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

// fiveCardPickMS is the extra time a 5-Card player gets to choose their three
// on a test table: long enough to be distinct from the variation window above,
// short enough that advancing past it is cheap.
const fiveCardPickMS = 8 * time.Second

func variationConfig() TableConfig {
	cfg := sideshowConfig()
	cfg.Category = CategoryVariation
	cfg.VariationSelectTimeout = variationWindowMS
	cfg.FiveCardPickTimeout = fiveCardPickMS
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
// seam setCards is. The card asked for may already have been dealt (a hand or
// a FIVE_CARD top-up), so it is EXCHANGED for the one that was turned up
// rather than simply written over it: the table keeps 52 distinct cards, and
// a snapshot of it does not carry the same card twice — which
// validateSnapshot refuses, and which made this seam a coin toss on the deal.
func (h *harness) setTurnUp(code string) {
	h.t.Helper()
	want := ParseCard(code)
	h.read(func() {
		hand := h.table.hand
		if hand == nil || hand.variation == nil {
			return
		}
		was := hand.variation.turnUp
		hand.variation.turnUp = want
		if was == want {
			return
		}
		// Idempotent over aliased slices: the second pass over the same
		// backing array finds `want` gone.
		swap := func(cards []Card) {
			for i, c := range cards {
				if c == want {
					cards[i] = was
				}
			}
		}
		for _, s := range h.table.seats {
			if s != nil {
				swap(s.cards)
			}
		}
		for _, c := range hand.contributions {
			swap(c.cards)
		}
		for _, extra := range hand.variation.extra {
			swap(extra)
		}
	})
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
	eq(t, len(e.Options), 7, "seven options")

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
		eq(t, len(w.Options), 7, id+" sees the menu")
		eq(t, w.CardsPerPlayer, 3, id+" is told the hand holds three cards")
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

// ----------------------------------------------------- 5-Card Teen Patti
//
// Owner, 18 Sep 2026. The deal is always three; choosing FIVE_CARD has the
// server top every hand up to five from the same shuffled deck, and every
// comparison is then made on each player's best three.

// extra is the top-up drawn for a player at the deal (server-side only).
func (h *harness) extra(id string) []string {
	var out []string
	h.read(func() {
		if w := h.table.hand.variation; w != nil {
			out = CardCodes(w.extra[id])
		}
	})
	return out
}

// setExtra forces a player's top-up, as setCards forces their hand.
func (h *harness) setExtra(id string, codes ...string) {
	h.t.Helper()
	h.read(func() { h.table.hand.variation.extra[id] = ParseCards(codes) })
}

func TestEveryOtherVariationLeavesEveryHandAtThreeCards(t *testing.T) {
	for _, v := range Variations {
		if v == VariationFiveCard {
			continue
		}
		h, ids, chooser := variationTable(t, 4)
		result, err := h.table.SelectVariation(chooser, string(v))
		if err != nil {
			t.Fatalf("%s: %v", v, err)
		}
		eq(t, result.CardsPerPlayer, 3, string(v)+": the ack says three")
		eq(t, h.selected()[0].CardsPerPlayer, 3, string(v)+": the announcement says three")
		for _, info := range mustSeats(t, h.table) {
			eq(t, len(info.Cards), 3, string(v)+": "+info.UserID+" holds three")
		}
		for _, id := range ids {
			view := h.view(id)
			eq(t, view.Variation.CardsPerPlayer, 3, string(v)+": the snapshot says three")
			for _, s := range view.Seats {
				if !s.Empty {
					eq(t, s.CardCount, 3, string(v)+": cardCount")
				}
			}
		}
		// The top-up that was drawn is dropped, not kept lying about.
		if got := h.extra(chooser); len(got) != 0 {
			t.Fatalf("%s: an undealt top-up survived the choice: %v", v, got)
		}
	}
}

func TestChoosingFiveCardDealsEveryPlayerTwoMoreFromTheSameDeck(t *testing.T) {
	h, ids, chooser := variationTable(t, 5)

	// Before the choice: three each, and the top-up drawn but dealt to nobody.
	before := map[string][]string{}
	dealt := map[string]bool{}
	for _, info := range mustSeats(t, h.table) {
		eq(t, len(info.Cards), 3, info.UserID+" is dealt three")
		before[info.UserID] = CardCodes(info.Cards)
		for _, c := range CardCodes(info.Cards) {
			dealt[c] = true
		}
	}
	tops := map[string][]string{}
	for _, id := range ids {
		tops[id] = h.extra(id)
		eq(t, len(tops[id]), 2, id+" has a top-up of two waiting")
	}

	result, err := h.table.SelectVariation(chooser, "FIVE_CARD")
	if err != nil {
		t.Fatal(err)
	}
	eq(t, result.Variation, VariationFiveCard, "the ack names it")
	eq(t, result.CardsPerPlayer, 5, "and says five")
	eq(t, result.TurnUp == nil, true, "no turned-up card: 5-Card does not use one")
	eq(t, h.selected()[0].CardsPerPlayer, 5, "the announcement says five")

	// After: five each — the three they had, in place, then their own two.
	all := map[string]bool{}
	for _, info := range mustSeats(t, h.table) {
		eq(t, len(info.Cards), 5, info.UserID+" now holds five")
		codes := CardCodes(info.Cards)
		eq(t, strings.Join(codes[:3], " "), strings.Join(before[info.UserID], " "), info.UserID+" keeps the three they were dealt")
		eq(t, strings.Join(codes[3:], " "), strings.Join(tops[info.UserID], " "), info.UserID+" is dealt the two drawn for them")
		for _, c := range codes {
			if all[c] {
				t.Fatalf("%s is on the table twice", c)
			}
			all[c] = true
		}
	}
	eq(t, len(all), 25, "twenty-five different cards for five players")

	// Everyone can see that hands are five now; nobody can see anyone's cards.
	for _, id := range ids {
		view := h.view(id)
		eq(t, view.Variation.CardsPerPlayer, 5, id+": the snapshot says five")
		eq(t, len(view.You.Cards), 0, id+" is still blind: no cards")
		for _, s := range view.Seats {
			if !s.Empty {
				eq(t, s.CardCount, 5, id+" sees cardCount 5 for "+s.UserID)
			}
		}
	}
	// Play begins as after any choice: the chooser on turn, a full clock.
	eq(t, h.turnUser(), chooser, "the chooser opens the betting")
}

func TestTheTopUpIsSecretUntilItIsDealtAndThenOnlyItsOwnersToSee(t *testing.T) {
	h, ids, chooser := variationTable(t, 3)
	// Every hand and every top-up is pinned, not only the chooser's: the test
	// looks for "2c" and "2d" in other people's snapshots, and a random deal
	// puts one of them in somebody's own legitimate hand about one run in
	// eight — which is a player seeing their own card, not a leak.
	hands := [][]string{{"As", "Kd", "9h"}, {"Qs", "Jd", "8h"}, {"Ts", "7d", "6h"}}
	tops := [][]string{{"3c", "3d"}, {"4c", "4d"}, {"5c", "5d"}}
	for i, id := range ids {
		h.setCards(id, hands[i]...)
		h.setExtra(id, tops[i]...)
	}
	h.setExtra(chooser, "2c", "2d")
	h.mustAct(chooser, ActionSee, ActRequest{}) // looking during the window

	// Window open: the chooser sees their three, and the top-up is nowhere.
	for _, id := range ids {
		raw := mustJSON(t, h.view(id))
		if strings.Contains(raw, `"2c"`) || strings.Contains(raw, `"2d"`) || strings.Contains(raw, "extra") {
			t.Fatalf("%s's snapshot shows an undealt top-up: %s", id, raw)
		}
	}
	eq(t, len(h.view(chooser).You.Cards), 3, "three while the window is open")

	if _, err := h.table.SelectVariation(chooser, "FIVE_CARD"); err != nil {
		t.Fatal(err)
	}
	// The player who was already looking is shown all five at once, and sent
	// the same cards event a See sends.
	mine := h.view(chooser).You.Cards
	eq(t, len(mine), 5, "five, without having to look again")
	eq(t, strings.Join(mine[3:], " "), "2c 2d", "their own top-up")
	cardEvents := h.rec.all("cards")
	last := cardEvents[len(cardEvents)-1].(CardsEvent)
	eq(t, last.UserID, chooser, "the cards event is theirs")
	eq(t, len(last.Cards), 5, "and carries all five")
	// Nobody else is sent them, in any form.
	for _, id := range ids {
		if id == chooser {
			continue
		}
		if raw := mustJSON(t, h.view(id)); strings.Contains(raw, `"2c"`) || strings.Contains(raw, `"2d"`) {
			t.Fatalf("%s can see %s's cards", id, chooser)
		}
	}
	// A blind player who looks later gets five too.
	other := ids[0]
	if other == chooser {
		other = ids[1]
	}
	h.mustAct(other, ActionSee, ActRequest{})
	eq(t, len(h.view(other).You.Cards), 5, "a later See shows five")
}

// Under 5-Card the PLAYER picks the three that play (owner, 19 Sep 2026), so
// until they have, their own view names no hand at all: naming it would hand
// them the answer they are being asked for. Once they pick, it names what they
// played and what the best would have been.
func TestYourOwnFiveCardHandIsUnnamedUntilTheyPick(t *testing.T) {
	h, _, chooser := variationTable(t, 2)
	h.setCards(chooser, "As", "7d", "Ks")
	h.setExtra(chooser, "7c", "Qs")
	h.mustAct(chooser, ActionSee, ActRequest{})
	if _, err := h.table.SelectVariation(chooser, "FIVE_CARD"); err != nil {
		t.Fatal(err)
	}

	hand := h.view(chooser).You.Hand
	if hand == nil {
		t.Fatal("no hand")
	}
	eq(t, hand.Picking, true, "a choice is owed")
	eq(t, hand.HandName, "", "and until it is made the hand has no name")
	eq(t, len(hand.Best), 0, "nothing counts yet")
	eq(t, len(hand.BestPossible), 0, "and the answer is not given away")
	if hand.PickDeadline == 0 || hand.PickTimeoutMs <= 0 {
		t.Fatalf("no deadline to choose by: %+v", hand)
	}

	// They pick the pair of sevens over the pure sequence they were dealt.
	out, err := h.table.SelectCards(chooser, []string{"7d", "7c", "As"})
	if err != nil {
		t.Fatal(err)
	}
	eq(t, strings.Join(out.Picked, " "), "As 7d 7c", "kept in the order they are held, not the order tapped")
	eq(t, strings.Join(out.Best, " "), "As Ks Qs", "the best three those five could have made")
	eq(t, out.WasBest, false, "and this was not it")

	hand = h.view(chooser).You.Hand
	eq(t, hand.Picking, false, "the choice is made")
	eq(t, hand.HandName, "Pair", "the hand is what they played")
	eq(t, strings.Join(hand.Best, " "), "As 7d 7c", "those three count")
	eq(t, strings.Join(hand.BestPossible, " "), "As Ks Qs", "and they are told what they missed")
	eq(t, hand.PickedBy, string(PickByPlayer), "by them")
	eq(t, len(hand.PlaysAs), 5, "every card plays as itself")

	// A three-card variation asks nothing and names all three.
	h2, _, c2 := variationTable(t, 2)
	h2.setCards(c2, "9h", "8d", "2c")
	h2.mustAct(c2, ActionSee, ActRequest{})
	if _, err := h2.table.SelectVariation(c2, "MUFLIS"); err != nil {
		t.Fatal(err)
	}
	eq(t, h2.view(c2).You.Hand.Picking, false, "nothing to choose")
	eq(t, strings.Join(h2.view(c2).You.Hand.Best, " "), "9h 8d 2c", "three cards, all three counted")
}

// The window lapses into the first three the player was dealt (owner: "if user
// not able to select cards in extra time then select first 3 cards"), and a
// player who never looks plays those three too.
func TestAFiveCardWindowLapsesIntoTheFirstThree(t *testing.T) {
	h, _, chooser := variationTable(t, 2)
	h.setCards(chooser, "2c", "9d", "5h")
	h.setExtra(chooser, "5s", "5d") // the trail is in cards 3-5
	h.mustAct(chooser, ActionSee, ActRequest{})
	if _, err := h.table.SelectVariation(chooser, "FIVE_CARD"); err != nil {
		t.Fatal(err)
	}
	eq(t, h.view(chooser).You.Hand.Picking, true, "the window is open")

	h.clock.Advance(h.table.cfg.FiveCardPickTimeout)

	hand := h.view(chooser).You.Hand
	eq(t, hand.Picking, false, "the clock closed it")
	eq(t, hand.PickedBy, string(PickByTimeout), "the server chose")
	eq(t, strings.Join(hand.Best, " "), "2c 9d 5h", "the first three they were dealt")
	eq(t, strings.Join(hand.BestPossible, " "), "5h 5s 5d", "the trail they did not play")
	eq(t, hand.HandName, "High Card", "and the hand is what they were left with")

	// A pick after the clock has spoken changes nothing.
	if _, err := h.table.SelectCards(chooser, []string{"5h", "5s", "5d"}); err == nil {
		t.Fatal("a late pick was accepted")
	} else if CodeOf(err, "") != CodeDuplicateAction {
		t.Fatalf("late pick refused as %q", CodeOf(err, ""))
	}
}

// Only three of the player's own cards, and only where a pick is owed.
func TestAFiveCardPickIsRefusedUnlessItIsThreeOfYourOwn(t *testing.T) {
	h, ids, chooser := variationTable(t, 2)
	h.setCards(chooser, "As", "7d", "Ks")
	h.setExtra(chooser, "7c", "Qs")
	h.mustAct(chooser, ActionSee, ActRequest{})
	if _, err := h.table.SelectVariation(chooser, "FIVE_CARD"); err != nil {
		t.Fatal(err)
	}
	for _, bad := range [][]string{
		{},                       // none
		{"As", "7d"},             // two
		{"As", "7d", "Ks", "Qs"}, // four
		{"As", "As", "7d"},       // the same card twice
		{"As", "7d", "3h"},       // a card they do not hold
		{"As", "7d", ""},         // a non-string the decoder blanked
		{"as", "7d", "Ks"},       // not a code this deck uses
	} {
		if _, err := h.table.SelectCards(chooser, bad); err == nil {
			t.Fatalf("%v was accepted", bad)
		} else if CodeOf(err, "") != CodeInvalidPick {
			t.Fatalf("%v refused as %q", bad, CodeOf(err, ""))
		}
	}
	// Somebody who is not at the table, and a hand that asks for no pick.
	if _, err := h.table.SelectCards("nobody", []string{"As", "7d", "Ks"}); CodeOf(err, "") != CodeNotSeated {
		t.Fatalf("a stranger picked: %v", err)
	}
	other := ids[0]
	if other == chooser {
		other = ids[1]
	}
	h2, _, c2 := variationTable(t, 2)
	h2.mustAct(c2, ActionSee, ActRequest{})
	if _, err := h2.table.SelectVariation(c2, "MUFLIS"); err != nil {
		t.Fatal(err)
	}
	if _, err := h2.table.SelectCards(c2, []string{"As", "7d", "Ks"}); CodeOf(err, "") != CodeNotPicking {
		t.Fatalf("a three-card hand took a pick: %v", err)
	}
}

// The showdown compares what each player PLAYED, which is their pick where they
// made one and their first three where they did not.
func TestAFiveCardShowdownComparesThePlayedThrees(t *testing.T) {
	h, ids, chooser := variationTable(t, 3)
	a, b, c := ids[0], ids[1], ids[2]
	h.setCards(a, "Qs", "Qh", "4d")
	h.setExtra(a, "9c", "2s") // A: a pair of queens in the first three
	h.setCards(b, "2c", "9d", "5h")
	h.setExtra(b, "5s", "5d") // B: a trail of fives, but only if B picks it
	h.setCards(c, "Ah", "3c", "8d")
	h.setExtra(c, "Kh", "6s") // C: ace high
	if _, err := h.table.SelectVariation(chooser, "FIVE_CARD"); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		h.mustAct(id, ActionSee, ActRequest{})
	}
	// B finds the trail; A and C leave their windows to lapse.
	if _, err := h.table.SelectCards(b, []string{"5h", "5s", "5d"}); err != nil {
		t.Fatal(err)
	}
	h.clock.Advance(h.table.cfg.FiveCardPickTimeout)

	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	for h.turnUser() != c {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
	h.mustAct(c, ActionPack, ActRequest{})
	h.mustAct(h.turnUser(), ActionShow, ActRequest{})

	showdowns := h.rec.all("showdown")
	eq(t, len(showdowns), 1, "one showdown")
	sd := showdowns[0].(ShowdownEvent)
	if sd.Variation != VariationFiveCard {
		t.Fatalf("the showdown does not name FIVE_CARD: %q", sd.Variation)
	}
	eq(t, len(sd.Reveals), 2, "the two players still in show")
	for _, r := range sd.Reveals {
		eq(t, len(r.Cards), 5, r.UserID+" shows all five")
		eq(t, len(r.Best), 3, r.UserID+" is told which three counted")
		switch r.UserID {
		case a:
			eq(t, r.HandName, "Pair", "A plays the pair its first three hold")
			eq(t, strings.Join(r.Best, " "), "Qs Qh 4d", "the first three, unchosen")
			eq(t, r.Won, false, "and loses")
		case b:
			eq(t, r.HandName, "Trail", "B plays the trail it picked")
			eq(t, strings.Join(r.Best, " "), "5h 5s 5d", "those three")
			eq(t, r.Won, true, "and wins")
		}
	}
	ended := h.rec.all("handEnded")
	winner := ended[len(ended)-1].(HandEndedEvent).WinnerID
	if winner == nil || *winner != b {
		t.Fatalf("the pot went to %v, want the trail's owner %s", winner, b)
	}
}

// The same five cards lose when their owner does not pick them: the rule really
// is the player's choice and not the strongest three.
func TestAFiveCardHandThatDoesNotPickPlaysItsFirstThreeAndLoses(t *testing.T) {
	h, ids, chooser := variationTable(t, 2)
	a, b := ids[0], ids[1]
	h.setCards(a, "Qs", "Qh", "4d")
	h.setExtra(a, "9c", "2s") // a pair, in the first three
	h.setCards(b, "2c", "9d", "5h")
	h.setExtra(b, "5s", "5d") // a trail, only if picked
	if _, err := h.table.SelectVariation(chooser, "FIVE_CARD"); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		h.mustAct(id, ActionSee, ActRequest{})
	}
	h.clock.Advance(h.table.cfg.FiveCardPickTimeout) // nobody picks
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	h.mustAct(h.turnUser(), ActionShow, ActRequest{})

	sd := h.rec.all("showdown")[0].(ShowdownEvent)
	for _, r := range sd.Reveals {
		if r.UserID == b {
			eq(t, r.HandName, "High Card", "B played the first three it was dealt")
			eq(t, r.Won, false, "and the trail it was holding never played")
		}
	}
}

// A sideshow compares the played threes too.
func TestASideshowUnderFiveCardComparesThePlayedThrees(t *testing.T) {
	h, ids, chooser := variationTable(t, 3)
	for i, id := range ids {
		h.setCards(id, []string{"2c", "2d", "2h"}[i], []string{"9d", "9h", "9s"}[i], []string{"5h", "5s", "5c"}[i])
	}
	if _, err := h.table.SelectVariation(chooser, "FIVE_CARD"); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		h.mustAct(id, ActionSee, ActRequest{})
	}
	h.clock.Advance(h.table.cfg.FiveCardPickTimeout) // everyone plays their first three
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	asker := h.turnUser()
	if _, err := h.act(asker, ActionSideshow, ActRequest{}); err != nil {
		t.Fatalf("sideshow: %v", err)
	}
	var asked string
	h.read(func() { asked = h.table.hand.sideshow.toUserID })
	if _, err := h.table.RespondToSideshow(asked, true); err != nil {
		t.Fatal(err)
	}
	reveals := h.rec.all("sideshowReveal")
	eq(t, len(reveals), 1, "one reveal")
	reveal := reveals[0].(SideshowRevealEvent).Reveal
	rules := RulesFor(VariationFiveCard, Card{})
	var hands [2]EvaluatedHand
	for i, hand := range reveal.Hands {
		eq(t, len(hand.Cards), 5, hand.UserID+" shows five to the other")
		eq(t, len(hand.Best), 3, hand.UserID+": which three counted")
		// Unchosen, so the first three of the five they hold.
		hands[i] = rules.EvaluateHand(ParseCards(hand.Cards)[:BaseCardsPerPlayer])
		eq(t, strings.Join(hand.Best, " "), strings.Join(hand.Cards[:BaseCardsPerPlayer], " "),
			hand.UserID+": the first three played")
		eq(t, hand.HandName, hands[i].Name, hand.UserID+": named for the three it played")
	}
	loser := asked
	if rules.CompareHands(hands[0], hands[1]) <= 0 {
		loser = asker
	}
	eq(t, reveal.PackedUserID, loser, "the sideshow was decided on the played threes")
}

