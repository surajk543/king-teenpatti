package game

// Mirrors server/test/handRank.test.js (hand-ranking cases) and adds the
// exhaustive checks the Node suite never had: every one of the 22100 3-card
// hands ranks consistently.

import (
	"math/rand"
	"sort"
	"strings"
	"testing"
)

func cards(codes ...string) []Card { return ParseCards(codes) }

func eval(codes ...string) EvaluatedHand { return Evaluate(cards(codes...), EvaluateOptions{}) }

func beats(t *testing.T, winner, loser []string) {
	t.Helper()
	if Compare(eval(winner...), eval(loser...)) <= 0 {
		t.Errorf("%s should beat %s", strings.Join(winner, ","), strings.Join(loser, ","))
	}
}

func ties(t *testing.T, a, b []string) {
	t.Helper()
	if Compare(eval(a...), eval(b...)) != 0 {
		t.Errorf("%s should tie %s", strings.Join(a, ","), strings.Join(b, ","))
	}
}

func TestClassifiesEveryCategory(t *testing.T) {
	cases := []struct {
		codes []string
		want  HandCategory
	}{
		{[]string{"As", "Ah", "Ad"}, Trail},
		{[]string{"As", "Ks", "Qs"}, PureSequence},
		{[]string{"As", "Kh", "Qd"}, Sequence},
		{[]string{"As", "9s", "4s"}, Color},
		{[]string{"As", "Ah", "4d"}, Pair},
		{[]string{"As", "9h", "4d"}, HighCard},
	}
	for _, c := range cases {
		got := eval(c.codes...)
		if got.Category != c.want {
			t.Errorf("%v: category %v, want %v", c.codes, got.Category, c.want)
		}
		if got.Name != CategoryNames[c.want] {
			t.Errorf("%v: name %q, want %q", c.codes, got.Name, CategoryNames[c.want])
		}
		if strings.Join(got.Cards, ",") != strings.Join(c.codes, ",") {
			t.Errorf("%v: cards %v not in input order", c.codes, got.Cards)
		}
	}
}

func TestCategoryNamesAreTheEnglishWireNames(t *testing.T) {
	want := map[HandCategory]string{
		HighCard: "High Card", Pair: "Pair", Color: "Color",
		Sequence: "Sequence", PureSequence: "Pure Sequence", Trail: "Trail",
	}
	for cat, name := range want {
		if CategoryNames[cat] != name || cat.String() != name {
			t.Errorf("category %d: %q / %q, want %q", cat, CategoryNames[cat], cat.String(), name)
		}
	}
	if HighCard != 0 || Pair != 1 || Color != 2 || Sequence != 3 || PureSequence != 4 || Trail != 5 {
		t.Fatal("category numbers must match handRank.js CATEGORY")
	}
}

func TestCategoryOrdering(t *testing.T) {
	ladder := [][]string{
		{"2s", "2h", "2d"}, // lowest trail
		{"As", "Ks", "Qs"}, // best pure sequence
		{"As", "Kh", "Qd"}, // best sequence
		{"As", "Ks", "Js"}, // best possible color
		{"As", "Ah", "Kd"}, // best pair
		{"As", "Kh", "Jd"}, // best high card
	}
	for i := 0; i < len(ladder)-1; i++ {
		beats(t, ladder[i], ladder[i+1])
	}
}

func TestTrailsRankByCardAceHigh(t *testing.T) {
	beats(t, []string{"As", "Ah", "Ad"}, []string{"Ks", "Kh", "Kd"})
	beats(t, []string{"3s", "3h", "3d"}, []string{"2s", "2h", "2d"})
}

func TestSequenceOrder(t *testing.T) {
	beats(t, []string{"As", "Kh", "Qd"}, []string{"As", "2h", "3d"}) // A-K-Q beats A-2-3
	beats(t, []string{"As", "2h", "3d"}, []string{"Ks", "Qh", "Jd"}) // A-2-3 beats K-Q-J
	beats(t, []string{"Ks", "Qh", "Jd"}, []string{"4s", "3h", "2d"}) // K-Q-J beats 4-3-2

	// The doubled run scale from handRank.js.
	if got := eval("As", "Kh", "Qd").Score; got[1] != 28 {
		t.Errorf("A-K-Q strength %d, want 28", got[1])
	}
	if got := eval("As", "2h", "3d").Score; got[1] != 27 {
		t.Errorf("A-2-3 strength %d, want 27", got[1])
	}
	if got := eval("Ks", "Qh", "Jd").Score; got[1] != 26 {
		t.Errorf("K-Q-J strength %d, want 26", got[1])
	}
	if got := eval("4s", "3h", "2d").Score; got[1] != 8 {
		t.Errorf("4-3-2 strength %d, want 8", got[1])
	}
}

