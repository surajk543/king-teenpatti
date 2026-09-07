/**
 * The lobby's menu: which rooms exist, and that nothing else can be joined.
 *
 * Two restrictions stack. The stake must be one the lobby offers (requirement
 * 13: 200 and 5000), and the stake and category together must be a room on the
 * menu — 5,000 is offered and so is seen, but there is no seen table at 5,000.
 * This suite runs with the defaults, because those defaults are what is under
 * test.
 */
import test from 'node:test';
import assert from 'node:assert/strict';

// The config module snapshots the environment at import time, so everything
// this suite needs has to be set before anything under src/ is loaded. The
// suite gets a throwaway Postgres schema of its own, dropped again afterwards.
process.env.NODE_ENV = 'test';
process.env.PG_SCHEMA = `test_stakes_${Math.random().toString(36).slice(2, 8)}`;
process.env.JWT_SECRET = 'stakes-test-secret';
process.env.NEXT_HAND_DELAY_MS = '150';
// Deliberately left at the defaults — those restrictions are under test.
delete process.env.TABLE_STAKES;
delete process.env.LOBBY_TABLES;

const { default: RoomManager } = await import('../src/game/roomManager.js');
const { default: config } = await import('../src/config/index.js');
const { openDatabase, dropSchema, closeDatabase } = await import('../src/db/index.js');

await openDatabase();

test.after(async () => {
  await dropSchema();
  await closeDatabase();
});

const player = (chips = 200000) => ({
  id: `p-${Math.random().toString(36).slice(2, 10)}`,
  displayName: 'Player',
  avatarUrl: null,
  chips,
});

test('the lobby offers exactly the 200 and 5000 stakes', () => {
  assert.deepEqual(config.game.tableStakes, [200, 5000]);
  assert.deepEqual(RoomManager.lobbyOptions().stakes, [200, 5000]);
  assert.deepEqual(RoomManager.lobbyOptions().categories, ['seen', 'blind']);
});

test('the menu is three rooms, in the order the lobby shows them', () => {
  // Each carries the rules the lobby card states, so the card and the table it
  // opens cannot drift apart. A zero ceiling means the pot is uncapped.
  assert.deepEqual(RoomManager.lobbyOptions().tables, [
    { category: 'seen', bootAmount: 200, maxPot: 1200000, maxBlindMoves: 4 },
    { category: 'blind', bootAmount: 200, maxPot: 0, maxBlindMoves: 4 },
    { category: 'blind', bootAmount: 5000, maxPot: 0, maxBlindMoves: 4 },
  ]);
});

test('the ceiling a card advertises is the one the table is built with', async () => {
  const rooms = new RoomManager();

  for (const entry of RoomManager.lobbyOptions().tables) {
    const table = rooms.quickJoin(player(), {
      bootAmount: entry.bootAmount,
      category: entry.category,
    });
    assert.equal(table.maxPot, entry.maxPot, `${entry.category} ${entry.bootAmount}`);
    assert.equal(table.config.maxBlindMoves, entry.maxBlindMoves);
  }

  await rooms.shutdown();
});

test('every room on the menu can be joined', async () => {
  const rooms = new RoomManager();

  for (const { category, bootAmount } of RoomManager.lobbyOptions().tables) {
    const table = rooms.quickJoin(player(), { bootAmount, category });
    assert.equal(table.config.bootAmount, bootAmount);
    assert.equal(table.category, category);
  }

  assert.equal(rooms.listTables().length, 3);
  await rooms.shutdown();
});

test('a stake and category that is not a room on the menu is refused', async () => {
  const rooms = new RoomManager();

  // Both halves are offered on their own; the pair is not.
  assert.throws(
    () => rooms.quickJoin(player(), { bootAmount: 5000, category: 'seen' }),
    (error) => error.code === 'table_not_offered',
    'there is no seen table at 5,000',
  );
  assert.equal(rooms.listTables().length, 0, 'and no room was opened for it');

  await rooms.shutdown();
});

test('a stake the lobby does not offer is refused', async () => {
  const rooms = new RoomManager();

  for (const bootAmount of [1, 100, 199, 4999, 10000]) {
    assert.throws(
      () => rooms.quickJoin(player(), { bootAmount }),
      (error) => error.code === 'invalid_stake',
      `${bootAmount} is not offered`,
    );
  }

  await rooms.shutdown();
});

test('a malformed stake is refused', async () => {
  const rooms = new RoomManager();

  for (const bootAmount of [0, -200, 200.5, Number.NaN, 'lots', null]) {
    assert.throws(
      () => rooms.quickJoin(player(), { bootAmount }),
      (error) => error.code === 'invalid_stake',
      `${bootAmount} is rejected`,
    );
  }

  await rooms.shutdown();
});

test('a player short of the stake cannot sit down', async () => {
  const rooms = new RoomManager();

  // The 5,000 room is a blind one; there is no seen table at that stake.
  assert.throws(
    () => rooms.quickJoin(player(4999), { bootAmount: 5000, category: 'blind' }),
    (error) => error.code === 'insufficient_chips',
  );

  // But they can afford the smaller table.
  const table = rooms.quickJoin(player(4999), { bootAmount: 200 });
  assert.equal(table.config.bootAmount, 200);

  await rooms.shutdown();
});

test('players cluster onto the fullest matching table', async () => {
  const rooms = new RoomManager();

  const first = rooms.quickJoin(player(), { bootAmount: 200, category: 'seen' });
  const second = rooms.quickJoin(player(), { bootAmount: 200, category: 'seen' });
  assert.equal(first.id, second.id, 'the second player joins the first table');

  // A different category at the same stake starts its own table.
  const other = rooms.quickJoin(player(), { bootAmount: 200, category: 'blind' });
  assert.notEqual(other.id, first.id);

  await rooms.shutdown();
});