// A choice made before a restart stands, and a window still open comes back
// with its ORIGINAL deadline rather than a fresh one.
func TestAFiveCardPickSurvivesARestart(t *testing.T) {
	h, ids, chooser := variationTable(t, 2)
	a, b := ids[0], ids[1]
	h.setCards(a, "2c", "9d", "5h")
	h.setExtra(a, "5s", "5d")
	h.setCards(b, "Qs", "Qh", "4d")
	h.setExtra(b, "9c", "2s")
	if _, err := h.table.SelectVariation(chooser, "FIVE_CARD"); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		h.mustAct(id, ActionSee, ActRequest{})
	}
	if _, err := h.table.SelectCards(a, []string{"5h", "5s", "5d"}); err != nil {
		t.Fatal(err)
	}

	moved := time.Second
	r := restoreHarness(t, roundTrip(t, mustSnapshot(h)), newFakeClock(h.clock.Now().Add(moved)), withLedger(emptyLedger))
	eq(t, strings.Join(r.view(a).You.Hand.Best, " "), "5h 5s 5d", "A's choice came back with the table")
	eq(t, r.view(a).You.Hand.Picking, false, "and A is not asked again")
	if hand := r.view(b).You.Hand; !hand.Picking {
		t.Fatal("B had not chosen, and must still be asked")
	}
	// The deadline is the ORIGINAL one — what is left really is shorter — while
	// the window's length stays the whole window, which is what the client's
	// countdown drains against.
	hand := r.view(b).You.Hand
	if want := h.table.cfg.FiveCardPickTimeout.Milliseconds(); hand.PickTimeoutMs != want {
		t.Fatalf("B's window is %d ms long, want the whole %d", hand.PickTimeoutMs, want)
	}
	if left := FromMillis(hand.PickDeadline).Sub(r.clock.Now()); left != h.table.cfg.FiveCardPickTimeout-moved {
		t.Fatalf("B's window has %s left, want %s", left, h.table.cfg.FiveCardPickTimeout-moved)
	}
	r.clock.Advance(h.table.cfg.FiveCardPickTimeout)
	eq(t, strings.Join(r.view(b).You.Hand.Best, " "), "Qs Qh 4d", "and lapses into B's first three")
}

