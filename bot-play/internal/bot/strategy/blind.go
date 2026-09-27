package strategy

import (
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/decision"
	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// The blind game.
//
// A hand starts with a plan (NewHandMemory): look at once, or ride a few
// blind bets first. On each blind turn the bot weighs whether to look now:
//
//   - the plan: before its planned blind bets are made a look is unlikely
//     (a whim, or the table pushing); once they are made, likely on a seen
//     table (0.6, rising each extra turn) and still only 0.22 at a blind
//     table, where playing blind is the point;
//   - its personality: the less it loves blind play, the sooner it looks;
//   - betting pressure: the table's pressure level and the raises it has
//     faced, felt more by a player who does not love blind play;
//   - the price: a blind chaal costing more than 4% of the stack pulls
//     towards a look, strongly past 10%;
//   - its contribution: the more of its chips already in the pot, the more it
//     wants to know what it is playing for;
//   - the crowd: each opponent beyond the first adds a little;
//   - noise.
//
// At a blind table every pull but the plan counts for less than half, so a
// bot plays most of a hand blind. Staying blind is mostly a blind chaal; an
// aggressive player now and then raises blind to lean on the table, a heads-
// up player now and then shows blind, and a tight one very rarely packs
// without looking.

// decideBlind is the move of a bot that has not looked at its cards.
func decideBlind(ctx DecisionContext, r *rng.Rand) (Decision, handClass) {
	o, p, m := ctx.Options, ctx.Personality, ctx.Memory
	if !ctx.EnableBlind {
		return look(ReasonBlindDisabled, 0.9, 0.05), classBlind
	}
	chaal, canChaal := decision.ChaalAmount(o)
	if !canChaal {
		switch {
		case ctx.EnableSeen:
			// A look is free and comes first: nobody folds or shows without
			// knowing what they hold when they could simply look.
			return look(ReasonBlindLookBroke, 0.8, 0.1), classForced
		case showLegal(o):
			return Decision{Action: protocol.ActionShow, Reason: ReasonBlindShow, Confidence: 0.4, Complexity: 0.5}, classForced
		case o.CanPack:
			return Decision{Action: protocol.ActionPack, Reason: ReasonBlindPack, Confidence: 0.6, Complexity: 0.2}, classForced
		}
		// Seen play is off, but a look is the only move there is: not a
		// voluntary one.
		return look(ReasonBlindLookBroke, 0.5, 0.1), classForced
	}

	if ctx.EnableSeen {
		chance, reason := lookChance(ctx, chaal, r)
		if r.Chance(chance) {
			return look(reason, 0.4+0.5*chance, 0.08+0.1*chance), classBlind
		}
	}

	blindTable := ctx.Category == protocol.CategoryBlind
	price := decision.RiskShare(chaal, stack(ctx))
	level := ctx.Pressure.Level

	if showLegal(o) && r.Chance(p.ShowRate*0.25*(1+0.1*float64(m.BlindTurns))) {
		return Decision{Action: protocol.ActionShow, Reason: ReasonBlindShow, Confidence: 0.4, Complexity: 0.55}, classBlind
	}

	raiseChance := p.Aggression * 0.22 * (1 - 0.5*level) * (1 + 0.5*ctx.Tilt)
	if blindTable {
		raiseChance *= 1.2
	}
	if price > 0.1 {
		raiseChance *= 0.3
	}
	if r.Chance(raiseChance) {
		if amount, ok := decision.RaiseAmount(o, p.Aggression, 0.4, r); ok {
			risk := decision.RiskShare(amount, stack(ctx))
			return Decision{
				Action:     protocol.ActionRaise,
				Amount:     amount,
				Reason:     ReasonBlindRaise,
				Confidence: 0.45,
				Complexity: clamp01(0.35 + 0.35*clamp01(risk*8)),
			}, classBlind
		}
	}

	packChance := p.Tightness * 0.015
	if price > 0.15 {
		packChance += p.Tightness * 0.05
	}
	if o.CanPack && r.Chance(packChance) {
		return Decision{Action: protocol.ActionPack, Reason: ReasonBlindPack, Confidence: 0.4, Complexity: 0.3}, classBlind
	}

	return Decision{
		Action:     protocol.ActionChaal,
		Amount:     chaal,
		Reason:     ReasonBlindStay,
		Confidence: 0.6,
		Complexity: clamp01(0.1 + 0.3*clamp01(price*8)),
	}, classBlind
}

// lookChance is the chance of looking this blind turn, and the reason that
// would be given for it (see the file comment for the pulls).
func lookChance(ctx DecisionContext, chaal int64, r *rng.Rand) (float64, string) {
	p, m := ctx.Personality, ctx.Memory
	blindTable := ctx.Category == protocol.CategoryBlind
	pull := 1.0 // how much the pressures move this player at this table
	if blindTable {
		pull = 0.45
	}
	love := clamp01(p.BlindLove)

	planDone := m.BlindTurns >= m.PlannedBlindTurns
	var base float64
	switch {
	case m.PlannedBlindTurns == 0:
		base = pick(blindTable, 0.55, 0.9)
	case planDone:
		base = pick(blindTable, 0.22, 0.6) + 0.1*float64(m.BlindTurns-m.PlannedBlindTurns)
	default:
		base = pick(blindTable, 0.01, 0.02)
	}
	base += (1 - love) * pick(blindTable, 0.04, 0.08)

	raises := max(ctx.Pressure.RaisesFaced, m.RaisesFaced)
	pressure := (0.45*ctx.Pressure.Level + 0.1*float64(raises)) * pull * (0.6 + 0.4*(1-love))
	expensive := clamp((decision.RiskShare(chaal, stack(ctx))-0.04)*4, 0, 0.4) * pull
	sunk := 0.15 * sunkShare(ctx) * pull
	crowd := 0.03 * float64(opponents(ctx)-1)
	noise := p.Noise * 0.3 * (r.Float64() - 0.5)
	chance := clamp(base+pressure+expensive+sunk+crowd+noise, 0.01, 0.97)

	reason := ReasonBlindLookWhim
	switch {
	case planDone && base >= pressure && base >= expensive:
		reason = ReasonBlindLookPlanned
	case expensive >= pressure && expensive > 0.02:
		reason = ReasonBlindLookCost
	case pressure > 0.05:
		reason = ReasonBlindLookPressure
	}
	return chance, reason
}

// LookEarly is whether a bot looks at its cards straight after the deal,
// before its first turn (a careful player does; a blind-lover never).
//
// A hand planned blind (m.PlannedBlindTurns > 0) is never looked at early,
// and a player whose BlindLove is 0.75 or more never looks early at all.
// Otherwise the chance is (1 − BlindLove) × 0.6 + Tightness × 0.2 (at most
// 0.9), and at a blind table 40% of that.
func LookEarly(p Personality, m *HandMemory, category string, r *rng.Rand) bool {
	if m != nil && m.PlannedBlindTurns > 0 {
		return false
	}
	if p.BlindLove >= 0.75 {
		return false
	}
	chance := (1-clamp01(p.BlindLove))*0.6 + clamp01(p.Tightness)*0.2
	if category == protocol.CategoryBlind {
		chance *= 0.4
	}
	return r.Chance(clamp(chance, 0, 0.9))
}

// look is a see.
func look(reason string, conf, complexity float64) Decision {
	return Decision{Action: protocol.ActionSee, Reason: reason, Confidence: clamp01(conf), Complexity: clamp01(complexity)}
}

func pick(cond bool, yes, no float64) float64 {
	if cond {
		return yes
	}
	return no
}
