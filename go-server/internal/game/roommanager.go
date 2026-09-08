package game

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
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
	// BootAmount 0 → config.Game.BootAmount. Ignored (forced to PrivateBoot)
	// when IsPrivate.
	BootAmount int64
	IsPrivate  bool
	// Category is normalised: anything but "blind" is seen.
	Category string
}

// QuickJoinOptions ← quickJoin(user, {bootAmount, category}).
type QuickJoinOptions struct {
	BootAmount int64  // 0 → config.Game.BootAmount
	Category   string // normalised
}

// ListOptions ← listTables({includePrivate, category}).
type ListOptions struct {
	IncludePrivate bool
	// Category "" → all.
	Category Category
}

// SwitchResult ← switchTable's `{from, table}`.
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
}

// RoomManagerOptions builds a RoomManager.
type RoomManagerOptions struct {
	// Game and Chat are the config sections roomManager.js reads
	// (config.game.*, config.chat.maxHistory/maxLength).
	Game config.GameConfig
	Chat config.ChatConfig
	// Ledger is handed to every Table. Production: db.Ledger. Tests: a
	// MemoryLedger. Required.
	Ledger Ledger
	Clock  Clock // nil → RealClock{}
	// TableListener receives every Table's events (the socket layer). The
	// RoomManager wraps it (see tableHooks) so that it can act on OnKick,
	// OnPersistError and OnError itself, then forwards every call unchanged.
	// nil → NopListener.
	TableListener Listener
	// Listener receives room-level events. nil → NopRoomListener.
	Listener RoomListener
	Logger   *slog.Logger // nil → slog.Default()
	Metrics  MetricsHooks
}

// RoomManager owns every live table in this process (roomManager.js).
//
// # Locking (PORT_PLAN.md decision 5)
//
// mu protects ONLY tables and playerRooms. It is NEVER held while calling
// into a Table (every Table method may block on the actor, which may be
// inside a Ledger write). Pattern for every method: lock → look up / decide
// → unlock → call the table → lock again to record the result if needed.
// Join/QuickJoin/JoinByCode RESERVE playerRooms[userId] = roomId under the
// lock BEFORE AddPlayer (so a concurrent second join is refused with
// already_in_room) and delete the reservation if AddPlayer fails.
//
// Table events that need the RoomManager (OnKick → Leave; a table emptied by
// a hand → destroy/sweep) are handled in a NEW goroutine, never on the
// actor, because Leave posts to the same table.
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

	mu          sync.Mutex
	tables      map[string]*Table // roomId → table
	playerRooms map[string]string // userId → roomId

	sweeperStop chan struct{}
	sweeperOnce sync.Once
}

// NewRoomManager builds the manager. It does NOT start the sweeper — call
// StartSweeper (the app does; unit tests usually do not).
func NewRoomManager(opts RoomManagerOptions) *RoomManager {
	panic("not ported: game.NewRoomManager")
}

// StartSweeper runs ConsolidateTables then SweepEmptyTables every
// config.Game.ConsolidateInterval in a background goroutine until Shutdown
// (Node: unref'd setInterval in the constructor). Errors are logged as
// `table sweep failed`. Safe to call once.
func (rm *RoomManager) StartSweeper() {
	panic("not ported: (*RoomManager).StartSweeper")
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
	panic("not ported: (*RoomManager).AssertStakeAllowed")
}

// AssertTableOffered (static assertTableOffered): with LobbyTables non-empty
// the (boot, category) PAIR must be on the menu, else table_not_offered
// ("The lobby offers: seen 200, blind 200, blind 5000").
func (rm *RoomManager) AssertTableOffered(bootAmount int64, category Category) error {
	panic("not ported: (*RoomManager).AssertTableOffered")
}

// CreateTable opens a table (createTable / _createTable), timed into
// Metrics.ObserveCreation. Rules:
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
//   - id util.UUID(), code util.RoomCode(6), Listener = rm's tableHooks.
//
// Registers the table, calls RoomListener.OnTableCreated, logs `table
// created {roomId, code, bootAmount, category, isPrivate, maxPot}`.
func (rm *RoomManager) CreateTable(opts CreateTableOptions) *Table {
	panic("not ported: (*RoomManager).CreateTable")
}

// GetTable returns the table or nil.
func (rm *RoomManager) GetTable(roomID string) *Table {
	panic("not ported: (*RoomManager).GetTable")
}

// GetTableByCode matches the upper-cased code, or nil.
func (rm *RoomManager) GetTableByCode(code string) *Table {
	panic("not ported: (*RoomManager).GetTableByCode")
}

// GetTableForPlayer returns the table the user is seated at (via
// playerRooms), or nil.
func (rm *RoomManager) GetTableForPlayer(userID string) *Table {
	panic("not ported: (*RoomManager).GetTableForPlayer")
}

// ListTables returns summaries of the (public unless IncludePrivate) tables,
// optionally filtered by category. Collects the *Table set under the lock,
// then calls Summary() on each OUTSIDE it.
func (rm *RoomManager) ListTables(opts ListOptions) []TableSummary {
	panic("not ported: (*RoomManager).ListTables")
}

// LobbyOptions builds the menu from config (static lobbyOptions()).
func (rm *RoomManager) LobbyOptions() LobbyOptions {
	panic("not ported: (*RoomManager).LobbyOptions")
}

// LiveTables returns every table (for metric gauges: players online, active /
// waiting games, tables{category,stake}). The gauges read only lock-free
// getters on the result.
func (rm *RoomManager) LiveTables() []*Table {
	panic("not ported: (*RoomManager).LiveTables")
}

