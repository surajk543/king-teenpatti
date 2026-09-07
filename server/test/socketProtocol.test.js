/**
 * Drives the Unity client's Socket.IO framing against the real server.
 *
 * A raw WebSocket connects to the Engine.IO endpoint and every frame is handed
 * to `PortedSocketIOClient` — the JavaScript port of the C# in
 * SocketIOClient.cs. If the Unity client's parser could not read a real frame,
 * or its handshake were malformed, these tests fail.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { WebSocket } from 'ws';

// The config module snapshots the environment at import time, so everything
// this suite needs has to be set before the server is loaded. The suite gets a
// throwaway Postgres schema of its own, dropped again in test.after.
process.env.NODE_ENV = 'test';
process.env.PG_SCHEMA = `test_proto_${Math.random().toString(36).slice(2, 8)}`;
process.env.JWT_SECRET = 'protocol-test-secret';
process.env.AUTH_ALLOW_FAKE_PROVIDERS = 'true';
process.env.BOOT_AMOUNT = '100';
process.env.TURN_TIMEOUT_MS = '3000';
process.env.NEXT_HAND_DELAY_MS = '150';
// Lift the lobby's fixed stakes so each test can use its own boot amount for
// isolation — quick-join matches on stake, so a unique one keeps tests apart.
process.env.TABLE_STAKES = '';
// ...and with it the menu of category/stake pairs, for the same reason.
process.env.LOBBY_TABLES = '';

const { createServer } = await import('../src/index.js');
const { dropSchema, closeDatabase } = await import('../src/db/index.js');
const { Json, PortedSocketIOClient } = await import('./helpers/csharpJsonPort.js');

let server;
let io;
let rooms;
let baseUrl;

test.before(async () => {
  const created = await createServer();
  server = created.server;
  io = created.io;
  rooms = created.rooms;
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

test.after(async () => {
  // Live hands are settled (their pots paid out) before the pool closes.
  await rooms.shutdown();
  await new Promise((resolve) => io.close(resolve));
  server.closeAllConnections?.();
  await new Promise((resolve) => server.close(resolve));
  await dropSchema();
  await closeDatabase();
});

const guestLogin = async (deviceId, displayName) => {
  const response = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ provider: 'guest', deviceId, displayName }),
  });
  return response.json();
};

/**
 * Opens a raw WebSocket and runs every frame through the ported Unity client,
 * replying exactly as the C# code would.
 */
