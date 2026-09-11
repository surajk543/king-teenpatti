/**
 * The small random interface the decision code uses.
 *
 * The fleet runs on Math.random; the tests hand brain.js a seeded stream
 * instead, so a rule like "a strong hand raises more than a weak one" can be
 * checked over thousands of hands and give the same answer every time.
 */

function around(next) {
  return {
    next,
    chance: (p) => next() < p,
    between: (lo, hi) => lo + (hi - lo) * next(),
    pick: (items) => items[Math.floor(next() * items.length)],
    /** Standard normal (Box–Muller). */
    gaussian: () => {
      let u = 0;
      while (u === 0) u = next();
      return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * next());
    },
  };
}

export const mathRandom = around(() => Math.random());

/** mulberry32: a deterministic stream for tests. */
export function seededRandom(seed) {
  let state = seed >>> 0 || 0x9e3779b9;
  return around(() => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  });
}
