import fs from 'node:fs';
import path from 'node:path';
import { Router } from 'express';
import { verifyLogin, AuthError } from './providers.js';
import { issueToken, verifyToken, tokenFromRequest } from './tokens.js';
import {
  upsertFromProfile,
  findById,
  recentHands,
  claimMilestoneReward,
  claimTimedBonus,
  setAvatarChoice,
  setDisplayName,
  normalizeDisplayName,
} from '../db/users.js';
import config from '../config/index.js';
import logger from '../util/logger.js';

/** Pictures bundled with the game that a player may choose from. */
const PROFILES_DIR = path.join(config.rootDir, 'public', 'profiles');

/** The pictures a player can choose between. */
const listProfilePictures = () => {
  try {
    return fs
      .readdirSync(PROFILES_DIR)
      .filter((name) => /\.(svg|png|jpg|jpeg|webp)$/i.test(name))
      .sort()
      .map((name) => ({ id: name, url: `/profiles/${name}` }));
  } catch {
    return [];
  }
};

export const requireAuth = async (req, res, next) => {
  try {
    const claims = verifyToken(tokenFromRequest(req));
    const user = await findById(claims.sub);
    if (!user) throw new AuthError('unknown_user', 'This account no longer exists');
    req.user = user;
    next();
  } catch (error) {
    next(error);
  }
};

export function authRoutes() {
  const router = Router();

  /**
   * POST /api/auth/login
   *
   * Body: { provider: "google" | "facebook" | "guest", ... }
   *   google   -> { idToken }
   *   facebook -> { accessToken }
   *   guest    -> { deviceId, displayName? }
   *
   * The account is created on first sight with the welcome chip grant, and
   * looked up by provider identity on every later login (requirements 1, 2, 5, 7).
   */
  router.post('/login', async (req, res, next) => {
    try {
      const profile = await verifyLogin(req.body ?? {});
      const { user, isNew } = await upsertFromProfile(profile);

      logger.info(isNew ? 'account created' : 'login', {
        userId: user.id,
        provider: user.provider,
      });

      res.json({
        token: issueToken(user),
        user,
        isNew,
        welcomeChips: isNew ? config.game.welcomeChips : 0,
      });
    } catch (error) {
      next(error);
    }
  });

  /** Returns the caller's persisted profile — chips, stats, everything. */
  router.get('/me', requireAuth, (req, res) => {
    res.json({ user: req.user });
  });

  /** Recent hand history for the caller. */
  router.get('/me/hands', requireAuth, async (req, res, next) => {
    try {
      const limit = Math.min(Number.parseInt(req.query.limit ?? '20', 10) || 20, 100);
      res.json({ hands: await recentHands(req.user.id, limit) });
    } catch (error) {
      next(error);
    }
  });

  return router;
}

/**
 * Rewards and profile pictures.
 *
 * `isSeated` is injected by the server so the avatar endpoint can refuse a
 * change while the player is at a table — their picture is already on screen
 * for everyone else, and swapping it mid-hand would be confusing.
 */
export function playerRoutes({ isSeated = () => false } = {}) {
  const router = Router();

  /**
   * POST /api/rewards/milestone
   * Collects the 25,000 chips owed for reaching a multiple of 25 hands played.
   */
  router.post('/rewards/milestone', requireAuth, async (req, res, next) => {
    try {
      const result = await claimMilestoneReward(req.user.id);
      if (!result.claimed) {
        return res.status(409).json({
          error: 'reward_not_available',
          message: 'No milestone reward is waiting yet.',
          user: result.user,
        });
      }
      logger.info('milestone reward claimed', { userId: req.user.id, milestone: result.milestone });
      return res.json(result);
    } catch (error) {
      return next(error);
    }
  });

  /**
   * POST /api/rewards/bonus
   * Collects the 10,000 chip timed bonus and restarts its 4-hour countdown.
   */
  router.post('/rewards/bonus', requireAuth, async (req, res, next) => {
    try {
      const result = await claimTimedBonus(req.user.id);
      if (!result.claimed) {
        return res.status(409).json({
          error: 'reward_not_ready',
          message: 'The bonus is still recharging.',
          readyAt: result.readyAt,
          user: result.user,
        });
      }
      logger.info('timed bonus claimed', { userId: req.user.id });
      return res.json(result);
    } catch (error) {
      return next(error);
    }
  });

  /** The pictures a player can choose from. */
  router.get('/profiles', (req, res) => {
    res.json({ profiles: listProfilePictures() });
  });

  /**
   * POST /api/profile/avatar  { avatar: "ace.svg" | null }
   *
   * Passing null clears the choice and falls back to the Google/Facebook
   * picture. Refused while the player is seated at a table.
   */
  router.post('/profile/avatar', requireAuth, async (req, res, next) => {
    try {
      if (isSeated(req.user.id)) {
        return res.status(409).json({
          error: 'seated',
          message: 'You cannot change your picture while you are at a table.',
        });
      }

      const requested = req.body?.avatar ?? null;

      if (requested !== null) {
        const allowed = listProfilePictures().some((entry) => entry.id === requested);
        if (!allowed) {
          return res.status(400).json({ error: 'unknown_avatar', message: 'That picture is not available.' });
        }
      }

      const user = await setAvatarChoice(req.user.id, requested ? `/profiles/${requested}` : null);
      return res.json({ user });
    } catch (error) {
      return next(error);
    }
  });

  /**
   * POST /api/profile/name  { name }
   *
   * Requirement 29: the display name is changed from the lobby only. Refused
   * while seated, for the same reason the picture is: everyone at the table is
   * looking at it, and it should not change under them mid-hand.
   */
  router.post('/profile/name', requireAuth, async (req, res, next) => {
    try {
      if (isSeated(req.user.id)) {
        return res.status(409).json({
          error: 'seated',
          message: 'You can only change your name in the lobby.',
        });
      }

      let name;
      try {
        name = normalizeDisplayName(req.body?.name, {
          maxLength: config.game.displayNameMaxLength,
        });
      } catch (error) {
        const messages = {
          empty_name: 'Your name cannot be empty.',
          name_too_long: `Keep it to ${config.game.displayNameMaxLength} characters or fewer.`,
          invalid_name: 'Letters, numbers and spaces only.',
        };
        return res.status(400).json({
          error: error.message,
          message: messages[error.message] ?? 'That name cannot be used.',
        });
      }

      return res.json({ user: await setDisplayName(req.user.id, name) });
    } catch (error) {
      return next(error);
    }
  });

  return router;
}

export default authRoutes;
