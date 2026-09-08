/**
 * Shared client helpers for the black-box parity suites.
 *
 * Every suite in test/parity/ talks to a server it did not start, named by
 * SERVER_URL, over exactly the surfaces a shipped client uses: fetch for REST,
 * socket.io-client (websocket only) for the realtime protocol, and a pg
 * connection to the server's own schema for the checks the Node suites made
 * by peeking into process memory. tools/parity.mjs sets the environment; run
 * a suite by hand with
 *
 *   SERVER_URL=http://127.0.0.1:3000 PG_SCHEMA=public PARITY_TARGET=node \
 *     node --test test/parity/rest.test.js
 *
 * Every socket opened through `openClient` is registered so `closeOpenClients`
 * (called from each suite's `test.after`) can tear down whatever a failing
 * test left behind — an open websocket would otherwise keep the runner alive
 * until the file timeout.
 */
import assert from 'node:assert/strict';
import { io as connect } from 'socket.io-client';

const missing = (name) => {
  throw new Error(
    `${name} is not set. The parity suites run against a live server — use \`npm run parity -- --target node\` `
    + '(or --target go --bin <path>), or export SERVER_URL / PG_SCHEMA / DATABASE_URL yourself.',
  );
};

/** Base URL of the server under test, e.g. http://127.0.0.1:41235 (no trailing slash). */
export const baseUrl = (process.env.SERVER_URL ?? missing('SERVER_URL')).replace(/\/+$/, '');
export const wsUrl = baseUrl.replace(/^http/, 'ws');

/**
 * Which implementation is on the other end: 'node' or 'go'. Used only where
 * DECISIONS.md records a deliberate difference (a handful of HTTP statuses and
 * the runtime metric names); everything else is asserted identically.
 */
export const target = process.env.PARITY_TARGET ?? 'node';
export const isNode = target === 'node';
export const isGo = target === 'go';

/** The JWT secret the harness started the server with (for cross-minted tokens). */
export const jwtSecret = process.env.PARITY_JWT_SECRET ?? 'parity-secret';
/** The bearer token /metrics demands, when the server was started with one. */
export const metricsToken = process.env.PARITY_METRICS_TOKEN ?? 'metrics-test-token';

/** The env profile the server was started with (see tools/parity.mjs PROFILES). */
export const profile = {
  bootAmount: Number(process.env.PARITY_BOOT_AMOUNT ?? 100),
  turnTimeoutMs: Number(process.env.PARITY_TURN_TIMEOUT_MS ?? 1200),
  nextHandDelayMs: Number(process.env.PARITY_NEXT_HAND_DELAY_MS ?? 150),
  reconnectGraceMs: Number(process.env.PARITY_RECONNECT_GRACE_MS ?? 400),
  sideshowTimeoutMs: Number(process.env.PARITY_SIDESHOW_TIMEOUT_MS ?? 1500),
  welcomeChips: Number(process.env.PARITY_WELCOME_CHIPS ?? 200000),
  maxPlayers: 5,
  minPlayers: 2,
  maxMissedTurns: 3,
  maxBlindMoves: 4,
  sideshowMinPlayers: 3,
  privateBoot: 200,
  privateMaxPot: 500000,
  seenMaxPot: 1200000,
  chatMaxLength: 140,
};

export const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Card codes on the wire: rank 2-9 T J Q K A, suit s h d c. */
export const CARD_CODE = /^[2-9TJQKA][shdc]$/;
export const ROOM_CODE = /^[A-Z2-9]{6}$/;
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const HAND_NAMES = ['High Card', 'Pair', 'Color', 'Sequence', 'Pure Sequence', 'Trail'];

/** Exact key sets of the wire objects, for shape assertions. */
export const SNAPSHOT_KEYS = [
  'roomId', 'code', 'category', 'chipsHidden', 'state', 'handNo', 'dealerSeat', 'maxPlayers', 'minPlayers',
  'bootAmount', 'turnTimeoutMs', 'startsAt', 'pot', 'maxPot', 'stake', 'round', 'sideshow', 'turn', 'you', 'seats',
];
export const YOU_KEYS = [
  'seatIndex', 'chips', 'status', 'isBlind', 'blindMovesLeft', 'contributed', 'missedTurns', 'maxMissedTurns',
  'cards', 'options',
];
export const SEAT_KEYS = [
  'seatIndex', 'userId', 'displayName', 'avatarUrl', 'chips', 'status', 'isBlind', 'lastBet', 'lastAction',
  'contributed', 'connected', 'cardCount',
];
export const OPTIONS_KEYS = [
  'canSee', 'canSideshow', 'sideshowWith', 'chaal', 'raise', 'raiseSteps', 'maxBet', 'show', 'canPack', 'isBlind',
  'currentStake', 'chips', 'pot',
];
export const CONFIG_KEYS = [
  'maxPlayers', 'minPlayers', 'bootAmount', 'turnTimeoutMs', 'welcomeChips', 'maxBetRounds', 'sideshowTimeoutMs',
  'sideshowMinPlayers', 'categories', 'stakes', 'tables', 'entryCapBoot', 'entryCapCategory', 'entryCapMaxChips',
  'privateBoot', 'privateMaxPot',
];

