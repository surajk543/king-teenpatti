package game

// Variation Teen Patti — the window (owner, 18 Sep 2026). A variation table's
// hand opens with the player to the dealer's left choosing the rules it is
// decided by. The rules themselves are pinned in variation_test.go; what is
// pinned here is everything around the choice: who may make it, for how long,
// what the server does when they do not, that it is made exactly once whatever
// arrives together, and that the hand is then decided by it.

import (
	"encoding/json"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

const variationWindowMS = 10 * time.Second

func variationConfig() TableConfig {
	cfg := sideshowConfig()
	cfg.Category = CategoryVariation
	cfg.VariationSelectTimeout = variationWindowMS
	return cfg
}

// variationTable seats count players on a variation table and deals. It returns
// the harness, every player's id in seat order, and the id of the chooser.
func variationTable(t *testing.T, count int, opts ...harnessOption) (*harness, []string, string) {
	t.Helper()
	opts = append([]harnessOption{withLedger(emptyLedger), withID("variation-room", "VARIANT1")}, opts...)
	h := newHarness(t, variationConfig(), opts...)
	var ids []string
	for i := 0; i < count; i++ {
		id := "p" + string(rune('0'+i))
		ids = append(ids, id)
		h.seatNamed(id, strings.ToUpper(id), sideshowStart)
	}
	h.advance(variationConfig().NextHandDelay)
	eq(t, h.handNo(), 1, "the first hand is dealt")
	return h, ids, h.chooser()
}

// chooser is who the open window is for, "" when none is open.
func (h *harness) chooser() string {
	var id string
	h.read(func() {
		if h.table.variationPending() {
			id = h.table.hand.variation.chooserID
		}
	})
	return id
}

// window is the variation block of a viewer's snapshot.
func (h *harness) window(viewer string) *VariationView {
	h.t.Helper()
	return h.view(viewer).Variation
}

// setTurnUp forces the card turned up for Joker and Hukam — the same kind of
// seam setCards is.
func (h *harness) setTurnUp(code string) {
	h.t.Helper()
	h.read(func() { h.table.hand.variation.turnUp = ParseCard(code) })
}

func (h *harness) selected() []VariationSelectedEvent {
	var out []VariationSelectedEvent
	for _, e := range h.rec.all("variationSelected") {
		out = append(out, e.(VariationSelectedEvent))
	}
	return out
}

// ------------------------------------------------------------- the window

func TestAVariationHandIsDealtThreeCardsEachAndOpensWithTheWindow(t *testing.T) {
	h, ids, chooser := variationTable(t, 4)

	for _, info := range mustSeats(t, h.table) {
		eq(t, len(info.Cards), 3, info.UserID+" is dealt three cards")
	}
	if chooser == "" {
		t.Fatal("the deal opened no window")
	}

	// The chooser is whoever would have been first to act: the dealer's left.
	var dealer int
	h.read(func() { dealer = h.table.dealerSeat })
	var first string
	h.read(func() { first = h.table.seats[h.table.nextActiveSeat(dealer)].userID })
	eq(t, chooser, first, "the chooser is the player to the dealer's left")

	// Nobody is on turn while it is open, and nobody's clock is running.
	eq(t, h.turnSeat(), -1, "no seat is on turn during the window")
	if got := len(h.rec.all("turn")); got != 0 {
		t.Fatalf("%d turn event(s) before the variation was chosen", got)
	}

	// Announced once, to the table, with the whole menu and the server's deadline.
	events := h.rec.all("variationSelecting")
	eq(t, len(events), 1, "one variationSelecting event")
	e := events[0].(VariationSelectingEvent)
	eq(t, e.UserID, chooser, "the event names the chooser")
	eq(t, e.DisplayName, strings.ToUpper(chooser), "and their name")
	eq(t, e.TimeoutMs, int64(10_000), "ten seconds")
	if e.Deadline == nil || *e.Deadline != e.StartedAt+10_000 {
		t.Fatalf("deadline = %v, want startedAt %d + 10s", e.Deadline, e.StartedAt)
	}
	eq(t, len(e.Options), 6, "six options")

	// Every viewer's snapshot says the same thing — it is all a reconnecting
	// client has.
	for _, id := range ids {
		w := h.window(id)
		if w == nil {
			t.Fatalf("%s's snapshot has no variation block", id)
		}
		eq(t, w.Selecting, true, id+" sees the window open")
		eq(t, w.UserID, chooser, id+" sees who is choosing")
		eq(t, *w.Deadline, *e.Deadline, id+" sees the server's deadline")
		eq(t, len(w.Options), 6, id+" sees the menu")
		if w.Selected != nil || w.SelectedBy != nil || w.TurnUp != nil {
			t.Fatalf("%s's open window already names a choice: %+v", id, w)
		}
		if view := h.view(id); view.You.Options != nil {
			t.Fatalf("%s has turn options while the variation is being chosen", id)
		}
	}
}

func TestTheChooserMayPickAnyOfTheSixVariations(t *testing.T) {
	for _, v := range Variations {
		t.Run(string(v), func(t *testing.T) {
			h, ids, chooser := variationTable(t, 3)
			result, err := h.table.SelectVariation(chooser, string(v))
			if err != nil {
				t.Fatalf("SelectVariation(%s): %v", v, err)
			}
			eq(t, result.Variation, v, "the ack names what was chosen")
			eq(t, result.SelectedBy, VariationByPlayer, "chosen by the player")
			eq(t, result.TurnUp != nil, v.UsesTurnUp(), "the turned-up card is shown only when the variation uses it")

			got := h.selected()
			eq(t, len(got), 1, "one variationSelected event")
			eq(t, got[0].Variation, v, "the broadcast names it")
			eq(t, got[0].UserID, chooser, "and who chose")
			eq(t, got[0].SelectedBy, VariationByPlayer, "and how")

			for _, id := range ids {
				w := h.window(id)
				eq(t, w.Selecting, false, id+" sees the window closed")
				if w.Selected == nil || *w.Selected != v {
					t.Fatalf("%s's snapshot selected = %v, want %s", id, w.Selected, v)
				}
				eq(t, w.TurnUp != nil, v.UsesTurnUp(), id+": turn-up card visibility")
			}

			// Play begins: the chooser is on turn with a full, fresh clock.
			eq(t, h.turnUser(), chooser, "the chooser gets the first turn")
			turns := h.rec.all("turn")
			eq(t, len(turns), 1, "one turn event, after the choice")
			eq(t, turns[0].(TurnEvent).TimeoutMs, int64(25_000), "a full turn clock")
		})
	}
}

func TestTheTurnUpCardIsNeverOnTheWireUnlessItDecidesTheHand(t *testing.T) {
	h, ids, chooser := variationTable(t, 3)
	h.setTurnUp("9h")

	snapshotsMention := func(code string) bool {
		for _, id := range ids {
			if strings.Contains(mustJSON(t, h.view(id)), `"`+code+`"`) {
				return true
			}
		}
		return false
	}
	if snapshotsMention("9h") {
		t.Fatal("the turned-up card is in a snapshot while the window is open")
	}
	if _, err := h.table.SelectVariation(chooser, string(VariationAK47)); err != nil {
		t.Fatal(err)
	}
	if snapshotsMention("9h") {
		t.Fatal("AK47 does not use the turned-up card, yet a snapshot shows it")
	}
	if e := h.selected()[0]; e.TurnUp != nil {
		t.Fatalf("AK47's broadcast carries a turn-up card: %v", *e.TurnUp)
	}
}

// ------------------------------------------------------------- the timeout

func TestWhenNobodyChoosesForTenSecondsTheServerChoosesMuflis(t *testing.T) {
	h, ids, chooser := variationTable(t, 3)

	h.advance(variationWindowMS - time.Millisecond)
	eq(t, h.chooser(), chooser, "a millisecond short of the deadline the window is still open")
	eq(t, len(h.selected()), 0, "and nothing has been chosen")

	h.advance(time.Millisecond)
	got := h.selected()
	eq(t, len(got), 1, "the server chose at the deadline")
	eq(t, got[0].Variation, VariationMuflis, "Muflis")
	eq(t, got[0].SelectedBy, VariationByTimeout, "by timeout")
	eq(t, got[0].UserID, chooser, "still attributed to the chooser's window")

	for _, id := range ids {
		w := h.window(id)
		if w.Selecting || w.Selected == nil || *w.Selected != VariationMuflis || *w.SelectedBy != VariationByTimeout {
			t.Fatalf("%s's snapshot after the timeout: %+v", id, w)
		}
	}

	// The lapse is not a missed turn: they get their ordinary turn, full clock.
	eq(t, h.turnUser(), chooser, "the chooser is on turn")
	eq(t, h.mustSeat(chooser).MissedTurns, 0, "letting the window lapse is not a missed turn")
}

func TestASelectionAfterTheTimeoutIsRefusedAndChangesNothing(t *testing.T) {
	h, _, chooser := variationTable(t, 3)
	h.advance(variationWindowMS)

	_, err := h.table.SelectVariation(chooser, string(VariationAK47))
	codeIs(t, err, CodeVariationAlreadySelected)
	eq(t, len(h.selected()), 1, "still exactly one choice")
	eq(t, *h.window(chooser).Selected, VariationMuflis, "and it is still the server's")
}

func TestAPickThatReachesTheTablePastTheDeadlineLosesToTheClock(t *testing.T) {
	// The deadline is the server's even in the instant where the timer's own
	// callback has not run yet. Stopping the timer by hand puts the table in
	// exactly that instant: past the deadline, window still open.
	h, _, chooser := variationTable(t, 3)
	h.read(func() { h.table.stopVariationTimer() })
	h.advance(variationWindowMS + time.Second)
	eq(t, h.chooser(), chooser, "the window is still open: its timer never fired")

	_, err := h.table.SelectVariation(chooser, string(VariationAK47))
	codeIs(t, err, CodeVariationExpired)

	got := h.selected()
	eq(t, len(got), 1, "the late pick made the server's choice happen now")
	eq(t, got[0].Variation, VariationMuflis, "Muflis, not the late AK47")
	eq(t, got[0].SelectedBy, VariationByTimeout, "by timeout")
	eq(t, h.turnUser(), chooser, "and play has begun")
}

// ----------------------------------------------------------- authorisation

func TestOnlyTheChooserMayChoose(t *testing.T) {
	h, ids, chooser := variationTable(t, 4)
	for _, id := range except(ids, chooser) {
		_, err := h.table.SelectVariation(id, string(VariationAK47))
		codeIs(t, err, CodeNotSelecting)
	}
	eq(t, h.chooser(), chooser, "the window is untouched")
	eq(t, len(h.selected()), 0, "and nothing was chosen")
}

func TestAPlayerWhoIsNotAtTheTableCannotChoose(t *testing.T) {
	h, _, _ := variationTable(t, 3)
	_, err := h.table.SelectVariation("stranger", string(VariationAK47))
	codeIs(t, err, CodeNotSeated)
	eq(t, len(h.selected()), 0, "nothing was chosen")
}

func TestAPlayerSittingTheHandOutCannotChoose(t *testing.T) {
	h, _, _ := variationTable(t, 3)
	h.seatNamed("late", "LATE", sideshowStart) // seated mid-hand: waiting
	_, err := h.table.SelectVariation("late", string(VariationAK47))
	codeIs(t, err, CodeNotSelecting)
}

func TestAnythingButTheSixCanonicalNamesIsRefused(t *testing.T) {
	h, _, chooser := variationTable(t, 3)
	for _, raw := range []string{"", "muflis", "Muflis", "Lowest Joker", "Lowest Joke", "LowestJoker", "CLASSIC", "null", "undefined", "AK47 ", "[object Object]"} {
		_, err := h.table.SelectVariation(chooser, raw)
		codeIs(t, err, CodeInvalidVariation)
	}
	eq(t, h.chooser(), chooser, "a refused name leaves the window open for a valid one")
	if _, err := h.table.SelectVariation(chooser, string(VariationHukam)); err != nil {
		t.Fatalf("a valid pick after refused ones: %v", err)
	}
}

func TestASecondSelectionIsRefusedAndTheFirstStands(t *testing.T) {
	h, ids, chooser := variationTable(t, 3)
	if _, err := h.table.SelectVariation(chooser, string(VariationAK47)); err != nil {
		t.Fatal(err)
	}
	// By the chooser again, by anyone else, with the same name or another.
	for _, id := range ids {
		for _, v := range []Variation{VariationAK47, VariationMuflis} {
			_, err := h.table.SelectVariation(id, string(v))
			codeIs(t, err, CodeVariationAlreadySelected)
		}
	}
	eq(t, len(h.selected()), 1, "exactly one choice was ever made")
	eq(t, *h.window(chooser).Selected, VariationAK47, "the first")
}

func TestASeenTableHasNoWindowAndRefusesASelection(t *testing.T) {
	h := newHarness(t, sideshowConfig(), withLedger(emptyLedger))
	h.seat("a", sideshowStart)
	h.seat("b", sideshowStart)
	h.advance(sideshowConfig().NextHandDelay)
	eq(t, h.handNo(), 1, "dealt")

	_, err := h.table.SelectVariation("a", string(VariationAK47))
	codeIs(t, err, CodeNoVariation)
	if w := h.window("a"); w != nil {
		t.Fatalf("a seen table's snapshot has a variation block: %+v", w)
	}
	// And the key is ABSENT, not null: the seen snapshot is byte for byte what
	// it was before variation tables existed.
	if strings.Contains(mustJSON(t, h.view("a")), "variation") {
		t.Fatal(`a seen table's room:state mentions "variation"`)
	}
	if got := len(h.rec.all("variationSelecting")); got != 0 {
		t.Fatalf("a seen table announced %d variation window(s)", got)
	}
	if h.turnUser() == "" {
		t.Fatal("a seen table's deal must go straight to a turn")
	}
}

func TestNoHandNoSelection(t *testing.T) {
	h := newHarness(t, variationConfig(), withLedger(emptyLedger))
	h.seat("a", sideshowStart)
	_, err := h.table.SelectVariation("a", string(VariationAK47))
	codeIs(t, err, CodeNoHand)
}

func TestNoMoveIsAllowedWhileTheVariationIsBeingChosenExceptALookAtYourCards(t *testing.T) {
	h, ids, chooser := variationTable(t, 3)
	for _, id := range ids {
		for _, action := range []Action{ActionChaal, ActionRaise, ActionPack, ActionShow, ActionSideshow, ActionForceSideshow, ActionMissile} {
			_, err := h.act(id, action, ActRequest{})
			codeIs(t, err, CodeVariationPending)
		}
	}
	eq(t, h.chooser(), chooser, "the window is untouched by refused moves")

	// Seeing is not a move; the chooser may well want to look before deciding.
	h.mustAct(chooser, ActionSee, ActRequest{})
	eq(t, h.mustSeat(chooser).IsBlind, false, "the chooser has seen their cards")
	eq(t, h.chooser(), chooser, "and the window is still open")
	if got := len(h.rec.all("turn")); got != 0 {
		t.Fatalf("a look during the window issued %d turn event(s)", got)
	}
}

// ---------------------------------------------------------------- the race

func TestAPickAndTheTimeoutArrivingTogetherChooseExactlyOnce(t *testing.T) {
	// The brief's race: the player picks AK47 in the same instant the clock
	// chooses Muflis. Both are closures on the table's actor, so one of them
	// runs first and closes the window and the other finds it closed. Run it
	// many times, releasing the two from different goroutines at once: whoever
	// wins, there is one choice, one broadcast, and a state that agrees.
	wins := map[Variation]int{}
	for i := 0; i < 200; i++ {
		h, ids, chooser := variationTable(t, 3)
		h.advance(variationWindowMS - time.Millisecond)

		var wg sync.WaitGroup
		start := make(chan struct{})
		var pickErr error
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-start
			_, pickErr = h.table.SelectVariation(chooser, string(VariationAK47))
		}()
		go func() {
			defer wg.Done()
			<-start
			// The fake clock is far quicker off the mark than a call through
			// the actor, so on alternate runs the clock gives way first —
			// otherwise "together" would nearly always mean "clock first".
			if i%2 == 0 {
				for spin := 0; spin < 50; spin++ {
					runtime.Gosched()
				}
			}
			h.advance(time.Millisecond)
		}()
		close(start)
		wg.Wait()

		got := h.selected()
		if len(got) != 1 {
			t.Fatalf("run %d: %d variationSelected events, want exactly 1: %+v", i, len(got), got)
		}
		chosen := got[0]
		switch {
		case pickErr == nil:
			// The pick won: it must be the player's AK47 everywhere.
			eq(t, chosen.Variation, VariationAK47, "the pick was acked, so the choice is the player's")
			eq(t, chosen.SelectedBy, VariationByPlayer, "by the player")
		default:
			// The clock won: the pick was refused and the choice is the server's.
			if code := CodeOf(pickErr, ""); code != CodeVariationAlreadySelected && code != CodeVariationExpired {
				t.Fatalf("run %d: the losing pick was refused with %q", i, code)
			}
			eq(t, chosen.Variation, VariationMuflis, "the pick was refused, so the choice is the server's")
			eq(t, chosen.SelectedBy, VariationByTimeout, "by timeout")
		}
		for _, id := range ids {
			w := h.window(id)
			if w.Selecting || w.Selected == nil || *w.Selected != chosen.Variation || *w.SelectedBy != chosen.SelectedBy {
				t.Fatalf("run %d: %s's snapshot %+v disagrees with the broadcast %+v", i, id, w, chosen)
			}
		}
		eq(t, len(h.rec.all("turn")), 1, "the chooser was given the turn once, not twice")
		eq(t, h.turnUser(), chooser, "and holds it")
		wins[chosen.Variation]++
		_ = h.table.Destroy()
	}
	t.Logf("pick won %d, clock won %d", wins[VariationAK47], wins[VariationMuflis])
}

