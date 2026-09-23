/**
 * Variation Teen Patti over the socket (Go only; owner, 18 Sep 2026): the
 * third table category. It bets exactly as a seen table does; the one
 * difference is that every hand opens with a server-timed window in which the
 * player who would have acted first picks one of seven variations, and the
 * server picks MUFLIS if they do not. The seventh, FIVE_CARD (5-Card Teen
 * Patti), is the one that changes how many cards a player HOLDS: every hand is
 * still dealt three, the server tops each up to five the moment it is chosen,
 * and the server — never the player, never the client — finds the best three.
 *
 * What is pinned here is the wire: the `variation` block on room:state (the
 * source of truth — a reconnect has nothing else), the two announcements that
 * only repeat it, who may answer and how everyone else is refused, that no
 * move but `see` is taken while the window is open, that the chooser then gets
 * an ordinary fresh turn, what the reveals gain — and that a seen table's wire
 * carries none of it. Cards are random, so which hand a variation makes the
 * best is the Go unit tests' business (internal/game/variation_test.go), not
 * this suite's: a reveal is checked for shape and for invariants only.
 *
 * Profile assumptions (tools/parity.mjs): this ONE file runs against two
 * servers, because the window's length is read once at start. "variation" has
 * a 60 s window and 60 s clocks, so nothing here can be blamed on a timeout;
 * "variation-timeout" has an 800 ms window, so the server is seen choosing.
 * Each test belongs to one of them and is skipped on the other.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  guestLogin, openClient, closeAll, closeOpenClients, stakeCounter, dealtTable, profile, pause,
  assertKeys, assertOrder, CARD_CODE, HAND_NAMES, SNAPSHOT_KEYS, VARIATION_SNAPSHOT_KEYS, VARIATION_KEYS, VARIATIONS,
  THREE_CARD_VARIATIONS, YOU_HAND_KEYS, YOU_HAND_PICKING_KEYS, YOU_HAND_PICKED_KEYS, OPTIONS_KEYS,
} from './lib/harness.mjs';
import { closeDb } from './lib/db.mjs';
// An independent oracle for the three-card ranking: bot-play's port of
// handrank.go, verified there against all 22,100 hands. Used only to check that
// the three cards the server says it counted really are the best of the five.
import { evaluate, compare } from '../../bot-play/src/handrank.js';

test.after(async () => {
  await closeOpenClients();
  await closeDb();
});

const uniqueStake = stakeCounter(7000);

/** Which server this run is talking to: the window that stays open, or the one that lapses. */
const windowStaysOpen = profile.variationSelectTimeoutMs >= 10000;
const held = { skip: windowStaysOpen ? false : 'needs the profile whose variation window stays open' };
const lapsing = { skip: windowStaysOpen ? 'needs the profile whose variation window lapses' : false };

/** The refusal also arrives as a game:error with the same code and message. */
const expectError = async (client, ack) => {
  const error = await client.wait('game:error', (e) => e.code === ack.code && e.message === ack.message, 2000);
  assert.deepEqual(error, { code: ack.code, message: ack.message });
};

const REFUSALS = {
  not_selecting: { ok: false, code: 'not_selecting', message: 'It is not your turn to choose the variation' },
  invalid_variation: { ok: false, code: 'invalid_variation', message: 'That is not a variation this table offers' },
  variation_already_selected: { ok: false, code: 'variation_already_selected', message: 'The variation has already been chosen' },
  variation_pending: { ok: false, code: 'variation_pending', message: 'The variation is still being chosen' },
  no_variation: { ok: false, code: 'no_variation', message: 'This table does not play variations' },
};

/**
 * Seats `count` fresh guests at a variation table of their own and waits for
 * the deal. harness.dealtTable cannot be used here: it waits for a betting
 * state with somebody on turn, and at a variation table nobody is until the
 * window closes. `wantOpen: false` (the lapsing profile) waits for the deal
 * only, since the window may already have closed by the time anyone looks.
 */
const variationTable = async (tag, { count = 2, wantOpen = true } = {}) => {
  const bootAmount = uniqueStake();
  const entries = [];
  for (let i = 0; i < count; i += 1) {
    const account = await guestLogin(`device-parity-variation-${tag}-${i}`, `${tag}${i}`);
    const client = await openClient(account.token);
    const ack = await client.emit('room:quickJoin', { bootAmount, category: 'variation' });
    assert.equal(ack.ok, true, `quickJoin for ${tag}${i}: ${JSON.stringify(ack)}`);
    assert.equal(ack.category, 'variation');
    entries.push({ account, user: account.user, client });
  }
  const clients = entries.map((entry) => entry.client);
  const joined = clients[0].last('ack:room:quickJoin');
  const started = await clients[0].wait('game:handStarted', (p) => p.participants.length === count, 6000);
  for (const client of clients) {
    await client.wait('room:state', (p) => p.handNo === started.handNo && p.variation
      && (wantOpen ? p.variation.selecting === true : true), 6000);
  }
  const chooserId = clients[0].state().variation.userId;
  const chooser = entries.find((entry) => entry.user.id === chooserId);
  const others = entries.filter((entry) => entry.user.id !== chooserId);
  assert.ok(chooser, 'the chooser is one of the seated players');
  return { bootAmount, entries, clients, joined, started, chooser, others, other: others[0], roomId: joined.roomId };
};

/** The window closed and the table says so: selected set, somebody on turn. */
const waitClosed = (client, waitMs = 4000) =>
  client.waitState((p) => p.variation && p.variation.selecting === false && p.turn?.userId, waitMs);


/** Chaals round a two-player table until the server offers a show, takes it, and hands back the game:showdown. */
const playToShowdown = async (chooser, other) => {
  const byId = { [chooser.user.id]: chooser.client, [other.user.id]: other.client };
  for (let move = 0; move < 12; move += 1) {
    const turnId = chooser.client.state().turn.userId;
    const client = byId[turnId];
    const state = await client.waitState((p) => p.turn?.userId === turnId && p.you.options);
    const mark = chooser.client.mark();
    if (state.you.options.show !== null) {
      const ack = await client.emit('game:action', { action: 'show' });
      assert.equal(ack.ok, true, JSON.stringify(ack));
      return chooser.client.waitNext('game:showdown', () => true, 4000, mark);
    }
    const ack = await client.emit('game:action', { action: 'chaal', amount: state.you.options.chaal });
    assert.equal(ack.ok, true, JSON.stringify(ack));
    await chooser.client.waitNext('room:state', (p) => p.turn?.userId !== turnId || p.state !== 'betting', 4000, mark);
  }
  return null;
};