func TestARestartDuringTheWindowStillDealsTheSameTopUp(t *testing.T) {
	h, ids, chooser := variationTable(t, 3)
	tops := map[string][]string{}
	for _, id := range ids {
		tops[id] = h.extra(id)
	}
	snap := roundTrip(t, mustSnapshot(h))
	r := restoreHarness(t, snap, newFakeClock(h.clock.Now().Add(time.Second)), withLedger(emptyLedger))
	for _, id := range ids {
		eq(t, strings.Join(r.extra(id), " "), strings.Join(tops[id], " "), id+"'s top-up came back with the table")
	}
	if _, err := r.table.SelectVariation(chooser, "FIVE_CARD"); err != nil {
		t.Fatal(err)
	}
	for _, info := range mustSeats(t, r.table) {
		eq(t, len(info.Cards), 5, info.UserID+" holds five after the restart")
		eq(t, strings.Join(CardCodes(info.Cards)[3:], " "), strings.Join(tops[info.UserID], " "), "the two that were drawn at the deal")
	}
	// And a restart AFTER the choice keeps the five-card hands and the count.
	again := restoreHarness(t, roundTrip(t, mustSnapshot(r)), newFakeClock(r.clock.Now().Add(time.Second)), withLedger(emptyLedger))
	for _, info := range mustSeats(t, again.table) {
		eq(t, len(info.Cards), 5, info.UserID+" still holds five")
	}
	eq(t, again.window(chooser).CardsPerPlayer, 5, "and the snapshot still says five")
	if raw := mustJSON(t, mustSnapshot(again)); strings.Contains(raw, `"extra"`) {
		t.Fatal("a dealt top-up is still in the snapshot")
	}
}

