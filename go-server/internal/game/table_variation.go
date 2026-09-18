package game

import (
	"time"
)

// The variation window (Go only; owner, 18 Sep 2026). The rules a variation
// plays by are in variation.go; this file is the part of the Table that lets a
// player choose one.
//
// # Flow
//
// On a CategoryVariation table, startHand deals the three cards as always and
// then, instead of opening play, opens a WINDOW for the player who is to act
// first — the seat to the dealer's left, exactly who would have been on turn:
//
//	startHand → beginVariation(firstSeat)        hand.turnSeat stays -1
//	    chooser: SelectVariation(v)  ─┐
//	    the window's clock runs out  ─┼→ closeVariation → setTurn(firstSeat)
//	    the chooser leaves the table ─┘   (a leaver's turn passes on instead)
//
// While the window is open NOBODY is on turn: hand.turnSeat is -1, the turn
// clock is not running, and act refuses every move but a look at one's own
// cards (variation_pending). When it closes the chooser gets their ordinary
// turn with a full clock, so choosing never costs them playing time.
//
// # Exactly one result
//
// The chooser's pick and the clock's expiry can arrive in the same instant.
// Both are closures on the table's actor — the pick through run() like every
// other move, the expiry through run() from the timer's goroutine — so they
// execute one after the other, never together, and closeVariation is guarded by
// the window's own `open` flag: whichever closure the actor runs first closes
// the window and the second finds it closed and changes nothing. There is no
// lock and no compare-and-swap because there is no second thread to race; this
// is the same guarantee hand.turnToken and the sideshow's pointer check give
// the two clocks that were here first.
//
// # One timer
//
// A hand has at most one window and the window at most one timer. It is
// stopped by closeVariation (every way a window closes), by endHand, and by
// destroy, suspend and fence — everywhere the sideshow's timer is — and
// resumeTimers re-arms it for what is left when a table comes back from the
// live store. It carries no token: like the sideshow's, its callback checks
// that the window it was armed for is still the hand's window and still open.

// variationWindow is hand.variation on a variation table; nil everywhere else.
type variationWindow struct {
	// open is true from the deal until the variation is chosen. Every path
	// that closes the window goes through closeVariation, which is what makes
	// the choice happen exactly once.
	open bool

	// The chooser, fixed when the window opens. The name is kept here because
	// the seat may be gone (they left) by the time it is reported.
	chooserID   string
	chooserName string
	chooserSeat int

	startedAt time.Time
	// deadline is when the server chooses for them; zero when the table's
	// VariationSelectTimeout is 0 and the window never lapses.
	deadline time.Time
	timer    Timer

	// turnUp is the card turned up from the undealt deck at the deal. It is
	// drawn for every hand so that Joker and Hukam need no second shuffle, and
	// it stays on the server unless one of those two is chosen.
	turnUp Card

	// selected is "" while the window is open.
	selected   Variation
	selectedBy VariationSelectedBy
}

// rules is what the hand's comparisons are made under: the zero value —
// classic Teen Patti — until a variation has been chosen.
func (w *variationWindow) rules() VariationRules {
	if w == nil || w.selected == "" {
		return VariationRules{}
	}
	return RulesFor(w.selected, w.turnUp)
}

// VariationResult is SelectVariation's return: ack `{ok:true, variation,
// selectedBy, turnUp?}`.
type VariationResult struct {
	Variation  Variation           `json:"variation"`
	SelectedBy VariationSelectedBy `json:"selectedBy"`
	// TurnUp is the turned-up card's wire code, present only when the chosen
	// variation is decided by it (Joker, Hukam).
	TurnUp *string `json:"turnUp,omitempty"`
}

