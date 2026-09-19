package poker

import (
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

func cards(codes ...string) []game.Card { return game.ParseCards(codes) }

func TestEvaluate5NamesEveryCategoryWithTheRightTiebreaks(t *testing.T) {
	cases := []struct {
		codes    []string
		category Category
		score    []int
	}{
		{[]string{"As", "Ks", "Qs", "Js", "Ts"}, RoyalFlush, []int{9}},
		{[]string{"9h", "8h", "7h", "6h", "5h"}, StraightFlush, []int{8, 9}},
		{[]string{"5c", "4c", "3c", "2c", "Ac"}, StraightFlush, []int{8, 5}}, // the steel wheel
		{[]string{"7s", "7h", "7d", "7c", "2s"}, FourOfAKind, []int{7, 7, 2}},
		{[]string{"Ks", "Kh", "Kd", "3c", "3s"}, FullHouse, []int{6, 13, 3}},
		{[]string{"Ad", "Td", "8d", "5d", "2d"}, Flush, []int{5, 14, 10, 8, 5, 2}},
		{[]string{"Ts", "9h", "8d", "7c", "6s"}, Straight, []int{4, 10}},
		{[]string{"5s", "4h", "3d", "2c", "As"}, Straight, []int{4, 5}}, // the wheel: ace low
		{[]string{"Qs", "Qh", "Qd", "9c", "4s"}, ThreeOfAKind, []int{3, 12, 9, 4}},
		{[]string{"Js", "Jh", "4d", "4c", "As"}, TwoPair, []int{2, 11, 4, 14}},
		{[]string{"9s", "9h", "Kd", "7c", "2s"}, Pair, []int{1, 9, 13, 7, 2}},
		{[]string{"Ks", "Jh", "9d", "6c", "3s"}, HighCard, []int{0, 13, 11, 9, 6, 3}},
	}
	for _, tc := range cases {
		h := Evaluate5(cards(tc.codes...))
		if h.Category != int(tc.category) || h.Name != CategoryNames[tc.category] {
			t.Errorf("%v: got %s (%d), want %s", tc.codes, h.Name, h.Category, CategoryNames[tc.category])
		}
		if !equalInts(h.Score, tc.score) {
			t.Errorf("%v: score %v, want %v", tc.codes, h.Score, tc.score)
		}
		if len(h.Best) != 5 || len(h.Cards) != 5 {
			t.Errorf("%v: cards %v best %v", tc.codes, h.Cards, h.Best)
		}
	}
}

// An ace never plays low except in the wheel: A-K-Q-J-9 is not a straight,
// and neither is K-A-2-3-4 ("round the corner").
func TestEvaluate5AceIsHighEverywhereButTheWheel(t *testing.T) {
	if h := Evaluate5(cards("As", "Kh", "Qd", "Jc", "9s")); h.Category != int(HighCard) {
		t.Fatalf("A-K-Q-J-9 is %s", h.Name)
	}
	if h := Evaluate5(cards("Ks", "Ah", "2d", "3c", "4s")); h.Category != int(HighCard) {
		t.Fatalf("K-A-2-3-4 is %s", h.Name)
	}
	if Compare(Evaluate5(cards("6s", "5h", "4d", "3c", "2s")), Evaluate5(cards("5s", "4h", "3d", "2c", "As"))) <= 0 {
		t.Fatal("a six-high straight beats the wheel")
	}
}

// Every one of the C(52,5) = 2,598,960 hands, counted by category against
// the textbook frequencies, and Score[0] == Category throughout.
func TestEvaluate5MatchesTheTextbookFrequenciesOverEveryHand(t *testing.T) {
	if testing.Short() {
		t.Skip("2.6 million evaluations")
	}
	deck := game.NewDeck()
	counts := map[Category]int{}
	pick := make([]game.Card, 5)
	total := 0
	for _, combo := range Combinations(52, 5) {
		for i, c := range combo {
			pick[i] = deck[c]
		}
		h := Evaluate5(pick)
		if h.Score[0] != h.Category {
			t.Fatalf("score[0] %d != category %d for %v", h.Score[0], h.Category, h.Cards)
		}
		counts[Category(h.Category)]++
		total++
	}
	want := map[Category]int{
		RoyalFlush: 4, StraightFlush: 36, FourOfAKind: 624, FullHouse: 3744, Flush: 5108,
		Straight: 10200, ThreeOfAKind: 54912, TwoPair: 123552, Pair: 1098240, HighCard: 1302540,
	}
	if total != 2598960 {
		t.Fatalf("evaluated %d hands", total)
	}
	for c, n := range want {
		if counts[c] != n {
			t.Errorf("%s: %d hands, want %d", c, counts[c], n)
		}
	}
}

// Compare is a total order consistent with the category numbers: a hand of
// a higher category always beats one of a lower, whatever the cards.
func TestCompareOrdersCategoriesBeforeTiebreaks(t *testing.T) {
	ladder := [][]string{
		{"Ks", "Jh", "9d", "6c", "3s"}, // high card
		{"2s", "2h", "3d", "4c", "5s"}, // pair
		{"3s", "3h", "2d", "2c", "4s"}, // two pair
		{"2s", "2h", "2d", "3c", "4s"}, // trips
		{"5s", "4h", "3d", "2c", "As"}, // straight (wheel)
		{"2d", "3d", "5d", "7d", "9d"}, // flush
		{"2s", "2h", "2d", "3c", "3s"}, // full house
		{"2s", "2h", "2d", "2c", "3s"}, // quads
		{"5c", "4c", "3c", "2c", "Ac"}, // straight flush
		{"As", "Ks", "Qs", "Js", "Ts"}, // royal
	}
	for i := 1; i < len(ladder); i++ {
		lo, hi := Evaluate5(cards(ladder[i-1]...)), Evaluate5(cards(ladder[i]...))
		if Compare(hi, lo) <= 0 || Compare(lo, hi) >= 0 {
			t.Errorf("%s must beat %s", hi.Name, lo.Name)
		}
	}
	a, b := Evaluate5(cards("9s", "9h", "Kd", "7c", "2s")), Evaluate5(cards("9d", "9c", "Kh", "7s", "2h"))
	if Compare(a, b) != 0 {
		t.Fatal("suits never break ties")
	}
	if Compare(Evaluate5(cards("9s", "9h", "Kd", "7c", "3s")), b) <= 0 {
		t.Fatal("a better kicker wins")
	}
}

func TestCombinationsWalkInIndexOrder(t *testing.T) {
	got := Combinations(4, 2)
	want := [][]int{{0, 1}, {0, 2}, {0, 3}, {1, 2}, {1, 3}, {2, 3}}
	if len(got) != len(want) {
		t.Fatalf("%v", got)
	}
	for i := range want {
		if !equalInts(got[i], want[i]) {
			t.Fatalf("combo %d: %v, want %v", i, got[i], want[i])
		}
	}
	if n := len(Combinations(7, 5)); n != 21 {
		t.Fatalf("C(7,5) = %d", n)
	}
	if n := len(Combinations(52, 5)); n != 2598960 {
		t.Fatalf("C(52,5) = %d", n)
	}
	if Combinations(3, 5) != nil || Combinations(3, 0) != nil {
		t.Fatal("impossible combinations are none")
	}
}

// Hold'em: the best five of seven, and Best names them in the order held.
func TestBestHoldemFindsTheBestFiveOfSeven(t *testing.T) {
	hole := cards("Ah", "Kh")
	board := cards("Qh", "Jh", "2c", "Th", "9d")
	h, ok := BestHoldem(hole, board)
	if !ok || h.Category != int(RoyalFlush) {
		t.Fatalf("got %s", h.Name)
	}
	if !equalStrings(h.Best, []string{"Ah", "Kh", "Qh", "Jh", "Th"}) {
		t.Fatalf("best %v", h.Best)
	}
	if !equalStrings(h.Cards, []string{"Ah", "Kh", "Qh", "Jh", "2c", "Th", "9d"}) {
		t.Fatalf("cards %v", h.Cards)
	}
	// The board plays: a pair in the hole loses to two pair on the board with
	// a better kicker.
	a, _ := BestHoldem(cards("3s", "3d"), cards("Ks", "Kd", "9s", "9d", "7c"))
	b, _ := BestHoldem(cards("As", "2d"), cards("Ks", "Kd", "9s", "9d", "7c"))
	if Compare(b, a) <= 0 {
		t.Fatalf("A kicker %v should beat the threes %v", b.Best, a.Best)
	}
	if _, ok := BestHoldem(cards("As", "2d"), cards("Ks", "Kd")); ok {
		t.Fatal("no hand before five cards")
	}
	// An independent check: the best of seven never loses to any five of them.
	all := append(append([]game.Card(nil), hole...), board...)
	best, _ := BestHoldem(hole, board)
	pick := make([]game.Card, 5)
	for _, combo := range Combinations(7, 5) {
		for i, c := range combo {
			pick[i] = all[c]
		}
		if Compare(Evaluate5(pick), best) > 0 {
			t.Fatalf("a five-card subset beats the best")
		}
	}
}

// Omaha: exactly two hole cards. A player holding four of a suit with one
// on the board has NO flush; a player holding A-A-A-A has only a pair of aces.
func TestBestOmahaUsesExactlyTwoHoleCards(t *testing.T) {
	h, ok := BestOmaha(cards("Ah", "Kh", "Qh", "Jh"), cards("Th", "2c", "3d", "4s", "9s"))
	if !ok {
		t.Fatal("no hand")
	}
	if h.Category == int(Flush) {
		t.Fatalf("four hearts in the hole and one on the board is no flush: %s %v", h.Name, h.Best)
	}
	quadAces, _ := BestOmaha(cards("As", "Ah", "Ad", "Ac"), cards("2c", "7d", "9s", "Jh", "Kh"))
	if quadAces.Category != int(Pair) {
		t.Fatalf("four aces in the hole play as a pair, got %s", quadAces.Name)
	}
	// Two hole + three board that DO make a flush.
	flush, _ := BestOmaha(cards("Ah", "Kh", "2c", "3d"), cards("Th", "9h", "5h", "4s", "9s"))
	if flush.Category != int(Flush) {
		t.Fatalf("got %s", flush.Name)
	}
	if len(flush.Best) != 5 {
		t.Fatalf("best %v", flush.Best)
	}
	holeInBest := 0
	for _, code := range flush.Best {
		if code == "Ah" || code == "Kh" || code == "2c" || code == "3d" {
			holeInBest++
		}
	}
	if holeInBest != 2 {
		t.Fatalf("best %v uses %d hole cards", flush.Best, holeInBest)
	}
	if _, ok := BestOmaha(cards("Ah", "Kh", "2c", "3d"), cards("Th", "9h")); ok {
		t.Fatal("no hand before the flop")
	}
}

func TestEvaluate3IsTeenPattiWithTheTopTwoSwappedAndAceLowLast(t *testing.T) {
	cases := []struct {
		codes    []string
		category int
	}{
		{[]string{"Qs", "Ks", "As"}, StraightFlush3},
		{[]string{"7s", "7h", "7d"}, ThreeOfAKind3},
		{[]string{"9s", "8h", "7d"}, Straight3},
		{[]string{"2s", "8s", "Ks"}, Flush3},
		{[]string{"9s", "9h", "2d"}, Pair3},
		{[]string{"Ks", "Jh", "4d"}, HighCard3},
	}
	for _, tc := range cases {
		h := Evaluate3(cards(tc.codes...))
		if h.Category != tc.category || h.Name != CategoryNames3[tc.category] || h.Score[0] != tc.category {
			t.Errorf("%v: %s (%d) %v", tc.codes, h.Name, h.Category, h.Score)
		}
	}
	// Straight flush beats three of a kind (Teen Patti has it the other way).
	if Compare(Evaluate3(cards("2s", "3s", "4s")), Evaluate3(cards("As", "Ah", "Ad"))) <= 0 {
		t.Fatal("a straight flush beats three aces in 3-Card Poker")
	}
	// A-K-Q is the best straight, A-2-3 the worst, 4-3-2 above it.
	akq, wheel, low := Evaluate3(cards("As", "Kh", "Qd")), Evaluate3(cards("As", "2h", "3d")), Evaluate3(cards("4s", "3h", "2d"))
	if Compare(akq, wheel) <= 0 || Compare(low, wheel) <= 0 {
		t.Fatalf("A-K-Q %v > 4-3-2 %v > A-2-3 %v", akq.Score, low.Score, wheel.Score)
	}
}

// Every one of the C(52,3) = 22,100 three-card hands, by category: the
// counts are Teen Patti's, only the order differs.
func TestEvaluate3MatchesTheTextbookFrequencies(t *testing.T) {
	deck := game.NewDeck()
	counts := map[int]int{}
	pick := make([]game.Card, 3)
	for _, combo := range Combinations(52, 3) {
		for i, c := range combo {
			pick[i] = deck[c]
		}
		counts[Evaluate3(pick).Category]++
	}
	want := map[int]int{StraightFlush3: 48, ThreeOfAKind3: 52, Straight3: 720, Flush3: 1096, Pair3: 3744, HighCard3: 16440}
	for c, n := range want {
		if counts[c] != n {
			t.Errorf("%s: %d, want %d", CategoryNames3[c], counts[c], n)
		}
	}
}

func TestDealerQualifiesWithQueenHighOrBetter(t *testing.T) {
	if !DealerQualifies(Evaluate3(cards("Qs", "7h", "2d"))) {
		t.Fatal("queen high qualifies")
	}
	if DealerQualifies(Evaluate3(cards("Js", "Th", "2d"))) {
		t.Fatal("jack high does not")
	}
	if !DealerQualifies(Evaluate3(cards("2s", "2h", "3d"))) {
		t.Fatal("a pair qualifies")
	}
}

func equalInts(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
