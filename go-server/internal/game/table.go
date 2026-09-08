package game

import (
	"context"
	"sync/atomic"
	"time"
)

// TableConfig is the slice of configuration one Table reads (Node passed the
// whole `config.game` spread plus per-category overrides; these are the keys
// table.js actually touches). RoomManager.CreateTable builds it; unit tests
// declare it in full.
//
// Zero means "no limit" for MaxBetRounds, PotLimitMultiplier, MaxRaiseSteps
// and MaxPot — exactly Node's blind-table rule (there is no `undefined →
// default` fallback in Go; every suite declared a full baseConfig anyway).
type TableConfig struct {
	Category   Category
	BootAmount int64
	MaxPlayers int // len(seats); 5 in production (requirement 3)
	MinPlayers int // funded seats needed to deal (requirement 4)

	TurnTimeout time.Duration // 25s; requirement 6d

	// MaxBetRounds: rounds before a forced showdown; 0 = never (blind tables).
	MaxBetRounds int
	// PotLimitMultiplier: a single bet may not exceed BootAmount × this; 0 = no ceiling.
	PotLimitMultiplier int64
	// MaxRaiseSteps: rungs on the +/− ladder; 0 = as many as the stack allows.
	MaxRaiseSteps int
	// MaxPot: pot ceiling → POT_LIMIT showdown; 0 = uncapped (requirement 22).
	MaxPot int64

	MaxBlindMoves  int // 4: blind bets before the cards auto-reveal
	MaxMissedTurns int // 3: timeouts in a row before a kick (requirement 31)

	SideshowTimeout    time.Duration // 6s (requirement 33)
	SideshowMinPlayers int           // 3

	NextHandDelay time.Duration // 4s countdown, also the settle-retry base delay

	ChatMaxHistory int // RoomChat caps
	ChatMaxLength  int
}

// TableOptions builds a Table.
type TableOptions struct {
	ID        string // util.UUID()
	Code      string // util.RoomCode(6)
	Config    TableConfig
	IsPrivate bool // requirement 22; set by RoomManager, read by lobby filters
	Ledger    Ledger
	Clock     Clock    // nil → RealClock{}
	Listener  Listener // nil → NopListener{}
}

// NewPlayer is what AddPlayer needs (roomManager.js join → table.addPlayer).
type NewPlayer struct {
	UserID      string
	DisplayName string
	AvatarURL   *string
	Chips       int64
	SocketID    string // "" when seated by consolidation without a live socket
}

// ActRequest is the client's move (socket game:action → table.act payload).
type ActRequest struct {
	// Amount is the rung the +/− stepper picked. nil → the default for the
	// kind (chaal → steps[0], raise → steps[1]). Ignored for see/pack/sideshow.
	Amount *int64
	// ActionID is the client's own id (validated ≤ 64 chars by the socket
	// layer) or "" → the Table generates util.UUID(); it becomes the ledger
	// row's unique action_id.
	ActionID string
}

// ActResult is table.act's return value, spread into the ack `{ok:true, …}`.
// The shape depends on the action (table.js _see/_bet/_pack/_show/
// _requestSideshow), hence the pointers and omitempty:
//
//	see      → {action:"see", auto:false}
//	chaal    → {action:"chaal", amount, autoSeen}
//	raise    → {action:"raise", amount, autoSeen}
//	pack     → {action:"pack", reason:"pack"}
//	show     → {action:"show", amount}
//	sideshow → {action:"sideshow", toUserId}
type ActResult struct {
	Action   string `json:"action"`
	Auto     *bool  `json:"auto,omitempty"`     // see: always present
	Amount   *int64 `json:"amount,omitempty"`   // chaal/raise/show
	AutoSeen *bool  `json:"autoSeen,omitempty"` // chaal/raise: always present
	Reason   string `json:"reason,omitempty"`   // pack
	ToUserID string `json:"toUserId,omitempty"` // sideshow
}

// SideshowOutcome is respondToSideshow's return: ack `{ok:true, accepted,
// packedUserId}`.
type SideshowOutcome struct {
	Accepted     bool    `json:"accepted"`
	PackedUserID *string `json:"packedUserId"` // null unless compared
}

