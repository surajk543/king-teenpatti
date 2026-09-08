package game

// Port of server/test/sideshow.test.js (requirement 33). The rules pinned
// here: a sideshow needs three players and two seen hands, only the player
// asked may answer, the request expires by itself, it can be asked once per
// turn, and the turn stays with the asker throughout.

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

const (
	sideshowBoot  int64 = 100
	sideshowStart int64 = 100000
	sideshowMS          = 6 * time.Second
)

func sideshowConfig() TableConfig {
	return TableConfig{
		Category:           CategorySeen,
		BootAmount:         sideshowBoot,
		MaxPlayers:         5,
		MinPlayers:         2,
		TurnTimeout:        25 * time.Second,
		MaxBetRounds:       20,
		PotLimitMultiplier: 1024,
		MaxRaiseSteps:      8,
		MaxBlindMoves:      4,
		NextHandDelay:      6 * time.Second,
		ChatMaxHistory:     100,
		ChatMaxLength:      140,
		SideshowTimeout:    sideshowMS,
		SideshowMinPlayers: 3,
	}
}

// sideshowTable is Node's makeTable({count}): `count` players seated, a hand
// under way, everybody having seen their cards.
func sideshowTable(t *testing.T, count int) (*harness, []string) {
	t.Helper()
	h := newHarness(t, sideshowConfig(), withLedger(emptyLedger), withID("sideshow-room", "SIDE01"))
	var ids []string
	for i := 0; i < count; i++ {
		id := "p" + string(rune('0'+i))
		ids = append(ids, id)
		h.seatNamed(id, strings.ToUpper(id), sideshowStart)
	}
	h.startHand()
	for _, id := range ids {
		h.mustAct(id, ActionSee, ActRequest{})
	}
	return h, ids
}

// rightOf is who a sideshow from userID would go to.
func (h *harness) rightOf(userID string) string {
	var id string
	h.read(func() {
		s := h.table.findSeat(userID)
		right := h.table.rightActiveSeat(s.seatIndex)
		if right >= 0 && h.table.seats[right] != nil {
			id = h.table.seats[right].userID
		}
	})
	return id
}

func (h *harness) respond(userID string, accept bool) (SideshowOutcome, error) {
	return h.table.RespondToSideshow(userID, accept)
}

func (h *harness) mustRespond(userID string, accept bool) SideshowOutcome {
	h.t.Helper()
	out, err := h.respond(userID, accept)
	if err != nil {
		h.t.Fatalf("respond: %v", err)
	}
	return out
}

func (h *harness) sideshowRequested() []SideshowRequestedEvent {
	var out []SideshowRequestedEvent
	for _, p := range h.rec.all("sideshowRequested") {
		out = append(out, p.(SideshowRequestedEvent))
	}
	return out
}

func (h *harness) sideshowReveals() []SideshowRevealEvent {
	var out []SideshowRevealEvent
	for _, p := range h.rec.all("sideshowReveal") {
		out = append(out, p.(SideshowRevealEvent))
	}
	return out
}

func (h *harness) sideshowResolved() []SideshowResolvedEvent {
	var out []SideshowResolvedEvent
	for _, p := range h.rec.all("sideshowResolved") {
		out = append(out, p.(SideshowResolvedEvent))
	}
	return out
}

// ------------------------------------------------------------- availability

func TestTheSideshowButtonIsOfferedToThePlayerOnTurnAndNobodyElse(t *testing.T) {
	h, ids := sideshowTable(t, 3)
	actor := h.turnUser()
	opts := h.turnOptions(actor)
	eq(t, opts.CanSideshow, true, "canSideshow")
	if opts.SideshowWith == nil || *opts.SideshowWith != strings.ToUpper(h.rightOf(actor)) {
		t.Fatalf("sideshowWith %v, want the right neighbour's name", opts.SideshowWith)
	}
	for _, id := range ids {
		if id == actor {
			continue
		}
		eq(t, h.turnOptions(id).CanSideshow, false, id+" cannot")
		if h.turnOptions(id).SideshowWith != nil {
			t.Fatal("sideshowWith null when blocked")
		}
		eq(t, h.blockedReason(id), SideshowBlockedNotYourTurn, id+" reason")
	}
}

func TestASideshowNeedsThreePlayersInTheHand(t *testing.T) {
	h, _ := sideshowTable(t, 2)
	actor := h.turnUser()
	eq(t, h.blockedReason(actor), SideshowBlockedTooFewPlayers, "reason")
	eq(t, h.turnOptions(actor).CanSideshow, false, "canSideshow")
	_, err := h.act(actor, ActionSideshow, ActRequest{})
	codeIs(t, err, CodeTooFewPlayers)
	var ge *GameError
	if errors.As(err, &ge) {
		eq(t, ge.Message, "A sideshow needs at least 3 players in the hand", "message")
	}
}

