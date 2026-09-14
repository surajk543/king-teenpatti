-- King Teen Patti — PostgreSQL schema, baseline (DDL).
--
-- Every table, column, check, index, function and trigger the server needs, in
-- one file. Consolidated on 14 Sep 2026 (owner) for a production deploy onto an
-- EMPTY database: the structure that used to arrive over four scripts — this
-- baseline, V1.0.3__diamond_purchases.sql, V1.0.5__hammers.sql and, folded in the
-- same day for a second fresh deploy, V1.0.2__missiles.sql — is declared here,
-- and every row the server seeds is in V1.0.1__seed_profile_pictures.sql.
-- The blocks that brought an older database forward (the guarded hammer ALTER,
-- Butterfly Flapping's move to Drive) went with them; they are in git history
-- (ccff445 and earlier).
--
-- Flyway naming: V<version>__<description>.sql. Scripts are applied in
-- ascending version order, so the next change is a NEW file (V1.0.2__….sql)
-- rather than an edit to this one — once a script has run somewhere, editing it
-- is how two environments quietly stop matching.
--
-- EVERY SCRIPT MUST BE IDEMPOTENT, including this one. Flyway would keep a
-- schema history table and skip what it has already run, but this server has
-- no such table: it applies every script on every boot, so running twice must
-- be indistinguishable from running once. In practice that means
-- CREATE TABLE / INDEX IF NOT EXISTS, CREATE OR REPLACE FUNCTION,
-- INSERT … ON CONFLICT DO NOTHING, and a catalogue lookup before anything
-- that has no IF NOT EXISTS of its own (triggers, functions that must not be
-- replaced). Nothing here may fail, and nothing may duplicate, on a second
-- run.
--
-- Declared from scratch: every table is written once, in full, with its
-- columns, checks and foreign keys in place. There are no ALTER TABLE
-- statements and no migration blocks — the file describes the shape the
-- database should have, not the steps some older database takes to reach it.
--
-- FOR AN EMPTY DATABASE. `CREATE TABLE IF NOT EXISTS` does nothing when the
-- table is already there, so a column declared here will NOT appear on a
-- database that already has the table. A database built by the scripts of
-- go-server/v1.0.0 or older lacks users.missile (v1.3.0 or older, users.hammer
-- too), and booting this build against it fails the first time a player is
-- read; bringing such a database to this shape is a deliberate one-off step
-- run by hand, or a fresh start (ops/DEPLOY.md §8), never something a boot
-- does behind your back. A database built by master's three scripts at c8cd055
-- (the missiles as V1.0.2__missiles.sql) already has this shape, with missile
-- at the end of users, and boots unchanged.
--
-- THIS FILE IS DDL ONLY — tables, constraints, indexes, functions, triggers.
-- Data lives in its own script (V1.0.1__seed_profile_pictures.sql). Keeping
-- them apart is what lets the shape of the database be reviewed, diffed and
-- re-applied without arguing about rows, and lets a row be corrected without
-- reopening a structural migration.
--
-- Order matters: `profile_pictures` is created before `users` because
-- `users.active_picture_id` references it, and `user_profile_pictures`,
-- `chip_ledger` and the purchase and spend tables come after both for the same
-- reason.
--
-- Timestamps are epoch milliseconds (BIGINT) to match the Date.now() values
-- the server works in everywhere else — never TIMESTAMPTZ. One column in a
-- different unit is a trap for whoever writes the next query.
--
-- PostgreSQL holds MONEY, AUDIT AND ACCOUNTS ONLY. There is no game state
-- here at all — not the table, not the hand, not the pot, and no per-hand
-- record. ALL game state lives in the live store (Redis) and nowhere else
-- (owner's decision of 9 Sep 2026, LIVE_STATE_PLAN.md). If the live store is
-- lost the hand never happened: the players re-join and whatever PostgreSQL
-- holds is their balance. `game_states`, `pots` and `hands` are retired and
-- are not created here; a database that still carries them is a database
-- somebody restored from an old backup, and dropping them is a human's call.


-- ---------------------------------------------------------------- pictures

-- The profile-picture catalogue (requirements 20 and 21). One row per picture
-- the game offers: a FREE row is worn by anyone, a PREMIUM row costs chips or
-- diamonds a player has to spend before they may wear it.
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
  -- still reconciles after a purchase.
  cost       BIGINT  NOT NULL DEFAULT 0 CHECK (cost >= 0),
  -- Which wallet cost is paid from: COIN (chips, the default) or DIAMOND
  -- (users.diamond). Meaningless on a FREE row — nothing is charged — and
  -- the default keeps hand-inserted rows on the chips path.
  currency   TEXT    NOT NULL DEFAULT 'COIN'
             CHECK (currency IN ('COIN', 'DIAMOND')),
  -- How long a purchase of this picture lasts, in DAYS. 0 means for ever,
  -- which is what every free picture is and what a premium one is until
  -- somebody prices it as a rental.
  --
  -- Days, not the milliseconds every other duration in this server is measured
  -- in, and deliberately: this is a catalogue column an owner edits by hand,
  -- and `duration_days = 30` cannot be misread the way `duration_ms = 30`
  -- silently can. The server converts once, on purchase.
  --
  -- Changing it re-prices the SHELF, never a rental already sold: the expiry
  -- is stamped onto the ownership row at the moment of purchase, so a player
  -- keeps the terms they bought under.
  duration_days INTEGER NOT NULL DEFAULT 0 CHECK (duration_days >= 0),
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
  -- Premium soft currency. Starts at 2 (owner, 14 Sep 2026; it was 1) so a
  -- fresh account can taste the diamond shelf. NOT chip_ledger's business: the
  -- ledger backs the chips invariant (SUM(delta) == chips), and diamonds are
  -- not chips.
  diamond           INTEGER NOT NULL DEFAULT 2 CHECK (diamond >= 0),
  -- The currency a Force Sideshow is paid in, one hammer each (owner, 13 Sep
  -- 2026). Every account starts with 20, and more are sold on Google Play in
  -- packs (internal/purchase/catalogue.go). Like diamonds, never chip_ledger's
  -- business: hammer_purchases and hammer_spends below are its receipts.
  hammer            INTEGER NOT NULL DEFAULT 20 CHECK (hammer >= 0),
  -- What a missile costs, one each (owner, 14 Sep 2026): every account starts
  -- with 1, and more are traded for diamonds at 5 diamonds a missile (POST
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
  -- Highest "hands played" milestone already collected (a multiple of 25).
  milestone_claimed INTEGER NOT NULL DEFAULT 0,
  -- Epoch ms when the timed bonus may next be collected. 0 = collectable now.
  next_bonus_at     BIGINT NOT NULL DEFAULT 0,
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
  UNIQUE (provider, provider_user_id)
);

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
  -- picture's duration_days at the moment of purchase, so re-pricing the shelf
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
  created_at BIGINT NOT NULL
);

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