async function openUnityLikeClient(token) {
  const wsUrl = `${baseUrl.replace('http://', 'ws://')}/socket.io/?EIO=4&transport=websocket`;
  const socket = new WebSocket(wsUrl);
  const client = new PortedSocketIOClient(token);
  const frames = [];

  socket.on('message', (data) => {
    const raw = data.toString();
    frames.push(raw);
    const reply = client.receive(raw);
    if (reply !== null && reply !== undefined) socket.send(reply);
  });

  await new Promise((resolve, reject) => {
    socket.once('open', resolve);
    socket.once('error', reject);
    setTimeout(() => reject(new Error('ws connect timed out')), 4000);
  });

  const waitFor = (name, timeoutMs = 4000) =>
    new Promise((resolve, reject) => {
      const started = Date.now();
      const tick = () => {
        const found = client.last(name);
        if (found !== undefined) return resolve(found);
        if (Date.now() - started > timeoutMs) return reject(new Error(`timed out waiting for ${name}`));
        return setTimeout(tick, 20);
      };
      tick();
    });

  const waitConnected = async () => {
    const started = Date.now();
    while (!client.connected) {
      if (Date.now() - started > 4000) throw new Error('socket.io connect timed out');
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  };

  return {
    socket,
    client,
    frames,
    waitFor,
    waitConnected,
    emit: (event, payload, wantsAck = false) => socket.send(client.emit(event, payload, wantsAck)),
    close: () => socket.close(),
  };
}

// -------------------------------------------------------------- unit: parser

test('the ported parser splits a Socket.IO event envelope', () => {
  const array = '["game:turn",{"userId":"abc","seatIndex":2,"deadline":1730000000000}]';
  assert.equal(Json.firstArrayString(array), 'game:turn');
  const payload = Json.secondArrayElement(array);
  assert.equal(Json.getString(payload, 'userId'), 'abc');
  assert.equal(Json.getInt(payload, 'seatIndex'), 2);
});

test('braces and brackets inside strings do not confuse the splitter', () => {
  const array = '["chat:message",{"text":"gg [nice] {hand} \\"wp\\"","userId":"u1"}]';
  assert.equal(Json.firstArrayString(array), 'chat:message');
  const payload = Json.secondArrayElement(array);
  assert.equal(Json.getString(payload, 'userId'), 'u1');
  assert.equal(Json.getString(payload, 'text'), 'gg [nice] {hand} "wp"');
});

test('nested objects and arrays are extracted whole', () => {
  const array =
    '["room:state",{"seats":[{"seatIndex":0,"chips":100},{"seatIndex":1}],"you":{"cards":["As","Kh","Qd"]}}]';
  const payload = Json.secondArrayElement(array);
  assert.ok(payload.startsWith('{') && payload.endsWith('}'));
  assert.equal(JSON.parse(payload).you.cards.length, 3, 'the payload is still valid JSON');
  assert.equal(JSON.parse(payload).seats.length, 2);
});

test('escaped quotes and unicode survive a round trip', () => {
  const name = 'Raj "The Ace" éü';
  const array = `["session:ready",{"name":"${Json.escape(name)}"}]`;
  assert.equal(Json.getString(Json.secondArrayElement(array), 'name'), name);
});

test('an event with no payload does not break the splitter', () => {
  const array = '["room:left"]';
  assert.equal(Json.firstArrayString(array), 'room:left');
  assert.equal(Json.secondArrayElement(array), null);
});

test('booleans and negative numbers parse', () => {
  const payload = '{"isNew":true,"blind":false,"delta":-1500,"pot":0}';
  assert.equal(Json.getBool(payload, 'isNew'), true);
  assert.equal(Json.getBool(payload, 'blind'), false);
  assert.equal(Json.getInt(payload, 'delta'), -1500);
  assert.equal(Json.getInt(payload, 'pot'), 0);
});

// ------------------------------------------------------ integration: handshake

test('the Unity handshake is accepted by the real server', async () => {
  const account = await guestLogin('device-proto-0001', 'UnityPlayer');
  const client = await openUnityLikeClient(account.token);

  await client.waitConnected();

  // The Engine.IO OPEN frame was understood.
  assert.ok(client.client.sid, 'the session id was read from the OPEN frame');
  assert.ok(client.client.pingIntervalMs > 0);

  // And the server accepted the "40{token}" CONNECT the C# code sends.
  assert.equal(client.client.connected, true);
  assert.ok(client.frames[0].startsWith('0{'), 'first frame is Engine.IO OPEN');

  const ready = await client.waitFor('session:ready');
  assert.equal(Json.getString(ready, 'id', null) ?? JSON.parse(ready).user.id, account.user.id);

  client.close();
});

test('a bad token is reported as a connect error the client can read', async () => {
  const client = await openUnityLikeClient('not-a-real-token');

  const started = Date.now();
  while (!client.client.connectError && Date.now() - started < 4000) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }

  assert.ok(client.client.connectError, 'the CONNECT_ERROR frame was parsed');
  assert.match(client.client.connectError, /invalid_session|unauthorized|unknown_user/);
  assert.equal(client.client.connected, false);

  client.close();
});

test('the client answers Engine.IO pings so the server keeps the socket', async () => {
  const account = await guestLogin('device-proto-ping-0002', 'Pinger');
  const client = await openUnityLikeClient(account.token);
  await client.waitConnected();

  // The dispatcher must answer a "2" with a "3", or the server drops us.
  assert.equal(client.client.receive('2'), '3');
  assert.equal(client.client.receive('3'), null);

  client.close();
});

// ----------------------------------------------------- integration: gameplay

test('a full hand is readable end to end by the Unity parser', async () => {
  const alice = await guestLogin('device-proto-a-0010', 'ProtoA');
  const bob = await guestLogin('device-proto-b-0011', 'ProtoB');

  const ca = await openUnityLikeClient(alice.token);
  const cb = await openUnityLikeClient(bob.token);
  await ca.waitConnected();
  await cb.waitConnected();

  // Acks come back through the C# ack path.
  ca.emit('room:quickJoin', '{"bootAmount":100}', true);
  cb.emit('room:quickJoin', '{"bootAmount":100}', true);

  const joinAck = await ca.waitFor('ack:room:quickJoin');
  assert.equal(Json.getBool(joinAck, 'ok'), true);
  assert.match(Json.getString(joinAck, 'code'), /^[A-Z2-9]{6}$/);

  const joined = await ca.waitFor('room:joined');
  assert.equal(Json.getInt(joined, 'maxPlayers'), 5);

  const started = await ca.waitFor('game:handStarted');
  assert.equal(Json.getInt(started, 'pot'), 200);
  assert.equal(Json.getInt(started, 'handNo'), 1);

  // Only the player on turn gets game:yourTurn, with the legal options.
  const turn = await ca.waitFor('game:turn');
  const onTurnUserId = Json.getString(turn, 'userId');
  const onTurn = onTurnUserId === alice.user.id ? ca : cb;

  const yourTurn = await onTurn.waitFor('game:yourTurn');
  const options = JSON.parse(yourTurn).options;
  assert.equal(options.chaal, 100, 'a blind player can chaal the boot');
  assert.equal(options.raise, 200, 'or double it');
  assert.equal(options.canSee, true);

  // See cards: the private player:cards frame must parse into three codes.
  onTurn.emit('game:action', '{"action":"see"}');
  const cards = await onTurn.waitFor('player:cards');
  const parsedCards = JSON.parse(cards).cards;
  assert.equal(parsedCards.length, 3);
  for (const code of parsedCards) assert.match(code, /^[2-9TJQKA][shdc]$/);

  const idle = onTurnUserId === alice.user.id ? cb : ca;
  assert.equal(idle.client.all('player:cards').length, 0, 'opponents never receive card faces');

  // Show ends the hand; the showdown and result frames must both parse.
  onTurn.emit('game:action', '{"action":"show"}');

  const showdown = await ca.waitFor('game:showdown');
  const reveals = JSON.parse(showdown).reveals;
  assert.equal(reveals.length, 2);
  for (const reveal of reveals) {
    assert.equal(reveal.cards.length, 3);
    assert.ok(typeof reveal.handName === 'string' && reveal.handName.length > 0);
  }

  const ended = await ca.waitFor('game:handEnded');
  assert.equal(Json.getInt(ended, 'pot'), 400);
  assert.ok(Json.getString(ended, 'winnerId'));
  assert.ok(Json.getString(ended, 'reason'));

  ca.close();
  cb.close();
});

