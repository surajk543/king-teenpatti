/**
 * The Poker family over the socket (Go only; owner, 19 Sep 2026 —
 * go-server/POKER_PLAN.md): 3-Card Poker against the house, 5-Card Draw,
 * Texas Hold'em and Omaha as rooms beside the Teen Patti tables.
 *
 * What is pinned here is the wire: the poker snapshot's exact key sets (and
 * that a Teen Patti snapshot gained none of them), that a poker room never
 * sends a game:* event nor a Teen Patti table a poker:* one, that every hole
 * card stays with its owner (a deep scan of every frame every client
 * received), that the board is public, the options on each turn and the
 * refusals off it, a hand of each variant to its end, and — with an
 * INDEPENDENT evaluator (lib/poker5.mjs, written from the rules, not ported)
 * — that every reveal's `best` and `handName` are what the cards make.
 *
 * Profile assumptions (tools/parity.mjs "poker"): 60 s clocks, TABLE_STAKES
 * and LOBBY_TABLES lifted (any pair; a poker room needs no menu entry to open,
 * only to be advertised).
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  guestLogin, openClient, closeOpenClients, closeAll, assertKeys, CARD_CODE, SNAPSHOT_KEYS, YOU_KEYS, SEAT_KEYS,
  stakeCounter, dealtTable,
} from './lib/harness.mjs';
import { closeDb, wallet } from './lib/db.mjs';
import { bestOf, bestOmaha, evaluate5, evaluate3, compare, dealerQualifies } from './lib/poker5.mjs';

test.after(async () => {
  await closeOpenClients();
  await closeDb();
});

const uniqueStake = stakeCounter(9000);

export const POKER_SNAPSHOT_KEYS = [
  'roomId', 'code', 'isPrivate', 'game', 'category', 'chipsHidden', 'state', 'handNo', 'dealerSeat', 'maxPlayers',
  'minPlayers', 'bootAmount', 'turnTimeoutMs', 'startsAt', 'pot', 'turn', 'you', 'seats', 'poker',
];
export const POKER_BLOCK_KEYS = [
  'variant', 'street', 'community', 'pots', 'currentBet', 'minRaise', 'smallBlind', 'bigBlind', 'ante', 'holeCards',
  'maxDiscards', 'minBuyIn',
];
export const POKER_YOU_KEYS = [
  'seatIndex', 'chips', 'status', 'cards', 'contributed', 'streetBet', 'allIn', 'missedTurns', 'maxMissedTurns', 'options',
];
export const POKER_SEAT_KEYS = [
  'seatIndex', 'userId', 'displayName', 'avatarUrl', 'chips', 'status', 'connected', 'cardCount', 'contributed',
  'streetBet', 'allIn', 'lastAction', 'dealer',
];
export const POKER_OPTIONS_KEYS = [
  'street', 'fold', 'check', 'call', 'callAmount', 'bet', 'minBet', 'maxBet', 'raise', 'minRaise', 'maxRaise', 'allIn',
  'allInAmount', 'play', 'playAmount', 'draw', 'maxDiscards',
];
const VARIANTS = ['three_card_poker', 'five_card_draw', 'texas_holdem', 'omaha'];
const HOLE = { three_card_poker: 3, five_card_draw: 5, texas_holdem: 2, omaha: 4 };

/** The refusal also arrives as a game:error with the same code and message. */
const expectError = async (client, ack) => {
  const error = await client.wait('game:error', (e) => e.code === ack.code && e.message === ack.message, 2000);
  assert.deepEqual(error, { code: ack.code, message: ack.message });
};

/** Every card code anywhere in a JSON value. */
const cardCodesIn = (value, out = []) => {
  if (typeof value === 'string') {
    if (CARD_CODE.test(value)) out.push(value);
  } else if (Array.isArray(value)) {
    for (const v of value) cardCodesIn(v, out);
  } else if (value && typeof value === 'object') {
    for (const v of Object.values(value)) cardCodesIn(v, out);
  }
  return out;
};

/**
 * Seats `count` fresh guests at a poker room of their own and waits for the
 * deal: the snapshot with somebody on turn.
 */
