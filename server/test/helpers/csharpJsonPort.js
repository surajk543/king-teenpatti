/**
 * A line-by-line JavaScript port of the `Json` helper and packet dispatch in
 * unity-client/Assets/Scripts/Net/SocketIOClient.cs.
 *
 * The Unity client cannot be compiled in CI, but its Socket.IO framing is the
 * part most likely to break against a real server. Porting the exact algorithm
 * lets `socketProtocol.test.js` drive it with genuine frames captured from this
 * server, so a protocol regression fails the build instead of the game.
 *
 * Keep this file in step with the C# original — if you change one, change both.
 */

const skipWhitespace = (json, index) => {
  while (index < json.length && /\s/.test(json[index])) index += 1;
  return index;
};

const findStringEnd = (json, quoteIndex) => {
  for (let i = quoteIndex + 1; i < json.length; i += 1) {
    if (json[i] === '\\') {
      i += 1;
      continue;
    }
    if (json[i] === '"') return i;
  }
  return -1;
};

const findValueEnd = (json, start) => {
  if (start >= json.length) return -1;

  const c = json[start];
  if (c === '"') {
    const end = findStringEnd(json, start);
    return end < 0 ? -1 : end + 1;
  }

  if (c === '{' || c === '[') {
    const open = c;
    const close = c === '{' ? '}' : ']';
    let depth = 0;
    let inString = false;

    for (let i = start; i < json.length; i += 1) {
      const ch = json[i];

      if (inString) {
        if (ch === '\\') i += 1;
        else if (ch === '"') inString = false;
        continue;
      }

      if (ch === '"') inString = true;
      else if (ch === open) depth += 1;
      else if (ch === close) {
        depth -= 1;
        if (depth === 0) return i + 1;
      }
    }
    return -1;
  }

  let scan = start;
  while (scan < json.length && json[scan] !== ',' && json[scan] !== ']' && json[scan] !== '}') scan += 1;
  return scan;
};

const unescape = (value) => {
  if (!value.includes('\\')) return value;
  let out = '';
  for (let i = 0; i < value.length; i += 1) {
    if (value[i] !== '\\') {
      out += value[i];
      continue;
    }
    i += 1;
    if (i >= value.length) break;
    switch (value[i]) {
      case 'n': out += '\n'; break;
      case 'r': out += '\r'; break;
      case 't': out += '\t'; break;
      case 'u': {
        const code = Number.parseInt(value.slice(i + 1, i + 5), 16);
        if (Number.isFinite(code)) {
          out += String.fromCharCode(code);
          i += 4;
        }
        break;
      }
      default: out += value[i]; break;
    }
  }
  return out;
};

const elementAt = (array, wanted) => {
  let index = skipWhitespace(array, 1);
  let element = 0;

  while (index < array.length && array[index] !== ']') {
    const end = findValueEnd(array, index);
    if (end < 0) return null;

    if (element === wanted) return array.slice(index, end).trim();

    element += 1;
    index = skipWhitespace(array, end);
    if (index < array.length && array[index] === ',') index = skipWhitespace(array, index + 1);
  }
  return null;
};

export const Json = {
  escape(value) {
    if (!value) return '';
    let out = '';
    for (const c of value) {
      if (c === '"') out += '\\"';
      else if (c === '\\') out += '\\\\';
      else if (c === '\n') out += '\\n';
      else if (c === '\r') out += '\\r';
      else if (c === '\t') out += '\\t';
      else if (c.charCodeAt(0) < 0x20) out += `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`;
      else out += c;
    }
    return out;
  },

  firstArrayString(array) {
    const index = skipWhitespace(array, 1);
    if (index >= array.length || array[index] !== '"') return null;
    const end = findStringEnd(array, index);
    if (end < 0) return null;
    return unescape(array.slice(index + 1, end));
  },

  firstArrayElement: (array) => elementAt(array, 0),
  secondArrayElement: (array) => elementAt(array, 1),

  getString(json, field, fallback = null) {
    const key = `"${field}"`;
    let index = json.indexOf(key);
    if (index < 0) return fallback;
    index = json.indexOf(':', index + key.length);
    if (index < 0) return fallback;
    index = skipWhitespace(json, index + 1);
    if (index >= json.length || json[index] !== '"') return fallback;
    const end = findStringEnd(json, index);
    return end < 0 ? fallback : unescape(json.slice(index + 1, end));
  },

  getInt(json, field, fallback = 0) {
    const key = `"${field}"`;
    let index = json.indexOf(key);
    if (index < 0) return fallback;
    index = json.indexOf(':', index + key.length);
    if (index < 0) return fallback;
    index = skipWhitespace(json, index + 1);
    let end = index;
    while (end < json.length && (/[0-9]/.test(json[end]) || json[end] === '-')) end += 1;
    const value = Number.parseInt(json.slice(index, end), 10);
    return Number.isFinite(value) ? value : fallback;
  },

  getBool(json, field, fallback = false) {
    const key = `"${field}"`;
    let index = json.indexOf(key);
    if (index < 0) return fallback;
    index = json.indexOf(':', index + key.length);
    if (index < 0) return fallback;
    index = skipWhitespace(json, index + 1);
    if (json.startsWith('true', index)) return true;
    if (json.startsWith('false', index)) return false;
    return fallback;
  },
};

