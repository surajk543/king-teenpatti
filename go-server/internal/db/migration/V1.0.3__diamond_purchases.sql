-- King Teen Patti — diamond pack purchases (DDL).
--
-- Added 13 Sep 2026 (owner): diamonds can be bought on Google Play in packs of
-- 1, 5, 20 and 100 (internal/purchase/catalogue.go). A new table in a new
-- script, never an edit to the applied baseline; `CREATE … IF NOT EXISTS` keeps
-- it idempotent, since every script runs on every boot.
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
