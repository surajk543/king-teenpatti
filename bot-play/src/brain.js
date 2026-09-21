/**
 * How a bot decides a turn.
 *
 * Pure functions of what the server sent — the turn's options and the table
 * view — plus the persona and a little memory of this hand. No sockets, so
 * every rule is tested (test/brain.test.js).
 *
 * The shape of it, as a person plays Teen Patti:
 *
 *  - Blind: a careful player looks at once, a blind-lover rides it for a few
 *    rounds; anyone looks when the price climbs or someone starts raising.
 *    Now and then a bold one raises blind to lean on the table. At a BLIND
 *    table everyone leans the other way: playing blind is the point of the
 *    table, so a bot prefers blind moves and looks late (see `lookChance`).
 *  - Seen: judge the hand against how many are still in and how hard they have
 *    been betting. Strong → bet big, high up the ladder (or slow-play it).
 *    Middling → stay in while the price is right, or settle it cheaply with a
 *    sideshow or a show. Weak → fold, unless this is a bluffer's moment.
 *
 * Every move is one the server offered and every amount is a rung of the
 * ladder it sent. A move the server refuses is counted in
 * game_invalid_moves_total, a metric the real game is watched by.
 */
import { bestThreeOf, evaluate, SEQUENCE, strength, threeCardCombinations } from './handrank.js';

const clamp = (value, lo, hi) => Math.max(lo, Math.min(hi, value));

export function newHandMemory() {
  return { blindTurns: 0, seenTurns: 0, raisesFaced: 0, biggestRaiseFaced: 0, raisedThisHand: 0 };
}

/** Players still in the hand other than `me`. */
export function opponentsInHand(view, me) {
  return (view?.seats ?? []).filter((s) => s && s.userId && s.userId !== me && s.status === 'active').length;
}

/**
 * A raise amount — the "high chaal". The stronger the intent (`power`, 0…1)
 * and the more aggressive the persona, the higher up the ladder, but never
 * past a share of the stack: a person bets big on a big hand, they do not
 * shove a week of winnings on a whim. Null when no raise is affordable.
 */
export function raiseAmount(options, persona, power, rng) {
  const ladder = options.raiseSteps ?? [];
  if (ladder.length < 2) return null;
  const floor = ladder[0] * 2; // the server refuses a "raise" below twice the chaal
  const rungs = ladder.filter((step) => step >= floor && step <= options.chips);
  if (rungs.length === 0) return null;
  const budget = options.chips * clamp(0.03 + 0.3 * persona.aggression * power, 0.02, 0.5);
  const affordable = rungs.filter((step) => step <= budget);
  const choices = affordable.length > 0 ? affordable : [rungs[0]];
  const reach = Math.floor(rng.next() * (1 + persona.aggression * 3 * power));
  return choices[Math.min(choices.length - 1, reach)];
}

/**
 * This turn's move: `{action, amount?, hand?, bluff?, mood?}`. Counts
 * `memory.blindTurns`. `tilt` (0…1) loosens a player who just lost big.
 */
/**
 * The chance of looking at the cards this turn, while still blind.
 *
 * At a seen table blind is a style: a careful player looks at once, and
 * anyone looks as the rounds and the raises mount. At a BLIND table (owner,
 * 13 Sep 2026) blind is the game — a player who sat down there wants to bet
 * blind — so every bot prefers blind moves: a far lower chance of looking,
 * which climbs slowly with each blind bet, and still more for a blind-lover
 * than a careful player. Pressure still counts, only for less: a bet that
 * costs a real share of the stack, or a table raising hard, makes anyone look
 * sooner. The server turns the cards face up itself after `maxBlindMoves`.
 */
export function lookChanceFor({ view, persona, memory, options, chaal, canAfford }) {
  const expensive = canAfford && chaal > options.chips * 0.08;
  if (view?.category === 'blind') {
    const pressure = memory.raisesFaced * 0.06 + (expensive ? 0.2 : 0);
    return clamp(
      0.02 + (1 - persona.blindLove) * 0.1 + (memory.blindTurns - 1) * 0.05 + pressure,
      0.01,
      0.6,
    );
  }
  const pressure = memory.raisesFaced * 0.18 + (expensive ? 0.35 : 0);
  return clamp(0.2 + (1 - persona.blindLove) * 0.5 + (memory.blindTurns - 1) * 0.18 + pressure, 0.05, 0.97);
}

