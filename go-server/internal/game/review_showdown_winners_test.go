package game

// Review (24 Sep 2026): WHO WINS at the table. The owner reported "in
// variation gameplay a player with a PAIR is showing Trail and winning". Under
// every variation but Muflis and 5-Card some cards are WILD, and a natural pair
// plus a wild card IS a trail by design (§6.4). What is audited here, with
// deterministic cards through the setCards seam, is whether the engine ever
// gets a hand's WORTH or the WINNER wrong on a seen, a blind or a variation
// table — the show, the forced showdowns, the sideshow — and whether the
// reveals say what the hand MADE and exactly which cards were wild.
//
// Every variation outcome is checked against an ORACLE written here from the
// rules alone (brute force over the whole deck for the wild cards; the classic
// direction reversed for Muflis), which shares nothing with
// evaluateWithWilds/bestCompletion but the one classic Evaluate/Compare that
// handrank_test.go and the Node interop test pin.

import (
	"fmt"
	"math/rand"
	"sort"
	"strings"
	"testing"
	"time"
)

// ------------------------------------------------------------------ oracle

// winnerOracleWildRule is which cards a variation makes wild, from the rules alone.
func winnerOracleWildRule(v Variation, turnUp Card, cards []Card) func(Card) bool {
	switch v {
	case VariationAK47:
		return func(c Card) bool { return c.Rank == 14 || c.Rank == 13 || c.Rank == 4 || c.Rank == 7 }
	case VariationJoker:
		return func(c Card) bool { return c.Rank == turnUp.Rank }
	case VariationHukam:
		return func(c Card) bool { return c.Suit == turnUp.Suit }
	case VariationLowestJoker:
		lo := cards[0].Rank
		for _, c := range cards {
			if c.Rank < lo {
				lo = c.Rank
			}
		}
		return func(c Card) bool { return c.Rank == lo }
	case VariationHighestJoker:
		hi := cards[0].Rank
		for _, c := range cards {
			if c.Rank > hi {
				hi = c.Rank
			}
		}
		return func(c Card) bool { return c.Rank == hi }
	}
	return nil
}

