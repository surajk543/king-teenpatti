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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const pct = (v, p) => { if (!v.length) return 0; const s = [...v].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]; };
const mean = (v) => (v.length ? Math.round(v.reduce((a, b) => a + b, 0) / v.length) : 0);

const bots = [];
const stageResults = [];
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
    socket.emit('room:quickJoin', { bootAmount: BOOT, category: CATEGORY }, (ack) => { rec.joined = Boolean(ack?.ok); rec.joinCode = ack?.code; });
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
async function finish(reason) {
  if (finished) return; finished = true;
  const hEnd = await health();
  const report = { url: BASE_URL, startedAt: runStartedAt, finishedAt: new Date().toISOString(), stages: STAGES, holdSeconds: HOLD_S, table: { category: CATEGORY, boot: BOOT },
    thresholds: { maxP95Ms: MAX_P95_MS, maxErrorRate: MAX_ERROR_RATE }, ceiling: ceilingNote, results: stageResults, serverBefore: h0, serverAfter: hEnd,
    lastHealthyStage: stageResults.filter((r) => !ceilingNote || r.target !== ceilingNote.target).map((r) => r.target).pop() ?? null,
    stoppedBecause: reason ?? null, connectionsAtStop: bots.filter((b) => b.connected).length };
  fs.writeFileSync(OUT, JSON.stringify(report, null, 2));
  console.log(`\nreport written to ${OUT}${reason ? ` (${reason})` : ''}`);
  for (const b of bots) { try { b.socket?.emit('room:leave', {}, () => {}); } catch {} }
  await sleep(1200);
  for (const b of bots) b.socket?.close();
  await sleep(500);
  process.exit(0);
}
process.on('SIGINT', () => finish('interrupted'));
process.on('SIGTERM', () => finish('terminated'));

/**
 * Adds players up to `target`. Between batches it watches for the two signs
 * that the far end has stopped taking connections — a burst of connect
 * failures, or /health not answering — and gives up at once rather than
 * pressing on for the rest of the ramp.
 */