func TestWheelIsARunInBothFlavours(t *testing.T) {
	if eval("As", "2s", "3s").Category != PureSequence {
		t.Error("A-2-3 suited should be a pure sequence")
	}
	if eval("As", "2h", "3d").Category != Sequence {
		t.Error("A-2-3 offsuit should be a sequence")
	}
	if eval("As", "2h", "4d").Category != HighCard {
		t.Error("A-2-4 is not a run")
	}
	if eval("Ks", "Ah", "2d").Category != HighCard {
		t.Error("K-A-2 does not wrap around")
	}
}

func TestAceLowVariantDemotesTheWheel(t *testing.T) {
	opts := EvaluateOptions{AceLowIsLowest: true}
	wheel := Evaluate(cards("As", "2h", "3d"), opts)
	low := Evaluate(cards("4s", "3h", "2d"), opts)
	if Compare(low, wheel) <= 0 {
		t.Error("4-3-2 should beat A-2-3 under the variant rule")
	}
	if wheel.Score[1] != 5 {
		t.Errorf("variant wheel strength %d, want 5", wheel.Score[1])
	}
}

func TestColorsCompareCardByCard(t *testing.T) {
	beats(t, []string{"As", "9s", "4s"}, []string{"Kh", "Qh", "9h"})
	beats(t, []string{"As", "9s", "5s"}, []string{"Ah", "9h", "4h"})
	ties(t, []string{"As", "9s", "4s"}, []string{"Ah", "9h", "4h"})
}

func TestPairsComparePairRankThenKicker(t *testing.T) {
	beats(t, []string{"Ks", "Kh", "2d"}, []string{"Qs", "Qh", "Ad"})
	beats(t, []string{"Ks", "Kh", "Ad"}, []string{"Ks", "Kd", "Qh"})
	assertScore(t, eval("As", "Kh", "Kd"), []int{int(Pair), 13, 14})
	assertScore(t, eval("Ks", "Kh", "2d"), []int{int(Pair), 13, 2})
}

func TestHighCardsCompareDescending(t *testing.T) {
	beats(t, []string{"As", "9h", "4d"}, []string{"Ks", "Qh", "9d"})
	beats(t, []string{"As", "Th", "4d"}, []string{"Ah", "9d", "8s"})
	beats(t, []string{"As", "Th", "5d"}, []string{"Ah", "Td", "4s"})
}

func TestRejectsHandsThatAreNotThreeCards(t *testing.T) {
	for _, codes := range [][]string{{"As", "Kh"}, {"As", "Kh", "Qd", "2c"}, {}} {
		func() {
			defer func() {
				r := recover()
				if r == nil {
					t.Errorf("%v: expected a panic", codes)
					return
				}
				if msg, _ := r.(string); !strings.Contains(msg, "exactly 3 cards") {
					t.Errorf("%v: panic %v, want /exactly 3 cards/", codes, r)
				}
			}()
			Evaluate(cards(codes...), EvaluateOptions{})
		}()
	}
}

func TestCompareTreatsMissingScoreElementsAsZero(t *testing.T) {
	a := EvaluatedHand{Score: []int{1, 5}}
	b := EvaluatedHand{Score: []int{1, 5, 0}}
	if Compare(a, b) != 0 || Compare(b, a) != 0 {
		t.Error("a missing element must compare as 0")
	}
	c := EvaluatedHand{Score: []int{1, 5, 3}}
	if Compare(c, a) <= 0 || Compare(a, c) >= 0 {
		t.Error("an extra positive element must win")
	}
}

func assertScore(t *testing.T, got EvaluatedHand, want []int) {
	t.Helper()
	if len(got.Score) != len(want) {
		t.Fatalf("score %v, want %v", got.Score, want)
	}
	for i := range want {
		if got.Score[i] != want[i] {
			t.Fatalf("score %v, want %v", got.Score, want)
		}
	}
}

// ------------------------------------------------------------ exhaustive

// allHands enumerates every 3-card combination of the 52-card deck: 22100.
func allHands() [][]Card {
	deck := NewDeck()
	out := make([][]Card, 0, 22100)
	for i := 0; i < 52; i++ {
		for j := i + 1; j < 52; j++ {
			for k := j + 1; k < 52; k++ {
				out = append(out, []Card{deck[i], deck[j], deck[k]})
			}
		}
	}
	return out
}

