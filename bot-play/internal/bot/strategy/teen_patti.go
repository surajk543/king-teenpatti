package strategy

import (
	"math"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/decision"
	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// handClass is what kind of situation a decision was made in; the
// imperfection layer picks a plausible mistake for it.
type handClass int

const (
	classNone    handClass = iota // no hand behind it (nothing legal, a fallback)
	classBlind                    // a blind move
	classStrong                   // a strong hand, or a monster
	classMedium                   // a middling hand
	classWeak                     // a weak hand
	classUnknown                  // seen, but no evaluation
	classForced                   // the price is out of reach
)

// NewHandMemory starts a hand: decides, from the personality, whether this
// hand begins with the intent to play blind and for how many blind bets.
//
// On a seen table the intent is BlindRate exactly (brief §10's ranges), and
// a variation table shaves a tenth off it — its rules make the cards matter.
// At a BLIND table blind is the game: three quarters of the hands a player
// would have looked at straight away are played blind as well (a BlindRate
// of 0.30 becomes 0.825).
//
// The plan is how many blind bets before looking, varied per hand so a bot
// does not always look in the same round: on a seen table about 1 + 1.6 ×
// BlindLove give or take one (1–4, mostly 1–3); at a blind table about 2 +
// 2.5 × BlindLove give or take one (1–6) — the server turns the cards up
// itself at the table's blind limit. Pressure can still make a bot look
// before its plan is done, and a bot may ride past it (Decide).
func NewHandMemory(p Personality, category string, r *rng.Rand) *HandMemory {
	m := &HandMemory{}
	rate := clamp01(p.BlindRate)
	switch category {
	case protocol.CategoryBlind:
		rate = 1 - (1-rate)*0.25
	case protocol.CategoryVariation:
		rate *= 0.9
	}
	if !r.Chance(rate) {
		return m
	}
	love := clamp01(p.BlindLove)
	if category == protocol.CategoryBlind {
		m.PlannedBlindTurns = clampInt(int(math.Round(2+2.5*love+r.Normal())), 1, 6)
	} else {
		m.PlannedBlindTurns = clampInt(int(math.Round(1+1.6*love+0.8*r.Normal())), 1, 4)
	}
	return m
}

// Decide chooses this turn's move. The result is always Legal for
// ctx.Options — bar the one case below where no move exists at all; when
// nothing but a pack is legal it packs.
//
// While the options offer a look (CanSee) the bot is blind and plays the
// blind game (blind.go); otherwise it plays the cards it has seen (seen.go).
// A look is a move of its own: Decide returns "see", and the bot calls it
// again on the next snapshot to bet with its cards.
//
// Over the chosen move sits a layer of controlled imperfection (a bad call, a
// needless fold, a small raise on nothing, a big hand not made to pay, one
// change of mind a hand) at the personality's Mistake rate, and for a noisy
// personality the odd whim — every one of them a legal move, marked Mistake.
//
// When the options allow no move at all (the bot asked a sideshow and it
// stands: no ladder, no show, no pack, no look) the result has Action "" and
// Reason NO_LEGAL_MOVE, and the bot waits for the next snapshot. With
// EnableBlind false a blind bot looks at its first chance, even when
// EnableSeen is false too; with EnableSeen false alone it never looks unless
// a look is the only move there is.
//
// Decide updates ctx.Memory (see HandMemory); a nil Memory is treated as a
// fresh one.
func Decide(ctx DecisionContext, r *rng.Rand) Decision {
	if ctx.Memory == nil {
		ctx.Memory = &HandMemory{}
	}
	d := choose(ctx, r)
	if d.Action != "" && !Legal(d, ctx.Options) || d.Action == "" && d.Reason != ReasonNoLegalMove {
		d = fallback(ctx.Options)
	}
	remember(ctx.Memory, d, ctx.Options.CanSee)
	return d
}

// choose is Decide without the safety net: the move the strategy wants.
func choose(ctx DecisionContext, r *rng.Rand) Decision {
	o := ctx.Options
	if !anyLegal(o) {
		return Decision{Reason: ReasonNoLegalMove, Confidence: 1}
	}
	var d Decision
	var class handClass
	if o.CanSee {
		d, class = decideBlind(ctx, r)
	} else {
		d, class = decideSeen(ctx, r)
	}
	if d.Action == "" || d.Action == protocol.ActionSee {
		return d
	}
	if w, ok := whim(ctx, r); ok {
		return w
	}
	return imperfect(ctx, d, class, r)
}

// Legal reports whether d is a move ctx's options allow, with an amount
// that is a rung of the ladder where one is needed.
//
// see needs CanSee; chaal the ladder's first rung, covered by the stack;
// raise a later rung, at least twice the chaal and covered by the stack
// (decision.IsRaiseRung); show a show cost the stack covers; sideshow
// CanSideshow; pack CanPack. A Force Sideshow and a missile are never legal
// here — they cost hammers and missiles, which the bots do not spend — and
// neither is an empty action. Amount is read only for chaal and raise.
func Legal(d Decision, o protocol.TurnOptions) bool {
	switch d.Action {
	case protocol.ActionSee:
		return o.CanSee
	case protocol.ActionChaal:
		amount, ok := decision.ChaalAmount(o)
		return ok && d.Amount == amount
	case protocol.ActionRaise:
		return decision.IsRaiseRung(o, d.Amount)
	case protocol.ActionShow:
		return showLegal(o)
	case protocol.ActionSideshow:
		return o.CanSideshow
	case protocol.ActionPack:
		return o.CanPack
	}
	return false
}

// SideshowAnswer is how a bot answers a sideshow asked of it: answer=false
// means it lets the ask lapse (a player who did not notice); otherwise accept
// says yes or no.
//
// It lapses 5–10% of the time (0.05 + half its Distracted, at most 0.1): a
// table where every ask is answered at once is a table of programs. A hand
// above a bar (0.3 + 0.25 × Tightness, raised a little by the table's
// pressure) is glad to compare — it accepts 80–95% of the time, the
// aggressive more — and a weaker one accepts rarely (8–28%, the loose more).
// Now and then (half its Mistake rate) it answers the other way. With no hand
// known — which the server should not allow, since a blind player cannot be
// asked — it is close to a coin toss.
func SideshowAnswer(ctx DecisionContext, r *rng.Rand) (answer bool, accept bool) {
	p := ctx.Personality
	if r.Chance(clamp(0.05+0.5*p.Distracted, 0.05, 0.1)) {
		return false, false
	}
	if !ctx.Hand.Known {
		return true, r.Chance(0.4 + 0.2*p.Aggression)
	}
	s := perceived(ctx.Hand.Strength, p.Noise, r)
	bar := 0.3 + 0.25*p.Tightness + 0.1*caution(ctx)
	acc := 0.08 + 0.2*(1-p.Tightness)
	if s > bar {
		acc = 0.8 + 0.15*p.Aggression
	}
	if r.Chance(p.Mistake * 0.5) {
		acc = 1 - acc
	}
	return true, r.Chance(acc)
}

// ---------------------------------------------------------------- plumbing

// anyLegal is whether the options allow any move at all.
func anyLegal(o protocol.TurnOptions) bool {
	_, chaal := decision.ChaalAmount(o)
	return o.CanSee || chaal || len(decision.RaiseRungs(o)) > 0 || showLegal(o) || o.CanSideshow || o.CanPack
}

// showLegal: a show is offered (heads-up), is never free, and the stack
// covers it.
func showLegal(o protocol.TurnOptions) bool {
	return o.Show != nil && *o.Show > 0 && *o.Show <= o.Chips
}

// fallback is the plainest legal move, for a choice that somehow was not
// legal: a chaal, else a show, else a pack, else a look, else nothing.
func fallback(o protocol.TurnOptions) Decision {
	d := Decision{Reason: ReasonSafeFallback, Confidence: 0.2, Complexity: 0.2}
	if amount, ok := decision.ChaalAmount(o); ok {
		d.Action, d.Amount = protocol.ActionChaal, amount
		return d
	}
	switch {
	case showLegal(o):
		d.Action = protocol.ActionShow
	case o.CanPack:
		d.Action = protocol.ActionPack
	case o.CanSee:
		d.Action = protocol.ActionSee
	default:
		return Decision{Reason: ReasonNoLegalMove, Confidence: 1}
	}
	return d
}

// remember counts the move Decide returns as made (HandMemory's rules).
func remember(m *HandMemory, d Decision, blind bool) {
	switch d.Action {
	case "", protocol.ActionSee, protocol.ActionSideshow:
		return
	}
	if blind {
		m.BlindTurns++
	} else {
		m.SeenTurns++
	}
	if d.Action == protocol.ActionRaise {
		m.RaisedThisHand++
	}
	m.RaisesFaced, m.BiggestRaiseFaced = 0, 0
}

// whim is a noisy personality's move on a whim: any legal bet, weighted
// towards the ordinary (chaal 3, raise 2, show, sideshow and pack 1 each —
// a pack weighted down by how strong the known hand is, so a whim never
// throws a trail away). Only a Noise above 0.25 has whims, at (Noise − 0.25)
// × 0.5 a decision: up to about one move in six for the noisiest RANDOM player.
func whim(ctx DecisionContext, r *rng.Rand) (Decision, bool) {
	p, o := ctx.Personality, ctx.Options
	if !r.Chance(math.Max(0, p.Noise-0.25) * 0.5) {
		return Decision{}, false
	}
	chaal, canChaal := decision.ChaalAmount(o)
	rungs := decision.RaiseRungs(o)
	packWeight := 1.0
	if ctx.Hand.Known {
		packWeight = 1 - ctx.Hand.Strength
	}
	type option struct {
		action string
		weight float64
	}
	opts := []option{
		{protocol.ActionChaal, boolWeight(canChaal, 3)},
		{protocol.ActionRaise, boolWeight(len(rungs) > 0, 2)},
		{protocol.ActionShow, boolWeight(showLegal(o), 1)},
		{protocol.ActionSideshow, boolWeight(o.CanSideshow, 1)},
		{protocol.ActionPack, boolWeight(o.CanPack, packWeight)},
	}
	weights := make([]float64, len(opts))
	total := 0.0
	for i, opt := range opts {
		weights[i] = opt.weight
		total += opt.weight
	}
	if total <= 0 {
		return Decision{}, false
	}
	d := Decision{Action: opts[r.Weighted(weights)].action, Reason: ReasonRandomWhim, Mistake: true, Confidence: 0.25, Complexity: 0.3}
	switch d.Action {
	case protocol.ActionChaal:
		d.Amount = chaal
	case protocol.ActionRaise:
		d.Amount = rungs[r.IntN(len(rungs))]
	}
	return d, true
}

// imperfect lays the personality's controlled imperfections over a chosen
// move. Once a hand, after the bot has already moved, it may change its mind
// (a middling chaal becomes a pack, or a pack one more chaal); otherwise, at
// its Mistake rate, a move turns into the mistake that fits the situation:
//
//   - a weak or middling pack → a bad call (or, one time in four, the
//     smallest raise on nothing);
//   - a middling chaal → a needless fold (never with a Strength of 0.9 or
//     more, which only noise could have made look middling);
//   - a strong raise → failing to make the hand pay (a chaal, or the lowest
//     raise);
//   - a blind chaal → now and then a needless blind pack;
//   - a middling show → one more chaal instead of ending it.
//
// Every result is legal; a situation with no fitting mistake is left alone.
func imperfect(ctx DecisionContext, d Decision, class handClass, r *rng.Rand) Decision {
	p, m, o := ctx.Personality, ctx.Memory, ctx.Options
	chaal, canChaal := decision.ChaalAmount(o)
	slip := func(action string, amount int64, reason string) Decision {
		return Decision{
			Action:     action,
			Amount:     amount,
			Reason:     reason,
			Mistake:    true,
			Confidence: d.Confidence * 0.5,
			Complexity: clamp01(d.Complexity + 0.1),
		}
	}

	// A fold is a middling hand's mistake, never a hand the noise alone
	// pushed below the strong bar.
	foldable := class == classMedium && (!ctx.Hand.Known || ctx.Hand.Strength < 0.9)

	if !m.ChangedMind && m.BlindTurns+m.SeenTurns > 0 && r.Chance(p.Mistake*0.4) {
		switch {
		case d.Action == protocol.ActionChaal && foldable && o.CanPack:
			m.ChangedMind = true
			return slip(protocol.ActionPack, 0, ReasonMistakeChangeOfMind)
		case d.Action == protocol.ActionPack && (class == classMedium || class == classWeak) && canChaal:
			m.ChangedMind = true
			return slip(protocol.ActionChaal, chaal, ReasonMistakeChangeOfMind)
		}
	}
	if !r.Chance(p.Mistake) {
		return d
	}
	switch {
	case d.Action == protocol.ActionPack && (class == classWeak || class == classMedium) && canChaal:
		if rungs := decision.RaiseRungs(o); len(rungs) > 0 && r.Chance(0.25) {
			return slip(protocol.ActionRaise, rungs[0], ReasonMistakeWeakRaise)
		}
		return slip(protocol.ActionChaal, chaal, ReasonMistakeBadCall)
	case d.Action == protocol.ActionChaal && foldable && o.CanPack:
		return slip(protocol.ActionPack, 0, ReasonMistakeNeedlessFold)
	case d.Action == protocol.ActionRaise && class == classStrong:
		if canChaal && r.Chance(0.6) {
			return slip(protocol.ActionChaal, chaal, ReasonMistakeUnderplay)
		}
		if rungs := decision.RaiseRungs(o); len(rungs) > 0 && rungs[0] < d.Amount {
			return slip(protocol.ActionRaise, rungs[0], ReasonMistakeUnderplay)
		}
	case d.Action == protocol.ActionChaal && class == classBlind && o.CanPack && r.Chance(0.25):
		return slip(protocol.ActionPack, 0, ReasonMistakeNeedlessFold)
	case d.Action == protocol.ActionShow && class == classMedium && canChaal:
		return slip(protocol.ActionChaal, chaal, ReasonMistakeBadCall)
	}
	return d
}

// ----------------------------------------------------------- shared reads

// reads are the opponents' aggression and looseness, with "no read" (both
// exactly zero — the zero Pressure, or state.OpponentBook with no data)
// taken as neutral, as decision.NewPressure does.
func reads(pr decision.Pressure) (aggression, looseness float64) {
	if pr.OpponentAggression == 0 && pr.OpponentLooseness == 0 {
		return decision.NeutralRead, decision.NeutralRead
	}
	return clamp01(pr.OpponentAggression), clamp01(pr.OpponentLooseness)
}

// caution is how much of the table's pressure registers with this player:
// everyone feels some of it (a raise is a raise), an adaptive player all of
// it.
func caution(ctx DecisionContext) float64 {
	return clamp01(ctx.Pressure.Level * (0.4 + 0.6*clamp01(ctx.Personality.Adapt)))
}

// exploit is how much an adaptive player leans on opponents who fold a lot
// (positive: bluff and raise more) or away from ones who call everything
// (negative: bluff less). −1..1, scaled by Adapt.
func exploit(ctx DecisionContext) float64 {
	_, looseness := reads(ctx.Pressure)
	return clamp((0.5-looseness)*2*clamp01(ctx.Personality.Adapt), -1, 1)
}

// opponents is the players still in the hand besides this bot (at least 1).
func opponents(ctx DecisionContext) int { return max(1, ctx.ActivePlayers-1) }

// stack is the bot's chips as the options state them (the server's figure),
// else as the context does.
func stack(ctx DecisionContext) int64 {
	if ctx.Options.Chips > 0 {
		return ctx.Options.Chips
	}
	return max(0, ctx.Chips)
}

// potOf is the pot as the options state it, else as the context does.
func potOf(ctx DecisionContext) int64 {
	if ctx.Options.Pot > 0 {
		return ctx.Options.Pot
	}
	return max(0, ctx.Pot)
}

// sunkShare is the share of what the bot brought to this hand already in
// the pot.
func sunkShare(ctx DecisionContext) float64 {
	in := max(0, ctx.Contribution)
	total := in + stack(ctx)
	if total <= 0 {
		return 0
	}
	return float64(in) / float64(total)
}

// highPressure is whether the table is leaning hard enough for a reason to
// say so.
func highPressure(ctx DecisionContext) bool { return ctx.Pressure.Level >= 0.4 }

// complexity grades a decision for timing: marginal ones (close to their
// bar) and big bets are hard, clear ones and small bets easy.
func complexity(margin, risk, extra float64) float64 {
	marginal := 1 - clamp01(math.Abs(margin)*4)
	return clamp01(0.15 + 0.45*marginal + 0.35*clamp01(risk*8) + extra)
}

// confidence is how sure a decision is: far from its bar and on a
// well-known hand, sure.
func confidence(margin, handConfidence float64) float64 {
	return clamp01((0.5 + math.Abs(margin)*1.5) * handConfidence)
}

func boolWeight(ok bool, w float64) float64 {
	if ok {
		return w
	}
	return 0
}

func clamp01(x float64) float64 { return clamp(x, 0, 1) }

func clamp(x, lo, hi float64) float64 {
	if x < lo {
		return lo
	}
	if x > hi {
		return hi
	}
	return x
}

func clampInt(x, lo, hi int) int {
	if x < lo {
		return lo
	}
	if x > hi {
		return hi
	}
	return x
}