func TestManyPicksAtOnceChooseExactlyOnce(t *testing.T) {
	h, _, chooser := variationTable(t, 3)
	var wg sync.WaitGroup
	start := make(chan struct{})
	accepted := make(chan Variation, len(Variations)*4)
	for round := 0; round < 4; round++ {
		for _, v := range Variations {
			wg.Add(1)
			go func(v Variation) {
				defer wg.Done()
				<-start
				if _, err := h.table.SelectVariation(chooser, string(v)); err == nil {
					accepted <- v
				}
			}(v)
		}
	}
	close(start)
	wg.Wait()
	close(accepted)

	var acked []Variation
	for v := range accepted {
		acked = append(acked, v)
	}
	eq(t, len(acked), 1, "exactly one of the concurrent picks was accepted")
	eq(t, len(h.selected()), 1, "and exactly one was broadcast")
	eq(t, h.selected()[0].Variation, acked[0], "the same one")
}

// ------------------------------------------------ the hand is decided by it

// showdownUnder plays a two-player variation hand to a show under v and
// returns who won. a holds the classically STRONGER hand.
func showdownUnder(t *testing.T, v Variation, turnUp string, aCards, bCards []string) (winner string, ended HandEndedEvent, h *harness) {
	t.Helper()
	h, ids, chooser := variationTable(t, 2)
	a, b := ids[0], ids[1]
	h.setCards(a, aCards...)
	h.setCards(b, bCards...)
	if turnUp != "" {
		h.setTurnUp(turnUp)
	}
	if _, err := h.table.SelectVariation(chooser, string(v)); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		h.mustAct(id, ActionSee, ActRequest{})
	}
	h.mustAct(h.turnUser(), ActionShow, ActRequest{})
	ended = h.lastEnded()
	if ended.WinnerID == nil {
		t.Fatal("the show produced no winner")
	}
	return *ended.WinnerID, ended, h
}

