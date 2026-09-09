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
 *   - the schema has no game state: no game_states, no pots, no hands;
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
  'welcome_bonus', 'hand_win', 'hand_loss', 'hand_packed', 'hand_left', 'milestone_reward', 'timed_bonus', 'test_fixture',
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
  const { rows } = await query('SELECT id, user_id, hand_id, action_id, delta, balance, reason, created_at FROM chip_ledger ORDER BY user_id, id');
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
    if (['welcome_bonus', 'milestone_reward', 'timed_bonus'].includes(row.reason)) assert.ok(row.delta > 0);
    if (row.reason === 'hand_win') assert.ok(row.delta > 0, 'a win pays');
    if (row.reason === 'hand_packed') assert.ok(row.delta <= 0, 'a pack only ever takes chips');
  }
});

test('every hand conserves chips, and resolves each player exactly once', async () => {
  const { rows: hands } = await query(
    `SELECT hand_id, SUM(delta) AS net, COUNT(*) AS rows FROM chip_ledger
      WHERE hand_id IS NOT NULL GROUP BY hand_id`);
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
  // A hand has at most one winner.
  const { rows: winners } = await query(
    `SELECT hand_id, COUNT(*) AS n FROM chip_ledger WHERE reason = 'hand_win' GROUP BY hand_id HAVING COUNT(*) > 1`);
  assert.deepEqual(winners, [], 'a hand paid two winners');
});

test('action ids are unique, so a replayed checkpoint can never be applied twice', async () => {
  const dupes = await query('SELECT action_id, COUNT(*) AS n FROM chip_ledger WHERE action_id IS NOT NULL GROUP BY action_id HAVING COUNT(*) > 1');
  assert.deepEqual(dupes.rows, [], 'the UNIQUE index held');
  const bare = await query(`SELECT COUNT(*) AS n FROM chip_ledger WHERE reason IN ('hand_win','hand_loss','hand_packed','hand_left') AND action_id IS NULL`);
  assert.equal(bare.rows[0].n, 0, 'every checkpoint row carries its id');
});

test('PostgreSQL holds no game state at all: only users and chip_ledger', async () => {
  // Owner's decision of 9 Sep 2026 (LIVE_STATE_PLAN.md): ALL game state lives
  // in the live store (Redis). game_states, pots and hands are gone; the boot
  // path in schema.sql drops each of them when it exists AND is empty, and
  // never creates them.
  const { rows } = await query(
    `SELECT tablename FROM pg_tables WHERE schemaname = current_schema() ORDER BY tablename`);
  const tables = rows.map((r) => r.tablename);
  assert.deepEqual(tables, ['chip_ledger', 'users'],
    `the schema must hold money and audit only, got ${tables.join(', ')}`);
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
