/**
 * An INDEPENDENT five-card poker evaluator, for the parity suite's oracle.
 *
 * Written from the rules, not ported from go-server/internal/poker/eval5.go,
 * so that a mistake in the server's evaluator and a mistake here would have
 * to be the same mistake to agree. It answers the two questions the suite
 * asks: what a five-card hand makes, and which five of a player's cards (hole
 * plus board) are the best — so `best` and `handName` on a reveal can be
 * checked against something the server did not compute.
 *
 * Score is [category, tiebreaks…], compared element by element; the wheel
 * A-2-3-4-5 is a straight with high card 5.
 */

const RANKS = '23456789TJQKA';
const SUITS = 'shdc';

export const NAMES = [
  'High Card', 'Pair', 'Two Pair', 'Three of a Kind', 'Straight', 'Flush', 'Full House', 'Four of a Kind',
  'Straight Flush', 'Royal Flush',
];

export const parse = (code) => {
  const rank = RANKS.indexOf(code[0]) + 2;
  if (rank < 2 || !SUITS.includes(code[1]) || code.length !== 2) throw new Error(`not a card: ${code}`);
  return { rank, suit: code[1], code };
};

/** Scores exactly five card codes. */
export const evaluate5 = (codes) => {
  if (codes.length !== 5) throw new Error('five cards');
  const cards = codes.map(parse);
  const ranks = cards.map((c) => c.rank).sort((a, b) => b - a);
  const flush = cards.every((c) => c.suit === cards[0].suit);
  let straight = 0;
  if (ranks.every((r, i) => i === 0 || r === ranks[i - 1] - 1)) straight = ranks[0];
  else if (ranks.join(',') === '14,5,4,3,2') straight = 5;
  const counts = new Map();
  for (const r of ranks) counts.set(r, (counts.get(r) ?? 0) + 1);
  const groups = [...counts.entries()].sort((a, b) => (b[1] - a[1]) || (b[0] - a[0]));
  const [g0, g1, g2, g3] = groups;
  let category;
  let tiebreak;
  if (straight && flush) {
    category = straight === 14 ? 9 : 8;
    tiebreak = straight === 14 ? [] : [straight];
  } else if (g0[1] === 4) {
    category = 7; tiebreak = [g0[0], g1[0]];
  } else if (g0[1] === 3 && g1[1] === 2) {
    category = 6; tiebreak = [g0[0], g1[0]];
  } else if (flush) {
    category = 5; tiebreak = ranks;
  } else if (straight) {
    category = 4; tiebreak = [straight];
  } else if (g0[1] === 3) {
    category = 3; tiebreak = [g0[0], g1[0], g2[0]];
  } else if (g0[1] === 2 && g1[1] === 2) {
    category = 2; tiebreak = [g0[0], g1[0], g2[0]];
  } else if (g0[1] === 2) {
    category = 1; tiebreak = [g0[0], g1[0], g2[0], g3[0]];
  } else {
    category = 0; tiebreak = ranks;
  }
  return { category, name: NAMES[category], score: [category, ...tiebreak] };
};

export const compare = (a, b) => {
  const n = Math.max(a.score.length, b.score.length);
  for (let i = 0; i < n; i += 1) {
    const d = (a.score[i] ?? 0) - (b.score[i] ?? 0);
    if (d !== 0) return d;
  }
  return 0;
};

const combos = (items, k) => {
  const out = [];
  const walk = (start, picked) => {
    if (picked.length === k) { out.push([...picked]); return; }
    for (let i = start; i < items.length; i += 1) {
      picked.push(items[i]);
      walk(i + 1, picked);
      picked.pop();
    }
  };
  walk(0, []);
  return out;
};

/** The strongest five of any number of card codes (Hold'em: hole + board). */
export const bestOf = (codes) => {
  let best = null;
  for (const pick of combos(codes, 5)) {
    const h = evaluate5(pick);
    if (!best || compare(h, best.hand) > 0) best = { hand: h, cards: pick };
  }
  return best;
};

/** Omaha: exactly two of the four hole cards and three of the board. */
export const bestOmaha = (hole, board) => {
  let best = null;
  for (const two of combos(hole, 2)) {
    for (const three of combos(board, 3)) {
      const pick = [...two, ...three];
      const h = evaluate5(pick);
      if (!best || compare(h, best.hand) > 0) best = { hand: h, cards: pick };
    }
  }
  return best;
};

/**
 * 3-Card Poker's ranking, from the rules: Straight Flush > Three of a Kind >
 * Straight > Flush > Pair > High Card; A-K-Q the best straight and A-2-3 the
 * worst. Independent of bot-play's Teen Patti port.
 */
export const NAMES3 = ['High Card', 'Pair', 'Flush', 'Straight', 'Three of a Kind', 'Straight Flush'];
export const evaluate3 = (codes) => {
  if (codes.length !== 3) throw new Error('three cards');
  const cards = codes.map(parse);
  const ranks = cards.map((c) => c.rank).sort((a, b) => b - a);
  const flush = cards.every((c) => c.suit === cards[0].suit);
  const [h, m, l] = ranks;
  let straightHigh = 0;
  if (h - m === 1 && m - l === 1) straightHigh = h;
  else if (h === 14 && m === 3 && l === 2) straightHigh = 3; // A-2-3: the lowest, under 4-3-2
  let category;
  let tiebreak;
  if (straightHigh && flush) { category = 5; tiebreak = [straightHigh]; }
  else if (h === m && m === l) { category = 4; tiebreak = [h]; }
  else if (straightHigh) { category = 3; tiebreak = [straightHigh]; }
  else if (flush) { category = 2; tiebreak = ranks; }
  else if (h === m || m === l) { category = 1; tiebreak = [m, h === m ? l : h]; }
  else { category = 0; tiebreak = ranks; }
  return { category, name: NAMES3[category], score: [category, ...tiebreak] };
};

/** The dealer plays with queen-high or better. */
export const dealerQualifies = (hand) => hand.category > 0 || hand.score[1] >= 12;
