package game

import (
	"sort"
)

// Port of server/src/game/handRank.js.

// HandCategory ranks Teen Patti hand types, low to high. The number is the
// primary comparison key, so a bigger category always beats a smaller one.
type HandCategory int

const (
	HighCard     HandCategory = 0
	Pair         HandCategory = 1
	Color        HandCategory = 2 // flush: three of a suit that is not a run
	Sequence     HandCategory = 3 // run: three consecutive ranks, mixed suits
	PureSequence HandCategory = 4 // straight flush
	Trail        HandCategory = 5 // trio / set: three of a kind
)

// CategoryNames are the ENGLISH wire names (handName in reveals). Flutter
// shows them untranslated — do not localise here.
var CategoryNames = map[HandCategory]string{
	HighCard:     "High Card",
	Pair:         "Pair",
	Color:        "Color",
	Sequence:     "Sequence",
	PureSequence: "Pure Sequence",
	Trail:        "Trail",
}

// String returns the wire name.
func (c HandCategory) String() string { return CategoryNames[c] }

// EvaluatedHand is the comparable descriptor Evaluate produces.
//
// Score is compared element by element: [category, ...tiebreakers]. Lengths
// differ by category (trail: 1 tiebreak; sequence: 1; pair: 2; color / high
// card: 3) but never mix because the category always decides first.
type EvaluatedHand struct {
	Category HandCategory
	Name     string   // CategoryNames[Category]
	Score    []int    // [category, tiebreak...]
	Cards    []string // wire codes of the input, same order
}

// EvaluateOptions carries the one variant switch. AceLowIsLowest=false (the
// default, and what the Table uses) is standard Teen Patti: A-2-3 ranks just
// below A-K-Q and above K-Q-J. With it true, A-2-3 is the weakest run.
type EvaluateOptions struct {
	AceLowIsLowest bool
}

// Evaluate scores a 3-card hand (handRank.js evaluate). Panics (Node throws)
// on len(cards) != 3 — a hand with any other size is a programming error.
//
// Algorithm, in this order:
//  1. ranks sorted descending [high, mid, low]; sameSuit = all three suits equal;
//  2. high==mid==low → Trail, tiebreak [high];
//  3. isRun (A-2-3 wheel, or high-mid==1 && mid-low==1) → PureSequence if
//     sameSuit else Sequence, tiebreak [runStrength] where runStrength is on a
//     DOUBLED scale: A-K-Q = 28 > A-2-3 = 27 > K-Q-J = 26 > … > 4-3-2 = 8
//     (A-2-3 = 5 when AceLowIsLowest); normal runs score 2*high;
//  4. sameSuit → Color, tiebreak [high, mid, low];
//  5. high==mid || mid==low → Pair, tiebreak [pairRank=mid, kicker];
//  6. else HighCard, tiebreak [high, mid, low].
//
// Suits never break ties (CLAUDE.md §6.3).
func Evaluate(cards []Card, opts EvaluateOptions) EvaluatedHand {
	if len(cards) != 3 {
		panic("a Teen Patti hand must be exactly 3 cards")
	}

	ranks := [3]int{cards[0].Rank, cards[1].Rank, cards[2].Rank}
	sort.Sort(sort.Reverse(sort.IntSlice(ranks[:])))
	high, mid, low := ranks[0], ranks[1], ranks[2]
	sameSuit := cards[0].Suit == cards[1].Suit && cards[1].Suit == cards[2].Suit

	var category HandCategory
	var tiebreak []int

	switch {
	case high == mid && mid == low:
		category = Trail
		tiebreak = []int{high}
	case isRun(high, mid, low):
		if sameSuit {
			category = PureSequence
		} else {
			category = Sequence
		}
		tiebreak = []int{runStrength(high, mid, low, opts.AceLowIsLowest)}
	case sameSuit:
		category = Color
		tiebreak = []int{high, mid, low}
	case high == mid || mid == low:
		category = Pair
		// mid is always part of the pair; the remaining card is the kicker.
		kicker := high
		if high == mid {
			kicker = low
		}
		tiebreak = []int{mid, kicker}
	default:
		category = HighCard
		tiebreak = []int{high, mid, low}
	}

	score := make([]int, 0, 1+len(tiebreak))
	score = append(score, int(category))
	score = append(score, tiebreak...)

	return EvaluatedHand{
		Category: category,
		Name:     CategoryNames[category],
		Score:    score,
		Cards:    CardCodes(cards),
	}
}

