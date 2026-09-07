import { query, withTransaction } from './index.js';
import { settle as settleLedger } from './ledger.js';
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

const selectUser = async (client, id) => {
  const { rows } = await client.query('SELECT * FROM users WHERE id = $1', [id]);
  return rows[0] ?? null;
};

export async function findById(id) {
  const { rows } = await query('SELECT * FROM users WHERE id = $1', [id]);
  return publicUser(rows[0]);
}

export async function findByProvider(provider, providerUserId) {
  const { rows } = await query(
    'SELECT * FROM users WHERE provider = $1 AND provider_user_id = $2',
    [provider, providerUserId],
  );
  return publicUser(rows[0]);
}

/**
 * Finds the account behind a verified provider profile, creating it (with the
 * welcome chip grant) the first time we see it. Returns `{ user, isNew }`.
 *
 * The insert and the welcome-grant ledger row go in one transaction so a crash
 * can never leave an account whose balance is not backed by the ledger.
 */
export async function upsertFromProfile(profile) {
  const timestamp = now();

  return withTransaction(async (client) => {
    const { rows } = await client.query(
      'SELECT * FROM users WHERE provider = $1 AND provider_user_id = $2 FOR UPDATE',
      [profile.provider, profile.providerUserId],
    );
    const existing = rows[0];

    if (existing) {
      await client.query(
        `UPDATE users
            SET display_name  = $1,
                email         = COALESCE($2, email),
                avatar_url    = COALESCE($3, avatar_url),
                updated_at    = $4,
                last_login_at = $4
          WHERE id = $5`,
        [
          profile.displayName || existing.display_name,
          profile.email ?? null,
          profile.avatarUrl ?? null,
          timestamp,
          existing.id,
        ],
      );
      return { user: publicUser(await selectUser(client, existing.id)), isNew: false };
    }

    const id = uuid();
    const chips = config.game.welcomeChips;

    await client.query(
      `INSERT INTO users (id, provider, provider_user_id, display_name, email, avatar_url,
                          chips, created_at, updated_at, last_login_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $8, $8)`,
      [
        id,
        profile.provider,
        profile.providerUserId,
        profile.displayName,
        profile.email ?? null,
        profile.avatarUrl ?? null,
        chips,
        timestamp,
      ],
    );

    await client.query(
      `INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at)
       VALUES ($1, NULL, NULL, $2, $2, 'welcome_bonus', $3)`,
      [id, chips, timestamp],
    );

    return { user: publicUser(await selectUser(client, id)), isNew: true };
  });
}

/**
 * Applies a chip delta and appends the matching ledger row atomically, with
 * the wallet row locked for the duration. Throws when the delta would drive
 * the balance negative.
 *
 * Gameplay does not use this — bets go through ledger.js so the pot and the
 * table state travel in the same transaction. It remains for grants, tooling
 * and corrections.
 */
export async function applyChipDelta({ userId, delta, reason, handId = null, actionId = null }) {
  return withTransaction(async (client) => {
    const { rows } = await client.query('SELECT chips FROM users WHERE id = $1 FOR UPDATE', [userId]);
    if (rows.length === 0) throw new Error(`unknown user ${userId}`);

    const balance = rows[0].chips + delta;
    if (balance < 0) throw new Error(`insufficient chips for ${userId}`);

    const timestamp = now();
    await client.query('UPDATE users SET chips = $1, updated_at = $2 WHERE id = $3', [balance, timestamp, userId]);
    await client.query(
      `INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7)`,
      [userId, handId, actionId, delta, balance, reason, timestamp],
    );

    return balance;
  });
}

/**
 * Settles a whole hand: hand record, payouts, counters, pot closing, state.
 * The work lives in ledger.js; this name is kept for callers and tests that
 * know the settlement by it.
 */
export function settleHand(args) {
  return settleLedger(args);
}

export async function recentHands(userId, limit = 20) {
  const { rows } = await query(
    `SELECT DISTINCT ON (h.id) h.*
       FROM hands h
       JOIN chip_ledger l ON l.hand_id = h.id
      WHERE l.user_id = $1
      ORDER BY h.id, h.ended_at DESC`,
    [userId],
  );
  return rows
    .sort((a, b) => b.ended_at - a.ended_at)
    .slice(0, limit)
    .map((row) => ({
      id: row.id,
      roomId: row.room_id,
      handNo: row.hand_no,
      pot: row.pot,
      winnerId: row.winner_id,
      winReason: row.win_reason,
      endedAt: row.ended_at,
      summary: typeof row.summary_json === 'string' ? JSON.parse(row.summary_json) : row.summary_json,
    }));
}

/**
 * Collects the reward for reaching a multiple of 25 hands played.
 *
 * The milestone already collected is recorded, so the same milestone can never
 * pay out twice however often the endpoint is called — the row is locked while
 * that is checked and written.
 */
export async function claimMilestoneReward(userId) {
  return withTransaction(async (client) => {
    const { rows } = await client.query('SELECT * FROM users WHERE id = $1 FOR UPDATE', [userId]);
    const row = rows[0];
    if (!row) throw new Error(`unknown user ${userId}`);

    const milestone = milestoneFor(row.hands_played);
    if (milestone <= (row.milestone_claimed ?? 0)) {
      return { claimed: false, reason: 'not_available', user: publicUser(row) };
    }

    const timestamp = now();
    const balance = row.chips + MILESTONE_REWARD;

    await client.query(
      'UPDATE users SET chips = $1, milestone_claimed = $2, updated_at = $3 WHERE id = $4',
      [balance, milestone, timestamp, userId],
    );
    await client.query(
      `INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at)
       VALUES ($1, NULL, $2, $3, $4, 'milestone_reward', $5)`,
      [userId, `${userId}:milestone:${milestone}`, MILESTONE_REWARD, balance, timestamp],
    );

    return {
      claimed: true,
      amount: MILESTONE_REWARD,
      milestone,
      user: publicUser(await selectUser(client, userId)),
    };
  });
}

/**
 * Collects the timed bonus and restarts its countdown.
 *
 * The next unlock time lives in the database, so the countdown survives a
 * restart and cannot be reset by reinstalling the client.
 */
export async function claimTimedBonus(userId) {
  return withTransaction(async (client) => {
    const { rows } = await client.query('SELECT * FROM users WHERE id = $1 FOR UPDATE', [userId]);
    const row = rows[0];
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

    await client.query(
      'UPDATE users SET chips = $1, next_bonus_at = $2, updated_at = $3 WHERE id = $4',
      [balance, readyAt, timestamp, userId],
    );
    await client.query(
      `INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at)
       VALUES ($1, NULL, NULL, $2, $3, 'timed_bonus', $4)`,
      [userId, TIMED_BONUS_REWARD, balance, timestamp],
    );

    return {
      claimed: true,
      amount: TIMED_BONUS_REWARD,
      readyAt,
      user: publicUser(await selectUser(client, userId)),
    };
  });
}

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

export async function setDisplayName(userId, displayName) {
  await query('UPDATE users SET display_name = $1, updated_at = $2 WHERE id = $3', [displayName, now(), userId]);
  return findById(userId);
}

/** Sets the picture a player chose from the bundled profiles folder. */
export async function setAvatarChoice(userId, avatarChoice) {
  await query('UPDATE users SET avatar_choice = $1, updated_at = $2 WHERE id = $3', [avatarChoice, now(), userId]);
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
