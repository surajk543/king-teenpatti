package db

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/metrics"
)

// The durable backstop of the live state (LIVE_STATE_PLAN.md "The durable
// backstop: reconstructing Redis from PostgreSQL"). Redis is fast and
// disposable only because every table's snapshot also reaches game_states —
// not inside the money transaction any more (that cost every move a JSONB
// write), and not once a second either (that cost the money the disk it
// needed), but from here: the table actor marks its room dirty at the two
// HAND BOUNDARIES — the deal and the settlement — and one goroutine flushes
// every dirty room in ONE transaction every SNAPSHOT_FLUSH_MS. A restart whose Redis came back empty rebuilds its
// tables from game_states (LoadSnapshots), reconciling each against the
// ledger (HandContributions) because the durable copy is written only at the
// two hand boundaries and is therefore a whole hand behind the money.

// DurableSnapshot is one game_states row as LoadSnapshots returns it — the
// game package's DurableSource contract (RoomID, HandID, Seq =
// game_states.version = the live-store sequence, State = the game.Snapshot
// JSON verbatim, UpdatedAt = when the writer flushed it, epoch ms).
type DurableSnapshot = game.DurableSnapshot

// *DB is the game package's DurableSource; *SnapshotWriter its SnapshotSink.
var (
	_ game.DurableSource = (*DB)(nil)
	_ game.SnapshotSink  = (*SnapshotWriter)(nil)
)

// SnapshotWriterOptions builds a SnapshotWriter.
type SnapshotWriterOptions struct {
	// Interval is SNAPSHOT_FLUSH_MS. <= 0 disables the writer: MarkDirty and
	// MarkDeleted drop their input, nothing runs, Flush is a no-op.
	Interval time.Duration
	// FlushTimeout bounds one batched transaction (default 10 s).
	FlushTimeout time.Duration
	Logger       *slog.Logger
	Metrics      *metrics.Metrics // nil → no observations
	Clock        func() time.Time // nil → time.Now
}

// SnapshotWriter batches game_states writes: MarkDirty / MarkDeleted are
// non-blocking and coalesce per room (only the newest snapshot of a room is
// kept, and a room marked deleted drops any pending snapshot), a goroutine
// flushes the pending set every Interval as one transaction — one multi-row
// upsert over unnest() guarded by `WHERE game_states.version <
// EXCLUDED.version`, then one DELETE … WHERE room_id = ANY($1) — and Flush
// runs the same pass on demand (graceful shutdown). Failures are logged and
// counted (game_snapshot_writes_total{result="error"}), never fatal: the
// money is already committed, and the failed batch is merged back into the
// pending set so the next flush retries it (unless a newer snapshot or a
// delete for that room arrived meanwhile — those win).
//
// Memory is bounded by the number of live rooms: one pending entry per room
// at most, whatever the move rate.
type SnapshotWriter struct {
	db       *DB
	interval time.Duration
	timeout  time.Duration
	log      *slog.Logger
	metrics  *metrics.Metrics
	clock    func() time.Time

	mu      sync.Mutex
	dirty   map[string]pendingSnapshot
	deleted map[string]struct{}
	closed  bool

	// flushMu serialises flush passes (the ticker's and Flush's).
	flushMu sync.Mutex
	stop    chan struct{}
	done    chan struct{}
	once    sync.Once
}

// pendingSnapshot is one room's newest unflushed snapshot.
type pendingSnapshot struct {
	seq      int64
	handID   string
	snapshot []byte
	since    time.Time // when the room first became dirty (lag metric)
}

// NewSnapshotWriter builds the writer and, when Interval > 0, starts its
// flush goroutine. Close (or Flush + Close at shutdown) stops it.
func NewSnapshotWriter(d *DB, opts SnapshotWriterOptions) *SnapshotWriter {
	log := opts.Logger
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	clock := opts.Clock
	if clock == nil {
		clock = time.Now
	}
	timeout := opts.FlushTimeout
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	w := &SnapshotWriter{
		db:       d,
		interval: opts.Interval,
		timeout:  timeout,
		log:      log,
		metrics:  opts.Metrics,
		clock:    clock,
		dirty:    map[string]pendingSnapshot{},
		deleted:  map[string]struct{}{},
		stop:     make(chan struct{}),
		done:     make(chan struct{}),
	}
	if w.interval > 0 {
		go w.loop()
	} else {
		close(w.done)
	}
	return w
}

// Enabled reports whether the writer runs (SNAPSHOT_FLUSH_MS > 0).
func (w *SnapshotWriter) Enabled() bool { return w.interval > 0 }

