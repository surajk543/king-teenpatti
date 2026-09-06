import jwt from 'jsonwebtoken';
import config from '../config/index.js';
import { AuthError } from './providers.js';

/** Issues the session token the client presents on REST calls and the socket handshake. */
export function issueToken(user) {
  return jwt.sign(
    { sub: user.id, provider: user.provider, name: user.displayName },
    config.jwt.secret,
    { expiresIn: config.jwt.expiresIn },
  );
}

export function verifyToken(token) {
  if (!token) throw new AuthError('missing_token', 'A session token is required');
  try {
    return jwt.verify(token, config.jwt.secret);
  } catch (error) {
    throw new AuthError('invalid_session', `Session token rejected: ${error.message}`);
  }
}

/** Reads a bearer token from an Express request. */
export function tokenFromRequest(req) {
  const header = req.headers.authorization ?? '';
  if (header.toLowerCase().startsWith('bearer ')) return header.slice(7).trim();
  return null;
}

export default { issueToken, verifyToken, tokenFromRequest };
