/**
 * Tampered and confused clients (invalidMoves.test.js, all 16 cases, black-box):
 * every bad request is refused with the exact code and message, changes
 * nothing — pot, turn, wallet, ledger — and never costs the honest players
 * their table. Plus the two refusal channels (ack + game:error), the general
 * 30/5 s limiter's `{ok:false, code:'rate_limited'}` ack, and the ledger's
 * duplicate_action guard when the same actionId comes back on a later turn.
 *
 * Profile assumptions (tools/parity.mjs "slow"): TURN_TIMEOUT_MS and
 * SIDESHOW_TIMEOUT_MS 60 s, so no refusal can be blamed on a clock.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  guestLogin, openClient, closeAll, closeOpenClients, stakeCounter, dealtTable, pause, UUID, profile,
} from './lib/harness.mjs';
import { query, closeDb, wallet, ledgerSum, setWallet } from './lib/db.mjs';

test.after(async () => {
  await closeOpenClients();
  await closeDb();
});

const uniqueStake = stakeCounter(1000);

/** The refusal also arrives as a game:error with the same code and message. */
const expectError = async (client, ack) => {
  const error = await client.wait('game:error', (e) => e.code === ack.code && e.message === ack.message, 2000);
  assert.deepEqual(error, { code: ack.code, message: ack.message });
};

// --------------------------------------------------------------- gameplay

test('acting out of turn is refused and the turn does not move', async () => {
  const { waiting, onTurn, clients } = await dealtTable('oot', uniqueStake);
  const before = waiting.state();
  const stake = before.stake;

  for (const action of ['chaal', 'pack', 'show', 'sideshow']) {
    const ack = await waiting.emit('game:action', { action, amount: stake, actionId: `oot-${action}` });
    assert.deepEqual(ack, { ok: false, code: 'not_your_turn', message: 'It is not your turn' }, `${action} out of turn`);
    await expectError(waiting, ack);
  }
  // `raise` with no amount, off turn, is the same refusal.
  const raise = await waiting.emit('game:action', { action: 'raise' });
  assert.equal(raise.code, 'not_your_turn');
  await pause(100);
  assert.deepEqual(waiting.state().turn, before.turn, 'the turn is where it was');
  assert.equal(onTurn.state().turn.userId, onTurn.state().you && onTurn.state().seats[onTurn.state().turn.seatIndex].userId);
  assert.equal((await query("SELECT COUNT(*) AS n FROM chip_ledger WHERE action_id LIKE 'oot-%'")).rows[0].n, 0);
  await closeAll(...clients);
});

test('a bet that is not on the ladder is refused, whatever the figure', async () => {
  const { onTurn, onTurnUser, clients } = await dealtTable('ladder', uniqueStake);
  const before = onTurn.state();
  const stake = before.stake;
  const walletBefore = await wallet(onTurnUser.id);

  const bad = [stake + 1, stake * 3, -stake, 0, 1, 1e15, walletBefore + 1];
  for (const amount of bad) {
    const ack = await onTurn.emit('game:action', { action: 'chaal', amount, actionId: `ladder-${amount}` });
    assert.deepEqual(ack, { ok: false, code: 'invalid_bet', message: 'That bet amount is not available' }, `chaal ${amount}`);
  }
  // On the ladder but not a raise: refused as a raise, accepted as a chaal.
  const lowRaise = await onTurn.emit('game:action', { action: 'raise', amount: stake, actionId: 'ladder-low-raise' });
  assert.deepEqual(lowRaise, { ok: false, code: 'invalid_bet', message: 'A raise must be at least double the chaal' });
  await pause(50);
  assert.equal(onTurn.state().pot, before.pot, 'the pot has not moved');
  assert.deepEqual(onTurn.state().turn, before.turn);
  assert.equal(await wallet(onTurnUser.id), walletBefore, 'the wallet has not moved');
  assert.equal((await query("SELECT COUNT(*) AS n FROM chip_ledger WHERE action_id LIKE 'ladder-%'")).rows[0].n, 0, 'nothing reached the ledger');
  await closeAll(...clients);
});

