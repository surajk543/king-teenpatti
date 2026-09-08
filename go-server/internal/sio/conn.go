package sio

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

// inbound is one item on the connection's dispatch queue: a decoded Socket.IO
// packet, or the reader's notice that the transport is gone (closed=true,
// with the reason it worked out). Queuing the notice behind the packets
// keeps Node's ordering — a "41" followed by the TCP close still reports
// ReasonClientNamespaceDisc, not ReasonTransportClose.
type inbound struct {
	packet Packet
	closed bool
	reason string
}

// conn is one Engine.IO connection (Node's engine Socket + socket.io Client
// pair). Three goroutines serve it:
//
//   - readLoop reads WebSocket frames, answers the engine layer (pongs,
//     protocol violations) and queues Socket.IO packets;
//   - writeLoop is the single writer (gorilla allows one) fed by a bounded
//     queue; it also runs the server-initiated heartbeat and the connect
//     timeout, so a handler that blocks never stalls a ping or a pong;
//   - dispatchLoop runs CONNECT (middleware), EVENT (handlers) and
//     DISCONNECT one at a time, in arrival order, and finally the disconnect
//     callbacks.
//
// terminate(reason) is the single close path: the first caller fixes the
// reason, arms the force-close watchdog and closes `closed`; the writer then
// flushes (for graceful reasons, bounded), sends a close frame and closes the
// WebSocket, which unblocks the reader; the dispatcher finishes its current
// packet, runs the disconnect callbacks with the fixed reason and exits. The
// reader never terminates directly: it records its reason and queues a
// closed notice behind the packets it has already read, so a "41" is still
// dispatched and a write failing after the peer left cannot override it.
type conn struct {
	srv  *Server
	ws   *websocket.Conn
	sid  string
	base Handshake // Query, Headers, Address, Time — Auth is per CONNECT

	outbound chan []byte
	inbound  chan inbound
	pong     chan struct{}

	closeOnce sync.Once
	closed    chan struct{}
	reason    string // written once in closeOnce before close(closed)
	// forceClose hard-closes the WebSocket if the writer has not finished
	// the close path within the drain limit — a write already blocked on a
	// client that stopped reading would otherwise hold the connection (and a
	// Server.Shutdown) for the whole WriteTimeout. Armed in terminate, before
	// close(closed); stopped by closeTransport.
	forceClose *time.Timer

	// readDone is set by readLoop the moment the transport fails, before the
	// closed notice is queued — Node's "next called after client was closed"
	// check in Namespace._add reads the same fact. readReason (written
	// before readDone, read only after it) is the reason the reader worked
	// out; a write that fails afterwards must not replace it.
	readDone   atomic.Bool
	readReason string
	// connected records that a Socket.IO CONNECT completed at least once
	// (socket.io clears its connectTimeout at that point and never re-arms).
	connected atomic.Bool

	// dispatcher-owned
	socket *Socket // the live namespace socket, nil when none
}

func newConn(srv *Server, ws *websocket.Conn, r *http.Request, q url.Values) *conn {
	return &conn{
		srv: srv,
		ws:  ws,
		sid: newSID(),
		base: Handshake{
			Query:   q,
			Headers: r.Header.Clone(),
			Address: hostOf(r.RemoteAddr),
			Time:    srv.opts.Now(),
		},
		outbound: make(chan []byte, srv.opts.WriteQueueSize),
		inbound:  make(chan inbound, 64),
		pong:     make(chan struct{}, 1),
		closed:   make(chan struct{}),
	}
}

// terminate fixes the disconnect reason and starts closing. Idempotent; the
// first reason wins. Safe from any goroutine; never called with s.mu held.
func (c *conn) terminate(reason string) {
	c.closeOnce.Do(func() {
		c.reason = reason
		// gorilla's Close may run concurrently with a blocked writer; it
		// makes that write fail, which is the point.
		c.forceClose = time.AfterFunc(c.closeLimit()+time.Second, func() { _ = c.ws.Close() })
		close(c.closed)
		c.srv.removeConn(c)
	})
}

// closeLimit bounds the flush before a graceful close: min(WriteTimeout,
// maxCloseDrain).
func (c *conn) closeLimit() time.Duration {
	limit := c.srv.opts.WriteTimeout
	if limit > maxCloseDrain {
		limit = maxCloseDrain
	}
	return limit
}

func (c *conn) isClosed() bool {
	select {
	case <-c.closed:
		return true
	default:
		return false
	}
}

// transportGone is what Node's `client.conn.readyState !== "open"` reports:
// the WebSocket has failed or the close path has started.
func (c *conn) transportGone() bool {
	return c.readDone.Load() || c.isClosed()
}

