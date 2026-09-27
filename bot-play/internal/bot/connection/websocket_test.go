package connection

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
)

// ---------------------------------------------------------------- the fake

// fakeServer speaks just enough Engine.IO v4 / Socket.IO v5 over gorilla
// websocket to drive the client: the open packet, the CONNECT (accepted or
// refused with CONNECT_ERROR, the transport left open as the real server
// leaves it), and then whatever frames a test writes. Every frame the client
// sends after its CONNECT is recorded, in order, on the connection.
type fakeServer struct {
	t   *testing.T
	srv *httptest.Server

	pingInterval int64 // ms, in the open packet
	pingTimeout  int64
	maxPayload   int64
	refuse       string // a CONNECT_ERROR message; "" accepts
	noOpen       bool   // upgrade, then say nothing
	compress     bool

	conns    chan *fakeConn
	tokens   chan string
	requests chan *http.Request
}

type fakeConn struct {
	ws     *websocket.Conn
	wmu    sync.Mutex
	frames chan string   // text frames from the client, after its CONNECT
	gone   chan struct{} // closed when the client's side is gone
	mu     sync.Mutex
	endErr error // the read error that ended it
}

func newFakeServer(t *testing.T, configure ...func(*fakeServer)) *fakeServer {
	t.Helper()
	f := &fakeServer{
		t:            t,
		pingInterval: 20000,
		pingTimeout:  25000,
		maxPayload:   100000,
		conns:        make(chan *fakeConn, 16),
		tokens:       make(chan string, 16),
		requests:     make(chan *http.Request, 16),
	}
	for _, c := range configure {
		c(f)
	}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeServer) serve(w http.ResponseWriter, r *http.Request) {
	f.requests <- r.Clone(context.Background())
	up := websocket.Upgrader{EnableCompression: f.compress}
	ws, err := up.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	fc := &fakeConn{ws: ws, frames: make(chan string, 4096), gone: make(chan struct{})}
	if f.compress {
		ws.EnableWriteCompression(true)
	}
	if f.noOpen {
		f.conns <- fc
		fc.read()
		return
	}
	open := fmt.Sprintf(`0{"sid":"engine-sid","upgrades":[],"pingInterval":%d,"pingTimeout":%d,"maxPayload":%d}`,
		f.pingInterval, f.pingTimeout, f.maxPayload)
	fc.send(open)
	_, connect, err := ws.ReadMessage()
	if err != nil || !strings.HasPrefix(string(connect), "40") {
		_ = ws.Close()
		return
	}
	var auth struct {
		Token string `json:"token"`
	}
	_ = json.Unmarshal(connect[2:], &auth)
	f.tokens <- auth.Token
	if f.refuse != "" {
		fc.send(`44{"message":"` + f.refuse + `"}`)
	} else {
		fc.send(`40{"sid":"socket-1"}`)
	}
	f.conns <- fc
	fc.read()
}

// read records every frame until the client's side is gone.
func (fc *fakeConn) read() {
	defer close(fc.gone)
	for {
		mt, data, err := fc.ws.ReadMessage()
		if err != nil {
			fc.mu.Lock()
			fc.endErr = err
			fc.mu.Unlock()
			return
		}
		if mt == websocket.TextMessage {
			fc.frames <- string(data)
		}
	}
}

func (fc *fakeConn) send(frame string) {
	fc.wmu.Lock()
	defer fc.wmu.Unlock()
	_ = fc.ws.WriteMessage(websocket.TextMessage, []byte(frame))
}

func (fc *fakeConn) sendBinary(b []byte) {
	fc.wmu.Lock()
	defer fc.wmu.Unlock()
	_ = fc.ws.WriteMessage(websocket.BinaryMessage, b)
}

// emit sends `42["event",payload]` (no payload when payload is nil).
func (fc *fakeConn) emit(event string, payload any) {
	args := []any{event}
	if payload != nil {
		args = append(args, payload)
	}
	data, _ := json.Marshal(args)
	fc.send("42" + string(data))
}

// drop ends the TCP connection with no close frame: a network failure.
func (fc *fakeConn) drop() { _ = fc.ws.NetConn().Close() }

func (fc *fakeConn) err() error {
	fc.mu.Lock()
	defer fc.mu.Unlock()
	return fc.endErr
}

func (fc *fakeConn) next(t *testing.T) string {
	t.Helper()
	select {
	case f := <-fc.frames:
		return f
	case <-time.After(3 * time.Second):
		t.Fatal("no frame from the client")
		return ""
	}
}