/**
 * The port of SocketIOClient's frame dispatch. Feed it raw Engine.IO frames;
 * it returns the reply the C# client would send (or null) and records events.
 */
export class PortedSocketIOClient {
  constructor(authToken) {
    this.authJson = `{"token":"${Json.escape(authToken)}"}`;
    this.events = [];
    this.acks = new Map();
    this.nextAckId = 1;
    this.connected = false;
    this.pingIntervalMs = 45000;
    this.connectSent = false;
    this.sent = [];
  }

  emit(eventName, payload = '{}', wantsAck = false) {
    if (!wantsAck) {
      const frame = `42["${Json.escape(eventName)}",${payload}]`;
      this.sent.push(frame);
      return frame;
    }
    const ackId = this.nextAckId;
    this.nextAckId += 1;
    this.acks.set(ackId, eventName);
    const frame = `42${ackId}["${Json.escape(eventName)}",${payload}]`;
    this.sent.push(frame);
    return frame;
  }

  /** Handles one raw frame; returns the frame to send back, or null. */
  receive(raw) {
    if (!raw) return null;

    switch (raw[0]) {
      case '0':
        return this.handleEngineOpen(raw.slice(1));
      case '2':
        return '3'; // PING -> PONG
      case '3':
        return null;
      case '4':
        return this.handleSocketIoPacket(raw.slice(1));
      default:
        return null;
    }
  }

  handleEngineOpen(json) {
    this.sid = Json.getString(json, 'sid');
    this.pingIntervalMs = Json.getInt(json, 'pingInterval', 25000) + Json.getInt(json, 'pingTimeout', 20000);
    if (this.connectSent) return null;
    this.connectSent = true;
    return `40${this.authJson}`;
  }

  handleSocketIoPacket(body) {
    if (body.length === 0) return null;
    const type = body[0];
    const rest = body.slice(1);

    switch (type) {
      case '0':
        this.connected = true;
        this.namespaceSid = Json.getString(rest, 'sid');
        return null;
      case '1':
        this.connected = false;
        return null;
      case '4':
        this.connectError = Json.getString(rest, 'message', rest);
        return null;
      case '2':
        this.handleEvent(rest);
        return null;
      case '3':
        this.handleAck(rest);
        return null;
      default:
        return null;
    }
  }

  handleEvent(rest) {
    const bracket = rest.indexOf('[');
    if (bracket < 0) return;
    const array = rest.slice(bracket);
    const name = Json.firstArrayString(array);
    if (name === null) return;
    const payload = Json.secondArrayElement(array) ?? '{}';
    this.events.push({ name, payload });
  }

  handleAck(rest) {
    const bracket = rest.indexOf('[');
    if (bracket <= 0) return;
    const ackId = Number.parseInt(rest.slice(0, bracket), 10);
    if (!this.acks.has(ackId)) return;
    const eventName = this.acks.get(ackId);
    this.acks.delete(ackId);
    const payload = Json.firstArrayElement(rest.slice(bracket)) ?? '{}';
    this.events.push({ name: `ack:${eventName}`, payload });
  }

  last(name) {
    return [...this.events].reverse().find((entry) => entry.name === name)?.payload;
  }

  all(name) {
    return this.events.filter((entry) => entry.name === name).map((entry) => entry.payload);
  }
}

export default { Json, PortedSocketIOClient };
