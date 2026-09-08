package game_test

// RoomManager ↔ live store (roommanager_live.go): the seat index mirror, the
// matchmaking index, Restore (tables, seats, codes, order, chat, clocks),
// Suspend as the graceful-restart path, the two-owners fence between two
// managers on one store, and that restored tables are swept and merged like
// any other.

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/game/livetest"
	"github.com/surajk543/king-teenpatti/go-server/internal/live"
)

// withStore is the fixture mutation that attaches a live store.
func withStore(store *livetest.Store, instance string) func(*config.GameConfig, *game.RoomManagerOptions) {
	return func(g *config.GameConfig, o *game.RoomManagerOptions) {
		openMenu(g, o)
		o.Live = store
		o.Instance = instance
	}
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func TestRoomsMirrorSeatsAndPublishToTheLiveStore(t *testing.T) {
	store := livetest.New()
	f := newRoomsFixture(t, withStore(store, "node-1"))

	a := f.player("A", rmStart)
	table := f.mustQuickJoin(a, rmBoot, "blind")
	eq(t, store.Seats()[a.ID], table.ID(), "SetSeated on the join")
	row, ok := store.Index()[table.ID()]
	eq(t, ok, true, "published on creation")
	eq(t, row.Players, 1, "one player")
	eq(t, row.State, string(game.TableWaiting), "waiting")
	eq(t, row.Instance, "node-1", "instance tag")
	eq(t, row.Code, table.Code(), "code")
	eq(t, row.Category, "blind", "category")
	eq(t, row.BootAmount, rmBoot, "boot")
	eq(t, row.MaxPlayers, 5, "maxPlayers")

	b := f.player("B", rmStart)
	eq(t, f.mustQuickJoin(b, rmBoot, "blind").ID(), table.ID(), "same table")
	row = store.Index()[table.ID()]
	eq(t, row.Players, 2, "player count published from OnState")
	eq(t, row.State, string(game.TableStarting), "countdown published")
	publishes := len(store.CallsOf("publish_table"))

	// A state event without a change in players or state publishes nothing.
	if _, err := table.SetConnected(a.ID, false, ""); err != nil {
		t.Fatal(err)
	}
	eq(t, len(store.CallsOf("publish_table")), publishes, "no duplicate publish")

	f.mustLeave(a.ID, game.LeaveReasonLeft)
	if _, seated := store.Seats()[a.ID]; seated {
		t.Fatal("ClearSeated on leave")
	}
	eq(t, store.Seats()[b.ID], table.ID(), "B still indexed")
	eq(t, store.Index()[table.ID()].Players, 1, "count republished")

	f.mustLeave(b.ID, game.LeaveReasonLeft)
	if _, seated := store.Seats()[b.ID]; seated {
		t.Fatal("ClearSeated for the last player")
	}
	if _, indexed := store.Index()[table.ID()]; indexed {
		t.Fatal("RetireTable when the emptied table is destroyed")
	}
	eq(t, len(store.CallsOf("retire_table")), 1, "retired once")
	if _, stored := store.Stored(table.ID()); stored {
		t.Fatal("the destroyed table's snapshot is deleted")
	}

	// Private tables are never indexed.
	private := f.rooms.CreateTable(game.CreateTableOptions{IsPrivate: true, Category: "seen"})
	c := f.player("C", rmStart)
	f.mustJoin(private, c)
	if _, indexed := store.Index()[private.ID()]; indexed {
		t.Fatal("private table published")
	}
	eq(t, store.Seats()[c.ID], private.ID(), "but its seats are mirrored")
	_, stored := store.Stored(private.ID())
	eq(t, stored, true, "and its snapshot saved")

	// Kick: the seat index follows.
	d := f.player("D", rmBoot-1)
	pub := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	f.mustJoin(pub, d)
	f.awaitKick(2 * time.Second)
	eventually(t, 2*time.Second, func() bool { _, seated := store.Seats()[d.ID]; return !seated }, "ClearSeated after the kick")
}

// playingFixture is a manager with a live store holding: t1 (blind 200, A+B,
// hand live, A chatted), t2 (seen 200, C alone), t3 (seen 200, E alone,
// created later), t4 (private, D), t5 (empty public). Returns the ids in
// creation order.
func playingFixture(t *testing.T, store *livetest.Store) (*roomsFixture, []string, map[string]game.Player) {
	t.Helper()
	f := newRoomsFixture(t, withStore(store, "old"))
	players := map[string]game.Player{}
	a, b := f.player("A", rmStart), f.player("B", rmStart)
	players["A"], players["B"] = a, b
	t1 := f.mustQuickJoin(a, rmBoot, "blind")
	f.mustQuickJoin(b, rmBoot, "blind")
	f.clock.Advance(f.cfg.NextHandDelay)
	if !t1.HasHand() {
		t.Fatal("t1 should be dealt")
	}
	if _, err := t1.Act(turnUser(t, t1), game.ActionChaal, game.ActRequest{}); err != nil {
		t.Fatal(err)
	}
	if _, err := t1.PostChat(a.ID, "hi from A"); err != nil {
		t.Fatal(err)
	}

	f.clock.Advance(time.Second)
	c := f.player("C", rmStart)
	players["C"] = c
	t2 := f.mustQuickJoin(c, rmBoot, "seen")

	f.clock.Advance(time.Second)
	e := f.player("E", rmStart)
	players["E"] = e
	t3 := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "seen"})
	f.mustJoin(t3, e)

	f.clock.Advance(time.Second)
	d := f.player("D", rmStart)
	players["D"] = d
	t4 := f.rooms.CreateTable(game.CreateTableOptions{IsPrivate: true, Category: "seen"})
	f.mustJoin(t4, d)

	f.clock.Advance(time.Second)
	t5 := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})

	return f, []string{t1.ID(), t2.ID(), t3.ID(), t4.ID(), t5.ID()}, players
}

