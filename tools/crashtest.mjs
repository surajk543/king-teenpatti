/**
 * Failure-and-recovery acceptance tests for the live-state architecture
 * (go-server/LIVE_STATE_PLAN.md).
 *
 * Each scenario plays real hands against a real server, breaks something for
 * real — SIGKILL, or FLUSHALL on Redis, or both — and then asks the three
 * questions that matter:
 *
 *   1. Did the tables come back, and from where?
 *   2. Did the players get their seats back?
 *   3. Is every chip still accounted for?
 *
 * Chips are the point. PostgreSQL is the authority, so every scenario ends by
 * proving that each wallet still equals the sum of its own ledger rows and
 * that wallets plus open pots hold exactly what they held before the failure.
 * A hand that cannot be resumed must have its pot returned to the players who
 * paid into it, exactly once — never settled and refunded both.
 *
 *   node crashtest.mjs                          # every scenario
 *   node crashtest.mjs --scenario redis-loss    # one of: crash, redis-flush, redis-loss, no-redis
 *   node crashtest.mjs --bin ../go-server/bin/gameplay --keep
 *
 * Exit code 0 only when every check of every scenario passes.
 */
import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { io } from 'socket.io-client';
import pg from 'pg';

const here = path.dirname(fileURLToPath(import.meta.url));
const args = Object.fromEntries(process.argv.slice(2).reduce((p, t, i, a) => {
  if (t.startsWith('--')) p.push([t.slice(2), a[i + 1] === undefined || a[i + 1].startsWith('--') ? 'true' : a[i + 1]]);
  return p;
}, []));

const BIN = path.resolve(args.bin ?? path.join(here, '..', 'go-server', 'bin', 'gameplay'));
const DATABASE_URL = args.db ?? process.env.DATABASE_URL ?? 'postgres://postgres:postgres@localhost:5432/gameplay';
const PLAYERS = Number(args.players ?? 6);
const KEEP = args.keep === 'true';
const ONLY = args.scenario && args.scenario !== 'true' ? args.scenario.split(',') : null;
const REDIS_PORT = Number(args.redisPort ?? 6390);
const LOG_ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'king-teenpatti-crash-'));
const REDIS_HOME = path.join(os.homedir(), '.local', 'bin');
const REDIS_SERVER = fs.existsSync(path.join(REDIS_HOME, 'redis-server')) ? path.join(REDIS_HOME, 'redis-server') : 'redis-server';
const REDIS_CLI = fs.existsSync(path.join(REDIS_HOME, 'redis-cli')) ? path.join(REDIS_HOME, 'redis-cli') : 'redis-cli';

pg.types.setTypeParser(20, (v) => Number(v));
pg.types.setTypeParser(1700, (v) => Number(v));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const freePort = () => new Promise((resolve, reject) => {
  const probe = net.createServer();
  probe.unref(); probe.on('error', reject);
  probe.listen(0, '127.0.0.1', () => { const { port } = probe.address(); probe.close(() => resolve(port)); });
});

// ------------------------------------------------------------------ report
let failures = 0;
const results = [];
const say = (s) => console.log(s);
const step = (s) => say(`\n  ── ${s}`);
const pass = (what, detail = '') => { results.push({ ok: true, what }); say(`     ok    ${what}${detail ? '  — ' + detail : ''}`); };
const fail = (what, detail = '') => { failures += 1; results.push({ ok: false, what }); say(`     FAIL  ${what}${detail ? '  — ' + detail : ''}`); };
const check = (cond, what, detail) => (cond ? pass(what, detail) : fail(what, detail));

