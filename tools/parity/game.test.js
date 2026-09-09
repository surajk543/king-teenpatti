/**
 * Gameplay parity over the socket: the deal and the boot, the bet ladder in
 * `you.options` / `game:yourTurn`, chaal / raise / see / pack / show, the
 * blind-move cap and auto-reveal, turn timeouts and the three-miss kick,
 * sideshow accept / decline / lapse / leave, forced showdown, hidden chips on
 * blind tables, room chat, and a player leaving mid-hand (integration
 * #12–#14, #20–#21, #25–#31; tableRules / blindRules / raiseLadder /
 * seatKeeping / sideshow / categories rules replayed through the wire).
 *
 * Cards are random, so hand names, winners of a showdown and who loses a
 * sideshow are checked as invariants (exactly one winner, the loser packs, the
 * pot is conserved), never as fixed values. Turn order is deterministic: the
 * first dealer is seat 0 and the first turn seat 1; the dealer then rotates.
 *
 * Profile assumptions (tools/parity.mjs "main"): TURN_TIMEOUT_MS 1200,
 * SIDESHOW_TIMEOUT_MS 1500, NEXT_HAND_DELAY_MS 150, any stake, boot 100.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  guestLogin, openClient, closeAll, closeOpenClients, stakeCounter, dealtTable, profile, pause, me, eventually,
  assertKeys, assertOrder, assertBefore, collapseRuns, CARD_CODE, UUID, HAND_NAMES, OPTIONS_KEYS,
} from './lib/harness.mjs';
import { query, closeDb, wallet } from './lib/db.mjs';

/**
 * Every card code carried in `cards` arrays anywhere inside the recorded
 * frames. A plain substring search over the JSON is wrong here: two-character
 * codes such as "9d" or "Ac" are valid hex and turn up inside uuids.
 */
const cardCodesIn = (value, out = []) => {
  if (Array.isArray(value)) {
    if (value.length > 0 && value.every((v) => typeof v === 'string' && CARD_CODE.test(v))) out.push(...value);
    else value.forEach((v) => cardCodesIn(v, out));
  } else if (value && typeof value === 'object') {
    Object.values(value).forEach((v) => cardCodesIn(v, out));
  }
  return out;
};

test.after(async () => {
  await closeOpenClients();
  await closeDb();
});

const uniqueStake = stakeCounter(2000);
const occupied = (snapshot) => snapshot.seats.filter((seat) => seat.status !== 'empty');
const sum = (list) => list.reduce((total, n) => total + n, 0);

/**
 * Makes `client` chaal (or `action`) every time the table hands it the turn —
 * including right now, if a `game:yourTurn` already arrived before the
 * listener was attached.
 */
const autoAct = (client, action = 'chaal') => {
  client.socket.on('game:yourTurn', () => {
    client.fire('game:action', { action });
  });
  const current = client.state();
  if (current?.state === 'betting' && current.you?.options) client.fire('game:action', { action });
};

/**
 * Resolves with the first snapshot (the latest already held, else the next to
 * arrive) in which it is `userId`'s turn in hand `handNo`.
 */
const waitTurn = async (client, userId, handNo) => {
  const matches = (s) => s?.state === 'betting' && s.turn?.userId === userId && (handNo === undefined || s.handNo === handNo);
  const now = client.state();
  if (matches(now)) return now;
  return client.waitNext('room:state', matches, 6000);
};

// ------------------------------------------------------------------ deal

test('the deal: boots are banked, three hidden cards each, the turn opens left of the dealer, and only that player gets options', async () => {
  const t = await dealtTable('deal', uniqueStake);
  const { bootAmount, started, bySeat, clients } = t;
  const s0 = bySeat[0];
  const s1 = bySeat[1];
  assert.equal(t.onTurnUser.id, s1.user.id, 'seat 1 opens (dealer is seat 0)');

  assertKeys(started, ['handId', 'handNo', 'dealerSeat', 'bootAmount', 'pot', 'stake', 'participants', 'roomId'], 'game:handStarted');
  assert.match(started.handId, UUID);
  assert.equal(started.handNo, 1);
  assert.equal(started.dealerSeat, 0);
  assert.equal(started.bootAmount, bootAmount);
  assert.equal(started.pot, bootAmount * 2);
  assert.equal(started.stake, bootAmount);
  assert.deepEqual(started.participants, [s0.user.id, s1.user.id], 'seat order');
  assert.equal(started.roomId, t.roomId);

  for (const client of clients) {
    assert.deepEqual(client.last('player:hand'), { roomId: t.roomId, dealt: true, cardsHidden: true });
    const turn = client.last('game:turn');
    assertKeys(turn, ['roomId', 'userId', 'seatIndex', 'deadline', 'timeoutMs'], 'game:turn');
    assert.equal(turn.userId, s1.user.id);
    assert.equal(turn.seatIndex, 1);
    assert.equal(turn.timeoutMs, profile.turnTimeoutMs);
    assert.ok(turn.deadline - Date.now() <= profile.turnTimeoutMs + 100 && turn.deadline - Date.now() > profile.turnTimeoutMs - 2000,
      `deadline ${turn.deadline - Date.now()} ms out`);
    assert.equal(client.count('player:cards'), 0, 'nobody has looked yet');
  }

  // The deal, in order, for the player on turn and for the other.
  const dealEvents = (client) => {
    const from = client.seen.findIndex((e) => e.event === 'game:handStarted');
    return collapseRuns(client.seen.slice(from).map((e) => e.event).filter((e) => !e.startsWith('ack:')));
  };
  assert.deepEqual(dealEvents(s1.client).slice(0, 5), ['game:handStarted', 'player:hand', 'game:turn', 'game:yourTurn', 'room:state']);
  assert.deepEqual(dealEvents(s0.client).slice(0, 4), ['game:handStarted', 'player:hand', 'game:turn', 'room:state']);
  assert.equal(s0.client.count('game:yourTurn'), 0, 'only the player on turn is told the options');

  const yourTurn = s1.client.last('game:yourTurn');
  assertKeys(yourTurn, ['roomId', 'deadline', 'timeoutMs', 'options'], 'game:yourTurn');
  assert.equal(yourTurn.deadline, s1.client.last('game:turn').deadline);
  assertKeys(yourTurn.options, OPTIONS_KEYS, 'options');
  assert.deepEqual(yourTurn.options, {
    canSee: true,
    canSideshow: false,
    sideshowWith: null,
    chaal: bootAmount,
    raise: bootAmount * 2,
    raiseSteps: [bootAmount, bootAmount * 2],
    maxBet: bootAmount * 2,
    show: bootAmount,
    canPack: true,
    isBlind: true,
    currentStake: bootAmount,
    chips: profile.welcomeChips - bootAmount,
    pot: bootAmount * 2,
  }, 'a blind player on a seen table (two rungs) at the first turn');

  // Snapshots: the same options under `you` for the actor, null for the other; cards hidden as counts.
  const view1 = s1.client.state();
  const view0 = s0.client.state();
  assert.equal(view1.state, 'betting');
  assert.equal(view1.handNo, 1);
  assert.equal(view1.dealerSeat, 0);
  assert.equal(view1.pot, bootAmount * 2);
  assert.equal(view1.stake, bootAmount);
  assert.equal(view1.round, 0);
  assert.deepEqual(view1.turn, { seatIndex: 1, userId: s1.user.id, deadline: yourTurn.deadline });
  assert.deepEqual(view1.you.options, yourTurn.options);
  assert.equal(view0.you.options, null);
  for (const view of [view0, view1]) {
    assert.equal(view.you.status, 'active');
    assert.equal(view.you.chips, profile.welcomeChips - bootAmount);
    assert.equal(view.you.contributed, bootAmount);
    assert.equal(view.you.isBlind, true);
    assert.equal(view.you.blindMovesLeft, 4);
    assert.deepEqual(view.you.cards, []);
    for (const seat of occupied(view)) {
      assert.equal(seat.cardCount, 3);
      assert.equal(seat.contributed, bootAmount);
      assert.equal(seat.chips, profile.welcomeChips - bootAmount, 'seen table: every stack visible');
      assert.equal(seat.status, 'active');
      assert.equal(seat.lastBet, 0);
      assert.equal(seat.lastAction, null);
      assert.equal('cards' in seat, false, 'no card list on any seat');
    }
  }

  // THE DEAL WRITES NOTHING (owner's decision of 9 Sep 2026). The boot comes
  // out of the seat and the wallet is untouched until this player's first
  // checkpoint — a pack, a departure, or the hand ending.
  for (const entry of [s0, s1]) {
    assert.equal(await wallet(entry.user.id), profile.welcomeChips, 'the wallet is untouched at the deal');
    const { rows } = await query('SELECT COUNT(*) AS n FROM chip_ledger WHERE hand_id = $1', [started.handId]);
    assert.equal(Number(rows[0].n), 0, 'no ledger row for a hand that has only been dealt');
  }

  await closeAll(...clients);
});

