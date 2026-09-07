-- King Teen Patti — SQLite schema.
-- Every table is created if missing, so this file is safe to run on every boot.

CREATE TABLE IF NOT EXISTS users (
  id                TEXT PRIMARY KEY,
  provider          TEXT NOT NULL CHECK (provider IN ('google', 'facebook', 'guest')),
  -- Provider-scoped identity: Google "sub", Facebook user id, or the device id for guests.
  provider_user_id  TEXT NOT NULL,
  display_name      TEXT NOT NULL,
  email             TEXT,
  avatar_url        TEXT,
  chips             INTEGER NOT NULL DEFAULT 0,
  -- A hand only counts as "played" once the player has made a voluntary bet;
  -- posting the boot and folding immediately does not count.
  hands_played      INTEGER NOT NULL DEFAULT 0,
  hands_won         INTEGER NOT NULL DEFAULT 0,
  hands_lost        INTEGER NOT NULL DEFAULT 0,
  -- Hands abandoned before they finished, tracked separately from losses.
  hands_left_mid    INTEGER NOT NULL DEFAULT 0,
  -- Gross chips taken in pots won, over the account's lifetime.
  total_winnings    INTEGER NOT NULL DEFAULT 0,
  biggest_pot       INTEGER NOT NULL DEFAULT 0,
  -- Highest "hands played" milestone already collected (a multiple of 25).
  milestone_claimed INTEGER NOT NULL DEFAULT 0,
  -- Epoch ms when the timed bonus may next be collected. 0 = collectable now.
  next_bonus_at     INTEGER NOT NULL DEFAULT 0,
  -- Picture chosen from the bundled profiles folder; overrides avatar_url.
  avatar_choice     TEXT,
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL,
  last_login_at     INTEGER NOT NULL,
  UNIQUE (provider, provider_user_id)
);

CREATE INDEX IF NOT EXISTS idx_users_last_login ON users (last_login_at DESC);

-- One row per completed hand, for auditing and dispute resolution.
CREATE TABLE IF NOT EXISTS hands (
  id           TEXT PRIMARY KEY,
  room_id      TEXT NOT NULL,
  hand_no      INTEGER NOT NULL,
  pot          INTEGER NOT NULL,
  winner_id    TEXT,
  win_reason   TEXT,
  boot_amount  INTEGER NOT NULL,
  started_at   INTEGER NOT NULL,
  ended_at     INTEGER NOT NULL,
  -- JSON array: every seat with its cards, contribution and final status.
  summary_json TEXT NOT NULL,
  FOREIGN KEY (winner_id) REFERENCES users (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_hands_room ON hands (room_id, hand_no);
CREATE INDEX IF NOT EXISTS idx_hands_ended ON hands (ended_at DESC);

-- Per-player ledger. Chip movements are only ever written through this table so
-- the users.chips balance can be reconciled against it.
CREATE TABLE IF NOT EXISTS chip_ledger (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id    TEXT NOT NULL,
  hand_id    TEXT,
  -- Negative for bets/antes, positive for pot winnings and grants.
  delta      INTEGER NOT NULL,
  balance    INTEGER NOT NULL,
  reason     TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_ledger_user ON chip_ledger (user_id, created_at DESC);