// ---------------------------------------------------------------- postgres
class Books {
  constructor(schema) { this.schema = schema; this.pool = new pg.Pool({ connectionString: DATABASE_URL, max: 4 }); }
  async q(text, params = []) { return (await this.pool.query({ text: text.replaceAll('%S%', `"${this.schema}"`), values: params })).rows; }
  async snapshot() {
    const [w] = await this.q('select coalesce(sum(chips),0) as chips, count(*) as users from %S%.users');
    const [p] = await this.q('select coalesce(sum(amount),0) as open_amount, count(*) as open_pots from %S%.pots where closed_at is null');
    const mismatched = await this.q(`select u.id, u.chips, l.s from %S%.users u
        join (select user_id, sum(delta) s from %S%.chip_ledger group by user_id) l on l.user_id = u.id
        where l.s <> u.chips`);
    const byReason = await this.q('select reason, count(*) as n, sum(delta) as delta from %S%.chip_ledger group by reason order by reason');
    const [g] = await this.q('select count(*) as rows from %S%.game_states');
    return { chips: w.chips, users: w.users, openPots: p.open_pots, openAmount: p.open_amount,
             total: w.chips + p.open_amount, mismatched, byReason, gameStates: g.rows };
  }
  /** Any trace of chat text anywhere in the durable snapshots. */
  async chatInDurable(mark) {
    const [r] = await this.q("select count(*) as n from %S%.game_states where state::text like $1", [`%${mark}%`]);
    return r.n;
  }
  async doubleClosed() {
    return this.q(`select hand_id from %S%.chip_ledger where reason in ('hand_win','hand_loss')
                   intersect
                   select hand_id from %S%.chip_ledger where reason = 'refund'`);
  }
  async drop() { try { await this.q('drop schema if exists %S% cascade'); } catch {} }
  async close() { await this.pool.end().catch(() => {}); }
}

// ------------------------------------------------------------------- redis
const redis = {
  proc: null,
  async start(logDir) {
    this.proc = spawn(REDIS_SERVER, ['--port', String(REDIS_PORT), '--save', '', '--appendonly', 'no', '--bind', '127.0.0.1'],
      { stdio: ['ignore', fs.openSync(path.join(logDir, 'redis.log'), 'a'), 'inherit'] });
    for (let i = 0; i < 60; i++) { if (this.ping()) return; await sleep(200); }
    throw new Error('redis did not start');
  },
  ping() { try { return execFileSync(REDIS_CLI, ['-p', String(REDIS_PORT), 'ping'], { stdio: 'pipe' }).toString().includes('PONG'); } catch { return false; } },
  cli(...a) { return execFileSync(REDIS_CLI, ['-p', String(REDIS_PORT), ...a], { stdio: 'pipe' }).toString().trim(); },
  keys(pattern = 'kt:*') { const out = this.cli('--scan', '--pattern', pattern); return out ? out.split('\n').filter(Boolean) : []; },
  flush() { return this.cli('flushall'); },
  stop() { if (this.proc) { this.proc.kill('SIGKILL'); this.proc = null; } },
  get url() { return `redis://127.0.0.1:${REDIS_PORT}/0`; },
};

// ------------------------------------------------------------------ server
function startServer({ port, schema, logDir, name, redisUrl }) {
  const env = {
    ...process.env,
    PORT: String(port), HOST: '127.0.0.1', PG_SCHEMA: schema, DATABASE_URL,
    NODE_ENV: 'test', AUTH_ALLOW_FAKE_PROVIDERS: 'true', JWT_SECRET: 'crashtest-secret',
    TABLE_STAKES: '', LOBBY_TABLES: '', BOOT_AMOUNT: '200', WELCOME_CHIPS: '200000',
    TURN_TIMEOUT_MS: '25000', NEXT_HAND_DELAY_MS: '1500', RECONNECT_GRACE_MS: '60000',
    // Short enough that the test does not wait long for the self-healing paths.
    SNAPSHOT_FLUSH_MS: '400', LIVE_RECONCILE_MS: '3000',
    LOG_LEVEL: 'info', PUBLIC_DIR: path.join(here, '..', 'go-server', 'public'),
    REDIS_URL: redisUrl ?? '',
  };
  const out = fs.openSync(path.join(logDir, `${name}.log`), 'a');
  const child = spawn(BIN, [], { env, cwd: path.dirname(BIN), stdio: ['ignore', out, out] });
  child.on('error', (e) => console.error('server spawn error:', e.message));
  return child;
}

