package db_test

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/metrics"
)

// The durable snapshot writer (LIVE_STATE_PLAN.md "The durable backstop"):
// batched, coalescing, version-guarded, never fatal.

// writerMetrics is a Metrics with just the writer's collectors, so a test can
// read what one flush did.
func writerMetrics() *metrics.Metrics {
	return &metrics.Metrics{
		SnapshotWrites:        prometheus.NewCounterVec(prometheus.CounterOpts{Name: "w"}, []string{"result"}),
		SnapshotWriteDuration: prometheus.NewHistogram(prometheus.HistogramOpts{Name: "d"}),
		SnapshotRowsWritten:   prometheus.NewCounter(prometheus.CounterOpts{Name: "r"}),
	}
}

func counterValue(c prometheus.Counter) float64 {
	var out dto.Metric
	if err := c.Write(&out); err != nil {
		return -1
	}
	return out.Counter.GetValue()
}

// newWriter builds a writer that only Flush drives (an hour-long interval).
func (f *fixture) newWriter(m *metrics.Metrics) *db.SnapshotWriter {
	f.t.Helper()
	w := db.NewSnapshotWriter(f.d, db.SnapshotWriterOptions{Interval: time.Hour, Metrics: m})
	f.t.Cleanup(w.Close)
	return w
}

// row reads one game_states row.
func (f *fixture) row(roomID string) (version int64, handID *string, state string, ok bool) {
	f.t.Helper()
	err := f.d.Pool.QueryRow(f.ctx, `SELECT version, hand_id, state::text FROM game_states WHERE room_id = $1`, roomID).Scan(&version, &handID, &state)
	if err != nil {
		if strings.Contains(err.Error(), "no rows") {
			return 0, nil, "", false
		}
		f.t.Fatal(err)
	}
	return version, handID, state, true
}

func snap(roomID string, seq int64) []byte {
	return []byte(fmt.Sprintf(`{"roomId":%q,"seq":%d,"state":"betting"}`, roomID, seq))
}

// Three marks for one room → one row carrying the newest snapshot.
func TestSnapshotWriterCoalescesAndKeepsTheNewestSeq(t *testing.T) {
	f := newFixture(t)
	m := writerMetrics()
	w := f.newWriter(m)
	w.MarkDirty("room-1", 1, "hand-1", snap("room-1", 1))
	w.MarkDirty("room-1", 3, "hand-1", snap("room-1", 3))
	w.MarkDirty("room-1", 2, "hand-1", snap("room-1", 2)) // older than what is pending: ignored
	if w.Pending() != 1 {
		t.Fatalf("pending = %d, want 1", w.Pending())
	}
	if w.Lag() <= 0 {
		t.Fatal("lag must be positive while something is pending")
	}
	if err := w.Flush(f.ctx); err != nil {
		t.Fatal(err)
	}
	version, handID, state, ok := f.row("room-1")
	if !ok || version != 3 || handID == nil || *handID != "hand-1" || !strings.Contains(state, `"seq": 3`) && !strings.Contains(state, `"seq":3`) {
		t.Fatalf("row = %d %v %s %v", version, handID, state, ok)
	}
	if w.Pending() != 0 || w.Lag() != 0 {
		t.Fatalf("after flush pending=%d lag=%s", w.Pending(), w.Lag())
	}
	if counterValue(m.SnapshotWrites.WithLabelValues(metrics.ResultOK)) != 1 || counterValue(m.SnapshotRowsWritten) != 1 {
		t.Fatalf("writes ok=%v rows=%v", counterValue(m.SnapshotWrites.WithLabelValues(metrics.ResultOK)), counterValue(m.SnapshotRowsWritten))
	}
	// A flush with nothing pending writes nothing and is not counted.
	if err := w.Flush(f.ctx); err != nil {
		t.Fatal(err)
	}
	if counterValue(m.SnapshotWrites.WithLabelValues(metrics.ResultOK)) != 1 {
		t.Fatal("an empty flush was counted")
	}
}

