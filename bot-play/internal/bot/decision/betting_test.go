package decision

import (
	"testing"

	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

func turn(chips int64, steps ...int64) protocol.TurnOptions {
	return protocol.TurnOptions{RaiseSteps: steps, Chips: chips, CanPack: true}
}

func TestPotOdds(t *testing.T) {
	for _, c := range []struct {
		chaal, pot int64
		want       float64
	}{{400, 1200, 0.25}, {100, 0, 1}, {0, 500, 0}, {-1, 500, 0}, {100, -50, 1}} {
		if got := PotOdds(c.chaal, c.pot); got != c.want {
			t.Errorf("PotOdds(%d, %d) = %v, want %v", c.chaal, c.pot, got, c.want)
		}
	}
}

func TestChaalAmountAndRaiseRungs(t *testing.T) {
	o := turn(5000, 400, 800, 1600, 3200, 6400)
	if a, ok := ChaalAmount(o); !ok || a != 400 {
		t.Fatalf("chaal %d %v", a, ok)
	}
	if got := RaiseRungs(o); len(got) != 3 || got[0] != 800 || got[2] != 3200 {
		t.Fatalf("rungs %v (the stack covers up to 3200)", got)
	}
	for _, amount := range []int64{800, 1600, 3200} {
		if !IsRaiseRung(o, amount) {
			t.Errorf("%d is a rung", amount)
		}
	}
	for _, amount := range []int64{400, 1200, 6400, 0, -800} {
		if IsRaiseRung(o, amount) {
			t.Errorf("%d is no raise", amount)
		}
	}
	if _, ok := ChaalAmount(turn(300, 400, 800)); ok {
		t.Error("a chaal the stack does not cover")
	}
	if _, ok := ChaalAmount(turn(5000)); ok {
		t.Error("a chaal from an empty ladder")
	}
	if got := RaiseRungs(turn(5000, 400, 700, 900)); len(got) != 1 || got[0] != 900 {
		t.Fatalf("rungs %v: a raise is at least twice the chaal", got)
	}
	// Overflow: a rung near the top of int64 is compared without doubling it.
	huge := int64(1) << 62
	if IsRaiseRung(turn(1<<62, huge, huge+1), huge+1) {
		t.Error("a rung just over the chaal passed as a raise")
	}
}

func TestRaiseAmountNamesALegalRung(t *testing.T) {
	r := rng.New(1)
	o := turn(100_000, 400, 800, 1600, 3200, 6400, 12800, 25600, 51200)
	for i := 0; i < 5000; i++ {
		a, ok := RaiseAmount(o, r.Float64(), r.Float64(), r)
		if !ok || !IsRaiseRung(o, a) {
			t.Fatalf("named %d (%v)", a, ok)
		}
	}
	for _, o := range []protocol.TurnOptions{turn(100_000), turn(100_000, 400), turn(700, 400, 800), turn(100_000, 400, 600)} {
		if a, ok := RaiseAmount(o, 1, 1, r); ok {
			t.Fatalf("%v: named %d where no raise is legal", o.RaiseSteps, a)
		}
	}
}

func TestRaiseAmountClimbsWithAggressionAndPowerWithinTheBudget(t *testing.T) {
	o := turn(1_000_000, 400, 800, 1600, 3200, 6400, 12800, 25600, 51200, 102400, 204800)
	mean := func(aggression, power float64) float64 {
		r := rng.New(2)
		sum := 0.0
		for i := 0; i < 4000; i++ {
			a, _ := RaiseAmount(o, aggression, power, r)
			sum += float64(a)
			if budget := 1_000_000 * clamp(0.03+0.3*aggression*power, 0.02, 0.5); float64(a) > budget {
				t.Fatalf("raised %d over a budget of %.0f", a, budget)
			}
		}
		return sum / 4000
	}
	calm, bold, boldStrong := mean(0.1, 0.5), mean(0.9, 0.5), mean(0.9, 1)
	if !(calm < bold && bold < boldStrong) || boldStrong < 2.5*calm {
		t.Fatalf("mean raises: careful %.0f, aggressive %.0f, aggressive with a monster %.0f", calm, bold, boldStrong)
	}
	// When no rung fits the budget the lowest raise is named.
	short := turn(10_000, 4000, 8000)
	if a, ok := RaiseAmount(short, 0, 0, rng.New(3)); !ok || a != 8000 {
		t.Fatalf("got %d %v", a, ok)
	}
	// The reach is the draw: a scripted draw of 0 names the lowest rung.
	if a, _ := RaiseAmount(o, 1, 1, rng.From(&rng.Script{Values: []float64{0}})); a != 800 {
		t.Fatalf("a draw of 0 named %d", a)
	}
}
