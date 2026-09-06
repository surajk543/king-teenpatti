import config from '../config/index.js';
import { uuid } from '../util/ids.js';

/**
 * In-memory chat history for one room.
 *
 * Deliberately never persisted: the log lives with the table object, so it is
 * visible to whoever is in the room (including someone who joins later), and it
 * disappears the moment the room does — which is when the last player leaves.
 * Nothing here touches SQLite.
 *
 * The buffer is capped, so a long-lived table cannot grow without bound.
 */
export class RoomChat {
  constructor({ maxHistory = config.chat.maxHistory, maxLength = config.chat.maxLength } = {}) {
    this.maxHistory = maxHistory;
    this.maxLength = maxLength;
    /** @type {Array<{id: string, userId: string, displayName: string, text: string, at: number}>} */
    this.messages = [];
  }

  /**
   * Sanitises and appends a message, dropping the oldest once the cap is hit.
   * Returns the stored message, or null when there was nothing left to send.
   */
  add({ userId, displayName, text }) {
    const clean = RoomChat.sanitize(text, this.maxLength);
    if (!clean) return null;

    const message = {
      id: uuid(),
      userId,
      displayName,
      text: clean,
      at: Date.now(),
    };

    this.messages.push(message);
    if (this.messages.length > this.maxHistory) {
      this.messages.splice(0, this.messages.length - this.maxHistory);
    }

    return message;
  }

  /** Appends a system line (a player joining, leaving, and so on). */
  addSystem(text) {
    const message = {
      id: uuid(),
      userId: null,
      displayName: 'Table',
      text: String(text).slice(0, this.maxLength),
      at: Date.now(),
      system: true,
    };

    this.messages.push(message);
    if (this.messages.length > this.maxHistory) {
      this.messages.splice(0, this.messages.length - this.maxHistory);
    }

    return message;
  }

  /** The history a joining player is shown, oldest first. */
  history() {
    return this.messages.slice();
  }

  get size() {
    return this.messages.length;
  }

  clear() {
    this.messages.length = 0;
  }

  /**
   * Strips control characters (which could smuggle escape sequences into a
   * client), collapses runaway whitespace, and trims to the length cap.
   */
  static sanitize(text, maxLength = config.chat.maxLength) {
    return String(text ?? '')
      .replace(/[\p{C}]/gu, ' ')
      .replace(/\s+/g, ' ')
      .trim()
      .slice(0, maxLength);
  }
}

export default RoomChat;