// game_states.version only rises: a flush carrying an older seq (a late
// batch, or a stale process) never overwrites a newer row.
func TestSnapshotWriterVersionGuardNeverGoesBackwards(t *testing.T) {
	f := newFixture(t)
	m := writerMetrics()
	w := f.newWriter(m)
	w.MarkDirty("room-g", 5, "", snap("room-g", 5))
	if err := w.Flush(f.ctx); err != nil {
		t.Fatal(err)
	}
	// Another writer (another process) is behind.
	late := f.newWriter(nil)
	late.MarkDirty("room-g", 3, "hand-old", snap("room-g", 3))
	if err := late.Flush(f.ctx); err != nil {
		t.Fatal(err)
	}
	version, handID, state, _ := f.row("room-g")
	if version != 5 || handID != nil || !strings.Contains(state, `"seq": 5`) && !strings.Contains(state, `"seq":5`) {
		t.Fatalf("row went backwards: %d %v %s", version, handID, state)
	}
	// Equal is stale too.
	late.MarkDirty("room-g", 5, "hand-eq", snap("room-g", 50))
	if err := late.Flush(f.ctx); err != nil {
		t.Fatal(err)
	}
	if version, handID, _, _ := f.row("room-g"); version != 5 || handID != nil {
		t.Fatalf("an equal version overwrote the row: %d %v", version, handID)
	}
	// Newer goes through.
	late.MarkDirty("room-g", 6, "hand-new", snap("room-g", 6))
	if err := late.Flush(f.ctx); err != nil {
		t.Fatal(err)
	}
	if version, handID, _, _ := f.row("room-g"); version != 6 || handID == nil || *handID != "hand-new" {
		t.Fatalf("newer version refused: %d %v", version, handID)
	}
}

// Two hundred rooms → one flush, one transaction, two hundred rows.
func TestSnapshotWriterBatchesManyRoomsInOneTransaction(t *testing.T) {
	f := newFixture(t)
	m := writerMetrics()
	w := f.newWriter(m)
	for i := 0; i < 200; i++ {
		room := fmt.Sprintf("room-%03d", i)
		w.MarkDirty(room, int64(i+1), fmt.Sprintf("hand-%03d", i), snap(room, int64(i+1)))
	}
	if w.Pending() != 200 {
		t.Fatalf("pending = %d", w.Pending())
	}
	if err := w.Flush(f.ctx); err != nil {
		t.Fatal(err)
	}
	if n := f.count(`SELECT COUNT(*) FROM game_states`); n != 200 {
		t.Fatalf("rows = %d, want 200", n)
	}
	if counterValue(m.SnapshotWrites.WithLabelValues(metrics.ResultOK)) != 1 {
		t.Fatalf("flushes = %v, want exactly one for the whole batch", counterValue(m.SnapshotWrites.WithLabelValues(metrics.ResultOK)))
	}
	if counterValue(m.SnapshotRowsWritten) != 200 {
		t.Fatalf("rows written = %v", counterValue(m.SnapshotRowsWritten))
	}
	if version, _, _, _ := f.row("room-199"); version != 200 {
		t.Fatalf("room-199 version = %d", version)
	}
}

// A delete beats a pending snapshot of the same room, a delete after a flush
// removes the row, and a mark after a delete revives the room.
func TestSnapshotWriterDeleteWinsOverPendingDirty(t *testing.T) {
	f := newFixture(t)
	w := f.newWriter(nil)
	// Pending dirty, then deleted → never written.
	w.MarkDirty("room-d", 1, "", snap("room-d", 1))
	w.MarkDeleted("room-d")
	if w.Pending() != 1 {
		t.Fatalf("pending = %d, want 1 (the delete only)", w.Pending())
	}
	if err := w.Flush(f.ctx); err != nil {
		t.Fatal(err)
	}
	if _, _, _, ok := f.row("room-d"); ok {
		t.Fatal("a deleted room was written")
	}
	// Written, then deleted → gone.
	w.MarkDirty("room-e", 1, "", snap("room-e", 1))
	if err := w.Flush(f.ctx); err != nil {
		t.Fatal(err)
	}
	w.MarkDeleted("room-e")
	if err := w.Flush(f.ctx); err != nil {
		t.Fatal(err)
	}
	if _, _, _, ok := f.row("room-e"); ok {
		t.Fatal("the row survived its delete")
	}
	// Deleted, then dirty again (the table lives on) → written.
	w.MarkDeleted("room-f")
	w.MarkDirty("room-f", 2, "", snap("room-f", 2))
	if err := w.Flush(f.ctx); err != nil {
		t.Fatal(err)
	}
	if version, _, _, ok := f.row("room-f"); !ok || version != 2 {
		t.Fatalf("revived room: %d %v", version, ok)
	}
}