/** Every string anywhere inside `value` that is a card code. */
const cardCodesIn = (value, found = []) => {
  if (typeof value === 'string') {
    if (CARD_CODE.test(value)) found.push(value);
  } else if (value && typeof value === 'object') {
    for (const inner of Object.values(value)) cardCodesIn(inner, found);
  }
  return found;
};

/** The ten ways of taking three cards from five, as index triples in ascending order. */
const THREES_OF_FIVE = [];
for (let a = 0; a < 5; a += 1) for (let b = a + 1; b < 5; b += 1) for (let c = b + 1; c < 5; c += 1) THREES_OF_FIVE.push([a, b, c]);

/**
 * `best` is the three of `cards` that PLAY, in the order they are held (owner,
 * 19 Sep 2026: the player chooses them; the server no longer picks the
 * strongest). `want` names which three to expect — the first three where the
 * window lapsed, or whatever was chosen.
 */
const assertPlayedThree = (cards, best, handName, label, want) => {
  assert.equal(cards.length, 5, `${label}: five cards held`);
  assert.equal(new Set(cards).size, 5, `${label}: five different cards`);
  for (const code of cards) assert.match(code, CARD_CODE);
  assert.equal(best.length, 3, `${label}: three are counted`);
  const places = best.map((code) => cards.indexOf(code));
  assert.ok(places.every((i) => i >= 0), `${label}: every counted card is one of the five held`);
  assert.deepEqual(places, [...places].sort((x, y) => x - y), `${label}: best keeps the order the cards are held in`);
  assert.equal(new Set(places).size, 3);
  assert.deepEqual(best, want, `${label}: the three that play are the three that were chosen`);
  assert.equal(evaluate(best).name, handName, `${label}: the hand is named for the three it plays`);
};

/** The strongest three of five, by the suite's own ranking — what the server
 * reports as `bestPossible` so a player can be told what they missed. */
const bestOfFive = (cards) => {
  let best = null;
  for (const triple of THREES_OF_FIVE) {
    const hand = triple.map((i) => cards[i]);
    if (best === null || compare(evaluate(hand), evaluate(best)) > 0) best = hand;
  }
  return best;
};

/**
 * `best` is three of `cards`, in the order they are held, and no other three of
 * the five beats them.
 */
const assertBestOfFive = (cards, best, handName, label) => {
  assert.equal(cards.length, 5, `${label}: five cards held`);
  assert.equal(new Set(cards).size, 5, `${label}: five different cards`);
  for (const code of cards) assert.match(code, CARD_CODE);
  assert.equal(best.length, 3, `${label}: three are counted`);
  const places = best.map((code) => cards.indexOf(code));
  assert.ok(places.every((i) => i >= 0), `${label}: every counted card is one of the five held`);
  assert.deepEqual(places, [...places].sort((x, y) => x - y), `${label}: best keeps the order the cards are held in`);
  assert.equal(new Set(places).size, 3);
  const made = evaluate(best);
  assert.equal(made.name, handName, `${label}: the hand is named for its best three`);
  for (const triple of THREES_OF_FIVE) {
    const rival = evaluate(triple.map((i) => cards[i]));
    assert.ok(compare(made, rival) >= 0, `${label}: ${best} is beaten by ${triple.map((i) => cards[i])}`);
  }
};

// ------------------------------------------------------------- the window

test('a variation table deals, announces the window, and room:state carries all of it with nobody on turn', held, async () => {
  const { chooser, other, clients, started, roomId, bootAmount } = await variationTable('open');

  for (const { client, user } of [chooser, other]) {
    const state = client.state();
    assertKeys(state, VARIATION_SNAPSHOT_KEYS, 'room:state at a variation table');
    assert.equal(state.category, 'variation');
    assert.equal(state.chipsHidden, true, 'a variation table hides other stacks, as a blind one does');
    for (const seat of state.seats.filter((s) => s.userId && s.userId !== user.id)) {
      assert.equal(seat.chips, null, 'another player\'s stack is withheld: null, never 0');
    }
    // No variation table has a pot limit (owner, 18 Sep 2026).
    assert.equal(state.maxPot, 0, 'a variation table has no pot limit');
    assert.equal(state.state, 'betting', 'the hand is live; there is no separate table state for the window');
    assert.equal(state.handNo, started.handNo);
    assert.equal(state.pot, bootAmount * 2, 'the boots are in before anyone chooses');

    const block = state.variation;
    assertKeys(block, VARIATION_KEYS, 'room:state.variation while selecting');
    assert.equal(block.selecting, true);
    assert.equal(block.userId, chooser.user.id);
    assert.equal(block.displayName, chooser.user.displayName);
    assert.equal(block.seatIndex, chooser.client.state().you.seatIndex);
    assert.deepEqual(block.options, VARIATIONS, 'the seven canonical values, in menu order, FIVE_CARD last');
    assert.equal(block.cardsPerPlayer, 3, 'every hand is dealt three; only a FIVE_CARD choice makes it five');
    assert.equal(block.timeoutMs, profile.variationSelectTimeoutMs);
    assert.equal(block.deadline - block.startedAt, block.timeoutMs);
    assert.ok(Math.abs(block.startedAt - Date.now()) < 5000, 'startedAt is epoch ms');
    assert.equal(block.selected, null);
    assert.equal(block.selectedBy, null);

    // Nobody is on turn while the window is open — not even the chooser.
    assert.equal(state.turn.seatIndex, -1);
    assert.equal(state.turn.userId, null);
    assert.equal(state.you.options, null);
  }
  assert.deepEqual(chooser.client.state().variation, other.client.state().variation, 'the block is public: every viewer reads the same one');

  // The first dealer is seat 0, so the player who would have acted first is seat 1.
  assert.equal(chooser.client.state().variation.seatIndex, 1);

  // The announcement only repeats the block, and comes after the deal and before the snapshot.
  for (const { client } of [chooser, other]) {
    const event = client.last('game:variationSelecting');
    // cardsPerPlayer is the block's alone: the announcement opens a window, and no hand has grown yet.
    const { selecting, selected, selectedBy, cardsPerPlayer, ...announced } = client.state().variation;
    assert.deepEqual(event, { ...announced, roomId });
    assertOrder(client.events(), ['game:handStarted', 'player:hand', 'game:variationSelecting', 'room:state']);
    assert.equal(client.count('game:turn'), 0, 'no turn is announced while the variation is being chosen');
    assert.equal(client.count('game:yourTurn'), 0);
    assert.equal(client.count('game:variationSelected'), 0);
  }
  await closeAll(...clients);
});