func TestBothHandsMustHaveBeenSeen(t *testing.T) {
	h, _ := sideshowTable(t, 3)
	actor := h.turnUser()
	right := h.rightOf(actor)

	h.setBlind(right, true)
	eq(t, h.blockedReason(actor), SideshowBlockedNeighbourIsBlind, "neighbour blind")
	_, err := h.act(actor, ActionSideshow, ActRequest{})
	codeIs(t, err, CodeNeighbourIsBlind)

	h.setBlind(right, false)
	h.setBlind(actor, true)
	eq(t, h.blockedReason(actor), SideshowBlockedYouAreBlind, "self blind")
	_, err = h.act(actor, ActionSideshow, ActRequest{})
	codeIs(t, err, CodeYouAreBlind)
}

func TestTheRequestGoesToThePlayerOnTheRightWhoActedImmediatelyBefore(t *testing.T) {
	h, _ := sideshowTable(t, 4)
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})

	actor := h.turnUser()
	previous := h.rightOf(actor)
	// The player on the right is the one who acted just before.
	eq(t, previous, h.lastAction().UserID, "right neighbour acted immediately before")

	res := h.mustAct(actor, ActionSideshow, ActRequest{})
	eq(t, res.Action, "sideshow", "ack action")
	eq(t, res.ToUserID, previous, "ack toUserId")

	requests := h.sideshowRequested()
	eq(t, len(requests), 1, "one request")
	eq(t, requests[0].FromUserID, actor, "from")
	eq(t, requests[0].ToUserID, previous, "to")
	eq(t, requests[0].FromName, strings.ToUpper(actor), "fromName")
	eq(t, requests[0].ToName, strings.ToUpper(previous), "toName")
	eq(t, requests[0].TimeoutMs, int64(6000), "timeoutMs")
	eq(t, requests[0].ExpiresAt, Millis(h.clock.Now().Add(sideshowMS)), "expiresAt")
	raw, _ := json.Marshal(requests[0])
	if strings.Contains(string(raw), "cards") {
		t.Fatal("no cards travel with the request")
	}

	view := h.view(actor)
	if view.Sideshow == nil {
		t.Fatal("the request is in the table state")
	}
	eq(t, view.Sideshow.ToUserID, previous, "state.sideshow.toUserId")
	eq(t, view.Sideshow.FromUserID, actor, "state.sideshow.fromUserId")
	rawView, _ := json.Marshal(view.Sideshow)
	if strings.Contains(string(rawView), "cards") || strings.Contains(string(rawView), "timer") {
		t.Fatalf("sideshow view carries ids/seats/expiresAt only: %s", rawView)
	}
}

// ------------------------------------------------------------- answering it

func TestOnlyThePlayerWhoWasAskedCanAnswer(t *testing.T) {
	h, ids := sideshowTable(t, 3)
	actor := h.turnUser()
	asked := h.rightOf(actor)
	h.mustAct(actor, ActionSideshow, ActRequest{})

	var bystander string
	for _, id := range ids {
		if id != actor && id != asked {
			bystander = id
		}
	}
	_, err := h.respond(bystander, true)
	codeIs(t, err, CodeNotYourSideshow)
	_, err = h.respond(actor, true)
	codeIs(t, err, CodeNotYourSideshow)

	h.mustRespond(asked, false)
	_, err = h.respond(asked, false)
	codeIs(t, err, CodeNoSideshow)
}

func TestADeclinedSideshowPacksNobodyAndHandsTheTurnStraightBack(t *testing.T) {
	h, _ := sideshowTable(t, 3)
	actor := h.turnUser()
	asked := h.rightOf(actor)
	h.mustAct(actor, ActionSideshow, ActRequest{})
	mark := h.rec.count()
	out := h.mustRespond(asked, false)
	eq(t, out.Accepted, false, "ack accepted")
	if out.PackedUserID != nil {
		t.Fatal("ack packedUserId null")
	}

	resolved := h.sideshowResolved()
	eq(t, len(resolved), 1, "one resolution")
	eq(t, resolved[0].Accepted, false, "accepted")
	eq(t, resolved[0].Reason, SideshowDeclined, "reason")
	if resolved[0].PackedUserID != nil {
		t.Fatal("packedUserId null")
	}
	eq(t, len(h.sideshowReveals()), 0, "nobody saw anything")

	eq(t, h.mustSeat(asked).Status, SeatActive, "asked still active")
	eq(t, h.turnUser(), actor, "turn back with the asker")
	if h.turnOptions(actor).Chaal == nil {
		t.Fatal("they can still bet")
	}
	// Observed order on a decline: sideshowResolved > turn > state.
	eq(t, strings.Join(h.rec.names()[mark:], ","), "sideshowResolved,turn,state", "decline order")
}

