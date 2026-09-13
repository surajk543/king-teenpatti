-- King Teen Patti — the profile-picture catalogue (DML).
--
-- Every row the server seeds, in one file. Consolidated on 14 Sep 2026 (owner)
-- for a production deploy onto an empty database (V1.0.0's header): the rows
-- V1.0.2__seed_animated_pictures.sql and V1.0.4__seed_more_animated_pictures.sql
-- used to add are here, in the order they always went in, so a fresh database
-- numbers the catalogue as before — Bear is 1, Jolly Queen is 30.
--
-- Data, not structure: V1.0.0__baseline.sql builds the tables, this fills one
-- of them. Separate on purpose — a price change or a new picture is a row, and
-- a row should never require reopening a structural migration.
--
-- Idempotent, like every script here: the server has no schema history table
-- and runs all of them on every boot, so this must be indistinguishable from
-- having run once. ON CONFLICT on the natural key (asset_url) does that, and
-- it also means the seed never rewrites a row the owner has since re-priced,
-- renamed, reordered or retired. Editing the catalogue afterwards is an
-- UPDATE (`UPDATE profile_pictures SET type = …, cost = … WHERE name = …`),
-- not a code change, and a new picture is a row in a NEW script: this one only
-- ever puts the starting set there.
--
-- THE ANIMALS. Which ones cost chips is a product decision, not a technical
-- one. Two are free — everyone has a face from the first launch — and the rest
-- ladder up at 25k / 50k / 1L / 2L against a 2,00,000 welcome, so the top pair
-- costs a whole welcome grant and is something to play towards. Every premium
-- picture is a RENTAL, and the coin-priced terms rise with the price — 3 days
-- at 25k, 4 at 50k, 5 at 1L, 7 at 2L — so the dear ones are better value per
-- day as well as rarer. The free pair never lapses. They are hosted bitmaps
-- (asset_format IMAGE) priced in COIN.
--
-- THE ANIMATED PICTURES are Lottie animations (asset_format LOTTIE) priced in
-- DIAMONDs on a 100-day rental, the Premium (Animated) shelf. One diamond —
-- Orange Ballerina, Live Chatbot, Paper Plane, Bouncing Dots, Galloping Horse —
-- is exactly what every new account starts with.
--
--   Orange Ballerina                                      1 DIAMOND   sort_order 160
--   Butterfly Flapping  1000×1000, 5 s,   Lottie 4.8.0    4 DIAMONDS  sort_order 170
--   Toucan Flying       1920×1080, 4 s,   Lottie 5.5.7    3 DIAMONDS  sort_order 180
--   Live Chatbot         952×784,  3 s,   Lottie 5.9.6    1 DIAMOND   sort_order 190
--   Paper Plane          800×600,  3 s,   Lottie 5.5.8    1 DIAMOND   sort_order 200
--   Bouncing Dots        256×256,  1.3 s, Lottie 4.6.8    1 DIAMOND   sort_order 210
--   Monarch Butterfly    450×450,  2.7 s, Lottie 4.8.0    4 DIAMONDS  sort_order 220
--   Lovestruck Cat       500×500,  6 s,   Lottie 5.9.6    5 DIAMONDS  sort_order 230
--   Waving Tiger Cub    1400×1400, 6 s,   Lottie 5.7.8    5 DIAMONDS  sort_order 240
--   Galloping Horse     1556×2048, 0.5 s, Lottie 4.8.0    1 DIAMOND   sort_order 250
--   Gamer Raccoon        512×512,  3 s,   Lottie 5.12.1   6 DIAMONDS  sort_order 260
--   Cool Cat             512×512,  2.1 s, Lottie 5.9.6   10 DIAMONDS  sort_order 270
--   Indian Flag         1000×1000, 2 s,   Lottie 4.8.0   10 DIAMONDS  sort_order 280
--   Jolly King          1080×1080, 6.2 s, Lottie 5.9.0   10 DIAMONDS  sort_order 290
--   Jolly Queen         1080×1080, 6.2 s, Lottie 5.9.0   10 DIAMONDS  sort_order 300
--
-- Every one moves with the plain 2D transforms the phone players draw (Flutter's
-- lottie and lottie-android), checked frame by frame against lottie-web — some
-- only because the file served is a reworked copy. Before replacing any of
-- these URLs, read CLAUDE.md §12.3:
--
--   * Butterfly Flapping as drawn beats its wings with 3D orientation ("or"),
--     which the phone players ignore — both wings sat still on top of each
--     other. The Drive file is a copy with that motion baked into 2D rotation
--     and scale on two null parents (tools/lottie/flatten_orientation.py). (It
--     was served from public/profiles/ by go-server/v1.3.0.)
--   * Jolly King and Jolly Queen move only through loopOut() /
--     loopOut('pingpong') expressions, and the phone players run no
--     expressions, so the originals freeze after about a second. The Drive
--     files are copies with those loops written out as keyframes
--     (tools/lottie/bake_loop_expressions.py; 37 properties for the king, 26
--     for the queen), pixel-identical to the originals in lottie-web.
--   * Waving Tiger Cub keeps two loopOut() expressions on a small detail in its
--     head, which holds still on a phone after its first 6-frame cycle — 48
--     differing pixels across eight sampled 212 px frames, invisible at avatar
--     size — so its original is served.
--   * Toucan Flying's canvas is landscape and the app draws a picture into a
--     circle with BoxFit.cover, so only the centre 1080×1080 shows.
--   * Galloping Horse is a black silhouette drawn as a 12-frame flipbook, which
--     barely stands out against the dark theme's picture circles. Indian Flag
--     sits high and left on its canvas, so the round picture loses most of its
--     thin pole and the lower part of the circle is empty. Cool Cat's thin black
--     whiskers fade on the dark theme.
--   * Merge paths (Galloping Horse, Gamer Raccoon, Cool Cat) are all plain
--     merges, which the phone players — merge paths off by default — draw
--     identically. Monarch Butterfly beats its wings by scaling each wing layer
--     horizontally, and embeds its three images in the JSON.
--
-- Google Drive: a /file/d/<id>/view link is an HTML viewer page, not the file,
-- and a client handed one renders nothing. Images use
-- lh3.googleusercontent.com/d/<id> (it serves the bytes and resizes, =s256);
-- anything else uses the direct-download form uc?export=download&id=<id>,
-- because lh3 only serves images. A changed file needs a new URL: the phones
-- keep a downloaded picture for as long as its URL stays the same.

INSERT INTO profile_pictures (name, asset_url, asset_format, currency, type, cost, duration_days, is_active, sort_order, created_at, updated_at)
SELECT name, asset_url, asset_format, currency, type, cost, duration_days, is_active, sort_order,
       (EXTRACT(EPOCH FROM now()) * 1000)::bigint,
       (EXTRACT(EPOCH FROM now()) * 1000)::bigint
  FROM (VALUES
    -- The animals.
    ('Bear',     'https://lh3.googleusercontent.com/d/1cMAxBlDvKxPpPyOKffLsjM0RDxPUdC-_=s256',
     'IMAGE',  'COIN',    'FREE', 0::bigint, 0, TRUE, 10),
    ('Cat',      'https://lh3.googleusercontent.com/d/1fTFvJGmCOaFF-mCm_4XAdyjaRFw3Sf9a=s256',
     'IMAGE',  'COIN',    'FREE', 0::bigint, 0, TRUE, 20),
    ('Dog',      'https://lh3.googleusercontent.com/d/1hZ2iw1UkqHJN18MLUhRTZGbgLBm-7dBS=s256',
     'IMAGE',  'COIN',    'PREMIUM', 25000::bigint, 3, TRUE, 30),
    ('Frog',     'https://lh3.googleusercontent.com/d/1JNMYRv7JtMkfkhEebxLIpTEx4TVMIV-7=s256',
     'IMAGE',  'COIN',    'PREMIUM', 25000::bigint, 3, TRUE, 40),
    ('Horse',    'https://lh3.googleusercontent.com/d/16v7Hh1ZknhM79ZR0KvelT48J4h2T-wyd=s256',
     'IMAGE',  'COIN',    'PREMIUM', 50000::bigint, 4, TRUE, 50),
    ('Koala',    'https://lh3.googleusercontent.com/d/1eRCQHZY-GJc5I2skndx6eyegFhTDCXoH=s256',
     'IMAGE',  'COIN',    'PREMIUM', 50000::bigint, 4, TRUE, 60),
    ('Monkey',   'https://lh3.googleusercontent.com/d/1NJDPIyXjEDEj4nRYEu1KTUjGDNQGqAfg=s256',
     'IMAGE',  'COIN',    'PREMIUM', 50000::bigint, 4, TRUE, 70),
    ('Penguin',  'https://lh3.googleusercontent.com/d/11MRH75SHIbZJzeK_tkQp6Gt6Z5GFJlaH=s256',
     'IMAGE',  'COIN',    'PREMIUM', 50000::bigint, 4, TRUE, 80),
    ('Rabbit',   'https://lh3.googleusercontent.com/d/1wIdpZ7RMytoy9rhpA411lZFz7CbjdyM3=s256',
     'IMAGE',  'COIN',    'PREMIUM', 50000::bigint, 4, TRUE, 90),
    ('Fox',      'https://lh3.googleusercontent.com/d/1qBwGLPAEBr2y5Y2_EVCAd0jQWDeCcUOW=s256',
     'IMAGE',  'COIN',    'PREMIUM', 100000::bigint, 5, TRUE, 100),
    ('Owl',      'https://lh3.googleusercontent.com/d/125zcjmHrYFGg0jMFm0zqpRg_G8VNSr5L=s256',
     'IMAGE',  'COIN',    'PREMIUM', 100000::bigint, 5, TRUE, 110),
    ('Lion',     'https://lh3.googleusercontent.com/d/1weXwu_K_35tQHYg92C4tIB9TwM7mBDab=s256',
     'IMAGE',  'COIN',    'PREMIUM', 100000::bigint, 5, TRUE, 120),
    ('Tiger',    'https://lh3.googleusercontent.com/d/1L-focNnL0yNJueAArM-YfHE9kX0VZv3T=s256',
     'IMAGE',  'COIN',    'PREMIUM', 100000::bigint, 5, TRUE, 130),
    ('Panda',    'https://lh3.googleusercontent.com/d/1zCySFnbUMtnBjv1g_u9nruHZM5PIdnt_=s256',
     'IMAGE',  'COIN',    'PREMIUM', 200000::bigint, 7, TRUE, 140),
    ('Wolf',     'https://lh3.googleusercontent.com/d/1LB0wQaR_rq3bYk9oN5P6RWsEm5-oIXae=s256',
     'IMAGE',  'COIN',    'PREMIUM', 200000::bigint, 7, TRUE, 150),
    -- The animated pictures.
    ('Orange Ballerina',   'https://drive.google.com/uc?export=download&id=1TNa5MuHshDXimN4ItUUQBB4VrW8xfmFH',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 1::bigint, 100, TRUE, 160),
    ('Butterfly Flapping', 'https://drive.google.com/uc?export=download&id=19mQ9PjStBJUoFyThaSe97fEcfzARw_Ar',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 4::bigint, 100, TRUE, 170),
    ('Toucan Flying',      'https://drive.google.com/uc?export=download&id=1HdjPRNx4vPO3EI-_U1Z1UQa8mprLdRNM',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 3::bigint, 100, TRUE, 180),
    ('Live Chatbot',       'https://drive.google.com/uc?export=download&id=1msaoUAeJipCWCy0q8TABPKxWc8ExLMjm',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 1::bigint, 100, TRUE, 190),
    ('Paper Plane',        'https://drive.google.com/uc?export=download&id=1PmclJnzKyczYNi3YSIxAStPWLI60f3-8',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 1::bigint, 100, TRUE, 200),
    ('Bouncing Dots',      'https://drive.google.com/uc?export=download&id=1FfiTWCqv_r0_wllt9GXKDhwVKxSZ823V',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 1::bigint, 100, TRUE, 210),
    ('Monarch Butterfly',  'https://drive.google.com/uc?export=download&id=16CuzIvYWioJW4xTyI4ukYVkHWnJFLyt-',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 4::bigint, 100, TRUE, 220),
    ('Lovestruck Cat',     'https://drive.google.com/uc?export=download&id=1KOKAFftNzGhnG6ISbnb7ylz1uTf87Er3',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 5::bigint, 100, TRUE, 230),
    ('Waving Tiger Cub',   'https://drive.google.com/uc?export=download&id=1vg1xUlnF0vLAYh-w8F4dHRUsQ1sTPTgB',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 5::bigint, 100, TRUE, 240),
    ('Galloping Horse',    'https://drive.google.com/uc?export=download&id=1hYp8vPfH07C7JeJlmJZI5JyazvRd7Qbg',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 1::bigint, 100, TRUE, 250),
    ('Gamer Raccoon',      'https://drive.google.com/uc?export=download&id=1uchuXzcjzIq6_WKIp2jHVkJ2D4AGxH8g',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 6::bigint, 100, TRUE, 260),
    ('Cool Cat',           'https://drive.google.com/uc?export=download&id=15UkZwIjVdEquW_smNseUStfciYikMH37',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 10::bigint, 100, TRUE, 270),
    ('Indian Flag',        'https://drive.google.com/uc?export=download&id=11oXU9B5LeWF9OMEcCYihLkKcrj0Zl4Gn',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 10::bigint, 100, TRUE, 280),
    ('Jolly King',         'https://drive.google.com/uc?export=download&id=1oDAJP-qC9GNxt6tW6WLMldl0EV6YtcWn',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 10::bigint, 100, TRUE, 290),
    ('Jolly Queen',        'https://drive.google.com/uc?export=download&id=1PXnoJzPxQtn7v5JkjUVemUNdbA4gSa73',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 10::bigint, 100, TRUE, 300)
  ) AS seed(name, asset_url, asset_format, currency, type, cost, duration_days, is_active, sort_order)
    ON CONFLICT (asset_url) DO NOTHING;