async function waitHealthy(baseUrl, timeoutMs = 30000) {
  const until = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < until) {
    try { const r = await fetch(`${baseUrl}/health`); if (r.ok) return await r.json(); } catch (e) { last = e.message; }
    await sleep(200);
  }
  throw new Error(`server at ${baseUrl} never became healthy${last ? ` (${last})` : ''}`);
}
const health = async (baseUrl) => (await (await fetch(`${baseUrl}/health`)).json());
async function metric(baseUrl, name) {
  try {
    const body = await (await fetch(`${baseUrl}/metrics`)).text();
    return body.split('\n').filter((l) => l.startsWith(name)).map((l) => {
      const i = l.lastIndexOf(' ');
      return { series: l.slice(0, i), value: Number(l.slice(i + 1)) };
    });
  } catch { return []; }
}
/** Sums every series whose text contains each of the given fragments. */
const metricSum = async (baseUrl, ...fragments) => (await metric(baseUrl, fragments[0].split('{')[0]))
  .filter((m) => fragments.every((f) => m.series.includes(f)))
  .reduce((n, m) => n + m.value, 0);

const kill = async (child, signal = 'SIGKILL') => {
  if (!child || child.exitCode !== null) return;
  child.kill(signal);
  await new Promise((resolve) => { child.once('exit', resolve); setTimeout(resolve, 12000); });
};

// ------------------------------------------------------------------ client
async function login(baseUrl, schema, i) {
  const r = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ provider: 'guest', deviceId: `crashtest-${schema}-${i}-device`, displayName: `Crash${i}` }),
  });
  if (!r.ok) throw new Error(`login ${i}: ${r.status}`);
  return r.json();
}

/** A player that joins a blind table and plays whatever it is offered. */
function connect(baseUrl, user, rec) {
  const socket = io(baseUrl, { auth: { token: user.token }, transports: ['websocket'], forceNew: true, reconnection: false });
  rec.events = [];
  let act = () => {};
  socket.onAny((name, payload) => {
    rec.events.push(name);
    if (name === 'room:joined') { rec.roomId = payload.roomId; rec.code = payload.code; }
    if (name === 'room:joined' || name === 'room:state') {
      if (payload.handNo) rec.handNo = payload.handNo;
      rec.pot = payload.pot;
      if (payload.turn?.userId === rec.user?.user?.id && payload.you?.options) act(payload.you.options, payload.turn.deadline);
    }
    if (name === 'game:handEnded') rec.handsEnded = (rec.handsEnded ?? 0) + 1;
    if (name === 'game:action') rec.movesSeen = (rec.movesSeen ?? 0) + 1;
    if (name === 'chat:history') rec.chat = (payload.messages ?? []).map((m) => m.text);
    if (name === 'chat:message') { rec.chat = rec.chat ?? []; rec.chat.push(payload.text); }
  });
  socket.on('connect', () => { rec.connected = true; });
  socket.on('disconnect', () => { rec.connected = false; });
  // The Flutter client never listens to game:yourTurn (CLAUDE.md §7.1): it
  // reads the turn and the options out of room:state. Doing the same here is
  // what makes this test meaningful after a restore, when the player who is
  // already on turn gets a snapshot rather than a fresh turn event.
  // One move per decision. The deadline identifies the turn, but SEE is free
  // and does not advance it, so the player must act again on the same turn —
  // hence canSee is part of the key. (Keying on the pot instead would be
  // wrong too: a pack leaves the pot unchanged.)
  act = (options, deadline) => {
    if (socket.disconnected || !options) return;
    const key = `${rec.handNo}:${deadline ?? 'none'}:${options.canSee ? 'blind' : 'seen'}`;
    if (rec.lastActed === key) return;
    rec.lastActed = key;
    setTimeout(() => {
      if (socket.disconnected) return;
      // A blind table has no round limit (by design), so bots that only ever
      // call would keep one hand running for ever. Fold sometimes, like the
      // practice bots do, so hands actually reach a showdown.
      const action = options.canSee ? 'see'
        : !options.raiseSteps?.length ? 'pack'
        : Math.random() < 0.3 ? 'pack' : 'chaal';
      socket.emit('game:action', { action, actionId: `${rec.i}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}` }, () => {});
    }, 60 + Math.random() * 200);
  };
  socket.on('game:yourTurn', ({ options, deadline }) => act(options, deadline));
  rec.socket = socket;
  return rec;
}

/**
 * Posts a distinctive line from each player. Chat is the one thing allowed to
 * vanish with the live store, so the test both proves it never reaches
 * PostgreSQL and accepts that a room rebuilt from there comes back silent.
 */
