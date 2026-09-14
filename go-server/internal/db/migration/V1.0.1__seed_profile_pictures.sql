-- King Teen Patti — the profile-picture catalogue (DML).
--
-- Every row the server seeds, in one file. Consolidated on 14 Sep 2026 (owner)
-- for a production deploy onto an empty database (V1.0.0's header): the rows
-- V1.0.2__seed_animated_pictures.sql and V1.0.4__seed_more_animated_pictures.sql
-- used to add are here. The rows run free first, then the pictures priced in
-- chips, then the animated pictures priced in hammers, then those priced in
-- diamonds (owner, 14 Sep 2026), and sort_order follows that order in steps of
-- ten, so a fresh database numbers the catalogue the same way: Bear is 1, Wolf
-- 15, Love Sheep 16, Anima Bot 19, Orange Ballerina 20, Love and Kiss 35,
-- Butterfly Flapping 36 and Jolly Queen 40. Shooting Game, Spider, Swirling
-- Dots, Sporty Avocado and Blazing Fire, and after them Love Sheep, Love Birds,
-- Error 404, Anima Bot and Love and Kiss, were added to this file the same day,
-- rather than in a new script,
-- because no environment that matters had run it yet: production starts from
-- an empty database (ops/DEPLOY.md §8). Once production has run this file, the
-- next picture goes in a new script.
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
--   Love and Kiss       512×512,  3 s,    Lottie 5.4.4     2 HAMMERS   10 days   sort_order 350
--   Butterfly Flapping  1000×1000, 5 s,    Lottie 4.8.0   4 DIAMONDS  100 days   sort_order 360
--   Waving Tiger Cub    1400×1400, 6 s,    Lottie 5.7.8   3 DIAMONDS  100 days   sort_order 370
--   Indian Flag         1000×1000, 2 s,    Lottie 4.8.0   5 DIAMONDS  100 days   sort_order 380
--   Jolly King          1080×1080, 6.2 s,  Lottie 5.9.0   5 DIAMONDS  100 days   sort_order 390
--   Jolly Queen         1080×1080, 6.2 s,  Lottie 5.9.0   5 DIAMONDS  100 days   sort_order 400
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
     'LOTTIE', 'HAMMER', 'PREMIUM', 2::bigint, 10, 0, TRUE, 350),
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
     'LOTTIE', 'DIAMOND', 'PREMIUM', 5::bigint, 100, 0, TRUE, 400)
  ) AS seed(name, asset_url, asset_format, currency, type, cost, duration_days, duration_hours, is_active, sort_order)
    ON CONFLICT (asset_url) DO NOTHING;
