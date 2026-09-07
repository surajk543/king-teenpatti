/**
 * Blind play limits.
 *
 * A player may look at their own cards whenever they like — it costs nothing
 * and changes nothing for anyone else — but they still only act on their turn.
 * And nobody rides a whole hand blind: after a set number of blind bets the
 * cards turn face up by themselves.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import Table from '../src/game/table.js';
import { ACTION } from '../src/game/constants.js';
import createFakeTimers from './helpers/fakeTimers.js';

const BOOT = 200;
const START = 5_000_000;

const baseConfig = {
  maxPlayers: 5,
  minPlayers: 2,
  bootAmount: BOOT,
  turnTimeoutMs: 25000,
  maxBetRounds: 40,
  potLimitMultiplier: 1_048_576,
  maxRaiseSteps: 8,
  maxBlindMoves: 4,
  nextHandDelayMs: 6000,
  chatMaxHistory: 100,
  chatMaxLength: 140,
};

function makeTable(overrides = {}) {
  const { timers, advance } = createFakeTimers();

  const table = new Table({
    id: 'blind-room',
    code: 'BLND01',
    config: { ...baseConfig, ...overrides },
    timers,
    settle: ({ hand, entries }) =>
      Object.fromEntries(
        entries.map((entry) => {
          const seat = table.findSeat(entry.userId);
          return [entry.userId, (seat ? seat.chips : 0) + (entry.isWinner ? hand.pot : 0)];
        }),
      ),
  });

  const seat = (id, chips = START) =>
    table.addPlayer({
      userId: id,
      displayName: id.toUpperCase(),
      avatarUrl: null,
      chips,
      socketId: `s-${id}`,
    });

  return { table, advance, seat };
}

const turnUser = (table) => table.seats[table.hand.turnSeat].userId;
const otherUser = (table, notThis) =>
  table.activeSeats.find((s) => s.userId !== notThis).userId;

// ----------------------------------------------- looking out of turn

test('a player may see their cards when it is not their turn', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  const waiting = otherUser(table, turnUser(table));
  assert.equal(table.findSeat(waiting).isBlind, true);

  // Not their turn, and yet allowed.
  await assert.doesNotReject(table.act(waiting, ACTION.SEE));
  assert.equal(table.findSeat(waiting).isBlind, false);
});

test('seeing out of turn does not hand the player the turn', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  const onTurn = turnUser(table);
  const waiting = otherUser(table, onTurn);

  await table.act(waiting, ACTION.SEE);
  assert.equal(turnUser(table), onTurn, 'the turn stays where it was');
});

test('a player still cannot bet out of turn after looking', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  const waiting = otherUser(table, turnUser(table));
  await table.act(waiting, ACTION.SEE);

  await assert.rejects(
    table.act(waiting, ACTION.CHAAL),
    (error) => error.code === 'not_your_turn',
  );
});

// ----------------------------------------------- the blind-move cap

test('the cards turn face up after the capped number of blind bets', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  const player = turnUser(table);
  const seatOf = () => table.findSeat(player);

  for (let move = 1; move <= baseConfig.maxBlindMoves; move++) {
    // Walk round to this player and bet blind.
    while (turnUser(table) !== player) await table.act(turnUser(table), ACTION.CHAAL);

    assert.equal(seatOf().isBlind, true, `still blind before move ${move}`);
    await table.act(player, ACTION.CHAAL);
    assert.equal(seatOf().blindMoves, move);
  }

  assert.equal(seatOf().isBlind, false, 'the cap turned the cards face up');
});

test('the capped bet is itself still charged at the blind rate', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  const player = turnUser(table);
  const seatOf = () => table.findSeat(player);

  for (let move = 1; move < baseConfig.maxBlindMoves; move++) {
    while (turnUser(table) !== player) await table.act(turnUser(table), ACTION.CHAAL);
    await table.act(player, ACTION.CHAAL);
  }

  while (turnUser(table) !== player) await table.act(turnUser(table), ACTION.CHAAL);

  // The last blind bet costs one stake, not the two a seen player pays. The
  // reveal happens after the chips are down.
  const stake = table.hand.stake;
  const before = seatOf().chips;
  await table.act(player, ACTION.CHAAL);

  assert.equal(before - seatOf().chips, stake, 'charged at the blind rate');
  assert.equal(seatOf().isBlind, false, 'and only then turned face up');
});

test('a player who looked early is never auto-seen', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  const player = turnUser(table);
  await table.act(player, ACTION.SEE);
  assert.equal(table.findSeat(player).isBlind, false);

  for (let move = 0; move < baseConfig.maxBlindMoves + 2; move++) {
    while (turnUser(table) !== player) await table.act(turnUser(table), ACTION.CHAAL);
    await table.act(player, ACTION.CHAAL);
    // Bets made after looking are not blind ones, so nothing accrues.
    assert.equal(table.findSeat(player).blindMoves, 0);
  }
});

test('the counter starts again on the next hand', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  const player = turnUser(table);
  while (turnUser(table) !== player) await table.act(turnUser(table), ACTION.CHAAL);
  await table.act(player, ACTION.CHAAL);
  assert.equal(table.findSeat(player).blindMoves, 1);

  // End the hand and deal the next one.
  await table.act(turnUser(table), ACTION.PACK);
  await advance(baseConfig.nextHandDelayMs);

  assert.equal(table.findSeat(player).blindMoves, 0);
  assert.equal(table.findSeat(player).isBlind, true);
});

// ------------------------------------------- what the table can see of a bet

test('a seat reports its last bet as well as its running total', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  const player = turnUser(table);
  const view = () => table.serializeFor('watcher').seats.find((s) => s.userId === player);

  assert.equal(view().lastBet, 0, 'the boot is not a bet');
  const contributedBefore = view().contributed;

  await table.act(player, ACTION.CHAAL);
  const after = view();

  assert.ok(after.lastBet > 0, 'the last bet is reported');
  assert.equal(after.contributed, contributedBefore + after.lastBet);
  assert.equal(after.lastAction, ACTION.CHAAL);
});

test('the last bet is cleared when the next hand is dealt', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  const player = turnUser(table);
  await table.act(player, ACTION.CHAAL);
  assert.ok(table.findSeat(player).lastBet > 0);

  await table.act(turnUser(table), ACTION.PACK);
  await advance(baseConfig.nextHandDelayMs);

  assert.equal(table.findSeat(player).lastBet, 0);
  assert.equal(table.findSeat(player).lastAction, null);
});
