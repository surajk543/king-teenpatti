package connection

import (
	"math"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// Backoff defaults.
const (
	DefaultBackoffBase   = time.Second
	DefaultBackoffMax    = 30 * time.Second
	DefaultBackoffFactor = 2.0
	DefaultBackoffJitter = 0.3
)

// Backoff is exponential backoff with jitter (brief §21): 1 s, 2 s, 4 s, 8 s,
// 16 s … capped at Max, each spread by ±Jitter so a fleet that lost the
// server together does not come back in lockstep.
//
// A zero field takes its default. Factor below 1 is read as 1 (a constant
// wait: backoff never shrinks). Jitter is clamped to 1; a NEGATIVE Jitter
// turns the spread off, since 0 already means the default.
type Backoff struct {
	Base   time.Duration // default 1 s
	Max    time.Duration // default 30 s
	Factor float64       // default 2
	Jitter float64       // 0..1, default 0.3
}

// Delay is the wait before attempt (1-based): Base·Factor^(attempt−1),
// capped at Max, then multiplied by a uniform draw from [1−Jitter, 1+Jitter)
// taken from r (a nil r spreads nothing). An attempt of 0 or less is read as
// 1. The result is never negative and never above Max·(1+Jitter).
func (b Backoff) Delay(attempt int, r *rng.Rand) time.Duration {
	base, maxWait, factor, jitter := b.resolved()
	if attempt < 1 {
		attempt = 1
	}
	// Computed in float64 and capped before converting, so a large attempt
	// neither overflows nor turns negative.
	d := float64(base) * math.Pow(factor, float64(attempt-1))
	if math.IsInf(d, 0) || math.IsNaN(d) || d > float64(maxWait) {
		d = float64(maxWait)
	}
	if r != nil && jitter > 0 {
		d *= 1 + jitter*(2*r.Float64()-1)
	}
	if d < 0 {
		d = 0
	}
	if hi := float64(maxWait) * (1 + jitter); d > hi {
		d = hi
	}
	return time.Duration(d)
}

func (b Backoff) resolved() (base, maxWait time.Duration, factor, jitter float64) {
	base, maxWait, factor, jitter = b.Base, b.Max, b.Factor, b.Jitter
	if base <= 0 {
		base = DefaultBackoffBase
	}
	if maxWait <= 0 {
		maxWait = DefaultBackoffMax
	}
	switch {
	case factor == 0 || math.IsNaN(factor):
		factor = DefaultBackoffFactor
	case factor < 1:
		factor = 1
	}
	switch {
	case jitter == 0 || math.IsNaN(jitter):
		jitter = DefaultBackoffJitter
	case jitter < 0:
		jitter = 0
	case jitter > 1:
		jitter = 1
	}
	return base, maxWait, factor, jitter
}
