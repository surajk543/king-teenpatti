package game

// Adversarial concurrency review of the Table actor and the RoomManager.
// Every test here pins a specific interleaving the Node server's single
// thread could not produce; each is white-box (package game) because it
// needs the per-player stripe, the tableHooks listener or the actor's View
// to force the interleaving deterministically instead of hoping for it.

import (
	"context"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
)

// reviewRoomListener records RoomListener calls and signals kicks.
type reviewRoomListener struct {
	NopRoomListener
	mu     sync.Mutex
	kicked []PlayerKicked
	kickCh chan PlayerKicked
}

func (l *reviewRoomListener) OnPlayerKicked(k PlayerKicked) {
	l.mu.Lock()
	l.kicked = append(l.kicked, k)
	l.mu.Unlock()
	select {
	case l.kickCh <- k:
	default:
	}
}

// newReviewRooms builds a RoomManager on a fake clock (no hand ever deals
// unless the test advances it) with an open menu and no entry cap.
func newReviewRooms(t *testing.T) (*RoomManager, *reviewRoomListener, *fakeClock) {
	t.Helper()
	g := config.Defaults().Game
	g.TableStakes = []int64{}
	g.LobbyTables = []config.LobbyTable{}
	g.EntryCapMaxChips = 0
	rl := &reviewRoomListener{kickCh: make(chan PlayerKicked, 16)}
	clock := newFakeClock(clockStart)
	rm := NewRoomManager(RoomManagerOptions{
		Game:     g,
		Chat:     config.Defaults().Chat,
		Ledger:   NewMemoryLedger(MemoryLedgerHooks{}),
		Clock:    clock,
		Listener: rl,
		Logger:   slog.New(slog.DiscardHandler),
	})
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = rm.Shutdown(ctx)
	})
	return rm, rl, clock
}

// withTimeout fails the test instead of hanging when fn deadlocks.
func withTimeout(t *testing.T, d time.Duration, what string, fn func()) {
	t.Helper()
	done := make(chan struct{})
	go func() {
		defer close(done)
		fn()
	}()
	select {
	case <-done:
	case <-time.After(d):
		t.Fatalf("REVIEW deadlock: %s did not finish within %s", what, d)
	}
}

// TestReviewKickGoroutineMustNotFollowThePlayerToAnotherTable pins the
// check-then-act gap in tableHooks.OnKick: the goroutine checks "still
// seated at the kicking table" with GetTableForPlayer, and only THEN takes
// the player's stripe inside Leave. A leave + join of the same player that
// slips into that gap (a churning bot pipelines room:leave and room:quickJoin
// in one TCP segment; the kick goroutine is merely descheduled) means the
// stale kick removes the player from the table they have just sat down at
// and reports room:kicked for the old one.
//
// The gap is forced deterministically by holding the player's stripe while
// the kick goroutine runs its check, moving the player under it, and only
// then letting the kick proceed.
func TestReviewKickGoroutineMustNotFollowThePlayerToAnotherTable(t *testing.T) {
	rm, rl, _ := newReviewRooms(t)

	x := rm.CreateTable(CreateTableOptions{BootAmount: 200, Category: "blind"})
	y := rm.CreateTable(CreateTableOptions{BootAmount: 5000, Category: "blind"})
	u := Player{ID: "u-kicked", DisplayName: "U", Chips: 1_000_000}
	for _, p := range []struct {
		t *Table
		p Player
	}{
		{x, u},
		{x, Player{ID: "v", DisplayName: "V", Chips: 1_000_000}},
		{y, Player{ID: "w", DisplayName: "W", Chips: 1_000_000}},
		{y, Player{ID: "z", DisplayName: "Z", Chips: 1_000_000}},
	} {
		if err := rm.Join(p.t, p.p, ""); err != nil {
			t.Fatalf("join %s: %v", p.p.ID, err)
		}
	}

	// Hold U's stripe: the kick goroutine's GetTableForPlayer check runs
	// (it needs only mu) but its Leave blocks on the stripe.
	ul := rm.userLock(u.ID)
	ul.Lock()

	// The table announces an idle kick for U (what onTurnTimeout does on
	// the actor); the hook spawns its goroutine.
	rm.hooks.OnKick(x.view, KickEvent{UserID: u.ID, DisplayName: "U", Reason: KickReasonIdle, Message: "idle"})
	time.Sleep(50 * time.Millisecond) // let the goroutine reach the stripe

	// Meanwhile U leaves X and sits down at Y (the stripe-holding halves of
	// Leave and Join, exactly what those calls do once they own the stripe).
	if _, err := rm.vacate(u.ID, LeaveReasonLeft); err != nil {
		t.Fatalf("vacate: %v", err)
	}
	if err := rm.seat(y, u, ""); err != nil {
		t.Fatalf("seat at y: %v", err)
	}
	ul.Unlock()

	// The kick goroutine now runs. Whatever it does, U must still be at Y.
	deadline := time.After(2 * time.Second)
	for {
		select {
		case k := <-rl.kickCh:
			t.Fatalf("REVIEW: stale kick for table %s was delivered after the player moved to %s: %+v", x.ID(), y.ID(), k)
		case <-deadline:
			goto check
		case <-time.After(150 * time.Millisecond):
			goto check
		}
	}
check:
	if got := rm.GetTableForPlayer(u.ID); got != y {
		var id string
		if got != nil {
			id = got.ID()
		}
		t.Fatalf("REVIEW: after a stale kick the player is indexed at %q, want the new table %s", id, y.ID())
	}
	seats, err := y.Seats()
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, s := range seats {
		if s.UserID == u.ID {
			found = true
		}
	}
	if !found {
		t.Fatalf("REVIEW: the stale kick removed the player from the table they had moved to")
	}
}