// ------------------------------------------------------------------- see

test('see: free, allowed off-turn, reveals only your own three cards, re-issues the turn (only) for the player on turn', async () => {
  const t = await dealtTable('see', uniqueStake);
  const { onTurn, waiting, onTurnUser, waitingUser } = t;

  // Off-turn see: cards to the seer, a public action, no turn re-issue.
  let mark = waiting.mark();
  let turnMark = onTurn.count('game:turn');
  let ack = await waiting.emit('game:action', { action: 'see' });
  assert.deepEqual(ack, { ok: true, action: 'see', auto: false });
  const cards = await waiting.wait('player:cards');
  assertKeys(cards, ['roomId', 'cards'], 'player:cards');
  assert.equal(cards.cards.length, 3);
  for (const code of cards.cards) assert.match(code, CARD_CODE);
  assert.equal(new Set(cards.cards).size, 3);
  const action = await onTurn.wait('game:action', (a) => a.action === 'see');
  assert.deepEqual(action, { userId: waitingUser.id, action: 'see', amount: 0, auto: false, pot: t.bootAmount * 2, stake: t.bootAmount, roomId: t.roomId });
  assert.deepEqual(collapseRuns(waiting.eventsSince(mark)), ['player:cards', 'game:action', 'room:state', 'ack:game:action']);
  await pause(100);
  assert.equal(onTurn.count('game:turn'), turnMark, 'no game:turn for an off-turn see');
  assert.equal(onTurn.count('player:cards'), 0, 'card faces never reach the other player');
  const seerView = waiting.state();
  assert.equal(seerView.you.isBlind, false);
  assert.equal(seerView.you.blindMovesLeft, 0);
  assert.deepEqual(seerView.you.cards, cards.cards);
  assert.equal(seerView.turn.userId, onTurnUser.id, 'the turn did not move');
  const otherView = onTurn.state();
  const seerSeat = otherView.seats.find((s) => s.userId === waitingUser.id);
  assert.equal(seerSeat.isBlind, false, 'seen-ness is public');
  assert.equal(seerSeat.cardCount, 3);
  assert.ok(!JSON.stringify(onTurn.seen).includes(`"${cards.cards[0]}"`), 'the cards are in nothing the other player received');

  ack = await waiting.emit('game:action', { action: 'see' });
  assert.deepEqual(ack, { ok: false, code: 'already_seen', message: 'You have already seen your cards' });
  ack = await waiting.emit('game:action', { action: 'chaal' });
  assert.equal(ack.code, 'not_your_turn', 'looking does not hand over the turn');

  // player:requestCards: empty while blind, the cards once seen (and re-sent).
  ack = await onTurn.emit('player:requestCards', {});
  assert.deepEqual(ack, { ok: true, cards: [] });
  mark = waiting.mark();
  ack = await waiting.emit('player:requestCards', {});
  assert.deepEqual(ack, { ok: true, cards: cards.cards });
  assert.deepEqual(waiting.eventsSince(mark), ['player:cards', 'ack:player:requestCards']);

  // On-turn see: the turn is re-issued with the same deadline and the seen ladder.
  const before = onTurn.last('game:turn');
  mark = onTurn.mark();
  const wMark = waiting.mark();
  ack = await onTurn.emit('game:action', { action: 'see' });
  assert.equal(ack.ok, true);
  const reissued = await onTurn.waitNext('game:turn', () => true, 4000, mark);
  assert.equal(reissued.deadline, before.deadline, 'seeing never touches the clock');
  assert.ok(reissued.timeoutMs <= profile.turnTimeoutMs && reissued.timeoutMs >= 0, `remaining ${reissued.timeoutMs}`);
  const yourTurn = await onTurn.waitNext('game:yourTurn', () => true, 4000, mark);
  assert.equal(yourTurn.options.isBlind, false);
  assert.equal(yourTurn.options.canSee, false);
  assert.equal(yourTurn.options.chaal, t.bootAmount * 2, 'a seen player pays double');
  assert.equal(yourTurn.options.raise, t.bootAmount * 4);
  assert.deepEqual(yourTurn.options.raiseSteps, [t.bootAmount * 2, t.bootAmount * 4]);
  assert.equal(yourTurn.options.show, t.bootAmount * 2, 'the show costs a seen chaal');
  assert.deepEqual(collapseRuns(onTurn.eventsSince(mark)), ['player:cards', 'game:action', 'game:turn', 'game:yourTurn', 'room:state', 'ack:game:action']);
  const witnessed = await waiting.waitNext('game:turn', () => true, 4000, wMark);
  assert.equal(witnessed.deadline, before.deadline, 'the room hears the re-issued turn too');

  await closeAll(onTurn, waiting);
});

// ------------------------------------------------------------ full hand

