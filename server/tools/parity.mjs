#!/usr/bin/env node
/**
 * Black-box parity harness: starts a game server (Node or the Go port) on a
 * throwaway Postgres schema, runs the test/parity suites against its URL, and
 * tears everything down. The same scenarios, the same assertions, whichever
 * implementation is on the other end — that is what makes the Go port provable.
 *
 *   npm run parity -- --target node
 *   npm run parity -- --target go --bin ../go-server/gameplay
 *   npm run parity -- --target node --filter game        # one suite (substring match, comma list)
 *   npm run parity -- --target go --bin ... --keep       # keep the schemas and server logs
 *   npm run parity -- --target node --serve [--profile main]   # start one profile's server and wait
 *   npm run parity -- --url http://127.0.0.1:3000 --schema public --filter rest   # attach to a running server
 *
 * Config is read once at server start, so suites that need different timeouts
 * run against different server processes ("profiles", below). Each profile
 * gets its own schema and its own server; suites inside a profile run one at a
 * time, then money.test.js audits the books that profile wrote. Exit code 0
 * only when every suite passed.
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  BASE_ENV, DEFAULT_DATABASE_URL, dropSchema, resolveGoBinary, serverDir, startServer,
} from '../test/parity/lib/launch.mjs';

const parityDir = path.join(serverDir, 'test', 'parity');

// ------------------------------------------------------------------ args

const args = {};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i += 1) {
  const key = argv[i];
  if (!key.startsWith('--')) continue;
  const name = key.slice(2);
  const next = argv[i + 1];
  if (next === undefined || next.startsWith('--')) {
    args[name] = true;
  } else {
    args[name] = next;
    i += 1;
  }
}

if (args.help) {
  console.log(fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').slice(1, 20).join('\n'));
  process.exit(0);
}

const target = args.target ?? 'node';
if (!['node', 'go'].includes(target)) {
  console.error(`--target must be node or go (got ${target})`);
  process.exit(2);
}
const databaseUrl = args.db ?? process.env.DATABASE_URL ?? DEFAULT_DATABASE_URL;
const keep = Boolean(args.keep);
const verbose = Boolean(args.verbose);
const filter = typeof args.filter === 'string' ? args.filter.split(',').map((s) => s.trim()).filter(Boolean) : null;
const testTimeout = args['test-timeout'] ?? '90000';

let goBinary = null;
if (target === 'go' && !args.url) {
  try {
    goBinary = resolveGoBinary(args.bin);
  } catch (error) {
    console.error(error.message);
    process.exit(2);
  }
}

// -------------------------------------------------------------- profiles

/**
 * One server process per environment profile. `env` is layered over BASE_ENV
 * (test/parity/lib/launch.mjs); a key set to `undefined` is left unset so the
 * server's default applies.
 */
const PROFILES = [
  {
    name: 'main',
    description: 'short clocks, any stake (integration/socketProtocol conditions)',
    env: {
      TURN_TIMEOUT_MS: '1200',
      SIDESHOW_TIMEOUT_MS: '1500',
      CONSOLIDATE_INTERVAL_MS: '500',
      TABLE_STAKES: '',
      LOBBY_TABLES: '',
    },
    suites: ['rest', 'protocol', 'lobby', 'game', 'resume'],
  },
  {
    name: 'slow',
    description: 'long clocks so refused moves cannot be blamed on a timeout (invalidMoves conditions)',
    env: {
      TURN_TIMEOUT_MS: '60000',
      SIDESHOW_TIMEOUT_MS: '60000',
      CONSOLIDATE_INTERVAL_MS: '600000',
      TABLE_STAKES: '',
      LOBBY_TABLES: '',
    },
    suites: ['invalid'],
  },
  {
    name: 'metrics',
    description: 'metrics.test.js conditions (4 s turn clock, bearer token, loopback allow-list)',
    env: {
      TURN_TIMEOUT_MS: '4000',
      SIDESHOW_TIMEOUT_MS: '6000',
      CONSOLIDATE_INTERVAL_MS: '600000',
      TABLE_STAKES: '',
      LOBBY_TABLES: '',
      // Lets the suite provoke the 403 from a client bound to 127.0.0.2.
      METRICS_ALLOW_IPS: '127.0.0.1',
    },
    suites: ['metrics'],
  },
  {
    name: 'menu',
    description: 'the real default lobby menu (stakes/lobbyRules conditions)',
    env: {
      TURN_TIMEOUT_MS: '60000',
      SIDESHOW_TIMEOUT_MS: '60000',
      CONSOLIDATE_INTERVAL_MS: '600000',
      BOOT_AMOUNT: undefined,
      TABLE_STAKES: undefined,
      LOBBY_TABLES: undefined,
    },
    suites: ['stakes'],
  },
];

