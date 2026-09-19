package game

import (
	"math/rand"
	"reflect"
	"sort"
	"strings"
	"testing"
)

// The variation rules, tested as the pure functions they are: no table, no
// clock. The window that chooses one is tested in table_variation_test.go.

func cardsOf(codes ...string) []Card { return ParseCards(codes) }

// wins reports whether a beats b under the rules.
func wins(r VariationRules, a, b []Card) bool {
	return r.CompareHands(r.EvaluateHand(a), r.EvaluateHand(b)) > 0
}

// ------------------------------------------------------------ the allowlist

func TestOnlyTheSevenCanonicalVariationsParse(t *testing.T) {
	for _, v := range Variations {
		got, ok := ParseVariation(string(v))
		if !ok || got != v {
			t.Errorf("ParseVariation(%q) = %q, %v; want it accepted", v, got, ok)
		}
	}
	if len(Variations) != 7 {
		t.Fatalf("the menu has %d variations, want 7", len(Variations))
	}
	// 5-Card Teen Patti was ADDED to the end: the six before it keep their
	// places, so an older client's menu is a prefix of this one.
	want := []Variation{"MUFLIS", "AK47", "JOKER", "HUKAM", "LOWEST_JOKER", "HIGHEST_JOKER", "FIVE_CARD"}
	for i, v := range want {
		if Variations[i] != v {
			t.Fatalf("menu[%d] = %s, want %s", i, Variations[i], v)
		}
	}
	// One canonical spelling. Everything else is refused rather than understood.
	for _, raw := range []string{
		"", " ", "muflis", "Muflis", "MUFLIS ", " MUFLIS", "ak47", "Ak47",
		"LOWEST JOKER", "Lowest Joker", "Lowest Joke", "LowestJoker", "lowest_joker",
		"HIGHESTJOKER", "JOKERS", "CLASSIC", "null", "undefined", "0", "MUFLIS\x00",
		"5-Card Teen Patti", "5_CARD", "FIVECARD", "five_card", "FIVE CARD", "FIVE_CARDS",
	} {
		if got, ok := ParseVariation(raw); ok {
			t.Errorf("ParseVariation(%q) accepted it as %q", raw, got)
		}
	}
}

func TestTheServersOwnChoiceIsMuflis(t *testing.T) {
	if VariationDefault != VariationMuflis {
		t.Fatalf("VariationDefault = %q, want MUFLIS", VariationDefault)
	}
}

func TestTheZeroRulesAreClassicTeenPatti(t *testing.T) {
	// A seen or blind table holds the zero value, so it must change nothing.
	var classic VariationRules
	for _, codes := range [][]string{
		{"As", "Ks", "Qs"}, {"Ah", "Kd", "4c"}, {"7s", "7h", "7d"}, {"2s", "3h", "5d"}, {"4s", "4h", "9d"},
	} {
		cards := cardsOf(codes...)
		got, want := classic.EvaluateHand(cards), Evaluate(cards, EvaluateOptions{})
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%v: zero rules gave %+v, classic gives %+v", codes, got, want)
		}
		if got.Wild != nil {
			t.Errorf("%v: a classic hand named wild cards %v", codes, got.Wild)
		}
	}
	trail, high := cardsOf("7s", "7h", "7d"), cardsOf("2s", "3h", "5d")
	if !wins(classic, trail, high) {
		t.Error("under the zero rules a trail must beat a high card")
	}
}

// ------------------------------------------------------------------ Muflis

func TestMuflisReversesTheClassicRanking(t *testing.T) {
	muflis := RulesFor(VariationMuflis, Card{})
	var classic VariationRules

	// One hand of every category, strongest classic first.
	ladder := [][]Card{
		cardsOf("As", "Ah", "Ad"), // trail
		cardsOf("As", "Ks", "Qs"), // pure sequence
		cardsOf("9s", "8h", "7d"), // sequence
		cardsOf("Ks", "9s", "4s"), // color
		cardsOf("Js", "Jh", "5d"), // pair
		cardsOf("Qs", "8h", "3d"), // high card
		cardsOf("5s", "3h", "2d"), // the weakest hand there is
	}
	for i := 0; i < len(ladder); i++ {
		for j := i + 1; j < len(ladder); j++ {
			stronger, weaker := ladder[i], ladder[j]
			if !wins(classic, stronger, weaker) {
				t.Fatalf("test ladder out of order at %d,%d", i, j)
			}
			if !wins(muflis, weaker, stronger) {
				t.Errorf("Muflis: %v should beat %v", CardCodes(weaker), CardCodes(stronger))
			}
			if wins(muflis, stronger, weaker) {
				t.Errorf("Muflis: %v must not beat %v", CardCodes(stronger), CardCodes(weaker))
			}
		}
	}
}

