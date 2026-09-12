-- Profile-picture catalogue, hosted on Google Drive, all FREE.
--
-- image_url is whatever a client can actually LOAD, and for Drive that is not
-- the /file/d/<id>/view link: that one is an HTML viewer page and would render
-- nothing. lh3.googleusercontent.com/d/<id> serves the bytes, and Drive
-- rasterises the SVG to PNG on the way out — so these are PNGs, and the "=s256"
-- suffix asks for a 256px one (9 KB instead of the 64-110 KB full render).
--
-- default.svg is deliberately absent: it is the image the app falls back to
-- when a picture will not load, so it ships INSIDE the app
-- (assets/default_avatar.svg) and must not depend on the network. It is also
-- not something a player should be able to choose.
INSERT INTO profile_pictures (name, image_url, type, cost, is_active, sort_order, created_at, updated_at)
VALUES
  ('Bear',    'https://lh3.googleusercontent.com/d/1cMAxBlDvKxPpPyOKffLsjM0RDxPUdC-_=s256', 'FREE', 0, TRUE,  10, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Cat',     'https://lh3.googleusercontent.com/d/1fTFvJGmCOaFF-mCm_4XAdyjaRFw3Sf9a=s256', 'FREE', 0, TRUE,  20, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Dog',     'https://lh3.googleusercontent.com/d/1hZ2iw1UkqHJN18MLUhRTZGbgLBm-7dBS=s256', 'FREE', 0, TRUE,  30, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Fox',     'https://lh3.googleusercontent.com/d/1qBwGLPAEBr2y5Y2_EVCAd0jQWDeCcUOW=s256', 'FREE', 0, TRUE,  40, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Frog',    'https://lh3.googleusercontent.com/d/1JNMYRv7JtMkfkhEebxLIpTEx4TVMIV-7=s256', 'FREE', 0, TRUE,  50, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Horse',   'https://lh3.googleusercontent.com/d/16v7Hh1ZknhM79ZR0KvelT48J4h2T-wyd=s256', 'FREE', 0, TRUE,  60, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Koala',   'https://lh3.googleusercontent.com/d/1eRCQHZY-GJc5I2skndx6eyegFhTDCXoH=s256', 'FREE', 0, TRUE,  70, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Lion',    'https://lh3.googleusercontent.com/d/1weXwu_K_35tQHYg92C4tIB9TwM7mBDab=s256', 'FREE', 0, TRUE,  80, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Monkey',  'https://lh3.googleusercontent.com/d/1NJDPIyXjEDEj4nRYEu1KTUjGDNQGqAfg=s256', 'FREE', 0, TRUE,  90, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Owl',     'https://lh3.googleusercontent.com/d/125zcjmHrYFGg0jMFm0zqpRg_G8VNSr5L=s256', 'FREE', 0, TRUE, 100, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Panda',   'https://lh3.googleusercontent.com/d/1zCySFnbUMtnBjv1g_u9nruHZM5PIdnt_=s256', 'FREE', 0, TRUE, 110, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Penguin', 'https://lh3.googleusercontent.com/d/11MRH75SHIbZJzeK_tkQp6Gt6Z5GFJlaH=s256', 'FREE', 0, TRUE, 120, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Rabbit',  'https://lh3.googleusercontent.com/d/1wIdpZ7RMytoy9rhpA411lZFz7CbjdyM3=s256', 'FREE', 0, TRUE, 130, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Tiger',   'https://lh3.googleusercontent.com/d/1L-focNnL0yNJueAArM-YfHE9kX0VZv3T=s256', 'FREE', 0, TRUE, 140, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint),
  ('Wolf',    'https://lh3.googleusercontent.com/d/1LB0wQaR_rq3bYk9oN5P6RWsEm5-oIXae=s256', 'FREE', 0, TRUE, 150, (EXTRACT(EPOCH FROM now())*1000)::bigint, (EXTRACT(EPOCH FROM now())*1000)::bigint)
ON CONFLICT (image_url) DO NOTHING;

-- ALTERNATIVE, and probably the one you want.
--
-- The catalogue already holds these fifteen animals pointing at /profiles/*.svg,
-- and image_url is UNIQUE on the URL rather than on the name — so the INSERT
-- above ADDS fifteen more rows and every animal appears twice in the picker.
-- To move the existing rows onto Drive instead, keeping their ids (and so every
-- player's chosen picture and every premium purchase), re-point them by name:
UPDATE profile_pictures p SET
       image_url  = v.url,
       updated_at = (EXTRACT(EPOCH FROM now())*1000)::bigint
  FROM (VALUES
         ('Bear', 'https://lh3.googleusercontent.com/d/1cMAxBlDvKxPpPyOKffLsjM0RDxPUdC-_=s256'),
         ('Cat', 'https://lh3.googleusercontent.com/d/1fTFvJGmCOaFF-mCm_4XAdyjaRFw3Sf9a=s256'),
         ('Dog', 'https://lh3.googleusercontent.com/d/1hZ2iw1UkqHJN18MLUhRTZGbgLBm-7dBS=s256'),
         ('Fox', 'https://lh3.googleusercontent.com/d/1qBwGLPAEBr2y5Y2_EVCAd0jQWDeCcUOW=s256'),
         ('Frog', 'https://lh3.googleusercontent.com/d/1JNMYRv7JtMkfkhEebxLIpTEx4TVMIV-7=s256'),
         ('Horse', 'https://lh3.googleusercontent.com/d/16v7Hh1ZknhM79ZR0KvelT48J4h2T-wyd=s256'),
         ('Koala', 'https://lh3.googleusercontent.com/d/1eRCQHZY-GJc5I2skndx6eyegFhTDCXoH=s256'),
         ('Lion', 'https://lh3.googleusercontent.com/d/1weXwu_K_35tQHYg92C4tIB9TwM7mBDab=s256'),
         ('Monkey', 'https://lh3.googleusercontent.com/d/1NJDPIyXjEDEj4nRYEu1KTUjGDNQGqAfg=s256'),
         ('Owl', 'https://lh3.googleusercontent.com/d/125zcjmHrYFGg0jMFm0zqpRg_G8VNSr5L=s256'),
         ('Panda', 'https://lh3.googleusercontent.com/d/1zCySFnbUMtnBjv1g_u9nruHZM5PIdnt_=s256'),
         ('Penguin', 'https://lh3.googleusercontent.com/d/11MRH75SHIbZJzeK_tkQp6Gt6Z5GFJlaH=s256'),
         ('Rabbit', 'https://lh3.googleusercontent.com/d/1wIdpZ7RMytoy9rhpA411lZFz7CbjdyM3=s256'),
         ('Tiger', 'https://lh3.googleusercontent.com/d/1L-focNnL0yNJueAArM-YfHE9kX0VZv3T=s256'),
         ('Wolf', 'https://lh3.googleusercontent.com/d/1LB0wQaR_rq3bYk9oN5P6RWsEm5-oIXae=s256')
       ) AS v(name, url)
 WHERE p.name = v.name;
