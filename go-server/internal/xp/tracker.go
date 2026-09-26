// Package xp keeps the XP that play TIME earns (owner, 26 Sep 2026: "30
// minutes active gameplay 5 · 60 minutes active gameplay 15 … game duration
// will be stored in redis not in postgres … once game duration 30, 60 minutes
// complete, then backend can update its xp in pg async").
//
// A hand's own XP — HAND_COMPLETED, HAND_WON and the daily play bonus — is
// awarded by the hand-end settle inside its ledger transaction (db.Ledger).
// What that settle leaves behind is the hand's duration: after it commits,
// Tracker.Settled adds it, for every player it resolved, to their XP window's
// play time in the LIVE store (live.PlayClock, never PostgreSQL), and when the
// window's play first reaches 30 or 60 minutes — a mark exactly one caller
// claims — the ACTIVE_30_MIN or ACTIVE_60_MIN award is made in PostgreSQL
// asynchronously: in a goroutine with its own context, never on a table's
// actor and under no lock, tried up to Retries times; when every try fails the
// mark is released, so the next hand end claims it and tries again. After any
// award that changed a player's XP, their socket is told (player:level).
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
	// Award awards source to userID in a transaction of its own and returns
	// their level after it and whether their XP changed.
	Award(ctx context.Context, userID, source string) (db.PlayerLevel, bool, error)
}

// Options builds a Tracker.
type Options struct {
	// Awards makes the asynchronous awards (production: db.XP).
	Awards Awarder
	// Live is the live store; its PlayClock (live.PlayClockOf) keeps the play
	// time. A store without one keeps none, and play time earns nothing.
	Live live.Store
	// Push tells a player their new level (socket.Handler.PushPlayerLevel).
	// nil → nobody is told.
	Push func(userID string, level db.PlayerLevel)
	// Logger nil → slog.Default().
	Logger *slog.Logger
	// Clock nil → time.Now. The play window opens at its reading.
	Clock func() time.Time
	// Retries is how many times an award is tried before its mark is
	// released (default 3); Backoff the pause after the first failure, grown
	// by the attempt number (0 → 200 ms, negative → none); Timeout bounds
	// each store or database call (default 5 s).
	Retries int
	Backoff time.Duration
	Timeout time.Duration
}

// Tracker is the play-time half of XP. Safe for concurrent use.
type Tracker struct {
	awards  Awarder
	live    live.Store
	push    func(userID string, level db.PlayerLevel)
	log     *slog.Logger
	clock   func() time.Time
	retries int
	backoff time.Duration
	timeout time.Duration

	wg      sync.WaitGroup
	noClock atomic.Bool // the "no play clock" warning was logged
}

// New builds a Tracker.
func New(opts Options) *Tracker {
	t := &Tracker{
		awards: opts.Awards, live: opts.Live, push: opts.Push, log: opts.Logger, clock: opts.Clock,
		retries: opts.Retries, backoff: opts.Backoff, timeout: opts.Timeout,
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
	return t
}

// SourceOf is the xp_sources code a play mark earns: ACTIVE_30_MIN for the
// 30-minute mark, ACTIVE_60_MIN for the 60-minute one, "" for any other.
func SourceOf(mark string) string {
	switch mark {
	case live.PlayMark30:
		return db.XPSourceActive30Min
	case live.PlayMark60:
		return db.XPSourceActive60Min
	}
	return ""
}

// Settled is db.Ledger's OnSettled hook, called on the table's actor right
// after a hand-end settlement committed: it tells every player whose XP the
// settlement changed their new level, and hands the hand's play time to a
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
			t.log.Warn("xp play time is not kept: the live store has no play clock, so the 30- and 60-minute XP is never earned",
				"store", kind(t.live))
		}
		return
	}
	players := append([]string(nil), h.Players...)
	t.wg.Add(1)
	go func() {
		defer t.wg.Done()
		t.recordPlay(clock, players, time.Duration(h.PlayedMs)*time.Millisecond, h.Window)
	}()
}

// recordPlay adds a hand's play to each player's window and awards every mark
// that claimed. A failure to record is logged and costs that hand's play; it
// is never retried (the store's own round trip already was, and the next hand
// adds its own).
func (t *Tracker) recordPlay(clock live.PlayClock, players []string, play, window time.Duration) {
	now := t.clock()
	for _, userID := range players {
		ctx, cancel := context.WithTimeout(context.Background(), t.timeout)
		pt, err := clock.AddPlayTime(ctx, userID, play, now, window)
		cancel()
		if err != nil {
			t.log.Warn("xp play time not recorded", "userId", userID, "playMs", play.Milliseconds(), "error", err.Error())
			continue
		}
		for _, mark := range pt.Claimed {
			t.award(clock, userID, mark)
		}
	}
}

// award makes a claimed mark's award, trying up to Retries times; when every
// try fails the mark is released for the next hand end, and a WARN says so.
func (t *Tracker) award(clock live.PlayClock, userID, mark string) {
	source := SourceOf(mark)
	if source == "" {
		return
	}
	var lastErr error
	for attempt := 1; attempt <= t.retries; attempt++ {
		ctx, cancel := context.WithTimeout(context.Background(), t.timeout)
		level, changed, err := t.awards.Award(ctx, userID, source)
		cancel()
		if err == nil {
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
	ctx, cancel := context.WithTimeout(context.Background(), t.timeout)
	clearErr := clock.ClearPlayMark(ctx, userID, mark)
	cancel()
	attrs := []any{"userId", userID, "source", source, "attempts", t.retries, "error", lastErr.Error()}
	if clearErr != nil {
		attrs = append(attrs, "releaseError", clearErr.Error())
	}
	t.log.Warn("xp active-play award failed; the mark is released for the next hand end", attrs...)
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