func TestMuflisKeepsTheClassicScoreAndNamesNothingWild(t *testing.T) {
	cards := cardsOf("Ks", "9s", "4s")
	got := RulesFor(VariationMuflis, Card{}).EvaluateHand(cards)
	want := Evaluate(cards, EvaluateOptions{})
	if !reflect.DeepEqual(got, want) {
		t.Errorf("Muflis evaluation = %+v, want the classic %+v", got, want)
	}
}

func TestAnExactTieIsATieInMuflisToo(t *testing.T) {
	muflis := RulesFor(VariationMuflis, Card{})
	a, b := muflis.EvaluateHand(cardsOf("Qs", "8h", "3d")), muflis.EvaluateHand(cardsOf("Qh", "8d", "3c"))
	if muflis.CompareHands(a, b) != 0 {
		t.Error("suits never break a tie, in either direction")
	}
}

// -------------------------------------------------------------------- AK47

func TestAK47MakesAcesKingsFoursAndSevensWild(t *testing.T) {
	rules := RulesFor(VariationAK47, Card{})
	tests := []struct {
		name  string
		cards []string
		want  []int
		wild  []string
	}{
		{"no wild card is a classic hand", []string{"Qs", "8h", "3d"}, []int{int(HighCard), 12, 8, 3}, nil},
		{"one wild completes a pair into a trail", []string{"4h", "9c", "9d"}, []int{int(Trail), 9}, []string{"4h"}},
		// 5-6 suited: the wild is the seven of spades, the top of the best run
		// that still holds both natural cards.
		{"one wild completes a suited run", []string{"7c", "5s", "6s"}, []int{int(PureSequence), 2 * 7}, []string{"7c"}},
		// 9-8 off suit: the wild makes T-9-8 (20), not 9-8-7 (18).
		{"one wild takes the HIGHER run", []string{"Ah", "9s", "8h"}, []int{int(Sequence), 2 * 10}, []string{"Ah"}},
		{"one wild makes a color with the ace of the suit", []string{"Kd", "9s", "2s"}, []int{int(Color), 14, 9, 2}, []string{"Kd"}},
		{"one wild beside two unrelated cards pairs the higher", []string{"4s", "Qh", "2d"}, []int{int(Pair), 12, 2}, []string{"4s"}},
		{"two wilds make a trail of the natural card", []string{"As", "Kd", "9c"}, []int{int(Trail), 9}, []string{"As", "Kd"}},
		{"three wilds make a trail of aces", []string{"As", "4d", "7c"}, []int{int(Trail), 14}, []string{"As", "4d", "7c"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cards := cardsOf(tt.cards...)
			got := rules.EvaluateHand(cards)
			if !reflect.DeepEqual(got.Score, tt.want) {
				t.Errorf("score = %v (%s), want %v", got.Score, got.Name, tt.want)
			}
			if !reflect.DeepEqual(got.Wild, tt.wild) {
				t.Errorf("wild = %v, want %v", got.Wild, tt.wild)
			}
			// A reveal shows the cards the player really holds.
			if !reflect.DeepEqual(got.Cards, tt.cards) {
				t.Errorf("cards = %v, want the real hand %v", got.Cards, tt.cards)
			}
			if got.Name != CategoryNames[got.Category] {
				t.Errorf("name %q does not match category %v", got.Name, got.Category)
			}
		})
	}
}