test('a full hand: chaal, raise, see, show — the ladder, the stake in blind units, the showdown and the payout', async () => {
  const t = await dealtTable('hand', uniqueStake);
  const { bootAmount, bySeat } = t;
  const s0 = bySeat[0];
  const s1 = bySeat[1];
  let expectedPot = bootAmount * 2;

  // Seat 1 chaals blind at the stake.
  let mark = s1.client.mark();
  let ack = await s1.client.emit('game:action', { action: 'chaal', amount: bootAmount, actionId: 'parity-game-hand-chaal' });
  assert.deepEqual(ack, { ok: true, action: 'chaal', amount: bootAmount, autoSeen: false });
  expectedPot += bootAmount;
  let action = s1.client.last('game:action');
  assert.deepEqual(action, { userId: s1.user.id, action: 'chaal', amount: bootAmount, pot: expectedPot, stake: bootAmount, roomId: t.roomId });
  assert.deepEqual(collapseRuns(s1.client.eventsSince(mark)), ['game:action', 'game:turn', 'room:state', 'ack:game:action']);
  await waitTurn(s0.client, s0.user.id);
  assert.deepEqual(collapseRuns(s0.client.eventsSince(s0.client.seen.findIndex((e) => e.event === 'game:action' && e.payload.action === 'chaal'))).slice(0, 4),
    ['game:action', 'game:turn', 'game:yourTurn', 'room:state']);
  let view = s0.client.state();
  assert.equal(view.pot, expectedPot);
  assert.equal(view.stake, bootAmount);
  assert.equal(view.round, 0);
  assert.equal(view.seats[1].lastBet, bootAmount);
  assert.equal(view.seats[1].lastAction, 'chaal');
  assert.equal(view.seats[1].contributed, bootAmount * 2);
  assert.equal(view.you.options.chaal, bootAmount);
  assert.equal(view.you.options.raise, bootAmount * 2);

  // Seat 0 raises: the ladder has two rungs on a seen table, so 4× is refused and a raise must be ≥ 2× the chaal.
  ack = await s0.client.emit('game:action', { action: 'raise', amount: bootAmount * 4, actionId: 'parity-game-hand-bad-raise' });
  assert.deepEqual(ack, { ok: false, code: 'invalid_bet', message: 'That bet amount is not available' });
  ack = await s0.client.emit('game:action', { action: 'raise', amount: bootAmount, actionId: 'parity-game-hand-low-raise' });
  assert.deepEqual(ack, { ok: false, code: 'invalid_bet', message: 'A raise must be at least double the chaal' });
  assert.equal((await query('SELECT COUNT(*) AS n FROM chip_ledger WHERE action_id LIKE $1', ['parity-game-hand-%raise'])).rows[0].n, 0,
    'a refused bet writes nothing');
  ack = await s0.client.emit('game:action', { action: 'raise', amount: bootAmount * 2, actionId: 'parity-game-hand-raise' });
  assert.deepEqual(ack, { ok: true, action: 'raise', amount: bootAmount * 2, autoSeen: false });
  expectedPot += bootAmount * 2;
  action = s0.client.last('game:action');
  assert.deepEqual(action, { userId: s0.user.id, action: 'raise', amount: bootAmount * 2, pot: expectedPot, stake: bootAmount * 2, roomId: t.roomId });
  await waitTurn(s1.client, s1.user.id);
  view = s1.client.state();
  assert.equal(view.stake, bootAmount * 2, 'a blind raise doubles the stake');
  assert.equal(view.round, 1, 'the turn stepped over the opener: one round');
  assert.equal(view.seats[0].lastAction, 'raise');
  assert.equal(view.seats[0].lastBet, bootAmount * 2);
  assert.deepEqual(view.you.options.raiseSteps, [bootAmount * 2, bootAmount * 4], 'blind ladder from the new stake');

  // A bare raise (no amount) takes the default double.
  ack = await s1.client.emit('game:action', { action: 'raise', actionId: 'parity-game-hand-bare-raise' });
  assert.deepEqual(ack, { ok: true, action: 'raise', amount: bootAmount * 4, autoSeen: false });
  expectedPot += bootAmount * 4;
  await waitTurn(s0.client, s0.user.id);
  assert.equal(s0.client.state().stake, bootAmount * 4);

  // Seat 0 sees, then chaals seen (pays double the stake; the stake stays in blind units).
  const seeMark = s0.client.mark();
  ack = await s0.client.emit('game:action', { action: 'see' });
  assert.equal(ack.ok, true);
  const seenTurn = await s0.client.waitNext('game:yourTurn', () => true, 4000, seeMark);
  assert.equal(seenTurn.options.chaal, bootAmount * 8);
  assert.equal(seenTurn.options.show, bootAmount * 8);
  ack = await s0.client.emit('game:action', { action: 'chaal', actionId: 'parity-game-hand-seen-chaal' });
  assert.deepEqual(ack, { ok: true, action: 'chaal', amount: bootAmount * 8, autoSeen: false });
  expectedPot += bootAmount * 8;
  await waitTurn(s1.client, s1.user.id);
  view = s1.client.state();
  assert.equal(view.stake, bootAmount * 4, 'a seen bet of 2× leaves the stake where it was (floor(amount/2))');
  assert.equal(view.pot, expectedPot);
  assert.equal(view.round, 2);

  // Seat 1 sees and shows: costs a seen chaal, reveals both hands, one winner.
  ack = await s1.client.emit('game:action', { action: 'see' });
  assert.equal(ack.ok, true);
  mark = s1.client.mark();
  const s0Mark = s0.client.mark();
  ack = await s1.client.emit('game:action', { action: 'show', actionId: 'parity-game-hand-show' });
  assert.deepEqual(ack, { ok: true, action: 'show', amount: bootAmount * 8 });
  expectedPot += bootAmount * 8;
  const showAction = s1.client.since(mark).find((e) => e.event === 'game:action').payload;
  assert.deepEqual(showAction, { userId: s1.user.id, action: 'show', amount: bootAmount * 8, pot: expectedPot, stake: bootAmount * 4, roomId: t.roomId });

  const showdown = await s0.client.waitNext('game:showdown', () => true, 4000, s0Mark);
  assertKeys(showdown, ['reveals', 'reason', 'roomId'], 'game:showdown');
  assert.equal(showdown.reason, 'show');
  assert.equal(showdown.reveals.length, 2);
  for (const reveal of showdown.reveals) {
    assertKeys(reveal, ['userId', 'seatIndex', 'cards', 'handName', 'category', 'won'], 'reveal');
    assert.equal(reveal.cards.length, 3);
    for (const code of reveal.cards) assert.match(code, CARD_CODE);
    assert.ok(HAND_NAMES.includes(reveal.handName), reveal.handName);
    assert.equal(HAND_NAMES[reveal.category], reveal.handName, 'category indexes the English name');
    assert.equal(typeof reveal.won, 'boolean');
  }
  assert.equal(showdown.reveals.filter((r) => r.won).length, 1, 'exactly one winner, never a split pot');
  assert.deepEqual(showdown.reveals.map((r) => r.seatIndex), [0, 1]);
  const winner = showdown.reveals.find((r) => r.won);
  const loser = showdown.reveals.find((r) => !r.won);

  const ended = await s0.client.waitNext('game:handEnded', () => true, 4000, s0Mark);
  assertKeys(ended, ['handId', 'handNo', 'winnerId', 'winnerName', 'pot', 'reason', 'reveals', 'summary', 'nextHandAt', 'roomId'], 'game:handEnded');
  assert.equal(ended.handId, t.started.handId);
  assert.equal(ended.handNo, 1);
  assert.equal(ended.winnerId, winner.userId);
  assert.equal(ended.winnerName, bySeat[winner.seatIndex].user.displayName);
  assert.equal(ended.pot, expectedPot);
  assert.equal(ended.reason, 'show');
  assert.deepEqual(ended.reveals, showdown.reveals);
  assert.ok(ended.nextHandAt - Date.now() <= profile.nextHandDelayMs + 100);
  assert.equal(ended.summary.length, 2);
  for (const entry of ended.summary) {
    assertKeys(entry, ['userId', 'displayName', 'seatIndex', 'contributed', 'status', 'sawCards', 'cards'], 'summary entry');
    assert.equal(entry.sawCards, true);
    assert.equal(entry.cards.length, 3, 'revealed at the show');
    assert.equal(entry.status, entry.userId === winner.userId ? 'won' : 'lost');
  }
  assert.equal(sum(ended.summary.map((e) => e.contributed)), expectedPot, 'the summary explains the pot');
  assert.equal(ended.summary.find((e) => e.seatIndex === 0).contributed, bootAmount * (1 + 2 + 8));
  assert.equal(ended.summary.find((e) => e.seatIndex === 1).contributed, bootAmount * (1 + 1 + 4 + 8));
  assertBefore(s1.client.eventsSince(mark), 'game:handEnded', 'ack:game:action', 'the ack follows the hand end');

  // Back to rest, then the countdown for the next hand. Wait for that state
  // BEFORE asserting the order: the settlement transaction now also banks the
  // hand's bets (LIVE_STATE_PLAN.md), so the trailing room:state can land a
  // few ms after game:handEnded rather than in the same breath.
  const rest = await s0.client.waitNext('room:state', (s) => s.state !== 'betting', 4000, s0Mark);
  assertOrder(s0.client.eventsSince(s0Mark), ['game:action', 'game:showdown', 'game:handEnded', 'room:state'], 'showdown order');
  assert.equal(rest.pot, 0);
  assert.equal(rest.turn, null);
  assert.equal(rest.stake, bootAmount);
  assert.equal(rest.seats[winner.seatIndex].status, 'won');
  assert.equal(rest.seats[loser.seatIndex].status, 'lost');
  await s0.client.waitNext('room:state', (s) => s.state === 'starting', 4000, s0Mark);

  // The winner's balance is persisted; both bet beyond the boot, so both "played".
  const winnerEntry = bySeat[winner.seatIndex];
  const loserEntry = bySeat[loser.seatIndex];
  const winnerContributed = ended.summary.find((e) => e.userId === winner.userId).contributed;
  const loserContributed = ended.summary.find((e) => e.userId === loser.userId).contributed;
  await eventually(async () => {
    const w = await me(winnerEntry.account.token);
    assert.equal(w.chips, profile.welcomeChips - winnerContributed + expectedPot);
    assert.equal(w.handsWon, 1);
    assert.equal(w.handsPlayed, 1);
    assert.equal(w.handsLost, 0);
    assert.equal(w.totalWinnings, expectedPot);
    assert.equal(w.biggestPot, expectedPot);
    const l = await me(loserEntry.account.token);
    assert.equal(l.chips, profile.welcomeChips - loserContributed);
    assert.equal(l.handsLost, 1);
    assert.equal(l.handsPlayed, 1);
    assert.equal(l.handsWon, 0);
  });
  assert.equal(rest.seats[winner.seatIndex].chips, profile.welcomeChips - winnerContributed + expectedPot, 'the seat adopts the settled balance');

  // NO CLIENT ACTION ID EVER REACHES THE LEDGER (owner's decision of 9 Sep
  // 2026): a bet writes nothing, and the whole hand lands as one outcome row
  // per player under a server-minted id.
  const client = await query("SELECT COUNT(*) AS n FROM chip_ledger WHERE action_id LIKE 'parity-game-hand-%'");
  assert.equal(Number(client.rows[0].n), 0, 'a client action id reached the ledger');
  const { rows } = await query(
    'SELECT user_id, delta, reason, action_id FROM chip_ledger WHERE hand_id = $1 ORDER BY user_id',
    [ended.handId],
  );
  assert.equal(rows.length, 2, 'one outcome row per player');
  assert.equal(rows.reduce((n, r) => n + r.delta, 0), 0, 'the hand conserved chips');
  for (const row of rows) {
    assert.equal(row.action_id, `${ended.handId}:settle:${row.user_id}`);
    assert.equal(row.reason, row.user_id === winner.userId ? 'hand_win' : 'hand_loss');
  }
  const won = rows.find((r) => r.user_id === winner.userId);
  assert.equal(won.delta, expectedPot - winnerContributed, 'the winner nets the pot less their own stake');

  await closeAll(...t.clients);
});

