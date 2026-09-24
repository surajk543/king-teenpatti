package socket

import (
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/sio"
)

// The fixes of 24 Sep 2026 (owner's "fix all bugs"): LR-2, LR-6, LR-7.

// serverSocket is the Handler's live socket for userID.
func (st *stack) serverSocket(userID string) *sio.Socket {
	st.t.Helper()
	st.h.mu.Lock()
	defer st.h.mu.Unlock()
	s := st.h.userSockets[userID]
	if s == nil {
		st.t.Fatalf("no live socket for %s", userID)
	}
	return s
}

// tracked reports whether userID's socket is tracked in roomID.
func (st *stack) tracked(userID, roomID string) bool {
	s := st.serverSocket(userID)
	st.h.mu.Lock()
	defer st.h.mu.Unlock()
	_, ok := st.h.roomSockets[roomID][s]
	return ok
}

// LR-6: a request from an account deleted under its live session is refused
// unknown_user (not internal_error with a raw message), and the session ends.
func TestADeletedAccountsRequestIsUnknownUserAndEndsTheSession(t *testing.T) {
	st := newStack(t, nil)
	p := st.player("Gone")
	st.users.mu.Lock()
	delete(st.users.users, p.user.ID)
	st.users.mu.Unlock()

	ack := st.call(p.c, EvRoomQuickJoin, map[string]any{"bootAmount": st.uniqueStake()})
	if ack.OK || ack.Code != auth.CodeUnknownUser || ack.Message != auth.MsgUnknownUser {
		t.Fatalf("a deleted account's quickJoin: %s", ack.Raw)
	}
	if !p.c.WaitClosed(eventTimeout) {
		t.Fatal("the deleted account's socket stayed connected")
	}
	if v := metricValue(st.metrics.SocketErrorsTotal.WithLabelValues(game.CodeInternalError)); v != 0 {
		t.Fatalf("socket_errors_total{internal_error} = %v", v)
	}
}

// EndSession (what DELETE /api/account calls) disconnects the account's socket.
func TestEndingASessionDisconnectsTheAccountsSocket(t *testing.T) {
	st := newStack(t, nil)
	p := st.player("Deleter")
	st.h.EndSession(p.user.ID)
	if !p.c.WaitClosed(eventTimeout) {
		t.Fatal("the socket stayed connected")
	}
	st.h.EndSession(p.user.ID) // nothing left to end: a no-op
}

// LR-7: the request limit binds the ACCOUNT, so reconnecting does not reset
// it: 30 requests on one socket, then a new socket for the same account is
// refused inside the same window.
func TestReconnectingDoesNotResetTheRequestLimit(t *testing.T) {
	st := newStack(t, nil)
	p := st.player("Burst")
	for i := 0; i < ActionRateLimit; i++ {
		if ack := st.call(p.c, EvLobbyList, map[string]any{}); !ack.OK {
			t.Fatalf("request %d refused: %s", i, ack.Raw)
		}
	}
	p.c.Close()
	c := st.connect(p.token)
	if ack := st.call(c, EvLobbyList, map[string]any{}); ack.OK || ack.Code != game.CodeRateLimited {
		t.Fatalf("a fresh socket reset the account's limit: %s", ack.Raw)
	}
	// The window passes and the account works again.
	time.Sleep(ActionRateWindowMs*time.Millisecond + 200*time.Millisecond)
	if ack := st.call(c, EvLobbyList, map[string]any{}); !ack.OK {
		t.Fatalf("still limited after the window: %s", ack.Raw)
	}
}

// LR-2: a room:moved delivered after the player's seat has gone elsewhere (a
// switch or a leave won the race with the consolidation) is stale: the socket
// must not be subscribed to the move's target, nor told it moved there.
func TestAStaleMoveDoesNotSubscribeTheSocketToATableItIsNotSeatedAt(t *testing.T) {
	st := newStack(t, nil)
	boot := st.uniqueStake()
	a := st.player("A")
	ja := st.mustOK(a.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot})
	seatedAt := str(ja.Raw, "roomId")
	other := st.rooms.CreateTable(game.CreateTableOptions{BootAmount: boot, Category: "seen"})
	b := st.player("B")
	st.mustOK(b.c, EvRoomJoinCode, map[string]any{"code": other.Code()})

	mark := a.c.Mark()
	st.h.OnPlayerMoved(game.PlayerMove{UserID: a.user.ID, FromRoomID: seatedAt, ToRoomID: other.ID()})
	if st.tracked(a.user.ID, other.ID()) {
		t.Fatal("a stale move subscribed the socket to a table it is not seated at")
	}
	if !st.tracked(a.user.ID, seatedAt) {
		t.Fatal("a stale move unsubscribed the socket from its own table")
	}
	st.mustOK(b.c, EvChatMessage, map[string]any{"text": "not for A"})
	time.Sleep(200 * time.Millisecond)
	for _, ev := range a.c.Since(mark) {
		if ev.Name == EvRoomMoved || str(ev.Payload, "roomId") == other.ID() {
			t.Fatalf("A received %s from a table it is not at: %s", ev.Name, ev.Payload)
		}
	}
}

// LR-2: after a switch the socket listens to the table the switch RESULT
// names and to nothing else, whatever it had been left tracked in by a race.
func TestASwitchLeavesTheSocketListeningOnlyToItsNewTable(t *testing.T) {
	st := newStack(t, nil)
	boot := st.uniqueStake()
	a := st.player("A")
	st.mustOK(a.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot})
	target := st.rooms.CreateTable(game.CreateTableOptions{BootAmount: boot, Category: "seen"})
	for _, n := range []string{"B", "C"} {
		p := st.player(n)
		st.mustOK(p.c, EvRoomJoinCode, map[string]any{"code": target.Code()})
	}
	// A stray subscription, as a consolidation racing the switch left one: a
	// table at another stake A is not seated at.
	stray := st.rooms.CreateTable(game.CreateTableOptions{BootAmount: st.uniqueStake(), Category: "seen"})
	x := st.player("X")
	st.mustOK(x.c, EvRoomJoinCode, map[string]any{"code": stray.Code()})
	st.h.trackRoom(stray.ID(), st.serverSocket(a.user.ID))

	ack := st.mustOK(a.c, EvRoomSwitch, map[string]any{})
	if str(ack.Raw, "roomId") != target.ID() {
		t.Fatalf("switch ack %s", ack.Raw)
	}
	if st.tracked(a.user.ID, stray.ID()) {
		t.Fatal("the socket is still listening to a table it is not seated at")
	}
	mark := a.c.Mark()
	st.mustOK(x.c, EvChatMessage, map[string]any{"text": "stray"})
	time.Sleep(200 * time.Millisecond)
	for _, ev := range a.c.Since(mark) {
		if str(ev.Payload, "roomId") == stray.ID() {
			t.Fatalf("A received %s from the stray table: %s", ev.Name, ev.Payload)
		}
	}
}
