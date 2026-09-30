// Package sim is BOT_MODE=simulation: an in-process stand-in for the game
// server, so the fleet can be run and watched with no server, no accounts
// and no real currency, reproducibly from a seed.
//
// It is a TEST HARNESS, not a game engine: it plays a simplified Teen Patti
// (boot, deal, blind/seen ladder, see, chaal, raise, pack, show, a sideshow,
// a variation window, a round cap and a pot cap) close enough to exercise
// every bot decision, state transition, table move and reconnect, and it
// speaks the server's wire shapes (go-server/internal/game/view.go,
// internal/socket/wire.go) so the bots run the same code path as against the
// real server. The real server's rules are the only rules; nothing here is
// ever used to decide a real hand.
//
// # Shape
//
// One actor goroutine owns every account, table and session: every REST
// call, dial and inbound message is a closure posted to it, so nothing needs
// a lock and a run is race-free by construction. Time is read only through
// Config.Clock, and every timer — turn clocks, the next deal, the reconnect
// grace, the simulated latency of each message — is an entry in one ordered
// queue (deadline, then insertion order) that the actor drains when the one
// clock timer it keeps armed fires. With a clock.Fake the whole simulation
// therefore moves only when the test advances the clock, and in the same
// order every time. The actor never blocks on a bot: each connection's
// events go into a bounded buffer, and a connection whose buffer fills is
// dropped, as a real server disconnects a client that stops reading.
//
// # Determinism
//
// Every draw comes from rng streams derived from Config.Seed: one per table
// for its shuffles (by the table's creation number), one per connection for
// its latency (by account id and connection count), one for the connection
// drops. Account ids, tokens, table ids and codes are hashes of the seed. Two
// runs with the same seed, the same clock and the same inputs in the same
// order produce the same hands.
//
// # What is simplified (the real server is the authority)
//
//   - No PostgreSQL, no Redis, no checkpoints: an account's wallet IS its
//     seat's stack while seated, so chips are conserved exactly (Stats.Chips
//     == Stats.Minted at all times).
//   - Variation tables offer six variations (FIVE_CARD is omitted, as the
//     real server omits it when the deck cannot cover the top-up) and play
//     them all with the classic ranking — no wild cards — except MUFLIS, which
//     compares the other way round. game:selectCards is always not_picking.
//   - No Force Sideshow and no missile: canForceSideshow and canMissile are
//     always false and the moves are refused no_hammers / no_missiles.
//   - A seat that cannot cover the boot is shown out as the next hand is
//     about to be dealt, with no UNFUNDED_GRACE_MS hold.
//   - No winning tax, no consolidation (room:moved is never sent), no
//     private tables, no emojis (chat:emoji is refused unknown_emoji).
//   - Only what a bot reads is sent: no player:hand, player:cards or
//     chat:history, no hand-end summary, and the account carries the keys
//     of protocol.User alone.
//   - REST calls answer at once; only socket messages carry latency.
package sim

