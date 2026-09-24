package db_test

import (
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// A checkpoint never lands on a deleted account (rest-wallet-1, 24 Sep 2026):
// its wallet was emptied through account_deleted, so a pack, a leave or a
// hand-end row found there would record a debit the zero floor then hid, and
// SUM(delta) would stop equalling chips. The pack answers unknown_user, the
// settle skips the account, and its books stay reconciled.
func TestACheckpointNeverLandsOnADeletedAccount(t *testing.T) {
	f := newFixture(t)
	gone, winner := f.user("Gone"), f.user("Winner")
	room, hand := "room-deleted", "hand-deleted"
	if err := f.users.DeleteAccount(f.ctx, gone.ID); err != nil {
		t.Fatal(err)
	}
	rowsBefore := len(f.ledgerRows(gone.ID))

	if _, err := f.pack(room, hand, gone, -200); game.CodeOf(err, "") != game.CodeUnknownUser {
		t.Fatalf("a pack on a deleted account: %v, want unknown_user", err)
	}
	if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: room, HandID: hand, Entries: []game.SettleEntry{
		settleEntry(hand, gone.ID, -200, false, true, 0),
		settleEntry(hand, winner.ID, 200, true, true, 400),
	}}); err != nil {
		t.Fatal(err)
	}
	if got := len(f.ledgerRows(gone.ID)); got != rowsBefore {
		t.Fatalf("a deleted account gained %d ledger rows", got-rowsBefore)
	}
	if got := f.ledgerSum(gone.ID); got != f.chips(gone.ID) {
		t.Fatalf("deleted account: SUM(delta) = %d, chips = %d", got, f.chips(gone.ID))
	}
	f.reconcile()
}
