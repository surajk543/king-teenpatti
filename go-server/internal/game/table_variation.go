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

	// extra is the top-up every player in the hand would be dealt if a
	// variation that plays more than three cards is chosen (5-Card Teen Patti:
	// two each), keyed by user id and drawn at the deal, from the SAME shuffled
	// deck the hands and the turned-up card came from, one card at a time round
	// the table as the deal itself goes. Drawn then rather than when the choice
	// lands so that it is part of the hand from the start: it is in the
	// snapshot, so a server that restarts mid-window deals the same two cards
	// it would have, and nothing about the choice can influence what they are.
	// It stays on the server — never in a view, never in an event — until it is
	// dealt (dealExtraCards), and is dropped once it has been or once any other
	// variation is chosen. nil when the deck could not cover it, in which case
	// such a variation is not on this hand's menu.
	extra map[string][]Card

	// menu is what THIS hand offers, decided ONCE when the window opens and
	// then left alone: every variation, less any that needs a top-up the deck
	// could not provide. It is state of its own rather than something read off
	// `extra`, because `extra` also goes nil when the top-up has been SPENT —
	// dealt, or dropped for a three-card choice — and a menu inferred from it
	// shrank from seven to six the moment any window closed, leaving a snapshot
	// that said selected:"FIVE_CARD" beside a menu with no FIVE_CARD on it.
	menu []Variation

	// selected is "" while the window is open.
	selected   Variation
	selectedBy VariationSelectedBy
}

// cardsPerPlayer is how many cards each player in the hand holds right now:
// three from the deal until a variation is chosen, then whatever that variation
// plays with. nil-safe: a hand with no window holds three.
func (w *variationWindow) cardsPerPlayer() int {
	if w == nil || w.open {
		return BaseCardsPerPlayer
	}
	return w.selected.CardsPerPlayer()
}

// options is the menu THIS hand offers, a fresh copy for a wire struct: the
// same before the choice and after it (see menu).
func (w *variationWindow) options() []Variation {
	return append([]Variation(nil), w.menu...)
}

// menuFor is the menu of a hand whose top-up was (or was not) drawn: every
// variation, less any that plays more than three cards when there is no top-up
// to deal — more players than a deck of 52 can give five cards to, which no
// table the lobby opens has, but a config can ask for.
func menuFor(hasTopUp bool) []Variation {
	out := make([]Variation, 0, len(Variations))
	for _, v := range Variations {
		if v.CardsPerPlayer() > BaseCardsPerPlayer && !hasTopUp {
			continue
		}
		out = append(out, v)
	}
	return out
}

// offers reports whether v is on this hand's menu.
func (w *variationWindow) offers(v Variation) bool {
	for _, o := range w.options() {
		if o == v {
			return true
		}
	}
	return false
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
	// CardsPerPlayer is how many cards every player in the hand now holds: 3,
	// or 5 under FIVE_CARD. The server's to say; a client never decides it.
	CardsPerPlayer int `json:"cardsPerPlayer"`
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
	// A variation this hand's menu does not carry is as invalid as a name that
	// is not a variation at all: the chooser was never offered it.
	if !ok || !w.offers(chosen) {
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
	return VariationResult{
		Variation:      w.selected,
		SelectedBy:     w.selectedBy,
		TurnUp:         w.turnUpCode(),
		CardsPerPlayer: w.cardsPerPlayer(),
	}
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
	if t.hand == nil || t.hand.variation == nil || t.hand.variation.selected == "" ||
		len(viewer.cards) != t.hand.variation.cardsPerPlayer() {
		return nil
	}
	hand := t.handRules().EvaluateHand(viewer.cards)
	view := &YouHand{
		HandName: hand.Name,
		Category: hand.Category,
		Wild:     []string{},
		PlaysAs:  CardCodes(viewer.cards),
		// Three cards are played whatever is held: all of a three-card hand,
		// the best three of a five-card one.
		Best: CardCodes(viewer.cards),
	}
	if len(hand.Wild) > 0 {
		view.Wild = hand.Wild
		view.PlaysAs = hand.PlaysAs
	}
	if len(hand.Best) > 0 {
		view.Best = hand.Best
	}
	return view
}

// beginVariation opens the window for the seat that is to act first. Called by
// startHand in place of setTurn.
func (t *Table) beginVariation(seatIndex int, undealt []Card) {
	h := t.hand
	if h == nil || seatIndex < 0 || seatIndex >= len(t.seats) || t.seats[seatIndex] == nil || len(undealt) == 0 {
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
		// The top of the deck the hands came from, so it is in nobody's hand.
		turnUp: undealt[0],
		extra:  drawExtraCards(h.contribOrder, undealt[1:]),
	}
	w.menu = menuFor(w.extra != nil)
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
		Options:     w.options(),
	})

	if t.cfg.VariationSelectTimeout > 0 {
		t.armVariationTimer(w, t.cfg.VariationSelectTimeout)
	}
}

