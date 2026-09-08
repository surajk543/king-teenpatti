package sio

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// ---- harness ----

type harness struct {
	t   *testing.T
	srv *Server
	ts  *httptest.Server
}

func newHarness(t *testing.T, opts Options) *harness {
	t.Helper()
	if opts.Logger == nil {
		opts.Logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	srv := NewServer(opts)
	mux := http.NewServeMux()
	mux.Handle("/socket.io/", srv)
	ts := httptest.NewServer(mux)
	h := &harness{t: t, srv: srv, ts: ts}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := srv.Shutdown(ctx); err != nil {
			t.Errorf("Shutdown: %v", err)
		}
		ts.Close()
	})
	return h
}

func (h *harness) wsURL(query string) string {
	if query == "" {
		query = "EIO=4&transport=websocket"
	}
	return "ws" + strings.TrimPrefix(h.ts.URL, "http") + "/socket.io/?" + query
}

// dial opens a raw WebSocket to the Engine.IO endpoint.
func (h *harness) dial() *websocket.Conn {
	h.t.Helper()
	ws, _, err := websocket.DefaultDialer.Dial(h.wsURL(""), nil)
	if err != nil {
		h.t.Fatalf("dial: %v", err)
	}
	h.t.Cleanup(func() { _ = ws.Close() })
	return ws
}

// client is a raw client that has completed OPEN (and optionally CONNECT).
type client struct {
	t  *testing.T
	ws *websocket.Conn
	// open is the parsed OPEN packet.
	open OpenPacket
	// sid is the namespace socket id from the CONNECT ack.
	sid string
}

func readFrame(t *testing.T, ws *websocket.Conn, timeout time.Duration) string {
	t.Helper()
	_ = ws.SetReadDeadline(time.Now().Add(timeout))
	mt, data, err := ws.ReadMessage()
	if err != nil {
		t.Fatalf("read frame: %v", err)
	}
	if mt != websocket.TextMessage {
		t.Fatalf("read frame: message type %d, want text", mt)
	}
	return string(data)
}

// readUntil reads frames, skipping heartbeat pings, until one satisfies
// pred. It answers pings with pongs so long tests keep their session alive.
func readUntil(t *testing.T, ws *websocket.Conn, timeout time.Duration, pred func(string) bool) string {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		f := readFrame(t, ws, time.Until(deadline))
		if f == "2" {
			_ = ws.WriteMessage(websocket.TextMessage, []byte("3"))
			continue
		}
		if pred(f) {
			return f
		}
	}
	t.Fatalf("no frame matched within %s", timeout)
	return ""
}

func send(t *testing.T, ws *websocket.Conn, frame string) {
	t.Helper()
	if err := ws.WriteMessage(websocket.TextMessage, []byte(frame)); err != nil {
		t.Fatalf("send %q: %v", frame, err)
	}
}

// expectClosed waits for the server to close the WebSocket.
func expectClosed(t *testing.T, ws *websocket.Conn, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		_ = ws.SetReadDeadline(deadline)
		_, data, err := ws.ReadMessage()
		if err != nil {
			var ne interface{ Timeout() bool }
			if errors.As(err, &ne) && ne.Timeout() {
				t.Fatalf("socket still open after %s", timeout)
			}
			return
		}
		if string(data) == "2" {
			continue
		}
	}
}

// openClient dials and consumes the OPEN frame.
func (h *harness) openClient() *client {
	h.t.Helper()
	ws := h.dial()
	first := readFrame(h.t, ws, 2*time.Second)
	if !strings.HasPrefix(first, "0{") {
		h.t.Fatalf("first frame %q, want OPEN", first)
	}
	var open OpenPacket
	if err := json.Unmarshal([]byte(first[1:]), &open); err != nil {
		h.t.Fatalf("OPEN json: %v", err)
	}
	return &client{t: h.t, ws: ws, open: open}
}

// connect sends CONNECT with the auth object and consumes the "40{sid}" ack.
func (c *client) connect(auth string) {
	c.t.Helper()
	send(c.t, c.ws, "40"+auth)
	f := readFrame(c.t, c.ws, 2*time.Second)
	if !strings.HasPrefix(f, `40{"sid":"`) {
		c.t.Fatalf("CONNECT reply %q, want 40{\"sid\":…}", f)
	}
	var ack ConnectAck
	if err := json.Unmarshal([]byte(f[2:]), &ack); err != nil {
		c.t.Fatalf("connect ack json: %v", err)
	}
	c.sid = ack.SID
}

// connectedClient is openClient + connect with a token the test middleware
// accepts.
func (h *harness) connectedClient() *client {
	c := h.openClient()
	c.connect(`{"token":"good"}`)
	return c
}

// tokenMiddleware refuses tokens other than "good" with the code as message,
// exactly like the game's io.use.
func tokenMiddleware(s *Socket) error {
	raw, ok := s.Handshake().Auth["token"]
	if !ok {
		return errors.New("missing_token")
	}
	var tok string
	_ = json.Unmarshal(raw, &tok)
	if tok != "good" {
		return errors.New("invalid_session")
	}
	s.SetData(tok)
	return nil
}

// waitFor polls until cond holds.
func waitFor(t *testing.T, timeout time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("condition not met within %s", timeout)
}

// ---- handshake ----

func TestHandshakeOpenPacketIsNodeExact(t *testing.T) {
	h := newHarness(t, Options{})
	ws := h.dial()
	first := readFrame(t, ws, 2*time.Second)
	// Exact key order and values of engine.io's OPEN (spec §14.3).
	re := regexp.MustCompile(`^0\{"sid":"([A-Za-z0-9_-]{20})","upgrades":\[\],"pingInterval":20000,"pingTimeout":25000,"maxPayload":100000\}$`)
	if !re.MatchString(first) {
		t.Fatalf("OPEN frame %q does not match engine.io's shape", first)
	}
	if h.srv.ClientsCount() != 1 {
		t.Fatalf("ClientsCount %d, want 1", h.srv.ClientsCount())
	}
}

