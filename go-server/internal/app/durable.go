package app

import (
	"context"
	"fmt"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// The seams between the app and the game package's durable-backstop API
// (LIVE_STATE_PLAN.md "The durable backstop"), kept in one file.

// durableRestoreWired reports that wireDurable hands the RoomManager its
// SnapshotSink and DurableSource, so Restore's second pass (game_states →
// table → written back into the live store) is live. The app test that boots
// on an empty live store with only a game_states row runs when it is true.
const durableRestoreWired = true

// wireDurable hands the RoomManager its SnapshotSink (the writer: every table
// marks its room dirty after a live save) and DurableSource (the database:
// Restore's second pass rebuilds what the live store lacked, reconciled
// against the ledger). Both stay nil without a database — a nil *pointer in
// a non-nil interface would not be the no-op the game package promises.
func (a *App) wireDurable(opts *game.RoomManagerOptions, database *db.DB) {
	if a.snapshots != nil {
		opts.Snapshots = a.snapshots
	}
	if database != nil {
		opts.Durable = database
	}
}

// reconcileLive is one reconciler pass: rooms.ReconcileLive(ctx) re-saves
// every table, re-publishes the lobby index and re-sets every seat when the
// store answers. An unhealthy store, or any failed call inside the pass, is
// reported as an error so game_live_store_reconciles_total{result="error"}
// and the log show the outage.
func (a *App) reconcileLive(ctx context.Context) error {
	report := a.rooms.ReconcileLive(ctx)
	if !report.Healthy {
		return fmt.Errorf("live store unhealthy; reconcile skipped")
	}
	if report.Errors > 0 {
		return fmt.Errorf("reconcile: %d store call(s) failed (tables=%d published=%d seats=%d)",
			report.Errors, report.Tables, report.Published, report.Seats)
	}
	return nil
}

// restoreBreakdown reads the per-source counts out of a RestoreReport for
// the metrics and the summary line: FromLive / FromDurable (postgres),
// Reconciled (durable snapshots the ledger corrected), Rejected (too stale,
// left for the refund).
func restoreBreakdown(report game.RestoreReport) (fromLive, fromPostgres, reconciled, rejected int) {
	return report.FromLive, report.FromDurable, report.Reconciled, report.Rejected
}
