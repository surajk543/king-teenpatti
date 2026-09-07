import { withTransaction } from './index.js';
import {
  dbTransactionDuration,
  dbTransactionErrorsTotal,
  handStartDuration,
  settlementDuration,
  safeLabel,
  timed,
} from '../metrics/index.js';

/**
 * Every chip movement a hand makes, each as one PostgreSQL transaction.
 *
 * This is the shape the game's money follows:
 *
 *   validate in memory (turn, amount, balance)
 *     → BEGIN
 *     → lock the wallet row            SELECT … FOR UPDATE
 *     → deduct the bet                 UPDATE users
 *     → add it to the pot              UPDATE pots
 *     → append the ledger entry        INSERT chip_ledger   (action_id UNIQUE)
 *     → save the table state/version   UPSERT game_states   (version must rise)
 *     → COMMIT
 *   → only then does the table change what it holds in memory and broadcast.
 *
 * Anything that fails inside the transaction rolls back completely, throws a
 * `LedgerError` with a code the table can turn into a `GameError`, and leaves
 * the game state untouched.
 */
export class LedgerError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'LedgerError';
    this.code = code;
  }
}

const now = () => Date.now();

/** PostgreSQL's unique_violation. */
const UNIQUE_VIOLATION = '23505';

/**
 * Turns a low-level failure into a LedgerError the caller can reason about.
 * The action_id UNIQUE index is what makes a retried move harmless, and a
 * violation on it is the one database error that is expected in normal play.
 */
const classify = (error) => {
  if (error instanceof LedgerError) return error;
  if (error?.code === UNIQUE_VIOLATION && /action_id/.test(error.detail ?? error.constraint ?? '')) {
    return new LedgerError('duplicate_action', 'That move has already been applied');
  }
  const wrapped = new LedgerError('persist_failed', error?.message ?? 'database write failed');
  wrapped.cause = error;
  return wrapped;
};

/** The codes a ledger operation can fail with; anything else is folded into "other". */
const KNOWN_LEDGER_CODES = new Set([
  'duplicate_action',
  'insufficient_chips',
  'stale_state',
  'no_pot',
  'unknown_user',
  'invalid_amount',
  'persist_failed',
]);

/**
 * Runs one ledger operation under its metrics: the transaction's duration by
 * operation, and — when it rolls back — a count by error code. Every failure
 * leaves here as a LedgerError, whatever it started out as.
 */
async function transact(op, fn) {
  try {
    return await timed(dbTransactionDuration, { op }, fn);
  } catch (error) {
    const refusal = classify(error);
    dbTransactionErrorsTotal.inc({ op, code: safeLabel(refusal.code, KNOWN_LEDGER_CODES) });
    throw refusal;
  }
}

/**
 * Locks a wallet row and returns its balance. Locking first, then reading, is
 * what stops two bets from the same account racing past the balance check.
 */
async function lockWallet(client, userId) {
  const { rows } = await client.query(
    'SELECT chips FROM users WHERE id = $1 FOR UPDATE',
    [userId],
  );
  if (rows.length === 0) throw new LedgerError('unknown_user', `unknown user ${userId}`);
  return rows[0].chips;
}

async function appendLedger(client, { userId, handId, actionId, delta, balance, reason, at }) {
  await client.query(
    `INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7)`,
    [userId, handId ?? null, actionId ?? null, delta, balance, reason, at],
  );
}

/**
 * Saves the table's snapshot, refusing to go backwards in version.
 *
 * A single process always presents a rising version, so the WHERE clause is a
 * no-op for it; its purpose is the other case — a second process that thinks
 * it owns the same room — whose stale write is rejected and rolled back.
 */
async function saveState(client, { roomId, handId, version, state, at }) {
  if (version === undefined || version === null) return;
  const { rowCount } = await client.query(
    `INSERT INTO game_states (room_id, hand_id, version, state, updated_at)
     VALUES ($1, $2, $3, $4::jsonb, $5)
     ON CONFLICT (room_id) DO UPDATE
        SET hand_id = EXCLUDED.hand_id,
            version = EXCLUDED.version,
            state = EXCLUDED.state,
            updated_at = EXCLUDED.updated_at
      WHERE game_states.version < EXCLUDED.version`,
    [roomId, handId ?? null, version, JSON.stringify(state ?? {}), at],
  );
  if (rowCount === 0) {
    throw new LedgerError('stale_state', `state version ${version} is not newer than the stored one`);
  }
}

/**
 * The transaction behind a chaal, raise or show: one player's chips into the
 * pot. Returns the wallet balance after the deduction, which the table adopts
 * as the truth.
 */
export async function bet({ userId, amount, roomId, handId, actionId, reason = 'bet', version, state }) {
  return transact('bet', async () => {
    if (!Number.isInteger(amount) || amount <= 0) {
      throw new LedgerError('invalid_amount', 'bet amount must be a positive integer');
    }

    return withTransaction(async (client) => {
      const at = now();

      const chips = await lockWallet(client, userId);
      if (chips < amount) {
        throw new LedgerError('insufficient_chips', `insufficient chips for ${userId}`);
      }
      const balance = chips - amount;

      await client.query('UPDATE users SET chips = $1, updated_at = $2 WHERE id = $3', [balance, at, userId]);

      const pot = await client.query(
        'UPDATE pots SET amount = amount + $1 WHERE hand_id = $2',
        [amount, handId],
      );
      if (pot.rowCount === 0) {
        throw new LedgerError('no_pot', `no open pot for hand ${handId}`);
      }

      await appendLedger(client, { userId, handId, actionId, delta: -amount, balance, reason, at });
      await saveState(client, { roomId, handId, version, state, at });

      // `persisted` tells the table how much of this stake the account has
      // already been debited — here, all of it — so settlement knows the only
      // movement left is the payout.
      return { balance, persisted: amount };
    });
  });
}

