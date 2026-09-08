/**
 * Staged load test: how many concurrent players a server takes before it degrades.
 *
 * Players are added in stages (10, 25, 50, … by default), each stage is held
 * for a measurement window, and the run stops on its own when action latency
 * or the error rate crosses a threshold. Bots log in as guests with FIXED
 * device ids (`ramp-bot-<n>`), so re-running reuses the same accounts.
 *
 *   node tools/ramptest.mjs --url https://api.sungamestudio.com \
 *        --stages 10,25,50,100,200,300,400,500 --hold 40 --out ramp.json
 */
import { io } from 'socket.io-client';
import fs from 'node:fs';

import { fork } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const args = Object.fromEntries(process.argv.slice(2).reduce((p, t, i, a) => {
  if (t.startsWith('--')) p.push([t.slice(2), a[i + 1]]);
  return p;
}, []));

const BASE_URL = args.url ?? 'http://localhost:3000';
const STAGES = (args.stages ?? '10,25,50,100,200,300,400,500').split(',').map(Number);
const HOLD_S = Number(args.hold ?? 40);
const BOOT = Number(args.boot ?? 200);
const CATEGORY = args.category ?? 'blind';
const BATCH = Number(args.batch ?? 25);
const BATCH_DELAY_MS = Number(args.rampDelay ?? 150);
const OUT = args.out ?? 'ramp-report.json';
// Stop rules: the stage that first breaks one of these is the ceiling.
const MAX_P95_MS = Number(args.maxP95 ?? 3000);
const MAX_ERROR_RATE = Number(args.maxErrors ?? 0.10);
// For running several generators side by side: each takes its own id range.
const ID_OFFSET = Number(args.idOffset ?? 0);
// Multi-process mode: `--workers N` forks N copies of this script, each holding
// the bots whose index i satisfies i % N == k. The parent drives the stages,
// polls /health, merges every worker's raw samples (so percentiles are exact)
// and writes the report. One Node process saturates its event loop somewhere
// around 5,000 sockets; ten workers on a 12-core machine carry 50,000.
const WORKERS = Number(args.workers ?? 0);
const WORKER_INDEX = args.worker === undefined ? null : Number(args.worker);
const isWorker = WORKER_INDEX !== null;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const pct = (v, p) => { if (!v.length) return 0; const s = [...v].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]; };
const mean = (v) => (v.length ? Math.round(v.reduce((a, b) => a + b, 0) / v.length) : 0);

const bots = [];
const stageResults = [];
// Which global player indices this process owns (all of them without --workers).
const joinRefusals = (list) => list.reduce((m, b) => { if (b.joinRefused) m[b.joinRefused] = (m[b.joinRefused] ?? 0) + 1; return m; }, {});
const globalIndex = (m) => (isWorker ? m * WORKERS + WORKER_INDEX : m);
const localTargetFor = (target) => (isWorker ? Math.max(0, Math.floor((target - WORKER_INDEX - 1) / WORKERS) + 1) : target);
let window = null; // the metrics collected during the current hold

const startWindow = () => { window = { actions: 0, actionErrors: 0, latencies: [], hands: new Set(), handsStarted: new Set(), chat: 0, disconnects: 0, health: [], healthRtt: [], genLag: [] }; };

// The generator's own event-loop lag: how late a 100 ms timer fires. If this
// climbs with the player count the laptop, not the server, is the bottleneck,
// and every latency figure above it is suspect.
let lagMark = performance.now();
setInterval(() => { const now = performance.now(); const drift = now - lagMark - 100; lagMark = now; if (window && drift > 0) window.genLag.push(Math.round(drift)); }, 100).unref?.();