// SelectVariation is the chooser's answer (socket game:selectVariation). raw is
// the client's string, untrusted; userID is the socket's authenticated user,
// never anything the client sent.
//
// Refusals, in order — the first that applies wins:
//
//	no_hand                    no hand is being played
//	not_seated                 the caller has no seat at this table
//	no_variation               this hand has no variation window (not a
//	                           variation table)
//	variation_already_selected the window has closed — by the chooser, by the
//	                           clock, or because the chooser left
//	not_selecting              the window is open, but for somebody else
//	invalid_variation          raw is not one of the six canonical values
//	variation_expired          the deadline has passed and the clock's own
//	                           closure had not run yet: the server's choice is
//	                           made NOW, by this call, and the request refused
//
// The last is what keeps the deadline the server's: a pick that reaches the
// actor after the deadline loses to the clock even when the timer's callback is
// still on its way, so a client cannot win the race by being late.
func (t *Table) SelectVariation(userID, raw string) (VariationResult, error) {
	var result VariationResult
	var failure error
	err := t.run(func() { result, failure = t.selectVariation(userID, raw) })
	if err != nil {
		return VariationResult{}, err
	}
	return result, failure
}

// selectVariation is SelectVariation's actor body.
func (t *Table) selectVariation(userID, raw string) (VariationResult, error) {
	if t.hand == nil {
		return VariationResult{}, NewGameError(CodeNoHand, MsgNoHand)
	}
	if t.findSeat(userID) == nil {
		return VariationResult{}, NewGameError(CodeNotSeated, MsgNotSeated)
	}
	w := t.hand.variation
	if w == nil {
		return VariationResult{}, NewGameError(CodeNoVariation, MsgNoVariation)
	}
	if !w.open {
		return VariationResult{}, NewGameError(CodeVariationAlreadySelected, MsgVariationAlreadySelected)
	}
	if w.chooserID != userID {
		return VariationResult{}, NewGameError(CodeNotSelecting, MsgNotSelecting)
	}
	chosen, ok := ParseVariation(raw)
	if !ok {
		return VariationResult{}, NewGameError(CodeInvalidVariation, MsgInvalidVariation)
	}
	if !w.deadline.IsZero() && !t.clock.Now().Before(w.deadline) {
		t.closeVariation(VariationDefault, VariationByTimeout, true)
		return VariationResult{}, NewGameError(CodeVariationExpired, MsgVariationExpired)
	}

	t.closeVariation(chosen, VariationByPlayer, true)
	return t.variationResult(w), nil
}

// variationResult renders a closed window as the chooser's ack.
func (t *Table) variationResult(w *variationWindow) VariationResult {
	return VariationResult{Variation: w.selected, SelectedBy: w.selectedBy, TurnUp: w.turnUpCode()}
}

// turnUpCode is the turned-up card's wire code once a variation that uses it
// has been chosen, else nil — the card never leaves the server otherwise.
func (w *variationWindow) turnUpCode() *string {
	if w == nil || !w.selected.UsesTurnUp() {
		return nil
	}
	return StrPtr(w.turnUp.Code())
}

// variationPending reports whether a window is open — and so whether the hand
// is between its deal and its first turn.
func (t *Table) variationPending() bool {
	return t.hand != nil && t.hand.variation != nil && t.hand.variation.open
}

// handRules is the rules the live hand's comparisons are made under. Classic
// for a hand with no window, and for one whose window is still open.
func (t *Table) handRules() VariationRules {
	if t.hand == nil {
		return VariationRules{}
	}
	return t.hand.variation.rules()
}

// ownHandView is YouView.Hand: what a viewer's own SEEN cards make under the
// hand's variation, nil until a variation has been chosen (and so always nil on
// a seen or blind table, whose hands never have one). Called on the actor from
// serializeFor, for a viewer who is not blind.
func (t *Table) ownHandView(viewer *seat) *YouHand {
	if t.hand == nil || t.hand.variation == nil || t.hand.variation.selected == "" || len(viewer.cards) != 3 {
		return nil
	}
	hand := t.handRules().EvaluateHand(viewer.cards)
	view := &YouHand{
		HandName: hand.Name,
		Category: hand.Category,
		Wild:     []string{},
		PlaysAs:  CardCodes(viewer.cards),
	}
	if len(hand.Wild) > 0 {
		view.Wild = hand.Wild
		view.PlaysAs = hand.PlaysAs
	}
	return view
}

