import test from 'node:test';
import assert from 'node:assert/strict';

// Two game-server workers in one process, sharing a Postgres schema through the
// cluster registry (src/cluster/registry.js). Tables never move between workers;
// the registry only remembers *where* a player's seat and a table's code live so
// a socket that lands on the wrong worker — nginx's least_conn does not know
// about seats — can be sent to the right one with `session:redirect`.
//
// The config module snapshots the environment at import time, so everything
// this suite needs has to be set before the server is loaded. The suite gets a
// throwaway Postgres schema of its own, dropped again in test.after.
process.env.NODE_ENV = 'test';
process.env.PG_SCHEMA = `test_cluster_${Math.random().toString(36).slice(2, 8)}`;
process.env.JWT_SECRET = 'cluster-test-secret';
process.env.AUTH_ALLOW_FAKE_PROVIDERS = 'true';
process.env.WELCOME_CHIPS = '200000';
process.env.BOOT_AMOUNT = '100';
// No hand is ever played out here; a long clock keeps turn timeouts (and the
// idle kicks they lead to) out of every scenario.
process.env.TURN_TIMEOUT_MS = '20000';
process.env.NEXT_HAND_DELAY_MS = '150';
// Long enough that "disconnect, land on the other worker, get redirected, come
// back" always happens inside the held-seat window; short enough that the
// lapsed-seat case does not drag the suite out.
process.env.RECONNECT_GRACE_MS = '2000';
// Short enough that "the lapsed seat's registry row is released once the
// offer expires" can be watched; long enough that the case which takes the
// offer up (a few hundred ms after the lapse) never races it.
process.env.RESUME_OFFER_MS = '4000';
process.env.PORT = '0';
// Lift the lobby's fixed stakes so each test can use its own boot amount for
// isolation — quick-join matches on stake, so a unique one keeps tests apart.
process.env.TABLE_STAKES = '';
// ...and with it the menu of category/stake pairs, for the same reason.
process.env.LOBBY_TABLES = '';
// The workers are configured through createServer() options, not the
// environment: a stray WORKER_ID here would turn the single-process case into
// a third worker.
delete process.env.WORKER_ID;
delete process.env.WORKER_COUNT;
delete process.env.WORKER_BASE_PORT;

const { createServer } = await import('../src/index.js');
const { io: connect } = await import('socket.io-client');
const { query, dropSchema, closeDatabase } = await import('../src/db/index.js');

/** Every server this suite starts, torn down in reverse order in test.after. */
const servers = [];
let w1;
let w2;

/**
 * Starts a server on an ephemeral port. createServer() is handed the worker
 * identity directly (the same options the entrypoint derives from WORKER_ID /
 * WORKER_COUNT) so both workers can share this process and its pg pool.
 */
// Workers heartbeat this often here (5 s in production) so the cases that wait
// for one — the takeover reconciliation — stay quick.
const HEARTBEAT_MS = 700;

const startServer = async (options) => {
  const created = await createServer(options);
  if (!created.server.listening) {
    await new Promise((resolve) => created.server.listen(0, '127.0.0.1', resolve));
  }
  const started = { ...created, baseUrl: `http://127.0.0.1:${created.server.address().port}` };
  servers.push(started);
  return started;
};

/** The server's own shutdown: registry first, then sockets, then tables. */
const stopServer = (started) => started.shutdown();

test.before(async () => {
  w1 = await startServer({ workerId: 1, workerCount: 2, port: 0, heartbeatMs: HEARTBEAT_MS });
  w2 = await startServer({ workerId: 2, workerCount: 2, port: 0, heartbeatMs: HEARTBEAT_MS });
});

test.after(async () => {
  for (const started of [...servers].reverse()) await stopServer(started);
  await dropSchema();
  await closeDatabase();
});

/**
 * Quick-join matches players by stake, so giving each test its own boot amount
 * keeps it off tables left over from earlier tests — a disconnected player
 * keeps their seat for the reconnect grace period, which is intended behaviour
 * in production but would otherwise leak between cases here.
 */
let nextStake = 100;
const uniqueStake = () => {
  nextStake += 50;
  return nextStake;
};

// ------------------------------------------------------------------ helpers

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Polls `check` until it returns something truthy. The registry's room rows are
 * written fire-and-forget by design, so a test that reads them straight after
 * an ack would be racing the worker; polling makes the assertion about the
 * outcome rather than the timing.
 */
