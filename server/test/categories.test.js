/**
 * Blind vs Seen table categories (requirement 13).
 *
 * The two categories differ in one thing: whether you can see other players'
 * chip stacks. The hiding is done when state is serialized per viewer, so it is
 * a real privacy boundary rather than something the client chooses to draw.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import Table from '../src/game/table.js';
import { TABLE_CATEGORY } from '../src/game/constants.js';
import createFakeTimers from './helpers/fakeTimers.js';

const BOOT = 200;
const START = 200000;

const baseConfig = {
  maxPlayers: 5,
  minPlayers: 2,
  bootAmount: BOOT,
  turnTimeoutMs: 25000,
  maxBetRounds: 20,
  potLimitMultiplier: 1024,
  maxRaiseSteps: 8,
  nextHandDelayMs: 6000,
  chatMaxHistory: 100,
  chatMaxLength: 140,
};

function makeTable(category, overrides = {}) {
  const { timers, advance } = createFakeTimers();
  const table = new Table({
    id: 'cat-room',
    code: 'CAT001',
    config: { ...baseConfig, category, ...overrides },
    timers,
    settle: () => ({}),
  });

  const seat = (id, chips = START) =>
    table.addPlayer({ userId: id, displayName: id, avatarUrl: null, chips, socketId: `s-${id}` });

  return { table, advance, seat };
}

const seatOf = (view, userId) => view.seats.find((entry) => entry.userId === userId);

// ------------------------------------------------------------- the category

test('a table defaults to the seen category', () => {
  const { table } = makeTable(undefined);
  assert.equal(table.category, TABLE_CATEGORY.SEEN);
});

test('an unknown category falls back to seen rather than hiding chips', () => {
  const { table } = makeTable('nonsense');
  assert.equal(table.category, TABLE_CATEGORY.SEEN, 'never hide by accident');
});

test('the category is reported in the snapshot and the lobby row', () => {
  const { table, seat } = makeTable(TABLE_CATEGORY.BLIND);
  seat('alice');

  assert.equal(table.serializeFor('alice').category, TABLE_CATEGORY.BLIND);
  assert.equal(table.summary().category, TABLE_CATEGORY.BLIND);
});

// ------------------------------------------------------ seen: chips visible

test('on a seen table everyone can see every stack', () => {
  const { table, seat } = makeTable(TABLE_CATEGORY.SEEN);
  seat('alice', 150000);
  seat('bob', 75000);
  seat('carol', 42000);

  const view = table.serializeFor('alice');

  assert.equal(view.chipsHidden, false);
  assert.equal(seatOf(view, 'alice').chips, 150000, 'your own stack');
  assert.equal(seatOf(view, 'bob').chips, 75000, "another player's stack");
  assert.equal(seatOf(view, 'carol').chips, 42000);
});

// ------------------------------------------------------ blind: chips hidden

test('on a blind table you see your own stack but nobody else\'s', () => {
  const { table, seat } = makeTable(TABLE_CATEGORY.BLIND);
  seat('alice', 150000);
  seat('bob', 75000);
  seat('carol', 42000);

  const view = table.serializeFor('alice');

  assert.equal(view.chipsHidden, true);
  assert.equal(seatOf(view, 'alice').chips, 150000, 'your own stack is always visible');
  assert.equal(seatOf(view, 'bob').chips, null, "another player's stack is withheld");
  assert.equal(seatOf(view, 'carol').chips, null);
});

test('a hidden stack is null, never zero', () => {
  // Zero would read as "this player is broke", which is a different claim.
  const { table, seat } = makeTable(TABLE_CATEGORY.BLIND);
  seat('alice');
  seat('bob', 90000);

  const bobSeat = seatOf(table.serializeFor('alice'), 'bob');
  assert.equal(bobSeat.chips, null);
  assert.notEqual(bobSeat.chips, 0);
});

test('each viewer sees only their own stack on a blind table', () => {
  const { table, seat } = makeTable(TABLE_CATEGORY.BLIND);
  seat('alice', 111000);
  seat('bob', 222000);

  const alice = table.serializeFor('alice');
  const bob = table.serializeFor('bob');

  assert.equal(seatOf(alice, 'alice').chips, 111000);
  assert.equal(seatOf(alice, 'bob').chips, null);

  assert.equal(seatOf(bob, 'bob').chips, 222000);
  assert.equal(seatOf(bob, 'alice').chips, null);
});

test('another player\'s stack is not in the serialized payload at all', () => {
  // The strong version of the claim: the number never reaches the client, so a
  // tampered client has nothing to reveal.
  const { table, seat } = makeTable(TABLE_CATEGORY.BLIND);
  seat('alice', 1000);
  seat('bob', 987654);

  const wire = JSON.stringify(table.serializeFor('alice'));
  assert.ok(!wire.includes('987654'), "bob's stack is absent from the wire");
  assert.ok(wire.includes('1000'), "alice's own stack is present");
});

test('your own turn options still carry your stack on a blind table', async () => {
  const { table, seat, advance } = makeTable(TABLE_CATEGORY.BLIND);
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  const onTurn = table.seats[table.hand.turnSeat];
  const view = table.serializeFor(onTurn.userId);

  assert.equal(view.you.chips, START - BOOT, 'you always know what you hold');
  assert.equal(view.you.options.chips, START - BOOT);
});

test('bets stay public on a blind table', async () => {
  // What a player has put into this pot is announced as it happens, so hiding
  // it in the snapshot would be inconsistent, not private.
  const { table, seat, advance } = makeTable(TABLE_CATEGORY.BLIND);
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  const view = table.serializeFor('alice');
  assert.equal(seatOf(view, 'bob').contributed, BOOT, 'the boot they staked is visible');
  assert.equal(seatOf(view, 'bob').chips, null, 'their bankroll is not');
  assert.equal(view.pot, BOOT * 2, 'the pot is public');
});

test('hiding chips does not affect gameplay', async () => {
  const blind = makeTable(TABLE_CATEGORY.BLIND);
  const seen = makeTable(TABLE_CATEGORY.SEEN);

  for (const setup of [blind, seen]) {
    setup.seat('alice');
    setup.seat('bob');
    await setup.advance(baseConfig.nextHandDelayMs);
  }

  const blindPlayer = blind.table.seats[blind.table.hand.turnSeat];
  const seenPlayer = seen.table.seats[seen.table.hand.turnSeat];

  assert.deepEqual(
    blind.table.betOptions(blindPlayer).steps,
    seen.table.betOptions(seenPlayer).steps,
    'the same bets are available in both categories',
  );
  assert.equal(blind.table.hand.pot, seen.table.hand.pot);
});
