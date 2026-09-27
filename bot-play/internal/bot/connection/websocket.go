// Package connection is the bots' way to the real game server: the REST API
// (rest.go) and the game connection — a websocket-only Socket.IO v5 /
// Engine.IO v4 client (websocket.go), the same transport the Flutter app
// uses — plus the reconnect backoff (reconnect.go).
//
// It speaks the public protocol only: the JWT the login returned goes in the
// Socket.IO handshake's auth.token, exactly as the app sends it.
package connection

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
)

// The wire, as go-server/internal/sio speaks it (all text frames):
//
//	Engine.IO frame  = <type digit><data>
//	  0 open  → 0{"sid":"…","upgrades":[],"pingInterval":20000,"pingTimeout":25000,"maxPayload":100000}
//	  1 close, 2 ping (SERVER → client), 3 pong (client → server), 4 message, 6 noop
//	Socket.IO packet = "4" + <type digit>[<attachments>-][<nsp>,][<ackId>][<json>]
//	  40{"token":"…"}        client CONNECT with its auth object
//	  40{"sid":"…"}          server CONNECT ack
//	  44{"message":"code"}   server CONNECT_ERROR (the handshake refused)
//	  41                     DISCONNECT (either side)
//	  42["event",payload]    EVENT; 42<id>["event",payload] asks for an ack
//	  43<id>[payload]        ACK — the argument ARRAY
//
// Engine.IO v4 heartbeats run from the server: every pingInterval it sends
// "2" and closes the connection unless "3" comes back within pingTimeout. A
// client "2" is an "invalid heartbeat direction" to the server and ends the
// connection, so this client never pings; it only answers.
const (
	engineOpen    byte = '0'
	engineClose   byte = '1'
	enginePing    byte = '2'
	enginePong    byte = '3'
	engineMessage byte = '4'

	packetConnect      byte = '0'
	packetDisconnect   byte = '1'
	packetEvent        byte = '2'
	packetAck          byte = '3'
	packetConnectError byte = '4'
	packetBinaryEvent  byte = '5'
	packetBinaryAck    byte = '6'
)

// Defaults for DialOptions.
const (
	DefaultHandshakeTimeout = 10 * time.Second
	DefaultEventBuffer      = 256
	DefaultStallTimeout     = 10 * time.Second
	DefaultWriteTimeout     = 10 * time.Second
)

// The server's own figures (go-server/internal/sio/server.go), used when an
// Engine.IO open packet leaves one out.
const (
	defaultPingInterval = 20 * time.Second
	defaultPingTimeout  = 25 * time.Second
	defaultMaxPayload   = 100000
)

const (
	// outboundQueue is the writer's queue per session. Emit and Request wait
	// for room in it (bounded by their ctx), so it is a smoothing buffer, not
	// a place frames are dropped from.
	outboundQueue = 64
	// readLimit caps one inbound frame. The server's largest (a chat:history
	// of 100 lines, a room:state) is tens of KB; this only stops a runaway
	// peer from eating the fleet's memory.
	readLimit = 4 << 20
	// compressMinBytes: with permessage-deflate negotiated, shorter frames go
	// out plain — the server's own rule (sio.DefaultCompressMinBytes). Almost
	// everything a bot sends is shorter.
	compressMinBytes = 256
	// closeWriteLimit bounds the goodbye ("41" and the close frame) a local
	// Close writes before the socket is closed.
	closeWriteLimit = time.Second
	// stallPoll is how often a reader waiting for room on a full event buffer
	// looks again (only while the consumer is behind).
	stallPoll = 5 * time.Millisecond
)

