#!/usr/bin/env node
/**
 * Byte-level parity: drives ONE fixed scenario against two servers and diffs
 * what each client socket heard.
 *
 *   node tools/parity-diff.mjs --a node --b go --bin ../go-server/gameplay   # spawn both, diff, tear down
 *   node tools/parity-diff.mjs --a node --b node                             # prove the normaliser (empty diff)
 *   node tools/parity-diff.mjs --a http://127.0.0.1:3000 --b http://127.0.0.1:3001 [--schema-a s --schema-b s]
 *   options: --out <dir> (write raw + normalised recordings), --keep, --verbose
 *
 * The scenario (deterministic apart from the shuffled cards): three guests log
 * in, open sockets, quick-join one seen table at boot 100; the hand deals
 * (dealer seat 0, first turn seat 1); seat 1 sees and chaals 200, seat 2 chaals
 * 100, seat 0 packs, seat 1 raises 400, seat 2 chaals 200, seat 1 packs — so
 * seat 2 takes the pot without a showdown and nothing depends on the cards;
 * seat 2 chats; everyone leaves in seat order. Every request is awaited and
 * the streams are left to settle between steps.
 *
 * Normalisation (spec-tests-tools.md §11.3): uuids → <uuid-N> by first
 * appearance in a fixed traversal order (so identity relationships still
 * diff), room codes → <code>, JWTs → <jwt>, epoch-ms fields → <ts>, card
 * arrays → <cards:N>, a `timeoutMs` that is not the configured clock →
 * <remaining>; consecutive identical room:state per socket are collapsed.
 * Key order is preserved — the diff runs on serialised JSON.
 *
 * Exit status 0 when the normalised recordings are identical, 1 on any
 * difference (a unified diff is printed), 2 on a usage or scenario error.
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import pg from 'pg';
import { io as connect } from 'socket.io-client';
import {
  DEFAULT_DATABASE_URL, dropSchema, resolveGoBinary, startServer,
} from '../test/parity/lib/launch.mjs';

// ------------------------------------------------------------------ args

const args = {};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i += 1) {
  const key = argv[i];
  if (!key.startsWith('--')) continue;
  const name = key.slice(2);
  const next = argv[i + 1];
  if (next === undefined || next.startsWith('--')) args[name] = true;
  else { args[name] = next; i += 1; }
}
if (args.help || !args.a || !args.b) {
  console.log(fs.readFileSync(new URL(import.meta.url), 'utf8').split('\n').slice(1, 9).join('\n'));
  process.exit(args.help ? 0 : 2);
}

const databaseUrl = args.db ?? process.env.DATABASE_URL ?? DEFAULT_DATABASE_URL;
const keep = Boolean(args.keep);
const verbose = Boolean(args.verbose);
const outDir = args.out ? path.resolve(args.out) : null;
const logDir = path.join(os.tmpdir(), `king-teenpatti-parity-diff-${process.pid}`);

/** The environment both spawned servers run with: long clocks, a slow deal (so three joins land before it), any stake. */
const DIFF_ENV = {
  TURN_TIMEOUT_MS: '60000',
  SIDESHOW_TIMEOUT_MS: '60000',
  NEXT_HAND_DELAY_MS: '3000',
  CONSOLIDATE_INTERVAL_MS: '600000',
  RECONNECT_GRACE_MS: '400',
  TABLE_STAKES: '',
  LOBBY_TABLES: '',
};

const log = (message) => process.stdout.write(`${message}\n`);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// -------------------------------------------------------------- servers

/** `spec` is a URL or a target name (node|go). */
const resolveSide = async (label, spec, schemaArg) => {
  if (/^https?:\/\//.test(spec)) {
    return { label, baseUrl: spec.replace(/\/+$/, ''), schema: schemaArg ?? null, stop: async () => {}, spawned: false };
  }
  if (!['node', 'go'].includes(spec)) throw new Error(`--${label} must be a URL, "node" or "go" (got ${spec})`);
  const server = await startServer({
    target: spec, bin: spec === 'go' ? resolveGoBinary(args.bin) : null, env: DIFF_ENV, databaseUrl, logDir, name: label, verbose,
  });
  log(`${label}: ${spec} server ${server.baseUrl} schema ${server.schema} (log ${server.logFile})`);
  return { label, baseUrl: server.baseUrl, schema: server.schema, stop: server.stop, spawned: true, target: spec };
};