// nextRequest reads the client's next `42<id>[...]` and returns its id and
// its argument array.
func (fc *fakeConn) nextRequest(t *testing.T) (int, []json.RawMessage) {
	t.Helper()
	frame := fc.next(t)
	if !strings.HasPrefix(frame, "42") {
		t.Fatalf("frame %q is not an EVENT", frame)
	}
	rest := frame[2:]
	i := 0
	for i < len(rest) && rest[i] >= '0' && rest[i] <= '9' {
		i++
	}
	if i == 0 {
		t.Fatalf("frame %q carries no ack id", frame)
	}
	id, _ := strconv.Atoi(rest[:i])
	var args []json.RawMessage
	if err := json.Unmarshal([]byte(rest[i:]), &args); err != nil {
		t.Fatalf("frame %q: %v", frame, err)
	}
	return id, args
}

func (f *fakeServer) conn(t *testing.T) *fakeConn {
	t.Helper()
	select {
	case fc := <-f.conns:
		return fc
	case <-time.After(3 * time.Second):
		t.Fatal("the client never connected")
		return nil
	}
}

func (f *fakeServer) dialer(opts DialOptions) *Dialer {
	return NewDialer(f.srv.URL, "", opts)
}

// dial connects a session and returns it with the server's side.
func (f *fakeServer) dial(t *testing.T, opts DialOptions) (protocol.Session, *fakeConn) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	s, err := f.dialer(opts).Dial(ctx, "jwt-token")
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s, f.conn(t)
}

func recv(t *testing.T, s protocol.Session) protocol.Event {
	t.Helper()
	select {
	case ev, ok := <-s.Events():
		if !ok {
			t.Fatal("Events closed")
		}
		return ev
	case <-time.After(3 * time.Second):
		t.Fatal("no event")
		return protocol.Event{}
	}
}

// drain reads Events to its close and returns what was left.
func drain(t *testing.T, s protocol.Session) []protocol.Event {
	t.Helper()
	var out []protocol.Event
	deadline := time.After(5 * time.Second)
	for {
		select {
		case ev, ok := <-s.Events():
			if !ok {
				return out
			}
			out = append(out, ev)
		case <-deadline:
			t.Fatalf("Events never closed (%d read)", len(out))
		}
	}
}

func waitDone(t *testing.T, s protocol.Session) {
	t.Helper()
	select {
	case <-s.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("the session never ended")
	}
}

// lockedWriter lets a test read what a logger wrote while the session's
// goroutines may still be writing.
type lockedWriter struct {
	w  io.Writer
	mu *sync.Mutex
}

func (l lockedWriter) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.w.Write(p)
}

func slogTo(w io.Writer, mu *sync.Mutex) *slog.Logger {
	return slog.New(slog.NewTextHandler(lockedWriter{w, mu}, &slog.HandlerOptions{Level: slog.LevelDebug}))
}

// ---------------------------------------------------------------- dialling

