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

// PlayMark is one threshold of active play in a player's XP window (owner,
// 26 Sep 2026: "30 minutes active gameplay 5 · 60 minutes active gameplay 15").
// Field is the kt:xpday hash field that records who has claimed it; At the
// play time that reaches it.
type PlayMark struct {
	Field string
	At    time.Duration
}

// The two play marks: 30 and 60 minutes of active play in one window. What
// each is worth is the database's business (xp_sources ACTIVE_30_MIN and
// ACTIVE_60_MIN); this package only keeps the time and who claimed a mark.
const (
	PlayMark30 = "a30"
	PlayMark60 = "a60"
)

// PlayMarks is every mark AddPlayTime claims, in order of play. A fresh slice
// each call.
func PlayMarks() []PlayMark {
	return []PlayMark{{Field: PlayMark30, At: 30 * time.Minute}, {Field: PlayMark60, At: 60 * time.Minute}}
}

// PlayTime is AddPlayTime's answer: the window's opening, its play time after
// the call, and the marks THIS call claimed (PlayMark.Field, in PlayMarks
// order; never nil).
type PlayTime struct {
	Start   time.Time
	Play    time.Duration
	Claimed []string
}

// PlayClock is the live store's XP play time (owner, 26 Sep 2026: "game
// duration will be stored in redis not in postgres"): per player, the active
// play in their current XP window and which play marks have been claimed in
// it — never PostgreSQL's business. A store that implements it is where a
// server keeps the play time the 30- and 60-minute XP is earned by; a store
// that does not keeps none, and those two sources are then never earned.
// Memory implements it; PlayClockOf finds it behind a WithHooks wrapper.
type PlayClock interface {
	// AddPlayTime adds play to the active play in userID's current XP window —
	// a record {start, playMs, a30, a60} — opening the window (start = now,
	// gone window after it) when there is none, and claims every PlayMarks
	// mark the window's play has reached and nobody has claimed in it.
	// Atomic: of calls that carry the play past a mark together, exactly one
	// claims it. A play of 0 or less adds nothing (and still opens a window).
	AddPlayTime(ctx context.Context, userID string, play time.Duration, now time.Time, window time.Duration) (PlayTime, error)
	// ClearPlayMark releases a mark (PlayMark.Field) AddPlayTime claimed in
	// userID's window — its award failed — so the next AddPlayTime at or past
	// it claims it again. No window, or a mark not claimed: a no-op.
	ClearPlayMark(ctx context.Context, userID, mark string) error
}

// PlayClockOf is s's PlayClock — s itself, or the store a WithHooks wrapper
// (anything with Unwrap() Store) decorates — and whether it has one.
func PlayClockOf(s Store) (PlayClock, bool) {
	for s != nil {
		if pc, ok := s.(PlayClock); ok {
			return pc, true
		}
		u, ok := s.(interface{ Unwrap() Store })
		if !ok {
			return nil, false
		}
		s = u.Unwrap()
	}
	return nil, false
}

// ResumeOffer is the table a lapsed seat is offered back (session:ready.resume).
type ResumeOffer struct {
	RoomID     string `json:"roomId"`
	Code       string `json:"code"`
	Category   string `json:"category"`
	BootAmount int64  `json:"bootAmount"`
	At         int64  `json:"at"` // epoch ms when the seat lapsed
}

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
	SetSeated(ctx context.Context, userID, roomID string) error
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