/** The books audit that closes every profile. */
const MONEY_SUITE = 'money';
const ALL_SUITES = [...PROFILES.flatMap((p) => p.suites), MONEY_SUITE];

// --------------------------------------------------------------- helpers

const log = (message) => process.stdout.write(`${message}\n`);
const logDir = path.join(os.tmpdir(), `king-teenpatti-parity-${process.pid}`);
fs.mkdirSync(logDir, { recursive: true });

const suiteWanted = (suite) => !filter || filter.some((f) => suite.includes(f));

/** Values the suites read about the server they are talking to (see lib/harness.mjs `profile`). */
const suiteEnv = ({ baseUrl, schema, env }) => ({
  ...process.env,
  SERVER_URL: baseUrl,
  PG_SCHEMA: schema,
  DATABASE_URL: databaseUrl,
  PARITY_TARGET: target,
  PARITY_JWT_SECRET: env.JWT_SECRET ?? BASE_ENV.JWT_SECRET,
  PARITY_METRICS_TOKEN: env.METRICS_TOKEN ?? '',
  PARITY_METRICS_ALLOW_IPS: env.METRICS_ALLOW_IPS ?? '',
  PARITY_BOOT_AMOUNT: env.BOOT_AMOUNT ?? '200',
  PARITY_TURN_TIMEOUT_MS: env.TURN_TIMEOUT_MS ?? '25000',
  PARITY_NEXT_HAND_DELAY_MS: env.NEXT_HAND_DELAY_MS ?? '4000',
  PARITY_RECONNECT_GRACE_MS: env.RECONNECT_GRACE_MS ?? '60000',
  PARITY_SIDESHOW_TIMEOUT_MS: env.SIDESHOW_TIMEOUT_MS ?? '6000',
  PARITY_WELCOME_CHIPS: env.WELCOME_CHIPS ?? '200000',
});

