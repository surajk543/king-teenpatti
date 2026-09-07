import { EventEmitter } from 'node:events';
import { deal, cardCode } from './deck.js';
import { evaluate, compare } from './handRank.js';
import { ACTION, SEAT_STATE, TABLE_CATEGORY, TABLE_STATE, WIN_REASON } from './constants.js';
import { RoomChat } from './chat.js';
import { uuid } from '../util/ids.js';

/**
 * One Teen Patti table.
 *
 * The table owns all authoritative game state and is completely transport
 * agnostic — it emits events and the socket layer forwards them.
 *
 * Money is database-first. A bet is validated in memory (turn, amount,
 * balance), then written as one transaction through the injected `ledger`
 * (wallet locked and debited, pot credited, append-only ledger row, table
 * state versioned), and only once that has committed does the table change
 * what it holds and tell anyone. A write that fails leaves the game exactly as
 * it was and the player is told the move was refused.
 *
 * Because those writes are asynchronous, every mutation goes through a
 * per-table queue (`_run`) so a turn timeout can never interleave with a bet
 * that is halfway to the database. Every public mutator therefore returns a
 * promise.
 *
 * Events:
 *   'state'              (table)                       — something changed, re-broadcast
 *   'seatUpdated'        ({ seatIndex })
 *   'chat'               (message)
 *   'handStarted'        ({ handId, handNo, dealerSeat, ... })
 *   'cards'              ({ userId, cards })           — private, send to that player only
 *   'turn'               ({ userId, seatIndex, deadline, timeoutMs, options })
 *   'action'             ({ userId, action, amount, pot, stake, reason?, auto? })
 *   'sideshowRequested'  (public), 'sideshowReveal' ({ userIds, reveal }), 'sideshowResolved' (public)
 *   'showdown'           ({ reveals, reason })
 *   'handEnded'          ({ winnerId, pot, reason, summary, nextHandAt })
 *   'kick'               ({ userId, displayName, reason, message }) — the room manager removes them
 *   'persistError'       ({ reason, error, ... })       — a database write failed
 *   'error'              (error)                        — settlement failed for good
 */
export class Table extends EventEmitter {
  constructor({ id, code, config, ledger, settle, persistChips, timers = defaultTimers }) {
    super();
    this.id = id;
    this.code = code;
    this.config = config;

    /**
     * Where the chips are actually kept. Production hands in the PostgreSQL
     * ledger (db/ledger.js). Tests may pass their own object with the same
     * three methods, or the older `settle` / `persistChips` callbacks, which
     * are wrapped into one here.
     */
    this.ledger = ledger ?? memoryLedger({ settle, persistChips });
    this.timers = timers;

    /**
     * Rises by one on every committed write. It travels with each transaction
     * so the database refuses a write from anything holding an older picture
     * of this table.
     */
    this.version = 0;

    /**
     * "seen" — every player's chip stack is visible to everyone.
     * "blind" — you see only your own stack.
     * This is enforced in serializeFor, not in the client.
     */
    this.category = config.category === TABLE_CATEGORY.BLIND
      ? TABLE_CATEGORY.BLIND
      : TABLE_CATEGORY.SEEN;

    /**
     * Largest the pot may grow to, or 0 for no cap. Private tables set this
     * (requirement 22); once it is reached the hand goes straight to a
     * showdown rather than letting the pot run past the limit.
     */
    this.maxPot = config.maxPot ?? 0;

    this.seats = Array.from({ length: config.maxPlayers }, () => null);
    this.state = TABLE_STATE.WAITING;
    this.handNo = 0;
    this.hand = null;
    this.dealerSeat = -1;
    this.createdAt = Date.now();

    // Room-scoped chat, held in memory and thrown away with the table.
    this.chat = new RoomChat({
      maxHistory: config.chatMaxHistory,
      maxLength: config.chatMaxLength,
    });

    this._turnTimer = null;
    this._startTimer = null;
    this._destroyed = false;

    /** The mutation queue. Everything that can change the hand runs through it. */
    this._queue = Promise.resolve();
  }

  /**
   * Runs `fn` after every mutation queued before it has finished.
   *
   * Only entry points wrap themselves in this — a method already inside the
   * queue must call the plain `_…` implementations directly, or it would wait
   * on itself.
   */
  _run(fn) {
    const run = this._queue.then(fn, fn);
    this._queue = run.then(() => undefined, () => undefined);
    return run;
  }

  /** Resolves once every queued mutation so far has finished. For tests. */
  settled() {
    return this._queue;
  }

  // ---------------------------------------------------------------- seating

  get occupiedSeats() {
    return this.seats.filter(Boolean);
  }

  get playerCount() {
    return this.occupiedSeats.length;
  }

  get isFull() {
    return this.playerCount >= this.config.maxPlayers;
  }

  get isEmpty() {
    return this.playerCount === 0;
  }

  findSeat(userId) {
    return this.seats.find((seat) => seat && seat.userId === userId) ?? null;
  }

  /**
   * Seats a player. A player who joins while a hand is live sits out until the
   * next deal — they are never dealt into a hand already in progress.
   *
   * Synchronous: sitting down moves no chips.
   */
  addPlayer({ userId, displayName, avatarUrl, chips, socketId }) {
    if (this.findSeat(userId)) throw new GameError('already_seated', 'You are already at this table');
    if (this.isFull) throw new GameError('table_full', 'This table is full');

    const seatIndex = this.seats.findIndex((seat) => seat === null);
    const seat = {
      seatIndex,
      userId,
      displayName,
      avatarUrl: avatarUrl ?? null,
      chips,
      socketId,
      connected: true,
      status: SEAT_STATE.WAITING,
      cards: [],
      isBlind: true,
      /** Bets made while blind this hand; at the cap the cards turn face up. */
      blindMoves: 0,
      /**
       * Turns let time out back to back (requirement 31). Any move the player
       * makes themselves clears it; three in a row and the seat goes to
       * somebody who is actually at the table.
       */
      missedTurns: 0,
      /** One sideshow request per turn; cleared when their turn comes round. */
      sideshowAskedThisTurn: false,
      /** The last bet this player made, and what it was, for the table to see. */
      lastBet: 0,
      lastAction: null,
      contributed: 0,
      joinedAt: Date.now(),
      disconnectedAt: null,
    };

    this.seats[seatIndex] = seat;
    this.emit('seatUpdated', { seatIndex });

    // Announce the arrival in the room log, so a player who joins mid-session
    // has context for the history they are about to be shown.
    this.emit('chat', this.chat.addSystem(`${displayName} joined the table`));

    this._maybeStart();
    this.emit('state', this);
    return seat;
  }

  /**
   * Posts a player message to this room's chat.
   *
   * History is per room and in memory only, so it reaches exactly the players
   * at this table and nobody else.
   */
  postChat(userId, text) {
    const seat = this.findSeat(userId);
    if (!seat) throw new GameError('not_in_room', 'You are not at this table');

    const message = this.chat.add({
      userId,
      displayName: seat.displayName,
      text,
    });
    if (!message) return null;

    this.emit('chat', message);
    return message;
  }

  /** The room's message history, oldest first — what a joining player is sent. */
  chatHistory() {
    return this.chat.history();
  }

  /**
   * Removes a player. If they were live in a hand their stake stays in the pot
   * — leaving mid-hand is a pack, exactly as if they had folded.
   */
  removePlayer(userId, reason = 'left') {
    return this._run(() => this._removePlayer(userId, reason));
  }