func TestHandshakeRefusalsAreEngineIOErrorBodies(t *testing.T) {
	h := newHarness(t, Options{})
	get := func(path string, upgrade bool) (int, string, string) {
		req, _ := http.NewRequest(http.MethodGet, h.ts.URL+path, nil)
		if upgrade {
			req.Header.Set("Connection", "Upgrade")
			req.Header.Set("Upgrade", "websocket")
			req.Header.Set("Sec-WebSocket-Version", "13")
			req.Header.Set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, resp.Header.Get("Content-Type"), string(body)
	}
	cases := []struct {
		name    string
		path    string
		upgrade bool
		body    string
	}{
		{"polling", "/socket.io/?EIO=4&transport=polling&t=abc", false, `{"code":0,"message":"Transport unknown"}`},
		{"no transport", "/socket.io/?EIO=4", false, `{"code":0,"message":"Transport unknown"}`},
		{"sid", "/socket.io/?EIO=4&transport=websocket&sid=abc", true, `{"code":1,"message":"Session ID unknown"}`},
		{"websocket without upgrade", "/socket.io/?EIO=4&transport=websocket", false, `{"code":3,"message":"Bad request"}`},
		{"EIO 3", "/socket.io/?EIO=3&transport=websocket", true, `{"code":5,"message":"Unsupported protocol version"}`},
		{"EIO missing", "/socket.io/?transport=websocket", true, `{"code":5,"message":"Unsupported protocol version"}`},
	}
	for _, tc := range cases {
		status, ctype, body := get(tc.path, tc.upgrade)
		if status != http.StatusBadRequest || body != tc.body || !strings.HasPrefix(ctype, "application/json") {
			t.Errorf("%s: got %d %s %q, want 400 application/json %s", tc.name, status, ctype, body, tc.body)
		}
	}
	// POST is "Bad handshake method".
	resp, err := http.Post(h.ts.URL+"/socket.io/?EIO=4&transport=websocket", "text/plain", nil)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 400 || string(body) != `{"code":2,"message":"Bad handshake method"}` {
		t.Errorf("POST: got %d %s", resp.StatusCode, body)
	}
	// gorilla's Dial surfaces the refusal as ErrBadHandshake.
	_, resp, err = websocket.DefaultDialer.Dial(h.wsURL("EIO=3&transport=websocket"), nil)
	if !errors.Is(err, websocket.ErrBadHandshake) || resp == nil || resp.StatusCode != 400 {
		t.Errorf("EIO=3 dial: err=%v resp=%v", err, resp)
	}
	if h.srv.ClientsCount() != 0 {
		t.Fatalf("refused handshakes must not count: %d", h.srv.ClientsCount())
	}
}

func TestCheckOriginRefusesWith403(t *testing.T) {
	h := newHarness(t, Options{CheckOrigin: func(r *http.Request) bool {
		return r.Header.Get("Origin") == "https://allowed.example"
	}})
	hdr := http.Header{"Origin": []string{"https://evil.example"}}
	_, resp, err := websocket.DefaultDialer.Dial(h.wsURL(""), hdr)
	if !errors.Is(err, websocket.ErrBadHandshake) || resp == nil || resp.StatusCode != http.StatusForbidden {
		t.Fatalf("want 403, got err=%v resp=%v", err, resp)
	}
	ws, _, err := websocket.DefaultDialer.Dial(h.wsURL(""), http.Header{"Origin": []string{"https://allowed.example"}})
	if err != nil {
		t.Fatal(err)
	}
	ws.Close()
}

// ---- CONNECT / auth ----

func TestConnectRunsMiddlewareAndAcksWithSid(t *testing.T) {
	h := newHarness(t, Options{})
	var seen Handshake
	h.srv.Use(func(s *Socket) error {
		seen = s.Handshake()
		return tokenMiddleware(s)
	})
	var connected atomic.Int32
	h.srv.OnConnection(func(s *Socket) {
		connected.Add(1)
		if s.Data() != "good" {
			t.Errorf("Data() = %v, want token stored by middleware", s.Data())
		}
		_ = s.Emit("session:ready", map[string]any{"user": map[string]any{"id": "u1"}})
	})
	c := h.openClient()
	c.connect(`{"token":"good"}`)
	// socket.io 4: the namespace socket id is a fresh base64id, never the
	// Engine.IO sid ("sensitive information").
	if c.sid == c.open.SID || !regexp.MustCompile(`^[A-Za-z0-9_-]{20}$`).MatchString(c.sid) {
		t.Errorf("socket id %q must be a fresh 20-char id distinct from the engine sid %q", c.sid, c.open.SID)
	}
	if f := readFrame(t, c.ws, 2*time.Second); f != `42["session:ready",{"user":{"id":"u1"}}]` {
		t.Fatalf("session:ready frame %q", f)
	}
	if got := string(seen.Auth["token"]); got != `"good"` {
		t.Errorf("handshake auth token %s", got)
	}
	if seen.Query.Get("EIO") != "4" || seen.Query.Get("transport") != "websocket" {
		t.Errorf("handshake query %v", seen.Query)
	}
	if seen.Address != "127.0.0.1" {
		t.Errorf("handshake address %q", seen.Address)
	}
	if seen.Headers.Get("Upgrade") != "websocket" {
		t.Errorf("handshake headers %v", seen.Headers)
	}
	if seen.Time.IsZero() {
		t.Error("handshake time unset")
	}
	if connected.Load() != 1 {
		t.Errorf("OnConnection ran %d times", connected.Load())
	}
}

func TestConnectWithoutAuthObjectHasNilAuth(t *testing.T) {
	h := newHarness(t, Options{})
	var auth map[string]json.RawMessage
	var hadKey bool
	h.srv.Use(func(s *Socket) error {
		auth = s.Handshake().Auth
		_, hadKey = auth["token"]
		return nil
	})
	c := h.openClient()
	c.connect("")
	if auth != nil || hadKey {
		t.Errorf("bare 40 should give nil Auth, got %v", auth)
	}
}

func TestAuthRejectionIsConnectErrorWithCodeAsMessage(t *testing.T) {
	h := newHarness(t, Options{})
	h.srv.Use(tokenMiddleware)
	var connections atomic.Int32
	h.srv.OnConnection(func(*Socket) { connections.Add(1) })

	c := h.openClient()
	send(t, c.ws, `40{"token":"stale"}`)
	if f := readFrame(t, c.ws, 2*time.Second); f != `44{"message":"invalid_session"}` {
		t.Fatalf("got %q, want 44{\"message\":\"invalid_session\"}", f)
	}
	send(t, c.ws, `40`)
	if f := readFrame(t, c.ws, 2*time.Second); f != `44{"message":"missing_token"}` {
		t.Fatalf("got %q, want 44{\"message\":\"missing_token\"}", f)
	}
	if connections.Load() != 0 {
		t.Fatal("OnConnection must not run for a refused CONNECT")
	}
	// As in Node the transport stays open: the client may CONNECT again.
	c.connect(`{"token":"good"}`)
	if connections.Load() != 1 {
		t.Fatalf("OnConnection ran %d times after the retry", connections.Load())
	}
}

func TestConnectToOtherNamespaceIsInvalidNamespace(t *testing.T) {
	h := newHarness(t, Options{})
	c := h.openClient()
	send(t, c.ws, `40/admin,{"token":"good"}`)
	if f := readFrame(t, c.ws, 2*time.Second); f != `44/admin,{"message":"Invalid namespace"}` {
		t.Fatalf("got %q", f)
	}
	// The default namespace is still available on the same connection.
	c.connect(`{"token":"good"}`)
}

// ---- events / acks / emits ----

func TestEventWithAndWithoutAck(t *testing.T) {
	h := newHarness(t, Options{})
	type got struct {
		args []string
		ack  bool
	}
	calls := make(chan got, 8)
	h.srv.OnConnection(func(s *Socket) {
		s.On("room:quickJoin", func(args []json.RawMessage, ack AckFunc) {
			var as []string
			for _, a := range args {
				as = append(as, string(a))
			}
			calls <- got{as, ack != nil}
			if ack != nil {
				ack(struct {
					OK     bool   `json:"ok"`
					RoomID string `json:"roomId"`
					Code   string `json:"code"`
				}{true, "r1", "ABC234"})
				ack("ignored second call")
			}
		})
		s.On("room:leave", func(args []json.RawMessage, ack AckFunc) {
			calls <- got{nil, ack != nil}
			ack() // ack with no payload
		})
	})
	c := h.connectedClient()

	send(t, c.ws, `42["room:quickJoin",{"bootAmount":100}]`)
	g := <-calls
	if g.ack || len(g.args) != 1 || g.args[0] != `{"bootAmount":100}` {
		t.Fatalf("no-ack event: %+v", g)
	}

	send(t, c.ws, `421["room:quickJoin",{"bootAmount":100,"category":"blind"}]`)
	g = <-calls
	if !g.ack || g.args[0] != `{"bootAmount":100,"category":"blind"}` {
		t.Fatalf("ack event: %+v", g)
	}
	if f := readFrame(t, c.ws, 2*time.Second); f != `431[{"ok":true,"roomId":"r1","code":"ABC234"}]` {
		t.Fatalf("ack frame %q", f)
	}

	send(t, c.ws, `422["room:leave"]`)
	g = <-calls
	if !g.ack {
		t.Fatalf("payload-less event: %+v", g)
	}
	if f := readFrame(t, c.ws, 2*time.Second); f != `432[]` {
		t.Fatalf("empty ack frame %q", f)
	}
	// socket.io-client ack ids start at 0.
	send(t, c.ws, `420["room:quickJoin",{}]`)
	<-calls
	if f := readFrame(t, c.ws, 2*time.Second); !strings.HasPrefix(f, `430[`) {
		t.Fatalf("ack id 0 frame %q", f)
	}
}

func TestUnknownEventIsNeverAcked(t *testing.T) {
	h := newHarness(t, Options{})
	h.srv.OnConnection(func(s *Socket) {
		s.On("known", func(_ []json.RawMessage, ack AckFunc) { ack("k") })
	})
	c := h.connectedClient()
	send(t, c.ws, `425["nobody:listens",{}]`)
	send(t, c.ws, `426["known"]`)
	// The only reply is the ack for the known event — the unknown one hangs.
	if f := readFrame(t, c.ws, 2*time.Second); f != `436["k"]` {
		t.Fatalf("got %q, want only the known ack", f)
	}
}

func TestServerEmitFramesAndOrdering(t *testing.T) {
	h := newHarness(t, Options{})
	sockCh := make(chan *Socket, 1)
	h.srv.OnConnection(func(s *Socket) { sockCh <- s })
	c := h.connectedClient()
	s := <-sockCh

	type payload struct {
		Text string  `json:"text"`
		N    *int64  `json:"n"`
		Null *string `json:"null"`
	}
	if err := s.Emit("chat:message", payload{Text: `gg [nice] {hand} "wp" <b>&`}); err != nil {
		t.Fatal(err)
	}
	if f := readFrame(t, c.ws, 2*time.Second); f != `42["chat:message",{"text":"gg [nice] {hand} \"wp\" <b>&","n":null,"null":null}]` {
		t.Fatalf("emit frame %q", f)
	}
	if err := s.Emit("room:left"); err != nil {
		t.Fatal(err)
	}
	if f := readFrame(t, c.ws, 2*time.Second); f != `42["room:left"]` {
		t.Fatalf("payload-less emit %q", f)
	}
	// Unicode goes raw (UTF-8), as JSON.stringify does.
	_ = s.Emit("x", map[string]string{"name": "Raj \"The Ace\" éü ♠"})
	if f := readFrame(t, c.ws, 2*time.Second); f != `42["x",{"name":"Raj \"The Ace\" éü ♠"}]` {
		t.Fatalf("unicode emit %q", f)
	}
	// Emits from many goroutines all arrive, and emits issued from one
	// goroutine keep their order.
	var wg sync.WaitGroup
	for g := 0; g < 4; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < 25; i++ {
				_ = s.Emit("seq", map[string]int{"g": g, "i": i})
			}
		}(g)
	}
	wg.Wait()
	last := map[int]int{0: -1, 1: -1, 2: -1, 3: -1}
	for n := 0; n < 100; n++ {
		f := readUntil(t, c.ws, 2*time.Second, func(f string) bool { return strings.HasPrefix(f, `42["seq",`) })
		var env []json.RawMessage
		_ = json.Unmarshal([]byte(f[2:]), &env)
		var p struct{ G, I int }
		_ = json.Unmarshal(env[1], &p)
		if p.I != last[p.G]+1 {
			t.Fatalf("goroutine %d: got i=%d after %d", p.G, p.I, last[p.G])
		}
		last[p.G] = p.I
	}
}

