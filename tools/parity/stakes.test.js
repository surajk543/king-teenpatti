/**
 * The lobby menu with the REAL defaults (stakes.test.js and the lobbyRules
 * config assertions, replayed over the wire): TABLE_STAKES 200,5000 and
 * LOBBY_TABLES seen:200,blind:200,blind:5000. The menu is advertised in
 * `session:ready.config` and `/api/rooms`, every room on it can be joined, and
 * nothing off it can — stake first, then the pair, then the wallet, then the
 * entry cap.
 *
 * Profile assumptions (tools/parity.mjs "menu"): TABLE_STAKES, LOBBY_TABLES and
 * BOOT_AMOUNT left at their defaults; long clocks.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  guestLogin, openClient, closeAll, closeOpenClients, http, isGo, profile, assertKeys,
} from './lib/harness.mjs';
import { closeDb, setWallet } from './lib/db.mjs';

test.after(async () => {
  await closeOpenClients();
  await closeDb();
});

// The blind ladder is banded by stack as well as by stake: minChips / maxChips
// say who each table is for, 0 meaning no limit at that end. Requirement 30's
// cap on the 200 table is the same field, folded in from ENTRY_CAP_*.
const MENU = [
  { category: 'seen', bootAmount: 200, maxPot: 1200000, maxBlindMoves: 4, minChips: 0, maxChips: 0 },
  { category: 'blind', bootAmount: 200, maxPot: 0, maxBlindMoves: 4, minChips: 0, maxChips: 500000 },
  { category: 'blind', bootAmount: 5000, maxPot: 0, maxBlindMoves: 4, minChips: 0, maxChips: 50000000 },
  { category: 'blind', bootAmount: 50000, maxPot: 0, maxBlindMoves: 4, minChips: 0, maxChips: 1000000000 },
  { category: 'blind', bootAmount: 1000000, maxPot: 0, maxBlindMoves: 4, minChips: 500000000, maxChips: 0 },
];

/** A stack that covers an entry's boot and sits inside its band. */
const legalStack = (entry) => {
  let stack = Math.max(200000, entry.bootAmount * 50);
  if (entry.minChips > 0 && stack < entry.minChips) stack = entry.minChips;
  if (entry.maxChips > 0 && stack > entry.maxChips) stack = entry.maxChips;
  return stack;
};

test('the lobby offers exactly the four stakes and the five rooms, in menu order, with their rules and bands', async () => {
  const account = await guestLogin('device-parity-menu-config', 'Menu');
  const client = await openClient(account.token);
  const ready = await client.wait('session:ready');
  assert.deepEqual(ready.config.stakes, [200, 5000, 50000, 1000000]);
  assert.deepEqual(ready.config.categories, ['seen', 'blind']);
  assert.deepEqual(ready.config.tables, MENU);
  for (const entry of ready.config.tables) assert.deepEqual(Object.keys(entry), ['category', 'bootAmount', 'maxPot', 'maxBlindMoves', 'minChips', 'maxChips'], 'key order');
  assert.equal(ready.config.bootAmount, 200, 'the default boot');
  assert.equal(ready.config.entryCapBoot, 200);
  assert.equal(ready.config.entryCapCategory, 'blind');
  assert.equal(ready.config.entryCapMaxChips, 500000);
  assert.equal(ready.config.privateBoot, 200);
  assert.equal(ready.config.privateMaxPot, 500000);
  assert.equal(ready.config.maxBetRounds, 20, 'the default; per-category caps are applied at the table');

  const rooms = await http('GET', '/api/rooms');
  assert.equal(rooms.status, 200);
  assert.deepEqual(rooms.body.options.stakes, [200, 5000, 50000, 1000000]);
  assert.deepEqual(rooms.body.options.tables, MENU);
  assertKeys(rooms.body.options, ['categories', 'stakes', 'tables', 'entryCapBoot', 'entryCapCategory', 'entryCapMaxChips', 'privateBoot', 'privateMaxPot']);
  const listed = await client.emit('lobby:list', {});
  assert.deepEqual(listed.options, rooms.body.options, 'the socket and REST menus are the same object');
  await client.close();
});

