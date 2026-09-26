// Package xp keeps the XP that play TIME earns (owner, 26 Sep 2026: "game
// duration will be stored in redis not in postgres … then backend can update
// its xp in pg async"; 27 Sep 2026: "Play 15 active minutes +3 XP · Play 60
// active minutes +20 XP · Play 120 active minutes +50 XP … 1 time … After 24
// hours this will be reset, so user can claim this again").
//
// A hand's own XP — the winner's "Win by …" — is awarded by the hand-end
// settle inside its ledger transaction (db.Ledger), which also opens or rolls
// the XP window of every player who completed the hand and says which window
// that is (SettledHand.Windows). What that settle leaves behind is the hand's
// duration: after it commits, Tracker.Settled adds it, for every player it
// resolved, to their play in that window in the LIVE store (live.PlayClock,
// never PostgreSQL), and when the hand carries the window's play past a mark
// some PLAY_TIME source is earned at — 15, 60 and 120 minutes as seeded — the
// database is asked to award whatever the play has reached
// (db.XP.AwardPlayTime), asynchronously: in a goroutine with its own context,
// never on a table's actor and under no lock, tried up to Retries times. The
// database counts each source's claims in the window (player_xp_claims), so
// asking twice never grants twice; a player whose award failed every try is
// asked again at their next hand end. After any award that changed a
// player's XP, their socket is told (player:level).
package xp

import (
	"context"
	"log/slog"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/live"
)

// Awarder is the award door for the play-time sources: db.XP.
type Awarder interface {
	// AwardPlayTime awards userID every PLAY_TIME source their play in the
	// window that opened at windowStart has reached and that they have not
	// yet earned in it, and returns their standing after it and whether
	// their XP changed.
	AwardPlayTime(ctx context.Context, userID string, windowStart int64, play time.Duration) (db.Standing, bool, error)
	// PlayMarks are the minutes of window play at which some PLAY_TIME
	// source is earned, ascending, and how long a window lasts.
	PlayMarks(ctx context.Context) ([]time.Duration, time.Duration, error)
}

// Options builds a Tracker.
type Options struct {
	// Awards makes the asynchronous awards (production: db.XP).
	Awards Awarder
	// Live is the live store; its PlayClock (live.PlayClockOf) keeps the play
	// time. A store without one keeps none, and play time earns nothing.
	Live live.Store
	// Push tells a player their new standing (socket.Handler.PushPlayerLevel).
	// nil → nobody is told.
	Push func(userID string, level db.Standing)
	// Logger nil → slog.Default().
	Logger *slog.Logger
	// Clock nil → time.Now.
	Clock func() time.Time
	// Retries is how many times an award is tried before the player is left
	// for their next hand end (default 3); Backoff the pause after the first
	// failure, grown by the attempt number (0 → 200 ms, negative → none);
	// Timeout bounds each store or database call (default 5 s).
	Retries int
	Backoff time.Duration
	Timeout time.Duration
	// MarksFor is how long the play marks read from the database are used
	// before they are read again (default a minute): an owner's edit to a
	// PLAY_TIME source reaches the tracker within it.
	MarksFor time.Duration
}

// Tracker is the play-time half of XP. Safe for concurrent use.
type Tracker struct {
	awards   Awarder
	live     live.Store
	push     func(userID string, level db.Standing)
	log      *slog.Logger
	clock    func() time.Time
	retries  int
	backoff  time.Duration
	timeout  time.Duration
	marksFor time.Duration

	wg      sync.WaitGroup
	noClock atomic.Bool // the "no play clock" warning was logged

	mu      sync.Mutex
	marks   []time.Duration // the play marks, as last read
	marksAt time.Time       // when they were read (zero: never)
	owed    map[string]bool // players whose last award failed every try
}

// New builds a Tracker.
func New(opts Options) *Tracker {
	t := &Tracker{
		awards: opts.Awards, live: opts.Live, push: opts.Push, log: opts.Logger, clock: opts.Clock,
		retries: opts.Retries, backoff: opts.Backoff, timeout: opts.Timeout, marksFor: opts.MarksFor,
		owed: map[string]bool{},
	}
	if t.log == nil {
		t.log = slog.Default()
	}
	if t.clock == nil {
		t.clock = time.Now
	}
	if t.retries <= 0 {
		t.retries = 3
	}
	switch {
	case t.backoff == 0:
		t.backoff = 200 * time.Millisecond
	case t.backoff < 0:
		t.backoff = 0
	}
	if t.timeout <= 0 {
		t.timeout = 5 * time.Second
	}
	if t.marksFor <= 0 {
		t.marksFor = time.Minute
	}
	return t
}