// winnerOracleEvaluate is what a three-card hand is worth under v: the strongest
// classic hand its naturals plus ANY stand-ins for its wild cards can make
// (every card of the deck that is not a natural of the hand, no two wilds on
// the same card), found by walking every combination.
func winnerOracleEvaluate(v Variation, turnUp Card, cards []Card) EvaluatedHand {
	if len(cards) != 3 {
		panic("oracle: three cards")
	}
	isWild := winnerOracleWildRule(v, turnUp, cards)
	if isWild == nil {
		return Evaluate(cards, EvaluateOptions{})
	}
	var naturals []Card
	var wild []string
	for _, c := range cards {
		if isWild(c) {
			wild = append(wild, c.Code())
		} else {
			naturals = append(naturals, c)
		}
	}
	if len(wild) == 0 {
		return Evaluate(cards, EvaluateOptions{})
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
	var best EvaluatedHand
	found := false
	candidate := make([]Card, 3)
	copy(candidate, naturals)
	var walk func(from, slot int)
	walk = func(from, slot int) {
		if slot == 3 {
			scored := Evaluate(candidate, EvaluateOptions{})
			if !found || Compare(scored, best) > 0 {
				best, found = scored, true
			}
			return
		}
		for i := from; i < len(pool); i++ {
			candidate[slot] = pool[i]
			walk(i+1, slot+1)
		}
	}
	walk(0, len(naturals))
	return EvaluatedHand{Category: best.Category, Name: best.Name, Score: best.Score, Cards: CardCodes(cards), Wild: wild}
}

// winnerOracleCompare is > 0 when a wins, < 0 when b wins, 0 on an exact tie.
func winnerOracleCompare(v Variation, a, b EvaluatedHand) int {
	if v == VariationMuflis {
		return Compare(b, a)
	}
	return Compare(a, b)
}

// winnerOracleBest names the best of several hands under v; "" on a tie for best.
func winnerOracleBest(v Variation, turnUp Card, hands map[string][]string) (winner string, tie bool) {
	ids := make([]string, 0, len(hands))
	for id := range hands {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	var best EvaluatedHand
	for i, id := range ids {
		h := winnerOracleEvaluate(v, turnUp, ParseCards(hands[id]))
		if i == 0 {
			best, winner, tie = h, id, false
			continue
		}
		switch d := winnerOracleCompare(v, h, best); {
		case d > 0:
			best, winner, tie = h, id, false
		case d == 0:
			tie = true
		}
	}
	return winner, tie
}

// ------------------------------------------------------------- table helpers

// totalChips is every seated player's stack plus the live pot: what a hand
// must conserve from its deal to its settlement (bookless ledger).
func (h *harness) totalChips() int64 {
	var total int64
	h.read(func() {
		for _, s := range h.table.seats {
			if s != nil {
				total += s.chips
			}
		}
		if h.table.hand != nil {
			total += h.table.hand.pot
		}
	})
	return total
}

// payerOfLastShow is who paid for the show that ended the hand.
func (h *harness) payerOfLastShow() string {
	acts := h.actions()
	for i := len(acts) - 1; i >= 0; i-- {
		if acts[i].Action == ActionShow {
			return acts[i].UserID
		}
	}
	h.t.Fatal("no show was paid for")
	return ""
}

// betUntilOver bets the smallest legal rung for whoever is on turn until the
// table ends the hand by itself (round cap or pot cap).
func (h *harness) betUntilOver() {
	h.t.Helper()
	for i := 0; i < 400 && h.hasHand(); i++ {
		p := h.turnUser()
		steps := h.betOptions(p).Steps
		if len(steps) == 0 {
			h.t.Fatalf("%s is on turn with no legal bet (pot %d)", p, h.pot())
		}
		h.mustAct(p, ActionChaal, amt(steps[0]))
	}
	if h.hasHand() {
		h.t.Fatal("the hand never ended on its own")
	}
}

// revealsOf indexes a hand's reveals.
func revealsOf(reveals []Reveal) map[string]Reveal {
	out := map[string]Reveal{}
	for _, r := range reveals {
		out[r.UserID] = r
	}
	return out
}

// checkWinnerOutcome is the common audit of a finished hand: one reveal per
// contender with Won on exactly the winner, the winner named by userId in
// handEnded, the pot paid to that seat and nobody else, chips conserved.
// `before` is each player's stack as they SAT DOWN, so the boot counts as a
// stake; `total` is the chips at the table (stacks + pot) before the hand ended.
func checkWinnerOutcome(t *testing.T, h *harness, ended HandEndedEvent, before map[string]int64, total int64, contenders []string) {
	t.Helper()
	if ended.WinnerID == nil {
		t.Fatal("handEnded names no winner")
	}
	winner := *ended.WinnerID
	eq(t, len(ended.Reveals), len(contenders), "one reveal per player still in")
	won := 0
	for _, r := range ended.Reveals {
		if r.Won {
			won++
			eq(t, r.UserID, winner, "the reveal marked won is the winner handEnded names")
		}
		if r.HandName != CategoryNames[r.Category] {
			t.Fatalf("%s: handName %q does not match category %d", r.UserID, r.HandName, r.Category)
		}
	}
	eq(t, won, 1, "exactly one reveal is marked won")
	eq(t, h.totalChips(), total, "chips are conserved across the hand")
	eq(t, h.pot(), int64(0), "the pot is empty after the hand")
	for id, start := range before {
		seat := h.mustSeat(id)
		if id == winner {
			if seat.Chips <= start-ended.Pot/int64(len(before)) || seat.Chips > start+ended.Pot {
				t.Fatalf("winner %s: chips %d from %d with pot %d", id, seat.Chips, start, ended.Pot)
			}
		} else if seat.Chips >= start {
			t.Fatalf("loser %s: chips %d did not go down from %d", id, seat.Chips, start)
		}
	}
	// The winner's stack rose by exactly the pot less what they staked; every
	// other stack fell by exactly what it staked; those stakes sum to the pot.
	var staked int64
	for id, start := range before {
		seat := h.mustSeat(id)
		if id == winner {
			staked += start + ended.Pot - seat.Chips
		} else {
			staked += start - seat.Chips
		}
	}
	eq(t, staked, ended.Pot, "what every player staked is exactly the pot the winner took")
}

// winnerTwoPlayerShow deals a and b the given cards on a table of cfg, has both look,
// and lets whoever is on turn pay for a show.
func winnerTwoPlayerShow(t *testing.T, cfg TableConfig, aCards, bCards []string) (h *harness, ended HandEndedEvent, payer string) {
	t.Helper()
	h = newHarness(t, cfg, withLedger(emptyLedger))
	h.seat("a", sideshowStart)
	h.seat("b", sideshowStart)
	h.advance(cfg.NextHandDelay)
	eq(t, h.handNo(), 1, "dealt")
	h.setCards("a", aCards...)
	h.setCards("b", bCards...)
	h.mustAct("a", ActionSee, ActRequest{})
	h.mustAct("b", ActionSee, ActRequest{})
	total := h.totalChips()
	before := map[string]int64{"a": sideshowStart, "b": sideshowStart}
	payer = h.turnUser()
	h.mustAct(payer, ActionShow, ActRequest{})
	ended = h.lastEnded()
	eq(t, ended.Reason, WinShow, "ended by the show")
	checkWinnerOutcome(t, h, ended, before, total, []string{"a", "b"})
	return h, ended, payer
}

// winnerClassicShowCases are the pairings a seen or blind show is audited on; want
// is "a", "b" or "" for an exact tie (the payer must lose).
var winnerClassicShowCases = []struct {
	name string
	a, b []string
	want string
}{
	{"pair beats high card", []string{"9s", "9h", "2c"}, []string{"As", "Kh", "9d"}, "a"},
	{"high card loses to pair", []string{"As", "Kh", "9d"}, []string{"3s", "3h", "2c"}, "b"},
	{"trail beats pure sequence", []string{"2s", "2h", "2d"}, []string{"As", "Ks", "Qs"}, "a"},
	{"pure sequence beats sequence", []string{"4h", "5h", "6h"}, []string{"Ad", "Kh", "Qs"}, "a"},
	{"A-2-3 beats K-Q-J", []string{"Ah", "2s", "3d"}, []string{"Kh", "Qs", "Jd"}, "a"},
	{"A-K-Q beats A-2-3", []string{"Ah", "2s", "3d"}, []string{"Ac", "Kh", "Qd"}, "b"},
	{"K-Q-J beats Q-J-T", []string{"Qh", "Jd", "Ts"}, []string{"Kh", "Qs", "Jc"}, "b"},
	{"sequence beats colour", []string{"As", "Ks", "9s"}, []string{"7h", "8d", "9c"}, "b"},
	{"colour beats pair", []string{"As", "Ah", "Kd"}, []string{"2c", "5c", "9c"}, "b"},
	{"higher pair wins", []string{"Ts", "Th", "Ad"}, []string{"Jc", "Jd", "2h"}, "b"},
	{"same pair, kicker decides", []string{"Ts", "Th", "Ad"}, []string{"Tc", "Td", "Kh"}, "a"},
	{"higher trail wins", []string{"5s", "5h", "5d"}, []string{"4c", "4d", "4h"}, "a"},
	{"exact tie: pair", []string{"Qs", "Qh", "8d"}, []string{"Qd", "Qc", "8s"}, ""},
	{"exact tie: high card, suits never break it", []string{"Ah", "9h", "4h"}, []string{"As", "9s", "4s"}, ""},
	{"exact tie: sequence off-suit v off-suit", []string{"9h", "8s", "7d"}, []string{"9c", "8d", "7h"}, ""},
}

func runWinnerClassicShowCases(t *testing.T, cfg TableConfig) {
	t.Helper()
	for _, tc := range winnerClassicShowCases {
		t.Run(tc.name, func(t *testing.T) {
			_, ended, payer := winnerTwoPlayerShow(t, cfg, tc.a, tc.b)
			winner := *ended.WinnerID
			want := tc.want
			if want == "" {
				want = "b"
				if payer == "b" {
					want = "a"
				}
			}
			eq(t, winner, want, fmt.Sprintf("%v v %v (payer %s)", tc.a, tc.b, payer))
			r := revealsOf(ended.Reveals)
			eq(t, r["a"].HandName, Evaluate(ParseCards(tc.a), EvaluateOptions{}).Name, "a's reveal names its classic hand")
			eq(t, r["b"].HandName, Evaluate(ParseCards(tc.b), EvaluateOptions{}).Name, "b's reveal names its classic hand")
			eq(t, strings.Join(r["a"].Cards, " "), strings.Join(tc.a, " "), "a's cards as held")
			eq(t, strings.Join(r["b"].Cards, " "), strings.Join(tc.b, " "), "b's cards as held")
			if len(r["a"].Wild)+len(r["b"].Wild) != 0 {
				t.Fatalf("a classic table's reveal names wild cards: %v / %v", r["a"].Wild, r["b"].Wild)
			}
			if ended.Variation != "" {
				t.Fatalf("a classic table's handEnded names a variation: %q", ended.Variation)
			}
		})
	}
}

func winnerSeenConfig() TableConfig {
	cfg := sideshowConfig()
	cfg.Category = CategorySeen
	return cfg
}

func winnerBlindConfig() TableConfig {
	cfg := sideshowConfig()
	cfg.Category = CategoryBlind
	return cfg
}

// ---------------------------------------------------------- SEEN and BLIND

func TestReviewASeenTablesShowIsWonByTheBetterClassicHand(t *testing.T) {
	runWinnerClassicShowCases(t, winnerSeenConfig())
}

func TestReviewABlindTablesShowIsWonByTheBetterClassicHand(t *testing.T) {
	runWinnerClassicShowCases(t, winnerBlindConfig())
}

// winnerThreeHandForcedShowdown seats a, b, c with the given hands in every one of
// the six seat orders and lets the table end the hand by itself; the best hand
// must win each time whatever its seat, and the middle hand never.
func winnerThreeHandForcedShowdown(t *testing.T, cfg TableConfig, wantReason WinReason, hands map[string][]string, best, middle string) {
	t.Helper()
	ids := []string{"a", "b", "c"}
	perms := [][]string{{"a", "b", "c"}, {"a", "c", "b"}, {"b", "a", "c"}, {"b", "c", "a"}, {"c", "a", "b"}, {"c", "b", "a"}}
	for _, order := range perms {
		t.Run(strings.Join(order, ""), func(t *testing.T) {
			h := newHarness(t, cfg, withLedger(emptyLedger))
			for _, id := range order {
				h.seat(id, sideshowStart)
			}
			h.advance(cfg.NextHandDelay)
			for _, id := range ids {
				h.setCards(id, hands[id]...)
				h.mustAct(id, ActionSee, ActRequest{})
			}
			total := h.totalChips()
			before := map[string]int64{}
			for _, id := range ids {
				before[id] = sideshowStart // what they sat down with: the boot is a stake too
			}
			h.betUntilOver()
			ended := h.lastEnded()
			eq(t, ended.Reason, wantReason, "how the hand ended")
			checkWinnerOutcome(t, h, ended, before, total, ids)
			eq(t, *ended.WinnerID, best, "the best hand wins from any seat")
			if *ended.WinnerID == middle {
				t.Fatalf("the middle-ranked hand %s won", middle)
			}
			r := revealsOf(ended.Reveals)
			for _, id := range ids {
				eq(t, r[id].HandName, Evaluate(ParseCards(hands[id]), EvaluateOptions{}).Name, id+" is named for its hand")
			}
		})
	}
}

var winnerThreeClassicHands = map[string][]string{
	"a": {"8s", "8h", "8d"}, // trail — must win
	"b": {"Ts", "Th", "3c"}, // pair — the middle hand
	"c": {"As", "Kh", "9d"}, // ace high
}

func TestReviewASeenTablesRoundCapShowdownGoesToTheBestOfThree(t *testing.T) {
	cfg := winnerSeenConfig()
	cfg.MaxBetRounds = 2
	winnerThreeHandForcedShowdown(t, cfg, WinForcedShowdown, winnerThreeClassicHands, "a", "b")
}

func TestReviewASeenTablesPotLimitShowdownGoesToTheBestOfThree(t *testing.T) {
	cfg := winnerSeenConfig()
	cfg.MaxPot = 1500 // boot 100 × 3, then seen chaals of 200
	winnerThreeHandForcedShowdown(t, cfg, WinPotLimit, winnerThreeClassicHands, "a", "b")
}

func TestReviewABlindTablesRoundCapShowdownGoesToTheBestOfThree(t *testing.T) {
	cfg := winnerBlindConfig()
	cfg.MaxBetRounds = 2
	winnerThreeHandForcedShowdown(t, cfg, WinForcedShowdown, winnerThreeClassicHands, "a", "b")
}

func TestReviewABlindTablesPotLimitShowdownGoesToTheBestOfThree(t *testing.T) {
	cfg := winnerBlindConfig()
	cfg.MaxPot = 1500
	winnerThreeHandForcedShowdown(t, cfg, WinPotLimit, winnerThreeClassicHands, "a", "b")
}

// A player who never looked at their cards is still in the showdown and wins
// with the best hand — and loses with the worst — exactly as a seen one.
func TestReviewABlindPlayerWhoNeverSawTheirCardsStillWinsOrLosesOnTheirHand(t *testing.T) {
	for _, tc := range []struct {
		name        string
		blind, seen []string
		want        string
	}{
		{"blind trail beats a seen pair", []string{"7s", "7h", "7d"}, []string{"As", "Ah", "Kd"}, "blind"},
		{"blind high card loses to a seen pair", []string{"As", "Kh", "9d"}, []string{"3s", "3h", "2c"}, "seen"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := winnerBlindConfig()
			cfg.MaxBetRounds = 2
			cfg.MaxBlindMoves = 4
			h := newHarness(t, cfg, withLedger(emptyLedger))
			h.seat("blind", sideshowStart)
			h.seat("seen", sideshowStart)
			h.advance(cfg.NextHandDelay)
			h.setCards("blind", tc.blind...)
			h.setCards("seen", tc.seen...)
			h.mustAct("seen", ActionSee, ActRequest{})
			total := h.totalChips()
			before := map[string]int64{"blind": sideshowStart, "seen": sideshowStart}
			h.betUntilOver()
			eq(t, h.mustSeat("blind").IsBlind, true, "the blind player never looked")
			ended := h.lastEnded()
			eq(t, ended.Reason, WinForcedShowdown, "round cap")
			checkWinnerOutcome(t, h, ended, before, total, []string{"blind", "seen"})
			eq(t, *ended.WinnerID, tc.want, "the better hand wins, blind or seen")
			r := revealsOf(ended.Reveals)
			eq(t, strings.Join(r["blind"].Cards, " "), strings.Join(tc.blind, " "), "the blind hand is revealed")
			eq(t, r["blind"].HandName, Evaluate(ParseCards(tc.blind), EvaluateOptions{}).Name, "and named")
		})
	}
}

// ------------------------------------------------------------- VARIATION

// winnerVariationShowCase is one two-player show under a variation. The expected
// winner is never written down: the oracle decides.
type winnerVariationShowCase struct {
	name   string
	v      Variation
	turnUp string
	a, b   []string
	// aName/bName pin what the reveal must CALL each hand, where the case is
	// about that (empty = only the oracle's name is checked).
	aName, bName string
	aWild, bWild string
}

var winnerVariationShowCases = []winnerVariationShowCase{
	// AK47 — the owner's report. A natural pair with NO wild card is a pair
	// and loses to a natural trail; a pair WITH a wild card is a trail.
	{name: "AK47: a natural pair with no wild loses to a natural trail", v: VariationAK47,
		a: []string{"9s", "9h", "2c"}, b: []string{"Js", "Jh", "Jd"}, aName: "Pair", bName: "Trail"},
	{name: "AK47: a natural pair with no wild loses to a natural higher pair", v: VariationAK47,
		a: []string{"9s", "9h", "2c"}, b: []string{"Ts", "Th", "3d"}, aName: "Pair", bName: "Pair"},
	{name: "AK47: a pair plus a wild 4 is a trail and beats a natural higher pair", v: VariationAK47,
		a: []string{"9s", "9h", "4c"}, b: []string{"Ts", "Th", "2d"}, aName: "Trail", bName: "Pair", aWild: "4c"},
	{name: "AK47: Q-Q-7 is a trail of queens and beats a natural trail of jacks", v: VariationAK47,
		a: []string{"Qs", "Qh", "7c"}, b: []string{"Js", "Jh", "Jd"}, aName: "Trail", bName: "Trail", aWild: "7c"},
	{name: "AK47: K-K-7 is three wilds, a trail of aces, and beats a natural trail of queens", v: VariationAK47,
		a: []string{"Ks", "Kh", "7c"}, b: []string{"Qs", "Qh", "Qd"}, aName: "Trail", bName: "Trail", aWild: "Ks Kh 7c"},
	{name: "AK47: three wilds tie three wilds (K-K-7 v A-A-A), the payer loses", v: VariationAK47,
		a: []string{"Ks", "Kh", "7c"}, b: []string{"As", "Ah", "Ad"}, aWild: "Ks Kh 7c", bWild: "As Ah Ad"},
	{name: "AK47: a wild 4 completes a run and beats a natural pair of tens", v: VariationAK47,
		a: []string{"Ts", "Th", "3c"}, b: []string{"9d", "Jh", "4s"}, aName: "Pair", bName: "Sequence", bWild: "4s"},
	{name: "AK47: a wild cannot rescue 2-3-9 past a natural sequence", v: VariationAK47,
		a: []string{"2s", "3h", "9c"}, b: []string{"5d", "6h", "7s"}, aName: "High Card", bName: "Sequence", bWild: "7s"},
	// JOKER — the rank turned up, and nothing else, is wild.
	{name: "JOKER on nines: one joker with 5-2 makes only a pair of fives and loses to natural aces", v: VariationJoker, turnUp: "9d",
		a: []string{"9s", "5h", "2c"}, b: []string{"As", "Ah", "3d"}, aName: "Pair", bName: "Pair", aWild: "9s"},
	{name: "JOKER on nines: two jokers with a two are a trail of twos and beat a pair of aces", v: VariationJoker, turnUp: "9d",
		a: []string{"9s", "9h", "2c"}, b: []string{"As", "Ah", "5d"}, aName: "Trail", bName: "Pair", aWild: "9s 9h"},
	{name: "JOKER on nines: three jokers are a trail of aces and beat a natural trail of eights", v: VariationJoker, turnUp: "9d",
		a: []string{"8s", "8h", "8d"}, b: []string{"9s", "9h", "9c"}, aName: "Trail", bName: "Trail", bWild: "9s 9h 9c"},
	{name: "JOKER on nines: an eight is not a joker", v: VariationJoker, turnUp: "9d",
		a: []string{"8s", "8h", "2c"}, b: []string{"Ts", "Th", "3d"}, aName: "Pair", bName: "Pair"},
	// HUKAM — the suit turned up is wild.
	{name: "HUKAM on clubs: two clubs with a king are a trail of kings and beat A-K-Q", v: VariationHukam, turnUp: "9c",
		a: []string{"3c", "8c", "Kd"}, b: []string{"As", "Kh", "Qd"}, aName: "Trail", bName: "Sequence", aWild: "3c 8c"},
	{name: "HUKAM on clubs: one club fills 4-6 into a run and beats a natural king high", v: VariationHukam, turnUp: "9c",
		a: []string{"3h", "8d", "Ks"}, b: []string{"2c", "4d", "6h"}, aName: "High Card", bName: "Sequence", bWild: "2c"},
	{name: "HUKAM on clubs: no club in either hand is classic, the trail wins", v: VariationHukam, turnUp: "9c",
		a: []string{"Qs", "Qh", "Qd"}, b: []string{"5s", "3h", "2d"}, aName: "Trail", bName: "High Card"},
	// LOWEST / HIGHEST JOKER — per hand.
	{name: "LOWEST_JOKER: 3-8-K is a pair of kings, 2-2-9 a trail of nines", v: VariationLowestJoker,
		a: []string{"3s", "8h", "Kd"}, b: []string{"2c", "2d", "9h"}, aName: "Pair", bName: "Trail", aWild: "3s", bWild: "2c 2d"},
	{name: "LOWEST_JOKER: a pair of kings beats a pair of queens", v: VariationLowestJoker,
		a: []string{"3s", "8h", "Kd"}, b: []string{"5c", "6d", "Qh"}, aName: "Pair", bName: "Pair", aWild: "3s", bWild: "5c"},
	{name: "HIGHEST_JOKER: 3-8-K is a pair of eights, 5-6-Q a run", v: VariationHighestJoker,
		a: []string{"3s", "8h", "Kd"}, b: []string{"5c", "6d", "Qh"}, aName: "Pair", bName: "Sequence", aWild: "Kd", bWild: "Qh"},
	{name: "HIGHEST_JOKER: A-A-2 is a trail of twos, a natural trail of fours is three wilds", v: VariationHighestJoker,
		a: []string{"As", "Ah", "2d"}, b: []string{"4c", "4d", "4h"}, aName: "Trail", bName: "Trail", aWild: "As Ah", bWild: "4c 4d 4h"},
	// MUFLIS — the classically worst hand wins; nothing is wild.
	{name: "MUFLIS: a pair loses to a high card", v: VariationMuflis,
		a: []string{"9s", "9h", "2c"}, b: []string{"Ks", "Qh", "2d"}, aName: "Pair", bName: "High Card"},
	{name: "MUFLIS: 5-3-2 beats 6-4-2", v: VariationMuflis,
		a: []string{"5s", "3h", "2c"}, b: []string{"6s", "4h", "2d"}, aName: "High Card", bName: "High Card"},
	{name: "MUFLIS: a trail of twos beats a trail of aces", v: VariationMuflis,
		a: []string{"As", "Ah", "Ad"}, b: []string{"2s", "2h", "2d"}, aName: "Trail", bName: "Trail"},
	{name: "MUFLIS: an off-suit 7-4-2 beats the same ranks in one suit", v: VariationMuflis,
		a: []string{"7s", "4h", "2c"}, b: []string{"7d", "4d", "2d"}, aName: "High Card", bName: "Color"},
	{name: "MUFLIS: a high card beats a sequence", v: VariationMuflis,
		a: []string{"Ks", "Qh", "9c"}, b: []string{"4s", "5h", "6d"}, aName: "High Card", bName: "Sequence"},
	{name: "MUFLIS: the ace stays high, so A-8-3 loses to K-8-3", v: VariationMuflis,
		a: []string{"As", "8h", "3c"}, b: []string{"Kd", "8c", "3h"}, aName: "High Card", bName: "High Card"},
	{name: "MUFLIS: an exact tie goes against the payer", v: VariationMuflis,
		a: []string{"Qs", "8h", "3d"}, b: []string{"Qh", "8d", "3c"}},
}

func TestReviewAVariationShowIsWonByTheHandTheOracleRanksBest(t *testing.T) {
	for _, tc := range winnerVariationShowCases {
		t.Run(tc.name, func(t *testing.T) {
			var turnUp Card
			if tc.turnUp != "" {
				turnUp = ParseCard(tc.turnUp)
			}
			a := winnerOracleEvaluate(tc.v, turnUp, ParseCards(tc.a))
			b := winnerOracleEvaluate(tc.v, turnUp, ParseCards(tc.b))
			if tc.aName != "" {
				eq(t, a.Name, tc.aName, "the oracle agrees the case is what it says for a")
			}
			if tc.bName != "" {
				eq(t, b.Name, tc.bName, "the oracle agrees the case is what it says for b")
			}

			winner, ended, h := showdownUnder(t, tc.v, tc.turnUp, tc.a, tc.b)
			payer := h.payerOfLastShow()
			want := "p0"
			switch d := winnerOracleCompare(tc.v, a, b); {
			case d < 0:
				want = "p1"
			case d == 0:
				want = "p1"
				if payer == "p1" {
					want = "p0"
				}
			}
			eq(t, winner, want, fmt.Sprintf("%s: %v (%s) v %v (%s), payer %s", tc.v, tc.a, a.Name, tc.b, b.Name, payer))
			eq(t, ended.Variation, tc.v, "handEnded names the rules")

			r := revealsOf(ended.Reveals)
			eq(t, r["p0"].HandName, a.Name, "p0's reveal names what the hand MADE")
			eq(t, r["p1"].HandName, b.Name, "p1's reveal names what the hand MADE")
			eq(t, r["p0"].Category, a.Category, "p0's category")
			eq(t, r["p1"].Category, b.Category, "p1's category")
			eq(t, strings.Join(r["p0"].Cards, " "), strings.Join(tc.a, " "), "p0's cards as held")
			eq(t, strings.Join(r["p1"].Cards, " "), strings.Join(tc.b, " "), "p1's cards as held")
			eq(t, strings.Join(r["p0"].Wild, " "), strings.Join(a.Wild, " "), "p0's wild cards, exactly")
			eq(t, strings.Join(r["p1"].Wild, " "), strings.Join(b.Wild, " "), "p1's wild cards, exactly")
			eq(t, strings.Join(r["p0"].Wild, " "), tc.aWild, "p0's wild cards as the case states")
			eq(t, strings.Join(r["p1"].Wild, " "), tc.bWild, "p1's wild cards as the case states")
			eq(t, r[winner].Won, true, "the winner's reveal says so")
			eq(t, r[winner].UserID, *ended.WinnerID, "the winner is identified by userId")

			// game:showdown says the same as game:handEnded.
			sd := h.lastShowdown()
			eq(t, sd.Variation, tc.v, "game:showdown names the rules")
			sr := revealsOf(sd.Reveals)
			for id := range r {
				eq(t, sr[id].HandName, r[id].HandName, id+": showdown and handEnded agree on the hand")
				eq(t, strings.Join(sr[id].Wild, " "), strings.Join(r[id].Wild, " "), id+": and on the wild cards")
				eq(t, sr[id].Won, r[id].Won, id+": and on who won")
			}
			if tc.v.UsesTurnUp() {
				if ended.TurnUp == nil || *ended.TurnUp != tc.turnUp {
					t.Fatalf("handEnded turnUp = %v, want %s", ended.TurnUp, tc.turnUp)
				}
			} else if ended.TurnUp != nil {
				t.Fatalf("%s carries a turnUp card %s", tc.v, *ended.TurnUp)
			}

			// Chips: the pot went to the winner and nowhere else.
			eq(t, h.pot(), int64(0), "the pot is empty")
			eq(t, h.totalChips(), 2*sideshowStart, "chips conserved")
			eq(t, h.mustSeat(winner).Chips > sideshowStart, true, "the winner is up")
		})
	}
}

// What the viewer's OWN hand is called in their snapshot (you.hand) — what the
// app draws over their cards before any reveal — is the same answer.
func TestReviewYourOwnHandIsNamedForWhatItMakesAndAPairWithoutAWildIsAPair(t *testing.T) {
	h, ids, chooser := variationTable(t, 2)
	h.setCards(ids[0], "9s", "9h", "2c") // a natural pair, nothing wild under AK47
	h.setCards(ids[1], "9d", "9c", "4h") // a pair plus a wild four: a trail
	if _, err := h.table.SelectVariation(chooser, string(VariationAK47)); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		h.mustAct(id, ActionSee, ActRequest{})
	}
	pair := h.view(ids[0]).You.Hand
	if pair == nil {
		t.Fatal("no you.hand for the pair")
	}
	eq(t, pair.HandName, "Pair", "a pair with no wild card is called a pair")
	eq(t, len(pair.Wild), 0, "and names no wild card")
	eq(t, strings.Join(pair.PlaysAs, " "), "9s 9h 2c", "and plays as itself")

	trail := h.view(ids[1]).You.Hand
	if trail == nil {
		t.Fatal("no you.hand for the trail")
	}
	eq(t, trail.HandName, "Trail", "a pair with a wild card is called the trail it makes")
	eq(t, strings.Join(trail.Wild, " "), "4h", "and names the wild card")
	eq(t, trail.PlaysAs[0]+" "+trail.PlaysAs[1], "9d 9c", "the naturals play as themselves")
	eq(t, trail.PlaysAs[2][0], byte('9'), "and the wild plays as a nine")

	// Each viewer is told their own cards and only a count of the other's.
	for i, id := range ids {
		view := h.view(id)
		eq(t, strings.Join(view.You.Cards, " "), strings.Join(CardCodes(h.mustSeat(id).Cards), " "), id+" sees their own cards")
		for _, s := range view.Seats {
			if !s.Empty && s.UserID == ids[1-i] {
				eq(t, s.CardCount, 3, id+" sees only a count of the other hand")
			}
		}
	}
}

