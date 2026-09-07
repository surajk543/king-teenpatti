/**
 * Prometheus metrics for the game server (Requirement 35).
 *
 * One registry, exposed on `/metrics`. Everything the process knows about
 * itself comes from prom-client's default collectors under the prefix
 * `game_server_`; everything about the game — sockets, tables, moves, the
 * latency of the operations that matter — is a named metric under `game_`.
 *
 * Label discipline: every label here has a small, fixed set of values (an
 * event name, an action, a route pattern, a status code, a reason code). No
 * label ever carries a socket id, a user id, a room id, a raw URL or an IP
 * address — each of those would give Prometheus a fresh time series per
 * player and eat its memory. `safeLabel()` is the last line of defence: a
 * value outside the known set is folded into "other".
 */
import { performance } from 'node:perf_hooks';
import v8 from 'node:v8';
import client from 'prom-client';
import config from '../config/index.js';

export const registry = new client.Registry();
registry.setDefaultLabels({ service: 'king-teenpatti' });

const PREFIX = config.metrics.prefix;

// ---------------------------------------------------------------- defaults

client.collectDefaultMetrics({
  register: registry,
  prefix: PREFIX,
  // Lag is sampled often enough to catch a stall between two scrapes.
  eventLoopMonitoringPrecision: 10,
  gcDurationBuckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1],
});

// The few process facts the default set leaves out.
new client.Gauge({
  name: `${PREFIX}nodejs_heap_size_limit_bytes`,
  help: 'V8 heap size limit in bytes (the point at which the process dies of memory).',
  registers: [registry],
  collect() {
    this.set(v8.getHeapStatistics().heap_size_limit);
  },
});
new client.Gauge({
  name: `${PREFIX}nodejs_array_buffers_bytes`,
  help: 'Memory allocated for ArrayBuffers and SharedArrayBuffers, in bytes.',
  registers: [registry],
  collect() {
    this.set(process.memoryUsage().arrayBuffers);
  },
});
new client.Gauge({
  name: `${PREFIX}process_uptime_seconds`,
  help: 'Seconds since the process started.',
  registers: [registry],
  collect() {
    this.set(process.uptime());
  },
});

// Event-loop utilisation over the interval since the previous scrape: 0 is
// idle, 1 is a loop that never waits. Kept per-scrape rather than cumulative
// so a Grafana panel can show it without a rate() over a ratio.
let lastElu = performance.eventLoopUtilization();
new client.Gauge({
  name: `${PREFIX}nodejs_eventloop_utilization`,
  help: 'Fraction of time the event loop was busy since the previous scrape (0 idle – 1 saturated).',
  registers: [registry],
  collect() {
    const now = performance.eventLoopUtilization();
    const delta = performance.eventLoopUtilization(now, lastElu);
    lastElu = now;
    this.set(Number.isFinite(delta.utilization) ? delta.utilization : 0);
  },
});

// ----------------------------------------------------------------- sockets

export const connectedSockets = new client.Gauge({
  name: 'game_connected_sockets',
  help: 'Socket.IO connections open right now.',
  registers: [registry],
});
export const peakConnectedSockets = new client.Gauge({
  name: 'game_connected_sockets_peak',
  help: 'Highest number of Socket.IO connections open at once since the process started.',
  registers: [registry],
});
export const connectionsTotal = new client.Counter({
  name: 'game_connections_total',
  help: 'Socket.IO connections accepted since the process started.',
  registers: [registry],
});
export const disconnectionsTotal = new client.Counter({
  name: 'game_disconnections_total',
  help: 'Socket.IO disconnections since the process started, by Socket.IO reason.',
  labelNames: ['reason'],
  registers: [registry],
});
export const reconnectsTotal = new client.Counter({
  name: 'game_reconnects_total',
  help: 'Connections from a player whose seat was still being held after a drop, or who was offered their table back.',
  labelNames: ['kind'],
  registers: [registry],
});
export const socketErrorsTotal = new client.Counter({
  name: 'game_socket_errors_total',
  help: 'Requests refused on the socket, by error code.',
  labelNames: ['code'],
  registers: [registry],
});
export const socketMessagesTotal = new client.Counter({
  name: 'game_socket_messages_total',
  help: 'Messages received from clients, by event name.',
  labelNames: ['event'],
  registers: [registry],
});
export const socketEmitsTotal = new client.Counter({
  name: 'game_socket_emits_total',
  help: 'Messages sent to clients, by event name (a room broadcast counts once).',
  labelNames: ['event'],
  registers: [registry],
});
export const sessionReplacedTotal = new client.Counter({
  name: 'game_session_replaced_total',
  help: 'Times a second sign-in displaced an existing socket for the same account.',
  registers: [registry],
});

// -------------------------------------------------------------------- game

let roomsRef = null;

/**
 * Gives the gauges that describe the live tables their source. Called once
 * when the server is built; before that they report zero.
 */
