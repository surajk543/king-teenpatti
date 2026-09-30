package db_test

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// The reward programs (owner, 30 Sep 2026): the login streaks and the
// calendar rewards, weekly and monthly, on one set of tables and one store.
// These run against the owner's four seeded programs (V1.0.1's THE REWARD
// PROGRAMS) on a clock a test moves by hand — 5 Oct 2026 is a Monday — and
// add programs of their own where a test is about a zone, a window or a kind
// of reward.

const (
	weeklyLogin     = "WEEKLY_LOGIN"
	monthlyLogin    = "MONTHLY_LOGIN"
	weeklyCalendar  = "WEEKLY_CALENDAR"
	monthlyCalendar = "MONTHLY_CALENDAR"
)

// set moves the clock to an instant.
func (c *luckyClock) set(t time.Time) {
	c.mu.Lock()
	c.now = t
	c.mu.Unlock()
}

// utcAt is an instant on the hour, UTC.
func utcAt(y int, m time.Month, d, hour int) time.Time {
	return time.Date(y, m, d, hour, 0, 0, 0, time.UTC)
}

// rewardStore is the reward programs on the fixture's schema, on clock.
func (f *fixture) rewardStore(clock func() time.Time) *db.RewardPrograms {
	return db.NewRewardPrograms(f.d, f.users, clock, nil)
}

// onlyPrograms keeps the named programs running and retires every other one,
// so a test's claims are about the programs it names (none: about its own).
func (f *fixture) onlyPrograms(codes ...string) {
	f.t.Helper()
	if codes == nil {
		codes = []string{}
	}
	f.exec(`UPDATE reward_programs SET is_active = (code = ANY($1))`, codes)
}

// program adds a program of the test's own and returns its id.
func (f *fixture) program(code, mode, period, zone string, weekStart int, reset bool) int64 {
	f.t.Helper()
	f.exec(`INSERT INTO reward_programs (code, name, mode, period_type, timezone, week_start_day, reset_on_missed_day, sort_order)
	         VALUES ($1, $1, $2, $3, $4, $5, $6, 100)`, code, mode, period, zone, weekStart, reset)
	return f.scalar(`SELECT id FROM reward_programs WHERE code = $1`, code)
}

// day gives one day of a program its reward.
func (f *fixture) day(programID int64, day int, kind string, value *int64, ref *string) {
	f.t.Helper()
	f.exec(`INSERT INTO reward_program_rewards (program_id, day_number, reward_type, reward_value, reward_ref_id)
	         VALUES ($1, $2, $3, $4, $5)`, programID, day, kind, value, ref)
}

func ref(s string) *string { return &s }

// exampleDays gives a seeded program the brief's example days — the lists
// the seed keeps commented out (owner, 30 Sep 2026: WEEKLY_LOGIN alone is
// seeded with days) — so a test of that mode has rewards to claim.
func (f *fixture) exampleDays(code string) {
	f.t.Helper()
	id := f.scalar(`SELECT id FROM reward_programs WHERE code = $1`, code)
	n := func(v int64) *int64 { return &v }
	clap := f.catalogueID("emojis", "Clapping Hands")
	type row struct {
		day   int
		kind  string
		value *int64
		ref   *string
	}
	var rows []row
	switch code {
	case weeklyCalendar:
		rows = []row{
			{1, db.RewardChips, n(10_000), nil}, {2, db.RewardHammer, n(1), nil}, {3, db.RewardHammer, n(1), nil},
			{4, db.RewardDiamond, n(1), nil}, {5, db.RewardEmoji, nil, clap}, {6, db.RewardChips, n(30_000), nil},
			{7, db.RewardChips, n(50_000), nil},
		}
	case monthlyLogin:
		rows = []row{
			{1, db.RewardChips, n(10_000), nil}, {2, db.RewardHammer, n(1), nil}, {3, db.RewardChips, n(20_000), nil},
			{4, db.RewardDiamond, n(1), nil}, {5, db.RewardChips, n(25_000), nil}, {6, db.RewardHammer, n(1), nil},
			{7, db.RewardChips, n(50_000), nil}, {8, db.RewardChips, n(30_000), nil}, {9, db.RewardHammer, n(2), nil},
			{10, db.RewardDiamond, n(1), nil}, {11, db.RewardChips, n(40_000), nil}, {12, db.RewardHammer, n(2), nil},
			{13, db.RewardChips, n(50_000), nil}, {14, db.RewardDiamond, n(1), nil}, {15, db.RewardEmoji, nil, clap},
			{16, db.RewardChips, n(60_000), nil}, {17, db.RewardHammer, n(2), nil}, {18, db.RewardChips, n(75_000), nil},
			{19, db.RewardDiamond, n(1), nil}, {20, db.RewardChips, n(100_000), nil}, {21, db.RewardHammer, n(3), nil},
			{22, db.RewardDiamond, n(1), nil}, {23, db.RewardChips, n(125_000), nil}, {24, db.RewardHammer, n(3), nil},
			{25, db.RewardProfilePicture, nil, f.catalogueID("profile_pictures", "Lovestruck Cat")},
			{26, db.RewardChips, n(150_000), nil}, {27, db.RewardDiamond, n(2), nil}, {28, db.RewardChips, n(200_000), nil},
			{29, db.RewardHammer, n(5), nil}, {30, db.RewardChips, n(250_000), nil}, {31, db.RewardBadge, nil, ref("ROYAL_KING")},
		}
	case monthlyCalendar:
		rows = []row{
			{1, db.RewardChips, n(10_000), nil}, {2, db.RewardHammer, n(1), nil}, {3, db.RewardChips, n(15_000), nil},
			{4, db.RewardDiamond, n(1), nil}, {5, db.RewardChips, n(20_000), nil}, {6, db.RewardHammer, n(1), nil},
			{7, db.RewardChips, n(25_000), nil}, {8, db.RewardChips, n(30_000), nil}, {9, db.RewardHammer, n(2), nil},
			{10, db.RewardEmoji, nil, clap}, {11, db.RewardChips, n(35_000), nil}, {12, db.RewardDiamond, n(1), nil},
			{13, db.RewardChips, n(40_000), nil}, {14, db.RewardHammer, n(2), nil}, {15, db.RewardChips, n(50_000), nil},
			{16, db.RewardDiamond, n(1), nil}, {17, db.RewardChips, n(60_000), nil}, {18, db.RewardHammer, n(2), nil},
			{19, db.RewardChips, n(75_000), nil}, {20, db.RewardDiamond, n(1), nil}, {21, db.RewardChips, n(100_000), nil},
			{22, db.RewardHammer, n(3), nil}, {23, db.RewardChips, n(125_000), nil}, {24, db.RewardDiamond, n(2), nil},
			{25, db.RewardTablePicture, nil, f.catalogueID("table_pictures", "Lines Background")},
			{26, db.RewardChips, n(150_000), nil}, {27, db.RewardHammer, n(3), nil}, {28, db.RewardChips, n(200_000), nil},
			{29, db.RewardDiamond, n(2), nil}, {30, db.RewardChips, n(250_000), nil}, {31, db.RewardBadge, nil, ref("ROYAL_ACE")},
		}
	}
	for _, r := range rows {
		f.day(id, r.day, r.kind, r.value, r.ref)
	}
}

