package xp

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/live"
)

// fakeAwards is the database's award door: it records every call as
// "<userId>:<window>:<play minutes>", fails the first failures of them, blocks
// while gate is set, and grants 5 XP a call.
type fakeAwards struct {
	mu        sync.Mutex
	calls     []string
	failures  int
	gate      chan struct{}
	xp        map[string]int64
	marks     []time.Duration
	markReads int
	marksErr  error
}

func (f *fakeAwards) AwardPlayTime(ctx context.Context, userID string, windowStart int64, play time.Duration) (db.Standing, bool, error) {
	f.mu.Lock()
	gate := f.gate
	f.mu.Unlock()
	if gate != nil {
		select {
		case <-gate:
		case <-ctx.Done():
			return db.Standing{}, false, ctx.Err()
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, userID+":"+strconv.FormatInt(windowStart, 10)+":"+strconv.Itoa(int(play/time.Minute)))
	if f.failures > 0 {
		f.failures--
		return db.Standing{}, false, errors.New("database unreachable")
	}
	if f.xp == nil {
		f.xp = map[string]int64{}
	}
	f.xp[userID] += 5
	return db.Standing{PlayerLevel: db.PlayerLevel{Level: 1, XP: f.xp[userID]}}, true, nil
}

func (f *fakeAwards) PlayMarks(ctx context.Context) ([]time.Duration, time.Duration, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.markReads++
	if f.marksErr != nil {
		return nil, 0, f.marksErr
	}
	marks := f.marks
	if marks == nil {
		marks = []time.Duration{15 * time.Minute, time.Hour, 2 * time.Hour}
	}
	return marks, 24 * time.Hour, nil
}

func (f *fakeAwards) callList() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := append([]string(nil), f.calls...)
	sort.Strings(out)
	return out
}

// pushes records what the socket layer would have been told.
type pushes struct {
	mu   sync.Mutex
	seen []string // "<userId>:<xp>"
}

func (p *pushes) push(userID string, level db.Standing) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.seen = append(p.seen, userID+":"+strconv.FormatInt(level.PlayerLevel.XP, 10))
}

func (p *pushes) list() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]string(nil), p.seen...)
}

// syncBuffer is a log sink safe to read while goroutines write to it.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.String()
}

func wait(t *testing.T, tr *Tracker) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := tr.Wait(ctx); err != nil {
		t.Fatal(err)
	}
}

// windowNow is a window that opened a minute ago, as the settle reports it.
func windowNow() int64 { return time.Now().Add(-time.Minute).UnixMilli() }

