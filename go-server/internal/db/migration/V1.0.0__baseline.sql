-- King Teen Patti — PostgreSQL schema, baseline (DDL).
--
-- Every table, column, check, index, function and trigger the server needs, in
-- one file — the ONLY file of structure there is. Since 23 Sep 2026 (owner:
-- "merge all DDL and DML into 2 files") the migration directory holds exactly
-- two scripts: this one, and V1.0.1__seed.sql, which holds every row the
-- server seeds (TestMigrationsAreVersionedOrderedAndSplitByKind pins the pair).
--
-- HOW IT GOT HERE. Consolidated on 14 Sep 2026 (owner) for a production deploy
-- onto an EMPTY database: the structure that used to arrive over four scripts —
-- this baseline, V1.0.3__diamond_purchases.sql, V1.0.5__hammers.sql and, folded
-- in the same day for a second fresh deploy, V1.0.2__missiles.sql — is declared
-- here. The blocks that brought an older database forward then (the guarded
-- hammer ALTER, Butterfly Flapping's move to Drive) went with them; they are in
-- git history (ccff445 and earlier). Later the same day, for a third fresh
-- deploy, the pictures gained a third currency (HAMMER) and
-- V1.0.2__new_account_diamonds.sql (the new-account diamond default of 9) was
-- folded in as well, and after production had run this file so was
-- V1.0.2__timed_bonus_milestone.sql (TIMED_BONUS in user_milestones' CHECK;
-- FOR AN EMPTY DATABASE, below, says what that means for production).
--
-- The two scripts written AFTER production had run the pair —
-- V1.0.2__chip_ledger_game.sql (chip_ledger.game and .variant, the Poker
-- family, 19 Sep 2026) and V1.0.3__users_is_bot.sql (users.is_bot, 22 Sep
-- 2026) — were folded in on 23 Sep 2026, together with the table catalogue
-- (TABLE CONFIGURATION, at the end). Each column is here twice: in its CREATE
-- TABLE, so a fresh database is built with it, and — moved verbatim from its
-- old script — in the catalogue-guarded block right after that CREATE TABLE,
-- which adds it to a database that lacks it. Those two blocks are what a
-- database built by an older tag needs at its next boot (production's, from
-- go-server/v1.1.2, has game and variant but not is_bot), and they are why this
-- file is no longer free of ALTER TABLE.
--
-- Flyway naming: V<version>__<description>.sql, applied in ascending version
-- order. With no schema history table (below) a script's name is recorded
-- nowhere, which is why the seed could be renamed from
-- V1.0.1__seed_profile_pictures.sql without any database noticing.
--
-- EVERY SCRIPT MUST BE IDEMPOTENT, including this one. Flyway would keep a
-- schema history table and skip what it has already run, but this server has
-- no such table: it applies every script on every boot, so running twice must
-- be indistinguishable from running once. In practice that means
-- CREATE TABLE / INDEX IF NOT EXISTS, CREATE OR REPLACE FUNCTION,
-- INSERT … ON CONFLICT DO NOTHING, and a catalogue lookup before anything
-- that has no IF NOT EXISTS of its own (triggers, functions that must not be
-- replaced, columns). Nothing here may fail, and nothing may duplicate, on a
-- second run.
--
-- THE NEXT CHANGE GOES IN THIS FILE, NEVER IN A NEW ONE. The seed runs right
-- after this file, so it runs BEFORE anything numbered after it: a seed row
-- that needed a column a V1.0.2 added would fail on every existing database —
-- and on a fresh one — before V1.0.2 had run. DDL the seed depends on must
-- therefore live here, in V1.0.0, which runs first; and keeping all of it here
-- is what "two files" means. A new TABLE is one CREATE TABLE IF NOT EXISTS. A
-- new COLUMN is written twice, the way is_bot and game/variant are: in its
-- CREATE TABLE for a fresh database, and in a catalogue-guarded DO block right
-- after it for an existing one. Changing what an existing column already IS —
-- a CHECK, a default, a type — is not something a boot can do safely, and stays
-- a deliberate step run by hand (FOR AN EMPTY DATABASE, below).
--
-- CATALOGUE-GUARDED, never `ADD COLUMN IF NOT EXISTS`: that form takes ACCESS
-- EXCLUSIVE on the table even when the column is already there, so every
-- restart would queue behind any reader of it — the crash loop of 9 Sep 2026
-- (TestABootSurvivesALongReaderHoldingTheTables). A lookup in
-- information_schema.columns takes no lock a SELECT can block, and only a
-- database that lacks the column runs the ALTER, once. The ALTER goes through
-- EXECUTE because PL/pgSQL plans a statement before it evaluates the branch
-- guarding it.
--
-- Declared from scratch: every table is written once, in full, with its
-- columns, checks and foreign keys in place. The file describes the shape the
-- database should have, not the steps some older database takes to reach it —
-- with the one exception above: the only ALTER TABLE statements are the EXECUTE
-- strings inside the guarded blocks (TestMigrationsAreVersionedOrderedAndSplitByKind
-- holds that).
--
-- FOR AN EMPTY DATABASE. `CREATE TABLE IF NOT EXISTS` does nothing when the
-- table is already there, so a column, default or CHECK declared here will NOT
-- reach a database that already has the table, unless a guarded block adds it
-- (above). A database built by the scripts of go-server/v1.0.0 or older lacks
-- users.missile (v1.3.0 or older, users.hammer too), and booting this build
-- against it fails the first time a player is read — those columns predate the
-- guarded blocks. A database built by any set of scripts older than the HAMMER
-- currency keeps profile_pictures_currency_check at ('COIN', 'DIAMOND'), and
-- this build's seed refuses to boot on it: PostgreSQL checks a row's CHECKs before
-- ON CONFLICT DO NOTHING looks for the existing row, so the HAMMER rows fail
-- even where their asset_url is already there. A database built by the scripts
-- of go-server/v1.1.0 — production's, deployed fresh on 14 Sep 2026 — has
-- user_milestones_milestone_check without TIMED_BONUS, so every four-hour bonus
-- claim there fails that CHECK and rolls back, paying nothing, until:
--
--   ALTER TABLE user_milestones DROP CONSTRAINT user_milestones_milestone_check;
--   ALTER TABLE user_milestones ADD CONSTRAINT user_milestones_milestone_check
--     CHECK (milestone IN ('HANDS_PLAYED', 'TIMED_BONUS', 'DAILY_BONUS'));
--
-- Bringing such a database to this shape is a deliberate one-off step run by
-- hand, or a fresh start (ops/DEPLOY.md §8), never something a boot does behind
-- your back. The guarded blocks are the one thing a boot does bring forward: a
-- MISSING column, whose default says what every existing row means, and never
-- a change to a column that is already there.
--
-- THIS FILE IS DDL ONLY — tables, constraints, indexes, functions, triggers.
-- Data lives in its own script (V1.0.1__seed.sql: the picture catalogue and
-- the table catalogue). Keeping them apart is what lets the shape of the
-- database be reviewed, diffed and re-applied without arguing about rows, and
-- lets a row be corrected without reopening a structural migration.
--
-- Order matters: `profile_pictures` is created before `users` because
-- `users.active_picture_id` references it, and `user_profile_pictures`,
-- `chip_ledger` and the purchase and spend tables come after both for the same
-- reason. The four table-configuration tables come last, in the order they
-- reference one another — `table_engines`, `table_categories` (each category
-- names its engine), then `table_settings` and `table_configs` (each names a
-- category) — and none of them references users.
--
-- Timestamps are epoch milliseconds (BIGINT) to match the Date.now() values
-- the server works in everywhere else — never TIMESTAMPTZ. One column in a
-- different unit is a trap for whoever writes the next query.
--
-- PostgreSQL holds MONEY, AUDIT, ACCOUNTS AND CONFIGURATION ONLY. There is no
-- game state here at all — not the table being played, not the hand, not the
-- pot, and no per-hand record. ALL game state lives in the live store (Redis)
-- and nowhere else (owner's decision of 9 Sep 2026, LIVE_STATE_PLAN.md). If
-- the live store is lost the hand never happened: the players re-join and
-- whatever PostgreSQL holds is their balance. `game_states`, `pots` and `hands`
-- are retired and are not created here; a database that still carries them is
-- a database somebody restored from an old backup, and dropping them is a
-- human's call. The four table-configuration tables (23 Sep 2026) are not an
-- exception: they say what KIND of table the lobby offers — its engine and
-- category, its boot, its ladder, its clocks — the way profile_pictures says
-- what a picture costs, and are read once at boot. Nothing about any table in
-- play is ever written to them.


-- ---------------------------------------------------------------- pictures

-- The profile-picture catalogue (requirements 20 and 21). One row per picture
-- the game offers: a FREE row is worn by anyone, a PREMIUM row costs chips,
-- diamonds or hammers a player has to spend before they may wear it.
--
-- asset_url is whatever a client can LOAD. That is a hosted URL for the art
-- the game ships with today; a server-relative path into PUBLIC_DIR
-- ("/profiles/bear.svg") works just as well. It is UNIQUE because it is the
-- natural key the seed matches on; the BIGSERIAL id is what
-- users.active_picture_id and user_profile_pictures point at.
--
-- asset_format tells the client HOW to play what asset_url serves, so no
-- client ever has to guess from a file extension (hosted URLs often carry
-- none): IMAGE is a bitmap — jpg, jpeg and png share one loader — SVG is
-- vector art, LOTTIE is a Lottie JSON (or .lottie zip) the client downloads
-- and plays, RIVE is a Rive .riv binary. The value rides the wire next to the
-- URL as assetFormat, so a catalogue row can change loader without a client
-- release.
CREATE TABLE IF NOT EXISTS profile_pictures (
  id         BIGSERIAL PRIMARY KEY,
  name       TEXT    NOT NULL,
  asset_url  TEXT    NOT NULL UNIQUE,
  -- How the client renders what asset_url serves. Defaults to IMAGE so a row
  -- inserted without the column is a picture every client can draw.
  asset_format TEXT   NOT NULL DEFAULT 'IMAGE'
               CHECK (asset_format IN ('IMAGE', 'SVG', 'LOTTIE', 'RIVE')),
  type       TEXT    NOT NULL CHECK (type IN ('FREE', 'PREMIUM')),
  -- What it costs, in the wallet `currency` names. A chip price is paid through
  -- chip_ledger like every other chip movement, so SUM(delta) = users.chips
  -- still reconciles after a purchase. A diamond or hammer price is taken
  -- straight off its column, with the ownership row as its receipt.
  cost       BIGINT  NOT NULL DEFAULT 0 CHECK (cost >= 0),
  -- Which wallet cost is paid from: COIN (chips, the default), DIAMOND
  -- (users.diamond) or HAMMER (users.hammer, owner 14 Sep 2026 — the same
  -- hammers a Force Sideshow spends, but a picture writes no hammer_spends
  -- row). Only a COIN price is chips, so only a COIN picture is refused to a
  -- seated player. Meaningless on a FREE row — nothing is charged — and the
  -- default keeps hand-inserted rows on the chips path.
  currency   TEXT    NOT NULL DEFAULT 'COIN'
             CHECK (currency IN ('COIN', 'DIAMOND', 'HAMMER')),
  -- How long a purchase of this picture lasts: duration_days DAYS plus
  -- duration_hours HOURS. Both 0 means for ever, which is what every free
  -- picture is and what a premium one is until somebody prices it as a rental.
  -- The hours arrived on 14 Sep 2026 (owner), for pictures rented by the hour;
  -- a picture rented for days leaves them at 0.
  --
  -- Days and hours, not the milliseconds every other duration in this server
  -- is measured in, and deliberately: this is a catalogue column an owner edits
  -- by hand, and `duration_days = 30` cannot be misread the way
  -- `duration_ms = 30` silently can. The server converts once, on purchase.
  --
  -- Changing either re-prices the SHELF, never a rental already sold: the
  -- expiry is stamped onto the ownership row at the moment of purchase, so a
  -- player keeps the terms they bought under.
  duration_days  INTEGER NOT NULL DEFAULT 0 CHECK (duration_days >= 0),
  duration_hours INTEGER NOT NULL DEFAULT 0 CHECK (duration_hours >= 0),
  -- FALSE retires a picture: it disappears from the catalogue the clients are
  -- offered, but the rows owning it and the players wearing it are untouched.
  is_active  BOOLEAN NOT NULL DEFAULT TRUE,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at BIGINT  NOT NULL,
  updated_at BIGINT  NOT NULL,
  -- Free means free and premium means it costs something. Without this a
  -- PREMIUM row at cost 0 would be a picture the buy endpoint charges nothing
  -- for and the picker still draws a padlock on.
  CONSTRAINT free_picture_cost_check CHECK (
    (type = 'FREE'    AND cost =  0) OR
    (type = 'PREMIUM' AND cost >  0)
  )
);

-- ------------------------------------------------------------------- users

CREATE TABLE IF NOT EXISTS users (
  id                TEXT PRIMARY KEY,
  provider          TEXT NOT NULL CHECK (provider IN ('google', 'facebook', 'guest')),
  -- Provider-scoped identity: Google "sub", Facebook user id, or the hashed device id for guests.
  provider_user_id  TEXT NOT NULL,
  display_name      TEXT NOT NULL,
  email             TEXT,
  -- The picture GOOGLE OR FACEBOOK gave us. Not the same thing as the picture
  -- the player is wearing: this one is what "use my social picture" falls
  -- back to when they take a catalogue picture off.
  avatar_url        TEXT,
  -- The picture the player IS wearing, or NULL for none. ON DELETE SET NULL so
  -- removing a catalogue row undresses whoever wore it rather than failing.
  active_picture_id BIGINT REFERENCES profile_pictures (id) ON DELETE SET NULL,
  -- The wallet. Every change goes through a transaction that locks this row,
  -- and the CHECK is the last line of defence against an overdraft.
  chips             BIGINT NOT NULL DEFAULT 0 CHECK (chips >= 0),
  -- Premium soft currency. Starts at 9 (owner, 14 Sep 2026; it was 2, and 1
  -- before that), which with the 20 hammers and 1 missile below and the
  -- WELCOME_CHIPS grant is the whole welcome. NOT chip_ledger's business: the
  -- ledger backs the chips invariant (SUM(delta) == chips), and diamonds are
  -- not chips.
  diamond           INTEGER NOT NULL DEFAULT 9 CHECK (diamond >= 0),
  -- The currency a Force Sideshow is paid in, one hammer each (owner, 13 Sep
  -- 2026), and since 14 Sep 2026 what the animated pictures are priced in.
  -- Every account starts with 20, and more are sold on Google Play in packs
  -- (internal/purchase/catalogue.go). Like diamonds, never chip_ledger's
  -- business: hammer_purchases and hammer_spends below are its receipts, and a
  -- picture's is its user_profile_pictures row.
  hammer            INTEGER NOT NULL DEFAULT 20 CHECK (hammer >= 0),
  -- What a missile costs, one each (owner, 14 Sep 2026): every account starts
  -- with 1, and more are traded for diamonds in the missile store's packs (POST
  -- /api/store/missiles). Like diamonds, never chip_ledger's business:
  -- missile_purchases and missile_spends below are its receipts.
  missile           INTEGER NOT NULL DEFAULT 1 CHECK (missile >= 0),
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
  -- The reward milestones a player has collected live in user_milestones
  -- (below), not here (owner, 14 Sep 2026).
  created_at        BIGINT NOT NULL,
  updated_at        BIGINT NOT NULL,
  last_login_at     BIGINT NOT NULL,
  -- Epoch ms the account was deleted at the player's request; 0 = live.
  -- The row survives deletion because chip_ledger references it ON DELETE
  -- CASCADE and those rows are a financial record that must not vanish. What
  -- is erased is the identity: the name, the pictures, the email and the
  -- provider identity are cleared and the wallet is emptied through a ledger
  -- row, so SUM(delta) = chips = 0 still holds.
  deleted_at        BIGINT NOT NULL DEFAULT 0,
  -- TRUE for one of the resident bots of bot-play/ (owner, 22 Sep 2026: "add
  -- one more column is_bot that will tell whether that account is bot or not
  -- … by default keep this flag value false"), so a query about real players
  -- can leave the fleet out — its display names are deliberately
  -- indistinguishable from a person's. The server sets it at login from the
  -- guest device id's namespace (config.BotDevicePrefix, `botplay-…`) and only
  -- ever raises it. A LABEL, not a permission: nothing in the game reads it and
  -- it never reaches a client, since a seat that announced itself as a bot
  -- would tell a player exactly what the fleet exists not to tell them. The
  -- value derives from a client-supplied device id, which anything that starts
  -- reading it has to answer for. Last, where the guarded block below puts it
  -- on an older database, so the column order is the same either way. No
  -- index: nothing at run time queries by it.
  is_bot            BOOLEAN NOT NULL DEFAULT FALSE,
  UNIQUE (provider, provider_user_id)
);

-- users.is_bot for a database built before it (V1.0.3__users_is_bot.sql until
-- 23 Sep 2026; production's go-server/v1.1.2 lacks it). Catalogue-guarded
-- (the header): only a database missing the column runs the ALTER, once, and
-- cheaply — since PostgreSQL 11 a NOT NULL column with a constant DEFAULT is
-- stored in the catalogue, not written into every existing row. FALSE, so every
-- account that already exists is a person unless a later login says otherwise.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = current_schema() AND table_name = 'users' AND column_name = 'is_bot'
  ) THEN
    EXECUTE 'ALTER TABLE users ADD COLUMN is_bot BOOLEAN NOT NULL DEFAULT FALSE';
  END IF;
END;
$$;

-- Behind a catalogue lookup, not a bare IF NOT EXISTS. PostgreSQL checks that
-- the caller OWNS the table before it looks for the index, so once users is
-- handed to the postgres superuser (ops/DEPLOY.md §7) the bare statement
-- fails on every boot as gameplay_app — "must be owner of table users" — even
-- though the index is already there and the statement would do nothing. The
-- lookup skips it wherever the index exists on this schema's users, and a
-- fresh database runs the statement. Tested as a non-superuser role under the
-- §7 arrangement: TestTheAppRoleBootsTwiceBeforeAndAfterUsersIsHandedToTheSuperuser.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
     WHERE i.indrelid = 'users'::regclass
       AND c.relname = 'idx_users_last_login'
  ) THEN
    CREATE INDEX IF NOT EXISTS idx_users_last_login ON users (last_login_at DESC);
  END IF;
END;
$$;

-- A users row is never deleted (owner's decision, 10 Sep 2026). The server has
-- no reason to: DELETE /api/account pseudonymises the row in place, because
-- chip_ledger references it ON DELETE CASCADE and the money audit must outlive
-- the player. So a DELETE here can only be a mistake or a hand on the wrong
-- console, and it is refused from every caller — the app role, a psql session,
-- a script. Removing a row takes a deliberate privileged step, as the table
-- owner or a superuser:
--
--   ALTER TABLE users DISABLE TRIGGER users_no_delete;
--   DELETE FROM users WHERE id = '…';
--   ALTER TABLE users ENABLE TRIGGER users_no_delete;
--
-- which in production means `sudo -u postgres psql gameplay` on the host.
--
-- Created only when missing, NOT CREATE OR REPLACE, so the function and the
-- table can be handed to the postgres superuser (ops/DEPLOY.md §7: ALTER …
-- OWNER TO postgres; GRANT SELECT, INSERT, UPDATE and REFERENCES ON users TO
-- gameplay_app)
-- and this file still runs: once the app role no longer owns either, it can
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


-- --------------------------------------------------------------- ownership

-- Who owns which premium picture, and until when. A FREE picture needs no row
-- — everyone may wear it — so this table holds only what somebody paid for,
-- one row per player per picture, written in the same transaction as the
-- debit.
--
-- The row is never deleted when it lapses. It is the record of a purchase, it
-- points at the chip_ledger row that paid for it, and money is not tidied away:
-- an expired rental is a row whose expires_at is in the past, and every
-- ownership test says so rather than relying on a sweep having run.
CREATE TABLE IF NOT EXISTS user_profile_pictures (
  user_id            TEXT   NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  profile_picture_id BIGINT NOT NULL REFERENCES profile_pictures (id) ON DELETE CASCADE,
  acquired_at        BIGINT NOT NULL,
  -- Epoch ms the rental runs out; 0 means it never does. Stamped from the
  -- picture's duration_days and duration_hours at the moment of purchase, so re-pricing the shelf
  -- afterwards cannot shorten or extend what somebody already bought.
  expires_at         BIGINT NOT NULL DEFAULT 0,
  -- How many times this player has bought this picture. It is what makes the
  -- ledger's action_id unique per PURCHASE rather than per pair, so a lapsed
  -- rental can be bought again — the id of the first purchase is already
  -- spent, and UNIQUE would refuse the second.
  purchases          INTEGER NOT NULL DEFAULT 1 CHECK (purchases > 0),
  PRIMARY KEY (user_id, profile_picture_id)
);

-- Finds the rentals that have run out, for the sweep at login.
CREATE INDEX IF NOT EXISTS idx_owned_pictures_expiry
  ON user_profile_pictures (expires_at) WHERE expires_at > 0;

-- The reward milestones each player has collected (owner, 14 Sep 2026): one
-- row per player per milestone, inserted the first time it is collected and
-- UPDATED in place every time after — never a row per claim, because
-- chip_ledger already records every payment. They were users.milestone_claimed
-- and users.next_bonus_at until then. No row means nothing collected yet: no
-- hands-played milestone, and both bonuses ready now.
--
-- TIMED_BONUS joined the CHECK later the same day, when the owner brought the
-- four-hour bonus back beside the daily one. It arrived as
-- V1.0.2__timed_bonus_milestone.sql and was folded in here (owner). A table
-- built before that — production's, from go-server/v1.1.0 — keeps the
-- two-value CHECK, since CREATE TABLE IF NOT EXISTS leaves an existing table
-- alone, and refuses every four-hour bonus claim until it is rebuilt or the
-- CHECK is replaced by hand (the header's FOR AN EMPTY DATABASE).
CREATE TABLE IF NOT EXISTS user_milestones (
  user_id         TEXT    NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  -- HANDS_PLAYED: 25,000 chips for every 25 hands played (requirement 17).
  -- TIMED_BONUS: 10,000 chips, once every 4 hours (requirement 18).
  -- DAILY_BONUS: 1,00,000 chips and 1 hammer, once every 24 hours.
  milestone       TEXT    NOT NULL CHECK (milestone IN ('HANDS_PLAYED', 'TIMED_BONUS', 'DAILY_BONUS')),
  -- HANDS_PLAYED: the highest multiple of 25 hands collected. A claim jumps it
  -- straight to the current multiple, so a skipped one is forfeited. 0 on a
  -- bonus row.
  claimed_up_to   INTEGER NOT NULL DEFAULT 0 CHECK (claimed_up_to >= 0),
  -- TIMED_BONUS and DAILY_BONUS: epoch ms it may next be collected. 0 on a
  -- HANDS_PLAYED row.
  next_claim_at   BIGINT  NOT NULL DEFAULT 0,
  -- How many times this milestone has been collected, and when last.
  times_claimed   INTEGER NOT NULL DEFAULT 0 CHECK (times_claimed >= 0),
  last_claimed_at BIGINT  NOT NULL DEFAULT 0,
  created_at      BIGINT  NOT NULL,
  updated_at      BIGINT  NOT NULL,
  PRIMARY KEY (user_id, milestone)
);


-- ------------------------------------------------------------------ money

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
  -- Negative for bets/antes and picture purchases, positive for pot winnings
  -- and grants.
  delta      BIGINT NOT NULL,
  -- users.chips immediately after this row was applied.
  balance    BIGINT NOT NULL,
  reason     TEXT NOT NULL,
  created_at BIGINT NOT NULL,
  -- Which GAME wrote the row (owner, 19 Sep 2026; go-server/POKER_PLAN.md §6):
  -- 'poker' and the poker variant ('three_card_poker', 'five_card_draw',
  -- 'texas_holdem', 'omaha') on a poker room's checkpoint, NULL on every Teen
  -- Patti row and every row that is not a hand's. The poker family settles
  -- through the same three checkpoints and the same rows, so the wallet
  -- invariant and the purge need nothing new; what the audit needed was to tell
  -- the games apart, because a 3-Card Poker hand is played against a house with
  -- no wallet and its rows do not sum to zero per hand
  -- (tools/parity/money.test.js). The brief's round_id is hand_id and its
  -- hand_result is reason. Last, where the guarded block below puts them on an
  -- older database. No index: the audit reads them in a full scan it makes
  -- anyway.
  game       TEXT,
  variant    TEXT
);

-- chip_ledger.game and .variant for a database built before them
-- (V1.0.2__chip_ledger_game.sql until 23 Sep 2026). Catalogue-guarded (the
-- header): a restart must never queue its ALTER behind a reader of the ledger.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = current_schema() AND table_name = 'chip_ledger' AND column_name = 'game'
  ) THEN
    EXECUTE 'ALTER TABLE chip_ledger ADD COLUMN game TEXT';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = current_schema() AND table_name = 'chip_ledger' AND column_name = 'variant'
  ) THEN
    EXECUTE 'ALTER TABLE chip_ledger ADD COLUMN variant TEXT';
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_ledger_hand ON chip_ledger (hand_id);