export function bindRooms(rooms) {
  roomsRef = rooms;
}

const liveTables = () => (roomsRef ? [...roomsRef.tables.values()] : []);

new client.Gauge({
  name: 'game_players_online',
  help: 'Players seated at a table right now.',
  registers: [registry],
  collect() {
    this.set(liveTables().reduce((sum, table) => sum + table.playerCount, 0));
  },
});
new client.Gauge({
  name: 'game_active_games',
  help: 'Tables with a hand in progress (betting or showdown).',
  registers: [registry],
  collect() {
    this.set(liveTables().filter((table) => table.hand !== null).length);
  },
});
new client.Gauge({
  name: 'game_waiting_games',
  help: 'Tables that exist but have no hand in progress (waiting for players or between hands).',
  registers: [registry],
  collect() {
    this.set(liveTables().filter((table) => table.hand === null).length);
  },
});
new client.Gauge({
  name: 'game_tables',
  help: 'Open tables by category and stake.',
  labelNames: ['category', 'stake'],
  registers: [registry],
  collect() {
    this.reset();
    for (const table of liveTables()) {
      this.inc({ category: table.category, stake: String(table.config.bootAmount) });
    }
  },
});

export const gamesStartedTotal = new client.Counter({
  name: 'game_games_started_total',
  help: 'Hands dealt since the process started.',
  labelNames: ['category'],
  registers: [registry],
});
export const gamesCompletedTotal = new client.Counter({
  name: 'game_games_completed_total',
  help: 'Hands that ended with a winner, by how they ended.',
  labelNames: ['category', 'reason'],
  registers: [registry],
});
export const gamesAbandonedTotal = new client.Counter({
  name: 'game_games_abandoned_total',
  help: 'Hands that ended because every player left, or a table destroyed mid-hand.',
  labelNames: ['category'],
  registers: [registry],
});
export const movesTotal = new client.Counter({
  name: 'game_moves_total',
  help: 'Player actions accepted by the rules engine, by action.',
  labelNames: ['action'],
  registers: [registry],
});
export const invalidMovesTotal = new client.Counter({
  name: 'game_invalid_moves_total',
  help: 'Player actions refused by the rules engine, by refusal code.',
  labelNames: ['code'],
  registers: [registry],
});
export const timeoutsTotal = new client.Counter({
  name: 'game_turn_timeouts_total',
  help: 'Turns that ran out the clock and were packed automatically.',
  registers: [registry],
});
export const kicksTotal = new client.Counter({
  name: 'game_kicks_total',
  help: 'Players removed from a table by the server, by reason.',
  labelNames: ['reason'],
  registers: [registry],
});
export const chatMessagesTotal = new client.Counter({
  name: 'game_chat_messages_total',
  help: 'Chat messages posted to a table.',
  registers: [registry],
});
export const potSettledTotal = new client.Counter({
  name: 'game_pot_settled_chips_total',
  help: 'Chips paid out to hand winners since the process started.',
  registers: [registry],
});

// ----------------------------------------------------------------- latency

export const LATENCY_BUCKETS = [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1];

export const moveDuration = new client.Histogram({
  name: 'game_move_processing_duration_seconds',
  help: 'Time to validate a move, commit it to the database and update the table, by action.',
  labelNames: ['action'],
  buckets: LATENCY_BUCKETS,
  registers: [registry],
});
export const gameCreationDuration = new client.Histogram({
  name: 'game_creation_duration_seconds',
  help: 'Time to create a table (lobby quick-join that opened a new one, or a private room).',
  buckets: LATENCY_BUCKETS,
  registers: [registry],
});
export const gameJoinDuration = new client.Histogram({
  name: 'game_join_duration_seconds',
  help: 'Time from a join request to the player being seated and sent the table, by entry route.',
  labelNames: ['route'],
  buckets: LATENCY_BUCKETS,
  registers: [registry],
});
export const stateUpdateDuration = new client.Histogram({
  name: 'game_state_update_duration_seconds',
  help: 'Time to serialise and send one table state change to every viewer at the table.',
  buckets: LATENCY_BUCKETS,
  registers: [registry],
});
export const handStartDuration = new client.Histogram({
  name: 'game_hand_start_duration_seconds',
  help: 'Time to collect the boot and deal a hand (one database transaction).',
  buckets: LATENCY_BUCKETS,
  registers: [registry],
});
export const settlementDuration = new client.Histogram({
  name: 'game_settlement_duration_seconds',
  help: 'Time to settle a finished hand in the database.',
  buckets: LATENCY_BUCKETS,
  registers: [registry],
});
export const dbTransactionDuration = new client.Histogram({
  name: 'game_db_transaction_duration_seconds',
  help: 'Duration of the ledger transactions that move chips, by operation.',
  labelNames: ['op'],
  buckets: LATENCY_BUCKETS,
  registers: [registry],
});
export const dbTransactionErrorsTotal = new client.Counter({
  name: 'game_db_transaction_errors_total',
  help: 'Ledger transactions that rolled back, by operation and error code.',
  labelNames: ['op', 'code'],
  registers: [registry],
});

