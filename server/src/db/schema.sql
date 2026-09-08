-- King Teen Patti — PostgreSQL schema.
--
-- Written so it can run on every boot: every statement is IF NOT EXISTS or
-- CREATE OR REPLACE. Timestamps are epoch milliseconds (BIGINT) to match the
-- Date.now() values the server works in everywhere else.

CREATE TABLE IF NOT EXISTS users (
  id                TEXT PRIMARY KEY,
  provider          TEXT NOT NULL CHECK (provider IN ('google', 'facebook', 'guest')),
  -- Provider-scoped identity: Google "sub", Facebook user id, or the hashed device id for guests.
  provider_user_id  TEXT NOT NULL,
  display_name      TEXT NOT NULL,
  email             TEXT,
  avatar_url        TEXT,
  -- The wallet. Every change goes through a transaction that locks this row,
  -- and the CHECK is the last line of defence against an overdraft.
  chips             BIGINT NOT NULL DEFAULT 0 CHECK (chips >= 0),
  -- A hand only counts as "played" once the player has made a voluntary bet;
  -- posting the boot and folding immediately does not count.
  hands_played      INTEGER NOT NULL DEFAULT 0,
  hands_won         INTEGER NOT NULL DEFAULT 0,
  hands_lost        INTEGER NOT NULL DEFAULT 0,
  -- Hands abandoned before they finished, tracked separately from losses.
  hands_left_mid    INTEGER NOT NULL DEFAULT 0,
  -- Gross chips taken in pots won, over the account's lifetime.
  total_winnings    BIGINT NOT NULL DEFAULT 0,
  biggest_pot       BIGINT NOT NULL DEFAULT 0,
  -- Highest "hands played" milestone already collected (a multiple of 25).
  milestone_claimed INTEGER NOT NULL DEFAULT 0,
  -- Epoch ms when the timed bonus may next be collected. 0 = collectable now.
  next_bonus_at     BIGINT NOT NULL DEFAULT 0,
  -- Picture chosen from the bundled profiles folder; overrides avatar_url.
  avatar_choice     TEXT,
  created_at        BIGINT NOT NULL,
  updated_at        BIGINT NOT NULL,
  last_login_at     BIGINT NOT NULL,
  UNIQUE (provider, provider_user_id)
);

CREATE INDEX IF NOT EXISTS idx_users_last_login ON users (last_login_at DESC);

