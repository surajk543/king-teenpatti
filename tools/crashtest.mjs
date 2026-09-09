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
 * that no chips were created.
 *
 * Since 9 Sep 2026 (LIVE_STATE_PLAN.md) PostgreSQL holds MONEY AND AUDIT ONLY
 * — `users` and `chip_ledger`, nothing else — and is written at exactly three
 * moments: a player packs, a player leaves or switches, and the hand ends.
 * The deal and every bet move chips in Redis and nowhere else. So losing
 * Redis loses the TABLES and the hand never happened: whatever PostgreSQL
 * holds is the players' balance, and for anyone who had not been checkpointed
 * that is their PRE-HAND balance (the owner's example 1).
 *
 * The one accepted consequence, owner-approved: a player who PACKED before
 * the loss keeps their reduced balance while nobody wins the pot, so those
 * chips leave the economy. The tests below allow the total to fall by exactly
 * that much and never by more, and never to rise.
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
    const mismatched = await this.q(`select u.id, u.chips, l.s from %S%.users u
        join (select user_id, sum(delta) s from %S%.chip_ledger group by user_id) l on l.user_id = u.id
        where l.s <> u.chips`);
    const byReason = await this.q('select reason, count(*) as n, sum(delta) as delta from %S%.chip_ledger group by reason order by reason');
    const perUser = await this.q('select id, chips from %S%.users order by id');
    // A hand whose rows do not sum to zero is one the failure interrupted:
    // its packers were charged and nobody was paid.
    const [stranded] = await this.q(`select coalesce(-sum(net), 0) as chips from (
        select sum(delta) as net from %S%.chip_ledger where hand_id is not null group by hand_id having sum(delta) <> 0
      ) x`);
    return { chips: w.chips, users: w.users, total: w.chips, mismatched, byReason,
             stranded: stranded.chips,
             wallets: Object.fromEntries(perUser.map((r) => [r.id, r.chips])) };
  }
  /** Which tables the schema has — PostgreSQL must hold no game state. */
  async tables() {
    return (await this.pool.query(
      { text: 'select tablename from pg_tables where schemaname = $1 order by tablename', values: [this.schema] })).rows.map((r) => r.tablename);
  }
  async ledgerFor(userId) {
    const [r] = await this.q('select coalesce(sum(delta),0) as s, count(*) as n from %S%.chip_ledger where user_id = $1', [userId]);
    return r;
  }
  /** A player resolved twice in one hand — a win/loss/left row written twice. */
  async doubleClosed() {
    return this.q(`select hand_id, user_id from %S%.chip_ledger
                    where reason in ('hand_win','hand_loss','hand_left')
                    group by hand_id, user_id having count(*) > 1`);
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
    LIVE_RECONCILE_MS: '3000',
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
  // THE conservation law of this design: wallets plus what an unfinished hand
  // has already taken from its packers is constant. A hand in flight moves
  // chips from wallets into "stranded"; finishing it moves them back; losing
  // Redis leaves them stranded for good (owner-approved). Nothing is ever
  // created either way.
  check(after.total + after.stranded === before.total + before.stranded,
    `wallets plus chips held by an unfinished hand are unchanged${label}`,
    `${after.total}+${after.stranded} vs ${before.total}+${before.stranded}`);
  check(dbl.length === 0, 'no player was resolved twice in one hand', dbl.length ? JSON.stringify(dbl) : '');
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
    say(`     ${h1.tables} tables, ${h1.activeHands} hands running; wallets hold ${before.total}`);
    check(h1.activeHands > 0, 'a hand is in progress when we kill the server', `${h1.activeHands} active`);
    check(redis.keys('kt:table:*').length === h1.tables, 'Redis holds a snapshot for every table',
      `${redis.keys('kt:table:*').length} of ${h1.tables}`);
    postChat(recs); await sleep(1200);
    check(redis.keys('kt:chat:*').length > 0, 'chat is mirrored to the live store', `${redis.keys('kt:chat:*').length} rooms`);
    check((await ctx.books.tables()).join(',') === 'chip_ledger,users', 'PostgreSQL holds money and audit only — nothing about a table');
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
    const restored = await metricSum(ctx.baseUrl, 'game_restored_tables_total');
    if (restored) check(restored === h1.tables, 'and they came from the live store, the only source', `${restored} tables`);

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
  await scenario('redis-loss', 'REDIS AND SERVER BOTH DIE — the tables are gone; every chip is not', async (ctx) => {
    await redis.start(ctx.logDir); redis.flush();
    ctx.servers.push(startServer({ ...ctx, name: 'server-1', redisUrl: redis.url }));
    await waitHealthy(ctx.baseUrl);
    step('Seat players and let hands run');
    const { users, recs } = await seatPlayers(ctx.baseUrl, ctx.schema);
    await sleep(7000);
    const h1 = await health(ctx.baseUrl);
    const rooms = new Set(recs.map((r) => r.roomId).filter(Boolean));
    say(`     ${h1.tables} tables, ${h1.activeHands} hands running`);
    // PostgreSQL holds money and audit only (owner's decision of 9 Sep 2026).
    check((await ctx.books.tables()).join(',') === 'chip_ledger,users',
      'PostgreSQL holds money and audit only: no game_states, no pots, no hands');
    postChat(recs); await sleep(1200);

    // One player walks out MID-HAND before the failure. That is checkpoint 1
    // of 3, so their stake is written through there and then — those rows
    // must survive the Redis loss, while everybody else's hand is un-made.
    step('A player leaves mid-hand: that one player is written through');
    const quitter = recs.find((r) => r.roomId) ?? recs[0];
    const quitterId = quitter.user.user.id;
    const preHand = (await ctx.books.snapshot()).wallets;
    quitter.socket.emit('room:leave', {}, () => {});
    await sleep(2000);
    const quitterLedger = await ctx.books.ledgerFor(quitterId);
    const afterLeave = (await ctx.books.snapshot()).wallets[quitterId];
    check(afterLeave === quitterLedger.s, 'the departed player\'s wallet equals their ledger',
      `${afterLeave} vs ${quitterLedger.s} over ${quitterLedger.n} rows`);
    quitter.socket.close();

    // Everyone still playing has been written for at most the hands that
    // already ended: pick one who is mid-hand and remember what PostgreSQL
    // holds for them — that is what they must still have afterwards.
    const before = await ctx.books.snapshot();
    const midHand = recs.filter((r) => r !== quitter && r.roomId).map((r) => r.user.user.id);
    say(`     ${midHand.length} players mid-hand; wallets hold ${before.total}, ${before.stranded} stranded`);

    step('Kill the server AND wipe Redis — the live store is gone for good');
    await kill(ctx.servers.pop());
    for (const r of recs) r.socket.close();
    redis.stop();
    await redis.start(ctx.logDir);   // a brand-new, empty Redis
    redis.flush();
    check(redis.keys().length === 0, 'Redis comes back with nothing in it');

    step('Restart — nothing is rebuilt, and the hand never happened');
    ctx.servers.push(startServer({ ...ctx, name: 'server-2', redisUrl: redis.url }));
    await waitHealthy(ctx.baseUrl); await sleep(2500);
    const h2 = await health(ctx.baseUrl);
    say(`     live store: ${JSON.stringify(h2.live ?? 'not reported')}`);
    const restored = await metricSum(ctx.baseUrl, 'game_restored_tables_total');
    check(h2.tables === 0, 'no table came back — the live store was the only copy', `${h2.tables} tables`);
    check(restored === 0, 'and the restore counter agrees', `${restored} restored`);
    check(h2.players === 0, 'no seat came back either', `${h2.players} players`);
    const mid = await ctx.books.snapshot();
    check(mid.mismatched.length === 0, 'every wallet still equals the sum of its own ledger rows',
      mid.mismatched.length ? JSON.stringify(mid.mismatched.slice(0, 3)) : `${mid.users} accounts`);
    // OWNER EXAMPLE 1: a player who staked mid-hand and was never
    // checkpointed has their PRE-HAND balance, because nothing was deducted.
    let unchanged = 0;
    for (const id of midHand) if (mid.wallets[id] === before.wallets[id]) unchanged += 1;
    check(unchanged === midHand.length,
      'every mid-hand player has the balance PostgreSQL held before the failure — the hand never happened',
      `${unchanged} of ${midHand.length}`);
    // The departed player's checkpoint is still there.
    const afterLedger = await ctx.books.ledgerFor(quitterId);
    check(afterLedger.n >= quitterLedger.n, 'the departed player\'s checkpoint rows are still in PostgreSQL',
      `${afterLedger.n} rows (was ${quitterLedger.n})`);
    check(mid.wallets[quitterId] === afterLedger.s, 'and their wallet equals their ledger',
      `${mid.wallets[quitterId]} vs ${afterLedger.s}`);
    check(mid.wallets[quitterId] === afterLeave, 'and it was NOT refunded by the restart',
      `${afterLeave} → ${mid.wallets[quitterId]}`);
    check(mid.wallets[quitterId] <= preHand[quitterId], 'their stake stayed forfeited, as leaving mid-hand means',
      `${preHand[quitterId]} → ${mid.wallets[quitterId]}`);
    // The conservation law: wallets plus what the interrupted hand had already
    // taken from its packers is unchanged. Those stranded chips are gone from
    // the economy for good — the one accepted consequence of this design.
    check(mid.total + mid.stranded === before.total + before.stranded,
      'wallets plus chips held by the interrupted hand are unchanged',
      `${mid.total}+${mid.stranded} vs ${before.total}+${before.stranded}`);
    say(`     ${mid.stranded} chip(s) are stranded in hands the failure interrupted (owner-approved: a packer keeps their reduced balance and nobody wins the pot)`);
    const dbl = await ctx.books.doubleClosed();
    check(dbl.length === 0, 'no player was resolved twice in one hand', dbl.length ? JSON.stringify(dbl) : '');

    step('Players rejoin into FRESH tables and play on');
    const again = users.map((u, i) => connect(ctx.baseUrl, u, { i, user: u }));
    await sleep(1500);
    for (const r of again) r.socket.emit('room:quickJoin', { bootAmount: 200, category: 'blind' }, () => {});
    await sleep(3500);
    const back = again.filter((r) => r.roomId).length;
    check(back === PLAYERS, 'every player is seated again', `${back} of ${PLAYERS}`);
    check(again.every((r) => !rooms.has(r.roomId)), 'at a NEW table — the old rooms are gone for good');
    const withChat = again.filter((r) => (r.chat ?? []).some((t) => t.startsWith(CHAT_MARK))).length;
    check(withChat === 0, 'the chat history went with the live store, as intended', `${withChat} players saw the old backlog`);
    check(again.filter((r) => Array.isArray(r.chat)).length === back, 'and the empty history is still delivered as a list');

    await sleep(10000);
    const moves = again.reduce((n, r) => n + (r.movesSeen ?? 0), 0);
    check(moves > 0, 'the fresh hands are being played', `${moves} moves after the rejoin`);
    check(again.some((r) => (r.handsEnded ?? 0) > 0), 'and a hand reached its showdown and paid out',
      `${again.reduce((n, r) => n + (r.handsEnded ?? 0), 0)} hands ended`);
    for (const r of again) r.socket.emit('room:leave', {}, () => {});
    await sleep(2500);
    for (const r of again) r.socket.close();
    await auditBooks(ctx.books, mid);
    redis.stop();
  });

  // 4 ─────────────────────────────────────────────────────────────────────
  await scenario('no-redis', 'NO LIVE STORE AT ALL — a restart loses the tables; the money is untouched', async (ctx) => {
    ctx.servers.push(startServer({ ...ctx, name: 'server-1', redisUrl: '' }));
    await waitHealthy(ctx.baseUrl);
    step('Seat players and let hands run');
    const { recs } = await seatPlayers(ctx.baseUrl, ctx.schema);
    await sleep(6000);
    const h1 = await health(ctx.baseUrl);
    const before = await ctx.books.snapshot();
    say(`     ${h1.tables} tables; wallets hold ${before.total}, ${before.stranded} stranded`);

    step('SIGKILL the server');
    await kill(ctx.servers.pop());
    for (const r of recs) r.socket.close();

    step('Restart — the tables are lost and the hands never happened');
    ctx.servers.push(startServer({ ...ctx, name: 'server-2', redisUrl: '' }));
    await waitHealthy(ctx.baseUrl); await sleep(2500);
    const h2 = await health(ctx.baseUrl);
    const restored = await metricSum(ctx.baseUrl, 'game_restored_tables_total');
    say(`     ${h2.tables} tables back, ${restored} restored`);
    check(h2.tables === 0, 'no table came back: the in-process store died with the process', `${h2.tables} tables`);
    check(restored === 0, 'and nothing was restored from anywhere', `${restored} restored`);
    await auditBooks(ctx.books, before, ' with no live store');
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