// catalogueID is a catalogue row's id as reward_ref_id names it.
func (f *fixture) catalogueID(table, name string) *string {
	f.t.Helper()
	return ref(fmt.Sprint(f.scalar(`SELECT id FROM `+table+` WHERE name = $1`, name)))
}

// text runs a query expected to return one string.
func (f *fixture) text(sql string, args ...any) string {
	f.t.Helper()
	var s string
	if err := f.d.Pool.QueryRow(f.ctx, sql, args...).Scan(&s); err != nil {
		f.t.Fatalf("text %q: %v", sql, err)
	}
	return s
}

// claimDays lists a player's claims of a program in the order they were
// made, by the day number each counted as.
func (f *fixture) claimDays(userID, code string) []int {
	f.t.Helper()
	rows, err := f.d.Pool.Query(f.ctx,
		`SELECT c.day_number FROM user_reward_claims c JOIN reward_programs p ON p.id = c.program_id
		  WHERE c.user_id = $1 AND p.code = $2 ORDER BY c.claim_date`, userID, code)
	if err != nil {
		f.t.Fatal(err)
	}
	defer rows.Close()
	var days []int
	for rows.Next() {
		var d int16
		if err := rows.Scan(&d); err != nil {
			f.t.Fatal(err)
		}
		days = append(days, int(d))
	}
	return days
}

// claimAt claims every running program at an instant.
func claimAt(t *testing.T, store *db.RewardPrograms, clock *luckyClock, userID string, at time.Time) *db.RewardClaimOutcome {
	t.Helper()
	clock.set(at)
	out, err := store.Claim(context.Background(), userID)
	if err != nil {
		t.Fatalf("claim at %s: %v", at.Format(time.RFC3339), err)
	}
	return out
}

// grantOf is the outcome's grant for a program, or nil when it gave nothing.
func grantOf(out *db.RewardClaimOutcome, code string) *db.RewardGrant {
	for i := range out.Granted {
		if out.Granted[i].ProgramCode == code {
			return &out.Granted[i]
		}
	}
	return nil
}

// stateOf is one program's state among many.
func stateOf(t *testing.T, states []db.RewardProgramState, code string) db.RewardProgramState {
	t.Helper()
	for _, s := range states {
		if s.Program.Code == code {
			return s
		}
	}
	t.Fatalf("no state for %s among %d programs", code, len(states))
	return db.RewardProgramState{}
}

// claimedDays are the days a state marks claimed.
func claimedDays(s db.RewardProgramState) []int {
	var days []int
	for _, d := range s.Rewards {
		if d.Claimed {
			days = append(days, d.Day)
		}
	}
	return days
}