// enqueue queues one frame for the writer. It never blocks: a full queue
// means the client is not draining, and Node's answer to an unbounded
// backlog was to keep buffering — ours is to close with
// ReasonTransportError. Returns false when the frame will not be sent.
func (c *conn) enqueue(frame []byte) bool {
	select {
	case <-c.closed:
		return false
	default:
	}
	select {
	case c.outbound <- frame:
		return true
	case <-c.closed:
		return false
	default:
		c.srv.log.Warn("sio: write queue overflow, closing connection", "sid", c.sid, "queue", cap(c.outbound))
		c.terminate(c.writeFailureReason())
		return false
	}
}

// writeFailureReason is the disconnect reason for a failed or overflowing
// write. Once the reader has already found the transport gone (the peer sent
// a close frame, the TCP connection dropped), the frames still being written
// by emitters racing that discovery fail too — gorilla refuses writes after a
// close frame has been answered — and those failures must not turn a
// "transport close" (or a "41" still waiting in the dispatch queue) into a
// "transport error". Node reports the reader's reason because its close
// event fires before the failed writes are noticed.
func (c *conn) writeFailureReason() string {
	if c.readDone.Load() {
		return c.readReason
	}
	return ReasonTransportError
}

// ---- writer + heartbeat ----

// writeLoop is the only goroutine that writes to the WebSocket. Heartbeat
// (engine.io/build/socket.js schedulePing/resetPingTimeout): PingInterval
// after OPEN send "2" and arm PingTimeout; a "3" clears that and re-arms the
// interval; the timeout fires → ReasonPingTimeout. Connect timeout
// (socket.io/dist/client.js setup): no CONNECT within ConnectTimeout → close.
func (c *conn) writeLoop() {
	defer c.srv.wg.Done()
	opts := c.srv.opts

	pingTimer := time.NewTimer(opts.PingInterval)
	defer pingTimer.Stop()
	var pongTimer *time.Timer
	var pongC <-chan time.Time
	stopPongTimer := func() {
		if pongTimer != nil {
			pongTimer.Stop()
			pongTimer, pongC = nil, nil
		}
	}
	defer stopPongTimer()
	connectTimer := time.NewTimer(opts.ConnectTimeout)
	defer connectTimer.Stop()
	connectC := connectTimer.C

	for {
		select {
		case frame := <-c.outbound:
			if !c.write(frame) {
				c.closeTransport()
				return
			}
		case <-pingTimer.C:
			if !c.write([]byte{EnginePacketPing}) {
				c.closeTransport()
				return
			}
			// Node: after the ping no further ping is scheduled until a pong
			// arrives (schedulePing runs from the pong handler only).
			stopPongTimer()
			pongTimer = time.NewTimer(opts.PingTimeout)
			pongC = pongTimer.C
		case <-pongC:
			c.terminate(ReasonPingTimeout)
			c.closeTransport()
			return
		case <-c.pong:
			stopPongTimer()
			pingTimer.Reset(opts.PingInterval)
		case <-connectC:
			connectC = nil
			if !c.connected.Load() {
				// Node: "no namespace joined yet, close the client" →
				// client.close() → "forced server close" (no socket observes it).
				c.terminate(ReasonForcedServerClose)
				c.closeTransport()
				return
			}
		case <-c.closed:
			c.closeTransport()
			return
		}
	}
}

// write sends one text frame under WriteTimeout. A failure closes the
// connection with ReasonTransportError — unless the reader already knows the
// transport is gone, in which case the writer just stops and leaves the
// reason (and the packets still queued for dispatch, a client's "41" among
// them) to the reader's closed notice; see writeFailureReason.
func (c *conn) write(frame []byte) bool {
	_ = c.ws.SetWriteDeadline(time.Now().Add(c.srv.opts.WriteTimeout))
	if err := c.ws.WriteMessage(websocket.TextMessage, frame); err != nil {
		if !c.readDone.Load() {
			c.terminate(ReasonTransportError)
		}
		return false
	}
	return true
}

// closeTransport waits for the disconnect reason to be fixed (terminate may
// still be on its way from the dispatcher when a write has just failed),
// flushes the queue for graceful closes (Node's engine `close()` waits for
// the write buffer to drain — here bounded by min(WriteTimeout, maxCloseDrain)),
// sends a close frame and closes the WebSocket. The reader unblocks on the
// closed socket.
func (c *conn) closeTransport() {
	<-c.closed // terminate has run: c.reason and forceClose are fixed
	defer c.forceClose.Stop()
	if drainOnClose(c.reason) {
		deadline := time.Now().Add(c.closeLimit())
	drain:
		for time.Now().Before(deadline) {
			select {
			case frame := <-c.outbound:
				_ = c.ws.SetWriteDeadline(deadline)
				if err := c.ws.WriteMessage(websocket.TextMessage, frame); err != nil {
					break drain
				}
			default:
				break drain
			}
		}
	}
	_ = c.ws.WriteControl(websocket.CloseMessage,
		websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""),
		time.Now().Add(time.Second))
	_ = c.ws.Close()
}

