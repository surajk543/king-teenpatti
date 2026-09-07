/**
 * Requirement 15 (the last player to leave takes the pot) and requirement 19
 * (seen tables allow one double per turn and force a showdown after 7 rounds).
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import Table from '../src/game/table.js';
import RoomManager from '../src/game/roomManager.js';
import { ACTION, TABLE_CATEGORY, WIN_REASON } from '../src/game/constants.js';
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

function makeTable(overrides = {}) {
  const { timers, advance } = createFakeTimers();
  const settled = [];

  const table = new Table({
    id: 'rules-room',
    code: 'RULE01',
    config: { ...baseConfig, ...overrides },
    timers,
    settle: ({ hand, entries }) => {
      settled.push({ hand, entries });
      return Object.fromEntries(
        entries.map((entry) => {
          const seat = table.findSeat(entry.userId);
          return [entry.userId, (seat ? seat.chips : 0) + (entry.isWinner ? hand.pot : 0)];
        }),
      );
    },
  });

  const ended = [];
  table.on('handEnded', (payload) => ended.push(payload));

  const seat = (id, chips = START) =>
    table.addPlayer({ userId: id, displayName: id.toUpperCase(), avatarUrl: null, chips, socketId: `s-${id}` });

  return { table, advance, settled, ended, seat };
}

const turnUser = (table) => table.seats[table.hand.turnSeat].userId;

// ------------------------------- requirement 15: everybody leaves the table

test('when a player leaves mid-hand the one still sitting takes the pot', () => {
  const { table, seat, advance, settled, ended } = makeTable();
  seat('alice');
  seat('bob');
  advance(baseConfig.nextHandDelayMs);

  const first = turnUser(table);
  table.act(first, ACTION.CHAAL);
  const potBefore = table.hand.pot;
  const other = table.activeSeats.find((s) => s.userId !== first).userId;

  table.removePlayer(first, 'left');

  const result = ended.at(-1);
  assert.equal(result.reason, WIN_REASON.LAST_STANDING);
  assert.equal(result.winnerId, other, 'the player still at the table takes it');
  assert.equal(result.pot, potBefore);

  assert.equal(
    settled.at(-1).entries.reduce((sum, entry) => sum + entry.delta, 0),
    0,
    'chips are conserved',
  );
});

test('destroying a table mid-hand pays the pot out rather than voiding it', () => {
  // A shutdown or an idle sweep can tear down a table while a hand is live.
  // The chips in the middle still belong to someone.
  const { table, seat, advance, settled, ended } = makeTable();
  for (const id of ['a', 'b', 'c']) seat(id);
  advance(baseConfig.nextHandDelayMs);

  table.act(turnUser(table), ACTION.CHAAL);
  const pot = table.hand.pot;
  const stillIn = table.activeSeats.map((s) => s.userId);

  table.destroy();

  const result = ended.at(-1);
  assert.equal(result.reason, WIN_REASON.ALL_LEFT);
  assert.ok(stillIn.includes(result.winnerId), 'a player who was still in the hand receives it');
  assert.equal(result.pot, pot, 'the whole pot is paid out');

  const record = settled.at(-1);
  assert.equal(
    record.entries.reduce((sum, entry) => sum + entry.delta, 0),
    0,
    'no chips are created or destroyed',
  );
});

test('successive departures hand the pot to whoever is still in the hand', () => {
  const { table, seat, advance, ended } = makeTable();
  for (const id of ['a', 'b', 'c']) seat(id);
  advance(baseConfig.nextHandDelayMs);

  table.act(turnUser(table), ACTION.CHAAL);
  const active = table.activeSeats.map((s) => s.userId);

  // First departure: two players are still in, so the hand carries on.
  table.removePlayer(active[0], 'left');
  assert.ok(table.hand, 'the hand continues with two players');

  // Second departure leaves exactly one, who takes the pot.
  const potBefore = table.hand.pot;
  table.removePlayer(active[1], 'left');

  assert.equal(table.hand, null, 'the hand is over');
  assert.equal(ended.at(-1).winnerId, active[2], 'the remaining player takes it');
  assert.equal(ended.at(-1).pot, potBefore);
});

test('a player who leaves mid-hand is flagged for the abandoned counter', () => {
  const { table, seat, advance, settled } = makeTable();
  for (const id of ['a', 'b', 'c']) seat(id);
  advance(baseConfig.nextHandDelayMs);

  const quitter = turnUser(table);
  table.act(quitter, ACTION.CHAAL);
  table.removePlayer(quitter, 'left');

  // Finish the hand between the two who stayed.
  table.act(turnUser(table), ACTION.PACK);

  const record = settled.at(-1);
  const quitterEntry = record.entries.find((entry) => entry.userId === quitter);

  assert.equal(quitterEntry.leftMidHand, true, 'flagged as abandoned');
  assert.equal(quitterEntry.didChaal, true, 'they had bet, so it counts as played');
  assert.equal(quitterEntry.isWinner, false);
});

test('a player who only posts the boot is not marked as having played', () => {
  const { table, seat, advance, settled } = makeTable();
  seat('alice');
  seat('bob');
  advance(baseConfig.nextHandDelayMs);

  // The player on turn packs straight away, never betting beyond the boot.
  const packer = turnUser(table);
  table.act(packer, ACTION.PACK);

  const record = settled.at(-1);
  const entry = record.entries.find((row) => row.userId === packer);

  assert.equal(entry.didChaal, false, 'the boot alone is not a hand played');
  assert.equal(entry.leftMidHand, false);
});

test('betting marks the hand as played', () => {
  const { table, seat, advance, settled } = makeTable();
  seat('alice');
  seat('bob');
  advance(baseConfig.nextHandDelayMs);

  const better = turnUser(table);
  table.act(better, ACTION.CHAAL);
  table.act(turnUser(table), ACTION.PACK);

  const entry = settled.at(-1).entries.find((row) => row.userId === better);
  assert.equal(entry.didChaal, true);
});

// --------------------------- requirement 19: seen tables play tighter

test('a seen table allows a single double per turn', () => {
  const rooms = new RoomManager({ timers: createFakeTimers().timers });
  const table = rooms.createTable({ bootAmount: BOOT, category: TABLE_CATEGORY.SEEN });

  table.addPlayer({ userId: 'a', displayName: 'A', chips: START, socketId: '1' });
  table.addPlayer({ userId: 'b', displayName: 'B', chips: START, socketId: '2' });
  table.startHand();

  const player = table.seats[table.hand.turnSeat];
  const { steps } = table.betOptions(player);

  assert.equal(steps.length, 2, 'the chaal and one double, nothing further');
  assert.deepEqual(steps, [BOOT, BOOT * 2]);

  // Pressing "+" past the single double is not a legal amount.
  assert.throws(
    () => table.act(player.userId, ACTION.RAISE, { amount: BOOT * 4 }),
    (error) => error.code === 'invalid_bet',
  );

  rooms.shutdown();
});

test('a blind table keeps the full doubling ladder', () => {
  const rooms = new RoomManager({ timers: createFakeTimers().timers });
  const table = rooms.createTable({ bootAmount: BOOT, category: TABLE_CATEGORY.BLIND });

  table.addPlayer({ userId: 'a', displayName: 'A', chips: START, socketId: '1' });
  table.addPlayer({ userId: 'b', displayName: 'B', chips: START, socketId: '2' });
  table.startHand();

  const steps = table.betOptions(table.seats[table.hand.turnSeat]).steps;
  assert.ok(steps.length > 2, 'blind tables can keep doubling');
  assert.equal(steps[2], BOOT * 4);

  rooms.shutdown();
});

test('a seen table forces a showdown after 7 rounds', () => {
  const timers = createFakeTimers();
  const rooms = new RoomManager({ timers: timers.timers });
  const table = rooms.createTable({ bootAmount: BOOT, category: TABLE_CATEGORY.SEEN });

  assert.equal(table.config.maxBetRounds, 7, 'seven turns each, then everyone shows');

  table.addPlayer({ userId: 'a', displayName: 'A', chips: START, socketId: '1' });
  table.addPlayer({ userId: 'b', displayName: 'B', chips: START, socketId: '2' });

  const ended = [];
  const showdowns = [];
  table.on('handEnded', (payload) => ended.push(payload));
  table.on('showdown', (payload) => showdowns.push(payload));

  table.startHand();

  // Nobody folds, so only the round cap can end this.
  for (let i = 0; i < 60 && table.hand; i += 1) {
    table.act(table.seats[table.hand.turnSeat].userId, ACTION.CHAAL);
  }

  assert.equal(table.hand, null, 'the hand ended on its own');
  assert.equal(ended.at(-1).reason, WIN_REASON.FORCED_SHOWDOWN);
  assert.equal(showdowns.at(-1).reveals.length, 2, "everybody's cards are shown");
  assert.ok(ended.at(-1).winnerId, 'and the pot goes to the best hand');

  rooms.shutdown();
});

test('the showdown reveals every remaining player to everyone', () => {
  // Requirement 14: a show must expose both hands, not just the caller's.
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  advance(baseConfig.nextHandDelayMs);

  const reveals = [];
  table.on('showdown', (payload) => reveals.push(payload));

  table.act(turnUser(table), ACTION.SHOW);

  const showdown = reveals.at(-1);
  assert.equal(showdown.reveals.length, 2);
  for (const reveal of showdown.reveals) {
    assert.equal(reveal.cards.length, 3, 'three cards per player');
    assert.ok(reveal.handName, 'with the hand name, so the result is explicable');
    assert.equal(typeof reveal.won, 'boolean');
  }
  assert.equal(showdown.reveals.filter((reveal) => reveal.won).length, 1, 'exactly one winner');
});
