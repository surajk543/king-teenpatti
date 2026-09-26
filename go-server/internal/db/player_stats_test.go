package db_test

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// Friends V1 (owner, 26 Sep 2026) moved the six gameplay counters off users
// into player_stats: the checkpoints write them there — in the transaction
// of the chip delta they belong to, and only when one moves — and the
// account reads them from there, with the wire's user object unchanged.

// statsRow is one player_stats row as stored, ok=false when there is none.
type statsRow struct {
	played, won, lost, left, winnings, biggest int64
	ok                                         bool
}

func (f *fixture) stats(userID string) statsRow {
	f.t.Helper()
	var r statsRow
	err := f.d.Pool.QueryRow(f.ctx, `SELECT hands_played, hands_won, hands_lost, hands_left, total_winnings, biggest_pot
	     FROM player_stats WHERE user_id = $1`, userID).Scan(&r.played, &r.won, &r.lost, &r.left, &r.winnings, &r.biggest)
	if err == nil {
		r.ok = true
	}
	return r
}

// retiredColumns sums the six users columns the counters used to live in.
func (f *fixture) retiredColumns(userID string) int64 {
	f.t.Helper()
	return f.scalar(`SELECT (hands_played + hands_won + hands_lost + hands_left_mid)::bigint + total_winnings + biggest_pot
	     FROM users WHERE id = $1`, userID)
}

func TestAHandsCountersLandInPlayerStatsAndNoneInUsers(t *testing.T) {
	f := newFixture(t)
	winner, loser, leaver, folder := f.user("Winner"), f.user("Loser"), f.user("Leaver"), f.user("Folder")
	room, hand := "room-stats", "hand-stats-"+randomSuffix(t)

	// Mid-hand: the folder packs (money only), the leaver walks out (resolved
	// now, as a departure).
	if _, err := f.pack(room, hand, folder, -200); err != nil {
		t.Fatal(err)
	}
	if got := f.stats(folder.ID); got.ok {
		t.Fatalf("a pack moves no counter, so it writes no player_stats row: %+v", got)
	}
	if _, err := f.left(room, hand, leaver, -600, true); err != nil {
		t.Fatal(err)
	}
	// The hand end: a winner of a 2,000 pot, a loser who bet, and the folder's
	// outcome row, which resolves them as a loss with no chaal.
	if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: room, HandID: hand, Entries: []game.SettleEntry{
		settleEntry(hand, winner.ID, 1400, true, true, 2000),
		settleEntry(hand, loser.ID, -600, false, true, 0),
		settleEntry(hand, folder.ID, 0, false, false, 0),
	}}); err != nil {
		t.Fatal(err)
	}

	for name, c := range map[string]struct {
		id   string
		want statsRow
	}{
		"winner": {winner.ID, statsRow{played: 1, won: 1, winnings: 2000, biggest: 2000, ok: true}},
		"loser":  {loser.ID, statsRow{played: 1, lost: 1, ok: true}},
		"leaver": {leaver.ID, statsRow{played: 1, left: 1, ok: true}},
		// Posting the boot and folding is not a hand played (requirement 16).
		"folder": {folder.ID, statsRow{lost: 1, ok: true}},
	} {
		if got := f.stats(c.id); got != c.want {
			t.Errorf("%s's player_stats = %+v, want %+v", name, got, c.want)
		}
		if n := f.retiredColumns(c.id); n != 0 {
			t.Errorf("%s: the retired users columns moved (%d); the counters live in player_stats", name, n)
		}
	}

	// A second win adds to the row rather than replacing it; the biggest pot
	// is the larger of the two.
	hand2 := "hand-stats-2-" + randomSuffix(t)
	if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: room, HandID: hand2, Entries: []game.SettleEntry{
		settleEntry(hand2, winner.ID, 700, true, true, 1500),
		settleEntry(hand2, loser.ID, -700, false, true, 0),
	}}); err != nil {
		t.Fatal(err)
	}
	if got := f.stats(winner.ID); got != (statsRow{played: 2, won: 2, winnings: 3500, biggest: 2000, ok: true}) {
		t.Errorf("after a second win = %+v", got)
	}

	// A replayed settle (its acknowledgement lost) is refused whole by the
	// ledger's UNIQUE action ids, counters included: nothing is counted twice.
	if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: room, HandID: hand2, Entries: []game.SettleEntry{
		settleEntry(hand2, winner.ID, 700, true, true, 1500),
		settleEntry(hand2, loser.ID, -700, false, true, 0),
	}}); codeOf(t, err) != game.CodeDuplicateAction {
		t.Fatalf("the replay: %v", err)
	}
	if got := f.stats(winner.ID); got.played != 2 || got.won != 2 || got.winnings != 3500 {
		t.Errorf("a replay counted again: %+v", got)
	}

	// The account read takes its counters from player_stats — handsLeftMid
	// is hands_left — and the wire object carries exactly the keys it did.
	u := f.find(leaver.ID)
	if u.HandsPlayed != 1 || u.HandsLeftMid != 1 || u.HandsLost != 0 || u.HandsWon != 0 {
		t.Errorf("the leaver reads %+v", u)
	}
	w := f.find(winner.ID)
	if w.HandsPlayed != 2 || w.HandsWon != 2 || w.TotalWinnings != 3500 || w.BiggestPot != 2000 {
		t.Errorf("the winner reads %+v", w)
	}
	raw, err := json.Marshal(w)
	if err != nil {
		t.Fatal(err)
	}
	var wire map[string]json.RawMessage
	if err := json.Unmarshal(raw, &wire); err != nil {
		t.Fatal(err)
	}
	for key, want := range map[string]string{"handsPlayed": "2", "handsWon": "2", "handsLost": "0", "handsLeftMid": "0",
		"totalWinnings": "3500", "biggestPot": "2000"} {
		if string(wire[key]) != want {
			t.Errorf("wire %s = %s, want %s", key, wire[key], want)
		}
	}
	for _, key := range []string{"handsLeft", "stats", "playerStats"} {
		if _, ok := wire[key]; ok {
			t.Errorf("the wire user object gained %q", key)
		}
	}
	f.reconcile()
}

