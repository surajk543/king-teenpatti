/**
 * The resident bot fleet.
 *
 *   npm start                        # 66 per category = 198 bots, ~75–95% online at once
 *   npm start -- --per-category 10   # a smaller fleet for a local server
 *   npm run dev                      # six per category, for a laptop
 *   npm test                         # the decision, ranking, persona and chat rules
 *
 * Bots exist so a real player who opens the lobby finds a game in progress
 * rather than three empty tables. They speak only the public protocol.
 */
import { Bot } from './bot.js';
import { config, totalBots } from './config.js';
import { Fleet } from './fleet.js';

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
  `fleet of ${totalBots} bots: ${config.perCategory} in each of ` +
    config.categories.map((c) => `${c.category}/${c.boot}`).join(', ') +
    (config.steady
      ? ', all seated for good'
      : `; ${config.onlineMin}–${config.onlineMax}% online at once, sittings of ~${config.sessionHands} hands, ~${config.restMinutes}m away between them`),
);

const bots = [];
let index = 0;
for (const table of config.categories) {
  for (let n = 0; n < config.perCategory; n += 1) {
    bots.push(new Bot({ index: index++, table, log }));
  }
}

const fleet = new Fleet({ bots, log });
await fleet.start();
console.log(`${fleet.summary()} — the rest are resting and will drift in.`);

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

// And, far more rarely, a change of stake — so the three lobby tables are not
// each the same fixed accounts for ever. Only the minority of bots whose
// persona has a hopRate ever take it.
if (config.hopEvery > 0) {
  for (const bot of bots) {
    if (!bot.persona.hopRate) continue;
    const tick = () => {
      const wait = config.hopEvery * 1000 * (0.5 + Math.random() * 1.4);
      bot.after(wait, () => {
        if (Math.random() < bot.persona.hopRate) bot.hop();
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
    `${new Date().toISOString()} fleet ${seated}/${bots.length} seated, ${fleet.summary()}` +
      `, ${fleet.arrivals} arrivals ${fleet.departures} sent home` +
      (stopped ? `, ${stopped} retired` : '') +
      (mintedRotations ? `, ${mintedRotations} rotations minted chips` : '') +
      ` · up ${Math.round((Date.now() - startedAt) / 60000)}m` +
      server,
  );
}, 5 * 60 * 1000).unref?.();

const shutdown = (signal) => {
  console.log(`${signal}: stopping ${bots.length} bots`);
  fleet.stop();
  for (const bot of bots) bot.stop();
  // Give the sockets a moment to close cleanly, so seats are released rather
  // than left for the reconnect grace to expire.
  setTimeout(() => process.exit(0), 1500);
};

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
