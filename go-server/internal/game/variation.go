package game

// Variation Teen Patti (Go only; owner, 18 Sep 2026). There is no Node source
// for any of this: the Node server never had a variation table.
//
// On a table of CategoryVariation the player who opens the hand picks, in a
// server-timed window straight after the deal, the rules the hand is decided
// by. This file is those rules and nothing else — it knows no table, no seat
// and no clock. The window, its timer and who may choose live in
// table_variation.go.
//
// # One ranking, not seven
//
// Every variation but Muflis is classic Teen Patti with some cards wild, and
// Muflis is classic Teen Patti read backwards. So there is exactly one hand
// ranking in the server — Evaluate, in handrank.go — and a variation is one of
// two small things laid over it:
//
//   - a WILD RULE, which says which of a player's three cards are wild. The
//     hand is then worth the best classic hand those wilds can complete
//     (evaluateWithWilds), found by trying every card they could stand for and
//     asking Evaluate — so a wild hand can never be ranked by logic that
//     disagrees with the classic one, because it IS the classic one;
//   - a COMPARISON DIRECTION: Muflis compares the other way round.
//
// Both are carried by VariationRules, whose zero value is classic Teen Patti.
// That is what lets the Table call one evaluator and one comparator everywhere
// and have a seen or blind table behave exactly as it did before this existed.

// Variation is one of the seven rule sets a variation table's hand can be played
// under. The values are the wire contract — game:selectVariation carries one,
// room:state and game:variationSelected echo it — and they are compared
// EXACTLY: there is one canonical spelling and no case folding, so "muflis",
// "Lowest Joker" and "LowestJoker" are all refused as invalid_variation rather
// than quietly understood.
type Variation string

const (
	// VariationMuflis — "lowball": the classic ranking reversed, so the weakest
	// classic hand wins. 5-3-2 of mixed suits is the best hand there is and a
	// trail of aces the worst. The ace stays high, as it is everywhere else in
	// this server.
	VariationMuflis Variation = "MUFLIS"
	// VariationAK47 — every ace, king, four and seven is wild, whatever its suit.
	VariationAK47 Variation = "AK47"
	// VariationJoker — a card is turned up from the undealt deck and every card
	// of its RANK is wild.
	VariationJoker Variation = "JOKER"
	// VariationHukam — a card is turned up from the undealt deck and every card
	// of its SUIT is wild: the hukam (trump) suit.
	VariationHukam Variation = "HUKAM"
	// VariationLowestJoker — in each player's own hand, the lowest-ranked card is
	// wild, and so is any other card of that same rank they hold.
	VariationLowestJoker Variation = "LOWEST_JOKER"
	// VariationHighestJoker — the same, with the highest-ranked card.
	VariationHighestJoker Variation = "HIGHEST_JOKER"
	// VariationFiveCard — 5-Card Teen Patti (owner, 18 Sep 2026): every player
	// holds FIVE cards and plays the best three of them, found by the server —
	// nobody picks. No card is wild and nothing is reversed: it is classic Teen
	// Patti with ten hands to choose from (EvaluateBest). It is the one
	// variation whose CardsPerPlayer is not three.
	VariationFiveCard Variation = "FIVE_CARD"
)

// The sizes a hand can be. Every hand is DEALT BaseCardsPerPlayer; a variation
// whose CardsPerPlayer is more has each hand topped up to it, from the same
// shuffled deck, when it is chosen (Table.closeVariation).
const (
	BaseCardsPerPlayer = 3
	MaxCardsPerPlayer  = 5
)

// CardsPerPlayer is how many cards a player HOLDS under this variation. It is
// the single place that number lives — the deal, the top-up, the snapshot the
// client draws its fan from and the validator all read it — so no part of the
// engine carries a "3" of its own. Whatever is held, three are played.
func (v Variation) CardsPerPlayer() int {
	if v == VariationFiveCard {
		return MaxCardsPerPlayer
	}
	return BaseCardsPerPlayer
}

// Variations is the menu in the order the chooser is shown it. It is sent to
// the client (room:state variation.options) so the client renders what the
// server offers rather than a list of its own that could drift.
var Variations = []Variation{
	VariationMuflis,
	VariationAK47,
	VariationJoker,
	VariationHukam,
	VariationLowestJoker,
	VariationHighestJoker,
	VariationFiveCard,
}

