package game_test

// Test fixture for the RoomManager suite (roommanager_test.go). Lives in the
// external test package so it can use testclock, which imports game.

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"sort"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/game/testclock"
)

const (
	rmBoot  int64 = 200
	rmStart int64 = 200000
)

// rmEpoch is where every fake clock starts (a realistic wire timestamp).
var rmEpoch = time.UnixMilli(1_700_000_000_000)

// roomEvents records the RoomListener surface.
type roomEvents struct {
	mu        sync.Mutex
	created   []string
	destroyed []string
	moved     []game.PlayerMove
	kicked    []game.PlayerKicked
	// trace is every room-level event in order, interleaved with the table
	// events the fixture's tableEvents records into the same slice.
	trace  *[]string
	kickCh chan game.PlayerKicked
}

func (r *roomEvents) note(s string) {
	if r.trace != nil {
		*r.trace = append(*r.trace, s)
	}
}

func (r *roomEvents) OnTableCreated(t *game.Table) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.created = append(r.created, t.ID())
	r.note("created:" + t.ID())
}

func (r *roomEvents) OnTableDestroyed(roomID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.destroyed = append(r.destroyed, roomID)
	r.note("destroyed:" + roomID)
}

func (r *roomEvents) OnPlayerMoved(m game.PlayerMove) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.moved = append(r.moved, m)
	r.note("moved:" + m.UserID)
}

func (r *roomEvents) OnPlayerKicked(k game.PlayerKicked) {
	r.mu.Lock()
	r.kicked = append(r.kicked, k)
	r.note("kicked:" + k.UserID)
	r.mu.Unlock()
	r.kickCh <- k
}

func (r *roomEvents) movedCopy() []game.PlayerMove {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]game.PlayerMove(nil), r.moved...)
}

func (r *roomEvents) destroyedCopy() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.destroyed...)
}

func (r *roomEvents) kickedCopy() []game.PlayerKicked {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]game.PlayerKicked(nil), r.kicked...)
}

// tableEvents records the Table events the RoomManager forwards (the socket
// layer's seat in production). Callbacks run on table actors; the mutex is
// shared with roomEvents so the trace interleaves correctly.
type tableEvents struct {
	game.NopListener
	mu            *sync.Mutex
	rooms         *roomEvents
	actions       []game.ActionEvent
	ended         []game.HandEndedEvent
	showdowns     []game.ShowdownEvent
	kicks         []game.KickEvent
	persistErrors []game.PersistErrorEvent
	errors        []error
}

func (l *tableEvents) OnSeatUpdated(v *game.View, i int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.rooms.note(fmt.Sprintf("seat:%s:%d", v.ID(), i))
}

func (l *tableEvents) OnAction(v *game.View, e game.ActionEvent) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.actions = append(l.actions, e)
}

func (l *tableEvents) OnHandEnded(v *game.View, e game.HandEndedEvent) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.ended = append(l.ended, e)
}

func (l *tableEvents) OnShowdown(v *game.View, e game.ShowdownEvent) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.showdowns = append(l.showdowns, e)
}

func (l *tableEvents) OnKick(v *game.View, e game.KickEvent) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.kicks = append(l.kicks, e)
}

func (l *tableEvents) OnPersistError(v *game.View, e game.PersistErrorEvent) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.persistErrors = append(l.persistErrors, e)
}

func (l *tableEvents) OnError(v *game.View, err error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.errors = append(l.errors, err)
}

func (l *tableEvents) endedCopy() []game.HandEndedEvent {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]game.HandEndedEvent(nil), l.ended...)
}

func (l *tableEvents) actionsCopy() []game.ActionEvent {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]game.ActionEvent(nil), l.actions...)
}

func (l *tableEvents) showdownsCopy() []game.ShowdownEvent {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]game.ShowdownEvent(nil), l.showdowns...)
}

