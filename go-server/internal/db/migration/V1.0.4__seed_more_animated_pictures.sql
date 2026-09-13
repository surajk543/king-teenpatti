-- King Teen Patti — nine more animated pictures (DML).
--
-- Added 13 Sep 2026 (owner), after V1.0.2 had already run in production with
-- go-server/v1.3.0. New rows are a new script, never an edit to an applied one:
-- the server runs every script on every boot, and this one only has to be
-- idempotent against itself.
--
--   Monarch Butterfly   450×450,   2.7 s, Lottie 4.8.0   4 DIAMONDS  sort_order 220
--   Lovestruck Cat      500×500,   6 s,   Lottie 5.9.6   5 DIAMONDS  sort_order 230
--   Waving Tiger Cub    1400×1400, 6 s,   Lottie 5.7.8   5 DIAMONDS  sort_order 240
--   Galloping Horse     1556×2048, 0.5 s, Lottie 4.8.0   1 DIAMOND   sort_order 250
--   Gamer Raccoon       512×512,   3 s,   Lottie 5.12.1  6 DIAMONDS  sort_order 260
--   Cool Cat            512×512,   2.1 s, Lottie 5.9.6   10 DIAMONDS sort_order 270
--   Indian Flag         1000×1000, 2 s,   Lottie 4.8.0   10 DIAMONDS sort_order 280
--   Jolly King          1080×1080, 6.2 s, Lottie 5.9.0   10 DIAMONDS sort_order 290
--   Jolly Queen         1080×1080, 6.2 s, Lottie 5.9.0   10 DIAMONDS sort_order 300
--
-- All are 100-day rentals on the Premium (Animated) shelf, and all move with
-- plain 2D transforms the phone players draw (checked frame by frame against
-- lottie-web). The monarch beats its wings by scaling each wing layer
-- horizontally (100% → 50% → 100%) — unlike Butterfly Flapping (V1.0.2), whose
-- 3D wing orientation had to be flattened before it would move on a phone — and
-- its three images are embedded in the JSON. The cat, lying down with hearts
-- floating up, is vector shapes in two precomps animated by position and
-- rotation. The tiger cub, which waves and covers its eyes, is vector shapes
-- animated by rotation and scale, and carries two loopOut() expressions on a
-- small detail in its head. The phone players do not run expressions, so that
-- detail holds still after its first 6-frame cycle: 48 differing pixels across
-- eight sampled 212 px frames against a loop-baked copy, invisible at avatar
-- size, so the Drive original is served as it is. The horse is a black
-- silhouette drawn as a 12-frame flipbook (one shape layer per frame, no
-- keyframes); its merge paths are all plain merges, which the phone players
-- (merge paths off by default) draw identically on a single solid fill. The
-- raccoon, blinking over a game controller, animates by opacity, rotation and
-- scale; its merge paths are plain merges too. The cool cat — sunglasses, a red
-- jacket and a baseball bat on its shoulder — swaps drawings for its glasses
-- and tongue and rotates its bat arm and tail; its merge paths are plain merges,
-- and only its thin black whiskers fade on the dark theme. The Indian flag waves
-- by 51 held mask shapes cut from three solid bands (masks the phone players
-- draw); it sits high and left on its canvas, so in the round picture its thin
-- brown pole is mostly clipped or lost on the dark theme and the lower part of
-- the circle is empty.
--
-- Jolly King and Jolly Queen are served from Drive like the rest, but from
-- reworked copies, not from their original uploads. Every move
-- either makes — the king's head sway, bob and twinkling sparkles, the queen's
-- sway, crown rock and sparkles — is a loopOut() / loopOut('pingpong')
-- expression over a few keyframes that run out by frame 32 of 187, and the
-- phone players run no expressions, so the Drive originals freeze after about a
-- second. The served copies have those loops written out as keyframes by
-- tools/lottie/bake_loop_expressions.py (37 properties for the king, 26 for the
-- queen, none left), render pixel-identically to the originals in lottie-web,
-- and were uploaded to Drive as jolly-king.json and jolly-queen.json (checked
-- byte for byte against the baked output after downloading them back).
--
-- Served by the Drive direct-download form uc?export=download&id= (a
-- /file/d/<id>/view link is an HTML viewer page). ON CONFLICT on asset_url leaves
-- a row exactly as the owner last left it once it exists.

INSERT INTO profile_pictures (name, asset_url, asset_format, currency, type, cost, duration_days, is_active, sort_order, created_at, updated_at)
SELECT name, asset_url, asset_format, currency, type, cost, duration_days, is_active, sort_order,
       (EXTRACT(EPOCH FROM now()) * 1000)::bigint,
       (EXTRACT(EPOCH FROM now()) * 1000)::bigint
  FROM (VALUES
    ('Monarch Butterfly', 'https://drive.google.com/uc?export=download&id=16CuzIvYWioJW4xTyI4ukYVkHWnJFLyt-',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 4::bigint, 100, TRUE, 220),
    ('Lovestruck Cat',    'https://drive.google.com/uc?export=download&id=1KOKAFftNzGhnG6ISbnb7ylz1uTf87Er3',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 5::bigint, 100, TRUE, 230),
    ('Waving Tiger Cub',  'https://drive.google.com/uc?export=download&id=1vg1xUlnF0vLAYh-w8F4dHRUsQ1sTPTgB',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 5::bigint, 100, TRUE, 240),
    ('Galloping Horse',   'https://drive.google.com/uc?export=download&id=1hYp8vPfH07C7JeJlmJZI5JyazvRd7Qbg',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 1::bigint, 100, TRUE, 250),
    ('Gamer Raccoon',     'https://drive.google.com/uc?export=download&id=1uchuXzcjzIq6_WKIp2jHVkJ2D4AGxH8g',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 6::bigint, 100, TRUE, 260),
    ('Cool Cat',          'https://drive.google.com/uc?export=download&id=15UkZwIjVdEquW_smNseUStfciYikMH37',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 10::bigint, 100, TRUE, 270),
    ('Indian Flag',       'https://drive.google.com/uc?export=download&id=11oXU9B5LeWF9OMEcCYihLkKcrj0Zl4Gn',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 10::bigint, 100, TRUE, 280),
    ('Jolly King',        'https://drive.google.com/uc?export=download&id=1oDAJP-qC9GNxt6tW6WLMldl0EV6YtcWn',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 10::bigint, 100, TRUE, 290),
    ('Jolly Queen',       'https://drive.google.com/uc?export=download&id=1PXnoJzPxQtn7v5JkjUVemUNdbA4gSa73',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 10::bigint, 100, TRUE, 300)
  ) AS seed(name, asset_url, asset_format, currency, type, cost, duration_days, is_active, sort_order)
    ON CONFLICT (asset_url) DO NOTHING;