async function addPlayers(target) {
  const loginMs = []; let loginFailures = 0; const startCount = bots.length; let healthMisses = 0; let batches = 0;
  while (bots.length < target) {
    const n = Math.min(BATCH, target - bots.length);
    const from = bots.length;
    await Promise.all(Array.from({ length: n }, async (_, k) => {
      const i = from + k; const rec = { i };
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
      const h = await health();
      healthMisses = h.ok ? 0 : healthMisses + 1;
      if ((settled.length >= 50 && failed / Math.max(1, settled.length) > 0.05) || healthMisses >= 2) {
        return { loginMs, loginFailures, aborted: `while ramping to ${target}: ${failed} of the ${settled.length} newest players failed to connect${h.ok ? '' : ' and /health answered ' + (h.error ?? 'not ok')} with ${bots.filter((b) => b.connected).length} sockets open` };
      }
    }
  }
  return { loginMs, loginFailures };
}

async function main() {
  h0 = await health();
  if (!h0.ok) { console.error(`no server at ${BASE_URL}:`, h0); process.exit(1); }
  console.log(`Ramp test against ${BASE_URL} — stages ${STAGES.join(', ')} — hold ${HOLD_S}s each — table ${CATEGORY} ${BOOT} — ids from ${ID_OFFSET}`);
  console.log(`server before: uptime ${Math.round(h0.uptime)}s players ${h0.players} tables ${h0.tables}\n`);
  runStartedAt = new Date().toISOString();
  let ceiling = null;

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
    const t0 = Date.now(); let samples = 0;
    let holdMisses = 0;
    while (Date.now() - t0 < HOLD_S * 1000) {
      const h = await health(); window.health.push(h); window.healthRtt.push(h.rtt); samples += 1;
      holdMisses = h.ok ? 0 : holdMisses + 1;
      if (holdMisses >= 2) {
        ceilingNote = { target, reasons: [`/health stopped answering during the ${target}-player hold (${h.error ?? 'not ok'}) with ${bots.filter((b) => b.connected).length} sockets open`] };
        console.log(`\nStopping: ${ceilingNote.reasons[0]}`);
        await finish('health lost during hold');
        return;
      }
      process.stdout.write(`  [${target}] t+${Math.round((Date.now() - t0) / 1000)}s players=${h.players ?? '?'} tables=${h.tables ?? '?'} actions=${window.actions} p95=${pct(window.latencies, 95)}ms hands=${window.hands.size}\r`);
      await sleep(5000);
    }
    const w = window; window = null;
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
      socketsMax: Math.max(...hp.map((h) => h.sockets ?? 0)),
      dbWaitingMax: Math.max(...hp.map((h) => h.db?.waiting ?? 0)),
      dbTotalMax: Math.max(...hp.map((h) => h.db?.total ?? 0)),
    } : null;
    const result = {
      target, connected, joined, loginFailures,
      generatorLag: { p50: pct(w.genLag, 50), p95: pct(w.genLag, 95), max: Math.max(0, ...w.genLag), samples: w.genLag.length },
      host,
      connectFailures: bots.filter((b) => b.connectError).length,
      disconnectsDuringHold: w.disconnects,
      login: { p50: pct(loginMs, 50), p95: pct(loginMs, 95), max: Math.max(0, ...loginMs), mean: mean(loginMs) },
      connect: { p50: pct(connectMs, 50), p95: pct(connectMs, 95), max: Math.max(0, ...connectMs) },
      action: { count: w.actions, errors: w.actionErrors, errorRate: Number(errorRate.toFixed(4)), perSec: Number((w.actions / seconds).toFixed(2)), p50: pct(w.latencies, 50), p95: pct(w.latencies, 95), p99: pct(w.latencies, 99), max: Math.max(0, ...w.latencies), mean: mean(w.latencies) },
      hands: { started: w.handsStarted.size, completed: w.hands.size, perSec: Number((w.hands.size / seconds).toFixed(2)), perMinute: Number((w.hands.size * 60 / seconds).toFixed(1)) },
      chatSent: w.chat,
      healthRtt: { p50: pct(w.healthRtt, 50), p95: pct(w.healthRtt, 95), max: Math.max(0, ...w.healthRtt) },
      server: { players: lastHealth.players, tables: lastHealth.tables, activeHands: lastHealth.activeHands, uptime: lastHealth.uptime },
      stageSeconds: Math.round((Date.now() - stageStart) / 1000),
    };
    stageResults.push(result);
    console.log(`\n[${target}] connected ${connected}/${target}  joined ${joined}  actions/s ${result.action.perSec}  hands/min ${result.hands.perMinute}  ack p50/p95/p99 ${result.action.p50}/${result.action.p95}/${result.action.p99}ms  errors ${w.actionErrors} (${(errorRate * 100).toFixed(1)}%)  health rtt p95 ${result.healthRtt.p95}ms  server players ${lastHealth.players} tables ${lastHealth.tables}  gen-lag p95 ${result.generatorLag.p95}ms${host ? `  host rss ${host.rssMbMax}MB cpu ${host.cpuPercentMean}% loop p99 ${host.loopLagP99MsMax}ms` : '  (no host metrics in /health)'}`);

    const broke = [];
    if (result.action.p95 > MAX_P95_MS) broke.push(`p95 ${result.action.p95}ms > ${MAX_P95_MS}ms`);
    if (errorRate > MAX_ERROR_RATE) broke.push(`error rate ${(errorRate * 100).toFixed(1)}% > ${MAX_ERROR_RATE * 100}%`);
    if (connected < target * 0.9) broke.push(`only ${connected}/${target} connected`);
    if (!lastHealth.ok) broke.push('health check failed');
    if (broke.length) { ceiling = { target, reasons: broke }; ceilingNote = ceiling; console.log(`\nStopping: ${broke.join('; ')}`); break; }
  }
  await finish(null);
}

main().catch((e) => { console.error(e); process.exit(1); });
