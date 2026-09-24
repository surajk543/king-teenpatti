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
-- id, a table's table_key — and it
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
--     200 / 5,000 / 50,000 / 10 Lakh, five seats and two to start, the 25 s
--     turn, 20 rounds and the 6 s sideshow as advertised, and requirement 30's
--     entry cap — nobody holding more than 5 Lakh sits at the 200 blind table;
--   * the twelve tables of the default LOBBY_TABLES menu, in its order
--     (sort_order 10 to 120), each with its stack band;
--   * a private template for each of the seven categories (sort_order 1010 to
--     1070), the table room:create opens: boot 200, two rungs, a 5 Lakh pot
--     cap at Teen Patti.
--
-- Every figure is resolved as TableRules and the poker knobs resolved it. Seen:
-- two rungs, seven rounds, a per-bet ceiling of 1024 boots and a 20 Lakh pot
-- cap, unless the table has its own (seen 50,000: 5 Crore). Blind: no limit
-- anywhere. Variation: seen's ladder, no pot cap, the 10 s chooser's window and
-- the 8 s 5-Card pick. Poker: a 25 s clock, a buy-in of ten boots, three cards
-- to exchange (only 5-Card Draw reads it), and none of Teen Patti's figures.
-- Every table: three missed turns before the idle kick, a 4 s pause between
-- hands, 30 s to buy chips before a short seat is kicked; every Teen Patti
-- table, four blind moves and 3 s more after a missile.
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
VALUES (1, 200, ARRAY[200, 5000, 50000, 1000000]::bigint[], 5, 2, 25000,
        20, 6000, 3,
        200, 'blind', 500000)
    ON CONFLICT (id) DO NOTHING;

-- The public tables: the default menu, in LOBBY_TABLES order. The column names
-- over the rows are shortened; v(…) at the foot names each in full.
WITH fresh AS (SELECT NOT EXISTS (SELECT 1 FROM table_configs WHERE NOT is_private) AS empty)
INSERT INTO table_configs (category, boot_amount, is_private, min_chips, max_chips,
                           max_pot, max_raise_steps, max_bet_rounds, pot_limit_multiplier, max_blind_moves,
                           turn_timeout_ms, max_missed_turns, sideshow_timeout_ms, sideshow_min_players,
                           next_hand_delay_ms, unfunded_grace_ms, missile_reveal_extra_ms,
                           variation_select_timeout_ms, five_card_pick_timeout_ms, min_buy_in, max_discards,
                           sort_order, is_active)
SELECT v.category, v.boot_amount, FALSE, v.min_chips, v.max_chips,
       v.max_pot, v.max_raise_steps, v.max_bet_rounds, v.pot_limit_multiplier, v.max_blind_moves,
       v.turn_timeout_ms, v.max_missed_turns, v.sideshow_timeout_ms, v.sideshow_min_players,
       v.next_hand_delay_ms, v.unfunded_grace_ms, v.missile_reveal_extra_ms,
       v.variation_select_timeout_ms, v.five_card_pick_timeout_ms, v.min_buy_in, v.max_discards,
       v.sort_order, fresh.empty
  FROM (VALUES
    -- category          boot         min_chips  max_chips   max_pot          steps  rounds  ceiling       blind  turn   missed  side  side_min  next  grace  missile  select  pick  buy_in     disc  sort
    ('seen',             200::bigint, 0::bigint, 0::bigint,  2000000::bigint, 2,     7,      1024::bigint, 4,     25000, 3,      6000, 3,        4000, 30000, 3000,    0,      0,    0::bigint, 0,     10),
    ('blind',            200,         0,         0,          0,               0,     0,      0,            4,     25000, 3,      6000, 3,        4000, 30000, 3000,    0,      0,    0,         0,     20),
    ('blind',            5000,        0,         50000000,   0,               0,     0,      0,            4,     25000, 3,      6000, 3,        4000, 30000, 3000,    0,      0,    0,         0,     30),
    ('blind',            50000,       0,         1000000000, 0,               0,     0,      0,            4,     25000, 3,      6000, 3,        4000, 30000, 3000,    0,      0,    0,         0,     40),
    ('blind',            1000000,     500000000, 0,          0,               0,     0,      0,            4,     25000, 3,      6000, 3,        4000, 30000, 3000,    0,      0,    0,         0,     50),
    ('variation',        50000,       0,         1000000000, 0,               2,     7,      1024,         4,     25000, 3,      6000, 3,        4000, 30000, 3000,    10000,  8000, 0,         0,     60),
    ('variation',        1000000,     500000000, 0,          0,               2,     7,      1024,         4,     25000, 3,      6000, 3,        4000, 30000, 3000,    10000,  8000, 0,         0,     70),
    ('seen',             50000,       0,         0,          50000000,        2,     7,      1024,         4,     25000, 3,      6000, 3,        4000, 30000, 3000,    0,      0,    0,         0,     80),
    ('three_card_poker', 50000,       0,         0,          0,               0,     0,      0,            0,     25000, 3,      0,    0,        4000, 30000, 0,       0,      0,    500000,    3,     90),
    ('five_card_draw',   50000,       0,         0,          0,               0,     0,      0,            0,     25000, 3,      0,    0,        4000, 30000, 0,       0,      0,    500000,    3,    100),
    ('texas_holdem',     50000,       0,         0,          0,               0,     0,      0,            0,     25000, 3,      0,    0,        4000, 30000, 0,       0,      0,    500000,    3,    110),
    ('omaha',            50000,       0,         0,          0,               0,     0,      0,            0,     25000, 3,      0,    0,        4000, 30000, 0,       0,      0,    500000,    3,    120)
  ) AS v(category, boot_amount, min_chips, max_chips,
         max_pot, max_raise_steps, max_bet_rounds, pot_limit_multiplier, max_blind_moves,
         turn_timeout_ms, max_missed_turns, sideshow_timeout_ms, sideshow_min_players,
         next_hand_delay_ms, unfunded_grace_ms, missile_reveal_extra_ms,
         variation_select_timeout_ms, five_card_pick_timeout_ms, min_buy_in, max_discards,
         sort_order)
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
                           sort_order, is_active)
