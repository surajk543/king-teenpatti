/**
 * The cluster registry: how N worker processes find each other's players and
 * tables without sharing any of them.
 *
 * Each worker is a whole game server — its own RoomManager, tables and
 * sockets — and a table never moves between workers. What *does* cross
 * workers is a player: nginx hands a fresh connection to whichever worker has
 * the fewest, which is not necessarily the one holding that player's seat, or
 * the one running the private table whose code they typed. Three small
 * PostgreSQL tables answer "where is this player?" and "where is this room?",
 * and the socket layer sends the client to the right worker with a
 * `session:redirect` carrying that worker's Socket.IO path (`/w<id>/socket.io`,
 * which only nginx knows about — the workers themselves all serve the default
 * `/socket.io`).
 *
 *   cluster_workers  one row per live worker, heartbeat every 5 s
 *   cluster_players  user -> worker (and room) holding their seat
 *   cluster_rooms    table code -> worker running it
 *
 * Liveness is the heartbeat: a worker whose heartbeat is older than 15 s is
 * dead as far as routing goes, and a player mapped to it is simply handled by
 * whichever worker they reached (a takeover). The heartbeat is written on a
 * connection of its own, not the shared pool, so a worker whose pool is queued
 * behind a burst of ledger transactions is slow but never mistaken for dead.
 *
 * A player row is a claim, and claiming is a compare-and-set: a worker may
 * only take a row that is its own already, or whose owner has stopped
 * heartbeating. That is what keeps one wallet from being seated at two tables
 * on two workers at once — the second worker's claim is refused and it sends
 * the player to the first. The reverse case, a worker that was declared dead
 * and came back with a seat somebody else has since taken over, is caught on
 * its next heartbeat: every seat it still holds is checked against the rows,
 * and a seat whose row now belongs to another live worker is released.
 *
 * Rows age in two ways. A dead worker's rows are trusted for the resume window
 * — `resumeOfferMs + reconnectGraceMs` — after its last heartbeat and treated
 * as absent past that (deleted on the way past). A live worker never lets its
 * rows age: they are not refreshed in bulk (that would rewrite every seated
 * player's row every 5 s); instead the socket layer deletes a lapsed seat's row
 * itself once the resume offer behind it has expired.
 *
 * In single-process mode (no WORKER_ID) `createRegistry()` returns a null
 * registry whose every method is a no-op returning "nothing anywhere", so the
 * callers need no branches of their own and the server behaves exactly as it
 * did before workers existed.
 */
import config from '../config/index.js';
import { query as defaultQuery, openDedicatedClient as defaultOpenClient } from '../db/index.js';
import logger from '../util/logger.js';

/** How often a worker refreshes its heartbeat and checks its seats. */
export const HEARTBEAT_MS = 5000;
/** A worker whose heartbeat is older than this is treated as gone. */
export const WORKER_STALE_MS = 15000;
/** The Socket.IO path every client uses when there is only one process. */
export const SINGLE_PROCESS_PATH = '/socket.io';

/** The nginx location that reaches exactly one worker's Socket.IO endpoint. */
export const socketPathFor = (workerId) => `/w${workerId}/socket.io`;

/**
 * How long a dead worker's rows stay meaningful after its last heartbeat. A
 * held seat lasts the reconnect grace; the resume offer that follows lasts
 * `resumeOfferMs` more — past both there is nothing on the old worker worth
 * sending the player back to, and nothing there to stop another worker
 * seating them.
 */
const defaultRowTtlMs = () => config.game.resumeOfferMs + config.game.reconnectGraceMs;

/** What claimPlayer() answers when there is nobody to lose a claim to. */
const CLAIMED = Object.freeze({ claimed: true });

// ------------------------------------------------------------ null registry

/**
 * The registry for a single-process server: nothing is recorded, nobody is
 * anywhere else, everything is local. Every method exists so callers can use
 * it without checking which mode they are in.
 */
export function createNullRegistry() {
  return {
    enabled: false,
    workerId: 0,
    workerCount: 1,
    port: config.port,
    async start() {},
    async stop() {},
    watchSeats() {},
    socketPathFor: () => SINGLE_PROCESS_PATH,
    isLocal: () => true,
    async claimPlayer() {
      return CLAIMED;
    },
    async releasePlayer() {},
    async whereIsPlayer() {
      return null;
    },
    async publishRoom() {},
    async retireRoom() {},
    async whereIsRoom() {
      return null;
    },
  };
}

