package poker

import (
	"fmt"
	"strings"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// The hand: the deal, the streets, every move, the showdown and the
// settlement. Everything here runs on the actor.

// startHand deals. It writes NOTHING to PostgreSQL (CLAUDE.md §5.1): blinds
// and antes come out of the seats in memory, and the whole hand lives in the
// live store until a checkpoint brings a wallet up to date.
func (t *Table) startHand() {
	if t.Destroyed() || t.hand != nil {
		return
	}
	started := t.clock.Now()
	t.sweepUnfunded()
	participants := t.fundedSeats()
	if len(participants) < t.cfg.MinPlayers {
		t.setState(game.TableWaiting)
		t.startsAt = nil
		t.emitState()
		return
	}
	v := t.cfg.Variant
	handID := util.UUID()
	button := t.nextButton(participants)

	// One shuffled deck; every card of the hand comes off its top in order.
	hands, stub := game.Deal(len(participants), v.HoleCards)
	h := &hand{
		id:            handID,
		handNo:        t.handNo + 1,
		startedAt:     started,
		streets:       append([]Street(nil), v.Streets...),
		streetIndex:   -1,
		deck:          stub,
		community:     []game.Card{},
		button:        button,
		turnSeat:      -1,
		contributions: make(map[string]*contribution, len(participants)),
		contribOrder:  make([]string, 0, len(participants)),
		actionIDs:     map[string]struct{}{},
	}
	if v.HasDealer {
		h.dealerCards, h.deck = h.deck[:v.HoleCards], h.deck[v.HoleCards:]
	}
	isParticipant := map[*seat]bool{}
	for _, s := range participants {
		isParticipant[s] = true
	}
	for _, s := range t.occupiedSeats() {
		s.cards = []game.Card{}
		s.contributed, s.streetBet = 0, 0
		s.allIn, s.acted, s.drew, s.played = false, false, false, false
		s.lastAction = nil
		if isParticipant[s] {
			s.status = game.SeatActive
		} else {
			s.status = game.SeatWaiting
		}
	}
	for i, s := range participants {
		s.cards = hands[i]
		h.contributions[s.userID] = &contribution{
			userID:       s.userID,
			displayName:  s.displayName,
			seatIndex:    s.seatIndex,
			status:       game.SeatActive,
			cards:        s.cards,
			chipsWritten: s.chips, // PostgreSQL still holds the pre-deal figure
			chips:        s.chips,
		}
		h.contribOrder = append(h.contribOrder, s.userID)
	}
	t.handNo = h.handNo
	t.button = button
	t.lastResult = nil
	t.setHand(h)
	t.setState(game.TableBetting)
	t.startsAt = nil

	// Forced bets: an ante from everyone, or the two blinds.
	if !v.Blinds {
		for _, s := range participants {
			t.post(s, t.ante())
		}
	} else {
		sb, bb := t.blindSeats(participants)
		t.post(sb, t.smallBlind())
		t.post(bb, t.bigBlind())
	}

	ids := make([]string, 0, len(participants))
	for _, s := range participants {
		ids = append(ids, s.userID)
	}
	t.listener.OnHandStarted(t.view, HandStartedEvent{
		HandID: h.id, HandNo: h.handNo, Variant: v.Variant, DealerSeat: button,
		SmallBlind: t.smallBlind(), BigBlind: t.bigBlind(), Ante: t.ante(), Pot: h.pot, Participants: ids,
	})
	for _, s := range participants {
		t.listener.OnCards(t.view, CardsEvent{UserID: s.userID, Cards: game.CardCodes(s.cards)})
	}
	t.beginStreet(0)
	t.emitState()
	if t.onHandStart != nil {
		t.onHandStart(t.clock.Now().Sub(started))
	}
}

// nextButton moves the button to the next participant clockwise.
func (t *Table) nextButton(participants []*seat) int {
	allowed := map[int]bool{}
	for _, s := range participants {
		allowed[s.seatIndex] = true
	}
	n := len(t.seats)
	for step := 1; step <= n; step++ {
		index := ((t.button+step)%n + n) % n
		if allowed[index] {
			return index
		}
	}
	return participants[0].seatIndex
}

// blindSeats: the small blind is the seat after the button and the big
// blind the one after that; heads-up the button posts the small blind.
func (t *Table) blindSeats(participants []*seat) (sb, bb *seat) {
	in := func(s *seat) bool { return s.inHand() }
	if len(participants) == 2 {
		sb = t.seats[t.button]
		bb = t.seats[t.nextSeat(t.button, in)]
		return sb, bb
	}
	sbIndex := t.nextSeat(t.button, in)
	sb = t.seats[sbIndex]
	bb = t.seats[t.nextSeat(sbIndex, in)]
	return sb, bb
}

// post takes a forced bet (blind or ante) from a seat: as much as the seat
// has, marking it all-in when that is less.
func (t *Table) post(s *seat, amount int64) {
	if s == nil || amount <= 0 {
		return
	}
	t.stake(s, amount)
}

// stake moves chips from a seat into the pot: the street bet, the hand's
// contribution and the pot all rise; a seat that puts its last chip in is
// all-in. Never more than the seat has.
func (t *Table) stake(s *seat, amount int64) int64 {
	if amount > s.chips {
		amount = s.chips
	}
	if amount <= 0 {
		return 0
	}
	s.chips -= amount
	s.streetBet += amount
	s.contributed += amount
	t.hand.pot += amount
	if s.chips == 0 {
		s.allIn = true
	}
	if entry := t.hand.contributions[s.userID]; entry != nil {
		entry.chips = s.chips
		entry.contributed = s.contributed
		entry.allIn = s.allIn
	}
	return amount
}

// ------------------------------------------------------------- streets

// beginStreet opens street i: street bets reset, the board dealt, the first
// player put on turn — or, when nobody can act (everyone but one all-in), the
// street is run straight through.
func (t *Table) beginStreet(i int) {
	h := t.hand
	if h == nil {
		return
	}
	h.streetIndex = i
	street := h.street()
	if street == StreetShowdown {
		t.showdown()
		return
	}
	for _, s := range t.seatsInHand() {
		s.acted = false
		s.drew = false
		if i > 0 {
			s.streetBet = 0
		}
	}
	if i > 0 {
		h.currentBet = 0
	} else if t.cfg.Variant.Blinds {
		h.currentBet = t.bigBlind()
	} else {
		h.currentBet = 0
	}
	h.minRaise = t.cfg.BootAmount
	// The board: up to this street's count, off the top of the stub.
	if want := boardBy(street); want > len(h.community) {
		n := want - len(h.community)
		if n > len(h.deck) {
			n = len(h.deck)
		}
		h.community = append(h.community, h.deck[:n]...)
		h.deck = h.deck[n:]
	}
	t.listener.OnStreet(t.view, StreetEvent{Street: street, Community: game.CardCodes(h.community), Pot: h.pot})

	switch {
	case street.IsBetting():
		if !t.streetHasSomeoneToAct() {
			t.endStreet()
			return
		}
		t.setTurn(t.firstToAct())
	case street == StreetDraw:
		t.setTurn(t.nextSeat(h.button, func(s *seat) bool { return s.inHand() && !s.drew }))
	case street == StreetDecision:
		t.setTurn(t.nextSeat(h.button, func(s *seat) bool { return s.inHand() && !s.acted }))
	}
}

// firstToAct: preflop the seat after the big blind (heads-up: the button,
// who posted the small blind); on every other street the first seat that
// can act clockwise from the button.
func (t *Table) firstToAct() int {
	h := t.hand
	if h.streetIndex == 0 && t.cfg.Variant.Blinds {
		inHand := t.seatsInHand()
		var bbIndex int
		if len(inHand) == 2 {
			bbIndex = t.nextSeat(h.button, func(s *seat) bool { return s.inHand() })
		} else {
			sbIndex := t.nextSeat(h.button, func(s *seat) bool { return s.inHand() })
			bbIndex = t.nextSeat(sbIndex, func(s *seat) bool { return s.inHand() })
		}
		if next := t.nextSeat(bbIndex, t.needsAction); next >= 0 {
			return next
		}
	}
	return t.nextSeat(h.button, t.needsAction)
}

// needsAction: this seat still owes the street a decision — it can act and
// has not yet acted since the last bet or raise, or has not matched the bet.
func (t *Table) needsAction(s *seat) bool {
	if !s.canAct() {
		return false
	}
	return !s.acted || s.streetBet < t.hand.currentBet
}

// streetHasSomeoneToAct: on a betting street, at least two seats are still
// in AND at least one can still act; a lone player who can act while every
// other seat is all-in has nothing to bet against once they have matched.
func (t *Table) streetHasSomeoneToAct() bool {
	h := t.hand
	if h == nil {
		return false
	}
	street := h.street()
	switch {
	case street.IsBetting():
		inHand := t.seatsInHand()
		if len(inHand) < 2 {
			return false
		}
		canAct := 0
		for _, s := range inHand {
			if s.canAct() {
				canAct++
			}
		}
		if canAct == 0 {
			return false
		}
		if canAct == 1 {
			// One player with chips against all-in players: they only act if
			// they still owe a call.
			for _, s := range inHand {
				if s.canAct() && s.streetBet < h.currentBet {
					return true
				}
			}
			return false
		}
		for _, s := range inHand {
			if t.needsAction(s) {
				return true
			}
		}
		return false
	case street == StreetDraw:
		for _, s := range t.seatsInHand() {
			if !s.drew {
				return true
			}
		}
		return false
	case street == StreetDecision:
		for _, s := range t.seatsInHand() {
			if !s.acted {
				return true
			}
		}
		return false
	}
	return false
}

// advanceAfter moves the turn on after `from` acted, or ends the street.
func (t *Table) advanceAfter(from int) {
	h := t.hand
	if h == nil {
		return
	}
	if t.resolveIfOnlyOneLeft() {
		return
	}
	if !t.streetHasSomeoneToAct() {
		t.endStreet()
		return
	}
	var next int
	switch street := h.street(); {
	case street.IsBetting():
		next = t.nextSeat(from, t.needsAction)
	case street == StreetDraw:
		next = t.nextSeat(from, func(s *seat) bool { return s.inHand() && !s.drew })
	default:
		next = t.nextSeat(from, func(s *seat) bool { return s.inHand() && !s.acted })
	}
	if next < 0 {
		t.endStreet()
		return
	}
	t.setTurn(next)
	t.emitState()
}

// endStreet closes the street: the next one begins, or the showdown.
func (t *Table) endStreet() {
	h := t.hand
	if h == nil {
		return
	}
	t.clearTurnTimer()
	h.turnSeat = -1
	h.turnDeadline = time.Time{}
	h.turnToken = ""
	t.beginStreet(h.streetIndex + 1)
}

// resolveIfOnlyOneLeft: one player still in → they take everything, no
// cards shown; none → the hand ends all_left with every stake refunded.
func (t *Table) resolveIfOnlyOneLeft() bool {
	h := t.hand
	if h == nil {
		return true
	}
	inHand := t.seatsInHand()
	if len(inHand) > 1 {
		return false
	}
	if len(inHand) == 1 {
		if t.cfg.Variant.HasDealer {
			// Against the house the last player still plays their hand out.
			return false
		}
		t.endHandWithWinners(WinLastStanding, nil, nil, nil)
		return true
	}
	t.endHandRefunded(WinAllLeft)
	return true
}

// --------------------------------------------------------------- moves

// act is Act's actor body.
func (t *Table) act(userID string, action Action, req ActRequest) (ActResult, error) {
	if _, ok := AllActions[action]; !ok {
		return ActResult{}, game.Errorf(CodeUnknownAction, MsgUnknownActionFmt, string(action))
	}
	h := t.hand
	if h == nil {
		return ActResult{}, errNoHand()
	}
	s := t.findSeat(userID)
	if s == nil {
		return ActResult{}, errNotSeated()
	}
	if !s.inHand() {
		return ActResult{}, errNotInHand()
	}
	if h.turnSeat != s.seatIndex {
		return ActResult{}, errNotYourTurn()
	}
	actionID := req.ActionID
	if actionID == "" || strings.ContainsRune(actionID, ':') {
		actionID = util.UUID()
	}
	if _, seen := h.actionIDs[actionID]; seen {
		return ActResult{}, errDuplicateAction()
	}

	street := h.street()
	var result ActResult
	var err error
	switch action {
	case ActionFold:
		if street != StreetDecision && !street.IsBetting() {
			return ActResult{}, errInvalid(MsgActionOffStreet)
		}
		result = t.fold(s, "")
	case ActionCheck:
		if !street.IsBetting() {
			return ActResult{}, errInvalid(MsgActionOffStreet)
		}
		result, err = t.applyCheck(s, "")
	case ActionCall:
		if !street.IsBetting() {
			return ActResult{}, errInvalid(MsgActionOffStreet)
		}
		result, err = t.applyCall(s)
	case ActionBet, ActionRaise:
		if !street.IsBetting() {
			return ActResult{}, errInvalid(MsgActionOffStreet)
		}
		if !req.HasAmount {
			return ActResult{}, game.NewGameError(CodeInvalidAmount, MsgAmountNotWhole)
		}
		result, err = t.applyBet(s, action, req.Amount)
	case ActionAllIn:
		if !street.IsBetting() {
			return ActResult{}, errInvalid(MsgActionOffStreet)
		}
		result, err = t.applyAllIn(s)
	case ActionPlay:
		if street != StreetDecision {
			return ActResult{}, errInvalid(MsgNotDecision)
		}
		result, err = t.applyPlay(s)
	case ActionDraw:
		if street != StreetDraw {
			return ActResult{}, errInvalid(MsgNotDrawing)
		}
		result, err = t.applyDraw(s, req.Cards, "")
	}
	if err != nil {
		return ActResult{}, err
	}
	h.actionIDs[actionID] = struct{}{}
	s.missedTurns = 0
	return result, nil
}

// options is what the player on turn may do (YouView.options,
// TurnEvent.Options): the same figures act validates against.
func (t *Table) options(s *seat) Options {
	h := t.hand
	o := Options{Street: h.street()}
	if h == nil || !s.inHand() || h.turnSeat != s.seatIndex {
		return o
	}
	switch street := h.street(); {
	case street.IsBetting():
		o.Fold = true
		toCall := h.currentBet - s.streetBet
		if toCall <= 0 {
			o.Check = true
		} else {
			o.Call = true
			o.CallAmount = min(toCall, s.chips)
		}
		if h.currentBet == 0 {
			if s.chips > 0 {
				o.Bet = true
				o.MinBet = min(t.cfg.BootAmount, s.chips)
				o.MaxBet = s.chips
			}
		} else if s.chips > toCall {
			o.Raise = true
			o.MinRaise = min(h.currentBet+h.minRaise, s.streetBet+s.chips)
			o.MaxRaise = s.streetBet + s.chips
		}
		if s.chips > 0 {
			o.AllIn = true
			o.AllInAmount = s.streetBet + s.chips
		}
	case street == StreetDecision:
		o.Fold = true
		if s.chips > 0 {
			o.Play = true
			o.PlayAmount = min(t.ante(), s.chips)
		}
	case street == StreetDraw:
		o.Draw = true
		o.MaxDiscards = t.maxDiscards()
	}
	return o
}

// fold takes a seat out of the hand and checkpoints its stake (hand_packed
// — CHECKPOINT 2 of 3). reason "" is the player's own choice.
func (t *Table) fold(s *seat, reason string) ActResult {
	h := t.hand
	s.status = game.SeatPacked
	s.lastAction = actionPtr(ActionFold)
	s.acted = true
	if entry := h.contributions[s.userID]; entry != nil {
		entry.status = game.SeatPacked
		entry.folded = true
		entry.chips = s.chips
		entry.contributed = s.contributed
		t.checkpoint(entry, game.LedgerReasonHandPacked, game.PackedActionID(h.id, s.userID), false)
	}
	t.listener.OnAction(t.view, ActionEvent{UserID: s.userID, SeatIndex: s.seatIndex, Action: ActionFold, Street: h.street(), Pot: h.pot, Reason: reason})
	t.clearTurnTimer()
	t.advanceAfter(s.seatIndex)
	return ActResult{Action: ActionFold}
}

func (t *Table) applyCheck(s *seat, reason string) (ActResult, error) {
	h := t.hand
	if s.streetBet < h.currentBet {
		return ActResult{}, errInvalid(MsgCannotCheck)
	}
	s.acted = true
	s.lastAction = actionPtr(ActionCheck)
	t.listener.OnAction(t.view, ActionEvent{UserID: s.userID, SeatIndex: s.seatIndex, Action: ActionCheck, Street: h.street(), Pot: h.pot, Reason: reason})
	t.clearTurnTimer()
	t.advanceAfter(s.seatIndex)
	return ActResult{Action: ActionCheck}, nil
}

func (t *Table) applyCall(s *seat) (ActResult, error) {
	h := t.hand
	toCall := h.currentBet - s.streetBet
	if toCall <= 0 {
		return ActResult{}, errInvalid(MsgNothingToCall)
	}
	t.stake(s, toCall)
	s.acted = true
	s.lastAction = actionPtr(ActionCall)
	t.markPlayed(s)
	t.listener.OnAction(t.view, ActionEvent{UserID: s.userID, SeatIndex: s.seatIndex, Action: ActionCall, Amount: s.streetBet, Street: h.street(), Pot: h.pot, AllIn: s.allIn})
	t.clearTurnTimer()
	t.advanceAfter(s.seatIndex)
	return ActResult{Action: ActionCall, Amount: game.Int64Ptr(s.streetBet), AllIn: s.allIn}, nil
}

// applyBet is a bet (no bet yet on the street) or a raise (to amount, the
// player's whole street bet after it).
func (t *Table) applyBet(s *seat, action Action, amount int64) (ActResult, error) {
	h := t.hand
	o := t.options(s)
	var lo, hi int64
	switch action {
	case ActionBet:
		if !o.Bet {
			if h.currentBet > 0 {
				return ActResult{}, errInvalid(MsgCannotBet)
			}
			return ActResult{}, errInvalid(MsgActionOffStreet)
		}
		lo, hi = o.MinBet, o.MaxBet
	default:
		if !o.Raise {
			if h.currentBet == 0 {
				return ActResult{}, errInvalid(MsgCannotRaise)
			}
			return ActResult{}, errInvalid(MsgNoChipsToRaise)
		}
		lo, hi = o.MinRaise, o.MaxRaise
	}
	if amount < lo || amount > hi {
		return ActResult{}, game.Errorf(CodeInvalidAmount, MsgAmountRangeFormat, thousands(lo), thousands(hi))
	}
	t.raiseTo(s, amount, action)
	return ActResult{Action: action, Amount: game.Int64Ptr(s.streetBet), AllIn: s.allIn}, nil
}

// applyAllIn puts the whole stack in: a raise when it beats the street's bet,
// otherwise a call for less.
func (t *Table) applyAllIn(s *seat) (ActResult, error) {
	h := t.hand
	if s.chips <= 0 {
		return ActResult{}, errInvalid(MsgActionOffStreet)
	}
	total := s.streetBet + s.chips
	if total > h.currentBet {
		action := ActionRaise
		if h.currentBet == 0 {
			action = ActionBet
		}
		t.raiseTo(s, total, action)
		return ActResult{Action: ActionAllIn, Amount: game.Int64Ptr(s.streetBet), AllIn: true}, nil
	}
	t.stake(s, s.chips)
	s.acted = true
	s.lastAction = actionPtr(ActionAllIn)
	t.markPlayed(s)
	t.listener.OnAction(t.view, ActionEvent{UserID: s.userID, SeatIndex: s.seatIndex, Action: ActionAllIn, Amount: s.streetBet, Street: h.street(), Pot: h.pot, AllIn: true})
	t.clearTurnTimer()
	t.advanceAfter(s.seatIndex)
	return ActResult{Action: ActionAllIn, Amount: game.Int64Ptr(s.streetBet), AllIn: true}, nil
}

// raiseTo sets the street's bet to amount from this seat and reopens the
// action for everyone else. A raise smaller than the last (an all-in for
// less) does not raise the minimum.
func (t *Table) raiseTo(s *seat, amount int64, action Action) {
	h := t.hand
	previous := h.currentBet
	t.stake(s, amount-s.streetBet)
	if s.streetBet > previous {
		if by := s.streetBet - previous; by >= h.minRaise {
			h.minRaise = by
		}
		h.currentBet = s.streetBet
		for _, other := range t.seatsInHand() {
			if other != s {
				other.acted = false
			}
		}
	}
	s.acted = true
	s.lastAction = actionPtr(action)
	t.markPlayed(s)
	t.listener.OnAction(t.view, ActionEvent{UserID: s.userID, SeatIndex: s.seatIndex, Action: action, Amount: s.streetBet, Street: h.street(), Pot: h.pot, AllIn: s.allIn})
	t.clearTurnTimer()
	t.advanceAfter(s.seatIndex)
}

// markPlayed: a voluntary bet beyond the forced one — "played" (requirement 16).
func (t *Table) markPlayed(s *seat) {
	if entry := t.hand.contributions[s.userID]; entry != nil {
		entry.played = true
	}
}

// applyPlay is 3-Card Poker's play bet.
func (t *Table) applyPlay(s *seat) (ActResult, error) {
	h := t.hand
	if s.chips <= 0 {
		return ActResult{}, game.NewGameError(game.CodeInsufficientChips, MsgInsufficientToPlay)
	}
	amount := t.stake(s, t.ante())
	s.played = true
	s.acted = true
	s.lastAction = actionPtr(ActionPlay)
	t.markPlayed(s)
	t.listener.OnAction(t.view, ActionEvent{UserID: s.userID, SeatIndex: s.seatIndex, Action: ActionPlay, Amount: amount, Street: h.street(), Pot: h.pot, AllIn: s.allIn})
	t.clearTurnTimer()
	t.advanceAfter(s.seatIndex)
	return ActResult{Action: ActionPlay, Amount: game.Int64Ptr(amount), AllIn: s.allIn}, nil
}

// applyDraw exchanges the named cards (none = stand pat) for the next off
// the deck, tells the player their new hand and the room how many went.
func (t *Table) applyDraw(s *seat, codes []string, reason string) (ActResult, error) {
	h := t.hand
	if len(codes) > t.maxDiscards() {
		return ActResult{}, game.Errorf(CodeInvalidDiscard, MsgTooManyDiscards, t.maxDiscards())
	}
	held := map[string]int{}
	for i, c := range s.cards {
		held[c.Code()] = i
	}
	indices := make([]int, 0, len(codes))
	seen := map[string]bool{}
	for _, code := range codes {
		if seen[code] {
			return ActResult{}, game.NewGameError(CodeInvalidDiscard, MsgDuplicateDiscard)
		}
		seen[code] = true
		i, ok := held[code]
		if !ok {
			return ActResult{}, game.NewGameError(CodeInvalidDiscard, MsgNotYourCard)
		}
		indices = append(indices, i)
	}
	if len(indices) > len(h.deck) {
		return ActResult{}, game.NewGameError(CodeInvalidDiscard, MsgTooManyDiscards)
	}
	fresh := make([]game.Card, len(s.cards))
	copy(fresh, s.cards)
	for _, i := range indices {
		fresh[i] = h.deck[0]
		h.deck = h.deck[1:]
	}
	s.cards = fresh
	if entry := h.contributions[s.userID]; entry != nil {
		entry.cards = fresh
	}
	s.drew = true
	s.lastAction = actionPtr(ActionDraw)
	n := len(indices)
	t.listener.OnCards(t.view, CardsEvent{UserID: s.userID, Cards: game.CardCodes(s.cards)})
	t.listener.OnDraw(t.view, DrawEvent{UserID: s.userID, SeatIndex: s.seatIndex, Discarded: n})
	t.listener.OnAction(t.view, ActionEvent{UserID: s.userID, SeatIndex: s.seatIndex, Action: ActionDraw, Street: h.street(), Pot: h.pot, Reason: reason, Discarded: &n})
	t.clearTurnTimer()
	t.advanceAfter(s.seatIndex)
	return ActResult{Action: ActionDraw, Discarded: &n}, nil
}

// ------------------------------------------------------------- showdown

// handOf scores a player's cards under the variant, with the board where
// there is one; ok false while there are not enough cards to say.
func (t *Table) handOf(cards []game.Card) (Hand, bool) {
	v := t.cfg.Variant
	var board []game.Card
	if t.hand != nil {
		board = t.hand.community
	}
	switch {
	case v.HasDealer:
		if len(cards) != 3 {
			return Hand{}, false
		}
		return Evaluate3(cards), true
	case v.UseExactlyTwoHole:
		return BestOmaha(cards, board)
	case v.CommunityCards > 0:
		return BestHoldem(cards, board)
	default:
		if len(cards) != 5 {
			return Hand{}, false
		}
		return Evaluate5(cards), true
	}
}

// showdown: the streets are done. Against the house the dealer's hand
// decides each player; otherwise the best hand(s) take the pots.
func (t *Table) showdown() {
	h := t.hand
	if h == nil {
		return
	}
	if t.cfg.Variant.HasDealer {
		t.resolveDealer()
		return
	}
	// Any community cards not yet dealt (an all-in run-out) come out now.
	if want := t.cfg.Variant.CommunityCards; want > len(h.community) {
		n := min(want-len(h.community), len(h.deck))
		h.community = append(h.community, h.deck[:n]...)
		h.deck = h.deck[n:]
	}
	hands := map[int]Hand{}
	reveals := []Reveal{}
	for _, s := range t.seatsInHand() {
		hd, ok := t.handOf(s.cards)
		if !ok {
			continue
		}
		hands[s.seatIndex] = hd
		reveals = append(reveals, Reveal{UserID: s.userID, SeatIndex: s.seatIndex, Cards: game.CardCodes(s.cards), Best: hd.Best, HandName: hd.Name, Category: hd.Category})
	}
	t.endHandWithWinners(WinShowdown, hands, reveals, nil)
}

// endHandWithWinners pays the pots (a lone player takes them all without a
// showdown), settles, and announces. hands may be nil (last standing).
func (t *Table) endHandWithWinners(reason WinReason, hands map[int]Hand, reveals []Reveal, dealer *DealerReveal) {
	h := t.hand
	if h == nil {
		return
	}
	pots := t.potsNow()
	if hands == nil {
		hands = map[int]Hand{}
	}
	payouts, totals := Award(pots, hands, h.button, len(t.seats))
	results := make([]PotResult, len(pots))
	for i, p := range pots {
		results[i] = PotResult{Amount: p.Amount, Eligible: p.Eligible, Winners: []PotWinner{}}
	}
	for _, p := range payouts {
		s := t.seats[p.Seat]
		if s == nil {
			continue
		}
		w := PotWinner{UserID: s.userID, SeatIndex: p.Seat, Amount: p.Amount}
		if hd, ok := hands[p.Seat]; ok {
			w.HandName = hd.Name
		}
		results[p.Pot].Winners = append(results[p.Pot].Winners, w)
	}
	// A winner took a share of a contested pot, or came out ahead.
	contested := map[int]bool{}
	for _, p := range payouts {
		if len(pots[p.Pot].Eligible) > 1 {
			contested[p.Seat] = true
		}
	}
	winners := map[string]bool{}
	for seatIndex, amount := range totals {
		s := t.seats[seatIndex]
		if s == nil {
			continue
		}
		s.chips += amount
		if entry := h.contributions[s.userID]; entry != nil {
			entry.won = amount
			entry.chips = s.chips
			if contested[seatIndex] || amount > entry.contributed {
				winners[s.userID] = true
			}
		}
	}
	for _, s := range t.seatsInHand() {
		if winners[s.userID] {
			s.status = game.SeatWon
		} else {
			s.status = game.SeatLost
		}
		if entry := h.contributions[s.userID]; entry != nil {
			entry.status = s.status
		}
	}
	for i := range reveals {
		reveals[i].Won = totals[reveals[i].SeatIndex]
	}
	if reveals == nil {
		reveals = []Reveal{}
	}
	if reason == WinShowdown || dealer != nil {
		t.listener.OnShowdown(t.view, ShowdownEvent{Reveals: reveals, Community: game.CardCodes(h.community), Dealer: dealer, Reason: reason})
	}
	t.settle(reason, winners, results, reveals, dealer)
}

// endHandRefunded ends a hand nobody could win (the room destroyed under a
// live hand, every player gone): each stake goes back where it came from.
func (t *Table) endHandRefunded(reason WinReason) {
	h := t.hand
	if h == nil {
		return
	}
	for _, entry := range h.contributions {
		if entry.contributed <= 0 {
			continue
		}
		entry.chips += entry.contributed
		entry.won = entry.contributed
		if s := t.findSeat(entry.userID); s != nil {
			s.chips = entry.chips
			if s.inHand() {
				s.status = game.SeatLost
				entry.status = s.status
			}
		}
	}
	t.settle(reason, map[string]bool{}, []PotResult{}, []Reveal{}, nil)
}

// settle is CHECKPOINT 3 of 3 — the hand end: one Settle for everyone who
// put chips in, then the announcement and the next countdown.
func (t *Table) settle(reason WinReason, winners map[string]bool, pots []PotResult, reveals []Reveal, dealer *DealerReveal) {
	h := t.hand
	t.clearTurnTimer()
	entries := make([]game.SettleEntry, 0, len(h.contribOrder))
	summary := make([]HandSummaryEntry, 0, len(h.contribOrder))
	for _, userID := range h.contribOrder {
		entry := h.contributions[userID]
		if entry == nil || entry.contributed <= 0 {
			continue
		}
		isWinner := winners[userID]
		summary = append(summary, HandSummaryEntry{UserID: userID, DisplayName: entry.displayName, SeatIndex: entry.seatIndex, Contributed: entry.contributed, Won: entry.won, Status: entry.status})
		if entry.leftMidHand && !isWinner {
			continue // resolved by their own leave checkpoint
		}
		rowReason := game.LedgerReasonHandLoss
		var pot int64
		if isWinner {
			rowReason = game.LedgerReasonHandWin
			pot = entry.won
		}
		entries = append(entries, game.SettleEntry{
			UserID:      userID,
			Delta:       entry.chips - entry.chipsWritten,
			ActionID:    game.SettleActionID(h.id, userID),
			Reason:      rowReason,
			Outcome:     true,
			IsWinner:    isWinner,
			DidChaal:    entry.played,
			LeftMidHand: entry.leftMidHand,
			Pot:         pot,
			Game:        game.GamePoker,
			Variant:     t.cfg.Category,
		})
	}
	req := game.SettleRequest{RoomID: t.id, HandID: h.id, Entries: entries}
	if _, err := t.ledger.Settle(t.Context(), req); err != nil {
		t.hooks.OnRoomPersistError(t, game.PersistErrorEvent{Reason: "settle", HandID: h.id, Err: err})
		t.Settler.Owe(req, true)
		t.Settler.Retry(req, 1)
	} else {
		t.version.Add(1)
		for _, entry := range h.contributions {
			entry.chipsWritten = entry.chips
		}
	}

	community := game.CardCodes(h.community)
	t.lastResult = &ResultView{HandID: h.id, Reason: reason, Pots: pots, Reveals: reveals, Community: community, Dealer: dealer}
	t.setHand(nil)
	t.setState(game.TableWaiting)
	nextHandAt := t.clock.Now().Add(t.cfg.NextHandDelay)
	t.listener.OnHandEnded(t.view, HandEndedEvent{
		HandID: h.id, HandNo: h.handNo, Variant: t.cfg.Variant.Variant, Reason: reason, Pot: h.pot,
		Pots: pots, Reveals: reveals, Community: community, Dealer: dealer, Summary: summary, NextHandAt: game.Millis(nextHandAt),
	})
	// Cards stay on show through the celebration; the next deal clears them.
	t.emitState()
	t.maybeStart()
}

// thousands is a comma-grouped integer for messages ("50,000").
func thousands(n int64) string {
	s := fmt.Sprintf("%d", n)
	neg := strings.HasPrefix(s, "-")
	if neg {
		s = s[1:]
	}
	var out []byte
	for i, c := range []byte(s) {
		if i > 0 && (len(s)-i)%3 == 0 {
			out = append(out, ',')
		}
		out = append(out, c)
	}
	if neg {
		return "-" + string(out)
	}
	return string(out)
}