func TestAK47CanTurnAClassicLoserIntoTheWinner(t *testing.T) {
	ak47 := RulesFor(VariationAK47, Card{})
	var classic VariationRules
	flush, scraps := cardsOf("Qs", "9s", "2s"), cardsOf("4h", "7d", "2c")
	if !wins(classic, flush, scraps) {
		t.Fatal("classically the color beats 7-4-2")
	}
	if !wins(ak47, scraps, flush) {
		t.Error("under AK47, 4-7-2 is a trail of twos and beats the color")
	}
}

// ------------------------------------------------------------ Joker, Hukam

func TestJokerMakesEveryCardOfTheTurnedUpRankWild(t *testing.T) {
	rules := RulesFor(VariationJoker, ParseCard("9d"))
	if rules.WildRank != 9 || rules.WildSuit != 0 {
		t.Fatalf("rules = %+v, want wild rank 9 and no wild suit", rules)
	}
	got := rules.EvaluateHand(cardsOf("9s", "9h", "2c"))
	if want := []int{int(Trail), 2}; !reflect.DeepEqual(got.Score, want) {
		t.Errorf("two jokers and a deuce = %v, want a trail of twos %v", got.Score, want)
	}
	if want := []string{"9s", "9h"}; !reflect.DeepEqual(got.Wild, want) {
		t.Errorf("wild = %v, want %v", got.Wild, want)
	}
	// The suit of the turned-up card means nothing in Joker.
	plain := rules.EvaluateHand(cardsOf("Kd", "8d", "3d"))
	if plain.Wild != nil || plain.Category != Color {
		t.Errorf("a hand with no nine must be classic, got %+v", plain)
	}
}

func TestHukamMakesEveryCardOfTheTurnedUpSuitWild(t *testing.T) {
	rules := RulesFor(VariationHukam, ParseCard("9h"))
	if rules.WildSuit != 'h' || rules.WildRank != 0 {
		t.Fatalf("rules = %+v, want wild suit hearts and no wild rank", rules)
	}
	got := rules.EvaluateHand(cardsOf("Ah", "5s", "6s"))
	if want := []int{int(PureSequence), 2 * 7}; !reflect.DeepEqual(got.Score, want) {
		t.Errorf("a heart beside 5-6 of spades = %v, want the 7-6-5 pure sequence %v", got.Score, want)
	}
	if want := []string{"Ah"}; !reflect.DeepEqual(got.Wild, want) {
		t.Errorf("wild = %v, want %v", got.Wild, want)
	}
	// The rank of the turned-up card means nothing in Hukam.
	plain := rules.EvaluateHand(cardsOf("9s", "9d", "2c"))
	if plain.Wild != nil || plain.Category != Pair {
		t.Errorf("a hand with no heart must be classic, got %+v", plain)
	}
	// Three hearts are three wild cards.
	if all := rules.EvaluateHand(cardsOf("2h", "7h", "Jh")); !reflect.DeepEqual(all.Score, []int{int(Trail), 14}) {
		t.Errorf("three hukam cards = %v, want a trail of aces", all.Score)
	}
}

func TestWithNoCardTurnedUpJokerAndHukamAreClassic(t *testing.T) {
	// Defensive: rules built with no card make nothing wild rather than
	// everything (rank 0 and suit 0 match no card).
	for _, v := range []Variation{VariationJoker, VariationHukam} {
		got := RulesFor(v, Card{}).EvaluateHand(cardsOf("9s", "9h", "2c"))
		if got.Wild != nil || got.Category != Pair {
			t.Errorf("%s with no turned-up card = %+v, want the classic pair", v, got)
		}
	}
}

// ------------------------------------------------ Lowest and Highest Joker

