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
// "other"). See socket/index.js KNOWN_DISCONNECT_REASONS.
const (
	ReasonTransportClose      = "transport close"             // the WebSocket closed (client went away)
	ReasonTransportError      = "transport error"             // read/write error on the WebSocket
	ReasonPingTimeout         = "ping timeout"                // no PONG within PingTimeout
	ReasonClientNamespaceDisc = "client namespace disconnect" // client sent "41"
	ReasonServerNamespaceDisc = "server namespace disconnect" // Socket.Disconnect(false)
	ReasonForcedClose         = "forced close"                // Socket.Disconnect(true)
	ReasonServerShuttingDown  = "server shutting down"        // Server.Close / Shutdown
)

// KnownDisconnectReasons is the label set for game_disconnections_total.
var KnownDisconnectReasons = map[string]struct{}{
	ReasonTransportClose: {}, ReasonTransportError: {}, ReasonPingTimeout: {},
	ReasonClientNamespaceDisc: {}, ReasonServerNamespaceDisc: {}, ReasonForcedClose: {},
	ReasonServerShuttingDown: {},
}
