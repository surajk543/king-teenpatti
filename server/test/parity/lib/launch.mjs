/**
 * Starts a game server — the Node one (`node src/index.js`) or the Go binary —
 * on a free port with a throwaway Postgres schema, waits for /health, and
 * tears it down (SIGTERM, then DROP SCHEMA). Shared by tools/parity.mjs and
 * tools/parity-diff.mjs; nothing in here is test-specific.
 *
 * Both servers read the same environment keys (spec-config-metrics.md); the
 * Go binary additionally reads PUBLIC_DIR for the browser client's files.
 */
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const here = path.dirname(fileURLToPath(import.meta.url));
export const serverDir = path.resolve(here, '..', '..', '..');
export const repoDir = path.resolve(serverDir, '..');

export const DEFAULT_DATABASE_URL = 'postgres://postgres:postgres@localhost:5432/gameplay';

/** Environment every launched server shares — the union of what the Node process suites set. */
export const BASE_ENV = {
  NODE_ENV: 'test',
  HOST: '127.0.0.1',
  JWT_SECRET: 'parity-secret',
  AUTH_ALLOW_FAKE_PROVIDERS: 'true',
  WELCOME_CHIPS: '200000',
  BOOT_AMOUNT: '100',
  NEXT_HAND_DELAY_MS: '150',
  RECONNECT_GRACE_MS: '400',
  METRICS_TOKEN: 'metrics-test-token',
  LOG_LEVEL: 'warn',
  PUBLIC_DIR: path.join(serverDir, 'public'),
};

/** Env keys a profile may leave unset on purpose — scrubbed from the inherited environment. */
export const SCRUBBED = [
  'PORT', 'HOST', 'PG_SCHEMA', 'TABLE_STAKES', 'LOBBY_TABLES', 'BOOT_AMOUNT', 'TURN_TIMEOUT_MS',
  'SIDESHOW_TIMEOUT_MS', 'NEXT_HAND_DELAY_MS', 'RECONNECT_GRACE_MS', 'CONSOLIDATE_INTERVAL_MS',
  'METRICS_TOKEN', 'METRICS_ALLOW_IPS', 'METRICS_ENABLED', 'JWT_SECRET', 'WELCOME_CHIPS',
  'AUTH_ALLOW_FAKE_PROVIDERS', 'RESUME_OFFER_MS', 'REDIS_URL', 'MAX_MISSED_TURNS', 'MAX_BLIND_MOVES',
  'ENTRY_CAP_BOOT', 'ENTRY_CAP_CATEGORY', 'ENTRY_CAP_MAX_CHIPS', 'PRIVATE_BOOT', 'LOG_LEVEL', 'PUBLIC_DIR',
  'DATABASE_URL', 'PG_POOL_MAX', 'JWT_EXPIRES_IN', 'CORS_ORIGIN', 'MAX_PLAYERS_PER_ROOM', 'MIN_PLAYERS_TO_START',
];

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export const freePort = () => new Promise((resolve, reject) => {
  const probe = net.createServer();
  probe.unref();
  probe.on('error', reject);
  probe.listen(0, '127.0.0.1', () => {
    const { port } = probe.address();
    probe.close(() => resolve(port));
  });
});

export const randomSchema = (prefix = 'test_parity') => `${prefix}_${Math.random().toString(36).slice(2, 8)}`;

/**
 * Builds the child environment: the inherited env minus every key a profile
 * controls, then BASE_ENV, then the profile (a value of `undefined` leaves the
 * key unset so the server's default applies), then port/schema/database.
 */
export const buildEnv = (profileEnv, { port, schema, databaseUrl }) => {
  const env = { ...process.env };
  for (const key of SCRUBBED) delete env[key];
  Object.assign(env, BASE_ENV);
  for (const [key, value] of Object.entries(profileEnv ?? {})) {
    if (value === undefined) delete env[key];
    else env[key] = value;
  }
  env.PORT = String(port);
  env.PG_SCHEMA = schema;
  env.DATABASE_URL = databaseUrl;
  return env;
};