// ------------------------------------------------------- blind table rules

test('blind table: hidden stacks are null, the ladder runs on, and the fourth blind bet auto-reveals the cards', async () => {
  const t = await dealtTable('blind', uniqueStake, { category: 'blind' });
  const { bootAmount, bySeat } = t;
  const s0 = bySeat[0];
  const s1 = bySeat[1];

  let view = s1.client.state();
  assert.equal(view.category, 'blind');
  assert.equal(view.chipsHidden, true);
  assert.equal(view.maxPot, 0, 'uncapped');
  assert.equal(typeof view.you.chips, 'number');
  assert.equal(view.seats[1].chips, profile.welcomeChips - bootAmount, 'your own seat carries your stack');
  assert.strictEqual(view.seats[0].chips, null, "the other player's stack is null, never 0");
  assert.ok(!JSON.stringify(s1.client.seen).includes(`"chips":${profile.welcomeChips - bootAmount},"status":"active","isBlind":true,"lastBet":0,"lastAction":null,"contributed":${bootAmount},"connected":true,"cardCount":3}`)
    || view.seats[0].chips === null, 'no foreign stack figure on the wire');
  assert.equal(view.seats[0].contributed, bootAmount, 'bets stay public');
  assert.equal(view.you.options.chips, profile.welcomeChips - bootAmount, 'your own options still carry your stack');
  const steps = view.you.options.raiseSteps;
  assert.ok(steps.length > 2, `a public blind table ladders past a seen table's two rungs (${steps.length} rungs)`);
  assert.equal(steps[0], bootAmount);
  for (let i = 1; i < steps.length; i += 1) assert.equal(steps[i], steps[i - 1] * 2);
  assert.ok(steps.at(-1) <= view.you.chips && steps.at(-1) * 2 > view.you.chips, 'stops where the next double would not fit');
  assert.equal(view.you.options.maxBet, steps.at(-1));

  // Both chaal blind. Seat 1's fourth blind bet is charged at the blind rate and then turns its cards up.
  let expectedPot = bootAmount * 2;
  const order = [s1, s0, s1, s0, s1, s0, s1];
  for (let i = 0; i < order.length; i += 1) {
    const actor = order[i];
    await waitTurn(actor.client, actor.user.id, 1);
    const before = actor.client.state();
    assert.equal(before.you.blindMovesLeft, 4 - Math.floor(i / 2), `blind moves left before bet ${i + 1}`);
    const mark = actor.client.mark();
    const ack = await actor.client.emit('game:action', { action: 'chaal', actionId: `parity-game-blind-${i}` });
    const last = i === order.length - 1;
    assert.deepEqual(ack, { ok: true, action: 'chaal', amount: bootAmount, autoSeen: last }, `bet ${i + 1}`);
    expectedPot += bootAmount;
    const actions = actor.client.since(mark).filter((e) => e.event === 'game:action').map((e) => e.payload);
    assert.equal(actions[0].amount, bootAmount, 'a blind chaal at the stake, the fourth included');
    assert.equal(actions[0].stake, bootAmount, 'a blind chaal at the stake keeps it');
    if (last) {
      assert.deepEqual(actions[1], { userId: actor.user.id, action: 'see', amount: 0, auto: true, pot: expectedPot, stake: bootAmount, roomId: t.roomId });
      assert.equal(actor.client.since(mark).filter((e) => e.event === 'player:cards').length, 1, 'the auto-reveal sends the cards');
      assert.deepEqual(collapseRuns(actor.client.eventsSince(mark)).slice(0, 5), ['game:action', 'player:cards', 'game:action', 'room:state', 'game:turn']);
      const after = actor.client.state();
      assert.equal(after.you.isBlind, false);
      assert.equal(after.you.blindMovesLeft, 0);
      assert.equal(after.you.cards.length, 3);
    } else {
      assert.equal(actions.length, 1);
      assert.equal(actor.client.count('player:cards'), 0);
    }
  }
  // The auto-reveal is broadcast, so wait for seat 0's own snapshot of it
  // rather than assuming it has already arrived.
  await s0.client.waitState((v) => v.seats.some((seat) => seat.seatIndex === 1 && !seat.isBlind));
  assert.equal(s0.client.state().seats[1].isBlind, false, 'the reveal is public');
  assert.equal(s0.client.count('player:cards'), 0);
  assert.equal(s0.client.state().pot, expectedPot);
  assert.equal(s0.client.state().round, 3, 'seven bets = three full rotations past the opener');

  // Seat 0 (blind, 3 moves used) now pays a blind chaal; seat 1 (seen) pays double.
  await waitTurn(s0.client, s0.user.id, 1);
  assert.equal(s0.client.state().you.options.chaal, bootAmount);
  const ack = await s0.client.emit('game:action', { action: 'pack' });
  assert.deepEqual(ack, { ok: true, action: 'pack', reason: 'pack' });
  const ended = await s1.client.wait('game:handEnded');
  assert.equal(ended.winnerId, s1.user.id);
  assert.equal(ended.reason, 'last_standing');
  assert.deepEqual(ended.reveals, []);
  assert.equal(ended.pot, expectedPot);
  assert.equal(ended.summary.find((e) => e.userId === s0.user.id).cards, null, 'nothing revealed on a pack');
  assert.equal(ended.summary.find((e) => e.userId === s0.user.id).status, 'packed');
  assert.equal(ended.summary.find((e) => e.userId === s1.user.id).sawCards, true);
  assert.equal(ended.summary.find((e) => e.userId === s1.user.id).cards, null);
  await closeAll(...t.clients);
});

