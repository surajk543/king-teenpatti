package stats

import (
	"context"
	"errors"
	"fmt"
	"io"
	"sync"
	"testing"
	"time"

	dto "github.com/prometheus/client_model/go"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/live"
	"github.com/surajk543/king-teenpatti/go-server/internal/metrics"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// flushRig is a flusher over a throwaway schema and the in-process live
// store, with a FlushStore in between that can lose an acknowledgement or
// fail a transaction on demand.
type flushRig struct {
	t       *testing.T
	ctx     context.Context
	d       *db.DB
	users   *db.Users
	live    live.Store
	store   *faultyStore
	flusher *Flusher
	metrics *metrics.Metrics
}

// faultyStore is db.StatsStore with faults: loseAck commits the batch and
// then answers an error (the acknowledgement lost on the wire), failNext
// fails it without committing. It records every batch id it was asked for.
type faultyStore struct {
	inner *db.StatsStore
	mu    sync.Mutex
	ids   []string
	// loseAck and failNext are how many of the next flushes misbehave.
	loseAck, failNext int
	prunes            int
}

func (s *faultyStore) Flush(ctx context.Context, batchID string, deltas []db.StatsDelta) (bool, error) {
	s.mu.Lock()
	s.ids = append(s.ids, batchID)
	fail := s.failNext > 0
	if fail {
		s.failNext--
	}
	lose := !fail && s.loseAck > 0
	if lose {
		s.loseAck--
	}
	s.mu.Unlock()
	if fail {
		return false, errors.New("the transaction failed")
	}
	applied, err := s.inner.Flush(ctx, batchID, deltas)
	if lose && err == nil {
		return false, errors.New("connection reset after COMMIT")
	}
	return applied, err
}

func (s *faultyStore) PruneFlushes(ctx context.Context, olderThanMs int64) (int64, error) {
	s.mu.Lock()
	s.prunes++
	s.mu.Unlock()
	return s.inner.PruneFlushes(ctx, olderThanMs)
}

func (s *faultyStore) batchIDs() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.ids...)
}

func newFlushRig(t *testing.T, batch int, interval time.Duration) *flushRig {
	t.Helper()
	d := dbtest.Open(t, "stats")
	r := &flushRig{t: t, ctx: context.Background(), d: d, users: db.NewUsers(d, 300000, nil), live: live.NewMemory(),
		metrics: metrics.New(metrics.Options{})}
	r.store = &faultyStore{inner: db.NewStatsStore(d, nil)}
	r.flusher = NewFlusher(FlusherOptions{Live: r.live, DB: r.store, Interval: interval, Batch: batch,
		Logger: util.NewLogger("error", io.Discard), Metrics: r.metrics})
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = r.flusher.Stop(ctx)
	})
	return r
}

func (r *flushRig) user(name string) string {
	r.t.Helper()
	u, _, err := r.users.UpsertFromProfile(r.ctx, db.Profile{Provider: db.ProviderGuest, ProviderUserID: name + "-" + util.UUID(), DisplayName: name})
	if err != nil {
		r.t.Fatal(err)
	}
	return u.ID
}

// record puts hands in the live store as the recorder would.
func (r *flushRig) record(hands ...game.HandStats) {
	r.t.Helper()
	if err := r.live.RecordStats(r.ctx, Deltas(hands)); err != nil {
		r.t.Fatal(err)
	}
}

func (r *flushRig) account(userID string) *db.User {
	r.t.Helper()
	u, err := r.users.FindByID(r.ctx, userID)
	if err != nil || u == nil {
		r.t.Fatalf("find %s: %v", userID, err)
	}
	return u
}

func (r *flushRig) receipts() int64 {
	r.t.Helper()
	var n int64
	if err := r.d.Pool.QueryRow(r.ctx, `SELECT count(*) FROM stats_flushes`).Scan(&n); err != nil {
		r.t.Fatal(err)
	}
	return n
}

func (r *flushRig) openBatches() []live.StatsBatch {
	r.t.Helper()
	open, err := r.live.StatsBatches(r.ctx)
	if err != nil {
		r.t.Fatal(err)
	}
	return open
}

