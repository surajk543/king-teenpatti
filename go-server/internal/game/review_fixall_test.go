package game

import (
	"testing"
	"time"
)

// The Teen Patti engine's share of the owner's "fix all bugs" (24 Sep 2026,
// before the APK release): each test here failed on the code it guards against.

func wantCode(t *testing.T, err error, code, what string) {
	t.Helper()
	if err == nil {
		t.Fatalf("%s: accepted, want %s", what, code)
	}
	if got := CodeOf(err, ""); got != code {
		t.Fatalf("%s: refused %q (%v), want %s", what, got, err, code)
	}
}

func (h *harness) turnDeadline() time.Time {
	var d time.Time
	h.read(func() { d = h.table.hand.turnDeadline })
	return d
}

// TPS-1 / F1: the asker could bet on while their own request stood, the turn
// moved round, and a late acceptance then froze the hand or skipped a turn.
func TestEveryMoveButALookWaitsWhileASideshowStands(t *testing.T) {
	h, ids := sideshowTable(t, 3)
	asker := h.turnUser()
	asked := h.rightOf(asker)
	h.setCards(asker, "As", "Ah", "Ad")
	h.setCards(asked, "2s", "7h", "9d")
	h.mustAct(asker, ActionSideshow, ActRequest{})

	steps := h.betOptions(asker).Steps
	_, err := h.act(asker, ActionChaal, ActRequest{})
	wantCode(t, err, CodeSideshowPending, "chaal")
	_, err = h.act(asker, ActionRaise, amt(steps[len(steps)-1]))
	wantCode(t, err, CodeSideshowPending, "raise")
	_, err = h.act(asker, ActionPack, ActRequest{})
	wantCode(t, err, CodeSideshowPending, "pack")
	_, err = h.act(asker, ActionShow, ActRequest{})
	wantCode(t, err, CodeSideshowPending, "show")
	eq(t, h.turnUser(), asker, "the turn never moved")
	for _, id := range ids {
		if id != asker {
			_, err = h.act(id, ActionChaal, ActRequest{})
			wantCode(t, err, CodeNotYourTurn, id+" chaal")
		}
	}

	h.mustRespond(asked, true)
	eq(t, h.mustSeat(asked).Status, SeatPacked, "the weaker hand packed")
	eq(t, h.turnUser(), asker, "the asker has the turn back")
	h.mustAct(asker, ActionChaal, ActRequest{})
}

// Defence in depth: however the turn came to be on the asked player when they
// lose, it moves on, and an asker who does not hold it never moves it.
func TestALateAcceptanceNeverLeavesTheTurnOnAPackedSeat(t *testing.T) {
	h, _ := sideshowTable(t, 4)
	asker := h.turnUser()
	asked := h.rightOf(asker)
	h.setCards(asker, "As", "Ah", "Ad")
	h.setCards(asked, "2s", "7h", "9d")
	h.mustAct(asker, ActionSideshow, ActRequest{})
	// The state the old act() let a table reach: the turn gone round to the
	// asked player while the request still stood.
	h.read(func() { h.table.hand.turnSeat = h.table.findSeat(asked).seatIndex })

	h.mustRespond(asked, true)
	eq(t, h.mustSeat(asked).Status, SeatPacked, "asked packed")
	turn := h.turnUser()
	if turn == "" || turn == asked {
		t.Fatalf("the turn stayed on the packed seat (%q)", turn)
	}
	eq(t, h.mustSeat(turn).Status, SeatActive, "the turn is on a player still in")
	h.mustAct(turn, ActionChaal, ActRequest{})
}

// TPS-2: a comparison a player forces waits for every hand it would judge to
// be chosen; it used to play their first three with the window still open.
func TestAComparisonWaitsForAPlayerStillChoosingTheirThree(t *testing.T) {
	h, ids, chooser := variationTable(t, 3)
	if _, err := h.table.SelectVariation(chooser, "FIVE_CARD"); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		h.mustAct(id, ActionSee, ActRequest{})
	}
	if _, err := h.table.SelectCards(chooser, h.view(chooser).You.Cards[:3]); err != nil {
		t.Fatal(err)
	}
	eq(t, h.turnUser(), chooser, "the chooser is on turn")

	_, err := h.act(chooser, ActionSideshow, ActRequest{})
	wantCode(t, err, CodePickPending, "sideshow")
	_, err = h.act(chooser, ActionForceSideshow, ActRequest{})
	wantCode(t, err, CodePickPending, "force sideshow")
	_, err = h.act(chooser, ActionMissile, ActRequest{})
	wantCode(t, err, CodePickPending, "missile")
	opts := h.turnOptions(chooser)
	eq(t, opts.CanSideshow, false, "canSideshow")
	eq(t, opts.CanForceSideshow, false, "canForceSideshow")
	eq(t, opts.CanMissile, false, "canMissile")

	// The windows lapse (at most FIVE_CARD_PICK_TIMEOUT_MS) and the ask goes.
	h.advance(h.table.cfg.FiveCardPickTimeout)
	eq(t, h.turnOptions(chooser).CanSideshow, true, "open again once nobody is choosing")
	h.mustAct(chooser, ActionSideshow, ActRequest{})
}

