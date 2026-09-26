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
  assertKeys, decodeJwt, signJwt, UUID, pause, baseUrl, CONFIG_KEYS, closeOpenClients,
} from './lib/harness.mjs';
import { query, closeDb, wallet, setWallet } from './lib/db.mjs';

// A test that fails with a socket open would otherwise hold the runner until
// the file timeout.
test.after(async () => {
  await closeOpenClients();
  await closeDb();
});

const uniqueStake = stakeCounter(100);

const USER_KEYS = [
  'id', 'provider', 'displayName', 'email', 'avatarUrl', 'providerAvatarUrl', 'activePictureId', 'tablePicture', 'chips', 'diamond', 'hammer', 'missile',
  'handsPlayed', 'handsWon', 'handsLost', 'handsLeftMid', 'totalWinnings', 'biggestPot', 'rewards',
  'createdAt', 'lastLoginAt',
];
const REWARD_KEYS = [
  'milestoneAvailable', 'milestoneAt', 'milestoneReward', 'milestoneEvery', 'handsToNextMilestone',
  'bonusReadyAt', 'bonusAvailable', 'bonusReward', 'bonusIntervalMs',
  'dailyReadyAt', 'dailyAvailable', 'dailyReward', 'dailyHammers', 'dailyIntervalMs',
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
  assert.equal(user.tablePicture, null, 'the table as it comes, until a table picture is laid');
  assert.equal(user.chips, profile.welcomeChips, 'a first-time player is granted 2 lakh chips');
  assert.equal(user.diamond, 9, 'and nine diamonds, the premium currency');
  assert.equal(user.hammer, 20, 'and twenty hammers');
  assert.equal(user.missile, 1, 'and one missile');
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
    dailyReadyAt: 0,
    dailyAvailable: true,
    dailyReward: 100000,
    dailyHammers: 1,
    dailyIntervalMs: 86400000,
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

test('google logins (fake providers) create provider-scoped accounts; facebook is switched off', async () => {
  const google = await login({ provider: 'google', providerUserId: 'google-sub-123', displayName: 'G Player' });
  // Facebook login is switched off for now (owner, 23 Sep 2026): refused as an
  // unsupported provider, the fake path included, and no account is created.
  const facebook = await login({ provider: 'facebook', providerUserId: 'fb-123', displayName: 'F Player' });

  assert.equal(google.status, 200);
  assert.equal(google.body.user.provider, 'google');
  assert.equal(google.body.user.displayName, 'G Player');
  assert.equal(google.body.user.chips, profile.welcomeChips);
  assert.equal(facebook.status, 400);
  assert.deepEqual(facebook.body, { error: 'unknown_provider', message: 'Unsupported login provider "facebook"' });

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

test('a login names only a new account: a chosen name survives the next login (requirement 29, 24 Sep 2026)', async () => {
  const first = await guestLogin('device-rename-0001', 'Original');
  const renamed = await http('POST', '/api/profile/name', { token: first.token, body: { name: 'Renamed' } });
  assert.equal(renamed.status, 200);
  assert.equal(renamed.body.user.displayName, 'Renamed');
  const again = await guestLogin('device-rename-0001', 'Original');
  assert.equal(again.user.displayName, 'Renamed');
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

test('at a table a rename and a chip-priced picture are refused (409 seated); a picture is worn, and bought with hammers', async () => {
  const account = await guestLogin('device-profile-seated-01', 'Seated');
  const client = await openClient(account.token);
  const joined = await client.emit('room:quickJoin', { bootAmount: uniqueStake() });
  assert.equal(joined.ok, true);

  const name = await http('POST', '/api/profile/name', { token: account.token, body: { name: 'Nope' } });
  assert.equal(name.status, 409);
  assert.deepEqual(name.body, { error: 'seated', message: 'You can only change your name in the lobby.' });

  const { profiles } = (await http('GET', '/api/profiles')).body;
  const free = profiles.find((p) => p.type === 'FREE');
  const coin = profiles.find((p) => p.type === 'PREMIUM' && p.currency === 'COIN');
  const hammered = profiles.filter((p) => p.type === 'PREMIUM' && p.currency === 'HAMMER').sort((a, b) => a.cost - b.cost)[0];
  assert.ok(free && coin && hammered, 'the seeded catalogue has a free, a chip-priced and a hammer picture');

  // Wearing a picture moves no wallet (owner, 13 Sep 2026): allowed, and the
  // seat shows it without anyone rejoining.
  const avatar = await http('POST', '/api/profile/avatar', { token: account.token, body: { avatar: free.id } });
  assert.equal(avatar.status, 200);
  assert.equal(avatar.body.user.avatarUrl, free.url);
  const seatAvatar = () => client.state()?.seats?.find((s) => s.userId === account.user.id)?.avatarUrl;
  for (let i = 0; i < 40 && seatAvatar() !== free.url; i++) await pause(50);
  assert.equal(seatAvatar(), free.url, 'the seat carries the new picture');

  // A seated wallet's chips may only move at the three hand checkpoints, so a
  // chip-priced picture waits for the lobby ...
  const buy = await http('POST', '/api/profile/picture/buy', { token: account.token, body: { pictureId: coin.id } });
  assert.equal(buy.status, 409);
  assert.deepEqual(buy.body, { error: 'seated', message: 'You can only buy a chip-priced picture in the lobby.' });

  // ... while hammers, which no seat holds (diamonds likewise), still buy.
  const bought = await http('POST', '/api/profile/picture/buy', { token: account.token, body: { pictureId: hammered.id } });
  assert.equal(bought.status, 200);
  assert.equal(bought.body.charged, true);
  assert.equal(bought.body.user.hammer, account.user.hammer - hammered.cost);
  assert.equal(bought.body.user.chips, account.user.chips);

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
    assertKeys(entry, ['id', 'name', 'url', 'assetFormat', 'currency', 'type', 'cost', 'durationDays', 'durationHours', 'sortOrder', 'owned', 'expiresAt']);
    // A premium picture is a rental of days plus hours; a free one never runs
    // out, and nobody owning nothing has an expiry.
    assert.equal(typeof entry.durationDays, 'number');
    assert.equal(typeof entry.durationHours, 'number');
    if (entry.type === 'FREE') {
      assert.equal(entry.durationDays, 0);
      assert.equal(entry.durationHours, 0);
    }
    // How the client renders what url serves; IMAGE covers jpg/jpeg/png.
    assert.ok(['IMAGE', 'SVG', 'LOTTIE', 'RIVE'].includes(entry.assetFormat), 'assetFormat');
    // The wallet cost is paid from.
    assert.ok(['COIN', 'DIAMOND', 'HAMMER'].includes(entry.currency), 'currency');
    assert.equal(entry.expiresAt, 0, 'an anonymous listing has no rental dates');
    assert.equal(typeof entry.id, 'number');
    assert.ok(entry.name.length > 0);
    // image_url is whatever a client can load: a path into PUBLIC_DIR for the
    // art this server serves (the bundled SVGs; a reworked Lottie can be served
    // from there too, as Butterfly Flapping was in go-server/v1.3.0), or an
    // absolute URL when a picture is hosted elsewhere, as every animated one is.
    assert.match(entry.url, /^(\/profiles\/.+\.(svg|png|jpg|jpeg|webp|json|lottie|riv)|https?:\/\/.+)$/i);
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

  // The catalogue's pictures are hosted elsewhere now, so this asserts what is
  // still this server's job: that the profiles directory is served. A row is
  // not the subject any more, so it names a bundled file outright.
  const served = await http('GET', '/profiles/default.svg', { raw: true });
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
  // Coin-priced only: a DIAMOND or HAMMER row can be cheaper in number (Blazing
  // Fire costs 1 hammer) and is paid from a different wallet — their own tests
  // are below.
  const coinPremium = profiles.filter((p) => p.type === 'PREMIUM' && p.currency === 'COIN');
  const premium = [...coinPremium].sort((a, b) => a.cost - b.cost)[0];
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
  const dearest = [...coinPremium].sort((a, b) => b.cost - a.cost)[0];
  const poor = await guestLogin('device-picture-0002', 'Skint');
  await setWallet(poor.user.id, 1);
  r = await http('POST', '/api/profile/picture/buy', { token: poor.token, body: { pictureId: dearest.id } });
  assert.equal(r.status, 409);
  assert.deepEqual(r.body, { error: 'picture_chips', message: 'You do not have enough chips for that picture.' });
});

test('a hammer picture is paid in hammers, never chips or diamonds, and a new account can afford one', async () => {
  const { profiles } = (await http('GET', '/api/profiles')).body;
  const hammered = profiles.filter((p) => p.currency === 'HAMMER');
  // Nineteen of the 30 seeded animated pictures: the owner priced five in
  // diamonds and six in chips (14 Sep 2026; two of them appended after launch),
  // and Love and Kiss and then Dog Dancing, Dance and Cockroach (appended after
  // launch too) joined the hammer shelf the same day.
  assert.equal(hammered.length, 19, 'the seeded animated pictures are priced in hammers');
  const pic = hammered.find((p) => p.cost === 10);
  assert.ok(pic, 'one of them costs 10 hammers');
  assert.equal(pic.type, 'PREMIUM');
  assert.equal(pic.assetFormat, 'LOTTIE');

  const { token, user } = await guestLogin('device-hammer-picture-0001', 'Hammer');
  assert.equal(user.hammer, 20, 'every account starts with twenty hammers');

  let r = await http('POST', '/api/profile/picture/buy', { token, body: { pictureId: pic.id } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assertKeys(r.body, ['user', 'picture', 'charged', 'spent']);
  assert.equal(r.body.charged, true);
  assert.equal(r.body.spent, pic.cost);
  assert.equal(r.body.picture.owned, true);
  assert.equal(r.body.picture.currency, 'HAMMER');
  assert.equal(r.body.user.hammer, user.hammer - pic.cost, 'the price came out of the hammers');
  assert.equal(r.body.user.chips, user.chips, 'and not out of the chips');
  assert.equal(r.body.user.diamond, user.diamond, 'nor out of the diamonds');
  const { rows } = await query(
    `SELECT (SELECT count(*)::int FROM chip_ledger WHERE user_id = $1 AND reason = 'picture_purchase') AS ledger,
            (SELECT count(*)::int FROM hammer_spends WHERE user_id = $1) AS spends`, [user.id]);
  assert.deepEqual(rows[0], { ledger: 0, spends: 0 }, 'no ledger row, and no Force Sideshow spend');

  r = await http('POST', '/api/profile/picture/buy', { token, body: { pictureId: pic.id } });
  assert.equal(r.status, 200);
  assert.equal(r.body.charged, false, 'a second click costs nothing');
  assert.equal(r.body.spent, 0);
  assert.equal(r.body.user.hammer, user.hammer - pic.cost);

  r = await http('POST', '/api/profile/avatar', { token, body: { avatar: pic.id } });
  assert.equal(r.status, 200);
  assert.equal(r.body.user.avatarUrl, pic.url);

  // One hammer short: refused with the price in the words, and nothing moves.
  const skint = await guestLogin('device-hammer-picture-0002', 'NoHammer');
  await query('UPDATE users SET hammer = $2 WHERE id = $1', [skint.user.id, pic.cost - 1]);
  r = await http('POST', '/api/profile/picture/buy', { token: skint.token, body: { pictureId: pic.id } });
  assert.equal(r.status, 409);
  assert.deepEqual(r.body, { error: 'picture_chips', message: `You need ${pic.cost} hammers to unlock this picture.` });
  const after = await me(skint.token);
  assert.equal(after.hammer, pic.cost - 1, 'the refusal took no hammers');
  assert.equal(after.chips, skint.user.chips, 'and no chips');
});

test('a diamond picture is paid in diamonds, never chips, and a new account can afford one', async () => {
  // Five seeded pictures are priced in diamonds (owner, 14 Sep 2026); this test
  // still prices a row of its own at 1, so it does not hang on which seeded
  // row is cheapest or what it costs.
  const { rows: [{ id: gemId }] } = await query(
    `INSERT INTO profile_pictures (name, asset_url, asset_format, currency, type, cost, duration_days, sort_order, created_at, updated_at)
     VALUES ('Parity Gem', '/profiles/parity-gem.json', 'LOTTIE', 'DIAMOND', 'PREMIUM', 1, 100, 10000, 0, 0)
     ON CONFLICT (asset_url) DO UPDATE SET currency = 'DIAMOND', cost = 1, is_active = TRUE
     RETURNING id`);
  const { profiles } = (await http('GET', '/api/profiles')).body;
  const gem = profiles.find((p) => p.id === gemId);
  assert.ok(gem, 'the diamond-priced picture is listed');
  assert.equal(gem.currency, 'DIAMOND');
  assert.equal(gem.type, 'PREMIUM');
  assert.equal(gem.assetFormat, 'LOTTIE');

  const { token, user } = await guestLogin('device-diamond-0001', 'Gem');
  assert.equal(user.diamond, 9, 'every account starts with nine diamonds');
  assert.ok(gem.cost <= user.diamond, 'which covers the seeded diamond picture');

  let r = await http('POST', '/api/profile/picture/buy', { token, body: { pictureId: gem.id } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.charged, true);
  assert.equal(r.body.spent, gem.cost);
  assert.equal(r.body.picture.owned, true);
  assert.equal(r.body.picture.currency, 'DIAMOND');
  assert.equal(r.body.user.diamond, user.diamond - gem.cost, 'the price came out of the diamonds');
  assert.equal(r.body.user.chips, user.chips, 'and not out of the chips');
  const { rows } = await query(
    `SELECT count(*)::int AS n FROM chip_ledger WHERE user_id = $1 AND reason = 'picture_purchase'`, [user.id]);
  assert.equal(rows[0].n, 0, 'diamonds are not chips: no ledger row');

  r = await http('POST', '/api/profile/picture/buy', { token, body: { pictureId: gem.id } });
  assert.equal(r.status, 200);
  assert.equal(r.body.charged, false, 'a second click costs nothing');
  assert.equal(r.body.user.diamond, user.diamond - gem.cost);

  r = await http('POST', '/api/profile/avatar', { token, body: { avatar: gem.id } });
  assert.equal(r.status, 200);
  assert.equal(r.body.user.avatarUrl, gem.url);

  // No diamonds: refused whatever the chip balance, with the diamond wording.
  const skint = await guestLogin('device-diamond-0002', 'NoGem');
  await query('UPDATE users SET diamond = 0 WHERE id = $1', [skint.user.id]);
  r = await http('POST', '/api/profile/picture/buy', { token: skint.token, body: { pictureId: gem.id } });
  assert.equal(r.status, 409);
  assert.deepEqual(r.body, { error: 'picture_chips', message: 'You do not have enough diamonds for that picture.' });
  assert.equal((await me(skint.token)).chips, skint.user.chips, 'the refusal moved no chips');
});

// ---------------------------------------------------------------- rewards

// setHandsPlayed puts a career's worth of hands on the counter, so the
// milestone test does not have to play 25. The counter is
// player_stats.hands_played since Friends V1 (26 Sep 2026): the users column
// of that name is retired and nothing reads it.
const setHandsPlayed = ([n, userId]) => query(
  `INSERT INTO player_stats (user_id, hands_played) VALUES ($2, $1)
     ON CONFLICT (user_id) DO UPDATE SET hands_played = EXCLUDED.hands_played`, [n, userId]);

test('the milestone reward is refused until 25 played hands, then paid exactly once through the ledger', async () => {
  const { token, user } = await guestLogin('device-milestone-0001', 'Miles');

  let r = await http('POST', '/api/rewards/milestone', { token, body: {} });
  assert.equal(r.status, 409);
  assertKeys(r.body, ['error', 'message', 'user']);
  assert.equal(r.body.error, 'reward_not_available');
  assert.equal(r.body.message, 'No milestone reward is waiting yet.');
  assert.equal(r.body.user.id, user.id);

  await setHandsPlayed([24, user.id]);
  const nearly = await me(token);
  assert.equal(nearly.rewards.milestoneAvailable, false);
  assert.equal(nearly.rewards.handsToNextMilestone, 1);
  assert.equal(nearly.rewards.milestoneAt, 0);

  await setHandsPlayed([50, user.id]);
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
  await setHandsPlayed([74, user.id]);
  assert.equal((await me(token)).rewards.milestoneAvailable, false);
  await setHandsPlayed([75, user.id]);
  r = await http('POST', '/api/rewards/milestone', { token });
  assert.equal(r.status, 200);
  assert.equal(r.body.milestone, 75);

  // One row per player per milestone, updated in place (owner, 14 Sep 2026).
  const milestones = await query('SELECT milestone, claimed_up_to, times_claimed FROM user_milestones WHERE user_id = $1', [user.id]);
  assert.deepEqual(milestones.rows, [{ milestone: 'HANDS_PLAYED', claimed_up_to: 75, times_claimed: 2 }]);
});

test('the timed bonus pays 10,000 at once, then recharges for four hours in the database', async () => {
  const { token, user } = await guestLogin('device-bonus-0001', 'Bonus');
  const before = user.chips;
  const hammers = user.hammer;
  assert.equal(user.rewards.bonusAvailable, true);

  const started = Date.now();
  let r = await http('POST', '/api/rewards/bonus', { token, body: {} });
  assert.equal(r.status, 200);
  assertKeys(r.body, ['claimed', 'amount', 'readyAt', 'user']);
  assert.equal(r.body.claimed, true);
  assert.equal(r.body.amount, 10000);
  assert.ok(Math.abs(r.body.readyAt - (started + 4 * 3600 * 1000)) < 2000, `readyAt ${r.body.readyAt} is now + 4h`);
  assert.equal(r.body.user.chips, before + 10000);
  assert.equal(r.body.user.hammer, hammers, 'the four-hour bonus is chips alone');
  assert.equal(r.body.user.rewards.bonusAvailable, false);
  assert.equal(r.body.user.rewards.bonusReadyAt, r.body.readyAt);
  assert.equal(r.body.user.rewards.dailyAvailable, true, 'and leaves the daily bonus waiting');
  const { readyAt } = r.body;

  r = await http('POST', '/api/rewards/bonus', { token });
  assert.equal(r.status, 409);
  assertKeys(r.body, ['error', 'message', 'readyAt', 'user']);
  assert.equal(r.body.error, 'reward_not_ready');
  assert.equal(r.body.message, 'The bonus is still recharging.');
  assert.equal(r.body.readyAt, readyAt);
  assert.equal(r.body.user.chips, before + 10000);

  const { rows } = await query(
    "SELECT next_claim_at, times_claimed FROM user_milestones WHERE user_id = $1 AND milestone = 'TIMED_BONUS'",
    [user.id],
  );
  assert.equal(rows.length, 1);
  assert.equal(rows[0].next_claim_at, readyAt, 'the countdown lives in the database');
  assert.equal(rows[0].times_claimed, 1);

  const ledger = await query("SELECT delta, action_id FROM chip_ledger WHERE user_id = $1 AND reason = 'timed_bonus'", [user.id]);
  assert.equal(ledger.rows.length, 1);
  assert.equal(ledger.rows[0].delta, 10000);
  assert.equal(ledger.rows[0].action_id, null);

  await query("UPDATE user_milestones SET next_claim_at = $1 WHERE user_id = $2 AND milestone = 'TIMED_BONUS'", [Date.now() - 1, user.id]);
  assert.equal((await me(token)).rewards.bonusAvailable, true);
  r = await http('POST', '/api/rewards/bonus', { token });
  assert.equal(r.status, 200);
  assert.equal(r.body.user.chips, before + 20000);
  const again = await query('SELECT times_claimed FROM user_milestones WHERE user_id = $1', [user.id]);
  assert.deepEqual(again.rows, [{ times_claimed: 2 }], 'the same row, updated');
});

test('the daily bonus pays 1 lakh chips and a hammer, then recharges for 24 hours beside the timed bonus', async () => {
  const { token, user } = await guestLogin('device-daily-bonus-0001', 'Daily');
  const before = user.chips;
  const hammers = user.hammer;
  assert.equal(user.rewards.dailyAvailable, true);

  const started = Date.now();
  let r = await http('POST', '/api/rewards/daily', { token, body: {} });
  assert.equal(r.status, 200);
  assertKeys(r.body, ['claimed', 'amount', 'readyAt', 'user']);
  assert.equal(r.body.claimed, true);
  assert.equal(r.body.amount, 100000);
  assert.ok(Math.abs(r.body.readyAt - (started + 24 * 3600 * 1000)) < 2000, `readyAt ${r.body.readyAt} is now + 24h`);
  assert.equal(r.body.user.chips, before + 100000);
  assert.equal(r.body.user.hammer, hammers + 1, 'and one hammer');
  assert.equal(r.body.user.rewards.dailyAvailable, false);
  assert.equal(r.body.user.rewards.dailyReadyAt, r.body.readyAt);
  assert.equal(r.body.user.rewards.bonusAvailable, true, 'the timed bonus keeps its own clock');

  r = await http('POST', '/api/rewards/daily', { token });
  assert.equal(r.status, 409);
  assertKeys(r.body, ['error', 'message', 'readyAt', 'user']);
  assert.equal(r.body.error, 'reward_not_ready');
  assert.equal(r.body.user.hammer, hammers + 1);

  const ledger = await query("SELECT delta, action_id FROM chip_ledger WHERE user_id = $1 AND reason = 'daily_bonus'", [user.id]);
  assert.equal(ledger.rows.length, 1);
  assert.equal(ledger.rows[0].delta, 100000);
  assert.equal(ledger.rows[0].action_id, null);

  r = await http('POST', '/api/rewards/bonus', { token });
  assert.equal(r.status, 200, 'the timed bonus is still there to collect');
  const { rows } = await query('SELECT milestone, times_claimed FROM user_milestones WHERE user_id = $1 ORDER BY milestone', [user.id]);
  assert.deepEqual(rows, [{ milestone: 'DAILY_BONUS', times_claimed: 1 }, { milestone: 'TIMED_BONUS', times_claimed: 1 }]);
  assert.equal(await wallet(user.id), before + 110000);
});

test('reward and profile routes need a session', async () => {
  for (const path of ['/api/rewards/milestone', '/api/rewards/bonus', '/api/rewards/daily', '/api/profile/name', '/api/profile/avatar']) {
    const r = await http('POST', path, { body: {} });
    assert.equal(r.status, 401, path);
    assert.equal(r.body.error, 'missing_token');
  }
});

// ---------------------------------------------------------------- health etc.

test('health reports live counts with the shape the tools read', async () => {
  const body = await health();
  assertKeys(body, ['ok', 'uptime', 'tables', 'players', 'activeHands', 'sockets', 'process', 'db', 'live', 'version', 'tableConfig']);
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
  // The build this process is running: the go-server release tag stamped in
  // by ops/build.sh, or "dev" for a plain `go build` like the one under test.
  // Never empty — ops/prod-version.sh reads it to decide whether a deploy
  // actually landed, and an empty string there would read as "no build".
  assert.equal(typeof body.version, 'string');
  assert.ok(body.version.length > 0, 'version must not be empty');
  // Where the tables this process plays by came from (23 Sep 2026): the source
  // the profile asked for, never the env fallback a db-sourced boot takes when
  // it cannot use the catalogue, and the version GET /api/tables carries.
  assertKeys(body.tableConfig, ['source', 'version', 'fallback']);
  assert.equal(body.tableConfig.source, profile.tableConfigSource);
  assert.equal(body.tableConfig.fallback, false);
  assert.match(body.tableConfig.version, /^[0-9a-f]{64}$/);

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

test('/api/rooms lists public tables with the lobby options, to a signed-in player, without codes or pots', async () => {
  const account = await guestLogin('device-rooms-0001', 'Rooms');
  const client = await openClient(account.token);
  const bootAmount = uniqueStake();
  const joined = await client.emit('room:quickJoin', { bootAmount, category: 'blind' });

  const anonymous = await http('GET', '/api/rooms');
  assert.equal(anonymous.status, 401, 'signed-in players only (24 Sep 2026)');

  const all = await http('GET', '/api/rooms', { token: account.token });
  assert.equal(all.status, 200);
  assertKeys(all.body, ['tables', 'options']);
  const mine = all.body.tables.find((t) => t.roomId === joined.roomId);
  assert.ok(mine, 'the table is listed');
  assertKeys(mine, ['roomId', 'category', 'state', 'players', 'maxPlayers', 'bootAmount']);
  assert.deepEqual(mine, {
    roomId: joined.roomId, category: 'blind', state: 'waiting', players: 1, maxPlayers: 5, bootAmount,
  });
  assertKeys(all.body.options, ['categories', 'stakes', 'tables', 'entryCapBoot', 'entryCapCategory', 'entryCapMaxChips', 'privateBoot', 'privateMaxPot']);
  // The lifted menu of this profile offers any pair, so variation is listed (Go only).
  assert.deepEqual(all.body.options.categories, ['seen', 'blind', 'variation']);

  const seenOnly = await http('GET', '/api/rooms?category=seen', { token: account.token });
  assert.ok(seenOnly.body.tables.every((t) => t.category === 'seen'));
  const upper = await http('GET', '/api/rooms?category=BLIND', { token: account.token });
  assert.ok(upper.body.tables.some((t) => t.roomId === joined.roomId), 'an unknown filter value means no filter');

  await client.close();
});

// ------------------------------------------------------- the table catalogue
//
// GET /api/tables (owner, 23 Sep 2026: "all table related config store in
// database … the UI fetches it, stores it on the phone, and re-fetches it at
// every login"). These tests run in two profiles (tools/parity.mjs): `main`,
// whose server composes its tables from the env keys with the menu lifted, and
// `menu`, which runs only the tests named "GET /api/tables" against a server
// playing the seeded catalogue from PostgreSQL. Everything but the figures is
// asserted identically in both.

/** The body's keys: session:ready.config's table figures, then the catalogue's own. */
const TABLE_CONFIG_KEYS = [
  'version', 'source', 'maxPlayers', 'minPlayers', 'bootAmount', 'turnTimeoutMs', 'maxBetRounds', 'sideshowTimeoutMs',
  'sideshowMinPlayers', 'categories', 'stakes', 'entryCapBoot', 'entryCapCategory', 'entryCapMaxChips', 'privateBoot',
  'privateMaxPot', 'tables', 'privateTables', 'engines',
];
/** What a catalogue entry carries after the lobby entry's own keys, in this order. */
const TABLE_ENTRY_EXTRA_KEYS = [
  'key', 'engine', 'isPrivate', 'sortOrder', 'maxRaiseSteps', 'maxBetRounds', 'potLimitMultiplier', 'turnTimeoutMs',
  'maxMissedTurns', 'sideshowTimeoutMs', 'sideshowMinPlayers', 'nextHandDelayMs', 'unfundedGraceMs', 'missileRevealExtraMs',
  'variationSelectTimeoutMs', 'fiveCardPickTimeoutMs',
];
const POKER_CATEGORIES = ['three_card_poker', 'five_card_draw', 'texas_holdem', 'omaha'];
const CATEGORY_ORDER = ['seen', 'blind', 'variation', ...POKER_CATEGORIES];
/**
 * The taxonomy (table_engines and table_categories): the categories are flat
 * and each belongs to exactly one engine — seen, blind and variation to Teen
 * Patti, the four poker categories to Poker. The names are admin labels (a
 * client names what it knows in its own language); a db-sourced server reads
 * them from the seed, an env-sourced one has the same defaults.
 */
const ENGINES = [
  {
    code: 'teen_patti',
    name: 'Teen Patti',
    sortOrder: 10,
    categories: [
      { code: 'seen', name: 'Seen', sortOrder: 10 },
      { code: 'blind', name: 'Blind', sortOrder: 20 },
      { code: 'variation', name: 'Variation', sortOrder: 30 },
    ],
  },
  {
    code: 'poker',
    name: 'Poker',
    sortOrder: 20,
    categories: [
      { code: 'three_card_poker', name: '3-Card Poker', sortOrder: 40 },
      { code: 'five_card_draw', name: '5-Card Draw', sortOrder: 50 },
      { code: 'texas_holdem', name: "Texas Hold'em", sortOrder: 60 },
      { code: 'omaha', name: 'Omaha', sortOrder: 70 },
    ],
  },
];
/** The public tables V1.0.1__seed.sql writes into a fresh schema, in menu order. */
const SEEDED_TABLE_KEYS = [
  'seen:200', 'blind:200', 'blind:5000', 'blind:50000', 'blind:1000000', 'variation:50000', 'variation:1000000',
  'seen:50000', 'three_card_poker:50000', 'five_card_draw:50000', 'texas_holdem:50000', 'omaha:50000',
];

const engineOf = (category) => (POKER_CATEGORIES.includes(category) ? 'poker' : 'teen_patti');

test('GET /api/tables serves the catalogue session:ready names: the same menu entry for entry, one version, every table under its engine', async () => {
  const account = await guestLogin('device-tables-0001', 'Catalogue');
  const client = await openClient(account.token);
  const ready = await client.wait('session:ready');
  // Public: a client fetches it before it has signed in.
  const r = await http('GET', '/api/tables');
  assert.equal(r.status, 200);
  assert.match(r.headers.get('content-type') ?? '', /^application\/json/);
  const body = r.body;
  assert.deepEqual(Object.keys(body), TABLE_CONFIG_KEYS, 'the body keys, in order');
  assert.match(body.version, /^[0-9a-f]{64}$/);
  assert.equal(body.version, ready.config.tableConfigVersion, 'session:ready names the version this body carries');
  assert.equal(body.source, profile.tableConfigSource);

  // Every figure the two share is the same figure. They share exactly the
  // table figures: the session-scoped keys (welcomeChips, minClientBuild) are
  // never in the catalogue a phone keeps across sessions and players.
  const shared = CONFIG_KEYS.filter((key) => TABLE_CONFIG_KEYS.includes(key));
  assert.deepEqual(
    CONFIG_KEYS.filter((key) => !shared.includes(key)).sort(),
    ['minClientBuild', 'tableConfigVersion', 'welcomeChips'],
  );
  for (const key of shared.filter((k) => k !== 'tables')) {
    assert.deepEqual(body[key], ready.config[key], key);
  }
  // tables is session:ready.config.tables entry for entry — same order, same
  // keys first, same values — with the figures a table plays by after them.
  assert.equal(body.tables.length, ready.config.tables.length, 'one catalogue entry per menu entry');
  for (const [i, menuEntry] of ready.config.tables.entries()) {
    const entry = body.tables[i];
    const menuKeys = Object.keys(menuEntry);
    assert.deepEqual(Object.keys(entry), [...menuKeys, ...TABLE_ENTRY_EXTRA_KEYS], `keys of table ${i}`);
    assert.deepEqual(Object.fromEntries(menuKeys.map((k) => [k, entry[k]])), menuEntry, `table ${i} is the menu entry`);
  }

  // The taxonomy, and every table filed under the engine that plays it.
  assert.deepEqual(body.engines, ENGINES);
  const filed = new Map(body.engines.flatMap((e) => e.categories.map((c) => [c.code, e.code])));
  for (const entry of [...body.tables, ...body.privateTables]) {
    assert.equal(entry.engine, engineOf(entry.category), `${entry.key} engine`);
    assert.equal(filed.get(entry.category), entry.engine, `${entry.key} is under its category's engine`);
    // A poker entry names its family as the lobby card always has.
    if (entry.engine === 'poker') assert.equal(entry.game, 'poker', `${entry.key} game`);
    else assert.equal('game' in entry, false, `${entry.key} names no family`);
  }
  for (const entry of body.tables) {
    assert.equal(entry.key, `${entry.category}:${entry.bootAmount}`);
    assert.equal(entry.isPrivate, false);
  }
  // One private template per category a room:create can open, in category
  // order, with no stack band (a private table is open to whoever has the code).
  assert.ok(body.privateTables.length > 0, 'a private seen template at least');
  assert.equal(body.privateTables[0].category, 'seen');
  const privateCategories = body.privateTables.map((entry) => entry.category);
  assert.deepEqual(privateCategories, CATEGORY_ORDER.filter((c) => privateCategories.includes(c)), 'category order');
  for (const entry of body.privateTables) {
    assert.deepEqual(Object.keys(entry).slice(-TABLE_ENTRY_EXTRA_KEYS.length), TABLE_ENTRY_EXTRA_KEYS, `${entry.key} keys`);
    assert.equal(entry.key, `private:${entry.category}`);
    assert.equal(entry.isPrivate, true);
    assert.equal(entry.minChips, 0, `${entry.key} has no band`);
    assert.equal(entry.maxChips, 0, `${entry.key} has no band`);
    assert.equal(entry.bootAmount, body.privateBoot, `${entry.key} boot`);
  }
  assert.equal(body.privateTables[0].maxPot, body.privateMaxPot, 'the private seen template is what privateMaxPot advertises');

  // /health says the same thing about the same catalogue.
  const h = await health();
  assert.deepEqual(h.tableConfig, { source: body.source, version: body.version, fallback: false });
  await client.close();
});

test('GET /api/tables carries the figures its source gives: the seeded rows from PostgreSQL, else the env keys', async () => {
  const { body } = await http('GET', '/api/tables');
  const privateKeys = body.privateTables.map((entry) => entry.key);
  if (profile.tableConfigSource === 'db') {
    // The `menu` profile: every table env key says otherwise (BOOT_AMOUNT 100,
    // 1.2 s turns, 150 ms between hands, the menu lifted) and none of it shows.
    assert.equal(body.source, 'db');
    assert.equal(body.bootAmount, 200);
    assert.equal(body.turnTimeoutMs, 25000);
    assert.equal(body.sideshowTimeoutMs, 6000);
    assert.deepEqual(body.stakes, [200, 5000, 50000, 1000000]);
    assert.deepEqual(body.categories, CATEGORY_ORDER);
    assert.deepEqual(body.tables.map((entry) => entry.key), SEEDED_TABLE_KEYS);
    assert.deepEqual(body.tables.map((entry) => entry.sortOrder), SEEDED_TABLE_KEYS.map((_, i) => (i + 1) * 10));
    assert.deepEqual(privateKeys, CATEGORY_ORDER.map((c) => `private:${c}`));
    assert.deepEqual(body.privateTables.map((entry) => entry.sortOrder), CATEGORY_ORDER.map((_, i) => 1000 + (i + 1) * 10));
    for (const entry of [...body.tables, ...body.privateTables]) {
      assert.equal(entry.turnTimeoutMs, 25000, `${entry.key} turn`);
      assert.equal(entry.nextHandDelayMs, 4000, `${entry.key} next hand`);
      assert.equal(entry.maxMissedTurns, 3, `${entry.key} missed turns`);
      if (entry.engine === 'teen_patti') assert.equal(entry.sideshowTimeoutMs, 6000, `${entry.key} sideshow`);
      if (entry.category === 'variation') {
        assert.equal(entry.variationSelectTimeoutMs, 10000, `${entry.key} window`);
        assert.equal(entry.fiveCardPickTimeoutMs, 8000, `${entry.key} pick`);
      } else {
        assert.equal(entry.variationSelectTimeoutMs, 0, `${entry.key} has no window`);
        assert.equal(entry.fiveCardPickTimeoutMs, 0, `${entry.key} has no pick`);
      }
    }
    // The ladders the seed writes: the seen ladder of two rungs over seven
    // rounds, blind without limits, the private seen table capped at 5 Lakh.
    const byKey = Object.fromEntries([...body.tables, ...body.privateTables].map((entry) => [entry.key, entry]));
    assert.deepEqual(
      ['maxRaiseSteps', 'maxBetRounds', 'potLimitMultiplier', 'maxPot'].map((k) => byKey['seen:200'][k]),
      [2, 7, 1024, 2000000],
    );
    assert.deepEqual(
      ['maxRaiseSteps', 'maxBetRounds', 'potLimitMultiplier', 'maxPot'].map((k) => byKey['blind:200'][k]),
      [0, 0, 0, 0],
    );
    assert.equal(byKey['private:seen'].maxPot, 500000);
    assert.equal(byKey['texas_holdem:50000'].minBuyIn, 500000);
    assert.equal(byKey['five_card_draw:50000'].maxDiscards, 3);
  } else {
    // An env-sourced server with the menu lifted (LOBBY_TABLES=''): no public
    // table is listed because any pair may be opened, and every private
    // template — variation included, a lifted menu offering it — plays by the
    // profile's short clocks.
    assert.equal(body.source, 'env');
    assert.deepEqual(body.tables, []);
    assert.deepEqual(body.stakes, []);
    assert.equal(body.bootAmount, profile.bootAmount);
    assert.equal(body.turnTimeoutMs, profile.turnTimeoutMs);
    assert.equal(body.sideshowTimeoutMs, profile.sideshowTimeoutMs);
    assert.deepEqual(privateKeys, CATEGORY_ORDER.map((c) => `private:${c}`));
    for (const entry of body.privateTables) {
      assert.equal(entry.turnTimeoutMs, profile.turnTimeoutMs, `${entry.key} turn`);
      assert.equal(entry.nextHandDelayMs, profile.nextHandDelayMs, `${entry.key} next hand`);
      if (entry.engine === 'teen_patti') assert.equal(entry.sideshowTimeoutMs, profile.sideshowTimeoutMs, `${entry.key} sideshow`);
      if (entry.category === 'variation') {
        assert.equal(entry.variationSelectTimeoutMs, profile.variationSelectTimeoutMs, `${entry.key} window`);
      }
    }
  }
});

test('GET /api/tables is revalidated by its version: If-None-Match naming it answers 304 with no body', async () => {
  const first = await http('GET', '/api/tables', { raw: true });
  assert.equal(first.status, 200);
  const { version } = JSON.parse(first.text);
  assert.equal(first.headers.get('etag'), `"${version}"`);
  assert.equal(first.headers.get('cache-control'), 'no-cache', 'kept, but asked about again every time');

  for (const tag of [`"${version}"`, `W/"${version}"`, `"stale", "${version}"`, '*']) {
    const again = await http('GET', '/api/tables', { raw: true, headers: { 'if-none-match': tag } });
    assert.equal(again.status, 304, `If-None-Match: ${tag}`);
    assert.equal(again.text, '', 'a 304 has no body');
    assert.equal(again.headers.get('etag'), `"${version}"`);
  }
  // A phone holding another version is answered in full.
  const stale = await http('GET', '/api/tables', { raw: true, headers: { 'if-none-match': '"0000"' } });
  assert.equal(stale.status, 200);
  assert.equal(stale.text, first.text, 'the same body, byte for byte');
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

// ------------------------------------------------------------- table pictures

test('a table picture is bought in the lobby, laid, shown by the table to every viewer, refused at a table when chip-priced, and cleared', async () => {
  // GET /api/table-pictures, POST /api/table-pictures/{use,buy} (owner,
  // 15 Sep 2026; merged 23 Sep 2026; CLAUDE.md §7.2): the profile-picture
  // trio for the cloth a player lays on their table.
  const listed = await http('GET', '/api/table-pictures');
  assert.equal(listed.status, 200);
  assertKeys(listed.body, ['tablePictures'], 'the catalogue body');
  const rows = listed.body.tablePictures;
  assert.ok(rows.length >= 1, 'the seed offers a table picture');
  for (const p of rows) {
    assertKeys(p, ['id', 'name', 'dayUrl', 'nightUrl', 'assetFormat', 'currency', 'type', 'cost', 'durationDays', 'durationHours', 'sortOrder', 'owned', 'expiresAt'], 'a catalogue row');
    assert.equal(p.owned, p.type === 'FREE', 'without a token only a free picture reads as owned');
    assert.equal(p.expiresAt, 0);
  }
  const coins = rows.filter((p) => p.type === 'PREMIUM' && p.currency === 'COIN').sort((a, b) => a.cost - b.cost);
  const [coin, dearer] = coins;
  assert.ok(coin, 'the seed offers a chip-priced table picture');

  const account = await guestLogin('device-table-picture-01', 'Cloth');
  const token = account.token;
  assert.equal(account.user.tablePicture, null, 'a new account has laid nothing');
  assert.ok(account.user.chips >= coin.cost, 'the welcome covers the cheapest cloth');

  let r = await http('POST', '/api/table-pictures/use', { token, body: { pictureId: coin.id } });
  assert.equal(r.status, 403);
  assert.equal(r.body.error, 'picture_locked');
  r = await http('POST', '/api/table-pictures/use', { token, body: { pictureId: 999999 } });
  assert.equal(r.status, 400);
  assert.equal(r.body.error, 'unknown_table_picture');
  r = await http('POST', '/api/table-pictures/use', { body: { pictureId: coin.id } });
  assert.equal(r.status, 401, 'laying needs a session');

  // Buying: one ledger row, deltas only; a replay is not charged twice.
  r = await http('POST', '/api/table-pictures/buy', { token, body: { pictureId: coin.id } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assertKeys(r.body, ['user', 'picture', 'charged', 'spent'], 'the buy answer');
  assert.equal(r.body.charged, true);
  assert.equal(r.body.spent, coin.cost);
  assert.equal(r.body.user.chips, account.user.chips - coin.cost);
  assert.equal(r.body.picture.owned, true);
  assert.ok(r.body.picture.expiresAt > Date.now(), 'a rental runs from now');
  assert.equal(r.body.user.tablePicture, null, 'buying does not lay');
  const again = await http('POST', '/api/table-pictures/buy', { token, body: { pictureId: coin.id } });
  assert.equal(again.status, 200);
  assert.equal(again.body.charged, false, 'an owned picture is not charged twice');
  assert.equal(again.body.spent, 0);
  assert.equal(again.body.user.chips, account.user.chips - coin.cost);
  assert.equal(await wallet(account.user.id), account.user.chips - coin.cost);
  const { rows: ledger } = await query(
    `SELECT action_id, delta, reason FROM chip_ledger WHERE user_id = $1 AND reason = 'table_picture_purchase'`, [account.user.id]);
  assert.deepEqual(ledger, [{ action_id: `table:${account.user.id}:${coin.id}:1`, delta: -coin.cost, reason: 'table_picture_purchase' }]);

  // Laying: the account carries the pair, and /me agrees.
  r = await http('POST', '/api/table-pictures/use', { token, body: { pictureId: coin.id } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assertKeys(r.body, ['user'], 'the use answer');
  assert.deepEqual(r.body.user.tablePicture,
    { id: coin.id, dayUrl: coin.dayUrl, nightUrl: coin.nightUrl, assetFormat: coin.assetFormat, currency: 'COIN', cost: coin.cost });
  assert.equal((await me(token)).tablePicture.id, coin.id);
  const mine = await http('GET', '/api/table-pictures', { token });
  assert.equal(mine.body.tablePictures.find((p) => p.id === coin.id).owned, true, 'with a token the bought picture reads as owned');

  // At a table the snapshot carries the TABLE's pick — the same for the
  // player who laid it and for a second player who laid nothing, tagged with
  // who laid it.
  const client = await openClient(token);
  const joined = await client.emit('room:quickJoin', { bootAmount: uniqueStake() });
  assert.equal(joined.ok, true);
  const shown = (c) => c.state()?.tablePicture;
  for (let i = 0; i < 40 && shown(client)?.id !== coin.id; i++) await pause(50);
  assert.deepEqual(shown(client), { ...r.body.user.tablePicture, userId: account.user.id });
  const viewer = await guestLogin('device-table-picture-02', 'Viewer');
  const other = await openClient(viewer.token);
  const sat = await other.emit('room:joinCode', { code: joined.code });
  assert.equal(sat.ok, true);
  for (let i = 0; i < 40 && shown(other)?.id !== coin.id; i++) await pause(50);
  assert.equal(shown(other)?.userId, account.user.id, 'the whole table shows the laid picture, tagged with who laid it');

  // A chip-priced picture is not sold at a table (§5.1) ...
  if (dearer) {
    r = await http('POST', '/api/table-pictures/buy', { token, body: { pictureId: dearer.id } });
    assert.equal(r.status, 409);
    assert.deepEqual(r.body, { error: 'seated', message: 'You can only buy a chip-priced table picture in the lobby.' });
  }
  // ... but taking one off is allowed there, and every viewer's snapshot follows.
  r = await http('POST', '/api/table-pictures/use', { token, body: { pictureId: null } });
  assert.equal(r.status, 200);
  assert.equal(r.body.user.tablePicture, null);
  for (let i = 0; i < 40 && (shown(client) !== null || shown(other) !== null); i++) await pause(50);
  assert.equal(shown(client), null);
  assert.equal(shown(other), null);
  await client.close();
  await other.close();
});
