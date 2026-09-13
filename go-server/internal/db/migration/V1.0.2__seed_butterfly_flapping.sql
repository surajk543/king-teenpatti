-- King Teen Patti — Butterfly Flapping (DML).
--
-- A second animated picture, added 13 Sep 2026 (owner) after V1.0.1 had
-- already run in production. A new row is a new script, never an edit to an
-- applied one: the server runs every script on every boot, and this one only
-- has to be idempotent against itself.
--
-- Priced like Orange Ballerina: a Lottie animation (a 1000×1000, 5-second
-- butterfly, Lottie 4.8.0), one DIAMOND for a 100-day rental. It sits after
-- the ballerina on the Premium (Animated) shelf (sort_order 170).
--
-- The Drive file is served by the direct-download form uc?export=download&id=
-- (a /file/d/<id>/view link is an HTML viewer page, and lh3 only serves
-- images). ON CONFLICT on asset_url leaves a row the owner has since
-- re-priced, renamed or retired exactly as it is.

INSERT INTO profile_pictures (name, asset_url, asset_format, currency, type, cost, duration_days, is_active, sort_order, created_at, updated_at)
VALUES ('Butterfly Flapping',
        'https://drive.google.com/uc?export=download&id=1hUwSw_hjvXv-AAU_d__rGUtJJ7OVJT8T',
        'LOTTIE', 'DIAMOND', 'PREMIUM', 1, 100, TRUE, 170,
        (EXTRACT(EPOCH FROM now()) * 1000)::bigint,
        (EXTRACT(EPOCH FROM now()) * 1000)::bigint)
    ON CONFLICT (asset_url) DO NOTHING;