import (
	"container/heap"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"log/slog"
	"sort"
	"strconv"
	"sync"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/clock"
	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// Config is a simulation's setup.
type Config struct {
	Seed          uint64
	Clock         clock.Clock
	Tables        []protocol.TableEntry // the menu; nil → a default Teen Patti menu
	WelcomeChips  int64                 // default 1,000,000
	MaxPlayers    int                   // default 5
	TurnTimeout   time.Duration         // default 25 s
	NextHandDelay time.Duration         // default 4 s
	Latency       [2]time.Duration      // simulated one-way delay range per message; default 5–40 ms; a negative bound = no delay at all
	DropEvery     time.Duration         // if set, drops a random connection this often (reconnect drill)
	Log           *slog.Logger
	// SessionBuffer is how many undelivered events one connection may hold
	// before the simulation drops it, as a real server disconnects a client
	// that stops reading. Default 1024.
	SessionBuffer int
}

// The rules the real server takes from its configuration, at their
// production defaults (CLAUDE.md §7.4).
const (
	minPlayers         = 2
	maxMissedTurns     = 3
	sideshowTimeout    = 6 * time.Second
	sideshowMinPlayers = 3
	variationWindow    = 10 * time.Second
	reconnectGrace     = 60 * time.Second
	resumeOfferFor     = 10 * time.Minute
	bonusChips         = 25_000
	bonusEvery         = 6 * time.Hour
	chatLimit          = 5
	chatWindow         = 5 * time.Second
	chatMaxLength      = 140
	actionLimit        = 30
	actionWindow       = 5 * time.Second
	nameMaxLength      = 24
)

// Salts that keep the seed's derived streams apart.
const (
	saltDeck    = 0x6465636b
	saltLatency = 0x6c6174
	saltDrop    = 0x64726f70
)

var (
	errServerClosed = errors.New("sim: server closed")
	errDropped      = errors.New("sim: connection dropped (DropEvery)")
	errOverflow     = errors.New("sim: event buffer overflow: the client stopped reading")
	errReplaced     = errors.New("sim: session replaced by a newer connection")
)

// Server is the simulated game server.
type Server struct {
	cfg     Config
	clk     clock.Clock
	log     *slog.Logger
	menu    []protocol.TableEntry
	version string
	lat     [2]time.Duration

	inbox     chan func()
	quit      chan struct{}
	stopped   chan struct{}
	closeOnce sync.Once

	// Everything below belongs to the actor goroutine alone.
	tasks      taskHeap
	seq        uint64
	timer      clock.Timer
	timerAt    time.Time
	accounts   map[string]*account // by id
	byDevice   map[string]*account
	byToken    map[string]*account
	tables     []*table // open tables, oldest first
	byCode     map[string]*table
	sessions   map[int]*session
	tableSeq   int
	sessionSeq int
	messageSeq int
	drop       *rng.Rand
	stats      Stats
}

// NewServer starts a simulation.
func NewServer(cfg Config) *Server {
	if cfg.Clock == nil {
		cfg.Clock = clock.Real{}
	}
	if cfg.Log == nil {
		cfg.Log = slog.New(slog.DiscardHandler)
	}
	if cfg.WelcomeChips <= 0 {
		cfg.WelcomeChips = 1_000_000
	}
	if cfg.MaxPlayers <= 0 {
		cfg.MaxPlayers = 5
	}
	cfg.MaxPlayers = max(cfg.MaxPlayers, minPlayers)
	if cfg.TurnTimeout <= 0 {
		cfg.TurnTimeout = 25 * time.Second
	}
	if cfg.NextHandDelay <= 0 {
		cfg.NextHandDelay = 4 * time.Second
	}
	if cfg.SessionBuffer <= 0 {
		cfg.SessionBuffer = 1024
	}
	s := &Server{
		cfg:      cfg,
		clk:      cfg.Clock,
		log:      cfg.Log.With("component", "sim"),
		inbox:    make(chan func(), 256),
		quit:     make(chan struct{}),
		stopped:  make(chan struct{}),
		accounts: map[string]*account{},
		byDevice: map[string]*account{},
		byToken:  map[string]*account{},
		byCode:   map[string]*table{},
		sessions: map[int]*session{},
		drop:     rng.Derive(cfg.Seed^saltDrop, 0),
	}
	switch {
	case cfg.Latency == [2]time.Duration{}:
		s.lat = [2]time.Duration{5 * time.Millisecond, 40 * time.Millisecond}
	case cfg.Latency[0] >= 0 && cfg.Latency[1] >= 0:
		s.lat = [2]time.Duration{min(cfg.Latency[0], cfg.Latency[1]), max(cfg.Latency[0], cfg.Latency[1])}
	}
	s.menu, s.version = buildMenu(cfg)
	if cfg.DropEvery > 0 {
		s.after(cfg.DropEvery, s.dropOne)
	}
	s.log.Info("simulation started", "seed", cfg.Seed, "tables", len(s.menu),
		"latencyMs", [2]int64{s.lat[0].Milliseconds(), s.lat[1].Milliseconds()})
	go s.loop()
	return s
}

// Stats is a summary for logs and tests.
type Stats struct {
	Accounts, Tables, HandsDealt, HandsCompleted, Moves, Refusals, Drops int
	// Chips is every wallet plus every pot in play; Minted is every chip the
	// simulation has created (welcome chips and bonuses). They are equal at
	// all times — the conservation check.
	Chips, Minted int64
}

// Stats reports what the simulation has done so far.
func (s *Server) Stats() Stats {
	var st Stats
	if s.do(func() { st = s.snapshot() }) != nil {
		<-s.stopped // the actor has gone, so its state can be read from here
		st = s.snapshot()
	}
	return st
}

func (s *Server) snapshot() Stats {
	st := s.stats
	st.Accounts, st.Tables, st.Chips = len(s.accounts), len(s.tables), 0
	for _, a := range s.accounts {
		st.Chips += a.chips
	}
	for _, t := range s.tables {
		if t.hand != nil {
			st.Chips += t.hand.pot
		}
	}
	return st
}

// Close ends every connection and stops the simulation.
func (s *Server) Close() {
	s.closeOnce.Do(func() { close(s.quit) })
	<-s.stopped
}

// ---- the actor ----

func (s *Server) loop() {
	defer close(s.stopped)
	for {
		var wake <-chan time.Time
		if s.timer != nil {
			wake = s.timer.C()
		}
		select {
		case fn := <-s.inbox:
			fn()
		case <-wake:
			s.timer = nil
		case <-s.quit:
			for _, c := range s.sessionList() {
				s.closeSession(c, errServerClosed)
			}
			if s.timer != nil {
				s.timer.Stop()
			}
			s.log.Info("simulation stopped", "hands", s.stats.HandsCompleted, "moves", s.stats.Moves)
			return
		}
		s.runDue()
		s.rearm()
	}
}

// do runs fn on the actor and waits for it.
func (s *Server) do(fn func()) error {
	done := make(chan struct{})
	if err := s.post(context.Background(), func() { fn(); close(done) }); err != nil {
		return err
	}
	select {
	case <-done:
		return nil
	case <-s.stopped:
		select {
		case <-done:
			return nil
		default:
			return errServerClosed
		}
	}
}

// post queues fn for the actor without waiting for it to run.
func (s *Server) post(ctx context.Context, fn func()) error {
	select {
	case s.inbox <- fn:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-s.quit:
		return protocol.ErrClosed
	}
}

// call runs fn on the actor and returns its answer, for the REST side.
func call[T any](ctx context.Context, s *Server, fn func() (T, error)) (T, error) {
	var out T
	if err := ctx.Err(); err != nil {
		return out, err
	}
	var ferr error
	if err := s.do(func() { out, ferr = fn() }); err != nil {
		return out, err
	}
	return out, ferr
}

// ---- the timer queue ----

// task is one entry of the actor's timer queue. A cancelled task stays in
// the heap and is skipped when it comes up.
type task struct {
	at   time.Time
	seq  uint64
	fn   func()
	dead bool
}

func (t *task) cancel() {
	if t != nil {
		t.dead = true
	}
}

type taskHeap []*task

func (h taskHeap) Len() int { return len(h) }
func (h taskHeap) Less(i, j int) bool {
	if !h[i].at.Equal(h[j].at) {
		return h[i].at.Before(h[j].at)
	}
	return h[i].seq < h[j].seq
}
func (h taskHeap) Swap(i, j int) { h[i], h[j] = h[j], h[i] }
func (h *taskHeap) Push(x any)   { *h = append(*h, x.(*task)) }
func (h *taskHeap) Pop() any {
	old := *h
	t := old[len(old)-1]
	*h = old[:len(old)-1]
	return t
}

func (s *Server) now() time.Time { return s.clk.Now() }

func (s *Server) after(d time.Duration, fn func()) *task { return s.schedule(s.now().Add(d), fn) }

func (s *Server) schedule(at time.Time, fn func()) *task {
	s.seq++
	t := &task{at: at, seq: s.seq, fn: fn}
	heap.Push(&s.tasks, t)
	return t
}

// runDue runs every task whose time has come, in deadline order; a task may
// schedule more, which run in the same pass when they are due too.
func (s *Server) runDue() {
	for len(s.tasks) > 0 {
		t := s.tasks[0]
		if !t.dead && t.at.After(s.now()) {
			return
		}
		heap.Pop(&s.tasks)
		if !t.dead {
			t.dead = true
			t.fn()
		}
	}
}

// rearm keeps the one clock timer armed for the earliest live task.
func (s *Server) rearm() {
	for len(s.tasks) > 0 && s.tasks[0].dead {
		heap.Pop(&s.tasks)
	}
	if len(s.tasks) == 0 {
		if s.timer != nil {
			s.timer.Stop()
			s.timer = nil
		}
		return
	}
	at := s.tasks[0].at
	if s.timer != nil && s.timerAt.Equal(at) {
		return
	}
	if s.timer != nil {
		s.timer.Stop()
	}
	s.timer, s.timerAt = s.clk.NewTimer(at.Sub(s.now())), at
}

// ---- identities ----

func (s *Server) digest(parts ...string) []byte {
	h := sha256.New()
	var seed [8]byte
	binary.BigEndian.PutUint64(seed[:], s.cfg.Seed)
	h.Write(seed[:])
	for _, p := range parts {
		h.Write([]byte(p))
		h.Write([]byte{0})
	}
	return h.Sum(nil)
}

// uuid is a UUID-shaped id derived from the seed and parts.
func (s *Server) uuid(parts ...string) string {
	x := hex.EncodeToString(s.digest(parts...)[:16])
	return x[0:8] + "-" + x[8:12] + "-4" + x[13:16] + "-" + x[16:20] + "-" + x[20:32]
}

// roomCode is an 8-character table code, unique among open tables.
func (s *Server) roomCode(serial int) string {
	const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	for n := 0; ; n++ {
		d := s.digest("code", strconv.Itoa(serial), strconv.Itoa(n))
		code := make([]byte, 8)
		for i := range code {
			code[i] = alphabet[int(d[i])%len(alphabet)]
		}
		if s.byCode[string(code)] == nil {
			return string(code)
		}
	}
}

func (s *Server) sessionList() []*session {
	out := make([]*session, 0, len(s.sessions))
	for _, c := range s.sessions {
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].id < out[j].id })
	return out
}

func millis(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.UnixMilli()
}

func ptr[T any](v T) *T { return &v }
