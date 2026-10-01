package db

import (
	"testing"
	"time"
)

// The reward programs' calendar (owner, 30 Sep 2026), without a database:
// a period is a calendar week from the program's week_start_day, or a
// calendar month — worked out in the program's zone by calendar arithmetic,
// never as a multiple of 86,400,000 ms.

func at(zone string, y int, m time.Month, d, hour int) time.Time {
	loc, err := time.LoadLocation(zone)
	if err != nil {
		panic(err)
	}
	return time.Date(y, m, d, hour, 0, 0, 0, loc)
}

func TestAWeeklyPeriodStartsOnTheProgramsWeekStartDay(t *testing.T) {
	utc := time.UTC
	// 5 Oct 2026 is a Monday. For every week start day and every day of the
	// week after it, the period starts on the last such day, today included.
	for weekStart := 1; weekStart <= 7; weekStart++ {
		for offset := 0; offset < 7; offset++ {
			today := civilDate{2026, time.October, 5 + offset}
			p, err := periodOf(RewardPeriodWeekly, weekStart, utc, today.midnight(utc).Add(13*time.Hour))
			if err != nil {
				t.Fatal(err)
			}
			if p.Start.isoWeekday() != weekStart {
				t.Fatalf("week start %d, today %s: period starts %s (weekday %d)", weekStart, today, p.Start, p.Start.isoWeekday())
			}
			if since := today.daysSince(p.Start); since < 0 || since > 6 || p.DayOfPeriod != since+1 {
				t.Fatalf("week start %d, today %s: starts %s, day %d", weekStart, today, p.Start, p.DayOfPeriod)
			}
			if p.Days != 7 || !p.End.equal(p.Start.plusDays(6)) || p.Today != today {
				t.Fatalf("week start %d, today %s: %+v", weekStart, today, p)
			}
			if p.EndMs-p.StartMs != 7*24*int64(time.Hour/time.Millisecond)-1 {
				t.Fatalf("a UTC week is 7 days less a millisecond, got %d ms", p.EndMs-p.StartMs)
			}
		}
	}
	// Monday-based: a Sunday is day 7 of the week that began the Monday before.
	p, _ := periodOf(RewardPeriodWeekly, 1, utc, at("UTC", 2026, time.October, 11, 23))
	if p.Start != (civilDate{2026, time.October, 5}) || p.DayOfPeriod != 7 {
		t.Fatalf("Sunday 11 Oct 2026 in a Monday week: %+v", p)
	}
	// Sunday-based: that Sunday is day 1 of a new week.
	p, _ = periodOf(RewardPeriodWeekly, 7, utc, at("UTC", 2026, time.October, 11, 0))
	if p.Start != (civilDate{2026, time.October, 11}) || p.DayOfPeriod != 1 {
		t.Fatalf("Sunday 11 Oct 2026 in a Sunday week: %+v", p)
	}
}

func TestAMonthlyPeriodIsTheCalendarMonthWhateverItsLength(t *testing.T) {
	utc := time.UTC
	for _, c := range []struct {
		y    int
		m    time.Month
		days int
	}{
		{2027, time.February, 28}, {2028, time.February, 29}, {2026, time.April, 30}, {2026, time.December, 31},
		{2100, time.February, 28}, {2000, time.February, 29},
	} {
		p, err := periodOf(RewardPeriodMonthly, 1, utc, at("UTC", c.y, c.m, c.days, 23))
		if err != nil {
			t.Fatal(err)
		}
		if p.Days != c.days || p.Start != (civilDate{c.y, c.m, 1}) || p.End != (civilDate{c.y, c.m, c.days}) || p.DayOfPeriod != c.days {
			t.Fatalf("%s %d: %+v", c.m, c.y, p)
		}
		next := civilDate{c.y, c.m + 1, 1}
		if p.EndMs != next.midnight(utc).UnixMilli()-1 {
			t.Fatalf("%s %d ends %d, want the millisecond before %s", c.m, c.y, p.EndMs, next)
		}
	}
	// December ends where January begins.
	p, _ := periodOf(RewardPeriodMonthly, 1, utc, at("UTC", 2026, time.December, 31, 23))
	if p.EndMs != at("UTC", 2027, time.January, 1, 0).UnixMilli()-1 {
		t.Fatalf("December 2026: %+v", p)
	}
}