test('a game error frame reaches the Unity client', async () => {
  const account = await guestLogin('device-proto-err-0020', 'ErrPlayer');
  const client = await openUnityLikeClient(account.token);
  await client.waitConnected();

  client.emit('game:action', '{"action":"chaal"}', true);
  const ack = await client.waitFor('ack:game:action');

  assert.equal(Json.getBool(ack, 'ok'), false);
  assert.equal(Json.getString(ack, 'code'), 'not_in_room');
  assert.ok(Json.getString(ack, 'message').length > 0);

  client.close();
});

test('room chat frames are readable by the Unity parser', async () => {
  const alice = await guestLogin('device-proto-chat-a-0040', 'ChatProtoA');
  const bob = await guestLogin('device-proto-chat-b-0041', 'ChatProtoB');

  const ca = await openUnityLikeClient(alice.token);
  await ca.waitConnected();
  ca.emit('room:quickJoin', '{"bootAmount":700}', true);
  const joinAck = await ca.waitFor('ack:room:quickJoin');
  const code = Json.getString(joinAck, 'code');

  // The backlog frame must parse into an array of messages.
  const history = await ca.waitFor('chat:history');
  assert.ok(Array.isArray(JSON.parse(history).messages));

  ca.emit('chat:message', '{"text":"hello table"}');
  const posted = await ca.waitFor('chat:message');
  assert.equal(Json.getString(posted, 'text'), 'hello table');
  assert.equal(Json.getString(posted, 'displayName'), 'ChatProtoA');
  assert.equal(Json.getBool(posted, 'system'), false);
  assert.ok(Json.getInt(posted, 'at') > 0 || JSON.parse(posted).at > 0);

  // A second player joins and must receive the backlog including that message.
  const cb = await openUnityLikeClient(bob.token);
  await cb.waitConnected();
  cb.emit('room:joinCode', `{"code":"${code}"}`, true);

  const backlog = await cb.waitFor('chat:history');
  const messages = JSON.parse(backlog).messages;
  assert.ok(messages.some((message) => message.text === 'hello table'), 'the new player sees the backlog');
  assert.ok(messages.some((message) => message.system === true), 'system lines parse too');

  ca.close();
  cb.close();
});

test('chat text with quotes and braces round-trips through the parser', async () => {
  const account = await guestLogin('device-proto-chat-x-0050', 'Tricky');
  const client = await openUnityLikeClient(account.token);
  await client.waitConnected();
  client.emit('room:quickJoin', '{"bootAmount":800}', true);
  await client.waitFor('ack:room:quickJoin');

  const tricky = 'nice {trail} "wp" [gg]';
  client.emit('chat:message', `{"text":"${Json.escape(tricky)}"}`);

  const posted = await client.waitFor('chat:message', 4000);
  assert.equal(Json.getString(posted, 'text'), tricky, 'the hand-rolled scanner reads it');
  assert.equal(JSON.parse(posted).text, tricky, 'and the frame is still valid JSON');

  client.close();
});

test('a display name with quotes and braces survives the round trip', async () => {
  const tricky = 'Raj "Ace" {x}';
  const account = await guestLogin('device-proto-name-0030', tricky);
  const client = await openUnityLikeClient(account.token);
  await client.waitConnected();

  const ready = await client.waitFor('session:ready');
  assert.equal(JSON.parse(ready).user.displayName, tricky, 'the frame is still valid JSON');
  // And the hand-rolled scanner reads it correctly too.
  assert.equal(Json.getString(ready, 'displayName'), tricky);

  client.close();
});