func sameInts(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// wantGrant holds a grant to a day, a kind and an amount.
func wantGrant(t *testing.T, g *db.RewardGrant, code string, day int, kind string, value int64) {
	t.Helper()
	if g == nil {
		t.Fatalf("%s: nothing granted, want day %d %s %d", code, day, kind, value)
	}
	if g.ProgramCode != code || g.Day != day || g.RewardType != kind {
		t.Fatalf("%s: granted day %d %s, want day %d %s", code, g.Day, g.RewardType, day, kind)
	}
	if value > 0 && (g.RewardValue == nil || *g.RewardValue != value) {
		t.Fatalf("%s day %d: granted %v, want %d", code, day, g.RewardValue, value)
	}
}

// The brief's §11 and §30: Mon Day 1, Tue Day 2, Wed Day 3, Thu missed, Fri
// Day 1 — a true consecutive streak, read from the latest claim; the same day
// twice gives once; a new week starts at Day 1 whatever the last one reached.
func TestAWeeklyLoginStreakCountsConsecutiveDaysAndResetsOnAMiss(t *testing.T) {
	f := newFixture(t)
	f.onlyPrograms(weeklyLogin)
	u := f.user("weekly")
	clock := &luckyClock{}
	store := f.rewardStore(clock.Now)
	chips, hammers := f.wallet(u.ID, "chips"), f.wallet(u.ID, "hammer")

	// Monday 5 Oct 2026: the first login of the week is Day 1.
	out := claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 5, 9))
	g := grantOf(out, weeklyLogin)
	wantGrant(t, g, weeklyLogin, 1, db.RewardChips, 10_000)
	if g.Mode != db.RewardModeLoginStreak || g.PeriodType != db.RewardPeriodWeekly || g.ProgramName != "Weekly Login Streak" {
		t.Fatalf("the grant names its program: %+v", g)
	}
	if got := f.wallet(u.ID, "chips"); got != chips+10_000 {
		t.Fatalf("chips %d, want %d", got, chips+10_000)
	}
	key := db.RewardClaimActionID(u.ID, weeklyLogin, "2026-10-05")
	if reason := f.text(`SELECT reason FROM chip_ledger WHERE action_id = $1`, key); reason != game.LedgerReasonRewardProgram {
		t.Fatalf("the ledger row under the claim's key: reason %q", reason)
	}
	if delta := f.scalar(`SELECT delta FROM chip_ledger WHERE action_id = $1`, key); delta != 10_000 {
		t.Fatalf("the ledger row's delta: %d", delta)
	}
	s := stateOf(t, out.Programs, weeklyLogin)
	if s.CurrentDay != 1 || !s.ClaimedToday || s.ClaimedDays != 1 || s.Today != "2026-10-05" || s.DayOfPeriod != 1 || s.PeriodDays != 7 {
		t.Fatalf("after Monday: %+v", s)
	}
	if !sameInts(claimedDays(s), []int{1}) {
		t.Fatalf("after Monday the claimed days: %v", claimedDays(s))
	}
	if s.Program.PeriodStart != utcAt(2026, time.October, 5, 0).UnixMilli() || s.Program.PeriodEnd != utcAt(2026, time.October, 12, 0).UnixMilli()-1 {
		t.Fatalf("the week's bounds: %d..%d", s.Program.PeriodStart, s.Program.PeriodEnd)
	}

	// The same day again, later: nothing more, and the state says so.
	again := claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 5, 21))
	if len(again.Granted) != 0 || !stateOf(t, again.Programs, weeklyLogin).ClaimedToday || f.wallet(u.ID, "chips") != chips+10_000 {
		t.Fatalf("a second claim the same day: %+v", again.Granted)
	}
	if n := f.count(`SELECT count(*) FROM user_reward_claims WHERE user_id = $1`, u.ID); n != 1 {
		t.Fatalf("%d claims after two calls on one day", n)
	}

	// Tuesday: Day 2, 20,000 chips. Wednesday: Day 3, 30,000.
	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 6, 9)), weeklyLogin), weeklyLogin, 2, db.RewardChips, 20_000)
	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 7, 9)), weeklyLogin), weeklyLogin, 3, db.RewardChips, 30_000)
	if got := f.wallet(u.ID, "chips"); got != chips+60_000 {
		t.Fatalf("chips %d, want %d after three days", got, chips+60_000)
	}
	if got := f.wallet(u.ID, "hammer"); got != hammers {
		t.Fatalf("hammers %d, want %d: the hammer is Day 7's", got, hammers)
	}

	// Thursday missed. Friday: Day 1 again — the LATEST claim decides, never
	// the highest day reached.
	out = claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 9, 9))
	wantGrant(t, grantOf(out, weeklyLogin), weeklyLogin, 1, db.RewardChips, 10_000)
	s = stateOf(t, out.Programs, weeklyLogin)
	if s.CurrentDay != 1 || s.ClaimedDays != 1 || !sameInts(claimedDays(s), []int{1}) {
		t.Fatalf("after the missed Thursday: day %d run %d claimed %v", s.CurrentDay, s.ClaimedDays, claimedDays(s))
	}
	// Saturday Day 2, Sunday Day 3.
	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 10, 9)), weeklyLogin), weeklyLogin, 2, db.RewardChips, 20_000)
	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 11, 23)), weeklyLogin), weeklyLogin, 3, db.RewardChips, 30_000)

	// Monday 12 Oct, an hour later: a new week, and Day 1 whatever Sunday was.
	out = claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 12, 0))
	wantGrant(t, grantOf(out, weeklyLogin), weeklyLogin, 1, db.RewardChips, 10_000)
	s = stateOf(t, out.Programs, weeklyLogin)
	if s.Program.PeriodStart != utcAt(2026, time.October, 12, 0).UnixMilli() || s.ClaimedDays != 1 || s.DayOfPeriod != 1 {
		t.Fatalf("the new week: %+v", s)
	}

	if days := f.claimDays(u.ID, weeklyLogin); !sameInts(days, []int{1, 2, 3, 1, 2, 3, 1}) {
		t.Fatalf("the claims counted as days %v", days)
	}
	f.reconcile()
}

// §12: a monthly streak resets on a missed day and starts again on the 1st;
// February is 28 days, or 29 in a leap year, and each is a whole period.
func TestAMonthlyLoginStreakResetsOnAMissAndAtTheMonthsEnd(t *testing.T) {
	f := newFixture(t)
	f.onlyPrograms(monthlyLogin)
	f.exampleDays(monthlyLogin)
	u := f.user("monthly")
	clock := &luckyClock{}
	store := f.rewardStore(clock.Now)

	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2026, time.December, 1, 9)), monthlyLogin), monthlyLogin, 1, db.RewardChips, 10_000)
	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2026, time.December, 2, 9)), monthlyLogin), monthlyLogin, 2, db.RewardHammer, 1)
	if len(claimAt(t, store, clock, u.ID, utcAt(2026, time.December, 2, 23)).Granted) != 0 {
		t.Fatal("2 Dec twice")
	}
	// 3 Dec missed: 4 Dec is Day 1, and the days count up from there to the
	// 31st, which is Day 28 of a 31-day period.
	var last *db.RewardGrant
	for d := 4; d <= 31; d++ {
		last = grantOf(claimAt(t, store, clock, u.ID, utcAt(2026, time.December, d, 9)), monthlyLogin)
		if last == nil || last.Day != d-3 {
			t.Fatalf("%d Dec: %+v, want day %d", d, last, d-3)
		}
	}
	if last.RewardType != db.RewardChips || *last.RewardValue != 200_000 {
		t.Fatalf("Day 28's reward: %+v", last)
	}
	out := claimAt(t, store, clock, u.ID, utcAt(2027, time.January, 1, 0))
	wantGrant(t, grantOf(out, monthlyLogin), monthlyLogin, 1, db.RewardChips, 10_000)
	if s := stateOf(t, out.Programs, monthlyLogin); s.PeriodDays != 31 || s.Program.PeriodStart != utcAt(2027, time.January, 1, 0).UnixMilli() {
		t.Fatalf("January: %+v", s)
	}

	// February 2027 has 28 days: every day logged in, the 28th is Day 28 and
	// 1 March is Day 1.
	for d := 1; d <= 28; d++ {
		out = claimAt(t, store, clock, u.ID, utcAt(2027, time.February, d, 12))
		if g := grantOf(out, monthlyLogin); g == nil || g.Day != d {
			t.Fatalf("%d Feb 2027: %+v", d, g)
		}
	}
	if s := stateOf(t, out.Programs, monthlyLogin); s.PeriodDays != 28 || s.DayOfPeriod != 28 || s.Program.PeriodEnd != utcAt(2027, time.March, 1, 0).UnixMilli()-1 {
		t.Fatalf("February 2027: %+v", s)
	}
	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2027, time.March, 1, 12)), monthlyLogin), monthlyLogin, 1, db.RewardChips, 10_000)

	// A leap February: 2028 has a 29th, Day 29, and 1 March is Day 1 again.
	for d := 1; d <= 29; d++ {
		out = claimAt(t, store, clock, u.ID, utcAt(2028, time.February, d, 12))
		if g := grantOf(out, monthlyLogin); g == nil || g.Day != d {
			t.Fatalf("%d Feb 2028: %+v", d, g)
		}
	}
	if s := stateOf(t, out.Programs, monthlyLogin); s.PeriodDays != 29 || s.ClaimedDays != 29 {
		t.Fatalf("February 2028: %+v", s)
	}
	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2028, time.March, 1, 12)), monthlyLogin), monthlyLogin, 1, db.RewardChips, 10_000)
	f.reconcile()
}

