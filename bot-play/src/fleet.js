/**
 * Who is online.
 *
 * A lobby where the same sixty-six accounts sit at the same tables all day,
 * every day, is a lobby of programs. People arrive, play a while, get up, and
 * come back later — so the faces at a table change through an evening.
 *
 * Each category's bots are a pool. At any moment only a share of the pool is
 * online, and that share drifts between --online-min and --online-max percent.
 * A bot plays a sitting (persona.sessionHands), gets up and rests
 * (persona.restMs); the fleet brings a rested bot back when its category is
 * below the share it currently wants, and asks one to get up after its hand
 * when it is above. One change per category per tick, so arrivals and
 * departures trickle rather than arriving in waves.
 *
 * The pool is the same fixed identities as before — no new accounts, so no
 * welcome bonuses minted by coming and going.
 */
import { config } from './config.js';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const pick = (items) => items[Math.floor(Math.random() * items.length)];
const shuffle = (items) => {
  const copy = [...items];
  for (let i = copy.length - 1; i > 0; i -= 1) {
    const j = Math.floor(Math.random() * (i + 1));
    [copy[i], copy[j]] = [copy[j], copy[i]];
  }
  return copy;
};

export class Fleet {
  constructor({ bots, log }) {
    this.bots = bots;
    this.log = log;
    this.targets = new Map(); // category key → bots wanted online
    this.timer = null;
    this.stopped = false;
    this.arrivals = 0;
    this.departures = 0;
  }

  groups() {
    const byHome = new Map();
    for (const bot of this.bots) {
      const key = `${bot.home.category}/${bot.home.boot}`;
      if (!byHome.has(key)) byHome.set(key, []);
      byHome.get(key).push(bot);
    }
    return byHome;
  }

  /** A share of `size` somewhere between the configured bounds. */
  wantedOnline(size) {
    if (config.steady) return size;
    const lo = Math.min(config.onlineMin, config.onlineMax) / 100;
    const hi = Math.max(config.onlineMin, config.onlineMax) / 100;
    return Math.max(1, Math.round(size * (lo + Math.random() * (hi - lo))));
  }

  /** Brings the opening share of each category online, staggered; the rest start mid-rest. */
  async start() {
    const now = Date.now();
    const opening = [];
    for (const [key, group] of this.groups()) {
      const target = this.wantedOnline(group.length);
      this.targets.set(key, target);
      const order = shuffle(group);
      opening.push(...order.slice(0, target));
      for (const bot of order.slice(target)) {
        // Away already, and due back at different times.
        bot.restUntil = now + Math.random() * config.restMinutes * 60_000;
      }
    }
    // Interleave the categories so no stake fills long before the others.
    for (const bot of shuffle(opening)) {
      if (this.stopped) return;
      try {
        await bot.start();
      } catch (e) {
        this.log(`bot ${bot.identity.name} failed to start: ${e.message}`);
        bot.restUntil = Date.now() + 60_000;
      }
      // Staggered on purpose: two hundred logins and websocket handshakes at
      // once is a thundering herd against the very server this is meant to make
      // look healthy, and it is the shape an edge filter drops.
      await sleep(config.startStaggerMs);
    }
    this.schedule();
  }

  schedule() {
    if (this.stopped) return;
    this.timer = setTimeout(() => this.tick(), 15_000 + Math.random() * 25_000);
    this.timer.unref?.();
  }

  async tick() {
    if (this.stopped) return;
    const now = Date.now();
    for (const [key, group] of this.groups()) {
      if (!config.steady && Math.random() < 0.25) this.targets.set(key, this.wantedOnline(group.length));
      const target = this.targets.get(key) ?? group.length;
      const online = group.filter((b) => b.online && !b.stopped);

      if (online.length < target) {
        const rested = group.filter((b) => !b.online && !b.stopped && !b.leaving && b.restUntil <= now);
        if (rested.length) {
          const bot = pick(rested);
          try {
            await bot.comeOnline();
            this.arrivals += 1;
            this.log(`${bot.identity.name}: back online (${key}, ${online.length + 1}/${target})`);
          } catch (e) {
            bot.restUntil = Date.now() + 60_000;
            this.log(`${bot.identity.name}: could not come back — ${e.message}`);
          }
        }
      } else if (online.length > target + 1) {
        const seated = online.filter((b) => b.seated && !b.wrappingUp && !b.leaving);
        if (seated.length) {
          pick(seated).wrapUp();
          this.departures += 1;
        }
      }
    }
    this.schedule();
  }

  summary() {
    const online = this.bots.filter((b) => b.online && !b.stopped).length;
    const wanted = [...this.targets.values()].reduce((sum, n) => sum + n, 0);
    return `${online} online (wanted ${wanted})`;
  }

  stop() {
    this.stopped = true;
    clearTimeout(this.timer);
  }
}
