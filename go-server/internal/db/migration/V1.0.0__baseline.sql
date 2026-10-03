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
-- file is no longer free of ALTER TABLE. users.is_active (26 Sep 2026) was
-- written straight in here the same way, a column and its guarded block, and
-- so were xp_sources.mission_type, .target and .scope (28 Sep 2026, the
-- one-time missions), which a database already holding the daily XP lacks.
-- table_configs.winner_tax (26 Sep 2026) is declared in its CREATE TABLE
-- alone, with no guarded block: that build is deployed onto a FRESH database
-- (owner: "treat this as fresh deployment not a migration one").
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
-- EVERY INDEX BEHIND A CATALOGUE LOOKUP TOO (29 Sep 2026), for the same kind
-- of reason: `CREATE INDEX IF NOT EXISTS` takes SHARE on its table BEFORE it
-- looks for the index, and SHARE waits for every open writer and makes every
-- later one wait behind it. ops/deploy.sh runs these scripts (`gameplay
-- -migrate`) while the previous build is still serving, so a bare one froze
-- the ledger's writes for up to lock_timeout at a deploy, and — the baseline
-- reaching user_profile_pictures before chip_ledger, a purchase writing them
-- the other way round — could deadlock a purchase. A to_regclass lookup on
-- this schema takes no lock; only a database that lacks the index builds it
-- (TestABootThatChangesNothingWaitsForNoWriter). A NEW index on a busy table
-- still holds SHARE while it builds, once, on the first deploy that carries it.
-- Like IF NOT EXISTS, the lookup is by NAME only: a changed index definition
-- (its columns, its WHERE, UNIQUE) never reaches a database that has the old
-- one — give the new definition a NEW index name, or drop the old one by hand.
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
-- claim there fails that CHECK and rolls back, paying nothing (moot for every
-- build since the rewards were removed on 30 Sep 2026; it matters again only
-- to a rollback to go-server/v1.12.0 or older), until:
--
--   ALTER TABLE user_milestones DROP CONSTRAINT user_milestones_milestone_check;
--   ALTER TABLE user_milestones ADD CONSTRAINT user_milestones_milestone_check
--     CHECK (milestone IN ('HANDS_PLAYED', 'TIMED_BONUS', 'DAILY_BONUS'));
--
-- A database built before Sign in with Apple (2 Oct 2026; the iOS app) —
-- production's — keeps users_provider_check at ('google', 'facebook',
-- 'guest'), which refuses an Apple account's INSERT. The server notices at
-- boot (db.Users.ProviderAccepted), logs these statements and answers every
-- Apple login 503 provider_unconfigured, until they are run (as the owner of
-- users: postgres where DEPLOY.md §7 is applied, else the app role) and the
-- server is restarted:
--
--   ALTER TABLE users DROP CONSTRAINT users_provider_check;
--   ALTER TABLE users ADD CONSTRAINT users_provider_check
--     CHECK (provider IN ('google', 'facebook', 'guest', 'apple')) NOT VALID;
--   ALTER TABLE users VALIDATE CONSTRAINT users_provider_check;
--
-- (NOT VALID then VALIDATE: the check is added without scanning the table
-- under its exclusive lock, and validated under a lock that lets logins and
-- checkpoints carry on.)
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
-- `users.active_picture_id` references it, and `user_profile_pictures`, the
-- table pictures, the card backs (`cards_background`, then
-- `user_cards_background` and `user_cards_background_choice`, which each name
-- a player and a card back), the emojis (`emojis`, then `user_emojis`, which
-- names a player and an emoji), `chip_ledger` and the purchase and spend tables come
-- after both for the same reason, as do the statistics (player_stats and
-- player_variation_stats, then stats_flushes, after user_milestones), the
-- two friends tables (after the Lucky Draw) and player_reports (after the
-- friends tables; it names two players). The Lucky Draw's three
-- follow the purchase tables — its draws, their slots (which
-- name a draw), and the spins (which name a player, a draw and a slot) — then
-- the player levels, badges and XP (player_levels, badges, then user_badges,
-- which names a player and a badge, xp_sources, xp_settings, player_xp, which
-- names a player, then player_xp_claims and player_xp_missions, which each
-- name a player and a source). The four table-configuration
-- tables come last, in the order they
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
-- play is ever written to them. Nor are the Lucky Draw's (24 Sep 2026): its
-- draws and slots are configuration, and its spins an audit — a spin is one
-- request, over before it answers. Nor are the statistics and the friends
-- tables (26-27 Sep 2026): career counters the stats flusher adds finished
-- hands to (and its receipts), and who asked whom and who is friends with
-- whom — account facts; a hand in play, whether a friend is online or at a
-- table, and the counters not yet flushed live in the live store and nowhere
-- here. Nor the player levels, badges and XP (26–27 Sep 2026): player_levels,
-- badges, xp_sources and xp_settings are configuration, and user_badges,
-- player_xp, player_xp_claims and player_xp_missions account facts — a settle
-- adds to player_xp and moves a player's one-time missions on,
-- and no table reads any of them to play a hand. The active play time the 30-
-- and 60-minute XP is earned by lives in the live store, never here.


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
  -- FALSE takes a picture off the shelves (owner, 1 Oct 2026: "if it is false,
  -- then user will not see these assets in UI or UI store"): GET /api/profiles
  -- leaves it out for everybody but a player who already has it — an
  -- ownership row still running, or the picture they are wearing — and nobody
  -- can buy it. Unlike is_active it takes nothing away: whoever has it keeps
  -- it, wears it and sees it, and a reward (the Lucky Draw, a reward program,
  -- the welcome) can still give it, which is how a picture becomes a prize no
  -- store sells. Last, where the guarded block below puts it on an older
  -- database, so the column order is the same either way.
  is_listed  BOOLEAN NOT NULL DEFAULT TRUE,
  -- Free means free and premium means it costs something. Without this a
  -- PREMIUM row at cost 0 would be a picture the buy endpoint charges nothing
  -- for and the picker still draws a padlock on.
  CONSTRAINT free_picture_cost_check CHECK (
    (type = 'FREE'    AND cost =  0) OR
    (type = 'PREMIUM' AND cost >  0)
  )
);

-- profile_pictures.is_listed for a database built before it (1 Oct 2026:
-- every database until then, production's included). Catalogue-guarded, as
-- users.is_bot is: only a database missing the column runs the ALTER, once,
-- and cheaply — a NOT NULL column with a constant DEFAULT is stored in the
-- catalogue, not written into every row. TRUE, so every picture already on
-- offer stays on the shelves.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = current_schema() AND table_name = 'profile_pictures' AND column_name = 'is_listed'
  ) THEN
    EXECUTE 'ALTER TABLE profile_pictures ADD COLUMN is_listed BOOLEAN NOT NULL DEFAULT TRUE';
  END IF;
END;
$$;

-- ------------------------------------------------------------------- users

