import { createHash } from 'node:crypto';
import { OAuth2Client } from 'google-auth-library';
import config from '../config/index.js';

export class AuthError extends Error {
  constructor(code, message, status = 401) {
    super(message);
    this.name = 'AuthError';
    this.code = code;
    this.status = status;
  }
}

const googleClient = new OAuth2Client();

/**
 * Verifies a Google Sign-In ID token.
 *
 * The token is checked against the OAuth client ids configured for this game,
 * which is what stops someone replaying a token minted for a different app.
 */
async function verifyGoogle({ idToken }) {
  if (!idToken) throw new AuthError('missing_token', 'idToken is required for Google login');
  if (config.google.clientIds.length === 0) {
    throw new AuthError('provider_unconfigured', 'Google login is not configured on this server', 503);
  }

  let payload;
  try {
    const ticket = await googleClient.verifyIdToken({
      idToken,
      audience: config.google.clientIds,
    });
    payload = ticket.getPayload();
  } catch (error) {
    throw new AuthError('invalid_token', `Google token rejected: ${error.message}`);
  }

  if (!payload?.sub) throw new AuthError('invalid_token', 'Google token had no subject');

  return {
    provider: 'google',
    providerUserId: payload.sub,
    displayName: payload.name || payload.given_name || 'Player',
    email: payload.email ?? null,
    avatarUrl: payload.picture ?? null,
  };
}

/**
 * Verifies a Facebook user access token.
 *
 * `debug_token` confirms the token was issued for *this* app and is still
 * valid; only then do we read the profile. Checking `app_id` is essential —
 * without it any valid Facebook token from any app would be accepted.
 */
async function verifyFacebook({ accessToken }) {
  if (!accessToken) throw new AuthError('missing_token', 'accessToken is required for Facebook login');
  if (!config.facebook.appId || !config.facebook.appSecret) {
    throw new AuthError('provider_unconfigured', 'Facebook login is not configured on this server', 503);
  }

  const appToken = `${config.facebook.appId}|${config.facebook.appSecret}`;
  const debugUrl = `https://graph.facebook.com/debug_token?input_token=${encodeURIComponent(
    accessToken,
  )}&access_token=${encodeURIComponent(appToken)}`;

  const debugResponse = await fetch(debugUrl);
  if (!debugResponse.ok) throw new AuthError('invalid_token', 'Facebook rejected the access token');

  const { data } = await debugResponse.json();
  if (!data?.is_valid) throw new AuthError('invalid_token', 'Facebook access token is not valid');
  if (String(data.app_id) !== String(config.facebook.appId)) {
    throw new AuthError('invalid_token', 'Facebook token was issued for a different app');
  }

  const profileUrl = `https://graph.facebook.com/v20.0/${data.user_id}?fields=id,name,email,picture.type(large)&access_token=${encodeURIComponent(
    accessToken,
  )}`;
  const profileResponse = await fetch(profileUrl);
  if (!profileResponse.ok) throw new AuthError('invalid_token', 'Could not read the Facebook profile');
  const profile = await profileResponse.json();

  return {
    provider: 'facebook',
    providerUserId: String(profile.id),
    displayName: profile.name || 'Player',
    email: profile.email ?? null,
    avatarUrl: profile.picture?.data?.url ?? null,
  };
}

/**
 * Guest login, keyed on the client's device id.
 *
 * The raw device id is hashed before it is stored so the database never holds a
 * device identifier in the clear. The same device therefore always resolves to
 * the same account (requirement 7) without the id itself being recoverable.
 */
function verifyGuest({ deviceId, displayName }) {
  const trimmed = String(deviceId ?? '').trim();
  if (trimmed.length < 8) {
    throw new AuthError('invalid_device_id', 'A deviceId of at least 8 characters is required', 400);
  }

  const hashed = createHash('sha256').update(`teenpatti:${trimmed}`).digest('hex');

  return {
    provider: 'guest',
    providerUserId: hashed,
    displayName: sanitizeName(displayName) || `Guest${hashed.slice(0, 5).toUpperCase()}`,
    email: null,
    avatarUrl: null,
  };
}

const sanitizeName = (name) => {
  const cleaned = String(name ?? '')
    .replace(/[\p{C}]/gu, '')
    .trim()
    .slice(0, 24);
  return cleaned.length >= 2 ? cleaned : '';
};

/**
 * Development-only escape hatch so the automated tests and the bundled browser
 * client can log in without real Google/Facebook credentials. Refused unless
 * AUTH_ALLOW_FAKE_PROVIDERS is on, and forced off entirely in production.
 */
function verifyFake({ provider, providerUserId, displayName }) {
  if (!config.allowFakeProviders) {
    throw new AuthError('provider_unconfigured', `${provider} login is not configured on this server`, 503);
  }
  return {
    provider,
    providerUserId: String(providerUserId ?? displayName ?? 'fake'),
    displayName: sanitizeName(displayName) || 'Player',
    email: null,
    avatarUrl: null,
  };
}

/** Resolves a login request into a verified provider profile. */
export async function verifyLogin({ provider, ...payload }) {
  switch (provider) {
    case 'google':
      return config.allowFakeProviders && !payload.idToken
        ? verifyFake({ provider, ...payload })
        : verifyGoogle(payload);
    case 'facebook':
      return config.allowFakeProviders && !payload.accessToken
        ? verifyFake({ provider, ...payload })
        : verifyFacebook(payload);
    case 'guest':
      return verifyGuest(payload);
    default:
      throw new AuthError('unknown_provider', `Unsupported login provider "${provider}"`, 400);
  }
}

export default { verifyLogin, AuthError };