func TestLowestJokerMakesTheLowestCardWild(t *testing.T) {
	rules := RulesFor(VariationLowestJoker, Card{})
	tests := []struct {
		name  string
		cards []string
		want  []int
		wild  []string
	}{
		// The brief's own example: 3 8 K → the 3 is the joker → a pair of kings.
		{"the brief's example", []string{"3s", "8h", "Kd"}, []int{int(Pair), 13, 8}, []string{"3s"}},
		{"both cards of the lowest rank are wild", []string{"3s", "3h", "Kd"}, []int{int(Trail), 13}, []string{"3s", "3h"}},
		{"a trail is three wild cards", []string{"5s", "5h", "5d"}, []int{int(Trail), 14}, []string{"5s", "5h", "5d"}},
		{"the ace is high, so it is not the lowest", []string{"As", "2h", "9d"}, []int{int(Pair), 14, 9}, []string{"2h"}},
		{"a high pair keeps its kicker wild", []string{"Ks", "Kh", "2d"}, []int{int(Trail), 13}, []string{"2d"}},
		{"same suit: the wild finishes the run", []string{"2s", "9s", "Ts"}, []int{int(PureSequence), 2 * 11}, []string{"2s"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := rules.EvaluateHand(cardsOf(tt.cards...))
			if !reflect.DeepEqual(got.Score, tt.want) {
				t.Errorf("score = %v (%s), want %v", got.Score, got.Name, tt.want)
			}
			if !reflect.DeepEqual(got.Wild, tt.wild) {
				t.Errorf("wild = %v, want %v", got.Wild, tt.wild)
			}
		})
	}
}

func TestHighestJokerMakesTheHighestCardWild(t *testing.T) {
	rules := RulesFor(VariationHighestJoker, Card{})
	tests := []struct {
		name  string
		cards []string
		want  []int
		wild  []string
	}{
		// The brief's own example: 3 8 K → the K is the joker → a pair of eights.
		{"the brief's example", []string{"3s", "8h", "Kd"}, []int{int(Pair), 8, 3}, []string{"Kd"}},
		{"both cards of the highest rank are wild", []string{"Ks", "Kh", "3d"}, []int{int(Trail), 3}, []string{"Ks", "Kh"}},
		{"a trail is three wild cards", []string{"5s", "5h", "5d"}, []int{int(Trail), 14}, []string{"5s", "5h", "5d"}},
		{"the ace is the highest card there is", []string{"As", "2h", "3d"}, []int{int(Sequence), 2*14 - 1}, []string{"As"}},
		{"a low pair under a high card becomes a trail", []string{"Qs", "4h", "4d"}, []int{int(Trail), 4}, []string{"Qs"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := rules.EvaluateHand(cardsOf(tt.cards...))
			if !reflect.DeepEqual(got.Score, tt.want) {
				t.Errorf("score = %v (%s), want %v", got.Score, got.Name, tt.want)
			}
			if !reflect.DeepEqual(got.Wild, tt.wild) {
				t.Errorf("wild = %v, want %v", got.Wild, tt.wild)
			}
		})
	}
}

func TestTheSameHandIsWorthDifferentThingsUnderEachVariation(t *testing.T) {
	cards := cardsOf("3s", "8h", "Kd")
	want := map[Variation][]int{
		VariationMuflis:       {int(HighCard), 13, 8, 3},
		VariationAK47:         {int(Pair), 8, 3},  // the king is wild
		VariationLowestJoker:  {int(Pair), 13, 8}, // the three is wild
		VariationHighestJoker: {int(Pair), 8, 3},  // the king is wild
	}
	for v, score := range want {
		if got := RulesFor(v, Card{}).EvaluateHand(cards).Score; !reflect.DeepEqual(got, score) {
			t.Errorf("%s: score = %v, want %v", v, got, score)
		}
	}
	if got := RulesFor(VariationJoker, ParseCard("8c")).EvaluateHand(cards).Score; !reflect.DeepEqual(got, []int{int(Pair), 13, 3}) {
		t.Errorf("JOKER on eights: score = %v, want a pair of kings", got)
	}
	if got := RulesFor(VariationHukam, ParseCard("2s")).EvaluateHand(cards).Score; !reflect.DeepEqual(got, []int{int(Pair), 13, 8}) {
		t.Errorf("HUKAM on spades: score = %v, want a pair of kings", got)
	}
}

// ------------------------------------------------------ the search itself