func TestEveryHandEvaluatesAndCountsMatchCombinatorics(t *testing.T) {
	hands := allHands()
	if len(hands) != 22100 {
		t.Fatalf("%d hands, want C(52,3) = 22100", len(hands))
	}
	counts := map[HandCategory]int{}
	for _, h := range hands {
		e := Evaluate(h, EvaluateOptions{})
		counts[e.Category]++
		if e.Score[0] != int(e.Category) {
			t.Fatalf("%v: score[0] %d != category %d", e.Cards, e.Score[0], e.Category)
		}
		wantLen := map[HandCategory]int{Trail: 2, PureSequence: 2, Sequence: 2, Color: 4, Pair: 3, HighCard: 4}[e.Category]
		if len(e.Score) != wantLen {
			t.Fatalf("%v: score %v has %d elements, want %d", e.Cards, e.Score, len(e.Score), wantLen)
		}
		// Sorting the input must not change the verdict; suits never do.
		perm := []Card{h[2], h[0], h[1]}
		if Compare(e, Evaluate(perm, EvaluateOptions{})) != 0 {
			t.Fatalf("%v: evaluation depends on card order", e.Cards)
		}
	}
	// Textbook Teen Patti frequencies.
	want := map[HandCategory]int{Trail: 52, PureSequence: 48, Sequence: 720, Color: 1096, Pair: 3744, HighCard: 16440}
	for cat, n := range want {
		if counts[cat] != n {
			t.Errorf("%s: %d hands, want %d", cat, counts[cat], n)
		}
	}
}

// TestCompareIsATotalOrder checks Compare over every hand: it agrees with
// itself under swapping (antisymmetry), sorts consistently (transitivity via
// a full sort followed by an adjacent-pairs sweep), and puts every hand of a
// higher category above every hand of a lower one.
func TestCompareIsATotalOrder(t *testing.T) {
	hands := allHands()
	evals := make([]EvaluatedHand, len(hands))
	for i, h := range hands {
		evals[i] = Evaluate(h, EvaluateOptions{})
	}

	rng := rand.New(rand.NewSource(1))
	for n := 0; n < 200000; n++ {
		a, b := evals[rng.Intn(len(evals))], evals[rng.Intn(len(evals))]
		ab, ba := Compare(a, b), Compare(b, a)
		if (ab > 0) != (ba < 0) || (ab == 0) != (ba == 0) {
			t.Fatalf("antisymmetry broken: %v vs %v → %d / %d", a.Cards, b.Cards, ab, ba)
		}
		if a.Category != b.Category && (ab > 0) != (a.Category > b.Category) {
			t.Fatalf("category must decide first: %v (%s) vs %v (%s) → %d", a.Cards, a.Name, b.Cards, b.Name, ab)
		}
	}

	sorted := make([]EvaluatedHand, len(evals))
	copy(sorted, evals)
	sort.SliceStable(sorted, func(i, j int) bool { return Compare(sorted[i], sorted[j]) < 0 })
	for i := 1; i < len(sorted); i++ {
		if Compare(sorted[i-1], sorted[i]) > 0 {
			t.Fatalf("sort inconsistent at %d: %v > %v", i, sorted[i-1].Cards, sorted[i].Cards)
		}
	}
	// Transitivity spot check on the sorted order: any i<j<k must satisfy
	// Compare(i,k) <= 0 given Compare(i,j) <= 0 and Compare(j,k) <= 0.
	for n := 0; n < 200000; n++ {
		i, j, k := rng.Intn(len(sorted)), rng.Intn(len(sorted)), rng.Intn(len(sorted))
		if i > j {
			i, j = j, i
		}
		if j > k {
			j, k = k, j
		}
		if i > j {
			i, j = j, i
		}
		if Compare(sorted[i], sorted[k]) > 0 {
			t.Fatalf("transitivity broken: %v ≤ %v ≤ %v but first > last", sorted[i].Cards, sorted[j].Cards, sorted[k].Cards)
		}
	}
	// Extremes.
	if sorted[len(sorted)-1].Category != Trail || sorted[len(sorted)-1].Score[1] != 14 {
		t.Errorf("the top hand should be a trail of aces, got %v", sorted[len(sorted)-1].Cards)
	}
	if sorted[0].Category != HighCard || sorted[0].Score[1] != 5 {
		t.Errorf("the bottom hand should be 5-3-2 offsuit, got %v", sorted[0].Cards)
	}
	// Distinct score classes: 6 trails? no — 13 trails, 12 runs each flavour,
	// colors/high cards by 3 distinct ranks, pairs by rank×kicker.
	classes := 1
	for i := 1; i < len(sorted); i++ {
		if Compare(sorted[i-1], sorted[i]) != 0 {
			classes++
		}
	}
	if classes != 13+12+12+274+156+274 {
		t.Errorf("%d distinct score classes, want %d", classes, 13+12+12+274+156+274)
	}
}