// VariationDefault is what the SERVER chooses when the window closes with no
// answer — the clock ran out, or the chooser left the table.
const VariationDefault = VariationMuflis

// ParseVariation is the allowlist. It accepts exactly the seven canonical values
// and nothing else: no trimming, no case folding, no aliases.
func ParseVariation(raw string) (Variation, bool) {
	for _, v := range Variations {
		if raw == string(v) {
			return v, true
		}
	}
	return "", false
}

// VariationSelectedBy says how a window closed.
type VariationSelectedBy string

const (
	// VariationByPlayer — the chooser picked it.
	VariationByPlayer VariationSelectedBy = "PLAYER"
	// VariationByTimeout — the window lapsed and the server chose VariationDefault.
	VariationByTimeout VariationSelectedBy = "TIMEOUT"
	// VariationByLeft — the chooser left the table mid-window and the server
	// chose VariationDefault so the hand could go on without them.
	VariationByLeft VariationSelectedBy = "LEFT"
)

// VariationRules is everything a comparison needs to know about the rules in
// force. The ZERO VALUE is classic Teen Patti: no wild cards, the classic
// direction. A seen or blind table only ever holds the zero value.
type VariationRules struct {
	Variation Variation
	// WildRank is the rank that is wild under VariationJoker (2..14), else 0.
	WildRank int
	// WildSuit is the suit that is wild under VariationHukam, else 0.
	WildSuit byte
}

// RulesFor builds the rules for a chosen variation. turnUp is the card turned
// up from the undealt deck; only Joker and Hukam read it.
func RulesFor(v Variation, turnUp Card) VariationRules {
	rules := VariationRules{Variation: v}
	switch v {
	case VariationJoker:
		rules.WildRank = turnUp.Rank
	case VariationHukam:
		rules.WildSuit = turnUp.Suit
	}
	return rules
}

// UsesTurnUp reports whether the variation is decided by the turned-up card,
// and so whether that card is shown to the table.
func (v Variation) UsesTurnUp() bool {
	return v == VariationJoker || v == VariationHukam
}

// EvaluateHand scores a hand under these rules. The result's Score is always a
// classic score — what the hand is worth as the best classic hand it can make —
// and CompareHands is what reads it in the right direction.
func (r VariationRules) EvaluateHand(cards []Card) EvaluatedHand {
	switch r.Variation {
	case VariationMuflis:
		return EvaluateMuflis(cards)
	case VariationAK47:
		return EvaluateAK47(cards)
	case VariationJoker:
		return EvaluateJoker(cards, r.WildRank)
	case VariationHukam:
		return EvaluateHukam(cards, r.WildSuit)
	case VariationLowestJoker:
		return EvaluateLowestJoker(cards)
	case VariationHighestJoker:
		return EvaluateHighestJoker(cards)
	case VariationFiveCard:
		return EvaluateBest(cards)
	default:
		return Evaluate(cards, EvaluateOptions{})
	}
}

// EvaluateBest is 5-Card Teen Patti's evaluator, and the general "best three of
// what you hold": it scores EVERY three-card combination of cards with the one
// classic Evaluate and returns the strongest by the one classic Compare — ten
// combinations for five cards, C(n,3) for n. There is no second ranking here to
// drift from the first: a hand of five is worth exactly what its best three
// cards are worth at any other table.
//
// The result keeps the player's real cards, all of them, in Cards, and names
// the three that were counted in Best (in the order they were held). Combinations
// are walked in index order and a later one must be STRICTLY better to displace
// an earlier one, so which three are named is deterministic even when several
// tie (two equal pairs, say) — and since they tie, the hand's worth does not
// depend on it. A three-card hand is simply evaluated (Best stays nil); fewer
// than three is a programming error, as it is for Evaluate.
func EvaluateBest(cards []Card) EvaluatedHand {
	if len(cards) < BaseCardsPerPlayer {
		panic("a Teen Patti hand must be at least 3 cards")
	}
	if len(cards) == BaseCardsPerPlayer {
		return Evaluate(cards, EvaluateOptions{})
	}
	var best EvaluatedHand
	var bestAt [3]int
	found := false
	for i := 0; i < len(cards)-2; i++ {
		for j := i + 1; j < len(cards)-1; j++ {
			for k := j + 1; k < len(cards); k++ {
				scored := Evaluate([]Card{cards[i], cards[j], cards[k]}, EvaluateOptions{})
				if !found || Compare(scored, best) > 0 {
					best, bestAt, found = scored, [3]int{i, j, k}, true
				}
			}
		}
	}
	return EvaluatedHand{
		Category: best.Category,
		Name:     best.Name,
		Score:    best.Score,
		Cards:    CardCodes(cards),
		Best:     []string{cards[bestAt[0]].Code(), cards[bestAt[1]].Code(), cards[bestAt[2]].Code()},
	}
}