// The ticker flushes on its own; Flush at shutdown writes what is pending;
// nothing is accepted after Close.
func TestSnapshotWriterFlushesOnTheTickerAndAtShutdown(t *testing.T) {
	f := newFixture(t)
	w := db.NewSnapshotWriter(f.d, db.SnapshotWriterOptions{Interval: 50 * time.Millisecond})
	if !w.Enabled() {
		t.Fatal("writer disabled")
	}
	w.MarkDirty("room-t", 1, "", snap("room-t", 1))
	deadline := time.Now().Add(3 * time.Second)
	for {
		if _, _, _, ok := f.row("room-t"); ok {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the ticker never flushed")
		}
		time.Sleep(10 * time.Millisecond)
	}
	// Shutdown: mark, Flush, Close — the mark lands; a later mark is dropped.
	w.MarkDirty("room-u", 1, "", snap("room-u", 1))
	if err := w.Flush(f.ctx); err != nil {
		t.Fatal(err)
	}
	w.Close()
	w.Close() // idempotent
	w.MarkDirty("room-v", 1, "", snap("room-v", 1))
	if w.Pending() != 0 {
		t.Fatal("a mark after Close was kept")
	}
	if _, _, _, ok := f.row("room-u"); !ok {
		t.Fatal("the shutdown flush lost a row")
	}

	// A disabled writer (SNAPSHOT_FLUSH_MS=0) keeps nothing and writes nothing.
	off := db.NewSnapshotWriter(f.d, db.SnapshotWriterOptions{Interval: 0})
	off.MarkDirty("room-off", 1, "", snap("room-off", 1))
	if off.Enabled() || off.Pending() != 0 || off.Flush(f.ctx) != nil {
		t.Fatal("a disabled writer did something")
	}
	off.Close()
	if _, _, _, ok := f.row("room-off"); ok {
		t.Fatal("a disabled writer wrote a row")
	}
}

// A failing database is logged and counted; the batch is kept and lands on
// the next flush once the database is back. A newer snapshot or a delete that
// arrives meanwhile wins over the kept copy.
func TestSnapshotWriterSurvivesADatabaseFailure(t *testing.T) {
	f := newFixture(t)
	m := writerMetrics()
	w := f.newWriter(m)
	w.MarkDirty("room-a", 1, "", snap("room-a", 1))
	w.MarkDirty("room-b", 1, "", snap("room-b", 1))
	w.MarkDirty("room-c", 1, "", snap("room-c", 1))
	if err := w.Flush(f.ctx); err != nil {
		t.Fatal(err)
	}
	w.MarkDirty("room-a", 2, "", snap("room-a", 2))
	w.MarkDirty("room-b", 2, "", snap("room-b", 2))
	w.MarkDeleted("room-c")

	// The database refuses every write for a while (a constraint no row can
	// satisfy stands in for an outage; renaming the table would only make the
	// search_path fall through to public.game_states on a shared server).
	if err := f.d.Exec(f.ctx, `ALTER TABLE game_states ADD CONSTRAINT outage CHECK (false) NOT VALID`); err != nil {
		t.Fatal(err)
	}
	if err := w.Flush(f.ctx); err == nil {
		t.Fatal("flush succeeded against a missing table")
	}
	if counterValue(m.SnapshotWrites.WithLabelValues(metrics.ResultError)) != 1 {
		t.Fatal("the failure was not counted")
	}
	if w.Pending() != 3 {
		t.Fatalf("pending after a failed flush = %d, want the batch kept (3)", w.Pending())
	}
	// Meanwhile: room-a moves on (newer wins), room-b is destroyed (delete wins).
	w.MarkDirty("room-a", 3, "", snap("room-a", 3))
	w.MarkDeleted("room-b")

	if err := f.d.Exec(f.ctx, `ALTER TABLE game_states DROP CONSTRAINT outage`); err != nil {
		t.Fatal(err)
	}
	if err := w.Flush(f.ctx); err != nil {
		t.Fatalf("flush after recovery: %v", err)
	}
	if version, _, _, ok := f.row("room-a"); !ok || version != 3 {
		t.Fatalf("room-a = %d %v, want 3", version, ok)
	}
	if _, _, _, ok := f.row("room-b"); ok {
		t.Fatal("room-b should have been deleted")
	}
	if _, _, _, ok := f.row("room-c"); ok {
		t.Fatal("room-c's kept delete was lost")
	}
	if w.Pending() != 0 {
		t.Fatalf("pending = %d after recovery", w.Pending())
	}
}

