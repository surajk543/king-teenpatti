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
	// TablePicture is the table picture the player has laid on their
	// account, or nil (owner, 15 Sep 2026); it goes onto their seat.
	TablePicture *TablePicture
	Chips        int64
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
	// MaxPot and MaxBlindMoves are the figures the table this entry opens
	// plays by (config.GameConfig.Spec — the same answer newTableLocked
	// builds the table from): from env, SeenMaxPot for seen entries, the
	// boot-scaled cap for variation ones (config.VariationMaxPot), 0
	// (uncapped) for blind, a `pot=N` of the entry's own over any of them;
	// in db mode, the entry's table_configs row.
	MaxPot        int64 `json:"maxPot"`
	MaxBlindMoves int   `json:"maxBlindMoves"`
	// MinChips / MaxChips are the stack band for this table, 0 for no limit
	// at that end (config.LobbyTable). They are sent so the lobby can say who
	// a table is for BEFORE the tap — a card that explains why it is shut is
	// worth more than a refusal after the fact — but the client is never what
	// enforces them: RoomManager.assertWithinTableBand checks every route
	// into a seat.
	MinChips int64 `json:"minChips"`
	MaxChips int64 `json:"maxChips"`

	// ---- poker entries only (POKER_PLAN.md §4); ABSENT on every Teen Patti
	// entry, whose bytes are unchanged ----

	// Game is GamePoker on a poker entry (the client files it under the Poker
	// card and reads the fields below), absent otherwise.
	Game Game `json:"game,omitempty"`
	// SmallBlind / BigBlind are a Hold'em or Omaha table's blinds (the big
	// blind IS the boot); Ante a 3-Card Poker or 5-Card Draw table's ante
	// (the boot). Whichever the variant does not post is absent.
	SmallBlind int64 `json:"smallBlind,omitempty"`
	BigBlind   int64 `json:"bigBlind,omitempty"`
	Ante       int64 `json:"ante,omitempty"`
	// MinBuyIn is the smallest stack that may sit down (POKER_MIN_BUYIN_BOOTS
	// × boot); MinChips is raised to it, so the band and the buy-in agree.
	MinBuyIn int64 `json:"minBuyIn,omitempty"`
	// HoleCards is how many cards each player holds (2, 4, 5 or 3);
	// MaxDiscards how many a 5-Card Draw player may exchange (absent elsewhere).
	HoleCards   int `json:"holeCards,omitempty"`
	MaxDiscards int `json:"maxDiscards,omitempty"`
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
	OnTableCreated(r Room)
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

func (NopRoomListener) OnTableCreated(Room)         {}
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
	// Category is normalised: anything but "blind", "variation" or a poker
	// category is seen, and so is "variation" on a lobby whose menu does not
	// offer it, and a private table of a category with no private template
	// (db mode; config.GameConfig.HasPrivate).
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
	From Room
	To   Room
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
	// Hammers is the wallet every Table charges a Force Sideshow to.
	// Production: db.Hammers. nil → each table's empty default, which refuses
	// every Force Sideshow no_hammers.
	Hammers HammerWallet
	// Missiles is the wallet every Table fires a missile from. Production:
	// db.Missiles. nil → each table's empty default, which refuses every
	// missile no_missiles.
	Missiles MissileWallet
	Clock    Clock // nil → RealClock{}
	// TableListener receives every Table's events (the socket layer). The
	// RoomManager wraps it (see tableHooks) so that it can act on OnKick,
	// OnPersistError and OnError itself, then forwards every call unchanged.
	// nil → NopListener.
	TableListener Listener
	// Listener receives room-level events. nil → NopRoomListener.
	Listener RoomListener
	Logger   *slog.Logger // nil → slog.Default()
	Metrics  MetricsHooks

	// LoadPlayer reads a player's account — above all their wallet — for a
	// seat taken from the lobby (QuickJoin, JoinByCode, Join, CreateAndJoin).
	// It is called HOLDING that player's seat lock, with a context bounded by
	// walletReadTimeout, and the seat starts from what it returns rather than
	// from the Player the caller passed in; the chip checks of that door read
	// it too.
	//
	// It is the other half of WhileUnseated and CreditBoughtChips. Every
	// caller reads the wallet before asking for a seat (the socket layer's
	// freshUser), and a lobby-only debit — a chip-priced picture — that
	// committed between that read and the seat reservation used to leave the
	// seat holding chips the wallet no longer had: when the player lost them,
	// the checkpoint clamped the wallet at zero and the winner was paid chips
	// that never existed. Read under the lock, the wallet a seat starts from
	// cannot be moved by a change holding the same lock before the seat is
	// reserved, and once it is reserved a lobby-only change is refused
	// (CLAUDE.md §5.1: a seated wallet moves only at a checkpoint).
	//
	// It is not called while that wallet is still waiting for a write from a
	// table the player sat at (departing, owed): no read can be final before
	// the write lands, so the seat is refused settlement_pending instead.
	//
	// nil → the Player the caller passed is used as it is (unit tests, whose
	// players have no wallet behind them). Production wires db.Users.FindByID.
	LoadPlayer func(ctx context.Context, userID string) (Player, error)

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

	// Factories opens and restores the rooms of every game family but Teen
	// Patti, keyed by family (POKER_PLAN.md §4): the app wires
	// poker.Factory under GamePoker. A poker category on the menu with no
	// factory behind it is logged at construction and its tables are folded
	// to seen, which is what an unknown category has always become.
	Factories map[Game]RoomFactory
}