const pokerTable = async (tag, category, { count = 2 } = {}) => {
  const bootAmount = uniqueStake();
  const entries = [];
  for (let i = 0; i < count; i += 1) {
    const account = await guestLogin(`device-parity-poker-${tag}-${i}`, `${tag}${i}`);
    const client = await openClient(account.token);
    const ack = await client.emit('room:quickJoin', { bootAmount, category });
    assert.equal(ack.ok, true, `quickJoin for ${tag}${i}: ${JSON.stringify(ack)}`);
    assert.equal(ack.category, category, 'an old server seats a poker request at a seen table; the ack is how a client tells');
    entries.push({ account, user: account.user, client, cards: [] });
  }
  const clients = entries.map((e) => e.client);
  const joined = clients[0].last('ack:room:quickJoin');
  const started = await clients[0].wait('poker:handStarted', (p) => p.participants.length === count, 6000);
  for (const entry of entries) {
    await entry.client.wait('room:state', (p) => p.handNo === started.handNo && p.state === 'betting' && p.turn?.userId, 6000);
    const cards = await entry.client.wait('poker:cards', () => true, 4000);
    entry.cards = cards.cards;
  }
  const byId = Object.fromEntries(entries.map((e) => [e.user.id, e]));
  const onTurn = () => byId[clients[0].state().turn.userId];
  // Every poker:turn from the first is followed through nextTurn; the mark
  // starts where the deal's first turn was recorded.
  const firstTurn = clients[0].seen.findIndex((e) => e.event === 'poker:turn');
  return { bootAmount, entries, clients, joined, started, byId, onTurn, roomId: joined.roomId, turnMark: firstTurn };
};

/** Waits for the snapshot that puts `userId` on turn with options. */
const myTurn = (entry) => entry.client.waitState((p) => p.turn?.userId === entry.user.id && p.you.options, 6000);

/**
 * The next player on turn, from the room's poker:turn events rather than the
 * latest snapshot — a snapshot read the instant after a move can still be
 * the one that put the mover on turn. Call `t.mark()` before the move.
 */
const nextTurn = async (t) => {
  const turn = await t.clients[0].waitNext('poker:turn', () => true, 6000, t.turnMark);
  t.turnMark = t.clients[0].seen.length;
  return t.byId[turn.userId];
};

/** Acts and expects success. */
const act = async (entry, payload) => {
  const ack = await entry.client.emit('poker:action', payload);
  assert.equal(ack.ok, true, `${entry.user.displayName} ${JSON.stringify(payload)}: ${JSON.stringify(ack)}`);
  return ack;
};

test('a poker room has its own snapshot, with exactly these keys, and a Teen Patti table gained none of them', async () => {
  const t = await pokerTable('shape', 'texas_holdem');
  const state = t.clients[0].state();
  assertKeys(state, POKER_SNAPSHOT_KEYS, 'poker room:state');
  assertKeys(state.poker, POKER_BLOCK_KEYS, 'room:state.poker');
  assertKeys(state.you, POKER_YOU_KEYS, 'room:state.you');
  assertKeys(state.you.options, POKER_OPTIONS_KEYS, 'you.options');
  for (const seat of state.seats) {
    if (seat.status === 'empty') assertKeys(seat, ['seatIndex', 'status'], 'empty seat');
    else assertKeys(seat, POKER_SEAT_KEYS, 'seat');
  }
  assert.equal(state.game, 'poker');
  assert.equal(state.category, 'texas_holdem');
  assert.equal(state.poker.variant, 'texas_holdem');
  assert.equal(state.chipsHidden, false, 'poker stacks are public');
  assert.equal(state.poker.bigBlind, t.bootAmount);
  assert.equal(state.poker.smallBlind, t.bootAmount / 2);
  assert.equal(state.poker.ante, 0);
  assert.equal(state.poker.holeCards, 2);
  assert.equal(state.poker.street, 'preflop');
  assert.deepEqual(state.poker.community, []);
  assert.equal(state.pot, t.bootAmount + t.bootAmount / 2, 'the blinds are the pot');
  assert.deepEqual(state.poker.pots, [], 'nothing has been collected yet: the blinds stand in front of their seats');
  for (const seat of state.seats) {
    if (seat.status === 'empty') continue;
    assert.ok([0, t.bootAmount / 2, t.bootAmount].includes(seat.streetBet), `street bet ${seat.streetBet}`);
  }
  assert.equal(state.you.cards.length, 2);
  for (const seat of state.seats) {
    if (seat.status === 'empty') continue;
    assert.equal(seat.cardCount, 2);
    assert.equal(typeof seat.chips, 'number', 'every stack is a figure');
  }
  // A Teen Patti table's snapshot is exactly what it was: no game key, no poker block.
  const tp = await dealtTable('poker-shape-tp', uniqueStake, { category: 'seen' });
  assertKeys(tp.state, SNAPSHOT_KEYS, 'seen room:state');
  assertKeys(tp.state.you, YOU_KEYS, 'seen you');
  for (const seat of tp.state.seats) {
    if (seat.status !== 'empty') assertKeys(seat, SEAT_KEYS, 'seen seat');
  }
  await closeAll(...t.clients, ...tp.clients);
});