async function login(i) {
  const t0 = performance.now();
  const r = await fetch(`${BASE_URL}/api/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ provider: 'guest', deviceId: `ramp-bot-${i + ID_OFFSET}-device-id`, displayName: `LoadBot${i + ID_OFFSET}` }) });
  const ms = performance.now() - t0;
  if (!r.ok) throw new Error(`login ${r.status}`);
  const body = await r.json();
  return { token: body.token, ms };
}

function chooseAction(o) {
  if (!o) return null;
  if (o.canSee && Math.random() < 0.6) return 'see';
  if (o.show && Math.random() < 0.45) return 'show';
  const roll = Math.random();
  if (roll < 0.15) return 'pack';
  if (roll < 0.30 && o.raise) return 'raise';
  if (o.chaal) return 'chaal';
  if (o.raise) return 'raise';
  return 'pack';
}

function createBot(token, rec) {
  const t0 = performance.now();
  const socket = io(BASE_URL, { auth: { token }, transports: ['websocket'], forceNew: true, reconnection: false });
  socket.on('connect', () => {
    rec.connectMs = performance.now() - t0; rec.connected = true;
    socket.emit('room:quickJoin', { bootAmount: BOOT, category: CATEGORY }, (ack) => { rec.joined = Boolean(ack?.ok); rec.joinCode = ack?.code; if (!ack?.ok) rec.joinRefused = ack?.code ?? 'no_ack'; });
  });
  socket.on('connect_error', (e) => { rec.connectError = e.message; });
  socket.on('disconnect', () => { if (window) window.disconnects += 1; rec.connected = false; });
  socket.on('game:handStarted', ({ handId }) => { if (window && handId) window.handsStarted.add(handId); });
  socket.on('game:handEnded', ({ handId }) => { if (window && handId) window.hands.add(handId); });
  socket.on('room:kicked', () => { rec.kicked = (rec.kicked ?? 0) + 1; socket.emit('room:quickJoin', { bootAmount: BOOT, category: CATEGORY }, () => {}); });
  socket.on('game:yourTurn', ({ options }) => {
    setTimeout(() => {
      if (socket.disconnected) return;
      const action = chooseAction(options);
      if (!action) return;
      const started = performance.now();
      if (window) window.actions += 1;
      socket.emit('game:action', { action, actionId: `${rec.i}-${Date.now()}` }, (ack) => {
        if (!window) return;
        window.latencies.push(Math.round(performance.now() - started));
        if (ack && ack.ok === false) window.actionErrors += 1;
      });
    }, 120 + Math.random() * 400);
  });
  const chat = setInterval(() => { if (!socket.disconnected && Math.random() < 0.15) { if (window) window.chat += 1; socket.emit('chat:message', { text: 'nice hand' }); } }, 5000);
  chat.unref?.();
  rec.socket = socket;
  return rec;
}

async function health() {
  const t0 = performance.now();
  try { const r = await fetch(`${BASE_URL}/health`); const j = await r.json(); return { ...j, rtt: Math.round(performance.now() - t0) }; }
  catch (e) { return { ok: false, error: e.message, rtt: Math.round(performance.now() - t0) }; }
}

let runStartedAt = null; let ceilingNote = null; let h0 = null; let finished = false;
const children = [];

const closeBots = async () => {
  for (const b of bots) { try { b.socket?.emit('room:leave', {}, () => {}); } catch {} }
  await sleep(1200);
  for (const b of bots) b.socket?.close();
  await sleep(500);
};

async function finish(reason) {
  if (finished) return; finished = true;
  const hEnd = await health();
  const report = { url: BASE_URL, startedAt: runStartedAt, finishedAt: new Date().toISOString(), stages: STAGES, holdSeconds: HOLD_S, table: { category: CATEGORY, boot: BOOT },
    workers: WORKERS || 1, thresholds: { maxP95Ms: MAX_P95_MS, maxErrorRate: MAX_ERROR_RATE }, ceiling: ceilingNote, results: stageResults, serverBefore: h0, serverAfter: hEnd,
    lastHealthyStage: stageResults.filter((r) => !ceilingNote || r.target !== ceilingNote.target).map((r) => r.target).pop() ?? null,
    stoppedBecause: reason ?? null, connectionsAtStop: WORKERS ? stageResults.at(-1)?.connected ?? null : bots.filter((b) => b.connected).length };
  fs.writeFileSync(OUT, JSON.stringify(report, null, 2));
  console.log(`\nreport written to ${OUT}${reason ? ` (${reason})` : ''}`);
  if (children.length) {
    await Promise.all(children.map((c) => new Promise((resolve) => { c.once('exit', resolve); c.send({ type: 'finish' }); setTimeout(resolve, 8000); })));
  } else {
    await closeBots();
  }
  process.exit(0);
}
process.on('SIGINT', () => finish('interrupted'));
process.on('SIGTERM', () => finish('terminated'));

/** Turns a hold window plus the ramp facts into one stage result (shared by both modes). */
function summarize({ target, stageStart, t0, connected, joined, loginFailures, connectFailures, loginMs, connectMs, w }) {
  const seconds = HOLD_S;
  const lastHealth = w.health[w.health.length - 1] ?? {};
  const errorRate = w.actions ? w.actionErrors / w.actions : 0;
  // Host vital signs, when the server's /health carries them (process block).
  const hp = w.health.filter((h) => h.process);
  const host = hp.length ? {
    samples: hp.length,
    rssMbMax: Math.max(...hp.map((h) => h.process.rssMb)),
    heapUsedMbMax: Math.max(...hp.map((h) => h.process.heapUsedMb)),
    cpuPercentMean: mean(hp.map((h) => h.process.cpuPercent)),
    cpuPercentMax: Math.max(...hp.map((h) => h.process.cpuPercent)),
    loopLagP99MsMax: Math.max(...hp.map((h) => h.process.loopLagP99Ms)),
    loopLagMaxMs: Math.max(...hp.map((h) => h.process.loopLagMaxMs)),
    goroutinesMax: Math.max(...hp.map((h) => h.process.goroutines ?? 0)),
    socketsMax: Math.max(...hp.map((h) => h.sockets ?? 0)),
    socketsMin: Math.min(...hp.map((h) => h.sockets ?? 0)),
    playersMax: Math.max(...hp.map((h) => h.players ?? 0)),
    activeHandsMax: Math.max(...hp.map((h) => h.activeHands ?? 0)),
    activeHandsMean: mean(hp.map((h) => h.activeHands ?? 0)),
    tablesMax: Math.max(...hp.map((h) => h.tables ?? 0)),
    dbWaitingMax: Math.max(...hp.map((h) => h.db?.waiting ?? 0)),
    dbTotalMax: Math.max(...hp.map((h) => h.db?.total ?? 0)),
  } : null;
  return {
    target, connected, joined, loginFailures,
    generatorLag: { p50: pct(w.genLag, 50), p95: pct(w.genLag, 95), max: w.genLag.length ? Math.max(...w.genLag) : 0, samples: w.genLag.length },
    host,
    connectFailures,
    disconnectsDuringHold: w.disconnects,
    login: { p50: pct(loginMs, 50), p95: pct(loginMs, 95), max: loginMs.length ? Math.max(...loginMs) : 0, mean: mean(loginMs) },
    connect: { p50: pct(connectMs, 50), p95: pct(connectMs, 95), max: connectMs.length ? Math.max(...connectMs) : 0 },
    action: { count: w.actions, errors: w.actionErrors, errorRate: Number(errorRate.toFixed(4)), perSec: Number((w.actions / seconds).toFixed(2)), p50: pct(w.latencies, 50), p90: pct(w.latencies, 90), p95: pct(w.latencies, 95), p99: pct(w.latencies, 99), max: w.latencies.length ? Math.max(...w.latencies) : 0, mean: mean(w.latencies) },
    hands: { started: w.handsStarted.size, completed: w.hands.size, perSec: Number((w.hands.size / seconds).toFixed(2)), perMinute: Number((w.hands.size * 60 / seconds).toFixed(1)) },
    chatSent: w.chat,
    healthRtt: { p50: pct(w.healthRtt, 50), p95: pct(w.healthRtt, 95), max: w.healthRtt.length ? Math.max(...w.healthRtt) : 0 },
    server: { players: lastHealth.players, tables: lastHealth.tables, activeHands: lastHealth.activeHands, sockets: lastHealth.sockets, uptime: lastHealth.uptime },
    stageSeconds: Math.round((Date.now() - stageStart) / 1000),
    holdStartedAt: new Date(t0).toISOString(), holdEndedAt: new Date().toISOString(),
    workers: WORKERS || 1,
  };
}

const printStage = (result, w) => {
  const host = result.host; const errorRate = result.action.errorRate;
  const refused = result.joinRefusals && Object.keys(result.joinRefusals).length ? `  not seated: ${Object.entries(result.joinRefusals).map(([k, v]) => `${k}=${v}`).join(',')}` : '';
  console.log(`\n[${result.target}] connected ${result.connected}/${result.target}  joined ${result.joined}${refused}  actions/s ${result.action.perSec}  hands/min ${result.hands.perMinute}  ack p50/p90/p95/p99 ${result.action.p50}/${result.action.p90}/${result.action.p95}/${result.action.p99}ms  errors ${w.actionErrors} (${(errorRate * 100).toFixed(1)}%)  health rtt p95 ${result.healthRtt.p95}ms  server players ${result.server.players} tables ${result.server.tables} sockets ${result.server.sockets}  gen-lag p95 ${result.generatorLag.p95}ms${host ? `  host rss ${host.rssMbMax}MB cpu ${host.cpuPercentMean}% loop p99 ${host.loopLagP99MsMax}ms` : '  (no host metrics in /health)'}`);
};

const stopRules = (result, lastHealth) => {
  const broke = [];
  if (result.action.p95 > MAX_P95_MS) broke.push(`p95 ${result.action.p95}ms > ${MAX_P95_MS}ms`);
  if (result.action.errorRate > MAX_ERROR_RATE) broke.push(`error rate ${(result.action.errorRate * 100).toFixed(1)}% > ${MAX_ERROR_RATE * 100}%`);
  if (result.connected < result.target * 0.9) broke.push(`only ${result.connected}/${result.target} connected`);
  if (!lastHealth.ok) broke.push('health check failed');
  return broke;
};

/** Polls /health for the whole hold, printing progress; returns the samples. */
async function holdAndPoll(target, progress) {
  const health_ = []; const rtt = []; let holdMisses = 0;
  const t0 = Date.now();
  while (Date.now() - t0 < HOLD_S * 1000) {
    const h = await health(); health_.push(h); rtt.push(h.rtt);
    holdMisses = h.ok ? 0 : holdMisses + 1;
    if (holdMisses >= 2) return { health_, rtt, lost: h };
    process.stdout.write(`  [${target}] t+${Math.round((Date.now() - t0) / 1000)}s players=${h.players ?? '?'} tables=${h.tables ?? '?'} sockets=${h.sockets ?? '?'}${progress ? ' ' + progress() : ''}\r`);
    await sleep(5000);
  }
  return { health_, rtt };
}

/**
 * Adds players up to `target` (this process's share of it in worker mode).
 * Between batches it watches for the two signs that the far end has stopped
 * taking connections — a burst of connect failures, or /health not answering —
 * and gives up at once rather than pressing on for the rest of the ramp.
 */
async function addPlayers(target) {
  const loginMs = []; let loginFailures = 0; const startCount = bots.length; let healthMisses = 0; let batches = 0;
  const want = localTargetFor(target);
  while (bots.length < want) {
    const n = Math.min(BATCH, want - bots.length);
    const from = bots.length;
    await Promise.all(Array.from({ length: n }, async (_, k) => {
      const i = globalIndex(from + k); const rec = { i };
      try { const { token, ms } = await login(i); loginMs.push(Math.round(ms)); createBot(token, rec); }
      catch (e) { loginFailures += 1; rec.loginError = e.message; }
      bots.push(rec);
    }));
    await sleep(BATCH_DELAY_MS);
    batches += 1;
    // Every few batches: are the ones we just sent actually getting through?
    if (batches % 4 === 0) {
      const added = bots.slice(startCount);
      const settled = added.filter((b) => b.connected || b.connectError || b.loginError);
      const failed = added.filter((b) => b.connectError || b.loginError).length;
      const h = isWorker ? { ok: true } : await health(); // workers leave /health to the parent
      healthMisses = h.ok ? 0 : healthMisses + 1;
      if ((settled.length >= 50 && failed / Math.max(1, settled.length) > 0.05) || healthMisses >= 2) {
        return { loginMs, loginFailures, aborted: `while ramping to ${target}: ${failed} of the ${settled.length} newest players failed to connect${h.ok ? '' : ' and /health answered ' + (h.error ?? 'not ok')} with ${bots.filter((b) => b.connected).length} sockets open` };
      }
    }
  }
  return { loginMs, loginFailures };
}

// ------------------------------------------------------------ single process
async function main() {
  h0 = await health();
  if (!h0.ok) { console.error(`no server at ${BASE_URL}:`, h0); process.exit(1); }
  console.log(`Ramp test against ${BASE_URL} — stages ${STAGES.join(', ')} — hold ${HOLD_S}s each — table ${CATEGORY} ${BOOT} — ids from ${ID_OFFSET}`);
  console.log(`server before: uptime ${Math.round(h0.uptime)}s players ${h0.players} tables ${h0.tables}\n`);
  runStartedAt = new Date().toISOString();

  for (const target of STAGES) {
    const stageStart = Date.now();
    const { loginMs, loginFailures, aborted } = await addPlayers(target);
    if (aborted) {
      ceilingNote = { target, reasons: [aborted], connectedAtStop: bots.filter((b) => b.connected).length };
      console.log(`\nStopping ${aborted}`);
      await finish('ramp aborted');
      return;
    }
    await sleep(2500); // let the last batch connect and sit
    const connected = bots.filter((b) => b.connected).length;
    const joined = bots.filter((b) => b.joined).length;
    const connectMs = bots.filter((b) => b.connectMs).map((b) => Math.round(b.connectMs));

    startWindow();
    const t0 = Date.now();
    const { health_, rtt, lost } = await holdAndPoll(target, () => `actions=${window.actions} p95=${pct(window.latencies, 95)}ms hands=${window.hands.size}`);
    if (lost) {
      ceilingNote = { target, reasons: [`/health stopped answering during the ${target}-player hold (${lost.error ?? 'not ok'}) with ${bots.filter((b) => b.connected).length} sockets open`] };
      console.log(`\nStopping: ${ceilingNote.reasons[0]}`);
      await finish('health lost during hold');
      return;
    }
    const w = window; window = null; w.health = health_; w.healthRtt = rtt;
    const result = summarize({ target, stageStart, t0, connected, joined, loginFailures, connectFailures: bots.filter((b) => b.connectError).length, loginMs, connectMs, w });
    result.joinRefusals = joinRefusals(bots);
    stageResults.push(result);
    printStage(result, w);
    const broke = stopRules(result, w.health.at(-1) ?? {});
    if (broke.length) { ceilingNote = { target, reasons: broke }; console.log(`\nStopping: ${broke.join('; ')}`); break; }
  }
  await finish(null);
}

// ------------------------------------------------------------------- worker
// A worker owns every player whose index ≡ WORKER_INDEX (mod WORKERS). It only
// does what the parent tells it and answers with raw numbers; the parent merges.
async function workerMain() {
  const reply = (msg) => process.send(msg);
  process.on('message', async (msg) => {
    try {
      if (msg.type === 'ramp') {
        const r = await addPlayers(msg.target);
        reply({ type: 'ramped', target: msg.target, loginMs: r.loginMs, loginFailures: r.loginFailures, aborted: r.aborted ?? null,
          connected: bots.filter((b) => b.connected).length, joined: bots.filter((b) => b.joined).length,
          connectFailures: bots.filter((b) => b.connectError).length, connectMs: bots.filter((b) => b.connectMs).map((b) => Math.round(b.connectMs)), joinRefusals: joinRefusals(bots) });
      } else if (msg.type === 'hold') {
        startWindow();
        await sleep(msg.seconds * 1000);
        const w = window; window = null;
        reply({ type: 'held', actions: w.actions, actionErrors: w.actionErrors, latencies: w.latencies, hands: [...w.hands], handsStarted: [...w.handsStarted], chat: w.chat, disconnects: w.disconnects, genLag: w.genLag,
          connected: bots.filter((b) => b.connected).length });
      } else if (msg.type === 'finish') {
        await closeBots();
        process.exit(0);
      }
    } catch (e) { reply({ type: 'error', error: e.message }); }
  });
  reply({ type: 'ready', worker: WORKER_INDEX });
}

// ------------------------------------------------------------------- parent
async function parentMain() {
  h0 = await health();
  if (!h0.ok) { console.error(`no server at ${BASE_URL}:`, h0); process.exit(1); }
  console.log(`Ramp test against ${BASE_URL} — stages ${STAGES.join(', ')} — hold ${HOLD_S}s each — table ${CATEGORY} ${BOOT} — ids from ${ID_OFFSET} — ${WORKERS} worker processes`);
  console.log(`server before: uptime ${Math.round(h0.uptime)}s players ${h0.players} tables ${h0.tables}\n`);
  runStartedAt = new Date().toISOString();

  const self = fileURLToPath(import.meta.url);
  const passthrough = process.argv.slice(2).filter((a, i, all) => !(a === '--workers' || all[i - 1] === '--workers'));
  const ask = (child, msg, type) => new Promise((resolve, reject) => {
    const onMsg = (m) => { if (m.type === type) { child.off('message', onMsg); resolve(m); } else if (m.type === 'error') { child.off('message', onMsg); reject(new Error(m.error)); } };
    child.on('message', onMsg);
    child.once('exit', (code) => { if (!finished) reject(new Error(`worker exited with ${code}`)); });
    child.send(msg);
  });
  for (let k = 0; k < WORKERS; k++) {
    const child = fork(self, [...passthrough, '--workers', String(WORKERS), '--worker', String(k)], { stdio: ['ignore', 'inherit', 'inherit', 'ipc'] });
    children.push(child);
  }
  await Promise.all(children.map((c) => new Promise((resolve) => c.once('message', resolve))));

  for (const target of STAGES) {
    const stageStart = Date.now();
    const ramped = await Promise.all(children.map((c) => ask(c, { type: 'ramp', target }, 'ramped')));
    const aborted = ramped.find((r) => r.aborted);
    const connectedNow = () => ramped.reduce((n, r) => n + r.connected, 0);
    if (aborted) {
      ceilingNote = { target, reasons: [aborted.aborted], connectedAtStop: connectedNow() };
      console.log(`\nStopping ${aborted.aborted}`);
      await finish('ramp aborted');
      return;
    }
    await sleep(2500);
    const connected = connectedNow();
    const joined = ramped.reduce((n, r) => n + r.joined, 0);
    const loginFailures = ramped.reduce((n, r) => n + r.loginFailures, 0);
    const connectFailures = ramped.reduce((n, r) => n + r.connectFailures, 0);
    const loginMs = ramped.flatMap((r) => r.loginMs);
    const connectMs = ramped.flatMap((r) => r.connectMs);
    const refusals = ramped.reduce((m, r) => { for (const [k, v] of Object.entries(r.joinRefusals ?? {})) m[k] = (m[k] ?? 0) + v; return m; }, {});

    const t0 = Date.now();
    const holds = Promise.all(children.map((c) => ask(c, { type: 'hold', seconds: HOLD_S }, 'held')));
    const { health_, rtt, lost } = await holdAndPoll(target, null);
    if (lost) {
      ceilingNote = { target, reasons: [`/health stopped answering during the ${target}-player hold (${lost.error ?? 'not ok'}) with ${connected} sockets open`] };
      console.log(`\nStopping: ${ceilingNote.reasons[0]}`);
      await finish('health lost during hold');
      return;
    }
    const held = await holds;
    const w = {
      actions: held.reduce((n, h) => n + h.actions, 0), actionErrors: held.reduce((n, h) => n + h.actionErrors, 0),
      latencies: held.flatMap((h) => h.latencies), hands: new Set(held.flatMap((h) => h.hands)), handsStarted: new Set(held.flatMap((h) => h.handsStarted)),
      chat: held.reduce((n, h) => n + h.chat, 0), disconnects: held.reduce((n, h) => n + h.disconnects, 0), genLag: held.flatMap((h) => h.genLag),
      health: health_, healthRtt: rtt,
    };
    const stillConnected = held.reduce((n, h) => n + h.connected, 0);
    const result = summarize({ target, stageStart, t0, connected, joined, loginFailures, connectFailures, loginMs, connectMs, w });
    result.connectedAfterHold = stillConnected;
    result.joinRefusals = refusals;
    stageResults.push(result);
    printStage(result, w);
    const broke = stopRules(result, w.health.at(-1) ?? {});
    if (broke.length) { ceilingNote = { target, reasons: broke }; console.log(`\nStopping: ${broke.join('; ')}`); break; }
  }
  await finish(null);
}

(isWorker ? workerMain() : WORKERS > 0 ? parentMain() : main()).catch((e) => { console.error(e); process.exit(1); });
