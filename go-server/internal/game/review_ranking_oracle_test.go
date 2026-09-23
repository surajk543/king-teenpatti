package game

import (
	"math/rand"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

// An INDEPENDENT oracle for the hand ranking (24 Sep 2026), written after the
// owner reported "in Variation a player with a PAIR is showing Trail and he is
// winning". Nothing in this file's oracle calls Evaluate, Compare or any of the
// variation evaluators: the classic ranking is written again from CLAUDE.md
// §6.3 (HIGH_CARD < PAIR < COLOR < SEQUENCE < PURE_SEQUENCE < TRAIL; runs
// A-K-Q > A-2-3 > K-Q-J > … > 4-3-2; suits never break ties; kickers by rank)
// and every wild rule from the text of §6.4, and each wild hand is scored by
// brute force over every substitution of its wilds. The engine is then held to
// the oracle over every one of the 22,100 three-card hands, or a large sample
// where a rule has a turned-up card.
//
// Run with: go test -race -count=1 ./internal/game -run Oracle

// ------------------------------------------------------------- the oracle

// oracleHand is what the oracle says a three-card hand is worth. key is a
// total order: a bigger key is a stronger hand, an equal key an exact tie.
type oracleHand struct {
	cat  int
	name string
	key  int64
}

// The wire names, from §6.3, index = category.
var oracleNames = [6]string{"High Card", "Pair", "Color", "Sequence", "Pure Sequence", "Trail"}

// oracleRunLadder is the run order of §6.3, strongest first, each run written
// with its ranks in descending order (so A-2-3 is "A32").
var oracleRunLadder = []string{"AKQ", "A32", "KQJ", "QJT", "JT9", "T98", "987", "876", "765", "654", "543", "432"}

func oracleRankChar(rank int) byte { return "..23456789TJQKA"[rank] }

// oracleEvaluate classifies and keys a three-card hand from the rule text.
func oracleEvaluate(cards []Card) oracleHand {
	if len(cards) != 3 {
		panic("oracle: three cards")
	}
	r := []int{cards[0].Rank, cards[1].Rank, cards[2].Rank}
	sort.Sort(sort.Reverse(sort.IntSlice(r)))
	h, m, l := r[0], r[1], r[2]
	for _, x := range r {
		if x < 2 || x > 14 {
			panic("oracle: rank out of range")
		}
	}
	flush := cards[0].Suit == cards[1].Suit && cards[1].Suit == cards[2].Suit
	runIdx := -1
	written := string([]byte{oracleRankChar(h), oracleRankChar(m), oracleRankChar(l)})
	for i, run := range oracleRunLadder {
		if run == written {
			runIdx = i
		}
	}
	var cat int
	var tie int64
	switch {
	case h == m && m == l:
		cat, tie = 5, int64(h)
	case runIdx >= 0:
		cat = 3
		if flush {
			cat = 4
		}
		tie = int64(len(oracleRunLadder) - runIdx) // strongest run = biggest
	case flush:
		cat, tie = 2, int64(h*225+m*15+l)
	case h == m:
		cat, tie = 1, int64(h*15+l) // pair of h, kicker l
	case m == l:
		cat, tie = 1, int64(m*15+h) // pair of m, kicker h
	default:
		cat, tie = 0, int64(h*225+m*15+l)
	}
	return oracleHand{cat: cat, name: oracleNames[cat], key: int64(cat)*1_000_000 + tie}
}

func sign(x int) int {
	switch {
	case x > 0:
		return 1
	case x < 0:
		return -1
	}
	return 0
}

func sign64(x int64) int {
	switch {
	case x > 0:
		return 1
	case x < 0:
		return -1
	}
	return 0
}

// allThreeCardHands is every one of the C(52,3) = 22,100 hands, in deck order.
func allThreeCardHands() [][]Card {
	deck := NewDeck()
	out := make([][]Card, 0, 22100)
	for i := 0; i < len(deck); i++ {
		for j := i + 1; j < len(deck); j++ {
			for k := j + 1; k < len(deck); k++ {
				out = append(out, []Card{deck[i], deck[j], deck[k]})
			}
		}
	}
	return out
}

func codesOf(cards []Card) string { return strings.Join(CardCodes(cards), " ") }

// oracleBestWithWilds brute-forces the strongest classic hand the masked
// (wild) cards can complete: each wild may stand for any card of the deck that
// is not a natural card of this hand, no two wilds for the same card (§6.4).
// It returns the oracle's answer and the stand-in cards that reach it.
func oracleBestWithWilds(hand []Card, wild [3]bool) (best oracleHand, standIns []Card) {
	var naturals []Card
	wilds := 0
	for i, c := range hand {
		if wild[i] {
			wilds++
		} else {
			naturals = append(naturals, c)
		}
	}
	if wilds == 0 {
		return oracleEvaluate(hand), nil
	}
	held := map[Card]bool{}
	for _, c := range naturals {
		held[c] = true
	}
	var pool []Card
	for _, c := range NewDeck() {
		if !held[c] {
			pool = append(pool, c)
		}
	}
	found := false
	consider := func(cands []Card) {
		trial := append(append([]Card{}, naturals...), cands...)
		o := oracleEvaluate(trial)
		if !found || o.key > best.key {
			best, standIns, found = o, append([]Card{}, cands...), true
		}
	}
	switch wilds {
	case 1:
		for _, a := range pool {
			consider([]Card{a})
		}
	case 2:
		for i := 0; i < len(pool); i++ {
			for j := i + 1; j < len(pool); j++ {
				consider([]Card{pool[i], pool[j]})
			}
		}
	case 3:
		// No natural card: the pool is the whole deck and the answer is the
		// same for every such hand, so it is brute-forced once (oracleAllWild).
		return oracleAllWild()
	}
	return best, standIns
}

var oracleAllWildOnce struct {
	sync.Once
	best     oracleHand
	standIns []Card
}

// oracleAllWild is the strongest hand three wild cards can make, found by
// scoring every one of the 22,100 hands of the deck, once.
func oracleAllWild() (oracleHand, []Card) {
	m := &oracleAllWildOnce
	m.Do(func() {
		found := false
		for _, hand := range allThreeCardHands() {
			o := oracleEvaluate(hand)
			if !found || o.key > m.best.key {
				m.best, m.standIns, found = o, append([]Card{}, hand...), true
			}
		}
	})
	return m.best, m.standIns
}

// ---------------------------------------------- (1) the classic ranking

func TestOracleClassicRankingAgreesOnEveryHand(t *testing.T) {
	hands := allThreeCardHands()
	eq(t, len(hands), 22100, "C(52,3) hands")

	type scored struct {
		cards  []Card
		engine EvaluatedHand
		oracle oracleHand
	}
	all := make([]scored, len(hands))
	for i, hand := range hands {
		e := Evaluate(hand, EvaluateOptions{})
		o := oracleEvaluate(hand)
		all[i] = scored{hand, e, o}
		if int(e.Category) != o.cat || e.Name != o.name {
			t.Errorf("%s: engine says %s (%d), oracle says %s (%d)", codesOf(hand), e.Name, e.Category, o.name, o.cat)
		}
		if e.Wild != nil || e.PlaysAs != nil || e.Best != nil {
			t.Errorf("%s: a classic evaluation names wild/playsAs/best: %+v", codesOf(hand), e)
		}
		if codesOf(ParseCards(e.Cards)) != codesOf(hand) {
			t.Errorf("%s: Cards came back as %v", codesOf(hand), e.Cards)
		}
		// The order the cards are held in must not matter.
		rev := []Card{hand[2], hand[0], hand[1]}
		if r := Evaluate(rev, EvaluateOptions{}); !reflect.DeepEqual(r.Score, e.Score) {
			t.Errorf("%s: reordered as %s scores %v, not %v", codesOf(hand), codesOf(rev), r.Score, e.Score)
		}
	}
	if t.Failed() {
		t.Fatalf("category/name disagreement — not checking the order")
	}

	// The total order: sort by the oracle's key and check every adjacent pair
	// with the engine. Compare is a lexicographic order on Score and so
	// transitive, which makes the adjacent checks a proof for every pair.
	sort.SliceStable(all, func(i, j int) bool { return all[i].oracle.key < all[j].oracle.key })
	for i := 1; i < len(all); i++ {
		a, b := all[i], all[i-1]
		want := sign64(a.oracle.key - b.oracle.key)
		if got := sign(Compare(a.engine, b.engine)); got != want {
			t.Errorf("order: %s (%s) vs %s (%s): engine %d, oracle %d", codesOf(a.cards), a.engine.Name, codesOf(b.cards), b.engine.Name, got, want)
		}
	}
	// Belt and braces: a large random sample of arbitrary pairs …
	rng := rand.New(rand.NewSource(20260924))
	for n := 0; n < 300_000; n++ {
		a, b := all[rng.Intn(len(all))], all[rng.Intn(len(all))]
		if got, want := sign(Compare(a.engine, b.engine)), sign64(a.oracle.key-b.oracle.key); got != want {
			t.Fatalf("pair %s vs %s: engine %d, oracle %d", codesOf(a.cards), codesOf(b.cards), got, want)
		}
	}
	// … and every pair within a category, for a sample of each category.
	byCat := map[int][]scored{}
	for _, s := range all {
		byCat[s.oracle.cat] = append(byCat[s.oracle.cat], s)
	}
	for cat := 0; cat <= 5; cat++ {
		group := byCat[cat]
		rng.Shuffle(len(group), func(i, j int) { group[i], group[j] = group[j], group[i] })
		if len(group) > 160 {
			group = group[:160]
		}
		for i := range group {
			for j := range group {
				a, b := group[i], group[j]
				if got, want := sign(Compare(a.engine, b.engine)), sign64(a.oracle.key-b.oracle.key); got != want {
					t.Fatalf("%s: %s vs %s: engine %d, oracle %d", oracleNames[cat], codesOf(a.cards), codesOf(b.cards), got, want)
				}
			}
		}
	}
	// The counts the arithmetic predicts: 52 trails, 48 pure sequences, 720
	// sequences, 1,096 colors, 3,744 pairs, 16,440 high cards.
	counts := map[int]int{}
	for _, s := range all {
		counts[s.oracle.cat]++
	}
	for cat, want := range map[int]int{5: 52, 4: 48, 3: 720, 2: 1096, 1: 3744, 0: 16440} {
		eq(t, counts[cat], want, oracleNames[cat]+" count")
	}
	// The §6.3 spot checks.
	beats := func(a, b []string) {
		t.Helper()
		if Compare(Evaluate(cardsOf(a...), EvaluateOptions{}), Evaluate(cardsOf(b...), EvaluateOptions{})) <= 0 {
			t.Errorf("%v must beat %v", a, b)
		}
	}
	beats([]string{"As", "Kh", "Qd"}, []string{"Ah", "2s", "3d"})
	beats([]string{"Ah", "2s", "3d"}, []string{"Ks", "Qh", "Jd"})
	beats([]string{"4s", "3h", "2d"}, []string{"As", "Kh", "Jd"}) // the weakest run beats any high card
	beats([]string{"2s", "2h", "3d"}, []string{"As", "Kh", "Jd"}) // any pair beats any high card
	beats([]string{"As", "Ah", "2d"}, []string{"Ks", "Kh", "Qd"})
	beats([]string{"Ks", "Kh", "Ad"}, []string{"Ks", "Kd", "Qd"})
	beats([]string{"2s", "3s", "5s"}, []string{"As", "Ah", "Kd"}) // any color beats any pair
	beats([]string{"4s", "3h", "2d"}, []string{"As", "Ks", "Js"}) // any sequence beats any color
	beats([]string{"4s", "3s", "2s"}, []string{"As", "Kh", "Qd"}) // any pure sequence beats any sequence
	beats([]string{"2s", "2h", "2d"}, []string{"As", "Ks", "Qs"}) // any trail beats any pure sequence
	if Compare(Evaluate(cardsOf("As", "Kh", "Qd"), EvaluateOptions{}), Evaluate(cardsOf("Ac", "Kd", "Qh"), EvaluateOptions{})) != 0 {
		t.Error("suits must not break a tie")
	}
}

// ------------------------------------------------- (2) the wild variations

// wildRuleSet is one wild variation as the RULE TEXT states it, beside the
// engine's rules for it.
type wildRuleSet struct {
	name   string
	rules  VariationRules
	isWild func(hand []Card, c Card) bool
}

func oracleWildRules() []wildRuleSet {
	var sets []wildRuleSet
	sets = append(sets, wildRuleSet{
		name:  "AK47",
		rules: VariationRules{Variation: VariationAK47},
		isWild: func(_ []Card, c Card) bool {
			return c.Rank == 14 || c.Rank == 13 || c.Rank == 4 || c.Rank == 7
		},
	})
	for _, rank := range Ranks {
		rank := rank
		sets = append(sets, wildRuleSet{
			name:   "JOKER " + string(oracleRankChar(rank)),
			rules:  RulesFor(VariationJoker, Card{Rank: rank, Suit: 'c'}),
			isWild: func(_ []Card, c Card) bool { return c.Rank == rank },
		})
	}
	for _, suit := range Suits {
		suit := suit
		sets = append(sets, wildRuleSet{
			name:   "HUKAM " + string(suit),
			rules:  RulesFor(VariationHukam, Card{Rank: 9, Suit: suit}),
			isWild: func(_ []Card, c Card) bool { return c.Suit == suit },
		})
	}
	sets = append(sets, wildRuleSet{
		name:  "LOWEST_JOKER",
		rules: VariationRules{Variation: VariationLowestJoker},
		isWild: func(hand []Card, c Card) bool {
			lowest := 15
			for _, x := range hand {
				if x.Rank < lowest {
					lowest = x.Rank
				}
			}
			return c.Rank == lowest
		},
	})
	sets = append(sets, wildRuleSet{
		name:  "HIGHEST_JOKER",
		rules: VariationRules{Variation: VariationHighestJoker},
		isWild: func(hand []Card, c Card) bool {
			highest := 0
			for _, x := range hand {
				if x.Rank > highest {
					highest = x.Rank
				}
			}
			return c.Rank == highest
		},
	})
	return sets
}

// checkWildHand holds one engine evaluation to the oracle. It returns the
// number of wild cards the rule made.
func checkWildHand(t *testing.T, set wildRuleSet, hand []Card) int {
	t.Helper()
	var mask [3]bool
	wilds := 0
	var wildCodes []string
	for i, c := range hand {
		mask[i] = set.isWild(hand, c)
		if mask[i] {
			wilds++
			wildCodes = append(wildCodes, c.Code())
		}
	}
	got := set.rules.EvaluateHand(hand)
	want, _ := oracleBestWithWilds(hand, mask)
	fail := func(format string, args ...any) {
		t.Helper()
		t.Errorf("%s %s: "+format, append([]any{set.name, codesOf(hand)}, args...)...)
	}
	// A wild card never makes a hand worse than its bare cards, and nothing
	// beats three aces.
	if classic := oracleEvaluate(hand); want.key < classic.key {
		fail("the oracle's best with wilds (%s) is worse than the bare cards (%s)", want.name, classic.name)
	}
	if want.key > oracleEvaluate(cardsOf("As", "Ah", "Ad")).key {
		fail("the oracle found something better than three aces")
	}
	if classic := Evaluate(hand, EvaluateOptions{}); Compare(got, classic) < 0 {
		fail("with wilds it is %s, worse than its classic %s", got.Name, classic.Name)
	}
	if got.Name != want.name || int(got.Category) != want.cat {
		fail("engine names it %s, oracle's best is %s", got.Name, want.name)
		return wilds
	}
	if codesOf(ParseCards(got.Cards)) != codesOf(hand) {
		fail("Cards = %v, must be the real cards", got.Cards)
	}
	if wilds == 0 {
		if got.Wild != nil || got.PlaysAs != nil {
			fail("no card is wild yet Wild=%v PlaysAs=%v", got.Wild, got.PlaysAs)
		}
		if classic := Evaluate(hand, EvaluateOptions{}); !reflect.DeepEqual(classic.Score, got.Score) {
			fail("no card is wild yet the score %v is not the classic %v", got.Score, classic.Score)
		}
		return 0
	}
	if strings.Join(got.Wild, " ") != strings.Join(wildCodes, " ") {
		fail("Wild = %v, the rule makes %v wild", got.Wild, wildCodes)
	}
	// PlaysAs must be a legal stand-in: three distinct real cards, the naturals
	// at their own places, no wild standing for a natural, and it must EVALUATE
	// (by the oracle and by the engine) to exactly the hand claimed.
	if len(got.PlaysAs) != 3 {
		fail("PlaysAs = %v", got.PlaysAs)
		return wilds
	}
	seen := map[string]bool{}
	naturals := map[string]bool{}
	for i, c := range hand {
		if !mask[i] {
			naturals[c.Code()] = true
		}
	}
	for i, code := range got.PlaysAs {
		if ParseCard(code).Rank == 0 || !strings.ContainsRune("shdc", rune(ParseCard(code).Suit)) {
			fail("PlaysAs[%d] = %q is not a card", i, code)
		}
		if seen[code] {
			fail("PlaysAs %v repeats %s", got.PlaysAs, code)
		}
		seen[code] = true
		if !mask[i] && code != hand[i].Code() {
			fail("PlaysAs[%d] = %s replaced the natural %s", i, code, hand[i].Code())
		}
		if mask[i] && naturals[code] {
			fail("PlaysAs[%d] = %s duplicates a natural card", i, code)
		}
	}
	playsAs := ParseCards(got.PlaysAs)
	if o := oracleEvaluate(playsAs); o.key != want.key {
		fail("PlaysAs %v is a %s worth %d by the oracle, the best reachable is %s worth %d", got.PlaysAs, o.name, o.key, want.name, want.key)
	}
	if e := Evaluate(playsAs, EvaluateOptions{}); !reflect.DeepEqual(e.Score, got.Score) {
		fail("PlaysAs %v scores %v classically, the hand claims %v", got.PlaysAs, e.Score, got.Score)
	}
	return wilds
}

func TestOracleWildVariationsAgreeWithBruteForce(t *testing.T) {
	hands := allThreeCardHands()
	rng := rand.New(rand.NewSource(47))

	// The hands every rule set is held on: all 3,744 pairs, all 52 trails, and
	// every hand made only of aces, kings, fours and sevens (C(16,3) = 560).
	var targeted [][]Card
	for _, hand := range hands {
		o := oracleEvaluate(hand)
		ak47 := true
		for _, c := range hand {
			if c.Rank != 14 && c.Rank != 13 && c.Rank != 4 && c.Rank != 7 {
				ak47 = false
			}
		}
		if o.cat == 1 || o.cat == 5 || ak47 {
			targeted = append(targeted, hand)
		}
	}
	if len(targeted) < 3744+52 {
		t.Fatalf("only %d targeted hands", len(targeted))
	}

	for _, set := range oracleWildRules() {
		set := set
		t.Run(set.name, func(t *testing.T) {
			var pool [][]Card
			switch {
			case strings.HasPrefix(set.name, "JOKER"), strings.HasPrefix(set.name, "HUKAM"):
				// Every hand the rule touches (at least one wild card), the
				// targeted set, and a random sample of the rest.
				for _, hand := range hands {
					touched := false
					for _, c := range hand {
						if set.isWild(hand, c) {
							touched = true
						}
					}
					if touched {
						pool = append(pool, hand)
					}
				}
				pool = append(pool, targeted...)
				for n := 0; n < 2000; n++ {
					pool = append(pool, hands[rng.Intn(len(hands))])
				}
			default:
				// AK47, LOWEST_JOKER, HIGHEST_JOKER: every hand there is.
				pool = hands
			}
			if len(pool) < 20_000 {
				// The brief asks for 20,000 random hands per variation at least.
				for len(pool) < 20_000 {
					pool = append(pool, hands[rng.Intn(len(hands))])
				}
			}
			wildCount := map[int]int{}
			for _, hand := range pool {
				wildCount[checkWildHand(t, set, hand)]++
				if t.Failed() && len(wildCount) > 0 {
					// Keep going for a while so the report lists several
					// cases, but not for ever.
					if n := wildCount[0] + wildCount[1] + wildCount[2] + wildCount[3]; n > 0 && n%500 == 0 {
						t.Fatalf("stopping after %d hands with failures", n)
					}
				}
			}
			t.Logf("%s: %d hands checked; wild cards per hand 0:%d 1:%d 2:%d 3:%d", set.name, len(pool), wildCount[0], wildCount[1], wildCount[2], wildCount[3])
		})
	}
}

// --------------------------------------------------------------- (3) Muflis

func TestOracleMuflisIsTheClassicOrderReversedWithTheAceHigh(t *testing.T) {
	muflis := VariationRules{Variation: VariationMuflis}
	hands := allThreeCardHands()
	type scored struct {
		cards  []Card
		engine EvaluatedHand
		oracle oracleHand
	}
	all := make([]scored, len(hands))
	for i, hand := range hands {
		e := muflis.EvaluateHand(hand)
		o := oracleEvaluate(hand)
		all[i] = scored{hand, e, o}
		if e.Name != o.name || int(e.Category) != o.cat {
			t.Errorf("%s: Muflis names it %s, classic is %s", codesOf(hand), e.Name, o.name)
		}
		if e.Wild != nil || e.PlaysAs != nil {
			t.Errorf("%s: Muflis has no wild cards, got %v / %v", codesOf(hand), e.Wild, e.PlaysAs)
		}
	}
	// Reversed order: the winner between any two is the classic loser.
	sort.SliceStable(all, func(i, j int) bool { return all[i].oracle.key < all[j].oracle.key })
	for i := 1; i < len(all); i++ {
		a, b := all[i], all[i-1]
		want := -sign64(a.oracle.key - b.oracle.key)
		if got := sign(muflis.CompareHands(a.engine, b.engine)); got != want {
			t.Errorf("%s vs %s: Muflis %d, want %d", codesOf(a.cards), codesOf(b.cards), got, want)
		}
		if got := sign(CompareMuflis(a.engine, b.engine)); got != want {
			t.Errorf("%s vs %s: CompareMuflis %d, want %d", codesOf(a.cards), codesOf(b.cards), got, want)
		}
	}
	rng := rand.New(rand.NewSource(532))
	for n := 0; n < 300_000; n++ {
		a, b := all[rng.Intn(len(all))], all[rng.Intn(len(all))]
		if got, want := sign(muflis.CompareHands(a.engine, b.engine)), -sign64(a.oracle.key-b.oracle.key); got != want {
			t.Fatalf("%s vs %s: Muflis %d, want %d", codesOf(a.cards), codesOf(b.cards), got, want)
		}
	}
	// 5-3-2 off-suit is the best hand there is; a trail of aces the worst.
	best := muflis.EvaluateHand(cardsOf("5s", "3h", "2d"))
	worst := muflis.EvaluateHand(cardsOf("As", "Ah", "Ad"))
	bestTies, worstTies := 0, 0
	for _, s := range all {
		switch d := muflis.CompareHands(s.engine, best); {
		case d > 0:
			t.Errorf("%s beats 5-3-2 under Muflis", codesOf(s.cards))
		case d == 0:
			bestTies++
		}
		switch d := muflis.CompareHands(s.engine, worst); {
		case d < 0:
			t.Errorf("%s loses to A-A-A under Muflis", codesOf(s.cards))
		case d == 0:
			worstTies++
		}
	}
	eq(t, bestTies, 4*4*4-4, "5-3-2 off-suit in every suit combination but the four colors ties the best")
	eq(t, worstTies, 4, "the four trails of aces tie the worst")
	// The ace stays high: A-4-2 is an ace-high hand and loses to 6-4-2.
	if muflis.CompareHands(muflis.EvaluateHand(cardsOf("6h", "4s", "2d")), muflis.EvaluateHand(cardsOf("Ah", "4s", "2d"))) <= 0 {
		t.Error("under Muflis 6-4-2 must beat A-4-2 (the ace is high)")
	}
	// A-2-3 is still a run (the second best), so it loses to 4-3-2 and to any high card.
	if muflis.CompareHands(muflis.EvaluateHand(cardsOf("4h", "3s", "2d")), muflis.EvaluateHand(cardsOf("Ah", "2s", "3d"))) <= 0 {
		t.Error("under Muflis 4-3-2 must beat A-2-3")
	}
	if muflis.CompareHands(muflis.EvaluateHand(cardsOf("Kh", "Qs", "2d")), muflis.EvaluateHand(cardsOf("Ah", "2s", "3d"))) <= 0 {
		t.Error("under Muflis a king-high beats the A-2-3 run")
	}
	// Exact ties are still ties.
	if muflis.CompareHands(muflis.EvaluateHand(cardsOf("Qs", "8h", "3d")), muflis.EvaluateHand(cardsOf("Qh", "8d", "3c"))) != 0 {
		t.Error("the same ranks in other suits tie under Muflis")
	}
}

// ------------------------------------------------------------ (4) FIVE_CARD

func TestOracleFiveCardPlaysTheBestThreeOfFive(t *testing.T) {
	rng := rand.New(rand.NewSource(5))
	deck := NewDeck()
	five := VariationRules{Variation: VariationFiveCard}
	for n := 0; n < 20_000; n++ {
		rng.Shuffle(len(deck), func(i, j int) { deck[i], deck[j] = deck[j], deck[i] })
		hand := append([]Card{}, deck[:5]...)

		// The oracle: the best of the ten combinations.
		var best oracleHand
		found := false
		combos := 0
		for i := 0; i < 5; i++ {
			for j := i + 1; j < 5; j++ {
				for k := j + 1; k < 5; k++ {
					combos++
					o := oracleEvaluate([]Card{hand[i], hand[j], hand[k]})
					if !found || o.key > best.key {
						best, found = o, true
					}
				}
			}
		}
		eq(t, combos, 10, "C(5,3)")

		for _, got := range []EvaluatedHand{EvaluateBest(hand), five.EvaluateHand(hand)} {
			if got.Name != best.name || int(got.Category) != best.cat {
				t.Fatalf("%s: engine %s, oracle %s", codesOf(hand), got.Name, best.name)
			}
			if codesOf(ParseCards(got.Cards)) != codesOf(hand) {
				t.Fatalf("%s: Cards = %v, must be all five", codesOf(hand), got.Cards)
			}
			if got.Wild != nil || got.PlaysAs != nil {
				t.Fatalf("%s: FIVE_CARD has no wild cards, got %v / %v", codesOf(hand), got.Wild, got.PlaysAs)
			}
			if len(got.Best) != 3 {
				t.Fatalf("%s: Best = %v", codesOf(hand), got.Best)
			}
			// Best is three of the held cards, in the order held.
			at := -1
			for _, code := range got.Best {
				idx := -1
				for i := at + 1; i < 5; i++ {
					if hand[i].Code() == code {
						idx = i
						break
					}
				}
				if idx < 0 {
					t.Fatalf("%s: Best %v is not three held cards in held order", codesOf(hand), got.Best)
				}
				at = idx
			}
			bestCards := ParseCards(got.Best)
			if o := oracleEvaluate(bestCards); o.key != best.key {
				t.Fatalf("%s: Best %v is a %s worth %d, the best three are worth %d", codesOf(hand), got.Best, o.name, o.key, best.key)
			}
			if e := Evaluate(bestCards, EvaluateOptions{}); !reflect.DeepEqual(e.Score, got.Score) {
				t.Fatalf("%s: Best %v scores %v, the hand claims %v", codesOf(hand), got.Best, e.Score, got.Score)
			}
		}
	}
}

// ------------------------------------------------- (5) the owner's case

// Every rule set a variation table's hand can be decided by, plus the classic
// zero rules of a seen or blind table.
func oracleEveryRuleSet() []wildRuleSet {
	sets := []wildRuleSet{
		{name: "classic (seen/blind)", rules: VariationRules{}, isWild: func([]Card, Card) bool { return false }},
		{name: "MUFLIS", rules: VariationRules{Variation: VariationMuflis}, isWild: func([]Card, Card) bool { return false }},
	}
	return append(sets, oracleWildRules()...)
}

func TestOracleAPairIsCalledATrailOnlyWhenAWildCardCompletesIt(t *testing.T) {
	hands := allThreeCardHands()
	var pairs [][]Card
	for _, hand := range hands {
		if oracleEvaluate(hand).cat == 1 {
			pairs = append(pairs, hand)
		}
	}
	eq(t, len(pairs), 3744, "every natural pair")

	for _, set := range oracleEveryRuleSet() {
		trails, unchanged := 0, 0
		for _, hand := range pairs {
			got := set.rules.EvaluateHand(hand)
			if len(got.Wild) == 0 {
				// With NO wild card a pair is a Pair and nothing else, at
				// every table there is.
				if got.Name != "Pair" || got.Category != Pair {
					t.Errorf("%s %s: no wild card, yet a pair is called %s", set.name, codesOf(hand), got.Name)
				}
				if classic := Evaluate(hand, EvaluateOptions{}); !reflect.DeepEqual(classic.Score, got.Score) {
					t.Errorf("%s %s: no wild card, yet scored %v not %v", set.name, codesOf(hand), got.Score, classic.Score)
				}
				unchanged++
				continue
			}
			if got.Category != Trail {
				continue
			}
			trails++
			// A pair named a Trail: at least one card is wild (checked), and
			// the pair plus its wild(s) really can form a trail — the hand as
			// counted is three cards of one rank, distinct, with every natural
			// card still in it.
			playsAs := ParseCards(got.PlaysAs)
			if len(playsAs) != 3 {
				t.Errorf("%s %s: called a Trail with PlaysAs %v", set.name, codesOf(hand), got.PlaysAs)
				continue
			}
			if playsAs[0].Rank != playsAs[1].Rank || playsAs[1].Rank != playsAs[2].Rank {
				t.Errorf("%s %s: called a Trail but plays as %v", set.name, codesOf(hand), got.PlaysAs)
			}
			if playsAs[0] == playsAs[1] || playsAs[1] == playsAs[2] || playsAs[0] == playsAs[2] {
				t.Errorf("%s %s: plays as %v, a card twice", set.name, codesOf(hand), got.PlaysAs)
			}
			wild := map[string]bool{}
			for _, w := range got.Wild {
				wild[w] = true
			}
			for i, c := range hand {
				if !wild[c.Code()] && playsAs[i] != c {
					t.Errorf("%s %s: the natural %s is not in the counted hand %v", set.name, codesOf(hand), c.Code(), got.PlaysAs)
				}
			}
			// (That the oracle's brute force agrees a Trail is the best these
			// wilds can reach is held by TestOracleWildVariationsAgreeWithBruteForce,
			// whose targeted set holds every pair hand under every rule set.)
			// Which happens only when the kicker is wild, or both pair cards
			// are, or all three — never when exactly one card of the pair is
			// the only wild (two different naturals cannot become a trail).
			ranks := map[int]int{}
			for _, c := range hand {
				ranks[c.Rank]++
			}
			wildPair, wildKicker := 0, 0
			for _, c := range hand {
				if wild[c.Code()] {
					if ranks[c.Rank] == 2 {
						wildPair++
					} else {
						wildKicker++
					}
				}
			}
			if wildKicker == 0 && wildPair == 1 {
				t.Errorf("%s %s: a Trail from a lone wild pair card, wild %v plays as %v", set.name, codesOf(hand), got.Wild, got.PlaysAs)
			}
		}
		t.Logf("%-22s pairs that became a Trail: %5d; pairs untouched (no wild card): %5d", set.name, trails, unchanged)
		switch set.name {
		case "classic (seen/blind)", "MUFLIS":
			eq(t, trails, 0, set.name+": a pair is never a trail")
			eq(t, unchanged, 3744, set.name+": every pair is a pair")
		case "LOWEST_JOKER", "HIGHEST_JOKER":
			// Every pair hand has a lowest and a highest rank, so every pair
			// is touched and every one becomes a trail: the kicker wild
			// completes the pair, or the wild pair matches the kicker.
			eq(t, unchanged, 0, set.name+": every pair holds a wild card")
			eq(t, trails, 3744, set.name+": every pair becomes a trail")
		}
	}
}

// --------------------------------------- the owner's case at the table

// classicShowdown plays a two-player hand of category cat to a show with the
// cards given and returns who won and the reveals. a is seat 0.
func classicShowdown(t *testing.T, cat Category, aCards, bCards []string) (winner string, ended HandEndedEvent) {
	t.Helper()
	cfg := sideshowConfig()
	cfg.Category = cat
	h := newHarness(t, cfg, withLedger(emptyLedger), withID("oracle-"+string(cat), "ORACLE01"))
	h.seatNamed("p0", "P0", sideshowStart)
	h.seatNamed("p1", "P1", sideshowStart)
	h.advance(cfg.NextHandDelay)
	eq(t, h.handNo(), 1, "dealt")
	h.setCards("p0", aCards...)
	h.setCards("p1", bCards...)
	for _, id := range []string{"p0", "p1"} {
		h.mustAct(id, ActionSee, ActRequest{})
	}
	h.mustAct(h.turnUser(), ActionShow, ActRequest{})
	ended = h.lastEnded()
	if ended.WinnerID == nil {
		t.Fatal("no winner")
	}
	return *ended.WinnerID, ended
}

func revealsByUser(ended HandEndedEvent) map[string]Reveal {
	out := map[string]Reveal{}
	for _, r := range ended.Reveals {
		out[r.UserID] = r
	}
	return out
}

func TestOracleOwnersCaseAtSeenBlindAndVariationTables(t *testing.T) {
	pair := []string{"9s", "9h", "2c"}  // a natural pair of nines
	color := []string{"Qd", "8d", "3d"} // a queen-high color, which beats any pair

	// Seen and blind: the pair is a Pair and loses to the color.
	for _, cat := range []Category{CategorySeen, CategoryBlind} {
		winner, ended := classicShowdown(t, cat, pair, color)
		eq(t, winner, "p1", string(cat)+": the color beats the pair")
		r := revealsByUser(ended)
		eq(t, r["p0"].HandName, "Pair", string(cat)+": the pair is named a Pair")
		eq(t, r["p1"].HandName, "Color", string(cat)+": the color is named a Color")
		eq(t, len(r["p0"].Wild), 0, string(cat)+": nothing is wild")
		eq(t, ended.Variation, Variation(""), string(cat)+": no variation on the wire")
	}

	// Variation, AK47, with NO wild card in the pair hand: still a Pair, and
	// it still loses to the color.
	winner, ended, _ := showdownUnder(t, VariationAK47, "", pair, color)
	eq(t, winner, "p1", "AK47 with no wild card: the color beats the pair")
	r := revealsByUser(ended)
	eq(t, r["p0"].HandName, "Pair", "AK47: a pair with no wild card is a Pair")
	eq(t, len(r["p0"].Wild), 0, "AK47: no wild card")

	// Variation, AK47, the pair's kicker is a wild 4: the hand MADE is a trail
	// of nines, the reveal says so, names the 4 as wild, and it wins.
	winner, ended, _ = showdownUnder(t, VariationAK47, "", []string{"9s", "9h", "4c"}, color)
	eq(t, winner, "p0", "AK47: a pair of nines plus a wild four is a trail")
	r = revealsByUser(ended)
	eq(t, r["p0"].HandName, "Trail", "the reveal names what the hand made")
	eq(t, strings.Join(r["p0"].Cards, " "), "9s 9h 4c", "but shows the cards really held")
	eq(t, strings.Join(r["p0"].Wild, " "), "4c", "and names the wild card")

	// Variation, JOKER with a turned-up rank nobody holds: classic, the pair
	// loses to the color. With the kicker's rank turned up: a trail, and it wins.
	winner, ended, _ = showdownUnder(t, VariationJoker, "Jc", pair, color)
	eq(t, winner, "p1", "JOKER (jacks) touches neither hand: the color wins")
	eq(t, revealsByUser(ended)["p0"].HandName, "Pair", "and the pair is a Pair")
	winner, ended, _ = showdownUnder(t, VariationJoker, "2d", pair, color)
	eq(t, winner, "p0", "JOKER (twos): the wild kicker completes the trail")
	eq(t, revealsByUser(ended)["p0"].HandName, "Trail", "named a Trail")
	eq(t, strings.Join(revealsByUser(ended)["p0"].Wild, " "), "2c", "with the two wild")

	// Muflis: the pair LOSES to a worse classic hand, never wins by being a pair.
	winner, ended, _ = showdownUnder(t, VariationMuflis, "", pair, []string{"Kd", "8h", "3c"})
	eq(t, winner, "p1", "Muflis: the king-high beats the pair")
	eq(t, revealsByUser(ended)["p0"].HandName, "Pair", "Muflis names the classic hand")

	// Two natural pairs under a wild rule that touches neither: the higher
	// pair wins, exactly as at a seen table.
	winner, _, _ = showdownUnder(t, VariationHukam, "Tc", []string{"9s", "9h", "2d"}, []string{"Js", "Jh", "3d"})
	eq(t, winner, "p1", "HUKAM (clubs) touches neither: jacks beat nines")
	winner, _ = classicShowdown(t, CategorySeen, []string{"9s", "9h", "2d"}, []string{"Js", "Jh", "3d"})
	eq(t, winner, "p1", "seen: jacks beat nines")
	winner, _ = classicShowdown(t, CategoryBlind, []string{"Js", "Jh", "3d"}, []string{"9s", "9h", "2d"})
	eq(t, winner, "p0", "blind: jacks beat nines from either seat")
}

// A guard against this file's own oracle drifting: its clock is real time,
// so keep it honest about how long the brute force takes.
func TestOracleBruteForceCostIsBounded(t *testing.T) {
	start := time.Now()
	worst := 0
	for _, hand := range [][]Card{cardsOf("As", "Kh", "4d"), cardsOf("As", "2h", "3d"), cardsOf("2s", "2h", "2d")} {
		var mask [3]bool
		for i, c := range hand {
			mask[i] = c.Rank == 14 || c.Rank == 13 || c.Rank == 4 || c.Rank == 7 || hand[0].Rank == hand[1].Rank
		}
		_, standIns := oracleBestWithWilds(hand, mask)
		if len(standIns) > worst {
			worst = len(standIns)
		}
	}
	if worst != 3 {
		t.Fatalf("three wilds must yield three stand-ins, got %d", worst)
	}
	if d := time.Since(start); d > 30*time.Second {
		t.Fatalf("the oracle took %s on three hands", d)
	}
}