func TestRoomsRestoreRebuildsTablesSeatsCodesAndOrder(t *testing.T) {
	store := livetest.New()
	f1, ids, players := playingFixture(t, store)
	t1 := f1.rooms.GetTable(ids[0])
	code1 := t1.Code()
	onTurn := turnUser(t, t1)
	deadline := *viewOf(t, t1, onTurn).Turn.Deadline
	handID := mustSnapshotOf(t, t1).Hand.ID
	created := map[string]time.Time{}
	for _, id := range ids {
		created[id] = f1.rooms.GetTable(id).CreatedAt()
	}

	// Graceful restart: suspend, not shutdown.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := f1.rooms.Suspend(ctx); err != nil {
		t.Fatalf("suspend: %v", err)
	}
	eq(t, len(f1.rooms.LiveTables()), 0, "every table gone from the old manager")
	eq(t, len(store.CallsOf("delete_table")), 0, "nothing deleted from the store")
	for _, id := range ids {
		if _, ok := store.Stored(id); !ok {
			t.Fatalf("table %s not in the store after suspend", id)
		}
	}
	eq(t, len(f1.tables.endedCopy()), 0, "no hand was ended by the suspend")
	eq(t, strings.Count(f1.logText(), "table suspended"), 5, "each suspend logged")

	// The new process, 3 s later.
	f2 := newRoomsFixture(t, withStore(store, "new"))
	f2.clock.Advance(f1.clock.Now().Sub(rmEpoch) + 3*time.Second)
	report, err := f2.rooms.Restore(ctx)
	if err != nil {
		t.Fatalf("restore: %v", err)
	}
	eq(t, report.Tables, 5, "five tables")
	eq(t, report.Seats, 5, "five seats")
	eq(t, report.HandsInProgress, 1, "one live hand")
	eq(t, len(report.HandIDs), 1, "its id")
	eq(t, report.HandIDs[0], handID, "is t1's hand")
	eq(t, report.Dropped+report.Skipped+report.Failed, 0, "nothing dropped")

	// Registration: ids, codes, order, index.
	live := f2.rooms.LiveTables()
	eq(t, strings.Join(tableIDs(live), ","), strings.Join(ids, ","), "creation order preserved")
	for _, id := range ids {
		table := f2.rooms.GetTable(id)
		if table == nil {
			t.Fatalf("table %s not restored", id)
		}
		eq(t, table.CreatedAt().Equal(created[id]), true, "createdAt preserved")
	}
	eq(t, f2.rooms.GetTableByCode(strings.ToLower(code1)).ID(), ids[0], "code lookup")
	for name, p := range players {
		table := f2.rooms.GetTableForPlayer(p.ID)
		if table == nil {
			t.Fatalf("%s not indexed", name)
		}
		eq(t, store.Seats()[p.ID], table.ID(), "seat index refreshed in the store")
	}
	restored := f2.rooms.RestoredSeats()
	eq(t, len(restored), 5, "RestoredSeats")
	byUser := map[string]string{}
	for _, r := range restored {
		byUser[r.UserID] = r.RoomID
	}
	eq(t, byUser[players["A"].ID], ids[0], "A at t1")
	eq(t, byUser[players["D"].ID], ids[3], "D at the private table")
	stats := f2.rooms.Stats()
	eq(t, stats.Tables, 5, "stats tables")
	eq(t, stats.Players, 5, "stats players")
	eq(t, stats.ActiveHands, 1, "stats hands")

	// Listener and index.
	f2.events.mu.Lock()
	eq(t, len(f2.events.created), 5, "OnTableCreated for every restored table")
	eq(t, len(f2.events.restored), 5, "OnTableRestored as well")
	f2.events.mu.Unlock()
	index := store.Index()
	for _, id := range []string{ids[0], ids[1], ids[2], ids[4]} {
		if _, ok := index[id]; !ok {
			t.Fatalf("public table %s not published", id)
		}
		eq(t, index[id].Instance, "new", "republished by the new instance")
	}
	if _, ok := index[ids[3]]; ok {
		t.Fatal("private table published")
	}

	// The hand goes on where it was: same turn, same deadline, seats held
	// disconnected, chat back.
	r1 := f2.rooms.GetTable(ids[0])
	eq(t, r1.HasHand(), true, "hand live")
	eq(t, turnUser(t, r1), onTurn, "same player on turn")
	eq(t, *viewOf(t, r1, onTurn).Turn.Deadline, deadline, "same deadline")
	for _, s := range seatsOf(t, r1) {
		eq(t, s.Connected, false, "seat held disconnected")
	}
	history, err := r1.ChatHistory()
	if err != nil {
		t.Fatal(err)
	}
	texts := make([]string, 0, len(history))
	for _, m := range history {
		texts = append(texts, m.Text)
	}
	eq(t, strings.Join(texts, "|"), "A joined the table|B joined the table|hi from A", "chat restored")
	eq(t, r1.LiveSeq() > 0, true, "claimed in the store")
	stored, _ := store.Stored(ids[0])
	eq(t, stored.Seq, r1.LiveSeq(), "store at the new seq")

	// The player acts on the restored table like nothing happened.
	if _, err := r1.Act(onTurn, game.ActionChaal, game.ActRequest{}); err != nil {
		t.Fatalf("act after restore: %v", err)
	}
	eq(t, turnUser(t, r1) != onTurn, true, "turn moved")
	// The turn clock is live: 25 s later the next player times out.
	f2.clock.Advance(f2.cfg.TurnTimeout)
	acts := f2.tables.actionsCopy()
	last := acts[len(acts)-1]
	eq(t, last.Action, game.ActionPack, "timeout pack")
	eq(t, last.Reason, game.PackReasonTimeout, "reason")
	eq(t, strings.Count(f2.logText(), "table restored"), 5, "each restore logged")

	// A second Restore is a no-op on what is already registered.
	again, err := f2.rooms.Restore(ctx)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, again.Tables, 0, "nothing new")
	eq(t, again.Skipped >= 4, true, "already registered")
}

