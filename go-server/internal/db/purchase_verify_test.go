package db_test

import (
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/purchase"
)

// TestVerifyAPurchaseIsBankedOnceInPostgres is the PostgreSQL half of buying
// chips at a table: the wallet and a `purchase` ledger row, a replayed receipt
// that moves nothing, and the table's next pack checkpoint (the boot only, as
// the seat reports it after CreditChips) landing on top with the books intact.
func TestVerifyAPurchaseIsBankedOnceInPostgres(t *testing.T) {
	f := newFixture(t)
	u := f.user("buyer")
	p, err := purchase.Lookup("chips_a_99")
	if err != nil {
		t.Fatal(err)
	}
	token := "verify-token-" + randomSuffix(t)

	first, err := db.CreditPurchase(f.ctx, f.d, f.users, u.ID, p, token)
	if err != nil {
		t.Fatalf("credit: %v", err)
	}
	if !first.Credited || first.Balance != welcome+p.Chips {
		t.Fatalf("first credit: %+v", first)
	}
	if got := f.chips(u.ID); got != welcome+p.Chips {
		t.Fatalf("wallet %d, want %d", got, welcome+p.Chips)
	}
	rows := f.ledgerRows(u.ID)
	last := rows[len(rows)-1]
	if last.Reason != game.LedgerReasonPurchase || last.Delta != p.Chips ||
		last.ActionID == nil || *last.ActionID != purchase.ActionID(token) {
		t.Fatalf("purchase ledger row: %+v", last)
	}

	// The same receipt again — a retry after a lost reply, or Play restoring it.
	again, err := db.CreditPurchase(f.ctx, f.d, f.users, u.ID, p, token)
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	if again.Credited {
		t.Fatal("a replayed receipt was credited a second time")
	}
	if got := f.chips(u.ID); got != welcome+p.Chips {
		t.Fatalf("wallet moved on replay: %d", got)
	}

	// The table's pack checkpoint for the hand the purchase was made in.
	if _, err := f.pack("room-verify", "hand-verify", u, -200); err != nil {
		t.Fatalf("pack checkpoint: %v", err)
	}
	if got, want := f.chips(u.ID), welcome+p.Chips-200; got != want {
		t.Fatalf("wallet after the pack %d, want %d (purchase counted once, boot taken once)", got, want)
	}
	f.reconcile()
}