test('a poker room sends no Teen Patti event and refuses every Teen Patti move; a Teen Patti table refuses poker:action', async () => {
  const t = await pokerTable('wall', 'omaha');
  const mover = t.onTurn();
  for (const [event, payload] of [
    ['game:action', { action: 'chaal' }],
    ['game:sideshowRespond', { accept: true }],
    ['game:selectVariation', { variation: 'MUFLIS' }],
    ['player:requestCards', {}],
  ]) {
    const ack = await mover.client.emit(event, payload);
    assert.deepEqual(ack, { ok: false, code: 'wrong_game', message: 'That move belongs to a different game' }, event);
    await expectError(mover.client, ack);
  }
  for (const client of t.clients) {
    for (const event of client.events()) {
      assert.ok(!/^game:(handStarted|turn|yourTurn|showdown|handEnded|action)$|^player:hand$|^player:cards$/.test(event),
        `a poker player received ${event}`);
    }
  }
  const tp = await dealtTable('poker-wall-tp', uniqueStake, { category: 'seen' });
  const ack = await tp.onTurn.emit('poker:action', { action: 'check' });
  assert.deepEqual(ack, { ok: false, code: 'wrong_game', message: 'That move belongs to a different game' });
  const lobby = await guestLogin('device-parity-poker-lobby', 'PokerLobby');
  const client = await openClient(lobby.token);
  const unseated = await client.emit('poker:action', { action: 'check' });
  assert.deepEqual(unseated, { ok: false, code: 'not_in_room', message: 'You are not at a table' });
  await closeAll(...t.clients, ...tp.clients, client);
});

