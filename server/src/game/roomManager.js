import { EventEmitter } from 'node:events';
import Table, { GameError } from './table.js';
import { TABLE_CATEGORY, TABLE_STATE } from './constants.js';
import config from '../config/index.js';
import { uuid, roomCode } from '../util/ids.js';
import { settleHand, applyChipDelta } from '../db/users.js';
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
  constructor({ settle = settleHand, persistChips = applyChipDelta, timers } = {}) {
    super();
    /** @type {Map<string, Table>} */
    this.tables = new Map();
    /** @type {Map<string, string>} userId -> roomId */
    this.playerRooms = new Map();
    this.settle = settle;

    /**
     * Banks a chip movement as it happens, so a bet is gone from the account
     * the moment it is made rather than at the end of the hand.
     */
    this.persistChips = persistChips;
    this.timers = timers;

    this._sweeper = setInterval(() => {
      this.consolidateTables();
      this.sweepEmptyTables();
    }, config.game.consolidateIntervalMs);
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

    // Requirement 22: a private table's boot is fixed, not chosen. Whatever a
    // client asks for is replaced, so there is no stake to validate and no way
    // to open a room at some other amount.
    const boot = isPrivate ? config.game.privateBoot : bootAmount;

    // Requirement 19: seen tables allow a single double per turn and force a
    // showdown after 7 rounds. Blind tables keep the open-ended ladder.
    const categoryRules = resolved === TABLE_CATEGORY.SEEN
      ? {
          maxRaiseSteps: config.game.seenMaxRaiseSteps,
          maxBetRounds: config.game.seenMaxBetRounds,
        }
      : {};

    // Requirement 22: a private table caps its pot and allows a single double
    // per turn, whichever category it is.
    const privateRules = isPrivate
      ? {
          maxPot: config.game.privateMaxPot,
          maxRaiseSteps: config.game.privateMaxRaiseSteps,
        }
      : {};

    const table = new Table({
      id,
      code: roomCode(),
      config: {
        ...config.game,
        ...categoryRules,
        ...privateRules,
        bootAmount: boot,
        category: resolved,
        chatMaxHistory: config.chat.maxHistory,
        chatMaxLength: config.chat.maxLength,
      },
      settle: this.settle,
      persistChips: this.persistChips,
      timers: this.timers,
    });

    table.isPrivate = isPrivate;
    table.on('error', (error) => logger.error('table error', { roomId: id, error: error.message }));

    this.tables.set(id, table);
    this.emit('tableCreated', table);
    logger.info('table created', {
      roomId: id,
      code: table.code,
      bootAmount: boot,
      category: resolved,
      isPrivate,
      maxPot: table.maxPot || null,
    });
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
      /** Requirement 30: which table is capped, and at what stack. */
      entryCapBoot: config.game.entryCapBoot,
      entryCapCategory: config.game.entryCapCategory,
      entryCapMaxChips: config.game.entryCapMaxChips,
      /** Requirement 22: a private table's fixed boot and its pot ceiling. */
      privateBoot: config.game.privateBoot,
      privateMaxPot: config.game.privateMaxPot,
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
    this._assertUnderEntryCap(user, { bootAmount, category: resolved });

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
    // A private table is somewhere you were invited, so the cap does not apply.
    if (!table.isPrivate) {
      this._assertUnderEntryCap(user, {
        bootAmount: table.config.bootAmount,
        category: table.category,
      });
    }
    return this.join(table, user);
  }

  /**
   * Moves a seated player to another table of the same kind.
   *
   * The entry cap (requirement 30) is deliberately *not* applied here. It
   * guards the way in from the lobby; a player already sitting at a table of
   * this stake and category was admitted under it, and a switch is a sideways
   * move rather than a new entry.
   *
   * That is safe because the server decides what a switch is, not the client:
   * the target must be a public table with the same boot and category as the
   * one the player is already seated at. There is no way to reach the capped
   * table this way without having been let into an equivalent one first.
   *
   * Leaving and seating happen together so the player is never standing: a
   * failure throws before their seat is given up.
   */
  switchTable(user) {
    const current = this.getTableForPlayer(user.id);
    if (!current) throw new GameError('not_in_room', 'You are not at a table');
    if (current.isPrivate) {
      throw new GameError('private_table', 'A private table cannot be swapped for another');
    }

    const bootAmount = current.config.bootAmount;
    const { category } = current;

    const target = [...this.tables.values()]
      .filter(
        (table) =>
          !table.isPrivate &&
          !table.isFull &&
          table.id !== current.id &&
          table.config.bootAmount === bootAmount &&
          table.category === category,
      )
      // The fullest table with room, which is how everyone else is seated too.
      .sort((a, b) => b.playerCount - a.playerCount)[0];

    if (!target) {
      throw new GameError(
        'no_other_table',
        `No other ${category} table at this stake has a free seat right now`,
      );
    }

    // "moved" rather than "left", so the departure does not trigger a merge of
    // the table being left while the player is between seats.
    this.leave(user.id, 'moved');
    return { from: current, table: this.join(target, user) };
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

    if (table.isEmpty) {
      this.destroyTable(table.id);
    } else if (reason !== 'moved') {
      // A departure is exactly when a table can drop to a single player, so
      // check for a merge right away rather than waiting for the next sweep.
      this.consolidateTables();
    }

    return table;
  }

  /**
   * Requirement 30: the cheapest blind table is capped, so a player carrying a
   * big stack cannot sit down at it.
   *
   * Checked on every route into a seat rather than only in the lobby: the
   * lobby greys the table out, but a client is never what enforces a rule.
   */
  _assertUnderEntryCap(user, { bootAmount, category }) {
    const cap = config.game.entryCapMaxChips;
    if (!cap) return;
    if (bootAmount !== config.game.entryCapBoot) return;
    if (category !== config.game.entryCapCategory) return;
    if (user.chips <= cap) return;

    throw new GameError(
      'over_entry_cap',
      `Players with more than ${cap.toLocaleString('en-US')} chips cannot join this table`,
    );
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

  /**
   * Merges tables that have dwindled to a single player (requirement 24).
   *
   * Two rooms each left with one player are two rooms where nobody can play, so
   * the stragglers are pulled together onto one table. Only idle tables are
   * touched: a table with a hand in progress is never disturbed, which is what
   * stops a player being moved out from under a live game.
   *
   * Returns the moves that were made, for logging and tests.
   */
  consolidateTables() {
    const singles = [...this.tables.values()].filter(
      (table) =>
        !table.isPrivate &&
        !table.hand &&
        table.state === TABLE_STATE.WAITING &&
        table.playerCount === 1,
    );

    // Only tables of the same kind can be merged — a player must not be moved
    // to a different stake or category than the one they chose.
    const groups = new Map();
    for (const table of singles) {
      const key = `${table.category}:${table.config.bootAmount}`;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(table);
    }

    const moves = [];

    for (const group of groups.values()) {
      // The longest-standing table is the destination, so the room that has
      // been advertised longest is the one that fills up.
      group.sort((a, b) => a.createdAt - b.createdAt);
      const target = group[0];

      for (const source of group.slice(1)) {
        if (target.isFull) break;
        const move = this._movePlayer(source, target);
        if (move) moves.push(move);
      }
    }

    return moves;
  }

  /**
   * Moves the sole occupant of `source` onto `target` and disposes of the empty
   * room. Both tables must be idle; the caller checks that.
   */
  _movePlayer(source, target) {
    const seat = source.occupiedSeats[0];
    if (!seat || source.hand || target.hand || target.isFull) return null;

    const player = {
      id: seat.userId,
      displayName: seat.displayName,
      avatarUrl: seat.avatarUrl,
      chips: seat.chips,
    };
    const socketId = seat.socketId;
    const fromRoomId = source.id;

    source.removePlayer(player.id, 'moved');
    this.playerRooms.delete(player.id);

    try {
      this.join(target, player, socketId);
    } catch (error) {
      // The destination filled up between the check and the move; put the
      // player back rather than dropping them.
      logger.warn('table consolidation failed, restoring seat', { error: error.message });
      this.join(source, player, socketId);
      return null;
    }

    if (source.isEmpty) this.destroyTable(fromRoomId);

    const move = { userId: player.id, fromRoomId, toRoomId: target.id };
    this.emit('playerMoved', move);
    logger.info('player moved to a busier table', move);
    return move;
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
