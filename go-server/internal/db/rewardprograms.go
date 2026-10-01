package db

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// The reward programs (owner, 30 Sep 2026: "a unified REWARD PROGRAM system
// that supports both LOGIN STREAK rewards and CALENDAR rewards, with WEEKLY
// and MONTHLY periods"; and 1 Oct 2026: "a generic reward engine that
// supports RESET, SEQUENTIAL and BREAK"; V1.0.0's REWARD PROGRAMS section).
// A program is a MODE, a PROGRESSION TYPE and a PERIOD TYPE — what decides a
// claim's day number, what a missed day does (rewardprogress.go states both),
// and the calendar week (from week_start_day) or month it runs over, in the
// program's own timezone. One set of tables, one store, for every program —
// and for any campaign an owner adds as rows.
const (
	// RewardModeLoginStreak is the brief's LOGIN: the day number is the
	// run's count. The stored and wire value keeps the name it was given on
	// 30 Sep 2026 — every installed app decides "streak" by it.
	RewardModeLoginStreak = "LOGIN_STREAK"
	// RewardModeCalendar: the day number is the date's place in the period.
	RewardModeCalendar  = "CALENDAR"
	RewardPeriodWeekly  = "WEEKLY"
	RewardPeriodMonthly = "MONTHLY"
)

// What a claim did for one program (POST /api/reward-programs/claim's
// `results[].outcome`).
const (
	// RewardOutcomeGranted: today's day was claimed by THIS call (its reward
	// is in `granted`, unless the day gives nothing).
	RewardOutcomeGranted = "GRANTED"
	// RewardOutcomeAlreadyClaimed: today's day had been claimed already —
	// the result carries that claim, and nothing more was given.
	RewardOutcomeAlreadyClaimed = "ALREADY_CLAIMED"
	// RewardOutcomeBroken and RewardOutcomeCompleted: nothing can be claimed
	// until the next period.
	RewardOutcomeBroken    = "BROKEN"
	RewardOutcomeCompleted = "COMPLETED"
)

// The refusals of a claim that NAMES a program (POST {programCode}); a claim
// of every program never refuses, it reports each one's outcome.
var (
	// ErrRewardProgramNotFound: no program of that code, or one switched off.
	ErrRewardProgramNotFound = errors.New("reward program not found")
	// ErrRewardProgramNotRunning: a campaign outside its starts_at..ends_at
	// window.
	ErrRewardProgramNotRunning = errors.New("reward program not running")
	// ErrRewardCycleBroken: a BREAK program's required day was missed; the
	// next period starts fresh.
	ErrRewardCycleBroken = errors.New("reward cycle broken")
	// ErrRewardCycleCompleted: every day of the period is collected.
	ErrRewardCycleCompleted = errors.New("reward cycle completed")
)

// RewardClaimActionID is the key a claim is recorded under, in
// user_reward_claims and — for a CHIPS reward — in chip_ledger:
// "reward:<userId>:<programCode>:<claimDate>". One per player, program and
// calendar day BY CONSTRUCTION, so a claim is idempotent with no key from the
// client: a second request on the same day — a retry, a second device, two
// requests at once — finds the row (or collides on it) and is answered
// "already claimed", with the claim that was made.
func RewardClaimActionID(userID, programCode, claimDate string) string {
	return "reward:" + userID + ":" + programCode + ":" + claimDate
}

// RewardProgram is a program as a client sees it (the `program` of every
// state), with the period it is in now.
type RewardProgram struct {
	ID         int64  `json:"id"`
	Code       string `json:"code"`
	Name       string `json:"name"`
	Mode       string `json:"mode"`
	PeriodType string `json:"periodType"`
	// ProgressionType is RESET, SEQUENTIAL or BREAK: what a missed day does.
	ProgressionType string `json:"progressionType"`
	// Timezone is the IANA zone every date of the program is read in.
	Timezone string `json:"timezone"`
	// WeekStartDay is 1 Monday … 7 Sunday; read by a WEEKLY program only.
	WeekStartDay int `json:"weekStartDay"`
	// ResetOnMissedDay is whether a missed day starts the run again from Day 1
	// — true exactly for a RESET program. Kept for the apps that read it
	// before the progression types existed.
	ResetOnMissedDay bool `json:"resetOnMissedDay"`
	// StartsAt and EndsAt bound a campaign (epoch ms); null on a recurring
	// program.
	StartsAt *int64 `json:"startsAt"`
	EndsAt   *int64 `json:"endsAt"`
	// PeriodStart and PeriodEnd are the current period's bounds, epoch ms:
	// the local midnight its first day began, and the last millisecond
	// before the next period.
	PeriodStart int64 `json:"periodStart"`
	PeriodEnd   int64 `json:"periodEnd"`

	loc       *time.Location
	sortOrder int
}