// RoomManager owns every live table in this process (roomManager.js).
//
// # Locking (PORT_PLAN.md decision 5)
//
// mu protects ONLY tables, order, pending, draining and playerRooms (and the
// wallet marks departing and owed, below). It is NEVER held while calling
// into a Table (every Table method may block on the actor, which may be
// inside a Ledger write). Pattern for every method: lock → look up /
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
// The stripe also fences the player's wallet off from the lobby. Every seat
// taken from the lobby reads the wallet under it (LoadPlayer), and the wallet
// changes a seat must neither start from half-done nor miss run under it — a
// lobby-only change (WhileUnseated), a chip pack's credit together with its
// seat top-up (CreditBoughtChips) — so no seat starts from a balance such a
// change is about to replace. The database work done under a stripe is that
// read, those changes, and whatever checkpoint a Table call makes on the
// actor; none of it takes a stripe, so the order is always stripe → mu
// (briefly, released) → table actor → database, and nothing waits the other
// way round. (A table's actor does take mu, briefly, to count a settlement
// owed — but mu is never held while calling a table, so no holder of mu can be
// waiting for that actor.) Two paths take seats off the index without the
// players' stripes, a table destroy and a suspend; they mark those players
// departing instead. And a player can leave a table between hands while the
// database is still refusing that table's last settlement; the table reports
// the write owed (settlementOwed). WhileUnseated and every lobby seat
// (freshPlayer) honour both marks.
//
// All methods Node marked async are ordinary blocking methods here.
type RoomManager struct {
	game     config.GameConfig
	chat     config.ChatConfig
	ledger   Ledger
	hammers  HammerWallet
	missiles MissileWallet
	clock    Clock
	tl       Listener
	rl       RoomListener
	log      *slog.Logger
	mx       MetricsHooks
	hooks    *tableHooks
	// factories is RoomManagerOptions.Factories; roomHooks the RoomHooks every
	// factory-built room reports to (the family-neutral half of tableHooks).
	factories map[Game]RoomFactory
	roomHooks *roomHooks

	// loadPlayer is RoomManagerOptions.LoadPlayer (nil → the caller's Player).
	loadPlayer func(ctx context.Context, userID string) (Player, error)

	// tableConfig is the catalogue payload (TableConfig), computed once at
	// construction from the immutable config and never written again.
	tableConfig TableConfigPayload

	mu          sync.Mutex
	tables      map[string]Room   // roomId → room (a *Table or a factory's room)
	playerRooms map[string]string // userId → roomId
	// departing is userId → seats of theirs that destroyTable or Suspend has
	// taken off the index without the player's stripe and whose last write
	// has not landed yet: the settlement of the live hand Destroy ends, until
	// Destroy returns (a settlement it leaves retrying is owed from then on),
	// or the seat a suspend hands on to the next process. WhileUnseated and a
	// lobby seat (freshPlayer) treat such a player as still at the table — a
	// lobby debit, or a seat started from the wallet, landing ahead of that
	// write would leave it to clamp the wallet at zero.
	departing map[string]int
	// owed is userId → refused hand-end settlements still being retried that
	// move that player's wallet (settlementOwed). Honoured exactly as
	// departing is, for as long as the count is above zero.
	owed map[string]int
	// order is roomId → creation sequence number. Node's Map iterated in
	// insertion order and its sorts were stable, so every "oldest" / "ties
	// to the earliest" rule fell out of creation order; Go maps do not
	// iterate deterministically and a fake clock can stamp two tables with
	// the same CreatedAt, so the order is recorded explicitly.
	order   map[string]uint64
	nextSeq uint64
	// draining is every public room restored from the live store that the
	// current configuration would not open as it is: its pair has left a
	// non-empty menu, or it plays by figures its pair's spec no longer gives
	// (drainReason). Matchmaking never sends anybody INTO one — quick-join and
	// a switch pass it by, and consolidation never moves a player there from
	// an undrained table — but its players may be taken out: a switch away,
	// or a consolidation moving its lone player onto the undrained table of
	// the same pair (their stack permitting) or onto an older drained one
	// playing by the same frozen rules (ConsolidateTables). Its code still
	// works, its players play on, and it goes the way of any table once it
	// empties. The entry goes with the table (destroyTable, Suspend).
	draining map[string]bool
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
	msgAlreadyInRoom       = "You are already seated at a table"
	msgInvalidStake        = "That stake is not valid"
	msgStakeMustBeOneOf    = "Stake must be one of: %s"
	msgLobbyOffers         = "The lobby offers: %s"
	msgInsufficientToJoin  = "Not enough chips to join this table"
	msgInvalidRoomCode     = "Table codes are 8 letters and numbers"
	msgRoomNotFound        = "No table with that code"
	msgThatTableFull       = "That table is full" // joinByCode; the Table's own is "This table is full"
	msgNotAtATable         = "You are not at a table"
	msgPrivateTableSwitch  = "A private table cannot be swapped for another"
	msgNoOtherTableFormat  = "No other %s table at this stake has a free seat right now"
	msgOverEntryCapFormat  = "Players with more than %s chips cannot join this table"
	msgBelowTableMinFormat = "This table is for players with %s chips or more"
	msgSettlementPending   = "Your last hand is still being saved; try again in a moment" // Go only (freshPlayer)
	sweepEmptyTableMinAge  = 30 * time.Second                                             // roomManager.js sweepEmptyTables: Date.now() - 30_000, hardcoded
	userLockStripes        = 256
	quickJoinMaxRepicks    = 3
)

// Bounds on the database work done holding a player's stripe. A stripe is
// shared by every player hashed to it (1 in userLockStripes), and
// statement_timeout does not cover waiting for a pool connection or a
// database that has stopped answering, so none of that work may wait for ever.
const (
	// walletReadTimeout bounds LoadPlayer: a join that cannot read the wallet
	// in this long is refused rather than left holding the stripe.
	walletReadTimeout = 10 * time.Second
	// walletWorkTimeout bounds the transaction WhileUnseated or
	// CreditBoughtChips runs. It is twice PG_STATEMENT_TIMEOUT_MS's default on
	// purpose: a statement PostgreSQL gives up on fails and rolls back before
	// this fires, so the outcome is final when the stripe is released. The
	// bound is for a stall PostgreSQL cannot see — a pool that never hands out
	// a connection, or a network gone quiet mid-COMMIT, the one case in which
	// the stripe is let go with the outcome still unknown.
	walletWorkTimeout = 30 * time.Second
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
		hammers:     opts.Hammers,
		missiles:    opts.Missiles,
		loadPlayer:  opts.LoadPlayer,
		clock:       clock,
		tl:          tl,
		rl:          rl,
		log:         logger,
		mx:          opts.Metrics,
		tables:      map[string]Room{},
		playerRooms: map[string]string{},
		departing:   map[string]int{},
		owed:        map[string]int{},
		order:       map[string]uint64{},
		draining:    map[string]bool{},
		pending:     map[string]int{},
		live:        opts.Live,
		instance:    opts.Instance,
		liveTTL:     liveTTL,
		published:   map[string]publishedSummary{},
		factories:   opts.Factories,
	}
	rm.hooks = &tableHooks{rm: rm}
	rm.roomHooks = &roomHooks{rm: rm}
	for _, entry := range opts.Game.LobbyTables {
		if c := Category(entry.Category); c.IsPoker() && rm.factoryFor(c) == nil {
			logger.Warn("lobby menu lists a poker table but no poker factory is wired; its tables would open as seen",
				"category", entry.Category, "bootAmount", entry.BootAmount)
		}
	}
	rm.tableConfig = rm.buildTableConfig()
	return rm
}

// factoryFor is the RoomFactory for a category's family, nil for Teen Patti
// (which the manager builds itself) and for a family nobody wired.
func (rm *RoomManager) factoryFor(category Category) RoomFactory {
	if category.Game() == GameTeenPatti || rm.factories == nil {
		return nil
	}
	return rm.factories[category.Game()]
}

