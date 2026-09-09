package game

import (
	"context"
	"errors"
	"fmt"
	"hash/fnv"
	"log/slog"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/live"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// Player is the account data a join needs (Node passed the whole publicUser;
// these are the four fields RoomManager/Table read). db.User.Player() builds it.
type Player struct {
	ID          string
	DisplayName string
	AvatarURL   *string
	Chips       int64
}

// LobbyOptions is RoomManager.lobbyOptions(): the menu the client renders
// verbatim. Sent in session:ready.config (spread), lobby:list.options and
// GET /api/rooms.options.
type LobbyOptions struct {
	// Categories is always ["seen","blind"] in that order.
	Categories []Category `json:"categories"`
	// Stakes is config.Game.TableStakes ([] when unrestricted — never null).
	Stakes []int64 `json:"stakes"`
	// Tables is the menu in display order.
	Tables []LobbyTableOption `json:"tables"`
	// Requirement 30.
	EntryCapBoot     int64  `json:"entryCapBoot"`
	EntryCapCategory string `json:"entryCapCategory"`
	EntryCapMaxChips int64  `json:"entryCapMaxChips"`
	// Requirement 22.
	PrivateBoot   int64 `json:"privateBoot"`
	PrivateMaxPot int64 `json:"privateMaxPot"`
}

// LobbyTableOption is one menu entry: the LobbyTable pair plus the rules a
// player wants before sitting down.
type LobbyTableOption struct {
	Category   string `json:"category"`
	BootAmount int64  `json:"bootAmount"`
	// MaxPot is SeenMaxPot for seen entries, 0 (uncapped) for blind.
	MaxPot        int64 `json:"maxPot"`
	MaxBlindMoves int   `json:"maxBlindMoves"`
}

// PlayerMove ← 'playerMoved' {userId, fromRoomId, toRoomId} (requirement 24).
type PlayerMove struct {
	UserID     string
	FromRoomID string
	ToRoomID   string
}

// PlayerKicked is delivered AFTER RoomManager.Leave(userId, reason) has
// succeeded for a Table kick (socket/index.js `table.on('kick')` body): the
// socket layer emits room:kicked {roomId, reason, message}, untracks the
// socket and re-broadcasts the table if it still exists.
type PlayerKicked struct {
	RoomID  string
	UserID  string
	Reason  string
	Message string
}

// RoomListener is the RoomManager's outward event surface (Node's
// EventEmitter events tableCreated / tableDestroyed / playerMoved, plus the
// kick completion). Methods are called from whichever goroutine performed
// the operation — for OnPlayerKicked that is a goroutine the RoomManager
// spawned. None of them is on a Table actor, so they MAY post to tables.
type RoomListener interface {
	// OnTableCreated: a table was opened (quick-join overflow, private room).
	// Node's socket layer used it to `wireTable`; the Go socket layer needs
	// nothing here because the Table's Listener is set at construction, but
	// it may use it to prime its per-room socket set.
	OnTableCreated(t *Table)
	// OnTableDestroyed: every viewer gets room:closed {roomId} and the
	// per-room socket set is dropped.
	OnTableDestroyed(roomID string)
	// OnPlayerMoved: consolidation moved a lone player; the socket layer
	// re-tracks the socket, SetConnected(true, socketId) on the target, sends
	// room:moved (no state), room:joined, chat:history, then broadcasts.
	OnPlayerMoved(m PlayerMove)
	// OnPlayerKicked: see PlayerKicked.
	OnPlayerKicked(k PlayerKicked)
}

// NopRoomListener is a no-op RoomListener to embed.
type NopRoomListener struct{}

func (NopRoomListener) OnTableCreated(*Table)       {}
func (NopRoomListener) OnTableDestroyed(string)     {}
func (NopRoomListener) OnPlayerMoved(PlayerMove)    {}
func (NopRoomListener) OnPlayerKicked(PlayerKicked) {}

var _ RoomListener = NopRoomListener{}

// Stats is rooms.stats(), spread into GET /health.
type Stats struct {
	Tables      int `json:"tables"`
	Players     int `json:"players"` // len(playerRooms)
	ActiveHands int `json:"activeHands"`
}

// CreateTableOptions ← createTable({bootAmount, isPrivate, category}).
type CreateTableOptions struct {
	// BootAmount 0 → config.Game.BootAmount (Node's `= config.game.bootAmount`
	// default for an undefined argument). Ignored (forced to PrivateBoot)
	// when IsPrivate.
	BootAmount int64
	IsPrivate  bool
	// Category is normalised: anything but "blind" is seen.
	Category string
}

// QuickJoinOptions ← quickJoin(user, {bootAmount, category}).
//
// BootAmount is validated AS GIVEN: the socket layer resolves the wire's
// null/absent bootAmount to config.Game.BootAmount before calling QuickJoin
// (DECISIONS.md §7), so a 0 here is a client that literally sent 0 and is
// refused with invalid_stake exactly as Node's `bootAmount <= 0` check did
// (stakes.test.js "a malformed stake is refused").
type QuickJoinOptions struct {
	BootAmount int64
	Category   string // normalised
}

// ListOptions ← listTables({includePrivate, category}).
type ListOptions struct {
	IncludePrivate bool
	// Category "" → all.
	Category Category
}

// SwitchResult ← switchTable's `{from, table}`. On an error return only From
// may be set (the table the player was — and after a restore still is —
// seated at).
type SwitchResult struct {
	From *Table
	To   *Table
}

// MetricsHooks lets the RoomManager feed the histogram Node observed from
// roomManager.js without importing the metrics package (which would create
// a cycle: metrics gauges read the RoomManager). May be zero.
type MetricsHooks struct {
	// ObserveCreation records game_creation_duration_seconds.
	ObserveCreation func(d time.Duration)
	// ObserveHandStart records game_hand_start_duration_seconds: how long
	// dealing a hand takes. It used to be timed around the boot transaction;
	// the deal writes nothing to PostgreSQL since 9 Sep 2026, so the table
	// times its own work instead.
	ObserveHandStart func(d time.Duration)
	// ObserveLiveError counts a failed live-store call made by the game
	// package (op is a LiveOp* name) — game_live_store_errors_total{op}. The
	// app may leave it nil when the store itself is wrapped with
	// live.WithHooks, which counts the same failures.
	ObserveLiveError func(op string, err error)
}

// RoomManagerOptions builds a RoomManager.
type RoomManagerOptions struct {
	// Game and Chat are the config sections roomManager.js reads
	// (config.game.*, config.chat.maxHistory/maxLength).
	Game config.GameConfig
	Chat config.ChatConfig
	// Ledger is handed to every Table. Production: db.Ledger. Tests: a
	// MemoryLedger. nil → NewMemoryLedger(LedgerHooks), which is Node's
	// `ledger ?? memoryLedger({settle, persistChips})` for a manager built
	// with the older test hooks.
	Ledger Ledger
	// LedgerHooks are the optional settle / persistChips hooks the default
	// MemoryLedger wraps when Ledger is nil. Ignored when Ledger is set.
	LedgerHooks MemoryLedgerHooks
	Clock       Clock // nil → RealClock{}
	// TableListener receives every Table's events (the socket layer). The
	// RoomManager wraps it (see tableHooks) so that it can act on OnKick,
	// OnPersistError and OnError itself, then forwards every call unchanged.
	// nil → NopListener.
	TableListener Listener
	// Listener receives room-level events. nil → NopRoomListener.
	Listener RoomListener
	Logger   *slog.Logger // nil → slog.Default()
	Metrics  MetricsHooks

	// Live is the live-state store (LIVE_STATE_PLAN.md): every table saves
	// its snapshot and chat there, the seat index is mirrored
	// (SetSeated/ClearSeated), public tables are published to the
	// matchmaking index, and Restore rebuilds the tables it holds. nil →
	// none of that happens (exactly the pre-Redis behaviour).
	Live live.Store
	// Instance tags this process in TableSummary.Instance (LIVE_INSTANCE_ID,
	// hostname:pid by default).
	Instance string
	// LiveTTL is the snapshot expiry handed to every table
	// (LIVE_STATE_TTL_MS); 0 → DefaultLiveTTL.
	LiveTTL time.Duration
}

// RoomManager owns every live table in this process (roomManager.js).
//
// # Locking (PORT_PLAN.md decision 5)
//
// mu protects ONLY tables, order, pending and playerRooms. It is NEVER held while
// calling into a Table (every Table method may block on the actor, which
// may be inside a Ledger write). Pattern for every method: lock → look up /
// decide → unlock → call the table → lock again to record the result if
// needed. Join/QuickJoin/JoinByCode RESERVE playerRooms[userId] = roomId
// under the lock BEFORE AddPlayer (so a concurrent second join is refused
// with already_in_room) and delete the reservation if AddPlayer fails.
//
// Table events that need the RoomManager (OnKick → Leave; a table emptied by
// a hand → destroy/sweep) are handled in a NEW goroutine, never on the
// actor, because Leave posts to the same table.
//
// # Per-player serialisation
//
// A seat transition (Join, Leave, a consolidation move, a switch) flips the
// index and then posts to a Table; two of them for the SAME player racing
// through that gap — a room:leave arriving while a sweep is moving that lone
// player, say — would leave a seat nobody is indexed for. Node's single
// thread made the gap unobservable; here every transition of one player
// holds that player's stripe in userLocks for its duration. Stripes are
// never nested and never held together with mu (mu is taken and released
// inside), so they cannot deadlock; a stripe is held across the Table call
// on purpose — it blocks only other transitions of the same (or a
// same-stripe) player, never the manager.
//
// All methods Node marked async are ordinary blocking methods here.
type RoomManager struct {
	game   config.GameConfig
	chat   config.ChatConfig
	ledger Ledger
	clock  Clock
	tl     Listener
	rl     RoomListener
	log    *slog.Logger
	mx     MetricsHooks
	hooks  *tableHooks

	mu          sync.Mutex
	tables      map[string]*Table // roomId → table
	playerRooms map[string]string // userId → roomId
	// order is roomId → creation sequence number. Node's Map iterated in
	// insertion order and its sorts were stable, so every "oldest" / "ties
	// to the earliest" rule fell out of creation order; Go maps do not
	// iterate deterministically and a fake clock can stamp two tables with
	// the same CreatedAt, so the order is recorded explicitly.
	order   map[string]uint64
	nextSeq uint64
	// pending is roomId → seats held by joins in flight (taken under mu when
	// a table is picked, released once AddPlayer has run). Candidate scans
	// and the full check count them, so fifty simultaneous quick-joins are
	// routed by the seats that will be taken, not the seats taken so far.
	pending map[string]int

	// userLocks serialises seat transitions per player (see the type doc).
	userLocks [userLockStripes]sync.Mutex

	sweeperOnce  sync.Once
	sweepMu      sync.Mutex
	sweepTimer   Timer
	sweepStopped bool

	// live-state store (nil → every live* helper is a no-op).
	live     live.Store
	instance string
	liveTTL  time.Duration
	// published is roomId → the (players, state) last pushed to the
	// matchmaking index, so tableHooks.OnState publishes only on a change.
	// Guarded by pubMu, never by mu (OnState runs on a table actor).
	pubMu     sync.Mutex
	published map[string]publishedSummary
	// restored is every seat Restore rebuilt (RestoredSeats), under mu.
	restored []RestoredSeat
}

// publishedSummary is what a table's last PublishTable said.
type publishedSummary struct {
	players int
	state   TableState
}

// Refusal messages verbatim from roomManager.js (the Table's live in
// errors.go; these are the RoomManager's own).
const (
	msgAlreadyInRoom      = "You are already seated at a table"
	msgInvalidStake       = "That stake is not valid"
	msgStakeMustBeOneOf   = "Stake must be one of: %s"
	msgLobbyOffers        = "The lobby offers: %s"
	msgInsufficientToJoin = "Not enough chips to join this table"
	msgRoomNotFound       = "No table with that code"
	msgThatTableFull      = "That table is full" // joinByCode; the Table's own is "This table is full"
	msgNotAtATable        = "You are not at a table"
	msgPrivateTableSwitch = "A private table cannot be swapped for another"
	msgNoOtherTableFormat = "No other %s table at this stake has a free seat right now"
	msgOverEntryCapFormat = "Players with more than %s chips cannot join this table"
	sweepEmptyTableMinAge = 30 * time.Second // roomManager.js sweepEmptyTables: Date.now() - 30_000, hardcoded
	userLockStripes       = 256
	quickJoinMaxRepicks   = 3
)

// userLock is the stripe serialising one player's seat transitions.
func (rm *RoomManager) userLock(userID string) *sync.Mutex {
	h := fnv.New32a()
	_, _ = h.Write([]byte(userID))
	return &rm.userLocks[h.Sum32()%userLockStripes]
}

// NewRoomManager builds the manager. It does NOT start the sweeper — call
// StartSweeper (the app does; unit tests usually do not).
func NewRoomManager(opts RoomManagerOptions) *RoomManager {
	clock := opts.Clock
	if clock == nil {
		clock = RealClock{}
	}
	ledger := opts.Ledger
	if ledger == nil {
		ledger = NewMemoryLedger(opts.LedgerHooks)
	}
	tl := opts.TableListener
	if tl == nil {
		tl = NopListener{}
	}
	rl := opts.Listener
	if rl == nil {
		rl = NopRoomListener{}
	}
	logger := opts.Logger
	if logger == nil {
		logger = slog.Default()
	}
	liveTTL := opts.LiveTTL
	if liveTTL <= 0 {
		liveTTL = DefaultLiveTTL
	}
	rm := &RoomManager{
		game:        opts.Game,
		chat:        opts.Chat,
		ledger:      ledger,
		clock:       clock,
		tl:          tl,
		rl:          rl,
		log:         logger,
		mx:          opts.Metrics,
		tables:      map[string]*Table{},
		playerRooms: map[string]string{},
		order:       map[string]uint64{},
		pending:     map[string]int{},
		live:        opts.Live,
		instance:    opts.Instance,
		liveTTL:     liveTTL,
		published:   map[string]publishedSummary{},
	}
	rm.hooks = &tableHooks{rm: rm}
	return rm
}

// StartSweeper runs ConsolidateTables then SweepEmptyTables every
// config.Game.ConsolidateInterval in a background goroutine until Shutdown
// (Node: unref'd setInterval in the constructor). Errors are logged as
// `table sweep failed`. Safe to call once.
//
// The interval is driven by the injected Clock (DECISIONS.md §3): with
// RealClock each tick runs on its own goroutine; with testclock.Fake a tick
// runs inside Advance. A non-positive interval disables the sweeper.
func (rm *RoomManager) StartSweeper() {
	rm.sweeperOnce.Do(func() {
		interval := rm.game.ConsolidateInterval
		if interval <= 0 {
			rm.log.Warn("table sweeper disabled", "consolidateIntervalMs", interval.Milliseconds())
			return
		}
		rm.armSweep(interval)
	})
}

// armSweep arms the next sweeper tick unless Shutdown has stopped it. Each
// tick re-arms itself, which is setInterval without a goroutine of its own.
func (rm *RoomManager) armSweep(interval time.Duration) {
	rm.sweepMu.Lock()
	defer rm.sweepMu.Unlock()
	if rm.sweepStopped {
		return
	}
	rm.sweepTimer = rm.clock.AfterFunc(interval, func() {
		rm.sweepTick()
		rm.armSweep(interval)
	})
}

// sweepTick is one interval body: consolidate, then sweep; a failure in the
// first skips the second, as Node's promise chain did.
func (rm *RoomManager) sweepTick() {
	if _, err := rm.ConsolidateTables(); err != nil {
		rm.log.Error("table sweep failed", "error", err.Error())
		return
	}
	if err := rm.SweepEmptyTables(); err != nil {
		rm.log.Error("table sweep failed", "error", err.Error())
	}
}

// stopSweeper is clearInterval(this._sweeper): no further tick is armed.
func (rm *RoomManager) stopSweeper() {
	rm.sweepMu.Lock()
	defer rm.sweepMu.Unlock()
	rm.sweepStopped = true
	if rm.sweepTimer != nil {
		rm.sweepTimer.Stop()
		rm.sweepTimer = nil
	}
}

// NormalizeCategory: "blind" → CategoryBlind; anything else → CategorySeen.
func NormalizeCategory(category string) Category {
	if category == string(CategoryBlind) {
		return CategoryBlind
	}
	return CategorySeen
}

// AssertStakeAllowed (static assertStakeAllowed): invalid_stake when boot ≤ 0
// ("That stake is not valid") or, with TableStakes non-empty, when boot is
// not in it ("Stake must be one of: 200, 5000").
func (rm *RoomManager) AssertStakeAllowed(bootAmount int64) error {
	if bootAmount <= 0 {
		return NewGameError(CodeInvalidStake, msgInvalidStake)
	}
	allowed := rm.game.TableStakes
	if len(allowed) == 0 {
		return nil
	}
	for _, stake := range allowed {
		if stake == bootAmount {
			return nil
		}
	}
	parts := make([]string, len(allowed))
	for i, stake := range allowed {
		parts[i] = strconv.FormatInt(stake, 10)
	}
	return Errorf(CodeInvalidStake, msgStakeMustBeOneOf, strings.Join(parts, ", "))
}

// AssertTableOffered (static assertTableOffered): with LobbyTables non-empty
// the (boot, category) PAIR must be on the menu, else table_not_offered
// ("The lobby offers: seen 200, blind 200, blind 5000").
func (rm *RoomManager) AssertTableOffered(bootAmount int64, category Category) error {
	offered := rm.game.LobbyTables
	if len(offered) == 0 {
		return nil
	}
	for _, entry := range offered {
		if entry.BootAmount == bootAmount && entry.Category == string(category) {
			return nil
		}
	}
	parts := make([]string, len(offered))
	for i, entry := range offered {
		parts[i] = entry.Category + " " + strconv.FormatInt(entry.BootAmount, 10)
	}
	return Errorf(CodeTableNotOffered, msgLobbyOffers, strings.Join(parts, ", "))
}

// CreateTable opens a table (createTable / _createTable), timed into
// Metrics.ObserveCreation. Rules (config.GameConfig.TableRules composes
// them exactly as Node's spreads did):
//
//   - boot = PrivateBoot when private (requirement 22: never chosen), else
//     opts.BootAmount or the default;
//   - seen → {MaxRaiseSteps: SeenMaxRaiseSteps, MaxBetRounds:
//     SeenMaxBetRounds, MaxPot: SeenMaxPot, PotLimitMultiplier: the generic
//     config.Game.PotLimitMultiplier} (requirement 19);
//   - blind → {MaxRaiseSteps: BlindMaxRaiseSteps, MaxBetRounds:
//     BlindMaxBetRounds, PotLimitMultiplier: BlindPotLimitMultiplier, MaxPot 0};
//   - private (either category) then overrides MaxPot = PrivateMaxPot and
//     MaxRaiseSteps = PrivateMaxRaiseSteps;
//   - the rest of TableConfig copies config.Game / config.Chat;
//   - id util.UUID(), code util.RoomCode(6) regenerated until unique among
//     live tables (DECISIONS.md §3), Listener = rm's tableHooks.
//
// Registers the table, calls RoomListener.OnTableCreated, logs `table
// created {roomId, code, bootAmount, category, isPrivate, maxPot}`.
func (rm *RoomManager) CreateTable(opts CreateTableOptions) *Table {
	started := time.Now()
	rm.mu.Lock()
	table := rm.newTableLocked(opts)
	rm.mu.Unlock()
	rm.announceCreated(table, started)
	return table
}

// newTableLocked is _createTable up to and including `tables.set`: builds
// the TableConfig, picks a code no live table uses, constructs the Table and
// registers it. mu held — the code is chosen and the table registered under
// one lock so two concurrent creations can never share a code, and a
// quick-join can register and take a seat in the same critical section.
// NewTable only allocates and starts the actor goroutine — it never posts to
// it — so holding mu across it does not break the "never call into a Table
// under mu" rule.
func (rm *RoomManager) newTableLocked(opts CreateTableOptions) *Table {
	g := rm.game
	resolved := NormalizeCategory(opts.Category)
	rules := g.TableRules(opts.Category, opts.BootAmount, opts.IsPrivate)

	cfg := TableConfig{
		Category:           resolved,
		BootAmount:         rules.BootAmount,
		MaxPlayers:         g.MaxPlayers,
		MinPlayers:         g.MinPlayers,
		TurnTimeout:        g.TurnTimeout,
		MaxBetRounds:       rules.MaxBetRounds,
		PotLimitMultiplier: rules.PotLimitMultiplier,
		MaxRaiseSteps:      rules.MaxRaiseSteps,
		MaxPot:             rules.MaxPot,
		MaxBlindMoves:      g.MaxBlindMoves,
		MaxMissedTurns:     g.MaxMissedTurns,
		SideshowTimeout:    g.SideshowTimeout,
		SideshowMinPlayers: g.SideshowMinPlayers,
		NextHandDelay:      g.NextHandDelay,
		ChatMaxHistory:     rm.chat.MaxHistory,
		ChatMaxLength:      rm.chat.MaxLength,
	}

	id := util.UUID()
	code := util.RoomCode(util.DefaultRoomCodeLength)
	for rm.codeTakenLocked(code) {
		code = util.RoomCode(util.DefaultRoomCodeLength)
	}
	table := NewTable(rm.tableOptions(TableOptions{
		ID:        id,
		Code:      code,
		Config:    cfg,
		IsPrivate: opts.IsPrivate,
	}))
	rm.nextSeq++
	rm.tables[id] = table
	rm.order[id] = rm.nextSeq
	return table
}

// tableOptions completes a table's options with everything every table of
// this manager shares: ledger, clock, the hooks Listener and the live store.
func (rm *RoomManager) tableOptions(opts TableOptions) TableOptions {
	opts.Ledger = rm.ledger
	opts.Clock = rm.clock
	opts.Listener = rm.hooks
	opts.Live = rm.live
	opts.LiveTTL = rm.liveTTL
	opts.LiveErrors = rm.liveErrorHook
	opts.ObserveHandStart = rm.mx.ObserveHandStart
	return opts
}

// announceCreated is the tail of _createTable, outside mu: emit
// tableCreated, log, observe the creation duration, publish to the index.
func (rm *RoomManager) announceCreated(table *Table, started time.Time) {
	rm.publishTable(table)
	rm.rl.OnTableCreated(table)
	var maxPot any // Node: `table.maxPot || null`
	if table.MaxPot() != 0 {
		maxPot = table.MaxPot()
	}
	rm.log.Info("table created",
		"roomId", table.ID(),
		"code", table.Code(),
		"bootAmount", table.BootAmount(),
		"category", string(table.Category()),
		"isPrivate", table.IsPrivate(),
		"maxPot", maxPot,
	)
	if rm.mx.ObserveCreation != nil {
		rm.mx.ObserveCreation(time.Since(started))
	}
}

// codeTakenLocked reports whether a live table already uses code. mu held.
func (rm *RoomManager) codeTakenLocked(code string) bool {
	for _, t := range rm.tables {
		if t.Code() == code {
			return true
		}
	}
	return false
}

// GetTable returns the table or nil.
func (rm *RoomManager) GetTable(roomID string) *Table {
	rm.mu.Lock()
	defer rm.mu.Unlock()
	return rm.tables[roomID]
}

// GetTableByCode matches the upper-cased code, or nil.
func (rm *RoomManager) GetTableByCode(code string) *Table {
	wanted := strings.ToUpper(code)
	rm.mu.Lock()
	defer rm.mu.Unlock()
	for _, t := range rm.tables {
		if t.Code() == wanted {
			return t
		}
	}
	return nil
}

// GetTableForPlayer returns the table the user is seated at (via
// playerRooms), or nil.
// CreditChips adds purchased chips to a player's seat, wherever they are
// sitting, and reports whether a seat was found.
//
// The mutex is released before the table is touched — RoomManager never holds
// its lock while calling a Table (PORT_PLAN.md §3.4), and CreditChips posts to
// that table's actor.
func (rm *RoomManager) CreditChips(userID string, amount int64) bool {
	t := rm.GetTableForPlayer(userID)
	if t == nil {
		return false
	}
	return t.CreditChips(userID, amount)
}

func (rm *RoomManager) GetTableForPlayer(userID string) *Table {
	rm.mu.Lock()
	t, dropped := rm.seatedTableLocked(userID)
	rm.mu.Unlock()
	if dropped {
		rm.liveClearSeated(userID)
	}
	return t
}

// seatedTableLocked is getTableForPlayer under mu: the table the index
// points at, or nil. An index entry naming a table that is no longer
// registered is stale (Node's getTable returned null for it too) and is
// dropped on sight so it cannot block a later join; `dropped` says so, and
// EVERY caller that leaves the player unseated must then clear the live
// store's mirror of that entry (liveClearSeated). Seat keys carry no ttl, so
// one dropped silently is one that stays in Redis for good — the
// `kt:seat:<userId>` leak found on production, 9 Sep 2026.
func (rm *RoomManager) seatedTableLocked(userID string) (t *Table, dropped bool) {
	roomID, ok := rm.playerRooms[userID]
	if !ok {
		return nil, false
	}
	t = rm.tables[roomID]
	if t == nil {
		delete(rm.playerRooms, userID)
		return nil, true
	}
	return t, false
}

// tablesLocked returns every registered table in creation order. mu held.
func (rm *RoomManager) tablesLocked() []*Table {
	out := make([]*Table, 0, len(rm.tables))
	for _, t := range rm.tables {
		out = append(out, t)
	}
	sort.Slice(out, func(i, j int) bool { return rm.order[out[i].ID()] < rm.order[out[j].ID()] })
	return out
}

// ListTables returns summaries of the (public unless IncludePrivate) tables,
// optionally filtered by category. Collects the *Table set under the lock,
// then calls Summary() on each OUTSIDE it.
func (rm *RoomManager) ListTables(opts ListOptions) []TableSummary {
	rm.mu.Lock()
	all := rm.tablesLocked()
	rm.mu.Unlock()

	out := make([]TableSummary, 0, len(all))
	for _, t := range all {
		if t.IsPrivate() && !opts.IncludePrivate {
			continue
		}
		if opts.Category != "" && t.Category() != opts.Category {
			continue
		}
		summary, err := t.Summary()
		if err != nil {
			// Destroyed between the snapshot and the read: it is no longer a
			// row the lobby should show.
			continue
		}
		out = append(out, summary)
	}
	return out
}

// LobbyOptions builds the menu from config (static lobbyOptions()).
func (rm *RoomManager) LobbyOptions() LobbyOptions {
	g := rm.game
	stakes := make([]int64, len(g.TableStakes))
	copy(stakes, g.TableStakes)

	// The rooms on the menu, in the order the lobby should show them. Each
	// carries the rules a player would want before sitting down, from the
	// same source the table is built from.
	tables := make([]LobbyTableOption, 0, len(g.LobbyTables))
	for _, entry := range g.LobbyTables {
		tables = append(tables, LobbyTableOption{
			Category:      entry.Category,
			BootAmount:    entry.BootAmount,
			MaxPot:        g.MenuMaxPot(entry.Category), // 0 means the pot is uncapped
			MaxBlindMoves: g.MaxBlindMoves,
		})
	}
	return LobbyOptions{
		Categories:       []Category{CategorySeen, CategoryBlind},
		Stakes:           stakes,
		Tables:           tables,
		EntryCapBoot:     g.EntryCapBoot,
		EntryCapCategory: g.EntryCapCategory,
		EntryCapMaxChips: g.EntryCapMaxChips,
		PrivateBoot:      g.PrivateBoot,
		PrivateMaxPot:    g.PrivateMaxPot,
	}
}

// LiveTables returns every table (for metric gauges: players online, active /
// waiting games, tables{category,stake}). The gauges read only lock-free
// getters on the result.
func (rm *RoomManager) LiveTables() []*Table {
	rm.mu.Lock()
	defer rm.mu.Unlock()
	return rm.tablesLocked()
}

// occupancyLocked is the seats taken plus the seats held by joins in flight
// — what the table will hold once every pending AddPlayer lands. mu held.
func (rm *RoomManager) occupancyLocked(t *Table) int {
	return t.PlayerCount() + rm.pending[t.ID()]
}

// fullLocked is IsFull counting held seats. mu held.
func (rm *RoomManager) fullLocked(t *Table) bool {
	return rm.occupancyLocked(t) >= t.Config().MaxPlayers
}

// holdLocked takes one seat on t for a join that is about to follow (mu
// held). Every hold is consumed by seatHeld or given back by
// releaseHoldLocked; the table's own AddPlayer is what actually seats.
func (rm *RoomManager) holdLocked(t *Table) { rm.pending[t.ID()]++ }

// releaseHoldLocked gives a held seat back. mu held.
func (rm *RoomManager) releaseHoldLocked(roomID string) {
	if rm.pending[roomID] <= 1 {
		delete(rm.pending, roomID)
	} else {
		rm.pending[roomID]--
	}
}

// releaseHold is releaseHoldLocked for callers not holding mu.
func (rm *RoomManager) releaseHold(roomID string) {
	rm.mu.Lock()
	rm.releaseHoldLocked(roomID)
	rm.mu.Unlock()
}

// pickTableLocked is the candidate scan quickJoin and switchTable share: the
// FULLEST public non-full table with the same boot AND category, excluding
// excludeID, ties to the earliest created (Node's stable sort over a Map in
// insertion order). Table state is not considered — a player may sit down
// mid-hand and wait for the next deal. nil when none. mu held; only
// lock-free getters are read.
func (rm *RoomManager) pickTableLocked(bootAmount int64, category Category, excludeID string) *Table {
	var best *Table
	var bestSeq uint64
	var bestOccupancy int
	for id, t := range rm.tables {
		if id == excludeID || t.IsPrivate() || rm.fullLocked(t) {
			continue
		}
		if t.BootAmount() != bootAmount || t.Category() != category {
			continue
		}
		seq, occupancy := rm.order[id], rm.occupancyLocked(t)
		if best == nil || occupancy > bestOccupancy || (occupancy == bestOccupancy && seq < bestSeq) {
			best, bestSeq, bestOccupancy = t, seq, occupancy
		}
	}
	return best
}

// QuickJoin (quickJoin) seats a player, creating a table if every one at the
// stake is full. Order of checks: already_in_room → AssertStakeAllowed →
// NormalizeCategory → AssertTableOffered → insufficient_chips (chips < boot,
// "Not enough chips to join this table") → entry cap. Candidate = the
// FULLEST public non-full table with the same boot AND category (ties: the
// earliest created), else CreateTable. Then Join.
//
// The pick (or creation) and the seat hold happen in one critical section,
// so fifty players quick-joining at the same instant are routed by the seats
// that will be taken and nobody is refused with table_full by a race Node's
// single thread could not have.
func (rm *RoomManager) QuickJoin(user Player, opts QuickJoinOptions) (*Table, error) {
	if err := rm.assertNotSeated(user.ID); err != nil {
		return nil, err
	}
	bootAmount := opts.BootAmount
	if err := rm.AssertStakeAllowed(bootAmount); err != nil {
		return nil, err
	}
	resolved := NormalizeCategory(opts.Category)
	if err := rm.AssertTableOffered(bootAmount, resolved); err != nil {
		return nil, err
	}
	if user.Chips < bootAmount {
		return nil, NewGameError(CodeInsufficientChips, msgInsufficientToJoin)
	}
	if err := rm.assertUnderEntryCap(user, bootAmount, resolved); err != nil {
		return nil, err
	}

	ul := rm.userLock(user.ID)
	ul.Lock()
	defer ul.Unlock()

	for attempt := 0; ; attempt++ {
		started := time.Now()
		rm.mu.Lock()
		if seated, _ := rm.seatedTableLocked(user.ID); seated != nil {
			rm.mu.Unlock()
			return nil, NewGameError(CodeAlreadyInRoom, msgAlreadyInRoom)
		}
		// A table only matches when both the stake and the category line up
		// — a blind table and a seen table at the same stake are different
		// rooms.
		table := rm.pickTableLocked(bootAmount, resolved, "")
		created := table == nil
		if created {
			table = rm.newTableLocked(CreateTableOptions{BootAmount: bootAmount, Category: string(resolved)})
		}
		rm.holdLocked(table)
		rm.mu.Unlock()

		if created {
			rm.announceCreated(table, started)
		}
		err := rm.seatHeld(table, user, "")
		if err == nil {
			return table, nil
		}
		if created {
			// Nobody is on the table that was opened for this join (unless a
			// concurrent quick-join has already claimed it); do not leave it
			// for the sweeper.
			_ = rm.destroyTable(table.ID(), true)
		} else if errors.Is(err, ErrTableDestroyed) && attempt < quickJoinMaxRepicks {
			// The table picked was torn down under us (a shutdown, or a
			// creator's failed join cleaning up its empty room): pick again.
			continue
		}
		return nil, err
	}
}

// JoinByCode (joinByCode): already_in_room → room_not_found ("No table with
// that code") → table_full ("That table is full") → insufficient_chips →
// entry cap (skipped for private tables: you were invited) → Join. Neither
// the stake list nor the menu is consulted: any live table can be joined by
// its code.
func (rm *RoomManager) JoinByCode(user Player, code string) (*Table, error) {
	if err := rm.assertNotSeated(user.ID); err != nil {
		return nil, err
	}
	table := rm.GetTableByCode(code)
	if table == nil {
		return nil, NewGameError(CodeRoomNotFound, msgRoomNotFound)
	}
	if table.IsFull() {
		return nil, NewGameError(CodeTableFull, msgThatTableFull)
	}
	if user.Chips < table.BootAmount() {
		return nil, NewGameError(CodeInsufficientChips, msgInsufficientToJoin)
	}
	// A private table is somewhere you were invited, so the cap does not apply.
	if !table.IsPrivate() {
		if err := rm.assertUnderEntryCap(user, table.BootAmount(), table.Category()); err != nil {
			return nil, err
		}
	}
	if err := rm.Join(table, user, ""); err != nil {
		return nil, err
	}
	return table, nil
}

// SwitchTable (switchTable) moves a seated player sideways: not_in_room if
// unseated; private_table if the current table is private; target = fullest
// OTHER public non-full table with the same boot and category, else
// no_other_table ("No other <category> table at this stake has a free seat
// right now"). The entry cap is deliberately NOT applied (requirement 30
// guards the lobby door only: a player already seated at a table of this
// stake and category was admitted under it, and the server — not the client
// — decides what a switch is). Then Leave(userId, "moved") — "moved" skips
// the consolidation sweep, and an emptied source is destroyed before the new
// seat is taken, as Node's awaited leave did — and Join(target). Every check
// happens BEFORE the seat is given up, and the target seat is held from the
// moment it is chosen so it cannot fill up in between. Should the join still
// be refused (the target was destroyed under us) the seat on the source
// table is restored (DECISIONS.md §3), or, when leaving emptied and
// destroyed the source, the error is returned and the caller finds the
// player unseated.
func (rm *RoomManager) SwitchTable(user Player) (SwitchResult, error) {
	ul := rm.userLock(user.ID)
	ul.Lock()
	defer ul.Unlock()

	rm.mu.Lock()
	current, dropped := rm.seatedTableLocked(user.ID)
	if current == nil {
		rm.mu.Unlock()
		if dropped {
			rm.liveClearSeated(user.ID)
		}
		return SwitchResult{}, NewGameError(CodeNotInRoom, msgNotAtATable)
	}
	if current.IsPrivate() {
		rm.mu.Unlock()
		return SwitchResult{From: current}, NewGameError(CodePrivateTable, msgPrivateTableSwitch)
	}
	bootAmount, category := current.BootAmount(), current.Category()
	target := rm.pickTableLocked(bootAmount, category, current.ID())
	if target == nil {
		rm.mu.Unlock()
		return SwitchResult{From: current}, Errorf(CodeNoOtherTable, msgNoOtherTableFormat, string(category))
	}
	rm.holdLocked(target)
	rm.mu.Unlock()

	// The seat's socket follows the player, and comes back with them if the
	// move has to be undone.
	socketID := ""
	if seat, err := current.FindSeat(user.ID); err == nil && seat != nil {
		socketID = seat.SocketID
	}

	// "moved" rather than "left", so the departure does not trigger a merge
	// of the table being left while the player is between seats.
	//
	// The seat comes back because the player has to be re-seated with what
	// they ACTUALLY hold. `user.Chips` was read from the wallet before this
	// line, and leaving mid-hand is a checkpoint: it has just written the
	// hand's losses through to PostgreSQL, so that figure is now stale by
	// exactly what they had staked. Re-seating on it handed the stake back at
	// the new table — the ledger was right and the seat was wrong, and the
	// gap then became the base for every later checkpoint, so it compounded
	// with each switch until a delta outran the wallet.
	_, vacated, err := rm.vacateSeat(user.ID, LeaveReasonMoved)
	if err != nil {
		rm.releaseHold(target.ID())
		return SwitchResult{From: current}, err
	}
	// The seat is the authority the moment it is given up: whatever it held is
	// what the checkpoint has just banked. Only fall back to the wallet read
	// if there was no seat to take chips from, which means nothing was staked.
	moving := user
	if vacated != nil {
		moving.Chips = vacated.Chips
	}
	if current.IsEmpty() {
		if err := rm.destroyTable(current.ID(), true); err != nil {
			rm.releaseHold(target.ID())
			return SwitchResult{From: current}, err
		}
	}
	if err := rm.seatHeld(target, moving, socketID); err != nil {
		if rerr := rm.seat(current, moving, socketID); rerr != nil {
			rm.log.Warn("table switch failed and the seat could not be restored",
				"userId", user.ID, "roomId", current.ID(), "error", err.Error(), "restoreError", rerr.Error())
		} else {
			rm.log.Warn("table switch failed, restoring seat",
				"userId", user.ID, "roomId", current.ID(), "error", err.Error())
		}
		return SwitchResult{From: current}, err
	}
	return SwitchResult{From: current, To: target}, nil
}

// Join (join) seats `user` at `table`: already_in_room unless unseated;
// reserve playerRooms under the lock; table.AddPlayer; on error remove the
// reservation and return it. socketID may be "".
//
// One seat per player, whichever door they came in by: without this a
// seated player could open a private room and be sat in two places, the old
// seat left behind to stall its table until the turn clock kicked it. The
// table must still be registered — a table DestroyTable has already taken
// out of the map refuses with table_destroyed rather than seating somebody
// on a room that is closing — and must have a seat that is not already held
// by a join in flight (table_full, "This table is full", the Table's own
// wording for the same refusal a moment later).
func (rm *RoomManager) Join(table *Table, user Player, socketID string) error {
	ul := rm.userLock(user.ID)
	ul.Lock()
	defer ul.Unlock()
	return rm.seat(table, user, socketID)
}

// seat is Join's body for callers already holding the player's stripe: take
// a hold (refusing already_in_room / table_destroyed / table_full under mu)
// and convert it into the seat.
func (rm *RoomManager) seat(table *Table, user Player, socketID string) error {
	if table == nil {
		return ErrTableDestroyed
	}
	rm.mu.Lock()
	if seated, _ := rm.seatedTableLocked(user.ID); seated != nil {
		rm.mu.Unlock()
		return NewGameError(CodeAlreadyInRoom, msgAlreadyInRoom)
	}
	if rm.tables[table.ID()] != table {
		rm.mu.Unlock()
		return ErrTableDestroyed
	}
	if rm.fullLocked(table) {
		rm.mu.Unlock()
		return NewGameError(CodeTableFull, MsgTableFull)
	}
	rm.holdLocked(table)
	rm.mu.Unlock()
	return rm.seatHeld(table, user, socketID)
}

// seatHeld converts a seat the caller holds on table into user's seat:
// reserve the index, AddPlayer, release the hold; on any refusal the index
// entry is removed again. The hold is consumed whatever happens. Caller
// holds the player's stripe, not mu.
func (rm *RoomManager) seatHeld(table *Table, user Player, socketID string) error {
	roomID := table.ID()

	rm.mu.Lock()
	if rm.tables[roomID] != table {
		rm.releaseHoldLocked(roomID)
		rm.mu.Unlock()
		return ErrTableDestroyed
	}
	if seated, _ := rm.seatedTableLocked(user.ID); seated != nil {
		rm.releaseHoldLocked(roomID)
		rm.mu.Unlock()
		return NewGameError(CodeAlreadyInRoom, msgAlreadyInRoom)
	}
	rm.playerRooms[user.ID] = roomID
	rm.mu.Unlock()

	_, err := table.AddPlayer(NewPlayer{
		UserID:      user.ID,
		DisplayName: user.DisplayName,
		AvatarURL:   user.AvatarURL,
		Chips:       user.Chips,
		SocketID:    socketID,
	})

	rm.mu.Lock()
	rm.releaseHoldLocked(roomID)
	if err != nil && rm.playerRooms[user.ID] == roomID {
		delete(rm.playerRooms, user.ID)
	}
	rm.mu.Unlock()
	if err == nil {
		rm.liveSetSeated(user.ID, roomID)
	}
	return err
}

// Leave (leave) removes a player: nil, nil when unseated. Deletes
// playerRooms FIRST (nothing that happens while the removal settles may
// still find them seated), then table.RemovePlayer(userId, reason). If the
// table is now empty → DestroyTable; else if reason != "moved" →
// ConsolidateTables (a departure is exactly when a table can drop to one
// player). Returns the table left. The reason string reaches the wire as the
// pack's game:action.reason when the player was in a live hand.
func (rm *RoomManager) Leave(userID, reason string) (*Table, error) {
	return rm.leaveFrom(userID, "", reason)
}

// leaveFrom is Leave restricted to one table: with roomID set the player is
// removed only while the index still says they are seated THERE, decided
// under their stripe together with the index deletion. The kick goroutine
// needs exactly this — a check made with GetTableForPlayer and acted on with
// Leave a moment later can straddle a leave + join of the same player and
// take the seat they have just sat down at somewhere else. "" means any
// table (Leave).
func (rm *RoomManager) leaveFrom(userID, roomID, reason string) (*Table, error) {
	ul := rm.userLock(userID)
	ul.Lock()
	table, _, err := rm.vacateFrom(userID, roomID, reason)
	ul.Unlock()
	if table == nil || err != nil {
		return table, err
	}

	if table.IsEmpty() {
		if err := rm.destroyTable(table.ID(), true); err != nil {
			return table, err
		}
	} else if reason != LeaveReasonMoved {
		// A departure is exactly when a table can drop to a single player, so
		// check for a merge right away rather than waiting for the next sweep.
		if _, err := rm.ConsolidateTables(); err != nil {
			return table, err
		}
	}
	return table, nil
}

// vacate is the first half of Leave, for callers holding the player's
// stripe: off the index, then off the table. nil, nil when unseated. A
// table destroyed under us (shutdown, sweep) counts as done — nobody is
// seated there any more, which is all a leave asks for.
func (rm *RoomManager) vacate(userID, reason string) (*Table, error) {
	table, _, err := rm.vacateFrom(userID, "", reason)
	return table, err
}

// vacateSeat is vacate for the one caller that needs the seat back: a table
// switch, which has to re-seat the player and must do so with the chips the
// checkpoint just banked rather than the wallet as it was read beforehand.
func (rm *RoomManager) vacateSeat(userID, reason string) (*Table, *SeatInfo, error) {
	return rm.vacateFrom(userID, "", reason)
}

// vacateFrom is vacate limited to roomID ("" = wherever they are): the index
// is checked and deleted in one critical section, so the caller's decision
// and the removal cannot be split by another transition of the same player.
func (rm *RoomManager) vacateFrom(userID, roomID, reason string) (*Table, *SeatInfo, error) {
	rm.mu.Lock()
	table, dropped := rm.seatedTableLocked(userID)
	if table == nil || (roomID != "" && table.ID() != roomID) {
		rm.mu.Unlock()
		if dropped {
			// The index named a table that is gone, so seatedTableLocked
			// dropped the entry: the mirror has to go with it or the seat key
			// is orphaned (it has no ttl). A player seated somewhere ELSE
			// (roomID names a table they have left) keeps their key — it is
			// their real seat.
			rm.liveClearSeated(userID)
		}
		return nil, nil, nil
	}
	// Off the index first: a leave can end a hand, and nothing that happens
	// while that settles should still find this player at the table.
	delete(rm.playerRooms, userID)
	rm.mu.Unlock()
	rm.liveClearSeated(userID)

	seat, err := table.RemovePlayer(userID, reason)
	if err != nil && !errors.Is(err, ErrTableDestroyed) {
		return table, nil, err
	}
	return table, seat, nil
}

// assertUnderEntryCap (_assertUnderEntryCap; requirement 30): the cheapest
// blind table is capped, so a player carrying a big stack cannot sit down at
// it. Checked on every route into a seat rather than only in the lobby: the
// lobby greys the table out, but a client is never what enforces a rule.
// EntryCapMaxChips 0 disables the cap; exactly the cap is allowed.
func (rm *RoomManager) assertUnderEntryCap(user Player, bootAmount int64, category Category) error {
	g := rm.game
	cap := g.EntryCapMaxChips
	if cap <= 0 {
		return nil
	}
	if bootAmount != g.EntryCapBoot {
		return nil
	}
	if string(category) != g.EntryCapCategory {
		return nil
	}
	if user.Chips <= cap {
		return nil
	}
	return Errorf(CodeOverEntryCap, msgOverEntryCapFormat, formatThousands(cap))
}

// formatThousands is Number#toLocaleString('en-US') for an integer: comma
// thousands grouping, no decimals ("500,000").
func formatThousands(n int64) string {
	digits := strconv.FormatInt(n, 10)
	sign := ""
	if strings.HasPrefix(digits, "-") {
		sign, digits = "-", digits[1:]
	}
	var b strings.Builder
	b.Grow(len(digits) + len(digits)/3 + 1)
	for i, d := range digits {
		if i > 0 && (len(digits)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(d)
	}
	return sign + b.String()
}

// assertNotSeated (_assertNotSeated): already_in_room when the index says
// the user is at a live table.
func (rm *RoomManager) assertNotSeated(userID string) error {
	if rm.GetTableForPlayer(userID) != nil {
		return NewGameError(CodeAlreadyInRoom, msgAlreadyInRoom)
	}
	return nil
}

// DestroyTable (destroyTable): under the lock, delete every seated user's
// playerRooms entry and the table itself (out of the map BEFORE the possibly
// slow settlement so nobody is seated at a table on its way out); then
// table.Destroy(); RoomListener.OnTableDestroyed; log `table destroyed`.
// No-op for an unknown id.
func (rm *RoomManager) DestroyTable(roomID string) error {
	return rm.destroyTable(roomID, false)
}

// destroyTable is DestroyTable with one refinement for the departure paths
// (Leave, a consolidation move, the empty-table sweep): with onlyIfUnclaimed
// the table is left alone when it is no longer empty or when the index holds
// a reservation for it — somebody is in the middle of sitting down, and
// Node's `if (table.isEmpty)` check could not see that half-finished join.
//
// The seated users are found through the index (every entry naming this
// room, reservations included) rather than by reading the table's seats,
// which would mean posting to the actor under mu.
func (rm *RoomManager) destroyTable(roomID string, onlyIfUnclaimed bool) error {
	rm.mu.Lock()
	table := rm.tables[roomID]
	if table == nil {
		rm.mu.Unlock()
		return nil
	}
	if onlyIfUnclaimed {
		if !table.IsEmpty() || rm.pending[roomID] > 0 {
			rm.mu.Unlock()
			return nil
		}
		for _, seatedAt := range rm.playerRooms {
			if seatedAt == roomID {
				rm.mu.Unlock()
				return nil
			}
		}
	}
	var unseated []string
	for userID, seatedAt := range rm.playerRooms {
		if seatedAt == roomID {
			delete(rm.playerRooms, userID)
			unseated = append(unseated, userID)
		}
	}
	delete(rm.tables, roomID)
	delete(rm.order, roomID)
	delete(rm.pending, roomID)
	rm.mu.Unlock()

	// A fenced table belongs to another process now: its seats and its index
	// entry are the owner's to keep (Table.Destroy likewise leaves the
	// owner's snapshot alone).
	if !table.Fenced() {
		for _, userID := range unseated {
			rm.liveClearSeated(userID)
		}
		rm.retireTable(table)
	}
	if err := table.Destroy(); err != nil && !errors.Is(err, ErrTableDestroyed) {
		return err
	}
	rm.rl.OnTableDestroyed(roomID)
	rm.log.Info("table destroyed", "roomId", roomID)
	if table.PendingSettlements() > 0 {
		// A pot the database had not accepted yet is still being written off
		// the actor (Table.settleDetached); the table emits nothing after
		// Destroy, so the outcome is logged from here.
		rm.log.Warn("table destroyed with a settlement still owed", "roomId", roomID, "pending", table.PendingSettlements())
		go func() {
			if err := table.WaitSettlements(context.Background()); err != nil {
				rm.log.Error("settlement abandoned after table destroyed", "roomId", roomID, "error", err.Error())
				return
			}
			rm.log.Info("late settlement landed after table destroyed", "roomId", roomID, "hands", table.SettlementsLanded())
		}()
	}
	return nil
}

// ConsolidateTables (consolidateTables; requirement 24) merges public idle
// tables (state waiting, no hand, exactly one player) of the same
// "category:boot" onto the OLDEST of the group (by CreatedAt, ties by
// creation order), moving one player at a time with movePlayer until the
// target is full. Returns the moves made.
//
// Two rooms each left with one player are two rooms where nobody can play,
// so the stragglers are pulled together onto one table. Only idle tables
// are touched: a table with a hand in progress is never disturbed, which is
// what stops a player being moved out from under a live game.
func (rm *RoomManager) ConsolidateTables() ([]PlayerMove, error) {
	rm.mu.Lock()
	var singles []*Table
	for _, t := range rm.tablesLocked() {
		if !t.IsPrivate() && !t.HasHand() && t.State() == TableWaiting && t.PlayerCount() == 1 {
			singles = append(singles, t)
		}
	}
	seq := make(map[string]uint64, len(singles))
	for _, t := range singles {
		seq[t.ID()] = rm.order[t.ID()]
	}
	rm.mu.Unlock()

	// Only tables of the same kind can be merged — a player must not be moved
	// to a different stake or category than the one they chose. Groups keep
	// the order in which they were first seen (Node's Map).
	var keys []string
	groups := map[string][]*Table{}
	for _, t := range singles {
		key := string(t.Category()) + ":" + strconv.FormatInt(t.BootAmount(), 10)
		if _, seen := groups[key]; !seen {
			keys = append(keys, key)
		}
		groups[key] = append(groups[key], t)
	}

	moves := []PlayerMove{}
	for _, key := range keys {
		group := groups[key]
		// The longest-standing table is the destination, so the room that has
		// been advertised longest is the one that fills up.
		sort.SliceStable(group, func(i, j int) bool {
			a, b := group[i].CreatedAt(), group[j].CreatedAt()
			if a.Equal(b) {
				return seq[group[i].ID()] < seq[group[j].ID()]
			}
			return a.Before(b)
		})
		target := group[0]
		for _, source := range group[1:] {
			if target.IsFull() {
				break
			}
			move, err := rm.movePlayer(source, target)
			if err != nil {
				return moves, err
			}
			if move != nil {
				moves = append(moves, *move)
			}
		}
	}
	return moves, nil
}

// movePlayer (_movePlayer): sole occupant of source → target. Bail (nil) if
// no seat, either table has a hand, or target is full. Player built from the
// seat (chips = seat chips), socketId kept. source.RemovePlayer(id,
// "moved"); delete playerRooms (holding the target seat at the same time);
// Join(target) — on failure (the target was destroyed under us) log `table
// consolidation failed, restoring seat` and Join(source) back.
// If source is now empty → DestroyTable(source). RoomListener.OnPlayerMoved;
// log `player moved to a busier table`.
//
// Event order for a successful move is Node's: the source's own events (seat
// vacated, chat, state), then the target's (seat filled, chat, maybe the
// start countdown, state), then OnTableDestroyed(source), then
// OnPlayerMoved — so a mover's room:closed always precedes room:moved /
// room:joined (DECISIONS.md §1).
func (rm *RoomManager) movePlayer(source, target *Table) (*PlayerMove, error) {
	seats, err := source.Seats()
	if err != nil {
		if errors.Is(err, ErrTableDestroyed) {
			return nil, nil
		}
		return nil, err
	}
	if len(seats) == 0 || source.HasHand() || target.HasHand() || target.IsFull() {
		return nil, nil
	}
	seat := seats[0]
	player := Player{
		ID:          seat.UserID,
		DisplayName: seat.DisplayName,
		AvatarURL:   seat.AvatarURL,
		Chips:       seat.Chips,
	}
	socketID := seat.SocketID
	fromRoomID := source.ID()

	ul := rm.userLock(player.ID)
	ul.Lock()

	// Off the index first (the same rule as Leave), and only if the index
	// still says they are here — otherwise somebody else has already moved
	// or removed this player and this sweep must not fight them. The target
	// seat is held in the same breath so it cannot fill up in between.
	rm.mu.Lock()
	if rm.playerRooms[player.ID] != fromRoomID || rm.tables[target.ID()] != target || rm.fullLocked(target) {
		rm.mu.Unlock()
		ul.Unlock()
		return nil, nil
	}
	delete(rm.playerRooms, player.ID)
	rm.holdLocked(target)
	rm.mu.Unlock()
	rm.liveClearSeated(player.ID)

	if _, err := source.RemovePlayer(player.ID, LeaveReasonMoved); err != nil {
		rm.releaseHold(target.ID())
		ul.Unlock()
		if errors.Is(err, ErrTableDestroyed) {
			return nil, nil
		}
		return nil, err
	}

	if err := rm.seatHeld(target, player, socketID); err != nil {
		// The destination filled up between the check and the move; put the
		// player back rather than dropping them.
		rm.log.Warn("table consolidation failed, restoring seat", "error", err.Error())
		rerr := rm.seat(source, player, socketID)
		ul.Unlock()
		if rerr != nil {
			rm.log.Error("table consolidation could not restore the seat",
				"userId", player.ID, "roomId", fromRoomID, "error", rerr.Error())
			if source.IsEmpty() {
				_ = rm.destroyTable(fromRoomID, true)
			}
		}
		return nil, nil
	}
	ul.Unlock()

	if source.IsEmpty() {
		if err := rm.destroyTable(fromRoomID, true); err != nil {
			return nil, err
		}
	}

	move := PlayerMove{UserID: player.ID, FromRoomID: fromRoomID, ToRoomID: target.ID()}
	rm.rl.OnPlayerMoved(move)
	rm.log.Info("player moved to a busier table",
		"userId", move.UserID, "fromRoomId", move.FromRoomID, "toRoomId", move.ToRoomID)
	return &move, nil
}

// SweepEmptyTables (sweepEmptyTables) destroys tables that are empty, waiting
// and older than a HARDCODED 30 seconds (Node: `Date.now() - 30_000`), so
// long-running processes stay flat. Age is measured on the injected Clock. A
// table somebody is in the middle of joining is skipped (see destroyTable).
func (rm *RoomManager) SweepEmptyTables() error {
	cutoff := rm.clock.Now().Add(-sweepEmptyTableMinAge)

	rm.mu.Lock()
	var stale []string
	for _, t := range rm.tablesLocked() {
		if t.IsEmpty() && t.State() == TableWaiting && t.CreatedAt().Before(cutoff) {
			stale = append(stale, t.ID())
		}
	}
	rm.mu.Unlock()

	for _, id := range stale {
		if err := rm.destroyTable(id, true); err != nil {
			return err
		}
	}
	return nil
}

// Stats is rooms.stats().
func (rm *RoomManager) Stats() Stats {
	// mu is the busiest lock in the server — every join, leave, switch and
	// consolidation needs it — and this runs on /health, which uptime checks
	// and dashboards poll. So take the counts and a copy of the table
	// pointers under the lock, then ask the tables themselves outside it.
	// HasHand is a lock-free atomic, but calling it 3,000 times while holding
	// mu would put /health in the way of every player trying to sit down.
	rm.mu.Lock()
	stats := Stats{Tables: len(rm.tables), Players: len(rm.playerRooms)}
	tables := rm.tablesLocked()
	rm.mu.Unlock()

	for _, t := range tables {
		if t.HasHand() {
			stats.ActiveHands++
		}
	}
	return stats
}

// Shutdown stops the sweeper and destroys every table in turn (settling live
// hands — their pots are paid out — before the caller closes the pool), then
// waits for any settlement the database refused at destroy time and that is
// still being retried off the actor (Table.WaitSettlements). ctx bounds the
// wait; Node gave the whole shutdown 8 s before process.exit(1). A table
// opened while the shutdown runs is destroyed as well. When ctx expires the
// remaining destroys carry on in the background and ctx.Err() is returned.
func (rm *RoomManager) Shutdown(ctx context.Context) error {
	rm.stopSweeper()

	done := make(chan error, 1)
	go func() {
		var destroyed []*Table
		var first error
		for {
			rm.mu.Lock()
			tables := rm.tablesLocked()
			rm.mu.Unlock()
			if len(tables) == 0 {
				break
			}
			for _, t := range tables {
				// One table's Destroy failing (a panic recovered on its actor
				// comes back as internal_error) must not leave the other live
				// pots unsettled: carry on and report the first error.
				if err := rm.DestroyTable(t.ID()); err != nil {
					if first == nil {
						first = err
					}
					continue
				}
				destroyed = append(destroyed, t)
			}
		}
		// A settlement the database refused at destroy time is still being
		// retried off the actor; leaving now would orphan the pot. Wait for
		// those writes within the caller's budget.
		for _, t := range destroyed {
			if err := t.WaitSettlements(ctx); err != nil {
				if ctx.Err() != nil {
					done <- err
					return
				}
				rm.log.Error("settlement abandoned at shutdown", "roomId", t.ID(), "error", err.Error())
			}
		}
		done <- first
	}()

	select {
	case err := <-done:
		return err
	case <-ctx.Done():
		// The destroys finished in the same instant the context expired?
		// Then they finished.
		select {
		case err := <-done:
			return err
		default:
			return ctx.Err()
		}
	}
}

// tableHooks is the Listener every Table is built with. It forwards every
// event to the app-supplied TableListener unchanged and additionally:
//
//   - OnKick: `go func(){ if rm.GetTableForPlayer(uid) == this table { if
//     err := rm.Leave(uid, reason); err != nil { log "kick failed"; return };
//     rm.rl.OnPlayerKicked(...) } }()` — in a NEW goroutine, because Leave
//     posts to the very table that is delivering the event;
//   - OnPersistError: log warn `table write refused {roomId, reason, error}`;
//   - OnError: log error `table error {roomId, error}`.
//
// Metric counters fed from table events stay in the socket layer's Listener,
// as Node's wireTable did.
type tableHooks struct {
	rm *RoomManager
}

var _ Listener = (*tableHooks)(nil)

// OnState forwards, then publishes the table to the matchmaking index when
// its player count or state changed (lock-free getters only; one store
// round trip on the actor, the same cost as the snapshot save that follows).
func (h *tableHooks) OnState(v *View) {
	h.rm.tl.OnState(v)
	h.rm.publishFromActor(v.t)
}
func (h *tableHooks) OnSeatUpdated(v *View, i int)              { h.rm.tl.OnSeatUpdated(v, i) }
func (h *tableHooks) OnChat(v *View, m *ChatMessage)            { h.rm.tl.OnChat(v, m) }
func (h *tableHooks) OnHandStarted(v *View, e HandStartedEvent) { h.rm.tl.OnHandStarted(v, e) }
func (h *tableHooks) OnCards(v *View, e CardsEvent)             { h.rm.tl.OnCards(v, e) }
func (h *tableHooks) OnTurn(v *View, e TurnEvent)               { h.rm.tl.OnTurn(v, e) }
func (h *tableHooks) OnAction(v *View, e ActionEvent)           { h.rm.tl.OnAction(v, e) }
func (h *tableHooks) OnShowdown(v *View, e ShowdownEvent)       { h.rm.tl.OnShowdown(v, e) }
func (h *tableHooks) OnHandEnded(v *View, e HandEndedEvent)     { h.rm.tl.OnHandEnded(v, e) }
func (h *tableHooks) OnSideshowReveal(v *View, e SideshowRevealEvent) {
	h.rm.tl.OnSideshowReveal(v, e)
}
func (h *tableHooks) OnSideshowRequested(v *View, e SideshowRequestedEvent) {
	h.rm.tl.OnSideshowRequested(v, e)
}
func (h *tableHooks) OnSideshowResolved(v *View, e SideshowResolvedEvent) {
	h.rm.tl.OnSideshowResolved(v, e)
}

// OnKick removes the player in a new goroutine — see the type comment. The
// Table only announces the kick; this is where the seat is actually vacated
// (Node: the socket layer's `table.on('kick')`, which ran synchronously
// right after the emit and so always found the player still on the kicking
// table — the Go guard requires exactly that, so a kick that lands after the
// player has already left and sat down elsewhere does not follow them).
func (h *tableHooks) OnKick(v *View, e KickEvent) {
	roomID := v.ID()
	h.rm.tl.OnKick(v, e)
	rm := h.rm
	go func() {
		// "Still seated at the kicking table" is decided under the player's
		// stripe, atomically with the index deletion (leaveFrom): checking
		// with GetTableForPlayer first and calling Leave afterwards left a
		// gap in which a leave + join of the same player could slip through,
		// and the stale kick then took the seat they had just moved to.
		left, err := rm.leaveFrom(e.UserID, roomID, e.Reason)
		if err != nil {
			rm.log.Error("kick failed", "userId", e.UserID, "reason", e.Reason, "error", err.Error())
			return
		}
		if left == nil {
			return // already gone from that table
		}
		rm.rl.OnPlayerKicked(PlayerKicked{
			RoomID:  roomID,
			UserID:  e.UserID,
			Reason:  e.Reason,
			Message: e.Message,
		})
	}()
}

// OnPersistError logs at warn and forwards. A live-store failure
// (PersistReasonLive*) refused nothing — the move stood, the store's copy is
// behind — so it is logged as `live store write failed` rather than as a
// refused write.
func (h *tableHooks) OnPersistError(v *View, e PersistErrorEvent) {
	var errText any // Node: error?.message
	if e.Err != nil {
		errText = e.Err.Error()
	}
	switch e.Reason {
	case PersistReasonLiveSave, PersistReasonLiveChat, PersistReasonLiveDelete:
		h.rm.log.Warn("live store write failed", "roomId", v.ID(), "reason", e.Reason, "error", errText)
	default:
		h.rm.log.Warn("table write refused", "roomId", v.ID(), "reason", e.Reason, "error", errText)
	}
	h.rm.tl.OnPersistError(v, e)
}

// OnError logs at error and forwards. A *FencedError (the live store refused
// a save with live.ErrStale: another process owns the table) additionally
// destroys the table — in a new goroutine, DestroyTable posts to the actor
// delivering this event. Its viewers get room:closed and find their seats
// again on the owning process.
func (h *tableHooks) OnError(v *View, err error) {
	text := ""
	if err != nil {
		text = err.Error()
	}
	h.rm.log.Error("table error", "roomId", v.ID(), "error", text)
	h.rm.tl.OnError(v, err)
	var fenced *FencedError
	if errors.As(err, &fenced) {
		roomID := v.ID()
		rm := h.rm
		go func() {
			if derr := rm.DestroyTable(roomID); derr != nil {
				rm.log.Error("fenced table could not be destroyed", "roomId", roomID, "error", derr.Error())
			}
		}()
	}
}

// String makes a PlayerMove readable in logs and test failures.
func (m PlayerMove) String() string {
	return fmt.Sprintf("%s: %s → %s", m.UserID, m.FromRoomID, m.ToRoomID)
}
