/**
 * Variation Teen Patti over the socket (Go only; owner, 18 Sep 2026): the
 * third table category. It bets exactly as a seen table does; the one
 * difference is that every hand opens with a server-timed window in which the
 * player who would have acted first picks one of six variations, and the
 * server picks MUFLIS if they do not.
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
  OPTIONS_KEYS,
} from './lib/harness.mjs';
import { closeDb } from './lib/db.mjs';

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

// ------------------------------------------------------------- the window

test('a variation table deals, announces the window, and room:state carries all of it with nobody on turn', held, async () => {
  const { chooser, other, clients, started, roomId, bootAmount } = await variationTable('open');

  for (const { client } of [chooser, other]) {
    const state = client.state();
    assertKeys(state, VARIATION_SNAPSHOT_KEYS, 'room:state at a variation table');
    assert.equal(state.category, 'variation');
    assert.equal(state.chipsHidden, false, 'a variation table bets as a seen one does: open chips');
    assert.equal(state.maxPot, profile.seenMaxPot, 'and under the seen pot cap');
    assert.equal(state.state, 'betting', 'the hand is live; there is no separate table state for the window');
    assert.equal(state.handNo, started.handNo);
    assert.equal(state.pot, bootAmount * 2, 'the boots are in before anyone chooses');

    const block = state.variation;
    assertKeys(block, VARIATION_KEYS, 'room:state.variation while selecting');
    assert.equal(block.selecting, true);
    assert.equal(block.userId, chooser.user.id);
    assert.equal(block.displayName, chooser.user.displayName);
    assert.equal(block.seatIndex, chooser.client.state().you.seatIndex);
    assert.deepEqual(block.options, VARIATIONS, 'the six canonical values, in menu order');
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
    const { selecting, selected, selectedBy, ...announced } = client.state().variation;
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
  }

  const after = chooser.client.state();
  assert.equal(after.variation.selecting, true, 'looking does not end the window');
  assert.equal(after.turn.userId, null);
  assert.equal(after.pot, pot, 'and nothing was bet');
  await closeAll(...clients);
});

test('the pick is acked, announced, then the state has it and the chooser is on turn with a fresh clock; a second pick is refused', held, async () => {
  const { chooser, other, clients, roomId } = await variationTable('pick');
  const open = chooser.client.state().variation;
  const marks = new Map(clients.map((client) => [client, client.mark()]));

  const ack = await chooser.client.emit('game:selectVariation', { variation: 'AK47' });
  assert.deepEqual(ack, { ok: true, variation: 'AK47', selectedBy: 'PLAYER' }, 'no turnUp: AK47 turns no card up');

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
      variation: 'AK47', selectedBy: 'PLAYER', roomId,
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
      assert.deepEqual(ack, { ok: true, variation, selectedBy: 'PLAYER' });
      assert.ok(!('turnUp' in state.variation), 'turnUp is absent, not null');
      assert.ok(!('turnUp' in event));
    } else {
      assertKeys(ack, ['ok', 'variation', 'selectedBy', 'turnUp'], `${variation} ack`);
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
  assert.deepEqual(ack, { ok: true, variation: 'HIGHEST_JOKER', selectedBy: 'PLAYER' });
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
    variation: 'MUFLIS', selectedBy: 'LEFT', roomId,
  });
  await closeAll(...clients);
});

// ------------------------------------------------------------ the reveals

test('a showdown names the variation, marks the wild cards inside each hand, and still pays exactly one winner', held, async () => {
  const { chooser, other, clients, roomId } = await variationTable('show');
  await chooser.client.emit('game:selectVariation', { variation: 'AK47' });
  await waitClosed(chooser.client);

  // Chaal round the table until the server offers a show, then take it.
  const byId = { [chooser.user.id]: chooser.client, [other.user.id]: other.client };
  let showdown = null;
  for (let move = 0; move < 12 && !showdown; move += 1) {
    const turnId = chooser.client.state().turn.userId;
    const client = byId[turnId];
    const state = await client.waitState((p) => p.turn?.userId === turnId && p.you.options);
    const mark = chooser.client.mark();
    if (state.you.options.show !== null) {
      const ack = await client.emit('game:action', { action: 'show' });
      assert.equal(ack.ok, true, JSON.stringify(ack));
      showdown = await chooser.client.waitNext('game:showdown', () => true, 4000, mark);
    } else {
      const ack = await client.emit('game:action', { action: 'chaal', amount: state.you.options.chaal });
      assert.equal(ack.ok, true, JSON.stringify(ack));
      await chooser.client.waitNext('room:state', (p) => p.turn?.userId !== turnId || p.state !== 'betting', 4000, mark);
    }
  }
  assert.ok(showdown, 'the hand reached a show');

  assertKeys(showdown, ['reveals', 'reason', 'variation', 'roomId'], 'game:showdown at a variation table (AK47: no turnUp)');
  assert.equal(showdown.variation, 'AK47');
  assert.equal(showdown.reveals.length, 2);
  for (const reveal of showdown.reveals) {
    const expected = ['userId', 'seatIndex', 'cards', 'handName', 'category', 'won'];
    assertKeys(reveal, 'wild' in reveal ? [...expected, 'wild'] : expected, 'reveal');
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
      selected: 'MUFLIS', selectedBy: 'TIMEOUT',
    });
    assert.equal(state.turn.userId, chooser.user.id, 'missing the window costs the chooser the choice, not the turn');
    assert.ok(state.turn.deadline - Date.now() > profile.turnTimeoutMs - 5000, 'and the turn clock is a full one');
    assert.deepEqual(client.last('game:variationSelected'), {
      userId: chooser.user.id, displayName: chooser.user.displayName, seatIndex: state.variation.seatIndex,
      variation: 'MUFLIS', selectedBy: 'TIMEOUT', roomId,
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
