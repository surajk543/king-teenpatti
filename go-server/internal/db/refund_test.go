package db_test

import (
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// A pot left open by a process that died mid-hand is handed back to the
// players who staked it — each contributor's boot + bets + shows, once — and
// closed with no winner. Running the refund again finds nothing to do.
func TestRefundOrphanedPotsReturnsEveryStakeOnceAndClosesThePot(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("A"), f.user("B")
	room, hand := "room-orphan", "hand-orphan"
	f.boot(room, hand, 200, a, b)
	if _, err := f.ledger.Bet(f.ctx, game.BetRequest{UserID: a.ID, Amount: 400, RoomID: room, HandID: hand, ActionID: "orphan-bet-1"}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.ledger.Bet(f.ctx, game.BetRequest{UserID: b.ID, Amount: 400, RoomID: room, HandID: hand, ActionID: "orphan-show-1", Reason: game.LedgerReasonShow}); err != nil {
		t.Fatal(err)
	}
	if f.chips(a.ID) != welcome-600 || f.chips(b.ID) != welcome-600 {
		t.Fatalf("stakes not banked: a=%d b=%d", f.chips(a.ID), f.chips(b.ID))
	}

	report, err := f.d.RefundOrphanedPots(f.ctx, map[string]bool{})
	if err != nil {
		t.Fatalf("refund: %v", err)
	}
	if report.Pots != 1 || report.Contributors != 2 || report.Chips != 1200 || report.AlreadyRefunded != 0 || report.Skipped != 0 {
		t.Fatalf("report = %+v", report)
	}
	for _, u := range []*db.User{a, b} {
		if got := f.chips(u.ID); got != welcome {
			t.Fatalf("%s wallet = %d, want the stake back (%d)", u.DisplayName, got, welcome)
		}
		rows := f.ledgerRows(u.ID)
		last := rows[len(rows)-1]
		wantID := db.RefundActionID(hand, u.ID)
		if last.Reason != db.LedgerReasonRefund || last.Delta != 600 || last.Balance != welcome || last.ActionID == nil || *last.ActionID != wantID || last.HandID == nil || *last.HandID != hand {
			t.Fatalf("%s refund row = %+v", u.DisplayName, last)
		}
	}
	var closedAt *int64
	var winner *string
	var amount int64
	if err := f.d.Pool.QueryRow(f.ctx, `SELECT closed_at, winner_id, amount FROM pots WHERE hand_id = $1`, hand).Scan(&closedAt, &winner, &amount); err != nil {
		t.Fatal(err)
	}
	if closedAt == nil || winner != nil || amount != 1200 {
		t.Fatalf("pot after refund: closed_at=%v winner=%v amount=%d", closedAt, winner, amount)
	}
	if n := f.count(`SELECT COUNT(*) FROM hands WHERE id = $1`, hand); n != 0 {
		t.Fatalf("a refund must not invent a hands row, found %d", n)
	}
	f.reconcile()

	// A second run is a no-op: the pot is closed, nothing is credited twice.
	again, err := f.d.RefundOrphanedPots(f.ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if again != (db.RefundReport{}) {
		t.Fatalf("second run did work: %+v", again)
	}
	if f.chips(a.ID) != welcome || f.chips(b.ID) != welcome {
		t.Fatal("a second run moved chips")
	}
	if n := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE reason = $1`, db.LedgerReasonRefund); n != 2 {
		t.Fatalf("refund rows = %d, want 2", n)
	}
	f.reconcile()
}

// A pot whose hand is still being played by a restored table is not an
// orphan; a pot already settled is not open. Neither is touched.
func TestRefundLeavesLiveAndSettledPotsAlone(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("A"), f.user("B")
	f.boot("room-live", "hand-live", 200, a, b)
	f.boot("room-dead", "hand-dead", 200, a, b)
	f.boot("room-done", "hand-done", 200, a, b)
	if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{
		Hand:    game.HandRecord{ID: "hand-done", RoomID: "room-done", HandNo: 1, Pot: 400, WinnerID: ptr(a.ID), WinReason: "show", BootAmount: 200, StartedAt: 1, EndedAt: 2},
		Entries: []game.SettleEntry{{UserID: a.ID, Delta: 400, IsWinner: true, DidChaal: true}, {UserID: b.ID}},
	}); err != nil {
		t.Fatal(err)
	}
	before := f.chips(a.ID) + f.chips(b.ID)

	report, err := f.d.RefundOrphanedPots(f.ctx, map[string]bool{"hand-live": true})
	if err != nil {
		t.Fatal(err)
	}
	if report.Pots != 1 || report.Contributors != 2 || report.Chips != 400 || report.Skipped != 1 {
		t.Fatalf("report = %+v", report)
	}
	if n := f.count(`SELECT COUNT(*) FROM pots WHERE hand_id = 'hand-live' AND closed_at IS NULL`); n != 1 {
		t.Fatal("the live pot was closed")
	}
	if n := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE hand_id = 'hand-live' AND reason = $1`, db.LedgerReasonRefund); n != 0 {
		t.Fatal("the live pot was refunded")
	}
	var winner *string
	if err := f.d.Pool.QueryRow(f.ctx, `SELECT winner_id FROM pots WHERE hand_id = 'hand-done'`).Scan(&winner); err != nil {
		t.Fatal(err)
	}
	if winner == nil || *winner != a.ID {
		t.Fatalf("the settled pot lost its winner: %v", winner)
	}
	if after := f.chips(a.ID) + f.chips(b.ID); after != before+400 {
		t.Fatalf("chips moved by %d, want exactly the dead pot (400)", after-before)
	}
	f.reconcile()
}

// The refund row's action_id ("<handId>:refund:<userId>") is the idempotency
// key: if an earlier run wrote the rows and died before closing the pot, the
// next run finds the pot open, credits nobody again and closes it.
func TestRefundIsIdempotentPerContributor(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("A"), f.user("B")
	room, hand := "room-idem-refund", "hand-idem-refund"
	f.boot(room, hand, 200, a, b)
	if _, err := f.d.RefundOrphanedPots(f.ctx, nil); err != nil {
		t.Fatal(err)
	}
	// Simulate the crash window: rows written, pot still open.
	if err := f.d.Exec(f.ctx, `UPDATE pots SET closed_at = NULL WHERE hand_id = $1`, hand); err != nil {
		t.Fatal(err)
	}

	report, err := f.d.RefundOrphanedPots(f.ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if report.Pots != 1 || report.Contributors != 0 || report.Chips != 0 || report.AlreadyRefunded != 2 {
		t.Fatalf("report = %+v", report)
	}
	if f.chips(a.ID) != welcome || f.chips(b.ID) != welcome {
		t.Fatalf("a repeated refund moved chips: a=%d b=%d", f.chips(a.ID), f.chips(b.ID))
	}
	if n := f.count(`SELECT COUNT(*) FROM chip_ledger WHERE hand_id = $1 AND reason = $2`, hand, db.LedgerReasonRefund); n != 2 {
		t.Fatalf("refund rows = %d, want exactly one per contributor", n)
	}
	if n := f.count(`SELECT COUNT(*) FROM pots WHERE hand_id = $1 AND closed_at IS NOT NULL AND winner_id IS NULL`, hand); n != 1 {
		t.Fatal("the pot was not closed again")
	}
	f.reconcile()
}

// Nothing open → nothing to report, and the call is cheap enough to run on
// every start.
func TestRefundWithNoOpenPotsIsANoOp(t *testing.T) {
	f := newFixture(t)
	report, err := f.d.RefundOrphanedPots(f.ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if report != (db.RefundReport{}) {
		t.Fatalf("report = %+v", report)
	}
}