// LoadSnapshots hands back what the writer stored; HandContributions is the
// ledger's word on who staked what.
func TestLoadSnapshotsAndHandContributionsRoundTrip(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("A"), f.user("B")
	f.boot("room-x", "hand-x", 200, a, b)
	if _, err := f.ledger.Bet(f.ctx, game.BetRequest{UserID: a.ID, Amount: 400, RoomID: "room-x", HandID: "hand-x", ActionID: "x-1"}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.ledger.Bet(f.ctx, game.BetRequest{UserID: b.ID, Amount: 400, RoomID: "room-x", HandID: "hand-x", ActionID: "x-2", Reason: game.LedgerReasonShow}); err != nil {
		t.Fatal(err)
	}
	got, err := f.d.HandContributions(f.ctx, "hand-x")
	if err != nil {
		t.Fatal(err)
	}
	total := map[string]int64{}
	for _, row := range got {
		total[row.UserID] = row.Amount
	}
	if len(got) != 2 || total[a.ID] != 600 || total[b.ID] != 600 {
		t.Fatalf("contributions = %v", got)
	}
	// Ledger order: B's show is the most recent row of the hand, so B comes
	// last — that is what ReconcileWithLedger hands the next turn to.
	if got[len(got)-1].UserID != b.ID {
		t.Fatalf("ledger order = %v, want B last", got)
	}
	if none, err := f.d.HandContributions(f.ctx, "no-such-hand"); err != nil || len(none) != 0 {
		t.Fatalf("unknown hand: %v %v", none, err)
	}

	w := f.newWriter(nil)
	w.MarkDirty("room-x", 7, "hand-x", snap("room-x", 7))
	if err := w.Flush(f.ctx); err != nil {
		t.Fatal(err)
	}
	time.Sleep(2 * time.Millisecond) // distinct updated_at
	w.MarkDirty("room-y", 2, "", snap("room-y", 2))
	if err := w.Flush(f.ctx); err != nil {
		t.Fatal(err)
	}
	snaps, err := f.d.LoadSnapshots(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(snaps) != 2 || snaps[0].RoomID != "room-x" || snaps[1].RoomID != "room-y" {
		t.Fatalf("snapshots = %+v", snaps)
	}
	x := snaps[0]
	if x.Seq != 7 || x.HandID != "hand-x" || x.UpdatedAt == 0 {
		t.Fatalf("room-x = %+v", x)
	}
	var parsed struct {
		RoomID string `json:"roomId"`
		Seq    int64  `json:"seq"`
	}
	if err := json.Unmarshal(x.State, &parsed); err != nil || parsed.RoomID != "room-x" || parsed.Seq != 7 {
		t.Fatalf("snapshot bytes = %s (%v)", x.State, err)
	}
	if snaps[1].HandID != "" {
		t.Fatalf("room-y hand = %q, want empty between hands", snaps[1].HandID)
	}
	// An empty table → an empty, non-nil slice.
	if err := f.d.Exec(f.ctx, `DELETE FROM game_states`); err != nil {
		t.Fatal(err)
	}
	if empty, err := f.d.LoadSnapshots(f.ctx); err != nil || empty == nil || len(empty) != 0 {
		t.Fatalf("empty = %v %v", empty, err)
	}
}

// Owner's rule (LIVE_STATE_PLAN.md invariant 5): chat is never written to
// PostgreSQL. A real table's snapshot, taken after a distinctive chat line,
// goes through the writer; the stored state must not carry the text. The
// writer stores the bytes it is handed and nothing else, so this pins both
// the writer and the game package's Snapshot against a future change.
func TestGameStatesNeverContainsChat(t *testing.T) {
	f := newFixture(t)
	const secret = "PINEAPPLE-CHAT-LINE-7f3a9c"
	table := game.NewTable(game.TableOptions{
		ID:   "room-chat",
		Code: "CHAT01",
		Config: game.TableConfig{
			Category: game.CategorySeen, BootAmount: 100, MaxPlayers: 5, MinPlayers: 2,
			TurnTimeout: time.Minute, NextHandDelay: time.Hour, SideshowTimeout: time.Minute,
		},
		Ledger: game.NewMemoryLedger(game.MemoryLedgerHooks{}),
	})
	defer func() { _ = table.Destroy() }()
	if _, err := table.AddPlayer(game.NewPlayer{UserID: "u-1", DisplayName: "Chatty", Chips: 10000}); err != nil {
		t.Fatal(err)
	}
	if msg, err := table.PostChat("u-1", secret); err != nil || msg == nil {
		t.Fatalf("post chat: %v %v", msg, err)
	}
	history, err := table.ChatHistory()
	if err != nil || len(history) == 0 || !strings.Contains(history[len(history)-1].Text, secret) {
		t.Fatalf("the chat line was not stored in memory: %v %v", history, err)
	}
	snapshot, err := table.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), secret) {
		t.Fatalf("game.Snapshot carries chat text: %s", raw)
	}
	w := f.newWriter(nil)
	w.MarkDirty(table.ID(), 1, "", raw)
	if err := w.Flush(f.ctx); err != nil {
		t.Fatal(err)
	}
	_, _, state, ok := f.row(table.ID())
	if !ok {
		t.Fatal("no row")
	}
	if strings.Contains(state, secret) || strings.Contains(strings.ToLower(state), `"chat"`) || strings.Contains(strings.ToLower(state), `"messages"`) {
		t.Fatalf("game_states.state carries chat: %s", state)
	}
	// No chat table or column exists to write to.
	if n := f.count(`SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = $1 AND table_name ILIKE '%chat%'`, f.d.Schema); n != 0 {
		t.Fatalf("%d chat table(s) in the schema", n)
	}
	if n := f.count(`SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = $1 AND column_name ILIKE '%chat%'`, f.d.Schema); n != 0 {
		t.Fatalf("%d chat column(s) in the schema", n)
	}
}