// §13 and §30: a weekly calendar gives each day its own reward — Mon Day 1,
// Tue Day 2, Wed missed, Thu Day 4, never Day 1 or Day 3 on the Thursday —
// and a new week is a new calendar.
func TestAWeeklyCalendarGivesEachDaysRewardAndAMissedDayIsMissed(t *testing.T) {
	f := newFixture(t)
	f.onlyPrograms(weeklyCalendar)
	f.exampleDays(weeklyCalendar)
	u := f.user("calendar")
	clock := &luckyClock{}
	store := f.rewardStore(clock.Now)
	diamonds := f.wallet(u.ID, "diamond")

	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 5, 9)), weeklyCalendar), weeklyCalendar, 1, db.RewardChips, 10_000)
	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 6, 9)), weeklyCalendar), weeklyCalendar, 2, db.RewardHammer, 1)
	// Wednesday missed. Thursday is Day 4: the diamond, and neither Day 1's
	// chips nor Day 3's hammer.
	out := claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 8, 9))
	g := grantOf(out, weeklyCalendar)
	wantGrant(t, g, weeklyCalendar, 4, db.RewardDiamond, 1)
	if g.Mode != db.RewardModeCalendar || f.wallet(u.ID, "diamond") != diamonds+1 {
		t.Fatalf("Thursday: %+v, diamonds %d", g, f.wallet(u.ID, "diamond"))
	}
	// Friday is Day 5: the emoji, owned for the shop's term from now.
	at := utcAt(2026, time.October, 9, 9)
	out = claimAt(t, store, clock, u.ID, at)
	g = grantOf(out, weeklyCalendar)
	wantGrant(t, g, weeklyCalendar, 5, db.RewardEmoji, 0)
	if g.Emoji == nil || g.Emoji.Name != "Clapping Hands" || !g.Emoji.Owned || g.Emoji.ExpiresAt != at.UnixMilli()+30*db.DayMs || g.AlreadyOwned {
		t.Fatalf("the emoji: %+v (owned %v until %d)", g.Emoji, g.Emoji != nil && g.Emoji.Owned, at.UnixMilli()+30*db.DayMs)
	}
	if n := f.count(`SELECT count(*) FROM user_emojis WHERE user_id = $1`, u.ID); n != 1 {
		t.Fatalf("%d user_emojis rows", n)
	}
	// Friday again: nothing more.
	if len(claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 9, 20)).Granted) != 0 {
		t.Fatal("Friday twice")
	}
	s := stateOf(t, out.Programs, weeklyCalendar)
	if s.CurrentDay != 5 || !s.ClaimedToday || s.ClaimedDays != 4 || s.DayOfPeriod != 5 || !sameInts(claimedDays(s), []int{1, 2, 4, 5}) {
		t.Fatalf("after Friday: day %d claimed %v run %d days %v", s.CurrentDay, s.ClaimedToday, s.ClaimedDays, claimedDays(s))
	}
	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 10, 9)), weeklyCalendar), weeklyCalendar, 6, db.RewardChips, 30_000)
	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 11, 9)), weeklyCalendar), weeklyCalendar, 7, db.RewardChips, 50_000)

	// Monday 12 Oct: Day 1 of a new calendar, the old one's claims behind it.
	out = claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 12, 9))
	wantGrant(t, grantOf(out, weeklyCalendar), weeklyCalendar, 1, db.RewardChips, 10_000)
	if s := stateOf(t, out.Programs, weeklyCalendar); s.ClaimedDays != 1 || !sameInts(claimedDays(s), []int{1}) {
		t.Fatalf("the new week: %+v", s)
	}
	if days := f.claimDays(u.ID, weeklyCalendar); !sameInts(days, []int{1, 2, 4, 5, 6, 7, 1}) {
		t.Fatalf("the claims counted as days %v", days)
	}
	f.reconcile()
}

