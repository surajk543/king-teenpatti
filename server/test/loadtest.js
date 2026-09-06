/**
 * Load test for the concurrency target (500–1000 players).
 *
 * Spawns N bot players that log in, quick-join tables and play real hands —
 * seeing, betting, packing and showing — against a running server. It reports
 * connection success, action round-trip latency and hands completed per second.
 *
 *   node test/loadtest.js --players 600 --seconds 60 --url http://localhost:3000
 *
 * Run it against a server started with AUTH_ALLOW_FAKE_PROVIDERS unset — bots
 * log in as guests, which needs no provider configuration.
 */
import { io } from 'socket.io-client';

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, token, index, all) => {
    if (token.startsWith('--')) pairs.push([token.slice(2), all[index + 1]]);
    return pairs;
  }, []),
);

const PLAYERS = Number.parseInt(args.players ?? '600', 10);
const SECONDS = Number.parseInt(args.seconds ?? '45', 10);
const BASE_URL = args.url ?? 'http://localhost:3000';
const BOOT = Number.parseInt(args.boot ?? '100', 10);
/** Players are connected in waves so the server is not hit by a thundering herd. */
const RAMP_BATCH = Number.parseInt(args.batch ?? '25', 10);
const RAMP_DELAY_MS = Number.parseInt(args.rampDelay ?? '120', 10);

const stats = {
  loginFailures: 0,
  connectFailures: 0,
  connected: 0,
  joined: 0,
  actionsSent: 0,
  actionErrors: 0,
  chatSent: 0,
  latencies: [],
  // Every player at a table receives the same hand events, so hands are counted
  // by id to avoid multiplying the total by the number of seats.
  handsStarted: new Set(),
  handsEnded: new Set(),
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const percentile = (values, p) => {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))];
};

async function login(index) {
  const response = await fetch(`${BASE_URL}/api/auth/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      provider: 'guest',
      deviceId: `loadtest-device-${index}-${process.pid}`,
      displayName: `Bot${index}`,
    }),
  });
  if (!response.ok) throw new Error(`login ${response.status}`);
  return response.json();
}

/**
 * One bot. It only ever acts on `game:yourTurn`, using the options the server
 * sent, so it exercises the same path a real client would.
 */
function createBot(token) {
  const socket = io(BASE_URL, {
    auth: { token },
    transports: ['websocket'],
    forceNew: true,
    reconnection: false,
  });

  socket.on('connect', () => {
    stats.connected += 1;
    socket.emit('room:quickJoin', { bootAmount: BOOT }, (ack) => {
      if (ack?.ok) stats.joined += 1;
    });
  });

  socket.on('connect_error', () => {
    stats.connectFailures += 1;
  });

  socket.on('game:handStarted', ({ handId }) => {
    if (handId) stats.handsStarted.add(handId);
  });

  socket.on('game:handEnded', ({ handId }) => {
    if (handId) stats.handsEnded.add(handId);
  });

  socket.on('game:yourTurn', ({ options }) => {
    // A little think time, so bots do not all fire on the same tick.
    const thinkMs = 120 + Math.random() * 400;

    setTimeout(() => {
      if (socket.disconnected) return;

      const action = chooseAction(options);
      if (!action) return;

      const startedAt = Date.now();
      stats.actionsSent += 1;

      socket.emit('game:action', { action }, (ack) => {
        stats.latencies.push(Date.now() - startedAt);
        if (ack && ack.ok === false) stats.actionErrors += 1;
      });
    }, thinkMs);
  });

  // A slow trickle of chat, to keep the room log path under load too.
  const chatTimer = setInterval(() => {
    if (socket.disconnected) return;
    if (Math.random() > 0.15) return;
    stats.chatSent += 1;
    socket.emit('chat:message', { text: 'nice hand' });
  }, 5000);
  chatTimer.unref?.();

  return socket;
}

/** Mirrors a reasonable human: mostly call, sometimes raise, sometimes fold. */
function chooseAction(options) {
  if (!options) return null;

  if (options.canSee && Math.random() < 0.6) return 'see';
  if (options.show && Math.random() < 0.45) return 'show';

  const roll = Math.random();
  if (roll < 0.15) return 'pack';
  if (roll < 0.30 && options.raise) return 'raise';
  if (options.chaal) return 'chaal';
  if (options.raise) return 'raise';
  return 'pack';
}

async function main() {
  console.log(`Load test: ${PLAYERS} players against ${BASE_URL} for ${SECONDS}s\n`);

  const health = await fetch(`${BASE_URL}/health`).then((r) => r.json()).catch(() => null);
  if (!health?.ok) {
    console.error(`No server at ${BASE_URL}. Start it with: npm start`);
    process.exit(1);
  }

  const sockets = [];
  const rampStart = Date.now();

  for (let batch = 0; batch < Math.ceil(PLAYERS / RAMP_BATCH); batch += 1) {
    const from = batch * RAMP_BATCH;
    const to = Math.min(PLAYERS, from + RAMP_BATCH);

    await Promise.all(
      Array.from({ length: to - from }, async (_, offset) => {
        try {
          const { token } = await login(from + offset);
          sockets.push(createBot(token));
        } catch {
          stats.loginFailures += 1;
        }
      }),
    );

    await sleep(RAMP_DELAY_MS);
  }

  const rampSeconds = (Date.now() - rampStart) / 1000;
  console.log(`Ramp-up done in ${rampSeconds.toFixed(1)}s — ${stats.connected} connected\n`);

  const started = Date.now();
  const handsAtStart = stats.handsEnded.size;

  const ticker = setInterval(async () => {
    const live = await fetch(`${BASE_URL}/health`).then((r) => r.json()).catch(() => ({}));
    const elapsed = ((Date.now() - started) / 1000).toFixed(0);
    console.log(
      `t+${elapsed.padStart(3)}s  players=${live.players ?? '?'}  tables=${live.tables ?? '?'}  ` +
        `hands=${stats.handsEnded.size}  actions=${stats.actionsSent}  ` +
        `p95=${percentile(stats.latencies, 95)}ms`,
    );
  }, 5000);

  await sleep(SECONDS * 1000);
  clearInterval(ticker);

  const elapsedSeconds = (Date.now() - started) / 1000;
  const finalHealth = await fetch(`${BASE_URL}/health`).then((r) => r.json()).catch(() => ({}));

  console.log('\n──────── results ────────');
  console.log(`players requested   ${PLAYERS}`);
  console.log(`login failures      ${stats.loginFailures}`);
  console.log(`connect failures    ${stats.connectFailures}`);
  console.log(`sockets connected   ${stats.connected}`);
  console.log(`seated at a table   ${stats.joined}`);
  console.log(`server sees         ${finalHealth.players ?? '?'} players / ${finalHealth.tables ?? '?'} tables`);
  console.log(`hands started       ${stats.handsStarted.size}`);
  console.log(`hands completed     ${stats.handsEnded.size}`);
  console.log(`hands/sec           ${((stats.handsEnded.size - handsAtStart) / elapsedSeconds).toFixed(1)}`);
  console.log(`actions sent        ${stats.actionsSent}`);
  console.log(`action errors       ${stats.actionErrors}`);
  console.log(`chat messages       ${stats.chatSent}`);
  console.log(`latency p50/p95/p99 ${percentile(stats.latencies, 50)}/${percentile(stats.latencies, 95)}/${percentile(stats.latencies, 99)} ms`);
  console.log('─────────────────────────');

  for (const socket of sockets) socket.close();
  await sleep(500);
  process.exit(0);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
