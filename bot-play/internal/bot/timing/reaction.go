package timing

import (
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// The distribution's shape. The amount drawn above a window's floor is
// log-normal with its median at medianShare of the window (times the
// context's shape factor) and a spread of logSigma; draws past the window's
// top are drawn again. Neutral, the median sits 30% of the way up the
// window and the mean a little above it — most reactions quick, a tail of
// slow ones, which is the shape human reaction times have.
const (
	medianShare   = 0.3
	logSigma      = 0.5
	redraws       = 12
	maxDistracted = 0.5 // no personality is distracted on more than every other decision

	// A distracted pause: someone put the phone down. Log-normal around 5.5 s,
	// held to 2.5–15 s, on top of the ordinary draw.
	pauseMedian = 5500 * time.Millisecond
	pauseSigma  = 0.45
	pauseMin    = 2500 * time.Millisecond
	pauseMax    = 15 * time.Second
)

// isDecision reports whether k is a decision: a turn move or an answer owed
// inside a server window. Only decisions are bounded by MinReaction and
// MaxReaction, shaped by the hand and the decision, and interrupted by a
// distracted pause.
func isDecision(k Kind) bool {
	switch k {
	case See, LookEarly, JoinTable, LeaveTable, SearchTable, Chat:
		return false
	}
	return true
}

// IsDecision reports whether a delay for k is a decision (see Kind).
func IsDecision(k Kind) bool { return isDecision(k) }

// drawIn is a shifted, truncated log-normal in [lo, hi]: lo plus a skewed
// amount whose median is share of the window.
func drawIn(r *rng.Rand, lo, hi time.Duration, share float64) time.Duration {
	span := float64(hi - lo)
	if span <= 0 {
		return lo
	}
	median := span * share
	for range redraws {
		if x := r.LogNormal(median, logSigma); x < span {
			return lo + time.Duration(x)
		}
	}
	// The median was pushed so high that a dozen draws overshot: somewhere in
	// the window's upper half, where such a draw belongs.
	return lo + time.Duration(span*r.Between(0.55, 1))
}

// distractedPause is the extra a distracted player takes.
func distractedPause(r *rng.Rand) time.Duration {
	d := time.Duration(r.LogNormal(float64(pauseMedian), pauseSigma))
	if d < pauseMin {
		d = pauseMin + time.Duration(r.Between(0, 0.3)*float64(pauseMin))
	}
	if d > pauseMax {
		d = pauseMax - time.Duration(r.Between(0, 0.2)*float64(pauseMax-pauseMin))
	}
	return d
}

// beat is the short delay For returns when the deadline is nearly on it:
// MinBeat and a little, ending 30 ms before the deadline when the deadline
// is further away than MinBeat and that, and MinBeat when it is not.
func beat(left time.Duration, r *rng.Rand) time.Duration {
	b := MinBeat + time.Duration(r.Between(0, 200)*float64(time.Millisecond))
	upper := left - 30*time.Millisecond
	if upper < MinBeat {
		upper = MinBeat
	}
	if b > upper {
		b = upper
	}
	return unround(b, MinBeat, upper, r)
}

// unround keeps a delay off whole milliseconds (so never a round 1000, 2000
// or 3000 ms, nor any multiple of 100 ms), moving it by under a millisecond
// in whichever direction stays within [lo, hi]. In a window narrower than
// that (a range configured as a single figure) it moves up: under a
// millisecond past a bound is invisible, a round figure is not.
func unround(d, lo, hi time.Duration, r *rng.Rand) time.Duration {
	if d%time.Millisecond != 0 {
		return d
	}
	j := time.Duration(1+r.IntN(999)) * time.Microsecond
	j += time.Duration(r.IntN(1000)) // and some nanoseconds
	if d+j > hi && d-j >= lo {
		return d - j
	}
	return d + j
}

// marginal is how much of a coin toss a hand is: 1 at strength 0.5, 0 at
// either end (a hand that is clearly good or clearly bad is decided fast).
func marginal(strength float64) float64 {
	return 1 - math.Abs(2*clamp(strength, 0, 1)-1)
}

func clamp(x, lo, hi float64) float64 {
	if x < lo || math.IsNaN(x) {
		return lo
	}
	if x > hi {
		return hi
	}
	return x
}

// tidy puts a configured range the right way round, with no negative bound.
func tidy(rg Range) Range {
	if rg.MinMs < 0 {
		rg.MinMs = 0
	}
	if rg.MaxMs < 0 {
		rg.MaxMs = 0
	}
	if rg.MaxMs < rg.MinMs {
		rg.MinMs, rg.MaxMs = rg.MaxMs, rg.MinMs
	}
	return rg
}

// Kinds is every kind with a default range, in a fixed order.
func Kinds() []Kind {
	ks := make([]Kind, 0, len(DefaultRanges))
	for k := range DefaultRanges {
		ks = append(ks, k)
	}
	sort.Slice(ks, func(i, j int) bool { return ks[i] < ks[j] })
	return ks
}

// ParseRanges turns the configuration's timing.ranges (kind name → [min_ms,
// max_ms]) into Config.Ranges. An unknown kind, a negative bound or a min
// above its max is an error naming it.
func ParseRanges(in map[string][2]int) (map[Kind]Range, error) {
	if len(in) == 0 {
		return nil, nil
	}
	out := make(map[Kind]Range, len(in))
	var bad []string
	for name, mm := range in {
		k := Kind(strings.TrimSpace(strings.ToLower(name)))
		if _, ok := DefaultRanges[k]; !ok {
			bad = append(bad, fmt.Sprintf("unknown kind %q", name))
			continue
		}
		if mm[0] < 0 || mm[1] < 0 || mm[0] > mm[1] {
			bad = append(bad, fmt.Sprintf("%s: [%d, %d] is not a range of milliseconds", name, mm[0], mm[1]))
			continue
		}
		out[k] = Range{MinMs: mm[0], MaxMs: mm[1]}
	}
	if len(bad) > 0 {
		sort.Strings(bad)
		return nil, fmt.Errorf("timing.ranges: %s", strings.Join(bad, "; "))
	}
	return out, nil
}

// Join is the pause before sitting down at a table the bot has chosen.
func (h *HumanDelay) Join(pace float64, r *rng.Rand) time.Duration {
	return h.For(Context{Kind: JoinTable, Pace: pace}, r)
}

// Leave is the pause before getting up from a table.
func (h *HumanDelay) Leave(pace float64, r *rng.Rand) time.Duration {
	return h.For(Context{Kind: LeaveTable, Pace: pace}, r)
}

// Search is the idle gap before looking for a table (brief: 2.5–8 s).
func (h *HumanDelay) Search(pace float64, r *rng.Rand) time.Duration {
	return h.For(Context{Kind: SearchTable, Pace: pace}, r)
}

// ChatPause is the pause between deciding to say something and saying it.
func (h *HumanDelay) ChatPause(pace float64, r *rng.Rand) time.Duration {
	return h.For(Context{Kind: Chat, Pace: pace}, r)
}