func TestAnUnansweredRequestIsRejectedAfterSixSeconds(t *testing.T) {
	h, _ := sideshowTable(t, 3)
	actor := h.turnUser()
	h.mustAct(actor, ActionSideshow, ActRequest{})
	eq(t, h.sideshowPending(), true, "pending")

	h.advance(sideshowMS - time.Millisecond)
	eq(t, h.sideshowPending(), true, "still standing just before the deadline")

	h.advance(time.Millisecond)
	eq(t, h.sideshowPending(), false, "expired")
	eq(t, h.sideshowResolved()[0].Reason, SideshowTimeout, "reason")
	eq(t, h.turnUser(), actor, "turn back with the asker")
}

func TestTheTurnClockStopsWhileARequestStandsAndRestartsFullAfterwards(t *testing.T) {
	h, _ := sideshowTable(t, 3)
	actor := h.turnUser()
	asked := h.rightOf(actor)

	h.advance(20 * time.Second) // 5s left of a 25s turn
	h.mustAct(actor, ActionSideshow, ActRequest{})

	h.advance(sideshowMS - time.Millisecond)
	eq(t, h.turnUser(), actor, "cannot time out while waiting")
	eq(t, h.mustSeat(actor).Status, SeatActive, "still active")

	h.mustRespond(asked, false)

	h.advance(25*time.Second - time.Millisecond)
	eq(t, h.turnUser(), actor, "still their turn on the fresh clock")
	h.advance(time.Millisecond)
	eq(t, h.mustSeat(actor).Status, SeatPacked, "timed out on the new clock")
}

// ------------------------------------------------------------- the comparison

func TestTheWeakerHandPacksAndOnlyTheTwoOfThemSeeTheCards(t *testing.T) {
	h, _ := sideshowTable(t, 3)
	actor := h.turnUser()
	asked := h.rightOf(actor)
	h.setCards(actor, "As", "Ah", "Ad")
	h.setCards(asked, "2s", "7h", "9d")

	h.mustAct(actor, ActionSideshow, ActRequest{})
	mark := h.rec.count()
	out := h.mustRespond(asked, true)
	eq(t, out.Accepted, true, "ack accepted")
	eq(t, *out.PackedUserID, asked, "ack packedUserId")

	reveals := h.sideshowReveals()
	eq(t, len(reveals), 1, "one reveal")
	eq(t, strings.Join(reveals[0].UserIDs, ","), actor+","+asked, "to both of them, asker first")
	hands := reveals[0].Reveal.Hands
	eq(t, len(hands), 2, "two hands")
	eq(t, strings.Join(hands[0].Cards, ""), "AsAhAd", "asker's cards first")
	eq(t, strings.Join(hands[1].Cards, ""), "2s7h9d", "asked second")
	eq(t, hands[0].HandName, "Trail", "hand name")
	eq(t, hands[0].DisplayName, strings.ToUpper(actor), "display name")
	eq(t, reveals[0].Reveal.PackedUserID, asked, "reveal packedUserId")
	eq(t, reveals[0].Reveal.Reason, SideshowAccepted, "reveal reason")

	resolved := h.sideshowResolved()
	eq(t, resolved[0].Accepted, true, "accepted")
	eq(t, *resolved[0].PackedUserID, asked, "packed")
	raw, _ := json.Marshal(resolved[0])
	if strings.Contains(string(raw), "As") {
		t.Fatal("what the rest of the table hears carries no cards")
	}

	eq(t, h.mustSeat(asked).Status, SeatPacked, "asked packed")
	eq(t, h.mustSeat(actor).Status, SeatActive, "asker active")
	eq(t, h.turnUser(), actor, "the turn never left the asker")

	// Observed order when the asked player loses (spec §19.1):
	// sideshowReveal > action:pack/sideshow > state > sideshowResolved > turn > state.
	eq(t, strings.Join(h.rec.names()[mark:], ","), "sideshowReveal,action,state,sideshowResolved,turn,state", "asked-loses order")
	eq(t, h.lastAction().Reason, PackReasonSideshow, "pack reason")
	eq(t, h.lastAction().UserID, asked, "pack of the asked")
}