const eventually = async (check, { timeoutMs = 3000, everyMs = 25, label = 'condition' } = {}) => {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${label}`);
    await pause(everyMs);
  }
};

/** The registry's view of where a player is seated, or null. */
const playerRow = async (userId) => {
  const { rows } = await query(
    'SELECT worker_id, room_id, updated_at FROM cluster_players WHERE user_id = $1',
    [userId],
  );
  return rows[0] ?? null;
};

/** The registry's view of which worker owns a table code, or null. */
const roomRow = async (code) => {
  const { rows } = await query(
    'SELECT worker_id, room_id, is_private, category, boot_amount FROM cluster_rooms WHERE code = $1',
    [code],
  );
  return rows[0] ?? null;
};

const login = async (body, worker = w1) => {
  const response = await fetch(`${worker.baseUrl}/api/auth/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return { status: response.status, body: await response.json() };
};

/** Accounts live in the shared database, so a login on any worker is good everywhere. */
const guestLogin = async (deviceId, displayName) => {
  const { body } = await login({ provider: 'guest', deviceId, displayName });
  return body;
};

/**
 * Connects a socket straight to one worker's own port and returns a small
 * event-recording client. There is no nginx in front of the workers here, so
 * the Socket.IO path stays at its default; the per-worker `/w<id>/socket.io`
 * paths only ever appear in the payloads the server sends.
 */
const openClient = async (worker, token) => {
  const socket = connect(worker.baseUrl, {
    auth: { token },
    transports: ['websocket'],
    forceNew: true,
    // A redirected socket is hung up on by the server; the client under test
    // must decide where to connect next, not the library.
    reconnection: false,
  });
  const seen = [];

  for (const event of [
    'session:ready', 'session:redirect', 'session:replaced', 'room:joined', 'room:state',
    'room:left', 'room:closed', 'room:kicked', 'game:handStarted', 'game:handEnded',
    'game:error', 'chat:history',
  ]) {
    socket.on(event, (payload) => seen.push({ event, payload }));
  }
  socket.on('disconnect', (reason) => seen.push({ event: 'disconnect', payload: reason }));

  await new Promise((resolve, reject) => {
    socket.once('connect', resolve);
    socket.once('connect_error', reject);
    setTimeout(() => reject(new Error('connect timed out')), 4000);
  });

  return {
    socket,
    seen,
    last: (event) => [...seen].reverse().find((entry) => entry.event === event)?.payload,
    all: (event) => seen.filter((entry) => entry.event === event).map((entry) => entry.payload),
    /** Resolves when `event` arrives (or immediately if it already has). */
    wait: (event, predicate = () => true, timeoutMs = 4000) =>
      new Promise((resolve, reject) => {
        const existing = seen.find((entry) => entry.event === event && predicate(entry.payload));
        if (existing) return resolve(existing.payload);
        const timer = setTimeout(() => reject(new Error(`timed out waiting for ${event}`)), timeoutMs);
        const handler = (payload) => {
          if (!predicate(payload)) return;
          clearTimeout(timer);
          socket.off(event, handler);
          resolve(payload);
        };
        socket.on(event, handler);
        return undefined;
      }),
    emit: (event, payload) =>
      new Promise((resolve) => socket.emit(event, payload ?? {}, (ack) => resolve(ack))),
    /** Leaves the table before disconnecting so the seat is freed immediately. */
    close: async () => {
      await new Promise((resolve) => socket.emit('room:leave', {}, resolve));
      socket.disconnect();
    },
  };
};

const closeAll = (...clients) => Promise.all(clients.map((client) => client.close()));

/**
 * A client-side disconnect reaches the server a moment later; the tests that
 * reconnect elsewhere give it that moment, as the resume cases in
 * integration.test.js do, so the held-seat bookkeeping is in place first.
 */
const dropConnection = async (client) => {
  client.socket.disconnect();
  await pause(50);
};

const heartbeatOf = async (workerId) => {
  const { rows } = await query('SELECT heartbeat_at FROM cluster_workers WHERE worker_id = $1', [workerId]);
  return Number(rows[0]?.heartbeat_at ?? 0);
};

/**
 * Makes a live worker look dead: waits for its next heartbeat to land and then
 * sets the stamp to 0, which leaves a whole heartbeat interval before the
 * worker writes a fresh one — time enough for the few round-trips a case
 * needs while the worker is "dead".
 */
const goStale = async (workerId) => {
  const before = await heartbeatOf(workerId);
  await eventually(async () => (await heartbeatOf(workerId)) !== before, {
    timeoutMs: HEARTBEAT_MS * 3,
    label: `worker ${workerId} to heartbeat`,
  });
  await query('UPDATE cluster_workers SET heartbeat_at = 0 WHERE worker_id = $1', [workerId]);
};