func TestTheSocketURLIsDerivedFromTheServerURL(t *testing.T) {
	cases := map[string]string{
		"http://127.0.0.1:3000":            "ws://127.0.0.1:3000/socket.io/?EIO=4&transport=websocket",
		"http://127.0.0.1:3000/":           "ws://127.0.0.1:3000/socket.io/?EIO=4&transport=websocket",
		"https://prod.sungamestudio.com":   "wss://prod.sungamestudio.com/socket.io/?EIO=4&transport=websocket",
		"https://example.com/game/":        "wss://example.com/game/socket.io/?EIO=4&transport=websocket",
		"HTTP://Example.com:80":            "ws://Example.com:80/socket.io/?EIO=4&transport=websocket",
		"wss://example.com":                "wss://example.com/socket.io/?EIO=4&transport=websocket",
		" http://127.0.0.1:3000?x=1#frag ": "ws://127.0.0.1:3000/socket.io/?EIO=4&transport=websocket",
	}
	for in, want := range cases {
		got, err := socketURL(in)
		if err != nil || got != want {
			t.Errorf("socketURL(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, bad := range []string{"", "ftp://example.com", "127.0.0.1:3000", "http://"} {
		if _, err := socketURL(bad); err == nil {
			t.Errorf("socketURL(%q) accepted", bad)
		}
	}
	if got := NewDialer("http://a:1", "ws://override/x", DialOptions{}).URL(); got != "ws://override/x" {
		t.Errorf("the override was not used: %q", got)
	}
	d := NewDialer("gopher://a", "", DialOptions{})
	if _, err := d.Dial(context.Background(), "t"); err == nil {
		t.Error("a Dialer with an unusable server url dialled")
	}
}

func TestDialAuthenticatesAndDeliversTheServersEvents(t *testing.T) {
	f := newFakeServer(t)
	s, fc := f.dial(t, DialOptions{})

	if tok := <-f.tokens; tok != "jwt-token" {
		t.Fatalf("the server received token %q", tok)
	}
	r := <-f.requests
	if r.URL.Path != "/socket.io/" || r.URL.Query().Get("EIO") != "4" || r.URL.Query().Get("transport") != "websocket" {
		t.Fatalf("upgrade request %s", r.URL)
	}
	if r.Header.Get("Origin") != "" {
		t.Fatalf("a native client sends no Origin; sent %q", r.Header.Get("Origin"))
	}

	fc.emit(protocol.EvSessionReady, map[string]any{"user": map[string]any{"id": "u1", "chips": 1000}})
	ev := recv(t, s)
	if ev.Name != protocol.EvSessionReady {
		t.Fatalf("event %q", ev.Name)
	}
	var ready protocol.SessionReady
	if err := ev.Decode(&ready); err != nil || ready.User.ID != "u1" || ready.User.Chips != 1000 {
		t.Fatalf("session:ready decoded as %+v, %v", ready, err)
	}
	if s.Err() != nil {
		t.Fatalf("Err on an open session: %v", s.Err())
	}
	select {
	case <-s.Done():
		t.Fatal("Done closed on an open session")
	default:
	}
}

func TestARefusedHandshakeIsAConnectError(t *testing.T) {
	f := newFakeServer(t, func(f *fakeServer) { f.refuse = protocol.CodeUnknownUser })
	s, err := f.dialer(DialOptions{}).Dial(context.Background(), "stale")
	if s != nil {
		t.Fatal("a refused Dial returned a session")
	}
	var ce *protocol.ConnectError
	if !errors.As(err, &ce) || ce.Message != protocol.CodeUnknownUser {
		t.Fatalf("err = %v, want a ConnectError unknown_user", err)
	}
	// The server keeps the transport open after CONNECT_ERROR; the client
	// must close it, as socket.io-client does.
	fc := f.conn(t)
	select {
	case <-fc.gone:
	case <-time.After(3 * time.Second):
		t.Fatal("the client left the refused transport open")
	}
}

func TestTheHandshakeTimesOutWithoutAnOpenPacket(t *testing.T) {
	f := newFakeServer(t, func(f *fakeServer) { f.noOpen = true })
	start := time.Now()
	_, err := f.dialer(DialOptions{HandshakeTimeout: 150 * time.Millisecond}).Dial(context.Background(), "t")
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err = %v, want DeadlineExceeded", err)
	}
	var ce *protocol.ConnectError
	if errors.As(err, &ce) {
		t.Fatal("a timeout reported as a refusal")
	}
	if el := time.Since(start); el > 2*time.Second {
		t.Fatalf("the handshake took %s", el)
	}
}

func TestACancelledContextStopsTheHandshake(t *testing.T) {
	f := newFakeServer(t, func(f *fakeServer) { f.noOpen = true })
	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(100*time.Millisecond, cancel)
	start := time.Now()
	_, err := f.dialer(DialOptions{HandshakeTimeout: 10 * time.Second}).Dial(ctx, "t")
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want Canceled", err)
	}
	if el := time.Since(start); el > 2*time.Second {
		t.Fatalf("the cancelled handshake took %s", el)
	}
}

func TestARefusedUpgradeNamesTheStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"code":0,"message":"Transport unknown"}`))
	}))
	defer srv.Close()
	_, err := NewDialer(srv.URL, "", DialOptions{}).Dial(context.Background(), "t")
	if err == nil || !strings.Contains(err.Error(), "400") || !strings.Contains(err.Error(), "Transport unknown") {
		t.Fatalf("err = %v", err)
	}
}

func TestTheTokenIsNeverLogged(t *testing.T) {
	var buf strings.Builder
	var mu sync.Mutex
	log := slogTo(&buf, &mu)
	f := newFakeServer(t)
	s, _ := f.dial(t, DialOptions{Log: log})
	_ = s.Close()
	f2 := newFakeServer(t, func(f *fakeServer) { f.refuse = "invalid_session" })
	_, _ = f2.dialer(DialOptions{Log: log}).Dial(context.Background(), "jwt-token")
	mu.Lock()
	defer mu.Unlock()
	if strings.Contains(buf.String(), "jwt-token") {
		t.Fatalf("the token reached the log:\n%s", buf.String())
	}
	if !strings.Contains(buf.String(), "connection open") || !strings.Contains(buf.String(), "invalid_session") {
		t.Fatalf("the lifecycle was not logged:\n%s", buf.String())
	}
}

// ---------------------------------------------------------------- events

func TestEventsArriveInTheOrderTheServerSentThem(t *testing.T) {
	f := newFakeServer(t)
	s, fc := f.dial(t, DialOptions{})
	const n = 500
	go func() {
		for i := 0; i < n; i++ {
			fc.emit("seq", map[string]int{"i": i})
		}
		fc.send(`42["tick"]`)
		fc.send(`42["multi",{"a":1},{"b":2}]`)
		fc.send(`42/admin,["elsewhere",1]`) // another namespace: never ours
		fc.send(`42[7,"numeric name"]`)     // no string name: nothing to deliver
		fc.send(`451-["bin",{"_placeholder":true,"num":0}]`)
		fc.sendBinary([]byte{1, 2, 3})
		fc.send(`6`) // Engine.IO noop
		fc.send(`42["last",null]`)
	}()
	for i := 0; i < n; i++ {
		ev := recv(t, s)
		var body struct{ I int }
		if ev.Name != "seq" || ev.Decode(&body) != nil || body.I != i {
			t.Fatalf("event %d is %s %s", i, ev.Name, ev.Data)
		}
	}
	if ev := recv(t, s); ev.Name != "tick" || ev.Data != nil {
		t.Fatalf("a no-argument event arrived as %s %s", ev.Name, ev.Data)
	}
	if ev := recv(t, s); ev.Name != "multi" || string(ev.Data) != `{"a":1}` {
		t.Fatalf("a two-argument event arrived as %s %s", ev.Name, ev.Data)
	}
	if ev := recv(t, s); ev.Name != "bin" || !strings.Contains(string(ev.Data), "_placeholder") {
		t.Fatalf("a binary event arrived as %s %s", ev.Name, ev.Data)
	}
	if ev := recv(t, s); ev.Name != "last" || string(ev.Data) != "null" {
		t.Fatalf("the last event arrived as %s %s", ev.Name, ev.Data)
	}
	if s.Err() != nil {
		t.Fatalf("the session ended: %v", s.Err())
	}
}

func TestLargeCompressedFramesArriveWhole(t *testing.T) {
	f := newFakeServer(t, func(f *fakeServer) { f.compress = true })
	s, fc := f.dial(t, DialOptions{})
	big := strings.Repeat("seat-", 5000) // 25 KB, deflated on the wire
	fc.emit(protocol.EvRoomState, map[string]string{"blob": big})
	ev := recv(t, s)
	var body struct{ Blob string }
	if err := ev.Decode(&body); err != nil || body.Blob != big {
		t.Fatalf("the compressed frame arrived as %d bytes, %v", len(body.Blob), err)
	}
	// And the other way: a frame long enough to be compressed going out.
	text := strings.Repeat("x", 1000)
	if err := s.Emit(context.Background(), protocol.EvChatMessage, map[string]string{"text": text}); err != nil {
		t.Fatal(err)
	}
	if got := fc.next(t); got != `42["chat:message",{"text":"`+text+`"}]` {
		t.Fatalf("the server read %d bytes", len(got))
	}
}

func TestEmitWritesTheEventAsTheAppWould(t *testing.T) {
	f := newFakeServer(t)
	s, fc := f.dial(t, DialOptions{})
	ctx := context.Background()
	if err := s.Emit(ctx, protocol.EvChatMessage, map[string]string{"text": "hi <b> & you"}); err != nil {
		t.Fatal(err)
	}
	if got := fc.next(t); got != `42["chat:message",{"text":"hi <b> & you"}]` {
		t.Fatalf("frame %q", got)
	}
	if err := s.Emit(ctx, protocol.EvRoomLeave, nil); err != nil {
		t.Fatal(err)
	}
	if got := fc.next(t); got != `42["room:leave"]` {
		t.Fatalf("a nil payload wrote %q", got)
	}
	if err := s.Emit(ctx, "raw", json.RawMessage(`{"a":[1,2]}`)); err != nil {
		t.Fatal(err)
	}
	if got := fc.next(t); got != `42["raw",{"a":[1,2]}]` {
		t.Fatalf("a raw payload wrote %q", got)
	}
}

func TestAFrameOverTheServersLimitIsRefusedBeforeItIsSent(t *testing.T) {
	f := newFakeServer(t, func(f *fakeServer) { f.maxPayload = 100 })
	s, fc := f.dial(t, DialOptions{})
	err := s.Emit(context.Background(), protocol.EvChatMessage, map[string]string{"text": strings.Repeat("a", 200)})
	if !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("err = %v", err)
	}
	err = s.Request(context.Background(), protocol.EvChatMessage, map[string]string{"text": strings.Repeat("a", 200)}, nil)
	if !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("Request err = %v", err)
	}
	if err := s.Emit(context.Background(), "ok", nil); err != nil {
		t.Fatal(err)
	}
	if got := fc.next(t); got != `42["ok"]` {
		t.Fatalf("frame %q", got)
	}
	if s.Err() != nil {
		t.Fatalf("the refusal ended the session: %v", s.Err())
	}
}

// ---------------------------------------------------------------- requests

func TestRequestResolvesItsAcknowledgement(t *testing.T) {
	f := newFakeServer(t)
	s, fc := f.dial(t, DialOptions{})
	ctx := context.Background()

	type result struct {
		ack protocol.RoomAck
		err error
	}
	done := make(chan result, 1)
	go func() {
		var ack protocol.RoomAck
		err := s.Request(ctx, protocol.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "blind"}, &ack)
		done <- result{ack, err}
	}()
	id, args := fc.nextRequest(t)
	if id != 0 || len(args) != 2 || string(args[0]) != `"room:quickJoin"` || string(args[1]) != `{"bootAmount":200,"category":"blind"}` {
		t.Fatalf("request %d %s", id, args)
	}
	// An event the server sends before the ack is queued before Request returns.
	fc.emit(protocol.EvRoomJoined, map[string]string{"roomId": "r1"})
	fc.send(fmt.Sprintf(`43%d[{"ok":true,"roomId":"r1","code":"ABCD1234","category":"blind"}]`, id))
	r := <-done
	if r.err != nil || !r.ack.OK || r.ack.RoomID != "r1" || r.ack.Code != "ABCD1234" || r.ack.Category != "blind" {
		t.Fatalf("ack %+v, %v", r.ack, r.err)
	}
	select {
	case ev := <-s.Events():
		if ev.Name != protocol.EvRoomJoined {
			t.Fatalf("event %q", ev.Name)
		}
	default:
		t.Fatal("the event sent before the ack was not yet queued when Request returned")
	}

	// A refusal is an answer, not an error; ids keep counting up.
	go func() {
		var ack protocol.RoomAck
		err := s.Request(ctx, protocol.EvRoomSwitch, nil, &ack)
		done <- result{ack, err}
	}()
	id, args = fc.nextRequest(t)
	if id != 1 || len(args) != 1 {
		t.Fatalf("second request %d %s", id, args)
	}
	fc.send(fmt.Sprintf(`43%d[{"ok":false,"code":"no_other_table","message":"No other table"}]`, id))
	r = <-done
	if r.err != nil || r.ack.OK || r.ack.Code != protocol.CodeNoOtherTable {
		t.Fatalf("refusal %+v, %v", r.ack, r.err)
	}

	// A nil ack discards the answer; an empty ack array resolves too.
	errc := make(chan error, 1)
	go func() { errc <- s.Request(ctx, protocol.EvRoomLeave, nil, nil) }()
	id, _ = fc.nextRequest(t)
	fc.send(fmt.Sprintf(`43%d[]`, id))
	if err := <-errc; err != nil {
		t.Fatalf("an empty ack: %v", err)
	}
	// An answer that does not fit the ack's type is an error of its own.
	go func() {
		var ack protocol.RoomAck
		errc <- s.Request(ctx, protocol.EvRoomLeave, nil, &ack)
	}()
	id, _ = fc.nextRequest(t)
	fc.send(fmt.Sprintf(`43%d["not an object"]`, id))
	if err := <-errc; err == nil || errors.Is(err, protocol.ErrClosed) {
		t.Fatalf("a mistyped ack: %v", err)
	}
}

func TestARequestTimesOutAndItsLateAckIsIgnored(t *testing.T) {
	f := newFakeServer(t)
	s, fc := f.dial(t, DialOptions{})
	ctx, cancel := context.WithTimeout(context.Background(), 80*time.Millisecond)
	defer cancel()
	start := time.Now()
	var ack protocol.Ack
	err := s.Request(ctx, protocol.EvRoomLeave, nil, &ack)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err = %v", err)
	}
	if el := time.Since(start); el > time.Second {
		t.Fatalf("the timeout took %s", el)
	}
	id, _ := fc.nextRequest(t)
	impl := s.(*session)
	impl.mu.Lock()
	left := len(impl.pending)
	impl.mu.Unlock()
	if left != 0 {
		t.Fatalf("%d pending entries left after the timeout", left)
	}
	fc.send(fmt.Sprintf(`43%d[{"ok":true}]`, id)) // late: nobody is waiting

	// The session is unharmed.
	errc := make(chan error, 1)
	go func() { errc <- s.Request(context.Background(), protocol.EvRoomLeave, nil, &ack) }()
	id2, _ := fc.nextRequest(t)
	if id2 != id+1 {
		t.Fatalf("the next id is %d after %d", id2, id)
	}
	fc.send(fmt.Sprintf(`43%d[{"ok":true}]`, id2))
	if err := <-errc; err != nil || !ack.OK {
		t.Fatalf("the next request: %+v, %v", ack, err)
	}
}

func TestManyConcurrentRequestsEachGetTheirOwnAnswer(t *testing.T) {
	f := newFakeServer(t)
	s, fc := f.dial(t, DialOptions{})
	const n = 200

	go func() {
		// Collect every request, then answer them in reverse.
		type req struct{ id, n int }
		var all []req
		for len(all) < n {
			frame := <-fc.frames
			rest := frame[2:]
			i := 0
			for rest[i] >= '0' && rest[i] <= '9' {
				i++
			}
			id, _ := strconv.Atoi(rest[:i])
			var args []json.RawMessage
			_ = json.Unmarshal([]byte(rest[i:]), &args)
			var body struct{ N int }
			_ = json.Unmarshal(args[1], &body)
			all = append(all, req{id, body.N})
		}
		for i := len(all) - 1; i >= 0; i-- {
			fc.send(fmt.Sprintf(`43%d[{"ok":true,"n":%d}]`, all[i].id, all[i].n))
		}
	}()

	var wg sync.WaitGroup
	errs := make(chan error, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			var ack struct {
				OK bool
				N  int
			}
			if err := s.Request(ctx, "echo", map[string]int{"n": i}, &ack); err != nil {
				errs <- err
				return
			}
			if !ack.OK || ack.N != i {
				errs <- fmt.Errorf("request %d got the answer for %d", i, ack.N)
			}
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Error(err)
	}
}

// ---------------------------------------------------------------- heartbeat

func TestServerPingsAreAnswered(t *testing.T) {
	f := newFakeServer(t, func(f *fakeServer) { f.pingInterval, f.pingTimeout = 60, 60 })
	s, fc := f.dial(t, DialOptions{})
	// Pinging every 40 ms keeps a 120 ms heartbeat window alive for 400 ms.
	for i := 0; i < 10; i++ {
		fc.send("2")
		if got := fc.next(t); got != "3" {
			t.Fatalf("ping %d answered with %q", i, got)
		}
		time.Sleep(40 * time.Millisecond)
	}
	if s.Err() != nil {
		t.Fatalf("a pinged session ended: %v", s.Err())
	}
	fc.send("2probe")
	if got := fc.next(t); got != "3probe" {
		t.Fatalf("a ping with data answered with %q", got)
	}
}

func TestASilentServerIsDetectedAsDead(t *testing.T) {
	f := newFakeServer(t, func(f *fakeServer) { f.pingInterval, f.pingTimeout = 60, 60 })
	s, fc := f.dial(t, DialOptions{})
	errc := make(chan error, 1)
	go func() { errc <- s.Request(context.Background(), protocol.EvRoomLeave, nil, nil) }()
	start := time.Now()
	waitDone(t, s)
	if el := time.Since(start); el > 2*time.Second {
		t.Fatalf("the dead connection was noticed after %s", el)
	}
	if !errors.Is(s.Err(), ErrHeartbeatTimeout) {
		t.Fatalf("Err = %v", s.Err())
	}
	if err := <-errc; !errors.Is(err, protocol.ErrClosed) {
		t.Fatalf("the pending request: %v", err)
	}
	evs := drain(t, s)
	if len(evs) != 1 || evs[0].Name != protocol.EvDisconnect {
		t.Fatalf("events %v", evs)
	}
	select {
	case <-fc.gone:
	case <-time.After(3 * time.Second):
		t.Fatal("the socket was left open")
	}
}

// ---------------------------------------------------------------- the end

func TestADroppedConnectionEndsEverything(t *testing.T) {
	f := newFakeServer(t)
	s, fc := f.dial(t, DialOptions{})
	fc.emit("before", map[string]int{"x": 1})

	errc := make(chan error, 3)
	for i := 0; i < 3; i++ {
		go func() { errc <- s.Request(context.Background(), protocol.EvRoomLeave, nil, nil) }()
	}
	for i := 0; i < 3; i++ {
		fc.next(t)
	}
	fc.drop()
	for i := 0; i < 3; i++ {
		select {
		case err := <-errc:
			if !errors.Is(err, protocol.ErrClosed) {
				t.Fatalf("pending request: %v", err)
			}
		case <-time.After(3 * time.Second):
			t.Fatal("a pending request was never failed")
		}
	}
	waitDone(t, s)
	if s.Err() == nil || errors.Is(s.Err(), protocol.ErrClosed) {
		t.Fatalf("Err = %v, want the read failure", s.Err())
	}
	evs := drain(t, s)
	if len(evs) != 2 || evs[0].Name != "before" || evs[1].Name != protocol.EvDisconnect {
		t.Fatalf("events %v", evs)
	}
	if err := s.Request(context.Background(), protocol.EvRoomLeave, nil, nil); !errors.Is(err, protocol.ErrClosed) {
		t.Fatalf("Request after the end: %v", err)
	}
	if err := s.Emit(context.Background(), protocol.EvRoomLeave, nil); !errors.Is(err, protocol.ErrClosed) {
		t.Fatalf("Emit after the end: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("Close after the end: %v", err)
	}
}

func TestTheServersDisconnectPacketEndsTheSession(t *testing.T) {
	f := newFakeServer(t)
	s, fc := f.dial(t, DialOptions{})
	fc.emit(protocol.EvSessionReplaced, map[string]string{"message": "Signed in elsewhere"})
	fc.send("41")
	waitDone(t, s)
	if !errors.Is(s.Err(), ErrServerDisconnect) {
		t.Fatalf("Err = %v", s.Err())
	}
	evs := drain(t, s)
	if len(evs) != 2 || evs[0].Name != protocol.EvSessionReplaced || evs[1].Name != protocol.EvDisconnect {
		t.Fatalf("events %v", evs)
	}
}

func TestTheEngineClosePacketEndsTheSession(t *testing.T) {
	f := newFakeServer(t)
	s, fc := f.dial(t, DialOptions{})
	fc.send("1")
	waitDone(t, s)
	if !errors.Is(s.Err(), ErrServerClose) {
		t.Fatalf("Err = %v", s.Err())
	}
}

func TestAConnectErrorAfterTheHandshakeIsForwarded(t *testing.T) {
	f := newFakeServer(t)
	s, fc := f.dial(t, DialOptions{})
	fc.send(`44{"message":"account_disabled"}`)
	waitDone(t, s)
	var ce *protocol.ConnectError
	if !errors.As(s.Err(), &ce) || ce.Message != protocol.CodeAccountDisabled {
		t.Fatalf("Err = %v", s.Err())
	}
	evs := drain(t, s)
	if len(evs) != 2 || evs[0].Name != protocol.EvConnectError || evs[1].Name != protocol.EvDisconnect {
		t.Fatalf("events %v", evs)
	}
	var body struct{ Message string }
	if err := evs[0].Decode(&body); err != nil || body.Message != protocol.CodeAccountDisabled {
		t.Fatalf("connect_error carried %s", evs[0].Data)
	}
}

func TestCloseIsIdempotentAndSaysGoodbye(t *testing.T) {
	f := newFakeServer(t)
	s, fc := f.dial(t, DialOptions{})
	errc := make(chan error, 1)
	go func() { errc <- s.Request(context.Background(), protocol.EvRoomLeave, nil, nil) }()
	fc.next(t)

	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := s.Close(); err != nil {
				t.Errorf("Close: %v", err)
			}
		}()
	}
	wg.Wait()
	// Every Close has returned: the session is over.
	select {
	case <-s.Done():
	default:
		t.Fatal("Close returned before the session ended")
	}
	if err := s.Close(); err != nil {
		t.Fatalf("a later Close: %v", err)
	}
	if !errors.Is(s.Err(), protocol.ErrClosed) {
		t.Fatalf("Err = %v", s.Err())
	}
	if err := <-errc; !errors.Is(err, protocol.ErrClosed) {
		t.Fatalf("the pending request: %v", err)
	}
	if got := fc.next(t); got != "41" {
		t.Fatalf("the goodbye was %q, want the DISCONNECT 41", got)
	}
	select {
	case <-fc.gone:
	case <-time.After(3 * time.Second):
		t.Fatal("the server never saw the socket close")
	}
	if !websocket.IsCloseError(fc.err(), websocket.CloseNormalClosure) {
		t.Fatalf("the server saw %v, want a normal close frame", fc.err())
	}
	evs := drain(t, s)
	if len(evs) != 1 || evs[0].Name != protocol.EvDisconnect {
		t.Fatalf("events %v", evs)
	}
}

func TestCloseFromTheEventLoopWithAFullBufferDoesNotHang(t *testing.T) {
	f := newFakeServer(t)
	s, fc := f.dial(t, DialOptions{EventBuffer: 2, StallTimeout: 10 * time.Second})
	for i := 0; i < 10; i++ {
		fc.emit("flood", i)
	}
	// Wait until the reader is waiting on the full buffer.
	deadline := time.Now().Add(3 * time.Second)
	for len(s.(*session).events) < 2 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	start := time.Now()
	_ = s.Close()
	if el := time.Since(start); el > 3*time.Second {
		t.Fatalf("Close took %s", el)
	}
	evs := drain(t, s)
	if len(evs) != 3 || evs[2].Name != protocol.EvDisconnect {
		t.Fatalf("events %v", evs)
	}
}

// ---------------------------------------------------------------- slow consumers

func TestAStalledConsumerLosesTheConnectionNotEvents(t *testing.T) {
	f := newFakeServer(t)
	s, fc := f.dial(t, DialOptions{EventBuffer: 4, StallTimeout: 150 * time.Millisecond})
	for i := 0; i < 20; i++ {
		fc.emit("seq", i)
	}
	waitDone(t, s)
	if !errors.Is(s.Err(), ErrSlowConsumer) {
		t.Fatalf("Err = %v", s.Err())
	}
	evs := drain(t, s)
	if len(evs) != 5 {
		t.Fatalf("%d events, want the 4 buffered and the disconnect", len(evs))
	}
	for i := 0; i < 4; i++ {
		if evs[i].Name != "seq" || string(evs[i].Data) != strconv.Itoa(i) {
			t.Fatalf("event %d is %s %s", i, evs[i].Name, evs[i].Data)
		}
	}
	if evs[4].Name != protocol.EvDisconnect {
		t.Fatalf("the last event is %s", evs[4].Name)
	}
}

func TestASlowButAttentiveConsumerMissesNothing(t *testing.T) {
	f := newFakeServer(t)
	s, fc := f.dial(t, DialOptions{EventBuffer: 4, StallTimeout: 2 * time.Second})
	const n = 40
	go func() {
		for i := 0; i < n; i++ {
			fc.emit("seq", i)
		}
	}()
	for i := 0; i < n; i++ {
		time.Sleep(3 * time.Millisecond)
		ev := recv(t, s)
		if ev.Name != "seq" || string(ev.Data) != strconv.Itoa(i) {
			t.Fatalf("event %d is %s %s", i, ev.Name, ev.Data)
		}
	}
	if s.Err() != nil {
		t.Fatalf("an attentive consumer lost its connection: %v", s.Err())
	}
}

// ---------------------------------------------------------------- parsing

func TestPacketsParseAsSocketIOWritesThem(t *testing.T) {
	cases := []struct {
		in          string
		typ         byte
		nsp         string
		id          int
		attachments int
		data        string
	}{
		{`2["x",1]`, packetEvent, "", -1, 0, `["x",1]`},
		{`217["x"]`, packetEvent, "", 17, 0, `["x"]`},
		{`317[{"ok":true}]`, packetAck, "", 17, 0, `[{"ok":true}]`},
		{`3170[]`, packetAck, "", 170, 0, `[]`},
		{`2/admin,5["x"]`, packetEvent, "/admin", 5, 0, `["x"]`},
		{`2/,["x"]`, packetEvent, "", -1, 0, `["x"]`},
		{`51-["x",{"_placeholder":true,"num":0}]`, packetBinaryEvent, "", -1, 1, `["x",{"_placeholder":true,"num":0}]`},
		{`62-/a,9[1]`, packetBinaryAck, "/a", 9, 2, `[1]`},
		{`0{"sid":"a"}`, packetConnect, "", -1, 0, `{"sid":"a"}`},
		{`1`, packetDisconnect, "", -1, 0, ``},
		{`4{"message":"unknown_user"}`, packetConnectError, "", -1, 0, `{"message":"unknown_user"}`},
	}
	for _, c := range cases {
		p, err := parsePacket([]byte(c.in))
		if err != nil || p.typ != c.typ || p.nsp != c.nsp || p.id != c.id || p.attachments != c.attachments || string(p.data) != c.data {
			t.Errorf("parsePacket(%q) = %+v %q, %v", c.in, p, p.data, err)
		}
	}
	for _, bad := range []string{``, `9`, `2{`, `5["x"]`, `5x-["x"]`, `2` + strings.Repeat("1", 19) + `[]`} {
		if _, err := parsePacket([]byte(bad)); !errors.Is(err, ErrProtocol) {
			t.Errorf("parsePacket(%q) accepted: %v", bad, err)
		}
	}
}

func TestAnUnreadablePacketEndsTheSessionAsAProtocolError(t *testing.T) {
	f := newFakeServer(t)
	s, fc := f.dial(t, DialOptions{})
	fc.send(`42["x",`)
	waitDone(t, s)
	if !errors.Is(s.Err(), ErrProtocol) {
		t.Fatalf("Err = %v", s.Err())
	}
}
