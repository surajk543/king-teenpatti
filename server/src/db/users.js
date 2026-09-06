import { getDatabase } from './index.js';
import { uuid } from '../util/ids.js';
import config from '../config/index.js';

const now = () => Date.now();

const publicUser = (row) =>
  row && {
    id: row.id,
    provider: row.provider,
    displayName: row.display_name,
    email: row.email,
    avatarUrl: row.avatar_url,
    chips: row.chips,
    handsPlayed: row.hands_played,
    handsWon: row.hands_won,
    biggestPot: row.biggest_pot,
    createdAt: row.created_at,
    lastLoginAt: row.last_login_at,
  };

export function findById(id) {
  const row = getDatabase().prepare('SELECT * FROM users WHERE id = ?').get(id);
  return publicUser(row);
}

export function findByProvider(provider, providerUserId) {
  const row = getDatabase()
    .prepare('SELECT * FROM users WHERE provider = ? AND provider_user_id = ?')
    .get(provider, providerUserId);
  return publicUser(row);
}

/**
 * Finds the account behind a verified provider profile, creating it (with the
 * welcome chip grant) the first time we see it. Returns `{ user, isNew }`.
 *
 * The insert and the welcome-grant ledger row go in one transaction so a crash
 * can never leave an account whose balance is not backed by the ledger.
 */
export function upsertFromProfile(profile) {
  const db = getDatabase();
  const timestamp = now();

  const run = db.transaction(() => {
    const existing = db
      .prepare('SELECT * FROM users WHERE provider = ? AND provider_user_id = ?')
      .get(profile.provider, profile.providerUserId);

    if (existing) {
      db.prepare(
        `UPDATE users
            SET display_name  = ?,
                email         = COALESCE(?, email),
                avatar_url    = COALESCE(?, avatar_url),
                updated_at    = ?,
                last_login_at = ?
          WHERE id = ?`,
      ).run(
        profile.displayName || existing.display_name,
        profile.email ?? null,
        profile.avatarUrl ?? null,
        timestamp,
        timestamp,
        existing.id,
      );
      const row = db.prepare('SELECT * FROM users WHERE id = ?').get(existing.id);
      return { user: publicUser(row), isNew: false };
    }

    const id = uuid();
    const chips = config.game.welcomeChips;

    db.prepare(
      `INSERT INTO users (id, provider, provider_user_id, display_name, email, avatar_url,
                          chips, created_at, updated_at, last_login_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).run(
      id,
      profile.provider,
      profile.providerUserId,
      profile.displayName,
      profile.email ?? null,
      profile.avatarUrl ?? null,
      chips,
      timestamp,
      timestamp,
      timestamp,
    );

    db.prepare(
      `INSERT INTO chip_ledger (user_id, hand_id, delta, balance, reason, created_at)
       VALUES (?, NULL, ?, ?, 'welcome_bonus', ?)`,
    ).run(id, chips, chips, timestamp);

    const row = db.prepare('SELECT * FROM users WHERE id = ?').get(id);
    return { user: publicUser(row), isNew: true };
  });

  return run();
}

/**
 * Applies a chip delta and appends the matching ledger row atomically.
 * Throws when the delta would drive the balance negative, which is the last
 * line of defence behind the in-memory table's own affordability checks.
 */
export function applyChipDelta({ userId, delta, reason, handId = null }) {
  const db = getDatabase();

  const run = db.transaction(() => {
    const row = db.prepare('SELECT chips FROM users WHERE id = ?').get(userId);
    if (!row) throw new Error(`unknown user ${userId}`);

    const balance = row.chips + delta;
    if (balance < 0) throw new Error(`insufficient chips for ${userId}`);

    const timestamp = now();
    db.prepare('UPDATE users SET chips = ?, updated_at = ? WHERE id = ?').run(balance, timestamp, userId);
    db.prepare(
      `INSERT INTO chip_ledger (user_id, hand_id, delta, balance, reason, created_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
    ).run(userId, handId, delta, balance, reason, timestamp);

    return balance;
  });

  return run();
}

/**
 * Settles a whole hand in one transaction: net chip movement per seat, the
 * hand record, and the play/win counters. `entries` is
 * `[{ userId, delta, isWinner }]` where deltas already net out the pot.
 */
export function settleHand({ hand, entries }) {
  const db = getDatabase();

  const run = db.transaction(() => {
    db.prepare(
      `INSERT INTO hands (id, room_id, hand_no, pot, winner_id, win_reason,
                          boot_amount, started_at, ended_at, summary_json)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).run(
      hand.id,
      hand.roomId,
      hand.handNo,
      hand.pot,
      hand.winnerId ?? null,
      hand.winReason ?? null,
      hand.bootAmount,
      hand.startedAt,
      hand.endedAt,
      JSON.stringify(hand.summary),
    );

    const balances = {};
    const timestamp = Date.now();

    for (const entry of entries) {
      const row = db.prepare('SELECT chips FROM users WHERE id = ?').get(entry.userId);
      if (!row) continue;

      const balance = Math.max(0, row.chips + entry.delta);
      db.prepare(
        `UPDATE users
            SET chips        = ?,
                hands_played = hands_played + 1,
                hands_won    = hands_won + ?,
                biggest_pot  = MAX(biggest_pot, ?),
                updated_at   = ?
          WHERE id = ?`,
      ).run(balance, entry.isWinner ? 1 : 0, entry.isWinner ? hand.pot : 0, timestamp, entry.userId);

      db.prepare(
        `INSERT INTO chip_ledger (user_id, hand_id, delta, balance, reason, created_at)
         VALUES (?, ?, ?, ?, ?, ?)`,
      ).run(entry.userId, hand.id, entry.delta, balance, entry.isWinner ? 'hand_win' : 'hand_loss', timestamp);

      balances[entry.userId] = balance;
    }

    return balances;
  });

  return run();
}

export function recentHands(userId, limit = 20) {
  return getDatabase()
    .prepare(
      `SELECT h.* FROM hands h
         JOIN chip_ledger l ON l.hand_id = h.id
        WHERE l.user_id = ?
        ORDER BY h.ended_at DESC
        LIMIT ?`,
    )
    .all(userId, limit)
    .map((row) => ({
      id: row.id,
      roomId: row.room_id,
      handNo: row.hand_no,
      pot: row.pot,
      winnerId: row.winner_id,
      winReason: row.win_reason,
      endedAt: row.ended_at,
      summary: JSON.parse(row.summary_json),
    }));
}

export default {
  findById,
  findByProvider,
  upsertFromProfile,
  applyChipDelta,
  settleHand,
  recentHands,
};