func TestTheSameTwoHandsAreWonByDifferentPlayersUnderDifferentVariations(t *testing.T) {
	trail, scraps := []string{"Qs", "Qh", "Qd"}, []string{"5s", "3h", "2d"}

	winner, ended, _ := showdownUnder(t, VariationHukam, "9c", trail, scraps)
	eq(t, winner, "p0", "with no club in either hand Hukam is classic: the trail wins")
	eq(t, ended.Variation, VariationHukam, "handEnded names the rules")
	if ended.TurnUp == nil || *ended.TurnUp != "9c" {
		t.Fatalf("handEnded turnUp = %v, want 9c", ended.TurnUp)
	}

	winner, ended, _ = showdownUnder(t, VariationMuflis, "", trail, scraps)
	eq(t, winner, "p1", "under Muflis 5-3-2 beats a trail of queens")
	eq(t, ended.Variation, VariationMuflis, "handEnded names the rules")
	if ended.TurnUp != nil {
		t.Fatalf("Muflis has no turn-up card, handEnded carries %v", *ended.TurnUp)
	}
}

func TestAShowdownRevealsWhatEachHandMadeAndWhichCardsWereWild(t *testing.T) {
	// AK47: 4-7-2 is a trail of twos and beats a queen-high color.
	winner, ended, h := showdownUnder(t, VariationAK47, "", []string{"Qs", "9s", "2s"}, []string{"4h", "7d", "2c"})
	eq(t, winner, "p1", "the wild hand wins")

	reveal := map[string]Reveal{}
	for _, r := range ended.Reveals {
		reveal[r.UserID] = r
	}
	eq(t, reveal["p1"].HandName, "Trail", "the reveal names what the hand MADE")
	eq(t, reveal["p1"].Category, Trail, "and its category")
	eq(t, strings.Join(reveal["p1"].Cards, " "), "4h 7d 2c", "but shows the cards really held")
	eq(t, strings.Join(reveal["p1"].Wild, " "), "4h 7d", "and which of them were wild")
	eq(t, reveal["p0"].HandName, "Color", "the natural hand is what it always was")
	eq(t, len(reveal["p0"].Wild), 0, "with nothing wild")

	showdown := h.rec.last("showdown").(ShowdownEvent)
	eq(t, showdown.Variation, VariationAK47, "game:showdown names the rules too")
}

