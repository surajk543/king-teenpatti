/**
 * Prometheus metrics parity (metrics.test.js, the portable parts): the
 * /metrics guard (401 for a bad or missing bearer, 403 for a peer outside
 * METRICS_ALLOW_IPS), the exposition format, the `game_` namespace and the
 * `service` label on every series, `game_server_process_*`, and every game
 * metric the socket layer, room manager and ledger feed — names, types, labels
 * and histogram buckets identical (DECISIONS.md §6). The Node runtime series
 * (`game_server_nodejs_*`) are Node-only and are not asserted here; the Go
 * runtime's own series are not asserted either. The cardinality rule is
 * policed on whatever the server exposes.
 *
 * Profile assumptions (tools/parity.mjs "metrics"): TURN_TIMEOUT_MS 4000 (a
 * hand is still live when the scrape after a move lands), METRICS_TOKEN set,
 * METRICS_ALLOW_IPS=127.0.0.1 (so a client bound to 127.0.0.2 is refused).
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {
  baseUrl, guestLogin, openClient, closeAll, closeOpenClients, stakeCounter, dealtTable, metricsToken, pause, health,
} from './lib/harness.mjs';

test.after(closeOpenClients);

const uniqueStake = stakeCounter(100);
const allowIps = (process.env.PARITY_METRICS_ALLOW_IPS ?? '').split(',').map((s) => s.trim()).filter(Boolean);

// --------------------------------------------------------- metrics helpers

const fetchMetrics = (headers = {}) => fetch(`${baseUrl}/metrics`, { headers });

/** GET /metrics from a chosen local source address (127.0.0.0/8 is all loopback on Linux). */
const fetchMetricsFrom = (localAddress, headers = {}) => new Promise((resolve, reject) => {
  const url = new URL(`${baseUrl}/metrics`);
  const request = http.request({
    host: url.hostname, port: url.port, path: url.pathname, method: 'GET', headers, localAddress,
  }, (response) => {
    let body = '';
    response.on('data', (chunk) => { body += chunk; });
    response.on('end', () => resolve({ status: response.statusCode, body, headers: response.headers }));
  });
  request.on('error', reject);
  request.end();
});

const parseValue = (text) => {
  if (text === '+Inf') return Infinity;
  if (text === '-Inf') return -Infinity;
  if (text === 'Nan' || text === 'NaN') return NaN;
  return Number(text);
};