-- One row per completed hand, for auditing and dispute resolution.
CREATE TABLE IF NOT EXISTS hands (
  id           TEXT PRIMARY KEY,
  room_id      TEXT NOT NULL,
  hand_no      INTEGER NOT NULL,
  pot          BIGINT NOT NULL,
  winner_id    TEXT REFERENCES users (id) ON DELETE SET NULL,
  win_reason   TEXT,
  boot_amount  BIGINT NOT NULL,
  started_at   BIGINT NOT NULL,
  ended_at     BIGINT NOT NULL,
  -- Every seat with its cards, contribution and final status.
  summary_json JSONB NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_hands_room ON hands (room_id, hand_no);
CREATE INDEX IF NOT EXISTS idx_hands_ended ON hands (ended_at DESC);

-- The pot, as the database sees it. Opened when the boots are collected,
-- grown by every bet, closed when the hand settles. Its amount and the sum of
-- the hand's ledger rows must agree — that is the reconciliation check.
CREATE TABLE IF NOT EXISTS pots (
  hand_id     TEXT PRIMARY KEY,
  room_id     TEXT NOT NULL,
  boot_amount BIGINT NOT NULL,
  amount      BIGINT NOT NULL DEFAULT 0 CHECK (amount >= 0),
  winner_id   TEXT REFERENCES users (id) ON DELETE SET NULL,
  opened_at   BIGINT NOT NULL,
  closed_at   BIGINT
);

CREATE INDEX IF NOT EXISTS idx_pots_room ON pots (room_id, opened_at DESC);

-- Per-player ledger. Chip movements are only ever written through this table
-- so users.chips can be reconciled against it. Rows are never updated or
-- deleted (see the trigger below).
CREATE TABLE IF NOT EXISTS chip_ledger (
  id         BIGSERIAL PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  hand_id    TEXT,
  -- The client's id for the move that caused this row. UNIQUE, so a retried
  -- request cannot deduct twice: the second insert fails and nothing changes.
  action_id  TEXT UNIQUE,
  -- Negative for bets/antes, positive for pot winnings and grants.
  delta      BIGINT NOT NULL,
  -- users.chips immediately after this row was applied.
  balance    BIGINT NOT NULL,
  reason     TEXT NOT NULL,
  created_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_ledger_user ON chip_ledger (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ledger_hand ON chip_ledger (hand_id);

-- The ledger is append-only. An UPDATE or DELETE is a bug or an intrusion,
-- and either way the database refuses it.
CREATE OR REPLACE FUNCTION chip_ledger_immutable() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'chip_ledger is append-only (attempted %)', TG_OP;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE tgname = 'chip_ledger_no_rewrite'
       AND tgrelid = 'chip_ledger'::regclass
  ) THEN
    CREATE TRIGGER chip_ledger_no_rewrite
      BEFORE UPDATE OR DELETE ON chip_ledger
      FOR EACH ROW EXECUTE FUNCTION chip_ledger_immutable();
  END IF;
END;
$$;

-- The authoritative snapshot of each live table, saved inside the same
-- transaction as every chip movement. `version` only ever goes up; a write
-- carrying an older version than the row already holds is refused, which is
-- how two processes are stopped from both believing they own a table.
CREATE TABLE IF NOT EXISTS game_states (
  room_id    TEXT PRIMARY KEY,
  hand_id    TEXT,
  version    BIGINT NOT NULL,
  state      JSONB NOT NULL,
  updated_at BIGINT NOT NULL
);

-- ---------------------------------------------------------------- workers
--
-- Multi-process routing (see src/cluster/registry.js). Every worker process
-- owns its own tables outright; these rows only say *which* worker holds a
-- player's seat or runs a table, so a connection that nginx handed to the
-- wrong worker can be sent to the right one. Nothing here is money, and every
-- row is disposable: a worker purges its own on start and stop, deletes a
-- lapsed seat's row once the resume offer behind it has expired, and a dead
-- worker's rows are treated as absent once the resume window has passed.

-- One row per live worker, refreshed every 5 s. A heartbeat older than 15 s
-- means the worker is gone and its players may be taken over.
CREATE TABLE IF NOT EXISTS cluster_workers (
  worker_id    INTEGER PRIMARY KEY,
  worker_count INTEGER NOT NULL,
  port         INTEGER NOT NULL,
  pid          INTEGER,
  started_at   BIGINT NOT NULL,
  heartbeat_at BIGINT NOT NULL
);

-- Which worker holds each player's seat (or held seat, or resume offer).
-- room_id is informational and may be NULL. Written by a compare-and-set: a
-- worker only takes a row that is free, its own, or whose owner has stopped
-- heartbeating — so one account is never seated on two live workers.
CREATE TABLE IF NOT EXISTS cluster_players (
  user_id    TEXT PRIMARY KEY,
  worker_id  INTEGER NOT NULL,
  room_id    TEXT,
  updated_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_cluster_players_worker ON cluster_players (worker_id);

-- Which worker runs the table behind each join code, so a code typed on any
-- worker reaches the private table it names.
CREATE TABLE IF NOT EXISTS cluster_rooms (
  code        TEXT PRIMARY KEY,
  room_id     TEXT NOT NULL,
  worker_id   INTEGER NOT NULL,
  is_private  BOOLEAN NOT NULL DEFAULT FALSE,
  category    TEXT NOT NULL,
  boot_amount BIGINT NOT NULL,
  updated_at  BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_cluster_rooms_worker ON cluster_rooms (worker_id);