func mustSnapshotOf(t *testing.T, table *game.Table) *game.Snapshot {
	t.Helper()
	snap, err := table.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	return snap
}

func seatsOf(t *testing.T, table *game.Table) []game.SeatInfo {
	t.Helper()
	seats, err := table.Seats()
	if err != nil {
		t.Fatal(err)
	}
	return seats
}

func TestRoomsRestoredTablesAreMergedAndSweptLikeAnyOther(t *testing.T) {
	store := livetest.New()
	f1, ids, players := playingFixture(t, store)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := f1.rooms.Suspend(ctx); err != nil {
		t.Fatal(err)
	}

	f2 := newRoomsFixture(t, withStore(store, "new"))
	f2.clock.Advance(f1.clock.Now().Sub(rmEpoch))
	if _, err := f2.rooms.Restore(ctx); err != nil {
		t.Fatal(err)
	}

	// Consolidation: C (t2, older) and E (t3) are lone players on seen 200
	// tables → E moves onto t2; t3 is destroyed and retired.
	moves := f2.mustConsolidate()
	eq(t, len(moves), 1, "one merge")
	eq(t, moves[0].UserID, players["E"].ID, "E moves")
	eq(t, moves[0].FromRoomID, ids[2], "from the younger table")
	eq(t, moves[0].ToRoomID, ids[1], "onto the older one")
	if f2.rooms.GetTable(ids[2]) != nil {
		t.Fatal("emptied source destroyed")
	}
	eq(t, store.Seats()[players["E"].ID], ids[1], "seat index follows the move")
	if _, ok := store.Stored(ids[2]); ok {
		t.Fatal("destroyed table deleted from the store")
	}
	if _, ok := store.Index()[ids[2]]; ok {
		t.Fatal("destroyed table retired from the index")
	}

	// Sweep: t5 was empty when it was created 30 s+ ago (by the restored
	// createdAt) → swept.
	f2.clock.Advance(31 * time.Second)
	if err := f2.rooms.SweepEmptyTables(); err != nil {
		t.Fatal(err)
	}
	if f2.rooms.GetTable(ids[4]) != nil {
		t.Fatal("empty restored table swept")
	}
	if f2.rooms.GetTable(ids[0]) == nil || f2.rooms.GetTable(ids[1]) == nil || f2.rooms.GetTable(ids[3]) == nil {
		t.Fatal("occupied tables kept")
	}
}

