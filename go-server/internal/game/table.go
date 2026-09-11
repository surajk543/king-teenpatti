package game

import (
	"context"
	"errors"
	"fmt"
	"math"
	"runtime/debug"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/live"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// TableConfig is the slice of configuration one Table reads (Node passed the
// whole `config.game` spread plus per-category overrides; these are the keys
// table.js actually touches). RoomManager.CreateTable builds it; unit tests
// declare it in full.
//
// Zero means "no limit" for MaxBetRounds, PotLimitMultiplier, MaxRaiseSteps
// and MaxPot — exactly Node's blind-table rule (there is no `undefined →
// default` fallback in Go; every suite declared a full baseConfig anyway).
//
// Zero means "disabled / never triggers" for MaxBlindMoves, MaxMissedTurns,
// SideshowMinPlayers and SideshowTimeout (DECISIONS.md §2): Node left those
// keys undefined in some unit suites, and `x >= undefined` is always false.
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

	MaxBlindMoves  int // 4: blind bets before the cards auto-reveal; 0 = never
	MaxMissedTurns int // 3: timeouts in a row before a kick (requirement 31); 0 = never

	SideshowTimeout    time.Duration // 6s (requirement 33); 0 = a request never expires
	SideshowMinPlayers int           // 3; 0 = no minimum

	NextHandDelay time.Duration // 4s countdown, also the settle-retry base delay

	// UnfundedGrace: how long a seat below the boot is held between hands
	// before the insufficient_chips kick; 0 = at once (requirements 31/32).
	UnfundedGrace time.Duration

	ChatMaxHistory int // RoomChat caps; 0 → chat.js defaults (100 / 140)
	ChatMaxLength  int
}

// Chat caps Node's RoomChat fell back to when the table config left them
// undefined (chat.js:16 → config.chat.maxHistory / maxLength).
const (
	defaultChatMaxHistory = 100
	defaultChatMaxLength  = 140
)

// settleMaxAttempts is how often _retrySettle tries before giving up, loudly.
const settleMaxAttempts = 10

// settleRetryMaxDelay caps the settle back-off (Node: Math.min(30_000, …)).
const settleRetryMaxDelay = 30 * time.Second

// reservedActionIDSeparator is the character every server-generated
// chip_ledger.action_id (BootActionID, SettleActionID, the users store's
// milestone id) is built around. A client-supplied actionId containing it is
// discarded in favour of a fresh uuid — see chargeToPot.
const reservedActionIDSeparator = ':'

// TableOptions builds a Table.
type TableOptions struct {
	ID        string // util.UUID()
	Code      string // util.RoomCode(6)
	Config    TableConfig
	IsPrivate bool // requirement 22; set by RoomManager, read by lobby filters
	Ledger    Ledger
	Clock     Clock    // nil → RealClock{}
	Listener  Listener // nil → NopListener{}

	// Live is the live-state store the actor saves its Snapshot to after
	// every mutation and mirrors its chat into (LIVE_STATE_PLAN.md). nil →
	// nothing is saved (unit tests; a table that need not survive a restart).
	Live live.Store
	// LiveTTL bounds how long a table that stops updating survives in the
	// store (LIVE_STATE_TTL_MS). 0 → DefaultLiveTTL.
	LiveTTL time.Duration
	// LiveErrors, if set, is called for every failed live-store call with
	// the operation name (LiveOp*) — the game_live_store_errors_total{op}
	// feed. Called on the actor goroutine; must not block or post back.
	LiveErrors func(op string, err error)
	// ObserveHandStart, if set, is called with how long startHand took —
	// game_hand_start_duration_seconds. Called on the actor; must not block.
	ObserveHandStart func(d time.Duration)
}

// PersistReasonFlush is PersistErrorEvent.Reason when a departing player's
// accumulated bets could not be banked (Table.flushBets). Nothing was
// refused: the player still leaves, their stake is still in the pot, and the
// settlement banks the bets instead — only their wallet is briefly behind.
const PersistReasonFlush = "flush_bets"

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
	// unfundedUntil ends the grace a seat below the boot is given between
	// hands before the insufficient_chips kick; nil while none is running.
	unfundedUntil *time.Time
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
	didChaal    bool // set on the first chaal/raise/show — "played" (requirement 16)
	leftMidHand bool // abandoned before the hand finished

	// chips is this player's stack as the LIVE state has it — the seat's
	// chips, kept in step here so a player who has left the table still has
	// a figure to settle against.
	chips int64
	// chipsWritten is the stack as PostgreSQL last had it. Every checkpoint
	// writes `chips - chipsWritten` and then sets this to `chips`, so the
	// money moves exactly once however many times a player is written: a
	// packer's hand-end row computes a delta of zero and records only the
	// outcome. It starts at the seat's chips when the hand was dealt, BEFORE
	// the boot came out, because nothing is written at the deal.
	//
	// A delta, never an absolute: a seated player can claim the four-hour
	// bonus or a milestone reward, which credits the wallet and not the seat,
	// and `SET chips = <live figure>` would erase it.
	chipsWritten int64
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
	// actionIDs are the client action ids this hand has already accepted for
	// a bet. A bet writes nothing to PostgreSQL, so the chip_ledger UNIQUE
	// index can no longer refuse a replayed move: this set does it in memory
	// (duplicate_action). It is in the snapshot, so it survives a restart.
	actionIDs map[string]struct{}
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

	// live is the live-state store (nil → no-op), liveTTL the snapshot
	// expiry, liveErrors the error hook — see TableOptions.
	live        live.Store
	liveTTL     time.Duration
	liveErrors  func(op string, err error)
	onHandStart func(d time.Duration)

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
	// liveSeq is the sequence number of the last snapshot saved to the live
	// store (restored from the snapshot; 0 for a table never saved).
	liveSeq atomic.Int64
	// fenced is set when the live store refused a save with live.ErrStale:
	// another process owns this table. Every post but Destroy is refused
	// (ErrTableDestroyed), and destroy neither settles nor deletes the
	// store's copy — both belong to the owner now.
	fenced atomic.Bool

	// ---- actor-owned state: touch ONLY from closures run by loop ----
	// liveDirty marks that observable state changed inside the running
	// closure; run() saves one snapshot to the LIVE store when the closure
	// ends. The live store is the ONLY place game state is kept — nothing
	// about a table is ever written to PostgreSQL (LIVE_STATE_PLAN.md).
	liveDirty  bool
	seats      []*seat // len == cfg.MaxPlayers; nil = empty
	handNo     int
	hand       *hand
	dealerSeat int        // -1 before the first hand
	startsAt   *time.Time // countdown target while state == starting
	chat       *RoomChat
	turnTimer  Timer
	startTimer Timer
	// startTimerGen names the armed start timer, so a callback whose timer
	// was stopped a moment too late (time.AfterFunc's Stop can lose that
	// race) is recognised as stale — the same guard hand.turnToken gives
	// the turn clock.
	startTimerGen uint64
	// unfundedTimer fires at the earliest grace deadline a short-stacked seat
	// was given (armUnfundedTimer); unfundedTimerGen guards a late callback the
	// way startTimerGen does.
	unfundedTimer    Timer
	unfundedTimerGen uint64
	// retryTimers are the armed settle back-offs (timer + the write it owes),
	// so Destroy can stop them and hand the writes to settleDetached rather
	// than lose them (Node let them fire into `_destroyed` checks and the
	// pot was never banked).
	retryTimers map[uint64]*settleRetry
	retryGen    uint64
	// detachedMu guards the bookkeeping of settlement chains still being
	// retried after Destroy (settleDetached): detachedOpen is how many are
	// running, detachedDone is broadcast when one finishes, landed/abandoned
	// record the outcomes for WaitSettlements.
	detachedMu   sync.Mutex
	detachedDone *sync.Cond
	detachedOpen int
	landed       []string // hand ids settled after Destroy
	abandoned    []string // hand ids given up after settleMaxAttempts
	view         *View    // the single View handed to listeners
}

// settleRetry is one armed settlement back-off: the timer and the exact
// write it will attempt when it fires. claimed (under detachedMu) records
// that the retry has been counted as a detached chain — by destroy() or by
// the timer's own callback, whichever reaches it first when the table goes
// down with the write still owed — so it is counted exactly once.
type settleRetry struct {
	timer   Timer
	req     SettleRequest
	attempt int
	claimed bool
}

// claimDetached counts a retry as an open detached chain, once.
func (t *Table) claimDetached(entry *settleRetry) {
	t.detachedMu.Lock()
	if !entry.claimed {
		entry.claimed = true
		t.detachedOpen++
	}
	t.detachedMu.Unlock()
}

// NewTable constructs the table and starts its actor goroutine. State is
// waiting, dealerSeat -1, version 0, MaxPlayers empty seats (Node
// constructor). It does not emit anything and saves nothing to the live
// store until the first mutation.
func NewTable(opts TableOptions) *Table {
	t := newTableCore(opts)
	go t.loop()
	return t
}

// newTableCore is NewTable without starting the actor: the shared
// constructor of NewTable and RestoreTable (which fills the actor-owned
// fields in before the loop can touch them).
func newTableCore(opts TableOptions) *Table {
	clock := opts.Clock
	if clock == nil {
		clock = RealClock{}
	}
	listener := opts.Listener
	if listener == nil {
		listener = NopListener{}
	}
	ledger := opts.Ledger
	if ledger == nil {
		// Node: `ledger ?? memoryLedger({settle, persistChips})` — a table
		// built without a database keeps its chips in the seats.
		ledger = NewMemoryLedger(MemoryLedgerHooks{})
	}
	cfg := opts.Config
	if cfg.MaxPlayers < 0 {
		cfg.MaxPlayers = 0
	}
	// Node: `config.category === 'blind' ? BLIND : SEEN` — an absent or
	// unknown category never hides chips by accident (categories.test.js).
	if cfg.Category != CategoryBlind {
		cfg.Category = CategorySeen
	}
	chatHistory, chatLength := cfg.ChatMaxHistory, cfg.ChatMaxLength
	if chatHistory <= 0 {
		chatHistory = defaultChatMaxHistory
	}
	if chatLength <= 0 {
		chatLength = defaultChatMaxLength
	}
	liveTTL := opts.LiveTTL
	if liveTTL <= 0 {
		liveTTL = DefaultLiveTTL
	}

	t := &Table{
		id:          opts.ID,
		code:        opts.Code,
		cfg:         cfg,
		isPrivate:   opts.IsPrivate,
		ledger:      ledger,
		clock:       clock,
		listener:    listener,
		createdAt:   clock.Now(),
		live:        opts.Live,
		liveTTL:     liveTTL,
		liveErrors:  opts.LiveErrors,
		onHandStart: opts.ObserveHandStart,
		posts:       make(chan func()),
		seats:       make([]*seat, cfg.MaxPlayers),
		dealerSeat:  -1,
		chat:        NewRoomChat(chatHistory, chatLength, clock),
		retryTimers: map[uint64]*settleRetry{},
	}
	t.ctx, t.cancel = context.WithCancel(context.Background())
	t.detachedDone = sync.NewCond(&t.detachedMu)
	t.state.Store(TableWaiting)
	t.view = &View{t: t}
	return t
}

// run posts fn to the actor and waits for it to finish. Returns
// ErrTableDestroyed (without running fn) once the table is destroyed — or
// fenced (Fenced): a table another process owns accepts nothing but Destroy.
// NEVER call from inside a closure already running on the actor (deadlock).
//
// A panic inside fn is recovered on the actor and handed back to the poster
// as an internal_error GameError, so a programming error in one move rejects
// that move (as Node's promise rejection did) instead of taking the whole
// process down with it. The actor keeps running.
//
// When fn is done the actor saves one Snapshot to the live store if the
// closure changed observable state (flushLive) — after the Listener has seen
// every event, so the store is never ahead of the clients, and once per
// posted closure however many state events it emitted.
func (t *Table) run(fn func()) error { return t.post(fn, false) }

// post is run; force lets Destroy through the fence.
func (t *Table) post(fn func(), force bool) error {
	if t.destroyed.Load() || (!force && t.fenced.Load()) {
		return ErrTableDestroyed
	}
	done := make(chan struct{})
	var failure error
	job := func() {
		defer close(done)
		defer t.flushLive()
		defer func() {
			if r := recover(); r != nil {
				failure = &GameError{
					Code:    CodeInternalError,
					Message: fmt.Sprintf("table %s: %v", t.id, r),
					Cause:   &actorPanic{value: r, stack: debug.Stack()},
				}
			}
		}()
		fn()
	}
	// Blocked senders on an unbuffered channel are served first-in first-out,
	// which is exactly Node's `_queue` ordering.
	select {
	case t.posts <- job:
	case <-t.ctx.Done():
		return ErrTableDestroyed
	}
	<-done
	return failure
}

// actorPanic is the Cause of the internal_error a recovered panic becomes.
type actorPanic struct {
	value any
	stack []byte
}

func (p *actorPanic) Error() string { return fmt.Sprintf("panic: %v\n%s", p.value, p.stack) }