func TestAPeriodIsReadInTheProgramsZoneNotTheServers(t *testing.T) {
	kolkata, _ := time.LoadLocation("Asia/Kolkata")
	// 19:00 UTC on 31 Oct is already 1 Nov, 00:30 in Kolkata.
	p, err := periodOf(RewardPeriodMonthly, 1, kolkata, time.Date(2026, time.October, 31, 19, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if p.Today != (civilDate{2026, time.November, 1}) || p.DayOfPeriod != 1 || p.Days != 30 {
		t.Fatalf("31 Oct 19:00 UTC in Kolkata: %+v", p)
	}
	if p.StartMs != time.Date(2026, time.November, 1, 0, 0, 0, 0, kolkata).UnixMilli() {
		t.Fatalf("the period starts at Kolkata's midnight, got %d", p.StartMs)
	}
	// An hour earlier it is still 31 Oct there.
	p, _ = periodOf(RewardPeriodMonthly, 1, kolkata, time.Date(2026, time.October, 31, 18, 0, 0, 0, time.UTC))
	if p.Today != (civilDate{2026, time.October, 31}) || p.DayOfPeriod != 31 {
		t.Fatalf("31 Oct 18:00 UTC in Kolkata: %+v", p)
	}
}

func TestAWeekAcrossADaylightSavingChangeIsStillSevenDays(t *testing.T) {
	ny, _ := time.LoadLocation("America/New_York")
	// The clocks go forward on Sunday 14 March 2027: the Monday week holding it
	// is seven calendar days and 167 hours long.
	p, err := periodOf(RewardPeriodWeekly, 1, ny, time.Date(2027, time.March, 10, 12, 0, 0, 0, ny))
	if err != nil {
		t.Fatal(err)
	}
	if p.Start != (civilDate{2027, time.March, 8}) || p.End != (civilDate{2027, time.March, 14}) || p.Days != 7 {
		t.Fatalf("the week of 10 Mar 2027 in New York: %+v", p)
	}
	if hours := (p.EndMs + 1 - p.StartMs) / int64(time.Hour/time.Millisecond); hours != 167 {
		t.Fatalf("a week across the spring change is 167 hours, got %d", hours)
	}
	// Day 7, the Sunday of the change, at what its clocks call noon.
	p, _ = periodOf(RewardPeriodWeekly, 1, ny, time.Date(2027, time.March, 14, 12, 0, 0, 0, ny))
	if p.DayOfPeriod != 7 {
		t.Fatalf("Sunday 14 Mar 2027 is day 7, got %d", p.DayOfPeriod)
	}
}

func TestTheStreakIsReadFromTheLatestClaimNeverTheHighestDay(t *testing.T) {
	d := func(day int) civilDate { return civilDate{2026, time.October, day} }
	claim := func(day, number int) claimRow { return claimRow{Date: d(day), Day: number} }
	period, _ := periodOf(RewardPeriodWeekly, 1, time.UTC, at("UTC", 2026, time.October, 9, 12)) // Friday
	for _, c := range []struct {
		name         string
		claims       []claimRow // newest first
		progression  string
		wantDay      int
		wantClaimed  bool
		wantRun      int
		wantAfterMax bool
	}{
		{"no claim yet", nil, RewardProgressionReset, 1, false, 0, false},
		{"claimed today", []claimRow{claim(9, 3), claim(8, 2), claim(7, 1)}, RewardProgressionReset, 3, true, 3, false},
		{"claimed yesterday", []claimRow{claim(8, 2), claim(7, 1)}, RewardProgressionReset, 3, false, 2, false},
		{"a day missed, resetting", []claimRow{claim(7, 3), claim(6, 2), claim(5, 1)}, RewardProgressionReset, 1, false, 0, true},
		{"a day missed, sequential", []claimRow{claim(7, 3), claim(6, 2), claim(5, 1)}, RewardProgressionSequential, 4, false, 3, false},
		{"back to day 1 after a miss, then today", []claimRow{claim(9, 1), claim(7, 3), claim(6, 2), claim(5, 1)}, RewardProgressionReset, 1, true, 1, true},
	} {
		rules := rewardRules{Mode: RewardModeLoginStreak, Progression: c.progression, FirstDay: period.Start, LastDay: period.End}
		p := progressAt(rules, period, c.claims)
		if p.CurrentDay != c.wantDay || p.ClaimedToday != c.wantClaimed || p.RunDays != c.wantRun {
			t.Errorf("%s: day %d claimed %v run %d, want %d %v %d", c.name, p.CurrentDay, p.ClaimedToday, p.RunDays, c.wantDay, c.wantClaimed, c.wantRun)
		}
		if c.wantAfterMax && p.CurrentDay == 3 {
			t.Errorf("%s: MAX(day_number) would say 3; the streak is %d", c.name, p.CurrentDay)
		}
	}
}

func TestASequentialCalendarDayIsItsPositionAndAMissedDateIsMissed(t *testing.T) {
	utc := time.UTC
	period, _ := periodOf(RewardPeriodWeekly, 1, utc, at("UTC", 2026, time.October, 8, 9)) // Thursday
	rules := rewardRules{Mode: RewardModeCalendar, Progression: RewardProgressionSequential, FirstDay: period.Start, LastDay: period.End}
	claims := []claimRow{{Date: civilDate{2026, time.October, 6}, Day: 2}, {Date: civilDate{2026, time.October, 5}, Day: 1}}
	p := progressAt(rules, period, claims)
	if p.CurrentDay != 4 || p.ClaimedToday || !p.CanClaim || len(p.Claimed) != 2 || !p.Claimed[1] || !p.Claimed[2] || p.Claimed[3] {
		t.Fatalf("Thursday after Mon and Tue: %+v", p)
	}
	if got := dayStateOf(rules, period, p, 3); got != RewardDayMissed {
		t.Fatalf("Wednesday, gone by unclaimed: %s", got)
	}
	claims = append([]claimRow{{Date: civilDate{2026, time.October, 8}, Day: 4}}, claims...)
	if p = progressAt(rules, period, claims); p.CurrentDay != 4 || !p.ClaimedToday || !p.Claimed[4] || p.Status != RewardStatusActive || p.NextDay != 5 {
		t.Fatalf("Thursday claimed: %+v", p)
	}
}

func TestTheClaimKeyIsOnePerPlayerProgramAndDay(t *testing.T) {
	if got := RewardClaimActionID("u1", "WEEKLY_LOGIN", "2026-10-05"); got != "reward:u1:WEEKLY_LOGIN:2026-10-05" {
		t.Fatalf("the key: %s", got)
	}
	if civilOf(time.Date(2026, time.October, 5, 23, 59, 0, 0, time.UTC)).String() != "2026-10-05" {
		t.Fatal("a civil date is written 2006-01-02")
	}
	if d, err := parseCivil("2028-02-29"); err != nil || d != (civilDate{2028, time.February, 29}) || d.plusDays(1) != (civilDate{2028, time.March, 1}) {
		t.Fatalf("parse and step: %v %v", d, err)
	}
}
