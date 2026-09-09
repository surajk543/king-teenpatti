import { io } from 'socket.io-client';

import { config } from './config.js';
import { moodFor, pickLine } from './chat.js';
import { identityFor, rotatedIdentity } from './identities.js';
import { personaFor, thinkTime } from './persona.js';

/**
 * One resident player.
 *
 * It speaks only the public protocol — the same events the Flutter client
 * sends — and acts only on the options the server hands it. It has no
 * privileged view of anyone's cards, because it is given none: the server
 * redacts per viewer, and a bot is just another viewer.
 *
 * Everything here that looks like a flourish is load-bearing for one of two
 * things: not being obviously a bot, or not falling over unattended. The
 * second matters more. This runs for weeks without anyone watching, through
 * server restarts, network blips and its own bad luck at cards.
 */
export class Bot {
  constructor({ index, table, log }) {
    this.index = index;
    this.table = table; // { category, boot }
    this.log = log;
    this.persona = personaFor(index);
    this.generation = 0;
    this.identity = identityFor(index);

    this.socket = null;
    this.token = null;
    this.userId = null;
    this.chips = 0;
    this.stopped = false;
    this.seated = false;
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

  async start() {
    await this.login();
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
  }

  connect() {
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

    // Do NOT join on connect. The server restores a player who is still
    // seated and sends `room:joined` by itself — that is how a client survives
    // a reconnect mid-hand. Asking for a seat we already hold is answered
    // `already_in_room`, correctly, and a fleet that does it on every connect
    // spends its first two minutes retrying its way into a seat it never lost.
    // So: wait, and only sit down if nothing arrives.
    this.socket.on('connect', () => {
      this.after(2500, () => { if (!this.seated) this.join(); });
    });
    this.socket.on('room:joined', () => {
      this.seated = true;
      // A greeting on arrival, sometimes — not every time, or every table
      // becomes a chorus of hellos whenever anyone sits down.
      if (Math.random() < this.persona.chatRate * 1.5) {
        this.after(1500 + Math.random() * 3500, () => this.say('greeting'));
      }
    });
    this.socket.on('room:left', () => { this.seated = false; });
    this.socket.on('room:closed', () => { this.seated = false; this.after(1500, () => this.join()); });

    // The server only *emits* a kick; the room manager removes the seat. Both
    // reasons need handling, and they need different handling.
    this.socket.on('room:kicked', ({ reason }) => {
      this.seated = false;
      if (reason === 'insufficient_chips') return this.onBroke();
      // Idle: this bot missed three turns, which means something was wrong
      // with its own timing. Sit back down after a pause.
      this.after(4000 + Math.random() * 6000, () => this.join());
    });

    this.socket.on('room:state', (state) => this.onState(state));
    this.socket.on('game:yourTurn', ({ options, deadline }) => this.onTurn(options, deadline));
    // The hand is over: anything still being thought about is stale.
    this.socket.on('game:showdown', () => { this.turnSeq += 1; });
    this.socket.on('game:sideshowRequested', (e) => this.onSideshowAsked(e));
    this.socket.on('game:handEnded', (e) => this.onHandEnded(e));
  }

  /**
   * Takes a seat, retrying while the answer is one that resolves itself.
   *
   * `already_in_room` is the common one and is not an error: a restart inside
   * the 60-second reconnect grace finds the old seat still held. Retrying
   * rides it out; giving up would bench the bot until someone noticed.
   */
  join(attempt = 1) {
    if (this.stopped || !this.socket?.connected) return;
    this.socket.emit(
      'room:quickJoin',
      { bootAmount: this.table.boot, category: this.table.category },
      (ack) => {
        if (ack?.ok) return;
        if (ack?.code === 'insufficient_chips') return this.onBroke();
        const retryable = ack?.code === 'already_in_room' || ack?.code === 'table_full' ||
          ack?.code === 'over_entry_cap';
        if (retryable && attempt <= 20) {
          return this.after(4000 + Math.random() * 6000, () => this.join(attempt + 1));
        }
        this.log?.(`${this.identity.name}: cannot sit — ${ack?.message ?? ack?.code ?? 'unknown'}`);
      },
    );
  }

  onState(state) {
    const me = state?.you;
    if (typeof me?.chips === 'number') this.chips = me.chips;
    this.potRatio = this.table.boot > 0 ? (state?.pot ?? 0) / this.table.boot : 0;
    // The snapshot is the authority on whose turn it is — the Flutter client
    // derives it from here too, rather than from game:turn. No options means
    // it is not ours, so a decision in flight is abandoned.
    if (!me?.options) this.turnSeq += 1;
  }

  /**
   * Decide and act.
   *
   * Every branch is gated on what the SERVER said is legal — `options` — not
   * on what this bot believes about the hand. Sending an illegal move would be
   * refused and counted as an invalid move, and a fleet doing that continually
   * would poison the metrics the real game is watched by.
   */
  onTurn(options, deadline) {
    if (this.stopped) return;
    this.turnSeq += 1;
    const seq = this.turnSeq;
    const delay = thinkTime(this.persona, { potRatio: this.potRatio ?? 0 });
    // Never let the think time eat the turn clock. A bot that times out gets
    // packed automatically and, three of those in a row, kicked for idling.
    const room = deadline ? Math.max(1200, deadline - Date.now() - 3500) : delay;
    this.after(Math.min(delay, room), () => {
      // The hand moved on while this bot was thinking.
      if (seq !== this.turnSeq) return;
      const action = this.decide(options);
      if (!action) return;
      this.socket?.emit('game:action', { action }, (ack) => {
        // A refusal is worth seeing: it means this bot's idea of what is legal
        // has drifted from the server's, which is a bug, not bad luck.
        // `not_your_turn`, `no_hand` and `not_in_hand` all mean the same
        // thing — the race above was lost anyway — and are not worth a line.
        const raced = ['not_your_turn', 'no_hand', 'not_in_hand', 'show_unavailable'];
        if (ack && ack.ok === false && !raced.includes(ack.code)) {
          this.log?.(`${this.identity.name}: ${action} refused — ${ack.code}`);
        }
      });
    });
  }

  decide(options) {
    if (!options) return null;
    const p = this.persona;

    // Looking is free and does not end the turn, so it is a decision on its
    // own: some players peek immediately, some run blind for a few rounds.
    if (options.canSee && Math.random() < p.seeRate) return 'see';

    if (options.show && Math.random() < p.showRate) return 'show';
    if (options.canSideshow && Math.random() < p.sideshowRate) return 'sideshow';

    if (Math.random() < p.packRate) return 'pack';
    if (options.raise && Math.random() < p.raiseRate) return 'raise';
    if (options.chaal) return 'chaal';
    if (options.raise) return 'raise';
    return 'pack';
  }

  onSideshowAsked({ toUserId }) {
    if (toUserId !== this.userId || this.stopped) return;
    const roll = Math.random();
    // A few are simply left to expire — a player who did not notice. The
    // server's six-second timeout handles it, and a table where every ask is
    // answered instantly is a table of programs.
    if (roll > 0.92) return;
    this.after(900 + Math.random() * 2600, () => {
      this.socket?.emit('game:sideshowRespond', { accept: roll < 0.7 });
    });
  }

  onHandEnded({ winnerId, pot }) {
    if (this.stopped) return;
    this.turnSeq += 1;
    if (Math.random() < this.persona.chatRate) {
      const mood = moodFor({ won: winnerId === this.userId, pot: pot ?? 0, boot: this.table.boot });
      this.after(900 + Math.random() * 2600, () => this.say(mood));
    }
  }

  say(mood) {
    if (this.stopped || !this.seated) return;
    // Our own cooldown, well inside the server's 5-in-5-seconds limiter. A bot
    // that trips a rate limit is a bot generating `rate_limited` metrics on a
    // production server for no reason.
    const now = Date.now();
    if (now - this.lastChatAt < 12000) return;
    const line = pickLine(this.index, mood);
    if (!line) return;
    this.lastChatAt = now;
    this.socket?.emit('chat:message', { text: line });
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
    if (this.stopped || !this.seated) return;
    this.socket?.emit('room:switch', {}, (ack) => {
      if (ack?.ok === false && ack.code === 'insufficient_chips') this.onBroke();
    });
  }

  /**
   * The bot cannot cover the boot any more.
   *
   * Either it retires — the honest outcome, and the fleet quietly shrinks — or
   * it takes a new guest identity, which the server greets with WELCOME_CHIPS.
   * The second keeps the lobby full and MINTS CHIPS, so every rotation is
   * logged with a running total. See config.onBroke.
   */
  async onBroke() {
    if (this.stopped) return;
    this.seated = false;
    if (config.onBroke !== 'rotate') {
      this.log?.(`${this.identity.name}: out of chips, retiring`);
      return this.stop();
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
  }

  stop() {
    this.stopped = true;
    for (const t of this.timers) clearTimeout(t);
    this.timers.clear();
    this.socket?.close();
  }
}
