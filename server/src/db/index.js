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

  logger.info('database ready', { file });
  return db;
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
