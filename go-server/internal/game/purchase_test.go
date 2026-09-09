package game

import (
	"testing"
	"time"
)

// contributionDelta is what the next checkpoint would write for this player:
// `chips - chipsWritten`, read on the actor so nothing races it.
func contributionDelta(h *harness, userID string) (delta int64, found bool) {
	h.read(func() {
		if h.table.hand == nil {
			return
		}
		if e := h.table.hand.contributions[userID]; e != nil {
			delta, found = e.chips-e.chipsWritten, true
		}
	})
	return delta, found
}

// TestBuyingChipsMidHandMovesTheSeatWithoutMovingThemTwice is the arithmetic
// that makes a purchase safe while a hand is in play.
//
// A purchase credits PostgreSQL *and* the seat, unlike a reward which credits
// only the wallet. Every checkpoint writes `chips - chipsWritten`, so if the
// purchase moved the stack alone that subtraction would grow by the purchase
// and the next checkpoint would write it a second time — the player paid once
// and would be credited twice. Both sides have to move together.
func TestBuyingChipsMidHandMovesTheSeatWithoutMovingThemTwice(t *testing.T) {
	h := newHarness(t, ladderConfig())
	h.seat("alice", 200000)
	h.seat("bob", 200000)
	h.advance(6 * time.Second)
	if !h.hasHand() {
		t.Fatalf("expected a hand to be in play")
	}

	seatBefore := h.mustSeat("alice").Chips
	deltaBefore, found := contributionDelta(h, "alice")
	if !found {
		t.Fatalf("alice has no contribution record in a live hand")
	}

	const bought = 19_200_000 // pack A
	if !h.table.CreditChips("alice", bought) {
		t.Fatalf("CreditChips reported no seat for a seated player")
	}

	if got, want := h.mustSeat("alice").Chips, seatBefore+bought; got != want {
		t.Errorf("seat did not gain the chips: got %d, want %d", got, want)
	}

	deltaAfter, _ := contributionDelta(h, "alice")
	if deltaAfter != deltaBefore {
		t.Errorf("the checkpoint delta moved: got %d, want %d — PostgreSQL "+
			"already has these chips, so writing this delta would credit the "+
			"purchase a second time", deltaAfter, deltaBefore)
	}
}

// TestBuyingChipsBetweenHandsJustAddsToTheSeat: with no hand there is no
// contribution to reconcile, and the next deal takes chipsWritten from the
// seat — which by then includes the purchase, as PostgreSQL does.
func TestBuyingChipsBetweenHandsJustAddsToTheSeat(t *testing.T) {
	h := newHarness(t, ladderConfig())
	h.seat("alice", 200000)
	before := h.mustSeat("alice").Chips

	const bought = 52_800_000 // pack B
	if !h.table.CreditChips("alice", bought) {
		t.Fatalf("CreditChips reported no seat for a seated player")
	}
	if got, want := h.mustSeat("alice").Chips, before+bought; got != want {
		t.Errorf("seat did not gain the chips: got %d, want %d", got, want)
	}
}

// TestBuyingChipsForSomeoneNotAtThisTableCreditsNothing: the caller uses the
// false to tell "credited the seat" from "there was no seat".
func TestBuyingChipsForSomeoneNotAtThisTableCreditsNothing(t *testing.T) {
	h := newHarness(t, ladderConfig())
	h.seat("alice", 200000)
	if h.table.CreditChips("nobody", 1000) {
		t.Errorf("CreditChips claimed to credit a player who is not seated")
	}
}

// TestBuyingNothingIsRefused guards the boundary: a zero or negative amount is
// never a purchase, and must not reach a seat.
func TestBuyingNothingIsRefused(t *testing.T) {
	h := newHarness(t, ladderConfig())
	h.seat("alice", 200000)
	before := h.mustSeat("alice").Chips
	for _, n := range []int64{0, -1, -19_200_000} {
		if h.table.CreditChips("alice", n) {
			t.Errorf("CreditChips accepted %d", n)
		}
	}
	if got := h.mustSeat("alice").Chips; got != before {
		t.Errorf("the stack moved on a refused amount: got %d, want %d", got, before)
	}
}
