// Package timing is when a bot acts: human-like reaction times drawn from a
// skewed distribution (most quick, a long tail of slow), shaped by the move,
// the decision's difficulty and the personality, and never allowed to eat
// the server's turn clock.
//
// A HumanDelay is immutable once built, so one may be shared by the whole
// fleet; the randomness is the caller's own *rng.Rand (one per bot).
package timing

import (
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// Kind is what the bot is about to do.
type Kind string

// The kinds a delay is drawn for. The betting moves, the answers owed inside
// a window (a sideshow, a variation, a 5-Card pick) and Difficult are
// DECISIONS: MinReaction/MaxReaction bound them, the decision's difficulty
// and the hand shape them, and only they can be interrupted by a distracted
// pause. The rest — a glance, sitting down, getting up, looking for a table,
// a chat line — are shaped by the player's pace alone.
const (
	See            Kind = "see"         // looking at one's cards: a glance
	Chaal          Kind = "chaal"       // a call
	BlindChaal     Kind = "blind_chaal" // another blind chaal: routine, the quickest decision
	Fold           Kind = "fold"        // a pack
	SmallRaise     Kind = "small_raise"
	LargeRaise     Kind = "large_raise"
	Show           Kind = "show"
	Sideshow       Kind = "sideshow" // asking for one
	Difficult      Kind = "difficult"
	JoinTable      Kind = "join_table"
	LeaveTable     Kind = "leave_table"
	SearchTable    Kind = "search_table" // the idle gap before looking for a table (brief: 2.5–8 s)
	Chat           Kind = "chat"         // the pause before a chat line goes out
	AnswerSideshow Kind = "answer_sideshow"
	PickVariation  Kind = "pick_variation"
	PickCards      Kind = "pick_cards"
	LookEarly      Kind = "look_early" // looking straight after the deal, before the first turn
)

// Range is a reaction window in milliseconds for a kind: most draws land
// well inside it, a few near its top (never beyond it except a distracted
// pause, which is still capped by the deadline).
type Range struct{ MinMs, MaxMs int }

// DefaultRanges are the brief's §8 starting values, and the kinds the brief
// does not name placed among them: a look is a glance, a blind chaal is
// routine, a show weighs what a large raise does, and an answer owed inside a
// server window leaves room inside it.
var DefaultRanges = map[Kind]Range{
	See:            {MinMs: 500, MaxMs: 1800},
	LookEarly:      {MinMs: 600, MaxMs: 2200},
	BlindChaal:     {MinMs: 700, MaxMs: 1900},
	Chaal:          {MinMs: 800, MaxMs: 2500},
	Fold:           {MinMs: 700, MaxMs: 2200},
	SmallRaise:     {MinMs: 1000, MaxMs: 3000},
	LargeRaise:     {MinMs: 1500, MaxMs: 4000},
	Show:           {MinMs: 1500, MaxMs: 4000},
	Sideshow:       {MinMs: 1200, MaxMs: 3500},
	Difficult:      {MinMs: 2000, MaxMs: 5000},
	AnswerSideshow: {MinMs: 900, MaxMs: 3200},
	PickVariation:  {MinMs: 1500, MaxMs: 5000},
	PickCards:      {MinMs: 1500, MaxMs: 4500},
	JoinTable:      {MinMs: 1000, MaxMs: 4000},
	LeaveTable:     {MinMs: 1500, MaxMs: 5000},
	SearchTable:    {MinMs: 2500, MaxMs: 8000},
	Chat:           {MinMs: 1000, MaxMs: 5000},
}

// fallbackRange is used for a kind nobody gave a range for: an ordinary call.
var fallbackRange = Range{MinMs: 800, MaxMs: 2500}

// The configuration's defaults.
const (
	DefaultMinReaction  = 700 * time.Millisecond
	DefaultMaxReaction  = 5 * time.Second
	DefaultSafetyMargin = 3 * time.Second
	DefaultMaxPause     = 20 * time.Second
)

// MinBeat is the shortest delay For ever returns: even with the deadline on
// top of it, a person needs a beat to press a key.
const MinBeat = 150 * time.Millisecond

// Config is the timing section of the configuration.
type Config struct {
	Ranges       map[Kind]Range // overrides DefaultRanges per kind
	MinReaction  time.Duration  // floor for any decision — a turn move or an answer owed in a window (default 700 ms)
	MaxReaction  time.Duration  // ceiling for any decision (default 5 s) before a distracted pause
	SafetyMargin time.Duration  // always act at least this long before a deadline (default 3 s)
	MaxPause     time.Duration  // the longest a distracted pause may run when there is no deadline (default 20 s)
}

// Context is one delay's inputs.
type Context struct {
	Kind       Kind
	Pace       float64   // personality: 0 snap … 1 deliberate
	Distracted float64   // personality: chance of a long pause
	Complexity float64   // 0..1 from the decision
	Strength   float64   // 0..1 hand strength (a clear hand is quick, a marginal one slower)
	IsBlind    bool      // a blind chaal is routine
	FacedRaise bool      // someone raised since the bot last acted
	Now        time.Time // for the deadline (zero = the wall clock)
	Deadline   time.Time // zero = none; the delay always ends SafetyMargin before it
}

// HumanDelay draws reaction times. Immutable after New, so safe to share
// between goroutines (each bringing its own *rng.Rand).
type HumanDelay struct {
	ranges       map[Kind]Range
	minReaction  time.Duration
	maxReaction  time.Duration
	safetyMargin time.Duration
	maxPause     time.Duration
}

// New builds a HumanDelay from cfg (zero fields take the defaults). A range
// given the wrong way round is turned the right way round, and a negative
// bound is read as 0; ParseRanges is the checked way to build cfg.Ranges.
func New(cfg Config) *HumanDelay {
	h := &HumanDelay{
		ranges:       make(map[Kind]Range, len(DefaultRanges)+len(cfg.Ranges)),
		minReaction:  cfg.MinReaction,
		maxReaction:  cfg.MaxReaction,
		safetyMargin: cfg.SafetyMargin,
		maxPause:     cfg.MaxPause,
	}
	for k, rg := range DefaultRanges {
		h.ranges[k] = rg
	}
	for k, rg := range cfg.Ranges {
		h.ranges[k] = tidy(rg)
	}
	if h.minReaction <= 0 {
		h.minReaction = DefaultMinReaction
	}
	if h.maxReaction <= 0 {
		h.maxReaction = DefaultMaxReaction
	}
	if h.maxReaction < h.minReaction {
		h.maxReaction = h.minReaction
	}
	if h.safetyMargin <= 0 {
		h.safetyMargin = DefaultSafetyMargin
	}
	if h.maxPause <= 0 {
		h.maxPause = DefaultMaxPause
	}
	return h
}

// For is how long to wait before acting. Never exact round figures; never
// past Deadline − SafetyMargin (and at least a short beat when the deadline
// is nearly on it).
//
// The draw is a shifted, truncated log-normal inside the kind's window
// (Bounds): the window's floor plus a skewed amount whose median sits under
// a third of the way up, so most reactions are quick and a few come late.
// Pace, the decision's complexity, how marginal the hand is, a raise faced
// and a routine blind move move that median up or down; none of them moves
// the window. A distracted pause (chance Context.Distracted, decisions only)
// adds several seconds on top, may pass MaxReaction, and is held to
// MaxPause — and, like everything else, to the deadline.
//
// When the deadline leaves less than MinBeat after the safety margin, For
// returns a beat of at least MinBeat, ending before the deadline itself
// wherever the deadline is more than that beat away.
func (h *HumanDelay) For(ctx Context, r *rng.Rand) time.Duration {
	lo, hi := h.Bounds(ctx.Kind)
	d := drawIn(r, lo, hi, medianShare*h.shape(ctx))
	upper := hi
	if isDecision(ctx.Kind) && r.Chance(clamp(ctx.Distracted, 0, maxDistracted)) {
		d += distractedPause(r)
		upper = h.maxPause
		if upper < hi {
			upper = hi
		}
		if d > upper {
			// Held under the ceiling by a fraction, so pauses that ran long
			// do not all end on the same instant.
			d = upper - time.Duration(r.Between(0.02, 0.12)*float64(upper-hi))
		}
	}
	d = unround(d, lo, upper, r)
	if ctx.Deadline.IsZero() {
		return d
	}
	now := ctx.Now
	if now.IsZero() {
		now = time.Now()
	}
	left := ctx.Deadline.Sub(now)
	room := left - h.safetyMargin
	if room < MinBeat {
		return beat(left, r)
	}
	if d > room {
		// Somewhere in the last stretch before the margin, not on its edge.
		d = time.Duration(r.Between(0.72, 1) * float64(room))
		if d < MinBeat {
			d = MinBeat
		}
		d = unround(d, MinBeat, room, r)
	}
	return d
}

// Bounds is the window a kind's draws land in before a distracted pause or a
// deadline: its range, and for a decision the range held inside
// [MinReaction, MaxReaction]. A kind with no range takes an ordinary call's.
func (h *HumanDelay) Bounds(k Kind) (lo, hi time.Duration) {
	rg, ok := h.ranges[k]
	if !ok {
		rg = fallbackRange
	}
	lo = time.Duration(rg.MinMs) * time.Millisecond
	hi = time.Duration(rg.MaxMs) * time.Millisecond
	if isDecision(k) {
		if lo < h.minReaction {
			lo = h.minReaction
		}
		if hi > h.maxReaction {
			hi = h.maxReaction
		}
		if hi < lo {
			hi = lo
		}
	}
	return lo, hi
}

// SafetyMargin is how long before a deadline every delay ends.
func (h *HumanDelay) SafetyMargin() time.Duration { return h.safetyMargin }

// shape is the factor on the draw's median: above 1 slower, below quicker.
func (h *HumanDelay) shape(ctx Context) float64 {
	pace := clamp(ctx.Pace, 0, 1)
	if !isDecision(ctx.Kind) {
		// Sitting down, getting up, a glance, a chat line: only the person's
		// general tempo shows.
		return 0.85 + 0.3*pace
	}
	f := 0.7 + 0.6*pace                         // snap … deliberate
	f *= 0.85 + 0.5*clamp(ctx.Complexity, 0, 1) // an easy call … a hard one
	f *= 0.85 + 0.35*marginal(ctx.Strength)     // a clear hand … a marginal one
	if ctx.FacedRaise {
		f *= 1.2 // a raise makes a person stop and think
	}
	if ctx.IsBlind {
		f *= 0.75 // another blind chaal is routine
	}
	return clamp(f, 0.4, 2.4)
}
