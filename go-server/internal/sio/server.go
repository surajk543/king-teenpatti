package sio

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"sort"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// Defaults are the Node server's Socket.IO options (server/src/index.js) and
// socket.io's own defaults for what index.js leaves unset.
const (
	DefaultPath         = "/socket.io/"
	DefaultPingInterval = 20 * time.Second
	DefaultPingTimeout  = 25 * time.Second
	DefaultMaxPayload   = 100000 // maxHttpBufferSize: 1e5
	// DefaultConnectTimeout is socket.io's `connectTimeout`: an Engine.IO
	// connection that never completes a Socket.IO CONNECT is closed.
	DefaultConnectTimeout = 45 * time.Second
	// DefaultWriteTimeout bounds one WebSocket write; a client that cannot
	// drain a frame in this long is closed with ReasonTransportError (Node
	// buffered without limit — a slow client could hold memory forever).
	DefaultWriteTimeout = 10 * time.Second
	// DefaultWriteQueueSize is the per-socket outbound frame queue; on overflow
	// the socket is closed with ReasonTransportError instead of blocking the
	// emitter (a Table actor or a handler).
	DefaultWriteQueueSize = 512
	// maxCloseDrain caps how long the writer flushes queued frames (the "41"
	// of a Disconnect, a final session:replaced) before it sends the close
	// frame — Node's engine `close()` waits for the write buffer to drain
	// with no bound, but a server Shutdown has an 8 s budget and a stuck
	// client must not eat it.
	maxCloseDrain = 2 * time.Second
)

// Options configures a Server. Zero values take the Node server's settings.
type Options struct {
	// Path is the mount point, default "/socket.io/". The handler must be
	// registered for that prefix (mux.Handle("/socket.io/", srv)).
	Path string
	// PingInterval / PingTimeout: Engine.IO heartbeat; defaults 20s / 25s.
	PingInterval time.Duration
	PingTimeout  time.Duration
	// MaxPayload is the largest text frame accepted and the advertised
	// maxPayload; default 100000 (Node maxHttpBufferSize: 1e5). Larger frames
	// close the socket with "transport error".
	MaxPayload int64
	// CheckOrigin decides whether an Upgrade request's Origin is allowed
	// (gorilla). nil → allow all (Node CORS_ORIGIN "*"). The app builds one
	// from config.CORSOrigin.
	CheckOrigin func(r *http.Request) bool
	// Logger for protocol-level debug lines; nil → slog.Default().
	Logger *slog.Logger
	// Now supplies time for handshake timestamps and heartbeats; nil → time.Now.
	Now func() time.Time
	// ConnectTimeout closes an Engine.IO connection that has not completed a
	// Socket.IO CONNECT (socket.io `connectTimeout`); default 45s.
	ConnectTimeout time.Duration
	// WriteTimeout bounds a single frame write; default 10s. The flush before
	// a graceful close is bounded by min(WriteTimeout, 2s).
	WriteTimeout time.Duration
	// WriteQueueSize is the per-connection outbound queue; default 512.
	WriteQueueSize int
}

