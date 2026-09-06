/**
 * Table categories.
 *
 * These control **chip visibility at the table**, not how betting works:
 *   SEEN  — everyone can see how many chips every player has.
 *   BLIND — you can see your own chips; other players' stacks are hidden.
 *
 * The hiding is done when the table state is serialized for each viewer, so a
 * modified client cannot read a stack it was not sent.
 */
export const TABLE_CATEGORY = {
  BLIND: 'blind',
  SEEN: 'seen',
};

/** Table lifecycle. */
export const TABLE_STATE = {
  WAITING: 'waiting', // fewer than the minimum number of funded players
  STARTING: 'starting', // countdown before the next deal
  BETTING: 'betting', // a hand is live, someone is on turn
  SHOWDOWN: 'showdown', // cards revealed, winner being resolved
};

/** Per-seat status inside the current hand. */
export const SEAT_STATE = {
  EMPTY: 'empty',
  WAITING: 'waiting', // seated, but sitting out this hand (joined late or short on chips)
  ACTIVE: 'active', // in the hand and still betting
  PACKED: 'packed', // folded
  LOST: 'lost', // reached showdown and lost
  WON: 'won',
};

/** Actions a client may send on its turn. */
export const ACTION = {
  SEE: 'see', // reveal own cards (free, does not end the turn)
  CHAAL: 'chaal', // bet the current amount
  RAISE: 'raise', // bet double the current amount
  PACK: 'pack', // fold
  SHOW: 'show', // pay to compare hands, only with two players left
};

/** Why a hand ended — surfaced to clients and stored on the hand record. */
export const WIN_REASON = {
  LAST_STANDING: 'last_standing', // everyone else packed
  SHOW: 'show', // a player paid for a show
  FORCED_SHOWDOWN: 'forced_showdown', // the round cap was reached
};

export default { TABLE_CATEGORY, TABLE_STATE, SEAT_STATE, ACTION, WIN_REASON };