func TestRoomsRestoreDropsSnapshotsItCannotRebuild(t *testing.T) {
	store := livetest.New()
	store.Put("garbage", 3, []byte("{not json"))
	bad := game.Snapshot{RoomID: "noconfig", Code: "NOCONF", State: game.TableWaiting}
	raw, _ := json.Marshal(bad)
	store.Put("noconfig", 1, raw)
	wrongRoom := game.Snapshot{RoomID: "other", Code: "OTHER1", State: game.TableWaiting, Config: game.SnapshotConfig{MaxPlayers: 5, MinPlayers: 2, BootAmount: 200}}
	raw, _ = json.Marshal(wrongRoom)
	store.Put("mismatch", 1, raw)

	f := newRoomsFixture(t, withStore(store, "new"))
	report, err := f.rooms.Restore(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	eq(t, report.Tables, 0, "nothing restored")
	eq(t, report.Dropped, 3, "three dropped")
	for _, id := range []string{"garbage", "noconfig", "mismatch"} {
		if _, ok := store.Stored(id); ok {
			t.Fatalf("%s still stored", id)
		}
	}
	eq(t, len(store.CallsOf("delete_chat")), 3, "chat dropped too")
	eq(t, strings.Count(f.logText(), "dropping stored table"), 3, "each drop logged")

	// A load failure is not a drop.
	store.Put("flaky", 1, []byte("{}"))
	store.Fail("load_table", errors.New("redis timeout"))
	report, err = f.rooms.Restore(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	eq(t, report.Failed, 1, "counted as failed")
	if _, ok := store.Stored("flaky"); !ok {
		t.Fatal("left in the store for a later attempt")
	}
	store.Fail("load_table", nil)

	// A listing failure is fatal.
	store.Fail("list_tables", errors.New("redis down"))
	if _, err := f.rooms.Restore(context.Background()); err == nil {
		t.Fatal("list failure must be returned")
	}
}

func TestRoomsAStaleWriterFencesItselfAndLetsGo(t *testing.T) {
	store := livetest.New()
	f1, ids, players := playingFixture(t, store)
	t1 := f1.rooms.GetTable(ids[0])
	onTurn := turnUser(t, t1)

	// A second process restores the same store while the first is alive
	// (a botched deploy). It claims every table with seq + 1.
	f2 := newRoomsFixture(t, withStore(store, "new"))
	f2.clock.Advance(f1.clock.Now().Sub(rmEpoch))
	if _, err := f2.rooms.Restore(context.Background()); err != nil {
		t.Fatal(err)
	}
	r1 := f2.rooms.GetTable(ids[0])
	eq(t, r1.HasHand(), true, "the new owner has the hand")

	// The old process applies a move: the ledger commits, the move stands,
	// the save is stale → the table fences itself and is destroyed.
	if _, err := t1.Act(onTurn, game.ActionChaal, game.ActRequest{}); err != nil {
		t.Fatalf("the move itself is not refused: %v", err)
	}
	eq(t, t1.Fenced(), true, "fenced")
	errs := f1.tables.errorsCopy()
	eq(t, len(errs), 1, "OnError delivered")
	var fenced *game.FencedError
	eq(t, errors.As(errs[0], &fenced), true, "a FencedError")
	eq(t, errors.Is(errs[0], live.ErrStale), true, "wrapping ErrStale")
	eventually(t, 2*time.Second, func() bool { return f1.rooms.GetTable(ids[0]) == nil }, "the fenced table is destroyed")
	eventually(t, 2*time.Second, func() bool {
		for _, id := range f1.events.destroyedCopy() {
			if id == ids[0] {
				return true
			}
		}
		return false
	}, "OnTableDestroyed")
	eq(t, f1.rooms.GetTableForPlayer(players["A"].ID), nil, "old index cleared")
	eq(t, strings.Contains(f1.logText(), "another process owns this table"), true, "logged")

	// Nothing of the owner's was touched.
	eq(t, store.Seats()[players["A"].ID], ids[0], "seat index intact")
	if _, ok := store.Index()[ids[0]]; !ok {
		t.Fatal("matchmaking index intact")
	}
	if _, ok := store.Stored(ids[0]); !ok {
		t.Fatal("snapshot intact")
	}
	eq(t, len(f1.tables.endedCopy()), 0, "the old process settled nothing")
	eq(t, r1.HasHand(), true, "the new owner plays on")
	eq(t, r1.Fenced(), false, "and is not fenced")
	eq(t, f2.rooms.GetTable(ids[0]) != nil, true, "still registered")
}

func TestRoomsSuspendWithoutAStoreIsAShutdown(t *testing.T) {
	f := newRoomsFixture(t, openMenu)
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "blind"})
	seatTwoAndDeal(t, f, table, rmStart)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := f.rooms.Suspend(ctx); err != nil {
		t.Fatal(err)
	}
	eq(t, len(f.rooms.LiveTables()), 0, "tables destroyed")
	ended := f.tables.endedCopy()
	eq(t, len(ended), 1, "the live hand was settled")
	eq(t, ended[0].Reason, game.WinAllLeft, "all_left")

	report, err := f.rooms.Restore(ctx)
	if err != nil || report.Tables != 0 {
		t.Fatalf("restore without a store: %+v %v", report, err)
	}
}

