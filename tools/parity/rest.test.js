/**
 * REST parity: login providers, sessions, profile, rewards, health, error
 * envelopes — everything a client reaches over HTTP (integration.test.js #1–#9,
 * #36; statsAndRewards.test.js #4–#11 and #13 via the reward/avatar routes;
 * lobbyRules.test.js name rules via POST /api/profile/name).
 *
 * The few places where DECISIONS.md §5 records a deliberate Go difference (body
 * parse failures, unknown /api paths) branch on PARITY_TARGET and say so.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  http, login, guestLogin, me, health, openClient, closeAll, stakeCounter, isNode, isGo, profile,
  assertKeys, decodeJwt, signJwt, UUID, pause, baseUrl,
} from './lib/harness.mjs';
import { query, closeDb, wallet, setWallet } from './lib/db.mjs';

test.after(closeDb);

const uniqueStake = stakeCounter(100);

const USER_KEYS = [
  'id', 'provider', 'displayName', 'email', 'avatarUrl', 'providerAvatarUrl', 'activePictureId', 'chips',
  'handsPlayed', 'handsWon', 'handsLost', 'handsLeftMid', 'totalWinnings', 'biggestPot', 'rewards',
  'createdAt', 'lastLoginAt',
];
const REWARD_KEYS = [
  'milestoneAvailable', 'milestoneAt', 'milestoneReward', 'milestoneEvery', 'handsToNextMilestone',
  'bonusReadyAt', 'bonusAvailable', 'bonusReward', 'bonusIntervalMs',
];

// ------------------------------------------------------------------ login

test('guest login creates an account with the welcome chip grant, in the exact public-user shape', async () => {
  const { status, body } = await login({ provider: 'guest', deviceId: 'device-guest-0001', displayName: 'Suraj' });
  assert.equal(status, 200);
  assertKeys(body, ['token', 'user', 'isNew', 'welcomeChips'], 'login response');
  assert.equal(body.isNew, true);
  assert.equal(body.welcomeChips, profile.welcomeChips);

  const { user } = body;
  assertKeys(user, USER_KEYS, 'user');
  assertKeys(user.rewards, REWARD_KEYS, 'user.rewards');
  assert.match(user.id, UUID);
  assert.equal(user.provider, 'guest');
  assert.equal(user.displayName, 'Suraj');
  assert.equal(user.email, null);
  assert.equal(user.avatarUrl, null);
  assert.equal(user.providerAvatarUrl, null);
  assert.equal(user.activePictureId, null);
  assert.equal(user.chips, profile.welcomeChips, 'a first-time player is granted 2 lakh chips');
  for (const counter of ['handsPlayed', 'handsWon', 'handsLost', 'handsLeftMid', 'totalWinnings', 'biggestPot']) {
    assert.equal(user[counter], 0, counter);
  }
  assert.deepEqual(user.rewards, {
    milestoneAvailable: false,
    milestoneAt: 0,
    milestoneReward: 25000,
    milestoneEvery: 25,
    handsToNextMilestone: 25,
    bonusReadyAt: 0,
    bonusAvailable: true,
    bonusReward: 10000,
    bonusIntervalMs: 14400000,
  });
  assert.equal(typeof user.createdAt, 'number');
  assert.equal(typeof user.lastLoginAt, 'number');
  assert.ok(Math.abs(user.createdAt - Date.now()) < 60000, 'createdAt is epoch milliseconds');
  assert.equal(user.createdAt, user.lastLoginAt);

  // The ledger explains the wallet from the very first row.
  const { rows } = await query('SELECT reason, delta, balance, action_id, hand_id FROM chip_ledger WHERE user_id = $1', [user.id]);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].reason, 'welcome_bonus');
  assert.equal(rows[0].delta, profile.welcomeChips);
  assert.equal(rows[0].balance, profile.welcomeChips);
  assert.equal(rows[0].action_id, null);
  assert.equal(rows[0].hand_id, null);
});

test('the session token is an HS256 JWT with exactly the claims the clients rely on', async () => {
  const { token, user } = await guestLogin('device-jwt-0001', 'Jwt');
  const { header, payload } = decodeJwt(token);
  assert.equal(header.alg, 'HS256');
  assert.equal(header.typ, 'JWT');
  assertKeys(payload, ['sub', 'provider', 'name', 'iat', 'exp'], 'jwt claims');
  assert.equal(payload.sub, user.id);
  assert.equal(payload.provider, 'guest');
  assert.equal(payload.name, 'Jwt');
  assert.equal(payload.exp - payload.iat, 30 * 24 * 3600, 'JWT_EXPIRES_IN default 30d');
  assert.ok(Math.abs(payload.iat * 1000 - Date.now()) < 60000);
});

test('logging in again from the same device returns the same saved account', async () => {
  const first = await guestLogin('device-returning-0002', 'Returning');
  const second = await guestLogin('device-returning-0002', 'Returning');
  assert.equal(second.isNew, false);
  assert.equal(second.welcomeChips, 0, 'the grant is only ever made once');
  assert.equal(second.user.id, first.user.id);
  assert.equal(second.user.chips, first.user.chips);
  assert.ok(second.user.lastLoginAt >= first.user.lastLoginAt);
  assert.equal(second.user.createdAt, first.user.createdAt);
});

test('a different device is a different account', async () => {
  const a = await guestLogin('device-alpha-0003', 'Alpha');
  const b = await guestLogin('device-beta-0004', 'Beta');
  assert.notEqual(a.user.id, b.user.id);
});

test('the raw device id is never stored; guests are keyed by sha256("teenpatti:" + deviceId)', async () => {
  const { createHash } = await import('node:crypto');
  const { user } = await guestLogin('  device-hash-0005  ', 'Hashed');
  const { rows } = await query('SELECT provider_user_id FROM users WHERE provider = $1', ['guest']);
  assert.ok(rows.length > 0);
  for (const row of rows) {
    assert.notEqual(row.provider_user_id, 'device-guest-0001');
    assert.match(row.provider_user_id, /^[0-9a-f]{64}$/);
  }
  const mine = await query('SELECT provider_user_id FROM users WHERE id = $1', [user.id]);
  const expected = createHash('sha256').update('teenpatti:device-hash-0005').digest('hex');
  assert.equal(mine.rows[0].provider_user_id, expected, 'the device id is trimmed, then hashed');
});

test('a short or missing device id is rejected with the exact envelope', async () => {
  const short = await login({ provider: 'guest', deviceId: 'abc' });
  assert.equal(short.status, 400);
  assert.deepEqual(short.body, {
    error: 'invalid_device_id',
    message: 'A deviceId of at least 8 characters is required',
  });
  const missing = await login({ provider: 'guest' });
  assert.equal(missing.status, 400);
  assert.equal(missing.body.error, 'invalid_device_id');
  const padded = await login({ provider: 'guest', deviceId: '   abcdef   ' });
  assert.equal(padded.status, 400, 'length is checked after trimming');
});

test('an unknown provider is rejected', async () => {
  const result = await login({ provider: 'myspace', deviceId: 'device-xxxx-9999' });
  assert.equal(result.status, 400);
  assert.deepEqual(result.body, { error: 'unknown_provider', message: 'Unsupported login provider "myspace"' });

  const none = await login({});
  assert.equal(none.status, 400);
  assert.equal(none.body.error, 'unknown_provider');
});

test('google and facebook logins (fake providers) create provider-scoped accounts', async () => {
  const google = await login({ provider: 'google', providerUserId: 'google-sub-123', displayName: 'G Player' });
  const facebook = await login({ provider: 'facebook', providerUserId: 'fb-123', displayName: 'F Player' });

  assert.equal(google.status, 200);
  assert.equal(google.body.user.provider, 'google');
  assert.equal(google.body.user.displayName, 'G Player');
  assert.equal(google.body.user.chips, profile.welcomeChips);
  assert.equal(facebook.status, 200);
  assert.equal(facebook.body.user.provider, 'facebook');
  assert.notEqual(google.body.user.id, facebook.body.user.id);

  const again = await login({ provider: 'google', providerUserId: 'google-sub-123', displayName: 'G Player' });
  assert.equal(again.body.user.id, google.body.user.id);
  assert.equal(again.body.isNew, false);

  const stored = await query('SELECT provider_user_id FROM users WHERE id = $1', [google.body.user.id]);
  assert.equal(stored.rows[0].provider_user_id, 'google-sub-123', 'fake provider ids are stored verbatim');
});

test('login names are sanitised, not pattern-checked: punctuation survives, short names fall back', async () => {
  const tricky = await guestLogin('device-name-tricky-01', 'Raj "Ace" {x}');
  assert.equal(tricky.user.displayName, 'Raj "Ace" {x}');

  const short = await guestLogin('device-name-short-01', 'X');
  assert.match(short.user.displayName, /^Guest[0-9A-F]{5}$/, 'one character is too short; the hash names them');

  const blank = await guestLogin('device-name-blank-01');
  assert.match(blank.user.displayName, /^Guest[0-9A-F]{5}$/);

  const long = await guestLogin('device-name-long-01', 'A'.repeat(30));
  assert.equal(long.user.displayName, 'A'.repeat(24), 'sliced to 24');

  const control = await guestLogin('device-name-ctrl-01', 'Suraj\u200b');
  assert.equal(control.user.displayName, 'Suraj', 'control and format characters are stripped');
});

test('every login overwrites the display name with the provider one (known behaviour, requirement 29)', async () => {
  const first = await guestLogin('device-rename-0001', 'Original');
  const renamed = await http('POST', '/api/profile/name', { token: first.token, body: { name: 'Renamed' } });
  assert.equal(renamed.status, 200);
  assert.equal(renamed.body.user.displayName, 'Renamed');
  const again = await guestLogin('device-rename-0001', 'Original');
  assert.equal(again.user.displayName, 'Original');
});

// --------------------------------------------------------------- sessions

test('/api/auth/me returns the persisted profile', async () => {
  const { token, user } = await guestLogin('device-me-0005', 'MeCheck');
  const response = await http('GET', '/api/auth/me', { token });
  assert.equal(response.status, 200);
  assertKeys(response.body, ['user'], '/me body');
  assert.equal(response.body.user.id, user.id);
  assert.equal(response.body.user.chips, profile.welcomeChips);
});

test('bad, missing, foreign-signed and orphaned session tokens are refused with their own codes', async () => {
  const bad = await http('GET', '/api/auth/me', { token: 'nonsense' });
  assert.equal(bad.status, 401);
  assert.equal(bad.body.error, 'invalid_session');
  assert.equal(typeof bad.body.message, 'string');

  const missing = await http('GET', '/api/auth/me');
  assert.equal(missing.status, 401);
  assert.deepEqual(missing.body, { error: 'missing_token', message: 'A session token is required' });

  const now = Math.floor(Date.now() / 1000);
  const foreign = await signJwt({ sub: 'x', provider: 'guest', name: 'x', iat: now, exp: now + 3600 }, 'some-other-secret');
  const rejected = await http('GET', '/api/auth/me', { token: foreign });
  assert.equal(rejected.status, 401);
  assert.equal(rejected.body.error, 'invalid_session');

  // Signed with the server's own secret, for a user that does not exist.
  const orphan = await signJwt({ sub: '00000000-0000-4000-8000-000000000000', provider: 'guest', name: 'Ghost', iat: now, exp: now + 3600 });
  const unknown = await http('GET', '/api/auth/me', { token: orphan });
  assert.equal(unknown.status, 401);
  assert.deepEqual(unknown.body, { error: 'unknown_user', message: 'This account no longer exists' });

  // And a correctly minted token for a real user is accepted — the harness
  // minted this one, so a Node-issued token verifies on a Go server and back.
  const { user } = await guestLogin('device-mint-0001', 'Minted');
  const minted = await signJwt({ sub: user.id, provider: 'guest', name: 'Minted', iat: now, exp: now + 3600 });
  const accepted = await http('GET', '/api/auth/me', { token: minted });
  assert.equal(accepted.status, 200);
  assert.equal(accepted.body.user.id, user.id);

  const expired = await signJwt({ sub: user.id, provider: 'guest', name: 'Minted', iat: now - 7200, exp: now - 3600 });
  const stale = await http('GET', '/api/auth/me', { token: expired });
  assert.equal(stale.status, 401);
  assert.equal(stale.body.error, 'invalid_session');
});

test('/api/auth/me/hands is gone with the hands table, and 404s as JSON', async () => {
  // Owner's decision of 9 Sep 2026: `hands` was write-only, its only reader
  // was this endpoint, and no shipped client called it.
  const { token } = await guestLogin('device-hands-0001', 'Hands');
  const response = await http('GET', '/api/auth/me/hands?limit=3', { token });
  assert.equal(response.status, 404);
  assert.equal(typeof response.body.error, 'string', 'a removed /api/ path still 404s as JSON');
});

// ---------------------------------------------------------------- profile

test('the display name endpoint applies the lobby name rules with exact messages', async () => {
  const { token } = await guestLogin('device-profile-name-01', 'Namer');
  const rename = (name) => http('POST', '/api/profile/name', { token, body: { name } });

  let r = await rename('  Suraj  Kumar ');
  assert.equal(r.status, 200);
  assert.equal(r.body.user.displayName, 'Suraj Kumar', 'trimmed and inner whitespace collapsed');

  r = await rename('Player7');
  assert.equal(r.body.user.displayName, 'Player7');

  for (const name of ['सूरज', 'সুরজ', 'સૂરજ', 'ਸੂਰਜ', 'प्रिया']) {
    r = await rename(name);
    assert.equal(r.status, 200, `${name}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.user.displayName, name, 'Indic vowel signs (\\p{M}) survive');
  }

  r = await rename(' सुरज\t\tकुमार ');
  assert.equal(r.body.user.displayName, 'सुरज कुमार');

  for (const empty of ['', '   ', '\t', null]) {
    r = await rename(empty);
    assert.equal(r.status, 400, JSON.stringify(empty));
    assert.deepEqual(r.body, { error: 'empty_name', message: 'Your name cannot be empty.' });
  }
  r = await http('POST', '/api/profile/name', { token, body: {} });
  assert.deepEqual(r.body, { error: 'empty_name', message: 'Your name cannot be empty.' });

  for (const bad of ['Su<b>raj', 'a@b', 'hi!', '--', 'x_y', 'drop;table', '!Suraj', ' !Suraj']) {
    r = await rename(bad);
    assert.equal(r.status, 400, bad);
    assert.deepEqual(r.body, { error: 'invalid_name', message: 'Letters, numbers and spaces only.' }, bad);
  }

  r = await rename('A'.repeat(30));
  assert.equal(r.status, 400);
  assert.deepEqual(r.body, { error: 'name_too_long', message: 'Keep it to 24 characters or fewer.' });

  r = await rename(`${'A'.repeat(25)}!`);
  assert.equal(r.body.error, 'name_too_long', 'length is checked before the pattern');

  r = await rename('A'.repeat(24));
  assert.equal(r.status, 200);

  // Non-strings are stringified the way Node's template literal does (DECISIONS.md §4).
  r = await rename(123);
  assert.equal(r.status, 200);
  assert.equal(r.body.user.displayName, '123');
  r = await rename({ a: 1 });
  assert.equal(r.status, 400);
  assert.ok(['invalid_name', 'empty_name'].includes(r.body.error));

  const fresh = await me(token);
  assert.equal(fresh.displayName, '123', 'the last successful rename stuck');
});

test('name and picture changes are refused while seated (409 seated)', async () => {
  const account = await guestLogin('device-profile-seated-01', 'Seated');
  const client = await openClient(account.token);
  const joined = await client.emit('room:quickJoin', { bootAmount: uniqueStake() });
  assert.equal(joined.ok, true);

  const name = await http('POST', '/api/profile/name', { token: account.token, body: { name: 'Nope' } });
  assert.equal(name.status, 409);
  assert.deepEqual(name.body, { error: 'seated', message: 'You can only change your name in the lobby.' });

  const avatar = await http('POST', '/api/profile/avatar', { token: account.token, body: { avatar: 1 } });
  assert.equal(avatar.status, 409);
  assert.deepEqual(avatar.body, { error: 'seated', message: 'You cannot change your picture while you are at a table.' });

  // A seated wallet may only move at the three hand checkpoints, so the
  // picture shop is shut at the table too.
  const buy = await http('POST', '/api/profile/picture/buy', { token: account.token, body: { pictureId: 1 } });
  assert.equal(buy.status, 409);
  assert.deepEqual(buy.body, { error: 'seated', message: 'You cannot buy a picture while you are at a table.' });

  await client.close();
  await pause(50);
  const after = await http('POST', '/api/profile/name', { token: account.token, body: { name: 'Free Again' } });
  assert.equal(after.status, 200, 'back in the lobby the change goes through');
});

test('the picture catalogue is listed, worn and cleared', async () => {
  const listed = await http('GET', '/api/profiles');
  assert.equal(listed.status, 200);
  assertKeys(listed.body, ['profiles']);
  const { profiles } = listed.body;
  assert.ok(profiles.length >= 1);

  for (const entry of profiles) {
    assertKeys(entry, ['id', 'name', 'url', 'type', 'cost', 'sortOrder', 'owned']);
    assert.equal(typeof entry.id, 'number');
    assert.ok(entry.name.length > 0);
    // image_url is whatever a client can load: a path into PUBLIC_DIR for the
    // bundled art, or an absolute URL when a picture is hosted elsewhere (the
    // animated ones are dotLottie on lottie.host).
    assert.match(entry.url, /^(\/profiles\/.+\.(svg|png|jpg|jpeg|webp)|https?:\/\/.+)$/i);
    assert.ok(['FREE', 'PREMIUM'].includes(entry.type));
    // The schema's own CHECK, seen from the outside.
    if (entry.type === 'FREE') assert.equal(entry.cost, 0);
    else assert.ok(entry.cost > 0);
    // Anonymous: free pictures are everyone's, premium ones are nobody's.
    assert.equal(entry.owned, entry.type === 'FREE');
  }
  const order = profiles.map((p) => p.sortOrder);
  assert.deepEqual(order, [...order].sort((a, b) => a - b), 'listed in display order');

  const free = profiles.find((p) => p.type === 'FREE');
  const premium = profiles.find((p) => p.type === 'PREMIUM');
  assert.ok(free && premium, 'the seeded catalogue has both tiers');

  // A bundled picture specifically: a hosted one (the animated dotLottie) is
  // not served by this server at all, so picking "the first free row" would
  // start failing the day one sorts to the front.
  const local = profiles.find((p) => p.url.startsWith('/profiles/'));
  const served = await http('GET', local.url, { raw: true });
  assert.equal(served.status, 200);
  assert.match(served.headers.get('content-type') ?? '', /^image\/svg\+xml/);

  const { token } = await guestLogin('device-avatar-0001', 'Avatar');
  let r = await http('POST', '/api/profile/avatar', { token, body: { avatar: free.id } });
  assert.equal(r.status, 200);
  assertKeys(r.body, ['user']);
  assert.equal(r.body.user.activePictureId, free.id, 'stored as a catalogue id');
  assert.equal(r.body.user.avatarUrl, free.url, 'the choice wins, resolved to its image');
  assert.equal(r.body.user.providerAvatarUrl, null);

  // An id that is not a catalogue row — which is also where an old client
  // sending a file name lands.
  for (const bad of ['nope.svg', '', 'bear.svg', 0, -1, false, 999999]) {
    r = await http('POST', '/api/profile/avatar', { token, body: { avatar: bad } });
    assert.equal(r.status, 400, JSON.stringify(bad));
    assert.deepEqual(r.body, { error: 'unknown_avatar', message: 'That picture is not available.' });
  }

  // A premium picture cannot be worn until it is bought.
  r = await http('POST', '/api/profile/avatar', { token, body: { avatar: premium.id } });
  assert.equal(r.status, 403);
  assert.deepEqual(r.body, { error: 'picture_locked', message: 'Unlock that picture before you can wear it.' });

  r = await http('POST', '/api/profile/avatar', { token, body: { avatar: null } });
  assert.equal(r.status, 200);
  assert.equal(r.body.user.activePictureId, null);
  assert.equal(r.body.user.avatarUrl, null, 'cleared back to the (absent) provider picture');

  r = await http('POST', '/api/profile/avatar', { token, body: {} });
  assert.equal(r.status, 200, 'a missing avatar field also clears');
});

test('a premium picture is bought once, with chips, and then can be worn', async () => {
  const { profiles } = (await http('GET', '/api/profiles')).body;
  const premium = profiles.filter((p) => p.type === 'PREMIUM').sort((a, b) => a.cost - b.cost)[0];
  const free = profiles.find((p) => p.type === 'FREE');
  assert.ok(premium, 'the seeded catalogue has a premium picture');

  const { token, user } = await guestLogin('device-picture-0001', 'Buyer');
  const before = user.chips;

  let r = await http('POST', '/api/profile/picture/buy', { token, body: { pictureId: premium.id } });
  assert.equal(r.status, 200);
  assertKeys(r.body, ['user', 'picture', 'charged', 'spent']);
  assert.equal(r.body.charged, true);
  assert.equal(r.body.spent, premium.cost);
  assert.equal(r.body.picture.owned, true);
  assert.equal(r.body.user.chips, before - premium.cost, 'the price came out of the wallet');
  // Buying does not dress the player.
  assert.equal(r.body.user.activePictureId, null);

  // The listing now says it is theirs — but only to them.
  const mine = (await http('GET', '/api/profiles', { token })).body.profiles;
  assert.equal(mine.find((p) => p.id === premium.id).owned, true);
  const anon = (await http('GET', '/api/profiles')).body.profiles;
  assert.equal(anon.find((p) => p.id === premium.id).owned, false);

  // And now it can be worn.
  r = await http('POST', '/api/profile/avatar', { token, body: { avatar: premium.id } });
  assert.equal(r.status, 200);
  assert.equal(r.body.user.avatarUrl, premium.url);

  // Buying it again is success that charges nothing: a click that arrives
  // twice must not cost twice.
  r = await http('POST', '/api/profile/picture/buy', { token, body: { pictureId: premium.id } });
  assert.equal(r.status, 200);
  assert.equal(r.body.charged, false);
  assert.equal(r.body.spent, 0);
  assert.equal(r.body.user.chips, before - premium.cost, 'the second buy moved nothing');

  // A free picture is not for sale, and an unknown id is unknown.
  r = await http('POST', '/api/profile/picture/buy', { token, body: { pictureId: free.id } });
  assert.equal(r.status, 400);
  assert.deepEqual(r.body, { error: 'picture_free', message: 'That picture is free — just choose it.' });
  for (const bad of [999999, 'wolf.svg', null, '']) {
    r = await http('POST', '/api/profile/picture/buy', { token, body: { pictureId: bad } });
    assert.equal(r.status, 400, JSON.stringify(bad));
    assert.deepEqual(r.body, { error: 'unknown_avatar', message: 'That picture is not available.' });
  }

  // A wallet that cannot cover the price.
  const dearest = profiles.filter((p) => p.type === 'PREMIUM').sort((a, b) => b.cost - a.cost)[0];
  const poor = await guestLogin('device-picture-0002', 'Skint');
  await setWallet(poor.user.id, 1);
  r = await http('POST', '/api/profile/picture/buy', { token: poor.token, body: { pictureId: dearest.id } });
  assert.equal(r.status, 409);
  assert.deepEqual(r.body, { error: 'picture_chips', message: 'You do not have enough chips for that picture.' });
});

// ---------------------------------------------------------------- rewards

test('the milestone reward is refused until 25 played hands, then paid exactly once through the ledger', async () => {
  const { token, user } = await guestLogin('device-milestone-0001', 'Miles');

  let r = await http('POST', '/api/rewards/milestone', { token, body: {} });
  assert.equal(r.status, 409);
  assertKeys(r.body, ['error', 'message', 'user']);
  assert.equal(r.body.error, 'reward_not_available');
  assert.equal(r.body.message, 'No milestone reward is waiting yet.');
  assert.equal(r.body.user.id, user.id);

  await query('UPDATE users SET hands_played = $1 WHERE id = $2', [24, user.id]);
  const nearly = await me(token);
  assert.equal(nearly.rewards.milestoneAvailable, false);
  assert.equal(nearly.rewards.handsToNextMilestone, 1);
  assert.equal(nearly.rewards.milestoneAt, 0);

  await query('UPDATE users SET hands_played = $1 WHERE id = $2', [50, user.id]);
  const ready = await me(token);
  assert.equal(ready.rewards.milestoneAvailable, true);
  assert.equal(ready.rewards.milestoneAt, 50);
  assert.equal(ready.rewards.handsToNextMilestone, 25, 'says 25, not 0, at an exact multiple');
  const before = ready.chips;

  r = await http('POST', '/api/rewards/milestone', { token });
  assert.equal(r.status, 200);
  assertKeys(r.body, ['claimed', 'amount', 'milestone', 'user']);
  assert.equal(r.body.claimed, true);
  assert.equal(r.body.amount, 25000);
  assert.equal(r.body.milestone, 50);
  assert.equal(r.body.user.chips, before + 25000);
  assert.equal(r.body.user.rewards.milestoneAvailable, false);

  r = await http('POST', '/api/rewards/milestone', { token });
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'reward_not_available');
  assert.equal(r.body.user.chips, before + 25000, 'nothing paid twice');

  const { rows } = await query(
    "SELECT delta, balance, action_id, hand_id FROM chip_ledger WHERE user_id = $1 AND reason = 'milestone_reward'",
    [user.id],
  );
  assert.equal(rows.length, 1);
  assert.equal(rows[0].delta, 25000);
  assert.equal(rows[0].balance, before + 25000);
  assert.equal(rows[0].action_id, `${user.id}:milestone:50`);
  assert.equal(rows[0].hand_id, null);
  assert.equal(await wallet(user.id), before + 25000);

  // The next multiple unlocks it again.
  await query('UPDATE users SET hands_played = $1 WHERE id = $2', [74, user.id]);
  assert.equal((await me(token)).rewards.milestoneAvailable, false);
  await query('UPDATE users SET hands_played = $1 WHERE id = $2', [75, user.id]);
  r = await http('POST', '/api/rewards/milestone', { token });
  assert.equal(r.status, 200);
  assert.equal(r.body.milestone, 75);
});

test('the timed bonus pays 10,000 at once, then recharges for four hours in the database', async () => {
  const { token, user } = await guestLogin('device-bonus-0001', 'Bonus');
  const before = user.chips;
  assert.equal(user.rewards.bonusAvailable, true);

  const started = Date.now();
  let r = await http('POST', '/api/rewards/bonus', { token, body: {} });
  assert.equal(r.status, 200);
  assertKeys(r.body, ['claimed', 'amount', 'readyAt', 'user']);
  assert.equal(r.body.claimed, true);
  assert.equal(r.body.amount, 10000);
  assert.ok(Math.abs(r.body.readyAt - (started + 4 * 3600 * 1000)) < 2000, `readyAt ${r.body.readyAt} is now + 4h`);
  assert.equal(r.body.user.chips, before + 10000);
  assert.equal(r.body.user.rewards.bonusAvailable, false);
  assert.equal(r.body.user.rewards.bonusReadyAt, r.body.readyAt);
  const { readyAt } = r.body;

  r = await http('POST', '/api/rewards/bonus', { token });
  assert.equal(r.status, 409);
  assertKeys(r.body, ['error', 'message', 'readyAt', 'user']);
  assert.equal(r.body.error, 'reward_not_ready');
  assert.equal(r.body.message, 'The bonus is still recharging.');
  assert.equal(r.body.readyAt, readyAt);
  assert.equal(r.body.user.chips, before + 10000);

  const { rows } = await query('SELECT next_bonus_at FROM users WHERE id = $1', [user.id]);
  assert.equal(rows[0].next_bonus_at, readyAt, 'the countdown lives in the database');

  const ledger = await query("SELECT delta, action_id FROM chip_ledger WHERE user_id = $1 AND reason = 'timed_bonus'", [user.id]);
  assert.equal(ledger.rows.length, 1);
  assert.equal(ledger.rows[0].delta, 10000);
  assert.equal(ledger.rows[0].action_id, null);

  await query('UPDATE users SET next_bonus_at = $1 WHERE id = $2', [Date.now() - 1, user.id]);
  assert.equal((await me(token)).rewards.bonusAvailable, true);
  r = await http('POST', '/api/rewards/bonus', { token });
  assert.equal(r.status, 200);
  assert.equal(r.body.user.chips, before + 20000);
});

test('reward and profile routes need a session', async () => {
  for (const path of ['/api/rewards/milestone', '/api/rewards/bonus', '/api/profile/name', '/api/profile/avatar']) {
    const r = await http('POST', path, { body: {} });
    assert.equal(r.status, 401, path);
    assert.equal(r.body.error, 'missing_token');
  }
});

// ---------------------------------------------------------------- health etc.

test('health reports live counts with the shape the tools read', async () => {
  const body = await health();
  assertKeys(body, ['ok', 'uptime', 'tables', 'players', 'activeHands', 'sockets', 'process', 'db', 'live']);
  assert.equal(body.ok, true);
  assert.equal(typeof body.uptime, 'number');
  assert.ok(body.uptime > 0);
  for (const key of ['tables', 'players', 'activeHands', 'sockets']) {
    assert.equal(typeof body[key], 'number', key);
    assert.ok(Number.isInteger(body[key]), key);
  }
  const PROCESS_KEYS = ['pid', 'node', 'rssMb', 'heapUsedMb', 'heapTotalMb', 'externalMb', 'cpuPercent', 'loopLagP50Ms', 'loopLagP99Ms', 'loopLagMaxMs'];
  for (const key of PROCESS_KEYS) assert.ok(key in body.process, `process.${key}`);
  assert.equal(typeof body.process.pid, 'number');
  assert.equal(typeof body.process.node, 'string');
  assert.ok(body.process.rssMb > 0);
  // The live-state store (LIVE_STATE_PLAN.md): "memory" when REDIS_URL is
  // unset, "redis" when it is. `tables` is how many snapshots it holds — and
  // that is the whole of it, because PostgreSQL keeps no game state and so
  // has no durable copy to lag behind.
  assertKeys(body.live, ['kind', 'ok', 'tables']);
  assert.ok(['memory', 'redis'].includes(body.live.kind), `live.kind ${body.live.kind}`);
  assert.equal(typeof body.live.ok, 'boolean');
  assert.equal(typeof body.live.tables, 'number');
  assertKeys(body.db, ['total', 'idle', 'waiting']);
  for (const key of ['total', 'idle', 'waiting']) assert.equal(typeof body.db[key], 'number', `db.${key}`);

  // The counts move with the tables.
  const account = await guestLogin('device-health-0001', 'Healthy');
  const client = await openClient(account.token);
  await client.emit('room:quickJoin', { bootAmount: uniqueStake() });
  const busy = await health();
  assert.ok(busy.tables >= body.tables + 1);
  assert.ok(busy.players >= body.players + 1);
  assert.ok(busy.sockets >= 1);
  await client.close();
});

test('/api/rooms lists public tables with the lobby options', async () => {
  const account = await guestLogin('device-rooms-0001', 'Rooms');
  const client = await openClient(account.token);
  const bootAmount = uniqueStake();
  const joined = await client.emit('room:quickJoin', { bootAmount, category: 'blind' });

  const all = await http('GET', '/api/rooms');
  assert.equal(all.status, 200);
  assertKeys(all.body, ['tables', 'options']);
  const mine = all.body.tables.find((t) => t.roomId === joined.roomId);
  assert.ok(mine, 'the table is listed');
  assertKeys(mine, ['roomId', 'code', 'category', 'state', 'players', 'maxPlayers', 'bootAmount', 'pot']);
  assert.deepEqual(mine, {
    roomId: joined.roomId, code: joined.code, category: 'blind', state: 'waiting', players: 1, maxPlayers: 5, bootAmount, pot: 0,
  });
  assertKeys(all.body.options, ['categories', 'stakes', 'tables', 'entryCapBoot', 'entryCapCategory', 'entryCapMaxChips', 'privateBoot', 'privateMaxPot']);
  assert.deepEqual(all.body.options.categories, ['seen', 'blind']);

  const seenOnly = await http('GET', '/api/rooms?category=seen');
  assert.ok(seenOnly.body.tables.every((t) => t.category === 'seen'));
  const upper = await http('GET', '/api/rooms?category=BLIND');
  assert.ok(upper.body.tables.some((t) => t.roomId === joined.roomId), 'an unknown filter value means no filter');

  await client.close();
});

test('the browser client and its assets are served', async () => {
  const index = await http('GET', '/', { raw: true });
  assert.equal(index.status, 200);
  assert.match(index.headers.get('content-type') ?? '', /^text\/html/);
  assert.match(index.text, /<!doctype html>|<html/i);
  const js = await http('GET', '/client.js', { raw: true });
  assert.equal(js.status, 200);
  assert.match(js.headers.get('content-type') ?? '', /javascript/);
  const missing = await http('GET', '/no-such-file.css', { raw: true });
  assert.equal(missing.status, 404);
});

// ------------------------------------------------------------ error envelopes

test('every JSON error carries {error, message}; unmatched routes are 404', async () => {
  const notFound = await http('GET', '/nothing-here-123', { raw: true });
  assert.equal(notFound.status, 404);
  if (isNode) assert.match(notFound.headers.get('content-type') ?? '', /text\/html/);

  const api404 = await http('GET', '/api/nothing', { raw: true });
  assert.equal(api404.status, 404);
  if (isGo) {
    // DECISIONS.md §5: unknown /api paths answer JSON on the Go server.
    const body = JSON.parse(api404.text);
    assert.equal(body.error, 'not_found');
    assert.equal(typeof body.message, 'string');
  }

  const wrongMethod = await http('GET', '/api/auth/login', { raw: true });
  assert.equal(wrongMethod.status, 404);
});

test('a malformed request body is refused (status per DECISIONS.md §5)', async () => {
  const malformed = await http('POST', '/api/auth/login', { body: '{not json' });
  if (isNode) {
    // Express's body parser error falls through to the generic 500 handler.
    assert.equal(malformed.status, 500);
    assert.deepEqual(malformed.body, { error: 'internal_error', message: 'Something went wrong' });
  } else {
    // Deliberate deviation: the honest status.
    assert.equal(malformed.status, 400);
    assert.equal(malformed.body.error, 'invalid_json');
    assert.equal(typeof malformed.body.message, 'string');
  }

  const huge = await http('POST', '/api/auth/login', {
    body: JSON.stringify({ provider: 'guest', deviceId: 'device-huge-0001', displayName: 'x'.repeat(40000) }),
  });
  if (isNode) {
    assert.equal(huge.status, 500);
    assert.equal(huge.body.error, 'internal_error');
  } else {
    assert.equal(huge.status, 413);
    assert.equal(typeof huge.body.error, 'string');
  }

  // No body at all is an empty object → unknown_provider on both.
  const empty = await fetch(`${baseUrl}/api/auth/login`, { method: 'POST' });
  assert.equal(empty.status, 400);
  assert.equal((await empty.json()).error, 'unknown_provider');

  // A non-JSON content type is ignored, not parsed.
  const text = await http('POST', '/api/auth/login', {
    body: JSON.stringify({ provider: 'guest', deviceId: 'device-text-0001' }),
    headers: { 'content-type': 'text/plain' },
  });
  assert.equal(text.status, 400);
  assert.equal(text.body.error, 'unknown_provider');
});

test('two seated players can leave cleanly (helper sanity)', async () => {
  const a = await guestLogin('device-rest-tail-a', 'TailA');
  const b = await guestLogin('device-rest-tail-b', 'TailB');
  const ca = await openClient(a.token);
  const cb = await openClient(b.token);
  const bootAmount = uniqueStake();
  await ca.emit('room:quickJoin', { bootAmount });
  await cb.emit('room:quickJoin', { bootAmount });
  await closeAll(ca, cb);
  assert.ok(true);
});
