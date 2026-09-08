package db

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// LedgerReasonRefund is the chip_ledger.reason of a startup refund: an open
// pot whose table did not survive the restart is handed back to the players
// who staked it (LIVE_STATE_PLAN.md startup step 3).
const LedgerReasonRefund = "refund"

// RefundActionID is the deterministic chip_ledger.action_id of one
// contributor's refund: "<handId>:refund:<userId>". UNIQUE on the ledger, so
// a refund that runs twice (two restarts before anyone notices, a crash
// between the ledger row and the pot close) credits nobody twice.
func RefundActionID(handID, userID string) string {
	return handID + ":refund:" + userID
}

// RefundReport is what RefundOrphanedPots did.
type RefundReport struct {
	// Pots is the number of open pots closed by this run.
	Pots int
	// Contributors is the number of refund rows written (one per player per
	// pot).
	Contributors int
	// Chips is the total credited back.
	Chips int64
	// AlreadyRefunded counts contributors whose refund row already existed
	// (an earlier run wrote it and did not get to close the pot): nothing
	// was credited for them this time.
	AlreadyRefunded int
	// Skipped is the number of open pots left alone because their hand is
	// live (in liveHandIDs).
	Skipped int
}

// RefundOrphanedPots returns every open pot that no live table holds
// (LIVE_STATE_PLAN.md startup step 3). A pot is open while pots.closed_at IS
// NULL; it is orphaned when its hand_id is not in liveHandIDs — the hands the
// tables rebuilt from the live store are still playing. Every other open pot
// belonged to a hand that died with the previous process: the boots and bets
// were banked as they were made, the settlement never came, and without this
// step the chips would stay in the pot for good.
//
// One transaction per pot:
//
//	SELECT room_id, closed_at FROM pots WHERE hand_id = $1 FOR UPDATE   (closed meanwhile → nothing to do)
//	SELECT user_id, -SUM(delta) FROM chip_ledger WHERE hand_id = $1
//	  AND reason IN ('boot','bet','show') GROUP BY user_id ORDER BY user_id
//	-- per contributor, user_id ascending (the ledger's lock order):
//	SELECT chips FROM users WHERE id = $1 FOR UPDATE            (no row → skip)
//	INSERT INTO chip_ledger (…, action_id '<handId>:refund:<userId>', delta +total, reason 'refund')
//	  ON CONFLICT (action_id) DO NOTHING                       (0 rows → already refunded, no credit)
//	UPDATE users SET chips = chips + total
//	UPDATE pots SET closed_at = now, winner_id = NULL
//
// The pot row is locked first so a pot that was closed since the listing is
// left untouched with nothing credited; the wallets follow in ascending id,
// the order every ledger transaction uses, so refunds cannot deadlock each
// other or live play on other tables (a live table's Settle touches a
// different pot row). A hands row, if one exists, is left alone.
// SUM(chip_ledger.delta) == users.chips holds afterwards because the credit
// and its ledger row are one transaction.
//
// Failures: a pot whose transaction fails is logged and skipped (the next
// start retries it); the first such error is returned with the report of
// what did succeed, so the caller can log both.
func (d *DB) RefundOrphanedPots(ctx context.Context, liveHandIDs map[string]bool) (RefundReport, error) {
	return d.refundOrphanedPots(ctx, liveHandIDs, nil)
}

// refundOrphanedPots is RefundOrphanedPots with an injectable clock (tests
// pin created_at).
func (d *DB) refundOrphanedPots(ctx context.Context, liveHandIDs map[string]bool, clock func() time.Time) (RefundReport, error) {
	var report RefundReport
	rows, err := d.Pool.Query(ctx, `SELECT hand_id FROM pots WHERE closed_at IS NULL ORDER BY opened_at, hand_id`)
	if err != nil {
		return report, fmt.Errorf("list open pots: %w", err)
	}
	var open []string
	for rows.Next() {
		var handID string
		if err := rows.Scan(&handID); err != nil {
			rows.Close()
			return report, err
		}
		open = append(open, handID)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return report, fmt.Errorf("list open pots: %w", err)
	}

	var first error
	for _, handID := range open {
		if liveHandIDs[handID] {
			report.Skipped++
			continue
		}
		result, err := d.refundPot(ctx, handID, clock)
		if err != nil {
			d.logger().Error("pot refund failed", "handId", handID, "error", err.Error())
			if first == nil {
				first = fmt.Errorf("refund pot %s: %w", handID, err)
			}
			continue
		}
		if !result.closed {
			continue // closed by someone else between the listing and the lock
		}
		report.Pots++
		report.Contributors += result.contributors
		report.Chips += result.chips
		report.AlreadyRefunded += result.alreadyRefunded
		d.logger().Info("orphaned pot refunded", "handId", handID, "roomId", result.roomID,
			"contributors", result.contributors, "chips", result.chips, "alreadyRefunded", result.alreadyRefunded)
	}
	return report, first
}