var _ = sortedKeys[string]

// ------------------------------------------------------ durable backstop

// durableFake is a DurableSource over maps.
type durableFake struct {
	rows          []game.DurableSnapshot
	contributions map[string]map[string]int64
	loadErr       error
	loads         int
}

func (d *durableFake) LoadSnapshots(context.Context) ([]game.DurableSnapshot, error) {
	d.loads++
	if d.loadErr != nil {
		return nil, d.loadErr
	}
	return append([]game.DurableSnapshot(nil), d.rows...), nil
}

func (d *durableFake) HandContributions(_ context.Context, handID string) (map[string]int64, error) {
	out := map[string]int64{}
	for k, v := range d.contributions[handID] {
		out[k] = v
	}
	return out, nil
}

// sinkFake is a SnapshotSink that keeps the newest snapshot per room — what
// game_states would hold — so a test can feed it back as a DurableSource.
type sinkFake struct {
	mu      sync.Mutex
	rows    map[string]game.DurableSnapshot
	deleted []string
}

func newSinkFake() *sinkFake { return &sinkFake{rows: map[string]game.DurableSnapshot{}} }

func (s *sinkFake) MarkDirty(roomID string, seq int64, handID string, snapshot []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if cur, ok := s.rows[roomID]; ok && cur.Seq >= seq {
		return
	}
	s.rows[roomID] = game.DurableSnapshot{RoomID: roomID, HandID: handID, Seq: seq, State: append([]byte(nil), snapshot...)}
}

func (s *sinkFake) MarkDeleted(roomID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.rows, roomID)
	s.deleted = append(s.deleted, roomID)
}

func (s *sinkFake) durable() *durableFake {
	s.mu.Lock()
	defer s.mu.Unlock()
	d := &durableFake{contributions: map[string]map[string]int64{}}
	for _, row := range s.rows {
		d.rows = append(d.rows, row)
	}
	return d
}

// ledgerTotals derives the per-hand ledger totals a real chip_ledger would
// hold from the table's own live snapshot (the money the table applied).
func ledgerTotals(t *testing.T, table *game.Table) (string, map[string]int64) {
	t.Helper()
	snap := mustSnapshotOf(t, table)
	if snap.Hand == nil {
		return "", nil
	}
	totals := map[string]int64{}
	for _, c := range snap.Hand.Contributions {
		totals[c.UserID] = c.Contributed
	}
	return snap.Hand.ID, totals
}

