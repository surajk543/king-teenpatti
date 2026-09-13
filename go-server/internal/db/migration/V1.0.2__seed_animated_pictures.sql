-- King Teen Patti — four more animated pictures (DML).
--
-- Added 13 Sep 2026 (owner), after V1.0.1 had already run in production. New
-- rows are a new script, never an edit to an applied one: the server runs
-- every script on every boot, and this one only has to be idempotent against
-- itself.
--
-- All are Lottie animations on a 100-day rental, following Orange Ballerina on
-- the Premium (Animated) shelf:
--
--   Butterfly Flapping  1000×1000, 5 s, Lottie 4.8.0   4 DIAMONDS  sort_order 170
--   Toucan Flying       1920×1080, 4 s, Lottie 5.5.7   3 DIAMONDS  sort_order 180
--   Live Chatbot         952×784,  3 s, Lottie 5.9.6   1 DIAMOND   sort_order 190
--   Paper Plane          800×600,  3 s, Lottie 5.5.8   1 DIAMOND   sort_order 200
--
-- The toucan's canvas is landscape; the app draws a picture into a circle with
-- BoxFit.cover, so only the centre 1080×1080 of it shows.
--
-- The Drive files are served by the direct-download form
-- uc?export=download&id= (a /file/d/<id>/view link is an HTML viewer page, and
-- lh3 only serves images). ON CONFLICT on asset_url leaves a row the owner has
-- since re-priced, renamed or retired exactly as it is.

INSERT INTO profile_pictures (name, asset_url, asset_format, currency, type, cost, duration_days, is_active, sort_order, created_at, updated_at)
SELECT name, asset_url, asset_format, currency, type, cost, duration_days, is_active, sort_order,
       (EXTRACT(EPOCH FROM now()) * 1000)::bigint,
       (EXTRACT(EPOCH FROM now()) * 1000)::bigint
  FROM (VALUES
    ('Butterfly Flapping', 'https://drive.google.com/uc?export=download&id=1hUwSw_hjvXv-AAU_d__rGUtJJ7OVJT8T',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 4::bigint, 100, TRUE, 170),
    ('Toucan Flying',      'https://drive.google.com/uc?export=download&id=1HdjPRNx4vPO3EI-_U1Z1UQa8mprLdRNM',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 3::bigint, 100, TRUE, 180),
    ('Live Chatbot',       'https://drive.google.com/uc?export=download&id=1msaoUAeJipCWCy0q8TABPKxWc8ExLMjm',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 1::bigint, 100, TRUE, 190),
    ('Paper Plane',        'https://drive.google.com/uc?export=download&id=1PmclJnzKyczYNi3YSIxAStPWLI60f3-8',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 1::bigint, 100, TRUE, 200)
  ) AS seed(name, asset_url, asset_format, currency, type, cost, duration_days, is_active, sort_order)
    ON CONFLICT (asset_url) DO NOTHING;