  async _removePlayer(userId, reason) {
    const seat = this.findSeat(userId);
    if (!seat) return null;

    const wasOnTurn = this.hand?.turnSeat === seat.seatIndex;
    const wasActive = seat.status === SEAT_STATE.ACTIVE;

    // A sideshow one of them is no longer around for cannot be answered, so
    // it is dropped now rather than left to expire — otherwise the other
    // player would sit and wait out a clock for nothing.
    const pendingSideshow = this.hand?.sideshow;
    if (pendingSideshow
        && (pendingSideshow.fromUserId === userId || pendingSideshow.toUserId === userId)) {
      await this._resolveSideshow(false, 'left');
    }

    this.seats[seat.seatIndex] = null;
    this.emit('seatUpdated', { seatIndex: seat.seatIndex });
    this.emit('chat', this.chat.addSystem(`${seat.displayName} left the table`));

    if (wasActive && this.hand) {
      this.hand.packedUserIds.add(userId);
      seat.status = SEAT_STATE.PACKED;
      this._syncContribution(seat, SEAT_STATE.PACKED);

      // Requirement 15/16: remember that this player abandoned the hand, and
      // who the most recent leaver was in case everybody walks away.
      const entry = this.hand.contributions.get(userId);
      if (entry) entry.leftMidHand = true;
      this.hand.lastDeparture = userId;
      this.emit('action', {
        userId,
        action: ACTION.PACK,
        amount: 0,
        pot: this.hand.pot,
        stake: this.hand.stake,
        reason,
      });
      if (await this._resolveIfOnlyOneLeft()) return seat;
      if (wasOnTurn) {
        this._clearTurnTimer();
        await this._advanceTurn(seat.seatIndex);
      }
    } else if (this.state === TABLE_STATE.STARTING && this._fundedSeats().length < this.config.minPlayers) {
      this._cancelStart();
    } else if (this.state === TABLE_STATE.WAITING) {
      // Somebody shown out for being unfunded may have been what stopped the
      // last start; with them gone the rest can get on with it.
      this._maybeStart();
    }

    this.emit('state', this);
    return seat;
  }

  setConnected(userId, connected, socketId = null) {
    const seat = this.findSeat(userId);
    if (!seat) return null;
    seat.connected = connected;
    seat.disconnectedAt = connected ? null : Date.now();
    if (socketId) seat.socketId = socketId;
    this.emit('seatUpdated', { seatIndex: seat.seatIndex });
    this.emit('state', this);
    return seat;
  }

  /** Applies an authoritative balance (post-settlement, or after a top-up). */
  setChips(userId, chips) {
    const seat = this.findSeat(userId);
    if (!seat) return;
    seat.chips = chips;
    this.emit('seatUpdated', { seatIndex: seat.seatIndex });
  }

  // ------------------------------------------------------------ hand start

  /** Seats that can afford the boot and are therefore dealt into the next hand. */
  _fundedSeats() {
    return this.occupiedSeats.filter((seat) => seat.chips >= this.config.bootAmount);
  }

  _maybeStart() {
    if (this._destroyed) return;
    if (this.state !== TABLE_STATE.WAITING) return;
    if (this._startTimer) return;

    // Requirement 32: the boot comes out of every player at the deal, so anyone
    // who cannot cover it is shown out now rather than sitting at a table they
    // can never be dealt into.
    this._sweepUnfunded();

    if (this._fundedSeats().length < this.config.minPlayers) return;

    this.state = TABLE_STATE.STARTING;
    this.startsAt = Date.now() + this.config.nextHandDelayMs;
    this.emit('state', this);

    this._startTimer = this.timers.setTimeout(() => {
      this._startTimer = null;
      return this._run(() => this._startHand());
    }, this.config.nextHandDelayMs);
  }

  _cancelStart() {
    if (this._startTimer) {
      this.timers.clearTimeout(this._startTimer);
      this._startTimer = null;
    }
    this.startsAt = null;
    this.state = TABLE_STATE.WAITING;
    this.emit('state', this);
  }

  /** Deals the next hand now (the countdown normally does this). */
  startHand() {
    return this._run(() => this._startHand());
  }

  /**
   * Deals a hand — database first.
   *
   * The boots are collected in one transaction before a single card is dealt
   * or a single seat is changed. Until it commits, nothing here has happened as
   * far as the table (or anyone watching it) is concerned. If it is refused the
   * table drops back to waiting and tries again shortly.
   */
  async _startHand() {
    if (this._destroyed) return null;
    if (this.hand) return null;

    // Requirement 32: the boot is about to come out of everyone, so this is
    // the moment to show out anyone who cannot cover it. Doing it here as well
    // as in _maybeStart matters: a player can sit down after the countdown has
    // already begun, and that path never passes through _maybeStart again.
    this._sweepUnfunded();

    const participants = this._fundedSeats();
    if (participants.length < this.config.minPlayers) {
      this.state = TABLE_STATE.WAITING;
      this.startsAt = null;
      this.emit('state', this);
      return null;
    }

    const bootAmount = this.config.bootAmount;
    const handId = uuid();
    const handNo = this.handNo + 1;
    const dealerSeat = this._nextOccupiedSeat(this.dealerSeat, participants);
    const { hands } = deal(participants.length);

    // The hand as it will be once the boots have been paid — built beside the
    // table, not on it, and shown to the database before it is adopted.
    const hand = {
      id: handId,
      handNo,
      startedAt: Date.now(),
      pot: bootAmount * participants.length,
      stake: bootAmount,
      round: 0,
      packedUserIds: new Set(),
      turnSeat: -1,
      startSeat: -1,
      seatOrder: participants.map((seat) => seat.seatIndex),
      showRequestedBy: null,
      /** The sideshow awaiting an answer, if any. At most one at a time. */
      sideshow: null,
      /**
       * The last player to walk away while this hand was live. If everybody
       * leaves, the pot goes to them (requirement 15) rather than evaporating.
       */
      lastDeparture: null,
      // Keyed by userId and owned by the hand rather than the seat, so a player
      // who leaves mid-hand still has their stake settled and audited.
      contributions: new Map(),
    };
    participants.forEach((seat, index) => {
      hand.contributions.set(seat.userId, {
        userId: seat.userId,
        displayName: seat.displayName,
        seatIndex: seat.seatIndex,
        contributed: bootAmount,
        status: SEAT_STATE.ACTIVE,
        sawCards: false,
        cards: hands[index],
        /** Set once the player bets beyond the boot — this is what "played" means. */
        didChaal: false,
        /** Set when the player abandons the hand before it finishes. */
        leftMidHand: false,
        /** How much of this contribution the account has already been debited. */
        persisted: 0,
      });
    });

    let balances;
    let persistedBoot = bootAmount;
    try {
      ({ balances, persisted: persistedBoot = bootAmount } = await this.ledger.collectBoot({
        roomId: this.id,
        handId,
        bootAmount,
        entries: participants.map((seat) => ({
          userId: seat.userId,
          amount: bootAmount,
          balanceBefore: seat.chips,
        })),
        version: this.version + 1,
        state: this._snapshot({ hand, handNo, dealerSeat, deals: hands, participants, bootAmount }),
      }));
    } catch (error) {
      return this._startRefused(error);
    }
    this.version += 1;

    // Committed. Now, and only now, the table takes the hand on. The ledger
    // says how much of each boot it actually banked: all of it in production,
    // nothing for a table that keeps no books — settlement then moves whatever
    // is left, which is how the unit suites can still check conservation.
    for (const entry of hand.contributions.values()) entry.persisted = persistedBoot;
    this.handNo = handNo;
    this.dealerSeat = dealerSeat;
    for (const seat of this.occupiedSeats) {
      seat.cards = [];
      seat.isBlind = true;
      seat.blindMoves = 0;
      seat.lastBet = 0;
      seat.lastAction = null;
      seat.contributed = 0;
      seat.status = participants.includes(seat) ? SEAT_STATE.ACTIVE : SEAT_STATE.WAITING;
    }
    participants.forEach((seat, index) => {
      seat.cards = hands[index];
      seat.contributed = bootAmount;
      // The database's figure wins over what the seat believed it had.
      if (Object.prototype.hasOwnProperty.call(balances ?? {}, seat.userId)) {
        seat.chips = balances[seat.userId];
      } else {
        seat.chips -= bootAmount;
      }
    });

    this.hand = hand;
    this.state = TABLE_STATE.BETTING;
    this.startsAt = null;

    this.emit('handStarted', {
      handId: hand.id,
      handNo: this.handNo,
      dealerSeat: this.dealerSeat,
      bootAmount,
      pot: hand.pot,
      stake: hand.stake,
      participants: participants.map((seat) => seat.userId),
    });

    // Play opens to the dealer's left and rotates clockwise from there.
    const firstSeat = this._nextActiveSeat(this.dealerSeat);
    hand.startSeat = firstSeat;
    this._setTurn(firstSeat);
    this.emit('state', this);
    return hand;
  }

