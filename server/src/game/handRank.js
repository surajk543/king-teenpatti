import { cardCode } from './deck.js';

/**
 * Teen Patti hand categories, high to low. The numeric value is the primary
 * comparison key, so a bigger number always beats a smaller one.
 */
export const CATEGORY = {
  HIGH_CARD: 0,
  PAIR: 1,
  COLOR: 2, // flush — three of a suit that is not a run
  SEQUENCE: 3, // run — three consecutive ranks, mixed suits
  PURE_SEQUENCE: 4, // straight flush
  TRAIL: 5, // trio / set — three of a kind
};

export const CATEGORY_NAMES = {
  [CATEGORY.HIGH_CARD]: 'High Card',
  [CATEGORY.PAIR]: 'Pair',
  [CATEGORY.COLOR]: 'Color',
  [CATEGORY.SEQUENCE]: 'Sequence',
  [CATEGORY.PURE_SEQUENCE]: 'Pure Sequence',
  [CATEGORY.TRAIL]: 'Trail',
};

/**
 * Ranked strength of a run, on a doubled scale so A-2-3 can slot between A-K-Q
 * and K-Q-J without fractions:
 *
 *   A-K-Q = 28  >  A-2-3 = 27  >  K-Q-J = 26  >  ...  >  4-3-2 = 8
 *
 * This is the standard Teen Patti ordering (the ace plays high in A-K-Q and low
 * in A-2-3, and A-2-3 outranks every run below A-K-Q). Set `aceLowIsLowest` on
 * `evaluate` to fall back to the variant where A-2-3 is the weakest run.
 */
const runStrength = (ranks, aceLowIsLowest) => {
  const [high, mid, low] = ranks; // sorted descending
  if (high === 14 && mid === 3 && low === 2) return aceLowIsLowest ? 5 : 2 * 14 - 1;
  return 2 * high;
};

const isRun = (ranks) => {
  const [high, mid, low] = ranks;
  if (high === 14 && mid === 3 && low === 2) return true; // A-2-3 wheel
  return high - mid === 1 && mid - low === 1;
};

/**
 * Scores a 3-card hand into a comparable descriptor.
 *
 * `score` is an array compared element by element: `[category, ...tiebreakers]`.
 * Longer/shorter arrays never mix because the category always matches first.
 */
export function evaluate(cards, { aceLowIsLowest = false } = {}) {
  if (!Array.isArray(cards) || cards.length !== 3) {
    throw new Error('a Teen Patti hand must be exactly 3 cards');
  }

  const ranks = cards.map((card) => card.rank).sort((a, b) => b - a);
  const suits = cards.map((card) => card.suit);
  const sameSuit = suits[0] === suits[1] && suits[1] === suits[2];
  const [high, mid, low] = ranks;

  let category;
  let tiebreak;

  if (high === mid && mid === low) {
    category = CATEGORY.TRAIL;
    tiebreak = [high];
  } else if (isRun(ranks)) {
    category = sameSuit ? CATEGORY.PURE_SEQUENCE : CATEGORY.SEQUENCE;
    tiebreak = [runStrength(ranks, aceLowIsLowest)];
  } else if (sameSuit) {
    category = CATEGORY.COLOR;
    tiebreak = [high, mid, low];
  } else if (high === mid || mid === low) {
    category = CATEGORY.PAIR;
    // mid is always part of the pair; the remaining card is the kicker.
    const pairRank = mid;
    const kicker = high === mid ? low : high;
    tiebreak = [pairRank, kicker];
  } else {
    category = CATEGORY.HIGH_CARD;
    tiebreak = [high, mid, low];
  }

  return {
    category,
    name: CATEGORY_NAMES[category],
    score: [category, ...tiebreak],
    cards: cards.map(cardCode),
  };
}

/**
 * Compares two evaluated hands.
 * Returns > 0 when `a` wins, < 0 when `b` wins, 0 on an exact tie.
 */
export function compare(a, b) {
  const length = Math.max(a.score.length, b.score.length);
  for (let i = 0; i < length; i += 1) {
    const diff = (a.score[i] ?? 0) - (b.score[i] ?? 0);
    if (diff !== 0) return diff;
  }
  return 0;
}

/**
 * Picks the single winner of a showdown.
 *
 * `contenders` is `[{ key, cards }]`. Exact ties are broken by `tieBreakOrder`
 * — a list of keys, earliest wins — which the table fills with the standard
 * rule: a player who pays for a show cannot win a tie against the player they
 * called, and in a multi-way showdown the seat nearest the dealer's left wins.
 */
export function pickWinner(contenders, { tieBreakOrder = [], options } = {}) {
  if (contenders.length === 0) return null;

  const scored = contenders.map((entry) => ({ ...entry, hand: evaluate(entry.cards, options) }));

  let best = scored[0];
  let tied = [best];

  for (const candidate of scored.slice(1)) {
    const diff = compare(candidate.hand, best.hand);
    if (diff > 0) {
      best = candidate;
      tied = [candidate];
    } else if (diff === 0) {
      tied.push(candidate);
    }
  }

  if (tied.length > 1) {
    const rank = (key) => {
      const index = tieBreakOrder.indexOf(key);
      return index === -1 ? Number.MAX_SAFE_INTEGER : index;
    };
    tied.sort((x, y) => rank(x.key) - rank(y.key));
    best = tied[0];
  }

  return { key: best.key, hand: best.hand, wasTie: tied.length > 1 };
}

export default { CATEGORY, CATEGORY_NAMES, evaluate, compare, pickWinner };