// Random hands under every three-card variation, decided at the table and by
// the oracle: the winner and every reveal's name and wild cards must agree.
func TestReviewRandomVariationShowsAgreeWithTheOracle(t *testing.T) {
	rng := rand.New(rand.NewSource(20260924))
	deck := NewDeck()
	const perVariation = 24
	for _, v := range Variations {
		if v == VariationFiveCard {
			continue
		}
		for n := 0; n < perVariation; n++ {
			rng.Shuffle(len(deck), func(i, j int) { deck[i], deck[j] = deck[j], deck[i] })
			a, b := CardCodes(deck[0:3]), CardCodes(deck[3:6])
			turnUpCode := ""
			var turnUp Card
			if v.UsesTurnUp() {
				turnUp = deck[6]
				turnUpCode = turnUp.Code()
			}
			oa := winnerOracleEvaluate(v, turnUp, ParseCards(a))
			ob := winnerOracleEvaluate(v, turnUp, ParseCards(b))
			winner, ended, h := showdownUnder(t, v, turnUpCode, a, b)
			payer := h.payerOfLastShow()
			want := "p0"
			switch d := winnerOracleCompare(v, oa, ob); {
			case d < 0:
				want = "p1"
			case d == 0:
				want = "p1"
				if payer == "p1" {
					want = "p0"
				}
			}
			label := fmt.Sprintf("%s turnUp=%q %v (%s %v) v %v (%s %v) payer %s", v, turnUpCode, a, oa.Name, oa.Wild, b, ob.Name, ob.Wild, payer)
			if winner != want {
				t.Fatalf("%s: table says %s, oracle says %s", label, winner, want)
			}
			r := revealsOf(ended.Reveals)
			if r["p0"].HandName != oa.Name || r["p1"].HandName != ob.Name {
				t.Fatalf("%s: reveals name %s / %s", label, r["p0"].HandName, r["p1"].HandName)
			}
			if strings.Join(r["p0"].Wild, " ") != strings.Join(oa.Wild, " ") || strings.Join(r["p1"].Wild, " ") != strings.Join(ob.Wild, " ") {
				t.Fatalf("%s: reveals list wild %v / %v", label, r["p0"].Wild, r["p1"].Wild)
			}
			if h.totalChips() != 2*sideshowStart {
				t.Fatalf("%s: chips not conserved: %d", label, h.totalChips())
			}
		}
	}
}