func TestThreeWildCardsAreWorthWhatTheSearchWouldFind(t *testing.T) {
	// evaluateWithWilds answers the all-wild hand from a constant instead of
	// searching C(52,3) hands. This is the search it skips.
	deck := NewDeck()
	var best EvaluatedHand
	found := false
	for i := 0; i < len(deck); i++ {
		for j := i + 1; j < len(deck); j++ {
			for k := j + 1; k < len(deck); k++ {
				scored := Evaluate([]Card{deck[i], deck[j], deck[k]}, EvaluateOptions{})
				if !found || Compare(scored, best) > 0 {
					best, found = scored, true
				}
			}
		}
	}
	got := evaluateWithWilds(cardsOf("As", "Kd", "4c"), [3]bool{true, true, true})
	if !reflect.DeepEqual(got.Score, best.Score) {
		t.Errorf("three wilds score %v, the exhaustive search finds %v", got.Score, best.Score)
	}
}

func TestAWildNeverStandsForACardTheHandAlreadyHolds(t *testing.T) {
	// Holding the ace and king of spades with a wild: the best color would need
	// a SECOND ace of spades, which does not exist. The wild makes the queen
	// instead, and the hand is the top pure sequence.
	got := evaluateWithWilds(cardsOf("As", "Ks", "2d"), [3]bool{false, false, true})
	if want := []int{int(PureSequence), 2 * 14}; !reflect.DeepEqual(got.Score, want) {
		t.Errorf("score = %v, want A-K-Q suited %v", got.Score, want)
	}
	// One natural ace and two wilds is a trail of aces — the two wilds are the
	// OTHER aces, never a copy of the one held.
	trail := evaluateWithWilds(cardsOf("Ah", "2s", "3d"), [3]bool{false, true, true})
	if want := []int{int(Trail), 14}; !reflect.DeepEqual(trail.Score, want) {
		t.Errorf("score = %v, want a trail of aces %v", trail.Score, want)
	}
}

func TestAWildHandIsNeverWorseThanTheSameCardsPlayedStraight(t *testing.T) {
	// A wild may stand for itself, so making a card wild can only help.
	deck := NewDeck()
	for i := 0; i < len(deck); i += 5 {
		for j := i + 1; j < len(deck); j += 7 {
			for k := j + 1; k < len(deck); k += 3 {
				cards := []Card{deck[i], deck[j], deck[k]}
				classic := Evaluate(cards, EvaluateOptions{})
				for wildAt := 0; wildAt < 3; wildAt++ {
					var mask [3]bool
					mask[wildAt] = true
					if got := evaluateWithWilds(cards, mask); Compare(got, classic) < 0 {
						t.Fatalf("%v with card %d wild scored %v, below its classic %v", CardCodes(cards), wildAt, got.Score, classic.Score)
					}
				}
			}
		}
	}
}

func TestEvaluationIsDeterministic(t *testing.T) {
	cards := cardsOf("4h", "Qs", "2d")
	first := EvaluateAK47(cards)
	for i := 0; i < 20; i++ {
		if got := EvaluateAK47(cards); !reflect.DeepEqual(got, first) {
			t.Fatalf("run %d gave %+v, first gave %+v", i, got, first)
		}
	}
}

// ----------------------------------------------------- 5-Card Teen Patti
//
// Owner, 18 Sep 2026: every player holds five cards and plays the best three of
// them, which the SERVER finds — "bestHand = max(all 10 threeCardCombinations)"
// by the existing ranking, never a second one.

func TestFiveCardIsTheOnlyVariationThatHoldsFiveCards(t *testing.T) {
	for _, v := range Variations {
		want := 3
		if v == VariationFiveCard {
			want = 5
		}
		if got := v.CardsPerPlayer(); got != want {
			t.Errorf("%s holds %d cards, want %d", v, got, want)
		}
	}
	if Variation("").CardsPerPlayer() != 3 || Variation("NOPE").CardsPerPlayer() != 3 {
		t.Error("a hand with no variation holds three")
	}
	if VariationFiveCard.UsesTurnUp() {
		t.Error("5-Card is not decided by the turned-up card")
	}
}

