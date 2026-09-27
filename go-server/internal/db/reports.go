package db

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// Report Player (owner, 27 Sep 2026): a player at a table reports another
// player they share (or shared, moments ago) that table with — the rows of
// player_reports (V1.0.0's PLAYER REPORTS). This file is the one writer of
// that table, and it writes nothing else: a report is MODERATION AUDIT, and
// submitting one moves no chip, touches no seat and changes nothing about a
// hand. What the report is about — the table, the hand, the game — comes from
// the server's own table state (the caller's game.ReportContext), never from
// the client.

// The statuses a report moves through. A report is filed PENDING; the rest are
// moderation's to set (no moderation is built yet) and never a player's.
const (
	ReportPending     = "PENDING"
	ReportUnderReview = "UNDER_REVIEW"
	ReportActionTaken = "ACTION_TAKEN"
	ReportDismissed   = "DISMISSED"
)

// The report store's refusals. Values, compared with errors.Is, so the REST
// layer words each as its own code.
var (
	// ErrReportedNotFound is a report about an account that no longer exists
	// to be reported: none with that id, or a deleted (pseudonymised) one.
	ErrReportedNotFound = errors.New("db: the reported player does not exist")
	// ErrSelfReport is a player reporting themselves (the REST layer refuses
	// it first; the table's CHECK is the last word).
	ErrSelfReport = errors.New("db: a report about oneself")
	// ErrAlreadyReported is a second report by the same reporter about the
	// same player for the same hand, or within ReportLimits.PairWindow of
	// their last one.
	ErrAlreadyReported = errors.New("db: already reported")
	// ErrReportLimitReached is a reporter who has filed ReportLimits.
	// MaxPerReporter reports within ReportLimits.Window. Submit returns it as
	// a *ReportLimitReached, which says when the oldest of those leaves the
	// window.
	ErrReportLimitReached = errors.New("db: report limit reached")
)

// ReportLimitReached is Submit refusing a report because its reporter has used
// every report the window allows: errors.Is(err, ErrReportLimitReached) is
// true of it, and RetryAt (epoch ms) is when the oldest report counted leaves
// the window — when one more will be accepted. Quota is the reporter's
// standing as the refusal found it (Quota.AvailableAt == RetryAt).
type ReportLimitReached struct {
	RetryAt int64
	Quota   ReportQuota
}

func (e *ReportLimitReached) Error() string {
	return fmt.Sprintf("%v: next report from %d", ErrReportLimitReached, e.RetryAt)
}

// Unwrap makes errors.Is(err, ErrReportLimitReached) true.
func (e *ReportLimitReached) Unwrap() error { return ErrReportLimitReached }

// PlayerReport is one report to file. ReporterID is the authenticated player;
// ReportedID, Reason and Description are what the client sent, already
// validated; the rest is the server's own account of where the two met
// (game.ReportContext): the engine code, the category, the variant ("" for
// none), the room's id and the hand's ("" for none).
type PlayerReport struct {
	ReporterID  string
	ReportedID  string
	Reason      string
	Description string
	Game        string
	Category    string
	Variant     string
	TableID     string
	HandID      string
}

// ReportLimits are the abuse guards Submit enforces, in the database, inside
// the transaction that files the report (config.ReportConfig):
//
//   - MaxPerReporter reports per reporter within Window, a ROLLING window
//     counted from the reporter's own rows (0: no such limit) — so a restart,
//     a reconnect or a second server can never reset it;
//   - one report per reporter → reported player within PairWindow (0: none
//     beyond the per-hand rule);
//   - and always one report per reporter → reported player per hand.
type ReportLimits struct {
	MaxPerReporter int
	Window         time.Duration
	PairWindow     time.Duration
}

