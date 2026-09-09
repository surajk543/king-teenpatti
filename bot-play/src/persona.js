/**
 * What makes one bot different from the next.
 *
 * A table where every seat folds at the same rate and answers in the same
 * second does not read as five people. It reads as one program with five
 * sockets, which is exactly what it is — so the job here is to make that
 * untrue in the ways a player would actually notice: how long someone takes,
 * how often they fold, whether they talk.
 *
 * A persona is derived from the bot's index and never changes. The same seat
 * plays the same way tomorrow, which is what makes it a person rather than a
 * dice roll.
 */

/** Deterministic 0..1 from an integer — a persona is stable, not random. */
function hash01(n, salt) {
  let h = (n + 1) * 2654435761 + salt * 40503;
  h = (h ^ (h >>> 15)) >>> 0;
  h = (h * 2246822519) >>> 0;
  h = (h ^ (h >>> 13)) >>> 0;
  return (h >>> 8) / 0x01000000;
}

export function personaFor(index) {
  const tight = hash01(index, 1); // 0 loose … 1 folds a lot
  const aggro = hash01(index, 2); // 0 calls … 1 raises
  const chatty = hash01(index, 3);
  const pace = hash01(index, 4); // 0 snap decisions … 1 deliberate
  const sees = hash01(index, 5); // how eagerly they look at their cards

  return {
    /** Chance of packing a hand that is not obviously worth playing. */
    packRate: 0.06 + tight * 0.22,
    /** Chance of raising rather than just calling, when both are legal. */
    raiseRate: 0.05 + aggro * 0.30,
    /** Chance of asking for a sideshow when the server offers one. */
    sideshowRate: 0.15 + aggro * 0.45,
    /** Chance of paying to show, when down to two players. */
    showRate: 0.25 + aggro * 0.45,
    /**
     * Chance of looking at the cards on any given blind turn. A bot that
     * always sees immediately never plays blind, and a blind table where
     * nobody is blind is not a blind table.
     */
    seeRate: 0.10 + sees * 0.45,
    /**
     * Chance of saying something when a hand ends.
     *
     * Weighted so most bots are quiet and a few carry the table: a room where
     * everyone talks equally reads as scripted, and one where nobody talks
     * reads as empty. The talkative fifth is what makes a table feel occupied.
     */
    chatRate: chatty < 0.55 ? 0.05 + chatty * 0.10 : 0.16 + (chatty - 0.55) * 0.45,
    /**
     * Chance this bot ever changes stake when the fleet offers it the choice.
     * Most never do — a regular has a table.
     */
    hopRate: hash01(index, 6) < 0.28 ? 0.5 : 0,
    /** Base think time, milliseconds. */
    thinkMin: 900 + pace * 1600,
    thinkSpread: 1200 + pace * 3200,
    /**
     * Chance of a much longer pause — someone put their phone down, answered
     * the door, went back to the game. Rare, but it is the thing that most
     * makes a table feel like people rather than a loop.
     */
    distractedRate: 0.03 + pace * 0.05,
  };
}

/**
 * How long this bot takes to act.
 *
 * A big pot slows everyone down a little, because a real player thinks harder
 * about a decision that costs more. The turn clock is 25 seconds, so even a
 * distracted pause stays well inside it — a bot that times out is not
 * "human", it is a bot that misses turns and gets kicked for it.
 */
export function thinkTime(persona, { potRatio = 0 } = {}) {
  const base = persona.thinkMin + Math.random() * persona.thinkSpread;
  const weight = 1 + Math.min(potRatio, 3) * 0.35;
  if (Math.random() < persona.distractedRate) {
    return Math.min(base * weight + 4000 + Math.random() * 7000, 20000);
  }
  return Math.min(base * weight, 20000);
}
