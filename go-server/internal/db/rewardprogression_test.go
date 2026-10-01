package db_test

import (
	"context"
	"errors"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
)

// The progression types (owner, 1 Oct 2026: "Build a generic reward engine
// that supports RESET, SEQUENTIAL and BREAK … WEEKLY and MONTHLY … LOGIN and
// CALENDAR"), on the database: the brief's own programs as the seed puts them,
// claims through the store, the progress row each player's standing is kept
// in, a named claim's refusals, and a database from before the column brought
// forward. 5 Oct 2026 is a Monday; the brief's programs run in Asia/Kolkata.

const (
	weeklySequential    = "WEEKLY_SEQUENTIAL"
	weeklySequentialCal = "WEEKLY_SEQUENTIAL_CAL"
)

// kolkataAt is an instant on the hour in Asia/Kolkata.
func kolkataAt(m time.Month, d, hour int) time.Time {
	loc, err := time.LoadLocation("Asia/Kolkata")
	if err != nil {
		panic(err)
	}
	return time.Date(2026, m, d, hour, 0, 0, 0, loc)
}

// progressRow is a player's user_reward_progress row of a program's period,
// or ok false with none.
func (f *fixture) progressRow(userID, code string, periodStart int64) (day int, status string, lastActivity, updatedAt int64, ok bool) {
	f.t.Helper()
	err := f.d.Pool.QueryRow(f.ctx,
		`SELECT up.current_day, up.status, up.last_activity_at, up.updated_at
		   FROM user_reward_progress up JOIN reward_programs p ON p.id = up.program_id
		  WHERE up.user_id = $1 AND p.code = $2 AND up.period_start_at = $3`, userID, code, periodStart).
		Scan(&day, &status, &lastActivity, &updatedAt)
	if err != nil {
		return 0, "", 0, 0, false
	}
	return day, status, lastActivity, updatedAt, true
}

// resultOf is a claim's result for a program.
func resultOf(t *testing.T, out *db.RewardClaimOutcome, code string) db.RewardClaimResult {
	t.Helper()
	for _, r := range out.Results {
		if r.ProgramCode == code {
			return r
		}
	}
	t.Fatalf("no result for %s among %+v", code, out.Results)
	return db.RewardClaimResult{}
}

// dayStates are a state's days' standings, in day order.
func dayStates(s db.RewardProgramState) []string {
	var out []string
	for _, d := range s.Rewards {
		out = append(out, d.State)
	}
	return out
}

