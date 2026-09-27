package live

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"sort"
	"sync"
	"testing"
)

// runStatsConformance is the players' statistics half of the Store contract
// (Player stats v2), run against every implementation: the sums, the max, the
// dirty set, the atomic move of a pending hash into a batch, a delta recorded
// while a batch is out, and the open batches a flusher retries.
func runStatsConformance(t *testing.T, newHarness func(t *testing.T) *harness) {
	ctx := context.Background()

	t.Run("StatsRecordSumsKeepsTheLargerMaxAndMarksThePlayersDirty", func(t *testing.T) {
		h := newHarness(t)
		must(t, h.store.RecordStats(ctx, []StatsDelta{
			{UserID: "u1", Add: map[string]int64{"TEEN_PATTI:hands_played": 1, "TEEN_PATTI:trail": 1}, Max: map[string]int64{"TEEN_PATTI:biggest_pot": 900}},
			{UserID: "u2", Add: map[string]int64{"POKER:hands_lost": 1}},
		}))
		// The same player twice in one call, and again in another.
		must(t, h.store.RecordStats(ctx, []StatsDelta{
			{UserID: "u1", Add: map[string]int64{"TEEN_PATTI:hands_played": 1}, Max: map[string]int64{"TEEN_PATTI:biggest_pot": 400}},
			{UserID: "u1", Add: map[string]int64{"TEEN_PATTI:hands_played": 1, "TEEN_PATTI:total_winnings": 1500}, Max: map[string]int64{"TEEN_PATTI:biggest_pot": 1500}},
		}))
		must(t, h.store.RecordStats(ctx, []StatsDelta{
			{UserID: "u1", Max: map[string]int64{"TEEN_PATTI:biggest_pot": 1200}},
		}))
		batch, err := h.store.TakeStatsBatch(ctx, "b1", 10)
		must(t, err)
		want := map[string]map[string]int64{
			"u1": {"TEEN_PATTI:hands_played": 3, "TEEN_PATTI:trail": 1, "TEEN_PATTI:total_winnings": 1500, "TEEN_PATTI:biggest_pot": 1500},
			"u2": {"POKER:hands_lost": 1},
		}
		if batch.ID != "b1" || !reflect.DeepEqual(batch.Players, want) {
			t.Fatalf("batch = %+v, want %v", batch, want)
		}
		// Taken: nobody is dirty any more.
		again, err := h.store.TakeStatsBatch(ctx, "b2", 10)
		must(t, err)
		if len(again.Players) != 0 {
			t.Fatalf("a second take found %v", again.Players)
		}
	})

	t.Run("StatsAnEmptyDeltaMarksNobody", func(t *testing.T) {
		h := newHarness(t)
		must(t, h.store.RecordStats(ctx, nil))
		must(t, h.store.RecordStats(ctx, []StatsDelta{{UserID: "u1"}, {UserID: "", Add: map[string]int64{"x": 1}}}))
		batch, err := h.store.TakeStatsBatch(ctx, "b1", 10)
		must(t, err)
		if len(batch.Players) != 0 {
			t.Fatalf("an empty delta marked %v", batch.Players)
		}
		open, err := h.store.StatsBatches(ctx)
		must(t, err)
		if open == nil || len(open) != 0 {
			t.Fatalf("an empty take registered a batch: %+v", open)
		}
	})

	t.Run("StatsATakeIsBoundedAndLeavesTheRestDirty", func(t *testing.T) {
		h := newHarness(t)
		var deltas []StatsDelta
		for i := 0; i < 5; i++ {
			deltas = append(deltas, StatsDelta{UserID: fmt.Sprintf("u%d", i), Add: map[string]int64{"POKER:hands_played": int64(i + 1)}})
		}
		must(t, h.store.RecordStats(ctx, deltas))
		seen := map[string]int64{}
		sizes := []int{}
		for i := 0; i < 4; i++ {
			batch, err := h.store.TakeStatsBatch(ctx, fmt.Sprintf("b%d", i), 2)
			must(t, err)
			sizes = append(sizes, len(batch.Players))
			for id, fields := range batch.Players {
				if _, twice := seen[id]; twice {
					t.Fatalf("%s taken twice", id)
				}
				seen[id] = fields["POKER:hands_played"]
			}
		}
		if !reflect.DeepEqual(sizes, []int{2, 2, 1, 0}) {
			t.Fatalf("batch sizes %v, want 2 2 1 0", sizes)
		}
		for i := 0; i < 5; i++ {
			if seen[fmt.Sprintf("u%d", i)] != int64(i+1) {
				t.Fatalf("u%d taken with %d", i, seen[fmt.Sprintf("u%d", i)])
			}
		}
	})

	t.Run("StatsADeltaRecordedWhileABatchIsOutLandsInAFreshPendingHash", func(t *testing.T) {
		h := newHarness(t)
		must(t, h.store.RecordStats(ctx, []StatsDelta{{UserID: "u1", Add: map[string]int64{"VARIATION:v:MUFLIS:played": 1}, Max: map[string]int64{"VARIATION:biggest_pot": 800}}}))
		out, err := h.store.TakeStatsBatch(ctx, "b1", 10)
		must(t, err)
		// The flush of b1 is under way: another hand ends for u1.
		must(t, h.store.RecordStats(ctx, []StatsDelta{{UserID: "u1", Add: map[string]int64{"VARIATION:v:MUFLIS:played": 1}, Max: map[string]int64{"VARIATION:biggest_pot": 300}}}))
		open, err := h.store.StatsBatches(ctx)
		must(t, err)
		if len(open) != 1 || open[0].ID != "b1" || !reflect.DeepEqual(open[0].Players, out.Players) {
			t.Fatalf("the batch out changed under a new delta: %+v, took %+v", open, out)
		}
		must(t, h.store.FinishStatsBatch(ctx, "b1"))
		next, err := h.store.TakeStatsBatch(ctx, "b2", 10)
		must(t, err)
		// The new delta is its own: not lost, and the old one not in it again —
		// its max included, which starts over with the fresh hash.
		want := map[string]map[string]int64{"u1": {"VARIATION:v:MUFLIS:played": 1, "VARIATION:biggest_pot": 300}}
		if !reflect.DeepEqual(next.Players, want) {
			t.Fatalf("the next batch = %v, want %v", next.Players, want)
		}
	})

	t.Run("StatsOpenBatchesAreListedOldestFirstUntilFinished", func(t *testing.T) {
		h := newHarness(t)
		must(t, h.store.RecordStats(ctx, []StatsDelta{{UserID: "u1", Add: map[string]int64{"TEEN_PATTI:hands_won": 1}}}))
		_, err := h.store.TakeStatsBatch(ctx, "first", 10)
		must(t, err)
		h.advance(h.ttl / 1000) // a later millisecond
		must(t, h.store.RecordStats(ctx, []StatsDelta{
			{UserID: "u1", Add: map[string]int64{"TEEN_PATTI:hands_won": 2}},
			{UserID: "u2", Add: map[string]int64{"TEEN_PATTI:hands_lost": 1}},
		}))
		_, err = h.store.TakeStatsBatch(ctx, "second", 10)
		must(t, err)
		open, err := h.store.StatsBatches(ctx)
		must(t, err)
		if len(open) != 2 || open[0].ID != "first" || open[1].ID != "second" || open[0].CreatedAt > open[1].CreatedAt {
			t.Fatalf("open batches %+v, want first then second", open)
		}
		if got := open[0].Players["u1"]["TEEN_PATTI:hands_won"]; got != 1 {
			t.Fatalf("first holds u1 won %d", got)
		}
		if got := open[1].Players; got["u1"]["TEEN_PATTI:hands_won"] != 2 || got["u2"]["TEEN_PATTI:hands_lost"] != 1 {
			t.Fatalf("second holds %v", got)
		}
		must(t, h.store.FinishStatsBatch(ctx, "first"))
		must(t, h.store.FinishStatsBatch(ctx, "first")) // idempotent
		open, err = h.store.StatsBatches(ctx)
		must(t, err)
		if len(open) != 1 || open[0].ID != "second" {
			t.Fatalf("after finishing first: %+v", open)
		}
		must(t, h.store.FinishStatsBatch(ctx, "second"))
		open, err = h.store.StatsBatches(ctx)
		must(t, err)
		if len(open) != 0 {
			t.Fatalf("after finishing both: %+v", open)
		}
	})

	t.Run("StatsATakeRefusesAnOpenBatchID", func(t *testing.T) {
		h := newHarness(t)
		must(t, h.store.RecordStats(ctx, []StatsDelta{{UserID: "u1", Add: map[string]int64{"POKER:hands_won": 1}}}))
		_, err := h.store.TakeStatsBatch(ctx, "b1", 10)
		must(t, err)
		must(t, h.store.RecordStats(ctx, []StatsDelta{{UserID: "u1", Add: map[string]int64{"POKER:hands_won": 5}}}))
		if _, err := h.store.TakeStatsBatch(ctx, "b1", 10); !errors.Is(err, ErrStatsBatchExists) {
			t.Fatalf("a take under an open batch's id: %v, want ErrStatsBatchExists", err)
		}
		open, err := h.store.StatsBatches(ctx)
		must(t, err)
		if len(open) != 1 || open[0].Players["u1"]["POKER:hands_won"] != 1 {
			t.Fatalf("the refused take touched the open batch: %+v", open)
		}
		// The new delta is still waiting.
		next, err := h.store.TakeStatsBatch(ctx, "b2", 10)
		must(t, err)
		if next.Players["u1"]["POKER:hands_won"] != 5 {
			t.Fatalf("the waiting delta: %v", next.Players)
		}
	})

	t.Run("StatsDropForgetsPendingCountersButNotABatchTaken", func(t *testing.T) {
		h := newHarness(t)
		must(t, h.store.RecordStats(ctx, []StatsDelta{{UserID: "u1", Add: map[string]int64{"POKER:hands_won": 1}}}))
		_, err := h.store.TakeStatsBatch(ctx, "b1", 10)
		must(t, err)
		must(t, h.store.RecordStats(ctx, []StatsDelta{
			{UserID: "u1", Add: map[string]int64{"POKER:hands_won": 7}},
			{UserID: "u2", Add: map[string]int64{"POKER:hands_won": 1}},
		}))
		must(t, h.store.DropStats(ctx, "u1"))
		must(t, h.store.DropStats(ctx, "nobody"))
		next, err := h.store.TakeStatsBatch(ctx, "b2", 10)
		must(t, err)
		if _, ok := next.Players["u1"]; ok || next.Players["u2"]["POKER:hands_won"] != 1 {
			t.Fatalf("after dropping u1: %v", next.Players)
		}
		open, err := h.store.StatsBatches(ctx)
		must(t, err)
		if len(open) != 2 || open[0].Players["u1"]["POKER:hands_won"] != 1 {
			t.Fatalf("the batch taken before the drop: %+v", open)
		}
	})

	t.Run("StatsConcurrentRecordsAndTakesLoseAndDuplicateNothing", func(t *testing.T) {
		h := newHarness(t)
		const writers, perWriter = 8, 25
		var wg sync.WaitGroup
		errs := make(chan error, writers+1)
		for w := 0; w < writers; w++ {
			wg.Add(1)
			go func(w int) {
				defer wg.Done()
				for i := 0; i < perWriter; i++ {
					if err := h.store.RecordStats(ctx, []StatsDelta{{UserID: fmt.Sprintf("u%d", i%5), Add: map[string]int64{"POKER:hands_played": 1}}}); err != nil {
						errs <- err
						return
					}
				}
			}(w)
		}
		var taken []StatsBatch
		var takeMu sync.Mutex
		stop := make(chan struct{})
		var tw sync.WaitGroup
		tw.Add(1)
		go func() {
			defer tw.Done()
			for n := 0; ; n++ {
				select {
				case <-stop:
					return
				default:
				}
				b, err := h.store.TakeStatsBatch(ctx, fmt.Sprintf("race-%d", n), 3)
				if err != nil {
					errs <- err
					return
				}
				takeMu.Lock()
				taken = append(taken, b)
				takeMu.Unlock()
			}
		}()
		wg.Wait()
		close(stop)
		tw.Wait()
		close(errs)
		for err := range errs {
			t.Fatalf("unexpected error: %v", err)
		}
		// Whatever is still pending is taken last.
		for n := 0; ; n++ {
			b, err := h.store.TakeStatsBatch(ctx, fmt.Sprintf("tail-%d", n), 100)
			must(t, err)
			if len(b.Players) == 0 {
				break
			}
			taken = append(taken, b)
		}
		var total int64
		for _, b := range taken {
			for _, fields := range b.Players {
				total += fields["POKER:hands_played"]
			}
		}
		if total != writers*perWriter {
			t.Fatalf("%d hands taken, %d recorded", total, writers*perWriter)
		}
		open, err := h.store.StatsBatches(ctx)
		must(t, err)
		ids := make([]string, 0, len(open))
		for _, b := range open {
			ids = append(ids, b.ID)
		}
		sort.Strings(ids)
		var want []string
		for _, b := range taken {
			if len(b.Players) > 0 {
				want = append(want, b.ID)
			}
		}
		sort.Strings(want)
		if !reflect.DeepEqual(ids, want) {
			t.Fatalf("open batches %v, want every non-empty take %v", ids, want)
		}
	})
}
