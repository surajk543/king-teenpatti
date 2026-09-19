package game

// Room is one table of ANY game family as everything outside the rules engine
// sees it: the RoomManager (lobby, matchmaking, consolidation, the seat index,
// restore and suspend), the socket layer (joins, per-viewer snapshots, chat,
// reconnects), the metrics gauges and /health. *Table — Teen Patti — satisfies
// it as it stands; a poker room (internal/poker) satisfies it too, which is how
// one RoomManager holds both families and the one-seat-per-wallet invariant
// (CLAUDE.md §5.1) covers both (POKER_PLAN.md §4). The method set is exactly
// what those callers use, no more: anything a caller needs from ONE family it
// gets by a type assertion (AsTable), never through this interface.
//
// Every method is safe from any goroutine. The "lock-free" group reads atomics
// the room's actor maintains; the rest post to that actor and wait, and answer
// ErrTableDestroyed once the room is gone.

import (
	"context"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/live"
)

// Room is documented above.
type Room interface {
	// ---- identity and configuration (immutable, lock-free) ----
	ID() string
	Code() string
	Category() Category
	// Game is Category().Game(): the family whose engine runs this room.
	Game() Game
	IsPrivate() bool
	// BootAmount is the room's stake: the boot of a Teen Patti table, the big
	// blind or the ante of a poker one. It is the ONE routing key beside the
	// category — menu, matchmaking bucket, stack band, resume offer.
	BootAmount() int64
	// MaxPot is the pot cap, 0 when uncapped (poker rooms are always 0).
	MaxPot() int64
	MaxPlayers() int
	CreatedAt() time.Time

	// ---- state (lock-free atomics) ----
	PlayerCount() int
	IsFull() bool
	IsEmpty() bool
	HasHand() bool
	State() TableState
	Version() int64
	LiveSeq() int64
	Fenced() bool
	Destroyed() bool

	// ---- posted reads ----
	// ViewFor is the viewer's REDACTED snapshot as the socket layer sends it
	// (room:joined / room:state): *TableView for Teen Patti, *poker.View for a
	// poker room. It is `any` because the two shapes share nothing a caller
	// could act on; the socket layer only serialises it.
	ViewFor(viewerID string) (any, error)
	Summary() (TableSummary, error)
	Seats() ([]SeatInfo, error)
	FindSeat(userID string) (*SeatInfo, error)
	ChatHistory() ([]ChatMessage, error)

	// ---- mutations ----
	AddPlayer(p NewPlayer) (*SeatInfo, error)
	RemovePlayer(userID, reason string) (*SeatInfo, error)
	SetConnected(userID string, connected bool, socketID string) (*SeatInfo, error)
	SetAvatar(userID string, avatarURL *string) error
	CreditChips(userID string, amount int64) bool
	PostChat(userID, text string) (*ChatMessage, error)
	SaveLive() error
	// Settled posts a no-op and waits: every mutation queued before it has run.
	Settled() error
	Destroy() error
	Suspend() error

	// ---- settlements still owed after Destroy or Suspend ----
	PendingSettlements() int
	WaitSettlements(ctx context.Context) error
	SettlementsLanded() []string

	// ---- restore (RoomManager.Restore) ----
	// RestoreChat loads the mirrored chat log onto a restored room.
	RestoreChat(history []ChatMessage) error
	// Resume re-arms a restored room's clocks against the current time. The
	// RoomManager calls it once the room is registered, so a timeout or kick
	// that fires at once finds the player indexed.
	Resume() error
}

var _ Room = (*Table)(nil)

// AsTable is the Teen Patti table behind a Room, or nil when the room is of
// another family. The socket layer's Teen Patti-only events (game:action,
// game:sideshowRespond, game:selectVariation, player:requestCards) use it and
// refuse anything else with wrong_game; tests use it to reach the rules engine.
func AsTable(r Room) *Table {
	t, _ := r.(*Table)
	return t
}

// RoomSpec is what a RoomFactory is asked to open: the identity and stake
// the RoomManager chose (the code is already unique among live rooms).
type RoomSpec struct {
	ID         string
	Code       string
	Category   Category
	BootAmount int64
	IsPrivate  bool
}