// Errors a session ends with (Session.Err). A local Close ends it with
// protocol.ErrClosed; a CONNECT_ERROR is a *protocol.ConnectError. Read and
// write failures of the network are reported wrapped, as they came.
var (
	// ErrServerDisconnect: the server sent the Socket.IO DISCONNECT "41" —
	// what it does right after session:replaced (the account signed in on
	// another connection) and when the account is deleted.
	ErrServerDisconnect = errors.New("connection: server disconnected the session")
	// ErrServerClose: the server sent the Engine.IO close packet "1".
	ErrServerClose = errors.New("connection: server closed the transport")
	// ErrHeartbeatTimeout: nothing at all came from the server for
	// pingInterval + pingTimeout — no ping, no event. The server pings every
	// pingInterval, so the connection is dead (a half-open TCP connection, a
	// server that hung).
	ErrHeartbeatTimeout = errors.New("connection: no heartbeat from the server")
	// ErrSlowConsumer: the consumer left Events full for StallTimeout. See
	// DialOptions.StallTimeout for the policy.
	ErrSlowConsumer = errors.New("connection: event consumer stalled")
	// ErrFrameTooLarge: an Emit or Request whose frame exceeds the server's
	// maxPayload. It is refused here, before it is sent: the server would
	// close the whole connection over it.
	ErrFrameTooLarge = errors.New("connection: frame exceeds the server's maxPayload")
	// ErrProtocol: the server said something this client cannot read.
	ErrProtocol = errors.New("connection: protocol error")
)

// DialOptions tunes the game connection.
type DialOptions struct {
	HandshakeTimeout time.Duration // websocket + Engine.IO open + Socket.IO connect; default 10 s
	EventBuffer      int           // inbound events buffered per session; default 256
	Log              *slog.Logger
	Header           http.Header // extra handshake headers (none needed)

	// StallTimeout is the slow-consumer policy. The reader delivers events
	// in order and never drops one: when Events already holds EventBuffer
	// undelivered events it stops reading the socket and waits for the
	// consumer, up to StallTimeout. If the consumer has not made room by
	// then, the session is ended with ErrSlowConsumer — the events already
	// buffered are still delivered, followed by the final EvDisconnect — so a
	// stuck bot loses its connection (and reconnects) rather than silently
	// missing what the table said. While the reader waits it answers no
	// pings and resolves no acks; the default 10 s is well inside the
	// server's 25 s pingTimeout. Default 10 s.
	StallTimeout time.Duration
	// WriteTimeout bounds one frame's write; a write that cannot finish in it
	// ends the session. Default 10 s.
	WriteTimeout time.Duration
	// DisableCompression stops the client offering permessage-deflate. By
	// default it is offered, as every shipped client offers it, and the
	// server's larger frames (room:state) then arrive compressed.
	DisableCompression bool
}

func (o DialOptions) withDefaults() DialOptions {
	if o.HandshakeTimeout <= 0 {
		o.HandshakeTimeout = DefaultHandshakeTimeout
	}
	if o.EventBuffer <= 0 {
		o.EventBuffer = DefaultEventBuffer
	}
	if o.StallTimeout <= 0 {
		o.StallTimeout = DefaultStallTimeout
	}
	if o.WriteTimeout <= 0 {
		o.WriteTimeout = DefaultWriteTimeout
	}
	if o.Log == nil {
		o.Log = slog.New(slog.DiscardHandler)
	}
	return o
}

// Dialer opens game connections. One Dialer serves the whole fleet; it
// holds no per-bot state. Safe for concurrent use.
type Dialer struct {
	url    string // the websocket address
	urlErr error  // a serverURL that could not be turned into one
	opts   DialOptions
	ws     *websocket.Dialer
}

// NewDialer: serverURL is http(s)://host[:port]; wsURL, when set, overrides
// the websocket address (ws(s)://host[:port]/socket.io/?EIO=4&transport=websocket
// is derived from serverURL otherwise). An address that cannot be used is
// reported by every Dial.
func NewDialer(serverURL, wsURL string, opts DialOptions) *Dialer {
	opts = opts.withDefaults()
	d := &Dialer{opts: opts}
	if wsURL != "" {
		d.url = wsURL
	} else {
		d.url, d.urlErr = socketURL(serverURL)
	}
	d.ws = &websocket.Dialer{
		Proxy:             http.ProxyFromEnvironment,
		HandshakeTimeout:  opts.HandshakeTimeout,
		ReadBufferSize:    4096,
		WriteBufferSize:   4096,
		WriteBufferPool:   &sync.Pool{}, // an idle bot holds no write buffer
		EnableCompression: !opts.DisableCompression,
	}
	return d
}