test('Texas Hold\'em: blinds, the options on each street, the board dealt in public, a showdown the oracle agrees with, and chips conserved', async () => {
  const t = await pokerTable('holdem', 'texas_holdem');
  const before = {};
  for (const e of t.entries) before[e.user.id] = await wallet(e.user.id);
  // Heads-up: the button posts the small blind and acts first, facing the big blind.
  const first = t.onTurn();
  const second = t.entries.find((e) => e !== first);
  let state = await myTurn(first);
  const o = state.you.options;
  assert.equal(o.street, 'preflop');
  assert.deepEqual([o.fold, o.check, o.call, o.callAmount, o.bet, o.raise, o.allIn], [true, false, true, t.bootAmount / 2, false, true, true]);
  assert.equal(o.minRaise, t.bootAmount * 2, 'a raise is at least a big blind more');
  assert.equal(o.maxRaise, o.allInAmount);
  assert.equal(o.play, false);
  assert.equal(o.draw, false);

  // Off turn and off street.
  let ack = await second.client.emit('poker:action', { action: 'call' });
  assert.deepEqual(ack, { ok: false, code: 'not_your_turn', message: 'It is not your turn' });
  await expectError(second.client, ack);
  ack = await first.client.emit('poker:action', { action: 'check' });
  assert.deepEqual(ack, { ok: false, code: 'invalid_action', message: 'You cannot check: there is a bet to call' });
  ack = await first.client.emit('poker:action', { action: 'raise', amount: 1 });
  assert.equal(ack.code, 'invalid_amount');
  ack = await first.client.emit('poker:action', { action: 'raise', amount: 'lots' });
  assert.deepEqual(ack, { ok: false, code: 'invalid_amount', message: 'Bet must be a whole number' });
  ack = await first.client.emit('poker:action', { action: 'draw', cards: [] });
  assert.deepEqual(ack, { ok: false, code: 'invalid_action', message: 'It is not the draw' });
  ack = await first.client.emit('poker:action', { action: 'dance' });
  assert.deepEqual(ack, { ok: false, code: 'unknown_action', message: 'Unknown action "dance"' });

  // Raise, call: the flop.
  await nextTurn(t); // the first turn, already on
  ack = await act(first, { action: 'raise', amount: t.bootAmount * 3, actionId: 'r1' });
  assert.deepEqual(ack, { ok: true, action: 'raise', amount: t.bootAmount * 3 });
  const replay = await second.client.emit('poker:action', { action: 'call', actionId: 'r1' });
  assert.deepEqual(replay, { ok: false, code: 'duplicate_action', message: 'That move was already received' });
  assert.equal((await nextTurn(t)), second);
  await myTurn(second);
  ack = await act(second, { action: 'call' });
  assert.deepEqual(ack, { ok: true, action: 'call', amount: t.bootAmount * 3 });
  const flop = await t.clients[0].wait('poker:street', (p) => p.street === 'flop', 4000);
  assert.equal(flop.community.length, 3);
  assert.ok(flop.community.every((c) => CARD_CODE.test(c)));
  assert.equal(flop.pot, t.bootAmount * 6);
  // Postflop the big blind (not the button) acts first, and may check.
  state = await t.clients[0].waitState((p) => p.poker.street === 'flop' && p.turn?.userId, 4000);
  assert.equal(state.turn.userId, second.user.id);
  assert.deepEqual(state.poker.community, flop.community);
  assert.equal(state.poker.pots.length, 1, 'the preflop bets were collected into the pot');
  assert.equal(state.poker.pots[0].amount, t.bootAmount * 6);
  for (const street of ['flop', 'turn', 'river']) {
    for (let i = 0; i < 2; i += 1) {
      const entry = await nextTurn(t);
      const s = await myTurn(entry);
      assert.equal(s.poker.street, street);
      assert.equal(s.you.options.check, true);
      assert.equal(s.you.options.bet, true);
      assert.equal(s.you.options.minBet, t.bootAmount);
      await act(entry, { action: 'check' });
    }
    if (street !== 'river') await t.clients[0].wait('poker:street', (p) => p.street === (street === 'flop' ? 'turn' : 'river'), 4000);
  }
  const showdown = await t.clients[0].wait('poker:showdown', () => true, 4000);
  assert.equal(showdown.reason, 'showdown');
  assert.equal(showdown.community.length, 5);
  assert.equal(showdown.reveals.length, 2);
  for (const reveal of showdown.reveals) {
    assertKeys(reveal, ['userId', 'seatIndex', 'cards', 'best', 'handName', 'category', 'won'], 'reveal');
    const entry = t.byId[reveal.userId];
    assert.deepEqual(reveal.cards, entry.cards, 'a reveal shows the hole cards its owner was dealt');
    const oracle = bestOf([...reveal.cards, ...showdown.community]);
    assert.equal(reveal.handName, oracle.hand.name, `oracle says ${oracle.hand.name} for ${reveal.cards} + ${showdown.community}`);
    assert.equal(reveal.category, oracle.hand.category);
    assert.equal(compare(evaluate5(reveal.best), oracle.hand), 0, `best ${reveal.best} is as strong as the oracle's ${oracle.cards}`);
  }
  const ended = await t.clients[0].wait('poker:handEnded', () => true, 4000);
  assertKeys(ended, ['handId', 'handNo', 'variant', 'reason', 'pot', 'pots', 'reveals', 'community', 'summary', 'nextHandAt', 'roomId'], 'handEnded');
  assert.equal(ended.pot, t.bootAmount * 6);
  const paid = ended.pots.flatMap((p) => p.winners).reduce((sum, w) => sum + w.amount, 0);
  assert.equal(paid, ended.pot, 'every chip on the table was paid out');
  const winners = showdown.reveals.filter((r) => r.won > 0).map((r) => r.userId);
  assert.ok(winners.length >= 1);
  // The books: each wallet moved by exactly what the seat did.
  const final = t.clients[0].all('room:state').find((p) => p.handNo === ended.handNo && p.state !== 'betting')
    ?? await t.clients[0].waitState((p) => p.state !== 'betting', 4000);
  let total = 0;
  for (const seat of final.seats) {
    if (seat.status === 'empty') continue;
    assert.equal(await wallet(seat.userId), seat.chips, `${seat.displayName}'s wallet follows the seat`);
    total += seat.chips;
  }
  assert.equal(total, Object.values(before).reduce((a, b) => a + b, 0), 'chips were neither created nor lost');
  // Nobody ever saw anybody else's hole cards.
  for (const entry of t.entries) {
    const mine = new Set(entry.cards);
    const others = new Set(t.entries.filter((e) => e !== entry).flatMap((e) => e.cards));
    for (const frame of entry.client.seen) {
      if (frame.event === 'poker:showdown' || frame.event === 'poker:handEnded' || frame.event.startsWith('ack:')) continue;
      if (frame.event === 'room:state' && frame.payload?.poker?.result) continue;
      for (const code of cardCodesIn(frame.payload)) {
        if (mine.has(code) || showdown.community.includes(code)) continue;
        assert.ok(!others.has(code), `${entry.user.displayName} saw ${code} in ${frame.event} before the showdown`);
      }
    }
  }
  await closeAll(...t.clients);
});