func TestLosingYourOwnSideshowPacksYouAndPassesTheTurnOn(t *testing.T) {
	h, _ := sideshowTable(t, 4)
	actor := h.turnUser()
	asked := h.rightOf(actor)
	h.setCards(actor, "2s", "7h", "9d")
	h.setCards(asked, "As", "Ah", "Ad")

	h.mustAct(actor, ActionSideshow, ActRequest{})
	mark := h.rec.count()
	h.mustRespond(asked, true)

	eq(t, h.mustSeat(actor).Status, SeatPacked, "asker packed")
	eq(t, h.mustSeat(asked).Status, SeatActive, "asked active")
	if h.turnUser() == actor {
		t.Fatal("the turn moved off the packed player")
	}
	eq(t, h.mustSeat(h.turnUser()).Status, SeatActive, "turn on an active seat")
	// Observed order when the asker loses:
	// sideshowReveal > action:pack/sideshow > turn > state > state > sideshowResolved > state.
	eq(t, strings.Join(h.rec.names()[mark:], ","), "sideshowReveal,action,turn,state,state,sideshowResolved,state", "asker-loses order")
}

func TestATieGoesAgainstThePlayerWhoAsked(t *testing.T) {
	h, _ := sideshowTable(t, 3)
	actor := h.turnUser()
	asked := h.rightOf(actor)
	h.setCards(actor, "Ks", "Kh", "4d")
	h.setCards(asked, "Kd", "Kc", "4s")

	h.mustAct(actor, ActionSideshow, ActRequest{})
	h.mustRespond(asked, true)

	eq(t, h.mustSeat(actor).Status, SeatPacked, "asker packed on a tie")
	eq(t, h.mustSeat(asked).Status, SeatActive, "asked active")
}

func TestWhenTheSideshowLeavesTwoPlayersTheHandCarriesOnRatherThanEnding(t *testing.T) {
	h, _ := sideshowTable(t, 3)
	actor := h.turnUser()
	asked := h.rightOf(actor)
	h.setCards(actor, "As", "Ah", "Ad")
	h.setCards(asked, "2s", "7h", "9d")

	h.mustAct(actor, ActionSideshow, ActRequest{})
	h.mustRespond(asked, true)

	eq(t, len(h.activeIDs()), 2, "two left")
	eq(t, h.hasHand(), true, "the hand is still live")
	show := h.turnOptions(h.turnUser()).Show
	if show == nil || *show <= 0 {
		t.Fatal("two left, so a show is now on the table")
	}
}

// ------------------------------------------------------------- once per turn

