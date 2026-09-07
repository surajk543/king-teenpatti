import { verifyToken } from '../auth/tokens.js';
import RoomManager from '../game/roomManager.js';
import { findById } from '../db/users.js';
import { GameError } from '../game/table.js';
import { ACTION, TABLE_CATEGORY, WIN_REASON } from '../game/constants.js';
import config from '../config/index.js';
import logger from '../util/logger.js';
import {
  connectedSockets,
  peakConnectedSockets,
  connectionsTotal,
  disconnectionsTotal,
  reconnectsTotal,
  socketErrorsTotal,
  socketMessagesTotal,
  socketEmitsTotal,
  sessionReplacedTotal,
  gamesStartedTotal,
  gamesCompletedTotal,
  gamesAbandonedTotal,
  movesTotal,
  invalidMovesTotal,
  timeoutsTotal,
  kicksTotal,
  chatMessagesTotal,
  potSettledTotal,
  moveDuration,
  gameJoinDuration,
  stateUpdateDuration,
  safeLabel,
  timed,
  timedSync,
} from '../metrics/index.js';

const VALID_ACTIONS = new Set(Object.values(ACTION));

// ------------------------------------------------------------- metric labels
//
// Every label value below comes from one of these fixed sets; anything else is
// folded into "other" by safeLabel(). Nothing derived from a player — ids,
// names, room codes — ever becomes a label.

/** Socket.IO's own server-side disconnect reasons. */
const KNOWN_DISCONNECT_REASONS = new Set([
  'transport close',
  'transport error',
  'ping timeout',
  'client namespace disconnect',
  'server namespace disconnect',
  'forced close',
  'server shutting down',
]);

/** Every GameError / AuthError code a socket request can be refused with. */
const KNOWN_ERROR_CODES = new Set([
  // Rooms and seating (roomManager.js, socket/index.js)
  'already_in_room',
  'already_seated',
  'insufficient_chips',
  'invalid_stake',
  'no_other_table',
  'not_in_room',
  'not_seated',
  'over_entry_cap',
  'private_table',
  'room_not_found',
  'table_full',
  'table_not_offered',
  'unknown_action',
  // Moves (table.js)
  'already_seen',
  'duplicate_action',
  'invalid_bet',
  'no_hand',
  'not_in_hand',
  'not_your_turn',
  'persist_failed',
  'show_unavailable',
  // Sideshow (table.js: sideshowBlockedReason and the response path)
  'already_asked',
  'neighbour_is_blind',
  'no_neighbour',
  'no_sideshow',
  'not_your_sideshow',
  'sideshow_pending',
  'too_few_players',
  'you_are_blind',
  // Chat
  'chat_rate_limited',
  // Auth (auth/*.js)
  'invalid_device_id',
  'invalid_session',
  'invalid_token',
  'missing_token',
  'provider_unconfigured',
  'unknown_provider',
  'unknown_user',
  // The socket layer's own refusals
  'rate_limited',
  'internal_error',
]);

const KNOWN_WIN_REASONS = new Set(Object.values(WIN_REASON));
const KNOWN_CATEGORIES = new Set(Object.values(TABLE_CATEGORY));
const KNOWN_KICK_REASONS = new Set(['idle', 'insufficient_chips', 'unfunded', 'disconnected', 'other']);

/**
 * Wires Socket.IO to the room manager.
 *
 * Table state is broadcast per viewer rather than per room, because each player
 * must only ever receive their own cards. With at most five seats per table
 * that is a handful of small payloads per change.
 */