// drainOnClose: only closes the server chose deserve a flush; after a
// transport failure or a missed pong there is nobody to flush to.
func drainOnClose(reason string) bool {
	switch reason {
	case ReasonServerNamespaceDisc, ReasonServerShuttingDown, ReasonForcedClose, ReasonForcedServerClose:
		return true
	}
	return false
}

// ---- reader ----

// readLoop is the engine layer (engine.io/build/socket.js onPacket +
// engine.io-parser decodePacket + socket.io/dist/client.js ondata).
func (c *conn) readLoop() {
	defer c.srv.wg.Done()
	c.ws.SetReadLimit(c.srv.opts.MaxPayload)
	for {
		mt, data, err := c.ws.ReadMessage()
		if err != nil {
			c.readFailed(readErrorReason(err))
			return
		}
		if mt == websocket.BinaryMessage {
			// socket.io-parser: "got binary data when not reconstructing a
			// packet" → client.onerror → conn.close() → "forced close".
			c.readFailed(ReasonForcedClose)
			return
		}
		if len(data) == 0 {
			// engine.io-parser: unknown type "" → ERROR_PACKET → "parse error".
			c.readFailed(ReasonParseError)
			return
		}
		switch data[0] {
		case EnginePacketPing:
			// v4: the server pings; a client ping is an "invalid heartbeat
			// direction" transport error.
			c.readFailed(ReasonTransportError)
			return
		case EnginePacketPong:
			select {
			case c.pong <- struct{}{}:
			default:
			}
		case EnginePacketMessage:
			p, err := DecodePacket(data[1:])
			if err != nil {
				c.readFailed(ReasonForcedClose)
				return
			}
			if !c.pushPacket(p) {
				return
			}
		case EnginePacketOpen, EnginePacketClose, EnginePacketUpgrade, EnginePacketNoop:
			// engine.io's onPacket has no case for these: ignored.
		case 'b':
			// base64 binary payload → binary data to the socket.io decoder.
			c.readFailed(ReasonForcedClose)
			return
		default:
			c.readFailed(ReasonParseError)
			return
		}
	}
}

// readFailed is the reader's single exit path: record the reason, publish
// that the transport is gone (readDone), then queue the closed notice behind
// any packets already read so the dispatcher sees them in order.
func (c *conn) readFailed(reason string) {
	c.readReason = reason
	c.readDone.Store(true)
	c.pushClosed(reason)
}

// readErrorReason maps a gorilla read error to engine.io's transport reason:
// a close frame or a plain EOF is "transport close"; a frame over MaxPayload
// (ErrReadLimit), a protocol violation or a network error is "transport
// error" (ws emits 'error' before 'close' in those cases).
func readErrorReason(err error) string {
	var ce *websocket.CloseError
	if errors.As(err, &ce) {
		return ReasonTransportClose
	}
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, net.ErrClosed) {
		return ReasonTransportClose
	}
	return ReasonTransportError
}

func (c *conn) pushPacket(p Packet) bool {
	select {
	case c.inbound <- inbound{packet: p}:
		return true
	case <-c.closed:
		return false
	}
}

func (c *conn) pushClosed(reason string) {
	select {
	case c.inbound <- inbound{closed: true, reason: reason}:
	case <-c.closed:
	}
}

// ---- dispatcher ----

// dispatchLoop runs the Socket.IO layer serially for this connection.
func (c *conn) dispatchLoop() {
	defer c.srv.wg.Done()
	defer c.finish()
	for {
		// A close decided elsewhere (ping timeout, write failure, Disconnect,
		// Server.Close) wins over queued packets: Node ignores packets
		// received after disconnection.
		if c.isClosed() {
			return
		}
		select {
		case <-c.closed:
			return
		case in := <-c.inbound:
			if in.closed {
				c.terminate(in.reason)
				return
			}
			c.handle(in.packet)
		}
	}
}

// finish runs after the loop: the transport is gone, so the live socket (if
// any) gets its disconnect callbacks with the fixed reason.
func (c *conn) finish() {
	<-c.closed
	if sock := c.socket; sock != nil {
		c.socket = nil
		sock.close(c.reason)
	}
}