func TestOneSideshowPerTurnAndTheNextTurnBringsAFreshOne(t *testing.T) {
	h, _ := sideshowTable(t, 3)
	first := h.turnUser()
	h.mustAct(first, ActionSideshow, ActRequest{})
	h.mustRespond(h.rightOf(first), false)

	eq(t, h.turnUser(), first, "turn given back")
	eq(t, h.blockedReason(first), SideshowBlockedAlreadyAsked, "ask used up")
	eq(t, h.turnOptions(first).CanSideshow, false, "canSideshow false")
	_, err := h.act(first, ActionSideshow, ActRequest{})
	codeIs(t, err, CodeAlreadyAsked)

	h.mustAct(first, ActionChaal, ActRequest{})
	for h.turnUser() != first {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
	eq(t, h.blockedReason(first), "", "fresh turn, fresh ask")
	eq(t, h.turnOptions(first).CanSideshow, true, "canSideshow true")
}

func TestASecondRequestCannotBeOpenedWhileOneIsStanding(t *testing.T) {
	h, _ := sideshowTable(t, 3)
	actor := h.turnUser()
	h.mustAct(actor, ActionSideshow, ActRequest{})
	_, err := h.act(actor, ActionSideshow, ActRequest{})
	codeIs(t, err, CodeSideshowPending)
}

// ------------------------------------------------------------- interruptions

func TestAPlayerLeavingCancelsTheSideshowTheyWerePartOf(t *testing.T) {
	h, _ := sideshowTable(t, 4)
	actor := h.turnUser()
	asked := h.rightOf(actor)
	h.mustAct(actor, ActionSideshow, ActRequest{})

	h.remove(asked, LeaveReasonLeft)

	eq(t, h.sideshowPending(), false, "cancelled")
	eq(t, h.sideshowResolved()[0].Reason, SideshowLeft, "reason left")
	eq(t, len(h.sideshowReveals()), 0, "no reveal")
	eq(t, h.turnUser(), actor, "the asker is not left waiting")
	if h.turnOptions(actor).Chaal == nil {
		t.Fatal("they can still bet")
	}
}

func TestTheAskerLeavingWithARequestPendingProducesTheNodeEventSequence(t *testing.T) {
	h, _ := sideshowTable(t, 4)
	actor := h.turnUser()
	h.mustAct(actor, ActionSideshow, ActRequest{})
	mark := h.rec.count()

	h.remove(actor, LeaveReasonLeft)

	// Spec §19.1: sideshowResolved > turn > state > seatUpdated > chat >
	// action:pack/left > turn > state > state.
	eq(t, strings.Join(h.rec.names()[mark:], ","),
		"sideshowResolved,turn,state,seatUpdated,chat,action,turn,state,state", "asker-leaves order")
	eq(t, h.sideshowResolved()[0].Reason, SideshowLeft, "reason")
	eq(t, h.lastAction().Reason, LeaveReasonLeft, "pack reason is the leave reason")
	eq(t, h.lastAction().Action, ActionPack, "leaving mid-hand is a pack")
	if h.turnUser() == actor {
		t.Fatal("the turn moved on")
	}
	eq(t, h.hasHand(), true, "three players carry on")
}

func TestAPendingRequestDoesNotOutliveItsHand(t *testing.T) {
	h, ids := sideshowTable(t, 3)
	actor := h.turnUser()
	h.mustAct(actor, ActionSideshow, ActRequest{})

	for _, id := range ids {
		if id != actor {
			h.remove(id, LeaveReasonLeft)
		}
	}
	eq(t, h.hasHand(), false, "the hand ended")
	eq(t, h.lastHandEnded().Reason, WinLastStanding, "last standing")

	before := len(h.sideshowResolved())
	h.advance(sideshowMS * 2)
	eq(t, len(h.sideshowReveals()), 0, "no reveal")
	eq(t, len(h.sideshowResolved()), before, "the expiry timer fired into nothing")
}

func TestASideshowTimeoutOfZeroNeverExpires(t *testing.T) {
	cfg := sideshowConfig()
	cfg.SideshowTimeout = 0
	h := newHarness(t, cfg, withLedger(emptyLedger))
	for _, id := range []string{"a", "b", "c"} {
		h.seat(id, sideshowStart)
	}
	h.startHand()
	for _, id := range []string{"a", "b", "c"} {
		h.mustAct(id, ActionSee, ActRequest{})
	}
	actor := h.turnUser()
	h.mustAct(actor, ActionSideshow, ActRequest{})
	h.advance(10 * time.Minute)
	eq(t, h.sideshowPending(), true, "DECISIONS §2: 0 = a request never expires")
	eq(t, len(h.sideshowResolved()), 0, "nothing resolved")
}

func TestASideshowMinPlayersOfZeroImposesNoMinimum(t *testing.T) {
	cfg := sideshowConfig()
	cfg.SideshowMinPlayers = 0
	h := newHarness(t, cfg, withLedger(emptyLedger))
	h.seat("a", sideshowStart)
	h.seat("b", sideshowStart)
	h.startHand()
	h.mustAct("a", ActionSee, ActRequest{})
	h.mustAct("b", ActionSee, ActRequest{})
	eq(t, h.blockedReason(h.turnUser()), "", "two players may sideshow when the gate is off")
}

func TestSideshowBlockedReasonOrder(t *testing.T) {
	h, _ := sideshowTable(t, 3)
	actor := h.turnUser()
	// Off turn beats everything after it.
	for _, id := range h.activeIDs() {
		if id != actor {
			h.setBlind(id, true)
			eq(t, h.blockedReason(id), SideshowBlockedNotYourTurn, "not_your_turn first")
			h.setBlind(id, false)
		}
	}
	// A pending request beats already_asked / blindness.
	h.mustAct(actor, ActionSideshow, ActRequest{})
	h.setBlind(actor, true)
	eq(t, h.blockedReason(actor), SideshowBlockedPending, "pending before blindness")
	h.setBlind(actor, false)
	h.mustRespond(h.rightOf(actor), false)
	// already_asked beats blindness.
	h.setBlind(actor, true)
	eq(t, h.blockedReason(actor), SideshowBlockedAlreadyAsked, "already_asked before blindness")
	h.setBlind(actor, false)
	// A packed player is not_in_hand.
	other := h.rightOf(actor)
	h.read(func() { h.table.findSeat(other).status = SeatPacked })
	eq(t, h.blockedReason(other), SideshowBlockedNotInHand, "not_in_hand")
}