// RewardDay is one day of a program as a client sees it: the reward on it,
// with the catalogue row of an item reward resolved for the viewer (Owned,
// Held), whether the viewer has claimed it in the current period, and its
// standing. For a LOGIN_STREAK program Claimed marks the days of the CURRENT
// run — after a RESET program's Mon Day 1, Tue Day 2, Wed missed, Thu Day 1,
// only Day 1 is claimed — so the app draws the streak it shows, not the
// history.
type RewardDay struct {
	Day         int     `json:"day"`
	RewardType  string  `json:"rewardType"`
	RewardValue *int64  `json:"rewardValue"`
	RewardRefID *string `json:"rewardRefId"`
	Claimed     bool    `json:"claimed"`
	// State is CLAIMED, AVAILABLE (collectable now), MISSED or LOCKED — the
	// server's verdict (dayStateOf), never worked out by the app.
	State string `json:"state"`
	// At most one is set, by RewardType: the catalogue row exactly as its
	// catalogue route serves it, so the app draws it with the loaders it has.
	Picture      *Picture      `json:"picture,omitempty"`
	TablePicture *TablePicture `json:"tablePicture,omitempty"`
	Emoji        *Emoji        `json:"emoji,omitempty"`
	Badge        *BadgeItem    `json:"badge,omitempty"`
}

// RewardCycle is the period a program is in now, for display: its bounds in
// epoch ms (EndAt exclusive — the next period's first millisecond) and its
// first and last dates in the program's zone.
type RewardCycle struct {
	StartAt   int64  `json:"startAt"`
	EndAt     int64  `json:"endAt"`
	StartDate string `json:"startDate"`
	EndDate   string `json:"endDate"`
}

// RewardNextCycle is the period after the current one: when it starts, and
// how long that is from this answer (so a phone with a wrong clock still
// counts down to the server's moment).
type RewardNextCycle struct {
	StartAt    int64  `json:"startAt"`
	StartDate  string `json:"startDate"`
	StartsInMs int64  `json:"startsInMs"`
}

// RewardProgramState is one program for one player (GET /api/reward-programs):
// the program with its current period, today's date in its zone and place in
// the period, where the player stands, and every day's reward.
type RewardProgramState struct {
	Program RewardProgram `json:"program"`
	// Today is today's date in the program's timezone, "2006-01-02".
	Today string `json:"today"`
	// DayOfPeriod is today's position in the period: 1..7 in a week from
	// week_start_day, the date in a month.
	DayOfPeriod int `json:"dayOfPeriod"`
	// PeriodDays is how many days the period has: 7, or the month's 28 to 31.
	PeriodDays int `json:"periodDays"`
	// CurrentDay is the day today's claim counts (or counted) as while the
	// cycle is ACTIVE; the day that was missed while it is BROKEN; the last
	// day once it is COMPLETED.
	CurrentDay int `json:"currentDay"`
	// ClaimedToday is whether today's reward of this program has been
	// claimed.
	ClaimedToday bool `json:"claimedToday"`
	// ClaimedDays is the days that count now: a RESET program's current run
	// (its "3 Day Streak"), every other program's days claimed this period.
	ClaimedDays int `json:"claimedDays"`
	// Status is ACTIVE, COMPLETED or BROKEN.
	Status string `json:"status"`
	// CanClaim is whether a claim now would grant CurrentDay.
	CanClaim bool `json:"canClaim"`
	// NextDay is the day the next claim counts as — today's while CanClaim,
	// tomorrow's once today is claimed — 0 when no claim is left this period.
	NextDay int `json:"nextDay"`
	// Period is the current cycle; NextPeriod the one after it, null when the
	// program has ended by then.
	Period     RewardCycle      `json:"period"`
	NextPeriod *RewardNextCycle `json:"nextPeriod"`
	// Rewards are the program's days that carry a reward, in day order; a
	// day with no entry gives nothing. Never null.
	Rewards []RewardDay `json:"rewards"`
}

// RewardProgramsView is GET /api/reward-programs: every program running now,
// in sort_order, as it stands for the caller, and the server's clock.
type RewardProgramsView struct {
	ServerTime int64                `json:"serverTime"`
	Programs   []RewardProgramState `json:"programs"`
}

// RewardGrant is one reward a claim gave (POST /api/reward-programs/claim's
// `granted`): which program and day, the reward as it stood — the snapshot
// user_reward_claims keeps — and the item after the grant.
type RewardGrant struct {
	ProgramCode  string        `json:"programCode"`
	ProgramName  string        `json:"programName"`
	Mode         string        `json:"mode"`
	PeriodType   string        `json:"periodType"`
	Day          int           `json:"day"`
	RewardType   string        `json:"rewardType"`
	RewardValue  *int64        `json:"rewardValue"`
	RewardRefID  *string       `json:"rewardRefId"`
	Picture      *Picture      `json:"picture,omitempty"`
	TablePicture *TablePicture `json:"tablePicture,omitempty"`
	Emoji        *Emoji        `json:"emoji,omitempty"`
	Badge        *BadgeItem    `json:"badge,omitempty"`
	// AlreadyOwned is an item the player already had: the day is claimed,
	// nothing more was given, and what they hold is left exactly as it was.
	AlreadyOwned bool  `json:"alreadyOwned"`
	ClaimedAt    int64 `json:"claimedAt"`
}

// RewardClaimResult is what a claim did for one program (`results`): its
// outcome and — GRANTED or ALREADY_CLAIMED — today's claim, the snapshot of
// the reward it recorded (a replay is answered with the claim it repeats).
type RewardClaimResult struct {
	ProgramCode string  `json:"programCode"`
	Outcome     string  `json:"outcome"`
	Day         int     `json:"day,omitempty"`
	RewardType  string  `json:"rewardType,omitempty"`
	RewardValue *int64  `json:"rewardValue,omitempty"`
	RewardRefID *string `json:"rewardRefId,omitempty"`
	ClaimedAt   int64   `json:"claimedAt,omitempty"`
}

