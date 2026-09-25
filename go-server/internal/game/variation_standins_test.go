package game

import "testing"

// Three wild cards make a trail of aces, and what each card is shown standing
// for must be a hand that could exist: a held ace stands for itself, and no card
// stands for another card of the same hand (26 Sep 2026: A♥ K♠ 4♣ under AK47
// showed the K♠ as the A♥ the player held, while the A♥ played as A♠ — the
// parity suite's "a stand-in is not another card of the same hand", which only
// a deal of three AK47 cards could trip). Every such hand, exhaustively.
func TestThreeWildCardsStandForAcesTheHandDoesNotHoldOrForThemselves(t *testing.T) {
	rules := VariationRules{Variation: VariationAK47}
	wildRank := map[int]bool{14: true, 13: true, 4: true, 7: true}
	var deck []Card
	for _, c := range NewDeck() {
		if wildRank[c.Rank] {
			deck = append(deck, c)
		}
	}
	checked := 0
	for i := 0; i < len(deck); i++ {
		for j := i + 1; j < len(deck); j++ {
			for k := j + 1; k < len(deck); k++ {
				cards := []Card{deck[i], deck[j], deck[k]}
				hand := rules.EvaluateHand(cards)
				if len(hand.Wild) != 3 {
					t.Fatalf("%v: %d wild cards, want 3", CardCodes(cards), len(hand.Wild))
				}
				if hand.Category != Trail {
					t.Fatalf("%v: %s, want a trail", CardCodes(cards), hand.Name)
				}
				held := map[string]bool{}
				for _, c := range cards {
					held[c.Code()] = true
				}
				seen := map[string]bool{}
				for n, stood := range hand.PlaysAs {
					own := cards[n].Code()
					if ParseCard(stood).Rank != 14 {
						t.Fatalf("%v plays as %v: %s is not an ace", CardCodes(cards), hand.PlaysAs, stood)
					}
					if seen[stood] {
						t.Fatalf("%v plays as %v: %s twice", CardCodes(cards), hand.PlaysAs, stood)
					}
					seen[stood] = true
					if held[stood] && stood != own {
						t.Fatalf("%v plays as %v: %s stands for %s, another card of the same hand", CardCodes(cards), hand.PlaysAs, own, stood)
					}
					if cards[n].Rank == 14 && stood != own {
						t.Fatalf("%v plays as %v: the ace %s does not stand for itself", CardCodes(cards), hand.PlaysAs, own)
					}
				}
				checked++
			}
		}
	}
	if checked != 560 { // C(16,3): every hand of three aces, kings, fours or sevens
		t.Fatalf("checked %d hands, want 560", checked)
	}
}
