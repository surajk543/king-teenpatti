package db_test

// The ONE_TIME missions (owner, 28 Sep 2026: "One-time missions are permanent
// missions that a player can complete only once … The system should now
// support DAILY and ONE_TIME. Do not remove or modify the existing DAILY
// behavior"; db/levels.go, V1.0.0's PLAYER LEVELS): the owner's twelve as
// seeded, progress and completion through the hand-end settle, the XP given
// once whatever replays, retries, concurrent settles or restarts ask again,
// the daily XP earning beside them exactly as it does alone, and a database
// from before them brought forward by one boot.

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// seat is one player's part in a hand a mission test settles: whether they
// win it, and whether they PLAYED it (a voluntary bet — SettleEntry.DidChaal).
type seat struct {
	user   *db.User
	won    bool
	played bool
}

// settleAt settles one hand at a table of category through ledger — every seat
// an outcome row of a player still at the table — with the variation it was
// played under ("" for none), and returns what the ledger told OnSettled.
func (f *fixture) settleAt(ledger *db.Ledger, category game.Category, variation game.Variation, seats ...seat) db.SettledHand {
	f.t.Helper()
	hand := "mission-hand-" + randomSuffix(f.t)
	req, heard := f.missionRequest(hand, category, variation, seats...), &settledHands{}
	ledger.OnSettled(heard.hook)
	defer ledger.OnSettled(nil)
	if _, err := ledger.Settle(f.ctx, req); err != nil {
		f.t.Fatalf("settle a %s hand: %v", category, err)
	}
	hands := heard.all()
	if len(hands) != 1 {
		f.t.Fatalf("OnSettled heard %d settlements, want 1", len(hands))
	}
	return hands[0]
}

// missionRequest is the settle request of one hand: the pot is 100 a seat,
// won by the winners, poker rows tagged as a poker room tags them, and — at a
// variation table — the variation on every player's counters, as the table
// computes them (game.Table.handStats).
func (f *fixture) missionRequest(hand string, category game.Category, variation game.Variation, seats ...seat) game.SettleRequest {
	f.t.Helper()
	pot := int64(100 * len(seats))
	winners := 0
	for _, s := range seats {
		if s.won {
			winners++
		}
	}
	req := game.SettleRequest{RoomID: "mission-room", HandID: hand, PlayedMs: 30_000, Category: category}
	for _, s := range seats {
		delta := int64(-100)
		if s.won {
			delta = pot/int64(winners) - 100
		}
		entry := settleEntry(hand, s.user.ID, delta, s.won, s.played, pot/int64(max(winners, 1)))
		if category.IsPoker() {
			entry.Game, entry.Variant = game.GamePoker, category
		}
		req.Entries = append(req.Entries, entry)
		if variation != "" {
			req.Stats = append(req.Stats, game.HandStats{UserID: s.user.ID, Bucket: game.StatsVariation,
				Played: 1, Variation: variation, VariationWon: s.won})
		}
	}
	return req
}

// mission is where userID stands on one mission as their account reads it —
// the zero value with Target 0 when they have not moved it.
func (f *fixture) mission(userID, code string) db.MissionProgress {
	f.t.Helper()
	for _, m := range f.find(userID).PlayerLevel.Missions {
		if m.Code == code {
			return m
		}
	}
	return db.MissionProgress{}
}

// completedMissions is the codes of every mission userID has completed, in
// the missions' order.
func (f *fixture) completedMissions(userID string) string {
	f.t.Helper()
	var done []string
	for _, m := range f.find(userID).PlayerLevel.Missions {
		if m.Completed {
			done = append(done, m.Code)
		}
	}
	return strings.Join(done, ",")
}

// xpOf is a player's lifetime XP as their account reads it.
func (f *fixture) xpOf(userID string) int64 {
	f.t.Helper()
	return f.find(userID).PlayerLevel.XP
}

