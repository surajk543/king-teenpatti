/**
 * Lobby and seating parity: quick-join, private tables and codes, switching,
 * leaving, consolidation — the acks, the snapshot shapes, and the ORDER in
 * which a socket hears about it all (integration.test.js #11, #15–#17,
 * #19–#24; invalidMoves #10–#12; lobbyRules entry-cap and switch rules;
 * consolidation's `room:moved`; spec-socket-protocol.md §11 ordering table).
 *
 * Ordering rules pinned here (DECISIONS.md §1 "reproduce exactly"):
 *   - the joiner hears `room:state` BEFORE `room:joined`, then `chat:history`,
 *     and the ack comes after every emit the handler made;
 *   - `room:create` sends the creator no `room:state` at all;
 *   - a player merged onto another table hears `room:closed` (old room) before
 *     `room:moved`, then `room:joined`, `chat:history`, `room:state`;
 *   - the last player to leave hears `room:closed` before `room:left`;
 *   - a switching player never hears `room:closed` or `room:left`.
 * Consecutive identical `room:state` are collapsed before comparing (§1).
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  guestLogin, openClient, closeAll, closeOpenClients, stakeCounter, profile, pause, eventually,
  assertKeys, assertOrder, assertBefore, collapseRuns, ROOM_CODE, UUID,
  SNAPSHOT_KEYS, YOU_KEYS, SEAT_KEYS, CONFIG_KEYS,
} from './lib/harness.mjs';
import { closeDb, setWallet } from './lib/db.mjs';

test.after(async () => {
  await closeOpenClients();
  await closeDb();
});

const uniqueStake = stakeCounter(1000);

const occupied = (snapshot) => snapshot.seats.filter((seat) => seat.status !== 'empty');

// ------------------------------------------------------------ quick-join

test('quick-join: ack shape, snapshot shape, and the joiner hears room:state before room:joined', async () => {
  const account = await guestLogin('device-parity-lobby-qj-0', 'QuickJoiner');
  const client = await openClient(account.token);
  const ready = await client.wait('session:ready');
  assertKeys(ready, ['user', 'config'], 'session:ready');
  assertKeys(ready.config, CONFIG_KEYS, 'session:ready.config');
  assert.equal(ready.user.id, account.user.id);
  assert.deepEqual(ready.config.categories, ['seen', 'blind']);
  assert.deepEqual(ready.config.stakes, [], 'TABLE_STAKES is lifted in this profile');
  assert.deepEqual(ready.config.tables, [], 'LOBBY_TABLES is lifted in this profile');
  assert.equal(ready.config.bootAmount, profile.bootAmount);
  assert.equal(ready.config.turnTimeoutMs, profile.turnTimeoutMs);
  assert.equal(ready.config.maxPlayers, 5);
  assert.equal(ready.config.minPlayers, 2);
  assert.equal(ready.config.privateBoot, 200);
  assert.equal(ready.config.privateMaxPot, 500000);
  assert.equal(ready.config.entryCapBoot, 200);
  assert.equal(ready.config.entryCapCategory, 'blind');
  assert.equal(ready.config.entryCapMaxChips, 500000);
  assert.equal(ready.config.sideshowMinPlayers, 3);

  const bootAmount = uniqueStake();
  const mark = client.mark();
  const ack = await client.emit('room:quickJoin', { bootAmount });
  assertKeys(ack, ['ok', 'roomId', 'code', 'category'], 'quickJoin ack');
  assert.equal(ack.ok, true);
  assert.match(ack.roomId, UUID);
  assert.match(ack.code, ROOM_CODE);
  assert.equal(ack.category, 'seen', 'no category means seen');

  assert.deepEqual(collapseRuns(client.eventsSince(mark)),
    ['room:state', 'room:joined', 'chat:history', 'room:state', 'ack:room:quickJoin']);
  assertBefore(client.eventsSince(mark), 'room:state', 'room:joined', 'joiner');

  const joined = client.last('room:joined');
  assertKeys(joined, SNAPSHOT_KEYS, 'room:joined');
  assert.equal(joined.roomId, ack.roomId);
  assert.equal(joined.code, ack.code);
  assert.equal(joined.category, 'seen');
  assert.equal(joined.chipsHidden, false);
  assert.equal(joined.state, 'waiting');
  assert.equal(joined.handNo, 0);
  assert.equal(joined.dealerSeat, -1);
  assert.equal(joined.maxPlayers, 5);
  assert.equal(joined.minPlayers, 2);
  assert.equal(joined.bootAmount, bootAmount);
  assert.equal(joined.turnTimeoutMs, profile.turnTimeoutMs);
  assert.equal(joined.startsAt, null);
  assert.equal(joined.pot, 0);
  assert.equal(joined.maxPot, profile.seenMaxPot, 'a public seen table is capped at 1.2M');
  assert.equal(joined.stake, bootAmount, 'stake falls back to the boot between hands');
  assert.equal(joined.round, 0);
  assert.equal(joined.sideshow, null);
  assert.equal(joined.turn, null);
  assertKeys(joined.you, YOU_KEYS, 'you');
  assert.deepEqual(joined.you, {
    seatIndex: 0, chips: profile.welcomeChips, status: 'waiting', isBlind: true, blindMovesLeft: 4, contributed: 0,
    missedTurns: 0, maxMissedTurns: 3, cards: [], options: null,
  });
  assert.equal(joined.seats.length, 5);
  assertKeys(joined.seats[0], SEAT_KEYS, 'seat');
  assert.deepEqual(joined.seats[0], {
    seatIndex: 0, userId: account.user.id, displayName: 'QuickJoiner', avatarUrl: null, chips: profile.welcomeChips,
    status: 'waiting', isBlind: true, lastBet: 0, lastAction: null, contributed: 0, connected: true, cardCount: 0,
  });
  for (let i = 1; i < 5; i += 1) assert.deepEqual(joined.seats[i], { seatIndex: i, status: 'empty' });

  // The history the joiner is sent already carries their own arrival.
  const history = client.last('chat:history');
  assertKeys(history, ['roomId', 'messages'], 'chat:history');
  assert.equal(history.roomId, ack.roomId);
  assert.equal(history.messages.length, 1);
  assertKeys(history.messages[0], ['id', 'userId', 'displayName', 'text', 'at', 'system'], 'system line');
  assert.equal(history.messages[0].userId, null);
  assert.equal(history.messages[0].displayName, 'Table');
  assert.equal(history.messages[0].text, 'QuickJoiner joined the table');
  assert.equal(history.messages[0].system, true);
  assert.match(history.messages[0].id, UUID);

  await client.close();
});

test('a second player is clustered onto the same table; the first hears the system line before the new snapshot', async () => {
  const a = await guestLogin('device-parity-lobby-cluster-a', 'ClusterA');
  const b = await guestLogin('device-parity-lobby-cluster-b', 'ClusterB');
  const ca = await openClient(a.token);
  const cb = await openClient(b.token);
  const bootAmount = uniqueStake();

  const joinA = await ca.emit('room:quickJoin', { bootAmount });
  const mark = ca.mark();
  const joinB = await cb.emit('room:quickJoin', { bootAmount });
  assert.equal(joinA.roomId, joinB.roomId, 'quick join clusters players onto one table');

  await ca.wait('room:state', (s) => occupied(s).length === 2);
  const events = ca.eventsSince(mark);
  assertBefore(events, 'chat:message', 'room:state', 'existing player');
  const line = ca.since(mark).find((e) => e.event === 'chat:message').payload;
  assert.equal(line.text, 'ClusterB joined the table');
  assert.equal(line.system, true);
  assert.equal(line.roomId, joinA.roomId);

  // Two funded players start the countdown; the deadline is a few ms away.
  const starting = await ca.wait('room:state', (s) => s.state === 'starting');
  assert.ok(starting.startsAt > Date.now() - 1000 && starting.startsAt <= Date.now() + profile.nextHandDelayMs + 50);
  const bView = cb.last('room:joined');
  assert.equal(bView.you.seatIndex, 1, 'seats fill in order');
  assert.equal(bView.seats[0].userId, a.user.id);

  await closeAll(ca, cb);
});

test('a table holds at most five players; the sixth opens a new one and the table counts are visible in the snapshots', async () => {
  const clients = [];
  const roomIds = new Set();
  const bootAmount = uniqueStake();
  for (let i = 0; i < 6; i += 1) {
    const account = await guestLogin(`device-parity-lobby-cap-${i}`, `Cap${i}`);
    const client = await openClient(account.token);
    clients.push(client);
    const ack = await client.emit('room:quickJoin', { bootAmount });
    assert.equal(ack.ok, true);
    roomIds.add(ack.roomId);
  }
  assert.equal(roomIds.size, 2, 'the sixth player is seated at a second table');
  await clients[0].wait('room:state', (s) => occupied(s).length === 5, 4000);
  assert.deepEqual([occupied(clients[0].state()).length, occupied(clients[5].state()).length].sort(), [1, 5]);

  const listed = await clients[5].emit('lobby:list', {});
  assertKeys(listed, ['ok', 'tables', 'options'], 'lobby:list ack');
  const rows = listed.tables.filter((t) => t.bootAmount === bootAmount);
  assert.deepEqual(rows.map((t) => t.players).sort(), [1, 5]);
  for (const row of rows) assertKeys(row, ['roomId', 'code', 'category', 'state', 'players', 'maxPlayers', 'bootAmount', 'pot'], 'lobby row');
  await closeAll(...clients);
});

test('the categories never share a table; an unknown category is seen; a null boot means the default', async () => {
  const a = await guestLogin('device-parity-lobby-cat-a', 'CatA');
  const b = await guestLogin('device-parity-lobby-cat-b', 'CatB');
  const c = await guestLogin('device-parity-lobby-cat-c', 'CatC');
  const ca = await openClient(a.token);
  const cb = await openClient(b.token);
  const cc = await openClient(c.token);
  const bootAmount = uniqueStake();

  const blind = await ca.emit('room:quickJoin', { bootAmount, category: 'blind' });
  const seen = await cb.emit('room:quickJoin', { bootAmount, category: 'seen' });
  assert.equal(blind.category, 'blind');
  assert.equal(seen.category, 'seen');
  assert.notEqual(blind.roomId, seen.roomId);
  assert.equal(ca.last('room:joined').chipsHidden, true);
  assert.equal(ca.last('room:joined').maxPot, 0, 'a public blind table is uncapped');
  assert.equal(cb.last('room:joined').chipsHidden, false);

  const sneaky = await cc.emit('room:quickJoin', { bootAmount: uniqueStake(), category: 'sneaky' });
  assert.equal(sneaky.ok, true);
  assert.equal(sneaky.category, 'seen', 'never hide chips by accident');
  await cc.emit('room:leave', {});

  const nulled = await cc.emit('room:quickJoin', { bootAmount: null });
  assert.equal(nulled.ok, true, JSON.stringify(nulled));
  assert.equal(cc.last('room:joined').bootAmount, profile.bootAmount, 'null boot = the configured default');
  await cc.emit('room:leave', {});

  const bare = await cc.emit('room:quickJoin', null);
  assert.equal(bare.ok, true, 'a null payload reads as the defaults');
  assert.equal(cc.last('room:joined').bootAmount, profile.bootAmount);

  // lobby:list filters by exact category; anything else lists nothing (the
  // filter is applied but matches no table).
  const blindOnly = await cc.emit('lobby:list', { category: 'blind' });
  assert.ok(blindOnly.tables.every((t) => t.category === 'blind'));
  assert.ok(blindOnly.tables.some((t) => t.roomId === blind.roomId));
  const seenOnly = await cc.emit('lobby:list', { category: 'seen' });
  assert.ok(seenOnly.tables.every((t) => t.category === 'seen'));
  assert.ok(seenOnly.tables.some((t) => t.roomId === seen.roomId));
  const nonsense = await cc.emit('lobby:list', { category: 'BLIND' });
  assert.deepEqual(nonsense.tables, []);
  const all = await cc.emit('lobby:list', {});
  assert.ok(all.tables.length >= 3);
  assert.ok(all.tables.every((t) => t.code === undefined || ROOM_CODE.test(t.code)));

  await closeAll(ca, cb, cc);
});

// -------------------------------------------------------- refused joins

test('refused joins: already seated, bad stakes, bad codes, unfunded, full', async () => {
  const bootAmount = uniqueStake();
  const seated = await guestLogin('device-parity-lobby-refuse-a', 'Seated');
  const cs = await openClient(seated.token);
  const seatedAck = await cs.emit('room:quickJoin', { bootAmount });
  assert.equal(seatedAck.ok, true);

  let ack = await cs.emit('room:quickJoin', { bootAmount });
  assert.deepEqual(ack, { ok: false, code: 'already_in_room', message: 'You are already seated at a table' });
  // Every refusal is also a game:error, sent right after the ack.
  assert.deepEqual(await cs.wait('game:error', (e) => e.code === 'already_in_room'),
    { code: 'already_in_room', message: 'You are already seated at a table' });
  ack = await cs.emit('room:joinCode', { code: 'NOPE00' });
  assert.equal(ack.code, 'already_in_room', 'the seat check comes first');
  ack = await cs.emit('room:create', { isPrivate: true });
  assert.equal(ack.code, 'already_in_room');
  ack = await cs.emit('room:switch', {});
  assert.deepEqual(ack, { ok: false, code: 'no_other_table', message: 'No other seen table at this stake has a free seat right now' });
  assert.equal(cs.state().you.seatIndex, 0, 'still seated after a refused switch');

  const loner = await guestLogin('device-parity-lobby-refuse-b', 'Loner');
  const cl = await openClient(loner.token);
  ack = await cl.emit('room:joinCode', { code: 'NOPE00' });
  assert.deepEqual(ack, { ok: false, code: 'room_not_found', message: 'No table with that code' });
  ack = await cl.emit('room:joinCode', { code: { $gt: '' } });
  assert.equal(ack.code, 'room_not_found');
  ack = await cl.emit('room:joinCode', {});
  assert.equal(ack.code, 'room_not_found');
  for (const bad of [-5, 0, 200.5, 'lots']) {
    ack = await cl.emit('room:quickJoin', { bootAmount: bad });
    assert.deepEqual(ack, { ok: false, code: 'invalid_stake', message: 'That stake is not valid' }, String(bad));
  }
  ack = await cl.emit('room:switch', {});
  assert.deepEqual(ack, { ok: false, code: 'not_in_room', message: 'You are not at a table' });
  ack = await cl.emit('room:leave', {});
  assert.deepEqual(ack, { ok: true }, 'leaving when not seated is a no-op with an empty ack');

  // Unfunded: the wallet is set through a fixture ledger row, never a bare UPDATE.
  const poor = await guestLogin('device-parity-lobby-refuse-c', 'Poor');
  await setWallet(poor.user.id, 50, 'parity-lobby-poor-fixture');
  const cp = await openClient(poor.token);
  ack = await cp.emit('room:quickJoin', { bootAmount });
  assert.deepEqual(ack, { ok: false, code: 'insufficient_chips', message: 'Not enough chips to join this table' });
  ack = await cp.emit('room:joinCode', { code: seatedAck.code });
  assert.equal(ack.code, 'insufficient_chips');
  ack = await cp.emit('room:quickJoin', { bootAmount: 50 });
  assert.equal(ack.ok, true, 'exactly the boot is enough');
  await cp.emit('room:leave', {});

  // Full: a private table takes five, and the sixth is told so.
  const host = await guestLogin('device-parity-lobby-full-host', 'Host');
  const ch = await openClient(host.token);
  const created = await ch.emit('room:create', { isPrivate: true });
  const guests = [];
  for (let i = 0; i < 4; i += 1) {
    const g = await guestLogin(`device-parity-lobby-full-${i}`, `Full${i}`);
    const cg = await openClient(g.token);
    const joined = await cg.emit('room:joinCode', { code: created.code });
    assert.equal(joined.ok, true, JSON.stringify(joined));
    guests.push(cg);
  }
  const extra = await guestLogin('device-parity-lobby-full-x', 'FullX');
  const cx = await openClient(extra.token);
  ack = await cx.emit('room:joinCode', { code: created.code });
  assert.deepEqual(ack, { ok: false, code: 'table_full', message: 'That table is full' });

  await closeAll(cs, cl, cp, ch, cx, ...guests);
});

// ------------------------------------------------------ private tables

test('room:create: private boot fixed at 200 and pot capped, creator gets room:joined + chat:history but NO room:state', async () => {
  const host = await guestLogin('device-parity-lobby-priv-host', 'PrivHost');
  const guest = await guestLogin('device-parity-lobby-priv-guest', 'PrivGuest');
  const ch = await openClient(host.token);
  const cg = await openClient(guest.token);

  const mark = ch.mark();
  const created = await ch.emit('room:create', { isPrivate: true, bootAmount: 99999, category: 'blind' });
  assertKeys(created, ['ok', 'roomId', 'code', 'category'], 'create ack');
  assert.equal(created.ok, true);
  assert.match(created.code, ROOM_CODE);
  assert.equal(created.category, 'blind');
  assert.deepEqual(ch.eventsSince(mark), ['room:joined', 'chat:history', 'ack:room:create'], 'no room:state on create');

  const joined = ch.last('room:joined');
  assert.equal(joined.bootAmount, 200, 'requirement 22: the requested boot is ignored');
  assert.equal(joined.maxPot, 500000);
  assert.equal(joined.stake, 200);
  assert.equal(joined.category, 'blind');
  assert.equal(joined.chipsHidden, true);

  // A private table is not on the lobby list...
  const listed = await cg.emit('lobby:list', {});
  assert.ok(!listed.tables.some((t) => t.roomId === created.roomId), 'private tables are not listed');

  // ...but its code is matched case-insensitively.
  const gmark = cg.mark();
  const byCode = await cg.emit('room:joinCode', { code: created.code.toLowerCase() });
  assert.deepEqual(byCode, { ok: true, roomId: created.roomId, code: created.code, category: 'blind' });
  assertBefore(cg.eventsSince(gmark), 'room:state', 'room:joined', 'code joiner');
  assert.deepEqual(collapseRuns(cg.eventsSince(gmark)), ['room:state', 'room:joined', 'chat:history', 'room:state', 'ack:room:joinCode']);

  // The host cannot switch away from a private table.
  const sw = await ch.emit('room:switch', {});
  assert.deepEqual(sw, { ok: false, code: 'private_table', message: 'A private table cannot be swapped for another' });

  // A public create at a boot the menu allows (any, in this profile) is also possible.
  const other = await guestLogin('device-parity-lobby-priv-public', 'PubCreator');
  const co = await openClient(other.token);
  const pub = await co.emit('room:create', { isPrivate: false, bootAmount: uniqueStake(), category: 'seen' });
  assert.equal(pub.ok, true, JSON.stringify(pub));
  assert.equal(co.last('room:joined').maxPot, profile.seenMaxPot);
  const listedAgain = await cg.emit('lobby:list', {});
  assert.ok(listedAgain.tables.some((t) => t.roomId === pub.roomId), 'a public table is listed');

  await closeAll(ch, cg, co);
});

// ------------------------------------------------------------- leaving

test('leaving: the last player hears room:closed before room:left; others see the seat empty', async () => {
  const a = await guestLogin('device-parity-lobby-leave-a', 'LeaveA');
  const b = await guestLogin('device-parity-lobby-leave-b', 'LeaveB');
  const ca = await openClient(a.token);
  const cb = await openClient(b.token);
  const bootAmount = uniqueStake();
  const joined = await ca.emit('room:quickJoin', { bootAmount });
  await cb.emit('room:quickJoin', { bootAmount });
  await cb.wait('room:state', (s) => occupied(s).length === 2);

  // A leaves with B still seated.
  const aMark = ca.mark();
  const bMark = cb.mark();
  const left = await ca.emit('room:leave', {});
  assert.deepEqual(left, { ok: true, roomId: joined.roomId });
  const aEvents = ca.eventsSince(aMark);
  assert.equal(aEvents.at(-1), 'ack:room:leave', 'the ack follows every emit');
  assert.ok(aEvents.includes('room:left'));
  assert.ok(!aEvents.includes('room:closed'), 'the room lives on');
  assert.deepEqual(ca.last('room:left'), { roomId: joined.roomId });
  assertBefore(aEvents, 'room:left', 'ack:room:leave', 'leaver');
  // Any snapshot the leaver was still sent shows them gone.
  const leaverStates = ca.since(aMark).filter((e) => e.event === 'room:state').map((e) => e.payload);
  if (leaverStates.length > 0) assert.equal(leaverStates.at(-1).you, null, 'a departed viewer has no `you`');

  const bView = await cb.waitNext('room:state', (s) => occupied(s).length === 1, 4000, bMark);
  assert.equal(bView.seats[0].status, 'empty');
  const line = cb.since(bMark).find((e) => e.event === 'chat:message')?.payload;
  assert.equal(line?.text, 'LeaveA left the table');
  assert.ok(['waiting', 'starting'].includes(bView.state));
  await eventually(() => assert.equal(cb.state().state, 'waiting', 'the countdown is cancelled with one player left'));
  assert.equal(cb.state().startsAt, null);

  // B, the last player, closes the room.
  const lastMark = cb.mark();
  const lastAck = await cb.emit('room:leave', {});
  assert.deepEqual(lastAck, { ok: true, roomId: joined.roomId });
  const lastEvents = cb.eventsSince(lastMark);
  assertOrder(lastEvents, ['room:closed', 'room:left', 'ack:room:leave'], 'last leaver');
  assert.deepEqual(cb.last('room:closed'), { roomId: joined.roomId });

  // The room is gone: quick-joining the same stake opens a fresh table with a fresh log.
  const rejoin = await ca.emit('room:quickJoin', { bootAmount });
  assert.equal(rejoin.ok, true);
  assert.notEqual(rejoin.roomId, joined.roomId);
  assert.equal(ca.last('chat:history').messages.length, 1);
  await closeAll(ca, cb);
});

// ----------------------------------------------------------- switching

test('room:switch moves to the fullest other table of the same kind without room:closed/room:left, and the vacated table is told', async () => {
  const bootAmount = uniqueStake();
  const [a, b, c] = await Promise.all([
    guestLogin('device-parity-lobby-switch-a', 'SwitchA'),
    guestLogin('device-parity-lobby-switch-b', 'SwitchB'),
    guestLogin('device-parity-lobby-switch-c', 'SwitchC'),
  ]);
  const ca = await openClient(a.token);
  const cb = await openClient(b.token);
  const cc = await openClient(c.token);

  // T1: A and B (a hand will be dealt). T2: C alone, opened as a public table.
  const t1 = await ca.emit('room:quickJoin', { bootAmount, category: 'blind' });
  await cb.emit('room:quickJoin', { bootAmount, category: 'blind' });
  const t2 = await cc.emit('room:create', { isPrivate: false, bootAmount, category: 'blind' });
  assert.equal(t2.ok, true, JSON.stringify(t2));
  assert.notEqual(t1.roomId, t2.roomId);
  await ca.wait('game:handStarted');

  const aMark = ca.mark();
  const bMark = cb.mark();
  const cMark = cc.mark();
  const moved = await ca.emit('room:switch', {});
  assert.deepEqual(moved, { ok: true, roomId: t2.roomId, code: t2.code, category: 'blind' });

  const aEvents = ca.eventsSince(aMark);
  assert.ok(!aEvents.includes('room:closed'), `no room:closed for a switcher: ${aEvents}`);
  assert.ok(!aEvents.includes('room:left'), `no room:left for a switcher: ${aEvents}`);
  // The new room's traffic, in join order; the old room's is filtered out by roomId.
  const newRoom = ca.since(aMark).filter((e) => e.payload?.roomId === t2.roomId || e.event.startsWith('ack:')).map((e) => e.event);
  assert.deepEqual(collapseRuns(newRoom), ['room:state', 'room:joined', 'chat:history', 'room:state', 'ack:room:switch']);
  assert.equal(ca.last('room:joined').roomId, t2.roomId);
  assert.equal(ca.last('room:joined').you.seatIndex, 1);

  // B: A's departure mid-hand is a pack with reason 'moved', B is last standing, and the seat empties.
  const pack = await cb.waitNext('game:action', (p) => p.action === 'pack' && p.userId === a.user.id, 4000, bMark);
  assert.equal(pack.reason, 'moved');
  const ended = await cb.waitNext('game:handEnded', () => true, 4000, bMark);
  assert.equal(ended.winnerId, b.user.id);
  assert.equal(ended.reason, 'last_standing');
  await cb.waitNext('room:state', (s) => occupied(s).length === 1, 4000, bMark);

  // C sees A arrive.
  await cc.waitNext('room:state', (s) => occupied(s).length === 2, 4000, cMark);
  assert.equal(cc.since(cMark).find((e) => e.event === 'chat:message')?.payload.text, 'SwitchA joined the table');

  await closeAll(ca, cb, cc);
});

// ------------------------------------------------------- consolidation

test('two lone players on tables of the same kind are merged: the mover hears room:closed, room:moved, room:joined, chat:history, room:state', async () => {
  const bootAmount = uniqueStake();
  const a = await guestLogin('device-parity-lobby-merge-a', 'MergeA');
  const b = await guestLogin('device-parity-lobby-merge-b', 'MergeB');
  const ca = await openClient(a.token);
  const cb = await openClient(b.token);

  // Two public tables at the same stake and category, one player each. The
  // older table is the destination.
  const t1 = await ca.emit('room:create', { isPrivate: false, bootAmount, category: 'seen' });
  assert.equal(t1.ok, true, JSON.stringify(t1));
  await pause(20);
  const t2 = await cb.emit('room:create', { isPrivate: false, bootAmount, category: 'seen' });
  assert.equal(t2.ok, true, JSON.stringify(t2));
  const aMark = ca.mark();
  const bMark = cb.mark();

  const movedEvent = await cb.waitNext('room:moved', () => true, 6000, bMark);
  assertKeys(movedEvent, ['fromRoomId', 'toRoomId', 'code', 'message'], 'room:moved');
  assert.deepEqual(movedEvent, {
    fromRoomId: t2.roomId, toRoomId: t1.roomId, code: t1.code, message: 'Moved to a table with other players waiting.',
  });
  await cb.waitNext('chat:history', (p) => p.roomId === t1.roomId, 4000, bMark);
  const historyAt = cb.seen.findIndex((e, i) => i >= bMark && e.event === 'chat:history' && e.payload.roomId === t1.roomId);
  await cb.waitNext('room:state', (s) => s.roomId === t1.roomId && occupied(s).length === 2, 4000, historyAt + 1);
  const bEvents = cb.eventsSince(bMark);
  // room:closed for the old room comes first; the new room's setConnected
  // snapshot may land between it and room:moved (Node does that), which is
  // why the order below is checked as a subsequence, not as adjacency.
  assertOrder(bEvents, ['room:closed', 'room:moved', 'room:joined', 'chat:history', 'room:state'], 'mover');
  assertBefore(bEvents, 'room:closed', 'room:moved', 'mover');
  assertBefore(bEvents, 'room:closed', 'room:joined', 'mover');
  assert.deepEqual(cb.last('room:closed'), { roomId: t2.roomId });
  assert.equal(cb.last('room:joined').roomId, t1.roomId);
  assert.equal(cb.last('room:joined').you.seatIndex, 1);
  assert.equal(cb.last('room:joined').you.chips, profile.welcomeChips);
  assert.ok(!bEvents.includes('room:left'), 'a merge is not a leave');

  // The host of the surviving table sees the arrival like any other join.
  await ca.waitNext('room:state', (s) => occupied(s).length === 2, 4000, aMark);
  assert.equal(ca.since(aMark).find((e) => e.event === 'chat:message')?.payload.text, 'MergeB joined the table');
  assert.ok(!ca.eventsSince(aMark).includes('room:closed'));

  await closeAll(ca, cb);
});

// -------------------------------------------------------- the entry cap

test('the entry cap guards the cheapest blind table from the lobby, not from a switch', async () => {
  const rich = await guestLogin('device-parity-lobby-cap-rich', 'Rich');
  const exact = await guestLogin('device-parity-lobby-cap-exact', 'Exact');
  const filler = await guestLogin('device-parity-lobby-cap-filler', 'Filler');
  const modest = await guestLogin('device-parity-lobby-cap-modest', 'Modest');
  await setWallet(rich.user.id, 500001, 'parity-lobby-cap-rich');
  await setWallet(exact.user.id, 500000, 'parity-lobby-cap-exact');
  const cr = await openClient(rich.token);
  const ce = await openClient(exact.token);
  const cf = await openClient(filler.token);
  const cm = await openClient(modest.token);

  let ack = await cr.emit('room:quickJoin', { bootAmount: 200, category: 'blind' });
  assert.deepEqual(ack, {
    ok: false, code: 'over_entry_cap', message: 'Players with more than 500,000 chips cannot join this table',
  });
  ack = await ce.emit('room:quickJoin', { bootAmount: 200, category: 'blind' });
  assert.equal(ack.ok, true, 'a stack exactly at the cap may still join');
  const capped = ack;
  // A second, ordinary player keeps that table from being a lone one (the
  // sweeper merges lone tables of the same kind, which would race this test).
  ack = await cf.emit('room:quickJoin', { bootAmount: 200, category: 'blind' });
  assert.equal(ack.roomId, capped.roomId);

  ack = await cr.emit('room:joinCode', { code: capped.code });
  assert.equal(ack.code, 'over_entry_cap', 'joining the capped table by code is refused too');
  ack = await cr.emit('room:quickJoin', { bootAmount: 200, category: 'seen' });
  assert.equal(ack.ok, true, 'the same stake in the other category is open');
  await cr.emit('room:leave', {});
  ack = await cr.emit('room:quickJoin', { bootAmount: 5000, category: 'blind' });
  assert.equal(ack.ok, true, 'and so is a higher stake in the capped category');
  await cr.emit('room:leave', {});

  // A private table is somewhere you were invited: no cap by code.
  const priv = await cm.emit('room:create', { isPrivate: true, category: 'blind' });
  ack = await cr.emit('room:joinCode', { code: priv.code });
  assert.equal(ack.ok, true, JSON.stringify(ack));
  await cr.emit('room:leave', {});
  await cm.emit('room:leave', {});

  // A switch between capped tables is a sideways move and is not capped. To
  // get the rich player seated at a public blind-200 table at all, drop the
  // stack through a fixture, sit down by code, then restore it.
  const second = await cm.emit('room:create', { isPrivate: false, bootAmount: 200, category: 'blind' });
  assert.equal(second.ok, true, JSON.stringify(second));
  await setWallet(rich.user.id, 1000, 'parity-lobby-cap-rich-drop');
  ack = await cr.emit('room:joinCode', { code: second.code });
  assert.equal(ack.ok, true, JSON.stringify(ack));
  await setWallet(rich.user.id, 500001, 'parity-lobby-cap-rich-topup');
  const sw = await cr.emit('room:switch', {});
  assert.equal(sw.ok, true, `switch is not capped: ${JSON.stringify(sw)}`);
  assert.equal(sw.roomId, capped.roomId, 'moved onto the other blind-200 table');
  assert.equal(cr.last('room:joined').you.chips, 500001, 'the seat takes the live wallet');

  await closeAll(cr, ce, cf, cm);
});