// ------------------------------------------------------------- recording

const openRecorder = (baseUrl, token, name) => new Promise((resolve, reject) => {
  const socket = connect(baseUrl, { auth: { token }, transports: ['websocket'], forceNew: true, reconnection: false });
  const stream = [];
  socket.onAny((event, payload) => stream.push({ event, payload }));
  const timer = setTimeout(() => reject(new Error(`${name}: connect timed out`)), 5000);
  socket.once('connect_error', (error) => { clearTimeout(timer); reject(error); });
  socket.once('connect', () => {
    clearTimeout(timer);
    resolve({
      name,
      socket,
      stream,
      emit: (event, payload) => new Promise((done) => socket.emit(event, payload, (ack) => {
        stream.push({ event: `ack:${event}`, payload: ack });
        done(ack);
      })),
      last: (event) => [...stream].reverse().find((e) => e.event === event)?.payload,
      state: () => [...stream].reverse().find((e) => e.event === 'room:state' || e.event === 'room:joined')?.payload,
    });
  });
});

/** Waits until no socket has recorded anything for `quietMs` (bounded by `maxMs`). */
const settle = async (sockets, quietMs = 200, maxMs = 5000) => {
  const started = Date.now();
  let lengths = sockets.map((s) => s.stream.length);
  let quietSince = Date.now();
  while (Date.now() - started < maxMs) {
    await sleep(25);
    const now = sockets.map((s) => s.stream.length);
    if (now.some((n, i) => n !== lengths[i])) {
      lengths = now;
      quietSince = Date.now();
    } else if (Date.now() - quietSince >= quietMs) {
      return;
    }
  }
};

const waitFor = async (socket, event, predicate = () => true, timeoutMs = 8000) => {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const hit = socket.stream.find((e) => e.event === event && predicate(e.payload));
    if (hit) return hit.payload;
    await sleep(20);
  }
  throw new Error(`${socket.name}: timed out waiting for ${event} (seen: ${socket.stream.map((e) => e.event).join(', ')})`);
};

const waitState = async (socket, predicate, timeoutMs = 8000) => {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const now = socket.state();
    if (now && predicate(now)) return now;
    await sleep(20);
  }
  throw new Error(`${socket.name}: timed out waiting for a snapshot (latest: ${JSON.stringify(socket.state())?.slice(0, 200)})`);
};

const expectOk = (ack, what) => {
  if (!ack || ack.ok !== true) throw new Error(`${what} was refused: ${JSON.stringify(ack)}`);
  return ack;
};