// ---------------------------------------------------------- (a) session:ready

test('session:ready names the worker the socket landed on and its nginx path', async () => {
  assert.equal(w1.workerId, 1, 'createServer exposes the worker id it was given');
  assert.equal(w2.workerId, 2);

  // The registry's routing helpers, straight from the object the server built.
  assert.equal(w1.registry.socketPathFor(1), '/w1/socket.io');
  assert.equal(w1.registry.socketPathFor(2), '/w2/socket.io');
  assert.equal(w1.registry.isLocal(1), true);
  assert.equal(w1.registry.isLocal(2), false);
  assert.equal(w2.registry.isLocal(2), true);

  const alice = await guestLogin('cluster-device-ready-a', 'Alice');

  const onOne = await openClient(w1, alice.token);
  const readyOne = await onOne.wait('session:ready');
  assert.deepEqual(readyOne.worker, { id: 1, path: '/w1/socket.io' });
  assert.equal(readyOne.resume, undefined);
  assert.ok(readyOne.user, 'the rest of the payload is unchanged');
  assert.ok(readyOne.config);
  await dropConnection(onOne);

  // A player with no seat anywhere is served wherever they land.
  const onTwo = await openClient(w2, alice.token);
  const readyTwo = await onTwo.wait('session:ready');
  assert.deepEqual(readyTwo.worker, { id: 2, path: '/w2/socket.io' });
  assert.equal(onTwo.all('session:redirect').length, 0, 'nothing to redirect to');
  onTwo.socket.disconnect();
});

// ------------------------------------------------------------ (b) held seat

test('a held seat on another worker redirects the reconnecting player there', async () => {
  const bootAmount = uniqueStake();
  const alice = await guestLogin('cluster-device-seat-a', 'Alice');

  const ca = await openClient(w1, alice.token);
  const joined = await ca.emit('room:quickJoin', { bootAmount });
  assert.equal(joined.ok, true);
  assert.equal((await ca.wait('room:joined')).roomId, joined.roomId);

  // A force-closed app sends no room:leave — the socket simply goes away, and
  // worker 1 holds the seat for the grace period.
  await dropConnection(ca);
  assert.ok(w1.rooms.getTableForPlayer(alice.user.id), 'the seat is held through the grace period');

  // The reconnect lands on the other worker, which has never heard of the seat.
  const wrong = await openClient(w2, alice.token);
  const redirect = await wrong.wait('session:redirect');
  assert.deepEqual(redirect, { worker: 1, path: '/w1/socket.io', reason: 'seat' });

  const reason = await wrong.wait('disconnect');
  assert.equal(reason, 'io server disconnect', 'the wrong worker hangs up after pointing the way');
  assert.equal(wrong.all('session:ready').length, 0, 'no session is ever opened on the wrong worker');
  assert.equal(wrong.all('room:joined').length, 0);
  assert.equal(w2.rooms.getTableForPlayer(alice.user.id), null, 'worker 2 seated nobody');

  // Following the redirect lands straight back on the held seat.
  const back = await openClient(w1, alice.token);
  const ready = await back.wait('session:ready');
  assert.deepEqual(ready.worker, { id: 1, path: '/w1/socket.io' });
  assert.equal(ready.resume, undefined, 'the seat was never given up, so there is nothing to offer');

  const state = await back.wait('room:joined');
  assert.equal(state.roomId, joined.roomId, 'the same table, not a new one');
  assert.equal(state.seats[state.you.seatIndex].userId, alice.user.id);
  assert.equal(back.all('session:redirect').length, 0);

  await back.close();
});

test('once the held seat lapses, the resume offer still lives on the original worker', async () => {
  const bootAmount = uniqueStake();
  const alice = await guestLogin('cluster-device-lapse-a', 'Alice');
  const bob = await guestLogin('cluster-device-lapse-b', 'Bob');

  // Bob keeps the table alive so there is something to offer Alice back.
  const ca = await openClient(w1, alice.token);
  const cb = await openClient(w1, bob.token);
  const joined = await ca.emit('room:quickJoin', { bootAmount });
  assert.equal((await cb.emit('room:quickJoin', { bootAmount })).roomId, joined.roomId);
  await ca.wait('game:handStarted');

  await dropConnection(ca);
  await eventually(() => w1.rooms.getTableForPlayer(alice.user.id) === null, {
    timeoutMs: 4000,
    label: 'the held seat to lapse',
  });

  // The grace lapse must not release the registry row: it is what routes the
  // player back to the worker that is holding their resume offer.
  const row = await playerRow(alice.user.id);
  assert.ok(row, 'the lapsed seat still maps the player to worker 1');
  assert.equal(Number(row.worker_id), 1);

  const wrong = await openClient(w2, alice.token);
  const redirect = await wrong.wait('session:redirect');
  assert.deepEqual(redirect, { worker: 1, path: '/w1/socket.io', reason: 'seat' });
  assert.equal(await wrong.wait('disconnect'), 'io server disconnect');

  // Worker 1 has the offer, and taking it up is the ordinary join-by-code.
  const back = await openClient(w1, alice.token);
  const ready = await back.wait('session:ready');
  assert.deepEqual(ready.resume, {
    roomId: joined.roomId,
    code: joined.code,
    category: joined.category,
    bootAmount,
  });
  const rejoined = await back.emit('room:joinCode', { code: ready.resume.code });
  assert.equal(rejoined.ok, true);
  assert.equal(rejoined.roomId, joined.roomId);
  assert.equal((await back.wait('room:joined')).roomId, joined.roomId);

  await closeAll(back, cb);
});