export function attachSocketHandlers(io, rooms) {
  /** roomId -> Set<socket>, so we can address a table's viewers individually. */
  const roomSockets = new Map();
  /** userId -> socket, for the single-session rule and private sends. */
  const userSockets = new Map();
  /** userId -> timeout handle for the disconnect grace period. */
  const pendingRemovals = new Map();
  /**
   * userId -> { roomId, code, category, bootAmount, at } for a player whose
   * connection died and whose seat was then given up when the grace period
   * ran out. An app that was force-closed mid-hand comes back to no seat; this
   * is how it still finds its way back to the same table.
   */
  const resumeOffers = new Map();

  /**
   * Live socket count and its high-water mark, kept here rather than read back
   * from the gauge so the peak is exact even when connections churn between
   * scrapes.
   */
  let liveSockets = 0;
  let peakSockets = 0;

  /** Takes the resume offer for a player, if there is one and it still stands. */
  const takeResumeOffer = (userId) => {
    const offer = resumeOffers.get(userId);
    if (!offer) return null;
    resumeOffers.delete(userId);
    if (Date.now() - offer.at > config.game.resumeOfferMs) return null;
    const table = rooms.getTable(offer.roomId);
    if (!table || table.isFull) return null;
    return {
      roomId: table.id,
      code: table.code,
      category: table.category,
      bootAmount: table.config.bootAmount,
    };
  };

  const socketsIn = (roomId) => roomSockets.get(roomId) ?? new Set();

  const trackRoom = (roomId, socket) => {
    if (!roomSockets.has(roomId)) roomSockets.set(roomId, new Set());
    roomSockets.get(roomId).add(socket);
    socket.join(roomId);
  };

  const untrackRoom = (roomId, socket) => {
    const set = roomSockets.get(roomId);
    if (!set) return;
    set.delete(socket);
    if (set.size === 0) roomSockets.delete(roomId);
    socket.leave(roomId);
  };

  // Every message to a client goes out through one of these three, so each is
  // counted under its wire event name. A room broadcast counts once, however
  // many sockets it reaches.
  const emitTo = (socket, event, payload) => {
    socketEmitsTotal.inc({ event });
    socket.emit(event, payload);
  };

  const emitToRoom = (roomId, event, payload) => {
    socketEmitsTotal.inc({ event });
    io.to(roomId).emit(event, payload);
  };

  const emitToUser = (userId, event, payload) => {
    const socket = userSockets.get(userId);
    if (socket) emitTo(socket, event, payload);
  };

  /**
   * Sends every viewer of a table their own redacted snapshot. Timed as a
   * whole — serialising once per viewer and sending — since that is the cost
   * of a table state change as the players experience it.
   */
  const broadcastState = (table) => {
    socketEmitsTotal.inc({ event: 'room:state' });
    timedSync(stateUpdateDuration, {}, () => {
      for (const socket of socketsIn(table.id)) {
        socket.emit('room:state', table.serializeFor(socket.data.user.id));
      }
    });
  };

  const fail = (socket, error) => {
    if (error instanceof GameError) {
      emitTo(socket, 'game:error', { code: error.code, message: error.message });
    } else {
      logger.error('socket handler failed', { error: error.message, stack: error.stack });
      emitTo(socket, 'game:error', { code: 'internal_error', message: 'Something went wrong' });
    }
  };

  // ------------------------------------------------------------- table wiring

  const wireTable = (table) => {
    if (table._wired) return;
    table._wired = true;

    const category = safeLabel(table.category, KNOWN_CATEGORIES);

    table.on('state', () => broadcastState(table));

    /**
     * Requirements 31 and 32: the table has decided somebody should not be
     * sitting there any more — they stopped playing, or they can no longer
     * cover the boot.
     *
     * The table only announces it; the seat is actually given up here, where
     * the room book-keeping and the player's socket both live. They are told
     * why, so the lobby can say something better than "you were removed".
     */
    table.on('kick', async ({ userId, reason, message }) => {
      if (!rooms.getTableForPlayer(userId)) return;

      try {
        await rooms.leave(userId, reason);
      } catch (error) {
        logger.error('kick failed', { userId, reason, error: error.message });
        return;
      }
      kicksTotal.inc({ reason: safeLabel(reason, KNOWN_KICK_REASONS) });
      emitToUser(userId, 'room:kicked', { roomId: table.id, reason, message });

      const socket = userSockets.get(userId);
      if (socket) untrackRoom(table.id, socket);

      const stillAlive = rooms.getTable(table.id);
      if (stillAlive) broadcastState(stillAlive);
    });

    table.on('handStarted', (payload) => {
      gamesStartedTotal.inc({ category });
      emitToRoom(table.id, 'game:handStarted', { ...payload, roomId: table.id });
      // Cards stay on the server until a player pays attention to them by
      // pressing "see" — this is what keeps a modified client from peeking.
      socketEmitsTotal.inc({ event: 'player:hand' });
      for (const socket of socketsIn(table.id)) {
        socket.emit('player:hand', { roomId: table.id, dealt: true, cardsHidden: true });
      }
    });

    table.on('cards', ({ userId, cards }) => {
      emitToUser(userId, 'player:cards', { roomId: table.id, cards });
    });

    table.on('turn', (payload) => {
      emitToRoom(table.id, 'game:turn', {
        roomId: table.id,
        userId: payload.userId,
        seatIndex: payload.seatIndex,
        deadline: payload.deadline,
        timeoutMs: payload.timeoutMs,
      });
      // Only the player on turn is told which actions are legal and what they cost.
      emitToUser(payload.userId, 'game:yourTurn', {
        roomId: table.id,
        deadline: payload.deadline,
        timeoutMs: payload.timeoutMs,
        options: payload.options,
      });
    });

    table.on('action', (payload) => {
      // A pack the clock made on the player's behalf, not one they chose.
      if (payload.reason === 'timeout') timeoutsTotal.inc();
      emitToRoom(table.id, 'game:action', { ...payload, roomId: table.id });
    });

    /**
     * A sideshow is public knowledge except for the cards: everyone sees who
     * asked whom, so the table can animate it, and everyone sees the outcome.
     * Only the two players involved ever receive the hands.
     */
    table.on('sideshowRequested', (payload) => {
      emitToRoom(table.id, 'game:sideshowRequested', { ...payload, roomId: table.id });
    });

    table.on('sideshowReveal', ({ userIds, reveal }) => {
      socketEmitsTotal.inc({ event: 'game:sideshowReveal' });
      for (const userId of userIds) {
        userSockets.get(userId)?.emit('game:sideshowReveal', { roomId: table.id, reveal });
      }
    });

    table.on('sideshowResolved', (payload) => {
      emitToRoom(table.id, 'game:sideshowResolved', { ...payload, roomId: table.id });
    });

    table.on('showdown', (payload) => {
      emitToRoom(table.id, 'game:showdown', { ...payload, roomId: table.id });
    });

    table.on('handEnded', (payload) => {
      const { reason, pot, winnerId } = payload;
      // A hand everybody walked out of (or one cut short by the table being
      // destroyed) is abandoned; anything else finished with a real outcome.
      if (reason === WIN_REASON.ALL_LEFT) {
        gamesAbandonedTotal.inc({ category });
      } else {
        gamesCompletedTotal.inc({ category, reason: safeLabel(reason, KNOWN_WIN_REASONS) });
      }
      // With no winner the pot is refunded rather than paid, so it is not a
      // settlement; the last leaver of an abandoned hand does take the pot.
      if (winnerId && Number.isFinite(pot) && pot > 0) potSettledTotal.inc(pot);
      emitToRoom(table.id, 'game:handEnded', { ...payload, roomId: table.id });
    });

    // Chat is room-scoped: this only reaches sockets joined to this table.
    table.on('chat', (message) => {
      if (!message) return;
      chatMessagesTotal.inc();
      emitToRoom(table.id, 'chat:message', { ...message, roomId: table.id });
    });
  };

  /** Sends a joining player the room's in-memory backlog, oldest first. */
  const sendChatHistory = (table, socket) => {
    emitTo(socket, 'chat:history', {
      roomId: table.id,
      messages: table.chatHistory(),
    });
  };

  rooms.on('tableCreated', wireTable);

  /**
   * Requirement 24: a player merged onto a busier table is re-tracked here and
   * handed the new room, so the move is seamless rather than a disconnect.
   */
  rooms.on('playerMoved', ({ userId, fromRoomId, toRoomId }) => {
    const socket = userSockets.get(userId);
    const target = rooms.getTable(toRoomId);
    if (!socket || !target) return;

    untrackRoom(fromRoomId, socket);
    wireTable(target);
    trackRoom(toRoomId, socket);
    target.setConnected(userId, true, socket.id);

    emitTo(socket, 'room:moved', {
      fromRoomId,
      toRoomId,
      code: target.code,
      message: 'Moved to a table with other players waiting.',
    });
    emitTo(socket, 'room:joined', target.serializeFor(userId));
    sendChatHistory(target, socket);
    broadcastState(target);
  });

  rooms.on('tableDestroyed', (roomId) => {
    const viewers = socketsIn(roomId);
    if (viewers.size > 0) socketEmitsTotal.inc({ event: 'room:closed' });
    for (const socket of viewers) {
      socket.emit('room:closed', { roomId });
      socket.leave(roomId);
    }
    roomSockets.delete(roomId);
  });

  // ------------------------------------------------------------ handshake

  io.use(async (socket, next) => {
    try {
      const token = socket.handshake.auth?.token ?? socket.handshake.query?.token;
      const claims = verifyToken(token);
      const user = await findById(claims.sub);
      if (!user) return next(new Error('unknown_user'));
      socket.data.user = user;
      return next();
    } catch (error) {
      return next(new Error(error.code ?? 'unauthorized'));
    }
  });

  io.on('connection', (socket) => {
    const user = socket.data.user;

    connectionsTotal.inc();
    connectedSockets.inc();
    liveSockets += 1;
    if (liveSockets > peakSockets) {
      peakSockets = liveSockets;
      peakConnectedSockets.set(peakSockets);
    }

    // One live session per account: a second login kicks the first, which stops
    // a player opening two clients on the same seat.
    const previous = userSockets.get(user.id);
    if (previous && previous.id !== socket.id) {
      sessionReplacedTotal.inc();
      emitTo(previous, 'session:replaced', { message: 'Signed in from another device' });
      previous.disconnect(true);
    }
    userSockets.set(user.id, socket);

    // Cancel a pending removal — this is a reconnect inside the grace window.
    const pending = pendingRemovals.get(user.id);
    if (pending) {
      clearTimeout(pending);
      pendingRemovals.delete(user.id);
      reconnectsTotal.inc({ kind: 'seat_held' });
    }

    // Restore a player who was mid-hand when their connection dropped. If the
    // seat has already lapsed, `resume` names the table they were at so the
    // client can sit them back down there without a trip through the lobby.
    const existingTable = rooms.getTableForPlayer(user.id);
    const resume = existingTable ? null : takeResumeOffer(user.id);
    if (existingTable) resumeOffers.delete(user.id);
    if (resume) reconnectsTotal.inc({ kind: 'offer' });

    emitTo(socket, 'session:ready', {
      user,
      config: publicGameConfig(),
      ...(resume ? { resume } : {}),
    });

    if (existingTable) {
      timedSync(gameJoinDuration, { route: 'resume' }, () => {
        wireTable(existingTable);
        trackRoom(existingTable.id, socket);
        existingTable.setConnected(user.id, true, socket.id);
        emitTo(socket, 'room:joined', existingTable.serializeFor(user.id));
      });
      sendChatHistory(existingTable, socket);
    }

    const rateLimiter = createRateLimiter({ limit: 30, windowMs: 5000 });

    /**
     * Wraps a request handler: counts the message under its event name, applies
     * the rate limit, acks the result or the refusal, and counts every refusal
     * by code. A refused `game:action` is also an invalid move.
     */
    const guard = (event, handler) => async (payload, ack) => {
      socketMessagesTotal.inc({ event });
      if (!rateLimiter()) {
        socketErrorsTotal.inc({ code: 'rate_limited' });
        emitTo(socket, 'game:error', { code: 'rate_limited', message: 'Slow down' });
        // Acknowledged as a refusal, not dropped: a client awaiting the ack
        // would otherwise hang on it.
        if (typeof ack === 'function') ack({ ok: false, code: 'rate_limited', message: 'Slow down' });
        return;
      }
      try {
        const result = await handler(payload ?? {});
        if (typeof ack === 'function') ack({ ok: true, ...result });
      } catch (error) {
        const code = safeLabel(error.code ?? 'internal_error', KNOWN_ERROR_CODES);
        socketErrorsTotal.inc({ code });
        if (event === 'game:action') invalidMovesTotal.inc({ code });
        if (typeof ack === 'function') {
          ack({ ok: false, code: error.code ?? 'internal_error', message: error.message });
        }
        fail(socket, error);
      }
    };

    /** Registers a guarded handler for one client event. */
    const handle = (event, handler) => socket.on(event, guard(event, handler));

    // ------------------------------------------------------------ lobby

    handle('lobby:list', async ({ category } = {}) => ({
      tables: rooms.listTables({ category: category ?? null }),
      options: RoomManager.lobbyOptions(),
    }));

    handle('room:quickJoin', async ({ bootAmount, category }) => {
      const table = await timed(gameJoinDuration, { route: 'quick_join' }, async () => {
        const fresh = await findById(user.id);
        // Seating announces the arrival to players already in the room; this
        // player sees it a moment later in the history they are sent below.
        const seated = rooms.quickJoin(fresh, {
          bootAmount: bootAmount ?? config.game.bootAmount,
          category,
        });
        wireTable(seated);
        trackRoom(seated.id, socket);
        seated.setConnected(user.id, true, socket.id);
        emitTo(socket, 'room:joined', seated.serializeFor(user.id));
        return seated;
      });
      sendChatHistory(table, socket);
      broadcastState(table);
      return { roomId: table.id, code: table.code, category: table.category };
    });

    handle('room:create', async ({ bootAmount, isPrivate = true, category }) => {
      const table = await timed(gameJoinDuration, { route: 'create' }, async () => {
        const fresh = await findById(user.id);
        const created = rooms.createTable({
          bootAmount: bootAmount ?? config.game.bootAmount,
          isPrivate,
          category,
        });
        wireTable(created);
        rooms.join(created, fresh, socket.id);
        trackRoom(created.id, socket);
        emitTo(socket, 'room:joined', created.serializeFor(user.id));
        return created;
      });
      sendChatHistory(table, socket);
      return { roomId: table.id, code: table.code, category: table.category };
    });

    handle('room:joinCode', async ({ code }) => {
      const table = await timed(gameJoinDuration, { route: 'code' }, async () => {
        const fresh = await findById(user.id);
        const seated = rooms.joinByCode(fresh, code);
        wireTable(seated);
        trackRoom(seated.id, socket);
        seated.setConnected(user.id, true, socket.id);
        emitTo(socket, 'room:joined', seated.serializeFor(user.id));
        return seated;
      });
      sendChatHistory(table, socket);
      broadcastState(table);
      return { roomId: table.id, code: table.code, category: table.category };
    });

    handle('room:switch', async () => {
      let from;
      const table = await timed(gameJoinDuration, { route: 'switch' }, async () => {
        const fresh = await findById(user.id);

        // Stop listening to the old room *first*. Leaving it can destroy it —
        // if this player was the last one there — and a table being destroyed
        // tells everyone still tracking it that the room closed. That message
        // would land on this socket and read as "you have been thrown out",
        // moments before the join it is in the middle of.
        const leaving = rooms.getTableForPlayer(user.id);
        if (leaving) untrackRoom(leaving.id, socket);

        let target;
        try {
          ({ from, table: target } = await rooms.switchTable(fresh));
        } catch (error) {
          // Nowhere to go: the seat was never given up, so put the socket back
          // where it was listening.
          if (leaving && rooms.getTable(leaving.id)) trackRoom(leaving.id, socket);
          throw error;
        }

        wireTable(target);
        trackRoom(target.id, socket);
        target.setConnected(user.id, true, socket.id);
        emitTo(socket, 'room:joined', target.serializeFor(user.id));
        return target;
      });

      sendChatHistory(table, socket);
      broadcastState(table);

      // The table they left has one fewer player; everyone still there
      // should see that straight away.
      const vacated = rooms.getTable(from.id);
      if (vacated) broadcastState(vacated);

      return { roomId: table.id, code: table.code, category: table.category };
    });

    handle('room:leave', async () => {
      const table = rooms.getTableForPlayer(user.id);
      if (!table) return {};
      const roomId = table.id;
      await rooms.leave(user.id, 'left');
      untrackRoom(roomId, socket);
      emitTo(socket, 'room:left', { roomId });
      const stillAlive = rooms.getTable(roomId);
      if (stillAlive) broadcastState(stillAlive);
      return { roomId };
    });

    // ------------------------------------------------------------- gameplay

    handle('game:action', async ({ action, amount, actionId }) => {
      if (!VALID_ACTIONS.has(action)) {
        throw new GameError('unknown_action', `Unknown action "${action}"`);
      }
      const table = rooms.getTableForPlayer(user.id);
      if (!table) throw new GameError('not_in_room', 'You are not at a table');

      // `amount` is what the player picked with the +/- stepper. The table
      // validates it against the ladder it computes itself, so a tampered
      // client cannot bet an arbitrary figure.
      // Only a real integer will do. `Number()` would happily turn "100",
      // [100] or true into a figure; a client sending those is not one we
      // want to guess for.
      const parsed = amount === undefined || amount === null ? undefined : amount;
      if (parsed !== undefined && (typeof parsed !== 'number' || !Number.isSafeInteger(parsed))) {
        throw new GameError('invalid_bet', 'Bet amount must be a whole number');
      }

      // `actionId` is the client's own id for this move. It goes onto the
      // ledger row and is unique there, so a retried request — the ack got
      // lost, the button was pressed twice — is refused rather than charged
      // twice. A client that sends none gets a fresh id and no protection.
      const id = typeof actionId === 'string' && actionId.length > 0 && actionId.length <= 64
        ? actionId
        : undefined;

      // `action` passed VALID_ACTIONS above, so it is already a safe label;
      // folding it anyway keeps that true if the check ever moves.
      const label = safeLabel(action, VALID_ACTIONS);
      const result = await timed(moveDuration, { action: label }, () =>
        table.act(user.id, action, { amount: parsed, actionId: id }));
      movesTotal.inc({ action: label });
      return result;
    });

    /**
     * The answer to a sideshow request. Only the player who was asked can send
     * this, which the table enforces; an unanswered request expires by itself
     * after six seconds, so a client that simply never replies is not a way to
     * stall the table.
     */
    handle('game:sideshowRespond', async ({ accept }) => {
      const table = rooms.getTableForPlayer(user.id);
      if (!table) throw new GameError('not_in_room', 'You are not at a table');
      return table.respondToSideshow(user.id, accept === true);
    });

    /** Lets a player re-request their own cards after a reconnect. */
    handle('player:requestCards', async () => {
      const table = rooms.getTableForPlayer(user.id);
      if (!table) throw new GameError('not_in_room', 'You are not at a table');
      const seat = table.findSeat(user.id);
      if (!seat || seat.isBlind || seat.cards.length === 0) return { cards: [] };
      const cards = table.serializeFor(user.id).you.cards;
      emitTo(socket, 'player:cards', { roomId: table.id, cards });
      return { cards };
    });

    // Chat gets its own, tighter allowance: a player flooding the room log
    // should be throttled well before they trip the general action limiter.
    const chatLimiter = createRateLimiter({
      limit: config.chat.rateLimit,
      windowMs: config.chat.rateWindowMs,
    });

    handle('chat:message', async ({ text }) => {
      const table = rooms.getTableForPlayer(user.id);
      if (!table) throw new GameError('not_in_room', 'You are not at a table');

      if (!chatLimiter()) {
        throw new GameError('chat_rate_limited', 'You are sending messages too quickly');
      }

      const message = table.postChat(user.id, text);
      return message ? { messageId: message.id } : {};
    });

    /** Lets a client re-pull the backlog, e.g. after a reconnect. */
    handle('chat:history', async () => {
      const table = rooms.getTableForPlayer(user.id);
      if (!table) throw new GameError('not_in_room', 'You are not at a table');
      sendChatHistory(table, socket);
      return { count: table.chatHistory().length };
    });

    socket.on('ping:rtt', (sentAt, ack) => {
      socketMessagesTotal.inc({ event: 'ping:rtt' });
      if (typeof ack === 'function') ack({ sentAt, serverTime: Date.now() });
    });

    // ----------------------------------------------------------- disconnect

    socket.on('disconnect', (reason) => {
      connectedSockets.dec();
      liveSockets = Math.max(0, liveSockets - 1);
      disconnectionsTotal.inc({ reason: safeLabel(reason, KNOWN_DISCONNECT_REASONS) });

      if (userSockets.get(user.id) === socket) userSockets.delete(user.id);

      const table = rooms.getTableForPlayer(user.id);
      if (!table) return;

      untrackRoom(table.id, socket);
      table.setConnected(user.id, false);

      // Hold the seat briefly so a flaky mobile connection does not cost the
      // player their place mid-hand; their turn still times out normally.
      const graceTimer = setTimeout(async () => {
        pendingRemovals.delete(user.id);
        if (userSockets.has(user.id)) return; // reconnected on another socket
        const current = rooms.getTableForPlayer(user.id);
        if (!current) return;
        const roomId = current.id;
        // The seat goes, but not the memory of where it was: a player who
        // reopens the app in the next few minutes is offered this table back.
        resumeOffers.set(user.id, { roomId, at: Date.now() });
        try {
          await rooms.leave(user.id, 'disconnected');
        } catch (error) {
          logger.error('grace removal failed', { userId: user.id, error: error.message });
          return;
        }
        const stillAlive = rooms.getTable(roomId);
        if (stillAlive) broadcastState(stillAlive);
      }, config.game.reconnectGraceMs);

      graceTimer.unref?.();
      pendingRemovals.set(user.id, graceTimer);

      logger.debug('socket disconnected', { userId: user.id, reason });
    });
  });

  return {
    stats: () => ({ sockets: userSockets.size, rooms: roomSockets.size }),
  };
}

const publicGameConfig = () => ({
  maxPlayers: config.game.maxPlayers,
  minPlayers: config.game.minPlayers,
  bootAmount: config.game.bootAmount,
  turnTimeoutMs: config.game.turnTimeoutMs,
  welcomeChips: config.game.welcomeChips,
  maxBetRounds: config.game.maxBetRounds,
  /** How long a sideshow request stands before it lapses, for the countdown. */
  sideshowTimeoutMs: config.game.sideshowTimeoutMs,
  sideshowMinPlayers: config.game.sideshowMinPlayers,
  /** The Blind/Seen categories, the lobby stakes, and the private-table rules. */
  ...RoomManager.lobbyOptions(),
});

/** Simple fixed-window limiter, applied per socket. */
function createRateLimiter({ limit, windowMs }) {
  let windowStart = Date.now();
  let count = 0;
  return () => {
    const now = Date.now();
    if (now - windowStart >= windowMs) {
      windowStart = now;
      count = 0;
    }
    count += 1;
    return count <= limit;
  };
}

export default attachSocketHandlers;
