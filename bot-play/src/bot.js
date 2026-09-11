import { randomUUID } from 'node:crypto';

import { io } from 'socket.io-client';

import { answerSideshow, decide, newHandMemory } from './brain.js';
import { moodFor, pickLine, tableAllowsChat } from './chat.js';
import { config } from './config.js';
import { PURE_SEQUENCE } from './handrank.js';
import { identityFor, rotatedIdentity } from './identities.js';
import { personaFor, restMs, sessionHands, thinkTime } from './persona.js';
import { profileFor, profileIds } from './profiles.js';
import { mathRandom } from './random.js';

/** Every bot's user id, so a bot can tell a person's chat from another bot's. */
export const botUserIds = new Set();

/**
 * Refusals that mean a race was lost — the hand or the turn moved on while
 * the bot was thinking — rather than that its idea of what is legal drifted.
 */
const RACED = new Set(['not_your_turn', 'no_hand', 'not_in_hand', 'show_unavailable', 'sideshow_pending']);

const firstName = (name) => String(name ?? '').trim().split(/[\s_]+/)[0] ?? '';
/** While the fleet is still sitting down, bots do not welcome each other: that is a chorus. */
const fleetStartedAt = Date.now();
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * One resident player.
 *
 * It speaks only the public protocol — the same events the Flutter client
 * sends — and acts only on the options the server hands it. It has no
 * privileged view of anyone's cards, because it is given none: the server
 * redacts per viewer, and a bot is just another viewer. What it knows is what
 * a player knows: its own cards once it looks, the table, and what the others
 * just did.
 *
 * Everything here that looks like a flourish is load-bearing for one of two
 * things: not being obviously a bot, or not falling over unattended. The
 * second matters more. This runs for weeks without anyone watching, through
 * server restarts, network blips and its own bad luck at cards.
 */
export class Bot {
  constructor({ index, table, log }) {
    this.index = index;
    this.home = table; // the category this bot belongs to in the fleet's counts
    this.table = table; // { category, boot } — where it sits now (hops change it)
    this.log = log;
    this.persona = personaFor(index);
    this.generation = 0;
    this.identity = identityFor(index);
    this.rng = mathRandom;

    this.socket = null;
    this.token = null;
    this.userId = null;
    this.chips = 0;
    this.stopped = false;
    this.seated = false;
    /**
     * Set when the picture could not be put on at login because the server
     * still held this bot's seat (409 seated — the fleet restarted inside the
     * reconnect grace). The next `room:joined` is then the restored seat, and
     * the bot steps out to the lobby once to wear the picture. See
     * wearAPicture / stepOutForPicture.
     */
    this.owesPicture = false;
    this.lastChatAt = 0;
    this.timers = new Set();
    /**
     * Invalidates a decision that is no longer worth sending.
     *
     * A bot thinks for up to twenty seconds, and in that time the hand can
     * end without it — everyone else packs, someone shows, the clock runs out.
     * Acting then is refused with `no_hand` or `not_in_hand`, and a fleet
     * doing it continually inflates game_invalid_moves_total on a production
     * server, which is a metric the real game is watched by.
     *
     * The server guards its own timers the same way, with hand.turnToken.
     * This is that idea on the client: bump the sequence whenever the turn
     * stops being ours, and a decision from an older sequence is dropped.
     */
    this.turnSeq = 0;

    // ---- the table as this bot sees it
    this.view = null;
    this.roomId = null;
    this.handNo = -1;
    this.memory = newHandMemory();
    /** Rises after a big loss and fades: a stung player plays looser for a while. */
    this.tilt = 0;
    this.knownPlayers = new Set();
    this.shortHandled = false;

    // ---- sittings: people play for a while, get up, and come back later
    this.online = false;
    this.leaving = false;
    this.wrappingUp = false;
    this.restUntil = 0;
    this.handsThisSitting = 0;
    this.plannedHands = 0;
  }