// beginVariation opens the window for the seat that is to act first. Called by
// startHand in place of setTurn.
func (t *Table) beginVariation(seatIndex int, turnUp Card) {
	h := t.hand
	if h == nil || seatIndex < 0 || seatIndex >= len(t.seats) || t.seats[seatIndex] == nil {
		return
	}
	s := t.seats[seatIndex]
	now := t.clock.Now()
	w := &variationWindow{
		open:        true,
		chooserID:   s.userID,
		chooserName: s.displayName,
		chooserSeat: seatIndex,
		startedAt:   now,
		turnUp:      turnUp,
	}
	if t.cfg.VariationSelectTimeout > 0 {
		w.deadline = now.Add(t.cfg.VariationSelectTimeout)
	}
	h.variation = w

	t.listener.OnVariationSelecting(t.view, VariationSelectingEvent{
		UserID:      w.chooserID,
		DisplayName: w.chooserName,
		SeatIndex:   w.chooserSeat,
		StartedAt:   Millis(w.startedAt),
		Deadline:    w.deadlineMillis(),
		TimeoutMs:   t.cfg.VariationSelectTimeout.Milliseconds(),
		Options:     variationOptions(),
	})

	if t.cfg.VariationSelectTimeout > 0 {
		t.armVariationTimer(w, t.cfg.VariationSelectTimeout)
	}
}

// armVariationTimer arms the window's expiry for d (beginVariation uses the
// full VariationSelectTimeout; a restored window has less left).
func (t *Table) armVariationTimer(w *variationWindow, d time.Duration) {
	if d < 0 {
		d = 0
	}
	w.timer = t.clock.AfterFunc(d, func() {
		_ = t.run(func() {
			// A timer stopped a moment too late must not close a newer hand's
			// window, and one that lost the race to the chooser's pick finds
			// its own window already closed inside closeVariation.
			if t.hand == nil || t.hand.variation != w {
				return
			}
			t.closeVariation(VariationDefault, VariationByTimeout, true)
		})
	})
}

// stopVariationTimer stops the window's clock if it is running. Safe on a hand
// with no window.
func (t *Table) stopVariationTimer() {
	if t.hand == nil || t.hand.variation == nil || t.hand.variation.timer == nil {
		return
	}
	t.hand.variation.timer.Stop()
	t.hand.variation.timer = nil
}

// closeVariation is the ONE place a window closes, and the reason a variation
// is chosen exactly once: it does nothing unless the window is open, and the
// first thing it does is close it. Returns whether this call was the one that
// closed it.
//
// startTurn hands the chooser their ordinary turn — a fresh one, with a full
// clock. It is false only when the chooser has left the table, where
// removePlayer moves the turn on past their empty seat instead.
func (t *Table) closeVariation(chosen Variation, by VariationSelectedBy, startTurn bool) bool {
	if t.hand == nil {
		return false
	}
	w := t.hand.variation
	if w == nil || !w.open {
		return false
	}
	w.open = false
	w.selected = chosen
	w.selectedBy = by
	t.stopVariationTimer()

	t.listener.OnVariationSelected(t.view, VariationSelectedEvent{
		UserID:      w.chooserID,
		DisplayName: w.chooserName,
		SeatIndex:   w.chooserSeat,
		Variation:   w.selected,
		SelectedBy:  w.selectedBy,
		TurnUp:      w.turnUpCode(),
	})

	if startTurn {
		t.setTurn(w.chooserSeat, true)
	}
	t.emitState()
	return true
}