// ------------------------------------------------------------------- REST

/** POST/GET helper returning { status, headers, body (parsed JSON or text) }. */
export const http = async (method, path, { body, token, headers = {}, raw = false } = {}) => {
  const init = { method, headers: { ...headers } };
  if (token) init.headers.authorization = `Bearer ${token}`;
  if (body !== undefined) {
    if (typeof body === 'string') {
      init.body = body;
      if (!init.headers['content-type']) init.headers['content-type'] = 'application/json';
    } else {
      init.body = JSON.stringify(body);
      init.headers['content-type'] = 'application/json';
    }
  }
  const response = await fetch(`${baseUrl}${path}`, init);
  const text = await response.text();
  let parsed = text;
  if (!raw) {
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = text;
    }
  }
  return { status: response.status, headers: response.headers, body: parsed, text };
};

export const login = (body) => http('POST', '/api/auth/login', { body });

/** Logs a guest in and returns the response body ({token, user, isNew, welcomeChips}). */
export const guestLogin = async (deviceId, displayName) => {
  const { status, body } = await login({ provider: 'guest', deviceId, displayName });
  assert.equal(status, 200, `guest login ${deviceId} failed: ${JSON.stringify(body)}`);
  return body;
};

/** GET /api/auth/me → public user. */
export const me = async (token) => {
  const { status, body } = await http('GET', '/api/auth/me', { token });
  assert.equal(status, 200, `/api/auth/me failed: ${JSON.stringify(body)}`);
  return body.user;
};

export const health = async () => {
  const { status, body } = await http('GET', '/health');
  assert.equal(status, 200);
  return body;
};

// ---------------------------------------------------------------- sockets

/** Every client still open, so a suite can tear down whatever a failed test left. */
const openClients = new Set();

/**
 * Connects a socket.io client and records EVERY inbound event (via onAny) plus
 * every ack, in arrival order, so tests can assert ordering as well as shape.
 *
 * `emit(event, payload)` sends the payload verbatim (null/undefined included —
 * the invalid-input suite depends on that) and resolves with the ack.
 * `close()` leaves the table first so the seat is freed at once instead of
 * being held for the reconnect grace.
 */