// A forced showdown with three players under a variation: the oracle's best
// hand wins from any seat, and the hand that is only classically best never
// does. AK47: T-T-2 is a natural pair (no wild), 9-9-4 a trail by the wild
// four, 2-5-9 nothing at all.
func TestReviewAVariationRoundCapShowdownGoesToTheOraclesBestOfThree(t *testing.T) {
	hands := map[string][]string{
		"p0": {"Ts", "Th", "2c"}, // pair of tens, classically the best of the three
		"p1": {"9s", "9h", "4c"}, // trail of nines by the wild four — must win
		"p2": {"2d", "5s", "9c"}, // nine high
	}
	best, tie := winnerOracleBest(VariationAK47, Card{}, hands)
	eq(t, best, "p1", "the oracle's answer")
	eq(t, tie, false, "no tie")
	for _, order := range [][]string{{"p0", "p1", "p2"}, {"p1", "p2", "p0"}, {"p2", "p0", "p1"}, {"p2", "p1", "p0"}} {
		t.Run(strings.Join(order, ""), func(t *testing.T) {
			cfg := variationConfig()
			cfg.MaxBetRounds = 2
			h := newHarness(t, cfg, withLedger(emptyLedger), withID("variation-forced", "VARFORCE"))
			for _, id := range order {
				h.seatNamed(id, strings.ToUpper(id), sideshowStart)
			}
			h.advance(cfg.NextHandDelay)
			chooser := h.chooser()
			if chooser == "" {
				t.Fatal("no window")
			}
			for id, cards := range hands {
				h.setCards(id, cards...)
			}
			if _, err := h.table.SelectVariation(chooser, string(VariationAK47)); err != nil {
				t.Fatal(err)
			}
			for id := range hands {
				h.mustAct(id, ActionSee, ActRequest{})
			}
			total := h.totalChips()
			before := map[string]int64{}
			for id := range hands {
				before[id] = sideshowStart
			}
			h.betUntilOver()
			ended := h.lastEnded()
			eq(t, ended.Reason, WinForcedShowdown, "the round cap ended it")
			eq(t, ended.Variation, VariationAK47, "under AK47")
			checkWinnerOutcome(t, h, ended, before, total, []string{"p0", "p1", "p2"})
			eq(t, *ended.WinnerID, "p1", "the wild trail wins from any seat")
			r := revealsOf(ended.Reveals)
			eq(t, r["p0"].HandName, "Pair", "the natural pair is a pair")
			eq(t, len(r["p0"].Wild), 0, "with no wild card")
			eq(t, r["p1"].HandName, "Trail", "the wild hand is the trail it made")
			eq(t, strings.Join(r["p1"].Wild, " "), "4c", "with its wild card named")
			eq(t, r["p2"].HandName, "High Card", "the scraps are scraps")
		})
	}
}

