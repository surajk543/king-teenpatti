/**
 * Practice bots.
 *
 * Fills a table so you can play a real hand on your own — a hand needs two
 * players, and a lobby is empty on a fresh server. Bots use exactly the same
 * public protocol a real client does: they act only on `game:yourTurn`, using
 * the options the server sends them.
 *
 *   node tools/bot.js --count 2 --boot 200
 *   node tools/bot.js --count 3 --boot 5000 --category blind --offset 4
 *   node tools/bot.js --count 4 --boot 200 --url http://localhost:3000
 *   node tools/bot.js --count 8 --boot 200 --category blind --churn 45
 *   node tools/bot.js --count 3 --boot 200 --category variation --offset 8
 *   node tools/bot.js --count 3 --boot 200 --category variation --variation AK47
 *   node tools/bot.js --count 3 --boot 200 --category variation --variation none
 *
 *   node tools/bot.js --count 3 --boot 200 --category texas_holdem --offset 8
 *   node tools/bot.js --count 2 --boot 200 --category three_card_poker
 *
 * Flags: --count N  --boot N  --category seen|blind|variation|three_card_poker|five_card_draw|texas_holdem|omaha
 *        --url URL  --offset N  --churn SECONDS
 *        --variation MUFLIS|AK47|JOKER|HUKAM|LOWEST_JOKER|HIGHEST_JOKER|FIVE_CARD|random|none
 *          what a bot picks when IT opens a hand at a variation table
 *          (default random; none never answers, so the server's timeout and
 *          its MUFLIS default can be watched). Ignored at seen and blind tables.
 */
import { io } from 'socket.io-client';

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, token, index, all) => {
    if (token.startsWith('--')) pairs.push([token.slice(2), all[index + 1]]);
    return pairs;
  }, []),
);

const COUNT = Number.parseInt(args.count ?? '2', 10);
const BOOT = Number.parseInt(args.boot ?? '200', 10);
/**
 * "seen" shows every stack at the table; "blind" hides all but your own;
 * "variation" bets as a seen table does, but every hand opens with one player
 * choosing the variation it is decided by. Anything else is a seen table,
 * which is also what the server makes of a category it does not know.
 */
const POKER = ['three_card_poker', 'five_card_draw', 'texas_holdem', 'omaha'];
const CATEGORY = ['blind', 'variation', ...POKER].includes(args.category) ? args.category : 'seen';
/** A poker room's turns arrive as poker:yourTurn and are answered with poker:action. */
const IS_POKER = POKER.includes(CATEGORY);

/**
 * The seven canonical wire values, FIVE_CARD last as on the server's menu. The
 * server matches them exactly — no case folding. Under FIVE_CARD the server
 * tops every hand up to five cards and plays the best three itself; a bot never
 * reads its cards to decide a move, so choosing it is all a bot has to know.
 */
const VARIATIONS = ['MUFLIS', 'AK47', 'JOKER', 'HUKAM', 'LOWEST_JOKER', 'HIGHEST_JOKER', 'FIVE_CARD'];
/**
 * What a bot answers when it is the chooser at a variation table: one of the
 * seven, "random" (a fresh pick every hand from the options the server sent, the default), or "none" — never
 * answer, so the server's window runs out and its MUFLIS default can be
 * watched. A misspelt value stops the run here rather than quietly becoming
 * ten-second timeouts at the table.
 */
const VARIATION = args.variation ?? 'random';
if (![...VARIATIONS, 'random', 'none'].includes(VARIATION)) {
  console.error(`--variation must be one of ${[...VARIATIONS, 'random', 'none'].join(', ')} (got ${VARIATION})`);
  process.exit(2);
}
const BASE_URL = args.url ?? 'http://localhost:3000';
/**
 * Shifts which bot identities this run uses. A bot account can only sit at one
 * table, so a second group of bots (a different table or category) needs its
 * own offset or it will collide with the first.
 */
const OFFSET = Number.parseInt(args.offset ?? '0', 10);

/**
 * Roughly how often, in seconds, a bot gets up and finds another table. 0 is
 * off, which is the default.
 *
 * Without this every bot stays put, and the server seats players at the
 * fullest table with room — so exactly one table ever has a free seat, and
 * "switch table" has nowhere to send you. Bots that come and go keep seats
 * opening across several tables, which is what a busy lobby actually looks
 * like.
 */
const CHURN = Number.parseInt(args.churn ?? '0', 10);

