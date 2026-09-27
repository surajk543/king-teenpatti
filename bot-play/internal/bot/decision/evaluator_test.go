package decision

import (
	"math"
	"testing"

	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
)

func pct(cards ...string) float64 {
	h, err := Rank(cards)
	if err != nil {
		panic(err)
	}
	return Percentile(h)
}

func TestEvaluateOnASeenOrBlindTableIsTheClassicRanking(t *testing.T) {
	for _, cat := range []string{protocol.CategorySeen, protocol.CategoryBlind, ""} {
		e := Evaluate(cat, "", &protocol.You{Cards: []string{"As", "Ad", "7c"}})
		want := pct("As", "Ad", "7c")
		if !e.Known || e.Source != SourceClassic || e.Strength != want || e.Confidence != 1 {
			t.Fatalf("%s table: %+v, want strength %v", cat, e, want)
		}
		if e.Category != protocol.HandPair || e.Name != "Pair" || e.Rank != int(want*999) || !e.Playable {
			t.Fatalf("%s table: %+v", cat, e)
		}
	}
	if e := Evaluate(protocol.CategorySeen, "", &protocol.You{Cards: []string{"2s", "4d", "7c"}}); e.Playable || e.Strength > 0.05 {
		t.Fatalf("seven high: %+v", e)
	}
}

func TestEvaluateKnowsNothingWhileBlind(t *testing.T) {
	cases := []*protocol.You{
		nil,
		{IsBlind: true},
		{IsBlind: true, Cards: []string{"As", "Ad", "Ah"}},
		{Cards: nil},
		{Cards: []string{"As", "Ad"}},
		{Cards: []string{"As", "Ad", "Xx"}},
	}
	for _, you := range cases {
		if e := Evaluate(protocol.CategorySeen, "", you); e.Known || e.Source != SourceNone || e.Strength != 0 {
			t.Errorf("%+v: %+v", you, e)
		}
	}
}

func TestEvaluateOnAVariationTableUsesTheServersHand(t *testing.T) {
	cards := []string{"Kd", "4s", "9c"}
	// Nothing until the variation is chosen and you.hand is there.
	for _, tc := range []struct {
		variation string
		hand      *protocol.YouHand
	}{
		{"", &protocol.YouHand{HandName: "Trail", Category: 5}},
		{protocol.VariationAK47, nil},
		{protocol.VariationFiveCard, &protocol.YouHand{Picking: true}},
	} {
		if e := Evaluate(protocol.CategoryVariation, tc.variation, &protocol.You{Cards: cards, Hand: tc.hand}); e.Known {
			t.Errorf("%q %+v: %+v", tc.variation, tc.hand, e)
		}
	}
	// AK47: the K and the 4 are wild and stood for two nines — a trail of
	// nines, as the server counted it.
	you := &protocol.You{Cards: cards, Hand: &protocol.YouHand{
		HandName: "Trail", Category: protocol.HandTrail,
		Wild: []string{"Kd", "4s"}, PlaysAs: []string{"9s", "9h", "9c"}, Best: cards,
	}}
	e := Evaluate(protocol.CategoryVariation, protocol.VariationAK47, you)
	if !e.Known || e.Source != SourceServer || e.Category != protocol.HandTrail || e.Name != "Trail" {
		t.Fatalf("AK47 trail: %+v", e)
	}
	// Under AK47 a quarter of hands are trails, so a trail of nines beats far
	// fewer than it would on a classic table — and the estimate says it is one.
	if classic := pct("9s", "9h", "9c"); e.Strength >= classic-0.05 || e.Strength < 0.75 {
		t.Fatalf("AK47 trail of nines: strength %.3f (classic %.4f)", e.Strength, classic)
	}
	if e.Confidence >= 1 || e.Confidence < 0.5 {
		t.Fatalf("AK47 confidence %.2f", e.Confidence)
	}
	// With no wild card the counted three are the cards themselves.
	plain := &protocol.You{Cards: []string{"Qs", "Js", "9d"}, Hand: &protocol.YouHand{
		HandName: "High Card", Category: protocol.HandHighCard, Wild: []string{}, PlaysAs: []string{}, Best: []string{"Qs", "Js", "9d"},
	}}
	j := Evaluate(protocol.CategoryVariation, protocol.VariationJoker, plain)
	if want := readThrough(mustTable(protocol.VariationJoker), pct("Qs", "Js", "9d")); !j.Known || j.Strength != want {
		t.Fatalf("Joker queen high: %+v, want %.4f", j, want)
	}
	if j.Strength >= pct("Qs", "Js", "9d") {
		t.Fatalf("a queen high is weaker where cards are wild: %.3f", j.Strength)
	}
}

func mustTable(v string) variationTable {
	t, ok := variationTableFor(v)
	if !ok {
		panic(v)
	}
	return t
}

// Muflis turns the ranking the other way up, exactly: the lowest hand wins.
func TestMuflisIsTheClassicRankingUpsideDown(t *testing.T) {
	muflis := func(cards ...string) HandEvaluation {
		h, _ := Rank(cards)
		return Evaluate(protocol.CategoryVariation, protocol.VariationMuflis, &protocol.You{Cards: cards, Hand: &protocol.YouHand{
			HandName: h.Name, Category: h.Category, Best: cards,
		}})
	}
	best := muflis("5s", "3d", "2h") // the best Muflis hand there is
	worst := muflis("As", "Ad", "Ah")
	if best.Strength < 0.99 || !best.Playable {
		t.Fatalf("5-3-2 off-suit under Muflis: %+v", best)
	}
	if worst.Strength > 0.01 || worst.Playable {
		t.Fatalf("a trail of aces under Muflis: %+v", worst)
	}
	for _, cards := range [][]string{{"Ks", "Qd", "7c"}, {"7s", "7d", "Kc"}, {"4h", "5h", "6h"}} {
		e := muflis(cards...)
		if want := 1 - pct(cards...); math.Abs(e.Strength-want) > 1e-12 {
			t.Errorf("%v: Muflis strength %.4f, want 1 − %.4f", cards, e.Strength, pct(cards...))
		}
		if e.Category != Evaluate(protocol.CategorySeen, "", &protocol.You{Cards: cards}).Category {
			t.Errorf("%v: the category is the server's classic one", cards)
		}
	}
	if best.Confidence < 0.9 {
		t.Fatalf("Muflis is exact: confidence %.2f", best.Confidence)
	}
}

