import test from 'node:test';
import assert from 'node:assert/strict';
import Table, { GameError } from '../src/game/table.js';
import { ACTION, SEAT_STATE, TABLE_STATE, WIN_REASON } from '../src/game/constants.js';
import { parseCard } from '../src/game/deck.js';
import createFakeTimers from './helpers/fakeTimers.js';

const BOOT = 100;
const START_CHIPS = 200000;

const baseConfig = {
  maxPlayers: 5,
  minPlayers: 2,
  bootAmount: BOOT,
  turnTimeoutMs: 25000,
  maxBetRounds: 20,
  potLimitMultiplier: 1024,
  nextHandDelayMs: 6000,
  welcomeChips: START_CHIPS,
};

/**
 * Builds a table plus a recording of every event it emitted.
 *
 * Every mutator on the table (act, removePlayer, startHand, destroy) now runs
 * through its queue and returns a promise, and `advance` awaits each timer it
 * fires — so tests await all of them and are declared async.
 */
function makeTable(overrides = {}) {
  const { timers, advance } = createFakeTimers();
  const settled = [];

  const table = new Table({
    id: 'room-1',
    code: 'TEST01',
    config: { ...baseConfig, ...overrides },
    timers,
    settle: ({ hand, entries }) => {
      settled.push({ hand, entries });
      // Mirror the real settlement: return each player's post-hand balance.
      return Object.fromEntries(
        entries.map((entry) => {
          const seat = table.findSeat(entry.userId);
          const before = seat ? seat.chips : 0;
          // seat.chips already has the contribution removed, so only the
          // winnings need adding back.
          return [entry.userId, before + (entry.isWinner ? hand.pot : 0)];
        }),
      );
    },
  });

  const events = [];
  for (const name of ['handStarted', 'turn', 'action', 'showdown', 'handEnded', 'cards']) {
    table.on(name, (payload) => events.push({ name, payload }));
  }

  const seat = (id, chips = START_CHIPS) =>
    table.addPlayer({ userId: id, displayName: id, avatarUrl: null, chips, socketId: `s-${id}` });

  const last = (name) => [...events].reverse().find((event) => event.name === name)?.payload;
  const all = (name) => events.filter((event) => event.name === name).map((event) => event.payload);

  return { table, advance, events, settled, seat, last, all };
}

/** Forces a known deal so showdown outcomes are deterministic. */
const setHands = (table, byUserId) => {
  for (const [userId, codes] of Object.entries(byUserId)) {
    table.findSeat(userId).cards = codes.map(parseCard);
  }
};

const turnUser = (table) => table.seats[table.hand.turnSeat].userId;

// ---------------------------------------------------------------- seating

test('a table waits until the minimum number of players is seated', async () => {
  const { table, seat, advance } = makeTable();

  seat('alice');
  assert.equal(table.state, TABLE_STATE.WAITING);
  assert.equal(table.hand, null);

  seat('bob');
  assert.equal(table.state, TABLE_STATE.STARTING, 'two players triggers the start countdown');

  await advance(baseConfig.nextHandDelayMs);
  assert.equal(table.state, TABLE_STATE.BETTING);
  assert.ok(table.hand);
});

test('a table seats at most five players', () => {
  const { table, seat } = makeTable();
  for (const id of ['a', 'b', 'c', 'd', 'e']) seat(id);
  assert.equal(table.playerCount, 5);
  assert.ok(table.isFull);
  assert.throws(() => seat('f'), (error) => error.code === 'table_full');
});

test('the same player cannot take two seats', () => {
  const { seat } = makeTable();
  seat('alice');
  assert.throws(() => seat('alice'), (error) => error.code === 'already_seated');
});

test('a player who joins mid-hand sits out until the next deal', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  const late = seat('carol');
  assert.equal(late.status, SEAT_STATE.WAITING);
  assert.equal(late.cards.length, 0);
  assert.equal(table.activeSeats.length, 2);
});

