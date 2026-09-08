package db_test

// Adversarial money review against real PostgreSQL: lock ordering between
// two tables' transactions that touch the same wallets.

import (
	"context"
	"errors"
	"sort"
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

// TestReviewSettleAndCollectBootCannotDeadlockOnSharedWallets: every ledger
// transaction is meant to lock wallet rows in ascending user id so two
// tables sharing a player cannot deadlock (ledger.js, DECISIONS.md §2). But
// Settle's first statement is INSERT INTO hands (… winner_id …), whose
// foreign key takes a KEY SHARE lock on the WINNER's users row before any
// wallet has been locked in order. A CollectBoot on another table that holds
// a lower-id wallet and wants the winner's wallet then waits on that KEY
// SHARE while the settle waits on the boot's wallet — a cycle PostgreSQL
// breaks after deadlock_timeout by aborting one of them.
//
// The game reaches this only through a settlement retry (the winner has
// since moved to another table whose boot starts as the retry fires), which
// is exactly when the money is already precarious. The interleaving is made
// deterministic here: a third transaction holds the winner's wallet so the
// settle parks on the KEY SHARE and the boot parks behind it on FOR UPDATE.
func TestReviewSettleAndCollectBootCannotDeadlockOnSharedWallets(t *testing.T) {
	f := newFixture(t)
	// A second pool on the same schema, tagged so the lock-wait probe below
	// counts only this test's backends (the dev database is shared with
	// whatever else is running against it).
	tagged, err := db.Open(f.ctx, db.Options{URL: withAppName(testURL(), reviewAppName), Schema: f.d.Schema, PoolMax: 3})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(tagged.Close)
	f.ledger = db.NewLedger(tagged, nil, nil)

	users := []*db.User{f.user("p"), f.user("q")}
	sort.Slice(users, func(i, j int) bool { return users[i].ID < users[j].ID })
	low, high := users[0], users[1] // wallets are locked low → high everywhere

	// Table A dealt and about to settle: high won the pot of 400.
	f.boot("room-A", "hand-A", 200, 1, low, high)
	settle := game.SettleRequest{
		Hand: game.HandRecord{ID: "hand-A", RoomID: "room-A", HandNo: 1, Pot: 400, WinnerID: ptr(high.ID),
			WinReason: game.WinLastStanding, BootAmount: 200, StartedAt: nowMs(), EndedAt: nowMs()},
		Entries: []game.SettleEntry{
			{UserID: low.ID, Delta: 0},
			{UserID: high.ID, Delta: 400, IsWinner: true},
		},
		Version: 2,
		State:   snapshot("room-A", game.TableWaiting, 1),
	}

	// A bystander holds the winner's wallet for a moment (any FOR UPDATE on
	// that row — another table's bet, say).
	hold, err := tagged.Pool.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := hold.Exec(f.ctx, `SELECT chips FROM users WHERE id = $1 FOR UPDATE`, high.ID); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(f.ctx, 20*time.Second)
	defer cancel()
	settleErr := make(chan error, 1)
	go func() {
		_, err := f.ledger.Settle(ctx, settle)
		settleErr <- err
	}()
	// Let the settle reach its first lock wait (INSERT hands → KEY SHARE on
	// high, blocked by the bystander).
	waitForLockWaiters(t, f, 1)

	bootErr := make(chan error, 1)
	go func() {
		_, err := f.ledger.CollectBoot(ctx, game.CollectBootRequest{
			RoomID: "room-B", HandID: "hand-B", BootAmount: 200,
			Entries: []game.BootEntry{{UserID: low.ID, Amount: 200}, {UserID: high.ID, Amount: 200}},
			Version: 1, State: snapshot("room-B", game.TableBetting, 1),
		})
		bootErr <- err
	}()
	// The boot takes low, then parks behind the settle on high.
	waitForLockWaiters(t, f, 2)

	// Release the bystander: PostgreSQL grants the queued locks in order and
	// the two ledger transactions are left facing each other.
	if err := hold.Rollback(f.ctx); err != nil {
		t.Fatal(err)
	}

	var failures []error
	for _, ch := range []chan error{settleErr, bootErr} {
		select {
		case err := <-ch:
			if err != nil {
				failures = append(failures, err)
			}
		case <-ctx.Done():
			t.Fatal("a ledger transaction never finished")
		}
	}
	for _, err := range failures {
		ge := db.Classify(err)
		if isDeadlock(ge.Cause) {
			t.Fatalf("REVIEW: ledger transactions deadlocked on shared wallets: %v", err)
		}
		t.Fatalf("unexpected ledger failure: %v", err)
	}
	f.reconcile()
	if got := f.chips(high.ID); got != welcome-200+400-200 {
		t.Fatalf("winner's wallet %d, want %d", got, welcome-200+400-200)
	}
}

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

// TestReviewConcurrentTablesSharingWalletsNeverDeadlock hammers the three
// ledger transactions from many "tables" at once over a small pool of
// wallets — far more overlap than the game allows (one seat per player), so
// any remaining lock-order cycle shows up as SQLSTATE 40P01. Every wallet
// must reconcile with its ledger afterwards.
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
			var version int64
			for h := 0; h < hands; h++ {
				// A pseudo-random 2–3 player subset, deterministic per worker/hand.
				n := 2 + (w+h)%2
				seen := map[int]bool{}
				var entries []game.BootEntry
				for k := 0; len(entries) < n; k++ {
					idx := (w*7 + h*3 + k*5) % players
					if seen[idx] {
						continue
					}
					seen[idx] = true
					entries = append(entries, game.BootEntry{UserID: pool[idx].ID, Amount: 200})
				}
				handID := roomID + "-hand-" + string(rune('a'+h%26)) + string(rune('a'+h/26))
				version++
				_, err := f.ledger.CollectBoot(ctx, game.CollectBootRequest{RoomID: roomID, HandID: handID, BootAmount: 200,
					Entries: entries, Version: version, State: snapshot(roomID, game.TableBetting, h+1)})
				if err != nil {
					if isDeadlock(db.Classify(err).Cause) {
						out.deadlocks++
					} else {
						out.refused++
					}
					version--
					continue
				}
				pot := int64(200 * len(entries))
				for i, e := range entries {
					version++
					_, err := f.ledger.Bet(ctx, game.BetRequest{UserID: e.UserID, Amount: 400, RoomID: roomID, HandID: handID,
						ActionID: handID + "-bet-" + string(rune('0'+i)), Reason: game.LedgerReasonBet, Version: version,
						State: snapshot(roomID, game.TableBetting, h+1)})
					if err != nil {
						if isDeadlock(db.Classify(err).Cause) {
							out.deadlocks++
						} else {
							out.refused++
						}
						version--
						continue
					}
					pot += 400
				}
				winner := entries[h%len(entries)].UserID
				var settleEntries []game.SettleEntry
				for _, e := range entries {
					se := game.SettleEntry{UserID: e.UserID, IsWinner: e.UserID == winner}
					if se.IsWinner {
						se.Delta = pot
					}
					settleEntries = append(settleEntries, se)
				}
				version++
				_, err = f.ledger.Settle(ctx, game.SettleRequest{
					Hand: game.HandRecord{ID: handID, RoomID: roomID, HandNo: h + 1, Pot: pot, WinnerID: ptr(winner),
						WinReason: game.WinLastStanding, BootAmount: 200, StartedAt: nowMs(), EndedAt: nowMs()},
					Entries: settleEntries, Version: version, State: snapshot(roomID, game.TableWaiting, h+1)})
				if err != nil {
					if isDeadlock(db.Classify(err).Cause) {
						out.deadlocks++
					} else {
						out.refused++
					}
					version--
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
	// Every closed pot equals the rows banked into it (pots.amount == boots + bets).
	mismatched := f.scalar(`SELECT COUNT(*) FROM pots p
	  WHERE p.amount <> (SELECT COALESCE(-SUM(delta), 0) FROM chip_ledger l WHERE l.hand_id = p.hand_id AND l.reason IN ('boot','bet','show'))`)
	if mismatched != 0 {
		t.Fatalf("%d pot(s) disagree with their banked rows", mismatched)
	}
	t.Logf("settled %d hands, %d refusals (insufficient chips), 0 deadlocks", total.settled, total.refused)
}
