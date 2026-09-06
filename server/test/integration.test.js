import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// The config module snapshots the environment at import time, so everything
// this suite needs has to be set before the server is loaded.
const dbFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'teenpatti-test-')), 'test.db');
process.env.NODE_ENV = 'test';
process.env.DB_FILE = dbFile;
process.env.JWT_SECRET = 'integration-test-secret';
process.env.AUTH_ALLOW_FAKE_PROVIDERS = 'true';
process.env.WELCOME_CHIPS = '200000';
process.env.BOOT_AMOUNT = '100';
process.env.TURN_TIMEOUT_MS = '1200';
process.env.NEXT_HAND_DELAY_MS = '150';
process.env.RECONNECT_GRACE_MS = '400';
process.env.PORT = '0';
// Lift the lobby's fixed stakes so each test can use its own boot amount for
// isolation — quick-join matches on stake, so a unique one keeps tests apart.
process.env.TABLE_STAKES = '';

const { createServer } = await import('../src/index.js');
const { io: connect } = await import('socket.io-client');
const { closeDatabase } = await import('../src/db/index.js');

let server;
let io;
let baseUrl;
let rooms;

test.before(async () => {
  const created = await createServer();
  server = created.server;
  io = created.io;
  rooms = created.rooms;
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

test.after(async () => {
  rooms.shutdown();
  // Sockets have to be torn down before the HTTP server will close.
  await new Promise((resolve) => io.close(resolve));
  server.closeAllConnections?.();
  await new Promise((resolve) => server.close(resolve));
  closeDatabase();
  fs.rmSync(path.dirname(dbFile), { recursive: true, force: true });
});

/**
 * Quick-join matches players by stake, so giving each test its own boot amount
 * keeps it off tables left over from earlier tests — a disconnected player
 * keeps their seat for the reconnect grace period, which is intended behaviour
 * in production but would otherwise leak between cases here.
 */
let nextStake = 100;
const uniqueStake = () => {
  nextStake += 50;
  return nextStake;
};

// ------------------------------------------------------------------ helpers

const login = async (body) => {
  const response = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return { status: response.status, body: await response.json() };
};

const guestLogin = async (deviceId, displayName) => {
  const { body } = await login({ provider: 'guest', deviceId, displayName });
  return body;
};

/** Connects a socket and returns a small event-recording client. */
const openClient = async (token) => {
  const socket = connect(baseUrl, { auth: { token }, transports: ['websocket'], forceNew: true });
  const seen = [];

  for (const event of [
    'session:ready', 'room:joined', 'room:state', 'game:handStarted', 'game:turn',
    'game:yourTurn', 'game:action', 'game:showdown', 'game:handEnded', 'player:cards',
    'game:error', 'session:replaced', 'chat:message', 'chat:history',
  ]) {
    socket.on(event, (payload) => seen.push({ event, payload }));
  }

  await new Promise((resolve, reject) => {
    socket.once('connect', resolve);
    socket.once('connect_error', reject);
    setTimeout(() => reject(new Error('connect timed out')), 4000);
  });

  return {
    socket,
    seen,
    last: (event) => [...seen].reverse().find((entry) => entry.event === event)?.payload,
    all: (event) => seen.filter((entry) => entry.event === event).map((entry) => entry.payload),
    /** Resolves when `event` arrives (or immediately if it already has). */
    wait: (event, predicate = () => true, timeoutMs = 4000) =>
      new Promise((resolve, reject) => {
        const existing = seen.find((entry) => entry.event === event && predicate(entry.payload));
        if (existing) return resolve(existing.payload);
        const timer = setTimeout(() => reject(new Error(`timed out waiting for ${event}`)), timeoutMs);
        const handler = (payload) => {
          if (!predicate(payload)) return;
          clearTimeout(timer);
          socket.off(event, handler);
          resolve(payload);
        };
        socket.on(event, handler);
        return undefined;
      }),
    emit: (event, payload) =>
      new Promise((resolve) => socket.emit(event, payload ?? {}, (ack) => resolve(ack))),
    /** Leaves the table before disconnecting so the seat is freed immediately. */
    close: async () => {
      await new Promise((resolve) => socket.emit('room:leave', {}, resolve));
      socket.disconnect();
    },
  };
};

const closeAll = (...clients) => Promise.all(clients.map((client) => client.close()));

// --------------------------------------------------------------------- auth

test('guest login creates an account with the welcome chip grant', async () => {
  const result = await guestLogin('device-guest-0001', 'Suraj');

  assert.ok(result.token);
  assert.equal(result.isNew, true);
  assert.equal(result.welcomeChips, 200000);
  assert.equal(result.user.chips, 200000, 'a first-time player is granted 2 lakh chips');
  assert.equal(result.user.provider, 'guest');
  assert.equal(result.user.displayName, 'Suraj');
});

test('logging in again from the same device returns the same saved account', async () => {
  const first = await guestLogin('device-returning-0002', 'Returning');
  const second = await guestLogin('device-returning-0002', 'Returning');

  assert.equal(second.isNew, false);
  assert.equal(second.welcomeChips, 0, 'the grant is only ever made once');
  assert.equal(second.user.id, first.user.id, 'the account is persisted and reused');
  assert.equal(second.user.chips, first.user.chips);
});

test('a different device is a different account', async () => {
  const a = await guestLogin('device-alpha-0003', 'Alpha');
  const b = await guestLogin('device-beta-0004', 'Beta');
  assert.notEqual(a.user.id, b.user.id);
});

test('the raw device id is never stored', async () => {
  // Read straight from the database file the server is writing to.
  const { getDatabase } = await import('../src/db/index.js');
  const stored = getDatabase()
    .prepare('SELECT provider_user_id FROM users WHERE provider = ?')
    .all('guest');

  assert.ok(stored.length > 0);
  for (const row of stored) {
    assert.notEqual(row.provider_user_id, 'device-guest-0001');
    assert.match(row.provider_user_id, /^[0-9a-f]{64}$/, 'device ids are stored hashed');
  }
});

test('a short or missing device id is rejected', async () => {
  const short = await login({ provider: 'guest', deviceId: 'abc' });
  assert.equal(short.status, 400);
  assert.equal(short.body.error, 'invalid_device_id');

  const missing = await login({ provider: 'guest' });
  assert.equal(missing.status, 400);
});

test('an unknown provider is rejected', async () => {
  const result = await login({ provider: 'myspace', deviceId: 'device-xxxx-9999' });
  assert.equal(result.status, 400);
  assert.equal(result.body.error, 'unknown_provider');
});

test('google and facebook logins create provider-scoped accounts', async () => {
  // AUTH_ALLOW_FAKE_PROVIDERS lets the suite exercise the account plumbing
  // without live Google/Facebook credentials; real tokens are verified in prod.
  const google = await login({ provider: 'google', providerUserId: 'google-sub-123', displayName: 'G Player' });
  const facebook = await login({ provider: 'facebook', providerUserId: 'fb-123', displayName: 'F Player' });

  assert.equal(google.status, 200);
  assert.equal(google.body.user.provider, 'google');
  assert.equal(google.body.user.chips, 200000);

  assert.equal(facebook.status, 200);
  assert.equal(facebook.body.user.provider, 'facebook');
  assert.notEqual(google.body.user.id, facebook.body.user.id, 'same id on two providers is two accounts');

  const again = await login({ provider: 'google', providerUserId: 'google-sub-123', displayName: 'G Player' });
  assert.equal(again.body.user.id, google.body.user.id, 'the google account is reused on next login');
});

test('/api/auth/me returns the persisted profile', async () => {
  const { token, user } = await guestLogin('device-me-0005', 'MeCheck');
  const response = await fetch(`${baseUrl}/api/auth/me`, {
    headers: { authorization: `Bearer ${token}` },
  });
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(body.user.id, user.id);
  assert.equal(body.user.chips, 200000);
});

test('a bad session token is refused', async () => {
  const response = await fetch(`${baseUrl}/api/auth/me`, { headers: { authorization: 'Bearer nonsense' } });
  assert.equal(response.status, 401);
});

// ------------------------------------------------------------------ sockets

test('a socket without a valid token cannot connect', async () => {
  const socket = connect(baseUrl, { auth: { token: 'garbage' }, transports: ['websocket'], forceNew: true });
  const error = await new Promise((resolve) => socket.once('connect_error', resolve));
  assert.match(error.message, /invalid_session|unauthorized/);
  socket.disconnect();
});

test('two players quick-join the same table and a hand is dealt', async () => {
  const alice = await guestLogin('device-play-a-0010', 'Alice');
  const bob = await guestLogin('device-play-b-0011', 'Bob');

  const ca = await openClient(alice.token);
  const cb = await openClient(bob.token);
  const bootAmount = uniqueStake();

  const joinA = await ca.emit('room:quickJoin', { bootAmount });
  const joinB = await cb.emit('room:quickJoin', { bootAmount });

  assert.equal(joinA.ok, true);
  assert.equal(joinB.ok, true);
  assert.equal(joinA.roomId, joinB.roomId, 'quick join clusters players onto one table');

  const started = await ca.wait('game:handStarted');
  assert.equal(started.participants.length, 2);
  assert.equal(started.pot, bootAmount * 2, 'both players anted the boot');

  const state = await ca.wait('room:state', (payload) => payload.state === 'betting');
  assert.equal(state.maxPlayers, 5);
  assert.equal(state.minPlayers, 2);
  assert.deepEqual(state.you.cards, [], 'cards stay hidden until you look');

  await closeAll(ca, cb);
});

test('a full hand plays out: see, bet, show, and the pot is paid', async () => {
  const alice = await guestLogin('device-hand-a-0020', 'HandA');
  const bob = await guestLogin('device-hand-b-0021', 'HandB');

  const clients = {
    [alice.user.id]: await openClient(alice.token),
    [bob.user.id]: await openClient(bob.token),
  };

  const bootAmount = uniqueStake();
  await clients[alice.user.id].emit('room:quickJoin', { bootAmount });
  await clients[bob.user.id].emit('room:quickJoin', { bootAmount });

  const ca = clients[alice.user.id];
  await ca.wait('game:handStarted');

  // Whoever is on turn sees their cards, then calls a show to end the hand.
  const turn = await ca.wait('game:turn');
  const onTurn = clients[turn.userId];

  const seeResult = await onTurn.emit('game:action', { action: 'see' });
  assert.equal(seeResult.ok, true);

  const cards = await onTurn.wait('player:cards');
  assert.equal(cards.cards.length, 3, 'you receive exactly your own three cards');

  // The other player must not have received them.
  const other = Object.values(clients).find((client) => client !== onTurn);
  assert.equal(other.all('player:cards').length, 0, 'card faces are never sent to opponents');

  const showResult = await onTurn.emit('game:action', { action: 'show' });
  assert.equal(showResult.ok, true);

  const ended = await ca.wait('game:handEnded');
  assert.ok(ended.winnerId, 'the hand has exactly one winner');
  // Two boots, plus a seen player's show (twice the stake).
  assert.equal(ended.pot, bootAmount * 4);
  assert.equal(ended.reveals.length, 2, 'both hands were revealed at the show');

  // The winner's balance is persisted, not just held in memory.
  const winnerToken = ended.winnerId === alice.user.id ? alice.token : bob.token;
  const profile = await (
    await fetch(`${baseUrl}/api/auth/me`, { headers: { authorization: `Bearer ${winnerToken}` } })
  ).json();
  assert.ok(profile.user.chips > 200000, 'winnings were written to the database');
  assert.equal(profile.user.handsWon, 1);
  assert.equal(profile.user.handsPlayed, 1);

  await closeAll(...Object.values(clients));
});

test('acting out of turn returns an error to the client', async () => {
  const a = await guestLogin('device-turn-a-0030', 'TurnA');
  const b = await guestLogin('device-turn-b-0031', 'TurnB');
  const ca = await openClient(a.token);
  const cb = await openClient(b.token);

  const bootAmount = uniqueStake();
  await ca.emit('room:quickJoin', { bootAmount });
  await cb.emit('room:quickJoin', { bootAmount });
  const turn = await ca.wait('game:turn');

  const waiting = turn.userId === a.user.id ? cb : ca;
  const result = await waiting.emit('game:action', { action: 'chaal' });

  assert.equal(result.ok, false);
  assert.equal(result.code, 'not_your_turn');

  await closeAll(ca, cb);
});

test('a player who stalls past the turn timer is packed and the other wins', async () => {
  const a = await guestLogin('device-slow-a-0040', 'SlowA');
  const b = await guestLogin('device-slow-b-0041', 'SlowB');
  const ca = await openClient(a.token);
  const cb = await openClient(b.token);

  const bootAmount = uniqueStake();
  await ca.emit('room:quickJoin', { bootAmount });
  await cb.emit('room:quickJoin', { bootAmount });
  const turn = await ca.wait('game:turn');

  // Nobody acts. The stalling player is packed, leaving one player standing.
  const ended = await ca.wait('game:handEnded', () => true, 5000);

  assert.notEqual(ended.winnerId, turn.userId, 'the player who timed out does not win');
  assert.equal(ended.reason, 'last_standing');

  const packAction = ca.all('game:action').find((action) => action.reason === 'timeout');
  assert.ok(packAction, 'the timeout pack was broadcast');

  await closeAll(ca, cb);
});

test('a table holds at most five players and a sixth opens a new one', async () => {
  const clients = [];
  const roomIds = new Set();
  const bootAmount = uniqueStake();

  for (let i = 0; i < 6; i += 1) {
    const account = await guestLogin(`device-cap-${i}-0050`, `Cap${i}`);
    const client = await openClient(account.token);
    clients.push(client);
    const result = await client.emit('room:quickJoin', { bootAmount });
    assert.equal(result.ok, true);
    roomIds.add(result.roomId);
  }

  assert.equal(roomIds.size, 2, 'the sixth player is seated at a second table');

  const counts = [...roomIds].map((id) => rooms.getTable(id).playerCount).sort();
  assert.deepEqual(counts, [1, 5], 'the first table filled to exactly five');

  await closeAll(...clients);
});

test('a private room can be created and joined by its code', async () => {
  const host = await guestLogin('device-code-a-0060', 'Host');
  const guest = await guestLogin('device-code-b-0061', 'Guest');
  const ch = await openClient(host.token);
  const cg = await openClient(guest.token);

  const created = await ch.emit('room:create', { isPrivate: true });
  assert.equal(created.ok, true);
  assert.match(created.code, /^[A-Z2-9]{6}$/);

  const joined = await cg.emit('room:joinCode', { code: created.code });
  assert.equal(joined.ok, true);
  assert.equal(joined.roomId, created.roomId);

  const bad = await cg.emit('room:joinCode', { code: 'ZZZZZZ' });
  assert.equal(bad.ok, false);

  await closeAll(ch, cg);
});

test('leaving a room frees the seat', async () => {
  const account = await guestLogin('device-leave-0070', 'Leaver');
  const client = await openClient(account.token);

  const joined = await client.emit('room:quickJoin', { bootAmount: uniqueStake() });
  assert.equal(rooms.getTable(joined.roomId).playerCount, 1);

  await client.emit('room:leave', {});
  assert.equal(rooms.getTableForPlayer(account.user.id), null);

  await client.close();
});

test('a second sign-in replaces the first session', async () => {
  const account = await guestLogin('device-dup-0080', 'Dup');
  const first = await openClient(account.token);
  const second = await openClient(account.token);

  const replaced = await first.wait('session:replaced');
  assert.ok(replaced.message);

  await second.close();
});

// -------------------------------------------------- blind / seen categories

test('blind and seen tables at the same stake are separate rooms', async () => {
  const a = await guestLogin('device-cat-a-0200', 'BlindPlayer');
  const b = await guestLogin('device-cat-b-0201', 'SeenPlayer');

  const ca = await openClient(a.token);
  const cb = await openClient(b.token);
  const bootAmount = uniqueStake();

  const blind = await ca.emit('room:quickJoin', { bootAmount, category: 'blind' });
  const seen = await cb.emit('room:quickJoin', { bootAmount, category: 'seen' });

  assert.equal(blind.ok, true);
  assert.equal(seen.ok, true);
  assert.equal(blind.category, 'blind');
  assert.equal(seen.category, 'seen');
  assert.notEqual(blind.roomId, seen.roomId, 'the categories never share a table');

  await closeAll(ca, cb);
});

test('on a seen table a player can see everyone\'s chips', async () => {
  const a = await guestLogin('device-cat-seen-a-0210', 'SeenA');
  const b = await guestLogin('device-cat-seen-b-0211', 'SeenB');

  const ca = await openClient(a.token);
  const cb = await openClient(b.token);
  const bootAmount = uniqueStake();

  await ca.emit('room:quickJoin', { bootAmount, category: 'seen' });
  await cb.emit('room:quickJoin', { bootAmount, category: 'seen' });

  const state = await ca.wait('room:state', (payload) =>
    payload.seats.filter((seat) => seat.userId).length === 2);

  assert.equal(state.category, 'seen');
  assert.equal(state.chipsHidden, false);

  for (const seat of state.seats.filter((entry) => entry.userId)) {
    assert.equal(typeof seat.chips, 'number', `${seat.displayName}'s stack is visible`);
    assert.ok(seat.chips > 0);
  }

  await closeAll(ca, cb);
});

test('on a blind table you see only your own chips', async () => {
  const a = await guestLogin('device-cat-blind-a-0220', 'BlindA');
  const b = await guestLogin('device-cat-blind-b-0221', 'BlindB');

  const ca = await openClient(a.token);
  const cb = await openClient(b.token);
  const bootAmount = uniqueStake();

  await ca.emit('room:quickJoin', { bootAmount, category: 'blind' });
  await cb.emit('room:quickJoin', { bootAmount, category: 'blind' });

  const state = await ca.wait('room:state', (payload) =>
    payload.seats.filter((seat) => seat.userId).length === 2);

  assert.equal(state.category, 'blind');
  assert.equal(state.chipsHidden, true);

  const mine = state.seats.find((seat) => seat.userId === a.user.id);
  const theirs = state.seats.find((seat) => seat.userId === b.user.id);

  assert.equal(typeof mine.chips, 'number', 'your own stack is visible');
  assert.equal(theirs.chips, null, "the other player's stack is withheld");

  // No occupied seat other than your own carries a stack figure at all.
  // (categories.test.js makes the same point byte-for-byte on the wire, with
  // distinct balances — here both players start on the same 200,000.)
  for (const seat of state.seats.filter((entry) => entry.userId && entry.userId !== a.user.id)) {
    assert.equal(seat.chips, null, `${seat.displayName}'s stack must not be sent`);
  }

  await closeAll(ca, cb);
});

test('the lobby offers the configured categories and stakes', async () => {
  const account = await guestLogin('device-cat-lobby-0230', 'Lobby');
  const client = await openClient(account.token);

  const ready = await client.wait('session:ready');
  assert.deepEqual(ready.config.categories, ['seen', 'blind']);
  assert.ok(Array.isArray(ready.config.stakes));

  const listed = await client.emit('lobby:list', {});
  assert.equal(listed.ok, true);
  assert.ok(Array.isArray(listed.tables));
  assert.ok(Array.isArray(listed.options.categories));

  await client.close();
});

test('the lobby can be filtered to one category', async () => {
  const account = await guestLogin('device-cat-filter-0240', 'Filter');
  const client = await openClient(account.token);
  const bootAmount = uniqueStake();

  await client.emit('room:quickJoin', { bootAmount, category: 'blind' });

  const blindOnly = await client.emit('lobby:list', { category: 'blind' });
  const seenOnly = await client.emit('lobby:list', { category: 'seen' });

  assert.ok(blindOnly.tables.every((table) => table.category === 'blind'));
  assert.ok(seenOnly.tables.every((table) => table.category === 'seen'));
  assert.ok(blindOnly.tables.some((table) => table.bootAmount === bootAmount));

  await client.close();
});

test('an unknown category is treated as seen rather than hiding chips', async () => {
  const account = await guestLogin('device-cat-bad-0250', 'BadCat');
  const client = await openClient(account.token);

  const joined = await client.emit('room:quickJoin', {
    bootAmount: uniqueStake(),
    category: 'sneaky',
  });

  assert.equal(joined.ok, true);
  assert.equal(joined.category, 'seen', 'never hide chips by accident');

  await client.close();
});

// ---------------------------------------------------------------- room chat

test('a chat message reaches everyone in the room and nobody outside it', async () => {
  const a = await guestLogin('device-chat-a-0090', 'ChatA');
  const b = await guestLogin('device-chat-b-0091', 'ChatB');
  const outsider = await guestLogin('device-chat-c-0092', 'Outsider');

  const ca = await openClient(a.token);
  const cb = await openClient(b.token);
  const cc = await openClient(outsider.token);

  const roomStake = uniqueStake();
  await ca.emit('room:quickJoin', { bootAmount: roomStake });
  await cb.emit('room:quickJoin', { bootAmount: roomStake });
  // The outsider sits at a different table entirely.
  await cc.emit('room:quickJoin', { bootAmount: uniqueStake() });

  await ca.emit('chat:message', { text: 'good luck all' });

  const received = await cb.wait('chat:message', (payload) => payload.text === 'good luck all');
  assert.equal(received.displayName, 'ChatA');
  assert.equal(received.userId, a.user.id);
  assert.ok(received.at > 0);

  // Give any stray delivery a chance to land before asserting it did not.
  await new Promise((resolve) => setTimeout(resolve, 150));
  assert.ok(
    !cc.all('chat:message').some((message) => message.text === 'good luck all'),
    'a player at another table never sees the message',
  );

  await closeAll(ca, cb, cc);
});

test('a player joining later is sent the room backlog', async () => {
  const a = await guestLogin('device-chat-hist-a-0100', 'HistA');
  const b = await guestLogin('device-chat-hist-b-0101', 'HistB');

  const ca = await openClient(a.token);
  const roomStake = uniqueStake();
  const joined = await ca.emit('room:quickJoin', { bootAmount: roomStake });

  await ca.emit('chat:message', { text: 'first message' });
  await ca.emit('chat:message', { text: 'second message' });

  // A different player joins the same table afterwards.
  const cb = await openClient(b.token);
  await cb.emit('room:joinCode', { code: joined.code });

  const history = await cb.wait('chat:history');
  const texts = history.messages.map((message) => message.text);

  assert.ok(texts.includes('first message'), 'the backlog survived for the new player');
  assert.ok(texts.includes('second message'));
  assert.ok(texts.includes('HistA joined the table'), 'system lines are part of the log');
  assert.equal(history.roomId, joined.roomId);

  await closeAll(ca, cb);
});

test('room chat history is capped at 100 messages', async () => {
  const account = await guestLogin('device-chat-cap-0110', 'Capper');
  const ca = await openClient(account.token);
  const joined = await ca.emit('room:quickJoin', { bootAmount: uniqueStake() });

  // Post past the cap directly on the table: the socket path is rate limited
  // on purpose, and the cap itself is what is under test here.
  const table = rooms.getTable(joined.roomId);
  for (let i = 1; i <= 130; i += 1) table.postChat(account.user.id, `spam ${i}`);

  await ca.emit('chat:history', {});
  const history = await ca.wait('chat:history', (payload) => payload.messages.length >= 100);

  assert.equal(history.messages.length, 100, 'never more than 100 messages are kept');
  assert.equal(history.messages.at(-1).text, 'spam 130', 'the newest message is retained');
  assert.ok(
    !history.messages.some((message) => message.text === 'spam 1'),
    'the oldest messages were dropped',
  );

  await ca.close();
});

test('chat history dies with the room when the last player leaves', async () => {
  const account = await guestLogin('device-chat-gone-0120', 'Ghost');
  const ca = await openClient(account.token);

  const joined = await ca.emit('room:quickJoin', { bootAmount: uniqueStake() });
  await ca.emit('chat:message', { text: 'anyone around?' });
  assert.ok(rooms.getTable(joined.roomId).chatHistory().length > 0);

  await ca.emit('room:leave', {});

  // The last player leaving destroys the table, and the history with it.
  assert.equal(rooms.getTable(joined.roomId), null, 'the empty room was removed');

  // A new player quick-joining the same stake gets a brand new room and log.
  const cb = await openClient((await guestLogin('device-chat-new-0121', 'Fresh')).token);
  const rejoined = await cb.emit('room:quickJoin', { bootAmount: uniqueStake() });
  const history = await cb.wait('chat:history');

  assert.notEqual(rejoined.roomId, joined.roomId);
  assert.ok(
    !history.messages.some((message) => message.text === 'anyone around?'),
    'nothing carried over from the deleted room',
  );

  await closeAll(ca, cb);
});

test('a player who is not at a table cannot chat', async () => {
  const account = await guestLogin('device-chat-nope-0130', 'Loner');
  const client = await openClient(account.token);

  const result = await client.emit('chat:message', { text: 'hello?' });
  assert.equal(result.ok, false);
  assert.equal(result.code, 'not_in_room');

  await client.close();
});

test('chat flooding is rate limited', async () => {
  const account = await guestLogin('device-chat-flood-0140', 'Flooder');
  const client = await openClient(account.token);
  await client.emit('room:quickJoin', { bootAmount: uniqueStake() });

  const results = [];
  for (let i = 0; i < 12; i += 1) {
    results.push(await client.emit('chat:message', { text: `flood ${i}` }));
  }

  assert.ok(results.some((result) => result.ok === false), 'the flood was cut off');
  assert.ok(
    results.some((result) => result.code === 'chat_rate_limited'),
    'and reported as a chat rate limit',
  );
  assert.ok(results.filter((result) => result.ok).length >= 3, 'normal chatting still works');

  await client.close();
});

test('empty chat messages are ignored', async () => {
  const account = await guestLogin('device-chat-empty-0150', 'Quiet');
  const client = await openClient(account.token);
  const joined = await client.emit('room:quickJoin', { bootAmount: uniqueStake() });

  const before = rooms.getTable(joined.roomId).chatHistory().length;
  const result = await client.emit('chat:message', { text: '   ' });

  assert.equal(result.ok, true);
  assert.equal(result.messageId, undefined, 'nothing was stored');
  assert.equal(rooms.getTable(joined.roomId).chatHistory().length, before);

  await client.close();
});

test('health reports live table and player counts', async () => {
  const body = await (await fetch(`${baseUrl}/health`)).json();
  assert.equal(body.ok, true);
  assert.equal(typeof body.tables, 'number');
  assert.equal(typeof body.players, 'number');
});
