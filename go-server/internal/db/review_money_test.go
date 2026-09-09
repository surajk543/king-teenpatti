package db_test

// Adversarial money review against real PostgreSQL: lock ordering between
// two tables' transactions that touch the same wallets.

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// pgDeadlockDetected is SQLSTATE 40P01.
const pgDeadlockDetected = "40P01"

// reviewAppName tags this file's connections in pg_stat_activity.
const reviewAppName = "review_money_test"

// withAppName appends application_name to a connection URL.
func withAppName(url, name string) string {
	sep := "?"
	if strings.Contains(url, "?") {
		sep = "&"
	}
	return url + sep + "application_name=" + name
}

func isDeadlock(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == pgDeadlockDetected
}

// The `hands` FK deadlock this file used to reproduce is GONE WITH THE TABLE.
// It was: Settle's first statement inserted into `hands`, whose winner_id
// foreign key took a KEY SHARE lock on the winner's users row before any
// wallet had been locked in ascending order, so a boot on another table
// holding a lower wallet could cycle with it (DECISIONS §2 fixed the ordering
// by moving the insert after the locks). Since 9 Sep 2026 there is no `hands`
// table and no boot transaction: every ledger transaction now takes wallet
// locks and nothing else, in ascending user id. The hammer below is what
// pins that.

// waitForLockWaiters polls pg_locks until n backends of this schema are
// waiting on a lock.
func waitForLockWaiters(t *testing.T, f *fixture, n int64) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		waiting := f.scalar(`SELECT COUNT(*) FROM pg_stat_activity
		   WHERE datname = current_database() AND application_name = $1 AND wait_event_type = 'Lock'`, reviewAppName)
		if waiting >= n {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("expected %d backends waiting on locks", n)
}

// TestReviewConcurrentTablesSharingWalletsNeverDeadlock hammers both ledger
// transactions (the per-player checkpoint and the hand-end settle) from many
// "tables" at once over a small pool of wallets — far more overlap than the
// game allows (one seat per player), so any remaining lock-order cycle shows
// up as SQLSTATE 40P01. Every wallet must reconcile with its ledger
// afterwards, which is now the only money cross-check there is.
func TestReviewConcurrentTablesSharingWalletsNeverDeadlock(t *testing.T) {
	f := newFixture(t)
	const (
		players = 6
		workers = 8
		hands   = 25
	)
	pool := make([]*db.User, players)
	for i := range pool {
		pool[i] = f.user("w")
	}
	ctx, cancel := context.WithTimeout(f.ctx, 60*time.Second)
	defer cancel()

	type outcome struct{ deadlocks, refused, settled int }
	results := make(chan outcome, workers)
	for w := 0; w < workers; w++ {
		go func(w int) {
			var out outcome
			roomID := "room-" + string(rune('A'+w))
			for h := 0; h < hands; h++ {
				// A pseudo-random 2–3 player subset, deterministic per worker/hand.
				n := 2 + (w+h)%2
				seen := map[int]bool{}
				var seats []string
				for k := 0; len(seats) < n; k++ {
					idx := (w*7 + h*3 + k*5) % players
					if seen[idx] {
						continue
					}
					seen[idx] = true
					seats = append(seats, pool[idx].ID)
				}
				handID := roomID + "-hand-" + string(rune('a'+h%26)) + string(rune('a'+h/26))
				const staked int64 = 600
				pot := staked * int64(len(seats))

				// One player packs (their own checkpoint), the rest ride the
				// settlement — the two transaction shapes, interleaved.
				packed := seats[h%len(seats)]
				winner := seats[(h+1)%len(seats)]
				if _, err := f.ledger.Checkpoint(ctx, game.CheckpointRequest{RoomID: roomID, HandID: handID,
					Entry: game.SettleEntry{UserID: packed, Delta: -staked, Reason: game.LedgerReasonHandPacked,
						ActionID: game.PackedActionID(handID, packed)}}); err != nil {
					if isDeadlock(db.Classify(err).Cause) {
						out.deadlocks++
					} else {
						out.refused++
					}
					continue
				}

				var settleEntries []game.SettleEntry
				for _, id := range seats {
					delta := -staked
					switch {
					case id == winner:
						delta = pot - staked
					case id == packed:
						delta = 0 // already written at their pack
					}
					settleEntries = append(settleEntries, settleEntry(handID, id, delta, id == winner, true, pot))
				}
				_, err := f.ledger.Settle(ctx, game.SettleRequest{RoomID: roomID, HandID: handID, Entries: settleEntries})
				if err != nil {
					if isDeadlock(db.Classify(err).Cause) {
						out.deadlocks++
					} else {
						out.refused++
					}
					continue
				}
				out.settled++
			}
			results <- out
		}(w)
	}
	var total outcome
	for w := 0; w < workers; w++ {
		select {
		case out := <-results:
			total.deadlocks += out.deadlocks
			total.refused += out.refused
			total.settled += out.settled
		case <-ctx.Done():
			t.Fatal("workers did not finish")
		}
	}
	if total.deadlocks != 0 {
		t.Fatalf("REVIEW: %d deadlock(s) across %d settled hands", total.deadlocks, total.settled)
	}
	if total.settled == 0 {
		t.Fatal("nothing settled — the test exercised nothing")
	}
	f.reconcile()
	// Every hand's rows sum to zero: the chips moved between wallets and
	// nothing was created or destroyed.
	mismatched := f.scalar(`SELECT COUNT(*) FROM (
	    SELECT hand_id FROM chip_ledger WHERE hand_id IS NOT NULL GROUP BY hand_id HAVING SUM(delta) <> 0
	  ) x`)
	if mismatched != 0 {
		t.Fatalf("%d hand(s) did not conserve chips", mismatched)
	}
	t.Logf("settled %d hands, %d refusals, 0 deadlocks", total.settled, total.refused)
}