-- Backs db.PurgeLedger's WHERE (reason IN (...) AND created_at < cutoff).
-- Partial and narrow on purpose: it covers only the four checkpoint reasons
-- the purge job ever touches, so 'purchase' / 'picture_purchase' /
-- 'milestone_reward' / 'timed_bonus' / 'welcome_bonus' rows never dirty this
-- index on insert.
--
-- There is deliberately NO index on (user_id, created_at). Measured on the dev
-- database it was the LARGEST index on the table at 6,128 kB — bigger than the
-- unique constraint — and pg_stat_user_indexes.idx_scan recorded THREE scans in
-- the table's entire life, all for a route that no longer exists. It indexes a
-- uuid, so every insert dirties a random leaf page, and that write pattern is
-- what pushed production past its 128 MB shared_buffers. The reconciliation
-- query (SUM(delta) GROUP BY user_id) is a full scan either way. Do not add it
-- back on a hunch.
CREATE INDEX IF NOT EXISTS idx_ledger_purge ON chip_ledger (created_at)
  WHERE reason IN ('hand_win', 'hand_loss', 'hand_packed', 'hand_left');

-- The ledger is append-only. An UPDATE or DELETE is a bug or an intrusion,
-- and either way the database refuses it — with ONE deliberate exception: a
-- DELETE inside a transaction that has SET LOCAL app.ledger_purge = 'on' is
-- let through. That GUC is set only by db.PurgeLedger (internal/db/ledger.go)
-- for its own transaction, is session-local (never persists, never leaks to
-- another connection the pool hands out), and PurgeLedger's WHERE clause is
-- hardcoded to reason IN ('hand_win','hand_loss','hand_packed','hand_left')
-- AND created_at older than the configured window — never 'purchase',
-- 'picture_purchase', 'milestone_reward', 'timed_bonus' or 'welcome_bonus',
-- whose UNIQUE action_id is a standing fraud/double-credit guard, not a
-- short-lived retry guard, and must not be purged on this clock. UPDATE stays
-- refused unconditionally, always, from every caller.
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