  /**
   * The boots could not be collected. Nothing was dealt; the table goes back
   * to waiting. A player the database says cannot pay is shown out (their seat
   * had a stale balance); any other failure is retried after the usual delay.
   */
  _startRefused(error) {
    this.emit('persistError', { reason: 'boot', error });
    this.state = TABLE_STATE.WAITING;
    this.startsAt = null;

    if (error?.code === 'insufficient_chips' && error.userId) {
      const seat = this.findSeat(error.userId);
      if (seat) {
        // Whatever the seat thought, the account cannot cover the boot.
        seat.chips = Math.min(seat.chips, this.config.bootAmount - 1);
        this._kick(seat, 'insufficient_chips', "You don't have enough coins to remain in this table");
      }
    } else if (!this._destroyed) {
      // The database was unavailable or refused for another reason: try again
      // shortly rather than leaving a full table waiting forever.
      this._startTimer = this.timers.setTimeout(() => {
        this._startTimer = null;
        return this._run(() => {
          this._maybeStart();
        });
      }, this.config.nextHandDelayMs);
    }

    this.emit('state', this);
    return null;
  }

  // ------------------------------------------------------------- turn flow

  _seatsInOrder() {
    return this.seats.map((seat, index) => index).filter((index) => this.seats[index]);
  }

  _nextOccupiedSeat(fromSeat, pool) {
    const allowed = new Set(pool.map((seat) => seat.seatIndex));
    for (let step = 1; step <= this.seats.length; step += 1) {
      const index = (fromSeat + step + this.seats.length) % this.seats.length;
      if (allowed.has(index)) return index;
    }
    return pool[0]?.seatIndex ?? -1;
  }

  /**
   * The active player on this seat's right.
   *
   * Play moves clockwise — to the left — so the player on your right is the
   * one who acted immediately before you. That is who a sideshow is asked of.
   */
  _rightActiveSeat(fromSeat) {
    for (let step = 1; step <= this.seats.length; step += 1) {
      const index = (fromSeat - step + this.seats.length * 2) % this.seats.length;
      const seat = this.seats[index];
      if (seat && seat.status === SEAT_STATE.ACTIVE && index !== fromSeat) return index;
    }
    return -1;
  }

  /**
   * Why this seat may not ask for a sideshow right now, or null if it may.
   *
   * Returned as a reason rather than a boolean so the same check can gate the
   * button in the client and refuse the action on the server, and say the same
   * thing in both places.
   */
  sideshowBlockedReason(seat) {
    if (!this.hand) return 'no_hand';
    if (seat.status !== SEAT_STATE.ACTIVE) return 'not_in_hand';
    if (this.hand.turnSeat !== seat.seatIndex) return 'not_your_turn';
    if (this.hand.sideshow) return 'sideshow_pending';

    // One ask per turn. Wanting another means waiting for the next one.
    if (seat.sideshowAskedThisTurn) return 'already_asked';

    if (this.activeSeats.length < this.config.sideshowMinPlayers) return 'too_few_players';

    // Both hands have to have been looked at: comparing cards nobody has seen
    // is not a decision, it is a coin toss.
    if (seat.isBlind) return 'you_are_blind';

    const rightIndex = this._rightActiveSeat(seat.seatIndex);
    if (rightIndex === -1) return 'no_neighbour';
    if (this.seats[rightIndex].isBlind) return 'neighbour_is_blind';

    return null;
  }

  /** Next seat still betting, clockwise from `fromSeat`. Returns -1 if none. */
  _nextActiveSeat(fromSeat) {
    for (let step = 1; step <= this.seats.length; step += 1) {
      const index = (fromSeat + step + this.seats.length) % this.seats.length;
      const seat = this.seats[index];
      if (seat && seat.status === SEAT_STATE.ACTIVE) return index;
    }
    return -1;
  }

  get activeSeats() {
    return this.occupiedSeats.filter((seat) => seat.status === SEAT_STATE.ACTIVE);
  }

  /**
   * @param {object} [options]
   * @param {boolean} [options.freshTurn]
   *   False when the same player is simply getting their clock back — after a
   *   sideshow they asked for, say. Their one ask has been used, and handing it
   *   back would let them ask again in the same turn.
   */
  _setTurn(seatIndex, { freshTurn = true } = {}) {
    if (seatIndex < 0) return;
    this.hand.turnSeat = seatIndex;
    const seat = this.seats[seatIndex];
    if (freshTurn) seat.sideshowAskedThisTurn = false;
    const deadline = Date.now() + this.config.turnTimeoutMs;
    this.hand.turnDeadline = deadline;

    // Names this particular turn. The timeout that is armed below carries it,
    // so a timeout that fires late — queued behind a bet that was already on
    // its way to the database — is recognised as stale and ignored.
    const token = uuid();
    this.hand.turnToken = token;

    this.emit('turn', {
      userId: seat.userId,
      seatIndex,
      deadline,
      timeoutMs: this.config.turnTimeoutMs,
      options: this.turnOptions(seat),
    });

    this._clearTurnTimer();
    this._turnTimer = this.timers.setTimeout(() => {
      this._turnTimer = null;
      return this._run(() => this._onTurnTimeout(seatIndex, token));
    }, this.config.turnTimeoutMs);
  }

  _clearTurnTimer() {
    if (this._turnTimer) {
      this.timers.clearTimeout(this._turnTimer);
      this._turnTimer = null;
    }
  }

  /**
   * Requirement 6d: a player who does not act within the turn window is packed
   * and play continues without them.
   */
  async _onTurnTimeout(seatIndex, token) {
    const seat = this.seats[seatIndex];
    if (!this.hand || !seat || this.hand.turnSeat !== seatIndex) return;
    if (token && this.hand.turnToken !== token) return;
    if (seat.status !== SEAT_STATE.ACTIVE) return;

    seat.missedTurns += 1;
    await this._pack(seat, 'timeout');

    // Requirement 31: somebody who has stopped playing is holding up everyone
    // else, a whole turn clock at a time. After three in a row the seat is
    // given back to the table.
    if (seat.missedTurns >= this.config.maxMissedTurns) {
      this._kick(seat, 'idle', `Left the table after ${seat.missedTurns} missed turns`);
    }
  }

  /**
   * Asks for a player to be shown out, and says why.
   *
   * The table cannot do the removing itself: which room a player belongs to is
   * the room manager's business, and it has to update its own book-keeping and
   * tell the player. So this announces the decision and lets that happen.
   */
  _kick(seat, reason, message) {
    this.emit('kick', {
      userId: seat.userId,
      displayName: seat.displayName,
      reason,
      message,
    });
  }

  /**
   * Requirements 31 and 32: shows out anyone who can no longer cover the boot.
   *
   * Only ever called between hands. Mid-hand a player who has bet everything
   * is legitimately down to nothing, and throwing them out would take their
   * stake with them.
   */
  _sweepUnfunded() {
    if (this.hand) return;

    for (const seat of this.occupiedSeats) {
      if (seat.chips >= this.config.bootAmount) continue;
      // The removal a kick asks for is queued behind whatever is running, so
      // a second sweep before it lands would ask again. Once is enough.
      if (seat.kickPending) continue;
      seat.kickPending = true;
      this._kick(
        seat,
        'insufficient_chips',
        "You don't have enough coins to remain in this table",
      );
    }
  }

