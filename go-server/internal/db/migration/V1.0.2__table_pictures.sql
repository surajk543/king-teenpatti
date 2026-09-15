-- King Teen Patti — table pictures (DDL).
--
-- The picture a player lays on their table (owner, 15 Sep 2026): the ground of
-- the felt, under the seats, the pot and the cards, seen by that player alone.
-- It is the profile-picture catalogue again, for the table rather than the
-- face — a FREE row anyone may lay, a PREMIUM row bought with chips, diamonds
-- or hammers and, when priced as a rental, kept for its term — with one
-- difference the table forces: TWO pictures per row. The app draws its table
-- on a pale ground by day and a dark one by night, and writes on it in ink
-- that follows the theme, so one picture cannot serve both: a dark cloth under
-- dark day ink loses every word on the table. day_asset_url is drawn in the
-- light theme and night_asset_url in the dark one, and the client switches
-- between them with the theme.
--
-- A NEW script rather than an edit to V1.0.0__baseline.sql: production has run
-- the baseline (go-server/v1.1.0 onwards), and a script that has run somewhere
-- is never edited (the baseline's header). Everything here is CREATE TABLE IF
-- NOT EXISTS, so it is idempotent as every script must be — the server runs
-- them all on every boot — and it touches nothing that exists: no ALTER, no
-- column on users, so it boots as gameplay_app whether or not ops/DEPLOY.md §7
-- has handed users to the postgres superuser. That is why the picture a player
-- has laid is a row in user_table_choice below rather than a users column like
-- active_picture_id: a column would be an ALTER TABLE users, which under §7
-- needs a one-off run as postgres before every deploy that carries it. A table
-- with a foreign key to users needs only REFERENCES, which §7 grants.
--
-- Order matters within the file as it does in the baseline: table_pictures
-- first, because the two tables after it reference it.


-- ---------------------------------------------------------- the catalogue

-- One row per table picture on offer. The columns are profile_pictures' — see
-- the baseline for what each means — with asset_url split in two.
--
-- day_asset_url is UNIQUE because it is the natural key the seed matches on
-- (V1.0.3__seed_table_pictures.sql, ON CONFLICT DO NOTHING). night_asset_url
-- is not: two rows may share a night picture, and a row may serve the same
-- picture by day and by night when its art reads on either ground. Both are
-- whatever a client can LOAD — the seed's are server-relative paths into
-- PUBLIC_DIR ("/tables/classic-baize-day.svg"), which production serves from
-- its public directory as it serves /profiles/ (CLAUDE.md §9); a hosted URL
-- works just as well. One asset_format for both: a pair is drawn by one
-- loader.
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
  CONSTRAINT free_table_picture_cost_check CHECK (
    (type = 'FREE'    AND cost =  0) OR
    (type = 'PREMIUM' AND cost >  0)
  )
);


-- --------------------------------------------------------------- ownership

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

CREATE INDEX IF NOT EXISTS idx_owned_table_pictures_expiry
  ON user_table_pictures (expires_at) WHERE expires_at > 0;


-- -------------------------------------------------------------- the choice

-- The table picture each player has laid: one row per player, or none for
-- the table as it comes. This is users.active_picture_id for the table,
-- moved off users for the reason the header gives. ON DELETE CASCADE on the
-- picture, so removing a catalogue row clears the tables it was laid on
-- rather than failing, as active_picture_id's ON DELETE SET NULL does.
CREATE TABLE IF NOT EXISTS user_table_choice (
  user_id          TEXT   PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
  table_picture_id BIGINT NOT NULL REFERENCES table_pictures (id) ON DELETE CASCADE,
  chosen_at        BIGINT NOT NULL
);
