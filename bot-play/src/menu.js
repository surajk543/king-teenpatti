/**
 * The lobby as the SERVER publishes it.
 *
 * The fleet staffs a list the owner chose (config.categories), but the server
 * decides what the lobby actually offers and who may sit where. Until
 * 27 Sep 2026 the fleet read neither: a table the server retired left its
 * bots refused `table_not_offered` for ever, and a bot hopping on its own
 * judgement walked straight into a stack band — `over_entry_cap` at the
 * blind 200 table past 20 Lakh, `below_table_minimum` at a table with a floor.
 *
 * The server publishes both, in two places carrying the same entries:
 * `GET /api/tables` (public, no token — `tables[]` with category, bootAmount,
 * minChips, maxChips and a `version`) and every socket's
 * `session:ready.config.tables` beside `config.tableConfigVersion`
 * (go-server internal/game/tableconfig.go, CLAUDE.md §7.2). This module turns
 * that into two answers: which of the configured entries are staffed, and
 * which of them a bot carrying a given stack may choose.
 *
 * It never adds a table. The configured list stays the owner's choice of what
 * to staff; the menu can only take entries out of it (and give back one it
 * took out, when a later menu lists it again).
 */

/** How the server keys a public table: `table_configs.table_key`, "blind:200". */
export const menuKey = (category, boot) => `${category}:${boot}`;

/** A configured entry's key. */
export const keyOf = (entry) => menuKey(entry.category, entry.boot);

/** The same lobby entry — category and boot both, as the server matches them. */
export const sameTable = (a, b) => Boolean(a && b) && a.category === b.category && a.boot === b.boot;

const nonNegative = (value) => {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? n : 0;
};

/**
 * The server's `tables[]` as a map of `category:boot` → its stack band
 * `{ minChips, maxChips }` (0 = no limit at that end, the server's own
 * convention).
 *
 * Returns null when there is nothing usable — not a list, or a non-empty list
 * none of whose entries could be read — so a garbled answer is treated as "no
 * menu known" rather than as a menu that offers nothing. An EMPTY list is
 * kept as an empty map: to the server that means any pair is offered
 * (LOBBY_TABLES='' — tests), and splitByMenu reads it that way.
 *
 * Private templates are skipped: GET /api/tables lists them separately
 * (`privateTables`), and a private table is never quick-joined.
 */
export function readMenu(tables) {
  if (!Array.isArray(tables)) return null;
  const menu = new Map();
  for (const table of tables) {
    if (!table || table.isPrivate === true) continue;
    const boot = Number(table.bootAmount);
    if (typeof table.category !== 'string' || !Number.isSafeInteger(boot) || boot <= 0) continue;
    menu.set(menuKey(table.category, boot), {
      minChips: nonNegative(table.minChips),
      maxChips: nonNegative(table.maxChips),
    });
  }
  if (tables.length && !menu.size) return null;
  return menu;
}

/**
 * The configured entries the menu offers, and the ones it does not.
 *
 * No menu, or an empty one (any pair offered), offers every configured entry —
 * the fleet's behaviour before it read the menu at all.
 */
export function splitByMenu(entries, menu) {
  if (!menu || menu.size === 0) return { offered: [...entries], dropped: [] };
  const offered = [];
  const dropped = [];
  for (const entry of entries) (menu.has(keyOf(entry)) ? offered : dropped).push(entry);
  return { offered, dropped };
}

/**
 * Whether a table's band lets a stack sit down: at least its floor, and at
 * most its cap when it has one. Exactly the limit is allowed at either end, as
 * the server's assertWithinTableBand has it. No band known means no limit.
 */
export function bandAdmits(band, chips) {
  if (!band) return true;
  if (band.minChips > 0 && chips < band.minChips) return false;
  if (band.maxChips > 0 && chips > band.maxChips) return false;
  return true;
}

/**
 * The entries a bot may move to by its own choice (a hop): not the table it is
 * at, admitted by the table's band, and deep enough — `bootsToSit` boots — to
 * be a game rather than one hand and a walk back to the lobby.
 *
 * The band is checked here rather than discovered from the refusal, because a
 * refusal costs a round trip, shows up in the server's refusal metrics, and
 * tells the bot nothing it could not have read from the menu.
 */
export function tablesToChoose({ entries, current, chips, bootsToSit, bandFor = () => null }) {
  return entries.filter(
    (entry) => !sameTable(entry, current)
      && chips >= entry.boot * bootsToSit
      && bandAdmits(bandFor(entry), chips),
  );
}

/**
 * Somewhere to sit when nothing passes the boots-to-sit bar: the cheapest
 * other entry whose band admits the stack and whose boot the stack covers.
 *
 * The one-boot rule is the server's own (anything less is refused
 * `insufficient_chips`, which the bot treats as broke — and, under
 * `--on-broke rotate`, would throw a solvent account away). Null when no
 * offered table will take this stack at all.
 */
export function fallbackTable({ entries, current, chips, bandFor = () => null }) {
  const candidates = entries.filter(
    (entry) => !sameTable(entry, current) && chips >= entry.boot && bandAdmits(bandFor(entry), chips),
  );
  return candidates.sort((a, b) => a.boot - b.boot)[0] ?? null;
}

