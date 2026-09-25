package sio

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// countingConn counts the bytes read off the wire, so a test can see what a
// frame cost before gorilla inflated it.
type countingConn struct {
	net.Conn
	read *atomic.Int64
}

func (c countingConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	c.read.Add(int64(n))
	return n, err
}

// dialCounting dials the harness with or without offering permessage-deflate
// and returns the socket, the upgrade response and the wire byte counter.
func (h *harness) dialCounting(offerDeflate bool) (*websocket.Conn, *http.Response, *atomic.Int64) {
	h.t.Helper()
	read := &atomic.Int64{}
	d := websocket.Dialer{
		EnableCompression: offerDeflate,
		NetDialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			conn, err := (&net.Dialer{}).DialContext(ctx, network, addr)
			if err != nil {
				return nil, err
			}
			return countingConn{Conn: conn, read: read}, nil
		},
	}
	ws, resp, err := d.Dial(h.wsURL(""), nil)
	if err != nil {
		h.t.Fatalf("dial: %v", err)
	}
	h.t.Cleanup(func() { _ = ws.Close() })
	return ws, resp, read
}

// connectRaw completes OPEN and CONNECT on an already dialled socket.
func connectRaw(t *testing.T, ws *websocket.Conn) {
	t.Helper()
	if f := readFrame(t, ws, 2*time.Second); !strings.HasPrefix(f, "0{") {
		t.Fatalf("first frame %q, want OPEN", f)
	}
	send(t, ws, `40{"token":"good"}`)
	if f := readFrame(t, ws, 2*time.Second); !strings.HasPrefix(f, `40{"sid":"`) {
		t.Fatalf("CONNECT reply %q", f)
	}
}

// emitAndMeasure has the server emit `payload` as one event and returns the
// frame the client read and the bytes it cost on the wire.
func emitAndMeasure(t *testing.T, s *Socket, ws *websocket.Conn, read *atomic.Int64, payload string) (string, int64) {
	t.Helper()
	before := read.Load()
	if err := s.Emit("room:state", map[string]string{"blob": payload}); err != nil {
		t.Fatal(err)
	}
	frame := readFrame(t, ws, 2*time.Second)
	return frame, read.Load() - before
}

func wantFrame(t *testing.T, frame, payload string) {
	t.Helper()
	want, _ := json.Marshal(map[string]string{"blob": payload})
	if frame != `42["room:state",`+string(want)+`]` {
		t.Fatalf("frame arrived changed: %.80q…", frame)
	}
}

// The table state is JSON repeated per viewer; this stands in for one.
var roomStateLike = strings.Repeat(`{"userId":"8f3c2a","displayName":"Priya","chips":250000,"status":"active","isBlind":true,"lastBet":400,"contributed":1200},`, 40)

func TestCompressionIsNegotiatedAndShrinksLargeFramesOnTheWire(t *testing.T) {
	h := newHarness(t, Options{EnableCompression: true})
	h.srv.Use(tokenMiddleware)
	sockCh := make(chan *Socket, 1)
	h.srv.OnConnection(func(s *Socket) { sockCh <- s })

	ws, resp, read := h.dialCounting(true)
	if ext := resp.Header.Get("Sec-WebSocket-Extensions"); !strings.Contains(ext, "permessage-deflate") {
		t.Fatalf("Sec-WebSocket-Extensions = %q, want permessage-deflate negotiated", ext)
	}
	connectRaw(t, ws)
	s := <-sockCh

	frame, wire := emitAndMeasure(t, s, ws, read, roomStateLike)
	wantFrame(t, frame, roomStateLike)
	if wire*4 > int64(len(frame)) {
		t.Fatalf("a %d-byte frame cost %d bytes on the wire; want it deflated (under a quarter)", len(frame), wire)
	}

	// A frame under CompressMinBytes goes out as it is: deflating a short
	// repetitive string would shrink it, so a wire cost at least its length
	// proves it was not compressed.
	short := strings.Repeat("ab", 50)
	frame, wire = emitAndMeasure(t, s, ws, read, short)
	wantFrame(t, frame, short)
	if wire < int64(len(frame)) {
		t.Fatalf("a %d-byte frame cost %d bytes; frames under %d bytes should not be compressed", len(frame), wire, DefaultCompressMinBytes)
	}
}

func TestCompressionIsOffUnlessEnabled(t *testing.T) {
	h := newHarness(t, Options{})
	h.srv.Use(tokenMiddleware)
	sockCh := make(chan *Socket, 1)
	h.srv.OnConnection(func(s *Socket) { sockCh <- s })

	ws, resp, read := h.dialCounting(true)
	if ext := resp.Header.Get("Sec-WebSocket-Extensions"); ext != "" {
		t.Fatalf("Sec-WebSocket-Extensions = %q with compression off, want none", ext)
	}
	connectRaw(t, ws)
	frame, wire := emitAndMeasure(t, <-sockCh, ws, read, roomStateLike)
	wantFrame(t, frame, roomStateLike)
	if wire < int64(len(frame)) {
		t.Fatalf("a %d-byte frame cost %d bytes with compression off", len(frame), wire)
	}
}

func TestAClientThatOffersNoDeflateStillGetsPlainFrames(t *testing.T) {
	h := newHarness(t, Options{EnableCompression: true})
	h.srv.Use(tokenMiddleware)
	sockCh := make(chan *Socket, 1)
	h.srv.OnConnection(func(s *Socket) { sockCh <- s })

	ws, resp, read := h.dialCounting(false)
	if ext := resp.Header.Get("Sec-WebSocket-Extensions"); ext != "" {
		t.Fatalf("Sec-WebSocket-Extensions = %q for a client that offered none", ext)
	}
	connectRaw(t, ws)
	frame, wire := emitAndMeasure(t, <-sockCh, ws, read, roomStateLike)
	wantFrame(t, frame, roomStateLike)
	if wire < int64(len(frame)) {
		t.Fatalf("a %d-byte frame cost %d bytes to a client without deflate", len(frame), wire)
	}
}

func TestOffersDeflateReadsTheExtensionHeader(t *testing.T) {
	for _, tc := range []struct {
		header []string
		want   bool
	}{
		{nil, false},
		{[]string{"permessage-deflate"}, true},
		{[]string{"permessage-deflate; client_max_window_bits"}, true}, // browsers, dart:io
		{[]string{"x-webkit-deflate-frame", "permessage-deflate; server_no_context_takeover"}, true},
		{[]string{"x-webkit-deflate-frame, PerMessage-Deflate"}, true},
		{[]string{"x-webkit-deflate-frame"}, false},
	} {
		r := &http.Request{Header: http.Header{}}
		for _, v := range tc.header {
			r.Header.Add("Sec-WebSocket-Extensions", v)
		}
		if got := offersDeflate(r); got != tc.want {
			t.Errorf("offersDeflate(%q) = %v, want %v", tc.header, got, tc.want)
		}
	}
}
