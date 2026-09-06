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

  rooms.on('tableDestroyed', (roomId) => {
    for (const socket of socketsIn(roomId)) {
      socket.emit('room:closed', { roomId });
      socket.leave(roomId);
    }
    roomSockets.delete(roomId);
  });

  // ------------------------------------------------------------ handshake

  io.use((socket, next) => {
    try {
      const token = socket.handshake.auth?.token ?? socket.handshake.query?.token;
      const claims = verifyToken(token);
      const user = findById(claims.sub);
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

    socket.emit('session:ready', { user, config: publicGameConfig() });

    // Restore a player who was mid-hand when their connection dropped.
    const existingTable = rooms.getTableForPlayer(user.id);
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
        const fresh = findById(user.id);
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
        const fresh = findById(user.id);
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
        const fresh = findById(user.id);
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
      'room:leave',
      guard(async () => {
        const table = rooms.getTableForPlayer(user.id);
        if (!table) return {};
        const roomId = table.id;
        rooms.leave(user.id, 'left');
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
      guard(async ({ action, amount }) => {
        if (!VALID_ACTIONS.has(action)) {
          throw new GameError('unknown_action', `Unknown action "${action}"`);
        }
        const table = rooms.getTableForPlayer(user.id);
        if (!table) throw new GameError('not_in_room', 'You are not at a table');

        // `amount` is what the player picked with the +/- stepper. The table
        // validates it against the ladder it computes itself, so a tampered
        // client cannot bet an arbitrary figure.
        const parsed = amount === undefined || amount === null ? undefined : Number(amount);
        if (parsed !== undefined && !Number.isInteger(parsed)) {
          throw new GameError('invalid_bet', 'Bet amount must be a whole number');
        }

        return table.act(user.id, action, { amount: parsed });
      }),
    );

    /** Lets a player re-request their own cards after a reconnect. */
    socket.on(
      'player:requestCards',
      guard(async () => {
        const table = rooms.getTableForPlayer(user.id);
        const seat = table?.findSeat(user.id);
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
      const handle = setTimeout(() => {
        pendingRemovals.delete(user.id);
        if (userSockets.has(user.id)) return; // reconnected on another socket
        const current = rooms.getTableForPlayer(user.id);
        if (!current) return;
        const roomId = current.id;
        rooms.leave(user.id, 'disconnected');
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
  /** The Blind/Seen categories and the stakes the lobby offers. */
  categories: RoomManager.lobbyOptions().categories,
  stakes: RoomManager.lobbyOptions().stakes,
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