test('a bet amount that is not a number at all is refused before it reaches the table', async () => {
  const { onTurn, clients } = await dealtTable('nan', uniqueStake);
  const before = onTurn.state();
  const stake = before.stake;

  // NaN and Infinity cannot cross the wire — JSON turns them into null, and a
  // null amount is the ordinary "chaal at the stake" — so they are left out.
  for (const amount of [String(stake), 'abc', 1.5, { amount: 100 }, [stake], true, '1e3']) {
    const ack = await onTurn.emit('game:action', { action: 'chaal', amount, actionId: `nan-${JSON.stringify(amount)}` });
    assert.deepEqual(ack, { ok: false, code: 'invalid_bet', message: 'Bet amount must be a whole number' }, `amount ${JSON.stringify(amount)}`);
  }
  await pause(50);
  assert.equal(onTurn.state().pot, before.pot);
  assert.equal(onTurn.state().you.contributed, before.you.contributed);
  await closeAll(...clients);
});

test('an unknown action, or one from a player at no table, is refused', async () => {
  const { onTurn, clients } = await dealtTable('unknown', uniqueStake);
  let ack = await onTurn.emit('game:action', { action: 'allin', actionId: 'unknown-1' });
  assert.deepEqual(ack, { ok: false, code: 'unknown_action', message: 'Unknown action "allin"' });
  await expectError(onTurn, ack);
  ack = await onTurn.emit('game:action', { action: '__proto__', actionId: 'unknown-2' });
  assert.deepEqual(ack, { ok: false, code: 'unknown_action', message: 'Unknown action "__proto__"' });
  ack = await onTurn.emit('game:action', { action: 'SEE' });
  assert.equal(ack.code, 'unknown_action', 'actions are case-sensitive');
  ack = await onTurn.emit('game:action', {});
  assert.deepEqual(ack, { ok: false, code: 'unknown_action', message: 'Unknown action "undefined"' });

  const loner = await guestLogin('device-parity-invalid-unknown-c', 'Cara');
  const cl = await openClient(loner.token);
  ack = await cl.emit('game:action', { action: 'pack', actionId: 'unknown-3' });
  assert.deepEqual(ack, { ok: false, code: 'not_in_room', message: 'You are not at a table' });
  ack = await cl.emit('game:sideshowRespond', { accept: true });
  assert.deepEqual(ack, { ok: false, code: 'not_in_room', message: 'You are not at a table' });
  ack = await cl.emit('game:action', { action: 'teleport' });
  assert.equal(ack.code, 'unknown_action', 'the action is checked before the seat');
  await closeAll(...clients, cl);
});

test('a show with more than two players in the hand is refused', async () => {
  const t = await dealtTable('show3', uniqueStake, { count: 3 });
  const ack = await t.onTurn.emit('game:action', { action: 'show', actionId: 'show3-1' });
  assert.deepEqual(ack, { ok: false, code: 'show_unavailable', message: 'A show needs exactly two players left' });
  await pause(50);
  assert.equal(t.onTurn.state().state, 'betting', 'the hand is still live');
  assert.equal(t.onTurn.state().you.options.show, null, 'and the option was never offered');
  await closeAll(...t.clients);
});

test('a sideshow with only two players is refused, and so is answering one that was never asked', async () => {
  const { onTurn, waiting, clients } = await dealtTable('sideshow2', uniqueStake);
  await onTurn.emit('game:action', { action: 'see' });
  await waiting.emit('game:action', { action: 'see' });
  let ack = await onTurn.emit('game:action', { action: 'sideshow', actionId: 'ss-1' });
  assert.deepEqual(ack, { ok: false, code: 'too_few_players', message: 'A sideshow needs at least 3 players in the hand' });
  ack = await waiting.emit('game:sideshowRespond', { accept: true });
  assert.deepEqual(ack, { ok: false, code: 'no_sideshow', message: 'There is no sideshow to answer' });
  await pause(50);
  assert.equal(onTurn.state().state, 'betting');
  assert.equal(onTurn.state().sideshow, null);
  await closeAll(...clients);
});