func (o Options) withDefaults() Options {
	if o.Path == "" {
		o.Path = DefaultPath
	}
	if o.PingInterval <= 0 {
		o.PingInterval = DefaultPingInterval
	}
	if o.PingTimeout <= 0 {
		o.PingTimeout = DefaultPingTimeout
	}
	if o.MaxPayload <= 0 {
		o.MaxPayload = DefaultMaxPayload
	}
	if o.CheckOrigin == nil {
		o.CheckOrigin = func(*http.Request) bool { return true }
	}
	if o.Logger == nil {
		o.Logger = slog.Default()
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.ConnectTimeout <= 0 {
		o.ConnectTimeout = DefaultConnectTimeout
	}
	if o.WriteTimeout <= 0 {
		o.WriteTimeout = DefaultWriteTimeout
	}
	if o.WriteQueueSize <= 0 {
		o.WriteQueueSize = DefaultWriteQueueSize
	}
	return o
}

// Handshake is what the connection middleware may inspect (Node
// socket.handshake).
type Handshake struct {
	// Auth is the CONNECT payload — `{"token":"…"}` from the clients. Nil
	// when the client sent "40" with no object.
	Auth map[string]json.RawMessage
	// Query is the upgrade request's query string (EIO, transport, t, and a
	// legacy `token` the Node middleware also accepted as a fallback).
	Query   url.Values
	Headers http.Header
	// Address is the client IP as seen by the server (RemoteAddr host, no port).
	Address string
	// Time is when the Engine.IO session opened.
	Time time.Time
}

// Middleware runs on each CONNECT (Node io.use). Returning an error refuses
// the connection: the client receives CONNECT_ERROR {"message": err.Error()}
// and, as in Node, the transport stays open — the client library closes it
// (socket.io-client destroys the socket on connect_error), or the
// ConnectTimeout does, or the client may send another CONNECT. Middleware
// runs on the socket's own goroutine and MAY block (the game's looks the
// user up in Postgres).
type Middleware func(s *Socket) error

// Handler handles one client EVENT. args are the elements of the event array
// AFTER the event name (the game's events always carry exactly one object, or
// none — treat a missing arg as `{}`; ping:rtt carries a bare number). ack is
// nil when the client did not request one; otherwise call it exactly once
// with the payload(s) to send back as the ACK args.
//
// Handlers run on the socket's dispatch goroutine, one at a time per socket,
// in arrival order (Node processed a socket's packets serially too). A
// handler may block (they await the Table actor and the database); the
// heartbeat is serviced by a separate goroutine so a slow handler never
// trips the ping timeout. Since handlers on DIFFERENT sockets run
// concurrently, anything they share needs a mutex.
type Handler func(args []json.RawMessage, ack AckFunc)

// AckFunc sends the ACK for the event it was handed with. Safe to call from
// any goroutine, once (later calls are ignored, as Node's `ack()` guard does).
type AckFunc func(payload ...any)

// Server is the Socket.IO server for the default namespace.
type Server struct {
	opts     Options
	upgrader websocket.Upgrader
	log      *slog.Logger

	mu          sync.RWMutex
	sockets     map[string]*Socket              // sid → connected namespace socket
	rooms       map[string]map[*Socket]struct{} // room → members
	conns       map[*conn]struct{}              // open Engine.IO connections
	middlewares []Middleware
	onConnect   func(*Socket)
	closed      bool

	wg sync.WaitGroup // one Add per connection goroutine
}

// NewServer builds a server; register it with mux.Handle(opts.Path, srv).
func NewServer(opts Options) *Server {
	opts = opts.withDefaults()
	s := &Server{
		opts:    opts,
		log:     opts.Logger,
		sockets: make(map[string]*Socket),
		rooms:   make(map[string]map[*Socket]struct{}),
		conns:   make(map[*conn]struct{}),
	}
	s.upgrader = websocket.Upgrader{
		ReadBufferSize:  4096,
		WriteBufferSize: 4096,
		CheckOrigin:     opts.CheckOrigin,
		// engine.io 6 leaves perMessageDeflate disabled.
		EnableCompression: false,
	}
	return s
}

// ServeHTTP is the Engine.IO endpoint. Flow (engine.io `Server.verify` +
// `handshake`, in Node's order):
//  1. transport must be "websocket" else 400 {code 0}; a `sid` parameter
//     (resuming a session) is 400 {code 1} — a websocket-only server never
//     resumes sessions; method must be GET else 400 {code 2}; the request
//     must be a WebSocket upgrade else 400 {code 3}; EIO must be "4" else
//     400 {code 5}. Bodies are engine.io's JSON {"code":N,"message":…}
//     (Node writes the same JSON for plain HTTP requests; for upgrade
//     requests it wrote text/html — invisible to every client);
//  2. websocket upgrade (CheckOrigin; failure → 403 from gorilla);
//  3. send OPEN "0{…}" with a fresh 20-char base64url sid;
//  4. heartbeat, engine.io v4 schedule: PingInterval after OPEN send "2",
//     then expect "3" within PingTimeout or close with ReasonPingTimeout; a
//     PONG re-arms the interval;
//  5. read loop: "3" (PONG) feeds the heartbeat; a client "2" is a protocol
//     violation in v4 → ReasonTransportError (engine.io "invalid heartbeat
//     direction"); "0"/"1"/"5"/"6" are ignored; "4…" → DecodePacket →
//     dispatch: CONNECT → middlewares in order (first error → "44{"message":…}",
//     transport kept open) → CONNECT ack "40{"sid":…}" → OnConnection; EVENT →
//     the registered Handler (an unknown event is ignored, like Node's
//     EventEmitter); ACK → ignored (the server never awaits client acks);
//     DISCONNECT → ReasonClientNamespaceDisc (transport kept open); an
//     EVENT/ACK/DISCONNECT before CONNECT, a second CONNECT, a binary frame
//     or an undecodable packet → ReasonForcedClose; an unknown Engine.IO
//     type character → ReasonParseError;
//  6. any read error → ReasonTransportClose (close frame / EOF) or
//     ReasonTransportError (frame over MaxPayload, protocol or network error).
//
// Every write to one connection goes through a single writer goroutine fed
// by a bounded queue (gorilla allows one concurrent writer).
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if q.Get("transport") != "websocket" {
		writeHandshakeError(w, ErrorCodeUnknownTransport)
		return
	}
	if q.Get("sid") != "" {
		writeHandshakeError(w, ErrorCodeUnknownSID)
		return
	}
	if r.Method != http.MethodGet {
		writeHandshakeError(w, ErrorCodeBadHandshake)
		return
	}
	if !websocket.IsWebSocketUpgrade(r) {
		writeHandshakeError(w, ErrorCodeBadRequest)
		return
	}
	if q.Get("EIO") != EngineIOVersion {
		writeHandshakeError(w, ErrorCodeUnsupportedProto)
		return
	}
	s.mu.RLock()
	closed := s.closed
	s.mu.RUnlock()
	if closed {
		http.Error(w, "server shutting down", http.StatusServiceUnavailable)
		return
	}

	ws, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		// gorilla has already written the 4xx response.
		s.log.Debug("sio: upgrade failed", "error", err.Error())
		return
	}

	c := newConn(s, ws, r, q)
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		_ = ws.Close()
		return
	}
	s.conns[c] = struct{}{}
	s.wg.Add(3)
	s.mu.Unlock()

	open, _ := marshalJSON(OpenPacket{
		SID:          c.sid,
		Upgrades:     []string{},
		PingInterval: s.opts.PingInterval.Milliseconds(),
		PingTimeout:  s.opts.PingTimeout.Milliseconds(),
		MaxPayload:   s.opts.MaxPayload,
	})
	// The OPEN frame is the first thing in the queue, so it is the first
	// thing on the wire.
	c.enqueue(append([]byte{EnginePacketOpen}, open...))

	go c.writeLoop()
	go c.readLoop()
	go c.dispatchLoop()
}

