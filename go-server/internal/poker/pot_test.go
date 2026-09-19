package poker

import (
	"testing"
)

func TestSidePotsWithNoAllInIsOnePot(t *testing.T) {
	pots := SidePots(map[int]int64{0: 300, 1: 300, 2: 300}, map[int]bool{0: true, 1: true, 2: true})
	if len(pots) != 1 || pots[0].Amount != 900 || !equalInts(pots[0].Eligible, []int{0, 1, 2}) {
		t.Fatalf("%+v", pots)
	}
}

func TestSidePotsFormAtEveryAllInLevel(t *testing.T) {
	// Seat 0 all-in for 100, seat 1 all-in for 250, seats 2 and 3 put in 400.
	contrib := map[int]int64{0: 100, 1: 250, 2: 400, 3: 400}
	pots := SidePots(contrib, map[int]bool{0: true, 1: true, 2: true, 3: true})
	want := []Pot{
		{Amount: 400, Eligible: []int{0, 1, 2, 3}},
		{Amount: 450, Eligible: []int{1, 2, 3}},
		{Amount: 300, Eligible: []int{2, 3}},
	}
	if len(pots) != len(want) {
		t.Fatalf("%+v", pots)
	}
	var total int64
	for i := range want {
		if pots[i].Amount != want[i].Amount || !equalInts(pots[i].Eligible, want[i].Eligible) {
			t.Fatalf("pot %d: %+v, want %+v", i, pots[i], want[i])
		}
		total += pots[i].Amount
	}
	if total != 1150 {
		t.Fatalf("total %d", total)
	}
}

// A folded player's chips stay in the pots they reached; they win none.
func TestSidePotsExcludeFoldedSeatsButKeepTheirChips(t *testing.T) {
	contrib := map[int]int64{0: 100, 1: 400, 2: 400}
	pots := SidePots(contrib, map[int]bool{0: true, 2: true}) // seat 1 folded after putting 400 in
	if len(pots) != 2 {
		t.Fatalf("%+v", pots)
	}
	if pots[0].Amount != 300 || !equalInts(pots[0].Eligible, []int{0, 2}) {
		t.Fatalf("main %+v", pots[0])
	}
	if pots[1].Amount != 600 || !equalInts(pots[1].Eligible, []int{2}) {
		t.Fatalf("side %+v", pots[1])
	}
}

func TestAwardSplitsATieAndGivesOddChipsClockwiseFromTheButton(t *testing.T) {
	pots := []Pot{{Amount: 1001, Eligible: []int{0, 2, 4}}}
	hands := map[int]Hand{
		0: Evaluate5(cards("As", "Kd", "Qc", "Jh", "9s")),
		2: Evaluate5(cards("Ah", "Kc", "Qd", "Js", "9h")), // ties seat 0
		4: Evaluate5(cards("2s", "3d", "7c", "8h", "9s")),
	}
	// Button at seat 3: seat 4 is first clockwise, then 0, then 2.
	payouts, totals := Award(pots, hands, 3, 5)
	if totals[4] != 0 || totals[0] != 501 || totals[2] != 500 {
		t.Fatalf("totals %v payouts %+v", totals, payouts)
	}
	// Button at seat 0: seat 2 is nearer the button's left than seat 0 itself.
	_, totals = Award(pots, hands, 0, 5)
	if totals[2] != 501 || totals[0] != 500 {
		t.Fatalf("totals %v", totals)
	}
}

func TestAwardPaysEachPotToItsOwnBestHand(t *testing.T) {
	pots := []Pot{
		{Amount: 300, Eligible: []int{0, 1, 2}},
		{Amount: 400, Eligible: []int{1, 2}},
	}
	hands := map[int]Hand{
		0: Evaluate5(cards("As", "Ad", "Ac", "Kh", "Ks")), // full house: wins the main pot only
		1: Evaluate5(cards("2s", "3d", "7c", "8h", "9s")),
		2: Evaluate5(cards("Ts", "Th", "4d", "5c", "6s")), // pair: wins the side pot
	}
	_, totals := Award(pots, hands, 0, 3)
	if totals[0] != 300 || totals[2] != 400 || totals[1] != 0 {
		t.Fatalf("totals %v", totals)
	}
	var sum int64
	for _, v := range totals {
		sum += v
	}
	if sum != 700 {
		t.Fatalf("chips created or lost: %d", sum)
	}
}
