package db

import "time"

// The progression engine of the reward programs (owner, 1 Oct 2026: "Build a
// generic reward engine that supports RESET, SEQUENTIAL and BREAK … and
// supports WEEKLY and MONTHLY … and two modes, LOGIN and CALENDAR. mode =
// WHAT triggers progress, progression_type = HOW progress behaves"). Pure:
// it reads a program's rules, the period, the player's claims of that period
// and today, and answers where the player stands — the ONE statement of the
// rules, which the look (State), the claim (claimOne) and the progress row
// (user_reward_progress) all take their figures from.
//
// The two axes:
//
//	mode decides the DAY NUMBER a claim counts as —
//	  LOGIN_STREAK  (the brief's LOGIN) the run's count: the first claim of a
//	                run is Day 1, each claim after it the next day;
//	  CALENDAR      the date's place in the period: Monday is Day 1 of a
//	                Monday week, the 10th is Day 10 of a month — and a
//	                CALENDAR program's days are REQUIRED from the first day
//	                it runs in the period, where a LOGIN program's are
//	                required only from the run's first claim.
//
//	progression_type decides what a MISSED required day does —
//	  RESET       the run starts again: a LOGIN program's next claim is Day 1
//	              (Mon Day 1, Tue Day 2, Wed Day 3, Thu missed, Fri Day 1);
//	              a CALENDAR program's day is still its date, and only the
//	              run it shows as "N day streak" starts again;
//	  SEQUENTIAL  nothing is lost: a LOGIN program's next claim is the next
//	              unclaimed day (Day 1, Day 2, Day 3 missed, Day 3 the day
//	              after — never Day 4); a CALENDAR program's missed date is
//	              simply missed and the calendar goes on (the program of
//	              30 Sep 2026 that "CALENDAR" meant until now);
//	  BREAK       the cycle is broken: nothing more can be claimed until the
//	              next period starts fresh (CALENDAR: Mon Day 1, Tue Day 2,
//	              Wed missed, Thu BROKEN; next Monday Day 1 again).
//
// One claim a program a calendar day, whatever the rules (the unique index
// on user_reward_claims, and RewardClaimActionID), so a run never moves more
// than a day a day, and a period never holds more claims than it has days.

// Progression types (reward_programs.progression_type).
const (
	RewardProgressionReset      = "RESET"
	RewardProgressionSequential = "SEQUENTIAL"
	RewardProgressionBreak      = "BREAK"
)

// Where a player stands in a program's current period
// (user_reward_progress.status, and `status` on the wire).
const (
	// RewardStatusActive: the cycle runs — a day can be collected today, or
	// was, and the next waits for tomorrow.
	RewardStatusActive = "ACTIVE"
	// RewardStatusCompleted: every day of the period has been collected.
	RewardStatusCompleted = "COMPLETED"
	// RewardStatusBroken: a BREAK program's required day was missed; nothing
	// more can be claimed until the next period.
	RewardStatusBroken = "BROKEN"
)

// A day's standing on the wire (`rewards[].state`): the server's verdict, so
// the app draws it and never works it out.
const (
	RewardDayClaimed   = "CLAIMED"
	RewardDayAvailable = "AVAILABLE"
	RewardDayMissed    = "MISSED"
	RewardDayLocked    = "LOCKED"
)

// rewardRules is what the engine reads of a program.
type rewardRules struct {
	Mode        string // RewardModeLoginStreak | RewardModeCalendar
	Progression string // RewardProgressionReset | Sequential | Break
	// FirstDay and LastDay are the first and last dates the program runs in
	// the period: the period's own first and last day, narrowed by a
	// campaign's starts_at / ends_at.
	FirstDay, LastDay civilDate
}