export const openClient = async (token, { timeoutMs = 4000, query, leaveOnClose = true } = {}) => {
  const socket = connect(baseUrl, {
    auth: token === undefined ? undefined : { token },
    query,
    transports: ['websocket'],
    forceNew: true,
    reconnection: false,
  });
  const seen = [];
  socket.onAny((event, payload) => seen.push({ event, payload }));

  await new Promise((resolve, reject) => {
    socket.once('connect', resolve);
    socket.once('connect_error', (error) => {
      socket.disconnect();
      reject(error);
    });
    setTimeout(() => reject(new Error('connect timed out')), timeoutMs);
  });

  const client = {
    socket,
    seen,
    token,
    /** Event names in arrival order (acks appear as `ack:<event>`). */
    events: () => seen.map((entry) => entry.event),
    last: (event) => [...seen].reverse().find((entry) => entry.event === event)?.payload,
    all: (event) => seen.filter((entry) => entry.event === event).map((entry) => entry.payload),
    count: (event) => seen.filter((entry) => entry.event === event).length,
    /** The viewer's latest snapshot (room:state, else room:joined). */
    state: () => {
      const latest = [...seen].reverse().find((entry) => entry.event === 'room:state' || entry.event === 'room:joined');
      return latest?.payload;
    },
    /** Resolves when `event` arrives matching `predicate` (or immediately if it already has). */
    wait: (event, predicate = () => true, waitMs = 4000) =>
      new Promise((resolve, reject) => {
        const existing = seen.find((entry) => entry.event === event && predicate(entry.payload));
        if (existing) return resolve(existing.payload);
        const timer = setTimeout(
          () => reject(new Error(`timed out waiting for ${event} (seen: ${seen.map((e) => e.event).join(', ')})`)),
          waitMs,
        );
        const handler = (payload) => {
          if (!predicate(payload)) return;
          clearTimeout(timer);
          socket.off(event, handler);
          resolve(payload);
        };
        socket.on(event, handler);
        return undefined;
      }),
    /** Like wait, but only considers entries recorded from index `from` (default: now) onwards. */
    waitNext: (event, predicate = () => true, waitMs = 4000, from = seen.length) =>
      new Promise((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error(`timed out waiting for next ${event} (seen since mark: ${seen.slice(from).map((e) => e.event).join(', ')})`)),
          waitMs,
        );
        const check = () => {
          for (let i = from; i < seen.length; i += 1) {
            if (seen[i].event === event && predicate(seen[i].payload)) {
              clearTimeout(timer);
              socket.offAny(check);
              return resolve(seen[i].payload);
            }
          }
          return undefined;
        };
        socket.onAny(check);
        check();
      }),
    /**
     * Resolves with the latest snapshot if it satisfies `predicate`, else with
     * the next room:state that does. Use this for "the table is now X" checks —
     * `wait` would match a stale earlier snapshot.
     */
    waitState: (predicate, waitMs = 4000) => {
      const now = client.state();
      if (now && predicate(now)) return Promise.resolve(now);
      return client.waitNext('room:state', predicate, waitMs);
    },
    /** Resolves once at least `n` events of this name have been recorded. */
    waitCount: (event, n, waitMs = 4000) =>
      new Promise((resolve, reject) => {
        const matching = () => seen.filter((entry) => entry.event === event);
        if (matching().length >= n) return resolve(matching());
        const timer = setTimeout(
          () => reject(new Error(`timed out waiting for ${n} × ${event} (have ${matching().length})`)),
          waitMs,
        );
        const check = () => {
          if (matching().length >= n) {
            clearTimeout(timer);
            socket.offAny(check);
            resolve(matching());
          }
        };
        socket.onAny(check);
        return undefined;
      }),
    emit: (event, payload) =>
      new Promise((resolve) => socket.emit(event, payload, (ack) => {
        seen.push({ event: `ack:${event}`, payload: ack });
        resolve(ack);
      })),
    /** Emits and resolves with the ack, or the string 'no_ack' after `waitMs`. */
    emitOrTimeout: (event, payload, waitMs = 1500) =>
      Promise.race([client.emit(event, payload), pause(waitMs).then(() => 'no_ack')]),
    /** Emits without asking for an ack (what bots and the browser do for moves). */
    fire: (event, payload) => socket.emit(event, payload),
    /** Marks the stream so `since(mark)` returns only later entries. */
    mark: () => seen.length,
    since: (mark) => seen.slice(mark),
    /** Event names recorded since `mark`. */
    eventsSince: (mark) => seen.slice(mark).map((entry) => entry.event),
    close: async () => {
      if (socket.connected && leaveOnClose) {
        await Promise.race([
          new Promise((resolve) => socket.emit('room:leave', {}, resolve)),
          pause(2000),
        ]);
      }
      socket.disconnect();
      openClients.delete(client);
    },
    /** Drops the connection without leaving — what a force-closed app does. */
    drop: () => {
      socket.disconnect();
      openClients.delete(client);
    },
  };
  openClients.add(client);
  return client;
};

export const closeAll = (...clients) => Promise.all(clients.map((client) => client.close()));

/** Tears down every client a suite still has open. Call from `test.after`. */
export const closeOpenClients = async () => {
  const pending = [...openClients];
  await Promise.all(pending.map((client) => client.close().catch(() => {})));
};

/**
 * Suites sharing one server each get their own stake range, so a seat held
 * for the reconnect grace by one suite's disconnect test cannot land the next
 * suite on a stale table. Quick-join matches on (boot, category).
 */
export const stakeCounter = (base) => {
  let next = base;
  return () => {
    next += 50;
    return next;
  };
};

/** The seat currently on turn, read from the viewer's latest snapshot. */
export const turnUserOf = (client) => client.state()?.turn?.userId ?? null;

/**
 * Seats `count` fresh guests at a table of their own and waits for the deal.
 * Returns the clients, who is on turn (from room:state.turn), and the join ack.
 * `bySeat[i]` is the entry seated at seat index i (seat order = join order).
 */
