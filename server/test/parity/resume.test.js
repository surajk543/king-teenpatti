/**
 * Disconnects, the reconnect grace, the resume offer and session replacement
 * (integration.test.js #18, #32–#35; spec-socket-protocol.md §10–§11):
 *
 *   - a dropped socket keeps its seat for RECONNECT_GRACE_MS; the table shows
 *     it `connected:false`; a reconnect inside the window gets `session:ready`
 *     (no `resume`), then `room:state`, `room:joined`, `chat:history` unasked;
 *   - once the grace lapses the seat goes (a pack with reason 'disconnected'
 *     if mid-hand) and the next sign-in is offered the table back, once, as
 *     `session:ready.resume {roomId, code, category, bootAmount}`;
 *   - a voluntary leave, or a table that closed meanwhile, leaves no offer;
 *   - a second sign-in replaces the first socket (`session:replaced`) and
 *     inherits the seat without any grace removal.
 *
 * Profile assumptions (tools/parity.mjs "main"): RECONNECT_GRACE_MS 400,
 * TURN_TIMEOUT_MS 1200, NEXT_HAND_DELAY_MS 150.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  guestLogin, openClient, closeAll, closeOpenClients, stakeCounter, profile, pause, eventually,
  assertKeys, assertOrder, collapseRuns,
} from './lib/harness.mjs';

test.after(closeOpenClients);

const uniqueStake = stakeCounter(3000);
const grace = profile.reconnectGraceMs;

/** Two players at a fresh table with the first hand dealt. */
const seatedPair = async (tag) => {
  const bootAmount = uniqueStake();
  const alice = await guestLogin(`device-parity-resume-${tag}-a`, 'Alice');
  const bob = await guestLogin(`device-parity-resume-${tag}-b`, 'Bob');
  const ca = await openClient(alice.token);
  const cb = await openClient(bob.token);
  const joined = await ca.emit('room:quickJoin', { bootAmount });
  assert.equal(joined.ok, true);
  const joinedB = await cb.emit('room:quickJoin', { bootAmount });
  assert.equal(joinedB.roomId, joined.roomId);
  await ca.wait('game:handStarted');
  await cb.wait('room:state', (s) => s.state === 'betting');
  return { bootAmount, alice, bob, ca, cb, joined };
};

test('a player whose app dies mid-hand is put straight back at the table on reconnect', async () => {
  const { alice, ca, cb, joined } = await seatedPair('held');

  const bMark = cb.mark();
  ca.drop(); // no room:leave — the socket simply goes away
  const away = await cb.waitNext('room:state', (s) => s.seats.some((seat) => seat.userId === alice.user.id && seat.connected === false), 4000, bMark);
  assert.equal(away.seats.find((seat) => seat.userId === alice.user.id).status, 'active', 'the seat is held, still in the hand');
  await pause(Math.min(100, grace / 4));

  const back = await openClient(alice.token);
  const ready = await back.wait('session:ready');
  assertKeys(ready, ['user', 'config'], 'session:ready');
  assert.equal(ready.resume, undefined, 'the seat is still held, so there is nothing to offer');

  // Nothing was asked for: the table snapshot arrives on its own.
  const state = await back.wait('room:joined');
  assert.equal(state.roomId, joined.roomId);
  assert.equal(state.state, 'betting', 'the hand carried on without them and is still live');
  assert.equal(state.you.status, 'active');
  assert.equal(state.seats[state.you.seatIndex].userId, alice.user.id);
  assert.equal(state.seats[state.you.seatIndex].connected, true);
  await back.wait('chat:history');
  assert.deepEqual(collapseRuns(back.events().filter((e) => ['session:ready', 'room:state', 'room:joined', 'chat:history'].includes(e))).slice(0, 4),
    ['session:ready', 'room:state', 'room:joined', 'chat:history'], 'a held seat is restored in this order');
  assert.equal(back.last('chat:history').roomId, joined.roomId);
  const rejoinedView = await cb.waitNext('room:state', (s) => s.seats.some((seat) => seat.userId === alice.user.id && seat.connected === true), 4000, bMark);
  assert.equal(rejoinedView.state, 'betting');
  assert.equal(cb.since(bMark).filter((e) => e.event === 'chat:message').length, 0, 'a reconnect is not a join: no system line');

  await closeAll(back, cb);
});

test('once the held seat has lapsed, the next sign-in is offered the same table back — once', async () => {
  const { bootAmount, alice, bob, ca, cb, joined } = await seatedPair('lapsed');

  const bMark = cb.mark();
  ca.drop();
  // Past the grace: the seat is given up. Mid-hand that is a pack, and Bob is last standing.
  const pack = await cb.waitNext('game:action', (a) => a.action === 'pack' && a.userId === alice.user.id, grace + 4000, bMark);
  assert.equal(pack.reason, 'disconnected');
  const ended = await cb.waitNext('game:handEnded', () => true, 4000, bMark);
  assert.equal(ended.winnerId, bob.user.id);
  assert.equal(ended.reason, 'last_standing');
  const gone = await cb.waitNext('room:state', (s) => s.seats.filter((seat) => seat.status !== 'empty').length === 1, 4000, bMark);
  assert.equal(gone.seats.find((s) => s.status !== 'empty').userId, ended.winnerId);
  assert.equal(cb.since(bMark).find((e) => e.event === 'chat:message')?.payload.text, 'Alice left the table');

  const back = await openClient(alice.token);
  const ready = await back.wait('session:ready');
  assertKeys(ready, ['user', 'config', 'resume'], 'session:ready with an offer');
  assert.deepEqual(ready.resume, {
    roomId: joined.roomId,
    code: joined.code,
    category: joined.category,
    bootAmount,
  });
  await pause(100);
  assert.equal(back.count('room:joined'), 0, 'no seat means no snapshot until they sit');
  assert.equal(back.count('room:state'), 0);

  // The client takes the offer up with the ordinary join-by-code.
  const rejoined = await back.emit('room:joinCode', { code: ready.resume.code });
  assert.equal(rejoined.ok, true, JSON.stringify(rejoined));
  assert.equal(rejoined.roomId, joined.roomId);
  assert.equal((await back.wait('room:joined')).roomId, joined.roomId);
  assert.equal(back.last('room:joined').you.chips, profile.welcomeChips - bootAmount, 'the boot stayed in the pot they walked out on');

  // Seated again, a further reconnect restores the seat and carries no offer.
  back.drop();
  await pause(50);
  const again = await openClient(alice.token);
  assert.equal((await again.wait('session:ready')).resume, undefined);
  assert.equal((await again.wait('room:joined')).roomId, joined.roomId);

  await closeAll(again, cb);
});

