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
 * agnostic — it emits events and the socket layer forwards them. Nothing here
 * touches the database; persistence happens once per hand through the
 * `settle` callback the room manager injects.
 *
 * Events:
 *   'state'        (table)                      — something changed, re-broadcast
 *   'handStarted'  ({ handNo, dealerSeat, ... })
 *   'cards'        ({ userId, cards })          — private, send to that player only
 *   'turn'         ({ userId, seatIndex, deadline, options })
 *   'action'       ({ userId, action, amount, pot, stake })
 *   'showdown'     ({ reveals })
 *   'handEnded'    ({ winnerId, pot, reason, summary, nextHandAt })
 *   'seatUpdated'  ({ seatIndex })
 */
export class Table extends EventEmitter {
  constructor({ id, code, config, settle, timers = defaultTimers }) {
    super();
    this.id = id;
    this.code = code;
    this.config = config;
    this.settle = settle ?? (() => ({}));
    this.timers = timers;

    /**
     * "seen" — every player's chip stack is visible to everyone.
     * "blind" — you see only your own stack.
     * This is enforced in serializeFor, not in the client.
     */
    this.category = config.category === TABLE_CATEGORY.BLIND
      ? TABLE_CATEGORY.BLIND
      : TABLE_CATEGORY.SEEN;

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
    const seat = this.findSeat(userId);
    if (!seat) return null;

    const wasOnTurn = this.hand?.turnSeat === seat.seatIndex;
    const wasActive = seat.status === SEAT_STATE.ACTIVE;

    this.seats[seat.seatIndex] = null;
    this.emit('seatUpdated', { seatIndex: seat.seatIndex });
    this.emit('chat', this.chat.addSystem(`${seat.displayName} left the table`));

    if (wasActive && this.hand) {
      this.hand.packedUserIds.add(userId);
      seat.status = SEAT_STATE.PACKED;
      this._syncContribution(seat, SEAT_STATE.PACKED);
      this.emit('action', {
        userId,
        action: ACTION.PACK,
        amount: 0,
        pot: this.hand.pot,
        stake: this.hand.stake,
        reason,
      });
      if (this._resolveIfOnlyOneLeft()) return seat;
      if (wasOnTurn) {
        this._clearTurnTimer();
        this._advanceTurn(seat.seatIndex);
      }
    } else if (this.state === TABLE_STATE.STARTING && this._fundedSeats().length < this.config.minPlayers) {
      this._cancelStart();
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
    if (this._fundedSeats().length < this.config.minPlayers) return;

    this.state = TABLE_STATE.STARTING;
    this.startsAt = Date.now() + this.config.nextHandDelayMs;
    this.emit('state', this);

    this._startTimer = this.timers.setTimeout(() => {
      this._startTimer = null;
      this.startHand();
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

  startHand() {
    if (this._destroyed) return null;
    if (this.hand) return null;

    const participants = this._fundedSeats();
    if (participants.length < this.config.minPlayers) {
      this.state = TABLE_STATE.WAITING;
      this.startsAt = null;
      this.emit('state', this);
      return null;
    }

    this.handNo += 1;
    this.dealerSeat = this._nextOccupiedSeat(this.dealerSeat, participants);

    // Reset every seat, then deal into the funded ones.
    for (const seat of this.occupiedSeats) {
      seat.cards = [];
      seat.isBlind = true;
      seat.contributed = 0;
      seat.status = participants.includes(seat) ? SEAT_STATE.ACTIVE : SEAT_STATE.WAITING;
    }

    const { hands } = deal(participants.length);
    participants.forEach((seat, index) => {
      seat.cards = hands[index];
    });

    this.hand = {
      id: uuid(),
      handNo: this.handNo,
      startedAt: Date.now(),
      pot: 0,
      stake: this.config.bootAmount,
      round: 0,
      packedUserIds: new Set(),
      turnSeat: -1,
      startSeat: -1,
      seatOrder: participants.map((seat) => seat.seatIndex),
      showRequestedBy: null,
      // Keyed by userId and owned by the hand rather than the seat, so a player
      // who leaves mid-hand still has their stake settled and audited.
      contributions: new Map(),
    };

    // Boot (ante) from every participant.
    for (const seat of participants) {
      this._moveToPot(seat, this.config.bootAmount);
    }

    this.state = TABLE_STATE.BETTING;
    this.startsAt = null;

    this.emit('handStarted', {
      handId: this.hand.id,
      handNo: this.handNo,
      dealerSeat: this.dealerSeat,
      bootAmount: this.config.bootAmount,
      pot: this.hand.pot,
      stake: this.hand.stake,
      participants: participants.map((seat) => seat.userId),
    });

    // Play opens to the dealer's left and rotates clockwise from there.
    const firstSeat = this._nextActiveSeat(this.dealerSeat);
    this.hand.startSeat = firstSeat;
    this._setTurn(firstSeat);
    this.emit('state', this);
    return this.hand;
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

  _setTurn(seatIndex) {
    if (seatIndex < 0) return;
    this.hand.turnSeat = seatIndex;
    const seat = this.seats[seatIndex];
    const deadline = Date.now() + this.config.turnTimeoutMs;
    this.hand.turnDeadline = deadline;
    this.hand.turnToken = uuid();

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
      this._onTurnTimeout(seatIndex);
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
  _onTurnTimeout(seatIndex) {
    const seat = this.seats[seatIndex];
    if (!this.hand || !seat || this.hand.turnSeat !== seatIndex) return;
    if (seat.status !== SEAT_STATE.ACTIVE) return;
    this._pack(seat, 'timeout');
  }

  _advanceTurn(fromSeat) {
    if (!this.hand) return;

    const next = this._nextActiveSeat(fromSeat);
    if (next === -1) return;

    // A betting round completes whenever the turn steps over the seat that
    // opened the hand. Measuring by distance (rather than landing exactly on
    // that seat) keeps the count right after the opener packs or leaves.
    const toNext = this._distance(fromSeat, next);
    const toStart = this._distance(fromSeat, this.hand.startSeat);
    if (toStart > 0 && toStart <= toNext) {
      this.hand.round += 1;
      if (this.hand.round >= this.config.maxBetRounds) {
        this._forcedShowdown();
        return;
      }
    }

    this._setTurn(next);
    this.emit('state', this);
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
    const potCap = this.config.bootAmount * this.config.potLimitMultiplier;
    const ceiling = Math.min(potCap, seat.chips);

    const maxSteps = this.config.maxRaiseSteps ?? 8;
    const steps = [];
    let amount = Math.min(base, potCap);
    while (amount <= ceiling && steps.length < maxSteps) {
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

    return {
      canSee: seat.isBlind,
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

  _moveToPot(seat, amount) {
    seat.chips -= amount;
    seat.contributed += amount;
    this.hand.pot += amount;

    const existing = this.hand.contributions.get(seat.userId);
    if (existing) {
      existing.contributed = seat.contributed;
    } else {
      this.hand.contributions.set(seat.userId, {
        userId: seat.userId,
        displayName: seat.displayName,
        seatIndex: seat.seatIndex,
        contributed: seat.contributed,
        status: seat.status,
        sawCards: !seat.isBlind,
        cards: seat.cards,
      });
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
   * Applies a player action. Throws `GameError` for anything the client should
   * be told about (wrong turn, unaffordable bet, illegal show).
   */
  act(userId, action, payload = {}) {
    if (!this.hand) throw new GameError('no_hand', 'No hand is in progress');

    const seat = this.findSeat(userId);
    if (!seat) throw new GameError('not_seated', 'You are not at this table');
    if (seat.status !== SEAT_STATE.ACTIVE) throw new GameError('not_in_hand', 'You are not in this hand');
    if (this.hand.turnSeat !== seat.seatIndex) throw new GameError('not_your_turn', 'It is not your turn');

    switch (action) {
      case ACTION.SEE:
        return this._see(seat);
      case ACTION.CHAAL:
        return this._bet(seat, 'chaal', payload.amount);
      case ACTION.RAISE:
        return this._bet(seat, 'raise', payload.amount);
      case ACTION.PACK:
        return this._pack(seat, 'pack');
      case ACTION.SHOW:
        return this._show(seat);
      default:
        throw new GameError('unknown_action', `Unknown action "${action}"`);
    }
  }

  /**
   * Reveals the player's own cards to them. Free, and deliberately does not end
   * the turn — the turn timer keeps running, so seeing costs thinking time.
   */
  _see(seat) {
    if (!seat.isBlind) throw new GameError('already_seen', 'You have already seen your cards');
    seat.isBlind = false;
    this._syncContribution(seat);

    this.emit('cards', { userId: seat.userId, cards: seat.cards.map(cardCode) });
    this.emit('action', {
      userId: seat.userId,
      action: ACTION.SEE,
      amount: 0,
      pot: this.hand.pot,
      stake: this.hand.stake,
    });
    // Re-issue the turn so the client gets the updated (seen) bet amounts.
    this.emit('turn', {
      userId: seat.userId,
      seatIndex: seat.seatIndex,
      deadline: this.hand.turnDeadline,
      timeoutMs: Math.max(0, this.hand.turnDeadline - Date.now()),
      options: this.turnOptions(seat),
    });
    this.emit('state', this);
    return { action: ACTION.SEE };
  }

  /**
   * Places a bet.
   *
   * `requested` is the amount the client picked with the +/− stepper. It is
   * never trusted: the ladder is recomputed here and the amount must be one of
   * its rungs, which is what stops a tampered client betting an arbitrary
   * figure or more than it holds. Omitting it takes the default for the kind,
   * so a plain "chaal" or "raise" still works.
   */
  _bet(seat, kind, requested) {
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

    this._moveToPot(seat, amount);

    // The stake is always expressed as a blind unit, so halve a seen player's bet.
    this.hand.stake = seat.isBlind ? amount : Math.floor(amount / 2);

    this.emit('action', {
      userId: seat.userId,
      action: kind === 'raise' ? ACTION.RAISE : ACTION.CHAAL,
      amount,
      pot: this.hand.pot,
      stake: this.hand.stake,
    });

    this._clearTurnTimer();
    this._advanceTurn(seat.seatIndex);
    this.emit('state', this);
    return { action: kind, amount };
  }

  _pack(seat, reason) {
    seat.status = SEAT_STATE.PACKED;
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

    if (this._resolveIfOnlyOneLeft()) return { action: ACTION.PACK, reason };

    this._advanceTurn(seat.seatIndex);
    this.emit('state', this);
    return { action: ACTION.PACK, reason };
  }

  /** Requirement 6e/6f: last player standing takes the whole pot, no reveal. */
  _resolveIfOnlyOneLeft() {
    const active = this.activeSeats;
    if (active.length > 1) return false;

    if (active.length === 1) {
      this._endHand({ winnerSeat: active[0], reason: WIN_REASON.LAST_STANDING, reveals: [] });
    } else {
      // Nobody left (everyone disconnected mid-hand): the pot is void and each
      // remaining contribution is returned.
      this._endHand({ winnerSeat: null, reason: WIN_REASON.LAST_STANDING, reveals: [] });
    }
    return true;
  }

  _show(seat) {
    const active = this.activeSeats;
    if (active.length !== 2) throw new GameError('show_unavailable', 'A show needs exactly two players left');

    const cost = this.showCost(seat);
    if (seat.chips < cost) throw new GameError('insufficient_chips', 'Not enough chips to pay for the show');

    this._moveToPot(seat, cost);
    this.hand.showRequestedBy = seat.userId;

    this.emit('action', {
      userId: seat.userId,
      action: ACTION.SHOW,
      amount: cost,
      pot: this.hand.pot,
      stake: this.hand.stake,
    });

    this._clearTurnTimer();
    this._resolveShowdown(active, WIN_REASON.SHOW, seat.userId);
    return { action: ACTION.SHOW, amount: cost };
  }

  /** Round cap reached: everyone still in reveals and the best hand takes it. */
  _forcedShowdown() {
    this._clearTurnTimer();
    this._resolveShowdown(this.activeSeats, WIN_REASON.FORCED_SHOWDOWN, null);
  }

  /**
   * Compares hands and ends the hand.
   *
   * Exact ties go to the player who did *not* pay for the show; in a forced
   * showdown they go to the seat nearest the dealer's left. Only one player
   * ever wins — the pot is never split (requirement 6e).
   */
  _resolveShowdown(contenders, reason, showRequestedBy) {
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

    this._endHand({ winnerSeat: best.seat, reason, reveals });
  }

  // ------------------------------------------------------------- hand end

  _endHand({ winnerSeat, reason, reveals }) {
    const hand = this.hand;
    if (!hand) return;

    this._clearTurnTimer();
    hand.endedAt = Date.now();

    if (winnerSeat) {
      winnerSeat.status = SEAT_STATE.WON;
      this._syncContribution(winnerSeat, SEAT_STATE.WON);
    }

    // Everyone who put chips in this hand, including players who have since
    // left the table — their stake still has to be settled and audited.
    const contributors = [...hand.contributions.values()].filter((entry) => entry.contributed > 0);

    // With no winner (every player vanished mid-hand) the pot is void and each
    // contribution is returned rather than quietly destroyed.
    const entries = contributors.map((entry) => {
      const isWinner = entry.userId === winnerSeat?.userId;
      let delta = 0;
      if (winnerSeat) delta = isWinner ? hand.pot - entry.contributed : -entry.contributed;
      return { userId: entry.userId, delta, isWinner };
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
      winnerId: winnerSeat?.userId ?? null,
      winReason: reason,
      bootAmount: this.config.bootAmount,
      startedAt: hand.startedAt,
      endedAt: hand.endedAt,
      summary,
    };

    // One database transaction per hand keeps write pressure flat as tables scale.
    let balances = {};
    try {
      balances = this.settle({ hand: record, entries }) ?? {};
    } catch (error) {
      this.emit('error', error);
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

    this.hand = null;
    this.state = TABLE_STATE.WAITING;

    const nextHandAt = Date.now() + this.config.nextHandDelayMs;
    this.emit('handEnded', {
      handId: record.id,
      handNo: record.handNo,
      winnerId: record.winnerId,
      winnerName: winnerSeat?.displayName ?? null,
      pot: record.pot,
      reason,
      reveals,
      summary,
      nextHandAt,
    });

    this.emit('state', this);
    this._maybeStart();
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
      stake: this.hand?.stake ?? this.config.bootAmount,
      round: this.hand?.round ?? 0,
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
            contributed: viewer.contributed,
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

  destroy() {
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

const defaultTimers = {
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (handle) => clearTimeout(handle),
};

export default Table;