// §14 and §30: a monthly calendar is dated — Dec 1 Day 1, Dec 2 Day 2, Dec 3
// missed, Dec 4 Day 4, Dec 25 the table picture, Dec 31 the badge — and each
// February is its own length.
func TestAMonthlyCalendarIsDatedAndKeepsItsFebruaries(t *testing.T) {
	f := newFixture(t)
	f.onlyPrograms(monthlyCalendar)
	f.exampleDays(monthlyCalendar)
	u := f.user("december")
	clock := &luckyClock{}
	store := f.rewardStore(clock.Now)

	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2026, time.December, 1, 9)), monthlyCalendar), monthlyCalendar, 1, db.RewardChips, 10_000)
	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2026, time.December, 2, 9)), monthlyCalendar), monthlyCalendar, 2, db.RewardHammer, 1)
	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2026, time.December, 4, 9)), monthlyCalendar), monthlyCalendar, 4, db.RewardDiamond, 1)

	at := utcAt(2026, time.December, 25, 9)
	g := grantOf(claimAt(t, store, clock, u.ID, at), monthlyCalendar)
	wantGrant(t, g, monthlyCalendar, 25, db.RewardTablePicture, 0)
	if g.TablePicture == nil || g.TablePicture.Name != "Lines Background" || !g.TablePicture.Owned || g.TablePicture.ExpiresAt != at.UnixMilli()+7*db.DayMs {
		t.Fatalf("the table picture: %+v", g.TablePicture)
	}
	if n := f.count(`SELECT count(*) FROM user_table_pictures WHERE user_id = $1`, u.ID); n != 1 {
		t.Fatalf("%d user_table_pictures rows", n)
	}

	at = utcAt(2026, time.December, 31, 9)
	out := claimAt(t, store, clock, u.ID, at)
	g = grantOf(out, monthlyCalendar)
	wantGrant(t, g, monthlyCalendar, 31, db.RewardBadge, 0)
	if g.Badge == nil || g.Badge.Code != "ROYAL_ACE" || g.Badge.Title != "Royal Ace" || !g.Badge.Held || g.Badge.ExpiresAt != at.UnixMilli()+7*db.DayMs || g.AlreadyOwned {
		t.Fatalf("the badge: %+v", g.Badge)
	}
	if expires := f.scalar(`SELECT expires_at FROM user_badges WHERE user_id = $1 AND badge_code = 'ROYAL_ACE'`, u.ID); expires != at.UnixMilli()+7*db.DayMs {
		t.Fatalf("user_badges says the grant runs out at %d", expires)
	}
	if len(claimAt(t, store, clock, u.ID, utcAt(2026, time.December, 31, 23)).Granted) != 0 {
		t.Fatal("31 Dec twice")
	}
	s := stateOf(t, out.Programs, monthlyCalendar)
	if s.CurrentDay != 31 || s.ClaimedDays != 5 || s.DayOfPeriod != 31 || s.PeriodDays != 31 || !sameInts(claimedDays(s), []int{1, 2, 4, 25, 31}) {
		t.Fatalf("after December: %+v (claimed %v)", s, claimedDays(s))
	}

	out = claimAt(t, store, clock, u.ID, utcAt(2027, time.January, 1, 9))
	wantGrant(t, grantOf(out, monthlyCalendar), monthlyCalendar, 1, db.RewardChips, 10_000)
	if s := stateOf(t, out.Programs, monthlyCalendar); s.PeriodDays != 31 || s.ClaimedDays != 1 {
		t.Fatalf("January: %+v", s)
	}
	out = claimAt(t, store, clock, u.ID, utcAt(2027, time.February, 28, 9))
	wantGrant(t, grantOf(out, monthlyCalendar), monthlyCalendar, 28, db.RewardChips, 200_000)
	if s := stateOf(t, out.Programs, monthlyCalendar); s.PeriodDays != 28 || s.DayOfPeriod != 28 {
		t.Fatalf("February 2027: %+v", s)
	}
	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2027, time.March, 1, 9)), monthlyCalendar), monthlyCalendar, 1, db.RewardChips, 10_000)
	out = claimAt(t, store, clock, u.ID, utcAt(2028, time.February, 29, 9))
	wantGrant(t, grantOf(out, monthlyCalendar), monthlyCalendar, 29, db.RewardDiamond, 2)
	if s := stateOf(t, out.Programs, monthlyCalendar); s.PeriodDays != 29 || s.DayOfPeriod != 29 {
		t.Fatalf("February 2028: %+v", s)
	}
	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2028, time.March, 1, 9)), monthlyCalendar), monthlyCalendar, 1, db.RewardChips, 10_000)
	f.reconcile()
}

// Every kind of reward lands where its purchase would: chips through
// chip_ledger (reason reward_program, the claim's key), the three other
// wallets as deltas, an emoji, a picture and a table picture as ownership
// rows for the shop's term, a badge as a grant for its validity — extended
// when granted again, as a second purchase extends it; an item already owned
// is left exactly as it is.
func TestEveryKindOfRewardLandsWhereItsPurchaseWould(t *testing.T) {
	f := newFixture(t)
	f.onlyPrograms()
	id := f.program("KINDS", db.RewardModeCalendar, db.RewardPeriodMonthly, "UTC", 1, false)
	clap := f.catalogueID("emojis", "Clapping Hands")
	f.day(id, 1, db.RewardChips, amount(1234), nil)
	f.day(id, 2, db.RewardHammer, amount(2), nil)
	f.day(id, 3, db.RewardDiamond, amount(3), nil)
	f.day(id, 4, db.RewardMissile, amount(4), nil)
	f.day(id, 5, db.RewardEmoji, nil, clap)
	f.day(id, 6, db.RewardProfilePicture, nil, f.catalogueID("profile_pictures", "Lovestruck Cat"))
	f.day(id, 7, db.RewardTablePicture, nil, f.catalogueID("table_pictures", "Lines Background"))
	f.day(id, 8, db.RewardBadge, nil, ref("ROYAL_ACE"))
	f.day(id, 9, db.RewardEmoji, nil, clap)
	f.day(id, 10, db.RewardBadge, nil, ref("ROYAL_ACE"))
	u := f.user("kinds")
	clock := &luckyClock{}
	store := f.rewardStore(clock.Now)
	chips, hammers, diamonds, missiles := f.wallet(u.ID, "chips"), f.wallet(u.ID, "hammer"), f.wallet(u.ID, "diamond"), f.wallet(u.ID, "missile")
	ledgerRows := len(f.ledgerRows(u.ID))

	grants := map[int]*db.RewardGrant{}
	ats := map[int]time.Time{}
	for d := 1; d <= 10; d++ {
		ats[d] = utcAt(2026, time.December, d, 10)
		grants[d] = grantOf(claimAt(t, store, clock, u.ID, ats[d]), "KINDS")
		if grants[d] == nil || grants[d].Day != d {
			t.Fatalf("day %d: %+v", d, grants[d])
		}
	}
	if got := f.wallet(u.ID, "chips"); got != chips+1234 {
		t.Fatalf("chips %d, want %d", got, chips+1234)
	}
	if got := f.wallet(u.ID, "hammer"); got != hammers+2 {
		t.Fatalf("hammers %d, want %d", got, hammers+2)
	}
	if got := f.wallet(u.ID, "diamond"); got != diamonds+3 {
		t.Fatalf("diamonds %d, want %d", got, diamonds+3)
	}
	if got := f.wallet(u.ID, "missile"); got != missiles+4 {
		t.Fatalf("missiles %d, want %d", got, missiles+4)
	}
	// One ledger row, for the chips; the other wallets are never ledgered.
	if rows := f.ledgerRows(u.ID); len(rows) != ledgerRows+1 {
		t.Fatalf("%d ledger rows, want %d", len(rows), ledgerRows+1)
	}
	if em := grants[5].Emoji; em == nil || !em.Owned || em.ExpiresAt != ats[5].UnixMilli()+30*db.DayMs {
		t.Fatalf("the emoji: %+v", em)
	}
	if pic := grants[6].Picture; pic == nil || pic.Name != "Lovestruck Cat" || !pic.Owned || pic.ExpiresAt != ats[6].UnixMilli()+50*db.DayMs {
		t.Fatalf("the picture: %+v", pic)
	}
	if n := f.count(`SELECT count(*) FROM user_profile_pictures WHERE user_id = $1`, u.ID); n != 1 {
		t.Fatalf("%d user_profile_pictures rows", n)
	}
	if pic := grants[7].TablePicture; pic == nil || !pic.Owned || pic.ExpiresAt != ats[7].UnixMilli()+7*db.DayMs {
		t.Fatalf("the table picture: %+v", pic)
	}
	firstBadge := ats[8].UnixMilli() + 7*db.DayMs
	if b := grants[8].Badge; b == nil || !b.Held || b.ExpiresAt != firstBadge || grants[8].AlreadyOwned {
		t.Fatalf("the badge: %+v", b)
	}
	// The emoji again on Day 9: already owned and running, left as it was.
	if g := grants[9]; !g.AlreadyOwned || g.Emoji == nil || g.Emoji.ExpiresAt != ats[5].UnixMilli()+30*db.DayMs {
		t.Fatalf("the emoji again: %+v", g)
	}
	if n := f.count(`SELECT count(*) FROM user_emojis WHERE user_id = $1`, u.ID); n != 1 {
		t.Fatalf("%d user_emojis rows after two emoji grants", n)
	}
	// The badge again on Day 10: the running grant is extended by its validity.
	if g := grants[10]; g.AlreadyOwned || g.Badge == nil || g.Badge.ExpiresAt != firstBadge+7*db.DayMs {
		t.Fatalf("the badge again: %+v (want until %d)", g.Badge, firstBadge+7*db.DayMs)
	}
	if expires := f.scalar(`SELECT expires_at FROM user_badges WHERE user_id = $1 AND badge_code = 'ROYAL_ACE'`, u.ID); expires != firstBadge+7*db.DayMs {
		t.Fatalf("user_badges says %d", expires)
	}
	// Every claim recorded with a snapshot of what it gave.
	if n := f.count(`SELECT count(*) FROM user_reward_claims WHERE user_id = $1`, u.ID); n != 10 {
		t.Fatalf("%d claims", n)
	}
	if kind := f.text(`SELECT reward_type FROM user_reward_claims WHERE user_id = $1 AND day_number = 7`, u.ID); kind != db.RewardTablePicture {
		t.Fatalf("day 7's claim says %s", kind)
	}
	f.reconcile()
}