func (r *flushRig) flushes(result string) float64 {
	var m dto.Metric
	if err := r.metrics.StatsFlushes.WithLabelValues(result).Write(&m); err != nil {
		r.t.Fatal(err)
	}
	return m.GetCounter().GetValue()
}

func won(hands int64, bucket game.StatsBucket, id string) game.HandStats {
	return game.HandStats{UserID: id, Bucket: bucket, Played: hands, Won: hands, Winnings: 100 * hands}
}

func TestAPassMovesEveryWaitingPlayerIntoPostgreSQLInOneTransaction(t *testing.T) {
	r := newFlushRig(t, 500, 0)
	a, b := r.user("A"), r.user("B")
	r.record(won(1, game.StatsTeenPatti, a), won(1, game.StatsTeenPatti, a),
		game.HandStats{UserID: b, Bucket: game.StatsVariation, Lost: 1, HasHeld: true, Held: game.Trail, Variation: game.VariationJoker})
	report, err := r.flusher.Pass(r.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if report.Batches != 1 || report.Players != 2 || report.Retried != 0 || report.Duplicates != 0 {
		t.Fatalf("report %+v", report)
	}
	if got := r.account(a); got.HandsWon != 2 || got.Stats.TeenPatti.HandsWon != 2 || got.BiggestPot != 100 {
		t.Fatalf("A reads %+v", got.Stats.TeenPatti)
	}
	if got := r.account(b).Stats.Variation; got.HandsLost != 1 || got.Hands.Trail != 1 || len(got.Variations) != 1 {
		t.Fatalf("B reads %+v", got)
	}
	if len(r.openBatches()) != 0 || r.receipts() != 1 {
		t.Fatalf("after the commit: %d open batches, %d receipts", len(r.openBatches()), r.receipts())
	}
	if r.flushes(metrics.StatsFlushOK) != 1 {
		t.Fatal("the commit was not counted")
	}
	// Nothing waiting: a pass does nothing.
	if report, err := r.flusher.Pass(r.ctx); err != nil || report.Batches != 0 {
		t.Fatalf("an idle pass: %+v %v", report, err)
	}
}

func TestAPassTakesBatchAfterBatchUpToTheBatchSize(t *testing.T) {
	r := newFlushRig(t, 3, 0)
	var ids []string
	for i := 0; i < 7; i++ {
		id := r.user(fmt.Sprintf("P%d", i))
		ids = append(ids, id)
		r.record(game.HandStats{UserID: id, Bucket: game.StatsPoker, Played: 1, Lost: 1})
	}
	report, err := r.flusher.Pass(r.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if report.Batches != 3 || report.Players != 7 || r.receipts() != 3 {
		t.Fatalf("report %+v, %d receipts: want 3 batches (3, 3, 1) of one transaction each", report, r.receipts())
	}
	for _, id := range ids {
		if got := r.account(id).Stats.Poker.HandsLost; got != 1 {
			t.Fatalf("%s lost %d", id, got)
		}
	}
}

// Exactly once across a lost acknowledgement: the batch committed, the
// flusher was told it failed, the batch stays in the live store, and the next
// pass finds its receipt, adds nothing and forgets it.
func TestALostAcknowledgementIsCountedOnce(t *testing.T) {
	r := newFlushRig(t, 500, 0)
	a := r.user("A")
	r.record(won(1, game.StatsPoker, a))
	r.store.loseAck = 1
	if _, err := r.flusher.Pass(r.ctx); err == nil {
		t.Fatal("the lost acknowledgement was not reported")
	}
	if open := r.openBatches(); len(open) != 1 {
		t.Fatalf("%d batches open after an unacknowledged commit, want it kept", len(open))
	}
	report, err := r.flusher.Pass(r.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if report.Retried != 1 || report.Duplicates != 1 || report.Batches != 0 {
		t.Fatalf("the retry: %+v", report)
	}
	ids := r.store.batchIDs()
	if len(ids) != 2 || ids[0] != ids[1] {
		t.Fatalf("batch ids %v: the retry must use the same id", ids)
	}
	if got := r.account(a).Stats.Poker; got.HandsWon != 1 || got.TotalWinnings != 100 {
		t.Fatalf("A reads %+v after a lost acknowledgement, want the hand once", got)
	}
	if len(r.openBatches()) != 0 {
		t.Fatal("the committed batch was not forgotten")
	}
	if r.flushes(metrics.StatsFlushError) != 1 || r.flushes(metrics.StatsFlushDuplicate) != 1 {
		t.Fatalf("metrics: error %v, duplicate %v", r.flushes(metrics.StatsFlushError), r.flushes(metrics.StatsFlushDuplicate))
	}
}

// Exactly once across a failed transaction: nothing was added, the batch is
// retried with the SAME id before anything new, and a delta recorded while it
// was out is flushed after it — not lost, not merged into it.
func TestAFailedTransactionIsRetriedWithTheSameIDBeforeAnythingNew(t *testing.T) {
	r := newFlushRig(t, 500, 0)
	a := r.user("A")
	r.record(won(1, game.StatsTeenPatti, a))
	r.store.failNext = 1
	if _, err := r.flusher.Pass(r.ctx); err == nil {
		t.Fatal("the failed transaction was not reported")
	}
	if got := r.account(a).HandsWon; got != 0 {
		t.Fatalf("a failed flush added %d", got)
	}
	// Another hand ends for A while the batch is out.
	r.record(won(1, game.StatsTeenPatti, a))
	report, err := r.flusher.Pass(r.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if report.Retried != 1 || report.Batches != 2 {
		t.Fatalf("report %+v: the retry, then the new batch", report)
	}
	ids := r.store.batchIDs()
	if len(ids) != 3 || ids[0] != ids[1] || ids[2] == ids[0] {
		t.Fatalf("batch ids %v: failed, retried under the same id, then a new one", ids)
	}
	if got := r.account(a); got.HandsWon != 2 || got.TotalWinnings != 200 {
		t.Fatalf("A reads won %d, winnings %d: want both hands, each once", got.HandsWon, got.TotalWinnings)
	}
}

// A batch a previous process took and never finished is flushed at boot,
// under its own id, before anything new is taken.
func TestABatchLeftByAPreviousProcessIsFlushedFirstAtBoot(t *testing.T) {
	r := newFlushRig(t, 500, time.Hour)
	a := r.user("A")
	r.record(won(1, game.StatsPoker, a))
	left, err := r.live.TakeStatsBatch(r.ctx, "left-by-the-last-process", 500)
	if err != nil || len(left.Players) != 1 {
		t.Fatalf("take: %+v %v", left, err)
	}
	r.record(won(1, game.StatsPoker, a))
	r.flusher.Start()
	deadline := time.Now().Add(5 * time.Second)
	for r.account(a).HandsWon != 2 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if got := r.account(a).HandsWon; got != 2 {
		t.Fatalf("A won %d after the boot pass, want 2", got)
	}
	if ids := r.store.batchIDs(); len(ids) != 2 || ids[0] != "left-by-the-last-process" {
		t.Fatalf("batch ids %v: the old batch first, under its own id", ids)
	}
}

// Shutdown's last pass puts what is waiting into PostgreSQL; a flusher that
// never started (STATS_FLUSH_MS=0) does nothing at either end.
func TestStopRunsOneLastFlushAndAnIntervalOfZeroNeverStarts(t *testing.T) {
	r := newFlushRig(t, 500, time.Hour)
	a := r.user("A")
	r.flusher.Start()
	time.Sleep(50 * time.Millisecond) // the boot pass, with nothing waiting
	r.record(won(1, game.StatsVariation, a))
	ctx, cancel := context.WithTimeout(r.ctx, 5*time.Second)
	defer cancel()
	if err := r.flusher.Stop(ctx); err != nil {
		t.Fatal(err)
	}
	if got := r.account(a).Stats.Variation.HandsWon; got != 1 {
		t.Fatalf("the last pass flushed %d", got)
	}
	if err := r.flusher.Stop(ctx); err != nil {
		t.Fatalf("a second stop: %v", err)
	}

	off := NewFlusher(FlusherOptions{Live: r.live, DB: r.store, Interval: 0, Batch: 500})
	off.Start()
	r.record(won(1, game.StatsVariation, a))
	if err := off.Stop(ctx); err != nil {
		t.Fatal(err)
	}
	if got := r.account(a).Stats.Variation.HandsWon; got != 1 {
		t.Fatalf("a flusher that is off flushed: %d", got)
	}
	if _, err := off.Pass(ctx); err != nil || r.account(a).Stats.Variation.HandsWon != 2 {
		t.Fatalf("an explicit pass still works: %v", err)
	}
}

// The receipts are pruned after FlushKeep, at most once an hour.
func TestTheFlusherPrunesReceiptsOlderThanAWeek(t *testing.T) {
	r := newFlushRig(t, 500, 0)
	old := time.Now().Add(-FlushKeep - time.Hour).UnixMilli()
	if _, err := r.d.Pool.Exec(r.ctx, `INSERT INTO stats_flushes (batch_id, players, flushed_at) VALUES ('ancient', 1, $1), ('recent', 1, $2)`,
		old, time.Now().UnixMilli()); err != nil {
		t.Fatal(err)
	}
	if _, err := r.flusher.Pass(r.ctx); err != nil {
		t.Fatal(err)
	}
	if n := r.receipts(); n != 1 {
		t.Fatalf("%d receipts after the prune, want the recent one", n)
	}
	if _, err := r.flusher.Pass(r.ctx); err != nil {
		t.Fatal(err)
	}
	if r.store.prunes != 1 {
		t.Fatalf("%d prunes in two passes a moment apart, want one an hour", r.store.prunes)
	}
}

// A player deleted while their counters wait is skipped by the flush.
func TestAFlushSkipsAnAccountDeletedMeanwhile(t *testing.T) {
	r := newFlushRig(t, 500, 0)
	a, b := r.user("Gone"), r.user("Stays")
	r.record(won(1, game.StatsPoker, a), won(1, game.StatsPoker, b))
	if err := r.users.DeleteAccount(r.ctx, a); err != nil {
		t.Fatal(err)
	}
	if _, err := r.flusher.Pass(r.ctx); err != nil {
		t.Fatal(err)
	}
	var rows int64
	if err := r.d.Pool.QueryRow(r.ctx, `SELECT count(*) FROM player_stats WHERE user_id = $1`, a).Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("%d rows for a deleted account (%v)", rows, err)
	}
	if got := r.account(b).HandsWon; got != 1 {
		t.Fatalf("the other player: %d", got)
	}
}

// The whole pipeline under -race: tables recording from many goroutines while
// passes run, and every hand lands exactly once.
func TestRecordsDuringPassesAreEachCountedExactlyOnce(t *testing.T) {
	r := newFlushRig(t, 2, 0)
	rec := NewRecorder(r.live, util.NewLogger("error", io.Discard))
	var ids []string
	for i := 0; i < 5; i++ {
		ids = append(ids, r.user(fmt.Sprintf("R%d", i)))
	}
	const hands = 40
	var wg sync.WaitGroup
	for w, id := range ids {
		wg.Add(1)
		go func(w int, id string) {
			defer wg.Done()
			for i := 0; i < hands; i++ {
				rec.Record([]game.HandStats{won(1, game.StatsTeenPatti, id)})
			}
		}(w, id)
	}
	stop := make(chan struct{})
	passes := make(chan error, 1)
	go func() {
		for {
			select {
			case <-stop:
				passes <- nil
				return
			default:
			}
			if _, err := r.flusher.Pass(r.ctx); err != nil {
				passes <- err
				return
			}
		}
	}()
	wg.Wait()
	ctx, cancel := context.WithTimeout(r.ctx, 5*time.Second)
	defer cancel()
	if err := rec.Close(ctx); err != nil {
		t.Fatal(err)
	}
	close(stop)
	if err := <-passes; err != nil {
		t.Fatal(err)
	}
	if _, err := r.flusher.Pass(r.ctx); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		if got := r.account(id).HandsWon; got != hands {
			t.Fatalf("%s won %d of %d", id, got, hands)
		}
	}
}
