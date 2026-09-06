import { EventEmitter } from 'node:events';
import Table, { GameError } from './table.js';
import { TABLE_CATEGORY, TABLE_STATE } from './constants.js';
import config from '../config/index.js';
import { uuid, roomCode } from '../util/ids.js';
import { settleHand } from '../db/users.js';
import logger from '../util/logger.js';

/**
 * Owns every live table in this process.
 *
 * At the 500–1000 concurrent player target that is roughly 100–200 tables, all
 * of which fit comfortably in memory; SQLite is only touched once per hand.
 * To run more than one process, front them with a sticky-session load balancer
 * and set REDIS_URL so Socket.IO shares rooms (see the deployment notes).
 */
export class RoomManager extends EventEmitter {
  constructor({ settle = settleHand, timers } = {}) {
    super();
    /** @type {Map<string, Table>} */
    this.tables = new Map();
    /** @type {Map<string, string>} userId -> roomId */
    this.playerRooms = new Map();
    this.settle = settle;
    this.timers = timers;

    this._sweeper = setInterval(() => this.sweepEmptyTables(), 60_000);
    this._sweeper.unref?.();
  }

  // ------------------------------------------------------------------ tables

  /** Normalises a requested category, defaulting to the chips-visible one. */
  static normalizeCategory(category) {
    return category === TABLE_CATEGORY.BLIND ? TABLE_CATEGORY.BLIND : TABLE_CATEGORY.SEEN;
  }

  /**
   * Rejects a stake the lobby does not offer.
   *
   * With `TABLE_STAKES` configured (200 and 5000 by default) a client cannot
   * spin up a table at some arbitrary boot. An empty list means "anything
   * goes", which the test suite relies on for isolation.
   */
  static assertStakeAllowed(bootAmount) {
    if (!Number.isInteger(bootAmount) || bootAmount <= 0) {
      throw new GameError('invalid_stake', 'That stake is not valid');
    }
    const allowed = config.game.tableStakes;
    if (allowed.length > 0 && !allowed.includes(bootAmount)) {
      throw new GameError('invalid_stake', `Stake must be one of: ${allowed.join(', ')}`);
    }
  }

  createTable({ bootAmount = config.game.bootAmount, isPrivate = false, category } = {}) {
    const id = uuid();
    const resolved = RoomManager.normalizeCategory(category);

    const table = new Table({
      id,
      code: roomCode(),
      config: {
        ...config.game,
        bootAmount,
        category: resolved,
        chatMaxHistory: config.chat.maxHistory,
        chatMaxLength: config.chat.maxLength,
      },
      settle: this.settle,
      timers: this.timers,
    });

    table.isPrivate = isPrivate;
    table.on('error', (error) => logger.error('table error', { roomId: id, error: error.message }));

    this.tables.set(id, table);
    this.emit('tableCreated', table);
    logger.info('table created', { roomId: id, code: table.code, bootAmount, category: resolved, isPrivate });
    return table;
  }

  getTable(roomId) {
    return this.tables.get(roomId) ?? null;
  }

  getTableByCode(code) {
    const wanted = String(code ?? '').toUpperCase();
    for (const table of this.tables.values()) {
      if (table.code === wanted) return table;
    }
    return null;
  }

  getTableForPlayer(userId) {
    const roomId = this.playerRooms.get(userId);
    return roomId ? this.getTable(roomId) : null;
  }

  listTables({ includePrivate = false, category = null } = {}) {
    return [...this.tables.values()]
      .filter((table) => includePrivate || !table.isPrivate)
      .filter((table) => !category || table.category === category)
      .map((table) => table.summary());
  }

  /** The stakes and categories the lobby offers, for the client to render. */
  static lobbyOptions() {
    return {
      categories: [TABLE_CATEGORY.SEEN, TABLE_CATEGORY.BLIND],
      stakes: config.game.tableStakes,
    };
  }

  // ----------------------------------------------------------------- joining

  /**
   * Seats a player at a table, creating one if every table at their stake is
   * full. Preference goes to the fullest table with room, so players cluster
   * into playable tables instead of scattering across half-empty ones.
   */
  quickJoin(user, { bootAmount = config.game.bootAmount, category } = {}) {
    this._assertNotSeated(user.id);
    RoomManager.assertStakeAllowed(bootAmount);

    const resolved = RoomManager.normalizeCategory(category);

    if (user.chips < bootAmount) {
      throw new GameError('insufficient_chips', 'Not enough chips to join this table');
    }

    // A table only matches when both the stake and the category line up — a
    // blind table and a seen table at the same stake are different rooms.
    const candidates = [...this.tables.values()]
      .filter(
        (table) =>
          !table.isPrivate &&
          !table.isFull &&
          table.config.bootAmount === bootAmount &&
          table.category === resolved,
      )
      .sort((a, b) => b.playerCount - a.playerCount);

    const table = candidates[0] ?? this.createTable({ bootAmount, category: resolved });
    return this.join(table, user);
  }

  joinByCode(user, code) {
    this._assertNotSeated(user.id);
    const table = this.getTableByCode(code);
    if (!table) throw new GameError('room_not_found', 'No table with that code');
    if (table.isFull) throw new GameError('table_full', 'That table is full');
    if (user.chips < table.config.bootAmount) {
      throw new GameError('insufficient_chips', 'Not enough chips to join this table');
    }
    return this.join(table, user);
  }

  join(table, user, socketId = null) {
    table.addPlayer({
      userId: user.id,
      displayName: user.displayName,
      avatarUrl: user.avatarUrl,
      chips: user.chips,
      socketId,
    });
    this.playerRooms.set(user.id, table.id);
    return table;
  }

  leave(userId, reason = 'left') {
    const table = this.getTableForPlayer(userId);
    if (!table) return null;

    table.removePlayer(userId, reason);
    this.playerRooms.delete(userId);

    if (table.isEmpty) this.destroyTable(table.id);
    return table;
  }

  _assertNotSeated(userId) {
    const existing = this.getTableForPlayer(userId);
    if (existing) {
      throw new GameError('already_in_room', 'You are already seated at a table');
    }
  }

  // ---------------------------------------------------------------- lifecycle

  destroyTable(roomId) {
    const table = this.tables.get(roomId);
    if (!table) return;
    for (const seat of table.occupiedSeats) this.playerRooms.delete(seat.userId);
    table.destroy();
    this.tables.delete(roomId);
    this.emit('tableDestroyed', roomId);
    logger.info('table destroyed', { roomId });
  }

  /** Reaps tables that are empty and idle, so long-running processes stay flat. */
  sweepEmptyTables() {
    const cutoff = Date.now() - 30_000;
    for (const table of [...this.tables.values()]) {
      if (table.isEmpty && table.state === TABLE_STATE.WAITING && table.createdAt < cutoff) {
        this.destroyTable(table.id);
      }
    }
  }

  stats() {
    const tables = [...this.tables.values()];
    return {
      tables: tables.length,
      players: this.playerRooms.size,
      activeHands: tables.filter((table) => table.hand).length,
    };
  }

  shutdown() {
    clearInterval(this._sweeper);
    for (const roomId of [...this.tables.keys()]) this.destroyTable(roomId);
  }
}

export default RoomManager;