// ------------------------------------------------- (c) join by code elsewhere

test('joining by code for a table on another worker is refused with a redirect', async () => {
  const host = await guestLogin('cluster-device-code-host', 'Host');
  const guest = await guestLogin('cluster-device-code-guest', 'Guest');

  const ch = await openClient(w2, host.token);
  const created = await ch.emit('room:create', { isPrivate: true });
  assert.equal(created.ok, true);
  assert.match(created.code, /^[A-Z2-9]{6}$/);

  // The code is published to the registry as the table is created; wait for
  // that write to land before another worker is asked about it.
  const published = await eventually(() => roomRow(created.code), { label: 'the room to be published' });
  assert.equal(Number(published.worker_id), 2);

  // The guest's socket is on worker 1, which has no such table locally.
  const cg = await openClient(w1, guest.token);
  const refused = await cg.emit('room:joinCode', { code: created.code });
  assert.equal(refused.ok, false);
  assert.equal(refused.code, 'other_worker');
  assert.equal(refused.path, '/w2/socket.io', 'the ack tells the client where to reconnect');
  assert.ok(refused.message);

  const redirect = await cg.wait('session:redirect');
  assert.deepEqual(redirect, {
    worker: 2,
    path: '/w2/socket.io',
    reason: 'room',
    joinCode: created.code,
  });

  // Unlike a seat redirect, a room redirect leaves the socket up: the client
  // reconnects to the other worker in its own time and replays the join.
  await pause(50);
  assert.equal(cg.socket.connected, true, 'the socket is not hung up on');
  assert.equal(w1.rooms.getTableForPlayer(guest.user.id), null, 'nothing was seated on worker 1');

  // A code nobody owns is still a plain room_not_found, not a redirect.
  const unknown = await cg.emit('room:joinCode', { code: 'ZZZZZZ' });
  assert.equal(unknown.ok, false);
  assert.equal(unknown.code, 'room_not_found');
  assert.equal(cg.all('session:redirect').length, 1, 'no redirect for a code that exists nowhere');

  // The client follows the redirect and the join goes through on worker 2.
  await dropConnection(cg);
  const onTwo = await openClient(w2, guest.token);
  await onTwo.wait('session:ready');
  assert.equal(onTwo.all('session:redirect').length, 0, 'the guest has no seat anywhere, so no redirect');

  const joined = await onTwo.emit('room:joinCode', { code: created.code });
  assert.equal(joined.ok, true);
  assert.equal(joined.roomId, created.roomId);
  assert.equal((await onTwo.wait('room:joined')).roomId, created.roomId);
  assert.equal(w2.rooms.getTable(created.roomId).playerCount, 2);

  await closeAll(ch, onTwo);
});

// ------------------------------------------------------- (d) after room:leave