export const dealtTable = async (tag, uniqueStake, { count = 2, category, names, deviceTag } = {}) => {
  const bootAmount = uniqueStake();
  const accounts = [];
  const clients = [];
  for (let i = 0; i < count; i += 1) {
    const name = names?.[i] ?? `${tag}${i}`;
    const account = await guestLogin(`device-parity-${deviceTag ?? tag}-${i}`, name);
    const client = await openClient(account.token);
    const ack = await client.emit('room:quickJoin', category ? { bootAmount, category } : { bootAmount });
    assert.equal(ack.ok, true, `quickJoin for ${name}: ${JSON.stringify(ack)}`);
    accounts.push(account);
    clients.push(client);
  }
  const joined = clients[0].last('ack:room:quickJoin');
  const started = await clients[0].wait('game:handStarted', (p) => p.participants.length === count, 6000);
  for (const client of clients) {
    await client.wait('room:state', (p) => p.state === 'betting' && p.turn?.userId && p.handNo === started.handNo, 6000);
  }
  const state = clients[0].state();
  const turnUserId = state.turn.userId;
  const entries = accounts.map((account, i) => ({
    account, user: account.user, client: clients[i], seatIndex: clients[i].state().you.seatIndex,
  }));
  const byUser = Object.fromEntries(entries.map((entry) => [entry.user.id, entry]));
  const bySeat = Object.fromEntries(entries.map((entry) => [entry.seatIndex, entry]));
  const onTurn = byUser[turnUserId].client;
  const onTurnUser = byUser[turnUserId].user;
  const waiting = clients.filter((c) => c !== onTurn);
  const waitingUsers = accounts.filter((a) => a.user.id !== turnUserId).map((a) => a.user);
  return {
    bootAmount, accounts, clients, byUser, bySeat, entries, joined, started, state,
    onTurn, onTurnUser,
    waiting: waiting[0], waitingUser: waitingUsers[0],
    waitingAll: waiting, waitingUsersAll: waitingUsers,
    roomId: joined.roomId,
    code: joined.code,
    /** The client whose turn it is right now, from the first client's latest snapshot. */
    current: () => byUser[turnUserOf(clients[0])],
  };
};

/** Exact key set of an object, for shape assertions. */
export const keysOf = (object) => Object.keys(object).sort();
export const assertKeys = (object, expected, label = 'object') => {
  assert.deepEqual(keysOf(object), [...expected].sort(), `${label} keys`);
};

/** Asserts `sequence` appears in `events` in this order (not necessarily adjacent). */
export const assertOrder = (events, sequence, label = 'events') => {
  let from = 0;
  for (const wanted of sequence) {
    const index = events.indexOf(wanted, from);
    assert.ok(index >= 0, `${label}: expected "${wanted}" after position ${from} in [${events.join(', ')}]`);
    from = index + 1;
  }
};

/** Asserts `before` occurs earlier than `after` in `events` (both must be present). */
export const assertBefore = (events, before, after, label = 'events') => {
  const i = events.indexOf(before);
  const j = events.indexOf(after);
  assert.ok(i >= 0, `${label}: "${before}" missing in [${events.join(', ')}]`);
  assert.ok(j >= 0, `${label}: "${after}" missing in [${events.join(', ')}]`);
  assert.ok(i < j, `${label}: expected "${before}" before "${after}" in [${events.join(', ')}]`);
};

/** Collapses consecutive duplicates (DECISIONS.md §1: repeated identical room:state need not match in count). */
export const collapseRuns = (list) => list.filter((item, index) => index === 0 || item !== list[index - 1]);

/** Re-checks `check` until it passes or `timeoutMs` elapses; the last failure is what surfaces. */
export const eventually = async (check, { timeoutMs = 4000, intervalMs = 50 } = {}) => {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      return await check();
    } catch (error) {
      if (Date.now() >= deadline) throw error;
    }
    await pause(intervalMs);
  }
};

/** A minimal HS256 JWT signer for cross-minted-token tests (no dependency). */
export const signJwt = async (claims, secret = jwtSecret) => {
  const { createHmac } = await import('node:crypto');
  const b64 = (input) => Buffer.from(typeof input === 'string' ? input : JSON.stringify(input))
    .toString('base64url');
  const header = b64({ alg: 'HS256', typ: 'JWT' });
  const payload = b64(claims);
  const signature = createHmac('sha256', secret).update(`${header}.${payload}`).digest('base64url');
  return `${header}.${payload}.${signature}`;
};

export const decodeJwt = (token) => {
  const [header, payload] = token.split('.');
  const parse = (part) => JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
  return { header: parse(header), payload: parse(payload) };
};
