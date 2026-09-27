package strategy

import (
	"math"
	"testing"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/decision"
	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// allVariations is the server's menu, FIVE_CARD last.
var allVariations = []string{
	protocol.VariationMuflis, protocol.VariationAK47, protocol.VariationJoker, protocol.VariationHukam,
	protocol.VariationLowestJoker, protocol.VariationHighestJoker, protocol.VariationFiveCard,
}

func TestAVariationIsChosenOnlyFromWhatTheServerOffered(t *testing.T) {
	r := rng.New(1)
	sixOnly := allVariations[:6] // the deck could not cover the top-up: no FIVE_CARD
	for _, kind := range Kinds {
		p := median(kind)
		for i := 0; i < 2000; i++ {
			v, ok := ChooseVariation(sixOnly, p, r)
			if !ok {
				continue
			}
			if v == protocol.VariationFiveCard {
				t.Fatalf("%s chose FIVE_CARD, which was not offered", kind)
			}
			found := false
			for _, o := range sixOnly {
				found = found || o == v
			}
			if !found {
				t.Fatalf("%s chose %q", kind, v)
			}
		}
		if v, ok := ChooseVariation([]string{"", protocol.VariationHukam, ""}, p, rng.New(3)); ok && v != protocol.VariationHukam {
			t.Fatalf("%s chose %q from a menu of Hukam", kind, v)
		}
	}
	for _, menu := range [][]string{nil, {}, {""}} {
		if v, ok := ChooseVariation(menu, median(Balanced), r); ok || v != "" {
			t.Fatalf("chose %q from %q", v, menu)
		}
	}
	// A value this build does not know is still the server's to offer.
	if v, ok := ChooseVariation([]string{"SEVEN_CARD"}, median(Balanced), rng.New(4)); !ok || v != "SEVEN_CARD" {
		t.Fatalf("got %q %v", v, ok)
	}
}

func TestTheVariationWindowLapsesAtTheDistractedRate(t *testing.T) {
	for _, kind := range Kinds {
		p := median(kind)
		r := rng.New(5)
		lapsed := 0
		const n = 20000
		for i := 0; i < n; i++ {
			if _, ok := ChooseVariation(allVariations, p, r); !ok {
				lapsed++
			}
		}
		if got := float64(lapsed) / n; math.Abs(got-p.Distracted) > 0.01 {
			t.Errorf("%s lapsed %.3f of windows, Distracted is %.3f", kind, got, p.Distracted)
		}
	}
}

// Every family calls every variation now and then, and the leanings are
// mild: a loose player calls Muflis more than a rock, an aggressive one the
// wild cards more than a careful one.
func TestVariationLeaningsAreMild(t *testing.T) {
	share := func(p Personality) map[string]float64 {
		r := rng.New(6)
		counts := map[string]float64{}
		n := 0.0
		for i := 0; i < 30000; i++ {
			if v, ok := ChooseVariation(allVariations, p, r); ok {
				counts[v]++
				n++
			}
		}
		for k := range counts {
			counts[k] /= n
		}
		return counts
	}
	shares := map[Kind]map[string]float64{}
	for _, kind := range Kinds {
		shares[kind] = share(median(kind))
		for _, v := range allVariations {
			if s := shares[kind][v]; s < 0.07 || s > 0.25 {
				t.Errorf("%s calls %s %.3f of the time", kind, v, s)
			}
		}
	}
	if shares[Loose][protocol.VariationMuflis] <= shares[Cautious][protocol.VariationMuflis] {
		t.Errorf("Muflis: loose %.3f, cautious %.3f", shares[Loose][protocol.VariationMuflis], shares[Cautious][protocol.VariationMuflis])
	}
	if shares[Aggressive][protocol.VariationAK47] <= shares[Cautious][protocol.VariationAK47] {
		t.Errorf("AK47: aggressive %.3f, cautious %.3f", shares[Aggressive][protocol.VariationAK47], shares[Cautious][protocol.VariationAK47])
	}
}

// isHeldOrder is whether picked are three distinct cards of held, in the
// order held.
func isHeldOrder(picked, held []string) bool {
	if len(picked) != 3 {
		return false
	}
	j := 0
	for _, c := range held {
		if j < 3 && picked[j] == c {
			j++
		}
	}
	return j == 3
}

func TestTheFiveCardPickIsUsuallyTheBestThree(t *testing.T) {
	slips := map[Kind]float64{}
	for _, kind := range Kinds {
		p := median(kind)
		r := rng.New(7)
		deal := rng.New(8)
		best, picked, lapsed := 0, 0, 0
		for i := 0; i < 4000; i++ {
			d := decision.Deck()
			for k := len(d) - 1; k > 0; k-- {
				j := deal.IntN(k + 1)
				d[k], d[j] = d[j], d[k]
			}
			cards := d[:5]
			got := ChoosePlayedCards(cards, p, r)
			if got == nil {
				lapsed++
				continue
			}
			picked++
			if !isHeldOrder(got, cards) {
				t.Fatalf("%s picked %v from %v: not three held cards in the order held", kind, got, cards)
			}
			want, _ := decision.BestThree(cards)
			if sameCards(got, want.Cards) {
				best++
			}
		}
		share := float64(best) / float64(picked)
		slips[kind] = 1 - share
		if share < 0.85 {
			t.Errorf("%s played the best three only %.3f of the time", kind, share)
		}
		if l := float64(lapsed) / 4000; l > p.Distracted*0.5+0.01 {
			t.Errorf("%s let %.3f of picks lapse", kind, l)
		}
	}
	if slips[Beginner] <= slips[Cautious] || slips[Aggressive] <= slips[Cautious] {
		t.Errorf("slip rates: %v", slips)
	}
	if slips[Cautious] == 0 {
		t.Errorf("a careful player never slipped: a fleet that always finds the optimum is a tell")
	}
}

func TestTheFiveCardPickOfThreeOrFewerCards(t *testing.T) {
	p := median(Balanced)
	if got := ChoosePlayedCards([]string{"As", "Kd", "2c"}, p, rng.New(1)); !sameCards(got, []string{"As", "Kd", "2c"}) {
		t.Fatalf("three cards picked as %v", got)
	}
	for _, bad := range [][]string{nil, {"As", "Kd"}, {"As", "Kd", "zz"}, {"As", "Kd", "zz", "2c", "3c"}} {
		if got := ChoosePlayedCards(bad, p, rng.New(1)); got != nil {
			t.Fatalf("%v picked as %v", bad, got)
		}
	}
	// The pick is the server's own bestPossible: of two equally strong threes
	// the first in held order.
	// Kd Ks 9c and Kd Ks 9h are the same pair of kings, nine kicker.
	cards := []string{"Kd", "Ks", "9c", "9h", "3d"}
	careful := p
	careful.Distracted, careful.Mistake, careful.Aggression = 0, 0, 0
	r := rng.From(&rng.Script{Values: []float64{0.99}})
	if got := ChoosePlayedCards(cards, careful, r); !sameCards(got, []string{"Kd", "Ks", "9c"}) {
		t.Fatalf("picked %v", got)
	}
	// A slip is another three, still held cards in the order held.
	slipper := careful
	slipper.Mistake = 1
	if got := ChoosePlayedCards(cards, slipper, rng.From(&rng.Script{Values: []float64{0, 0.5}})); sameCards(got, []string{"Kd", "Ks", "9c"}) || !isHeldOrder(got, cards) {
		t.Fatalf("a slip picked %v", got)
	}
}

func TestSideshowAnswers(t *testing.T) {
	strong := hand("As", "Ad", "Kc")
	weak := hand("2s", "4d", "7c")
	for _, kind := range Kinds {
		p := median(kind)
		r := rng.New(9)
		lapses, strongYes, weakYes, blindYes, answered := 0, 0, 0, 0, 0
		const n = 6000
		for i := 0; i < n; i++ {
			ctx := seenCtx(p, strong, 3, decision.Pressure{})
			answer, accept := SideshowAnswer(ctx, r)
			if !answer {
				lapses++
				continue
			}
			answered++
			if accept {
				strongYes++
			}
			if _, a := SideshowAnswer(seenCtx(p, weak, 3, decision.Pressure{}), rng.New(uint64(i))); a {
				weakYes++
			}
			ctx.Hand = decision.HandEvaluation{}
			if _, a := SideshowAnswer(ctx, rng.New(uint64(i)+n)); a {
				blindYes++
			}
		}
		if l := float64(lapses) / n; l < 0.05 || l > 0.1 {
			t.Errorf("%s let %.3f of asks lapse", kind, l)
		}
		if s := float64(strongYes) / float64(answered); s < 0.7 {
			t.Errorf("%s accepted with a pair of aces %.3f of the time", kind, s)
		}
		if w := float64(weakYes) / float64(answered); w > 0.35 {
			t.Errorf("%s accepted with seven high %.3f of the time", kind, w)
		}
		if b := float64(blindYes) / float64(answered); b < 0.3 || b > 0.7 {
			t.Errorf("%s accepted with no hand known %.3f of the time", kind, b)
		}
	}
}
