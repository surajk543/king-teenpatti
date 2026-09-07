/**
 * The sideshow: the player on turn may ask the player on their right to
 * compare hands privately, and the weaker of the two packs.
 *
 * The rules being pinned down here are that it needs three players and two
 * seen hands, that only the player who was asked may answer, that the request
 * expires by itself, that it can be asked only once per turn, and — the part
 * that is easy to get wrong — that the turn stays with the asker throughout.
 *
 * Every mutator on the table (act, respondToSideshow, removePlayer, startHand)
 * runs through its queue and returns a promise, and `advance` awaits each
 * timer it fires — so the tests await all of them and are declared async.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import Table from '../src/game/table.js';
import { ACTION, SEAT_STATE, TABLE_CATEGORY } from '../src/game/constants.js';
import { parseCard } from '../src/game/deck.js';
import createFakeTimers from './helpers/fakeTimers.js';

const BOOT = 100;
const START = 100000;
const SIDESHOW_MS = 6000;

const baseConfig = {
  maxPlayers: 5,
  minPlayers: 2,
  bootAmount: BOOT,
  turnTimeoutMs: 25000,
  maxBetRounds: 20,
  potLimitMultiplier: 1024,
  maxRaiseSteps: 8,
  maxBlindMoves: 4,
  nextHandDelayMs: 6000,
  chatMaxHistory: 100,
  chatMaxLength: 140,
  sideshowTimeoutMs: SIDESHOW_MS,
  sideshowMinPlayers: 3,
};

/**
 * A table with `count` players seated and a hand under way, everybody having
 * seen their cards — the state a sideshow needs.
 */
async function makeTable({ count = 3, ...overrides } = {}) {
  const { timers, advance } = createFakeTimers();

  const table = new Table({
    id: 'sideshow-room',
    code: 'SIDE01',
    category: TABLE_CATEGORY.SEEN,
    config: { ...baseConfig, ...overrides },
    timers,
    settle: () => ({}),
  });

  const ids = [];
  for (let i = 0; i < count; i += 1) {
    const id = `p${i}`;
    ids.push(id);
    table.addPlayer({
      userId: id, displayName: id.toUpperCase(), avatarUrl: null, chips: START, socketId: `s-${id}`,
    });
  }

  const events = [];
  for (const name of ['sideshowRequested', 'sideshowReveal', 'sideshowResolved']) {
    table.on(name, (payload) => events.push({ name, payload }));
  }

  await table.startHand();
  for (const id of ids) await table.act(id, ACTION.SEE);

  const onTurn = () => table.seats[table.hand.turnSeat];
  /** Who a sideshow from `userId` would go to. */
  const rightOf = (userId) => {
    const seat = table.findSeat(userId);
    return table.seats[table._rightActiveSeat(seat.seatIndex)];
  };
  /** Stacks a specific hand on a seat, so the comparison has a known answer. */
  const giveCards = (userId, codes) => {
    table.findSeat(userId).cards = codes.map(parseCard);
  };
  const named = (name) => events.filter((event) => event.name === name).map((event) => event.payload);

  return { table, advance, ids, events, named, onTurn, rightOf, giveCards };
}

// ------------------------------------------------------------- availability

test('the sideshow button is offered to the player on turn and nobody else', async () => {
  const { table, onTurn, rightOf } = await makeTable();

  const actor = onTurn();
  const options = table.turnOptions(actor);
  assert.equal(options.canSideshow, true);
  assert.equal(options.sideshowWith, rightOf(actor.userId).displayName);

  // Everyone else is offered nothing, because it is not their turn.
  for (const seat of table.seats.filter((s) => s && s !== actor)) {
    assert.equal(table.turnOptions(seat).canSideshow, false);
    assert.equal(table.sideshowBlockedReason(seat), 'not_your_turn');
  }
});

test('a sideshow needs three players in the hand', async () => {
  const { table, onTurn } = await makeTable({ count: 2 });

  const actor = onTurn();
  assert.equal(table.sideshowBlockedReason(actor), 'too_few_players');
  assert.equal(table.turnOptions(actor).canSideshow, false);
  await assert.rejects(table.act(actor.userId, ACTION.SIDESHOW), { code: 'too_few_players' });
});

test('both hands must have been seen', async () => {
  const { table, onTurn, rightOf } = await makeTable();

  // Put the player on the right back to blind: there is nothing to compare.
  const actor = onTurn();
  const right = rightOf(actor.userId);
  right.isBlind = true;
  assert.equal(table.sideshowBlockedReason(actor), 'neighbour_is_blind');

  right.isBlind = false;
  actor.isBlind = true;
  assert.equal(table.sideshowBlockedReason(actor), 'you_are_blind');
});