// writeHandshakeError writes engine.io's `abortRequest` body.
func writeHandshakeError(w http.ResponseWriter, code int) {
	body, _ := json.Marshal(HandshakeError{Code: code, Message: ErrorMessages[code]})
	status := http.StatusBadRequest
	if code == ErrorCodeForbidden {
		status = http.StatusForbidden
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

// Use appends a connection middleware (run in order on each CONNECT).
func (s *Server) Use(mw Middleware) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.middlewares = append(s.middlewares, mw)
}

// OnConnection sets the callback for every accepted socket (Node
// io.on('connection')). It runs after the CONNECT ack has been sent, on the
// socket's goroutine, BEFORE any of that socket's events are dispatched — so
// handlers registered inside it see every event.
func (s *Server) OnConnection(fn func(*Socket)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.onConnect = fn
}

// To addresses every socket in `room` (Node io.to(room)).
func (s *Server) To(room string) *Broadcast {
	return &Broadcast{s: s, rooms: []string{room}}
}

// ClientsCount is the number of open Engine.IO connections (Node
// io.engine.clientsCount) — GET /health `sockets`.
func (s *Server) ClientsCount() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.conns)
}

// Close disconnects every socket with ReasonServerShuttingDown and refuses new
// upgrades (Node io.close()). Idempotent. It returns without waiting for the
// disconnect callbacks — use Shutdown to wait for them.
func (s *Server) Close() {
	s.mu.Lock()
	s.closed = true
	conns := make([]*conn, 0, len(s.conns))
	for c := range s.conns {
		conns = append(conns, c)
	}
	s.mu.Unlock()
	// Node: every namespace socket _onclose("server shutting down") — no "41"
	// is sent — then engine.close() closes each transport.
	for _, c := range conns {
		c.terminate(ReasonServerShuttingDown)
	}
}