// Under MUFLIS a forced showdown of three goes to the classically WORST hand.
func TestReviewAMuflisRoundCapShowdownGoesToTheWorstClassicHand(t *testing.T) {
	hands := map[string][]string{
		"p0": {"Ts", "Th", "Td"}, // trail — must lose
		"p1": {"9s", "9h", "4c"}, // pair
		"p2": {"7d", "5s", "2c"}, // seven high — must win
	}
	best, _ := winnerOracleBest(VariationMuflis, Card{}, hands)
	eq(t, best, "p2", "the oracle's answer")
	cfg := variationConfig()
	cfg.MaxBetRounds = 2
	h := newHarness(t, cfg, withLedger(emptyLedger), withID("variation-muflis", "VARMUFLI"))
	for _, id := range []string{"p0", "p1", "p2"} {
		h.seatNamed(id, strings.ToUpper(id), sideshowStart)
	}
	h.advance(cfg.NextHandDelay)
	chooser := h.chooser()
	for id, cards := range hands {
		h.setCards(id, cards...)
	}
	if _, err := h.table.SelectVariation(chooser, string(VariationMuflis)); err != nil {
		t.Fatal(err)
	}
	for id := range hands {
		h.mustAct(id, ActionSee, ActRequest{})
	}
	h.betUntilOver()
	ended := h.lastEnded()
	eq(t, ended.Reason, WinForcedShowdown, "the round cap ended it")
	eq(t, *ended.WinnerID, "p2", "the worst classic hand wins Muflis")
	r := revealsOf(ended.Reveals)
	eq(t, r["p0"].HandName, "Trail", "the trail is still called a trail")
	eq(t, r["p0"].Won, false, "and loses")
}

