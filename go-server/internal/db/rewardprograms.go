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
// and MONTHLY periods"; V1.0.0's REWARD PROGRAMS section). A program is a
// MODE and a PERIOD TYPE:
//
//	LOGIN_STREAK  the day number is the consecutive login day: Mon Day 1, Tue
//	              Day 2, Wed missed, Thu Day 1 again (reset_on_missed_day);
//	CALENDAR      the day number is the day's position in the period: Mon
//	              Day 1, Tue Day 2, Wed missed, Thu Day 4 — nothing resets;
//
// over a WEEKLY period (a calendar week from week_start_day) or a MONTHLY one
// (a calendar month), in the program's own timezone. One set of tables, one
// store, for all four — and for any campaign an owner adds as rows.
const (
	RewardModeLoginStreak = "LOGIN_STREAK"
	RewardModeCalendar    = "CALENDAR"
	RewardPeriodWeekly    = "WEEKLY"
	RewardPeriodMonthly   = "MONTHLY"
)

// RewardClaimActionID is the key a claim is recorded under, in
// user_reward_claims and — for a CHIPS reward — in chip_ledger:
// "reward:<userId>:<programCode>:<claimDate>". One per player, program and
// calendar day BY CONSTRUCTION, so a claim is idempotent with no key from the
// client: a second request on the same day — a retry, a second device, two
// requests at once — finds the row (or collides on it) and is answered
// "already claimed".
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
	// Timezone is the IANA zone every date of the program is read in.
	Timezone string `json:"timezone"`
	// WeekStartDay is 1 Monday … 7 Sunday; read by a WEEKLY program only.
	WeekStartDay int `json:"weekStartDay"`
	// ResetOnMissedDay is whether a missed day starts a LOGIN_STREAK again
	// from Day 1; always false on a CALENDAR program (the schema holds it).
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
// Held), and whether the viewer has claimed it in the current period. For a
// LOGIN_STREAK program Claimed marks the days of the CURRENT run — after Mon
// Day 1, Tue Day 2, Wed missed, Thu Day 1, only Day 1 is claimed — so the
// app draws the streak it shows, not the history.
type RewardDay struct {
	Day         int     `json:"day"`
	RewardType  string  `json:"rewardType"`
	RewardValue *int64  `json:"rewardValue"`
	RewardRefID *string `json:"rewardRefId"`
	Claimed     bool    `json:"claimed"`
	// At most one is set, by RewardType: the catalogue row exactly as its
	// catalogue route serves it, so the app draws it with the loaders it has.
	Picture      *Picture      `json:"picture,omitempty"`
	TablePicture *TablePicture `json:"tablePicture,omitempty"`
	Emoji        *Emoji        `json:"emoji,omitempty"`
	Badge        *BadgeItem    `json:"badge,omitempty"`
}

