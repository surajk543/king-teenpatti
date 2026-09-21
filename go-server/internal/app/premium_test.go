package app

import (
	"context"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/purchase"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
)

// softWallets reads one account's diamonds, missiles and hammers.
func softWallets(t *testing.T, database *db.DB, userID string) (diamonds, missiles, hammers int64) {
	t.Helper()
	if err := database.Pool.QueryRow(context.Background(),
		`SELECT diamond, missile, hammer FROM users WHERE id = $1`, userID).Scan(&diamonds, &missiles, &hammers); err != nil {
		t.Fatal(err)
	}
	return diamonds, missiles, hammers
}

// A premium package bought through the production gateway (a real Google
// verifier talking to a fake Play) by a player seated at a table: the outcome
// the REST answer is built from carries its chips, missiles and hammers and
// the account holding all three; the chips reach the live seat once; the
// wallet, the seat and the ledger agree. A replayed receipt answers the same
// figures with nothing credited, and moves neither the wallets nor the seat.
func TestAPremiumPackageThroughThePlayStoreCreditsChipsMissilesAndHammersOnceAndTopsUpTheSeat(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()

	token, id := login(t, ts.URL, "premium-package-buyer", "Premium")
	c := dial(t, ts.URL, token)
	mustOK(t, c, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"})
	seat0 := seatOf(t, a, id)
	wallet0, ledger0 := walletAndLedger(t, database, id)
	diamonds0, missiles0, hammers0 := softWallets(t, database, id)
	if seat0 != wallet0 || ledger0 != wallet0 {
		t.Fatalf("before: seat %d, wallet %d, ledger %d", seat0, wallet0, ledger0)
	}

	// P4 is the dearest package since P5 and P6 were dropped on 22 Sep 2026.
	product, err := purchase.Lookup("premium_4_29999")
	if err != nil {
		t.Fatal(err)
	}
	const chips int64 = 25_000_000_000
	users := db.NewUsers(database, a.cfg.Game.WelcomeChips, time.Now)
	store := &playStore{verifier: newFakePlayVerifier(t), db: database, users: users, credit: a.Rooms().CreditBoughtChips}

	out, err := store.Buy(ctx, id, product.ID, "fake-play-premium-receipt")
	if err != nil {
		t.Fatalf("buy: %v", err)
	}
	if !out.Credited || out.Chips != chips || out.Missiles != 6 || out.Hammers != 30 || out.Diamonds != 0 ||
		out.Balance != wallet0+chips || out.User == nil || out.User.Chips != wallet0+chips ||
		out.User.Missile != int(missiles0)+6 || out.User.Hammer != int(hammers0)+30 || out.User.Diamond != int(diamonds0) {
		t.Fatalf("outcome %+v (user %+v), want 2,500 Crore, 6 missiles and 30 hammers credited", out, out.User)
	}
	if seat, wallet, ledger := seatOf(t, a, id), walletOf(t, database, id), ledgerOf(t, database, id); seat != seat0+chips || wallet != wallet0+chips || ledger != wallet {
		t.Fatalf("after the package: seat %d, wallet %d, ledger %d, want the seat and wallet %d and the ledger equal", seat, wallet, ledger, wallet0+chips)
	}
	if d, m, h := softWallets(t, database, id); d != diamonds0 || m != missiles0+6 || h != hammers0+30 {
		t.Fatalf("after the package: diamonds %d, missiles %d, hammers %d", d, m, h)
	}

	again, err := store.Buy(ctx, id, product.ID, "fake-play-premium-receipt")
	if err != nil || again.Credited || again.Chips != chips || again.Missiles != 6 || again.Hammers != 30 ||
		again.Balance != wallet0+chips || again.User == nil || again.User.Missile != int(missiles0)+6 || again.User.Hammer != int(hammers0)+30 {
		t.Fatalf("replayed receipt: %+v (user %+v) %v, want the package's figures with nothing credited", again, again.User, err)
	}
	if seat, wallet := seatOf(t, a, id), walletOf(t, database, id); seat != seat0+chips || wallet != wallet0+chips {
		t.Fatalf("after a replayed receipt: seat %d, wallet %d, want both %d", seat, wallet, wallet0+chips)
	}
	if d, m, h := softWallets(t, database, id); d != diamonds0 || m != missiles0+6 || h != hammers0+30 {
		t.Fatalf("a replayed receipt moved a soft wallet: diamonds %d, missiles %d, hammers %d", d, m, h)
	}

	mustOK(t, c, socket.EvRoomLeave, map[string]any{})
	if wallet, ledger := walletAndLedger(t, database, id); wallet != wallet0+chips || ledger != wallet {
		t.Fatalf("after leaving: wallet %d, ledger %d, want both %d", wallet, ledger, wallet0+chips)
	}
}

// A premium package bought in the lobby banks all three with no seat to top
// up, and a chip pack bought the same way still moves no missiles or hammers.
func TestAPremiumPackageInTheLobbyBanksAllThreeAndAChipPackStillOnlyChips(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()

	_, id := login(t, ts.URL, "premium-lobby-buyer", "Lobby")
	users := db.NewUsers(database, a.cfg.Game.WelcomeChips, time.Now)
	store := &playStore{verifier: newFakePlayVerifier(t), db: database, users: users, credit: a.Rooms().CreditBoughtChips}
	wallet0, _ := walletAndLedger(t, database, id)
	_, missiles0, hammers0 := softWallets(t, database, id)

	out, err := store.Buy(ctx, id, "premium_1_9999", "fake-play-premium-lobby")
	if err != nil || !out.Credited || out.Chips != 6_500_000_000 || out.Missiles != 1 || out.Hammers != 10 || out.User == nil ||
		out.User.Missile != int(missiles0)+1 || out.User.Hammer != int(hammers0)+10 {
		t.Fatalf("lobby premium package: %+v (user %+v) %v", out, out.User, err)
	}
	if a.Rooms().GetTableForPlayer(id) != nil {
		t.Fatal("buying a premium package seated the player")
	}

	chipPack, _ := purchase.Lookup("chips_a_99")
	out, err = store.Buy(ctx, id, chipPack.ID, "fake-play-chips-lobby")
	if err != nil || !out.Credited || out.Chips != chipPack.Chips || out.Missiles != 0 || out.Hammers != 0 || out.Diamonds != 0 {
		t.Fatalf("chip pack: %+v %v", out, err)
	}
	if wallet, ledger := walletAndLedger(t, database, id); wallet != wallet0+6_500_000_000+chipPack.Chips || ledger != wallet {
		t.Fatalf("wallet %d, ledger %d", wallet, ledger)
	}
	if _, m, h := softWallets(t, database, id); m != missiles0+1 || h != hammers0+10 {
		t.Fatalf("missiles %d, hammers %d: a chip pack moved one", m, h)
	}
}