test('the request goes to the player on the right, who acted immediately before', async () => {
  const { table, onTurn, rightOf, named } = await makeTable({ count: 4 });

  // Play one bet so the turn has moved and "before" means something.
  await table.act(onTurn().userId, ACTION.CHAAL);

  const actor = onTurn();
  const previous = rightOf(actor.userId);
  await table.act(actor.userId, ACTION.SIDESHOW);

  const [request] = named('sideshowRequested');
  assert.equal(request.fromUserId, actor.userId);
  assert.equal(request.toUserId, previous.userId);
  // No cards travel with the request.
  assert.equal(request.cards, undefined);
  // And it is in the table state, so a reconnecting client can restore it.
  assert.equal(table.serializeFor(actor.userId).sideshow.toUserId, previous.userId);
});

// ------------------------------------------------------------- answering it

test('only the player who was asked can answer', async () => {
  const { table, ids, onTurn, rightOf } = await makeTable();

  const actor = onTurn();
  const asked = rightOf(actor.userId);
  await table.act(actor.userId, ACTION.SIDESHOW);

  const bystander = ids.find((id) => id !== actor.userId && id !== asked.userId);
  await assert.rejects(table.respondToSideshow(bystander, true), { code: 'not_your_sideshow' });
  // Not even the player who asked can accept on their behalf.
  await assert.rejects(table.respondToSideshow(actor.userId, true), { code: 'not_your_sideshow' });

  await table.respondToSideshow(asked.userId, false);
  await assert.rejects(table.respondToSideshow(asked.userId, false), { code: 'no_sideshow' });
});

test('a declined sideshow packs nobody and hands the turn straight back', async () => {
  const { table, onTurn, rightOf, named } = await makeTable();

  const actor = onTurn();
  const asked = rightOf(actor.userId);
  await table.act(actor.userId, ACTION.SIDESHOW);
  await table.respondToSideshow(asked.userId, false);

  const [resolved] = named('sideshowResolved');
  assert.equal(resolved.accepted, false);
  assert.equal(resolved.reason, 'declined');
  assert.equal(resolved.packedUserId, null);
  // Nobody saw anything.
  assert.equal(named('sideshowReveal').length, 0);

  assert.equal(asked.status, SEAT_STATE.ACTIVE);
  assert.equal(table.hand.turnSeat, actor.seatIndex);
  assert.ok(table.turnOptions(actor).chaal > 0, 'they can still bet');
});

test('an unanswered request is rejected after six seconds', async () => {
  const { table, advance, onTurn, named } = await makeTable();

  const actor = onTurn();
  await table.act(actor.userId, ACTION.SIDESHOW);
  assert.ok(table.hand.sideshow);

  await advance(SIDESHOW_MS - 1);
  assert.ok(table.hand.sideshow, 'still standing just before the deadline');

  await advance(1);
  assert.equal(table.hand.sideshow, null);
  assert.equal(named('sideshowResolved')[0].reason, 'timeout');
  assert.equal(table.hand.turnSeat, actor.seatIndex);
});

test('the turn clock stops while a request stands and restarts full afterwards', async () => {
  const { table, advance, onTurn, rightOf } = await makeTable();

  const actor = onTurn();
  const asked = rightOf(actor.userId);

  await advance(20000); // 5s left of a 25s turn
  await table.act(actor.userId, ACTION.SIDESHOW);

  // Their turn cannot time out while they are waiting on somebody else.
  await advance(SIDESHOW_MS - 1);
  assert.equal(table.hand.turnSeat, actor.seatIndex);
  assert.equal(actor.status, SEAT_STATE.ACTIVE);

  await table.respondToSideshow(asked.userId, false);

  // A fresh clock, not the 5s that were left.
  await advance(baseConfig.turnTimeoutMs - 1);
  assert.equal(table.hand.turnSeat, actor.seatIndex, 'still their turn');
  await advance(1);
  assert.equal(actor.status, SEAT_STATE.PACKED, 'timed out on the new clock');
});

// ------------------------------------------------------------- the comparison

test('the weaker hand packs and only the two of them see the cards', async () => {
  const { table, onTurn, rightOf, named, giveCards } = await makeTable();

  const actor = onTurn();
  const asked = rightOf(actor.userId);
  giveCards(actor.userId, ['As', 'Ah', 'Ad']); // trail of aces
  giveCards(asked.userId, ['2s', '7h', '9d']); // nothing

  await table.act(actor.userId, ACTION.SIDESHOW);
  await table.respondToSideshow(asked.userId, true);

  const [reveal] = named('sideshowReveal');
  assert.deepEqual(reveal.userIds.sort(), [actor.userId, asked.userId].sort());
  assert.deepEqual(
    reveal.reveal.hands.map((hand) => hand.cards),
    [['As', 'Ah', 'Ad'], ['2s', '7h', '9d']],
  );
  assert.equal(reveal.reveal.packedUserId, asked.userId);

  // What the rest of the table hears carries no cards at all.
  const [resolved] = named('sideshowResolved');
  assert.equal(resolved.accepted, true);
  assert.equal(resolved.packedUserId, asked.userId);
  assert.equal(JSON.stringify(resolved).includes('As'), false);

  assert.equal(asked.status, SEAT_STATE.PACKED);
  assert.equal(actor.status, SEAT_STATE.ACTIVE);
});