test('only the chooser may pick: everyone else is not_selecting, garbage is invalid_variation, and the window stays open', held, async () => {
  const { chooser, other, clients } = await variationTable('who');
  const before = chooser.client.state().variation;

  let ack = await other.client.emit('game:selectVariation', { variation: 'AK47' });
  assert.deepEqual(ack, REFUSALS.not_selecting);
  await expectError(other.client, ack);

  // Exact match, no case folding; anything that is not a string is read as "".
  for (const variation of ['Muflis', 'ak47', ' AK47', 'CLASSIC', '', 7, null, true, ['AK47'], { name: 'AK47' }]) {
    ack = await chooser.client.emit('game:selectVariation', { variation });
    assert.deepEqual(ack, REFUSALS.invalid_variation, `variation ${JSON.stringify(variation)}`);
  }
  await expectError(chooser.client, ack);
  ack = await chooser.client.emit('game:selectVariation', {});
  assert.deepEqual(ack, REFUSALS.invalid_variation, 'no variation at all');

  await pause(100);
  assert.deepEqual(chooser.client.state().variation, before, 'none of it moved the window');
  assert.equal(chooser.client.count('game:variationSelected'), 0);
  await closeAll(...clients);
});

test('no move but see is taken while the variation is being chosen', held, async () => {
  const { chooser, other, clients } = await variationTable('pend');
  const pot = chooser.client.state().pot;

  for (const { client } of [chooser, other]) {
    for (const action of ['chaal', 'raise', 'pack', 'show', 'sideshow']) {
      const ack = await client.emit('game:action', { action, amount: client.state().stake });
      assert.deepEqual(ack, REFUSALS.variation_pending, `${action} during the window`);
    }
    await expectError(client, REFUSALS.variation_pending);
  }

  // See is free and off-turn everywhere, and here it lets the chooser look before choosing.
  for (const { client } of [chooser, other]) {
    const ack = await client.emit('game:action', { action: 'see' });
    assert.equal(ack.ok, true, `see during the window: ${JSON.stringify(ack)}`);
    const state = await client.waitState((p) => p.you.isBlind === false);
    assert.equal(state.you.cards.length, 3);
    for (const code of state.you.cards) assert.match(code, CARD_CODE);
    // Seen, but with no variation chosen there is no rule to count the hand by.
    assert.equal('hand' in state.you, false, 'you.hand is absent until the variation is chosen');
  }

  const after = chooser.client.state();
  assert.equal(after.variation.selecting, true, 'looking does not end the window');
  assert.equal(after.turn.userId, null);
  assert.equal(after.pot, pot, 'and nothing was bet');

  // The choice lands, and each player who has looked is told — privately — what
  // their OWN cards make under it: which played wild and what they stood for
  // (owner, 18 Sep 2026; the client turns the wild cards over with it).
  const pick = await chooser.client.emit('game:selectVariation', { variation: 'AK47' });
  assert.equal(pick.ok, true, JSON.stringify(pick));
  for (const { client } of [chooser, other]) {
    const state = await client.waitState((p) => p.you.hand);
    const { hand, cards } = state.you;
    assertKeys(hand, YOU_HAND_KEYS, 'you.hand');
    assert.deepEqual(hand.best, cards, 'a three-card hand counts all three, in the order held');
    assert.equal(typeof hand.handName, 'string');
    assert.ok(hand.handName.length > 0);
    assert.ok(Array.isArray(hand.wild), 'wild is [] when nothing was wild, never null');
    assert.equal(hand.playsAs.length, 3, 'three cards, index for index with you.cards');
    for (const code of hand.playsAs) assert.match(code, CARD_CODE);
    for (const code of hand.wild) {
      assert.ok(cards.includes(code), 'a wild card is one of the player\'s own');
      assert.match(code, /^[AK47]/, 'and under AK47 it is an A, K, 4 or 7');
    }
    cards.forEach((code, i) => {
      if (!hand.wild.includes(code)) assert.equal(hand.playsAs[i], code, 'a natural card plays as itself');
      else assert.ok(!cards.includes(hand.playsAs[i]) || hand.playsAs[i] === code, 'a stand-in is not another card of the same hand');
    });
    // Nothing of it is in anybody's public seat row.
    for (const seat of state.seats) assert.equal('hand' in seat, false);
  }
  await closeAll(...clients);
});

test('the pick is acked, announced, then the state has it and the chooser is on turn with a fresh clock; a second pick is refused', held, async () => {
  const { chooser, other, clients, roomId } = await variationTable('pick');
  const open = chooser.client.state().variation;
  const marks = new Map(clients.map((client) => [client, client.mark()]));

  const ack = await chooser.client.emit('game:selectVariation', { variation: 'AK47' });
  assert.deepEqual(ack, { ok: true, variation: 'AK47', selectedBy: 'PLAYER', cardsPerPlayer: 3 }, 'no turnUp: AK47 turns no card up');

  for (const { client } of [chooser, other]) {
    const state = await waitClosed(client);
    assertKeys(state, VARIATION_SNAPSHOT_KEYS, 'room:state after the pick');
    assertKeys(state.variation, VARIATION_KEYS, 'room:state.variation after an AK47 pick');
    assert.deepEqual(state.variation, { ...open, selecting: false, selected: 'AK47', selectedBy: 'PLAYER' },
      'the chooser stays the chooser; only the answer changed');
    assert.equal(state.turn.userId, chooser.user.id, 'the chooser acts first, as they would have');
    assert.equal(state.turn.seatIndex, open.seatIndex);
    assert.ok(state.turn.deadline - Date.now() > profile.turnTimeoutMs - 5000, 'with a full turn clock, not what the window left');

    const selected = client.last('game:variationSelected');
    assert.deepEqual(selected, {
      userId: chooser.user.id, displayName: chooser.user.displayName, seatIndex: open.seatIndex,
      variation: 'AK47', selectedBy: 'PLAYER', cardsPerPlayer: 3, roomId,
    });
    assertOrder(client.eventsSince(marks.get(client)), ['game:variationSelected', 'game:turn', 'room:state']);
  }
  assertOrder(chooser.client.eventsSince(marks.get(chooser.client)), ['game:variationSelected', 'game:yourTurn', 'room:state']);
  assertKeys(chooser.client.state().you.options, OPTIONS_KEYS, 'the chooser has ordinary options');
  assert.equal(other.client.state().you.options, null);
  assert.equal(other.client.count('game:yourTurn'), 0);

  // The window is closed however it closed — for a second tap, and for anybody else.
  for (const { client } of [chooser, other]) {
    const again = await client.emit('game:selectVariation', { variation: 'MUFLIS' });
    assert.deepEqual(again, REFUSALS.variation_already_selected);
    await expectError(client, again);
  }
  assert.equal(chooser.client.state().variation.selected, 'AK47', 'the first answer stands');

  // And the table now plays: the move that was refused a moment ago is taken.
  const chaal = await chooser.client.emit('game:action', { action: 'chaal', amount: chooser.client.state().you.options.chaal });
  assert.equal(chaal.ok, true, JSON.stringify(chaal));
  await closeAll(...clients);
});