// ReportQuota is how a reporter stands against ReportLimits.MaxPerReporter
// (owner, 27 Sep 2026: "if user has reported 2 player, then reporting by him
// should be disabled in UI, and show a cool down time in UI when can he
// report again"): the reports they have filed within the window, how many
// more it allows, and — when none — the moment one more will be accepted.
// Counted from their own rows, as Submit counts them, so the app is told
// exactly what Submit will decide.
type ReportQuota struct {
	// Max is the limit (MaxPerReporter); 0 = no per-reporter limit, and then
	// Used and Remaining are 0 too.
	Max int
	// Used is the reports this reporter filed within the window, ending now.
	Used int
	// Remaining is Max − Used, never below 0.
	Remaining int
	// Window is the rolling window the reports are counted in.
	Window time.Duration
	// AvailableAt (epoch ms) is when the next report will be accepted, when
	// Remaining is 0: the moment enough of the reports counted leave the
	// window. 0 while one can be filed now.
	AvailableAt int64
	// Now (epoch ms) is the store's clock when it counted — so a caller can
	// say how long is left without trusting another clock.
	Now int64
}

// Limited reports whether no report can be filed now.
func (q ReportQuota) Limited() bool { return q.Max > 0 && q.Remaining == 0 }

// reportQuota counts reporter's reports within limits.Window ending at stamp
// (created_at > stamp − window, as Submit counts them). The retry moment is
// the created_at of the report whose leaving brings the count under the
// limit, plus the window: the oldest one when exactly Max are counted, a
// later one where the limit was lowered under what a reporter had filed.
func reportQuota(ctx context.Context, q queryer, reporterID string, stamp int64, limits ReportLimits) (ReportQuota, error) {
	quota := ReportQuota{Window: limits.Window, Now: stamp}
	if limits.MaxPerReporter <= 0 || limits.Window <= 0 {
		return quota, nil
	}
	quota.Max = limits.MaxPerReporter
	windowMs := limits.Window.Milliseconds()
	rows, err := q.Query(ctx,
		`SELECT created_at FROM player_reports
		  WHERE reporter_user_id = $1 AND created_at > $2
		  ORDER BY created_at, id`,
		reporterID, stamp-windowMs)
	if err != nil {
		return quota, err
	}
	var times []int64
	for rows.Next() {
		var at int64
		if err := rows.Scan(&at); err != nil {
			rows.Close()
			return quota, err
		}
		times = append(times, at)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return quota, err
	}
	quota.Used = len(times)
	quota.Remaining = max(quota.Max-quota.Used, 0)
	if quota.Remaining == 0 {
		// The window counts reports with created_at > now − window, so a
		// report stops counting the moment now reaches its created_at +
		// window; the count falls under Max once the (Used − Max + 1)th
		// oldest has.
		quota.AvailableAt = times[quota.Used-quota.Max] + windowMs
	}
	return quota, nil
}

// Quota is reporterID's standing against limits now: what the app shows
// before a report is written, so a player who has used every report sees the
// Report line switched off with the time it opens again. A read, taking no
// lock; Submit decides, under its own.
func (r *Reports) Quota(ctx context.Context, reporterID string, limits ReportLimits) (ReportQuota, error) {
	return reportQuota(ctx, r.db.Pool, reporterID, now(r.clock), limits)
}

// Reports is the player-report store.
type Reports struct {
	db    *DB
	clock func() time.Time
	// counted is a test seam (SetReportCounted): run after the window's
	// reports are counted, before the insert. nil in production.
	counted func()
}

// NewReports builds the store; clock nil → time.Now. created_at and
// updated_at are stamped from it, never from the client.
func NewReports(d *DB, clock func() time.Time) *Reports {
	return &Reports{db: d, clock: clock}
}

// reportLockNamespace is the first key of the transaction-scoped advisory lock
// Submit takes per reporter (pg_advisory_xact_lock(int4, int4)); the second is
// hashtext(reporter). The two-key form has a key space of its own, apart from
// the one-key schema lock db.Open takes, so the two can never collide. Two
// reporters whose ids hash alike merely wait for each other.
const reportLockNamespace = `hashtext('king-teenpatti:player_report')`

