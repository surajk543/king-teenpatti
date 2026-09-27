package strategy

import (
	"testing"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/decision"
	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

func TestLegal(t *testing.T) {
	o := options(200, false, 3, 5_000, 1_000, true, true) // ladder 400, 800, 1600; show 400
	cases := []struct {
		d    Decision
		want bool
	}{
		{Decision{Action: protocol.ActionChaal, Amount: 400}, true},
		{Decision{Action: protocol.ActionChaal, Amount: 800}, false}, // a chaal is the first rung
		{Decision{Action: protocol.ActionChaal}, false},
		{Decision{Action: protocol.ActionRaise, Amount: 800}, true},
		{Decision{Action: protocol.ActionRaise, Amount: 1600}, true},
		{Decision{Action: protocol.ActionRaise, Amount: 400}, false},  // the chaal is not a raise
		{Decision{Action: protocol.ActionRaise, Amount: 1200}, false}, // not a rung
		{Decision{Action: protocol.ActionRaise, Amount: 3200}, false}, // not on this ladder
		{Decision{Action: protocol.ActionShow}, true},
		{Decision{Action: protocol.ActionSideshow}, true},
		{Decision{Action: protocol.ActionPack}, true},
		{Decision{Action: protocol.ActionSee}, false}, // already seen
		{Decision{Action: protocol.ActionForceSideshow}, false},
		{Decision{Action: protocol.ActionMissile}, false},
		{Decision{}, false},
		{Decision{Action: "fold"}, false},
	}
	for _, c := range cases {
		if got := Legal(c.d, o); got != c.want {
			t.Errorf("Legal(%s %d) = %v, want %v", c.d.Action, c.d.Amount, got, c.want)
		}
	}

	short := o
	short.Chips = 1_000 // covers the chaal and the first raise only
	if Legal(Decision{Action: protocol.ActionRaise, Amount: 1600}, short) {
		t.Error("a raise the stack does not cover is legal")
	}
	if !Legal(Decision{Action: protocol.ActionRaise, Amount: 800}, short) {
		t.Error("a covered raise is not legal")
	}
	broke := o
	broke.Chips = 300
	if Legal(Decision{Action: protocol.ActionChaal, Amount: 400}, broke) || Legal(Decision{Action: protocol.ActionShow}, broke) {
		t.Error("a chaal or show the stack does not cover is legal")
	}
	odd := o
	odd.RaiseSteps = []int64{400, 700} // a rung under twice the chaal is never a raise
	if Legal(Decision{Action: protocol.ActionRaise, Amount: 700}, odd) {
		t.Error("a raise under twice the chaal is legal")
	}
	pending := protocol.TurnOptions{RaiseSteps: []int64{}, Chips: 5_000}
	for _, a := range []string{protocol.ActionChaal, protocol.ActionRaise, protocol.ActionShow, protocol.ActionSideshow, protocol.ActionPack, protocol.ActionSee} {
		if Legal(Decision{Action: a, Amount: 400}, pending) {
			t.Errorf("%s is legal while a sideshow stands", a)
		}
	}
	free := o
	free.Show = ptr(0)
	if Legal(Decision{Action: protocol.ActionShow}, free) {
		t.Error("a free show is legal")
	}
}

// randomOptions is anything the wire could carry and more: ladders that do
// not double, rungs past the stack, a show past the stack or free, flags in
// every combination.
func randomOptions(r *rng.Rand) protocol.TurnOptions {
	chips := int64(r.IntN(6)) * int64(1+r.IntN(200_000))
	o := protocol.TurnOptions{
		CanSee:       r.Chance(0.4),
		CanSideshow:  r.Chance(0.3),
		CanPack:      r.Chance(0.9),
		CanMissile:   r.Chance(0.2),
		Chips:        chips,
		Pot:          int64(r.IntN(100_000)),
		CurrentStake: int64(1 + r.IntN(5000)),
	}
	o.CanForceSideshow = o.CanSideshow
	o.IsBlind = o.CanSee
	n := r.IntN(9)
	o.RaiseSteps = []int64{}
	step := int64(1 + r.IntN(20_000))
	for i := 0; i < n; i++ {
		o.RaiseSteps = append(o.RaiseSteps, step)
		switch r.IntN(4) {
		case 0:
			step += int64(r.IntN(10_000)) // not a doubling
		default:
			step *= 2
		}
	}
	if r.Chance(0.05) {
		o.RaiseSteps = append(o.RaiseSteps, -5, 0) // nonsense a bot must not name
	}
	if len(o.RaiseSteps) > 0 {
		o.Chaal = ptr(o.RaiseSteps[0])
	}
	switch r.IntN(4) {
	case 0:
		o.Show = ptr(int64(r.IntN(50_000)))
	case 1:
		if o.Chaal != nil {
			o.Show = ptr(*o.Chaal)
		}
	}
	return o
}

func randomContext(r *rng.Rand) DecisionContext {
	kind := Kinds[r.IntN(len(Kinds))]
	p := NewPersonality(kind, nil, r)
	cats := []string{protocol.CategorySeen, protocol.CategoryBlind, protocol.CategoryVariation, ""}
	cat := cats[r.IntN(len(cats))]
	o := randomOptions(r)
	var h decision.HandEvaluation
	if !o.CanSee && r.Chance(0.85) {
		h = strengthHand(r.Float64())
		h.Confidence = r.Float64()
	}
	vars := []string{"", protocol.VariationMuflis, protocol.VariationFiveCard, protocol.VariationAK47}
	return DecisionContext{
		Category:      cat,
		Variation:     vars[r.IntN(len(vars))],
		Options:       o,
		IsBlind:       o.CanSee,
		Hand:          h,
		Pot:           int64(r.IntN(100_000)),
		Boot:          int64(r.IntN(5000)),
		Chips:         int64(r.IntN(1_000_000)),
		Contribution:  int64(r.IntN(50_000)),
		ActivePlayers: r.IntN(7),
		Pressure:      decision.NewPressure(r.IntN(6), int64(r.IntN(1_000_000)), int64(r.IntN(5000)), r.Float64(), r.Float64(), r.IntN(5)),
		Tilt:          r.Float64(),
		Personality:   p,
		Memory: &HandMemory{
			PlannedBlindTurns: r.IntN(6), BlindTurns: r.IntN(8), SeenTurns: r.IntN(8),
			RaisesFaced: r.IntN(5), RaisedThisHand: r.IntN(5), ChangedMind: r.Chance(0.5),
		},
		EnableBlind: r.Chance(0.9),
		EnableSeen:  r.Chance(0.9),
	}
}

// Over tens of thousands of random turns — every family, blind and seen,
// every category — Decide returns a legal move, or waits only when nothing
// at all is legal; it never names a Force Sideshow or a missile. And the
// strategy itself never needs the safety net: before the fallback its choice
// is already legal.
func TestDecideIsAlwaysLegal(t *testing.T) {
	r := rng.New(20260927)
	const n = 60_000
	byKind := map[Kind]int{}
	for i := 0; i < n; i++ {
		ctx := randomContext(r)
		byKind[ctx.Personality.Kind]++
		raw := choose(ctx, rng.New(uint64(i)))
		switch {
		case raw.Action == "" && raw.Reason == ReasonNoLegalMove:
			if anyLegal(ctx.Options) {
				t.Fatalf("turn %d: waited with a legal move on offer: %+v", i, ctx.Options)
			}
		case raw.Action == "":
			t.Fatalf("turn %d: the strategy chose nothing (%+v) for %+v", i, raw, ctx.Options)
		case !Legal(raw, ctx.Options):
			t.Fatalf("turn %d: the strategy chose an illegal %+v for %+v (%s)", i, raw, ctx.Options, ctx.Personality.Kind)
		}

		d := Decide(ctx, rng.New(uint64(i)))
		if d.Action == protocol.ActionForceSideshow || d.Action == protocol.ActionMissile {
			t.Fatalf("turn %d: %s costs what a bot never spends", i, d.Action)
		}
		if d.Action == "" {
			if d.Reason != ReasonNoLegalMove || anyLegal(ctx.Options) {
				t.Fatalf("turn %d: no move (%+v) with %+v", i, d, ctx.Options)
			}
			continue
		}
		if !Legal(d, ctx.Options) {
			t.Fatalf("turn %d: illegal %+v for %+v", i, d, ctx.Options)
		}
		if d.Reason == ReasonSafeFallback {
			t.Fatalf("turn %d: the safety net was needed for %+v", i, ctx.Options)
		}
		if d.Action != protocol.ActionChaal && d.Action != protocol.ActionRaise && d.Amount != 0 {
			t.Fatalf("turn %d: %+v carries an amount", i, d)
		}
		// Nothing but a pack on offer: it packs.
		if !ctx.Options.CanSee && !ctx.Options.CanSideshow && !showLegal(ctx.Options) && len(decision.RaiseRungs(ctx.Options)) == 0 {
			if _, ok := decision.ChaalAmount(ctx.Options); !ok && ctx.Options.CanPack && d.Action != protocol.ActionPack {
				t.Fatalf("turn %d: only a pack was legal and it chose %+v", i, d)
			}
		}
	}
	for _, k := range Kinds {
		if byKind[k] < n/10 {
			t.Fatalf("the fuzz barely covered %s: %v", k, byKind)
		}
	}
}

func TestSideshowAnswersNeverPanicOnRandomTurns(t *testing.T) {
	r := rng.New(5)
	for i := 0; i < 20_000; i++ {
		ctx := randomContext(r)
		answer, accept := SideshowAnswer(ctx, r)
		if !answer && accept {
			t.Fatalf("a lapsed answer that accepts")
		}
	}
}

func TestTheFallbackIsThePlainestLegalMove(t *testing.T) {
	o := options(200, false, 3, 5_000, 1_000, true, true)
	if d := fallback(o); d.Action != protocol.ActionChaal || d.Amount != 400 || !Legal(d, o) {
		t.Fatalf("fallback %+v", d)
	}
	o.RaiseSteps = []int64{}
	o.Show = ptr(300)
	if d := fallback(o); d.Action != protocol.ActionShow {
		t.Fatalf("fallback %+v", d)
	}
	o.Show = nil
	if d := fallback(o); d.Action != protocol.ActionPack {
		t.Fatalf("fallback %+v", d)
	}
	o.CanPack, o.CanSee = false, true
	if d := fallback(o); d.Action != protocol.ActionSee {
		t.Fatalf("fallback %+v", d)
	}
	o.CanSee = false
	if d := fallback(o); d.Action != "" || d.Reason != ReasonNoLegalMove {
		t.Fatalf("fallback %+v", d)
	}
}