test('JOKER and HUKAM turn a card up — in the ack, the announcement and the state — and nothing else does', held, async () => {
  for (const variation of ['JOKER', 'HUKAM', 'LOWEST_JOKER']) {
    const { chooser, other, clients } = await variationTable(`up${variation.slice(0, 2).toLowerCase()}`);
    const ack = await chooser.client.emit('game:selectVariation', { variation });
    const state = await waitClosed(other.client);
    const event = other.client.last('game:variationSelected');
    if (variation === 'LOWEST_JOKER') {
      assert.deepEqual(ack, { ok: true, variation, selectedBy: 'PLAYER', cardsPerPlayer: 3 });
      assert.ok(!('turnUp' in state.variation), 'turnUp is absent, not null');
      assert.ok(!('turnUp' in event));
    } else {
      assertKeys(ack, ['ok', 'variation', 'selectedBy', 'turnUp', 'cardsPerPlayer'], `${variation} ack`);
      assert.equal(ack.cardsPerPlayer, 3);
      assert.match(ack.turnUp, CARD_CODE);
      assertKeys(state.variation, [...VARIATION_KEYS, 'turnUp'], `room:state.variation after ${variation}`);
      assert.equal(state.variation.turnUp, ack.turnUp);
      assert.equal(event.turnUp, ack.turnUp);
      // It came from the undealt deck, so nobody can be holding it.
      await other.client.emit('game:action', { action: 'see' });
      const mine = await other.client.waitState((p) => p.you.isBlind === false);
      assert.ok(!mine.you.cards.includes(ack.turnUp), 'the turned-up card is not in a hand');
    }
    assert.equal(state.variation.selected, variation);
    await closeAll(...clients);
  }
});

test('room:state alone rebuilds the window: a second connection is handed the same block in room:joined', held, async () => {
  const { chooser, other, clients } = await variationTable('rejoin');
  const open = chooser.client.state().variation;

  // The same account connecting again replaces the old socket and is resumed
  // onto its seat — no grace timer involved, and no announcement to lean on.
  const again = await openClient(chooser.account.token);
  const joined = await again.wait('room:joined');
  assertKeys(joined, VARIATION_SNAPSHOT_KEYS, 'room:joined at a variation table');
  assert.deepEqual(joined.variation, open, 'the chooser, the ORIGINAL deadline and the options all come back');
  assert.equal(joined.turn.userId, null);
  assert.equal(again.count('game:variationSelecting'), 0, 'the block is all a reconnect gets');

  // And the window it describes is real: the new socket answers it.
  const ack = await again.emit('game:selectVariation', { variation: 'HIGHEST_JOKER' });
  assert.deepEqual(ack, { ok: true, variation: 'HIGHEST_JOKER', selectedBy: 'PLAYER', cardsPerPlayer: 3 });
  const state = await waitClosed(other.client);
  assert.equal(state.variation.selected, 'HIGHEST_JOKER');
  assert.equal(state.turn.userId, chooser.user.id);
  await closeAll(again, ...clients.filter((client) => client !== chooser.client));
  chooser.client.drop();
});

test('a chooser who leaves mid-window has MUFLIS chosen for them at once, and the next player opens the betting', held, async () => {
  const { chooser, others, clients, roomId } = await variationTable('left', { count: 3 });
  const open = chooser.client.state().variation;
  const watcher = others[0].client;
  const mark = watcher.mark();

  const left = await chooser.client.emit('room:leave', {});
  assert.equal(left.ok, true);

  const state = await waitClosed(watcher);
  assert.deepEqual(state.variation, { ...open, selecting: false, selected: 'MUFLIS', selectedBy: 'LEFT' });
  assert.notEqual(state.turn.userId, chooser.user.id, 'the turn opens with a player who is still here');
  assert.ok(others.some((entry) => entry.user.id === state.turn.userId));
  const selected = watcher.since(mark).find((e) => e.event === 'game:variationSelected').payload;
  assert.deepEqual(selected, {
    userId: chooser.user.id, displayName: chooser.user.displayName, seatIndex: open.seatIndex,
    variation: 'MUFLIS', selectedBy: 'LEFT', cardsPerPlayer: 3, roomId,
  });
  await closeAll(...clients);
});

// ------------------------------------------------------------ the reveals

