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
    if (token.startsWith('--')) pairs.push([token.slice(2), all[i + 1] ?? 'true']);
    return pairs;
  }, []),
);

const num = (name, fallback) => {
  const raw = args[name] ?? process.env[name.toUpperCase().replace(/-/g, '_')];
  if (raw === undefined) return fallback;
  const n = Number.parseInt(raw, 10);
  if (Number.isNaN(n)) throw new Error(`bot-play: ${name} must be a whole number, got ${raw}`);
  return n;
};

const str = (name, fallback) =>
  args[name] ?? process.env[name.toUpperCase().replace(/-/g, '_')] ?? fallback;

const flag = (name) => args[name] === 'true' || args[name] === '' ||
  process.env[name.toUpperCase().replace(/-/g, '_')] === 'true';

export const config = {
  serverUrl: str('server-url', 'http://127.0.0.1:3000'),

  /**
   * Bots per table CATEGORY, not per table — a table seats five, so 66 here
   * fills about thirteen tables in each of the three lobby categories.
   */
  perCategory: num('per-category', 66),

  /**
   * The lobby's three tables (LOBBY_TABLES on the server). A bot belongs to
   * one of these for its whole life, and only ever switches between tables
   * within it, because that is what "switch table" means to a player.
   */
  categories: [
    { category: 'seen', boot: 200 },
    { category: 'blind', boot: 200 },
    { category: 'blind', boot: 5000 },
  ],

  /** Seconds between a bot considering moving tables. 0 disables wandering. */
  switchEvery: num('switch-every', 240),

  /**
   * Seconds between a bot considering a different STAKE — the other category,
   * or the 5,000 table instead of the 200. 0 disables it.
   *
   * Much rarer than switchEvery on purpose. Switching seats is what a player
   * does when a table goes quiet; changing stake is a different decision, and
   * a fleet that made it often would leave whole stakes empty in waves.
   */
  hopEvery: num('hop-every', 1800),

  /**
   * How long to wait between starting each bot. Two hundred logins and
   * websocket handshakes fired at once is a thundering herd against the very
   * server the fleet exists to make look healthy.
   */
  startStaggerMs: num('start-stagger-ms', 250),

  /**
   * What to do when a bot can no longer cover the boot.
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
};

export const totalBots = config.perCategory * config.categories.length;