  async _advanceTurn(fromSeat) {
    if (!this.hand) return;

    const next = this._nextActiveSeat(fromSeat);
    if (next === -1) return;

    // Requirement 22: once no further bet can fit under the pot cap, everyone
    // still in shows and the best hand takes it.
    if (this._potCapReached()) {
      this._clearTurnTimer();
      await this._resolveShowdown(this.activeSeats, WIN_REASON.POT_LIMIT, null);
      return;
    }

    // A betting round completes whenever the turn steps over the seat that
    // opened the hand. Measuring by distance (rather than landing exactly on
    // that seat) keeps the count right after the opener packs or leaves.
    const toNext = this._distance(fromSeat, next);
    const toStart = this._distance(fromSeat, this.hand.startSeat);
    if (toStart > 0 && toStart <= toNext) {
      this.hand.round += 1;
      // A round cap of 0 is a blind table's: the turn goes round for as long
      // as the players keep it going.
      const roundCap = this.config.maxBetRounds ?? 0;
      if (roundCap > 0 && this.hand.round >= roundCap) {
        await this._forcedShowdown();
        return;
      }
    }

    this._setTurn(next);
    this.emit('state', this);
  }

  /**
   * True when the pot has reached the table's cap, or is close enough that not
   * even the smallest legal bet would fit underneath it. Checking the headroom
   * rather than only equality avoids leaving a player on turn with nothing to
   * do but fold.
   */
  _potCapReached() {
    if (!this.maxPot || !this.hand) return false;
    return this.hand.pot + this.hand.stake > this.maxPot;
  }

  _distance(from, to) {
    return (to - from + this.seats.length) % this.seats.length;
  }

  // ------------------------------------------------------------ betting math

  /**
   * The amounts a seat may bet on its turn.
   *
   * A blind player stakes the current unit; a seen player always pays double a
   * blind (that is the standard Teen Patti handicap for having looked). From
   * that base the ladder doubles on each rung — base, 2x, 4x, 8x … — which is
   * what the client's "+" and "−" buttons step through.
   *
   * The ladder is truncated by whichever bites first: the pot limit, or the
   * player's own chip stack. A player can therefore never be offered, or send,
   * a bet larger than they hold.
   */
  betOptions(seat) {
    const unit = this.hand.stake;
    const base = seat.isBlind ? unit : unit * 2;
    // Not the pot cap — the largest a single bet may be (a multiple of the
    // boot). A multiplier of 0 means there is none, and only the player's own
    // stack bounds the bet — a blind table's rule.
    const multiplier = this.config.potLimitMultiplier ?? 1024;
    const perBetCeiling = multiplier > 0
      ? this.config.bootAmount * multiplier
      : Number.POSITIVE_INFINITY;
    const ceiling = Math.min(perBetCeiling, seat.chips);

    // Likewise 0 rungs means the ladder is as long as the stack allows.
    const configuredSteps = this.config.maxRaiseSteps ?? 8;
    const maxSteps = configuredSteps > 0 ? configuredSteps : Number.POSITIVE_INFINITY;
    // Requirement 22: a private table's pot is capped, so a bet that would push
    // it past the ceiling is not offered at all. Headroom is Infinity when the
    // table has no cap.
    const headroom = this.maxPot ? this.maxPot - this.hand.pot : Number.POSITIVE_INFINITY;

    const steps = [];
    let amount = Math.min(base, perBetCeiling);
    while (amount <= ceiling && amount <= headroom && steps.length < maxSteps) {
      steps.push(amount);
      amount *= 2;
    }

    return {
      /** Every legal bet, ascending. Empty when the player cannot afford the base. */
      steps,
      /** "Same amount" — the minimum legal bet. */
      chaal: steps[0] ?? null,
      /** "Double" — the first rung the "+" button reaches. */
      raise: steps[1] ?? null,
      /** The largest bet this player can make right now. */
      max: steps.length > 0 ? steps[steps.length - 1] : null,
    };
  }

  /** Cost of calling a show, using the same handicap as a chaal. */
  showCost(seat) {
    const { chaal } = this.betOptions(seat);
    return chaal;
  }

  turnOptions(seat) {
    const { chaal, raise, steps, max } = this.betOptions(seat);
    const twoLeft = this.activeSeats.length === 2;
    const show = twoLeft ? this.showCost(seat) : null;

    const sideshowBlocked = this.sideshowBlockedReason(seat);
    const rightIndex = sideshowBlocked ? -1 : this._rightActiveSeat(seat.seatIndex);

    return {
      canSee: seat.isBlind,
      /** Requirement: ask the player on your right to compare, privately. */
      canSideshow: sideshowBlocked === null,
      sideshowWith: rightIndex === -1 ? null : this.seats[rightIndex].displayName,
      chaal,
      raise,
      /** The full +/− ladder, so the client never has to compute an amount. */
      raiseSteps: steps,
      maxBet: max,
      show: show !== null && seat.chips >= show ? show : null,
      canPack: true,
      isBlind: seat.isBlind,
      currentStake: this.hand.stake,
      chips: seat.chips,
      pot: this.hand.pot,
    };
  }

  /**
   * Moves chips from a seat into the pot: the database transaction first, the
   * table's own figures only after it has committed.
   *
   * Returns the balance the database reports, which the seat adopts. Throws a
   * GameError — and changes nothing — when the write is refused.
   */
  async _chargeToPot(seat, amount, { actionId, reason }) {
    const version = this.version + 1;
    let result;
    try {
      result = await this.ledger.bet({
        userId: seat.userId,
        amount,
        roomId: this.id,
        handId: this.hand.id,
        actionId: actionId ?? uuid(),
        reason,
        balanceBefore: seat.chips,
        version,
        state: this._snapshotAfterBet(seat, amount),
      });
    } catch (error) {
      this.emit('persistError', { userId: seat.userId, delta: -amount, reason, error });
      throw this._refusal(error);
    }
    this.version = version;

    const balance = Number.isFinite(result?.balance) ? result.balance : seat.chips - amount;
    // How much of this bet the account has actually been debited. The real
    // ledger banks all of it; a bookless test ledger banks none, and then
    // settlement carries the whole net.
    const persisted = Number.isFinite(result?.persisted) ? result.persisted : amount;
    seat.chips = balance;
    seat.contributed += amount;
    this.hand.pot += amount;

    const existing = this.hand.contributions.get(seat.userId);
    if (existing) {
      existing.contributed = seat.contributed;
      existing.persisted += persisted;
    } else {
      this.hand.contributions.set(seat.userId, {
        userId: seat.userId,
        displayName: seat.displayName,
        seatIndex: seat.seatIndex,
        contributed: seat.contributed,
        status: seat.status,
        sawCards: !seat.isBlind,
        cards: seat.cards,
        didChaal: false,
        leftMidHand: false,
        persisted,
      });
    }
    return balance;
  }

  /** The GameError a player is told when the database refused their move. */
  _refusal(error) {
    switch (error?.code) {
      case 'insufficient_chips':
        return new GameError('insufficient_chips', 'Not enough chips for that bet');
      case 'duplicate_action':
        return new GameError('duplicate_action', 'That move was already applied');
      default:
        return new GameError('persist_failed', 'The move could not be recorded, so nothing was changed');
    }
  }

  /** Copies a seat's live values onto its hand contribution record. */
  _syncContribution(seat, status = seat.status) {
    const entry = this.hand?.contributions.get(seat.userId);
    if (!entry) return;
    entry.contributed = seat.contributed;
    entry.status = status;
    entry.sawCards = !seat.isBlind;
    entry.cards = seat.cards;
  }

  // ---------------------------------------------------------------- actions

  /**
   * Applies a player action. Rejects with `GameError` for anything the client
   * should be told about (wrong turn, unaffordable bet, illegal show, a write
   * the database refused).
   *
   * `payload.actionId` is the client's own id for the move. It is written with
   * the ledger row and is unique there, so a request the client repeats — a
   * retry after a dropped ack, say — is refused instead of charged twice.
   */
  act(userId, action, payload = {}) {
    return this._run(() => this._act(userId, action, payload));
  }

