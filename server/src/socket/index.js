import { verifyToken } from '../auth/tokens.js';
import RoomManager from '../game/roomManager.js';
import { findById } from '../db/users.js';
import { GameError } from '../game/table.js';
import { ACTION } from '../game/constants.js';
import config from '../config/index.js';
import logger from '../util/logger.js';

const VALID_ACTIONS = new Set(Object.values(ACTION));

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

  /** Sends every viewer of a table their own redacted snapshot. */
  const broadcastState = (table) => {
    for (const socket of socketsIn(table.id)) {
      socket.emit('room:state', table.serializeFor(socket.data.user.id));
    }
  };

  const emitToUser = (userId, event, payload) => {
    userSockets.get(userId)?.emit(event, payload);
  };

  const fail = (socket, error) => {
    if (error instanceof GameError) {
      socket.emit('game:error', { code: error.code, message: error.message });
    } else {
      logger.error('socket handler failed', { error: error.message, stack: error.stack });
      socket.emit('game:error', { code: 'internal_error', message: 'Something went wrong' });
    }
  };

  // ------------------------------------------------------------- table wiring

  const wireTable = (table) => {
    if (table._wired) return;
    table._wired = true;

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
      emitToUser(userId, 'room:kicked', { roomId: table.id, reason, message });

      const socket = userSockets.get(userId);
      if (socket) untrackRoom(table.id, socket);

      const stillAlive = rooms.getTable(table.id);
      if (stillAlive) broadcastState(stillAlive);
    });

    table.on('handStarted', (payload) => {
      io.to(table.id).emit('game:handStarted', { ...payload, roomId: table.id });
      // Cards stay on the server until a player pays attention to them by
      // pressing "see" — this is what keeps a modified client from peeking.
      for (const socket of socketsIn(table.id)) {
        socket.emit('player:hand', { roomId: table.id, dealt: true, cardsHidden: true });
      }
    });

    table.on('cards', ({ userId, cards }) => {
      emitToUser(userId, 'player:cards', { roomId: table.id, cards });
    });

    table.on('turn', (payload) => {
      io.to(table.id).emit('game:turn', {
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
      io.to(table.id).emit('game:action', { ...payload, roomId: table.id });
    });

    /**
     * A sideshow is public knowledge except for the cards: everyone sees who
     * asked whom, so the table can animate it, and everyone sees the outcome.
     * Only the two players involved ever receive the hands.
     */
    table.on('sideshowRequested', (payload) => {
      io.to(table.id).emit('game:sideshowRequested', { ...payload, roomId: table.id });
    });

    table.on('sideshowReveal', ({ userIds, reveal }) => {
      for (const userId of userIds) {
        emitToUser(userId, 'game:sideshowReveal', { roomId: table.id, reveal });
      }
    });

    table.on('sideshowResolved', (payload) => {
      io.to(table.id).emit('game:sideshowResolved', { ...payload, roomId: table.id });
    });

    table.on('showdown', (payload) => {
      io.to(table.id).emit('game:showdown', { ...payload, roomId: table.id });
    });

    table.on('handEnded', (payload) => {
      io.to(table.id).emit('game:handEnded', { ...payload, roomId: table.id });
    });

    // Chat is room-scoped: this only reaches sockets joined to this table.
    table.on('chat', (message) => {
      if (!message) return;
      io.to(table.id).emit('chat:message', { ...message, roomId: table.id });
    });
  };

  /** Sends a joining player the room's in-memory backlog, oldest first. */
  const sendChatHistory = (table, socket) => {
    socket.emit('chat:history', {
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

    socket.emit('room:moved', {
      fromRoomId,
      toRoomId,
      code: target.code,
      message: 'Moved to a table with other players waiting.',
    });
    socket.emit('room:joined', target.serializeFor(userId));
    sendChatHistory(target, socket);
    broadcastState(target);
  });

  rooms.on('tableDestroyed', (roomId) => {
    for (const socket of socketsIn(roomId)) {
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

    // One live session per account: a second login kicks the first, which stops
    // a player opening two clients on the same seat.
    const previous = userSockets.get(user.id);
    if (previous && previous.id !== socket.id) {
      previous.emit('session:replaced', { message: 'Signed in from another device' });
      previous.disconnect(true);
    }
    userSockets.set(user.id, socket);

    // Cancel a pending removal — this is a reconnect inside the grace window.
    const pending = pendingRemovals.get(user.id);
    if (pending) {
      clearTimeout(pending);
      pendingRemovals.delete(user.id);
    }

    // Restore a player who was mid-hand when their connection dropped. If the
    // seat has already lapsed, `resume` names the table they were at so the
    // client can sit them back down there without a trip through the lobby.
    const existingTable = rooms.getTableForPlayer(user.id);
    const resume = existingTable ? null : takeResumeOffer(user.id);
    if (existingTable) resumeOffers.delete(user.id);

    socket.emit('session:ready', {
      user,
      config: publicGameConfig(),
      ...(resume ? { resume } : {}),
    });

    if (existingTable) {
      wireTable(existingTable);
      trackRoom(existingTable.id, socket);
      existingTable.setConnected(user.id, true, socket.id);
      socket.emit('room:joined', existingTable.serializeFor(user.id));
      sendChatHistory(existingTable, socket);
    }

    const rateLimiter = createRateLimiter({ limit: 30, windowMs: 5000 });

    const guard = (handler) => async (payload, ack) => {
      if (!rateLimiter()) {
        socket.emit('game:error', { code: 'rate_limited', message: 'Slow down' });
        // Acknowledged as a refusal, not dropped: a client awaiting the ack
        // would otherwise hang on it.
        if (typeof ack === 'function') ack({ ok: false, code: 'rate_limited', message: 'Slow down' });
        return;
      }
      try {
        const result = await handler(payload ?? {});
        if (typeof ack === 'function') ack({ ok: true, ...result });
      } catch (error) {
        if (typeof ack === 'function') {
          ack({ ok: false, code: error.code ?? 'internal_error', message: error.message });
        }
        fail(socket, error);
      }
    };

    // ------------------------------------------------------------ lobby

    socket.on(
      'lobby:list',
      guard(async ({ category } = {}) => ({
        tables: rooms.listTables({ category: category ?? null }),
        options: RoomManager.lobbyOptions(),
      })),
    );

    socket.on(
      'room:quickJoin',
      guard(async ({ bootAmount, category }) => {
        const fresh = await findById(user.id);
        // Seating announces the arrival to players already in the room; this
        // player sees it a moment later in the history they are sent below.
        const table = rooms.quickJoin(fresh, {
          bootAmount: bootAmount ?? config.game.bootAmount,
          category,
        });
        wireTable(table);
        trackRoom(table.id, socket);
        table.setConnected(user.id, true, socket.id);
        socket.emit('room:joined', table.serializeFor(user.id));
        sendChatHistory(table, socket);
        broadcastState(table);
        return { roomId: table.id, code: table.code, category: table.category };
      }),
    );

    socket.on(
      'room:create',
      guard(async ({ bootAmount, isPrivate = true, category }) => {
        const fresh = await findById(user.id);
        const table = rooms.createTable({
          bootAmount: bootAmount ?? config.game.bootAmount,
          isPrivate,
          category,
        });
        wireTable(table);
        rooms.join(table, fresh, socket.id);
        trackRoom(table.id, socket);
        socket.emit('room:joined', table.serializeFor(user.id));
        sendChatHistory(table, socket);
        return { roomId: table.id, code: table.code, category: table.category };
      }),
    );

    socket.on(
      'room:joinCode',
      guard(async ({ code }) => {
        const fresh = await findById(user.id);
        const table = rooms.joinByCode(fresh, code);
        wireTable(table);
        trackRoom(table.id, socket);
        table.setConnected(user.id, true, socket.id);
        socket.emit('room:joined', table.serializeFor(user.id));
        sendChatHistory(table, socket);
        broadcastState(table);
        return { roomId: table.id, code: table.code, category: table.category };
      }),
    );

    socket.on(
      'room:switch',
      guard(async () => {
        const fresh = await findById(user.id);

        // Stop listening to the old room *first*. Leaving it can destroy it —
        // if this player was the last one there — and a table being destroyed
        // tells everyone still tracking it that the room closed. That message
        // would land on this socket and read as "you have been thrown out",
        // moments before the join it is in the middle of.
        const leaving = rooms.getTableForPlayer(user.id);
        if (leaving) untrackRoom(leaving.id, socket);

        let from;
        let table;
        try {
          ({ from, table } = await rooms.switchTable(fresh));
        } catch (error) {
          // Nowhere to go: the seat was never given up, so put the socket back
          // where it was listening.
          if (leaving && rooms.getTable(leaving.id)) trackRoom(leaving.id, socket);
          throw error;
        }

        wireTable(table);
        trackRoom(table.id, socket);
        table.setConnected(user.id, true, socket.id);

        socket.emit('room:joined', table.serializeFor(user.id));
        sendChatHistory(table, socket);
        broadcastState(table);

        // The table they left has one fewer player; everyone still there
        // should see that straight away.
        const vacated = rooms.getTable(from.id);
        if (vacated) broadcastState(vacated);

        return { roomId: table.id, code: table.code, category: table.category };
      }),
    );

    socket.on(
      'room:leave',
      guard(async () => {
        const table = rooms.getTableForPlayer(user.id);
        if (!table) return {};
        const roomId = table.id;
        await rooms.leave(user.id, 'left');
        untrackRoom(roomId, socket);
        socket.emit('room:left', { roomId });
        const stillAlive = rooms.getTable(roomId);
        if (stillAlive) broadcastState(stillAlive);
        return { roomId };
      }),
    );

    // ------------------------------------------------------------- gameplay

    socket.on(
      'game:action',
      guard(async ({ action, amount, actionId }) => {
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

        return table.act(user.id, action, { amount: parsed, actionId: id });
      }),
    );

    /**
     * The answer to a sideshow request. Only the player who was asked can send
     * this, which the table enforces; an unanswered request expires by itself
     * after six seconds, so a client that simply never replies is not a way to
     * stall the table.
     */
    socket.on(
      'game:sideshowRespond',
      guard(async ({ accept }) => {
        const table = rooms.getTableForPlayer(user.id);
        if (!table) throw new GameError('not_in_room', 'You are not at a table');
        return table.respondToSideshow(user.id, accept === true);
      }),
    );

    /** Lets a player re-request their own cards after a reconnect. */
    socket.on(
      'player:requestCards',
      guard(async () => {
        const table = rooms.getTableForPlayer(user.id);
        if (!table) throw new GameError('not_in_room', 'You are not at a table');
        const seat = table.findSeat(user.id);
        if (!seat || seat.isBlind || seat.cards.length === 0) return { cards: [] };
        const cards = table.serializeFor(user.id).you.cards;
        socket.emit('player:cards', { roomId: table.id, cards });
        return { cards };
      }),
    );

    // Chat gets its own, tighter allowance: a player flooding the room log
    // should be throttled well before they trip the general action limiter.
    const chatLimiter = createRateLimiter({
      limit: config.chat.rateLimit,
      windowMs: config.chat.rateWindowMs,
    });

    socket.on(
      'chat:message',
      guard(async ({ text }) => {
        const table = rooms.getTableForPlayer(user.id);
        if (!table) throw new GameError('not_in_room', 'You are not at a table');

        if (!chatLimiter()) {
          throw new GameError('chat_rate_limited', 'You are sending messages too quickly');
        }

        const message = table.postChat(user.id, text);
        return message ? { messageId: message.id } : {};
      }),
    );

    /** Lets a client re-pull the backlog, e.g. after a reconnect. */
    socket.on(
      'chat:history',
      guard(async () => {
        const table = rooms.getTableForPlayer(user.id);
        if (!table) throw new GameError('not_in_room', 'You are not at a table');
        sendChatHistory(table, socket);
        return { count: table.chatHistory().length };
      }),
    );

    socket.on('ping:rtt', (sentAt, ack) => {
      if (typeof ack === 'function') ack({ sentAt, serverTime: Date.now() });
    });

    // ----------------------------------------------------------- disconnect

    socket.on('disconnect', (reason) => {
      if (userSockets.get(user.id) === socket) userSockets.delete(user.id);

      const table = rooms.getTableForPlayer(user.id);
      if (!table) return;

      untrackRoom(table.id, socket);
      table.setConnected(user.id, false);

      // Hold the seat briefly so a flaky mobile connection does not cost the
      // player their place mid-hand; their turn still times out normally.
      const handle = setTimeout(async () => {
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

      handle.unref?.();
      pendingRemovals.set(user.id, handle);

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
