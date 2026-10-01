package db

import (
	"testing"
	"time"
)

// The progression engine (owner, 1 Oct 2026: RESET, SEQUENTIAL and BREAK, over
// LOGIN and CALENDAR, WEEKLY and MONTHLY), without a database: a program's
// rules, its period and a player's claims in, the standing out. 5 Oct 2026 is
// a Monday.

// periodAt is the period of a program of that type, zone and week start at
// an instant.
func periodAt(t *testing.T, periodType string, zone string, instant time.Time) rewardPeriod {
	t.Helper()
	loc, err := time.LoadLocation(zone)
	if err != nil {
		t.Fatal(err)
	}
	p, err := periodOf(periodType, 1, loc, instant)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// whole is a program running through the whole period.
func whole(mode, progression string, p rewardPeriod) rewardRules {
	return rewardRules{Mode: mode, Progression: progression, FirstDay: p.Start, LastDay: p.End}
}

// claimsOn are claims on the given dates of October 2026, with their day
// numbers, newest first: pairs of (date, day).
func claimsOn(pairs ...int) []claimRow {
	var out []claimRow
	for i := len(pairs) - 2; i >= 0; i -= 2 {
		out = append(out, claimRow{Date: civilDate{2026, time.October, pairs[i]}, Day: pairs[i+1], ClaimedAt: int64(pairs[i]) * 1000})
	}
	return out
}

// statesOf are the standings of days 1..n.
func statesOf(r rewardRules, period rewardPeriod, p rewardProgress, n int) []string {
	out := make([]string, n)
	for k := 1; k <= n; k++ {
		out[k-1] = dayStateOf(r, period, p, k)
	}
	return out
}

func sameStates(a, b []string) bool {
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

func TestAWeeklyLoginStreakGoesBackToDayOneAfterAMissedDay(t *testing.T) {
	// The brief's A: Monday Day 1, Tuesday Day 2, Wednesday Day 3, Thursday
	// missed, Friday Day 1.
	fri := periodAt(t, RewardPeriodWeekly, "Asia/Kolkata", at("Asia/Kolkata", 2026, time.October, 9, 10))
	r := whole(RewardModeLoginStreak, RewardProgressionReset, fri)
	p := progressAt(r, fri, claimsOn(5, 1, 6, 2, 7, 3))
	if p.Status != RewardStatusActive || p.CurrentDay != 1 || !p.CanClaim || p.NextDay != 1 || p.RunDays != 0 || len(p.Claimed) != 0 {
		t.Fatalf("Friday after a missed Thursday: %+v", p)
	}
	want := []string{RewardDayAvailable, RewardDayLocked, RewardDayLocked, RewardDayLocked, RewardDayLocked, RewardDayLocked, RewardDayLocked}
	if got := statesOf(r, fri, p, 7); !sameStates(got, want) {
		t.Fatalf("the days after the reset: %v", got)
	}
	// Claimed on Friday, the run is Day 1 again, and Saturday is Day 2.
	sat := periodAt(t, RewardPeriodWeekly, "Asia/Kolkata", at("Asia/Kolkata", 2026, time.October, 10, 10))
	p = progressAt(r, sat, claimsOn(5, 1, 6, 2, 7, 3, 9, 1))
	if p.CurrentDay != 2 || !p.CanClaim || p.RunDays != 1 || !p.Claimed[1] || p.Claimed[2] {
		t.Fatalf("Saturday after Friday's Day 1: %+v", p)
	}
}

func TestAMonthlyLoginStreakResetsAndNeverCrossesTheMonth(t *testing.T) {
	oct5 := periodAt(t, RewardPeriodMonthly, "UTC", at("UTC", 2026, time.October, 5, 12))
	r := whole(RewardModeLoginStreak, RewardProgressionReset, oct5)
	if oct5.Days != 31 || oct5.Start != (civilDate{2026, time.October, 1}) {
		t.Fatalf("October: %+v", oct5)
	}
	// 1, 2, 3 claimed, the 4th missed: the 5th is Day 1.
	if p := progressAt(r, oct5, claimsOn(1, 1, 2, 2, 3, 3)); p.CurrentDay != 1 || !p.CanClaim {
		t.Fatalf("the 5th after a missed 4th: %+v", p)
	}
	// The 31st claimed as Day 31 of an unbroken month: complete.
	var month []int
	for d := 1; d <= 31; d++ {
		month = append(month, d, d)
	}
	oct31 := periodAt(t, RewardPeriodMonthly, "UTC", at("UTC", 2026, time.October, 31, 23))
	if p := progressAt(r, oct31, claimsOn(month...)); p.Status != RewardStatusCompleted || p.CanClaim || p.NextDay != 0 {
		t.Fatalf("October done: %+v", p)
	}
	// November 1st is a new period: its claims are none, and it is Day 1.
	nov1 := periodAt(t, RewardPeriodMonthly, "UTC", at("UTC", 2026, time.November, 1, 0))
	if nov1.StartMs == oct31.StartMs || nov1.Days != 30 {
		t.Fatalf("November: %+v", nov1)
	}
	if p := progressAt(r, nov1, nil); p.CurrentDay != 1 || !p.CanClaim || p.Status != RewardStatusActive {
		t.Fatalf("November 1st: %+v", p)
	}
}

func TestASequentialRunNeverSkipsAReward(t *testing.T) {
	// The brief's C: Day 1, Day 2, Day 3 missed — the next login is Day 3,
	// never Day 4.
	thu := periodAt(t, RewardPeriodWeekly, "Asia/Kolkata", at("Asia/Kolkata", 2026, time.October, 8, 10))
	r := whole(RewardModeLoginStreak, RewardProgressionSequential, thu)
	p := progressAt(r, thu, claimsOn(5, 1, 6, 2))
	if p.Status != RewardStatusActive || p.CurrentDay != 3 || !p.CanClaim || p.RunDays != 2 || !p.Claimed[1] || !p.Claimed[2] {
		t.Fatalf("Thursday after a missed Wednesday: %+v", p)
	}
	want := []string{RewardDayClaimed, RewardDayClaimed, RewardDayAvailable, RewardDayLocked, RewardDayLocked, RewardDayLocked, RewardDayLocked}
	if got := statesOf(r, thu, p, 7); !sameStates(got, want) {
		t.Fatalf("the days: %v", got)
	}
	// Two days missed after it: still Day 4 next, nothing lost.
	sun := periodAt(t, RewardPeriodWeekly, "Asia/Kolkata", at("Asia/Kolkata", 2026, time.October, 11, 10))
	if p = progressAt(r, sun, claimsOn(5, 1, 6, 2, 8, 3)); p.CurrentDay != 4 || !p.CanClaim {
		t.Fatalf("Sunday: %+v", p)
	}
}

func TestABreakCalendarWeekIsBrokenByAMissedDayUntilTheNextWeek(t *testing.T) {
	// The brief's D, WEEKLY_SEQUENTIAL_CAL in Asia/Kolkata: Monday Day 1,
	// Tuesday Day 2, Wednesday missed — Thursday to Sunday BROKEN at Day 3;
	// next Monday Day 1 again.
	claims := claimsOn(5, 1, 6, 2)
	want := []string{RewardDayClaimed, RewardDayClaimed, RewardDayMissed, RewardDayLocked, RewardDayLocked, RewardDayLocked, RewardDayLocked}
	for day := 8; day <= 11; day++ {
		period := periodAt(t, RewardPeriodWeekly, "Asia/Kolkata", at("Asia/Kolkata", 2026, time.October, day, 9))
		r := whole(RewardModeCalendar, RewardProgressionBreak, period)
		p := progressAt(r, period, claims)
		if p.Status != RewardStatusBroken || p.CurrentDay != 3 || p.Missed != 3 || p.CanClaim || p.NextDay != 0 {
			t.Fatalf("October %d: %+v", day, p)
		}
		if got := statesOf(r, period, p, 7); !sameStates(got, want) {
			t.Fatalf("October %d's days: %v", day, got)
		}
		if progressRowDay(p) != 3 {
			t.Fatalf("the progress row says Day %d", progressRowDay(p))
		}
	}
	// Wednesday itself, before it is claimed, is still open.
	wed := periodAt(t, RewardPeriodWeekly, "Asia/Kolkata", at("Asia/Kolkata", 2026, time.October, 7, 9))
	if p := progressAt(whole(RewardModeCalendar, RewardProgressionBreak, wed), wed, claims); p.Status != RewardStatusActive || p.CurrentDay != 3 || !p.CanClaim {
		t.Fatalf("Wednesday: %+v", p)
	}
	// The next Monday is a new period: fresh, Day 1.
	mon := periodAt(t, RewardPeriodWeekly, "Asia/Kolkata", at("Asia/Kolkata", 2026, time.October, 12, 0))
	if mon.Start != (civilDate{2026, time.October, 12}) {
		t.Fatalf("the next week starts on the 12th: %+v", mon)
	}
	if p := progressAt(whole(RewardModeCalendar, RewardProgressionBreak, mon), mon, nil); p.Status != RewardStatusActive || p.CurrentDay != 1 || !p.CanClaim {
		t.Fatalf("the next Monday: %+v", p)
	}
}

func TestABreakCalendarOpenedFirstOnWednesdayIsAlreadyBroken(t *testing.T) {
	// A CALENDAR program's days are required from the period's first: a
	// player whose first look is Wednesday has missed Monday.
	wed := periodAt(t, RewardPeriodWeekly, "UTC", at("UTC", 2026, time.October, 7, 9))
	p := progressAt(whole(RewardModeCalendar, RewardProgressionBreak, wed), wed, nil)
	if p.Status != RewardStatusBroken || p.Missed != 1 || p.CanClaim {
		t.Fatalf("first look on Wednesday: %+v", p)
	}
	// A LOGIN program's are required only from the run's first claim.
	if p := progressAt(whole(RewardModeLoginStreak, RewardProgressionBreak, wed), wed, nil); p.Status != RewardStatusActive || p.CurrentDay != 1 || !p.CanClaim {
		t.Fatalf("a login break program on Wednesday: %+v", p)
	}
}

func TestALoginBreakRunStartsAtItsFirstClaimAndBreaksOnAMiss(t *testing.T) {
	thu := periodAt(t, RewardPeriodWeekly, "UTC", at("UTC", 2026, time.October, 8, 9))
	r := whole(RewardModeLoginStreak, RewardProgressionBreak, thu)
	if p := progressAt(r, thu, claimsOn(7, 1)); p.CurrentDay != 2 || !p.CanClaim {
		t.Fatalf("Thursday after Wednesday's first claim: %+v", p)
	}
	sat := periodAt(t, RewardPeriodWeekly, "UTC", at("UTC", 2026, time.October, 10, 9))
	p := progressAt(r, sat, claimsOn(7, 1, 8, 2))
	if p.Status != RewardStatusBroken || p.Missed != 3 || p.CanClaim || p.RunDays != 2 {
		t.Fatalf("Saturday after a missed Friday: %+v", p)
	}
}

func TestACalendarCampaignRequiresOnlyTheDaysItRuns(t *testing.T) {
	// Starting on Wednesday, a CALENDAR+BREAK campaign's Monday and Tuesday
	// were never required: Wednesday is its Day 3, the date's place.
	wed := periodAt(t, RewardPeriodWeekly, "UTC", at("UTC", 2026, time.October, 7, 9))
	r := rewardRules{Mode: RewardModeCalendar, Progression: RewardProgressionBreak,
		FirstDay: civilDate{2026, time.October, 7}, LastDay: wed.End}
	p := progressAt(r, wed, nil)
	if p.Status != RewardStatusActive || p.CurrentDay != 3 || !p.CanClaim {
		t.Fatalf("the campaign's first day: %+v", p)
	}
	if got := statesOf(r, wed, p, 3); !sameStates(got, []string{RewardDayLocked, RewardDayLocked, RewardDayAvailable}) {
		t.Fatalf("the days before it ran: %v", got)
	}
	// Ending on Thursday: claimed on Thursday, nothing is next — and the
	// campaign is complete, every day it ran collected.
	thu := periodAt(t, RewardPeriodWeekly, "UTC", at("UTC", 2026, time.October, 8, 9))
	r.LastDay = civilDate{2026, time.October, 8}
	p = progressAt(r, thu, claimsOn(7, 3, 8, 4))
	if p.NextDay != 0 || p.Status != RewardStatusCompleted || p.CanClaim {
		t.Fatalf("the campaign's last day, claimed: %+v", p)
	}
}

func TestTheWeekTurnsAtMidnightInTheProgramsOwnZone(t *testing.T) {
	// 18:29 UTC on Sunday 11 Oct is 23:59 in Kolkata: still the week of the
	// 5th there. 18:30 UTC is midnight Monday the 12th in Kolkata — a new
	// week — while a UTC program is still on its Sunday.
	before := time.Date(2026, time.October, 11, 18, 29, 0, 0, time.UTC)
	after := time.Date(2026, time.October, 11, 18, 30, 0, 0, time.UTC)
	k1 := periodAt(t, RewardPeriodWeekly, "Asia/Kolkata", before)
	k2 := periodAt(t, RewardPeriodWeekly, "Asia/Kolkata", after)
	u2 := periodAt(t, RewardPeriodWeekly, "UTC", after)
	if k1.Start != (civilDate{2026, time.October, 5}) || k1.DayOfPeriod != 7 {
		t.Fatalf("23:59 in Kolkata: %+v", k1)
	}
	if k2.Start != (civilDate{2026, time.October, 12}) || k2.DayOfPeriod != 1 || k2.StartMs != after.UnixMilli() {
		t.Fatalf("midnight in Kolkata: %+v", k2)
	}
	if u2.Start != (civilDate{2026, time.October, 5}) || u2.DayOfPeriod != 7 {
		t.Fatalf("the same instant in UTC: %+v", u2)
	}
	// The run of the old week stays with it: at Kolkata's midnight a new
	// period starts at Day 1, whatever was claimed on Sunday.
	r := whole(RewardModeLoginStreak, RewardProgressionReset, k2)
	if p := progressAt(r, k2, nil); p.CurrentDay != 1 || !p.CanClaim {
		t.Fatalf("Monday 00:00 in Kolkata: %+v", p)
	}
}

func TestFebruaryHasTwentyEightDaysOrTwentyNine(t *testing.T) {
	feb27 := periodAt(t, RewardPeriodMonthly, "Asia/Kolkata", at("Asia/Kolkata", 2027, time.February, 28, 20))
	feb28 := periodAt(t, RewardPeriodMonthly, "Asia/Kolkata", at("Asia/Kolkata", 2028, time.February, 29, 20))
	if feb27.Days != 28 || feb27.End != (civilDate{2027, time.February, 28}) {
		t.Fatalf("February 2027: %+v", feb27)
	}
	if feb28.Days != 29 || feb28.End != (civilDate{2028, time.February, 29}) {
		t.Fatalf("February 2028: %+v", feb28)
	}
	// A monthly calendar collected every day of February 2027 is complete on
	// the 28th: there is no 29th to wait for.
	r := whole(RewardModeCalendar, RewardProgressionSequential, feb27)
	var claims []claimRow
	for d := 28; d >= 1; d-- {
		claims = append(claims, claimRow{Date: civilDate{2027, time.February, d}, Day: d})
	}
	if p := progressAt(r, feb27, claims); p.Status != RewardStatusCompleted || p.NextDay != 0 || p.RunDays != 28 {
		t.Fatalf("all of February 2027: %+v", p)
	}
}

func TestACompletedCycleOffersNothingMore(t *testing.T) {
	sun := periodAt(t, RewardPeriodWeekly, "UTC", at("UTC", 2026, time.October, 11, 20))
	week := claimsOn(5, 1, 6, 2, 7, 3, 8, 4, 9, 5, 10, 6, 11, 7)
	for _, r := range []rewardRules{
		whole(RewardModeLoginStreak, RewardProgressionReset, sun),
		whole(RewardModeLoginStreak, RewardProgressionSequential, sun),
		whole(RewardModeCalendar, RewardProgressionBreak, sun),
	} {
		p := progressAt(r, sun, week)
		if p.Status != RewardStatusCompleted || p.CanClaim || p.NextDay != 0 || p.CurrentDay != 7 || progressRowDay(p) != 7 {
			t.Fatalf("%s %s, all seven: %+v", r.Mode, r.Progression, p)
		}
	}
	// A run that has not reached Day 7 by Sunday is not complete — it simply
	// has no tomorrow in this week.
	r := whole(RewardModeLoginStreak, RewardProgressionReset, sun)
	p := progressAt(r, sun, claimsOn(10, 1, 11, 2))
	if p.Status != RewardStatusActive || p.NextDay != 0 || !p.ClaimedToday || progressRowDay(p) != 3 {
		t.Fatalf("Sunday's Day 2: %+v", p)
	}
}

func TestTheNextDayIsTodaysUntilClaimedThenTomorrows(t *testing.T) {
	wed := periodAt(t, RewardPeriodWeekly, "UTC", at("UTC", 2026, time.October, 7, 9))
	r := whole(RewardModeLoginStreak, RewardProgressionReset, wed)
	if p := progressAt(r, wed, claimsOn(5, 1, 6, 2)); p.NextDay != 3 || progressRowDay(p) != 3 {
		t.Fatalf("Wednesday unclaimed: %+v", p)
	}
	if p := progressAt(r, wed, claimsOn(5, 1, 6, 2, 7, 3)); p.NextDay != 4 || p.CanClaim || progressRowDay(p) != 4 || p.LastActivity != 7000 {
		t.Fatalf("Wednesday claimed: %+v", p)
	}
}