  async _act(userId, action, payload) {
    if (!this.hand) throw new GameError('no_hand', 'No hand is in progress');

    const seat = this.findSeat(userId);
    if (!seat) throw new GameError('not_seated', 'You are not at this table');
    if (seat.status !== SEAT_STATE.ACTIVE) throw new GameError('not_in_hand', 'You are not in this hand');

    // Seeing your own cards is not a move: it costs nothing, changes nothing
    // for anyone else, and a player may look whenever they like. Everything
    // that does change the hand still waits for their turn.
    if (action !== ACTION.SEE && this.hand.turnSeat !== seat.seatIndex) {
      throw new GameError('not_your_turn', 'It is not your turn');
    }

    let result;
    switch (action) {
      case ACTION.SEE:
        result = this._see(seat);
        break;
      case ACTION.CHAAL:
        result = await this._bet(seat, 'chaal', payload.amount, payload.actionId);
        break;
      case ACTION.RAISE:
        result = await this._bet(seat, 'raise', payload.amount, payload.actionId);
        break;
      case ACTION.PACK:
        result = await this._pack(seat, 'pack');
        break;
      case ACTION.SHOW:
        result = await this._show(seat, payload.actionId);
        break;
      case ACTION.SIDESHOW:
        result = this._requestSideshow(seat);
        break;
      default:
        throw new GameError('unknown_action', `Unknown action "${action}"`);
    }

    // They are here and playing, so whatever they had missed before does not
    // count against them any more. Cleared only once the move went through.
    seat.missedTurns = 0;
    return result;
  }

  /**
   * Reveals the player's own cards to them. Free, and deliberately does not end
   * the turn — the turn timer keeps running, so seeing costs thinking time.
   */
  _see(seat, { auto = false } = {}) {
    if (!seat.isBlind) throw new GameError('already_seen', 'You have already seen your cards');
    seat.isBlind = false;
    this._syncContribution(seat);

    this.emit('cards', { userId: seat.userId, cards: seat.cards.map(cardCode) });
    this.emit('action', {
      userId: seat.userId,
      action: ACTION.SEE,
      amount: 0,
      auto,
      pot: this.hand.pot,
      stake: this.hand.stake,
    });

    // Re-issue the turn so the client picks up the seen player's bet ladder,
    // which is double the blind one. Only when it really is their turn: a
    // player may look at any point now, and the automatic reveal happens as
    // their turn is ending, so in both of those cases telling the table it is
    // their turn would be a lie.
    if (!auto && this.hand.turnSeat === seat.seatIndex) {
      this.emit('turn', {
        userId: seat.userId,
        seatIndex: seat.seatIndex,
        deadline: this.hand.turnDeadline,
        timeoutMs: Math.max(0, this.hand.turnDeadline - Date.now()),
        options: this.turnOptions(seat),
      });
    }

    this.emit('state', this);
    return { action: ACTION.SEE, auto };
  }

  /**
   * Places a bet.
   *
   * `requested` is the amount the client picked with the +/− stepper. It is
   * never trusted: the ladder is recomputed here and the amount must be one of
   * its rungs, which is what stops a tampered client betting an arbitrary
   * figure or more than it holds. Omitting it takes the default for the kind,
   * so a plain "chaal" or "raise" still works.
   *
   * Validation happens first and costs nothing; then the chips move in the
   * database; then, and only then, the table's own state follows.
   */
  async _bet(seat, kind, requested, actionId) {
    const options = this.betOptions(seat);

    if (options.steps.length === 0) {
      throw new GameError('insufficient_chips', 'Not enough chips to bet');
    }

    let amount;
    if (requested === undefined || requested === null) {
      amount = options[kind];
    } else {
      if (!Number.isInteger(requested)) {
        throw new GameError('invalid_bet', 'Bet amount must be a whole number');
      }
      if (!options.steps.includes(requested)) {
        throw new GameError('invalid_bet', 'That bet amount is not available');
      }
      // A "raise" has to actually raise; the base rung is a chaal.
      if (kind === 'raise' && requested < options.steps[0] * 2) {
        throw new GameError('invalid_bet', 'A raise must be at least double the chaal');
      }
      amount = requested;
    }

    if (!amount || amount <= 0) throw new GameError('invalid_bet', 'That bet is not available');
    if (seat.chips < amount) throw new GameError('insufficient_chips', 'Not enough chips for that bet');

    await this._chargeToPot(seat, amount, { actionId, reason: 'bet' });

    // What this player just did, so the table can show it rather than only the
    // running total. Kept on the seat rather than inferred from the action
    // stream, so it survives a reconnect and is there for a late joiner.
    seat.lastBet = amount;
    seat.lastAction = kind === 'raise' ? ACTION.RAISE : ACTION.CHAAL;

    // Requirement 16: a hand only counts as played once chips go in beyond the
    // boot, so record that here rather than at the deal.
    const entry = this.hand.contributions.get(seat.userId);
    if (entry) entry.didChaal = true;

    // The stake is always expressed as a blind unit, so halve a seen player's bet.
    this.hand.stake = seat.isBlind ? amount : Math.floor(amount / 2);

    this.emit('action', {
      userId: seat.userId,
      action: kind === 'raise' ? ACTION.RAISE : ACTION.CHAAL,
      amount,
      pot: this.hand.pot,
      stake: this.hand.stake,
    });

    // A player gets a limited number of bets while blind; on the last one the
    // cards turn face up by themselves, so nobody plays a whole hand unseen.
    // The bet above was still a blind one — the reveal follows it.
    let autoSeen = false;
    if (seat.isBlind) {
      seat.blindMoves += 1;
      if (seat.blindMoves >= this.config.maxBlindMoves) {
        this._see(seat, { auto: true });
        autoSeen = true;
      }
    }

    this._clearTurnTimer();
    await this._advanceTurn(seat.seatIndex);
    this.emit('state', this);
    return { action: kind, amount, autoSeen };
  }

  /**
   * @param {object} [options]
   * @param {boolean} [options.advanceTurn]
   *   False when the packed player was not the one on turn — a sideshow they
   *   lost, for instance. The turn never left whoever holds it, so moving it
   *   on would skip them.
   */
  async _pack(seat, reason, { advanceTurn = true } = {}) {
    seat.status = SEAT_STATE.PACKED;
    seat.lastAction = ACTION.PACK;
    this.hand.packedUserIds.add(seat.userId);
    this._syncContribution(seat, SEAT_STATE.PACKED);

    this.emit('action', {
      userId: seat.userId,
      action: ACTION.PACK,
      amount: 0,
      pot: this.hand.pot,
      stake: this.hand.stake,
      reason,
    });

    this._clearTurnTimer();

    if (await this._resolveIfOnlyOneLeft()) return { action: ACTION.PACK, reason };

    if (advanceTurn) await this._advanceTurn(seat.seatIndex);
    this.emit('state', this);
    return { action: ACTION.PACK, reason };
  }

  /** Requirement 6e/6f: last player standing takes the whole pot, no reveal. */
  async _resolveIfOnlyOneLeft() {
    const active = this.activeSeats;
    if (active.length > 1) return false;

    if (active.length === 1) {
      await this._endHand({ winnerId: active[0].userId, reason: WIN_REASON.LAST_STANDING, reveals: [] });
    } else {
      // Requirement 15: everybody walked out, so the pot goes to whoever left
      // last rather than evaporating. They are no longer seated, which is why
      // the hand is settled by user id rather than by seat.
      await this._endHand({
        winnerId: this.hand.lastDeparture,
        reason: WIN_REASON.ALL_LEFT,
        reveals: [],
      });
    }
    return true;
  }

