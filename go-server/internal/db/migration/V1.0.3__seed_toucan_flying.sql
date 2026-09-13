-- King Teen Patti — Toucan Flying (DML).
--
-- A third animated picture, added 13 Sep 2026 (owner). A new row is a new
-- script, never an edit to an applied one: the server runs every script on
-- every boot, and this one only has to be idempotent against itself.
--
-- Priced like Orange Ballerina and Butterfly Flapping: a Lottie animation (a
-- 4-second toucan, Lottie 5.5.7), one DIAMOND for a 100-day rental, after the
-- butterfly on the Premium (Animated) shelf (sort_order 180). Unlike the other
-- two its canvas is landscape, 1920×1080, not square.
--
-- The Drive file is served by the direct-download form uc?export=download&id=
-- (a /file/d/<id>/view link is an HTML viewer page, and lh3 only serves
-- images). ON CONFLICT on asset_url leaves a row the owner has since
-- re-priced, renamed or retired exactly as it is.

INSERT INTO profile_pictures (name, asset_url, asset_format, currency, type, cost, duration_days, is_active, sort_order, created_at, updated_at)
VALUES ('Toucan Flying',
        'https://drive.google.com/uc?export=download&id=1HdjPRNx4vPO3EI-_U1Z1UQa8mprLdRNM',
        'LOTTIE', 'DIAMOND', 'PREMIUM', 1, 100, TRUE, 180,
        (EXTRACT(EPOCH FROM now()) * 1000)::bigint,
        (EXTRACT(EPOCH FROM now()) * 1000)::bigint)
    ON CONFLICT (asset_url) DO NOTHING;
