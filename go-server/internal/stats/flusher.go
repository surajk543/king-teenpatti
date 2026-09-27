package stats

import (
	"context"
	"errors"
	"log/slog"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/live"
	"github.com/surajk543/king-teenpatti/go-server/internal/metrics"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// Flusher timings.
const (
	// passTimeout bounds one scheduled pass (every batch it takes).
	passTimeout = 30 * time.Second
	// maxBatchesPerPass bounds how many new batches one pass takes: at the
	// default batch of 500 that is 10,000 players a pass, far above any
	// interval's worth, and a pass that ever hit it leaves the rest for the
	// next one.
	maxBatchesPerPass = 20
	// FlushKeep is how long a stats_flushes receipt is kept: a batch still
	// unfinished in the live store after that would be counted again, and none
	// waits that long. pruneEvery is how often the receipts are pruned.
	FlushKeep  = 7 * 24 * time.Hour
	pruneEvery = time.Hour
)

// FlushStore is the PostgreSQL side of a flush (db.StatsStore): one
// transaction per batch, and the receipts' pruning.
type FlushStore interface {
	Flush(ctx context.Context, batchID string, deltas []db.StatsDelta) (applied bool, err error)
	PruneFlushes(ctx context.Context, olderThanMs int64) (int64, error)
}

// FlusherOptions builds a Flusher.
type FlusherOptions struct {
	// Live is where the pending counters wait (the app's live store).
	Live live.Store
	// DB is where they go (db.StatsStore).
	DB FlushStore
	// Interval is STATS_FLUSH_MS: 0 → the flusher never starts (Start and
	// Stop do nothing); Pass still works when called.
	Interval time.Duration
	// Batch is STATS_FLUSH_BATCH, the most players one transaction holds
	// (below 1 → 1).
	Batch int
	// Now is the clock (nil → time.Now): the receipts' pruning cutoff.
	Now func() time.Time
	// NewID mints batch ids (nil → util.UUID).
	NewID  func() string
	Logger *slog.Logger
	// Metrics feeds game_stats_flushes_total{result} and
	// game_stats_flush_players (nil: nothing observed).
	Metrics *metrics.Metrics
}

// Flusher is the group commit: it moves the players' pending statistics from
// the live store into PostgreSQL in batches, exactly once each.
//
// A pass first retries every batch already taken and not finished — under
// its OWN id, which is what makes a flush exactly once: a batch whose commit
// was never acknowledged finds its receipt in stats_flushes and adds nothing
// (duplicate), and one whose transaction failed finds none and adds everything
// — then takes new batches of up to Batch players until nobody is waiting,
// each flushed in ONE transaction and forgotten by the live store only after
// its COMMIT. A batch that fails stops the pass: it stays taken and the next
// pass (or the next process, at boot) retries it before taking anything new.
// Receipts older than FlushKeep are pruned, at most once every pruneEvery.
type Flusher struct {
	live     live.Store
	db       FlushStore
	interval time.Duration
	batch    int
	now      func() time.Time
	newID    func() string
	log      *slog.Logger
	metrics  *metrics.Metrics

	// passMu runs one pass at a time (the ticker's, the final one, a test's).
	passMu    sync.Mutex
	lastPrune time.Time

	startOnce sync.Once
	stopOnce  sync.Once
	stop      chan struct{}
	done      chan struct{}
	started   atomic.Bool
}

// PassReport is what one pass did.
type PassReport struct {
	// Retried is how many batches taken earlier the pass flushed or found
	// flushed; Batches how many it committed in all (new ones included) and
	// Duplicates how many it found committed already.
	Retried    int
	Batches    int
	Duplicates int
	// Players is how many players the committed batches held.
	Players int
}

// NewFlusher builds a flusher; Start runs it.
func NewFlusher(opts FlusherOptions) *Flusher {
	f := &Flusher{
		live: opts.Live, db: opts.DB, interval: opts.Interval, batch: opts.Batch,
		now: opts.Now, newID: opts.NewID, log: opts.Logger, metrics: opts.Metrics,
		stop: make(chan struct{}), done: make(chan struct{}),
	}
	if f.batch < 1 {
		f.batch = 1
	}
	if f.now == nil {
		f.now = time.Now
	}
	if f.newID == nil {
		f.newID = util.UUID
	}
	if f.log == nil {
		f.log = slog.Default()
	}
	return f
}

// Start runs the flusher: one pass at once — the boot's, which retries any
// batch a previous process left taken before anything new — then one every
// interval until Stop. Nothing when the interval is 0 (STATS_FLUSH_MS=0) or
// either store is missing. Safe to call once.
func (f *Flusher) Start() {
	if f.interval <= 0 || f.live == nil || f.db == nil {
		return
	}
	f.startOnce.Do(func() {
		f.started.Store(true)
		go f.loop()
	})
}

func (f *Flusher) loop() {
	defer close(f.done)
	f.scheduledPass()
	ticker := time.NewTicker(f.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			f.scheduledPass()
		case <-f.stop:
			return
		}
	}
}