test('a player who left on purpose can sit down on whichever worker they reach next', async () => {
  const alice = await guestLogin('cluster-device-left-a', 'Alice');

  const ca = await openClient(w1, alice.token);
  const joined = await ca.emit('room:quickJoin', { bootAmount: uniqueStake() });
  assert.equal(joined.ok, true);
  await eventually(() => playerRow(alice.user.id), { label: 'the seat to be claimed' });

  const left = await ca.emit('room:leave');
  assert.equal(left.ok, true);
  assert.equal(w1.rooms.getTableForPlayer(alice.user.id), null);
  // The release is what makes the next connection free to land anywhere.
  await eventually(async () => (await playerRow(alice.user.id)) === null, { label: 'the seat to be released' });
  await dropConnection(ca);

  const onTwo = await openClient(w2, alice.token);
  const ready = await onTwo.wait('session:ready');
  assert.deepEqual(ready.worker, { id: 2, path: '/w2/socket.io' });
  assert.equal(ready.resume, undefined, 'leaving on purpose leaves nothing to resume');
  assert.equal(onTwo.all('session:redirect').length, 0, 'no seat anywhere means no redirect');

  const seated = await onTwo.emit('room:quickJoin', { bootAmount: uniqueStake() });
  assert.equal(seated.ok, true);
  assert.notEqual(seated.roomId, joined.roomId, 'tables never move between workers — this is a new one');
  assert.ok(w2.rooms.getTableForPlayer(alice.user.id), 'seated on worker 2');
  assert.equal(w1.rooms.getTableForPlayer(alice.user.id), null);

  const row = await eventually(() => playerRow(alice.user.id), { label: 'the new seat to be claimed' });
  assert.equal(Number(row.worker_id), 2);
  assert.equal(row.room_id, seated.roomId);

  await onTwo.close();
});

// --------------------------------------------------------- (g) registry rows

test('the registry rows follow seats and tables', async () => {
  // start(): both workers registered themselves and are heartbeating.
  const { rows: workers } = await query(
    'SELECT worker_id, heartbeat_at FROM cluster_workers ORDER BY worker_id',
  );
  assert.deepEqual(workers.map((row) => Number(row.worker_id)), [1, 2]);
  for (const row of workers) {
    assert.ok(Date.now() - Number(row.heartbeat_at) < 15000, `worker ${row.worker_id} is alive`);
  }

  // cluster_players: present while seated, gone after room:leave.
  const dan = await guestLogin('cluster-device-rows-a', 'Dan');
  const cd = await openClient(w1, dan.token);
  const joined = await cd.emit('room:quickJoin', { bootAmount: uniqueStake() });
  assert.equal(joined.ok, true);

  const seatRow = await eventually(() => playerRow(dan.user.id), { label: 'the seat to be claimed' });
  assert.equal(Number(seatRow.worker_id), 1);
  assert.equal(seatRow.room_id, joined.roomId);
  assert.ok(Number(seatRow.updated_at) > 0, 'updated_at is an epoch-ms stamp');

  assert.equal((await cd.emit('room:leave')).ok, true);
  await eventually(async () => (await playerRow(dan.user.id)) === null, { label: 'the seat to be released' });
  cd.socket.disconnect();

  // cluster_rooms: a private table created on worker 2 is published under its
  // code and retired when the table is destroyed.
  const host = await guestLogin('cluster-device-rows-host', 'Host');
  const guest = await guestLogin('cluster-device-rows-guest', 'Guest');
  const ch = await openClient(w2, host.token);
  const cg = await openClient(w2, guest.token);

  const created = await ch.emit('room:create', { isPrivate: true, category: 'seen' });
  assert.equal(created.ok, true);

  const room = await eventually(() => roomRow(created.code), { label: 'the room to be published' });
  assert.equal(Number(room.worker_id), 2);
  assert.equal(room.room_id, created.roomId);
  assert.equal(Boolean(room.is_private), true);
  assert.equal(room.category, 'seen');
  assert.equal(Number(room.boot_amount), w2.rooms.getTable(created.roomId).config.bootAmount);

  const joinedByCode = await cg.emit('room:joinCode', { code: created.code });
  assert.equal(joinedByCode.ok, true);
  const guestRow = await eventually(() => playerRow(guest.user.id), { label: 'the guest to be claimed' });
  assert.equal(Number(guestRow.worker_id), 2);
  assert.equal(guestRow.room_id, created.roomId);

  // One departure leaves the table standing, and its row with it.
  assert.equal((await ch.emit('room:leave')).ok, true);
  assert.ok(w2.rooms.getTable(created.roomId), 'the table survives one player leaving');
  assert.ok(await roomRow(created.code), 'and so does its registry row');

  // The last player out destroys the table; the code is retired.
  assert.equal((await cg.emit('room:leave')).ok, true);
  assert.equal(w2.rooms.getTable(created.roomId), null, 'the empty table was destroyed');
  await eventually(async () => (await roomRow(created.code)) === null, { label: 'the room to be retired' });
  await eventually(
    async () => (await playerRow(host.user.id)) === null && (await playerRow(guest.user.id)) === null,
    { label: 'both seats to be released' },
  );

  ch.socket.disconnect();
  cg.socket.disconnect();
});

// ------------------------------------------------------------ (e) dead worker

