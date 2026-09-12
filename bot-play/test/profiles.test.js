import assert from 'node:assert/strict';
import test from 'node:test';

import { profileFor, strideFor } from '../src/profiles.js';

/** Catalogue ids as the server hands them over: integers, in display order. */
const catalogue = (n) => Array.from({ length: n }, (_, i) => i + 1);

test('every picture in the catalogue gets worn, whatever size it is', () => {
  // The catalogue is rows the owner edits, not a fixed folder, so the number of
  // FREE pictures can be anything. A stride sharing a factor with that number
  // walks a cycle instead of the whole list: the hardcoded 7 this replaced put
  // ALL two hundred bots on one face at seven free pictures, and on two faces
  // at fourteen.
  for (let n = 1; n <= 60; n += 1) {
    const ids = catalogue(n);
    const worn = new Set(Array.from({ length: 198 }, (_, i) => profileFor(i, ids)));
    assert.equal(worn.size, n, `${n} pictures should all be used, got ${worn.size}`);
  }
});

test('the stride is coprime with the catalogue size', () => {
  const gcd = (a, b) => (b === 0 ? a : gcd(b, a % b));
  for (let n = 1; n <= 60; n += 1) {
    assert.equal(gcd(strideFor(n), n), 1, `stride ${strideFor(n)} shares a factor with ${n}`);
  }
});

test('neighbouring seats do not wear the same picture', () => {
  // Bots are seated in index order, so adjacent indices land at adjacent seats.
  // This is the whole reason there is a stride at all rather than index % n.
  for (const n of [9, 15, 16, 20]) {
    const ids = catalogue(n);
    for (let i = 0; i < 197; i += 1) {
      assert.notEqual(profileFor(i, ids), profileFor(i + 1, ids),
        `seats ${i} and ${i + 1} share a face with ${n} pictures`);
    }
  }
});

test('a bot keeps the same face across runs, and copes with an empty catalogue', () => {
  const ids = catalogue(9);
  assert.equal(profileFor(42, ids), profileFor(42, ids));
  assert.equal(profileFor(0, []), null, 'no catalogue means no picture, not a crash');
});