// expectNothingThenMarker proves that no frame was queued for the socket
// before now: it emits a marker straight to the socket and requires the very
// next frame to be that marker. Frames on one connection are written in
// order, so anything queued earlier would arrive first. (A read with a short
// deadline cannot be used for this — gorilla makes a read error permanent,
// so a timed-out probe poisons every later read on that connection.)
func expectNothingThenMarker(t *testing.T, s *Socket, ws *websocket.Conn) {
	t.Helper()
	if err := s.Emit("marker"); err != nil {
		t.Fatalf("marker emit: %v", err)
	}
	if f := readFrame(t, ws, 2*time.Second); f != `42["marker"]` {
		t.Fatalf("got %q before the marker — a frame that should not have been sent", f)
	}
}

func TestRoomBroadcast(t *testing.T) {
	h := newHarness(t, Options{})
	sockets := make(chan *Socket, 3)
	h.srv.OnConnection(func(s *Socket) { sockets <- s })
	a := h.connectedClient()
	sa := <-sockets
	b := h.connectedClient()
	sb := <-sockets
	cc := h.connectedClient()
	sc := <-sockets

	sa.Join("table-1")
	sb.Join("table-1")
	sb.Join("table-2") // in two rooms: still gets the event once
	sc.Join("table-2")

	h.srv.To("table-1").Emit("room:state", map[string]any{"roomId": "table-1"})
	for _, ws := range []*websocket.Conn{a.ws, b.ws} {
		if f := readFrame(t, ws, 2*time.Second); f != `42["room:state",{"roomId":"table-1"}]` {
			t.Fatalf("member frame %q", f)
		}
	}
	// c is not in table-1: nothing arrived.
	expectNothingThenMarker(t, sc, cc.ws)

	// Broadcast to both rooms: b (in both) receives it exactly once.
	(&Broadcast{s: h.srv, rooms: []string{"table-1", "table-2"}}).Emit("both", 1)
	for _, ws := range []*websocket.Conn{a.ws, b.ws, cc.ws} {
		if f := readFrame(t, ws, 2*time.Second); f != `42["both",1]` {
			t.Fatalf("both-rooms frame %q", f)
		}
	}
	expectNothingThenMarker(t, sb, b.ws) // no duplicate for the member of two rooms

	// Leave removes membership; Rooms lists own id + rooms.
	sb.Leave("table-1")
	rooms := sb.Rooms()
	if len(rooms) != 2 || (rooms[0] != sb.ID() && rooms[1] != sb.ID()) || (rooms[0] != "table-2" && rooms[1] != "table-2") {
		t.Fatalf("rooms after leave %v", rooms)
	}
	h.srv.To("table-1").Emit("only-a")
	if f := readFrame(t, a.ws, 2*time.Second); f != `42["only-a"]` {
		t.Fatalf("frame %q", f)
	}
	expectNothingThenMarker(t, sb, b.ws) // the socket that left gets nothing
	// Leaving a room the socket is not in is harmless; so is an empty room.
	sb.Leave("never-joined")
	h.srv.To("nobody").Emit("x")

	// The server-side index agrees with the sockets' own view.
	h.srv.mu.RLock()
	t1, t2 := len(h.srv.rooms["table-1"]), len(h.srv.rooms["table-2"])
	h.srv.mu.RUnlock()
	if t1 != 1 || t2 != 2 {
		t.Fatalf("room index table-1=%d table-2=%d, want 1 and 2", t1, t2)
	}
}

