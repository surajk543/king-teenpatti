package strategy

import (
	"math"
	"testing"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/decision"
	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// blindShare is the share of n hands that start with a blind plan.
func blindShare(p Personality, category string, n int, r *rng.Rand) float64 {
	blind := 0
	for i := 0; i < n; i++ {
		if NewHandMemory(p, category, r).PlannedBlindTurns > 0 {
			blind++
		}
	}
	return float64(blind) / float64(n)
}

// On a seen table a bot starts a hand blind at its own BlindRate, which lies
// in its family's range, and bots of one family differ.
func TestBlindRatesFallInTheFamilyRangesAndDifferPerBot(t *testing.T) {
	for _, kind := range Kinds {
		g := DefaultProfiles[kind].BlindRate
		lo, hi := 1.0, 0.0
		for i := 0; i < 8; i++ {
			p := NewPersonality(kind, nil, rng.Derive(2026, i))
			share := blindShare(p, protocol.CategorySeen, 6000, rng.Derive(7, i))
			if math.Abs(share-p.BlindRate) > 0.025 {
				t.Errorf("%s bot %d: blind %.3f of hands, its rate is %.3f", kind, i, share, p.BlindRate)
			}
			if share < g.Lo-0.025 || share > g.Hi+0.025 {
				t.Errorf("%s bot %d: blind %.3f of hands, outside the family's %v", kind, i, share, g)
			}
			lo, hi = math.Min(lo, share), math.Max(hi, share)
		}
		if hi-lo < 0.03 {
			t.Errorf("%s: eight bots all play blind about as often (%.3f..%.3f)", kind, lo, hi)
		}
	}
}

func TestABlindTableIsPlayedFarMoreBlind(t *testing.T) {
	for _, kind := range Kinds {
		p := median(kind)
		seen := blindShare(p, protocol.CategorySeen, 4000, rng.New(1))
		blind := blindShare(p, protocol.CategoryBlind, 4000, rng.New(1))
		variation := blindShare(p, protocol.CategoryVariation, 4000, rng.New(1))
		if blind < 0.8 || blind < seen+0.3 {
			t.Errorf("%s: blind table %.2f of hands blind, seen table %.2f", kind, blind, seen)
		}
		if variation > seen {
			t.Errorf("%s: a variation table (%.2f) more blind than a seen one (%.2f)", kind, variation, seen)
		}
	}
}

func TestPlannedBlindTurnsVaryFromHandToHand(t *testing.T) {
	p := median(Aggressive)
	r := rng.New(3)
	counts := map[int]int{}
	total := 0
	for i := 0; i < 5000; i++ {
		if n := NewHandMemory(p, protocol.CategorySeen, r).PlannedBlindTurns; n > 0 {
			counts[n]++
			total++
		}
	}
	if len(counts) < 3 {
		t.Fatalf("the plan hardly varies: %v", counts)
	}
	if usual := counts[1] + counts[2] + counts[3]; float64(usual)/float64(total) < 0.85 {
		t.Fatalf("plans are not usually 1-3 blind turns: %v", counts)
	}
	for n := range counts {
		if n < 1 || n > 4 {
			t.Fatalf("a seen-table plan of %d blind turns", n)
		}
	}
	blindCounts := map[int]int{}
	for i := 0; i < 3000; i++ {
		if n := NewHandMemory(p, protocol.CategoryBlind, r).PlannedBlindTurns; n > 0 {
			blindCounts[n]++
		}
	}
	if len(blindCounts) < 4 {
		t.Fatalf("blind-table plans hardly vary: %v", blindCounts)
	}
}

// lookRate is the share of blind turns on which the bot looks.
func lookRate(p Personality, category string, m HandMemory, pr decision.Pressure, n int, seed uint64) float64 {
	r := rng.New(seed)
	looks := 0
	for i := 0; i < n; i++ {
		mem := m
		ctx := blindCtx(p, category, 4, &mem)
		ctx.Pressure = pr
		if Decide(ctx, r).Action == protocol.ActionSee {
			looks++
		}
	}
	return float64(looks) / float64(n)
}

func TestTheBlindPlanIsHonoured(t *testing.T) {
	calm := decision.NewPressure(0, 0, testBoot, 0, 0, 0)
	for _, kind := range Kinds {
		p := median(kind)
		before := lookRate(p, protocol.CategorySeen, HandMemory{PlannedBlindTurns: 3, BlindTurns: 1}, calm, 3000, 1)
		after := lookRate(p, protocol.CategorySeen, HandMemory{PlannedBlindTurns: 3, BlindTurns: 3}, calm, 3000, 1)
		atOnce := lookRate(p, protocol.CategorySeen, HandMemory{}, calm, 3000, 1)
		if before > 0.3 {
			t.Errorf("%s looks %.2f of the time before its plan is done", kind, before)
		}
		if after < 0.6 || after < before+0.35 {
			t.Errorf("%s looks %.2f of the time once the plan is done (%.2f before)", kind, after, before)
		}
		if atOnce < 0.85 {
			t.Errorf("%s planned to look at once and looked %.2f of the time", kind, atOnce)
		}
	}
}

func TestPressureMakesABlindPlayerLookSooner(t *testing.T) {
	calm := decision.NewPressure(0, 0, testBoot, 0, 0, 0)
	hot := decision.NewPressure(3, testBoot*32, testBoot, 0.9, 0.6, 0)
	for _, kind := range Kinds {
		p := median(kind)
		for _, cat := range []string{protocol.CategorySeen, protocol.CategoryBlind} {
			m := HandMemory{PlannedBlindTurns: 3, BlindTurns: 1}
			quiet := lookRate(p, cat, m, calm, 4000, 2)
			m.RaisesFaced = 3
			pushed := lookRate(p, cat, m, hot, 4000, 2)
			if pushed < quiet+0.08 {
				t.Errorf("%s at a %s table: looks %.3f calm and %.3f under pressure", kind, cat, quiet, pushed)
			}
		}
	}
}

func TestAnExpensiveBlindChaalMakesAPlayerLook(t *testing.T) {
	p := median(Balanced)
	r := rng.New(4)
	cheap, dear := 0, 0
	const n = 3000
	for i := 0; i < n; i++ {
		m := HandMemory{PlannedBlindTurns: 3, BlindTurns: 1}
		ctx := blindCtx(p, protocol.CategorySeen, 3, &m)
		if Decide(ctx, r).Action == protocol.ActionSee {
			cheap++
		}
		m = HandMemory{PlannedBlindTurns: 3, BlindTurns: 1}
		ctx = blindCtx(p, protocol.CategorySeen, 3, &m)
		ctx.Options = options(3000, true, 0, 30_000, 20_000, false, false) // a blind chaal of a tenth of the stack
		if Decide(ctx, r).Action == protocol.ActionSee {
			dear++
		}
	}
	if float64(dear)/n < float64(cheap)/n+0.15 {
		t.Fatalf("looked %d/%d at a cheap blind chaal, %d/%d at a dear one", cheap, n, dear, n)
	}
}

func TestStayingBlindIsMostlyAChaalAndAggressivePlayersRaiseBlind(t *testing.T) {
	raises := map[Kind]float64{}
	for _, kind := range []Kind{Cautious, Balanced, Aggressive} {
		p := median(kind)
		r := rng.New(5)
		got := tally{}
		for i := 0; i < 5000; i++ {
			m := HandMemory{PlannedBlindTurns: 4, BlindTurns: 1}
			ctx := blindCtx(p, protocol.CategoryBlind, 4, &m)
			d := Decide(ctx, r)
			if d.Action != protocol.ActionSee {
				got[d.Action]++
			}
		}
		if got.share(protocol.ActionChaal) < 0.7 {
			t.Errorf("%s: staying blind is a chaal only %.2f of the time: %v", kind, got.share(protocol.ActionChaal), got)
		}
		if got.share(protocol.ActionPack) > 0.05 {
			t.Errorf("%s packs blind %.3f of the time", kind, got.share(protocol.ActionPack))
		}
		raises[kind] = got.share(protocol.ActionRaise)
	}
	if !(raises[Aggressive] > raises[Balanced] && raises[Balanced] > raises[Cautious]) || raises[Aggressive] < 0.08 {
		t.Fatalf("blind raises by family: %v", raises)
	}
}

func TestABlindPlayerSometimesShowsHeadsUp(t *testing.T) {
	p := median(Aggressive)
	r := rng.New(6)
	shows := 0
	for i := 0; i < 4000; i++ {
		m := HandMemory{PlannedBlindTurns: 4, BlindTurns: 2}
		ctx := blindCtx(p, protocol.CategoryBlind, 2, &m)
		if Decide(ctx, r).Action == protocol.ActionShow {
			shows++
		}
	}
	if shows < 100 || shows > 1200 {
		t.Fatalf("a heads-up blind player showed %d times in 4000", shows)
	}
}

func TestWithBlindPlayDisabledABotLooksAtItsFirstChance(t *testing.T) {
	r := rng.New(7)
	for _, kind := range Kinds {
		for i := 0; i < 300; i++ {
			p := NewPersonality(kind, nil, r)
			m := NewHandMemory(p, protocol.CategoryBlind, r)
			ctx := blindCtx(p, protocol.CategoryBlind, 3, m)
			ctx.EnableBlind = false
			if d := Decide(ctx, r); d.Action != protocol.ActionSee || d.Reason != ReasonBlindDisabled {
				t.Fatalf("%s with blind play off: %+v", kind, d)
			}
		}
	}
}

func TestWithSeenPlayDisabledABotNeverLooks(t *testing.T) {
	r := rng.New(8)
	for _, kind := range Kinds {
		p := median(kind)
		for i := 0; i < 1000; i++ {
			m := &HandMemory{PlannedBlindTurns: r.IntN(3), BlindTurns: r.IntN(6)}
			ctx := blindCtx(p, protocol.CategorySeen, 2+r.IntN(4), m)
			ctx.EnableSeen = false
			ctx.Pressure = decision.NewPressure(r.IntN(4), testBoot*16, testBoot, 0.8, 0.5, 0)
			if d := Decide(ctx, r); d.Action == protocol.ActionSee {
				t.Fatalf("%s looked with seen play off: %+v", kind, d)
			}
		}
		// Even the blind chaal out of reach does not make it look.
		ctx := blindCtx(p, protocol.CategorySeen, 3, &HandMemory{})
		ctx.EnableSeen = false
		ctx.Options.RaiseSteps, ctx.Options.Chaal, ctx.Options.Show = []int64{}, nil, nil
		if d := Decide(ctx, r); d.Action != protocol.ActionPack {
			t.Fatalf("%s with no affordable chaal and seen play off: %+v", kind, d)
		}
	}
}

func TestABlindPlayerWhoCannotAffordTheChaalLooksFirst(t *testing.T) {
	p := median(Loose)
	ctx := blindCtx(p, protocol.CategoryBlind, 3, &HandMemory{PlannedBlindTurns: 4})
	ctx.Options.RaiseSteps, ctx.Options.Chaal = []int64{}, nil
	if d := Decide(ctx, rng.New(1)); d.Action != protocol.ActionSee || d.Reason != ReasonBlindLookBroke {
		t.Fatalf("got %+v", d)
	}
}

func TestLookEarly(t *testing.T) {
	r := rng.New(9)
	for _, kind := range Kinds {
		p := median(kind)
		for i := 0; i < 500; i++ {
			if LookEarly(p, &HandMemory{PlannedBlindTurns: 1 + r.IntN(4)}, protocol.CategorySeen, r) {
				t.Fatalf("%s looked early at a hand it planned to play blind", kind)
			}
		}
	}
	lover := median(Aggressive)
	lover.BlindLove = 0.8
	for i := 0; i < 500; i++ {
		if LookEarly(lover, &HandMemory{}, protocol.CategorySeen, r) {
			t.Fatalf("a blind-lover looked early")
		}
	}
	rate := func(p Personality, cat string) float64 {
		n := 0
		for i := 0; i < 4000; i++ {
			if LookEarly(p, &HandMemory{}, cat, r) {
				n++
			}
		}
		return float64(n) / 4000
	}
	careful := rate(median(Cautious), protocol.CategorySeen)
	balanced := rate(median(Balanced), protocol.CategorySeen)
	atBlind := rate(median(Cautious), protocol.CategoryBlind)
	if careful < 0.5 || careful <= balanced || atBlind >= careful*0.6 {
		t.Fatalf("look-early rates: cautious %.2f, balanced %.2f, cautious at a blind table %.2f", careful, balanced, atBlind)
	}
	if !LookEarly(median(Cautious), nil, protocol.CategorySeen, rng.From(&rng.Script{Values: []float64{0}})) {
		t.Fatalf("a nil memory must read as no blind plan")
	}
}
