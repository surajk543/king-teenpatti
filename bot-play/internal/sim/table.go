package sim

import (
	"fmt"
	"math"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/decision"
	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// variations is the menu a variation window offers: the server's seven less
// FIVE_CARD, which the simulation does not deal.
var variations = []string{protocol.VariationMuflis, protocol.VariationAK47, protocol.VariationJoker,
	protocol.VariationHukam, protocol.VariationLowestJoker, protocol.VariationHighestJoker}

// table is one simulated Teen Patti table (the server's game.Table, much
// reduced): WAITING → STARTING → BETTING → (SHOWDOWN) → WAITING.
type table struct {
	s           *Server
	serial      int
	id, code    string
	entry       protocol.TableEntry
	r           rules
	turnTimeout time.Duration
	seats       []*seat
	state       string
	handNo      int
	dealer      int
	startsAt    time.Time
	startTask   *task
	hand        *hand
	deck        *rng.Rand
	sweeping    bool
	dead        bool
}

// seat is an occupied seat. Its stack is its account's chips.
type seat struct {
	t           *table
	idx         int
	acct        *account
	status      string
	isBlind     bool
	blindMoves  int
	cards       []string
	lastBet     int64
	lastAction  *string
	contributed int64
	missed      int
	asked       bool // a sideshow asked this turn
	grace       *task
}

// hand is the hand in play.
type hand struct {
	id            string
	pot, stake    int64 // stake in blind units
	round         int
	turn, start   int
	deadline      time.Time
	turnTask      *task
	token         int
	ids           map[string]bool // userId:actionId already applied
	parts         []*seat         // dealt in, in seat order
	sideshow      *sideshow
	vw            *varWindow
	lastDeparture *account
}

type sideshow struct {
	from, to *seat
	expires  time.Time
	task     *task
}

// varWindow is a variation table's choice of the hand's rules.
type varWindow struct {
	chooser           *account
	seatIdx           int
	started, deadline time.Time
	open              bool
	selected, by      string
	task              *task
}

// ---- seating ----

func (t *table) occupied() int {
	n := 0
	for _, st := range t.seats {
		if st != nil {
			n++
		}
	}
	return n
}

func (t *table) full() bool { return t.occupied() >= len(t.seats) }

func (t *table) funded() []*seat {
	var out []*seat
	for _, st := range t.seats {
		if st != nil && st.acct.chips >= t.entry.BootAmount {
			out = append(out, st)
		}
	}
	return out
}

func (t *table) active() []*seat {
	var out []*seat
	for _, st := range t.seats {
		if st != nil && st.status == protocol.SeatActive {
			out = append(out, st)
		}
	}
	return out
}

// sit seats an account in the first empty seat (a lobby door has checked it
// may sit): room:state to the table, room:joined and chat:history to it.
func (t *table) sit(acct *account) {
	t.system(acct.name + " joined the table")
	idx := 0
	for t.seats[idx] != nil {
		idx++
	}
	st := &seat{t: t, idx: idx, acct: acct, status: protocol.SeatWaiting, isBlind: true, cards: []string{}}
	t.seats[idx], acct.seat, acct.resume = st, st, nil
	t.emitState()
	t.s.send(acct.sess, protocol.EvRoomJoined, t.view(acct))
	t.maybeStart()
}

// removeSeat gives a seat up — a leave, a switch, a kick or the reconnect
// grace. A player still in the hand is packed with reason as the reason.
func (t *table) removeSeat(st *seat, reason string) {
	if t.seats[st.idx] != st {
		return
	}
	h, acct := t.hand, st.acct
	wasActive := h != nil && st.status == protocol.SeatActive
	wasTurn := h != nil && h.turn == st.idx
	wasChoosing := h != nil && h.vw != nil && h.vw.open && h.vw.chooser == acct
	if wasChoosing {
		t.closeVariation(protocol.VariationMuflis, "LEFT", false)
	}
	if h != nil && h.sideshow != nil && (h.sideshow.from == st || h.sideshow.to == st) {
		t.resolveSideshow(false, "left")
	}
	t.seats[st.idx], acct.seat = nil, nil
	st.grace.cancel()
	t.system(acct.name + " left the table")
	switch {
	case wasActive && t.hand == h:
		st.status = protocol.SeatPacked
		h.lastDeparture = acct
		t.broadcastAction(st, protocol.ActionPack, 0, reason, nil)
		if !t.resolveIfOnlyOneLeft() && (wasTurn || wasChoosing) {
			t.clearTurn()
			t.advanceTurn(st.idx)
		}
	case t.state == protocol.TableStarting && len(t.funded()) < minPlayers:
		t.startTask.cancel()
		t.startTask, t.startsAt, t.state = nil, time.Time{}, protocol.TableWaiting
	case t.state == protocol.TableWaiting:
		t.maybeStart()
	}
	t.emitState()
	if t.occupied() == 0 {
		t.destroy()
	}
}

// kick shows a player out: idle (missed turns) or insufficient_chips.
func (t *table) kick(st *seat, reason, message string) {
	if t.seats[st.idx] != st {
		return
	}
	acct := st.acct
	t.removeSeat(st, reason)
	t.s.send(acct.sess, protocol.EvRoomKicked, protocol.RoomKicked{RoomID: t.id, Reason: reason, Message: message})
	if reason == "idle" && acct.sess == nil && !t.dead {
		acct.resume = &resumeOffer{t: t, at: t.s.now()} // as the server offers it
	}
}

func (t *table) destroy() {
	if t.dead {
		return
	}
	t.dead = true
	t.startTask.cancel()
	t.s.tables = slices.DeleteFunc(t.s.tables, func(x *table) bool { return x == t })
	delete(t.s.byCode, t.code)
	t.s.log.Debug("table closed", "roomId", t.id)
}

// ---- the hand ----

// maybeStart counts down to the next deal once two funded players sit.
func (t *table) maybeStart() {
	if t.dead || t.sweeping || t.state != protocol.TableWaiting || t.startTask != nil {
		return
	}
	t.sweep()
	if t.dead || len(t.funded()) < minPlayers {
		return
	}
	delay := t.s.cfg.NextHandDelay
	t.state, t.startsAt = protocol.TableStarting, t.s.now().Add(delay)
	t.startTask = t.s.after(delay, t.startHand)
	t.emitState()
}

// sweep shows out, between hands, everyone who cannot cover the boot.
func (t *table) sweep() {
	if t.hand != nil {
		return
	}
	var short []*seat
	for _, st := range t.seats {
		if st != nil && st.acct.chips < t.entry.BootAmount {
			short = append(short, st)
		}
	}
	t.sweeping = true
	for _, st := range short {
		t.kick(st, protocol.CodeInsufficientChips, "You don't have enough coins to remain in this table")
	}
	t.sweeping = false
}

func (t *table) startHand() {
	t.startTask = nil
	if t.dead || t.hand != nil {
		return
	}
	t.sweep()
	if t.dead {
		return
	}
	t.startsAt = time.Time{}
	parts := t.funded()
	if len(parts) < minPlayers {
		t.state = protocol.TableWaiting
		t.emitState()
		return
	}
	boot := t.entry.BootAmount
	t.handNo++
	t.dealer = t.nextAmong(t.dealer, parts)
	deck := decision.Deck()
	for i := len(deck) - 1; i > 0; i-- {
		j := t.deck.IntN(i + 1)
		deck[i], deck[j] = deck[j], deck[i]
	}
	h := &hand{id: t.s.uuid("hand", t.id, strconv.Itoa(t.handNo)), pot: boot * int64(len(parts)), stake: boot,
		turn: -1, start: -1, ids: map[string]bool{}, parts: parts}
	for _, st := range t.seats {
		if st != nil {
			st.status, st.cards, st.isBlind, st.blindMoves = protocol.SeatWaiting, []string{}, true, 0
			st.lastBet, st.lastAction, st.contributed = 0, nil, 0
		}
	}
	ids := make([]string, len(parts))
	for i, st := range parts {
		st.status, st.cards, st.contributed = protocol.SeatActive, deck[3*i:3*i+3], boot
		st.acct.chips -= boot
		ids[i] = st.acct.id
	}
	t.hand, t.state = h, protocol.TableBetting
	t.s.stats.HandsDealt++
	t.broadcast(protocol.EvGameHandStarted, handStartedWire{HandID: h.id, HandNo: t.handNo, DealerSeat: t.dealer,
		BootAmount: boot, Pot: h.pot, Stake: h.stake, Participants: ids, RoomID: t.id})
	h.start = t.nextActive(t.dealer)
	if t.entry.Category == protocol.CategoryVariation {
		t.beginVariation(h.start)
	} else {
		t.setTurn(h.start, true)
	}
	t.emitState()
}

// setTurn puts a seat on the clock. fresh is false when a player gets their
// clock back after their own sideshow: their one ask stays used.
func (t *table) setTurn(i int, fresh bool) {
	h, st := t.hand, t.seats[i]
	if h == nil || st == nil {
		return
	}
	h.turn = i
	if fresh {
		st.asked = false
	}
	h.deadline = t.s.now().Add(t.turnTimeout)
	h.token++
	token := h.token
	h.turnTask.cancel()
	h.turnTask = t.s.after(t.turnTimeout, func() { t.onTimeout(h, i, token) })
	t.turnEvents(st, t.turnTimeout.Milliseconds())
}

func (t *table) turnEvents(st *seat, timeoutMs int64) {
	h := t.hand
	t.broadcast(protocol.EvGameTurn, turnWire{RoomID: t.id, UserID: st.acct.id, SeatIndex: st.idx,
		Deadline: millis(h.deadline), TimeoutMs: timeoutMs})
	t.s.send(st.acct.sess, protocol.EvGameYourTurn, protocol.YourTurn{RoomID: t.id, Deadline: millis(h.deadline),
		TimeoutMs: timeoutMs, Options: t.options(st)})
}

func (t *table) clearTurn() {
	if t.hand != nil {
		t.hand.turnTask.cancel()
		t.hand.turnTask = nil
	}
}

// onTimeout: the clock ran out — pack, count the miss, and after three in a
// row show the player out (requirement 31).
func (t *table) onTimeout(h *hand, i, token int) {
	if t.hand != h || h.turn != i || h.token != token {
		return
	}
	st := t.seats[i]
	if st == nil || st.status != protocol.SeatActive {
		return
	}
	st.missed++
	t.pack(st, "timeout", true)
	if st.missed >= maxMissedTurns {
		t.kick(st, "idle", fmt.Sprintf("Left the table after %d missed turns", st.missed))
	}
}

// advanceTurn moves the turn clockwise; the pot cap and the round cap end the
// hand in a showdown instead.
func (t *table) advanceTurn(from int) {
	h := t.hand
	if h == nil {
		return
	}
	next := t.nextActive(from)
	if next < 0 {
		return
	}
	if t.r.maxPot > 0 && h.pot+h.stake > t.r.maxPot {
		t.showdown(t.active(), protocol.WinPotLimit, nil)
		return
	}
	if toStart := t.dist(from, h.start); toStart > 0 && toStart <= t.dist(from, next) {
		h.round++
		if t.r.maxBetRounds > 0 && h.round >= t.r.maxBetRounds {
			t.showdown(t.active(), protocol.WinForcedShowdown, nil)
			return
		}
	}
	t.setTurn(next, true)
	t.emitState()
}

// act applies a move of the seat's player (the server's Table.act).
func (t *table) act(st *seat, action string, amount *int64, actionID string) (any, *refusal) {
	h := t.hand
	switch {
	case h == nil:
		return nil, refNoHand
	case st.status != protocol.SeatActive:
		return nil, refNotInHand
	case action != protocol.ActionSee && h.vw != nil && h.vw.open:
		return nil, refuse(protocol.CodeVariationPending, "The variation is still being chosen")
	case action != protocol.ActionSee && h.turn != st.idx:
		return nil, refuse(protocol.CodeNotYourTurn, "It is not your turn")
	case action != protocol.ActionSee && h.sideshow != nil:
		return nil, refuse(protocol.CodeSideshowPending, "A sideshow is already in progress")
	}
	var ack any
	var ref *refusal
	switch action {
	case protocol.ActionSee:
		return t.see(st, false)
	case protocol.ActionChaal, protocol.ActionRaise:
		ack, ref = t.bet(st, action, amount, actionID)
	case protocol.ActionPack:
		t.pack(st, "pack", true)
		ack = actionAck{OK: true, Action: protocol.ActionPack, Reason: "pack"}
	case protocol.ActionShow:
		ack, ref = t.show(st, actionID)
	case protocol.ActionSideshow:
		ack, ref = t.askSideshow(st)
	case protocol.ActionForceSideshow:
		ref = refuse("no_hammers", "You need a hammer to force a sideshow")
	default:
		ref = refuse("no_missiles", "You need a missile to fire")
	}
	if ref == nil {
		st.missed = 0 // a move, not a look, proves the player is here
	}
	return ack, ref
}

// see turns the player's own cards up: free, off-turn, and not a move.
func (t *table) see(st *seat, auto bool) (any, *refusal) {
	if !st.isBlind {
		return nil, refuse("already_seen", "You have already seen your cards")
	}
	h := t.hand
	st.isBlind = false
	t.broadcastAction(st, protocol.ActionSee, 0, "", &auto)
	if !auto && h.turn == st.idx {
		t.turnEvents(st, max(0, h.deadline.Sub(t.s.now()).Milliseconds())) // the seen ladder is double
	}
	t.emitState()
	return actionAck{OK: true, Action: protocol.ActionSee, Auto: &auto}, nil
}

// ladder is the server's betOptions: base = stake (blind) or 2 × stake
// (seen), doubling while under the per-bet ceiling, the stack, the pot cap's
// headroom and the rung limit — and the headroom itself as the one rung when
// the pot cap is all that bars the way.
func (t *table) ladder(st *seat) []int64 {
	h, steps := t.hand, []int64{}
	base := h.stake
	if !st.isBlind {
		base *= 2
	}
	perBet := int64(math.MaxInt64)
	if t.r.potLimitMul > 0 {
		perBet = t.entry.BootAmount * t.r.potLimitMul
	}
	ceiling := min(perBet, st.acct.chips)
	headroom := int64(math.MaxInt64)
	if t.r.maxPot > 0 {
		headroom = t.r.maxPot - h.pot
	}
	for amount := min(base, perBet); amount > 0 && amount <= ceiling && amount <= headroom &&
		(t.r.maxRaiseSteps <= 0 || len(steps) < t.r.maxRaiseSteps); amount *= 2 {
		steps = append(steps, amount)
		if amount > math.MaxInt64/2 {
			break
		}
	}
	if floor := min(base, perBet); len(steps) == 0 && t.r.maxPot > 0 && headroom > 0 && headroom < floor && headroom <= st.acct.chips {
		steps = append(steps, headroom)
	}
	return steps
}

// options is you.options for the seat on turn (the server's turnOptions).
func (t *table) options(st *seat) protocol.TurnOptions {
	h, steps := t.hand, t.ladder(st)
	o := protocol.TurnOptions{CanSee: st.isBlind, RaiseSteps: steps, CanPack: true, IsBlind: st.isBlind,
		CurrentStake: h.stake, Chips: st.acct.chips, Pot: h.pot}
	blocked := t.sideshowBlocked(st)
	if o.CanSideshow = blocked == ""; o.CanSideshow {
		o.SideshowWith = ptr(t.seats[t.right(st.idx)].acct.name)
	}
	if h.sideshow != nil { // the turn is frozen: only a look is allowed
		o.RaiseSteps, o.CanPack = []int64{}, false
		return o
	}
	if len(steps) > 0 {
		o.Chaal, o.MaxBet = ptr(steps[0]), ptr(steps[len(steps)-1])
		if len(t.active()) == 2 && st.acct.chips >= steps[0] {
			o.Show = ptr(steps[0])
		}
	}
	if len(steps) > 1 {
		o.Raise = ptr(steps[1])
	}
	return o
}

// bet is a chaal or a raise: the amount must be one of the ladder's rungs.
func (t *table) bet(st *seat, action string, amount *int64, actionID string) (any, *refusal) {
	h, steps := t.hand, t.ladder(st)
	if len(steps) == 0 {
		return nil, refuse(protocol.CodeInsufficientChips, "Not enough chips to bet")
	}
	var bet int64
	switch {
	case amount == nil && action == protocol.ActionRaise && len(steps) < 2:
		return nil, refuse(protocol.CodeInvalidBet, "That bet is not available")
	case amount == nil && action == protocol.ActionRaise:
		bet = steps[1]
	case amount == nil:
		bet = steps[0]
	case !slices.Contains(steps, *amount):
		return nil, refuse(protocol.CodeInvalidBet, "That bet amount is not available")
	case action == protocol.ActionRaise && *amount < steps[0]*2:
		return nil, refuse(protocol.CodeInvalidBet, "A raise must be at least double the chaal")
	default:
		bet = *amount
	}
	if st.acct.chips < bet {
		return nil, refuse(protocol.CodeInsufficientChips, "Not enough chips for that bet")
	}
	if ref := t.claimAction(st, actionID); ref != nil {
		return nil, ref
	}
	t.charge(st, bet)
	kind := protocol.ActionChaal
	if action == protocol.ActionRaise || bet >= steps[0]*2 {
		kind = protocol.ActionRaise // what the bet IS names it
	}
	st.lastBet, st.lastAction = bet, ptr(kind)
	h.stake = bet
	if !st.isBlind {
		h.stake = bet / 2
	}
	t.broadcastAction(st, kind, bet, "", nil)
	autoSeen := false
	if st.isBlind {
		st.blindMoves++
		if t.r.maxBlindMoves > 0 && st.blindMoves >= t.r.maxBlindMoves {
			t.see(st, true)
			autoSeen = true
		}
	}
	t.clearTurn()
	t.advanceTurn(st.idx)
	return actionAck{OK: true, Action: kind, Amount: &bet, AutoSeen: &autoSeen}, nil
}

// claimAction refuses an action id this player already used this hand, and
// remembers it otherwise. An id that is empty, longer than 64 characters or
// holds a colon protects nothing, as on the server.
func (t *table) claimAction(st *seat, actionID string) *refusal {
	if actionID == "" || len(actionID) > 64 || strings.ContainsRune(actionID, ':') {
		return nil
	}
	key := st.acct.id + ":" + actionID
	if t.hand.ids[key] {
		return refuse(protocol.CodeDuplicateAction, "That move was already applied")
	}
	t.hand.ids[key] = true
	return nil
}

func (t *table) charge(st *seat, amount int64) {
	st.acct.chips -= amount
	st.contributed += amount
	t.hand.pot += amount
}

// pack folds a seat. advance is false for a sideshow's asked player, who did
// not hold the turn.
func (t *table) pack(st *seat, reason string, advance bool) {
	st.status, st.lastAction = protocol.SeatPacked, ptr(protocol.ActionPack)
	t.broadcastAction(st, protocol.ActionPack, 0, reason, nil)
	t.clearTurn()
	if t.resolveIfOnlyOneLeft() {
		return
	}
	if advance {
		t.advanceTurn(st.idx)
	} else {
		t.emitState()
	}
}

// show is a paid show with exactly two players left; the payer loses a tie.
func (t *table) show(st *seat, actionID string) (any, *refusal) {
	contenders := t.active()
	if len(contenders) != 2 {
		return nil, refuse(protocol.CodeShowUnavailable, "A show needs exactly two players left")
	}
	steps := t.ladder(st)
	if len(steps) == 0 || st.acct.chips < steps[0] {
		return nil, refuse(protocol.CodeInsufficientChips, "Not enough chips to pay for the show")
	}
	if ref := t.claimAction(st, actionID); ref != nil {
		return nil, ref
	}
	cost := steps[0]
	t.charge(st, cost)
	t.broadcastAction(st, protocol.ActionShow, cost, "", nil)
	t.clearTurn()
	t.showdown(contenders, protocol.WinShow, st)
	return actionAck{OK: true, Action: protocol.ActionShow, Amount: &cost}, nil
}

func (t *table) resolveIfOnlyOneLeft() bool {
	switch left := t.active(); len(left) {
	case 1:
		t.endHand(left[0].acct, protocol.WinLastStanding, nil)
	case 0:
		t.endHand(t.hand.lastDeparture, protocol.WinAllLeft, nil)
	default:
		return false
	}
	return true
}

// compare ranks two hands under the hand's rules: classic, or reversed under
// MUFLIS. The simulation plays no wild cards.
func (t *table) compare(a, b decision.Hand) int {
	if h := t.hand; h != nil && h.vw != nil && h.vw.selected == protocol.VariationMuflis {
		return decision.Compare(b, a)
	}
	return decision.Compare(a, b)
}

// showdown compares every contender; an exact tie goes to the seat nearest
// the dealer going clockwise (the dealer's own first), and against the
// player who paid for the show. The pot is never split.
func (t *table) showdown(contenders []*seat, reason string, payer *seat) {
	t.state = protocol.TableShowdown
	pref := append([]*seat(nil), contenders...)
	sort.SliceStable(pref, func(i, j int) bool {
		if (pref[i] == payer) != (pref[j] == payer) {
			return pref[j] == payer
		}
		return t.dist(t.dealer, pref[i].idx) < t.dist(t.dealer, pref[j].idx)
	})
	hands := map[*seat]decision.Hand{}
	for _, c := range contenders {
		hands[c], _ = decision.Rank(c.cards)
	}
	best := pref[0]
	for _, c := range pref[1:] {
		if t.compare(hands[c], hands[best]) > 0 {
			best = c
		}
	}
	reveals := make([]revealWire, 0, len(contenders))
	for _, c := range contenders {
		reveals = append(reveals, revealWire{UserID: c.acct.id, SeatIndex: c.idx, Cards: c.cards,
			HandName: hands[c].Name, Category: hands[c].Category, Won: c == best})
		if c != best {
			c.status = protocol.SeatLost
		}
	}
	t.broadcast(protocol.EvGameShowdown, showdownWire{Reveals: reveals, Reason: reason, Variation: t.variationName(), RoomID: t.id})
	t.endHand(best.acct, reason, reveals)
}

// endHand pays the pot to the winner (seated or not) and returns the table to
// WAITING, then counts down to the next deal.
func (t *table) endHand(winner *account, reason string, reveals []revealWire) {
	h := t.hand
	t.clearTurn()
	if h.sideshow != nil {
		h.sideshow.task.cancel()
		h.sideshow = nil
	}
	if h.vw != nil {
		h.vw.task.cancel()
		h.vw.open = false
	}
	ev := handEndedWire{HandID: h.id, HandNo: t.handNo, Pot: h.pot, Reason: reason, Reveals: reveals,
		NextHandAt: millis(t.s.now().Add(t.s.cfg.NextHandDelay)), Variation: t.variationName(), RoomID: t.id}
	if ev.Reveals == nil {
		ev.Reveals = []revealWire{}
	}
	if winner != nil {
		winner.chips += h.pot
		ev.WinnerID, ev.WinnerName = ptr(winner.id), ptr(winner.name)
		if st := winner.seat; st != nil && st.t == t {
			st.status = protocol.SeatWon
		}
	} else {
		for _, p := range h.parts { // unreachable in practice; the pot is never lost
			p.acct.chips += p.contributed
		}
	}
	t.hand, t.state = nil, protocol.TableWaiting
	t.s.stats.HandsCompleted++
	t.broadcast(protocol.EvGameHandEnded, ev)
	t.emitState()
	t.maybeStart()
}

// ---- the sideshow ----

var sideshowMessages = map[string]string{
	protocol.CodeNoHand: "No hand is in progress", protocol.CodeNotInHand: "You are not in this hand",
	protocol.CodeNotYourTurn: "It is not your turn", protocol.CodeSideshowPending: "A sideshow is already in progress",
	"already_asked":      "You have already asked for a sideshow this turn",
	"too_few_players":    fmt.Sprintf("A sideshow needs at least %d players in the hand", sideshowMinPlayers),
	"you_are_blind":      "See your cards before asking for a sideshow",
	"no_neighbour":       "There is nobody on your right to ask",
	"neighbour_is_blind": "The player on your right has not seen their cards",
}

// sideshowBlocked is the server's sideshowBlockedReason, in its order.
func (t *table) sideshowBlocked(st *seat) string {
	h := t.hand
	switch {
	case h == nil:
		return protocol.CodeNoHand
	case st.status != protocol.SeatActive:
		return protocol.CodeNotInHand
	case h.turn != st.idx:
		return protocol.CodeNotYourTurn
	case h.sideshow != nil:
		return protocol.CodeSideshowPending
	case st.asked:
		return "already_asked"
	case len(t.active()) < sideshowMinPlayers:
		return "too_few_players"
	case st.isBlind:
		return "you_are_blind"
	}
	right := t.right(st.idx)
	if right < 0 {
		return "no_neighbour"
	}
	if t.seats[right].isBlind {
		return "neighbour_is_blind"
	}
	return ""
}

// askSideshow asks the player on the right to compare hands. The turn clock
// stops until they answer or the request lapses.
func (t *table) askSideshow(st *seat) (any, *refusal) {
	if blocked := t.sideshowBlocked(st); blocked != "" {
		return nil, refuse(blocked, sideshowMessages[blocked])
	}
	h, target := t.hand, t.seats[t.right(st.idx)]
	st.asked = true
	t.clearTurn()
	ss := &sideshow{from: st, to: target, expires: t.s.now().Add(sideshowTimeout)}
	ss.task = t.s.after(sideshowTimeout, func() {
		if t.hand == h && h.sideshow == ss {
			t.resolveSideshow(false, "timeout")
		}
	})
	h.sideshow = ss
	t.broadcast(protocol.EvGameSideshowRequested, sideshowRequestedWire{FromUserID: st.acct.id, FromName: st.acct.name,
		FromSeat: st.idx, ToUserID: target.acct.id, ToName: target.acct.name, ToSeat: target.idx,
		ExpiresAt: millis(ss.expires), TimeoutMs: sideshowTimeout.Milliseconds(), RoomID: t.id})
	t.emitState()
	return actionAck{OK: true, Action: protocol.ActionSideshow, ToUserID: target.acct.id}, nil
}

// resolveSideshow settles the pending request: on an acceptance the two
// compare privately and the weaker hand packs (the asker loses a tie); the
// asker then gets their clock back if the hand goes on.
func (t *table) resolveSideshow(accepted bool, reason string) *string {
	h := t.hand
	ss := h.sideshow
	if ss == nil {
		return nil
	}
	ss.task.cancel()
	h.sideshow = nil
	from, to := ss.from, ss.to
	var packed *string
	if accepted && from.status == protocol.SeatActive && to.status == protocol.SeatActive {
		a, _ := decision.Rank(from.cards)
		b, _ := decision.Rank(to.cards)
		loser := from
		if t.compare(a, b) > 0 {
			loser = to
		}
		packed = ptr(loser.acct.id)
		var reveal sideshowRevealWire
		reveal.RoomID, reveal.Reveal.Reason, reveal.Reveal.PackedUserID = t.id, "accepted", loser.acct.id
		reveal.Reveal.Hands = []sideshowHandWire{
			{UserID: from.acct.id, DisplayName: from.acct.name, Cards: from.cards, HandName: a.Name},
			{UserID: to.acct.id, DisplayName: to.acct.name, Cards: to.cards, HandName: b.Name},
		}
		t.s.send(from.acct.sess, protocol.EvGameSideshowReveal, reveal)
		t.s.send(to.acct.sess, protocol.EvGameSideshowReveal, reveal)
		t.pack(loser, "sideshow", h.turn == loser.idx)
	}
	t.broadcast(protocol.EvGameSideshowResolved, protocol.SideshowResolved{RoomID: t.id, FromUserID: from.acct.id,
		ToUserID: to.acct.id, Accepted: accepted, Reason: reason, PackedUserID: packed})
	if t.hand == h {
		if h.turn == from.idx && from.status == protocol.SeatActive && t.seats[from.idx] == from {
			t.setTurn(from.idx, false)
		}
		t.emitState()
	}
	return packed
}

// ---- the variation window ----

// beginVariation opens the window: the player left of the dealer chooses the
// hand's variation, and nobody is on turn until they have (or the clock has).
func (t *table) beginVariation(first int) {
	h, st, now := t.hand, t.seats[first], t.s.now()
	vw := &varWindow{chooser: st.acct, seatIdx: first, started: now, deadline: now.Add(variationWindow), open: true}
	vw.task = t.s.after(variationWindow, func() {
		if t.hand == h && vw.open {
			t.closeVariation(protocol.VariationMuflis, "TIMEOUT", true)
			t.emitState()
		}
	})
	h.vw, h.turn = vw, -1
	t.broadcast(protocol.EvGameVariationSelecting, variationSelectingWire{UserID: st.acct.id, DisplayName: st.acct.name,
		SeatIndex: first, StartedAt: millis(now), Deadline: ptr(millis(vw.deadline)),
		TimeoutMs: variationWindow.Milliseconds(), Options: variations, RoomID: t.id})
}

// closeVariation closes the window exactly once: by the chooser (PLAYER), the
// clock (TIMEOUT → MUFLIS) or the chooser leaving (LEFT → MUFLIS). The
// chooser, still in, then gets a fresh turn.
func (t *table) closeVariation(v, by string, giveTurn bool) {
	vw := t.hand.vw
	vw.open, vw.selected, vw.by = false, v, by
	vw.task.cancel()
	t.broadcast(protocol.EvGameVariationSelected, variationSelectedWire{UserID: vw.chooser.id, DisplayName: vw.chooser.name,
		SeatIndex: vw.seatIdx, Variation: v, SelectedBy: by, CardsPerPlayer: 3, RoomID: t.id})
	if st := t.seats[vw.seatIdx]; giveTurn && st != nil && st.acct == vw.chooser && st.status == protocol.SeatActive {
		t.setTurn(vw.seatIdx, true)
	}
}

func (t *table) variationName() string {
	if h := t.hand; h != nil && h.vw != nil && !h.vw.open {
		return h.vw.selected
	}
	return ""
}

// ---- seats in order ----

func (t *table) dist(from, to int) int {
	n := len(t.seats)
	return ((to-from)%n + n) % n
}

func (t *table) nextActive(from int) int {
	for step := 1; step <= len(t.seats); step++ {
		i := (from + step + len(t.seats)) % len(t.seats)
		if st := t.seats[i]; st != nil && st.status == protocol.SeatActive {
			return i
		}
	}
	return -1
}

// right is the active seat on this one's right: the one who acted before it.
func (t *table) right(from int) int {
	for step := 1; step < len(t.seats); step++ {
		i := ((from-step)%len(t.seats) + len(t.seats)) % len(t.seats)
		if st := t.seats[i]; st != nil && st.status == protocol.SeatActive {
			return i
		}
	}
	return -1
}

// nextAmong is the first seat of pool strictly clockwise after from.
func (t *table) nextAmong(from int, pool []*seat) int {
	for step := 1; step <= len(t.seats); step++ {
		i := ((from+step)%len(t.seats) + len(t.seats)) % len(t.seats)
		for _, st := range pool {
			if st.idx == i {
				return i
			}
		}
	}
	return pool[0].idx
}
