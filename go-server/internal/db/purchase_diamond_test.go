package db_test

import (
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/purchase"
)

// A diamond pack is banked into users.diamond exactly once per Play token: the
// chips and chip_ledger never move, a replayed receipt credits nothing, and the
// same token sent from a second account is refused rather than paid twice.
func TestADiamondPackIsBankedOnceAndNeverTouchesChips(t *testing.T) {
	f := newFixture(t)
	u := f.user("gem-buyer")
	p, err := purchase.Lookup("diamonds_20_699")
	if err != nil {
		t.Fatal(err)
	}
	token := "diamond-token-" + randomSuffix(t)
	diamonds := func(id string) int64 {
		t.Helper()
		var n int64
		if err := f.d.Pool.QueryRow(f.ctx, `SELECT diamond FROM users WHERE id = $1`, id).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	startDiamonds := diamonds(u.ID)
	startRows := len(f.ledgerRows(u.ID))

	first, err := db.CreditDiamondPurchase(f.ctx, f.d, f.users, u.ID, p, token)
	if err != nil {
		t.Fatalf("credit: %v", err)
	}
	if !first.Credited || first.Diamonds != 20 || first.User == nil || first.User.Diamond != int(startDiamonds)+20 {
		t.Fatalf("first credit: %+v", first)
	}
	if got := diamonds(u.ID); got != startDiamonds+20 {
		t.Fatalf("diamonds %d, want %d", got, startDiamonds+20)
	}
	if got := f.chips(u.ID); got != welcome {
		t.Fatalf("chips moved on a diamond purchase: %d", got)
	}
	if got := len(f.ledgerRows(u.ID)); got != startRows {
		t.Fatalf("a diamond purchase wrote %d chip_ledger rows", got-startRows)
	}

	// The same receipt again — a retry after a lost reply, or Play restoring it.
	again, err := db.CreditDiamondPurchase(f.ctx, f.d, f.users, u.ID, p, token)
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	if again.Credited || diamonds(u.ID) != startDiamonds+20 {
		t.Fatalf("a replayed receipt was credited again: %+v, diamonds %d", again, diamonds(u.ID))
	}

	// The same token from another account pays nobody.
	other := f.user("token-thief")
	otherStart := diamonds(other.ID)
	stolen, err := db.CreditDiamondPurchase(f.ctx, f.d, f.users, other.ID, p, token)
	if err != nil {
		t.Fatalf("stolen token: %v", err)
	}
	if stolen.Credited || diamonds(other.ID) != otherStart {
		t.Fatalf("a token already banked was credited to another account: %+v", stolen)
	}

	// A chip pack is not a diamond pack.
	chips, _ := purchase.Lookup("chips_a_99")
	if _, err := db.CreditDiamondPurchase(f.ctx, f.d, f.users, u.ID, chips, "chips-token-"+randomSuffix(t)); err == nil {
		t.Fatal("a chip pack must not be credited as diamonds")
	}
	f.reconcile()
}