func TestARestoreRefusesATopUpThatDuplicatesACardInPlay(t *testing.T) {
	h, ids, _ := variationTable(t, 2)
	var held string
	for _, info := range mustSeats(t, h.table) {
		if info.UserID == ids[0] {
			held = info.Cards[0].Code()
		}
	}
	snap := roundTrip(t, mustSnapshot(h))
	snap.Hand.Variation.Extra[ids[1]][0] = held
	if _, err := RestoreTable(snap, TableOptions{Clock: h.clock, Ledger: NewMemoryLedger(MemoryLedgerHooks{})}); err == nil {
		t.Fatal("a snapshot whose top-up repeats a dealt card was restored")
	}
	short := roundTrip(t, mustSnapshot(h))
	short.Hand.Variation.Extra[ids[1]] = short.Hand.Variation.Extra[ids[1]][:1]
	if _, err := RestoreTable(short, TableOptions{Clock: h.clock, Ledger: NewMemoryLedger(MemoryLedgerHooks{})}); err == nil {
		t.Fatal("a snapshot with a one-card top-up was restored")
	}
}

func TestATimeoutStillChoosesMuflisAndDealsNobodyMoreCards(t *testing.T) {
	h, _, _ := variationTable(t, 3)
	h.advance(variationWindowMS)
	got := h.selected()
	eq(t, len(got), 1, "the server chose")
	eq(t, got[0].Variation, VariationMuflis, "Muflis, as ever — not 5-Card")
	eq(t, got[0].CardsPerPlayer, 3, "three cards")
	for _, info := range mustSeats(t, h.table) {
		eq(t, len(info.Cards), 3, info.UserID+" holds three")
	}
}