// rewardProgress is a player's standing in one program's current period.
type rewardProgress struct {
	Status string
	// CurrentDay is the day today's claim counts — or counted — as while
	// ACTIVE; the day that was missed while BROKEN; the last day while
	// COMPLETED.
	CurrentDay   int
	ClaimedToday bool
	// CanClaim: a claim now would grant CurrentDay.
	CanClaim bool
	// NextDay is the day the next claim counts as — today's while CanClaim,
	// tomorrow's once today is claimed and the cycle goes on — 0 when no
	// claim is left in this period.
	NextDay int
	// Missed is the day a BROKEN cycle missed (CurrentDay), 0 otherwise.
	Missed int
	// RunDays is what the app shows as the run: a RESET program's current
	// unbroken run ("3 day streak"), every other program's days claimed this
	// period.
	RunDays int
	// Claimed are the days that count as collected now: a LOGIN program's
	// current run (Days 1..RunDays — after a RESET's missed day none, though
	// the history keeps them), a CALENDAR program's claimed dates.
	Claimed map[int]bool
	// LastActivity is the latest claim's claimed_at (epoch ms), 0 for none.
	LastActivity int64
}

// position is a date's day number in the period: 1 for its first day.
func (p rewardPeriod) position(d civilDate) int { return d.daysSince(p.Start) + 1 }

// dateOf is the date of day k of the period.
func (p rewardPeriod) dateOf(k int) civilDate { return p.Start.plusDays(k - 1) }

// before is whether c falls before o.
func (c civilDate) before(o civilDate) bool { return c.daysSince(o) < 0 }

// progressAt works out where a player stands: the program's rules, its
// current period, and the player's claims of THAT period, newest first (one
// a date; loadClaims' order). Nothing here reads a clock: today is
// period.Today.
func progressAt(r rewardRules, period rewardPeriod, claims []claimRow) rewardProgress {
	if r.Mode == RewardModeCalendar {
		return calendarProgress(r, period, claims)
	}
	return loginProgress(r, period, claims)
}

// loginProgress is a LOGIN_STREAK program: the day number is the run's count.
func loginProgress(r rewardRules, period rewardPeriod, claims []claimRow) rewardProgress {
	today := period.Today
	ladder := period.Days
	p := rewardProgress{Status: RewardStatusActive, Claimed: map[int]bool{}}
	tomorrow := today.plusDays(1)
	goesOn := !r.LastDay.before(tomorrow) // the program still runs tomorrow, in this period

	if len(claims) == 0 {
		// No run yet this period: Day 1, whatever the progression — a LOGIN
		// program's days are required only from the run's first claim.
		p.CurrentDay, p.CanClaim, p.NextDay = 1, true, 1
		return p
	}
	latest := claims[0]
	p.LastActivity = latest.ClaimedAt
	mark := func(run int) {
		p.RunDays = run
		for k := 1; k <= run; k++ {
			p.Claimed[k] = true
		}
	}
	if latest.Date.equal(today) {
		p.ClaimedToday = true
		p.CurrentDay = latest.Day
		mark(latest.Day)
		switch {
		case latest.Day >= ladder:
			p.Status = RewardStatusCompleted
		case goesOn:
			p.NextDay = latest.Day + 1
		}
		return p
	}
	if today.daysSince(latest.Date) == 1 {
		// Yesterday: the run goes on.
		mark(latest.Day)
		p.CurrentDay = latest.Day + 1
	} else {
		// A required day — every day since the latest claim — was missed.
		switch r.Progression {
		case RewardProgressionReset:
			// The run starts again; the days before it are history.
			p.CurrentDay = 1
		case RewardProgressionBreak:
			mark(latest.Day)
			p.Status = RewardStatusBroken
			p.CurrentDay = latest.Day + 1
			p.Missed = p.CurrentDay
			return p
		default: // SEQUENTIAL: the next unclaimed day waits
			mark(latest.Day)
			p.CurrentDay = latest.Day + 1
		}
	}
	if p.CurrentDay > ladder {
		// Unreachable with one claim a day, kept as a floor.
		p.Status, p.CurrentDay = RewardStatusCompleted, ladder
		return p
	}
	p.CanClaim, p.NextDay = true, p.CurrentDay
	return p
}