// socketURL derives the Engine.IO endpoint from the server's base URL:
// http → ws, https → wss (ws and wss pass through), the base path kept, and
// /socket.io/?EIO=4&transport=websocket appended.
func socketURL(serverURL string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(serverURL))
	if err != nil {
		return "", fmt.Errorf("connection: server url: %w", err)
	}
	switch strings.ToLower(u.Scheme) {
	case "http", "ws":
		u.Scheme = "ws"
	case "https", "wss":
		u.Scheme = "wss"
	default:
		return "", fmt.Errorf("connection: server url %q: the scheme must be http or https", serverURL)
	}
	if u.Host == "" {
		return "", fmt.Errorf("connection: server url %q has no host", serverURL)
	}
	u.Path = strings.TrimRight(u.Path, "/") + "/socket.io/"
	u.RawPath = ""
	u.RawQuery = "EIO=4&transport=websocket"
	u.Fragment = ""
	return u.String(), nil
}

// URL is the websocket address this Dialer connects to ("" when the server
// URL it was given could not be used).
func (d *Dialer) URL() string { return d.url }

// openPacket is the JSON after the Engine.IO open frame's "0".
type openPacket struct {
	SID          string `json:"sid"`
	PingInterval int64  `json:"pingInterval"`
	PingTimeout  int64  `json:"pingTimeout"`
	MaxPayload   int64  `json:"maxPayload"`
}

// Dial connects and authenticates with token. A handshake the server
// refuses is a *protocol.ConnectError. The whole handshake — the websocket
// upgrade, the Engine.IO open packet, the Socket.IO CONNECT and its answer —
// runs within HandshakeTimeout and ctx: when ctx ends the error is
// ctx.Err(); when HandshakeTimeout runs out it wraps
// context.DeadlineExceeded. The token is never logged.
func (d *Dialer) Dial(ctx context.Context, token string) (protocol.Session, error) {
	if d.urlErr != nil {
		return nil, d.urlErr
	}
	hctx, cancel := context.WithTimeout(ctx, d.opts.HandshakeTimeout)
	defer cancel()

	ws, resp, err := d.ws.DialContext(hctx, d.url, d.opts.Header.Clone())
	if err != nil {
		if resp != nil && resp.StatusCode != http.StatusSwitchingProtocols {
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
			_ = resp.Body.Close()
			return nil, fmt.Errorf("connection: websocket upgrade refused: %s: %s", resp.Status, bytes.TrimSpace(body))
		}
		return nil, d.handshakeErr(ctx, hctx, fmt.Errorf("connection: dial: %w", err))
	}
	// A cancelled ctx (not only a deadline) must stop a blocked read too.
	stop := context.AfterFunc(hctx, func() { _ = ws.Close() })
	s, err := d.handshake(hctx, ws, token)
	if !stop() && err == nil {
		err = hctx.Err() // the context ended at the last moment: the socket is closed
	}
	if err != nil {
		_ = ws.Close()
		var ce *protocol.ConnectError
		if errors.As(err, &ce) {
			d.opts.Log.Debug("connection refused", "code", ce.Message)
			return nil, err
		}
		return nil, d.handshakeErr(ctx, hctx, err)
	}
	s.start()
	d.opts.Log.Debug("connection open", "socketId", s.socketID,
		"pingInterval", s.pingInterval, "pingTimeout", s.pingTimeout)
	return s, nil
}