// ---------------------------------------------------------- database pool

let poolRef = null;

/** Gives the pool gauges their source. Everything deeper is postgres_exporter's job. */
export function bindPool(getPool) {
  poolRef = getPool;
}

const poolStat = (key) => {
  try {
    const pool = poolRef?.();
    return pool ? pool[key] : 0;
  } catch {
    return 0;
  }
};
new client.Gauge({ name: 'game_db_pool_connections', help: 'Connections held by the pg pool.', registers: [registry], collect() { this.set(poolStat('totalCount')); } });
new client.Gauge({ name: 'game_db_pool_idle_connections', help: 'Pool connections not in use.', registers: [registry], collect() { this.set(poolStat('idleCount')); } });
new client.Gauge({ name: 'game_db_pool_waiting_requests', help: 'Queries waiting for a pool connection.', registers: [registry], collect() { this.set(poolStat('waitingCount')); } });

// -------------------------------------------------------------------- HTTP

export const httpRequestsTotal = new client.Counter({
  name: 'game_http_requests_total',
  help: 'HTTP requests served, by method, route pattern and status code.',
  labelNames: ['method', 'route', 'status_code'],
  registers: [registry],
});
export const httpRequestDuration = new client.Histogram({
  name: 'game_http_request_duration_seconds',
  help: 'HTTP request duration, by method, route pattern and status code.',
  labelNames: ['method', 'route', 'status_code'],
  buckets: LATENCY_BUCKETS,
  registers: [registry],
});

const KNOWN_METHODS = new Set(['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS']);

/**
 * The route *pattern* a request matched — `/api/auth/me/hands`, never the URL
 * with an id in it. Static files are one bucket, anything unmatched another.
 */
function routeLabel(req) {
  if (req.route?.path) {
    const base = req.baseUrl ?? '';
    const path = Array.isArray(req.route.path) ? req.route.path[0] : req.route.path;
    return `${base}${path === '/' && base ? '' : path}` || '/';
  }
  if (req.path === '/' || /\.[a-z0-9]{2,5}$/i.test(req.path)) return 'static';
  return 'unmatched';
}

/** Express middleware: one counter and one histogram observation per response. */
export function httpMetricsMiddleware() {
  return (req, res, next) => {
    if (req.path === config.metrics.path) return next();
    const started = process.hrtime.bigint();
    res.on('finish', () => {
      const seconds = Number(process.hrtime.bigint() - started) / 1e9;
      const labels = {
        method: KNOWN_METHODS.has(req.method) ? req.method : 'OTHER',
        route: routeLabel(req),
        status_code: String(res.statusCode),
      };
      httpRequestsTotal.inc(labels);
      httpRequestDuration.observe(labels, seconds);
    });
    next();
  };
}

// ----------------------------------------------------------------- helpers

/**
 * Folds an unexpected label value into "other", so a label set stays bounded
 * even if a code path starts producing values nobody planned for.
 */
export function safeLabel(value, known, fallback = 'other') {
  const text = String(value ?? fallback);
  return known.has(text) ? text : fallback;
}

/** Times an async operation into a histogram, with labels, rethrowing on failure. */
export async function timed(histogram, labels, fn) {
  const started = process.hrtime.bigint();
  try {
    return await fn();
  } finally {
    histogram.observe(labels ?? {}, Number(process.hrtime.bigint() - started) / 1e9);
  }
}

/** Times a synchronous operation into a histogram. */
export function timedSync(histogram, labels, fn) {
  const started = process.hrtime.bigint();
  try {
    return fn();
  } finally {
    histogram.observe(labels ?? {}, Number(process.hrtime.bigint() - started) / 1e9);
  }
}

// ---------------------------------------------------------------- endpoint

/**
 * The `/metrics` handler. Optional protection: a bearer token
 * (`METRICS_TOKEN`) and/or an allow-list of client IPs (`METRICS_ALLOW_IPS`);
 * with neither set the endpoint is open, which is fine behind a firewall and
 * wrong on the public internet — the README says so.
 */
export function metricsHandler() {
  return async (req, res) => {
    const { token, allowIps } = config.metrics;
    if (allowIps.length > 0) {
      const ip = (req.ip ?? '').replace(/^::ffff:/, '');
      if (!allowIps.includes(ip)) return res.status(403).type('text/plain').send('forbidden');
    }
    if (token) {
      const header = req.headers.authorization ?? '';
      if (header !== `Bearer ${token}`) return res.status(401).type('text/plain').send('unauthorized');
    }
    res.set('Content-Type', registry.contentType);
    res.send(await registry.metrics());
  };
}

export default registry;
