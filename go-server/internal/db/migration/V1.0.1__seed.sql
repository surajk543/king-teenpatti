-- King Teen Patti — every row the server seeds (DML).
--
-- The DATA half of the two scripts there are (owner, 23 Sep 2026: "merge all
-- DDL and DML into 2 files"; V1.0.0__baseline.sql is the structure). Two
-- catalogues — three since 23 Sep 2026 — each under its own heading below:
--
--   THE PICTURES  the profile-picture catalogue (requirements 20 and 21) —
--                 this file's whole content while it was named
--                 V1.0.1__seed_profile_pictures.sql. Nothing records a
--                 script's name (there is no schema history table), so the
--                 rename changed nothing for any database.
--   THE TABLE PICTURES  the table-picture catalogue (owner, 15 Sep 2026):
--                 the pictures a player lays on their table, a day and a
--                 night file each (table_pictures).
--   THE TABLES    the table catalogue (owner, 23 Sep 2026): the engines and
--                 the categories under them (table_engines, table_categories),
--                 the one table_settings row, and a table_configs row for
--                 every lobby table and every private template.
--   THE LUCKY DRAW  the beginner draw and its six prizes (owner, 24 Sep 2026;
--                 lucky_draws, lucky_draw_slots).
--   THE EMOJIS    the emoji catalogue (owner, 26 Sep 2026): the animations a
--                 player buys and sends at a table (emojis).
--   THE PLAYER LEVELS  the level ladder (owner, 26 Sep 2026; the tax bracket
--                 of 27 Sep 2026): fifty levels reached by XP, each with its
--                 title, icon and winning tax (player_levels); the badges a
--                 player may hold beside their level (badges; owner, 27 Sep
--                 2026: "Vip is not a level, it is badge"); what earns XP and
--                 how much (xp_sources: the daily sources and, since 28 Sep
--                 2026, the one-time missions); and the 24-hour window, with no
--                 daily cap (xp_settings). No player_xp or user_badges row is
--                 ever seeded. Levels and XP never expire — XP is only ever
--                 added to, and the window resets what may still be EARNED
--                 today, never what was. A Royal badge is bought in the app
--                 through Google Play (its play_product_id, below); one
--                 given BY HAND instead — a support grant, a compensation —
--                 runs for its validity_days (7 for Royal Ace up to 90 for
--                 Royal King of Kings), with:
--
--     INSERT INTO user_badges (user_id, badge_code) VALUES ('<users.id>', 'ROYAL_KING')
--     ON CONFLICT (user_id, badge_code) DO UPDATE
--        SET granted_at = EXCLUDED.granted_at, expires_at = EXCLUDED.expires_at;
--
--                 — which also RENEWS it for another validity from now — or
--                 for a term of its own, naming expires_at (epoch ms; 0: for
--                 ever): `INSERT INTO user_badges (user_id, badge_code,
--                 expires_at) VALUES ('<users.id>', 'ROYAL_ACE', 0) ON
--                 CONFLICT (user_id, badge_code) DO UPDATE SET expires_at =
--                 EXCLUDED.expires_at;`. It is taken away early with `UPDATE
--                 user_badges SET expires_at = (EXTRACT(EPOCH FROM now()) *
--                 1000)::bigint WHERE user_id = '<users.id>' AND badge_code =
--                 'ROYAL_KING';` (the row stays as the record). A player holds every
--                 badge whose grant has not run out, and Regular always
--                 (is_default; owner, 27 Sep 2026: "By default every user will
--                 hold this Regular badge"); the winning tax they pay is the
--                 LOWEST of their
--                 level's and their badges' (V1.0.0's PLAYER LEVELS). XP
--                 never grants a badge. A seat takes the new rate at its next
--                 sit-down or hand end.
--   THE APP VERSIONS  a row per app platform with no floor (owner, 28 Sep
--                 2026; app_versions).
--   THE WELCOME   what a new account is given (owner, 30 Sep 2026;
--                 welcome_rewards): the diamonds, hammers and missile. The
--                 chips row is the server's, written at boot from WELCOME_CHIPS
--                 (the section says why).
--
-- Data, not structure: V1.0.0__baseline.sql builds every table these rows go
-- into, and it runs FIRST — before this file and before anything numbered
-- after it. So anything a row here needs of the structure (a new column, a new
-- table) must be declared THERE, never in a later-numbered script, which would
-- run after this one and leave the row failing on every boot (the baseline's
-- header, "THE NEXT CHANGE GOES IN THIS FILE, NEVER IN A NEW ONE"). Separate
-- on purpose — a price change, a new picture or a new table is a row, and a
-- row should never require reopening a structural migration. This file
-- creates, alters and indexes nothing
-- (TestMigrationsAreVersionedOrderedAndSplitByKind).
--
-- Idempotent, like every script here: the server has no schema history table
-- and runs all of them on every boot, so this must be indistinguishable from
-- having run once. ON CONFLICT on each table's natural key does that — a
-- picture's asset_url, an engine's or a category's code, the settings row's
-- id, a table's table_key, a level's number — and it
-- also means the seed never rewrites a row the owner has since edited:
-- re-priced, renamed, reordered, retired. Editing a row a database already
-- has is an UPDATE (`UPDATE profile_pictures SET cost = … WHERE name = …`,
-- `UPDATE table_configs SET max_blind_moves = 3 WHERE table_key = 'blind:200'`),
-- not a code change.


-- ================================================================ THE PICTURES
--
-- Consolidated on 14 Sep 2026 (owner) for a production deploy onto an empty
-- database (V1.0.0's header): the rows V1.0.2__seed_animated_pictures.sql and
-- V1.0.4__seed_more_animated_pictures.sql used to add are here. The rows run
-- free first, then the pictures priced in chips, then the animated pictures
-- priced in hammers, then those priced in diamonds (owner, 14 Sep 2026), and
-- sort_order follows that order in steps of ten, so a fresh database numbers
-- the catalogue the same way: Bear is 1, Wolf 15, Love Sheep 16, Anima Bot 19,
-- Orange Ballerina 20, Love and Kiss 35, Butterfly Flapping 36 and Jolly Queen
-- 40, and the five appended after launch 41 to 45. Shooting Game, Spider,
-- Swirling Dots, Sporty Avocado and Blazing Fire, and after them Love Sheep,
-- Love Birds, Error 404, Anima Bot and Love and Kiss, were added to this file
-- the same day, rather than in a new script, because no environment that
-- matters had run it yet: production starts from an empty database
-- (ops/DEPLOY.md §8).
--
-- AFTER LAUNCH. go-server/v1.1.0 put production on this file the same day, and
-- the owner has gone on adding to it rather than to new scripts: the five
-- pictures of V1.0.3__seed_new_pictures.sql were folded back in (owner, 14 Sep
-- 2026). That works for a NEW row — every boot runs this file, and ON CONFLICT
-- DO NOTHING skips only the rows a database already has, so a row appended
-- here reaches production at its next boot. It does NOT work for a CHANGED row:
-- Love and Kiss was re-priced here from 2 hammers to 25 after production had
-- the row, so only a database built from scratch sells it at 25, and
-- production keeps 2 until an UPDATE is run there (owner's choice).
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
-- THE ANIMATED PICTURES PRICED IN CHIPS (owner, 14 Sep 2026) are four Lottie
-- animations far above the animals' ladder, filed after them cheapest first.
-- The two cheaper ones are the first rentals counted in hours
-- (duration_hours, beside duration_days — V1.0.0's profile_pictures). Being
-- chip-priced they sell only in the lobby; at a table they can be worn but not
-- bought. None has 3D layers, expressions or embedded images, so the phones
-- play them as lottie-web does (CLAUDE.md §12.3).
--
--   Love Sheep  512×512,   2.7 s, Lottie 5.5.2   10 LAKH    1 hour    sort_order 160
--   Love Birds  350×300,   3 s,   Lottie 5.9.4   30 LAKH    3 hours   sort_order 170
--   Error 404   512×512,   6 s,   Lottie 5.8.1   1 CRORE   10 days    sort_order 180
--   Anima Bot   1080×1080, 2.7 s, Lottie 5.7.0   1 CRORE    5 days    sort_order 190
--
-- Love Sheep is two sheep kissing inside a pink heart. Love Birds is a pink
-- bird and a teal one flirting under little hearts; it was uploaded as "Bird
-- pair love and flying sky" and is named for what it shows, and its canvas is
-- a little wider than tall, so the round picture trims the sides. Error 404 is
-- a yellow robot at a desk under "Oops! 404", named as uploaded. Anima Bot is
-- a pale robot with a dark visor that floats and waves, drawn with gradients
-- on a transparent canvas.
--
-- THE ANIMATED PICTURES are Lottie animations (asset_format LOTTIE), the
-- Premium (Animated) shelf, all rentals. The owner priced 15 of them in HAMMERs
-- on 14 Sep 2026 — they had been diamonds, at a tenth of these figures — each
-- rented for as many days as it costs hammers (Swirling Dots: 30 hammers for 50
-- days), added a sixteenth the same day at 2 hammers for 10 days — Love and
-- Kiss, a boy and a girl with a balloon about to kiss, whose maker's red logo
-- sits in a corner the round picture mostly cuts off — and kept five in
-- DIAMONDs on a 100-day rental: Butterfly Flapping,
-- Waving Tiger Cub, Indian Flag, Jolly King and Jolly Queen. Every new account
-- starts with 20 hammers and 9 diamonds, which covers any two of the 10-hammer
-- pictures or any one diamond picture — though a hammer spent on a picture is
-- one fewer Force Sideshow.
--
--   Orange Ballerina                                      10 HAMMERS   10 days   sort_order 200
--   Toucan Flying       1920×1080, 4 s,    Lottie 5.5.7   30 HAMMERS   30 days   sort_order 210
--   Live Chatbot        952×784,  3 s,    Lottie 5.9.6    10 HAMMERS   10 days   sort_order 220
--   Paper Plane         800×600,  3 s,    Lottie 5.5.8    10 HAMMERS   10 days   sort_order 230
--   Bouncing Dots       256×256,  1.3 s,  Lottie 4.6.8    10 HAMMERS   10 days   sort_order 240
--   Monarch Butterfly   450×450,  2.7 s,  Lottie 4.8.0    40 HAMMERS   40 days   sort_order 250
--   Lovestruck Cat      500×500,  6 s,    Lottie 5.9.6    50 HAMMERS   50 days   sort_order 260
--   Galloping Horse     1556×2048, 0.5 s,  Lottie 4.8.0   10 HAMMERS   10 days   sort_order 270
--   Gamer Raccoon       512×512,  3 s,    Lottie 5.12.1   60 HAMMERS   60 days   sort_order 280
--   Cool Cat            512×512,  2.1 s,  Lottie 5.9.6   100 HAMMERS  100 days   sort_order 290
--   Shooting Game       400×400,  0.85 s, Lottie 5.5.2    80 HAMMERS   80 days   sort_order 300
--   Spider              3840×2160, 6 s,    Lottie 5.12.1  80 HAMMERS   80 days   sort_order 310
--   Swirling Dots       1080×1080, 2.8 s,  Lottie 5.9.3   30 HAMMERS   50 days   sort_order 320
--   Sporty Avocado      256×256,  3.2 s,  Lottie 5.7.11   90 HAMMERS   90 days   sort_order 330
--   Blazing Fire        500×690,  1.1 s,  Lottie 5.9.0    10 HAMMERS   10 days   sort_order 340
--   Love and Kiss       512×512,  3 s,    Lottie 5.4.4    25 HAMMERS   10 days   sort_order 350
--   Butterfly Flapping  1000×1000, 5 s,    Lottie 4.8.0   4 DIAMONDS  100 days   sort_order 360
--   Waving Tiger Cub    1400×1400, 6 s,    Lottie 5.7.8   3 DIAMONDS  100 days   sort_order 370
--   Indian Flag         1000×1000, 2 s,    Lottie 4.8.0   5 DIAMONDS  100 days   sort_order 380
--   Jolly King          1080×1080, 6.2 s,  Lottie 5.9.0   5 DIAMONDS  100 days   sort_order 390
--   Jolly Queen         1080×1080, 6.2 s,  Lottie 5.9.0   5 DIAMONDS  100 days   sort_order 400
--
-- THE PICTURES APPENDED AFTER LAUNCH (owner, 14 Sep 2026) are five more Lottie
-- rentals, at the end of the list below (AFTER LAUNCH, above):
--
--   Bodybuilder         512×512,  3.3 s,  Lottie 5.7.11   50 CRORE     50 days   sort_order 195
--   Butterfly           1000×1000, 2 s,    Lottie 5.9.6   100 CRORE    100 days   sort_order 197
--   Dog Dancing         256×256,  3.2 s,  Lottie 5.12.1   30 HAMMERS   30 days   sort_order 352
--   Dance               512×512,  3.2 s,  Lottie 5.12.1   20 HAMMERS   10 days   sort_order 354
--   Cockroach           1024×1024, 2.2 s,  Lottie 5.8.1   10 HAMMERS   15 days   sort_order 356
--
-- Bodybuilder and Butterfly are the two dearest pictures in the catalogue,
-- priced in chips and so sold in the lobby only. Bodybuilder was uploaded as
-- "Bodybuilder lifting heavy barbell" and is named shorter, as Love Birds was;
-- Butterfly is a different animation from Butterfly Flapping and Monarch
-- Butterfly. Dog Dancing is rented for as many days as it costs and Dance and
-- Cockroach are not; Cockroach was first priced at 80 Crore chips for 50 days,
-- then sent again at 10 hammers for 15. The rest are named as uploaded. None
-- has 3D layers, expressions or embedded images, and Butterfly's four merge
-- paths are plain merges, which the phone players draw identically. sort_order
-- files the chip pair after Anima Bot and the hammer three after Love and Kiss,
-- so the catalogue still runs free → chips → hammers → diamonds.
--
-- Every one moves with what the phone players draw (Flutter's lottie and
-- lottie-android), checked frame by frame against lottie-web — some only
-- because the file served is a reworked copy. Before replacing any of these
-- URLs, read CLAUDE.md §12.3:
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
--   * Sporty Avocado — an avocado in a headband kicking its own stone about —
--     carries 12 "Kleaner" expressions (anticipation and follow-through laid
--     over keyframed transforms). The phones play the keyframes without that
--     overshoot, which looked the same at avatar size, so the original is
--     served. It is BLACK line art on a transparent canvas: on the dark theme's
--     picture circles it all but disappears.
--   * Toucan Flying's and Spider's canvases are landscape and Blazing Fire's is
--     portrait, and the app draws a picture into a circle with BoxFit.cover, so
--     only the centre square shows — for the spider the whole spider, for the
--     fire everything but the tips of its flame and its sparks.
--   * Galloping Horse is a black silhouette drawn as a 12-frame flipbook, which
--     barely stands out against the dark theme's picture circles. Indian Flag
--     sits high and left on its canvas, so the round picture loses most of its
--     thin pole and the lower part of the circle is empty. Cool Cat's thin black
--     whiskers fade on the dark theme, and so do Spider's dark brown legs (its
--     coral body and big eyes do not).
--   * Merge paths (Galloping Horse, Gamer Raccoon, Cool Cat) are all plain
--     merges, which the phone players — merge paths off by default — draw
--     identically. Monarch Butterfly beats its wings by scaling each wing layer
--     horizontally, and embeds its three images in the JSON.
--   * Shooting Game — a helmeted soldier firing a heavy gun, muzzle flash and
--     spent shells flying — is a video turned into a Lottie: 28 image layers,
--     one per frame at 33 fps, each showing one of 28 embedded 400×400 WebP
--     images. The images carry no transparency, so the soldier stands on a
--     white square and the round picture is a white disc on either theme. Most
--     of its 180 KB is the images.
--   * Swirling Dots — purple and teal dots chasing each other round a turning
--     loop, on a transparent canvas — was uploaded as "Dots Loader"; it is
--     named for what it shows, since the upload's name reads as a loading
--     spinner and sat close to Bouncing Dots.
--   * Blazing Fire is the animated 🔥 from Noto Emoji Animation
--     (emoji_u1F525), drawn with gradients the phone players handle. That
--     collection is published under CC BY 4.0, which asks for attribution.
--
-- Google Drive: a /file/d/<id>/view link is an HTML viewer page, not the file,
-- and a client handed one renders nothing. Images use
-- lh3.googleusercontent.com/d/<id> (it serves the bytes and resizes, =s256);
-- anything else uses the direct-download form uc?export=download&id=<id>,
-- because lh3 only serves images. A changed file needs a new URL: the phones
-- keep a downloaded picture for as long as its URL stays the same.

INSERT INTO profile_pictures (name, asset_url, asset_format, currency, type, cost, duration_days, duration_hours, is_active, sort_order, created_at, updated_at)
SELECT name, asset_url, asset_format, currency, type, cost, duration_days, duration_hours, is_active, sort_order,
       (EXTRACT(EPOCH FROM now()) * 1000)::bigint,
       (EXTRACT(EPOCH FROM now()) * 1000)::bigint
  FROM (VALUES
    -- Free: everyone may wear these.
    ('Bear',     'https://lh3.googleusercontent.com/d/1cMAxBlDvKxPpPyOKffLsjM0RDxPUdC-_=s256',
     'IMAGE',  'COIN',    'FREE', 0::bigint, 0, 0, TRUE, 10),
    ('Cat',      'https://lh3.googleusercontent.com/d/1fTFvJGmCOaFF-mCm_4XAdyjaRFw3Sf9a=s256',
     'IMAGE',  'COIN',    'FREE', 0::bigint, 0, 0, TRUE, 20),
    -- The animals priced in chips.
    ('Dog',      'https://lh3.googleusercontent.com/d/1hZ2iw1UkqHJN18MLUhRTZGbgLBm-7dBS=s256',
     'IMAGE',  'COIN',    'PREMIUM', 25000::bigint, 3, 0, TRUE, 30),
    ('Frog',     'https://lh3.googleusercontent.com/d/1JNMYRv7JtMkfkhEebxLIpTEx4TVMIV-7=s256',
     'IMAGE',  'COIN',    'PREMIUM', 25000::bigint, 3, 0, TRUE, 40),
    ('Horse',    'https://lh3.googleusercontent.com/d/16v7Hh1ZknhM79ZR0KvelT48J4h2T-wyd=s256',
     'IMAGE',  'COIN',    'PREMIUM', 50000::bigint, 4, 0, TRUE, 50),
    ('Koala',    'https://lh3.googleusercontent.com/d/1eRCQHZY-GJc5I2skndx6eyegFhTDCXoH=s256',
     'IMAGE',  'COIN',    'PREMIUM', 50000::bigint, 4, 0, TRUE, 60),
    ('Monkey',   'https://lh3.googleusercontent.com/d/1NJDPIyXjEDEj4nRYEu1KTUjGDNQGqAfg=s256',
     'IMAGE',  'COIN',    'PREMIUM', 50000::bigint, 4, 0, TRUE, 70),
    ('Penguin',  'https://lh3.googleusercontent.com/d/11MRH75SHIbZJzeK_tkQp6Gt6Z5GFJlaH=s256',
     'IMAGE',  'COIN',    'PREMIUM', 50000::bigint, 4, 0, TRUE, 80),
    ('Rabbit',   'https://lh3.googleusercontent.com/d/1wIdpZ7RMytoy9rhpA411lZFz7CbjdyM3=s256',
     'IMAGE',  'COIN',    'PREMIUM', 50000::bigint, 4, 0, TRUE, 90),
    ('Fox',      'https://lh3.googleusercontent.com/d/1qBwGLPAEBr2y5Y2_EVCAd0jQWDeCcUOW=s256',
     'IMAGE',  'COIN',    'PREMIUM', 100000::bigint, 5, 0, TRUE, 100),
    ('Owl',      'https://lh3.googleusercontent.com/d/125zcjmHrYFGg0jMFm0zqpRg_G8VNSr5L=s256',
     'IMAGE',  'COIN',    'PREMIUM', 100000::bigint, 5, 0, TRUE, 110),
    ('Lion',     'https://lh3.googleusercontent.com/d/1weXwu_K_35tQHYg92C4tIB9TwM7mBDab=s256',
     'IMAGE',  'COIN',    'PREMIUM', 100000::bigint, 5, 0, TRUE, 120),
    ('Tiger',    'https://lh3.googleusercontent.com/d/1L-focNnL0yNJueAArM-YfHE9kX0VZv3T=s256',
     'IMAGE',  'COIN',    'PREMIUM', 100000::bigint, 5, 0, TRUE, 130),
    ('Panda',    'https://lh3.googleusercontent.com/d/1zCySFnbUMtnBjv1g_u9nruHZM5PIdnt_=s256',
     'IMAGE',  'COIN',    'PREMIUM', 200000::bigint, 7, 0, TRUE, 140),
    ('Wolf',     'https://lh3.googleusercontent.com/d/1LB0wQaR_rq3bYk9oN5P6RWsEm5-oIXae=s256',
     'IMAGE',  'COIN',    'PREMIUM', 200000::bigint, 7, 0, TRUE, 150),
    -- The animated pictures priced in chips.
    ('Love Sheep',         'https://drive.google.com/uc?export=download&id=1_xsklNtmysOICReADfzAHTmGWXtap0P8',
     'LOTTIE', 'COIN',    'PREMIUM', 1000000::bigint, 0, 1, TRUE, 160),
    ('Love Birds',         'https://drive.google.com/uc?export=download&id=1sr5MD9P1lK9Whg5qezYMGVz9P7aM5h6F',
     'LOTTIE', 'COIN',    'PREMIUM', 3000000::bigint, 0, 3, TRUE, 170),
    ('Error 404',          'https://drive.google.com/uc?export=download&id=1bVCZfGy671tAjUHdPIscUFbuSPpeX15o',
     'LOTTIE', 'COIN',    'PREMIUM', 10000000::bigint, 10, 0, TRUE, 180),
    ('Anima Bot',          'https://drive.google.com/uc?export=download&id=1ZyY6jy3Bm7QYVs3-GWfzFfCjlY95yeaP',
     'LOTTIE', 'COIN',    'PREMIUM', 10000000::bigint, 5, 0, TRUE, 190),
    -- The animated pictures priced in hammers.
    ('Orange Ballerina',   'https://drive.google.com/uc?export=download&id=1TNa5MuHshDXimN4ItUUQBB4VrW8xfmFH',
     'LOTTIE', 'HAMMER', 'PREMIUM', 10::bigint, 10, 0, TRUE, 200),
    ('Toucan Flying',      'https://drive.google.com/uc?export=download&id=1HdjPRNx4vPO3EI-_U1Z1UQa8mprLdRNM',
     'LOTTIE', 'HAMMER', 'PREMIUM', 30::bigint, 30, 0, TRUE, 210),
    ('Live Chatbot',       'https://drive.google.com/uc?export=download&id=1msaoUAeJipCWCy0q8TABPKxWc8ExLMjm',
     'LOTTIE', 'HAMMER', 'PREMIUM', 10::bigint, 10, 0, TRUE, 220),
    ('Paper Plane',        'https://drive.google.com/uc?export=download&id=1PmclJnzKyczYNi3YSIxAStPWLI60f3-8',
     'LOTTIE', 'HAMMER', 'PREMIUM', 10::bigint, 10, 0, TRUE, 230),
    ('Bouncing Dots',      'https://drive.google.com/uc?export=download&id=1FfiTWCqv_r0_wllt9GXKDhwVKxSZ823V',
     'LOTTIE', 'HAMMER', 'PREMIUM', 10::bigint, 10, 0, TRUE, 240),
    ('Monarch Butterfly',  'https://drive.google.com/uc?export=download&id=16CuzIvYWioJW4xTyI4ukYVkHWnJFLyt-',
     'LOTTIE', 'HAMMER', 'PREMIUM', 40::bigint, 40, 0, TRUE, 250),
    ('Lovestruck Cat',     'https://drive.google.com/uc?export=download&id=1KOKAFftNzGhnG6ISbnb7ylz1uTf87Er3',
     'LOTTIE', 'HAMMER', 'PREMIUM', 50::bigint, 50, 0, TRUE, 260),
    ('Galloping Horse',    'https://drive.google.com/uc?export=download&id=1hYp8vPfH07C7JeJlmJZI5JyazvRd7Qbg',
     'LOTTIE', 'HAMMER', 'PREMIUM', 10::bigint, 10, 0, TRUE, 270),
    ('Gamer Raccoon',      'https://drive.google.com/uc?export=download&id=1uchuXzcjzIq6_WKIp2jHVkJ2D4AGxH8g',
     'LOTTIE', 'HAMMER', 'PREMIUM', 60::bigint, 60, 0, TRUE, 280),
    ('Cool Cat',           'https://drive.google.com/uc?export=download&id=15UkZwIjVdEquW_smNseUStfciYikMH37',
     'LOTTIE', 'HAMMER', 'PREMIUM', 100::bigint, 100, 0, TRUE, 290),
    ('Shooting Game',      'https://drive.google.com/uc?export=download&id=1awnG6ysbh0QRWXQpDN-5yIsTj0IXFJbO',
     'LOTTIE', 'HAMMER', 'PREMIUM', 80::bigint, 80, 0, TRUE, 300),
    ('Spider',             'https://drive.google.com/uc?export=download&id=1JRg3ayCimSPi3SsJNSRFj53S65BdMzpY',
     'LOTTIE', 'HAMMER', 'PREMIUM', 80::bigint, 80, 0, TRUE, 310),
    ('Swirling Dots',      'https://drive.google.com/uc?export=download&id=10vbKXtV7-ZT8Gf-m7giwWNbi0nP67juF',
     'LOTTIE', 'HAMMER', 'PREMIUM', 30::bigint, 50, 0, TRUE, 320),
    ('Sporty Avocado',     'https://drive.google.com/uc?export=download&id=1cal_8xZS9Tz4TCDt1leTtG36mqZhH98Q',
     'LOTTIE', 'HAMMER', 'PREMIUM', 90::bigint, 90, 0, TRUE, 330),
    ('Blazing Fire',       'https://drive.google.com/uc?export=download&id=1sWLmx0skXzrQ6d_ZitT_OTZMmSd_c6LA',
     'LOTTIE', 'HAMMER', 'PREMIUM', 10::bigint, 10, 0, TRUE, 340),
    ('Love and Kiss',      'https://drive.google.com/uc?export=download&id=1Mw_0tq2l_2FN3c7X_sDvrV_nZqIsafVM',
     'LOTTIE', 'HAMMER', 'PREMIUM', 25::bigint, 10, 0, TRUE, 350),
    -- The animated pictures priced in diamonds.
    ('Butterfly Flapping', 'https://drive.google.com/uc?export=download&id=19mQ9PjStBJUoFyThaSe97fEcfzARw_Ar',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 4::bigint, 100, 0, TRUE, 360),
    ('Waving Tiger Cub',   'https://drive.google.com/uc?export=download&id=1vg1xUlnF0vLAYh-w8F4dHRUsQ1sTPTgB',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 3::bigint, 100, 0, TRUE, 370),
    ('Indian Flag',        'https://drive.google.com/uc?export=download&id=11oXU9B5LeWF9OMEcCYihLkKcrj0Zl4Gn',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 5::bigint, 100, 0, TRUE, 380),
    ('Jolly King',         'https://drive.google.com/uc?export=download&id=1oDAJP-qC9GNxt6tW6WLMldl0EV6YtcWn',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 5::bigint, 100, 0, TRUE, 390),
    ('Jolly Queen',        'https://drive.google.com/uc?export=download&id=1PXnoJzPxQtn7v5JkjUVemUNdbA4gSa73',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 5::bigint, 100, 0, TRUE, 400),
    -- Appended after launch (owner, 14 Sep 2026). At the end, so the ids an
    -- empty database gives the rows above stay the ones the header lists;
    -- sort_order files each among its currency's pictures.
    ('Bodybuilder',        'https://drive.google.com/uc?export=download&id=1rpYEPGB5MqjPq-V-1wKPP0waPy3iYGxq',
     'LOTTIE', 'COIN',    'PREMIUM', 500000000::bigint, 50, 0, TRUE, 195),
    ('Butterfly',          'https://drive.google.com/uc?export=download&id=1j_sD1jKZZwbgTOquWLhRS96gqJ8xS67c',
     'LOTTIE', 'COIN',    'PREMIUM', 1000000000::bigint, 100, 0, TRUE, 197),
    ('Dog Dancing',        'https://drive.google.com/uc?export=download&id=1i5EKv2S01ARvRaZT2l3fIvQyhMOu4sFd',
     'LOTTIE', 'HAMMER', 'PREMIUM', 30::bigint, 30, 0, TRUE, 352),
    ('Dance',              'https://drive.google.com/uc?export=download&id=1vBB46I0BL-58G03kwqwf5EGpqUxq2vpQ',
     'LOTTIE', 'HAMMER', 'PREMIUM', 20::bigint, 10, 0, TRUE, 354),
    ('Cockroach',          'https://drive.google.com/uc?export=download&id=13Zw4aYOI2tF1ULv_HBpc7ovS7VKHQd6m',
     'LOTTIE', 'HAMMER', 'PREMIUM', 10::bigint, 15, 0, TRUE, 356)
  ) AS seed(name, asset_url, asset_format, currency, type, cost, duration_days, duration_hours, is_active, sort_order)
    ON CONFLICT (asset_url) DO NOTHING;


-- ========================================================= THE TABLE PICTURES
--
-- Every table picture the server seeds (owner, 15 Sep 2026), for the three
-- tables V1.0.0__baseline.sql's TABLE PICTURES section builds. They arrived as
-- V1.0.3__seed_table_pictures.sql on the table-pictures branch and were folded
-- in here on 23 Sep 2026 under the two-file rule. Data apart from structure,
-- as the profile pictures are: a price or a new table is a row here, never a
-- change to the DDL.
--
-- Idempotent like everything in this file: ON CONFLICT on the natural key
-- (day_asset_url) DO NOTHING, so a boot adds the rows a database lacks and
-- never rewrites one the owner has since re-priced, renamed, reordered or
-- retired. Editing a row a database already has is an UPDATE run there, not a
-- code change; a new picture appended here reaches every database at its
-- next boot.
--
-- THE TABLE PICTURES are the owner's own, hosted on Google Drive as the animated
-- profile pictures are (THE PICTURES above says how a Drive link becomes a URL a
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
--   Lines Background    1 lakh chips   7 days  sort_order 75  LOTTIE, on Drive
--   Background Pattern  5 lakh chips   7 days  sort_order 80  LOTTIE, on Drive
--   Welcome             1.5 lakh chips 7 days  sort_order 85  LOTTIE, on Drive
--   Thank You           30 lakh chips  7 days  sort_order 90  LOTTIE, on Drive
--   Circle Background Pattern  3 lakh chips  7 days  sort_order 95  LOTTIE, on Drive (one file, both themes)
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
-- owner in chips the next day (1 lakh for 7 days) — which a database that ran
-- the seed in between keeps as an UPDATE, the row being matched on
-- day_asset_url:
--
--   UPDATE table_pictures SET currency = 'COIN', cost = 100000, duration_days = 7
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
-- That gold reads on the dark ground and all but vanishes on the light one
-- (owner, 16 Sep 2026: "Thank you text not visible in Day mode"), so the
-- upload is the NIGHT file and the DAY file is the same Lottie with its 140
-- shape fills and its text fill in the light theme's deep gold (#8A6A18,
-- AppTheme.goldDeep) — "Thank You Day.json", the owner's upload to the same
-- folder, 729 KB, written by tools/tables/make_thank_you_day.py, which checks
-- that nothing else differs from the original (the twinkle's 7,722 per-frame
-- keyframes are kept as they are). It was seeded first with the original as
-- both files, and day_asset_url is the conflict key: a database that ran that
-- seed would take the changed row as a NEW picture and show two Thank Yous.
-- So this one change to a seeded row is in the script — the guarded UPDATE
-- below the header moves such a row onto the day file before the INSERT and
-- is a no-op everywhere else. (Lines Background's re-price above stays a hand
-- step: it does not touch the key.)

-- CIRCLE BACKGROUND PATTERN (owner, 24 Sep 2026: "LOTTIE COIN 300000 PREMIUM …
-- validity 7 Days") is a Lottie of three circles turning once every five
-- seconds over a pastel gradient — sky blue (#7DDBFF) through a grey-green to
-- peach (#FFBD81), the same gradient spinning inside each circle under a soft
-- white rim — on a 1920×1080 canvas (Lottie 5.5.8, 60 fps, 5 s, 3.6 KB), the
-- owner's own upload ("Circle Background Pattern .json", trailing space and
-- all, public). No 3D, no expressions, no text, no embedded images. Its
-- background rectangle is OPAQUE, so unlike the pictures above it brings its
-- own ground and reads the same on both themes: night_asset_url is the day
-- file, as Welcome's is. A 16:9 canvas is a scene, not a banner — the felt
-- crops it to the square around the pot (pictureFitFor / bannerAspect draw
-- the line at 2:1 since this row; Welcome, at 3.5:1, stays a banner drawn
-- above the plinth), which keeps the middle circle whole and halves the two
-- beside it. Appended after Thank You so the ids an empty database gives the
-- rows above stay what the header lists; sort_order 95 files it last on the
-- shelf. Sold for chips, so in the lobby only.

UPDATE table_pictures
   SET day_asset_url = 'https://drive.google.com/uc?export=download&id=19egvyPjBfCFbtEna7cL-_U1kQLVra6e8',
       updated_at    = (EXTRACT(EPOCH FROM now()) * 1000)::bigint
 WHERE name = 'Thank You'
   AND day_asset_url = 'https://drive.google.com/uc?export=download&id=1Iowysv9_-BE4qont-qLkZRi3XhfF6uc4';

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
     'LOTTIE', 'COIN', 'PREMIUM', 150000::bigint, 7, 0, TRUE, 85),
    ('Thank You',
     'https://drive.google.com/uc?export=download&id=19egvyPjBfCFbtEna7cL-_U1kQLVra6e8',
     'https://drive.google.com/uc?export=download&id=1Iowysv9_-BE4qont-qLkZRi3XhfF6uc4',
     'LOTTIE', 'COIN', 'PREMIUM', 3000000::bigint, 7, 0, TRUE, 90),
    -- Appended 24 Sep 2026 (owner); opaque, so one file serves both themes.
    ('Circle Background Pattern',
     'https://drive.google.com/uc?export=download&id=1Hx3AHsY2-8by89WIsxbPxpM64zL7kZps',
     'https://drive.google.com/uc?export=download&id=1Hx3AHsY2-8by89WIsxbPxpM64zL7kZps',
     'LOTTIE', 'COIN', 'PREMIUM', 300000::bigint, 7, 0, TRUE, 95)
  ) AS seed(name, day_asset_url, night_asset_url, asset_format, currency, type, cost, duration_days, duration_hours, is_active, sort_order)
    ON CONFLICT (day_asset_url) DO NOTHING;


-- ================================================================== THE TABLES
--
-- What a fresh database is given is exactly what the server composed from its
-- defaults before the catalogue existed — config.Defaults().Game
-- .EffectiveCatalogue(), with TABLE_CONFIG_SOURCE unset and no table env key:
--
--   * the taxonomy (owner, 23 Sep 2026: "Teen Patti engines / Poker
--     engines"): two engines, Teen Patti and Poker, and the seven categories,
--     flat, each under exactly one of them — seen, blind and variation under
--     Teen Patti, three_card_poker, five_card_draw, texas_holdem and omaha
--     under Poker (config.DefaultTableEngines, DefaultTableCategories);
--   * the settings row: a 200 boot when a quick-join names none, the stakes
--     200 / 5,000 / 50,000 / 20 Lakh (owner, 27 Sep 2026: "Change 10 Lakh
--     boot table to 20Lakh boot table"), five seats and two to start, the 25 s
--     turn, 20 rounds and the 6 s sideshow as advertised, and requirement 30's
--     entry cap — nobody holding more than 20 Lakh sits at the 200 blind
--     table (owner, 27 Sep 2026: "for blind 200 keep the entry upto 20 lakh";
--     5 Lakh before, which a new account's 10 Lakh welcome would have outgrown);
--   * the twelve tables of the default LOBBY_TABLES menu, in its order
--     (sort_order 10 to 120), each with its stack band;
--   * a private template for each of the seven categories (sort_order 1010 to
--     1070), the table room:create opens: boot 200, two rungs, a 5 Lakh pot
--     cap at Teen Patti.
--
-- Every figure is resolved as TableRules and the poker knobs resolved it. Seen:
-- two rungs, seven rounds, a per-bet ceiling of 1024 boots and a 20 Lakh pot
-- cap, unless the table has its own (seen 50,000: 5 Crore). Blind: no limit
-- anywhere. Variation: at a public table a blind table's betting — no raise
-- limit, no round cap, no per-bet ceiling (owner, 28 Sep 2026: "no limit on
-- chaal if a player has money"; seen's two rungs and seven rounds before, which
-- a database seeded before then keeps until its rows are changed by hand,
-- ops/DEPLOY.md) — and no pot cap; the private template keeps two rungs. Every
-- variation table: the 10 s chooser's window and the 8 s 5-Card pick. Poker: a
-- 25 s clock, a buy-in of ten boots, three cards to exchange (only 5-Card Draw
-- reads it), and none of Teen Patti's figures.
-- Every table: three missed turns before the idle kick, a 4 s pause between
-- hands, 30 s to buy chips before a short seat is kicked; every Teen Patti
-- table, four blind moves and 3 s more after a missile. Every public Seen,
-- Blind and Variation table TAXES ITS WINNERS (winner_tax; owner, 26 Sep
-- 2026, and 27 Sep 2026: "Apply this tax rule on all the tables, blind, seen,
-- variation", then "tax will be on total pot amount - amount player
-- contributed … 30 lakh is the limit on winning amount not on pot limit", and
-- then "no tax for winning amount less than 50 Lakh"): the winner of each
-- hand pays their rate (THE PLAYER LEVELS, below) of what they won — the pot
-- less their own contribution — on winnings of 50,00,000 or more
-- (tax_min_winnings). No private template — its pot stops at 5 Lakh — and no
-- poker room does.
-- This build goes onto a FRESH database (owner, 26 Sep 2026), which these rows
-- seed.
--
-- The VALUES below were GENERATED from that composition, and
-- TestTheSeededTableCatalogueIsTheDefaults loads them back out of a fresh
-- schema and compares them with it figure by figure — so a server switched to
-- TABLE_CONFIG_SOURCE=db on this seed plays exactly as one on the defaults
-- did. A default changed in config without this file fails that test, which
-- names the table.
--
-- ACTIVE ONLY INTO AN EMPTY TABLE. Each table_configs INSERT first asks
-- whether the table already holds a row of its kind — public, or private — and
-- writes every row it adds with is_active set to that answer:
--
--   * a fresh database gets every row, active;
--   * a row appended here in a later release reaches an existing database at
--     its next boot INACTIVE: a new table goes live when the owner sets
--     is_active = TRUE, after raising MIN_CLIENT_BUILD to a build that can draw
--     it — the way variation and poker were rolled out — never because a
--     server restarted;
--   * a row already there is never touched (ON CONFLICT (table_key) DO
--     NOTHING), so an owner's UPDATE survives every restart;
--   * a seeded row that was DELETEd, or re-keyed by changing its category or
--     boot, comes back at the next boot — inactive, so harmlessly. Retire a
--     table with is_active = FALSE, never with DELETE.
--
-- The settings row is written only where there is none (ON CONFLICT (id) DO
-- NOTHING); change it with an UPDATE.
--
-- The engines and categories come first — every other row here names a
-- category, through a foreign key — and are written ACTIVE wherever their code
-- is missing, on a fresh database and an existing one alike (ON CONFLICT
-- (code) DO NOTHING, so a name, a place or an is_active the owner has changed
-- stays changed). Active is safe there: a category puts nothing in front of a
-- player by itself, and the tables that would are the table_configs rows
-- below, which arrive inactive in a catalogue that already has tables. A new
-- engine or category is a row appended here — and code in the server, which
-- leaves out a category it cannot play (V1.0.0's TABLE CONFIGURATION).
--
-- A deployment whose .env configures its tables (LOBBY_TABLES and the rest of
-- config.TableEnvKeys) gets the DEFAULT catalogue from this file, not its own.
-- Before switching one to TABLE_CONFIG_SOURCE=db, run
-- `TABLE_CONFIG_SOURCE=env ./bin/gameplay -export-table-config | psql …` with
-- that .env: it writes the menu the deployment plays today over these rows
-- (db.ExportTableConfigSQL). Either way the server reads the catalogue once, at
-- boot, so an edit applies after the next restart, to the tables opened after
-- it (V1.0.0's TABLE CONFIGURATION).

-- The engines, then the categories under them, in config.Categories order.
INSERT INTO table_engines (code, name, sort_order, is_active)
VALUES ('teen_patti', 'Teen Patti', 10, TRUE),
       ('poker',      'Poker',      20, TRUE)
    ON CONFLICT (code) DO NOTHING;

INSERT INTO table_categories (code, engine, name, sort_order, is_active)
VALUES ('seen',             'teen_patti', 'Seen',           10, TRUE),
       ('blind',            'teen_patti', 'Blind',          20, TRUE),
       ('variation',        'teen_patti', 'Variation',      30, TRUE),
       ('three_card_poker', 'poker',      '3-Card Poker',   40, TRUE),
       ('five_card_draw',   'poker',      '5-Card Draw',    50, TRUE),
       ('texas_holdem',     'poker',      'Texas Hold''em', 60, TRUE),
       ('omaha',            'poker',      'Omaha',          70, TRUE)
    ON CONFLICT (code) DO NOTHING;

INSERT INTO table_settings (id, default_boot_amount, stakes, max_players, min_players, turn_timeout_ms,
                            max_bet_rounds, sideshow_timeout_ms, sideshow_min_players,
                            entry_cap_boot, entry_cap_category, entry_cap_max_chips)
VALUES (1, 200, ARRAY[200, 5000, 50000, 2000000]::bigint[], 5, 2, 25000,
        20, 6000, 3,
        200, 'blind', 2000000)
    ON CONFLICT (id) DO NOTHING;

-- The public tables: the default menu, in LOBBY_TABLES order. The column names
-- over the rows are shortened; v(…) at the foot names each in full.
WITH fresh AS (SELECT NOT EXISTS (SELECT 1 FROM table_configs WHERE NOT is_private) AS empty)
INSERT INTO table_configs (category, boot_amount, is_private, min_chips, max_chips,
                           max_pot, max_raise_steps, max_bet_rounds, pot_limit_multiplier, max_blind_moves,
                           turn_timeout_ms, max_missed_turns, sideshow_timeout_ms, sideshow_min_players,
                           next_hand_delay_ms, unfunded_grace_ms, missile_reveal_extra_ms,
                           variation_select_timeout_ms, five_card_pick_timeout_ms, min_buy_in, max_discards,
                           winner_tax, tax_min_winnings, sort_order, is_active)
SELECT v.category, v.boot_amount, FALSE, v.min_chips, v.max_chips,
       v.max_pot, v.max_raise_steps, v.max_bet_rounds, v.pot_limit_multiplier, v.max_blind_moves,
       v.turn_timeout_ms, v.max_missed_turns, v.sideshow_timeout_ms, v.sideshow_min_players,
       v.next_hand_delay_ms, v.unfunded_grace_ms, v.missile_reveal_extra_ms,
       v.variation_select_timeout_ms, v.five_card_pick_timeout_ms, v.min_buy_in, v.max_discards,
       v.winner_tax, v.tax_min_winnings, v.sort_order, fresh.empty
  FROM (VALUES
    -- category          boot         min_chips  max_chips   max_pot          steps rounds ceiling       blind turn   missed side  side_min next  grace  missile select pick  buy_in     disc tax       tax_min   sort
    ('seen',             200::bigint, 0::bigint, 0::bigint,  2000000::bigint, 2,    7,     1024::bigint, 4,    25000, 3,     6000, 3,       4000, 30000, 3000,   0,     0,    0::bigint, 0,   TRUE::boolean, 5000000::bigint, 10),
    ('blind',            200,         0,         0,          0,               0,    0,     0,            4,    25000, 3,     6000, 3,       4000, 30000, 3000,   0,     0,    0,         0,   TRUE,     5000000,  20),
    ('blind',            5000,        0,         200000000,  0,               0,    0,     0,            4,    25000, 3,     6000, 3,       4000, 30000, 3000,   0,     0,    0,         0,   TRUE,     5000000,  30),
    ('blind',            50000,       0,         2000000000, 0,               0,    0,     0,            4,    25000, 3,     6000, 3,       4000, 30000, 3000,   0,     0,    0,         0,   TRUE,     5000000,  40),
    ('blind',            2000000,     500000000, 0,          0,               0,    0,     0,            4,    25000, 3,     6000, 3,       4000, 30000, 3000,   0,     0,    0,         0,   TRUE,     5000000,  50),
    ('variation',        50000,       0,         2000000000, 0,               0,    0,     0,            4,    25000, 3,     6000, 3,       4000, 30000, 3000,   10000, 8000, 0,         0,   TRUE,     5000000,  60),
    ('variation',        2000000,     500000000, 0,          0,               0,    0,     0,            4,    25000, 3,     6000, 3,       4000, 30000, 3000,   10000, 8000, 0,         0,   TRUE,     5000000,  70),
    ('seen',             50000,       0,         0,          50000000,        2,    7,     1024,         4,    25000, 3,     6000, 3,       4000, 30000, 3000,   0,     0,    0,         0,   TRUE,     5000000,  80),
    ('three_card_poker', 50000,       0,         0,          0,               0,    0,     0,            0,    25000, 3,     0,    0,       4000, 30000, 0,      0,     0,    500000,    3,   FALSE,    0,        90),
    ('five_card_draw',   50000,       0,         0,          0,               0,    0,     0,            0,    25000, 3,     0,    0,       4000, 30000, 0,      0,     0,    500000,    3,   FALSE,    0,        100),
    ('texas_holdem',     50000,       0,         0,          0,               0,    0,     0,            0,    25000, 3,     0,    0,       4000, 30000, 0,      0,     0,    500000,    3,   FALSE,    0,        110),
    ('omaha',            50000,       0,         0,          0,               0,    0,     0,            0,    25000, 3,     0,    0,       4000, 30000, 0,      0,     0,    500000,    3,   FALSE,    0,        120)
  ) AS v(category, boot_amount, min_chips, max_chips,
         max_pot, max_raise_steps, max_bet_rounds, pot_limit_multiplier, max_blind_moves,
         turn_timeout_ms, max_missed_turns, sideshow_timeout_ms, sideshow_min_players,
         next_hand_delay_ms, unfunded_grace_ms, missile_reveal_extra_ms,
         variation_select_timeout_ms, five_card_pick_timeout_ms, min_buy_in, max_discards,
         winner_tax, tax_min_winnings, sort_order)
 CROSS JOIN fresh
    ON CONFLICT (table_key) DO NOTHING;

-- The private templates, one per category, in config.Categories order. Asked
-- about separately: an existing catalogue with public tables but no templates
-- still gets every template, active.
WITH fresh AS (SELECT NOT EXISTS (SELECT 1 FROM table_configs WHERE is_private) AS empty)
INSERT INTO table_configs (category, boot_amount, is_private, min_chips, max_chips,
                           max_pot, max_raise_steps, max_bet_rounds, pot_limit_multiplier, max_blind_moves,
                           turn_timeout_ms, max_missed_turns, sideshow_timeout_ms, sideshow_min_players,
                           next_hand_delay_ms, unfunded_grace_ms, missile_reveal_extra_ms,
                           variation_select_timeout_ms, five_card_pick_timeout_ms, min_buy_in, max_discards,
                           winner_tax, tax_min_winnings, sort_order, is_active)
SELECT v.category, v.boot_amount, TRUE, v.min_chips, v.max_chips,
       v.max_pot, v.max_raise_steps, v.max_bet_rounds, v.pot_limit_multiplier, v.max_blind_moves,
       v.turn_timeout_ms, v.max_missed_turns, v.sideshow_timeout_ms, v.sideshow_min_players,
       v.next_hand_delay_ms, v.unfunded_grace_ms, v.missile_reveal_extra_ms,
       v.variation_select_timeout_ms, v.five_card_pick_timeout_ms, v.min_buy_in, v.max_discards,
       v.winner_tax, v.tax_min_winnings, v.sort_order, fresh.empty
  FROM (VALUES
    -- category          boot         min_chips  max_chips  max_pot         steps rounds ceiling       blind turn   missed side  side_min next  grace  missile select pick  buy_in     disc tax       tax_min   sort
    ('seen',             200::bigint, 0::bigint, 0::bigint, 500000::bigint, 2,    7,     1024::bigint, 4,    25000, 3,     6000, 3,       4000, 30000, 3000,   0,     0,    0::bigint, 0,   FALSE::boolean, 0::bigint, 1010),
    ('blind',            200,         0,         0,         500000,         2,    0,     0,            4,    25000, 3,     6000, 3,       4000, 30000, 3000,   0,     0,    0,         0,   FALSE,    0,        1020),
    ('variation',        200,         0,         0,         500000,         2,    0,     0,            4,    25000, 3,     6000, 3,       4000, 30000, 3000,   10000, 8000, 0,         0,   FALSE,    0,        1030),
    ('three_card_poker', 200,         0,         0,         0,              0,    0,     0,            0,    25000, 3,     0,    0,       4000, 30000, 0,      0,     0,    2000,      3,   FALSE,    0,        1040),
    ('five_card_draw',   200,         0,         0,         0,              0,    0,     0,            0,    25000, 3,     0,    0,       4000, 30000, 0,      0,     0,    2000,      3,   FALSE,    0,        1050),
    ('texas_holdem',     200,         0,         0,         0,              0,    0,     0,            0,    25000, 3,     0,    0,       4000, 30000, 0,      0,     0,    2000,      3,   FALSE,    0,        1060),
    ('omaha',            200,         0,         0,         0,              0,    0,     0,            0,    25000, 3,     0,    0,       4000, 30000, 0,      0,     0,    2000,      3,   FALSE,    0,        1070)
  ) AS v(category, boot_amount, min_chips, max_chips,
         max_pot, max_raise_steps, max_bet_rounds, pot_limit_multiplier, max_blind_moves,
         turn_timeout_ms, max_missed_turns, sideshow_timeout_ms, sideshow_min_players,
         next_hand_delay_ms, unfunded_grace_ms, missile_reveal_extra_ms,
         variation_select_timeout_ms, five_card_pick_timeout_ms, min_buy_in, max_discards,
         winner_tax, tax_min_winnings, sort_order)
 CROSS JOIN fresh
    ON CONFLICT (table_key) DO NOTHING;


-- ============================================================== THE LUCKY DRAW
--
-- The owner's draw (24 Sep 2026: "for now you can use this lucky draw insert
-- query"), BEGINNER_LUCKY_DRAW: a spin every three days — 259,200,000 ms after
-- a player's last one — on a wheel of six slots, numbered clockwise from the
-- top:
--
--   slot  prize                weight
--   1     1 hammer                25
--   2     4 hammers               15
--   3     10,00,000 chips         20
--   4     1,00,000 chips          20
--   5     no reward               10
--   6     5,00,000 chips          10
--
-- The weights add up to 100 only so they read as percentages; the server draws
-- by each active slot's share of whatever they add up to (db.pickWeighted). A
-- request that names no draw gets the first active one in sort_order, which is
-- this one. PROFILE_PICTURE and TABLE_PICTURE prizes are supported but not in
-- this draw: a slot names its picture's catalogue id in reward_ref_id, looked
-- up by the row's natural key rather than written as a number, because
-- BIGSERIAL ids differ between databases (every ON CONFLICT DO NOTHING above
-- takes a sequence value even when it inserts nothing) —
--
--   UPDATE lucky_draw_slots SET reward_type = 'PROFILE_PICTURE', reward_value = NULL,
--          reward_ref_id = (SELECT id::text FROM profile_pictures WHERE name = 'Lovestruck Cat')
--    WHERE slot_number = 5 AND lucky_draw_id = (SELECT id FROM lucky_draws WHERE code = 'BEGINNER_LUCKY_DRAW');
--
-- Written only where missing, like everything in this file — ON CONFLICT
-- (code) for the draw, (lucky_draw_id, slot_number) for a slot — so an owner's
-- UPDATE survives every restart, and a change to a row here reaches only a
-- fresh database. The server reads the draw on each request, so an edit is on
-- the wheel at the next look; retire a slot with is_active = FALSE, never
-- DELETE — the spins that won it point at it.

-- ============================================================
-- BEGINNER LUCKY DRAW
-- Cooldown: 3 days
-- ============================================================

INSERT INTO lucky_draws (
    code,
    name,
    spinner_type,
    cooldown_ms,
    is_active,
    sort_order
)
VALUES (
    'BEGINNER_LUCKY_DRAW',
    'Beginner Lucky Draw',
    'BEGINNER',
    259200000, -- 3 days
    TRUE,
    10
)
ON CONFLICT (code) DO NOTHING;


-- ============================================================
-- 6 REWARD SLOTS
-- ============================================================

INSERT INTO lucky_draw_slots (
    lucky_draw_id,
    slot_number,
    reward_type,
    reward_value,
    reward_ref_id,
    weight,
    is_active,
    sort_order
)
SELECT
    ld.id,
    v.slot_number,
    v.reward_type,
    v.reward_value,
    NULL,
    v.weight,
    TRUE,
    v.slot_number
FROM lucky_draws ld
CROSS JOIN (
    VALUES
        (1, 'HAMMER', 1::BIGINT,       25),
        (2, 'HAMMER', 4::BIGINT,       15),
        (3, 'CHIPS',  1000000::BIGINT, 20),
        (4, 'CHIPS',  100000::BIGINT,  20),
        (5, 'NO_REWARD', 0::BIGINT,    10),
        (6, 'CHIPS',  500000::BIGINT,  10)
) AS v(slot_number, reward_type, reward_value, weight)
WHERE ld.code = 'BEGINNER_LUCKY_DRAW'
ON CONFLICT (lucky_draw_id, slot_number) DO NOTHING;

-- ================================================================= THE EMOJIS
--
-- Every emoji the server seeds (owner, 26 Sep 2026), for the two tables
-- V1.0.0__baseline.sql's EMOJIS section builds. An emoji is bought like a
-- profile picture and SENT at a table, where it plays over the sender's seat
-- for everyone there (chat:emoji). The owner's own art only, hosted in the
-- owner's Drive folder as the animated pictures are (THE PICTURES says how a
-- Drive link becomes a URL a client can load); every row is a Lottie.
--
-- Idempotent like everything in this file: ON CONFLICT on the natural key
-- (asset_url) DO NOTHING, so a boot adds the rows a database lacks and never
-- rewrites one the owner has since re-priced, renamed, reordered or retired.
-- Editing a row a database already has is an UPDATE run there; a new emoji
-- appended here reaches every database at its next boot.
--
--   Angry                       5 hammers  30 days  sort_order  10  "Emoji Angry.json", 480x480, 60 fps, 1.85 s
--   Dollar                      5 hammers  30 days  sort_order  20  "Dollar Emoji.json", 750x750, 25 fps, 2.04 s
--   Crying                      5 hammers  30 days  sort_order  30  "Emoji Crying.json", 480x480, 60 fps, 1.55 s
--   Hi Face                     5 hammers  30 days  sort_order  40  "Hi Face Emoji.json", 512x512, 60 fps, 2.17 s
--   Clapping Hands              5 hammers  30 days  sort_order  50  "Clapping Hands Emoji.json", 512x512, 60 fps, 2.00 s
--   Cowboy Hat Face             5 hammers  30 days  sort_order  60  "Cowboy Hat Face Emoji.json", 512x512, 60 fps, 3.00 s
--   Muscle                      5 hammers  30 days  sort_order  70  "Muscle Emoji.json", 512x512, 60 fps, 3.00 s
--   Plane Face                  5 hammers  30 days  sort_order  80  "Plane Face Emoji.json", 512x512, 60 fps, 2.52 s
--   Knife                       5 hammers  30 days  sort_order  90  "Knife Emoji.json", 500x500, 60 fps, 4.00 s
--   Sleeping                    5 hammers  30 days  sort_order 100  "Emoji Sleeping.json", 480x480, 60 fps, 0.60 s
--   Squinting Face with Tongue  5 hammers  30 days  sort_order 110  "Squinting Face with Tongue Emoji.json", 500x500, 60 fps, 2.33 s
--   Crying Face                 5 hammers  30 days  sort_order 120  "Crying Face Emoji.json", 512x512, 60 fps, 2.40 s
--   Enraged Face                5 hammers  30 days  sort_order 130  "Enraged Face Emoji.json", 500x500, 60 fps, 2.33 s
--   Chill Face                  5 hammers  30 days  sort_order 140  "Chill Face Emoji.json", 512x512, 60 fps, 2.70 s
--   Face Blowing a Kiss         5 hammers  30 days  sort_order 150  "Face Blowing A Kiss Emoji.json", 512x512, 60 fps, 2.00 s
--   Kiss Face                   5 hammers  30 days  sort_order 160  "Kiss Face Emoji.json", 512x512, 60 fps, 3.00 s
--   Ok                          5 hammers  30 days  sort_order 170  "Ok Emoji.json", 512x512, 60 fps, 1.53 s
--   No Face                     5 hammers  30 days  sort_order 180  "No Face Emoji.json", 512x512, 60 fps, 2.22 s
--   Tongue Face                 5 hammers  30 days  sort_order 190  "Tongue Face Emoji.json", 512x512, 60 fps, 0.73 s
--
-- None has a 3D layer, an expression, an embedded image or a text layer —
-- what a phone's Lottie player cannot draw (CLAUDE.md §12.3).
INSERT INTO emojis (name, asset_url, asset_format, currency, type, cost, duration_days, duration_hours, is_active, sort_order, created_at, updated_at)
SELECT name, asset_url, 'LOTTIE', currency, type, cost, duration_days, 0, TRUE, sort_order,
       (EXTRACT(EPOCH FROM now()) * 1000)::bigint,
       (EXTRACT(EPOCH FROM now()) * 1000)::bigint
  FROM (VALUES
    ('Angry',
     'https://drive.google.com/uc?export=download&id=19CkeJfl8J9knw0tLoxgruKFaGwnsP3jh',
     'HAMMER', 'PREMIUM', 5::bigint, 30, 10),
    ('Dollar',
     'https://drive.google.com/uc?export=download&id=1HZej1y15g4FhGKjNPbR2WOqFdDXn-r5l',
     'HAMMER', 'PREMIUM', 5::bigint, 30, 20),
    ('Crying',
     'https://drive.google.com/uc?export=download&id=1iTOgg_JZRXvY9f9IRPaAR9UyEt4q7f4S',
     'HAMMER', 'PREMIUM', 5::bigint, 30, 30),
    ('Hi Face',
     'https://drive.google.com/uc?export=download&id=1qpBgQTwXWMvrHqQLAA6wT1EIsNb9zakr',
     'HAMMER', 'PREMIUM', 5::bigint, 30, 40),
    ('Clapping Hands',
     'https://drive.google.com/uc?export=download&id=1_wnZ9Tmiy7qnK7EzmK5hpSPZCOTxvjlc',
     'HAMMER', 'PREMIUM', 5::bigint, 30, 50),
    ('Cowboy Hat Face',
     'https://drive.google.com/uc?export=download&id=141HlEZZxoRuIzAaN16emiNO7UZ7RWYNn',
     'HAMMER', 'PREMIUM', 5::bigint, 30, 60),
    ('Muscle',
     'https://drive.google.com/uc?export=download&id=199f59nq4Vx0FImGvbAv4X2LJnkyUQ67f',
     'HAMMER', 'PREMIUM', 5::bigint, 30, 70),
    ('Plane Face',
     'https://drive.google.com/uc?export=download&id=1Y3WEnboXZskv6vItBQ_E1WZoC9aIUh8D',
     'HAMMER', 'PREMIUM', 5::bigint, 30, 80),
    ('Knife',
     'https://drive.google.com/uc?export=download&id=1lLryjoIf2KNGqZFGxGX8vGThozJM0vw-',
     'HAMMER', 'PREMIUM', 5::bigint, 30, 90),
    ('Sleeping',
     'https://drive.google.com/uc?export=download&id=1bC-1hqYUblHCjiTvAd6OT8xHYYbj9sKC',
     'HAMMER', 'PREMIUM', 5::bigint, 30, 100),
    ('Squinting Face with Tongue',
     'https://drive.google.com/uc?export=download&id=1MwoBkG2OIUbHVwu_Jrp4d1VjsJyPb9Y7',
     'HAMMER', 'PREMIUM', 5::bigint, 30, 110),
    ('Crying Face',
     'https://drive.google.com/uc?export=download&id=1NbIZ7Uix45KCEencp5cvX6aDisiEfhqi',
     'HAMMER', 'PREMIUM', 5::bigint, 30, 120),
    ('Enraged Face',
     'https://drive.google.com/uc?export=download&id=1C_zU11KCYX8vaGC04TQgC68cE2TYXHWt',
     'HAMMER', 'PREMIUM', 5::bigint, 30, 130),
    ('Chill Face',
     'https://drive.google.com/uc?export=download&id=1kvwY307kfud4L9SjaZCLzO0mLOZ9pRYR',
     'HAMMER', 'PREMIUM', 5::bigint, 30, 140),
    ('Face Blowing a Kiss',
     'https://drive.google.com/uc?export=download&id=1K7mIif6FpaHl06j1VFkPB8awW21zz-wf',
     'HAMMER', 'PREMIUM', 5::bigint, 30, 150),
    ('Kiss Face',
     'https://drive.google.com/uc?export=download&id=1oLtnFWg0dd75cuPebF5i0IHuynRnJlp2',
     'HAMMER', 'PREMIUM', 5::bigint, 30, 160),
    ('Ok',
     'https://drive.google.com/uc?export=download&id=1YnSphiJ7STpuHng9ACqPjwxWFSD4ex6t',
     'HAMMER', 'PREMIUM', 5::bigint, 30, 170),
    ('No Face',
     'https://drive.google.com/uc?export=download&id=1MWQZiwQMIqDtJcfqBEaB7PcgQ0Py4x8t',
     'HAMMER', 'PREMIUM', 5::bigint, 30, 180),
    ('Tongue Face',
     'https://drive.google.com/uc?export=download&id=1htRt4pDieoOmUJtBPf-FtXb5OK7nPyz8',
     'HAMMER', 'PREMIUM', 5::bigint, 30, 190)
  ) AS v(name, asset_url, currency, type, cost, duration_days, sort_order)
ON CONFLICT (asset_url) DO NOTHING;


-- ========================================================== THE PLAYER LEVELS
--
-- The owner's level ladder (26 Sep 2026: "create table which stores every
-- player xp and ac to their level, tax will be applied, use below table"),
-- with the tax bracket the owner gave on 27 Sep 2026 ("use this tax
-- bracket"), exactly as given: Level 1 at 0 XP, Newbie, 20.00% winning tax,
-- down to Level 50 at 20,00,000 XP, King of Kings, 6.00% — an even 28.57
-- points a level, rounded to the basis point. tax_bps is basis points
-- (2000 = 20.00%). A badge is not a level (owner, 27 Sep 2026: "Vip is not a
-- level, it is badge"): the badges follow the ladder. Each level's icon is the owner's
-- emoji ("use these icons for each tag"), byte for byte: keep the U+FE0F
-- variation selectors, and some icons are two emoji
-- (TestTheSeededLevelsAreTheOwnersTable compares every one code point for
-- code point).
--
-- Written only where the level is missing (ON CONFLICT (level) DO NOTHING),
-- so an owner's UPDATE — a re-priced tax, a renamed title, a moved threshold —
-- survives every restart, and a changed row here reaches only a fresh
-- database (the picture rule, THE PICTURES).
INSERT INTO player_levels (level, min_xp, title, icon, tax_bps)
VALUES
  (1,  0,       'Newbie',           '🌱',   2000),
  (2,  100,     'Rookie',           '🔰',   1971),
  (3,  250,     'Beginner',         '⭐',   1943),
  (4,  500,     'Player',           '🎮',   1914),
  (5,  800,     'Regular',          '🟢',   1886),
  (6,  1200,    'Challenger',       '⚔️',  1857),
  (7,  1700,    'Skilled',          '🎯',   1829),
  (8,  2300,    'Contender',        '🛡️',  1800),
  (9,  3000,    'Fighter',          '⚔️',  1771),
  (10, 4000,    'Rising Star',      '🌟',   1743),
  (11, 5200,    'Pro Player',       '🏅',   1714),
  (12, 6700,    'Veteran',          '🎖️',  1686),
  (13, 8500,    'Expert',           '🧠',   1657),
  (14, 10500,   'Specialist',       '💠',   1629),
  (15, 13000,   'Ace',              '🃏',   1600),
  (16, 16000,   'Elite',            '💎',   1571),
  (17, 20000,   'Master',           '👑',   1543),
  (18, 25000,   'Grand Master',     '👑⚔️', 1514),
  (19, 31000,   'Champion',         '🏆',   1486),
  (20, 38000,   'High Roller',      '💰',   1457),
  (21, 46000,   'Royal',            '👑',   1429),
  (22, 55000,   'Royal Ace',        '🃏👑',  1400),
  (23, 65000,   'Royal Master',     '👑💎',  1371),
  (24, 76000,   'Supreme',          '🔱',   1343),
  (25, 88000,   'Supreme Ace',      '🔱🃏',  1314),
  (26, 102000,  'Legend',           '🌠',   1286),
  (27, 118000,  'Legendary',        '✨',   1257),
  (28, 136000,  'Grand Legend',     '🌟👑',  1229),
  (29, 156000,  'Immortal',         '♾️',  1200),
  (30, 178000,  'Titan',            '⚡',   1171),
  (31, 202000,  'Elite Titan',      '⚡💎',  1143),
  (32, 228000,  'Royal Titan',      '⚡👑',  1114),
  (33, 256000,  'Emperor',          '👑',   1086),
  (34, 286000,  'Royal Emperor',    '👑💎',  1057),
  (35, 318000,  'Supreme Emperor',  '🔱👑',  1029),
  (36, 352000,  'King',             '👑',   1000),
  (37, 390000,  'Grand King',       '👑🏆',  971),
  (38, 432000,  'Royal King',       '👑💎',  943),
  (39, 478000,  'Supreme King',     '🔱👑',  914),
  (40, 528000,  'Master King',      '👑⚔️', 886),
  (41, 585000,  'Overlord',         '🔥',   857),
  (42, 650000,  'Grand Overlord',   '🔥👑',  829),
  (43, 725000,  'Royal Overlord',   '🔥💎',  800),
  (44, 810000,  'Supreme Overlord', '🔥🔱',  771),
  (45, 900000,  'Mythic',           '🌌',   743),
  (46, 1000000, 'Mythic King',      '🌌👑',  714),
  (47, 1150000, 'Immortal King',    '♾️👑', 686),
  (48, 1350000, 'Legendary King',   '🌟👑',  657),
  (49, 1600000, 'Supreme Legend',   '🔱🌟',  629),
  (50, 2000000, 'King of Kings',    '👑👑',  600)
    ON CONFLICT (level) DO NOTHING;

-- Each level's ART (owner, 29 Sep 2026: "Instead of using icons use lottie
-- animations json for showing player Level … if there is no url, you show
-- empty icon … meanwhile i will provide u other urls for level"): the owner's
-- Lotties, as each arrives. A level missing here keeps asset_url NULL and the
-- app shows an empty mark in its place.
--
-- Filled only where asset_url IS NULL, so it reaches a database whose ladder
-- was seeded before the art existed (production's) and every URL added to
-- this list later reaches every database at its next boot — while an owner's
-- own URL, or '' for a level deliberately shown with none, is never touched.
--
-- Every level but Level 1 is the owner's Drive upload as given, each checked
-- for what a phone cannot play (CLAUDE.md §12.3): no 3D, no image or font
-- fetched from elsewhere (Player's three WebP images and Expert's six glyphs
-- are in their files), and no expression a phone would miss — Contender's
-- three inertial-bounce expressions only overshoot scale keyframes that
-- play, as Sporty Avocado's "Kleaner" ones do.
-- Level 1's upload (350x350, 4 s) swings its leaves with two
-- loopOut('pingpong') expressions over frames 0–20 of 101, which the phones'
-- player does not run (CLAUDE.md §12.3): they would sway for 0.8 s and hold
-- still for the other 3.2 s of every loop. So Level 1 is served from this
-- server as the copy tools/lottie/bake_loop_expressions.py wrote, the loop
-- written out as keyframes (public/levels/, served in production like
-- profiles/); its "Kleaner" overshoot, which no phone runs either, is left as
-- it is.
UPDATE player_levels AS l
   SET asset_url    = v.url,
       asset_format = 'LOTTIE',
       updated_at   = (EXTRACT(EPOCH FROM now()) * 1000)::bigint
  FROM (VALUES
         (1, '/levels/newbie.json'),
         (2, 'https://drive.google.com/uc?export=download&id=1X5ONeIYMh2Q6348MsQGU9YO1Ut9j0RjR'),
         (3, 'https://drive.google.com/uc?export=download&id=1046FnHvyBeXHRzuQAyflU-Z994XLMuZG'),
         (4, 'https://drive.google.com/uc?export=download&id=1UteuLgAVMFKBXSDGtMs_7LCJKixrZhP8'),
         (5, 'https://drive.google.com/uc?export=download&id=1o0Ch-l1nosmMomDocrKO061DnCAIOOcR'),
         (6, 'https://drive.google.com/uc?export=download&id=1JBH14iM0z78skBTliTzYlU1aHl3-c6S2'),
         (7, 'https://drive.google.com/uc?export=download&id=16LUCeHS--xT7pWcup9xWLOzI7slpIDba'),
         (8, 'https://drive.google.com/uc?export=download&id=1DVOEYt6eBhpjhfYqNI-0XTzAXmWsDg7c'),
         (9, 'https://drive.google.com/uc?export=download&id=1-oNEE7AIBgDltplByb_hUT4TjyNU4TQ8'),
         (10, 'https://drive.google.com/uc?export=download&id=11E2kIWN-I3d1Df_ZiikOlbfJVR8bCkkd'),
         (11, 'https://drive.google.com/uc?export=download&id=1uPdZgu0zaHe3Cxev7RxRFe5bdDFJ9uax'),
         (12, 'https://drive.google.com/uc?export=download&id=1v7t6TppF5xMO1tHiZaUiM0Vk_hWDtpru'),
         (13, 'https://drive.google.com/uc?export=download&id=1p-DiB6Ywhwg9nu1o22MoObJU4dp5pQa2'),
         (14, 'https://drive.google.com/uc?export=download&id=12TiIf1ghpANIC9CTpHN7-DPgSjqCekN7'),
         (15, 'https://drive.google.com/uc?export=download&id=1KbguHCl0hnDNPiD5mC4WBUqfjoNqrXHO'),
         (16, 'https://drive.google.com/uc?export=download&id=1St9AZX05qFedF40zf0rZhQ6ATFTkCytQ'),
         (17, 'https://drive.google.com/uc?export=download&id=1ec87R_lGM3EZHXAVIhjt0eYDslLzKk95'),
         (18, 'https://drive.google.com/uc?export=download&id=1fq3eVEu739XZBBN5Jkt_m4TLc_P5zIUK'),
         (19, 'https://drive.google.com/uc?export=download&id=1_agD2lEmfPN-sQcgm853aqwG9ujd0R2K'),
         (20, '/levels/high-roller.json'),
         (21, 'https://drive.google.com/uc?export=download&id=1UNCYMfWQ1FNKW_4skDQefTTPvP7lr_ja'),
         (22, '/levels/royal-ace.json'),
         (23, 'https://drive.google.com/uc?export=download&id=1SkpRRudplWyT7IKEpOAucp0UPrrQG9iZ'),
         (24, 'https://drive.google.com/uc?export=download&id=1tStW2xVARGhsutKETNaJna5gj4opBSAv'),
         (25, '/levels/supreme-ace.json'),
         (26, 'https://drive.google.com/uc?export=download&id=1_aeUxyPcY8y8vjS5XCGle2GVJ58H1W_S'),
         (27, 'https://drive.google.com/uc?export=download&id=1JJf7FXDtLbABcU6QV4dDC3AjTaB42d9G'),
         (28, 'https://drive.google.com/uc?export=download&id=1waubm1JDH69aO-Wi_SJ2NPU2LuhAmLul'),
         (29, 'https://drive.google.com/uc?export=download&id=1IQv0oHWum_kyAvvuNLhvV6UsiEdf7u8S'),
         (30, 'https://drive.google.com/uc?export=download&id=1NVhpS0i9DiahWamLqOsqlCPh9FpJEgqZ'),
         (31, 'https://drive.google.com/uc?export=download&id=1t5mpo6BYOrECuoRAsPTgAmwTJEGSwH9Z'),
         (32, '/levels/royal-titan.json'),
         (33, 'https://drive.google.com/uc?export=download&id=1wLDxV_GkYrhpyLDDSP9cC7zUi4Hh9Cnz'),
         (34, 'https://drive.google.com/uc?export=download&id=1J0cl9aGb3Gvhgbov49FCyPjtuo7W96az'),
         (35, 'https://drive.google.com/uc?export=download&id=1gvFRTrz1C_faOiIZUoe8y8adVdCyXM57'),
         (36, 'https://drive.google.com/uc?export=download&id=1SqX6So-jtLzeOpoqdXzdIGJgquZXZiJk'),
         (37, 'https://drive.google.com/uc?export=download&id=1Ngplvi2rKX0rjFxzXOR4ODx9L38UQDHE'),
         (38, 'https://drive.google.com/uc?export=download&id=1AoW8XeczJTYOC3Q0H8DjCXVwbudMoGcP'),
         (39, 'https://drive.google.com/uc?export=download&id=1jaEC17ASGxNDJAyyulBVhO0NBVmI_iAa'),
         (40, 'https://drive.google.com/uc?export=download&id=15go9POUg8_3nsjz6xPHmZqxzYxnMNcu7'),
         (41, '/levels/overlord.json'),
         (42, 'https://drive.google.com/uc?export=download&id=1eZF7faadc4hjZ-lUxGMggz99gT03tGEM'),
         (43, 'https://drive.google.com/uc?export=download&id=1W6PhSsxNDQbxLwWiFHhOfc0INgw-exov'),
         (44, 'https://drive.google.com/uc?export=download&id=1kF5cZ7xd6k6QEklwo0BGee6NteAdvXBM'),
         (45, 'https://drive.google.com/uc?export=download&id=1Mt08RZaAuazPJORoXaWkBBvdpOzGX1qU'),
         (46, 'https://drive.google.com/uc?export=download&id=1vN8VIjlRK6NOKTlQ_7YBZIQMDGelamjM'),
         (47, 'https://drive.google.com/uc?export=download&id=1xcnpkXAsum0i6DwbrK5AhAC4qbXB9adX'),
         (48, 'https://drive.google.com/uc?export=download&id=1W33Jv1LFLAvh_0wmKOWh9ktpUK5aFzQX'),
         (49, 'https://drive.google.com/uc?export=download&id=11X5XK7q6HExMJZ-zUPoxZW9vYFDD5B3r'),
         (50, 'https://drive.google.com/uc?export=download&id=1IyDWBxn-9lcQeZVkTQQY1gzE3zTBuZdA')
       ) AS v (level, url)
 WHERE l.level = v.level
   AND l.asset_url IS NULL;

-- A level whose first art was replaced (the fill above never touches a URL
-- already there): Level 20's first upload was 4.1 MB of embedded images, and
-- the owner sent a 43 KB one the same evening (29 Sep 2026). Moves exactly the
-- old URL onto the new file, so an owner's own URL is never touched and a
-- database seeded afresh finds nothing to do.
UPDATE player_levels
   SET asset_url    = '/levels/high-roller.json',
       asset_format = 'LOTTIE',
       updated_at   = (EXTRACT(EPOCH FROM now()) * 1000)::bigint
 WHERE level = 20
   AND asset_url = 'https://drive.google.com/uc?export=download&id=1ABHkYZ0N3O_BDBI1UpBfoVvWilXPTnxf';

-- The badges (owner, 27 Sep 2026: "Vip is not a level, it is badge, User can
-- hold multiple badges"; then "add validity column in badges so that when it
-- expires, player will not get tax benefit"). REGULAR is every player's by default, with no
-- row, for life (owner, 27 Sep 2026: "By default every user will hold this
-- Regular badge 20 percent tax … validaity life time, do not show this badge
-- in store, its price zero"; is_default — the store never lists a default
-- badge): 20%, which no level's rate is above, so for a player with no other
-- badge their level decides; its art is the owner's Lottie (500x500, a
-- one-second loop, nothing a phone cannot draw). It replaces the Standard
-- badge of the owner's first list.
-- Then the ROYAL badges the store lists (owner, 27 Sep 2026: "for badges use
-- this entry, not vips entry … Add this in UI store and with their lottie
-- animation u can store in db"): 0% winning tax for 7 to 90 days at ₹500 to
-- ₹4,500, each with the owner's Lottie (asset_url: their Drive uploads, public,
-- as the download link; every one checked for what a phone's player cannot
-- draw — no 3D layers, no images, no text; Royal King of Kings's crown pulse
-- is a loopOut('pingpong') a phone plays once a loop rather than throughout,
-- and Royal Ace's 16:9 canvas has its crown in the middle, which a square
-- shows whole). Each is SOLD IN THE APP through Google Play under its
-- play_product_id, a managed one-time product in the Play Console (owner,
-- 27 Sep 2026, who created the six that day: badge_royal_<name>_<rupees>);
-- until then every royal badge was asked for through support ("for all type
-- of royal badges Add a button to contact support in store") and granted by
-- hand (this file's header, still the way to grant one without a purchase).
-- A product id set to NULL takes a badge back to the support key.
-- price_inr is the price in rupees, always INR ("price in
-- badges will always be in inr currency"). They replace the two badges of the
-- owner's first list, Tax Free Ace and Tax Free King; the VIP, Royal VIP and
-- Elite VIP badges of the same day are gone (owner, 27 Sep 2026: "remove the
-- entry vip, royal vip and elite vip"). Written only where the code is
-- missing, so an owner's UPDATE — a re-priced badge, a new icon, a longer
-- validity — survives every restart. The prices are Play's own in India
-- (owner, 27 Sep 2026: "change price to match"): ₹500 to ₹4,500, where the
-- first list said ₹499 to ₹4,499 — the product ids keep that list's figures,
-- since Play never renames a product.
INSERT INTO badges (code, title, icon, tax_bps, validity_days, price_inr, play_product_id,
                    asset_url, asset_format, is_default, is_active, sort_order)
VALUES
  ('REGULAR',   'Regular',   '',    2000, 0,    0,    NULL,
   'https://drive.google.com/uc?export=download&id=1zz4gVBpw579xeR1LLn3dBd3Os3cG8jQT', 'LOTTIE', TRUE, TRUE, 10),
  ('ROYAL_ACE',           'Royal Ace',           '', 0, 7,  500,  'badge_royal_ace_499',
   'https://drive.google.com/uc?export=download&id=1lwt8uXauqnX77WEb73xZAbTz_TR-rJKm', 'LOTTIE', FALSE, TRUE, 20),
  ('ROYAL_KING',          'Royal King',          '', 0, 15, 1000,  'badge_royal_king_999',
   'https://drive.google.com/uc?export=download&id=1Frs4uv6oAkxK9YgHhh52Rwi_kCRpngNU', 'LOTTIE', FALSE, TRUE, 30),
  ('ROYAL_MASTER',        'Royal Master',        '', 0, 30, 1800, 'badge_royal_master_1799',
   'https://drive.google.com/uc?export=download&id=1ifJxiC6l59fQ1i-RulfLn2SzJfw5sgiJ', 'LOTTIE', FALSE, TRUE, 40),
  ('ROYAL_EMPEROR',       'Royal Emperor',       '', 0, 45, 2500, 'badge_royal_emperor_2499',
   'https://drive.google.com/uc?export=download&id=1gBUNiLrdoSqkL29UEKCI7DjqAr8wZiSd', 'LOTTIE', FALSE, TRUE, 50),
  ('ROYAL_LEGEND',        'Royal Legend',        '', 0, 60, 3300, 'badge_royal_legend_3299',
   'https://drive.google.com/uc?export=download&id=1kn5KJLW96mcMaXLygpvM_sIxPA7L1Ov-', 'LOTTIE', FALSE, TRUE, 60),
  ('ROYAL_KING_OF_KINGS', 'Royal King of Kings', '', 0, 90, 4500, 'badge_royal_king_of_kings_4499',
   'https://drive.google.com/uc?export=download&id=1A1ckgYQjocbcYfeJsOKFNO8hCrCDCWNI', 'LOTTIE', FALSE, TRUE, 70)
    ON CONFLICT (code) DO NOTHING;

-- The daily XP (owner, 27 Sep 2026: "Daily XP user can get store this info in
-- db … After 24 hours this will be reset, so user can claim this again"),
-- exactly as given — each ONCE a window:
--
--   🎮 Play 15 active minutes    +3 XP     🎮 Play 60 active minutes   +20 XP
--   🎮 Play 120 active minutes   +50 XP    👥 Win by Pair              +1 XP
--   🎨 Win by Color              +2 XP     🃏 Win by Sequence          +4 XP
--   💎 Win by Pure Sequence      +8 XP     🔥 Win by Trail             +20 XP
--
-- A PLAY_TIME source is earned when the window's active play (the live
-- store's, of hands played out) reaches its minutes; a WIN_HAND source when
-- the player wins a Teen Patti or Variation hand holding that hand, as the
-- table ranks it. 108 XP a window at most. These replaced the first sources
-- (26 Sep 2026: a hand completed 1, a hand won 1, 30 and 60 minutes 5 and 15,
-- a daily bonus 5). ON CONFLICT (code) DO NOTHING: an owner's UPDATE — a
-- source re-valued, re-timed or switched off — survives every restart.
INSERT INTO xp_sources (code, name, icon, kind, play_minutes, hand_rank, xp, times_per_window, is_active, sort_order)
VALUES ('PLAY_15_MIN',       'Play 15 active minutes',  '🎮', 'PLAY_TIME', 15,   NULL,            3,  1, TRUE, 10),
       ('PLAY_60_MIN',       'Play 60 active minutes',  '🎮', 'PLAY_TIME', 60,   NULL,            20, 1, TRUE, 20),
       ('PLAY_120_MIN',      'Play 120 active minutes', '🎮', 'PLAY_TIME', 120,  NULL,            50, 1, TRUE, 30),
       ('WIN_PAIR',          'Win by Pair',             '👥', 'WIN_HAND',  NULL, 'PAIR',          1,  1, TRUE, 40),
       ('WIN_COLOR',         'Win by Color',            '🎨', 'WIN_HAND',  NULL, 'COLOR',         2,  1, TRUE, 50),
       ('WIN_SEQUENCE',      'Win by Sequence',         '🃏', 'WIN_HAND',  NULL, 'SEQUENCE',      4,  1, TRUE, 60),
       ('WIN_PURE_SEQUENCE', 'Win by Pure Sequence',    '💎', 'WIN_HAND',  NULL, 'PURE_SEQUENCE', 8,  1, TRUE, 70),
       ('WIN_TRAIL',         'Win by Trail',            '🔥', 'WIN_HAND',  NULL, 'TRAIL',         20, 1, TRUE, 80)
    ON CONFLICT (code) DO NOTHING;

-- The ONE-TIME missions (owner, 28 Sep 2026: "Add a new mission type:
-- ONE_TIME. One-time missions are permanent missions that a player can
-- complete only once"), the owner's eight — each once in a player's life,
-- never reset — at a TENTH of the XP first given (owner, the same day: "reduce
-- the XP Granted value", ÷10), so the missions alone lift a player to Level 2
-- (100 XP). The four Poker missions first given with them (First Poker Hand,
-- First Poker Win, Texas Hold'em Debut, Poker Regular) were taken out the same
-- day (owner: "Remove Poker and texas related one time XP from DB, we don't
-- need"):
--
--   First Hand            play 1 hand                +5     FIRST_HAND
--   First Win             win 1 hand                 +10    FIRST_WIN
--   Getting Started       play 10 hands              +15    GETTING_STARTED
--   First 5 Wins          win 5 hands                +30    FIRST_5_WINS
--   Card Player           play 50 hands              +50    CARD_PLAYER
--   Winning Streak        win 10 hands               +75    WINNING_STREAK
--   Variation Explorer    play 1 Variation hand      +10    VARIATION_EXPLORER
--   Game Explorer         play 3 different games     +50    GAME_EXPLORER
--
-- 245 XP in all (2,450 as first given), and none of it counted in a daily
-- window. A hand is
-- PLAYED as requirement 16 and player_stats say — the player put chips in
-- beyond the boot (a chaal, raise or show; at poker any chips beyond the
-- forced blinds or ante) — and WON when the hand-end settle names them its
-- winner (at 3-Card Poker, beating the dealer or a dealer that does not
-- qualify; a push is neither); only hands the player COMPLETES count, never
-- one they walked out of. Winning Streak is ten wins in all, not ten in a row
-- (the owner's name, the owner's requirement). Variation Explorer is a hand
-- played at a Variation table (scope 'variation'); to have it count the
-- variations instead (MUFLIS, AK47 …), it is one UPDATE:
--
--   UPDATE xp_sources SET kind = 'VARIATIONS_PLAYED', scope = NULL
--    WHERE code = 'VARIATION_EXPLORER';
--
-- Game Explorer counts the seven table categories (seen, blind, variation,
-- three_card_poker, five_card_draw, texas_holdem, omaha) a player has played
-- a hand at, and wants three of them (owner, 28 Sep 2026: "make it 3 instead
-- of 5" — 5 at first; the app offers Seen, Blind and Variation alone since
-- Poker was hidden, so five could never be reached). A target lowered by hand
-- on a database where a player is already at or past it completes at the next
-- hand that MOVES the mission, and a different-games mission moves only for a
-- game it has not counted: such a player is left at "3 / 3" until they play a
-- fourth kind of table. Nothing like them was seeded before (the daily sources above are
-- play time and "Win by …"), so every one is new. ON CONFLICT (code) DO
-- NOTHING, like the daily sources: an owner's UPDATE — a mission re-valued,
-- re-targeted or switched off — survives every restart, and a completed
-- mission stays completed whatever becomes of its row.
INSERT INTO xp_sources (code, name, icon, kind, mission_type, target, scope, xp, times_per_window, is_active, sort_order)
VALUES ('FIRST_HAND',         'First Hand',          '🎴', 'HANDS_PLAYED',      'ONE_TIME', 1,  NULL,           5,  1, TRUE, 110),
       ('FIRST_WIN',          'First Win',           '🏆', 'HANDS_WON',         'ONE_TIME', 1,  NULL,           10, 1, TRUE, 120),
       ('GETTING_STARTED',    'Getting Started',     '🚀', 'HANDS_PLAYED',      'ONE_TIME', 10, NULL,           15, 1, TRUE, 130),
       ('FIRST_5_WINS',       'First 5 Wins',        '🥇', 'HANDS_WON',         'ONE_TIME', 5,  NULL,           30, 1, TRUE, 140),
       ('CARD_PLAYER',        'Card Player',         '♠️', 'HANDS_PLAYED',      'ONE_TIME', 50, NULL,           50, 1, TRUE, 150),
       ('WINNING_STREAK',     'Winning Streak',      '⚡', 'HANDS_WON',         'ONE_TIME', 10, NULL,           75, 1, TRUE, 160),
       ('VARIATION_EXPLORER', 'Variation Explorer',  '🔀', 'HANDS_PLAYED',      'ONE_TIME', 1,  'variation',    10, 1, TRUE, 210),
       ('GAME_EXPLORER',      'Game Explorer',       '🧭', 'CATEGORIES_PLAYED', 'ONE_TIME', 3,  NULL,           50, 1, TRUE, 220)
    ON CONFLICT (code) DO NOTHING;

-- The window (owner: "it will be reset after 24 hours", "After 24 hours this
-- will be reset, so user can claim this again"): 24 hours from the first hand
-- a player completes in it — how often every daily XP source comes round. NO
-- daily cap (owner, 27 Sep 2026:
-- "Don't set any daily limit to xp"; 50 XP until then): daily_cap NULL, and
-- every hand's XP counts however many are played. Written only where there is
-- none.
INSERT INTO xp_settings (id, daily_cap, window_ms)
VALUES (1, NULL, 86400000)
    ON CONFLICT (id) DO NOTHING;

-- ============================================================= THE APP VERSIONS
--
-- The app version gate (owner, 28 Sep 2026; the baseline's APP VERSIONS
-- section): a row per app platform with NO floor ('0.0.0'), nothing announced
-- ('0.0.0') and the platform open (NORMAL), so deploying the gate changes
-- nothing for anybody. android carries the Play listing, which is public and
-- fixed by the package name; ios is empty until the App Store has a listing
-- (the app then falls back to its own link, which needs APPLE_APP_ID).
--
-- ON CONFLICT (platform) DO NOTHING: an operator's UPDATE — a raised minimum,
-- a maintenance — survives every restart, and a seed row changed here reaches
-- only a fresh database. ops/DEPLOY.md ("The app version gate") has the
-- statements that raise the minimum and enter and leave maintenance.
INSERT INTO app_versions (platform, status, minimum_version, latest_version, store_url, message)
VALUES ('android', 'NORMAL', '0.0.0', '0.0.0',
        'https://play.google.com/store/apps/details?id=com.sungamestudio.kingteenpatti', NULL),
       ('ios',     'NORMAL', '0.0.0', '0.0.0', '', NULL)
    ON CONFLICT (platform) DO NOTHING;

-- ================================================================ THE WELCOME
--
-- What a new account is given (owner, 30 Sep 2026: "new account will get how
-- much coins, hammers, diamonds, profile_picture, emoji — this data should
-- come from database, user might get some or all rewards"; the baseline's
-- WELCOME REWARDS). A new account gets every ACTIVE row, inside the
-- transaction that creates it; an existing account's login gets nothing.
--
-- These three are exactly what the users column DEFAULTs gave every account
-- until today — 9 diamonds, 20 hammers, 1 missile — so the deploy changes
-- nothing a player sees. The CHIPS row is deliberately NOT here: the server
-- writes it at boot, coded 'chips' with sort_order 10, from WELCOME_CHIPS when
-- the table has no 'chips' row (db.Welcome.EnsureChipsRow), so a deployment's
-- first boot carries its own .env's welcome into the table — production's
-- figure, a test schema's, a parity profile's — and from then on the ROW
-- decides; a boot whose WELCOME_CHIPS differs says so in one WARN and leaves
-- the row alone.
--
-- ON CONFLICT (code) DO NOTHING: an owner's UPDATE survives every restart.
-- Change a figure, or switch a grant off, with an UPDATE — it applies to the
-- very next new account, no restart:
--
--   UPDATE welcome_rewards SET reward_value = 500000 WHERE code = 'chips';
--   UPDATE welcome_rewards SET is_active = FALSE WHERE code = 'hammers';
--
-- never with a DELETE: a seeded row, and the chips row, come back at the next
-- boot. A picture, a table picture or an emoji is added by its catalogue's
-- natural key (ids differ between databases), and must be a PREMIUM, active
-- row (a FREE one is everybody's already); the new account owns it for the
-- term the shop rents it for, from its first moment, and is never put in it:
--
--   INSERT INTO welcome_rewards (code, reward_type, reward_ref_id, sort_order)
--   VALUES ('welcome_picture', 'PROFILE_PICTURE',
--           (SELECT id::text FROM profile_pictures WHERE name = 'Lovestruck Cat'), 50)
--       ON CONFLICT (code) DO NOTHING;
--
--   INSERT INTO welcome_rewards (code, reward_type, reward_ref_id, sort_order)
--   VALUES ('welcome_table_picture', 'TABLE_PICTURE',
--           (SELECT id::text FROM table_pictures WHERE name = 'Lines Background'), 60)
--       ON CONFLICT (code) DO NOTHING;
--
--   INSERT INTO welcome_rewards (code, reward_type, reward_ref_id, sort_order)
--   VALUES ('welcome_emoji', 'EMOJI',
--           (SELECT id::text FROM emojis WHERE name = 'Clapping Hands'), 70)
--       ON CONFLICT (code) DO NOTHING;
--
-- A row the server cannot grant — a type it does not know, an amount missing
-- or 0, a catalogue row missing, retired or free — is left out with a WARN
-- `welcome reward left out` naming its code, and the account is created
-- without it.
INSERT INTO welcome_rewards (code, reward_type, reward_value, sort_order)
VALUES ('diamonds', 'DIAMOND', 9,  20),
       ('hammers',  'HAMMER',  20, 30),
       ('missiles', 'MISSILE', 1,  40)
    ON CONFLICT (code) DO NOTHING;
