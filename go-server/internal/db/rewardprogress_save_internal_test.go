package db

import (
	"context"
	"testing"
	"time"
)

// The progress row's one rule beyond the standing it records (owner, 1 Oct
// 2026: user_reward_progress): a writer never takes it back in time. A look
// works the standing out from claims it read, and a claim can commit between
// that read and the look's write; the look's write — whose latest claim is
// older than the row's — must then leave the row as the claim left it.
func TestAStaleLookNeverWindsTheProgressRowBack(t *testing.T) {
	d := openMissionsSchema(t)
	ctx := context.Background()
	u, _, err := NewUsers(d, 1000, nil).UpsertFromProfile(ctx, Profile{Provider: ProviderGuest,
		ProviderUserID: "progress-int-" + time.Now().Format("150405.000000000"), DisplayName: "Stale"})
	if err != nil {
		t.Fatal(err)
	}
	var programID int64
	if err := d.Pool.QueryRow(ctx, `SELECT id FROM reward_programs WHERE code = 'WEEKLY_LOGIN'`).Scan(&programID); err != nil {
		t.Fatal(err)
	}
	const period = int64(1791158400000) // Monday 5 Oct 2026, UTC
	row := func() (int, string, int64) {
		t.Helper()
		var day int
		var status string
		var last int64
		if err := d.Pool.QueryRow(ctx, `SELECT current_day, status, last_activity_at FROM user_reward_progress
		                                WHERE user_id = $1 AND program_id = $2 AND period_start_at = $3`, u.ID, programID, period).
			Scan(&day, &status, &last); err != nil {
			t.Fatal(err)
		}
		return day, status, last
	}

	// A claim of Day 2 at 2,000 — then a look that read before it, still
	// seeing Day 1's claim at 1,000.
	claimed := rewardProgress{Status: RewardStatusActive, CurrentDay: 2, ClaimedToday: true, LastActivity: 2000}
	if err := saveProgress(ctx, d.Pool, u.ID, programID, period, claimed, 2000); err != nil {
		t.Fatal(err)
	}
	stale := rewardProgress{Status: RewardStatusActive, CurrentDay: 2, CanClaim: true, LastActivity: 1000}
	if err := saveProgress(ctx, d.Pool, u.ID, programID, period, stale, 2500); err != nil {
		t.Fatal(err)
	}
	if day, status, last := row(); day != 3 || status != RewardStatusActive || last != 2000 {
		t.Fatalf("after the stale look: day %d %s last %d, want the claim's 3 ACTIVE 2000", day, status, last)
	}
	// A look as fresh as the row may move it on — a missed day breaking a
	// BREAK cycle is exactly that.
	broken := rewardProgress{Status: RewardStatusBroken, CurrentDay: 3, Missed: 3, LastActivity: 2000}
	if err := saveProgress(ctx, d.Pool, u.ID, programID, period, broken, 9000); err != nil {
		t.Fatal(err)
	}
	if day, status, last := row(); day != 3 || status != RewardStatusBroken || last != 2000 {
		t.Fatalf("after the fresh look: day %d %s last %d", day, status, last)
	}
}
