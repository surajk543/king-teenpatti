package game

import (
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// The 5-Card pick (Go only; owner, 19 Sep 2026). Under FIVE_CARD a player holds
// five cards and three of them play. The server used to decide which three —
// EvaluateBest walked the ten combinations and kept the strongest — so the
// player held five cards and made no decision at all. Now THEY choose, and the
// server only tells them afterwards whether they chose well.
//
// # The window
//
// It belongs to one player, not to the table: it opens the moment that player
// can SEE five cards, which is either their tap on "See cards" or the top-up
// landing on a player who was already looking, and it lasts
// FIVE_CARD_PICK_TIMEOUT_MS. Nobody else waits for it. A player who never looks
// never opens one.
//
// Lapsing is not a refusal: the server plays THE FIRST THREE THEY WERE DEALT
// (owner: "if user not able to select cards in extra time then select first 3
// cards"), which is also what a player who stays blind all hand plays. So every
// hand always has three cards to compare, whatever anyone does or does not do.
//
// # Extra time, not borrowed time
//
// A player whose turn is running while they choose would otherwise spend their
// 25 seconds reading five cards. extendTurn pushes their turn deadline out to
// cover the whole window AND a full turn after it, so the choice never costs
// them the time to act on it. It re-tokens the turn the way setTurn does, so
// the clock it replaces is stale and cannot pack them.
//
// # One timer for every window
//
// Up to five windows can be open at once and they close at different moments,
// but the table keeps ONE timer (pickTimer), armed for the earliest deadline
// still outstanding. When it fires it defaults every window that has actually
// lapsed and re-arms for the next. That keeps the table's timer count fixed —
// turn, sideshow, variation, unfunded, pick — however many players are choosing.
//
// # Exactly one result per player
//
// A player's pick and their own deadline can arrive in the same instant. Both
// are closures on the table's actor, so they run one after the other, and
// settlePick is guarded by `picked` already being set: whichever runs first
// decides, and the second finds the choice made and changes nothing. It is the
// guarantee closeVariation gives the variation window, per seat.

// pickedBy says who chose a player's three cards, for the message the client
// shows them afterwards.
type PickedBy string

const (
	// PickByPlayer: they chose.
	PickByPlayer PickedBy = "PLAYER"
	// PickByTimeout: the window lapsed and the first three were played.
	PickByTimeout PickedBy = "TIMEOUT"
)

// PickResult is SelectCards's return — the ack `{ok:true, picked, best,
// wasBest}`. Best is the strongest three the five held could have made, so a
// client can say "you played this; the best was that" without a ranking of its
// own (there is exactly one, and it is here).
type PickResult struct {
	Picked  []string `json:"picked"`
	Best    []string `json:"best"`
	WasBest bool     `json:"wasBest"`
}

// fiveCardHand reports whether this hand is being played with more cards than
// are counted — FIVE_CARD, once it has been chosen and the top-up dealt.
func (t *Table) fiveCardHand() bool {
	return t.hand != nil && t.hand.variation != nil &&
		t.hand.variation.selected == VariationFiveCard &&
		t.hand.variation.cardsPerPlayer() > BaseCardsPerPlayer
}

// playedCards is the three cards a seat actually plays: the three they chose,
// else — for a player who has not chosen, has not looked, or whose window
// lapsed — the first three they were dealt. Every other hand plays all of
// itself, so this is s.cards.
func (t *Table) playedCards(s *seat) []Card {
	if s == nil {
		return nil
	}
	if !t.fiveCardHand() || len(s.cards) <= BaseCardsPerPlayer {
		return s.cards
	}
	if len(s.picked) == BaseCardsPerPlayer {
		return s.picked
	}
	return s.cards[:BaseCardsPerPlayer]
}

// playedHand scores what a seat plays, and is the ONE way a hand is scored
// anywhere a comparison is made (the showdown, a sideshow, a player's own
// view). For a five-card hand it evaluates the THREE that play and then reports
// the five that are held with those three named, which is the shape every
// reader already expects: Cards is what the player holds and Best which of them
// counted.
func (t *Table) playedHand(rules VariationRules, s *seat) EvaluatedHand {
	played := t.playedCards(s)
	if len(played) == len(s.cards) {
		return rules.EvaluateHand(s.cards)
	}
	hand := rules.EvaluateHand(played)
	hand.Cards = CardCodes(s.cards)
	hand.Best = CardCodes(played)
	return hand
}

// beginPick opens a player's window, if one is owed: a five-card hand, five
// cards in front of a player who can see them, and no choice made or window
// running already. Called where those become true — see(), and dealExtraCards
// for a player who was already looking.
func (t *Table) beginPick(s *seat) {
	if s == nil || s.isBlind || !t.fiveCardHand() ||
		len(s.cards) <= BaseCardsPerPlayer || len(s.picked) > 0 || !s.pickUntil.IsZero() {
		return
	}
	if t.cfg.FiveCardPickTimeout <= 0 {
		// No clock: the window stays open until the hand ends, and whatever is
		// unchosen then plays the first three. A deadline of zero says so.
		s.pickUntil = time.Time{}
		s.picking = true
		return
	}
	s.picking = true
	s.pickUntil = t.clock.Now().Add(t.cfg.FiveCardPickTimeout)
	// The choice must not eat the turn it is being made on — THEIR turn, and
	// only when they hold it (extendTurn checks).
	t.extendTurnForPick(s)
	t.armPickTimer()
}

// extendTurnForPick gives a player whose pick window is open, and who holds
// the turn, the whole window plus a full turn. Called when the window opens
// and when the turn reaches a player whose window is already open (the
// variation chooser who looked before choosing FIVE_CARD).
func (t *Table) extendTurnForPick(s *seat) {
	if s == nil || !s.picking || len(s.picked) > 0 || s.pickUntil.IsZero() {
		return
	}
	t.extendTurn(s, s.pickUntil.Add(t.cfg.TurnTimeout))
}

// pickPending reports whether any of these seats, still in the hand, is inside
// a 5-Card pick window with a deadline — a player who has five cards in front
// of them and has not yet chosen which three play. A comparison a player
// forces (Sideshow, Force Sideshow, Missile, Show) waits for them: judging
// them now would play their first three and cut short the time the owner
// gave them to choose. A window without a deadline (FIVE_CARD_PICK_TIMEOUT_MS
// 0, never in production) does not hold anything up, or it could hold the
// hand for ever.
func (t *Table) pickPending(seats ...*seat) bool {
	if !t.fiveCardHand() {
		return false
	}
	for _, s := range seats {
		if s != nil && s.status == SeatActive && s.picking && len(s.picked) == 0 && !s.pickUntil.IsZero() {
			return true
		}
	}
	return false
}

// dropPick closes a window that no longer matters — the player has packed —
// so the pick clock does not fire for a seat out of the hand.
func (t *Table) dropPick(s *seat) {
	if s == nil || !s.picking {
		return
	}
	s.picking = false
	s.pickUntil = time.Time{}
	t.armPickTimer()
}

// SelectCards is a player's choice of which three of their five cards play
// (socket game:selectCards). codes is the client's list, untrusted; userID is
// the socket's authenticated user, so nobody can choose for anyone else.
//
// Refusals, in order: no_hand | not_seated | not_in_hand | not_picking |
// duplicate_action | invalid_pick.
// A choice that arrives after the deadline is not refused — the deadline is the
// server's own, and by the time a late choice reaches the actor the sweep has
// already played the first three; it finds the choice made and answers
// duplicate_action rather than pretending to change a hand that is decided.
func (t *Table) SelectCards(userID string, codes []string) (PickResult, error) {
	var result PickResult
	var failure error
	err := t.run(func() { result, failure = t.selectCards(userID, codes) })
	if err != nil {
		return PickResult{}, err
	}
	return result, failure
}

// selectCards is SelectCards's actor body.
func (t *Table) selectCards(userID string, codes []string) (PickResult, error) {
	if t.hand == nil {
		return PickResult{}, NewGameError(CodeNoHand, MsgNoHand)
	}
	s := t.findSeat(userID)
	if s == nil {
		return PickResult{}, NewGameError(CodeNotSeated, MsgNotSeated)
	}
	// A packed seat is out of the hand: its cards will never be compared, and
	// a choice now would change a state nobody plays by.
	if s.status != SeatActive {
		return PickResult{}, NewGameError(CodeNotInHand, MsgNotInHand)
	}
	if !t.fiveCardHand() || len(s.cards) <= BaseCardsPerPlayer || s.isBlind {
		return PickResult{}, NewGameError(CodeNotPicking, MsgNotPicking)
	}
	if len(s.picked) > 0 {
		return PickResult{}, NewGameError(CodeDuplicateAction, MsgDuplicateAction)
	}
	picked, ok := pickFrom(s.cards, codes)
	if !ok {
		return PickResult{}, NewGameError(CodeInvalidPick, MsgInvalidPick)
	}
	return t.settlePick(s, picked, PickByPlayer), nil
}

// pickFrom turns the client's three codes into three of the player's own cards.
// It refuses anything but exactly BaseCardsPerPlayer codes, a code the player
// does not hold, and the same card named twice — the three are matched against
// the hand one at a time, so a player holding one ace cannot play three.
// The result keeps the order the cards were DEALT in, not the order they were
// named, so which three play never depends on the order they were tapped.
func pickFrom(held []Card, codes []string) ([]Card, bool) {
	if len(codes) != BaseCardsPerPlayer {
		return nil, false
	}
	used := make([]bool, len(held))
	for _, code := range codes {
		found := false
		for i, card := range held {
			if !used[i] && card.Code() == code {
				used[i] = true
				found = true
				break
			}
		}
		if !found {
			return nil, false
		}
	}
	picked := make([]Card, 0, BaseCardsPerPlayer)
	for i, card := range held {
		if used[i] {
			picked = append(picked, card)
		}
	}
	return picked, true
}

// settlePick records a player's three and closes their window. It is the ONE
// place a choice is made — by the player, or by the clock on their behalf — and
// it does nothing if one has been made already, which is what makes a pick and
// its own deadline arriving together decide exactly once.
func (t *Table) settlePick(s *seat, picked []Card, by PickedBy) PickResult {
	best := EvaluateBest(s.cards).Best
	if len(s.picked) > 0 {
		return PickResult{Picked: CardCodes(s.picked), Best: best, WasBest: sameCards(CardCodes(s.picked), best)}
	}
	s.picked = append([]Card(nil), picked...)
	s.pickedBy = by
	s.picking = false
	s.pickUntil = time.Time{}
	t.syncContribution(s, s.status)
	t.emitState()
	t.armPickTimer()
	codes := CardCodes(s.picked)
	return PickResult{Picked: codes, Best: best, WasBest: sameCards(codes, best)}
}

// sameCards reports whether two sets of wire codes hold the same cards. Both
// come from the same hand in the same order (CardCodes keeps the dealt order),
// so this is a plain comparison rather than a set one.
func sameCards(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// armPickTimer points the table's one pick clock at the earliest window still
// outstanding, or stops it when none is. Called whenever a window opens or
// closes.
func (t *Table) armPickTimer() {
	t.stopPickTimer()
	if t.hand == nil {
		return
	}
	var next time.Time
	for _, s := range t.seats {
		if s == nil || !s.picking || s.pickUntil.IsZero() || len(s.picked) > 0 {
			continue
		}
		if next.IsZero() || s.pickUntil.Before(next) {
			next = s.pickUntil
		}
	}
	if next.IsZero() {
		return
	}
	d := next.Sub(t.clock.Now())
	if d < 0 {
		d = 0
	}
	hand := t.hand
	t.pickTimer = t.clock.AfterFunc(d, func() {
		_ = t.run(func() {
			// A timer stopped a moment too late must not reach into a newer
			// hand: every window belongs to the hand it was opened in.
			if t.hand != hand {
				return
			}
			t.expirePicks()
		})
	})
}

// expirePicks plays the first three for every window whose deadline has passed,
// then re-arms for whatever is left. A window that has not lapsed yet is left
// alone — the one timer serves them all, so it fires for the earliest and finds
// the others still running.
func (t *Table) expirePicks() {
	now := t.clock.Now()
	for _, s := range t.seats {
		if s == nil || !s.picking || len(s.picked) > 0 || s.pickUntil.IsZero() || s.pickUntil.After(now) {
			continue
		}
		t.settlePick(s, s.cards[:BaseCardsPerPlayer], PickByTimeout)
	}
	t.armPickTimer()
}

// stopPickTimer stops the pick clock if it is running.
func (t *Table) stopPickTimer() {
	if t.pickTimer != nil {
		t.pickTimer.Stop()
		t.pickTimer = nil
	}
}

// clearPicks forgets every window and choice. The deal calls it, so a hand
// never starts holding the last one's.
func (t *Table) clearPicks() {
	t.stopPickTimer()
	for _, s := range t.seats {
		if s == nil {
			continue
		}
		s.picked = nil
		s.pickedBy = ""
		s.picking = false
		s.pickUntil = time.Time{}
	}
}

// extendTurn pushes the running turn's deadline out to `until`, when that is
// later than the deadline it already has, and leaves it alone otherwise. The
// turn is re-tokened as setTurn does, so the clock being replaced is stale and
// its timeout is ignored when it fires.
//
// Only the picker's OWN turn is extended, and only while it runs (owner's "fix all
// bugs", 24 Sep 2026): it used to extend whoever held the turn, so every other
// player's first look topped the holder up to a window plus a full turn, and
// it re-armed a clock a pending sideshow had stopped.
func (t *Table) extendTurn(picker *seat, until time.Time) {
	if t.hand == nil || picker == nil || t.hand.turnSeat != picker.seatIndex || t.hand.sideshow != nil {
		return
	}
	s := picker
	if t.seats[s.seatIndex] != s || !until.After(t.hand.turnDeadline) {
		return
	}
	left := until.Sub(t.clock.Now())
	if left < 0 {
		left = 0
	}
	t.hand.turnDeadline = until
	token := util.UUID()
	t.hand.turnToken = token
	seatIndex := s.seatIndex
	t.clearTurnTimer()
	t.turnTimer = t.clock.AfterFunc(left, func() {
		_ = t.run(func() { t.onTurnTimeout(seatIndex, token) })
	})
	t.listener.OnTurn(t.view, TurnEvent{
		UserID:    s.userID,
		SeatIndex: seatIndex,
		Deadline:  Millis(until),
		TimeoutMs: left.Milliseconds(),
		Options:   t.turnOptions(s),
	})
}

// seatAt is the seat at index i, or nil for -1, an index out of range or an
// empty place.
func (t *Table) seatAt(i int) *seat {
	if i < 0 || i >= len(t.seats) {
		return nil
	}
	return t.seats[i]
}
