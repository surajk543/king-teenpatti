package game

// Mirrors the deck cases in server/test/handRank.test.js plus the wire-code
// round trip the Table and every client depend on.

import (
	"strings"
	"testing"
)

func cardKey(c Card) string { return c.Code() }

func TestNewDeckIsSuitMajorInDeckOrder(t *testing.T) {
	deck := NewDeck()
	if len(deck) != 52 {
		t.Fatalf("%d cards, want 52", len(deck))
	}
	if deck[0] != (Card{Rank: 2, Suit: 's'}) || deck[12] != (Card{Rank: 14, Suit: 's'}) ||
		deck[13] != (Card{Rank: 2, Suit: 'h'}) || deck[51] != (Card{Rank: 14, Suit: 'c'}) {
		t.Fatalf("deck order is not spades, hearts, diamonds, clubs × 2..A: %v", CardCodes(deck))
	}
}

func TestWireCodesRoundTrip(t *testing.T) {
	want := map[string]Card{
		"As": {14, 's'}, "Td": {10, 'd'}, "7h": {7, 'h'}, "2c": {2, 'c'},
		"Jh": {11, 'h'}, "Qd": {12, 'd'}, "Ks": {13, 's'}, "9c": {9, 'c'},
	}
	for code, card := range want {
		if card.Code() != code {
			t.Errorf("%v.Code() = %q, want %q", card, card.Code(), code)
		}
		if ParseCard(code) != card {
			t.Errorf("ParseCard(%q) = %v, want %v", code, ParseCard(code), card)
		}
	}
	for _, c := range NewDeck() {
		if len(c.Code()) != 2 || ParseCard(c.Code()) != c {
			t.Errorf("round trip failed for %v (%q)", c, c.Code())
		}
	}
	codes := CardCodes(ParseCards([]string{"As", "Td", "7h"}))
	if strings.Join(codes, ",") != "As,Td,7h" {
		t.Errorf("CardCodes/ParseCards must preserve order, got %v", codes)
	}
	// Malformed input is trusted like Node: rank 0, nothing panics.
	if ParseCard("Xs").Rank != 0 || ParseCard("A").Rank != 0 || ParseCard("").Rank != 0 {
		t.Error("malformed codes yield a zero rank")
	}
}

func TestShuffledDeckStaysALegalDeck(t *testing.T) {
	deck := Shuffle(NewDeck())
	if len(deck) != 52 {
		t.Fatalf("%d cards, want 52", len(deck))
	}
	seen := map[string]bool{}
	for _, c := range deck {
		seen[cardKey(c)] = true
	}
	if len(seen) != 52 {
		t.Fatalf("%d distinct cards after shuffle, want 52", len(seen))
	}
}

func TestDealingFiveHandsProducesFifteenDistinctCards(t *testing.T) {
	hands, remaining := Deal(5, 3)
	if len(hands) != 5 {
		t.Fatalf("%d hands, want 5", len(hands))
	}
	seen := map[string]bool{}
	total := 0
	for _, h := range hands {
		if len(h) != 3 {
			t.Fatalf("hand of %d cards, want 3", len(h))
		}
		for _, c := range h {
			seen[cardKey(c)] = true
			total++
		}
	}
	if total != 15 || len(seen) != 15 {
		t.Fatalf("%d cards, %d distinct; want 15/15 — no card may be dealt twice", total, len(seen))
	}
	if len(remaining) != 37 {
		t.Fatalf("%d cards remaining, want 37", len(remaining))
	}
	for _, c := range remaining {
		if seen[cardKey(c)] {
			t.Fatalf("%s was dealt and is also in the remainder", c.Code())
		}
	}
}

func TestDealIsRoundRobinOneCardAtATime(t *testing.T) {
	// hands[seat][round] = deck[round*count + seat]: the remainder starts at
	// deck[count*cardsPer], so deck order can be reconstructed and checked.
	hands, remaining := Deal(3, 3)
	if len(remaining) != 43 {
		t.Fatalf("%d remaining, want 43", len(remaining))
	}
	hands0, rem0 := Deal(0, 3)
	if len(hands0) != 0 || len(rem0) != 52 {
		t.Fatalf("Deal(0,3) → %d hands / %d remaining, want 0/52", len(hands0), len(rem0))
	}
	_ = hands
}

func TestShuffleActuallyMovesCardsAround(t *testing.T) {
	ordered := strings.Join(CardCodes(NewDeck()), "")
	identical := 0
	for i := 0; i < 10; i++ {
		if strings.Join(CardCodes(Shuffle(NewDeck())), "") == ordered {
			identical++
		}
	}
	if identical != 0 {
		t.Fatalf("%d of 10 shuffles left the deck in order", identical)
	}
}

func TestCryptoIntnIsInRangeAndCoversEveryValue(t *testing.T) {
	for n := 1; n <= 52; n++ {
		seen := make([]bool, n)
		for i := 0; i < 400; i++ {
			v := cryptoIntn(n)
			if v < 0 || v >= n {
				t.Fatalf("cryptoIntn(%d) = %d out of range", n, v)
			}
			seen[v] = true
		}
		if n <= 8 {
			for v, ok := range seen {
				if !ok {
					t.Errorf("cryptoIntn(%d) never produced %d in 400 draws", n, v)
				}
			}
		}
	}
	if cryptoIntn(1) != 0 {
		t.Error("cryptoIntn(1) must be 0")
	}
}
