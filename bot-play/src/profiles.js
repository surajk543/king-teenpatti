/**
 * The faces the bots wear.
 *
 * The server bundles a set of animal pictures and serves the list from
 * /api/profiles; a player picks one in the lobby. Bots that never pick one all
 * show the same grey initial, and five identical grey circles around a table
 * is the tell that gives the whole fleet away before anyone reads a name.
 *
 * Fetched once for the fleet rather than once per bot: two hundred identical
 * requests to learn the same fifteen filenames is pure noise in the log.
 */
import { config } from './config.js';

let cached = null;

export async function profileIds() {
  if (cached) return cached;
  try {
    const res = await fetch(`${config.serverUrl}/api/profiles`);
    const body = await res.json();
    cached = (body?.profiles ?? []).map((p) => p.id).filter(Boolean);
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
 * often. A stride coprime with 15 walks the whole list before repeating.
 */
export function profileFor(index, ids) {
  if (!ids.length) return null;
  return ids[(index * 7) % ids.length];
}