test('Texas Hold\'em: folding to one player ends the hand without a showdown, and the pot goes to them', async () => {
  const t = await pokerTable('fold', 'texas_holdem');
  const first = t.onTurn();
  const second = t.entries.find((e) => e !== first);
  await myTurn(first);
  await act(first, { action: 'raise', amount: t.bootAmount * 4 });
  await myTurn(second);
  await act(second, { action: 'fold' });
  const ended = await t.clients[0].wait('poker:handEnded', () => true, 4000);
  assert.equal(ended.reason, 'last_standing');
  assert.deepEqual(ended.reveals, []);
  assert.equal(t.clients[0].count('poker:showdown'), 0);
  assert.equal(ended.pots[0].winners[0].userId, first.user.id);
  assert.equal(ended.pots[0].winners[0].amount, t.bootAmount * 5);
  await closeAll(...t.clients);
});

test('Omaha: four hole cards, and every reveal is the best of exactly two of them with three of the board', async () => {
  const t = await pokerTable('omaha', 'omaha');
  assert.equal(t.clients[0].state().you.cards.length, 4);
  assert.equal(t.clients[0].state().poker.holeCards, 4);
  // Check it down.
  for (let i = 0; i < 8; i += 1) {
    const entry = await nextTurn(t);
    const s = await myTurn(entry);
    await act(entry, { action: s.you.options.check ? 'check' : 'call' });
  }
  const showdown = await t.clients[0].wait('poker:showdown', () => true, 4000);
  for (const reveal of showdown.reveals) {
    const oracle = bestOmaha(reveal.cards, showdown.community);
    assert.equal(reveal.handName, oracle.hand.name, `oracle: ${reveal.cards} + ${showdown.community}`);
    assert.equal(reveal.best.filter((c) => reveal.cards.includes(c)).length, 2, `best ${reveal.best} uses two hole cards`);
    assert.equal(reveal.best.filter((c) => showdown.community.includes(c)).length, 3, `best ${reveal.best} uses three board cards`);
  }
  await closeAll(...t.clients);
});

test('5-Card Draw: an ante each, five cards, a draw that exchanges only the cards named, and a showdown on five', async () => {
  const t = await pokerTable('draw', 'five_card_draw');
  const state = t.clients[0].state();
  assert.equal(state.poker.ante, t.bootAmount);
  assert.equal(state.poker.bigBlind, 0);
  assert.equal(state.pot, t.bootAmount * 2);
  assert.equal(state.you.cards.length, 5);
  assert.equal(state.poker.street, 'predraw');
  assert.equal(state.poker.maxDiscards, 3);
  for (let i = 0; i < 2; i += 1) {
    const entry = await nextTurn(t);
    await myTurn(entry);
    await act(entry, { action: 'check' });
  }
  const draw = await t.clients[0].wait('poker:street', (p) => p.street === 'draw', 4000);
  assert.deepEqual(draw.community, []);
  const drawer = await nextTurn(t);
  const s = await myTurn(drawer);
  assert.equal(s.you.options.draw, true);
  assert.equal(s.you.options.maxDiscards, 3);
  assert.equal(s.you.options.fold, false, 'nobody folds at the draw');
  const held = [...drawer.cards];
  let ack = await drawer.client.emit('poker:action', { action: 'draw', cards: ['Zz'] });
  assert.deepEqual(ack, { ok: false, code: 'invalid_discard', message: 'That is not one of your cards' });
  ack = await drawer.client.emit('poker:action', { action: 'draw', cards: [held[0], held[0]] });
  assert.deepEqual(ack, { ok: false, code: 'invalid_discard', message: 'A card was named twice' });
  ack = await drawer.client.emit('poker:action', { action: 'draw', cards: held.slice(0, 4) });
  assert.deepEqual(ack, { ok: false, code: 'invalid_discard', message: 'You may exchange at most 3 cards' });
  const mark = drawer.client.seen.length;
  ack = await act(drawer, { action: 'draw', cards: held.slice(0, 2) });
  assert.deepEqual(ack, { ok: true, action: 'draw', discarded: 2 });
  const fresh = await drawer.client.waitNext('poker:cards', () => true, 4000, mark);
  assert.equal(fresh.cards.length, 5);
  assert.deepEqual(fresh.cards.slice(2), held.slice(2), 'the kept cards stay where they were');
  assert.ok(!held.includes(fresh.cards[0]) && !held.includes(fresh.cards[1]), 'the exchanged cards are new');
  drawer.cards = fresh.cards;
  const drew = await t.clients[0].wait('poker:draw', (p) => p.userId === drawer.user.id, 4000);
  assert.equal(drew.discarded, 2, 'the room hears how many, never which');
  const other = await nextTurn(t);
  assert.notEqual(other, drawer);
  await myTurn(other);
  ack = await act(other, { action: 'draw' });
  assert.deepEqual(ack, { ok: true, action: 'draw', discarded: 0 });
  await t.clients[0].wait('poker:street', (p) => p.street === 'postdraw', 4000);
  for (let i = 0; i < 2; i += 1) {
    const entry = await nextTurn(t);
    await myTurn(entry);
    await act(entry, { action: 'check' });
  }
  const showdown = await t.clients[0].wait('poker:showdown', () => true, 4000);
  for (const reveal of showdown.reveals) {
    assert.deepEqual(reveal.cards, t.byId[reveal.userId].cards);
    assert.equal(reveal.handName, evaluate5(reveal.cards).name);
    assert.deepEqual(reveal.best, reveal.cards);
  }
  await closeAll(...t.clients);
});

