package strategy

import (
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/decision"
	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// ChooseVariation picks the hand's variation from the options the SERVER
// offered this hand (never a list of its own: FIVE_CARD is absent when the
// deck cannot cover the top-up). ok is false when there is nothing to pick,
// or when the bot lets the window lapse (the server then picks Muflis).
//
// It lapses at its Distracted rate (1–9%): someone who looked away is a real
// thing at a table, and the only way the server's timeout is ever exercised
// in production — rare, or a table would play Muflis all evening. Otherwise
// each offered variation is weighted by variationAppetite, kept mild (1 to
// about 2.2) so a table sees all seven over an evening rather than one per
// seat. Values the server offers that this build does not know are weighted
// 1, like any other.
func ChooseVariation(options []string, p Personality, r *rng.Rand) (choice string, ok bool) {
	menu := make([]string, 0, len(options))
	for _, v := range options {
		if v != "" {
			menu = append(menu, v)
		}
	}
	if len(menu) == 0 {
		return "", false
	}
	if r.Chance(p.Distracted) {
		return "", false
	}
	weights := make([]float64, len(menu))
	for i, v := range menu {
		weights[i] = variationAppetite(v, p)
	}
	return menu[r.Weighted(weights)], true
}

// variationAppetite is how much a personality fancies a variation (the Node
// fleet's, kept): Muflis turns junk into gold, so a loose player is at home
// there and a rock is not; wild cards mean bigger hands and bigger pots,
// which the aggressive like; five cards is simply the one most people enjoy
// most.
func variationAppetite(variation string, p Personality) float64 {
	switch variation {
	case protocol.VariationMuflis:
		return 1 + (1-clamp01(p.Tightness))*1.2
	case protocol.VariationAK47, protocol.VariationJoker, protocol.VariationHukam:
		return 1 + clamp01(p.Aggression)*1.2
	case protocol.VariationLowestJoker, protocol.VariationHighestJoker:
		return 1 + clamp01(p.Aggression)*0.6
	case protocol.VariationFiveCard:
		return 1.4
	}
	return 1
}

// ChoosePlayedCards picks three of the five cards held under FIVE_CARD, in
// the order held — usually the best three, now and then not (a player
// glancing at five cards misses the flush). nil means let the window lapse
// (the server then plays the first three dealt).
//
// It lapses at half its Distracted rate. It slips — plays another three —
// at 0.03 + 0.06 × Aggression + 0.5 × Mistake (about 4–5% for a careful
// player, 5–9% for an aggressive one, 9–16% for a beginner), and a slip is
// usually a near miss: the other combinations are weighted by how strong
// they are, so the obvious pair is taken over the flush more often than a
// jumble is. The best three are decision.BestThree's, which names the same
// three as the server's bestPossible. Three cards are returned as they are;
// fewer than three, or anything that is not a card, is a lapse (nil).
func ChoosePlayedCards(cards []string, p Personality, r *rng.Rand) []string {
	if len(cards) < 3 {
		return nil
	}
	if len(cards) == 3 {
		for _, c := range cards {
			if _, _, ok := decision.ParseCard(c); !ok {
				return nil
			}
		}
		return append([]string(nil), cards...)
	}
	best, err := decision.BestThree(cards)
	if err != nil {
		return nil
	}
	if r.Chance(p.Distracted * 0.5) {
		return nil
	}
	slip := 0.03 + 0.06*clamp01(p.Aggression) + 0.5*clamp01(p.Mistake)
	if r.Chance(slip) {
		var others [][]string
		var weights []float64
		for _, combo := range decision.Combinations3(cards) {
			h, _ := decision.Rank(combo)
			if decision.Compare(h, best) == 0 && sameCards(combo, best.Cards) {
				continue
			}
			pct := decision.Percentile(h)
			others = append(others, combo)
			weights = append(weights, (0.05+pct)*(0.05+pct))
		}
		if len(others) > 0 {
			return others[r.Weighted(weights)]
		}
	}
	return append([]string(nil), best.Cards...)
}

func sameCards(a, b []string) bool {
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
