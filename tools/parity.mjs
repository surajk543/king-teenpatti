#!/usr/bin/env node
/**
 * Black-box parity harness: starts a game server (Node or the Go port) on a
 * throwaway Postgres schema, runs the parity/ suites against its URL, and
 * tears everything down. The same scenarios, the same assertions, whichever
 * implementation is on the other end — that is what makes the Go port provable.
 *
 *   npm run parity                                    # spawns ../go-server/bin/gameplay
 *   npm run parity -- --bin /path/to/gameplay
 *   npm run parity -- --filter game                     # one suite (substring match, comma list)
 *   npm run parity -- --keep                            # keep the schemas and server logs
 *   npm run parity -- --serve [--profile main]          # start one profile's server and wait
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
  BASE_ENV, DEFAULT_DATABASE_URL, dropSchema, resolveGoBinary, toolsDir, startServer,
} from './parity/lib/launch.mjs';

const parityDir = path.join(toolsDir, 'parity');

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

const target = args.target ?? 'go';
if (target !== 'go') {
  console.error(`--target must be go (got ${target}); the Node server was removed once the port matched it`);
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
 * (parity/lib/launch.mjs); a key set to `undefined` is left unset so the
 * server's default applies. `only` names a suite the profile runs just part
 * of: those of its tests whose names match the pattern (node --test's
 * --test-name-pattern, which leaves the rest out of the report altogether).
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
  // The table catalogue in PostgreSQL (owner, 23 Sep 2026): TABLE_CONFIG_SOURCE=db,
  // so the server plays the four configuration tables V1.0.1__seed.sql fills a
  // fresh schema with — the real default menu. Every table env key it inherits
  // or is given here says something else ON PURPOSE: BOOT_AMOUNT 100 and
  // NEXT_HAND_DELAY_MS 150 from BASE_ENV, 1.2 s clocks and a lifted menu below.
  // A db-mode server ignores all of them, so every exact assertion of the
  // seed's figures here (boot 200, a 25 s turn, a 6 s sideshow, twelve tables)
  // also proves that it did: a key that leaked through would fail one.
  // suiteEnv reports the seed's figures for this profile, not these.
  {
    name: 'menu',
    description: 'the seeded table catalogue from PostgreSQL (TABLE_CONFIG_SOURCE=db; the table env keys ignored)',
    env: {
      TABLE_CONFIG_SOURCE: 'db',
      TURN_TIMEOUT_MS: '1200',
      SIDESHOW_TIMEOUT_MS: '1500',
      CONSOLIDATE_INTERVAL_MS: '600000',
      TABLE_STAKES: '',
      LOBBY_TABLES: '',
    },
    suites: ['stakes', 'rest'],
    only: { rest: 'GET /api/tables' },
  },
  // Variation Teen Patti (Go only). The window's length is read once at start
  // like every other clock, so the one suite runs against two servers: a
  // window that stays open while picks are refused and accepted, and one short
  // enough to watch the server choose MUFLIS. variation.test.js reads
  // PARITY_VARIATION_SELECT_TIMEOUT_MS and skips whichever half is not its.
  {
    name: 'variation',
    description: 'a 60 s variation window and long clocks, so no refusal can be blamed on a timeout',
    env: {
      TURN_TIMEOUT_MS: '60000',
      SIDESHOW_TIMEOUT_MS: '60000',
      VARIATION_SELECT_TIMEOUT_MS: '60000',
      CONSOLIDATE_INTERVAL_MS: '600000',
      TABLE_STAKES: '',
      LOBBY_TABLES: '',
    },
    suites: ['variation'],
  },
  {
    name: 'variation-timeout',
    description: 'an 800 ms variation window, so the server is seen choosing MUFLIS',
    env: {
      TURN_TIMEOUT_MS: '60000',
      SIDESHOW_TIMEOUT_MS: '60000',
      VARIATION_SELECT_TIMEOUT_MS: '800',
      CONSOLIDATE_INTERVAL_MS: '600000',
      TABLE_STAKES: '',
      LOBBY_TABLES: '',
    },
    suites: ['variation'],
  },
  // The Poker family (Go only; owner, 19 Sep 2026 — go-server/POKER_PLAN.md):
  // long clocks so no refusal can be blamed on a timeout, any pair (a poker
  // room needs no menu entry to open, only to be advertised).
  {
    name: 'poker',
    description: '60 s clocks, any stake, the four poker variants',
    env: {
      TURN_TIMEOUT_MS: '60000',
      POKER_TURN_TIMEOUT_MS: '60000',
      SIDESHOW_TIMEOUT_MS: '60000',
      CONSOLIDATE_INTERVAL_MS: '600000',
      TABLE_STAKES: '',
      LOBBY_TABLES: '',
    },
    suites: ['poker'],
  },
];

/** The books audit that closes every profile. */
const MONEY_SUITE = 'money';
// A suite may run in more than one profile (variation does), so the names are de-duplicated.
const ALL_SUITES = [...new Set([...PROFILES.flatMap((p) => p.suites), MONEY_SUITE])];

// --------------------------------------------------------------- helpers

const log = (message) => process.stdout.write(`${message}\n`);
const logDir = path.join(os.tmpdir(), `king-teenpatti-parity-${process.pid}`);
fs.mkdirSync(logDir, { recursive: true });