// Settled is db.Ledger's OnSettled hook, called on the table's actor right
// after a hand-end settlement committed: it tells every player whose XP the
// settlement changed their new standing, and hands the hand's play time to a
// goroutine of its own (recordPlay). It never blocks on the live store or the
// database.
func (t *Tracker) Settled(h db.SettledHand) {
	if t.push != nil {
		ids := make([]string, 0, len(h.Levels))
		for userID := range h.Levels {
			ids = append(ids, userID)
		}
		sort.Strings(ids)
		for _, userID := range ids {
			t.push(userID, h.Levels[userID])
		}
	}
	if h.PlayedMs <= 0 || len(h.Players) == 0 || h.Window <= 0 {
		return
	}
	clock, ok := live.PlayClockOf(t.live)
	if !ok {
		if t.noClock.CompareAndSwap(false, true) {
			t.log.Warn("xp play time is not kept: the live store has no play clock, so the play-time XP is never earned",
				"store", kind(t.live))
		}
		return
	}
	type played struct {
		userID      string
		windowStart int64
	}
	players := make([]played, 0, len(h.Players))
	for _, userID := range h.Players {
		if start := h.Windows[userID]; start > 0 {
			players = append(players, played{userID, start})
		}
	}
	if len(players) == 0 {
		return
	}
	play := time.Duration(h.PlayedMs) * time.Millisecond
	t.wg.Add(1)
	go func() {
		defer t.wg.Done()
		marks := t.playMarks()
		for _, p := range players {
			t.recordPlay(clock, marks, p.userID, p.windowStart, play, h.Window)
		}
	}()
}

// playMarks are the play marks, read again once they are MarksFor old. A read
// that fails keeps the last ones (nil before any read — and then every hand
// end asks the database, which is right, only slower).
func (t *Tracker) playMarks() []time.Duration {
	t.mu.Lock()
	fresh := !t.marksAt.IsZero() && t.clock().Sub(t.marksAt) < t.marksFor
	marks := t.marks
	t.mu.Unlock()
	if fresh {
		return marks
	}
	ctx, cancel := context.WithTimeout(context.Background(), t.timeout)
	read, _, err := t.awards.PlayMarks(ctx)
	cancel()
	if err != nil {
		t.log.Warn("xp play marks not read; the last ones are used", "error", err.Error())
		return marks
	}
	if read == nil {
		read = []time.Duration{}
	}
	t.mu.Lock()
	t.marks, t.marksAt = read, t.clock()
	t.mu.Unlock()
	return read
}

// recordPlay adds a hand's play to one player's window and, when it carries
// the window's play past a mark (or the player's last award failed), asks the
// database for what the play has reached. A failure to record is logged and
// costs that hand's play; it is never retried (the store's own round trip
// already was, and the next hand adds its own).
func (t *Tracker) recordPlay(clock live.PlayClock, marks []time.Duration, userID string, windowStart int64, play, window time.Duration) {
	ttl := time.UnixMilli(windowStart).Add(window).Sub(t.clock())
	if ttl <= 0 {
		return // the window has already ended: its play counts for nothing
	}
	ctx, cancel := context.WithTimeout(context.Background(), t.timeout)
	before, after, err := clock.AddPlayTime(ctx, userID, windowStart, play, ttl)
	cancel()
	if err != nil {
		t.log.Warn("xp play time not recorded", "userId", userID, "playMs", play.Milliseconds(), "error", err.Error())
		return
	}
	t.mu.Lock()
	owed := t.owed[userID]
	t.mu.Unlock()
	if !owed && !crosses(marks, before, after) {
		return
	}
	t.award(userID, windowStart, after)
}

// crosses says whether play from before to after reaches a mark it had not —
// or, with no marks known yet (nil), whether there was any play at all.
func crosses(marks []time.Duration, before, after time.Duration) bool {
	if marks == nil {
		return after > before
	}
	for _, mark := range marks {
		if before < mark && mark <= after {
			return true
		}
	}
	return false
}

// award asks for the play's awards, trying up to Retries times; when every
// try fails the player is owed another asking at their next hand end, and a
// WARN says so.
func (t *Tracker) award(userID string, windowStart int64, play time.Duration) {
	var lastErr error
	for attempt := 1; attempt <= t.retries; attempt++ {
		ctx, cancel := context.WithTimeout(context.Background(), t.timeout)
		level, changed, err := t.awards.AwardPlayTime(ctx, userID, windowStart, play)
		cancel()
		if err == nil {
			t.mu.Lock()
			delete(t.owed, userID)
			t.mu.Unlock()
			if changed && t.push != nil {
				t.push(userID, level)
			}
			return
		}
		lastErr = err
		if attempt < t.retries && t.backoff > 0 {
			time.Sleep(t.backoff * time.Duration(attempt))
		}
	}
	t.mu.Lock()
	t.owed[userID] = true
	t.mu.Unlock()
	t.log.Warn("xp play-time award failed; it is asked for again at the player's next hand end",
		"userId", userID, "attempts", t.retries, "error", lastErr.Error())
}

// Wait blocks until every goroutine Settled has started has finished, or ctx
// is done (its error then). Shutdown calls it so a restart does not cut an
// award off halfway.
func (t *Tracker) Wait(ctx context.Context) error {
	done := make(chan struct{})
	go func() {
		t.wg.Wait()
		close(done)
	}()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// kind is the live store's Kind for a log line, "none" without one.
func kind(s live.Store) string {
	if s == nil {
		return "none"
	}
	return s.Kind()
}