-- --------------------------------------------------------------- diamonds

-- One row per Play diamond pack banked (owner, 13 Sep 2026: packs of 1, 5, 20
-- and 100, internal/purchase/catalogue.go).
--
-- Why a table of its own. A chip pack is credited through chip_ledger, whose
-- UNIQUE action_id ("gplay:<token>") is what stops a replayed receipt paying
-- twice. Diamonds never enter chip_ledger — it backs the
-- `SUM(delta) == users.chips` invariant and nothing else — so they need the
-- same guarantee somewhere else. Here the Play purchase token IS the primary
-- key: db.CreditDiamondPurchase inserts it ON CONFLICT DO NOTHING and adds the
-- diamonds only when the insert took, so a retry, a restore on a new install or
-- the same token sent from another account credits nothing.
--
-- It is also the record of what was bought, for support and for reconciling a
-- Play payout report: who, which product, how many diamonds, when.
CREATE TABLE IF NOT EXISTS diamond_purchases (
  purchase_token TEXT    PRIMARY KEY,
  user_id        TEXT    NOT NULL REFERENCES users (id),
  product_id     TEXT    NOT NULL,
  diamonds       INTEGER NOT NULL CHECK (diamonds > 0),
  created_at     BIGINT  NOT NULL
);

-- A player's purchase history, newest first, for support.
CREATE INDEX IF NOT EXISTS diamond_purchases_user_idx ON diamond_purchases (user_id, created_at);


