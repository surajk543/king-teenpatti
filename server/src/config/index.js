import 'dotenv/config';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

const num = (value, fallback) => {
  const parsed = Number.parseInt(value ?? '', 10);
  return Number.isFinite(parsed) ? parsed : fallback;
};

const bool = (value, fallback = false) => {
  if (value === undefined || value === '') return fallback;
  return ['1', 'true', 'yes', 'on'].includes(String(value).toLowerCase());
};

const list = (value) =>
  String(value ?? '')
    .split(',')
    .map((entry) => entry.trim())
    .filter(Boolean);

const config = {
  env: process.env.NODE_ENV ?? 'development',
  port: num(process.env.PORT, 3000),
  host: process.env.HOST ?? '0.0.0.0',
  corsOrigin: process.env.CORS_ORIGIN === '*' || !process.env.CORS_ORIGIN ? '*' : list(process.env.CORS_ORIGIN),

  jwt: {
    secret: process.env.JWT_SECRET ?? 'dev-only-insecure-secret',
    expiresIn: process.env.JWT_EXPIRES_IN ?? '30d',
  },

  google: {
    clientIds: list(process.env.GOOGLE_CLIENT_IDS),
  },

  facebook: {
    appId: process.env.FACEBOOK_APP_ID ?? '',
    appSecret: process.env.FACEBOOK_APP_SECRET ?? '',
  },

  allowFakeProviders: bool(process.env.AUTH_ALLOW_FAKE_PROVIDERS, false),

  db: {
    file: path.isAbsolute(process.env.DB_FILE ?? '')
      ? process.env.DB_FILE
      : path.resolve(rootDir, process.env.DB_FILE ?? './data/teenpatti.db'),
  },

  game: {
    welcomeChips: num(process.env.WELCOME_CHIPS, 200000),
    bootAmount: num(process.env.BOOT_AMOUNT, 200),
    /**
     * The stakes the lobby offers. Quick-join is restricted to these, so a
     * client cannot conjure a table at an arbitrary boot. An empty list lifts
     * the restriction, which is what the test suite uses to isolate cases.
     */
    tableStakes: list(process.env.TABLE_STAKES ?? '200,5000')
      .map((entry) => Number.parseInt(entry, 10))
      .filter((entry) => Number.isInteger(entry) && entry > 0),
    maxPlayers: num(process.env.MAX_PLAYERS_PER_ROOM, 5),
    minPlayers: num(process.env.MIN_PLAYERS_TO_START, 2),
    turnTimeoutMs: num(process.env.TURN_TIMEOUT_MS, 25000),
    maxBetRounds: num(process.env.MAX_BET_ROUNDS, 20),
    potLimitMultiplier: num(process.env.POT_LIMIT_MULTIPLIER, 1024),
    /**
     * How many rungs the raise ladder can have. Each "+" doubles the bet, so
     * the ladder is base, 2x, 4x, ... and this bounds how far it can go before
     * the player's own chip stack or the pot limit cuts it short anyway.
     */
    maxRaiseSteps: num(process.env.MAX_RAISE_STEPS, 8),
    /** Countdown shown to clients between a finished hand and the next deal. */
    nextHandDelayMs: num(process.env.NEXT_HAND_DELAY_MS, 6000),
    /** Grace period a disconnected player keeps their seat before being removed. */
    reconnectGraceMs: num(process.env.RECONNECT_GRACE_MS, 30000),
  },

  chat: {
    /** Messages kept per room, in memory only. Oldest are dropped past this. */
    maxHistory: num(process.env.CHAT_MAX_HISTORY, 100),
    /** Longest single message accepted, in characters. */
    maxLength: num(process.env.CHAT_MAX_LENGTH, 140),
    /** Per-player send allowance, to keep one player from flooding a table. */
    rateLimit: num(process.env.CHAT_RATE_LIMIT, 5),
    rateWindowMs: num(process.env.CHAT_RATE_WINDOW_MS, 5000),
  },

  redisUrl: process.env.REDIS_URL ?? '',
  rootDir,
};

if (config.env === 'production') {
  if (config.jwt.secret === 'dev-only-insecure-secret') {
    throw new Error('JWT_SECRET must be set in production');
  }
  if (config.allowFakeProviders) {
    throw new Error('AUTH_ALLOW_FAKE_PROVIDERS must be false in production');
  }
}

export default config;