// Shutdown is Close plus waiting for every socket goroutine to exit or ctx
// to expire.
func (s *Server) Shutdown(ctx context.Context) error {
	s.Close()
	done := make(chan struct{})
	go func() {
		s.wg.Wait()
		close(done)
	}()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// ---- registry (all under s.mu) ----

func (s *Server) removeConn(c *conn) {
	s.mu.Lock()
	delete(s.conns, c)
	s.mu.Unlock()
}

func (s *Server) middlewareChain() []Middleware {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return append([]Middleware(nil), s.middlewares...)
}

func (s *Server) connectionHandler() func(*Socket) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.onConnect
}

func (s *Server) addSocket(sock *Socket) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sockets[sock.id] = sock
}

// removeSocket drops the socket from the registry and from every room
// (Node `_cleanup` → `leaveAll` + `nsp._remove`).
func (s *Server) removeSocket(sock *Socket, rooms []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.sockets, sock.id)
	for _, room := range rooms {
		s.dropMemberLocked(room, sock)
	}
}

func (s *Server) dropMemberLocked(room string, sock *Socket) {
	members := s.rooms[room]
	if members == nil {
		return
	}
	delete(members, sock)
	if len(members) == 0 {
		delete(s.rooms, room)
	}
}

func (s *Server) joinRoom(room string, sock *Socket) {
	s.mu.Lock()
	defer s.mu.Unlock()
	members := s.rooms[room]
	if members == nil {
		members = make(map[*Socket]struct{})
		s.rooms[room] = members
	}
	members[sock] = struct{}{}
}

func (s *Server) leaveRoom(room string, sock *Socket) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.dropMemberLocked(room, sock)
}

// members returns every socket in any of the rooms, once each.
func (s *Server) members(rooms []string) []*Socket {
	s.mu.RLock()
	defer s.mu.RUnlock()
	seen := make(map[*Socket]struct{})
	var out []*Socket
	for _, room := range rooms {
		for sock := range s.rooms[room] {
			if _, dup := seen[sock]; dup {
				continue
			}
			seen[sock] = struct{}{}
			out = append(out, sock)
		}
	}
	return out
}

// Broadcast is a room-addressed emit.
type Broadcast struct {
	s     *Server
	rooms []string
}

// Emit sends the event to every socket in the addressed rooms, once per
// socket even if it is in several. Serialises the payload ONCE.
func (b *Broadcast) Emit(event string, payload ...any) {
	frame, err := eventFrame(event, payload)
	if err != nil {
		b.s.log.Error("sio: broadcast payload not serialisable", "event", event, "error", err.Error())
		return
	}
	for _, sock := range b.s.members(b.rooms) {
		sock.send(frame)
	}
}