// --------------------------------------------------- timeouts and the kick

test('turn timeouts pack the idler; three misses in a row lose the seat with room:kicked {reason:idle}', async () => {
  const t = await dealtTable('idle', uniqueStake);
  const { bySeat } = t;
  const active = bySeat[0];
  const idler = bySeat[1];
  assert.equal(t.onTurnUser.id, idler.user.id, 'the idler opens hand 1');
  autoAct(active.client, 'chaal');

  const startedAt = Date.now();
  const pack = await active.client.wait('game:action', (a) => a.action === 'pack' && a.reason === 'timeout', profile.turnTimeoutMs + 3000);
  assert.deepEqual(pack, { userId: idler.user.id, action: 'pack', amount: 0, pot: t.bootAmount * 2, stake: t.bootAmount, reason: 'timeout', roomId: t.roomId });
  const elapsed = Date.now() - startedAt;
  assert.ok(elapsed >= profile.turnTimeoutMs - 300 && elapsed <= profile.turnTimeoutMs + 1500, `packed after ${elapsed} ms`);
  const ended1 = await active.client.wait('game:handEnded', (e) => e.handNo === 1);
  assert.equal(ended1.winnerId, active.user.id);
  assert.equal(ended1.reason, 'last_standing');
  assert.equal(ended1.pot, t.bootAmount * 2);
  await idler.client.wait('room:state', (s) => s.you?.missedTurns === 1, 4000);
  assert.equal(active.client.state().you.missedTurns, 0);
  assert.ok(!JSON.stringify(active.client.state().seats).includes('missedTurns'), 'nobody else is told');

  // Hand 2 opens with the active player (dealer rotated); a chaal hands the idler the turn, who times out again.
  const ended2 = await active.client.wait('game:handEnded', (e) => e.handNo === 2, 6000);
  assert.equal(ended2.winnerId, active.user.id);
  await idler.client.wait('room:state', (s) => s.you?.missedTurns === 2, 4000);

  // Hand 3: the third miss. The idler is packed, the hand ends, and then the seat goes.
  const kicked = await idler.client.wait('room:kicked', () => true, 6000);
  assert.deepEqual(kicked, { roomId: t.roomId, reason: 'idle', message: 'Left the table after 3 missed turns' });
  const timeoutPacks = active.client.all('game:action').filter((a) => a.reason === 'timeout' && a.userId === idler.user.id);
  assert.equal(timeoutPacks.length, 3);
  assert.equal(active.client.all('game:handEnded').length, 3);
  const idlerEvents = idler.client.events();
  assertBefore(idlerEvents, 'game:handEnded', 'room:kicked', 'idler');
  assert.ok(!idlerEvents.includes('room:left'), 'a kick is not a leave');
  await eventually(() => {
    const view = active.client.state();
    assert.equal(occupied(view).length, 1);
    assert.equal(view.state, 'waiting', 'the countdown for a fourth hand is cancelled');
    assert.equal(view.seats[1].status, 'empty');
  });
  const line = active.client.all('chat:message').find((m) => m.text === `${idler.user.displayName} left the table`);
  assert.ok(line?.system, 'the room log records the departure');

  // The kicked player is free to sit down again.
  const again = await idler.client.emit('room:quickJoin', { bootAmount: uniqueStake() });
  assert.equal(again.ok, true, JSON.stringify(again));
  assert.equal(idler.client.last('room:joined').you.missedTurns, 0, 'a fresh seat, a clean slate');
  assert.equal(await wallet(idler.user.id), profile.welcomeChips - t.bootAmount * 3, 'three boots lost');
  assert.equal((await me(idler.account.token)).handsLost, 3);
  assert.equal((await me(idler.account.token)).handsPlayed, 0, 'never bet beyond the boot');
  await closeAll(...t.clients);
});

// -------------------------------------------------------- forced showdown

test('a seen table forces a showdown after seven rounds, and a blind bet at the cap still charges the blind rate', async () => {
  const t = await dealtTable('forced', uniqueStake);
  const { bootAmount, bySeat, clients } = t;
  const amounts = [];
  for (const client of clients) {
    client.socket.on('game:action', (a) => { if (['chaal', 'raise'].includes(a.action)) amounts.push(a.amount); });
  }
  // Everybody chaals until the table calls it.
  autoAct(bySeat[0].client, 'chaal');
  autoAct(bySeat[1].client, 'chaal');
  const showdown = await clients[0].wait('game:showdown', () => true, 15000);
  assert.equal(showdown.reason, 'forced_showdown');
  assert.equal(showdown.reveals.length, 2);
  assert.equal(showdown.reveals.filter((r) => r.won).length, 1);
  const ended = await clients[0].wait('game:handEnded');
  assert.equal(ended.reason, 'forced_showdown');
  const settled = ended.summary;
  assert.equal(sum(settled.map((e) => e.contributed)), ended.pot);
  await pause(100);
  const seenActions = clients[0].all('game:action').filter((a) => ['chaal', 'raise'].includes(a.action));
  assert.equal(bootAmount * 2 + sum(seenActions.map((a) => a.amount)), ended.pot, 'the pot is the boots plus every bet');
  assert.equal(seenActions.length, 14, 'two players × seven rounds');
  // The first four bets of each player are blind (100), the rest seen (200); the stake never moved.
  assert.deepEqual(seenActions.map((a) => a.amount), [
    ...Array(8).fill(bootAmount), ...Array(6).fill(bootAmount * 2),
  ]);
  assert.ok(seenActions.every((a) => a.stake === bootAmount));
  assert.equal(clients[0].all('game:action').filter((a) => a.action === 'see' && a.auto === true).length, 2, 'both were auto-revealed');
  assert.equal(clients[0].state().round === 0 || clients[0].state().round === 7, true);
  await closeAll(...clients);
});

// -------------------------------------------------------------- sideshow