// isRun reports whether the descending ranks form a Teen Patti run: the
// A-2-3 wheel, or three consecutive ranks. K-A-2 never wraps around.
func isRun(high, mid, low int) bool {
	if high == 14 && mid == 3 && low == 2 {
		return true
	}
	return high-mid == 1 && mid-low == 1
}

// runStrength ranks a run on a doubled scale so A-2-3 can slot between A-K-Q
// and K-Q-J without fractions:
//
//	A-K-Q = 28  >  A-2-3 = 27  >  K-Q-J = 26  >  ...  >  4-3-2 = 8
//
// This is the standard Teen Patti ordering (the ace plays high in A-K-Q and
// low in A-2-3, and A-2-3 outranks every run below A-K-Q). aceLowIsLowest is
// the variant where A-2-3 is the weakest run (5 < 4-3-2's 8).
func runStrength(high, mid, low int, aceLowIsLowest bool) int {
	if high == 14 && mid == 3 && low == 2 {
		if aceLowIsLowest {
			return 5
		}
		return 2*14 - 1
	}
	return 2 * high
}

// Compare returns > 0 when a wins, < 0 when b wins, 0 on an exact tie.
// Missing score elements compare as 0 (Node: `a.score[i] ?? 0`).
func Compare(a, b EvaluatedHand) int {
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

// Contender is one entrant to PickWinner: Key identifies the player (userId),
// Cards their hand.
type Contender struct {
	Key   string
	Cards []Card
}

// WinnerPick is PickWinner's answer.
type WinnerPick struct {
	Key    string
	Hand   EvaluatedHand
	WasTie bool // more than one contender had the best score
}

// PickWinner chooses the single winner of a showdown (handRank.js pickWinner).
// Exact ties are broken by tieBreakOrder — a list of keys, EARLIEST wins;
// keys absent from it sort last. Returns nil for no contenders.
//
// NOTE: table.js re-implements this tie loop inline in _resolveShowdown
// (preference = seats sorted by distance from the dealer's left, with the
// show-payer moved to the very end). Keep both consistent; the Table port may
// call PickWinner with that preference list instead of duplicating it, as long
// as the result is identical.
func PickWinner(contenders []Contender, tieBreakOrder []string, opts EvaluateOptions) *WinnerPick {
	if len(contenders) == 0 {
		return nil
	}

	type scored struct {
		key  string
		hand EvaluatedHand
	}
	entries := make([]scored, len(contenders))
	for i, entry := range contenders {
		entries[i] = scored{key: entry.Key, hand: Evaluate(entry.Cards, opts)}
	}

	best := entries[0]
	tied := []scored{best}
	for _, candidate := range entries[1:] {
		diff := Compare(candidate.hand, best.hand)
		if diff > 0 {
			best = candidate
			tied = []scored{candidate}
		} else if diff == 0 {
			tied = append(tied, candidate)
		}
	}

	if len(tied) > 1 {
		// Earliest in tieBreakOrder wins; keys absent from it sort last and,
		// among themselves, keep contender order (V8's Array.prototype.sort is
		// stable, hence SliceStable).
		rank := func(key string) int {
			for i, k := range tieBreakOrder {
				if k == key {
					return i
				}
			}
			return int(^uint(0) >> 1)
		}
		sort.SliceStable(tied, func(x, y int) bool {
			return rank(tied[x].key) < rank(tied[y].key)
		})
		best = tied[0]
	}

	return &WinnerPick{Key: best.key, Hand: best.hand, WasTie: len(tied) > 1}
}
