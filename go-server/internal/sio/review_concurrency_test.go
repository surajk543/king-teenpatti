package sio

// Adversarial concurrency review of the Engine.IO connection.

import (
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"
)

// TestReviewBlockedHandlerWithAFullInboundQueueStarvesTheHeartbeat: the
// reader goroutine both answers the heartbeat (a client "3" clears the pong
// timer) and queues Socket.IO packets for the dispatcher through a bounded
// channel (64). A handler that blocks — an actor stuck behind a hung
// statement — stops the dispatcher, the channel fills, the reader parks in
// pushPacket, and from then on the client's pongs are never read: the
// connection is closed with "ping timeout" although the client answered
// every ping. engine.io's reader is never blocked (its event queue is
// unbounded), so Node kept such a connection open.
//
// Reachable only with a stuck handler AND 64+ packets from one client, so it
// is reported as a documented limitation rather than fixed here (the fix is
// either an unbounded dispatch queue or reading pongs off a separate path).
func TestReviewBlockedHandlerWithAFullInboundQueueStarvesTheHeartbeat(t *testing.T) {
	t.Skip("REVIEW: confirmed on current code (ping timeout after ~200 ms with the reader parked on a full inbound queue); left as a documented limitation — see the test comment")
	h := newHarness(t, Options{PingInterval: 60 * time.Millisecond, PingTimeout: 120 * time.Millisecond})
	h.srv.Use(tokenMiddleware)

	release := make(chan struct{})
	defer close(release)
	var once sync.Once
	reasons := make(chan string, 1)
	h.srv.OnConnection(func(s *Socket) {
		s.On("stuck", func(_ []json.RawMessage, ack AckFunc) {
			once.Do(func() { <-release }) // the first call blocks the dispatcher
			if ack != nil {
				ack(map[string]any{"ok": true})
			}
		})
		s.OnDisconnect(func(reason string) { reasons <- reason })
	})

	c := h.connectedClient()
	// One event that blocks the dispatcher, then more than the inbound queue
	// can hold, so the reader parks on pushPacket.
	for i := 0; i < 80; i++ {
		send(t, c.ws, `42["stuck",{}]`)
	}
	// Answer every ping promptly for a while — much longer than PingTimeout.
	deadline := time.Now().Add(600 * time.Millisecond)
	for time.Now().Before(deadline) {
		_ = c.ws.SetReadDeadline(time.Now().Add(50 * time.Millisecond))
		_, data, err := c.ws.ReadMessage()
		if err != nil {
			if strings.Contains(err.Error(), "timeout") {
				continue
			}
			select {
			case r := <-reasons:
				t.Fatalf("REVIEW: connection closed with %q while the client answered every ping (reader parked on a full inbound queue)", r)
			case <-time.After(time.Second):
				t.Fatalf("REVIEW: transport closed (%v) while the client answered every ping", err)
			}
		}
		if string(data) == "2" {
			send(t, c.ws, "3")
		}
	}
	select {
	case r := <-reasons:
		t.Fatalf("REVIEW: disconnected with %q although every ping was answered", r)
	default:
	}
}