// Sixteen identities: enough for four bots on each of the three lobby tables
// plus a spare group. Slot = (index + offset) % 16, so groups pick disjoint
// offsets (0, 4, 8, 12).
const NAMES = [
  'Ravi', 'Meera', 'Arjun', 'Kavya', 'Vikram', 'Anita', 'Rohit', 'Neha',
  'Priya', 'Aman', 'Sneha', 'Karan', 'Pooja', 'Rahul', 'Isha', 'Dev',
];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function login(name, index) {
  const response = await fetch(`${BASE_URL}/api/auth/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      provider: 'guest',
      // Stable per-bot device id, so a bot keeps its chips between runs.
      deviceId: `practice-bot-${index}-${name}`,
      displayName: name,
    }),
  });
  if (!response.ok) throw new Error(`login failed: ${response.status}`);
  return response.json();
}

/** Plays a straightforward, slightly loose game — enough to make hands happen. */
function decide(options) {
  // Bots always look. A blind bot cannot be part of a sideshow, and a table
  // of them never exercises one.
  if (options.canSee) return 'see';
  if (options.show && Math.random() < 0.5) return 'show';
  // Ask for a sideshow when the server says it is on offer, often enough that
  // playing against bots actually exercises it.
  if (options.canSideshow && Math.random() < 0.45) return 'sideshow';

  const roll = Math.random();
  if (roll < 0.12) return 'pack';
  if (roll < 0.25 && options.raise) return 'raise';
  if (options.chaal) return 'chaal';
  if (options.raise) return 'raise';
  return 'pack';
}

/**
 * Plays a poker street loosely, from the options the server sent and nothing
 * else — a bot never reads its cards. Checks when it can, calls small bets,
 * folds to big ones now and then, opens or raises the minimum once in a while,
 * plays against the dealer most of the time, and stands pat at the draw or
 * exchanges a card or two.
 */
function decidePoker(options, you) {
  const stack = you?.chips ?? 0;
  if (options.draw) {
    const n = Math.random() < 0.5 ? 0 : 1 + Math.floor(Math.random() * Math.min(2, options.maxDiscards));
    return { action: 'draw', cards: (you?.cards ?? []).slice(0, n) };
  }
  if (options.play) return { action: Math.random() < 0.75 ? 'play' : 'fold' };
  const roll = Math.random();
  if (options.check) {
    if (options.bet && roll < 0.2) return { action: 'bet', amount: options.minBet };
    return { action: 'check' };
  }
  if (options.call) {
    // Fold to a bet that would take more than a third of the stack, some of the time.
    if (options.callAmount > stack / 3 && roll < 0.5) return { action: 'fold' };
    if (options.raise && roll < 0.15) return { action: 'raise', amount: options.minRaise };
    return { action: 'call' };
  }
  return { action: 'fold' };
}

/** Variation windows already reported closed, as "<roomId>:<handNo>", so each is logged once for the whole run. */
const closedWindows = new Set();

const CHATTER = [
  'good luck all',
  'nice hand',
  'wow',
  'all yours',
  'lets go',
  'that was close',
];

async function startBot(index) {
  const slot = (index + OFFSET) % NAMES.length;
  const name = NAMES[slot];
  const { token, user } = await login(name, slot);

  const socket = io(BASE_URL, { auth: { token }, transports: ['websocket'], forceNew: true });

  /**
   * Joins a table, retrying while the server still holds a seat for us.
   *
   * Restarting the bots inside the reconnect grace window is the common case:
   * the old socket's seat has not been released yet, so the join is refused
   * with "already seated". Retrying rides that out instead of leaving a bot
   * permanently benched.
   */
  const joinTable = (attempt = 1) => {
    socket.emit('room:quickJoin', { bootAmount: BOOT, category: CATEGORY }, (ack) => {
      if (ack?.ok) {
        console.log(`${name} joined table ${ack.code} (chips ${user.chips.toLocaleString()})`);
        return;
      }

      const retryable = ack?.code === 'already_in_room' || ack?.code === 'table_full';
      if (retryable && attempt <= 12) {
        if (attempt === 1) console.log(`${name} waiting for a seat (${ack.message})…`);
        setTimeout(() => joinTable(attempt + 1), 5000);
        return;
      }

      console.log(`${name} could not join: ${ack?.message ?? 'unknown error'}`);
    });
  };

  socket.on('connect', () => joinTable());

  // Wander between tables, so seats keep opening up around the lobby.
  if (CHURN > 0) {
    const wander = () => {
      // Spread out, so they do not all stand up at the same moment.
      const wait = (CHURN * 1000) * (0.6 + Math.random() * 0.8);
      setTimeout(() => {
        socket.emit('room:leave', {}, () => {
          // A short pause before sitting down again, which is the window that
          // leaves a seat free for somebody else to take.
          setTimeout(() => joinTable(), 1200 + Math.random() * 2500);
        });
        wander();
      }, wait);
    };
    wander();
  }

  /**
   * The latest snapshot. Only a variation table's carries a `variation` block,
   * so everything that reads it is a no-op at a seen or blind table.
   */
  let table = null;
  /**
   * The hand whose window this bot has already answered — one pick per hand, however many snapshots repeat it.
   * Keyed by table as well: every fresh table starts at hand 1, and a bot under --churn changes tables.
   */
  let answeredHand = null;

  // The variation window is driven from room:state, not from
  // game:variationSelecting: the snapshot is the source of truth, and it is
  // all a bot that reconnects into an open window is ever sent.
  const onSnapshot = (state) => {
    table = state;
    const variation = state?.variation;
    if (!variation) return;

    if (!variation.selecting) {
      // Every bot at the table is sent the same block, and with --churn they
      // may be at different tables, so the line is keyed by table and hand
      // rather than spoken by bot 0 alone.
      const key = `${state.roomId}:${state.handNo}`;
      if (variation.selected && !closedWindows.has(key)) {
        closedWindows.add(key);
        const turnUp = variation.turnUp ? ` (turned up ${variation.turnUp})` : '';
        console.log(`  variation ${variation.selected} chosen by ${variation.selectedBy}${turnUp} — ${variation.displayName} opens`);
      }
      return;
    }

    const handKey = `${state.roomId}:${state.handNo}`;
    if (variation.userId !== user.id || answeredHand === handKey) return;
    answeredHand = handKey;
    if (VARIATION === 'none') {
      console.log(`${name} is the chooser and is letting the window run out (--variation none)`);
      return;
    }
    const options = variation.options?.length ? variation.options : VARIATIONS;
    const pick = VARIATION === 'random' ? options[Math.floor(Math.random() * options.length)] : VARIATION;
    // A person reads seven names before tapping one: one to three seconds.
    setTimeout(() => {
      socket.emit('game:selectVariation', { variation: pick }, (ack) => {
        if (ack?.ok) console.log(`${name} picked ${ack.variation}`);
        else console.log(`${name} could not pick ${pick}: ${ack?.message ?? 'no answer'}`);
      });
    }, 1000 + Math.random() * 2000);
  };
  socket.on('room:state', onSnapshot);
  socket.on('room:joined', onSnapshot);

  socket.on('game:yourTurn', ({ options }) => {
    // Human-ish think time, so the table does not resolve instantly.
    setTimeout(() => {
      // Nobody is on turn while a variation is being chosen, so this cannot
      // fire then — but a move sent into the window would only collect a
      // variation_pending refusal, so it is never sent.
      if (table?.variation?.selecting) return;
      socket.emit('game:action', { action: decide(options) });
    }, 700 + Math.random() * 1600);
  });

  // A poker room's turn: the same think time, the poker vocabulary.
  socket.on('poker:yourTurn', ({ options }) => {
    setTimeout(() => {
      const move = decidePoker(options, table?.you);
      socket.emit('poker:action', move, (ack) => {
        if (!ack?.ok) console.log(`${name} poker move ${move.action} refused: ${ack?.message ?? 'no answer'}`);
      });
    }, 700 + Math.random() * 1600);
  });

  socket.on('poker:handEnded', ({ pots, reason }) => {
    if (index !== 0) return;
    const winners = (pots ?? []).flatMap((p) => p.winners ?? []).map((w) => `${w.handName ?? 'hand'} ${w.amount.toLocaleString()}`);
    console.log(`  poker hand ended (${reason}): ${winners.join(', ') || 'nobody paid'}`);
  });

  // Somebody asked this bot for a sideshow. Mostly accept, so the compare-and-
  // pack path gets played out; occasionally refuse, and now and then answer
  // not at all so the six-second expiry is exercised too.
  socket.on('game:sideshowRequested', ({ toUserId }) => {
    if (toUserId !== user.id) return;

    const roll = Math.random();
    if (roll > 0.9) return; // let it lapse
    setTimeout(
      () => socket.emit('game:sideshowRespond', { accept: roll < 0.75 }),
      600 + Math.random() * 1500,
    );
  });

  socket.on('game:handEnded', ({ winnerName, pot }) => {
    if (Math.random() < 0.25) {
      setTimeout(
        () => socket.emit('chat:message', { text: CHATTER[Math.floor(Math.random() * CHATTER.length)] }),
        800 + Math.random() * 1200,
      );
    }
    if (index === 0) console.log(`  hand won by ${winnerName ?? '—'} for ${pot.toLocaleString()}`);
  });

  socket.on('disconnect', () => console.log(`${name} disconnected`));
  return socket;
}

const health = await fetch(`${BASE_URL}/health`).then((r) => r.json()).catch(() => null);
if (!health?.ok) {
  console.error(`No server at ${BASE_URL}. Start it with: npm start`);
  process.exit(1);
}

console.log(
  `Starting ${COUNT} practice bot(s) — ${CATEGORY} table, boot ${BOOT} — on ${BASE_URL}` +
    (CHURN > 0 ? `, moving tables about every ${CHURN}s` : '') +
    '\n',
);

const sockets = [];
for (let i = 0; i < COUNT; i += 1) {
  sockets.push(await startBot(i));
  await sleep(400);
}

console.log(`\nBots are seated. Join the ${CATEGORY} table at boot ${BOOT} to play against them.`);
console.log('Press Ctrl+C to stop.\n');

const shutdown = () => {
  for (const socket of sockets) socket.close();
  process.exit(0);
};

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
