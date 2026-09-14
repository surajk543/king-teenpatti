-- King Teen Patti — missiles (DDL). Owner, 14 Sep 2026.
--
-- A missile, fired by the player on turn with at least three players still in
-- the hand, shows every hand and pays the best one (game.ActionMissile). It is
-- bought with diamonds at 2 missiles a diamond (POST /api/store/missiles), and
-- every account created from now on starts with 2 diamonds and 1 missile.
--
-- A NEW FILE, not an edit to the baseline: production has already run
-- V1.0.0 and V1.0.1, and a script that has run somewhere is never edited. It
-- runs on EVERY boot, like every script here, so each statement is idempotent
-- and each ALTER sits behind a catalogue lookup — a boot with nothing to do
-- issues no ALTER at all.
--
-- The lookups matter beyond tidiness. PostgreSQL checks that the caller owns
-- users before it looks at anything else, so once users is handed to the
-- postgres superuser (ops/DEPLOY.md §7) a bare `ALTER TABLE users …` fails on
-- every boot as gameplay_app even when the column is already there. Behind the
-- lookup a fresh database runs the ALTERs, and a handed-over one whose ALTERs
-- were run once as postgres before the deploy skips them
-- (TestTheAppRoleBootsTwiceBeforeAndAfterUsersIsHandedToTheSuperuser).
--
-- Neither table touches chip_ledger: missiles and diamonds are not chips, and
-- chip_ledger backs `SUM(delta) == users.chips` and nothing else.


-- ------------------------------------------------------------------- users

DO $$
BEGIN
  -- The wallet. Added at DEFAULT 0, so every account that exists when this
  -- first runs holds no missiles: the grant is for new accounts, not a
  -- handout. The CHECK is the last line against going below zero.
  IF NOT EXISTS (
    SELECT 1 FROM pg_attribute
     WHERE attrelid = 'users'::regclass
       AND attname = 'missile'
       AND NOT attisdropped
  ) THEN
    ALTER TABLE users ADD COLUMN missile INTEGER NOT NULL DEFAULT 0 CHECK (missile >= 0);
  END IF;

  -- …and from then on a new account starts with one. SET DEFAULT changes only
  -- what later INSERTs get; the rows above keep their 0.
  IF NOT EXISTS (
    SELECT 1 FROM pg_attrdef d
      JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
     WHERE d.adrelid = 'users'::regclass
       AND a.attname = 'missile'
       AND pg_get_expr(d.adbin, d.adrelid) = '1'
  ) THEN
    ALTER TABLE users ALTER COLUMN missile SET DEFAULT 1;
  END IF;

  -- A new account starts with 2 diamonds (it was 1). Existing balances are
  -- not touched.
  IF NOT EXISTS (
    SELECT 1 FROM pg_attrdef d
      JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
     WHERE d.adrelid = 'users'::regclass
       AND a.attname = 'diamond'
       AND pg_get_expr(d.adbin, d.adrelid) = '2'
  ) THEN
    ALTER TABLE users ALTER COLUMN diamond SET DEFAULT 2;
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