  /**
   * Asks the player on the right to compare hands privately.
   *
   * Nothing is decided here — it is a request, and it stands for a few seconds
   * until they answer or the clock runs out. The turn clock is stopped for the
   * duration: the player asking should not lose their turn while waiting for
   * somebody else to press a button.
   */
  _requestSideshow(seat) {
    const blocked = this.sideshowBlockedReason(seat);
    if (blocked) {
      const messages = {
        sideshow_pending: 'A sideshow is already in progress',
        already_asked: 'You have already asked for a sideshow this turn',
        too_few_players: `A sideshow needs at least ${this.config.sideshowMinPlayers} players in the hand`,
        you_are_blind: 'See your cards before asking for a sideshow',
        neighbour_is_blind: 'The player on your right has not seen their cards',
        no_neighbour: 'There is nobody on your right to ask',
      };
      throw new GameError(blocked, messages[blocked] ?? 'You cannot ask for a sideshow now');
    }

    const target = this.seats[this._rightActiveSeat(seat.seatIndex)];
    seat.sideshowAskedThisTurn = true;

    // The turn clock stops while the request stands, and is restarted from
    // full when it resolves.
    this._clearTurnTimer();

    const expiresAt = Date.now() + this.config.sideshowTimeoutMs;
    this.hand.sideshow = {
      fromUserId: seat.userId,
      fromSeat: seat.seatIndex,
      toUserId: target.userId,
      toSeat: target.seatIndex,
      expiresAt,
      timer: this.timers.setTimeout(
        () => this._run(() => this._resolveSideshow(false, 'timeout')),
        this.config.sideshowTimeoutMs,
      ),
    };

    // Everyone sees that it was asked — that is public — but not the cards.
    this.emit('sideshowRequested', {
      fromUserId: seat.userId,
      fromName: seat.displayName,
      fromSeat: seat.seatIndex,
      toUserId: target.userId,
      toName: target.displayName,
      toSeat: target.seatIndex,
      expiresAt,
      timeoutMs: this.config.sideshowTimeoutMs,
    });

    this.emit('state', this);
    return { action: ACTION.SIDESHOW, toUserId: target.userId };
  }

  /** The asked player's answer. Only they may give it. */
  respondToSideshow(userId, accept) {
    return this._run(() => {
      const pending = this.hand?.sideshow;
      if (!pending) throw new GameError('no_sideshow', 'There is no sideshow to answer');
      if (pending.toUserId !== userId) {
        throw new GameError('not_your_sideshow', 'That sideshow was not asked of you');
      }
      return this._resolveSideshow(Boolean(accept), accept ? 'accepted' : 'declined');
    });
  }

  /**
   * Settles a sideshow.
   *
   * On a refusal nothing changes but the clock. On an acceptance the two hands
   * are compared and the weaker one packs — the asker loses a tie, which is
   * the usual rule and stops asking being free.
   *
   * The cards go only to the two of them. Everyone else is told that it
   * happened and who packed, which is what they would see at a real table.
   */
  async _resolveSideshow(accepted, reason) {
    const pending = this.hand?.sideshow;
    if (!pending) return null;

    if (pending.timer) this.timers.clearTimeout(pending.timer);
    this.hand.sideshow = null;

    const asker = this.findSeat(pending.fromUserId);
    const asked = this.findSeat(pending.toUserId);

    let packedUserId = null;

    const bothInHand = asker?.status === SEAT_STATE.ACTIVE && asked?.status === SEAT_STATE.ACTIVE;

    if (accepted && bothInHand) {
      const a = evaluate(asker.cards);
      const b = evaluate(asked.cards);
      // A tie goes against the player who asked.
      const loser = compare(a, b) > 0 ? asked : asker;
      packedUserId = loser.userId;

      // Only the two of them ever see these cards.
      const reveal = {
        reason,
        packedUserId,
        hands: [
          {
            userId: asker.userId,
            displayName: asker.displayName,
            cards: asker.cards.map(cardCode),
            handName: a.name,
          },
          {
            userId: asked.userId,
            displayName: asked.displayName,
            cards: asked.cards.map(cardCode),
            handName: b.name,
          },
        ],
      };
      this.emit('sideshowReveal', { userIds: [asker.userId, asked.userId], reveal });

      // Only the asker holds the turn, so only their packing moves it on.
      await this._pack(loser, 'sideshow', { advanceTurn: loser === asker });
    }

    this.emit('sideshowResolved', {
      fromUserId: pending.fromUserId,
      toUserId: pending.toUserId,
      accepted,
      reason,
      packedUserId,
    });

    // The hand may have ended with that pack; if it is still running, the
    // asker gets their turn back with a full clock.
    if (this.hand && this.hand.turnSeat === pending.fromSeat && asker
        && asker.status === SEAT_STATE.ACTIVE) {
      this._setTurn(pending.fromSeat, { freshTurn: false });
    }

    this.emit('state', this);
    return { accepted, packedUserId };
  }

  async _show(seat, actionId) {
    const active = this.activeSeats;
    if (active.length !== 2) throw new GameError('show_unavailable', 'A show needs exactly two players left');

    const cost = this.showCost(seat);
    // A show is paid for. No affordable chaal means no show either — never a
    // free look at the other hand.
    if (cost === null || seat.chips < cost) {
      throw new GameError('insufficient_chips', 'Not enough chips to pay for the show');
    }

    await this._chargeToPot(seat, cost, { actionId, reason: 'show' });
    this.hand.showRequestedBy = seat.userId;

    // Paying for a show commits chips beyond the boot, so it counts as having
    // played the hand just as a chaal does (requirement 16).
    const entry = this.hand.contributions.get(seat.userId);
    if (entry) entry.didChaal = true;

    this.emit('action', {
      userId: seat.userId,
      action: ACTION.SHOW,
      amount: cost,
      pot: this.hand.pot,
      stake: this.hand.stake,
    });

    this._clearTurnTimer();
    await this._resolveShowdown(active, WIN_REASON.SHOW, seat.userId);
    return { action: ACTION.SHOW, amount: cost };
  }

  /** Round cap reached: everyone still in reveals and the best hand takes it. */
  async _forcedShowdown() {
    this._clearTurnTimer();
    await this._resolveShowdown(this.activeSeats, WIN_REASON.FORCED_SHOWDOWN, null);
  }

  /**
   * Compares hands and ends the hand.
   *
   * Exact ties go to the player who did *not* pay for the show; in a forced
   * showdown they go to the seat nearest the dealer's left. Only one player
   * ever wins — the pot is never split (requirement 6e).
   */
  async _resolveShowdown(contenders, reason, showRequestedBy) {
    this.state = TABLE_STATE.SHOWDOWN;

    const scored = contenders.map((seat) => ({ seat, hand: evaluate(seat.cards) }));

    // Preference order for exact ties.
    const preference = [...contenders]
      .sort((a, b) => this._distance(this.dealerSeat, a.seatIndex) - this._distance(this.dealerSeat, b.seatIndex))
      .map((seat) => seat.userId)
      .filter((userId) => userId !== showRequestedBy);
    if (showRequestedBy) preference.push(showRequestedBy);

    let best = scored[0];
    let tied = [best];
    for (const candidate of scored.slice(1)) {
      const diff = compare(candidate.hand, best.hand);
      if (diff > 0) {
        best = candidate;
        tied = [candidate];
      } else if (diff === 0) {
        tied.push(candidate);
      }
    }
    if (tied.length > 1) {
      tied.sort((a, b) => preference.indexOf(a.seat.userId) - preference.indexOf(b.seat.userId));
      best = tied[0];
    }

    const reveals = scored.map(({ seat, hand }) => ({
      userId: seat.userId,
      seatIndex: seat.seatIndex,
      cards: hand.cards,
      handName: hand.name,
      category: hand.category,
      won: seat.userId === best.seat.userId,
    }));

    this.emit('showdown', { reveals, reason });

    for (const { seat } of scored) {
      if (seat.userId !== best.seat.userId) {
        seat.status = SEAT_STATE.LOST;
        this._syncContribution(seat, SEAT_STATE.LOST);
      }
    }

    await this._endHand({ winnerId: best.seat.userId, reason, reveals });
  }

