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

// fakeAwards is the database's award door: it records every call, fails the
// first failures of them, and blocks while gate is set.
type fakeAwards struct {
	mu       sync.Mutex
	calls    []string // "<userId>:<source>"
	failures int
	gate     chan struct{}
	xp       map[string]int64
}

func (f *fakeAwards) Award(ctx context.Context, userID, source string) (db.PlayerLevel, bool, error) {
	f.mu.Lock()
	gate := f.gate
	f.mu.Unlock()
	if gate != nil {
		select {
		case <-gate:
		case <-ctx.Done():
			return db.PlayerLevel{}, false, ctx.Err()
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, userID+":"+source)
	if f.failures > 0 {
		f.failures--
		return db.PlayerLevel{}, false, errors.New("database unreachable")
	}
	if f.xp == nil {
		f.xp = map[string]int64{}
	}
	f.xp[userID] += 5
	return db.PlayerLevel{Level: 1, XP: f.xp[userID]}, true, nil
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

func (p *pushes) push(userID string, level db.PlayerLevel) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.seen = append(p.seen, userID+":"+strconv.FormatInt(level.XP, 10))
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

// TestAHandEndTellsThePlayersAndEarnsThePlayMarks: the settled hand's levels
// are pushed at once, its play is added to each player's window in the live
// store, and a player whose play reaches 30 and then 60 minutes gets each
// award once, and is told.
func TestAHandEndTellsThePlayersAndEarnsThePlayMarks(t *testing.T) {
	store := live.NewMemory()
	t.Cleanup(func() { _ = store.Close() })
	awards, told := &fakeAwards{}, &pushes{}
	tr := New(Options{Awards: awards, Live: store, Push: told.push, Backoff: -1})
	hand := func(played time.Duration, levels map[string]db.PlayerLevel, players ...string) {
		tr.Settled(db.SettledHand{HandID: "h", Players: players, Levels: levels, PlayedMs: played.Milliseconds(), Window: 24 * time.Hour})
		wait(t, tr)
	}

	hand(20*time.Minute, map[string]db.PlayerLevel{"b": {XP: 6}, "a": {XP: 7}}, "a", "b")
	if got := told.list(); !reflect.DeepEqual(got, []string{"a:7", "b:6"}) {
		t.Fatalf("the hand's own XP is told at once, in order: %v", got)
	}
	if len(awards.callList()) != 0 {
		t.Fatal("20 minutes of play earns nothing yet")
	}
	pc, _ := live.PlayClockOf(store)
	if pt, _ := pc.AddPlayTime(context.Background(), "a", 0, time.Now(), 24*time.Hour); pt.Play != 20*time.Minute {
		t.Fatalf("the play is kept in the live store: %+v", pt)
	}

	hand(11*time.Minute, nil, "a", "b")
	if got := awards.callList(); !reflect.DeepEqual(got, []string{"a:ACTIVE_30_MIN", "b:ACTIVE_30_MIN"}) {
		t.Fatalf("31 minutes: %v", got)
	}
	hand(29*time.Minute, nil, "a")
	hand(time.Minute, nil, "a")
	if got := awards.callList(); !reflect.DeepEqual(got, []string{"a:ACTIVE_30_MIN", "a:ACTIVE_60_MIN", "b:ACTIVE_30_MIN"}) {
		t.Fatalf("61 minutes for a: %v", got)
	}
	if got := told.list(); len(got) != 5 {
		t.Fatalf("every award that changed the XP is told: %v", got)
	}
	// A hand with no play time, no players or no window records nothing.
	for _, h := range []db.SettledHand{
		{Players: []string{"c"}, PlayedMs: 0, Window: time.Hour},
		{PlayedMs: int64(time.Hour / time.Millisecond), Window: time.Hour},
		{Players: []string{"c"}, PlayedMs: int64(time.Hour / time.Millisecond)},
	} {
		tr.Settled(h)
	}
	wait(t, tr)
	if len(awards.callList()) != 3 {
		t.Fatalf("nothing more: %v", awards.callList())
	}
}

// TestAFailedPlayAwardIsReleasedForTheNextHandEnd: an award is tried Retries
// times; when every try fails the mark is released with a WARN, and the next
// hand end claims it and awards it.
func TestAFailedPlayAwardIsReleasedForTheNextHandEnd(t *testing.T) {
	store := live.NewMemory()
	t.Cleanup(func() { _ = store.Close() })
	logs := &syncBuffer{}
	awards := &fakeAwards{failures: 3}
	tr := New(Options{Awards: awards, Live: store, Backoff: -1, Logger: slog.New(slog.NewTextHandler(logs, nil))})
	tr.Settled(db.SettledHand{Players: []string{"a"}, PlayedMs: int64(31 * time.Minute / time.Millisecond), Window: 24 * time.Hour})
	wait(t, tr)
	if got := awards.callList(); len(got) != 3 {
		t.Fatalf("three tries: %v", got)
	}
	if !strings.Contains(logs.String(), "xp active-play award failed") || !strings.Contains(logs.String(), "ACTIVE_30_MIN") {
		t.Fatalf("the failure is a WARN naming the source: %s", logs.String())
	}
	tr.Settled(db.SettledHand{Players: []string{"a"}, PlayedMs: 1000, Window: 24 * time.Hour})
	wait(t, tr)
	if got := awards.callList(); len(got) != 4 || awards.xp["a"] != 5 {
		t.Fatalf("the released mark is claimed and awarded at the next hand end: %v", got)
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
			tr.Settled(db.SettledHand{Players: []string{"a"}, Levels: map[string]db.PlayerLevel{"a": {XP: 1}},
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
	tr.Settled(db.SettledHand{Players: []string{"a"}, PlayedMs: int64(time.Hour / time.Millisecond), Window: 24 * time.Hour})
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if err := tr.Wait(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("a blocked award: Wait = %v", err)
	}
	close(gate)
	wait(t, tr)
	if got := awards.callList(); !reflect.DeepEqual(got, []string{"a:ACTIVE_30_MIN", "a:ACTIVE_60_MIN"}) {
		t.Fatalf("both marks of an hour's hand: %v", got)
	}
	if SourceOf(live.PlayMark30) != db.XPSourceActive30Min || SourceOf(live.PlayMark60) != db.XPSourceActive60Min || SourceOf("x") != "" {
		t.Error("SourceOf")
	}
}
