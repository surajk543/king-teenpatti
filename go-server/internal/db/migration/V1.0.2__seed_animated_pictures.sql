-- King Teen Patti — five more animated pictures (DML).
--
-- Added 13 Sep 2026 (owner), after V1.0.1 had already run in production. New
-- rows are a new script, never an edit to an applied one: the server runs
-- every script on every boot, and this one only has to be idempotent against
-- itself. (It has since been edited once, for Butterfly Flapping's move to
-- Drive, under the rule below — read "WHY THIS APPLIED SCRIPT WAS EDITED".)
--
-- All are Lottie animations on a 100-day rental, following Orange Ballerina on
-- the Premium (Animated) shelf:
--
--   Butterfly Flapping  1000×1000, 5 s,    Lottie 4.8.0   4 DIAMONDS  sort_order 170
--   Toucan Flying       1920×1080, 4 s,    Lottie 5.5.7   3 DIAMONDS  sort_order 180
--   Live Chatbot         952×784,  3 s,    Lottie 5.9.6   1 DIAMOND   sort_order 190
--   Paper Plane          800×600,  3 s,    Lottie 5.5.8   1 DIAMOND   sort_order 200
--   Bouncing Dots        256×256,  1.3 s,  Lottie 4.6.8   1 DIAMOND   sort_order 210
--
-- The toucan's canvas is landscape; the app draws a picture into a circle with
-- BoxFit.cover, so only the centre 1080×1080 of it shows.
--
-- Butterfly Flapping as drawn beats its wings with 3D orientation ("or"):
-- lottie-web plays that, but the phone players — Flutter's lottie and
-- lottie-android — ignore it, so on a phone both wings sat still on top of each
-- other. The copy served has that motion baked into 2D rotation and scale on
-- two null parent layers (tools/lottie/flatten_orientation.py), and draws the
-- same frame for frame. go-server/v1.3.0 served that copy itself, from
-- public/profiles/butterfly-flapping.json; the owner has since uploaded the
-- byte-identical file to Drive, and public/profiles/ no longer carries it.
--
-- The Drive files are served by the direct-download form
-- uc?export=download&id= (a /file/d/<id>/view link is an HTML viewer page, and
-- lh3 only serves images). ON CONFLICT on asset_url leaves a row the owner has
-- since re-priced, renamed or retired exactly as it is.
--
-- WHY THIS APPLIED SCRIPT WAS EDITED (13 Sep 2026). Production ran this script
-- under go-server/v1.3.0 with Butterfly Flapping at
-- '/profiles/butterfly-flapping.json', and players own that row
-- (user_profile_pictures) and wear it (users.active_picture_id). Moving it to
-- Drive cannot be done the way CLAUDE.md §7.3 asks for a change — a new script —
-- nor by editing only the seed below:
--
--   * Changing only the URL in the INSERT seeds a SECOND 'Butterfly Flapping'
--     row next to the owned one. ON CONFLICT matches asset_url, and the Drive
--     URL conflicts with nothing.
--   * An UPDATE in a later script does not survive the next boot. Every boot
--     runs this script first; still seeding the old URL, it would insert a
--     fresh row there, and the later UPDATE would then hit the UNIQUE asset_url
--     — on every boot, a crash loop.
--
-- So the move lives here, in front of the INSERT, and it is the only kind of
-- edit §7.3 allows an applied script: guards that bring whatever database they
-- meet to the same end state and find nothing to do on the next boot. Every
-- database — fresh, production at v1.3.0, or one a rollback has left with both
-- rows — ends with exactly ONE 'Butterfly Flapping' row, at the Drive URL, on
-- the id it already had. Proven, twice-booted, from a schema built by the
-- v1.3.0 scripts: internal/db/butterfly_drive_test.go.
--
-- The DO block below does two things, in this order.
--
-- 1. FOLD A DUPLICATE. Both URLs can hold a row at once. A rollback to
--    go-server/v1.3.0 re-runs the old INSERT against a database whose row has
--    already moved, and seeds a second row at the old URL — on sale at 4
--    diamonds, so while the rollback lasts anyone may buy it or wear it. (A
--    build that shipped the Drive URL without the move would leave the same
--    pair the other way round.) Retiring the duplicate would not do: whenever
--    somebody had bought or worn it there would still be two rows, and
--    deleting it outright would cascade their purchase away. Instead the two
--    are merged:
--
--      - The OLDER row (lower id) is kept. In both orders that is the row
--        production has had since v1.3.0: it carries the original purchases,
--        the id clients hold as activePictureId, and any re-pricing the owner
--        has done since. The newer one is a fresh seed copy.
--      - Every ownership row on the newer id moves to the kept id. A player
--        holding BOTH ends with one row that keeps everything either purchase
--        paid for: "never runs out" (0) wins; otherwise the later expiry plus
--        whatever was still unexpired on the earlier one, since they paid for
--        both terms and only one row can carry them; the later acquired_at, as
--        a re-purchase stamps; and the two purchase counts added, so the number
--        the next chip purchase writes into its action_id
--        (picture:<user>:<id>:<n>, pictures.go) is past every one the kept id
--        has used.
--      - Every player wearing the newer id wears the kept one.
--      - Only then is the newer row deleted, so its ON DELETE CASCADE and SET
--        NULL find nothing left to act on. Its id is never reused (BIGSERIAL),
--        so a ledger action_id naming it cannot collide with anything later.
--
--    Touching users only when there is a duplicate is deliberate: a normal
--    boot reads two catalogue rows and writes nothing. When it does run, it
--    needs only UPDATE on users, which the app role keeps after the §7
--    handover in ops/DEPLOY.md.
--
-- 2. MOVE THE OLD URL TO DRIVE, in place, so the id — and with it every
--    purchase and every player wearing it — stays exactly as it was. Guarded by
--    NOT EXISTS, so it can never collide with the UNIQUE asset_url (after the
--    fold a Drive row and an old-URL row cannot both be there, but the guard
--    does not rely on that).
--
-- Then the INSERT: a fresh database gets the row straight at the Drive URL; any
-- other conflicts on it and changes nothing.