func TestAPlayerWhoLeftDuringTheWindowIsDealtNothing(t *testing.T) {
	h, ids, chooser := variationTable(t, 4)
	leaver := ids[0]
	if leaver == chooser {
		leaver = ids[1]
	}
	if _, err := h.table.RemovePlayer(leaver, "left"); err != nil {
		t.Fatal(err)
	}
	if _, err := h.table.SelectVariation(chooser, "FIVE_CARD"); err != nil {
		t.Fatal(err)
	}
	for _, info := range mustSeats(t, h.table) {
		if info.UserID == leaver {
			t.Fatalf("%s left and is still seated", leaver)
		}
		eq(t, len(info.Cards), 5, info.UserID+" holds five")
	}
}

func TestSevenPlayersWorthOfCardsStillFitTheDeck(t *testing.T) {
	// 5 players × 3 + the turned-up card + 5 × 2 = 26 of 52: a full table can
	// always be topped up, so FIVE_CARD is always on a real table's menu.
	h, _, chooser := variationTable(t, 5)
	found := false
	for _, v := range h.window(chooser).Options {
		if v == VariationFiveCard {
			found = true
		}
	}
	eq(t, found, true, "FIVE_CARD is offered at a full table")
	// And where the deck could NOT cover it, it is neither offered nor taken.
	order := make([]string, 30)
	for i := range order {
		order[i] = "p" + string(rune('A'+i))
	}
	if extra := drawExtraCards(order, NewDeck()[:40]); extra != nil {
		t.Fatalf("a top-up for 30 players was drawn from 40 cards: %d hands", len(extra))
	}
	w := &variationWindow{open: true, menu: menuFor(false)}
	if w.offers(VariationFiveCard) {
		t.Fatal("a window with no top-up offers 5-Card")
	}
	eq(t, len(w.options()), 6, "the six three-card variations remain")
	eq(t, len(menuFor(true)), 7, "and with a top-up, all seven")
}