// deadlineMillis is the window's deadline for the wire, nil when it never
// lapses.
func (w *variationWindow) deadlineMillis() *int64 {
	if w.deadline.IsZero() {
		return nil
	}
	return Int64Ptr(Millis(w.deadline))
}

// variationOptions is a fresh copy of the menu for a wire struct.
func variationOptions() []Variation {
	return append([]Variation(nil), Variations...)
}

// variationView renders the window for room:state — nil for a hand without
// one, which keeps the key off a seen or blind table's snapshot entirely. It is
// the same for every viewer: who is choosing, until when and what was chosen
// are public, and the turned-up card is included only once a variation that
// uses it has made it public.
func (t *Table) variationView() *VariationView {
	if t.hand == nil || t.hand.variation == nil {
		return nil
	}
	w := t.hand.variation
	view := &VariationView{
		Selecting:   w.open,
		UserID:      w.chooserID,
		DisplayName: w.chooserName,
		SeatIndex:   w.chooserSeat,
		StartedAt:   Millis(w.startedAt),
		Deadline:    w.deadlineMillis(),
		TimeoutMs:   t.cfg.VariationSelectTimeout.Milliseconds(),
		Options:     variationOptions(),
		TurnUp:      w.turnUpCode(),
	}
	if !w.open {
		selected, by := w.selected, w.selectedBy
		view.Selected = &selected
		view.SelectedBy = &by
	}
	return view
}

// snapshotVariation renders the window for the live store — the turned-up card
// included, always: the snapshot is the server's own state and never reaches a
// client.
func (w *variationWindow) snapshot() *SnapshotVariation {
	if w == nil {
		return nil
	}
	return &SnapshotVariation{
		Open:        w.open,
		ChooserID:   w.chooserID,
		ChooserName: w.chooserName,
		ChooserSeat: w.chooserSeat,
		StartedAt:   Millis(w.startedAt),
		Deadline:    w.deadlineMillis(),
		TurnUp:      w.turnUp.Code(),
		Selected:    w.selected,
		SelectedBy:  w.selectedBy,
	}
}

// variationFrom is snapshot's inverse (restoreTable). The timer is re-armed by
// resumeTimers, not here.
func variationFrom(s *SnapshotVariation) *variationWindow {
	if s == nil {
		return nil
	}
	w := &variationWindow{
		open:        s.Open,
		chooserID:   s.ChooserID,
		chooserName: s.ChooserName,
		chooserSeat: s.ChooserSeat,
		startedAt:   FromMillis(s.StartedAt),
		turnUp:      ParseCard(s.TurnUp),
		selected:    s.Selected,
		selectedBy:  s.SelectedBy,
	}
	if s.Deadline != nil {
		w.deadline = FromMillis(*s.Deadline)
	}
	return w
}

// resumeVariation re-arms a restored window's clock against now, or closes a
// window whose deadline passed while the process was down. Returns whether the
// hand is still waiting on the window — the caller must then leave the turn
// alone, because there is none yet.
func (t *Table) resumeVariation(now time.Time) bool {
	if !t.variationPending() {
		return false
	}
	w := t.hand.variation
	if w.chooserSeat < 0 || w.chooserSeat >= len(t.seats) || t.seats[w.chooserSeat] == nil ||
		t.seats[w.chooserSeat].userID != w.chooserID || t.seats[w.chooserSeat].status != SeatActive {
		// The chooser is not there to be given a turn (validateSnapshot refuses
		// this; belt and braces). Choose for them and open play as startHand
		// would have for whoever is next.
		t.closeVariation(VariationDefault, VariationByLeft, false)
		t.advanceTurn(w.chooserSeat)
		return false
	}
	if w.deadline.IsZero() {
		return true
	}
	if !w.deadline.After(now) {
		t.closeVariation(VariationDefault, VariationByTimeout, true)
		return false
	}
	t.armVariationTimer(w, w.deadline.Sub(now))
	return true
}