const suiteWanted = (suite) => !filter || filter.some((f) => suite.includes(f));

/**
 * Where a profile's server takes its tables from. BASE_ENV names env and only
 * the `menu` profile says db; a profile that unset it would still run env,
 * because BASE_ENV sets table keys and the server resolves an unset source to
 * env whenever one is set (config.resolveTableConfigSource).
 */
const tableConfigSource = (env) => (env.TABLE_CONFIG_SOURCE === 'db' ? 'db' : 'env');

/**
 * The table figures a db-sourced server plays by: the table_settings row and
 * the seen 200 / variation rows V1.0.1__seed.sql writes, which are
 * config.Defaults() composed (go-server's TestTheSeededTableCatalogueIsTheDefaults
 * holds the two together). In db mode these, not the env keys, are the truth.
 */
const SEEDED_TABLE_FIGURES = {
  BOOT_AMOUNT: '200',
  TURN_TIMEOUT_MS: '25000',
  NEXT_HAND_DELAY_MS: '4000',
  SIDESHOW_TIMEOUT_MS: '6000',
  VARIATION_SELECT_TIMEOUT_MS: '10000',
};

/** Values the suites read about the server they are talking to (see lib/harness.mjs `profile`). */
const suiteEnv = ({ baseUrl, schema, env }) => {
  const source = tableConfigSource(env);
  // A table figure is the env's in env mode and the seed's in db mode, where
  // the server ignores every table env key (the menu profile sets several).
  const table = (key, fallback) => (source === 'db' ? SEEDED_TABLE_FIGURES[key] : env[key] ?? fallback);
  return {
    ...process.env,
    SERVER_URL: baseUrl,
    PG_SCHEMA: schema,
    DATABASE_URL: databaseUrl,
    PARITY_TARGET: target,
    PARITY_JWT_SECRET: env.JWT_SECRET ?? BASE_ENV.JWT_SECRET,
    PARITY_METRICS_TOKEN: env.METRICS_TOKEN ?? '',
    PARITY_METRICS_ALLOW_IPS: env.METRICS_ALLOW_IPS ?? '',
    PARITY_TABLE_CONFIG_SOURCE: source,
    PARITY_BOOT_AMOUNT: table('BOOT_AMOUNT', '200'),
    PARITY_TURN_TIMEOUT_MS: table('TURN_TIMEOUT_MS', '25000'),
    PARITY_NEXT_HAND_DELAY_MS: table('NEXT_HAND_DELAY_MS', '4000'),
    PARITY_RECONNECT_GRACE_MS: env.RECONNECT_GRACE_MS ?? '60000',
    PARITY_SIDESHOW_TIMEOUT_MS: table('SIDESHOW_TIMEOUT_MS', '6000'),
    PARITY_WELCOME_CHIPS: env.WELCOME_CHIPS ?? '200000',
    PARITY_VARIATION_SELECT_TIMEOUT_MS: table('VARIATION_SELECT_TIMEOUT_MS', '10000'),
  };
};

/** The test-name pattern `profile` runs `suite` under, or null for the whole suite. */
const patternFor = (profile, suite) => profile.only?.[suite] ?? null;

/** Runs one suite file with node --test; resolves with parsed TAP totals. */
const runSuite = (suite, server, pattern = null) => new Promise((resolve) => {
  const file = path.join(parityDir, `${suite}.test.js`);
  const tapFile = path.join(logDir, `${suite}-${Date.now()}.tap`);
  const started = Date.now();
  const child = spawn(process.execPath, [
    '--test',
    `--test-timeout=${testTimeout}`,
    '--test-concurrency=1',
    ...(pattern ? [`--test-name-pattern=${pattern}`] : []),
    '--test-reporter=spec', '--test-reporter-destination=stdout',
    '--test-reporter=tap', `--test-reporter-destination=${tapFile}`,
    file,
  ], { cwd: toolsDir, env: suiteEnv(server), stdio: ['ignore', 'inherit', 'inherit'] });

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
    resolve({ suite, pattern, code, durationMs: Date.now() - started, ...totals });
  });
});

const rowPassed = (row) => row.code === 0 && row.fail === 0 && row.cancelled === 0 && row.tests > 0;

const printSummary = (rows) => {
  log('');
  log('Parity summary');
  log(`target: ${target}${goBinary ? ` (${goBinary})` : ''}`);
  const header = ['profile', 'suite', 'tests', 'pass', 'fail', 'skip', 'time', 'result'];
  const table = rows.map((row) => [
    row.profile, row.pattern ? `${row.suite} (${row.pattern})` : row.suite, String(row.tests), String(row.pass), String(row.fail), String(row.skipped),
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
    const pattern = patternFor(profile, suite);
    const part = pattern ? `, only tests matching "${pattern}"` : '';
    log(`\n=== ${profile.name}/${suite} against ${server.baseUrl} (schema ${server.schema}${part}) ===`);
    const result = await runSuite(suite, server, pattern);
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
    const pattern = patternFor(profile, suite);
    const part = pattern ? `, only tests matching "${pattern}"` : '';
    log(`\n=== attach/${suite} against ${baseUrl} (schema ${schema}, values of profile "${profile.name}"${part}) ===`);
    rows.push({ profile: 'attach', ...(await runSuite(suite, server, pattern)) });
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