test('a showdown names the variation, marks the wild cards inside each hand, and still pays exactly one winner', held, async () => {
  const { chooser, other, clients, roomId } = await variationTable('show');
  await chooser.client.emit('game:selectVariation', { variation: 'AK47' });
  await waitClosed(chooser.client);

  // Chaal round the table until the server offers a show, then take it.
  const showdown = await playToShowdown(chooser, other);
  assert.ok(showdown, 'the hand reached a show');

  assertKeys(showdown, ['reveals', 'reason', 'variation', 'roomId'], 'game:showdown at a variation table (AK47: no turnUp)');
  assert.equal(showdown.variation, 'AK47');
  assert.equal(showdown.reveals.length, 2);
  for (const reveal of showdown.reveals) {
    const expected = ['userId', 'seatIndex', 'cards', 'handName', 'category', 'won'];
    // playsAs (24 Sep 2026: "on show or sideshow, show updated cards not the
    // base cards") comes exactly with wild: the hand as it was counted.
    assertKeys(reveal, 'wild' in reveal ? [...expected, 'wild', 'playsAs'] : expected, 'reveal');
    assert.equal(reveal.cards.length, 3);
    if ('playsAs' in reveal) {
      assert.equal(reveal.playsAs.length, 3, 'playsAs runs index for index with cards');
      for (const [i, code] of reveal.cards.entries()) {
        if (reveal.wild.includes(code)) assert.match(reveal.playsAs[i], CARD_CODE);
        else assert.equal(reveal.playsAs[i], code, 'a natural card plays as itself');
      }
      assert.equal(new Set(reveal.playsAs).size, 3, 'no card twice in the counted hand');
      assert.equal(HAND_NAMES[evaluate(reveal.playsAs).category], reveal.handName, 'the counted hand makes the name the reveal carries');
    }
    assert.ok(!('best' in reveal), 'best is FIVE_CARD\'s alone: absent, not null, under every other variation');
    // What the hand MADE, in the same six English names every table uses.
    assert.equal(HAND_NAMES[reveal.category], reveal.handName);
    const wildRanks = reveal.cards.filter((code) => 'AK47'.includes(code[0]));
    if ('wild' in reveal) {
      assert.ok(reveal.wild.length > 0, 'wild is omitted, never empty');
      for (const code of reveal.wild) {
        assert.ok(reveal.cards.includes(code), `wild card ${code} is one of the hand's own`);
        assert.ok('AK47'.includes(code[0]), `${code} is wild under AK47`);
      }
    } else {
      assert.deepEqual(wildRanks, [], 'a hand holding an A, K, 4 or 7 says so');
    }
  }
  assert.equal(showdown.reveals.filter((r) => r.won).length, 1, 'exactly one winner, never a split pot');

  const ended = await chooser.client.wait('game:handEnded', (p) => p.roomId === roomId);
  assert.equal(ended.variation, 'AK47');
  assert.ok(!('turnUp' in ended));
  assert.equal(ended.winnerId, showdown.reveals.find((r) => r.won).userId);

  // Between hands the block is gone — absent, not null — until the next deal opens a new window.
  const between = chooser.client.all('room:state').find((p) => p.handNo === ended.handNo && p.state !== 'betting');
  if (between) assertKeys(between, SNAPSHOT_KEYS, 'room:state between hands');
  await closeAll(...clients);
});


// ------------------------------------------------------ 5-Card Teen Patti

test('FIVE_CARD is acked and announced with five cards each, every seat counts five, all twenty-five differ, and nobody is sent another player\'s', held, async () => {
  const { chooser, entries, clients, roomId } = await variationTable('five', { count: 5 });
  const open = chooser.client.state().variation;
  assert.equal(open.cardsPerPlayer, 3);
  for (const { client } of entries) {
    for (const seat of client.state().seats.filter((r) => r.userId)) assert.equal(seat.cardCount, 3, 'dealt three, as every hand is');
  }
  const marks = new Map(clients.map((client) => [client, client.mark()]));

  const ack = await chooser.client.emit('game:selectVariation', { variation: 'FIVE_CARD' });
  assert.deepEqual(ack, { ok: true, variation: 'FIVE_CARD', selectedBy: 'PLAYER', cardsPerPlayer: 5 }, 'no turnUp: FIVE_CARD turns no card up');

  for (const { client, user } of entries) {
    const state = await waitClosed(client);
    assertKeys(state.variation, VARIATION_KEYS, 'room:state.variation after a FIVE_CARD pick');
    assert.deepEqual(state.variation, { ...open, selecting: false, selected: 'FIVE_CARD', selectedBy: 'PLAYER', cardsPerPlayer: 5 });
    assert.deepEqual(client.last('game:variationSelected'), {
      userId: chooser.user.id, displayName: chooser.user.displayName, seatIndex: open.seatIndex,
      variation: 'FIVE_CARD', selectedBy: 'PLAYER', cardsPerPlayer: 5, roomId,
    });
    assertOrder(client.eventsSince(marks.get(client)), ['game:variationSelected', 'game:turn', 'room:state']);
    assert.equal(state.turn.userId, chooser.user.id, 'the chooser still opens the betting');

    const seated = state.seats.filter((seat) => seat.userId);
    assert.equal(seated.length, 5);
    for (const seat of seated) {
      assert.equal(seat.cardCount, 5, `seat ${seat.seatIndex} holds five`);
      assert.equal('cards' in seat, false, 'a seat row never carries cards');
    }
    assert.equal(state.you.isBlind, true);
    assert.equal(cardCodesIn(state.you).length, 0, `${user.displayName} has not looked, so is sent no card`);
    assert.equal('hand' in state.you, false);
  }

  // Everyone looks: five each, and across the table no card twice.
  const held5 = new Map();
  for (const { client, user } of entries) {
    const seen = await client.emit('game:action', { action: 'see' });
    assert.equal(seen.ok, true, JSON.stringify(seen));
    const state = await client.waitState((p) => p.you.isBlind === false);
    assert.equal(state.you.cards.length, 5);
    held5.set(user.id, state.you.cards);
  }
  const everyCard = [...held5.values()].flat();
  assert.equal(everyCard.length, 25);
  assert.equal(new Set(everyCard).size, 25, 'twenty-five cards, all different: the extra two came from the same deck');

  // Nothing any player was sent — no snapshot, no event, no ack — names a card that is not their own.
  await pause(100);
  for (const { client, user } of entries) {
    const mine = new Set(held5.get(user.id));
    for (const { event, payload } of client.since(0)) {
      for (const code of cardCodesIn(payload)) assert.ok(mine.has(code), `${user.displayName} was sent ${code} in ${event}`);
    }
    for (const seat of client.state().seats.filter((r) => r.userId)) assert.equal(seat.cardCount, 5);
  }
  await closeAll(...clients);
});