func TestJokerIsDecidedByTheRankOfTheTurnedUpCard(t *testing.T) {
	// Nines are wild: 9-9-2 is a trail of twos and beats a pair of aces.
	winner, _, _ := showdownUnder(t, VariationJoker, "9d", []string{"As", "Ah", "5d"}, []string{"9s", "9h", "2c"})
	eq(t, winner, "p1", "the two jokers win")
}

func TestLowestAndHighestJokerAreDecidedPerHand(t *testing.T) {
	// 3-8-K v 2-2-9.
	//   Lowest:  p0's 3 is wild → pair of kings; p1's twos are wild → trail of nines. p1 wins.
	//   Highest: p0's K is wild → pair of eights; p1's 9 is wild → trail of twos.     p1 wins.
	// and classically p1's pair of twos beats king-high too, so use a hand where
	// the two differ: 3-8-K v 5-6-Q.
	//   Lowest:  K-K-8 (pair K) v Q-Q-6 (pair Q)            → p0
	//   Highest: 8-8-3 (pair 8) v 5-6-7 sequence            → p1
	a, b := []string{"3s", "8h", "Kd"}, []string{"5c", "6d", "Qh"}
	winner, _, _ := showdownUnder(t, VariationLowestJoker, "", a, b)
	eq(t, winner, "p0", "Lowest Joker: a pair of kings beats a pair of queens")
	winner, _, _ = showdownUnder(t, VariationHighestJoker, "", a, b)
	eq(t, winner, "p1", "Highest Joker: the run beats a pair of eights")
}

