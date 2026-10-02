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
 *   - every hand's hand_* rows sum to zero: chips moved between wallets, none
 *     were created or destroyed. A table that taxes its winners (owner,
 *     26 Sep 2026) adds ONE more row to a hand it taxes — table_tax, the
 *     winner's, minus the tax — and that is the one way chips leave the
 *     economy at a hand;
 *   - every row carries a known reason, a server-minted action id of the
 *     right shape, and a balance that follows the running total;
 *   - a hand_win row pays the pot less the winner's own stake; a player is
 *     resolved exactly once (one outcome row per hand per player);
 *   - the counters (handsWon / totalWinnings / biggestPot) follow the
 *     hand_win rows;
 *   - the schema has no game state: no game_states, no pots, no hands (the
 *     table configuration and the player levels are configuration, and a
 *     player's XP an account fact, argued below);
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
//
// The lobby rewards' reasons — milestone_reward, timed_bonus, daily_bonus.
// Two are retired (owner, 30 Sep 2026: the milestone and the daily bonus were
// removed) and nothing writes them any more, but they stay in the vocabulary:
// an older database's history keeps its rows, and the ledger is append-only,
// so the audit must still read them as the chip sources they were.
// timed_bonus is written again: the bonus came back that evening, every 6
// hours (POST /api/rewards/bonus).
const RETIRED_REWARD_REASONS = ['milestone_reward', 'timed_bonus', 'daily_bonus'];
const REASONS = new Set([
  'welcome_bonus', 'hand_win', 'hand_loss', 'hand_packed', 'hand_left', ...RETIRED_REWARD_REASONS,
  'lucky_draw', 'picture_purchase', 'table_picture_purchase', 'emoji_purchase', 'test_fixture',
  // The winning tax a hand's winner pays at a table that taxes its winners
  // (owner, 26 Sep 2026): a chip sink, beside that hand's hand_win row.
  'table_tax',
  // A reward program's chips — a login streak's or a calendar's day (owner,
  // 30 Sep 2026): a chip source, like the Lucky Draw, under the claim's key
  // reward:<user>:<program>:<date>.
  'reward_program',
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
    if (['welcome_bonus', ...RETIRED_REWARD_REASONS, 'lucky_draw', 'reward_program'].includes(row.reason)) assert.ok(row.delta > 0);
    if (row.reason === 'reward_program') {
      assert.ok(row.action_id?.startsWith(`reward:${row.user_id}:`), 'a reward program row carries the claim\'s own key');
    }
    // The winning tax (owner, 26 Sep 2026): only ever takes chips, names its
    // hand, and carries the server's own id for it.
    if (row.reason === 'table_tax') {
      assert.ok(row.delta < 0, 'a winning tax only ever takes chips');
      assert.ok(row.hand_id, 'a winning tax names its hand');
      assert.equal(row.action_id, `${row.hand_id}:tax:${row.user_id}`, 'a winning tax carries the server-minted id');
      assert.equal(row.game, null, 'only a Teen Patti table taxes its winners');
    }
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
  //
  // The sum is over the hand_* rows: a hand at a table that taxes its winners
  // also carries the winner's table_tax row, the chips that left the game,
  // which is checked on its own below.
  const { rows: hands } = await query(
    `SELECT hand_id, SUM(delta) AS net, COUNT(*) AS rows FROM chip_ledger
      WHERE hand_id IS NOT NULL AND reason IN ('hand_win', 'hand_loss', 'hand_packed', 'hand_left')
        AND (variant IS NULL OR variant <> 'three_card_poker') GROUP BY hand_id`);
  for (const hand of hands) {
    assert.equal(Number(hand.net), 0, `hand ${hand.hand_id} moved ${hand.net} chips into or out of the economy`);
  }
  // Every row of a hand is a checkpoint row or its winner's tax.
  const { rows: stray } = await query(
    `SELECT hand_id, reason FROM chip_ledger
      WHERE hand_id IS NOT NULL AND reason NOT IN ('hand_win', 'hand_loss', 'hand_packed', 'hand_left', 'table_tax')`);
  assert.deepEqual(stray, [], 'a hand carries a row that is neither a checkpoint nor its winning tax');
  // A taxed hand: one table_tax row, the WINNER's — the player with that
  // hand's hand_win row — and no other player pays anything.
  const { rows: taxes } = await query(
    `SELECT t.hand_id, t.user_id, COUNT(*) OVER (PARTITION BY t.hand_id) AS per_hand,
            EXISTS (SELECT 1 FROM chip_ledger w WHERE w.hand_id = t.hand_id AND w.user_id = t.user_id
                     AND w.reason = 'hand_win') AS winner
       FROM chip_ledger t WHERE t.reason = 'table_tax'`);
  for (const tax of taxes) {
    assert.equal(Number(tax.per_hand), 1, `hand ${tax.hand_id} was taxed more than once`);
    assert.equal(tax.winner, true, `the tax of hand ${tax.hand_id} was paid by ${tax.user_id}, who did not win it`);
  }
  // One OUTCOME row per player per hand (hand_win / hand_loss / hand_left).
  // A packer also has a hand_packed row — that is the money moving early —
  // but never two outcomes. Nor is a leaver's CATCH-UP one (go-server
  // DECISIONS.md, "A checkpoint the ledger refuses"): a hand_loss under the
  // settle's id beside that player's own hand_left row of the same hand is
  // what the hand end wrote of the stake that leave did not bank — a leave
  // replayed after a restore that landed less than the restored stake — so
  // the pair is ONE resolution, and the check below holds the pair to moving
  // money.
  const { rows: dupes } = await query(
    `SELECT hand_id, user_id, COUNT(*) AS n FROM chip_ledger c
      WHERE reason IN ('hand_win', 'hand_loss', 'hand_left')
        AND NOT (reason = 'hand_loss' AND EXISTS (
              SELECT 1 FROM chip_ledger l
               WHERE l.hand_id = c.hand_id AND l.user_id = c.user_id AND l.reason = 'hand_left'))
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
  // too: which rewards a player collected, moved off users — history since the
  // lobby rewards were removed (30 Sep 2026), written by nothing. table_pictures,
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
  // sent emoji is a chat line, and chat lives with the room in Redis.
  // player_stats, friend_requests and friendships (Friends V1, 26 Sep 2026)
  // are account facts: the career counters (a row per bucket since Player
  // stats v2, 27 Sep 2026, beside player_variation_stats per variation), and
  // who asked whom and who is friends with whom — whether a friend is online
  // or at a table is Redis's (kt:online, kt:playing:<userId>) and no row here
  // names a room. The counters are added AFTER a hand, by the stats flusher's
  // group commit from Redis; stats_flushes is its receipts, one row per batch
  // committed.
  // player_reports (Report Player, 27 Sep 2026) is moderation audit: a row a
  // player's report writes once, naming the room and the hand it is about by
  // id — references, never their state — and nothing a table reads.
  // user_sessions (28 Sep 2026) is an account fact: how many times each
  // account has signed in, the figure its current token carries — one
  // signed-in device per account. A login writes it, nothing a table reads.
  // player_levels, badges, xp_sources and xp_settings (26–27 Sep 2026) are
  // configuration: the level ladder — each level's title, icon and the winning
  // tax it carries —, the badges a player may hold beside it with their rates
  // and validity, the daily XP sources and the window; the seed and the owner
  // write them. player_xp, player_xp_claims and user_badges are account facts,
  // the kind of thing users holds: a player's lifetime XP and their day's
  // window, how many times they have earned each source in it, and the badges
  // they were given and when each runs out — XP written by the hand-end settle
  // in the ledger's own transaction and by the play-time award, badges by
  // hand or by a store purchase, whose receipt badge_purchases keeps (a Play
  // purchase record, as diamond_purchases is). No table reads any of them to play a hand — a seat takes its rate
  // with the account when its player sits down, and from each hand-end
  // settle's answer — and the play TIME that earns XP is kept in the live
  // store, never here. player_xp_missions (28 Sep 2026) is an account fact
  // too: each player's progress on the one-time missions and when each was
  // completed, moved on by the same hand-end settle's transaction after a hand
  // has ENDED — never a hand in play. The list is exact rather than a minimum,
  // so a new table has to be argued for here first.
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
  // app_versions (28 Sep 2026) is the app version gate's configuration: a row
  // per app platform — open or in maintenance, its minimum and latest
  // versions, its store link — read by the REST and handshake gate through a
  // short cache, never by a table. welcome_rewards (30 Sep 2026) is what a new
  // account is given — chips, diamonds, hammers, missiles, a picture, a table
  // picture, an emoji — configuration the login that creates an account reads,
  // never a table. reward_programs and reward_program_rewards (30 Sep 2026)
  // are the login streaks' and calendar rewards' configuration, and
  // user_reward_claims every day of them granted — an audit, as the Lucky
  // Draw's spins are — and user_reward_progress (1 Oct 2026) where each
  // player stands in a program's period.
  assert.deepEqual(tables, [
    'app_versions', 'badge_purchases', 'badges', 'chip_ledger', 'diamond_purchases', 'emojis', 'friend_requests', 'friendships',
    'hammer_purchases', 'hammer_spends', 'lucky_draw_slots', 'lucky_draws', 'missile_purchases', 'missile_spends',
    'player_levels', 'player_reports', 'player_stats', 'player_variation_stats', 'player_xp', 'player_xp_claims', 'player_xp_missions', 'profile_pictures',
    'reward_program_rewards', 'reward_programs',
    'stats_flushes', 'table_categories', 'table_configs', 'table_engines', 'table_pictures', 'table_settings',
    'user_badges', 'user_emojis', 'user_lucky_draws', 'user_milestones', 'user_profile_pictures', 'user_reward_claims', 'user_reward_progress', 'user_sessions', 'user_table_choice',
    'user_table_pictures', 'users', 'welcome_rewards', 'xp_settings', 'xp_sources',
  ], `the schema must hold money, audit, accounts, the picture catalogues and table configuration only, got ${tables.join(', ')}`);
  // Configuration, by construction: no column of the four — nor of the level
  // ladder, the badges and the XP rules — refers to a room, a hand, a seat or a
  // user.
  const { rows: stateful } = await query(
    `SELECT table_name, column_name FROM information_schema.columns
      WHERE table_schema = current_schema()
        AND table_name IN ('table_engines', 'table_categories', 'table_settings', 'table_configs',
                           'player_levels', 'badges', 'xp_sources', 'xp_settings', 'app_versions', 'welcome_rewards')
        AND column_name ~ '^(room|hand|seat|user)_'
        -- the kind of hand a daily XP source is won with (PAIR … TRAIL): a
        -- rule, never a hand
        AND NOT (table_name = 'xp_sources' AND column_name = 'hand_rank')`);
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

// retryUntil re-runs an audit until it passes or `timeoutMs` elapses; the last
// failure is the one reported.
const retryUntil = async (audit, timeoutMs, intervalMs = 250) => {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      return await audit();
    } catch (error) {
      if (Date.now() >= deadline) throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
};

test('counters: handsWon follows the hand_win rows, and the winnings counters agree with them', async () => {
  // The counters live in player_stats, a row per player per bucket (Player
  // stats v2, 27 Sep 2026): the career is their sum, the biggest pot the
  // largest. They reach PostgreSQL by the stats flusher's group commit, one
  // STATS_FLUSH_MS after the hand (250 ms in the harness; 10 s on a server
  // attached with --url), so the audit waits for the last hands to land.
  await retryUntil(auditCounters, 20000);
});

const auditCounters = async () => {
  const { rows: users } = await query(
    `SELECT u.id, COALESCE(SUM(s.hands_played), 0) AS hands_played, COALESCE(SUM(s.hands_won), 0) AS hands_won,
            COALESCE(SUM(s.hands_lost), 0) AS hands_lost, COALESCE(SUM(s.hands_left), 0) AS hands_left,
            COALESCE(SUM(s.total_winnings), 0) AS total_winnings, COALESCE(MAX(s.biggest_pot), 0) AS biggest_pot,
            COALESCE(SUM(s.total_tax_paid), 0) AS total_tax_paid
       FROM users u LEFT JOIN player_stats s ON s.user_id = u.id
      GROUP BY u.id`);
  // The winning tax a player has paid (2 Oct 2026; player_stats.total_tax_paid)
  // is counted from the same settle that wrote their table_tax rows, and those
  // rows are never purged: the two agree exactly, player by player.
  const { rows: taxes } = await query(
    "SELECT user_id, -SUM(delta) AS paid FROM chip_ledger WHERE reason = 'table_tax' GROUP BY user_id");
  const taxPaid = new Map(taxes.map((tax) => [tax.user_id, Number(tax.paid)]));
  for (const user of users) {
    assert.equal(Number(user.total_tax_paid), taxPaid.get(user.id) ?? 0, `totalTaxPaid for ${user.id}`);
    assert.ok(Number(user.total_tax_paid) <= Number(user.total_winnings), 'nobody pays more tax than they won');
  }
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
  // Nobody is credited a loss and a departure for the same hand. A hand_loss
  // beside a hand_left of the same player and hand is that leave's catch-up
  // (the check above): money the leave did not bank, never a second outcome
  // — so it always moves chips. A zero-delta hand_loss there would be a leaver
  // the hand end resolved again. (The one exception is a fault neither this
  // harness nor crashtest.mjs can cause: a poker leave with nothing staked
  // whose commit's acknowledgement the database lost.)
  const { rows: both } = await query(
    `SELECT c.hand_id, c.user_id FROM chip_ledger c
      WHERE c.reason = 'hand_loss' AND c.delta = 0 AND EXISTS (
            SELECT 1 FROM chip_ledger l
             WHERE l.hand_id = c.hand_id AND l.user_id = c.user_id AND l.reason = 'hand_left')`);
  assert.deepEqual(both, [], 'a player was both lost and left in one hand');
};

test('statistics: the buckets are the three, the hands held add up, and every flush receipt names its players', async () => {
  await retryUntil(async () => {
    const { rows: buckets } = await query(`SELECT DISTINCT category FROM player_stats ORDER BY category`);
    for (const { category } of buckets) {
      assert.ok(['POKER', 'TEEN_PATTI', 'VARIATION'].includes(category), `bucket ${category}`);
    }
    // The hand held is counted for every hand a Teen Patti or Variation
    // hand end resolved — never more than the hands finished (won + lost),
    // and never at poker.
    const { rows } = await query(
      `SELECT user_id, category, hands_won + hands_lost AS finished,
              trail + pure_sequence + sequence + color + pair + high_card AS held
         FROM player_stats`);
    for (const row of rows) {
      if (row.category === 'POKER') assert.equal(row.held, 0, `a poker row counts hands held (${row.user_id})`);
      else assert.ok(row.held <= row.finished, `${row.user_id} ${row.category}: ${row.held} hands held of ${row.finished} finished`);
    }
    const { rows: tallies } = await query(
      `SELECT v.user_id, SUM(v.hands_played) AS played, COALESCE(MAX(s.hands_won + s.hands_lost + s.hands_left), 0) AS finished
         FROM player_variation_stats v LEFT JOIN player_stats s ON s.user_id = v.user_id AND s.category = 'VARIATION'
        GROUP BY v.user_id`);
    for (const t of tallies) {
      // Every hand tallied under a variation was a Variation hand the player
      // finished (won, lost, or left as its winner).
      assert.ok(t.played <= t.finished, `${t.user_id}: ${t.played} variation hands of ${t.finished} finished`);
    }
    const { rows: receipts } = await query('SELECT batch_id, players FROM stats_flushes');
    for (const r of receipts) assert.ok(r.players >= 1, `receipt ${r.batch_id} names ${r.players} players`);
  }, 20000);
});