/** Three seen players: seat 1 is on turn, seat 0 is on their right. */
const sideshowTable = async (tag) => {
  const t = await dealtTable(tag, uniqueStake, { count: 3 });
  const { bySeat } = t;
  assert.equal(t.onTurnUser.id, bySeat[1].user.id);
  return { ...t, asker: bySeat[1], asked: bySeat[0], bystander: bySeat[2] };
};

test('sideshow: gated by the blocked-reason order, asked of the player on the right, declined → turn straight back, once per turn', async () => {
  const t = await sideshowTable('ssdecline');
  const { asker, asked, bystander, bootAmount } = t;

  assert.equal(asker.client.state().you.options.canSideshow, false);
  let ack = await asker.client.emit('game:action', { action: 'sideshow' });
  assert.deepEqual(ack, { ok: false, code: 'you_are_blind', message: 'See your cards before asking for a sideshow' });
  ack = await bystander.client.emit('game:action', { action: 'sideshow' });
  assert.equal(ack.code, 'not_your_turn');

  await asker.client.emit('game:action', { action: 'see' });
  ack = await asker.client.emit('game:action', { action: 'sideshow' });
  assert.deepEqual(ack, { ok: false, code: 'neighbour_is_blind', message: 'The player on your right has not seen their cards' });
  await asked.client.emit('game:action', { action: 'see' });
  const view = await asker.client.waitState((s) => s.you?.options?.canSideshow === true);
  assert.equal(view.you.options.canSideshow, true, 'once both have seen, the button is offered');
  assert.equal(view.you.options.sideshowWith, asked.user.displayName);

  const askerMark = asker.client.mark();
  const askedMark = asked.client.mark();
  ack = await asker.client.emit('game:action', { action: 'sideshow' });
  assert.deepEqual(ack, { ok: true, action: 'sideshow', toUserId: asked.user.id });
  const requested = await bystander.client.wait('game:sideshowRequested');
  assertKeys(requested, ['fromUserId', 'fromName', 'fromSeat', 'toUserId', 'toName', 'toSeat', 'expiresAt', 'timeoutMs', 'roomId'], 'game:sideshowRequested');
  assert.equal(requested.fromUserId, asker.user.id);
  assert.equal(requested.fromName, asker.user.displayName);
  assert.equal(requested.fromSeat, 1);
  assert.equal(requested.toUserId, asked.user.id);
  assert.equal(requested.toName, asked.user.displayName);
  assert.equal(requested.toSeat, 0);
  assert.equal(requested.timeoutMs, profile.sideshowTimeoutMs);
  assert.ok(requested.expiresAt - Date.now() <= profile.sideshowTimeoutMs + 100);
  assert.ok(!('cards' in requested));
  const pending = await asked.client.waitNext('room:state', (s) => s.sideshow !== null, 4000, askedMark);
  assert.deepEqual(pending.sideshow, {
    fromUserId: asker.user.id, fromSeat: 1, toUserId: asked.user.id, toSeat: 0, expiresAt: requested.expiresAt,
  });
  assert.equal(pending.turn.userId, asker.user.id, 'the turn stays with the asker');
  assert.deepEqual(collapseRuns(asker.client.eventsSince(askerMark)), ['game:sideshowRequested', 'room:state', 'ack:game:action']);

  ack = await asker.client.emit('game:action', { action: 'sideshow' });
  assert.deepEqual(ack, { ok: false, code: 'sideshow_pending', message: 'A sideshow is already in progress' });
  ack = await bystander.client.emit('game:sideshowRespond', { accept: true });
  assert.deepEqual(ack, { ok: false, code: 'not_your_sideshow', message: 'That sideshow was not asked of you' });
  ack = await asker.client.emit('game:sideshowRespond', { accept: true });
  assert.equal(ack.code, 'not_your_sideshow');

  // Declined: nobody packs, no reveal, the asker's clock restarts from full.
  const beforeDecline = asker.client.last('game:turn').deadline;
  const declineMark = asker.client.mark();
  ack = await asked.client.emit('game:sideshowRespond', { accept: false });
  assert.deepEqual(ack, { ok: true, accepted: false, packedUserId: null });
  const resolved = await bystander.client.wait('game:sideshowResolved');
  assertKeys(resolved, ['fromUserId', 'toUserId', 'accepted', 'reason', 'packedUserId', 'roomId'], 'game:sideshowResolved');
  assert.deepEqual(resolved, {
    fromUserId: asker.user.id, toUserId: asked.user.id, accepted: false, reason: 'declined', packedUserId: null, roomId: t.roomId,
  });
  const reTurn = await asker.client.waitNext('game:turn', () => true, 4000, declineMark);
  assert.equal(reTurn.userId, asker.user.id);
  assert.ok(reTurn.deadline > beforeDecline, 'a fresh full clock');
  assert.equal(reTurn.timeoutMs, profile.turnTimeoutMs);
  assert.equal(asker.client.count('game:sideshowReveal'), 0);
  assert.equal(asked.client.count('game:sideshowReveal'), 0);
  assertOrder(asker.client.eventsSince(declineMark), ['game:sideshowResolved', 'game:turn', 'game:yourTurn', 'room:state'], 'asker after decline');
  const afterView = await asker.client.waitNext('room:state', (s) => s.sideshow === null, 4000, declineMark);
  assert.equal(afterView.you.options.canSideshow, false, 'one ask per turn');
  assert.equal(afterView.you.options.chaal, bootAmount * 2);
  assert.equal(afterView.seats[0].status, 'active');

  ack = await asked.client.emit('game:sideshowRespond', { accept: false });
  assert.deepEqual(ack, { ok: false, code: 'no_sideshow', message: 'There is no sideshow to answer' });
  ack = await asker.client.emit('game:action', { action: 'sideshow' });
  assert.deepEqual(ack, { ok: false, code: 'already_asked', message: 'You have already asked for a sideshow this turn' });

  // The next turn (seat 2, blind) is blocked for its own reason; after seeing, its neighbour (seat 1) is seen → allowed.
  ack = await asker.client.emit('game:action', { action: 'chaal' });
  assert.equal(ack.ok, true);
  await waitTurn(bystander.client, bystander.user.id);
  ack = await bystander.client.emit('game:action', { action: 'sideshow' });
  assert.equal(ack.code, 'you_are_blind');
  await bystander.client.emit('game:action', { action: 'see' });
  const byView = await bystander.client.waitState((s) => s.you?.options?.canSideshow === true);
  assert.equal(byView.you.options.sideshowWith, asker.user.displayName, 'the player on the right acted just before');

  await closeAll(...t.clients);
});