const CHAT_MARK = `chatmark-${Math.random().toString(36).slice(2, 10)}`;
function postChat(recs) {
  recs.forEach((r, i) => r.socket.emit('chat:message', { text: `${CHAT_MARK}-${i}` }, () => {}));
}

/** Seats PLAYERS guests and waits until hands are running. */
async function seatPlayers(baseUrl, schema) {
  const users = [];
  for (let i = 0; i < PLAYERS; i++) users.push(await login(baseUrl, schema, i));
  const recs = users.map((u, i) => connect(baseUrl, u, { i, user: u }));
  await sleep(600);
  for (const r of recs) r.socket.emit('room:quickJoin', { bootAmount: 200, category: 'blind' }, () => {});
  for (let i = 0; i < 60 && (await health(baseUrl)).players < PLAYERS; i++) await sleep(250);
  return { users, recs };
}

// --------------------------------------------------------------- scenarios
/**
 * Every scenario gets a fresh schema, its own log directory and, unless it
 * says otherwise, a fresh Redis. `run` returns nothing and records checks.
 */
async function scenario(name, title, body) {
  if (ONLY && !ONLY.includes(name)) return;
  const schema = `crash_${name.replace(/-/g, '_')}_${Math.random().toString(36).slice(2, 6)}`;
  const logDir = path.join(LOG_ROOT, name);
  fs.mkdirSync(logDir, { recursive: true });
  const books = new Books(schema);
  const port = await freePort();
  const baseUrl = `http://127.0.0.1:${port}`;
  const servers = [];
  say(`\n${'═'.repeat(78)}\n${title}\n${'─'.repeat(78)}\n  schema ${schema} · port ${port} · logs ${logDir}`);
  const before = failures;
  try {
    await body({ schema, logDir, books, port, baseUrl, servers });
  } catch (e) {
    fail(`${name} threw`, e.message);
  } finally {
    for (const s of servers) await kill(s, 'SIGTERM');
    if (!KEEP) await books.drop();
    await books.close();
  }
  say(`  ${failures === before ? '✔ scenario passed' : `✘ scenario failed (${failures - before} check(s))`}`);
}

/** Shared ending: the books must balance however the scenario broke things. */
async function auditBooks(books, before, label = '') {
  const after = await books.snapshot();
  const dbl = await books.doubleClosed();
  say(`     ledger: ${after.byReason.map((r) => `${r.reason} ${r.n}`).join(', ')}`);
  check(after.mismatched.length === 0, `every wallet equals the sum of its own ledger rows${label}`,
    after.mismatched.length ? JSON.stringify(after.mismatched.slice(0, 3)) : `${after.users} accounts`);
  check(after.total === before.total, `wallets plus open pots hold what they held before${label}`,
    `${after.total} vs ${before.total}`);
  check(dbl.length === 0, 'no hand was both settled and refunded', dbl.length ? JSON.stringify(dbl) : '');
  return after;
}