/** Runs one suite file with node --test; resolves with parsed TAP totals. */
const runSuite = (suite, server) => new Promise((resolve) => {
  const file = path.join(parityDir, `${suite}.test.js`);
  const tapFile = path.join(logDir, `${suite}-${Date.now()}.tap`);
  const started = Date.now();
  const child = spawn(process.execPath, [
    '--test',
    `--test-timeout=${testTimeout}`,
    '--test-concurrency=1',
    '--test-reporter=spec', '--test-reporter-destination=stdout',
    '--test-reporter=tap', `--test-reporter-destination=${tapFile}`,
    file,
  ], { cwd: serverDir, env: suiteEnv(server), stdio: ['ignore', 'inherit', 'inherit'] });

  child.on('exit', (code) => {
    const totals = { tests: 0, pass: 0, fail: 0, skipped: 0, todo: 0, cancelled: 0 };
    try {
      const tap = fs.readFileSync(tapFile, 'utf8');
      for (const [, key, value] of tap.matchAll(/^# (tests|pass|fail|skipped|todo|cancelled) (\d+)$/gm)) {
        totals[key] = Number(value);
      }
    } catch {
      // no TAP output at all — the runner crashed before reporting
    }
    resolve({ suite, code, durationMs: Date.now() - started, ...totals });
  });
});

const rowPassed = (row) => row.code === 0 && row.fail === 0 && row.cancelled === 0 && row.tests > 0;

const printSummary = (rows) => {
  log('');
  log('Parity summary');
  log(`target: ${target}${goBinary ? ` (${goBinary})` : ''}`);
  const header = ['profile', 'suite', 'tests', 'pass', 'fail', 'skip', 'time', 'result'];
  const table = rows.map((row) => [
    row.profile, row.suite, String(row.tests), String(row.pass), String(row.fail), String(row.skipped),
    `${(row.durationMs / 1000).toFixed(1)}s`, rowPassed(row) ? 'PASS' : 'FAIL',
  ]);
  const widths = header.map((h, i) => Math.max(h.length, ...table.map((r) => r[i].length)));
  const fmt = (cells) => cells.map((c, i) => c.padEnd(widths[i])).join('  ');
  log(fmt(header));
  log(fmt(widths.map((w) => '-'.repeat(w))));
  for (const row of table) log(fmt(row));
  const totals = rows.reduce((acc, row) => ({
    tests: acc.tests + row.tests, pass: acc.pass + row.pass, fail: acc.fail + row.fail, skipped: acc.skipped + row.skipped,
  }), { tests: 0, pass: 0, fail: 0, skipped: 0 });
  log(fmt(['total', '', String(totals.tests), String(totals.pass), String(totals.fail), String(totals.skipped), '', rows.every(rowPassed) ? 'PASS' : 'FAIL']));
  log(`server logs: ${logDir}`);
};

/** Servers still running, so a stray SIGINT leaves neither a process nor a schema behind. */
const running = new Set();
const launch = async (profile) => {
  const server = await startServer({
    target, bin: goBinary, env: profile.env, databaseUrl, logDir, name: profile.name, verbose,
  });
  running.add(server);
  const stop = server.stop;
  server.stop = async () => { running.delete(server); await stop(); };
  return server;
};
process.on('SIGINT', async () => {
  for (const server of [...running]) {
    await server.stop();
    if (!keep) await dropSchema(server.schema, databaseUrl).catch(() => {});
  }
  process.exit(130);
});

// ------------------------------------------------------------------ modes

const runProfile = async (profile, server, rows) => {
  const suites = profile.suites.filter(suiteWanted);
  if (suites.length === 0 && !suiteWanted(MONEY_SUITE)) return;
  // The books are audited after every profile that played anything (and when asked for directly).
  const order = [...suites, MONEY_SUITE];
  for (const suite of order) {
    log(`\n=== ${profile.name}/${suite} against ${server.baseUrl} (schema ${server.schema}) ===`);
    const result = await runSuite(suite, server);
    rows.push({ profile: profile.name, ...result });
  }
};

const attachMode = async () => {
  const baseUrl = String(args.url).replace(/\/+$/, '');
  const schema = args.schema ?? 'public';
  const profile = PROFILES.find((p) => p.name === (args.profile ?? 'main')) ?? PROFILES[0];
  const server = { baseUrl, schema, env: { ...BASE_ENV, ...profile.env } };
  const suites = filter ? ALL_SUITES.filter(suiteWanted) : [...profile.suites, MONEY_SUITE];
  const rows = [];
  for (const suite of [...new Set(suites)]) {
    log(`\n=== attach/${suite} against ${baseUrl} (schema ${schema}, values of profile "${profile.name}") ===`);
    rows.push({ profile: 'attach', ...(await runSuite(suite, server)) });
  }
  printSummary(rows);
  process.exit(rows.every(rowPassed) ? 0 : 1);
};

const serveMode = async () => {
  const profile = PROFILES.find((p) => p.name === (args.profile ?? 'main'));
  if (!profile) {
    console.error(`unknown profile ${args.profile}; choose one of ${PROFILES.map((p) => p.name).join(', ')}`);
    process.exit(2);
  }
  const server = await launch(profile);
  const env = suiteEnv(server);
  log(`${target} server up for profile "${profile.name}" (${profile.description})`);
  for (const key of Object.keys(env).filter((k) => k === 'SERVER_URL' || k === 'PG_SCHEMA' || k.startsWith('PARITY_'))) {
    log(`  ${key}=${env[key]}`);
  }
  log(`  log: ${server.logFile}`);
  log('Press Ctrl-C to stop (the schema is dropped unless --keep).');
  await new Promise((resolve) => {
    process.once('SIGINT', resolve);
    process.once('SIGTERM', resolve);
  });
  await server.stop();
  if (!keep) await dropSchema(server.schema, databaseUrl);
  else log(`kept schema ${server.schema}`);
  process.exit(0);
};

const runMode = async () => {
  const rows = [];
  const kept = [];
  let fatal = null;
  const wanted = PROFILES.filter((profile) => profile.suites.some(suiteWanted));
  // The books audit on its own runs against the first profile's server.
  if (wanted.length === 0 && suiteWanted(MONEY_SUITE)) wanted.push(PROFILES[0]);
  for (const profile of wanted) {
    log(`\n##### profile "${profile.name}" — ${profile.description}`);
    let server;
    try {
      server = await launch(profile);
    } catch (error) {
      fatal = error;
      log(`failed to start the ${target} server: ${error.message}`);
      break;
    }
    log(`server ${server.baseUrl} schema ${server.schema} (log ${server.logFile})`);
    try {
      await runProfile(profile, server, rows);
    } finally {
      await server.stop();
      if (keep) kept.push(server.schema);
      else await dropSchema(server.schema, databaseUrl).catch((error) => log(`could not drop ${server.schema}: ${error.message}`));
    }
  }
  if (rows.length === 0 && !fatal) {
    log(`no suite matches --filter ${filter?.join(',')}; suites: ${ALL_SUITES.join(', ')}`);
    process.exit(2);
  }
  printSummary(rows);
  if (kept.length > 0) log(`kept schemas: ${kept.join(', ')} (drop with: DROP SCHEMA "<name>" CASCADE)`);
  process.exit(!fatal && rows.every(rowPassed) ? 0 : 1);
};

if (args.serve) await serveMode();
else if (args.url) await attachMode();
else await runMode();
