// Package testclient is a minimal Socket.IO v5 / Engine.IO v4 client over one
// WebSocket, for tests of the Go server: connect with an auth token, emit with
// or without an ack, and record every server event by name — the Go
// counterpart of the `openClient` helpers in server/test/*.test.js and of the
// hand-rolled PortedSocketIOClient in test/helpers/csharpJsonPort.js.
//
// Frames (all text): Engine.IO `<type><data>` — 0 open, 2 ping (answered with
// 3), 4 message; Socket.IO inside a message — 40{auth} CONNECT, 40{"sid"}
// CONNECT ack, 41 DISCONNECT, 42[…] / 42<id>[…] EVENT, 43<id>[…] ACK,
// 44{"message"} CONNECT_ERROR.
package testclient

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// Event is one server → client EVENT as received.
type Event struct {
	Name    string
	Payload json.RawMessage // the second array element; nil when the event carried none
}

// ConnectError is the CONNECT_ERROR the server answered the handshake with;
// Message is the auth code (missing_token, invalid_session, unknown_user,
// unauthorized).
type ConnectError struct {
	Message string `json:"message"`
}

func (e *ConnectError) Error() string { return "connect_error: " + e.Message }

// ErrNoAck is returned by Request when the server did not acknowledge in time
// (an unknown event is never acked; Node's clients hang the same way).
var ErrNoAck = errors.New("testclient: no ack")

// NoPayload makes Request/Emit send the event with no argument at all
// (`42["event"]`), where nil would send `42["event",null]`.
type NoPayload struct{}

// Client is one connected socket.
type Client struct {
	conn *websocket.Conn

	writeMu sync.Mutex

	mu         sync.Mutex
	changed    chan struct{}
	events     []Event
	frames     []string
	acks       map[int]chan json.RawMessage
	nextAck    int
	sid        string
	socketID   string
	connected  bool
	connectErr *ConnectError
	closed     bool
	closeErr   error
	gotConnect chan struct{}
	gotOpen    chan struct{}
}

// Dial opens the WebSocket at <baseURL>/socket.io/?EIO=4&transport=websocket,
// waits for the Engine.IO OPEN frame, sends CONNECT with {"token": token}
// (omitting the auth object when token is "" and rawAuth is nil) and waits
// for the CONNECT ack. A CONNECT_ERROR is returned as *ConnectError together
// with the client, so the caller can inspect what else arrived and Close it.
func Dial(ctx context.Context, baseURL, token string) (*Client, error) {
	var auth json.RawMessage
	if token != "" {
		auth, _ = json.Marshal(map[string]string{"token": token})
	}
	return DialAuth(ctx, baseURL, auth)
}

// DialAuth is Dial with an arbitrary CONNECT auth object (nil → bare "40").
func DialAuth(ctx context.Context, baseURL string, auth json.RawMessage) (*Client, error) {
	return dial(ctx, baseURL, "", auth)
}

// DialQuery is Dial with extra query parameters on the upgrade URL (for the
// legacy ?token= fallback) and no auth object.
func DialQuery(ctx context.Context, baseURL, query string) (*Client, error) {
	return dial(ctx, baseURL, query, nil)
}

func dial(ctx context.Context, baseURL, extraQuery string, auth json.RawMessage) (*Client, error) {
	wsURL := strings.Replace(strings.Replace(baseURL, "https://", "wss://", 1), "http://", "ws://", 1)
	wsURL = strings.TrimRight(wsURL, "/") + "/socket.io/?EIO=4&transport=websocket"
	if extraQuery != "" {
		wsURL += "&" + extraQuery
	}
	dialer := websocket.Dialer{HandshakeTimeout: 5 * time.Second}
	conn, resp, err := dialer.DialContext(ctx, wsURL, http.Header{})
	if err != nil {
		if resp != nil {
			return nil, fmt.Errorf("testclient: upgrade failed: %s: %w", resp.Status, err)
		}
		return nil, fmt.Errorf("testclient: dial: %w", err)
	}
	c := &Client{
		conn:       conn,
		changed:    make(chan struct{}),
		acks:       make(map[int]chan json.RawMessage),
		gotConnect: make(chan struct{}),
		gotOpen:    make(chan struct{}),
	}
	go c.readLoop()

	select {
	case <-c.gotOpen:
	case <-ctx.Done():
		c.Close()
		return c, ctx.Err()
	case <-time.After(5 * time.Second):
		c.Close()
		return c, errors.New("testclient: no OPEN frame")
	}

	// Engine.IO MESSAGE ("4") carrying a Socket.IO CONNECT ("0") → "40{auth}".
	connect := "40"
	if auth != nil {
		connect += string(auth)
	}
	if err := c.writeFrame(connect); err != nil {
		c.Close()
		return c, err
	}
	select {
	case <-c.gotConnect:
	case <-ctx.Done():
		c.Close()
		return c, ctx.Err()
	case <-time.After(5 * time.Second):
		c.Close()
		return c, errors.New("testclient: no CONNECT reply")
	}
	c.mu.Lock()
	cerr := c.connectErr
	connected := c.connected
	closed := c.closed
	c.mu.Unlock()
	if cerr != nil {
		return c, cerr
	}
	if !connected || closed {
		return c, errors.New("testclient: transport closed before the CONNECT reply")
	}
	return c, nil
}

