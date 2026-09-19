package poker

import (
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// 3-Card Poker's ranking is Teen Patti's with two differences, and nothing
// else: the top two categories are the other way round (Straight Flush beats
// Three of a Kind, where Teen Patti's Trail beats its Pure Sequence), and the
// wheel A-2-3 is the LOWEST straight rather than the second highest. The
// second is exactly game.EvaluateOptions{AceLowIsLowest: true}, a switch
// Teen Patti's evaluator has always carried and no production caller ever set
// (POKER_PLAN.md §3); the first is a permutation of the category number. So
// Evaluate3 is a mapping over game.Evaluate — the 22,100-hand proofs of that
// evaluator carry over, and every tiebreak (pair + kicker, three high cards,
// the doubled run scale) is inherited untouched.

// Three-card categories, weakest first; the numbers are Hand.Score[0].
const (
	HighCard3      = 0
	Pair3          = 1
	Flush3         = 2
	Straight3      = 3
	ThreeOfAKind3  = 4
	StraightFlush3 = 5
)

// CategoryNames3 are the wire hand names of 3-Card Poker.
var CategoryNames3 = [...]string{
	HighCard3: "High Card", Pair3: "Pair", Flush3: "Flush", Straight3: "Straight",
	ThreeOfAKind3: "Three of a Kind", StraightFlush3: "Straight Flush",
}

// threeCardCategory maps a Teen Patti category onto 3-Card Poker's.
var threeCardCategory = map[game.HandCategory]int{
	game.HighCard:     HighCard3,
	game.Pair:         Pair3,
	game.Color:        Flush3,
	game.Sequence:     Straight3,
	game.PureSequence: StraightFlush3,
	game.Trail:        ThreeOfAKind3,
}

// Evaluate3 scores exactly three cards under 3-Card Poker's ranking.
func Evaluate3(cards []game.Card) Hand {
	tp := game.Evaluate(cards, game.EvaluateOptions{AceLowIsLowest: true})
	category := threeCardCategory[tp.Category]
	score := append([]int{category}, tp.Score[1:]...)
	codes := game.CardCodes(cards)
	return Hand{Category: category, Name: CategoryNames3[category], Score: score, Cards: codes, Best: append([]string(nil), codes...)}
}

// DealerQualifyRank is the high card a dealer's hand needs to play: a queen.
const DealerQualifyRank = 12

// DealerQualifies reports whether the house plays this hand: queen-high or
// better. Anything above a high card qualifies; a high card qualifies when
// its highest card is a queen or better.
func DealerQualifies(h Hand) bool {
	if h.Category > HighCard3 {
		return true
	}
	return len(h.Score) > 1 && h.Score[1] >= DealerQualifyRank
}
