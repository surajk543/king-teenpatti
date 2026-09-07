/**
 * Every rule lives on the server. These tests play the part of a client that
 * has been tampered with — or is simply confused — and check that each bad
 * request is refused with a clear code, changes nothing, and never brings the
 * table down for the honest players at it.
 */
import test from 'node:test';
import assert from 'node:assert/strict';

process.env.NODE_ENV = 'test';
process.env.PG_SCHEMA = `test_invalid_${Math.random().toString(36).slice(2, 8)}`;
process.env.JWT_SECRET = 'invalid-moves-test-secret';
process.env.AUTH_ALLOW_FAKE_PROVIDERS = 'true';
process.env.WELCOME_CHIPS = '200000';
process.env.BOOT_AMOUNT = '100';
process.env.TURN_TIMEOUT_MS = '60000';
process.env.NEXT_HAND_DELAY_MS = '150';
process.env.RECONNECT_GRACE_MS = '400';
process.env.SIDESHOW_TIMEOUT_MS = '60000';
process.env.TABLE_STAKES = '';
process.env.LOBBY_TABLES = '';

const { createServer } = await import('../src/index.js');
const { io: connect } = await import('socket.io-client');
const { query, dropSchema, closeDatabase } = await import('../src/db/index.js');
const { applyChipDelta } = await import('../src/db/users.js');

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
  await rooms.shutdown();
  await new Promise((resolve) => io.close(resolve));
  server.closeAllConnections?.();
  await new Promise((resolve) => server.close(resolve));
  await dropSchema();
  await closeDatabase();
});

let nextStake = 1000;
const uniqueStake = () => {
  nextStake += 50;
  return nextStake;
};

const guestLogin = async (deviceId, displayName) => {
  const response = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ provider: 'guest', deviceId, displayName }),
  });
  return response.json();
};

