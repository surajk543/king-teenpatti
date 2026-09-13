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

// V1.0.5 gives every account 20 hammers — the accounts that existed before it
// as well as the ones made after — and boots again and again without adding a
// second column or a second CHECK.
func TestEveryAccountHoldsTwentyHammersTheOnesBeforeV105Included(t *testing.T) {
	schema, conn := butterflySchema(t) // a plain throwaway schema the test boots itself
	ctx := context.Background()
	d := bootNow(t, schema)
	fresh, isNew, err := db.NewUsers(d, welcome, nil).UpsertFromProfile(ctx, db.Profile{
		Provider: db.ProviderGuest, ProviderUserID: "hammer-fresh-" + randomSuffix(t), DisplayName: "Fresh",
	})
	if err != nil || !isNew || fresh.Hammer != 20 {
		t.Fatalf("a new account on a fresh database: %+v isNew=%v %v", fresh, isNew, err)
	}

	// The database as it stood before V1.0.5: no hammer column, and an account
	// made then.
	if _, err := conn.Exec(ctx, `ALTER TABLE users DROP COLUMN hammer`); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `INSERT INTO users (id, provider, provider_user_id, display_name, chips, created_at, updated_at, last_login_at)
		VALUES ('before-v105', 'guest', 'hammer-old-device', 'Old', 0, 1, 1, 1)`); err != nil {
		t.Fatal(err)
	}

	for boot := 1; boot <= 2; boot++ {
		bootNow(t, schema)
		var old, made int64
		if err := conn.QueryRow(ctx, `SELECT (SELECT hammer FROM users WHERE id = 'before-v105'), (SELECT hammer FROM users WHERE id = $1)`, fresh.ID).Scan(&old, &made); err != nil {
			t.Fatal(err)
		}
		if old != 20 || made != 20 {
			t.Fatalf("boot %d: the account from before V1.0.5 holds %d hammers and the later one %d, want 20 each", boot, old, made)
		}
		var checks int64
		var def string
		if err := conn.QueryRow(ctx, `
			SELECT (SELECT count(*) FROM pg_constraint
			         WHERE conrelid = 'users'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%hammer%'),
			       (SELECT column_default FROM information_schema.columns
			         WHERE table_schema = $1 AND table_name = 'users' AND column_name = 'hammer')`, schema).Scan(&checks, &def); err != nil {
			t.Fatal(err)
		}
		if checks != 1 || def != "20" {
			t.Fatalf("boot %d: %d CHECKs on hammer, default %q — want one CHECK and default 20", boot, checks, def)
		}
	}
}