func withStoreAndDurable(store *livetest.Store, sink game.SnapshotSink, durable game.DurableSource, instance string) func(*config.GameConfig, *game.RoomManagerOptions) {
	return func(g *config.GameConfig, o *game.RoomManagerOptions) {
		openMenu(g, o)
		o.Live = store
		o.Instance = instance
		o.Snapshots = sink
		o.Durable = durable
	}
}

func TestRoomsRestoreFallsBackToTheDurableSnapshotsAndReconcilesThem(t *testing.T) {
	store := livetest.New()
	sink := newSinkFake()
	f1 := newRoomsFixture(t, withStoreAndDurable(store, sink, nil, "old"))

	// t1: hand live, two chaals; the sink keeps every snapshot the store got.
	a, b := f1.player("A", rmStart), f1.player("B", rmStart)
	t1 := f1.mustQuickJoin(a, rmBoot, "blind")
	f1.mustQuickJoin(b, rmBoot, "blind")
	f1.clock.Advance(f1.cfg.NextHandDelay)
	if _, err := t1.Act(turnUser(t, t1), game.ActionChaal, game.ActRequest{}); err != nil {
		t.Fatal(err)
	}
	// The durable row is the state BEFORE the last chaal (the async writer
	// had not flushed it): freeze the sink here…
	durable := sink.durable()
	if _, err := t1.Act(turnUser(t, t1), game.ActionChaal, game.ActRequest{}); err != nil {
		t.Fatal(err)
	}
	// …while the ledger has everything.
	handID, totals := ledgerTotals(t, t1)
	durable.contributions[handID] = totals
	var ledgerPot int64
	for _, v := range totals {
		ledgerPot += v
	}
	onTurnBefore := turnUser(t, t1)
	_ = onTurnBefore

	// t2: a waiting table with C alone, also only in the durable rows.
	c := f1.player("C", rmStart)
	f1.clock.Advance(time.Second)
	t2 := f1.mustQuickJoin(c, rmBoot, "seen")
	durable.rows = append(durable.rows, sink.durable().rows...)
	// Deduplicate rows by room (t1 must stay the frozen one).
	seen := map[string]bool{}
	var rows []game.DurableSnapshot
	for _, row := range durable.rows {
		if !seen[row.RoomID] {
			seen[row.RoomID] = true
			rows = append(rows, row)
		}
	}
	durable.rows = rows

	// The old process dies without a suspend, and Redis is lost with it.
	empty := livetest.New()
	f2 := newRoomsFixture(t, withStoreAndDurable(empty, newSinkFake(), durable, "new"))
	f2.clock.Advance(f1.clock.Now().Sub(rmEpoch) + time.Second)
	report, err := f2.rooms.Restore(context.Background())
	if err != nil {
		t.Fatalf("restore: %v", err)
	}
	eq(t, report.FromLive, 0, "Redis had nothing")
	eq(t, report.FromDurable, 2, "both tables came from game_states")
	eq(t, report.Tables, 2, "two tables")
	eq(t, report.Reconciled, 1, "the stale hand was corrected")
	eq(t, report.Rejected, 0, "nothing rejected")
	eq(t, report.HandsInProgress, 1, "one hand")
	eq(t, report.HandIDs[0], handID, "its id")

	// The invariant: pot and every contribution match the ledger.
	r1 := f2.rooms.GetTable(t1.ID())
	if r1 == nil {
		t.Fatal("t1 not restored")
	}
	snap := mustSnapshotOf(t, r1)
	eq(t, snap.Hand.Pot, ledgerPot, "pot == Σ ledger")
	for _, s := range snap.Seats {
		if s != nil {
			eq(t, s.Contributed, totals[s.UserID], "seat contributed == ledger for "+s.UserID)
		}
	}
	for _, cr := range snap.Hand.Contributions {
		eq(t, cr.Contributed, totals[cr.UserID], "record == ledger")
		eq(t, cr.Persisted, totals[cr.UserID], "persisted == banked")
	}
	eq(t, viewOf(t, r1, a.ID).Pot, ledgerPot, "clients see the ledger's pot")

	// Redis is refilled: snapshot, index and seats are back in the store.
	stored, ok := empty.Stored(t1.ID())
	eq(t, ok, true, "t1 written back into the live store")
	eq(t, stored.Seq > durable.rows[0].Seq, true, "under a newer seq")
	if _, ok := empty.Stored(t2.ID()); !ok {
		t.Fatal("t2 written back")
	}
	eq(t, empty.Seats()[a.ID], t1.ID(), "seat index refilled")
	eq(t, empty.Seats()[c.ID], t2.ID(), "seat index refilled")
	if _, ok := empty.Index()[t1.ID()]; !ok {
		t.Fatal("index refilled")
	}
	eq(t, strings.Contains(f2.logText(), `"source":"postgres"`), true, "source logged")

	// The hand goes on.
	if _, err := r1.Act(turnUser(t, r1), game.ActionChaal, game.ActRequest{}); err != nil {
		t.Fatalf("play on: %v", err)
	}
}

