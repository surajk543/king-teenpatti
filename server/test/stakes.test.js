/**
 * The lobby's fixed stakes (requirement 13: tables of 200 and 5000).
 *
 * Quick-join is restricted to the configured stakes, so a client cannot spin up
 * a table at an arbitrary boot amount. This suite runs with the default list.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const dbFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'teenpatti-stakes-')), 'stakes.db');
process.env.NODE_ENV = 'test';
process.env.DB_FILE = dbFile;
process.env.JWT_SECRET = 'stakes-test-secret';
process.env.NEXT_HAND_DELAY_MS = '150';
// Deliberately left at the default 200,5000 — that restriction is under test.
delete process.env.TABLE_STAKES;

const { default: RoomManager } = await import('../src/game/roomManager.js');
const { default: config } = await import('../src/config/index.js');
const { closeDatabase, openDatabase } = await import('../src/db/index.js');

openDatabase();

test.after(() => {
  closeDatabase();
  fs.rmSync(path.dirname(dbFile), { recursive: true, force: true });
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

test('both offered stakes can be joined, in both categories', () => {
  const rooms = new RoomManager();

  for (const bootAmount of [200, 5000]) {
    for (const category of ['seen', 'blind']) {
      const table = rooms.quickJoin(player(), { bootAmount, category });
      assert.equal(table.config.bootAmount, bootAmount);
      assert.equal(table.category, category);
    }
  }

  // Four distinct table types: 2 stakes x 2 categories.
  assert.equal(rooms.listTables().length, 4);
  rooms.shutdown();
});

test('a stake the lobby does not offer is refused', () => {
  const rooms = new RoomManager();

  for (const bootAmount of [1, 100, 199, 4999, 10000]) {
    assert.throws(
      () => rooms.quickJoin(player(), { bootAmount }),
      (error) => error.code === 'invalid_stake',
      `${bootAmount} is not offered`,
    );
  }

  rooms.shutdown();
});

test('a malformed stake is refused', () => {
  const rooms = new RoomManager();

  for (const bootAmount of [0, -200, 200.5, Number.NaN, 'lots', null]) {
    assert.throws(
      () => rooms.quickJoin(player(), { bootAmount }),
      (error) => error.code === 'invalid_stake',
      `${bootAmount} is rejected`,
    );
  }

  rooms.shutdown();
});

test('a player short of the stake cannot sit down', () => {
  const rooms = new RoomManager();

  assert.throws(
    () => rooms.quickJoin(player(4999), { bootAmount: 5000 }),
    (error) => error.code === 'insufficient_chips',
  );

  // But they can afford the smaller table.
  const table = rooms.quickJoin(player(4999), { bootAmount: 200 });
  assert.equal(table.config.bootAmount, 200);

  rooms.shutdown();
});

test('players cluster onto the fullest matching table', () => {
  const rooms = new RoomManager();

  const first = rooms.quickJoin(player(), { bootAmount: 200, category: 'seen' });
  const second = rooms.quickJoin(player(), { bootAmount: 200, category: 'seen' });
  assert.equal(first.id, second.id, 'the second player joins the first table');

  // A different category at the same stake starts its own table.
  const other = rooms.quickJoin(player(), { bootAmount: 200, category: 'blind' });
  assert.notEqual(other.id, first.id);

  rooms.shutdown();
});