test('a player who cannot cover the boot is dealt out', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  seat('broke', BOOT - 1);
  await advance(baseConfig.nextHandDelayMs);

  assert.equal(table.findSeat('broke').status, SEAT_STATE.WAITING);
  assert.equal(table.activeSeats.length, 2);
});

// ------------------------------------------------------------- dealing

test('every player is dealt three hidden cards and the boot is collected', async () => {
  const { table, seat, advance, last } = makeTable();
  seat('alice');
  seat('bob');
  seat('carol');
  await advance(baseConfig.nextHandDelayMs);

  for (const player of table.activeSeats) {
    assert.equal(player.cards.length, 3);
    assert.equal(player.isBlind, true, 'cards start face down');
    assert.equal(player.chips, START_CHIPS - BOOT);
    assert.equal(player.contributed, BOOT);
  }

  assert.equal(table.hand.pot, BOOT * 3);
  assert.equal(last('handStarted').pot, BOOT * 3);

  // The snapshot must not leak an unseen hand to its own owner either.
  assert.deepEqual(table.serializeFor('alice').you.cards, []);
});

test('a snapshot never contains another player\'s cards', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  await table.act(turnUser(table), ACTION.SEE);
  const view = table.serializeFor(turnUser(table));

  assert.equal(view.you.cards.length, 3, 'you can see your own hand once you look');
  for (const seatView of view.seats) {
    assert.equal(seatView.cards, undefined, 'no seat entry ever carries card faces');
  }
});

// ------------------------------------------------------------- turn order

test('turns open left of the dealer and rotate clockwise', async () => {
  const { table, seat, advance, all } = makeTable();
  for (const id of ['a', 'b', 'c']) seat(id);
  await advance(baseConfig.nextHandDelayMs);

  // Walk occupied seats clockwise from the dealer — seats can be sparse.
  const expected = [];
  let cursor = table.dealerSeat;
  while (expected.length < 3) {
    cursor = (cursor + 1) % table.seats.length;
    if (table.seats[cursor]) expected.push(table.seats[cursor].userId);
  }

  const order = [];
  for (let i = 0; i < 3; i += 1) {
    order.push(turnUser(table));
    await table.act(turnUser(table), ACTION.CHAAL);
  }

  assert.deepEqual(order, expected);
  assert.ok(all('turn').length >= 3);
});

test('acting out of turn is refused', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  const onTurn = turnUser(table);
  const other = table.activeSeats.find((player) => player.userId !== onTurn).userId;

  await assert.rejects(table.act(other, ACTION.CHAAL), (error) => error.code === 'not_your_turn');
});

test('a player not in the hand cannot act', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);
  seat('carol'); // sitting out

  await assert.rejects(table.act('carol', ACTION.CHAAL), (error) => error.code === 'not_in_hand');
  await assert.rejects(table.act('nobody', ACTION.CHAAL), (error) => error.code === 'not_seated');
});

// ------------------------------------------------------------- betting

test('a blind player bets the stake or double it; a seen player pays double that', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  const blind = table.findSeat(turnUser(table));
  let options = table.betOptions(blind);
  assert.equal(options.chaal, BOOT, 'blind: same amount');
  assert.equal(options.raise, BOOT * 2, 'blind: double');

  await table.act(blind.userId, ACTION.SEE);
  options = table.betOptions(blind);
  assert.equal(options.chaal, BOOT * 2, 'seen: same amount is double a blind');
  assert.equal(options.raise, BOOT * 4, 'seen: double');
});

test('a blind bet raises the stake; a seen bet raises it by half as much', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  const first = turnUser(table);
  await table.act(first, ACTION.RAISE); // blind, pays 2x boot
  assert.equal(table.hand.stake, BOOT * 2);
  assert.equal(table.hand.pot, BOOT * 2 + BOOT * 2);

  const second = turnUser(table);
  await table.act(second, ACTION.SEE);
  await table.act(second, ACTION.CHAAL); // seen, pays 2 x stake = 4x boot
  assert.equal(table.hand.pot, BOOT * 4 + BOOT * 4);
  assert.equal(table.hand.stake, BOOT * 2, 'stake stays in blind units');
});