// A sideshow at a variation table is decided under the variation, its reveal
// names what each hand made and which cards were wild, and an exact tie goes
// against the asker.
func TestReviewASideshowAtAVariationTableIsDecidedByTheVariation(t *testing.T) {
	for _, tc := range []struct {
		name         string
		v            Variation
		asker, asked []string
		packed       string // "asker" or "asked"
	}{
		{"AK47: Q-Q-7 (trail of queens) beats a natural trail of jacks, which a classic compare would not", VariationAK47,
			[]string{"Qs", "Qh", "7c"}, []string{"Js", "Jh", "Jd"}, "asked"},
		{"AK47: a natural pair with no wild loses to a natural trail", VariationAK47,
			[]string{"9s", "9h", "2c"}, []string{"Js", "Jh", "Jd"}, "asker"},
		{"AK47: two trails of nines by different wilds tie, the asker loses", VariationAK47,
			[]string{"9s", "9h", "4c"}, []string{"9d", "9c", "7s"}, "asker"},
		{"AK47: two trails of nines by different wilds tie, the asker loses (roles swapped)", VariationAK47,
			[]string{"9d", "9c", "7s"}, []string{"9s", "9h", "4c"}, "asker"},
		{"HIGHEST_JOKER: 5-6-Q (a run) beats 3-8-K (a pair of eights)", VariationHighestJoker,
			[]string{"3s", "8h", "Kd"}, []string{"5c", "6d", "Qh"}, "asker"},
		{"MUFLIS: a high card beats a pair", VariationMuflis,
			[]string{"Ks", "Qh", "2c"}, []string{"9s", "9h", "3d"}, "asked"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h, ids, chooser := variationTable(t, 3)
			if _, err := h.table.SelectVariation(chooser, string(tc.v)); err != nil {
				t.Fatal(err)
			}
			for _, id := range ids {
				h.mustAct(id, ActionSee, ActRequest{})
			}
			asker := h.turnUser()
			asked := h.rightOf(asker)
			h.setCards(asker, tc.asker...)
			h.setCards(asked, tc.asked...)
			// The oracle agrees with the case.
			oa := winnerOracleEvaluate(tc.v, Card{}, ParseCards(tc.asker))
			ob := winnerOracleEvaluate(tc.v, Card{}, ParseCards(tc.asked))
			wantLoser := asker
			if winnerOracleCompare(tc.v, oa, ob) > 0 {
				wantLoser = asked
			}
			if tc.packed == "asked" {
				eq(t, wantLoser, asked, "the oracle agrees the asked player loses")
			} else {
				eq(t, wantLoser, asker, "the oracle agrees the asker loses")
			}
			total := h.totalChips()

			h.mustAct(asker, ActionSideshow, ActRequest{})
			outcome := h.mustRespond(asked, true)
			if outcome.PackedUserID == nil || *outcome.PackedUserID != wantLoser {
				t.Fatalf("packed %v, want %s (%s %v v %s %v)", outcome.PackedUserID, wantLoser, oa.Name, oa.Wild, ob.Name, ob.Wild)
			}
			reveals := h.sideshowReveals()
			eq(t, len(reveals), 1, "one private reveal")
			rv := reveals[0]
			eq(t, strings.Join(rv.UserIDs, " "), asker+" "+asked, "sent to the two of them only")
			eq(t, rv.Reveal.PackedUserID, wantLoser, "the reveal names the loser")
			eq(t, rv.Reveal.Hands[0].UserID, asker, "hands[0] is the asker")
			eq(t, rv.Reveal.Hands[1].UserID, asked, "hands[1] is the asked")
			eq(t, rv.Reveal.Hands[0].HandName, oa.Name, "the asker's hand is what it MADE")
			eq(t, rv.Reveal.Hands[1].HandName, ob.Name, "the asked's hand is what it MADE")
			eq(t, strings.Join(rv.Reveal.Hands[0].Wild, " "), strings.Join(oa.Wild, " "), "the asker's wild cards, exactly")
			eq(t, strings.Join(rv.Reveal.Hands[1].Wild, " "), strings.Join(ob.Wild, " "), "the asked's wild cards, exactly")
			eq(t, strings.Join(rv.Reveal.Hands[0].Cards, " "), strings.Join(tc.asker, " "), "the asker's cards as held")
			eq(t, strings.Join(rv.Reveal.Hands[1].Cards, " "), strings.Join(tc.asked, " "), "the asked's cards as held")
			eq(t, h.mustSeat(wantLoser).Status, SeatPacked, "the loser packed")
			eq(t, h.hasHand(), true, "two are still in, the hand goes on")
			eq(t, h.totalChips(), total, "a sideshow moves no chips")
			// The turn never left the asker unless it was they who packed.
			if wantLoser == asked {
				eq(t, h.turnUser(), asker, "the asker keeps the turn when the asked player packs")
			} else if h.turnUser() == asker {
				t.Fatal("a packed asker is still on turn")
			}
		})
	}
}