// ThreeCardCombinations is every way of choosing three of cards, in index
// order: ten for a hand of five. EvaluateBest walks the same order without
// building the list; this is the list itself, for the tests that count it.
func ThreeCardCombinations(cards []Card) [][]Card {
	var out [][]Card
	for i := 0; i < len(cards)-2; i++ {
		for j := i + 1; j < len(cards)-1; j++ {
			for k := j + 1; k < len(cards); k++ {
				out = append(out, []Card{cards[i], cards[j], cards[k]})
			}
		}
	}
	return out
}

// CompareHands returns > 0 when a wins, < 0 when b wins, 0 on an exact tie —
// Compare's contract, under these rules. Exact ties are left to the caller,
// exactly as they are on a classic table (the show-payer loses, else nearest
// the dealer's left; a sideshow's asker loses).
func (r VariationRules) CompareHands(a, b EvaluatedHand) int {
	if r.Variation == VariationMuflis {
		return CompareMuflis(a, b)
	}
	return Compare(a, b)
}

// ----------------------------------------------------------------- Muflis

// EvaluateMuflis scores a hand for Muflis. It is the classic evaluation: what
// changes in Muflis is which way the score is read, and CompareMuflis owns that.
func EvaluateMuflis(cards []Card) EvaluatedHand {
	return Evaluate(cards, EvaluateOptions{})
}

// CompareMuflis is Compare reversed: the weaker classic hand wins.
func CompareMuflis(a, b EvaluatedHand) int {
	return Compare(b, a)
}

// ------------------------------------------------------------- wild rules

// EvaluateAK47 — aces, kings, fours and sevens are wild.
func EvaluateAK47(cards []Card) EvaluatedHand {
	return evaluateWithWilds(cards, wildMask(cards, func(c Card) bool {
		return c.Rank == 14 || c.Rank == 13 || c.Rank == 4 || c.Rank == 7
	}))
}

// EvaluateJoker — every card of jokerRank is wild. A jokerRank outside 2..14
// (no card turned up) makes nothing wild and the hand classic.
func EvaluateJoker(cards []Card, jokerRank int) EvaluatedHand {
	return evaluateWithWilds(cards, wildMask(cards, func(c Card) bool {
		return jokerRank != 0 && c.Rank == jokerRank
	}))
}

// EvaluateHukam — every card of the hukam suit is wild. A zero suit makes
// nothing wild.
func EvaluateHukam(cards []Card, hukamSuit byte) EvaluatedHand {
	return evaluateWithWilds(cards, wildMask(cards, func(c Card) bool {
		return hukamSuit != 0 && c.Suit == hukamSuit
	}))
}

// EvaluateLowestJoker — the lowest rank in THIS hand is wild, and so is every
// card of that rank in it: holding 3-3-K makes both threes wild, and a trail
// makes all three cards wild. The ace is high, so it is never the lowest card
// of a hand that holds anything else.
func EvaluateLowestJoker(cards []Card) EvaluatedHand {
	lowest := cards[0].Rank
	for _, c := range cards[1:] {
		if c.Rank < lowest {
			lowest = c.Rank
		}
	}
	return evaluateWithWilds(cards, wildMask(cards, func(c Card) bool { return c.Rank == lowest }))
}

// EvaluateHighestJoker — the highest rank in this hand is wild, duplicates of
// it included.
func EvaluateHighestJoker(cards []Card) EvaluatedHand {
	highest := cards[0].Rank
	for _, c := range cards[1:] {
		if c.Rank > highest {
			highest = c.Rank
		}
	}
	return evaluateWithWilds(cards, wildMask(cards, func(c Card) bool { return c.Rank == highest }))
}