func sameStrings(a, b []string) bool {
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

// The seed: the four programs of 30 Sep 2026 given the progression each
// already had, and the brief's two, inactive, in Asia/Kolkata — the
// calendar with the brief's seven days, its emoji and badge by natural key.
func TestTheProgressionBriefsProgramsAreSeededWaiting(t *testing.T) {
	f := newFixture(t)
	for code, want := range map[string]string{
		weeklyLogin:         "LOGIN_STREAK RESET WEEKLY UTC true",
		monthlyLogin:        "LOGIN_STREAK RESET MONTHLY UTC false",
		weeklyCalendar:      "CALENDAR SEQUENTIAL WEEKLY UTC false",
		monthlyCalendar:     "CALENDAR SEQUENTIAL MONTHLY UTC false",
		weeklySequential:    "LOGIN_STREAK SEQUENTIAL WEEKLY Asia/Kolkata false",
		weeklySequentialCal: "CALENDAR BREAK WEEKLY Asia/Kolkata false",
	} {
		got := f.text(`SELECT mode || ' ' || progression_type || ' ' || period_type || ' ' || timezone || ' ' || is_active::text
		                 FROM reward_programs WHERE code = $1`, code)
		if got != want {
			t.Errorf("%s: %s, want %s", code, got, want)
		}
	}
	if n := f.count(`SELECT count(*) FROM reward_program_rewards r JOIN reward_programs p ON p.id = r.program_id WHERE p.code = $1`, weeklySequential); n != 0 {
		t.Errorf("WEEKLY_SEQUENTIAL has %d days, want none yet", n)
	}
	clap := f.scalar(`SELECT id FROM emojis WHERE name = 'Clapping Hands'`)
	rows, err := f.d.Pool.Query(f.ctx,
		`SELECT r.day_number, r.reward_type, coalesce(r.reward_value, 0), coalesce(r.reward_ref_id, '')
		   FROM reward_program_rewards r JOIN reward_programs p ON p.id = r.program_id
		  WHERE p.code = $1 ORDER BY r.day_number`, weeklySequentialCal)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var got []string
	for rows.Next() {
		var day int16
		var kind, refID string
		var value int64
		if err := rows.Scan(&day, &kind, &value, &refID); err != nil {
			t.Fatal(err)
		}
		got = append(got, kind+":"+strconv.FormatInt(value, 10)+":"+refID)
	}
	want := []string{"CHIPS:10000:", "HAMMER:1:", "CHIPS:20000:", "DIAMOND:1:", "EMOJI:0:" + strconv.FormatInt(clap, 10), "CHIPS:50000:", "BADGE:0:ROYAL_ACE"}
	if !sameStrings(got, want) {
		t.Fatalf("WEEKLY_SEQUENTIAL_CAL's days:\n %v\nwant\n %v", got, want)
	}
}

// The brief's IMPORTANT EXAMPLE, word for word: WEEKLY_SEQUENTIAL_CAL, period
// 5–12 Oct 2026 in Kolkata, player U1001 — Monday Day 1 (10,000 chips),
// Tuesday Day 2 (a hammer), Wednesday missed, Thursday opens the app: the
// progress row says current_day 3, BROKEN; Days 3–7 cannot be claimed;
// next Monday is a new period, Day 1 ACTIVE.
func TestTheBriefsSequentialCalendarBreaksOnAMissedDayAndStartsAgainTheNextWeek(t *testing.T) {
	f := newFixture(t)
	f.onlyPrograms(weeklySequentialCal)
	u := f.user("u1001")
	clock := &luckyClock{}
	store := f.rewardStore(clock.Now)
	chips, hammers := f.wallet(u.ID, "chips"), f.wallet(u.ID, "hammer")
	monday := kolkataAt(time.October, 5, 0).UnixMilli()

	out := claimAt(t, store, clock, u.ID, kolkataAt(time.October, 5, 9))
	wantGrant(t, grantOf(out, weeklySequentialCal), weeklySequentialCal, 1, db.RewardChips, 10_000)
	out = claimAt(t, store, clock, u.ID, kolkataAt(time.October, 6, 9))
	wantGrant(t, grantOf(out, weeklySequentialCal), weeklySequentialCal, 2, db.RewardHammer, 1)
	tuesdayClaim := resultOf(t, out, weeklySequentialCal).ClaimedAt
	if day, status, last, _, ok := f.progressRow(u.ID, weeklySequentialCal, monday); !ok || day != 3 || status != db.RewardStatusActive || last != tuesdayClaim {
		t.Fatalf("after Tuesday's claim: day %d %s last %d (ok %v)", day, status, last, ok)
	}

	// Wednesday: the player does not open the app. Thursday they do.
	broken := []string{db.RewardDayClaimed, db.RewardDayClaimed, db.RewardDayMissed,
		db.RewardDayLocked, db.RewardDayLocked, db.RewardDayLocked, db.RewardDayLocked}
	clock.set(kolkataAt(time.October, 8, 9))
	view, err := store.State(f.ctx, u.ID)
	if err != nil {
		t.Fatal(err)
	}
	s := stateOf(t, view.Programs, weeklySequentialCal)
	if s.Status != db.RewardStatusBroken || s.CurrentDay != 3 || s.CanClaim || s.NextDay != 0 || s.ClaimedDays != 2 || s.ClaimedToday {
		t.Fatalf("Thursday: %+v", s)
	}
	if got := dayStates(s); !sameStrings(got, broken) {
		t.Fatalf("Thursday's days: %v", got)
	}
	if s.Period.StartDate != "2026-10-05" || s.Period.EndDate != "2026-10-11" || s.Period.StartAt != monday ||
		s.NextPeriod == nil || s.NextPeriod.StartDate != "2026-10-12" || s.NextPeriod.StartAt != s.Period.EndAt ||
		s.NextPeriod.StartsInMs != s.NextPeriod.StartAt-clock.Now().UnixMilli() {
		t.Fatalf("Thursday's cycles: %+v %+v", s.Period, s.NextPeriod)
	}
	if day, status, last, _, ok := f.progressRow(u.ID, weeklySequentialCal, monday); !ok || day != 3 || status != db.RewardStatusBroken || last != tuesdayClaim {
		t.Fatalf("the progress row after Thursday's look: day %d %s last %d (ok %v)", day, status, last, ok)
	}
	// Claimed anyway: nothing is given, and a claim that names it is refused.
	out = claimAt(t, store, clock, u.ID, kolkataAt(time.October, 8, 10))
	if len(out.Granted) != 0 || resultOf(t, out, weeklySequentialCal).Outcome != db.RewardOutcomeBroken {
		t.Fatalf("Thursday's claim: %+v", out)
	}
	if _, err := store.Claim(f.ctx, u.ID, weeklySequentialCal); !errors.Is(err, db.ErrRewardCycleBroken) {
		t.Fatalf("a named claim of a broken cycle: %v", err)
	}
	// Friday, Saturday and Sunday the same.
	for day := 9; day <= 11; day++ {
		clock.set(kolkataAt(time.October, day, 22))
		view, err := store.State(f.ctx, u.ID)
		if err != nil {
			t.Fatal(err)
		}
		if s := stateOf(t, view.Programs, weeklySequentialCal); s.Status != db.RewardStatusBroken || s.CanClaim || !sameStrings(dayStates(s), broken) {
			t.Fatalf("October %d: %+v", day, s)
		}
	}
	if days := f.claimDays(u.ID, weeklySequentialCal); !sameInts(days, []int{1, 2}) {
		t.Fatalf("claims recorded: %v", days)
	}

	// The next Monday: a new period, Day 1 again.
	nextMonday := kolkataAt(time.October, 12, 0).UnixMilli()
	clock.set(kolkataAt(time.October, 12, 7))
	view, err = store.State(f.ctx, u.ID)
	if err != nil {
		t.Fatal(err)
	}
	s = stateOf(t, view.Programs, weeklySequentialCal)
	if s.Status != db.RewardStatusActive || s.CurrentDay != 1 || !s.CanClaim || s.Period.StartAt != nextMonday || s.Period.StartDate != "2026-10-12" {
		t.Fatalf("the next Monday: %+v", s)
	}
	if day, status, last, _, ok := f.progressRow(u.ID, weeklySequentialCal, nextMonday); !ok || day != 1 || status != db.RewardStatusActive || last != 0 {
		t.Fatalf("the new period's row at the first look: day %d %s last %d (ok %v)", day, status, last, ok)
	}
	out = claimAt(t, store, clock, u.ID, kolkataAt(time.October, 12, 8))
	wantGrant(t, grantOf(out, weeklySequentialCal), weeklySequentialCal, 1, db.RewardChips, 10_000)
	if day, status, _, _, ok := f.progressRow(u.ID, weeklySequentialCal, nextMonday); !ok || day != 2 || status != db.RewardStatusActive {
		t.Fatalf("the new period's row after its Day 1: day %d %s", day, status)
	}
	// The broken week's row stays as it ended.
	if day, status, _, _, ok := f.progressRow(u.ID, weeklySequentialCal, monday); !ok || day != 3 || status != db.RewardStatusBroken {
		t.Fatalf("the broken week's row: day %d %s", day, status)
	}
	if got := f.wallet(u.ID, "chips"); got != chips+20_000 {
		t.Fatalf("chips %d, want %d", got, chips+20_000)
	}
	if got := f.wallet(u.ID, "hammer"); got != hammers+1 {
		t.Fatalf("hammers %d, want %d", got, hammers+1)
	}
	f.reconcile()
}

// A whole week of the brief's calendar: every day's reward lands where its
// purchase would — chips through the ledger, a hammer and a diamond in their
// columns, the emoji and the badge as their ownership rows — and Sunday's
// claim completes the cycle.
func TestAWholeWeekOfTheBriefsCalendarGivesEveryRewardAndCompletes(t *testing.T) {
	f := newFixture(t)
	f.onlyPrograms(weeklySequentialCal)
	u := f.user("everyday")
	clock := &luckyClock{}
	store := f.rewardStore(clock.Now)
	chips, hammers, diamonds := f.wallet(u.ID, "chips"), f.wallet(u.ID, "hammer"), f.wallet(u.ID, "diamond")
	for day := 5; day <= 11; day++ {
		out := claimAt(t, store, clock, u.ID, kolkataAt(time.October, day, 20))
		if r := resultOf(t, out, weeklySequentialCal); r.Outcome != db.RewardOutcomeGranted || r.Day != day-4 {
			t.Fatalf("October %d: %+v", day, r)
		}
	}
	view, err := store.State(f.ctx, u.ID)
	if err != nil {
		t.Fatal(err)
	}
	s := stateOf(t, view.Programs, weeklySequentialCal)
	if s.Status != db.RewardStatusCompleted || s.CanClaim || s.NextDay != 0 || s.CurrentDay != 7 || s.ClaimedDays != 7 {
		t.Fatalf("Sunday, all seven: %+v", s)
	}
	if day, status, _, _, ok := f.progressRow(u.ID, weeklySequentialCal, kolkataAt(time.October, 5, 0).UnixMilli()); !ok || day != 7 || status != db.RewardStatusCompleted {
		t.Fatalf("the row: day %d %s", day, status)
	}
	if got := f.wallet(u.ID, "chips"); got != chips+80_000 {
		t.Fatalf("chips %d, want %d", got, chips+80_000)
	}
	if f.wallet(u.ID, "hammer") != hammers+1 || f.wallet(u.ID, "diamond") != diamonds+1 {
		t.Fatalf("hammers %d diamonds %d", f.wallet(u.ID, "hammer"), f.wallet(u.ID, "diamond"))
	}
	if n := f.count(`SELECT count(*) FROM user_emojis ue JOIN emojis e ON e.id = ue.emoji_id WHERE ue.user_id = $1 AND e.name = 'Clapping Hands'`, u.ID); n != 1 {
		t.Fatalf("the emoji: %d ownership rows", n)
	}
	if n := f.count(`SELECT count(*) FROM user_badges WHERE user_id = $1 AND badge_code = 'ROYAL_ACE'`, u.ID); n != 1 {
		t.Fatalf("the badge: %d grants", n)
	}
	if n := f.count(`SELECT count(*) FROM chip_ledger WHERE user_id = $1 AND reason = 'reward_program'`, u.ID); n != 3 {
		t.Fatalf("%d reward_program ledger rows, want the three chip days", n)
	}
	f.reconcile()
}

// The brief's C, WEEKLY_SEQUENTIAL: Day 1, Day 2, Day 3 missed — the next
// login is Day 3; the run never jumps to Day 4.
func TestASequentialLoginProgramWaitsOnTheMissedDay(t *testing.T) {
	f := newFixture(t)
	f.onlyPrograms(weeklySequential)
	id := f.scalar(`SELECT id FROM reward_programs WHERE code = $1`, weeklySequential)
	for day := 1; day <= 7; day++ {
		v := int64(1000 * day)
		f.day(id, day, db.RewardChips, &v, nil)
	}
	u := f.user("sequential")
	clock := &luckyClock{}
	store := f.rewardStore(clock.Now)
	claimAt(t, store, clock, u.ID, kolkataAt(time.October, 5, 9))
	claimAt(t, store, clock, u.ID, kolkataAt(time.October, 6, 9))
	// Wednesday missed; Thursday:
	out := claimAt(t, store, clock, u.ID, kolkataAt(time.October, 8, 9))
	wantGrant(t, grantOf(out, weeklySequential), weeklySequential, 3, db.RewardChips, 3000)
	// Two more days missed; Sunday is Day 4.
	out = claimAt(t, store, clock, u.ID, kolkataAt(time.October, 11, 9))
	wantGrant(t, grantOf(out, weeklySequential), weeklySequential, 4, db.RewardChips, 4000)
	if days := f.claimDays(u.ID, weeklySequential); !sameInts(days, []int{1, 2, 3, 4}) {
		t.Fatalf("claims: %v", days)
	}
	s := stateOf(t, out.Programs, weeklySequential)
	if s.Program.ProgressionType != db.RewardProgressionSequential || s.Program.ResetOnMissedDay || s.ClaimedDays != 4 || s.NextDay != 0 {
		t.Fatalf("Sunday's state: %+v", s)
	}
	f.reconcile()
}

// The same action id again — a retry, a second tap, a second device — gives
// nothing more, and is answered with the claim it repeats.
func TestARetriedClaimIsAnsweredWithTheClaimItRepeats(t *testing.T) {
	f := newFixture(t)
	f.onlyPrograms(weeklyLogin)
	u := f.user("retrier")
	clock := &luckyClock{}
	store := f.rewardStore(clock.Now)
	chips, day1 := f.wallet(u.ID, "chips"), f.seededChips(1)
	first := resultOf(t, claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 5, 9)), weeklyLogin)
	if first.Outcome != db.RewardOutcomeGranted || first.Day != 1 {
		t.Fatalf("the first claim: %+v", first)
	}
	for _, code := range []string{"", weeklyLogin} {
		clock.set(utcAt(2026, time.October, 5, 18))
		out, err := store.Claim(f.ctx, u.ID, code)
		if err != nil {
			t.Fatal(err)
		}
		again := resultOf(t, out, weeklyLogin)
		if len(out.Granted) != 0 || again.Outcome != db.RewardOutcomeAlreadyClaimed || again.Day != 1 ||
			again.RewardType != db.RewardChips || again.RewardValue == nil || *again.RewardValue != day1 || again.ClaimedAt != first.ClaimedAt {
			t.Fatalf("the retry (code %q): %+v %+v", code, out.Granted, again)
		}
	}
	key := db.RewardClaimActionID(u.ID, weeklyLogin, "2026-10-05")
	if n := f.count(`SELECT count(*) FROM chip_ledger WHERE action_id = $1`, key); n != 1 {
		t.Fatalf("%d ledger rows under %s", n, key)
	}
	if got := f.wallet(u.ID, "chips"); got != chips+day1 {
		t.Fatalf("chips %d, want %d once", got, chips+day1)
	}
	f.reconcile()
}