CREATE TABLE IF NOT EXISTS users (
  id                TEXT PRIMARY KEY,
  provider          TEXT NOT NULL CHECK (provider IN ('google', 'facebook', 'guest', 'apple')),
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
  -- Premium soft currency. NOT chip_ledger's business: the ledger backs the
  -- chips invariant (SUM(delta) == chips), and diamonds are not chips.
  --
  -- What a NEW account starts with — chips, diamonds, hammers, missiles and
  -- anything else — is the welcome_rewards rows' (owner, 30 Sep 2026; WELCOME
  -- REWARDS, at the end), and the account is inserted with all four wallets
  -- set explicitly from them (0 where no row gives any). The DEFAULTs below
  -- (9 diamonds, 20 hammers, 1 missile: the welcome from 14 Sep 2026 until the
  -- rows took it over, which the seed's rows repeat) no longer decide anything;
  -- they stay because changing a DEFAULT is not something a boot does.
  diamond           INTEGER NOT NULL DEFAULT 9 CHECK (diamond >= 0),
  -- The currency a Force Sideshow is paid in, one hammer each (owner, 13 Sep
  -- 2026), and since 14 Sep 2026 what the animated pictures are priced in.
  -- A new account's first are its welcome (welcome_rewards: 20 in the seed),
  -- and more are sold on Google Play in packs
  -- (internal/purchase/catalogue.go). Like diamonds, never chip_ledger's
  -- business: hammer_purchases and hammer_spends below are its receipts, and a
  -- picture's is its user_profile_pictures row.
  hammer            INTEGER NOT NULL DEFAULT 20 CHECK (hammer >= 0),
  -- What a missile costs, one each (owner, 14 Sep 2026): a new account's first
  -- is its welcome (welcome_rewards: 1 in the seed), and more are traded for
  -- diamonds in the missile store's packs (POST
  -- /api/store/missiles). Like diamonds, never chip_ledger's business:
  -- missile_purchases and missile_spends below are its receipts.
  missile           INTEGER NOT NULL DEFAULT 1 CHECK (missile >= 0),
  -- No gameplay counters: hands played, won, lost and left mid-hand, total
  -- winnings, the biggest pot and the rest live in player_stats (below),
  -- per bucket (Player stats v2, owner 27 Sep 2026).
  -- The reward milestones a player had collected lived in user_milestones
  -- (below), not here (owner, 14 Sep 2026); retired with the rewards, 30 Sep
  -- 2026.
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
  -- guest device id's namespace (config.BotDevicePrefixes, `botplay-…` and the practice and ramp bots') and only
  -- ever raises it. A LABEL, not a permission: nothing in the game reads it and
  -- it never reaches a client, since a seat that announced itself as a bot
  -- would tell a player exactly what the fleet exists not to tell them. The
  -- value derives from a client-supplied device id, which anything that starts
  -- reading it has to answer for. Last, where the guarded block below puts it
  -- on an older database, so the column order is the same either way. No
  -- index: nothing at run time queries by it.
  is_bot            BOOLEAN NOT NULL DEFAULT FALSE,
  -- FALSE disables the account (owner, 26 Sep 2026: "by default keep its value
  -- true and when it is marked false, it means user is disabled … he cannot
  -- join the table also"). Set by hand — `UPDATE users SET is_active = FALSE
  -- WHERE id = …` — and read on every door: a login is refused before the row
  -- is touched, every signed-in request and the socket handshake answer
  -- account_disabled, and so does every way into a seat. A seat already taken
  -- plays on until the player leaves it; the wallet and the ledger are left
  -- alone, so TRUE again restores the account exactly as it was. Never on the
  -- wire: a disabled account never receives a user object. Last, where the
  -- guarded block below puts it on an older database. No index: it is read
  -- with the row, by primary key or provider identity.
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
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

-- users.is_active for a database built before it (26 Sep 2026; production's
-- go-server/v1.4.0 lacks it). Guarded like is_bot above, and as cheap: a NOT
-- NULL column with a constant DEFAULT lives in the catalogue. TRUE, so every
-- account that already exists stays enabled.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = current_schema() AND table_name = 'users' AND column_name = 'is_active'
  ) THEN
    EXECUTE 'ALTER TABLE users ADD COLUMN is_active BOOLEAN NOT NULL DEFAULT TRUE';
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
       AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = current_schema())
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
DO $$
BEGIN
  IF to_regclass(format('%I.%I', current_schema(), 'idx_owned_pictures_expiry')) IS NULL THEN
    CREATE INDEX IF NOT EXISTS idx_owned_pictures_expiry
      ON user_profile_pictures (expires_at) WHERE expires_at > 0;
  END IF;
END;
$$;


-- ---------------------------------------------------------- table pictures

-- The picture a player lays on their table (owner, 15 Sep 2026): the ground
-- of the felt, under the seats, the pot and the cards. It is the profile-
-- picture catalogue again, for the table rather than the face — a FREE row
-- anyone may lay, a PREMIUM row bought with chips, diamonds or hammers and,
-- when priced as a rental, kept for its term — with one difference the table
-- forces: TWO pictures per row. The app draws its table on a pale ground by
-- day and a dark one by night, and writes on it in ink that follows the
-- theme, so one picture cannot serve both: a dark cloth under dark day ink
-- loses every word on the table. day_asset_url is drawn in the light theme
-- and night_asset_url in the dark one, and the client switches between them
-- with the theme. Which picture a TABLE shows is the server's pick among
-- everyone seated (game/tablepicture.go), the same for every player at it.
--
-- They arrived as V1.0.2__table_pictures.sql (DDL) and
-- V1.0.3__seed_table_pictures.sql (DML) on the table-pictures branch, written
-- when production had run the baseline and a script that had run somewhere
-- was never edited; folded in here on 23 Sep 2026 under the two-file rule
-- above, as a new TABLE is — three CREATE TABLE IF NOT EXISTS and one index,
-- nothing on users. Which is why the picture a player has laid is a row in
-- user_table_choice rather than a users column like active_picture_id: a
-- column would be an ALTER TABLE users, which under ops/DEPLOY.md §7 needs a
-- one-off run as postgres; a table with a foreign key to users needs only
-- REFERENCES, which §7 grants. Order matters as it does everywhere in this
-- file: table_pictures first, because the two after it reference it.

-- One row per table picture on offer. The columns are profile_pictures' —
-- above, for what each means — with asset_url split in two.
--
-- day_asset_url is UNIQUE because it is the natural key the seed matches on
-- (V1.0.1__seed.sql, THE TABLE PICTURES, ON CONFLICT DO NOTHING).
-- night_asset_url is not: two rows may share a night picture, and a row may
-- serve the same picture by day and by night when its art reads on either
-- ground. Both are whatever a client can LOAD — a server-relative path into
-- PUBLIC_DIR ("/tables/classic-baize-day.svg"), which production serves from
-- its public directory as it serves /profiles/ (CLAUDE.md §9), or a hosted
-- URL, which is what the seed's rows carry. One asset_format for both: a pair
-- is drawn by one loader.
CREATE TABLE IF NOT EXISTS table_pictures (
  id              BIGSERIAL PRIMARY KEY,
  name            TEXT    NOT NULL,
  day_asset_url   TEXT    NOT NULL UNIQUE,
  night_asset_url TEXT    NOT NULL,
  asset_format    TEXT    NOT NULL DEFAULT 'IMAGE'
                  CHECK (asset_format IN ('IMAGE', 'SVG', 'LOTTIE', 'RIVE')),
  type            TEXT    NOT NULL CHECK (type IN ('FREE', 'PREMIUM')),
  cost            BIGINT  NOT NULL DEFAULT 0 CHECK (cost >= 0),
  -- COIN is chips, through chip_ledger; DIAMOND and HAMMER debit their users
  -- column directly, as a profile picture's do. Only a COIN row is refused to
  -- a seated player (CLAUDE.md §5.1).
  currency        TEXT    NOT NULL DEFAULT 'COIN'
                  CHECK (currency IN ('COIN', 'DIAMOND', 'HAMMER')),
  -- The rental term, duration_days DAYS plus duration_hours HOURS; both 0 is
  -- for ever. Stamped onto the ownership row at purchase, so re-pricing the
  -- shelf never shortens a term already sold.
  duration_days   INTEGER NOT NULL DEFAULT 0 CHECK (duration_days >= 0),
  duration_hours  INTEGER NOT NULL DEFAULT 0 CHECK (duration_hours >= 0),
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  sort_order      INTEGER NOT NULL DEFAULT 0,
  created_at      BIGINT  NOT NULL,
  updated_at      BIGINT  NOT NULL,
  -- FALSE takes the picture off the Tables shelf (owner, 1 Oct 2026) as
  -- profile_pictures.is_listed does a face: listed to nobody but a player who
  -- has it — an ownership row still running, or the picture laid on their
  -- table — and sold to nobody; nothing is taken away, and a reward can still
  -- give it. Last, where the guarded block below puts it on an older database.
  is_listed       BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT free_table_picture_cost_check CHECK (
    (type = 'FREE'    AND cost =  0) OR
    (type = 'PREMIUM' AND cost >  0)
  )
);

-- table_pictures.is_listed for a database built before it (1 Oct 2026),
-- guarded as profile_pictures.is_listed is above. TRUE: every table picture
-- already on offer stays on the shelf.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = current_schema() AND table_name = 'table_pictures' AND column_name = 'is_listed'
  ) THEN
    EXECUTE 'ALTER TABLE table_pictures ADD COLUMN is_listed BOOLEAN NOT NULL DEFAULT TRUE';
  END IF;
END;
$$;

-- Who has bought which premium table picture, and until when: the twin of
-- user_profile_pictures, kept for the same reasons. A FREE row needs no row
-- here, a lapsed rental is a row whose expires_at is in the past and is never
-- deleted, and purchases is what makes a renewal's ledger action_id unique
-- ("table:<user>:<id>:<n>").
CREATE TABLE IF NOT EXISTS user_table_pictures (
  user_id          TEXT   NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  table_picture_id BIGINT NOT NULL REFERENCES table_pictures (id) ON DELETE CASCADE,
  acquired_at      BIGINT NOT NULL,
  expires_at       BIGINT NOT NULL DEFAULT 0,
  purchases        INTEGER NOT NULL DEFAULT 1 CHECK (purchases > 0),
  PRIMARY KEY (user_id, table_picture_id)
);

DO $$
BEGIN
  IF to_regclass(format('%I.%I', current_schema(), 'idx_owned_table_pictures_expiry')) IS NULL THEN
    CREATE INDEX IF NOT EXISTS idx_owned_table_pictures_expiry
      ON user_table_pictures (expires_at) WHERE expires_at > 0;
  END IF;
END;
$$;

-- The table picture each player has laid: one row per player, or none for
-- the table as it comes. This is users.active_picture_id for the table,
-- moved off users for the reason given above. ON DELETE CASCADE on the
-- picture, so removing a catalogue row clears the tables it was laid on
-- rather than failing, as active_picture_id's ON DELETE SET NULL does.
CREATE TABLE IF NOT EXISTS user_table_choice (
  user_id          TEXT   PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
  table_picture_id BIGINT NOT NULL REFERENCES table_pictures (id) ON DELETE CASCADE,
  chosen_at        BIGINT NOT NULL
);

-- -------------------------------------------------------------- card backs

-- The back of a player's cards (owner, 3 Oct 2026: "Add a table
-- cards_background which users can buy just like user can buy
-- profile_pictures … add one more tab Cards in Store which user can buy, in
-- database store its path, just like you are storing for profile_pictures
-- table … keep the price of all cards 5 Hammers validity 10 days"). It is the
-- table-picture catalogue again — a FREE row anyone may choose, a PREMIUM row
-- bought with chips, diamonds or hammers and, priced as a rental, kept for its
-- term; who owns what; and the one each player has chosen, in a side table of
-- its own — with the profile picture's visibility: a seat carries its
-- player's card back (game.CardBackground), and EVERY viewer at a Teen Patti
-- table sees it on that player's face-down cards, the viewer their own on
-- their own hand.
--
-- The default back is NO row: it is the owner's Royal Fox, bundled with the
-- app (flutter-client/assets/card_back.jpg), worn by everybody who has chosen
-- nothing — the table pictures' "Flowing chips". A player choosing nothing
-- has no row in user_cards_background_choice, and their seat carries none.
--
-- Three CREATE TABLE IF NOT EXISTS and one index, nothing on users, for the
-- reason the table pictures give above: a database built before them takes
-- them at its next boot, and under ops/DEPLOY.md §7 the two that name a
-- player need only the REFERENCES grant §7 gives. cards_background first,
-- because the two after it reference it.

-- One row per card back on offer: profile_pictures' columns (above, for what
-- each means) with the art held to a raster and the card's place in it.
--
-- asset_url is the file's LOCATION in the private R2 bucket — the owner's
-- cards/ folder, the key written as the bucket names it with each space %20
-- ("…/king-teenpatti/cards/Brutal%20Demon.jpg"), which a phone opens through
-- POST /api/assets/sign — and UNIQUE: the natural key the seed matches on
-- (V1.0.1__seed.sql, THE CARD BACKS, ON CONFLICT (asset_url) DO NOTHING).
-- There is no day/night pair: a card is printed stock and reads on either
-- ground. asset_format is IMAGE and nothing else, the one thing a card back is
-- drawn from (game.CardBackgroundFormat).
--
-- crop_x, crop_y, crop_w and crop_h are where the CARD is in its picture, as
-- fractions of the picture's width (x, w) and height (y, h): the owner's art
-- is product shots — the card on a dark ground, at a different size and place
-- in each — so a client draws that rectangle stretched to its card. All four
-- or none: NULL is the whole picture as the card. Set, the rectangle has a
-- positive size and lies inside the picture; a NaN or an infinity fails these
-- comparisons, so only finite figures are stored.
CREATE TABLE IF NOT EXISTS cards_background (
  id             BIGSERIAL PRIMARY KEY,
  name           TEXT    NOT NULL,
  asset_url      TEXT    NOT NULL UNIQUE,
  asset_format   TEXT    NOT NULL DEFAULT 'IMAGE' CHECK (asset_format IN ('IMAGE')),
  crop_x         DOUBLE PRECISION,
  crop_y         DOUBLE PRECISION,
  crop_w         DOUBLE PRECISION,
  crop_h         DOUBLE PRECISION,
  -- COIN is chips, through chip_ledger (reason card_background_purchase);
  -- DIAMOND and HAMMER debit their users column directly, as a picture's do.
  -- Only a COIN row is refused to a seated player (CLAUDE.md §5.1).
  currency       TEXT    NOT NULL DEFAULT 'COIN' CHECK (currency IN ('COIN', 'DIAMOND', 'HAMMER')),
  type           TEXT    NOT NULL CHECK (type IN ('FREE', 'PREMIUM')),
  cost           BIGINT  NOT NULL DEFAULT 0 CHECK (cost >= 0),
  -- The rental term, duration_days DAYS plus duration_hours HOURS; both 0 is
  -- for ever. Stamped onto the ownership row at purchase, so re-pricing the
  -- shelf never shortens a term already sold.
  duration_days  INTEGER NOT NULL DEFAULT 0 CHECK (duration_days >= 0),
  duration_hours INTEGER NOT NULL DEFAULT 0 CHECK (duration_hours >= 0),
  -- FALSE retires a card back: off the shelf and sold to nobody; whoever has
  -- chosen one keeps it on their cards.
  is_active      BOOLEAN NOT NULL DEFAULT TRUE,
  -- FALSE takes it off the Cards shelf as profile_pictures.is_listed does a
  -- face (owner, 1 Oct 2026): listed to nobody but a player who has it — an
  -- ownership row still running, or the one they have chosen — and sold to
  -- nobody; nothing is taken away. Declared with the table, which no older
  -- database has, so no guarded block brings it forward.
  is_listed      BOOLEAN NOT NULL DEFAULT TRUE,
  sort_order     INTEGER NOT NULL DEFAULT 0,
  created_at     BIGINT  NOT NULL,
  updated_at     BIGINT  NOT NULL,
  CONSTRAINT free_card_background_cost_check CHECK (
    (type = 'FREE'    AND cost =  0) OR
    (type = 'PREMIUM' AND cost >  0)
  ),
  CONSTRAINT card_background_crop_check CHECK (
    (crop_x IS NULL AND crop_y IS NULL AND crop_w IS NULL AND crop_h IS NULL) OR
    (crop_x IS NOT NULL AND crop_y IS NOT NULL AND crop_w IS NOT NULL AND crop_h IS NOT NULL
     AND crop_x >= 0 AND crop_y >= 0 AND crop_w > 0 AND crop_h > 0
     AND crop_x + crop_w <= 1 AND crop_y + crop_h <= 1)
  )
);

-- Who has bought which premium card back, and until when: the twin of
-- user_table_pictures, kept for the same reasons. A FREE row needs no row
-- here, a lapsed rental is a row whose expires_at is in the past and is never
-- deleted, and purchases is what makes a renewal's ledger action_id unique
-- ("cardbg:<user>:<id>:<n>").
CREATE TABLE IF NOT EXISTS user_cards_background (
  user_id            TEXT    NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  card_background_id BIGINT  NOT NULL REFERENCES cards_background (id) ON DELETE CASCADE,
  acquired_at        BIGINT  NOT NULL,
  -- Epoch ms the rental runs out; 0 means it never does.
  expires_at         BIGINT  NOT NULL DEFAULT 0,
  purchases          INTEGER NOT NULL DEFAULT 1 CHECK (purchases > 0),
  PRIMARY KEY (user_id, card_background_id)
);

DO $$
BEGIN
  IF to_regclass(format('%I.%I', current_schema(), 'idx_owned_cards_background_expiry')) IS NULL THEN
    CREATE INDEX IF NOT EXISTS idx_owned_cards_background_expiry
      ON user_cards_background (expires_at) WHERE expires_at > 0;
  END IF;
END;
$$;

-- The card back each player has chosen: one row per player, or none for the
-- default back. user_table_choice's twin, off users for the same reason;
-- ON DELETE CASCADE on the card back, so removing a catalogue row puts the
-- default back on whoever had chosen it rather than failing.
CREATE TABLE IF NOT EXISTS user_cards_background_choice (
  user_id            TEXT   PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
  card_background_id BIGINT NOT NULL REFERENCES cards_background (id) ON DELETE CASCADE,
  chosen_at          BIGINT NOT NULL
);

-- ------------------------------------------------------------------ emojis

-- The animated emojis a player sends to their table (owner, 26 Sep 2026: "user
-- can buy emoji which will be animation … when user click that emoji then that
-- emoji message will send to all players just like chat messages"). It is the
-- profile-picture catalogue again, for a thing SENT rather than worn: a FREE
-- row anyone may send, a PREMIUM row bought with chips, diamonds or hammers
-- and, when priced as a rental, kept for its term — the same columns, the same
-- FREE/PREMIUM rule, the same three currencies, the same rentals, and the same
-- lobby-only rule for a chip-priced one (CLAUDE.md §5.1). What differs: the
-- art is a Lottie and nothing else, and an emoji is never worn — owning one is
-- what lets a player send it at a table (the socket's chat:emoji, which reads
-- the ownership below on every send), where it reaches everybody as an
-- ordinary chat:message carrying the emoji.
--
-- Two CREATE TABLE IF NOT EXISTS, nothing on users — so a database built
-- before them takes them at its next boot, and under ops/DEPLOY.md §7
-- user_emojis needs only the REFERENCES grant §7 gives, as user_table_pictures
-- does. The seed holds NO emoji: the owner supplies the art (their Lotties,
-- names, prices and terms) and the rows are added then.

-- One row per emoji on offer. The columns are profile_pictures' — above, for
-- what each means — with asset_format held to LOTTIE, the one format an emoji
-- is played in. asset_url is the Lottie JSON (a Drive uc?export=download link,
-- or a server-relative path into PUBLIC_DIR such as /emojis/laughing.json) and
-- is UNIQUE, the natural key a later seed would match on.
CREATE TABLE IF NOT EXISTS emojis (
  id             BIGSERIAL PRIMARY KEY,
  name           TEXT    NOT NULL,
  asset_url      TEXT    NOT NULL UNIQUE,
  asset_format   TEXT    NOT NULL DEFAULT 'LOTTIE' CHECK (asset_format IN ('LOTTIE')),
  -- COIN is chips, through chip_ledger (reason emoji_purchase); DIAMOND and
  -- HAMMER debit their users column directly, as a picture's do. Only a COIN
  -- row is refused to a seated player.
  currency       TEXT    NOT NULL DEFAULT 'COIN'   CHECK (currency IN ('COIN', 'DIAMOND', 'HAMMER')),
  type           TEXT    NOT NULL DEFAULT 'FREE'   CHECK (type IN ('FREE', 'PREMIUM')),
  cost           BIGINT  NOT NULL DEFAULT 0 CHECK (cost >= 0),
  -- The rental term, duration_days DAYS plus duration_hours HOURS; both 0 is
  -- for ever. Stamped onto the ownership row at purchase.
  duration_days  INTEGER NOT NULL DEFAULT 0 CHECK (duration_days >= 0),
  duration_hours INTEGER NOT NULL DEFAULT 0 CHECK (duration_hours >= 0),
  is_active      BOOLEAN NOT NULL DEFAULT TRUE,
  sort_order     INTEGER NOT NULL DEFAULT 0,
  created_at     BIGINT  NOT NULL,
  updated_at     BIGINT  NOT NULL,
  -- FALSE takes the emoji off the Emojis shelf and the table's emoji page
  -- (owner, 1 Oct 2026) as profile_pictures.is_listed does a face: listed to
  -- nobody but a player who owns it on a rental still running, and sold to
  -- nobody. Whoever owns it still sends it, and a reward can still give it.
  -- Last, where the guarded block below puts it on an older database.
  is_listed      BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT free_emoji_cost_check CHECK (
    (type = 'FREE'    AND cost =  0) OR
    (type = 'PREMIUM' AND cost >  0)
  )
);

-- emojis.is_listed for a database built before it (1 Oct 2026), guarded as
-- profile_pictures.is_listed is. TRUE: every emoji already on offer stays.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = current_schema() AND table_name = 'emojis' AND column_name = 'is_listed'
  ) THEN
    EXECUTE 'ALTER TABLE emojis ADD COLUMN is_listed BOOLEAN NOT NULL DEFAULT TRUE';
  END IF;
END;
$$;

-- Who has bought which premium emoji, and until when: the twin of
-- user_profile_pictures, kept for the same reasons. A FREE emoji needs no row
-- here; a lapsed rental is a row whose expires_at is in the past, never
-- deleted, and every ownership test (the listing, a purchase, a send) says so
-- rather than relying on a sweep — there is nothing worn to sweep, which is
-- also why, unlike the picture tables, it has no index on expires_at. purchases
-- is what makes a renewal's ledger action_id unique ("emoji:<user>:<id>:<n>").
CREATE TABLE IF NOT EXISTS user_emojis (
  user_id     TEXT    NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  emoji_id    BIGINT  NOT NULL REFERENCES emojis (id) ON DELETE CASCADE,
  acquired_at BIGINT  NOT NULL,
  -- Epoch ms the rental runs out; 0 means it never does.
  expires_at  BIGINT  NOT NULL DEFAULT 0,
  purchases   INTEGER NOT NULL DEFAULT 1 CHECK (purchases > 0),
  PRIMARY KEY (user_id, emoji_id)
);

-- RETIRED 30 Sep 2026 (owner: "Remove 24-hour daily reward, 4-hour bonus, and
-- milestone reward"). The three lobby rewards were removed from the server,
-- and nothing reads or writes this table any more. It is kept, rows and all,
-- so that a rollback to go-server/v1.12.0 on a database this build made still
-- finds it; never drop it on a hunch.
--
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

-- One signed-in device per account (owner, 28 Sep 2026: "when someone is
-- already logged in … and some other guy tries to login with same google
-- account in diff device, the first one will be auto logout"). version counts
-- the account's sign-ins: every login adds one and carries the new figure in
-- its token (the JWT's `sv`), and a token carrying any other figure is
-- refused session_replaced — at every signed-in request and at the socket's
-- handshake — so the device signed in before is out the moment the next one
-- signs in, and stays out. A player with no row has never signed in since
-- this table existed: version 0, which is what a token without `sv` carries,
-- so every session from before it stays good until that account's next login.
-- A side table, as user_table_choice is, because a users column would be an
-- ALTER TABLE users and a DEPLOY.md §7 one-off on every deploy that carries it.
CREATE TABLE IF NOT EXISTS user_sessions (
  user_id    TEXT   PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
  version    BIGINT NOT NULL DEFAULT 0 CHECK (version >= 0),
  updated_at BIGINT NOT NULL
);

-- Each player's gameplay statistics — Player stats v2 (owner, 27 Sep 2026:
-- "maintain stats acc to only three category: teenpatti variation and poker …
-- also store … how many times he got trail, pair, highcard, pure sequence,
-- sequence … how many muflis, ak47, other gameplay type he played … store this
-- info in redis, then async … group commit"). users holds none of them.
--
-- ONE row per player per BUCKET: `category` is TEEN_PATTI (seen and blind
-- tables, public or private), VARIATION (variation tables) or POKER (the four
-- poker categories) — game.StatsBucket. No CHECK: the server writes only those
-- three, and a fourth would be a new value, never a constraint to change. The
-- six outcome counters follow requirement 16 (a hand is played once the player
-- made a voluntary bet; total_winnings is gross chips taken in pots won and
-- biggest_pot the largest of them; hands_left is hands abandoned mid-hand,
-- which the wire's handsLeftMid still carries); trail … high_card count the
-- hand each player HELD at a Teen Patti or Variation hand end, as the table
-- counted it (wild cards make the category; under 5-Card the three that
-- played) — the six sum to the hands those buckets finished, and all six stay
-- 0 on a POKER row. total_tax_paid (owner, 2 Oct 2026: "In player stats table,
-- also include column how much tax he totally paid") is the winning tax the
-- player has paid in the bucket — the chips the table withheld from their
-- taxed wins, the sum of their chip_ledger table_tax rows — so
-- total_winnings − total_tax_paid is what those pots actually paid them; it
-- stays 0 on a POKER row, since no poker room taxes a winner.
--
-- NOT written in the money transactions: the ledger writes money only. A
-- hand's counters are recorded in the live store (kt:stats:<userId>) once its
-- write has committed, and the stats flusher (internal/stats) adds them here in
-- batches — one transaction per batch, exactly once by stats_flushes below. So
-- the figures here trail play by up to one flush interval (STATS_FLUSH_MS);
-- every account read sums a player's rows (db.userColumns), and the
-- HANDS_PLAYED milestone reads that sum. This build goes onto a fresh database
-- (owner, 27 Sep 2026): nothing is copied from anywhere.
CREATE TABLE IF NOT EXISTS player_stats (
  user_id        TEXT   NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  category       TEXT   NOT NULL,
  hands_played   BIGINT NOT NULL DEFAULT 0,
  hands_won      BIGINT NOT NULL DEFAULT 0,
  hands_lost     BIGINT NOT NULL DEFAULT 0,
  hands_left     BIGINT NOT NULL DEFAULT 0,
  total_winnings BIGINT NOT NULL DEFAULT 0,
  biggest_pot    BIGINT NOT NULL DEFAULT 0,
  trail          BIGINT NOT NULL DEFAULT 0,
  pure_sequence  BIGINT NOT NULL DEFAULT 0,
  sequence       BIGINT NOT NULL DEFAULT 0,
  color          BIGINT NOT NULL DEFAULT 0,
  pair           BIGINT NOT NULL DEFAULT 0,
  high_card      BIGINT NOT NULL DEFAULT 0,
  total_tax_paid BIGINT NOT NULL DEFAULT 0,
  created_at     BIGINT NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  updated_at     BIGINT NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  PRIMARY KEY (user_id, category)
);

-- A database a go-server/v1.6.0 boot built (Friends V1, the table tax) holds
-- player_stats in its OLD shape — one row per player, no category — and the
-- CREATE TABLE IF NOT EXISTS above leaves it as it is. This build reads and
-- writes the table by bucket, so on that one every account read and every
-- stats flush would fail AFTER a boot that looked clean: logins, the socket
-- handshake, rewards, all of it. The boot is refused here instead, naming the
-- fix. Nothing is converted: v1.6.0's counters cover every game, and filing
-- them under TEEN_PATTI would misstate them — this build goes onto a FRESH
-- database (owner, 27 Sep 2026; go-server/ops/DEPLOY.md §8).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = current_schema() AND table_name = 'player_stats'
                    AND column_name = 'category') THEN
    RAISE EXCEPTION 'player_stats has the go-server/v1.6.0 shape (one row per player, no category); this build keeps it per game (Player stats v2) and needs a fresh database — go-server/ops/DEPLOY.md §8';
  END IF;
END $$;

-- player_stats.total_tax_paid for a database built before it (2 Oct 2026:
-- every database until then, production's included). Catalogue-guarded, as
-- users.is_bot is: only a database missing the column runs the ALTER, once,
-- and cheaply — a NOT NULL column with a constant DEFAULT is stored in the
-- catalogue, not written into every row. 0: the tax paid is counted from the
-- first hand settled by a build that knows the column; nothing is backfilled
-- (the chip_ledger table_tax rows are the history of what each player paid,
-- but a Teen Patti row does not say whether its table was a variation one, so
-- they cannot be filed per bucket). After the refusal above, so a v1.6.0
-- table is refused rather than altered.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = current_schema() AND table_name = 'player_stats' AND column_name = 'total_tax_paid'
  ) THEN
    EXECUTE 'ALTER TABLE player_stats ADD COLUMN total_tax_paid BIGINT NOT NULL DEFAULT 0';
  END IF;
END;
$$;

-- The Variation bucket by the variation each hand was played under (Player
-- stats v2): one row per player per variation — MUFLIS, AK47, JOKER, HUKAM,
-- LOWEST_JOKER, HIGHEST_JOKER, FIVE_CARD (game.Variation). An OPEN set: a
-- future variation is a new value, never a schema change, so no CHECK.
-- hands_played counts every hand the player was resolved in at the hand end
-- under it, hands_won the ones they won. Written by the stats flusher alone,
-- beside player_stats and in the same transaction.
CREATE TABLE IF NOT EXISTS player_variation_stats (
  user_id      TEXT   NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  variation    TEXT   NOT NULL,
  hands_played BIGINT NOT NULL DEFAULT 0,
  hands_won    BIGINT NOT NULL DEFAULT 0,
  created_at   BIGINT NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  updated_at   BIGINT NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  PRIMARY KEY (user_id, variation)
);

-- The stats flusher's receipts: one row per batch it committed, written in
-- the batch's own transaction (db.StatsStore.Flush). The batch id is minted
-- when the batch is moved out of the live store's pending counters and kept
-- with them until this row exists; a batch whose id is already here was
-- committed and its acknowledgement lost, so a retry of it adds nothing — the
-- group commit is exactly once. players is how many players the batch held;
-- flushed_at (epoch ms) is what the flusher prunes by after 7 days. Not money
-- and not audit: a bookkeeping row of the counters' pipeline.
CREATE TABLE IF NOT EXISTS stats_flushes (
  batch_id   TEXT    PRIMARY KEY,
  players    INTEGER NOT NULL,
  flushed_at BIGINT  NOT NULL
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

DO $$
BEGIN
  IF to_regclass(format('%I.%I', current_schema(), 'idx_ledger_hand')) IS NULL THEN
    CREATE INDEX IF NOT EXISTS idx_ledger_hand ON chip_ledger (hand_id);
  END IF;
END;
$$;

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
DO $$
BEGIN
  IF to_regclass(format('%I.%I', current_schema(), 'idx_ledger_purge')) IS NULL THEN
    CREATE INDEX IF NOT EXISTS idx_ledger_purge ON chip_ledger (created_at)
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
DO $$
BEGIN
  IF to_regclass(format('%I.%I', current_schema(), 'diamond_purchases_user_idx')) IS NULL THEN
    CREATE INDEX IF NOT EXISTS diamond_purchases_user_idx ON diamond_purchases (user_id, created_at);
  END IF;
END;
$$;


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

DO $$
BEGIN
  IF to_regclass(format('%I.%I', current_schema(), 'hammer_purchases_user_idx')) IS NULL THEN
    CREATE INDEX IF NOT EXISTS hammer_purchases_user_idx ON hammer_purchases (user_id, created_at);
  END IF;
END;
$$;

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

DO $$
BEGIN
  IF to_regclass(format('%I.%I', current_schema(), 'hammer_spends_user_idx')) IS NULL THEN
    CREATE INDEX IF NOT EXISTS hammer_spends_user_idx ON hammer_spends (user_id, created_at);
  END IF;
END;
$$;


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
DO $$
BEGIN
  IF to_regclass(format('%I.%I', current_schema(), 'missile_purchases_user_idx')) IS NULL THEN
    CREATE INDEX IF NOT EXISTS missile_purchases_user_idx ON missile_purchases (user_id, created_at);
  END IF;
END;
$$;

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

DO $$
BEGIN
  IF to_regclass(format('%I.%I', current_schema(), 'missile_spends_user_idx')) IS NULL THEN
    CREATE INDEX IF NOT EXISTS missile_spends_user_idx ON missile_spends (user_id, created_at);
  END IF;
END;
$$;


-- -------------------------------------------------------------- lucky draw

-- The Lucky Draw (owner, 24 Sep 2026): a wheel of six slots the lobby opens, a
-- prize in each, spun by the SERVER — which picks the slot by weight, grants
-- the prize and records the spin in one transaction (db.LuckyDraws.Spin); the
-- phone only asks to spin and turns its wheel to the slot it is told. Three
-- tables:
--
--   lucky_draws       the draws — today one, BEGINNER_LUCKY_DRAW, a spin every
--                     three days;
--   lucky_draw_slots  the six slots of each draw and the prize in each;
--   user_lucky_draws  every spin, for good: the audit, the cooldown's clock
--                     and the replay guard.
--
-- The first two are CONFIGURATION, as the table catalogue is (the header):
-- what a draw offers, never a spin in progress, and read on each request —
-- a slot re-priced with an UPDATE is on the wheel at the next look, no restart.
-- The third is an audit, as missile_spends is. Nothing of either is live state:
-- a spin is one request, finished before it answers.
--
-- A PRIZE IS reward_type + reward_value + reward_ref_id, and nothing else.
-- CHIPS, DIAMOND, HAMMER and MISSILE carry an amount in reward_value;
-- NO_REWARD is a slot that pays nothing (its value, if any, is not read);
-- PROFILE_PICTURE and TABLE_PICTURE name an existing catalogue row by its id in
-- reward_ref_id (TEXT, so a later prize can name something that is not a
-- number — an AVATAR_FRAME 'golden_crown_frame', a TITLE 'high_roller'). No
-- ENUM and no CHECK lists the types: a new kind of prize is a row and a
-- release, never a change to a constraint an existing database already has —
-- the trap profile_pictures_currency_check sprang when HAMMER arrived. The
-- server grants only the types it knows (db.LuckyReward*) and leaves out of
-- the draw, with a logged reason, a slot it cannot grant: an unknown type, an
-- amount that is missing or zero, or a picture that is gone or retired.

-- One row per draw. code is what the app asks for (GET /api/lucky-draw?code=);
-- a request that names none gets the first active draw in sort_order.
-- spinner_type says what kind of draw it is — BEGINNER today (the owner's
-- seed); VIP, EVENT and the like later — and rides the wire as spinnerType;
-- the app has one wheel and draws it for every type. cooldown_ms is how long
-- after a player's last spin of the draw they may spin it again (0: whenever
-- they like). Retire a draw with is_active = FALSE, never DELETE: its spins
-- keep pointing at it.
CREATE TABLE IF NOT EXISTS lucky_draws (
  id           BIGSERIAL PRIMARY KEY,
  code         TEXT    NOT NULL UNIQUE,
  name         TEXT    NOT NULL,
  spinner_type TEXT    NOT NULL DEFAULT 'STANDARD',
  cooldown_ms  BIGINT  NOT NULL DEFAULT 0 CHECK (cooldown_ms >= 0),
  is_active    BOOLEAN NOT NULL DEFAULT TRUE,
  sort_order   INTEGER NOT NULL DEFAULT 0,
  created_at   BIGINT  NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  updated_at   BIGINT  NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint)
);

-- One row per slot of a draw's wheel, slot_number 1 to 6 clockwise from the
-- top. weight is the slot's share of the draw — a slot of weight 40 in a draw
-- whose active slots weigh 100 in all comes up 40 times in 100 — so weights
-- need not add up to anything; they must only be positive, which the CHECK
-- holds. An inactive slot is neither shown nor drawn. The weights never leave
-- the server.
CREATE TABLE IF NOT EXISTS lucky_draw_slots (
  id            BIGSERIAL PRIMARY KEY,
  lucky_draw_id BIGINT   NOT NULL REFERENCES lucky_draws (id) ON DELETE CASCADE,
  slot_number   SMALLINT NOT NULL CHECK (slot_number BETWEEN 1 AND 6),
  reward_type   TEXT     NOT NULL,
  reward_value  BIGINT   CHECK (reward_value IS NULL OR reward_value >= 0),
  reward_ref_id TEXT,
  weight        INTEGER  NOT NULL CHECK (weight > 0),
  is_active     BOOLEAN  NOT NULL DEFAULT TRUE,
  sort_order    INTEGER  NOT NULL DEFAULT 0,
  created_at    BIGINT   NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  updated_at    BIGINT   NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  UNIQUE (lucky_draw_id, slot_number)
);

-- One row per spin, never updated and never deleted: which slot came up and a
-- SNAPSHOT of its prize as it stood then, so the record keeps saying what was
-- won after the slot is re-priced or pointed at another picture. The newest row
-- of a player's for a draw is the cooldown's clock (the index below). action_id
-- is the spin's idempotency key, "lucky:<userId>:<client actionId>"
-- (db.LuckyDrawActionID), inserted in the same transaction as the prize: a
-- retried request whose first attempt committed finds its row and is answered
-- with that spin again, granting nothing twice. A CHIPS prize's chip_ledger row
-- carries the same key, so the ledger's own UNIQUE index guards it as well.
-- slot_id has no ON DELETE: a slot that has been won cannot be deleted, only
-- retired (is_active = FALSE), because the record points at it.
CREATE TABLE IF NOT EXISTS user_lucky_draws (
  id            BIGSERIAL PRIMARY KEY,
  user_id       TEXT   NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  lucky_draw_id BIGINT NOT NULL REFERENCES lucky_draws (id),
  slot_id       BIGINT NOT NULL REFERENCES lucky_draw_slots (id),
  reward_type   TEXT   NOT NULL,
  reward_value  BIGINT CHECK (reward_value IS NULL OR reward_value >= 0),
  reward_ref_id TEXT,
  action_id     TEXT   NOT NULL UNIQUE,
  created_at    BIGINT NOT NULL
);

-- A player's latest spin of a draw, for the cooldown; newest first.
DO $$
BEGIN
  IF to_regclass(format('%I.%I', current_schema(), 'user_lucky_draws_last_idx')) IS NULL THEN
    CREATE INDEX IF NOT EXISTS user_lucky_draws_last_idx
      ON user_lucky_draws (user_id, lucky_draw_id, created_at DESC);
  END IF;
END;
$$;


-- ----------------------------------------------------------------- friends

-- The social graph (Friends V1, owner 26 Sep 2026): a lobby feature — search
-- a player by their Player ID (users.id), send a request, accept or reject
-- it, a friend list, a friend's profile, remove a friend. Two tables, both
-- ACCOUNT FACTS, not game state: who asked whom, and who is friends with
-- whom. Whether a friend is online or playing is never here — no column
-- anywhere in PostgreSQL says so; that is the live store's (kt:online and the
-- seat's kt:playing:<userId> record), read per request.
--
-- Nothing on users: both reference it, which needs only the REFERENCES grant
-- ops/DEPLOY.md §7 gives, so a database built before them takes them at its
-- next boot whoever owns users.

-- Every friend request ever sent, and what became of it: PENDING until the
-- recipient accepts (ACCEPTED, and a friendships pair is written in the same
-- transaction) or rejects it (REJECTED), or until either player deletes their
-- account (CANCELLED, DELETE /api/account). A row is never deleted — it is
-- the record of the request — and a new request between the same two players
-- is a new row, once the last one is no longer pending.
CREATE TABLE IF NOT EXISTS friend_requests (
  id           BIGSERIAL PRIMARY KEY,
  requester_id TEXT   NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  recipient_id TEXT   NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  status       TEXT   NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'ACCEPTED', 'REJECTED', 'CANCELLED')),
  created_at   BIGINT NOT NULL,
  updated_at   BIGINT NOT NULL,
  CHECK (requester_id <> recipient_id)
);

-- One PENDING request per unordered pair of players: no duplicate, and no
-- A→B beside B→A. This index is what decides two requests sent at the same
-- instant — the second insert fails 23505 and db.Friends.Send reads the
-- winner back and answers with the refusal that fits it.
DO $$
BEGIN
  IF to_regclass(format('%I.%I', current_schema(), 'friend_requests_one_pending_per_pair')) IS NULL THEN
    CREATE UNIQUE INDEX IF NOT EXISTS friend_requests_one_pending_per_pair
      ON friend_requests (LEAST(requester_id, recipient_id), GREATEST(requester_id, recipient_id)) WHERE status = 'PENDING';
  END IF;
END;
$$;
-- A player's pending requests, received and sent (GET /api/friends/requests).
DO $$
BEGIN
  IF to_regclass(format('%I.%I', current_schema(), 'friend_requests_incoming')) IS NULL THEN
    CREATE INDEX IF NOT EXISTS friend_requests_incoming ON friend_requests (recipient_id) WHERE status = 'PENDING';
  END IF;
  IF to_regclass(format('%I.%I', current_schema(), 'friend_requests_outgoing')) IS NULL THEN
    CREATE INDEX IF NOT EXISTS friend_requests_outgoing ON friend_requests (requester_id) WHERE status = 'PENDING';
  END IF;
END;
$$;

-- Who is friends with whom: one row per DIRECTION, so a friendship is a pair
-- of rows (A→B and B→A) written together when a request is accepted and
-- deleted together when either removes the other or deletes their account.
-- A player's friends are then the rows keyed on their own user_id, read off
-- the UNIQUE (user_id, friend_user_id) index. created_at is when the two
-- became friends (the wire's friendsSince).
CREATE TABLE IF NOT EXISTS friendships (
  id             BIGSERIAL PRIMARY KEY,
  user_id        TEXT   NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  friend_user_id TEXT   NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at     BIGINT NOT NULL,
  UNIQUE (user_id, friend_user_id),
  CHECK (user_id <> friend_user_id)
);


-- ---------------------------------------------------------- player reports

-- Report Player (owner, 27 Sep 2026: "A player sitting at a gameplay table
-- must be able to report another player currently at the same table"). One
-- row per report: MODERATION AUDIT, neither game state nor a copy of it. A
-- report never changes anything at a table by itself — it pauses, kicks,
-- folds and bans nobody; it is a row for a moderator to read.
--
-- The client sends only who, why and (optionally) what happened (POST
-- /api/reports, auth/reports.go); the server fills every other column from
-- the reporter's session and its own table state: the reporter, and — from
-- the room the two shared, now or within REPORT_RECENT_MS — the KIND of table
-- (game: the engine code, teen_patti | poker; category: seen … omaha;
-- variant: the variation a Variation hand was decided by, the poker variant
-- at a poker room, NULL otherwise), the room's id (table_id) and the hand
-- (hand_id: the hand the reported player is in, else the last one they were
-- dealt into at that table; NULL when neither is known). Those two are
-- REFERENCES by value, never copies of the hand: a hand's authoritative
-- record is its chip_ledger rows (chip_ledger.hand_id), which the ledger
-- purge keeps for every hand a report names (db.PurgeLedger), and the room
-- lives in the live store only while it plays. Neither id is ever sent to a
-- client.
--
-- status is the moderation lifecycle — PENDING as filed, then UNDER_REVIEW,
-- ACTION_TAKEN or DISMISSED — set by moderation (none is built yet) and never
-- by a player. A CLOSED set, as friend_requests.status is, so a CHECK. reason
-- is deliberately NOT checked here: the server validates it against its own
-- list (auth.ReportReasons), so a new reason is code and never a change to a
-- constraint an existing database already has (the trap
-- profile_pictures_currency_check sprang when HAMMER arrived; the Lucky
-- Draw's reward_type is left open the same way). description is NULL when the
-- reporter wrote none; its length is the server's (REPORT_DESCRIPTION_MAX).
--
-- A moderation system to come adds a table of its own naming player_reports
-- (id) for the actions it records; a player's reports filed and received are
-- read off the two (player, created_at) indexes, a hand's off hand_id.
--
-- Both players are users rows, which are never deleted (users_no_delete) — an
-- account deletion pseudonymises its row and its reports stay, as its ledger
-- does; ON DELETE CASCADE is for the deliberate privileged removal only, as
-- on every other table naming a player. Nothing on users: the two foreign
-- keys need only ops/DEPLOY.md §7's REFERENCES grant, so a database built
-- before this table takes it at its next boot whoever owns users.
CREATE TABLE IF NOT EXISTS player_reports (
  id               BIGSERIAL PRIMARY KEY,
  reporter_user_id TEXT   NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  reported_user_id TEXT   NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  reason           TEXT   NOT NULL,
  description      TEXT,
  game             TEXT   NOT NULL,
  category         TEXT   NOT NULL,
  variant          TEXT,
  table_id         TEXT   NOT NULL,
  hand_id          TEXT,
  status           TEXT   NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'UNDER_REVIEW', 'ACTION_TAKEN', 'DISMISSED')),
  created_at       BIGINT NOT NULL,
  updated_at       BIGINT NOT NULL,
  CHECK (reporter_user_id <> reported_user_id)
);

-- A player's history as the one reported and as the reporter — the second is
-- also what the per-reporter limit counts (the reports filed in the last
-- REPORT_WINDOW_MS, db.Reports.Submit) — and the moderation queue by status.
DO $$
BEGIN
  IF to_regclass(format('%I.%I', current_schema(), 'player_reports_reported_idx')) IS NULL THEN
    CREATE INDEX IF NOT EXISTS player_reports_reported_idx ON player_reports (reported_user_id, created_at);
  END IF;
  IF to_regclass(format('%I.%I', current_schema(), 'player_reports_reporter_idx')) IS NULL THEN
    CREATE INDEX IF NOT EXISTS player_reports_reporter_idx ON player_reports (reporter_user_id, created_at);
  END IF;
  IF to_regclass(format('%I.%I', current_schema(), 'player_reports_status_idx')) IS NULL THEN
    CREATE INDEX IF NOT EXISTS player_reports_status_idx ON player_reports (status, created_at);
  END IF;
END;
$$;
-- The reports about one hand (a moderator's, and the ledger purge's look for a
-- hand to keep) — and, being UNIQUE, the guarantee under the server's own
-- check that one reporter reports one player once per hand.
DO $$
BEGIN
  IF to_regclass(format('%I.%I', current_schema(), 'player_reports_one_per_hand')) IS NULL THEN
    CREATE UNIQUE INDEX IF NOT EXISTS player_reports_one_per_hand
      ON player_reports (hand_id, reporter_user_id, reported_user_id) WHERE hand_id IS NOT NULL;
  END IF;
END;
$$;


-- --------------------------------------------------------- player levels

-- Player levels, badges and XP (owner, 26 Sep 2026: "create table which stores
-- every player xp and ac to their level, tax will be applied", and "XP source
-- / XP: Complete a hand 1 · Win a game 1 · 30 minutes active gameplay 5 · 60
-- minutes active gameplay 15 · Daily play bonus 5 … daily xp cap limit is 50XP
-- for each user … these XP source and XP store in diff table" — sources the
-- daily list below replaced the next day; then 27 Sep 2026: "Vip is not a
-- level, it is badge, User can hold multiple badges,
-- Rookie, beginner is level, and badge and level both are different … the tax
-- will be applied acc to minimum of badge or player level"; "Daily XP user can
-- get store this info in db";
-- then the Royal badges the store lists, each with its Lottie, validity, price
-- and 0% winning tax, "Add a icon in Store to buy badges"; then 28 Sep 2026,
-- the ONE-TIME missions: "One-time missions are permanent missions that a
-- player can complete only once … The system should now support DAILY and
-- ONE_TIME"). Nine tables:
--
--   player_levels  CONFIGURATION: the ladder a player climbs by XP — fifty
--                  levels, each reached at its min_xp — with the title and
--                  icon each is shown by and the WINNING TAX each carries: the
--                  share of the winnings (the pot less the winner's own
--                  contribution), in basis points (2000 = 20.00%), that a
--                  table which taxes its winners (table_configs.winner_tax)
--                  takes from the winner of a hand.
--   badges         CONFIGURATION: the badges a player may hold beside their
--                  level — Regular, every player's by default for life at 20%
--                  (is_default; owner, 27 Sep 2026: "By default every user
--                  will hold this Regular badge") — and the Royal badges the
--                  store lists, granted by hand or bought —
--                  each with the winning tax it brings its holder's down to
--                  (NULL: none) and its VALIDITY: how long a grant of it lasts
--                  (owner, 27 Sep 2026: "add validity column in badges so that
--                  when it expires, player will not get tax benefit"; 0 = for
--                  ever), its price in rupees and its art (a Lottie), and —
--                  for a badge the app sells through Play — the product it is
--                  bought as.
--   user_badges    an ACCOUNT FACT: the badges each player has been given
--                  beyond the default one — as many as they are given — each
--                  with the instant it runs out. Granted BY HAND (V1.0.1's
--                  header) or bought in the store (badge_purchases); no amount
--                  of XP ever grants one.
--   badge_purchases  an ACCOUNT FACT: every store purchase of a badge, keyed
--                  by its Play purchase token — the replay guard and the
--                  receipt.
--   xp_sources     CONFIGURATION: the DAILY XP a player can earn (owner,
--                  27 Sep 2026: "Daily XP user can get store this info in db
--                  … After 24 hours this will be reset, so user can claim
--                  this again") — each source what earns it (its kind: so many
--                  minutes of active play in the window, or a hand won with a
--                  given Teen Patti hand), the XP it gives, and how many times
--                  a window it can be earned. A kind this build does not know
--                  earns nothing (db.XPKind*). Since 28 Sep 2026 a source has
--                  a MISSION TYPE: DAILY (every source until then, and the
--                  default) or ONE_TIME — a mission completed once, for good,
--                  when the hands a player completes reach its target (so many
--                  hands played or won, so many different games played),
--                  never reset by a window.
--   player_xp_claims  an ACCOUNT FACT: how many times each player has earned
--                  each DAILY source in their current window — what makes "1
--                  time" once a day, and what the app ticks off.
--   player_xp_missions  an ACCOUNT FACT: each player's progress on each
--                  ONE_TIME mission and, once its target is reached, when it
--                  was completed and the XP it gave — one row per player per
--                  mission, for ever (its primary key), which is what makes
--                  "once" once.
--   xp_settings    CONFIGURATION, ONE row: the window's length — how long a
--                  day lasts for the daily sources, each earned its
--                  times_per_window in it — and an optional daily cap on the
--                  XP a player earns in one window: NULL, as seeded, is no cap
--                  at all (owner, 27 Sep 2026: "Don't set any daily limit to
--                  xp").
--   player_xp      an ACCOUNT FACT, one row per player who has played a hand
--                  out: the lifetime XP that decides their level and the
--                  window their daily XP is counted in (window_start,
--                  window_xp) — opened by the first hand they complete, and
--                  rolled 24 hours later by the next. No row = 0 XP, no
--                  window: Level 1.
--
-- The four configuration tables are read on demand and never cached — every
-- account read resolves a level and the badges afresh, and every award reads
-- the sources and the settings in its own transaction — so an owner's UPDATE
-- (or a badge granted) shows at the next read, with no restart, and reaches a
-- seat's winning-tax rate at its next sit-down or hand end. V1.0.1 seeds all
-- four.
--
-- A player's LEVEL is the highest level whose min_xp their XP has reached —
-- and, should the ladder have no level that low (an owner's edit), the lowest
-- rung. A level never expires ("there is no validity on player level"): it is
-- the XP, and XP is never taken away. Their BADGES are every active default
-- badge and every active badge user_badges gives them that has not run out.
-- The WINNING TAX they pay is the LOWEST of their level's tax_bps and the
-- tax_bps of every badge they hold (a badge with none sets no rate):
-- db.playerLevelJoins, the one statement of the rule — so a badge that runs
-- out stops lowering the rate at the next account read, and a seated player's
-- at the next hand end. A badge is a property of its HOLDER, never of an XP
-- total: XP only ever moves a player up the ladder.
--
-- XP is written by ONE function (db.awardXP), whatever the source: it opens a
-- new window when the last one has run out, grants each source asked for that
-- the player has not yet earned its times_per_window in the window
-- (player_xp_claims) — its XP, or what a daily cap, where an owner sets one,
-- leaves of it — and adds the XP to both the lifetime and the window's XP. The
-- ledger transaction that settles a hand opens or rolls the window of every
-- player who completed it and awards the winner's WIN_HAND source; the
-- PLAY_TIME ones are awarded asynchronously, once the play time kept in the
-- live store (Redis, never here) for the window reaches their minutes. The
-- same settle moves every finisher's ONE_TIME missions on (player_xp_missions)
-- and completes, through db.awardXP, each whose target the hand reached: the
-- row goes from completed_at 0 to the instant, once — a conditional UPDATE
-- under the row's lock — and only the statement that made that change adds
-- the mission's XP. A ONE_TIME mission's XP is lifetime XP alone: it is never
-- counted in a window's XP, a daily cap never limits it, and no window ever
-- resets it.
--
-- None of it is game state. The rate a seat pays is captured on the seat when
-- its player sits down and refreshed from every hand-end settle, and kept in
-- the table's Redis snapshot; nothing at a table reads these tables at any
-- other moment. All nine are the app role's, and the foreign keys of
-- user_badges, player_xp, player_xp_claims and player_xp_missions to users
-- need only the REFERENCES grant ops/DEPLOY.md §7 gives.
--
-- As seeded, a window's XP is at most 108 — 15, 60 and 120 minutes of play
-- (3 + 20 + 50) and a win with each of Pair, Color, Sequence, Pure Sequence
-- and Trail (1 + 2 + 4 + 8 + 20), each once — so Level 10 (4,000 XP) is at
-- least 38 days away. The ladder, the sources, the window and any cap are all
-- rows the owner can edit. The seeded ONE_TIME missions add 245 XP once in a
-- player's life (a tenth of the XP first given, and no Poker missions; owner,
-- 28 Sep 2026), and none of it to any window.
CREATE TABLE IF NOT EXISTS player_levels (
  level      SMALLINT PRIMARY KEY CHECK (level >= 1),
  -- The XP that reaches this level. UNIQUE: two levels at one threshold would
  -- be one level twice.
  min_xp     BIGINT   NOT NULL UNIQUE CHECK (min_xp >= 0),
  title      TEXT     NOT NULL,
  -- The level's emoji, exactly as the owner gave it — some are two emoji, and
  -- the crossed swords, shield, medal and infinity carry a U+FE0F variation
  -- selector that must not be lost. Sent as user.playerLevel.icon; since
  -- 29 Sep 2026 the app draws the level's art (asset_url) instead, and the
  -- emoji is for anything that has no art to draw (a log line, an older app).
  icon       TEXT     NOT NULL,
  -- The winning tax in basis points: 2000 = 20.00%, 10000 = all the winnings.
  tax_bps    INTEGER  NOT NULL CHECK (tax_bps BETWEEN 0 AND 10000),
  -- The level's ART (owner, 29 Sep 2026: "Instead of using icons use lottie
  -- animations json for showing player Level"): a LOTTIE at asset_url, drawn
  -- wherever the app showed the level's emoji — badges.asset_url's twin.
  -- NULL: not given yet, and the app shows an empty mark; the seed fills a
  -- NULL from its own list, so a URL the owner sends later reaches every
  -- database at its next boot. '' is none on purpose, which the seed leaves.
  asset_url    TEXT,
  asset_format TEXT     CHECK (asset_format IN ('IMAGE', 'SVG', 'LOTTIE', 'RIVE')),
  created_at BIGINT   NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  updated_at BIGINT   NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint)
);

-- player_levels.asset_url and .asset_format for a database built before them
-- (29 Sep 2026: production's has the ladder and neither). Catalogue-guarded,
-- as users.is_bot is: only a database missing a column runs its ALTER, once.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = current_schema() AND table_name = 'player_levels' AND column_name = 'asset_url'
  ) THEN
    EXECUTE 'ALTER TABLE player_levels ADD COLUMN asset_url TEXT';
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = current_schema() AND table_name = 'player_levels' AND column_name = 'asset_format'
  ) THEN
    EXECUTE 'ALTER TABLE player_levels ADD COLUMN asset_format TEXT CHECK (asset_format IN (''IMAGE'', ''SVG'', ''LOTTIE'', ''RIVE''))';
  END IF;
END;
$$;

-- One row per badge. code is what the server and the app know it by; title
-- and icon are what a player is shown (icon an emoji or a playing-card symbol,
-- like a level's mark, or empty for none). tax_bps is the winning tax the
-- badge brings its holder's down to — NULL on a badge that sets no rate.
-- validity_days is how long a grant of the badge lasts from the moment it is
-- given (0: for ever) — what user_badges.expires_at is filled from when a
-- grant does not name its own. is_default: every player holds it with no
-- user_badges row, for ever — Regular, as seeded (owner, 27 Sep 2026: "By
-- default every user will hold this Regular badge"), which the store never
-- lists. price_inr is what the badge costs, ALWAYS in
-- Indian rupees, whole (owner, 27 Sep 2026: "include price column in badge
-- with validity", "price in badges will always be in inr currency") — NULL
-- where no price is set. The store's Badges shelf LISTS every
-- active badge but the default one that has a price (owner, 27 Sep 2026:
-- "Add a icon in Store to buy badges", then "for badges use this entry, not
-- vips entry": the Royal badges).
-- play_product_id makes a listed badge BUYABLE in the app: the Google Play
-- managed product the shelf sells it as, bought through POST
-- /api/purchases/google and granted by db.CreditBadgePurchase for its
-- validity; a listed badge with none — every Royal badge, as seeded — is
-- asked for through support ("for all type of royal badges Add a button to
-- contact support in store") and granted by hand. Play holds the real price
-- and currency a buyer pays; price_inr is what the shelf shows, and the record
-- a purchase keeps. asset_url and asset_format are the badge's ART — a LOTTIE
-- the store's card plays ("with their lottie animation u can store in db"),
-- hosted as the picture catalogue's is (a Drive uc?export=download&id= link),
-- IMAGE, SVG or RIVE as for a picture; NULL on a badge shown by its icon
-- alone. Retire a badge with is_active = FALSE — its holders keep their rows
-- and simply stop holding it — rather than deleting it, which would take every
-- grant of it too.
CREATE TABLE IF NOT EXISTS badges (
  code            TEXT     PRIMARY KEY,
  title           TEXT     NOT NULL,
  icon            TEXT     NOT NULL DEFAULT '',
  tax_bps         INTEGER  CHECK (tax_bps BETWEEN 0 AND 10000),
  validity_days   INTEGER  NOT NULL DEFAULT 0 CHECK (validity_days >= 0),
  price_inr       INTEGER  CHECK (price_inr >= 0),
  play_product_id TEXT     UNIQUE,
  asset_url       TEXT,
  asset_format    TEXT     CHECK (asset_format IN ('IMAGE', 'SVG', 'LOTTIE', 'RIVE')),
  is_default      BOOLEAN  NOT NULL DEFAULT FALSE,
  is_active       BOOLEAN  NOT NULL DEFAULT TRUE,
  sort_order      INTEGER  NOT NULL,
  created_at      BIGINT   NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  updated_at      BIGINT   NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  -- FALSE takes the badge out of the catalogue (owner, 1 Oct 2026: "if it is
  -- false, then user will not see these assets in UI or UI store"): GET
  -- /api/levels leaves it out, so neither the store's Badges shelf nor the
  -- level screen's list of badges shows it. Unlike is_active it takes nothing
  -- away: a player who holds it keeps holding it — its rate, its mark on
  -- their picture, its card among their own badges, all read with the
  -- account — and a reward or a Play purchase made while it was listed still
  -- grants it. Last, where the guarded block below puts it on an older
  -- database.
  is_listed       BOOLEAN  NOT NULL DEFAULT TRUE
);

-- badges.is_listed for a database built before it (1 Oct 2026), guarded as
-- profile_pictures.is_listed is. TRUE: every badge already in the catalogue
-- stays in it.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = current_schema() AND table_name = 'badges' AND column_name = 'is_listed'
  ) THEN
    EXECUTE 'ALTER TABLE badges ADD COLUMN is_listed BOOLEAN NOT NULL DEFAULT TRUE';
  END IF;
END;
$$;

-- The badges each player has been given, one row a badge (a player may hold
-- several). Written by hand (V1.0.1's header has the statements) and by a
-- store purchase of a buyable badge (db.CreditBadgePurchase, which extends a
-- running grant by the badge's validity rather than restarting it).
-- expires_at is when the grant runs out, epoch ms (0: never): a grant that
-- leaves it out gets the badge's validity from granted_at
-- (user_badges_expiry, below), so granting a badge is one plain INSERT and
-- renewing it the same INSERT ON CONFLICT DO UPDATE. A grant past its
-- expires_at is kept — the record of it — and simply no longer held.
CREATE TABLE IF NOT EXISTS user_badges (
  user_id    TEXT   NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  badge_code TEXT   NOT NULL REFERENCES badges (code) ON DELETE CASCADE,
  granted_at BIGINT NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  expires_at BIGINT NOT NULL CHECK (expires_at >= 0),
  PRIMARY KEY (user_id, badge_code)
);

-- A grant that does not say when it ends lasts the badge's validity_days from
-- granted_at (0 days: for ever). NOT NULL is checked after BEFORE triggers,
-- so a statement that leaves expires_at out reaches this with NULL. The
-- function is replaced on every boot (a function takes no table lock); the
-- trigger is created only when missing, so a boot never queues behind a
-- reader of user_badges — every account read is one.
CREATE OR REPLACE FUNCTION user_badges_expiry() RETURNS trigger AS $$
BEGIN
  IF NEW.expires_at IS NULL THEN
    SELECT CASE WHEN b.validity_days = 0 THEN 0
                ELSE NEW.granted_at + b.validity_days::bigint * 86400000 END
      INTO NEW.expires_at
      FROM badges b
     WHERE b.code = NEW.badge_code;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE tgname = 'user_badges_expiry'
       AND tgrelid = 'user_badges'::regclass
  ) THEN
    CREATE TRIGGER user_badges_expiry
      BEFORE INSERT ON user_badges
      FOR EACH ROW EXECUTE FUNCTION user_badges_expiry();
  END IF;
END;
$$;

-- The badges bought in the store (owner, 27 Sep 2026: "Add a icon in Store to
-- buy badges"): the replay guard and the record of every Google Play purchase
-- of a buyable badge (badges.play_product_id). The Play purchase token IS the
-- primary key — db.CreditBadgePurchase inserts it ON CONFLICT DO NOTHING and
-- grants the badge only when the insert took, in the same transaction, so a
-- retry, a restore on a new install or the same token sent from another
-- account grants nothing a second time. Like diamond_purchases, never
-- chip_ledger's business: a badge is not chips. price_inr is the badge's
-- price when it was bought (badges.price_inr; Play holds what was actually
-- charged), and expires_at the end of the grant the purchase left — for
-- support, and for reconciling a Play payout report.
CREATE TABLE IF NOT EXISTS badge_purchases (
  purchase_token TEXT    PRIMARY KEY,
  user_id        TEXT    NOT NULL REFERENCES users (id),
  product_id     TEXT    NOT NULL,
  badge_code     TEXT    NOT NULL REFERENCES badges (code),
  price_inr      INTEGER CHECK (price_inr >= 0),
  expires_at     BIGINT  NOT NULL CHECK (expires_at >= 0),
  created_at     BIGINT  NOT NULL
);

-- A player's badge purchases, newest first, for support.
DO $$
BEGIN
  IF to_regclass(format('%I.%I', current_schema(), 'badge_purchases_user_idx')) IS NULL THEN
    CREATE INDEX IF NOT EXISTS badge_purchases_user_idx ON badge_purchases (user_id, created_at);
  END IF;
END;
$$;

-- One row per daily XP source. code is its name for the app and the claims;
-- name is the owner's label (the app names the kinds it knows in its own
-- languages); icon the emoji the owner gave it. kind says what earns it —
-- 'PLAY_TIME': play_minutes of active play in the window; 'WIN_HAND': a Teen
-- Patti or Variation hand won with hand_rank (HIGH_CARD, PAIR, COLOR,
-- SEQUENCE, PURE_SEQUENCE or TRAIL, as the table ranks it) — TEXT checked by
-- the server, so a future kind is a row and code, never a migration. xp is
-- what one earning gives; times_per_window how many times a window it can be
-- earned. Retire a source with is_active = FALSE — the seed would put a
-- deleted row back (inactive rows are left as they are).
--
-- mission_type (28 Sep 2026) says how often a source can be earned: DAILY,
-- times_per_window in each rolling window (every source before it, and the
-- DEFAULT, so an existing row reads exactly as it did), or ONE_TIME, ONCE in
-- a player's life (player_xp_missions, below). A CLOSED set — each value is a
-- different rule the server applies, not a label — so it is a CHECK, as
-- profile_pictures.type is. A ONE_TIME source is earned when a player's
-- progress reaches its target: kind 'HANDS_PLAYED' counts the hands they
-- play (a voluntary bet, requirement 16's "played") and 'HANDS_WON' the
-- hands they win, 'CATEGORIES_PLAYED' the different table categories they
-- have played a hand at and 'VARIATIONS_PLAYED' the different variations
-- (MUFLIS … FIVE_CARD) — each counting only the hands a player COMPLETES,
-- as the hand-end settle resolves them. scope narrows which hands count: NULL
-- any table; an engine code (teen_patti, poker) that engine's tables; a
-- category code (seen … omaha) that category's — by value, checked by the
-- server like kind, because the table catalogue it names is declared (and
-- seeded) after this table. target and scope mean nothing to a DAILY source,
-- which ignores them.
CREATE TABLE IF NOT EXISTS xp_sources (
  code             TEXT    PRIMARY KEY,
  name             TEXT    NOT NULL,
  icon             TEXT    NOT NULL DEFAULT '',
  kind             TEXT    NOT NULL,
  play_minutes     INTEGER CHECK (play_minutes > 0),
  hand_rank        TEXT,
  xp               INTEGER NOT NULL CHECK (xp >= 0),
  times_per_window INTEGER NOT NULL DEFAULT 1 CHECK (times_per_window >= 1),
  mission_type     TEXT    NOT NULL DEFAULT 'DAILY' CHECK (mission_type IN ('DAILY', 'ONE_TIME')),
  target           INTEGER CHECK (target >= 1),
  scope            TEXT,
  is_active        BOOLEAN NOT NULL,
  sort_order       INTEGER NOT NULL,
  created_at       BIGINT  NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  updated_at       BIGINT  NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint)
);

-- xp_sources.mission_type, .target and .scope for a database built before
-- them (28 Sep 2026: production's has the daily sources and none of the
-- three). Catalogue-guarded, as users.is_bot is: only a database missing a
-- column runs its ALTER, once, and a NOT NULL column with a constant DEFAULT
-- is stored in the catalogue rather than written into every row. The DEFAULT
-- is what keeps every existing source DAILY — the only kind there was.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = current_schema() AND table_name = 'xp_sources' AND column_name = 'mission_type'
  ) THEN
    EXECUTE 'ALTER TABLE xp_sources ADD COLUMN mission_type TEXT NOT NULL DEFAULT ''DAILY'' CHECK (mission_type IN (''DAILY'', ''ONE_TIME''))';
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = current_schema() AND table_name = 'xp_sources' AND column_name = 'target'
  ) THEN
    EXECUTE 'ALTER TABLE xp_sources ADD COLUMN target INTEGER CHECK (target >= 1)';
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = current_schema() AND table_name = 'xp_sources' AND column_name = 'scope'
  ) THEN
    EXECUTE 'ALTER TABLE xp_sources ADD COLUMN scope TEXT';
  END IF;
END;
$$;

-- The one row of XP rules that belong to no source. id is always 1 — the CHECK
-- makes a second row impossible. daily_cap is the most XP a player earns in one
-- window: NULL (as seeded) is no cap, 0 is none at all; window_ms how long a
-- window lasts from the award that opened it — a rolling 24 hours per player,
-- not a calendar day.
CREATE TABLE IF NOT EXISTS xp_settings (
  id         SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  daily_cap  INTEGER  CHECK (daily_cap >= 0),
  window_ms  BIGINT   NOT NULL CHECK (window_ms > 0),
  created_at BIGINT   NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  updated_at BIGINT   NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint)
);

-- One row per player who has completed a hand. Only db.awardXP writes it.
-- window_start is the epoch ms the current window opened (0: none yet);
-- window_xp what the player has earned in it, never more than a cap it was
-- earned under.
CREATE TABLE IF NOT EXISTS player_xp (
  user_id        TEXT     PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
  xp             BIGINT   NOT NULL DEFAULT 0 CHECK (xp >= 0),
  window_start   BIGINT   NOT NULL DEFAULT 0 CHECK (window_start >= 0),
  window_xp      INTEGER  NOT NULL DEFAULT 0 CHECK (window_xp >= 0),
  created_at     BIGINT   NOT NULL,
  updated_at     BIGINT   NOT NULL
);

-- How many times each player has earned each source in the window that
-- opened at window_start — a row from an earlier window counts as none. Only
-- db.awardXP writes it, under the player's player_xp row lock, so a source is
-- never earned more than its times_per_window in a window however many hands
-- end at once.
CREATE TABLE IF NOT EXISTS player_xp_claims (
  user_id      TEXT    NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  source_code  TEXT    NOT NULL REFERENCES xp_sources (code) ON DELETE CASCADE,
  window_start BIGINT  NOT NULL CHECK (window_start > 0),
  claims       INTEGER NOT NULL CHECK (claims >= 0),
  updated_at   BIGINT  NOT NULL,
  PRIMARY KEY (user_id, source_code)
);

-- Each player's ONE_TIME missions (28 Sep 2026: "One-time missions are
-- permanent missions that a player can complete only once … the completion
-- must persist in PostgreSQL"): one row per player per mission, created by
-- the first hand that moves it on and never deleted — no window, and nothing
-- that runs at a window's end, ever touches it. progress is how far the
-- player has come (hands, or the different games or variations in seen, which
-- progress counts); completed_at is 0 until the progress reaches the source's
-- target, and then the instant it did, for good; xp_awarded is the XP the
-- completion gave, the record of it (the lifetime XP it went into is
-- player_xp.xp). Only the hand-end settle writes it, under the player's
-- wallet lock, and only db.awardXP completes it:
--
--   UPDATE … SET completed_at = <now> WHERE … AND completed_at = 0 AND progress >= <target>
--
-- the statement that changes the row is the one that adds the XP, and a
-- second one — a replay, a concurrent settle, a retry — finds completed_at set
-- and adds nothing. The primary key is the one row per player and mission
-- that makes that single transition the only completion there can be; a row
-- completed stops moving (progress is frozen at its completion). No index
-- beyond it: every read is one player's, its leading column. Deleting a
-- source deletes its rows (the cascade) — retire one with is_active = FALSE
-- instead, which keeps who completed it.
CREATE TABLE IF NOT EXISTS player_xp_missions (
  user_id      TEXT    NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  source_code  TEXT    NOT NULL REFERENCES xp_sources (code) ON DELETE CASCADE,
  progress     INTEGER NOT NULL DEFAULT 0 CHECK (progress >= 0),
  seen         TEXT[]  NOT NULL DEFAULT '{}',
  completed_at BIGINT  NOT NULL DEFAULT 0 CHECK (completed_at >= 0),
  xp_awarded   INTEGER NOT NULL DEFAULT 0 CHECK (xp_awarded >= 0),
  created_at   BIGINT  NOT NULL,
  updated_at   BIGINT  NOT NULL,
  PRIMARY KEY (user_id, source_code),
  -- No XP without a completion.
  CHECK (completed_at > 0 OR xp_awarded = 0)
);


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
  -- Teen Patti only (owner, 26 Sep 2026): TRUE makes the table TAX ITS
  -- WINNERS — the winner of each hand pays a share of what they WON, the pot
  -- less their own contribution, at the rate they pay (their player level's,
  -- or a badge's, below) — on winnings of tax_min_winnings or more, and never
  -- on less (owner, 27 Sep 2026: "Apply this tax rule on all the tables,
  -- blind, seen, variation", then "tax will be on total pot amount - amount
  -- player contributed … 30 lakh is the limit on winning amount not on pot
  -- limit"). Seeded TRUE with 30,00,000 on every public Seen, Blind and
  -- Variation table; a private template's and a poker row's are read as
  -- FALSE. No DEFAULT here, like every rule column.
  winner_tax   BOOLEAN NOT NULL,
  tax_min_winnings  BIGINT  NOT NULL CHECK (tax_min_winnings >= 0),
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

-- ------------------------------------------------------------ app versions

-- The app version gate (owner, 28 Sep 2026: "the backend controls the minimum
-- supported app version … I should be able to change the minimum supported
-- Android/iOS version from the backend and immediately prevent older clients
-- from entering the game"; internal/appversion, db.AppVersions). One row per
-- app platform — android and ios, configured independently:
--
--   status           NORMAL, or MAINTENANCE: nobody on that platform may play,
--                    whatever their version (REST 503 maintenance, connect_error
--                    maintenance, the app's maintenance screen);
--   minimum_version  the oldest version allowed to play, MAJOR.MINOR.PATCH;
--                    below it is FORCE_UPDATE (REST 426 update_required,
--                    connect_error update_required, the app's update screen).
--                    '0.0.0' = no floor;
--   latest_version   the newest version announced; at or above the minimum and
--                    below this is SOFT_UPDATE (the app offers the update and
--                    may be told Later). '0.0.0' = none;
--   store_url        where the app's Update now goes; '' leaves the app to its
--                    own link;
--   message          shown with a force update or a maintenance; NULL = the
--                    app's own words.
--
-- CONFIGURATION, like the table catalogue — but read while the server runs:
-- the gate reads the rows through a cache of APP_VERSION_CACHE_MS (15 s), so
-- an operator's UPDATE is enforced within seconds, with no restart and no app
-- release (ops/DEPLOY.md, "The app version gate"). Nothing a hand does reads
-- or writes it, and it references nothing.
--
-- Versions are TEXT held to MAJOR.MINOR.PATCH by a CHECK, so a typo fails at
-- the UPDATE rather than locking every player out; the server compares them as
-- numbers, never as text (1.10.0 is newer than 1.9.0). platform is an OPEN set
-- (a lower-case word, not an enumeration): a platform this build does not know
-- is a row it never reads. updated_at follows every UPDATE by itself (the
-- trigger below), so the row says when it was last changed.
--
-- V1.0.1__seed.sql writes both rows with NO floor and nothing announced, and
-- ON CONFLICT DO NOTHING: deploying this changes nothing for anybody, and an
-- operator's UPDATE survives every restart.
CREATE TABLE IF NOT EXISTS app_versions (
  platform        TEXT PRIMARY KEY CHECK (platform ~ '^[a-z][a-z0-9_]{0,31}$'),
  status          TEXT NOT NULL DEFAULT 'NORMAL' CHECK (status IN ('NORMAL', 'MAINTENANCE')),
  minimum_version TEXT NOT NULL DEFAULT '0.0.0'
                  CHECK (minimum_version ~ '^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$'),
  latest_version  TEXT NOT NULL DEFAULT '0.0.0'
                  CHECK (latest_version ~ '^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$'),
  store_url       TEXT NOT NULL DEFAULT '' CHECK (length(store_url) <= 500),
  message         TEXT CHECK (message IS NULL OR length(message) <= 500),
  created_at      BIGINT NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  updated_at      BIGINT NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint)
);

-- Replaced on every boot (a function takes no table lock); the trigger is
-- created only when missing, so a boot never queues behind a reader.
CREATE OR REPLACE FUNCTION app_versions_touch() RETURNS trigger AS $$
BEGIN
  NEW.updated_at := (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::bigint;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE tgname = 'app_versions_touch'
       AND tgrelid = 'app_versions'::regclass
  ) THEN
    CREATE TRIGGER app_versions_touch
      BEFORE UPDATE ON app_versions
      FOR EACH ROW EXECUTE FUNCTION app_versions_touch();
  END IF;
END;
$$;

-- ------------------------------------------------------------ welcome rewards

-- What a NEW account is given (owner, 30 Sep 2026: "new account will get how
-- much coins, hammers, diamonds, profile_picture, emoji — this data should
-- come from database, user might get some or all rewards"; db.Welcome). One row
-- per reward; a new account gets every ACTIVE row, in sort_order, inside the
-- transaction that creates it, and an existing account's login gets nothing:
--
--   code           the row's name, lower case (the seed's conflict key):
--                  'chips', 'diamonds', 'hammers', 'missiles', or one of an
--                  owner's own ('welcome_picture' …);
--   reward_type    CHIPS, DIAMOND, HAMMER or MISSILE — reward_value of that
--                  wallet, rows of one kind adding up — or PROFILE_PICTURE,
--                  TABLE_PICTURE or EMOJI — reward_ref_id the catalogue row's
--                  id as text, which must be PREMIUM and active (a FREE one is
--                  everybody's already), owned from the account's first moment
--                  for the term the shop rents it for, and never worn or laid:
--                  that stays the player's choice.
--
-- reward_type is an OPEN set the server checks, never a CHECK or an ENUM, as
-- lucky_draw_slots.reward_type is: a later kind of welcome is a row and a
-- release, never a change to a constraint every database already carries. A
-- row the server cannot grant — a type it does not know, an amount missing or
-- 0, a picture or emoji that is missing, retired or free, a wallet it would
-- overflow — is left out with a logged reason (`welcome reward left out`) and
-- never refuses the login.
--
-- CONFIGURATION, read on every new account (no cache, no restart): an owner's
-- UPDATE applies to the very next account. Nothing references it and it
-- references nothing — reward_ref_id is text, as the Lucky Draw's is, so a
-- picture deleted from its catalogue leaves the row to be left out rather than
-- the DELETE refused.
--
-- The chips row is NOT in V1.0.1__seed.sql: the server writes it at boot from
-- WELCOME_CHIPS when there is no row coded 'chips' (db.Welcome.EnsureChipsRow;
-- app.New, never `gameplay -migrate`), so a deployment's first boot carries its
-- .env's welcome into the table, and from then on the row decides. The seed
-- holds the diamonds, hammers and missile the users column DEFAULTs gave until
-- 30 Sep 2026 (9, 20 and 1), so the deploy changed nothing a player sees. A
-- row is switched off with is_active = FALSE, never deleted: a seeded row —
-- and the chips row — comes back at the next boot. updated_at follows every
-- UPDATE by itself (the trigger below).
CREATE TABLE IF NOT EXISTS welcome_rewards (
  id            BIGSERIAL PRIMARY KEY,
  code          TEXT    NOT NULL UNIQUE CHECK (code ~ '^[a-z0-9_]{1,64}$'),
  reward_type   TEXT    NOT NULL,
  reward_value  BIGINT  CHECK (reward_value IS NULL OR reward_value >= 0),
  reward_ref_id TEXT,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  sort_order    INTEGER NOT NULL DEFAULT 0,
  created_at    BIGINT  NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  updated_at    BIGINT  NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint)
);

-- Replaced on every boot (a function takes no table lock); the trigger is
-- created only when missing, so a boot never queues behind a reader.
CREATE OR REPLACE FUNCTION welcome_rewards_touch() RETURNS trigger AS $$
BEGIN
  NEW.updated_at := (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::bigint;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE tgname = 'welcome_rewards_touch'
       AND tgrelid = 'welcome_rewards'::regclass
  ) THEN
    CREATE TRIGGER welcome_rewards_touch
      BEFORE UPDATE ON welcome_rewards
      FOR EACH ROW EXECUTE FUNCTION welcome_rewards_touch();
  END IF;
END;
$$;


-- ------------------------------------------------------------ reward programs

-- The reward programs (owner, 30 Sep 2026: "a unified REWARD PROGRAM system
-- that supports both LOGIN STREAK rewards and CALENDAR rewards, with WEEKLY
-- and MONTHLY periods"; db/rewardprograms.go). ONE generic model for every
-- program the lobby runs — the weekly and monthly login streaks, the weekly
-- and monthly calendars, and a one-off campaign such as a December calendar —
-- so a later program is rows here, never a table or a line of Go. Four
-- tables:
--
--   reward_programs         a program: its MODE (LOGIN_STREAK or CALENDAR),
--                           its PROGRESSION TYPE (RESET, SEQUENTIAL or
--                           BREAK), WEEKLY or MONTHLY, its timezone, the day
--                           its week starts, and an optional campaign window;
--   reward_program_rewards  what each day of a program gives;
--   user_reward_claims      every reward granted, for good: the audit, the
--                           run's memory and the replay guard;
--   user_reward_progress    where each player stands in a program's period
--                           (owner, 1 Oct 2026) — a row the first time they
--                           look at or claim the program in that period.
--
-- The first two are CONFIGURATION, as the Lucky Draw's are: read on every
-- claim and every look, so an owner's UPDATE is in force at the next one, no
-- restart. The third is APPEND-ONLY by use, as user_lucky_draws is. No game
-- state, and nothing on users: there is no user_login_streaks table and no
-- streak column. The standing is worked out from the claims of the current
-- period every time (db/rewardprogress.go, the one statement of the rules),
-- and the fourth table is what it came to, kept up to date by the server.
--
-- The MODE says what a claim's DAY NUMBER is (owner, 1 Oct 2026: "mode =
-- WHAT triggers progress, progression_type = HOW progress behaves"):
--
--   LOGIN_STREAK  the run's count — the first claim of a run is Day 1 (the
--                 brief's LOGIN; the name every installed app reads);
--   CALENDAR      the date's place in the period — Monday is Day 1 of a
--                 Monday week; every date from the first the program runs
--                 is REQUIRED.
--
-- The PROGRESSION TYPE says what a missed required day does:
--
--   RESET       the run starts again at Day 1 (a login streak: Mon Day 1,
--               Tue Day 2, Wed Day 3, Thu missed, Fri Day 1);
--   SEQUENTIAL  nothing is lost: the next unclaimed day waits (LOGIN), or
--               the missed date is missed and the calendar goes on
--               (CALENDAR — what "CALENDAR" meant from 30 Sep 2026);
--   BREAK       the cycle is BROKEN: nothing more can be claimed until the
--               next period starts fresh.
--
-- A PERIOD is a calendar week (starting on week_start_day) or a calendar
-- month, in the program's timezone, worked out by the server with calendar
-- arithmetic — never 7 × 86,400,000 ms: a month is 28 to 31 days and a week
-- may cross a daylight-saving change. There is no table of periods: a period
-- is the program's configuration, the instant and the zone, and the rows
-- that belong to one carry its first midnight, period_start_at.

-- One row per program. code is what a claim is recorded under and the seed's
-- conflict key; name the owner's label (the app names the four it knows in
-- its own languages). timezone is an IANA name (UTC, Asia/Kolkata …) and
-- decides today's date, the week and month boundaries and the claim date —
-- never the server's local zone; a zone this server cannot load leaves the
-- program out with a logged reason. week_start_day is 1 Monday … 7 Sunday
-- and is read by WEEKLY programs only. progression_type is RESET,
-- SEQUENTIAL or BREAK (above); reset_on_missed_day is what the builds before
-- it read — TRUE exactly for RESET on a LOGIN_STREAK program — kept so a
-- rollback finds what it expects, and the CHECK below keeps it FALSE on a
-- CALENDAR one. starts_at / ends_at (epoch ms, NULL for none) bound a
-- campaign — DECEMBER_2026 runs Dec 1 to Dec 31 — while a recurring program
-- leaves both NULL. Retire a program with is_active = FALSE, never DELETE:
-- its claims point at it.
CREATE TABLE IF NOT EXISTS reward_programs (
  id                  BIGSERIAL PRIMARY KEY,
  code                TEXT     NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9_]{1,64}$'),
  name                TEXT     NOT NULL,
  mode                TEXT     NOT NULL CHECK (mode IN ('LOGIN_STREAK', 'CALENDAR')),
  period_type         TEXT     NOT NULL CHECK (period_type IN ('WEEKLY', 'MONTHLY')),
  timezone            TEXT     NOT NULL DEFAULT 'UTC',
  week_start_day      SMALLINT NOT NULL DEFAULT 1 CHECK (week_start_day BETWEEN 1 AND 7),
  reset_on_missed_day BOOLEAN  NOT NULL DEFAULT FALSE,
  progression_type    TEXT     NOT NULL DEFAULT 'SEQUENTIAL' CHECK (progression_type IN ('RESET', 'SEQUENTIAL', 'BREAK')),
  starts_at           BIGINT   CHECK (starts_at IS NULL OR starts_at >= 0),
  ends_at             BIGINT   CHECK (ends_at IS NULL OR ends_at >= 0),
  is_active           BOOLEAN  NOT NULL DEFAULT TRUE,
  sort_order          INTEGER  NOT NULL DEFAULT 0,
  created_at          BIGINT   NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  updated_at          BIGINT   NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  -- A missed day resets a LOGIN STREAK and nothing else: a CALENDAR program
  -- cannot be made to behave like a streak.
  CONSTRAINT reward_programs_reset_is_a_streaks CHECK (mode = 'LOGIN_STREAK' OR reset_on_missed_day = FALSE),
  CONSTRAINT reward_programs_window_in_order CHECK (starts_at IS NULL OR ends_at IS NULL OR starts_at <= ends_at)
);

-- progression_type on a database built before it (owner, 1 Oct 2026) —
-- production's, where WEEKLY_LOGIN runs: added once, behind the catalogue,
-- and every program it finds given the progression it already had, in the
-- same statement — a streak that resets on a missed day RESET, every other
-- program SEQUENTIAL (the column's DEFAULT, which matches
-- reset_on_missed_day's FALSE). That fill runs only the boot that adds the
-- column, so it never rewrites a progression an owner has set since.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = current_schema() AND table_name = 'reward_programs' AND column_name = 'progression_type'
  ) THEN
    EXECUTE 'ALTER TABLE reward_programs ADD COLUMN progression_type TEXT NOT NULL DEFAULT ''SEQUENTIAL'' CHECK (progression_type IN (''RESET'', ''SEQUENTIAL'', ''BREAK''))';
    EXECUTE 'UPDATE reward_programs SET progression_type = ''RESET'' WHERE mode = ''LOGIN_STREAK'' AND reset_on_missed_day';
  END IF;
END;
$$;

-- One row per day of a program: day_number 1 to 7 for a WEEKLY program, 1 to
-- 31 for a MONTHLY one (a day past the period is never reached), read by the
-- program's mode (above). A REWARD IS reward_type + reward_value +
-- reward_ref_id, the Lucky Draw's and the welcome's shape: CHIPS, HAMMER,
-- DIAMOND and MISSILE carry an amount; EMOJI, PROFILE_PICTURE and
-- TABLE_PICTURE name a catalogue row by its id in reward_ref_id (TEXT), BADGE
-- a badge by its code (badges.code); NO_REWARD is a day that gives nothing
-- (the claim is still recorded, so a streak keeps counting through it). The
-- CHECK holds the SHAPE of every type this build grants — an amount and no
-- reference for a wallet, a reference and no amount for a catalogue item —
-- and lets any other type through, so the set stays OPEN as
-- lucky_draw_slots.reward_type is: a later kind is a row and a release,
-- never a change to a constraint every database already carries, and the
-- server leaves such a row out with a logged reason until a build grants it.
-- A day with no row, or a row it cannot grant (a retired picture, a missing
-- emoji), is a NO_REWARD day. Retire a row with is_active = FALSE.
CREATE TABLE IF NOT EXISTS reward_program_rewards (
  id            BIGSERIAL PRIMARY KEY,
  program_id    BIGINT   NOT NULL REFERENCES reward_programs (id) ON DELETE CASCADE,
  day_number    SMALLINT NOT NULL CHECK (day_number BETWEEN 1 AND 31),
  reward_type   TEXT     NOT NULL,
  reward_value  BIGINT   CHECK (reward_value IS NULL OR reward_value >= 0),
  reward_ref_id TEXT,
  is_active     BOOLEAN  NOT NULL DEFAULT TRUE,
  sort_order    INTEGER  NOT NULL DEFAULT 0,
  created_at    BIGINT   NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  updated_at    BIGINT   NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  UNIQUE (program_id, day_number),
  CONSTRAINT reward_program_rewards_shape CHECK (
       (reward_type IN ('CHIPS', 'HAMMER', 'DIAMOND', 'MISSILE')
          AND reward_value IS NOT NULL AND reward_value > 0 AND reward_ref_id IS NULL)
    OR (reward_type IN ('EMOJI', 'PROFILE_PICTURE', 'TABLE_PICTURE', 'BADGE')
          AND reward_value IS NULL AND reward_ref_id IS NOT NULL)
    OR (reward_type = 'NO_REWARD' AND reward_value IS NULL AND reward_ref_id IS NULL)
    OR reward_type NOT IN ('CHIPS', 'HAMMER', 'DIAMOND', 'MISSILE',
                           'EMOJI', 'PROFILE_PICTURE', 'TABLE_PICTURE', 'BADGE', 'NO_REWARD')
  )
);

-- One row per reward granted, never updated and never deleted: which program,
-- which period (period_start_at: the local midnight its first day began,
-- epoch ms), which day number the claim counted as, the claim's calendar date
-- in the program's timezone, and a SNAPSHOT of the reward as it stood — so
-- the record keeps saying what was given after Day 5 is pointed at another
-- emoji. A player's claims in a period, newest first, are the streak's
-- memory: the latest one says which day comes next, and none of it is kept
-- anywhere else. action_id is the claim's key,
-- "reward:<userId>:<programCode>:<claimDate>" (db.RewardClaimActionID) — one
-- per player, program and day by construction, so a claim is idempotent
-- without any key from the client; a CHIPS reward's chip_ledger row carries
-- the same key, and the ledger's own UNIQUE index guards it as well. The
-- unique index below is the same guarantee from the other side (one claim a
-- day a program), and the one read the store makes: this player's claims of
-- this program in this period, newest first — never a scan of the history.
-- program_id has no ON DELETE: a program that has been claimed cannot be
-- deleted, only retired, because the record points at it.
CREATE TABLE IF NOT EXISTS user_reward_claims (
  id              BIGSERIAL PRIMARY KEY,
  user_id         TEXT     NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  program_id      BIGINT   NOT NULL REFERENCES reward_programs (id),
  period_start_at BIGINT   NOT NULL,
  day_number      SMALLINT NOT NULL CHECK (day_number BETWEEN 1 AND 31),
  claim_date      DATE     NOT NULL,
  reward_type     TEXT     NOT NULL,
  reward_value    BIGINT   CHECK (reward_value IS NULL OR reward_value >= 0),
  reward_ref_id   TEXT,
  action_id       TEXT     NOT NULL UNIQUE,
  claimed_at      BIGINT   NOT NULL
);

-- One claim per player, program and calendar day, and the store's one read:
-- the latest claim of this program in this period.
DO $$
BEGIN
  IF to_regclass(format('%I.%I', current_schema(), 'user_reward_claims_period_idx')) IS NULL THEN
    CREATE UNIQUE INDEX IF NOT EXISTS user_reward_claims_period_idx
      ON user_reward_claims (user_id, program_id, period_start_at, claim_date DESC);
  END IF;
END;
$$;

-- One row per player, program and period they have touched (owner, 1 Oct
-- 2026): where the player stands in that period — current_day, the day the
-- player is to receive next (today's while it can be claimed, tomorrow's once
-- it is; while BROKEN the day that was missed; while COMPLETED the last
-- day), status ACTIVE, COMPLETED or BROKEN, and last_activity_at, the latest
-- claim's claimed_at (0 before the first). Created the first time the player
-- looks at or claims the program in the period — never one for every period
-- ahead — and kept up to date by the server in the same transaction as each
-- claim, and by a look that finds the standing changed (a BREAK program's
-- missed day turns its cycle BROKEN). The claims stay the record the
-- standing is worked out from: a row that ever disagreed would be put right
-- at the next look. A new period is a new row; the ones before it stay as
-- they ended. ON DELETE CASCADE on both keys: the row is a standing, not an
-- audit (the claims are the audit, and keep their program).
CREATE TABLE IF NOT EXISTS user_reward_progress (
  user_id          TEXT     NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  program_id       BIGINT   NOT NULL REFERENCES reward_programs (id) ON DELETE CASCADE,
  period_start_at  BIGINT   NOT NULL,
  current_day      INTEGER  NOT NULL DEFAULT 1 CHECK (current_day > 0),
  status           TEXT     NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'COMPLETED', 'BROKEN')),
  last_activity_at BIGINT   NOT NULL DEFAULT 0 CHECK (last_activity_at >= 0),
  created_at       BIGINT   NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  updated_at       BIGINT   NOT NULL DEFAULT ((EXTRACT(EPOCH FROM now()) * 1000)::bigint),
  PRIMARY KEY (user_id, program_id, period_start_at)
);

-- updated_at follows every UPDATE of the two configuration tables by itself.
-- Replaced on every boot (a function takes no table lock); each trigger is
-- created only when missing, so a boot never queues behind a reader.
CREATE OR REPLACE FUNCTION reward_programs_touch() RETURNS trigger AS $$
BEGIN
  NEW.updated_at := (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::bigint;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE tgname = 'reward_programs_touch'
       AND tgrelid = 'reward_programs'::regclass
  ) THEN
    CREATE TRIGGER reward_programs_touch
      BEFORE UPDATE ON reward_programs
      FOR EACH ROW EXECUTE FUNCTION reward_programs_touch();
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE tgname = 'reward_program_rewards_touch'
       AND tgrelid = 'reward_program_rewards'::regclass
  ) THEN
    CREATE TRIGGER reward_program_rewards_touch
      BEFORE UPDATE ON reward_program_rewards
      FOR EACH ROW EXECUTE FUNCTION reward_programs_touch();
  END IF;
END;
$$;