func TestASideshowIsDecidedByTheChosenVariation(t *testing.T) {
	h, ids, chooser := variationTable(t, 3)
	if _, err := h.table.SelectVariation(chooser, string(VariationMuflis)); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		h.mustAct(id, ActionSee, ActRequest{})
	}
	asker := h.turnUser()
	var asked string
	h.read(func() {
		s := h.table.findSeat(asker)
		asked = h.table.seats[h.table.rightActiveSeat(s.seatIndex)].userID
	})
	h.setCards(asker, "5s", "3h", "2d") // the best Muflis hand
	h.setCards(asked, "Qs", "Qh", "Qd") // the classic winner

	h.mustAct(asker, ActionSideshow, ActRequest{})
	outcome, err := h.table.RespondToSideshow(asked, true)
	if err != nil {
		t.Fatal(err)
	}
	if outcome.PackedUserID == nil || *outcome.PackedUserID != asked {
		t.Fatalf("packed = %v, want the trail of queens (%s): it loses under Muflis", outcome.PackedUserID, asked)
	}
}

func TestAnExactTieStillGoesAgainstTheShowPayerUnderAVariation(t *testing.T) {
	h, ids, chooser := variationTable(t, 2)
	h.setCards(ids[0], "Qs", "8h", "3d")
	h.setCards(ids[1], "Qh", "8d", "3c")
	if _, err := h.table.SelectVariation(chooser, string(VariationMuflis)); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		h.mustAct(id, ActionSee, ActRequest{})
	}
	payer := h.turnUser()
	h.mustAct(payer, ActionShow, ActRequest{})
	if got := *h.lastEnded().WinnerID; got == payer {
		t.Fatalf("the show-payer %s won an exact tie", payer)
	}
}

// --------------------------------------------------------------- lifecycle

func TestWhenTheChooserLeavesTheServerChoosesAndPlayMovesOn(t *testing.T) {
	h, ids, chooser := variationTable(t, 3)
	h.remove(chooser, "left")

	got := h.selected()
	eq(t, len(got), 1, "the table did not wait out the clock")
	eq(t, got[0].Variation, VariationMuflis, "the server chose Muflis")
	eq(t, got[0].SelectedBy, VariationByLeft, "because the chooser left")
	eq(t, got[0].UserID, chooser, "still attributed to their window")
	eq(t, got[0].DisplayName, strings.ToUpper(chooser), "with the name they had")

	next := h.turnUser()
	if next == "" || next == chooser {
		t.Fatalf("turn = %q after the chooser left", next)
	}
	remaining := except(ids, chooser)
	if next != remaining[0] && next != remaining[1] {
		t.Fatalf("turn went to %q, not a player still in the hand", next)
	}
	eq(t, h.hasHand(), true, "two players remain, so the hand goes on")

	// The window's clock died with it: ten seconds later nothing else happens.
	h.advance(variationWindowMS)
	eq(t, len(h.selected()), 1, "no second choice")
}

func TestWhenAnotherPlayerLeavesTheWindowStaysOpen(t *testing.T) {
	h, ids, chooser := variationTable(t, 3)
	h.remove(except(ids, chooser)[0], "left")
	eq(t, h.chooser(), chooser, "the chooser is still choosing")
	eq(t, len(h.selected()), 0, "nothing was chosen for them")
	if _, err := h.table.SelectVariation(chooser, string(VariationJoker)); err != nil {
		t.Fatal(err)
	}
}

func TestADisconnectedChooserIsTimedOutByTheServerNotLeftHanging(t *testing.T) {
	h, _, chooser := variationTable(t, 3)
	if _, err := h.table.SetConnected(chooser, false, ""); err != nil {
		t.Fatal(err)
	}
	eq(t, h.chooser(), chooser, "a disconnect alone changes nothing: the seat is held")
	h.advance(variationWindowMS)
	got := h.selected()
	eq(t, len(got), 1, "the server's clock does not need the client")
	eq(t, got[0].SelectedBy, VariationByTimeout, "by timeout")
	eq(t, h.turnUser(), chooser, "and their turn clock now runs like anyone's")
}

func TestTheHandEndingDuringTheWindowKillsItsClock(t *testing.T) {
	h, ids, chooser := variationTable(t, 2)
	h.remove(except(ids, chooser)[0], "left")

	ended := h.lastEnded()
	eq(t, *ended.WinnerID, chooser, "the chooser is last standing")
	eq(t, ended.Variation, Variation(""), "no variation was ever chosen for that hand")
	eq(t, len(h.selected()), 0, "and none is announced after the fact")

	before := h.rec.count()
	h.advance(variationWindowMS)
	if got := len(h.selected()); got != 0 {
		t.Fatalf("the dead hand's window fired: %d selection(s)", got)
	}
	_ = before
}

func TestDestroyingTheTableDuringTheWindowStopsItsClock(t *testing.T) {
	h, _, _ := variationTable(t, 3)
	if err := h.table.Destroy(); err != nil {
		t.Fatal(err)
	}
	h.advance(variationWindowMS * 2)
	eq(t, len(h.selected()), 0, "a destroyed table chooses nothing")
}