// TestAHandEndTellsThePlayersAndAsksAtEachMark: the settled hand's standings
// are pushed at once, its play is added to each player's window in the live
// store, and the database is asked only when a hand carries a player's play
// past a mark — 15, 60 and 120 minutes — and told when it changed their XP.
func TestAHandEndTellsThePlayersAndAsksAtEachMark(t *testing.T) {
	store := live.NewMemory()
	t.Cleanup(func() { _ = store.Close() })
	awards, told := &fakeAwards{}, &pushes{}
	tr := New(Options{Awards: awards, Live: store, Push: told.push, Backoff: -1})
	w := windowNow()
	windows := map[string]int64{"a": w, "b": w}
	hand := func(played time.Duration, levels map[string]db.Standing, players ...string) {
		tr.Settled(db.SettledHand{HandID: "h", Players: players, Windows: windows, Levels: levels,
			PlayedMs: played.Milliseconds(), Window: 24 * time.Hour})
		wait(t, tr)
	}
	ws := strconv.FormatInt(w, 10)

	hand(10*time.Minute, map[string]db.Standing{"b": {PlayerLevel: db.PlayerLevel{XP: 6}}, "a": {PlayerLevel: db.PlayerLevel{XP: 7}}}, "a", "b")
	if got := told.list(); !reflect.DeepEqual(got, []string{"a:7", "b:6"}) {
		t.Fatalf("the hand's own XP is told at once, in order: %v", got)
	}
	if len(awards.callList()) != 0 {
		t.Fatal("10 minutes of play reaches no mark")
	}
	pc, _ := live.PlayClockOf(store)
	if _, after, _ := pc.AddPlayTime(context.Background(), "a", w, 0, time.Hour); after != 10*time.Minute {
		t.Fatalf("the play is kept in the live store, in the window: %v", after)
	}

	hand(6*time.Minute, nil, "a", "b")
	if got := awards.callList(); !reflect.DeepEqual(got, []string{"a:" + ws + ":16", "b:" + ws + ":16"}) {
		t.Fatalf("16 minutes crosses 15: %v", got)
	}
	hand(30*time.Minute, nil, "a") // 46: no mark
	hand(14*time.Minute, nil, "a") // 60: the hour
	hand(70*time.Minute, nil, "a") // 130: two hours
	if got := awards.callList(); !reflect.DeepEqual(got, []string{"a:" + ws + ":130", "a:" + ws + ":16", "a:" + ws + ":60", "b:" + ws + ":16"}) {
		t.Fatalf("a's marks: %v", got)
	}
	if got := told.list(); len(got) != 6 {
		t.Fatalf("every award that changed the XP is told: %v", got)
	}
	// A hand with no play time, no players, no window, or players whose window
	// the settle did not name records nothing.
	for _, h := range []db.SettledHand{
		{Players: []string{"a"}, Windows: windows, PlayedMs: 0, Window: time.Hour},
		{Windows: windows, PlayedMs: int64(time.Hour / time.Millisecond), Window: time.Hour},
		{Players: []string{"a"}, Windows: windows, PlayedMs: int64(time.Hour / time.Millisecond)},
		{Players: []string{"c"}, Windows: windows, PlayedMs: int64(time.Hour / time.Millisecond), Window: time.Hour},
	} {
		tr.Settled(h)
	}
	wait(t, tr)
	if len(awards.callList()) != 4 {
		t.Fatalf("nothing more: %v", awards.callList())
	}
	// A window that has already ended counts no play.
	old := time.Now().Add(-25 * time.Hour).UnixMilli()
	tr.Settled(db.SettledHand{Players: []string{"d"}, Windows: map[string]int64{"d": old}, PlayedMs: int64(time.Hour / time.Millisecond), Window: 24 * time.Hour})
	wait(t, tr)
	if len(awards.callList()) != 4 {
		t.Fatalf("an ended window: %v", awards.callList())
	}
	// The marks were read once (they are kept a minute).
	if awards.markReads != 1 {
		t.Errorf("the marks were read %d times, want once", awards.markReads)
	}
}

// TestAFailedPlayAwardIsAskedForAgainAtTheNextHandEnd: an award is tried
// Retries times; when every try fails the player is owed another asking, with
// a WARN, and their next hand end asks — mark or no mark.
func TestAFailedPlayAwardIsAskedForAgainAtTheNextHandEnd(t *testing.T) {
	store := live.NewMemory()
	t.Cleanup(func() { _ = store.Close() })
	logs := &syncBuffer{}
	awards := &fakeAwards{failures: 3}
	tr := New(Options{Awards: awards, Live: store, Backoff: -1, Logger: slog.New(slog.NewTextHandler(logs, nil))})
	w := windowNow()
	windows := map[string]int64{"a": w}
	tr.Settled(db.SettledHand{Players: []string{"a"}, Windows: windows, PlayedMs: int64(16 * time.Minute / time.Millisecond), Window: 24 * time.Hour})
	wait(t, tr)
	if got := awards.callList(); len(got) != 3 {
		t.Fatalf("three tries: %v", got)
	}
	if !strings.Contains(logs.String(), "xp play-time award failed") {
		t.Fatalf("the failure is a WARN: %s", logs.String())
	}
	tr.Settled(db.SettledHand{Players: []string{"a"}, Windows: windows, PlayedMs: 1000, Window: 24 * time.Hour})
	wait(t, tr)
	if got := awards.callList(); len(got) != 4 || awards.xp["a"] != 5 {
		t.Fatalf("the next hand end asks again and is awarded: %v", got)
	}
	// Paid, the player is owed nothing: a hand reaching no mark asks nothing.
	tr.Settled(db.SettledHand{Players: []string{"a"}, Windows: windows, PlayedMs: 1000, Window: 24 * time.Hour})
	wait(t, tr)
	if got := awards.callList(); len(got) != 4 {
		t.Fatalf("nothing owed, nothing asked: %v", got)
	}
}

