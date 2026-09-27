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
// the window — when one more will be accepted.
type ReportLimitReached struct {
	RetryAt int64
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
		if limits.MaxPerReporter > 0 && limits.Window > 0 {
			windowMs := limits.Window.Milliseconds()
			var count int64
			var oldest *int64
			if err := tx.QueryRow(ctx,
				`SELECT count(*), min(created_at) FROM player_reports
				  WHERE reporter_user_id = $1 AND created_at > $2`,
				report.ReporterID, stamp-windowMs).Scan(&count, &oldest); err != nil {
				return err
			}
			if count >= int64(limits.MaxPerReporter) {
				retryAt := stamp + windowMs
				if oldest != nil {
					// The window counts reports with created_at > now − window,
					// so the oldest stops counting the moment now reaches its
					// created_at + window.
					retryAt = *oldest + windowMs
				}
				return &ReportLimitReached{RetryAt: retryAt}
			}
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