test('losing your own sideshow packs you and passes the turn on', async () => {
  const { table, onTurn, rightOf, giveCards } = await makeTable({ count: 4 });

  const actor = onTurn();
  const asked = rightOf(actor.userId);
  giveCards(actor.userId, ['2s', '7h', '9d']);
  giveCards(asked.userId, ['As', 'Ah', 'Ad']);

  await table.act(actor.userId, ACTION.SIDESHOW);
  await table.respondToSideshow(asked.userId, true);

  assert.equal(actor.status, SEAT_STATE.PACKED);
  assert.equal(asked.status, SEAT_STATE.ACTIVE);
  assert.notEqual(table.hand.turnSeat, actor.seatIndex, 'the turn moved off the packed player');
  assert.equal(table.seats[table.hand.turnSeat].status, SEAT_STATE.ACTIVE);
});

test('a tie goes against the player who asked', async () => {
  const { table, onTurn, rightOf, giveCards } = await makeTable();

  const actor = onTurn();
  const asked = rightOf(actor.userId);
  // The same hand in different suits: identical rank, so the asker loses.
  giveCards(actor.userId, ['Ks', 'Kh', '4d']);
  giveCards(asked.userId, ['Kd', 'Kc', '4s']);

  await table.act(actor.userId, ACTION.SIDESHOW);
  await table.respondToSideshow(asked.userId, true);

  assert.equal(actor.status, SEAT_STATE.PACKED);
  assert.equal(asked.status, SEAT_STATE.ACTIVE);
});

test('when the sideshow leaves two players the hand carries on rather than ending', async () => {
  const { table, onTurn, rightOf, giveCards } = await makeTable();

  const actor = onTurn();
  const asked = rightOf(actor.userId);
  giveCards(actor.userId, ['As', 'Ah', 'Ad']);
  giveCards(asked.userId, ['2s', '7h', '9d']);

  await table.act(actor.userId, ACTION.SIDESHOW);
  await table.respondToSideshow(asked.userId, true);

  assert.equal(table.activeSeats.length, 2);
  assert.ok(table.hand, 'the hand is still live');
  // Two left, so a show is now on the table.
  assert.ok(table.turnOptions(table.seats[table.hand.turnSeat]).show > 0);
});

// ------------------------------------------------------------- once per turn

test('one sideshow per turn, and the next turn brings a fresh one', async () => {
  const { table, onTurn, rightOf } = await makeTable();

  const first = onTurn();
  await table.act(first.userId, ACTION.SIDESHOW);
  await table.respondToSideshow(rightOf(first.userId).userId, false);

  // Turn given back, but the ask has been used up.
  assert.equal(table.hand.turnSeat, first.seatIndex);
  assert.equal(table.sideshowBlockedReason(first), 'already_asked');
  assert.equal(table.turnOptions(first).canSideshow, false);
  await assert.rejects(table.act(first.userId, ACTION.SIDESHOW), { code: 'already_asked' });

  // Play all the way round to them again.
  await table.act(first.userId, ACTION.CHAAL);
  while (table.hand.turnSeat !== first.seatIndex) {
    await table.act(onTurn().userId, ACTION.CHAAL);
  }

  assert.equal(table.sideshowBlockedReason(first), null);
  assert.equal(table.turnOptions(first).canSideshow, true);
});

test('a second request cannot be opened while one is standing', async () => {
  const { table, onTurn } = await makeTable();

  const actor = onTurn();
  await table.act(actor.userId, ACTION.SIDESHOW);
  await assert.rejects(table.act(actor.userId, ACTION.SIDESHOW), { code: 'sideshow_pending' });
});

// ------------------------------------------------------------- interruptions

test('a player leaving cancels the sideshow they were part of', async () => {
  const { table, onTurn, rightOf, named } = await makeTable({ count: 4 });

  const actor = onTurn();
  const asked = rightOf(actor.userId);
  await table.act(actor.userId, ACTION.SIDESHOW);

  await table.removePlayer(asked.userId, 'left');

  assert.equal(table.hand.sideshow, null);
  assert.equal(named('sideshowResolved')[0].reason, 'left');
  assert.equal(named('sideshowReveal').length, 0);
  // The asker is not left waiting on somebody who has gone.
  assert.equal(table.hand.turnSeat, actor.seatIndex);
  assert.ok(table.turnOptions(actor).chaal > 0, 'they can still bet');
});

test('a pending request does not outlive its hand', async () => {
  const { table, advance, onTurn, ids, named } = await makeTable();

  const actor = onTurn();
  await table.act(actor.userId, ACTION.SIDESHOW);

  // Everybody else walks out, which ends the hand while the request stands.
  for (const id of ids.filter((candidate) => candidate !== actor.userId)) {
    await table.removePlayer(id, 'left');
  }
  assert.equal(table.hand, null);

  // The expiry timer must not fire into a finished hand.
  await assert.doesNotReject(() => advance(SIDESHOW_MS * 2));
  assert.equal(named('sideshowReveal').length, 0);
});
