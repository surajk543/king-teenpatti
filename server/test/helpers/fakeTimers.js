/**
 * Minimal deterministic timer queue so table tests can step through the 25s
 * turn clock and the between-hand countdown without actually waiting.
 *
 * Timer callbacks may be async — the table's are, since a timeout can end a
 * hand and a hand ending is a database transaction — so `advance` awaits each
 * one before firing the next. Call it as `await advance(ms)`.
 */
export function createFakeTimers() {
  let now = 0;
  let nextId = 1;
  const scheduled = new Map();

  const timers = {
    setTimeout: (fn, ms) => {
      const id = nextId;
      nextId += 1;
      scheduled.set(id, { fn, at: now + ms });
      return id;
    },
    clearTimeout: (id) => {
      scheduled.delete(id);
    },
  };

  /** Advances the clock, firing everything due, in order, awaiting each. */
  const advance = async (ms) => {
    const target = now + ms;
    for (;;) {
      const due = [...scheduled.entries()]
        .filter(([, timer]) => timer.at <= target)
        .sort((a, b) => a[1].at - b[1].at);
      if (due.length === 0) break;
      const [id, timer] = due[0];
      scheduled.delete(id);
      now = timer.at;
      await timer.fn();
    }
    now = target;
  };

  return { timers, advance, now: () => now, pending: () => scheduled.size };
}

export default createFakeTimers;