// seat is the actor-owned state of one occupied seat (table.js addPlayer).
// SeatInfo is its exported copy. Only the actor goroutine touches it.
type seat struct {
	seatIndex             int
	userID                string
	displayName           string
	avatarURL             *string
	chips                 int64
	socketID              string
	connected             bool
	status                SeatState
	cards                 []Card
	isBlind               bool
	blindMoves            int
	missedTurns           int
	sideshowAskedThisTurn bool
	lastBet               int64
	lastAction            *Action
	contributed           int64
	joinedAt              time.Time
	disconnectedAt        *time.Time
	kickPending           bool
}

// contribution is hand.contributions[userId] — owned by the HAND, not the
// seat, so a player who leaves mid-hand is still settled and audited.
type contribution struct {
	userID      string
	displayName string
	seatIndex   int
	contributed int64
	status      SeatState
	sawCards    bool
	cards       []Card
	didChaal    bool  // set on the first chaal/raise/show — "played" (requirement 16)
	leftMidHand bool  // abandoned before the hand finished
	persisted   int64 // how much the account has already been debited
}

// pendingSideshow is hand.sideshow.
type pendingSideshow struct {
	fromUserID string
	fromSeat   int
	toUserID   string
	toSeat     int
	expiresAt  time.Time
	timer      Timer
}

// hand is the live hand (table.js _startHand `hand`).
type hand struct {
	id              string
	handNo          int
	startedAt       time.Time
	endedAt         time.Time
	pot             int64
	stake           int64 // ALWAYS in blind units: floor(amount/2) after a seen bet
	round           int
	packedUserIDs   map[string]struct{}
	turnSeat        int
	startSeat       int
	seatOrder       []int
	showRequestedBy *string
	sideshow        *pendingSideshow
	lastDeparture   *string // last player to leave mid-hand (requirement 15)
	turnDeadline    time.Time
	turnToken       string // names the current turn; a late timeout carrying another token is stale
	contributions   map[string]*contribution
	contribOrder    []string // insertion order of contributions, for snapshots/summaries
}

// Table is one Teen Patti table — the port of `class Table` in table.js.
//
// # Actor model (PORT_PLAN.md decision 4)
//
// One goroutine (loop) owns every field below the "actor-owned" line. All
// mutation and all reads of that state happen by posting a closure with
// run(), which blocks until the closure has finished — Node's `_run` promise
// queue made synchronous. Consequences:
//
//   - a Ledger round-trip inside a move can never interleave with a turn
//     timeout: the timeout's closure simply queues behind it;
//   - hand.turnToken additionally makes a late-firing timeout a no-op;
//   - Listener callbacks run ON the actor goroutine and must not post back;
//   - the exported "lock-free" getters read atomics the actor maintains and
//     are safe from any goroutine (RoomManager under its mutex, /health,
//     metric gauges);
//   - after Destroy, every post returns ErrTableDestroyed.
//
// Entry points wrap themselves in run(); internals never do — re-entering
// run from the actor goroutine deadlocks, exactly as Node's `_run` would wait
// on itself.
type Table struct {
	id        string
	code      string
	cfg       TableConfig
	isPrivate bool
	ledger    Ledger
	clock     Clock
	listener  Listener
	createdAt time.Time

	// ctx is cancelled by Destroy; posts select on it so callers of a
	// destroyed table get ErrTableDestroyed instead of blocking forever. It is
	// also the ctx handed to the Ledger.
	ctx    context.Context
	cancel context.CancelFunc
	posts  chan func()

	// Lock-free summaries maintained by the actor after every mutation.
	playerCount atomic.Int32
	hasHand     atomic.Bool
	state       atomic.Value // TableState
	version     atomic.Int64 // rises by one per committed ledger write
	destroyed   atomic.Bool

	// ---- actor-owned state: touch ONLY from closures run by loop ----
	seats      []*seat // len == cfg.MaxPlayers; nil = empty
	handNo     int
	hand       *hand
	dealerSeat int        // -1 before the first hand
	startsAt   *time.Time // countdown target while state == starting
	chat       *RoomChat
	turnTimer  Timer
	startTimer Timer
	view       *View // the single View handed to listeners
}

// NewTable constructs the table and starts its actor goroutine. State is
// waiting, dealerSeat -1, version 0, MaxPlayers empty seats (Node
// constructor). It does not emit anything.
func NewTable(opts TableOptions) *Table {
	panic("not ported: game.NewTable")
}