DO $$
DECLARE
  old_url CONSTANT TEXT := '/profiles/butterfly-flapping.json';
  new_url CONSTANT TEXT := 'https://drive.google.com/uc?export=download&id=19mQ9PjStBJUoFyThaSe97fEcfzARw_Ar';
  stamp   CONSTANT BIGINT := (EXTRACT(EPOCH FROM now()) * 1000)::bigint;
  keep_id BIGINT;
  drop_id BIGINT;
BEGIN
  -- 1. Fold a duplicate. No rows when there are fewer than two, so both stay NULL.
  SELECT min(id), max(id) INTO keep_id, drop_id
    FROM profile_pictures
   WHERE asset_url IN (old_url, new_url)
  HAVING count(*) = 2;

  IF keep_id IS NOT NULL THEN
    UPDATE user_profile_pictures k
       SET acquired_at = GREATEST(k.acquired_at, d.acquired_at),
           expires_at  = CASE
                           WHEN k.expires_at = 0 OR d.expires_at = 0 THEN 0
                           ELSE GREATEST(k.expires_at, d.expires_at)
                                + GREATEST(LEAST(k.expires_at, d.expires_at) - stamp, 0)
                         END,
           purchases   = k.purchases + d.purchases
      FROM user_profile_pictures d
     WHERE k.profile_picture_id = keep_id
       AND d.profile_picture_id = drop_id
       AND d.user_id = k.user_id;

    DELETE FROM user_profile_pictures d
     WHERE d.profile_picture_id = drop_id
       AND EXISTS (SELECT 1 FROM user_profile_pictures k
                    WHERE k.user_id = d.user_id AND k.profile_picture_id = keep_id);

    UPDATE user_profile_pictures
       SET profile_picture_id = keep_id
     WHERE profile_picture_id = drop_id;

    UPDATE users
       SET active_picture_id = keep_id, updated_at = stamp
     WHERE active_picture_id = drop_id;

    DELETE FROM profile_pictures WHERE id = drop_id;
  END IF;

  -- 2. Move the old URL to Drive, keeping the id.
  UPDATE profile_pictures
     SET asset_url = new_url, updated_at = stamp
   WHERE asset_url = old_url
     AND NOT EXISTS (SELECT 1 FROM profile_pictures WHERE asset_url = new_url);
END;
$$;

INSERT INTO profile_pictures (name, asset_url, asset_format, currency, type, cost, duration_days, is_active, sort_order, created_at, updated_at)
SELECT name, asset_url, asset_format, currency, type, cost, duration_days, is_active, sort_order,
       (EXTRACT(EPOCH FROM now()) * 1000)::bigint,
       (EXTRACT(EPOCH FROM now()) * 1000)::bigint
  FROM (VALUES
    ('Butterfly Flapping', 'https://drive.google.com/uc?export=download&id=19mQ9PjStBJUoFyThaSe97fEcfzARw_Ar',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 4::bigint, 100, TRUE, 170),
    ('Toucan Flying',      'https://drive.google.com/uc?export=download&id=1HdjPRNx4vPO3EI-_U1Z1UQa8mprLdRNM',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 3::bigint, 100, TRUE, 180),
    ('Live Chatbot',       'https://drive.google.com/uc?export=download&id=1msaoUAeJipCWCy0q8TABPKxWc8ExLMjm',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 1::bigint, 100, TRUE, 190),
    ('Paper Plane',        'https://drive.google.com/uc?export=download&id=1PmclJnzKyczYNi3YSIxAStPWLI60f3-8',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 1::bigint, 100, TRUE, 200),
    ('Bouncing Dots',      'https://drive.google.com/uc?export=download&id=1FfiTWCqv_r0_wllt9GXKDhwVKxSZ823V',
     'LOTTIE', 'DIAMOND', 'PREMIUM', 1::bigint, 100, TRUE, 210)
  ) AS seed(name, asset_url, asset_format, currency, type, cost, duration_days, is_active, sort_order)
    ON CONFLICT (asset_url) DO NOTHING;
