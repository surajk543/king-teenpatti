import assert from 'node:assert/strict';
import test from 'node:test';

import { answerSideshow, decide, newHandMemory, raiseAmount } from '../src/brain.js';
import { personaFor } from '../src/persona.js';
import { seededRandom } from '../src/random.js';

/** A turn's options as the server builds them (go-server view.go TurnOptions). */
function optionsFor({ chips = 200_000, stake = 200, blind = false, pot = 1_000, show = false, sideshow = false, maxSteps = 8 } = {}) {
  const base = blind ? stake : stake * 2;
  const steps = [];
  for (let amount = base; amount <= chips && steps.length < maxSteps; amount *= 2) steps.push(amount);
  return {
    canSee: blind,
    canSideshow: sideshow && !blind,
    chaal: steps[0] ?? null,
    raise: steps[1] ?? null,
    raiseSteps: steps,
    maxBet: steps.at(-1) ?? null,
    show: show && steps[0] ? steps[0] : null,
    canPack: true,
    isBlind: blind,
    currentStake: stake,
    chips,
    pot,
  };
}

function viewFor({ cards = [], opponents = 2, blind = false, category = 'seen' } = {}) {
  const seats = [{ userId: 'me', status: 'active' }];
  for (let i = 0; i < opponents; i += 1) seats.push({ userId: `opp${i}`, status: 'active' });
  return { category, seats, you: { cards: blind ? [] : cards, isBlind: blind, status: 'active' } };
}

const STYLES = {
  rock: { aggression: 0.2, tightness: 0.8, bluff: 0.02, blindLove: 0.2 },
  shark: { aggression: 0.75, tightness: 0.6, bluff: 0.1, blindLove: 0.3 },
  maniac: { aggression: 0.92, tightness: 0.2, bluff: 0.22, blindLove: 0.65 },
  station: { aggression: 0.25, tightness: 0.15, bluff: 0.05, blindLove: 0.5 },
  casual: { aggression: 0.5, tightness: 0.45, bluff: 0.08, blindLove: 0.45 },
};
const persona = (style) => ({ ...personaFor(0), ...STYLES[style] });

const TRAIL = ['Ks', 'Kh', 'Kd'];
const RUBBISH = ['7s', '5h', '2d'];

test('every move is one the server offered, and every bet is a rung the bot can pay', () => {
  const rng = seededRandom(42);
  const hands = [TRAIL, RUBBISH, ['Qs', 'Qh', '4d'], ['As', 'Kh', 'Qd'], ['9h', '6h', '2h']];
  for (let n = 0; n < 6000; n += 1) {
    const blind = rng.chance(0.4);
    const options = optionsFor({
      chips: rng.pick([150, 900, 5_000, 200_000, 3_000_000]),
      stake: rng.pick([100, 200, 400, 1_600]),
      blind,
      pot: Math.round(rng.between(400, 60_000)),
      show: rng.chance(0.3),
      sideshow: rng.chance(0.3),
      maxSteps: rng.pick([2, 8]),
    });
    const memory = newHandMemory();
    memory.raisesFaced = Math.floor(rng.between(0, 4));
    const move = decide({
      options,
      view: viewFor({ cards: rng.pick(hands), opponents: 1 + Math.floor(rng.between(0, 4)), blind }),
      me: 'me',
      persona: { ...personaFor(n % 198), ...STYLES[rng.pick(Object.keys(STYLES))] },
      memory,
      rng,
      tilt: rng.next(),
    });
    switch (move.action) {
      case 'see':
        assert.ok(options.canSee, 'see only while blind');
        break;
      case 'show':
        assert.notEqual(options.show, null, 'show only when offered');
        break;
      case 'sideshow':
        assert.ok(options.canSideshow, 'sideshow only when offered');
        break;
      case 'chaal':
        assert.equal(move.amount, options.chaal);
        assert.ok(move.amount <= options.chips);
        break;
      case 'raise':
        assert.ok(options.raiseSteps.includes(move.amount), `raise ${move.amount} is a rung`);
        assert.ok(move.amount >= options.raiseSteps[0] * 2, 'a raise at least doubles the chaal');
        assert.ok(move.amount <= options.chips, 'never more than the stack');
        break;
      case 'pack':
        break;
      default:
        assert.fail(`unknown action ${move.action}`);
    }
  }
});

function tally(cards, style, runs = 3000) {
  const rng = seededRandom(7);
  const counts = { raise: 0, chaal: 0, pack: 0, show: 0, sideshow: 0, see: 0, raised: 0 };
  for (let n = 0; n < runs; n += 1) {
    const move = decide({
      options: optionsFor({ pot: 2_000 }),
      view: viewFor({ cards, opponents: 2 }),
      me: 'me',
      persona: persona(style),
      memory: newHandMemory(),
      rng,
    });
    counts[move.action] += 1;
    if (move.action === 'raise') counts.raised += move.amount;
  }
  return { ...counts, avgRaise: counts.raise ? counts.raised / counts.raise : 0 };
}

test('a strong hand bets and a weak one folds', () => {
  const strong = tally(TRAIL, 'casual');
  const weak = tally(RUBBISH, 'casual');
  assert.ok(strong.raise > weak.raise * 3, `raises: strong ${strong.raise} vs weak ${weak.raise}`);
  assert.ok(weak.pack > strong.pack + 1000, `packs: weak ${weak.pack} vs strong ${strong.pack}`);
  assert.equal(strong.pack, 0, 'nobody folds three kings');
});

