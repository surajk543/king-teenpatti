package sio

import "errors"

// Errors the parser and server return.
var (
	ErrMalformedPacket   = errors.New("sio: malformed packet")
	ErrBinaryUnsupported = errors.New("sio: binary packets are not supported")
	ErrInvalidNamespace  = errors.New("sio: invalid namespace")
	ErrSocketClosed      = errors.New("sio: socket closed")
	ErrServerClosed      = errors.New("sio: server closed")
)

// Disconnect reasons, exactly Socket.IO's server-side strings (they are the
// label set of game_disconnections_total{reason}; anything else folds to
// "other"). See socket/index.js KNOWN_DISCONNECT_REASONS. The mapping below is
// socket.io 4.8.3 / engine.io 6.6.10's, verified against
// server/node_modules (client.js, socket.js, engine.io/build/socket.js):
const (
	// ReasonTransportClose: the WebSocket closed (close frame or EOF) — the
	// client went away.
	ReasonTransportClose = "transport close"
	// ReasonTransportError: a read/write error on the WebSocket, a frame over
	// MaxPayload, a write that timed out or overflowed the queue, or a client
	// PING ("2") — engine.io v4 treats a client-initiated ping as an
	// "invalid heartbeat direction" transport error.
	ReasonTransportError = "transport error"
	// ReasonPingTimeout: no PONG within PingTimeout of a PING.
	ReasonPingTimeout = "ping timeout"
	// ReasonClientNamespaceDisc: the client sent "41".
	ReasonClientNamespaceDisc = "client namespace disconnect"
	// ReasonServerNamespaceDisc: Socket.Disconnect(close) — with EITHER value
	// of close. socket.disconnect(true) in Node runs client._disconnect(),
	// which calls socket.disconnect() (a "41" and this reason) on every
	// namespace socket before closing the transport; that is what the
	// session:replaced path in socket/index.js observes (spec §3, §10.2).
	ReasonServerNamespaceDisc = "server namespace disconnect"
	// ReasonForcedClose: the engine closed the transport after a Socket.IO
	// packet failed to decode (malformed frame, binary data, reserved event
	// name): socket.io's client.onerror → conn.close() → engine.io
	// onClose("forced close"). Never produced by Disconnect(true).
	ReasonForcedClose = "forced close"
	// ReasonForcedServerClose: socket.io's client.close() for an "invalid
	// state" packet — an EVENT/ACK/DISCONNECT before CONNECT, a second CONNECT
	// while connected, a CONNECT_ERROR from the client — and for the connect
	// timeout. Not in KnownDisconnectReasons; Node folds it to "other" too.
	ReasonForcedServerClose = "forced server close"
	// ReasonServerShuttingDown: Server.Close / Shutdown (Node io.close()).
	ReasonServerShuttingDown = "server shutting down"
	// ReasonParseError: an Engine.IO frame whose first character is not a
	// packet type digit (engine.io-parser ERROR_PACKET → onClose("parse
	// error")). Not in KnownDisconnectReasons — Node folds it to "other" too.
	ReasonParseError = "parse error"
)

// KnownDisconnectReasons is the label set for game_disconnections_total.
var KnownDisconnectReasons = map[string]struct{}{
	ReasonTransportClose: {}, ReasonTransportError: {}, ReasonPingTimeout: {},
	ReasonClientNamespaceDisc: {}, ReasonServerNamespaceDisc: {}, ReasonForcedClose: {},
	ReasonServerShuttingDown: {},
}
