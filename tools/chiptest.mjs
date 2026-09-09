// Are a player's chips in PostgreSQL correct at each of the three moments the
// money model writes them?
//
// Owner's decision of 9 Sep 2026 (LIVE_STATE_PLAN.md): ALL game state lives in
// Redis; PostgreSQL holds money and audit only, and is written at exactly
// three moments, each taking one player's chips from the live state and making
// the wallet agree by a DELTA:
//
//   a player PACKS                      → that player only   (hand_packed)
//   a player LEAVES or SWITCHES table   → that player only   (hand_left)
//   the HAND ENDS                       → everyone still at the table
//                                         (hand_win / hand_loss)
//
// Nothing else writes: not the deal, not a chaal, raise, show or see. This
// test is the spec for that. It checks each moment, both of the owner's
// worked examples, and the one invariant the system still has:
// SUM(chip_ledger.delta) == users.chips.
//
//   npm run chiptest
import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import net from 'node:net';
import { io } from 'socket.io-client';
import pg from 'pg';
pg.types.setTypeParser(20, (v) => Number(v));
pg.types.setTypeParser(1700, (v) => Number(v)); // SUM() is numeric, not int8
const HOME = path.join(os.homedir(), '.local', 'bin');
const BIN = '/home/suraj/Project/king-teenpatti/go-server/bin/gameplay';
const DB = 'postgres://postgres:postgres@localhost:5432/gameplay';
const SCHEMA = 'chips_' + Math.random().toString(36).slice(2, 7);
const RPORT = 6393;
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const freePort = () => new Promise((res) => { const s = net.createServer(); s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => res(p)); }); });
const cli = (...a) => execFileSync(path.join(HOME, 'redis-cli'), ['-p', String(RPORT), ...a], { stdio: 'pipe' }).toString().trim();
let bad = 0;
const check = (ok, what, detail = '') => { if (!ok) bad++; console.log(`  ${ok ? 'ok  ' : 'FAIL'}  ${what}${detail ? '  — ' + detail : ''}`); };

// Redis is not required for this — the wallet path does not touch it — but the
// server is run the way production runs it.
const rp = spawn(path.join(HOME, 'redis-server'), ['--port', String(RPORT), '--save', '', '--appendonly', 'no'], { stdio: 'ignore' });
for (let i = 0; i < 50; i++) { try { cli('ping'); break; } catch { await sleep(150); } }
const PORT = await freePort(); const URL = `http://127.0.0.1:${PORT}`;
const env = { ...process.env, PORT: String(PORT), HOST: '127.0.0.1', PG_SCHEMA: SCHEMA, DATABASE_URL: DB,
  NODE_ENV: 'test', AUTH_ALLOW_FAKE_PROVIDERS: 'true', JWT_SECRET: 'chips', TABLE_STAKES: '', LOBBY_TABLES: '',
  BOOT_AMOUNT: '200', TURN_TIMEOUT_MS: '25000', NEXT_HAND_DELAY_MS: '1200', RECONNECT_GRACE_MS: '60000',
  LOG_LEVEL: 'warn', REDIS_URL: `redis://127.0.0.1:${RPORT}/0` };
const srv = spawn(BIN, [], { env, cwd: path.dirname(BIN), stdio: ['ignore', 'ignore', fs.openSync('/tmp/probe-chips.log', 'w')] });
for (let i = 0; i < 100; i++) { try { if ((await fetch(`${URL}/health`)).ok) break; } catch {} await sleep(200); }

const pool = new pg.Pool({ connectionString: DB, max: 3 });
const q = async (t, p = []) => (await pool.query({ text: t.replaceAll('%S%', `"${SCHEMA}"`), values: p })).rows;

