package db

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// purgeableReasons are the ONLY chip_ledger rows PurgeLedger is ever allowed
// to remove: the three checkpoint writes (pack, leave/switch, hand-end),
// whose UNIQUE action_id guards a short server-retry window (see
// game.Ledger's doc comment), not a standing fraud guard. 'purchase'
// ("gplay:<purchaseToken>") must never appear here — its UNIQUE index is what
// stops a replayed Google Play receipt being credited twice, and a replay can
// arrive long after any reasonable retention window. 'milestone_reward',
// 'timed_bonus' and 'welcome_bonus' are excluded for the same reason: their
// dedup isn't network-retry-bounded, it's "did this reward already fire"
// bounded, and nothing else in the system re-derives that if the row is gone.
var purgeableReasons = []string{
	"hand_win",
	"hand_loss",
	"hand_packed",
	"hand_left",
}

// PurgeLedger deletes chip_ledger rows older than olderThanMs (epoch ms) whose
// reason is one of purgeableReasons. It is the only caller in the codebase
// allowed to delete from chip_ledger, and it can only do so because the
// trigger (schema.sql, chip_ledger_immutable) checks for
// `SET LOCAL app.ledger_purge = 'on'` — set here, inside this one
// transaction, never anywhere else. SET LOCAL is transaction-scoped: it
// reverts at COMMIT/ROLLBACK and never leaks onto a pooled connection handed
// to a later, unrelated query.
//
// Returns the number of rows removed. Safe to call on a schedule — an empty
// result is not an error, just nothing old enough yet.
func (d *DB) PurgeLedger(ctx context.Context, olderThanMs int64) (int64, error) {
	var deleted int64
	err := d.WithTx(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "SET LOCAL app.ledger_purge = 'on'"); err != nil {
			return fmt.Errorf("enable purge for this transaction: %w", err)
		}
		tag, err := tx.Exec(ctx,
			`DELETE FROM chip_ledger
			  WHERE created_at < $1
			    AND reason = ANY($2)`,
			olderThanMs, purgeableReasons,
		)
		if err != nil {
			return fmt.Errorf("purge chip_ledger: %w", err)
		}
		deleted = tag.RowsAffected()
		return nil
	})
	if err != nil {
		return 0, err
	}
	if d.log != nil && deleted > 0 {
		d.log.Info("chip_ledger purged", "rows", deleted, "olderThanMs", olderThanMs, "reasons", purgeableReasons)
	}
	return deleted, nil
}