// drawExtraCards draws the top-up for every player in the hand from what is
// left of the deck after the turned-up card: MaxCardsPerPlayer −
// BaseCardsPerPlayer each, one card at a time round the table in the order the
// hands were dealt. nil when the deck cannot cover everyone — a top-up for some
// and not others is not a game.
func drawExtraCards(order []string, deck []Card) map[string][]Card {
	each := MaxCardsPerPlayer - BaseCardsPerPlayer
	if len(order) == 0 || len(deck) < each*len(order) {
		return nil
	}
	extra := make(map[string][]Card, len(order))
	index := 0
	for round := 0; round < each; round++ {
		for _, userID := range order {
			extra[userID] = append(extra[userID], deck[index])
			index++
		}
	}
	return extra
}

// dealExtraCards tops every hand up to what the chosen variation plays with.
// Called once, by closeVariation, on the actor. Every player still in the hand
// gets their two — a player who left during the window has no seat to deal to
// — and the hand's own record of their cards is brought along, because that is
// what a showdown and a restart read. A player who has already looked is sent
// their new hand at once (the same `cards` event a See sends); everyone else
// learns only that the hand now holds five, from cardCount.
func (t *Table) dealExtraCards(w *variationWindow) {
	want := w.selected.CardsPerPlayer()
	for _, s := range t.seats {
		if s == nil || len(s.cards) == 0 || len(s.cards) >= want {
			continue
		}
		top := w.extra[s.userID]
		if len(top) < want-len(s.cards) {
			continue
		}
		// A fresh slice: the deal's own backing array is shared with nothing
		// by then, but a top-up must never be able to write into another hand.
		cards := make([]Card, 0, want)
		cards = append(cards, s.cards...)
		cards = append(cards, top[:want-len(s.cards)]...)
		s.cards = cards
		if entry := t.hand.contributions[s.userID]; entry != nil {
			entry.cards = cards
		}
		if !s.isBlind {
			t.listener.OnCards(t.view, CardsEvent{UserID: s.userID, Cards: CardCodes(s.cards)})
		}
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

	// The announcement first, so a client knows the hand is now five cards
	// before the cards arrive; then the top-up. Either way the top-up is
	// spent: dealt, or never to be.
	t.listener.OnVariationSelected(t.view, VariationSelectedEvent{
		UserID:         w.chooserID,
		DisplayName:    w.chooserName,
		SeatIndex:      w.chooserSeat,
		Variation:      w.selected,
		SelectedBy:     w.selectedBy,
		TurnUp:         w.turnUpCode(),
		CardsPerPlayer: w.cardsPerPlayer(),
	})
	if w.cardsPerPlayer() > BaseCardsPerPlayer {
		t.dealExtraCards(w)
	}
	w.extra = nil

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
		Options:     w.options(),
		TurnUp:      w.turnUpCode(),
		// What every player in the hand holds right now. The client draws its
		// fans from this and never decides it.
		CardsPerPlayer: w.cardsPerPlayer(),
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
		Extra:       extraCodes(w.extra),
		Options:     w.options(),
	}
}

// extraCodes renders the undealt top-up for the snapshot; nil when there is
// none, which keeps the key out of a hand that has dealt or dropped it.
func extraCodes(extra map[string][]Card) map[string][]string {
	if len(extra) == 0 {
		return nil
	}
	out := make(map[string][]string, len(extra))
	for userID, cards := range extra {
		out[userID] = CardCodes(cards)
	}
	return out
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
	// Only an open window still has a top-up to deal.
	if s.Open && len(s.Extra) > 0 {
		w.extra = make(map[string][]Card, len(s.Extra))
		for userID, codes := range s.Extra {
			w.extra[userID] = ParseCards(codes)
		}
	}
	// The menu the hand opened with. A snapshot written before menus were kept
	// has none: an open window offers what it can still deal, and a closed one
	// — whose menu is only a record by then — is given the full list, so that
	// whatever it selected is on it.
	switch {
	case len(s.Options) > 0:
		w.menu = append([]Variation(nil), s.Options...)
	case s.Open:
		w.menu = menuFor(w.extra != nil)
	default:
		w.menu = menuFor(true)
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