test('only `accept: true` accepts a sideshow; anything else declines it', async () => {
  const t = await dealtTable('ssaccept', uniqueStake, { count: 3 });
  const asker = t.bySeat[1];
  const asked = t.bySeat[0];
  await asker.client.emit('game:action', { action: 'see' });
  await asked.client.emit('game:action', { action: 'see' });
  let ack = await asker.client.emit('game:action', { action: 'sideshow' });
  assert.deepEqual(ack, { ok: true, action: 'sideshow', toUserId: asked.user.id });
  ack = await asked.client.emit('game:sideshowRespond', { accept: 'yes' });
  assert.deepEqual(ack, { ok: true, accepted: false, packedUserId: null }, 'a truthy string is not an acceptance');
  const resolved = await t.bySeat[2].client.wait('game:sideshowResolved');
  assert.equal(resolved.accepted, false);
  assert.equal(resolved.reason, 'declined');
  assert.equal(asker.client.count('game:sideshowReveal'), 0);
  await closeAll(...t.clients);
});

test('seeing twice is refused, and seeing never hands over the turn', async () => {
  const { onTurn, waiting, clients } = await dealtTable('see', uniqueStake);
  const before = waiting.state();
  let ack = await waiting.emit('game:action', { action: 'see', actionId: 'see-1' });
  assert.deepEqual(ack, { ok: true, action: 'see', auto: false });
  ack = await waiting.emit('game:action', { action: 'see', actionId: 'see-2' });
  assert.deepEqual(ack, { ok: false, code: 'already_seen', message: 'You have already seen your cards' });
  await pause(50);
  assert.deepEqual(waiting.state().turn, before.turn);
  assert.equal(waiting.state().you.isBlind, false);
  assert.equal(onTurn.state().seats.find((s) => s.seatIndex === before.you.seatIndex).isBlind, false);
  await closeAll(...clients);
});

test('replaying a move with the same actionId charges nobody twice — refused as not_your_turn at once, as duplicate_action when the turn returns', async () => {
  const { onTurn, waiting, onTurnUser, clients } = await dealtTable('dup', uniqueStake);
  const amount = onTurn.state().stake;
  const walletBefore = await wallet(onTurnUser.id);

  const first = await onTurn.emit('game:action', { action: 'chaal', amount, actionId: 'dup-same-id' });
  assert.deepEqual(first, { ok: true, action: 'chaal', amount, autoSeen: false });

  // The turn has moved on, so the replay fails the turn check first.
  const replay = await onTurn.emit('game:action', { action: 'chaal', amount, actionId: 'dup-same-id' });
  assert.deepEqual(replay, { ok: false, code: 'not_your_turn', message: 'It is not your turn' });

  // The other player chaals; the turn comes back; the same id now reaches the ledger and is refused there.
  await waiting.waitState((s) => s.turn?.userId !== onTurnUser.id);
  const other = await waiting.emit('game:action', { action: 'chaal', actionId: 'dup-other' });
  assert.equal(other.ok, true);
  await onTurn.waitState((s) => s.turn?.userId === onTurnUser.id);
  const potBefore = onTurn.state().pot;
  const again = await onTurn.emit('game:action', { action: 'chaal', amount, actionId: 'dup-same-id' });
  assert.deepEqual(again, { ok: false, code: 'duplicate_action', message: 'That move was already applied' });
  await expectError(onTurn, again);
  await pause(50);
  assert.equal(onTurn.state().pot, potBefore, 'the refused write changed nothing');
  assert.equal(onTurn.state().turn.userId, onTurnUser.id, 'and the turn did not move');
  assert.equal(onTurn.state().you.contributed, onTurn.state().bootAmount + amount);

  // A bet writes nothing to PostgreSQL while the hand runs (owner's decision
  // of 9 Sep 2026): the chips move at the seat and in the live store, and are
  // banked when the player leaves the hand or when it settles.
  assert.equal((await query('SELECT COUNT(*) AS n FROM chip_ledger WHERE action_id = $1', ['dup-same-id'])).rows[0].n, 0,
    'a bet is not a transaction of its own');
  assert.equal(await wallet(onTurnUser.id), walletBefore, 'and the wallet has not moved yet');

  // An actionId that is not a usable string is replaced by a server-minted uuid — the move still goes through.
  const long = await onTurn.emit('game:action', { action: 'chaal', amount, actionId: 'x'.repeat(65) });
  assert.equal(long.ok, true, JSON.stringify(long));
  await waiting.waitState((s) => s.turn?.userId !== onTurnUser.id);
  const numeric = await waiting.emit('game:action', { action: 'chaal', actionId: 12345 });
  assert.equal(numeric.ok, true, JSON.stringify(numeric));

  // End the hand. The wallet catches up in ONE step — the pack checkpoint
  // and then the outcome row — and every id in the ledger is server-minted:
  // no client action id ever reaches it now, so the ids above could only ever
  // have been idempotency tokens.
  const staked = onTurn.state().you.contributed;
  await onTurn.waitState((s) => s.turn?.userId === onTurnUser.id);
  const packed = await onTurn.emit('game:action', { action: 'pack' });
  assert.equal(packed.ok, true, JSON.stringify(packed));
  const ended = await onTurn.wait('game:handEnded');

  for (const id of ['dup-same-id', 'other-1', 'x'.repeat(65), '12345']) {
    assert.equal((await query('SELECT COUNT(*) AS n FROM chip_ledger WHERE action_id = $1', [id])).rows[0].n, 0,
      `a client action id reached the ledger: ${id}`);
  }
  const rows = await query('SELECT reason, delta, action_id FROM chip_ledger WHERE hand_id = $1 AND user_id = $2 ORDER BY id',
    [ended.handId, onTurnUser.id]);
  assert.deepEqual(rows.rows.map((r) => r.reason), ['hand_packed', 'hand_loss']);
  assert.equal(rows.rows[0].action_id, `${ended.handId}:packed:${onTurnUser.id}`);
  assert.equal(rows.rows[1].action_id, `${ended.handId}:settle:${onTurnUser.id}`);
  assert.equal(rows.rows[0].delta, -staked, 'their whole stake, charged once at the pack');
  assert.equal(rows.rows[1].delta, 0, 'and the outcome row moves nothing');
  assert.equal(await wallet(onTurnUser.id), walletBefore - staked, 'the wallet moved exactly once');
  await closeAll(...clients);
});

