/**
 * Money-conservation tests.
 *
 * Chips are the product here: every hand must redistribute exactly what was
 * staked, no more and no less, whatever route the hand took to finish.
 *
 * Every mutator on the table (act, removePlayer, startHand) runs through its
 * queue and returns a promise, and `advance` awaits each timer it fires — so
 * the tests await all of them and are declared async.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import Table from '../src/game/table.js';
import { ACTION } from '../src/game/constants.js';
import { parseCard } from '../src/game/deck.js';
import createFakeTimers from './helpers/fakeTimers.js';

const BOOT = 100;
const START = 200000;

const baseConfig = {
  maxPlayers: 5,
  minPlayers: 2,
  bootAmount: BOOT,
  turnTimeoutMs: 25000,
  maxBetRounds: 20,
  potLimitMultiplier: 1024,
  nextHandDelayMs: 6000,
  chatMaxHistory: 100,
  chatMaxLength: 140,
};

/** A table whose settle callback behaves like the real database one. */
function makeTable(overrides = {}) {
  const { timers, advance } = createFakeTimers();
  const settled = [];
  const bank = new Map();

  const table = new Table({
    id: 'settle-room',
    code: 'SETL01',
    config: { ...baseConfig, ...overrides },
    timers,
    settle: ({ hand, entries }) => {
      settled.push({ hand, entries });
      const balances = {};
      for (const entry of entries) {
        // The real settle applies the delta to the pre-hand balance.
        const before = bank.get(entry.userId) ?? START;
        const after = before + entry.delta;
        bank.set(entry.userId, after);
        balances[entry.userId] = after;
      }
      return balances;
    },
  });

  const seat = (id, chips = START) => {
    bank.set(id, chips);
    return table.addPlayer({ userId: id, displayName: id, avatarUrl: null, chips, socketId: `s-${id}` });
  };

  return { table, advance, settled, seat, bank };
}

const turnUser = (table) => table.seats[table.hand.turnSeat].userId;

const setHands = (table, byUserId) => {
  for (const [userId, codes] of Object.entries(byUserId)) {
    table.findSeat(userId).cards = codes.map(parseCard);
  }
};

/** Asserts the hand moved exactly the pot and no chips were created or lost. */
const assertConserved = (record) => {
  const net = record.entries.reduce((sum, entry) => sum + entry.delta, 0);
  assert.equal(net, 0, 'the sum of all deltas must be zero');

  const staked = record.hand.summary.reduce((sum, row) => sum + row.contributed, 0);
  assert.equal(staked, record.hand.pot, 'the pot equals everything staked');

  const winners = record.entries.filter((entry) => entry.isWinner);
  assert.equal(winners.length, 1, 'exactly one winner');
  assert.equal(
    winners[0].delta,
    record.hand.pot - record.hand.summary.find((row) => row.userId === winners[0].userId).contributed,
    'the winner nets the pot minus their own stake',
  );
};

test('chips are conserved when everyone else packs', async () => {
  const { table, seat, advance, settled } = makeTable();
  for (const id of ['a', 'b', 'c']) seat(id);
  await advance(baseConfig.nextHandDelayMs);

  await table.act(turnUser(table), ACTION.CHAAL);
  await table.act(turnUser(table), ACTION.PACK);
  await table.act(turnUser(table), ACTION.PACK);

  assertConserved(settled.at(-1));
});

test('chips are conserved through a show', async () => {
  const { table, seat, advance, settled } = makeTable();
  seat('a');
  seat('b');
  await advance(baseConfig.nextHandDelayMs);
  setHands(table, { a: ['As', 'Ah', 'Ad'], b: ['2s', '7h', '9d'] });

  await table.act(turnUser(table), ACTION.SEE);
  await table.act(turnUser(table), ACTION.RAISE);
  await table.act(turnUser(table), ACTION.SHOW);

  assertConserved(settled.at(-1));
});

test('chips are conserved through a forced showdown', async () => {
  const { table, seat, advance, settled } = makeTable({ maxBetRounds: 4 });
  for (const id of ['a', 'b', 'c']) seat(id);
  await advance(baseConfig.nextHandDelayMs);

  for (let i = 0; i < 60 && table.hand; i += 1) await table.act(turnUser(table), ACTION.CHAAL);

  assert.equal(table.hand, null);
  assertConserved(settled.at(-1));
});

test('chips are conserved when a player leaves mid-hand', async () => {
  const { table, seat, advance, settled } = makeTable();
  for (const id of ['a', 'b', 'c']) seat(id);
  await advance(baseConfig.nextHandDelayMs);

  const quitter = turnUser(table);
  await table.act(quitter, ACTION.CHAAL);
  await table.removePlayer(quitter, 'left');
  await table.act(turnUser(table), ACTION.PACK);

  const record = settled.at(-1);
  assertConserved(record);
  assert.ok(
    record.entries.some((entry) => entry.userId === quitter && entry.delta < 0),
    'the player who left still paid what they staked',
  );
});

test('chips are conserved when every player times out but one', async () => {
  const { table, seat, advance, settled } = makeTable();
  for (const id of ['a', 'b', 'c']) seat(id);
  await advance(baseConfig.nextHandDelayMs);

  await advance(baseConfig.turnTimeoutMs); // first player packed
  await advance(baseConfig.turnTimeoutMs); // second packed, hand ends

  assert.equal(table.hand, null);
  assertConserved(settled.at(-1));
});

test('the total in play is unchanged across many hands', async () => {
  const { table, seat, advance, bank } = makeTable();
  for (const id of ['a', 'b', 'c', 'd']) seat(id);

  const totalBefore = [...bank.values()].reduce((sum, chips) => sum + chips, 0);

  // Play out a stack of hands with a mix of packs, bets and shows.
  for (let hand = 0; hand < 25; hand += 1) {
    await advance(baseConfig.nextHandDelayMs);
    if (!table.hand) break;

    let guard = 0;
    while (table.hand && guard < 80) {
      guard += 1;
      const player = table.findSeat(turnUser(table));
      const options = table.turnOptions(player);

      if (options.show) await table.act(player.userId, ACTION.SHOW);
      else if (guard % 4 === 0) await table.act(player.userId, ACTION.PACK);
      else if (options.chaal) await table.act(player.userId, ACTION.CHAAL);
      else await table.act(player.userId, ACTION.PACK);
    }
  }

  const totalAfter = [...bank.values()].reduce((sum, chips) => sum + chips, 0);
  assert.equal(totalAfter, totalBefore, 'no chips were created or destroyed across 25 hands');
  assert.ok(table.handNo > 5, 'a meaningful number of hands actually ran');
});

test('a settled balance of zero is not treated as a failed settlement', async () => {
  // A player who wins a hand but is left with exactly 0 chips must not have the
  // pot credited twice by the in-memory fallback.
  const { timers, advance } = createFakeTimers();
  const table = new Table({
    id: 'zero-room',
    code: 'ZERO01',
    config: baseConfig,
    timers,
    settle: ({ entries }) => Object.fromEntries(entries.map((entry) => [entry.userId, 0])),
  });

  table.addPlayer({ userId: 'a', displayName: 'A', avatarUrl: null, chips: START, socketId: 's-a' });
  table.addPlayer({ userId: 'b', displayName: 'B', avatarUrl: null, chips: START, socketId: 's-b' });
  await advance(baseConfig.nextHandDelayMs);

  await table.act(table.seats[table.hand.turnSeat].userId, ACTION.PACK);

  for (const seat of table.occupiedSeats) {
    assert.equal(seat.chips, 0, 'the settled balance is used verbatim');
  }
});
