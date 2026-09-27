package strategy

import (
	"regexp"
	"testing"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/decision"
	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// scenario is one random seen turn: a dealt hand, 1–4 opponents, a table
// that has raised 0–2 times.
type scenario struct {
	cards   []string
	players int
	raises  int
	biggest int64
}

func scenarios(n int, seed uint64) []scenario {
	r := rng.New(seed)
	out := make([]scenario, n)
	for i := range out {
		out[i] = scenario{
			cards:   randomHand(r),
			players: 2 + r.IntN(4),
			raises:  r.IntN(3),
			biggest: testBoot * int64(1<<r.IntN(5)),
		}
	}
	return out
}

// play decides every scenario for p and tallies the moves, all of them and
// those made with weak hands (Strength under 0.4).
func play(p Personality, sc []scenario, pressure func(scenario) decision.Pressure, seed uint64) (all, weak tally, decisions []Decision) {
	r := rng.New(seed)
	all, weak = tally{}, tally{}
	for _, s := range sc {
		h := hand(s.cards...)
		d := Decide(seenCtx(p, h, s.players, pressure(s)), r)
		all[d.Action]++
		if h.Strength < 0.4 {
			weak[d.Action]++
		}
		decisions = append(decisions, d)
	}
	return all, weak, decisions
}

func ordinaryPressure(s scenario) decision.Pressure {
	return decision.NewPressure(s.raises, s.biggest, testBoot, 0, 0, 0)
}

func TestAStrongHandBetsAndAWeakOneFolds(t *testing.T) {
	trail := hand("As", "Ad", "Ah")
	junk := hand("2s", "3d", "5h")
	for _, kind := range Kinds {
		p := median(kind)
		r := rng.New(11)
		strong, weak := tally{}, tally{}
		for i := 0; i < 1000; i++ {
			pr := decision.NewPressure(i%3, testBoot*4, testBoot, 0, 0, 0)
			strong[Decide(seenCtx(p, trail, 4, pr), r).Action]++
			weak[Decide(seenCtx(p, junk, 4, pr), r).Action]++
		}
		bets := strong.share(protocol.ActionRaise) + strong.share(protocol.ActionChaal)
		if strong[protocol.ActionPack] > 0 && kind != Random {
			t.Errorf("%s packed a trail of aces: %v", kind, strong)
		}
		if bets < 0.9 || strong.share(protocol.ActionRaise) < 0.45 {
			t.Errorf("%s with a trail of aces: %v", kind, strong)
		}
		foldBar := 0.75
		switch kind {
		case Loose, Random, Beginner, Aggressive:
			foldBar = 0.4
		}
		if weak.share(protocol.ActionPack) < foldBar {
			t.Errorf("%s with 5-3-2 against four: folds only %.2f: %v", kind, weak.share(protocol.ActionPack), weak)
		}
	}
}

// Over 5,000 decisions an aggressive player raises far more than a careful
// one, and a careful one folds weak hands more.
func TestAggressiveRaisesMoreAndCautiousFoldsWeakMore(t *testing.T) {
	sc := scenarios(5000, 21)
	shares := map[Kind][2]float64{}
	for _, kind := range Kinds {
		all, weak, _ := play(median(kind), sc, ordinaryPressure, 22)
		shares[kind] = [2]float64{all.share(protocol.ActionRaise), weak.share(protocol.ActionPack)}
	}
	c, b, a, l := shares[Cautious], shares[Balanced], shares[Aggressive], shares[Loose]
	if a[0] < 2*c[0] || a[0] <= b[0] || b[0] <= c[0] {
		t.Errorf("raise shares: cautious %.3f, balanced %.3f, aggressive %.3f", c[0], b[0], a[0])
	}
	if c[1] < a[1]+0.15 || c[1] < l[1]+0.15 || c[1] <= b[1] {
		t.Errorf("weak-hand fold shares: cautious %.3f, balanced %.3f, aggressive %.3f, loose %.3f", c[1], b[1], a[1], l[1])
	}
	// And across the whole family, not only its median bot.
	var caut, aggr float64
	for i := 0; i < 6; i++ {
		all, _, _ := play(NewPersonality(Cautious, nil, rng.Derive(3, i)), sc[:1500], ordinaryPressure, 23)
		caut += all.share(protocol.ActionRaise)
		all, _, _ = play(NewPersonality(Aggressive, nil, rng.Derive(4, i)), sc[:1500], ordinaryPressure, 23)
		aggr += all.share(protocol.ActionRaise)
	}
	if aggr < 1.8*caut {
		t.Errorf("six aggressive bots raise %.3f, six cautious ones %.3f", aggr/6, caut/6)
	}
}

func TestPressureMakesEveryFamilyMoreCareful(t *testing.T) {
	sc := scenarios(4000, 31)
	calm := func(scenario) decision.Pressure { return decision.NewPressure(0, 0, testBoot, 0.3, 0.5, 1) }
	hot := func(scenario) decision.Pressure { return decision.NewPressure(3, testBoot*32, testBoot, 0.9, 0.5, 0) }
	for _, kind := range Kinds {
		p := median(kind)
		quiet, _, _ := play(p, sc, calm, 32)
		pushed, _, _ := play(p, sc, hot, 32)
		if pushed.share(protocol.ActionRaise) >= quiet.share(protocol.ActionRaise)*0.8 {
			t.Errorf("%s raises %.3f calm, %.3f under pressure", kind, quiet.share(protocol.ActionRaise), pushed.share(protocol.ActionRaise))
		}
		if pushed.share(protocol.ActionPack) <= quiet.share(protocol.ActionPack)+0.02 {
			t.Errorf("%s folds %.3f calm, %.3f under pressure", kind, quiet.share(protocol.ActionPack), pushed.share(protocol.ActionPack))
		}
	}
	// A careful, adaptive player feels it more than a noisy one.
	b := median(Balanced)
	quiet, _, _ := play(b, sc, calm, 33)
	pushed, _, dec := play(b, sc, hot, 33)
	gotPressureFold := false
	for _, d := range dec {
		if d.Reason == ReasonPressureFold {
			gotPressureFold = true
		}
	}
	if !gotPressureFold {
		t.Errorf("no fold was put down to the pressure (%v → %v)", quiet, pushed)
	}
}

// An adaptive player raises and bluffs more into opponents who fold a lot
// than into ones who call everything.
func TestAdaptivePlayersLeanOnFoldersAndNotOnCallers(t *testing.T) {
	sc := scenarios(4000, 41)
	folders := func(s scenario) decision.Pressure { return decision.NewPressure(0, 0, testBoot, 0.3, 0.1, 0) }
	callers := func(s scenario) decision.Pressure { return decision.NewPressure(0, 0, testBoot, 0.3, 0.9, 0) }
	b := median(Balanced)
	vsFolders, _, df := play(b, sc, folders, 42)
	vsCallers, _, dc := play(b, sc, callers, 42)
	if vsFolders.share(protocol.ActionRaise) < vsCallers.share(protocol.ActionRaise)*1.2 {
		t.Errorf("raises against folders %.3f, against callers %.3f", vsFolders.share(protocol.ActionRaise), vsCallers.share(protocol.ActionRaise))
	}
	bluffs := func(ds []Decision) int {
		n := 0
		for _, d := range ds {
			if d.Bluff {
				n++
			}
		}
		return n
	}
	if bluffs(df) <= bluffs(dc) {
		t.Errorf("bluffs against folders %d, against callers %d", bluffs(df), bluffs(dc))
	}
	// A player who does not adapt barely notices.
	stubborn := median(Balanced)
	stubborn.Adapt = 0
	a, _, _ := play(stubborn, sc, folders, 43)
	c, _, _ := play(stubborn, sc, callers, 43)
	if d := a.share(protocol.ActionRaise) - c.share(protocol.ActionRaise); d > 0.01 || d < -0.03 {
		t.Errorf("a player with Adapt 0 raised %.3f vs folders and %.3f vs callers", a.share(protocol.ActionRaise), c.share(protocol.ActionRaise))
	}
}

func TestRaisesClimbHigherForAggressivePlayersAndBiggerHands(t *testing.T) {
	mean := func(p Personality, h decision.HandEvaluation) float64 {
		r := rng.New(51)
		sum, n := 0.0, 0
		for i := 0; i < 3000; i++ {
			ctx := seenCtx(p, h, 3, decision.NewPressure(0, 0, testBoot, 0, 0, 0))
			ctx.Options = options(testBoot, false, 0, 400_000, 2_000, false, false) // a deep stack, a long ladder
			if d := Decide(ctx, r); d.Action == protocol.ActionRaise {
				sum += float64(d.Amount)
				n++
			}
		}
		if n == 0 {
			return 0
		}
		return sum / float64(n)
	}
	monster := hand("Ks", "Qs", "Js")
	if a, c := mean(median(Aggressive), monster), mean(median(Cautious), monster); a < 1.5*c {
		t.Errorf("mean raise with a pure sequence: aggressive %.0f, cautious %.0f", a, c)
	}
}

func TestAConfidentHandShowsHeadsUp(t *testing.T) {
	aces := hand("As", "Ad", "7c") // a pair of aces
	junk := hand("2s", "4d", "7c")
	for _, kind := range []Kind{Cautious, Balanced, Aggressive} {
		p := median(kind)
		r := rng.New(61)
		good, bad := tally{}, tally{}
		for i := 0; i < 1000; i++ {
			good[Decide(seenCtx(p, aces, 2, decision.NewPressure(0, 0, testBoot, 0, 0, 0)), r).Action]++
			bad[Decide(seenCtx(p, junk, 2, decision.NewPressure(0, 0, testBoot, 0, 0, 0)), r).Action]++
		}
		if good.share(protocol.ActionShow) < 0.4 {
			t.Errorf("%s heads-up with a pair of aces: %v", kind, good)
		}
		if bad.share(protocol.ActionShow) > 0.05 {
			t.Errorf("%s heads-up with seven high shows: %v", kind, bad)
		}
	}
}

func TestAMiddlingHandAsksASideshowAndAStrongOneDoesNot(t *testing.T) {
	middling := hand("Ks", "Qd", "7c") // king high
	monster := hand("9s", "9d", "9c")
	for _, kind := range Kinds {
		p := median(kind)
		r := rng.New(71)
		mid, big := tally{}, tally{}
		for i := 0; i < 2000; i++ {
			mid[Decide(seenCtx(p, middling, 3, decision.NewPressure(0, 0, testBoot, 0, 0, 0)), r).Action]++
			big[Decide(seenCtx(p, monster, 3, decision.NewPressure(0, 0, testBoot, 0, 0, 0)), r).Action]++
		}
		if mid.share(protocol.ActionSideshow) < 0.08 {
			t.Errorf("%s with king high asks a sideshow %.3f of the time", kind, mid.share(protocol.ActionSideshow))
		}
		if big.share(protocol.ActionSideshow) > 0.02 {
			t.Errorf("%s with a trail asks a sideshow %.3f of the time", kind, big.share(protocol.ActionSideshow))
		}
	}
}

func TestMistakesAreLegalMarkedAndBeginnersMakeMore(t *testing.T) {
	sc := scenarios(5000, 81)
	rates := map[Kind]float64{}
	reasons := map[string]bool{}
	for _, kind := range Kinds {
		_, _, ds := play(median(kind), sc, ordinaryPressure, 82)
		n := 0
		for _, d := range ds {
			if d.Mistake {
				n++
				reasons[d.Reason] = true
			}
		}
		rates[kind] = float64(n) / float64(len(ds))
	}
	if rates[Beginner] < 3*rates[Cautious] || rates[Beginner] < 2*rates[Balanced] {
		t.Errorf("mistake rates: %v", rates)
	}
	if rates[Random] < rates[Beginner] {
		t.Errorf("the noisiest family errs less than beginners: %v", rates)
	}
	for _, want := range []string{ReasonMistakeBadCall, ReasonMistakeNeedlessFold, ReasonMistakeUnderplay, ReasonMistakeWeakRaise, ReasonRandomWhim} {
		if !reasons[want] {
			t.Errorf("never saw the imperfection %s", want)
		}
	}
}

// A change of mind is a once-a-hand thing, however long the hand.
func TestAChangeOfMindHappensAtMostOnceAHand(t *testing.T) {
	p := median(Beginner)
	p.Mistake = 0.5
	r := rng.New(91)
	changed := 0
	for handNo := 0; handNo < 400; handNo++ {
		m := &HandMemory{}
		n := 0
		for turn := 0; turn < 12; turn++ {
			ctx := seenCtx(p, strengthHand(0.55+0.3*r.Float64()), 3, decision.NewPressure(0, 0, testBoot, 0, 0, 0))
			ctx.Memory = m
			if Decide(ctx, r).Reason == ReasonMistakeChangeOfMind {
				n++
			}
		}
		if n > 1 {
			t.Fatalf("hand %d: %d changes of mind", handNo, n)
		}
		changed += n
	}
	if changed == 0 {
		t.Fatalf("no bot ever changed its mind")
	}
}

func TestReasonsConfidenceAndComplexityAreWellFormed(t *testing.T) {
	upper := regexp.MustCompile(`^[A-Z][A-Z_]*[A-Z]$`)
	sc := scenarios(3000, 101)
	for _, kind := range Kinds {
		_, _, ds := play(median(kind), sc, ordinaryPressure, 102)
		for _, d := range ds {
			if !upper.MatchString(d.Reason) {
				t.Fatalf("reason %q is not UPPER_SNAKE", d.Reason)
			}
			if d.Confidence < 0 || d.Confidence > 1 || d.Complexity < 0 || d.Complexity > 1 {
				t.Fatalf("%+v: confidence or complexity outside 0..1", d)
			}
			if d.Action != protocol.ActionChaal && d.Action != protocol.ActionRaise && d.Amount != 0 {
				t.Fatalf("%+v: an amount on a move that takes none", d)
			}
		}
	}
	// A blind chaal is routine; a big raise is not.
	r := rng.New(103)
	blind := Decide(blindCtx(median(Balanced), protocol.CategorySeen, 3, &HandMemory{PlannedBlindTurns: 4, BlindTurns: 1}), r)
	var big Decision
	for i := 0; i < 200 && big.Action != protocol.ActionRaise; i++ {
		ctx := seenCtx(median(Aggressive), hand("As", "Ks", "Qs"), 3, decision.NewPressure(0, 0, testBoot, 0, 0, 0))
		ctx.Options = options(testBoot*16, false, 0, 60_000, 50_000, false, false)
		big = Decide(ctx, r)
	}
	if blind.Action == protocol.ActionChaal && big.Action == protocol.ActionRaise && blind.Complexity >= big.Complexity {
		t.Errorf("a blind chaal (%.2f) is no simpler than a big raise (%.2f)", blind.Complexity, big.Complexity)
	}
}

func TestDecideIsDeterministicForASeed(t *testing.T) {
	sc := scenarios(500, 111)
	for _, kind := range Kinds {
		_, _, a := play(median(kind), sc, ordinaryPressure, 112)
		_, _, b := play(median(kind), sc, ordinaryPressure, 112)
		_, _, c := play(median(kind), sc, ordinaryPressure, 113)
		same := true
		for i := range a {
			if a[i] != b[i] {
				t.Fatalf("%s: decision %d differs for the same seed: %+v vs %+v", kind, i, a[i], b[i])
			}
			if a[i] != c[i] {
				same = false
			}
		}
		if same {
			t.Fatalf("%s: a different seed made every decision the same", kind)
		}
	}
}

func TestDecideKeepsTheHandsMemory(t *testing.T) {
	p := median(Balanced)
	p.Mistake, p.Noise = 0, 0
	m := &HandMemory{PlannedBlindTurns: 2, RaisesFaced: 2, BiggestRaiseFaced: 800}

	// A look is not a turn.
	ctx := blindCtx(p, protocol.CategorySeen, 3, m)
	ctx.EnableBlind = false
	if d := Decide(ctx, rng.New(1)); d.Action != protocol.ActionSee || m.BlindTurns != 0 || m.RaisesFaced != 2 {
		t.Fatalf("after a look: %+v, memory %+v", d, m)
	}
	// A blind bet is a blind turn and clears the raises faced.
	ctx = blindCtx(p, protocol.CategorySeen, 3, m)
	ctx.EnableSeen = false
	d := Decide(ctx, rng.New(2))
	if d.Action == protocol.ActionSee || m.BlindTurns != 1 || m.RaisesFaced != 0 || m.BiggestRaiseFaced != 0 {
		t.Fatalf("after a blind bet: %+v, memory %+v", d, m)
	}
	// A seen raise is a seen turn and a raise this hand.
	for i := 0; i < 50 && m.RaisedThisHand == 0; i++ {
		ctx = seenCtx(p, hand("As", "Ks", "Qs"), 3, decision.NewPressure(0, 0, testBoot, 0, 0, 0))
		ctx.Memory = m
		Decide(ctx, rng.New(uint64(10+i)))
	}
	if m.RaisedThisHand == 0 || m.SeenTurns == 0 {
		t.Fatalf("memory after seen raises: %+v", m)
	}
	// A nil memory is a fresh one.
	ctx = seenCtx(p, hand("As", "Ks", "Qs"), 3, decision.Pressure{})
	ctx.Memory = nil
	if d := Decide(ctx, rng.New(3)); !Legal(d, ctx.Options) {
		t.Fatalf("with a nil memory: %+v", d)
	}
}

func TestASeenHandNotYetScoredStaysInCheaply(t *testing.T) {
	p := median(Cautious)
	ctx := seenCtx(p, decision.HandEvaluation{Source: decision.SourceNone}, 3, decision.Pressure{})
	ctx.Category, ctx.Variation = protocol.CategoryVariation, protocol.VariationFiveCard
	if d := Decide(ctx, rng.New(1)); d.Action != protocol.ActionChaal || d.Reason != ReasonUnknownChaal {
		t.Fatalf("got %+v", d)
	}
	ctx.Options = options(testBoot*64, false, 0, 30_000, 60_000, false, false) // a chaal of most of the stack
	if d := Decide(ctx, rng.New(1)); d.Action != protocol.ActionPack || d.Reason != ReasonUnknownPack {
		t.Fatalf("got %+v", d)
	}
}

func TestTheChaalOutOfReachLeavesAShowOrAPack(t *testing.T) {
	p := median(Balanced)
	ctx := seenCtx(p, hand("As", "Ad", "Kc"), 2, decision.Pressure{})
	ctx.Options.RaiseSteps, ctx.Options.Chaal, ctx.Options.Raise, ctx.Options.Show = []int64{}, nil, nil, nil
	if d := Decide(ctx, rng.New(1)); d.Action != protocol.ActionPack {
		t.Fatalf("got %+v", d)
	}
}

func TestWhatToDoWhenLittleOrNothingIsLegal(t *testing.T) {
	p := median(Random)
	// A sideshow this bot asked stands: nothing is legal but waiting.
	pending := protocol.TurnOptions{RaiseSteps: []int64{}, Chips: 10_000, Pot: 1_000}
	ctx := seenCtx(p, hand("Ks", "Qd", "7c"), 3, decision.Pressure{})
	ctx.Options = pending
	if d := Decide(ctx, rng.New(1)); d.Action != "" || d.Reason != ReasonNoLegalMove {
		t.Fatalf("with nothing legal: %+v", d)
	}
	// Only a pack.
	ctx.Options = protocol.TurnOptions{RaiseSteps: []int64{}, CanPack: true, Chips: 100}
	if d := Decide(ctx, rng.New(1)); d.Action != protocol.ActionPack {
		t.Fatalf("with only a pack: %+v", d)
	}
	// Only a look.
	ctx.Options = protocol.TurnOptions{RaiseSteps: []int64{}, CanSee: true, Chips: 100}
	for _, seen := range []bool{true, false} {
		ctx.EnableSeen = seen
		if d := Decide(ctx, rng.New(1)); d.Action != protocol.ActionSee {
			t.Fatalf("with only a look (seen play %v): %+v", seen, d)
		}
	}
}
