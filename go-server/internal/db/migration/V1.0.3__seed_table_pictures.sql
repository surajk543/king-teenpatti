-- King Teen Patti — the table-picture catalogue (DML).
--
-- Every table picture the server seeds (owner, 15 Sep 2026), for the tables
-- V1.0.2__table_pictures.sql builds. Data apart from structure, as the profile
-- pictures are (V1.0.1's header): a price or a new table is a row here, never a
-- change to the DDL.
--
-- Idempotent like every script: ON CONFLICT on the natural key (day_asset_url)
-- DO NOTHING, so a boot adds the rows a database lacks and never rewrites one
-- the owner has since re-priced, renamed, reordered or retired. Editing a row a
-- database already has is an UPDATE run there, not a code change; a new
-- picture appended here reaches every database at its next boot.
--
-- THE PICTURES are the owner's own, hosted on Google Drive as the animated
-- profile pictures are (V1.0.1's header says how a Drive link becomes a URL a
-- client can load: the /file/d/<id>/view link is an HTML page, not the file).
-- Each row is one picture in two files: the DAY file is drawn on the light
-- theme, whose ink on the table is dark, and the NIGHT file on the dark theme,
-- whose ink is light — a picture's art must read on its own ground or the
-- words on the table (the pot, "waiting", a seat's bet) go with it. Every
-- premium table is a RENTAL, as every premium profile picture is; a
-- chip-priced one sells in the lobby only (CLAUDE.md §5.1), a hammer or
-- diamond one at a table too. The table as it comes — no picture — is always
-- there, so no free row is needed for a first launch.
--
-- Eight SVG designs, a day and a night file each, were drawn for this shelf by
-- tools/tables/make_table_pictures.py into public/tables/ (served like
-- profiles/) and seeded here on 15 Sep 2026; the owner took their rows out the
-- same day, keeping the catalogue to their own art. The files and the script
-- remain, and a row for any of them is the shape of the ones below with
-- '/tables/<slug>-day.svg' and '/tables/<slug>-night.svg' as its two URLs.
--
--   Lines Background    10,000 chips  7 days  sort_order 75  LOTTIE, on Drive
--   Background Pattern  5 lakh chips  7 days  sort_order 80  LOTTIE, on Drive
--   Welcome             1 lakh chips  2 days  sort_order 85  LOTTIE, on Drive
--   Thank You           10 lakh chips 10 days sort_order 90  LOTTIE, on Drive
--
-- LINES BACKGROUND (owner, 15 Sep 2026) is a Lottie of 23 layers of black
-- lines moving over a transparent 1500×1500 canvas (Lottie 5.12.1, 60 fps,
-- 2 s), uploaded to Drive as "Lines Background". No 3D layers and no
-- expressions, so the phones play it as lottie-web does (CLAUDE.md §12.3).
-- Black lines all but vanish on the dark theme's ground, so the NIGHT file is
-- a copy with the lines in white — "Lines Background Night.json" in the
-- owner's table_pictures folder on Drive, made from the day file: the 22
-- strokes recoloured, editor metadata dropped, and each layer's 120 per-frame
-- trim-offset keyframes re-encoded as the same curve sampled adaptively within
-- 1° (a hold across the 360→0 wrap), 30 KB against 101. The day file stays
-- the owner's original. Seeded at 10 hammers for 30 days and re-priced by the
-- owner in chips the next day (10,000 for 7 days) — which a database that ran
-- the seed in between keeps as an UPDATE, the row being matched on
-- day_asset_url:
--
--   UPDATE table_pictures SET currency = 'COIN', cost = 10000, duration_days = 7
--    WHERE name = 'Lines Background';
--
-- BACKGROUND PATTERN (owner, 16 Sep 2026) is a Lottie of 96 rounded tiles in
-- two blues that pop in one after another over four seconds on a transparent
-- 1500×1000 canvas, hold, and shrink away together before the loop (Lottie
-- 5.5.3, 25 fps, 6 s). The owner's export — 122 KB, 96 shape layers each
-- carrying its own copy of the same path and keyframes — is kept as
-- tools/tables/background-pattern.json, and both Drive files are made from it
-- by tools/tables/make_background_pattern.py: the pop-in written once per
-- colour as a precomp, each tile an instance started at its own frame, 31 KB
-- each, checked keyframe for keyframe against the export ("Background
-- Pattern.json" and "Background Pattern Night.json", same Drive folder). The
-- NIGHT file swaps the pale blue (#E3F2FD, a tint that all but vanishes on the
-- light ground) for a navy tint (#1B2F42) that sits on the dark ground the same
-- way; the mid blue (#64B5F6) reads on both and stays.
--
-- WELCOME (owner, 16 Sep 2026) is a Lottie of one word, "welcome", written on
-- in a rainbow gradient stroke — teal through yellow, orange, pink and violet
-- to blue, 9 px wide, a trim path over 7.6 s (Lottie 4.8.0, 60 fps, 8.2 s) —
-- on a transparent 428×123 banner canvas, the owner's own upload
-- ("Welcome.json", public). No 3D, no expressions. A rainbow reads on both
-- grounds, so its NIGHT file IS its day file: night_asset_url is not the
-- unique key and may repeat it. The felt fits a banner-shaped canvas whole
-- (pictureFitFor, 16 Sep 2026: wider than 1.6:1 or taller than 1:1.6 is
-- contained, a squarer canvas covers the square), so the word lies across the
-- pot's width rather than showing two letters of its middle.
--
-- THANK YOU (owner, 16 Sep 2026) is a Lottie of the words "Thank You" in gold
-- (#FCC700) with 35 gold shapes animating around them on a transparent
-- 1080×1080 canvas (Lottie 5.11.0, 30 fps, 10 s), the owner's own upload
-- ("Thank You.json", public, 728 KB). No 3D, no expressions; its text layer
-- carries its nine glyphs as shapes (`chars`), so the phones need no font.
-- Gold reads on both grounds, so its NIGHT file is its day file too.

INSERT INTO table_pictures (name, day_asset_url, night_asset_url, asset_format, currency, type, cost, duration_days, duration_hours, is_active, sort_order, created_at, updated_at)
SELECT name, day_asset_url, night_asset_url, asset_format, currency, type, cost, duration_days, duration_hours, is_active, sort_order,
       (EXTRACT(EPOCH FROM now()) * 1000)::bigint,
       (EXTRACT(EPOCH FROM now()) * 1000)::bigint
  FROM (VALUES
    ('Lines Background',
     'https://drive.google.com/uc?export=download&id=1r26ntLyDxKVbu7NAcsAQ3P3Sh8qF-oN-',
     'https://drive.google.com/uc?export=download&id=1mBnzYABRNRvP7aaEOk2JrBdQC7Lw--fB',
     'LOTTIE', 'COIN', 'PREMIUM', 100000::bigint,  7, 0, TRUE, 75),
    ('Background Pattern',
     'https://drive.google.com/uc?export=download&id=1SZ9uuV6AuJB5vYqjMmbRq0Qi7ILr7O3_',
     'https://drive.google.com/uc?export=download&id=1jysl9afLqlbeIO1SS8ypASb1TQkUFl2C',
     'LOTTIE', 'COIN', 'PREMIUM', 500000::bigint, 7, 0, TRUE, 80),
    ('Welcome',
     'https://drive.google.com/uc?export=download&id=1iEyjVt07WkoblcgnX-DdWlqYp-Hsc3Wy',
     'https://drive.google.com/uc?export=download&id=1iEyjVt07WkoblcgnX-DdWlqYp-Hsc3Wy',
     'LOTTIE', 'COIN', 'PREMIUM', 100000::bigint, 7, 0, TRUE, 85),
    ('Thank You',
     'https://drive.google.com/uc?export=download&id=1Iowysv9_-BE4qont-qLkZRi3XhfF6uc4',
     'https://drive.google.com/uc?export=download&id=1Iowysv9_-BE4qont-qLkZRi3XhfF6uc4',
     'LOTTIE', 'COIN', 'PREMIUM', 3000000::bigint, 7, 0, TRUE, 90)
  ) AS seed(name, day_asset_url, night_asset_url, asset_format, currency, type, cost, duration_days, duration_hours, is_active, sort_order)
    ON CONFLICT (day_asset_url) DO NOTHING;
