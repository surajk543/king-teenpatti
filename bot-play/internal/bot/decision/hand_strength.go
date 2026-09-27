package decision

import (
	"fmt"
	"sort"
	"strings"
	"sync"
)

// The classic Teen Patti ranking, as the game server scores it.
//
// This is a client's copy of go-server/internal/game/handrank.go (Evaluate,
// Compare, EvaluateBest), which a separate module cannot import. It is pinned
// to the server's own results: TestRankingIsTheServers compares a
// fingerprint of the server's scores for all 22,100 possible hands, taken
// from go-server/internal/game.Evaluate on 27 Sep 2026, with this copy's.
// A bot uses it only to judge its OWN cards — the server's showdown decides
// every hand, and on variation tables the server evaluates the viewer's hand
// itself (you.hand), so no wild-card rule is copied here.

const ranks = "23456789TJQKA"

// CategoryNames are the server's wire hand names, HighCard 0 … Trail 5.
var CategoryNames = [...]string{"High Card", "Pair", "Color", "Sequence", "Pure Sequence", "Trail"}

// Hand is three cards scored: Score compares element by element, Category is
// Score[0].
type Hand struct {
	Category int
	Name     string
	Score    []int
	Cards    []string
}

// ParseCard reads a wire card code ("As", "Td"): rank 2..14 and the suit
// letter. ok is false for anything that is not a card.
func ParseCard(code string) (rank int, suit byte, ok bool) {
	if len(code) != 2 {
		return 0, 0, false
	}
	i := strings.IndexByte(ranks, code[0])
	if i < 0 || strings.IndexByte("shdc", code[1]) < 0 {
		return 0, 0, false
	}
	return i + 2, code[1], true
}

// Rank scores exactly three cards the way the server's Evaluate does.
func Rank(cards []string) (Hand, error) {
	if len(cards) != 3 {
		return Hand{}, fmt.Errorf("decision: a hand is exactly 3 cards, got %d", len(cards))
	}
	var r [3]int
	var s [3]byte
	for i, c := range cards {
		rank, suit, ok := ParseCard(c)
		if !ok {
			return Hand{}, fmt.Errorf("decision: not a card: %q", c)
		}
		r[i], s[i] = rank, suit
	}
	sort.Sort(sort.Reverse(sort.IntSlice(r[:])))
	high, mid, low := r[0], r[1], r[2]
	sameSuit := s[0] == s[1] && s[1] == s[2]

	var category int
	var tiebreak []int
	switch {
	case high == mid && mid == low:
		category, tiebreak = 5, []int{high}
	case isRun(high, mid, low):
		category = 3
		if sameSuit {
			category = 4
		}
		tiebreak = []int{runStrength(high, mid, low)}
	case sameSuit:
		category, tiebreak = 2, []int{high, mid, low}
	case high == mid || mid == low:
		kicker := high
		if high == mid {
			kicker = low
		}
		category, tiebreak = 1, []int{mid, kicker}
	default:
		category, tiebreak = 0, []int{high, mid, low}
	}
	score := append([]int{category}, tiebreak...)
	return Hand{Category: category, Name: CategoryNames[category], Score: score, Cards: append([]string(nil), cards...)}, nil
}

// isRun: the A-2-3 wheel or three consecutive ranks; K-A-2 never wraps.
func isRun(high, mid, low int) bool {
	if high == 14 && mid == 3 && low == 2 {
		return true
	}
	return high-mid == 1 && mid-low == 1
}

// runStrength: A-K-Q 28 > A-2-3 27 > K-Q-J 26 > … > 4-3-2 8.
func runStrength(high, mid, low int) int {
	if high == 14 && mid == 3 && low == 2 {
		return 27
	}
	return 2 * high
}

// Compare is > 0 when a wins, < 0 when b wins, 0 on an exact tie. Suits never
// break a tie.
func Compare(a, b Hand) int {
	n := max(len(a.Score), len(b.Score))
	for i := 0; i < n; i++ {
		var x, y int
		if i < len(a.Score) {
			x = a.Score[i]
		}
		if i < len(b.Score) {
			y = b.Score[i]
		}
		if x != y {
			return x - y
		}
	}
	return 0
}

// Combinations3 is every three of cards in index order (C(5,3) = 10 for a
// 5-Card hand) — the order the server walks them in.
func Combinations3(cards []string) [][]string {
	var out [][]string
	for i := 0; i < len(cards); i++ {
		for j := i + 1; j < len(cards); j++ {
			for k := j + 1; k < len(cards); k++ {
				out = append(out, []string{cards[i], cards[j], cards[k]})
			}
		}
	}
	return out
}

// BestThree is the strongest three of cards, in the order held — the
// server's EvaluateBest: a later combination must be STRICTLY better, so
// which of two equal hands is named matches the server's bestPossible.
func BestThree(cards []string) (Hand, error) {
	if len(cards) == 3 {
		return Rank(cards)
	}
	if len(cards) < 3 {
		return Hand{}, fmt.Errorf("decision: %d cards cannot make a hand", len(cards))
	}
	var best Hand
	found := false
	for _, combo := range Combinations3(cards) {
		h, err := Rank(combo)
		if err != nil {
			return Hand{}, err
		}
		if !found || Compare(h, best) > 0 {
			best, found = h, true
		}
	}
	return best, nil
}

// Deck is every card code, ranks 2…A, suits s h d c.
func Deck() []string {
	out := make([]string, 0, 52)
	for i := 0; i < len(ranks); i++ {
		for _, s := range "shdc" {
			out = append(out, string(ranks[i])+string(s))
		}
	}
	return out
}

var (
	percentileOnce sync.Once
	percentiles    map[string]float64
)

// Percentile is where a scored hand sits among all 22,100: the share of
// hands it beats, ties counted half — 0 the worst hand there is, 1 the best.
func Percentile(h Hand) float64 {
	percentileOnce.Do(buildPercentiles)
	return percentiles[scoreKey(h.Score)]
}

// Strength is Percentile of three cards; 0 for anything that is not a hand.
func Strength(cards []string) float64 {
	h, err := Rank(cards)
	if err != nil {
		return 0
	}
	return Percentile(h)
}

func scoreKey(score []int) string { return fmt.Sprint(score) }

func buildPercentiles() {
	deck := Deck()
	hands := make([]Hand, 0, 22100)
	for _, combo := range Combinations3(deck) {
		h, _ := Rank(combo)
		hands = append(hands, h)
	}
	sort.SliceStable(hands, func(i, j int) bool { return Compare(hands[i], hands[j]) < 0 })
	percentiles = make(map[string]float64, 600)
	n := float64(len(hands))
	for start := 0; start < len(hands); {
		end := start + 1
		for end < len(hands) && Compare(hands[end], hands[start]) == 0 {
			end++
		}
		percentiles[scoreKey(hands[start].Score)] = (float64(start) + float64(end-start)/2) / n
		start = end
	}
}