// RoomDeps is everything a room of any family is built with — the same
// objects every *Table gets through RoomManager.tableOptions, so a poker room
// settles through the same Ledger, saves to the same live store and reports
// to the same manager.
type RoomDeps struct {
	Game  config.GameConfig
	Chat  config.ChatConfig
	Clock Clock
	// Ledger is the money: the three checkpoints of CLAUDE.md §5.1.
	Ledger Ledger
	// Live is the live-state store (nil → nothing saved); LiveTTL its expiry;
	// LiveErrors the failed-call hook (TableOptions.LiveErrors).
	Live       live.Store
	LiveTTL    time.Duration
	LiveErrors func(op string, err error)
	// ObserveHandStart is game_hand_start_duration_seconds (may be nil).
	ObserveHandStart func(d time.Duration)
	// SettlementOwed is TableOptions.SettlementOwed: the manager's count of
	// refused hand-end settlements still being retried, per player.
	SettlementOwed func(req SettleRequest, owed bool)
	// Hooks is the manager's side of the room's events (RoomHooks). A room
	// delivers each to its own game-family listener (the socket layer) AND to
	// these, on its actor.
	Hooks RoomHooks
}

// RoomHooks is what the RoomManager needs to hear from a room of any family,
// on the room's actor goroutine — the family-neutral half of tableHooks. None
// of them may call back into the room; the manager acts on a kick or a fence
// in a goroutine of its own.
type RoomHooks interface {
	// OnRoomState: observable state changed (player count, lifecycle state) —
	// the manager republishes the room to the matchmaking index when it did.
	OnRoomState(r Room)
	// OnRoomKick: the room wants a seat vacated (idle / insufficient_chips).
	// The room only ANNOUNCES it; the manager removes the player and tells the
	// socket layer through RoomListener.OnPlayerKicked.
	OnRoomKick(r Room, e KickEvent)
	// OnRoomPersistError: a ledger or live-store write failed (logged).
	OnRoomPersistError(r Room, e PersistErrorEvent)
	// OnRoomError: a settlement was abandoned, or the room was fenced
	// (*FencedError, on which the manager destroys it).
	OnRoomError(r Room, err error)
}

// RestoredRoom is what a RoomFactory.Restore learned from the stored document
// the manager needs for its index and its report.
type RestoredRoom struct {
	// Seats are the user ids of every seat the document held, in seat order.
	Seats []string
	// HandID is the live hand's id, "" between hands.
	HandID string
}

// RoomFactory opens and restores the rooms of one game family other than Teen
// Patti (which the RoomManager builds itself). The app wires one per family
// into RoomManagerOptions.Factories; package game never imports a family.
type RoomFactory interface {
	// New builds a fresh room for spec, ready to be registered. It starts the
	// room's actor but never posts to it (it is called under the manager's
	// mutex, exactly as NewTable is).
	New(spec RoomSpec, deps RoomDeps) (Room, error)
	// Restore rebuilds a room from a stored document of this family WITHOUT
	// arming a clock — the manager registers it, restores its chat and then
	// calls Room.Resume — or refuses it with an error, on which the manager
	// drops the document from the store exactly as it drops a Teen Patti
	// snapshot it cannot rebuild.
	Restore(data []byte, deps RoomDeps) (Room, RestoredRoom, error)
	// MenuEntry fills in the family-specific fields of a lobby menu entry for
	// a LOBBY_TABLES line of this family (blinds, ante, buy-in, hole cards…).
	// The category, boot and stack band are already set.
	MenuEntry(entry config.LobbyTable, g config.GameConfig, option *LobbyTableOption)
}

// storedRoomHeader is the peek every stored document gets before a parser is
// chosen (RoomManager.restoreFromLive): the family, and the two fields the
// restore order needs. A Teen Patti snapshot has no `game` key.
type storedRoomHeader struct {
	Game      Game   `json:"game"`
	RoomID    string `json:"roomId"`
	CreatedAt int64  `json:"createdAt"`
}