  /** setTimeout that is forgotten on stop, so shutdown is actually immediate. */
  after(ms, fn) {
    const t = setTimeout(() => {
      this.timers.delete(t);
      if (!this.stopped) fn();
    }, ms);
    this.timers.add(t);
    return t;
  }

  /** A chat roll, scaled by --chat-scale. */
  talks(p) {
    return this.rng.chance(p * config.chatScale);
  }

  async start() {
    await this.comeOnline();
  }

  /** Signs in, tops up if it can, and connects for a new sitting. */
  async comeOnline() {
    if (this.stopped || this.online) return;
    await this.login();
    await this.collectBonus();
    this.online = true;
    this.wrappingUp = false;
    this.handsThisSitting = 0;
    this.plannedHands = sessionHands(this.persona, { mean: config.sessionHands });
    this.connect();
  }

  async login() {
    const res = await fetch(`${config.serverUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        provider: 'guest',
        deviceId: this.identity.deviceId,
        displayName: this.identity.name,
      }),
    });
    if (!res.ok) throw new Error(`login ${res.status} for ${this.identity.name}`);
    const body = await res.json();
    this.token = body.token;
    this.userId = body.user.id;
    this.chips = body.user.chips;
    botUserIds.add(this.userId);
    await this.wearAPicture(body.user);
  }

  /**
   * Collects the 4-hour bonus when the stack is running low — what a player
   * does in the lobby before sitting back down, and far cheaper for the
   * economy than rotating to a freshly minted account (see onBroke). Lobby
   * only: at a table the server answers 409 seated, which is fine.
   */
  async collectBonus() {
    if (this.chips >= this.table.boot * 25) return;
    try {
      const res = await fetch(`${config.serverUrl}/api/rewards/bonus`, {
        method: 'POST',
        headers: { authorization: `Bearer ${this.token}` },
      });
      if (!res.ok) return;
      const body = await res.json();
      if (typeof body?.user?.chips === 'number') {
        this.chips = body.user.chips;
        this.log?.(`${this.identity.name}: collected the timed bonus`);
      }
    } catch {
      // A bot that could not claim its bonus still plays.
    }
  }

  /**
   * Picks the bot's profile picture while it is in the lobby.
   *
   * The server refuses a picture change at a table (409 seated), which is why
   * this runs after login and before the socket connects — normally the one
   * moment a bot is reliably unseated. Not always, though: a fleet restarted
   * inside the server's 60-second reconnect grace finds every seat still
   * held, the request is refused, and until 10 Sep 2026 that refusal was
   * swallowed and never retried, so a restart left two hundred bots faceless
   * for good. Now a refusal marks the bot as owing itself a picture, and the
   * restored seat that follows is answered by stepping out once
   * (stepOutForPicture).
   *
   * Any other failure is still swallowed. The picture is decoration and a bot
   * that could not set one should still sit down and play.
   */
  async wearAPicture(user) {
    this.owesPicture = false;
    if (user?.avatarChoice) return;
    const wanted = profileFor(this.index, await profileIds());
    if (!wanted) return;
    try {
      const res = await fetch(`${config.serverUrl}/api/profile/avatar`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', authorization: `Bearer ${this.token}` },
        body: JSON.stringify({ avatar: wanted }),
      });
      if (res.status === 409) this.owesPicture = true;
    } catch {
      // see above
    }
  }

  /**
   * Leaves the restored seat, wears the picture, sits back down.
   *
   * Runs once per login at most: owesPicture is cleared by wearAPicture
   * whatever the outcome, so a second refusal cannot turn into a leave loop.
   * Leaving mid-hand packs the bot's cards — its own chips, and a fleet-wide
   * restart is rare enough that a round of packs is the cheaper of the two
   * evils next to a lobby of grey circles.
   */
  stepOutForPicture() {
    this.socket?.emit('room:leave', {}, async () => {
      this.seated = false;
      await this.wearAPicture();
      this.log?.(`${this.identity.name}: stepped out for a picture`);
      this.after(1500 + Math.random() * 3000, () => this.join());
    });
  }

  connect() {
    this.socket?.close();
    this.socket = io(config.serverUrl, {
      auth: { token: this.token },
      transports: ['websocket'],
      forceNew: true,
      // Left to the client library: a server restart should not need the
      // fleet restarted with it.
      reconnection: true,
      reconnectionDelay: 2000 + Math.random() * 4000,
      reconnectionDelayMax: 30000,
    });
    const socket = this.socket;

    // Do NOT join on connect. The server restores a player who is still
    // seated and sends `room:joined` by itself — that is how a client survives
    // a reconnect mid-hand. Asking for a seat we already hold is answered
    // `already_in_room`, correctly, and a fleet that does it on every connect
    // spends its first two minutes retrying its way into a seat it never lost.
    // So: wait, and only sit down if nothing arrives.
    socket.on('connect', () => {
      this.after(2500, () => { if (!this.seated) this.join(); });
    });
    socket.on('room:joined', (state) => {
      this.seated = true;
      // The seat the server held through a restart, and a picture still owed:
      // step out and put it on before anything else.
      if (this.owesPicture) return this.stepOutForPicture();
      // Everyone already at this table is known; only later arrivals get a hello.
      this.knownPlayers = new Set((state?.seats ?? []).map((s) => s?.userId).filter(Boolean));
      this.shortHandled = false;
      this.onState(state);
      if (this.wrappingUp) return this.goOffline('the fleet is thinning out');
      // A greeting on arrival, sometimes — not every time, or every table
      // becomes a chorus of hellos whenever anyone sits down.
      if (this.talks(this.persona.chatRate * 1.5)) {
        this.after(1500 + Math.random() * 3500, () => this.say('greeting'));
      }
    });
    socket.on('room:left', () => { this.seated = false; });
    socket.on('room:closed', () => {
      this.seated = false;
      if (!this.leaving) this.after(1500, () => this.join());
    });

    // The server only *emits* a kick; the room manager removes the seat. Both
    // reasons need handling, and they need different handling.
    socket.on('room:kicked', ({ reason }) => {
      this.seated = false;
      if (reason === 'insufficient_chips') return this.onBroke();
      // Idle: this bot missed three turns, which means something was wrong
      // with its own timing. Sit back down after a pause.
      this.after(4000 + Math.random() * 6000, () => this.join());
    });

    socket.on('room:state', (state) => this.onState(state));
    socket.on('game:yourTurn', ({ options, deadline }) => this.onTurn(options, deadline));
    socket.on('game:action', (event) => this.onAction(event));
    // The hand is over: anything still being thought about is stale.
    socket.on('game:showdown', () => { this.turnSeq += 1; });
    socket.on('game:sideshowRequested', (e) => this.onSideshowAsked(e));
    socket.on('game:sideshowResolved', (e) => this.onSideshowResolved(e));
    socket.on('game:handEnded', (e) => this.onHandEnded(e));
    socket.on('chat:message', (m) => this.onChat(m));
  }

  /**
   * Takes a seat, retrying while the answer is one that resolves itself.
   *
   * `already_in_room` is the common one and is not an error: a restart inside
   * the 60-second reconnect grace finds the old seat still held. Retrying
   * rides it out; giving up would bench the bot until someone noticed.
   */
  join(attempt = 1) {
    if (this.stopped || this.leaving || !this.socket?.connected) return;
    this.socket.emit(
      'room:quickJoin',
      { bootAmount: this.table.boot, category: this.table.category },
      (ack) => {
        if (ack?.ok) return;
        if (ack?.code === 'insufficient_chips') return this.onBroke();
        if (ack?.code === 'over_entry_cap') {
          // Too rich for this table, and waiting will not make it poorer.
          this.table = this.affordableTable();
          return this.after(1000 + Math.random() * 2000, () => this.join(attempt + 1));
        }
        const retryable = ack?.code === 'already_in_room' || ack?.code === 'table_full';
        if (retryable && attempt <= 20) {
          return this.after(4000 + Math.random() * 6000, () => this.join(attempt + 1));
        }
        this.log?.(`${this.identity.name}: cannot sit — ${ack?.message ?? ack?.code ?? 'unknown'}`);
      },
    );
  }

  onState(state) {
    if (!state) return;
    this.view = state;
    if (state.roomId) this.roomId = state.roomId;
    const me = state.you;
    if (typeof me?.chips === 'number') this.chips = me.chips;
    this.potRatio = this.table.boot > 0 ? (state.pot ?? 0) / this.table.boot : 0;
    // The snapshot is the authority on whose turn it is — the Flutter client
    // derives it from here too, rather than from game:turn. No options means
    // it is not ours, so a decision in flight is abandoned.
    if (!me?.options) this.turnSeq += 1;

    if (state.state === 'betting' && state.handNo !== this.handNo) {
      this.handNo = state.handNo;
      this.memory = newHandMemory();
      this.shortHandled = false;
      this.maybeLookEarly();
    }
    if (state.state !== 'betting' && typeof me?.chips === 'number' && me.chips < this.table.boot) {
      this.leaveShort();
    }
    this.noticeNewcomers(state);
  }

  /** Someone sat down since this bot arrived: a hello, now and then. */
  noticeNewcomers(state) {
    for (const seat of state.seats ?? []) {
      if (!seat?.userId || this.knownPlayers.has(seat.userId)) continue;
      this.knownPlayers.add(seat.userId);
      if (seat.userId === this.userId) continue;
      // A person is worth greeting; bots greeting bots is a chorus.
      const isBot = botUserIds.has(seat.userId);
      if (isBot && Date.now() - fleetStartedAt < 90_000) continue;
      const chance = isBot ? this.persona.chatRate * 0.15 : this.persona.chatRate * 2;
      if (this.talks(chance)) {
        this.after(1500 + Math.random() * 5000, () => this.say('welcome', { name: firstName(seat.displayName) }));
      }
    }
  }

  /**
   * Careful players look at their cards straight after the deal, before their
   * turn — which the table shows, as the green SEEN backs. Blind-lovers wait.
   */
  maybeLookEarly() {
    const me = this.view?.you;
    if (!me?.isBlind || me.status !== 'active') return;
    if (!this.rng.chance((1 - this.persona.blindLove) * 0.5)) return;
    const hand = this.handNo;
    this.after(1200 + Math.random() * 4000, () => {
      const now = this.view?.you;
      if (this.handNo !== hand || !now?.isBlind || now.status !== 'active' || this.view?.state !== 'betting') return;
      this.socket?.emit('game:action', { action: 'see', actionId: randomUUID() }, () => {});
    });
  }

  /**
   * Decide and act.
   *
   * brain.decide picks a move from what the SERVER said is legal — `options` —
   * and the cards this bot has looked at. The decision is made first so that
   * a heavy one (a big raise, a show) can take longer to arrive, the way a
   * person hesitates before pushing chips in.
   */
  onTurn(options, deadline) {
    if (this.stopped || !options) return;
    this.turnSeq += 1;
    const seq = this.turnSeq;
    const move = decide({
      options,
      view: this.view,
      me: this.userId,
      persona: this.persona,
      memory: this.memory,
      rng: this.rng,
      tilt: this.tilt,
    });
    const heavy = move.action === 'raise' || move.action === 'show';
    const delay = thinkTime(this.persona, {
      potRatio: this.potRatio ?? 0,
      heavy,
      quick: move.action === 'see',
      light: move.action === 'chaal' && Boolean(this.view?.you?.isBlind),
    });
    // Never let the think time eat the turn clock. A bot that times out gets
    // packed automatically and, three of those in a row, kicked for idling.
    const room = deadline ? Math.max(1200, deadline - Date.now() - 3500) : delay;
    this.after(Math.min(delay, room), () => {
      // The hand moved on while this bot was thinking.
      if (seq !== this.turnSeq) return;
      this.play(move);
    });
  }

  play(move) {
    const payload = { action: move.action, actionId: randomUUID() };
    if ((move.action === 'chaal' || move.action === 'raise') && move.amount != null) payload.amount = move.amount;
    this.socket?.emit('game:action', payload, (ack) => {
      if (ack?.ok) return this.afterMove(move);
      if (!ack || RACED.has(ack.code)) return;
      // A refusal is worth seeing: this bot's idea of what is legal has
      // drifted from the server's, which is a bug, not bad luck. The turn is
      // not wasted on it — fall back to the plainest move.
      this.log?.(`${this.identity.name}: ${move.action}${move.amount ? ` ${move.amount}` : ''} refused — ${ack.code}`);
      if (move.action !== 'chaal' && move.action !== 'pack') {
        this.socket?.emit('game:action', { action: 'chaal', actionId: randomUUID() }, () => {});
      }
    });
  }

  afterMove(move) {
    if (move.action === 'raise') this.memory.raisedThisHand += 1;
    this.memory.raisesFaced = 0;
    if (config.verbose && move.action !== 'see') {
      const detail = move.hand ? ` (${move.hand}${move.bluff ? ', bluffing' : ''})` : ' (blind)';
      this.log?.(`${this.identity.name}: ${move.action}${move.amount ? ` ${move.amount}` : ''}${detail}`);
    }
    if (move.mood === 'blind' && this.talks(this.persona.chatRate * 0.6)) {
      this.after(800 + Math.random() * 2500, () => this.say('blind'));
    }
    if (move.action === 'pack' && move.hand && this.talks(this.persona.chatRate * 0.25)) {
      this.after(900 + Math.random() * 2500, () => this.say('packed'));
    }
  }

  /** Other players' moves: who is betting hard this hand. */
  onAction({ userId, action, amount }) {
    if (!this.userId || userId === this.userId || action !== 'raise') return;
    this.memory.raisesFaced += 1;
    this.memory.biggestRaiseFaced = Math.max(this.memory.biggestRaiseFaced, amount ?? 0);
    if ((amount ?? 0) >= this.table.boot * 16 && this.talks(this.persona.chatRate * 0.8)) {
      this.after(1500 + Math.random() * 3000, () => this.say('bigRaise'));
    }
  }

  onSideshowAsked({ toUserId, expiresAt }) {
    if (toUserId !== this.userId || this.stopped) return;
    const { answer } = answerSideshow({ view: this.view, persona: this.persona, rng: this.rng });
    // A few are simply left to expire — a player who did not notice. The
    // server's six-second timeout handles it.
    if (answer == null) return;
    const room = expiresAt ? Math.max(400, expiresAt - Date.now() - 1200) : 5000;
    this.after(Math.min(room, 900 + Math.random() * 2600), () => {
      this.socket?.emit('game:sideshowRespond', { accept: answer });
    });
  }

  onSideshowResolved({ fromUserId, toUserId, accepted, packedUserId }) {
    if (!accepted || !packedUserId || (fromUserId !== this.userId && toUserId !== this.userId)) return;
    if (!this.talks(this.persona.chatRate * 1.2)) return;
    this.after(1200 + Math.random() * 2500, () => this.say(packedUserId === this.userId ? 'sideshowLost' : 'sideshowWon'));
  }

  onHandEnded({ winnerId, winnerName, pot, reveals }) {
    if (this.stopped) return;
    this.turnSeq += 1;
    const boot = this.table.boot;
    const me = this.view?.you;
    const contributed = me?.contributed ?? 0;
    const played = contributed > 0 && me?.status !== 'waiting';
    const won = winnerId === this.userId;
    const net = won ? (pot ?? 0) - contributed : -contributed;
    this.tilt = Math.max(0, Math.min(1, this.tilt * 0.7 + (net <= -boot * 10 ? 0.35 : 0)));
    if (played) this.handsThisSitting += 1;

    if (played && this.talks(this.persona.chatRate)) {
      const winners = !won ? (reveals ?? []).find((r) => r.userId === winnerId) : null;
      const mood = winners && winners.category >= PURE_SEQUENCE ? 'niceHand' : moodFor({ won, pot: pot ?? 0, boot });
      this.after(900 + Math.random() * 2600, () => this.say(mood, { name: firstName(winnerName) }));
    }

    // Between hands is when a person gets up.
    if (!config.steady && (this.wrappingUp || this.handsThisSitting >= this.plannedHands)) {
      const why = this.wrappingUp ? 'the fleet is thinning out' : `after ${this.handsThisSitting} hands`;
      // Promptly: the next deal is NEXT_HAND_DELAY (4 s) away, and a bot still
      // seated then is dealt in, and leaving packs that boot away.
      this.after(600 + Math.random() * 800, () => this.goOffline(why));
    }
  }

  /** People talk back — to a hello, and when their name comes up. */
  onChat({ userId, text, system }) {
    if (system || !userId || userId === this.userId || !this.seated) return;
    const lower = String(text ?? '').toLowerCase();
    const scale = botUserIds.has(userId) ? 0.1 : 1;
    const name = firstName(this.identity.name).toLowerCase();
    if (name.length >= 3 && lower.includes(name)) {
      if (this.talks(0.6 * scale)) this.after(2000 + Math.random() * 4000, () => this.say('replyName'));
      return;
    }
    if (/\b(hi+|hello|hey|namaste|hlo)\b/.test(lower) && this.talks(this.persona.chatRate * 1.5 * scale)) {
      this.after(2000 + Math.random() * 5000, () => this.say('replyHi'));
    }
  }

  say(mood, vars) {
    if (this.stopped || !this.seated) return false;
    // Our own cooldown, well inside the server's 5-in-5-seconds limiter. A bot
    // that trips a rate limit is a bot generating `rate_limited` metrics on a
    // production server for no reason.
    const now = Date.now();
    if (now - this.lastChatAt < 12000) return false;
    if (!tableAllowsChat(this.roomId, now)) return false;
    const line = pickLine(this.index, mood, vars);
    if (!line) return false;
    this.lastChatAt = now;
    this.socket?.emit('chat:message', { text: line });
    return true;
  }

  /**
   * Gets up and finds another table in the same category.
   *
   * This is not decoration. The server seats a player at the FULLEST table
   * with room, so without churn exactly one table in each category ever has a
   * free seat — and a real player arriving is always dropped into the same
   * one. Bots coming and going keep seats open across the whole lobby, which
   * is what a busy game actually looks like.
   */
  wander() {
    if (this.stopped || !this.seated || this.leaving) return;
    this.socket?.emit('room:switch', {}, (ack) => {
      if (ack?.ok === false && ack.code === 'insufficient_chips') this.onBroke();
    });
  }

  /**
   * Moves to a DIFFERENT lobby table — another stake, or the other category.
   *
   * `wander` cannot do this: room:switch is defined as "another table of the
   * same boot and category", which is what a player means by switching seats.
   * Changing stake is leaving one game for another, so it is a leave and a
   * fresh quick-join, exactly as a player would do it from the lobby.
   *
   * Only some bots ever do it, and rarely, because a fleet that redistributes
   * itself constantly leaves whole stakes empty for minutes at a time.
   */
  hop() {
    if (this.stopped || !this.seated || this.leaving) return;
    const elsewhere = config.categories.filter(
      (c) => !(c.category === this.table.category && c.boot === this.table.boot),
    );
    if (!elsewhere.length) return;
    const next = elsewhere[Math.floor(Math.random() * elsewhere.length)];
    this.socket?.emit('room:leave', {}, () => {
      this.seated = false;
      this.table = next;
      this.log?.(`${this.identity.name}: moving to ${next.category}/${next.boot}`);
      // A beat in the lobby before sitting down again, so the move reads as a
      // decision rather than a teleport.
      this.after(1500 + Math.random() * 3000, () => this.join());
    });
  }

  /**
   * A table this bot can actually sit at, given what it is carrying.
   *
   * Requirement 30 caps the cheapest blind table so a big stack cannot sit
   * down at it. A bot that has won its way past the cap is refused for ever
   * otherwise, and retrying twenty times does not change its balance.
   */
  affordableTable() {
    const others = config.categories.filter(
      (c) => !(c.category === this.table.category && c.boot === this.table.boot),
    );
    return others[Math.floor(Math.random() * others.length)] ?? this.table;
  }

  /** Asked by the fleet to get up after this hand. */
  wrapUp() {
    if (!this.online || this.leaving) return;
    this.wrappingUp = true;
    if (!this.seated) this.goOffline('the fleet is thinning out');
  }

  /**
   * Ends a sitting: sometimes a goodbye, then up from the table and offline
   * for a while. The fleet (fleet.js) brings the bot back once it has rested,
   * which is how the faces at a table change through an evening.
   */
  async goOffline(reason) {
    if (!this.online || this.leaving || this.stopped) return;
    this.leaving = true;
    this.turnSeq += 1;
    if (this.seated && this.talks(this.persona.chatRate * 2) && this.say('leaving')) {
      await sleep(600 + Math.random() * 400);
    }
    if (this.socket?.connected && this.seated) {
      await new Promise((resolve) => {
        const timeout = setTimeout(resolve, 3000);
        this.socket.emit('room:leave', {}, () => { clearTimeout(timeout); resolve(); });
      });
    }
    this.seated = false;
    this.socket?.close();
    this.socket = null;
    this.online = false;
    this.wrappingUp = false;
    this.leaving = false;
    this.restUntil = Date.now() + restMs(this.persona, { meanMinutes: config.restMinutes });
    this.log?.(`${this.identity.name}: got up ${reason} — back in ~${Math.max(1, Math.round((this.restUntil - Date.now()) / 60000))}m`);
  }

  /**
   * Out of chips at the end of a hand. A person says so and leaves rather than
   * sitting at a table they cannot be dealt into (the server would hold the
   * seat for its unfunded grace, then show them out anyway).
   */
  leaveShort() {
    if (this.shortHandled || this.leaving || !this.seated) return;
    this.shortHandled = true;
    if (this.talks(this.persona.chatRate * 2)) this.say('lowChips');
    this.after(2000 + Math.random() * 2000, () => {
      if (!this.seated || this.leaving) return;
      this.socket?.emit('room:leave', {}, () => {
        this.seated = false;
        this.onBroke();
      });
    });
  }

  /**
   * The bot cannot cover the boot any more.
   *
   * First, the timed bonus — the honest top-up every player has. If that
   * covers the boot, sit back down. Otherwise either it retires — the honest
   * outcome, and the fleet quietly shrinks — or it takes a new guest identity,
   * which the server greets with WELCOME_CHIPS. The second keeps the lobby
   * full and MINTS CHIPS, so every rotation is logged with a running total.
   * See config.onBroke.
   */
  async onBroke() {
    if (this.stopped || this.handlingBroke) return;
    this.handlingBroke = true;
    try {
      this.seated = false;
      await this.collectBonus();
      if (this.chips >= this.table.boot) {
        this.after(2000 + Math.random() * 3000, () => this.join());
        return;
      }
      if (config.onBroke !== 'rotate') {
        this.log?.(`${this.identity.name}: out of chips, retiring`);
        this.stop();
        return;
      }
      this.generation += 1;
      this.identity = rotatedIdentity(this.index, this.generation);
      this.socket?.close();
      try {
        await this.login();
        this.connect();
        this.log?.(`${this.identity.name}: out of chips, rotated to generation ${this.generation}`, {
          minted: true,
        });
      } catch (e) {
        this.log?.(`${this.identity.name}: rotation failed — ${e.message}`);
        this.after(30000, () => this.onBroke());
      }
    } finally {
      this.handlingBroke = false;
    }
  }

  stop() {
    this.stopped = true;
    this.online = false;
    for (const t of this.timers) clearTimeout(t);
    this.timers.clear();
    this.socket?.close();
  }
}