/** Parses the Prometheus text exposition (label order is not significant). */
const parseExposition = (text) => {
  const samples = [];
  const types = new Map();
  const helps = new Map();
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line) continue;
    if (line.startsWith('#')) {
      const typed = /^# TYPE (\S+) (\S+)$/.exec(line);
      if (typed) types.set(typed[1], typed[2]);
      const help = /^# HELP (\S+) (.*)$/.exec(line);
      if (help) helps.set(help[1], help[2]);
      continue;
    }
    const match = /^([A-Za-z_:][A-Za-z0-9_:]*)(?:\{(.*)\})?\s+(\S+)(?:\s+\S+)?$/.exec(line);
    assert.ok(match, `unparseable exposition line: ${line}`);
    const [, name, labelText = '', valueText] = match;
    const labels = {};
    for (const [, key, value] of labelText.matchAll(/([A-Za-z_][A-Za-z0-9_]*)="((?:[^"\\]|\\.)*)"/g)) {
      labels[key] = value.replace(/\\(["\\n])/g, (_, escaped) => (escaped === 'n' ? '\n' : escaped));
    }
    samples.push({ name, labels, value: parseValue(valueText) });
  }
  const matching = (name, want) => samples.filter((sample) =>
    sample.name === name && Object.entries(want).every(([key, value]) => sample.labels[key] === String(value)));
  return {
    text,
    samples,
    types,
    helps,
    value(name, want = {}) {
      const hits = matching(name, want);
      return hits.length > 0 ? hits.reduce((total, hit) => total + hit.value, 0) : undefined;
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
    /** Label names (other than service) used by series of this metric. */
    labelsOf(name) {
      return [...new Set(samples.filter((s) => s.name === name).flatMap((s) => Object.keys(s.labels)))].filter((l) => l !== 'service').sort();
    },
  };
};

const scrape = async () => {
  const response = await fetchMetrics({ authorization: `Bearer ${metricsToken}` });
  assert.equal(response.status, 200, 'an authorised scrape succeeds');
  return parseExposition(await response.text());
};

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

const atLeast = (snapshot, name, labels, min) => {
  const value = snapshot.value(name, labels);
  assert.ok(value !== undefined && value >= min, `${describe(name, labels)} is ${value}, expected at least ${min}`);
  return value;
};

const present = (snapshot, name, labels = {}) => {
  assert.ok(snapshot.has(name, labels), `${describe(name, labels)} is not exported`);
};

const BUCKETS = ['0.001', '0.005', '0.01', '0.025', '0.05', '0.1', '0.25', '0.5', '1', '+Inf'];

// ----------------------------------------------------------------- endpoint

test('/metrics requires the bearer token (401), refuses peers outside METRICS_ALLOW_IPS (403), and serves the text exposition', async () => {
  const anonymous = await fetchMetrics();
  assert.equal(anonymous.status, 401, 'no token is refused');
  assert.equal(await anonymous.text(), 'unauthorized');
  const wrong = await fetchMetrics({ authorization: 'Bearer not-the-token' });
  assert.equal(wrong.status, 401, 'a wrong token is refused');
  const lower = await fetchMetrics({ authorization: `bearer ${metricsToken}` });
  assert.equal(lower.status, 401, 'the scheme is matched exactly');

  if (allowIps.length > 0 && !allowIps.includes('127.0.0.2')) {
    const foreign = await fetchMetricsFrom('127.0.0.2', { authorization: `Bearer ${metricsToken}` });
    assert.equal(foreign.status, 403, 'a peer outside the allow-list is forbidden even with the token');
    assert.equal(foreign.body, 'forbidden');
    const foreignNoToken = await fetchMetricsFrom('127.0.0.2');
    assert.equal(foreignNoToken.status, 403, 'the IP check comes before the token check');
  }

  const right = await fetchMetrics({ authorization: `Bearer ${metricsToken}` });
  assert.equal(right.status, 200);
  assert.ok((right.headers.get('content-type') ?? '').startsWith('text/plain'), `content-type is ${right.headers.get('content-type')}`);
  const body = await right.text();
  assert.match(body, /^# HELP /m, 'the body is a Prometheus text exposition');
  assert.match(body, /^# TYPE game_connected_sockets gauge$/m);
});

// ------------------------------------------------------------- default set

test('everything lives under game_ with the service label; the process collectors carry the game_server_ prefix', async () => {
  const snapshot = await scrape();
  for (const sample of snapshot.samples) {
    assert.ok(sample.name.startsWith('game_'), `${sample.name} is outside the game_ namespace`);
    assert.equal(sample.labels.service, 'king-teenpatti', `${sample.name} lacks the service label`);
  }
  for (const name of [
    'game_server_process_resident_memory_bytes',
    'game_server_process_uptime_seconds',
    'game_server_process_start_time_seconds',
    'game_server_process_cpu_user_seconds_total',
    'game_server_process_cpu_system_seconds_total',
    'game_server_process_open_fds',
  ]) present(snapshot, name);
  assert.ok(snapshot.value('game_server_process_resident_memory_bytes') > 0);
  assert.ok(snapshot.value('game_server_process_uptime_seconds') > 0);
  assert.ok(snapshot.value('game_server_process_open_fds') > 0);
  assert.ok(Math.abs(snapshot.value('game_server_process_start_time_seconds') - Date.now() / 1000) < 3600);
  assert.equal(snapshot.types.get('game_server_process_uptime_seconds'), 'gauge');
  assert.equal(snapshot.types.get('game_server_process_cpu_user_seconds_total'), 'counter');
});

test('the game metric catalogue: names, types, labels and buckets', async () => {
  // Make sure every kind has been touched once so all series are present.
  const { clients, onTurn } = await dealtTable('catalogue', uniqueStake, { category: 'seen', names: ['CatA', 'CatB'], deviceTag: 'metrics-catalogue' });
  await onTurn.emit('game:action', { action: 'see' });
  await onTurn.emit('game:action', { action: 'chaal' });
  await onTurn.emit('game:action', { action: 'teleport' });
  await clients[0].emit('chat:message', { text: 'gg' });
  await closeAll(...clients);

  await eventually((m) => {
    const expectType = (name, type) => assert.equal(m.types.get(name), type, `# TYPE ${name}`);
    const expectLabels = (name, labels) => assert.deepEqual(m.labelsOf(name), labels.sort(), `labels of ${name}`);

    expectType('game_connected_sockets', 'gauge');
    expectType('game_connected_sockets_peak', 'gauge');
    expectType('game_connections_total', 'counter');
    expectType('game_disconnections_total', 'counter'); expectLabels('game_disconnections_total', ['reason']);
    expectType('game_reconnects_total', 'counter');
    expectType('game_socket_errors_total', 'counter'); expectLabels('game_socket_errors_total', ['code']);
    expectType('game_socket_messages_total', 'counter'); expectLabels('game_socket_messages_total', ['event']);
    expectType('game_socket_emits_total', 'counter'); expectLabels('game_socket_emits_total', ['event']);
    expectType('game_session_replaced_total', 'counter');
    expectType('game_players_online', 'gauge');
    expectType('game_active_games', 'gauge');
    expectType('game_waiting_games', 'gauge');
    expectType('game_tables', 'gauge'); // labelled series exist only while a table is live (see the game test)
    expectType('game_games_started_total', 'counter'); expectLabels('game_games_started_total', ['category']);
    expectType('game_games_completed_total', 'counter');
    expectType('game_games_abandoned_total', 'counter');
    expectType('game_moves_total', 'counter'); expectLabels('game_moves_total', ['action']);
    expectType('game_invalid_moves_total', 'counter'); expectLabels('game_invalid_moves_total', ['code']);
    expectType('game_turn_timeouts_total', 'counter');
    expectType('game_kicks_total', 'counter');
    expectType('game_chat_messages_total', 'counter');
    expectType('game_pot_settled_chips_total', 'counter');
    for (const [name, labels] of [
      ['game_move_processing_duration_seconds', ['action']],
      ['game_creation_duration_seconds', []],
      ['game_join_duration_seconds', ['route']],
      ['game_state_update_duration_seconds', []],
      ['game_hand_start_duration_seconds', []],
      ['game_settlement_duration_seconds', []],
      ['game_db_transaction_duration_seconds', ['op']],
      ['game_http_request_duration_seconds', ['method', 'route', 'status_code']],
    ]) {
      expectType(name, 'histogram');
      const buckets = [...new Set(m.samples.filter((s) => s.name === `${name}_bucket`).map((s) => s.labels.le))];
      assert.deepEqual(buckets.sort(), [...BUCKETS].sort(), `buckets of ${name}`);
      assert.deepEqual(m.labelsOf(`${name}_count`), labels.sort(), `labels of ${name}`);
    }
    expectType('game_db_transaction_errors_total', 'counter');
    expectType('game_db_pool_connections', 'gauge');
    expectType('game_db_pool_idle_connections', 'gauge');
    expectType('game_db_pool_waiting_requests', 'gauge');
    expectType('game_http_requests_total', 'counter'); expectLabels('game_http_requests_total', ['method', 'route', 'status_code']);
    assert.ok(m.helps.get('game_connected_sockets')?.length > 0, 'every metric has help text');
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

  await eventually(async (now) => {
    assert.equal(now.value('game_connected_sockets'), connectedBefore + 2, 'two more sockets are open');
    atLeast(now, 'game_connections_total', {}, connectionsBefore + 2);
    atLeast(now, 'game_connected_sockets_peak', {}, connectedBefore + 2);
  });
  // The gauge agrees with /health (the substitute for peeking at the engine).
  assert.equal((await health()).sockets, (await scrape()).value('game_connected_sockets'));

  await closeAll(ca, cb);

  await eventually((now) => {
    assert.equal(now.value('game_connected_sockets'), connectedBefore, 'the gauge fell back once both closed');
    atLeast(now, 'game_disconnections_total', {}, disconnectionsBefore + 2);
    for (const reason of now.labelValues('reason')) {
      assert.match(reason, /^[a-z][a-z _]*$/, `disconnect reason "${reason}" is not a fixed code`);
    }
  });
});

test('a replaced session is counted, and a reconnect inside the grace is a seat_held reconnect', async () => {
  const before = await scrape();
  const replacedBefore = before.value('game_session_replaced_total') ?? 0;
  const heldBefore = before.value('game_reconnects_total', { kind: 'seat_held' }) ?? 0;
  const account = await guestLogin('device-metrics-replace', 'Replace');
  const first = await openClient(account.token);
  await first.emit('room:quickJoin', { bootAmount: uniqueStake() });
  const second = await openClient(account.token);
  await first.wait('session:replaced');
  await second.wait('room:joined');
  await eventually((m) => {
    atLeast(m, 'game_session_replaced_total', {}, replacedBefore + 1);
  });
  second.drop();
  await pause(50);
  const third = await openClient(account.token);
  await third.wait('room:joined');
  await eventually((m) => {
    atLeast(m, 'game_reconnects_total', { kind: 'seat_held' }, heldBefore + 1);
  });
  first.drop();
  await third.close();
});

// --------------------------------------------------------------------- game

test('game: a dealt hand and its moves are counted and timed', async () => {
  const { clients, onTurn, bootAmount } = await dealtTable('game', uniqueStake, { category: 'seen', names: ['gameA', 'gameB'], deviceTag: 'metrics-game' });

  const see = await onTurn.emit('game:action', { action: 'see' });
  assert.equal(see.ok, true, JSON.stringify(see));
  const chaal = await onTurn.emit('game:action', { action: 'chaal' });
  assert.equal(chaal.ok, true, JSON.stringify(chaal));

  await eventually((m) => {
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

    assert.ok(m.value('game_move_processing_duration_seconds_sum', { action: 'chaal' }) > 0);
    assert.ok(m.value('game_db_transaction_duration_seconds_sum', { op: 'bet' }) > 0);
    atLeast(m, 'game_socket_emits_total', { event: 'room:state' }, 1);
    atLeast(m, 'game_socket_emits_total', { event: 'game:handStarted' }, 1);
    atLeast(m, 'game_socket_emits_total', { event: 'player:hand' }, 1);
    atLeast(m, 'game_socket_emits_total', { event: 'game:yourTurn' }, 1);
    atLeast(m, 'game_socket_emits_total', { event: 'player:cards' }, 1);
    atLeast(m, 'game_db_pool_connections', {}, 1);
  });

  await closeAll(...clients);
});

test('invalid moves are counted by refusal code', async () => {
  const { clients, waiting } = await dealtTable('invalid', uniqueStake, { category: 'seen', names: ['invA', 'invB'], deviceTag: 'metrics-invalid' });
  const before = await scrape();
  const validBefore = before.value('game_moves_total') ?? 0;

  const outOfTurn = await waiting.emit('game:action', { action: 'chaal' });
  assert.equal(outOfTurn.code, 'not_your_turn');
  const unknown = await waiting.emit('game:action', { action: 'teleport' });
  assert.equal(unknown.code, 'unknown_action');

  await eventually((m) => {
    atLeast(m, 'game_invalid_moves_total', { code: 'not_your_turn' }, 1);
    atLeast(m, 'game_socket_errors_total', { code: 'not_your_turn' }, 1);
    atLeast(m, 'game_socket_errors_total', { code: 'unknown_action' }, 1);
    atLeast(m, 'game_invalid_moves_total', { code: 'unknown_action' }, 1);
    atLeast(m, 'game_socket_emits_total', { event: 'game:error' }, 2);
    assert.equal(m.value('game_moves_total') ?? 0, validBefore);
    assert.ok(!m.labelValues('action').has('teleport'), 'an unknown action is not a label value');
  });
  await closeAll(...clients);
});

test('a completed hand is counted with its reason, and the pot it paid out; a turn timeout is counted too', async () => {
  const { clients, onTurn, bootAmount } = await dealtTable('complete', uniqueStake, { category: 'seen', names: ['cmpA', 'cmpB'], deviceTag: 'metrics-complete' });
  const ca = clients[0];
  const before = await scrape();
  const settledBefore = before.value('game_pot_settled_chips_total') ?? 0;
  const timeoutsBefore = before.value('game_turn_timeouts_total') ?? 0;

  const packed = await onTurn.emit('game:action', { action: 'pack' });
  assert.equal(packed.ok, true, JSON.stringify(packed));
  const ended = await ca.wait('game:handEnded');
  assert.equal(ended.reason, 'last_standing');
  assert.equal(ended.pot, bootAmount * 2);

  await eventually((m) => {
    atLeast(m, 'game_games_completed_total', { category: 'seen', reason: 'last_standing' }, 1);
    atLeast(m, 'game_pot_settled_chips_total', {}, settledBefore + ended.pot);
    atLeast(m, 'game_socket_emits_total', { event: 'game:handEnded' }, 1);
    atLeast(m, 'game_moves_total', { action: 'pack' }, 1);
    atLeast(m, 'game_settlement_duration_seconds_count', {}, 1);
    atLeast(m, 'game_db_transaction_duration_seconds_count', { op: 'settle' }, 1);
  });

  // Hand 2: nobody acts, so the player on turn is packed by the clock.
  await ca.wait('game:handEnded', (e) => e.handNo === 2, 12000);
  await eventually((m) => {
    atLeast(m, 'game_turn_timeouts_total', {}, timeoutsBefore + 1);
  });
  await closeAll(...clients);
});

test('a sixth-player table, a code join and a private create feed the join histogram by route', async () => {
  const host = await guestLogin('device-metrics-routes-host', 'RouteHost');
  const guest = await guestLogin('device-metrics-routes-guest', 'RouteGuest');
  const ch = await openClient(host.token);
  const cg = await openClient(guest.token);
  const created = await ch.emit('room:create', { isPrivate: true });
  assert.equal(created.ok, true);
  assert.equal((await cg.emit('room:joinCode', { code: created.code })).ok, true);
  await eventually((m) => {
    atLeast(m, 'game_join_duration_seconds_count', { route: 'create' }, 1);
    atLeast(m, 'game_join_duration_seconds_count', { route: 'code' }, 1);
    atLeast(m, 'game_socket_messages_total', { event: 'room:create' }, 1);
    atLeast(m, 'game_socket_messages_total', { event: 'room:joinCode' }, 1);
    atLeast(m, 'game_socket_emits_total', { event: 'chat:history' }, 2);
  });
  await closeAll(ch, cg);
});

// --------------------------------------------------------------------- HTTP

test('http: requests are counted by route pattern, never by raw path', async () => {
  const { token } = await guestLogin('device-metrics-http', 'Http');
  const auth = { authorization: `Bearer ${token}` };

  assert.equal((await fetch(`${baseUrl}/api/auth/me`, { headers: auth })).status, 200);
  assert.equal((await fetch(`${baseUrl}/health`)).status, 200);
  assert.equal((await fetch(`${baseUrl}/api/auth/me/hands?limit=3`, { headers: auth })).status, 200);
  assert.equal((await fetch(`${baseUrl}/nothing-here-123`)).status, 404);
  assert.equal((await fetch(`${baseUrl}/profiles/bear.svg`)).status, 200);

  await eventually((m) => {
    atLeast(m, 'game_http_requests_total', { method: 'POST', route: '/api/auth/login', status_code: '200' }, 1);
    atLeast(m, 'game_http_requests_total', { method: 'GET', route: '/api/auth/me', status_code: '200' }, 1);
    atLeast(m, 'game_http_requests_total', { method: 'GET', route: '/health', status_code: '200' }, 1);
    atLeast(m, 'game_http_requests_total', { method: 'GET', route: '/api/auth/me/hands', status_code: '200' }, 1);
    atLeast(m, 'game_http_requests_total', { method: 'GET', route: 'unmatched', status_code: '404' }, 1);
    atLeast(m, 'game_http_requests_total', { method: 'GET', route: 'static', status_code: '200' }, 1);

    atLeast(m, 'game_http_request_duration_seconds_bucket', { route: '/health', le: '+Inf' }, 1);
    atLeast(m, 'game_http_request_duration_seconds_count', { route: '/health' }, 1);

    const routes = m.labelValues('route');
    assert.ok(!routes.has('/nothing-here-123'), 'a 404 path is never a route label');
    assert.ok(!routes.has('/profiles/bear.svg'), 'a static file path is never a route label');
    for (const route of routes) {
      assert.ok(!route.includes('?') && !route.includes('limit='), `route "${route}" carries a query string`);
      assert.ok(!/\/\d+(\/|$)/.test(route), `route "${route}" carries a numeric id`);
    }
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

test('cardinality: no label carries an identifier, address or raw path', async () => {
  const m = await scrape();
  assert.ok(m.samples.some((s) => s.name.startsWith('game_') && Object.keys(s.labels).length > 1), 'the exposition has labelled game series to inspect');

  const FORBIDDEN_LABEL_NAMES = ['socket_id', 'user_id', 'room_id', 'code_', 'ip', 'url', 'path', 'device_id'];
  for (const name of m.labelNames()) {
    for (const forbidden of FORBIDDEN_LABEL_NAMES) assert.notEqual(name, forbidden, `label name "${name}" is forbidden`);
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
  // The label vocabularies of the game's own series are small and fixed. (The
  // runtime collectors under game_server_ have their own labels, e.g. GC kind.)
  const gameValues = (labelName) => new Set(m.samples
    .filter((s) => !s.name.startsWith('game_server_') && labelName in s.labels)
    .map((s) => s.labels[labelName]));
  for (const code of gameValues('code')) assert.match(code, /^[a-z][a-z0-9_]*$/, `code "${code}" is not a snake_case error code`);
  for (const event of gameValues('event')) assert.match(event, /^[a-z]+:[a-zA-Z]+$/, `event "${event}" is not a wire event name`);
  for (const category of gameValues('category')) assert.ok(['seen', 'blind', 'other'].includes(category), `category "${category}" is not fixed`);
  for (const method of gameValues('method')) assert.match(method, /^[A-Z]+$/, `method "${method}" is not an HTTP verb`);
  for (const action of gameValues('action')) assert.ok(['see', 'chaal', 'raise', 'pack', 'show', 'sideshow', 'other'].includes(action), `action "${action}"`);
  for (const route of gameValues('route')) assert.match(route, /^(\/[a-z/]+|static|unmatched|quick_join|code|create|switch|resume)$/, `route "${route}"`);
  // `op` names a database transaction (bet|boot|settle) or a live-store call
  // (LIVE_STATE_PLAN.md). Both are fixed vocabularies of method names — the
  // point of the check is that no identifier can ever appear here.
  const DB_OPS = ['bet', 'boot', 'settle'];
  const LIVE_OPS = ['save_table', 'load_table', 'delete_table', 'list_tables', 'count_tables', 'list_summaries', 'list_seats', 'append_chat', 'load_chat',
    'delete_chat', 'set_seated', 'clear_seated', 'seat_of', 'set_online', 'set_offline', 'online_count',
    'put_resume_offer', 'take_resume_offer', 'delete_resume_offer', 'publish_table', 'retire_table',
    'candidates', 'ping', 'close', 'other'];
  for (const op of gameValues('op')) assert.ok([...DB_OPS, ...LIVE_OPS].includes(op), `op "${op}" is outside the fixed vocabulary`);
  for (const kind of gameValues('kind')) assert.ok(['seat_held', 'offer'].includes(kind), `kind "${kind}"`);
  for (const reason of gameValues('reason')) assert.match(reason, /^[a-z][a-z _]*$/, `reason "${reason}"`);
  for (const stake of gameValues('stake')) assert.match(stake, /^\d+$/, `stake "${stake}"`);
});