// §21: two requests at once — from two pools, as two server processes would
// send them, no Go lock between them — grant a day's reward once. The wallet
// lock serialises them; the unique claim index would catch what slipped it.
func TestTwoRequestsAtOnceGrantADaysRewardOnce(t *testing.T) {
	f := newFixture(t)
	u := f.user("racer")
	clock := &luckyClock{}
	clock.set(utcAt(2026, time.October, 5, 9)) // a Monday, the 5th
	other, err := db.Open(f.ctx, db.Options{URL: testURL(), Schema: f.d.Schema, PoolMax: 4, SkipMigrations: true})
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	stores := []*db.RewardPrograms{
		f.rewardStore(clock.Now),
		db.NewRewardPrograms(other, db.NewUsers(other, welcome, nil), clock.Now, nil),
	}
	chips := f.wallet(u.ID, "chips")

	const callers = 8
	var wg sync.WaitGroup
	start := make(chan struct{})
	results := make(chan *db.RewardClaimOutcome, callers)
	errs := make(chan error, callers)
	for i := 0; i < callers; i++ {
		store := stores[i%len(stores)]
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			out, err := store.Claim(context.Background(), u.ID)
			if err != nil {
				errs <- err
				return
			}
			results <- out
		}()
	}
	close(start)
	wg.Wait()
	close(results)
	close(errs)
	for err := range errs {
		t.Fatalf("a claim failed: %v", err)
	}
	granted := 0
	for out := range results {
		granted += len(out.Granted)
	}
	// The one seeded program gave once, across every caller: Monday the 5th
	// is Day 1 of the weekly streak (10,000 chips).
	if granted != 1 {
		t.Fatalf("%d rewards granted across %d callers, want 1", granted, callers)
	}
	if n := f.count(`SELECT count(*) FROM user_reward_claims WHERE user_id = $1`, u.ID); n != 1 {
		t.Fatalf("%d claims recorded, want 1", n)
	}
	if got := f.wallet(u.ID, "chips"); got != chips+10_000 {
		t.Fatalf("chips %d, want %d", got, chips+10_000)
	}
	f.reconcile()
}

// §10: a claim keeps what it gave. The day repointed afterwards changes what
// the program offers, not what the record says was given.
func TestAClaimKeepsWhatItGaveWhenTheDayIsRepointed(t *testing.T) {
	f := newFixture(t)
	f.onlyPrograms(weeklyLogin)
	u := f.user("snapshot")
	clock := &luckyClock{}
	store := f.rewardStore(clock.Now)
	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 5, 9)), weeklyLogin), weeklyLogin, 1, db.RewardChips, 10_000)

	f.exec(`UPDATE reward_program_rewards
	           SET reward_type = 'EMOJI', reward_value = NULL,
	               reward_ref_id = (SELECT id::text FROM emojis WHERE name = 'Clapping Hands')
	         WHERE day_number = 1 AND program_id = (SELECT id FROM reward_programs WHERE code = $1)`, weeklyLogin)
	if kind := f.text(`SELECT reward_type FROM user_reward_claims WHERE user_id = $1`, u.ID); kind != db.RewardChips {
		t.Fatalf("the claim now says %s", kind)
	}
	if value := f.scalar(`SELECT reward_value FROM user_reward_claims WHERE user_id = $1`, u.ID); value != 10_000 {
		t.Fatalf("the claim now says %d", value)
	}
	states, err := store.State(f.ctx, u.ID)
	if err != nil {
		t.Fatal(err)
	}
	s := stateOf(t, states, weeklyLogin)
	if s.Rewards[0].RewardType != db.RewardEmoji || !s.Rewards[0].Claimed {
		t.Fatalf("the day as it now stands: %+v", s.Rewards[0])
	}
	// A retry of the claim gives nothing: the day is claimed, whatever it now
	// offers.
	if len(claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 5, 12)).Granted) != 0 {
		t.Fatal("the repointed day was given again")
	}
}