// RewardClaimOutcome is POST /api/reward-programs/claim: what THIS call
// granted (nothing for a day already claimed, or a day that gives nothing),
// each program's outcome, every active program as it stands after, the
// account after, and the server's clock.
type RewardClaimOutcome struct {
	ServerTime int64                `json:"serverTime"`
	Granted    []RewardGrant        `json:"granted"`
	Results    []RewardClaimResult  `json:"results"`
	Programs   []RewardProgramState `json:"programs"`
	User       *User                `json:"user"`
}

// RewardPrograms is the reward programs store: the programs and their days —
// configuration, read on every look and every claim, so an owner's UPDATE is
// in force at the next one — and the claim, which works out the day, grants
// its reward and records the claim in one transaction per program.
type RewardPrograms struct {
	db     *DB
	users  *Users
	clock  func() time.Time
	logger *slog.Logger // may be nil

	zones sync.Map // timezone name → *time.Location
}

// NewRewardPrograms builds the store. users builds the account a claim answers
// with; clock nil → time.Now; logger nil → a row left out is not reported.
func NewRewardPrograms(d *DB, users *Users, clock func() time.Time, logger *slog.Logger) *RewardPrograms {
	return &RewardPrograms{db: d, users: users, clock: clock, logger: logger}
}

// nowTime is the instant every read and write of a call is made at.
func (r *RewardPrograms) nowTime() time.Time {
	if r.clock == nil {
		return time.Now()
	}
	return r.clock()
}

// zone loads a program's timezone, once per name.
func (r *RewardPrograms) zone(name string) (*time.Location, error) {
	if loc, ok := r.zones.Load(name); ok {
		return loc.(*time.Location), nil
	}
	loc, err := time.LoadLocation(name)
	if err != nil {
		return nil, err
	}
	r.zones.Store(name, loc)
	return loc, nil
}

// leftOut reports a program or a day the store cannot run.
func (r *RewardPrograms) leftOut(msg string, args ...any) {
	if r.logger != nil {
		r.logger.Warn(msg, args...)
	}
}

// ---------------------------------------------------------------- calendar

// civilDate is a calendar date with no time and no zone — what a claim is
// dated by, in the program's timezone.
type civilDate struct {
	Year  int
	Month time.Month
	Day   int
}

// civilOf is the calendar date of an instant, in the instant's zone.
func civilOf(t time.Time) civilDate {
	y, m, d := t.Date()
	return civilDate{y, m, d}
}

// parseCivil reads "2006-01-02".
func parseCivil(s string) (civilDate, error) {
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		return civilDate{}, err
	}
	return civilOf(t), nil
}

func (c civilDate) String() string {
	return fmt.Sprintf("%04d-%02d-%02d", c.Year, int(c.Month), c.Day)
}

// plusDays is the date n days on (n may be negative), by calendar
// arithmetic: time.Date normalises a day past the month's end.
func (c civilDate) plusDays(n int) civilDate {
	return civilOf(time.Date(c.Year, c.Month, c.Day+n, 0, 0, 0, 0, time.UTC))
}

// midnight is the instant the date began in loc. Worked out with time.Date,
// so a day a daylight-saving change makes 23 or 25 hours long is still the
// right day, and a midnight that does not exist is the first instant after.
func (c civilDate) midnight(loc *time.Location) time.Time {
	return time.Date(c.Year, c.Month, c.Day, 0, 0, 0, 0, loc)
}

// isoWeekday is 1 Monday … 7 Sunday.
func (c civilDate) isoWeekday() int {
	if w := int(c.midnight(time.UTC).Weekday()); w != 0 {
		return w
	}
	return 7
}

// daysSince is how many days this date is after o (negative before it).
func (c civilDate) daysSince(o civilDate) int {
	return int(c.midnight(time.UTC).Sub(o.midnight(time.UTC)).Hours() / 24)
}

func (c civilDate) equal(o civilDate) bool { return c == o }

// daysInMonth is the month's length — 28, 29 in a leap year, 30 or 31 — by
// the calendar: day 0 of the next month is this month's last.
func daysInMonth(y int, m time.Month) int {
	return time.Date(y, m+1, 0, 0, 0, 0, 0, time.UTC).Day()
}

// rewardPeriod is the calendar period a program is in at an instant.
type rewardPeriod struct {
	// Start and End are the period's first and last day.
	Start, End civilDate
	// StartMs is the local midnight the first day began (what
	// user_reward_claims.period_start_at and user_reward_progress's hold);
	// EndMs the last millisecond before the next period's first midnight.
	StartMs, EndMs int64
	// Days is the period's length: 7, or the month's.
	Days int
	// Today is the date at the instant, in the program's zone, and
	// DayOfPeriod its position in the period, from 1.
	Today       civilDate
	DayOfPeriod int
}