// handshakeErr reports a handshake that failed because a context ended as
// that context's error: the caller's own when ctx ended, a wrapped
// DeadlineExceeded when HandshakeTimeout ran out; otherwise err.
func (d *Dialer) handshakeErr(ctx, hctx context.Context, err error) error {
	// The socket's deadlines are hctx's deadline, and a socket deadline can
	// fire a moment before the context's own timer does: give the context
	// that moment, so the error says which deadline it was.
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() && hctx.Err() == nil {
		select {
		case <-hctx.Done():
		case <-time.After(50 * time.Millisecond):
		}
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if hctx.Err() != nil {
		return fmt.Errorf("connection: handshake timed out after %s: %w", d.opts.HandshakeTimeout, context.DeadlineExceeded)
	}
	return err
}

// handshake reads the open packet, sends CONNECT and reads its answer.
func (d *Dialer) handshake(ctx context.Context, ws *websocket.Conn, token string) (*session, error) {
	ws.SetReadLimit(readLimit)
	if dl, ok := ctx.Deadline(); ok {
		_ = ws.SetReadDeadline(dl)
		_ = ws.SetWriteDeadline(dl)
	}

	frame, err := readText(ws)
	if err != nil {
		return nil, fmt.Errorf("connection: reading the open packet: %w", err)
	}
	if len(frame) == 0 || frame[0] != engineOpen {
		return nil, fmt.Errorf("%w: expected the Engine.IO open packet, got %q", ErrProtocol, clip(frame))
	}
	var open openPacket
	if err := json.Unmarshal(frame[1:], &open); err != nil {
		return nil, fmt.Errorf("%w: open packet: %v", ErrProtocol, err)
	}

	auth, err := json.Marshal(struct {
		Token string `json:"token"`
	}{token})
	if err != nil {
		return nil, err
	}
	connect := append([]byte{engineMessage, packetConnect}, auth...)
	if err := ws.WriteMessage(websocket.TextMessage, connect); err != nil {
		return nil, fmt.Errorf("connection: sending CONNECT: %w", err)
	}

	for {
		frame, err := readText(ws)
		if err != nil {
			return nil, fmt.Errorf("connection: waiting for the CONNECT answer: %w", err)
		}
		if len(frame) == 0 {
			continue
		}
		switch frame[0] {
		case enginePing:
			pong := append([]byte{enginePong}, frame[1:]...)
			if err := ws.WriteMessage(websocket.TextMessage, pong); err != nil {
				return nil, fmt.Errorf("connection: answering a ping: %w", err)
			}
			continue
		case engineClose:
			return nil, ErrServerClose
		case engineMessage:
		default:
			continue
		}
		p, err := parsePacket(frame[1:])
		if err != nil {
			return nil, err
		}
		if p.nsp != "" {
			continue // only "/" is ever connected
		}
		switch p.typ {
		case packetConnect:
			var ack struct {
				SID string `json:"sid"`
			}
			_ = json.Unmarshal(p.data, &ack)
			return newSession(d.opts, ws, open, ack.SID), nil
		case packetConnectError:
			return nil, connectError(p.data)
		case packetDisconnect:
			return nil, ErrServerDisconnect
		}
	}
}

// readText reads frames until a text one; a binary frame before the
// handshake is meaningless and skipped.
func readText(ws *websocket.Conn) ([]byte, error) {
	for {
		mt, data, err := ws.ReadMessage()
		if err != nil {
			return nil, err
		}
		if mt == websocket.TextMessage {
			return data, nil
		}
	}
}

// connectError decodes a CONNECT_ERROR's body: {"message": code}, or a bare
// string (socket.io-parser allows either).
func connectError(data []byte) *protocol.ConnectError {
	var body struct {
		Message string `json:"message"`
	}
	if err := json.Unmarshal(data, &body); err == nil && body.Message != "" {
		return &protocol.ConnectError{Message: body.Message}
	}
	var text string
	if err := json.Unmarshal(data, &text); err == nil && text != "" {
		return &protocol.ConnectError{Message: text}
	}
	return &protocol.ConnectError{Message: "unknown"}
}

var _ protocol.Dialer = (*Dialer)(nil)

// ---------------------------------------------------------------- session

// session is one live connection: protocol.Session over one websocket.
//
// Two goroutines serve it. The reader reads every frame, answers pings (via
// the writer), resolves acknowledgements and delivers events in order; it is
// the only sender on events. The writer is the only goroutine that writes
// frames (gorilla allows one concurrent writer), fed by a bounded queue plus
// a one-slot pong channel it serves first.
//
// terminate is the one way a session ends: the first reason wins, every
// pending request fails with ErrClosed, and closing is closed. The writer
// then says goodbye (a local Close only) and closes the websocket, which
// unblocks the reader; the reader waits for the writer, delivers the final
// EvDisconnect, closes events and finally done.
type session struct {
	ws  *websocket.Conn
	log *slog.Logger

	socketID     string
	pingInterval time.Duration
	pingTimeout  time.Duration
	maxPayload   int
	bufferLimit  int // events the consumer may leave undelivered
	stallTimeout time.Duration
	writeTimeout time.Duration

	events     chan protocol.Event // cap bufferLimit+1: the last slot is the final EvDisconnect's
	out        chan []byte
	pong       chan []byte // one pending pong at most
	closing    chan struct{}
	writerDone chan struct{}
	done       chan struct{}

	termOnce sync.Once
	mu       sync.Mutex
	err      error
	graceful bool // a local Close: the writer sends "41" and a close frame
	ended    bool
	nextID   int
	pending  map[int]chan json.RawMessage
}

func newSession(opts DialOptions, ws *websocket.Conn, open openPacket, socketID string) *session {
	s := &session{
		ws:           ws,
		log:          opts.Log,
		socketID:     socketID,
		pingInterval: millisOr(open.PingInterval, defaultPingInterval),
		pingTimeout:  millisOr(open.PingTimeout, defaultPingTimeout),
		maxPayload:   int(open.MaxPayload),
		bufferLimit:  opts.EventBuffer,
		stallTimeout: opts.StallTimeout,
		writeTimeout: opts.WriteTimeout,
		events:       make(chan protocol.Event, opts.EventBuffer+1),
		out:          make(chan []byte, outboundQueue),
		pong:         make(chan []byte, 1),
		closing:      make(chan struct{}),
		writerDone:   make(chan struct{}),
		done:         make(chan struct{}),
		pending:      make(map[int]chan json.RawMessage),
	}
	if s.maxPayload <= 0 {
		s.maxPayload = defaultMaxPayload
	}
	return s
}

func millisOr(ms int64, fallback time.Duration) time.Duration {
	if ms <= 0 {
		return fallback
	}
	return time.Duration(ms) * time.Millisecond
}

func (s *session) start() {
	_ = s.ws.SetWriteDeadline(time.Time{})
	go s.writeLoop()
	go s.readLoop()
}

var _ protocol.Session = (*session)(nil)

// Events is the ordered stream of inbound events, ending with EvDisconnect.
func (s *session) Events() <-chan protocol.Event { return s.events }

// Done is closed when the connection has ended and both of its goroutines
// have finished; by then the final EvDisconnect is queued on Events.
func (s *session) Done() <-chan struct{} { return s.done }

// Err is why the connection ended: protocol.ErrClosed after Close,
// ErrServerDisconnect, ErrServerClose, ErrHeartbeatTimeout, ErrSlowConsumer,
// a *protocol.ConnectError, ErrProtocol, or the network error that ended it.
// Nil while the connection is open.
func (s *session) Err() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.err
}

