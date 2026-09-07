/**
 * Requirement 31 (three missed turns in a row loses the seat, and so does
 * falling below the boot) and requirement 32 (the boot comes out of everyone
 * at the deal; anyone who cannot cover it is shown out).
 *
 * Every mutator on the table (act, removePlayer, startHand) runs through its
 * queue and returns a promise, and `advance` awaits each timer it fires — so
 * the tests await all of them and are declared async.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import Table from '../src/game/table.js';
import { ACTION } from '../src/game/constants.js';
import createFakeTimers from './helpers/fakeTimers.js';

const BOOT = 200;
const START = 50000;
const TIMEOUT = 25000;

const baseConfig = {
  maxPlayers: 5,
  minPlayers: 2,
  bootAmount: BOOT,
  turnTimeoutMs: TIMEOUT,
  maxBetRounds: 40,
  potLimitMultiplier: 1024,
  maxRaiseSteps: 8,
  maxBlindMoves: 4,
  maxMissedTurns: 3,
  nextHandDelayMs: 6000,
  chatMaxHistory: 100,
  chatMaxLength: 140,
};

function makeTable(overrides = {}) {
  const { timers, advance } = createFakeTimers();
  const kicks = [];

  const table = new Table({
    id: 'seat-room',
    code: 'SEAT01',
    config: { ...baseConfig, ...overrides },
    timers,
    settle: ({ hand, entries }) =>
      Object.fromEntries(
        entries.map((e) => {
          const seat = table.findSeat(e.userId);
          return [e.userId, (seat ? seat.chips : 0) + (e.isWinner ? hand.pot : 0)];
        }),
      ),
  });

  // Stand in for the room manager, which is what actually frees the seat.
  // The table announces a kick synchronously, mid-operation; the removal it
  // asks for queues up behind whatever the table is doing at the time, so a
  // test that wants to see the seat freed must `await table.settled()` first.
  table.on('kick', ({ userId, reason, message }) => {
    kicks.push({ userId, reason, message });
    table.removePlayer(userId, reason);
  });

  const seat = (id, chips = START) =>
    table.addPlayer({
      userId: id,
      displayName: id.toUpperCase(),
      avatarUrl: null,
      chips,
      socketId: `s-${id}`,
    });

  return { table, advance, seat, kicks };
}

const turnUser = (table) => table.seats[table.hand.turnSeat].userId;

// ------------------------------------------------- requirement 31: idling

test('three missed turns in a row loses the seat', async () => {
  const { table, seat, advance, kicks } = makeTable();
  seat('alice');
  seat('bob');
  seat('carol');
  await advance(baseConfig.nextHandDelayMs);

  const idler = turnUser(table);

  // Let hands run, with everyone but the idler playing on. Not every hand
  // reaches them — one can end first — so this counts actual misses rather
  // than assuming one per hand.
  for (let round = 0; round < 12 && table.findSeat(idler); round++) {
    if (!table.hand) await advance(baseConfig.nextHandDelayMs);
    if (!table.hand) break;

    let guard = 0;
    while (table.hand && turnUser(table) !== idler && guard++ < 80) {
      await table.act(turnUser(table), ACTION.CHAAL);
    }
    if (!table.hand) continue;

    const before = table.findSeat(idler).missedTurns;
    await advance(TIMEOUT + 10);
    // A kick frees the seat through the queue, not on the spot.
    await table.settled();

    if (before < baseConfig.maxMissedTurns - 1) {
      assert.ok(table.findSeat(idler), `still seated after ${before + 1} miss(es)`);
    }
  }

  assert.equal(kicks.length, 1, 'shown out exactly once');
  assert.equal(kicks[0].userId, idler);
  assert.equal(kicks[0].reason, 'idle');
  assert.match(kicks[0].message, /missed turns/i);
  assert.equal(table.findSeat(idler), null, 'the seat is free again');
});

test('a player is told their own missed-turn count, and nobody else is', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  seat('carol');
  await advance(baseConfig.nextHandDelayMs);

  const idler = turnUser(table);
  const other = ['alice', 'bob', 'carol'].find((id) => id !== idler);

  const mine = table.serializeFor(idler).you;
  assert.equal(mine.missedTurns, 0, 'nothing missed yet');
  assert.equal(mine.maxMissedTurns, baseConfig.maxMissedTurns,
    'and what the allowance is, so the warning can count down');

  await advance(TIMEOUT + 10);
  assert.equal(table.serializeFor(idler).you.missedTurns, 1);

  // It is a warning to the player it concerns, not a tell about them: the
  // count is in `you` and is nowhere in what anyone else receives.
  const theirs = JSON.stringify(table.serializeFor(other).seats);
  assert.equal(theirs.includes('missedTurns'), false);

  table.shutdown?.();
});

test('playing a turn clears the missed-turn count', async () => {
  const { table, seat, advance, kicks } = makeTable();
  seat('alice');
  seat('bob');
  seat('carol');
  await advance(baseConfig.nextHandDelayMs);

  const player = turnUser(table);

  // Miss two, then turn up and play.
  await advance(TIMEOUT + 10);
  assert.equal(table.findSeat(player).missedTurns, 1);

  while (table.hand && turnUser(table) !== player) await table.act(turnUser(table), ACTION.CHAAL);
  if (!table.hand) await advance(baseConfig.nextHandDelayMs);
  while (table.hand && turnUser(table) !== player) await table.act(turnUser(table), ACTION.CHAAL);

  if (table.hand && table.findSeat(player)?.status === 'active') {
    await table.act(player, ACTION.CHAAL);
    assert.equal(table.findSeat(player).missedTurns, 0, 'the slate is wiped');
  }

  assert.equal(kicks.length, 0, 'nobody was shown out');
});

// ------------------------------- requirements 31 and 32: covering the boot

test('a player who cannot cover the boot is shown out between hands', async () => {
  const { table, seat, advance, kicks } = makeTable();
  seat('alice');
  seat('bob');
  const broke = seat('carol', BOOT - 1);

  await advance(baseConfig.nextHandDelayMs);
  // The deal asks for the kick; the removal runs once the deal has finished.
  await table.settled();

  assert.equal(kicks.length, 1);
  assert.equal(kicks[0].userId, 'carol');
  assert.equal(kicks[0].reason, 'insufficient_chips');
  assert.match(kicks[0].message, /enough coins/i);
  assert.equal(table.findSeat('carol'), null);
  assert.ok(broke, 'was seated to begin with');
});

test('a player is never shown out mid-hand for being all in', async () => {
  const { table, seat, advance, kicks } = makeTable();
  seat('alice');
  // Exactly the boot: after posting it they are on zero, mid-hand.
  seat('bob', BOOT);
  await advance(baseConfig.nextHandDelayMs);
  await table.settled();

  assert.equal(table.findSeat('bob').chips, 0, 'all in on the ante');
  assert.equal(kicks.length, 0, 'still at the table while the hand runs');
  assert.ok(table.hand, 'and the hand is live');
});

test('the sweep runs again once the hand is over', async () => {
  const { table, seat, advance, kicks } = makeTable();
  seat('alice');
  seat('bob', BOOT);
  await advance(baseConfig.nextHandDelayMs);

  // Play it out; whoever loses their last chips cannot cover the next boot.
  while (table.hand) {
    const player = turnUser(table);
    await table.act(player, player === 'bob' ? ACTION.PACK : ACTION.CHAAL);
  }
  await advance(baseConfig.nextHandDelayMs);
  await table.settled();

  assert.ok(
    kicks.some((k) => k.userId === 'bob' && k.reason === 'insufficient_chips'),
    'the busted player was shown out',
  );
});

test('a table that empties out does not throw', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice', BOOT - 1);
  seat('bob', BOOT - 1);

  await assert.doesNotReject(async () => {
    await advance(baseConfig.nextHandDelayMs * 2);
    await table.settled();
  });
  assert.equal(table.playerCount, 0, 'both were shown out');
});