// TestReviewDestroyWhileAPosterIsQueuedDoesNotLeakOrHang: posts queued
// behind Destroy must all return ErrTableDestroyed promptly (no goroutine
// parked on the posts channel forever).
func TestReviewDestroyWhilePostersAreQueued(t *testing.T) {
	h := newHarness(t, TableConfig{
		Category: CategorySeen, BootAmount: 100, MaxPlayers: 5, MinPlayers: 2,
		TurnTimeout: 25 * time.Second, NextHandDelay: 4 * time.Second,
	})
	h.seat("a", 10_000)
	h.seat("b", 10_000)

	// Block the actor with a slow post so the others queue behind it.
	release := make(chan struct{})
	started := make(chan struct{})
	go func() {
		_ = h.table.run(func() {
			close(started)
			<-release
		})
	}()
	<-started

	var wg sync.WaitGroup
	results := make(chan error, 32)
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := h.table.SerializeFor("a")
			results <- err
		}()
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		results <- h.table.Destroy()
	}()
	time.Sleep(20 * time.Millisecond)
	close(release)

	withTimeout(t, 3*time.Second, "posts queued behind Destroy", wg.Wait)
	close(results)
	destroyedErrs, ok := 0, 0
	for err := range results {
		switch {
		case err == nil:
			ok++
		case err == ErrTableDestroyed:
			destroyedErrs++
		default:
			t.Fatalf("unexpected error: %v", err)
		}
	}
	if ok+destroyedErrs != 17 {
		t.Fatalf("lost posts: ok=%d destroyed=%d", ok, destroyedErrs)
	}
	if !h.table.Destroyed() {
		t.Fatal("table not destroyed")
	}
}

