package socket

// Adversarial concurrency review of the realtime layer: interleavings Node's
// single thread made impossible and the Go port must rule out explicitly.

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/game/testclock"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket/testclient"
)

// TestReviewSimultaneousSignInsLeaveExactlyOneLiveSocket: two sockets for
// the same account complete their CONNECT at the same instant while the
// account's current socket is seated at a table whose actor is inside a slow
// ledger write. Node's synchronous connection handler serialised the two: the
// second saw the first in userSockets and replaced it. The Go onConnection
// read `previous` under mu, released it, disconnected the previous socket
// (which posts SetConnected(false) to the busy actor) and only then wrote
// userSockets[user] = s — so both newcomers read the same `previous`, both
// replaced it, and both stayed connected: two live sessions on one seat,
// both receiving room:state and both able to act.
func TestReviewSimultaneousSignInsLeaveExactlyOneLiveSocket(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("")
	u := d.onTurn

	// Hold the table's actor inside a ledger write for a while.
	st.books.delay.Store(int64(600 * time.Millisecond))
	defer st.books.delay.Store(0)
	if err := u.c.Emit(EvGameAction, map[string]any{"action": "chaal"}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(80 * time.Millisecond) // the chaal is now inside persist()

	// Two more sign-ins for the same account, at once.
	var wg sync.WaitGroup
	clients := make([]*testclient.Client, 2)
	for i := range clients {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			c, err := testclient.Dial(ctx, st.ts.URL, u.token)
			if err != nil {
				// Replaced so fast that "40" and "41" arrived together: that
				// socket is simply not live. (A real failure to reach the
				// server would leave nobody live and fail the count below.)
				t.Logf("dial %d: %v", i, err)
				if c != nil {
					st.track(c)
				}
				return
			}
			st.track(c)
			clients[i] = c
		}(i)
	}
	wg.Wait()

	// Let the ledger write finish and every replacement settle.
	time.Sleep(1500 * time.Millisecond)

	live := 0
	for _, c := range append([]*testclient.Client{u.c}, clients...) {
		if c != nil && c.Connected() {
			live++
		}
	}
	if live != 1 {
		t.Fatalf("REVIEW: %d live sockets for one account after two simultaneous sign-ins (want exactly 1, Node's one-session rule)", live)
	}
	if got := st.h.Stats().Sockets; got != 2 { // u's account + the waiting player
		t.Fatalf("userSockets has %d entries, want 2", got)
	}
}

// TestReviewReplacedSocketNeverStaysTracked: after a replacement the dead
// socket must be gone from roomSockets even when its own join handler was
// still finishing (trackRoom's connected check can be raced by the
// replacement). A leftover would receive nothing but would be counted and
// iterated for every room:state until the table closes.
func TestReviewReplacedSocketNeverStaysTracked(t *testing.T) {
	st := newStack(t, nil)
	boot := st.uniqueStake()
	for round := 0; round < 40; round++ {
		u, tok := st.login("Flapper")
		first := st.connect(tok)
		// Join and replace at the same instant.
		var wg sync.WaitGroup
		wg.Add(2)
		var second *testclient.Client
		go func() {
			defer wg.Done()
			_ = first.Emit(EvRoomQuickJoin, map[string]any{"bootAmount": boot})
		}()
		go func() {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			c, err := testclient.Dial(ctx, st.ts.URL, tok)
			if err != nil {
				t.Errorf("dial: %v", err)
				return
			}
			st.track(c)
			second = c
		}()
		wg.Wait()
		if t.Failed() {
			return
		}
		// Wait until the server has settled: the old socket is closed and the
		// account is (or is not) seated.
		if !first.WaitClosed(3 * time.Second) {
			t.Fatalf("round %d: the first socket was not replaced", round)
		}
		time.Sleep(30 * time.Millisecond)
		table := st.rooms.GetTableForPlayer(u.ID)
		if table != nil {
			// Every tracked viewer must be a connected socket.
			st.h.mu.Lock()
			for s := range st.h.roomSockets[table.ID()] {
				if !s.Connected() {
					st.h.mu.Unlock()
					t.Fatalf("round %d: a disconnected socket is still tracked on %s", round, table.ID())
				}
			}
			st.h.mu.Unlock()
		}
		// Tidy up for the next round.
		if second != nil && second.Connected() {
			_, _ = second.Request(EvRoomLeave, map[string]any{}, ackTimeout)
			second.Disconnect()
		}
		_, _ = st.rooms.Leave(u.ID, "left")
	}
}