SELECT v.category, v.boot_amount, TRUE, v.min_chips, v.max_chips,
       v.max_pot, v.max_raise_steps, v.max_bet_rounds, v.pot_limit_multiplier, v.max_blind_moves,
       v.turn_timeout_ms, v.max_missed_turns, v.sideshow_timeout_ms, v.sideshow_min_players,
       v.next_hand_delay_ms, v.unfunded_grace_ms, v.missile_reveal_extra_ms,
       v.variation_select_timeout_ms, v.five_card_pick_timeout_ms, v.min_buy_in, v.max_discards,
       v.sort_order, fresh.empty
  FROM (VALUES
    -- category          boot         min_chips  max_chips  max_pot         steps  rounds  ceiling       blind  turn   missed  side  side_min  next  grace  missile  select  pick  buy_in     disc  sort
    ('seen',             200::bigint, 0::bigint, 0::bigint, 500000::bigint, 2,     7,      1024::bigint, 4,     25000, 3,      6000, 3,        4000, 30000, 3000,    0,      0,    0::bigint, 0,    1010),
    ('blind',            200,         0,         0,         500000,         2,     0,      0,            4,     25000, 3,      6000, 3,        4000, 30000, 3000,    0,      0,    0,         0,    1020),
    ('variation',        200,         0,         0,         500000,         2,     7,      1024,         4,     25000, 3,      6000, 3,        4000, 30000, 3000,    10000,  8000, 0,         0,    1030),
    ('three_card_poker', 200,         0,         0,         0,              0,     0,      0,            0,     25000, 3,      0,    0,        4000, 30000, 0,       0,      0,    2000,      3,    1040),
    ('five_card_draw',   200,         0,         0,         0,              0,     0,      0,            0,     25000, 3,      0,    0,        4000, 30000, 0,       0,      0,    2000,      3,    1050),
    ('texas_holdem',     200,         0,         0,         0,              0,     0,      0,            0,     25000, 3,      0,    0,        4000, 30000, 0,       0,      0,    2000,      3,    1060),
    ('omaha',            200,         0,         0,         0,              0,     0,      0,            0,     25000, 3,      0,    0,        4000, 30000, 0,       0,      0,    2000,      3,    1070)
  ) AS v(category, boot_amount, min_chips, max_chips,
         max_pot, max_raise_steps, max_bet_rounds, pot_limit_multiplier, max_blind_moves,
         turn_timeout_ms, max_missed_turns, sideshow_timeout_ms, sideshow_min_players,
         next_hand_delay_ms, unfunded_grace_ms, missile_reveal_extra_ms,
         variation_select_timeout_ms, five_card_pick_timeout_ms, min_buy_in, max_discards,
         sort_order)
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