// roomDeps is RoomDeps for a factory-built room: the same ledger, clock,
// live store and hooks every *Table gets through tableOptions.
func (rm *RoomManager) roomDeps() RoomDeps {
	return RoomDeps{
		Game:             rm.game,
		Chat:             rm.chat,
		Clock:            rm.clock,
		Ledger:           rm.ledger,
		Live:             rm.live,
		LiveTTL:          rm.liveTTL,
		LiveErrors:       rm.liveErrorHook,
		ObserveHandStart: rm.mx.ObserveHandStart,
		SettlementOwed:   rm.settlementOwed,
		Hooks:            rm.roomHooks,
	}
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

// NormalizeCategory: "blind" → CategoryBlind; "variation" → CategoryVariation
// (Go only); anything else → CategorySeen. Exact matches only — the set is
// closed, and an unknown category never hides chips or opens a variation
// window by accident.
func NormalizeCategory(category string) Category {
	switch category {
	case string(CategoryBlind):
		return CategoryBlind
	case string(CategoryVariation):
		return CategoryVariation
	case string(CategoryThreeCardPoker), string(CategoryFiveCardDraw), string(CategoryTexasHoldem), string(CategoryOmaha):
		// The poker family (Go only; owner, 19 Sep 2026). Exact matches, as
		// for the three above: a poker room is a different engine, and nothing a
		// client sends may open one by accident.
		return Category(category)
	default:
		return CategorySeen
	}
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
// Metrics.ObserveCreation. Rules are config.GameConfig.Spec's (newTableLocked):
// in db mode the table_configs row of the pair (a private table: its
// category's template), from env the composition config.GameConfig.TableRules
// makes exactly as Node's spreads did:
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
//   - the rest of TableConfig copies config.Game, the chat caps config.Chat;
//   - id util.UUID(), code util.RoomCode(8) regenerated until unique among
//     live tables (DECISIONS.md §3), Listener = rm's tableHooks.
//
// Registers the table, calls RoomListener.OnTableCreated, logs `table
// created {roomId, code, bootAmount, category, isPrivate, maxPot}`.
func (rm *RoomManager) CreateTable(opts CreateTableOptions) Room {
	started := time.Now()
	rm.mu.Lock()
	table := rm.newTableLocked(opts)
	rm.mu.Unlock()
	rm.announceCreated(table, started)
	return table
}

// offersVariation reports whether this lobby has a variation table on its
// menu. An empty menu means "any pair" (tests), which includes it. It reads
// only the immutable config, so it needs no lock.
func (rm *RoomManager) offersVariation() bool {
	if len(rm.game.LobbyTables) == 0 {
		return true
	}
	for _, entry := range rm.game.LobbyTables {
		if entry.Category == string(CategoryVariation) {
			return true
		}
	}
	return false
}

// offersCategory reports whether the menu lists at least one table of c.
// Unlike offersVariation an EMPTY menu does not count as offering it: it is
// asked only of poker categories, which need a factory to open at all.
func (rm *RoomManager) offersCategory(c Category) bool {
	for _, entry := range rm.game.LobbyTables {
		if entry.Category == string(c) {
			return true
		}
	}
	return false
}

// newTableLocked is _createTable up to and including `tables.set`: builds
// the TableConfig, picks a code no live table uses, constructs the Table and
// registers it. mu held — the code is chosen and the table registered under
// one lock so two concurrent creations can never share a code, and a
// quick-join can register and take a seat in the same critical section.
// NewTable only allocates and starts the actor goroutine — it never posts to
// it — so holding mu across it does not break the "never call into a Table
// under mu" rule.
//
// Every figure the new room plays by comes from config.GameConfig.Spec for
// the category it resolves to (the table_configs row in db mode, the env
// composition otherwise — TableRules and the global keys, exactly as they
// always composed it), so the table and the lobby card that sent a player to
// it read one source. The category is settled first, in this order: a
// variation table the menu does not offer is seen; a private table of a
// category with no private template (db mode) is seen; a poker category
// without a factory, or whose factory refuses, is seen.
func (rm *RoomManager) newTableLocked(opts CreateTableOptions) Room {
	g := rm.game
	resolved := NormalizeCategory(opts.Category)
	// Leaving `variation:` off the menu switches the category off, and a
	// private table is no way round that: AssertTableOffered guards only the
	// public doors, so a private create naming a category this lobby does not
	// offer is folded to seen — what an unknown category has always become.
	if resolved == CategoryVariation && !rm.offersVariation() {
		resolved = CategorySeen
	}
	// A private table plays by its category's private template. In db mode a
	// category the operator has not given one (or has switched off) cannot be
	// opened privately, and folds to seen as an unknown category does; the
	// catalogue always has a private seen template (TableCatalogue.Validate).
	if opts.IsPrivate && !g.HasPrivate(string(resolved)) {
		resolved = CategorySeen
	}
	// A poker category opens a room of the poker family through its factory
	// (POKER_PLAN.md §4). Without one — a deployment that never wired it —
	// it is folded to seen exactly as an unknown category is, and was logged
	// at construction. The factory is called under mu as NewTable is: it
	// starts the room's actor and never posts to it.
	if resolved.IsPoker() {
		if factory := rm.factoryFor(resolved); factory != nil {
			id := util.UUID()
			code := util.RoomCode(util.DefaultRoomCodeLength)
			for rm.codeTakenLocked(code) {
				code = util.RoomCode(util.DefaultRoomCodeLength)
			}
			spec := g.Spec(string(resolved), opts.BootAmount, opts.IsPrivate)
			room, err := factory.New(RoomSpec{
				ID: id, Code: code, Category: resolved, BootAmount: spec.BootAmount, IsPrivate: opts.IsPrivate, Table: spec,
			}, rm.roomDeps())
			if err == nil {
				rm.nextSeq++
				rm.tables[id] = room
				rm.order[id] = rm.nextSeq
				return room
			}
			rm.log.Error("poker room could not be opened; opening a seen table instead", "category", string(resolved), "error", err.Error())
		}
		resolved = CategorySeen
	}
	cfg := tableConfigFromSpec(resolved, g.Spec(string(resolved), opts.BootAmount, opts.IsPrivate), rm.chat)

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
// this manager shares: ledger, hammer and missile wallets, clock, the hooks
// Listener and the live store. A restored table gets them through here too, so
// a Force Sideshow or a missile on a table brought back from the live store is
// charged like any other.
func (rm *RoomManager) tableOptions(opts TableOptions) TableOptions {
	opts.Ledger = rm.ledger
	opts.Hammers = rm.hammers
	opts.Missiles = rm.missiles
	opts.Clock = rm.clock
	opts.Listener = rm.hooks
	opts.Live = rm.live
	opts.LiveTTL = rm.liveTTL
	opts.LiveErrors = rm.liveErrorHook
	opts.ObserveHandStart = rm.mx.ObserveHandStart
	opts.SettlementOwed = rm.settlementOwed
	return opts
}

// announceCreated is the tail of _createTable, outside mu: emit
// tableCreated, log, observe the creation duration, publish to the index.
func (rm *RoomManager) announceCreated(table Room, started time.Time) {
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
func (rm *RoomManager) GetTable(roomID string) Room {
	rm.mu.Lock()
	defer rm.mu.Unlock()
	return rm.tables[roomID]
}

// GetTableByCode matches the upper-cased code, or nil.
func (rm *RoomManager) GetTableByCode(code string) Room {
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

// CreditBoughtChips banks a chip purchase and adds it to the player's seat, if
// they have one, as one step under the player's stripe, and reports whether a
// seat was topped up. bank is the database credit: it runs on the context it
// is handed — bounded by walletWorkTimeout and never a request's, for the
// reason given on WhileUnseated — and reports whether it credited the wallet
// this time. A receipt already banked credits nothing, and neither does its
// seat.
//
// A purchase is not lobby-only, so why the stripe: the credit and the top-up
// are two moments, and a lobby seat is taken from the wallet as read under the
// stripe (LoadPlayer). With nothing held across both, a join could read the
// wallet after the credit had committed and reserve its seat before the
// top-up looked for one: the seat started with the pack in it, the top-up
// added the pack again, and losing those chips clamped the wallet at zero and
// paid out chips that never existed. Held across both, either the join sits
// down first and the top-up finds its seat, or the join reads a wallet that
// already holds the pack, after a top-up that found no seat. A seated player's
// purchase is otherwise unchanged: the top-up is Table.CreditChips, which also
// ends an unfunded grace the chips now cover.
//
// bank must not start a seat transition, or any other call that takes this
// player's stripe: it would deadlock.
func (rm *RoomManager) CreditBoughtChips(userID string, amount int64, bank func(ctx context.Context) bool) bool {
	ul := rm.userLock(userID)
	ul.Lock()
	defer ul.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), walletWorkTimeout)
	credited := bank(ctx)
	cancel()
	if !credited {
		return false
	}
	return rm.creditSeat(userID, amount)
}

// creditSeat adds purchased chips to a player's seat, wherever they are
// sitting, and reports whether a seat was found. The caller holds the
// player's stripe (CreditBoughtChips).
//
// The mutex is released before the table is touched — RoomManager never holds
// its lock while calling a Table (PORT_PLAN.md §3.4), and CreditChips posts to
// that table's actor.
func (rm *RoomManager) creditSeat(userID string, amount int64) bool {
	t := rm.GetTableForPlayer(userID)
	if t == nil {
		return false
	}
	return t.CreditChips(userID, amount)
}

// GetTableForPlayer returns the table the user is seated at (via
// playerRooms), or nil.
func (rm *RoomManager) GetTableForPlayer(userID string) Room {
	rm.mu.Lock()
	t, dropped := rm.seatedTableLocked(userID)
	rm.mu.Unlock()
	if dropped {
		rm.liveClearSeated(userID)
	}
	return t
}

// SetPlayerAvatar puts a player's newly worn picture on their seat, when they
// have one. The avatar endpoint calls it after the choice is saved, so for a
// player in the lobby it does nothing: their next seat reads the picture from
// the user row like any other join. A table destroyed between the lookup and
// the call has no seat to update, so that error is not one.
func (rm *RoomManager) SetPlayerAvatar(userID string, avatarURL *string) {
	if t := rm.GetTableForPlayer(userID); t != nil {
		_ = t.SetAvatar(userID, avatarURL)
	}
}

// SetPlayerTablePicture puts the table picture a player has just laid (nil:
// taken off) on their seat, when they have one, so the table can show it to
// everyone (Table.SetTablePicture). For a player in the lobby it does
// nothing: their next seat reads the picture from the user row like any
// other join. Only a Teen Patti table shows a table picture (the feature
// predates the Poker family, §6.5, whose felt has the board where the
// picture would go): at a poker room the choice is saved on the account and
// nothing on the felt changes, so this does nothing there either.
func (rm *RoomManager) SetPlayerTablePicture(userID string, pic *TablePicture) {
	if t := AsTable(rm.GetTableForPlayer(userID)); t != nil {
		_ = t.SetTablePicture(userID, pic)
	}
}

// seatedTableLocked is getTableForPlayer under mu: the table the index
// points at, or nil. An index entry naming a table that is no longer
// registered is stale (Node's getTable returned null for it too) and is
// dropped on sight so it cannot block a later join; `dropped` says so, and
// EVERY caller that leaves the player unseated must then clear the live
// store's mirror of that entry (liveClearSeated). Seat keys carry no ttl, so
// one dropped silently is one that stays in Redis for good — the
// `kt:seat:<userId>` leak found on production, 9 Sep 2026.
func (rm *RoomManager) seatedTableLocked(userID string) (t Room, dropped bool) {
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
func (rm *RoomManager) tablesLocked() []Room {
	out := make([]Room, 0, len(rm.tables))
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
	menu := rm.menuRows()
	tables := make([]LobbyTableOption, 0, len(menu))
	for _, row := range menu {
		tables = append(tables, row.option)
	}
	// The two categories every client has always been told of, the third
	// only where this lobby actually offers it, and each poker category only
	// where the menu lists a table of it: a menu with no variation or poker
	// entry advertises exactly what it did before they existed. An empty menu
	// means "any pair" (tests), which includes variation but not poker (a
	// poker room needs a factory, which an empty menu says nothing about).
	categories := []Category{CategorySeen, CategoryBlind}
	if rm.offersVariation() {
		categories = append(categories, CategoryVariation)
	}
	for _, c := range PokerCategories {
		if rm.offersCategory(c) {
			categories = append(categories, c)
		}
	}
	return LobbyOptions{
		Categories:       categories,
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
func (rm *RoomManager) LiveTables() []Room {
	rm.mu.Lock()
	defer rm.mu.Unlock()
	return rm.tablesLocked()
}

// occupancyLocked is the seats taken plus the seats held by joins in flight
// — what the table will hold once every pending AddPlayer lands. mu held.
func (rm *RoomManager) occupancyLocked(t Room) int {
	return t.PlayerCount() + rm.pending[t.ID()]
}

// fullLocked is IsFull counting held seats. mu held.
func (rm *RoomManager) fullLocked(t Room) bool {
	return rm.occupancyLocked(t) >= t.MaxPlayers()
}

// holdLocked takes one seat on t for a join that is about to follow (mu
// held). Every hold is consumed by seatHeld or given back by
// releaseHoldLocked; the table's own AddPlayer is what actually seats.
func (rm *RoomManager) holdLocked(t Room) { rm.pending[t.ID()]++ }

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

// pickTableLocked is quickJoin's candidate scan: the
// FULLEST public non-full table with the same boot AND category, excluding
// excludeID, ties to the earliest created (Node's stable sort over a Map in
// insertion order). Table state is not considered — a player may sit down
// mid-hand and wait for the next deal. A draining table is never picked: the
// lobby card describes the table the configuration opens now, not it. nil when
// none. mu held; only lock-free getters are read.
func (rm *RoomManager) pickTableLocked(bootAmount int64, category Category, excludeID string) Room {
	var best Room
	var bestSeq uint64
	var bestOccupancy int
	for id, t := range rm.tables {
		if id == excludeID || t.IsPrivate() || rm.draining[id] || rm.fullLocked(t) {
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

// pickRandomTableLocked is switchTable's candidate scan: a table chosen
// uniformly at random from every OTHER public non-full table with the same
// boot AND category (owner, 13 Sep 2026). Node — and quickJoin still — sent a
// switcher to the fullest table, which funnelled every switch at a stake onto
// the same few tables; a random pick spreads switchers across all the tables
// of that kind. The draw is crypto/rand (cryptoIntn), like the deck: which
// table a player lands on should not be predictable. A draining table is never
// a destination (a player may still switch away from one). nil when none. mu
// held; only lock-free getters are read.
func (rm *RoomManager) pickRandomTableLocked(bootAmount int64, category Category, excludeID string) Room {
	var candidates []Room
	for id, t := range rm.tables {
		if id == excludeID || t.IsPrivate() || rm.draining[id] || rm.fullLocked(t) {
			continue
		}
		if t.BootAmount() != bootAmount || t.Category() != category {
			continue
		}
		candidates = append(candidates, t)
	}
	if len(candidates) == 0 {
		return nil
	}
	return candidates[cryptoIntn(len(candidates))]
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
//
// The player's stripe is taken before anything is decided, because the chip
// checks and the seat have to use the wallet as it stands under that lock
// (freshPlayer, LoadPlayer): a lobby-only wallet change holds the same lock
// (WhileUnseated), so it lands wholly before the read or is refused once the
// seat is reserved.
func (rm *RoomManager) QuickJoin(user Player, opts QuickJoinOptions) (Room, error) {
	ul := rm.userLock(user.ID)
	ul.Lock()
	defer ul.Unlock()

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
	user, err := rm.freshPlayer(user)
	if err != nil {
		return nil, err
	}
	if user.Chips < bootAmount {
		return nil, NewGameError(CodeInsufficientChips, msgInsufficientToJoin)
	}
	if err := rm.assertUnderEntryCap(user, bootAmount, resolved); err != nil {
		return nil, err
	}
	if err := rm.assertWithinTableBand(user, bootAmount, resolved); err != nil {
		return nil, err
	}

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

// JoinByCode (joinByCode): already_in_room → invalid_room_code (not exactly 8
// letters or digits — owner, 13 Sep 2026; checked before any lookup) →
// room_not_found ("No table with that code") → table_full ("That table is
// full") → insufficient_chips →
// entry cap (skipped for private tables: you were invited) → Join. Neither
// the stake list nor the menu is consulted: any live table can be joined by
// its code. As in QuickJoin, the player's stripe is held from the first check,
// so the chips checked and seated are the wallet read under it.
func (rm *RoomManager) JoinByCode(user Player, code string) (Room, error) {
	ul := rm.userLock(user.ID)
	ul.Lock()
	defer ul.Unlock()

	if err := rm.assertNotSeated(user.ID); err != nil {
		return nil, err
	}
	code = strings.ToUpper(strings.TrimSpace(code))
	if !util.ValidRoomCode(code) {
		return nil, NewGameError(CodeInvalidRoomCode, msgInvalidRoomCode)
	}
	table := rm.GetTableByCode(code)
	if table == nil {
		return nil, NewGameError(CodeRoomNotFound, msgRoomNotFound)
	}
	if table.IsFull() {
		return nil, NewGameError(CodeTableFull, msgThatTableFull)
	}
	user, err := rm.freshPlayer(user)
	if err != nil {
		return nil, err
	}
	if user.Chips < table.BootAmount() {
		return nil, NewGameError(CodeInsufficientChips, msgInsufficientToJoin)
	}
	// A private table is somewhere you were invited, so the cap does not apply.
	if !table.IsPrivate() {
		if err := rm.assertUnderEntryCap(user, table.BootAmount(), table.Category()); err != nil {
			return nil, err
		}
		if err := rm.assertWithinTableBand(user, table.BootAmount(), table.Category()); err != nil {
			return nil, err
		}
	}
	// seat, not Join: this goroutine already holds the stripe, and the wallet
	// has just been read under it.
	if err := rm.seat(table, user, ""); err != nil {
		return nil, err
	}
	return table, nil
}

// SwitchTable (switchTable) moves a seated player sideways: not_in_room if
// unseated; private_table if the current table is private; target = a RANDOM
// other public non-full table with the same boot and category
// (pickRandomTableLocked; owner, 13 Sep 2026 — Node took the fullest), else
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
	target := rm.pickRandomTableLocked(bootAmount, category, current.ID())
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
// wording for the same refusal a moment later). The seat starts from the
// wallet as read under the player's stripe (freshPlayer), not from user.Chips.
func (rm *RoomManager) Join(table Room, user Player, socketID string) error {
	ul := rm.userLock(user.ID)
	ul.Lock()
	defer ul.Unlock()
	user, err := rm.freshPlayer(user)
	if err != nil {
		return err
	}
	return rm.seat(table, user, socketID)
}

// freshPlayer is the account a seat taken from the lobby starts from:
// LoadPlayer's answer when the manager has one, else the Player the caller
// passed. The caller holds the player's stripe, which is the point — see
// RoomManagerOptions.LoadPlayer and WhileUnseated. The read is bounded by
// walletReadTimeout: it holds a stripe other players share, and a pool with no
// connection to give, or a database that has stopped answering, would
// otherwise hold that stripe for as long as it lasted. A seat that moves with
// its player (a switch, a consolidation) never comes through here: the seat's
// own chips are the authority there, and the checkpoint has just banked them.
//
// Before any read, a player whose wallet is still waiting for a write from a
// table they sat at — a settlement the database refused and is retrying
// (owed), or a destroy still settling their seat (departing) — is refused
// settlement_pending, with or without a loader. Read now, the wallet would
// still hold a stake that write is about to take: the seat would start with
// chips the wallet is about to lose, and losing them at the new table would
// clamp the wallet at zero and pay chips that never existed. The look is under
// the stripe, before the read, and that is enough (see settlementOwed): a debit
// cannot be marked owed for a player who is unseated and whose stripe is held.
func (rm *RoomManager) freshPlayer(user Player) (Player, error) {
	rm.mu.Lock()
	unfinished := rm.walletUnfinishedLocked(user.ID)
	rm.mu.Unlock()
	if unfinished {
		return Player{}, NewGameError(CodeSettlementPending, msgSettlementPending)
	}
	if rm.loadPlayer == nil {
		return user, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), walletReadTimeout)
	defer cancel()
	fresh, err := rm.loadPlayer(ctx, user.ID)
	if err != nil {
		return Player{}, err
	}
	if fresh.ID != user.ID {
		return Player{}, fmt.Errorf("load player %s: got account %q", user.ID, fresh.ID)
	}
	return fresh, nil
}

// WhileUnseated runs fn — a change to the player's wallet that may only be
// made in the lobby: a reward, a chip-priced picture — holding that player's
// stripe, and reports whether it ran. It reports false, and fn does not run,
// while the player has a seat — one the index names, or one a table destroy or
// suspend has taken off the index before its last write landed (departing) —
// or while a settlement of a table they have left is still being retried
// (owed): until that write lands, their wallet is not final.
// With the stripe held, that look is also a look at every seat transition of
// theirs that holds the stripe across its gap: a join between reading the
// wallet and reserving the seat, a leave or kick between the index and the
// table, a switch or a consolidation move between one table and the next, a
// chip pack between its credit and its seat top-up.
//
// A look without the lock (GetTableForPlayer, the old IsSeated) is not enough
// because the look and the commit are two moments. A player holding 2,50,000
// bought a 2,00,000 picture while their room:quickJoin had already read the
// wallet: the join reserved its seat after the purchase committed, the seat
// started at 2,50,000 against a wallet of 50,000, and when they lost it the
// checkpoint clamped the wallet at zero and the winner was paid 2,00,000 that
// never existed. Now one of the two runs wholly before the other: the purchase
// finds the seat and is refused, or the join reads the wallet it left.
//
// fn's database work must use the ctx it is handed, bounded by
// walletWorkTimeout — never a request's. pgx gives up on a cancelled context
// at once, even with COMMIT already on the wire, so a client that hung up
// could end fn, and release the stripe, while PostgreSQL was still deciding
// the outcome; a join waiting on the stripe could then read the wallet from
// before a debit that landed a moment later.
//
// fn may do I/O — it is a database transaction — and holding the stripe
// through it blocks only seat transitions of this player (and of whoever
// shares their stripe), never the manager, exactly as a Table call under the
// stripe does. fn must not start a seat transition itself (Join, Leave,
// SwitchTable, …): they take the same stripe, and it would deadlock.
//
// The owed mark covers a player who left a table between hands while the
// database was refusing its settlement. A leave between hands writes nothing,
// so the wallet went on holding the stake they had lost: a 9,800 picture paid
// from a wallet of 10,000, with 9,600 at the seat, left the retry's −400 to
// clamp the wallet at zero, and the winner was paid 200 chips that never
// existed. settlementOwed says why a look under the stripe cannot miss such a
// debit.
func (rm *RoomManager) WhileUnseated(userID string, fn func(ctx context.Context)) bool {
	ul := rm.userLock(userID)
	ul.Lock()
	defer ul.Unlock()
	rm.mu.Lock()
	seated, dropped := rm.seatedTableLocked(userID)
	unfinished := rm.walletUnfinishedLocked(userID)
	rm.mu.Unlock()
	if dropped {
		rm.liveClearSeated(userID)
	}
	if seated != nil || unfinished {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), walletWorkTimeout)
	defer cancel()
	fn(ctx)
	return true
}

// CreateAndJoin is room:create: open a table and seat its creator at it,
// holding the creator's stripe from the first check to the seat. Order:
// already_in_room → for a public table AssertStakeAllowed → AssertTableOffered
// → insufficient_chips → entry cap → table band — then CreateTable and the
// seat (DECISIONS.md §3). A private table forces its boot (requirement 22) and
// checks no chips: it is somewhere its creator invites people to, which is
// also why JoinByCode does not cap it.
//
// The chip checks read the wallet under the stripe (freshPlayer), the same
// wallet the seat starts from. Made on a read taken before the lock, as the
// socket layer used to make them, a lobby purchase or reward committing in
// between could seat the creator below the boot, above the entry cap
// (requirement 30) or outside the table's band. A refused create opens no
// table; a seat refused once the table is open (a shutdown destroying it under
// us) takes the empty table away again rather than leaving it to the sweeper.
func (rm *RoomManager) CreateAndJoin(user Player, opts CreateTableOptions, socketID string) (Room, error) {
	ul := rm.userLock(user.ID)
	ul.Lock()
	defer ul.Unlock()

	if err := rm.assertNotSeated(user.ID); err != nil {
		return nil, err
	}
	category := NormalizeCategory(opts.Category)
	if !opts.IsPrivate {
		if err := rm.AssertStakeAllowed(opts.BootAmount); err != nil {
			return nil, err
		}
		if err := rm.AssertTableOffered(opts.BootAmount, category); err != nil {
			return nil, err
		}
	}
	user, err := rm.freshPlayer(user)
	if err != nil {
		return nil, err
	}
	if !opts.IsPrivate {
		if user.Chips < opts.BootAmount {
			return nil, NewGameError(CodeInsufficientChips, msgInsufficientToJoin)
		}
		if err := rm.assertUnderEntryCap(user, opts.BootAmount, category); err != nil {
			return nil, err
		}
		if err := rm.assertWithinTableBand(user, opts.BootAmount, category); err != nil {
			return nil, err
		}
	}
	table := rm.CreateTable(opts)
	if err := rm.seat(table, user, socketID); err != nil {
		_ = rm.destroyTable(table.ID(), true)
		return nil, err
	}
	return table, nil
}

// seat is Join's body for callers already holding the player's stripe: take
// a hold (refusing already_in_room / table_destroyed / table_full under mu)
// and convert it into the seat.
func (rm *RoomManager) seat(table Room, user Player, socketID string) error {
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
func (rm *RoomManager) seatHeld(table Room, user Player, socketID string) error {
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
		UserID:       user.ID,
		DisplayName:  user.DisplayName,
		AvatarURL:    user.AvatarURL,
		TablePicture: user.TablePicture,
		Chips:        user.Chips,
		SocketID:     socketID,
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
func (rm *RoomManager) Leave(userID, reason string) (Room, error) {
	return rm.leaveFrom(userID, "", reason)
}

// leaveFrom is Leave restricted to one table: with roomID set the player is
// removed only while the index still says they are seated THERE, decided
// under their stripe together with the index deletion. The kick goroutine
// needs exactly this — a check made with GetTableForPlayer and acted on with
// Leave a moment later can straddle a leave + join of the same player and
// take the seat they have just sat down at somewhere else. "" means any
// table (Leave).
func (rm *RoomManager) leaveFrom(userID, roomID, reason string) (Room, error) {
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
func (rm *RoomManager) vacate(userID, reason string) (Room, error) {
	table, _, err := rm.vacateFrom(userID, "", reason)
	return table, err
}

// vacateSeat is vacate for the one caller that needs the seat back: a table
// switch, which has to re-seat the player and must do so with the chips the
// checkpoint just banked rather than the wallet as it was read beforehand.
func (rm *RoomManager) vacateSeat(userID, reason string) (Room, *SeatInfo, error) {
	return rm.vacateFrom(userID, "", reason)
}

// vacateFrom is vacate limited to roomID ("" = wherever they are): the index
// is checked and deleted in one critical section, so the caller's decision
// and the removal cannot be split by another transition of the same player.
func (rm *RoomManager) vacateFrom(userID, roomID, reason string) (Room, *SeatInfo, error) {
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
//
// In db mode it checks nothing: the cap is the matching menu entry's band
// there (tableMaxChips folds it in, and assertWithinTableBand refuses with the
// same code and message), where a table_configs row's own max_chips wins over
// it at the card AND at the door — checked here as well, the settings' cap
// would refuse a player the row lets in.
func (rm *RoomManager) assertUnderEntryCap(user Player, bootAmount int64, category Category) error {
	g := rm.game
	if g.FromDatabase() {
		return nil
	}
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

// tableMinChips / tableMaxChips are the band for one menu entry. The legacy
// ENTRY_CAP_* trio (requirement 30) is folded in here rather than left as a
// second mechanism: it describes exactly one table by category and boot, so
// it is that table's MaxChips, and a band set on the same entry in
// LOBBY_TABLES wins because it is the more specific statement of the two.
func (rm *RoomManager) tableMinChips(entry config.LobbyTable) int64 { return entry.MinChips }

func (rm *RoomManager) tableMaxChips(entry config.LobbyTable) int64 {
	if entry.MaxChips > 0 {
		return entry.MaxChips
	}
	g := rm.game
	if g.EntryCapMaxChips > 0 && entry.BootAmount == g.EntryCapBoot && entry.Category == g.EntryCapCategory {
		return g.EntryCapMaxChips
	}
	return 0
}

// assertWithinTableBand refuses a seat to a stack the table is not for.
//
// Checked on every route in rather than only in the lobby: the lobby shows a
// card as shut, but a client is never what enforces a rule — a modified or
// simply stale build would otherwise walk straight past it.
//
// Both ends are exclusive of the limit itself, which is how the rules were
// written: "more than 5 Cr cannot enter" lets exactly 5 Cr in, and "50 Cr or
// more" lets exactly 50 Cr in. With no menu configured (tests pass an empty
// LobbyTables to mean "any table") there is no band to apply.
func (rm *RoomManager) assertWithinTableBand(user Player, bootAmount int64, category Category) error {
	for _, entry := range rm.game.LobbyTables {
		if entry.BootAmount != bootAmount || entry.Category != string(category) {
			continue
		}
		if min := rm.tableMinChips(entry); min > 0 && user.Chips < min {
			return Errorf(CodeBelowTableMinimum, msgBelowTableMinFormat, formatThousands(min))
		}
		if max := rm.tableMaxChips(entry); max > 0 && user.Chips > max {
			return Errorf(CodeOverEntryCap, msgOverEntryCapFormat, formatThousands(max))
		}
		return nil
	}
	return nil
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
			// Off the index without the player's stripe, and not yet written
			// through: Destroy settles a live hand below, and the wallet is
			// still waiting for that write. Until Destroy returns, a lobby
			// change or a lobby seat counts the player as still here
			// (departing).
			rm.departing[userID]++
		}
	}
	delete(rm.tables, roomID)
	delete(rm.order, roomID)
	delete(rm.pending, roomID)
	delete(rm.draining, roomID)
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
	err := table.Destroy()
	// Destroy settled the live hand on the actor before it returned: the write
	// landed, or the database refused it and the table reported it owed
	// (settlementOwed), a mark that holds until a retry lands or is given up.
	// Either way the departing mark has done its work. The same owed marks
	// cover a player who left this table earlier while one of its settlements
	// was retrying, whom no departing mark could name. A Destroy that failed (a
	// panic recovered on the actor) has left nothing to wait for either.
	rm.clearDeparting(unseated)
	if err != nil && !errors.Is(err, ErrTableDestroyed) {
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

// clearDeparting ends the departing marks destroyTable set for userIDs, once
// Destroy has returned.
func (rm *RoomManager) clearDeparting(userIDs []string) {
	rm.mu.Lock()
	defer rm.mu.Unlock()
	for _, userID := range userIDs {
		if rm.departing[userID]--; rm.departing[userID] <= 0 {
			delete(rm.departing, userID)
		}
	}
}

// settlementOwed is every table's TableOptions.SettlementOwed: it counts, per
// player, the refused hand-end settlements still being retried that move
// their wallet — a non-zero delta; a zero-delta row only records an outcome,
// and that wallet is already final.
//
// Why the manager has to know. A player can leave a table between hands while
// the database is refusing its settlement, and a leave between hands writes
// nothing, so their wallet goes on holding the stake they lost until a retry
// lands. The index no longer seats them, and departing covers only a table
// destroyed or suspended under its players, so a lobby debit of that wallet,
// or a lobby seat started from it, used to go through — and the late negative
// delta then clamped the wallet at zero and paid the winner chips that never
// existed. While the count is above zero, WhileUnseated refuses and
// freshPlayer refuses settlement_pending.
//
// Why a look under the player's stripe is enough. A retry chain begins on the
// actor inside endHand, and a debit can only be in it for a player the table
// still held when the hand ended: seated in the index; off it inside a
// transition that holds their stripe — whose RemovePlayer the actor runs only
// after endHand, so the stripe is let go only after the mark is set; or taken
// off by a destroy, whose departing mark is set with the index deletion and
// cleared only after Destroy (and so endHand) has returned. A player found
// unseated, not departing and owing nothing, with their stripe held, cannot
// therefore acquire a pending debit before the look's decision is carried out,
// and a mark is cleared only after the write it stands for has returned. A
// pending CREDIT can be marked for a player who has already gone — the winner
// of a hand everyone left (ALL_LEFT) — but a credit landing late cannot clamp
// anything: at worst a seat starts without it and the wallet ends up higher.
//
// It runs on a table's actor, or on its clock's goroutine for a retry that
// outlived the table: mu only, briefly, and never anything that waits on a
// table.
func (rm *RoomManager) settlementOwed(req SettleRequest, owed bool) {
	rm.mu.Lock()
	defer rm.mu.Unlock()
	for _, entry := range req.Entries {
		if entry.Delta == 0 {
			continue
		}
		if owed {
			rm.owed[entry.UserID]++
			continue
		}
		if rm.owed[entry.UserID]--; rm.owed[entry.UserID] <= 0 {
			delete(rm.owed, entry.UserID)
		}
	}
}

// walletUnfinishedLocked reports whether the player's wallet is still waiting
// for a write from a table they sat at: a destroy or suspend still settling or
// handing on their seat (departing), or a refused settlement still being
// retried (owed). The caller holds mu.
func (rm *RoomManager) walletUnfinishedLocked(userID string) bool {
	return rm.departing[userID] > 0 || rm.owed[userID] > 0
}

// ConsolidateTables (consolidateTables; requirement 24) merges public idle
// tables (state waiting, no hand, exactly one player) of the same
// "category:boot" onto the OLDEST undrained one of the group (by CreatedAt,
// ties by creation order), moving one player at a time with movePlayer until
// the target is full. Returns the moves made.
//
// Two rooms each left with one player are two rooms where nobody can play,
// so the stragglers are pulled together onto one table. Only idle tables
// are touched: a table with a hand in progress is never disturbed, which is
// what stops a player being moved out from under a live game.
//
// A draining table (RoomManager.draining) may be a SOURCE, but never the
// target of a player from an undrained one. Matchmaking sends nobody onto
// rules the lobby no longer offers; but a lone player a restart left on such
// rules is exactly who requirement 24 is for, and with the drained tables
// left out of the merge they could never meet the fresh table quick-join
// opens beside them, nor — once their pair has left the menu — each other.
// So:
//
//   - The target is the group's oldest UNDRAINED single, and every other
//     single goes there as before. One from a drained table goes only when
//     its stack is one the lobby would seat at that pair now
//     (admitsFromDrained: the band, the env entry cap, a poker room's
//     buy-in), which movePlayer does not check; otherwise it stays put.
//   - The drained singles still alone after that — every one of them when the
//     group has no undrained single (the pair left the menu, or nobody has
//     quick-joined it since the restart), else those the target would not
//     admit or had no seat for — merge among themselves: each goes onto the
//     oldest of them playing by the same frozen rules (RulesSpec, compared in
//     whole milliseconds as drainReason compares them), so nobody is moved
//     onto rules they were not already playing by. The pair, and so the band,
//     is the same at both ends, and the target stays drained.
//
// Emptied, a drained source is destroyed by movePlayer like any other, and
// its draining mark goes with it (destroyTable).
func (rm *RoomManager) ConsolidateTables() ([]PlayerMove, error) {
	rm.mu.Lock()
	var singles []Room
	drained := map[string]bool{}
	for _, t := range rm.tablesLocked() {
		if !t.IsPrivate() && !t.HasHand() && t.State() == TableWaiting && t.PlayerCount() == 1 {
			singles = append(singles, t)
			if rm.draining[t.ID()] {
				drained[t.ID()] = true
			}
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
	groups := map[string][]Room{}
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
		var target Room
		for _, t := range group {
			if !drained[t.ID()] {
				target = t
				break
			}
		}
		// stranded is every drained single not moved onto target, oldest first.
		var stranded []Room
		for _, source := range group {
			if source == target {
				continue
			}
			if target == nil || target.IsFull() {
				if drained[source.ID()] {
					stranded = append(stranded, source)
				}
				continue
			}
			var admit func(chips int64) bool
			if drained[source.ID()] {
				admit = func(chips int64) bool { return rm.admitsFromDrained(target, chips) }
			}
			move, err := rm.movePlayer(source, target, admit)
			if err != nil {
				return moves, err
			}
			if move != nil {
				moves = append(moves, *move)
			} else if drained[source.ID()] {
				stranded = append(stranded, source)
			}
		}
		merged, err := rm.mergeDrained(stranded)
		moves = append(moves, merged...)
		if err != nil {
			return moves, err
		}
	}
	return moves, nil
}

// mergeDrained is ConsolidateTables for the drained singles of one group that
// are still alone (stranded, oldest first): each goes onto the oldest of them
// playing by the same frozen rules, until that one is full. Rules are
// compared as drainReason compares them — RulesSpec in whole milliseconds,
// SameRules — and read from each room's frozen config, lock-free.
func (rm *RoomManager) mergeDrained(stranded []Room) ([]PlayerMove, error) {
	moves := []PlayerMove{}
	type head struct {
		room  Room
		rules config.TableSpec
	}
	var heads []head
	for _, source := range stranded {
		rules := wholeMillis(source.RulesSpec())
		var target Room
		for _, h := range heads {
			if h.rules.SameRules(rules) {
				target = h.room
				break
			}
		}
		if target == nil {
			heads = append(heads, head{room: source, rules: rules})
			continue
		}
		if target.IsFull() {
			continue
		}
		move, err := rm.movePlayer(source, target, nil)
		if err != nil {
			return moves, err
		}
		if move != nil {
			moves = append(moves, *move)
		}
	}
	return moves, nil
}

// admitsFromDrained reports whether a player holding chips may be moved by a
// consolidation from a draining table onto target, an undrained table of the
// same pair. They sat down under a configuration the lobby no longer offers,
// and movePlayer checks nothing a lobby door checks, so the door's checks for
// target's pair are made here, on the stack the seat holds: the band
// (assertWithinTableBand, the entry cap folded in), the env entry cap
// (assertUnderEntryCap, a no-op in db mode) and a poker room's buy-in
// (RulesSpec().MinBuyIn, 0 at a Teen Patti table). The buy-in is checked
// rather than left to the room: its AddPlayer would refuse and movePlayer's
// failure path would put the player back, but only after taking them off
// their table and seating them again — announced to the table as a departure
// and an arrival — on every sweep. Chips a top-up adds after this look are
// the chips of a player who bought while seated, which no band speaks to.
// Lock-free: the immutable config and target's frozen config only.
func (rm *RoomManager) admitsFromDrained(target Room, chips int64) bool {
	p := Player{Chips: chips}
	category, boot := target.Category(), target.BootAmount()
	if rm.assertUnderEntryCap(p, boot, category) != nil || rm.assertWithinTableBand(p, boot, category) != nil {
		return false
	}
	return chips >= target.RulesSpec().MinBuyIn
}

// movePlayer (_movePlayer): sole occupant of source → target. Bail (nil) if
// no seat, either table has a hand, target is full, or admit (nil = anyone)
// refuses the chips the seat holds. Player built from the seat (chips = seat
// chips), socketId kept. source.RemovePlayer(id, "moved"); delete
// playerRooms (holding the target seat at the same time); Join(target) — on
// failure (the target was destroyed under us, or refused the player: a poker
// room's buy-in) log `table consolidation failed, restoring seat` and
// Join(source) back.
// If source is now empty → DestroyTable(source). RoomListener.OnPlayerMoved;
// log `player moved to a busier table`.
//
// Event order for a successful move is Node's: the source's own events (seat
// vacated, chat, state), then the target's (seat filled, chat, maybe the
// start countdown, state), then OnTableDestroyed(source), then
// OnPlayerMoved — so a mover's room:closed always precedes room:moved /
// room:joined (DECISIONS.md §1).
func (rm *RoomManager) movePlayer(source, target Room, admit func(chips int64) bool) (*PlayerMove, error) {
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
	if admit != nil && !admit(seats[0].Chips) {
		rm.log.Debug("table consolidation skipped: the player's stack is not one the table admits",
			"userId", seats[0].UserID, "fromRoomId", source.ID(), "toRoomId", target.ID())
		return nil, nil
	}
	seat := seats[0]
	player := Player{
		ID:           seat.UserID,
		DisplayName:  seat.DisplayName,
		AvatarURL:    seat.AvatarURL,
		TablePicture: seat.TablePicture,
		Chips:        seat.Chips,
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

	vacated, err := source.RemovePlayer(player.ID, LeaveReasonMoved)
	if err != nil {
		rm.releaseHold(target.ID())
		ul.Unlock()
		if errors.Is(err, ErrTableDestroyed) {
			return nil, nil
		}
		return nil, err
	}
	// The seat above was read before the stripe was taken, and a chip pack's
	// seat top-up (CreditBoughtChips) holds the stripe, so one can have landed
	// in between. Carry the chips the seat held when it was given up, as
	// SwitchTable does.
	if vacated != nil {
		player.Chips = vacated.Chips
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
		var destroyed []Room
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
func (h *tableHooks) OnVariationSelecting(v *View, e VariationSelectingEvent) {
	h.rm.tl.OnVariationSelecting(v, e)
}
func (h *tableHooks) OnVariationSelected(v *View, e VariationSelectedEvent) {
	h.rm.tl.OnVariationSelected(v, e)
}

// OnKick removes the player in a new goroutine — see the type comment. The
// Table only announces the kick; this is where the seat is actually vacated
// (Node: the socket layer's `table.on('kick')`, which ran synchronously
// right after the emit and so always found the player still on the kicking
// table — the Go guard requires exactly that, so a kick that lands after the
// player has already left and sat down elsewhere does not follow them).
func (h *tableHooks) OnKick(v *View, e KickEvent) {
	h.rm.tl.OnKick(v, e)
	h.rm.kickHook(v.ID(), e)
}

// kickHook is OnKick's family-neutral body: the removal, in a new goroutine,
// for a Teen Patti table and a factory-built room alike (roomHooks).
func (rm *RoomManager) kickHook(roomID string, e KickEvent) {
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
	h.rm.persistErrorHook(v.ID(), e)
	h.rm.tl.OnPersistError(v, e)
}

// persistErrorHook is OnPersistError's log line, for every family.
func (rm *RoomManager) persistErrorHook(roomID string, e PersistErrorEvent) {
	var errText any // Node: error?.message
	if e.Err != nil {
		errText = e.Err.Error()
	}
	switch e.Reason {
	case PersistReasonLiveSave, PersistReasonLiveChat, PersistReasonLiveDelete:
		rm.log.Warn("live store write failed", "roomId", roomID, "reason", e.Reason, "error", errText)
	default:
		rm.log.Warn("table write refused", "roomId", roomID, "reason", e.Reason, "error", errText)
	}
}

// OnError logs at error and forwards. A *FencedError (the live store refused
// a save with live.ErrStale: another process owns the table) additionally
// destroys the table — in a new goroutine, DestroyTable posts to the actor
// delivering this event. Its viewers get room:closed and find their seats
// again on the owning process.
func (h *tableHooks) OnError(v *View, err error) {
	h.rm.errorHook(v.ID(), err)
	h.rm.tl.OnError(v, err)
}

// errorHook is OnError's family-neutral body: the log line and, for a fence,
// the destroy in a goroutine of its own.
func (rm *RoomManager) errorHook(roomID string, err error) {
	text := ""
	if err != nil {
		text = err.Error()
	}
	rm.log.Error("table error", "roomId", roomID, "error", text)
	var fenced *FencedError
	if errors.As(err, &fenced) {
		go func() {
			if derr := rm.DestroyTable(roomID); derr != nil {
				rm.log.Error("fenced table could not be destroyed", "roomId", roomID, "error", derr.Error())
			}
		}()
	}
}

// roomHooks is the RoomHooks every factory-built room is given (RoomDeps):
// the family-neutral half of tableHooks, so a poker room's kicks, refused
// writes, fences and index publishes are handled exactly as a Teen Patti
// table's are. The room delivers its own game events to its own listener (the
// socket layer) itself.
type roomHooks struct {
	rm *RoomManager
}

var _ RoomHooks = (*roomHooks)(nil)

func (h *roomHooks) OnRoomState(r Room)                             { h.rm.publishFromActor(r) }
func (h *roomHooks) OnRoomKick(r Room, e KickEvent)                 { h.rm.kickHook(r.ID(), e) }
func (h *roomHooks) OnRoomPersistError(r Room, e PersistErrorEvent) { h.rm.persistErrorHook(r.ID(), e) }
func (h *roomHooks) OnRoomError(r Room, err error)                  { h.rm.errorHook(r.ID(), err) }

// String makes a PlayerMove readable in logs and test failures.
func (m PlayerMove) String() string {
	return fmt.Sprintf("%s: %s → %s", m.UserID, m.FromRoomID, m.ToRoomID)
}
