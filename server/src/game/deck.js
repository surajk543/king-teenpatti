import { randomInt } from 'node:crypto';

export const SUITS = ['s', 'h', 'd', 'c']; // spades, hearts, diamonds, clubs
export const RANKS = [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]; // 11=J 12=Q 13=K 14=A

const RANK_CODES = {
  2: '2', 3: '3', 4: '4', 5: '5', 6: '6', 7: '7', 8: '8', 9: '9',
  10: 'T', 11: 'J', 12: 'Q', 13: 'K', 14: 'A',
};

const CODE_RANKS = Object.fromEntries(Object.entries(RANK_CODES).map(([rank, code]) => [code, Number(rank)]));

/** Wire format for a card: rank code + suit letter, e.g. "As", "Td", "7h". */
export const cardCode = (card) => `${RANK_CODES[card.rank]}${card.suit}`;

export const parseCard = (code) => ({
  rank: CODE_RANKS[code[0]],
  suit: code[1],
});

export const newDeck = () => {
  const deck = [];
  for (const suit of SUITS) {
    for (const rank of RANKS) deck.push({ rank, suit });
  }
  return deck;
};

/**
 * Fisher–Yates shuffle driven by `crypto.randomInt`.
 *
 * `Math.random` is explicitly avoided: its state is recoverable from a short
 * run of outputs, which in a chips game means a client could predict the deal.
 */
export function shuffle(deck) {
  for (let i = deck.length - 1; i > 0; i -= 1) {
    const j = randomInt(i + 1);
    [deck[i], deck[j]] = [deck[j], deck[i]];
  }
  return deck;
}

/** Deals `count` hands of `cardsPer` cards each, one card at a time, as at a real table. */
export function deal(count, cardsPer = 3) {
  const deck = shuffle(newDeck());
  const hands = Array.from({ length: count }, () => []);
  let index = 0;
  for (let round = 0; round < cardsPer; round += 1) {
    for (let seat = 0; seat < count; seat += 1) {
      hands[seat].push(deck[index]);
      index += 1;
    }
  }
  return { hands, remaining: deck.slice(index) };
}

export default { SUITS, RANKS, newDeck, shuffle, deal, cardCode, parseCard };