// QuickJoin (quickJoin) seats a player, creating a table if every one at the
// stake is full. Order of checks: already_in_room → AssertStakeAllowed →
// NormalizeCategory → AssertTableOffered → insufficient_chips (chips < boot,
// "Not enough chips to join this table") → entry cap. Candidate = the
// FULLEST public non-full table with the same boot AND category (ties: any),
// else CreateTable. Then Join.
func (rm *RoomManager) QuickJoin(user Player, opts QuickJoinOptions) (*Table, error) {
	panic("not ported: (*RoomManager).QuickJoin")
}

// JoinByCode (joinByCode): already_in_room → room_not_found ("No table with
// that code") → table_full ("That table is full") → insufficient_chips →
// entry cap (skipped for private tables: you were invited) → Join.
func (rm *RoomManager) JoinByCode(user Player, code string) (*Table, error) {
	panic("not ported: (*RoomManager).JoinByCode")
}

// SwitchTable (switchTable) moves a seated player sideways: not_in_room if
// unseated; private_table if the current table is private; target = fullest
// OTHER public non-full table with the same boot and category, else
// no_other_table ("No other <category> table at this stake has a free seat
// right now"). The entry cap is deliberately NOT applied (requirement 30
// guards the lobby door only). Then Leave(userId, "moved") — "moved" skips
// the consolidation sweep — and Join(target). Failure happens BEFORE the seat
// is given up.
func (rm *RoomManager) SwitchTable(user Player) (SwitchResult, error) {
	panic("not ported: (*RoomManager).SwitchTable")
}

// Join (join) seats `user` at `table`: already_in_room unless unseated;
// reserve playerRooms under the lock; table.AddPlayer; on error remove the
// reservation and return it. socketID may be "".
func (rm *RoomManager) Join(table *Table, user Player, socketID string) error {
	panic("not ported: (*RoomManager).Join")
}

// Leave (leave) removes a player: nil, nil when unseated. Deletes
// playerRooms FIRST (nothing that happens while the removal settles may
// still find them seated), then table.RemovePlayer(userId, reason). If the
// table is now empty → DestroyTable; else if reason != "moved" →
// ConsolidateTables (a departure is exactly when a table can drop to one
// player). Returns the table left.
func (rm *RoomManager) Leave(userID, reason string) (*Table, error) {
	panic("not ported: (*RoomManager).Leave")
}

// DestroyTable (destroyTable): under the lock, delete every seated user's
// playerRooms entry and the table itself (out of the map BEFORE the possibly
// slow settlement so nobody is seated at a table on its way out); then
// table.Destroy(); RoomListener.OnTableDestroyed; log `table destroyed`.
// No-op for an unknown id.
func (rm *RoomManager) DestroyTable(roomID string) error {
	panic("not ported: (*RoomManager).DestroyTable")
}

// ConsolidateTables (consolidateTables; requirement 24) merges public idle
// tables (state waiting, no hand, exactly one player) of the same
// "category:boot" onto the OLDEST of the group (by CreatedAt), moving one
// player at a time with movePlayer until the target is full. Returns the
// moves made.
func (rm *RoomManager) ConsolidateTables() ([]PlayerMove, error) {
	panic("not ported: (*RoomManager).ConsolidateTables")
}

// movePlayer (_movePlayer): sole occupant of source → target. Bail (nil) if
// no seat, either table has a hand, or target is full. Player built from the
// seat (chips = seat chips), socketId kept. source.RemovePlayer(id,
// "moved"); delete playerRooms; Join(target) — on failure (it filled up)
// log `table consolidation failed, restoring seat` and Join(source) back.
// If source is now empty → DestroyTable(source). RoomListener.OnPlayerMoved;
// log `player moved to a busier table`.
func (rm *RoomManager) movePlayer(source, target *Table) (*PlayerMove, error) {
	panic("not ported")
}

// SweepEmptyTables (sweepEmptyTables) destroys tables that are empty, waiting
// and older than a HARDCODED 30 seconds (Node: `Date.now() - 30_000`).
func (rm *RoomManager) SweepEmptyTables() error {
	panic("not ported: (*RoomManager).SweepEmptyTables")
}

// Stats is rooms.stats().
func (rm *RoomManager) Stats() Stats {
	panic("not ported: (*RoomManager).Stats")
}

// Shutdown stops the sweeper and destroys every table in turn (settling live
// hands — their pots are paid out — before the caller closes the pool). ctx
// bounds the wait; Node gave the whole shutdown 8 s before process.exit(1).
func (rm *RoomManager) Shutdown(ctx context.Context) error {
	panic("not ported: (*RoomManager).Shutdown")
}

// tableHooks is the Listener every Table is built with. It forwards every
// event to the app-supplied TableListener unchanged and additionally:
//
//   - OnKick: `go func(){ if rm.GetTableForPlayer(uid) != nil { if err :=
//     rm.Leave(uid, reason); err != nil { log "kick failed"; return };
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

func (h *tableHooks) OnState(v *View)                           { h.rm.tl.OnState(v) }
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

// OnKick removes the player in a new goroutine — see the type comment.
func (h *tableHooks) OnKick(v *View, e KickEvent) {
	panic("not ported: (*tableHooks).OnKick")
}

// OnPersistError logs at warn and forwards.
func (h *tableHooks) OnPersistError(v *View, e PersistErrorEvent) {
	panic("not ported: (*tableHooks).OnPersistError")
}

// OnError logs at error and forwards.
func (h *tableHooks) OnError(v *View, err error) {
	panic("not ported: (*tableHooks).OnError")
}
