-- King Teen Patti — marking an account as one of the resident bots (DDL).
--
-- Owner, 22 Sep 2026: "add one more column is_bot that will tell whether that
-- account is bot or not, so that when i run bot-play project, all bots will
-- have this flag marked as true, by default keep this flag value false".
--
-- The fleet in bot-play/ keeps production's lobby populated with ~243 guest
-- accounts, and until now nothing in the database said so. Every query about
-- real players — how many accounts, how much they hold, what the economy did
-- last week — has had to either count the bots in or guess at them from their
-- display names, which are deliberately indistinguishable from a person's
-- (bot-play/src/identities.js: that is the whole point of them). One boolean
-- settles it.
--
-- FALSE by default, so every existing row and every human signing in is a
-- person unless something says otherwise. The server sets it at login, from
-- the device id the guest provider was handed: the fleet's ids are namespaced
-- `botplay-…` (identityFor / rotatedIdentity), which is also what keeps them
-- from colliding with tools/bot.js and the ramp test's accounts. The prefix
-- is config.BotDevicePrefix, so it is a deployment decision rather than a
-- constant buried in the login path.
--
-- It is a LABEL, not a permission. Nothing in the game reads it: a bot is not
-- dealt differently, not matched differently, and not shown differently — the
-- flag never reaches a client, because a seat that announced itself as a bot
-- would tell a player exactly what the fleet exists not to tell them. Anything
-- that does start reading it has to answer for the fact that the value is
-- derived from a client-supplied device id, which a determined person could
-- send too. Mislabelling themselves as a bot is all that buys them today.
--
-- A NEW file, never an edit to an applied one (V1.0.0's header, CLAUDE.md
-- §7.3): the server keeps no schema history table and runs every script on
-- every boot, so each must be idempotent, and adding this to the baseline's
-- CREATE TABLE would do nothing for a database that already has `users`
-- (CREATE TABLE IF NOT EXISTS is a no-op there).
--
-- CATALOGUE-GUARDED, not `ADD COLUMN IF NOT EXISTS`: that form takes ACCESS
-- EXCLUSIVE on users even when the column is already there, so every restart
-- would queue behind any reader of the table — the crash loop of 9 Sep 2026
-- (TestABootSurvivesALongReaderHoldingTheTables). The lookup below takes no
-- lock a SELECT can block, and only a database missing the column runs the
-- ALTER, once. Through EXECUTE for the reason the baseline gives: PL/pgSQL
-- plans a statement before it evaluates the branch guarding it.
--
-- The ALTER itself is cheap on a table this size and would be on a far larger
-- one: since PostgreSQL 11 a NOT NULL column with a constant DEFAULT is stored
-- in the catalogue rather than written into every existing row, so no rewrite
-- happens here.
--
-- No index. Nothing at run time queries by it — this is for the analyst with a
-- psql prompt, who is scanning the table anyway.
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