/** Runs the scripted scenario against one server; returns the raw recording. */
const runScenario = async (side) => {
  const { baseUrl } = side;
  const rest = [];
  const http = async (name, method, route, { body, token } = {}) => {
    const init = { method, headers: {} };
    if (token) init.headers.authorization = `Bearer ${token}`;
    if (body !== undefined) { init.body = JSON.stringify(body); init.headers['content-type'] = 'application/json'; }
    const response = await fetch(`${baseUrl}${route}`, init);
    const text = await response.text();
    let parsed;
    try { parsed = JSON.parse(text); } catch { parsed = text; }
    rest.push({ event: `${name} ${method} ${route}`, payload: { status: response.status, body: parsed } });
    return parsed;
  };

  const players = [];
  for (let i = 0; i < 3; i += 1) {
    const login = await http(`login-p${i}`, 'POST', '/api/auth/login', {
      body: { provider: 'guest', deviceId: `parity-diff-device-p${i}`, displayName: `DiffP${i}` },
    });
    if (!login.token) throw new Error(`login p${i} failed: ${JSON.stringify(login)}`);
    players.push(login);
  }
  const sockets = [];
  for (let i = 0; i < 3; i += 1) sockets.push(await openRecorder(baseUrl, players[i].token, `socket${i}`));
  const [s0, s1, s2] = sockets;
  for (const s of sockets) await waitFor(s, 'session:ready');
  await settle(sockets);

  // Everybody sits at one seen table at boot 100 (join order = seat order).
  const joins = [];
  for (const s of sockets) {
    joins.push(expectOk(await s.emit('room:quickJoin', { bootAmount: 100, category: 'seen' }), `${s.name} quickJoin`));
    await settle(sockets);
  }
  if (new Set(joins.map((j) => j.roomId)).size !== 1) throw new Error('the three players did not land on one table');

  // The deal: three participants, seat 1 on turn.
  for (const s of sockets) await waitFor(s, 'game:handStarted', (p) => p.participants.length === 3, 10000);
  for (const s of sockets) await waitState(s, (v) => v.state === 'betting' && v.turn?.seatIndex === 1);
  await settle(sockets);
  const turnOf = (seat) => Promise.all(sockets.map((s) => waitState(s, (v) => v.state === 'betting' && v.turn?.seatIndex === seat)));

  const move = async (socket, payload, what) => {
    expectOk(await socket.emit('game:action', payload), what);
    await settle(sockets);
  };
  await move(s1, { action: 'see' }, 'p1 see');
  await move(s1, { action: 'chaal', amount: 200, actionId: 'parity-diff-1' }, 'p1 chaal 200');
  await turnOf(2);
  await move(s2, { action: 'chaal', amount: 100, actionId: 'parity-diff-2' }, 'p2 chaal 100');
  await turnOf(0);
  await move(s0, { action: 'pack', actionId: 'parity-diff-3' }, 'p0 pack');
  await turnOf(1);
  await move(s1, { action: 'raise', amount: 400, actionId: 'parity-diff-4' }, 'p1 raise 400');
  await turnOf(2);
  await move(s2, { action: 'chaal', amount: 200, actionId: 'parity-diff-5' }, 'p2 chaal 200');
  await turnOf(1);
  await move(s1, { action: 'pack', actionId: 'parity-diff-6' }, 'p1 pack');
  for (const s of sockets) await waitFor(s, 'game:handEnded');
  await settle(sockets);

  expectOk(await s2.emit('chat:message', { text: 'gg — nice hand {all} "wp"' }), 'p2 chat');
  await settle(sockets);
  await http('me-p2', 'GET', '/api/auth/me', { token: players[2].token });
  await http('me-p1', 'GET', '/api/auth/me', { token: players[1].token });

  // Everyone leaves in seat order, before the next deal.
  for (const s of sockets) {
    expectOk(await s.emit('room:leave', {}), `${s.name} leave`);
    await settle(sockets);
  }
  await http('me-p0', 'GET', '/api/auth/me', { token: players[0].token });
  for (const s of sockets) s.socket.disconnect();

  const config = s0.stream.find((e) => e.event === 'session:ready')?.payload?.config ?? {};
  return {
    config,
    streams: {
      rest,
      socket0: s0.stream,
      socket1: s1.stream,
      socket2: s2.stream,
    },
  };
};

// ------------------------------------------------------------ normalise

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const JWT = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;
const ROOM_CODE = /^[A-Z2-9]{6}$/;
const CARD = /^[2-9TJQKA][shdc]$/;
const TIMESTAMP_KEYS = new Set(['at', 'createdAt', 'lastLoginAt', 'deadline', 'startsAt', 'expiresAt', 'nextHandAt', 'serverTime', 'updatedAt', 'bonusReadyAt', 'readyAt']);