// A Join racing the socket's disconnect must never leave a dead member in
// the server's room index (Join used to update the socket's set under its
// lock but the server index after releasing it).
func TestJoinRacingDisconnectLeavesNoDeadMembers(t *testing.T) {
	h := newHarness(t, Options{})
	sockets := make(chan *Socket, 1)
	h.srv.OnConnection(func(s *Socket) { sockets <- s })
	for i := 0; i < 150; i++ {
		c := h.connectedClient()
		s := <-sockets
		gone := make(chan struct{})
		s.OnDisconnect(func(string) { close(gone) })
		var wg sync.WaitGroup
		for g := 0; g < 4; g++ {
			wg.Add(1)
			go func(g int) {
				defer wg.Done()
				for j := 0; j < 300; j++ {
					s.Join(fmt.Sprintf("r%d-%d-%d", i, g, j%5))
					if g == 0 && j == 10 {
						send(t, c.ws, "41")
					}
				}
			}(g)
		}
		<-gone
		wg.Wait()
		h.srv.mu.RLock()
		leaked := len(h.srv.rooms)
		h.srv.mu.RUnlock()
		if leaked != 0 {
			t.Fatalf("iteration %d: %d rooms still hold the disconnected socket", i, leaked)
		}
		if len(s.Rooms()) != 0 {
			t.Fatalf("iteration %d: socket still lists rooms %v", i, s.Rooms())
		}
		_ = c.ws.Close()
	}
}

// ---- disconnects ----

