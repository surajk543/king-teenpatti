package app

import (
	"context"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// A hammer pack bought through the production gateway (a real Google verifier
// talking to a fake Play) is banked into users.hammer once, reports its
// hammers in the outcome the REST answer is built from, and moves neither the
// chips nor chip_ledger — and a replayed receipt reports the same pack with
// nothing credited.
func TestAHammerPackThroughThePlayStoreIsBankedOnceAndSaysSo(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()

	_, id := login(t, ts.URL, "hammer-pack-buyer", "Hammerer")
	users := db.NewUsers(database, a.cfg.Game.WelcomeChips, time.Now)
	store := &playStore{verifier: newFakePlayVerifier(t), db: database, users: users, credit: a.Rooms().CreditBoughtChips}
	walletBefore, ledgerBefore := walletAndLedger(t, database, id)

	out, err := store.Buy(ctx, id, "hammers_100_1299", "fake-play-hammer-receipt")
	if err != nil {
		t.Fatalf("buy: %v", err)
	}
	if !out.Credited || out.Hammers != 100 || out.Chips != 0 || out.Diamonds != 0 || out.User == nil || out.User.Hammer != 120 {
		t.Fatalf("outcome %+v (user %+v), want 100 hammers credited onto the welcome 20", out, out.User)
	}
	if wallet, ledger := walletAndLedger(t, database, id); wallet != walletBefore || ledger != ledgerBefore || out.Balance != walletBefore {
		t.Fatalf("a hammer pack moved chips: wallet %d→%d, ledger %d→%d, balance %d", walletBefore, wallet, ledgerBefore, ledger, out.Balance)
	}

	again, err := store.Buy(ctx, id, "hammers_100_1299", "fake-play-hammer-receipt")
	if err != nil || again.Credited || again.Hammers != 100 || again.User == nil || again.User.Hammer != 120 {
		t.Fatalf("replayed receipt: %+v %v", again, err)
	}
}
