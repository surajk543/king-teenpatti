/**
 * The resident bot fleet.
 *
 *   npm start                        # 66 per category = 198 bots
 *   npm start -- --per-category 10   # a smaller fleet for a local server
 *   npm run dev                      # six per category, for a laptop
 *
 * Bots exist so a real player who opens the lobby finds a game in progress
 * rather than three empty tables. They speak only the public protocol.
 */
import { Bot } from './bot.js';
import { config, totalBots } from './config.js';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let mintedRotations = 0;
const startedAt = Date.now();

const log = (message, meta = {}) => {
  if (meta.minted) mintedRotations += 1;
  if (config.quiet && !meta.minted) return;
  const t = new Date().toISOString();
  console.log(`${t} ${message}`);
};

async function waitForServer() {
  for (let attempt = 1; ; attempt += 1) {
    try {
      const res = await fetch(`${config.serverUrl}/health`);
      const body = await res.json();
      if (body?.ok) return body;
    } catch {
      // fall through to the retry
    }
    if (attempt === 1) {
      console.log(`waiting for the game server at ${config.serverUrl} …`);
    }
    // The fleet is a systemd unit that may well start before the game server
    // does, so "not there yet" is a normal state to wait out rather than a
    // reason to exit and be restarted in a loop.
    await sleep(Math.min(3000 * attempt, 20000));
  }
}

const health = await waitForServer();
console.log(
  `bot-play → ${config.serverUrl} (server up ${Math.round(health.uptime)}s, ` +
    `${health.players} players, ${health.tables} tables)`,
);
console.log(
  `starting ${totalBots} bots: ${config.perCategory} in each of ` +
    config.categories.map((c) => `${c.category}/${c.boot}`).join(', '),
);

const bots = [];
let index = 0;
for (const table of config.categories) {
  for (let n = 0; n < config.perCategory; n += 1) {
    const bot = new Bot({ index: index++, table, log });
    bots.push(bot);
    try {
      await bot.start();
    } catch (e) {
      log(`bot ${bot.identity.name} failed to start: ${e.message}`);
    }
    // Staggered on purpose: two hundred logins and websocket handshakes at
    // once is a thundering herd against the very server this is meant to make
    // look healthy, and it is the shape an edge filter drops.
    await sleep(config.startStaggerMs);
  }
}

console.log(`${bots.length} bots seated.`);

// Wandering, so seats keep opening across the lobby rather than in one table.
if (config.switchEvery > 0) {
  for (const bot of bots) {
    const tick = () => {
      const wait = config.switchEvery * 1000 * (0.5 + Math.random() * 1.4);
      bot.after(wait, () => {
        if (Math.random() < 0.6) bot.wander();
        tick();
      });
    };
    tick();
  }
}

// A heartbeat, so a fleet left running for weeks says something about itself
// in the journal without anyone having to attach to it.
setInterval(async () => {
  const seated = bots.filter((b) => b.seated).length;
  const stopped = bots.filter((b) => b.stopped).length;
  let server = '';
  try {
    const h = await fetch(`${config.serverUrl}/health`).then((r) => r.json());
    server = ` · server ${h.players} players ${h.tables} tables ${h.activeHands} hands`;
  } catch {
    server = ' · server unreachable';
  }
  console.log(
    `${new Date().toISOString()} fleet ${seated}/${bots.length} seated` +
      (stopped ? `, ${stopped} retired` : '') +
      (mintedRotations ? `, ${mintedRotations} rotations minted chips` : '') +
      ` · up ${Math.round((Date.now() - startedAt) / 60000)}m` +
      server,
  );
}, 5 * 60 * 1000).unref?.();

const shutdown = (signal) => {
  console.log(`${signal}: stopping ${bots.length} bots`);
  for (const bot of bots) bot.stop();
  // Give the sockets a moment to close cleanly, so seats are released rather
  // than left for the reconnect grace to expire.
  setTimeout(() => process.exit(0), 1500);
};

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