// wildMask marks which of the three cards a rule makes wild.
func wildMask(cards []Card, isWild func(Card) bool) [3]bool {
	var mask [3]bool
	for i, c := range cards {
		if i < len(mask) {
			mask[i] = isWild(c)
		}
	}
	return mask
}

// bestPossibleHand is what three wild cards make: a trail of aces. It is the
// only case evaluateWithWilds does not search for — C(52,3) = 22,100 classic
// evaluations to rediscover a constant — and
// TestThreeWildCardsAreWorthWhatTheSearchWouldFind holds it to the search.
var bestPossibleHand = []Card{{Rank: 14, Suit: 's'}, {Rank: 14, Suit: 'h'}, {Rank: 14, Suit: 'd'}}

// evaluateWithWilds scores a hand in which the masked cards are wild: it is
// worth the best classic hand they can complete.
//
// It searches rather than reasons. Each wild may stand for any card of the deck
// that is not one of the hand's own natural cards, no two wilds for the same
// card, and every resulting hand is put to Evaluate; the strongest wins. With
// one wild that is at most 50 evaluations, with two 1,275 — nothing, at a
// showdown of five players. The alternative is a second ranking written in
// terms of "can these two ranks reach a run", and a second ranking is a second
// place for the game to be wrong.
//
// A wild may not duplicate a natural card of the same hand, so the evaluator is
// never shown a hand that could not exist (two aces of spades). It may stand
// for a card another player holds: jokers are per hand, as they are at any
// table these rules are played at.
//
// The result keeps the player's REAL cards in Cards — that is what a reveal
// shows — names the wild ones in Wild, and takes Category, Name and Score from
// the hand they made.
func evaluateWithWilds(cards []Card, wild [3]bool) EvaluatedHand {
	if len(cards) != 3 {
		panic("a Teen Patti hand must be exactly 3 cards")
	}

	naturals := make([]Card, 0, 3)
	wildCodes := make([]string, 0, 3)
	for i, c := range cards {
		if wild[i] {
			wildCodes = append(wildCodes, c.Code())
		} else {
			naturals = append(naturals, c)
		}
	}
	if len(wildCodes) == 0 {
		return Evaluate(cards, EvaluateOptions{})
	}

	var best EvaluatedHand
	if len(naturals) == 0 {
		best = Evaluate(bestPossibleHand, EvaluateOptions{})
	} else {
		best = bestCompletion(naturals, len(wildCodes))
	}
	// best.Cards is the winning candidate in the order it was built: the
	// natural cards, then what the wilds stood for. Dealt back into the
	// player's own order, each wild card takes the next stand-in.
	standIns := best.Cards[len(naturals):]
	playsAs := make([]string, len(cards))
	next := 0
	for i, c := range cards {
		if wild[i] {
			playsAs[i] = standIns[next]
			next++
		} else {
			playsAs[i] = c.Code()
		}
	}
	return EvaluatedHand{
		Category: best.Category,
		Name:     best.Name,
		Score:    best.Score,
		Cards:    CardCodes(cards),
		Wild:     wildCodes,
		PlaysAs:  playsAs,
	}
}

// bestCompletion tries every way of filling `wilds` places beside the natural
// cards and returns the strongest classic hand. The deck is walked in NewDeck's
// fixed order and a later hand must be strictly better to displace an earlier
// one, so the answer is deterministic.
func bestCompletion(naturals []Card, wilds int) EvaluatedHand {
	held := make(map[Card]bool, len(naturals))
	for _, c := range naturals {
		held[c] = true
	}
	pool := make([]Card, 0, 52)
	for _, c := range NewDeck() {
		if !held[c] {
			pool = append(pool, c)
		}
	}

	candidate := make([]Card, 3)
	copy(candidate, naturals)
	var best EvaluatedHand
	found := false
	consider := func() {
		scored := Evaluate(candidate, EvaluateOptions{})
		if !found || Compare(scored, best) > 0 {
			best, found = scored, true
		}
	}

	first := len(naturals)
	for i := 0; i < len(pool); i++ {
		candidate[first] = pool[i]
		if wilds == 1 {
			consider()
			continue
		}
		// Two wilds: unordered pairs, so j starts after i.
		for j := i + 1; j < len(pool); j++ {
			candidate[first+1] = pool[j]
			consider()
		}
	}
	return best
}