test("a player who is not seated cannot ask for cards, and a seated one cannot see another's", async () => {
  const { onTurn, waiting, waitingUser, clients } = await dealtTable('cards', uniqueStake);
  const loner = await guestLogin('device-parity-invalid-cards-c', 'Cara');
  const cl = await openClient(loner.token);
  const ack = await cl.emit('player:requestCards', {});
  assert.deepEqual(ack, { ok: false, code: 'not_in_room', message: 'You are not at a table' });

  const state = onTurn.state();
  const other = state.seats.find((s) => s.userId === waitingUser.id);
  assert.equal(other.cards, undefined, 'no card codes for another seat');
  assert.equal(other.cardCount, 3);
  assert.ok(!JSON.stringify(onTurn.seen).includes('"cards":["'), 'no card list for anyone before they look');
  // Even after the other player looks, nothing of theirs reaches this socket.
  await waiting.emit('game:action', { action: 'see' });
  const theirs = waiting.last('player:cards').cards;
  await pause(100);
  for (const code of theirs) assert.ok(!JSON.stringify(onTurn.seen).includes(`"${code}"`), `${code} leaked`);
  await closeAll(...clients, cl);
});

// ------------------------------------------------------------------ seating

test('joining while already seated, or a room that does not exist, is refused', async () => {
  const { onTurn, bootAmount, clients } = await dealtTable('seat', uniqueStake);
  let ack = await onTurn.emit('room:quickJoin', { bootAmount });
  assert.deepEqual(ack, { ok: false, code: 'already_in_room', message: 'You are already seated at a table' });
  ack = await onTurn.emit('room:joinCode', { code: 'NOPE00' });
  assert.equal(ack.code, 'already_in_room');
  ack = await onTurn.emit('room:create', { isPrivate: true });
  assert.equal(ack.code, 'already_in_room');
  await pause(50);
  assert.equal(onTurn.state().you.status, 'active', 'still seated, still in the hand');

  const loner = await guestLogin('device-parity-invalid-seat-c', 'Cara');
  const cl = await openClient(loner.token);
  ack = await cl.emit('room:joinCode', { code: 'NOPE00' });
  assert.deepEqual(ack, { ok: false, code: 'room_not_found', message: 'No table with that code' });
  ack = await cl.emit('room:joinCode', { code: { $gt: '' } });
  assert.equal(ack.code, 'room_not_found');
  ack = await cl.emit('room:quickJoin', { bootAmount: -5 });
  assert.deepEqual(ack, { ok: false, code: 'invalid_stake', message: 'That stake is not valid' });
  ack = await cl.emit('room:quickJoin', { bootAmount: 'lots' });
  assert.equal(ack.code, 'invalid_stake');
  // A null payload is not a crash — it is read as "the defaults".
  ack = await cl.emit('room:quickJoin', null);
  assert.equal(ack.ok, true);
  assert.equal(cl.last('room:joined').bootAmount, profile.bootAmount);
  await closeAll(...clients, cl);
});

