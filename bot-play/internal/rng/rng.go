// Package rng is the bots' randomness: one independent, seedable stream per
// bot, so no two bots share a sequence and a test (or a simulation run with
// BOT_SEED) replays exactly.
//
// A Rand is NOT safe for concurrent use: each bot owns its own and uses it
// from its one event loop.
package rng

import (
	"math"
	"math/rand/v2"
)

// Source is where the randomness comes from: [0,1) floats.
type Source interface {
	Float64() float64
}

// Rand is a Source with the draws the strategy code uses.
type Rand struct {
	src Source
}

// New is a deterministic stream for seed (PCG): the same seed gives the same
// draws on every run and every platform.
func New(seed uint64) *Rand {
	return &Rand{src: rand.New(rand.NewPCG(seed, seed^0x9e3779b97f4a7c15))}
}

// From wraps any Source — a test's scripted one, for instance.
func From(src Source) *Rand { return &Rand{src: src} }

// Derive is a new, independent stream for the i-th child of seed (bot i of a
// fleet seeded with seed), mixed so neighbouring bots are not correlated.
func Derive(seed uint64, i int) *Rand {
	x := seed + uint64(i+1)*0x9e3779b97f4a7c15
	x ^= x >> 30
	x *= 0xbf58476d1ce4e5b9
	x ^= x >> 27
	x *= 0x94d049bb133111eb
	x ^= x >> 31
	return New(x)
}

// Float64 is a uniform draw in [0,1).
func (r *Rand) Float64() float64 { return r.src.Float64() }

// Chance is true with probability p (clamped to [0,1]).
func (r *Rand) Chance(p float64) bool {
	if p <= 0 {
		return false
	}
	if p >= 1 {
		return true
	}
	return r.src.Float64() < p
}

// Between is a uniform draw in [lo,hi).
func (r *Rand) Between(lo, hi float64) float64 { return lo + (hi-lo)*r.src.Float64() }

// IntN is a uniform integer in [0,n). n <= 0 gives 0.
func (r *Rand) IntN(n int) int {
	if n <= 1 {
		return 0
	}
	i := int(r.src.Float64() * float64(n))
	if i >= n {
		i = n - 1
	}
	return i
}

// Normal is a standard normal draw (Box–Muller).
func (r *Rand) Normal() float64 {
	u := r.src.Float64()
	for u == 0 {
		u = r.src.Float64()
	}
	return math.Sqrt(-2*math.Log(u)) * math.Cos(2*math.Pi*r.src.Float64())
}

// LogNormal is a draw whose median is median and whose spread is sigma (the
// standard deviation of its log): most draws near the median, a long tail of
// slow ones — the shape human reaction times have.
func (r *Rand) LogNormal(median, sigma float64) float64 {
	return median * math.Exp(sigma*r.Normal())
}

// Weighted picks an index with probability proportional to its weight.
// Non-positive weights are never picked; all non-positive picks 0.
func (r *Rand) Weighted(weights []float64) int {
	total := 0.0
	for _, w := range weights {
		if w > 0 {
			total += w
		}
	}
	if total <= 0 {
		return 0
	}
	roll := r.src.Float64() * total
	for i, w := range weights {
		if w <= 0 {
			continue
		}
		roll -= w
		if roll < 0 {
			return i
		}
	}
	return len(weights) - 1
}

// Script is a Source that replays fixed values in a loop — for tests that
// pin one exact draw.
type Script struct {
	Values []float64
	i      int
}

// Float64 returns the next scripted value.
func (s *Script) Float64() float64 {
	if len(s.Values) == 0 {
		return 0
	}
	v := s.Values[s.i%len(s.Values)]
	s.i++
	return v
}