test('seeing cards is free, reveals only your hand, and does not pass the turn', async () => {
  const { table, seat, advance, last } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  const player = turnUser(table);
  const before = table.findSeat(player).chips;

  await table.act(player, ACTION.SEE);

  assert.equal(table.findSeat(player).chips, before, 'seeing costs nothing');
  assert.equal(turnUser(table), player, 'the turn does not move');
  assert.equal(last('cards').userId, player);
  assert.equal(last('cards').cards.length, 3);
  await assert.rejects(table.act(player, ACTION.SEE), (error) => error.code === 'already_seen');
});

test('bets are capped by the pot limit', async () => {
  const { table, seat, advance } = makeTable({ potLimitMultiplier: 4 });
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  const player = table.findSeat(turnUser(table));
  await table.act(player.userId, ACTION.SEE);
  // Seen raise would be 4 x boot, and the cap is exactly 4 x boot.
  const options = table.betOptions(player);
  assert.equal(options.chaal, BOOT * 2);
  assert.equal(options.raise, BOOT * 4);
  assert.equal(options.max, BOOT * 4, 'the ladder stops at the pot limit');
});

test('a player who cannot afford a bet is offered no bet', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob', BOOT + 10); // can pay the boot, then has 10 left
  await advance(baseConfig.nextHandDelayMs);

  const poor = table.findSeat('bob');
  const options = table.turnOptions(poor);
  assert.equal(options.chaal, null);
  assert.equal(options.raise, null);
  assert.equal(options.canPack, true);
});

// -------------------------------------------------------------- packing

test('packing forfeits the hand and passes the turn', async () => {
  const { table, seat, advance, last } = makeTable();
  for (const id of ['a', 'b', 'c']) seat(id);
  await advance(baseConfig.nextHandDelayMs);

  const packer = turnUser(table);
  const potBefore = table.hand.pot;
  await table.act(packer, ACTION.PACK);

  assert.equal(table.findSeat(packer).status, SEAT_STATE.PACKED);
  assert.equal(table.hand.pot, potBefore, 'a pack adds nothing to the pot');
  assert.notEqual(turnUser(table), packer);
  assert.equal(last('action').action, ACTION.PACK);
});

test('the last player standing takes the pot without a show', async () => {
  const { table, seat, advance, last } = makeTable();
  seat('alice');
  seat('bob');
  seat('carol');
  await advance(baseConfig.nextHandDelayMs);

  const pot = table.hand.pot;
  const first = turnUser(table);
  await table.act(first, ACTION.PACK);
  const second = turnUser(table);
  await table.act(second, ACTION.PACK);

  const ended = last('handEnded');
  assert.equal(ended.reason, WIN_REASON.LAST_STANDING);
  assert.equal(ended.pot, pot);
  assert.deepEqual(ended.reveals, [], 'nobody has to show their cards');
  assert.equal(table.findSeat(ended.winnerId).status, SEAT_STATE.WON);
});

// -------------------------------------------------------------- timeouts

test('a player who does not act within 25 seconds is packed automatically', async () => {
  const { table, seat, advance, all } = makeTable();
  for (const id of ['a', 'b', 'c']) seat(id);
  await advance(baseConfig.nextHandDelayMs);

  const stalling = turnUser(table);
  await advance(baseConfig.turnTimeoutMs);

  assert.equal(table.findSeat(stalling).status, SEAT_STATE.PACKED);
  const timeoutPack = all('action').find(
    (action) => action.userId === stalling && action.reason === 'timeout',
  );
  assert.ok(timeoutPack, 'the pack is reported as a timeout');
  assert.notEqual(turnUser(table), stalling, 'play continues with the others');
});