// The menu is a fact about the HAND, decided when the window opens. It used to
// be read off whether the top-up was still undealt — which is also true once it
// has been spent — so every closed window's menu shrank to six and a snapshot
// could say selected:"FIVE_CARD" beside a menu without it.
func TestTheMenuIsTheSameBeforeAndAfterTheChoiceHoweverItIsMade(t *testing.T) {
	menu := func(h *harness, id string) string {
		var out []string
		for _, v := range h.window(id).Options {
			out = append(out, string(v))
		}
		return strings.Join(out, ",")
	}
	const seven = "MUFLIS,AK47,JOKER,HUKAM,LOWEST_JOKER,HIGHEST_JOKER,FIVE_CARD"

	for _, pick := range []string{"FIVE_CARD", "AK47", "MUFLIS"} {
		h, ids, chooser := variationTable(t, 3)
		eq(t, menu(h, chooser), seven, pick+": seven while the window is open")
		if _, err := h.table.SelectVariation(chooser, pick); err != nil {
			t.Fatal(err)
		}
		for _, id := range ids {
			eq(t, menu(h, id), seven, pick+": and the same seven once it is chosen, for "+id)
		}
		// A table restored after the choice reports it too.
		r := restoreHarness(t, roundTrip(t, mustSnapshot(h)), newFakeClock(h.clock.Now()), withLedger(emptyLedger))
		eq(t, menu(r, chooser), seven, pick+": and after a restart")
		if sel := r.window(chooser).Selected; sel == nil || string(*sel) != pick {
			t.Fatalf("%s: the restored window selected %v", pick, sel)
		}
	}

	// The clock choosing, and the chooser walking out, are no different.
	h, _, chooser := variationTable(t, 3)
	h.advance(variationWindowMS)
	eq(t, menu(h, chooser), seven, "after a timeout")
	h2, ids2, chooser2 := variationTable(t, 3)
	if _, err := h2.table.RemovePlayer(chooser2, "left"); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids2 {
		if id != chooser2 {
			eq(t, menu(h2, id), seven, "after the chooser left")
		}
	}
}