// Claims that name the same program at once, from two pools: one grants, the
// rest are answered "already claimed" with it — one claim row, one ledger
// row, one progress row.
func TestNamedClaimsAtOnceGrantADayOnce(t *testing.T) {
	f := newFixture(t)
	f.onlyPrograms(weeklySequentialCal)
	u := f.user("namedracer")
	clock := &luckyClock{}
	clock.set(kolkataAt(time.October, 5, 9))
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
	results := make(chan db.RewardClaimResult, callers)
	errs := make(chan error, callers)
	for i := 0; i < callers; i++ {
		store := stores[i%len(stores)]
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			out, err := store.Claim(context.Background(), u.ID, weeklySequentialCal)
			if err != nil {
				errs <- err
				return
			}
			results <- out.Results[0]
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
	for r := range results {
		switch r.Outcome {
		case db.RewardOutcomeGranted:
			granted++
		case db.RewardOutcomeAlreadyClaimed:
			if r.Day != 1 || r.RewardType != db.RewardChips {
				t.Fatalf("an already-claimed answer without the claim: %+v", r)
			}
		default:
			t.Fatalf("outcome %s", r.Outcome)
		}
	}
	if granted != 1 {
		t.Fatalf("%d grants across %d callers, want 1", granted, callers)
	}
	if n := f.count(`SELECT count(*) FROM user_reward_claims WHERE user_id = $1`, u.ID); n != 1 {
		t.Fatalf("%d claims", n)
	}
	if n := f.count(`SELECT count(*) FROM user_reward_progress WHERE user_id = $1`, u.ID); n != 1 {
		t.Fatalf("%d progress rows", n)
	}
	if got := f.wallet(u.ID, "chips"); got != chips+10_000 {
		t.Fatalf("chips %d", got)
	}
	f.reconcile()
}

// A claim that names a program refuses one switched off, one nobody declared,
// and a campaign outside its window — before or after it — and none of them
// is in the look or a claim of every program.
func TestANamedClaimOfAProgramThatIsNotRunningIsRefused(t *testing.T) {
	f := newFixture(t)
	f.onlyPrograms(weeklyLogin) // WEEKLY_SEQUENTIAL_CAL, among others, is switched off
	u := f.user("refused")
	clock := &luckyClock{}
	clock.set(utcAt(2026, time.October, 5, 9))
	store := f.rewardStore(clock.Now)
	future := f.program("NOVEMBER_ONLY", db.RewardModeCalendar, db.RewardPeriodMonthly, "UTC", 1, false)
	past := f.program("SEPTEMBER_ONLY", db.RewardModeCalendar, db.RewardPeriodMonthly, "UTC", 1, false)
	v := int64(100)
	f.day(future, 1, db.RewardChips, &v, nil)
	f.day(past, 1, db.RewardChips, &v, nil)
	f.exec(`UPDATE reward_programs SET starts_at = $2 WHERE id = $1`, future, utcAt(2026, time.November, 1, 0).UnixMilli())
	f.exec(`UPDATE reward_programs SET ends_at = $2 WHERE id = $1`, past, utcAt(2026, time.October, 1, 0).UnixMilli()-1)

	for code, want := range map[string]error{
		"NO_SUCH_PROGRAM":   db.ErrRewardProgramNotFound,
		weeklySequentialCal: db.ErrRewardProgramNotFound,
		"NOVEMBER_ONLY":     db.ErrRewardProgramNotRunning,
		"SEPTEMBER_ONLY":    db.ErrRewardProgramNotRunning,
	} {
		if _, err := store.Claim(f.ctx, u.ID, code); !errors.Is(err, want) {
			t.Errorf("%s: %v, want %v", code, err, want)
		}
	}
	out, err := store.Claim(f.ctx, u.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(out.Results) != 1 || out.Results[0].ProgramCode != weeklyLogin || len(out.Programs) != 1 {
		t.Fatalf("every program: %+v", out.Results)
	}
	if n := f.count(`SELECT count(*) FROM user_reward_claims WHERE user_id = $1`, u.ID); n != 1 {
		t.Fatalf("%d claims", n)
	}
	f.reconcile()
}

// The progress row is created at the player's first look in a period, follows
// every claim, and is written again only when the standing changes.
func TestTheProgressRowIsCreatedAtTheFirstLookAndFollowsEveryClaim(t *testing.T) {
	f := newFixture(t)
	f.onlyPrograms(weeklyLogin)
	u := f.user("progress")
	clock := &luckyClock{}
	store := f.rewardStore(clock.Now)
	monday := utcAt(2026, time.October, 5, 0).UnixMilli()
	if _, _, _, _, ok := f.progressRow(u.ID, weeklyLogin, monday); ok {
		t.Fatal("a row before the player touched the program")
	}
	clock.set(utcAt(2026, time.October, 5, 8))
	if _, err := store.State(f.ctx, u.ID); err != nil {
		t.Fatal(err)
	}
	day, status, last, updated, ok := f.progressRow(u.ID, weeklyLogin, monday)
	if !ok || day != 1 || status != db.RewardStatusActive || last != 0 {
		t.Fatalf("after the first look: day %d %s last %d (ok %v)", day, status, last, ok)
	}
	clock.set(utcAt(2026, time.October, 5, 9))
	if _, err := store.State(f.ctx, u.ID); err != nil {
		t.Fatal(err)
	}
	if _, _, _, again, _ := f.progressRow(u.ID, weeklyLogin, monday); again != updated {
		t.Fatalf("a look that changed nothing wrote the row: updated_at %d → %d", updated, again)
	}
	out := claimAt(t, store, clock, u.ID, utcAt(2026, time.October, 5, 10))
	claimedAt := resultOf(t, out, weeklyLogin).ClaimedAt
	if day, status, last, _, _ := f.progressRow(u.ID, weeklyLogin, monday); day != 2 || status != db.RewardStatusActive || last != claimedAt {
		t.Fatalf("after Day 1: day %d %s last %d", day, status, last)
	}
	// Wednesday after a missed Tuesday: the RESET streak's next day is Day 1
	// again, and the first look says so.
	clock.set(utcAt(2026, time.October, 7, 9))
	if _, err := store.State(f.ctx, u.ID); err != nil {
		t.Fatal(err)
	}
	if day, status, last, _, _ := f.progressRow(u.ID, weeklyLogin, monday); day != 1 || status != db.RewardStatusActive || last != claimedAt {
		t.Fatalf("after the reset: day %d %s last %d", day, status, last)
	}
}

// A database from before the progression types — production's, where
// WEEKLY_LOGIN runs — is brought forward by one boot: the column added, every
// program given the progression it already had (a streak that resets RESET,
// everything else SEQUENTIAL), the progress table created, the brief's two
// programs seeded inactive. The fill runs once: an owner's progression set
// afterwards survives every later boot.
func TestABootGivesAnOlderDatabasesProgramsTheProgressionTheyHad(t *testing.T) {
	older := dbtest.Open(t, "progression")
	ctx := context.Background()
	execSQL(t, older, `DELETE FROM reward_program_rewards WHERE program_id IN (SELECT id FROM reward_programs WHERE code IN ('WEEKLY_SEQUENTIAL', 'WEEKLY_SEQUENTIAL_CAL'))`)
	execSQL(t, older, `DELETE FROM reward_programs WHERE code IN ('WEEKLY_SEQUENTIAL', 'WEEKLY_SEQUENTIAL_CAL')`)
	// A login streak the owner had made not reset.
	execSQL(t, older, `UPDATE reward_programs SET reset_on_missed_day = FALSE WHERE code = 'MONTHLY_LOGIN'`)
	execSQL(t, older, `ALTER TABLE reward_programs DROP COLUMN progression_type`)
	execSQL(t, older, `DROP TABLE user_reward_progress`)

	boot := func(why string) *db.DB {
		t.Helper()
		bootCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
		defer cancel()
		d, err := db.Open(bootCtx, db.Options{URL: testURL(), Schema: older.Schema, PoolMax: 2})
		if err != nil {
			t.Fatalf("%s: %v", why, err)
		}
		t.Cleanup(d.Close)
		return d
	}
	progression := func(d *db.DB, code string) string {
		t.Helper()
		var s string
		if err := d.Pool.QueryRow(ctx, `SELECT progression_type FROM reward_programs WHERE code = $1`, code).Scan(&s); err != nil {
			t.Fatalf("%s: %v", code, err)
		}
		return s
	}

	d := boot("the boot that brings the database forward")
	for code, want := range map[string]string{
		"WEEKLY_LOGIN": "RESET", "MONTHLY_LOGIN": "SEQUENTIAL", "WEEKLY_CALENDAR": "SEQUENTIAL", "MONTHLY_CALENDAR": "SEQUENTIAL",
		"WEEKLY_SEQUENTIAL": "SEQUENTIAL", "WEEKLY_SEQUENTIAL_CAL": "BREAK",
	} {
		if got := progression(d, code); got != want {
			t.Errorf("%s: %s, want %s", code, got, want)
		}
	}
	if n := countOf(t, d, `SELECT count(*) FROM reward_programs WHERE code IN ('WEEKLY_SEQUENTIAL', 'WEEKLY_SEQUENTIAL_CAL') AND is_active`); n != 0 {
		t.Errorf("%d of the brief's programs arrived active", n)
	}
	if n := countOf(t, d, `SELECT count(*) FROM reward_program_rewards r JOIN reward_programs p ON p.id = r.program_id WHERE p.code = 'WEEKLY_SEQUENTIAL_CAL'`); n != 7 {
		t.Errorf("WEEKLY_SEQUENTIAL_CAL arrived with %d days", n)
	}
	if n := countOf(t, d, `SELECT count(*) FROM information_schema.tables WHERE table_schema = $1 AND table_name = 'user_reward_progress'`, d.Schema); n != 1 {
		t.Error("user_reward_progress was not created")
	}
	// The owner's choice afterwards is never undone by a boot.
	execSQL(t, d, `UPDATE reward_programs SET progression_type = 'BREAK' WHERE code = 'WEEKLY_CALENDAR'`)
	d = boot("a later boot")
	if got := progression(d, "WEEKLY_CALENDAR"); got != "BREAK" {
		t.Fatalf("an owner's BREAK became %s at the next boot", got)
	}
}