test('sideshow accepted: the weaker hand packs, only the two of them see the cards, and the turn follows the rule', async () => {
  const t = await sideshowTable('ssaccept');
  const { asker, asked, bystander } = t;
  await asker.client.emit('game:action', { action: 'see' });
  await asked.client.emit('game:action', { action: 'see' });
  await asker.client.waitState((s) => s.you?.options?.canSideshow === true);

  const marks = { asker: asker.client.mark(), asked: asked.client.mark(), by: bystander.client.mark() };
  let ack = await asker.client.emit('game:action', { action: 'sideshow' });
  assert.equal(ack.ok, true);
  ack = await asked.client.emit('game:sideshowRespond', { accept: true });
  assert.equal(ack.ok, true);
  assert.equal(ack.accepted, true);
  assert.ok([asker.user.id, asked.user.id].includes(ack.packedUserId), 'one of the two packs');
  const loserId = ack.packedUserId;
  const winnerId = loserId === asker.user.id ? asked.user.id : asker.user.id;

  const reveal = await asker.client.waitNext('game:sideshowReveal', () => true, 4000, marks.asker);
  assertKeys(reveal, ['roomId', 'reveal'], 'game:sideshowReveal');
  assertKeys(reveal.reveal, ['reason', 'packedUserId', 'hands'], 'reveal');
  assert.equal(reveal.reveal.reason, 'accepted');
  assert.equal(reveal.reveal.packedUserId, loserId);
  assert.equal(reveal.reveal.hands.length, 2);
  assert.deepEqual(reveal.reveal.hands.map((h) => h.userId), [asker.user.id, asked.user.id], 'asker first');
  for (const hand of reveal.reveal.hands) {
    assertKeys(hand, ['userId', 'displayName', 'cards', 'handName'], 'revealed hand');
    assert.equal(hand.cards.length, 3);
    assert.ok(HAND_NAMES.includes(hand.handName));
  }
  assert.deepEqual(await asked.client.waitNext('game:sideshowReveal', () => true, 4000, marks.asked), reveal);
  await pause(150);
  assert.equal(bystander.client.count('game:sideshowReveal'), 0, 'the third player is never shown the cards');
  const resolved = bystander.client.last('game:sideshowResolved');
  assert.deepEqual(resolved, {
    fromUserId: asker.user.id, toUserId: asked.user.id, accepted: true, reason: 'accepted', packedUserId: loserId, roomId: t.roomId,
  });
  assert.ok(!cardCodesIn(bystander.client.since(marks.by)).includes(reveal.reveal.hands[0].cards[0]), 'no card leaks to the room');
  const pack = bystander.client.since(marks.by).find((e) => e.event === 'game:action' && e.payload.action === 'pack')?.payload;
  assert.equal(pack?.userId, loserId);
  assert.equal(pack?.reason, 'sideshow');
  assertBefore(bystander.client.eventsSince(marks.by), 'game:action', 'game:sideshowResolved', 'the pack is announced before the resolution');

  const view = await bystander.client.waitNext('room:state', (s) => s.sideshow === null && s.seats.some((seat) => seat.userId === loserId && seat.status === 'packed'), 4000, marks.by);
  assert.equal(view.seats.find((s) => s.userId === winnerId).status, 'active');
  if (loserId === asked.user.id) {
    assert.equal(view.turn.userId, asker.user.id, 'the asked player lost: the turn never left the asker');
  } else {
    assert.equal(view.turn.userId, bystander.user.id, 'the asker lost: the turn moves on to the next active seat');
  }
  assert.equal(view.state, 'betting', 'two players left: the hand carries on');
  const onTurn = view.turn.userId === asker.user.id ? asker : bystander;
  const turnView = await onTurn.client.waitState((s) => s.sideshow === null && s.turn?.userId === onTurn.user.id && s.you?.options);
  assert.ok(turnView.you.options.show > 0, 'with two left a show is on offer');
  await closeAll(...t.clients);
});

test('sideshow lapses after the timeout with the turn clock stopped meanwhile; a participant leaving cancels it', async () => {
  const t = await sideshowTable('sslapse');
  const { asker, asked, bystander } = t;
  await asker.client.emit('game:action', { action: 'see' });
  await asked.client.emit('game:action', { action: 'see' });
  await asker.client.waitState((s) => s.you?.options?.canSideshow === true);

  // Ask late in the turn so the lapse (1500 ms) lands after the turn clock (1200 ms) would have expired.
  const turnDeadline = asker.client.last('game:turn').deadline;
  const mark = asker.client.mark();
  const askedAt = Date.now();
  let ack = await asker.client.emit('game:action', { action: 'sideshow' });
  assert.equal(ack.ok, true);
  const resolved = await bystander.client.wait('game:sideshowResolved', () => true, profile.sideshowTimeoutMs + 3000);
  const lapsedAfter = Date.now() - askedAt;
  assert.deepEqual(resolved, {
    fromUserId: asker.user.id, toUserId: asked.user.id, accepted: false, reason: 'timeout', packedUserId: null, roomId: t.roomId,
  });
  assert.ok(lapsedAfter >= profile.sideshowTimeoutMs - 200, `lapsed after ${lapsedAfter} ms`);
  assert.ok(Date.now() > turnDeadline, 'the original turn deadline has passed');
  const reTurn = await asker.client.waitNext('game:turn', () => true, 4000, mark);
  assert.equal(reTurn.userId, asker.user.id, 'still on turn: the clock was stopped while the request stood');
  assert.ok(reTurn.deadline > turnDeadline);
  assert.equal(asker.client.state().you.status, 'active');
  assert.equal(asker.client.all('game:action').filter((a) => a.reason === 'timeout').length, 0);

  // Next turn: seat 2 asks seat 1, and seat 1 leaves → resolved 'left', no reveal, hand continues with two.
  ack = await asker.client.emit('game:action', { action: 'chaal' });
  assert.equal(ack.ok, true);
  await waitTurn(bystander.client, bystander.user.id);
  await bystander.client.emit('game:action', { action: 'see' });
  await bystander.client.waitState((s) => s.you?.options?.canSideshow === true);
  const byMark = bystander.client.mark();
  ack = await bystander.client.emit('game:action', { action: 'sideshow' });
  assert.deepEqual(ack, { ok: true, action: 'sideshow', toUserId: asker.user.id });
  ack = await asker.client.emit('room:leave', {});
  assert.equal(ack.ok, true);
  const left = await bystander.client.waitNext('game:sideshowResolved', () => true, 4000, byMark);
  assert.deepEqual(left, {
    fromUserId: bystander.user.id, toUserId: asker.user.id, accepted: false, reason: 'left', packedUserId: null, roomId: t.roomId,
  });
  const leavePack = await bystander.client.waitNext('game:action', (a) => a.action === 'pack', 4000, byMark);
  assert.equal(leavePack.userId, asker.user.id);
  assert.equal(leavePack.reason, 'left');
  assertBefore(bystander.client.eventsSince(byMark), 'game:sideshowResolved', 'game:action', 'the sideshow is dropped before the leaver is packed');
  assert.equal(bystander.client.count('game:sideshowReveal'), 0);
  const view = await bystander.client.waitNext('room:state', (s) => s.seats[1].status === 'empty', 4000, byMark);
  assert.equal(view.state, 'betting');
  assert.equal(view.sideshow, null);
  assert.equal(view.turn.userId, bystander.user.id);
  assert.ok(view.you.options.show > 0);
  await closeAll(...t.clients);
});

// ------------------------------------------------------ leaving mid-hand