// §4 and §16: a program is dated in its own zone and its own week — never
// the server's.
func TestAProgramIsDatedInItsOwnZoneAndWeek(t *testing.T) {
	f := newFixture(t)
	f.onlyPrograms()
	ist := f.program("IST_MONTHLY", db.RewardModeCalendar, db.RewardPeriodMonthly, "Asia/Kolkata", 1, false)
	f.day(ist, 1, db.RewardChips, amount(500), nil)
	f.day(ist, 31, db.RewardChips, amount(700), nil)
	sun := f.program("SUNDAY_WEEK", db.RewardModeCalendar, db.RewardPeriodWeekly, "UTC", 7, false)
	f.day(sun, 1, db.RewardHammer, amount(1), nil)
	f.day(sun, 7, db.RewardHammer, amount(7), nil)
	u := f.user("zoned")
	clock := &luckyClock{}
	store := f.rewardStore(clock.Now)
	kolkata, _ := time.LoadLocation("Asia/Kolkata")

	// 31 Oct, 18:00 UTC is 23:30 in Kolkata: still the 31st there.
	out := claimAt(t, store, clock, u.ID, time.Date(2026, time.October, 31, 18, 0, 0, 0, time.UTC))
	wantGrant(t, grantOf(out, "IST_MONTHLY"), "IST_MONTHLY", 31, db.RewardChips, 700)
	if s := stateOf(t, out.Programs, "IST_MONTHLY"); s.Today != "2026-10-31" || s.Program.Timezone != "Asia/Kolkata" {
		t.Fatalf("31 Oct in Kolkata: %+v", s)
	}
	// An hour later it is 1 Nov there: Day 1 of a new month, claimable again.
	out = claimAt(t, store, clock, u.ID, time.Date(2026, time.October, 31, 19, 0, 0, 0, time.UTC))
	wantGrant(t, grantOf(out, "IST_MONTHLY"), "IST_MONTHLY", 1, db.RewardChips, 500)
	s := stateOf(t, out.Programs, "IST_MONTHLY")
	if s.Today != "2026-11-01" || s.Program.PeriodStart != time.Date(2026, time.November, 1, 0, 0, 0, 0, kolkata).UnixMilli() || s.PeriodDays != 30 {
		t.Fatalf("1 Nov in Kolkata: %+v", s)
	}
	if date := f.text(`SELECT claim_date::text FROM user_reward_claims c JOIN reward_programs p ON p.id = c.program_id
	                    WHERE c.user_id = $1 AND p.code = 'IST_MONTHLY' ORDER BY c.claimed_at DESC LIMIT 1`, u.ID); date != "2026-11-01" {
		t.Fatalf("the claim is dated %s", date)
	}

	// A Sunday-based week: Sunday 4 Oct 2026 is Day 1, Saturday the 10th Day 7.
	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 4, 12)), "SUNDAY_WEEK"), "SUNDAY_WEEK", 1, db.RewardHammer, 1)
	out = claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 10, 12))
	wantGrant(t, grantOf(out, "SUNDAY_WEEK"), "SUNDAY_WEEK", 7, db.RewardHammer, 7)
	if s := stateOf(t, out.Programs, "SUNDAY_WEEK"); s.DayOfPeriod != 7 || s.Program.PeriodStart != utcAt(2026, time.October, 4, 0).UnixMilli() || s.Program.WeekStartDay != 7 {
		t.Fatalf("the Sunday week: %+v", s)
	}
	f.reconcile()
}

// §15: a one-off campaign runs only inside its window, and is otherwise the
// same program as any other.
func TestACampaignRunsOnlyInsideItsWindow(t *testing.T) {
	f := newFixture(t)
	f.onlyPrograms()
	starts, ends := utcAt(2026, time.December, 1, 0).UnixMilli(), utcAt(2027, time.January, 1, 0).UnixMilli()-1
	f.exec(`INSERT INTO reward_programs (code, name, mode, period_type, timezone, starts_at, ends_at, sort_order)
	         VALUES ('DECEMBER_2026', 'December Rewards', 'CALENDAR', 'MONTHLY', 'UTC', $1, $2, 5)`, starts, ends)
	id := f.scalar(`SELECT id FROM reward_programs WHERE code = 'DECEMBER_2026'`)
	f.day(id, 15, db.RewardChips, amount(1500), nil)
	u := f.user("campaigner")
	clock := &luckyClock{}
	store := f.rewardStore(clock.Now)

	for _, at := range []time.Time{utcAt(2026, time.November, 30, 23), utcAt(2027, time.January, 1, 0)} {
		if out := claimAt(t, store, clock, u.ID, at); len(out.Programs) != 0 || len(out.Granted) != 0 {
			t.Fatalf("outside its window at %s: %+v", at, out.Programs)
		}
	}
	out := claimAt(t, store, clock, u.ID, utcAt(2026, time.December, 15, 12))
	wantGrant(t, grantOf(out, "DECEMBER_2026"), "DECEMBER_2026", 15, db.RewardChips, 1500)
	s := stateOf(t, out.Programs, "DECEMBER_2026")
	if s.Program.StartsAt == nil || *s.Program.StartsAt != starts || s.Program.EndsAt == nil || *s.Program.EndsAt != ends || s.DayOfPeriod != 15 {
		t.Fatalf("the campaign: %+v", s)
	}
}