// loop is the actor goroutine: executes posted closures one at a time until
// destroy() has run, then drains/cancels so blocked posters wake with
// ErrTableDestroyed.
func (t *Table) loop() {
	for job := range t.posts {
		job()
		if t.destroyed.Load() {
			// destroy() cancelled ctx before returning; every poster still
			// waiting in run()'s select wakes up with ErrTableDestroyed.
			return
		}
	}
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

// Version is the count of committed ledger writes (boot, bet/show, settle,
// settle retry). It used to be game_states.version; the live store's
// per-table sequence is LiveSeq.
func (t *Table) Version() int64 { return t.version.Load() }

// LiveSeq is the sequence number of the last Snapshot the actor offered to
// the live store (0 before the first; restored tables continue from the
// stored value). Every attempt takes a number, landed or not, so the durable
// writer's version guard stays monotonic; gaps are harmless.
func (t *Table) LiveSeq() int64 { return t.liveSeq.Load() }

// SaveLive posts a save of the current snapshot to the live store (and the
// durable sink) whether or not anything changed — RoomManager.ReconcileLive
// uses it to refill a store that came back empty. ErrTableDestroyed once the
// table is gone.
func (t *Table) SaveLive() error { return t.run(func() { t.liveDirty = true }) }

// Fenced reports that the live store refused a save with live.ErrStale —
// another process owns this table — so every post but Destroy is refused
// with ErrTableDestroyed. RoomManager destroys a fenced table.
func (t *Table) Fenced() bool { return t.fenced.Load() }

// Destroyed reports whether Destroy has completed.
func (t *Table) Destroyed() bool { return t.destroyed.Load() }

// ------------------------------------------------------------- posting reads

// SerializeFor posts a read and returns the viewer's redacted TableView
// (see TableView for the rules). viewerID may be unseated → You == nil.
func (t *Table) SerializeFor(viewerID string) (*TableView, error) {
	var view *TableView
	err := t.run(func() { view = t.serializeFor(viewerID) })
	return view, err
}

// Summary posts a read and returns the lobby row.
func (t *Table) Summary() (TableSummary, error) {
	var summary TableSummary
	err := t.run(func() { summary = t.summary() })
	return summary, err
}

// Seats posts a read and returns copies of the occupied seats in seat order
// (Node: occupiedSeats).
func (t *Table) Seats() ([]SeatInfo, error) {
	var seats []SeatInfo
	err := t.run(func() { seats = t.seatInfos() })
	return seats, err
}

// FindSeat posts a read; nil, nil when the user is not seated.
func (t *Table) FindSeat(userID string) (*SeatInfo, error) {
	var info *SeatInfo
	err := t.run(func() {
		if s := t.findSeat(userID); s != nil {
			info = s.info()
		}
	})
	return info, err
}

// ChatHistory posts a read and returns the room log, oldest first.
func (t *Table) ChatHistory() ([]ChatMessage, error) {
	var history []ChatMessage
	err := t.run(func() { history = t.chat.History() })
	return history, err
}

// Snapshot posts a read and returns the full server-side Snapshot (cards
// included) — what the live store holds after the last mutation. Never send
// it to a client.
func (t *Table) Snapshot() (*Snapshot, error) {
	var snap *Snapshot
	err := t.run(func() { snap = t.snapshot() })
	return snap, err
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
	var info *SeatInfo
	var failure error
	err := t.run(func() { info, failure = t.addPlayer(p) })
	if err != nil {
		return nil, err
	}
	return info, failure
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
	var info *SeatInfo
	err := t.run(func() { info = t.removePlayer(userID, reason) })
	return info, err
}

// SetConnected flags a seat connected/disconnected (setConnected). socketID
// "" leaves the stored id unchanged (Node: `if (socketId)`). Sets
// disconnectedAt = now when disconnecting, nil when connecting. Emits
// seatUpdated and state. nil, nil when not seated.
// CreditChips adds bought chips to a seated player's live stack.
//
// Called after a Google Play purchase has been verified and banked in
// PostgreSQL, for a player who is sitting at a table. Without it the chips
// would be in the wallet and invisible where they were bought — a player tops
// up mid-hand precisely because they are short at THIS table, and telling them
// to leave and come back to see it would be absurd.
//
// The delicate part is chipsWritten, and getting it wrong doubles the money.
//
// Rewards deliberately move the wallet and NOT the seat, which is why every
// checkpoint writes `chips - chipsWritten` and never an absolute. A purchase
// moves BOTH, so both sides of that subtraction have to move with it: the
// stack gains the chips, and chipsWritten gains them too, because PostgreSQL
// already has them. Advance only the stack and the next checkpoint writes the
// purchase a second time; advance neither and the seat never shows it.
//
// Between hands there is no contribution record and nothing to reconcile — the
// next deal takes chipsWritten from the seat, which by then includes the
// purchase, and PostgreSQL agrees.
//
// A seat the sweep found short and is holding for a purchase (UnfundedGrace)
// is released from its grace as soon as the chips cover the boot, and a
// waiting table is given the chance to start with it.
//
// Returns false when the player is not at this table, so the caller can tell
// "credited the seat" from "there was no seat", and log accordingly.
func (t *Table) CreditChips(userID string, amount int64) bool {
	if amount <= 0 {
		return false
	}
	var credited bool
	_ = t.run(func() {
		s := t.findSeat(userID)
		if s == nil {
			return
		}
		s.chips += amount
		if t.hand != nil {
			if entry := t.hand.contributions[userID]; entry != nil {
				entry.chips += amount
				// PostgreSQL already holds these chips. Moving chipsWritten by
				// the same amount keeps `chips - chipsWritten` exactly what it
				// was, so the next checkpoint writes the hand's betting and
				// not the purchase.
				entry.chipsWritten += amount
			}
		}
		credited = true
		// Bought back over the boot: the grace the sweep gave this seat is
		// spent, and a table that was waiting on funded players may now start.
		if s.unfundedUntil != nil && s.chips >= t.cfg.BootAmount {
			s.unfundedUntil = nil
			t.armUnfundedTimer()
		}
		t.listener.OnSeatUpdated(t.view, s.seatIndex)
		t.emitState()
		if t.hand == nil {
			t.maybeStart()
		}
	})
	return credited
}

func (t *Table) SetConnected(userID string, connected bool, socketID string) (*SeatInfo, error) {
	var info *SeatInfo
	err := t.run(func() {
		s := t.findSeat(userID)
		if s == nil {
			return
		}
		s.connected = connected
		if connected {
			s.disconnectedAt = nil
		} else {
			now := t.clock.Now()
			s.disconnectedAt = &now
		}
		if socketID != "" {
			s.socketID = socketID
		}
		t.listener.OnSeatUpdated(t.view, s.seatIndex)
		t.emitState()
		info = s.info()
	})
	return info, err
}

// SetChips applies an authoritative balance (setChips) and emits seatUpdated
// only. No-op when not seated. Unused by the Node server itself; kept for
// tooling parity.
func (t *Table) SetChips(userID string, chips int64) error {
	return t.run(func() {
		s := t.findSeat(userID)
		if s == nil {
			return
		}
		s.chips = chips
		t.liveDirty = true
		t.listener.OnSeatUpdated(t.view, s.seatIndex)
	})
}

// PostChat appends a player line (postChat). Error not_in_room when the user
// is not seated (message MsgNotInRoom). Returns nil, nil when the text
// sanitised to nothing (no event). Emits chat on success and mirrors the
// line to the live store (Live.AppendChat, capped at ChatMaxHistory).
func (t *Table) PostChat(userID, text string) (*ChatMessage, error) {
	var msg *ChatMessage
	var failure error
	err := t.run(func() {
		s := t.findSeat(userID)
		if s == nil {
			failure = NewGameError(CodeNotInRoom, MsgNotInRoom)
			return
		}
		msg = t.chat.Add(userID, s.displayName, text)
		if msg == nil {
			return
		}
		t.listener.OnChat(t.view, msg)
		t.liveAppendChat(msg)
	})
	if err != nil {
		return nil, err
	}
	return msg, failure
}

// StartHand deals now instead of waiting for the countdown (startHand).
// Returns nil (no error) when nothing was dealt (destroyed, hand already
// live, too few funded players, or the boot transaction was refused — the
// refusal is reported via OnPersistError, not returned).
func (t *Table) StartHand() error {
	return t.run(func() { t.startHand() })
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
	var result ActResult
	var failure error
	err := t.run(func() { result, failure = t.act(userID, action, req) })
	if err != nil {
		return ActResult{}, err
	}
	return result, failure
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
	var outcome SideshowOutcome
	var failure error
	err := t.run(func() {
		if t.hand == nil || t.hand.sideshow == nil {
			failure = NewGameError(CodeNoSideshow, MsgNoSideshow)
			return
		}
		if t.hand.sideshow.toUserID != userID {
			failure = NewGameError(CodeNotYourSideshow, MsgNotYourSideshow)
			return
		}
		reason := SideshowDeclined
		if accept {
			reason = SideshowAccepted
		}
		outcome, _ = t.resolveSideshow(accept, reason)
	})
	if err != nil {
		return SideshowOutcome{}, err
	}
	return outcome, failure
}

// Destroy tears the table down (table.js _destroy) — the path a shutdown or
// an idle sweep takes. If a hand is live its pot must not vanish
// (requirement 15): endHand(winner = first active seat, else lastDeparture,
// reason all_left, no reveals). Then destroyed = true, timers stopped, chat
// cleared, the live store's copy deleted (DeleteTable + DeleteChat), actor
// stopped. Idempotent: a second call returns ErrTableDestroyed.
//
// A FENCED table (another process owns it) is torn down without settling
// the hand and without touching the store: both belong to the owner. Its
// own detached settle retries — hands that ended here — continue.
func (t *Table) Destroy() error {
	return t.post(func() { t.destroy() }, true)
}

// ------------------------------------------------------------ internals
//
// The private method set below is the map a porter should follow; names are
// Node's minus the underscore. Bodies live on the actor goroutine and never
// call run(). Each doc comment is the specification.

// emitState is `this.emit('state', this)`. It also marks the snapshot dirty:
// every state event is observable change, saved once the closure ends.
func (t *Table) emitState() {
	t.liveDirty = true
	t.listener.OnState(t.view)
}

// setState writes the lifecycle state for the actor and the lock-free readers.
func (t *Table) setState(s TableState) { t.state.Store(s) }

// setHand swaps the live hand and keeps the HasHand atomic in step.
func (t *Table) setHand(h *hand) {
	t.hand = h
	t.hasHand.Store(h != nil)
}

// occupiedSeats (occupiedSeats getter) — non-nil seats in ascending index.
func (t *Table) occupiedSeats() []*seat {
	out := make([]*seat, 0, len(t.seats))
	for _, s := range t.seats {
		if s != nil {
			out = append(out, s)
		}
	}
	return out
}

// activeSeats (activeSeats getter) — occupied seats still betting, ascending.
func (t *Table) activeSeats() []*seat {
	out := make([]*seat, 0, len(t.seats))
	for _, s := range t.seats {
		if s != nil && s.status == SeatActive {
			out = append(out, s)
		}
	}
	return out
}

// fundedSeats (_fundedSeats): seats that can cover the boot and are therefore
// dealt into the next hand.
func (t *Table) fundedSeats() []*seat {
	out := make([]*seat, 0, len(t.seats))
	for _, s := range t.seats {
		if s != nil && s.chips >= t.cfg.BootAmount {
			out = append(out, s)
		}
	}
	return out
}

// findSeat (findSeat): the seat for userID or nil.
func (t *Table) findSeat(userID string) *seat {
	for _, s := range t.seats {
		if s != nil && s.userID == userID {
			return s
		}
	}
	return nil
}

// isFull is the actor-side `isFull` getter.
func (t *Table) isFull() bool { return len(t.occupiedSeats()) >= t.cfg.MaxPlayers }

// refreshPlayerCount keeps the lock-free PlayerCount in step with seats.
func (t *Table) refreshPlayerCount() { t.playerCount.Store(int32(len(t.occupiedSeats()))) }

// seatInfos copies every occupied seat in seat order.
func (t *Table) seatInfos() []SeatInfo {
	occupied := t.occupiedSeats()
	out := make([]SeatInfo, 0, len(occupied))
	for _, s := range occupied {
		out = append(out, *s.info())
	}
	return out
}

// info copies a seat into its exported form.
func (s *seat) info() *SeatInfo {
	cards := make([]Card, len(s.cards))
	copy(cards, s.cards)
	var lastAction *Action
	if s.lastAction != nil {
		a := *s.lastAction
		lastAction = &a
	}
	var avatar *string
	if s.avatarURL != nil {
		a := *s.avatarURL
		avatar = &a
	}
	var disconnectedAt *int64
	if s.disconnectedAt != nil {
		ms := Millis(*s.disconnectedAt)
		disconnectedAt = &ms
	}
	return &SeatInfo{
		SeatIndex:             s.seatIndex,
		UserID:                s.userID,
		DisplayName:           s.displayName,
		AvatarURL:             avatar,
		Chips:                 s.chips,
		SocketID:              s.socketID,
		Connected:             s.connected,
		Status:                s.status,
		Cards:                 cards,
		IsBlind:               s.isBlind,
		BlindMoves:            s.blindMoves,
		MissedTurns:           s.missedTurns,
		SideshowAskedThisTurn: s.sideshowAskedThisTurn,
		LastBet:               s.lastBet,
		LastAction:            lastAction,
		Contributed:           s.contributed,
		JoinedAt:              Millis(s.joinedAt),
		DisconnectedAt:        disconnectedAt,
		KickPending:           s.kickPending,
	}
}

// addPlayer (addPlayer) — see AddPlayer.
func (t *Table) addPlayer(p NewPlayer) (*SeatInfo, error) {
	if t.findSeat(p.UserID) != nil {
		return nil, NewGameError(CodeAlreadySeated, MsgAlreadySeated)
	}
	if t.isFull() {
		return nil, NewGameError(CodeTableFull, MsgTableFull)
	}
	seatIndex := -1
	for i, s := range t.seats {
		if s == nil {
			seatIndex = i
			break
		}
	}
	if seatIndex < 0 {
		return nil, NewGameError(CodeTableFull, MsgTableFull)
	}
	var avatar *string
	if p.AvatarURL != nil {
		a := *p.AvatarURL
		avatar = &a
	}
	s := &seat{
		seatIndex:   seatIndex,
		userID:      p.UserID,
		displayName: p.DisplayName,
		avatarURL:   avatar,
		chips:       p.Chips,
		socketID:    p.SocketID,
		connected:   true,
		status:      SeatWaiting,
		cards:       []Card{},
		isBlind:     true,
		joinedAt:    t.clock.Now(),
	}
	t.seats[seatIndex] = s
	t.refreshPlayerCount()
	t.listener.OnSeatUpdated(t.view, seatIndex)

	// Announce the arrival in the room log, so a player who joins mid-session
	// has context for the history they are about to be shown.
	if msg := t.chat.AddSystem(fmt.Sprintf(ChatJoinedFormat, p.DisplayName)); msg != nil {
		t.listener.OnChat(t.view, msg)
		t.liveAppendChat(msg)
	}

	t.maybeStart()
	t.emitState()
	return s.info(), nil
}

// removePlayer (_removePlayer) — see RemovePlayer. Leaving mid-hand is a
// pack: the stake stays in the pot, exactly as if they had folded.
func (t *Table) removePlayer(userID, reason string) *SeatInfo {
	s := t.findSeat(userID)
	if s == nil {
		return nil
	}

	wasOnTurn := t.hand != nil && t.hand.turnSeat == s.seatIndex
	wasActive := s.status == SeatActive

	// A sideshow one of them is no longer around for cannot be answered, so
	// it is dropped now rather than left to expire — otherwise the other
	// player would sit and wait out a clock for nothing.
	if t.hand != nil && t.hand.sideshow != nil {
		pending := t.hand.sideshow
		if pending.fromUserID == userID || pending.toUserID == userID {
			t.resolveSideshow(false, SideshowLeft)
		}
	}

	t.seats[s.seatIndex] = nil
	t.refreshPlayerCount()
	t.listener.OnSeatUpdated(t.view, s.seatIndex)
	if msg := t.chat.AddSystem(fmt.Sprintf(ChatLeftFormat, s.displayName)); msg != nil {
		t.listener.OnChat(t.view, msg)
		t.liveAppendChat(msg)
	}

	if wasActive && t.hand != nil {
		t.hand.packedUserIDs[userID] = struct{}{}
		s.status = SeatPacked
		t.syncContribution(s, SeatPacked)

		// Requirement 15/16: remember that this player abandoned the hand, and
		// who the most recent leaver was in case everybody walks away.
		if entry := t.hand.contributions[userID]; entry != nil {
			entry.leftMidHand = true
		}
		// CHECKPOINT 1 of 3 — A LEAVE OR SWITCH. They are gone, so their
		// wallet must be right NOW: they may sit down elsewhere or read their
		// balance at once. Their stake stays in the pot (leaving mid-hand is
		// a pack), and this is the row that resolves the hand for them —
		// hands_left_mid lands here, because they will not be at the
		// hand-end write.
		if entry := t.hand.contributions[userID]; entry != nil {
			entry.chips = s.chips
			t.checkpoint(entry, LedgerReasonHandLeft, LeftActionID(t.hand.id, userID), true)
		}
		departed := userID
		t.hand.lastDeparture = &departed
		t.listener.OnAction(t.view, ActionEvent{
			UserID: userID,
			Action: ActionPack,
			Amount: 0,
			Pot:    t.hand.pot,
			Stake:  t.hand.stake,
			Reason: reason,
		})
		if t.resolveIfOnlyOneLeft() {
			return s.info()
		}
		if wasOnTurn {
			t.clearTurnTimer()
			t.advanceTurn(s.seatIndex)
		}
	} else if t.State() == TableStarting && len(t.fundedSeats()) < t.cfg.MinPlayers {
		t.cancelStart()
	} else if t.State() == TableWaiting {
		// Somebody shown out for being unfunded may have been what stopped the
		// last start; with them gone the rest can get on with it.
		t.maybeStart()
	}

	t.emitState()
	return s.info()
}

// maybeStart (table.js _maybeStart): if destroyed, state != waiting, or a
// start timer is armed → return. sweepUnfunded(). If funded seats <
// MinPlayers → return. state = starting, startsAt = now + NextHandDelay,
// emit state, arm startTimer(NextHandDelay) → run(startHand).
func (t *Table) maybeStart() {
	if t.destroyed.Load() {
		return
	}
	if t.State() != TableWaiting {
		return
	}
	if t.startTimer != nil {
		return
	}

	// Requirement 32: the boot comes out of every player at the deal, so anyone
	// who cannot cover it is shown out now rather than sitting at a table they
	// can never be dealt into.
	t.sweepUnfunded()

	if len(t.fundedSeats()) < t.cfg.MinPlayers {
		return
	}

	t.setState(TableStarting)
	startsAt := t.clock.Now().Add(t.cfg.NextHandDelay)
	t.startsAt = &startsAt
	t.emitState()

	t.armStartTimer(func() { t.startHand() })
}

// armStartTimer arms the single start timer for NextHandDelay; when it fires,
// `then` runs on the actor after the timer handle has been released. A
// callback from a timer that was stopped too late is stale and ignored.
func (t *Table) armStartTimer(then func()) { t.armStartTimerAfter(t.cfg.NextHandDelay, then) }

// armStartTimerAfter is armStartTimer with an explicit delay (a restored
// countdown has less than NextHandDelay left).
func (t *Table) armStartTimerAfter(d time.Duration, then func()) {
	t.startTimerGen++
	gen := t.startTimerGen
	t.startTimer = t.clock.AfterFunc(d, func() {
		_ = t.run(func() {
			if t.startTimerGen != gen || t.startTimer == nil {
				return
			}
			t.startTimer = nil
			then()
		})
	})
}

// clearStartTimer stops the start timer if one is armed.
func (t *Table) clearStartTimer() {
	if t.startTimer != nil {
		t.startTimer.Stop()
		t.startTimer = nil
	}
}

// cancelStart (_cancelStart): stop startTimer, startsAt = nil, state =
// waiting, emit state.
func (t *Table) cancelStart() {
	t.clearStartTimer()
	t.startsAt = nil
	t.setState(TableWaiting)
	t.emitState()
}

// startHand (_startHand) deals. Since 9 Sep 2026 it writes NOTHING to
// PostgreSQL (owner's decision; see the Ledger doc): the boot comes out of
// each seat in memory and the whole hand lives in the live store until a
// checkpoint — a pack, a departure, or the hand ending — brings a player's
// wallet up to date.
//
// If destroyed or a hand is live → nil. sweepUnfunded(); participants =
// funded seats; if < MinPlayers → state waiting, startsAt nil, emit state,
// return. Builds the hand (id util.UUID(), handNo+1, pot = boot × n, stake =
// boot, round 0, dealerSeat = nextOccupiedSeat(dealerSeat, participants),
// Deal(n,3), a contribution per participant recording `chipsWritten` = the
// seat's stack BEFORE the boot, which is what PostgreSQL still holds), resets
// every occupied seat, deals the cards, takes the boot, state betting,
// emits handStarted, opens the turn at nextActiveSeat(dealerSeat).
func (t *Table) startHand() {
	if t.destroyed.Load() {
		return
	}
	if t.hand != nil {
		return
	}
	started := t.clock.Now()

	// Requirement 32: the boot is about to come out of everyone, so this is
	// the moment to show out anyone who cannot cover it. Doing it here as well
	// as in maybeStart matters: a player can sit down after the countdown has
	// already begun, and that path never passes through maybeStart again.
	t.sweepUnfunded()

	participants := t.fundedSeats()
	if len(participants) < t.cfg.MinPlayers {
		t.setState(TableWaiting)
		t.startsAt = nil
		t.emitState()
		return
	}

	bootAmount := t.cfg.BootAmount
	handID := util.UUID()
	handNo := t.handNo + 1
	dealerSeat := t.nextOccupiedSeat(t.dealerSeat, participants)
	deals, _ := Deal(len(participants), 3)

	h := &hand{
		id:            handID,
		handNo:        handNo,
		startedAt:     started,
		pot:           bootAmount * int64(len(participants)),
		stake:         bootAmount,
		round:         0,
		packedUserIDs: map[string]struct{}{},
		turnSeat:      -1,
		startSeat:     -1,
		seatOrder:     make([]int, 0, len(participants)),
		contributions: make(map[string]*contribution, len(participants)),
		contribOrder:  make([]string, 0, len(participants)),
		actionIDs:     map[string]struct{}{},
	}
	for i, s := range participants {
		h.seatOrder = append(h.seatOrder, s.seatIndex)
		h.contributions[s.userID] = &contribution{
			userID:      s.userID,
			displayName: s.displayName,
			seatIndex:   s.seatIndex,
			contributed: bootAmount,
			status:      SeatActive,
			sawCards:    false,
			cards:       deals[i],
			didChaal:    false,
			leftMidHand: false,
			// PostgreSQL still holds the pre-boot figure: nothing is written
			// at the deal.
			chipsWritten: s.chips,
			chips:        s.chips - bootAmount,
		}
		h.contribOrder = append(h.contribOrder, s.userID)
	}

	t.handNo = handNo
	t.dealerSeat = dealerSeat
	isParticipant := make(map[*seat]bool, len(participants))
	for _, s := range participants {
		isParticipant[s] = true
	}
	for _, s := range t.occupiedSeats() {
		s.cards = []Card{}
		s.isBlind = true
		s.blindMoves = 0
		s.lastBet = 0
		s.lastAction = nil
		s.contributed = 0
		if isParticipant[s] {
			s.status = SeatActive
		} else {
			s.status = SeatWaiting
		}
	}
	for i, s := range participants {
		s.cards = deals[i]
		s.contributed = bootAmount
		s.chips -= bootAmount
	}

	t.setHand(h)
	t.setState(TableBetting)
	t.startsAt = nil

	participantIDs := make([]string, 0, len(participants))
	for _, s := range participants {
		participantIDs = append(participantIDs, s.userID)
	}
	t.listener.OnHandStarted(t.view, HandStartedEvent{
		HandID:       h.id,
		HandNo:       t.handNo,
		DealerSeat:   t.dealerSeat,
		BootAmount:   bootAmount,
		Pot:          h.pot,
		Stake:        h.stake,
		Participants: participantIDs,
	})

	// Play opens to the dealer's left and rotates clockwise from there.
	firstSeat := t.nextActiveSeat(t.dealerSeat)
	h.startSeat = firstSeat
	t.setTurn(firstSeat, true)
	t.emitState()
	if t.onHandStart != nil {
		t.onHandStart(t.clock.Now().Sub(started))
	}
}

// nextOccupiedSeat (_nextOccupiedSeat): the first seat strictly clockwise
// after fromSeat whose index is in pool; falls back to pool[0].
func (t *Table) nextOccupiedSeat(fromSeat int, pool []*seat) int {
	allowed := make(map[int]bool, len(pool))
	for _, s := range pool {
		allowed[s.seatIndex] = true
	}
	n := len(t.seats)
	for step := 1; step <= n; step++ {
		index := ((fromSeat+step)%n + n) % n
		if allowed[index] {
			return index
		}
	}
	if len(pool) > 0 {
		return pool[0].seatIndex
	}
	return -1
}

// nextActiveSeat (_nextActiveSeat): next ACTIVE seat clockwise = ascending
// index, wrapping; -1 if none. rightActiveSeat (_rightActiveSeat) walks
// DOWNWARD — the player on your right acted just before you (who a sideshow
// is asked of). nextOccupiedSeat (_nextOccupiedSeat) is nextActiveSeat over
// a given pool, falling back to pool[0]. distance(from, to) = (to - from +
// n) % n.
func (t *Table) nextActiveSeat(fromSeat int) int {
	n := len(t.seats)
	for step := 1; step <= n; step++ {
		index := ((fromSeat+step)%n + n) % n
		if s := t.seats[index]; s != nil && s.status == SeatActive {
			return index
		}
	}
	return -1
}

// rightActiveSeat (_rightActiveSeat): the active seat on this seat's right —
// play moves clockwise (to the left), so the player on your right is the one
// who acted immediately before you. -1 when there is nobody.
func (t *Table) rightActiveSeat(fromSeat int) int {
	n := len(t.seats)
	for step := 1; step <= n; step++ {
		index := ((fromSeat-step)%n + n) % n
		if s := t.seats[index]; s != nil && s.status == SeatActive && index != fromSeat {
			return index
		}
	}
	return -1
}

// distance (_distance): clockwise seats from `from` to `to`.
func (t *Table) distance(from, to int) int {
	n := len(t.seats)
	return ((to-from)%n + n) % n
}

// setTurn (_setTurn): if seatIndex < 0 return. hand.turnSeat = seatIndex; if
// freshTurn → seat.sideshowAskedThisTurn = false; deadline = now +
// TurnTimeout; turnToken = util.UUID(); emit turn{deadline, TurnTimeout,
// turnOptions}; clearTurnTimer; arm turnTimer(TurnTimeout) →
// run(onTurnTimeout(seatIndex, token)).
//
// freshTurn is false when the same player is simply getting their clock back
// — after a sideshow they asked for, say. Their one ask has been used, and
// handing it back would let them ask again in the same turn.
func (t *Table) setTurn(seatIndex int, freshTurn bool) {
	if seatIndex < 0 || t.hand == nil {
		return
	}
	s := t.seats[seatIndex]
	if s == nil {
		return
	}
	t.hand.turnSeat = seatIndex
	if freshTurn {
		s.sideshowAskedThisTurn = false
	}
	deadline := t.clock.Now().Add(t.cfg.TurnTimeout)
	t.hand.turnDeadline = deadline

	// Names this particular turn. The timeout that is armed below carries it,
	// so a timeout that fires late — queued behind a bet that was already on
	// its way to the database — is recognised as stale and ignored.
	token := util.UUID()
	t.hand.turnToken = token

	t.listener.OnTurn(t.view, TurnEvent{
		UserID:    s.userID,
		SeatIndex: seatIndex,
		Deadline:  Millis(deadline),
		TimeoutMs: t.cfg.TurnTimeout.Milliseconds(),
		Options:   t.turnOptions(s),
	})

	t.clearTurnTimer()
	t.turnTimer = t.clock.AfterFunc(t.cfg.TurnTimeout, func() {
		_ = t.run(func() { t.onTurnTimeout(seatIndex, token) })
	})
}

// clearTurnTimer (_clearTurnTimer) stops the turn clock if it is running.
func (t *Table) clearTurnTimer() {
	if t.turnTimer != nil {
		t.turnTimer.Stop()
		t.turnTimer = nil
	}
}

// onTurnTimeout (_onTurnTimeout; requirement 6d/31): ignore if no hand, seat
// empty, turnSeat != seatIndex, token != hand.turnToken, or seat not active.
// missedTurns++; pack(seat, PackReasonTimeout); if missedTurns >=
// MaxMissedTurns → kick(seat, idle, sprintf(KickMessageIdleFormat)).
func (t *Table) onTurnTimeout(seatIndex int, token string) {
	if t.hand == nil || seatIndex < 0 || seatIndex >= len(t.seats) {
		return
	}
	s := t.seats[seatIndex]
	if s == nil || t.hand.turnSeat != seatIndex {
		return
	}
	if token != "" && t.hand.turnToken != token {
		return
	}
	if s.status != SeatActive {
		return
	}

	s.missedTurns++
	t.pack(s, PackReasonTimeout, true)

	// Requirement 31: somebody who has stopped playing is holding up everyone
	// else, a whole turn clock at a time. After three in a row the seat is
	// given back to the table.
	if t.cfg.MaxMissedTurns > 0 && s.missedTurns >= t.cfg.MaxMissedTurns {
		t.kick(s, KickReasonIdle, fmt.Sprintf(KickMessageIdleFormat, s.missedTurns))
	}
}

// kick (_kick) only EMITS OnKick{userId, displayName, reason, message}; the
// RoomManager does the removing.
func (t *Table) kick(s *seat, reason, message string) {
	t.listener.OnKick(t.view, KickEvent{
		UserID:      s.userID,
		DisplayName: s.displayName,
		Reason:      reason,
		Message:     message,
	})
}

// sweepUnfunded (_sweepUnfunded; requirements 31/32): ONLY between hands (`if
// hand != nil return`). A seat with chips < boot and !kickPending is shown out
// with kick(insufficient_chips, KickMessageInsufficientChips) — at once when
// UnfundedGrace is 0 (Node's rule), otherwise once the grace it was given the
// first time a sweep found it short has run out. A seat that is funded again
// loses its grace.
//
// Mid-hand a player who has bet everything is legitimately down to nothing,
// and throwing them out would take their stake with them.
//
// The grace is for buying chips (owner's decision, 11 Sep 2026). This sweep
// runs the moment a hand ends (endHand → maybeStart), so a player who had just
// lost their last chips had no time at all to get through a store sheet: the
// purchase landed in PostgreSQL and the player landed in the lobby.
func (t *Table) sweepUnfunded() {
	if t.hand != nil {
		return
	}
	now := t.clock.Now()
	granted := false
	for _, s := range t.occupiedSeats() {
		if s.chips >= t.cfg.BootAmount {
			if s.unfundedUntil != nil {
				s.unfundedUntil = nil
				t.liveDirty = true
			}
			continue
		}
		// The removal a kick asks for is queued behind whatever is running, so
		// a second sweep before it lands would ask again. Once is enough.
		if s.kickPending {
			continue
		}
		if t.cfg.UnfundedGrace > 0 {
			if s.unfundedUntil == nil {
				until := now.Add(t.cfg.UnfundedGrace)
				s.unfundedUntil = &until
				t.liveDirty = true
				granted = true
			}
			if s.unfundedUntil.After(now) {
				continue
			}
		}
		t.kickUnfunded(s)
	}
	t.armUnfundedTimer()
	if granted {
		// The deadline rides in that player's `you`: send it now, not whenever
		// the table next happens to change.
		t.emitState()
	}
}

// kickUnfunded marks a seat that cannot cover the boot and asks the
// RoomManager to show it out.
func (t *Table) kickUnfunded(s *seat) {
	s.kickPending = true
	s.unfundedUntil = nil
	t.liveDirty = true
	t.kick(s, KickReasonInsufficientChips, KickMessageInsufficientChips)
}

// expireUnfunded runs when the unfunded timer fires: every seat whose grace
// has run out and that still cannot cover the boot is shown out — mid-hand
// too, since a seat sitting a hand out has nothing in its pot. A seat that is
// funded again just loses its grace.
func (t *Table) expireUnfunded() {
	now := t.clock.Now()
	for _, s := range t.occupiedSeats() {
		if s.unfundedUntil == nil || s.unfundedUntil.After(now) || s.kickPending {
			continue
		}
		if s.chips >= t.cfg.BootAmount {
			s.unfundedUntil = nil
			t.liveDirty = true
			continue
		}
		if t.hand != nil && s.status == SeatActive {
			continue // an unfunded seat is never dealt in; the hand-end sweep has it
		}
		t.kickUnfunded(s)
	}
	t.armUnfundedTimer()
}

// armUnfundedTimer (re)arms the one unfunded timer for the earliest grace
// still running, and leaves it stopped when there is none.
func (t *Table) armUnfundedTimer() {
	t.clearUnfundedTimer()
	if t.destroyed.Load() {
		return
	}
	var next *time.Time
	for _, s := range t.occupiedSeats() {
		if s.unfundedUntil == nil || s.kickPending || (t.hand != nil && s.status == SeatActive) {
			continue
		}
		if next == nil || s.unfundedUntil.Before(*next) {
			next = s.unfundedUntil
		}
	}
	if next == nil {
		return
	}
	d := max(next.Sub(t.clock.Now()), 0)
	t.unfundedTimerGen++
	gen := t.unfundedTimerGen
	t.unfundedTimer = t.clock.AfterFunc(d, func() {
		_ = t.run(func() {
			if t.unfundedTimerGen != gen || t.unfundedTimer == nil {
				return
			}
			t.unfundedTimer = nil
			t.expireUnfunded()
		})
	})
}

// clearUnfundedTimer stops the unfunded timer if one is armed.
func (t *Table) clearUnfundedTimer() {
	if t.unfundedTimer != nil {
		t.unfundedTimer.Stop()
		t.unfundedTimer = nil
	}
}

// advanceTurn (_advanceTurn): if no hand return; next = nextActiveSeat(from);
// if none return. If potCapReached() (MaxPot > 0 && pot + stake > MaxPot) →
// clearTurnTimer, resolveShowdown(active, WinPotLimit, nil), return. Round
// counting by DISTANCE: toNext = distance(from, next), toStart =
// distance(from, startSeat); if toStart > 0 && toStart <= toNext → round++,
// and if MaxBetRounds > 0 && round >= MaxBetRounds → forcedShowdown, return.
// setTurn(next, fresh); emit state.
func (t *Table) advanceTurn(fromSeat int) {
	if t.hand == nil {
		return
	}

	next := t.nextActiveSeat(fromSeat)
	if next == -1 {
		return
	}

	// Requirement 22: once no further bet can fit under the pot cap, everyone
	// still in shows and the best hand takes it.
	if t.potCapReached() {
		t.clearTurnTimer()
		t.resolveShowdown(t.activeSeats(), WinPotLimit, nil)
		return
	}

	// A betting round completes whenever the turn steps over the seat that
	// opened the hand. Measuring by distance (rather than landing exactly on
	// that seat) keeps the count right after the opener packs or leaves.
	toNext := t.distance(fromSeat, next)
	toStart := t.distance(fromSeat, t.hand.startSeat)
	if toStart > 0 && toStart <= toNext {
		t.hand.round++
		// A round cap of 0 is a blind table's: the turn goes round for as long
		// as the players keep it going.
		if t.cfg.MaxBetRounds > 0 && t.hand.round >= t.cfg.MaxBetRounds {
			t.forcedShowdown()
			return
		}
	}

	t.setTurn(next, true)
	t.emitState()
}

// potCapReached (_potCapReached): true when the pot has reached the table's
// cap, or is close enough that not even the smallest legal bet (one blind
// unit) would fit underneath it.
func (t *Table) potCapReached() bool {
	if t.cfg.MaxPot <= 0 || t.hand == nil {
		return false
	}
	return t.hand.pot+t.hand.stake > t.cfg.MaxPot
}

// ------------------------------------------------------------ betting math

// betOptions (betOptions) computes the ladder — see BetOptions' doc.
func (t *Table) betOptions(s *seat) BetOptions {
	steps := make([]int64, 0, 8)
	if t.hand == nil {
		return BetOptions{Steps: steps}
	}
	unit := t.hand.stake
	base := unit
	if !s.isBlind {
		base = unit * 2
	}
	// Not the pot cap — the largest a single bet may be (a multiple of the
	// boot). A multiplier of 0 means there is none, and only the player's own
	// stack bounds the bet — a blind table's rule.
	perBetCeiling := int64(math.MaxInt64)
	if t.cfg.PotLimitMultiplier > 0 {
		perBetCeiling = t.cfg.BootAmount * t.cfg.PotLimitMultiplier
	}
	ceiling := min(perBetCeiling, s.chips)

	// Likewise 0 rungs means the ladder is as long as the stack allows.
	maxSteps := t.cfg.MaxRaiseSteps
	// Requirement 22: a private table's pot is capped, so a bet that would push
	// it past the ceiling is not offered at all. Headroom is unbounded when the
	// table has no cap.
	headroom := int64(math.MaxInt64)
	if t.cfg.MaxPot > 0 {
		headroom = t.cfg.MaxPot - t.hand.pot
	}

	// Node: `let amount = Math.min(base, perBetCeiling)` — when the stake has
	// outgrown the per-bet ceiling the only rung is the ceiling itself.
	amount := min(base, perBetCeiling)
	for amount > 0 && amount <= ceiling && amount <= headroom && (maxSteps <= 0 || len(steps) < maxSteps) {
		steps = append(steps, amount)
		if amount > math.MaxInt64/2 {
			break
		}
		amount *= 2
	}

	options := BetOptions{Steps: steps}
	if len(steps) > 0 {
		options.Chaal = Int64Ptr(steps[0])
		options.Max = Int64Ptr(steps[len(steps)-1])
	}
	if len(steps) > 1 {
		options.Raise = Int64Ptr(steps[1])
	}
	return options
}

// showCost (showCost): cost of calling a show, using the same handicap as a
// chaal. nil when the player cannot afford even that.
func (t *Table) showCost(s *seat) *int64 {
	return t.betOptions(s).Chaal
}

// turnOptions (turnOptions): from betOptions; Show = showCost (== Chaal) only
// when exactly two active seats and chips >= cost; CanSideshow /
// SideshowWith from sideshowBlockedReason and rightActiveSeat.
func (t *Table) turnOptions(s *seat) TurnOptions {
	options := t.betOptions(s)
	var show *int64
	if len(t.activeSeats()) == 2 {
		if cost := t.showCost(s); cost != nil && s.chips >= *cost {
			show = Int64Ptr(*cost)
		}
	}

	blocked := t.sideshowBlockedReason(s)
	rightIndex := -1
	if blocked == "" {
		rightIndex = t.rightActiveSeat(s.seatIndex)
	}
	var sideshowWith *string
	if rightIndex != -1 {
		if right := t.seats[rightIndex]; right != nil {
			sideshowWith = StrPtr(right.displayName)
		}
	}

	var currentStake, pot int64
	if t.hand != nil {
		currentStake = t.hand.stake
		pot = t.hand.pot
	}
	return TurnOptions{
		CanSee:       s.isBlind,
		CanSideshow:  blocked == "",
		SideshowWith: sideshowWith,
		Chaal:        options.Chaal,
		Raise:        options.Raise,
		RaiseSteps:   options.Steps,
		MaxBet:       options.Max,
		Show:         show,
		CanPack:      true,
		IsBlind:      s.isBlind,
		CurrentStake: currentStake,
		Chips:        s.chips,
		Pot:          pot,
	}
}

// sideshowBlockedReason (sideshowBlockedReason; requirement 33) returns "" when
// allowed, else the first failing check IN THIS ORDER: no_hand, not_in_hand,
// not_your_turn, sideshow_pending, already_asked, too_few_players (active <
// SideshowMinPlayers), you_are_blind, no_neighbour, neighbour_is_blind.
//
// Returned as a reason rather than a boolean so the same check can gate the
// button in the client and refuse the action on the server, and say the same
// thing in both places.
func (t *Table) sideshowBlockedReason(s *seat) string {
	if t.hand == nil {
		return SideshowBlockedNoHand
	}
	if s.status != SeatActive {
		return SideshowBlockedNotInHand
	}
	if t.hand.turnSeat != s.seatIndex {
		return SideshowBlockedNotYourTurn
	}
	if t.hand.sideshow != nil {
		return SideshowBlockedPending
	}
	// One ask per turn. Wanting another means waiting for the next one.
	if s.sideshowAskedThisTurn {
		return SideshowBlockedAlreadyAsked
	}
	if t.cfg.SideshowMinPlayers > 0 && len(t.activeSeats()) < t.cfg.SideshowMinPlayers {
		return SideshowBlockedTooFewPlayers
	}
	// Both hands have to have been looked at: comparing cards nobody has seen
	// is not a decision, it is a coin toss.
	if s.isBlind {
		return SideshowBlockedYouAreBlind
	}
	rightIndex := t.rightActiveSeat(s.seatIndex)
	if rightIndex == -1 {
		return SideshowBlockedNoNeighbour
	}
	if t.seats[rightIndex].isBlind {
		return SideshowBlockedNeighbourIsBlind
	}
	return ""
}

// chargeToPot (_chargeToPot) moves chips from a seat into the pot. Since the
// owner's decision of 9 Sep 2026 it writes NOTHING to PostgreSQL: the money
// moves in the table's memory and, through the snapshot flushed at the end of
// this closure, in the live store. The wallet catches up at the next
// checkpoint — this player packing, leaving, or the hand ending.
//
// The two refusals the database used to produce are made here instead:
//
//   - duplicate_action, when this hand has already accepted that action id (a
//     replayed request; the chip_ledger UNIQUE index used to catch it);
//   - insufficient_chips, when the seat does not hold the stake. The seat is
//     the live truth for the stack, so this IS the balance check.
func (t *Table) chargeToPot(s *seat, amount int64, actionID, reason string) error {
	// A client id is an opaque idempotency token. The ledger's own action ids
	// ("<handId>:settle:<userId>", "<handId>:packed:<userId>",
	// "<handId>:left:<userId>", "<userId>:milestone:<n>") are the only
	// colon-separated ones, and a client must never be able to occupy one of
	// those keys ahead of the server — a bet carrying another player's
	// "<userId>:milestone:25" would make that player's milestone claim fail
	// on the UNIQUE index. The socket layer applies the same rule; this is
	// the last line.
	if actionID == "" || strings.ContainsRune(actionID, reservedActionIDSeparator) {
		actionID = util.UUID()
	}
	if _, seen := t.hand.actionIDs[actionID]; seen {
		err := &GameError{Code: CodeDuplicateAction, Message: MsgDuplicateAction}
		t.listener.OnPersistError(t.view, PersistErrorEvent{UserID: s.userID, Delta: -amount, Reason: reason, Err: err})
		return err
	}
	if s.chips < amount {
		err := &GameError{Code: CodeInsufficientChips, Message: MsgInsufficientForBet}
		t.listener.OnPersistError(t.view, PersistErrorEvent{UserID: s.userID, Delta: -amount, Reason: reason, Err: err})
		return err
	}

	t.hand.actionIDs[actionID] = struct{}{}
	s.chips -= amount
	s.contributed += amount
	t.hand.pot += amount

	if existing := t.hand.contributions[s.userID]; existing != nil {
		existing.contributed = s.contributed
		existing.chips = s.chips
	} else {
		t.hand.contributions[s.userID] = &contribution{
			userID:       s.userID,
			displayName:  s.displayName,
			seatIndex:    s.seatIndex,
			contributed:  s.contributed,
			status:       s.status,
			sawCards:     !s.isBlind,
			cards:        s.cards,
			chips:        s.chips,
			chipsWritten: s.chips + amount,
		}
		t.hand.contribOrder = append(t.hand.contribOrder, s.userID)
	}
	return nil
}

// checkpoint writes ONE player's chips through to PostgreSQL — the pack
// checkpoint and the leave/switch checkpoint (the hand end goes through
// endHand's Settle, which does the same arithmetic for everyone at once).
//
// delta = the stack the live state has now MINUS the stack PostgreSQL was
// last given. A player written twice therefore moves money once: the second
// delta is zero and the row records only the outcome. Never an absolute
// overwrite — see the Ledger doc.
//
// A failure is reported (persistError) and never refuses the move: the pack
// or the departure has already happened at the table. The wallet is then
// behind by that player's stake until the hand-end write catches it up (their
// chipsWritten was not advanced), which is why nothing is lost.
func (t *Table) checkpoint(entry *contribution, reason string, actionID string, outcome bool) {
	if entry == nil {
		return
	}
	delta := entry.chips - entry.chipsWritten
	req := CheckpointRequest{
		RoomID: t.id,
		HandID: t.hand.id,
		Entry: SettleEntry{
			UserID:      entry.userID,
			Delta:       delta,
			ActionID:    actionID,
			Reason:      reason,
			Outcome:     outcome,
			DidChaal:    entry.didChaal,
			LeftMidHand: entry.leftMidHand,
		},
	}
	if _, err := t.ledger.Checkpoint(t.ctx, req); err != nil {
		t.listener.OnPersistError(t.view, PersistErrorEvent{UserID: entry.userID, Delta: delta, Reason: reason, HandID: t.hand.id, Err: err})
		return
	}
	t.version.Add(1)
	entry.chipsWritten = entry.chips
}

// refusal (_refusal) maps a Ledger error onto the GameError the player is
// told: insufficient_chips → MsgInsufficientForBet; duplicate_action →
// MsgDuplicateAction; anything else → persist_failed / MsgPersistFailed.
func (t *Table) refusal(err error) *GameError {
	switch CodeOf(err, "") {
	case CodeInsufficientChips:
		return &GameError{Code: CodeInsufficientChips, Message: MsgInsufficientForBet, Cause: err}
	case CodeDuplicateAction:
		return &GameError{Code: CodeDuplicateAction, Message: MsgDuplicateAction, Cause: err}
	default:
		return &GameError{Code: CodePersistFailed, Message: MsgPersistFailed, Cause: err}
	}
}

// syncContribution (_syncContribution) copies a seat's live values onto its
// hand contribution record, with the given status.
func (t *Table) syncContribution(s *seat, status SeatState) {
	if t.hand == nil {
		return
	}
	entry := t.hand.contributions[s.userID]
	if entry == nil {
		return
	}
	entry.contributed = s.contributed
	entry.status = status
	entry.sawCards = !s.isBlind
	entry.cards = s.cards
	entry.chips = s.chips
}

// ---------------------------------------------------------------- actions

// act (_act) — see Act.
func (t *Table) act(userID string, action Action, req ActRequest) (ActResult, error) {
	if t.hand == nil {
		return ActResult{}, NewGameError(CodeNoHand, MsgNoHand)
	}
	s := t.findSeat(userID)
	if s == nil {
		return ActResult{}, NewGameError(CodeNotSeated, MsgNotSeated)
	}
	if s.status != SeatActive {
		return ActResult{}, NewGameError(CodeNotInHand, MsgNotInHand)
	}

	// Seeing your own cards is not a move: it costs nothing, changes nothing
	// for anyone else, and a player may look whenever they like. Everything
	// that does change the hand still waits for their turn.
	if action != ActionSee && t.hand.turnSeat != s.seatIndex {
		return ActResult{}, NewGameError(CodeNotYourTurn, MsgNotYourTurn)
	}

	var result ActResult
	var err error
	switch action {
	case ActionSee:
		result, err = t.see(s, false)
	case ActionChaal:
		result, err = t.bet(s, BetChaal, req.Amount, req.ActionID)
	case ActionRaise:
		result, err = t.bet(s, BetRaise, req.Amount, req.ActionID)
	case ActionPack:
		result = t.pack(s, PackReasonPack, true)
	case ActionShow:
		result, err = t.show(s, req.ActionID)
	case ActionSideshow:
		result, err = t.requestSideshow(s)
	default:
		return ActResult{}, Errorf(CodeUnknownAction, MsgUnknownActionFormat, string(action))
	}
	if err != nil {
		return ActResult{}, err
	}

	// They are here and playing, so whatever they had missed before does not
	// count against them any more. Cleared only once the move went through.
	s.missedTurns = 0
	return result, nil
}

// see (_see) reveals the player's own cards to them. Free, and deliberately
// does not end the turn — the turn timer keeps running, so seeing costs
// thinking time. auto is true for the reveal MaxBlindMoves forces.
func (t *Table) see(s *seat, auto bool) (ActResult, error) {
	if !s.isBlind {
		return ActResult{}, NewGameError(CodeAlreadySeen, MsgAlreadySeen)
	}
	s.isBlind = false
	t.syncContribution(s, s.status)

	t.listener.OnCards(t.view, CardsEvent{UserID: s.userID, Cards: CardCodes(s.cards)})
	autoFlag := auto
	t.listener.OnAction(t.view, ActionEvent{
		UserID: s.userID,
		Action: ActionSee,
		Amount: 0,
		Auto:   &autoFlag,
		Pot:    t.hand.pot,
		Stake:  t.hand.stake,
	})

	// Re-issue the turn so the client picks up the seen player's bet ladder,
	// which is double the blind one. Only when it really is their turn: a
	// player may look at any point now, and the automatic reveal happens as
	// their turn is ending, so in both of those cases telling the table it is
	// their turn would be a lie.
	if !auto && t.hand.turnSeat == s.seatIndex {
		remaining := t.hand.turnDeadline.Sub(t.clock.Now()).Milliseconds()
		if remaining < 0 {
			remaining = 0
		}
		t.listener.OnTurn(t.view, TurnEvent{
			UserID:    s.userID,
			SeatIndex: s.seatIndex,
			Deadline:  Millis(t.hand.turnDeadline),
			TimeoutMs: remaining,
			Options:   t.turnOptions(s),
		})
	}

	t.emitState()
	resultAuto := auto
	return ActResult{Action: string(ActionSee), Auto: &resultAuto}, nil
}

// bet (_bet) places a chaal or raise. `requested` is the amount the client
// picked with the +/− stepper. It is never trusted: the ladder is recomputed
// here and the amount must be one of its rungs, which is what stops a
// tampered client betting an arbitrary figure or more than it holds.
// Omitting it takes the default for the kind.
//
// Validation happens first and costs nothing; then the chips move in the
// database; then, and only then, the table's own state follows.
func (t *Table) bet(s *seat, kind BetKind, requested *int64, actionID string) (ActResult, error) {
	options := t.betOptions(s)

	if len(options.Steps) == 0 {
		return ActResult{}, NewGameError(CodeInsufficientChips, MsgInsufficientToBet)
	}

	var amount *int64
	if requested == nil {
		if kind == BetRaise {
			amount = options.Raise
		} else {
			amount = options.Chaal
		}
	} else {
		// Node's `Number.isInteger` check cannot fail here: the socket layer
		// only ever hands the Table a safe integer. The rung check follows.
		onLadder := false
		for _, step := range options.Steps {
			if step == *requested {
				onLadder = true
				break
			}
		}
		if !onLadder {
			return ActResult{}, NewGameError(CodeInvalidBet, MsgBetNotAvailable)
		}
		// A "raise" has to actually raise; the base rung is a chaal.
		if kind == BetRaise && *requested < options.Steps[0]*2 {
			return ActResult{}, NewGameError(CodeInvalidBet, MsgRaiseTooSmall)
		}
		amount = Int64Ptr(*requested)
	}

	if amount == nil || *amount <= 0 {
		return ActResult{}, NewGameError(CodeInvalidBet, MsgBetUnavailable)
	}
	if s.chips < *amount {
		return ActResult{}, NewGameError(CodeInsufficientChips, MsgInsufficientForBet)
	}

	if err := t.chargeToPot(s, *amount, actionID, LedgerReasonBet); err != nil {
		return ActResult{}, err
	}

	// What this player just did, so the table can show it rather than only the
	// running total. Kept on the seat rather than inferred from the action
	// stream, so it survives a reconnect and is there for a late joiner.
	s.lastBet = *amount
	wireAction := ActionChaal
	if kind == BetRaise {
		wireAction = ActionRaise
	}
	s.lastAction = ActionPtr(wireAction)

	// Requirement 16: a hand only counts as played once chips go in beyond the
	// boot, so record that here rather than at the deal.
	if entry := t.hand.contributions[s.userID]; entry != nil {
		entry.didChaal = true
	}

	// The stake is always expressed as a blind unit, so halve a seen player's bet.
	if s.isBlind {
		t.hand.stake = *amount
	} else {
		t.hand.stake = *amount / 2
	}

	t.listener.OnAction(t.view, ActionEvent{
		UserID: s.userID,
		Action: wireAction,
		Amount: *amount,
		Pot:    t.hand.pot,
		Stake:  t.hand.stake,
	})

	// A player gets a limited number of bets while blind; on the last one the
	// cards turn face up by themselves, so nobody plays a whole hand unseen.
	// The bet above was still a blind one — the reveal follows it.
	autoSeen := false
	if s.isBlind {
		s.blindMoves++
		if t.cfg.MaxBlindMoves > 0 && s.blindMoves >= t.cfg.MaxBlindMoves {
			_, _ = t.see(s, true)
			autoSeen = true
		}
	}

	t.clearTurnTimer()
	t.advanceTurn(s.seatIndex)
	t.emitState()
	return ActResult{Action: string(kind), Amount: Int64Ptr(*amount), AutoSeen: &autoSeen}, nil
}

// pack (_pack): status packed, lastAction PACK, packedUserIDs += id,
// syncContribution(packed); emit action PACK{reason}; clearTurnTimer; if
// resolveIfOnlyOneLeft() return; if advanceTurn → advanceTurn(seatIndex);
// emit state.
//
// advanceTurn is false when the packed player was not the one on turn — a
// sideshow they lost, for instance. The turn never left whoever holds it, so
// moving it on would skip them.
func (t *Table) pack(s *seat, reason string, advanceTurn bool) ActResult {
	result := ActResult{Action: string(ActionPack), Reason: reason}
	if t.hand == nil {
		return result
	}
	s.status = SeatPacked
	s.lastAction = ActionPtr(ActionPack)
	t.hand.packedUserIDs[s.userID] = struct{}{}
	t.syncContribution(s, SeatPacked)

	// CHECKPOINT 2 of 3 — A PACK. Their stake is fixed the moment they fold,
	// so the wallet is brought up to date now rather than at the hand end
	// (owner's decision of 9 Sep 2026). The outcome row still comes at the
	// settlement, where the delta is zero and the counters land.
	t.checkpoint(t.hand.contributions[s.userID], LedgerReasonHandPacked, PackedActionID(t.hand.id, s.userID), false)

	t.listener.OnAction(t.view, ActionEvent{
		UserID: s.userID,
		Action: ActionPack,
		Amount: 0,
		Pot:    t.hand.pot,
		Stake:  t.hand.stake,
		Reason: reason,
	})

	t.clearTurnTimer()

	if t.resolveIfOnlyOneLeft() {
		return result
	}

	if advanceTurn {
		t.advanceTurn(s.seatIndex)
	}
	t.emitState()
	return result
}

// resolveIfOnlyOneLeft (_resolveIfOnlyOneLeft; requirements 6e/6f/15): with
// > 1 active seat → false. Exactly one → endHand(winner, last_standing, no
// reveals). None → endHand(hand.lastDeparture, all_left, no reveals) — the
// pot goes to the last leaver, who is no longer seated, which is why the
// winner is a userId and not a seat. Returns true.
func (t *Table) resolveIfOnlyOneLeft() bool {
	active := t.activeSeats()
	if len(active) > 1 {
		return false
	}
	if len(active) == 1 {
		t.endHand(StrPtr(active[0].userID), WinLastStanding, []Reveal{})
	} else {
		// Requirement 15: everybody walked out, so the pot goes to whoever left
		// last rather than evaporating. They are no longer seated, which is why
		// the hand is settled by user id rather than by seat.
		var winner *string
		if t.hand != nil && t.hand.lastDeparture != nil {
			winner = StrPtr(*t.hand.lastDeparture)
		}
		t.endHand(winner, WinAllLeft, []Reveal{})
	}
	return true
}

// requestSideshow (_requestSideshow) asks the player on the right to compare
// hands privately. Nothing is decided here — it is a request, and it stands
// for a few seconds until they answer or the clock runs out. The turn clock
// is stopped for the duration: the player asking should not lose their turn
// while waiting for somebody else to press a button.
func (t *Table) requestSideshow(s *seat) (ActResult, error) {
	if blocked := t.sideshowBlockedReason(s); blocked != "" {
		var message string
		switch blocked {
		case SideshowBlockedPending:
			message = MsgSideshowPending
		case SideshowBlockedAlreadyAsked:
			message = MsgSideshowAlreadyAsked
		case SideshowBlockedTooFewPlayers:
			message = fmt.Sprintf(MsgSideshowTooFewFormat, t.cfg.SideshowMinPlayers)
		case SideshowBlockedYouAreBlind:
			message = MsgSideshowYouAreBlind
		case SideshowBlockedNeighbourIsBlind:
			message = MsgSideshowNeighbour
		case SideshowBlockedNoNeighbour:
			message = MsgSideshowNoNeighbour
		default:
			message = MsgSideshowGeneric
		}
		return ActResult{}, NewGameError(blocked, message)
	}

	target := t.seats[t.rightActiveSeat(s.seatIndex)]
	s.sideshowAskedThisTurn = true

	// The turn clock stops while the request stands, and is restarted from
	// full when it resolves.
	t.clearTurnTimer()

	expiresAt := t.clock.Now().Add(t.cfg.SideshowTimeout)
	pending := &pendingSideshow{
		fromUserID: s.userID,
		fromSeat:   s.seatIndex,
		toUserID:   target.userID,
		toSeat:     target.seatIndex,
		expiresAt:  expiresAt,
	}
	t.hand.sideshow = pending
	if t.cfg.SideshowTimeout > 0 {
		pending.timer = t.clock.AfterFunc(t.cfg.SideshowTimeout, func() {
			_ = t.run(func() {
				// A timer stopped a moment too late must not expire a newer
				// request that has since been opened.
				if t.hand == nil || t.hand.sideshow != pending {
					return
				}
				t.resolveSideshow(false, SideshowTimeout)
			})
		})
	}

	// Everyone sees that it was asked — that is public — but not the cards.
	t.listener.OnSideshowRequested(t.view, SideshowRequestedEvent{
		FromUserID: s.userID,
		FromName:   s.displayName,
		FromSeat:   s.seatIndex,
		ToUserID:   target.userID,
		ToName:     target.displayName,
		ToSeat:     target.seatIndex,
		ExpiresAt:  Millis(expiresAt),
		TimeoutMs:  t.cfg.SideshowTimeout.Milliseconds(),
	})

	t.emitState()
	return ActResult{Action: string(ActionSideshow), ToUserID: target.userID}, nil
}

// resolveSideshow (_resolveSideshow) settles a sideshow — see
// RespondToSideshow. Returns ok=false when nothing was pending (a late timer
// is a no-op). On a refusal nothing changes but the clock. On an acceptance
// the two hands are compared and the weaker one packs — the asker loses a
// tie, which is the usual rule and stops asking being free.
func (t *Table) resolveSideshow(accepted bool, reason string) (SideshowOutcome, bool) {
	if t.hand == nil || t.hand.sideshow == nil {
		return SideshowOutcome{}, false
	}
	pending := t.hand.sideshow
	if pending.timer != nil {
		pending.timer.Stop()
		pending.timer = nil
	}
	t.hand.sideshow = nil

	asker := t.findSeat(pending.fromUserID)
	asked := t.findSeat(pending.toUserID)

	var packedUserID *string
	bothInHand := asker != nil && asked != nil && asker.status == SeatActive && asked.status == SeatActive

	if accepted && bothInHand {
		a := Evaluate(asker.cards, EvaluateOptions{})
		b := Evaluate(asked.cards, EvaluateOptions{})
		// A tie goes against the player who asked.
		loser := asker
		if Compare(a, b) > 0 {
			loser = asked
		}
		packedUserID = StrPtr(loser.userID)

		// Only the two of them ever see these cards.
		t.listener.OnSideshowReveal(t.view, SideshowRevealEvent{
			UserIDs: []string{asker.userID, asked.userID},
			Reveal: SideshowReveal{
				Reason:       reason,
				PackedUserID: loser.userID,
				Hands: []SideshowHand{
					{UserID: asker.userID, DisplayName: asker.displayName, Cards: CardCodes(asker.cards), HandName: a.Name},
					{UserID: asked.userID, DisplayName: asked.displayName, Cards: CardCodes(asked.cards), HandName: b.Name},
				},
			},
		})

		// Only the asker holds the turn, so only their packing moves it on.
		t.pack(loser, PackReasonSideshow, loser == asker)
	}

	t.listener.OnSideshowResolved(t.view, SideshowResolvedEvent{
		FromUserID:   pending.fromUserID,
		ToUserID:     pending.toUserID,
		Accepted:     accepted,
		Reason:       reason,
		PackedUserID: packedUserID,
	})

	// The hand may have ended with that pack; if it is still running, the
	// asker gets their turn back with a full clock.
	if t.hand != nil && t.hand.turnSeat == pending.fromSeat && asker != nil && asker.status == SeatActive {
		t.setTurn(pending.fromSeat, false)
	}

	t.emitState()
	return SideshowOutcome{Accepted: accepted, PackedUserID: packedUserID}, true
}

// show (_show) pays for a show and resolves it — see Act.
func (t *Table) show(s *seat, actionID string) (ActResult, error) {
	active := t.activeSeats()
	if len(active) != 2 {
		return ActResult{}, NewGameError(CodeShowUnavailable, MsgShowUnavailable)
	}

	cost := t.showCost(s)
	// A show is paid for. No affordable chaal means no show either — never a
	// free look at the other hand.
	if cost == nil || s.chips < *cost {
		return ActResult{}, NewGameError(CodeInsufficientChips, MsgInsufficientForShow)
	}

	if err := t.chargeToPot(s, *cost, actionID, LedgerReasonShow); err != nil {
		return ActResult{}, err
	}
	t.hand.showRequestedBy = StrPtr(s.userID)

	// Paying for a show commits chips beyond the boot, so it counts as having
	// played the hand just as a chaal does (requirement 16).
	if entry := t.hand.contributions[s.userID]; entry != nil {
		entry.didChaal = true
	}

	t.listener.OnAction(t.view, ActionEvent{
		UserID: s.userID,
		Action: ActionShow,
		Amount: *cost,
		Pot:    t.hand.pot,
		Stake:  t.hand.stake,
	})

	t.clearTurnTimer()
	t.resolveShowdown(active, WinShow, StrPtr(s.userID))
	return ActResult{Action: string(ActionShow), Amount: Int64Ptr(*cost)}, nil
}

// forcedShowdown (_forcedShowdown): round cap reached — everyone still in
// reveals and the best hand takes it.
func (t *Table) forcedShowdown() {
	t.clearTurnTimer()
	t.resolveShowdown(t.activeSeats(), WinForcedShowdown, nil)
}

// resolveShowdown (_resolveShowdown): state showdown; score contenders;
// preference for exact ties = contenders sorted by distance(dealerSeat,
// seatIndex) ascending, minus showRequestedBy, who is appended LAST (the
// show-payer loses a tie); pick best (first max, ties broken by preference
// index); reveals for every contender {won}; emit showdown; losers → status
// lost + syncContribution; endHand(best, reason, reveals). The pot is never
// split.
func (t *Table) resolveShowdown(contenders []*seat, reason WinReason, showRequestedBy *string) {
	if t.hand == nil || len(contenders) == 0 {
		return
	}
	t.setState(TableShowdown)

	type scoredSeat struct {
		seat *seat
		hand EvaluatedHand
	}
	scored := make([]scoredSeat, 0, len(contenders))
	for _, s := range contenders {
		scored = append(scored, scoredSeat{seat: s, hand: Evaluate(s.cards, EvaluateOptions{})})
	}

	// Preference order for exact ties: the dealer's own seat first (distance
	// 0), then the dealer's left, …; the show payer moved to the very end.
	byDealer := make([]*seat, len(contenders))
	copy(byDealer, contenders)
	sort.SliceStable(byDealer, func(i, j int) bool {
		return t.distance(t.dealerSeat, byDealer[i].seatIndex) < t.distance(t.dealerSeat, byDealer[j].seatIndex)
	})
	preference := make([]string, 0, len(byDealer)+1)
	for _, s := range byDealer {
		if showRequestedBy != nil && s.userID == *showRequestedBy {
			continue
		}
		preference = append(preference, s.userID)
	}
	if showRequestedBy != nil {
		preference = append(preference, *showRequestedBy)
	}
	rank := func(userID string) int {
		for i, id := range preference {
			if id == userID {
				return i
			}
		}
		return -1
	}

	best := scored[0]
	tied := []scoredSeat{best}
	for _, candidate := range scored[1:] {
		diff := Compare(candidate.hand, best.hand)
		if diff > 0 {
			best = candidate
			tied = []scoredSeat{candidate}
		} else if diff == 0 {
			tied = append(tied, candidate)
		}
	}
	if len(tied) > 1 {
		sort.SliceStable(tied, func(i, j int) bool {
			return rank(tied[i].seat.userID) < rank(tied[j].seat.userID)
		})
		best = tied[0]
	}

	reveals := make([]Reveal, 0, len(scored))
	for _, entry := range scored {
		reveals = append(reveals, Reveal{
			UserID:    entry.seat.userID,
			SeatIndex: entry.seat.seatIndex,
			Cards:     entry.hand.Cards,
			HandName:  entry.hand.Name,
			Category:  entry.hand.Category,
			Won:       entry.seat.userID == best.seat.userID,
		})
	}

	t.listener.OnShowdown(t.view, ShowdownEvent{Reveals: reveals, Reason: reason})

	for _, entry := range scored {
		if entry.seat.userID != best.seat.userID {
			entry.seat.status = SeatLost
			t.syncContribution(entry.seat, SeatLost)
		}
	}

	t.endHand(StrPtr(best.seat.userID), reason, reveals)
}

// ------------------------------------------------------------- hand end

// endHand (_endHand) settles: CHECKPOINT 3 of 3 — THE HAND END, the one that
// resolves everybody still at the table.
//
// clearTurnTimer; stop the sideshow timer; endedAt = now; the winner's seat
// takes the pot IN MEMORY (the live state is the truth for a stack), then one
// SettleEntry per player still at the table — packers included, because their
// outcome row and its counters belong here even though their money moved at
// the pack — plus the winner when they have already left (ALL_LEFT), whose
// pot would otherwise be credited to nobody.
//
//	delta   = contribution.chips − contribution.chipsWritten
//	reason  = hand_win for the winner, hand_loss for everyone else
//	Outcome = true: this is the row that carries hands_played / hands_won /
//	          hands_lost / total_winnings / biggest_pot
//
// A packer's delta is zero here (their pack checkpoint already moved it), so
// the money moves once and the row records only the outcome — exactly what a
// losing player's row has always been. A player who LEFT is not written here:
// their leave checkpoint resolved them and counted hands_left_mid.
//
// On failure the hand is over anyway — memory is already right — and retrySettle re-sends the identical
// request until it lands; the per-entry action ids make that safe.
func (t *Table) endHand(winnerID *string, reason WinReason, reveals []Reveal) {
	h := t.hand
	if h == nil {
		return
	}
	if reveals == nil {
		reveals = []Reveal{}
	}

	t.clearTurnTimer()
	if h.sideshow != nil && h.sideshow.timer != nil {
		h.sideshow.timer.Stop()
	}
	h.sideshow = nil
	h.endedAt = t.clock.Now()

	var winnerSeat *seat
	if winnerID != nil {
		winnerSeat = t.findSeat(*winnerID)
	}
	if winnerSeat != nil {
		winnerSeat.status = SeatWon
		// The pot is paid in memory first: the live state is what the
		// checkpoint below writes through.
		winnerSeat.chips += h.pot
		t.syncContribution(winnerSeat, SeatWon)
	} else if winnerID != nil {
		// The winner has already left. Their leave checkpoint took their
		// stake; the pot still has to reach them, so their contribution is
		// credited and written even though they have no seat.
		if entry := h.contributions[*winnerID]; entry != nil {
			entry.status = SeatWon
			entry.chips += h.pot
		}
	}

	// Everyone who put chips in this hand, in the order they joined it.
	contributors := make([]*contribution, 0, len(h.contribOrder))
	for _, userID := range h.contribOrder {
		if entry := h.contributions[userID]; entry != nil && entry.contributed > 0 {
			contributors = append(contributors, entry)
		}
	}

	entries := make([]SettleEntry, 0, len(contributors))
	for _, entry := range contributors {
		isWinner := winnerID != nil && entry.userID == *winnerID
		if entry.leftMidHand && !isWinner {
			// Resolved at their own checkpoint when they walked out.
			continue
		}
		rowReason := LedgerReasonHandLoss
		if isWinner {
			rowReason = LedgerReasonHandWin
		}
		var pot int64
		if isWinner {
			pot = h.pot
		}
		entries = append(entries, SettleEntry{
			UserID:      entry.userID,
			Delta:       entry.chips - entry.chipsWritten,
			ActionID:    SettleActionID(h.id, entry.userID),
			Reason:      rowReason,
			Outcome:     true,
			IsWinner:    isWinner,
			DidChaal:    entry.didChaal,
			LeftMidHand: entry.leftMidHand,
			Pot:         pot,
		})
	}

	revealed := make(map[string]bool, len(reveals))
	for _, reveal := range reveals {
		revealed[reveal.UserID] = true
	}
	summary := make([]HandSummaryEntry, 0, len(contributors))
	for _, entry := range contributors {
		var cards []string
		if revealed[entry.userID] {
			cards = CardCodes(entry.cards)
		}
		summary = append(summary, HandSummaryEntry{
			UserID:      entry.userID,
			DisplayName: entry.displayName,
			SeatIndex:   entry.seatIndex,
			Contributed: entry.contributed,
			Status:      entry.status,
			SawCards:    entry.sawCards,
			Cards:       cards,
		})
	}

	// The hand is over whatever the database says next: the pot is already at
	// the winner's seat and every stack is final. The write only makes the
	// wallets agree.
	settleReq := SettleRequest{RoomID: t.id, HandID: h.id, Entries: entries}
	_, err := t.ledger.Settle(t.ctx, settleReq)
	if err != nil {
		t.listener.OnPersistError(t.view, PersistErrorEvent{Reason: "settle", HandID: h.id, Err: err})
		// Keep trying — the write is idempotent (per-player action ids), so a
		// late success moves each wallet exactly once. chipsWritten is NOT
		// advanced, so if the retries are abandoned the next checkpoint for
		// that player still carries this hand's delta.
		t.retrySettle(settleReq, 1)
	} else {
		t.version.Add(1)
		for _, entry := range contributors {
			entry.chipsWritten = entry.chips
		}
	}

	var winnerName *string
	if winnerSeat != nil {
		winnerName = StrPtr(winnerSeat.displayName)
	} else if winnerID != nil {
		if entry := h.contributions[*winnerID]; entry != nil {
			winnerName = StrPtr(entry.displayName)
		}
	}

	t.setHand(nil)
	t.setState(TableWaiting)

	nextHandAt := t.clock.Now().Add(t.cfg.NextHandDelay)
	var wireWinner *string
	if winnerID != nil {
		wireWinner = StrPtr(*winnerID)
	}
	t.listener.OnHandEnded(t.view, HandEndedEvent{
		HandID:     h.id,
		HandNo:     h.handNo,
		WinnerID:   wireWinner,
		WinnerName: winnerName,
		Pot:        h.pot,
		Reason:     reason,
		Reveals:    reveals,
		Summary:    summary,
		NextHandAt: Millis(nextHandAt),
	})

	t.emitState()

	t.maybeStart()
}

// retrySettle (_retrySettle): if destroyed return. attempt > 10 → emit error
// (OnError) with "settlement of hand <id> failed after 10 attempts". delay =
// min(30s, NextHandDelay × attempt). AfterFunc(delay) → run(): Settle again;
// on success version++, adopt balances ONLY onto seats that are not active
// (a live stake is in play), emit state; on error emit
// persistError{settle_retry, attempt} and retrySettle(attempt+1). Unlike
// Node, the retry body runs ON the actor (Node ran it outside the queue and
// mutated seats concurrently — a bug the port does not copy).
//
// DECISIONS.md §2: a retry refused with duplicate_action means the write
// already landed (the per-player settle action ids are UNIQUE), so it counts
// as success and the chain stops.
//
// A retry the table no longer owns — Destroy ran first, or ran while the
// timer's callback was already on its way to the actor — is not dropped: the
// losers' stakes are already banked and the winner is still owed the pot, so
// the write continues off the actor in settleDetached (Node's `if
// (this._destroyed) return` silently orphaned the pot).
func (t *Table) retrySettle(req SettleRequest, attempt int) {
	if t.destroyed.Load() {
		t.settleDetached(req, attempt)
		return
	}
	if attempt > settleMaxAttempts {
		t.listener.OnError(t.view, fmt.Errorf("settlement of hand %s failed after %d attempts", req.HandID, settleMaxAttempts))
		return
	}

	t.retryGen++
	gen := t.retryGen
	entry := &settleRetry{req: req, attempt: attempt}
	t.retryTimers[gen] = entry
	entry.timer = t.clock.AfterFunc(t.settleRetryDelay(attempt), func() {
		err := t.run(func() {
			delete(t.retryTimers, gen)
			balances, err := t.ledger.Settle(t.ctx, req)
			if err != nil && CodeOf(err, "") != CodeDuplicateAction {
				t.listener.OnPersistError(t.view, PersistErrorEvent{Reason: "settle_retry", HandID: req.HandID, Attempt: attempt, Err: err})
				t.retrySettle(req, attempt+1)
				return
			}
			t.version.Add(1)
			for userID, balance := range balances {
				s := t.findSeat(userID)
				// Only correct a seat that is not mid-hand; a live stake is in play.
				if s != nil && s.status != SeatActive {
					s.chips = balance
				}
			}
			t.emitState()
		})
		if errors.Is(err, ErrTableDestroyed) {
			// The timer fired in the same instant destroy() was tearing the
			// table down: Stop() reported "already fired" to destroy, so the
			// chain is ours to run. Whichever of us got to the entry first
			// counted it (claimDetached); it is counted once either way.
			t.claimDetached(entry)
			t.settleDetachedFrom(req, attempt)
		}
	})
}

// settleRetryDelay is min(30s, NextHandDelay × attempt) — Node's back-off.
func (t *Table) settleRetryDelay(attempt int) time.Duration {
	delay := t.cfg.NextHandDelay * time.Duration(attempt)
	if delay > settleRetryMaxDelay || delay < 0 {
		delay = settleRetryMaxDelay
	}
	return delay
}

// settleDetached keeps retrying a settlement whose table has been destroyed
// (Go addition; see retrySettle). It runs entirely off the actor: there are
// no seats to correct, no state to broadcast and — Destroy's contract — no
// Listener event is ever delivered again; the outcome is reported to whoever
// calls WaitSettlements instead. Only the idempotent write itself remains,
// with the same back-off, attempt numbering and cap as retrySettle, and a
// context that outlives the table's. A landed write still counts in Version.
func (t *Table) settleDetached(req SettleRequest, attempt int) {
	t.detachedMu.Lock()
	t.detachedOpen++
	t.detachedMu.Unlock()
	t.settleDetachedFrom(req, attempt)
}

// settleDetachedFrom is one link of a settleDetached chain; the chain was
// counted in detachedOpen once, by whoever started it, and is released here
// when it lands or is abandoned.
func (t *Table) settleDetachedFrom(req SettleRequest, attempt int) {
	if attempt > settleMaxAttempts {
		t.finishDetached(req.HandID, false)
		return
	}
	t.clock.AfterFunc(t.settleRetryDelay(attempt), func() {
		_, err := t.ledger.Settle(context.WithoutCancel(t.ctx), req)
		if err != nil && CodeOf(err, "") != CodeDuplicateAction {
			t.settleDetachedFrom(req, attempt+1)
			return
		}
		t.version.Add(1)
		t.finishDetached(req.HandID, true)
	})
}

// finishDetached records a chain's outcome and wakes WaitSettlements.
func (t *Table) finishDetached(handID string, landed bool) {
	t.detachedMu.Lock()
	if landed {
		t.landed = append(t.landed, handID)
	} else {
		t.abandoned = append(t.abandoned, handID)
	}
	t.detachedOpen--
	t.detachedDone.Broadcast()
	t.detachedMu.Unlock()
}

// PendingSettlements reports how many settlements are still being retried
// off the actor after Destroy (0 before Destroy, and 0 once every one has
// landed or been abandoned).
func (t *Table) PendingSettlements() int {
	t.detachedMu.Lock()
	defer t.detachedMu.Unlock()
	return t.detachedOpen
}

// WaitSettlements blocks until every settlement still being retried after
// Destroy has landed or been abandoned, or ctx expires (ctx.Err()). It then
// reports the hands whose settlement was abandoned after settleMaxAttempts as
// an error naming them, or nil when everything landed. Before Destroy it
// returns at once. RoomManager.Shutdown calls it so a process does not exit
// with a winner's pot still unbanked while the database is merely slow;
// RoomManager.destroyTable logs its result.
func (t *Table) WaitSettlements(ctx context.Context) error {
	done := make(chan struct{})
	go func() {
		t.detachedMu.Lock()
		for t.detachedOpen > 0 {
			t.detachedDone.Wait()
		}
		t.detachedMu.Unlock()
		close(done)
	}()
	select {
	case <-done:
	case <-ctx.Done():
		return ctx.Err()
	}
	t.detachedMu.Lock()
	defer t.detachedMu.Unlock()
	if len(t.abandoned) == 0 {
		return nil
	}
	return fmt.Errorf("settlement of hand(s) %s abandoned after %d attempts each", strings.Join(t.abandoned, ", "), settleMaxAttempts)
}

// SettlementsLanded returns the hand ids whose settlement landed only after
// Destroy (for logs and tests).
func (t *Table) SettlementsLanded() []string {
	t.detachedMu.Lock()
	defer t.detachedMu.Unlock()
	return append([]string(nil), t.landed...)
}

// destroy (_destroy) — see Destroy.
func (t *Table) destroy() {
	fenced := t.fenced.Load()
	if t.hand != nil && !fenced {
		remaining := t.activeSeats()
		var winnerID *string
		if len(remaining) > 0 {
			winnerID = StrPtr(remaining[0].userID)
		} else if t.hand.lastDeparture != nil {
			winnerID = StrPtr(*t.hand.lastDeparture)
		}
		t.endHand(winnerID, WinAllLeft, []Reveal{})
	}

	t.destroyed.Store(true)
	t.clearTurnTimer()
	t.clearStartTimer()
	t.clearUnfundedTimer()
	if t.hand != nil && t.hand.sideshow != nil && t.hand.sideshow.timer != nil {
		// Only reachable when fenced (endHand clears it otherwise): the hand
		// is the owner's now, this process just stops its own clocks.
		t.hand.sideshow.timer.Stop()
		t.hand.sideshow.timer = nil
	}
	// A settlement the database has not accepted yet is still owed whatever
	// happens to the table: every stopped retry continues off the actor. A
	// timer that had already fired is left to its own callback, which finds
	// the table destroyed and does the same.
	for gen, entry := range t.retryTimers {
		delete(t.retryTimers, gen)
		stopped := entry.timer.Stop()
		// Counted here, before Destroy returns, so a WaitSettlements that
		// starts the moment it does cannot miss the chain — even one whose
		// timer had already fired and whose callback is on its way to run()
		// to be told ErrTableDestroyed; that callback then runs the chain.
		t.claimDetached(entry)
		if stopped {
			t.settleDetachedFrom(entry.req, entry.attempt)
		}
	}
	// The room is gone, and so is its chat: history exists only for as long as
	// the room does. The live store's copy goes with it — unless another
	// process owns the table, in which case the copy is theirs.
	t.chat.Clear()
	if !fenced {
		t.liveDelete()
	}
	t.liveDirty = false
	t.cancel()
}

// ------------------------------------------------------------ snapshots

// snapshot builds the full server-side Snapshot from the actor state — what
// the live store holds (see Snapshot). Every field RestoreTable reads is
// here; the pair is an identity (TestSnapshotRoundTripIsLossless). Node's
// _snapshot rendered a hand "as it will be" for the ledger's game_states
// write; PostgreSQL holds no game state at all now, so the snapshot is
// always the table as it is, and it only ever goes to the live store.
func (t *Table) snapshot() *Snapshot {
	seats := make([]*SnapshotSeat, len(t.seats))
	for index, s := range t.seats {
		if s == nil {
			continue
		}
		snap := &SnapshotSeat{
			SeatIndex:             index,
			UserID:                s.userID,
			DisplayName:           s.displayName,
			Chips:                 s.chips,
			Status:                s.status,
			IsBlind:               s.isBlind,
			BlindMoves:            s.blindMoves,
			Contributed:           s.contributed,
			Cards:                 CardCodes(s.cards),
			LastBet:               s.lastBet,
			MissedTurns:           s.missedTurns,
			SideshowAskedThisTurn: s.sideshowAskedThisTurn,
			KickPending:           s.kickPending,
			JoinedAt:              Millis(s.joinedAt),
		}
		if s.unfundedUntil != nil {
			snap.UnfundedUntil = Int64Ptr(Millis(*s.unfundedUntil))
		}
		if s.avatarURL != nil {
			snap.AvatarURL = StrPtr(*s.avatarURL)
		}
		if s.lastAction != nil {
			snap.LastAction = ActionPtr(*s.lastAction)
		}
		seats[index] = snap
	}

	state := t.State()
	if t.hand != nil {
		state = TableBetting
	}

	var snapHand *SnapshotHand
	if h := t.hand; h != nil {
		contributions := make([]SnapshotContribution, 0, len(h.contribOrder))
		for _, userID := range h.contribOrder {
			entry := h.contributions[userID]
			if entry == nil {
				continue
			}
			contributions = append(contributions, SnapshotContribution{
				UserID:       entry.userID,
				Contributed:  entry.contributed,
				Status:       entry.status,
				DidChaal:     entry.didChaal,
				LeftMidHand:  entry.leftMidHand,
				DisplayName:  entry.displayName,
				SeatIndex:    entry.seatIndex,
				SawCards:     entry.sawCards,
				Cards:        CardCodes(entry.cards),
				Chips:        entry.chips,
				ChipsWritten: entry.chipsWritten,
			})
		}
		packed := make([]string, 0, len(h.packedUserIDs))
		for userID := range h.packedUserIDs {
			packed = append(packed, userID)
		}
		sort.Strings(packed)
		actionIDs := make([]string, 0, len(h.actionIDs))
		for id := range h.actionIDs {
			actionIDs = append(actionIDs, id)
		}
		sort.Strings(actionIDs)
		seatOrder := make([]int, len(h.seatOrder))
		copy(seatOrder, h.seatOrder)
		snapHand = &SnapshotHand{
			ID:            h.id,
			HandNo:        h.handNo,
			Pot:           h.pot,
			Stake:         h.stake,
			Round:         h.round,
			TurnSeat:      h.turnSeat,
			StartSeat:     h.startSeat,
			StartedAt:     Millis(h.startedAt),
			Contributions: contributions,
			PackedUserIDs: packed,
			SeatOrder:     seatOrder,
			ActionIDs:     actionIDs,
		}
		if h.showRequestedBy != nil {
			snapHand.ShowRequestedBy = StrPtr(*h.showRequestedBy)
		}
		if h.lastDeparture != nil {
			snapHand.LastDeparture = StrPtr(*h.lastDeparture)
		}
		if !h.turnDeadline.IsZero() {
			snapHand.TurnDeadline = Int64Ptr(Millis(h.turnDeadline))
		}
		if p := h.sideshow; p != nil {
			snapHand.Sideshow = &SnapshotSideshow{
				FromUserID: p.fromUserID,
				FromSeat:   p.fromSeat,
				ToUserID:   p.toUserID,
				ToSeat:     p.toSeat,
				ExpiresAt:  Millis(p.expiresAt),
			}
		}
	}

	snap := &Snapshot{
		RoomID:     t.id,
		Code:       t.code,
		Category:   t.cfg.Category,
		State:      state,
		HandNo:     t.handNo,
		DealerSeat: t.dealerSeat,
		Hand:       snapHand,
		Seats:      seats,
		Seq:        t.liveSeq.Load(),
		Version:    t.version.Load(),
		IsPrivate:  t.isPrivate,
		CreatedAt:  Millis(t.createdAt),
		Config:     snapshotConfig(t.cfg),
	}
	if t.startsAt != nil {
		snap.StartsAt = Int64Ptr(Millis(*t.startsAt))
	}
	return snap
}

// snapshotConfig renders TableConfig for the store (durations in ms).
func snapshotConfig(cfg TableConfig) SnapshotConfig {
	return SnapshotConfig{
		Category:           cfg.Category,
		BootAmount:         cfg.BootAmount,
		MaxPlayers:         cfg.MaxPlayers,
		MinPlayers:         cfg.MinPlayers,
		TurnTimeoutMs:      cfg.TurnTimeout.Milliseconds(),
		MaxBetRounds:       cfg.MaxBetRounds,
		PotLimitMultiplier: cfg.PotLimitMultiplier,
		MaxRaiseSteps:      cfg.MaxRaiseSteps,
		MaxPot:             cfg.MaxPot,
		MaxBlindMoves:      cfg.MaxBlindMoves,
		MaxMissedTurns:     cfg.MaxMissedTurns,
		SideshowTimeoutMs:  cfg.SideshowTimeout.Milliseconds(),
		SideshowMinPlayers: cfg.SideshowMinPlayers,
		NextHandDelayMs:    cfg.NextHandDelay.Milliseconds(),
		UnfundedGraceMs:    cfg.UnfundedGrace.Milliseconds(),
		ChatMaxHistory:     cfg.ChatMaxHistory,
		ChatMaxLength:      cfg.ChatMaxLength,
	}
}

// tableConfigFrom is the inverse of snapshotConfig.
func tableConfigFrom(c SnapshotConfig) TableConfig {
	return TableConfig{
		Category:           c.Category,
		BootAmount:         c.BootAmount,
		MaxPlayers:         c.MaxPlayers,
		MinPlayers:         c.MinPlayers,
		TurnTimeout:        time.Duration(c.TurnTimeoutMs) * time.Millisecond,
		MaxBetRounds:       c.MaxBetRounds,
		PotLimitMultiplier: c.PotLimitMultiplier,
		MaxRaiseSteps:      c.MaxRaiseSteps,
		MaxPot:             c.MaxPot,
		MaxBlindMoves:      c.MaxBlindMoves,
		MaxMissedTurns:     c.MaxMissedTurns,
		SideshowTimeout:    time.Duration(c.SideshowTimeoutMs) * time.Millisecond,
		SideshowMinPlayers: c.SideshowMinPlayers,
		NextHandDelay:      time.Duration(c.NextHandDelayMs) * time.Millisecond,
		UnfundedGrace:      time.Duration(c.UnfundedGraceMs) * time.Millisecond,
		ChatMaxHistory:     c.ChatMaxHistory,
		ChatMaxLength:      c.ChatMaxLength,
	}
}

// ------------------------------------------------------------ serializing

// serializeFor (serializeFor) builds the TableView for one viewer — see
// TableView's doc for every redaction rule. Cards are only ever included for
// the viewer themselves, and only once they have seen them, so a tampered
// client cannot read anyone else's hand.
func (t *Table) serializeFor(viewerID string) *TableView {
	viewer := t.findSeat(viewerID)

	// On a blind table another player's stack is never put on the wire, so it
	// cannot be read out of a tampered client. Your own is always sent.
	hideOthersChips := t.cfg.Category == CategoryBlind

	view := &TableView{
		RoomID:        t.id,
		Code:          t.code,
		Category:      t.cfg.Category,
		ChipsHidden:   hideOthersChips,
		State:         t.State(),
		HandNo:        t.handNo,
		DealerSeat:    t.dealerSeat,
		MaxPlayers:    t.cfg.MaxPlayers,
		MinPlayers:    t.cfg.MinPlayers,
		BootAmount:    t.cfg.BootAmount,
		TurnTimeoutMs: t.cfg.TurnTimeout.Milliseconds(),
		MaxPot:        t.cfg.MaxPot,
		Stake:         t.cfg.BootAmount,
	}
	if t.startsAt != nil {
		view.StartsAt = Int64Ptr(Millis(*t.startsAt))
	}
	if h := t.hand; h != nil {
		view.Pot = h.pot
		view.Stake = h.stake
		view.Round = h.round
		// The sideshow currently awaiting an answer. Public — who asked whom
		// and how long is left, never the cards — so a client that reconnects
		// mid-request can put the prompt back up.
		if h.sideshow != nil {
			view.Sideshow = &SideshowView{
				FromUserID: h.sideshow.fromUserID,
				FromSeat:   h.sideshow.fromSeat,
				ToUserID:   h.sideshow.toUserID,
				ToSeat:     h.sideshow.toSeat,
				ExpiresAt:  Millis(h.sideshow.expiresAt),
			}
		}
		turn := &TurnView{SeatIndex: h.turnSeat}
		if h.turnSeat >= 0 && h.turnSeat < len(t.seats) {
			if s := t.seats[h.turnSeat]; s != nil {
				turn.UserID = StrPtr(s.userID)
			}
		}
		if !h.turnDeadline.IsZero() {
			turn.Deadline = Int64Ptr(Millis(h.turnDeadline))
		}
		view.Turn = turn
	}

	if viewer != nil {
		you := &YouView{
			SeatIndex:      viewer.seatIndex,
			Chips:          viewer.chips,
			Status:         viewer.status,
			IsBlind:        viewer.isBlind,
			Contributed:    viewer.contributed,
			MissedTurns:    viewer.missedTurns,
			MaxMissedTurns: t.cfg.MaxMissedTurns,
			Cards:          []string{},
		}
		if viewer.unfundedUntil != nil && !viewer.kickPending {
			you.UnfundedDeadline = Int64Ptr(Millis(*viewer.unfundedUntil))
		}
		// Blind bets still allowed before the cards turn face up.
		if viewer.isBlind {
			you.BlindMovesLeft = max(0, t.cfg.MaxBlindMoves-viewer.blindMoves)
		} else {
			you.Cards = CardCodes(viewer.cards)
		}
		if t.hand != nil && t.hand.turnSeat == viewer.seatIndex && viewer.status == SeatActive {
			options := t.turnOptions(viewer)
			you.Options = &options
		}
		view.You = you
	}

	view.Seats = make([]SeatView, len(t.seats))
	for index, s := range t.seats {
		if s == nil {
			view.Seats[index] = SeatView{Empty: true, SeatIndex: index, Status: SeatEmpty}
			continue
		}
		isViewer := s.userID == viewerID
		entry := SeatView{
			SeatIndex:   index,
			UserID:      s.userID,
			DisplayName: s.displayName,
			Status:      s.status,
			IsBlind:     s.isBlind,
			// What a player has staked this hand stays public either way: bets
			// are announced as they happen, so hiding it here would fool nobody.
			// The same goes for the last one on its own.
			LastBet:     s.lastBet,
			Contributed: s.contributed,
			Connected:   s.connected,
			CardCount:   len(s.cards),
		}
		if s.avatarURL != nil {
			entry.AvatarURL = StrPtr(*s.avatarURL)
		}
		// Null rather than 0, so the client shows "hidden" instead of "broke".
		if !hideOthersChips || isViewer {
			entry.Chips = Int64Ptr(s.chips)
		}
		if s.lastAction != nil {
			entry.LastAction = ActionPtr(*s.lastAction)
		}
		view.Seats[index] = entry
	}
	return view
}

// summary (summary): lightweight row for the lobby list.
func (t *Table) summary() TableSummary {
	var pot int64
	if t.hand != nil {
		pot = t.hand.pot
	}
	return TableSummary{
		RoomID:     t.id,
		Code:       t.code,
		Category:   t.cfg.Category,
		State:      t.State(),
		Players:    len(t.occupiedSeats()),
		MaxPlayers: t.cfg.MaxPlayers,
		BootAmount: t.cfg.BootAmount,
		Pot:        pot,
	}
}

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
func (v *View) Seats() []SeatInfo { return v.t.seatInfos() }

// FindSeat returns a copy of the user's seat or nil.
func (v *View) FindSeat(userID string) *SeatInfo {
	if s := v.t.findSeat(userID); s != nil {
		return s.info()
	}
	return nil
}

// ChatHistory returns the room log.
func (v *View) ChatHistory() []ChatMessage { return v.t.chat.History() }

// Summary is the lobby row.
func (v *View) Summary() TableSummary { return v.t.summary() }
