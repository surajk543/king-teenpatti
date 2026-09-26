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

// usersCounterColumns counts the gameplay-counter columns users has in the
// fixture's schema — none: they live in player_stats alone.
func (f *fixture) usersCounterColumns() int64 {
	f.t.Helper()
	return f.scalar(`SELECT count(*) FROM information_schema.columns
	     WHERE table_schema = current_schema() AND table_name = 'users'
	       AND column_name IN ('hands_played', 'hands_won', 'hands_lost', 'hands_left_mid', 'total_winnings', 'biggest_pot')`)
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
	}
	if n := f.usersCounterColumns(); n != 0 {
		t.Errorf("users has %d gameplay-counter columns; the counters live in player_stats alone", n)
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

// A whole career of checkpoints and rewards is counted in player_stats, and
// users has no counter column for anything to write (owner, 26 Sep 2026: "only
// store in player_stats table").
func TestAWholeCareerIsCountedInPlayerStatsAlone(t *testing.T) {
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
	if n := f.usersCounterColumns(); n != 0 {
		t.Fatalf("users has %d gameplay-counter columns", n)
	}
	if got := f.stats(a.ID); got.won != 3 || got.played != 3 {
		t.Fatalf("A's statistics = %+v", got)
	}
	if got := f.stats(b.ID); got.left != 3 || got.played != 3 {
		t.Fatalf("B's statistics = %+v", got)
	}
	_ = db.MilestoneEvery
}