// ------------------------------------------------------------ pickWinner

func TestPickWinnerAgreesWithCompare(t *testing.T) {
	hands := allHands()
	rng := rand.New(rand.NewSource(7))
	for n := 0; n < 20000; n++ {
		size := 2 + rng.Intn(4)
		contenders := make([]Contender, size)
		for i := range contenders {
			contenders[i] = Contender{Key: string(rune('a' + i)), Cards: hands[rng.Intn(len(hands))]}
		}
		pick := PickWinner(contenders, nil, EvaluateOptions{})
		if pick == nil {
			t.Fatal("nil pick for a non-empty field")
		}
		best := pick.Hand
		tiedCount := 0
		firstBestIdx := -1
		for i, c := range contenders {
			e := Evaluate(c.Cards, EvaluateOptions{})
			d := Compare(e, best)
			if d > 0 {
				t.Fatalf("%v beats the picked winner %v", e.Cards, best.Cards)
			}
			if d == 0 {
				tiedCount++
				if firstBestIdx == -1 {
					firstBestIdx = i
				}
			}
		}
		if pick.WasTie != (tiedCount > 1) {
			t.Fatalf("wasTie %v with %d tied", pick.WasTie, tiedCount)
		}
		// With no tieBreakOrder, contender order decides (Node's stable sort).
		if pick.Key != contenders[firstBestIdx].Key {
			t.Fatalf("no tieBreakOrder: picked %s, want earliest best %s", pick.Key, contenders[firstBestIdx].Key)
		}
	}
}

func TestPickWinnerTieBreakOrder(t *testing.T) {
	if PickWinner(nil, nil, EvaluateOptions{}) != nil {
		t.Fatal("no contenders → nil")
	}
	// Three-way exact tie: same ranks, different suits.
	contenders := []Contender{
		{Key: "alice", Cards: cards("As", "9s", "4h")},
		{Key: "bob", Cards: cards("Ah", "9h", "4d")},
		{Key: "carol", Cards: cards("Ad", "9d", "4c")},
	}
	pick := PickWinner(contenders, []string{"carol", "bob", "alice"}, EvaluateOptions{})
	if pick.Key != "carol" || !pick.WasTie {
		t.Fatalf("earliest in tieBreakOrder must win: got %s tie=%v", pick.Key, pick.WasTie)
	}
	// Keys absent from the order sort last; the show payer (moved to the end
	// by the Table) therefore loses a tie.
	pick = PickWinner(contenders, []string{"bob"}, EvaluateOptions{})
	if pick.Key != "bob" {
		t.Fatalf("listed key must beat unlisted ones: got %s", pick.Key)
	}
	pick = PickWinner(contenders, []string{"zed"}, EvaluateOptions{})
	if pick.Key != "alice" {
		t.Fatalf("all unlisted → contender order: got %s", pick.Key)
	}
	// A strictly better hand ignores the order entirely.
	contenders[1].Cards = cards("Ah", "Ad", "4c")
	pick = PickWinner(contenders, []string{"carol", "alice"}, EvaluateOptions{})
	if pick.Key != "bob" || pick.WasTie || pick.Hand.Category != Pair {
		t.Fatalf("the best hand wins outright: got %s tie=%v %s", pick.Key, pick.WasTie, pick.Hand.Name)
	}
	if strings.Join(pick.Hand.Cards, ",") != "Ah,Ad,4c" {
		t.Fatalf("winner's cards in input order, got %v", pick.Hand.Cards)
	}
}

func TestPickWinnerHonoursTheVariant(t *testing.T) {
	contenders := []Contender{
		{Key: "wheel", Cards: cards("As", "2h", "3d")},
		{Key: "low", Cards: cards("4s", "3h", "2d")},
	}
	if PickWinner(contenders, nil, EvaluateOptions{}).Key != "wheel" {
		t.Error("standard: A-2-3 beats 4-3-2")
	}
	if PickWinner(contenders, nil, EvaluateOptions{AceLowIsLowest: true}).Key != "low" {
		t.Error("variant: 4-3-2 beats A-2-3")
	}
}
