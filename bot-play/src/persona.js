/**
 * What makes one bot different from the next.
 *
 * A table where every seat folds at the same rate and answers in the same
 * second does not read as five people. It reads as one program with five
 * sockets, which is exactly what it is — so the job here is to make that
 * untrue in the ways a player would actually notice: how someone bets, how
 * long they take, whether they talk, how long they stay.
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

/** The label a regular at a card table would give this player. */
function styleOf(tight, aggro) {
  if (aggro > 0.62) return tight > 0.5 ? 'shark' : 'maniac';
  if (aggro < 0.38) return tight > 0.55 ? 'rock' : 'station';
  return 'casual';
}

export function personaFor(index) {
  const tight = hash01(index, 1); // 0 loose … 1 folds a lot
  const aggro = hash01(index, 2); // 0 calls … 1 raises, and high
  const chatty = hash01(index, 3);
  const pace = hash01(index, 4); // 0 snap decisions … 1 deliberate
  const sees = hash01(index, 5); // how eagerly they look at their cards

  return {
    style: styleOf(tight, aggro),
    /** 0 plays almost anything … 1 folds whatever is not clearly good. */
    tightness: tight,
    /** 0 calls … 1 raises often, and far up the ladder (brain.raiseAmount). */
    aggression: aggro,
    /**
     * How long they ride a blind hand. A bot that always sees immediately
     * never plays blind, and a blind table where nobody is blind is not a
     * blind table.
     */
    blindLove: 1 - sees,
    /** Chance of playing a weak hand as a strong one: most rarely, a few often. */
    bluff: 0.01 + hash01(index, 7) ** 2 * 0.2,
    /** Chance of asking for a sideshow with a middling hand, when offered. */
    sideshowRate: 0.15 + aggro * 0.45,
    /** Appetite for paying to show when down to two players. */
    showRate: 0.25 + aggro * 0.45,
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
    /** Hands in a sitting before getting up, before per-session jitter: 8…40. */
    stayHands: 8 + Math.round(hash01(index, 8) * 32),
    /** Minutes away between sittings, before jitter: 5…45. */
    restMinutes: 5 + hash01(index, 9) * 40,
    /** Base think time, milliseconds. */
    thinkMin: 700 + pace * 1100,
    thinkSpread: 800 + pace * 1800,
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
 * A big pot slows everyone down a little, and so does a big decision — a raise
 * or a show — because a real player thinks harder about a move that costs
 * more. The turn clock is 25 seconds, so even a distracted pause stays well
 * inside it: a bot that times out is not "human", it is a bot that misses
 * turns and gets kicked for it.
 */
export function thinkTime(persona, { potRatio = 0, heavy = false, quick = false, light = false } = {}) {
  // Looking at your own cards is a glance, not a decision.
  if (quick) return Math.round((600 + Math.random() * 1200) * (persona.thinkMin / 1250));
  const base = persona.thinkMin + Math.random() * persona.thinkSpread;
  // Another blind chaal is routine; a raise or a show is not.
  const weight = (1 + Math.min(potRatio, 3) * 0.15) * (heavy ? 1.3 : 1) * (light ? 0.55 : 1);
  if (Math.random() < persona.distractedRate) {
    return Math.min(base * weight + 4000 + Math.random() * 7000, 20000);
  }
  return Math.min(base * weight, 20000);
}

function gaussian() {
  let u = 0;
  while (u === 0) u = Math.random();
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * Math.random());
}

/**
 * Hands this bot will play in this sitting. The persona sets the habit (a
 * regular stays long, a dropper-in leaves early), `mean` the fleet-wide scale
 * (--session-hands), and each sitting varies around it.
 */
export function sessionHands(persona, { mean = 20 } = {}) {
  const habit = persona.stayHands * (mean / 24); // stayHands averages 24
  return Math.max(3, Math.round(habit * Math.exp(gaussian() * 0.35)));
}

/** How long this bot stays away after getting up, in ms (--rest-minutes scales it). */
export function restMs(persona, { meanMinutes = 25 } = {}) {
  const minutes = persona.restMinutes * (meanMinutes / 25) * (0.5 + Math.random() * 1.3);
  return Math.round(Math.max(0.25, minutes) * 60_000);
}
