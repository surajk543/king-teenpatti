/**
 * Practice bots.
 *
 * Fills a table so you can play a real hand on your own — a hand needs two
 * players, and a lobby is empty on a fresh server. Bots use exactly the same
 * public protocol a real client does: they act only on `game:yourTurn`, using
 * the options the server sends them.
 *
 *   node tools/bot.js --count 2 --boot 200
 *   node tools/bot.js --count 3 --boot 5000 --category blind --offset 4
 *   node tools/bot.js --count 4 --boot 200 --url http://localhost:3000
 */
import { io } from 'socket.io-client';

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, token, index, all) => {
    if (token.startsWith('--')) pairs.push([token.slice(2), all[index + 1]]);
    return pairs;
  }, []),
);

const COUNT = Number.parseInt(args.count ?? '2', 10);
const BOOT = Number.parseInt(args.boot ?? '200', 10);
/** "seen" shows every stack at the table; "blind" hides all but your own. */
const CATEGORY = args.category === 'blind' ? 'blind' : 'seen';
const BASE_URL = args.url ?? 'http://localhost:3000';
/**
 * Shifts which bot identities this run uses. A bot account can only sit at one
 * table, so a second group of bots (a different table or category) needs its
 * own offset or it will collide with the first.
 */
const OFFSET = Number.parseInt(args.offset ?? '0', 10);
const NAMES = ['Ravi', 'Meera', 'Arjun', 'Kavya', 'Vikram', 'Anita', 'Rohit', 'Neha'];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function login(name, index) {
  const response = await fetch(`${BASE_URL}/api/auth/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      provider: 'guest',
      // Stable per-bot device id, so a bot keeps its chips between runs.
      deviceId: `practice-bot-${index}-${name}`,
      displayName: name,
    }),
  });
  if (!response.ok) throw new Error(`login failed: ${response.status}`);
  return response.json();
}

/** Plays a straightforward, slightly loose game — enough to make hands happen. */
function decide(options) {
  if (options.canSee && Math.random() < 0.7) return 'see';
  if (options.show && Math.random() < 0.5) return 'show';

  const roll = Math.random();
  if (roll < 0.12) return 'pack';
  if (roll < 0.25 && options.raise) return 'raise';
  if (options.chaal) return 'chaal';
  if (options.raise) return 'raise';
  return 'pack';
}

const CHATTER = [
  'good luck all',
  'nice hand',
  'wow',
  'all yours',
  'lets go',
  'that was close',
];

async function startBot(index) {
  const slot = (index + OFFSET) % NAMES.length;
  const name = NAMES[slot];
  const { token, user } = await login(name, slot);

  const socket = io(BASE_URL, { auth: { token }, transports: ['websocket'], forceNew: true });

  /**
   * Joins a table, retrying while the server still holds a seat for us.
   *
   * Restarting the bots inside the reconnect grace window is the common case:
   * the old socket's seat has not been released yet, so the join is refused
   * with "already seated". Retrying rides that out instead of leaving a bot
   * permanently benched.
   */
  const joinTable = (attempt = 1) => {
    socket.emit('room:quickJoin', { bootAmount: BOOT, category: CATEGORY }, (ack) => {
      if (ack?.ok) {
        console.log(`${name} joined table ${ack.code} (chips ${user.chips.toLocaleString()})`);
        return;
      }

      const retryable = ack?.code === 'already_in_room' || ack?.code === 'table_full';
      if (retryable && attempt <= 12) {
        if (attempt === 1) console.log(`${name} waiting for a seat (${ack.message})…`);
        setTimeout(() => joinTable(attempt + 1), 5000);
        return;
      }

      console.log(`${name} could not join: ${ack?.message ?? 'unknown error'}`);
    });
  };

  socket.on('connect', () => joinTable());

  socket.on('game:yourTurn', ({ options }) => {
    // Human-ish think time, so the table does not resolve instantly.
    setTimeout(() => socket.emit('game:action', { action: decide(options) }), 700 + Math.random() * 1600);
  });

  socket.on('game:handEnded', ({ winnerName, pot }) => {
    if (Math.random() < 0.25) {
      setTimeout(
        () => socket.emit('chat:message', { text: CHATTER[Math.floor(Math.random() * CHATTER.length)] }),
        800 + Math.random() * 1200,
      );
    }
    if (index === 0) console.log(`  hand won by ${winnerName ?? '—'} for ${pot.toLocaleString()}`);
  });

  socket.on('disconnect', () => console.log(`${name} disconnected`));
  return socket;
}

const health = await fetch(`${BASE_URL}/health`).then((r) => r.json()).catch(() => null);
if (!health?.ok) {
  console.error(`No server at ${BASE_URL}. Start it with: npm start`);
  process.exit(1);
}

console.log(`Starting ${COUNT} practice bot(s) — ${CATEGORY} table, boot ${BOOT} — on ${BASE_URL}\n`);

const sockets = [];
for (let i = 0; i < COUNT; i += 1) {
  sockets.push(await startBot(i));
  await sleep(400);
}

console.log(`\nBots are seated. Join the ${CATEGORY} table at boot ${BOOT} to play against them.`);
console.log('Press Ctrl+C to stop.\n');

const shutdown = () => {
  for (const socket of sockets) socket.close();
  process.exit(0);
};

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