// TestReviewTimersAreInertAfterDestroyUnderRealClock: with the real clock a
// turn timer, a start timer and a settle-retry timer armed before Destroy
// must never touch the destroyed table (they post through run and get
// ErrTableDestroyed). Detects a panic or a data race on freed state.
func TestReviewTimersAreInertAfterDestroyUnderRealClock(t *testing.T) {
	failing := NewMemoryLedger(MemoryLedgerHooks{
		Settle: func(HandRecord, []SettleEntry) (map[string]int64, error) {
			return nil, NewGameError(CodePersistFailed, "down")
		},
	})
	rec := &recorder{}
	table := NewTable(TableOptions{
		ID: "rt", Code: "RT0001",
		Config: TableConfig{
			Category: CategorySeen, BootAmount: 100, MaxPlayers: 5, MinPlayers: 2,
			TurnTimeout: 30 * time.Millisecond, NextHandDelay: 20 * time.Millisecond,
			MaxMissedTurns: 3,
		},
		Ledger:   failing,
		Clock:    RealClock{},
		Listener: rec,
	})
	for _, id := range []string{"a", "b"} {
		if _, err := table.AddPlayer(NewPlayer{UserID: id, DisplayName: id, Chips: 10_000}); err != nil {
			t.Fatal(err)
		}
	}
	// Wait for the deal (start timer fires after 20 ms).
	deadline := time.Now().Add(2 * time.Second)
	for !table.HasHand() && time.Now().Before(deadline) {
		time.Sleep(2 * time.Millisecond)
	}
	if !table.HasHand() {
		t.Fatal("no hand dealt")
	}
	// Both pack via timeout → hand ends → settle fails → retry timer armed.
	for table.HasHand() && time.Now().Before(deadline) {
		time.Sleep(2 * time.Millisecond)
	}
	// A new start timer is armed by maybeStart; a retry timer by retrySettle.
	if err := table.Destroy(); err != nil {
		t.Fatal(err)
	}
	before := rec.count()
	time.Sleep(150 * time.Millisecond) // every real timer would have fired by now
	if after := rec.count(); after != before {
		t.Fatalf("REVIEW: %d events were delivered after Destroy", after-before)
	}
	if err := table.Destroy(); err != ErrTableDestroyed {
		t.Fatalf("second Destroy: %v", err)
	}
}

