// Package decision is the arithmetic under a bot's choices: how strong its
// hand is (as the server ranks it — see hand_strength.go), how much pressure
// the table is putting on it, the pot odds, which rung of the ladder a raise
// should name, and how much of the stack a move risks. No personality lives
// here; strategy weighs these numbers by one.
package decision

import "github.com/surajk543/king-teenpatti/bot-play/internal/protocol"

// PlayableBar is the Strength at and above which a hand is Playable: the top
// 55% of hands, which on a classic table is a middling king-high or better —
// worth a chaal at a fair price with no other reason to stay.
const PlayableBar = 0.45

// Where a HandEvaluation's figures came from.
const (
	SourceClassic = "classic" // this package's copy of the classic ranking, on the viewer's own cards
	SourceServer  = "server"  // the server's own evaluation of a variation hand (you.hand)
	SourceNone    = "none"    // nothing known: blind, or no evaluation yet
)

// HandEvaluation is a bot's hand normalised for the decision layer (brief
// §16), whatever the table's rules: Strength is always "higher is better
// under THIS hand's rules" — under Muflis a low hand is strong.
type HandEvaluation struct {
	Known      bool    // false while blind (or while a 5-Card pick is pending)
	Category   int     // protocol.Hand* as the rules counted it
	Name       string  // the server's hand name, e.g. "Pure Sequence"
	Strength   float64 // 0..1, the share of hands this one beats under these rules
	Rank       int     // 0..999: Strength on a coarse integer scale, for logs
	Playable   bool    // worth staying in for with no other reason
	Confidence float64 // 0..1: how sure the estimate is (lower with wild cards or while picking)
	Source     string  // "classic" (our copy of the ranking), "server" (you.hand), "none"
}

// Evaluate reads the viewer's hand from the snapshot: the classic ranking
// of you.cards on seen and blind tables, and on a variation table the
// server's own evaluation (you.hand), with Muflis turned the other way up.
// Unknown (Known false) while blind, while you.hand is absent, or while a
// 5-Card pick is pending. variation is the hand's chosen variation or "".
//
// On a variation table the counted three are you.hand.playsAs when a wild
// card played (the hand as the server counted it), else you.hand.best (the
// three that play — the chosen three under 5-Card), else you.cards. Those
// three are ranked classically and the classic percentile is:
//
//   - MUFLIS: turned the other way up, 1 − percentile (exact: no card is wild
//     and the lowest hand wins);
//   - FIVE_CARD: read through the distribution of best-three-of-five hands,
//     since every other player also plays their best three of five;
//   - AK47, JOKER, HUKAM, LOWEST_JOKER, HIGHEST_JOKER: read through that
//     variation's distribution of counted hands (variation_tables.go), with a
//     lower Confidence — an offline approximation, never the wild-card rules;
//   - a variation this build does not know: the classic percentile itself,
//     Confidence 0.4.
//
// When the counted three cannot be read the server's category alone places
// the hand (the middle of that category), at a lower Confidence still. A
// variation table with no variation chosen yet ("") is unknown: the rules
// that would rank the hand are not known.
func Evaluate(category, variation string, you *protocol.You) HandEvaluation {
	if you == nil || you.IsBlind {
		return unknownHand()
	}
	if category == protocol.CategoryVariation {
		return evaluateVariation(variation, you)
	}
	if len(you.Cards) != 3 {
		return unknownHand()
	}
	h, err := Rank(you.Cards)
	if err != nil {
		return unknownHand()
	}
	return evaluation(h.Category, h.Name, Percentile(h), 1, SourceClassic)
}

func evaluateVariation(variation string, you *protocol.You) HandEvaluation {
	hand := you.Hand
	if variation == "" || hand == nil || hand.Picking {
		return unknownHand()
	}
	name := hand.HandName
	if name == "" && hand.Category >= 0 && hand.Category < len(CategoryNames) {
		name = CategoryNames[hand.Category]
	}
	confidence := variationConfidence(variation)

	pct, read := 0.0, false
	if counted := countedThree(you); counted != nil {
		if h, err := Rank(counted); err == nil {
			pct, read = Percentile(h), true
		}
	}
	if !read {
		pct = categoryMidpoint(hand.Category)
		confidence *= 0.6
	}

	var strength float64
	switch variation {
	case protocol.VariationMuflis:
		strength = 1 - pct
	default:
		if t, ok := variationTableFor(variation); ok {
			strength = readThrough(t, pct)
		} else {
			strength = pct
		}
	}
	return evaluation(hand.Category, name, strength, confidence, SourceServer)
}

// countedThree is the three cards the server counted, as a classic hand:
// playsAs (wild cards as the cards they stood for), else best, else the
// cards themselves when there are exactly three. nil when none is usable.
func countedThree(you *protocol.You) []string {
	h := you.Hand
	for _, cards := range [][]string{h.PlaysAs, h.Best, you.Cards} {
		if len(cards) == 3 {
			return cards
		}
	}
	return nil
}

func evaluation(category int, name string, strength, confidence float64, source string) HandEvaluation {
	strength = clamp01(strength)
	return HandEvaluation{
		Known:      true,
		Category:   category,
		Name:       name,
		Strength:   strength,
		Rank:       int(strength * 999),
		Playable:   strength >= PlayableBar,
		Confidence: clamp01(confidence),
		Source:     source,
	}
}

func unknownHand() HandEvaluation { return HandEvaluation{Source: SourceNone} }

func clamp01(x float64) float64 { return clamp(x, 0, 1) }

func clamp(x, lo, hi float64) float64 {
	if x < lo {
		return lo
	}
	if x > hi {
		return hi
	}
	return x
}
