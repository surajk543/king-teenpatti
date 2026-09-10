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
  -- Epoch ms the account was deleted at the player's request; 0 = live.
  -- The row survives deletion because chip_ledger references it ON DELETE
  -- CASCADE and those rows are a financial record that must not vanish. What
  -- is erased is the identity, in db.Users.DeleteAccount: the name, the
  -- pictures, the email and the provider identity are cleared and the wallet
  -- is emptied through a ledger row, so SUM(delta) = chips = 0 still holds.
  deleted_at        BIGINT NOT NULL DEFAULT 0,
  UNIQUE (provider, provider_user_id)
);

-- Added after the table existed in production, so it needs its own statement:
-- CREATE TABLE IF NOT EXISTS above is a no-op on a database that already has
-- the table and would never add the column.
--
-- Guarded by a catalogue lookup rather than written as a bare
-- `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, because that form still takes an
-- ACCESS EXCLUSIVE lock on users EVERY BOOT even when the column is already
-- there, and an exclusive lock queues behind any reader. On 9 Sep 2026 a
-- long-running report holding ACCESS SHARE on users made this statement wait
-- past PG_STATEMENT_TIMEOUT_MS, so the server failed to start and systemd
-- restarted it into the same wall seven times. A boot that changes nothing
-- must take no lock that a plain SELECT can block.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = current_schema()
       AND table_name   = 'users'
       AND column_name  = 'deleted_at'
  ) THEN
    ALTER TABLE users ADD COLUMN deleted_at BIGINT NOT NULL DEFAULT 0;
  END IF;
END;
$$;

-- Guarded the same way the ALTER above is, and for a sharper reason: CREATE
-- INDEX requires ownership of the table, and IF NOT EXISTS does NOT bypass
-- that check — PostgreSQL resolves and permission-checks the relation before
-- it ever looks to see whether the index is already there. So once `users`
-- was handed to the postgres superuser (§7 of ops/DEPLOY.md, exactly what
-- makes users_no_delete undisableable by the app role) this line began raising
-- 42501 on every boot, and systemd restarted the server into the same wall
-- 1,319 times before anyone looked. A boot that changes nothing must not
-- require a privilege the running server does not need.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
     WHERE schemaname = current_schema()
       AND indexname  = 'idx_users_last_login'
  ) THEN
    CREATE INDEX idx_users_last_login ON users (last_login_at DESC);
  END IF;
END;
$$;

-- A users row is never deleted (owner's decision, 10 Sep 2026). The server
-- has no reason to: DELETE /api/account pseudonymises the row in place
-- (db.Users.DeleteAccount) because chip_ledger references it ON DELETE
-- CASCADE and the money audit must outlive the player. So a DELETE here can
-- only be a mistake or a hand on the wrong console, and it is refused from
-- every caller — the app role, a psql session, a script. Removing a row
-- takes a deliberate privileged step, as the table owner or a superuser:
--
--   ALTER TABLE users DISABLE TRIGGER users_no_delete;
--   DELETE FROM users WHERE id = '…';
--   ALTER TABLE users ENABLE TRIGGER users_no_delete;
--
-- which in production means `sudo -u postgres psql gameplay` on the host.
--
-- Created only when missing, NOT CREATE OR REPLACE, so the function and the
-- table can be handed to the postgres superuser (ops/DEPLOY.md §7: ALTER …
-- OWNER TO postgres; GRANT SELECT, INSERT, UPDATE ON users TO gameplay_app)
-- and this file still boots: once the app role no longer owns either, it can
-- neither delete a row nor disable the trigger nor rewrite the function —
-- only sudo on the host can.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
     WHERE proname = 'users_immutable_rows'
       AND pronamespace = current_schema()::regnamespace
  ) THEN
    CREATE FUNCTION users_immutable_rows() RETURNS trigger AS $fn$
    BEGIN
      RAISE EXCEPTION 'users rows are never deleted (attempted % on %); pseudonymise through DELETE /api/account, or disable trigger users_no_delete as a superuser', TG_OP, OLD.id;
    END;
    $fn$ LANGUAGE plpgsql;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE tgname = 'users_no_delete'
       AND tgrelid = 'users'::regclass
  ) THEN
    CREATE TRIGGER users_no_delete
      BEFORE DELETE ON users
      FOR EACH ROW EXECUTE FUNCTION users_immutable_rows();
  END IF;
END;
$$;

-- Per-player ledger. Chip movements are only ever written through this table
-- so users.chips can be reconciled against it. Rows are never updated or
-- deleted (see the trigger below).
CREATE TABLE IF NOT EXISTS chip_ledger (
  id         BIGSERIAL PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  hand_id    TEXT,
  -- The client's id for the move that caused this row. UNIQUE, so a retried
  -- request cannot deduct twice: the row is already there, and the writer
  -- skips the wallet debit and the pot update with it (db.bankBets).
  action_id  TEXT UNIQUE,
  -- Negative for bets/antes, positive for pot winnings and grants.
  delta      BIGINT NOT NULL,
  -- users.chips immediately after this row was applied.
  balance    BIGINT NOT NULL,
  reason     TEXT NOT NULL,
  created_at BIGINT NOT NULL
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
     WHERE schemaname = current_schema()
       AND indexname  = 'idx_ledger_hand'
  ) THEN
    CREATE INDEX idx_ledger_hand ON chip_ledger (hand_id);
  END IF;
END;
$$;

-- Backs db.PurgeLedger's WHERE (reason IN (...) AND created_at < cutoff).
-- Partial and narrow on purpose, after idx_ledger_user's lesson two sections
-- down: it covers only the four checkpoint reasons the purge job ever
-- touches, so 'purchase' / 'milestone_reward' / 'timed_bonus' /
-- 'welcome_bonus' rows never dirty this index on insert.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
     WHERE schemaname = current_schema()
       AND indexname  = 'idx_ledger_purge'
  ) THEN
    CREATE INDEX idx_ledger_purge ON chip_ledger (created_at)
      WHERE reason IN ('hand_win', 'hand_loss', 'hand_packed', 'hand_left');
  END IF;
END;
$$;

-- The ledger is append-only. An UPDATE or DELETE is a bug or an intrusion,
-- and either way the database refuses it — with ONE deliberate exception: a
-- DELETE inside a transaction that has SET LOCAL app.ledger_purge = 'on' is
-- let through. That GUC is set only by db.PurgeLedger (internal/db/ledger.go)
-- for its own transaction, is session-local (never persists, never leaks to
-- another connection the pool hands out), and PurgeLedger's WHERE clause is
-- hardcoded to reason IN ('hand_win','hand_loss','hand_packed','hand_left')
-- AND created_at older than the configured window — never 'purchase',
-- 'milestone_reward', 'timed_bonus' or 'welcome_bonus', whose UNIQUE
-- action_id is a standing fraud/double-credit guard, not a short-lived retry
-- guard, and must not be purged on this clock. UPDATE stays refused
-- unconditionally, always, from every caller.
CREATE OR REPLACE FUNCTION chip_ledger_immutable() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'DELETE' AND current_setting('app.ledger_purge', true) = 'on' THEN
    RETURN OLD;
  END IF;
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

-- PostgreSQL holds MONEY AND AUDIT ONLY: users (wallets and lifetime
-- counters) and chip_ledger (the append-only money audit). There is no game
-- state here at all — not the table, not the hand, not the pot — and no
-- per-hand record either.
--
-- ALL game state lives in the live store (Redis) and nowhere else (owner's
-- decision of 9 Sep 2026, LIVE_STATE_PLAN.md). If the live store is lost the
-- hand never happened: the players re-join and whatever PostgreSQL holds is
-- their balance.
--
-- Two tables are retired, and dropped below on an existing database ONLY when
-- they exist AND are empty: this file runs on every boot, and an unguarded
-- DROP in that path would be a hazard the day somebody restored an old
-- backup. A table with rows in it is left alone so a human looks at it.
--
--   game_states (room_id, hand_id, version, state, updated_at) — table
--     snapshots; the live store is the only copy now.
--   pots (hand_id, room_id, boot_amount, amount, winner_id, opened_at,
--     closed_at) — per-hand pot accounting. PostgreSQL never holds pot money
--     any more, so nothing can be stranded in one and there is nothing to
--     refund.
--   hands (id, room_id, hand_no, pot, winner_id, …, summary_json) — one row
--     per completed hand. Write-only: the single reader was
--     GET /api/auth/me/hands, which no shipped client calls, and every stat
--     the app shows is a counter column on `users` incremented in the
--     settlement transaction. chip_ledger stays because its UNIQUE action_id
--     IS the settle-retry safety mechanism (a commit whose acknowledgement is
--     lost must not pay the winner twice); `hands` carried no such mechanism.
-- Every reference to a retired table goes through EXECUTE, and that is not a
-- style choice. PL/pgSQL parses and PLANS a statement before it evaluates it,
-- and it treats an IF condition as one expression, so
--
--     IF EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'game_states')
--        AND NOT EXISTS (SELECT 1 FROM game_states)
--
-- fails to parse the moment game_states is gone — SQL's AND promises no
-- short-circuit, and planning happens first either way. Written that way the
-- block drops the table on its first run and then makes every later boot fail
-- with 42P01, which is exactly what it did to production on 9 Sep 2026: the
-- server crash-looped, and because this block aborts schema.sql before the
-- statements after it, pots and hands were never dropped either. Dynamic SQL
-- defers the parse to run time, so the body is only ever parsed when the outer
-- guard has already confirmed the table is there.
DO $$
DECLARE
  retired  text;
  occupied bigint;
BEGIN
  FOREACH retired IN ARRAY ARRAY['game_states', 'pots', 'hands'] LOOP
    IF EXISTS (SELECT 1 FROM pg_tables
                WHERE schemaname = current_schema() AND tablename = retired) THEN
      -- Populated means a human should look at it (a restored backup, say),
      -- so the drop is refused rather than guessed at.
      EXECUTE format('SELECT count(*) FROM (SELECT 1 FROM %I LIMIT 1) probe', retired)
         INTO occupied;
      IF occupied = 0 THEN
        EXECUTE format('DROP TABLE %I', retired);
        RAISE NOTICE 'dropped retired empty table %', retired;
      ELSE
        RAISE NOTICE 'kept retired table % — it still holds rows', retired;
      END IF;
    END IF;
  END LOOP;
END;
$$;

-- idx_ledger_user (chip_ledger (user_id, created_at DESC)) is dropped and must
-- not come back on a hunch. Measured on the dev database: it was the LARGEST
-- index on the table at 6,128 kB — bigger than the unique constraint — and
-- pg_stat_user_indexes.idx_scan recorded THREE scans in the table's entire
-- life, all of them for GET /api/auth/me/hands, which is gone. It indexes a
-- uuid, so every insert dirties a random leaf page; that write pattern is what
-- pushed production past its 128 MB shared_buffers. The reconciliation query
-- (SUM(delta) GROUP BY user_id) is a full scan either way.
DROP INDEX IF EXISTS idx_ledger_user;