// run posts fn to the actor and waits for it to finish. Returns
// ErrTableDestroyed (without running fn) once the table is destroyed.
// NEVER call from inside a closure already running on the actor (deadlock).
func (t *Table) run(fn func()) error {
	panic("not ported: (*Table).run")
}

// loop is the actor goroutine: executes posted closures one at a time until
// destroy() has run, then drains/cancels so blocked posters wake with
// ErrTableDestroyed.
func (t *Table) loop() {
	panic("not ported: (*Table).loop")
}

// Settled posts a no-op and waits: every mutation queued before it has
// finished. For tests (Node: `await table.settled()` after an indirect
// removal by a kick handler).
func (t *Table) Settled() error { return t.run(func() {}) }

// ------------------------------------------------------------ lock-free reads

// ID is the roomId.
func (t *Table) ID() string { return t.id }

// Code is the 6-letter join code.
func (t *Table) Code() string { return t.code }

// Category is blind or seen.
func (t *Table) Category() Category { return t.cfg.Category }

// IsPrivate: reached by code only, boot fixed, pot capped (requirement 22).
func (t *Table) IsPrivate() bool { return t.isPrivate }

// Config returns the (immutable) table configuration.
func (t *Table) Config() TableConfig { return t.cfg }

// BootAmount is cfg.BootAmount (used by lobby matching and metrics labels).
func (t *Table) BootAmount() int64 { return t.cfg.BootAmount }

// MaxPot is cfg.MaxPot (0 = uncapped).
func (t *Table) MaxPot() int64 { return t.cfg.MaxPot }

// CreatedAt is when the table was opened (consolidation picks the oldest).
func (t *Table) CreatedAt() time.Time { return t.createdAt }

// PlayerCount is the number of occupied seats (atomic).
func (t *Table) PlayerCount() int { return int(t.playerCount.Load()) }

// IsFull is PlayerCount >= MaxPlayers.
func (t *Table) IsFull() bool { return t.PlayerCount() >= t.cfg.MaxPlayers }

// IsEmpty is PlayerCount == 0.
func (t *Table) IsEmpty() bool { return t.PlayerCount() == 0 }

// HasHand reports whether a hand is live (Node: `table.hand !== null`).
func (t *Table) HasHand() bool { return t.hasHand.Load() }

// State is the lifecycle state (atomic).
func (t *Table) State() TableState {
	if v, ok := t.state.Load().(TableState); ok {
		return v
	}
	return TableWaiting
}

// Version is the count of committed ledger writes (game_states.version).
func (t *Table) Version() int64 { return t.version.Load() }

// Destroyed reports whether Destroy has completed.
func (t *Table) Destroyed() bool { return t.destroyed.Load() }

// ------------------------------------------------------------- posting reads

// SerializeFor posts a read and returns the viewer's redacted TableView
// (see TableView for the rules). viewerID may be unseated → You == nil.
func (t *Table) SerializeFor(viewerID string) (*TableView, error) {
	panic("not ported: (*Table).SerializeFor")
}

// Summary posts a read and returns the lobby row.
func (t *Table) Summary() (TableSummary, error) {
	panic("not ported: (*Table).Summary")
}

// Seats posts a read and returns copies of the occupied seats in seat order
// (Node: occupiedSeats).
func (t *Table) Seats() ([]SeatInfo, error) {
	panic("not ported: (*Table).Seats")
}

// FindSeat posts a read; nil, nil when the user is not seated.
func (t *Table) FindSeat(userID string) (*SeatInfo, error) {
	panic("not ported: (*Table).FindSeat")
}

// ChatHistory posts a read and returns the room log, oldest first.
func (t *Table) ChatHistory() ([]ChatMessage, error) {
	panic("not ported: (*Table).ChatHistory")
}

// --------------------------------------------------------------- mutations

// AddPlayer seats a player (table.js addPlayer). Errors: already_seated,
// table_full. Sitting down moves no chips.
//
// Sequence: first nil seat; seat = {status waiting, isBlind true, blindMoves
// 0, missedTurns 0, cards [], connected true, joinedAt now}; emit
// seatUpdated; emit chat system line ChatJoinedFormat; maybeStart(); emit
// state. A player who joins during a live hand sits out until the next deal.
func (t *Table) AddPlayer(p NewPlayer) (*SeatInfo, error) {
	panic("not ported: (*Table).AddPlayer")
}

