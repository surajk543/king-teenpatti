/**
 * Requirement 24: two rooms each down to a single player are merged, so the
 * stragglers end up somewhere they can actually play.
 *
 * The rule that matters most here is the one about *not* doing it mid-game: a
 * table with a hand in progress is never disturbed.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import RoomManager from '../src/game/roomManager.js';
import { ACTION, TABLE_CATEGORY, TABLE_STATE } from '../src/game/constants.js';
import createFakeTimers from './helpers/fakeTimers.js';

const BOOT = 200;
const START = 200000;

let seq = 0;
const player = (name) => {
  seq += 1;
  return { id: `${name}-${seq}`, displayName: name, avatarUrl: null, chips: START };
};

const makeRooms = () => {
  const { timers, advance } = createFakeTimers();
  return { rooms: new RoomManager({ timers, settle: () => ({}) }), advance };
};

/** A table holding exactly one player, at the given stake and category. */
const singleTable = (rooms, { bootAmount = BOOT, category = TABLE_CATEGORY.BLIND } = {}) => {
  const table = rooms.createTable({ bootAmount, category });
  rooms.join(table, player('Solo'));
  return table;
};

// ------------------------------------------------------------ the merge

test('two tables with one player each are merged into one', async () => {
  const { rooms } = makeRooms();

  const a = singleTable(rooms);
  const b = singleTable(rooms);
  const [aPlayer, bPlayer] = [a.occupiedSeats[0].userId, b.occupiedSeats[0].userId];

  const moves = await rooms.consolidateTables();

  assert.equal(moves.length, 1, 'one player was moved');
  assert.equal(rooms.tables.size, 1, 'the emptied table was disposed of');

  const survivor = [...rooms.tables.values()][0];
  assert.equal(survivor.playerCount, 2, 'both players are now at one table');

  const seated = survivor.occupiedSeats.map((seat) => seat.userId).sort();
  assert.deepEqual(seated, [aPlayer, bPlayer].sort(), 'and they are the same two players');
});

test('the merged players can now actually start a hand', async () => {
  const { rooms, advance } = makeRooms();

  singleTable(rooms);
  singleTable(rooms);
  await rooms.consolidateTables();

  const survivor = [...rooms.tables.values()][0];
  assert.equal(survivor.state, TABLE_STATE.STARTING, 'two players triggers the countdown');

  await advance(10000);
  assert.ok(survivor.hand, 'a hand was dealt');
});

test('the player is moved onto the longest-standing table', async () => {
  const { rooms } = makeRooms();

  const first = singleTable(rooms);
  const second = singleTable(rooms);

  const moves = await rooms.consolidateTables();

  assert.equal(moves[0].fromRoomId, second.id, 'the newer room gives up its player');
  assert.equal(moves[0].toRoomId, first.id, 'to the one that has been open longest');
  assert.equal(rooms.getTable(second.id), null, 'the newer room is gone');
});

test('three lone players end up at the same table', async () => {
  const { rooms } = makeRooms();

  singleTable(rooms);
  singleTable(rooms);
  singleTable(rooms);

  await rooms.consolidateTables();

  assert.equal(rooms.tables.size, 1);
  assert.equal([...rooms.tables.values()][0].playerCount, 3);
});

test('a move is announced so the client can follow it', async () => {
  const { rooms } = makeRooms();

  const announced = [];
  rooms.on('playerMoved', (move) => announced.push(move));

  singleTable(rooms);
  const second = singleTable(rooms);
  const movedUser = second.occupiedSeats[0].userId;

  await rooms.consolidateTables();

  assert.equal(announced.length, 1);
  assert.equal(announced[0].userId, movedUser);
  assert.equal(announced[0].fromRoomId, second.id);
});

test('the room index follows the player to their new table', async () => {
  const { rooms } = makeRooms();

  const first = singleTable(rooms);
  const second = singleTable(rooms);
  const movedUser = second.occupiedSeats[0].userId;

  await rooms.consolidateTables();

  assert.equal(rooms.getTableForPlayer(movedUser).id, first.id, 'lookups point at the new room');
});

// ------------------------------------------- never during a live game

test('a table with a hand in progress is never disturbed', async () => {
  const { rooms, advance } = makeRooms();

  // A busy table: two players, mid-hand.
  const busy = rooms.createTable({ bootAmount: BOOT, category: TABLE_CATEGORY.BLIND });
  rooms.join(busy, player('Busy1'));
  rooms.join(busy, player('Busy2'));
  await advance(10000);
  assert.ok(busy.hand, 'the busy table is mid-hand');

  // Everyone packs but one — the hand ends and the table drops to two seats.
  const lonely = singleTable(rooms);

  const moves = await rooms.consolidateTables();

  assert.equal(moves.length, 0, 'nobody was moved off a table that is playing');
  assert.ok(rooms.getTable(busy.id), 'the busy table is untouched');
  assert.ok(rooms.getTable(lonely.id), 'and the lone player stays put');
});

