package socket

import (
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket/testclient"
)

// Friends at the table (owner, 26 Sep 2026), the socket half of the two
// pushes: NotifyFriendRequest and NotifyFriendAccepted reach ONE account's
// live socket — at a table or in the lobby — exactly as given, and nobody
// else: not the table that account sits at, not a player with no socket.

// barrier is a ping round trip: every frame queued for c before it was sent
// has arrived once its ack has (acks and events share the socket's one write
// queue).
func barrier(t *testing.T, c *testclient.Client) {
	t.Helper()
	if _, err := c.Request(EvPingRTT, 1, ackTimeout); err != nil {
		t.Fatalf("ping: %v", err)
	}
}

// friendEvents are the friend:* events among evs.
func friendEvents(evs []testclient.Event) []testclient.Event {
	var out []testclient.Event
	for _, e := range evs {
		if e.Name == EvFriendRequest || e.Name == EvFriendAccepted {
			out = append(out, e)
		}
	}
	return out
}

func TestAFriendPushReachesThatPlayersSocketAloneAtATableOrInTheLobby(t *testing.T) {
	st := newStack(t, nil)
	d := st.dealtTable("seen")
	lobby := st.player("Lobby")
	marks := map[*player]int{d.a: d.a.c.Mark(), d.b: d.b.c.Mark(), lobby: lobby.c.Mark()}

	picture, url := int64(7), "https://cdn.example/bear.svg"
	request := auth.FriendRequestItem{
		RequestID: 41,
		Player:    auth.PlayerCard{UserID: "sender-id", DisplayName: "Sender", ProfilePicture: auth.PlayerPicture{ID: &picture, URL: &url}},
		CreatedAt: 1_790_000_000_000,
	}
	accepted := auth.FriendAccepted{
		RequestID:    41,
		Player:       auth.PlayerCard{UserID: "accepter-id", DisplayName: "Accepter"},
		FriendsSince: 1_790_000_000_500,
	}
	st.h.NotifyFriendRequest(d.a.user.ID, request)     // seated, mid-hand
	st.h.NotifyFriendAccepted(lobby.user.ID, accepted) // in the lobby
	// Nobody to tell: no socket, so nothing anywhere and nothing kept.
	st.h.NotifyFriendRequest("no-socket-player", request)
	st.h.NotifyFriendAccepted("no-socket-player", accepted)
	for p := range marks {
		barrier(t, p.c)
	}

	want := map[*player][]string{
		d.a:   {EvFriendRequest + ` {"requestId":41,"player":{"userId":"sender-id","displayName":"Sender","profilePicture":{"id":7,"url":"https://cdn.example/bear.svg"}},"createdAt":1790000000000}`},
		d.b:   nil, // at the same table: a push is never a room's
		lobby: {EvFriendAccepted + ` {"requestId":41,"player":{"userId":"accepter-id","displayName":"Accepter","profilePicture":{"id":null,"url":null}},"friendsSince":1790000000500}`},
	}
	for p, mark := range marks {
		var got []string
		for _, e := range friendEvents(p.c.Since(mark)) {
			got = append(got, e.Name+" "+string(e.Payload))
		}
		if len(got) != len(want[p]) || (len(got) == 1 && got[0] != want[p][0]) {
			t.Errorf("%s received %q, want %q", p.user.DisplayName, got, want[p])
		}
	}
	// Counted once per push that had a socket to go to, under the event's own
	// name — a constant, so no new label value.
	for event, n := range map[string]float64{EvFriendRequest: 1, EvFriendAccepted: 1} {
		if v := metricValue(st.metrics.SocketEmitsTotal.WithLabelValues(event)); v != n {
			t.Errorf("socket_emits_total{%s} = %v, want %v", event, v, n)
		}
	}
}

// A player whose socket has dropped — the reconnect grace — is told nothing,
// and the push is not waiting for them when they come back.
func TestAFriendPushIsNeverKeptForAPlayerWithNoSocket(t *testing.T) {
	st := newStack(t, nil)
	p := st.player("Away")
	p.c.Close()
	// The account has no socket once the server has run its disconnect.
	deadline := time.Now().Add(eventTimeout)
	for st.h.Stats().Sockets != 0 {
		if time.Now().After(deadline) {
			t.Fatalf("the dropped socket is still the account's: %+v", st.h.Stats())
		}
		time.Sleep(5 * time.Millisecond)
	}
	st.h.NotifyFriendRequest(p.user.ID, auth.FriendRequestItem{RequestID: 1, Player: auth.PlayerCard{UserID: "x"}})
	st.h.NotifyFriendAccepted(p.user.ID, auth.FriendAccepted{RequestID: 1, Player: auth.PlayerCard{UserID: "x"}})

	back := st.connect(p.token)
	barrier(t, back)
	if got := friendEvents(back.Events()); len(got) != 0 {
		t.Fatalf("a push was kept for the player: %v", testclient.Names(got))
	}
	for _, event := range []string{EvFriendRequest, EvFriendAccepted} {
		if v := metricValue(st.metrics.SocketEmitsTotal.WithLabelValues(event)); v != 0 {
			t.Errorf("socket_emits_total{%s} = %v, want 0", event, v)
		}
	}
}
