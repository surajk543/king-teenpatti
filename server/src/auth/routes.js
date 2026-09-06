import { Router } from 'express';
import { verifyLogin, AuthError } from './providers.js';
import { issueToken, verifyToken, tokenFromRequest } from './tokens.js';
import { upsertFromProfile, findById, recentHands } from '../db/users.js';
import config from '../config/index.js';
import logger from '../util/logger.js';

export const requireAuth = (req, res, next) => {
  try {
    const claims = verifyToken(tokenFromRequest(req));
    const user = findById(claims.sub);
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
      const { user, isNew } = upsertFromProfile(profile);

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
  router.get('/me/hands', requireAuth, (req, res) => {
    const limit = Math.min(Number.parseInt(req.query.limit ?? '20', 10) || 20, 100);
    res.json({ hands: recentHands(req.user.id, limit) });
  });

  return router;
}

export default authRoutes;
