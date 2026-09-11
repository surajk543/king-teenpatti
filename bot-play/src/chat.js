/**
 * What the bots say.
 *
 * Chat is the fastest way to give the fleet away, in both directions: silence
 * at every table is odd, and a canned line after every hand is worse. So lines
 * are grouped by what just happened, drawn without immediate repetition, sent
 * by only a minority of bots on any given moment, and rationed per table.
 *
 * The register is what people actually type in an Indian card room — mixed
 * Hinglish, lowercase, short. Full sentences with correct punctuation would
 * stand out more than saying nothing.
 *
 * The server allows 5 messages per 5 seconds per socket and caps a line at 140
 * characters (CHAT_RATE_LIMIT, CHAT_MAX_LENGTH). Nothing here comes close: each
 * bot keeps its own cooldown, and every table has a budget on top (below).
 */
const LINES = {
  greeting: [
    'hi all', 'hello', 'good luck', 'gl all', 'namaste', 'hi', 'aa gaya main',
    'lets play', 'all the best', 'hey',
  ],
  welcome: [
    'welcome {name}', 'hi {name}', 'aao {name}', 'hello {name}', '{name} aa gaye',
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
  niceHand: [
    'nice hand {name}', 'wah {name}', 'kya haath tha', 'gg {name}', 'itna acha haath',
  ],
  bigRaise: [
    'itna bada chaal', 'bluff hai kya', 'dekhte hai', 'whoa', 'confident ho', 'hmm', 'bada khel',
  ],
  blind: [
    'blind hi chalega', 'bina dekhe', 'blind mein maza hai', 'no peeking', 'blind chal',
  ],
  sideshowWon: [
    'sideshow mera', 'hehe', 'pakad liya', 'got you',
  ],
  sideshowLost: [
    'sideshow gaya', 'chalo koi nahi', 'fair', 'theek hai',
  ],
  packed: [
    'is baar nahi', 'pack', 'chhod diya', 'not my hand',
  ],
  lowChips: [
    'chips khatam', 'paisa khatam ho gaya', 'almost broke', 'bas itna hi',
  ],
  leaving: [
    'chalo bye', 'gn all', 'phir milte hai', 'thoda break', 'bye bye', 'chalta hu', 'kal milte hai',
  ],
  replyHi: [
    'hi', 'hello', 'hey', 'namaste', 'hlo', 'haan hello',
  ],
  replyName: [
    'haan bolo', 'kya hua', 'haan ji', 'yes?', 'bolo',
  ],
  waiting: [
    'koi aao', 'need players', 'anyone', 'start karo', 'jaldi',
  ],
  banter: [
    'bluff tha kya', 'dikhao', 'strong hand', 'sochke khelo', 'itna time',
    'bas bas', 'ha ha', 'lucky', 'again same', 'kaise kar lete ho',
  ],
};
export const MOODS = Object.keys(LINES);

/** Remembers the last line each bot used, so nobody repeats themselves twice. */
const lastSaid = new Map();

/** A line for `mood` with `{name}` filled in, or null (never the same line twice running). */
export function pickLine(botId, mood, vars = {}) {
  const pool = LINES[mood] ?? LINES.banter;
  if (pool.length === 0) return null;
  const previous = lastSaid.get(botId);
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const template = pool[Math.floor(Math.random() * pool.length)];
    if (template === previous) continue;
    if (template.includes('{name}') && !vars.name) continue;
    lastSaid.set(botId, template);
    return template.replaceAll('{name}', vars.name ?? '').trim().slice(0, 140);
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

/**
 * The per-table budget: at most one bot line every few seconds and a handful a
 * minute at any one table. Several talkative bots can land at the same table,
 * and with more things to react to they would otherwise turn it into a group
 * chat — which reads as bots faster than silence does.
 */
const tableTalk = new Map(); // roomId → recent send times

export function tableAllowsChat(roomId, now = Date.now(), { gapMs = 6000, perMinute = 6 } = {}) {
  if (!roomId) return false;
  const sent = (tableTalk.get(roomId) ?? []).filter((at) => now - at < 60_000);
  if ((sent.length && now - sent[sent.length - 1] < gapMs) || sent.length >= perMinute) {
    tableTalk.set(roomId, sent);
    return false;
  }
  sent.push(now);
  tableTalk.set(roomId, sent);
  if (tableTalk.size > 500) {
    for (const [room, times] of tableTalk) if (!times.some((at) => now - at < 60_000)) tableTalk.delete(room);
  }
  return true;
}