test('every room on the menu can be joined, and the ceiling a card advertises is the one the table is built with', async () => {
  const clients = [];
  for (const [i, entry] of MENU.entries()) {
    const account = await guestLogin(`device-parity-menu-join-${i}`, `Menu${i}`);
    // The welcome grant cannot cover the top table's boot, let alone its
    // floor, so each account is funded into the band of the table it is
    // testing — the point here is that the menu is joinable, not that 2 lakh
    // opens everything.
    await setWallet(account.user.id, legalStack(entry), `parity-menu-join-${i}`);
    const client = await openClient(account.token);
    const ack = await client.emit('room:quickJoin', { bootAmount: entry.bootAmount, category: entry.category });
    assert.equal(ack.ok, true, `${entry.category} ${entry.bootAmount}: ${JSON.stringify(ack)}`);
    assert.equal(ack.category, entry.category);
    const joined = client.last('room:joined');
    assert.equal(joined.bootAmount, entry.bootAmount);
    assert.equal(joined.category, entry.category);
    assert.equal(joined.maxPot, entry.maxPot, `${entry.category} ${entry.bootAmount} maxPot`);
    assert.equal(joined.you.blindMovesLeft, entry.maxBlindMoves);
    assert.equal(joined.chipsHidden, entry.category === 'blind');
    clients.push(client);
  }
  const listed = await clients[0].emit('lobby:list', {});
  assert.equal(listed.tables.length, MENU.length, 'one room per menu entry');
  assert.deepEqual(
    listed.tables.map((t) => `${t.category}:${t.bootAmount}`).sort(),
    MENU.map((t) => `${t.category}:${t.bootAmount}`).sort(),
  );
  for (const row of listed.tables) {
    assert.equal(row.players, 1);
    assert.equal(row.maxPlayers, 5);
    assert.equal(row.state, 'waiting');
    assert.equal(row.pot, 0);
  }
  const rest = await http('GET', '/api/rooms?category=blind');
  assert.equal(rest.body.tables.length, MENU.filter((e) => e.category === 'blind').length);
  assert.ok(rest.body.tables.every((t) => t.category === 'blind'));
  await closeAll(...clients);
});

test('a stake and category that is not a room on the menu is refused, and no room is opened for it', async () => {
  const account = await guestLogin('device-parity-menu-pair', 'Pair');
  const client = await openClient(account.token);
  // Both halves are offered on their own; the pair is not.
  const ack = await client.emit('room:quickJoin', { bootAmount: 5000, category: 'seen' });
  assert.deepEqual(ack, { ok: false, code: 'table_not_offered', message: 'The lobby offers: seen 200, blind 200, blind 5000, blind 50000, blind 1000000' });
  const listed = await client.emit('lobby:list', {});
  assert.ok(!listed.tables.some((t) => t.category === 'seen' && t.bootAmount === 5000), 'no seen table at 5,000 exists');
  assert.equal(client.count('room:joined'), 0);
  await client.close();
});

test('a stake the lobby does not offer, or a malformed one, is refused; null means the default boot', async () => {
  const account = await guestLogin('device-parity-menu-stake', 'Stake');
  const client = await openClient(account.token);
  for (const bootAmount of [1, 100, 199, 4999, 10000]) {
    const ack = await client.emit('room:quickJoin', { bootAmount });
    assert.deepEqual(ack, { ok: false, code: 'invalid_stake', message: 'Stake must be one of: 200, 5000, 50000, 1000000' }, `${bootAmount}`);
  }
  for (const bootAmount of [0, -200, 200.5, 'lots', '200']) {
    const ack = await client.emit('room:quickJoin', { bootAmount });
    assert.deepEqual(ack, { ok: false, code: 'invalid_stake', message: 'That stake is not valid' }, `${bootAmount}`);
  }
  // Over the wire a null boot is the default boot (200, seen) — DECISIONS.md §7.
  const nulled = await client.emit('room:quickJoin', { bootAmount: null });
  assert.equal(nulled.ok, true, JSON.stringify(nulled));
  assert.equal(nulled.category, 'seen');
  assert.equal(client.last('room:joined').bootAmount, 200);
  await client.emit('room:leave', {});
  const bare = await client.emit('room:quickJoin', {});
  assert.equal(bare.ok, true);
  assert.equal(client.last('room:joined').bootAmount, 200);
  await client.close();
});