func TestRoomsRestoreRejectsADurableSnapshotTooStaleToTrust(t *testing.T) {
	store := livetest.New()
	sink := newSinkFake()
	f1 := newRoomsFixture(t, withStoreAndDurable(store, sink, nil, "old"))
	a, b, c := f1.player("A", rmStart), f1.player("B", rmStart), f1.player("C", rmStart)
	t1 := f1.mustQuickJoin(a, rmBoot, "blind")
	f1.mustQuickJoin(b, rmBoot, "blind")
	f1.mustQuickJoin(c, rmBoot, "blind")
	f1.clock.Advance(f1.cfg.NextHandDelay)
	durable := sink.durable() // frozen right after the deal
	// Then: one player chaals and packs (ledger has their chaal; the frozen
	// snapshot has them active with only the boot — fine so far), and the
	// NEXT player chaals too. Make it too stale: pack the first bettor in
	// the frozen snapshot by hand so the ledger shows a bet from a packed seat.
	first := turnUser(t, t1)
	if _, err := t1.Act(first, game.ActionChaal, game.ActRequest{}); err != nil {
		t.Fatal(err)
	}
	handID, totals := ledgerTotals(t, t1)
	durable.contributions[handID] = totals
	for i, row := range durable.rows {
		var snap game.Snapshot
		if err := json.Unmarshal(row.State, &snap); err != nil {
			t.Fatal(err)
		}
		for _, s := range snap.Seats {
			if s != nil && s.UserID == first {
				s.Status = game.SeatPacked
			}
		}
		for j := range snap.Hand.Contributions {
			if snap.Hand.Contributions[j].UserID == first {
				snap.Hand.Contributions[j].Status = game.SeatPacked
			}
		}
		snap.Hand.PackedUserIDs = []string{first}
		raw, _ := json.Marshal(snap)
		durable.rows[i].State = raw
	}

	f2 := newRoomsFixture(t, withStoreAndDurable(livetest.New(), newSinkFake(), durable, "new"))
	report, err := f2.rooms.Restore(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	eq(t, report.Rejected, 1, "rejected")
	eq(t, report.Tables, 0, "not restored")
	if f2.rooms.GetTable(t1.ID()) != nil {
		t.Fatal("a rejected room is not registered")
	}
	eq(t, len(report.HandIDs), 0, "its hand is left for the refund")
	eq(t, strings.Contains(f2.logText(), "too stale"), true, "logged")
}

func TestRoomsRestorePrefersTheLiveStoreOverTheDurableCopy(t *testing.T) {
	store := livetest.New()
	sink := newSinkFake()
	f1 := newRoomsFixture(t, withStoreAndDurable(store, sink, nil, "old"))
	a, b := f1.player("A", rmStart), f1.player("B", rmStart)
	t1 := f1.mustQuickJoin(a, rmBoot, "blind")
	f1.mustQuickJoin(b, rmBoot, "blind")
	f1.clock.Advance(f1.cfg.NextHandDelay)
	durable := sink.durable() // stale: before the chaal
	if _, err := t1.Act(turnUser(t, t1), game.ActionChaal, game.ActRequest{}); err != nil {
		t.Fatal(err)
	}
	// Poison the durable ledger totals: if pass 2 ever touched this room the
	// invariant check below would catch a pot of 999999.
	handID, _ := ledgerTotals(t, t1)
	durable.contributions[handID] = map[string]int64{a.ID: 999999}
	livePot := mustSnapshotOf(t, t1).Hand.Pot
	ctx := context.Background()
	if err := f1.rooms.Suspend(ctx); err != nil {
		t.Fatal(err)
	}

	f2 := newRoomsFixture(t, withStoreAndDurable(store, newSinkFake(), durable, "new"))
	f2.clock.Advance(f1.clock.Now().Sub(rmEpoch))
	report, err := f2.rooms.Restore(ctx)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, report.FromLive, 1, "from the live store")
	eq(t, report.FromDurable, 0, "the durable copy was ignored")
	eq(t, report.Reconciled+report.Rejected, 0, "no reconciliation")
	eq(t, report.Tables, 1, "one table")
	eq(t, mustSnapshotOf(t, f2.rooms.GetTable(t1.ID())).Hand.Pot, livePot, "the live copy's pot")
	eq(t, durable.loads, 1, "the durable source was consulted, and its row skipped")
}

