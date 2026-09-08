// Package sio is a minimal Socket.IO v5 / Engine.IO v4 SERVER over WebSocket
// only, built on github.com/gorilla/websocket. It exists so the Flutter client
// (socket_io_client, websocket transport), the browser client (socket.io
// 4.x) and the wire tests (server/test/socketProtocol.test.js and its
// PortedSocketIOClient) keep working unchanged against the Go server.
//
// Scope, deliberately small (PORT_PLAN.md decision 2):
//   - transport=websocket only; a handshake with transport=polling (or any
//     other) is answered HTTP 400 with the Engine.IO error body
//     {"code":0,"message":"Transport unknown"}; a request without EIO=4 gets
//     {"code":5,"message":"Unsupported protocol version"};
//   - the default namespace "/" only; a CONNECT to another namespace gets
//     CONNECT_ERROR {"message":"Invalid namespace"};
//   - text frames only: no binary attachments (types 5/6 are rejected with a
//     disconnect); the game never sends binary;
//   - server-initiated ping (Engine.IO v4): every PingInterval the server
//     sends "2" and expects "3" within PingTimeout, else it closes with
//     reason "ping timeout";
//   - rooms (Join/Leave/To) are in-process maps; no adapter.
//
// The frame grammar (all text):
//
//	Engine.IO packet  = <type digit><data>
//	  0 open   → 0{"sid":"…","upgrades":[],"pingInterval":20000,"pingTimeout":25000,"maxPayload":100000}
//	  1 close, 2 ping, 3 pong, 4 message, 5 upgrade, 6 noop
//	Socket.IO packet  = "4" + <type digit>[<nsp>,][<ackId>][<json>]
//	  40{"token":"…"}          client CONNECT with auth object (nsp "/" omitted)
//	  40{"sid":"…"}            server CONNECT ack
//	  41                       DISCONNECT
//	  42["event",payload]      EVENT (no ack)
//	  4217["event",payload]    EVENT with ack id 17
//	  4317[{"ok":true}]        ACK for id 17 — the args ARRAY
//	  44{"message":"…"}        CONNECT_ERROR
//
// Reference: socket.io-parser v4 (`Encoder.encodeAsString`) and
// engine.io-parser v5. The Node server's settings (index.js): pingInterval
// 20000, pingTimeout 25000, maxHttpBufferSize 1e5, cors origin from config.
package sio

// EngineIOVersion is the only EIO query value accepted.
const EngineIOVersion = "4"

// Engine.IO packet types (engine.io-parser).
const (
	EnginePacketOpen    byte = '0'
	EnginePacketClose   byte = '1'
	EnginePacketPing    byte = '2'
	EnginePacketPong    byte = '3'
	EnginePacketMessage byte = '4'
	EnginePacketUpgrade byte = '5'
	EnginePacketNoop    byte = '6'
)

// Socket.IO packet types (socket.io-parser PacketType).
const (
	PacketConnect      byte = '0'
	PacketDisconnect   byte = '1'
	PacketEvent        byte = '2'
	PacketAck          byte = '3'
	PacketConnectError byte = '4'
	PacketBinaryEvent  byte = '5'
	PacketBinaryAck    byte = '6'
)

// Engine.IO handshake error bodies (engine.io `Server.errors` /
// `errorMessages`), sent as JSON with HTTP 400.
const (
	ErrorCodeUnknownTransport = 0
	ErrorCodeUnknownSID       = 1
	ErrorCodeBadHandshake     = 2
	ErrorCodeBadRequest       = 3
	ErrorCodeForbidden        = 4
	ErrorCodeUnsupportedProto = 5
)

// ErrorMessages maps the codes above to engine.io's exact strings.
var ErrorMessages = map[int]string{
	ErrorCodeUnknownTransport: "Transport unknown",
	ErrorCodeUnknownSID:       "Session ID unknown",
	ErrorCodeBadHandshake:     "Bad handshake method",
	ErrorCodeBadRequest:       "Bad request",
	ErrorCodeForbidden:        "Forbidden",
	ErrorCodeUnsupportedProto: "Unsupported protocol version",
}

// HandshakeError is the 400 body: {"code":0,"message":"Transport unknown"}.
type HandshakeError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// OpenPacket is the JSON after the "0" of the Engine.IO OPEN frame.
type OpenPacket struct {
	SID          string   `json:"sid"`
	Upgrades     []string `json:"upgrades"` // always [] — marshal an empty non-nil slice
	PingInterval int64    `json:"pingInterval"`
	PingTimeout  int64    `json:"pingTimeout"`
	MaxPayload   int64    `json:"maxPayload"`
}

// ConnectAck is the JSON after "40" the server sends on a successful CONNECT.
type ConnectAck struct {
	SID string `json:"sid"`
}

// ConnectError is the JSON after "44". Node's `next(new Error(code))` in the
// io.use middleware produces {"message":"<code>"} — the Flutter client shows
// `message`, the protocol test matches it against
// /invalid_session|unauthorized|unknown_user/. Data is present only when the
// middleware attached `err.data` (the game never does).
type ConnectError struct {
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

// Packet is one decoded Socket.IO packet (namespace "/" implied).
type Packet struct {
	Type byte
	// ID is the ack id for EVENT/ACK packets, or -1 when absent.
	ID int
	// Data is the raw JSON payload: for CONNECT the auth object (may be
	// empty), for EVENT the args array `["event", ...payload]`, for ACK the
	// args array, for CONNECT_ERROR the error object.
	Data []byte
}

// EncodePacket renders p as the Socket.IO part of a message frame — that is,
// WITHOUT the leading Engine.IO "4"; the transport adds it. Examples: Packet
// {Type: PacketEvent, ID: -1, Data: `["x",{}]`} → `2["x",{}]`; {PacketAck,
// 17, `[{"ok":true}]`} → `317[{"ok":true}]`; {PacketConnect, -1, `{"sid":"s"}`}
// → `0{"sid":"s"}`.
func EncodePacket(p Packet) []byte {
	panic("not ported: sio.EncodePacket")
}

// DecodePacket parses the Socket.IO part of a message frame (after the
// Engine.IO "4"). Grammar: type digit; optional binary attachment count
// "<n>-" (rejected: ErrBinaryUnsupported); optional namespace "/<nsp>," (any
// nsp other than "/" → the caller answers CONNECT_ERROR "Invalid namespace");
// optional ack id digits; the rest is the JSON payload. Returns
// ErrMalformedPacket on anything else. EVENT/ACK payloads must be a JSON
// array; EVENT's first element must be a string.
func DecodePacket(frame []byte) (Packet, error) {
	panic("not ported: sio.DecodePacket")
}
