/**
 * Requirement 22: private tables cap the pot at 500,000, allow a single double
 * per turn, and start at a boot of 200 chips.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import Table from '../src/game/table.js';
import RoomManager from '../src/game/roomManager.js';
import { ACTION, TABLE_CATEGORY, WIN_REASON } from '../src/game/constants.js';
import createFakeTimers from './helpers/fakeTimers.js';

const START = 2000000;

// `settle` keeps the chips in memory: without it the room manager would reach
// for the PostgreSQL ledger, and these are table-rule tests, not database ones.
const makeRooms = () => new RoomManager({ timers: createFakeTimers().timers, settle: () => ({}) });

const seatTwo = async (table, chips = START) => {
  table.addPlayer({ userId: 'a', displayName: 'A', chips, socketId: '1' });
  table.addPlayer({ userId: 'b', displayName: 'B', chips, socketId: '2' });
  await table.startHand();
};

const turnUser = (table) => table.seats[table.hand.turnSeat].userId;

// -------------------------------------------------------- fixed boot amount

test('a private table always uses the fixed boot of 200 chips', async () => {
  const rooms = makeRooms();

  // Whatever is asked for is replaced: the boot is not a choice.
  for (const asked of [50, 199, 200, 1000, 99999, undefined]) {
    const table = rooms.createTable({ bootAmount: asked, isPrivate: true });
    assert.equal(table.config.bootAmount, 200, `asking for ${asked} still gives 200`);
  }

  await rooms.shutdown();
});

test('a public table still uses the stake it was created with', async () => {
  const rooms = makeRooms();

  assert.equal(rooms.createTable({ bootAmount: 100, isPrivate: false }).config.bootAmount, 100);
  assert.equal(rooms.createTable({ bootAmount: 5000, isPrivate: false }).config.bootAmount, 5000);

  await rooms.shutdown();
});

test('the lobby advertises the fixed boot and the maximum win', () => {
  const options = RoomManager.lobbyOptions();

  assert.equal(options.privateBoot, 200);
  assert.equal(options.privateMaxPot, 500000);
});

// ------------------------------------------------- one double per turn

test('a private table allows a single double per turn', async () => {
  const rooms = makeRooms();
  const table = rooms.createTable({ bootAmount: 200, isPrivate: true, category: TABLE_CATEGORY.BLIND });
  await seatTwo(table);

  const player = table.seats[table.hand.turnSeat];
  const { steps } = table.betOptions(player);

  assert.deepEqual(steps, [200, 400], 'the chaal and one double, nothing further');

  await assert.rejects(
    table.act(player.userId, ACTION.RAISE, { amount: 800 }),
    (error) => error.code === 'invalid_bet',
    'a second double is not on the ladder',
  );

  await rooms.shutdown();
});

test('a public blind table still keeps the full ladder', async () => {
  const rooms = makeRooms();
  const table = rooms.createTable({ bootAmount: 200, isPrivate: false, category: TABLE_CATEGORY.BLIND });
  await seatTwo(table);

  const steps = table.betOptions(table.seats[table.hand.turnSeat]).steps;
  assert.ok(steps.length > 2, 'public blind tables can keep doubling');

  await rooms.shutdown();
});

// ------------------------------------------------------------ the pot cap

test('every table but a public blind one carries a pot ceiling', async () => {
  const rooms = makeRooms();

  // A private table's own ceiling wins whichever category it is.
  assert.equal(rooms.createTable({ bootAmount: 200, isPrivate: true }).maxPot, 500000);
  assert.equal(
    rooms.createTable({ bootAmount: 200, isPrivate: true, category: 'blind' }).maxPot,
    500000,
  );

  // A public seen table is capped so a seen hand cannot run away...
  assert.equal(
    rooms.createTable({ bootAmount: 200, isPrivate: false, category: 'seen' }).maxPot,
    1200000,
  );
  // ...and a public blind one is not.
  assert.equal(
    rooms.createTable({ bootAmount: 200, isPrivate: false, category: 'blind' }).maxPot,
    0,
    'uncapped',
  );

  await rooms.shutdown();
});

test('the ceiling is reported to clients in the table snapshot', async () => {
  const rooms = makeRooms();
  const table = rooms.createTable({ bootAmount: 200, isPrivate: true });
  await seatTwo(table);

  assert.equal(table.serializeFor('a').maxPot, 500000);

  await rooms.shutdown();
});

test('a bet that would push the pot past the ceiling is not offered', async () => {
  const { timers } = createFakeTimers();
  const table = new Table({
    id: 'cap', code: 'CAP001',
    config: {
      maxPlayers: 5, minPlayers: 2, bootAmount: 200, turnTimeoutMs: 25000,
      maxBetRounds: 100, potLimitMultiplier: 1024, maxRaiseSteps: 8,
      nextHandDelayMs: 6000, maxPot: 5000,
    },
    timers,
    settle: () => ({}),
  });

  await seatTwo(table);

  // Pot is 400 after the boots; headroom is 4,600.
  table.hand.pot = 4000;
  const { steps } = table.betOptions(table.seats[table.hand.turnSeat]);

  for (const step of steps) {
    assert.ok(4000 + step <= 5000, `${step} keeps the pot under the ceiling`);
  }
  assert.deepEqual(steps, [200, 400, 800], '1600 would overshoot, so it is withheld');
});

test('reaching the ceiling ends the hand in a showdown', async () => {
  const { timers } = createFakeTimers();
  const settled = [];
  const table = new Table({
    id: 'cap2', code: 'CAP002',
    config: {
      maxPlayers: 5, minPlayers: 2, bootAmount: 200, turnTimeoutMs: 25000,
      maxBetRounds: 500, potLimitMultiplier: 1024, maxRaiseSteps: 8,
      nextHandDelayMs: 6000, maxPot: 5000,
    },
    timers,
    settle: ({ hand, entries }) => {
      settled.push({ hand, entries });
      return {};
    },
  });

  const ended = [];
  const showdowns = [];
  table.on('handEnded', (payload) => ended.push(payload));
  table.on('showdown', (payload) => showdowns.push(payload));

  await seatTwo(table);

  // Both players keep betting; only the pot cap can stop this.
  for (let i = 0; i < 200 && table.hand; i += 1) {
    const player = table.seats[table.hand.turnSeat];
    const { max } = table.betOptions(player);
    if (!max) break;
    const steps = table.betOptions(player).steps;
    await table.act(player.userId, steps.length > 1 ? ACTION.RAISE : ACTION.CHAAL, { amount: max });
  }

  assert.equal(table.hand, null, 'the hand ended on its own');
  assert.equal(ended.at(-1).reason, WIN_REASON.POT_LIMIT);
  assert.equal(showdowns.at(-1).reveals.length, 2, 'everyone still in shows their cards');
  assert.ok(ended.at(-1).winnerId, 'and the best hand takes the pot');

  assert.ok(ended.at(-1).pot <= 5000, `pot ${ended.at(-1).pot} never exceeded the ceiling`);
  assert.equal(
    settled.at(-1).entries.reduce((sum, entry) => sum + entry.delta, 0),
    0,
    'chips are still conserved',
  );
});

test('an uncapped table is unaffected by the ceiling logic', async () => {
  const rooms = makeRooms();
  const table = rooms.createTable({ bootAmount: 200, isPrivate: false, category: TABLE_CATEGORY.BLIND });
  await seatTwo(table);

  // With no cap the pot has unlimited headroom — and a public blind table has
  // neither a rung limit nor a per-bet ceiling, so only the player's own stack
  // bounds the ladder.
  const seat = table.seats[table.hand.turnSeat];
  const { steps, max } = table.betOptions(seat);
  assert.ok(steps.length > 8, `runs past the eight rungs of a capped ladder (${steps.length})`);
  assert.ok(max <= seat.chips, 'but never past what the player holds');
  assert.ok(max * 2 > seat.chips, 'and stops only where the next double would not fit');

  await rooms.shutdown();
});
