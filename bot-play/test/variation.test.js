/**
 * Variation tables: choosing the hand's variation, and choosing which three
 * of five cards play (§6.4).
 *
 * Both are pure functions of what the server sent, so they are tested here
 * rather than against a socket. The rules that matter:
 *
 *   * a bot names only what the SERVER offered this hand — FIVE_CARD is not
 *     on every hand's menu, and naming it when it is absent is refused;
 *   * `bestThreeOf` must agree with the server's `EvaluateBest`, including
 *     which of two equally strong combinations it names;
 *   * the three chosen are returned in the order HELD, which is what
 *     `game:selectCards` echoes back.
 */
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { chooseVariation, choosePlayedCards, VARIATIONS } from '../src/brain.js';
import { bestThreeOf, compare, evaluate, threeCardCombinations } from '../src/handrank.js';
import { personaFor } from '../src/persona.js';

/** A deterministic stand-in for the fleet's rng: fixed rolls, no chances taken. */
const rngWith = (value, chance = false) => ({ next: () => value, chance: () => chance });

describe('choosing the variation', () => {
  it('only ever names something the server offered', () => {
    const menu = ['MUFLIS', 'AK47', 'JOKER'];
    for (let i = 0; i < 200; i += 1) {
      const choice = chooseVariation({
        options: menu,
        persona: personaFor(i),
        rng: { next: () => Math.random(), chance: () => false },
      });
      assert.ok(menu.includes(choice), `${choice} was not on the menu`);
    }
  });

  it('never invents FIVE_CARD when the deck could not cover it', () => {
    // The server leaves FIVE_CARD off a hand it cannot deal; naming it then
    // is invalid_variation, so a bot that guessed from its own list would
    // spend that hand being refused.
    const menu = VARIATIONS.filter((v) => v !== 'FIVE_CARD');
    const seen = new Set();
    for (let i = 0; i < 300; i += 1) {
      seen.add(chooseVariation({
        options: menu,
        persona: personaFor(i),
        rng: { next: () => Math.random(), chance: () => false },
      }));
    }
    assert.ok(!seen.has('FIVE_CARD'));
    assert.ok(seen.size > 1, 'the fleet should not settle on one variation');
  });

  it('says nothing when there is no menu', () => {
    const persona = personaFor(1);
    const rng = rngWith(0.5);
    assert.equal(chooseVariation({ options: [], persona, rng }), null);
    assert.equal(chooseVariation({ options: undefined, persona, rng }), null);
    assert.equal(chooseVariation({ options: [null, '', 7], persona, rng }), null);
  });

  it('spreads across all seven over a fleet, rather than welding a seat to one', () => {
    const counts = new Map();
    for (let i = 0; i < 400; i += 1) {
      const choice = chooseVariation({
        options: VARIATIONS,
        persona: personaFor(i),
        rng: { next: () => Math.random(), chance: () => false },
      });
      counts.set(choice, (counts.get(choice) ?? 0) + 1);
    }
    assert.equal(counts.size, VARIATIONS.length, 'every variation should get called sometimes');
    // No variation should dominate: the persona lean is meant to be mild.
    for (const [variation, n] of counts) {
      assert.ok(n < 400 * 0.4, `${variation} was called ${n}/400 times — the lean is too strong`);
    }
  });
});

describe('choosing three of five', () => {
  it('finds the best three, in the order held', () => {
    // A flush in spades hiding among two off-suit high cards.
    const held = ['Ah', 'Ks', '7s', 'Kd', '2s'];
    const picked = choosePlayedCards({ cards: held, persona: personaFor(3), rng: rngWith(0.9) });
    assert.deepEqual(picked, ['Ks', '7s', '2s'], 'the three spades play, in dealt order');
  });

  it('agrees with an exhaustive search over random hands', () => {
    const ranks = '23456789TJQKA'.split('');
    const suits = 's h d c'.split(' ');
    const deck = [];
    for (const r of ranks) for (const s of suits) deck.push(`${r}${s}`);

    for (let trial = 0; trial < 300; trial += 1) {
      const hand = [];
      const pool = [...deck];
      for (let n = 0; n < 5; n += 1) hand.push(...pool.splice(Math.floor(Math.random() * pool.length), 1));

      const best = bestThreeOf(hand);
      // Nothing among the ten combinations beats what bestThreeOf named.
      for (const combo of threeCardCombinations(hand)) {
        assert.ok(compare(evaluate(combo), best.hand) <= 0, `${combo} beat ${best.cards}`);
      }
    }
  });

  it('keeps the FIRST of equally strong combinations, as the server does', () => {
    // Two identical-strength high-card hands; variation.go walks combinations
    // in index order and requires a later one to be STRICTLY better, so the
    // earliest wins. A bot that broke ties the other way would name a
    // different three from the server's bestPossible for no visible reason.
    const held = ['Ah', 'Kd', 'Qs', 'Ac', 'Kh'];
    const first = bestThreeOf(held);
    const second = bestThreeOf(held);
    assert.deepEqual(first.cards, second.cards, 'the choice must be deterministic');
    const combos = threeCardCombinations(held);
    const earliest = combos.find((c) => compare(evaluate(c), first.hand) === 0);
    assert.deepEqual(first.cards, earliest);
  });

  it('hands back three cards even when it slips', () => {
    // rng.chance true = the distracted pick. It must still be three of the
    // player's OWN cards, or the server refuses it as invalid_pick.
    const held = ['Ah', 'Ks', '7s', 'Kd', '2s'];
    const picked = choosePlayedCards({
      cards: held,
      persona: personaFor(5),
      rng: { next: () => 0.5, chance: () => true },
    });
    assert.equal(picked.length, 3);
    assert.equal(new Set(picked).size, 3, 'no card named twice');
    for (const card of picked) assert.ok(held.includes(card), `${card} is not in hand`);
  });

  it('passes a three-card hand straight through', () => {
    const held = ['Ah', 'Ks', '7s'];
    const picked = choosePlayedCards({ cards: held, persona: personaFor(1), rng: rngWith(0.5) });
    assert.deepEqual(picked, held);
    assert.deepEqual(choosePlayedCards({ cards: [], persona: personaFor(1), rng: rngWith(0.5) }), []);
    assert.deepEqual(choosePlayedCards({ cards: null, persona: personaFor(1), rng: rngWith(0.5) }), []);
  });
});