// RemovePlayer takes a player off the table (table.js _removePlayer).
// Returns nil, nil when not seated. `reason` is a leave or kick reason and is
// echoed as the pack's ActionEvent.Reason.
//
// Sequence: if a pending sideshow involves them → resolveSideshow(false,
// "left"); vacate the seat; emit seatUpdated; emit chat ChatLeftFormat;
// then if they were ACTIVE in a live hand: packedUserIDs += userId, status
// packed, syncContribution, contribution.leftMidHand = true,
// hand.lastDeparture = userId, emit action PACK{reason}; if
// resolveIfOnlyOneLeft() → done; else if they were on turn → clearTurnTimer,
// advanceTurn(seatIndex). Otherwise if state == starting and funded seats <
// MinPlayers → cancelStart(); else if state == waiting → maybeStart() (an
// unfunded departure may unblock the rest). Finally emit state.
func (t *Table) RemovePlayer(userID, reason string) (*SeatInfo, error) {
	panic("not ported: (*Table).RemovePlayer")
}

// SetConnected flags a seat connected/disconnected (setConnected). socketID
// "" leaves the stored id unchanged (Node: `if (socketId)`). Sets
// disconnectedAt = now when disconnecting, nil when connecting. Emits
// seatUpdated and state. nil, nil when not seated.
func (t *Table) SetConnected(userID string, connected bool, socketID string) (*SeatInfo, error) {
	panic("not ported: (*Table).SetConnected")
}

// SetChips applies an authoritative balance (setChips) and emits seatUpdated
// only. No-op when not seated. Unused by the Node server itself; kept for
// tooling parity.
func (t *Table) SetChips(userID string, chips int64) error {
	panic("not ported: (*Table).SetChips")
}

// PostChat appends a player line (postChat). Error not_in_room when the user
// is not seated (message MsgNotInRoom). Returns nil, nil when the text
// sanitised to nothing (no event). Emits chat on success.
func (t *Table) PostChat(userID, text string) (*ChatMessage, error) {
	panic("not ported: (*Table).PostChat")
}

// StartHand deals now instead of waiting for the countdown (startHand).
// Returns nil (no error) when nothing was dealt (destroyed, hand already
// live, too few funded players, or the boot transaction was refused — the
// refusal is reported via OnPersistError, not returned).
func (t *Table) StartHand() error {
	panic("not ported: (*Table).StartHand")
}

// Act applies a player action (table.js _act). Errors, in order: no_hand,
// not_seated, not_in_hand, not_your_turn (every action but SEE needs the
// turn), then per action:
//
//	see      → already_seen; free; does not end the turn nor reset the clock;
//	           re-emits OnTurn (with the seen ladder) only if it really is
//	           their turn and it was not an auto-see.
//	chaal    → bet(BetChaal): insufficient_chips (no rungs / chips < amount),
//	raise      invalid_bet (not a rung; raise < 2*steps[0]); then Ledger.Bet
//	           (refusal() maps its error); on success chips/contributed/pot
//	           updated, lastBet/lastAction set, didChaal = true, stake =
//	           amount (blind) or floor(amount/2) (seen), emit action; if still
//	           blind: blindMoves++ and at MaxBlindMoves see(auto:true) — the
//	           bet itself was charged at the blind rate; clearTurnTimer;
//	           advanceTurn; emit state.
//	pack     → pack(seat, PackReasonPack).
//	show     → show_unavailable (active seats != 2); insufficient_chips when
//	           showCost is nil or unaffordable — a show is NEVER free; then
//	           Ledger.Bet(reason show), showRequestedBy = userId, didChaal =
//	           true, emit action SHOW, clearTurnTimer, resolveShowdown(active,
//	           WinShow, userId).
//	sideshow → requestSideshow: sideshowBlockedReason → GameError(code =
//	           reason, message from the Msg table, MsgSideshowGeneric
//	           fallback); mark sideshowAskedThisTurn; STOP the turn clock;
//	           arm SideshowTimeout → resolveSideshow(false, "timeout"); emit
//	           sideshowRequested and state.
//	other    → unknown_action.
//
// missedTurns is reset to 0 only AFTER the move succeeded.
func (t *Table) Act(userID string, action Action, req ActRequest) (ActResult, error) {
	panic("not ported: (*Table).Act")
}

