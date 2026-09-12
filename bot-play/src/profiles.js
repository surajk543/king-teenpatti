/**
 * The faces the bots wear.
 *
 * The server keeps a catalogue of pictures and serves it from /api/profiles;
 * a player picks one in the lobby. Bots that never pick one all show the same
 * grey initial, and five identical grey circles around a table is the tell
 * that gives the whole fleet away before anyone reads a name.
 *
 * Only the FREE ones are taken. A premium picture has to be bought with chips,
 * and a fleet that spent its way through the catalogue would be two hundred
 * accounts quietly draining the chip economy every restart for a decoration —
 * and would be refused anyway, since a bot with no purchase is not allowed to
 * wear one.
 *
 * Fetched once for the fleet rather than once per bot: two hundred identical
 * requests to learn the same fifteen ids is pure noise in the log.
 */
import { config } from './config.js';

let cached = null;

export async function profileIds() {
  if (cached) return cached;
  try {
    const res = await fetch(`${config.serverUrl}/api/profiles`);
    const body = await res.json();
    cached = (body?.profiles ?? [])
      .filter((p) => p?.type === 'FREE')
      .map((p) => p.id)
      .filter((id) => Number.isInteger(id));
  } catch {
    // The picture is decoration; a bot that cannot fetch the list still plays.
    cached = [];
  }
  return cached;
}

/**
 * Which picture bot `index` wears — derived from the index, so it is the same
 * face every run for the same seat, exactly as its name and persona are.
 *
 * The offset keeps neighbours apart: bots are seated in index order, so
 * picking `index % length` would put the same animal on adjacent seats far too
 * often. A stride coprime with the list length walks it all before repeating.
 */
export function profileFor(index, ids) {
  if (!ids.length) return null;
  return ids[(index * 7) % ids.length];
}
