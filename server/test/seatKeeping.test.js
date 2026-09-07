/**
 * Requirement 31 (three missed turns in a row loses the seat, and so does
 * falling below the boot) and requirement 32 (the boot comes out of everyone
 * at the deal; anyone who cannot cover it is shown out).
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

test('three missed turns in a row loses the seat', () => {
  const { table, seat, advance, kicks } = makeTable();
  seat('alice');
  seat('bob');
  seat('carol');
  advance(baseConfig.nextHandDelayMs);

  const idler = turnUser(table);

  // Let hands run, with everyone but the idler playing on. Not every hand
  // reaches them — one can end first — so this counts actual misses rather
  // than assuming one per hand.
  for (let round = 0; round < 12 && table.findSeat(idler); round++) {
    if (!table.hand) advance(baseConfig.nextHandDelayMs);
    if (!table.hand) break;

    let guard = 0;
    while (table.hand && turnUser(table) !== idler && guard++ < 80) {
      table.act(turnUser(table), ACTION.CHAAL);
    }
    if (!table.hand) continue;

    const before = table.findSeat(idler).missedTurns;
    advance(TIMEOUT + 10);

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

test('playing a turn clears the missed-turn count', () => {
  const { table, seat, advance, kicks } = makeTable();
  seat('alice');
  seat('bob');
  seat('carol');
  advance(baseConfig.nextHandDelayMs);

  const player = turnUser(table);

  // Miss two, then turn up and play.
  advance(TIMEOUT + 10);
  assert.equal(table.findSeat(player).missedTurns, 1);

  while (table.hand && turnUser(table) !== player) table.act(turnUser(table), ACTION.CHAAL);
  if (!table.hand) advance(baseConfig.nextHandDelayMs);
  while (table.hand && turnUser(table) !== player) table.act(turnUser(table), ACTION.CHAAL);

  if (table.hand && table.findSeat(player)?.status === 'active') {
    table.act(player, ACTION.CHAAL);
    assert.equal(table.findSeat(player).missedTurns, 0, 'the slate is wiped');
  }

  assert.equal(kicks.length, 0, 'nobody was shown out');
});

// ------------------------------- requirements 31 and 32: covering the boot

test('a player who cannot cover the boot is shown out between hands', () => {
  const { table, seat, advance, kicks } = makeTable();
  seat('alice');
  seat('bob');
  const broke = seat('carol', BOOT - 1);

  advance(baseConfig.nextHandDelayMs);

  assert.equal(kicks.length, 1);
  assert.equal(kicks[0].userId, 'carol');
  assert.equal(kicks[0].reason, 'insufficient_chips');
  assert.match(kicks[0].message, /enough coins/i);
  assert.equal(table.findSeat('carol'), null);
  assert.ok(broke, 'was seated to begin with');
});

test('a player is never shown out mid-hand for being all in', () => {
  const { table, seat, advance, kicks } = makeTable();
  seat('alice');
  // Exactly the boot: after posting it they are on zero, mid-hand.
  seat('bob', BOOT);
  advance(baseConfig.nextHandDelayMs);

  assert.equal(table.findSeat('bob').chips, 0, 'all in on the ante');
  assert.equal(kicks.length, 0, 'still at the table while the hand runs');
  assert.ok(table.hand, 'and the hand is live');
});

test('the sweep runs again once the hand is over', () => {
  const { table, seat, advance, kicks } = makeTable();
  seat('alice');
  seat('bob', BOOT);
  advance(baseConfig.nextHandDelayMs);

  // Play it out; whoever loses their last chips cannot cover the next boot.
  while (table.hand) {
    const player = turnUser(table);
    table.act(player, player === 'bob' ? ACTION.PACK : ACTION.CHAAL);
  }
  advance(baseConfig.nextHandDelayMs);

  assert.ok(
    kicks.some((k) => k.userId === 'bob' && k.reason === 'insufficient_chips'),
    'the busted player was shown out',
  );
});

test('a table that empties out does not throw', () => {
  const { table, seat, advance } = makeTable();
  seat('alice', BOOT - 1);
  seat('bob', BOOT - 1);

  assert.doesNotThrow(() => advance(baseConfig.nextHandDelayMs * 2));
  assert.equal(table.playerCount, 0, 'both were shown out');
});