func TestEveryHandOpensWithACleanWindowForTheNextChooser(t *testing.T) {
	h, ids, first := variationTable(t, 3)
	if _, err := h.table.SelectVariation(first, string(VariationAK47)); err != nil {
		t.Fatal(err)
	}
	// End hand 1: everyone but one packs.
	for len(h.activeIDs()) > 1 {
		h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	}
	eq(t, h.hasHand(), false, "hand 1 is over")
	if w := h.window(ids[0]); w != nil {
		t.Fatalf("between hands the snapshot still carries a variation block: %+v", w)
	}

	h.advance(variationConfig().NextHandDelay)
	eq(t, h.handNo(), 2, "hand 2 is dealt")
	second := h.chooser()
	if second == "" {
		t.Fatal("hand 2 opened no window")
	}
	if second == first {
		t.Fatalf("the dealer moved on, yet %s chooses again", first)
	}
	w := h.window(second)
	if !w.Selecting || w.Selected != nil || w.SelectedBy != nil || w.TurnUp != nil {
		t.Fatalf("hand 2's window is not clean: %+v", w)
	}
	eq(t, len(h.rec.all("variationSelecting")), 2, "one announcement per hand")
}

// ------------------------------------------------ restart (the live store)

func TestARestartDuringTheWindowKeepsTheChooserTheDeadlineAndTheCard(t *testing.T) {
	h, ids, chooser := variationTable(t, 3)
	h.setTurnUp("9h")
	h.advance(4 * time.Second)
	deadline := *h.window(chooser).Deadline

	snap := roundTrip(t, mustSnapshot(h))
	clock := newFakeClock(h.clock.Now().Add(2 * time.Second)) // two seconds "down"
	r := restoreHarness(t, snap, clock, withLedger(emptyLedger))

	for _, id := range ids {
		w := r.window(id)
		if w == nil || !w.Selecting {
			t.Fatalf("%s: the restored table has no open window: %+v", id, w)
		}
		eq(t, w.UserID, chooser, id+" still sees who is choosing")
		eq(t, *w.Deadline, deadline, id+" sees the SAME deadline, not a fresh ten seconds")
	}
	eq(t, r.turnSeat(), -1, "and play has not been opened behind the chooser's back")
	eq(t, len(r.rec.all("turn")), 0, "no turn was issued by the restore")

	// Four seconds are left of the ten.
	r.advance(4*time.Second - time.Millisecond)
	eq(t, r.chooser(), chooser, "still open just short of the original deadline")
	r.advance(time.Millisecond)
	got := r.selected()
	eq(t, len(got), 1, "the re-armed clock chose at the original deadline")
	eq(t, got[0].SelectedBy, VariationByTimeout, "by timeout")

	// The turned-up card survived: a Hukam chosen after a restart is still hearts.
	var turnUp string
	r.read(func() { turnUp = r.table.hand.variation.turnUp.Code() })
	eq(t, turnUp, "9h", "the card drawn at the deal came back with the table")
}

func TestARestartAfterTheDeadlineChoosesAtOnce(t *testing.T) {
	h, _, chooser := variationTable(t, 3)
	snap := roundTrip(t, mustSnapshot(h))
	clock := newFakeClock(h.clock.Now().Add(time.Minute))
	r := restoreHarness(t, snap, clock, withLedger(emptyLedger))

	got := r.selected()
	eq(t, len(got), 1, "the window lapsed while the process was down")
	eq(t, got[0].Variation, VariationMuflis, "Muflis")
	eq(t, got[0].SelectedBy, VariationByTimeout, "by timeout")
	eq(t, r.turnUser(), chooser, "and the chooser is on turn")
}

func TestARestartAfterTheChoiceKeepsTheRules(t *testing.T) {
	h, ids, chooser := variationTable(t, 2)
	h.setTurnUp("9d")
	h.setCards(ids[0], "As", "Ah", "5d")
	h.setCards(ids[1], "9s", "9h", "2c")
	if _, err := h.table.SelectVariation(chooser, string(VariationJoker)); err != nil {
		t.Fatal(err)
	}

	r := restoreHarness(t, roundTrip(t, mustSnapshot(h)), newFakeClock(h.clock.Now()), withLedger(emptyLedger))
	w := r.window(chooser)
	if w == nil || w.Selecting || *w.Selected != VariationJoker || w.TurnUp == nil || *w.TurnUp != "9d" {
		t.Fatalf("restored window = %+v, want JOKER on 9d, closed", w)
	}
	eq(t, len(r.selected()), 0, "a restore announces no choice a second time")

	for _, id := range ids {
		r.mustAct(id, ActionSee, ActRequest{})
	}
	r.mustAct(r.turnUser(), ActionShow, ActRequest{})
	eq(t, *r.lastEnded().WinnerID, ids[1], "the restored hand is still decided by nines being wild")
}

func TestAVariationSnapshotRoundTripsLosslessly(t *testing.T) {
	h, _, chooser := variationTable(t, 3)
	check := func(step string) {
		t.Helper()
		snap := mustSnapshot(h)
		r := restoreHarness(t, roundTrip(t, snap), newFakeClock(h.clock.Now()), withLedger(emptyLedger))
		again := mustSnapshot(r)
		again.Seq = snap.Seq
		if a, b := mustJSON(t, snap.Hand.Variation), mustJSON(t, again.Hand.Variation); a != b {
			t.Fatalf("%s: variation changed across a restore:\n was %s\n now %s", step, a, b)
		}
	}
	check("window open")
	if _, err := h.table.SelectVariation(chooser, string(VariationHukam)); err != nil {
		t.Fatal(err)
	}
	check("window closed")
}

func TestARestoreRefusesAWindowItCannotRebuild(t *testing.T) {
	h, _, _ := variationTable(t, 3)
	base := roundTrip(t, mustSnapshot(h))

	mutate := func(fn func(w *SnapshotVariation)) *Snapshot {
		copied := roundTrip(t, base)
		fn(copied.Hand.Variation)
		return copied
	}
	bad := map[string]*Snapshot{
		"a chooser who is not at that seat": mutate(func(w *SnapshotVariation) { w.ChooserID = "nobody" }),
		"a chooser seat out of range":       mutate(func(w *SnapshotVariation) { w.ChooserSeat = 9 }),
		"a turn-up that is not a card":      mutate(func(w *SnapshotVariation) { w.TurnUp = "ZZ" }),
		"open yet already selected":         mutate(func(w *SnapshotVariation) { w.Selected = VariationAK47 }),
		"an unknown variation": mutate(func(w *SnapshotVariation) {
			w.Open = false
			w.Selected = "SEPIA"
		}),
	}
	for name, snap := range bad {
		if _, err := RestoreTable(snap, TableOptions{Ledger: emptyLedger(h), Clock: newFakeClock(h.clock.Now())}); err == nil {
			t.Errorf("%s: the snapshot was restored", name)
		}
	}
}