func TestClientDisconnectPacket(t *testing.T) {
	h := newHarness(t, Options{})
	reasons := make(chan string, 4)
	var connections atomic.Int32
	h.srv.OnConnection(func(s *Socket) {
		connections.Add(1)
		s.Join("t")
		s.OnDisconnect(func(reason string) {
			if len(s.Rooms()) != 0 {
				t.Errorf("rooms not left before disconnect callback: %v", s.Rooms())
			}
			if s.Connected() {
				t.Error("Connected() true inside disconnect callback")
			}
			reasons <- reason
		})
	})
	c := h.connectedClient()
	send(t, c.ws, "41")
	select {
	case r := <-reasons:
		if r != ReasonClientNamespaceDisc {
			t.Fatalf("reason %q", r)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("disconnect callback did not run")
	}
	waitFor(t, time.Second, func() bool {
		h.srv.mu.RLock()
		defer h.srv.mu.RUnlock()
		return len(h.srv.sockets) == 0 && len(h.srv.rooms) == 0
	})
	// The transport is still open (Node keeps the engine connection); a
	// fresh CONNECT builds a new socket with a fresh id.
	if h.srv.ClientsCount() != 1 {
		t.Fatalf("ClientsCount %d, want 1 (transport kept)", h.srv.ClientsCount())
	}
	first := c.sid
	c.connect(`{"token":"good"}`)
	if c.sid == first {
		t.Fatalf("re-CONNECT reused socket id %q", c.sid)
	}
	if connections.Load() != 2 {
		t.Fatalf("OnConnection ran %d times", connections.Load())
	}
}

func TestClientTransportClose(t *testing.T) {
	h := newHarness(t, Options{})
	reasons := make(chan string, 1)
	h.srv.OnConnection(func(s *Socket) {
		s.OnDisconnect(func(reason string) { reasons <- reason })
	})
	c := h.connectedClient()
	_ = c.ws.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""), time.Now().Add(time.Second))
	_ = c.ws.Close()
	select {
	case r := <-reasons:
		if r != ReasonTransportClose {
			t.Fatalf("reason %q", r)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("disconnect callback did not run")
	}
	waitFor(t, time.Second, func() bool { return h.srv.ClientsCount() == 0 })

	// A TCP drop without a close frame is also "transport close".
	c2 := h.connectedClient()
	_ = c2.ws.UnderlyingConn().Close()
	select {
	case r := <-reasons:
		if r != ReasonTransportClose {
			t.Fatalf("reason %q", r)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("disconnect callback did not run")
	}
}

func TestDisconnectPacketBeforeTransportCloseKeepsItsReason(t *testing.T) {
	h := newHarness(t, Options{})
	reasons := make(chan string, 1)
	h.srv.OnConnection(func(s *Socket) {
		s.OnDisconnect(func(reason string) { reasons <- reason })
	})
	c := h.connectedClient()
	// socket.io-client's disconnect(): "41" immediately followed by the close.
	send(t, c.ws, "41")
	_ = c.ws.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""), time.Now().Add(time.Second))
	_ = c.ws.Close()
	select {
	case r := <-reasons:
		if r != ReasonClientNamespaceDisc {
			t.Fatalf("reason %q, want the DISCONNECT packet to win over the close", r)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("disconnect callback did not run")
	}
}

// A client that leaves cleanly sends "41" and then a close frame. If a
// broadcast is racing that departure, the writer's failure (gorilla refuses
// writes once a close frame has been answered) must not turn the reason into
// "transport error", and the queued "41" must still be dispatched — Node
// reports "client namespace disconnect" here.
func TestWriteFailureAfterPeerCloseKeepsTheReadersReason(t *testing.T) {
	h := newHarness(t, Options{})
	release := make(chan struct{})
	var releaseOnce sync.Once
	releaseHandler := func() { releaseOnce.Do(func() { close(release) }) }
	t.Cleanup(releaseHandler) // a failed assertion must not leave the handler stuck
	entered := make(chan struct{}, 1)
	reasons := make(chan string, 1)
	sockCh := make(chan *Socket, 1)
	h.srv.OnConnection(func(s *Socket) {
		s.On("slow", func(_ []json.RawMessage, _ AckFunc) {
			entered <- struct{}{}
			<-release
		})
		s.OnDisconnect(func(r string) { reasons <- r })
		sockCh <- s
	})
	c := h.connectedClient()
	s := <-sockCh
	send(t, c.ws, `42["slow"]`)
	<-entered
	// Both frames are read while the handler still occupies the dispatcher.
	send(t, c.ws, "41")
	_ = c.ws.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""), time.Now().Add(time.Second))
	waitFor(t, 2*time.Second, func() bool { return s.c.readDone.Load() })
	// The racing broadcast: queued fine, fails on the wire.
	for i := 0; i < 3; i++ {
		_ = s.Emit("room:state", map[string]int{"i": i})
	}
	time.Sleep(50 * time.Millisecond)
	if s.c.isClosed() {
		t.Fatalf("the failed write closed the connection with %q before the dispatcher saw the 41", s.c.reason)
	}
	releaseHandler()
	select {
	case r := <-reasons:
		if r != ReasonClientNamespaceDisc {
			t.Fatalf("reason %q, want %q", r, ReasonClientNamespaceDisc)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("disconnect callback did not run")
	}
	waitFor(t, 2*time.Second, func() bool { return h.srv.ClientsCount() == 0 })
}

func TestServerDisconnectIsSynchronousAndSends41(t *testing.T) {
	h := newHarness(t, Options{})
	sockCh := make(chan *Socket, 1)
	var order []string
	var mu sync.Mutex
	h.srv.OnConnection(func(s *Socket) {
		s.OnDisconnect(func(reason string) {
			mu.Lock()
			order = append(order, "callback:"+reason)
			mu.Unlock()
		})
		sockCh <- s
	})
	c := h.connectedClient()
	s := <-sockCh
	_ = s.Emit("session:replaced", map[string]string{"message": "Signed in from another device"})
	s.Disconnect(true)
	mu.Lock()
	order = append(order, "returned")
	mu.Unlock()
	if s.Connected() {
		t.Fatal("Connected() after Disconnect")
	}
	if err := s.Emit("x"); !errors.Is(err, ErrSocketClosed) {
		t.Fatalf("Emit after Disconnect: %v", err)
	}
	mu.Lock()
	got := strings.Join(order, ",")
	mu.Unlock()
	if got != "callback:server namespace disconnect,returned" {
		t.Fatalf("Disconnect must run the callbacks before returning; got %s", got)
	}
	// Wire: the queued emit, then "41", then the close.
	if f := readFrame(t, c.ws, 2*time.Second); f != `42["session:replaced",{"message":"Signed in from another device"}]` {
		t.Fatalf("frame %q", f)
	}
	if f := readFrame(t, c.ws, 2*time.Second); f != "41" {
		t.Fatalf("frame %q, want 41", f)
	}
	expectClosed(t, c.ws, 2*time.Second)
	waitFor(t, time.Second, func() bool { return h.srv.ClientsCount() == 0 })
	// Idempotent.
	s.Disconnect(true)
	s.Disconnect(false)
}