// Close ends the connection — a Socket.IO DISCONNECT and a websocket close
// frame first, as socket.io-client's disconnect() does, so the server
// records a client disconnect — and waits until it has ended (about a
// second at most). Safe to call more than once and from any goroutine,
// including the one reading Events.
func (s *session) Close() error {
	s.terminate(protocol.ErrClosed)
	<-s.done
	return nil
}

// Emit queues the event and returns; it waits only for room in the writer's
// queue (bounded by ctx). A nil payload sends the event with no argument —
// `42["event"]`, which the server reads as {}.
func (s *session) Emit(ctx context.Context, event string, payload any) error {
	frame, err := s.eventFrame(event, payload, -1)
	if err != nil {
		return err
	}
	return s.enqueue(ctx, frame)
}

// Request sends the event with the next ack id and waits for the server's
// acknowledgement, decoding its first argument into ack (a nil ack discards
// it). ctx ending → ctx.Err(), and the pending entry is removed (a late ack
// is ignored); the connection ending first → protocol.ErrClosed.
//
// Acknowledgements are read in wire order with the events, so every event
// the server sent before the ack is already queued on Events when Request
// returns.
func (s *session) Request(ctx context.Context, event string, payload any, ack any) error {
	ch := make(chan json.RawMessage, 1)
	s.mu.Lock()
	if s.ended {
		s.mu.Unlock()
		return protocol.ErrClosed
	}
	id := s.nextID
	s.nextID++
	s.pending[id] = ch
	s.mu.Unlock()

	frame, err := s.eventFrame(event, payload, id)
	if err == nil {
		err = s.enqueue(ctx, frame)
	}
	if err != nil {
		s.forget(id)
		return err
	}
	select {
	case raw, ok := <-ch:
		if !ok {
			return protocol.ErrClosed
		}
		if ack == nil || len(raw) == 0 {
			return nil
		}
		if err := json.Unmarshal(raw, ack); err != nil {
			return fmt.Errorf("connection: %s ack: %w", event, err)
		}
		return nil
	case <-ctx.Done():
		s.forget(id)
		return ctx.Err()
	}
}