/**
 * The menu the whole fleet shares: one per process, handed to every bot and to
 * the fleet, so a change one bot learns of is the fleet's at once.
 */
export class TableMenu {
  /**
   * @param {object} options
   * @param {Array<{category: string, boot: number}>} options.entries the configured
   *   lobby entries (config.categories) — what the owner chose to staff.
   * @param {(message: string) => void} [options.log] where menu changes are reported.
   */
  constructor({ entries, log = () => {} }) {
    this.entries = entries;
    this.log = log;
    /** category:boot → band, or null while no menu is known. */
    this.menu = null;
    /** The catalogue version the menu came from; null when the server named none. */
    this.version = null;
    /** Keys the current menu leaves out, so a change is logged once, not per bot. */
    this.dropped = new Set();
    /**
     * Keys the server refused `table_not_offered` although the menu held
     * listed them — the menu is stale, and the server is the authority. Cleared
     * by the next menu, which says afresh what is offered.
     */
    this.retired = new Set();
  }

  /** Whether any menu has been read — from the REST call or a session. */
  get known() {
    return this.menu !== null;
  }

  /**
   * Takes a menu (`tables[]` as the server sends it). Logs, once each, every
   * configured entry it leaves out and every one it gives back. Returns false,
   * changing nothing, when `tables` is not a usable list.
   */
  apply(tables, { version = null, source = 'the server' } = {}) {
    const menu = readMenu(tables);
    if (!menu) return false;
    this.menu = menu;
    this.version = version;
    this.retired.clear();
    const { offered, dropped } = splitByMenu(this.entries, menu);
    for (const entry of dropped) {
      if (!this.dropped.has(keyOf(entry))) {
        this.log(`table menu (${source}): not staffing ${entry.category}/${entry.boot} — the server does not offer it`);
      }
    }
    for (const entry of offered) {
      if (this.dropped.has(keyOf(entry))) {
        this.log(`table menu (${source}): ${entry.category}/${entry.boot} is offered again — staffing it`);
      }
    }
    this.dropped = new Set(dropped.map(keyOf));
    return true;
  }

  /**
   * Reads the menu from `GET <serverUrl>/api/tables`. Public, no token, and
   * answered from the server's memory, so this is the menu the server
   * enforces. On any failure the menu stays unknown and the first
   * session:ready a bot receives supplies it instead (noticeSession).
   */
  async load(serverUrl, fetchImpl = globalThis.fetch) {
    try {
      const res = await fetchImpl(`${serverUrl}/api/tables`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const body = await res.json();
      const version = typeof body?.version === 'string' && body.version ? body.version : null;
      if (!this.apply(body?.tables, { version, source: 'GET /api/tables' })) {
        throw new Error('no usable tables list');
      }
      return true;
    } catch (e) {
      this.log(`table menu: could not read ${serverUrl}/api/tables (${e.message}) — taking it from the first session:ready`);
      return false;
    }
  }

  /**
   * A bot's `session:ready.config`. Its `tables` are the same entries GET
   * /api/tables serves, so a version different from the one held is applied
   * straight from here — one bot learns it and the whole fleet has it, with
   * no fleet-wide burst of identical requests after a server restart. A
   * session naming no version (an older server) is used only while no menu
   * is known at all.
   */
  noticeSession(sessionConfig) {
    if (!sessionConfig) return;
    const raw = sessionConfig.tableConfigVersion;
    const version = typeof raw === 'string' && raw ? raw : null;
    if (version ? version === this.version : this.known) return;
    this.apply(sessionConfig.tables, { version, source: 'session:ready' });
  }

  /**
   * The server refused this entry `table_not_offered`: out of every bot's
   * choices until the next menu, logged once however many bots are refused.
   */
  retire(entry, why = '') {
    const key = keyOf(entry);
    if (this.retired.has(key)) return;
    this.retired.add(key);
    this.log(`table menu: ${entry.category}/${entry.boot} refused as not offered${why ? ` (${why})` : ''} — no longer choosing it`);
  }

  /** Whether the fleet should staff this entry. */
  isOffered(entry) {
    if (this.retired.has(keyOf(entry))) return false;
    return !this.menu || this.menu.size === 0 || this.menu.has(keyOf(entry));
  }

  /** The configured entries the server offers, in the configured order. */
  offered() {
    return this.entries.filter((entry) => this.isOffered(entry));
  }

  /** The stack band of an entry, or null when none is known. */
  bandFor(entry) {
    return this.menu?.get(keyOf(entry)) ?? null;
  }

  /** Whether a bot carrying `chips` may sit at `entry` at all. */
  admits(entry, chips) {
    return this.isOffered(entry) && bandAdmits(this.bandFor(entry), chips);
  }

  /** tablesToChoose over the offered entries. */
  choices(current, chips, bootsToSit) {
    return tablesToChoose({
      entries: this.offered(), current, chips, bootsToSit, bandFor: (entry) => this.bandFor(entry),
    });
  }

  /** fallbackTable over the offered entries. */
  fallback(current, chips) {
    return fallbackTable({ entries: this.offered(), current, chips, bandFor: (entry) => this.bandFor(entry) });
  }
}