// calendarProgress is a CALENDAR program: the day number is the date's place
// in the period, and every date from the first the program runs is required.
func calendarProgress(r rewardRules, period rewardPeriod, claims []claimRow) rewardProgress {
	today := period.Today
	t := period.position(today)
	p := rewardProgress{Status: RewardStatusActive, CurrentDay: t, Claimed: map[int]bool{}}
	byDate := make(map[civilDate]bool, len(claims))
	for _, c := range claims {
		byDate[c.Date] = true
		p.Claimed[c.Day] = true
	}
	if len(claims) > 0 {
		p.LastActivity = claims[0].ClaimedAt
	}
	p.ClaimedToday = byDate[today]

	// The required dates before today: from the first day the program runs.
	firstMissed := 0
	run := 0
	for d := r.FirstDay; d.before(today); d = d.plusDays(1) {
		if byDate[d] {
			run++
			continue
		}
		if firstMissed == 0 {
			firstMissed = period.position(d)
		}
		run = 0 // a RESET run starts again after the miss
	}
	if p.ClaimedToday {
		run++
	}

	if firstMissed > 0 && r.Progression == RewardProgressionBreak {
		p.Status = RewardStatusBroken
		p.CurrentDay, p.Missed = firstMissed, firstMissed
		p.RunDays = len(claims)
		return p
	}
	if r.Progression == RewardProgressionReset {
		p.RunDays = run
	} else {
		p.RunDays = len(claims)
	}

	tomorrow := today.plusDays(1)
	goesOn := !r.LastDay.before(tomorrow)
	if p.ClaimedToday {
		// Every date the program runs this period collected: complete.
		if firstMissed == 0 && !goesOn {
			p.Status = RewardStatusCompleted
		}
		if goesOn {
			p.NextDay = t + 1
		}
		return p
	}
	p.CanClaim, p.NextDay = true, t
	return p
}

// dayStateOf is day k's standing for the app: CLAIMED, AVAILABLE (today's,
// collectable now), MISSED (a required day that was not claimed: a BROKEN
// cycle's missed day, or a CALENDAR date gone by unclaimed) or LOCKED (not
// reached — or no longer reachable).
func dayStateOf(r rewardRules, period rewardPeriod, p rewardProgress, k int) string {
	if p.Claimed[k] {
		return RewardDayClaimed
	}
	if p.Status == RewardStatusBroken {
		if k == p.Missed {
			return RewardDayMissed
		}
		return RewardDayLocked
	}
	if p.CanClaim && k == p.CurrentDay {
		return RewardDayAvailable
	}
	if r.Mode == RewardModeCalendar {
		d := period.dateOf(k)
		if d.before(period.Today) && !d.before(r.FirstDay) {
			return RewardDayMissed
		}
	}
	return RewardDayLocked
}

// progressRowDay is user_reward_progress.current_day for a standing (the
// brief's "next reward day the user should receive"): today's while it can
// be claimed, the day after today's once it is claimed, the day that was
// missed when BROKEN, the last day when COMPLETED.
func progressRowDay(p rewardProgress) int {
	switch {
	case p.Status != RewardStatusActive:
		return p.CurrentDay
	case p.ClaimedToday:
		return p.CurrentDay + 1
	default:
		return p.CurrentDay
	}
}

// runsBetween narrows a period to the dates a program runs in it: its
// campaign's starts_at and ends_at (epoch ms; nil for none), read in its zone.
func runsBetween(period rewardPeriod, loc *time.Location, startsAt, endsAt *int64) (first, last civilDate) {
	first, last = period.Start, period.End
	if startsAt != nil {
		if d := civilOf(time.UnixMilli(*startsAt).In(loc)); first.before(d) {
			first = d
		}
	}
	if endsAt != nil {
		if d := civilOf(time.UnixMilli(*endsAt).In(loc)); d.before(last) {
			last = d
		}
	}
	return first, last
}