// oneReportPerHandIndex is player_reports' partial unique index on (hand_id,
// reporter, reported): a 23505 naming it is a second report of the same hand.
const oneReportPerHandIndex = "player_reports_one_per_hand"

// Submit files report under limits and returns its id. ONE transaction:
//
//	pg_advisory_xact_lock(<namespace>, hashtext(reporter))   one reporter at a time
//	lock both accounts FOR KEY SHARE, in id order             (reported gone → ErrReportedNotFound)
//	a report of this pair for this hand                       → ErrAlreadyReported
//	a report of this pair within PairWindow                   → ErrAlreadyReported
//	MaxPerReporter reports by reporter within Window          → *ReportLimitReached
//	INSERT INTO player_reports … 'PENDING', now, now
//
// The advisory lock serialises every report of ONE reporter, so the count and
// the insert that follows it are atomic: two reports sent in the same instant
// with one slot left file exactly one. It is not a row lock on users — nothing
// but another report of the same reporter ever waits for it, and it is
// released with the transaction. The accounts are then locked FOR KEY SHARE,
// the mode the foreign keys take anyway and the one the friends store takes,
// in id order: a wallet lock a hand's settlement holds (FOR UPDATE, ascending
// id order too) can make this wait a moment, but never the other way round in
// a cycle, and an account deletion (its own row FOR UPDATE) cannot land
// between the look and the insert.
func (r *Reports) Submit(ctx context.Context, report PlayerReport, limits ReportLimits) (int64, error) {
	if report.ReporterID == report.ReportedID {
		return 0, ErrSelfReport
	}
	var id int64
	err := r.db.WithTx(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(`+reportLockNamespace+`, hashtext($1))`, report.ReporterID); err != nil {
			return err
		}
		live, err := lockReportAccounts(ctx, tx, report.ReporterID, report.ReportedID)
		if err != nil {
			return err
		}
		if !live[report.ReportedID] {
			return ErrReportedNotFound
		}
		if !live[report.ReporterID] {
			return fmt.Errorf("report from account %s, which is gone", report.ReporterID)
		}
		stamp := now(r.clock)
		if report.HandID != "" {
			var again bool
			if err := tx.QueryRow(ctx,
				`SELECT EXISTS (SELECT 1 FROM player_reports
				                 WHERE hand_id = $1 AND reporter_user_id = $2 AND reported_user_id = $3)`,
				report.HandID, report.ReporterID, report.ReportedID).Scan(&again); err != nil {
				return err
			}
			if again {
				return ErrAlreadyReported
			}
		}
		if limits.PairWindow > 0 {
			var recent bool
			if err := tx.QueryRow(ctx,
				`SELECT EXISTS (SELECT 1 FROM player_reports
				                 WHERE reporter_user_id = $1 AND reported_user_id = $2 AND created_at > $3)`,
				report.ReporterID, report.ReportedID, stamp-limits.PairWindow.Milliseconds()).Scan(&recent); err != nil {
				return err
			}
			if recent {
				return ErrAlreadyReported
			}
		}
		quota, err := reportQuota(ctx, tx, report.ReporterID, stamp, limits)
		if err != nil {
			return err
		}
		if quota.Limited() {
			return &ReportLimitReached{RetryAt: quota.AvailableAt, Quota: quota}
		}
		if r.counted != nil {
			r.counted()
		}
		return tx.QueryRow(ctx,
			`INSERT INTO player_reports
			   (reporter_user_id, reported_user_id, reason, description, game, category, variant,
			    table_id, hand_id, status, created_at, updated_at)
			 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'PENDING', $10, $10)
			 RETURNING id`,
			report.ReporterID, report.ReportedID, report.Reason, nullIfEmpty(report.Description),
			report.Game, report.Category, nullIfEmpty(report.Variant), report.TableID,
			nullIfEmpty(report.HandID), stamp).Scan(&id)
	})
	if err != nil {
		// Only another transaction holding the same advisory lock could have
		// raced this insert, and none can: the index is the last word should a
		// report ever be filed around Submit.
		if isUniqueViolationOn(err, oneReportPerHandIndex) {
			return 0, ErrAlreadyReported
		}
		return 0, err
	}
	return id, nil
}

// lockReportAccounts locks both accounts' rows FOR KEY SHARE, in id order (the
// order every multi-account lock in this package takes), and reports which of
// them still exist to take part in a report: not deleted. A disabled account
// (users.is_active FALSE) may still be reported — support switching it off is
// no reason to lose what it was reported for; the reporter was authenticated,
// which a disabled account cannot be.
func lockReportAccounts(ctx context.Context, tx pgx.Tx, a, b string) (map[string]bool, error) {
	rows, err := tx.Query(ctx,
		`SELECT u.id, u.deleted_at = 0 FROM users u WHERE u.id IN ($1, $2) ORDER BY u.id FOR KEY SHARE`, a, b)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	live := map[string]bool{}
	for rows.Next() {
		var id string
		var ok bool
		if err := rows.Scan(&id, &ok); err != nil {
			return nil, err
		}
		live[id] = ok
	}
	return live, rows.Err()
}

// FiledReport is one report as the player who filed it lists it (owner,
// 27 Sep 2026: "add one more tab, where user can see all the players he
// reported in detail status, description, time he reported but don't show
// the reported user id"): who it is about as a card (the name and picture,
// resolved as Friends resolves them — Reported.UserID is for the store's own
// use and never reaches the wire), why, what they wrote, where they met, how
// moderation has it, and when. Table and hand ids are not read at all.
type FiledReport struct {
	Reported FriendPlayer
	// ReportedGone is true when the reported account has been deleted since
	// (pseudonymised: no name, no picture).
	ReportedGone bool
	Reason       string
	Description  string
	Game         string
	Category     string
	Variant      string
	Status       string
	CreatedAt    int64
	UpdatedAt    int64
}

// MaxFiledReportsListed is the most reports Filed lists: the newest. At two a
// day (REPORT_MAX_PER_REPORTER) that is more than a month and a half of them.
const MaxFiledReportsListed = 100

// Filed is reporterID's own reports, newest first (created_at, then id, both
// descending), at most limit of them (≤ 0 or over MaxFiledReportsListed:
// MaxFiledReportsListed). A read of the reporter's own rows, off the
// (reporter_user_id, created_at) index; a report about an account deleted
// since is listed with ReportedGone set.
func (r *Reports) Filed(ctx context.Context, reporterID string, limit int) ([]FiledReport, error) {
	if limit <= 0 || limit > MaxFiledReportsListed {
		limit = MaxFiledReportsListed
	}
	rows, err := r.db.Pool.Query(ctx,
		`SELECT `+friendPlayerColumns+`, u.deleted_at <> 0,
		        pr.reason, COALESCE(pr.description, ''), pr.game, pr.category,
		        COALESCE(pr.variant, ''), pr.status, pr.created_at, pr.updated_at
		   FROM player_reports pr
		   JOIN users u ON u.id = pr.reported_user_id`+friendPictureJoin+`
		  WHERE pr.reporter_user_id = $1
		  ORDER BY pr.created_at DESC, pr.id DESC
		  LIMIT $2`,
		reporterID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []FiledReport{}
	for rows.Next() {
		var f FiledReport
		p, err := scanFriendPlayer(rows, &f.ReportedGone, &f.Reason, &f.Description, &f.Game,
			&f.Category, &f.Variant, &f.Status, &f.CreatedAt, &f.UpdatedAt)
		if err != nil {
			return nil, err
		}
		f.Reported = p
		if f.ReportedGone {
			f.Reported.DisplayName = ""
			f.Reported.PictureID = nil
			f.Reported.PictureURL = nil
		}
		out = append(out, f)
	}
	return out, rows.Err()
}
