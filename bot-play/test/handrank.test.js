import assert from 'node:assert/strict';
import test from 'node:test';

import { CATEGORY_NAMES, compare, deckCodes, evaluate, strength } from '../src/handrank.js';

const beats = (a, b) => compare(evaluate(a), evaluate(b)) > 0;

test('categories rank trail > pure sequence > sequence > color > pair > high card', () => {
  const ladder = [
    ['2s', '2h', '2d'], // the lowest trail
    ['4h', '3h', '2h'], // the lowest pure sequence
    ['As', 'Kh', 'Qd'], // the highest sequence
    ['Ah', 'Kh', 'Jh'], // color
    ['As', 'Ah', 'Kd'], // pair
    ['As', 'Kh', 'Jd'], // high card
  ];
  for (let i = 0; i < ladder.length - 1; i += 1) {
    assert.ok(beats(ladder[i], ladder[i + 1]), `${evaluate(ladder[i]).name} beats ${evaluate(ladder[i + 1]).name}`);
  }
  assert.deepEqual(ladder.map((h) => evaluate(h).name), [...CATEGORY_NAMES].reverse());
});

test('runs: A-K-Q over A-2-3 over K-Q-J, and K-A-2 is not a run', () => {
  assert.ok(beats(['As', 'Kh', 'Qd'], ['Ah', '2c', '3d']));
  assert.ok(beats(['Ah', '2c', '3d'], ['Ks', 'Qh', 'Jd']));
  assert.ok(beats(['5s', '4h', '3d'], ['4s', '3h', '2d']));
  assert.equal(evaluate(['Ks', 'Ah', '2d']).name, 'High Card');
});

test('suits never break a tie', () => {
  assert.equal(compare(evaluate(['As', 'Kh', '9d']), evaluate(['Ac', 'Kd', '9s'])), 0);
});

test('strength runs from the worst hand in the deck to the best, in showdown order', () => {
  assert.ok(strength(['As', 'Ah', 'Ad']) > 0.999);
  // 5-3-2 offsuit is the worst hand, but sixty suit combinations tie with it,
  // so it sits at half their share rather than at zero.
  assert.ok(strength(['5s', '3h', '2d']) < 0.005);
  const codes = deckCodes();
  for (let n = 0; n < 2000; n += 1) {
    const a = [codes[n % 52], codes[(n * 5 + 1) % 52], codes[(n * 11 + 2) % 52]];
    const b = [codes[(n * 3 + 7) % 52], codes[(n * 13 + 9) % 52], codes[(n * 17 + 20) % 52]];
    if (new Set(a).size < 3 || new Set(b).size < 3) continue;
    const order = Math.sign(compare(evaluate(a), evaluate(b)));
    assert.equal(Math.sign(strength(a) - strength(b)), order, `${a} vs ${b}`);
  }
});
