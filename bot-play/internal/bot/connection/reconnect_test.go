package connection

import (
	"math"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

func TestBackoffDoublesFromOneSecondToTheCap(t *testing.T) {
	b := Backoff{Jitter: -1} // no spread
	want := []time.Duration{1, 2, 4, 8, 16, 30, 30, 30}
	for i, w := range want {
		if got := b.Delay(i+1, rng.New(1)); got != w*time.Second {
			t.Errorf("attempt %d: %s, want %s", i+1, got, w*time.Second)
		}
	}
	for _, attempt := range []int{0, -1, math.MinInt} {
		if got := b.Delay(attempt, nil); got != time.Second {
			t.Errorf("attempt %d: %s, want the first attempt's 1s", attempt, got)
		}
	}
	for _, attempt := range []int{64, 1000, math.MaxInt} {
		if got := b.Delay(attempt, nil); got != 30*time.Second {
			t.Errorf("attempt %d: %s, want the cap", attempt, got)
		}
	}
}

func TestANilRandSpreadsNothing(t *testing.T) {
	var b Backoff // every default: 1 s, 30 s, 2, 0.3
	if got := b.Delay(3, nil); got != 4*time.Second {
		t.Fatalf("got %s", got)
	}
}

func TestJitterStaysInsideItsBand(t *testing.T) {
	var b Backoff // Jitter 0.3
	r := rng.New(42)
	lowSeen, highSeen := false, false
	for attempt := 1; attempt <= 40; attempt++ {
		mid := math.Min(float64(time.Second)*math.Pow(2, float64(attempt-1)), float64(30*time.Second))
		for i := 0; i < 500; i++ {
			d := float64(b.Delay(attempt, r))
			if d < mid*0.7-1 || d > mid*1.3+1 {
				t.Fatalf("attempt %d: %s outside ±30%% of %s", attempt, time.Duration(d), time.Duration(mid))
			}
			if d > float64(30*time.Second)*1.3 {
				t.Fatalf("attempt %d: %s above Max·(1+Jitter)", attempt, time.Duration(d))
			}
			if d < mid*0.8 {
				lowSeen = true
			}
			if d > mid*1.2 {
				highSeen = true
			}
		}
	}
	if !lowSeen || !highSeen {
		t.Fatal("the jitter never reached the ends of its band")
	}
}

func TestTheSameSeedGivesTheSameWaits(t *testing.T) {
	var b Backoff
	r1, r2 := rng.New(7), rng.New(7)
	for attempt := 1; attempt <= 10; attempt++ {
		if a, c := b.Delay(attempt, r1), b.Delay(attempt, r2); a != c {
			t.Fatalf("attempt %d: %s and %s from one seed", attempt, a, c)
		}
	}
	a, c := b.Delay(5, rng.Derive(1, 0)), b.Delay(5, rng.Derive(1, 1))
	if a == c {
		t.Fatal("two bots of a fleet waited exactly alike")
	}
}

func TestOutOfRangeSettingsAreClamped(t *testing.T) {
	// Jitter above 1 is 1: never negative, never above twice the cap.
	wild := Backoff{Base: time.Second, Max: 4 * time.Second, Jitter: 5}
	r := rng.From(&rng.Script{Values: []float64{0, 0.999999, 0.5}})
	for i := 0; i < 30; i++ {
		d := wild.Delay(10, r)
		if d < 0 || d > 8*time.Second {
			t.Fatalf("%s outside [0, 2·Max]", d)
		}
	}
	// A factor below 1 never shrinks the wait.
	flat := Backoff{Base: 500 * time.Millisecond, Factor: 0.5, Jitter: -1}
	if got := flat.Delay(6, nil); got != 500*time.Millisecond {
		t.Fatalf("a shrinking factor gave %s", got)
	}
	// A base above the cap is the cap.
	high := Backoff{Base: time.Minute, Max: 10 * time.Second, Jitter: -1}
	if got := high.Delay(1, nil); got != 10*time.Second {
		t.Fatalf("a base over the cap gave %s", got)
	}
	// Custom figures.
	custom := Backoff{Base: 100 * time.Millisecond, Max: time.Second, Factor: 3, Jitter: -1}
	for i, w := range []time.Duration{100, 300, 900, 1000} {
		if got := custom.Delay(i+1, nil); got != w*time.Millisecond {
			t.Errorf("attempt %d: %s, want %s", i+1, got, w*time.Millisecond)
		}
	}
	// The lowest and highest draws hit the band's ends exactly.
	edges := Backoff{Jitter: 0.5}
	lo := edges.Delay(2, rng.From(&rng.Script{Values: []float64{0}}))
	if lo != time.Second {
		t.Fatalf("the lowest draw gave %s, want 1s (2s − 50%%)", lo)
	}
}