// Socket is one connected client in the default namespace.
type Socket struct {
	id        string
	server    *Server
	c         *conn
	handshake Handshake

	mu           sync.RWMutex
	handlers     map[string]Handler
	onDisconnect []func(reason string)
	rooms        map[string]struct{}
	data         any
	connected    bool
}

func newSocket(id string, c *conn, hs Handshake) *Socket {
	return &Socket{
		id:        id,
		server:    c.srv,
		c:         c,
		handshake: hs,
		handlers:  make(map[string]Handler),
		rooms:     make(map[string]struct{}),
	}
}

// ID is the namespace socket id (Node socket.id): a fresh 20-char base64url
// id per CONNECT, never the Engine.IO sid — socket.io 4 deliberately keeps
// the two apart ("don't reuse the Engine.IO id because it's sensitive
// information", socket.js). A re-CONNECT on the same connection gets another
// fresh id. The clients never compare the two.
func (s *Socket) ID() string { return s.id }

// Handshake returns the connection facts (auth token, query, address).
func (s *Socket) Handshake() Handshake { return s.handshake }

// SetData / Data attach arbitrary per-socket state (Node socket.data.user).
// The game stores its *session there.
func (s *Socket) SetData(v any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.data = v
}

// Data returns what SetData stored, or nil.
func (s *Socket) Data() any {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.data
}

// On registers the handler for one event name, replacing any previous one.
func (s *Socket) On(event string, h Handler) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if h == nil {
		delete(s.handlers, event)
		return
	}
	s.handlers[event] = h
}

func (s *Socket) handler(event string) Handler {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.handlers[event]
}

// OnDisconnect registers a callback run once, after the transport is gone,
// with the Socket.IO reason string (see Reason*). Callbacks run in
// registration order, after the socket has left every room (Node fires
// 'disconnect' after `_cleanup`).
func (s *Socket) OnDisconnect(fn func(reason string)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.onDisconnect = append(s.onDisconnect, fn)
}

// Emit sends an EVENT to this socket: frame `42["event",payload...]`.
// Returns ErrSocketClosed after disconnect; never blocks the caller (writes
// are queued to a single writer goroutine; a client that cannot drain the
// queue or a write that exceeds WriteTimeout closes the socket with
// ReasonTransportError).
func (s *Socket) Emit(event string, payload ...any) error {
	if !s.Connected() {
		return ErrSocketClosed
	}
	frame, err := eventFrame(event, payload)
	if err != nil {
		return err
	}
	return s.send(frame)
}

// send queues one message frame; a disconnected socket drops it.
func (s *Socket) send(frame []byte) error {
	if !s.Connected() {
		return ErrSocketClosed
	}
	if !s.c.enqueue(frame) {
		return ErrSocketClosed
	}
	return nil
}

// Join / Leave manage room membership (Node socket.join/leave). Rooms are
// server-wide keys; the game uses the roomId. Join after disconnect is a
// no-op (Node replaces `join` with noop in `_cleanup`).
//
// The socket's own room set and the server's room index are updated under
// s.mu together (lock order: Socket.mu → Server.mu; the server never calls
// into a Socket while holding its own lock). Otherwise a Join racing a
// disconnect could re-insert the socket into the server index after close()
// had swept it — a dead member the room would carry forever.
func (s *Socket) Join(room string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.connected {
		return
	}
	s.rooms[room] = struct{}{}
	s.server.joinRoom(room, s)
}

// Leave removes the socket from a room (no-op if absent).
func (s *Socket) Leave(room string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.rooms, room)
	s.server.leaveRoom(room, s)
}

// Rooms lists the rooms the socket is in (sorted; includes the socket's own
// id, which socket.io joins on connect).
func (s *Socket) Rooms() []string {
	s.mu.RLock()
	out := make([]string, 0, len(s.rooms))
	for room := range s.rooms {
		out = append(out, room)
	}
	s.mu.RUnlock()
	sort.Strings(out)
	return out
}