func TestAShowWaitsForTheOtherPlayerToChooseTheirThree(t *testing.T) {
	h, ids, chooser := variationTable(t, 2)
	if _, err := h.table.SelectVariation(chooser, "FIVE_CARD"); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		h.mustAct(id, ActionSee, ActRequest{})
	}
	if _, err := h.table.SelectCards(chooser, h.view(chooser).You.Cards[:3]); err != nil {
		t.Fatal(err)
	}
	if h.turnOptions(chooser).Show != nil {
		t.Fatal("show offered while the other player is still choosing")
	}
	_, err := h.act(chooser, ActionShow, ActRequest{})
	wantCode(t, err, CodePickPending, "show")
	eq(t, h.hasHand(), true, "the hand goes on")

	other := h.otherActive(chooser)
	picked := h.view(other).You.Cards[2:]
	if _, err := h.table.SelectCards(other, picked); err != nil {
		t.Fatal(err)
	}
	h.mustAct(chooser, ActionShow, ActRequest{})
	for _, r := range h.lastShowdown().Reveals {
		if r.UserID == other {
			eq(t, r.Best[0]+r.Best[1]+r.Best[2], picked[0]+picked[1]+picked[2], "judged on the three they chose")
		}
	}
}

// TPS-3: another player's look opened THEIR window and extended the turn
// holder's clock.
func TestAnotherPlayersPickWindowDoesNotExtendTheTurn(t *testing.T) {
	h, ids, chooser := variationTable(t, 3)
	if _, err := h.table.SelectVariation(chooser, "FIVE_CARD"); err != nil {
		t.Fatal(err)
	}
	before := h.turnDeadline()
	for _, id := range ids {
		if id != chooser {
			h.mustAct(id, ActionSee, ActRequest{})
		}
	}
	eq(t, h.turnDeadline().Equal(before), true, "the holder's deadline did not move")

	h.mustAct(chooser, ActionSee, ActRequest{})
	want := h.clock.Now().Add(h.table.cfg.FiveCardPickTimeout + h.table.cfg.TurnTimeout)
	eq(t, h.turnDeadline().Equal(want), true, "their own window extends their own turn")
}

// TPS-6: the chooser who looked during the window gets the extension too.
func TestAChooserWhoLookedFirstGetsTheirPickTimeOnTheirTurn(t *testing.T) {
	h, _, chooser := variationTable(t, 3)
	h.mustAct(chooser, ActionSee, ActRequest{})
	if _, err := h.table.SelectVariation(chooser, "FIVE_CARD"); err != nil {
		t.Fatal(err)
	}
	eq(t, h.view(chooser).You.Hand.Picking, true, "their window is open")
	want := h.clock.Now().Add(h.table.cfg.FiveCardPickTimeout + h.table.cfg.TurnTimeout)
	eq(t, h.turnDeadline().Equal(want), true, "the window and a full turn")
}

// TPS-7: a packed seat's choice was accepted.
func TestAPackedPlayerCannotChooseTheirThree(t *testing.T) {
	h, _, chooser := variationTable(t, 3)
	if _, err := h.table.SelectVariation(chooser, "FIVE_CARD"); err != nil {
		t.Fatal(err)
	}
	h.mustAct(chooser, ActionChaal, ActRequest{})
	folder := h.turnUser()
	h.mustAct(folder, ActionSee, ActRequest{})
	cards := h.view(folder).You.Cards[:3]
	h.mustAct(folder, ActionPack, ActRequest{})
	_, err := h.table.SelectCards(folder, cards)
	wantCode(t, err, CodeNotInHand, "pick from a packed seat")
	eq(t, h.view(folder).You.Hand == nil || !h.view(folder).You.Hand.Picking, true, "the window closed with the pack")
}

// F3: a chaal carrying a raise rung doubled the stake and was announced as a
// chaal.
func TestAChaalCarryingARaiseIsAnnouncedAsTheRaiseItIs(t *testing.T) {
	h, _ := sideshowTable(t, 3)
	player := h.turnUser()
	steps := h.betOptions(player).Steps
	res := h.mustAct(player, ActionChaal, amt(steps[1]))
	eq(t, res.Action, string(ActionRaise), "ack")
	eq(t, h.lastAction().Action, ActionRaise, "the table hears a raise")
	eq(t, h.lastAction().Amount, steps[1], "amount")

	next := h.turnUser()
	first := h.betOptions(next).Steps[0]
	res = h.mustAct(next, ActionChaal, amt(first))
	eq(t, res.Action, string(ActionChaal), "the first rung stays a chaal")
	eq(t, h.lastAction().Action, ActionChaal, "and is heard as one")
}

// F4: one player's action id refused another player's move.
func TestAnActionIDIsIdempotentPerPlayerNotPerHand(t *testing.T) {
	h, _ := sideshowTable(t, 3)
	a := h.turnUser()
	h.mustAct(a, ActionChaal, ActRequest{ActionID: "dup-1"})
	b := h.turnUser()
	h.mustAct(b, ActionChaal, ActRequest{ActionID: "dup-1"})
	c := h.turnUser()
	h.mustAct(c, ActionChaal, ActRequest{ActionID: "c-1"})
	_, err := h.act(a, ActionChaal, ActRequest{ActionID: "dup-1"})
	wantCode(t, err, CodeDuplicateAction, "the same player's replay")
}
