/**
 * Teen Patti hand ranking.
 *
 * A line-for-line port of go-server/internal/game/handrank.go (Evaluate and
 * Compare), checked against the server's own scores for all 22,100 possible
 * hands — so a bot judges its cards exactly the way the showdown will.
 *
 * On top of that it knows where every hand sits among all the others, which
 * is what a bot's sense of "how good is this" is built from.
 */

const RANKS = '23456789TJQKA';
const SUITS = 'shdc';

export const CATEGORY_NAMES = ['High Card', 'Pair', 'Color', 'Sequence', 'Pure Sequence', 'Trail'];
export const HIGH_CARD = 0;
export const PAIR = 1;
export const COLOR = 2;
export const SEQUENCE = 3;
export const PURE_SEQUENCE = 4;
export const TRAIL = 5;

/** Every card code in the deck, "2s" … "Ac" — the server's wire format. */
export function deckCodes() {
  const codes = [];
  for (const rank of RANKS) for (const suit of SUITS) codes.push(rank + suit);
  return codes;
}

function parseCard(code) {
  const rank = RANKS.indexOf(code?.[0]);
  if (rank < 0 || !SUITS.includes(code[1])) throw new Error(`not a card: ${code}`);
  return { rank: rank + 2, suit: code[1] };
}

/** A-2-3 or three consecutive ranks (descending); K-A-2 never wraps. */
function isRun(high, mid, low) {
  if (high === 14 && mid === 3 && low === 2) return true;
  return high - mid === 1 && mid - low === 1;
}

/** A doubled scale so A-2-3 slots in: A-K-Q 28 > A-2-3 27 > K-Q-J 26 > … > 4-3-2 8. */
function runStrength(high, mid, low) {
  if (high === 14 && mid === 3 && low === 2) return 27;
  return 2 * high;
}

/** `{category, name, score}` for three card codes; scores compare element by element. */
export function evaluate(codes) {
  if (!Array.isArray(codes) || codes.length !== 3) throw new Error('a hand is exactly 3 cards');
  const cards = codes.map(parseCard);
  const [high, mid, low] = cards.map((c) => c.rank).sort((a, b) => b - a);
  const sameSuit = cards[0].suit === cards[1].suit && cards[1].suit === cards[2].suit;

  let category;
  let tiebreak;
  if (high === mid && mid === low) {
    category = TRAIL;
    tiebreak = [high];
  } else if (isRun(high, mid, low)) {
    category = sameSuit ? PURE_SEQUENCE : SEQUENCE;
    tiebreak = [runStrength(high, mid, low)];
  } else if (sameSuit) {
    category = COLOR;
    tiebreak = [high, mid, low];
  } else if (high === mid || mid === low) {
    category = PAIR;
    tiebreak = [mid, high === mid ? low : high];
  } else {
    category = HIGH_CARD;
    tiebreak = [high, mid, low];
  }
  return { category, name: CATEGORY_NAMES[category], score: [category, ...tiebreak] };
}

/** > 0 when a wins, < 0 when b wins, 0 on an exact tie. Suits never break ties. */
export function compare(a, b) {
  const length = Math.max(a.score.length, b.score.length);
  for (let i = 0; i < length; i += 1) {
    const diff = (a.score[i] ?? 0) - (b.score[i] ?? 0);
    if (diff !== 0) return diff;
  }
  return 0;
}

let percentiles = null;

function percentileTable() {
  if (percentiles) return percentiles;
  const codes = deckCodes();
  const hands = [];
  for (let i = 0; i < codes.length; i += 1) {
    for (let j = i + 1; j < codes.length; j += 1) {
      for (let k = j + 1; k < codes.length; k += 1) hands.push(evaluate([codes[i], codes[j], codes[k]]));
    }
  }
  hands.sort(compare);
  percentiles = new Map();
  let start = 0;
  while (start < hands.length) {
    let end = start + 1;
    while (end < hands.length && compare(hands[end], hands[start]) === 0) end += 1;
    percentiles.set(hands[start].score.join(','), (start + (end - start) / 2) / hands.length);
    start = end;
  }
  return percentiles;
}

/** 0 (the worst hand in the deck) … 1 (the best): the share of all hands this one beats. */
export function strength(codes) {
  return percentileTable().get(evaluate(codes).score.join(','));
}
