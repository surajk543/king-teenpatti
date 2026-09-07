import test from 'node:test';
import assert from 'node:assert/strict';

/**
 * Prometheus metrics (requirement 35), checked end to end through a running
 * server: the `/metrics` endpoint and its bearer guard, the default process
 * collectors under the `game_server_` prefix, and every game metric the socket
 * layer, room manager and ledger feed as real players log in, sit down, bet,
 * pack and chat.
 *
 * The one rule the suite polices hardest is cardinality: no label may ever
 * carry a socket id, user id, room id, table code, raw URL or IP address —
 * the last test parses every label in the exposition and says so.
 */

// The config module snapshots the environment at import time, so everything
// this suite needs has to be set before the server is loaded. The suite gets a
// throwaway Postgres schema of its own, dropped again in test.after.
process.env.NODE_ENV = 'test';
process.env.PG_SCHEMA = `test_metrics_${Math.random().toString(36).slice(2, 8)}`;
process.env.JWT_SECRET = 'metrics-test-secret';
process.env.AUTH_ALLOW_FAKE_PROVIDERS = 'true';
process.env.WELCOME_CHIPS = '200000';
process.env.BOOT_AMOUNT = '100';
// Long enough that a hand is still live when the scrape after a move lands —
// the "active games" gauge is read mid-hand below.
process.env.TURN_TIMEOUT_MS = '4000';
process.env.NEXT_HAND_DELAY_MS = '150';
process.env.RECONNECT_GRACE_MS = '400';
process.env.PORT = '0';
// Lift the lobby's fixed stakes so each test can use its own boot amount for
// isolation — quick-join matches on stake, so a unique one keeps tests apart.
process.env.TABLE_STAKES = '';
// ...and with it the menu of category/stake pairs, for the same reason.
process.env.LOBBY_TABLES = '';
// The endpoint must demand this bearer; the first test checks that it does.
const METRICS_TOKEN = 'metrics-test-token';
process.env.METRICS_TOKEN = METRICS_TOKEN;

const { createServer } = await import('../src/index.js');
const { io: connect } = await import('socket.io-client');
const { dropSchema, closeDatabase } = await import('../src/db/index.js');

let server;
let io;
let baseUrl;
let rooms;

