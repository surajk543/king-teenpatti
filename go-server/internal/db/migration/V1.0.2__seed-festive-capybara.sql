-- King Teen Patti — rows added after the two founding scripts (DML).
--
-- A third script, holding ROWS only (owner, 28 Sep 2026: "Create new file
-- V1.0.2__seed.sql and ADD a insert idempotent profile_pictures"; renamed the
-- same day, before any database had run it — "change seed file name
-- seed-festive-capybara" — and a rename changes nothing for a database that
-- has, since no schema history table records a script's name). The server
-- applies every script on every boot in version order — V1.0.0__baseline.sql,
-- which builds every table, then V1.0.1__seed.sql, then this — so anything a
-- row here needs of the structure already exists when it runs. It creates,
-- alters and indexes nothing (TestMigrationsAreVersionedOrderedAndSplitByKind):
-- a change of STRUCTURE still goes into the baseline, never into a later
-- script, because a later script runs after the seeds (the baseline's header).
--
-- Idempotent, like every script here: there is no schema history table, so
-- every INSERT names its table's natural key in ON CONFLICT … DO NOTHING. A row
-- appended here reaches every database — production included — at its next
-- boot, and a row a database already has is never rewritten: re-pricing,
-- renaming or retiring one is an UPDATE (`UPDATE profile_pictures SET cost = …
-- WHERE name = …`), which the next boot leaves alone.


-- ================================================================ THE PICTURES
--
--   Festive Capybara  350×350, 3.2 s, Lottie 5.12.1   1 HAMMER   3 days   sort_order 358
--
-- Festive Capybara (owner, 28 Sep 2026: "Hammer 1 PREMIUM LOTTIE", "validity 3
-- day") is named as uploaded ("Festive Capybara.json", 228 KB, 25 fps, 81
-- frames). Priced in hammers, so it sells at a table as well as in the lobby
-- (CLAUDE.md §7.2). It has no 3D layers, no text and no embedded images. Its
-- five "Kleaner" expressions lay anticipation and follow-through over keyframed
-- transforms; the phone players run no expressions and play those keyframes
-- without the overshoot — the Sporty Avocado case in V1.0.1__seed.sql, served
-- as the original for the same reason (CLAUDE.md §12.3). sort_order 358 files
-- it after Cockroach (356), the last of the hammer pictures and before the
-- first diamond one (360), so the catalogue still runs free → chips → hammers →
-- diamonds.
--
-- Served from Drive's direct-download form, as every picture that is not a
-- bitmap is (V1.0.1__seed.sql's note on Google Drive): the /file/d/<id>/view
-- link the owner shares is an HTML page, and a phone handed one draws nothing.

INSERT INTO profile_pictures (name, asset_url, asset_format, currency, type, cost, duration_days, duration_hours, is_active, sort_order, created_at, updated_at)
SELECT name, asset_url, asset_format, currency, type, cost, duration_days, duration_hours, is_active, sort_order,
       (EXTRACT(EPOCH FROM now()) * 1000)::bigint,
       (EXTRACT(EPOCH FROM now()) * 1000)::bigint
  FROM (VALUES
    ('Festive Capybara',   'https://a91cb23b3b93a35dd9ea50db7b855e18.r2.cloudflarestorage.com/king-teenpatti/profile_pictures/festive-capybara.json',
     'LOTTIE', 'HAMMER', 'PREMIUM', 1::bigint, 3, 0, TRUE, 358)
  ) AS seed(name, asset_url, asset_format, currency, type, cost, duration_days, duration_hours, is_active, sort_order)
    ON CONFLICT (asset_url) DO NOTHING;