test('a player who looked during the window holds three, then five with the first three in place; player:cards is sent again; you.hand.best is three of their own', held, async () => {
  const { chooser, other, clients } = await variationTable('grow');
  const first = new Map();
  for (const { client, user } of [chooser, other]) {
    const ack = await client.emit('game:action', { action: 'see' });
    assert.equal(ack.ok, true, JSON.stringify(ack));
    const state = await client.waitState((p) => p.you.isBlind === false);
    assert.equal(state.you.cards.length, 3, 'three while the window is open');
    assert.equal(state.variation.cardsPerPlayer, 3);
    const dealt = await client.wait('player:cards');
    assert.deepEqual(dealt.cards, state.you.cards);
    first.set(user.id, state.you.cards);
  }
  const marks = new Map(clients.map((client) => [client, client.mark()]));

  const ack = await chooser.client.emit('game:selectVariation', { variation: 'FIVE_CARD' });
  assert.equal(ack.cardsPerPlayer, 5, JSON.stringify(ack));

  for (const { client, user } of [chooser, other]) {
    const state = await waitClosed(client);
    const { cards, hand } = state.you;
    assert.equal(cards.length, 5);
    assert.deepEqual(cards.slice(0, 3), first.get(user.id), 'the three already looked at stay where they were; the new two follow');

    // No snapshot is ever half way: three cards with the window open, five from the one that says FIVE_CARD.
    for (const { event, payload } of client.since(marks.get(client))) {
      if (event !== 'room:state') continue;
      const want = payload.variation?.selected === 'FIVE_CARD' ? 5 : 3;
      assert.equal(payload.you.cards.length, want, `a snapshot with selected ${payload.variation?.selected}`);
      assert.equal(payload.variation.cardsPerPlayer, want);
    }

    // The player was already looking, so the two new cards are dealt to them face up.
    const resent = await client.waitNext('player:cards', () => true, 4000, marks.get(client));
    assert.deepEqual(resent.cards, cards, 'player:cards again, with all five');

    // Five cards are in front of them and a choice is owed: the hand has no
    // name yet, because naming it would hand them the answer.
    assertKeys(hand, YOU_HAND_PICKING_KEYS, 'you.hand under FIVE_CARD, still choosing');
    assert.equal(hand.picking, true, 'a choice is owed');
    assert.equal(hand.handName, '', 'and the hand is not named until it is made');
    assert.deepEqual(hand.best, [], 'nothing counts yet');
    assert.ok(hand.pickDeadline > 0 && hand.pickTimeoutMs > 0, 'with a clock on it');
    assert.deepEqual(hand.wild, [], 'FIVE_CARD has no wild cards');
    assert.deepEqual(hand.playsAs, cards, 'so every card plays as itself');

    // They choose the last three they hold — any three of their own will do.
    const chosen = cards.slice(2);
    const ack = await client.emit('game:selectCards', { cards: chosen });
    assert.equal(ack.ok, true, `${user.displayName}: the pick was taken`);
    assert.deepEqual(ack.picked, chosen);
    assert.deepEqual(ack.best, bestOfFive(cards), 'and the ack says what the best three were');
    assert.equal(ack.wasBest, compare(evaluate(chosen), evaluate(bestOfFive(cards))) === 0);

    const after = (await client.waitState((p) => p.you.hand?.picking !== true)).you.hand;
    assertKeys(after, YOU_HAND_PICKED_KEYS, 'you.hand under FIVE_CARD, chosen');
    assert.equal(after.pickedBy, 'PLAYER');
    assert.deepEqual(after.bestPossible, bestOfFive(cards), 'what they could have played');
    assertPlayedThree(cards, after.best, after.handName, user.displayName, chosen);
    for (const seat of state.seats) assert.equal('hand' in seat, false, 'and none of it is public');
  }
  assert.equal(new Set([...chooser.client.state().you.cards, ...other.client.state().you.cards]).size, 10);
  await closeAll(...clients);
});

// The choice is the player's, and only theirs: three of their OWN cards, once
// (owner, 19 Sep 2026).
test('a FIVE_CARD pick takes three of your own cards, once, and nothing else', held, async () => {
  const { chooser, other, clients } = await variationTable('pick5');
  await chooser.client.emit('game:selectVariation', { variation: 'FIVE_CARD' });
  await waitClosed(chooser.client);
  await chooser.client.emit('game:action', { action: 'see' });
  const cards = (await chooser.client.waitState((p) => p.you.isBlind === false)).you.cards;
  assert.equal(cards.length, 5);

  // A player who has not looked is owed no choice: they cannot see the cards.
  const blind = await other.client.emit('game:selectCards', { cards: cards.slice(0, 3) });
  assert.equal(blind.ok, false);
  assert.equal(blind.code, 'not_picking', JSON.stringify(blind));

  for (const bad of [
    [], cards.slice(0, 2), cards.slice(0, 4), [cards[0], cards[0], cards[1]],
    [cards[0], cards[1], 'Zz'], [cards[0], cards[1], 7], 'not-an-array', undefined,
  ]) {
    const ack = await chooser.client.emit('game:selectCards', { cards: bad });
    assert.equal(ack.ok, false, `${JSON.stringify(bad)} was accepted`);
    assert.equal(ack.code, 'invalid_pick', `${JSON.stringify(bad)}: ${JSON.stringify(ack)}`);
  }

  // Three of their own, named in any order, play in the order they are HELD.
  const want = [cards[0], cards[2], cards[4]];
  const ack = await chooser.client.emit('game:selectCards', { cards: [cards[4], cards[0], cards[2]] });
  assert.equal(ack.ok, true, JSON.stringify(ack));
  assert.deepEqual(ack.picked, want, 'kept in the order they are held');

  // And once: the hand is decided.
  const again = await chooser.client.emit('game:selectCards', { cards: cards.slice(0, 3) });
  assert.equal(again.ok, false);
  assert.equal(again.code, 'duplicate_action', JSON.stringify(again));

  const hand = (await chooser.client.waitState((p) => p.you.hand?.picking !== true)).you.hand;
  assert.deepEqual(hand.best, want, 'the three that play are the three chosen');
  await closeAll(...clients);
});