async function main() {
  if (!fs.existsSync(BIN)) throw new Error(`Go binary not found at ${BIN} — build it first (go-server/ops/build.sh)`);
  say(`live-state failure tests\n  binary ${BIN}\n  logs   ${LOG_ROOT}`);

  // 1 ─────────────────────────────────────────────────────────────────────
  await scenario('crash', 'CRASH — the server is killed mid-hand; Redis survives', async (ctx) => {
    await redis.start(ctx.logDir); redis.flush();
    ctx.servers.push(startServer({ ...ctx, name: 'server-1', redisUrl: redis.url }));
    await waitHealthy(ctx.baseUrl);
    step('Seat players and let hands run');
    const { users, recs } = await seatPlayers(ctx.baseUrl, ctx.schema);
    await sleep(6000);
    const h1 = await health(ctx.baseUrl);
    const before = await ctx.books.snapshot();
    say(`     ${h1.tables} tables, ${h1.activeHands} hands running, ${before.openPots} open pots holding ${before.openAmount} chips`);
    check(h1.activeHands > 0, 'a hand is in progress when we kill the server', `${h1.activeHands} active`);
    check(redis.keys('kt:table:*').length === h1.tables, 'Redis holds a snapshot for every table',
      `${redis.keys('kt:table:*').length} of ${h1.tables}`);
    postChat(recs); await sleep(1200);
    check(redis.keys('kt:chat:*').length > 0, 'chat is mirrored to the live store', `${redis.keys('kt:chat:*').length} rooms`);
    check((await ctx.books.chatInDurable(CHAT_MARK)) === 0, 'and no chat text reached PostgreSQL');
    const rooms = new Set(recs.map((r) => r.roomId).filter(Boolean));

    step('SIGKILL the server');
    await kill(ctx.servers.pop());
    for (const r of recs) r.socket.close();

    step('Restart it');
    ctx.servers.push(startServer({ ...ctx, name: 'server-2', redisUrl: redis.url }));
    await waitHealthy(ctx.baseUrl); await sleep(1500);
    const h2 = await health(ctx.baseUrl);
    say(`     live store: ${JSON.stringify(h2.live ?? 'not reported')}`);
    check(h2.tables === h1.tables, 'every table came back', `${h2.tables} of ${h1.tables}`);
    check(h2.players === PLAYERS, 'every seat was held for the reconnect grace', `${h2.players} of ${PLAYERS}`);
    const fromLive = await metricSum(ctx.baseUrl, 'game_restored_tables_total', 'source="live"');
    if (fromLive) check(fromLive === h1.tables, 'and they came from the live store', `${fromLive} tables`);

    step('Players reconnect and play on');
    const again = users.map((u, i) => connect(ctx.baseUrl, u, { i, user: u }));
    await sleep(3000);
    check(again.filter((r) => r.roomId).length === PLAYERS, 'every player is back at a table');
    check(again.filter((r) => rooms.has(r.roomId)).length === PLAYERS, 'and it is the table they were at');
    const heard = again.filter((r) => (r.chat ?? []).some((t) => t.startsWith(CHAT_MARK))).length;
    check(heard > 0, 'the chat history came back with the table (Redis survived)', `${heard} players got the backlog`);
    await sleep(10000);
    const moves = again.reduce((n, r) => n + (r.movesSeen ?? 0), 0);
    const hh = await health(ctx.baseUrl);
    say(`     diagnostics: ${JSON.stringify(hh)} · per player: ${again.map((r) => `P${r.i}[room=${(r.roomId ?? '-').slice(0, 6)} moves=${r.movesSeen ?? 0} ends=${r.handsEnded ?? 0} kicked=${r.events.filter((e) => e === 'room:kicked').length}]`).join(' ')}`);
    check(moves > 0, 'the restored hands are being played on', `${moves} moves after the restart`);
    check(again.some((r) => (r.handsEnded ?? 0) > 0), 'and a hand reached its showdown and paid out',
      `${again.reduce((n, r) => n + (r.handsEnded ?? 0), 0)} hands ended`);
    for (const r of again) r.socket.emit('room:leave', {}, () => {});
    await sleep(2500);
    for (const r of again) r.socket.close();
    await auditBooks(ctx.books, before);
    redis.stop();
  });

  // 2 ─────────────────────────────────────────────────────────────────────
  await scenario('redis-flush', 'REDIS DIES under a running server, then comes back empty', async (ctx) => {
    await redis.start(ctx.logDir); redis.flush();
    ctx.servers.push(startServer({ ...ctx, name: 'server', redisUrl: redis.url }));
    await waitHealthy(ctx.baseUrl);
    step('Seat players and let hands run');
    const { recs } = await seatPlayers(ctx.baseUrl, ctx.schema);
    await sleep(6000);
    const h1 = await health(ctx.baseUrl);
    const before = await ctx.books.snapshot();
    const keysBefore = redis.keys().length;
    say(`     ${h1.tables} tables, ${keysBefore} live keys`);

    step('FLUSHALL — the live store loses everything while the game is running');
    redis.flush();
    check(redis.keys().length === 0, 'the live store is empty');
    const errsBefore = await metricSum(ctx.baseUrl, 'game_live_store_errors_total');

    step('The game must not notice');
    await sleep(4000);
    const h2 = await health(ctx.baseUrl);
    check(h2.tables === h1.tables, 'every table is still being played', `${h2.tables} of ${h1.tables}`);
    check(h2.players === h1.players, 'nobody lost their seat', `${h2.players} of ${h1.players}`);
    check(recs.some((r) => r.connected), 'sockets stayed connected');

    step('The reconciler refills the live store');
    let refilled = 0;
    for (let i = 0; i < 20; i++) { refilled = redis.keys('kt:table:*').length; if (refilled >= h1.tables) break; await sleep(1000); }
    check(refilled >= h1.tables, 'every table snapshot is back in Redis without waiting for a move',
      `${refilled} of ${h1.tables}`);
    const seats = redis.keys('kt:seat:*').length;
    check(seats >= h1.players, 'and every seat is indexed again', `${seats} of ${h1.players}`);
    const reconciles = await metricSum(ctx.baseUrl, 'game_live_store_reconciles_total');
    if (reconciles) say(`     reconciler ran ${reconciles} time(s); live-store errors during the outage: ${(await metricSum(ctx.baseUrl, 'game_live_store_errors_total')) - errsBefore}`);

    step('Play continues and the books balance');
    await sleep(6000);
    for (const r of recs) { r.socket.emit('room:leave', {}, () => {}); }
    await sleep(2500);
    for (const r of recs) r.socket.close();
    await auditBooks(ctx.books, before);
    redis.stop();
  });

  // 3 ─────────────────────────────────────────────────────────────────────
  await scenario('redis-loss', 'REDIS AND SERVER BOTH DIE — every room is rebuilt from PostgreSQL', async (ctx) => {
    await redis.start(ctx.logDir); redis.flush();
    ctx.servers.push(startServer({ ...ctx, name: 'server-1', redisUrl: redis.url }));
    await waitHealthy(ctx.baseUrl);
    step('Seat players and let hands run');
    const { users, recs } = await seatPlayers(ctx.baseUrl, ctx.schema);
    await sleep(7000);
    const h1 = await health(ctx.baseUrl);
    const before = await ctx.books.snapshot();
    const rooms = new Set(recs.map((r) => r.roomId).filter(Boolean));
    say(`     ${h1.tables} tables, ${h1.activeHands} hands running, ${before.openPots} open pots holding ${before.openAmount} chips`);
    // Since 9 Sep 2026 the durable copy is written at the two hand boundaries
    // only, so a table that has never dealt has no row — nothing is at stake
    // and its players simply re-join. What must hold is that every table that
    // HAS dealt is recoverable.
    const dealt = (await ctx.books.q('select count(distinct room_id) as n from %S%.pots'))[0].n;
    check(before.gameStates >= dealt, 'PostgreSQL holds a durable snapshot of every table that dealt',
      `${before.gameStates} game_states rows for ${dealt} room(s) that dealt, ${h1.tables} tables open`);
    postChat(recs); await sleep(1200);

    step('Kill the server AND wipe Redis — the live store is gone for good');
    await kill(ctx.servers.pop());
    for (const r of recs) r.socket.close();
    redis.stop();
    await redis.start(ctx.logDir);   // a brand-new, empty Redis
    redis.flush();
    check(redis.keys().length === 0, 'Redis comes back with nothing in it');

    step('Restart the server — it must rebuild the rooms from PostgreSQL');
    ctx.servers.push(startServer({ ...ctx, name: 'server-2', redisUrl: redis.url }));
    await waitHealthy(ctx.baseUrl); await sleep(2500);
    const h2 = await health(ctx.baseUrl);
    say(`     live store: ${JSON.stringify(h2.live ?? 'not reported')}`);
    const fromPg = await metricSum(ctx.baseUrl, 'game_restored_tables_total', 'source="postgres"');
    const rejected = await metricSum(ctx.baseUrl, 'game_restore_rejected_total');
    const reconciled = await metricSum(ctx.baseUrl, 'game_restore_reconciled_total');
    check(h2.tables > 0, 'rooms were rebuilt from the durable snapshot', `${h2.tables} tables (of ${h1.tables})`);
    if (fromPg) check(fromPg > 0, 'and the restore source was PostgreSQL', `${fromPg} tables from game_states`);
    say(`     ${reconciled} snapshot(s) corrected against the ledger, ${rejected} rejected as too stale`);
    check(h2.players > 0, 'seats were held for the players', `${h2.players} of ${PLAYERS}`);
    check(redis.keys('kt:table:*').length >= h2.tables, 'the rebuilt rooms were written back into Redis',
      `${redis.keys('kt:table:*').length} snapshots`);

    step('Players reconnect');
    const again = users.map((u, i) => connect(ctx.baseUrl, u, { i, user: u }));
    await sleep(3500);
    const back = again.filter((r) => r.roomId).length;
    check(back > 0, 'players are back at a table', `${back} of ${PLAYERS}`);
    check(again.filter((r) => rooms.has(r.roomId)).length === back, 'at the table they were at before');
    const withChat = again.filter((r) => (r.chat ?? []).some((t) => t.startsWith(CHAT_MARK))).length;
    check(withChat === 0, 'the chat history is gone with the live store, as intended', `${withChat} players saw the old backlog`);
    check(again.filter((r) => Array.isArray(r.chat)).length === back, 'and the empty history is still delivered as a list');
    check((await ctx.books.chatInDurable(CHAT_MARK)) === 0, 'no chat text was ever written to PostgreSQL');

    step('Play on, then settle up');
    await sleep(10000);
    const moves = again.reduce((n, r) => n + (r.movesSeen ?? 0), 0);
    check(moves > 0, 'the rebuilt hands are being played on', `${moves} moves after the rebuild`);
    check(again.some((r) => (r.handsEnded ?? 0) > 0), 'and a hand reached its showdown and paid out',
      `${again.reduce((n, r) => n + (r.handsEnded ?? 0), 0)} hands ended`);
    for (const r of again) r.socket.emit('room:leave', {}, () => {});
    await sleep(2500);
    for (const r of again) r.socket.close();
    const after = await auditBooks(ctx.books, before);
    const refunds = after.byReason.find((r) => r.reason === 'refund');
    say(`     ${refunds ? `${refunds.n} refund rows returned ${refunds.delta} chips` : 'no pot needed refunding'}`);
    redis.stop();
  });

  // 4 ─────────────────────────────────────────────────────────────────────
  await scenario('no-redis', 'NO LIVE STORE AT ALL — tables are lost, money is not', async (ctx) => {
    ctx.servers.push(startServer({ ...ctx, name: 'server-1', redisUrl: '' }));
    await waitHealthy(ctx.baseUrl);
    step('Seat players and let hands run');
    const { recs } = await seatPlayers(ctx.baseUrl, ctx.schema);
    await sleep(6000);
    const h1 = await health(ctx.baseUrl);
    const before = await ctx.books.snapshot();
    say(`     ${h1.tables} tables, ${before.openPots} open pots holding ${before.openAmount} chips`);

    step('SIGKILL the server');
    await kill(ctx.servers.pop());
    for (const r of recs) r.socket.close();

    step('Restart — PostgreSQL is still the backstop even with no Redis');
    ctx.servers.push(startServer({ ...ctx, name: 'server-2', redisUrl: '' }));
    await waitHealthy(ctx.baseUrl); await sleep(2500);
    const h2 = await health(ctx.baseUrl);
    const fromPg = await metricSum(ctx.baseUrl, 'game_restored_tables_total', 'source="postgres"');
    say(`     ${h2.tables} tables back, ${fromPg} from game_states`);
    const after = await auditBooks(ctx.books, before, ' with no live store');
    check(after.openPots === 0 || h2.tables > 0, 'no pot was left open with no table to play it out',
      `${after.openPots} open, ${h2.tables} tables`);
  });

  // ────────────────────────────────────────────────────────────────────────
  const ok = results.filter((r) => r.ok).length;
  say(`\n${'═'.repeat(78)}`);
  say(`${failures === 0 ? 'PASS' : `FAIL — ${failures} of ${results.length} checks`}   (${ok}/${results.length} checks passed)`);
  if (KEEP) say(`logs kept in ${LOG_ROOT}`);
}

main()
  .catch((e) => { failures += 1; console.error('\nerror:', e.stack ?? e.message); })
  .finally(async () => {
    redis.stop();
    if (!KEEP) { try { fs.rmSync(LOG_ROOT, { recursive: true, force: true }); } catch {} }
    process.exit(failures === 0 ? 0 : 1);
  });