func TestServerDisconnectWithoutCloseKeepsTransport(t *testing.T) {
	h := newHarness(t, Options{})
	sockCh := make(chan *Socket, 2)
	reasons := make(chan string, 2)
	h.srv.OnConnection(func(s *Socket) {
		s.OnDisconnect(func(reason string) { reasons <- reason })
		sockCh <- s
	})
	c := h.connectedClient()
	s := <-sockCh
	s.Disconnect(false)
	if f := readFrame(t, c.ws, 2*time.Second); f != "41" {
		t.Fatalf("frame %q, want 41", f)
	}
	if r := <-reasons; r != ReasonServerNamespaceDisc {
		t.Fatalf("reason %q", r)
	}
	if h.srv.ClientsCount() != 1 {
		t.Fatalf("transport should stay open, ClientsCount %d", h.srv.ClientsCount())
	}
	// An event now, with no namespace socket, is an "invalid state" → the
	// server closes the transport ("forced server close", nobody observes it).
	send(t, c.ws, `42["room:leave",{}]`)
	expectClosed(t, c.ws, 2*time.Second)
	waitFor(t, time.Second, func() bool { return h.srv.ClientsCount() == 0 })
	if len(reasons) != 0 {
		t.Fatal("a second disconnect callback ran")
	}
}

// ---- heartbeat ----

func TestPingTimeoutClosesTheSocket(t *testing.T) {
	h := newHarness(t, Options{PingInterval: 60 * time.Millisecond, PingTimeout: 80 * time.Millisecond})
	reasons := make(chan string, 1)
	h.srv.OnConnection(func(s *Socket) {
		s.OnDisconnect(func(reason string) { reasons <- reason })
	})
	c := h.openClient()
	if c.open.PingInterval != 60 || c.open.PingTimeout != 80 {
		t.Fatalf("advertised heartbeat %d/%d", c.open.PingInterval, c.open.PingTimeout)
	}
	c.connect(`{"token":"good"}`)
	start := time.Now()
	if f := readFrame(t, c.ws, time.Second); f != "2" {
		t.Fatalf("frame %q, want PING", f)
	}
	if since := time.Since(start); since < 40*time.Millisecond {
		t.Fatalf("PING arrived after %s, before the interval", since)
	}
	// No PONG: the server gives up after PingTimeout.
	select {
	case r := <-reasons:
		if r != ReasonPingTimeout {
			t.Fatalf("reason %q", r)
		}
		if since := time.Since(start); since < 100*time.Millisecond || since > 1500*time.Millisecond {
			t.Fatalf("ping timeout fired after %s", since)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no ping timeout")
	}
	expectClosed(t, c.ws, 2*time.Second)
}

func TestPongKeepsTheSocketAlive(t *testing.T) {
	h := newHarness(t, Options{PingInterval: 40 * time.Millisecond, PingTimeout: 60 * time.Millisecond})
	reasons := make(chan string, 1)
	h.srv.OnConnection(func(s *Socket) {
		s.OnDisconnect(func(reason string) { reasons <- reason })
	})
	c := h.connectedClient()
	pings := 0
	deadline := time.Now().Add(400 * time.Millisecond)
	for time.Now().Before(deadline) {
		_ = c.ws.SetReadDeadline(deadline)
		_, data, err := c.ws.ReadMessage()
		if err != nil {
			break
		}
		if string(data) == "2" {
			pings++
			send(t, c.ws, "3")
		}
	}
	if pings < 4 {
		t.Fatalf("only %d pings in 400ms at a 40ms interval", pings)
	}
	select {
	case r := <-reasons:
		t.Fatalf("socket disconnected (%s) although every ping was answered", r)
	default:
	}
}

func TestClientPingIsATransportError(t *testing.T) {
	h := newHarness(t, Options{})
	reasons := make(chan string, 1)
	h.srv.OnConnection(func(s *Socket) {
		s.OnDisconnect(func(reason string) { reasons <- reason })
	})
	c := h.connectedClient()
	send(t, c.ws, "2") // engine.io v4: "invalid heartbeat direction"
	if r := <-reasons; r != ReasonTransportError {
		t.Fatalf("reason %q", r)
	}
	expectClosed(t, c.ws, 2*time.Second)
}

func TestIgnoredEnginePacketsDoNotDisconnect(t *testing.T) {
	h := newHarness(t, Options{})
	h.srv.OnConnection(func(s *Socket) {
		s.On("echo", func(_ []json.RawMessage, ack AckFunc) { ack("ok") })
	})
	c := h.connectedClient()
	for _, f := range []string{"0", "1", "5", "6"} {
		send(t, c.ws, f)
	}
	send(t, c.ws, `429["echo"]`)
	if f := readFrame(t, c.ws, 2*time.Second); f != `439["ok"]` {
		t.Fatalf("frame %q", f)
	}
}

// ---- protocol violations ----

func TestOversizedFrameIsATransportError(t *testing.T) {
	h := newHarness(t, Options{MaxPayload: 1024})
	reasons := make(chan string, 1)
	h.srv.OnConnection(func(s *Socket) {
		s.OnDisconnect(func(reason string) { reasons <- reason })
	})
	c := h.openClient()
	if c.open.MaxPayload != 1024 {
		t.Fatalf("advertised maxPayload %d", c.open.MaxPayload)
	}
	c.connect(`{"token":"good"}`)
	big := `42["chat:message",{"text":"` + strings.Repeat("x", 2000) + `"}]`
	_ = c.ws.WriteMessage(websocket.TextMessage, []byte(big))
	if r := <-reasons; r != ReasonTransportError {
		t.Fatalf("reason %q", r)
	}
	expectClosed(t, c.ws, 2*time.Second)
}

func TestMalformedPacketsCloseWithNodesReasons(t *testing.T) {
	cases := []struct {
		name   string
		frame  string
		binary bool
		reason string
	}{
		{"unknown engine type", `9`, false, ReasonParseError},
		{"garbage", `hello`, false, ReasonParseError},
		{"empty frame", ``, false, ReasonParseError},
		{"unknown socket.io type", `47`, false, ReasonForcedClose},
		{"event not an array", `42{"a":1}`, false, ReasonForcedClose},
		{"invalid json", `42["x",{`, false, ReasonForcedClose},
		{"reserved event", `42["disconnect"]`, false, ReasonForcedClose},
		{"binary attachments", `451-["x",{"_placeholder":true,"num":0}]`, false, ReasonForcedClose},
		{"binary frame", `42["x"]`, true, ReasonForcedClose},
		{"base64 binary", `bAAAA`, false, ReasonForcedClose},
		{"second CONNECT", `40{"token":"good"}`, false, ReasonForcedServerClose},
		{"client CONNECT_ERROR", `44{"message":"x"}`, false, ReasonForcedServerClose},
		{"event for other nsp", `42/admin,["x"]`, false, ReasonForcedServerClose},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarness(t, Options{})
			reasons := make(chan string, 1)
			h.srv.OnConnection(func(s *Socket) {
				s.OnDisconnect(func(reason string) { reasons <- reason })
			})
			c := h.connectedClient()
			mt := websocket.TextMessage
			if tc.binary {
				mt = websocket.BinaryMessage
			}
			if err := c.ws.WriteMessage(mt, []byte(tc.frame)); err != nil {
				t.Fatal(err)
			}
			select {
			case r := <-reasons:
				if r != tc.reason {
					t.Fatalf("reason %q, want %q", r, tc.reason)
				}
			case <-time.After(2 * time.Second):
				t.Fatal("no disconnect")
			}
			expectClosed(t, c.ws, 2*time.Second)
			waitFor(t, time.Second, func() bool { return h.srv.ClientsCount() == 0 })
		})
	}
}