test('a player mapped to a worker that has stopped heartbeating is taken over, not redirected', async () => {
  const alice = await guestLogin('cluster-device-stale-a', 'Alice');

  const ca = await openClient(w1, alice.token);
  const joined = await ca.emit('room:quickJoin', { bootAmount: uniqueStake() });
  assert.equal(joined.ok, true);
  const mapped = await eventually(() => playerRow(alice.user.id), { label: 'the seat to be claimed' });
  assert.equal(Number(mapped.worker_id), 1, 'the registry maps the player to worker 1');
  await dropConnection(ca);

  // Worker 1 "dies": its heartbeat goes stale. The live worker 1 re-stamps its
  // heartbeat every 5 s, so the stamp is checked again after the connection —
  // if a heartbeat landed in between, the outcome says nothing and the
  // scenario is rerun rather than reported as a flaky failure.
  const answered = (client) =>
    client.seen.some((entry) => entry.event === 'session:ready' || entry.event === 'session:redirect');
  let back;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    await goStale(1);
    back = await openClient(w2, alice.token);
    await eventually(() => answered(back), { label: 'worker 2 to answer the connection' });
    const { rows } = await query('SELECT heartbeat_at FROM cluster_workers WHERE worker_id = $1', [1]);
    if (Number(rows[0].heartbeat_at) === 0) break;
    back.socket.disconnect();
    back = null;
  }
  assert.ok(back, 'could not keep worker 1 stale long enough to observe a connection');

  assert.equal(back.all('session:redirect').length, 0, 'nobody is sent to a worker that has stopped answering');
  const ready = await back.wait('session:ready');
  assert.deepEqual(ready.worker, { id: 2, path: '/w2/socket.io' });
  assert.equal(back.socket.connected, true);

  // Sitting down here re-homes the registry row to the worker that took over.
  const seated = await back.emit('room:quickJoin', { bootAmount: uniqueStake() });
  assert.equal(seated.ok, true);
  const rehomed = await eventually(async () => {
    const row = await playerRow(alice.user.id);
    return row && Number(row.worker_id) === 2 ? row : null;
  }, { label: 'the seat to be re-homed on worker 2' });
  assert.equal(rehomed.room_id, seated.roomId);

  // Worker 1 is not actually dead: put its heartbeat back so later cases (and
  // its own next heartbeat) see a live worker again.
  await query('UPDATE cluster_workers SET heartbeat_at = $2 WHERE worker_id = $1', [1, Date.now()]);
  await back.close();
});

// ------------------------------------------------- (h) one seat per wallet

test('the same account cannot be seated on two live workers at once', async () => {
  const alice = await guestLogin('cluster-device-double-a', 'Alice');

  // Two devices, both in the lobby: no row yet, so neither is redirected.
  const onOne = await openClient(w1, alice.token);
  const onTwo = await openClient(w2, alice.token);
  await onOne.wait('session:ready');
  await onTwo.wait('session:ready');
  assert.equal(onOne.all('session:redirect').length, 0);
  assert.equal(onTwo.all('session:redirect').length, 0);

  const seated = await onOne.emit('room:quickJoin', { bootAmount: uniqueStake() });
  assert.equal(seated.ok, true);
  assert.equal((await onOne.wait('room:joined')).roomId, seated.roomId);
  const row = await playerRow(alice.user.id);
  assert.equal(Number(row.worker_id), 1, 'the claim is written before room:joined is sent');

  // The second device tries to sit down on worker 2 with the same wallet.
  const tablesBefore = w2.rooms.tables.size;
  const refused = await onTwo.emit('room:quickJoin', { bootAmount: uniqueStake() });
  assert.equal(refused.ok, false);
  assert.equal(refused.code, 'already_seated');
  assert.equal(refused.path, '/w1/socket.io', 'the ack names the worker holding the seat');
  const redirect = await onTwo.wait('session:redirect');
  assert.deepEqual(redirect, { worker: 1, path: '/w1/socket.io', reason: 'seat' });
  assert.equal(onTwo.all('room:joined').length, 0, 'the refused seat was never shown');
  assert.equal(w2.rooms.getTableForPlayer(alice.user.id), null, 'worker 2 gave the seat straight back');
  assert.equal(w2.rooms.tables.size, tablesBefore, 'the table opened for the refused seat is gone again');

  // The registry still says worker 1, and worker 1 still has the seat.
  const after = await playerRow(alice.user.id);
  assert.equal(Number(after.worker_id), 1);
  assert.equal(after.room_id, seated.roomId);
  assert.ok(w1.rooms.getTableForPlayer(alice.user.id));

  // A private table is refused the same way — the empty table is destroyed.
  const created = await onTwo.emit('room:create', { isPrivate: true });
  assert.equal(created.ok, false);
  assert.equal(created.code, 'already_seated');
  assert.equal(
    [...w2.rooms.tables.values()].filter((table) => table.isPrivate).length,
    0,
    'the private table did not survive',
  );

  onTwo.socket.disconnect();
  await onOne.close();
});

