package protocol

import (
	"context"
	"encoding/json"
	"errors"
)

// API is the game server's REST side, as a bot uses it. The real server
// (connection.HTTPAPI) and the simulator (sim) both implement it, so a bot
// cannot tell them apart and needs no mode switch of its own.
type API interface {
	// Login signs in as a guest device — the same door every guest player
	// uses. The server marks the account is_bot from the device id's
	// namespace (its BOT_DEVICE_PREFIX); the bot sends nothing else to say so.
	Login(ctx context.Context, deviceID, displayName string) (LoginResult, error)
	// Tables is GET /api/tables (public, no token).
	Tables(ctx context.Context) (Catalogue, error)
	// Me is GET /api/auth/me — the account as the server has it now.
	Me(ctx context.Context, token string) (User, error)
	// FreePictureIDs lists the profile pictures anyone may wear for free
	// (GET /api/profiles: FREE rows that are not RIVE).
	FreePictureIDs(ctx context.Context) ([]int64, error)
	// WearPicture is POST /api/profile/avatar {avatar: id}.
	WearPicture(ctx context.Context, token string, pictureID int64) error
}

// Dialer opens an authenticated game connection (Socket.IO over websocket
// for the real server). One Dialer is shared by the whole fleet.
type Dialer interface {
	Dial(ctx context.Context, token string) (Session, error)
}

// Session is one live game connection.
//
// Inbound events arrive on Events in the order the server sent them,
// including a final EvDisconnect when the connection ends; the channel is
// then closed. A bot reads it from ONE goroutine, so its state needs no locks.
type Session interface {
	// Emit sends an event without asking for an acknowledgement.
	Emit(ctx context.Context, event string, payload any) error
	// Request sends an event and waits for its acknowledgement, decoding it
	// into ack. It returns ctx.Err() on timeout or cancellation, and
	// ErrClosed when the connection ends first. A refusal ({ok:false}) is NOT
	// an error: it decodes into ack like any answer.
	Request(ctx context.Context, event string, payload any, ack any) error
	// Events is the ordered stream of inbound events.
	Events() <-chan Event
	// Done is closed when the connection has ended.
	Done() <-chan struct{}
	// Err is why the connection ended (nil while it is open).
	Err() error
	// Close ends the connection. Safe to call more than once.
	Close() error
}

// Event is one inbound event: its name and its first argument, undecoded.
type Event struct {
	Name string
	Data json.RawMessage
}

// Decode unmarshals the event's payload into v.
func (e Event) Decode(v any) error {
	if len(e.Data) == 0 {
		return errors.New("protocol: event " + e.Name + " carries no payload")
	}
	return json.Unmarshal(e.Data, v)
}

// ErrClosed is returned by Session.Request when the connection ended before
// the acknowledgement arrived.
var ErrClosed = errors.New("protocol: connection closed")

// APIError is a REST refusal: the HTTP status and the server's
// {error: code, message}.
type APIError struct {
	Status  int
	Code    string
	Message string
}

func (e *APIError) Error() string {
	if e.Message != "" {
		return "api: " + e.Code + ": " + e.Message
	}
	return "api: " + e.Code
}

// ConnectError is the handshake refused by the server (connect_error), for
// example unknown_user after a database wipe or account_disabled.
type ConnectError struct {
	Message string
}

func (e *ConnectError) Error() string { return "connect_error: " + e.Message }