// handle is socket.io/dist/client.js `ondecoded` + socket.js `_onpacket`.
func (c *conn) handle(p Packet) {
	sock := c.socket
	if sock != nil && !sock.Connected() {
		// Disconnected out of band (Disconnect(false), or a "41" handled
		// earlier): the namespace has no socket again.
		sock, c.socket = nil, nil
	}
	defaultNsp := p.Nsp == "" || p.Nsp == "/"

	switch p.Type {
	case PacketConnect:
		if !defaultNsp {
			// Only "/" exists: `44/<nsp>,{"message":"Invalid namespace"}`.
			body, _ := marshalJSON(ConnectError{Message: MsgInvalidNamespace})
			c.enqueue(messageFrame(Packet{Type: PacketConnectError, ID: -1, Nsp: p.Nsp, Data: body}))
			return
		}
		if sock != nil {
			// "invalid state": a CONNECT while connected → client.close().
			c.terminate(ReasonForcedServerClose)
			return
		}
		c.connectNamespace(p)
	case PacketEvent:
		if sock == nil || !defaultNsp {
			c.terminate(ReasonForcedServerClose)
			return
		}
		c.dispatchEvent(sock, p)
	case PacketAck:
		if sock == nil || !defaultNsp {
			c.terminate(ReasonForcedServerClose)
			return
		}
		// The server never awaits client acks: ignored (Node: "bad ack").
	case PacketDisconnect:
		if sock == nil || !defaultNsp {
			c.terminate(ReasonForcedServerClose)
			return
		}
		// Transport stays open; the client closes it (or CONNECTs again).
		c.socket = nil
		sock.close(ReasonClientNamespaceDisc)
	default:
		// CONNECT_ERROR from a client: "invalid state" in either state.
		c.terminate(ReasonForcedServerClose)
	}
}

// connectNamespace is Namespace._add: build the socket, run the middleware
// chain, answer CONNECT_ERROR or CONNECT ack, then fire OnConnection.
func (c *conn) connectNamespace(p Packet) {
	hs := c.base
	if len(p.Data) > 0 {
		var auth map[string]json.RawMessage
		if err := json.Unmarshal(p.Data, &auth); err != nil {
			// DecodePacket already required an object; defensive only.
			c.terminate(ReasonForcedClose)
			return
		}
		hs.Auth = auth
	}
	// socket.io 4 never reuses the Engine.IO sid for the namespace socket id
	// (socket.js: "don't reuse the Engine.IO id because it's sensitive
	// information"); every CONNECT gets a fresh base64id.
	sock := newSocket(newSID(), c, hs)

	for _, mw := range c.srv.middlewareChain() {
		if err := mw(sock); err != nil {
			if c.transportGone() {
				return // Node: "next called after client was closed - ignoring socket"
			}
			body, _ := marshalJSON(ConnectError{Message: err.Error()})
			c.enqueue(messageFrame(Packet{Type: PacketConnectError, ID: -1, Data: body}))
			return
		}
	}
	if c.transportGone() {
		return
	}
	sock.connect()
	c.socket = sock
	c.connected.Store(true)
	ack, _ := marshalJSON(ConnectAck{SID: sock.id})
	c.enqueue(messageFrame(Packet{Type: PacketConnect, ID: -1, Data: ack}))
	if fn := c.srv.connectionHandler(); fn != nil {
		fn(sock)
	}
}

// dispatchEvent is Socket.onevent: look the handler up by the first array
// element, hand it the remaining elements and, when the packet carries an id,
// an ack function. Unknown events are ignored — never acked — like Node's
// EventEmitter (spec §4).
func (c *conn) dispatchEvent(sock *Socket, p Packet) {
	if p.Data == nil {
		return // `42` alone: an empty args array nobody listens to
	}
	var elems []json.RawMessage
	if err := json.Unmarshal(p.Data, &elems); err != nil || len(elems) == 0 {
		return
	}
	var name string
	if err := json.Unmarshal(elems[0], &name); err != nil {
		return // a numeric event name matches no handler
	}
	h := sock.handler(name)
	if h == nil {
		return
	}
	var ack AckFunc
	if p.ID >= 0 {
		ack = c.ackFunc(p.ID)
	}
	h(elems[1:], ack)
}

// ackFunc is Socket.ack(id): sends `43<id>[args...]` once; later calls are
// dropped ("prevent double callbacks"). Node writes the ack even after a
// namespace disconnect as long as the transport is open, so this goes to the
// connection queue directly.
func (c *conn) ackFunc(id int) AckFunc {
	var once sync.Once
	return func(payload ...any) {
		once.Do(func() {
			frame, err := ackFrame(id, payload)
			if err != nil {
				c.srv.log.Error("sio: ack payload not serialisable", "error", err.Error())
				return
			}
			c.enqueue(frame)
		})
	}
}

// messageFrame is "4" + EncodePacket(p).
func messageFrame(p Packet) []byte {
	body := EncodePacket(p)
	frame := make([]byte, 0, 1+len(body))
	frame = append(frame, EnginePacketMessage)
	return append(frame, body...)
}
