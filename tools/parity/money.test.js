/**
 * The books, audited after everything the other suites played on this server
 * (invalidMoves #16 and the CLAUDE.md §4/§12.1 psql checks, over the whole
 * schema).
 *
 * Since 9 Sep 2026 PostgreSQL holds MONEY AND AUDIT ONLY — `users` and
 * `chip_ledger`, nothing else — and it is written at exactly three moments
 * per hand: a player packs, a player leaves or switches, and the hand ends.
 * The deal and every bet move chips in Redis and nowhere else. So this suite
 * checks:
 *
 *   - SUM(chip_ledger.delta) == users.chips for every user. That is now the
 *     ONLY money cross-check in the system, so treat it as load-bearing;
 *   - every hand's rows sum to zero: chips moved between wallets, none were
 *     created or destroyed;
 *   - every row carries a known reason, a server-minted action id of the
 *     right shape, and a balance that follows the running total;
 *   - a hand_win row pays the pot less the winner's own stake; a player is
 *     resolved exactly once (one outcome row per hand per player);
 *   - the counters (handsWon / totalWinnings / biggestPot) follow the
 *     hand_win rows;
 *   - the schema has no game state: no game_states, no pots, no hands (the
 *     four table configuration tables are configuration, argued below);
 *   - the append-only trigger refuses UPDATE/DELETE on chip_ledger.
 *
 * Runs last in each profile (tools/parity.mjs appends it), but is also safe to
 * run on its own against a schema that has seen no play.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { query, closeDb } from './lib/db.mjs';

test.after(closeDb);

// The vocabulary of chip_ledger.reason. `boot`, `bet` and `show` are retired
// (they belonged to the per-bet model) and must not appear in a fresh schema.
const REASONS = new Set([
  'welcome_bonus', 'hand_win', 'hand_loss', 'hand_packed', 'hand_left', 'milestone_reward', 'timed_bonus', 'daily_bonus',
  'lucky_draw', 'picture_purchase', 'table_picture_purchase', 'emoji_purchase', 'test_fixture',
]);
const CHECKPOINT_REASONS = new Set(['hand_win', 'hand_loss', 'hand_packed', 'hand_left']);

test('every wallet equals the sum of its ledger', async () => {
  const { rows } = await query(`
    SELECT u.id, u.display_name, u.chips, COALESCE(l.total, 0) AS total, COALESCE(l.n, 0) AS n
      FROM users u
      LEFT JOIN (SELECT user_id, SUM(delta) AS total, COUNT(*) AS n FROM chip_ledger GROUP BY user_id) l
        ON l.user_id = u.id`);
  // (An empty schema — the audit run on its own — has nothing to reconcile, which is fine.)
  for (const row of rows) {
    assert.equal(row.chips, row.total, `wallet of ${row.display_name} (${row.id}): chips ${row.chips} vs ledger ${row.total}`);
    assert.ok(row.n >= 1, `${row.display_name} has at least the welcome row`);
    assert.ok(row.chips >= 0, 'never overdrawn');
  }
  const mismatch = await query(`
    SELECT count(*) AS n FROM users u
      JOIN (SELECT user_id, SUM(delta) AS s FROM chip_ledger GROUP BY user_id) l ON l.user_id = u.id
     WHERE l.s <> u.chips`);
  assert.equal(mismatch.rows[0].n, 0, 'the CLAUDE.md reconciliation query returns 0');
});

test('every ledger row has a known reason, a balance that follows the running total, and the right sign', async () => {
  const { rows } = await query('SELECT id, user_id, hand_id, action_id, delta, balance, reason, created_at, game, variant FROM chip_ledger ORDER BY user_id, id');
  const running = new Map();
  for (const row of rows) {
    assert.ok(REASONS.has(row.reason), `reason ${row.reason}`);
    const before = running.get(row.user_id) ?? 0;
    const after = before + row.delta;
    running.set(row.user_id, after);
    assert.equal(row.balance, Math.max(0, after), `balance follows the running total for ${row.user_id}`);
    assert.ok(row.created_at > 0);
    if (CHECKPOINT_REASONS.has(row.reason)) {
      assert.ok(row.hand_id, `${row.reason} names its hand`);
      assert.ok(row.action_id, `${row.reason} carries an action id`);
      const verb = { hand_win: 'settle', hand_loss: 'settle', hand_packed: 'packed', hand_left: 'left' }[row.reason];
      assert.equal(row.action_id, `${row.hand_id}:${verb}:${row.user_id}`,
        'every checkpoint action id is server-minted — no client id ever reaches the ledger');
    }
    if (['welcome_bonus', 'milestone_reward', 'timed_bonus', 'daily_bonus', 'lucky_draw'].includes(row.reason)) assert.ok(row.delta > 0);
    // A premium picture is a chip SINK: the row only ever takes chips away.
    if (row.reason === 'picture_purchase') {
      assert.ok(row.delta < 0, 'buying a picture only ever takes chips');
      assert.ok(row.action_id?.startsWith('picture:'), 'a picture purchase carries its own action id');
    }
    // So is a table picture (15 Sep 2026; merged 23 Sep 2026): action_id
    // table:<user>:<picture>:<n>, n counting that pair's purchases so a lapsed
    // rental can be bought again.
    if (row.reason === 'table_picture_purchase') {
      assert.ok(row.delta < 0, 'buying a table picture only ever takes chips');
      assert.ok(row.action_id?.startsWith(`table:${row.user_id}:`), 'a table picture purchase carries its own action id');
    }
    // And so is a chip-priced emoji (26 Sep 2026): action_id
    // emoji:<user>:<emoji>:<n>, n counting that pair's purchases.
    if (row.reason === 'emoji_purchase') {
      assert.ok(row.delta < 0, 'buying an emoji only ever takes chips');
      assert.ok(row.action_id?.startsWith(`emoji:${row.user_id}:`), 'an emoji purchase carries its own action id');
    }
    // A Teen Patti win pays; a poker win may be a split that returns exactly
    // the stake (delta 0), or a 3-Card Poker push — never a loss.
    if (row.reason === 'hand_win') assert.ok(row.game === 'poker' ? row.delta >= 0 : row.delta > 0, 'a win pays');
    if (row.reason === 'hand_packed') assert.ok(row.delta <= 0, 'a pack only ever takes chips');
    // The family columns (chip_ledger.game / .variant, V1.0.0__baseline.sql):
    // NULL on every Teen Patti row, the poker family and one of its four
    // variants on a poker row.
    if (row.game === null) assert.equal(row.variant, null, 'a Teen Patti row names no variant');
    else {
      assert.equal(row.game, 'poker');
      assert.ok(['three_card_poker', 'five_card_draw', 'texas_holdem', 'omaha'].includes(row.variant), `variant ${row.variant}`);
    }
  }
});

test('every hand conserves chips, and resolves each player exactly once', async () => {
  // A 3-Card Poker hand is played against the house, which has no wallet:
  // chips a player wins enter the economy and chips they lose leave it, as a
  // reward or a picture purchase moves them (POKER_PLAN.md §6). Every other
  // hand — Teen Patti and player-versus-player poker alike — sums to zero.
  const { rows: hands } = await query(
    `SELECT hand_id, SUM(delta) AS net, COUNT(*) AS rows FROM chip_ledger
      WHERE hand_id IS NOT NULL AND (variant IS NULL OR variant <> 'three_card_poker') GROUP BY hand_id`);
  for (const hand of hands) {
    assert.equal(Number(hand.net), 0, `hand ${hand.hand_id} moved ${hand.net} chips into or out of the economy`);
  }
  // One OUTCOME row per player per hand (hand_win / hand_loss / hand_left).
  // A packer also has a hand_packed row — that is the money moving early —
  // but never two outcomes.
  const { rows: dupes } = await query(
    `SELECT hand_id, user_id, COUNT(*) AS n FROM chip_ledger
      WHERE reason IN ('hand_win', 'hand_loss', 'hand_left')
      GROUP BY hand_id, user_id HAVING COUNT(*) > 1`);
  assert.deepEqual(dupes, [], 'a player was resolved twice in one hand');
  // A Teen Patti hand has exactly one winner; a poker hand may split a pot or
  // pay several side pots, and against the house every player who beat the
  // dealer wins.
  const { rows: winners } = await query(
    `SELECT hand_id, COUNT(*) AS n FROM chip_ledger WHERE reason = 'hand_win' AND game IS NULL GROUP BY hand_id HAVING COUNT(*) > 1`);
  assert.deepEqual(winners, [], 'a Teen Patti hand paid two winners');
});

test('action ids are unique, so a replayed checkpoint can never be applied twice', async () => {
  const dupes = await query('SELECT action_id, COUNT(*) AS n FROM chip_ledger WHERE action_id IS NOT NULL GROUP BY action_id HAVING COUNT(*) > 1');
  assert.deepEqual(dupes.rows, [], 'the UNIQUE index held');
  const bare = await query(`SELECT COUNT(*) AS n FROM chip_ledger WHERE reason IN ('hand_win','hand_loss','hand_packed','hand_left') AND action_id IS NULL`);
  assert.equal(bare.rows[0].n, 0, 'every checkpoint row carries its id');
});

test('PostgreSQL holds no game state at all: money, audit, accounts and table configuration only', async () => {
  // Owner's decision of 9 Sep 2026 (LIVE_STATE_PLAN.md): ALL game state lives
  // in the live store (Redis). game_states, pots and hands are gone; the boot
  // path in schema.sql drops each of them when it exists AND is empty, and
  // never creates them.
  //
  // profile_pictures and user_profile_pictures are account facts, the same
  // kind of thing `users` holds — a catalogue and who has paid for what. They
  // outlive every hand and no table ever reads them. diamond_purchases
  // (13 Sep 2026) is money: the record of a Play diamond pack and the guard
  // that stops its token crediting twice. hammer_purchases and hammer_spends
  // (13 Sep 2026) are the same for hammers: a Play hammer pack's replay
  // guard, and the one-row-per-key receipt a Force Sideshow's hammer is spent
  // against — nothing reads either back to play a hand. missile_purchases and
  // missile_spends (14 Sep 2026) are the missiles' twins: the record and
  // replay guard of a diamonds-for-missiles trade, and the receipt a fired
  // missile is spent against. user_milestones (14 Sep 2026) is an account fact
  // too: which rewards a player has collected, moved off users. table_pictures,
  // user_table_pictures and user_table_choice (15 Sep 2026) are the
  // table-picture catalogue, who has bought which, and which each player has
  // laid on their own table — a catalogue, receipts and a choice, the same
  // kind of thing as the profile pictures, and nothing a table reads to play a
  // hand. lucky_draws, lucky_draw_slots and user_lucky_draws (24 Sep 2026) are
  // the Lucky Draw: the draws and their prizes, configuration read on each
  // request, and every spin — an audit a spin writes once, in the same
  // transaction as its prize, and nothing a table reads. emojis and
  // user_emojis (26 Sep 2026) are the emoji catalogue and who has bought
  // which — a catalogue and receipts, the profile pictures' shape again; a
  // sent emoji is a chat line, and chat lives with the room in Redis. The list
  // is exact rather than a minimum, so a new table has to be argued for here
  // first.
  //
  // table_engines, table_categories, table_settings and table_configs (owner,
  // 23 Sep 2026: "all table related config store in database") are
  // CONFIGURATION: what a table IS, never what is happening at one. The engines
  // and categories are the taxonomy the lobby files tables under (Teen Patti:
  // seen, blind, variation; Poker: the four variants), the settings row the
  // figures no one table owns, and each table_configs row the rules one lobby
  // table or private template is opened with — boot, ladder, pot cap, clocks.
  // The seed and the owner write them; a server reads the active rows once, at
  // boot, and nothing a hand does writes a row. No row names a room, a seat, a
  // hand or a player, and a table restored from Redis never reads them (its
  // snapshot carries the rules it was opened with), so losing Redis still
  // loses the hands and nothing else — which is the rule this test guards.
  const { rows } = await query(
    `SELECT tablename FROM pg_tables WHERE schemaname = current_schema() ORDER BY tablename`);
  const tables = rows.map((r) => r.tablename);
  for (const retired of ['game_states', 'pots', 'hands']) {
    assert.ok(!tables.includes(retired), `${retired} is game state and must not exist`);
  }
  assert.deepEqual(tables, [
    'chip_ledger', 'diamond_purchases', 'emojis', 'hammer_purchases', 'hammer_spends', 'lucky_draw_slots', 'lucky_draws',
    'missile_purchases', 'missile_spends', 'profile_pictures', 'table_categories', 'table_configs', 'table_engines',
    'table_pictures', 'table_settings', 'user_emojis', 'user_lucky_draws', 'user_milestones', 'user_profile_pictures',
    'user_table_choice', 'user_table_pictures', 'users',
  ], `the schema must hold money, audit, accounts, the picture catalogues and table configuration only, got ${tables.join(', ')}`);
  // Configuration, by construction: no column of the four refers to a room, a
  // hand, a seat or a user.
  const { rows: stateful } = await query(
    `SELECT table_name, column_name FROM information_schema.columns
      WHERE table_schema = current_schema()
        AND table_name IN ('table_engines', 'table_categories', 'table_settings', 'table_configs')
        AND column_name ~ '^(room|hand|seat|user)_'`);
  assert.deepEqual(stateful, [], 'a table configuration column names a room, a hand, a seat or a user');
});

test('a bet is not a transaction: the books move only at a pack, a departure and the hand end', async () => {
  const { rows } = await query(
    `SELECT COUNT(*) AS n FROM chip_ledger WHERE reason IN ('boot', 'bet', 'show')`);
  assert.equal(Number(rows[0].n), 0, 'a retired per-bet reason was written');
});

test('the chip ledger is append-only', async () => {
  const { rows } = await query('SELECT id FROM chip_ledger LIMIT 1');
  if (rows.length === 0) return;
  await assert.rejects(query('UPDATE chip_ledger SET delta = delta WHERE id = $1', [rows[0].id]), /append-only/);
  await assert.rejects(query('DELETE FROM chip_ledger WHERE id = $1', [rows[0].id]), /append-only/);
});

test('counters: handsWon follows the hand_win rows, and the winnings counters agree with them', async () => {
  const { rows: users } = await query('SELECT id, hands_played, hands_won, hands_lost, hands_left_mid, total_winnings, biggest_pot FROM users');
  // There is no `hands` table to read a pot from any more, and a winner's own
  // stake is folded into their single hand_win row (delta = pot - own stake),
  // so the exact pot is not derivable from the ledger. What IS checkable:
  // handsWon is exactly the number of hand_win rows, and the winnings
  // counters are at least the net those rows paid (the pot is that net plus
  // whatever the winner had staked, which is never negative).
  const { rows: wins } = await query("SELECT user_id, delta FROM chip_ledger WHERE reason = 'hand_win'");
  const count = new Map();
  const net = new Map();
  const biggestNet = new Map();
  for (const win of wins) {
    count.set(win.user_id, (count.get(win.user_id) ?? 0) + 1);
    net.set(win.user_id, (net.get(win.user_id) ?? 0) + win.delta);
    biggestNet.set(win.user_id, Math.max(biggestNet.get(win.user_id) ?? 0, win.delta));
  }
  for (const user of users) {
    const n = count.get(user.id) ?? 0;
    assert.equal(user.hands_won, n, `handsWon for ${user.id}`);
    if (n === 0) {
      assert.equal(user.total_winnings, 0, `totalWinnings for ${user.id}`);
      assert.equal(user.biggest_pot, 0, `biggestPot for ${user.id}`);
      continue;
    }
    assert.ok(user.total_winnings >= net.get(user.id), `totalWinnings ${user.total_winnings} < net won ${net.get(user.id)}`);
    assert.ok(user.biggest_pot >= biggestNet.get(user.id), `biggestPot ${user.biggest_pot} < biggest net ${biggestNet.get(user.id)}`);
    assert.ok(user.biggest_pot <= user.total_winnings, 'the biggest pot cannot exceed the total');
  }
  // Nobody is credited a loss and a departure for the same hand.
  const { rows: both } = await query(
    `SELECT hand_id, user_id FROM chip_ledger WHERE reason IN ('hand_loss','hand_left')
      GROUP BY hand_id, user_id HAVING COUNT(*) > 1`);
  assert.deepEqual(both, [], 'a player was both lost and left in one hand');
});
