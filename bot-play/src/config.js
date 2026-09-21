/**
 * Everything the fleet reads, in one place, from the environment.
 *
 * The default server URL is `http://127.0.0.1:3000` — the game server's own
 * port, not the public HTTPS address — and that is deliberate on both sides of
 * the deployment:
 *
 *   In production the bots run ON the game host, so talking to the loopback
 *   skips nginx, skips TLS termination, and skips the provider's edge
 *   protection entirely. That last one is not theoretical: two hundred sockets
 *   opening from a single address through the public endpoint is exactly the
 *   shape a DDoS filter is built to drop, and it does.
 *
 *   In development the go-server also listens on 127.0.0.1:3000, so the same
 *   default works with no configuration at all.
 *
 * Point SERVER_URL somewhere else only when the bots genuinely run off-host.
 */
const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, token, i, all) => {
    if (!token.startsWith('--')) return pairs;
    const next = all[i + 1];
    pairs.push([token.slice(2), next === undefined || next.startsWith('--') ? 'true' : next]);
    return pairs;
  }, []),
);

const envName = (name) => name.toUpperCase().replace(/-/g, '_');

const num = (name, fallback) => {
  const raw = args[name] ?? process.env[envName(name)];
  if (raw === undefined) return fallback;
  const n = Number.parseInt(raw, 10);
  if (Number.isNaN(n)) throw new Error(`bot-play: ${name} must be a whole number, got ${raw}`);
  return n;
};

const decimal = (name, fallback) => {
  const raw = args[name] ?? process.env[envName(name)];
  if (raw === undefined) return fallback;
  const n = Number.parseFloat(raw);
  if (Number.isNaN(n)) throw new Error(`bot-play: ${name} must be a number, got ${raw}`);
  return n;
};

const str = (name, fallback) => args[name] ?? process.env[envName(name)] ?? fallback;

const flag = (name) => args[name] === 'true' || args[name] === '' || process.env[envName(name)] === 'true';

export const config = {
  serverUrl: str('server-url', 'http://127.0.0.1:3000'),

  /**
   * The default POOL for a lobby entry — how many accounts belong to it, not
   * how many are playing. Only `online` of them are seated at any moment
   * (below), the rest are resting between sittings, so the pool has to be
   * several times the number you want to see.
   */
  perCategory: num('per-category', 66),

  /**
   * How many bots should be SEATED at each lobby entry, as a range the fleet
   * drifts between (owner, 22 Sep 2026: "every table should contain 20-25
   * bots").
   *
   * Read it as bots per lobby CARD, not per table: a table seats five
   * (MAX_PLAYERS_PER_ROOM), so 20–25 at one entry is four or five tables of
   * that stake running at once, which is what a busy lobby looks like.
   *
   * This replaced a share-of-the-pool figure (75–95%) that the fleet could
   * never actually reach. Sittings end on their own after ~20 hands and a
   * rest averages 25 minutes, so the online share settles at the duty cycle
   * those two imply — about a third — whatever percentage was asked for. The
   * old default therefore asked for 50–63 per entry and produced 19–27, and
   * the log said `19/59` every tick without anything being wrong. An absolute
   * target is honest: the fleet can hold it, and the number in the log is the
   * number on the table.
   */
  onlineMin: num('online-min', 20),
  onlineMax: num('online-max', 25),

  /**
   * The lobby's tables (LOBBY_TABLES on the server). A bot belongs to one of
   * these, and `hop` is what moves it to another.
   *
   * `pool` and `online` override the fleet-wide defaults for that entry.
   * Variation (owner, 22 Sep 2026) is deliberately smaller: its boot is
   * 50,000, so a fresh bot sits down with six boots rather than the 1,500 a
   * 200 table gives it, and a bot that busts is replaced by a NEW account
   * carrying a new welcome bonus (config.onBroke). Fewer seats there means
   * less of the fleet exposed to that, and richer bots reach it by hopping
   * (bot.hop only offers a table the bot can actually afford).
   */
  categories: [
    { category: 'seen', boot: 200 },
    { category: 'blind', boot: 200 },
    { category: 'blind', boot: 5000 },
    { category: 'variation', boot: 50000, pool: num('variation-pool', 45), online: [12, 18] },
  ],

  /**
   * The stack a bot wants before it will sit at a table, counted in boots.
   *
   * Used by `hop` and by the too-rich-for-this-table fallback, so a bot never
   * moves somewhere it can only play a hand or two. The server refuses below
   * one boot; this is the bot's own judgement on top, and it is what keeps
   * the 200-boot regulars out of the 50,000 variation table.
   */
  bootsToSit: num('boots-to-sit', 8),

  /** Seconds between a bot considering moving tables. 0 disables wandering. */
  switchEvery: num('switch-every', 240),

  /**
   * Seconds between a bot considering a different STAKE — the other category,
   * or the 5,000 table instead of the 200. 0 disables it.
   *
   * Rarer than switchEvery on purpose. Switching seats is what a player does
   * when a table goes quiet; changing stake is a different decision, and a
   * fleet that made it constantly would leave whole stakes empty in waves.
   * Halved from 1800 (owner, 22 Sep 2026: bots should "randomly change
   * boot"); persona.hopRate still decides who ever does it at all, and
   * bot.hop only offers a table the bot can afford.
   */
  hopEvery: num('hop-every', 900),

  /** Average hands in a sitting before a bot gets up (each persona stays longer or shorter). */
  sessionHands: num('session-hands', 20),

  /** Average minutes a bot stays away after getting up. */
  restMinutes: decimal('rest-minutes', 25),

  /** Keeps every bot seated for good: no sittings, no rests (the pre-12 Sep 2026 fleet). */
  steady: flag('steady'),

  /** Multiplies how often bots talk. 0 silences the fleet. */
  chatScale: decimal('chat-scale', 1),

  /**
   * How long to wait between starting each bot. Two hundred logins and
   * websocket handshakes fired at once is a thundering herd against the very
   * server the fleet exists to make look healthy.
   */
  startStaggerMs: num('start-stagger-ms', 250),

  /**
   * What to do when a bot can no longer cover the boot, once the timed bonus
   * has been tried.
   *
   * "retire" leaves the seat empty and the fleet quietly shrinks — honest, and
   * visible in the log, but the lobby thins out over weeks.
   *
   * "rotate" gives that bot a fresh guest identity, which the server greets
   * with WELCOME_CHIPS. That keeps the fleet at full strength and CREATES
   * CHIPS: every rotation adds 200,000 to the economy out of nothing. The
   * running total is logged on every rotation precisely so that inflation is
   * something you watch rather than something that happens to you.
   */
  onBroke: str('on-broke', 'rotate'),

  quiet: flag('quiet'),

  /** Logs every bet a bot makes, with its hand. Noisy; for watching a small fleet. */
  verbose: flag('verbose'),
};

/** How many accounts belong to a lobby entry — its own `pool`, or the default. */
export const poolFor = (table) => table.pool ?? config.perCategory;

/**
 * How many of them should be seated, as `[min, max]` — the entry's own
 * `online`, or the fleet-wide target. Clamped to the pool, since the fleet
 * cannot seat more bots than belong to the entry, and clamped to at least one
 * so a tiny --per-category still puts somebody at the table.
 */
export const onlineRangeFor = (table) => {
  const [lo, hi] = table.online ?? [config.onlineMin, config.onlineMax];
  const pool = poolFor(table);
  const min = Math.max(1, Math.min(lo, hi, pool));
  return [min, Math.max(min, Math.min(Math.max(lo, hi), pool))];
};

export const totalBots = config.categories.reduce((sum, table) => sum + poolFor(table), 0);
