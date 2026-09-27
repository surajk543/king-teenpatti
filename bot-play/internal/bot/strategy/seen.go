package strategy

import (
	"math"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/decision"
	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// The seen game — the Node fleet's brain.decide, ported and made to read the
// table.
//
// The hand's Strength (the share of hands it beats under this hand's rules,
// decision.Evaluate) is bent a little by the player's Noise (perceived) and
// then judged
// against the opponents still in: win = strength^opponents × doubt, where
// doubt is how far the table's pressure is believed (down to 0.5). Pressure
// registers with everyone a little and with an adaptive player fully
// (caution); an adaptive player also leans on opponents who fold a lot and
// away from ones who call everything (exploit).
//
// In order:
//
//  1. Heads-up, a show ends it: when confident, short-stacked, tired of a
//     long hand, pressed by a raised pot with a fair hand, or simply curious.
//     A monster sometimes keeps betting instead, to build the pot.
//  2. A chaal the stack cannot cover leaves a show (heads-up) or a pack.
//  3. A middling hand asks a sideshow to settle it cheaply — more as the
//     hand drags on and as the pressure mounts.
//  4. Strong (a sequence or better, or a win estimate over the strong bar,
//     which pressure raises and aggression lowers): raise up the ladder
//     (decision.RaiseAmount, harder the stronger) — or slow-play it with a
//     chaal and let someone else build the pot.
//  5. Middling (win over the call bar: pot odds, tightness, patience,
//     pressure and the price against the stack, eased by chips already in):
//     chaal, and now and then raise.
//  6. Weak: bluff (more heads-up, less into raises and callers, more against
//     folders), float a chaal that costs next to nothing (cheapChaal; more
//     with a better hand and heads-up), take a sideshow's free chance, or
//     fold.

// monsterBar is the Strength of a hand that bets whatever the table does: a
// sequence or better on a classic table.
const monsterBar = 0.96

// decideSeen is the move of a bot that has looked at its cards.
func decideSeen(ctx DecisionContext, r *rng.Rand) (Decision, handClass) {
	o, p, m := ctx.Options, ctx.Personality, ctx.Memory
	chaal, canChaal := decision.ChaalAmount(o)
	canRaise := len(decision.RaiseRungs(o)) > 0
	showOK := showLegal(o)
	chips := stack(ctx)

	if !ctx.Hand.Known {
		return decideUnknown(ctx, chaal, canChaal)
	}

	tight := clamp01(p.Tightness - ctx.Tilt*0.3)
	cau := caution(ctx)
	exp := exploit(ctx)
	aggr := clamp01(p.Aggression + 0.25*math.Max(0, exp) - 0.2*cau + 0.1*ctx.Tilt)
	n := opponents(ctx)
	s := perceived(ctx.Hand.Strength, p.Noise, r)
	calm := math.Pow(s, float64(n))
	win := calm * clamp(1-0.5*cau, 0.5, 1)
	monster := s >= monsterBar
	patience := m.SeenTurns
	handConf := ctx.Hand.Confidence
	if handConf <= 0 {
		handConf = 0.5
	}
	price := 1.0
	potOdds := 1.0
	if canChaal {
		price = decision.RiskShare(chaal, chips)
		potOdds = decision.PotOdds(chaal, potOf(ctx))
	}

	// 1. Heads-up: a show ends it.
	if showOK {
		cost := *o.Show
		if !(monster && canRaise && r.Chance(aggr*0.5)) {
			bar := 0.55 + tight*0.15
			reason := ""
			switch {
			case win > bar:
				reason = ReasonShowHeadsUp
			case chips < cost*3 && win > 0.35:
				reason = ReasonShowShortStack
			case (m.RaisedThisHand >= 3 || patience >= 3) && win > 0.4:
				reason = ReasonShowPatience
			case cau > 0.3 && win > 0.4 && r.Chance(0.4+0.5*p.ShowRate):
				reason = ReasonShowPressure
			case win > 0.3 && r.Chance(p.ShowRate*0.3):
				reason = ReasonShowCurious
			}
			if reason != "" {
				class := classMedium
				if win > bar {
					class = classStrong
				}
				return Decision{
					Action:     protocol.ActionShow,
					Reason:     reason,
					Confidence: confidence(win-bar, handConf),
					Complexity: complexity(win-bar, decision.RiskShare(cost, chips), 0.15),
				}, class
			}
		}
	}

	// 2. The chaal is out of reach.
	if !canChaal {
		switch {
		case showOK:
			return Decision{Action: protocol.ActionShow, Reason: ReasonBrokeShow, Confidence: 0.5, Complexity: 0.4}, classForced
		case o.CanPack:
			return Decision{Action: protocol.ActionPack, Reason: ReasonBrokePack, Confidence: 0.8, Complexity: 0.1}, classForced
		case o.CanSideshow:
			return Decision{Action: protocol.ActionSideshow, Reason: ReasonSideshowSettle, Confidence: 0.4, Complexity: 0.4}, classForced
		}
		return Decision{}, classNone
	}

	// 3. A middling hand settled against the neighbour for nothing.
	if o.CanSideshow && s > 0.35 && s < 0.88 &&
		r.Chance(clamp(0.6*p.SideshowRate+0.08*float64(patience)+0.15*cau, 0, 0.9)) {
		return Decision{
			Action:     protocol.ActionSideshow,
			Reason:     ReasonSideshowSettle,
			Confidence: confidence(s-0.5, handConf),
			Complexity: 0.45,
		}, classMedium
	}

	// 4. Strong: bet big, or slow-play it.
	strongBar := 0.70 - aggr*0.1 + cau*0.12
	if monster || win > strongBar {
		margin := win - strongBar
		if monster {
			margin = math.Max(margin, 0.25)
		}
		slow := 0.2*(1-aggr) - 0.1*math.Max(0, exp)
		if monster && n >= 2 {
			slow += 0.08
		}
		if canRaise && !r.Chance(slow) {
			if amount, ok := decision.RaiseAmount(o, aggr, clamp01(win+0.2), r); ok {
				reason := ReasonStrongLowPressure
				if highPressure(ctx) {
					reason = ReasonStrongHighPressure
				}
				return Decision{
					Action:     protocol.ActionRaise,
					Amount:     amount,
					Reason:     reason,
					Confidence: confidence(margin, handConf),
					Complexity: complexity(margin, decision.RiskShare(amount, chips), 0),
				}, classStrong
			}
		}
		reason := ReasonStrongChaal
		if canRaise {
			reason = ReasonSlowPlay
		}
		return Decision{
			Action:     protocol.ActionChaal,
			Amount:     chaal,
			Reason:     reason,
			Confidence: confidence(margin, handConf),
			Complexity: complexity(margin, price, 0.05),
		}, classStrong
	}

	// 5. Middling: stay in while the price is right.
	sunk := sunkShare(ctx)
	callBar := math.Max(potOdds*(1.1+tight*0.6), 0.12+tight*0.3) +
		0.05*float64(patience) + 0.15*cau + 0.5*price - 0.05*sunk
	if win > callBar {
		margin := win - callBar
		if canRaise && r.Chance(aggr*0.18*(1+math.Max(0, exp))) {
			if amount, ok := decision.RaiseAmount(o, aggr, 0.35, r); ok {
				return Decision{
					Action:     protocol.ActionRaise,
					Amount:     amount,
					Reason:     ReasonMediumRaise,
					Confidence: confidence(margin, handConf) * 0.8,
					Complexity: complexity(margin, decision.RiskShare(amount, chips), 0.1),
				}, classMedium
			}
		}
		reason := ReasonMediumLowPressure
		if highPressure(ctx) {
			reason = ReasonMediumHighPressure
		}
		return Decision{
			Action:     protocol.ActionChaal,
			Amount:     chaal,
			Reason:     reason,
			Confidence: confidence(margin, handConf),
			Complexity: complexity(margin, price, 0),
		}, classMedium
	}

	// 6. Weak — or a middling hand the pressure has priced out.
	margin := win - callBar
	pressured := calm > callBar-0.15*cau
	class := classWeak
	if pressured || s >= decision.PlayableBar {
		class = classMedium
	}
	raises := max(ctx.Pressure.RaisesFaced, m.RaisesFaced)
	bluff := p.Bluff * (1 + 0.5*ctx.Tilt) * (1 - 0.5*cau) * (1 + math.Max(0, exp)) * (1 + 0.6*math.Min(0, exp))
	if n == 1 {
		bluff *= 2
	}
	if raises > 1 {
		bluff *= 0.4
	}
	if r.Chance(bluff) {
		if amount, ok := decision.RaiseAmount(o, aggr, 0.6, r); ok {
			return Decision{
				Action:     protocol.ActionRaise,
				Amount:     amount,
				Reason:     ReasonBluffRaise,
				Bluff:      true,
				Confidence: 0.3,
				Complexity: complexity(0, decision.RiskShare(amount, chips), 0.1),
			}, class
		}
		return Decision{Action: protocol.ActionChaal, Amount: chaal, Reason: ReasonBluffChaal, Bluff: true, Confidence: 0.3, Complexity: 0.5}, class
	}
	float := (1 - tight) * 0.45 * (0.35 + s)
	if n == 1 {
		float *= 1.3
	}
	if cheapChaal(ctx, chaal, price) && r.Chance(float) {
		return Decision{
			Action:     protocol.ActionChaal,
			Amount:     chaal,
			Reason:     ReasonWeakCheapChaal,
			Confidence: 0.35,
			Complexity: complexity(margin, price, 0),
		}, class
	}
	if o.CanSideshow && r.Chance((1-tight)*0.2) {
		return Decision{Action: protocol.ActionSideshow, Reason: ReasonSideshowLongShot, Confidence: 0.3, Complexity: 0.4}, class
	}
	if o.CanPack {
		reason := ReasonWeakFold
		if pressured {
			reason = ReasonPressureFold
		}
		return Decision{
			Action:     protocol.ActionPack,
			Reason:     reason,
			Confidence: confidence(margin, handConf),
			Complexity: complexity(margin, 0, -0.05),
		}, class
	}
	// No pack on offer (never at a real table while a ladder is): stay in.
	return Decision{Action: protocol.ActionChaal, Amount: chaal, Reason: ReasonMediumLowPressure, Confidence: 0.3, Complexity: 0.3}, class
}

// perceived is a Strength as a player reads it: bent by their Noise, most
// in the middle of the range, where hands are hard to judge, and hardly at
// the ends — nobody misreads a trail or a hopeless jumble. The spread is
// 0.25 × Noise × 2√(s(1−s)): at a strength of 0.5 a RANDOM player's read
// wanders by about ±0.12, at a trail's 0.9998 by next to nothing.
func perceived(strength, noise float64, r *rng.Rand) float64 {
	s := clamp01(strength)
	return clamp01(s + noise*0.25*2*math.Sqrt(s*(1-s))*r.Normal())
}

// cheapChaal is a chaal that costs next to nothing: at most 2% of the stack
// and, where the boot is known, no more than four boots — the opening chaal,
// not one the raises have doubled up (a deep stack makes every chaal a small
// share of it).
func cheapChaal(ctx DecisionContext, chaal int64, price float64) bool {
	if price > 0.02 {
		return false
	}
	return ctx.Boot <= 0 || chaal <= 4*ctx.Boot
}

// decideUnknown is a seen bot with no evaluation yet (a 5-Card pick still
// open, a variation hand not scored): stay in while it is cheap, since
// folding cards it has not judged is worse than a small chaal.
func decideUnknown(ctx DecisionContext, chaal int64, canChaal bool) (Decision, handClass) {
	o := ctx.Options
	price := decision.RiskShare(chaal, stack(ctx))
	switch {
	case canChaal && price <= 0.25:
		return Decision{Action: protocol.ActionChaal, Amount: chaal, Reason: ReasonUnknownChaal, Confidence: 0.3, Complexity: 0.3}, classUnknown
	case o.CanPack:
		return Decision{Action: protocol.ActionPack, Reason: ReasonUnknownPack, Confidence: 0.4, Complexity: 0.3}, classUnknown
	case canChaal:
		return Decision{Action: protocol.ActionChaal, Amount: chaal, Reason: ReasonUnknownChaal, Confidence: 0.2, Complexity: 0.4}, classUnknown
	case showLegal(o):
		return Decision{Action: protocol.ActionShow, Reason: ReasonBrokeShow, Confidence: 0.3, Complexity: 0.4}, classForced
	case o.CanSideshow:
		return Decision{Action: protocol.ActionSideshow, Reason: ReasonSideshowSettle, Confidence: 0.3, Complexity: 0.4}, classForced
	}
	return Decision{}, classNone
}