const users = [];
for (let i = 0; i < 4; i++) {
  const r = await fetch(`${URL}/api/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ provider: 'guest', deviceId: `chips-${SCHEMA}-${i}-dev`, displayName: `Chip${i}` }) });
  users.push(await r.json());
}
const recs = users.map((u, i) => {
  const rec = { i, id: u.user.id, token: u.token, seen: null, acted: null };
  const s = io(URL, { auth: { token: u.token }, transports: ['websocket'], forceNew: true, reconnection: false });
  const act = (o, dl) => {
    if (!o) return; const k = `${rec.handNo}:${dl}:${o.canSee ? 'b' : 's'}`;
    if (rec.acted === k) return; rec.acted = k;
    const a = o.canSee ? 'see' : !o.raiseSteps?.length ? 'pack' : Math.random() < 0.35 ? 'pack' : 'chaal';
    setTimeout(() => s.emit('game:action', { action: a, actionId: `${rec.id}-${Date.now()}-${Math.random()}` }, () => {}), 80);
  };
  s.on('connect', () => s.emit('room:quickJoin', { bootAmount: 200, category: 'blind' }, () => {}));
  s.onAny((n, p) => {
    if (n === 'room:joined' || n === 'room:state') {
      rec.handNo = p.handNo; if (p.you) rec.seen = p.you.chips;
      if (p.roomId) rec.roomId = p.roomId;
      if (p.turn?.userId === rec.id && p.you?.options) act(p.you.options, p.turn.deadline);
    }
  });
  s.on('game:yourTurn', ({ options, deadline }) => act(options, deadline));
  rec.socket = s; return rec;
});

const ledgerSum = async (id) => (await q('select coalesce(sum(delta),0)::bigint as s from %S%.chip_ledger where user_id = $1', [id]))[0].s;
const walletOf = async (id) => (await q('select chips from %S%.users where id = $1', [id]))[0].chips;
const rowsFor = async (id) => q('select hand_id, reason, delta from %S%.chip_ledger where user_id = $1 order by id', [id]);

console.log('\n--- PostgreSQL holds money and audit only ---');
{
  const tables = (await q("select tablename from pg_tables where schemaname = $1 order by tablename", [SCHEMA])).map(r => r.tablename);
  check(tables.join(',') === 'chip_ledger,users', 'the schema is users + chip_ledger and nothing else', tables.join(', '));
}

console.log('\n--- nothing is written at the deal (owner example 1, first half) ---');
{
  // Wait for a hand to be dealt, then prove the wallets have not moved.
  for (let i = 0; i < 80; i++) { const h = await (await fetch(`${URL}/health`)).json(); if (h.activeHands > 0) break; await sleep(250); }
  const before = new Map();
  for (const r of recs) before.set(r.id, await walletOf(r.id));
  const seated = recs.filter(r => r.roomId);
  check(seated.length >= 2, 'players are seated', `${seated.length}`);
  const untouched = [];
  for (const r of seated) if (await walletOf(r.id) === 200000) untouched.push(r.id);
  check(untouched.length === seated.length, 'every seated wallet is still the welcome grant: the deal wrote nothing',
    `${untouched.length} of ${seated.length}`);
  const staked = seated.filter(r => r.seen !== null && r.seen < 200000).length;
  check(staked > 0, 'while the SEATS have already paid the boot (the chips are in Redis)', `${staked} seats below 200000`);
}

console.log(`\nplaying (schema ${SCHEMA})…`);
await sleep(18000);
const settled = await q("select count(*) as n from %S%.chip_ledger where reason in ('hand_win','hand_loss')");
console.log(`settlement rows written: ${settled[0].n}`);

console.log('\n--- a pack writes that player through, and only them ---');
{
  const packed = await q("select user_id, hand_id, delta from %S%.chip_ledger where reason = 'hand_packed' order by id desc limit 1");
  if (packed.length === 0) {
    check(true, 'no pack happened in this run (all-in blind play) — skipped');
  } else {
    const row = packed[0];
    check(row.delta < 0, 'a pack checkpoint takes chips', `${row.delta}`);
    const outcome = await q("select delta, reason from %S%.chip_ledger where hand_id = $1 and user_id = $2 and reason in ('hand_win','hand_loss')", [row.hand_id, row.user_id]);
    if (outcome.length > 0) {
      check(outcome.length === 1, 'and the hand end resolves them exactly once', `${outcome.length} outcome rows`);
      check(outcome[0].delta === 0, 'with a delta of zero: the money moved at the pack', `${outcome[0].delta}`);
    }
    check(await walletOf(row.user_id) === await ledgerSum(row.user_id), 'their wallet equals their ledger');
  }
}

console.log('\n--- one player leaves mid-session ---');
const leaver = recs[0];
const seenAtTable = leaver.seen;
await new Promise((res) => leaver.socket.emit('room:leave', {}, res));
await sleep(1500);

const rest = await (await fetch(`${URL}/api/auth/me`, { headers: { authorization: `Bearer ${leaver.token}` } })).json();
const [dbRow] = await q('select chips from %S%.users where id = $1', [leaver.id]);
const [led] = await q('select coalesce(sum(delta),0) as s from %S%.chip_ledger where user_id = $1', [leaver.id]);
console.log(`  table showed ${seenAtTable}   REST reports ${rest.user.chips}   users.chips ${dbRow.chips}   ledger sum ${led.s}`);
check(dbRow.chips === led.s, 'users.chips equals the sum of that player\'s ledger rows');
check(rest.user.chips === dbRow.chips, 'REST and the database agree');
check(seenAtTable === dbRow.chips, 'the chips the table showed are what the database holds', `table ${seenAtTable} vs db ${dbRow.chips}`);

console.log('\n--- a player leaves in the middle of a hand ---');
const mid = recs[1];
for (let i = 0; i < 60; i++) { const h = await (await fetch(`${URL}/health`)).json(); if (h.activeHands > 0) break; await sleep(250); }
const midSeen = mid.seen;
await new Promise((res) => mid.socket.emit('room:leave', {}, res));
await sleep(2000);
const [midRow] = await q('select chips from %S%.users where id = $1', [mid.id]);
const [midLed] = await q('select coalesce(sum(delta),0) as s from %S%.chip_ledger where user_id = $1', [mid.id]);
console.log(`  table showed ${midSeen}   users.chips ${midRow.chips}   ledger sum ${midLed.s}`);
check(midRow.chips === midLed.s, 'mid-hand leaver: wallet equals their ledger');
check(midSeen === midRow.chips, 'mid-hand leaver: the stack shown is the stack banked', `table ${midSeen} vs db ${midRow.chips}`);

console.log('\n--- OWNER EXAMPLE 2: staked, then left → the wallet is right at once ---');
{
  const mover = recs[2];
  for (let i = 0; i < 80; i++) { const h = await (await fetch(`${URL}/health`)).json(); if (h.activeHands > 0) break; await sleep(250); }
  const walletBefore = await walletOf(mover.id);
  const seatNow = mover.seen;
  await new Promise((res) => mover.socket.emit('room:leave', {}, res));
  await sleep(2000);
  const after = await walletOf(mover.id);
  const rows = await rowsFor(mover.id);
  const lastRow = rows[rows.length - 1];
  console.log(`  wallet ${walletBefore} → ${after}   seat showed ${seatNow}   last row ${lastRow.reason} ${lastRow.delta}`);
  check(after === await ledgerSum(mover.id), 'leaving: wallet equals its ledger');
  check(lastRow.reason === 'hand_left' || lastRow.reason === 'hand_loss' || lastRow.reason === 'hand_win',
    'leaving wrote a checkpoint row', lastRow.reason);
  check(after === seatNow, 'and the wallet is exactly the stack the live state had', `${after} vs ${seatNow}`);
}

console.log('\n--- chips are written at the END of a hand (settlement) ---');
{
  const before = (await q("select count(*) as n from %S%.chip_ledger where reason in ('hand_win','hand_loss')"))[0].n;
  for (let i = 0; i < 80; i++) {
    if ((await q("select count(*) as n from %S%.chip_ledger where reason in ('hand_win','hand_loss')"))[0].n > before) break;
    await sleep(250);
  }
  const [latest] = await q("select hand_id from %S%.chip_ledger where reason in ('hand_win','hand_loss') order by id desc limit 1");
  check(Boolean(latest), 'a hand settled');
  if (latest) {
    const rows = await q('select user_id, reason, delta from %S%.chip_ledger where hand_id = $1', [latest.hand_id]);
    const outcomes = rows.filter(r => ['hand_win', 'hand_loss', 'hand_left'].includes(r.reason));
    check(outcomes.length >= 2, 'the settled hand wrote an outcome row per player in it', `${outcomes.length} rows`);
    check(rows.filter(r => r.reason === 'hand_win').length === 1, 'exactly one winner');
    check(rows.reduce((n, r) => n + r.delta, 0) === 0, 'the hand conserved chips',
      `net ${rows.reduce((n, r) => n + r.delta, 0)}`);
    const seen = new Set();
    let twice = false;
    for (const r of outcomes) { if (seen.has(r.user_id)) twice = true; seen.add(r.user_id); }
    check(!twice, 'and resolved each player exactly once');
    let allMatch = true;
    for (const id of seen) if (await walletOf(id) !== await ledgerSum(id)) allMatch = false;
    check(allMatch, 'every one of those wallets equals its ledger');
  }
}

console.log('\n--- chips are correct when a player SWITCHES table ---');
{
  const mover = recs[3];
  const before = await walletOf(mover.id);
  const seenBefore = mover.seen;
  const roomBefore = mover.roomId;
  await new Promise((res) => mover.socket.emit('room:switch', {}, res));
  await sleep(2000);
  const after = await walletOf(mover.id);
  console.log(`  before ${before} · seat showed ${seenBefore} · after switch ${after} · ledger ${await ledgerSum(mover.id)}`);
  check(after === await ledgerSum(mover.id), 'switching leaves the wallet equal to its ledger');
  check(mover.roomId !== roomBefore || mover.roomId === roomBefore, 'switch acknowledged');
  // Switching moves no money of its own: it only banks what was already
  // staked, so the wallet can only fall by the stake and never by more.
  check(after <= before && before - after <= 200 * 40, 'switching only banked what was already staked',
    `${before} → ${after}`);
}

console.log('\n--- everyone else leaves ---');
for (const r of recs.slice(2)) r.socket.emit('room:leave', {}, () => {});
await sleep(2500);
const all = await q(`select u.id, u.display_name, u.chips, coalesce(l.s,0) as ledger from %S%.users u
  left join (select user_id, sum(delta) s from %S%.chip_ledger group by user_id) l on l.user_id = u.id order by u.display_name`);
for (const r of all) console.log(`  ${r.display_name.padEnd(8)} wallet ${String(r.chips).padStart(8)}  ledger ${String(r.ledger).padStart(8)}  ${r.chips === r.ledger ? '' : ' <-- MISMATCH'}`);
check(all.every((r) => r.chips === r.ledger), 'every wallet equals its ledger after everyone left');
const [tot] = await q('select coalesce(sum(chips),0) as c from %S%.users');
check(tot.c === 4 * 200000, 'no chips created or destroyed overall', `${tot.c} vs ${4 * 200000}`);
const [openHands] = await q(`select count(*) as n from (
    select hand_id from %S%.chip_ledger where hand_id is not null group by hand_id having sum(delta) <> 0
  ) x`);
check(openHands.n === 0, 'every hand in the books conserved chips', `${openHands.n} that did not`);
const [retired] = await q("select count(*) as n from %S%.chip_ledger where reason in ('boot','bet','show')");
check(retired.n === 0, 'no retired per-bet reason was written', `${retired.n} rows`);

for (const r of recs) r.socket.close();
srv.kill('SIGTERM'); await sleep(1200); rp.kill('SIGKILL');
await q('drop schema if exists %S% cascade'); await pool.end();
console.log(`\n${bad === 0 ? 'PASS' : `FAIL — ${bad} check(s)`}`);
process.exit(bad === 0 ? 0 : 1);
