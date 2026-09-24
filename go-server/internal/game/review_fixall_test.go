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

// ---- Follow-up (same day): a showdown the SERVER starts waits too. ----

// deferredShowdownTable plays a FIVE_CARD hand to the edge of a server
// showdown with one player, the waiter, still inside their pick window, and
// takes the last step. potLimit picks the pot cap over the round cap.
func deferredShowdownTable(t *testing.T, potLimit bool) (h *harness, ids []string, waiter string) {
	t.Helper()
	h, ids, chooser := variationTable(t, 3)
	if _, err := h.table.SelectVariation(chooser, "FIVE_CARD"); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		h.mustAct(id, ActionSee, ActRequest{})
	}
	for _, id := range ids {
		if id == chooser || waiter != "" {
			if _, err := h.table.SelectCards(id, h.view(id).You.Cards[:3]); err != nil {
				t.Fatal(err)
			}
			continue
		}
		waiter = id
	}
	eq(t, h.turnUser(), chooser, "the chooser opens the betting")
	if potLimit {
		chaal := *h.betOptions(chooser).Chaal
		h.read(func() { h.table.cfg.MaxPot = h.table.hand.pot + chaal })
		h.mustAct(chooser, ActionChaal, ActRequest{})
	} else {
		h.read(func() { h.table.hand.round = h.table.cfg.MaxBetRounds - 1 })
		for i := 0; i < 3; i++ {
			h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
		}
	}
	return h, ids, waiter
}

func (h *harness) showdowns() []ShowdownEvent {
	var out []ShowdownEvent
	for _, p := range h.rec.all("showdown") {
		out = append(out, p.(ShowdownEvent))
	}
	return out
}

func (h *harness) deferred() WinReason {
	var r WinReason
	h.read(func() {
		if h.table.hand != nil {
			r = h.table.hand.deferredShowdown
		}
	})
	return r
}

func revealOf(t *testing.T, ev ShowdownEvent, userID string) Reveal {
	t.Helper()
	for _, r := range ev.Reveals {
		if r.UserID == userID {
			return r
		}
	}
	t.Fatalf("no reveal for %s", userID)
	return Reveal{}
}

func TestAForcedShowdownWaitsForAPlayerStillChoosingAndJudgesTheirChoice(t *testing.T) {
	h, ids, waiter := deferredShowdownTable(t, false)
	eq(t, len(h.showdowns()), 0, "no showdown while the waiter is choosing")
	eq(t, h.hasHand(), true, "the hand waits")
	eq(t, h.deferred(), WinForcedShowdown, "the showdown is deferred")
	eq(t, h.turnSeat(), -1, "nobody is on turn meanwhile")
	for _, id := range ids {
		_, err := h.act(id, ActionChaal, ActRequest{})
		wantCode(t, err, CodeNotYourTurn, id+" betting into a deferred showdown")
	}

	picked := h.view(waiter).You.Cards[2:]
	if _, err := h.table.SelectCards(waiter, picked); err != nil {
		t.Fatal(err)
	}
	shows := h.showdowns()
	eq(t, len(shows), 1, "the showdown ran once the choice was made")
	eq(t, shows[0].Reason, WinForcedShowdown, "as a forced showdown")
	best := revealOf(t, shows[0], waiter).Best
	eq(t, best[0]+best[1]+best[2], picked[0]+picked[1]+picked[2], "the waiter was judged on the three they chose")
	h.advance(fiveCardPickMS)
	eq(t, len(h.showdowns()), 1, "and it ran exactly once")
}