// RespondToSideshow is the asked player's answer (respondToSideshow).
// Errors: no_sideshow, not_your_sideshow. Only accept == true accepts.
//
// resolveSideshow(accepted, reason): stop the sideshow timer, clear
// hand.sideshow; if accepted and both still ACTIVE: evaluate both hands,
// loser = asked if Compare(asker, asked) > 0 else asker (a TIE GOES AGAINST
// THE ASKER); emit sideshowReveal (both cards, to the two of them only);
// pack(loser, PackReasonSideshow, advanceTurn = loser == asker) — when the
// asked player loses the turn never left the asker. Then emit
// sideshowResolved; if the hand is still live and the asker still holds the
// turn and is active → setTurn(fromSeat, freshTurn=false) (full clock again,
// but sideshowAskedThisTurn survives: one ask per turn); emit state.
func (t *Table) RespondToSideshow(userID string, accept bool) (SideshowOutcome, error) {
	panic("not ported: (*Table).RespondToSideshow")
}

// Destroy tears the table down (table.js _destroy) — the path a shutdown or
// an idle sweep takes. If a hand is live its pot must not vanish
// (requirement 15): endHand(winner = first active seat, else lastDeparture,
// reason all_left, no reveals). Then destroyed = true, timers stopped, chat
// cleared, actor stopped. Idempotent: a second call returns ErrTableDestroyed.
func (t *Table) Destroy() error {
	panic("not ported: (*Table).Destroy")
}

// ------------------------------------------------------------ internals
//
// The private method set below is the map a porter should follow; names are
// Node's minus the underscore. Bodies live on the actor goroutine and never
// call run(). Each doc comment is the specification.

// maybeStart (table.js _maybeStart): if destroyed, state != waiting, or a
// start timer is armed → return. sweepUnfunded(). If funded seats <
// MinPlayers → return. state = starting, startsAt = now + NextHandDelay,
// emit state, arm startTimer(NextHandDelay) → run(startHand).
func (t *Table) maybeStart() { panic("not ported") }

// cancelStart (_cancelStart): stop startTimer, startsAt = nil, state =
// waiting, emit state.
func (t *Table) cancelStart() { panic("not ported") }

// startHand (_startHand) deals database-first. If destroyed or a hand is live
// → nil. sweepUnfunded(); participants = funded seats; if < MinPlayers →
// state waiting, startsAt nil, emit state, return. Build the hand BESIDE the
// table (id util.UUID(), handNo+1, pot = boot × n, stake = boot, round 0,
// dealerSeat = nextOccupiedSeat(dealerSeat, participants), Deal(n,3),
// contributions per participant {contributed boot, status active, cards,
// persisted 0}). Ledger.CollectBoot with Version+1 and
// snapshot(hand-to-be); on error → startRefused(err). On success: version++,
// every contribution.persisted = result.Persisted, adopt handNo/dealerSeat,
// reset EVERY occupied seat (cards [], isBlind true, blindMoves 0, lastBet 0,
// lastAction nil, contributed 0, status active if participant else waiting),
// give participants their cards, contributed = boot, chips = Balances[id] if
// present else chips - boot; state betting; startsAt nil; emit handStarted;
// startSeat = nextActiveSeat(dealerSeat); setTurn(startSeat); emit state.
func (t *Table) startHand() { panic("not ported") }

// startRefused (_startRefused): emit persistError{reason "boot"}; state
// waiting; startsAt nil. If err is insufficient_chips with UserID and that
// seat exists: seat.chips = min(chips, boot-1) and kick(seat,
// insufficient_chips, KickMessageInsufficientChips). Else if not destroyed:
// arm startTimer(NextHandDelay) → run(maybeStart). Emit state.
func (t *Table) startRefused(err error) { panic("not ported") }

// setTurn (_setTurn): if seatIndex < 0 return. hand.turnSeat = seatIndex; if
// freshTurn → seat.sideshowAskedThisTurn = false; deadline = now +
// TurnTimeout; turnToken = util.UUID(); emit turn{deadline, TurnTimeout,
// turnOptions}; clearTurnTimer; arm turnTimer(TurnTimeout) →
// run(onTurnTimeout(seatIndex, token)).
func (t *Table) setTurn(seatIndex int, freshTurn bool) { panic("not ported") }

