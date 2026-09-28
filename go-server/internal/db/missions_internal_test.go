package db

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
)

// The completion of a ONE_TIME mission on its own, below the settle (owner,
// 28 Sep 2026: "a player wins a hand, and two backend workers receive/process
// the same authoritative event … GOOD: Worker A completes the mission and
// awards 100 XP; Worker B detects the mission is already completed and awards
// 0 XP"). The settle holds the player's wallet lock around it too; these take
// that away and show the database alone makes the completion — and its XP —
// happen once.

// openMissionsSchema opens a throwaway schema (dbtest.Open, which this
// package's own tests cannot import), dropped when the test ends; it skips
// when PostgreSQL is not there.
func openMissionsSchema(t *testing.T) *DB {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		url = os.Getenv("DATABASE_URL")
	}
	if url == "" {
		url = config.Defaults().DB.URL
	}
	var raw [3]byte
	if _, err := rand.Read(raw[:]); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	d, err := Open(ctx, Options{URL: url, Schema: "test_missionsint_" + hex.EncodeToString(raw[:]), PoolMax: 12})
	if err != nil {
		t.Skipf("postgres unreachable: %v", err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := d.DropSchema(ctx); err != nil {
			t.Errorf("drop schema: %v", err)
		}
		d.Close()
	})
	return d
}

// reachedFirstHand is a player whose First Hand has reached its target and
// is not completed — what advanceMissions leaves before awardXP — and the
// rules with that mission among them.
func reachedFirstHand(t *testing.T, d *DB) (string, xpRules, xpSourceRow) {
	t.Helper()
	ctx := context.Background()
	u, _, err := NewUsers(d, 1000, nil).UpsertFromProfile(ctx, Profile{Provider: ProviderGuest, ProviderUserID: "missions-int-" + time.Now().Format("150405.000000000"), DisplayName: "Worker"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.Pool.Exec(ctx, `INSERT INTO player_xp_missions (user_id, source_code, progress, created_at, updated_at)
	     VALUES ($1, 'FIRST_HAND', 1, 1, 1)`, u.ID); err != nil {
		t.Fatal(err)
	}
	rules, err := loadXPRules(ctx, d.Pool)
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range rules.missions {
		if m.code == "FIRST_HAND" {
			return u.ID, rules, m
		}
	}
	t.Fatal("First Hand is not among the rules' missions")
	return "", xpRules{}, xpSourceRow{}
}

// award runs awardXP for one mission in a transaction of its own and returns
// the XP it granted.
func award(t *testing.T, d *DB, rules xpRules, userID string, m xpSourceRow) (int, error) {
	var granted int
	err := d.WithTx(context.Background(), func(tx pgx.Tx) error {
		a, err := awardXP(context.Background(), tx, rules, userID, time.Now().UnixMilli(), []xpSourceRow{m})
		granted = a.granted
		return err
	})
	return granted, err
}

// TestWorkerBFindsTheMissionWorkerACompleted is the owner's example, in that
// order: worker A completes the mission and has not yet committed; worker B
// asks for the same completion meanwhile and waits on the row; A commits;
// B finds it completed and grants 0. The XP is A's 5, once.
func TestWorkerBFindsTheMissionWorkerACompleted(t *testing.T) {
	d := openMissionsSchema(t)
	ctx := context.Background()
	userID, rules, firstHand := reachedFirstHand(t, d)

	txA, err := d.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	a, err := awardXP(ctx, txA, rules, userID, time.Now().UnixMilli(), []xpSourceRow{firstHand})
	if err != nil || a.granted != 5 || len(a.completed) != 1 {
		t.Fatalf("worker A: %+v %v, want First Hand's 5", a, err)
	}
	b := make(chan int, 1)
	go func() {
		granted, err := award(t, d, rules, userID, firstHand)
		if err != nil {
			t.Errorf("worker B: %v", err)
		}
		b <- granted
	}()
	select {
	case granted := <-b:
		t.Fatalf("worker B went past worker A's open transaction and granted %d", granted)
	case <-time.After(300 * time.Millisecond):
	}
	if err := txA.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if granted := <-b; granted != 0 {
		t.Fatalf("worker B granted %d, want 0: the mission was completed", granted)
	}
	var xp int64
	var completions int
	if err := d.Pool.QueryRow(ctx, `SELECT (SELECT xp FROM player_xp WHERE user_id = $1),
	       (SELECT count(*) FROM player_xp_missions WHERE user_id = $1 AND completed_at > 0 AND xp_awarded = 5)`, userID).Scan(&xp, &completions); err != nil {
		t.Fatal(err)
	}
	if xp != 5 || completions != 1 {
		t.Fatalf("XP %d and %d completions, want 5 once", xp, completions)
	}
}

// TestACompletionIsWrittenOnceWhoeverAsks: twelve transactions ask to
// complete the same reached mission at the same moment; exactly one grants
// its XP, and a worker whose transaction rolls back after completing leaves
// it for the next — the completion is part of the transaction, never a
// side effect of it.
func TestACompletionIsWrittenOnceWhoeverAsks(t *testing.T) {
	d := openMissionsSchema(t)
	ctx := context.Background()
	userID, rules, firstHand := reachedFirstHand(t, d)

	// A worker that completes and then fails: nothing of it stays.
	rolledBack := d.WithTx(ctx, func(tx pgx.Tx) error {
		if a, err := awardXP(ctx, tx, rules, userID, time.Now().UnixMilli(), []xpSourceRow{firstHand}); err != nil || a.granted != 5 {
			t.Fatalf("the failing worker: %+v %v", a, err)
		}
		return context.Canceled
	})
	if rolledBack == nil {
		t.Fatal("the failing worker's transaction committed")
	}

	const workers = 12
	var wg sync.WaitGroup
	start := make(chan struct{})
	grants := make(chan int, workers)
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			granted, err := award(t, d, rules, userID, firstHand)
			if err != nil {
				t.Errorf("a worker: %v", err)
			}
			grants <- granted
		}()
	}
	close(start)
	wg.Wait()
	close(grants)
	total, winners := 0, 0
	for g := range grants {
		total += g
		if g > 0 {
			winners++
		}
	}
	if total != 5 || winners != 1 {
		t.Fatalf("%d workers granted %d XP between them, want one worker and 5", winners, total)
	}
	var xp int64
	if err := d.Pool.QueryRow(ctx, `SELECT xp FROM player_xp WHERE user_id = $1`, userID).Scan(&xp); err != nil || xp != 5 {
		t.Fatalf("the lifetime XP %d %v, want 5", xp, err)
	}
}
