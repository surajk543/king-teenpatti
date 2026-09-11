import assert from 'node:assert/strict';
import test from 'node:test';

import { MOODS, moodFor, pickLine, tableAllowsChat } from '../src/chat.js';
import { personaFor, restMs, sessionHands, thinkTime } from '../src/persona.js';

test('a persona is the same person on every run, with every trait in range', () => {
  assert.deepEqual(personaFor(17), personaFor(17));
  const styles = new Set();
  for (let index = 0; index < 198; index += 1) {
    const p = personaFor(index);
    styles.add(p.style);
    for (const key of ['tightness', 'aggression', 'blindLove']) assert.ok(p[key] >= 0 && p[key] <= 1, `${key} ${p[key]}`);
    assert.ok(p.bluff >= 0.01 && p.bluff <= 0.21);
    assert.ok(p.stayHands >= 8 && p.stayHands <= 40);
    assert.ok(p.restMinutes >= 5 && p.restMinutes <= 45);
  }
  assert.deepEqual([...styles].sort(), ['casual', 'maniac', 'rock', 'shark', 'station'], 'the fleet has every kind of player');
});

test('sittings and rests vary but stay sensible', () => {
  const p = personaFor(3);
  for (let n = 0; n < 500; n += 1) {
    assert.ok(sessionHands(p, { mean: 20 }) >= 3);
    const rest = restMs(p, { meanMinutes: 25 });
    assert.ok(rest >= 15_000 && rest <= 2 * 60 * 60_000, `rest ${rest}`);
  }
  assert.ok(sessionHands(p, { mean: 4 }) < sessionHands({ ...p, stayHands: 40 }, { mean: 60 }));
});

test('think time never eats the 25-second turn clock', () => {
  for (let index = 0; index < 198; index += 1) {
    const ms = thinkTime(personaFor(index), { potRatio: 10, heavy: true });
    assert.ok(ms > 0 && ms <= 20_000, `${ms}`);
  }
});

test('every mood has a line within the server limit, and names are filled in', () => {
  for (const mood of MOODS) {
    const line = pickLine(`test-${mood}`, mood, { name: 'Asha' });
    assert.ok(line && line.length <= 140, `${mood}: ${line}`);
    assert.ok(!line.includes('{name}'), line);
  }
  assert.equal(moodFor({ won: true, pot: 2_400, boot: 200 }), 'wonBig');
  assert.equal(moodFor({ won: false, pot: 400, boot: 200 }), 'lostSmall');
});

test('nobody says the same thing twice running', () => {
  let previous = null;
  for (let n = 0; n < 200; n += 1) {
    const line = pickLine('repeat-check', 'greeting');
    if (line) assert.notEqual(line, previous);
    previous = line ?? previous;
  }
});

test('a table is rationed: a gap between lines and a cap per minute', () => {
  const t0 = 1_000_000;
  assert.ok(tableAllowsChat('room-a', t0));
  assert.equal(tableAllowsChat('room-a', t0 + 2_000), false, 'too soon after the last line');
  assert.ok(tableAllowsChat('room-b', t0 + 2_000), 'another table has its own budget');
  let allowed = 1;
  for (let s = 7; s < 60; s += 7) if (tableAllowsChat('room-a', t0 + s * 1000)) allowed += 1;
  assert.ok(allowed <= 6, `at most six lines a minute, got ${allowed}`);
  assert.equal(tableAllowsChat(null, t0), false);
});
