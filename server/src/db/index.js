import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Database from 'better-sqlite3';
import config from '../config/index.js';
import logger from '../util/logger.js';

const here = path.dirname(fileURLToPath(import.meta.url));

let db = null;

/**
 * Opens (and, on first call, creates + migrates) the SQLite database.
 *
 * SQLite is a single-writer store, so the settings below matter for the
 * 500–1000 concurrent player target: WAL lets readers run while a write is in
 * flight, and `synchronous = NORMAL` avoids an fsync per commit. All gameplay
 * runs from memory — the database is only touched at login, at the end of a
 * hand, and on chip movements.
 */
export function openDatabase(file = config.db.file) {
  if (db) return db;

  if (file !== ':memory:') {
    fs.mkdirSync(path.dirname(file), { recursive: true });
  }

  db = new Database(file);
  db.pragma('journal_mode = WAL');
  db.pragma('synchronous = NORMAL');
  db.pragma('foreign_keys = ON');
  db.pragma('busy_timeout = 5000');

  const schema = fs.readFileSync(path.join(here, 'schema.sql'), 'utf8');
  db.exec(schema);
  migrate(db);

  logger.info('database ready', { file });
  return db;
}

/**
 * Adds columns that were introduced after a database was first created.
 *
 * `CREATE TABLE IF NOT EXISTS` leaves an existing table untouched, so a
 * database made by an earlier build would be missing newer columns. Each ALTER
 * is applied only when the column is genuinely absent, which makes this safe to
 * run on every boot.
 */
function migrate(db) {
  const columns = new Set(db.prepare('PRAGMA table_info(users)').all().map((row) => row.name));

  const additions = [
    ['hands_lost', 'INTEGER NOT NULL DEFAULT 0'],
    ['hands_left_mid', 'INTEGER NOT NULL DEFAULT 0'],
    ['total_winnings', 'INTEGER NOT NULL DEFAULT 0'],
    ['milestone_claimed', 'INTEGER NOT NULL DEFAULT 0'],
    ['next_bonus_at', 'INTEGER NOT NULL DEFAULT 0'],
    ['avatar_choice', 'TEXT'],
  ];

  for (const [name, definition] of additions) {
    if (columns.has(name)) continue;
    db.exec(`ALTER TABLE users ADD COLUMN ${name} ${definition}`);
    logger.info('database migrated', { added: name });
  }
}

export function getDatabase() {
  if (!db) return openDatabase();
  return db;
}

export function closeDatabase() {
  if (!db) return;
  db.close();
  db = null;
}

export default { openDatabase, getDatabase, closeDatabase };
