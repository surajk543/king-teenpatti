package app

import (
	"context"
	"fmt"
)

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