func TestEventBeforeConnectClosesTheTransport(t *testing.T) {
	h := newHarness(t, Options{})
	var connections atomic.Int32
	h.srv.OnConnection(func(*Socket) { connections.Add(1) })
	for _, frame := range []string{`42["room:leave",{}]`, `430[]`, `41`} {
		c := h.openClient()
		send(t, c.ws, frame)
		expectClosed(t, c.ws, 2*time.Second)
	}
	if connections.Load() != 0 {
		t.Fatal("no socket should have connected")
	}
	waitFor(t, time.Second, func() bool { return h.srv.ClientsCount() == 0 })
}

func TestConnectTimeoutClosesIdleEngineConnections(t *testing.T) {
	h := newHarness(t, Options{ConnectTimeout: 80 * time.Millisecond})
	c := h.openClient()
	start := time.Now()
	expectClosed(t, c.ws, 2*time.Second)
	if since := time.Since(start); since < 50*time.Millisecond {
		t.Fatalf("closed after %s, before the connect timeout", since)
	}
	// A connected socket is not subject to it.
	c2 := h.connectedClient()
	time.Sleep(150 * time.Millisecond)
	send(t, c2.ws, `421["x"]`)
	_ = c2.ws.SetReadDeadline(time.Now().Add(150 * time.Millisecond))
	if _, _, err := c2.ws.ReadMessage(); err == nil || !strings.Contains(err.Error(), "timeout") {
		t.Fatalf("connected socket was closed by the connect timeout: %v", err)
	}
}

func TestMiddlewareResultAfterTransportCloseIsIgnored(t *testing.T) {
	h := newHarness(t, Options{})
	release := make(chan struct{})
	entered := make(chan *Socket, 1)
	h.srv.Use(func(s *Socket) error {
		entered <- s
		<-release
		return nil
	})
	var connections atomic.Int32
	h.srv.OnConnection(func(*Socket) { connections.Add(1) })
	c := h.openClient()
	send(t, c.ws, `40{"token":"good"}`)
	pending := <-entered
	_ = c.ws.Close() // the client gives up while the DB lookup is pending
	// The reader notices first (the conn is removed from the registry only
	// once the dispatcher, busy in the middleware, gets to the notice).
	waitFor(t, 2*time.Second, func() bool { return pending.c.readDone.Load() })
	if h.srv.ClientsCount() != 1 {
		t.Fatalf("ClientsCount %d while the dispatcher is still in the middleware", h.srv.ClientsCount())
	}
	close(release)
	waitFor(t, 2*time.Second, func() bool { return h.srv.ClientsCount() == 0 })
	if connections.Load() != 0 {
		t.Fatal("OnConnection ran for a client that had already gone")
	}
	if pending.Connected() || len(pending.Rooms()) != 0 {
		t.Fatal("the never-connected socket must not be marked connected or hold rooms")
	}
}

// ---- write path ----