// scheduledPass is one pass under passTimeout, a failure logged.
func (f *Flusher) scheduledPass() {
	ctx, cancel := context.WithTimeout(context.Background(), passTimeout)
	defer cancel()
	if _, err := f.Pass(ctx); err != nil {
		f.log.Warn("player statistics flush failed; retried on the next pass", "error", err.Error())
	}
}

// Stop ends the loop and runs one last pass, both bounded by ctx (the
// shutdown's budget), so the counters of the last hands reach PostgreSQL
// before the process goes. Nothing when the flusher never started. Safe to
// call more than once.
func (f *Flusher) Stop(ctx context.Context) error {
	if !f.started.Load() {
		return nil
	}
	var err error
	f.stopOnce.Do(func() {
		close(f.stop)
		select {
		case <-f.done:
		case <-ctx.Done():
			err = ctx.Err()
			return
		}
		_, err = f.Pass(ctx)
	})
	return err
}

// Pass is one flush: the open batches retried, then new ones taken until
// nobody is waiting (maxBatchesPerPass at most), then the receipts pruned if
// it is time. The first failure ends it and is returned; what it had
// committed stays committed.
func (f *Flusher) Pass(ctx context.Context) (PassReport, error) {
	f.passMu.Lock()
	defer f.passMu.Unlock()
	var report PassReport
	if f.live == nil || f.db == nil {
		return report, nil
	}
	open, err := f.live.StatsBatches(ctx)
	if err != nil {
		return report, err
	}
	for _, batch := range open {
		if err := f.flush(ctx, batch, &report); err != nil {
			return report, err
		}
		report.Retried++
	}
	for i := 0; i < maxBatchesPerPass; i++ {
		batch, err := f.live.TakeStatsBatch(ctx, f.newID(), f.batch)
		if errors.Is(err, live.ErrStatsBatchExists) {
			continue // an id minted twice: mint another
		}
		if err != nil {
			return report, err
		}
		if len(batch.Players) == 0 {
			break
		}
		if err := f.flush(ctx, batch, &report); err != nil {
			return report, err
		}
	}
	f.maybePrune(ctx)
	return report, nil
}

// flush is ONE batch: decoded, committed in one transaction under its own
// id, and forgotten by the live store only after the COMMIT. A failure
// leaves it taken, to be retried with the same id.
func (f *Flusher) flush(ctx context.Context, batch live.StatsBatch, report *PassReport) error {
	deltas := make([]db.StatsDelta, 0, len(batch.Players))
	unknown := 0
	for userID, fields := range batch.Players {
		delta, n := Decode(userID, fields)
		unknown += n
		deltas = append(deltas, *delta)
	}
	sort.Slice(deltas, func(i, j int) bool { return deltas[i].UserID < deltas[j].UserID })
	if unknown > 0 {
		f.log.Warn("statistics fields this build does not know were left out of a flush", "batchId", batch.ID, "fields", unknown)
	}
	if len(deltas) > 0 {
		applied, err := f.db.Flush(ctx, batch.ID, deltas)
		if err != nil {
			f.count(metrics.StatsFlushError)
			return err
		}
		if applied {
			f.count(metrics.StatsFlushOK)
			if f.metrics != nil && f.metrics.StatsFlushPlayers != nil {
				f.metrics.StatsFlushPlayers.Observe(float64(len(deltas)))
			}
			report.Batches++
			report.Players += len(deltas)
		} else {
			// Committed by an earlier attempt whose acknowledgement was lost:
			// nothing is added twice, and the batch is forgotten now.
			f.count(metrics.StatsFlushDuplicate)
			report.Duplicates++
		}
	}
	return f.live.FinishStatsBatch(ctx, batch.ID)
}

// maybePrune deletes the receipts older than FlushKeep, at most once every
// pruneEvery (the first pass prunes). A failure is logged and retried at the
// next pass.
func (f *Flusher) maybePrune(ctx context.Context) {
	now := f.now()
	if !f.lastPrune.IsZero() && now.Sub(f.lastPrune) < pruneEvery {
		return
	}
	pruned, err := f.db.PruneFlushes(ctx, now.Add(-FlushKeep).UnixMilli())
	if err != nil {
		f.log.Warn("stats_flushes receipts not pruned", "error", err.Error())
		return
	}
	f.lastPrune = now
	if pruned > 0 {
		f.log.Info("stats_flushes receipts pruned", "rows", pruned)
	}
}

// count adds one batch outcome to game_stats_flushes_total.
func (f *Flusher) count(result string) {
	if f.metrics != nil && f.metrics.StatsFlushes != nil {
		f.metrics.StatsFlushes.WithLabelValues(result).Inc()
	}
}