// FIVE_CARD: the three the player chose, ranked classically, against
// everybody else's best three of five.
func TestFiveCardRanksTheChosenThreeAgainstBestOfFive(t *testing.T) {
	cards := []string{"As", "Ad", "7c", "4h", "Jd"}
	you := &protocol.You{Cards: cards, Hand: &protocol.YouHand{
		HandName: "Pair", Category: protocol.HandPair, Best: []string{"As", "Ad", "Jd"}, PickedBy: "PLAYER",
	}}
	e := Evaluate(protocol.CategoryVariation, protocol.VariationFiveCard, you)
	classic := pct("As", "Ad", "Jd")
	if !e.Known || e.Strength >= classic-0.3 {
		t.Fatalf("a pair of aces of five: %+v (classic %.3f)", e, classic)
	}
	// A sequence of five is worth less than of three, but still a good hand.
	seq := Evaluate(protocol.CategoryVariation, protocol.VariationFiveCard, &protocol.You{Cards: cards, Hand: &protocol.YouHand{
		HandName: "Sequence", Category: protocol.HandSequence, Best: []string{"9s", "Td", "Jc"},
	}})
	if seq.Strength <= e.Strength || seq.Strength < 0.7 {
		t.Fatalf("a sequence under 5-Card: %.3f, a pair of aces %.3f", seq.Strength, e.Strength)
	}
	// While choosing: unknown.
	you.Hand.Picking, you.Hand.HandName, you.Hand.Best = true, "", nil
	if e := Evaluate(protocol.CategoryVariation, protocol.VariationFiveCard, you); e.Known {
		t.Fatalf("while picking: %+v", e)
	}
}

func TestAHandKnownOnlyByItsCategoryIsPlacedInItsMiddle(t *testing.T) {
	you := &protocol.You{Cards: []string{"As", "Ad", "7c", "4h", "Jd"}, Hand: &protocol.YouHand{HandName: "Color", Category: protocol.HandColor}}
	e := Evaluate(protocol.CategoryVariation, protocol.VariationHukam, you)
	if !e.Known || e.Confidence >= variationConfidence(protocol.VariationHukam) {
		t.Fatalf("%+v", e)
	}
	if want := readThrough(mustTable(protocol.VariationHukam), categoryMidpoint(protocol.HandColor)); e.Strength != want {
		t.Fatalf("strength %.4f, want %.4f", e.Strength, want)
	}
}

func TestAnUnknownVariationFallsBackToTheClassicPercentile(t *testing.T) {
	cards := []string{"Ks", "Qd", "7c"}
	e := Evaluate(protocol.CategoryVariation, "SEVEN_CARD", &protocol.You{Cards: cards, Hand: &protocol.YouHand{HandName: "High Card", Best: cards}})
	if !e.Known || e.Strength != pct(cards...) || e.Confidence > 0.5 {
		t.Fatalf("%+v", e)
	}
}

// The tables are cumulative shares: from 0 to 1 and never falling, so a
// better counted hand never reads as a weaker one.
func TestEveryVariationTableIsACumulativeShare(t *testing.T) {
	k := variationKnots()
	for i := 1; i < knotCount; i++ {
		if k[i] <= k[i-1] {
			t.Fatalf("knots not rising at %d", i)
		}
	}
	for _, v := range []string{protocol.VariationAK47, protocol.VariationJoker, protocol.VariationHukam, protocol.VariationLowestJoker, protocol.VariationHighestJoker, protocol.VariationFiveCard} {
		tab := mustTable(v)
		if tab[0] != 0 || tab[knotCount-1] != 1 {
			t.Errorf("%s runs %v..%v", v, tab[0], tab[knotCount-1])
		}
		prev := -1.0
		for x := 0.0; x <= 1.0; x += 0.0005 {
			s := readThrough(tab, x)
			if s < prev-1e-12 || s < 0 || s > 1 {
				t.Fatalf("%s falls or leaves 0..1 at %.4f: %.4f after %.4f", v, x, s, prev)
			}
			prev = s
		}
	}
	if _, ok := variationTableFor(protocol.VariationMuflis); ok {
		t.Fatal("Muflis has no table: it is exact")
	}
	// Where no card is wild the table would be the identity: the knots are
	// the classic shares of hands below them.
	var all []float64
	for _, combo := range Combinations3(Deck()) {
		all = append(all, pct(combo...))
	}
	for i, x := range k {
		below := 0
		for _, p := range all {
			if p < x {
				below++
			}
		}
		if got := float64(below) / 22100; math.Abs(got-x) > 0.006 {
			t.Errorf("knot %d (%.6f): %.4f of classic hands lie below it", i, x, got)
		}
	}
}

func TestStrengthRankAndPlayableAgree(t *testing.T) {
	for _, combo := range Combinations3(Deck())[:3000] {
		e := Evaluate(protocol.CategorySeen, "", &protocol.You{Cards: combo})
		if e.Rank != int(e.Strength*999) || e.Playable != (e.Strength >= PlayableBar) || e.Rank < 0 || e.Rank > 999 {
			t.Fatalf("%v: %+v", combo, e)
		}
	}
}
