/**
 * A raw Engine.IO/Socket.IO WebSocket client built on the Unity parser port
 * (test/helpers/csharpJsonPort.js) — frame by frame, no socket.io-client, so
 * the protocol suite can assert on the exact bytes a server sends.
 *
 * Every socket opened here is registered so `closeOpenRawClients` can tear
 * down whatever a failing test left open (see harness.mjs).
 */
import { WebSocket } from 'ws';
import { wsUrl } from './harness.mjs';
import { PortedSocketIOClient } from '../../helpers/csharpJsonPort.js';

export { Json, PortedSocketIOClient } from '../../helpers/csharpJsonPort.js';

const openRaw = new Set();

/**
 * Opens a raw WebSocket to `/socket.io/?EIO=4&transport=websocket[&extra]`
 * and runs every frame through the ported client, replying as the C# code
 * would. `auto: false` leaves the CONNECT handshake to the caller.
 */
export async function openUnityLikeClient(token, { extraQuery = '', auto = true } = {}) {
  const url = `${wsUrl}/socket.io/?EIO=4&transport=websocket${extraQuery}`;
  const socket = new WebSocket(url);
  const client = new PortedSocketIOClient(token);
  const frames = [];
  const sent = [];

  socket.on('message', (data) => {
    const raw = data.toString();
    frames.push(raw);
    const reply = client.receive(raw);
    if (auto && reply !== null && reply !== undefined) {
      sent.push(reply);
      socket.send(reply);
    }
  });

  let closed = null;
  socket.on('close', (code, reason) => {
    closed = { code, reason: reason.toString() };
    openRaw.delete(handle);
  });
  socket.on('error', () => {});

  await new Promise((resolve, reject) => {
    socket.once('open', resolve);
    socket.once('error', reject);
    setTimeout(() => reject(new Error('ws connect timed out')), 4000);
  });

  const poll = (predicate, describe, timeoutMs) =>
    new Promise((resolve, reject) => {
      const started = Date.now();
      const tick = () => {
        const found = predicate();
        if (found !== undefined) return resolve(found);
        if (Date.now() - started > timeoutMs) {
          return reject(new Error(`timed out waiting for ${describe}; frames: ${frames.map((f) => f.slice(0, 80)).join(' | ')}`));
        }
        return setTimeout(tick, 20);
      };
      tick();
    });

  /** The latest event of this name (may be one that arrived before the call). */
  const waitFor = (name, timeoutMs = 4000) => poll(() => client.last(name), name, timeoutMs);

  /** The first event of this name recorded after `mark` (see `markEvents`). */
  const waitNew = (name, mark, timeoutMs = 4000) =>
    poll(() => client.events.slice(mark).find((entry) => entry.name === name)?.payload, `new ${name}`, timeoutMs);

  const waitFrame = (predicate, timeoutMs = 4000) =>
    poll(() => frames.find(predicate), 'a frame', timeoutMs);

  const waitConnected = async (timeoutMs = 4000) => {
    const started = Date.now();
    while (!client.connected) {
      if (client.connectError) throw new Error(`connect error: ${client.connectError}`);
      if (Date.now() - started > timeoutMs) throw new Error('socket.io connect timed out');
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  };

  const waitClosed = async (timeoutMs = 4000) => {
    const started = Date.now();
    while (!closed) {
      if (Date.now() - started > timeoutMs) throw new Error('socket did not close');
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    return closed;
  };

  const handle = {
    socket,
    client,
    frames,
    sent,
    waitFor,
    waitNew,
    waitFrame,
    waitConnected,
    waitClosed,
    markEvents: () => client.events.length,
    isClosed: () => closed,
    send: (frame) => { sent.push(frame); socket.send(frame); },
    emit: (event, payload = '{}', wantsAck = false) => {
      const frame = client.emit(event, payload, wantsAck);
      sent.push(frame);
      socket.send(frame);
      return frame;
    },
    close: () => {
      openRaw.delete(handle);
      if (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING) socket.close();
    },
  };
  openRaw.add(handle);
  return handle;
}

/** Closes every raw socket a suite still has open. Call from `test.after`. */
export const closeOpenRawClients = () => {
  for (const handle of [...openRaw]) handle.close();
};