  // ------------------------------------------------------------- hand end

  /**
   * Ends the hand and settles it.
   *
   * The winner is identified by user id, not by seat: when everyone abandons a
   * hand the pot goes to the last player who left, and they no longer have one.
   *
   * Every stake was already banked as it was bet, so settlement's one chip
   * movement is the pot to the winner. It is written in one transaction with
   * the hand record and the counters; if that write fails the table keeps
   * playing on its own books and retries the write in the background until the
   * database takes it.
   */
  async _endHand({ winnerId, reason, reveals }) {
    const hand = this.hand;
    if (!hand) return;

    this._clearTurnTimer();
    if (hand.sideshow?.timer) this.timers.clearTimeout(hand.sideshow.timer);
    hand.sideshow = null;
    hand.endedAt = Date.now();

    const winnerSeat = winnerId ? this.findSeat(winnerId) : null;
    if (winnerSeat) {
      winnerSeat.status = SEAT_STATE.WON;
      this._syncContribution(winnerSeat, SEAT_STATE.WON);
    } else if (winnerId) {
      // The winner has already left; mark their contribution record instead.
      const entry = hand.contributions.get(winnerId);
      if (entry) entry.status = SEAT_STATE.WON;
    }

    // Everyone who put chips in this hand, including players who have since
    // left the table — their stake still has to be settled and audited.
    const contributors = [...hand.contributions.values()].filter((entry) => entry.contributed > 0);

    // With no winner (every player vanished mid-hand) the pot is void and each
    // contribution is returned rather than quietly destroyed.
    const entries = contributors.map((entry) => {
      const isWinner = entry.userId === winnerId;

      // What this hand costs or pays this player overall...
      let net = 0;
      if (winnerId) net = isWinner ? hand.pot - entry.contributed : -entry.contributed;

      // ...less whatever was already taken from their account as they bet. A
      // loser who has been banked all the way owes nothing further; a winner is
      // paid the whole pot; and with no winner at all, a banked contribution is
      // handed back.
      const delta = net + entry.persisted;

      return {
        userId: entry.userId,
        delta,
        isWinner,
        // Requirement 16: these drive the played / lost / abandoned counters.
        didChaal: Boolean(entry.didChaal),
        leftMidHand: Boolean(entry.leftMidHand),
      };
    });

    const revealed = new Set(reveals.map((reveal) => reveal.userId));
    const summary = contributors.map((entry) => ({
      userId: entry.userId,
      displayName: entry.displayName,
      seatIndex: entry.seatIndex,
      contributed: entry.contributed,
      status: entry.status,
      sawCards: entry.sawCards,
      cards: revealed.has(entry.userId) ? entry.cards.map(cardCode) : null,
    }));

    const record = {
      id: hand.id,
      roomId: this.id,
      handNo: hand.handNo,
      pot: hand.pot,
      winnerId: winnerId ?? null,
      winReason: reason,
      bootAmount: this.config.bootAmount,
      startedAt: hand.startedAt,
      endedAt: hand.endedAt,
      summary,
    };

    // The hand is over whatever the database says next; the snapshot it is
    // saved with shows the table back at rest.
    const version = this.version + 1;
    const state = this._snapshot({ hand: null, stateOverride: TABLE_STATE.WAITING });

    let balances = {};
    let settledInDb = false;
    try {
      balances = (await this.ledger.settle({ hand: record, entries, version, state })) ?? {};
      this.version = version;
      settledInDb = true;
    } catch (error) {
      this.emit('persistError', { reason: 'settle', handId: hand.id, error });
    }

    for (const [userId, balance] of Object.entries(balances)) {
      const seat = this.findSeat(userId);
      if (seat) seat.chips = balance;
    }

    // Settlement failed (or did not cover the winner): keep the in-memory books
    // consistent so play can continue. Tested by key presence, not truthiness —
    // a settled balance of exactly 0 is a valid result, not a missing one.
    if (winnerSeat && !Object.prototype.hasOwnProperty.call(balances, winnerSeat.userId)) {
      winnerSeat.chips += hand.pot;
    }

    if (!settledInDb) {
      // The winner has not been paid in the database yet. Keep trying — the
      // write is idempotent (hand id, per-player action ids), so a late success
      // pays exactly once.
      this._retrySettle({ hand: record, entries, version, state }, 1);
    }

    const winnerName = winnerSeat?.displayName
      ?? (winnerId ? hand.contributions.get(winnerId)?.displayName : null)
      ?? null;

    this.hand = null;
    this.state = TABLE_STATE.WAITING;

    const nextHandAt = Date.now() + this.config.nextHandDelayMs;
    this.emit('handEnded', {
      handId: record.id,
      handNo: record.handNo,
      winnerId: record.winnerId,
      winnerName,
      pot: record.pot,
      reason,
      reveals,
      summary,
      nextHandAt,
    });

    this.emit('state', this);
    this._maybeStart();
  }

  /**
   * Re-attempts a settlement the database refused. Backs off a little more
   * each time and gives up, loudly, after ten tries.
   */
  _retrySettle(args, attempt) {
    if (this._destroyed) return;
    const maxAttempts = 10;
    if (attempt > maxAttempts) {
      const error = new Error(`settlement of hand ${args.hand.id} failed after ${maxAttempts} attempts`);
      if (this.listenerCount('error') > 0) this.emit('error', error);
      else this.emit('persistError', { reason: 'settle_abandoned', handId: args.hand.id, error });
      return;
    }

    const delay = Math.min(30_000, this.config.nextHandDelayMs * attempt);
    this.timers.setTimeout(async () => {
      if (this._destroyed) return;
      try {
        // The version has moved on with later hands; present the current one
        // so the snapshot check still describes "newer than stored".
        const version = this.version + 1;
        const balances = (await this.ledger.settle({ ...args, version })) ?? {};
        this.version = version;
        for (const [userId, balance] of Object.entries(balances)) {
          const seat = this.findSeat(userId);
          // Only correct a seat that is not mid-hand; a live stake is in play.
          if (seat && seat.status !== SEAT_STATE.ACTIVE) seat.chips = balance;
        }
        this.emit('state', this);
      } catch (error) {
        this.emit('persistError', { reason: 'settle_retry', handId: args.hand.id, attempt, error });
        this._retrySettle(args, attempt + 1);
      }
    }, delay);
  }

  // ------------------------------------------------------------ snapshots

  /**
   * The table as the database should remember it: everything needed to audit
   * or rebuild a hand, cards included. Server-side only — never sent to a
   * client, which gets the redacted `serializeFor` instead.
   */
  _snapshot({ hand = this.hand, handNo = this.handNo, dealerSeat = this.dealerSeat, deals = null, participants = null, bootAmount = null, stateOverride = null } = {}) {
    const seats = this.seats.map((seat, index) => {
      if (!seat) return null;
      const dealt = deals && participants ? participants.indexOf(seat) : -1;
      const inNewHand = dealt >= 0;
      return {
        seatIndex: index,
        userId: seat.userId,
        displayName: seat.displayName,
        chips: inNewHand ? seat.chips - bootAmount : seat.chips,
        status: inNewHand ? SEAT_STATE.ACTIVE : seat.status,
        isBlind: inNewHand ? true : seat.isBlind,
        blindMoves: inNewHand ? 0 : seat.blindMoves,
        contributed: inNewHand ? bootAmount : seat.contributed,
        cards: (inNewHand ? deals[dealt] : seat.cards).map(cardCode),
      };
    });

    return {
      roomId: this.id,
      code: this.code,
      category: this.category,
      state: stateOverride ?? (hand ? TABLE_STATE.BETTING : this.state),
      handNo,
      dealerSeat,
      hand: hand
        ? {
            id: hand.id,
            handNo: hand.handNo,
            pot: hand.pot,
            stake: hand.stake,
            round: hand.round,
            turnSeat: hand.turnSeat,
            startSeat: hand.startSeat,
            startedAt: hand.startedAt,
            showRequestedBy: hand.showRequestedBy ?? null,
            contributions: [...hand.contributions.values()].map((entry) => ({
              userId: entry.userId,
              contributed: entry.contributed,
              persisted: entry.persisted,
              status: entry.status,
              didChaal: Boolean(entry.didChaal),
              leftMidHand: Boolean(entry.leftMidHand),
            })),
          }
        : null,
      seats,
    };
  }