// onlyMissions leaves active the one-time missions named and no other, so a
// test's totals are the XP it means to check (the daily sources stay on).
func (f *fixture) onlyMissions(codes ...string) {
	f.t.Helper()
	quoted := make([]string, len(codes))
	for i, c := range codes {
		quoted[i] = "'" + c + "'"
	}
	keep := "''"
	if len(quoted) > 0 {
		keep = strings.Join(quoted, ", ")
	}
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE xp_sources SET is_active = (code IN (`+keep+`)) WHERE mission_type = 'ONE_TIME'`); err != nil {
		f.t.Fatal(err)
	}
}

// ownersMissions is the owner's twelve (28 Sep 2026), exactly: code, title,
// kind, target, scope and XP, in their order — the XP a tenth of the first
// figures (owner, the same day: "reduce the XP Granted value").
var ownersMissions = []string{
	"FIRST_HAND|First Hand|HANDS_PLAYED|1||5",
	"FIRST_WIN|First Win|HANDS_WON|1||10",
	"GETTING_STARTED|Getting Started|HANDS_PLAYED|10||15",
	"FIRST_5_WINS|First 5 Wins|HANDS_WON|5||30",
	"CARD_PLAYER|Card Player|HANDS_PLAYED|50||50",
	"WINNING_STREAK|Winning Streak|HANDS_WON|10||75",
	"FIRST_POKER_HAND|First Poker Hand|HANDS_PLAYED|1|poker|10",
	"FIRST_POKER_WIN|First Poker Win|HANDS_WON|1|poker|20",
	"TEXAS_HOLDEM_DEBUT|Texas Hold'em Debut|HANDS_PLAYED|1|texas_holdem|15",
	"POKER_REGULAR|Poker Regular|HANDS_PLAYED|50|poker|75",
	"VARIATION_EXPLORER|Variation Explorer|HANDS_PLAYED|1|variation|10",
	"GAME_EXPLORER|Game Explorer|CATEGORIES_PLAYED|5||50",
}

// TestTheSeededOneTimeMissionsAreTheOwnersTwelve: a fresh database holds the
// owner's twelve missions, every one ONE_TIME, active and with its icon, after
// the eight daily sources — which stay DAILY — and nobody's progress.
func TestTheSeededOneTimeMissionsAreTheOwnersTwelve(t *testing.T) {
	f := newFixture(t)
	rows, err := f.d.Pool.Query(f.ctx, `SELECT code, name, kind, target, COALESCE(scope, ''), xp, icon <> '', is_active
	     FROM xp_sources WHERE mission_type = 'ONE_TIME' ORDER BY sort_order`)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	var total int
	for rows.Next() {
		var code, name, kind, scope string
		var target, xp int
		var icon, active bool
		if err := rows.Scan(&code, &name, &kind, &target, &scope, &xp, &icon, &active); err != nil {
			t.Fatal(err)
		}
		if !icon || !active {
			t.Errorf("%s: icon %v, active %v — every mission has its mark and is on", code, icon, active)
		}
		total += xp
		got = append(got, fmt.Sprintf("%s|%s|%s|%d|%s|%d", code, name, kind, target, scope, xp))
	}
	rows.Close()
	if strings.Join(got, "\n") != strings.Join(ownersMissions, "\n") {
		t.Errorf("the one-time missions:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(ownersMissions, "\n"))
	}
	if total != 365 {
		t.Errorf("the missions give %d XP in all, want 365", total)
	}
	if n := f.count(`SELECT count(*) FROM xp_sources WHERE mission_type = 'DAILY'`); n != 8 {
		t.Errorf("%d daily sources, want the eight", n)
	}
	if n := f.count(`SELECT count(*) FROM xp_sources WHERE mission_type = 'ONE_TIME' AND sort_order <= 80`); n != 0 {
		t.Error("the missions come after the daily sources")
	}
	if n := f.count(`SELECT count(*) FROM player_xp_missions`); n != 0 {
		t.Error("the seed moves nobody's missions")
	}
}

// TestAOneTimeMissionMovesOnAndCompletesOnce is the mission's life: partial
// progress shown as it grows, completion when the target is reached — its XP
// added once, to lifetime XP alone — and nothing after it: the next hands
// move it no further and give it nothing again, and neither does a new window
// 24 hours on, a week on, a new login or a restart.
func TestAOneTimeMissionMovesOnAndCompletesOnce(t *testing.T) {
	f := newFixture(t)
	f.onlyMissions("GETTING_STARTED")
	clock := &testClock{now: time.UnixMilli(1_800_000_000_000)}
	ledger := db.NewLedger(f.d, nil, clock.Now)
	users := db.NewUsers(f.d, welcome, clock.Now)
	f.users = users
	profile := db.Profile{Provider: db.ProviderGuest, ProviderUserID: "missions-" + randomSuffix(t), DisplayName: "Starter"}
	a, _, err := users.UpsertFromProfile(f.ctx, profile)
	if err != nil {
		t.Fatal(err)
	}
	b := f.user("Opponent")

	// A player who has played nothing reads no progress at all.
	if got := f.find(a.ID).PlayerLevel.Missions; got != nil {
		t.Fatalf("before any hand: %+v, want none", got)
	}
	// Seven hands played — the loser's side, so no daily "Win by …" either:
	// 7 of 10, not completed, no XP.
	for i := 1; i <= 7; i++ {
		h := f.settleAt(ledger, game.CategorySeen, "", seat{user: b, won: true}, seat{user: a, played: true})
		if _, told := h.Levels[a.ID]; !told {
			t.Fatalf("hand %d moved the mission on but player:level was not sent", i)
		}
	}
	if got := f.mission(a.ID, "GETTING_STARTED"); got != (db.MissionProgress{Code: "GETTING_STARTED", Type: db.MissionOneTime, Progress: 7, Target: 10}) {
		t.Fatalf("after seven hands: %+v, want 7 of 10 and not completed", got)
	}
	if xp := f.xpOf(a.ID); xp != 0 {
		t.Fatalf("partial progress gave %d XP", xp)
	}
	if raw, _ := json.Marshal(f.find(a.ID).PlayerLevel); !strings.Contains(string(raw),
		`"missions":[{"code":"GETTING_STARTED","type":"ONE_TIME","progress":7,"target":10,"completed":false}]`) {
		t.Errorf("the wire: %s", raw)
	}

	// The tenth completes it: 15 XP, lifetime only — the window's XP is the
	// daily sources' alone.
	for i := 8; i <= 10; i++ {
		clock.Advance(time.Minute)
		f.settleAt(ledger, game.CategorySeen, "", seat{user: b, won: true}, seat{user: a, played: true})
	}
	completedAt := clock.Now().UnixMilli()
	want := db.MissionProgress{Code: "GETTING_STARTED", Type: db.MissionOneTime, Progress: 10, Target: 10,
		Completed: true, CompletedAt: completedAt, XPAwarded: 15}
	if got := f.mission(a.ID, "GETTING_STARTED"); got != want {
		t.Fatalf("after ten hands: %+v, want %+v", got, want)
	}
	if xp := f.xpOf(a.ID); xp != 15 {
		t.Fatalf("the completion gave %d XP, want 15", xp)
	}
	if n := f.count(`SELECT window_xp FROM player_xp WHERE user_id = $1`, a.ID); n != 0 {
		t.Errorf("the window counted %d XP of a one-time mission", n)
	}
	if raw, _ := json.Marshal(f.mission(a.ID, "GETTING_STARTED")); strings.Contains(string(raw), "resets") || strings.Contains(string(raw), "expires") {
		t.Errorf("a one-time mission carries a reset: %s", raw)
	}

	// More hands: nothing moves, nothing is given again.
	for i := 0; i < 3; i++ {
		h := f.settleAt(ledger, game.CategorySeen, "", seat{user: b, won: true}, seat{user: a, played: true})
		if _, told := h.Levels[a.ID]; told {
			t.Error("a hand that changed nothing of theirs was pushed")
		}
	}
	// 24 hours on the daily window has rolled; a week on, again. The mission
	// is as it was — completed, 10 of 10, at the same instant — and its XP is
	// not given again.
	for _, wait := range []time.Duration{24 * time.Hour, 7 * 24 * time.Hour} {
		clock.Advance(wait)
		if got := f.find(a.ID).PlayerLevel; got.Daily != nil {
			t.Fatalf("the daily window should have run out: %+v", got.Daily)
		}
		if got := f.mission(a.ID, "GETTING_STARTED"); got != want {
			t.Fatalf("%v on, before a hand: %+v, want %+v", wait, got, want)
		}
		f.settleAt(ledger, game.CategorySeen, "", seat{user: b, won: true}, seat{user: a, played: true})
		if got := f.mission(a.ID, "GETTING_STARTED"); got != want || f.xpOf(a.ID) != 15 {
			t.Fatalf("%v on, after a hand: %+v and %d XP, want it untouched at 15", wait, got, f.xpOf(a.ID))
		}
	}
	// Signing out and in again changes nothing of it (a login is the same
	// account read), and nor does a restart: every migration runs again, the
	// seed's ON CONFLICT DO NOTHING leaves the source as it is.
	again, isNew, err := users.UpsertFromProfile(f.ctx, profile)
	if err != nil || isNew || again.ID != a.ID {
		t.Fatalf("the second login: %v %v %v", again, isNew, err)
	}
	if got := f.mission(again.ID, "GETTING_STARTED"); got != want {
		t.Fatalf("after a new login: %+v", got)
	}
	reboot(t, f.d)
	if got := f.mission(a.ID, "GETTING_STARTED"); got != want || f.xpOf(a.ID) != 15 {
		t.Fatalf("after a restart: %+v and %d XP", got, f.xpOf(a.ID))
	}
	f.settleAt(ledger, game.CategorySeen, "", seat{user: b, won: true}, seat{user: a, played: true})
	if f.xpOf(a.ID) != 15 || f.count(`SELECT count(*) FROM player_xp_missions WHERE user_id = $1`, a.ID) != 1 {
		t.Fatal("a hand after the restart gave the mission again")
	}
}

// TestAReplayedSettleAwardsAMissionOnce: the same hand settled twice — a retry
// whose first commit's acknowledgement was lost — is refused duplicate_action
// on its ledger rows, and its rollback takes the mission progress and the XP
// with it: the mission moved once, and was given once.
func TestAReplayedSettleAwardsAMissionOnce(t *testing.T) {
	f := newFixture(t)
	f.onlyMissions("FIRST_HAND", "FIRST_WIN", "GETTING_STARTED")
	a, b := f.user("Replayed"), f.user("Other")
	req := f.missionRequest("replay-"+randomSuffix(t), game.CategoryBlind, "", seat{user: a, won: true, played: true}, seat{user: b, played: true})
	if _, err := f.ledger.Settle(f.ctx, req); err != nil {
		t.Fatal(err)
	}
	wantA := f.xpOf(a.ID)
	if f.completedMissions(a.ID) != "FIRST_HAND,FIRST_WIN" || f.completedMissions(b.ID) != "FIRST_HAND" {
		t.Fatalf("the first settle completed %q and %q", f.completedMissions(a.ID), f.completedMissions(b.ID))
	}
	for i := 0; i < 3; i++ {
		if _, err := f.ledger.Settle(f.ctx, req); codeOf(t, err) != game.CodeDuplicateAction {
			t.Fatalf("replay %d: %v, want duplicate_action", i, err)
		}
	}
	if f.xpOf(a.ID) != wantA || f.xpOf(b.ID) != 5 {
		t.Fatalf("after the replays: %d and %d XP, want %d and 5", f.xpOf(a.ID), f.xpOf(b.ID), wantA)
	}
	if got := f.mission(a.ID, "GETTING_STARTED"); got.Progress != 1 {
		t.Fatalf("the replays moved Getting Started to %d", got.Progress)
	}
	if n := f.count(`SELECT count(*) FROM player_xp_missions WHERE completed_at > 0`); n != 3 {
		t.Fatalf("%d completions, want the three of the first settle", n)
	}
	f.reconcile()
}

// TestConcurrentSettlesCompleteAMissionOnce: eight hands settled at once for
// one player — through two separate pools, as two server processes would —
// each of which alone would complete First Hand: one completes it, the others
// find it completed, and its 5 XP is given exactly once. The same hand
// settled from both pools at once lands once and is duplicate_action on the
// other.
func TestConcurrentSettlesCompleteAMissionOnce(t *testing.T) {
	f := newFixture(t)
	f.onlyMissions("FIRST_HAND", "GETTING_STARTED")
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	second, err := db.Open(ctx, db.Options{URL: testURL(), Schema: f.d.Schema, PoolMax: 4, SkipMigrations: true})
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	ledgers := []*db.Ledger{f.ledger, db.NewLedger(second, nil, nil)}

	a := f.user("Racer")
	opponents := make([]*db.User, 8)
	for i := range opponents {
		opponents[i] = f.user(fmt.Sprintf("Rival%d", i))
	}
	var wg sync.WaitGroup
	start := make(chan struct{})
	errs := make(chan error, len(opponents))
	for i, o := range opponents {
		req := f.missionRequest(fmt.Sprintf("race-%d-%s", i, randomSuffix(t)), game.CategorySeen, "",
			seat{user: o, won: true}, seat{user: a, played: true})
		wg.Add(1)
		go func(l *db.Ledger, req game.SettleRequest) {
			defer wg.Done()
			<-start
			if _, err := l.Settle(context.Background(), req); err != nil {
				errs <- err
			}
		}(ledgers[i%2], req)
	}
	close(start)
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatalf("a concurrent settle failed: %v", err)
	}
	if xp := f.xpOf(a.ID); xp != 5 {
		t.Fatalf("eight concurrent first hands gave %d XP, want First Hand's 5 once", xp)
	}
	if n := f.count(`SELECT count(*) FROM player_xp_missions WHERE user_id = $1 AND source_code = 'FIRST_HAND' AND completed_at > 0 AND xp_awarded = 5`, a.ID); n != 1 {
		t.Fatalf("%d completions of First Hand", n)
	}
	// Every hand counted once for the mission still open: 8 of 10.
	if got := f.mission(a.ID, "GETTING_STARTED"); got.Progress != 8 || got.Completed {
		t.Fatalf("Getting Started after eight concurrent hands: %+v", got)
	}

	// One hand from both pools at the same moment: one lands, the other is a
	// replay — and the mission it would complete is completed once.
	c, d := f.user("Twin"), f.user("Twin2")
	req := f.missionRequest("twin-"+randomSuffix(t), game.CategorySeen, "", seat{user: c, won: true, played: true}, seat{user: d, played: true})
	results := make(chan error, 2)
	start = make(chan struct{})
	for _, l := range ledgers {
		go func(l *db.Ledger) {
			<-start
			_, err := l.Settle(context.Background(), req)
			results <- err
		}(l)
	}
	close(start)
	var landed, duplicates int
	for range ledgers {
		switch err := <-results; {
		case err == nil:
			landed++
		case game.CodeOf(err, "") == game.CodeDuplicateAction:
			duplicates++
		default:
			t.Fatalf("the twin settle: %v", err)
		}
	}
	if landed != 1 || duplicates != 1 || f.xpOf(c.ID) != 5 || f.xpOf(d.ID) != 5 {
		t.Fatalf("the twin settle: %d landed, %d duplicates, XP %d and %d", landed, duplicates, f.xpOf(c.ID), f.xpOf(d.ID))
	}
	f.reconcile()
}

// TestTheDailyXPEarnsBesideTheMissionsExactlyAsAlone: with every mission on,
// the daily sources earn exactly what they earn alone — each once a window,
// the same claims, the same window XP and the same reset — and the lifetime
// XP is the daily XP plus the missions' XP, a player's XP from before any of
// it included; a new window 24 hours on brings the daily sources back and no
// mission. An owner's daily cap counts and limits the daily XP only.
func TestTheDailyXPEarnsBesideTheMissionsExactlyAsAlone(t *testing.T) {
	f := newFixture(t)
	clock := &testClock{now: time.UnixMilli(1_800_000_000_000)}
	ledger := db.NewLedger(f.d, nil, clock.Now)
	f.users = db.NewUsers(f.d, welcome, clock.Now)
	a, b := f.user("Both"), f.user("Other")
	f.setXP(a.ID, 5000) // a player of Level 10 before any of it
	opened := clock.Now().UnixMilli()
	// win settles a hand a wins, played, holding hand ("" names none).
	win := func(hand string) {
		t.Helper()
		req := f.missionRequest("both-"+randomSuffix(t), game.CategorySeen, "", seat{user: a, won: true, played: true}, seat{user: b, played: true})
		req.Entries[0].WonWith = hand
		if _, err := ledger.Settle(f.ctx, req); err != nil {
			t.Fatal(err)
		}
	}

	// A pair won and played: the daily WIN_PAIR (+1) as ever, and First Hand
	// (+5) and First Win (+10) beside it.
	win("PAIR")
	lvl := f.find(a.ID).PlayerLevel
	if lvl.XP != 5000+1+5+10 || lvl.Daily == nil || !reflect.DeepEqual(lvl.Daily.Claimed, map[string]int{"WIN_PAIR": 1}) ||
		lvl.Daily.ResetsAt != opened+86_400_000 {
		t.Fatalf("the daily pair beside the missions: %d XP, daily %+v, want 5,016 and WIN_PAIR once", lvl.XP, lvl.Daily)
	}
	if n := f.count(`SELECT window_xp FROM player_xp WHERE user_id = $1`, a.ID); n != 1 {
		t.Fatalf("the window's XP is %d, want the pair's 1 alone", n)
	}
	if f.completedMissions(a.ID) != "FIRST_HAND,FIRST_WIN" {
		t.Fatalf("completed: %s", f.completedMissions(a.ID))
	}
	// A second pair in the window: nothing daily (once a window), nothing
	// one-time (First Win is done); First 5 Wins moves on.
	win("PAIR")
	if xp := f.xpOf(a.ID); xp != 5016 {
		t.Fatalf("a second pair: %d XP, want 5,016", xp)
	}
	if got := f.mission(a.ID, "FIRST_5_WINS"); got.Progress != 2 || got.Completed {
		t.Fatalf("First 5 Wins: %+v", got)
	}

	// 24 hours on: a new window, and the pair is there to be earned again;
	// the missions are not reset.
	clock.Advance(24 * time.Hour)
	win("PAIR")
	lvl = f.find(a.ID).PlayerLevel
	if lvl.XP != 5017 || !reflect.DeepEqual(lvl.Daily.Claimed, map[string]int{"WIN_PAIR": 1}) || lvl.Daily.ResetsAt != clock.Now().UnixMilli()+86_400_000 {
		t.Fatalf("a new window: %d XP, daily %+v", lvl.XP, lvl.Daily)
	}
	if f.completedMissions(a.ID) != "FIRST_HAND,FIRST_WIN" || f.mission(a.ID, "FIRST_5_WINS").Progress != 3 {
		t.Fatalf("after the reset: completed %s, First 5 Wins %+v", f.completedMissions(a.ID), f.mission(a.ID, "FIRST_5_WINS"))
	}

	// An owner's cap limits the daily XP and never a mission's: with a cap of
	// 1, already reached by the pair, the fifth win completes First 5 Wins'
	// 30 in full, a trail gives nothing today, and the window's XP stays
	// the pair's 1.
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE xp_settings SET daily_cap = 1`); err != nil {
		t.Fatal(err)
	}
	win("")
	win("TRAIL")
	lvl = f.find(a.ID).PlayerLevel
	if lvl.XP != 5017+30 || lvl.Today == nil || lvl.Today.XP != 1 || lvl.Today.Cap != 1 || lvl.Daily.Claimed["WIN_TRAIL"] != 0 {
		t.Fatalf("a capped window: %d XP, today %+v, daily %+v, want First 5 Wins' 30 past a cap of 1", lvl.XP, lvl.Today, lvl.Daily)
	}
	if got := f.mission(a.ID, "FIRST_5_WINS"); !got.Completed || got.XPAwarded != 30 {
		t.Fatalf("First 5 Wins: %+v", got)
	}
}

