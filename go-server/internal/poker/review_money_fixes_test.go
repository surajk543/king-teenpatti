package poker

import (
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// Regression tests for the 24 Sep 2026 release review of the poker money
// paths (owner: "fix all bugs"). Each names the finding it pins.

// PM-1, the pot helper: the small blind (x) and the big blind (2x) walk out
// and the first player to act, who has put in 0, is the only one left. The
// pot nobody in hand reached must be opened to the players still in, never
// left with no eligible seat.
func TestSidePotsGiveDeadMoneyToThePlayerStillInWhenTheyPutInNothing(t *testing.T) {
	// SB seat 1 put in 100, BB seat 2 put in 200, UTG seat 0 put in 0 and is
	// the only seat still in.
	pots := SidePots(map[int]int64{1: 100, 2: 200}, map[int]bool{0: true})
	var total int64
	for _, p := range pots {
		total += p.Amount
		if len(p.Eligible) == 0 {
			t.Fatalf("a pot with no eligible seat: %+v", pots)
		}
	}
	if total != 300 || len(pots) != 1 || !equalInts(pots[0].Eligible, []int{0}) {
		t.Fatalf("%+v", pots)
	}
	_, totals := Award(pots, map[int]Hand{}, 0, 3)
	if totals[0] != 300 {
		t.Fatalf("UTG took %d of 300 (%v)", totals[0], totals)
	}
	// Nobody in hand at all: still unclaimed, for the caller to refund.
	if pots := SidePots(map[int]int64{1: 100, 2: 200}, map[int]bool{}); len(pots) != 1 || len(pots[0].Eligible) != 0 || pots[0].Amount != 300 {
		t.Fatalf("%+v", pots)
	}
}

// PM-1, the room: the blinds leave while UTG, 0 chips in, is on the clock.
// UTG is last standing and must take both blinds — in the seat AND in the
// books — and the hand's rows must sum to zero.
func TestTheBlindsLeavingPreflopPayTheBlindsToTheLastPlayerStanding(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	for _, id := range []string{"a", "b", "c"} {
		h.seat(id, 10_000)
	}
	h.deal()
	// Button a, small blind b (100), big blind c (200), a on turn with 0 in.
	if h.turn() != "a" {
		t.Fatalf("turn %s", h.turn())
	}
	for _, id := range []string{"b", "c"} {
		if _, err := h.table.RemovePlayer(id, game.LeaveReasonLeft); err != nil {
			t.Fatal(err)
		}
	}
	ended, ok := h.rec.last("handEnded").(HandEndedEvent)
	if !ok || ended.Reason != WinLastStanding {
		t.Fatalf("hand not ended last standing: %+v", h.rec.last("handEnded"))
	}
	if len(ended.Pots) != 1 || ended.Pots[0].Amount != 300 || len(ended.Pots[0].Winners) != 1 ||
		ended.Pots[0].Winners[0].UserID != "a" || ended.Pots[0].Winners[0].Amount != 300 || ended.Pots[0].Eligible == nil {
		t.Fatalf("pots %+v", ended.Pots)
	}
	if h.chips("a") != 10_300 {
		t.Fatalf("a %d, want 10,300", h.chips("a"))
	}
	h.assertWalletsMatchSeats()
	h.books.mu.Lock()
	defer h.books.mu.Unlock()
	if h.books.wallets["a"] != 10_300 || h.books.wallets["b"] != 9_900 || h.books.wallets["c"] != 9_800 {
		t.Fatalf("wallets %v", h.books.wallets)
	}
	var sum int64
	for _, r := range h.books.rows {
		sum += r.Delta
	}
	if sum != 0 {
		t.Fatalf("the hand's rows sum to %d: %+v", sum, h.books.rows)
	}
}

// PM-2: an all-in for less than a full raise does not reopen the betting to
// a player who has already acted since the last full raise — they may call or
// fold, not re-raise. A player who has not yet acted still may.
func TestAnIncompleteAllInRaiseDoesNotReopenTheBetting(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.seat("c", 10_000)
	h.deal()
	// Preflop: a calls, b (SB) calls, c (BB) checks.
	h.mustAct("a", ActionCall)
	h.mustAct("b", ActionCall)
	h.mustAct("c", ActionCheck)
	if h.street() != StreetFlop {
		t.Fatalf("street %s", h.street())
	}
	// Shorten b so their all-in is less than a full raise.
	h.read(func() { h.table.findSeat("b").chips = 1_300 })
	// Flop: b first (left of the button). b checks, c bets 1,000, a calls,
	// b goes all-in to 1,300 (+300 < a full 1,000 raise).
	h.mustAct("b", ActionCheck)
	h.mustAct("c", ActionBet, 1_000)
	h.mustAct("a", ActionCall)
	h.mustAct("b", ActionRaise, 1_300)
	if h.turn() != "c" {
		t.Fatalf("turn %s", h.turn())
	}
	o := h.options("c")
	if o.Raise || !o.Call || o.CallAmount != 300 || !o.Fold {
		t.Fatalf("c was offered %+v after an incomplete all-in raise", o)
	}
	expectCode(t, h.act("c", ActionRaise, 2_600), CodeInvalidAction)
	h.mustAct("c", ActionCall)
	if o := h.options("a"); o.Raise || !o.Call {
		t.Fatalf("a was offered %+v", o)
	}
	h.mustAct("a", ActionCall)
	if h.street() != StreetTurn {
		t.Fatalf("street %s", h.street())
	}
}

// PM-2's other half: a FULL raise still reopens it, and a player who has not
// acted on the street may raise over an incomplete all-in.
func TestAFullRaiseStillReopensTheBettingAndAPlayerYetToActMayRaise(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.seat("c", 10_000)
	h.seat("d", 10_000)
	h.deal()
	// Button a, SB b, BB c, first to act d. d raises to 400 (full), a shoves
	// short to 500 (+100, incomplete); b has not acted and may raise.
	h.mustAct("d", ActionRaise, 400)
	h.read(func() { h.table.findSeat("a").chips = 500 })
	h.mustAct("a", ActionRaise, 500)
	if o := h.options("b"); !o.Raise {
		t.Fatalf("b, yet to act, was offered %+v", o)
	}
	h.mustAct("b", ActionRaise, 1_000) // a full raise over 500 (+500 ≥ 200)
	if o := h.options("c"); !o.Raise {
		t.Fatalf("c was offered %+v", o)
	}
	h.mustAct("c", ActionCall)
	// d had acted, but b's full raise reopened it.
	if o := h.options("d"); !o.Raise {
		t.Fatalf("d was offered %+v after a full raise", o)
	}
}

// PM-7: a raise is not offered when nobody left can answer it.
func TestNoRaiseIsOfferedWhenEveryOpponentIsAllIn(t *testing.T) {
	h := newHarness(t, TexasHoldem)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	// Heads-up: button a posts the small blind, b the big blind. Make b's
	// big blind their whole stack.
	h.read(func() { h.table.findSeat("b").chips = 200 })
	h.books.mu.Lock()
	h.books.wallets["b"] = 200
	h.books.mu.Unlock()
	h.deal()
	if h.turn() != "a" {
		t.Fatalf("turn %s", h.turn())
	}
	o := h.options("a")
	if o.Raise || !o.Call || o.CallAmount != 100 {
		t.Fatalf("a was offered %+v against an all-in big blind", o)
	}
	expectCode(t, h.act("a", ActionRaise, 400), CodeInvalidAction)
	h.mustAct("a", ActionCall)
	if h.rec.last("handEnded") == nil {
		t.Fatal("the board did not run out")
	}
	h.assertWalletsMatchSeats()
}

// PM-3: at 3-Card Poker a stack that cannot pay the ante AND the play bet is
// not dealt in (it would be forced to fold its ante away), and is treated as
// unfunded between hands.
func TestThreeCardPokerDoesNotDealInAStackThatCannotPlay(t *testing.T) {
	h := newHarness(t, ThreeCardPoker)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.seat("c", 10_000)
	// c drops to one ante (200): enough for the ante, not for the play bet.
	h.read(func() { h.table.findSeat("c").chips = 200 })
	h.deal()
	dealtIn := false
	h.read(func() { dealtIn = h.table.hand.contributions["c"] != nil })
	if dealtIn {
		t.Fatal("c was dealt in with one ante")
	}
	if h.chips("c") != 200 {
		t.Fatalf("c %d", h.chips("c"))
	}
	// Exactly two antes is enough.
	h.mustAct(h.turn(), ActionFold)
	h.mustAct(h.turn(), ActionFold)
	if h.rec.last("handEnded") == nil {
		t.Fatal("hand did not end")
	}
	h.read(func() { h.table.findSeat("c").chips = 400 })
	h.clock.Advance(h.cfg.NextHandDelay)
	h.read(func() { dealtIn = h.table.hand != nil && h.table.hand.contributions["c"] != nil })
	if !dealtIn {
		t.Fatal("c, holding ante + play, was not dealt in")
	}
}

// PM-3, the kick: with no grace, a 3-Card Poker seat below ante + play is
// shown out between hands like any other unfunded seat.
func TestThreeCardPokerKicksAStackBelowAnteAndPlayBetweenHands(t *testing.T) {
	h := newHarness(t, ThreeCardPoker)
	h.seat("a", 10_000)
	h.seat("b", 10_000)
	h.seat("c", 10_000)
	kicked := false
	h.read(func() {
		h.table.findSeat("c").chips = 300
		h.table.sweepUnfunded()
		kicked = h.table.findSeat("c") == nil || h.table.findSeat("c").kickPending
	})
	if !kicked {
		t.Fatal("c, holding less than ante + play, was not treated as unfunded")
	}
}

// PM-6 (the rule, documented in SidePots): a player who left or folded
// forfeits their chips, even the part nobody matched — it is dead money in
// the highest pot a player still in can win. A player STILL IN gets back an
// excess nobody could call.
func TestAnUnmatchedExcessGoesBackToAPlayerStillInButIsDeadMoneyOnceTheyLeave(t *testing.T) {
	// Seat 0 (still in) bet 3,000; seat 1 called all-in for 1,000; seat 2
	// folded after 200. Seat 0's 2,000 excess is theirs alone.
	pots := SidePots(map[int]int64{0: 3_000, 1: 1_000, 2: 200}, map[int]bool{0: true, 1: true})
	if len(pots) != 2 || pots[0].Amount != 2_200 || !equalInts(pots[0].Eligible, []int{0, 1}) ||
		pots[1].Amount != 2_000 || !equalInts(pots[1].Eligible, []int{0}) {
		t.Fatalf("%+v", pots)
	}
	// The same, but seat 0 has LEFT: their excess is dead money in the pot
	// seat 1 can win — every chip still in exactly one pot.
	pots = SidePots(map[int]int64{0: 3_000, 1: 1_000, 2: 200}, map[int]bool{1: true})
	if len(pots) != 1 || pots[0].Amount != 4_200 || !equalInts(pots[0].Eligible, []int{1}) {
		t.Fatalf("%+v", pots)
	}
}
