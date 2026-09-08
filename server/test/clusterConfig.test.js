import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// How a worker picks its listen port (src/config/index.js). The config module
// reads the environment once at import and `dotenv/config` fills in anything
// missing from a `.env` in the working directory, so every case runs in a
// child process of its own, with its own environment and working directory.
//
// The production box is the reason this exists: its `.env` still says
// PORT=3000 from the single-process days, and the systemd unit cannot hide
// that from dotenv (UnsetEnvironment= only clears what systemd passes; dotenv
// then reads the file). A worker's port must therefore not depend on PORT at
// all, or three workers all try to listen on 3000.

const execFileAsync = promisify(execFile);
const serverDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const configModule = path.join(serverDir, 'src', 'config', 'index.js');

/** The port the config module resolves under `env`, run from `cwd`. */
const portUnder = async (env, cwd = serverDir) => {
  const { stdout } = await execFileAsync(
    process.execPath,
    ['--input-type=module', '-e', `import c from ${JSON.stringify(configModule)}; console.log(JSON.stringify({ port: c.port, cluster: c.cluster, envPort: process.env.PORT ?? null }));`],
    {
      cwd,
      // Only what the case sets, plus what Node needs to run at all — the
      // parent's PORT / WORKER_* (a test runner's, say) must not leak in.
      env: { PATH: process.env.PATH, HOME: process.env.HOME, NODE_ENV: 'test', ...env },
    },
  );
  return JSON.parse(stdout.trim());
};

/** A throwaway directory holding a `.env` with the given lines. */
const dirWithEnv = async (lines) => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'ktp-config-'));
  await fs.writeFile(path.join(dir, '.env'), `${lines.join('\n')}\n`);
  return dir;
};

test('single-process mode listens on PORT (default 3000)', async () => {
  assert.equal((await portUnder({})).port, 3000);
  assert.equal((await portUnder({ PORT: '4000' })).port, 4000);
  const { cluster } = await portUnder({});
  assert.deepEqual(cluster, { workerId: 0, workerCount: 1, basePort: 3100 });
});

test('a worker listens on WORKER_BASE_PORT + WORKER_ID and ignores PORT', async () => {
  assert.equal((await portUnder({ WORKER_ID: '2' })).port, 3102);
  assert.equal((await portUnder({ WORKER_ID: '3', WORKER_BASE_PORT: '4000' })).port, 4003);
  // PORT in the environment is the single process's setting, not a worker's.
  const worker = await portUnder({ WORKER_ID: '2', WORKER_COUNT: '3', PORT: '3000' });
  assert.equal(worker.port, 3102);
  assert.deepEqual(worker.cluster, { workerId: 2, workerCount: 3, basePort: 3100 });
});

test('WORKER_PORT is the explicit override for a worker', async () => {
  assert.equal((await portUnder({ WORKER_ID: '1', WORKER_PORT: '5001' })).port, 5001);
  // ...and means nothing to the single process.
  assert.equal((await portUnder({ WORKER_PORT: '5001' })).port, 3000);
});

test('PORT=3000 in a .env next to the worker does not move it off its own port', async () => {
  const cwd = await dirWithEnv(['PORT=3000', 'JWT_SECRET=from-the-file']);
  try {
    // The exact production shape: the unit passes WORKER_ID, the file says PORT.
    const worker = await portUnder({ WORKER_ID: '2', WORKER_COUNT: '3' }, cwd);
    assert.equal(worker.envPort, '3000', 'dotenv did put PORT=3000 into the environment');
    assert.equal(worker.port, 3102, '...and the worker did not care');
    // The file still serves the single process.
    assert.equal((await portUnder({}, cwd)).port, 3000);
  } finally {
    await fs.rm(cwd, { recursive: true, force: true });
  }
});

test('WORKER_ID unset or 0 in a .env keeps single-process mode', async () => {
  // .env.example ships these lines commented out; an active empty WORKER_ID=
  // would be read as 0 — single-process mode — which is exactly why the
  // installer refuses a .env that sets any WORKER_* variable at all.
  const cwd = await dirWithEnv(['WORKER_ID=', 'WORKER_COUNT=1', 'WORKER_BASE_PORT=3100']);
  try {
    const single = await portUnder({}, cwd);
    assert.equal(single.cluster.workerId, 0);
    assert.equal(single.port, 3000);
  } finally {
    await fs.rm(cwd, { recursive: true, force: true });
  }
});
