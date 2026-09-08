/**
 * Direct access to the schema the server under test is writing to.
 *
 * The Node suites read `users` and `chip_ledger` through the server's own pool
 * to check the books; the parity suites do the same through a pool of their
 * own, pointed at PG_SCHEMA by the same `search_path` connection option the
 * server uses (db/index.js). BIGINT/NUMERIC come back as JS numbers, as they
 * do in the server, so every comparison below is numeric.
 */
import pg from 'pg';

pg.types.setTypeParser(20, (value) => Number(value));
pg.types.setTypeParser(1700, (value) => Number(value));

const url = process.env.DATABASE_URL ?? 'postgres://postgres:postgres@localhost:5432/gameplay';
const schema = process.env.PG_SCHEMA;

if (!schema || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(schema)) {
  throw new Error(`PG_SCHEMA must name the server's schema (got "${schema}")`);
}

let pool = null;

const getPool = () => {
  if (!pool) {
    pool = new pg.Pool({ connectionString: url, max: 4, options: `-c search_path=${schema},public` });
    pool.on('error', () => {});
  }
  return pool;
};

export const query = (text, params = []) => getPool().query(text, params);

export const closeDb = async () => {
  if (pool) await pool.end();
  pool = null;
};

export const ledgerSum = async (userId) => {
  const { rows } = await query('SELECT COALESCE(SUM(delta), 0) AS total FROM chip_ledger WHERE user_id = $1', [userId]);
  return rows[0].total;
};

export const wallet = async (userId) => {
  const { rows } = await query('SELECT chips FROM users WHERE id = $1', [userId]);
  return rows[0]?.chips;
};

/**
 * Sets a wallet to `target` chips the only legitimate way — through a
 * `test_fixture` ledger row — so `SUM(chip_ledger.delta) == users.chips` keeps
 * holding (CLAUDE.md §12.2; the port must never see a bare UPDATE).
 */
export const setWallet = async (userId, target, actionId = null) => {
  const client = await getPool().connect();
  try {
    await client.query('BEGIN');
    const { rows } = await client.query('SELECT chips FROM users WHERE id = $1 FOR UPDATE', [userId]);
    if (rows.length === 0) throw new Error(`unknown user ${userId}`);
    const delta = target - rows[0].chips;
    const at = Date.now();
    await client.query('UPDATE users SET chips = $1, updated_at = $2 WHERE id = $3', [target, at, userId]);
    await client.query(
      `INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at)
       VALUES ($1, NULL, $2, $3, $4, 'test_fixture', $5)`,
      [userId, actionId, delta, target, at],
    );
    await client.query('COMMIT');
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
  return target;
};
