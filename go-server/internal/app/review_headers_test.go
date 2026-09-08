package app

import (
	"bufio"
	"context"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// Adversarial review — per-connection memory. sio keeps the upgrade
// request's headers for the life of every WebSocket connection
// (Handshake.Headers, as socket.io's handshake.headers does). Node's
// http.Server refuses a header block over 16 KiB (`--max-http-header-size`
// default), so that retention was bounded at 16 KiB per connection; Go's
// http.Server default is 1 MiB — sixty-four times more that a hostile client
// with a free guest token can pin per connection, for as long as it keeps
// the socket open. The Go server must apply Node's ceiling.
func TestReviewOversizedUpgradeHeadersAreRefused(t *testing.T) {
	database := dbtest.Open(t, "app")
	cfg := testConfig(t, publicDir(t))
	a, err := New(Options{Config: cfg, DB: database, Logger: util.NewLogger("error", io.Discard)})
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = a.Start(context.Background()) }()
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		_ = a.Shutdown(ctx)
	})
	deadline := time.Now().Add(5 * time.Second)
	for a.Addr() == "" && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	addr := a.Addr()
	if addr == "" {
		t.Fatal("app did not start")
	}

	status := func(headerBytes int) int {
		t.Helper()
		conn, err := net.DialTimeout("tcp", addr, 2*time.Second)
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
		var b strings.Builder
		b.WriteString("GET /socket.io/?EIO=4&transport=websocket HTTP/1.1\r\n")
		b.WriteString("Host: " + addr + "\r\n")
		b.WriteString("Connection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\n")
		b.WriteString("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n")
		if headerBytes > 0 {
			// Spread over several headers so no single line trips a different limit.
			for i := 0; headerBytes > 0; i++ {
				n := min(headerBytes, 4000)
				b.WriteString("X-Pad-" + string(rune('a'+i%26)) + string(rune('a'+(i/26)%26)) + ": " + strings.Repeat("x", n) + "\r\n")
				headerBytes -= n
			}
		}
		b.WriteString("\r\n")
		if _, err := io.WriteString(conn, b.String()); err != nil {
			t.Fatal(err)
		}
		res, err := http.ReadResponse(bufio.NewReader(conn), nil)
		if err != nil {
			t.Fatalf("no HTTP response: %v", err)
		}
		defer res.Body.Close()
		return res.StatusCode
	}

	// A normal upgrade (well under 16 KiB) is accepted.
	if got := status(0); got != http.StatusSwitchingProtocols {
		t.Fatalf("plain upgrade: %d, want 101", got)
	}
	// 200 KB of headers: Node answered 431 Request Header Fields Too Large.
	if got := status(200_000); got != http.StatusRequestHeaderFieldsTooLarge {
		t.Fatalf("REVIEW: a 200 KB header block was answered %d (want 431); with a free guest token every such connection pins ~200 KB in sio's Handshake.Headers for its lifetime", got)
	}
}