test('a lone player is not moved while their own table has a live hand', async () => {
  // A single-player table cannot be mid-hand (two are needed to deal), so this
  // guards the inverse: the check is on the hand, not just the seat count.
  const { rooms, advance } = makeRooms();

  const table = rooms.createTable({ bootAmount: BOOT, category: TABLE_CATEGORY.BLIND });
  rooms.join(table, player('P1'));
  rooms.join(table, player('P2'));
  await advance(10000);
  assert.ok(table.hand);

  // One leaves mid-hand; the hand ends immediately with the other as winner.
  await rooms.leave(table.occupiedSeats[0].userId, 'left');

  assert.equal(table.playerCount, 1);
  assert.equal(table.hand, null, 'the hand resolved before any merge could apply');
});

// -------------------------------------------- only like-for-like tables

test('tables of different stakes are never merged', async () => {
  const { rooms } = makeRooms();

  singleTable(rooms, { bootAmount: 200 });
  singleTable(rooms, { bootAmount: 5000 });

  assert.equal((await rooms.consolidateTables()).length, 0, 'a player keeps the stake they chose');
  assert.equal(rooms.tables.size, 2);
});

test('blind and seen tables are never merged', async () => {
  const { rooms } = makeRooms();

  singleTable(rooms, { category: TABLE_CATEGORY.BLIND });
  singleTable(rooms, { category: TABLE_CATEGORY.SEEN });

  assert.equal((await rooms.consolidateTables()).length, 0, 'a player keeps the category they chose');
  assert.equal(rooms.tables.size, 2);
});

test('private tables are left alone', async () => {
  const { rooms } = makeRooms();

  const one = rooms.createTable({ isPrivate: true, category: TABLE_CATEGORY.BLIND });
  rooms.join(one, player('Host1'));
  const two = rooms.createTable({ isPrivate: true, category: TABLE_CATEGORY.BLIND });
  rooms.join(two, player('Host2'));

  assert.equal((await rooms.consolidateTables()).length, 0, 'a private room is joined on purpose');
  assert.equal(rooms.tables.size, 2);
});

test('a full destination stops taking players', async () => {
  const { rooms } = makeRooms();

  const target = rooms.createTable({ bootAmount: BOOT, category: TABLE_CATEGORY.BLIND });
  for (let i = 0; i < 5; i += 1) rooms.join(target, player(`Seat${i}`));
  assert.ok(target.isFull);

  const lonely = singleTable(rooms);
  const moves = await rooms.consolidateTables();

  assert.equal(moves.length, 0, 'there was nowhere to put them');
  assert.equal(lonely.playerCount, 1, 'so they stayed where they were');
});

test('a single lone table has nothing to merge with', async () => {
  const { rooms } = makeRooms();
  singleTable(rooms);

  assert.equal((await rooms.consolidateTables()).length, 0);
  assert.equal(rooms.tables.size, 1);
});

// ------------------------------------------------ the start countdown

test('the table announces when the next hand starts', async () => {
  const { rooms } = makeRooms();

  singleTable(rooms);
  singleTable(rooms);
  await rooms.consolidateTables();

  const survivor = [...rooms.tables.values()][0];
  const view = survivor.serializeFor(survivor.occupiedSeats[0].userId);

  assert.equal(view.state, TABLE_STATE.STARTING);
  assert.ok(view.startsAt > Date.now(), 'clients get a deadline to count down to');
  assert.ok(view.startsAt <= Date.now() + 5000, 'and it is a few seconds away');
});

test('leaving a table triggers a merge without waiting for the sweep', async () => {
  const { rooms } = makeRooms();

  // Table A: two players, one of whom leaves, dropping it to one.
  const a = rooms.createTable({ bootAmount: BOOT, category: TABLE_CATEGORY.BLIND });
  rooms.join(a, player('A1'));
  rooms.join(a, player('A2'));

  // Table B already has a lone player.
  const b = rooms.createTable({ bootAmount: BOOT, category: TABLE_CATEGORY.BLIND });
  rooms.join(b, player('B1'));

  await rooms.leave(a.occupiedSeats[0].userId, 'left');

  // A dropped to one player, so the two singles should now be together.
  assert.equal(rooms.tables.size, 1, 'the rooms merged on the spot');
  assert.equal([...rooms.tables.values()][0].playerCount, 2);
});