func (l *tableEvents) persistErrorsCopy() []game.PersistErrorEvent {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]game.PersistErrorEvent(nil), l.persistErrors...)
}

func (l *tableEvents) errorsCopy() []error {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]error(nil), l.errors...)
}

// roomsFixture is one RoomManager with a fake clock, a bookless MemoryLedger
// (Node's `settle: () => ({})`), recording listeners and a captured log.
type roomsFixture struct {
	t      *testing.T
	rooms  *game.RoomManager
	clock  *testclock.Fake
	events *roomEvents
	tables *tableEvents
	logs   *bytes.Buffer
	logMu  sync.Mutex
	cfg    config.GameConfig
	seq    int
}

// lockedWriter makes the log buffer safe for the actor goroutines.
type lockedWriter struct {
	mu  *sync.Mutex
	buf *bytes.Buffer
}

func (w lockedWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.buf.Write(p)
}

// newRoomsFixture builds a manager on config.Defaults().Game (the real menu,
// as the Node unit suites ran) after applying mutate to the config and the
// options.
func newRoomsFixture(t *testing.T, mutate func(*config.GameConfig, *game.RoomManagerOptions)) *roomsFixture {
	t.Helper()
	f := &roomsFixture{t: t, clock: testclock.New(rmEpoch), logs: &bytes.Buffer{}}
	f.cfg = config.Defaults().Game
	var trace []string
	f.events = &roomEvents{trace: &trace, kickCh: make(chan game.PlayerKicked, 64)}
	f.tables = &tableEvents{mu: &f.events.mu, rooms: f.events}
	logger := slog.New(slog.NewJSONHandler(lockedWriter{mu: &f.logMu, buf: f.logs}, &slog.HandlerOptions{Level: slog.LevelDebug}))
	opts := game.RoomManagerOptions{
		Chat:          config.Defaults().Chat,
		Ledger:        game.NewMemoryLedger(game.MemoryLedgerHooks{}),
		Clock:         f.clock,
		TableListener: f.tables,
		Listener:      f.events,
		Logger:        logger,
	}
	if mutate != nil {
		mutate(&f.cfg, &opts)
	}
	opts.Game = f.cfg
	f.rooms = game.NewRoomManager(opts)
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = f.rooms.Shutdown(ctx)
	})
	return f
}

// openMenu lifts the stake and menu restrictions (TABLE_STAKES=” and
// LOBBY_TABLES=” in the Node process suites).
func openMenu(g *config.GameConfig, _ *game.RoomManagerOptions) {
	g.TableStakes = []int64{}
	g.LobbyTables = []config.LobbyTable{}
}

func (f *roomsFixture) logText() string {
	f.logMu.Lock()
	defer f.logMu.Unlock()
	return f.logs.String()
}

func (f *roomsFixture) trace() []string {
	f.events.mu.Lock()
	defer f.events.mu.Unlock()
	return append([]string(nil), *f.events.trace...)
}

// player is a distinct account each call (deriving the id from the name
// alone made two players with the same name the same person).
func (f *roomsFixture) player(name string, chips int64) game.Player {
	f.seq++
	return game.Player{ID: fmt.Sprintf("%s-%d", name, f.seq), DisplayName: name, Chips: chips}
}

// singleTable is a public table holding exactly one player.
func (f *roomsFixture) singleTable(boot int64, category game.Category) *game.Table {
	f.t.Helper()
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: boot, Category: string(category)})
	f.mustJoin(table, f.player("Solo", rmStart))
	return table
}

func (f *roomsFixture) mustJoin(table *game.Table, p game.Player) {
	f.t.Helper()
	if err := f.rooms.Join(table, p, "sock-"+p.ID); err != nil {
		f.t.Fatalf("join %s: %v", p.ID, err)
	}
}