// TestPokerMissionsCountOnlyTheirGames: a Teen Patti or Variation hand moves
// no Poker mission; any poker hand moves First Poker Hand, First Poker Win and
// Poker Regular; only a Texas Hold'em hand completes Texas Hold'em Debut; and
// the general missions count every game.
func TestPokerMissionsCountOnlyTheirGames(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("Poker"), f.user("Other")
	pokerCodes := []string{"FIRST_POKER_HAND", "FIRST_POKER_WIN", "TEXAS_HOLDEM_DEBUT", "POKER_REGULAR"}
	for _, c := range []game.Category{game.CategorySeen, game.CategoryBlind, game.CategoryVariation} {
		f.settleAt(f.ledger, c, "", seat{user: a, won: true, played: true}, seat{user: b, played: true})
	}
	for _, code := range pokerCodes {
		if got := f.mission(a.ID, code); got.Progress != 0 {
			t.Fatalf("a Teen Patti hand moved %s: %+v", code, got)
		}
	}
	if got := f.mission(a.ID, "GETTING_STARTED"); got.Progress != 3 {
		t.Fatalf("Getting Started counts every game: %+v", got)
	}
	// Omaha: the poker missions but not the Texas one; a loss moves no win.
	f.settleAt(f.ledger, game.CategoryOmaha, "", seat{user: b, won: true, played: true}, seat{user: a, played: true})
	if got := f.completedMissions(a.ID); !strings.Contains(got, "FIRST_POKER_HAND") || strings.Contains(got, "FIRST_POKER_WIN") ||
		strings.Contains(got, "TEXAS_HOLDEM_DEBUT") {
		t.Fatalf("after an Omaha loss: %s", got)
	}
	if got := f.mission(a.ID, "POKER_REGULAR"); got.Progress != 1 || got.Target != 50 {
		t.Fatalf("Poker Regular: %+v", got)
	}
	// 3-Card Poker against the house: a win moves First Poker Win, and it is
	// not Texas Hold'em either.
	f.settleAt(f.ledger, game.CategoryThreeCardPoker, "", seat{user: a, won: true, played: true})
	if got := f.completedMissions(a.ID); !strings.Contains(got, "FIRST_POKER_WIN") || strings.Contains(got, "TEXAS_HOLDEM_DEBUT") {
		t.Fatalf("after a 3-Card Poker win: %s", got)
	}
	// Texas Hold'em: the debut, once.
	before := f.xpOf(a.ID)
	f.settleAt(f.ledger, game.CategoryTexasHoldem, "", seat{user: b, won: true, played: true}, seat{user: a, played: true})
	if got := f.mission(a.ID, "TEXAS_HOLDEM_DEBUT"); !got.Completed || got.XPAwarded != 15 || f.xpOf(a.ID) != before+15 {
		t.Fatalf("Texas Hold'em Debut: %+v, XP %d → %d", got, before, f.xpOf(a.ID))
	}
	// A poker hand the player did not play (folded before any voluntary bet)
	// moves no "played" mission.
	c := f.user("Folder")
	f.settleAt(f.ledger, game.CategoryTexasHoldem, "", seat{user: b, won: true, played: true}, seat{user: c})
	if got := f.find(c.ID).PlayerLevel.Missions; got != nil {
		t.Fatalf("a hand not played moved %+v", got)
	}
	// A push at 3-Card Poker is no win.
	pushed := f.user("Pushed")
	hand := "push-" + randomSuffix(t)
	entry := settleEntry(hand, pushed.ID, 0, false, true, 0)
	entry.Push, entry.Game, entry.Variant = true, game.GamePoker, game.CategoryThreeCardPoker
	if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: "r", HandID: hand, Category: game.CategoryThreeCardPoker, Entries: []game.SettleEntry{entry}}); err != nil {
		t.Fatal(err)
	}
	if got := f.completedMissions(pushed.ID); got != "FIRST_HAND,FIRST_POKER_HAND" {
		t.Fatalf("a push: %s, want played and not won", got)
	}
}

