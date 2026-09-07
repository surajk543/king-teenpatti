/**
 * Two throwaway clients against the running server:
 *   Idler — joins and never acts, so its turns time out.
 *   Shorty — joins with just over one boot, loses it, and then cannot cover
 *            the next one.
 */
import { io } from 'socket.io-client';
import { getDatabase } from './src/db/index.js';

const BASE = 'http://localhost:3000';
const db = getDatabase();

async function login(deviceId, displayName, chips) {
  const r = await fetch(`${BASE}/api/auth/login`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ provider: 'guest', deviceId, displayName }),
  }).then((x) => x.json());
  db.prepare('UPDATE users SET chips = ? WHERE id = ?').run(chips, r.user.id);
  // Log in again so the session carries the adjusted balance.
  return fetch(`${BASE}/api/auth/login`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ provider: 'guest', deviceId, displayName }),
  }).then((x) => x.json());
}

function client(token, label, { act }) {
  const s = io(BASE, { auth: { token }, transports: ['websocket'], forceNew: true });
  s.on('room:kicked', (p) => console.log(`  ${label}: KICKED — reason=${p.reason} — "${p.message}"`));
  s.on('connect', () =>
    s.emit('room:quickJoin', { bootAmount: 200, category: 'blind' }, (ack) =>
      console.log(`  ${label}: ${ack.ok ? 'joined ' + ack.code : 'refused — ' + ack.message}`)));
  if (act) {
    s.on('game:yourTurn', () => setTimeout(() => s.emit('game:action', { action: 'pack' }), 400));
  }
  return s;
}

const idler = await login('kick-idler-device', 'Idler', 50000);
const shorty = await login('kick-shorty-device', 'Shorty', 260);
console.log('Idler: 50,000 chips, never acts.  Shorty: 260 chips, boot is 200.\n');

const a = client(idler.token, 'Idler', { act: false });
setTimeout(() => client(shorty.token, 'Shorty', { act: true }), 2000);

setTimeout(() => process.exit(0), 150000);