export function decide({ options, view, me, persona, memory, rng, tilt = 0 }) {
  const chaal = options.chaal ?? null;
  const canAfford = chaal != null && chaal <= options.chips;
  const opponents = Math.max(1, opponentsInHand(view, me));
  const tight = clamp(persona.tightness - tilt * 0.3, 0, 1);

  // ---- blind
  if (options.canSee) {
    memory.blindTurns += 1;
    const lookChance = lookChanceFor({ view, persona, memory, options, chaal, canAfford });
    if (!canAfford || rng.chance(lookChance)) return { action: 'see' };
    if (options.show != null && rng.chance(persona.showRate * 0.25)) return { action: 'show' };
    if (rng.chance(persona.aggression * 0.22)) {
      const amount = raiseAmount(options, persona, 0.4, rng);
      if (amount != null) return { action: 'raise', amount, mood: 'blind' };
    }
    if (rng.chance(tight * 0.02)) return { action: 'pack' };
    return { action: 'chaal', amount: chaal, mood: memory.blindTurns >= 3 ? 'blind' : undefined };
  }

  // ---- seen
  const cards = view?.you?.cards ?? [];
  if (cards.length !== 3) return canAfford ? { action: 'chaal', amount: chaal } : { action: 'pack' };

  const hand = evaluate(cards);
  const share = strength(cards);
  // Patience runs out. Blind tables never force a showdown, and a table of
  // middling hands paying chaal round after round is not how people play: the
  // longer a hand drags on, the sooner a middling hand folds, compares or shows.
  memory.seenTurns += 1;
  const patience = memory.seenTurns - 1;
  // Somebody betting hard is probably holding something. Believe it, a bit.
  const doubt = clamp(1 - memory.raisesFaced * 0.12 - (memory.biggestRaiseFaced > options.chips * 0.1 ? 0.15 : 0), 0.5, 1);
  const win = share ** opponents * doubt;
  const potOdds = chaal ? chaal / ((options.pot ?? 0) + chaal) : 1;
  const monster = hand.category >= SEQUENCE || share > 0.97;
  const tag = { hand: hand.name };

  // Heads-up: a show ends it.
  if (options.show != null) {
    const confident = win > 0.55 + tight * 0.15;
    const shortStacked = options.chips < options.show * 3 && win > 0.35;
    const tired = (memory.raisedThisHand >= 3 || patience >= 3) && win > 0.4;
    const curious = win > 0.3 && rng.chance(persona.showRate * 0.3);
    // A monster sometimes keeps betting instead, to build the pot.
    if ((confident || shortStacked || tired || curious) && !(monster && rng.chance(persona.aggression * 0.5))) {
      return { action: 'show', ...tag };
    }
  }

  if (!canAfford) return options.show != null ? { action: 'show', ...tag } : { action: 'pack', ...tag };

  // A middling hand, settled against one neighbour for nothing.
  if (options.canSideshow && share > 0.3 && share < 0.9 && rng.chance(clamp(persona.sideshowRate + 0.1 * patience, 0, 0.95))) {
    return { action: 'sideshow', ...tag };
  }

  // Strong: bet big — or slow-play it and let someone else build the pot.
  if (monster || win > 0.7 - persona.aggression * 0.1) {
    if (!rng.chance(0.2 * (1 - persona.aggression))) {
      const amount = raiseAmount(options, persona, clamp(win + 0.2, 0, 1), rng);
      if (amount != null) return { action: 'raise', amount, ...tag };
    }
    return { action: 'chaal', amount: chaal, ...tag };
  }

  // Middling: stay in while the price is right.
  const callBar = Math.max(potOdds * (1.1 + tight * 0.6), 0.12 + tight * 0.3) + 0.05 * patience;
  if (win > callBar) {
    if (rng.chance(persona.aggression * 0.18)) {
      const amount = raiseAmount(options, persona, 0.35, rng);
      if (amount != null) return { action: 'raise', amount, ...tag };
    }
    return { action: 'chaal', amount: chaal, ...tag };
  }

  // Weak: bluff, float a cheap chaal, or fold.
  const bluffChance = persona.bluff * (opponents === 1 ? 2 : 1) * (memory.raisesFaced > 1 ? 0.4 : 1);
  if (rng.chance(bluffChance)) {
    const amount = raiseAmount(options, persona, 0.6, rng);
    return amount != null
      ? { action: 'raise', amount, bluff: true, ...tag }
      : { action: 'chaal', amount: chaal, bluff: true, ...tag };
  }
  if (chaal <= options.chips * 0.02 && rng.chance((1 - tight) * 0.45)) return { action: 'chaal', amount: chaal, ...tag };
  return { action: 'pack', ...tag };
}