// potRefund is one refundPot outcome.
type potRefund struct {
	roomID          string
	closed          bool
	contributors    int
	chips           int64
	alreadyRefunded int
}

// refundPot refunds and closes one open pot in one transaction (see
// RefundOrphanedPots for the statement order).
func (d *DB) refundPot(ctx context.Context, handID string, clock func() time.Time) (potRefund, error) {
	var out potRefund
	err := d.WithTx(ctx, func(tx pgx.Tx) error {
		at := now(clock)

		// The pot row is locked first: a pot closed since the listing (an
		// earlier run, or a settlement that raced this one) is left exactly
		// as it is, with nothing credited. Refunds lock only their own pot
		// row before the wallets, and the live tables' Settle takes its own
		// pot row after the wallets — different rows, so no cycle; two
		// refunds lock wallets in the same ascending order as every other
		// ledger transaction.
		var closedAt *int64
		if err := tx.QueryRow(ctx, `SELECT room_id, closed_at FROM pots WHERE hand_id = $1 FOR UPDATE`, handID).Scan(&out.roomID, &closedAt); err != nil {
			return err
		}
		if closedAt != nil {
			return nil
		}

		type contributor struct {
			userID string
			total  int64
		}
		var contributors []contributor
		rows, err := tx.Query(ctx, `SELECT user_id, -SUM(delta)::bigint FROM chip_ledger
		   WHERE hand_id = $1 AND reason IN ($2, $3, $4)
		   GROUP BY user_id ORDER BY user_id`, handID, game.LedgerReasonBoot, game.LedgerReasonBet, game.LedgerReasonShow)
		if err != nil {
			return err
		}
		for rows.Next() {
			var c contributor
			if err := rows.Scan(&c.userID, &c.total); err != nil {
				rows.Close()
				return err
			}
			contributors = append(contributors, c)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}

		for _, c := range contributors {
			if c.total <= 0 {
				continue // nothing staked (cannot happen: every row summed is a debit)
			}
			chips, err := lockWallet(ctx, tx, c.userID)
			if err != nil {
				if game.CodeOf(err, "") == game.CodeUnknownUser {
					continue // the account is gone; its ledger rows went with it (ON DELETE CASCADE)
				}
				return err
			}
			balance := chips + c.total
			// The ledger row is the idempotency key: inserted → credit the
			// wallet in the same transaction; already there → an earlier run
			// credited this player and died before closing the pot.
			tag, err := tx.Exec(ctx, `INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at)
			   VALUES ($1, $2, $3, $4, $5, $6, $7)
			   ON CONFLICT (action_id) DO NOTHING`,
				c.userID, handID, RefundActionID(handID, c.userID), c.total, balance, LedgerReasonRefund, at)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 0 {
				out.alreadyRefunded++
				continue
			}
			if _, err := tx.Exec(ctx, `UPDATE users SET chips = $1, updated_at = $2 WHERE id = $3`, balance, at, c.userID); err != nil {
				return err
			}
			out.contributors++
			out.chips += c.total
		}

		if _, err := tx.Exec(ctx, `UPDATE pots SET closed_at = $1, winner_id = NULL WHERE hand_id = $2`, at, handID); err != nil {
			return err
		}
		out.closed = true
		return nil
	})
	if err != nil {
		return potRefund{}, err
	}
	return out, nil
}

// logger is the DB's logger (a discard logger when Open was given none).
func (d *DB) logger() *slog.Logger {
	if d.log == nil {
		return slog.New(slog.DiscardHandler)
	}
	return d.log
}
