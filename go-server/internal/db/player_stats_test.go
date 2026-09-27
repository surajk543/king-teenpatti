package db_test

import (
	"encoding/json"
	"fmt"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// Player stats v2 (owner, 27 Sep 2026): a player's statistics per bucket —
// TEEN_PATTI, VARIATION, POKER — in player_stats, per variation in
// player_variation_stats, written by the stats flusher's group commit alone
// (db.StatsStore.Flush, one transaction per batch, exactly once by its
// stats_flushes receipt), and summed by every account read.

// statsRow is one player_stats row as stored, ok=false when there is none.
type statsRow struct {
	played, won, lost, left, winnings, biggest       int64
	trail, pureSequence, sequence, color, pair, high int64
	ok                                               bool
}

func (f *fixture) stats(userID string, bucket game.StatsBucket) statsRow {
	f.t.Helper()
	var r statsRow
	err := f.d.Pool.QueryRow(f.ctx, `SELECT hands_played, hands_won, hands_lost, hands_left, total_winnings, biggest_pot,
	            trail, pure_sequence, sequence, color, pair, high_card
	       FROM player_stats WHERE user_id = $1 AND category = $2`, userID, string(bucket)).
		Scan(&r.played, &r.won, &r.lost, &r.left, &r.winnings, &r.biggest,
			&r.trail, &r.pureSequence, &r.sequence, &r.color, &r.pair, &r.high)
	if err == nil {
		r.ok = true
	}
	return r
}

// statsRows counts a player's rows in both statistics tables.
func (f *fixture) statsRows(userID string) int64 {
	f.t.Helper()
	return f.count(`SELECT (SELECT count(*) FROM player_stats WHERE user_id = $1) +
	                       (SELECT count(*) FROM player_variation_stats WHERE user_id = $1)`, userID)
}

// flushHands is what the recorder and the flusher do for these hands in
// production, stated directly: every hand folded into its player's delta, the
// lot committed as ONE batch under batchID. Returns whether it was applied.
func (f *fixture) flushHands(batchID string, hands ...game.HandStats) bool {
	f.t.Helper()
	applied, err := db.NewStatsStore(f.d, nil).Flush(f.ctx, batchID, deltasOf(hands...))
	if err != nil {
		f.t.Fatalf("flush %s: %v", batchID, err)
	}
	return applied
}

// deltasOf folds hands into one delta per player.
func deltasOf(hands ...game.HandStats) []db.StatsDelta {
	byUser := map[string]*db.StatsDelta{}
	var order []string
	for _, h := range hands {
		d := byUser[h.UserID]
		if d == nil {
			d = db.NewStatsDelta(h.UserID)
			byUser[h.UserID] = d
			order = append(order, h.UserID)
		}
		d.Add(h)
	}
	out := make([]db.StatsDelta, 0, len(order))
	for _, id := range order {
		out = append(out, *byUser[id])
	}
	return out
}

// counted flushes, as a batch of its own, what the game records for these
// settled entries at a table of bucket (game.StatsForEntry): the counters of
// every outcome row.
func (f *fixture) counted(bucket game.StatsBucket, entries ...game.SettleEntry) {
	f.t.Helper()
	var hands []game.HandStats
	for _, e := range entries {
		if h, ok := game.StatsForEntry(e, bucket); ok && !h.Empty() {
			hands = append(hands, h)
		}
	}
	f.flushHands("counted-"+randomSuffix(f.t), hands...)
}

func TestTheLedgerWritesMoneyOnlyAndNoStatistics(t *testing.T) {
	f := newFixture(t)
	winner, loser, leaver, folder := f.user("Winner"), f.user("Loser"), f.user("Leaver"), f.user("Folder")
	room, hand := "room-money-only", "hand-money-only-"+randomSuffix(t)
	if _, err := f.pack(room, hand, folder, -200); err != nil {
		t.Fatal(err)
	}
	if _, err := f.left(room, hand, leaver, -600, true); err != nil {
		t.Fatal(err)
	}
	req := game.SettleRequest{RoomID: room, HandID: hand, Entries: []game.SettleEntry{
		settleEntry(hand, winner.ID, 1400, true, true, 2000),
		settleEntry(hand, loser.ID, -600, false, true, 0),
		settleEntry(hand, folder.ID, 0, false, false, 0),
	}, Stats: []game.HandStats{{UserID: winner.ID, Bucket: game.StatsTeenPatti, Played: 1, Won: 1, Winnings: 2000, HasHeld: true, Held: game.Trail}}}
	if _, err := f.ledger.Settle(f.ctx, req); err != nil {
		t.Fatal(err)
	}
	for _, u := range []*db.User{winner, loser, leaver, folder} {
		if n := f.statsRows(u.ID); n != 0 {
			t.Errorf("%s: the ledger wrote %d statistics rows; it writes money only", u.DisplayName, n)
		}
	}
	if got := f.chips(winner.ID); got != welcome+1400 {
		t.Fatalf("the money still moved: winner %d", got)
	}
	if n := f.count(`SELECT count(*) FROM stats_flushes`); n != 0 {
		t.Fatalf("%d flush receipts from a ledger write", n)
	}
	f.reconcile()
}

func TestAFlushAddsEveryBucketsCountersAndKeepsTheBiggestPot(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("A"), f.user("B")
	if !f.flushHands("b1",
		game.HandStats{UserID: a.ID, Bucket: game.StatsTeenPatti, Played: 1, Won: 1, Winnings: 2000, HasHeld: true, Held: game.Trail},
		game.HandStats{UserID: a.ID, Bucket: game.StatsTeenPatti, Played: 1, Lost: 1, HasHeld: true, Held: game.HighCard},
		game.HandStats{UserID: a.ID, Bucket: game.StatsVariation, Played: 1, Won: 1, Winnings: 900, HasHeld: true, Held: game.Pair,
			Variation: game.VariationMuflis, VariationWon: true},
		game.HandStats{UserID: a.ID, Bucket: game.StatsPoker, Left: 1},
		game.HandStats{UserID: b.ID, Bucket: game.StatsTeenPatti, Lost: 1, HasHeld: true, Held: game.PureSequence},
	) {
		t.Fatal("the first batch was not applied")
	}
	if !f.flushHands("b2",
		game.HandStats{UserID: a.ID, Bucket: game.StatsTeenPatti, Played: 1, Won: 1, Winnings: 1500, HasHeld: true, Held: game.Trail},
		game.HandStats{UserID: a.ID, Bucket: game.StatsVariation, Played: 1, Lost: 1, HasHeld: true, Held: game.Color,
			Variation: game.VariationAK47},
	) {
		t.Fatal("the second batch was not applied")
	}
	if got, want := f.stats(a.ID, game.StatsTeenPatti), (statsRow{played: 3, won: 2, lost: 1, winnings: 3500, biggest: 2000,
		trail: 2, high: 1, ok: true}); got != want {
		t.Errorf("A's Teen Patti = %+v, want %+v", got, want)
	}
	if got, want := f.stats(a.ID, game.StatsVariation), (statsRow{played: 2, won: 1, lost: 1, winnings: 900, biggest: 900,
		pair: 1, color: 1, ok: true}); got != want {
		t.Errorf("A's Variation = %+v, want %+v", got, want)
	}
	if got, want := f.stats(a.ID, game.StatsPoker), (statsRow{left: 1, ok: true}); got != want {
		t.Errorf("A's Poker = %+v, want %+v (the rank columns stay 0 on a poker row)", got, want)
	}
	if got, want := f.stats(b.ID, game.StatsTeenPatti), (statsRow{lost: 1, pureSequence: 1, ok: true}); got != want {
		t.Errorf("B's Teen Patti = %+v, want %+v", got, want)
	}
	if f.stats(b.ID, game.StatsPoker).ok {
		t.Error("a bucket B never played in has a row")
	}
	for variation, want := range map[string][2]int64{"MUFLIS": {1, 1}, "AK47": {1, 0}} {
		var played, won int64
		if err := f.d.Pool.QueryRow(f.ctx, `SELECT hands_played, hands_won FROM player_variation_stats WHERE user_id = $1 AND variation = $2`,
			a.ID, variation).Scan(&played, &won); err != nil || played != want[0] || won != want[1] {
			t.Errorf("A's %s = %d played, %d won (%v), want %v", variation, played, won, err, want)
		}
	}
	if n := f.count(`SELECT players FROM stats_flushes WHERE batch_id = 'b1'`); n != 2 {
		t.Errorf("b1's receipt names %d players, want 2", n)
	}
}

// Exactly once: a batch whose commit went unacknowledged is flushed again
// under the same id, finds its receipt and adds nothing.
func TestAFlushIsExactlyOnceUnderItsBatchID(t *testing.T) {
	f := newFixture(t)
	a := f.user("A")
	hand := game.HandStats{UserID: a.ID, Bucket: game.StatsPoker, Played: 1, Won: 1, Winnings: 500}
	if !f.flushHands("once", hand) {
		t.Fatal("the first flush was not applied")
	}
	if f.flushHands("once", hand, hand) {
		t.Fatal("a batch already committed was applied again")
	}
	if got := f.stats(a.ID, game.StatsPoker); got.won != 1 || got.played != 1 || got.winnings != 500 {
		t.Fatalf("after the replay: %+v", got)
	}
	if n := f.count(`SELECT count(*) FROM stats_flushes WHERE batch_id = 'once'`); n != 1 {
		t.Fatalf("%d receipts", n)
	}
	if _, err := db.NewStatsStore(f.d, nil).Flush(f.ctx, "", deltasOf(hand)); err == nil {
		t.Fatal("a batch with no id was flushed")
	}
	// A player named twice in one batch is folded into one row per bucket.
	twice := append(deltasOf(hand), deltasOf(game.HandStats{UserID: a.ID, Bucket: game.StatsPoker, Played: 1, Won: 1, Winnings: 900})...)
	if applied, err := db.NewStatsStore(f.d, nil).Flush(f.ctx, "twice", twice); err != nil || !applied {
		t.Fatalf("a player named twice: %v %v", applied, err)
	}
	if got := f.stats(a.ID, game.StatsPoker); got.won != 3 || got.winnings != 1900 || got.biggest != 900 {
		t.Fatalf("after the doubled batch: %+v", got)
	}
}

// A batch whose transaction failed leaves nothing — no counter and no
// receipt — and its retry under the same id adds everything, once.
func TestAFailedFlushLeavesNothingAndItsRetryAddsEverything(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("A"), f.user("B")
	// B's row cannot take one more hand: the upsert overflows and the whole
	// transaction rolls back, A's counters and the receipt with it.
	if err := f.d.Exec(f.ctx, `INSERT INTO player_stats (user_id, category, hands_played) VALUES ($1, 'POKER', 9223372036854775807)`, b.ID); err != nil {
		t.Fatal(err)
	}
	hands := []game.HandStats{
		{UserID: a.ID, Bucket: game.StatsPoker, Played: 1, Won: 1, Winnings: 800},
		{UserID: b.ID, Bucket: game.StatsPoker, Played: 1, Lost: 1},
	}
	store := db.NewStatsStore(f.d, nil)
	if _, err := store.Flush(f.ctx, "retry-me", deltasOf(hands...)); err == nil {
		t.Fatal("the overflowing flush committed")
	}
	if f.stats(a.ID, game.StatsPoker).ok || f.count(`SELECT count(*) FROM stats_flushes`) != 0 {
		t.Fatal("a failed flush left counters or a receipt behind")
	}
	if err := f.d.Exec(f.ctx, `UPDATE player_stats SET hands_played = 0 WHERE user_id = $1`, b.ID); err != nil {
		t.Fatal(err)
	}
	applied, err := store.Flush(f.ctx, "retry-me", deltasOf(hands...))
	if err != nil || !applied {
		t.Fatalf("the retry: applied %v, %v", applied, err)
	}
	if got := f.stats(a.ID, game.StatsPoker); got.played != 1 || got.won != 1 || got.winnings != 800 {
		t.Fatalf("A after the retry: %+v", got)
	}
	if got := f.stats(b.ID, game.StatsPoker); got.played != 1 || got.lost != 1 {
		t.Fatalf("B after the retry: %+v", got)
	}
}

func TestTheAccountReadSumsTheBucketsAndCarriesTheStatsPerCategory(t *testing.T) {
	f := newFixture(t)
	a := f.user("A")
	f.flushHands("sums",
		game.HandStats{UserID: a.ID, Bucket: game.StatsTeenPatti, Played: 1, Won: 1, Winnings: 3000, HasHeld: true, Held: game.Trail},
		game.HandStats{UserID: a.ID, Bucket: game.StatsTeenPatti, Played: 1, Lost: 1, HasHeld: true, Held: game.Pair},
		game.HandStats{UserID: a.ID, Bucket: game.StatsTeenPatti, Left: 1},
		game.HandStats{UserID: a.ID, Bucket: game.StatsVariation, Played: 1, Won: 1, Winnings: 7000, HasHeld: true, Held: game.Sequence,
			Variation: game.VariationFiveCard, VariationWon: true},
		game.HandStats{UserID: a.ID, Bucket: game.StatsVariation, Lost: 1, HasHeld: true, Held: game.HighCard, Variation: game.VariationMuflis},
		game.HandStats{UserID: a.ID, Bucket: game.StatsVariation, Played: 1, Lost: 1, HasHeld: true, Held: game.Color,
			Variation: game.Variation("ZEBRA")},
		game.HandStats{UserID: a.ID, Bucket: game.StatsVariation, Played: 1, Lost: 1, HasHeld: true, Held: game.PureSequence,
			Variation: game.Variation("ALPHA")},
		game.HandStats{UserID: a.ID, Bucket: game.StatsPoker, Played: 1, Won: 1, Winnings: 500},
	)
	u := f.find(a.ID)
	if u.HandsPlayed != 6 || u.HandsWon != 3 || u.HandsLost != 4 || u.HandsLeftMid != 1 || u.TotalWinnings != 10500 || u.BiggestPot != 7000 {
		t.Fatalf("the totals: played %d won %d lost %d left %d winnings %d biggest %d",
			u.HandsPlayed, u.HandsWon, u.HandsLost, u.HandsLeftMid, u.TotalWinnings, u.BiggestPot)
	}
	tp := u.Stats.TeenPatti
	if tp.HandsPlayed != 2 || tp.HandsWon != 1 || tp.HandsLost != 1 || tp.HandsLeft != 1 || tp.TotalWinnings != 3000 ||
		tp.BiggestPot != 3000 || tp.WinRate != 50 || tp.Hands != (db.HandTally{Trail: 1, Pair: 1}) {
		t.Errorf("teenPatti = %+v", tp)
	}
	v := u.Stats.Variation
	if v.HandsPlayed != 3 || v.HandsWon != 1 || v.WinRate != 33.33 || v.Hands != (db.HandTally{Sequence: 1, HighCard: 1, Color: 1, PureSequence: 1}) {
		t.Errorf("variation = %+v", v)
	}
	// The chooser's order, then any other by name.
	want := []db.VariationTally{{Variation: "MUFLIS", HandsPlayed: 1}, {Variation: "FIVE_CARD", HandsPlayed: 1, HandsWon: 1},
		{Variation: "ALPHA", HandsPlayed: 1}, {Variation: "ZEBRA", HandsPlayed: 1}}
	if !reflect.DeepEqual(v.Variations, want) {
		t.Errorf("variations = %+v, want %+v", v.Variations, want)
	}
	if p := u.Stats.Poker; p.HandsPlayed != 1 || p.HandsWon != 1 || p.WinRate != 100 || p.BiggestPot != 500 {
		t.Errorf("poker = %+v", p)
	}

	// The wire: each bucket's keys, and the hands and variations as sent.
	raw, err := json.Marshal(u)
	if err != nil {
		t.Fatal(err)
	}
	var wire struct {
		Stats map[string]map[string]json.RawMessage `json:"stats"`
	}
	if err := json.Unmarshal(raw, &wire); err != nil {
		t.Fatal(err)
	}
	keys := func(m map[string]json.RawMessage) string {
		var out []string
		for k := range m {
			out = append(out, k)
		}
		sort.Strings(out)
		return fmt.Sprint(out)
	}
	sorted := func(in ...string) string {
		sort.Strings(in)
		return fmt.Sprint(in)
	}
	base := []string{"biggestPot", "handsLeft", "handsLost", "handsPlayed", "handsWon", "totalWinnings", "winRate"}
	if got, want := keys(wire.Stats["teenPatti"]), sorted(append([]string{"hands"}, base...)...); got != want {
		t.Errorf("teenPatti keys %s, want %s", got, want)
	}
	if got, want := keys(wire.Stats["variation"]), sorted(append([]string{"hands", "variations"}, base...)...); got != want {
		t.Errorf("variation keys %s, want %s", got, want)
	}
	if got, want := keys(wire.Stats["poker"]), sorted(base...); got != want {
		t.Errorf("poker keys %s, want %s", got, want)
	}
	if got := string(wire.Stats["teenPatti"]["hands"]); got != `{"trail":1,"pureSequence":0,"sequence":0,"color":0,"pair":1,"highCard":0}` {
		t.Errorf("teenPatti.hands = %s", got)
	}
	if got := string(wire.Stats["variation"]["variations"]); !strings.HasPrefix(got, `[{"variation":"MUFLIS","handsPlayed":1,"handsWon":0}`) {
		t.Errorf("variation.variations = %s", got)
	}
}

// A player with no row reads zeros everywhere, and every list is a list.
func TestAPlayerWithNoStatisticsReadsZerosAndEmptyLists(t *testing.T) {
	f := newFixture(t)
	u := f.find(f.user("Fresh").ID)
	if u.HandsPlayed != 0 || u.HandsWon != 0 || u.HandsLost != 0 || u.HandsLeftMid != 0 || u.TotalWinnings != 0 || u.BiggestPot != 0 {
		t.Fatalf("a player with no row reads %+v", u)
	}
	raw, err := json.Marshal(u.Stats)
	if err != nil {
		t.Fatal(err)
	}
	const zero = `"handsPlayed":0,"handsWon":0,"handsLost":0,"handsLeft":0,"totalWinnings":0,"biggestPot":0,"winRate":0`
	const hands = `"hands":{"trail":0,"pureSequence":0,"sequence":0,"color":0,"pair":0,"highCard":0}`
	want := `{"teenPatti":{` + zero + `,` + hands + `},"variation":{` + zero + `,` + hands + `,"variations":[]},"poker":{` + zero + `}}`
	if string(raw) != want {
		t.Fatalf("user.stats =\n %s\nwant\n %s", raw, want)
	}
}

// DELETE /api/account removes the player's statistics in its own
// transaction, and a flush of counters still pending for them brings none
// back.
func TestDeletingAnAccountRemovesItsStatisticsAndAFlushBringsNoneBack(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("Gone"), f.user("Stays")
	hand := game.HandStats{UserID: a.ID, Bucket: game.StatsVariation, Played: 1, Won: 1, Winnings: 100, HasHeld: true, Held: game.Pair,
		Variation: game.VariationJoker, VariationWon: true}
	f.flushHands("before", hand, game.HandStats{UserID: b.ID, Bucket: game.StatsPoker, Lost: 1})
	if f.statsRows(a.ID) != 2 {
		t.Fatalf("%d rows before the deletion, want a bucket and a variation", f.statsRows(a.ID))
	}
	if err := f.users.DeleteAccount(f.ctx, a.ID); err != nil {
		t.Fatal(err)
	}
	if n := f.statsRows(a.ID); n != 0 {
		t.Fatalf("%d statistics rows survive the deletion", n)
	}
	if !f.flushHands("after", hand, game.HandStats{UserID: b.ID, Bucket: game.StatsPoker, Lost: 1}) {
		t.Fatal("the batch after the deletion was not applied")
	}
	if n := f.statsRows(a.ID); n != 0 {
		t.Fatalf("a flush brought %d rows back for a deleted account", n)
	}
	if got := f.stats(b.ID, game.StatsPoker); got.lost != 2 {
		t.Fatalf("the other player of the batch: %+v", got)
	}
	// Nor for an account that never existed.
	if !f.flushHands("nobody", game.HandStats{UserID: "no-such-user", Bucket: game.StatsPoker, Lost: 1}) {
		t.Fatal("a batch naming nobody was refused rather than skipped")
	}
}

// The HANDS_PLAYED milestone is judged on hands_played summed over every
// bucket.
func TestTheMilestoneReadsTheSumOfHandsPlayed(t *testing.T) {
	f := newFixture(t)
	p := f.user("Grinder")
	var hands []game.HandStats
	for i := 0; i < 10; i++ {
		hands = append(hands, game.HandStats{UserID: p.ID, Bucket: game.StatsTeenPatti, Played: 1, Lost: 1})
		hands = append(hands, game.HandStats{UserID: p.ID, Bucket: game.StatsVariation, Played: 1, Lost: 1})
	}
	for i := 0; i < 4; i++ {
		hands = append(hands, game.HandStats{UserID: p.ID, Bucket: game.StatsPoker, Played: 1, Lost: 1})
	}
	f.flushHands("24", hands...)
	if r := f.find(p.ID).Rewards; r.MilestoneAvailable || r.HandsToNextMilestone != 1 {
		t.Fatalf("at 24 across the buckets: %+v", r)
	}
	f.flushHands("25", game.HandStats{UserID: p.ID, Bucket: game.StatsPoker, Played: 1, Won: 1, Winnings: 10})
	if r := f.find(p.ID).Rewards; !r.MilestoneAvailable || r.MilestoneAt != 25 {
		t.Fatalf("at 25 across the buckets: %+v", r)
	}
	res, err := f.users.ClaimMilestoneReward(f.ctx, p.ID)
	if err != nil || !res.Claimed || res.Milestone != 25 {
		t.Fatalf("the claim: %+v %v", res, err)
	}
	f.reconcile()
}

// The receipts are kept for the retention the flusher asks and no longer.
func TestOnlyOldFlushReceiptsArePruned(t *testing.T) {
	f := newFixture(t)
	if err := f.d.Exec(f.ctx, `INSERT INTO stats_flushes (batch_id, players, flushed_at) VALUES ('old', 3, 1000), ('new', 2, 5000)`); err != nil {
		t.Fatal(err)
	}
	pruned, err := db.NewStatsStore(f.d, nil).PruneFlushes(f.ctx, 2000)
	if err != nil || pruned != 1 {
		t.Fatalf("pruned %d, %v", pruned, err)
	}
	if n := f.count(`SELECT count(*) FROM stats_flushes WHERE batch_id = 'new'`); n != 1 {
		t.Fatal("a recent receipt was pruned")
	}
}

// Sheet reads exactly what the account read reads.
func TestASheetIsWhatTheAccountReads(t *testing.T) {
	f := newFixture(t)
	a := f.user("A")
	f.flushHands("sheet", game.HandStats{UserID: a.ID, Bucket: game.StatsTeenPatti, Played: 1, Won: 1, Winnings: 50, HasHeld: true, Held: game.Color})
	sheet, err := db.NewStatsStore(f.d, nil).Sheet(f.ctx, a.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(sheet.Wire(), f.find(a.ID).Stats) {
		t.Fatalf("sheet %+v, account %+v", sheet.Wire(), f.find(a.ID).Stats)
	}
}
