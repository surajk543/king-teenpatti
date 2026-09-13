package db_test

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/purchase"
)

// hammersOf reads users.hammer straight from the table.
func (f *fixture) hammersOf(userID string) int64 {
	f.t.Helper()
	return f.scalar(`SELECT hammer FROM users WHERE id = $1`, userID)
}

// A Force Sideshow's hammer is taken once per key and never below zero: a
// retry of a committed spend charges nothing (even when that spend took the
// last hammer), an empty wallet is refused no_hammers with nothing recorded,
// and chips and chip_ledger never move.
func TestAHammerSpendIsChargedOncePerKeyAndNeverGoesBelowZero(t *testing.T) {
	f := newFixture(t)
	u := f.user("forcer")
	wallet := db.NewHammers(f.d, nil, nil)
	if u.Hammer != 20 || f.hammersOf(u.ID) != 20 {
		t.Fatalf("a new account holds %d hammers (row %d), want 20", u.Hammer, f.hammersOf(u.ID))
	}
	startRows := len(f.ledgerRows(u.ID))
	spend := func(key string) (game.HammerSpendResult, error) {
		return wallet.SpendHammer(f.ctx, game.HammerSpend{
			RoomID: "room-h", HandID: "hand-h", UserID: u.ID,
			ActionID: game.ForceSideshowSpendID("hand-h", u.ID, key),
		})
	}
	spends := func(key string) int64 {
		return f.count(`SELECT count(*) FROM hammer_spends WHERE action_id = $1`, game.ForceSideshowSpendID("hand-h", u.ID, key))
	}

	first, err := spend("a")
	if err != nil || !first.Charged || first.Remaining != 19 {
		t.Fatalf("first spend: %+v %v", first, err)
	}
	if f.hammersOf(u.ID) != 19 || spends("a") != 1 {
		t.Fatalf("after one spend: hammers %d, rows %d", f.hammersOf(u.ID), spends("a"))
	}
	if hand := f.count(`SELECT count(*) FROM hammer_spends WHERE user_id = $1 AND hand_id = 'hand-h'`, u.ID); hand != 1 {
		t.Fatalf("the spend records its hand: %d rows", hand)
	}

	again, err := spend("a")
	if err != nil || again.Charged || again.Remaining != 19 || f.hammersOf(u.ID) != 19 || spends("a") != 1 {
		t.Fatalf("a retried key was charged again: %+v %v, hammers %d", again, err, f.hammersOf(u.ID))
	}

	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE users SET hammer = 1 WHERE id = $1`, u.ID); err != nil {
		t.Fatal(err)
	}
	last, err := spend("b")
	if err != nil || !last.Charged || last.Remaining != 0 {
		t.Fatalf("the last hammer: %+v %v", last, err)
	}
	_, err = spend("c")
	if game.CodeOf(err, "") != game.CodeNoHammers {
		t.Fatalf("an empty wallet: %v, want no_hammers", err)
	}
	if f.hammersOf(u.ID) != 0 || spends("c") != 0 {
		t.Fatalf("a refused spend left hammers %d and %d rows", f.hammersOf(u.ID), spends("c"))
	}
	// The retry of the spend that took the last hammer is paid for already.
	retried, err := spend("b")
	if err != nil || retried.Charged || retried.Remaining != 0 {
		t.Fatalf("retry of a paid key at zero: %+v %v", retried, err)
	}

	// The CHECK is the last line.
	_, err = f.d.Pool.Exec(f.ctx, `UPDATE users SET hammer = hammer - 1 WHERE id = $1`, u.ID)
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "23514" {
		t.Fatalf("users.hammer below zero must violate its CHECK, got %v", err)
	}

	if _, err := wallet.SpendHammer(f.ctx, game.HammerSpend{HandID: "hand-h", UserID: "no-such-user", ActionID: "k"}); game.CodeOf(err, "") != game.CodeUnknownUser {
		t.Fatalf("an unknown account: %v", err)
	}
	if f.chips(u.ID) != welcome || len(f.ledgerRows(u.ID)) != startRows {
		t.Fatalf("hammers moved chips (%d) or wrote %d chip_ledger rows", f.chips(u.ID), len(f.ledgerRows(u.ID))-startRows)
	}
	f.reconcile()
}

// The key a Force Sideshow is charged under names the hand and the player as
// well as the client's actionId (game.ForceSideshowSpendID): the same id in the
// next hand, or from another player, is a spend of its own and takes a hammer.
// Only the same player's retry in the same hand is free.
func TestTheSameClientActionIdIsANewHammerSpendInAnotherHandOrForAnotherPlayer(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("force-key-a"), f.user("force-key-b")
	wallet := db.NewHammers(f.d, nil, nil)
	for _, c := range []struct {
		what    string
		handID  string
		user    *db.User
		charged bool
		left    int64
	}{
		{"the first spend", "hand-1", a, true, 19},
		{"the same id in the next hand", "hand-2", a, true, 18},
		{"the same id from another player", "hand-1", b, true, 19},
		{"the same player's retry in the same hand", "hand-1", a, false, 18},
	} {
		got, err := wallet.SpendHammer(f.ctx, game.HammerSpend{
			RoomID: "room-k", HandID: c.handID, UserID: c.user.ID,
			ActionID: game.ForceSideshowSpendID(c.handID, c.user.ID, "same-client-id"),
		})
		if err != nil || got.Charged != c.charged || got.Remaining != c.left {
			t.Fatalf("%s: %+v %v, want charged=%v with %d left", c.what, got, err, c.charged, c.left)
		}
	}
	if f.hammersOf(a.ID) != 18 || f.hammersOf(b.ID) != 19 {
		t.Fatalf("wallets hold %d and %d, want 18 and 19", f.hammersOf(a.ID), f.hammersOf(b.ID))
	}
	if n := f.count(`SELECT count(*) FROM hammer_spends WHERE user_id IN ($1, $2)`, a.ID, b.ID); n != 3 {
		t.Fatalf("%d spend rows, want 3", n)
	}
}

// Spends from one wallet racing each other queue on the wallet lock: exactly
// as many succeed as there were hammers, and the rest are refused.
func TestConcurrentHammerSpendsNeverTakeMoreThanTheWalletHolds(t *testing.T) {
	f := newFixture(t)
	u := f.user("racer")
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE users SET hammer = 5 WHERE id = $1`, u.ID); err != nil {
		t.Fatal(err)
	}
	wallet := db.NewHammers(f.d, nil, nil)
	const attempts = 16
	var wg sync.WaitGroup
	var mu sync.Mutex
	ok, refused := 0, 0
	for i := 0; i < attempts; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, err := wallet.SpendHammer(context.Background(), game.HammerSpend{
				HandID: "race", UserID: u.ID, ActionID: game.ForceSideshowSpendID("race", u.ID, fmt.Sprint(i)),
			})
			mu.Lock()
			defer mu.Unlock()
			switch {
			case err == nil:
				ok++
			case game.CodeOf(err, "") == game.CodeNoHammers:
				refused++
			default:
				t.Errorf("spend %d: %v", i, err)
			}
		}(i)
	}
	wg.Wait()
	if ok != 5 || refused != attempts-5 {
		t.Fatalf("%d spends went through and %d were refused, want 5 and %d", ok, refused, attempts-5)
	}
	if f.hammersOf(u.ID) != 0 || f.count(`SELECT count(*) FROM hammer_spends WHERE user_id = $1`, u.ID) != 5 {
		t.Fatalf("hammers %d, spend rows %d", f.hammersOf(u.ID), f.count(`SELECT count(*) FROM hammer_spends WHERE user_id = $1`, u.ID))
	}
}

