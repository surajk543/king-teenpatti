-- Profile-picture catalogue: every bundled SVG, all FREE.
--
-- Idempotent on image_url, so it is safe to run twice and it will not
-- overwrite a row you have since renamed or reordered by hand.
-- default.svg is deliberately absent: it is the fallback drawn when a
-- picture fails to load, not a picture anybody should be able to choose.
INSERT INTO profile_pictures (name, image_url, type, cost, is_active, sort_order, created_at, updated_at)
VALUES
  ('Bear',    '/profiles/bear.svg',    'FREE', 0, TRUE,  10, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Cat',     '/profiles/cat.svg',     'FREE', 0, TRUE,  20, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Dog',     '/profiles/dog.svg',     'FREE', 0, TRUE,  30, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Fox',     '/profiles/fox.svg',     'FREE', 0, TRUE,  40, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Frog',    '/profiles/frog.svg',    'FREE', 0, TRUE,  50, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Horse',   '/profiles/horse.svg',   'FREE', 0, TRUE,  60, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Koala',   '/profiles/koala.svg',   'FREE', 0, TRUE,  70, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Lion',    '/profiles/lion.svg',    'FREE', 0, TRUE,  80, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Monkey',  '/profiles/monkey.svg',  'FREE', 0, TRUE,  90, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Owl',     '/profiles/owl.svg',     'FREE', 0, TRUE, 100, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Panda',   '/profiles/panda.svg',   'FREE', 0, TRUE, 110, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Penguin', '/profiles/penguin.svg', 'FREE', 0, TRUE, 120, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Rabbit',  '/profiles/rabbit.svg',  'FREE', 0, TRUE, 130, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Tiger',   '/profiles/tiger.svg',   'FREE', 0, TRUE, 140, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Wolf',    '/profiles/wolf.svg',    'FREE', 0, TRUE, 150, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint)
ON CONFLICT (image_url) DO NOTHING;

-- The INSERT above cannot change a row that is already there, so if the
-- catalogue was seeded with the premium tier, this is what actually makes
-- everything free. The CHECK constraint requires cost = 0 for a FREE row, so
-- the two columns have to move together.
UPDATE profile_pictures
   SET type = 'FREE',
       cost = 0,
       updated_at = (EXTRACT(EPOCH FROM now())*1000)::bigint
 WHERE type <> 'FREE';