func TestAPotLimitShowdownWaitsForAWindowToLapseThenPlaysTheFirstThree(t *testing.T) {
	h, _, waiter := deferredShowdownTable(t, true)
	eq(t, h.deferred(), WinPotLimit, "the pot-limit showdown is deferred")
	eq(t, len(h.showdowns()), 0, "no showdown yet")
	first := h.view(waiter).You.Cards[:3]

	h.advance(fiveCardPickMS)
	shows := h.showdowns()
	eq(t, len(shows), 1, "the lapse ran it")
	eq(t, shows[0].Reason, WinPotLimit, "as the pot-limit showdown")
	best := revealOf(t, shows[0], waiter).Best
	eq(t, best[0]+best[1]+best[2], first[0]+first[1]+first[2], "a window that LAPSED plays the first three")
}

func TestAPlayerLeavingReleasesTheShowdownWaitingForThem(t *testing.T) {
	h, _, waiter := deferredShowdownTable(t, false)
	h.remove(waiter, LeaveReasonLeft)
	shows := h.showdowns()
	eq(t, len(shows), 1, "nobody waits for a player who has gone")
	eq(t, len(shows[0].Reveals), 2, "the two still in show")
}

func TestADeferredShowdownSurvivesARestart(t *testing.T) {
	h, _, waiter := deferredShowdownTable(t, false)
	snap := roundTrip(t, mustSnapshot(h))
	eq(t, snap.Hand.DeferredShowdown, WinForcedShowdown, "the snapshot keeps the deferral")

	// Back inside the window: it still waits, and the choice releases it.
	r := restoreHarness(t, snap, newFakeClock(h.clock.Now().Add(time.Second)), withLedger(emptyLedger))
	eq(t, r.hasHand(), true, "restored mid-deferral")
	eq(t, r.turnSeat(), -1, "and play was not reopened")
	eq(t, len(r.showdowns()), 0, "no showdown yet")
	picked := r.view(waiter).You.Cards[1:4]
	if _, err := r.table.SelectCards(waiter, picked); err != nil {
		t.Fatal(err)
	}
	eq(t, len(r.showdowns()), 1, "the choice ran it after the restart")
	best := revealOf(t, r.showdowns()[0], waiter).Best
	eq(t, best[0]+best[1]+best[2], picked[0]+picked[1]+picked[2], "on the three they chose")

	// Back after the window lapsed: it runs, once, on the first three.
	late := restoreHarness(t, roundTrip(t, mustSnapshot(h)), newFakeClock(h.clock.Now().Add(fiveCardPickMS+time.Second)), withLedger(emptyLedger))
	late.advance(time.Millisecond)
	eq(t, len(late.showdowns()), 1, "a lapsed window runs it at the restart")
	eq(t, late.showdowns()[0].Reason, WinForcedShowdown, "as the showdown it was")
	late.advance(fiveCardPickMS)
	eq(t, len(late.showdowns()), 1, "exactly once")
}

// Follow-up 2: while a sideshow stands the asker's options offer nothing the
// server would refuse, so the client's keys grey out instead of taking a tap.
func TestTheAskersOptionsOfferNoMoveWhileTheirSideshowStands(t *testing.T) {
	h, _ := sideshowTable(t, 3)
	asker := h.turnUser()
	asked := h.rightOf(asker)
	h.mustAct(asker, ActionSideshow, ActRequest{})

	opts := h.view(asker).You.Options
	if opts == nil {
		t.Fatal("the asker still holds the turn, so still has options")
	}
	eq(t, len(opts.RaiseSteps), 0, "no ladder")
	if opts.RaiseSteps == nil {
		t.Fatal("raiseSteps must be [] on the wire, never null")
	}
	eq(t, opts.Chaal == nil && opts.Raise == nil && opts.MaxBet == nil, true, "no chaal, raise or max")
	eq(t, opts.Show == nil, true, "no show")
	eq(t, opts.CanPack, false, "no pack")
	eq(t, opts.CanSideshow || opts.CanForceSideshow || opts.CanMissile, false, "no sideshow, force or missile")

	h.mustRespond(asked, false)
	opts = h.view(asker).You.Options
	eq(t, len(opts.RaiseSteps) > 0, true, "the ladder is back once it resolves")
	eq(t, opts.CanPack, true, "and the pack")
}