// A hammer pack is banked into users.hammer exactly once per Play token: the
// chips, the diamonds and chip_ledger never move, a replayed receipt credits
// nothing, and the same token from a second account pays nobody.
func TestAHammerPackIsBankedOnceAndNeverTouchesChips(t *testing.T) {
	f := newFixture(t)
	u := f.user("hammer-buyer")
	p, err := purchase.Lookup("hammers_50_699")
	if err != nil {
		t.Fatal(err)
	}
	token := "hammer-token-" + randomSuffix(t)
	startRows := len(f.ledgerRows(u.ID))
	diamonds := f.scalar(`SELECT diamond FROM users WHERE id = $1`, u.ID)

	first, err := db.CreditHammerPurchase(f.ctx, f.d, f.users, u.ID, p, token)
	if err != nil {
		t.Fatalf("credit: %v", err)
	}
	if !first.Credited || first.Hammers != 50 || first.Diamonds != 0 || first.Chips != 0 || first.User == nil || first.User.Hammer != 70 {
		t.Fatalf("first credit: %+v", first)
	}
	if f.hammersOf(u.ID) != 70 || first.Balance != welcome {
		t.Fatalf("hammers %d balance %d", f.hammersOf(u.ID), first.Balance)
	}
	if f.chips(u.ID) != welcome || len(f.ledgerRows(u.ID)) != startRows || f.scalar(`SELECT diamond FROM users WHERE id = $1`, u.ID) != diamonds {
		t.Fatal("a hammer pack moved chips, diamonds or chip_ledger")
	}
	if n := f.count(`SELECT count(*) FROM hammer_purchases WHERE purchase_token = $1 AND user_id = $2 AND product_id = 'hammers_50_699' AND hammers = 50`, token, u.ID); n != 1 {
		t.Fatalf("hammer_purchases rows %d", n)
	}

	again, err := db.CreditHammerPurchase(f.ctx, f.d, f.users, u.ID, p, token)
	if err != nil || again.Credited || again.Hammers != 50 || f.hammersOf(u.ID) != 70 {
		t.Fatalf("a replayed receipt was credited again: %+v %v, hammers %d", again, err, f.hammersOf(u.ID))
	}

	other := f.user("hammer-thief")
	stolen, err := db.CreditHammerPurchase(f.ctx, f.d, f.users, other.ID, p, token)
	if err != nil || stolen.Credited || f.hammersOf(other.ID) != 20 {
		t.Fatalf("a token already banked was credited to another account: %+v %v", stolen, err)
	}

	gems, _ := purchase.Lookup("diamonds_5_199")
	if _, err := db.CreditHammerPurchase(f.ctx, f.d, f.users, u.ID, gems, "gem-token-"+randomSuffix(t)); err == nil {
		t.Fatal("a diamond pack must not be credited as hammers")
	}
	if _, err := db.CreditDiamondPurchase(f.ctx, f.d, f.users, u.ID, p, "hammer-as-gem-"+randomSuffix(t)); err == nil {
		t.Fatal("a hammer pack must not be credited as diamonds")
	}
	f.reconcile()
}

// A new account holds 20 hammers, and booting again adds no second column or
// CHECK: the baseline declares users.hammer once, in CREATE TABLE users.
func TestANewAccountHoldsTwentyHammersAndABootAddsNoSecondCheck(t *testing.T) {
	f := newFixture(t)
	u := f.user("hammer-fresh")
	if u.Hammer != 20 || f.hammersOf(u.ID) != 20 {
		t.Fatalf("a new account holds %d hammers (row %d), want 20", u.Hammer, f.hammersOf(u.ID))
	}
	again, err := db.Open(f.ctx, db.Options{URL: testURL(), Schema: f.d.Schema, PoolMax: 2})
	if err != nil {
		t.Fatalf("second boot: %v", err)
	}
	again.Close()
	checks := f.scalar(`SELECT count(*) FROM pg_constraint
		WHERE conrelid = 'users'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%hammer%'`)
	if checks != 1 {
		t.Fatalf("%d CHECKs on users.hammer after two boots, want 1", checks)
	}
}
