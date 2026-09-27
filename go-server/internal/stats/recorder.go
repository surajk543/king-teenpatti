package stats

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/live"
)

// Recorder timings and sizes.
const (
	// recordQueue is how many hands may wait to be written to the live store.
	// A table never waits for the store (Record never blocks); a hand that
	// finds the queue full is not counted, with a warning — the live store
	// being slower than every table together is an outage, and statistics are
	// what an outage costs first.
	recordQueue = 4096
	// recordMerge is how many queued hands one RecordStats round trip carries
	// at most: under load the queue is written in batches, not a round trip a
	// hand.
	recordMerge = 64
	// recordTimeout bounds one RecordStats round trip, and forgetTimeout a
	// DropStats.
	recordTimeout = 2 * time.Second
	forgetTimeout = 2 * time.Second
	// warnEvery is the shortest gap between two warnings.
	warnEvery = 10 * time.Second
)

// ErrRecorderClosed is Sync's answer once Close has begun.
var ErrRecorderClosed = errors.New("stats: recorder closed")

// recordItem is one entry of the queue: a hand's deltas, or — synced set, no
// deltas — a marker Sync waits on.
type recordItem struct {
	deltas []live.StatsDelta
	synced chan struct{}
}

// Recorder moves a table's committed counters into the live store off the
// table's actor: Record — a game.StatsRecorder — only queues them, and one
// goroutine writes each hand (or each few queued hands) in one round trip
// (live.Store.RecordStats). A table's actor therefore never waits on this
// store for a statistic (CLAUDE.md §14.1): the hand is over whatever the
// store says.
type Recorder struct {
	store live.Store
	log   *slog.Logger

	queue chan recordItem
	done  chan struct{}
	// mu makes closing the queue safe against a Record in flight: Record
	// sends under the read lock, Close closes under the write lock.
	mu     sync.RWMutex
	closed bool

	recorded atomic.Int64 // hands written
	dropped  atomic.Int64 // hands lost: queue full, store refused, or after Close
	lastWarn atomic.Int64 // epoch ms of the last warning
}

// NewRecorder starts the recorder's goroutine; Close stops it.
func NewRecorder(store live.Store, logger *slog.Logger) *Recorder {
	if logger == nil {
		logger = slog.Default()
	}
	r := &Recorder{
		store: store,
		log:   logger,
		queue: make(chan recordItem, recordQueue),
		done:  make(chan struct{}),
	}
	go r.run()
	return r
}

// Record queues a committed write's counters for the live store. It never
// blocks and never fails: a full queue, or a Record after Close, drops the
// hand with a warning. Safe from any goroutine.
func (r *Recorder) Record(stats []game.HandStats) {
	deltas := Deltas(stats)
	if len(deltas) == 0 {
		return
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.closed {
		r.drop(1, "statistics recorded after shutdown began; not counted")
		return
	}
	select {
	case r.queue <- recordItem{deltas: deltas}:
	default:
		r.drop(1, "statistics queue full; a hand's statistics were not counted")
	}
}

// Sync waits (bounded by ctx) until every hand queued before it has been
// written to the live store, or given up on — for a flush that must include
// them (tests, tooling). ErrRecorderClosed once Close has begun.
func (r *Recorder) Sync(ctx context.Context) error {
	synced := make(chan struct{})
	r.mu.RLock()
	if r.closed {
		r.mu.RUnlock()
		return ErrRecorderClosed
	}
	select {
	case r.queue <- recordItem{synced: synced}:
	case <-ctx.Done():
		r.mu.RUnlock()
		return ctx.Err()
	}
	r.mu.RUnlock()
	select {
	case <-synced:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Forget drops a player's pending counters (DELETE /api/account), best
// effort and bounded: the account's rows are already gone from PostgreSQL,
// and a flush of anything left behind finds the account deleted and adds
// nothing.
func (r *Recorder) Forget(userID string) {
	ctx, cancel := context.WithTimeout(context.Background(), forgetTimeout)
	defer cancel()
	if err := r.store.DropStats(ctx, userID); err != nil {
		r.log.Warn("pending statistics of a deleted account not dropped", "userId", userID, "error", err.Error())
	}
}

// Close stops taking hands and waits (bounded by ctx) until every hand
// already queued is in the live store. Safe to call more than once.
func (r *Recorder) Close(ctx context.Context) error {
	r.mu.Lock()
	if !r.closed {
		r.closed = true
		close(r.queue)
	}
	r.mu.Unlock()
	select {
	case <-r.done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Recorded and Dropped count the hands written to the live store and the
// ones lost on the way (for logs and tests).
func (r *Recorder) Recorded() int64 { return r.recorded.Load() }
func (r *Recorder) Dropped() int64  { return r.dropped.Load() }

// run is the writer: each hand queued, merged with whatever else is waiting
// (up to recordMerge hands), in one RecordStats round trip. A sync marker
// writes what has been gathered first and is then released, so everything
// queued before it is written when its Sync returns. It drains the queue
// after Close and then returns.
func (r *Recorder) run() {
	defer close(r.done)
	var deltas []live.StatsDelta
	hands := 0
	flush := func() {
		if hands > 0 {
			r.write(deltas, hands)
		}
		deltas, hands = nil, 0
	}
	for {
		item, ok := <-r.queue
		if !ok {
			flush()
			return
		}
		r.take(item, &deltas, &hands, flush)
	gather:
		for hands > 0 && hands < recordMerge {
			select {
			case more, ok := <-r.queue:
				if !ok {
					flush()
					return
				}
				r.take(more, &deltas, &hands, flush)
			default:
				break gather
			}
		}
		flush()
	}
}

// take adds one item to what is being gathered, or — a sync marker — writes
// what was gathered and releases the marker.
func (r *Recorder) take(item recordItem, deltas *[]live.StatsDelta, hands *int, flush func()) {
	if item.synced != nil {
		flush()
		close(item.synced)
		return
	}
	*deltas = append(*deltas, item.deltas...)
	*hands++
}

// write is one RecordStats round trip for hands hands' deltas.
func (r *Recorder) write(deltas []live.StatsDelta, hands int) {
	ctx, cancel := context.WithTimeout(context.Background(), recordTimeout)
	defer cancel()
	if err := r.store.RecordStats(ctx, deltas); err != nil {
		r.drop(int64(hands), "statistics not recorded in the live store; not counted", "error", err.Error())
		return
	}
	r.recorded.Add(int64(hands))
}

// drop counts lost hands and warns, at most once per warnEvery.
func (r *Recorder) drop(hands int64, msg string, args ...any) {
	total := r.dropped.Add(hands)
	now := time.Now().UnixMilli()
	last := r.lastWarn.Load()
	if now-last < warnEvery.Milliseconds() || !r.lastWarn.CompareAndSwap(last, now) {
		return
	}
	r.log.Warn(msg, append(args, "hands", hands, "droppedTotal", total)...)
}
