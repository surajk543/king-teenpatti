/**
 * Player statistics (requirement 16) and the two rewards (17, 18).
 *
 * "Played" deliberately means the player committed chips beyond the boot, so a
 * seat that antes and folds immediately does not inflate the counter that the
 * milestone reward is paid against.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const dbFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'teenpatti-stats-')), 'stats.db');
process.env.NODE_ENV = 'test';
process.env.DB_FILE = dbFile;
process.env.JWT_SECRET = 'stats-test-secret';

const users = await import('../src/db/users.js');
const { openDatabase, closeDatabase, getDatabase } = await import('../src/db/index.js');

openDatabase();

test.after(() => {
  closeDatabase();
  fs.rmSync(path.dirname(dbFile), { recursive: true, force: true });
});

let seq = 0;
const makeUser = (name = 'Player') => {
  seq += 1;
  return users.upsertFromProfile({
    provider: 'guest',
    providerUserId: `stats-${seq}-${Math.random().toString(36).slice(2)}`,
    displayName: name,
  }).user;
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

// -------------------------------------------------------------- statistics

test('a hand only counts as played once the player bets beyond the boot', () => {
  const better = makeUser('Better');
  const folder = makeUser('Folder');

  settle(
    [
      { userId: better.id, delta: 400, isWinner: true, didChaal: true, leftMidHand: false },
      // Posted the boot, then packed without ever betting.
      { userId: folder.id, delta: -200, isWinner: false, didChaal: false, leftMidHand: false },
    ],
    600,
  );

  assert.equal(users.findById(better.id).handsPlayed, 1, 'the player who bet has played a hand');
  assert.equal(users.findById(folder.id).handsPlayed, 0, 'posting the boot alone is not playing');
});

test('wins, losses and abandoned hands are counted separately', () => {
  const winner = makeUser('W');
  const loser = makeUser('L');
  const quitter = makeUser('Q');

  settle(
    [
      { userId: winner.id, delta: 800, isWinner: true, didChaal: true, leftMidHand: false },
      { userId: loser.id, delta: -400, isWinner: false, didChaal: true, leftMidHand: false },
      { userId: quitter.id, delta: -400, isWinner: false, didChaal: true, leftMidHand: true },
    ],
    1600,
  );

  const w = users.findById(winner.id);
  const l = users.findById(loser.id);
  const q = users.findById(quitter.id);

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

test('total winnings accumulate the pots taken', () => {
  const player = makeUser('Rich');

  settle([{ userId: player.id, delta: 500, isWinner: true, didChaal: true, leftMidHand: false }], 1000);
  settle([{ userId: player.id, delta: 900, isWinner: true, didChaal: true, leftMidHand: false }], 2500);

  const row = users.findById(player.id);
  assert.equal(row.totalWinnings, 3500, 'the two pots are summed');
  assert.equal(row.biggestPot, 2500);
  assert.equal(row.handsWon, 2);
});

// ------------------------------------------------- milestone reward (req 17)

test('the milestone reward unlocks every 25 played hands', () => {
  const player = makeUser('Grinder');
  const db = getDatabase();

  assert.equal(users.findById(player.id).rewards.milestoneAvailable, false, 'nothing at zero hands');
  assert.equal(users.findById(player.id).rewards.handsToNextMilestone, 25);

  db.prepare('UPDATE users SET hands_played = 24 WHERE id = ?').run(player.id);
  assert.equal(users.findById(player.id).rewards.milestoneAvailable, false, 'not yet at 24');
  assert.equal(users.findById(player.id).rewards.handsToNextMilestone, 1);

  db.prepare('UPDATE users SET hands_played = 25 WHERE id = ?').run(player.id);
  const ready = users.findById(player.id);
  assert.equal(ready.rewards.milestoneAvailable, true, 'available at 25');
  assert.equal(ready.rewards.milestoneAt, 25);
  assert.equal(ready.rewards.milestoneReward, 25000);
});

test('collecting the milestone reward grants 25,000 chips exactly once', () => {
  const player = makeUser('Collector');
  const db = getDatabase();
  db.prepare('UPDATE users SET hands_played = 50 WHERE id = ?').run(player.id);

  const before = users.findById(player.id).chips;
  const first = users.claimMilestoneReward(player.id);

  assert.equal(first.claimed, true);
  assert.equal(first.amount, 25000);
  assert.equal(first.milestone, 50);
  assert.equal(first.user.chips, before + 25000);
  assert.equal(first.user.rewards.milestoneAvailable, false, 'the same milestone is now spent');

  const second = users.claimMilestoneReward(player.id);
  assert.equal(second.claimed, false, 'a second claim pays nothing');
  assert.equal(second.reason, 'not_available');
  assert.equal(users.findById(player.id).chips, before + 25000, 'and moves no chips');
});

test('reaching the next milestone unlocks the reward again', () => {
  const player = makeUser('Repeater');
  const db = getDatabase();

  db.prepare('UPDATE users SET hands_played = 25 WHERE id = ?').run(player.id);
  assert.equal(users.claimMilestoneReward(player.id).claimed, true);

  db.prepare('UPDATE users SET hands_played = 49 WHERE id = ?').run(player.id);
  assert.equal(users.findById(player.id).rewards.milestoneAvailable, false, 'still on the 25 milestone');

  db.prepare('UPDATE users SET hands_played = 50 WHERE id = ?').run(player.id);
  assert.equal(users.findById(player.id).rewards.milestoneAvailable, true, '50 is a new milestone');
  assert.equal(users.claimMilestoneReward(player.id).claimed, true);
});

test('the milestone reward is written to the chip ledger', () => {
  const player = makeUser('Audited');
  const db = getDatabase();
  db.prepare('UPDATE users SET hands_played = 25 WHERE id = ?').run(player.id);
  users.claimMilestoneReward(player.id);

  const row = db
    .prepare("SELECT * FROM chip_ledger WHERE user_id = ? AND reason = 'milestone_reward'")
    .get(player.id);

  assert.ok(row, 'the grant is auditable');
  assert.equal(row.delta, 25000);
});

// ----------------------------------------------------- timed bonus (req 18)

test('a new account can collect the timed bonus straight away', () => {
  const player = makeUser('Fresh');
  const rewards = users.findById(player.id).rewards;

  assert.equal(rewards.bonusAvailable, true, 'no waiting on a brand new account');
  assert.equal(rewards.bonusReward, 10000);
  assert.equal(rewards.bonusIntervalMs, 4 * 60 * 60 * 1000, 'the countdown is 4 hours');
});

test('collecting the bonus grants 10,000 chips and starts a 4-hour countdown', () => {
  const player = makeUser('Bonus');
  const before = users.findById(player.id).chips;

  const claimedAt = Date.now();
  const result = users.claimTimedBonus(player.id);

  assert.equal(result.claimed, true);
  assert.equal(result.amount, 10000);
  assert.equal(result.user.chips, before + 10000);

  const fourHours = 4 * 60 * 60 * 1000;
  assert.ok(result.readyAt >= claimedAt + fourHours - 1000, 'the next one is ~4 hours out');
  assert.ok(result.readyAt <= Date.now() + fourHours + 1000);
  assert.equal(result.user.rewards.bonusAvailable, false, 'and is not collectable now');
});

test('the bonus cannot be collected twice inside the countdown', () => {
  const player = makeUser('Greedy');
  users.claimTimedBonus(player.id);

  const before = users.findById(player.id).chips;
  const second = users.claimTimedBonus(player.id);

  assert.equal(second.claimed, false);
  assert.equal(second.reason, 'not_ready');
  assert.ok(second.readyAt > Date.now());
  assert.equal(users.findById(player.id).chips, before, 'no chips moved');
});

test('the countdown lives in the database, so it survives a restart', () => {
  const player = makeUser('Persistent');
  const result = users.claimTimedBonus(player.id);

  const stored = getDatabase().prepare('SELECT next_bonus_at FROM users WHERE id = ?').get(player.id);
  assert.equal(stored.next_bonus_at, result.readyAt, 'the unlock time is persisted, not held in memory');

  // Once the stored time passes, it is collectable again.
  getDatabase().prepare('UPDATE users SET next_bonus_at = ? WHERE id = ?')
    .run(Date.now() - 1, player.id);
  assert.equal(users.findById(player.id).rewards.bonusAvailable, true);
  assert.equal(users.claimTimedBonus(player.id).claimed, true);
});

// ------------------------------------------------------ avatars (req 20/21)

test('a provider picture is kept and used by default', () => {
  const { user } = users.upsertFromProfile({
    provider: 'google',
    providerUserId: `g-${Math.random().toString(36).slice(2)}`,
    displayName: 'G Player',
    avatarUrl: 'https://lh3.googleusercontent.com/example',
  });

  assert.equal(user.avatarUrl, 'https://lh3.googleusercontent.com/example');
  assert.equal(user.providerAvatarUrl, 'https://lh3.googleusercontent.com/example');
  assert.equal(user.avatarChoice, null);
});

test('a chosen picture overrides the provider one, and clearing restores it', () => {
  const { user } = users.upsertFromProfile({
    provider: 'facebook',
    providerUserId: `f-${Math.random().toString(36).slice(2)}`,
    displayName: 'F Player',
    avatarUrl: 'https://graph.facebook.com/example',
  });

  const chosen = users.setAvatarChoice(user.id, '/profiles/ace.svg');
  assert.equal(chosen.avatarUrl, '/profiles/ace.svg', 'the choice wins');
  assert.equal(chosen.providerAvatarUrl, 'https://graph.facebook.com/example', 'the original is kept');

  const cleared = users.setAvatarChoice(user.id, null);
  assert.equal(cleared.avatarUrl, 'https://graph.facebook.com/example', 'clearing falls back');
});
