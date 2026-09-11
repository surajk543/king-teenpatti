package game

import (
	"testing"
	"time"
)

// A seat that can no longer cover the boot is held for UnfundedGrace before
// the insufficient_chips kick, so a player can buy chips and keep it.

func unfundedGraceConfig() TableConfig {
	cfg := purchaseBlindConfig()
	cfg.UnfundedGrace = 30 * time.Second
	cfg.TurnTimeout = 10 * time.Minute // no timeouts muddying the clock
	return cfg
}

// shortStackAfterAHand seats a buyer who can pay exactly one boot and a rival,
// deals, and lets the buyer pack: the hand ends with the buyer at 100, under
// the 200 boot.
func shortStackAfterAHand(t *testing.T) *harness {
	t.Helper()
	h := newHarness(t, unfundedGraceConfig(), withKickHandler())
	h.seat("buyer", 300)
	h.seat("rival", blindStart)
	h.advance(6 * time.Second)
	packOnTurn(h, "buyer")
	return h
}

func unfundedKickCount(h *harness, userID string) int {
	n := 0
	for _, k := range h.kickEvents() {
		if k.UserID == userID && k.Reason == KickReasonInsufficientChips {
			n++
		}
	}
	return n
}

func TestAShortStackIsHeldForTheGraceAndThenShownOut(t *testing.T) {
	h := shortStackAfterAHand(t)
	eq(t, unfundedKickCount(h, "buyer"), 0, "not shown out the moment the hand ends")

	you := h.view("buyer").You
	if you == nil || you.UnfundedDeadline == nil {
		t.Fatalf("the short player's view carries no grace deadline: %+v", you)
	}
	eq(t, *you.UnfundedDeadline, Millis(h.clock.Now().Add(30*time.Second)), "deadline is the grace from the hand's end")
	if other := h.view("rival").You; other == nil || other.UnfundedDeadline != nil {
		t.Fatalf("a funded player sees no deadline: %+v", other)
	}

	h.advance(29 * time.Second)
	eq(t, unfundedKickCount(h, "buyer"), 0, "still inside the grace")
	h.advance(2 * time.Second)
	eq(t, unfundedKickCount(h, "buyer"), 1, "shown out once the grace runs out")
	h.waitKicks()
	if h.seatInfo("buyer") != nil {
		t.Fatal("the seat is still taken after the kick")
	}
}

func TestBuyingChipsDuringTheGraceKeepsTheSeat(t *testing.T) {
	h := shortStackAfterAHand(t)
	h.advance(10 * time.Second)

	if !h.table.CreditChips("buyer", 19_200_000) {
		t.Fatal("CreditChips found no seat inside the grace")
	}
	if you := h.view("buyer").You; you == nil || you.UnfundedDeadline != nil {
		t.Fatalf("the grace should end once the boot is covered: %+v", you)
	}
	eq(t, h.state(), TableStarting, "the table counts down with the buyer funded")

	h.advance(25 * time.Second) // past where the grace would have ended, and past the countdown
	eq(t, unfundedKickCount(h, "buyer"), 0, "never shown out")
	eq(t, h.hasHand(), true, "the next hand is dealt")
	eq(t, h.mustSeat("buyer").Status, SeatActive, "with the buyer in it")
}

func TestTheGraceRunsOutForASeatSittingOutTheNextHand(t *testing.T) {
	h := newHarness(t, unfundedGraceConfig(), withKickHandler())
	h.seat("buyer", 300)
	h.seat("rival", blindStart)
	h.seat("third", blindStart)
	h.advance(6 * time.Second)

	// The buyer packs, then the rival: the third player takes the hand.
	for i := 0; h.hasHand() && i < 20; i++ {
		switch who := h.turnUser(); {
		case who == "buyer":
			h.mustAct(who, ActionPack, ActRequest{})
		case who == "rival" && h.mustSeat("buyer").Status == SeatPacked:
			h.mustAct(who, ActionPack, ActRequest{})
		default:
			h.mustAct(who, ActionChaal, ActRequest{})
		}
	}
	eq(t, h.hasHand(), false, "first hand over")
	eq(t, unfundedKickCount(h, "buyer"), 0, "held for the grace")

	h.advance(6 * time.Second) // the other two are dealt in; the buyer sits out
	eq(t, h.hasHand(), true, "second hand dealt without the buyer")
	eq(t, h.mustSeat("buyer").Status, SeatWaiting, "buyer sits it out")

	h.advance(25 * time.Second) // 31s after the first hand ended, mid-hand
	eq(t, unfundedKickCount(h, "buyer"), 1, "shown out without waiting for the hand to end")
	h.waitKicks()
	eq(t, h.hasHand(), true, "the others' hand goes on")
}

func TestAnUnfundedGraceSurvivesARestore(t *testing.T) {
	h := shortStackAfterAHand(t)
	h.advance(10 * time.Second)
	snap := roundTrip(t, mustSnapshot(h))
	_ = h.table.Destroy()

	r := restoreHarness(t, snap, h.clock, withKickHandler())
	if you := r.view("buyer").You; you == nil || you.UnfundedDeadline == nil {
		t.Fatalf("the restored seat lost its grace: %+v", you)
	}
	r.advance(19 * time.Second)
	eq(t, unfundedKickCount(r, "buyer"), 0, "still inside what was left of the grace")
	r.advance(2 * time.Second)
	eq(t, unfundedKickCount(r, "buyer"), 1, "shown out when the restored grace runs out")
}