// ------------------------------------------------------------------ registry

/**
 * Builds the registry for one worker.
 *
 * @param {object} options
 * @param {number} options.workerId       1-based id of this worker; 0/absent = single-process mode
 * @param {number} options.workerCount    how many workers the cluster runs
 * @param {number} options.port           the port this worker listens on (informational)
 * @param {Function} options.query        `(text, params) => Promise<{rows}>`, default the pg pool
 * @param {Function} [options.openClient] opens the heartbeat's own connection; default a pg.Client
 *                                        on the pool's database and schema
 * @param {number} [options.heartbeatMs]  heartbeat interval; the default is HEARTBEAT_MS (tests shorten it)
 * @param {number} [options.rowTtlMs]     how long a dead worker's rows stay meaningful
 */
export function createRegistry({
  workerId = 0,
  workerCount = 1,
  port = config.port,
  query = defaultQuery,
  openClient = defaultOpenClient,
  heartbeatMs = HEARTBEAT_MS,
  rowTtlMs,
} = {}) {
  const id = Number.parseInt(workerId, 10);
  if (!Number.isInteger(id) || id <= 0) return createNullRegistry();

  const count = Math.max(1, Number.parseInt(workerCount, 10) || 1);
  const ttl = () => (Number.isFinite(rowTtlMs) ? rowTtlMs : defaultRowTtlMs());
  const startedAt = Date.now();
  let heartbeatTimer = null;
  /** Set by stop(): a worker on its way out records nothing new. */
  let stopped = false;
  /** The heartbeat's own connection, opened lazily and reopened after an error. */
  let heartbeatClient = null;
  /** Where the socket layer's seats are, and what to do with one that is no longer ours. */
  let seatedUserIds = null;
  let onForeignSeat = null;

  /** Fire-and-forget housekeeping: failure is logged, never thrown. */
  const background = (promise, message, meta) => {
    promise.catch((error) => logger.warn(message, { ...meta, worker: id, error: error.message }));
  };

  /**
   * Runs one statement on the heartbeat's dedicated connection, opening it if
   * need be. A connection that fails is dropped and reopened next time; while
   * it cannot be opened at all the pool is used, so a heartbeat is only ever
   * late, never skipped, when the dedicated connection is what is broken.
   */
  const heartbeatQuery = async (text, params) => {
    if (!heartbeatClient) {
      try {
        heartbeatClient = await openClient();
        heartbeatClient.on('error', (error) => {
          logger.warn('cluster heartbeat connection lost', { worker: id, error: error.message });
          dropHeartbeatClient();
        });
      } catch (error) {
        logger.warn('cluster heartbeat connection failed; using the pool this time', {
          worker: id,
          error: error.message,
        });
        return query(text, params);
      }
    }
    try {
      return await heartbeatClient.query(text, params);
    } catch (error) {
      dropHeartbeatClient();
      throw error;
    }
  };

  const dropHeartbeatClient = () => {
    const client = heartbeatClient;
    heartbeatClient = null;
    if (client) client.end().catch(() => {});
  };

  /** Writes this worker's heartbeat. One row, every interval — nothing else is rewritten. */
  const heartbeat = async () => {
    await heartbeatQuery(
      `INSERT INTO cluster_workers (worker_id, worker_count, port, pid, started_at, heartbeat_at)
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT (worker_id) DO UPDATE
         SET worker_count = EXCLUDED.worker_count,
             port         = EXCLUDED.port,
             pid          = EXCLUDED.pid,
             started_at   = EXCLUDED.started_at,
             heartbeat_at = EXCLUDED.heartbeat_at`,
      [id, count, port, process.pid, startedAt, Date.now()],
    );
  };

  /**
   * Checks every seat this worker holds against the registry. A seat whose row
   * now names another worker was taken over while this one was thought dead
   * (its heartbeat stale, or its row aged out): the player has since been
   * seated elsewhere, so the seat here is a zombie that would otherwise keep
   * charging boots against the same wallet, and the socket layer is told to
   * release it. Only rows with a *live* owner count — a dead owner's row is
   * one this worker would win back by claiming it.
   */
  const reconcileSeats = async () => {
    if (!seatedUserIds || !onForeignSeat) return;
    const userIds = seatedUserIds();
    if (userIds.length === 0) return;
    const { rows } = await heartbeatQuery(
      `SELECT p.user_id, p.worker_id
         FROM cluster_players p
         JOIN cluster_workers w ON w.worker_id = p.worker_id
        WHERE p.user_id = ANY($1)
          AND p.worker_id <> $2
          AND w.heartbeat_at > $3`,
      [userIds, id, Date.now() - WORKER_STALE_MS],
    );
    for (const row of rows) {
      try {
        await onForeignSeat({ userId: row.user_id, workerId: Number(row.worker_id) });
      } catch (error) {
        logger.warn('cluster seat reconciliation failed', {
          worker: id,
          userId: row.user_id,
          error: error.message,
        });
      }
    }
  };

  const tick = async () => {
    await heartbeat();
    await reconcileSeats();
  };

  /**
   * Drops every row this worker owns. Called on start — a worker that has just
   * come up has no tables and no seats, so anything still pointing at it is
   * left over from before it went down — and on stop, so a worker that is
   * gone stops attracting players.
   */
  const purgeOwnRows = async () => {
    await query('DELETE FROM cluster_players WHERE worker_id = $1', [id]);
    await query('DELETE FROM cluster_rooms WHERE worker_id = $1', [id]);
  };

  /** Turns a joined row into the answer callers get, or null once it is too old to trust. */
  const locate = (row, now) => {
    const heartbeatAt = row.heartbeat_at ?? null;
    const alive = heartbeatAt !== null && now - heartbeatAt <= WORKER_STALE_MS;
    // A live worker's rows never age — it deletes the ones it is done with
    // itself. A dead worker's rows are trusted for the resume window after
    // its last heartbeat (or the row's own stamp, if that is later).
    const lastSeen = Math.max(row.updated_at ?? 0, heartbeatAt ?? 0);
    const expired = now - lastSeen > ttl();
    return {
      workerId: Number(row.worker_id),
      roomId: row.room_id ?? null,
      alive,
      path: socketPathFor(Number(row.worker_id)),
      expired,
    };
  };

  return {
    enabled: true,
    workerId: id,
    workerCount: count,
    port,

    // ------------------------------------------------------------ lifecycle

    /** Registers this worker and starts the heartbeat. Safe to call again after stop(). */
    async start() {
      if (heartbeatTimer) return;
      stopped = false;
      await purgeOwnRows();
      await heartbeat();
      heartbeatTimer = setInterval(() => {
        background(tick(), 'cluster heartbeat failed');
      }, heartbeatMs);
      // The heartbeat must never be what keeps a finished process alive.
      heartbeatTimer.unref?.();
      logger.info('cluster worker registered', { worker: id, workers: count, port });
    },

    /**
     * Withdraws this worker and everything it owns, and stops recording. The
     * server calls this *first* on shutdown, before a single socket is closed:
     * the moment the rows are gone, players dropped by this worker are served
     * wherever they reconnect instead of being sent back to a closed port.
     */
    async stop() {
      stopped = true;
      if (heartbeatTimer) clearInterval(heartbeatTimer);
      heartbeatTimer = null;
      dropHeartbeatClient();
      await purgeOwnRows();
      await query('DELETE FROM cluster_workers WHERE worker_id = $1', [id]);
    },

    /**
     * Gives the heartbeat the seats to check: `seatedUserIds()` lists the
     * players seated on this worker, `onForeignSeat({userId, workerId})` is
     * called for each one whose registry row now belongs to another live
     * worker. Bound by the socket layer, which owns both the seats and the
     * sockets to tell.
     */
    watchSeats({ seatedUserIds: list, onForeignSeat: handler }) {
      seatedUserIds = list;
      onForeignSeat = handler;
    },

    // -------------------------------------------------------------- routing

    socketPathFor,

    isLocal(workerId) {
      return Number(workerId) === id;
    },

    // -------------------------------------------------------------- players

    /**
     * Records that this worker holds the player's seat at `roomId` — if it may.
     * A compare-and-set: the row is written when there is none, when this
     * worker owns it already, or when its owner has stopped heartbeating (or
     * is not registered at all). Otherwise the player is seated on another
     * live worker and the answer is `{claimed: false, workerId, path}` so the
     * caller can undo its seating and send the player there.
     */
    async claimPlayer(userId, roomId = null) {
      if (stopped) return CLAIMED;
      for (let attempt = 0; attempt < 2; attempt += 1) {
        const now = Date.now();
        const { rows } = await query(
          `INSERT INTO cluster_players (user_id, worker_id, room_id, updated_at)
           VALUES ($1, $2, $3, $4)
           ON CONFLICT (user_id) DO UPDATE
             SET worker_id  = EXCLUDED.worker_id,
                 room_id    = EXCLUDED.room_id,
                 updated_at = EXCLUDED.updated_at
             WHERE cluster_players.worker_id = EXCLUDED.worker_id
                OR NOT EXISTS (
                     SELECT 1 FROM cluster_workers w
                      WHERE w.worker_id = cluster_players.worker_id
                        AND w.heartbeat_at > $5)
           RETURNING worker_id`,
          [userId, id, roomId, now, now - WORKER_STALE_MS],
        );
        if (rows.length > 0) return CLAIMED;

        const { rows: owners } = await query(
          'SELECT worker_id FROM cluster_players WHERE user_id = $1',
          [userId],
        );
        // Released between the two statements — the next attempt will take it.
        if (owners.length === 0) continue;
        const owner = Number(owners[0].worker_id);
        return { claimed: false, workerId: owner, path: socketPathFor(owner) };
      }
      return CLAIMED;
    },

    /**
     * Forgets the player's seat — only if this worker is the one holding the
     * claim. A worker never withdraws another worker's claim: after a takeover
     * the old worker may still be tidying up a seat the player has long since
     * been given elsewhere.
     */
    async releasePlayer(userId) {
      await query('DELETE FROM cluster_players WHERE user_id = $1 AND worker_id = $2', [userId, id]);
    },

    /**
     * Which worker holds this player's seat (or held seat, or resume offer).
     * `alive` says whether that worker is still heartbeating; a dead worker's
     * row that has outlived the resume window is treated as absent and removed.
     */
    async whereIsPlayer(userId) {
      const { rows } = await query(
        `SELECT p.worker_id, p.room_id, p.updated_at, w.heartbeat_at
           FROM cluster_players p
           LEFT JOIN cluster_workers w ON w.worker_id = p.worker_id
          WHERE p.user_id = $1`,
        [userId],
      );
      if (rows.length === 0) return null;
      const now = Date.now();
      const found = locate(rows[0], now);
      if (found.expired) {
        // Matched on updated_at so a claim made in the meantime survives.
        background(
          query('DELETE FROM cluster_players WHERE user_id = $1 AND updated_at = $2', [userId, rows[0].updated_at]),
          'stale player row cleanup failed',
        );
        return null;
      }
      const { expired, ...where } = found;
      return where;
    },

    // ---------------------------------------------------------------- rooms

    /** Advertises a table this worker runs, so a code typed anywhere finds it. */
    async publishRoom({ code, roomId, isPrivate = false, category, bootAmount }) {
      if (stopped) return;
      await query(
        `INSERT INTO cluster_rooms (code, room_id, worker_id, is_private, category, boot_amount, updated_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7)
         ON CONFLICT (code) DO UPDATE
           SET room_id     = EXCLUDED.room_id,
               worker_id   = EXCLUDED.worker_id,
               is_private  = EXCLUDED.is_private,
               category    = EXCLUDED.category,
               boot_amount = EXCLUDED.boot_amount,
               updated_at  = EXCLUDED.updated_at`,
        [String(code).toUpperCase(), roomId, id, Boolean(isPrivate), category, bootAmount, Date.now()],
      );
    },

    /** Withdraws a table's advertisement — only this worker's own. */
    async retireRoom(code) {
      await query('DELETE FROM cluster_rooms WHERE code = $1 AND worker_id = $2', [String(code).toUpperCase(), id]);
    },

    /** Which worker runs the table with this code, if any worker does. */
    async whereIsRoom(code) {
      const wanted = String(code ?? '').toUpperCase();
      if (!wanted) return null;
      const { rows } = await query(
        `SELECT r.room_id, r.worker_id, r.updated_at, w.heartbeat_at
           FROM cluster_rooms r
           LEFT JOIN cluster_workers w ON w.worker_id = r.worker_id
          WHERE r.code = $1`,
        [wanted],
      );
      if (rows.length === 0) return null;
      const now = Date.now();
      const found = locate(rows[0], now);
      if (found.expired) {
        // A table whose worker has been gone this long no longer exists.
        background(
          query('DELETE FROM cluster_rooms WHERE code = $1 AND room_id = $2', [wanted, rows[0].room_id]),
          'stale room row cleanup failed',
        );
        return null;
      }
      const { expired, ...where } = found;
      return where;
    },
  };
}

export default createRegistry;