/**
 * Asked for a sideshow: `{answer}` — true accept, false decline, null let it
 * lapse (a player who did not notice; a table where every ask is answered at
 * once is a table of programs). A good hand is glad to compare.
 */
export function answerSideshow({ view, persona, rng }) {
  if (rng.chance(0.07)) return { answer: null };
  const cards = view?.you?.cards ?? [];
  if (cards.length !== 3) return { answer: rng.chance(0.5) };
  const bar = 0.3 + persona.tightness * 0.25;
  return { answer: strength(cards) > bar ? rng.chance(0.85) : rng.chance(0.2) };
}

/* ------------------------------------------------------------------ *
 * Variation tables (§6.4). The player to the dealer's left picks the
 * hand's variation inside a server-timed window; lapsing gives Muflis.
 * ------------------------------------------------------------------ */

/** The seven wire values, in the server's order. FIVE_CARD is last there too. */
export const VARIATIONS = [
  'MUFLIS', 'AK47', 'JOKER', 'HUKAM', 'LOWEST_JOKER', 'HIGHEST_JOKER', 'FIVE_CARD',
];

/**
 * How much this persona fancies a variation, as a weight.
 *
 * Kept deliberately mild — between 1 and about 2.2 — because the point is a
 * table that sees all seven over an evening, not seven bots each welded to a
 * favourite. A strong lean would make the choice predictable from the seat,
 * which is the opposite of what a menu of seven is for.
 */
function variationAppetite(variation, persona) {
  switch (variation) {
    // Muflis turns junk into gold, so it rewards the player who would other-
    // wise have folded it. A loose player is at home; a rock is not.
    case 'MUFLIS': return 1 + (1 - persona.tightness) * 1.2;
    // Wild cards mean bigger hands and bigger pots.
    case 'AK47':
    case 'JOKER':
    case 'HUKAM': return 1 + persona.aggression * 1.2;
    case 'LOWEST_JOKER':
    case 'HIGHEST_JOKER': return 1 + persona.aggression * 0.6;
    // Five cards is simply the one most people enjoy most.
    case 'FIVE_CARD': return 1.4;
    default: return 1;
  }
}

/**
 * Which variation to call, chosen from the menu the SERVER offered for this
 * hand — never from a list of our own.
 *
 * `variation.options` is per hand: FIVE_CARD is absent when the deck could not
 * cover a two-card top-up for everyone, and picking it then is
 * `invalid_variation`. Returns null when there is nothing to choose from,
 * which the caller treats as "say nothing and let the clock decide".
 */
export function chooseVariation({ options, persona, rng }) {
  const menu = (options ?? []).filter((v) => typeof v === 'string' && v.length > 0);
  if (menu.length === 0) return null;
  const weights = menu.map((v) => variationAppetite(v, persona));
  let roll = rng.next() * weights.reduce((sum, w) => sum + w, 0);
  for (let i = 0; i < menu.length; i += 1) {
    roll -= weights[i];
    if (roll <= 0) return menu[i];
  }
  return menu[menu.length - 1];
}

/**
 * Under FIVE_CARD, which three of the five to play.
 *
 * Usually the best three — that is what anyone is trying to do. But not
 * always: a player glancing at five cards on a phone takes the obvious pair
 * and misses the flush, and the server tells them afterwards what they could
 * have played (`you.hand.bestPossible`). A fleet that found the optimum every
 * single time would be the one thing at the table that never errs, which is
 * a tell. The slip is small, and larger for the impatient.
 *
 * Returns the cards in the order HELD, which is what the ack echoes back.
 */
export function choosePlayedCards({ cards, persona, rng }) {
  if (!Array.isArray(cards)) return [];
  if (cards.length <= 3) return [...cards];
  const slip = 0.04 + persona.aggression * 0.06;
  if (rng.chance(slip)) {
    const combos = threeCardCombinations(cards);
    return combos[Math.floor(rng.next() * combos.length)];
  }
  return bestThreeOf(cards).cards;
}
