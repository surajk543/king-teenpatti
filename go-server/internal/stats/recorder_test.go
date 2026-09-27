package stats

import (
	"context"
	"errors"
	"io"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/live"
	"github.com/surajk543/king-teenpatti/go-server/internal/livetest"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

func newTestRecorder(t *testing.T, store live.Store) *Recorder {
	t.Helper()
	r := NewRecorder(store, util.NewLogger("error", io.Discard))
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = r.Close(ctx)
	})
	return r
}

func syncOrFail(t *testing.T, r *Recorder) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := r.Sync(ctx); err != nil {
		t.Fatalf("sync: %v", err)
	}
}

// takeAll moves everything pending out of store, one batch.
func takeAll(t *testing.T, store live.Store) map[string]map[string]int64 {
	t.Helper()
	b, err := store.TakeStatsBatch(context.Background(), "inspect-"+util.UUID(), 1000)
	if err != nil {
		t.Fatal(err)
	}
	return b.Players
}

func TestTheRecorderWritesEveryCommittedHandToTheLiveStore(t *testing.T) {
	store := live.NewMemory()
	r := newTestRecorder(t, store)
	for i := 0; i < 100; i++ {
		r.Record([]game.HandStats{
			{UserID: "a", Bucket: game.StatsTeenPatti, Played: 1, Won: 1, Winnings: int64(100 + i)},
			{UserID: "b", Bucket: game.StatsTeenPatti, Played: 1, Lost: 1},
		})
	}
	r.Record(nil) // nothing to write
	syncOrFail(t, r)
	got := takeAll(t, store)
	if got["a"]["TEEN_PATTI:hands_won"] != 100 || got["a"]["TEEN_PATTI:biggest_pot"] != 199 || got["b"]["TEEN_PATTI:hands_lost"] != 100 {
		t.Fatalf("recorded %v", got)
	}
	if r.Recorded() != 100 || r.Dropped() != 0 {
		t.Fatalf("recorded %d, dropped %d", r.Recorded(), r.Dropped())
	}
}

// gatedStore holds every RecordStats until released, counting the calls.
type gatedStore struct {
	live.Store
	gate  chan struct{}
	calls chan int // the number of deltas of each call
}

func (g *gatedStore) RecordStats(ctx context.Context, deltas []live.StatsDelta) error {
	<-g.gate
	g.calls <- len(deltas)
	return g.Store.RecordStats(ctx, deltas)
}

// Hands that queue up while a write is under way go out together in one round
// trip, never on the caller's goroutine: Record returns at once however slow
// the store is.
func TestTheRecorderMergesQueuedHandsIntoOneRoundTrip(t *testing.T) {
	store := &gatedStore{Store: live.NewMemory(), gate: make(chan struct{}), calls: make(chan int, 100)}
	r := newTestRecorder(t, store)
	r.Record([]game.HandStats{{UserID: "a", Bucket: game.StatsPoker, Lost: 1}}) // the writer takes it and waits at the gate
	returned := make(chan struct{})
	go func() {
		for i := 0; i < 50; i++ {
			r.Record([]game.HandStats{{UserID: "a", Bucket: game.StatsPoker, Lost: 1}})
		}
		close(returned)
	}()
	select {
	case <-returned:
	case <-time.After(2 * time.Second):
		t.Fatal("Record blocked on a slow store")
	}
	close(store.gate)
	syncOrFail(t, r)
	close(store.calls)
	var sizes []int
	for n := range store.calls {
		sizes = append(sizes, n)
	}
	// However much the first write gathered before it reached the gate, every
	// hand queued behind it went in ONE more round trip.
	total := 0
	for _, n := range sizes {
		total += n
	}
	if len(sizes) > 2 || total != 51 {
		t.Fatalf("round trips of %v deltas, want 51 hands in at most two", sizes)
	}
	if got := takeAll(t, store.Store)["a"]["POKER:hands_lost"]; got != 51 {
		t.Fatalf("recorded %d of 51", got)
	}
}

// A write the store refuses loses that hand's counters — counted, and warned
// about — and the recorder goes on.
func TestAWriteTheStoreRefusesIsDroppedAndTheRecorderGoesOn(t *testing.T) {
	store := livetest.New()
	store.Fail(livetest.OpRecordStats, errors.New("redis down"))
	r := newTestRecorder(t, store)
	r.Record([]game.HandStats{{UserID: "a", Bucket: game.StatsPoker, Lost: 1}})
	syncOrFail(t, r)
	if r.Dropped() != 1 || r.Recorded() != 0 {
		t.Fatalf("dropped %d, recorded %d", r.Dropped(), r.Recorded())
	}
	store.Fail(livetest.OpRecordStats, nil)
	r.Record([]game.HandStats{{UserID: "a", Bucket: game.StatsPoker, Lost: 1}})
	syncOrFail(t, r)
	if got := store.PendingStats("a")["POKER:hands_lost"]; got != 1 || r.Recorded() != 1 {
		t.Fatalf("after the store came back: pending %d, recorded %d", got, r.Recorded())
	}
}

// Close drains what is queued; a hand recorded after it is dropped, and Sync
// says the recorder is closed.
func TestCloseDrainsTheQueueAndNothingIsTakenAfterIt(t *testing.T) {
	store := live.NewMemory()
	r := NewRecorder(store, util.NewLogger("error", io.Discard))
	for i := 0; i < 20; i++ {
		r.Record([]game.HandStats{{UserID: "a", Bucket: game.StatsPoker, Played: 1, Won: 1, Winnings: 10}})
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := r.Close(ctx); err != nil {
		t.Fatal(err)
	}
	if err := r.Close(ctx); err != nil {
		t.Fatalf("a second close: %v", err)
	}
	if got := takeAll(t, store)["a"]["POKER:hands_won"]; got != 20 {
		t.Fatalf("drained %d of 20", got)
	}
	r.Record([]game.HandStats{{UserID: "a", Bucket: game.StatsPoker, Won: 1}})
	if r.Dropped() != 1 {
		t.Fatalf("a hand after close: dropped %d", r.Dropped())
	}
	if err := r.Sync(ctx); !errors.Is(err, ErrRecorderClosed) {
		t.Fatalf("sync after close: %v", err)
	}
}

func TestForgetDropsAPlayersPendingCounters(t *testing.T) {
	store := live.NewMemory()
	r := newTestRecorder(t, store)
	r.Record([]game.HandStats{
		{UserID: "gone", Bucket: game.StatsPoker, Lost: 1},
		{UserID: "stays", Bucket: game.StatsPoker, Won: 1},
	})
	syncOrFail(t, r)
	r.Forget("gone")
	got := takeAll(t, store)
	if _, ok := got["gone"]; ok || got["stays"]["POKER:hands_won"] != 1 {
		t.Fatalf("after forgetting: %v", got)
	}
}
