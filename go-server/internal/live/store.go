// Package live is the FAST / TEMPORARY half of the server's storage:
//
//	Internet → Go server (game engine, websocket)
//	              ├── Redis      live table state · presence · turn deadlines · matchmaking   (this package)
//	              └── PostgreSQL users · wallets · chip_ledger · hands · audit             (internal/db)
//
// Everything in here is reconstructable and may be lost without losing money:
// the authoritative record of every chip is the ledger in PostgreSQL. What the
// live store buys is (1) the per-move JSONB snapshot no longer rides inside the
// money transaction, and (2) a restarted server rebuilds every table, holds the
// seats for the reconnect grace period and lets the hands continue instead of
// dropping them.
//
// Two implementations satisfy Store: Redis (production; REDIS_URL set) and an
// in-process map (REDIS_URL empty: development, unit tests, and the fallback
// that keeps a single instance working exactly as before Redis existed).
//
// Concurrency: every method is safe for concurrent use; Table actors call
// SaveTable from their own goroutine, the socket layer calls presence methods
// from handler goroutines. Methods take a context and never block indefinitely.
package live

import (
	"context"
	"errors"
	"time"
)

var (
	// ErrNotFound is returned by Load/Take methods when the key is absent.
	ErrNotFound = errors.New("live: not found")
	// ErrStale is returned by SaveTable when the stored sequence number is
	// already >= the one offered — another writer owns this table.
	ErrStale = errors.New("live: stale sequence")
)

// TableRef identifies a stored table snapshot.
type TableRef struct {
	RoomID string
	Seq    int64
}

// TableSummary is what the matchmaking index holds per table: enough for
// quick-join to pick a table and for the lobby list, never any cards or
// hidden chips.
type TableSummary struct {
	RoomID     string `json:"roomId"`
	Code       string `json:"code"`
	Category   string `json:"category"`
	BootAmount int64  `json:"bootAmount"`
	Players    int    `json:"players"`
	MaxPlayers int    `json:"maxPlayers"`
	IsPrivate  bool   `json:"isPrivate"`
	State      string `json:"state"`     // waiting | starting | betting | showdown
	CreatedAt  int64  `json:"createdAt"` // epoch ms
	Instance   string `json:"instance"`  // which server process owns the table
}

// ResumeOffer is the table a lapsed seat is offered back (session:ready.resume).
type ResumeOffer struct {
	RoomID     string `json:"roomId"`
	Code       string `json:"code"`
	Category   string `json:"category"`
	BootAmount int64  `json:"bootAmount"`
	At         int64  `json:"at"` // epoch ms when the seat lapsed
}

// Playing is the record a seated player's friends are shown (Friends V1,
// owner 26 Sep 2026): what KIND of table they sit at, never which one. It is
// the value of kt:playing:<userId>, written beside the seat mirror by
// SetSeated and deleted with it by ClearSeated, and it carries no room id, no
// code and nothing about the hand — only the game family and the variant:
//
//	{"game":"TEEN_PATTI","variant":"SEEN","updatedAt":1790000000000}
//
// Game is TEEN_PATTI or POKER; Variant is the table's category upper-cased
// (SEEN, BLIND, VARIATION, THREE_CARD_POKER, FIVE_CARD_DRAW, TEXAS_HOLDEM,
// OMAHA) — game.PlayingAt is the one place that mapping lives. UpdatedAt is
// the epoch ms of the write (a store stamps it when the caller leaves it 0).
type Playing struct {
	Game      string `json:"game"`
	Variant   string `json:"variant"`
	UpdatedAt int64  `json:"updatedAt"`
}

// Presence is one account's presence as the live store holds it — the raw
// facts, before any rule is applied to them:
//
//   - Online: kt:online holds an unexpired entry for the account (a live
//     socket on some instance, refreshed by the socket layer's heartbeat);
//   - Playing: kt:playing:<userId> exists, the account has a seat — Game,
//     Variant and UpdatedAt are then the record's (empty otherwise).
//
// Status resolves the two into what a friend is shown.
type Presence struct {
	Online    bool
	Playing   bool
	Game      string
	Variant   string
	UpdatedAt int64
}

// Presence statuses, the wire's `status` (GET /api/friends, the friend
// profile).
const (
	StatusPlaying = "PLAYING"
	StatusOnline  = "ONLINE"
	StatusOffline = "OFFLINE"
)

// Status is PLAYING when the account has a seat — whatever its socket is
// doing: a player inside the reconnect grace (RECONNECT_GRACE_MS) has no
// socket and no kt:online entry, and is still "Playing now" rather than
// flickering offline until the seat lapses — else ONLINE when kt:online is
// live, else OFFLINE.
func (p Presence) Status() string {
	switch {
	case p.Playing:
		return StatusPlaying
	case p.Online:
		return StatusOnline
	default:
		return StatusOffline
	}
}

// IsOnline is the wire's `online`: true whenever Status is not OFFLINE, so a
// PLAYING account in its reconnect grace reads online as well.
func (p Presence) IsOnline() bool { return p.Online || p.Playing }