// FIVE_CARD: the player's own three play, not the best three; the reveal names
// the three that played and the winner follows them.
func TestReviewAFiveCardShowdownIsDecidedOnTheThreesThePlayersChoseOrLapsedInto(t *testing.T) {
	h, ids, chooser := variationTable(t, 3)
	a, b, c := ids[0], ids[1], ids[2]
	h.setCards(a, "Qs", "Qh", "4d")
	h.setExtra(a, "9c", "2s") // holds a pair of queens; will PICK a queen-high nothing
	h.setCards(b, "2c", "9d", "5h")
	h.setExtra(b, "5s", "5d") // holds a trail of fives; will pick it
	h.setCards(c, "Ah", "Kh", "Qh")
	h.setExtra(c, "6s", "3d") // holds A-K-Q of hearts, a pure sequence; will LAPSE and play it (first three)
	if _, err := h.table.SelectVariation(chooser, string(VariationFiveCard)); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		h.mustAct(id, ActionSee, ActRequest{})
		eq(t, len(h.mustSeat(id).Cards), 5, id+" holds five")
	}
	pick, err := h.table.SelectCards(a, []string{"Qs", "4d", "9c"})
	if err != nil {
		t.Fatal(err)
	}
	eq(t, pick.WasBest, false, "a chose worse than they held")
	eq(t, Evaluate(ParseCards(pick.Picked), EvaluateOptions{}).Name, "High Card", "a's three make nothing")
	eq(t, Evaluate(ParseCards(pick.Best), EvaluateOptions{}).Name, "Pair", "the best they could have played was the pair")
	pick, err = h.table.SelectCards(b, []string{"5d", "5h", "5s"})
	if err != nil {
		t.Fatal(err)
	}
	eq(t, pick.WasBest, true, "b chose the trail")
	h.clock.Advance(h.table.cfg.FiveCardPickTimeout) // c lapses into A-K-Q of hearts

	total := h.totalChips()
	h.betUntilOver()
	ended := h.lastEnded()
	eq(t, ended.Variation, VariationFiveCard, "under FIVE_CARD")
	eq(t, *ended.WinnerID, b, "the trail wins")
	eq(t, h.totalChips(), total, "chips conserved")
	r := revealsOf(ended.Reveals)
	eq(t, r[a].HandName, "High Card", "a plays the three they chose, not the pair they held")
	eq(t, winnerSortedCodes(r[a].Best), "4d 9c Qs", "and the reveal names the three chosen")
	eq(t, r[b].HandName, "Trail", "b plays the trail they chose")
	eq(t, winnerSortedCodes(r[b].Best), "5d 5h 5s", "those three")
	eq(t, r[c].HandName, "Pure Sequence", "c plays the first three dealt")
	eq(t, strings.Join(r[c].Best, " "), "Ah Kh Qh", "the first three, in the order held")
	for _, id := range ids {
		eq(t, len(r[id].Cards), 5, id+" shows all five")
		eq(t, len(r[id].Wild), 0, "nothing is wild under FIVE_CARD")
	}
	// The trail beats the pure sequence, which beats the high card — the same
	// order every classic table plays by, on the threes that were played.
	best, _ := winnerOracleBest(VariationFiveCard, Card{}, map[string][]string{a: r[a].Best, b: r[b].Best, c: r[c].Best})
	eq(t, best, b, "the oracle on the played threes agrees")
}