test('3-Card Poker: an ante, a decision each against the dealer, and a verdict the oracle agrees with', async () => {
  const t = await pokerTable('three', 'three_card_poker', { count: 3 });
  const state = t.clients[0].state();
  assert.equal(state.poker.street, 'decision');
  assert.equal(state.you.cards.length, 3);
  assert.deepEqual(state.poker.dealer, { cardCount: 3, cards: [] }, 'the dealer holds three, face down');
  assert.equal(state.pot, t.bootAmount * 3);
  const decisions = {};
  for (let i = 0; i < 3; i += 1) {
    const entry = await nextTurn(t);
    const s = await myTurn(entry);
    assert.equal(s.you.options.play, true);
    assert.equal(s.you.options.playAmount, t.bootAmount);
    assert.equal(s.you.options.fold, true);
    assert.equal(s.you.options.check, false);
    const action = i === 2 ? 'fold' : 'play';
    decisions[entry.user.id] = action;
    const ack = await act(entry, { action });
    if (action === 'play') assert.deepEqual(ack, { ok: true, action: 'play', amount: t.bootAmount });
  }
  const showdown = await t.clients[0].wait('poker:showdown', () => true, 4000);
  assert.equal(showdown.reason, 'dealer');
  assert.equal(showdown.dealer.cards.length, 3);
  const dealer = evaluate3(showdown.dealer.cards);
  assert.equal(showdown.dealer.handName, dealer.name);
  assert.equal(showdown.dealer.qualified, dealerQualifies(dealer));
  assert.equal(showdown.reveals.length, 2, 'the folded player is not revealed');
  for (const reveal of showdown.reveals) {
    const hand = evaluate3(reveal.cards);
    assert.equal(reveal.handName, hand.name);
    let expected;
    if (!showdown.dealer.qualified) expected = 'win';
    else {
      const d = compare(hand, dealer);
      expected = d > 0 ? 'win' : d < 0 ? 'lose' : 'push';
    }
    assert.equal(reveal.outcome, expected, `${reveal.cards} vs dealer ${showdown.dealer.cards}`);
    const staked = t.bootAmount * 2;
    const back = { win: showdown.dealer.qualified ? staked * 2 : t.bootAmount * 3, lose: 0, push: staked }[expected];
    assert.equal(reveal.won, back);
  }
  const ended = await t.clients[0].wait('poker:handEnded', () => true, 4000);
  assert.equal(ended.reason, 'dealer');
  assert.ok(ended.dealer);
  // The snapshot that followed the hand's end — the seats hold the result.
  const final = t.clients[0].all('room:state').find((p) => p.handNo === ended.handNo && p.state !== 'betting')
    ?? await t.clients[0].waitState((p) => p.state !== 'betting', 4000);
  for (const seat of final.seats) {
    if (seat.status === 'empty') continue;
    assert.equal(await wallet(seat.userId), seat.chips, `${seat.displayName}'s wallet follows the seat`);
  }
  await closeAll(...t.clients);
});