func TestRoomsReconcileLiveRefillsAnEmptiedStore(t *testing.T) {
	store := livetest.New()
	f := newRoomsFixture(t, withStore(store, "node-1"))
	a, b, c := f.player("A", rmStart), f.player("B", rmStart), f.player("C", rmStart)
	t1 := f.mustQuickJoin(a, rmBoot, "blind")
	f.mustQuickJoin(b, rmBoot, "blind")
	f.clock.Advance(f.cfg.NextHandDelay)
	t2 := f.mustQuickJoin(c, rmBoot, "seen")
	private := f.rooms.CreateTable(game.CreateTableOptions{IsPrivate: true, Category: "seen"})
	f.mustJoin(private, f.player("D", rmStart))

	// Redis restarted empty (or somebody ran FLUSHALL).
	store.Flush()
	if _, ok := store.Stored(t1.ID()); ok {
		t.Fatal("store should be empty")
	}
	before := map[string]int64{t1.ID(): t1.LiveSeq(), t2.ID(): t2.LiveSeq(), private.ID(): private.LiveSeq()}

	report := f.rooms.ReconcileLive(context.Background())
	eq(t, report.Healthy, true, "store answered")
	eq(t, report.Tables, 3, "every table re-saved")
	eq(t, report.Published, 2, "public tables re-published")
	eq(t, report.Seats, 4, "every seat re-set")
	eq(t, report.Errors, 0, "no errors")
	for _, table := range []*game.Table{t1, t2, private} {
		stored, ok := store.Stored(table.ID())
		if !ok {
			t.Fatalf("%s not re-saved", table.ID())
		}
		eq(t, stored.Seq, before[table.ID()]+1, "a fresh seq")
		eq(t, stored.Seq, table.LiveSeq(), "matches the table")
		var snap game.Snapshot
		if err := json.Unmarshal(stored.Snapshot, &snap); err != nil {
			t.Fatal(err)
		}
		eq(t, snap.RoomID, table.ID(), "the right table")
	}
	eq(t, mustHand(t, store, t1.ID()), true, "t1's live hand is back in the store")
	eq(t, store.Seats()[a.ID], t1.ID(), "seats refilled")
	eq(t, store.Seats()[c.ID], t2.ID(), "seats refilled")
	if _, ok := store.Index()[t1.ID()]; !ok {
		t.Fatal("index refilled")
	}
	if _, ok := store.Index()[private.ID()]; ok {
		t.Fatal("private table never indexed")
	}

	// Cheap and idempotent: a second tick re-saves again (a new seq each
	// time) and touches nothing else.
	again := f.rooms.ReconcileLive(context.Background())
	eq(t, again.Tables, 3, "idempotent")

	// An unhealthy store: nothing written, Healthy false.
	store.Fail("ping", errors.New("down"))
	down := f.rooms.ReconcileLive(context.Background())
	eq(t, down.Healthy, false, "unhealthy")
	eq(t, down.Tables, 0, "nothing written")

	// Without a store: a no-op.
	plain := newRoomsFixture(t, openMenu)
	eq(t, plain.rooms.ReconcileLive(context.Background()).Healthy, false, "no store")
}

func mustHand(t *testing.T, store *livetest.Store, roomID string) bool {
	t.Helper()
	stored, ok := store.Stored(roomID)
	if !ok {
		return false
	}
	var snap game.Snapshot
	if err := json.Unmarshal(stored.Snapshot, &snap); err != nil {
		t.Fatal(err)
	}
	return snap.Hand != nil
}
