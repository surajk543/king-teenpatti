/**
 * Player statistics (requirement 16) and the two rewards (17, 18).
 *
 * "Played" deliberately means the player committed chips beyond the boot, so a
 * seat that antes and folds immediately does not inflate the counter that the
 * milestone reward is paid against.
 */
import test from 'node:test';
import assert from 'node:assert/strict';

// The config module snapshots the environment at import time, so the schema
// this suite writes to has to be named before anything under src/ is loaded.
// It is a throwaway Postgres schema of the suite's own, dropped in test.after.
process.env.NODE_ENV = 'test';
process.env.PG_SCHEMA = `test_stats_${Math.random().toString(36).slice(2, 8)}`;
process.env.JWT_SECRET = 'stats-test-secret';

const users = await import('../src/db/users.js');
const { openDatabase, dropSchema, closeDatabase, query } = await import('../src/db/index.js');

await openDatabase();

test.after(async () => {
  await dropSchema();
  await closeDatabase();
});

let seq = 0;
const makeUser = async (name = 'Player') => {
  seq += 1;
  const { user } = await users.upsertFromProfile({
    provider: 'guest',
    providerUserId: `stats-${seq}-${Math.random().toString(36).slice(2)}`,
    displayName: name,
  });
  return user;
};

/** Settles one synthetic hand so the counters move. */
const settle = (entries, pot) =>
  users.settleHand({
    hand: {
      id: `hand-${seq}-${Math.random().toString(36).slice(2)}`,
      roomId: 'room-stats',
      handNo: 1,
      pot,
      winnerId: entries.find((entry) => entry.isWinner)?.userId ?? null,
      winReason: 'show',
      bootAmount: 200,
      startedAt: Date.now() - 1000,
      endedAt: Date.now(),
      summary: [],
    },
    entries,
  });

/**
 * Reaches past the API to put a career's worth of hands on the counter, so the
 * milestone tests do not have to settle 25 hands apiece.
 */
const setHandsPlayed = (userId, handsPlayed) =>
  query('UPDATE users SET hands_played = $1 WHERE id = $2', [handsPlayed, userId]);

// -------------------------------------------------------------- statistics

test('a hand only counts as played once the player bets beyond the boot', async () => {
  const better = await makeUser('Better');
  const folder = await makeUser('Folder');

  await settle(
    [
      { userId: better.id, delta: 400, isWinner: true, didChaal: true, leftMidHand: false },
      // Posted the boot, then packed without ever betting.
      { userId: folder.id, delta: -200, isWinner: false, didChaal: false, leftMidHand: false },
    ],
    600,
  );

  assert.equal((await users.findById(better.id)).handsPlayed, 1, 'the player who bet has played a hand');
  assert.equal((await users.findById(folder.id)).handsPlayed, 0, 'posting the boot alone is not playing');
});

test('wins, losses and abandoned hands are counted separately', async () => {
  const winner = await makeUser('W');
  const loser = await makeUser('L');
  const quitter = await makeUser('Q');

  await settle(
    [
      { userId: winner.id, delta: 800, isWinner: true, didChaal: true, leftMidHand: false },
      { userId: loser.id, delta: -400, isWinner: false, didChaal: true, leftMidHand: false },
      { userId: quitter.id, delta: -400, isWinner: false, didChaal: true, leftMidHand: true },
    ],
    1600,
  );

  const w = await users.findById(winner.id);
  const l = await users.findById(loser.id);
  const q = await users.findById(quitter.id);

  assert.equal(w.handsWon, 1);
  assert.equal(w.handsLost, 0);
  assert.equal(w.handsLeftMid, 0);

  assert.equal(l.handsWon, 0);
  assert.equal(l.handsLost, 1);
  assert.equal(l.handsLeftMid, 0);

  assert.equal(q.handsLeftMid, 1, 'leaving mid-hand is tracked on its own');
  assert.equal(q.handsLost, 0, 'and is not also counted as a loss');
  assert.equal(q.handsPlayed, 1, 'they had bet, so the hand still counts as played');
});

test('total winnings accumulate the pots taken', async () => {
  const player = await makeUser('Rich');

  await settle([{ userId: player.id, delta: 500, isWinner: true, didChaal: true, leftMidHand: false }], 1000);
  await settle([{ userId: player.id, delta: 900, isWinner: true, didChaal: true, leftMidHand: false }], 2500);

  const row = await users.findById(player.id);
  assert.equal(row.totalWinnings, 3500, 'the two pots are summed');
  assert.equal(row.biggestPot, 2500);
  assert.equal(row.handsWon, 2);
});

// ------------------------------------------------- milestone reward (req 17)

test('the milestone reward unlocks every 25 played hands', async () => {
  const player = await makeUser('Grinder');

  const fresh = await users.findById(player.id);
  assert.equal(fresh.rewards.milestoneAvailable, false, 'nothing at zero hands');
  assert.equal(fresh.rewards.handsToNextMilestone, 25);

  await setHandsPlayed(player.id, 24);
  const nearly = await users.findById(player.id);
  assert.equal(nearly.rewards.milestoneAvailable, false, 'not yet at 24');
  assert.equal(nearly.rewards.handsToNextMilestone, 1);

  await setHandsPlayed(player.id, 25);
  const ready = await users.findById(player.id);
  assert.equal(ready.rewards.milestoneAvailable, true, 'available at 25');
  assert.equal(ready.rewards.milestoneAt, 25);
  assert.equal(ready.rewards.milestoneReward, 25000);
});