test('the turn clock is announced with a deadline the client can count down', async () => {
  const { table, seat, advance, last } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  const turn = last('turn');
  assert.equal(turn.timeoutMs, 25000);
  assert.ok(turn.deadline > Date.now() + 20000);
  assert.ok(turn.options.chaal > 0);
});

test('acting resets the clock for the next player', async () => {
  const { table, seat, advance } = makeTable();
  for (const id of ['a', 'b', 'c']) seat(id);
  await advance(baseConfig.nextHandDelayMs);

  await advance(baseConfig.turnTimeoutMs - 1000); // nearly out of time
  const player = turnUser(table);
  await table.act(player, ACTION.CHAAL);

  const next = turnUser(table);
  await advance(baseConfig.turnTimeoutMs - 1000);
  assert.equal(table.findSeat(next).status, SEAT_STATE.ACTIVE, 'the next player got a full window');
});

// -------------------------------------------------------------- showdown

test('a show needs exactly two players left', async () => {
  const { table, seat, advance } = makeTable();
  for (const id of ['a', 'b', 'c']) seat(id);
  await advance(baseConfig.nextHandDelayMs);

  await assert.rejects(
    table.act(turnUser(table), ACTION.SHOW),
    (error) => error.code === 'show_unavailable',
  );
});

test('a show reveals both hands and the better hand takes the pot', async () => {
  const { table, seat, advance, last } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  setHands(table, {
    alice: ['As', 'Ah', 'Ad'], // trail of aces
    bob: ['2s', '7h', '9d'], // nothing
  });

  const caller = turnUser(table);
  await table.act(caller, ACTION.SHOW);

  const showdown = last('showdown');
  assert.equal(showdown.reveals.length, 2);
  assert.equal(showdown.reason, WIN_REASON.SHOW);

  const ended = last('handEnded');
  assert.equal(ended.winnerId, 'alice');
  assert.equal(ended.reason, WIN_REASON.SHOW);
  assert.ok(ended.reveals.find((reveal) => reveal.userId === 'alice').handName === 'Trail');
});

test('paying for a show costs the caller a chaal', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  const caller = table.findSeat(turnUser(table));
  const potBefore = table.hand.pot;
  const cost = table.showCost(caller);

  await table.act(caller.userId, ACTION.SHOW);

  assert.equal(cost, BOOT, 'a blind caller pays the blind stake');
  const settledPot = table.serializeFor('alice');
  assert.equal(settledPot.pot, 0, 'the pot is cleared once the hand ends');
  assert.equal(potBefore + cost, BOOT * 2 + BOOT);
});

test('an exact tie goes to the player who did not call the show', async () => {
  const { table, seat, advance, last } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  // Identical ranks, different suits — a true tie.
  setHands(table, {
    alice: ['As', '9s', '4s'],
    bob: ['Ah', '9h', '4h'],
  });

  const caller = turnUser(table);
  await table.act(caller, ACTION.SHOW);

  const ended = last('handEnded');
  assert.notEqual(ended.winnerId, caller, 'the caller loses a tie');
});

test('the round cap forces a showdown so a pot cannot run forever', async () => {
  const { table, seat, advance, last } = makeTable({ maxBetRounds: 3 });
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  setHands(table, {
    alice: ['As', 'Ks', 'Qs'], // pure sequence
    bob: ['2s', '7h', '9d'],
  });

  // Both players keep calling; the cap must end it.
  for (let i = 0; i < 40 && table.hand; i += 1) {
    await table.act(turnUser(table), ACTION.CHAAL);
  }

  assert.equal(table.hand, null, 'the hand ended on its own');
  const ended = last('handEnded');
  assert.equal(ended.reason, WIN_REASON.FORCED_SHOWDOWN);
  assert.equal(ended.winnerId, 'alice');
});

// ------------------------------------------------------------ settlement

