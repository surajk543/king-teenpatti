package rng

import (
	"math"
	"sort"
	"testing"
)

func TestTheSameSeedReplaysAndSeedsDiffer(t *testing.T) {
	a, b, c := New(42), New(42), New(43)
	same, diff := true, false
	for i := 0; i < 100; i++ {
		x, y, z := a.Float64(), b.Float64(), c.Float64()
		same = same && x == y
		diff = diff || x != z
	}
	if !same || !diff {
		t.Fatalf("same seed replays: %v; another seed differs: %v", same, diff)
	}
}

func TestNeighbouringBotsGetUncorrelatedStreams(t *testing.T) {
	// Bot i and bot i+1 of one fleet seed must not start alike.
	close := 0
	for i := 0; i < 1000; i++ {
		if math.Abs(Derive(7, i).Float64()-Derive(7, i+1).Float64()) < 0.01 {
			close++
		}
	}
	if close > 40 { // ~20 expected by chance
		t.Fatalf("%d of 1000 neighbouring streams started within 0.01 of each other", close)
	}
}

func TestDrawsStayInRange(t *testing.T) {
	r := New(1)
	for i := 0; i < 10000; i++ {
		if f := r.Float64(); f < 0 || f >= 1 {
			t.Fatalf("Float64 %v", f)
		}
		if n := r.IntN(7); n < 0 || n >= 7 {
			t.Fatalf("IntN %d", n)
		}
		if b := r.Between(2, 5); b < 2 || b >= 5 {
			t.Fatalf("Between %v", b)
		}
	}
	if r.Chance(0) || !r.Chance(1) || r.IntN(0) != 0 {
		t.Fatal("edges")
	}
}

func TestLogNormalIsSkewedAroundItsMedian(t *testing.T) {
	r := New(9)
	xs := make([]float64, 20000)
	sum := 0.0
	for i := range xs {
		xs[i] = r.LogNormal(1000, 0.4)
		sum += xs[i]
	}
	sort.Float64s(xs)
	median, mean := xs[len(xs)/2], sum/float64(len(xs))
	if math.Abs(median-1000) > 30 || mean <= median {
		t.Fatalf("median %.0f (want ~1000), mean %.0f (want above the median)", median, mean)
	}
}

func TestWeightedFollowsItsWeightsAndSkipsZeroes(t *testing.T) {
	r := New(3)
	counts := make([]int, 3)
	for i := 0; i < 30000; i++ {
		counts[r.Weighted([]float64{1, 0, 3})]++
	}
	if counts[1] != 0 || math.Abs(float64(counts[2])/float64(counts[0])-3) > 0.2 {
		t.Fatalf("counts %v", counts)
	}
	if r.Weighted([]float64{0, -1}) != 0 {
		t.Fatal("all non-positive picks 0")
	}
}

func TestAScriptReplaysItsValues(t *testing.T) {
	r := From(&Script{Values: []float64{0.1, 0.9}})
	if r.Float64() != 0.1 || r.Float64() != 0.9 || r.Float64() != 0.1 {
		t.Fatal("script order")
	}
}