test('a player who cannot cover the boot is not seated', async () => {
  const poor = await guestLogin('device-parity-invalid-poor-a', 'Poor');
  await setWallet(poor.user.id, 50, 'parity-invalid-poor-fixture');
  const cp = await openClient(poor.token);
  const ack = await cp.emit('room:quickJoin', { bootAmount: uniqueStake() });
  assert.deepEqual(ack, { ok: false, code: 'insufficient_chips', message: 'Not enough chips to join this table' });
  assert.equal(cp.count('room:joined'), 0);
  const again = await cp.emit('room:quickJoin', { bootAmount: 50 });
  assert.equal(again.ok, true, 'exactly the boot suffices');
  await cp.close();
});

test('the sixth player is not squeezed onto a full table', async () => {
  const host = await guestLogin('device-parity-invalid-full-host', 'Host');
  const ch = await openClient(host.token);
  const created = await ch.emit('room:create', { isPrivate: true });
  assert.equal(created.ok, true);
  const clients = [ch];
  for (let i = 0; i < 4; i += 1) {
    const p = await guestLogin(`device-parity-invalid-full-${i}`, `F${i}`);
    const c = await openClient(p.token);
    const ack = await c.emit('room:joinCode', { code: created.code });
    assert.equal(ack.ok, true, JSON.stringify(ack));
    clients.push(c);
  }
  const extra = await guestLogin('device-parity-invalid-full-x', 'FX');
  const cx = await openClient(extra.token);
  const ack = await cx.emit('room:joinCode', { code: created.code });
  assert.deepEqual(ack, { ok: false, code: 'table_full', message: 'That table is full' });
  await closeAll(...clients, cx);
});

// --------------------------------------------------------------------- chat

test('chat that is empty, too long, or from outside the room never reaches the table', async () => {
  const { onTurn, waiting, clients } = await dealtTable('chat', uniqueStake);
  const heard = [];
  waiting.socket.on('chat:message', (m) => heard.push(m));

  // Five sends: the chat allowance is five per five seconds, and every send
  // counts against it whether or not anything is posted.
  const acks = [];
  for (const payload of [{ text: '   ' }, { text: 'x'.repeat(5000) }, { text: 12345 }, null, { text: 'hello table' }]) {
    acks.push(await onTurn.emit('chat:message', payload));
  }
  await waiting.wait('chat:message', (m) => m.text === 'hello table');
  await pause(100);

  assert.deepEqual(acks[0], { ok: true }, 'blank: nothing posted, no id');
  assert.match(acks[1].messageId, UUID);
  assert.match(acks[2].messageId, UUID);
  assert.deepEqual(acks[3], { ok: true }, 'a null payload is an empty message');
  assert.match(acks[4].messageId, UUID);
  assert.equal(heard.length, 3, 'the trimmed long message, the number, and the real one');
  assert.equal(heard[0].text.length, 140);
  assert.equal(heard[1].text, '12345');
  assert.equal(heard[2].text, 'hello table');
  assert.deepEqual(heard.map((m) => m.id), [acks[1].messageId, acks[2].messageId, acks[4].messageId]);

  const sixth = await onTurn.emit('chat:message', { text: 'one too many' });
  assert.deepEqual(sixth, { ok: false, code: 'chat_rate_limited', message: 'You are sending messages too quickly' });
  await expectError(onTurn, sixth);
  await closeAll(...clients);
});

