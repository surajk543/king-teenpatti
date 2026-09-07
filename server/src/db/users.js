import { getDatabase } from './index.js';
import { uuid } from '../util/ids.js';
import config from '../config/index.js';

const now = () => Date.now();

/** Chips granted when a "hands played" milestone is collected. */
export const MILESTONE_REWARD = 25000;
/** Hands between milestone rewards. */
export const MILESTONE_EVERY = 25;
/** Chips granted by the timed bonus. */
export const TIMED_BONUS_REWARD = 10000;
/** How long the timed bonus takes to recharge. */
export const TIMED_BONUS_INTERVAL_MS = 4 * 60 * 60 * 1000;

/** The milestone this many played hands has reached, e.g. 63 -> 50. */
const milestoneFor = (handsPlayed) =>
  Math.floor(handsPlayed / MILESTONE_EVERY) * MILESTONE_EVERY;

const publicUser = (row) => {
  if (!row) return null;

  const milestone = milestoneFor(row.hands_played);
  const nextBonusAt = row.next_bonus_at ?? 0;

  return {
    id: row.id,
    provider: row.provider,
    displayName: row.display_name,
    email: row.email,
    // A picture chosen in-game wins over the one the provider gave us.
    avatarUrl: row.avatar_choice || row.avatar_url,
    providerAvatarUrl: row.avatar_url,
    avatarChoice: row.avatar_choice ?? null,
    chips: row.chips,
    handsPlayed: row.hands_played,
    handsWon: row.hands_won,
    handsLost: row.hands_lost ?? 0,
    handsLeftMid: row.hands_left_mid ?? 0,
    totalWinnings: row.total_winnings ?? 0,
    biggestPot: row.biggest_pot,
    rewards: {
      /** Chips waiting to be collected for reaching a played-hands milestone. */
      milestoneAvailable: milestone > (row.milestone_claimed ?? 0),
      milestoneAt: milestone,
      milestoneReward: MILESTONE_REWARD,
      milestoneEvery: MILESTONE_EVERY,
      /** Hands still to play before the next milestone. */
      handsToNextMilestone: MILESTONE_EVERY - (row.hands_played % MILESTONE_EVERY),
      /** Epoch ms the timed bonus unlocks; 0 means it is ready now. */
      bonusReadyAt: nextBonusAt,
      bonusAvailable: Date.now() >= nextBonusAt,
      bonusReward: TIMED_BONUS_REWARD,
      bonusIntervalMs: TIMED_BONUS_INTERVAL_MS,
    },
    createdAt: row.created_at,
    lastLoginAt: row.last_login_at,
  };
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

      // "Played" means the player committed chips beyond the boot — posting the
      // ante and folding straight away is not a hand played.
      const played = entry.didChaal ? 1 : 0;
      const left = entry.leftMidHand ? 1 : 0;
      const lost = !entry.isWinner && !entry.leftMidHand ? 1 : 0;

      db.prepare(
        `UPDATE users
            SET chips          = ?,
                hands_played   = hands_played + ?,
                hands_won      = hands_won + ?,
                hands_lost     = hands_lost + ?,
                hands_left_mid = hands_left_mid + ?,
                total_winnings = total_winnings + ?,
                biggest_pot    = MAX(biggest_pot, ?),
                updated_at     = ?
          WHERE id = ?`,
      ).run(
        balance,
        played,
        entry.isWinner ? 1 : 0,
        lost,
        left,
        entry.isWinner ? hand.pot : 0,
        entry.isWinner ? hand.pot : 0,
        timestamp,
        entry.userId,
      );

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

/**
 * Collects the reward for reaching a multiple of 25 hands played.
 *
 * The milestone already collected is recorded, so the same milestone can never
 * pay out twice however often the endpoint is called.
 */
export function claimMilestoneReward(userId) {
  const db = getDatabase();

  const run = db.transaction(() => {
    const row = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    if (!row) throw new Error(`unknown user ${userId}`);

    const milestone = milestoneFor(row.hands_played);
    if (milestone <= (row.milestone_claimed ?? 0)) {
      return { claimed: false, reason: 'not_available', user: publicUser(row) };
    }

    const timestamp = now();
    const balance = row.chips + MILESTONE_REWARD;

    db.prepare('UPDATE users SET chips = ?, milestone_claimed = ?, updated_at = ? WHERE id = ?')
      .run(balance, milestone, timestamp, userId);

    db.prepare(
      `INSERT INTO chip_ledger (user_id, hand_id, delta, balance, reason, created_at)
       VALUES (?, NULL, ?, ?, 'milestone_reward', ?)`,
    ).run(userId, MILESTONE_REWARD, balance, timestamp);

    const updated = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    return { claimed: true, amount: MILESTONE_REWARD, milestone, user: publicUser(updated) };
  });

  return run();
}

/**
 * Collects the timed bonus and restarts its countdown.
 *
 * The next unlock time lives in the database, so the countdown survives a
 * restart and cannot be reset by reinstalling the client.
 */
export function claimTimedBonus(userId) {
  const db = getDatabase();

  const run = db.transaction(() => {
    const row = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    if (!row) throw new Error(`unknown user ${userId}`);

    const timestamp = now();
    if (timestamp < (row.next_bonus_at ?? 0)) {
      return {
        claimed: false,
        reason: 'not_ready',
        readyAt: row.next_bonus_at,
        user: publicUser(row),
      };
    }

    const balance = row.chips + TIMED_BONUS_REWARD;
    const readyAt = timestamp + TIMED_BONUS_INTERVAL_MS;

    db.prepare('UPDATE users SET chips = ?, next_bonus_at = ?, updated_at = ? WHERE id = ?')
      .run(balance, readyAt, timestamp, userId);

    db.prepare(
      `INSERT INTO chip_ledger (user_id, hand_id, delta, balance, reason, created_at)
       VALUES (?, NULL, ?, ?, 'timed_bonus', ?)`,
    ).run(userId, TIMED_BONUS_REWARD, balance, timestamp);

    const updated = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    return { claimed: true, amount: TIMED_BONUS_REWARD, readyAt, user: publicUser(updated) };
  });

  return run();
}

/** Sets the picture a player chose from the bundled profiles folder. */
/**
 * Requirement 29: what a display name may be.
 *
 * Letters, digits and single spaces. No punctuation and no empty string —
 * a name is shown at the table to everyone, so it has to be something that
 * reads as a name rather than as decoration.
 *
 * Matched by Unicode property, so a player may write their name in their own
 * script. Combining marks are letters' companions rather than punctuation:
 * without \p{M} every Devanagari, Bengali, Gujarati and Gurmukhi name carrying
 * a vowel sign would be rejected, which would be most of them. A name still
 * has to *start* with a letter or a digit.
 */
const NAME_PATTERN = /^[\p{L}\p{N}][\p{L}\p{N}\p{M} ]*$/u;

export function normalizeDisplayName(raw, { maxLength = 24 } = {}) {
  const trimmed = `${raw ?? ''}`.trim().replace(/\s+/g, ' ');

  if (!trimmed) {
    throw new Error('empty_name');
  }
  if (trimmed.length > maxLength) {
    throw new Error('name_too_long');
  }
  if (!NAME_PATTERN.test(trimmed)) {
    throw new Error('invalid_name');
  }
  return trimmed;
}

export function setDisplayName(userId, displayName) {
  getDatabase()
    .prepare('UPDATE users SET display_name = ?, updated_at = ? WHERE id = ?')
    .run(displayName, now(), userId);
  return findById(userId);
}

export function setAvatarChoice(userId, avatarChoice) {
  getDatabase()
    .prepare('UPDATE users SET avatar_choice = ?, updated_at = ? WHERE id = ?')
    .run(avatarChoice, now(), userId);
  return findById(userId);
}

export default {
  findById,
  findByProvider,
  upsertFromProfile,
  applyChipDelta,
  settleHand,
  recentHands,
  claimMilestoneReward,
  claimTimedBonus,
  setAvatarChoice,
  setDisplayName,
  normalizeDisplayName,
};