func TestAVariationTableKeepsItsCategoryAcrossARestore(t *testing.T) {
	// NewTable normalises the category, and it is also where a restored table
	// gets its category back. Rewritten to seen there, a variation table would
	// come back from a restart dealing classic hands with nothing to say why.
	h, _, _ := variationTable(t, 2)
	r := restoreHarness(t, roundTrip(t, mustSnapshot(h)), newFakeClock(h.clock.Now()), withLedger(emptyLedger))
	eq(t, r.table.Category(), CategoryVariation, "the restored table is still a variation table")
	eq(t, r.table.Config().VariationSelectTimeout, variationWindowMS, "with its window's length")
}

// ------------------------------------------------------------ the category

// Owner, 18 Sep 2026: "in variation all players are able to see each other's
// amounts, which should not be — keep the same thing as the blind table, that
// no one can see another player's amount."
func TestAVariationTableHidesEveryoneElsesStackLikeABlindOne(t *testing.T) {
	h, ids, _ := variationTable(t, 3)
	for _, viewer := range ids {
		view := h.view(viewer)
		eq(t, view.ChipsHidden, true, "chips are hidden")
		eq(t, view.Category, CategoryVariation, "the snapshot names the category")
		eq(t, view.You.Chips > 0, true, "a player still sees their own stack")
		for _, s := range view.Seats {
			if s.Empty {
				continue
			}
			if s.UserID == viewer {
				if s.Chips == nil {
					t.Fatalf("%s cannot see their own stack", viewer)
				}
				continue
			}
			// null, never 0: a withheld stack is not an empty one.
			if s.Chips != nil {
				t.Fatalf("%s can see %s's stack (%d) on a variation table", viewer, s.UserID, *s.Chips)
			}
		}
	}
	raw := mustJSON(t, h.view(ids[0]))
	if !strings.Contains(raw, `"chipsHidden":true`) {
		t.Fatalf("chipsHidden is not on the wire: %s", raw)
	}
	// Nobody at the table is sent another player's stack in any form.
	spectator := h.view("")
	for _, s := range spectator.Seats {
		if !s.Empty && s.Chips != nil {
			t.Fatalf("a spectator can see %s's stack", s.UserID)
		}
	}
}

// ------------------------------------------------ what your own cards make

// Owner, 18 Sep 2026: once a player has seen their cards the client turns
// their wild cards into what they played as. It can only do that if the server
// says what that was — privately, to that player alone.
func TestYourOwnHandIsNamedOnceYouHaveSeenItAndTheVariationIsChosen(t *testing.T) {
	h, ids, chooser := variationTable(t, 3)
	h.setCards(chooser, "Jh", "Qs", "4s") // under AK47 the 4 is wild: J-Q-K

	// Dealt, blind, window open: nothing.
	if you := h.view(chooser).You; you.Hand != nil {
		t.Fatalf("a blind player was told their hand: %+v", you.Hand)
	}
	// Seen during the window, no variation yet: the cards, and still nothing —
	// there is no rule to count them by.
	h.mustAct(chooser, ActionSee, ActRequest{})
	you := h.view(chooser).You
	eq(t, len(you.Cards), 3, "the cards are face up")
	if you.Hand != nil {
		t.Fatalf("a hand was named before the variation was chosen: %+v", you.Hand)
	}

	// The choice lands: the hand is named at once, with nothing more to do.
	if _, err := h.table.SelectVariation(chooser, "AK47"); err != nil {
		t.Fatal(err)
	}
	hand := h.view(chooser).You.Hand
	if hand == nil {
		t.Fatal("no hand after the variation was chosen")
	}
	eq(t, hand.HandName, "Sequence", "J-Q and a wild 4 make a run")
	eq(t, strings.Join(hand.Wild, ","), "4s", "which card played wild")
	eq(t, len(hand.PlaysAs), 3, "three cards, index for index")
	eq(t, hand.PlaysAs[0], "Jh", "a natural card is itself")
	eq(t, hand.PlaysAs[1], "Qs", "a natural card is itself")
	if hand.PlaysAs[2][0] != 'K' {
		t.Fatalf("the wild 4 should have stood for a king, got %s", hand.PlaysAs[2])
	}

	// It is that player's alone: nobody else's snapshot carries it or the cards.
	for _, other := range ids {
		if other == chooser {
			continue
		}
		raw := mustJSON(t, h.view(other))
		for _, leak := range []string{`"playsAs"`, `"4s"`, `"Jh"`, `"Qs"`, "Sequence"} {
			if strings.Contains(raw, leak) {
				t.Fatalf("%s's snapshot leaks %s of %s's hand", other, leak, chooser)
			}
		}
		if h.view(other).You.Hand != nil {
			t.Fatalf("%s is blind and was told a hand", other)
		}
	}
}

func TestAHandWithNoWildCardPlaysAsItself(t *testing.T) {
	h, _, chooser := variationTable(t, 2)
	h.setCards(chooser, "9h", "8d", "2c")
	h.mustAct(chooser, ActionSee, ActRequest{})
	if _, err := h.table.SelectVariation(chooser, "AK47"); err != nil {
		t.Fatal(err)
	}
	hand := h.view(chooser).You.Hand
	if hand == nil {
		t.Fatal("no hand")
	}
	eq(t, hand.HandName, "High Card", "nothing wild in 9-8-2")
	eq(t, len(hand.Wild), 0, "no wild card")
	eq(t, strings.Join(hand.PlaysAs, ","), "9h,8d,2c", "the cards as they are")
	// [] on the wire, never null: the client reads both as lists.
	raw := mustJSON(t, h.view(chooser))
	if !strings.Contains(raw, `"wild":[]`) || !strings.Contains(raw, `"playsAs":["9h","8d","2c"]`) {
		t.Fatalf("wire shape: %s", raw)
	}
}