// onTurnTimeout (_onTurnTimeout; requirement 6d/31): ignore if no hand, seat
// empty, turnSeat != seatIndex, token != hand.turnToken, or seat not active.
// missedTurns++; pack(seat, PackReasonTimeout); if missedTurns >=
// MaxMissedTurns → kick(seat, idle, sprintf(KickMessageIdleFormat)).
func (t *Table) onTurnTimeout(seatIndex int, token string) { panic("not ported") }

// advanceTurn (_advanceTurn): if no hand return; next = nextActiveSeat(from);
// if none return. If potCapReached() (MaxPot > 0 && pot + stake > MaxPot) →
// clearTurnTimer, resolveShowdown(active, WinPotLimit, nil), return. Round
// counting by DISTANCE: toNext = distance(from, next), toStart =
// distance(from, startSeat); if toStart > 0 && toStart <= toNext → round++,
// and if MaxBetRounds > 0 && round >= MaxBetRounds → forcedShowdown, return.
// setTurn(next, fresh); emit state.
func (t *Table) advanceTurn(fromSeat int) { panic("not ported") }

// pack (_pack): status packed, lastAction PACK, packedUserIDs += id,
// syncContribution(packed); emit action PACK{reason}; clearTurnTimer; if
// resolveIfOnlyOneLeft() return; if advanceTurn → advanceTurn(seatIndex);
// emit state.
func (t *Table) pack(s *seat, reason string, advanceTurn bool) { panic("not ported") }

// resolveIfOnlyOneLeft (_resolveIfOnlyOneLeft; requirements 6e/6f/15): with
// > 1 active seat → false. Exactly one → endHand(winner, last_standing, no
// reveals). None → endHand(hand.lastDeparture, all_left, no reveals) — the
// pot goes to the last leaver, who is no longer seated, which is why the
// winner is a userId and not a seat. Returns true.
func (t *Table) resolveIfOnlyOneLeft() bool { panic("not ported") }

// resolveShowdown (_resolveShowdown): state showdown; score contenders;
// preference for exact ties = contenders sorted by distance(dealerSeat,
// seatIndex) ascending, minus showRequestedBy, who is appended LAST (the
// show-payer loses a tie); pick best (first max, ties broken by preference
// index); reveals for every contender {won}; emit showdown; losers → status
// lost + syncContribution; endHand(best, reason, reveals). The pot is never
// split.
func (t *Table) resolveShowdown(contenders []*seat, reason WinReason, showRequestedBy *string) {
	panic("not ported")
}

// endHand (_endHand) settles. clearTurnTimer; stop sideshow timer; endedAt =
// now. Winner seat → status won (or mark the contribution if they left).
// contributors = contributions with contributed > 0. entries: net = pot -
// contributed (winner), -contributed (loser), 0 (no winner); delta = net +
// persisted. summary = HandSummaryEntry per contributor with cards only for
// revealed users. record = HandRecord. version = Version+1; state =
// snapshot(hand nil, state waiting). Ledger.Settle → on success version =
// that, settledInDb; on error emit persistError{reason "settle"}. Adopt every
// returned balance onto its seat. If the winner is seated and balances LACKS
// their key → chips += pot (key presence, not truthiness). If !settledInDb →
// retrySettle(args, 1). hand = nil; state waiting; emit handEnded{nextHandAt
// = now + NextHandDelay}; emit state; maybeStart().
//
// This is the ONE place memory changes before the write commits — the hand
// IS over whatever the database says next.
func (t *Table) endHand(winnerID *string, reason WinReason, reveals []Reveal) { panic("not ported") }

// retrySettle (_retrySettle): if destroyed return. attempt > 10 → emit error
// (OnError) with "settlement of hand <id> failed after 10 attempts". delay =
// min(30s, NextHandDelay × attempt). AfterFunc(delay) → run(): if destroyed
// return; Settle with Version+1; on success version = that, adopt balances
// ONLY onto seats that are not active (a live stake is in play), emit state;
// on error emit persistError{settle_retry, attempt} and retrySettle(attempt+1).
// Unlike Node, the retry body runs ON the actor (Node ran it outside the
// queue and mutated seats concurrently — a bug the port does not copy).
func (t *Table) retrySettle(req SettleRequest, attempt int) { panic("not ported") }

// snapshot (_snapshot) builds the DB-side Snapshot from the actor state, or
// from an about-to-be hand (startHand passes the new hand, dealt cards and
// participants so seats read as they WILL be: chips - boot, active, blind,
// contributed boot). snapshotAfterBet (_snapshotAfterBet) is snapshot() with
// pot/chips/contributed/persisted advanced by the bet.
func (t *Table) snapshot() *Snapshot { panic("not ported") }

