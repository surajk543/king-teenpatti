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
// Reference: socket.io-parser v4 (`Encoder.encodeAsString` /
// `Decoder.decodeString`) and engine.io-parser v5. The Node server's settings
// (index.js): pingInterval 20000, pingTimeout 25000, maxHttpBufferSize 1e5,
// cors origin from config.
package sio

import (
	"bytes"
	"encoding/json"
	"strconv"
)

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

// MsgInvalidNamespace is socket.io's CONNECT_ERROR message for a CONNECT to a
// namespace the server does not serve (socket.io/dist/client.js `connect`).
const MsgInvalidNamespace = "Invalid namespace"

// Packet is one decoded Socket.IO packet.
type Packet struct {
	Type byte
	// ID is the ack id for EVENT/ACK packets, or -1 when absent.
	ID int
	// Data is the raw JSON payload: for CONNECT the auth object (may be
	// empty), for EVENT the args array `["event", ...payload]`, for ACK the
	// args array, for CONNECT_ERROR the error object.
	Data []byte
	// Nsp is the namespace the packet names; "" (and "/") mean the default
	// namespace, which the wire omits. The server serves only "/", but a
	// CONNECT to another namespace must be answered with a CONNECT_ERROR
	// addressed to THAT namespace — `44/admin,{"message":"Invalid namespace"}`
	// — so the decoder reports it instead of failing (socket.io-parser keeps
	// `nsp` on every packet).
	Nsp string
}

// reservedEvents may not be used as event names on the wire (socket.io-parser
// RESERVED_EVENTS); an EVENT carrying one fails to decode.
var reservedEvents = map[string]struct{}{
	"connect": {}, "connect_error": {}, "disconnect": {}, "disconnecting": {},
	"newListener": {}, "removeListener": {},
}

// EncodePacket renders p as the Socket.IO part of a message frame — that is,
// WITHOUT the leading Engine.IO "4"; the transport adds it. Examples: Packet
// {Type: PacketEvent, ID: -1, Data: `["x",{}]`} → `2["x",{}]`; {PacketAck,
// 17, `[{"ok":true}]`} → `317[{"ok":true}]`; {PacketConnect, -1, `{"sid":"s"}`}
// → `0{"sid":"s"}`. A non-default Nsp is written as `<nsp>,` right after the
// type (`4/admin,{"message":"Invalid namespace"}`), exactly socket.io-parser's
// `encodeAsString`.
func EncodePacket(p Packet) []byte {
	out := make([]byte, 0, 1+len(p.Nsp)+1+20+len(p.Data))
	out = append(out, p.Type)
	if p.Nsp != "" && p.Nsp != "/" {
		out = append(out, p.Nsp...)
		out = append(out, ',')
	}
	if p.ID >= 0 {
		out = strconv.AppendInt(out, int64(p.ID), 10)
	}
	out = append(out, p.Data...)
	return out
}

// DecodePacket parses the Socket.IO part of a message frame (after the
// Engine.IO "4"), following socket.io-parser's `Decoder.decodeString` rule for
// rule. Grammar: type digit; optional binary attachment count "<n>-" (types
// 5/6 only; rejected: ErrBinaryUnsupported); optional namespace "/<nsp>,"
// (reported in Packet.Nsp — the caller answers a CONNECT to anything but "/"
// with CONNECT_ERROR "Invalid namespace"); optional ack id digits; the rest
// is the JSON payload, validated per type as `isPayloadValid` does: CONNECT →
// object or absent; DISCONNECT → absent; CONNECT_ERROR → string or object;
// EVENT → array whose first element is a string that is not a reserved event
// name (or a number, which Node tolerates and then ignores); ACK → array.
// Anything else → ErrMalformedPacket. An empty frame decodes as a bare
// CONNECT, as `Number("")` is 0 in JavaScript.
func DecodePacket(frame []byte) (Packet, error) {
	p := Packet{ID: -1}
	if len(frame) == 0 {
		p.Type = PacketConnect
		return p, nil
	}
	i := 0
	p.Type = frame[0]
	if p.Type < PacketConnect || p.Type > PacketBinaryAck {
		return p, ErrMalformedPacket
	}
	if p.Type == PacketBinaryEvent || p.Type == PacketBinaryAck {
		// "<n>-" attachments: the game never uses binary; refuse it outright
		// (Node would wait for the attachments and then dispatch a packet with
		// Buffers in it, which no handler of ours accepts).
		return p, ErrBinaryUnsupported
	}
	// namespace
	if i+1 < len(frame) && frame[i+1] == '/' {
		start := i + 1
		i++
		for i < len(frame) && frame[i] != ',' {
			i++
		}
		p.Nsp = string(frame[start:i])
		// i now sits on the ',' (or at len(frame) when the nsp ran to the end)
	}
	// ack id: a run of ASCII digits
	if i+1 < len(frame) && isDigit(frame[i+1]) {
		start := i + 1
		j := start
		for j < len(frame) && isDigit(frame[j]) {
			j++
		}
		if j-start > 18 {
			return p, ErrMalformedPacket
		}
		id, err := strconv.Atoi(string(frame[start:j]))
		if err != nil {
			return p, ErrMalformedPacket
		}
		p.ID = id
		i = j - 1
	}
	// payload
	i++
	if i < len(frame) {
		data := frame[i:]
		if !json.Valid(data) || !payloadValid(p.Type, data) {
			return p, ErrMalformedPacket
		}
		p.Data = data
	} else if p.Type == PacketEvent || p.Type == PacketAck {
		// `42` alone: Node dispatches an empty args array, which no handler
		// matches; we surface it as a packet without data (ignored upstream).
		p.Data = nil
	}
	return p, nil
}

func isDigit(b byte) bool { return b >= '0' && b <= '9' }

// payloadValid is socket.io-parser's `Decoder.isPayloadValid` for valid JSON.
func payloadValid(typ byte, data []byte) bool {
	trimmed := bytes.TrimLeft(data, " \t\r\n")
	if len(trimmed) == 0 {
		return false
	}
	switch typ {
	case PacketConnect:
		return trimmed[0] == '{'
	case PacketDisconnect:
		return false // "41" must carry nothing
	case PacketConnectError:
		return trimmed[0] == '"' || trimmed[0] == '{'
	case PacketEvent:
		if trimmed[0] != '[' {
			return false
		}
		var elems []json.RawMessage
		if err := json.Unmarshal(trimmed, &elems); err != nil || len(elems) == 0 {
			return false
		}
		first := bytes.TrimLeft(elems[0], " \t\r\n")
		if len(first) == 0 {
			return false
		}
		switch {
		case first[0] == '"':
			var name string
			if err := json.Unmarshal(first, &name); err != nil {
				return false
			}
			_, reserved := reservedEvents[name]
			return !reserved
		case first[0] == '-' || isDigit(first[0]):
			return true
		default:
			return false
		}
	case PacketAck:
		return trimmed[0] == '['
	}
	return false
}