// MarkDirty records the newest snapshot of a room for the next flush. Never
// blocks; a snapshot older than (or equal to) the pending one is ignored, a
// room marked deleted since is revived by it (the table lives again). The
// slice is retained — callers hand over the encoded snapshot they will not
// touch again (the table actor encodes a fresh one per save).
func (w *SnapshotWriter) MarkDirty(roomID string, seq int64, handID string, snapshot []byte) {
	if w.interval <= 0 {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return
	}
	if cur, ok := w.dirty[roomID]; ok && cur.seq >= seq {
		return
	}
	delete(w.deleted, roomID)
	since := w.clock()
	if cur, ok := w.dirty[roomID]; ok {
		since = cur.since
	}
	w.dirty[roomID] = pendingSnapshot{seq: seq, handID: handID, snapshot: snapshot, since: since}
}

// MarkDeleted records that a room's row must go (the table was destroyed).
// Never blocks; any pending snapshot of the room is dropped so a flush can
// never resurrect a destroyed table.
func (w *SnapshotWriter) MarkDeleted(roomID string) {
	if w.interval <= 0 {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return
	}
	delete(w.dirty, roomID)
	w.deleted[roomID] = struct{}{}
}

// Pending is the number of rooms waiting to be flushed (dirty + deleted).
func (w *SnapshotWriter) Pending() int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return len(w.dirty) + len(w.deleted)
}

// Lag is the age of the oldest pending snapshot (game_snapshot_lag_seconds);
// 0 when nothing is pending.
func (w *SnapshotWriter) Lag() time.Duration {
	w.mu.Lock()
	defer w.mu.Unlock()
	var oldest time.Time
	for _, p := range w.dirty {
		if oldest.IsZero() || p.since.Before(oldest) {
			oldest = p.since
		}
	}
	if oldest.IsZero() {
		return 0
	}
	if lag := w.clock().Sub(oldest); lag > 0 {
		return lag
	}
	return 0
}

// Flush writes everything pending now, in one transaction, and returns the
// write's error (also logged and counted). Safe to call concurrently with
// the ticker; the two passes never interleave.
func (w *SnapshotWriter) Flush(ctx context.Context) error {
	if w.interval <= 0 {
		return nil
	}
	return w.flush(ctx)
}

// Close stops the goroutine. Pending entries are NOT flushed — call Flush
// first at a graceful shutdown. Idempotent.
func (w *SnapshotWriter) Close() {
	w.once.Do(func() {
		w.mu.Lock()
		w.closed = true
		w.mu.Unlock()
		if w.interval > 0 {
			close(w.stop)
		}
	})
	<-w.done
}

// loop is the flush goroutine.
func (w *SnapshotWriter) loop() {
	defer close(w.done)
	ticker := time.NewTicker(w.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			ctx, cancel := context.WithTimeout(context.Background(), w.timeout)
			_ = w.flush(ctx)
			cancel()
		case <-w.stop:
			return
		}
	}
}

// flush is one pass: take the pending sets, write them, merge back what
// failed.
func (w *SnapshotWriter) flush(ctx context.Context) error {
	w.flushMu.Lock()
	defer w.flushMu.Unlock()

	w.mu.Lock()
	dirty, deleted := w.dirty, w.deleted
	w.dirty = make(map[string]pendingSnapshot, len(dirty))
	w.deleted = make(map[string]struct{}, len(deleted))
	w.mu.Unlock()
	if len(dirty) == 0 && len(deleted) == 0 {
		return nil
	}

	started := time.Now()
	rows, err := w.write(ctx, dirty, deleted)
	if w.metrics != nil {
		w.metrics.SnapshotWriteDuration.Observe(time.Since(started).Seconds())
		if err == nil {
			w.metrics.SnapshotWrites.WithLabelValues(metrics.ResultOK).Inc()
			w.metrics.SnapshotRowsWritten.Add(float64(rows))
		} else {
			w.metrics.SnapshotWrites.WithLabelValues(metrics.ResultError).Inc()
		}
	}
	if err == nil {
		return nil
	}
	w.log.Error("durable snapshot flush failed; will retry", "error", err.Error(), "rooms", len(dirty), "deletes", len(deleted))
	// Merge back: a newer snapshot or a delete that arrived meanwhile wins.
	w.mu.Lock()
	for roomID, p := range dirty {
		if _, gone := w.deleted[roomID]; gone {
			continue
		}
		if cur, ok := w.dirty[roomID]; ok && cur.seq >= p.seq {
			continue
		}
		w.dirty[roomID] = p
	}
	for roomID := range deleted {
		if _, revived := w.dirty[roomID]; revived {
			continue
		}
		w.deleted[roomID] = struct{}{}
	}
	w.mu.Unlock()
	return err
}

