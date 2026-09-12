-- King Teen Patti — the profile-picture catalogue (DML).
--
-- Data, not structure: V1.0.0__baseline.sql builds the tables, this fills one
-- of them. Separate on purpose — a price change or a new picture is a row, and
-- a row should never require reopening a structural migration.
--
-- Idempotent, like every script here: the server has no schema history table
-- and runs all of them on every boot, so this must be indistinguishable from
-- having run once. ON CONFLICT on the natural key (image_url) does that, and
-- it also means the seed never rewrites a row the owner has since re-priced,
-- renamed, reordered or retired. Editing the catalogue afterwards is an
-- UPDATE, not a code change; this script only ever puts the starting set there.
--
-- Which animals cost chips is a product decision, not a technical one — the
-- six showiest are premium at 10k/25k/50k against a 2,00,000 welcome. Change
-- them with `UPDATE profile_pictures SET type = …, cost = … WHERE name = …`.

INSERT INTO profile_pictures (name, image_url, type, cost, is_active, sort_order, created_at, updated_at)
SELECT name, image_url, type, cost, is_active, sort_order,
       (EXTRACT(EPOCH FROM now()) * 1000)::bigint,
       (EXTRACT(EPOCH FROM now()) * 1000)::bigint
  FROM (VALUES
    ('Bear',     'https://lh3.googleusercontent.com/d/1cMAxBlDvKxPpPyOKffLsjM0RDxPUdC-_=s256',
     'FREE',       0::bigint, TRUE,   10),
    ('Cat',      'https://lh3.googleusercontent.com/d/1fTFvJGmCOaFF-mCm_4XAdyjaRFw3Sf9a=s256',
     'FREE',       0::bigint, TRUE,   20),
    ('Dog',      'https://lh3.googleusercontent.com/d/1hZ2iw1UkqHJN18MLUhRTZGbgLBm-7dBS=s256',
     'FREE',       0::bigint, TRUE,   30),
    ('Frog',     'https://lh3.googleusercontent.com/d/1JNMYRv7JtMkfkhEebxLIpTEx4TVMIV-7=s256',
     'FREE',       0::bigint, TRUE,   40),
    ('Horse',    'https://lh3.googleusercontent.com/d/16v7Hh1ZknhM79ZR0KvelT48J4h2T-wyd=s256',
     'FREE',       0::bigint, TRUE,   50),
    ('Koala',    'https://lh3.googleusercontent.com/d/1eRCQHZY-GJc5I2skndx6eyegFhTDCXoH=s256',
     'FREE',       0::bigint, TRUE,   60),
    ('Monkey',   'https://lh3.googleusercontent.com/d/1NJDPIyXjEDEj4nRYEu1KTUjGDNQGqAfg=s256',
     'FREE',       0::bigint, TRUE,   70),
    ('Penguin',  'https://lh3.googleusercontent.com/d/11MRH75SHIbZJzeK_tkQp6Gt6Z5GFJlaH=s256',
     'FREE',       0::bigint, TRUE,   80),
    ('Rabbit',   'https://lh3.googleusercontent.com/d/1wIdpZ7RMytoy9rhpA411lZFz7CbjdyM3=s256',
     'FREE',       0::bigint, TRUE,   90),
    ('Fox',      'https://lh3.googleusercontent.com/d/1qBwGLPAEBr2y5Y2_EVCAd0jQWDeCcUOW=s256',
     'PREMIUM', 10000::bigint, TRUE,  100),
    ('Owl',      'https://lh3.googleusercontent.com/d/125zcjmHrYFGg0jMFm0zqpRg_G8VNSr5L=s256',
     'PREMIUM', 10000::bigint, TRUE,  110),
    ('Lion',     'https://lh3.googleusercontent.com/d/1weXwu_K_35tQHYg92C4tIB9TwM7mBDab=s256',
     'PREMIUM', 25000::bigint, TRUE,  120),
    ('Tiger',    'https://lh3.googleusercontent.com/d/1L-focNnL0yNJueAArM-YfHE9kX0VZv3T=s256',
     'PREMIUM', 25000::bigint, TRUE,  130),
    ('Panda',    'https://lh3.googleusercontent.com/d/1zCySFnbUMtnBjv1g_u9nruHZM5PIdnt_=s256',
     'PREMIUM', 50000::bigint, TRUE,  140),
    ('Wolf',     'https://lh3.googleusercontent.com/d/1LB0wQaR_rq3bYk9oN5P6RWsEm5-oIXae=s256',
     'PREMIUM', 50000::bigint, TRUE,  150)
  ) AS seed(name, image_url, type, cost, is_active, sort_order)
    ON CONFLICT (image_url) DO NOTHING;