// --------------------------------------------- (i) takeover releases the seat

test('a seat taken over while the worker was stale is released on its next heartbeat', async () => {
  const alice = await guestLogin('cluster-device-zombie-a', 'Alice');
  const bob = await guestLogin('cluster-device-zombie-b', 'Bob');

  // Alice and Bob play on worker 1; Alice's socket stays connected throughout,
  // so no grace timer can be what frees her seat.
  const ca = await openClient(w1, alice.token);
  const cb = await openClient(w1, bob.token);
  const bootAmount = uniqueStake();
  const joined = await ca.emit('room:quickJoin', { bootAmount });
  assert.equal(joined.ok, true);
  assert.equal((await cb.emit('room:quickJoin', { bootAmount })).roomId, joined.roomId);
  await eventually(() => playerRow(alice.user.id), { label: 'the seat to be claimed' });

  // Worker 1 goes quiet; a second device of Alice's reaches worker 2 and sits
  // down there. The claim succeeds because worker 1's heartbeat is stale.
  let elsewhere;
  let seated;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    await goStale(1);
    elsewhere = await openClient(w2, alice.token);
    await eventually(() => elsewhere.seen.some((e) => e.event === 'session:ready' || e.event === 'session:redirect'), {
      label: 'worker 2 to answer',
    });
    if (elsewhere.all('session:redirect').length > 0) {
      // A heartbeat landed first; try again.
      elsewhere.socket.disconnect();
      elsewhere = null;
      continue;
    }
    seated = await elsewhere.emit('room:quickJoin', { bootAmount: uniqueStake() });
    if (seated.ok) break;
    assert.equal(seated.code, 'already_seated', `unexpected refusal: ${seated.code}`);
    elsewhere.socket.disconnect();
    elsewhere = null;
  }
  assert.ok(elsewhere && seated?.ok, 'could not keep worker 1 stale long enough to take the player over');
  const row = await playerRow(alice.user.id);
  assert.equal(Number(row.worker_id), 2, 'the registry now maps Alice to worker 2');
  assert.equal(row.room_id, seated.roomId);

  // Worker 1 comes back to life and notices on its next heartbeat that the
  // seat it still holds belongs to another worker: it releases it, tells the
  // socket, and sends it where the seat now is.
  await eventually(() => w1.rooms.getTableForPlayer(alice.user.id) === null, {
    timeoutMs: HEARTBEAT_MS * 4,
    label: 'worker 1 to release the taken-over seat',
  });
  const kicked = await ca.wait('room:kicked');
  assert.equal(kicked.roomId, joined.roomId);
  assert.equal(kicked.reason, 'takeover');
  const redirect = await ca.wait('session:redirect');
  assert.deepEqual(redirect, { worker: 2, path: '/w2/socket.io', reason: 'seat' });
  assert.equal(await ca.wait('disconnect'), 'io server disconnect');

  // Bob is alone at the table and sees Alice gone; worker 2's seat is intact.
  const table = w1.rooms.getTable(joined.roomId);
  assert.ok(table, 'the table survives with Bob at it');
  assert.equal(table.playerCount, 1);
  assert.ok(w2.rooms.getTableForPlayer(alice.user.id), 'the seat on worker 2 is untouched');
  assert.equal(Number((await playerRow(alice.user.id)).worker_id), 2, 'the row was never touched by worker 1');

  await closeAll(elsewhere, cb);
});

// ----------------------------------------- (j) lapsed rows are released