// periodOf is the WEEKLY or MONTHLY period an instant falls in, in loc — the
// ONE place a period is worked out (there is no table of periods: a period
// is the program's configuration, the instant and the zone). A week runs
// from weekStartDay (1 Monday … 7 Sunday) for seven days; a month from its
// first day for as many days as it has. Neither is a multiple of
// 86,400,000 ms: the bounds are calendar days' midnights in loc.
func periodOf(periodType string, weekStartDay int, loc *time.Location, at time.Time) (rewardPeriod, error) {
	today := civilOf(at.In(loc))
	var start civilDate
	var days int
	switch periodType {
	case RewardPeriodWeekly:
		if weekStartDay < 1 || weekStartDay > 7 {
			weekStartDay = 1
		}
		offset := (today.isoWeekday() - weekStartDay + 7) % 7
		start = today.plusDays(-offset)
		days = 7
	case RewardPeriodMonthly:
		start = civilDate{today.Year, today.Month, 1}
		days = daysInMonth(today.Year, today.Month)
	default:
		return rewardPeriod{}, fmt.Errorf("reward program: unknown period type %q", periodType)
	}
	next := start.plusDays(days)
	return rewardPeriod{
		Start:       start,
		End:         start.plusDays(days - 1),
		StartMs:     start.midnight(loc).UnixMilli(),
		EndMs:       next.midnight(loc).UnixMilli() - 1,
		Days:        days,
		Today:       today,
		DayOfPeriod: today.daysSince(start) + 1,
	}, nil
}

// claimRow is one user_reward_claims row of a period, as loadClaims reads
// them: newest first.
type claimRow struct {
	Date       civilDate
	Day        int
	RewardType string
	Value      *int64
	Ref        *string
	ClaimedAt  int64
}

// ------------------------------------------------------------------- reads

// programRow is one reward_programs row as stored.
type programRow struct {
	RewardProgram
	timezone string
	active   bool
}

// programColumns is what every read of reward_programs takes.
const programColumns = `id, code, name, mode, period_type, progression_type, timezone, week_start_day, starts_at, ends_at, sort_order, is_active`

// scanProgram reads one programColumns row.
func scanProgram(row pgx.Row) (programRow, error) {
	var p programRow
	var weekStart int16
	err := row.Scan(&p.ID, &p.Code, &p.Name, &p.Mode, &p.PeriodType, &p.ProgressionType, &p.timezone, &weekStart,
		&p.StartsAt, &p.EndsAt, &p.sortOrder, &p.active)
	p.WeekStartDay = int(weekStart)
	p.ResetOnMissedDay = p.ProgressionType == RewardProgressionReset
	return p, err
}

// running is whether a program runs at atMs: inside its campaign window.
func (p programRow) running(atMs int64) bool {
	return (p.StartsAt == nil || *p.StartsAt <= atMs) && (p.EndsAt == nil || *p.EndsAt >= atMs)
}

// open makes a stored program a running one: its zone loaded and its
// current period worked out — or a reason it cannot run.
func (r *RewardPrograms) open(p programRow, at time.Time) (*RewardProgram, string) {
	switch p.ProgressionType {
	case RewardProgressionReset, RewardProgressionSequential, RewardProgressionBreak:
	default:
		return nil, "unknown progression type " + p.ProgressionType
	}
	loc, err := r.zone(p.timezone)
	if err != nil {
		return nil, "unknown timezone " + p.timezone
	}
	period, err := periodOf(p.PeriodType, p.WeekStartDay, loc, at)
	if err != nil {
		return nil, err.Error()
	}
	program := p.RewardProgram
	program.Timezone = p.timezone
	program.loc = loc
	program.PeriodStart, program.PeriodEnd = period.StartMs, period.EndMs
	return &program, ""
}

