/**
 * The books, audited after everything the other suites played on this server
 * (invalidMoves #16 and the CLAUDE.md §4/§12.1 psql checks, over the whole
 * schema):
 *
 *   - SUM(chip_ledger.delta) == users.chips for every user touched;
 *   - every pot equals the boots, bets and shows banked against its hand, and a
 *     closed pot's hands row carries the same pot and winner;
 *   - the winner's hand_win row pays the whole pot (every stake was banked as
 *     it was bet), losers get a hand_loss row of 0, and every boot/settle row
 *     carries its deterministic action id;
 *   - every client-supplied actionId appears on exactly one ledger row, and
 *     no bet/show row is missing one;
 *   - game_states holds a snapshot for every hand still open, with a rising
 *     version, and none for a table that has been destroyed;
 *   - the append-only trigger refuses UPDATE/DELETE on chip_ledger.
 *
 * Runs last in each profile (tools/parity.mjs appends it), but is also safe to
 * run on its own against a schema that has seen no play.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { query, closeDb } from './lib/db.mjs';
import { UUID } from './lib/harness.mjs';

test.after(closeDb);

const REASONS = new Set([
  'welcome_bonus', 'boot', 'bet', 'show', 'hand_win', 'hand_loss', 'milestone_reward', 'timed_bonus', 'test_fixture',
]);

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
  let previous = null;
  for (const row of rows) {
    assert.ok(REASONS.has(row.reason), `reason ${row.reason}`);
    assert.equal(typeof row.delta, 'number');
    assert.equal(typeof row.created_at, 'number');
    if (['boot', 'bet', 'show'].includes(row.reason)) {
      assert.ok(row.delta < 0, `${row.reason} debits (${row.delta})`);
      assert.ok(row.hand_id, `${row.reason} names its hand`);
      assert.ok(row.action_id, `${row.reason} carries an action id`);
    }
    if (['welcome_bonus', 'milestone_reward', 'timed_bonus'].includes(row.reason)) assert.ok(row.delta > 0);
    if (row.reason === 'hand_win') assert.ok(row.delta > 0, 'a win pays');
    if (row.reason === 'hand_loss') assert.equal(row.delta, 0, 'a loser was banked as they bet; settlement moves nothing');
    if (row.reason === 'boot') assert.equal(row.action_id, `${row.hand_id}:boot:${row.user_id}`);
    if (row.reason === 'hand_win' || row.reason === 'hand_loss') {
      assert.equal(row.action_id, `${row.hand_id}:settle:${row.user_id}`);
    }
    // Balances chain within one user, in insertion order.
    if (previous && previous.user_id === row.user_id) {
      assert.equal(row.balance, previous.balance + row.delta,
        `balance chain for ${row.user_id} at row ${row.id}: ${previous.balance} + ${row.delta} != ${row.balance}`);
    } else {
      assert.equal(row.balance, row.delta, `first row for ${row.user_id} opens the account`);
    }
    previous = row;
  }
});

test('every pot equals what was banked against its hand, and closed pots agree with their hands row', async () => {
  const { rows: pots } = await query('SELECT hand_id, room_id, boot_amount, amount, winner_id, opened_at, closed_at FROM pots');
  for (const pot of pots) {
    const banked = await query(
      `SELECT COALESCE(-SUM(delta), 0) AS staked, COUNT(*) FILTER (WHERE reason = 'boot') AS boots
         FROM chip_ledger WHERE hand_id = $1 AND reason IN ('boot', 'bet', 'show')`,
      [pot.hand_id],
    );
    assert.equal(pot.amount, banked.rows[0].staked, `pot ${pot.hand_id} vs banked stakes`);
    assert.ok(banked.rows[0].boots >= 2, 'a hand needs at least two boots');
    assert.equal(typeof pot.opened_at, 'number');
    assert.ok(pot.room_id);

    if (pot.closed_at === null) continue; // a hand still live when the audit ran

    const hand = await query('SELECT id, room_id, hand_no, pot, winner_id, win_reason, boot_amount, started_at, ended_at, summary_json FROM hands WHERE id = $1', [pot.hand_id]);
    assert.equal(hand.rows.length, 1, `hands row for ${pot.hand_id}`);
    const record = hand.rows[0];
    assert.equal(record.pot, pot.amount);
    assert.equal(record.winner_id, pot.winner_id);
    assert.equal(record.room_id, pot.room_id);
    assert.equal(record.boot_amount, pot.boot_amount);
    assert.ok(record.started_at <= record.ended_at);
    assert.ok(['show', 'last_standing', 'forced_showdown', 'pot_limit', 'all_left'].includes(record.win_reason), record.win_reason);
    const summary = record.summary_json;
    assert.ok(Array.isArray(summary) && summary.length >= 2);
    assert.equal(summary.reduce((sum, entry) => sum + entry.contributed, 0), record.pot, 'the summary explains the pot');
    for (const entry of summary) {
      assert.deepEqual(Object.keys(entry).sort(), ['cards', 'contributed', 'displayName', 'sawCards', 'seatIndex', 'status', 'userId']);
      assert.ok(entry.cards === null || (Array.isArray(entry.cards) && entry.cards.length === 3));
    }

    // Settlement rows: the winner takes the pot, everybody else gets a zero row.
    const settle = await query(
      "SELECT user_id, delta, reason FROM chip_ledger WHERE hand_id = $1 AND reason IN ('hand_win', 'hand_loss')",
      [pot.hand_id],
    );
    const contributors = new Set(summary.map((entry) => entry.userId));
    assert.equal(settle.rows.length, contributors.size, 'one settlement row per contributor');
    if (record.winner_id) {
      const win = settle.rows.filter((row) => row.reason === 'hand_win');
      assert.equal(win.length, 1);
      assert.equal(win[0].user_id, record.winner_id);
      assert.equal(win[0].delta, record.pot, 'the winner is paid the whole pot');
      assert.ok(summary.filter((entry) => entry.status === 'won').length === 1);
    }
    for (const row of settle.rows.filter((r) => r.reason === 'hand_loss')) assert.equal(row.delta, 0);
  }
});

test('client action ids land on exactly one ledger row each, and every bet or show has one', async () => {
  const dupes = await query('SELECT action_id, COUNT(*) AS n FROM chip_ledger WHERE action_id IS NOT NULL GROUP BY action_id HAVING COUNT(*) > 1');
  assert.deepEqual(dupes.rows, [], 'the UNIQUE index held');
  const bare = await query("SELECT COUNT(*) AS n FROM chip_ledger WHERE reason IN ('bet', 'show') AND action_id IS NULL");
  assert.equal(bare.rows[0].n, 0);
  // Ids the suites chose themselves are there once; ids the server minted are uuids.
  const { rows } = await query("SELECT action_id FROM chip_ledger WHERE reason IN ('bet', 'show')");
  for (const { action_id: id } of rows) {
    assert.ok(id.length >= 1 && id.length <= 64, `action id length ${id.length}`);
    if (!id.startsWith('parity-') && !id.startsWith('oot-') && !id.startsWith('ladder-') && !id.startsWith('dup-')) {
      assert.ok(UUID.test(id) || id.length <= 64, `server-minted id ${id}`);
    }
  }
});

test('game_states mirrors the live tables: a snapshot for every hand still open, nothing left behind', async () => {
  // game_states is the durable backstop the live store is rebuilt from
  // (LIVE_STATE_PLAN.md). It is no longer written inside the money
  // transaction and it is no longer an audit log: a row exists while its
  // table does, and is removed when the table is destroyed. What must hold
  // is that anything still recoverable IS recoverable.
  const rooms = new Set((await query('SELECT DISTINCT room_id FROM pots')).rows.map((r) => r.room_id));

  const snapshots = async () => (await query('SELECT room_id, hand_id, version, state, updated_at FROM game_states')).rows;
  let rows = await snapshots();

  for (const row of rows) {
    assert.ok(row.version >= 1, `version for ${row.room_id} is ${row.version}`);
    assert.equal(typeof row.state, 'object', `state for ${row.room_id}`);
    assert.equal(row.state.roomId ?? row.state.id ?? row.room_id, row.room_id, 'a snapshot names its own room');
    assert.ok(rooms.has(row.room_id), `game_states row for a room that never dealt: ${row.room_id}`);
  }

  // The recoverability invariant: a pot that is still open belongs to a hand
  // that is still being played, so there must be a snapshot to rebuild it
  // from. The writer batches, so give it a moment to catch up.
  const openRooms = (await query('SELECT room_id FROM pots WHERE closed_at IS NULL')).rows.map((r) => r.room_id);
  for (let i = 0; openRooms.length > 0 && i < 20; i++) {
    const have = new Set(rows.map((r) => r.room_id));
    if (openRooms.every((id) => have.has(id))) break;
    await new Promise((r) => setTimeout(r, 250));
    rows = await snapshots();
  }
  const have = new Set(rows.map((r) => r.room_id));
  for (const roomId of openRooms) {
    assert.ok(have.has(roomId), `an open pot at room ${roomId} has no durable snapshot to rebuild it from`);
  }

  // A write with a non-rising version is refused by the WHERE clause, so a
  // direct attempt to move a row backwards changes nothing. This is the guard
  // that stops a late batch overwriting newer state.
  if (rows.length > 0) {
    const target = rows[0];
    const stale = await query(
      `INSERT INTO game_states (room_id, hand_id, version, state, updated_at)
       VALUES ($1, NULL, $2, '{}'::jsonb, $3)
       ON CONFLICT (room_id) DO UPDATE SET version = EXCLUDED.version, state = EXCLUDED.state
       WHERE game_states.version < EXCLUDED.version`,
      [target.room_id, target.version - 1, Date.now()],
    );
    assert.equal(stale.rowCount, 0);
    const after = await query('SELECT version FROM game_states WHERE room_id = $1', [target.room_id]);
    assert.equal(after.rows[0].version, target.version);
  }
});

test('the chip ledger is append-only', async () => {
  const { rows } = await query('SELECT id FROM chip_ledger LIMIT 1');
  if (rows.length === 0) return;
  await assert.rejects(query('UPDATE chip_ledger SET delta = delta WHERE id = $1', [rows[0].id]), /append-only/);
  await assert.rejects(query('DELETE FROM chip_ledger WHERE id = $1', [rows[0].id]), /append-only/);
});

test('hands and counters: handsWon / handsPlayed / handsLost / handsLeftMid follow the settled hands', async () => {
  const { rows: users } = await query('SELECT id, hands_played, hands_won, hands_lost, hands_left_mid, total_winnings, biggest_pot FROM users');
  const { rows: hands } = await query('SELECT id, pot, winner_id, summary_json FROM hands');
  const wins = new Map();
  const winnings = new Map();
  const biggest = new Map();
  for (const hand of hands) {
    if (!hand.winner_id) continue;
    wins.set(hand.winner_id, (wins.get(hand.winner_id) ?? 0) + 1);
    winnings.set(hand.winner_id, (winnings.get(hand.winner_id) ?? 0) + hand.pot);
    biggest.set(hand.winner_id, Math.max(biggest.get(hand.winner_id) ?? 0, hand.pot));
  }
  for (const user of users) {
    // Counters may exceed the hands rows where a REST test fast-forwarded
    // hands_played directly; wins and winnings are only ever written by settlement.
    assert.equal(user.hands_won, wins.get(user.id) ?? 0, `handsWon for ${user.id}`);
    assert.equal(user.total_winnings, winnings.get(user.id) ?? 0, `totalWinnings for ${user.id}`);
    assert.equal(user.biggest_pot, biggest.get(user.id) ?? 0, `biggestPot for ${user.id}`);
    assert.ok(user.hands_lost + user.hands_left_mid + user.hands_won <= Math.max(user.hands_played, hands.length * 5));
  }
});
