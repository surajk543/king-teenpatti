package poker

import (
	"sort"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// The five-card evaluator. It is NOT game.Evaluate: Teen Patti's ranking is
// three cards, its categories and its doubled run scale are its own, and
// changing either would move every Teen Patti score the two external oracles
// pin (POKER_PLAN.md §9). This one shares only what is game-neutral — the
// Card, the wire codes and the Score convention `[category, tiebreaks…]` that
// Compare reads element by element.

// Category is a five-card poker hand's rank, weakest first. The numbers are
// the first element of Hand.Score, so they are the order of strength.
type Category int

const (
	HighCard      Category = iota // 0
	Pair                          // 1
	TwoPair                       // 2
	ThreeOfAKind                  // 3
	Straight                      // 4
	Flush                         // 5
	FullHouse                     // 6
	FourOfAKind                   // 7
	StraightFlush                 // 8
	RoyalFlush                    // 9
)

// CategoryNames are the wire hand names, by Category.
var CategoryNames = [...]string{
	HighCard: "High Card", Pair: "Pair", TwoPair: "Two Pair", ThreeOfAKind: "Three of a Kind",
	Straight: "Straight", Flush: "Flush", FullHouse: "Full House", FourOfAKind: "Four of a Kind",
	StraightFlush: "Straight Flush", RoyalFlush: "Royal Flush",
}

// String is the wire name.
func (c Category) String() string {
	if int(c) < len(CategoryNames) {
		return CategoryNames[c]
	}
	return "Unknown"
}

// Hand is an evaluated hand: what it made and the cards it was made from.
// Score is [category, tiebreaks…] and is the ONLY thing Compare reads; suits
// never break ties. Cards are every card the player held (wire codes, in
// the order held) and Best the ones that were counted — the five of a seven-
// card Hold'em hand, the two-plus-three of Omaha, all five of a Draw hand,
// all three of a 3-Card Poker hand — in the order held.
type Hand struct {
	Category int      `json:"category"`
	Name     string   `json:"handName"`
	Score    []int    `json:"-"`
	Cards    []string `json:"cards"`
	Best     []string `json:"best"`
}

// Compare returns > 0 when a wins, < 0 when b wins, 0 on an exact tie
// (element-wise on Score; a missing element compares as 0, as game.Compare).
func Compare(a, b Hand) int {
	length := len(a.Score)
	if len(b.Score) > length {
		length = len(b.Score)
	}
	for i := 0; i < length; i++ {
		var x, y int
		if i < len(a.Score) {
			x = a.Score[i]
		}
		if i < len(b.Score) {
			y = b.Score[i]
		}
		if diff := x - y; diff != 0 {
			return diff
		}
	}
	return 0
}

// Evaluate5 scores exactly five cards. Panics on any other count — a hand of
// another size is a programming error, as game.Evaluate treats it.
//
// Ranks are sorted descending and grouped; a flush is all one suit; a
// straight is five distinct consecutive ranks, or the wheel A-2-3-4-5 whose
// high card counts as 5 (an ace plays low there and nowhere else). Tiebreaks:
//
//	Royal Flush      []                         (a royal flush ties a royal flush)
//	Straight Flush   [high]
//	Four of a Kind   [quad, kicker]
//	Full House       [trips, pair]
//	Flush            [r1 r2 r3 r4 r5]
//	Straight         [high]
//	Three of a Kind  [trips, k1, k2]
//	Two Pair         [high pair, low pair, kicker]
//	Pair             [pair, k1, k2, k3]
//	High Card        [r1 r2 r3 r4 r5]
func Evaluate5(cards []game.Card) Hand {
	if len(cards) != 5 {
		panic("a five-card poker hand must be exactly 5 cards")
	}
	ranks := make([]int, 5)
	for i, c := range cards {
		ranks[i] = c.Rank
	}
	sort.Sort(sort.Reverse(sort.IntSlice(ranks)))
	flush := true
	for _, c := range cards[1:] {
		if c.Suit != cards[0].Suit {
			flush = false
			break
		}
	}
	straightHigh := straightHigh5(ranks)

	// Group by rank: counts in descending count then descending rank order.
	type group struct{ rank, n int }
	var groups []group
	for _, r := range ranks {
		if len(groups) > 0 && groups[len(groups)-1].rank == r {
			groups[len(groups)-1].n++
			continue
		}
		groups = append(groups, group{rank: r, n: 1})
	}
	sort.SliceStable(groups, func(i, j int) bool {
		if groups[i].n != groups[j].n {
			return groups[i].n > groups[j].n
		}
		return groups[i].rank > groups[j].rank
	})

	var category Category
	var tiebreak []int
	switch {
	case straightHigh > 0 && flush:
		if straightHigh == 14 {
			category = RoyalFlush
		} else {
			category = StraightFlush
			tiebreak = []int{straightHigh}
		}
	case groups[0].n == 4:
		category = FourOfAKind
		tiebreak = []int{groups[0].rank, groups[1].rank}
	case groups[0].n == 3 && groups[1].n == 2:
		category = FullHouse
		tiebreak = []int{groups[0].rank, groups[1].rank}
	case flush:
		category = Flush
		tiebreak = ranks
	case straightHigh > 0:
		category = Straight
		tiebreak = []int{straightHigh}
	case groups[0].n == 3:
		category = ThreeOfAKind
		tiebreak = []int{groups[0].rank, groups[1].rank, groups[2].rank}
	case groups[0].n == 2 && groups[1].n == 2:
		category = TwoPair
		tiebreak = []int{groups[0].rank, groups[1].rank, groups[2].rank}
	case groups[0].n == 2:
		category = Pair
		tiebreak = []int{groups[0].rank, groups[1].rank, groups[2].rank, groups[3].rank}
	default:
		category = HighCard
		tiebreak = ranks
	}

	score := make([]int, 0, 1+len(tiebreak))
	score = append(score, int(category))
	score = append(score, tiebreak...)
	codes := game.CardCodes(cards)
	return Hand{Category: int(category), Name: CategoryNames[category], Score: score, Cards: codes, Best: append([]string(nil), codes...)}
}

// straightHigh5 is the high card of a five-card straight (5 for the wheel),
// or 0 when the descending ranks are not one.
func straightHigh5(desc []int) int {
	for i := 1; i < 5; i++ {
		if desc[i] != desc[i-1]-1 {
			// The wheel: A 5 4 3 2 sorts as 14 5 4 3 2.
			if desc[0] == 14 && desc[1] == 5 && desc[2] == 4 && desc[3] == 3 && desc[4] == 2 {
				return 5
			}
			return 0
		}
	}
	return desc[0]
}

// Combinations lists every k-subset of n indices in lexicographic order:
// Combinations(5, 3) is [0 1 2] [0 1 3] … [2 3 4]. k > n or k ≤ 0 gives none.
func Combinations(n, k int) [][]int {
	if k <= 0 || k > n {
		return nil
	}
	var out [][]int
	idx := make([]int, k)
	for i := range idx {
		idx[i] = i
	}
	for {
		out = append(out, append([]int(nil), idx...))
		// Advance the rightmost index that can still move.
		i := k - 1
		for i >= 0 && idx[i] == n-k+i {
			i--
		}
		if i < 0 {
			return out
		}
		idx[i]++
		for j := i + 1; j < k; j++ {
			idx[j] = idx[j-1] + 1
		}
	}
}

// BestOf is the strongest five-card hand among all cards (len ≥ 5): every
// C(n,5) subset through Evaluate5, walked in index order, a later one kept
// only when STRICTLY better — so which cards Best names is deterministic
// among equal hands, and being equal it cannot change who wins. Cards holds
// every card given, in the order given; Best the five counted, in that order.
func BestOf(cards []game.Card) Hand {
	if len(cards) < 5 {
		panic("BestOf needs at least five cards")
	}
	var best Hand
	found := false
	pick := make([]game.Card, 5)
	for _, combo := range Combinations(len(cards), 5) {
		for i, c := range combo {
			pick[i] = cards[c]
		}
		h := Evaluate5(pick)
		if !found || Compare(h, best) > 0 {
			best = h
			best.Best = bestCodes(cards, combo)
			found = true
		}
	}
	best.Cards = game.CardCodes(cards)
	return best
}

// bestCodes names the counted cards in the order they were held.
func bestCodes(cards []game.Card, combo []int) []string {
	out := make([]string, 0, len(combo))
	for _, i := range combo {
		out = append(out, cards[i].Code())
	}
	return out
}

// BestHoldem is the best five of the two hole cards and the board (up to
// seven cards, C(7,5) = 21). Fewer than five cards in all (a board not yet
// dealt) is scored on what there is only when there are five; before that
// the hand is nameless (ok false).
func BestHoldem(hole, board []game.Card) (Hand, bool) {
	all := append(append([]game.Card(nil), hole...), board...)
	if len(all) < 5 {
		return Hand{}, false
	}
	return BestOf(all), true
}

// BestOmaha is the best hand of EXACTLY two of the four hole cards and three
// of the board (C(4,2) × C(5,3) = 60 on a full board). A board of fewer than
// three cards has no hand (ok false).
func BestOmaha(hole, board []game.Card) (Hand, bool) {
	if len(hole) != 4 || len(board) < 3 {
		return Hand{}, false
	}
	var best Hand
	found := false
	pick := make([]game.Card, 5)
	all := append(append([]game.Card(nil), hole...), board...)
	for _, hc := range Combinations(4, 2) {
		for _, bc := range Combinations(len(board), 3) {
			pick[0], pick[1] = hole[hc[0]], hole[hc[1]]
			pick[2], pick[3], pick[4] = board[bc[0]], board[bc[1]], board[bc[2]]
			h := Evaluate5(pick)
			if !found || Compare(h, best) > 0 {
				best = h
				combo := []int{hc[0], hc[1], 4 + bc[0], 4 + bc[1], 4 + bc[2]}
				best.Best = bestCodes(all, combo)
				found = true
			}
		}
	}
	best.Cards = game.CardCodes(all)
	return best, true
}