export const waitForHealth = async (baseUrl, child, timeoutMs = 30000) => {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`server exited early with code ${child.exitCode}`);
    try {
      const response = await fetch(`${baseUrl}/health`, { signal: AbortSignal.timeout(1000) });
      if (response.ok) {
        const body = await response.json();
        if (body.ok === true) return body;
      }
    } catch {
      // not up yet
    }
    await sleep(100);
  }
  throw new Error(`server at ${baseUrl} did not report healthy within ${timeoutMs} ms`);
};

/** Resolves the Go binary path, or throws with build instructions. */
export const resolveGoBinary = (bin) => {
  const goBinary = path.resolve(bin ?? path.join(repoDir, 'go-server', 'gameplay'));
  if (!fs.existsSync(goBinary)) {
    throw new Error(`Go binary not found at ${goBinary}. Build it first:\n`
      + `  cd ${path.join(repoDir, 'go-server')} && go build -o gameplay ./cmd/gameplay\n`
      + 'or pass --bin <path>.');
  }
  return goBinary;
};

/**
 * Starts one server. Resolves with { baseUrl, port, schema, env, logFile, child, stop }.
 * `stop()` sends SIGTERM (SIGKILL after 10 s) and closes the log; the schema is
 * the caller's to drop (see `dropSchema`).
 */
export const startServer = async ({
  target, bin, env: profileEnv = {}, databaseUrl = DEFAULT_DATABASE_URL, logDir, name = 'server', verbose = false,
}) => {
  if (!['node', 'go'].includes(target)) throw new Error(`target must be node or go (got ${target})`);
  const goBinary = target === 'go' ? resolveGoBinary(bin) : null;
  const port = await freePort();
  const schema = randomSchema();
  const env = buildEnv(profileEnv, { port, schema, databaseUrl });
  fs.mkdirSync(logDir, { recursive: true });
  const logFile = path.join(logDir, `${name}-${target}.log`);
  const out = fs.openSync(logFile, 'a');

  const command = target === 'node' ? process.execPath : goBinary;
  const commandArgs = target === 'node' ? [path.join(serverDir, 'src', 'index.js')] : [];
  const child = spawn(command, commandArgs, {
    cwd: serverDir,
    env,
    stdio: ['ignore', verbose ? 'inherit' : out, verbose ? 'inherit' : out],
  });
  child.on('error', (error) => process.stderr.write(`  server process error: ${error.message}\n`));

  const baseUrl = `http://127.0.0.1:${port}`;
  try {
    await waitForHealth(baseUrl, child);
  } catch (error) {
    fs.closeSync(out);
    const tail = fs.existsSync(logFile) ? fs.readFileSync(logFile, 'utf8').split('\n').slice(-25).join('\n') : '';
    throw new Error(`${error.message}\n--- server log (${logFile}) ---\n${tail}`);
  }

  let stopped = false;
  const stop = async () => {
    if (stopped) return;
    stopped = true;
    if (child.exitCode === null) {
      child.kill('SIGTERM');
      const exited = await Promise.race([
        new Promise((resolve) => child.once('exit', () => resolve(true))),
        sleep(10000).then(() => false),
      ]);
      if (!exited) child.kill('SIGKILL');
    }
    fs.closeSync(out);
  };

  return { target, baseUrl, port, schema, env, logFile, child, stop, goBinary };
};

export const dropSchema = async (schema, databaseUrl = DEFAULT_DATABASE_URL) => {
  if (!schema || schema === 'public') return;
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(schema)) throw new Error(`refusing to drop schema "${schema}"`);
  const client = new pg.Client({ connectionString: databaseUrl });
  await client.connect();
  try {
    await client.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`);
  } finally {
    await client.end();
  }
};
