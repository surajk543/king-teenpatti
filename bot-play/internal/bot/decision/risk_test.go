package decision

import (
	"math"
	"testing"
)

func TestPressureWithNoRaisesAndNoReadsIsLow(t *testing.T) {
	p := NewPressure(0, 0, 200, 0, 0, 0)
	if math.Abs(p.Level-0.14) > 1e-9 {
		t.Fatalf("level %.3f, want 0.14", p.Level)
	}
	if p.OpponentAggression != NeutralRead || p.OpponentLooseness != NeutralRead {
		t.Fatalf("no read must read neutral: %+v", p)
	}
}

func TestPressureRisesWithRaisesTheirSizeAndAggressiveOpponents(t *testing.T) {
	prev := -1.0
	for n := 0; n <= 6; n++ {
		l := NewPressure(n, 800, 200, 0.5, 0.5, 0).Level
		if l <= prev {
			t.Fatalf("%d raises: level %.3f, not above %.3f", n, l, prev)
		}
		prev = l
	}
	prev = -1
	for _, raise := range []int64{0, 400, 800, 3200, 12800, 1 << 20} {
		l := NewPressure(1, raise, 200, 0.5, 0.5, 0).Level
		if l < prev {
			t.Fatalf("a raise of %d: level %.3f below %.3f", raise, l, prev)
		}
		prev = l
	}
	if NewPressure(1, 800, 200, 0.9, 0.5, 0).Level <= NewPressure(1, 800, 200, 0.2, 0.5, 0).Level {
		t.Fatal("aggressive opponents do not add pressure")
	}
	if NewPressure(1, 800, 200, 0.5, 0.5, 3).Level >= NewPressure(1, 800, 200, 0.5, 0.5, 0).Level {
		t.Fatal("opponents still blind do not ease it")
	}
	// The same raise means less at a bigger boot.
	if NewPressure(1, 3200, 1000, 0.5, 0.5, 0).Level >= NewPressure(1, 3200, 100, 0.5, 0.5, 0).Level {
		t.Fatal("a raise is not measured against the boot")
	}
}

func TestPressureIsClampedAndTolerant(t *testing.T) {
	cases := []Pressure{
		NewPressure(100, 1<<40, 1, 1, 1, 0),
		NewPressure(-3, -5, 0, -1, 2, -2),
		NewPressure(2, 1000, 0, 0.5, 0.5, 10),
	}
	for _, p := range cases {
		if p.Level < 0 || p.Level > 1 || p.RaisesFaced < 0 || p.BiggestRaise < 0 || p.OpponentsBlind < 0 {
			t.Fatalf("%+v", p)
		}
		if p.OpponentAggression < 0 || p.OpponentAggression > 1 || p.OpponentLooseness < 0 || p.OpponentLooseness > 1 {
			t.Fatalf("reads outside 0..1: %+v", p)
		}
	}
	if NewPressure(100, 1<<40, 1, 1, 1, 0).Level < 0.9 {
		t.Fatal("a table raising without end is not high pressure")
	}
}

func TestRiskShare(t *testing.T) {
	for _, c := range []struct {
		amount, chips int64
		want          float64
	}{{0, 1000, 0}, {-5, 1000, 0}, {100, 1000, 0.1}, {1000, 1000, 1}, {5000, 1000, 1}, {10, 0, 1}} {
		if got := RiskShare(c.amount, c.chips); got != c.want {
			t.Errorf("RiskShare(%d, %d) = %v, want %v", c.amount, c.chips, got, c.want)
		}
	}
}
