import test from 'node:test';
import assert from 'node:assert/strict';
import { evaluate, compare, CATEGORY } from '../src/game/handRank.js';
import { parseCard, newDeck, shuffle, deal } from '../src/game/deck.js';

const hand = (...codes) => codes.map(parseCard);
const beats = (winner, loser) => compare(evaluate(hand(...winner)), evaluate(hand(...loser))) > 0;
const ties = (a, b) => compare(evaluate(hand(...a)), evaluate(hand(...b))) === 0;

test('classifies every Teen Patti category', () => {
  assert.equal(evaluate(hand('As', 'Ah', 'Ad')).category, CATEGORY.TRAIL);
  assert.equal(evaluate(hand('As', 'Ks', 'Qs')).category, CATEGORY.PURE_SEQUENCE);
  assert.equal(evaluate(hand('As', 'Kh', 'Qd')).category, CATEGORY.SEQUENCE);
  assert.equal(evaluate(hand('As', '9s', '4s')).category, CATEGORY.COLOR);
  assert.equal(evaluate(hand('As', 'Ah', '4d')).category, CATEGORY.PAIR);
  assert.equal(evaluate(hand('As', '9h', '4d')).category, CATEGORY.HIGH_CARD);
});

test('category ordering: trail > pure sequence > sequence > color > pair > high card', () => {
  const ladder = [
    ['2s', '2h', '2d'], // lowest trail
    ['As', 'Ks', 'Qs'], // best pure sequence
    ['As', 'Kh', 'Qd'], // best sequence
    ['As', 'Ks', 'Js'], // best possible color
    ['As', 'Ah', 'Kd'], // best pair
    ['As', 'Kh', 'Jd'], // best high card
  ];

  for (let i = 0; i < ladder.length - 1; i += 1) {
    assert.ok(beats(ladder[i], ladder[i + 1]), `${ladder[i]} should beat ${ladder[i + 1]}`);
  }
});

test('trails rank by card, ace high', () => {
  assert.ok(beats(['As', 'Ah', 'Ad'], ['Ks', 'Kh', 'Kd']));
  assert.ok(beats(['3s', '3h', '3d'], ['2s', '2h', '2d']));
});

test('sequence order is A-K-Q, then A-2-3, then K-Q-J down to 4-3-2', () => {
  assert.ok(beats(['As', 'Kh', 'Qd'], ['As', '2h', '3d']), 'A-K-Q beats A-2-3');
  assert.ok(beats(['As', '2h', '3d'], ['Ks', 'Qh', 'Jd']), 'A-2-3 beats K-Q-J');
  assert.ok(beats(['Ks', 'Qh', 'Jd'], ['4s', '3h', '2d']), 'K-Q-J beats 4-3-2');
});

test('A-2-3 is recognised as a run in both flavours', () => {
  assert.equal(evaluate(hand('As', '2s', '3s')).category, CATEGORY.PURE_SEQUENCE);
  assert.equal(evaluate(hand('As', '2h', '3d')).category, CATEGORY.SEQUENCE);
  // A-2-4 is not a run.
  assert.equal(evaluate(hand('As', '2h', '4d')).category, CATEGORY.HIGH_CARD);
  // K-A-2 does not wrap around.
  assert.equal(evaluate(hand('Ks', 'Ah', '2d')).category, CATEGORY.HIGH_CARD);
});

test('the ace-low variant demotes A-2-3 to the weakest run', () => {
  const wheel = evaluate(hand('As', '2h', '3d'), { aceLowIsLowest: true });
  const low = evaluate(hand('4s', '3h', '2d'), { aceLowIsLowest: true });
  assert.ok(compare(low, wheel) > 0, '4-3-2 should beat A-2-3 under the variant rule');
});

test('colors compare card by card', () => {
  // Both sides must be genuine colors — K-Q-J of a suit would be a pure sequence.
  assert.ok(beats(['As', '9s', '4s'], ['Kh', 'Qh', '9h']));
  assert.ok(beats(['As', '9s', '5s'], ['Ah', '9h', '4h']));
  assert.ok(ties(['As', '9s', '4s'], ['Ah', '9h', '4h']), 'same ranks, different suits, is an exact tie');
});

test('pairs compare pair rank first, then the kicker', () => {
  assert.ok(beats(['Ks', 'Kh', '2d'], ['Qs', 'Qh', 'Ad']));
  assert.ok(beats(['Ks', 'Kh', 'Ad'], ['Ks', 'Kd', 'Qh']));
  // The pair is found whether it sits high or low in the sorted hand.
  assert.deepEqual(evaluate(hand('As', 'Kh', 'Kd')).score, [CATEGORY.PAIR, 13, 14]);
  assert.deepEqual(evaluate(hand('Ks', 'Kh', '2d')).score, [CATEGORY.PAIR, 13, 2]);
});

test('high cards compare in descending order', () => {
  // K-Q-J mixed would be a sequence, so the loser here is K-Q-9.
  assert.ok(beats(['As', '9h', '4d'], ['Ks', 'Qh', '9d']));
  assert.ok(beats(['As', 'Th', '4d'], ['Ah', '9d', '8s']));
  assert.ok(beats(['As', 'Th', '5d'], ['Ah', 'Td', '4s']));
});

test('rejects hands that are not exactly three cards', () => {
  assert.throws(() => evaluate(hand('As', 'Kh')), /exactly 3 cards/);
  assert.throws(() => evaluate(hand('As', 'Kh', 'Qd', '2c')), /exactly 3 cards/);
});

test('a shuffled deck stays a legal 52-card deck', () => {
  const deck = shuffle(newDeck());
  assert.equal(deck.length, 52);
  assert.equal(new Set(deck.map((card) => `${card.rank}${card.suit}`)).size, 52);
});

test('dealing five hands produces fifteen distinct cards', () => {
  const { hands } = deal(5, 3);
  assert.equal(hands.length, 5);
  const all = hands.flat().map((card) => `${card.rank}${card.suit}`);
  assert.equal(all.length, 15);
  assert.equal(new Set(all).size, 15, 'no card may be dealt twice');
});

test('the shuffle actually moves cards around', () => {
  // A correct shuffle produces a different order essentially every time; ten
  // identical results would mean the shuffle is not shuffling.
  const ordered = newDeck().map((card) => `${card.rank}${card.suit}`).join('');
  let identical = 0;
  for (let i = 0; i < 10; i += 1) {
    if (shuffle(newDeck()).map((card) => `${card.rank}${card.suit}`).join('') === ordered) identical += 1;
  }
  assert.equal(identical, 0);
});