func (s *session) forget(id int) {
	s.mu.Lock()
	delete(s.pending, id)
	s.mu.Unlock()
}

// enqueue hands one frame to the writer, waiting for room up to ctx.
func (s *session) enqueue(ctx context.Context, frame []byte) error {
	select {
	case <-s.closing:
		return protocol.ErrClosed
	default:
	}
	select {
	case s.out <- frame:
		return nil
	case <-s.closing:
		return protocol.ErrClosed
	case <-ctx.Done():
		return ctx.Err()
	}
}

// eventFrame renders `42[<id>]["event",payload]`.
func (s *session) eventFrame(event string, payload any, id int) ([]byte, error) {
	args := []any{event}
	if payload != nil {
		args = append(args, payload)
	}
	data, err := marshalJSON(args)
	if err != nil {
		return nil, fmt.Errorf("connection: %s payload: %w", event, err)
	}
	frame := make([]byte, 0, 2+20+len(data))
	frame = append(frame, engineMessage, packetEvent)
	if id >= 0 {
		frame = strconv.AppendInt(frame, int64(id), 10)
	}
	frame = append(frame, data...)
	if len(frame) > s.maxPayload {
		return nil, fmt.Errorf("%w: %s is %d bytes, the limit %d", ErrFrameTooLarge, event, len(frame), s.maxPayload)
	}
	return frame, nil
}

// marshalJSON is JSON.stringify: no HTML escaping, no trailing newline.
func marshalJSON(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}

// terminate fixes why the session ended and starts closing it. Idempotent;
// the first reason wins. Every pending Request fails with ErrClosed.
func (s *session) terminate(err error) {
	s.termOnce.Do(func() {
		if err == nil {
			err = protocol.ErrClosed
		}
		s.mu.Lock()
		s.err = err
		s.ended = true
		s.graceful = errors.Is(err, protocol.ErrClosed)
		for id, ch := range s.pending {
			close(ch)
			delete(s.pending, id)
		}
		s.mu.Unlock()
		close(s.closing)
	})
}

// ---- writer ----

func (s *session) writeLoop() {
	defer close(s.writerDone)
	for {
		// A pong goes before anything queued: the server's heartbeat waits.
		select {
		case p := <-s.pong:
			if !s.write(p) {
				return
			}
			continue
		default:
		}
		select {
		case p := <-s.pong:
			if !s.write(p) {
				return
			}
		case frame := <-s.out:
			if !s.write(frame) {
				return
			}
		case <-s.closing:
			s.goodbye()
			return
		}
	}
}

// write sends one text frame under WriteTimeout; a failure ends the session
// and closes the socket.
func (s *session) write(frame []byte) bool {
	_ = s.ws.SetWriteDeadline(time.Now().Add(s.writeTimeout))
	s.ws.EnableWriteCompression(len(frame) >= compressMinBytes)
	if err := s.ws.WriteMessage(websocket.TextMessage, frame); err != nil {
		s.terminate(fmt.Errorf("connection: write: %w", err))
		_ = s.ws.Close()
		return false
	}
	return true
}