// Had c picked their best three and a played the first three, the pure
// sequence would still lose to the trail but the pair would beat nothing: the
// choice moves a hand's worth, never the ranking.
func TestReviewAFiveCardPickCanOnlyLowerOrKeepAHandsWorthNeverBreakTheRanking(t *testing.T) {
	h, ids, chooser := variationTable(t, 2)
	a, b := ids[0], ids[1]
	h.setCards(a, "Qs", "Qh", "4d")
	h.setExtra(a, "9c", "2s")
	h.setCards(b, "Jc", "Jd", "8h")
	h.setExtra(b, "Js", "3d") // a trail of jacks, but only if picked
	if _, err := h.table.SelectVariation(chooser, string(VariationFiveCard)); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		h.mustAct(id, ActionSee, ActRequest{})
	}
	// b picks the pair of jacks with the eight — worse than the trail they hold.
	if _, err := h.table.SelectCards(b, []string{"Jc", "Jd", "8h"}); err != nil {
		t.Fatal(err)
	}
	h.clock.Advance(h.table.cfg.FiveCardPickTimeout) // a lapses into Q-Q-4
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	h.mustAct(h.turnUser(), ActionShow, ActRequest{})
	ended := h.lastEnded()
	eq(t, *ended.WinnerID, a, "a pair of queens beats the pair of jacks b chose to play")
	r := revealsOf(ended.Reveals)
	eq(t, r[b].HandName, "Pair", "b's reveal is the pair they played")
	eq(t, r[a].HandName, "Pair", "a's is the pair they lapsed into")
}

func winnerSortedCodes(codes []string) string {
	out := append([]string(nil), codes...)
	sort.Strings(out)
	return strings.Join(out, " ")
}

// The hand is compared exactly once, under exactly one set of rules, however
// it ends: on a variation table the window has to be closed before any move
// that could compare hands is accepted, so no comparison can run under classic
// rules there — and a classic table never has a window at all.
func TestReviewNoComparisonCanHappenBeforeAVariationIsChosen(t *testing.T) {
	h, ids, _ := variationTable(t, 3)
	for _, id := range ids {
		h.mustAct(id, ActionSee, ActRequest{}) // allowed
	}
	for _, action := range []Action{ActionShow, ActionSideshow, ActionForceSideshow, ActionMissile, ActionChaal, ActionPack} {
		for _, id := range ids {
			_, err := h.act(id, action, ActRequest{ActionID: "x-" + string(action) + id})
			codeIs(t, err, CodeVariationPending)
		}
	}
	eq(t, h.hasHand(), true, "the hand is still on")
	if len(h.rec.all("showdown"))+len(h.rec.all("sideshowReveal")) != 0 {
		t.Fatal("a hand was compared while the variation was still being chosen")
	}
	// A seen table's rules are the zero value: classic, and every reveal is
	// classic.
	seen := newHarness(t, winnerSeenConfig(), withLedger(emptyLedger))
	seen.seat("a", sideshowStart)
	seen.seat("b", sideshowStart)
	seen.advance(winnerSeenConfig().NextHandDelay)
	var rules VariationRules
	seen.read(func() { rules = seen.table.handRules() })
	eq(t, rules, VariationRules{}, "a seen table's hand rules are classic")
	var vrules VariationRules
	h.read(func() { vrules = h.table.handRules() })
	eq(t, vrules, VariationRules{}, "a variation table's rules are classic ONLY while the window is open, when nothing may be compared")
}

// A hand's clock: a variation table's showdown reached by the turn clock
// packing everyone but one compares nothing and pays the last player.
func TestReviewTimeoutsPackAndTheLastPlayerStandingTakesThePotWithoutAComparison(t *testing.T) {
	h, ids, chooser := variationTable(t, 3)
	h.setCards(ids[0], "2s", "3h", "5d")
	h.setCards(ids[1], "As", "Ah", "Ad")
	h.setCards(ids[2], "Ks", "Kh", "Kd")
	if _, err := h.table.SelectVariation(chooser, string(VariationAK47)); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		h.advance(variationConfig().TurnTimeout + time.Millisecond)
	}
	ended := h.lastEnded()
	eq(t, ended.Reason, WinLastStanding, "everyone else timed out")
	eq(t, len(ended.Reveals), 0, "nothing was revealed")
	if len(h.rec.all("showdown")) != 0 {
		t.Fatal("a showdown ran for a hand nobody contested")
	}
}

// An exact three-way tie at a forced showdown (no show payer): the pot goes to
// the seat nearest the dealer counting the dealer's OWN seat as distance 0 —
// the Node rule the port verified (PORT_NOTES/table.md), which CLAUDE.md §6.1
// abbreviates as "nearest the dealer's left". Pinned here so a change to the
// preference shows up; the same rule decides ties on every category.
func TestReviewAThreeWayExactTieAtAForcedShowdownGoesToTheDealersSeatFirst(t *testing.T) {
	for _, cfg := range []TableConfig{winnerSeenConfig(), winnerBlindConfig()} {
		cfg := cfg
		cfg.MaxBetRounds = 2
		t.Run(string(cfg.Category), func(t *testing.T) {
			h := newHarness(t, cfg, withLedger(emptyLedger))
			for _, id := range []string{"a", "b", "c"} {
				h.seat(id, sideshowStart)
			}
			h.advance(cfg.NextHandDelay)
			// Three identical high-card hands in three suits: suits never break a tie.
			h.setCards("a", "Ks", "9s", "4s")
			h.setCards("b", "Kh", "9h", "4h")
			h.setCards("c", "Kd", "9d", "4d")
			for _, id := range []string{"a", "b", "c"} {
				h.mustAct(id, ActionSee, ActRequest{})
			}
			dealer := h.dealerSeat()
			var atDealer string
			h.read(func() { atDealer = h.table.seats[dealer].userID })
			h.betUntilOver()
			ended := h.lastEnded()
			eq(t, ended.Reason, WinForcedShowdown, "round cap")
			eq(t, len(ended.Reveals), 3, "everyone shows")
			eq(t, *ended.WinnerID, atDealer, "the dealer's own seat takes an exact tie (distance 0)")
		})
	}
}