func TestARestoreRefusesATopUpThatLeavesAPlayerOut(t *testing.T) {
	h, ids, _ := variationTable(t, 3)
	snap := roundTrip(t, mustSnapshot(h))
	delete(snap.Hand.Variation.Extra, ids[2])
	if _, err := RestoreTable(snap, TableOptions{Clock: h.clock, Ledger: NewMemoryLedger(MemoryLedgerHooks{})}); err == nil {
		t.Fatal("a top-up for two of three players was restored: some would hold five and one three")
	}
	// A snapshot from before top-ups existed has none at all, and that is fine:
	// the hand simply does not offer 5-Card.
	old := roundTrip(t, mustSnapshot(h))
	old.Hand.Variation.Extra = nil
	old.Hand.Variation.Options = nil
	r := restoreHarness(t, old, newFakeClock(h.clock.Now()), withLedger(emptyLedger))
	chooser := r.chooser()
	for _, v := range r.window(chooser).Options {
		if v == VariationFiveCard {
			t.Fatal("a hand with no top-up to deal offers 5-Card")
		}
	}
	if _, err := r.table.SelectVariation(chooser, "FIVE_CARD"); err == nil {
		t.Fatal("5-Card was accepted on a hand that cannot deal it")
	} else if got := CodeOf(err, "<nil>"); got != CodeInvalidVariation {
		t.Fatalf("5-Card on a hand that cannot deal it: %s, want %s", got, CodeInvalidVariation)
	}
	// The window is still open for a real choice.
	if _, err := r.table.SelectVariation(chooser, "AK47"); err != nil {
		t.Fatalf("a three-card variation was refused afterwards: %v", err)
	}
	bad := roundTrip(t, mustSnapshot(h))
	bad.Hand.Variation.Options = []Variation{"MUFLIS", "SEVEN_CARD_STUD"}
	if _, err := RestoreTable(bad, TableOptions{Clock: h.clock, Ledger: NewMemoryLedger(MemoryLedgerHooks{})}); err == nil {
		t.Fatal("a menu naming a variation this server does not play was restored")
	}
}