test('an aggressive player chaals higher up the ladder than a careful one', () => {
  const maniac = tally(TRAIL, 'maniac');
  const rock = tally(TRAIL, 'rock');
  assert.ok(maniac.avgRaise > rock.avgRaise * 1.5, `average raise: maniac ${maniac.avgRaise} vs rock ${rock.avgRaise}`);
});

test('a raise never exceeds the ladder or the stack', () => {
  const rng = seededRandom(3);
  const options = optionsFor({ chips: 3_000, stake: 200 });
  for (let n = 0; n < 500; n += 1) {
    const amount = raiseAmount(options, persona('maniac'), 1, rng);
    if (amount == null) continue;
    assert.ok(options.raiseSteps.includes(amount) && amount <= 3_000);
  }
  assert.equal(raiseAmount(optionsFor({ chips: 500, stake: 200 }), persona('maniac'), 1, rng), null, 'no raise a 500 stack can pay');
});

test('blind-lovers stay blind longer than careful players', () => {
  const looks = (style) => {
    const rng = seededRandom(19);
    let seen = 0;
    for (let n = 0; n < 3000; n += 1) {
      const move = decide({ options: optionsFor({ blind: true }), view: viewFor({ blind: true }), me: 'me', persona: persona(style), memory: newHandMemory(), rng });
      if (move.action === 'see') seen += 1;
    }
    return seen;
  };
  assert.ok(looks('rock') > looks('maniac'), `first-turn looks: rock ${looks('rock')} vs maniac ${looks('maniac')}`);
});

test('at a blind table every bot prefers blind moves, and still looks under pressure', () => {
  // How many of 3000 bots look on a given blind turn, at one kind of table.
  const looks = (style, category, { blindTurnsAlready = 0, raisesFaced = 0 } = {}) => {
    const rng = seededRandom(31);
    let seen = 0;
    for (let n = 0; n < 3000; n += 1) {
      const memory = newHandMemory();
      memory.blindTurns = blindTurnsAlready;
      memory.raisesFaced = raisesFaced;
      const move = decide({
        options: optionsFor({ blind: true }),
        view: viewFor({ blind: true, category }),
        me: 'me',
        persona: persona(style),
        memory,
        rng,
      });
      if (move.action === 'see') seen += 1;
    }
    return seen;
  };
  for (const style of Object.keys(STYLES)) {
    const atBlind = looks(style, 'blind');
    const atSeen = looks(style, 'seen');
    // Even the most careful bot stays blind on most first turns at a blind table.
    assert.ok(atBlind < 3000 * 0.2, `${style} looks on ${atBlind} of 3000 first turns at a blind table`);
    assert.ok(atBlind * 2 < atSeen, `${style}: blind table ${atBlind} vs seen table ${atSeen}`);
  }
  // Blind bets add up: by the fourth, a casual player has a real reason to look.
  assert.ok(looks('casual', 'blind', { blindTurnsAlready: 3 }) > looks('casual', 'blind'));
  // A table raising hard still makes a bot look sooner.
  assert.ok(looks('casual', 'blind', { raisesFaced: 3 }) > looks('casual', 'blind'));
  // And the personas keep their order: a rock looks sooner than a maniac.
  assert.ok(looks('rock', 'blind') > looks('maniac', 'blind'));
});

test('at a blind table a bot plays most of a hand blind', () => {
  // Four blind turns in a row, as the server allows before turning the cards
  // up: count the blind bets made before the first look.
  const rng = seededRandom(37);
  let blindBets = 0;
  const hands = 2000;
  for (let n = 0; n < hands; n += 1) {
    const memory = newHandMemory();
    for (let turn = 0; turn < 4; turn += 1) {
      const move = decide({
        options: optionsFor({ blind: true }),
        view: viewFor({ blind: true, category: 'blind' }),
        me: 'me',
        persona: persona('casual'),
        memory,
        rng,
      });
      if (move.action === 'see' || move.action === 'pack') break;
      blindBets += 1;
    }
  }
  assert.ok(blindBets / hands > 2.5, `blind bets per hand: ${(blindBets / hands).toFixed(2)} of a possible 4`);
});

test('a middling hand grows impatient as the hand drags on', () => {
  // Ace-king high: worth paying for on the first turn, not for ever. No
  // sideshow on offer, so only the pay-or-fold decision is measured.
  const MIDDLING = ['As', 'Kh', '9d'];
  const quits = (turnsAlready) => {
    const rng = seededRandom(23);
    let out = 0;
    for (let n = 0; n < 3000; n += 1) {
      const memory = newHandMemory();
      memory.seenTurns = turnsAlready;
      const move = decide({
        options: optionsFor({ pot: 6_000 }),
        view: viewFor({ cards: MIDDLING, opponents: 2 }),
        me: 'me',
        persona: persona('casual'),
        memory,
        rng,
      });
      if (move.action === 'pack') out += 1;
    }
    return out;
  };
  const early = quits(0);
  const late = quits(6);
  assert.ok(early < 300, `ace-king stays in on its first turn: packed ${early} of 3000`);
  assert.ok(late > early + 1000, `packs late ${late} vs early ${early}`);
});

test('a strong hand accepts a sideshow far more often than a weak one', () => {
  const rng = seededRandom(11);
  const accepts = (cards) => {
    let yes = 0;
    for (let n = 0; n < 2000; n += 1) {
      if (answerSideshow({ view: viewFor({ cards }), persona: persona('casual'), rng }).answer === true) yes += 1;
    }
    return yes;
  };
  assert.ok(accepts(TRAIL) > accepts(RUBBISH) * 2);
});
