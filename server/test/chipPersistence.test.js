/**
 * Chips are banked as they are bet, not only when the hand ends.
 *
 * The account has to be right at every moment, not just at the end of a hand:
 * a process that dies mid-hand must not hand everybody their stake back, and a
 * player who walks out mid-hand does not get their contribution returned.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import Table from '../src/game/table.js';
import { ACTION, SEAT_STATE } from '../src/game/constants.js';
import createFakeTimers from './helpers/fakeTimers.js';

const BOOT = 200;
const START = 100000;

const baseConfig = {
  maxPlayers: 5,
  minPlayers: 2,
  bootAmount: BOOT,
  turnTimeoutMs: 25000,
  maxBetRounds: 40,
  potLimitMultiplier: 1024,
  maxRaiseSteps: 8,
  maxBlindMoves: 4,
  nextHandDelayMs: 6000,
  chatMaxHistory: 100,
  chatMaxLength: 140,
};

/**
 * A table backed by a toy ledger, so the test can watch the account move
 * rather than only inspecting the seats.
 */
function makeTable(overrides = {}) {
  const { timers, advance } = createFakeTimers();
  const accounts = new Map();
  const movements = [];

  const table = new Table({
    id: 'bank-room',
    code: 'BANK01',
    config: { ...baseConfig, ...overrides },
    timers,
    persistChips: ({ userId, delta, reason }) => {
      const before = accounts.get(userId) ?? 0;
      const after = before + delta;
      assert.ok(after >= 0, `${userId} went negative`);
      accounts.set(userId, after);
      movements.push({ userId, delta, reason });
    },
    settle: ({ hand, entries }) => {
      const balances = {};
      for (const entry of entries) {
        const after = (accounts.get(entry.userId) ?? 0) + entry.delta;
        accounts.set(entry.userId, after);
        balances[entry.userId] = after;
        movements.push({ userId: entry.userId, delta: entry.delta, reason: 'settle' });
      }
      return balances;
    },
  });

  const seat = (id, chips = START) => {
    accounts.set(id, chips);
    return table.addPlayer({
      userId: id,
      displayName: id.toUpperCase(),
      avatarUrl: null,
      chips,
      socketId: `s-${id}`,
    });
  };

  return { table, advance, seat, accounts, movements };
}

const turnUser = (table) => table.seats[table.hand.turnSeat].userId;
const total = (accounts) => [...accounts.values()].reduce((a, b) => a + b, 0);

test('the boot leaves the account the moment it is posted', () => {
  const { table, seat, advance, accounts } = makeTable();
  seat('alice');
  seat('bob');
  advance(baseConfig.nextHandDelayMs);

  // Both antes are already gone, before anyone has acted.
  assert.equal(accounts.get('alice'), START - BOOT);
  assert.equal(accounts.get('bob'), START - BOOT);
  assert.equal(table.hand.pot, BOOT * 2);
});

test('every chaal is banked as it is made', () => {
  const { table, seat, advance, accounts } = makeTable();
  seat('alice');
  seat('bob');
  advance(baseConfig.nextHandDelayMs);

  const player = turnUser(table);
  const before = accounts.get(player);
  const stake = table.hand.stake;

  table.act(player, ACTION.CHAAL);

  assert.equal(accounts.get(player), before - stake, 'the account moved with the bet');
  assert.equal(table.findSeat(player).chips, accounts.get(player), 'seat and account agree');
});

test('the winner is paid the pot and nobody is charged twice', () => {
  const { table, seat, advance, accounts } = makeTable();
  seat('alice');
  seat('bob');
  advance(baseConfig.nextHandDelayMs);

  const first = turnUser(table);
  table.act(first, ACTION.CHAAL);

  const loser = turnUser(table);
  const pot = table.hand.pot;
  const winner = table.activeSeats.find((s) => s.userId !== loser).userId;
  const winnerBefore = accounts.get(winner);
  const loserBefore = accounts.get(loser);

  table.act(loser, ACTION.PACK);

  assert.equal(accounts.get(winner), winnerBefore + pot, 'paid exactly the pot');
  assert.equal(accounts.get(loser), loserBefore, 'already paid; not charged again');
  assert.equal(total(accounts), START * 2, 'chips are conserved');
});

test('a player who walks out mid-hand does not get their stake back', () => {
  const { table, seat, advance, accounts } = makeTable();
  seat('alice');
  seat('bob');
  seat('carol');
  advance(baseConfig.nextHandDelayMs);

  const quitter = turnUser(table);
  table.act(quitter, ACTION.CHAAL);

  const staked = table.findSeat(quitter).contributed;
  const afterBetting = accounts.get(quitter);
  assert.equal(afterBetting, START - staked);

  table.removePlayer(quitter, 'left');

  // Walking out settles nothing back: the chips are in the pot and stay there.
  assert.equal(accounts.get(quitter), START - staked, 'stake stays in the pot');

  // And when the hand finishes, they are still not refunded.
  while (table.hand && table.activeSeats.length > 1) {
    table.act(turnUser(table), ACTION.PACK);
  }
  assert.equal(accounts.get(quitter), START - staked, 'still not refunded at settlement');
  assert.equal(total(accounts), START * 3, 'chips are conserved');
});

test('chips are conserved across a long hand of raises', () => {
  const { table, seat, advance, accounts } = makeTable();
  seat('alice');
  seat('bob');
  seat('carol');
  advance(baseConfig.nextHandDelayMs);

  for (let i = 0; i < 9 && table.hand; i++) {
    const player = turnUser(table);
    const options = table.betOptions(table.findSeat(player));
    // Raise when there is a rung to raise to, otherwise call.
    table.act(player, options.steps.length > 1 ? ACTION.RAISE : ACTION.CHAAL,
      { amount: options.steps.length > 1 ? options.steps[1] : options.steps[0] });
  }

  while (table.hand && table.activeSeats.length > 1) {
    table.act(turnUser(table), ACTION.PACK);
  }

  assert.equal(total(accounts), START * 3, 'nothing was created or destroyed');
});

test('a seat and its account never disagree', () => {
  const { table, seat, advance, accounts } = makeTable();
  seat('alice');
  seat('bob');
  advance(baseConfig.nextHandDelayMs);

  for (let i = 0; i < 4 && table.hand; i++) {
    const player = turnUser(table);
    table.act(player, ACTION.CHAAL);

    for (const s of table.occupiedSeats) {
      if (s.status === SEAT_STATE.ACTIVE) {
        assert.equal(s.chips, accounts.get(s.userId), `${s.userId} out of step`);
      }
    }
  }
});