// Store is the live-state contract. Implementations: Redis (redis.go) and
// Memory (memory.go).
type Store interface {
	// ---- live table state -------------------------------------------------
	// SaveTable stores the table's full snapshot (game.Snapshot JSON, cards
	// included — server side only, never sent to a client) under a strictly
	// increasing per-table sequence number. It fails with ErrStale when the
	// stored seq is >= seq, which is the guard against two processes owning
	// one table. ttl bounds how long a table that stops updating survives.
	SaveTable(ctx context.Context, roomID string, seq int64, snapshot []byte, ttl time.Duration) error
	// LoadTable returns the latest snapshot and its seq, or ErrNotFound.
	LoadTable(ctx context.Context, roomID string) (seq int64, snapshot []byte, err error)
	// DeleteTable forgets a table (destroyed, or refunded on startup).
	DeleteTable(ctx context.Context, roomID string) error
	// ListTables enumerates every stored table. It is O(tables) — one round
	// trip per table on Redis — so it belongs ONLY on the startup restore and
	// in the periodic reconcile, never on a request path. Use CountTables for
	// a number.
	ListTables(ctx context.Context) ([]TableRef, error)
	// CountTables is how many tables the store holds, in one O(1) call.
	// /health reports this: it wants a number, not a listing. The count can
	// briefly include a table whose snapshot expired but whose index entry has
	// not been swept yet; ListTables repairs that, and the reconciler runs it.
	CountTables(ctx context.Context) (int, error)

	// ---- chat (per table, capped) -----------------------------------------
	// AppendChat pushes one serialised chat message and trims to max entries.
	AppendChat(ctx context.Context, roomID string, message []byte, max int) error
	// LoadChat returns the stored messages oldest first.
	LoadChat(ctx context.Context, roomID string) ([][]byte, error)
	// DeleteChat forgets a table's chat.
	DeleteChat(ctx context.Context, roomID string) error

	// ---- presence ----------------------------------------------------------
	// SetSeated / ClearSeated / SeatOf mirror RoomManager's userId → roomId
	// index so a restarted (or second) process knows who sits where.
	//
	// SetSeated writes the seat key (kt:seat:<userId>, no ttl) AND the
	// player's playing record beside it (kt:playing:<userId>, Playing JSON,
	// expiring after playingTTL; playingTTL <= 0 means no expiry) in one
	// atomic round trip — the record lives and dies with the seat mirror, so
	// every place the manager mirrors a seat writes it and every rewrite (a
	// move, a restore, the reconciler's refresh) renews it. A zero Playing
	// (Game "") writes the seat alone and removes any playing record.
	// ClearSeated deletes both keys in one command.
	SetSeated(ctx context.Context, userID, roomID string, playing Playing, playingTTL time.Duration) error
	ClearSeated(ctx context.Context, userID string) error
	SeatOf(ctx context.Context, userID string) (roomID string, err error) // ErrNotFound when not seated
	// ListSeats returns every mirrored seat entry (userId → roomId). Seat
	// entries have no ttl — they are cleared by whoever wrote them — so this
	// is what lets RoomManager.ReconcileLive delete the ones no live table
	// accounts for and heal a leak instead of accumulating one. Never nil.
	ListSeats(ctx context.Context) (map[string]string, error)
	// SetOnline records a live socket for the user on this instance; the entry
	// expires after ttl unless refreshed (heartbeat), so a crashed process
	// leaves no ghosts. SetOffline removes it. OnlineCount is scrape-time.
	SetOnline(ctx context.Context, userID, instance string, ttl time.Duration) error
	SetOffline(ctx context.Context, userID string) error
	OnlineCount(ctx context.Context) (int, error)
	// Presence reads, for every id asked about, whether its kt:online entry
	// is live and the playing record it holds — batched, one round trip on
	// Redis (HMGET kt:online + MGET kt:playing:*, pipelined) whatever the
	// number of ids. The map has one entry per distinct id asked about (the
	// zero Presence for an account with neither); never nil. The friends
	// endpoints call it for a whole friend list at once.
	Presence(ctx context.Context, userIDs []string) (map[string]Presence, error)

	// ---- resume offers -----------------------------------------------------
	// PutResumeOffer stores the offer for ttl (RESUME_OFFER_MS); TakeResumeOffer
	// returns and deletes it atomically (offered once), or ErrNotFound.
	PutResumeOffer(ctx context.Context, userID string, offer ResumeOffer, ttl time.Duration) error
	TakeResumeOffer(ctx context.Context, userID string) (ResumeOffer, error)
	DeleteResumeOffer(ctx context.Context, userID string) error

	// ---- matchmaking index -------------------------------------------------
	// PublishTable upserts the table in the lobby index (sorted by Players
	// within its category:boot bucket); RetireTable removes it; Candidates
	// lists a bucket's public tables, fullest first (ties: oldest first).
	PublishTable(ctx context.Context, t TableSummary) error
	RetireTable(ctx context.Context, roomID, category string, bootAmount int64) error
	Candidates(ctx context.Context, category string, bootAmount int64) ([]TableSummary, error)
	// ListSummaries returns every published summary, whichever bucket it is
	// indexed in — the sweep side of RetireTable, for the same reason
	// ListSeats exists. Never nil.
	ListSummaries(ctx context.Context) ([]TableSummary, error)

	// ---- lifecycle ---------------------------------------------------------
	Ping(ctx context.Context) error
	Close() error
	// Kind is "redis" or "memory" — for /health and logs.
	Kind() string
}

// Options configures Open.
type Options struct {
	// URL is REDIS_URL (redis://[:password@]host:port/db). Empty → Memory.
	URL string
	// Instance identifies this server process in presence/matchmaking entries
	// (hostname:pid by default).
	Instance string
	// KeyPrefix namespaces every key (default "kt:"); tests use a random one
	// so suites can share one Redis.
	KeyPrefix string
	// Timeout bounds each round trip (default 500 ms).
	Timeout time.Duration
}

// Open returns a Redis-backed Store when opts.URL is set and a Memory store
// otherwise. Open pings Redis once and fails fast when it is unreachable.
func Open(ctx context.Context, opts Options) (Store, error) {
	if opts.URL == "" {
		return NewMemory(), nil
	}
	return OpenRedis(ctx, opts)
}
