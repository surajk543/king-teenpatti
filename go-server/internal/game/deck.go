package game

import (
	"crypto/rand"
	"encoding/binary"
)

// Port of server/src/game/deck.js.

// Suit letters, in deck order: spades, hearts, diamonds, clubs.
var Suits = []byte{'s', 'h', 'd', 'c'}

// Ranks 2..14 in deck order; 11=J 12=Q 13=K 14=A.
var Ranks = []int{2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14}

// Card is one playing card. Rank is 2..14 (ace high = 14), Suit one of Suits.
type Card struct {
	Rank int
	Suit byte
}

// rankCodes / codeRanks are deck.js RANK_CODES / CODE_RANKS.
var rankCodes = map[int]byte{
	2: '2', 3: '3', 4: '4', 5: '5', 6: '6', 7: '7', 8: '8', 9: '9',
	10: 'T', 11: 'J', 12: 'Q', 13: 'K', 14: 'A',
}

var codeRanks = func() map[byte]int {
	m := make(map[byte]int, len(rankCodes))
	for rank, code := range rankCodes {
		m[code] = rank
	}
	return m
}()

// Code is the 2-character wire format: rank code + suit letter — "As", "Td",
// "7h" (deck.js cardCode). Every card a client ever sees is one of these.
func (c Card) Code() string {
	return string([]byte{rankCodes[c.Rank], c.Suit})
}

// CardCodes maps a hand to its wire codes, preserving order.
func CardCodes(cards []Card) []string {
	out := make([]string, len(cards))
	for i, c := range cards {
		out[i] = c.Code()
	}
	return out
}

// ParseCard is the inverse of Code. It is only used by tests (forcing a
// deterministic showdown: `seat.cards = codes.map(parseCard)`) and trusts its
// input like Node does: a malformed code yields a zero Rank.
func ParseCard(code string) Card {
	if len(code) != 2 {
		return Card{}
	}
	return Card{Rank: codeRanks[code[0]], Suit: code[1]}
}

// ParseCards maps ParseCard over a slice.
func ParseCards(codes []string) []Card {
	out := make([]Card, len(codes))
	for i, code := range codes {
		out[i] = ParseCard(code)
	}
	return out
}

// NewDeck returns the 52 cards in deck order (suits outer, ranks inner).
func NewDeck() []Card {
	deck := make([]Card, 0, 52)
	for _, suit := range Suits {
		for _, rank := range Ranks {
			deck = append(deck, Card{Rank: rank, Suit: suit})
		}
	}
	return deck
}

// Shuffle is an in-place Fisher–Yates shuffle driven by crypto/rand
// (Node: crypto.randomInt(i+1)). math/rand is explicitly forbidden: its state
// is recoverable from a short run of outputs, which in a chips game means a
// client could predict the deal. Returns the same slice for chaining.
func Shuffle(deck []Card) []Card {
	for i := len(deck) - 1; i > 0; i-- {
		j := cryptoIntn(i + 1)
		deck[i], deck[j] = deck[j], deck[i]
	}
	return deck
}

// cryptoIntn returns a uniformly distributed integer in [0, n) drawn from
// crypto/rand, with rejection sampling so no residue bias creeps in
// (crypto.randomInt is unbiased too). n must be > 0; the deck loop
// guarantees 2 <= n <= 52. A failure of the system CSPRNG is not something a
// chips game can carry on from, so it panics — exactly as crypto.randomInt
// throws in Node.
func cryptoIntn(n int) int {
	if n <= 0 {
		panic("cryptoIntn: n must be positive")
	}
	limit := uint64(n)
	// Largest multiple of limit that fits in a uint64; anything at or above
	// it is rejected so every residue class is equally likely.
	bound := (^uint64(0) / limit) * limit
	var buf [8]byte
	for {
		if _, err := rand.Read(buf[:]); err != nil {
			panic("crypto/rand unavailable: " + err.Error())
		}
		v := binary.LittleEndian.Uint64(buf[:])
		if v < bound {
			return int(v % limit)
		}
	}
}

// Deal shuffles a fresh deck and deals `count` hands of `cardsPer` cards
// one card at a time round the table, as at a real table (deck.js deal):
// hands[seat][round] = deck[round*count + seat]. `remaining` is the rest of
// the deck in order. The Table always calls Deal(len(participants), 3).
func Deal(count, cardsPer int) (hands [][]Card, remaining []Card) {
	if count < 0 {
		count = 0
	}
	if cardsPer < 0 {
		cardsPer = 0
	}
	deck := Shuffle(NewDeck())
	hands = make([][]Card, count)
	for seat := range hands {
		hands[seat] = make([]Card, 0, cardsPer)
	}
	index := 0
	for round := 0; round < cardsPer; round++ {
		for seat := 0; seat < count; seat++ {
			// Node indexes past the end of the deck for count*cardsPer > 52
			// and pushes `undefined`; the Table only ever asks for 5*3 = 15,
			// so stopping at the last card is the same behaviour on every
			// reachable path.
			if index >= len(deck) {
				return hands, deck[len(deck):]
			}
			hands[seat] = append(hands[seat], deck[index])
			index++
		}
	}
	return hands, deck[index:]
}
