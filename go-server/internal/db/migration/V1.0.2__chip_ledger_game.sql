-- King Teen Patti — which GAME a ledger row was written by (DDL).
--
-- The Poker family (owner, 19 Sep 2026; go-server/POKER_PLAN.md §6) settles
-- through the same three checkpoints Teen Patti does — hand_packed on a fold,
-- hand_left on a departure, hand_win / hand_loss at the hand end — and writes
-- the same chip_ledger rows, so the wallet invariant (SUM(delta) = chips) and
-- the purge need nothing new. What the audit DID need was to tell a poker hand
-- from a Teen Patti one: a 3-Card Poker hand is played against the house,
-- which has no wallet, so its rows do not sum to zero per hand the way every
-- player-versus-player hand's do (tools/parity/money.test.js).
--
-- Two nullable columns, and nothing else: `game` is the family
-- ('poker'; NULL for every Teen Patti row, which are therefore byte for byte
-- what they were) and `variant` the poker variant ('three_card_poker',
-- 'five_card_draw', 'texas_holdem', 'omaha'; NULL otherwise). The brief's
-- round_id is the existing hand_id and its hand_result the existing reason.
--
-- This is the first script since the pair production was built from, so it is
-- written the way every later change must be: a NEW file, never an edit to an
-- applied one (V1.0.0's header), and idempotent — the server has no schema
-- history table and runs every script on every boot. The baseline itself stays
-- as it is: it declares every table in full for a FRESH database and needs no
-- ALTER, and adding these two columns to its CREATE TABLE would do nothing for
-- a database that already has the table (CREATE TABLE IF NOT EXISTS is a no-op
-- there) — which is exactly why this is a separate script.
--
-- CATALOGUE-GUARDED, not `ADD COLUMN IF NOT EXISTS`: that form takes ACCESS
-- EXCLUSIVE on chip_ledger even when the column is already there, so every
-- restart would queue behind any reader of the table — the crash loop of
-- 9 Sep 2026 (TestABootSurvivesALongReaderHoldingTheTables). The lookup below
-- takes no lock a SELECT can block; only a database that lacks the column runs
-- the ALTER, once. Through EXECUTE for the reason the baseline gives: PL/pgSQL
-- plans before it evaluates.
--
-- No index: the audit reads these columns in a full scan it makes anyway, and
-- nothing at run time queries by them (CLAUDE.md §7.3 on idx_ledger_purge).
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