  /** The snapshot as it will read once `seat` has put `amount` in the pot. */
  _snapshotAfterBet(seat, amount) {
    const snapshot = this._snapshot();
    if (snapshot.hand) snapshot.hand.pot += amount;
    const own = snapshot.seats[seat.seatIndex];
    if (own) {
      own.chips -= amount;
      own.contributed += amount;
    }
    const entry = snapshot.hand?.contributions.find((c) => c.userId === seat.userId);
    if (entry) {
      entry.contributed += amount;
      entry.persisted += amount;
    }
    return snapshot;
  }

  // ------------------------------------------------------------ serializing

  /**
   * Table snapshot for one viewer. Cards are only ever included for the viewer
   * themselves, and only once they have paid attention to them (seen), so a
   * tampered client cannot read anyone else's hand.
   */
  serializeFor(userId) {
    const viewer = this.findSeat(userId);

    // On a blind table another player's stack is never put on the wire, so it
    // cannot be read out of a tampered client. Your own is always sent.
    const hideOthersChips = this.category === TABLE_CATEGORY.BLIND;

    return {
      roomId: this.id,
      code: this.code,
      category: this.category,
      /** True when other players' stacks are hidden from this viewer. */
      chipsHidden: hideOthersChips,
      state: this.state,
      handNo: this.handNo,
      dealerSeat: this.dealerSeat,
      maxPlayers: this.config.maxPlayers,
      minPlayers: this.config.minPlayers,
      bootAmount: this.config.bootAmount,
      turnTimeoutMs: this.config.turnTimeoutMs,
      startsAt: this.startsAt ?? null,
      pot: this.hand?.pot ?? 0,
      /** The table's pot ceiling, or 0 when uncapped. */
      maxPot: this.maxPot,
      stake: this.hand?.stake ?? this.config.bootAmount,
      round: this.hand?.round ?? 0,
      /**
       * The sideshow currently awaiting an answer. Public — who asked whom and
       * how long is left, never the cards — so a client that reconnects
       * mid-request can put the prompt back up.
       */
      sideshow: this.hand?.sideshow
        ? {
            fromUserId: this.hand.sideshow.fromUserId,
            fromSeat: this.hand.sideshow.fromSeat,
            toUserId: this.hand.sideshow.toUserId,
            toSeat: this.hand.sideshow.toSeat,
            expiresAt: this.hand.sideshow.expiresAt,
          }
        : null,
      turn: this.hand
        ? {
            seatIndex: this.hand.turnSeat,
            userId: this.seats[this.hand.turnSeat]?.userId ?? null,
            deadline: this.hand.turnDeadline ?? null,
          }
        : null,
      you: viewer
        ? {
            seatIndex: viewer.seatIndex,
            chips: viewer.chips,
            status: viewer.status,
            isBlind: viewer.isBlind,
            /** Blind bets still allowed before the cards turn face up. */
            blindMovesLeft: viewer.isBlind
              ? Math.max(0, this.config.maxBlindMoves - viewer.blindMoves)
              : 0,
            contributed: viewer.contributed,
            /**
             * Requirement 31: turns auto-packed in a row, and how many the
             * table allows before the seat is given back. Sent only to the
             * player it concerns — it is a warning to them, not a tell for
             * everyone else about who is not paying attention.
             */
            missedTurns: viewer.missedTurns,
            maxMissedTurns: this.config.maxMissedTurns,
            cards: viewer.isBlind ? [] : viewer.cards.map(cardCode),
            options:
              this.hand && this.hand.turnSeat === viewer.seatIndex && viewer.status === SEAT_STATE.ACTIVE
                ? this.turnOptions(viewer)
                : null,
          }
        : null,
      seats: this.seats.map((seat, index) => {
        if (!seat) return { seatIndex: index, status: SEAT_STATE.EMPTY };

        const isViewer = seat.userId === userId;
        return {
          seatIndex: index,
          userId: seat.userId,
          displayName: seat.displayName,
          avatarUrl: seat.avatarUrl,
          // Null rather than 0, so the client shows "hidden" instead of "broke".
          chips: hideOthersChips && !isViewer ? null : seat.chips,
          status: seat.status,
          isBlind: seat.isBlind,
          // What a player has staked this hand stays public either way: bets
          // are announced as they happen, so hiding it here would fool nobody.
          // The same goes for the last one on its own.
          lastBet: seat.lastBet,
          lastAction: seat.lastAction,
          contributed: seat.contributed,
          connected: seat.connected,
          cardCount: seat.cards.length,
        };
      }),
    };
  }

  /** Lightweight row for the lobby list. */
  summary() {
    return {
      roomId: this.id,
      code: this.code,
      category: this.category,
      state: this.state,
      players: this.playerCount,
      maxPlayers: this.config.maxPlayers,
      bootAmount: this.config.bootAmount,
      pot: this.hand?.pot ?? 0,
    };
  }

  /**
   * Tears the table down.
   *
   * If a hand is still live its pot must not simply vanish (requirement 15):
   * it goes to whoever is still sitting, or failing that to the last player who
   * walked out. This is the path a server shutdown or an idle sweep takes,
   * since ordinary play always ends a hand before the room empties.
   */
  destroy() {
    return this._run(() => this._destroy());
  }

  async _destroy() {
    if (this.hand) {
      const remaining = this.activeSeats;
      const winnerId = remaining.length > 0 ? remaining[0].userId : this.hand.lastDeparture;
      await this._endHand({ winnerId, reason: WIN_REASON.ALL_LEFT, reveals: [] });
    }

    this._destroyed = true;
    this._clearTurnTimer();
    if (this._startTimer) {
      this.timers.clearTimeout(this._startTimer);
      this._startTimer = null;
    }
    // The room is gone, and so is its chat: history exists only for as long as
    // the room does, and is never written anywhere.
    this.chat.clear();
    this.removeAllListeners();
  }
}

export class GameError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'GameError';
    this.code = code;
  }
}

/**
 * A ledger that keeps no books of its own, for tables built without a database.
 *
 * It honours the two older hooks: `persistChips` is called for every boot and
 * bet (and a throw from it refuses the move, exactly as the database would),
 * and `settle` is called at the end of the hand and must return the post-hand
 * balances. With neither, chips simply live in the seats.
 */
export function memoryLedger({ settle, persistChips } = {}) {
  return {
    async bet({ userId, amount, roomId, handId, actionId, reason, balanceBefore }) {
      if (persistChips) {
        await persistChips({ userId, delta: -amount, reason, roomId, handId, actionId });
      }
      // With a persist hook the stake really left the account; without one,
      // nothing did, and settlement must move the whole net.
      return { balance: balanceBefore - amount, persisted: persistChips ? amount : 0 };
    },
    async collectBoot({ roomId, handId, entries }) {
      const balances = {};
      for (const entry of entries) {
        if (persistChips) {
          await persistChips({
            userId: entry.userId,
            delta: -entry.amount,
            reason: 'boot',
            roomId,
            handId,
            actionId: `${handId}:boot:${entry.userId}`,
          });
        }
        balances[entry.userId] = entry.balanceBefore - entry.amount;
      }
      return { balances, persisted: persistChips ? (entries[0]?.amount ?? 0) : 0 };
    },
    async settle({ hand, entries }) {
      if (!settle) return {};
      return (await settle({ hand, entries })) ?? {};
    },
  };
}

const defaultTimers = {
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (handle) => clearTimeout(handle),
};

export default Table;
