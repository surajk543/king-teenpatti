import { randomBytes, randomUUID } from 'node:crypto';

export const uuid = () => randomUUID();

/** Short, human-typable room code (unambiguous alphabet: no 0/O/1/I). */
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

export const roomCode = (length = 6) => {
  const bytes = randomBytes(length);
  let out = '';
  for (let i = 0; i < length; i += 1) out += ALPHABET[bytes[i] % ALPHABET.length];
  return out;
};
