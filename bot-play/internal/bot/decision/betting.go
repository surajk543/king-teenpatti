package decision

import (
	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// PotOdds is the share of the pot-after-calling a call of chaal costs.
// A free call (chaal ≤ 0) costs nothing: 0.
func PotOdds(chaal, pot int64) float64 {
	if chaal <= 0 {
		return 0
	}
	pot = max(0, pot)
	return float64(chaal) / (float64(pot) + float64(chaal))
}

// ChaalAmount is the chaal the options offer — the first rung of the ladder —
// when the stack covers it. ok is false with an empty ladder (nothing is
// affordable, or a sideshow stands) or a rung the stack does not cover.
func ChaalAmount(o protocol.TurnOptions) (amount int64, ok bool) {
	if len(o.RaiseSteps) == 0 {
		return 0, false
	}
	first := o.RaiseSteps[0]
	if first <= 0 || first > o.Chips {
		return 0, false
	}
	return first, true
}

// IsRaiseRung reports whether amount is a raise the server would accept: one
// of the ladder's later rungs (index ≥ 1), at least twice the chaal, and
// covered by the stack.
func IsRaiseRung(o protocol.TurnOptions, amount int64) bool {
	if len(o.RaiseSteps) < 2 || amount <= 0 || amount > o.Chips {
		return false
	}
	first := o.RaiseSteps[0]
	if first <= 0 || amount < first || amount-first < first { // amount ≥ 2×first, without overflow
		return false
	}
	for _, step := range o.RaiseSteps[1:] {
		if step == amount {
			return true
		}
	}
	return false
}

// RaiseRungs is every raise the options allow (IsRaiseRung), ascending as the
// ladder is. Empty when no raise is legal.
func RaiseRungs(o protocol.TurnOptions) []int64 {
	if len(o.RaiseSteps) < 2 {
		return nil
	}
	var rungs []int64
	for _, step := range o.RaiseSteps[1:] {
		if IsRaiseRung(o, step) {
			rungs = append(rungs, step)
		}
	}
	return rungs
}

// RaiseAmount names a rung of o.RaiseSteps for a raise: higher the stronger
// the intent (power 0..1) and the more aggressive (aggression 0..1), but
// within a share of the stack. ok is false when no raise rung is legal
// (fewer than two rungs, or none at least twice the chaal that the stack
// covers).
//
// The Node fleet's raiseAmount, kept: the budget is the stack ×
// clamp(0.03 + 0.3·aggression·power, 0.02, 0.5) — a person bets big on a big
// hand without shoving a week of winnings on a whim — and among the rungs
// inside it the pick climbs from the lowest, reaching as far as
// ⌊draw × (1 + 3·aggression·power)⌋ rungs up. When no rung fits the budget the
// lowest raise is named.
func RaiseAmount(o protocol.TurnOptions, aggression, power float64, r *rng.Rand) (amount int64, ok bool) {
	rungs := RaiseRungs(o)
	if len(rungs) == 0 {
		return 0, false
	}
	aggression, power = clamp01(aggression), clamp01(power)
	budget := float64(o.Chips) * clamp(0.03+0.3*aggression*power, 0.02, 0.5)
	choices := rungs[:0:0]
	for _, step := range rungs {
		if float64(step) <= budget {
			choices = append(choices, step)
		}
	}
	if len(choices) == 0 {
		choices = rungs[:1]
	}
	reach := int(r.Float64() * (1 + aggression*3*power))
	return choices[min(len(choices)-1, reach)], true
}