test('a lapsed seat\'s registry row is released once the resume offer expires', async () => {
  const bootAmount = uniqueStake();
  const alice = await guestLogin('cluster-device-expire-a', 'Alice');
  const bob = await guestLogin('cluster-device-expire-b', 'Bob');

  const ca = await openClient(w1, alice.token);
  const cb = await openClient(w1, bob.token);
  const joined = await ca.emit('room:quickJoin', { bootAmount });
  assert.equal((await cb.emit('room:quickJoin', { bootAmount })).roomId, joined.roomId);
  await eventually(() => playerRow(alice.user.id), { label: 'the seat to be claimed' });

  await dropConnection(ca);
  await eventually(() => w1.rooms.getTableForPlayer(alice.user.id) === null, {
    timeoutMs: 4000,
    label: 'the held seat to lapse',
  });
  const lapsedAt = Date.now();
  assert.ok(await playerRow(alice.user.id), 'the row outlives the seat while the offer stands');

  // The row goes when the offer would have; a live worker does not keep it
  // around by refreshing it. (RESUME_OFFER_MS is 4 s in this suite.)
  await eventually(async () => (await playerRow(alice.user.id)) === null, {
    timeoutMs: 4000 + 2000,
    everyMs: 100,
    label: 'the lapsed row to be released',
  });
  assert.ok(Date.now() - lapsedAt >= 3500, 'not released before the offer window ran out');

  // With no row, the player lands wherever they connect, no redirect.
  const onTwo = await openClient(w2, alice.token);
  const ready = await onTwo.wait('session:ready');
  assert.equal(ready.resume, undefined, 'the offer is gone with the row');
  assert.equal(onTwo.all('session:redirect').length, 0);
  onTwo.socket.disconnect();
  await cb.close();
});

// ------------------------------------------------- (k) shutdown withdraws first

test('a stopping worker withdraws its rows before it drops its sockets', async () => {
  const w3 = await startServer({ workerId: 3, workerCount: 3, port: 0, heartbeatMs: HEARTBEAT_MS });
  const alice = await guestLogin('cluster-device-stop-a', 'Alice');

  const ca = await openClient(w3, alice.token);
  const joined = await ca.emit('room:quickJoin', { bootAmount: uniqueStake() });
  assert.equal(joined.ok, true);
  assert.equal(Number((await playerRow(alice.user.id)).worker_id), 3);

  // What the registry says at the instant the socket is closed on us.
  let rowsAtDisconnect;
  const disconnected = new Promise((resolve) => {
    ca.socket.once('disconnect', () => {
      rowsAtDisconnect = Promise.all([
        playerRow(alice.user.id),
        query('SELECT 1 FROM cluster_workers WHERE worker_id = 3').then((r) => r.rows.length),
      ]);
      resolve();
    });
  });

  await w3.shutdown();
  servers.splice(servers.indexOf(w3), 1);
  await disconnected;
  const [row, workerRows] = await rowsAtDisconnect;
  assert.equal(row, null, 'the player row was gone before the socket was closed');
  assert.equal(workerRows, 0, 'and so was the worker row');

  // Reconnecting anywhere is served locally — nothing points at the dead port.
  const onOne = await openClient(w1, alice.token);
  const ready = await onOne.wait('session:ready');
  assert.deepEqual(ready.worker, { id: 1, path: '/w1/socket.io' });
  assert.equal(onOne.all('session:redirect').length, 0);
  onOne.socket.disconnect();
});

// ------------------------------------------------------ (f) single process

test('single-process mode: worker 0 on the default path, and nothing ever redirects', async () => {
  const single = await startServer();
  assert.equal(single.workerId, 0, 'no worker id means single-process mode');

  // The null registry: knows nothing, refuses nothing, treats every worker as
  // local, and never registers itself.
  assert.equal(single.registry.isLocal(1), true);
  assert.equal(single.registry.isLocal(2), true);
  const { rows: zero } = await query('SELECT 1 FROM cluster_workers WHERE worker_id = 0');
  assert.equal(zero.length, 0, 'a single-process server does not register as a worker');

  // Carol holds a seat on worker 1 — a live, heartbeating worker.
  const carol = await guestLogin('cluster-device-single-a', 'Carol');
  const onOne = await openClient(w1, carol.token);
  const joined = await onOne.emit('room:quickJoin', { bootAmount: uniqueStake() });
  assert.equal(joined.ok, true);
  await eventually(() => playerRow(carol.user.id), { label: 'the seat to be claimed' });
  await dropConnection(onOne);

  assert.equal(await single.registry.whereIsPlayer(carol.user.id), null, 'the null registry never finds a player');
  assert.equal(await single.registry.whereIsRoom(joined.code), null, 'or a room');

  // A single-process server serves her locally regardless.
  const onSingle = await openClient(single, carol.token);
  const ready = await onSingle.wait('session:ready');
  assert.deepEqual(ready.worker, { id: 0, path: '/socket.io' });
  assert.equal(onSingle.all('session:redirect').length, 0, 'single-process mode never redirects');
  assert.equal(onSingle.all('room:joined').length, 0, 'the seat lives on worker 1, not here');
  onSingle.socket.disconnect();

  // Tidy up: the held seat on worker 1 is given back on purpose.
  const backOnOne = await openClient(w1, carol.token);
  assert.equal((await backOnOne.wait('room:joined')).roomId, joined.roomId);
  await backOnOne.close();
});