// loadPrograms reads the ACTIVE programs in sort_order that are RUNNING at
// `at` — a campaign outside its starts_at..ends_at window is not — each with
// its zone loaded and its current period worked out. A program whose zone
// this server cannot load, or whose rules it does not know, is left out with
// a logged reason.
func (r *RewardPrograms) loadPrograms(ctx context.Context, q queryer, at time.Time) ([]*RewardProgram, error) {
	rows, err := q.Query(ctx,
		`SELECT `+programColumns+`
		   FROM reward_programs
		  WHERE is_active
		  ORDER BY sort_order, id`)
	if err != nil {
		return nil, err
	}
	// Read to the end before any other query: a transaction serves one result
	// at a time.
	var raw []programRow
	for rows.Next() {
		p, err := scanProgram(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		raw = append(raw, p)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	atMs := at.UnixMilli()
	programs := make([]*RewardProgram, 0, len(raw))
	for _, p := range raw {
		if !p.running(atMs) {
			continue // a campaign not yet open, or over
		}
		program, reason := r.open(p, at)
		if reason != "" {
			r.leftOut("reward program left out", "program", p.Code, "reason", reason)
			continue
		}
		programs = append(programs, program)
	}
	return programs, nil
}

// namedProgram is the program a claim names, running at `at` — or why it
// cannot be claimed: ErrRewardProgramNotFound (no such code, switched off,
// or one this server cannot run), ErrRewardProgramNotRunning (outside its
// campaign window).
func (r *RewardPrograms) namedProgram(ctx context.Context, q queryer, code string, at time.Time) (*RewardProgram, error) {
	p, err := scanProgram(q.QueryRow(ctx,
		`SELECT `+programColumns+` FROM reward_programs WHERE code = $1`, code))
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !p.active) {
		return nil, ErrRewardProgramNotFound
	}
	if err != nil {
		return nil, err
	}
	if !p.running(at.UnixMilli()) {
		return nil, ErrRewardProgramNotRunning
	}
	program, reason := r.open(p, at)
	if reason != "" {
		r.leftOut("reward program left out", "program", p.Code, "reason", reason)
		return nil, ErrRewardProgramNotFound
	}
	return program, nil
}

// period is the program's period at `at`.
func (p *RewardProgram) period(at time.Time) rewardPeriod {
	period, _ := periodOf(p.PeriodType, p.WeekStartDay, p.loc, at) // validated in open
	return period
}

// rules is what the progression engine reads of the program in a period.
func (p *RewardProgram) rules(period rewardPeriod) rewardRules {
	first, last := runsBetween(period, p.loc, p.StartsAt, p.EndsAt)
	return rewardRules{Mode: p.Mode, Progression: p.ProgressionType, FirstDay: first, LastDay: last}
}

// cycles is the program's current period for display, and the next one —
// nil when the program has ended by then.
func (p *RewardProgram) cycles(period rewardPeriod, at time.Time) (RewardCycle, *RewardNextCycle) {
	nextStart := period.EndMs + 1
	current := RewardCycle{
		StartAt:   period.StartMs,
		EndAt:     nextStart,
		StartDate: period.Start.String(),
		EndDate:   period.End.String(),
	}
	if p.EndsAt != nil && *p.EndsAt < nextStart {
		return current, nil
	}
	return current, &RewardNextCycle{
		StartAt:    nextStart,
		StartDate:  period.End.plusDays(1).String(),
		StartsInMs: max(0, nextStart-at.UnixMilli()),
	}
}

// loadClaims reads this player's claims of the program in the period,
// newest first — the one read the standing needs, off
// user_reward_claims_period_idx, never a scan of the history.
func loadClaims(ctx context.Context, q queryer, userID string, programID int64, periodStartMs int64) ([]claimRow, error) {
	rows, err := q.Query(ctx,
		`SELECT claim_date::text, day_number, reward_type, reward_value, reward_ref_id, claimed_at
		   FROM user_reward_claims
		  WHERE user_id = $1 AND program_id = $2 AND period_start_at = $3
		  ORDER BY claim_date DESC`, userID, programID, periodStartMs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var claims []claimRow
	for rows.Next() {
		var c claimRow
		var date string
		var day int16
		if err := rows.Scan(&date, &day, &c.RewardType, &c.Value, &c.Ref, &c.ClaimedAt); err != nil {
			return nil, err
		}
		if c.Date, err = parseCivil(date); err != nil {
			return nil, err
		}
		c.Day = int(day)
		claims = append(claims, c)
	}
	return claims, rows.Err()
}

// rewardRow is one reward_program_rewards row as stored.
type rewardRow struct {
	day   int
	kind  string
	value *int64
	ref   *string
}

// loadRewards reads a program's ACTIVE days in day order.
func loadRewards(ctx context.Context, q queryer, programID int64) ([]rewardRow, error) {
	rows, err := q.Query(ctx,
		`SELECT day_number, reward_type, reward_value, reward_ref_id
		   FROM reward_program_rewards
		  WHERE program_id = $1 AND is_active
		  ORDER BY day_number`, programID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []rewardRow
	for rows.Next() {
		var row rewardRow
		var day int16
		if err := rows.Scan(&day, &row.kind, &row.value, &row.ref); err != nil {
			return nil, err
		}
		row.day = int(day)
		out = append(out, row)
	}
	return out, rows.Err()
}

// loadReward reads one ACTIVE day of a program; found is false for a day
// with no row.
func loadReward(ctx context.Context, q queryer, programID int64, day int) (rewardRow, bool, error) {
	var row rewardRow
	err := q.QueryRow(ctx,
		`SELECT day_number, reward_type, reward_value, reward_ref_id
		   FROM reward_program_rewards
		  WHERE program_id = $1 AND day_number = $2 AND is_active`, programID, day).
		Scan(&day, &row.kind, &row.value, &row.ref)
	if errors.Is(err, pgx.ErrNoRows) {
		return rewardRow{}, false, nil
	}
	row.day = day
	return row, err == nil, err
}

// resolve checks that a day's reward can be granted and, for an item, reads
// its catalogue row onto the day with this viewer's ownership as of `at`. It
// answers with why the reward must be left out — the day then gives nothing
// — or "" when it can be given:
//
//   - a type this build does not know;
//   - CHIPS, DIAMOND, HAMMER or MISSILE with no amount, or 0, or — for the
//     three INTEGER wallets — more than a wallet column can ever hold;
//   - EMOJI, PROFILE_PICTURE or TABLE_PICTURE whose reward_ref_id names no
//     catalogue row, or a retired one; BADGE whose code names no badge, or a
//     retired one.
func resolve(ctx context.Context, q queryer, userID string, day *RewardDay, at int64) (string, error) {
	switch day.RewardType {
	case RewardNone:
	case RewardChips:
		if day.RewardValue == nil || *day.RewardValue <= 0 {
			return "no amount", nil
		}
	case RewardDiamond, RewardHammer, RewardMissile:
		if day.RewardValue == nil || *day.RewardValue <= 0 {
			return "no amount", nil
		}
		if *day.RewardValue > math.MaxInt32 {
			return "more than the wallet can hold", nil
		}
	case RewardProfilePicture:
		id, ok := refID(day.RewardRefID)
		if !ok {
			return "no picture id", nil
		}
		pic, active, found, err := findPictureIn(ctx, q, userID, id, at)
		if err != nil {
			return "", err
		}
		if reason := itemReason("profile picture", found, active); reason != "" {
			return reason, nil
		}
		day.Picture = &pic
	case RewardTablePicture:
		id, ok := refID(day.RewardRefID)
		if !ok {
			return "no table picture id", nil
		}
		pic, active, found, err := findTablePictureIn(ctx, q, userID, id, at)
		if err != nil {
			return "", err
		}
		if reason := itemReason("table picture", found, active); reason != "" {
			return reason, nil
		}
		day.TablePicture = &pic
	case RewardEmoji:
		id, ok := refID(day.RewardRefID)
		if !ok {
			return "no emoji id", nil
		}
		em, active, found, err := findEmojiIn(ctx, q, userID, id, at)
		if err != nil {
			return "", err
		}
		if reason := itemReason("emoji", found, active); reason != "" {
			return reason, nil
		}
		day.Emoji = &em
	case RewardBadge:
		if day.RewardRefID == nil || *day.RewardRefID == "" {
			return "no badge code", nil
		}
		b, active, found, err := findBadgeIn(ctx, q, userID, *day.RewardRefID, at)
		if err != nil {
			return "", err
		}
		if reason := itemReason("badge", found, active); reason != "" {
			return reason, nil
		}
		day.Badge = &b
	default:
		return "a reward this server cannot grant", nil
	}
	return "", nil
}

// itemReason is why a catalogue item cannot be a reward, or "".
func itemReason(what string, found, active bool) string {
	switch {
	case !found:
		return "no such " + what
	case !active:
		return "the " + what + " is retired"
	}
	return ""
}

// dayOf is a stored reward as a client's RewardDay, before resolve.
func (row rewardRow) dayOf() RewardDay {
	return RewardDay{Day: row.day, RewardType: row.kind, RewardValue: row.value, RewardRefID: row.ref}
}

// noReward is the RewardDay of a day that gives nothing.
func noReward(day int) RewardDay {
	return RewardDay{Day: day, RewardType: RewardNone}
}

// ---------------------------------------------------------------- progress

// saveProgress keeps the player's user_reward_progress row of the program's
// period in step with the standing the engine worked out (rewardprogress.go):
// the row is created the first time the player looks at or claims the
// program in that period — never for a period nobody touched — and updated
// only when the standing has changed. The claims stay the record the
// standing is worked out from; this row is what it came to, for whoever
// reads the table. A writer never goes back in time: an update whose latest
// claim is older than the row's (a look that read before a claim committed)
// leaves the row alone.
func saveProgress(ctx context.Context, q queryer, userID string, programID, periodStartMs int64, p rewardProgress, at int64) error {
	_, err := q.Exec(ctx,
		`INSERT INTO user_reward_progress AS up
		        (user_id, program_id, period_start_at, current_day, status, last_activity_at, created_at, updated_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $7)
		 ON CONFLICT (user_id, program_id, period_start_at) DO UPDATE
		    SET current_day = EXCLUDED.current_day,
		        status = EXCLUDED.status,
		        last_activity_at = EXCLUDED.last_activity_at,
		        updated_at = EXCLUDED.updated_at
		  WHERE EXCLUDED.last_activity_at >= up.last_activity_at
		    AND (up.current_day, up.status, up.last_activity_at)
		        IS DISTINCT FROM (EXCLUDED.current_day, EXCLUDED.status, EXCLUDED.last_activity_at)`,
		userID, programID, periodStartMs, progressRowDay(p), p.Status, p.LastActivity, at)
	return err
}

// ------------------------------------------------------------------- state

// state is one program's state for one player from its claims in the current
// period and its days, each resolved for the player; save also writes the
// standing to user_reward_progress (a look does, a claim's closing read
// does not: its transaction already has).
func (r *RewardPrograms) state(ctx context.Context, q queryer, userID string, p *RewardProgram, at time.Time, save bool) (RewardProgramState, error) {
	period := p.period(at)
	rules := p.rules(period)
	claims, err := loadClaims(ctx, q, userID, p.ID, period.StartMs)
	if err != nil {
		return RewardProgramState{}, err
	}
	rows, err := loadRewards(ctx, q, p.ID)
	if err != nil {
		return RewardProgramState{}, err
	}
	progress := progressAt(rules, period, claims)
	cycle, next := p.cycles(period, at)
	s := RewardProgramState{
		Program:      *p,
		Today:        period.Today.String(),
		DayOfPeriod:  period.DayOfPeriod,
		PeriodDays:   period.Days,
		CurrentDay:   progress.CurrentDay,
		ClaimedToday: progress.ClaimedToday,
		ClaimedDays:  progress.RunDays,
		Status:       progress.Status,
		CanClaim:     progress.CanClaim,
		NextDay:      progress.NextDay,
		Period:       cycle,
		NextPeriod:   next,
		Rewards:      make([]RewardDay, 0, len(rows)),
	}
	atMs := at.UnixMilli()
	for _, row := range rows {
		if row.day > period.Days {
			continue // a day this period never reaches
		}
		day := row.dayOf()
		reason, err := resolve(ctx, q, userID, &day, atMs)
		if err != nil {
			return RewardProgramState{}, err
		}
		if reason != "" {
			r.leftOut("reward program day left out", "program", p.Code, "day", row.day, "rewardType", row.kind, "reason", reason)
			continue
		}
		day.Claimed = progress.Claimed[day.Day]
		day.State = dayStateOf(rules, period, progress, day.Day)
		s.Rewards = append(s.Rewards, day)
	}
	if save {
		if err := saveProgress(ctx, q, userID, p.ID, period.StartMs, progress, atMs); err != nil {
			return RewardProgramState{}, err
		}
	}
	return s, nil
}

// State is GET /api/reward-programs for one player: every program running
// now, in sort_order, as it stands for them. Nothing is granted; the
// player's progress row of each program's period is created or brought up to
// date (a missed day turns a BREAK program's cycle BROKEN the first time the
// player looks after it). Allowed anywhere, at a table included — no wallet
// moves.
func (r *RewardPrograms) State(ctx context.Context, userID string) (*RewardProgramsView, error) {
	at := r.nowTime()
	programs, err := r.loadPrograms(ctx, r.db.Pool, at)
	if err != nil {
		return nil, err
	}
	view := &RewardProgramsView{ServerTime: at.UnixMilli(), Programs: make([]RewardProgramState, 0, len(programs))}
	for _, p := range programs {
		s, err := r.state(ctx, r.db.Pool, userID, p, at, true)
		if err != nil {
			return nil, err
		}
		view.Programs = append(view.Programs, s)
	}
	return view, nil
}

// ------------------------------------------------------------------- claim

// Claim is POST /api/reward-programs/claim: today's reward of the program
// `code` names, or of every program running now when it is "" — each in ONE
// transaction of its own, in sort_order:
//
//	SELECT chips FROM users WHERE id = $1 FOR UPDATE   lock the wallet (no row → unknown_user)
//	this player's claims of the program in the period   newest first (loadClaims)
//	the standing                                        progressAt: the day, or why there is none
//	today already claimed?                              → ALREADY_CLAIMED, with that claim
//	broken or completed?                                → BROKEN / COMPLETED, nothing written
//	the day's reward, resolved for the player           a day with none, or one it cannot grant: NO_REWARD
//	the reward granted                                  grantReward: chips through chip_ledger, the rest as deltas or ownership rows
//	INSERT user_reward_claims                           the snapshot and the key
//	UPSERT user_reward_progress                         the standing after the claim
//
// All of a program's claim commits or none of it does: a reward that cannot
// be granted leaves no claim, and a claim that cannot be written takes the
// reward back out with it. The wallet lock serialises one player's claims,
// so two requests at once — two devices, a retry racing its first attempt —
// queue, and the second finds the first's row; two claims that somehow both
// passed the look (another pool's transaction committing between the look
// and the write) collide on user_reward_claims_period_idx or on action_id,
// roll back, and are answered "already claimed" all the same. Nothing the
// caller sends decides anything but WHICH program: the server works out the
// day and the reward.
//
// A day with no reward — none configured, or one this build cannot grant —
// is still CLAIMED (recorded as NO_REWARD), so a run counts through it; it is
// not in Granted. Lobby-only: the caller runs it under the player's seat lock
// (auth: WhileUnseated), because a CHIPS reward moves a wallet only the lobby
// may move (CLAUDE.md §5.1). Each program is independent: one that fails (a
// database error) stops the call with its error, and the ones claimed before
// it stay claimed. A NAMED program refuses with ErrRewardProgramNotFound,
// ErrRewardProgramNotRunning, ErrRewardCycleBroken or ErrRewardCycleCompleted;
// a claim of every program reports those as outcomes instead.
func (r *RewardPrograms) Claim(ctx context.Context, userID, code string) (*RewardClaimOutcome, error) {
	at := r.nowTime()
	var programs []*RewardProgram
	if code != "" {
		p, err := r.namedProgram(ctx, r.db.Pool, code, at)
		if err != nil {
			return nil, err
		}
		programs = []*RewardProgram{p}
	} else {
		var err error
		if programs, err = r.loadPrograms(ctx, r.db.Pool, at); err != nil {
			return nil, err
		}
	}
	out := &RewardClaimOutcome{ServerTime: at.UnixMilli(), Granted: []RewardGrant{}, Results: []RewardClaimResult{}}
	for _, p := range programs {
		result, grant, err := r.claimOne(ctx, userID, p, at)
		if err != nil {
			return nil, err
		}
		if code != "" {
			switch result.Outcome {
			case RewardOutcomeBroken:
				return nil, ErrRewardCycleBroken
			case RewardOutcomeCompleted:
				return nil, ErrRewardCycleCompleted
			}
		}
		out.Results = append(out.Results, result)
		if grant != nil {
			out.Granted = append(out.Granted, *grant)
		}
	}
	// Every running program as it now stands, after the last commit.
	all, err := r.loadPrograms(ctx, r.db.Pool, at)
	if err != nil {
		return nil, err
	}
	out.Programs = make([]RewardProgramState, 0, len(all))
	for _, p := range all {
		s, err := r.state(ctx, r.db.Pool, userID, p, at, false)
		if err != nil {
			return nil, err
		}
		out.Programs = append(out.Programs, s)
	}
	if out.User, err = r.users.FindByID(ctx, userID); err != nil {
		return nil, err
	}
	return out, nil
}

// claimOne claims today's reward of one program (Claim's transaction): the
// outcome, and the grant when THIS call gave something.
func (r *RewardPrograms) claimOne(ctx context.Context, userID string, p *RewardProgram, at time.Time) (RewardClaimResult, *RewardGrant, error) {
	period := p.period(at)
	rules := p.rules(period)
	key := RewardClaimActionID(userID, p.Code, period.Today.String())
	atMs := at.UnixMilli()
	var result RewardClaimResult
	var grant *RewardGrant
	err := r.db.WithTx(ctx, func(tx pgx.Tx) error {
		result, grant = RewardClaimResult{ProgramCode: p.Code}, nil
		chips, err := lockWallet(ctx, tx, userID)
		if err != nil {
			return err
		}
		claims, err := loadClaims(ctx, tx, userID, p.ID, period.StartMs)
		if err != nil {
			return err
		}
		progress := progressAt(rules, period, claims)
		switch {
		case progress.ClaimedToday:
			result = alreadyClaimed(p.Code, claims[0])
			return nil
		case progress.Status == RewardStatusBroken:
			result.Outcome = RewardOutcomeBroken
			return saveProgress(ctx, tx, userID, p.ID, period.StartMs, progress, atMs)
		case !progress.CanClaim:
			result.Outcome = RewardOutcomeCompleted
			return saveProgress(ctx, tx, userID, p.ID, period.StartMs, progress, atMs)
		}
		day := progress.CurrentDay

		reward := noReward(day)
		if row, found, err := loadReward(ctx, tx, p.ID, day); err != nil {
			return err
		} else if found {
			candidate := row.dayOf()
			reason, err := resolve(ctx, tx, userID, &candidate, atMs)
			if err != nil {
				return err
			}
			if reason == "" && candidate.RewardType == RewardChips && *candidate.RewardValue > math.MaxInt64-chips {
				reason = "more than the wallet can hold"
			}
			if reason != "" {
				r.leftOut("reward program day left out", "program", p.Code, "day", day, "rewardType", row.kind, "reason", reason)
			} else {
				reward = candidate
			}
		}

		g := &Grant{Type: reward.RewardType, Value: reward.RewardValue,
			Picture: reward.Picture, TablePicture: reward.TablePicture, Emoji: reward.Emoji, Badge: reward.Badge}
		alreadyOwned, err := grantReward(ctx, tx, userID, key, chips, g, atMs, game.LedgerReasonRewardProgram)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO user_reward_claims
			   (user_id, program_id, period_start_at, day_number, claim_date, reward_type, reward_value, reward_ref_id, action_id, claimed_at)
			 VALUES ($1, $2, $3, $4, $5::date, $6, $7, $8, $9, $10)`,
			userID, p.ID, period.StartMs, day, period.Today.String(), reward.RewardType, reward.RewardValue, reward.RewardRefID, key, atMs); err != nil {
			return err
		}
		claimed := claimRow{Date: period.Today, Day: day, RewardType: reward.RewardType, Value: reward.RewardValue,
			Ref: reward.RewardRefID, ClaimedAt: atMs}
		after := progressAt(rules, period, append([]claimRow{claimed}, claims...))
		if err := saveProgress(ctx, tx, userID, p.ID, period.StartMs, after, atMs); err != nil {
			return err
		}
		result = RewardClaimResult{ProgramCode: p.Code, Outcome: RewardOutcomeGranted, Day: day,
			RewardType: reward.RewardType, RewardValue: reward.RewardValue, RewardRefID: reward.RewardRefID, ClaimedAt: atMs}
		if reward.RewardType == RewardNone {
			return nil
		}
		grant = &RewardGrant{
			ProgramCode: p.Code, ProgramName: p.Name, Mode: p.Mode, PeriodType: p.PeriodType,
			Day: day, RewardType: reward.RewardType, RewardValue: reward.RewardValue, RewardRefID: reward.RewardRefID,
			Picture: reward.Picture, TablePicture: reward.TablePicture, Emoji: reward.Emoji, Badge: reward.Badge,
			AlreadyOwned: alreadyOwned, ClaimedAt: atMs,
		}
		return nil
	})
	if err != nil && (isUniqueViolationOn(err, "action_id") || isUniqueViolationOn(err, "claim_date")) {
		// Today's claim committed in the meantime: nothing more to give, and
		// the answer is that claim.
		claims, readErr := loadClaims(ctx, r.db.Pool, userID, p.ID, period.StartMs)
		if readErr != nil {
			return RewardClaimResult{}, nil, readErr
		}
		if len(claims) > 0 && claims[0].Date.equal(period.Today) {
			return alreadyClaimed(p.Code, claims[0]), nil, nil
		}
		return RewardClaimResult{ProgramCode: p.Code, Outcome: RewardOutcomeAlreadyClaimed}, nil, nil
	}
	if err != nil {
		return RewardClaimResult{}, nil, err
	}
	return result, grant, nil
}

// alreadyClaimed is the result of a claim that finds today's claim made:
// that claim, as it was recorded.
func alreadyClaimed(code string, c claimRow) RewardClaimResult {
	return RewardClaimResult{ProgramCode: code, Outcome: RewardOutcomeAlreadyClaimed, Day: c.Day,
		RewardType: c.RewardType, RewardValue: c.Value, RewardRefID: c.Ref, ClaimedAt: c.ClaimedAt}
}