test('leaving mid-hand is a pack: the stake stays in the pot, the last player standing takes it, and the leaver is counted as having left', async () => {
  const t = await dealtTable('leaver', uniqueStake);
  const { bootAmount, onTurn, onTurnUser, waiting, waitingUser } = t;
  const ack = await onTurn.emit('game:action', { action: 'chaal', actionId: 'parity-game-leaver-chaal' });
  assert.equal(ack.ok, true);
  const pot = bootAmount * 3;
  await waitTurn(waiting, waitingUser.id);

  const mark = waiting.mark();
  const left = await onTurn.emit('room:leave', {});
  assert.deepEqual(left, { ok: true, roomId: t.roomId });
  const pack = await waiting.waitNext('game:action', (a) => a.action === 'pack', 4000, mark);
  assert.deepEqual(pack, { userId: onTurnUser.id, action: 'pack', amount: 0, pot, stake: bootAmount, reason: 'left', roomId: t.roomId });
  const ended = await waiting.waitNext('game:handEnded', () => true, 4000, mark);
  assert.equal(ended.winnerId, waitingUser.id);
  assert.equal(ended.winnerName, waitingUser.displayName);
  assert.equal(ended.reason, 'last_standing');
  assert.equal(ended.pot, pot, 'the leaver forfeits their stake');
  assert.deepEqual(ended.reveals, []);
  const leaverEntry = ended.summary.find((e) => e.userId === onTurnUser.id);
  assert.equal(leaverEntry.contributed, bootAmount * 2);
  assert.equal(leaverEntry.status, 'packed');
  assertOrder(waiting.eventsSince(mark), ['chat:message', 'game:action', 'game:handEnded', 'room:state'], 'remaining player');
  const view = await waiting.waitNext('room:state', (s) => occupied(s).length === 1 && s.state === 'waiting', 4000, mark);
  assert.equal(view.you.chips, profile.welcomeChips - bootAmount + pot, 'the pot is credited');

  await eventually(async () => {
    const leaver = await me(t.byUser[onTurnUser.id].account.token);
    assert.equal(leaver.chips, profile.welcomeChips - bootAmount * 2);
    assert.equal(leaver.handsLeftMid, 1);
    assert.equal(leaver.handsLost, 0, 'left, not lost');
    assert.equal(leaver.handsPlayed, 1, 'the chaal counts as having played');
    const stayer = await me(t.byUser[waitingUser.id].account.token);
    assert.equal(stayer.chips, profile.welcomeChips - bootAmount + pot);
    assert.equal(stayer.handsWon, 1);
    assert.equal(stayer.handsPlayed, 0, 'never bet beyond the boot');
  });
  // The leaver is resolved at their OWN checkpoint (hand_left, written the
  // moment they are gone so their wallet is right at once) and is not in the
  // hand-end write; the player still at the table gets the hand_win row.
  const ledger = await query(
    'SELECT user_id, reason, delta, action_id FROM chip_ledger WHERE hand_id = $1 ORDER BY reason',
    [ended.handId],
  );
  assert.deepEqual(ledger.rows.map((r) => r.reason), ['hand_left', 'hand_win']);
  const leaverRow = ledger.rows.find((r) => r.reason === 'hand_left');
  assert.equal(leaverRow.user_id, onTurnUser.id);
  assert.equal(leaverRow.delta, -bootAmount * 2, 'their whole stake, taken when they left');
  assert.equal(leaverRow.action_id, `${ended.handId}:left:${onTurnUser.id}`);
  const winRow = ledger.rows.find((r) => r.reason === 'hand_win');
  assert.equal(winRow.user_id, waitingUser.id);
  assert.equal(winRow.delta, pot - bootAmount, 'the pot less their own boot');
  assert.equal(ledger.rows.reduce((n, r) => n + r.delta, 0), 0, 'the hand conserved chips');
  await closeAll(...t.clients);
});

// ------------------------------------------------------------------ chat

test('room chat: delivery to the room only, exact message shape, backlog for late joiners, sanitising and the 5/5 s limiter', async () => {
  const a = await guestLogin('device-parity-game-chat-a', 'ChatA');
  const b = await guestLogin('device-parity-game-chat-b', 'ChatB');
  const outsider = await guestLogin('device-parity-game-chat-c', 'Outsider');
  const ca = await openClient(a.token);
  const cb = await openClient(b.token);
  const cc = await openClient(outsider.token);

  let ack = await ca.emit('chat:message', { text: 'hello?' });
  assert.deepEqual(ack, { ok: false, code: 'not_in_room', message: 'You are not at a table' });
  ack = await ca.emit('chat:history', {});
  assert.equal(ack.code, 'not_in_room');

  const bootAmount = uniqueStake();
  const joined = await ca.emit('room:quickJoin', { bootAmount });
  await cc.emit('room:quickJoin', { bootAmount: uniqueStake() });

  const mark = ca.mark();
  ack = await ca.emit('chat:message', { text: 'good luck all' });
  assertKeys(ack, ['ok', 'messageId'], 'chat ack');
  assert.match(ack.messageId, UUID);
  const posted = await ca.waitNext('chat:message', (m) => m.text === 'good luck all', 4000, mark);
  assert.deepEqual(Object.keys(posted), ['id', 'userId', 'displayName', 'text', 'at', 'roomId'], 'key order; no system key on a player line');
  assert.equal(posted.id, ack.messageId);
  assert.equal(posted.userId, a.user.id);
  assert.equal(posted.displayName, 'ChatA');
  assert.ok(Math.abs(posted.at - Date.now()) < 5000);
  assert.equal(posted.roomId, joined.roomId);

  // Sanitising: blank → nothing posted (ack ok, no id); long → cut to 140; number → digits; control chars → spaces.
  ack = await ca.emit('chat:message', { text: '   ' });
  assert.deepEqual(ack, { ok: true });
  ack = await ca.emit('chat:message', { text: 'x'.repeat(5000) });
  assert.ok(ack.messageId);
  const long = await ca.waitNext('chat:message', (m) => m.text.startsWith('xxx'), 4000, mark);
  assert.equal(long.text.length, profile.chatMaxLength);
  ack = await ca.emit('chat:message', { text: 12345 });
  const number = await ca.waitNext('chat:message', (m) => m.text === '12345', 4000, mark);
  assert.ok(number);
  ack = await ca.emit('chat:message', { text: ' a b\t\tc  ​d ' });
  const cleaned = await ca.waitNext('chat:message', (m) => m.text.startsWith('a b'), 4000, mark);
  assert.equal(cleaned.text, 'a b c d');
  // That was five sends: the sixth trips the chat limiter, with its own code.
  ack = await ca.emit('chat:message', { text: 'sixth' });
  assert.deepEqual(ack, { ok: false, code: 'chat_rate_limited', message: 'You are sending messages too quickly' });
  await pause(100);
  assert.equal(ca.all('chat:message').filter((m) => m.text === 'sixth').length, 0);

  // A late joiner is sent the backlog, oldest first, system lines included.
  await cb.emit('room:joinCode', { code: joined.code });
  const history = await cb.wait('chat:history');
  assert.equal(history.roomId, joined.roomId);
  const texts = history.messages.map((m) => m.text);
  assert.deepEqual(texts, ['ChatA joined the table', 'good luck all', 'x'.repeat(140), '12345', 'a b c d', 'ChatB joined the table']);
  assert.ok(history.messages.every((m, i) => i === 0 || m.at >= history.messages[i - 1].at), 'oldest first');
  assert.equal(history.messages[0].system, true);
  assert.equal(history.messages[0].userId, null);
  assert.equal(history.messages[0].displayName, 'Table');
  assert.equal(history.messages[1].system, undefined);
  ack = await cb.emit('chat:history', {});
  assert.deepEqual(ack, { ok: true, count: 6 });
  assert.equal(cb.count('chat:history'), 2, 're-sent on request');

  // B's message reaches A, and never the outsider.
  ack = await cb.emit('chat:message', { text: 'hi from B' });
  const heard = await ca.wait('chat:message', (m) => m.text === 'hi from B');
  assert.equal(heard.userId, b.user.id);
  await pause(150);
  assert.equal(cc.all('chat:message').filter((m) => m.userId !== null).length, 0, 'a player at another table never sees it');

  await closeAll(ca, cb, cc);
});