const makeNormaliser = (config) => {
  const uuids = new Map();
  const uuid = (value) => {
    if (!uuids.has(value)) uuids.set(value, `<uuid-${uuids.size + 1}>`);
    return uuids.get(value);
  };
  const clocks = new Set([config.turnTimeoutMs, config.sideshowTimeoutMs].filter((n) => typeof n === 'number'));
  const walk = (value, key) => {
    if (Array.isArray(value)) {
      if (value.length > 0 && value.every((v) => typeof v === 'string' && CARD.test(v))) return `<cards:${value.length}>`;
      return value.map((v) => walk(v, key));
    }
    if (value && typeof value === 'object') {
      // Keys are sorted: JSON key order is not part of the wire contract (DECISIONS.md §1).
      const out = {};
      for (const [k, v] of Object.entries(value).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) out[k] = walk(v, k);
      return out;
    }
    if (typeof value === 'string') {
      if (UUID.test(value)) return uuid(value);
      if (key === 'token' && JWT.test(value)) return '<jwt>';
      if (key === 'code' && ROOM_CODE.test(value)) return '<code>';
      return value;
    }
    if (typeof value === 'number') {
      if (TIMESTAMP_KEYS.has(key) && value > 1e12) return '<ts>';
      if (key === 'timeoutMs' && !clocks.has(value)) return '<remaining>';
      if (key === 'uptime') return '<uptime>';
      return value;
    }
    return value;
  };
  return walk;
};

/** Normalises one recording into { streamName: [line, ...] }. */
const normalise = (recording) => {
  const walk = makeNormaliser(recording.config);
  const out = {};
  for (const [name, stream] of Object.entries(recording.streams)) {
    const lines = [];
    let previous = null;
    for (const entry of stream) {
      const line = `${entry.event} ${JSON.stringify(walk(entry.payload, entry.event))}`;
      // Consecutive identical room:state snapshots are one snapshot (DECISIONS.md §1).
      if (entry.event === 'room:state' && line === previous) continue;
      lines.push(line);
      previous = line;
    }
    out[name] = lines;
  }
  return out;
};

// -------------------------------------------------------------- database

const dumpDatabase = async (schema) => {
  if (!schema) return null;
  const client = new pg.Client({ connectionString: databaseUrl, options: `-c search_path=${schema},public` });
  pg.types.setTypeParser(20, (v) => Number(v));
  await client.connect();
  try {
    const users = await client.query(
      `SELECT display_name, chips, hands_played, hands_won, hands_lost, hands_left_mid, total_winnings, biggest_pot
         FROM users WHERE display_name LIKE 'DiffP%' ORDER BY display_name`,
    );
    const ledger = await client.query(
      `SELECT u.display_name, l.reason, l.delta, l.balance,
              CASE WHEN l.action_id LIKE 'parity-diff-%' THEN l.action_id
                   WHEN l.action_id LIKE '%:boot:%' THEN '<hand>:boot:<user>'
                   WHEN l.action_id LIKE '%:settle:%' THEN '<hand>:settle:<user>'
                   WHEN l.action_id IS NULL THEN NULL ELSE '<uuid>' END AS action_id
         FROM chip_ledger l JOIN users u ON u.id = l.user_id
        WHERE u.display_name LIKE 'DiffP%' ORDER BY u.display_name, l.id`,
    );
    const hands = await client.query('SELECT hand_no, pot, win_reason, boot_amount, jsonb_array_length(summary_json) AS seats FROM hands ORDER BY hand_no');
    const pots = await client.query('SELECT boot_amount, amount, closed_at IS NOT NULL AS closed FROM pots ORDER BY opened_at');
    return {
      users: users.rows, ledger: ledger.rows, hands: hands.rows, pots: pots.rows,
    };
  } finally {
    await client.end();
  }
};

// ------------------------------------------------------------------ diff