// TestReviewSeatCompletedOnADeadSocketIsNotOrphaned: a join whose socket is
// replaced while the join is in flight (during the user lookup) finishes
// seating the account on a socket that is already gone. Node did the same
// and the seat then sat there with no live socket, no grace timer and no
// resume offer: the account answered already_in_room to every join until
// the idle kick, 75 s later. The port should hand the seat to the live
// socket, or at least start the grace clock.
func TestReviewSeatCompletedOnADeadSocketIsNotOrphaned(t *testing.T) {
	st := newStack(t, nil)
	boot := st.uniqueStake()
	u, tok := st.login("Orphan")
	first := st.connect(tok)
	// Slow the join's user lookup (only that one: the delay is read on entry
	// to FindByID, so it is lifted again before the second handshake) and land
	// the replacement while the join is inside it.
	st.users.delay.Store(int64(400 * time.Millisecond))
	if err := first.Emit(EvRoomQuickJoin, map[string]any{"bootAmount": boot}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(60 * time.Millisecond) // the join is inside FindByID
	st.users.delay.Store(0)
	second := st.connect(tok) // replaces `first` while the join is in flight
	if !first.WaitClosed(3 * time.Second) {
		t.Fatal("first socket not replaced")
	}
	// The join completes on the dead socket.
	deadline := time.Now().Add(3 * time.Second)
	for st.rooms.GetTableForPlayer(u.ID) == nil && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	table := st.rooms.GetTableForPlayer(u.ID)
	if table == nil {
		t.Fatal("the join never completed")
	}

	// Acceptable outcomes: the live socket was handed the seat (room:joined
	// arrived on `second`), or the seat is on the grace clock and lapses.
	if _, err := second.Wait(EvRoomJoined, func(raw json.RawMessage) bool {
		return str(raw, "roomId") == table.ID()
	}, 2*time.Second); err == nil {
		return // the seat followed the live socket
	}
	// Otherwise the grace timer must be running for this account.
	time.Sleep(st.cfg.Game.ReconnectGrace + 300*time.Millisecond)
	if st.rooms.GetTableForPlayer(u.ID) != nil {
		st.h.mu.Lock()
		_, pending := st.h.pendingRemovals[u.ID]
		st.h.mu.Unlock()
		t.Fatalf("REVIEW: seat completed on a dead socket is orphaned (no room:joined to the live socket, grace pending=%v, still seated=%v)", pending, true)
	}
}

// TestReviewSignInDuringALapseWaitsAndGetsTheOffer: the grace timer has
// fired and graceExpired is inside rooms.Leave (the actor is busy with a
// slow ledger write) when the player signs in again. The sign-in must not
// restore a seat that is being removed under it (it would receive
// room:joined and then a you:null room:state with no room:left — Node's
// synchronous index deletion made that impossible); it waits for the lapse
// and receives session:ready with the resume offer instead. Also pins that
// the wait is released (no hang until lapseWait).
func TestReviewSignInDuringALapseWaitsAndGetsTheOffer(t *testing.T) {
	clock := testclock.New(time.UnixMilli(1_700_000_000_000))
	st := newStackWithClock(t, nil, clock)
	d := st.dealtTable("")
	u, v := d.waiting, d.onTurn

	// U drops; the grace timer is armed on the fake clock.
	u.c.Close()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if seat, _ := d.table.FindSeat(u.user.ID); seat != nil && !seat.Connected {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}

	// V's chaal holds the actor inside persist, so the Leave that the lapse
	// posts will block there after the index has been cleared.
	st.books.delay.Store(int64(700 * time.Millisecond))
	defer st.books.delay.Store(0)
	if err := v.c.Emit(EvGameAction, map[string]any{"action": "chaal"}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(60 * time.Millisecond)

	lapsed := make(chan struct{})
	go func() {
		defer close(lapsed)
		clock.Advance(st.cfg.Game.ReconnectGrace + time.Millisecond) // graceExpired runs here
	}()
	time.Sleep(60 * time.Millisecond) // graceExpired is now inside Leave

	started := time.Now()
	again := st.dial(u.token)
	ready, err := again.Wait(EvSessionReady, nil, 5*time.Second)
	if err != nil {
		t.Fatalf("no session:ready after a lapse: %v", err)
	}
	waited := time.Since(started)
	select {
	case <-lapsed:
	case <-time.After(5 * time.Second):
		t.Fatal("the lapse never finished")
	}
	if waited > 3*time.Second {
		t.Fatalf("REVIEW: sign-in waited %s for the lapse (the wait was not released)", waited)
	}
	if got := str(ready, "resume.roomId"); got != d.roomID {
		t.Fatalf("session:ready.resume.roomId = %q, want %s (%s)", got, d.roomID, ready)
	}
	if _, ok := again.Last(EvRoomJoined); ok {
		t.Fatal("REVIEW: a seat that was lapsing was restored to the new socket")
	}
	if st.rooms.GetTableForPlayer(u.user.ID) != nil {
		t.Fatal("the lapse did not remove the seat")
	}
}