-- ---------------------------------------------------------------- hammers

-- One row per Play hammer pack banked (packs of 20, 50, 100 and 250), keyed on
-- the purchase token: the replay guard (db.CreditHammerPurchase inserts ON
-- CONFLICT DO NOTHING and adds the hammers only when the insert took) and the
-- record of what was bought. The twin of diamond_purchases, for the same
-- reason — a pack that never enters chip_ledger needs its double-credit guard
-- somewhere else.
CREATE TABLE IF NOT EXISTS hammer_purchases (
  purchase_token TEXT    PRIMARY KEY,
  user_id        TEXT    NOT NULL REFERENCES users (id),
  product_id     TEXT    NOT NULL,
  hammers        INTEGER NOT NULL CHECK (hammers > 0),
  created_at     BIGINT  NOT NULL
);

CREATE INDEX IF NOT EXISTS hammer_purchases_user_idx ON hammer_purchases (user_id, created_at);

-- One row per Force Sideshow paid for. action_id is the spend's idempotency key,
-- "<handId>:force:<userId>:<client actionId>" (game.ForceSideshowSpendID):
-- db.Hammers.SpendHammer inserts it in the same transaction that takes the
-- hammer, so a retry whose first attempt committed finds its row and is charged
-- nothing. hand_id says which hand it was spent in, for support.
--
-- This is not game state — nothing reads it back to play a hand. It is the audit
-- of a currency and the guard against spending it twice.
CREATE TABLE IF NOT EXISTS hammer_spends (
  action_id  TEXT   PRIMARY KEY,
  user_id    TEXT   NOT NULL REFERENCES users (id),
  hand_id    TEXT   NOT NULL,
  created_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS hammer_spends_user_idx ON hammer_spends (user_id, created_at);


-- ---------------------------------------------------------------- missiles

-- One row per diamonds-for-missiles trade (db.Missiles.TradeMissiles). The
-- replay guard and the record in one: request_id is the trade's idempotency
-- key, "<userId>:<client requestId>" (db.MissileTradeID), inserted ON CONFLICT
-- DO NOTHING in the same transaction that takes the diamonds and adds the
-- missiles, so a retried request whose first attempt committed finds its row
-- and is charged nothing. A trade refused for want of diamonds rolls its row
-- back with it, so the same request may be sent again once the player has
-- them.
CREATE TABLE IF NOT EXISTS missile_purchases (
  request_id TEXT    PRIMARY KEY,
  user_id    TEXT    NOT NULL REFERENCES users (id),
  diamonds   INTEGER NOT NULL CHECK (diamonds > 0),
  missiles   INTEGER NOT NULL CHECK (missiles > 0),
  created_at BIGINT  NOT NULL
);

-- A player's trade history, for support.
CREATE INDEX IF NOT EXISTS missile_purchases_user_idx ON missile_purchases (user_id, created_at);

-- One row per missile fired. action_id is the spend's idempotency key,
-- "<handId>:missile:<userId>:<client actionId>" (game.MissileSpendID):
-- db.Missiles.SpendMissile inserts it in the same transaction that takes the
-- missile, so a retry whose first attempt committed finds its row and is
-- charged nothing. hand_id says which hand it was fired in, for support.
--
-- Not game state — nothing reads it back to play a hand. The audit of a
-- currency and the guard against spending it twice, as hammer_spends is.
CREATE TABLE IF NOT EXISTS missile_spends (
  action_id  TEXT   PRIMARY KEY,
  user_id    TEXT   NOT NULL REFERENCES users (id),
  hand_id    TEXT   NOT NULL,
  created_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS missile_spends_user_idx ON missile_spends (user_id, created_at);


-- ---------------------------------------------------- table configuration

-- The table catalogue (owner, 23 Sep 2026: "all table related config store in
-- database"): which tables the lobby offers and every figure each one plays by
-- — until then the env keys BOOT_AMOUNT, TABLE_STAKES, LOBBY_TABLES, SEEN_*,
-- BLIND_*, PRIVATE_*, VARIATION_*, POKER_* and the rest of
-- config.TableEnvKeys, composed at boot. Four tables:
--
--   table_engines     the engines — Teen Patti, Poker ("Teen Patti engines /
--                     Poker engines", the owner, the same day);
--   table_categories  the categories, each under exactly one engine: seen,
--                     blind and variation under Teen Patti, the four poker
--                     categories under Poker;
--   table_settings    the one row of figures that belong to no single table;
--   table_configs     every table the lobby offers and every private template.
--
-- With TABLE_CONFIG_SOURCE=db the server reads them ONCE, at boot
-- (db.TableConfigs.Load, checked by config.TableCatalogue.Validate), and
-- ignores every one of those keys; with TABLE_CONFIG_SOURCE=env it composes
-- them as it always did and these rows are seeded but not read.
--
-- is_active works at every level, and the server reads a table only when its
-- row, its category AND its engine are active: one UPDATE retires one table,
-- turns off a whole category (every Variation table) or a whole engine (all of
-- Poker), and the next restart applies it.
--
-- CONFIGURATION, NOT GAME STATE (the header): a row says what a KIND of table
-- is. A table in play copies every figure into its own config when it is
-- opened, keeps it in its Redis snapshot and never looks here again. So an edit
-- takes effect after the next restart, and only for tables opened after it; a
-- table restored from Redis keeps the rules it was opened with, and one whose
-- rules no longer match its row is drained (the lobby stops matching players
-- into it) rather than changed under the players sitting at it.
--
-- V1.0.1__seed.sql writes the two engines and seven categories wherever their
-- code is missing, and fills an EMPTY catalogue of tables with exactly what the
-- defaults compose (config.Defaults().Game.EffectiveCatalogue(), proved by
-- TestTheSeededTableCatalogueIsTheDefaults), and adds a table appended in a
-- later release to an existing catalogue INACTIVE — its header has the policy. To
-- make a database hold a deployment's own env menu instead,
-- `gameplay -export-table-config` prints the SQL (db.ExportTableConfigSQL).
--
-- FOREIGN KEYS, NOT ENUMERATED CHECKS. A category names its engine, and a
-- table (and the settings' entry cap) names its category, through a foreign
-- key: the set stays OPEN — a future engine or category is a seed row, never a
-- change to a constraint an existing database already has. A CHECK listing the
-- values would freeze the set on every such database, which is exactly the
-- trap profile_pictures_currency_check sprang when HAMMER arrived (FOR AN
-- EMPTY DATABASE, in the header). The foreign keys still refuse a table naming
-- a category nobody has declared. What they cannot say is whether THIS build
-- can play a category — a category is an engine's code as well as a row — so
-- the server checks every row it loads against the engines it has
-- (config.EngineOf) and leaves out, with a logged reason, a row that names one
-- it does not know or files a category under the wrong engine (seen under
-- poker).
--
-- Created and owned by the app role, like every table but users; none of the
-- four references users, so ops/DEPLOY.md §7 changes nothing here. Durations
-- are in milliseconds, like the env keys they replace. No table has an index
-- beyond the keys it declares: each is read whole, once per boot.

-- One row per engine: the code the server knows it by (config.EngineTeenPatti,
-- config.EnginePoker — game.Game's values, and what chip_ledger.game says on a
-- poker row), an admin label, and its place. A client names an engine in its
-- own language and shows `name` only for a code it does not know.
CREATE TABLE IF NOT EXISTS table_engines (
  code       TEXT    PRIMARY KEY,
  name       TEXT    NOT NULL,
  sort_order INTEGER NOT NULL,
  is_active  BOOLEAN NOT NULL DEFAULT TRUE,
  created_at BIGINT  NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  updated_at BIGINT  NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint)
);

-- One row per category, under exactly one engine: the categories are flat — a
-- poker variant is a category of the Poker engine, not a kind of Teen Patti's
-- `variation`. code is what every table_configs row and every client message
-- carries (config.Categories); name is an admin label like the engine's.
-- Retire an engine or a category with is_active = FALSE, as a table: a DELETE
-- is refused while anything names it, and the seed would put a seeded row back.
CREATE TABLE IF NOT EXISTS table_categories (
  code       TEXT    PRIMARY KEY,
  engine     TEXT    NOT NULL REFERENCES table_engines (code),
  name       TEXT    NOT NULL,
  sort_order INTEGER NOT NULL,
  is_active  BOOLEAN NOT NULL DEFAULT TRUE,
  created_at BIGINT  NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  updated_at BIGINT  NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint)
);

-- The one row of figures that belong to no single table: what session:ready
-- advertises, and the entry cap. id is always 1 — the CHECK makes a second row
-- impossible rather than merely unexpected.
--
-- max_players and min_players are here and on no table_configs row because
-- every installed client lays its seats out from the ONE maxPlayers that
-- session:ready advertises; a table with a sixth seat would seat a player the
-- phones cannot draw. The clocks and rounds here are the ADVERTISED figures
-- (each table has its own below). entry_cap_* is requirement 30, which the
-- lobby folds into the matching table's stack band. No DEFAULT on any figure:
-- the seed and the export state every one.
CREATE TABLE IF NOT EXISTS table_settings (
  id                   SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  -- BOOT_AMOUNT: the stake a quick-join that names none is given.
  default_boot_amount  BIGINT   NOT NULL CHECK (default_boot_amount > 0),
  -- TABLE_STAKES verbatim, order and repeats kept; empty = any stake.
  stakes               BIGINT[] NOT NULL,
  max_players          INTEGER  NOT NULL CHECK (max_players BETWEEN 2 AND 5),
  min_players          INTEGER  NOT NULL CHECK (min_players >= 2),
  -- Five seconds is the floor for any clock a person has to answer.
  turn_timeout_ms      INTEGER  NOT NULL CHECK (turn_timeout_ms >= 5000),
  max_bet_rounds       INTEGER  NOT NULL CHECK (max_bet_rounds >= 0),
  sideshow_timeout_ms  INTEGER  NOT NULL CHECK (sideshow_timeout_ms = 0 OR sideshow_timeout_ms >= 1000),
  sideshow_min_players INTEGER  NOT NULL CHECK (sideshow_min_players >= 0),
  entry_cap_boot       BIGINT   NOT NULL CHECK (entry_cap_boot >= 0),
  -- A declared category (FOREIGN KEYS, NOT ENUMERATED CHECKS, above), which
  -- the server also checks it knows (config.IsKnownCategory).
  entry_cap_category   TEXT     NOT NULL REFERENCES table_categories (code),
  -- 0 disables the cap.
  entry_cap_max_chips  BIGINT   NOT NULL CHECK (entry_cap_max_chips >= 0),
  created_at BIGINT NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  updated_at BIGINT NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  CHECK (min_players <= max_players)
);

-- One row per table the server opens: every PUBLIC lobby table — the menu, in
-- sort_order — and one PRIVATE template per category, which room:create opens
-- (a category with no active template folds a private create to seen). Every
-- figure a table plays by is on its own row, fully resolved: no inheritance
-- from another row, no NULL meaning "the default".
--
-- table_key is the identity: 'category:boot' for a public table,
-- 'private:category' for a template — config.PublicTableKey /
-- PrivateTableKey. (category, boot) is what quick-join, a switch,
-- consolidation, the live lobby, resume offers and the metrics all key a public
-- table on, so two rows for one pair would be two answers to one question.
-- GENERATED, so it cannot disagree with the columns it is made of, and UNIQUE
-- in the CREATE TABLE rather than a CREATE INDEX of its own: a boot that
-- changes nothing then takes no SHARE lock a writer could queue behind and
-- makes no ownership check. The seed and the export conflict on it.
--
-- category references table_categories, and through it the engine that plays
-- the table (FOREIGN KEYS, NOT ENUMERATED CHECKS, above): a row naming a
-- category nobody declared is refused here, and one whose category or engine
-- is inactive is not read. The two CHECKs at the foot that name categories are
-- rules about ONE category's figures (a variation window, a poker buy-in), not
-- a list of which categories may exist.
--
-- The rule and timer columns have NO DEFAULT on purpose: an INSERT must state
-- every figure, so a row typed by hand that forgets one fails there and then
-- instead of playing by a number nobody chose. A figure a category does not
-- read (a poker row's ladder, a seen row's buy-in, the variation windows off a
-- variation row) is stored as written and zeroed by the server when it loads.
--
-- is_active = FALSE retires a table: the lobby stops offering it after the next
-- restart, and the row stays as the record of what it was. Never DELETE or
-- re-key a seeded row to retire it — the next boot's seed would put it back
-- (inactive, V1.0.1's header, so harmless, but not what was meant).
CREATE TABLE IF NOT EXISTS table_configs (
  id          BIGSERIAL PRIMARY KEY,
  -- seen | blind | variation | three_card_poker | five_card_draw |
  -- texas_holdem | omaha: a table_categories row (above).
  category    TEXT    NOT NULL REFERENCES table_categories (code),
  -- The stake: the boot at Teen Patti, the big blind at Hold'em and Omaha, the
  -- ante at 3-Card Poker and 5-Card Draw.
  boot_amount BIGINT  NOT NULL CHECK (boot_amount > 0),
  is_private  BOOLEAN NOT NULL DEFAULT FALSE,
  table_key   TEXT GENERATED ALWAYS AS (CASE WHEN is_private THEN 'private:' || category
                                             ELSE category || ':' || boot_amount::text END) STORED UNIQUE,
  -- The stack band (public only; 0 = no limit at that end): max_chips shuts
  -- the table to a player holding MORE, min_chips to one holding LESS.
  min_chips   BIGINT  NOT NULL DEFAULT 0 CHECK (min_chips >= 0),
  max_chips   BIGINT  NOT NULL DEFAULT 0 CHECK (max_chips >= 0),
  -- Teen Patti's ladder. 0 means no limit for each: no pot cap, a ladder to
  -- the stack, no forced showdown, no per-bet ceiling (the blind table's rule).
  max_pot              BIGINT  NOT NULL CHECK (max_pot >= 0),
  max_raise_steps      INTEGER NOT NULL CHECK (max_raise_steps >= 0),
  max_bet_rounds       INTEGER NOT NULL CHECK (max_bet_rounds >= 0),
  pot_limit_multiplier BIGINT  NOT NULL CHECK (pot_limit_multiplier >= 0),
  max_blind_moves      INTEGER NOT NULL CHECK (max_blind_moves >= 0),
  -- The clocks and the kicks.
  turn_timeout_ms         INTEGER NOT NULL CHECK (turn_timeout_ms >= 5000),
  max_missed_turns        INTEGER NOT NULL CHECK (max_missed_turns >= 0),
  sideshow_timeout_ms     INTEGER NOT NULL CHECK (sideshow_timeout_ms = 0 OR sideshow_timeout_ms >= 1000),
  sideshow_min_players    INTEGER NOT NULL CHECK (sideshow_min_players >= 0),
  next_hand_delay_ms      INTEGER NOT NULL CHECK (next_hand_delay_ms >= 0),
  unfunded_grace_ms       INTEGER NOT NULL CHECK (unfunded_grace_ms >= 0),
  missile_reveal_extra_ms INTEGER NOT NULL CHECK (missile_reveal_extra_ms >= 0),
  -- Variation only: the chooser's window and the 5-Card pick.
  variation_select_timeout_ms INTEGER NOT NULL CHECK (variation_select_timeout_ms >= 0),
  five_card_pick_timeout_ms   INTEGER NOT NULL CHECK (five_card_pick_timeout_ms >= 0),
  -- Poker only: the smallest stack that may sit, in chips (not boots), and how
  -- many cards a 5-Card Draw player may exchange.
  min_buy_in   BIGINT  NOT NULL CHECK (min_buy_in >= 0),
  max_discards INTEGER NOT NULL CHECK (max_discards BETWEEN 0 AND 5),
  -- The menu position; the private templates sit after the public tables.
  sort_order INTEGER NOT NULL,
  is_active  BOOLEAN NOT NULL DEFAULT TRUE,
  created_at BIGINT NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  updated_at BIGINT NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  -- A band whose min exceeds its max is a table nobody could join.
  CHECK (max_chips = 0 OR min_chips <= max_chips),
  -- A private table is opened by code, never matched by stack.
  CHECK (NOT is_private OR (min_chips = 0 AND max_chips = 0)),
  -- A window of 0 never lapses on its own, and a chooser who walked away would
  -- hold the table for the whole reconnect grace (CLAUDE.md §7.4).
  CHECK (category <> 'variation' OR (variation_select_timeout_ms > 0 AND five_card_pick_timeout_ms > 0)),
  -- A poker stack must at least cover the stake it sits down to.
  CHECK (category NOT IN ('three_card_poker', 'five_card_draw', 'texas_holdem', 'omaha') OR min_buy_in >= boot_amount)
);
