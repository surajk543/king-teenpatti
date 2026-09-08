// Are a player's chips in PostgreSQL correct the moment they leave a table?
//
// The server is wallet-based, not buy-in based: `users.chips` is debited
// inside the same transaction as every boot, bet and show, and committed
// before the player is told the move succeeded. The chips shown at the seat
// are a mirror of the wallet, not a separate stack, so there is nothing to
// write back when someone leaves. This test proves that claim, for a player
// leaving between hands and for one leaving in the middle of one.
//
// It compares four numbers that must agree for the same player: what the
// table showed, what GET /api/auth/me reports, what users.chips holds, and
// what that player's ledger rows sum to.
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
      if (p.turn?.userId === rec.id && p.you?.options) act(p.you.options, p.turn.deadline);
    }
  });
  s.on('game:yourTurn', ({ options, deadline }) => act(options, deadline));
  rec.socket = s; return rec;
});

console.log(`\nplaying (schema ${SCHEMA})…`);
await sleep(18000);
const played = await q('select count(*) as n from %S%.hands');
console.log(`hands settled: ${played[0].n}`);

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

console.log('\n--- everyone else leaves ---');
for (const r of recs.slice(2)) r.socket.emit('room:leave', {}, () => {});
await sleep(2500);
const all = await q(`select u.id, u.display_name, u.chips, coalesce(l.s,0) as ledger from %S%.users u
  left join (select user_id, sum(delta) s from %S%.chip_ledger group by user_id) l on l.user_id = u.id order by u.display_name`);
for (const r of all) console.log(`  ${r.display_name.padEnd(8)} wallet ${String(r.chips).padStart(8)}  ledger ${String(r.ledger).padStart(8)}  ${r.chips === r.ledger ? '' : ' <-- MISMATCH'}`);
check(all.every((r) => r.chips === r.ledger), 'every wallet equals its ledger after everyone left');
const [tot] = await q('select coalesce(sum(chips),0) as c from %S%.users');
const [pot] = await q('select coalesce(sum(amount),0) as a from %S%.pots where closed_at is null');
check(tot.c + pot.a === 4 * 200000, 'no chips created or destroyed overall', `${tot.c} + ${pot.a} vs ${4 * 200000}`);

for (const r of recs) r.socket.close();
srv.kill('SIGTERM'); await sleep(1200); rp.kill('SIGKILL');
await q('drop schema if exists %S% cascade'); await pool.end();
console.log(`\n${bad === 0 ? 'PASS' : `FAIL — ${bad} check(s)`}`);
process.exit(bad === 0 ? 0 : 1);