func TestFiveCardsMakeExactlyTenUniqueThreeCardCombinations(t *testing.T) {
	hand := cardsOf("As", "Ks", "Qs", "7d", "7c")
	combos := ThreeCardCombinations(hand)
	if len(combos) != 10 {
		t.Fatalf("%d combinations, want C(5,3) = 10", len(combos))
	}
	seen := map[string]bool{}
	for _, c := range combos {
		if len(c) != 3 {
			t.Fatalf("a combination of %d cards", len(c))
		}
		if c[0] == c[1] || c[1] == c[2] || c[0] == c[2] {
			t.Fatalf("a combination repeats a card: %v", CardCodes(c))
		}
		codes := CardCodes(c)
		sort.Strings(codes)
		key := strings.Join(codes, " ")
		if seen[key] {
			t.Fatalf("combination %s twice", key)
		}
		seen[key] = true
	}
	if n := len(ThreeCardCombinations(cardsOf("As", "Ks", "Qs"))); n != 1 {
		t.Fatalf("three cards make %d combinations, want 1", n)
	}
}

func TestFiveCardPlaysTheBestThreeOfTheFive(t *testing.T) {
	for _, tc := range []struct {
		why   string
		cards []string
		name  string
		best  []string
	}{
		// The brief's own examples.
		{"a pure sequence beats the pair beside it", []string{"As", "Ks", "Qs", "7d", "7c"}, "Pure Sequence", []string{"As", "Ks", "Qs"}},
		{"a trail", []string{"7s", "7h", "7d", "Kc", "2s"}, "Trail", []string{"7s", "7h", "7d"}},
		{"a pair, with the best kicker there is", []string{"As", "Ah", "Kd", "8c", "3s"}, "Pair", []string{"As", "Ah", "Kd"}},
		{"a sequence — and the highest of the two on offer (A-K-Q, not K-Q-J)", []string{"As", "Kh", "Qd", "Jc", "3s"}, "Sequence", []string{"As", "Kh", "Qd"}},
		// The strongest three are NOT the first three dealt.
		{"the trail is the last three", []string{"2c", "9d", "5h", "5s", "5d"}, "Trail", []string{"5h", "5s", "5d"}},
		{"the pure sequence is cards 1, 3 and 5", []string{"9h", "2c", "8h", "Kd", "7h"}, "Pure Sequence", []string{"9h", "8h", "7h"}},
		{"the colour skips the second and fourth", []string{"Ad", "2s", "9d", "Kc", "4d"}, "Color", []string{"Ad", "9d", "4d"}},
		// Two possible pairs: the higher pair, then the highest kicker left.
		{"two pairs on offer", []string{"9s", "9h", "Kd", "Kc", "3s"}, "Pair", []string{"9s", "Kd", "Kc"}},
		// Several colours: five of one suit, the three highest of them.
		{"five of a suit", []string{"2h", "Jh", "5h", "Kh", "8h"}, "Color", []string{"Jh", "Kh", "8h"}},
		// A sequence and a colour both possible: sequence ranks higher.
		{"sequence over colour", []string{"4s", "5d", "6s", "Js", "2c"}, "Sequence", []string{"4s", "5d", "6s"}},
		// Nothing at all: the three highest cards.
		{"high card", []string{"2c", "9d", "5h", "Ks", "7d"}, "High Card", []string{"9d", "Ks", "7d"}},
		// A-2-3 is a run (second only to A-K-Q), found among five.
		{"ace low run", []string{"Ah", "9c", "2d", "Kc", "3s"}, "Sequence", []string{"Ah", "2d", "3s"}},
	} {
		hand := EvaluateBest(cardsOf(tc.cards...))
		if hand.Name != tc.name {
			t.Errorf("%s: %v is a %s, want %s", tc.why, tc.cards, hand.Name, tc.name)
		}
		if strings.Join(hand.Best, " ") != strings.Join(tc.best, " ") {
			t.Errorf("%s: best three %v, want %v", tc.why, hand.Best, tc.best)
		}
		// The player's real hand is kept whole, in the order it was held.
		if strings.Join(hand.Cards, " ") != strings.Join(tc.cards, " ") {
			t.Errorf("%s: cards %v, want all five as dealt", tc.why, hand.Cards)
		}
		if len(hand.Wild) != 0 || len(hand.PlaysAs) != 0 {
			t.Errorf("%s: 5-Card has no wild card, got wild %v", tc.why, hand.Wild)
		}
		// Through the rules, as the table calls it.
		if via := RulesFor(VariationFiveCard, Card{}).EvaluateHand(cardsOf(tc.cards...)); via.Name != tc.name {
			t.Errorf("%s: through VariationRules it is a %s", tc.why, via.Name)
		}
	}
}