test('the offer is one-shot: a sign-in that does not take it up loses it', async () => {
  const { alice, ca, cb, joined } = await seatedPair('oneshot');
  ca.drop();
  await cb.waitNext('room:state', (s) => s.seats.filter((seat) => seat.status !== 'empty').length === 1, grace + 4000, 0);

  const first = await openClient(alice.token);
  assert.equal((await first.wait('session:ready')).resume?.roomId, joined.roomId, 'offered');
  first.drop();
  await pause(50);
  const second = await openClient(alice.token);
  assert.equal((await second.wait('session:ready')).resume, undefined, 'the offer was consumed by the first sign-in');
  await pause(100);
  assert.equal(second.count('room:joined'), 0);
  await closeAll(second, cb);
});

test('leaving a table on purpose leaves nothing to resume', async () => {
  const { alice, ca, cb } = await seatedPair('left');
  const left = await ca.emit('room:leave', undefined);
  assert.equal(left.ok, true);
  ca.drop();
  await pause(grace * 2);

  const back = await openClient(alice.token);
  const ready = await back.wait('session:ready');
  assert.equal(ready.resume, undefined);
  await pause(100);
  assert.equal(back.count('room:joined'), 0);
  await closeAll(back, cb);
});

test('a table that closed while the player was away is not offered back', async () => {
  const { alice, ca, cb, joined } = await seatedPair('closed');
  ca.drop();
  await cb.waitNext('room:state', (s) => s.seats.filter((seat) => seat.status !== 'empty').length === 1, grace + 4000, 0);
  // The last player walks out and the room is destroyed.
  const cbMark = cb.mark();
  await cb.close();
  assertOrder(cb.eventsSince(cbMark), ['room:closed', 'room:left'], 'last leaver');
  assert.equal(cb.last('room:closed').roomId, joined.roomId);

  const back = await openClient(alice.token);
  const ready = await back.wait('session:ready');
  assert.equal(ready.resume, undefined, 'there is no table left to return to');
  const stale = await back.emit('room:joinCode', { code: joined.code });
  assert.equal(stale.code, 'room_not_found');
  await back.close();
});

test('a second sign-in replaces the first session and inherits the seat without any grace removal', async () => {
  const bootAmount = uniqueStake();
  const account = await guestLogin('device-parity-resume-dup', 'Dup');
  const other = await guestLogin('device-parity-resume-dup-other', 'Other');
  const first = await openClient(account.token);
  const co = await openClient(other.token);
  const joined = await first.emit('room:quickJoin', { bootAmount });
  await co.emit('room:quickJoin', { bootAmount });
  await first.wait('game:handStarted');

  const disconnected = new Promise((resolve) => first.socket.once('disconnect', resolve));
  const oMark = co.mark();
  const second = await openClient(account.token);
  const replaced = await first.wait('session:replaced');
  assert.deepEqual(replaced, { message: 'Signed in from another device' });
  const reason = await disconnected;
  assert.equal(reason, 'io server disconnect', 'the server closes the old socket');
  assert.equal(first.socket.connected, false);

  // The new socket is the session now: seat restored at once, hand still live.
  assert.equal((await second.wait('session:ready')).resume, undefined);
  const view = await second.wait('room:joined');
  assert.equal(view.roomId, joined.roomId);
  assert.equal(view.you.status, 'active');
  assert.equal(view.state, 'betting');

  // Well past the grace, the seat is still there: the replacement counted as a reconnect.
  await pause(grace * 2);
  assert.equal(second.socket.connected, true);
  const still = co.state();
  assert.equal(still.seats.filter((s) => s.status !== 'empty').length, 2);
  assert.equal(still.seats.find((s) => s.userId === account.user.id).connected, true);
  assert.ok(!co.since(oMark).some((e) => e.event === 'game:action' && e.payload.reason === 'disconnected'), 'no disconnect pack');
  first.drop();
  await closeAll(second, co);
});

test('a socket without a valid token cannot connect (socket.io-client view)', async () => {
  await assert.rejects(openClient('garbage'), (error) => /invalid_session|unauthorized/.test(error.message));
  await assert.rejects(openClient(undefined), (error) => /missing_token/.test(error.message));
  await eventually(async () => {
    const account = await guestLogin('device-parity-resume-ok', 'Ok');
    const client = await openClient(account.token);
    assert.equal(client.socket.connected, true);
    await client.close();
  });
});
