// Package clock is time as the bots see it, injectable so a test (or the
// simulator) can move it by hand.
package clock

import (
	"context"
	"sort"
	"sync"
	"time"
)

// Clock is the time source every timer in bot-play goes through.
type Clock interface {
	Now() time.Time
	// NewTimer fires once, d from now.
	NewTimer(d time.Duration) Timer
	// Sleep waits d or until ctx ends (returning ctx.Err()).
	Sleep(ctx context.Context, d time.Duration) error
}

// Timer is a one-shot timer.
type Timer interface {
	C() <-chan time.Time
	// Stop prevents the timer firing; false if it already fired or stopped.
	Stop() bool
}

// Real is the wall clock.
type Real struct{}

func (Real) Now() time.Time { return time.Now() }

func (Real) NewTimer(d time.Duration) Timer { return realTimer{time.NewTimer(d)} }

func (Real) Sleep(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

type realTimer struct{ t *time.Timer }

func (r realTimer) C() <-chan time.Time { return r.t.C }
func (r realTimer) Stop() bool          { return r.t.Stop() }

// Fake is a clock that moves only when Advance is called. Safe for
// concurrent use.
type Fake struct {
	mu     sync.Mutex
	now    time.Time
	timers []*fakeTimer
}

// NewFake starts a fake clock at start.
func NewFake(start time.Time) *Fake { return &Fake{now: start} }

func (f *Fake) Now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.now
}

func (f *Fake) NewTimer(d time.Duration) Timer {
	f.mu.Lock()
	defer f.mu.Unlock()
	t := &fakeTimer{clock: f, at: f.now.Add(d), c: make(chan time.Time, 1)}
	if d <= 0 {
		t.fired = true
		t.c <- f.now
		return t
	}
	f.timers = append(f.timers, t)
	return t
}

func (f *Fake) Sleep(ctx context.Context, d time.Duration) error {
	t := f.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C():
		return nil
	}
}

// Advance moves the clock on by d, firing every timer due by then in
// deadline order.
func (f *Fake) Advance(d time.Duration) {
	f.mu.Lock()
	f.now = f.now.Add(d)
	now := f.now
	due := make([]*fakeTimer, 0)
	keep := f.timers[:0]
	for _, t := range f.timers {
		if !t.fired && !t.stopped && !t.at.After(now) {
			due = append(due, t)
			continue
		}
		if !t.fired && !t.stopped {
			keep = append(keep, t)
		}
	}
	f.timers = keep
	sort.SliceStable(due, func(i, j int) bool { return due[i].at.Before(due[j].at) })
	for _, t := range due {
		t.fired = true
	}
	f.mu.Unlock()
	for _, t := range due {
		t.c <- t.at
	}
}

// Pending is how many timers are waiting to fire.
func (f *Fake) Pending() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.timers)
}

type fakeTimer struct {
	clock   *Fake
	at      time.Time
	c       chan time.Time
	fired   bool
	stopped bool
}

func (t *fakeTimer) C() <-chan time.Time { return t.c }

func (t *fakeTimer) Stop() bool {
	t.clock.mu.Lock()
	defer t.clock.mu.Unlock()
	if t.fired || t.stopped {
		return false
	}
	t.stopped = true
	return true
}
