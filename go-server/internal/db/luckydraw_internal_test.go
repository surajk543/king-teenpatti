package db

import (
	"errors"
	"math"
	"testing"
)

// The weighted draw on its own, with no database: the slots lie end to end
// along [0, total), each as long as its weight.

func wheel(weights ...int64) []LuckyDrawSlot {
	slots := make([]LuckyDrawSlot, len(weights))
	for i, w := range weights {
		slots[i] = LuckyDrawSlot{SlotNumber: i + 1, weight: w}
	}
	return slots
}

// Every number the draw can be handed lands on exactly one slot, in order, and
// every slot with a weight is reached — whatever the weights add up to.
func TestPickWeightedLaysTheSlotsEndToEnd(t *testing.T) {
	slots := wheel(3, 1, 2)
	want := []int{1, 1, 1, 2, 3, 3}
	for r, slot := range want {
		got, err := pickWeighted(slots, func(n int64) (int64, error) {
			if n != 6 {
				t.Fatalf("handed %d, want the total weight 6", n)
			}
			return int64(r), nil
		})
		if err != nil || got.SlotNumber != slot {
			t.Fatalf("drew %d: slot %d %v, want %d", r, got.SlotNumber, err, slot)
		}
	}
	for _, r := range []int64{-1, 6} {
		if _, err := pickWeighted(slots, func(int64) (int64, error) { return r, nil }); err == nil {
			t.Fatalf("a number outside [0, 6) was accepted: %d", r)
		}
	}
	// A slot of no weight is never drawn; a wheel of none cannot be spun.
	for r := int64(0); r < 5; r++ {
		got, _ := pickWeighted(wheel(2, 0, 3), func(int64) (int64, error) { return r, nil })
		if got.SlotNumber == 2 {
			t.Fatalf("a slot of weight 0 was drawn at %d", r)
		}
	}
	if _, err := pickWeighted(wheel(0, 0), cryptoPick); !errors.Is(err, ErrLuckyDrawUnavailable) {
		t.Fatalf("a wheel of no weight: %v", err)
	}
}

// Drawn from crypto/rand, each slot comes up in proportion to its weight. With
// 60,000 draws the seeded wheel's shares are known to within a fifth of a
// percent (one standard deviation of the 40% slot); two percent is ten of
// those, so this fails for a wrong draw and not by chance.
func TestPickWeightedFollowsTheWeights(t *testing.T) {
	weights := []int64{40, 20, 15, 10, 10, 5}
	slots := wheel(weights...)
	const draws = 60000
	counts := make([]int, len(weights))
	for i := 0; i < draws; i++ {
		got, err := pickWeighted(slots, cryptoPick)
		if err != nil {
			t.Fatal(err)
		}
		counts[got.SlotNumber-1]++
	}
	for i, w := range weights {
		share := float64(counts[i]) / draws
		if math.Abs(share-float64(w)/100) > 0.02 {
			t.Fatalf("slot %d came up %.3f of the time, weight %d%%", i+1, share, w)
		}
	}
}