test('a FIVE_CARD showdown reveals all five cards and the best three of each hand, and pays exactly one winner', held, async () => {
  const { chooser, other, clients, roomId } = await variationTable('show5');
  await chooser.client.emit('game:selectVariation', { variation: 'FIVE_CARD' });
  await waitClosed(chooser.client);
  const held5 = new Map();
  for (const { client, user } of [chooser, other]) {
    await client.emit('game:action', { action: 'see' });
    held5.set(user.id, (await client.waitState((p) => p.you.isBlind === false)).you.cards);
  }

  const showdown = await playToShowdown(chooser, other);
  assert.ok(showdown, 'the hand reached a show');
  assertKeys(showdown, ['reveals', 'reason', 'variation', 'roomId'], 'game:showdown under FIVE_CARD (no turnUp)');
  assert.equal(showdown.variation, 'FIVE_CARD');
  assert.equal(showdown.reveals.length, 2);
  for (const reveal of showdown.reveals) {
    assertKeys(reveal, ['userId', 'seatIndex', 'cards', 'handName', 'category', 'won', 'best'], 'a FIVE_CARD reveal: best, and no wild');
    assert.deepEqual(reveal.cards, held5.get(reveal.userId), 'the five the player held, in the order they held them');
    assert.equal(HAND_NAMES[reveal.category], reveal.handName);
    // Nobody chose, so the first three they were dealt are the three that
    // played (owner, 19 Sep 2026).
    assertPlayedThree(reveal.cards, reveal.best, reveal.handName,
      `reveal of seat ${reveal.seatIndex}`, reveal.cards.slice(0, 3));
  }
  assert.equal(new Set(showdown.reveals.flatMap((r) => r.cards)).size, 10, 'ten cards, all different');
  const winners = showdown.reveals.filter((r) => r.won);
  assert.equal(winners.length, 1, 'exactly one winner, never a split pot');
  const loser = showdown.reveals.find((r) => !r.won);
  assert.ok(compare(evaluate(winners[0].best), evaluate(loser.best)) >= 0, 'and the winner\'s played three are not the weaker');

  const ended = await chooser.client.wait('game:handEnded', (p) => p.roomId === roomId);
  assert.equal(ended.variation, 'FIVE_CARD');
  assert.ok(!('turnUp' in ended));
  assert.equal(ended.winnerId, winners[0].userId);
  assert.deepEqual(ended.reveals, showdown.reveals, 'game:handEnded repeats the same reveals');
  await closeAll(...clients);
});

test('a FIVE_CARD sideshow shows the two players five cards and a best three each, and the room none of it', held, async () => {
  const { chooser, entries, clients } = await variationTable('side5', { count: 3 });
  await chooser.client.emit('game:selectVariation', { variation: 'FIVE_CARD' });
  await waitClosed(chooser.client);
  const held5 = new Map();
  for (const { client, user } of entries) {
    await client.emit('game:action', { action: 'see' });
    held5.set(user.id, (await client.waitState((p) => p.you.isBlind === false)).you.cards);
  }

  // The chooser is on turn; the player on their right is the next seat DOWN, wrapping.
  const seatOf = (entry) => entry.client.state().you.seatIndex;
  const seats = entries.map(seatOf).sort((a, b) => a - b);
  const below = seats.filter((seat) => seat < seatOf(chooser));
  const askedSeat = below.length ? below[below.length - 1] : seats[seats.length - 1];
  const asked = entries.find((entry) => seatOf(entry) === askedSeat);
  const bystander = entries.find((entry) => entry !== chooser && entry !== asked);

  let ack = await chooser.client.emit('game:action', { action: 'sideshow' });
  assert.deepEqual(ack, { ok: true, action: 'sideshow', toUserId: asked.user.id });
  ack = await asked.client.emit('game:sideshowRespond', { accept: true });
  assert.equal(ack.ok, true, JSON.stringify(ack));
  assert.equal(ack.accepted, true);

  for (const { client } of [chooser, asked]) {
    const { reveal } = await client.wait('game:sideshowReveal');
    assert.deepEqual(reveal.hands.map((hand) => hand.userId), [chooser.user.id, asked.user.id]);
    for (const hand of reveal.hands) {
      assertKeys(hand, ['userId', 'displayName', 'cards', 'handName', 'best'], 'a FIVE_CARD sideshow hand: best, and no wild');
      assert.deepEqual(hand.cards, held5.get(hand.userId));
      // Nobody chose, so each plays the first three they were dealt.
      assertPlayedThree(hand.cards, hand.best, hand.handName,
        `sideshow hand of ${hand.displayName}`, hand.cards.slice(0, 3));
    }
    const [askerHand, askedHand] = reveal.hands.map((hand) => evaluate(hand.best));
    // A tie goes against the asker, so the asker survives only by being strictly better.
    assert.equal(reveal.packedUserId, compare(askerHand, askedHand) > 0 ? asked.user.id : chooser.user.id);
  }
  await pause(100);
  assert.equal(bystander.client.count('game:sideshowReveal'), 0, 'the room never sees the cards');
  const mine = new Set(held5.get(bystander.user.id));
  for (const { event, payload } of bystander.client.since(0)) {
    for (const code of cardCodesIn(payload)) assert.ok(mine.has(code), `the bystander was sent ${code} in ${event}`);
  }
  await closeAll(...clients);
});

test('each of the six older variations leaves every hand at the three cards it was dealt', held, async () => {
  for (const variation of THREE_CARD_VARIATIONS) {
    const { chooser, other, clients } = await variationTable(`three${variation.replace('_', '').slice(0, 6).toLowerCase()}`);
    // The chooser looks first, so a top-up — were there one — would have somebody to be re-sent to.
    await chooser.client.emit('game:action', { action: 'see' });
    await chooser.client.waitState((p) => p.you.isBlind === false);
    const before = chooser.client.state().you.cards;
    const mark = chooser.client.mark();

    const ack = await chooser.client.emit('game:selectVariation', { variation });
    assert.equal(ack.ok, true, JSON.stringify(ack));
    assert.equal(ack.cardsPerPlayer, 3, `${variation} ack`);
    for (const { client } of [chooser, other]) {
      const state = await waitClosed(client);
      assert.equal(state.variation.selected, variation);
      assert.equal(state.variation.cardsPerPlayer, 3, `${variation} block`);
      assert.equal(client.last('game:variationSelected').cardsPerPlayer, 3, `${variation} announcement`);
      for (const seat of state.seats.filter((r) => r.userId)) assert.equal(seat.cardCount, 3, `${variation}: seat ${seat.seatIndex}`);
    }
    await other.client.emit('game:action', { action: 'see' });
    const theirs = await other.client.waitState((p) => p.you.hand);
    assert.equal(theirs.you.cards.length, 3);
    assert.deepEqual(theirs.you.hand.best, theirs.you.cards, `${variation}: all three are counted`);

    const mine = await chooser.client.waitState((p) => p.you.hand);
    assert.deepEqual(mine.you.cards, before, `${variation}: the hand looked at is the hand played`);
    assert.deepEqual(mine.you.hand.best, before);
    await pause(100);
    assert.equal(chooser.client.eventsSince(mark).filter((event) => event === 'player:cards').length, 0,
      `${variation}: nothing was dealt, so player:cards is not sent again`);
    await closeAll(...clients);
  }
});