// TestReviewShutdownSettlesLiveHandsWithinBudget: RoomManager.Shutdown on
// tables with live hands must settle each pot (all_left to the remaining
// player) and return well within the 8 s budget when the ledger answers.
func TestReviewShutdownSettlesLiveHands(t *testing.T) {
	var mu sync.Mutex
	settled := map[string]int64{}
	ledger := NewMemoryLedger(MemoryLedgerHooks{
		Settle: func(hand HandRecord, entries []SettleEntry) (map[string]int64, error) {
			mu.Lock()
			defer mu.Unlock()
			for _, e := range entries {
				if e.IsWinner {
					settled[hand.RoomID] = hand.Pot
				}
			}
			return map[string]int64{}, nil
		},
	})
	g := config.Defaults().Game
	g.TableStakes, g.LobbyTables = []int64{}, []config.LobbyTable{}
	clock := newFakeClock(clockStart)
	rm := NewRoomManager(RoomManagerOptions{Game: g, Chat: config.Defaults().Chat, Ledger: ledger, Clock: clock, Logger: slog.New(slog.DiscardHandler)})

	tables := make([]*Table, 0, 5)
	for i := 0; i < 5; i++ {
		tb := rm.CreateTable(CreateTableOptions{BootAmount: 200, Category: "seen"})
		tables = append(tables, tb)
		for _, id := range []string{"a", "b"} {
			p := Player{ID: id + "-" + tb.ID(), DisplayName: id, Chips: 100_000}
			if err := rm.Join(tb, p, ""); err != nil {
				t.Fatal(err)
			}
		}
	}
	clock.Advance(g.NextHandDelay) // deal everywhere
	for _, tb := range tables {
		if !tb.HasHand() {
			t.Fatalf("table %s has no live hand", tb.ID())
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	started := time.Now()
	var err error
	withTimeout(t, 5*time.Second, "RoomManager.Shutdown", func() { err = rm.Shutdown(ctx) })
	if err != nil {
		t.Fatalf("shutdown: %v", err)
	}
	if d := time.Since(started); d > 2*time.Second {
		t.Fatalf("shutdown took %s", d)
	}
	mu.Lock()
	defer mu.Unlock()
	for _, tb := range tables {
		if settled[tb.ID()] != 400 {
			t.Fatalf("table %s: pot %d not settled on shutdown", tb.ID(), settled[tb.ID()])
		}
	}
}

// TestReviewShutdownReturnsAtDeadlineWhenTheLedgerHangs: a hung Postgres
// inside Destroy → endHand → Settle blocks that table's actor; Shutdown must
// still return ctx.Err() at the deadline instead of hanging the process.
func TestReviewShutdownReturnsAtDeadlineWhenTheLedgerHangs(t *testing.T) {
	hang := make(chan struct{})
	defer close(hang)
	ledger := NewMemoryLedger(MemoryLedgerHooks{
		Settle: func(HandRecord, []SettleEntry) (map[string]int64, error) {
			<-hang // a statement that never returns
			return map[string]int64{}, nil
		},
	})
	g := config.Defaults().Game
	g.TableStakes, g.LobbyTables = []int64{}, []config.LobbyTable{}
	clock := newFakeClock(clockStart)
	rm := NewRoomManager(RoomManagerOptions{Game: g, Chat: config.Defaults().Chat, Ledger: ledger, Clock: clock, Logger: slog.New(slog.DiscardHandler)})
	tb := rm.CreateTable(CreateTableOptions{BootAmount: 200, Category: "seen"})
	for _, id := range []string{"a", "b"} {
		if err := rm.Join(tb, Player{ID: id, DisplayName: id, Chips: 100_000}, ""); err != nil {
			t.Fatal(err)
		}
	}
	clock.Advance(g.NextHandDelay)
	if !tb.HasHand() {
		t.Fatal("no hand")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	var err error
	withTimeout(t, 3*time.Second, "RoomManager.Shutdown with a hung ledger", func() { err = rm.Shutdown(ctx) })
	if err != context.DeadlineExceeded {
		t.Fatalf("want DeadlineExceeded, got %v", err)
	}
}

// TestReviewLeaveDuringLiveHandNeverStrandsIndex: 30 rounds of two players
// leaving the same table at the same moment as a third joins and a sweep
// runs; afterwards every indexed player is seated and every seated player is
// indexed, and no player is seated at two tables.
func TestReviewIndexAndSeatsAgreeUnderChurn(t *testing.T) {
	rm, _, clock := newReviewRooms(t)
	const boot = 200
	players := make([]Player, 12)
	for i := range players {
		players[i] = Player{ID: "p" + string(rune('a'+i)), DisplayName: "P", Chips: 1_000_000}
	}
	var wg sync.WaitGroup
	for round := 0; round < 30; round++ {
		for _, p := range players {
			wg.Add(1)
			go func(p Player) {
				defer wg.Done()
				if rm.GetTableForPlayer(p.ID) != nil {
					_, _ = rm.Leave(p.ID, LeaveReasonLeft)
				} else {
					_, _ = rm.QuickJoin(p, QuickJoinOptions{BootAmount: boot, Category: "blind"})
				}
			}(p)
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _ = rm.ConsolidateTables()
			_ = rm.SweepEmptyTables()
		}()
		withTimeout(t, 5*time.Second, "churn round", wg.Wait)
		clock.Advance(35 * time.Second)
	}
	// Reconcile.
	rm.mu.Lock()
	index := make(map[string]string, len(rm.playerRooms))
	for k, v := range rm.playerRooms {
		index[k] = v
	}
	tables := rm.tablesLocked()
	rm.mu.Unlock()
	seatedAt := map[string]string{}
	for _, tb := range tables {
		seats, err := tb.Seats()
		if err != nil {
			continue
		}
		for _, s := range seats {
			if prev, dup := seatedAt[s.UserID]; dup {
				t.Fatalf("%s seated at both %s and %s", s.UserID, prev, tb.ID())
			}
			seatedAt[s.UserID] = tb.ID()
		}
	}
	for uid, room := range index {
		if seatedAt[uid] != room {
			t.Fatalf("index says %s is at %s, seats say %q", uid, room, seatedAt[uid])
		}
	}
	for uid, room := range seatedAt {
		if index[uid] != room {
			t.Fatalf("%s is seated at %s but indexed at %q", uid, room, index[uid])
		}
	}
}