// A resolution that moves no counter writes no stats statement: a 3-Card
// Poker push by a player who had not bet is neither won, lost, left nor
// played.
func TestAnOutcomeThatMovesNoCounterWritesNoStatsRow(t *testing.T) {
	f := newFixture(t)
	p := f.user("Push")
	hand := "hand-push-" + randomSuffix(t)
	entry := settleEntry(hand, p.ID, 0, false, false, 0)
	entry.Push = true
	if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: "room-push", HandID: hand, Entries: []game.SettleEntry{entry}}); err != nil {
		t.Fatal(err)
	}
	if got := f.stats(p.ID); got.ok {
		t.Fatalf("a push that moved no counter wrote a player_stats row: %+v", got)
	}
	if len(f.handLedgerRows(hand)) != 1 {
		t.Fatal("the outcome row is still written: it says the player was in the hand")
	}
	// The account reads zeros with no row.
	if u := f.find(p.ID); u.HandsPlayed != 0 || u.HandsWon != 0 || u.HandsLost != 0 || u.HandsLeftMid != 0 ||
		u.TotalWinnings != 0 || u.BiggestPot != 0 {
		t.Fatalf("a player with no row reads %+v", u)
	}
}

// The boot's backfill copies an account's retired counters into player_stats
// once — hands_left_mid as hands_left — and never again over a live row.
func TestTheBackfillCopiesTheRetiredCountersOnceAndNeverOverLiveStatistics(t *testing.T) {
	f := newFixture(t)
	old := f.user("Veteran")
	if _, err := f.d.Pool.Exec(f.ctx, `DELETE FROM player_stats WHERE user_id = $1`, old.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE users SET hands_played = 40, hands_won = 10, hands_lost = 25, hands_left_mid = 5,
	       total_winnings = 700000, biggest_pot = 120000 WHERE id = $1`, old.ID); err != nil {
		t.Fatal(err)
	}
	reboot(t, f.d)
	if got := f.stats(old.ID); got != (statsRow{played: 40, won: 10, lost: 25, left: 5, winnings: 700000, biggest: 120000, ok: true}) {
		t.Fatalf("backfilled = %+v", got)
	}
	u := f.find(old.ID)
	if u.HandsPlayed != 40 || u.HandsLeftMid != 5 || u.TotalWinnings != 700000 {
		t.Fatalf("the account reads %+v", u)
	}
	// Twenty-five hands in, the milestone judges player_stats.hands_played.
	if !u.Rewards.MilestoneAvailable || u.Rewards.MilestoneAt != 25 {
		t.Fatalf("the milestone after the backfill: %+v", u.Rewards)
	}

	// A hand played since; then a boot, with the stale figures still on users.
	hand := "hand-after-" + randomSuffix(t)
	if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: "room-after", HandID: hand, Entries: []game.SettleEntry{
		settleEntry(hand, old.ID, 900, true, true, 1800),
	}}); err != nil {
		t.Fatal(err)
	}
	reboot(t, f.d)
	if got := f.stats(old.ID); got.played != 41 || got.won != 11 || got.winnings != 701800 {
		t.Fatalf("a boot copied the retired columns over live statistics: %+v", got)
	}
	// A new account gets a row of zeros at the next boot, which the reads do
	// not tell from no row at all.
	fresh := f.user("Fresh")
	reboot(t, f.d)
	if got := f.stats(fresh.ID); got != (statsRow{ok: true}) {
		t.Fatalf("a new account's backfilled row = %+v", got)
	}
}

// The users columns are never written by this build: a whole career of
// checkpoints and rewards leaves them at 0.
func TestNothingWritesTheRetiredUsersColumns(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("A"), f.user("B")
	for i := 0; i < 3; i++ {
		hand := "hand-career-" + randomSuffix(t)
		if _, err := f.left("room-career", hand, b, -100, true); err != nil {
			t.Fatal(err)
		}
		if _, err := f.ledger.Settle(context.Background(), game.SettleRequest{RoomID: "room-career", HandID: hand, Entries: []game.SettleEntry{
			settleEntry(hand, a.ID, 100, true, true, 300),
		}}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := f.users.ClaimTimedBonus(f.ctx, a.ID); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{a.ID, b.ID} {
		if n := f.retiredColumns(id); n != 0 {
			t.Fatalf("a retired users column was written for %s: %d", id, n)
		}
	}
	if got := f.stats(a.ID); got.won != 3 || got.played != 3 {
		t.Fatalf("A's statistics = %+v", got)
	}
	if got := f.stats(b.ID); got.left != 3 || got.played != 3 {
		t.Fatalf("B's statistics = %+v", got)
	}
	_ = db.MilestoneEvery
}