// SID is the Engine.IO session id from the OPEN frame.
func (c *Client) SID() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.sid
}

// SocketID is the namespace socket id from the CONNECT ack.
func (c *Client) SocketID() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.socketID
}

// Connected reports whether the namespace connection is open.
func (c *Client) Connected() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.connected && !c.closed
}

// Closed reports whether the transport has gone (either side).
func (c *Client) Closed() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.closed
}

// Close closes the WebSocket (Node: socket.disconnect() also sends "41" first;
// use Disconnect for that).
func (c *Client) Close() {
	c.writeMu.Lock()
	_ = c.conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""), time.Now().Add(time.Second))
	c.writeMu.Unlock()
	_ = c.conn.Close()
}

// Disconnect sends the Socket.IO DISCONNECT packet ("41", what
// socket.io-client's socket.disconnect() sends) and closes the transport.
func (c *Client) Disconnect() {
	_ = c.writeFrame("41")
	time.Sleep(20 * time.Millisecond)
	c.Close()
}

// WaitClosed blocks until the transport is gone or the timeout passes.
func (c *Client) WaitClosed(timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for {
		c.mu.Lock()
		closed := c.closed
		ch := c.changed
		c.mu.Unlock()
		if closed {
			return true
		}
		select {
		case <-ch:
		case <-time.After(time.Until(deadline)):
			return false
		}
	}
}

// Emit sends an EVENT without asking for an ack. payload may be a Go value
// (marshalled), a json.RawMessage (sent verbatim) or NoPayload.
func (c *Client) Emit(event string, payload any) error {
	data, err := eventData(event, payload)
	if err != nil {
		return err
	}
	return c.writeFrame("42" + data)
}

// SendRaw writes one text frame verbatim — Engine.IO type digit included, so
// `42["x"]` is an EVENT and `2` a client ping — for tests that need to put
// hostile or malformed bytes on the wire. Nothing is decoded or validated on
// the way out; any ACK the server answers with an id this client did not
// allocate is recorded in Frames() but not routed to Request.
func (c *Client) SendRaw(frame string) error {
	return c.writeFrame(frame)
}

// Request sends an EVENT with an ack id and returns the first ack argument
// (the server always acks with exactly one object). ErrNoAck after timeout.
func (c *Client) Request(event string, payload any, timeout time.Duration) (json.RawMessage, error) {
	data, err := eventData(event, payload)
	if err != nil {
		return nil, err
	}
	ch := make(chan json.RawMessage, 1)
	c.mu.Lock()
	id := c.nextAck
	c.nextAck++
	c.acks[id] = ch
	c.mu.Unlock()
	if err := c.writeFrame("42" + strconv.Itoa(id) + data); err != nil {
		return nil, err
	}
	select {
	case ack := <-ch:
		return ack, nil
	case <-time.After(timeout):
		c.mu.Lock()
		delete(c.acks, id)
		c.mu.Unlock()
		return nil, ErrNoAck
	}
}

// Ack is a decoded `{ok, code, message}` ack.
type Ack struct {
	OK      bool            `json:"ok"`
	Code    string          `json:"code"`
	Message string          `json:"message"`
	Raw     json.RawMessage `json:"-"`
}

// Call is Request plus decoding of the common ack fields; Raw keeps the whole
// object for event-specific fields.
func (c *Client) Call(event string, payload any, timeout time.Duration) (Ack, error) {
	raw, err := c.Request(event, payload, timeout)
	if err != nil {
		return Ack{}, err
	}
	var ack Ack
	if err := json.Unmarshal(raw, &ack); err != nil {
		return Ack{Raw: raw}, fmt.Errorf("testclient: ack is not an object: %s", raw)
	}
	ack.Raw = raw
	return ack, nil
}

// Mark returns the number of events received so far, for Since.
func (c *Client) Mark() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.events)
}

// Events returns every event received so far, in arrival order.
func (c *Client) Events() []Event {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]Event(nil), c.events...)
}

// Since returns the events received after a Mark.
func (c *Client) Since(mark int) []Event {
	c.mu.Lock()
	defer c.mu.Unlock()
	if mark > len(c.events) {
		return nil
	}
	return append([]Event(nil), c.events[mark:]...)
}

// Names returns the event names in evs, in order.
func Names(evs []Event) []string {
	out := make([]string, len(evs))
	for i, e := range evs {
		out[i] = e.Name
	}
	return out
}

// Frames returns every raw frame received, in order (for byte-level checks
// such as "no card codes ever reached this socket").
func (c *Client) Frames() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]string(nil), c.frames...)
}

// All returns the payloads of every event with that name.
func (c *Client) All(name string) []json.RawMessage {
	c.mu.Lock()
	defer c.mu.Unlock()
	var out []json.RawMessage
	for _, e := range c.events {
		if e.Name == name {
			out = append(out, e.Payload)
		}
	}
	return out
}