// goodbye closes the socket; after a local Close it first sends the
// Socket.IO DISCONNECT and a websocket close frame, bounded by
// closeWriteLimit.
func (s *session) goodbye() {
	s.mu.Lock()
	graceful := s.graceful
	s.mu.Unlock()
	if graceful {
		deadline := time.Now().Add(closeWriteLimit)
		_ = s.ws.SetWriteDeadline(deadline)
		s.ws.EnableWriteCompression(false)
		if err := s.ws.WriteMessage(websocket.TextMessage, []byte{engineMessage, packetDisconnect}); err == nil {
			_ = s.ws.WriteControl(websocket.CloseMessage,
				websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""), deadline)
		}
	}
	_ = s.ws.Close()
}

// ---- reader ----

func (s *session) readLoop() {
	var endErr error
	defer func() {
		s.terminate(endErr)
		<-s.writerDone
		s.log.Debug("connection closed", "socketId", s.socketID, "reason", s.Err())
		// The last slot of events is kept for this (see push): it never blocks.
		s.events <- protocol.Event{Name: protocol.EvDisconnect}
		close(s.events)
		close(s.done)
	}()

	s.ws.SetReadLimit(readLimit)
	heartbeat := s.pingInterval + s.pingTimeout
	for {
		// Any frame proves the server alive (engine.io-client resets its ping
		// timer on every packet); nothing for pingInterval+pingTimeout means
		// the server's next ping is overdue by its own timeout.
		_ = s.ws.SetReadDeadline(time.Now().Add(heartbeat))
		mt, data, err := s.ws.ReadMessage()
		if err != nil {
			endErr = s.readError(err, heartbeat)
			return
		}
		if mt == websocket.BinaryMessage || len(data) == 0 {
			// A binary attachment (the game never sends one; its event went
			// out with the placeholder as Data), or nothing at all.
			continue
		}
		switch data[0] {
		case enginePing:
			pong := append([]byte{enginePong}, data[1:]...)
			select {
			case s.pong <- pong:
			default: // one is already waiting to go
			}
		case engineMessage:
			p, err := parsePacket(data[1:])
			if err != nil {
				endErr = err
				return
			}
			if stop, err := s.handle(p); stop {
				endErr = err
				return
			}
		case engineClose:
			endErr = ErrServerClose
			return
		default:
			// open (again), pong, upgrade, noop: nothing for a client to do.
		}
	}
}

// readError names why the read failed: our own close, the heartbeat
// deadline, or the network's error.
func (s *session) readError(err error, heartbeat time.Duration) error {
	select {
	case <-s.closing:
		return nil // terminate has already fixed the reason
	default:
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return fmt.Errorf("%w for %s", ErrHeartbeatTimeout, heartbeat)
	}
	return fmt.Errorf("connection: read: %w", err)
}

// handle acts on one Socket.IO packet. stop ends the reader with err.
func (s *session) handle(p packet) (stop bool, err error) {
	if p.nsp != "" {
		return false, nil // not the default namespace: never ours
	}
	switch p.typ {
	case packetEvent, packetBinaryEvent:
		ev, ok := eventOf(p.data)
		if !ok {
			return false, nil
		}
		return s.push(ev)
	case packetAck, packetBinaryAck:
		if p.id < 0 {
			return false, nil
		}
		var args []json.RawMessage // `43<id>` with no array at all: an empty answer
		if len(p.data) > 0 {
			if err := json.Unmarshal(p.data, &args); err != nil {
				return false, nil
			}
		}
		var first json.RawMessage
		if len(args) > 0 {
			first = args[0]
		}
		s.mu.Lock()
		if ch := s.pending[p.id]; ch != nil {
			delete(s.pending, p.id)
			ch <- first // buffered 1 and resolved once: never blocks
		}
		s.mu.Unlock()
		return false, nil
	case packetDisconnect:
		return true, ErrServerDisconnect
	case packetConnectError:
		ce := connectError(p.data)
		data, _ := json.Marshal(struct {
			Message string `json:"message"`
		}{ce.Message})
		if stop, err := s.push(protocol.Event{Name: protocol.EvConnectError, Data: data}); stop {
			return true, err
		}
		return true, ce
	default:
		// A second CONNECT ack: nothing to do.
		return false, nil
	}
}