// TestExplorerMissionsCountDifferentGames: Game Explorer counts the DIFFERENT
// table categories a player has played at — hands at one category over and
// over count once — and completes at the fifth; Variation Explorer is a hand
// played at a Variation table; switched by one UPDATE to count variations,
// it counts different variations instead.
func TestExplorerMissionsCountDifferentGames(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("Explorer"), f.user("Other")
	for i := 0; i < 3; i++ {
		f.settleAt(f.ledger, game.CategorySeen, "", seat{user: a, played: true}, seat{user: b, won: true, played: true})
	}
	if got := f.mission(a.ID, "GAME_EXPLORER"); got.Progress != 1 || got.Target != 5 {
		t.Fatalf("three Seen hands: %+v, want 1 of 5", got)
	}
	// A hand not played (no voluntary bet) is not a game played.
	f.settleAt(f.ledger, game.CategoryBlind, "", seat{user: a}, seat{user: b, won: true, played: true})
	if got := f.mission(a.ID, "GAME_EXPLORER"); got.Progress != 1 {
		t.Fatalf("a Blind hand not played: %+v", got)
	}
	f.settleAt(f.ledger, game.CategoryBlind, "", seat{user: a, played: true}, seat{user: b, won: true, played: true})
	f.settleAt(f.ledger, game.CategoryBlind, "", seat{user: a, played: true}, seat{user: b, won: true, played: true})
	f.settleAt(f.ledger, game.CategoryVariation, game.VariationMuflis, seat{user: a, played: true}, seat{user: b, won: true, played: true})
	if got := f.mission(a.ID, "GAME_EXPLORER"); got.Progress != 3 || got.Completed {
		t.Fatalf("Seen, Blind, Variation: %+v, want 3 of 5", got)
	}
	if got := f.mission(a.ID, "VARIATION_EXPLORER"); !got.Completed || got.XPAwarded != 10 {
		t.Fatalf("Variation Explorer after a Variation hand: %+v", got)
	}
	f.settleAt(f.ledger, game.CategoryOmaha, "", seat{user: a, played: true}, seat{user: b, won: true, played: true})
	f.settleAt(f.ledger, game.CategoryOmaha, "", seat{user: a, played: true}, seat{user: b, won: true, played: true})
	if got := f.mission(a.ID, "GAME_EXPLORER"); got.Progress != 4 || got.Completed {
		t.Fatalf("and Omaha twice: %+v, want 4 of 5", got)
	}
	before := f.xpOf(a.ID)
	f.settleAt(f.ledger, game.CategoryFiveCardDraw, "", seat{user: a, played: true}, seat{user: b, won: true, played: true})
	got := f.mission(a.ID, "GAME_EXPLORER")
	if !got.Completed || got.Progress != 5 || got.XPAwarded != 50 {
		t.Fatalf("the fifth game: %+v", got)
	}
	// First Poker Hand came with the first Omaha hand, and Getting Started
	// is at 9 of 10: this hand gave Game Explorer's 50 alone.
	if f.xpOf(a.ID) != before+50 {
		t.Fatalf("the fifth game gave %d XP, want Game Explorer's 50", f.xpOf(a.ID)-before)
	}
	var seen []string
	if err := f.d.Pool.QueryRow(f.ctx, `SELECT seen FROM player_xp_missions WHERE user_id = $1 AND source_code = 'GAME_EXPLORER'`, a.ID).Scan(&seen); err != nil {
		t.Fatal(err)
	}
	if strings.Join(seen, ",") != "seen,blind,variation,omaha,five_card_draw" {
		t.Errorf("the games counted: %v", seen)
	}

	// The other reading of Variation Explorer (the variations, not the
	// table): one UPDATE, and a Variation hand under a variation already
	// counted moves it no further.
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE xp_sources SET kind = 'VARIATIONS_PLAYED', scope = NULL, target = 2 WHERE code = 'VARIATION_EXPLORER'`); err != nil {
		t.Fatal(err)
	}
	c := f.user("Variations")
	f.settleAt(f.ledger, game.CategoryVariation, game.VariationMuflis, seat{user: c, played: true}, seat{user: b, won: true, played: true})
	f.settleAt(f.ledger, game.CategoryVariation, game.VariationMuflis, seat{user: c, played: true}, seat{user: b, won: true, played: true})
	if got := f.mission(c.ID, "VARIATION_EXPLORER"); got.Progress != 1 || got.Completed {
		t.Fatalf("two Muflis hands: %+v, want 1 of 2", got)
	}
	f.settleAt(f.ledger, game.CategoryVariation, game.VariationAK47, seat{user: c, played: true}, seat{user: b, won: true, played: true})
	if got := f.mission(c.ID, "VARIATION_EXPLORER"); !got.Completed || got.Progress != 2 {
		t.Fatalf("Muflis then AK47: %+v, want completed", got)
	}
	// A player who had completed it under the old reading keeps it.
	if got := f.mission(a.ID, "VARIATION_EXPLORER"); !got.Completed {
		t.Fatalf("the old completion: %+v", got)
	}
}

// TestALeaverAndAMoneyOnlyRowMoveNoMission: only a hand a player COMPLETED
// counts — the daily window's rule — so a leaver's row and a money-only
// catch-up move nothing; and with XP switched off (no settings row) nothing
// moves at all.
func TestALeaverAndAMoneyOnlyRowMoveNoMission(t *testing.T) {
	f := newFixture(t)
	win, leaver, money := f.user("Stayed"), f.user("Left"), f.user("Money")
	hand := "leave-" + randomSuffix(t)
	gone := settleEntry(hand, leaver.ID, -100, false, true, 0)
	gone.LeftMidHand = true
	moneyOnly := game.SettleEntry{UserID: money.ID, Delta: -50, ActionID: game.SettleActionID(hand, money.ID), Reason: game.LedgerReasonHandLoss, DidChaal: true}
	if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: "r", HandID: hand, Category: game.CategorySeen, Entries: []game.SettleEntry{
		settleEntry(hand, win.ID, 150, true, true, 200), gone, moneyOnly,
	}}); err != nil {
		t.Fatal(err)
	}
	for _, u := range []*db.User{leaver, money} {
		if got := f.find(u.ID).PlayerLevel; got.Missions != nil || got.XP != 0 {
			t.Errorf("%s: %+v", u.DisplayName, got)
		}
	}
	if got := f.completedMissions(win.ID); got != "FIRST_HAND,FIRST_WIN" {
		t.Errorf("the winner: %s", got)
	}
	if _, err := f.d.Pool.Exec(f.ctx, `DELETE FROM xp_settings`); err != nil {
		t.Fatal(err)
	}
	other := f.user("Off")
	f.settleAt(f.ledger, game.CategorySeen, "", seat{user: other, won: true, played: true}, seat{user: win, played: true})
	if n := f.count(`SELECT count(*) FROM player_xp_missions WHERE user_id = $1`, other.ID); n != 0 {
		t.Error("with XP off a settle moves no mission")
	}
}

// TestAMissionOffOrMisconfiguredEarnsNothing: a mission switched off is
// neither moved nor offered; one with no target, an unknown scope or a kind
// this build does not know is left out; a DAILY source of a one-time kind
// earns nothing daily; and an owner's lowered target completes a mission at
// its next counted hand.
func TestAMissionOffOrMisconfiguredEarnsNothing(t *testing.T) {
	f := newFixture(t)
	f.onlyMissions("CARD_PLAYER")
	if _, err := f.d.Pool.Exec(f.ctx, `INSERT INTO xp_sources (code, name, kind, mission_type, target, scope, xp, is_active, sort_order) VALUES
	     ('NO_TARGET', 'x', 'HANDS_PLAYED', 'ONE_TIME', NULL, NULL, 99, TRUE, 300),
	     ('MOON', 'x', 'MOON_PHASE', 'ONE_TIME', 1, NULL, 99, TRUE, 301),
	     ('CHESS', 'x', 'HANDS_PLAYED', 'ONE_TIME', 1, 'chess', 99, TRUE, 302),
	     ('DAILY_HANDS', 'x', 'HANDS_PLAYED', 'DAILY', 1, NULL, 99, TRUE, 303)`); err != nil {
		t.Fatal(err)
	}
	a, b := f.user("Misconfigured"), f.user("Other")
	f.settleAt(f.ledger, game.CategorySeen, "", seat{user: a, played: true}, seat{user: b, won: true, played: true})
	if xp := f.xpOf(a.ID); xp != 0 {
		t.Fatalf("a misconfigured source gave %d XP", xp)
	}
	if got := f.find(a.ID).PlayerLevel.Missions; len(got) != 1 || got[0].Code != "CARD_PLAYER" || got[0].Progress != 1 {
		t.Fatalf("progress: %+v, want Card Player alone", got)
	}
	ladder, err := db.NewXP(f.d, nil).Ladder(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	var codes []string
	for _, m := range ladder.Missions {
		codes = append(codes, m.Code)
	}
	// Offered: every active ONE_TIME row with a target (the app names a kind
	// it does not know by its title); never the one with none.
	if strings.Join(codes, ",") != "CARD_PLAYER,MOON,CHESS" {
		t.Errorf("the ladder offers %v", codes)
	}
	for _, s := range ladder.XPSources {
		if s.Code == "DAILY_HANDS" && (s.Type != db.MissionDaily || s.Target != nil) {
			t.Errorf("a DAILY row of a one-time kind: %+v", s)
		}
	}
	// An owner lowers Card Player's target under the progress: the next hand
	// completes it.
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE xp_sources SET target = 2 WHERE code = 'CARD_PLAYER'`); err != nil {
		t.Fatal(err)
	}
	f.settleAt(f.ledger, game.CategorySeen, "", seat{user: a, played: true}, seat{user: b, won: true, played: true})
	if got := f.mission(a.ID, "CARD_PLAYER"); !got.Completed || got.Target != 2 || f.xpOf(a.ID) != 50 {
		t.Fatalf("a lowered target: %+v, %d XP", got, f.xpOf(a.ID))
	}
	// Switched off: no longer on the account (nor the ladder), and moved no
	// further — but the completion and its XP stand.
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE xp_sources SET is_active = FALSE WHERE code = 'CARD_PLAYER'`); err != nil {
		t.Fatal(err)
	}
	if got := f.find(a.ID).PlayerLevel.Missions; got != nil || f.xpOf(a.ID) != 50 {
		t.Fatalf("a mission switched off: %+v, %d XP", got, f.xpOf(a.ID))
	}
	if n := f.count(`SELECT count(*) FROM player_xp_missions WHERE user_id = $1 AND completed_at > 0`, a.ID); n != 1 {
		t.Error("switching a mission off must keep who completed it")
	}
}

// TestTheLadderListsTheMissionsApartFromTheDailySources: GET /api/levels'
// read keeps xpSources the eight daily sources — every one typed DAILY, no
// target, their XP summing to the 108 an older app shows as a window's most —
// and lists the twelve missions beside them, typed ONE_TIME, each with its
// target and scope and no daily reset.
func TestTheLadderListsTheMissionsApartFromTheDailySources(t *testing.T) {
	f := newFixture(t)
	ladder, err := db.NewXP(f.d, nil).Ladder(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	daily := 0
	for _, s := range ladder.XPSources {
		if s.Type != db.MissionDaily || s.Target != nil || s.Scope != "" {
			t.Errorf("a daily source: %+v", s)
		}
		daily += s.XP * s.Times
	}
	if len(ladder.XPSources) != 8 || daily != 108 {
		t.Fatalf("%d daily sources worth %d, want 8 worth 108", len(ladder.XPSources), daily)
	}
	var got []string
	for _, m := range ladder.Missions {
		if m.Type != db.MissionOneTime || m.Target == nil || m.Times != 1 || m.PlayMinutes != nil || m.HandRank != "" || m.Icon == "" {
			t.Errorf("a mission: %+v", m)
		}
		got = append(got, fmt.Sprintf("%s|%s|%s|%d|%s|%d", m.Code, m.Name, m.Kind, *m.Target, m.Scope, m.XP))
	}
	if strings.Join(got, "\n") != strings.Join(ownersMissions, "\n") {
		t.Errorf("the ladder's missions:\n%s", strings.Join(got, "\n"))
	}
	raw, _ := json.Marshal(ladder)
	for _, want := range []string{`"type":"DAILY"`, `"missions":[{"code":"FIRST_HAND","name":"First Hand","icon":"🎴","kind":"HANDS_PLAYED","type":"ONE_TIME","target":1,"xp":5,"times":1}`,
		`"scope":"texas_holdem"`} {
		if !strings.Contains(string(raw), want) {
			t.Errorf("the ladder's JSON lacks %s:\n%s", want, raw)
		}
	}
}

// TestABootBringsTheXPSourcesForwardForMissions is the path production takes
// (TestABootBringsAnOlderDatabaseForward's twin for the one-time missions): a
// database whose xp_sources has the daily sources and none of mission_type,
// target and scope, and no player_xp_missions, with a player's daily XP in it.
// One boot adds the three columns — every existing source DAILY by the
// DEFAULT — creates the table and seeds the twelve; the player's XP and daily
// claims are untouched, the daily XP earns as before, a mission completes; a
// second boot changes nothing.
func TestABootBringsTheXPSourcesForwardForMissions(t *testing.T) {
	older := dbtest.Open(t, "missionsup")
	ctx := context.Background()
	clock := &testClock{now: time.UnixMilli(1_800_000_000_000)}
	users := db.NewUsers(older, welcome, clock.Now)
	mk := func(name string) *db.User {
		u, _, err := users.UpsertFromProfile(ctx, db.Profile{Provider: db.ProviderGuest, ProviderUserID: "up-" + name + "-" + randomSuffix(t), DisplayName: name})
		if err != nil {
			t.Fatal(err)
		}
		return u
	}
	a, b := mk("Before"), mk("Other")
	// The player's XP and daily claim from before the upgrade: a trail won.
	execSQL(t, older, `INSERT INTO player_xp (user_id, xp, window_start, window_xp, created_at, updated_at) VALUES ($1, 20, $2, 20, $2, $2)`,
		a.ID, clock.Now().UnixMilli())
	execSQL(t, older, `INSERT INTO player_xp_claims (user_id, source_code, window_start, claims, updated_at) VALUES ($1, 'WIN_TRAIL', $2, 1, $2)`,
		a.ID, clock.Now().UnixMilli())
	// What such a database looks like: no missions table, no rows of them, no
	// columns for them.
	execSQL(t, older, `DROP TABLE player_xp_missions`)
	execSQL(t, older, `DELETE FROM xp_sources WHERE mission_type = 'ONE_TIME'`)
	execSQL(t, older, `ALTER TABLE xp_sources DROP COLUMN mission_type, DROP COLUMN target, DROP COLUMN scope`)
	column := func(d *db.DB, name string) int64 {
		return countOf(t, d, `SELECT count(*) FROM information_schema.columns WHERE table_schema = $1 AND table_name = 'xp_sources' AND column_name = $2`, d.Schema, name)
	}

	bootCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	d, err := db.Open(bootCtx, db.Options{URL: testURL(), Schema: older.Schema, PoolMax: 2})
	if err != nil {
		t.Fatalf("the boot that brings the database forward: %v", err)
	}
	t.Cleanup(d.Close)
	for _, c := range []string{"mission_type", "target", "scope"} {
		if column(d, c) != 1 {
			t.Errorf("xp_sources.%s is not back", c)
		}
	}
	if n := countOf(t, d, `SELECT count(*) FROM xp_sources WHERE mission_type = 'DAILY' AND code IN
	     ('PLAY_15_MIN', 'PLAY_60_MIN', 'PLAY_120_MIN', 'WIN_PAIR', 'WIN_COLOR', 'WIN_SEQUENCE', 'WIN_PURE_SEQUENCE', 'WIN_TRAIL')`); n != 8 {
		t.Errorf("%d of the daily sources read DAILY after the upgrade, want all 8", n)
	}
	if n := countOf(t, d, `SELECT count(*) FROM xp_sources WHERE mission_type = 'ONE_TIME' AND is_active`); n != 12 {
		t.Errorf("%d missions after the upgrade, want the seed's 12", n)
	}
	// The player's XP and claim are as they were.
	upgraded := db.NewUsers(d, welcome, clock.Now)
	got, err := upgraded.FindByID(ctx, a.ID)
	if err != nil || got.PlayerLevel.XP != 20 || got.PlayerLevel.Daily == nil ||
		!reflect.DeepEqual(got.PlayerLevel.Daily.Claimed, map[string]int{"WIN_TRAIL": 1}) || got.PlayerLevel.Missions != nil {
		t.Fatalf("the player after the upgrade: %+v %v", got, err)
	}
	// A hand after it: Trail again earns nothing (claimed in this window), a
	// pair its 1, and the missions their XP on top.
	ledger := db.NewLedger(d, nil, clock.Now)
	hand := "after-upgrade-" + randomSuffix(t)
	w := settleEntry(hand, a.ID, 100, true, true, 200)
	w.WonWith = "PAIR"
	if _, err := ledger.Settle(ctx, game.SettleRequest{RoomID: "r", HandID: hand, Category: game.CategorySeen, Entries: []game.SettleEntry{
		w, settleEntry(hand, b.ID, -100, false, true, 0),
	}}); err != nil {
		t.Fatalf("a settle after the upgrade: %v", err)
	}
	got, _ = upgraded.FindByID(ctx, a.ID)
	if got.PlayerLevel.XP != 20+1+5+10 || !reflect.DeepEqual(got.PlayerLevel.Daily.Claimed, map[string]int{"WIN_TRAIL": 1, "WIN_PAIR": 1}) {
		t.Fatalf("after a hand: %d XP, claims %+v", got.PlayerLevel.XP, got.PlayerLevel.Daily.Claimed)
	}
	// A second boot is a no-op.
	reboot(t, d)
	if n := countOf(t, d, `SELECT count(*) FROM xp_sources`); n != 20 {
		t.Errorf("%d sources after a second boot, want 20", n)
	}
	if n := countOf(t, d, `SELECT count(*) FROM player_xp_missions WHERE user_id = $1 AND completed_at > 0`, a.ID); n != 2 {
		t.Errorf("%d completions after a second boot, want First Hand and First Win", n)
	}
}