/**
 * Opens the pot and takes the boot from every participant, in one transaction.
 *
 * All wallet rows are locked in a fixed order (by user id) so two tables that
 * happen to share a player cannot deadlock against each other. If any one
 * player cannot cover the boot the whole start is refused and nothing is
 * charged — the table then sweeps them and tries again.
 */
export async function collectBoot({ roomId, handId, bootAmount, entries, version, state }) {
  // The boot transaction is what a hand start costs, so the same span feeds
  // both the ledger histogram and the hand-start one.
  return timed(handStartDuration, {}, () => transact('boot', () =>
    withTransaction(async (client) => {
      const at = now();
      const ordered = [...entries].sort((a, b) => (a.userId < b.userId ? -1 : 1));
      const balances = {};

      for (const { userId, amount } of ordered) {
        const chips = await lockWallet(client, userId);
        if (chips < amount) {
          const error = new LedgerError('insufficient_chips', `insufficient chips for ${userId}`);
          error.userId = userId;
          throw error;
        }
        balances[userId] = chips - amount;
        await client.query('UPDATE users SET chips = $1, updated_at = $2 WHERE id = $3', [balances[userId], at, userId]);
      }

      const total = ordered.reduce((sum, entry) => sum + entry.amount, 0);
      await client.query(
        `INSERT INTO pots (hand_id, room_id, boot_amount, amount, opened_at)
         VALUES ($1, $2, $3, $4, $5)`,
        [handId, roomId, bootAmount, total, at],
      );

      for (const { userId, amount } of ordered) {
        await appendLedger(client, {
          userId,
          handId,
          // Deterministic, so a retried start cannot ante the same player twice.
          actionId: `${handId}:boot:${userId}`,
          delta: -amount,
          balance: balances[userId],
          reason: 'boot',
          at,
        });
      }

      await saveState(client, { roomId, handId, version, state, at });
      return { balances, persisted: bootAmount };
    })));
}

/**
 * Settles a whole hand in one transaction: the hand record, the winner's
 * payout (every stake was already banked as it was bet, so the only movement
 * left is the pot going to the winner), the play/win counters, the pot
 * closing, and the final state snapshot.
 *
 * `entries` is `[{ userId, delta, isWinner, didChaal, leftMidHand }]` with
 * deltas already computed by the table. Returns `{ userId: balance }` for
 * every entry, which the table adopts.
 */
export async function settle({ hand, entries, version, state }) {
  return timed(settlementDuration, {}, () => transact('settle', () =>
    withTransaction(async (client) => {
      const at = now();

      await client.query(
        `INSERT INTO hands (id, room_id, hand_no, pot, winner_id, win_reason,
                            boot_amount, started_at, ended_at, summary_json)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb)
         ON CONFLICT (id) DO NOTHING`,
        [
          hand.id,
          hand.roomId,
          hand.handNo,
          hand.pot,
          hand.winnerId ?? null,
          hand.winReason ?? null,
          hand.bootAmount,
          hand.startedAt,
          hand.endedAt,
          JSON.stringify(hand.summary ?? []),
        ],
      );

      const balances = {};
      const ordered = [...entries].sort((a, b) => (a.userId < b.userId ? -1 : 1));

      for (const entry of ordered) {
        const { rows } = await client.query('SELECT chips FROM users WHERE id = $1 FOR UPDATE', [entry.userId]);
        if (rows.length === 0) continue;

        // Never below zero: a delta here is a payout or a correction, and the
        // wallet CHECK would reject an overdraft anyway.
        const balance = Math.max(0, rows[0].chips + entry.delta);

        // "Played" means the player committed chips beyond the boot — posting
        // the ante and folding straight away is not a hand played.
        const played = entry.didChaal ? 1 : 0;
        const left = entry.leftMidHand ? 1 : 0;
        const lost = !entry.isWinner && !entry.leftMidHand ? 1 : 0;

        await client.query(
          `UPDATE users
              SET chips          = $1,
                  hands_played   = hands_played + $2,
                  hands_won      = hands_won + $3,
                  hands_lost     = hands_lost + $4,
                  hands_left_mid = hands_left_mid + $5,
                  total_winnings = total_winnings + $6,
                  biggest_pot    = GREATEST(biggest_pot, $7),
                  updated_at     = $8
            WHERE id = $9`,
          [
            balance,
            played,
            entry.isWinner ? 1 : 0,
            lost,
            left,
            entry.isWinner ? hand.pot : 0,
            entry.isWinner ? hand.pot : 0,
            at,
            entry.userId,
          ],
        );

        // A zero delta is still recorded: the row is what says this player was
        // in the hand and how it ended for them.
        await appendLedger(client, {
          userId: entry.userId,
          handId: hand.id,
          actionId: `${hand.id}:settle:${entry.userId}`,
          delta: entry.delta,
          balance,
          reason: entry.isWinner ? 'hand_win' : 'hand_loss',
          at,
        });

        balances[entry.userId] = balance;
      }

      await client.query(
        'UPDATE pots SET closed_at = $1, winner_id = $2 WHERE hand_id = $3',
        [at, hand.winnerId ?? null, hand.id],
      );

      await saveState(client, { roomId: hand.roomId, handId: null, version, state, at });
      return balances;
    })));
}

/**
 * The bundle a Table is built with. Kept as a plain object so a test can hand
 * the table an in-memory stand-in with the same three methods.
 */
export function createLedger() {
  return { bet, collectBoot, settle };
}

export default { bet, collectBoot, settle, createLedger, LedgerError };