// A day with nothing on it — no row, or a row this server cannot grant — is
// still claimed, recorded as NO_REWARD, so a streak counts through it; the
// day gives nothing and is left out of what the program offers.
func TestADayWithNothingOnItStillCountsForTheStreak(t *testing.T) {
	f := newFixture(t)
	f.onlyPrograms()
	id := f.program("SPARSE", db.RewardModeLoginStreak, db.RewardPeriodWeekly, "UTC", 1, true)
	f.day(id, 1, db.RewardChips, amount(100), nil)
	f.day(id, 3, db.RewardChips, amount(300), nil)
	f.exec(`UPDATE emojis SET is_active = FALSE WHERE name = 'Angry'`)
	f.day(id, 4, db.RewardEmoji, nil, f.catalogueID("emojis", "Angry"))
	f.day(id, 5, "AVATAR_FRAME", nil, ref("golden_crown"))
	u := f.user("sparse")
	clock := &luckyClock{}
	store := f.rewardStore(clock.Now)
	chips := f.wallet(u.ID, "chips")

	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 5, 9)), "SPARSE"), "SPARSE", 1, db.RewardChips, 100)
	// Tuesday has no reward: nothing granted, the day claimed all the same.
	out := claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 6, 9))
	if len(out.Granted) != 0 {
		t.Fatalf("Tuesday granted %+v", out.Granted)
	}
	if s := stateOf(t, out.Programs, "SPARSE"); !s.ClaimedToday || s.CurrentDay != 2 || s.ClaimedDays != 2 {
		t.Fatalf("after Tuesday: %+v", s)
	}
	// Wednesday is Day 3: the streak did not reset over a day that gave
	// nothing.
	wantGrant(t, grantOf(claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 7, 9)), "SPARSE"), "SPARSE", 3, db.RewardChips, 300)
	// Thursday's emoji is retired, Friday's kind unknown: both days claimed,
	// neither given.
	for d := 8; d <= 9; d++ {
		out = claimAt(t, store, clock, u.ID, utcAt(2026, time.October, d, 9))
		if len(out.Granted) != 0 {
			t.Fatalf("%d Oct granted %+v", d, out.Granted)
		}
	}
	s := stateOf(t, out.Programs, "SPARSE")
	if s.ClaimedDays != 5 || len(s.Rewards) != 2 || s.Rewards[0].Day != 1 || s.Rewards[1].Day != 3 {
		t.Fatalf("what the program offers: %+v", s.Rewards)
	}
	if days := f.claimDays(u.ID, "SPARSE"); !sameInts(days, []int{1, 2, 3, 4, 5}) {
		t.Fatalf("the claims counted as days %v", days)
	}
	if kind := f.text(`SELECT reward_type FROM user_reward_claims WHERE user_id = $1 AND day_number = 4`, u.ID); kind != db.RewardNone {
		t.Fatalf("Thursday's claim says %s", kind)
	}
	if got := f.wallet(u.ID, "chips"); got != chips+400 {
		t.Fatalf("chips %d, want %d", got, chips+400)
	}
	f.reconcile()
}

// A program in a zone this server cannot load is left out — a WARN, never a
// failed request.
func TestAProgramInAZoneTheServerCannotLoadIsLeftOut(t *testing.T) {
	f := newFixture(t)
	f.program("MARS", db.RewardModeCalendar, db.RewardPeriodWeekly, "Mars/Olympus", 1, false)
	u := f.user("martian")
	states, err := f.rewardStore(nil).State(f.ctx, u.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range states {
		if s.Program.Code == "MARS" {
			t.Fatal("a program in an unknown zone was served")
		}
	}
	if len(states) != 1 {
		t.Fatalf("%d programs, want the seeded one", len(states))
	}
}

// The seed: the owner's four programs, in order, with the brief's rewards.
func TestTheSeededProgramsAreTheOwnersWeeklyLoginAndThreeWaiting(t *testing.T) {
	f := newFixture(t)
	u := f.user("reader")
	clock := &luckyClock{}
	clock.set(utcAt(2026, time.October, 5, 9))
	states, err := f.rewardStore(clock.Now).State(f.ctx, u.ID)
	if err != nil {
		t.Fatal(err)
	}
	// One program runs: the owner's weekly login streak.
	if len(states) != 1 {
		t.Fatalf("%d programs run, want the weekly login alone: %+v", len(states), states)
	}
	weekly := states[0]
	p := weekly.Program
	if p.Code != weeklyLogin || p.Mode != db.RewardModeLoginStreak || p.PeriodType != db.RewardPeriodWeekly || !p.ResetOnMissedDay ||
		p.Timezone != "UTC" || p.WeekStartDay != 1 || p.StartsAt != nil || p.EndsAt != nil {
		t.Fatalf("WEEKLY_LOGIN: %+v", p)
	}
	if weekly.ClaimedToday || weekly.ClaimedDays != 0 {
		t.Fatalf("a fresh account has claimed nothing: %+v", weekly)
	}
	kinds := func(s db.RewardProgramState) string {
		var parts []string
		for _, d := range s.Rewards {
			part := fmt.Sprintf("%d:%s", d.Day, d.RewardType)
			if d.RewardValue != nil {
				part += fmt.Sprintf("=%d", *d.RewardValue)
			}
			parts = append(parts, part)
		}
		return strings.Join(parts, " ")
	}
	// The owner's own days (30 Sep 2026): chips rising to the sixth day, a
	// hammer on the seventh.
	if got := kinds(weekly); got != "1:CHIPS=10000 2:CHIPS=20000 3:CHIPS=30000 4:CHIPS=40000 5:CHIPS=50000 6:CHIPS=60000 7:HAMMER=1" {
		t.Fatalf("WEEKLY_LOGIN's days: %s", got)
	}
	if weekly.CurrentDay != 1 || weekly.DayOfPeriod != 1 || weekly.PeriodDays != 7 {
		t.Fatalf("Monday's weekly streak: %+v", weekly)
	}
	// The other three are seeded, inactive, with no days: switched on with an
	// UPDATE once their days are.
	for _, code := range []string{monthlyLogin, weeklyCalendar, monthlyCalendar} {
		if active := f.text(`SELECT is_active::text FROM reward_programs WHERE code = $1`, code); active != "false" {
			t.Fatalf("%s is_active %q, want false", code, active)
		}
		if n := f.count(`SELECT count(*) FROM reward_program_rewards r JOIN reward_programs p ON p.id = r.program_id WHERE p.code = $1`, code); n != 0 {
			t.Fatalf("%s has %d days seeded", code, n)
		}
	}
	// The wire, as the brief's §25 names it.
	body, err := json.Marshal(weekly)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{`"program":{"id":`, `"code":"WEEKLY_LOGIN"`, `"mode":"LOGIN_STREAK"`, `"periodType":"WEEKLY"`,
		`"periodStart":`, `"periodEnd":`, `"currentDay":1`, `"claimedToday":false`, `"rewards":[{"day":1,"rewardType":"CHIPS","rewardValue":10000,"rewardRefId":null,"claimed":false}`} {
		if !strings.Contains(string(body), key) {
			t.Fatalf("the wire lacks %s:\n%s", key, body)
		}
	}
}