// RewardProgramState is one program for one player (GET /api/reward-programs):
// the program with its current period, today's date in its zone and place in
// the period, the day the player stands on, and every day's reward.
type RewardProgramState struct {
	Program RewardProgram `json:"program"`
	// Today is today's date in the program's timezone, "2006-01-02".
	Today string `json:"today"`
	// DayOfPeriod is today's position in the period: 1..7 in a week from
	// week_start_day, the date in a month.
	DayOfPeriod int `json:"dayOfPeriod"`
	// PeriodDays is how many days the period has: 7, or the month's 28 to 31.
	PeriodDays int `json:"periodDays"`
	// CurrentDay is the day number today's claim counts (or counted) as: a
	// LOGIN_STREAK's consecutive login day, a CALENDAR's DayOfPeriod.
	CurrentDay int `json:"currentDay"`
	// ClaimedToday is whether today's reward of this program has been
	// claimed.
	ClaimedToday bool `json:"claimedToday"`
	// ClaimedDays is the days that count now: a LOGIN_STREAK's current run
	// (its "3 Day Streak"; CurrentDay once today is claimed, one less until
	// then, 0 after a missed day), a CALENDAR's days claimed this period.
	ClaimedDays int `json:"claimedDays"`
	// Rewards are the program's days that carry a reward, in day order; a
	// day with no entry gives nothing. Never null.
	Rewards []RewardDay `json:"rewards"`
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

// RewardClaimOutcome is POST /api/reward-programs/claim: what THIS call
// granted (nothing for a day already claimed, or a day that gives nothing),
// every active program as it stands after, and the account after.
type RewardClaimOutcome struct {
	Granted  []RewardGrant        `json:"granted"`
	Programs []RewardProgramState `json:"programs"`
	User     *User                `json:"user"`
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
	// user_reward_claims.period_start_at holds); EndMs the last millisecond
	// before the next period's first midnight.
	StartMs, EndMs int64
	// Days is the period's length: 7, or the month's.
	Days int
	// Today is the date at the instant, in the program's zone, and
	// DayOfPeriod its position in the period, from 1.
	Today       civilDate
	DayOfPeriod int
}

// periodOf is the WEEKLY or MONTHLY period an instant falls in, in loc. A
// week runs from weekStartDay (1 Monday … 7 Sunday) for seven days; a month
// from its first day for as many days as it has. Neither is a multiple of
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

// streakAt is the LOGIN_STREAK rule (the brief's §17), from the period's
// claims newest first: which day number today's claim counts as, whether
// today is already claimed, and how many days the current run has claimed.
// Always the LATEST claim, never MAX(day_number): after Day 1, 2, 3 and a
// missed day the streak stands at Day 1 again, whatever it reached before.
func streakAt(claims []claimRow, today civilDate, reset bool) (currentDay int, claimedToday bool, run int) {
	if len(claims) == 0 {
		return 1, false, 0
	}
	latest := claims[0]
	switch {
	case latest.Date.equal(today):
		return latest.Day, true, latest.Day
	case latest.Date.equal(today.plusDays(-1)):
		return latest.Day + 1, false, latest.Day
	case reset:
		return 1, false, 0
	default:
		// A streak that does not reset counts on after a gap.
		return latest.Day + 1, false, latest.Day
	}
}

// calendarAt is the CALENDAR rule (§18): today's day number is its position
// in the period; each day claimed stays claimed, and a missed day is simply
// missed.
func calendarAt(claims []claimRow, period rewardPeriod) (currentDay int, claimedToday bool, claimed map[int]bool) {
	claimed = make(map[int]bool, len(claims))
	for _, c := range claims {
		claimed[c.Day] = true
		if c.Date.equal(period.Today) {
			claimedToday = true
		}
	}
	return period.DayOfPeriod, claimedToday, claimed
}

// ------------------------------------------------------------------- reads

// programRow is one reward_programs row as stored.
type programRow struct {
	RewardProgram
	timezone string
}

// loadPrograms reads the ACTIVE programs in sort_order that are RUNNING at
// `at` — a campaign outside its starts_at..ends_at window is not — each with
// its zone loaded and its current period worked out. A program whose zone
// this server cannot load is left out with a logged reason.
func (r *RewardPrograms) loadPrograms(ctx context.Context, q queryer, at time.Time) ([]*RewardProgram, error) {
	rows, err := q.Query(ctx,
		`SELECT id, code, name, mode, period_type, timezone, week_start_day, reset_on_missed_day, starts_at, ends_at, sort_order
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
		var p programRow
		var weekStart int16
		if err := rows.Scan(&p.ID, &p.Code, &p.Name, &p.Mode, &p.PeriodType, &p.timezone, &weekStart, &p.ResetOnMissedDay,
			&p.StartsAt, &p.EndsAt, &p.sortOrder); err != nil {
			rows.Close()
			return nil, err
		}
		p.WeekStartDay = int(weekStart)
		raw = append(raw, p)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	atMs := at.UnixMilli()
	programs := make([]*RewardProgram, 0, len(raw))
	for _, p := range raw {
		if (p.StartsAt != nil && *p.StartsAt > atMs) || (p.EndsAt != nil && *p.EndsAt < atMs) {
			continue // a campaign not yet open, or over
		}
		loc, err := r.zone(p.timezone)
		if err != nil {
			r.leftOut("reward program left out", "program", p.Code, "reason", "unknown timezone "+p.timezone)
			continue
		}
		period, err := periodOf(p.PeriodType, p.WeekStartDay, loc, at)
		if err != nil {
			r.leftOut("reward program left out", "program", p.Code, "reason", err.Error())
			continue
		}
		program := p.RewardProgram
		program.Timezone = p.timezone
		program.loc = loc
		program.PeriodStart, program.PeriodEnd = period.StartMs, period.EndMs
		programs = append(programs, &program)
	}
	return programs, nil
}

// period is the program's period at `at`.
func (p *RewardProgram) period(at time.Time) rewardPeriod {
	period, _ := periodOf(p.PeriodType, p.WeekStartDay, p.loc, at) // validated in loadPrograms
	return period
}

// loadClaims reads this player's claims of the program in the period,
// newest first — the one read the streak needs, off
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

// state is one program's state for one player from its claims in the current
// period and its days, each resolved for the player.
func (r *RewardPrograms) state(ctx context.Context, q queryer, userID string, p *RewardProgram, at time.Time) (RewardProgramState, error) {
	period := p.period(at)
	claims, err := loadClaims(ctx, q, userID, p.ID, period.StartMs)
	if err != nil {
		return RewardProgramState{}, err
	}
	rows, err := loadRewards(ctx, q, p.ID)
	if err != nil {
		return RewardProgramState{}, err
	}
	s := RewardProgramState{
		Program:     *p,
		Today:       period.Today.String(),
		DayOfPeriod: period.DayOfPeriod,
		PeriodDays:  period.Days,
		Rewards:     make([]RewardDay, 0, len(rows)),
	}
	var claimedDay func(day int) bool
	switch p.Mode {
	case RewardModeLoginStreak:
		var run int
		s.CurrentDay, s.ClaimedToday, run = streakAt(claims, period.Today, p.ResetOnMissedDay)
		s.ClaimedDays = run
		claimedDay = func(day int) bool { return day <= run }
	default:
		var claimed map[int]bool
		s.CurrentDay, s.ClaimedToday, claimed = calendarAt(claims, period)
		s.ClaimedDays = len(claimed)
		claimedDay = func(day int) bool { return claimed[day] }
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
		day.Claimed = claimedDay(day.Day)
		s.Rewards = append(s.Rewards, day)
	}
	return s, nil
}

// State is GET /api/reward-programs for one player: every program running
// now, in sort_order, as it stands for them. Nothing is granted. Allowed
// anywhere, at a table included — it only reads.
func (r *RewardPrograms) State(ctx context.Context, userID string) ([]RewardProgramState, error) {
	at := r.nowTime()
	programs, err := r.loadPrograms(ctx, r.db.Pool, at)
	if err != nil {
		return nil, err
	}
	states := make([]RewardProgramState, 0, len(programs))
	for _, p := range programs {
		s, err := r.state(ctx, r.db.Pool, userID, p, at)
		if err != nil {
			return nil, err
		}
		states = append(states, s)
	}
	return states, nil
}

// ------------------------------------------------------------------- claim

// Claim is POST /api/reward-programs/claim: today's reward of every program
// running now, each in ONE transaction of its own, in sort_order:
//
//	SELECT chips FROM users WHERE id = $1 FOR UPDATE   lock the wallet (no row → unknown_user)
//	this player's claims of the program in the period   newest first (loadClaims)
//	today already claimed?                              → nothing, and on to the next program
//	the day number                                      LOGIN_STREAK: streakAt; CALENDAR: today's position
//	the day's reward, resolved for the player           a day with none, or one it cannot grant: NO_REWARD
//	the reward granted                                  grantReward: chips through chip_ledger, the rest as deltas or ownership rows
//	INSERT user_reward_claims                           the snapshot and the key
//
// All of a program's claim commits or none of it does: a reward that cannot
// be granted leaves no claim, and a claim that cannot be written takes the
// reward back out with it. The wallet lock serialises one player's claims,
// so two requests at once — two devices, a retry racing its first attempt —
// queue, and the second finds the first's row; two claims that somehow both
// passed the look (another pool's transaction committing between the look
// and the write) collide on user_reward_claims_period_idx or on action_id,
// roll back, and are answered "already claimed" all the same. Nothing the
// caller sends decides anything: the server works out the day and the reward.
//
// A day with no reward — none configured, or one this build cannot grant —
// is still CLAIMED (recorded as NO_REWARD), so a login streak counts through
// it; it is not in Granted. Lobby-only: the caller runs it under the
// player's seat lock (auth: WhileUnseated), because a CHIPS reward moves a
// wallet only the lobby may move (CLAUDE.md §5.1). Each program is
// independent: one that fails (a database error) stops the call with its
// error, and the ones claimed before it stay claimed.
func (r *RewardPrograms) Claim(ctx context.Context, userID string) (*RewardClaimOutcome, error) {
	at := r.nowTime()
	programs, err := r.loadPrograms(ctx, r.db.Pool, at)
	if err != nil {
		return nil, err
	}
	out := &RewardClaimOutcome{Granted: []RewardGrant{}}
	for _, p := range programs {
		grant, err := r.claimOne(ctx, userID, p, at)
		if err != nil {
			return nil, err
		}
		if grant != nil {
			out.Granted = append(out.Granted, *grant)
		}
	}
	// As everything stands now, after the last commit.
	for _, p := range programs {
		s, err := r.state(ctx, r.db.Pool, userID, p, at)
		if err != nil {
			return nil, err
		}
		out.Programs = append(out.Programs, s)
	}
	if out.Programs == nil {
		out.Programs = []RewardProgramState{}
	}
	if out.User, err = r.users.FindByID(ctx, userID); err != nil {
		return nil, err
	}
	return out, nil
}

// claimOne claims today's reward of one program (Claim's transaction); nil
// when today was already claimed, or the day gives nothing.
func (r *RewardPrograms) claimOne(ctx context.Context, userID string, p *RewardProgram, at time.Time) (*RewardGrant, error) {
	period := p.period(at)
	key := RewardClaimActionID(userID, p.Code, period.Today.String())
	atMs := at.UnixMilli()
	var grant *RewardGrant
	err := r.db.WithTx(ctx, func(tx pgx.Tx) error {
		grant = nil
		chips, err := lockWallet(ctx, tx, userID)
		if err != nil {
			return err
		}
		claims, err := loadClaims(ctx, tx, userID, p.ID, period.StartMs)
		if err != nil {
			return err
		}
		var day int
		switch p.Mode {
		case RewardModeLoginStreak:
			var claimedToday bool
			if day, claimedToday, _ = streakAt(claims, period.Today, p.ResetOnMissedDay); claimedToday {
				return nil
			}
		default:
			var claimedToday bool
			if day, claimedToday, _ = calendarAt(claims, period); claimedToday {
				return nil
			}
		}

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
		// Today's claim committed in the meantime: nothing more to give.
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return grant, nil
}