// The heart of it: the best of five is EXACTLY the best of its ten three-card
// hands by the one classic ranking — checked against that definition, written
// out the long way, on thousands of random hands.
func TestEvaluateBestIsTheMaximumOfTheTenClassicHands(t *testing.T) {
	deck := NewDeck()
	rng := rand.New(rand.NewSource(20260918))
	for n := 0; n < 5000; n++ {
		rng.Shuffle(len(deck), func(i, j int) { deck[i], deck[j] = deck[j], deck[i] })
		hand := append([]Card(nil), deck[:5]...)
		got := EvaluateBest(hand)

		var want EvaluatedHand
		for i, combo := range ThreeCardCombinations(hand) {
			scored := Evaluate(combo, EvaluateOptions{})
			if i == 0 || Compare(scored, want) > 0 {
				want = scored
			}
		}
		if Compare(got, want) != 0 || got.Name != want.Name {
			t.Fatalf("%v: EvaluateBest says %s %v, the ten hands' best is %s %v", CardCodes(hand), got.Name, got.Score, want.Name, want.Score)
		}
		// The three it names really are three of the five, and really are that hand.
		if len(got.Best) != 3 {
			t.Fatalf("%v: best = %v", CardCodes(hand), got.Best)
		}
		held := map[string]bool{}
		for _, c := range hand {
			held[c.Code()] = true
		}
		for _, code := range got.Best {
			if !held[code] {
				t.Fatalf("%v: best names %s, which is not in the hand", CardCodes(hand), code)
			}
		}
		if again := Evaluate(ParseCards(got.Best), EvaluateOptions{}); Compare(again, got) != 0 {
			t.Fatalf("%v: the named three %v score %v, the hand %v", CardCodes(hand), got.Best, again.Score, got.Score)
		}
		// Order of the five does not change what they are worth.
		rng.Shuffle(len(hand), func(i, j int) { hand[i], hand[j] = hand[j], hand[i] })
		if Compare(EvaluateBest(hand), got) != 0 {
			t.Fatalf("%v: a different order of the same five scored differently", CardCodes(hand))
		}
	}
}

func TestFiveCardWinnersAreComparedOnTheirBestThree(t *testing.T) {
	rules := RulesFor(VariationFiveCard, Card{})
	// B's first three cards are rubbish and A's are a pair — but B holds a
	// trail further along, and that is the hand B plays.
	a := cardsOf("Qs", "Qh", "4d", "9c", "2s")
	b := cardsOf("2c", "9d", "5h", "5s", "5d")
	if !wins(rules, b, a) {
		t.Fatal("a trail found among five should beat a pair")
	}
	// Equal-strength best hands are an exact tie, whatever else is held: the
	// two cards that are not played break nothing.
	c := cardsOf("As", "Kd", "9h", "4c", "6d")
	d := cardsOf("Ah", "Kc", "9s", "5d", "2c")
	if got := rules.CompareHands(rules.EvaluateHand(c), rules.EvaluateHand(d)); got != 0 {
		t.Fatalf("A-K-9 against A-K-9 should tie, got %d", got)
	}
	// It is classic Teen Patti, not Muflis: the higher hand wins.
	if wins(rules, cardsOf("2c", "3d", "5h", "7s", "8d"), cardsOf("Ac", "Ad", "5s", "7h", "8c")) {
		t.Fatal("a high-card hand beat a pair of aces under 5-Card")
	}
}

func TestAThreeCardHandIsEvaluatedAsItAlwaysWas(t *testing.T) {
	for _, codes := range [][]string{{"As", "Ks", "Qs"}, {"7s", "7h", "2d"}, {"2c", "9d", "5h"}} {
		classic := Evaluate(cardsOf(codes...), EvaluateOptions{})
		best := EvaluateBest(cardsOf(codes...))
		if Compare(classic, best) != 0 || best.Name != classic.Name || best.Best != nil {
			t.Errorf("%v: EvaluateBest %+v differs from Evaluate %+v", codes, best, classic)
		}
	}
}
