/**
 * The +/- raise stepper (requirement 9) and the turn timeout (requirement 10).
 *
 * Each "+" doubles the bet. The ladder the client steps through is computed and
 * validated server-side, so the amount can never exceed what the player holds
 * however the client behaves.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import Table from '../src/game/table.js';
import { ACTION, SEAT_STATE } from '../src/game/constants.js';
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
  maxRaiseSteps: 8,
  nextHandDelayMs: 6000,
  chatMaxHistory: 100,
  chatMaxLength: 140,
};

function makeTable(overrides = {}) {
  const { timers, advance } = createFakeTimers();
  const table = new Table({
    id: 'ladder-room',
    code: 'LADR01',
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

  const events = [];
  table.on('action', (payload) => events.push(payload));

  const seat = (id, chips = START) =>
    table.addPlayer({ userId: id, displayName: id, avatarUrl: null, chips, socketId: `s-${id}` });

  return { table, advance, seat, events };
}

const turnSeat = (table) => table.seats[table.hand.turnSeat];

// ------------------------------------------------------------- the ladder

test('each step doubles the previous amount', () => {
  const { table, seat, advance } = makeTable();
  seat('a');
  seat('b');
  advance(baseConfig.nextHandDelayMs);

  const player = turnSeat(table);
  const { steps } = table.betOptions(player);

  assert.equal(steps[0], BOOT, 'the first rung is the plain chaal');
  for (let i = 1; i < steps.length; i += 1) {
    assert.equal(steps[i], steps[i - 1] * 2, `step ${i} doubles step ${i - 1}`);
  }
  assert.deepEqual(steps, [100, 200, 400, 800, 1600, 3200, 6400, 12800]);
});

test('a seen player\'s ladder starts at double a blind player\'s', () => {
  const { table, seat, advance } = makeTable();
  seat('a');
  seat('b');
  advance(baseConfig.nextHandDelayMs);

  const player = turnSeat(table);
  assert.equal(table.betOptions(player).steps[0], BOOT, 'blind');

  table.act(player.userId, ACTION.SEE);
  assert.equal(table.betOptions(player).steps[0], BOOT * 2, 'seen pays double');
  assert.equal(table.betOptions(player).steps[1], BOOT * 4);
});

test('the ladder is capped by the number of steps configured', () => {
  const { table, seat, advance } = makeTable({ maxRaiseSteps: 3 });
  seat('a');
  seat('b');
  advance(baseConfig.nextHandDelayMs);

  assert.deepEqual(table.betOptions(turnSeat(table)).steps, [100, 200, 400]);
});

test('the ladder is capped by the pot limit', () => {
  const { table, seat, advance } = makeTable({ potLimitMultiplier: 4 });
  seat('a');
  seat('b');
  advance(baseConfig.nextHandDelayMs);

  const { steps, max } = table.betOptions(turnSeat(table));
  assert.deepEqual(steps, [100, 200, 400], 'nothing above 4 x boot');
  assert.equal(max, 400);
});

// --------------------------------------------- never more than you can pay

test('the ladder never offers more chips than the player holds', () => {
  const { table, seat, advance } = makeTable();
  seat('rich');
  // Can cover the boot, then holds 650 — so 100, 200 and 400 fit, 800 does not.
  seat('short', BOOT + 650);
  advance(baseConfig.nextHandDelayMs);

  const short = table.findSeat('short');
  const { steps, max } = table.betOptions(short);

  assert.equal(short.chips, 650, 'chips left after the boot');
  assert.deepEqual(steps, [100, 200, 400]);
  assert.equal(max, 400);
  for (const step of steps) {
    assert.ok(step <= short.chips, `${step} is affordable`);
  }
});

test('a player who cannot afford the base bet is offered no bet at all', () => {
  const { table, seat, advance } = makeTable();
  seat('rich');
  seat('broke', BOOT + 50); // 50 left, base bet is 100
  advance(baseConfig.nextHandDelayMs);

  const broke = table.findSeat('broke');
  const options = table.turnOptions(broke);

  assert.deepEqual(options.raiseSteps, []);
  assert.equal(options.chaal, null);
  assert.equal(options.raise, null);
  assert.equal(options.maxBet, null);
  assert.equal(options.canPack, true, 'packing is always available');
});

test('the turn payload carries the ladder and the player\'s stack', () => {
  const { table, seat, advance } = makeTable();
  seat('a');
  seat('b');
  advance(baseConfig.nextHandDelayMs);

  const options = table.turnOptions(turnSeat(table));

  assert.ok(Array.isArray(options.raiseSteps));
  assert.equal(options.raiseSteps[0], options.chaal);
  assert.equal(options.raiseSteps[1], options.raise);
  assert.equal(options.chips, START - BOOT, 'the client can show what is left');
  assert.equal(options.maxBet, options.raiseSteps.at(-1));
});

// ------------------------------------------------------- placing the bet

test('a raise can be placed at any rung of the ladder', () => {
  const { table, seat, advance, events } = makeTable();
  seat('a');
  seat('b');
  advance(baseConfig.nextHandDelayMs);

  const player = turnSeat(table);
  const potBefore = table.hand.pot;

  // Three taps of "+": 100 -> 200 -> 400 -> 800.
  table.act(player.userId, ACTION.RAISE, { amount: 800 });

  assert.equal(events.at(-1).amount, 800);
  assert.equal(table.hand.pot, potBefore + 800);
  assert.equal(player.chips, START - BOOT - 800);
  assert.equal(table.hand.stake, 800, 'a blind bet sets the stake');
});

test('omitting the amount keeps the old default behaviour', () => {
  const { table, seat, advance, events } = makeTable();
  seat('a');
  seat('b');
  advance(baseConfig.nextHandDelayMs);

  table.act(turnSeat(table).userId, ACTION.RAISE);
  assert.equal(events.at(-1).amount, BOOT * 2, 'a bare raise is still double');

  table.act(turnSeat(table).userId, ACTION.CHAAL);
  assert.equal(events.at(-1).action, ACTION.CHAAL);
});

test('an amount that is not on the ladder is refused', () => {
  const { table, seat, advance } = makeTable();
  seat('a');
  seat('b');
  advance(baseConfig.nextHandDelayMs);

  const player = turnSeat(table);

  for (const bad of [150, 999, 101, 1]) {
    assert.throws(
      () => table.act(player.userId, ACTION.RAISE, { amount: bad }),
      (error) => error.code === 'invalid_bet',
      `${bad} is not a rung`,
    );
  }
});

test('a bet larger than the player\'s stack is refused', () => {
  const { table, seat, advance } = makeTable();
  seat('rich');
  seat('short', BOOT + 650);
  advance(baseConfig.nextHandDelayMs);

  // Make sure the short stack is the one on turn.
  while (turnSeat(table).userId !== 'short') {
    table.act(turnSeat(table).userId, ACTION.CHAAL);
  }

  const short = table.findSeat('short');
  assert.equal(short.chips, 650);

  // 800 is a rung of the *unbounded* ladder but beyond this player's stack.
  assert.throws(
    () => table.act('short', ACTION.RAISE, { amount: 800 }),
    (error) => error.code === 'invalid_bet',
  );
  assert.throws(
    () => table.act('short', ACTION.RAISE, { amount: 200000 }),
    (error) => error.code === 'invalid_bet',
  );

  assert.equal(short.chips, 650, 'no chips moved on a refused bet');
});

test('non-integer and negative amounts are refused', () => {
  const { table, seat, advance } = makeTable();
  seat('a');
  seat('b');
  advance(baseConfig.nextHandDelayMs);

  const player = turnSeat(table);
  for (const bad of [100.5, -100, Number.NaN, Number.POSITIVE_INFINITY]) {
    assert.throws(
      () => table.act(player.userId, ACTION.RAISE, { amount: bad }),
      (error) => error.code === 'invalid_bet',
      `${bad} is rejected`,
    );
  }
});

test('a raise must be at least double the chaal', () => {
  const { table, seat, advance } = makeTable();
  seat('a');
  seat('b');
  advance(baseConfig.nextHandDelayMs);

  // The base rung is a chaal, not a raise.
  assert.throws(
    () => table.act(turnSeat(table).userId, ACTION.RAISE, { amount: BOOT }),
    (error) => error.code === 'invalid_bet',
  );
});

test('stepping up repeatedly stays inside the stack across a whole hand', () => {
  const { table, seat, advance } = makeTable();
  seat('a');
  seat('b');
  advance(baseConfig.nextHandDelayMs);

  // Both players keep taking the biggest bet available to them. Once a stack
  // has shrunk to a single rung that rung is a chaal, not a raise — which is
  // exactly the distinction a real client has to make.
  for (let i = 0; i < 30 && table.hand; i += 1) {
    const player = turnSeat(table);
    const { steps, max } = table.betOptions(player);

    if (!max) {
      table.act(player.userId, ACTION.PACK);
      continue;
    }

    const action = steps.length > 1 ? ACTION.RAISE : ACTION.CHAAL;
    table.act(player.userId, action, { amount: max });
    assert.ok(player.chips >= 0, 'a player can never be driven negative');
  }

  for (const player of table.occupiedSeats) {
    assert.ok(player.chips >= 0, `${player.userId} still has a non-negative stack`);
  }
});

test('a stack that affords only one rung can chaal but not raise', () => {
  const { table, seat, advance } = makeTable();
  seat('rich');
  // 150 left after the boot: the base 100 fits, 200 does not.
  seat('tight', BOOT + 150);
  advance(baseConfig.nextHandDelayMs);

  while (turnSeat(table).userId !== 'tight') {
    table.act(turnSeat(table).userId, ACTION.CHAAL);
  }

  const options = table.turnOptions(table.findSeat('tight'));
  assert.deepEqual(options.raiseSteps, [100], 'the "+" button has nowhere to go');
  assert.equal(options.chaal, 100);
  assert.equal(options.raise, null, 'so no raise is offered');

  assert.throws(
    () => table.act('tight', ACTION.RAISE, { amount: 100 }),
    (error) => error.code === 'invalid_bet',
  );

  table.act('tight', ACTION.CHAAL, { amount: 100 });
  assert.equal(table.findSeat('tight').chips, 50);
});

// ------------------------------------------------- requirement 10: timeout

test('a player who does not act on their turn is packed automatically', () => {
  const { table, seat, advance, events } = makeTable();
  for (const id of ['a', 'b', 'c']) seat(id);
  advance(baseConfig.nextHandDelayMs);

  const stalling = turnSeat(table).userId;
  advance(baseConfig.turnTimeoutMs);

  assert.equal(table.findSeat(stalling).status, SEAT_STATE.PACKED);

  const pack = events.find((event) => event.userId === stalling && event.reason === 'timeout');
  assert.ok(pack, 'the auto-pack is broadcast with a timeout reason');
  assert.equal(pack.action, ACTION.PACK);
  assert.notEqual(turnSeat(table).userId, stalling, 'play moved on');
});

test('the timeout still fires while a raise stepper is open', () => {
  // Sitting on the +/- control must not hold the table up.
  const { table, seat, advance } = makeTable();
  seat('a');
  seat('b');
  advance(baseConfig.nextHandDelayMs);

  const stalling = turnSeat(table).userId;
  table.act(stalling, ACTION.SEE); // looking at cards does not stop the clock
  advance(baseConfig.turnTimeoutMs);

  assert.equal(table.findSeat(stalling).status, SEAT_STATE.PACKED);
  assert.equal(table.hand, null, 'the last player standing took the pot');
});