test('the checks come in order: stake, then the pair, then the wallet, then the entry cap', async () => {
  const poor = await guestLogin('device-parity-menu-poor', 'Poor');
  const rich = await guestLogin('device-parity-menu-rich', 'Rich');
  await setWallet(poor.user.id, 4999, 'parity-menu-poor');
  await setWallet(rich.user.id, 600000, 'parity-menu-rich');
  const cp = await openClient(poor.token);
  const cr = await openClient(rich.token);

  let ack = await cp.emit('room:quickJoin', { bootAmount: 100 });
  assert.equal(ack.code, 'invalid_stake', 'a bad stake is refused before the wallet is looked at');
  ack = await cp.emit('room:quickJoin', { bootAmount: 5000, category: 'blind' });
  assert.deepEqual(ack, { ok: false, code: 'insufficient_chips', message: 'Not enough chips to join this table' });
  ack = await cp.emit('room:quickJoin', { bootAmount: 200 });
  assert.equal(ack.ok, true, 'but they can afford the smaller table');
  assert.equal(cp.last('room:joined').bootAmount, 200);
  assert.equal(cp.last('room:joined').category, 'seen');

  ack = await cr.emit('room:quickJoin', { bootAmount: 5000, category: 'seen' });
  assert.equal(ack.code, 'table_not_offered', 'the pair is checked before the cap');
  ack = await cr.emit('room:quickJoin', { bootAmount: 200, category: 'blind' });
  assert.deepEqual(ack, { ok: false, code: 'over_entry_cap', message: 'Players with more than 500,000 chips cannot join this table' });
  ack = await cr.emit('room:quickJoin', { bootAmount: 5000, category: 'blind' });
  assert.equal(ack.ok, true, 'the big blind table is open to a big stack');
  await closeAll(cp, cr);
});

test('players cluster onto the fullest matching table; a different category at the same stake is its own table', async () => {
  const clients = [];
  const acks = [];
  for (const [i, spec] of [['seen', 200], ['seen', 200], ['blind', 200], ['seen', 200]].entries()) {
    const account = await guestLogin(`device-parity-menu-cluster-${i}`, `Cluster${i}`);
    const client = await openClient(account.token);
    const ack = await client.emit('room:quickJoin', { bootAmount: spec[1], category: spec[0] });
    assert.equal(ack.ok, true, JSON.stringify(ack));
    clients.push(client);
    acks.push(ack);
  }
  assert.equal(acks[0].roomId, acks[1].roomId, 'the second player joins the first table');
  assert.equal(acks[0].roomId, acks[3].roomId, 'and so does the fourth');
  assert.notEqual(acks[2].roomId, acks[0].roomId, 'a different category at the same stake starts its own table');
  await closeAll(...clients);
});

test('a private table ignores the menu (fixed boot 200); a public create is validated like a quick-join on the Go server (DECISIONS.md §3)', async () => {
  const account = await guestLogin('device-parity-menu-create', 'Creator');
  const client = await openClient(account.token);
  const priv = await client.emit('room:create', { isPrivate: true, bootAmount: 777, category: 'blind' });
  assert.equal(priv.ok, true);
  assert.equal(client.last('room:joined').bootAmount, 200);
  assert.equal(client.last('room:joined').maxPot, 500000);
  await client.emit('room:leave', {});

  const offMenu = await client.emit('room:create', { isPrivate: false, bootAmount: 777, category: 'seen' });
  if (isGo) {
    // Deliberate deviation: a public create cannot open a table the lobby does not offer.
    assert.equal(offMenu.code, 'invalid_stake');
  } else {
    // Node opens the table as asked (the stake is only checked on quick-join).
    assert.equal(offMenu.ok, true);
    assert.equal(client.last('room:joined').bootAmount, 777);
    await client.emit('room:leave', {});
  }
  const badPair = await client.emit('room:create', { isPrivate: false, bootAmount: 5000, category: 'seen' });
  if (isGo) {
    assert.equal(badPair.code, 'table_not_offered');
  } else {
    assert.equal(badPair.ok, true);
    assert.equal(client.last('room:joined').bootAmount, 5000);
    assert.equal(client.last('room:joined').maxPot, 1200000);
    await client.emit('room:leave', {});
  }
  const onMenu = await client.emit('room:create', { isPrivate: false, bootAmount: 200, category: 'blind' });
  assert.equal(onMenu.ok, true, JSON.stringify(onMenu));
  assert.equal(client.last('room:joined').maxPot, 0);
  assert.equal(client.last('room:joined').you.chips, profile.welcomeChips);
  await client.close();
});