// eventOf reads `["name", arg, …]`: the name and its first argument (nil
// when the event carried none).
func eventOf(data []byte) (protocol.Event, bool) {
	var args []json.RawMessage
	if err := json.Unmarshal(data, &args); err != nil || len(args) == 0 {
		return protocol.Event{}, false
	}
	var name string
	if err := json.Unmarshal(args[0], &name); err != nil {
		return protocol.Event{}, false
	}
	ev := protocol.Event{Name: name}
	if len(args) > 1 {
		ev.Data = args[1]
	}
	return ev, true
}

// push delivers one event in order. Events holds at most bufferLimit
// undelivered ones (its last slot is kept for the final EvDisconnect); on a
// full buffer the reader waits for the consumer up to stallTimeout, then
// ends the session with ErrSlowConsumer. The reader is the only sender, so
// room it has seen cannot be taken before it sends.
func (s *session) push(ev protocol.Event) (stop bool, err error) {
	if len(s.events) < s.bufferLimit {
		s.events <- ev
		return false, nil
	}
	stall := time.NewTimer(s.stallTimeout)
	defer stall.Stop()
	poll := time.NewTicker(stallPoll)
	defer poll.Stop()
	for {
		select {
		case <-s.closing:
			return true, nil
		case <-stall.C:
			s.log.Warn("event consumer stalled; closing the connection",
				"socketId", s.socketID, "buffered", len(s.events), "event", ev.Name)
			return true, fmt.Errorf("%w: %d events undelivered for %s", ErrSlowConsumer, len(s.events), s.stallTimeout)
		case <-poll.C:
			if len(s.events) < s.bufferLimit {
				s.events <- ev
				return false, nil
			}
		}
	}
}

// ---- packet parsing ----

// packet is one decoded Socket.IO packet (after the Engine.IO "4").
type packet struct {
	typ         byte
	attachments int    // binary packets only
	nsp         string // "" for the default namespace
	id          int    // -1 when absent
	data        []byte // the JSON, or nil
}

// parsePacket follows socket.io-parser's decodeString: the type digit; for a
// binary packet "<n>-"; an optional "/nsp,"; optional ack-id digits; the
// JSON payload.
func parsePacket(frame []byte) (packet, error) {
	p := packet{id: -1}
	if len(frame) == 0 {
		return p, fmt.Errorf("%w: empty Socket.IO packet", ErrProtocol)
	}
	p.typ = frame[0]
	if p.typ < packetConnect || p.typ > packetBinaryAck {
		return p, fmt.Errorf("%w: unknown Socket.IO packet type %q", ErrProtocol, p.typ)
	}
	rest := frame[1:]
	if p.typ == packetBinaryEvent || p.typ == packetBinaryAck {
		dash := bytes.IndexByte(rest, '-')
		if dash <= 0 {
			return p, fmt.Errorf("%w: binary packet without an attachment count", ErrProtocol)
		}
		n, err := strconv.Atoi(string(rest[:dash]))
		if err != nil || n < 0 {
			return p, fmt.Errorf("%w: bad attachment count %q", ErrProtocol, rest[:dash])
		}
		p.attachments = n
		rest = rest[dash+1:]
	}
	if len(rest) > 0 && rest[0] == '/' {
		comma := bytes.IndexByte(rest, ',')
		if comma < 0 {
			p.nsp, rest = string(rest), nil
		} else {
			p.nsp, rest = string(rest[:comma]), rest[comma+1:]
		}
		if p.nsp == "/" {
			p.nsp = ""
		}
	}
	i := 0
	for i < len(rest) && rest[i] >= '0' && rest[i] <= '9' {
		i++
	}
	if i > 0 {
		if i > 18 {
			return p, fmt.Errorf("%w: ack id too long", ErrProtocol)
		}
		p.id, _ = strconv.Atoi(string(rest[:i]))
		rest = rest[i:]
	}
	if len(rest) > 0 {
		if !json.Valid(rest) {
			return p, fmt.Errorf("%w: invalid JSON in a %q packet", ErrProtocol, p.typ)
		}
		p.data = rest
	}
	return p, nil
}

// clip shortens a frame for an error message.
func clip(b []byte) []byte {
	if len(b) > 64 {
		return b[:64]
	}
	return b
}