const openClient = async (token) => {
  const socket = connect(baseUrl, { auth: { token }, transports: ['websocket'], forceNew: true });
  const seen = [];
  for (const event of ['session:ready', 'room:joined', 'room:state', 'game:handStarted', 'game:error',
    'game:handEnded', 'game:showdown', 'player:cards', 'room:kicked', 'room:left', 'game:sideshowAsked']) {
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
    last: (event) => [...seen].reverse().find((e) => e.event === event)?.payload,
    wait: (event, predicate = () => true, timeoutMs = 4000) =>
      new Promise((resolve, reject) => {
        const existing = seen.find((e) => e.event === event && predicate(e.payload));
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
    /** Emits and resolves with the ack, whatever shape the payload is. */
    emit: (event, payload) =>
      new Promise((resolve) => socket.emit(event, payload, (ack) => resolve(ack))),
    close: async () => {
      await new Promise((resolve) => socket.emit('room:leave', {}, resolve));
      socket.disconnect();
    },
  };
};

const closeAll = (...clients) => Promise.all(clients.map((c) => c.close()));

/** Two players at a fresh table with a hand dealt; returns who is on turn. */
async function dealtTable(tag) {
  const bootAmount = uniqueStake();
  const a = await guestLogin(`device-${tag}-a`, 'Alice');
  const b = await guestLogin(`device-${tag}-b`, 'Bob');
  const ca = await openClient(a.token);
  const cb = await openClient(b.token);
  const joined = await ca.emit('room:quickJoin', { bootAmount });
  await cb.emit('room:quickJoin', { bootAmount });
  const started = await ca.wait('game:handStarted');
  const table = rooms.getTable(joined.roomId);
  const turnUserId = table.seats[table.hand.turnSeat].userId;
  const [onTurn, waiting] = turnUserId === a.user.id ? [ca, cb] : [cb, ca];
  const onTurnUser = turnUserId === a.user.id ? a.user : b.user;
  const waitingUser = turnUserId === a.user.id ? b.user : a.user;
  return { bootAmount, ca, cb, onTurn, waiting, onTurnUser, waitingUser, table, joined, started };
}

const ledgerSum = async (userId) => {
  const { rows } = await query('SELECT COALESCE(SUM(delta), 0) AS total FROM chip_ledger WHERE user_id = $1', [userId]);
  return rows[0].total;
};

const wallet = async (userId) => {
  const { rows } = await query('SELECT chips FROM users WHERE id = $1', [userId]);
  return rows[0].chips;
};

// --------------------------------------------------------------- gameplay

test('acting out of turn is refused and the turn does not move', async () => {
  const { waiting, onTurn, table } = await dealtTable('oot');
  const before = table.hand.turnSeat;

  for (const action of ['chaal', 'pack', 'show', 'sideshow']) {
    const ack = await waiting.emit('game:action', { action, amount: table.hand.stake, actionId: `oot-${action}` });
    assert.equal(ack.ok, false, `${action} out of turn`);
    assert.equal(ack.code, 'not_your_turn');
  }
  assert.equal(table.hand.turnSeat, before, 'the turn is where it was');
  await closeAll(onTurn, waiting);
});

test('a bet that is not on the ladder is refused, whatever the figure', async () => {
  const { onTurn, waiting, onTurnUser, table } = await dealtTable('ladder');
  const potBefore = table.hand.pot;
  const walletBefore = await wallet(onTurnUser.id);

  const bad = [
    table.hand.stake + 1,   // not a rung
    table.hand.stake * 3,   // between rungs
    -table.hand.stake,      // negative
    0,
    1,
    1e15,                   // absurdly large
    walletBefore + 1,       // one more than they hold
  ];
  for (const amount of bad) {
    const ack = await onTurn.emit('game:action', { action: 'chaal', amount, actionId: `ladder-${amount}` });
    assert.equal(ack.ok, false, `chaal ${amount} was accepted`);
    assert.ok(['invalid_bet', 'insufficient_chips'].includes(ack.code), `${amount} -> ${ack.code}`);
  }
  assert.equal(table.hand.pot, potBefore, 'the pot has not moved');
  assert.equal(await wallet(onTurnUser.id), walletBefore, 'the wallet has not moved');
  await closeAll(onTurn, waiting);
});

test('a bet amount that is not a number at all is refused before it reaches the table', async () => {
  const { onTurn, waiting, table } = await dealtTable('nan');
  const potBefore = table.hand.pot;

  // NaN and Infinity cannot cross the wire — JSON turns them into null, and a
  // null amount is the ordinary "chaal at the stake" — so they are left out.
  // Every other shape here would coerce to a legal figure if the server used
  // Number(), and must be refused instead.
  for (const amount of [String(table.hand.stake), 'abc', 1.5, { amount: 100 }, [table.hand.stake], true]) {
    const ack = await onTurn.emit('game:action', { action: 'chaal', amount, actionId: `nan-${JSON.stringify(amount)}` });
    assert.equal(ack.ok, false, `amount ${JSON.stringify(amount)} was accepted`);
    assert.equal(ack.code, 'invalid_bet');
  }
  assert.equal(table.hand.pot, potBefore);
  await closeAll(onTurn, waiting);
});

test('an unknown action, or one from a player at no table, is refused', async () => {
  const { onTurn, waiting } = await dealtTable('unknown');
  let ack = await onTurn.emit('game:action', { action: 'allin', actionId: 'unknown-1' });
  assert.equal(ack.ok, false);
  assert.equal(ack.code, 'unknown_action');

  ack = await onTurn.emit('game:action', { action: '__proto__', actionId: 'unknown-2' });
  assert.equal(ack.ok, false);

  const loner = await guestLogin('device-unknown-c', 'Cara');
  const cl = await openClient(loner.token);
  ack = await cl.emit('game:action', { action: 'pack', actionId: 'unknown-3' });
  assert.equal(ack.ok, false);
  assert.equal(ack.code, 'not_in_room');
  await closeAll(onTurn, waiting, cl);
});

test('a show with more than two players in the hand is refused', async () => {
  const bootAmount = uniqueStake();
  const players = await Promise.all([1, 2, 3].map((i) => guestLogin(`device-show3-${i}`, `P${i}`)));
  const clients = [];
  for (const p of players) {
    const c = await openClient(p.token);
    await c.emit('room:quickJoin', { bootAmount });
    clients.push(c);
  }
  await clients[0].wait('game:handStarted');
  const table = rooms.getTableForPlayer(players[0].user.id);
  const turnUser = table.seats[table.hand.turnSeat].userId;
  const onTurn = clients[players.findIndex((p) => p.user.id === turnUser)];

  const ack = await onTurn.emit('game:action', { action: 'show', actionId: 'show3-1' });
  assert.equal(ack.ok, false);
  assert.equal(ack.code, 'show_unavailable');
  assert.ok(table.hand, 'the hand is still live');
  await closeAll(...clients);
});

test('a sideshow with only two players is refused, and so is answering one that was never asked', async () => {
  const { onTurn, waiting, table } = await dealtTable('sideshow2');
  let ack = await onTurn.emit('game:action', { action: 'sideshow', actionId: 'ss-1' });
  assert.equal(ack.ok, false);
  assert.equal(ack.code, 'too_few_players', 'refused for want of a third player');

  ack = await waiting.emit('game:sideshowRespond', { accept: true });
  assert.equal(ack.ok, false);
  assert.equal(ack.code, 'no_sideshow');
  assert.ok(table.hand);
  await closeAll(onTurn, waiting);
});

test('seeing twice is refused, and seeing never hands over the turn', async () => {
  const { onTurn, waiting, waitingUser, table } = await dealtTable('see');
  const turnBefore = table.hand.turnSeat;

  let ack = await waiting.emit('game:action', { action: 'see', actionId: 'see-1' });
  assert.equal(ack.ok, true, 'looking at your own cards is allowed at any time');
  ack = await waiting.emit('game:action', { action: 'see', actionId: 'see-2' });
  assert.equal(ack.ok, false);
  assert.equal(ack.code, 'already_seen');
  assert.equal(table.hand.turnSeat, turnBefore);
  assert.equal(table.findSeat(waitingUser.id).isBlind, false);
  await closeAll(onTurn, waiting);
});

test('replaying a move with the same actionId charges nobody twice', async () => {
  const { onTurn, waiting, onTurnUser, table } = await dealtTable('dup');
  const amount = table.hand.stake;
  const walletBefore = await wallet(onTurnUser.id);

  const first = await onTurn.emit('game:action', { action: 'chaal', amount, actionId: 'dup-same-id' });
  assert.equal(first.ok, true);

  // The turn has moved on, so the replay fails the turn check first; force
  // the ledger check by replaying when the turn comes back is what the unit
  // tests cover — here the point is that nothing is charged either way.
  const replay = await onTurn.emit('game:action', { action: 'chaal', amount, actionId: 'dup-same-id' });
  assert.equal(replay.ok, false);

  const { rows } = await query('SELECT COUNT(*) AS n FROM chip_ledger WHERE action_id = $1', ['dup-same-id']);
  assert.equal(rows[0].n, 1, 'exactly one ledger row carries the id');
  assert.equal(await wallet(onTurnUser.id), walletBefore - amount);
  await closeAll(onTurn, waiting);
});

test('a player who is not seated cannot ask for cards, and a seated one cannot see another\'s', async () => {
  const { onTurn, waiting, waitingUser, table } = await dealtTable('cards');
  const loner = await guestLogin('device-cards-c', 'Cara');
  const cl = await openClient(loner.token);
  const ack = await cl.emit('player:requestCards', {});
  assert.equal(ack.ok, false);
  assert.equal(ack.code, 'not_in_room');

  // The other player's cards are never in anything this client receives.
  const theirs = table.findSeat(waitingUser.id).cards.map((c) => `${c.rank}${c.suit}`).sort().join(',');
  const snapshot = JSON.stringify(onTurn.seen);
  for (const code of theirs.split(',')) {
    assert.ok(code.length > 0);
  }
  const state = onTurn.last('room:state') ?? onTurn.last('room:joined');
  const other = state.seats.find((s) => s.userId === waitingUser.id);
  assert.equal(other.cards, undefined, 'no card codes for another seat');
  assert.ok(!snapshot.includes('"cards":["'), 'no card list for anyone but the viewer before they look');
  await closeAll(onTurn, waiting, cl);
});

// ----------------------------------------------------------------- seating

test('joining while already seated, or a room that does not exist, is refused', async () => {
  const { onTurn, waiting, bootAmount } = await dealtTable('seat');
  let ack = await onTurn.emit('room:quickJoin', { bootAmount });
  assert.equal(ack.ok, false);
  assert.equal(ack.code, 'already_in_room');

  ack = await onTurn.emit('room:joinCode', { code: 'NOPE00' });
  assert.equal(ack.ok, false);
  assert.ok(['already_in_room', 'room_not_found'].includes(ack.code));

  // Opening a private room is a way in as well, and it is shut to a player
  // who already has a seat.
  ack = await onTurn.emit('room:create', { isPrivate: true });
  assert.equal(ack.ok, false);
  assert.equal(ack.code, 'already_in_room');
  assert.equal(rooms.getTableForPlayer(onTurn.last('room:joined').seats.find((s) => s.userId).userId) !== null, true);

  const loner = await guestLogin('device-seat-c', 'Cara');
  const cl = await openClient(loner.token);
  ack = await cl.emit('room:joinCode', { code: 'NOPE00' });
  assert.equal(ack.ok, false);
  assert.equal(ack.code, 'room_not_found');
  ack = await cl.emit('room:joinCode', { code: { $gt: '' } });
  assert.equal(ack.ok, false);
  ack = await cl.emit('room:quickJoin', { bootAmount: -5 });
  assert.equal(ack.ok, false);
  ack = await cl.emit('room:quickJoin', { bootAmount: 'lots' });
  assert.equal(ack.ok, false);
  // A null payload is not a crash — it is read as "the defaults", which is a
  // legitimate quick-join at the default stake.
  ack = await cl.emit('room:quickJoin', null);
  assert.equal(ack.ok, true);
  await closeAll(onTurn, waiting, cl);
});

test('a player who cannot cover the boot is not seated', async () => {
  const poor = await guestLogin('device-poor-a', 'Poor');
  // Through the ledger, as every chip movement must be — a bare UPDATE would
  // leave a wallet the books cannot explain.
  await applyChipDelta({ userId: poor.user.id, delta: -(poor.user.chips - 50), reason: 'test_fixture', actionId: 'poor-fixture' });
  const cp = await openClient(poor.token);
  const ack = await cp.emit('room:quickJoin', { bootAmount: uniqueStake() });
  assert.equal(ack.ok, false);
  assert.equal(ack.code, 'insufficient_chips');
  assert.equal(rooms.getTableForPlayer(poor.user.id), null);
  cp.socket.disconnect();
});

test('the sixth player is not squeezed onto a full table', async () => {
  const bootAmount = uniqueStake();
  const table = rooms.createTable({ bootAmount, isPrivate: true });
  const clients = [];
  for (let i = 0; i < 5; i += 1) {
    const p = await guestLogin(`device-full-${i}`, `F${i}`);
    const c = await openClient(p.token);
    const ack = await c.emit('room:joinCode', { code: table.code });
    assert.equal(ack.ok, true);
    clients.push(c);
  }
  const extra = await guestLogin('device-full-x', 'FX');
  const cx = await openClient(extra.token);
  const ack = await cx.emit('room:joinCode', { code: table.code });
  assert.equal(ack.ok, false);
  assert.equal(ack.code, 'table_full');
  await closeAll(...clients, cx);
});

// -------------------------------------------------------------------- chat

test('chat that is empty, too long, or from outside the room never reaches the table', async () => {
  const { onTurn, waiting } = await dealtTable('chat');
  const heard = [];
  waiting.socket.on('chat:message', (m) => heard.push(m));

  await onTurn.emit('chat:message', { text: '' });
  await onTurn.emit('chat:message', { text: '   ' });
  await onTurn.emit('chat:message', { text: 'x'.repeat(5000) });
  await onTurn.emit('chat:message', { text: 12345 });
  await onTurn.emit('chat:message', null);
  await onTurn.emit('chat:message', { text: 'hello table' });
  await waiting.wait('chat:message', () => true).catch(() => {});
  await new Promise((r) => setTimeout(r, 100));

  // Blank, over-long and non-object messages are dropped. A bare number is
  // said as its digits — harmless, and the player did say something.
  assert.equal(heard.length, 2, 'the number and the real message');
  assert.equal(heard[0].text, '12345');
  assert.equal(heard[1].text, 'hello table');
  await closeAll(onTurn, waiting);
});

// --------------------------------------------------------- garbage payloads

test('garbage on every gameplay event is refused rather than crashing the server', async () => {
  const { onTurn, waiting, table } = await dealtTable('garbage');
  // None of these is a legal move: a valid action with a junk amount, a junk
  // action, or no object at all. (A legal action with an over-long actionId
  // is still a legal action — the id is simply replaced — so it is not here.)
  const garbage = [undefined, null, 42, 'string', [], [1, 2], { action: null }, { action: {} }, { amount: {} },
    { action: 'chaal', amount: '1e3' }, { action: 'chaal', amount: [100] }, { action: 'raise', amount: true },
    { __proto__: { action: 'pack' } }];

  const events = ['game:action', 'game:sideshowRespond', 'room:quickJoin', 'room:joinCode', 'room:create', 'chat:message'];
  for (const payload of garbage) {
    for (const event of events) {
      const ack = await Promise.race([
        onTurn.emit(event, payload),
        new Promise((resolve) => setTimeout(() => resolve('no_ack'), 1500)),
      ]);
      assert.notEqual(ack, 'no_ack', `${event} ${JSON.stringify(payload)} was acknowledged`);
      // An empty chat message is ignored rather than refused — nothing is
      // posted, and the ack says so with no message id. Everything else is a
      // refusal.
      if (event === 'chat:message') {
        assert.equal(ack.messageId, undefined, `${event} ${JSON.stringify(payload)} posted nothing`);
      } else {
        assert.equal(ack.ok, false, `${event} ${JSON.stringify(payload)} was refused`);
      }
    }
  }
  assert.ok(table.hand, 'the hand survived all of it');
  assert.equal(onTurn.socket.connected, true, 'and so did the socket');

  // The table still works for honest play afterwards.
  const ack = await onTurn.emit('game:action', { action: 'pack', actionId: 'garbage-pack' });
  assert.equal(ack.ok, true);
  await closeAll(onTurn, waiting);
});

test('too many requests in a burst are rate limited but the session survives', async () => {
  const { onTurn, waiting } = await dealtTable('burst');
  const acks = await Promise.all(Array.from({ length: 60 }, (_, i) =>
    onTurn.emit('lobby:list', { i })));
  const limited = onTurn.seen.filter((e) => e.event === 'game:error' && e.payload.code === 'rate_limited');
  assert.ok(limited.length > 0 || acks.some((a) => a === undefined), 'the burst hit the limiter');
  assert.equal(onTurn.socket.connected, true);
  await closeAll(onTurn, waiting);
});

// -------------------------------------------------------------- the books

test('after all of the above every wallet still equals its ledger', async () => {
  const { rows } = await query('SELECT id, chips FROM users');
  for (const row of rows) {
    assert.equal(row.chips, await ledgerSum(row.id), `wallet ${row.id} matches its ledger`);
  }
});