// Last returns the most recent payload of that event, if any.
func (c *Client) Last(name string) (json.RawMessage, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for i := len(c.events) - 1; i >= 0; i-- {
		if c.events[i].Name == name {
			return c.events[i].Payload, true
		}
	}
	return nil, false
}

// Wait resolves with the first event of that name (already received or
// arriving within timeout) whose payload satisfies pred (nil → any).
func (c *Client) Wait(name string, pred func(json.RawMessage) bool, timeout time.Duration) (json.RawMessage, error) {
	return c.WaitFrom(0, name, pred, timeout)
}

// WaitFrom is Wait restricted to events received after a Mark.
func (c *Client) WaitFrom(mark int, name string, pred func(json.RawMessage) bool, timeout time.Duration) (json.RawMessage, error) {
	deadline := time.Now().Add(timeout)
	scanned := mark
	for {
		c.mu.Lock()
		for ; scanned < len(c.events); scanned++ {
			e := c.events[scanned]
			if e.Name == name && (pred == nil || pred(e.Payload)) {
				c.mu.Unlock()
				return e.Payload, nil
			}
		}
		ch := c.changed
		closed := c.closed
		c.mu.Unlock()
		if closed {
			return nil, fmt.Errorf("testclient: connection closed while waiting for %s", name)
		}
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return nil, fmt.Errorf("testclient: timed out waiting for %s", name)
		}
		select {
		case <-ch:
		case <-time.After(remaining):
			return nil, fmt.Errorf("testclient: timed out waiting for %s", name)
		}
	}
}

// ---- wire ----

func eventData(event string, payload any) (string, error) {
	args := []any{event}
	switch p := payload.(type) {
	case NoPayload:
	case json.RawMessage:
		args = append(args, p)
	default:
		args = append(args, payload)
	}
	data, err := json.Marshal(args)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func (c *Client) writeFrame(frame string) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_ = c.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	return c.conn.WriteMessage(websocket.TextMessage, []byte(frame))
}

func (c *Client) notify() {
	close(c.changed)
	c.changed = make(chan struct{})
}

func (c *Client) readLoop() {
	defer func() {
		c.mu.Lock()
		c.closed = true
		c.connected = false
		for id, ch := range c.acks {
			close(ch)
			delete(c.acks, id)
		}
		c.notify()
		c.mu.Unlock()
		select {
		case <-c.gotOpen:
		default:
			close(c.gotOpen)
		}
		select {
		case <-c.gotConnect:
		default:
			close(c.gotConnect)
		}
	}()
	for {
		_, msg, err := c.conn.ReadMessage()
		if err != nil {
			c.mu.Lock()
			c.closeErr = err
			c.mu.Unlock()
			return
		}
		frame := string(msg)
		c.mu.Lock()
		c.frames = append(c.frames, frame)
		c.mu.Unlock()
		if frame == "" {
			continue
		}
		switch frame[0] {
		case '0':
			var open struct {
				SID string `json:"sid"`
			}
			_ = json.Unmarshal([]byte(frame[1:]), &open)
			c.mu.Lock()
			c.sid = open.SID
			c.mu.Unlock()
			close(c.gotOpen)
		case '2':
			_ = c.writeFrame("3")
		case '1':
			return
		case '4':
			c.handlePacket(frame[1:])
		}
	}
}

func (c *Client) handlePacket(pkt string) {
	if pkt == "" {
		return
	}
	switch pkt[0] {
	case '0': // CONNECT ack
		var ack struct {
			SID string `json:"sid"`
		}
		_ = json.Unmarshal([]byte(pkt[1:]), &ack)
		c.mu.Lock()
		c.socketID = ack.SID
		c.connected = true
		c.notify()
		c.mu.Unlock()
		close(c.gotConnect)
	case '4': // CONNECT_ERROR
		cerr := &ConnectError{}
		_ = json.Unmarshal([]byte(pkt[1:]), cerr)
		c.mu.Lock()
		c.connectErr = cerr
		c.notify()
		c.mu.Unlock()
		close(c.gotConnect)
	case '1': // DISCONNECT
		c.mu.Lock()
		c.connected = false
		c.notify()
		c.mu.Unlock()
	case '2', '3':
		rest := pkt[1:]
		i := 0
		for i < len(rest) && rest[i] >= '0' && rest[i] <= '9' {
			i++
		}
		idText, body := rest[:i], rest[i:]
		var args []json.RawMessage
		if err := json.Unmarshal([]byte(body), &args); err != nil {
			return
		}
		if pkt[0] == '3' {
			id, err := strconv.Atoi(idText)
			if err != nil {
				return
			}
			var first json.RawMessage
			if len(args) > 0 {
				first = args[0]
			}
			c.mu.Lock()
			ch := c.acks[id]
			delete(c.acks, id)
			c.mu.Unlock()
			if ch != nil {
				ch <- first
			}
			return
		}
		if len(args) == 0 {
			return
		}
		var name string
		if err := json.Unmarshal(args[0], &name); err != nil {
			return
		}
		ev := Event{Name: name}
		if len(args) > 1 {
			ev.Payload = args[1]
		}
		c.mu.Lock()
		c.events = append(c.events, ev)
		c.notify()
		c.mu.Unlock()
	}
}