// write is the transaction: the multi-row upsert, then the delete. The
// delete runs AFTER the upsert so a room in both sets (impossible by
// construction, kept safe anyway) ends up deleted. Returns rows affected.
func (w *SnapshotWriter) write(ctx context.Context, dirty map[string]pendingSnapshot, deleted map[string]struct{}) (int64, error) {
	var rows int64
	err := w.db.WithTx(ctx, func(tx pgx.Tx) error {
		if len(dirty) > 0 {
			at := w.clock().UnixMilli()
			roomIDs := make([]string, 0, len(dirty))
			handIDs := make([]*string, 0, len(dirty))
			seqs := make([]int64, 0, len(dirty))
			states := make([]string, 0, len(dirty))
			stamps := make([]int64, 0, len(dirty))
			for roomID, p := range dirty {
				roomIDs = append(roomIDs, roomID)
				handIDs = append(handIDs, nullIfEmpty(p.handID))
				seqs = append(seqs, p.seq)
				state := p.snapshot
				if len(state) == 0 {
					state = []byte("{}")
				}
				states = append(states, string(state))
				stamps = append(stamps, at)
			}
			tag, err := tx.Exec(ctx, `INSERT INTO game_states (room_id, hand_id, version, state, updated_at)
			   SELECT t.room_id, t.hand_id, t.version, t.state::jsonb, t.updated_at
			     FROM unnest($1::text[], $2::text[], $3::bigint[], $4::text[], $5::bigint[])
			       AS t(room_id, hand_id, version, state, updated_at)
			   ON CONFLICT (room_id) DO UPDATE
			      SET hand_id = EXCLUDED.hand_id,
			          version = EXCLUDED.version,
			          state = EXCLUDED.state,
			          updated_at = EXCLUDED.updated_at
			    WHERE game_states.version < EXCLUDED.version`,
				roomIDs, handIDs, seqs, states, stamps)
			if err != nil {
				return err
			}
			rows += tag.RowsAffected()
		}
		if len(deleted) > 0 {
			ids := make([]string, 0, len(deleted))
			for roomID := range deleted {
				ids = append(ids, roomID)
			}
			tag, err := tx.Exec(ctx, `DELETE FROM game_states WHERE room_id = ANY($1::text[])`, ids)
			if err != nil {
				return err
			}
			rows += tag.RowsAffected()
		}
		return nil
	})
	return rows, err
}

// LoadSnapshots returns every game_states row, oldest flush first — the
// durable copies a restart rebuilds from when the live store has lost a
// room (game.DurableSource).
func (d *DB) LoadSnapshots(ctx context.Context) ([]DurableSnapshot, error) {
	rows, err := d.Pool.Query(ctx, `SELECT room_id, hand_id, version, state, updated_at FROM game_states ORDER BY updated_at, room_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []DurableSnapshot{}
	for rows.Next() {
		var s DurableSnapshot
		var handID *string
		if err := rows.Scan(&s.RoomID, &handID, &s.Seq, &s.State, &s.UpdatedAt); err != nil {
			return nil, err
		}
		if handID != nil {
			s.HandID = *handID
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// HandContributions is what the ledger says each player has staked in a
// hand — boots, bets and shows, as positive totals (game.DurableSource).
// The ledger is never behind the money, so a restore from a durable
// snapshot sets each seat's contribution and the pot from this, not from
// the snapshot.
//
// The rows come back in LEDGER ORDER: each player is placed by their most
// recent row for the hand (MAX(id) — chip_ledger.id is a BIGSERIAL, so it
// is the order the chips actually went in), which makes the last element
// whoever moved last. game.ReconcileWithLedger gives the turn to the seat
// after them, so a hand rebuilt from its opening snapshot resumes where the
// engine would have gone next rather than asking somebody to act twice.
func (d *DB) HandContributions(ctx context.Context, handID string) ([]game.LedgerContribution, error) {
	rows, err := d.Pool.Query(ctx, `SELECT user_id, -SUM(delta)::bigint AS contributed FROM chip_ledger
	   WHERE hand_id = $1 AND reason IN ($2, $3, $4)
	   GROUP BY user_id
	   ORDER BY MAX(id)`, handID, game.LedgerReasonBoot, game.LedgerReasonBet, game.LedgerReasonShow)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []game.LedgerContribution{}
	for rows.Next() {
		var entry game.LedgerContribution
		if err := rows.Scan(&entry.UserID, &entry.Amount); err != nil {
			return nil, err
		}
		out = append(out, entry)
	}
	return out, rows.Err()
}
