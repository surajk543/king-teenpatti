package strategy

import (
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/decision"
	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

const testBoot = 200

// ladder is the server's betOptions for a seat: base = stake (blind) or
// 2×stake (seen), doubling while the stack covers it, at most steps rungs
// (0 = no limit).
func ladder(stake int64, blind bool, steps int, chips int64) []int64 {
	base := stake
	if !blind {
		base = stake * 2
	}
	out := []int64{}
	for a := base; a > 0 && a <= chips && (steps <= 0 || len(out) < steps); a *= 2 {
		out = append(out, a)
	}
	return out
}

func ptr(v int64) *int64 { return &v }

// options builds a realistic you.options: the ladder, and a show offered
// heads-up when the chaal is affordable.
func options(stake int64, blind bool, steps int, chips, pot int64, headsUp, sideshow bool) protocol.TurnOptions {
	steps2 := ladder(stake, blind, steps, chips)
	o := protocol.TurnOptions{
		CanSee:       blind,
		CanSideshow:  sideshow && !blind,
		RaiseSteps:   steps2,
		CanPack:      true,
		IsBlind:      blind,
		CurrentStake: stake,
		Chips:        chips,
		Pot:          pot,
	}
	if len(steps2) > 0 {
		o.Chaal = ptr(steps2[0])
		o.MaxBet = ptr(steps2[len(steps2)-1])
		if headsUp {
			o.Show = ptr(steps2[0])
		}
	}
	if len(steps2) > 1 {
		o.Raise = ptr(steps2[1])
	}
	return o
}

// hand evaluates three cards classically.
func hand(cards ...string) decision.HandEvaluation {
	return decision.Evaluate(protocol.CategorySeen, "", &protocol.You{Cards: cards})
}

// strengthHand is a hand evaluation of exactly this strength.
func strengthHand(s float64) decision.HandEvaluation {
	return decision.HandEvaluation{Known: true, Strength: s, Confidence: 1, Playable: s >= decision.PlayableBar, Source: decision.SourceClassic}
}

// seenCtx is a seen turn at a seen table with players in the hand.
func seenCtx(p Personality, h decision.HandEvaluation, players int, pr decision.Pressure) DecisionContext {
	chips := int64(40_000)
	o := options(testBoot, false, 0, chips, 2_000, players == 2, players >= 3)
	return DecisionContext{
		Category:      protocol.CategorySeen,
		Options:       o,
		Hand:          h,
		Pot:           o.Pot,
		Boot:          testBoot,
		Chips:         chips,
		Contribution:  600,
		ActivePlayers: players,
		Pressure:      pr,
		Personality:   p,
		Memory:        &HandMemory{},
		EnableBlind:   true,
		EnableSeen:    true,
	}
}

// blindCtx is a blind turn.
func blindCtx(p Personality, category string, players int, m *HandMemory) DecisionContext {
	chips := int64(40_000)
	o := options(testBoot, true, 0, chips, 1_000, players == 2, false)
	return DecisionContext{
		Category:      category,
		Options:       o,
		IsBlind:       true,
		Pot:           o.Pot,
		Boot:          testBoot,
		Chips:         chips,
		ActivePlayers: players,
		Pressure:      decision.NewPressure(0, 0, testBoot, 0, 0, 0),
		Personality:   p,
		Memory:        m,
		EnableBlind:   true,
		EnableSeen:    true,
	}
}

// median is the personality at the middle of every range of kind.
func median(kind Kind) Personality {
	return NewPersonality(kind, nil, rng.From(&rng.Script{Values: []float64{0.5}}))
}

// randomHand deals three cards off a fresh shuffle.
func randomHand(r *rng.Rand) []string {
	deck := decision.Deck()
	for i := len(deck) - 1; i > 0; i-- {
		j := r.IntN(i + 1)
		deck[i], deck[j] = deck[j], deck[i]
	}
	return deck[:3]
}

// tally counts actions.
type tally map[string]int

func (t tally) share(action string) float64 {
	n := 0
	for _, c := range t {
		n += c
	}
	if n == 0 {
		return 0
	}
	return float64(t[action]) / float64(n)
}