func (f *roomsFixture) mustQuickJoin(p game.Player, boot int64, category string) *game.Table {
	f.t.Helper()
	table, err := f.rooms.QuickJoin(p, game.QuickJoinOptions{BootAmount: boot, Category: category})
	if err != nil {
		f.t.Fatalf("quickJoin %s (%d %s): %v", p.ID, boot, category, err)
	}
	return table
}

func (f *roomsFixture) mustConsolidate() []game.PlayerMove {
	f.t.Helper()
	moves, err := f.rooms.ConsolidateTables()
	if err != nil {
		f.t.Fatalf("consolidate: %v", err)
	}
	return moves
}

func (f *roomsFixture) mustLeave(userID, reason string) *game.Table {
	f.t.Helper()
	table, err := f.rooms.Leave(userID, reason)
	if err != nil {
		f.t.Fatalf("leave %s: %v", userID, err)
	}
	return table
}

// seatedIDs are the user ids at the table, sorted.
func seatedIDs(t *testing.T, table *game.Table) []string {
	t.Helper()
	seats, err := table.Seats()
	if err != nil {
		t.Fatalf("seats: %v", err)
	}
	ids := make([]string, 0, len(seats))
	for _, s := range seats {
		ids = append(ids, s.UserID)
	}
	sort.Strings(ids)
	return ids
}

// turnUser is the user on turn, read from a spectator's snapshot.
func turnUser(t *testing.T, table *game.Table) string {
	t.Helper()
	view, err := table.SerializeFor("")
	if err != nil {
		t.Fatalf("serialize: %v", err)
	}
	if view.Turn == nil || view.Turn.UserID == nil {
		t.Fatal("nobody is on turn")
	}
	return *view.Turn.UserID
}

// optionsFor is the viewer's own turn options (you.options), which is where
// Flutter reads the ladder from.
func optionsFor(t *testing.T, table *game.Table, userID string) *game.TurnOptions {
	t.Helper()
	view, err := table.SerializeFor(userID)
	if err != nil {
		t.Fatalf("serialize: %v", err)
	}
	if view.You == nil || view.You.Options == nil {
		t.Fatalf("%s has no options (not on turn?)", userID)
	}
	return view.You.Options
}

func viewOf(t *testing.T, table *game.Table, userID string) *game.TableView {
	t.Helper()
	view, err := table.SerializeFor(userID)
	if err != nil {
		t.Fatalf("serialize: %v", err)
	}
	return view
}

// seatTwoAndDeal seats a and b directly on the table and deals a hand now.
func seatTwoAndDeal(t *testing.T, f *roomsFixture, table *game.Table, chips int64) (game.Player, game.Player) {
	t.Helper()
	a := f.player("A", chips)
	b := f.player("B", chips)
	f.mustJoin(table, a)
	f.mustJoin(table, b)
	if err := table.StartHand(); err != nil {
		t.Fatalf("startHand: %v", err)
	}
	if !table.HasHand() {
		t.Fatal("no hand was dealt")
	}
	return a, b
}

func codeOf(err error) string { return game.CodeOf(err, "<nil>") }

func expectCode(t *testing.T, err error, code string) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected %s, got no error", code)
	}
	if got := codeOf(err); got != code {
		t.Fatalf("expected %s, got %s (%v)", code, got, err)
	}
}

func tableIDs(tables []*game.Table) []string {
	ids := make([]string, 0, len(tables))
	for _, t := range tables {
		ids = append(ids, t.ID())
	}
	return ids
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func equalInt64s(a, b []int64) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// awaitKick waits for the RoomManager's kick goroutine to report.
func (f *roomsFixture) awaitKick(timeout time.Duration) game.PlayerKicked {
	f.t.Helper()
	select {
	case k := <-f.events.kickCh:
		return k
	case <-time.After(timeout):
		f.t.Fatal("no OnPlayerKicked arrived — the kick goroutine deadlocked or never ran")
		return game.PlayerKicked{}
	}
}

// eventually polls cond until it holds or the timeout passes.
func eventually(t *testing.T, timeout time.Duration, cond func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}