test('collecting the milestone reward grants 25,000 chips exactly once', async () => {
  const player = await makeUser('Collector');
  await setHandsPlayed(player.id, 50);

  const before = (await users.findById(player.id)).chips;
  const first = await users.claimMilestoneReward(player.id);

  assert.equal(first.claimed, true);
  assert.equal(first.amount, 25000);
  assert.equal(first.milestone, 50);
  assert.equal(first.user.chips, before + 25000);
  assert.equal(first.user.rewards.milestoneAvailable, false, 'the same milestone is now spent');

  const second = await users.claimMilestoneReward(player.id);
  assert.equal(second.claimed, false, 'a second claim pays nothing');
  assert.equal(second.reason, 'not_available');
  assert.equal((await users.findById(player.id)).chips, before + 25000, 'and moves no chips');
});

test('reaching the next milestone unlocks the reward again', async () => {
  const player = await makeUser('Repeater');

  await setHandsPlayed(player.id, 25);
  assert.equal((await users.claimMilestoneReward(player.id)).claimed, true);

  await setHandsPlayed(player.id, 49);
  assert.equal(
    (await users.findById(player.id)).rewards.milestoneAvailable,
    false,
    'still on the 25 milestone',
  );

  await setHandsPlayed(player.id, 50);
  assert.equal((await users.findById(player.id)).rewards.milestoneAvailable, true, '50 is a new milestone');
  assert.equal((await users.claimMilestoneReward(player.id)).claimed, true);
});

test('the milestone reward is written to the chip ledger', async () => {
  const player = await makeUser('Audited');
  await setHandsPlayed(player.id, 25);
  await users.claimMilestoneReward(player.id);

  const { rows } = await query(
    "SELECT * FROM chip_ledger WHERE user_id = $1 AND reason = 'milestone_reward'",
    [player.id],
  );
  const [row] = rows;

  assert.ok(row, 'the grant is auditable');
  assert.equal(row.delta, 25000);
});

// ----------------------------------------------------- timed bonus (req 18)

test('a new account can collect the timed bonus straight away', async () => {
  const player = await makeUser('Fresh');
  const { rewards } = await users.findById(player.id);

  assert.equal(rewards.bonusAvailable, true, 'no waiting on a brand new account');
  assert.equal(rewards.bonusReward, 10000);
  assert.equal(rewards.bonusIntervalMs, 4 * 60 * 60 * 1000, 'the countdown is 4 hours');
});

test('collecting the bonus grants 10,000 chips and starts a 4-hour countdown', async () => {
  const player = await makeUser('Bonus');
  const before = (await users.findById(player.id)).chips;

  const claimedAt = Date.now();
  const result = await users.claimTimedBonus(player.id);

  assert.equal(result.claimed, true);
  assert.equal(result.amount, 10000);
  assert.equal(result.user.chips, before + 10000);

  const fourHours = 4 * 60 * 60 * 1000;
  assert.ok(result.readyAt >= claimedAt + fourHours - 1000, 'the next one is ~4 hours out');
  assert.ok(result.readyAt <= Date.now() + fourHours + 1000);
  assert.equal(result.user.rewards.bonusAvailable, false, 'and is not collectable now');
});

test('the bonus cannot be collected twice inside the countdown', async () => {
  const player = await makeUser('Greedy');
  await users.claimTimedBonus(player.id);

  const before = (await users.findById(player.id)).chips;
  const second = await users.claimTimedBonus(player.id);

  assert.equal(second.claimed, false);
  assert.equal(second.reason, 'not_ready');
  assert.ok(second.readyAt > Date.now());
  assert.equal((await users.findById(player.id)).chips, before, 'no chips moved');
});

test('the countdown lives in the database, so it survives a restart', async () => {
  const player = await makeUser('Persistent');
  const result = await users.claimTimedBonus(player.id);

  const { rows } = await query('SELECT next_bonus_at FROM users WHERE id = $1', [player.id]);
  assert.equal(rows[0].next_bonus_at, result.readyAt, 'the unlock time is persisted, not held in memory');

  // Once the stored time passes, it is collectable again.
  await query('UPDATE users SET next_bonus_at = $1 WHERE id = $2', [Date.now() - 1, player.id]);
  assert.equal((await users.findById(player.id)).rewards.bonusAvailable, true);
  assert.equal((await users.claimTimedBonus(player.id)).claimed, true);
});

// ------------------------------------------------------ avatars (req 20/21)

test('a provider picture is kept and used by default', async () => {
  const { user } = await users.upsertFromProfile({
    provider: 'google',
    providerUserId: `g-${Math.random().toString(36).slice(2)}`,
    displayName: 'G Player',
    avatarUrl: 'https://lh3.googleusercontent.com/example',
  });

  assert.equal(user.avatarUrl, 'https://lh3.googleusercontent.com/example');
  assert.equal(user.providerAvatarUrl, 'https://lh3.googleusercontent.com/example');
  assert.equal(user.avatarChoice, null);
});

test('a chosen picture overrides the provider one, and clearing restores it', async () => {
  const { user } = await users.upsertFromProfile({
    provider: 'facebook',
    providerUserId: `f-${Math.random().toString(36).slice(2)}`,
    displayName: 'F Player',
    avatarUrl: 'https://graph.facebook.com/example',
  });

  const chosen = await users.setAvatarChoice(user.id, '/profiles/ace.svg');
  assert.equal(chosen.avatarUrl, '/profiles/ace.svg', 'the choice wins');
  assert.equal(chosen.providerAvatarUrl, 'https://graph.facebook.com/example', 'the original is kept');

  const cleared = await users.setAvatarChoice(user.id, null);
  assert.equal(cleared.avatarUrl, 'https://graph.facebook.com/example', 'clearing falls back');
});
