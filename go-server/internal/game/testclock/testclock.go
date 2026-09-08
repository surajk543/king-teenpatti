// Package testclock is the deterministic game.Clock for unit tests — the port
// of server/test/helpers/fakeTimers.js.
//
// Advance moves the clock forward and fires every due timer IN DEADLINE ORDER,
// running each callback synchronously and waiting for it to return before
// firing the next. A Table timer callback posts onto the actor and waits, so
// when Advance returns every side effect of every fired timer — including any
// Ledger call it made — has completed. Timers a callback arms with a deadline
// inside the window being advanced are fired in the same Advance call.
//
// Never call Advance from a Table listener callback (it would post to the
// actor that is delivering the callback and deadlock).
package testclock

import (
	"sort"
	"sync"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// Fake is the deterministic clock. Zero value is not usable; use New.
type Fake struct {
	mu      sync.Mutex
	now     time.Time
	nextID  int
	pending map[int]*entry
}

type entry struct {
	id int
	at time.Time
	fn func()
}

type timer struct {
	c  *Fake
	id int
}

// Stop implements game.Timer: removes the entry if it has not fired.
func (t *timer) Stop() bool {
	t.c.mu.Lock()
	defer t.c.mu.Unlock()
	if _, ok := t.c.pending[t.id]; !ok {
		return false
	}
	delete(t.c.pending, t.id)
	return true
}

// New returns a Fake whose Now() starts at `start` (Node's fake started at 0;
// pick something like time.UnixMilli(1_700_000_000_000) so wire timestamps
// look realistic).
func New(start time.Time) *Fake {
	return &Fake{now: start, pending: map[int]*entry{}}
}

// Now implements game.Clock.
func (c *Fake) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

// AfterFunc implements game.Clock: schedules fn at Now()+d without firing it.
func (c *Fake) AfterFunc(d time.Duration, fn func()) game.Timer {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.nextID++
	e := &entry{id: c.nextID, at: c.now.Add(d), fn: fn}
	c.pending[e.id] = e
	return &timer{c: c, id: e.id}
}

// Advance moves the clock by d, firing due timers one at a time (earliest
// deadline first; equal deadlines by creation order), each run to completion
// with the clock set to that timer's deadline. Finally Now() == start + d.
func (c *Fake) Advance(d time.Duration) {
	c.mu.Lock()
	target := c.now.Add(d)
	c.mu.Unlock()

	for {
		c.mu.Lock()
		var due []*entry
		for _, e := range c.pending {
			if !e.at.After(target) {
				due = append(due, e)
			}
		}
		if len(due) == 0 {
			c.now = target
			c.mu.Unlock()
			return
		}
		sort.Slice(due, func(i, j int) bool {
			if due[i].at.Equal(due[j].at) {
				return due[i].id < due[j].id
			}
			return due[i].at.Before(due[j].at)
		})
		next := due[0]
		delete(c.pending, next.id)
		c.now = next.at
		c.mu.Unlock()

		next.fn()
	}
}

// Pending is the number of armed timers (Node: pending()).
func (c *Fake) Pending() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.pending)
}

var _ game.Clock = (*Fake)(nil)