test.before(async () => {
  const created = await createServer();
  server = created.server;
  io = created.io;
  rooms = created.rooms;
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

test.after(async () => {
  // Live hands are settled (their pots paid out) before the pool closes.
  await rooms.shutdown();
  // Sockets have to be torn down before the HTTP server will close.
  await new Promise((resolve) => io.close(resolve));
  server.closeAllConnections?.();
  await new Promise((resolve) => server.close(resolve));
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

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ------------------------------------------------------------ game helpers

const login = async (body) => {
  const response = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return { status: response.status, body: await response.json() };
};

const guestLogin = async (deviceId, displayName) => {
  const { status, body } = await login({ provider: 'guest', deviceId, displayName });
  assert.equal(status, 200, `login for ${deviceId} failed: ${JSON.stringify(body)}`);
  return body;
};

/** Connects a socket and returns a small event-recording client. */
const openClient = async (token) => {
  const socket = connect(baseUrl, { auth: { token }, transports: ['websocket'], forceNew: true });
  const seen = [];

  for (const event of [
    'session:ready', 'room:joined', 'room:state', 'game:handStarted', 'game:turn',
    'game:yourTurn', 'game:action', 'game:showdown', 'game:handEnded', 'player:cards',
    'game:error', 'session:replaced', 'chat:message', 'chat:history',
  ]) {
    socket.on(event, (payload) => seen.push({ event, payload }));
  }

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
 * Seats two fresh players on a seen table of their own and waits for the deal.
 * Returns the clients keyed by user id, plus whoever the table says is on turn
 * — read from the live Table object, the same source the server acts on.
 */
const dealTwoPlayerHand = async (tag) => {
  const a = await guestLogin(`device-metrics-${tag}-a`, `${tag}A`);
  const b = await guestLogin(`device-metrics-${tag}-b`, `${tag}B`);
  const ca = await openClient(a.token);
  const cb = await openClient(b.token);
  const bootAmount = uniqueStake();

  const joinA = await ca.emit('room:quickJoin', { bootAmount, category: 'seen' });
  const joinB = await cb.emit('room:quickJoin', { bootAmount, category: 'seen' });
  assert.equal(joinA.ok, true, JSON.stringify(joinA));
  assert.equal(joinB.ok, true, JSON.stringify(joinB));
  assert.equal(joinA.roomId, joinB.roomId, 'quick join clusters players onto one table');

  await ca.wait('game:handStarted');

  const table = rooms.getTable(joinA.roomId);
  assert.ok(table?.hand, 'the hand is live on the server');
  const onTurnId = table.seats[table.hand.turnSeat].userId;
  const clients = { [a.user.id]: ca, [b.user.id]: cb };

  return {
    a, b, ca, cb, bootAmount, table,
    roomId: joinA.roomId,
    onTurn: clients[onTurnId],
    waiting: clients[onTurnId === a.user.id ? b.user.id : a.user.id],
  };
};

// --------------------------------------------------------- metrics helpers

const fetchMetrics = (headers = {}) => fetch(`${baseUrl}/metrics`, { headers });

const parseValue = (text) => {
  if (text === '+Inf') return Infinity;
  if (text === '-Inf') return -Infinity;
  if (text === 'Nan' || text === 'NaN') return NaN;
  return Number(text);
};

/**
 * Parses the Prometheus text exposition.
 *
 * `series` is the literal `name{labels}` → value map, label string kept as
 * printed. Label *order* is not stable across metric kinds, though — a
 * histogram prints `le` first and its own labels last — so the lookups the
 * tests use (`value`, `has`) match on a subset of labels regardless of order.
 */
const parseExposition = (text) => {
  const samples = [];
  const series = new Map();
  const types = new Map();

  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line) continue;
    if (line.startsWith('#')) {
      const typed = /^# TYPE (\S+) (\S+)$/.exec(line);
      if (typed) types.set(typed[1], typed[2]);
      continue;
    }
    const match = /^([A-Za-z_:][A-Za-z0-9_:]*)(?:\{(.*)\})?\s+(\S+)(?:\s+\S+)?$/.exec(line);
    assert.ok(match, `unparseable exposition line: ${line}`);
    const [, name, labelText = '', valueText] = match;

    const labels = {};
    for (const [, key, value] of labelText.matchAll(/([A-Za-z_][A-Za-z0-9_]*)="((?:[^"\\]|\\.)*)"/g)) {
      labels[key] = value.replace(/\\(["\\n])/g, (_, escaped) => (escaped === 'n' ? '\n' : escaped));
    }

    const value = parseValue(valueText);
    samples.push({ name, labels, value });
    series.set(labelText ? `${name}{${labelText}}` : name, value);
  }

  const matching = (name, want) => samples.filter((sample) =>
    sample.name === name
    && Object.entries(want).every(([key, value]) => sample.labels[key] === String(value)));

  return {
    text,
    samples,
    series,
    types,
    /** Sum of every sample of `name` whose labels include `want`; undefined when there is none. */
    value(name, want = {}) {
      const hits = matching(name, want);
      return hits.length > 0 ? hits.reduce((sum, hit) => sum + hit.value, 0) : undefined;
    },
    has(name, want = {}) {
      return matching(name, want).length > 0;
    },
    labelNames() {
      return new Set(samples.flatMap((sample) => Object.keys(sample.labels)));
    },
    labelValues(labelName) {
      return new Set(samples.filter((s) => labelName in s.labels).map((s) => s.labels[labelName]));
    },
  };
};

const scrape = async () => {
  const response = await fetchMetrics({ authorization: `Bearer ${METRICS_TOKEN}` });
  assert.equal(response.status, 200, 'an authorised scrape succeeds');
  return parseExposition(await response.text());
};

/**
 * Re-scrapes until `check` stops throwing. Counters are bumped on the server
 * side of an event the client has only just seen (a disconnect, a room
 * broadcast, a settled hand), so a single scrape straight after can be early.
 * On timeout the *last* assertion failure is what surfaces.
 */
const eventually = async (check, { timeoutMs = 5000, intervalMs = 60 } = {}) => {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const snapshot = await scrape();
    try {
      return check(snapshot);
    } catch (error) {
      if (Date.now() >= deadline) throw error;
    }
    await pause(intervalMs);
  }
};

const describe = (name, labels) => {
  const pairs = Object.entries(labels).map(([key, value]) => `${key}="${value}"`);
  return pairs.length > 0 ? `${name}{${pairs.join(',')}}` : name;
};

/** Asserts the (summed) sample is at least `min`, naming the series on failure. */
const atLeast = (snapshot, name, labels, min) => {
  const value = snapshot.value(name, labels);
  assert.ok(
    value !== undefined && value >= min,
    `${describe(name, labels)} is ${value}, expected at least ${min}`,
  );
  return value;
};

const present = (snapshot, name, labels = {}) => {
  assert.ok(snapshot.has(name, labels), `${describe(name, labels)} is not exported`);
};

// ----------------------------------------------------------------- endpoint

test('/metrics requires the bearer token and serves the text exposition', async () => {
  const anonymous = await fetchMetrics();
  assert.equal(anonymous.status, 401, 'no token is refused');

  const wrong = await fetchMetrics({ authorization: 'Bearer not-the-token' });
  assert.equal(wrong.status, 401, 'a wrong token is refused');

  const right = await fetchMetrics({ authorization: `Bearer ${METRICS_TOKEN}` });
  assert.equal(right.status, 200);
  assert.ok(
    (right.headers.get('content-type') ?? '').startsWith('text/plain'),
    `content-type is ${right.headers.get('content-type')}`,
  );

  const body = await right.text();
  assert.match(body, /^# HELP /m, 'the body is a Prometheus text exposition');
  assert.match(body, /^# TYPE game_connected_sockets gauge$/m);
});

// ------------------------------------------------------------- default set

const DEFAULT_METRICS = [
  'game_server_process_resident_memory_bytes',
  'game_server_nodejs_heap_size_used_bytes',
  'game_server_nodejs_heap_size_total_bytes',
  'game_server_nodejs_heap_size_limit_bytes',
  'game_server_nodejs_external_memory_bytes',
  'game_server_nodejs_array_buffers_bytes',
  'game_server_nodejs_eventloop_lag_seconds',
  'game_server_nodejs_eventloop_utilization',
  'game_server_nodejs_active_handles_total',
  'game_server_nodejs_active_requests_total',
  'game_server_process_uptime_seconds',
  'game_server_nodejs_version_info',
  'game_server_process_start_time_seconds',
  'game_server_process_cpu_user_seconds_total',
  'game_server_process_cpu_system_seconds_total',
  'game_server_process_open_fds',
];

/**
 * The GC histogram only has samples once a collection has actually run, so
 * churn enough short-lived objects through the young generation to force a
 * few scavenges. Small objects on purpose: a single huge array would land in
 * large-object space and not have the same effect.
 */
const makeGarbage = () => {
  let sink = 0;
  for (let round = 0; round < 40; round += 1) {
    const junk = Array.from({ length: 50_000 }, (_, i) => ({ i, text: `garbage ${i}` }));
    sink += junk.length;
  }
  return sink;
};

test('default process metrics are exported under the game_server_ prefix', async () => {
  const snapshot = await scrape();

  for (const name of DEFAULT_METRICS) present(snapshot, name);
  assert.equal(snapshot.types.get('game_server_nodejs_gc_duration_seconds'), 'histogram');

  // Nothing escapes the namespace: every series is either a prefixed default
  // or one of the game's own, and each carries the service label.
  for (const sample of snapshot.samples) {
    assert.ok(sample.name.startsWith('game_'), `${sample.name} is outside the game_ namespace`);
    assert.equal(sample.labels.service, 'king-teenpatti', `${sample.name} lacks the service label`);
  }

  assert.ok(snapshot.value('game_server_process_resident_memory_bytes') > 0);
  assert.ok(snapshot.value('game_server_nodejs_heap_size_used_bytes') > 0);
  assert.ok(snapshot.value('game_server_nodejs_heap_size_limit_bytes') > snapshot.value('game_server_nodejs_heap_size_used_bytes'));
  assert.ok(snapshot.value('game_server_process_uptime_seconds') > 0);
  assert.ok(snapshot.value('game_server_process_open_fds') > 0);
  const elu = snapshot.value('game_server_nodejs_eventloop_utilization');
  assert.ok(elu >= 0 && elu <= 1, `event-loop utilisation ${elu} is a fraction`);

  assert.ok(makeGarbage() > 0);
  await eventually((later) => {
    assert.ok(
      later.has('game_server_nodejs_gc_duration_seconds_bucket')
        || later.has('game_server_nodejs_gc_duration_seconds_count'),
      'gc duration has been observed at least once',
    );
    atLeast(later, 'game_server_nodejs_gc_duration_seconds_count', {}, 1);
  });
});

// ------------------------------------------------------------------ sockets

test('sockets: the live gauge follows connects and disconnects, and the totals count them', async () => {
  const before = await scrape();
  const connectedBefore = before.value('game_connected_sockets') ?? 0;
  const connectionsBefore = before.value('game_connections_total') ?? 0;
  const disconnectionsBefore = before.value('game_disconnections_total') ?? 0;

  const a = await guestLogin('device-metrics-sock-a', 'SockA');
  const b = await guestLogin('device-metrics-sock-b', 'SockB');
  const ca = await openClient(a.token);
  const cb = await openClient(b.token);

  await eventually((now) => {
    assert.equal(now.value('game_connected_sockets'), connectedBefore + 2, 'two more sockets are open');
    atLeast(now, 'game_connections_total', {}, connectionsBefore + 2);
    atLeast(now, 'game_connected_sockets_peak', {}, connectedBefore + 2);
    assert.equal(now.value('game_connected_sockets'), io.engine.clientsCount, 'the gauge agrees with the engine');
  });

  await closeAll(ca, cb);

  await eventually((now) => {
    assert.equal(now.value('game_connected_sockets'), connectedBefore, 'the gauge fell back once both closed');
    atLeast(now, 'game_disconnections_total', {}, disconnectionsBefore + 2);
    // Any reason label is fine, but it must be a fixed Socket.IO reason, not free text.
    for (const reason of now.labelValues('reason')) {
      assert.match(reason, /^[a-z][a-z _]*$/, `disconnect reason "${reason}" is not a fixed code`);
    }
  });
});

// --------------------------------------------------------------------- game

test('game: a dealt hand and its moves are counted and timed', async () => {
  const { ca, cb, onTurn, bootAmount } = await dealTwoPlayerHand('game');

  const see = await onTurn.emit('game:action', { action: 'see' });
  assert.equal(see.ok, true, JSON.stringify(see));
  const chaal = await onTurn.emit('game:action', { action: 'chaal' });
  assert.equal(chaal.ok, true, JSON.stringify(chaal));

  await eventually((m) => {
    // Gauges are computed from the live tables at scrape time.
    atLeast(m, 'game_players_online', {}, 2);
    atLeast(m, 'game_active_games', {}, 1);
    atLeast(m, 'game_tables', { category: 'seen', stake: String(bootAmount) }, 1);

    atLeast(m, 'game_games_started_total', { category: 'seen' }, 1);
    atLeast(m, 'game_moves_total', { action: 'see' }, 1);
    atLeast(m, 'game_moves_total', { action: 'chaal' }, 1);
    atLeast(m, 'game_socket_messages_total', { event: 'game:action' }, 2);
    atLeast(m, 'game_socket_messages_total', { event: 'room:quickJoin' }, 2);

    atLeast(m, 'game_move_processing_duration_seconds_bucket', { action: 'chaal', le: '+Inf' }, 1);
    present(m, 'game_move_processing_duration_seconds_bucket', { action: 'chaal', le: '1' });
    atLeast(m, 'game_move_processing_duration_seconds_count', { action: 'see' }, 1);

    atLeast(m, 'game_state_update_duration_seconds_count', {}, 1);
    atLeast(m, 'game_join_duration_seconds_count', { route: 'quick_join' }, 2);
    atLeast(m, 'game_creation_duration_seconds_count', {}, 1);
    atLeast(m, 'game_hand_start_duration_seconds_count', {}, 1);
    atLeast(m, 'game_db_transaction_duration_seconds_count', { op: 'boot' }, 1);
    atLeast(m, 'game_db_transaction_duration_seconds_count', { op: 'bet' }, 1);

    // A latency histogram whose sum is zero was never really observed.
    assert.ok(m.value('game_move_processing_duration_seconds_sum', { action: 'chaal' }) > 0);
    assert.ok(m.value('game_db_transaction_duration_seconds_sum', { op: 'bet' }) > 0);
  });

  await closeAll(ca, cb);
});

test('invalid moves are counted by refusal code', async () => {
  const { ca, cb, waiting } = await dealTwoPlayerHand('invalid');

  const before = await scrape();
  const validBefore = before.value('game_moves_total') ?? 0;

  const outOfTurn = await waiting.emit('game:action', { action: 'chaal' });
  assert.equal(outOfTurn.ok, false);
  assert.equal(outOfTurn.code, 'not_your_turn');

  const unknown = await waiting.emit('game:action', { action: 'teleport' });
  assert.equal(unknown.ok, false);
  assert.equal(unknown.code, 'unknown_action');

  await eventually((m) => {
    atLeast(m, 'game_invalid_moves_total', { code: 'not_your_turn' }, 1);
    atLeast(m, 'game_socket_errors_total', { code: 'not_your_turn' }, 1);
    atLeast(m, 'game_socket_errors_total', { code: 'unknown_action' }, 1);
    atLeast(m, 'game_invalid_moves_total', { code: 'unknown_action' }, 1);
    atLeast(m, 'game_socket_emits_total', { event: 'game:error' }, 2);
    // The refusals were not counted as accepted moves.
    assert.equal(m.value('game_moves_total') ?? 0, validBefore);
    // And the raw action name never became a label.
    assert.ok(!m.labelValues('action').has('teleport'), 'an unknown action is not a label value');
  });

  await closeAll(ca, cb);
});

test('a completed hand is counted with its reason, and the pot it paid out', async () => {
  const { ca, cb, onTurn, bootAmount } = await dealTwoPlayerHand('complete');

  const before = await scrape();
  const settledBefore = before.value('game_pot_settled_chips_total') ?? 0;

  const packed = await onTurn.emit('game:action', { action: 'pack' });
  assert.equal(packed.ok, true, JSON.stringify(packed));

  const ended = await ca.wait('game:handEnded');
  assert.equal(ended.reason, 'last_standing');
  assert.equal(ended.pot, bootAmount * 2, 'two boots were in the pot');
  assert.ok(ended.winnerId);

  await eventually((m) => {
    atLeast(m, 'game_games_completed_total', { category: 'seen', reason: 'last_standing' }, 1);
    atLeast(m, 'game_pot_settled_chips_total', {}, settledBefore + ended.pot);
    atLeast(m, 'game_socket_emits_total', { event: 'game:handEnded' }, 1);
    atLeast(m, 'game_moves_total', { action: 'pack' }, 1);
    atLeast(m, 'game_settlement_duration_seconds_count', {}, 1);
  });

  await closeAll(ca, cb);
});

// --------------------------------------------------------------------- HTTP

test('http: requests are counted by route pattern, never by raw path', async () => {
  const { token } = await guestLogin('device-metrics-http', 'Http');
  const auth = { authorization: `Bearer ${token}` };

  assert.equal((await fetch(`${baseUrl}/api/auth/me`, { headers: auth })).status, 200);
  assert.equal((await fetch(`${baseUrl}/health`)).status, 200);
  assert.equal((await fetch(`${baseUrl}/api/auth/me/hands?limit=3`, { headers: auth })).status, 200);
  assert.equal((await fetch(`${baseUrl}/nothing-here-123`)).status, 404);

  await eventually((m) => {
    atLeast(m, 'game_http_requests_total', { method: 'POST', route: '/api/auth/login', status_code: '200' }, 1);
    atLeast(m, 'game_http_requests_total', { method: 'GET', route: '/api/auth/me', status_code: '200' }, 1);
    atLeast(m, 'game_http_requests_total', { method: 'GET', route: '/health', status_code: '200' }, 1);
    atLeast(m, 'game_http_requests_total', { method: 'GET', route: '/api/auth/me/hands', status_code: '200' }, 1);
    atLeast(m, 'game_http_requests_total', { method: 'GET', route: 'unmatched', status_code: '404' }, 1);

    atLeast(m, 'game_http_request_duration_seconds_bucket', { route: '/health', le: '+Inf' }, 1);
    atLeast(m, 'game_http_request_duration_seconds_count', { route: '/health' }, 1);

    const routes = m.labelValues('route');
    assert.ok(!routes.has('/nothing-here-123'), 'a 404 path is never a route label');
    for (const route of routes) {
      assert.ok(!route.includes('?') && !route.includes('limit='), `route "${route}" carries a query string`);
      assert.ok(!/\/\d+(\/|$)/.test(route), `route "${route}" carries a numeric id`);
    }
    // The scrape itself is not counted as traffic.
    assert.ok(!m.has('game_http_requests_total', { route: '/metrics' }), 'scrapes are excluded from HTTP metrics');
  });
});

// --------------------------------------------------------------------- chat

test('chat: a posted message is counted and its broadcast recorded', async () => {
  const a = await guestLogin('device-metrics-chat-a', 'ChatA');
  const b = await guestLogin('device-metrics-chat-b', 'ChatB');
  const ca = await openClient(a.token);
  const cb = await openClient(b.token);
  const bootAmount = uniqueStake();
  await ca.emit('room:quickJoin', { bootAmount });
  await cb.emit('room:quickJoin', { bootAmount });

  const before = await scrape();
  const chatBefore = before.value('game_chat_messages_total') ?? 0;

  const posted = await ca.emit('chat:message', { text: 'good luck all' });
  assert.equal(posted.ok, true);
  assert.ok(posted.messageId);
  await cb.wait('chat:message', (payload) => payload.text === 'good luck all');

  await eventually((m) => {
    atLeast(m, 'game_chat_messages_total', {}, Math.max(1, chatBefore + 1));
    atLeast(m, 'game_socket_emits_total', { event: 'chat:message' }, 1);
    atLeast(m, 'game_socket_messages_total', { event: 'chat:message' }, 1);
  });

  await closeAll(ca, cb);
});

// -------------------------------------------------------------- cardinality

// Last on purpose: by now the exposition carries every kind of label the
// earlier tests could provoke — codes, events, categories, routes, reasons.
test('cardinality: no label carries an identifier, address or raw path', async () => {
  const m = await scrape();

  assert.ok(
    m.samples.some((s) => s.name.startsWith('game_') && Object.keys(s.labels).length > 1),
    'the exposition has labelled game series to inspect',
  );

  const FORBIDDEN_LABEL_NAMES = ['socket_id', 'user_id', 'room_id', 'code_', 'ip', 'url', 'path', 'device_id'];
  for (const name of m.labelNames()) {
    for (const forbidden of FORBIDDEN_LABEL_NAMES) {
      assert.notEqual(name, forbidden, `label name "${name}" is forbidden`);
    }
    assert.ok(!/_id$/.test(name), `label name "${name}" is an identifier`);
    assert.ok(!/^code_/.test(name), `label name "${name}" looks like a table code`);
  }

  const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;
  const IPV4 = /\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/;
  const IPV6 = /^[0-9a-f.:]+$/i;
  const SHA256 = /^[0-9a-f]{64}$/i;

  for (const sample of m.samples) {
    for (const [name, value] of Object.entries(sample.labels)) {
      const where = `${sample.name} ${name}="${value}"`;
      assert.ok(!UUID.test(value), `${where} contains a UUID`);
      assert.ok(!IPV4.test(value), `${where} looks like an IPv4 address`);
      assert.ok(!(IPV6.test(value) && (value.match(/:/g) ?? []).length >= 2), `${where} looks like an IPv6 address`);
      assert.ok(!SHA256.test(value), `${where} is a hashed device id`);
    }
  }

  // The label sets themselves are small and fixed in shape.
  for (const code of m.labelValues('code')) {
    assert.match(code, /^[a-z][a-z0-9_]*$/, `code "${code}" is not a snake_case error code`);
  }
  for (const event of m.labelValues('event')) {
    assert.match(event, /^[a-z]+:[a-zA-Z]+$/, `event "${event}" is not a wire event name`);
  }
  for (const category of m.labelValues('category')) {
    assert.ok(['seen', 'blind', 'other'].includes(category), `category "${category}" is not fixed`);
  }
  for (const method of m.labelValues('method')) {
    assert.match(method, /^[A-Z]+$/, `method "${method}" is not an HTTP verb`);
  }
});