func TestSlowClientOverflowingTheQueueIsClosed(t *testing.T) {
	h := newHarness(t, Options{WriteQueueSize: 8, WriteTimeout: 300 * time.Millisecond})
	sockCh := make(chan *Socket, 1)
	reasons := make(chan string, 1)
	h.srv.OnConnection(func(s *Socket) {
		s.OnDisconnect(func(reason string) { reasons <- reason })
		sockCh <- s
	})
	c := h.connectedClient()
	s := <-sockCh
	// The client never reads; fill the kernel buffers with large frames
	// until a write blocks past WriteTimeout or the queue overflows. Either
	// way the emitter is never blocked and the reason is "transport error".
	big := strings.Repeat("y", 64*1024)
	start := time.Now()
	var sawErr bool
	for i := 0; i < 5000 && !sawErr; i++ {
		if err := s.Emit("blob", big); err != nil {
			sawErr = true
		}
		if time.Since(start) > 5*time.Second {
			t.Fatal("Emit blocked the caller")
		}
	}
	if !sawErr {
		t.Fatal("Emit never reported the closed socket")
	}
	select {
	case r := <-reasons:
		if r != ReasonTransportError {
			t.Fatalf("reason %q", r)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("slow client was not disconnected")
	}
	_ = c.ws.Close()
}

// A write already blocked on a client that stopped reading must not hold the
// connection — or a Shutdown — for the whole WriteTimeout: the watchdog armed
// by terminate hard-closes the WebSocket after the drain limit.
func TestShutdownIsNotHeldByABlockedWrite(t *testing.T) {
	h := newHarness(t, Options{WriteTimeout: 30 * time.Second})
	sockCh := make(chan *Socket, 1)
	h.srv.OnConnection(func(s *Socket) { sockCh <- s })
	c := h.connectedClient()
	s := <-sockCh
	// The client never reads: the writer blocks on the kernel buffers, then
	// the queue overflows and the connection is closed with "transport error"
	// while the blocked write is still in flight.
	big := strings.Repeat("z", 64*1024)
	fill := time.Now()
	for !errors.Is(s.Emit("blob", big), ErrSocketClosed) {
		if time.Since(fill) > 10*time.Second {
			t.Fatal("the queue never overflowed")
		}
	}
	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := h.srv.Shutdown(ctx); err != nil {
		t.Fatalf("Shutdown: %v", err)
	}
	if took := time.Since(start); took > 6*time.Second {
		t.Fatalf("Shutdown took %s with a blocked write (WriteTimeout 30s); the watchdog should cap it near %s", took, maxCloseDrain)
	}
	_ = c.ws.Close()
}

// ---- lifecycle ----

func TestCloseDisconnectsEveryoneWithServerShuttingDown(t *testing.T) {
	h := newHarness(t, Options{})
	reasons := make(chan string, 3)
	h.srv.OnConnection(func(s *Socket) {
		s.OnDisconnect(func(reason string) { reasons <- reason })
	})
	clients := []*client{h.connectedClient(), h.connectedClient(), h.connectedClient()}
	h.srv.Close()
	for i := 0; i < 3; i++ {
		select {
		case r := <-reasons:
			if r != ReasonServerShuttingDown {
				t.Fatalf("reason %q", r)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("not every socket was disconnected")
		}
	}
	for _, c := range clients {
		expectClosed(t, c.ws, 2*time.Second)
	}
	// New upgrades are refused; Close is idempotent.
	if _, resp, err := websocket.DefaultDialer.Dial(h.wsURL(""), nil); err == nil || resp == nil || resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("dial after Close: err=%v resp=%v", err, resp)
	}
	h.srv.Close()
	if h.srv.ClientsCount() != 0 {
		t.Fatalf("ClientsCount %d after Close", h.srv.ClientsCount())
	}
}

func TestShutdownWaitsForHandlersAndCallbacks(t *testing.T) {
	h := newHarness(t, Options{})
	release := make(chan struct{})
	var callbackRan atomic.Bool
	h.srv.OnConnection(func(s *Socket) {
		s.On("slow", func(_ []json.RawMessage, ack AckFunc) {
			<-release
			ack("late")
		})
		s.OnDisconnect(func(string) { callbackRan.Store(true) })
	})
	c := h.connectedClient()
	send(t, c.ws, `421["slow"]`)
	time.Sleep(30 * time.Millisecond)
	// With a handler in flight, Shutdown honours the ctx…
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	err := h.srv.Shutdown(ctx)
	cancel()
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Shutdown with a blocked handler: %v", err)
	}
	if callbackRan.Load() {
		t.Fatal("disconnect callback ran while the handler was still in flight")
	}
	// …and completes once the handler returns.
	close(release)
	ctx, cancel = context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := h.srv.Shutdown(ctx); err != nil {
		t.Fatalf("Shutdown: %v", err)
	}
	if !callbackRan.Load() {
		t.Fatal("disconnect callback did not run")
	}
}

func TestHundredConcurrentSocketsAndNoGoroutineLeak(t *testing.T) {
	baseline := runtime.NumGoroutine()
	h := newHarness(t, Options{})
	h.srv.Use(tokenMiddleware)
	var joined atomic.Int32
	h.srv.OnConnection(func(s *Socket) {
		s.Join("lobby")
		joined.Add(1)
		s.On("room:quickJoin", func(args []json.RawMessage, ack AckFunc) {
			ack(map[string]any{"ok": true, "roomId": s.ID()})
		})
	})

	const n = 100
	conns := make([]*websocket.Conn, n)
	var wg sync.WaitGroup
	errs := make(chan error, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			ws, _, err := websocket.DefaultDialer.Dial(h.wsURL(""), nil)
			if err != nil {
				errs <- err
				return
			}
			conns[i] = ws
			_ = ws.SetReadDeadline(time.Now().Add(5 * time.Second))
			if _, f, err := ws.ReadMessage(); err != nil || !strings.HasPrefix(string(f), "0{") {
				errs <- fmt.Errorf("open: %v %q", err, f)
				return
			}
			if err := ws.WriteMessage(websocket.TextMessage, []byte(`40{"token":"good"}`)); err != nil {
				errs <- err
				return
			}
			if _, f, err := ws.ReadMessage(); err != nil || !strings.HasPrefix(string(f), "40{") {
				errs <- fmt.Errorf("connect: %v %q", err, f)
				return
			}
			id := fmt.Sprint(i)
			if err := ws.WriteMessage(websocket.TextMessage, []byte(`42`+id+`["room:quickJoin",{"bootAmount":200}]`)); err != nil {
				errs <- err
				return
			}
			_, f, err := ws.ReadMessage()
			if err != nil || !strings.HasPrefix(string(f), "43"+id+`[{"ok":true,"roomId":"`) {
				errs <- fmt.Errorf("ack: %v %q", err, f)
			}
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Error(err)
	}
	if t.Failed() {
		t.FailNow()
	}
	if h.srv.ClientsCount() != n || joined.Load() != n {
		t.Fatalf("ClientsCount %d joined %d, want %d", h.srv.ClientsCount(), joined.Load(), n)
	}
	// A room broadcast reaches all 100.
	h.srv.To("lobby").Emit("lobby:tick", 1)
	for _, ws := range conns {
		_ = ws.SetReadDeadline(time.Now().Add(5 * time.Second))
		_, f, err := ws.ReadMessage()
		if err != nil || string(f) != `42["lobby:tick",1]` {
			t.Fatalf("broadcast: %v %q", err, f)
		}
	}
	// Shut down and make sure every connection goroutine is gone.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := h.srv.Shutdown(ctx); err != nil {
		t.Fatalf("Shutdown: %v", err)
	}
	for _, ws := range conns {
		expectClosed(t, ws, 2*time.Second)
		_ = ws.Close()
	}
	h.ts.CloseClientConnections()
	waitFor(t, 5*time.Second, func() bool {
		runtime.GC()
		return runtime.NumGoroutine() <= baseline+3 // httptest's own goroutines
	})
}