test('the winner takes the whole pot and everyone else pays what they staked', async () => {
  const { table, seat, advance, settled, last } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  setHands(table, { alice: ['As', 'Ah', 'Ad'], bob: ['2s', '7h', '9d'] });

  const first = turnUser(table);
  await table.act(first, ACTION.CHAAL); // pot 300
  await table.act(turnUser(table), ACTION.SHOW); // caller pays another 100 -> pot 400

  const record = settled.at(-1);
  const ended = last('handEnded');

  const total = record.entries.reduce((sum, entry) => sum + entry.delta, 0);
  assert.equal(total, 0, 'chips are conserved: the pot is exactly redistributed');

  const winner = record.entries.find((entry) => entry.isWinner);
  assert.equal(winner.userId, 'alice');

  const contributed = record.hand.summary.reduce((sum, row) => sum + row.contributed, 0);
  assert.equal(contributed, ended.pot, 'the pot equals the sum of all contributions');
  assert.equal(record.entries.filter((entry) => entry.isWinner).length, 1, 'exactly one winner');
});

test('a hand record carries the full audit trail', async () => {
  const { table, seat, advance, settled } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);
  setHands(table, { alice: ['As', 'Ah', 'Ad'], bob: ['2s', '7h', '9d'] });
  await table.act(turnUser(table), ACTION.SHOW);

  const { hand } = settled.at(-1);
  assert.equal(hand.roomId, 'room-1');
  assert.equal(hand.handNo, 1);
  assert.equal(hand.bootAmount, BOOT);
  assert.ok(hand.startedAt <= hand.endedAt);
  assert.equal(hand.summary.length, 2);
  for (const row of hand.summary) {
    assert.equal(row.cards.length, 3, 'showdown hands are recorded');
    assert.ok(row.contributed > 0);
  }
});

test('a player who leaves mid-hand still forfeits their stake', async () => {
  const { table, seat, advance, settled } = makeTable();
  seat('alice');
  seat('bob');
  seat('carol');
  await advance(baseConfig.nextHandDelayMs);

  const quitter = turnUser(table);
  await table.act(quitter, ACTION.CHAAL);
  await table.removePlayer(quitter, 'left');

  // Finish the hand between the two who stayed.
  const remaining = table.activeSeats.map((player) => player.userId);
  await table.act(turnUser(table), ACTION.PACK);

  const record = settled.at(-1);
  const quitterEntry = record.entries.find((entry) => entry.userId === quitter);

  assert.ok(quitterEntry, 'the departed player is still settled');
  assert.equal(quitterEntry.delta, -(BOOT + BOOT), 'their boot and chaal stay in the pot');
  assert.equal(record.entries.reduce((sum, entry) => sum + entry.delta, 0), 0);
  assert.ok(remaining.includes(record.entries.find((entry) => entry.isWinner).userId));
});

test('the next hand starts automatically and the dealer button moves', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  const firstDealer = table.dealerSeat;
  await table.act(turnUser(table), ACTION.PACK); // hand 1 ends

  assert.equal(table.handNo, 1);
  await advance(baseConfig.nextHandDelayMs);

  assert.equal(table.handNo, 2, 'a new hand was dealt');
  assert.notEqual(table.dealerSeat, firstDealer, 'the dealer button rotated');
});

test('play stops when only one funded player remains', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);

  await table.act(turnUser(table), ACTION.PACK);
  await table.removePlayer('bob');
  await advance(baseConfig.nextHandDelayMs * 3);

  assert.equal(table.state, TABLE_STATE.WAITING);
  assert.equal(table.hand, null);
});

test('a destroyed table stops all of its timers', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  await table.destroy();
  await advance(baseConfig.nextHandDelayMs * 5);
  assert.equal(table.hand, null, 'no hand is dealt after destroy');
});

test('unknown actions are rejected', async () => {
  const { table, seat, advance } = makeTable();
  seat('alice');
  seat('bob');
  await advance(baseConfig.nextHandDelayMs);
  await assert.rejects(
    table.act(turnUser(table), 'steal_the_pot'),
    (error) => error instanceof GameError && error.code === 'unknown_action',
  );
});
