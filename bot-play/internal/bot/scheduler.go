package bot

import (
	"sort"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/clock"
)

// scheduler is a bot's future: things to do at a time (act on a turn, say a
// line, get up after a hand), kept in order under ONE clock timer — the
// earliest — so a bot waiting on several things holds one timer, not a
// goroutine each. It is owned by the bot's loop: not safe for concurrent use.
type scheduler struct {
	clock clock.Clock
	items []scheduled
	seq   uint64
	timer clock.Timer
	armed time.Time
}

type scheduled struct {
	at   time.Time
	seq  uint64
	kind string // for cancellation by kind ("turn", "chat", …)
	fn   func()
}

func newScheduler(c clock.Clock) *scheduler { return &scheduler{clock: c} }

// after schedules fn to run on the loop d from now.
func (s *scheduler) after(d time.Duration, kind string, fn func()) {
	s.seq++
	s.items = append(s.items, scheduled{at: s.clock.Now().Add(d), seq: s.seq, kind: kind, fn: fn})
	sort.SliceStable(s.items, func(i, j int) bool {
		if s.items[i].at.Equal(s.items[j].at) {
			return s.items[i].seq < s.items[j].seq
		}
		return s.items[i].at.Before(s.items[j].at)
	})
	s.rearm()
}

// cancel drops every pending item of kind.
func (s *scheduler) cancel(kind string) {
	keep := s.items[:0]
	for _, it := range s.items {
		if it.kind != kind {
			keep = append(keep, it)
		}
	}
	s.items = keep
	s.rearm()
}

// has reports whether an item of kind is pending.
func (s *scheduler) has(kind string) bool {
	for _, it := range s.items {
		if it.kind == kind {
			return true
		}
	}
	return false
}

// clear drops everything (a connection ended, the bot stops).
func (s *scheduler) clear() {
	s.items = nil
	s.rearm()
}

// wake is the channel to select on; nil when nothing is pending.
func (s *scheduler) wake() <-chan time.Time {
	if s.timer == nil {
		return nil
	}
	return s.timer.C()
}

// fire runs every item that is due, in order. Call when wake fires.
func (s *scheduler) fire() {
	s.timer = nil
	s.armed = time.Time{}
	now := s.clock.Now()
	for len(s.items) > 0 && !s.items[0].at.After(now) {
		it := s.items[0]
		s.items = s.items[1:]
		it.fn()
	}
	s.rearm()
}

func (s *scheduler) rearm() {
	if len(s.items) == 0 {
		if s.timer != nil {
			s.timer.Stop()
			s.timer = nil
			s.armed = time.Time{}
		}
		return
	}
	next := s.items[0].at
	if s.timer != nil && s.armed.Equal(next) {
		return
	}
	if s.timer != nil {
		s.timer.Stop()
	}
	d := next.Sub(s.clock.Now())
	if d < 0 {
		d = 0
	}
	s.timer = s.clock.NewTimer(d)
	s.armed = next
}
