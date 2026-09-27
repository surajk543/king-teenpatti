/**
 * Who is online.
 *
 * A lobby where the same sixty-six accounts sit at the same tables all day,
 * every day, is a lobby of programs. People arrive, play a while, get up, and
 * come back later — so the faces at a table change through an evening.
 *
 * Each category's bots are a pool. At any moment only some of the pool is
 * online, a count that drifts between --online-min and --online-max bots.
 * A bot plays a sitting (persona.sessionHands), gets up and rests
 * (persona.restMs); the fleet brings a rested bot back when its category is
 * below the count it currently wants, and asks one to get up after its hand
 * when it is above. One change per category per tick, so arrivals and
 * departures trickle rather than arriving in waves.
 *
 * Only entries the server's menu offers are staffed (menu.js). An entry the
 * menu leaves out wants nobody: its bots rest; any still seated are asked to
 * get up after their hand, one a tick, the way the fleet thins any table (and
 * under --steady too, which otherwise never thins); and one on its way to a
 * seat ends its sitting instead of sitting somewhere else (Bot.join). If a
 * later menu lists the entry again, its bots drift back in.
 *
 * The pool is the same fixed identities as before — no new accounts, so no
 * welcome bonuses minted by coming and going.
 */
import { config, onlineRangeFor } from './config.js';
import { TableMenu } from './menu.js';

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
/** The fleet's key for a home entry's group of bots (and its target). */
const groupKey = (table) => `${table.category}/${table.boot}`;

export class Fleet {
  constructor({ bots, log, menu }) {
    this.bots = bots;
    this.log = log;
    /** What the server offers; with none given, every configured entry is. */
    this.menu = menu ?? new TableMenu({ entries: config.categories });
    this.targets = new Map(); // category key → bots wanted online
    this.timer = null;
    this.stopped = false;
    this.arrivals = 0;
    this.departures = 0;
  }

  groups() {
    const byHome = new Map();
    for (const bot of this.bots) {
      const key = groupKey(bot.home);
      if (!byHome.has(key)) byHome.set(key, []);
      byHome.get(key).push(bot);
    }
    return byHome;
  }

  /**
   * How many of this entry's bots should be seated right now.
   *
   * An absolute count drawn from the entry's range (config.onlineRangeFor),
   * not a share of the pool. The share it used to be could not be met: a
   * sitting ends by itself after ~20 hands and a rest averages 25 minutes, so
   * the seated count settles at the duty cycle those imply — about a third of
   * the pool — no matter what percentage was configured. Asking for a number
   * the fleet can actually hold is what makes "20–25 at every table" true
   * rather than aspirational.
   */
  wantedOnline(table, size) {
    if (!this.menu.isOffered(table)) return 0;
    if (config.steady) return size;
    const [lo, hi] = onlineRangeFor(table);
    return Math.min(size, lo + Math.floor(Math.random() * (hi - lo + 1)));
  }

  /** Brings the opening share of each category online, staggered; the rest start mid-rest. */
  async start() {
    const now = Date.now();
    const opening = [];
    for (const [key, group] of this.groups()) {
      const target = this.wantedOnline(group[0].home, group.length);
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
      // The menu can arrive only now — from an earlier bot's session:ready,
      // when GET /api/tables could not be read — and leave this bot's entry
      // out. Then it stays resting rather than logging in only to get straight
      // back up (Bot.join), and its entry wants nobody until a menu lists it.
      if (!this.menu.isOffered(bot.home)) {
        this.targets.set(groupKey(bot.home), 0);
        continue;
      }
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
      const home = group[0].home;
      const online = group.filter((b) => b.online && !b.stopped);
      if (!this.menu.isOffered(home)) {
        // Off the menu: nobody wanted, and whoever is still online goes home
        // after their hand — one a tick, like any thinning, not all at once.
        this.targets.set(key, 0);
        const staying = online.filter((b) => !b.wrappingUp && !b.leaving);
        if (staying.length) {
          pick(staying).wrapUp();
          this.departures += 1;
        }
        continue;
      }
      // A target of 0 is an entry that was off the menu and is back: want
      // bots for it now rather than on some later tick's redraw.
      if (!this.targets.get(key) || (!config.steady && Math.random() < 0.25)) {
        this.targets.set(key, this.wantedOnline(home, group.length));
      }
      const target = this.targets.get(key);

      if (online.length < target) {
        const rested = group.filter((b) => !b.online && !b.stopped && !b.leaving && b.restUntil <= now);
        // One arrival per tick takes twenty minutes to close a gap of forty,
        // which is what a restart or a wave of sittings ending together
        // leaves behind — and for all of it the table is emptier than the
        // target says. Bring several when the gap is wide, but never the whole
        // gap at once: a dozen logins in the same second is the thundering
        // herd startStaggerMs exists to avoid, aimed at the server this fleet
        // is here to make look healthy.
        const shortfall = target - online.length;
        const bringBack = Math.min(rested.length, shortfall > 4 ? 3 : 1);
        for (let n = 0; n < bringBack; n += 1) {
          if (this.stopped) return;
          const bot = pick(rested.filter((b) => !b.online));
          if (!bot) break;
          try {
            await bot.comeOnline();
            this.arrivals += 1;
            this.log(`${bot.identity.name}: back online (${key}, ${online.length + n + 1}/${target})`);
          } catch (e) {
            bot.restUntil = Date.now() + 60_000;
            this.log(`${bot.identity.name}: could not come back — ${e.message}`);
          }
          if (n + 1 < bringBack) await sleep(config.startStaggerMs);
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
