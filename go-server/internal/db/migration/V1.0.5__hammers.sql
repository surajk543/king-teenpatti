-- King Teen Patti — hammers, the currency a Force Sideshow is paid in (DDL).
--
-- Added 13 Sep 2026 (owner): a Force Sideshow compares hands with the player on
-- your right without asking them, and costs one hammer. Every account holds 20
-- — new accounts and existing ones alike, the owner's decision — and more are
-- sold on Google Play in packs of 20, 50, 100 and 250
-- (internal/purchase/catalogue.go).
--
-- EVERY SCRIPT RUNS ON EVERY BOOT (V1.0.0's header), so everything below must
-- be a no-op the second time.
--
-- ------------------------------------------------------------------ the column
--
-- Why an ALTER, and why here. users.hammer has to exist on a fresh database and
-- on the production one that already holds every account. The baseline cannot
-- give it to either: `CREATE TABLE IF NOT EXISTS users` does nothing where users
-- is already there, and adding the column to the baseline's CREATE TABLE would
-- be an edit changing what an applied script creates — V1.0.0's header sanctions
-- one exception, a guard that only skips work already done, and says in as many
-- words that it is not a precedent for that. So the column is added by this
-- script, on fresh and existing databases alike, and V1.0.0 is untouched.
--
-- The DEFAULT is what gives every existing row its 20 hammers. PostgreSQL 11 and
-- later store a constant default in the catalogue rather than rewriting the
-- table, so on a large users table this is a brief lock, not a rewrite.
--
-- Why behind a catalogue lookup. PostgreSQL checks that the caller OWNS a table
-- before it looks at IF NOT EXISTS, so a bare `ALTER TABLE users ADD COLUMN IF
-- NOT EXISTS` fails on every boot once ops/DEPLOY.md §7 has handed users to the
-- postgres superuser — even with the column long in place. The lookup skips it
-- wherever the column exists, the pattern the baseline uses for
-- idx_users_last_login and users_no_delete. On a database already handed over
-- the column must therefore be added once as postgres BEFORE this release
-- boots; DEPLOY.md §7 carries that statement, and
-- TestTheAppRoleBootsTwiceBeforeAndAfterUsersIsHandedToTheSuperuser runs it.
--
-- Hammers are not chips, and never chip_ledger's business: the ledger backs the
-- `SUM(delta) == users.chips` invariant and nothing else. The two tables below
-- are the hammers' receipts instead.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_attribute
     WHERE attrelid = 'users'::regclass
       AND attname = 'hammer'
       AND NOT attisdropped
  ) THEN
    ALTER TABLE users ADD COLUMN IF NOT EXISTS hammer INTEGER NOT NULL DEFAULT 20 CHECK (hammer >= 0);
  END IF;
END;
$$;

-- --------------------------------------------------------------- purchases
--
-- One row per Play hammer pack banked, keyed on the purchase token: the replay
-- guard (db.CreditHammerPurchase inserts ON CONFLICT DO NOTHING and adds the
-- hammers only when the insert took) and the record of what was bought. The
-- twin of diamond_purchases (V1.0.3), for the same reason — a pack that never
-- enters chip_ledger needs its double-credit guard somewhere else.
CREATE TABLE IF NOT EXISTS hammer_purchases (
  purchase_token TEXT    PRIMARY KEY,
  user_id        TEXT    NOT NULL REFERENCES users (id),
  product_id     TEXT    NOT NULL,
  hammers        INTEGER NOT NULL CHECK (hammers > 0),
  created_at     BIGINT  NOT NULL
);

CREATE INDEX IF NOT EXISTS hammer_purchases_user_idx ON hammer_purchases (user_id, created_at);

-- ------------------------------------------------------------------ spends
--
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
