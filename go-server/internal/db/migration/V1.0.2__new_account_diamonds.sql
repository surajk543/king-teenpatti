-- King Teen Patti — nine diamonds for every new account (DDL). Owner, 14 Sep 2026.
--
-- Every account created from now on starts with 9 diamonds (it was 2); an
-- account that already exists keeps what it holds. With the 20 hammers and 1
-- missile the baseline already gives, and the 3 lakh WELCOME_CHIPS, that is the
-- whole welcome. (Production's go-server/.env sets WELCOME_CHIPS explicitly, so
-- the chips change there, not here.)
--
-- A NEW FILE, not an edit to V1.0.0__baseline.sql: production has already run
-- the baseline, and a script that has run somewhere is never edited. Like every
-- script here it runs on EVERY boot, so its ALTER sits behind a catalogue
-- lookup: a boot with nothing to do issues no ALTER at all, which is also what
-- lets the app role boot once users belongs to the postgres superuser
-- (ops/DEPLOY.md §7).

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_attrdef d
      JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
     WHERE d.adrelid = 'users'::regclass
       AND a.attname = 'diamond'
       AND pg_get_expr(d.adbin, d.adrelid) = '9'
  ) THEN
    ALTER TABLE users ALTER COLUMN diamond SET DEFAULT 9;
  END IF;
END;
$$;