/** Unified diff of two line arrays (LCS-based; the inputs are small). */
const unifiedDiff = (a, b, labelA, labelB) => {
  const n = a.length;
  const m = b.length;
  const lcs = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
  for (let i = n - 1; i >= 0; i -= 1) {
    for (let j = m - 1; j >= 0; j -= 1) {
      lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }
  const ops = [];
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) { ops.push([' ', a[i]]); i += 1; j += 1; } else if (lcs[i + 1][j] >= lcs[i][j + 1]) { ops.push(['-', a[i]]); i += 1; } else { ops.push(['+', b[j]]); j += 1; }
  }
  while (i < n) { ops.push(['-', a[i]]); i += 1; }
  while (j < m) { ops.push(['+', b[j]]); j += 1; }
  const changed = ops.some(([op]) => op !== ' ');
  if (!changed) return { changed, text: '' };
  const lines = [`--- ${labelA}`, `+++ ${labelB}`];
  for (let k = 0; k < ops.length; k += 1) {
    const [op, line] = ops[k];
    const nearChange = ops.slice(Math.max(0, k - 2), k + 3).some(([o]) => o !== ' ');
    if (op !== ' ' || nearChange) lines.push(`${op} ${line.length > 400 ? `${line.slice(0, 400)}…` : line}`);
    else if (lines.at(-1) !== '  …') lines.push('  …');
  }
  return { changed, text: lines.join('\n') };
};

// ------------------------------------------------------------------ main

const sides = [];
let exitCode = 0;
try {
  const a = await resolveSide('a', args.a, args['schema-a']);
  sides.push(a);
  const b = await resolveSide('b', args.b, args['schema-b']);
  sides.push(b);

  const recordings = {};
  const dumps = {};
  for (const side of [a, b]) {
    log(`\nrunning the scenario against ${side.label} (${side.baseUrl})`);
    recordings[side.label] = await runScenario(side);
    await sleep(300);
    dumps[side.label] = await dumpDatabase(side.schema);
  }

  const normalised = { a: normalise(recordings.a), b: normalise(recordings.b) };
  if (outDir) {
    fs.mkdirSync(outDir, { recursive: true });
    for (const label of ['a', 'b']) {
      fs.writeFileSync(path.join(outDir, `${label}-raw.json`), JSON.stringify(recordings[label], null, 2));
      for (const [stream, lines] of Object.entries(normalised[label])) {
        fs.writeFileSync(path.join(outDir, `${label}-${stream}.txt`), `${lines.join('\n')}\n`);
      }
      if (dumps[label]) fs.writeFileSync(path.join(outDir, `${label}-db.json`), JSON.stringify(dumps[label], null, 2));
    }
    log(`recordings written to ${outDir}`);
  }

  log('');
  let differences = 0;
  for (const stream of Object.keys(normalised.a)) {
    const { changed, text } = unifiedDiff(normalised.a[stream], normalised.b[stream] ?? [], `a/${stream}`, `b/${stream}`);
    if (changed) {
      differences += 1;
      log(`### ${stream}: DIFFERENT`);
      log(text);
      log('');
    } else {
      log(`### ${stream}: identical (${normalised.a[stream].length} entries)`);
    }
  }
  if (dumps.a && dumps.b) {
    const da = JSON.stringify(dumps.a, null, 1).split('\n');
    const db = JSON.stringify(dumps.b, null, 1).split('\n');
    const { changed, text } = unifiedDiff(da, db, 'a/db', 'b/db');
    if (changed) { differences += 1; log('### database: DIFFERENT'); log(text); } else log(`### database: identical (${dumps.a.ledger.length} ledger rows for the three players)`);
  } else {
    log('### database: skipped (no schema known for one side — pass --schema-a/--schema-b)');
  }
  log('');
  log(differences === 0 ? 'PARITY: the normalised recordings are identical.' : `PARITY: ${differences} stream(s) differ.`);
  exitCode = differences === 0 ? 0 : 1;
} catch (error) {
  log(`parity-diff failed: ${error.stack ?? error.message}`);
  exitCode = 2;
} finally {
  for (const side of sides) {
    await side.stop();
    if (side.spawned && !keep) await dropSchema(side.schema, databaseUrl).catch(() => {});
    else if (side.spawned) log(`kept schema ${side.schema}`);
  }
}
process.exit(exitCode);