// serializeFor (serializeFor) builds the TableView for one viewer — see
// TableView's doc for every redaction rule.
func (t *Table) serializeFor(viewerID string) *TableView { panic("not ported") }

// betOptions (betOptions) computes the ladder — see BetOptions' doc.
func (t *Table) betOptions(s *seat) BetOptions { panic("not ported") }

// turnOptions (turnOptions): from betOptions; Show = showCost (== Chaal) only
// when exactly two active seats and chips >= cost; CanSideshow /
// SideshowWith from sideshowBlockedReason and rightActiveSeat.
func (t *Table) turnOptions(s *seat) TurnOptions { panic("not ported") }

// sideshowBlockedReason (sideshowBlockedReason; requirement 33) returns "" when
// allowed, else the first failing check IN THIS ORDER: no_hand, not_in_hand,
// not_your_turn, sideshow_pending, already_asked, too_few_players (active <
// SideshowMinPlayers), you_are_blind, no_neighbour, neighbour_is_blind.
func (t *Table) sideshowBlockedReason(s *seat) string { panic("not ported") }

// nextActiveSeat (_nextActiveSeat): next ACTIVE seat clockwise = ascending
// index, wrapping; -1 if none. rightActiveSeat (_rightActiveSeat) walks
// DOWNWARD — the player on your right acted just before you (who a sideshow
// is asked of). nextOccupiedSeat (_nextOccupiedSeat) is nextActiveSeat over
// a given pool, falling back to pool[0]. distance(from, to) = (to - from +
// n) % n.
func (t *Table) nextActiveSeat(fromSeat int) int { panic("not ported") }

// sweepUnfunded (_sweepUnfunded; requirements 31/32): ONLY between hands (`if
// hand != nil return`). For each seat with chips < boot and !kickPending:
// kickPending = true, kick(insufficient_chips, KickMessageInsufficientChips).
func (t *Table) sweepUnfunded() { panic("not ported") }

// kick (_kick) only EMITS OnKick{userId, displayName, reason, message}; the
// RoomManager does the removing.
func (t *Table) kick(s *seat, reason, message string) { panic("not ported") }

// refusal (_refusal) maps a Ledger error onto the GameError the player is
// told: insufficient_chips → MsgInsufficientForBet; duplicate_action →
// MsgDuplicateAction; anything else → persist_failed / MsgPersistFailed.
func (t *Table) refusal(err error) *GameError { panic("not ported") }

// View is the read-only accessor handed to Listener callbacks. It wraps the
// table and calls the actor-side internals DIRECTLY (no posting), which is
// only safe because the callback is already on the actor goroutine. Using a
// View after the callback returns is a data race; never store one.
type View struct {
	t *Table
}

// ID is the roomId.
func (v *View) ID() string { return v.t.id }

// Code is the table code.
func (v *View) Code() string { return v.t.code }

// Category is blind or seen.
func (v *View) Category() Category { return v.t.cfg.Category }

// IsPrivate mirrors Table.IsPrivate.
func (v *View) IsPrivate() bool { return v.t.isPrivate }

// Config mirrors Table.Config.
func (v *View) Config() TableConfig { return v.t.cfg }

// State is the current lifecycle state.
func (v *View) State() TableState { return v.t.State() }

// HasHand reports a live hand.
func (v *View) HasHand() bool { return v.t.hand != nil }

// Pot is the live pot or 0.
func (v *View) Pot() int64 {
	if v.t.hand == nil {
		return 0
	}
	return v.t.hand.pot
}

// SerializeFor is the per-viewer snapshot, computed inline.
func (v *View) SerializeFor(viewerID string) *TableView { return v.t.serializeFor(viewerID) }

// Seats returns copies of the occupied seats.
func (v *View) Seats() []SeatInfo { panic("not ported: (*View).Seats") }

// FindSeat returns a copy of the user's seat or nil.
func (v *View) FindSeat(userID string) *SeatInfo { panic("not ported: (*View).FindSeat") }

// ChatHistory returns the room log.
func (v *View) ChatHistory() []ChatMessage { return v.t.chat.History() }

// Summary is the lobby row.
func (v *View) Summary() TableSummary { panic("not ported: (*View).Summary") }