// ------------------------------------------------- every other table is as it was

test('a seen table and a blind table carry no variation key, announce no window, and refuse a pick with no_variation', held, async () => {
  for (const category of ['seen', 'blind']) {
    const { onTurn, waiting, clients } = await dealtTable(`varnot${category}`, uniqueStake, { category });
    for (const client of clients) {
      for (const snapshot of [...client.all('room:joined'), ...client.all('room:state')]) {
        assertKeys(snapshot, SNAPSHOT_KEYS, `${category} snapshot`);
      }
      assert.equal(client.count('game:variationSelecting'), 0);
      assert.equal(client.count('game:variationSelected'), 0);
    }
    for (const client of [onTurn, waiting]) {
      const ack = await client.emit('game:selectVariation', { variation: 'MUFLIS' });
      assert.deepEqual(ack, REFUSALS.no_variation, `${category} table`);
      await expectError(client, ack);
    }
    // The refusal cost nothing: the player on turn still is, and can still bet.
    const chaal = await onTurn.emit('game:action', { action: 'chaal', amount: onTurn.state().you.options.chaal });
    assert.equal(chaal.ok, true, JSON.stringify(chaal));
    await closeAll(...clients);
  }
});

test('a pick from a player at no table is not_in_room', held, async () => {
  const account = await guestLogin('device-parity-variation-lobby', 'Lobbyist');
  const client = await openClient(account.token);
  const ack = await client.emit('game:selectVariation', { variation: 'MUFLIS' });
  assert.equal(ack.ok, false);
  assert.equal(ack.code, 'not_in_room');
  await expectError(client, ack);
  await client.close();
});

// ------------------------------------------------------------- the timeout

test('a window nobody answers closes on the server clock: MUFLIS, TIMEOUT, and the chooser on turn', lapsing, async () => {
  const { chooser, other, clients, roomId } = await variationTable('lapse', { wantOpen: false });

  for (const { client } of [chooser, other]) {
    const state = await waitClosed(client, profile.variationSelectTimeoutMs + 4000);
    const { startedAt, deadline, timeoutMs } = state.variation;
    assert.equal(timeoutMs, profile.variationSelectTimeoutMs);
    assert.equal(deadline - startedAt, timeoutMs);
    assert.deepEqual(state.variation, {
      selecting: false, userId: chooser.user.id, displayName: chooser.user.displayName,
      seatIndex: chooser.client.state().you.seatIndex, startedAt, deadline, timeoutMs, options: VARIATIONS,
      selected: 'MUFLIS', selectedBy: 'TIMEOUT', cardsPerPlayer: 3,
    });
    assert.equal(state.turn.userId, chooser.user.id, 'missing the window costs the chooser the choice, not the turn');
    assert.ok(state.turn.deadline - Date.now() > profile.turnTimeoutMs - 5000, 'and the turn clock is a full one');
    assert.deepEqual(client.last('game:variationSelected'), {
      userId: chooser.user.id, displayName: chooser.user.displayName, seatIndex: state.variation.seatIndex,
      variation: 'MUFLIS', selectedBy: 'TIMEOUT', cardsPerPlayer: 3, roomId,
    });
    assertOrder(client.events(), ['game:variationSelecting', 'game:variationSelected', 'game:turn']);
  }
  assert.equal(chooser.client.state().you.missedTurns, 0, 'a lapsed window is not a missed turn');

  // Too late is too late, for the chooser as for anyone.
  const late = await chooser.client.emit('game:selectVariation', { variation: 'AK47' });
  assert.deepEqual(late, REFUSALS.variation_already_selected);
  assert.equal(chooser.client.state().variation.selected, 'MUFLIS');
  await closeAll(...clients);
});

test('every hand at the table opens a window of its own, and the chooser moves round with the deal', lapsing, async () => {
  const { chooser, other, clients, started } = await variationTable('next', { wantOpen: false });
  await waitClosed(chooser.client, profile.variationSelectTimeoutMs + 4000);

  // End the first hand: the player on turn packs, the other takes the pot.
  const pack = await chooser.client.emit('game:action', { action: 'pack' });
  assert.equal(pack.ok, true, JSON.stringify(pack));

  const next = await other.client.waitState((p) => p.handNo > started.handNo && p.variation, 8000);
  assert.equal(next.variation.userId, other.user.id, 'the dealer moved on, and so did the choice');
  assert.ok(next.variation.startedAt > chooser.client.all('room:state').find((p) => p.variation).variation.startedAt);
  const closed = await waitClosed(other.client, profile.variationSelectTimeoutMs + 4000);
  assert.equal(closed.handNo, next.handNo);
  assert.equal(closed.variation.selectedBy, 'TIMEOUT');
  assert.equal(closed.turn.userId, other.user.id);
  await closeAll(...clients);
});

test('a lapsed window never becomes 5-Card: MUFLIS, and every hand stays at three cards', lapsing, async () => {
  const { chooser, other, clients } = await variationTable('lapse3', { count: 3, wantOpen: false });
  // Read from the announcement of the OPEN window, which always describes it;
  // with an 800 ms window the latest snapshot may already be the closed one.
  assert.ok(chooser.client.last('game:variationSelecting').options.includes('FIVE_CARD'), 'FIVE_CARD was on offer');
  for (const { client } of [chooser, other]) {
    const state = await waitClosed(client, profile.variationSelectTimeoutMs + 4000);
    assert.equal(state.variation.selected, 'MUFLIS');
    assert.equal(state.variation.selectedBy, 'TIMEOUT');
    assert.equal(state.variation.cardsPerPlayer, 3);
    for (const seat of state.seats.filter((r) => r.userId)) assert.equal(seat.cardCount, 3);

    await client.emit('game:action', { action: 'see' });
    const seen = await client.waitState((p) => p.you.hand);
    assert.equal(seen.you.cards.length, 3);
    assert.deepEqual(seen.you.hand.best, seen.you.cards);
    assert.deepEqual(seen.you.hand.wild, [], 'Muflis has no wild cards');
  }
  await closeAll(...clients);
});
