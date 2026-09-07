import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import config from '../config/index.js';
import logger from '../util/logger.js';

const here = path.dirname(fileURLToPath(import.meta.url));

// PostgreSQL hands BIGINT back as a string, because it may not fit a double.
// Every BIGINT here is chips or an epoch-ms timestamp — both far inside the
// safe-integer range — and the rest of the server does arithmetic on them, so
// they come back as numbers.
pg.types.setTypeParser(20, (value) => Number(value));
// SUM() over a BIGINT column comes back as NUMERIC. Nothing in this schema
// stores a NUMERIC, so the only ones ever read are integer chip totals.
pg.types.setTypeParser(1700, (value) => Number(value));

let pool = null;
let schemaName = 'public';

/** Quotes a schema name so it can be interpolated into DDL. */
const quoteIdent = (name) => `"${String(name).replace(/"/g, '""')}"`;

/**
 * Opens the connection pool and makes sure the schema and tables exist.
 *
 * Idempotent: `schema.sql` is written entirely in terms of IF NOT EXISTS and
 * CREATE OR REPLACE, so it is safe to run on every boot — and on every test
 * suite start, each of which uses a schema of its own.
 */
export async function openDatabase({ url = config.db.url, schema = config.db.schema } = {}) {
  if (pool) return pool;

  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(schema)) {
    throw new Error(`PG_SCHEMA must be a plain identifier, got "${schema}"`);
  }
  schemaName = schema;

  // Every connection the pool opens looks in this schema first, so the SQL in
  // the rest of this directory can name tables without a prefix. Set as a
  // startup parameter rather than a query per connection, so it is in place
  // before the connection is ever handed out.
  const created = new pg.Pool({
    connectionString: url,
    max: config.db.poolMax,
    options: `-c search_path=${schema},public`,
  });
  created.on('error', (error) => logger.error('postgres pool error', { error: error.message }));

  const client = await created.connect();
  try {
    await client.query(`CREATE SCHEMA IF NOT EXISTS ${quoteIdent(schema)}`);
    await client.query(`SET search_path TO ${quoteIdent(schema)}, public`);
    const ddl = fs.readFileSync(path.join(here, 'schema.sql'), 'utf8');
    await client.query(ddl);
  } finally {
    client.release();
  }

  pool = created;
  logger.info('database ready', { url: redact(url), schema });
  return pool;
}

export function getPool() {
  if (!pool) throw new Error('database not open — call openDatabase() first');
  return pool;
}

/** One-shot query on the pool. */
export function query(text, params = []) {
  return getPool().query(text, params);
}

/**
 * Runs `fn(client)` inside BEGIN … COMMIT, rolling back on any throw.
 *
 * Everything that moves chips goes through here, so a bet is either wholly in
 * the database — wallet, pot, ledger, state — or not there at all.
 */
export async function withTransaction(fn) {
  const client = await getPool().connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    try {
      await client.query('ROLLBACK');
    } catch {
      // The connection is probably gone; the pool will discard it.
    }
    throw error;
  } finally {
    client.release();
  }
}

/**
 * Removes the schema and everything in it. Only for test teardown: a suite
 * opens its own schema, runs, then throws the whole thing away.
 */
export async function dropSchema() {
  if (!pool) return;
  if (schemaName === 'public') throw new Error('refusing to drop the public schema');
  await pool.query(`DROP SCHEMA IF EXISTS ${quoteIdent(schemaName)} CASCADE`);
}

export async function closeDatabase() {
  if (!pool) return;
  const closing = pool;
  pool = null;
  await closing.end();
}

/** Strips the password out of a connection string before it reaches a log. */
function redact(url) {
  return String(url).replace(/\/\/([^:]+):[^@]+@/, '//$1:***@');
}

export default { openDatabase, getPool, query, withTransaction, dropSchema, closeDatabase };