// --------------------------------------------------------- garbage payloads

test('garbage on every gameplay event is refused rather than crashing the server, and every request is acked', async () => {
  const { onTurn, clients } = await dealtTable('garbage', uniqueStake);
  const garbage = [undefined, null, 42, 'string', [], [1, 2], { action: null }, { action: {} }, { amount: {} },
    { action: 'chaal', amount: '1e3' }, { action: 'chaal', amount: [100] }, { action: 'raise', amount: true },
    { __proto__: { action: 'pack' } }];
  const events = ['game:action', 'game:sideshowRespond', 'room:quickJoin', 'room:joinCode', 'room:create', 'chat:message'];
  let limited = 0;
  for (const payload of garbage) {
    for (const event of events) {
      const ack = await onTurn.emitOrTimeout(event, payload, 1500);
      assert.notEqual(ack, 'no_ack', `${event} ${JSON.stringify(payload)} was acknowledged`);
      if (ack.code === 'rate_limited') {
        limited += 1;
        assert.deepEqual(ack, { ok: false, code: 'rate_limited', message: 'Slow down' }, 'the limiter acks a refusal, never silence');
        continue;
      }
      if (event === 'chat:message') {
        assert.equal(ack.messageId, undefined, `${event} ${JSON.stringify(payload)} posted nothing`);
      } else {
        assert.equal(ack.ok, false, `${event} ${JSON.stringify(payload)} was refused: ${JSON.stringify(ack)}`);
        assert.equal(typeof ack.code, 'string');
        assert.equal(typeof ack.message, 'string');
      }
    }
  }
  assert.ok(limited > 0, 'that many requests in a burst trips the 30/5 s limiter');
  assert.ok(onTurn.all('game:error').some((e) => e.code === 'rate_limited' && e.message === 'Slow down'), 'and it is reported as a game:error too');
  assert.equal(onTurn.state().state, 'betting', 'the hand survived all of it');
  assert.equal(onTurn.socket.connected, true, 'and so did the socket');

  // Once the window has passed the table works for honest play again.
  await pause(5200);
  const ack = await onTurn.emit('game:action', { action: 'pack', actionId: 'garbage-pack' });
  assert.deepEqual(ack, { ok: true, action: 'pack', reason: 'pack' });
  await closeAll(...clients);
});

test('too many requests in a burst are rate limited with an ack, and the session survives', async () => {
  const { onTurn, clients } = await dealtTable('burst', uniqueStake);
  const acks = await Promise.all(Array.from({ length: 60 }, (_, i) => onTurn.emit('lobby:list', { i })));
  const limitedAcks = acks.filter((a) => a.ok === false);
  const passed = acks.filter((a) => a.ok === true);
  assert.ok(limitedAcks.length >= 30, `at least 30 of 60 are refused (${limitedAcks.length})`);
  assert.ok(passed.length >= 1 && passed.length <= 30, `no more than 30 pass a window (${passed.length})`);
  for (const ack of limitedAcks) assert.deepEqual(ack, { ok: false, code: 'rate_limited', message: 'Slow down' });
  for (const ack of passed) assert.ok(Array.isArray(ack.tables));
  const errors = onTurn.all('game:error').filter((e) => e.code === 'rate_limited');
  assert.equal(errors.length, limitedAcks.length, 'one game:error per refused request');
  assert.equal(onTurn.socket.connected, true);
  await closeAll(...clients);
});

// -------------------------------------------------------------- the books

test('after all of the above every wallet still equals its ledger', async () => {
  const { rows } = await query('SELECT id, chips FROM users');
  assert.ok(rows.length > 0);
  for (const row of rows) {
    assert.equal(row.chips, await ledgerSum(row.id), `wallet ${row.id} matches its ledger`);
  }
});