func TestEveryWildVariationSaysWhatYourCardsPlayAs(t *testing.T) {
	for _, tc := range []struct {
		variation string
		turnUp    string
		cards     []string
		wild      string
		name      string
	}{
		{"AK47", "", []string{"Ah", "Kd", "7c"}, "Ah,Kd,7c", "Trail"},
		{"JOKER", "9d", []string{"9h", "5s", "5c"}, "9h", "Trail"},
		{"HUKAM", "2h", []string{"8h", "Qs", "Js"}, "8h", "Pure Sequence"},
		{"LOWEST_JOKER", "", []string{"3h", "8d", "Ks"}, "3h", "Pair"},
		{"HIGHEST_JOKER", "", []string{"3h", "8d", "Ks"}, "Ks", "Pair"},
		{"MUFLIS", "", []string{"Ah", "Kd", "7c"}, "", "High Card"},
	} {
		h, _, chooser := variationTable(t, 2)
		if tc.turnUp != "" {
			h.setTurnUp(tc.turnUp)
		}
		h.setCards(chooser, tc.cards...)
		h.mustAct(chooser, ActionSee, ActRequest{})
		if _, err := h.table.SelectVariation(chooser, tc.variation); err != nil {
			t.Fatalf("%s: %v", tc.variation, err)
		}
		hand := h.view(chooser).You.Hand
		if hand == nil {
			t.Fatalf("%s: no hand", tc.variation)
		}
		eq(t, hand.HandName, tc.name, tc.variation+": what the hand made")
		eq(t, strings.Join(hand.Wild, ","), tc.wild, tc.variation+": which cards were wild")
		eq(t, len(hand.PlaysAs), 3, tc.variation+": three cards")
		// A stand-in is never a card the hand already holds, and a natural
		// card is always itself.
		held := map[string]bool{}
		for _, c := range tc.cards {
			held[c] = true
		}
		wild := map[string]bool{}
		for _, c := range hand.Wild {
			wild[c] = true
		}
		for i, c := range tc.cards {
			if !wild[c] && hand.PlaysAs[i] != c {
				t.Fatalf("%s: natural %s plays as %s", tc.variation, c, hand.PlaysAs[i])
			}
		}
		// What it plays as really is the hand it was named.
		if got := Evaluate(ParseCards(hand.PlaysAs), EvaluateOptions{}).Name; got != tc.name {
			t.Fatalf("%s: plays as %v, which is a %s, not a %s", tc.variation, hand.PlaysAs, got, tc.name)
		}
	}
}

func TestASeenTablesYouBlockCarriesNoHand(t *testing.T) {
	h := newHarness(t, sideshowConfig(), withLedger(emptyLedger))
	h.seat("a", sideshowStart)
	h.seat("b", sideshowStart)
	h.advance(sideshowConfig().NextHandDelay)
	h.mustAct("a", ActionSee, ActRequest{})
	if you := h.view("a").You; you.Hand != nil {
		t.Fatalf("a seen table named a hand: %+v", you.Hand)
	}
	if raw := mustJSON(t, h.view("a")); strings.Contains(raw, `"hand":`) || strings.Contains(raw, "playsAs") {
		t.Fatalf("a seen table's you block changed: %s", raw)
	}
}

func TestAWindowThatNeverLapsesStillClosesWhenTheChooserLeaves(t *testing.T) {
	cfg := variationConfig()
	cfg.VariationSelectTimeout = 0
	h := newHarness(t, cfg, withLedger(emptyLedger))
	for _, id := range []string{"a", "b", "c"} {
		h.seat(id, sideshowStart)
	}
	h.advance(cfg.NextHandDelay)
	chooser := h.chooser()
	if w := h.window(chooser); w.Deadline != nil {
		t.Fatalf("a window with no timeout advertises a deadline: %d", *w.Deadline)
	}
	h.advance(time.Hour)
	eq(t, h.chooser(), chooser, "with no timeout the window waits")
	h.remove(chooser, "left")
	eq(t, len(h.selected()), 1, "but never for a player who has gone")
}

func TestTheWireShapeOfTheVariationBlock(t *testing.T) {
	h, _, chooser := variationTable(t, 3)
	h.setTurnUp("9h")

	var open map[string]any
	if err := json.Unmarshal([]byte(mustJSON(t, h.window(chooser))), &open); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"selecting", "userId", "displayName", "seatIndex", "startedAt", "deadline", "timeoutMs", "options", "selected", "selectedBy"} {
		if _, ok := open[key]; !ok {
			t.Errorf("open window lacks %q", key)
		}
	}
	if open["selected"] != nil || open["selectedBy"] != nil {
		t.Errorf("open window: selected/selectedBy must be null, got %v / %v", open["selected"], open["selectedBy"])
	}
	if _, ok := open["turnUp"]; ok {
		t.Error("open window carries turnUp")
	}

	if _, err := h.table.SelectVariation(chooser, string(VariationHukam)); err != nil {
		t.Fatal(err)
	}
	var closed map[string]any
	if err := json.Unmarshal([]byte(mustJSON(t, h.window(chooser))), &closed); err != nil {
		t.Fatal(err)
	}
	eq(t, closed["selecting"], any(false), "selecting")
	eq(t, closed["selected"], any("HUKAM"), "selected")
	eq(t, closed["selectedBy"], any("PLAYER"), "selectedBy")
	eq(t, closed["turnUp"], any("9h"), "turnUp")
}