// Disconnect ends the session (Node socket.disconnect(close)). Both variants
// send a DISCONNECT packet "41" and run the disconnect callbacks
// SYNCHRONOUSLY, on the caller's goroutine, with ReasonServerNamespaceDisc
// before returning — socket/index.js relies on that ordering when it
// replaces a user's previous socket (spec §10.2). close=true additionally
// closes the underlying WebSocket once the "41" has been written; false
// keeps the transport (the client may CONNECT again). The game always passes
// true (session:replaced). No-op when already disconnected.
func (s *Socket) Disconnect(close bool) {
	if !s.Connected() {
		return
	}
	// Node writes the DISCONNECT packet, then _onclose(...).
	s.c.enqueue([]byte{EnginePacketMessage, PacketDisconnect})
	s.close(ReasonServerNamespaceDisc)
	if close {
		s.c.terminate(ReasonServerNamespaceDisc)
	}
}

// Connected reports whether the namespace connection is open.
func (s *Socket) Connected() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.connected
}

// connect marks the socket live: registry, own-id room, connected flag
// (Node `_onconnect`). Called on the dispatch goroutine only.
func (s *Socket) connect() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.connected = true
	s.rooms[s.id] = struct{}{}
	s.server.addSocket(s)
	s.server.joinRoom(s.id, s)
}

// close is Node's `_onclose(reason)`: exactly once; leave every room and the
// registry, flip connected, then run the disconnect callbacks in order (the
// callbacks run without any lock held, so they may Join/Leave/Emit on other
// sockets). Safe to call from any goroutine; concurrent callers return
// immediately.
func (s *Socket) close(reason string) {
	s.mu.Lock()
	if !s.connected {
		s.mu.Unlock()
		return
	}
	s.connected = false
	rooms := make([]string, 0, len(s.rooms))
	for room := range s.rooms {
		rooms = append(rooms, room)
	}
	s.rooms = make(map[string]struct{})
	callbacks := append([]func(reason string){}, s.onDisconnect...)
	s.server.removeSocket(s, rooms)
	s.mu.Unlock()
	for _, cb := range callbacks {
		cb(reason)
	}
}

// ---- helpers ----

// marshalJSON is JSON.stringify: no HTML escaping (Node emits <, >, & raw),
// no trailing newline.
func marshalJSON(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	out := buf.Bytes()
	if n := len(out); n > 0 && out[n-1] == '\n' {
		out = out[:n-1]
	}
	return out, nil
}

// eventFrame builds the full Engine.IO frame `42["event",payload...]`.
func eventFrame(event string, payload []any) ([]byte, error) {
	args := make([]any, 0, 1+len(payload))
	args = append(args, event)
	args = append(args, payload...)
	data, err := marshalJSON(args)
	if err != nil {
		return nil, err
	}
	frame := make([]byte, 0, 2+len(data))
	frame = append(frame, EnginePacketMessage)
	frame = append(frame, EncodePacket(Packet{Type: PacketEvent, ID: -1, Data: data})...)
	return frame, nil
}

// ackFrame builds `43<id>[args...]`.
func ackFrame(id int, payload []any) ([]byte, error) {
	if payload == nil {
		payload = []any{}
	}
	data, err := marshalJSON(payload)
	if err != nil {
		return nil, err
	}
	frame := make([]byte, 0, 2+20+len(data))
	frame = append(frame, EnginePacketMessage)
	frame = append(frame, EncodePacket(Packet{Type: PacketAck, ID: id, Data: data})...)
	return frame, nil
}

// newSID is engine.io's base64id shape: 15 random bytes → 20 base64url chars.
func newSID() string {
	var b [15]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("sio: crypto/rand unavailable: " + err.Error())
	}
	return base64.RawURLEncoding.EncodeToString(b[:])
}

// hostOf strips the port from a RemoteAddr.
func hostOf(remoteAddr string) string {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		return remoteAddr
	}
	return host
}
