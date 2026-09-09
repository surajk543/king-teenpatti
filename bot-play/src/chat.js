/**
 * What the bots say.
 *
 * Chat is the fastest way to give the fleet away, in both directions: silence
 * at every table is odd, and a canned line after every hand is worse. So lines
 * are grouped by what just happened, drawn without immediate repetition, and
 * sent by only a minority of bots on any given hand.
 *
 * The register is what people actually type in an Indian card room — mixed
 * Hinglish, lowercase, short. Full sentences with correct punctuation would
 * stand out more than saying nothing.
 *
 * The server allows 5 messages per 5 seconds per socket and caps a line at 140
 * characters (CHAT_RATE_LIMIT, CHAT_MAX_LENGTH). Nothing here comes close, and
 * the bot adds its own cooldown on top.
 */
const LINES = {
  greeting: [
    'hi all', 'hello', 'good luck', 'gl all', 'namaste', 'hi', 'aa gaya main',
    'lets play', 'all the best', 'hey',
  ],
  wonBig: [
    'thank you thank you', 'finally', 'aaj ka din acha hai', 'yesss',
    'kya baat', 'thats mine', 'ekdum', 'bohot badhiya',
  ],
  wonSmall: [
    'ty', 'thanks', 'chalo', 'ok ok', 'shukriya', 'nice', 'thank u',
  ],
  lostBig: [
    'oh no', 'kya kismat hai', 'gaya', 'wow', 'that hurt', 'unbelievable',
    'arre yaar', 'nice hand', 'well played',
  ],
  lostSmall: [
    'ok', 'gg', 'next', 'chalta hai', 'no problem', 'wp', 'aage dekhte hai',
  ],
  waiting: [
    'koi aao', 'need players', 'anyone', 'start karo', 'jaldi',
  ],
  banter: [
    'bluff tha kya', 'dikhao', 'strong hand', 'sochke khelo', 'itna time',
    'bas bas', 'ha ha', 'lucky', 'again same', 'kaise kar lete ho',
  ],
};

/** Remembers the last line each bot used, so nobody repeats themselves twice. */
const lastSaid = new Map();

export function pickLine(botId, mood) {
  const pool = LINES[mood] ?? LINES.banter;
  if (pool.length === 0) return null;
  const previous = lastSaid.get(botId);
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const line = pool[Math.floor(Math.random() * pool.length)];
    if (line !== previous) {
      lastSaid.set(botId, line);
      return line;
    }
  }
  return null;
}

/**
 * What mood a finished hand puts this bot in.
 *
 * "Big" is measured against the table's boot rather than an absolute figure,
 * so the same excitement reads correctly at a 200 table and a 5,000 one.
 */
export function moodFor({ won, pot, boot }) {
  const big = pot >= boot * 12;
  if (won) return big ? 'wonBig' : 'wonSmall';
  return big ? 'lostBig' : 'lostSmall';
}
