package livetest

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/live"
)

// The fake keeps the players' statistics with the contract's semantics
// (live.StatsBook, which the conformance suite holds to Redis's), counts the
// calls and fails them on demand — what the app suites rely on to drive the
// stats flusher end to end.
func TestTheFakeKeepsStatisticsAsTheContractSays(t *testing.T) {
	ctx := context.Background()
	f := NewWithClock(func() time.Time { return time.UnixMilli(1_790_000_000_000) })
	if err := f.RecordStats(ctx, []live.StatsDelta{
		{UserID: "u1", Add: map[string]int64{"TEEN_PATTI:hands_won": 1}, Max: map[string]int64{"TEEN_PATTI:biggest_pot": 500}},
		{UserID: "u1", Add: map[string]int64{"TEEN_PATTI:hands_won": 1}, Max: map[string]int64{"TEEN_PATTI:biggest_pot": 200}},
	}); err != nil {
		t.Fatal(err)
	}
	if got := f.PendingStats("u1"); got["TEEN_PATTI:hands_won"] != 2 || got["TEEN_PATTI:biggest_pot"] != 500 {
		t.Fatalf("pending = %v", got)
	}
	if got := f.DirtyStats(); len(got) != 1 || got[0] != "u1" {
		t.Fatalf("dirty = %v", got)
	}
	batch, err := f.TakeStatsBatch(ctx, "b1", 10)
	if err != nil || len(batch.Players) != 1 || batch.CreatedAt != 1_790_000_000_000 {
		t.Fatalf("take = %+v %v", batch, err)
	}
	if f.PendingStats("u1") != nil || len(f.DirtyStats()) != 0 || len(f.OpenStatsBatches()) != 1 {
		t.Fatal("the take did not move the counters out")
	}
	down := errors.New("redis down")
	f.Fail(OpFinishStatsBatch, down)
	if err := f.FinishStatsBatch(ctx, "b1"); !errors.Is(err, down) {
		t.Fatalf("an injected failure: %v", err)
	}
	f.Fail(OpFinishStatsBatch, nil)
	if err := f.FinishStatsBatch(ctx, "b1"); err != nil || len(f.OpenStatsBatches()) != 0 {
		t.Fatalf("finish: %v, open %v", err, f.OpenStatsBatches())
	}
	if err := f.DropStats(ctx, "u1"); err != nil {
		t.Fatal(err)
	}
	for op, want := range map[string]int{OpRecordStats: 1, OpTakeStatsBatch: 1, OpFinishStatsBatch: 2, OpDropStats: 1} {
		if got := f.Calls(op); got != want {
			t.Errorf("%s called %d times, want %d", op, got, want)
		}
	}
}
