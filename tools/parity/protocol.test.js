/**
 * Raw wire parity: Engine.IO v4 + Socket.IO v5 frames as a hand-rolled client
 * (the Unity port in parity/lib/csharpJsonPort.js) sees them — OPEN packet,
 * CONNECT / CONNECT_ERROR, event and ack framing, ping/pong. Mirrors
 * socketProtocol.test.js (all 14 tests) and adds the byte-level assertions
 * from spec-socket-protocol.md §14.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  baseUrl, guestLogin, stakeCounter, isNode, isGo, signJwt, pause, CARD_CODE, ROOM_CODE, closeOpenClients,
} from './lib/harness.mjs';
import { Json, openUnityLikeClient, closeOpenRawClients } from './lib/raw.mjs';
import { WebSocket } from 'ws';

const uniqueStake = stakeCounter(300);

test.after(async () => {
  closeOpenRawClients();
  await closeOpenClients();
});

// -------------------------------------------------------------- unit: parser
// (The client's parser, pinned so a server frame that breaks it fails here.)

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
  assert.equal(JSON.parse(payload).you.cards.length, 3);
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

// ----------------------------------------------------------- handshake

test('the Engine.IO OPEN packet carries exactly the advertised transport parameters', async () => {
  const account = await guestLogin('device-proto-open-0001', 'Opener');
  const client = await openUnityLikeClient(account.token);
  await client.waitConnected();

  assert.ok(client.frames[0].startsWith('0{'), 'first frame is Engine.IO OPEN');
  const open = JSON.parse(client.frames[0].slice(1));
  assert.deepEqual(Object.keys(open).sort(), ['maxPayload', 'pingInterval', 'pingTimeout', 'sid', 'upgrades']);
  assert.equal(typeof open.sid, 'string');
  assert.ok(open.sid.length > 0 && !open.sid.includes('"'));
  assert.deepEqual(open.upgrades, []);
  assert.equal(open.pingInterval, 20000);
  assert.equal(open.pingTimeout, 25000);
  assert.equal(open.maxPayload, 100000);

  // The CONNECT ack is `40{"sid":...}` with a socket id distinct from the engine sid.
  const connectAck = client.frames.find((frame) => frame.startsWith('40'));
  assert.ok(connectAck, 'a 40 CONNECT reply arrived');
  const connectBody = JSON.parse(connectAck.slice(2));
  assert.deepEqual(Object.keys(connectBody), ['sid']);
  assert.notEqual(connectBody.sid, open.sid);

  // session:ready follows immediately as a 42 EVENT with exactly two array elements.
  const readyFrame = client.frames.find((frame) => frame.startsWith('42["session:ready"'));
  assert.ok(readyFrame, 'session:ready is the first event');
  const parsed = JSON.parse(readyFrame.slice(2));
  assert.equal(parsed.length, 2);
  assert.equal(parsed[0], 'session:ready');
  assert.deepEqual(Object.keys(parsed[1]), ['user', 'config'], 'user before config, no resume key');
  client.close();
});

test('the Unity handshake is accepted by the real server', async () => {
  const account = await guestLogin('device-proto-0001', 'UnityPlayer');
  const client = await openUnityLikeClient(account.token);
  await client.waitConnected();

  assert.ok(client.client.sid);
  assert.ok(client.client.pingIntervalMs > 0);
  assert.equal(client.client.connected, true);
  assert.ok(client.frames[0].startsWith('0{'));
  assert.deepEqual(client.sent, [`40{"token":"${account.token}"}`], 'the CONNECT the C# code sends');

  const ready = await client.waitFor('session:ready');
  // The scanner reads the first "id" in the frame — inside user, because user precedes config.
  assert.equal(Json.getString(ready, 'id', null), account.user.id);
  assert.equal(JSON.parse(ready).user.id, account.user.id);
  client.close();
});

test('a bad token is reported as a connect error the client can read, and the socket is not connected', async () => {
  const client = await openUnityLikeClient('not-a-real-token');
  const started = Date.now();
  while (!client.client.connectError && Date.now() - started < 4000) await pause(20);

  assert.ok(client.client.connectError, 'the CONNECT_ERROR frame was parsed');
  assert.match(client.client.connectError, /invalid_session|unauthorized|unknown_user/);
  assert.equal(client.client.connected, false);

  const frame = client.frames.find((f) => f.startsWith('44'));
  assert.deepEqual(JSON.parse(frame.slice(2)), { message: 'invalid_session' }, 'the code is the whole message; no data key');
  client.close();
});

test('each refusal code reaches the raw client: missing_token, invalid_session, unknown_user', async () => {
  // No token at all.
  const none = await openUnityLikeClient(undefined, { auto: false });
  await none.waitFrame((f) => f.startsWith('0{'));
  none.send('40');
  const noneErr = await none.waitFrame((f) => f.startsWith('44'));
  assert.deepEqual(JSON.parse(noneErr.slice(2)), { message: 'missing_token' });
  none.close();

  // Signed with the right secret for a user that does not exist.
  const now = Math.floor(Date.now() / 1000);
  const orphan = await signJwt({ sub: '00000000-0000-4000-8000-00000000dead', provider: 'guest', name: 'Ghost', iat: now, exp: now + 3600 });
  const ghost = await openUnityLikeClient(orphan);
  const ghostErr = await ghost.waitFrame((f) => f.startsWith('44'));
  assert.deepEqual(JSON.parse(ghostErr.slice(2)), { message: 'unknown_user' });
  ghost.close();

  // Signed with another secret.
  const foreign = await signJwt({ sub: 'x', provider: 'guest', name: 'x', iat: now, exp: now + 3600 }, 'another-secret');
  const forged = await openUnityLikeClient(foreign);
  const forgedErr = await forged.waitFrame((f) => f.startsWith('44'));
  assert.deepEqual(JSON.parse(forgedErr.slice(2)), { message: 'invalid_session' });
  forged.close();
});

test('the token may also travel as a ?token= query parameter on the handshake', async () => {
  const account = await guestLogin('device-proto-query-0001', 'Query');
  const client = await openUnityLikeClient(undefined, { extraQuery: `&token=${encodeURIComponent(account.token)}`, auto: false });
  await client.waitFrame((f) => f.startsWith('0{'));
  client.send('40');
  await client.waitFrame((f) => f.startsWith('40'));
  const ready = await client.waitFrame((f) => f.startsWith('42["session:ready"'));
  assert.equal(JSON.parse(ready.slice(2))[1].user.id, account.user.id);
  client.close();
});

test('the client answers Engine.IO pings so the server keeps the socket', async () => {
  const account = await guestLogin('device-proto-ping-0002', 'Pinger');
  const client = await openUnityLikeClient(account.token);
  await client.waitConnected();
  assert.equal(client.client.receive('2'), '3');
  assert.equal(client.client.receive('3'), null);
  client.close();
});

test('the Engine.IO endpoint refuses what is not a handshake, with the engine.io error envelope', async () => {
  // A plain GET on the websocket transport (no Upgrade header) is a bad request (engine.io code 3).
  const plain = await fetch(`${baseUrl}/socket.io/?EIO=4&transport=websocket`);
  assert.equal(plain.status, 400);
  assert.deepEqual(await plain.json(), { code: 3, message: 'Bad request' });

  // Engine.IO v3 is not spoken: a v3 websocket handshake never yields an OPEN packet.
  // (Node aborts the upgrade with an HTTP body after the 101, which `ws` reports as
  // a framing error; a clean close or a 400 are equally acceptable — the point is
  // that no `0{` frame ever arrives.)
  const outcome = await new Promise((resolve) => {
    const socket = new WebSocket(`${baseUrl.replace(/^http/, 'ws')}/socket.io/?EIO=3&transport=websocket`);
    const frames = [];
    socket.on('message', (data) => frames.push(data.toString()));
    socket.on('unexpected-response', (req, res) => resolve({ status: res.statusCode, frames }));
    socket.on('error', (error) => resolve({ error: error.message, frames }));
    socket.on('close', (code) => resolve({ close: code, frames }));
    setTimeout(() => { resolve({ timeout: true, frames }); socket.terminate(); }, 2000);
  });
  assert.ok(!outcome.frames.some((frame) => frame.startsWith('0{')), `EIO=3 must not be served an OPEN packet: ${JSON.stringify(outcome)}`);
  assert.ok(!outcome.timeout, 'the server answers an EIO=3 handshake one way or another');
});

test('long polling: accepted by Node, refused with code 0 by the Go port (DECISIONS.md §1)', async () => {
  const response = await fetch(`${baseUrl}/socket.io/?EIO=4&transport=polling&t=parity`);
  if (isNode) {
    assert.equal(response.status, 200);
    const text = await response.text();
    assert.ok(text.startsWith('0{'), 'an OPEN packet over polling');
  } else {
    assert.equal(response.status, 400);
    const body = await response.json();
    assert.equal(body.code, 0);
    assert.equal(body.message, 'Transport unknown');
  }
  const unknown = await fetch(`${baseUrl}/socket.io/?EIO=4&transport=carrier-pigeon`);
  assert.equal(unknown.status, 400);
  assert.deepEqual(await unknown.json(), { code: 0, message: 'Transport unknown' });
});

// ------------------------------------------------------------- gameplay

test('a full hand is readable end to end by the Unity parser', async () => {
  const alice = await guestLogin('device-proto-a-0010', 'ProtoA');
  const bob = await guestLogin('device-proto-b-0011', 'ProtoB');
  const bootAmount = uniqueStake();

  const ca = await openUnityLikeClient(alice.token);
  const cb = await openUnityLikeClient(bob.token);
  await ca.waitConnected();
  await cb.waitConnected();

  const sentA = ca.emit('room:quickJoin', `{"bootAmount":${bootAmount}}`, true);
  assert.equal(sentA, `421["room:quickJoin",{"bootAmount":${bootAmount}}]`, 'ack ids start at 1 in the port');
  cb.emit('room:quickJoin', `{"bootAmount":${bootAmount}}`, true);

  const joinAck = await ca.waitFor('ack:room:quickJoin');
  assert.equal(Json.getBool(joinAck, 'ok'), true);
  assert.match(Json.getString(joinAck, 'code'), ROOM_CODE);
  const ackFrame = ca.frames.find((f) => f.startsWith('431'));
  assert.ok(ackFrame, 'the ack frame is 43<id>[...]');
  const ackArgs = JSON.parse(ackFrame.slice(3));
  assert.equal(ackArgs.length, 1, 'the server acks with exactly one argument');
  assert.deepEqual(Object.keys(ackArgs[0]), ['ok', 'roomId', 'code', 'category']);

  const joined = await ca.waitFor('room:joined');
  assert.equal(Json.getInt(joined, 'maxPlayers'), 5);

  const started = await ca.waitFor('game:handStarted');
  assert.equal(Json.getInt(started, 'pot'), bootAmount * 2);
  assert.equal(Json.getInt(started, 'handNo'), 1);

  const turn = await ca.waitFor('game:turn');
  const onTurnUserId = Json.getString(turn, 'userId');
  const onTurn = onTurnUserId === alice.user.id ? ca : cb;
  const idle = onTurnUserId === alice.user.id ? cb : ca;

  const yourTurn = await onTurn.waitFor('game:yourTurn');
  const options = JSON.parse(yourTurn).options;
  assert.equal(options.chaal, bootAmount, 'a blind player can chaal the boot');
  assert.equal(options.raise, bootAmount * 2, 'or double it');
  assert.equal(options.canSee, true);
  assert.equal(idle.client.all('game:yourTurn').length, 0, 'only the player on turn is told the options');

  onTurn.emit('game:action', '{"action":"see"}');
  const cards = await onTurn.waitFor('player:cards');
  const parsedCards = JSON.parse(cards).cards;
  assert.equal(parsedCards.length, 3);
  for (const code of parsedCards) assert.match(code, CARD_CODE);
  assert.equal(idle.client.all('player:cards').length, 0, 'opponents never receive card faces');

  onTurn.emit('game:action', '{"action":"show"}');

  const showdown = await ca.waitFor('game:showdown');
  const reveals = JSON.parse(showdown).reveals;
  assert.equal(reveals.length, 2);
  for (const reveal of reveals) {
    assert.equal(reveal.cards.length, 3);
    assert.ok(typeof reveal.handName === 'string' && reveal.handName.length > 0);
  }

  const ended = await ca.waitFor('game:handEnded');
  assert.equal(Json.getInt(ended, 'pot'), bootAmount * 4);
  assert.ok(Json.getString(ended, 'winnerId'));
  assert.ok(Json.getString(ended, 'reason'));

  ca.emit('room:leave', '{}', true);
  cb.emit('room:leave', '{}', true);
  await ca.waitFor('ack:room:leave');
  await cb.waitFor('ack:room:leave');
  ca.close();
  cb.close();
});

test('a game error frame reaches the Unity client, as an ack and as game:error', async () => {
  const account = await guestLogin('device-proto-err-0020', 'ErrPlayer');
  const client = await openUnityLikeClient(account.token);
  await client.waitConnected();

  client.emit('game:action', '{"action":"chaal"}', true);
  const ack = await client.waitFor('ack:game:action');
  assert.equal(Json.getBool(ack, 'ok'), false);
  assert.equal(Json.getString(ack, 'code'), 'not_in_room');
  assert.ok(Json.getString(ack, 'message').length > 0);
  assert.deepEqual(JSON.parse(ack), { ok: false, code: 'not_in_room', message: 'You are not at a table' });

  const error = await client.waitFor('game:error');
  assert.deepEqual(JSON.parse(error), { code: 'not_in_room', message: 'You are not at a table' });

  // Ack first, then game:error, on the wire.
  const ackIndex = client.frames.findIndex((f) => f.startsWith('431'));
  const errIndex = client.frames.findIndex((f) => f.startsWith('42["game:error"'));
  assert.ok(ackIndex >= 0 && errIndex > ackIndex, 'the ack precedes the game:error frame');
  client.close();
});

test('ping:rtt is answered without an ok field and echoes sentAt verbatim', async () => {
  const account = await guestLogin('device-proto-rtt-0021', 'Rtt');
  const client = await openUnityLikeClient(account.token);
  await client.waitConnected();

  let mark = client.markEvents();
  client.emit('ping:rtt', '1730000000123', true);
  const ack = await client.waitNew('ack:ping:rtt', mark);
  const parsed = JSON.parse(ack);
  assert.deepEqual(Object.keys(parsed).sort(), ['sentAt', 'serverTime']);
  assert.equal(parsed.sentAt, 1730000000123);
  assert.ok(Math.abs(parsed.serverTime - Date.now()) < 5000);

  // Whatever the client sends as its first argument comes straight back.
  mark = client.markEvents();
  client.emit('ping:rtt', '{"nested":true}', true);
  const echoed = JSON.parse(await client.waitNew('ack:ping:rtt', mark));
  assert.deepEqual(echoed.sentAt, { nested: true });

  // The ack frame is 43<id>[{...}]: one argument, and a rising ack id.
  const rttFrames = client.frames.filter((f) => /^43\d+\[\{"sentAt"/.test(f));
  assert.equal(rttFrames.length, 2);
  const ids = rttFrames.map((f) => Number(/^43(\d+)/.exec(f)[1]));
  assert.ok(ids[1] > ids[0], `ack ids rise: ${ids}`);
  client.close();
});

test('room chat frames are readable by the Unity parser', async () => {
  const alice = await guestLogin('device-proto-chat-a-0040', 'ChatProtoA');
  const bob = await guestLogin('device-proto-chat-b-0041', 'ChatProtoB');
  const bootAmount = uniqueStake();

  const ca = await openUnityLikeClient(alice.token);
  await ca.waitConnected();
  ca.emit('room:quickJoin', `{"bootAmount":${bootAmount}}`, true);
  const joinAck = await ca.waitFor('ack:room:quickJoin');
  const code = Json.getString(joinAck, 'code');

  const history = await ca.waitFor('chat:history');
  assert.ok(Array.isArray(JSON.parse(history).messages));

  ca.emit('chat:message', '{"text":"hello table"}');
  const posted = await ca.waitFor('chat:message');
  assert.equal(Json.getString(posted, 'text'), 'hello table');
  assert.equal(Json.getString(posted, 'displayName'), 'ChatProtoA');
  assert.equal(Json.getBool(posted, 'system'), false, 'the key is absent, so the fallback applies');
  assert.ok(JSON.parse(posted).at > 0);
  assert.deepEqual(Object.keys(JSON.parse(posted)).sort(), ['at', 'displayName', 'id', 'roomId', 'text', 'userId']);

  const cb = await openUnityLikeClient(bob.token);
  await cb.waitConnected();
  cb.emit('room:joinCode', `{"code":"${code}"}`, true);

  const backlog = await cb.waitFor('chat:history');
  const messages = JSON.parse(backlog).messages;
  assert.ok(messages.some((message) => message.text === 'hello table'));
  assert.ok(messages.some((message) => message.system === true));

  ca.emit('room:leave', '{}', true);
  cb.emit('room:leave', '{}', true);
  await ca.waitFor('ack:room:leave');
  await cb.waitFor('ack:room:leave');
  ca.close();
  cb.close();
});

test('chat text with quotes and braces round-trips through the parser', async () => {
  const account = await guestLogin('device-proto-chat-x-0050', 'Tricky');
  const client = await openUnityLikeClient(account.token);
  await client.waitConnected();
  client.emit('room:quickJoin', `{"bootAmount":${uniqueStake()}}`, true);
  await client.waitFor('ack:room:quickJoin');

  const tricky = 'nice {trail} "wp" [gg]';
  client.emit('chat:message', `{"text":"${Json.escape(tricky)}"}`);

  const posted = await client.waitFor('chat:message', 4000);
  assert.equal(Json.getString(posted, 'text'), tricky);
  assert.equal(JSON.parse(posted).text, tricky);

  client.emit('room:leave', '{}', true);
  await client.waitFor('ack:room:leave');
  client.close();
});

test('a display name with quotes and braces survives the round trip', async () => {
  const tricky = 'Raj "Ace" {x}';
  const account = await guestLogin('device-proto-name-0030', tricky);
  const client = await openUnityLikeClient(account.token);
  await client.waitConnected();

  const ready = await client.waitFor('session:ready');
  assert.equal(JSON.parse(ready).user.displayName, tricky);
  assert.equal(Json.getString(ready, 'displayName'), tricky);
  client.close();
});

test('non-ASCII text is emitted raw (UTF-8), not \\u-escaped, and stays valid JSON', async () => {
  const account = await guestLogin('device-proto-utf8-0031', 'सूरज');
  const client = await openUnityLikeClient(account.token);
  await client.waitConnected();
  const ready = await client.waitFor('session:ready');
  assert.equal(JSON.parse(ready).user.displayName, 'सूरज');
  assert.ok(ready.includes('सूरज'), 'the frame carries the characters themselves');
  client.close();
});

test('a client 41 DISCONNECT ends the session; the seat is held for the grace period and restored on reconnect', async () => {
  const account = await guestLogin('device-proto-bye-0060', 'Bye');
  const client = await openUnityLikeClient(account.token);
  await client.waitConnected();
  client.emit('room:quickJoin', `{"bootAmount":${uniqueStake()}}`, true);
  await client.waitFor('ack:room:quickJoin');

  const socketsBefore = (await (await fetch(`${baseUrl}/health`)).json()).sockets;
  client.send('41');
  await pause(50);

  // Reconnecting inside the grace window restores the seat unrequested.
  const again = await openUnityLikeClient(account.token);
  await again.waitConnected();
  const joined = await again.waitFor('room:joined');
  assert.ok(Json.getString(joined, 'roomId'));
  const ready = await again.waitFor('session:ready');
  assert.equal(JSON.parse(ready).resume, undefined, 'a held seat means no resume offer');

  // The old namespace session is over: nothing sent on it is answered any
  // more, and /health no longer counts it. (The transport itself may stay
  // open — Socket.IO leaves closing it to the client — so nothing here waits
  // for a close frame.)
  const mark = client.markEvents();
  client.emit('ping:rtt', '1', true);
  await pause(300);
  assert.equal(client.client.events.slice(mark).length, 0, 'no ack after 41');
  const socketsAfter = (await (await fetch(`${baseUrl}/health`)).json()).sockets;
  assert.ok(socketsAfter <= socketsBefore, `health.sockets ${socketsBefore} → ${socketsAfter}: the old session is not counted`);
  client.close();

  again.emit('room:leave', '{}', true);
  await again.waitFor('ack:room:leave');
  again.close();
});

test('an unknown event name is never acked (the client must time out on its own)', async () => {
  const account = await guestLogin('device-proto-unknown-0070', 'Unknown');
  const client = await openUnityLikeClient(account.token);
  await client.waitConnected();
  client.emit('lobby:teleport', '{}', true);
  await pause(400);
  assert.equal(client.client.last('ack:lobby:teleport'), undefined);
  assert.equal(client.isClosed(), null, 'and the socket is still open');
  client.emit('ping:rtt', '1', true);
  await client.waitFor('ack:ping:rtt');
  client.close();
});

test(`target is ${isGo ? 'go' : 'node'} (recorded for the report)`, () => {
  assert.ok(isNode || isGo);
});