// TestUnreadMarksAskAtEveryHandEnd: when the marks cannot be read the
// tracker asks the database at every hand end (the database knows what has
// been earned), and reads the marks again next time.
func TestUnreadMarksAskAtEveryHandEnd(t *testing.T) {
	store := live.NewMemory()
	t.Cleanup(func() { _ = store.Close() })
	awards := &fakeAwards{marksErr: errors.New("database unreachable")}
	tr := New(Options{Awards: awards, Live: store, Backoff: -1, Logger: slog.New(slog.NewTextHandler(&syncBuffer{}, nil))})
	windows := map[string]int64{"a": windowNow()}
	for range 2 {
		tr.Settled(db.SettledHand{Players: []string{"a"}, Windows: windows, PlayedMs: 60_000, Window: 24 * time.Hour})
		wait(t, tr)
	}
	if got := awards.callList(); len(got) != 2 || awards.markReads != 2 {
		t.Fatalf("asked %v with %d reads, want every hand and a read each", got, awards.markReads)
	}
}

// TestWithoutAPlayClockPlayTimeEarnsNothingAndSaysSoOnce: a live store that
// keeps no play time (or none at all) earns no play marks, logs one WARN for
// the life of the process, and still tells the players their hand's XP.
func TestWithoutAPlayClockPlayTimeEarnsNothingAndSaysSoOnce(t *testing.T) {
	type plain struct{ live.Store }
	inner := live.NewMemory()
	t.Cleanup(func() { _ = inner.Close() })
	for name, store := range map[string]live.Store{"no play clock": plain{inner}, "no store": nil} {
		logs := &syncBuffer{}
		awards, told := &fakeAwards{}, &pushes{}
		tr := New(Options{Awards: awards, Live: store, Push: told.push, Logger: slog.New(slog.NewTextHandler(logs, nil))})
		for i := 0; i < 3; i++ {
			tr.Settled(db.SettledHand{Players: []string{"a"}, Windows: map[string]int64{"a": windowNow()},
				Levels:   map[string]db.Standing{"a": {PlayerLevel: db.PlayerLevel{XP: 1}}},
				PlayedMs: int64(time.Hour / time.Millisecond), Window: 24 * time.Hour})
		}
		wait(t, tr)
		if len(awards.callList()) != 0 {
			t.Errorf("%s: awards %v", name, awards.callList())
		}
		if n := strings.Count(logs.String(), "xp play time is not kept"); n != 1 {
			t.Errorf("%s: the WARN is logged %d times, want once", name, n)
		}
		if len(told.list()) != 3 {
			t.Errorf("%s: the hand's XP is still told: %v", name, told.list())
		}
	}
}

// TestWaitReturnsWhenItsContextIsDone: Shutdown's wait is bounded.
func TestWaitReturnsWhenItsContextIsDone(t *testing.T) {
	store := live.NewMemory()
	t.Cleanup(func() { _ = store.Close() })
	gate := make(chan struct{})
	awards := &fakeAwards{gate: gate}
	tr := New(Options{Awards: awards, Live: store, Timeout: time.Minute})
	w := windowNow()
	tr.Settled(db.SettledHand{Players: []string{"a"}, Windows: map[string]int64{"a": w}, PlayedMs: int64(time.Hour / time.Millisecond), Window: 24 * time.Hour})
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if err := tr.Wait(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("a blocked award: Wait = %v", err)
	}
	close(gate)
	wait(t, tr)
	if got := awards.callList(); !reflect.DeepEqual(got, []string{"a:" + strconv.FormatInt(w, 10) + ":60"}) {
		t.Fatalf("an hour's hand asks once, with the hour: %v", got)
	}
}
