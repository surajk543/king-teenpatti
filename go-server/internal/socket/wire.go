// Package socket is the game's realtime protocol on top of sio — the port of
// server/src/socket/index.js (attachSocketHandlers). Event names, payload
// shapes and ack shapes are the wire contract with the Flutter and browser
// clients (CLAUDE.md §7.1) and must not change.
//
// Per-viewer broadcast: table state is sent per SOCKET, never per room, as
// table.SerializeFor(viewer) — each player must only ever receive their own
// cards.
package socket

import (
	"encoding/json"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// Client → server events.
const (
	EvLobbyList        = "lobby:list"           // {category?} → {tables, options}   (scratch/tests only)
	EvRoomQuickJoin    = "room:quickJoin"       // {bootAmount?, category?} → RoomAck
	EvRoomCreate       = "room:create"          // {bootAmount?, isPrivate=true, category?} → RoomAck (boot forced to PrivateBoot when private)
	EvRoomJoinCode     = "room:joinCode"        // {code} → RoomAck
	EvRoomSwitch       = "room:switch"          // {} → RoomAck
	EvRoomLeave        = "room:leave"           // {} → {roomId} or {}
	EvGameAction       = "game:action"          // {action, amount?, actionId?} → game.ActResult
	EvGameSideshowResp = "game:sideshowRespond" // {accept} → game.SideshowOutcome
	// EvGameSelectVariation is the chooser's answer on a variation table (Go
	// only; owner, 18 Sep 2026). WHO is choosing is never in the payload: it is
	// the socket's authenticated user, and the Table decides whether that is
	// the player the window is open for.
	EvGameSelectVariation = "game:selectVariation" // {variation} → game.VariationResult
	// EvGameSelectCards is a player's choice of which three of their five
	// cards play under 5-Card Teen Patti (Go only; owner, 19 Sep 2026).
	EvGameSelectCards = "game:selectCards"    // {cards:[3]} → game.PickResult
	EvPlayerReqCards  = "player:requestCards" // {} → {cards}
	EvChatMessage     = "chat:message"        // {text} → {messageId} or {}
	EvChatHistory     = "chat:history"        // {} → {count}
	EvPingRTT         = "ping:rtt"            // sentAt (number) → {sentAt, serverTime} — UNGUARDED, no `ok`
	// EvChatEmoji sends an animated emoji the player owns to their table
	// (owner, 26 Sep 2026; Go only). It arrives at everybody there as an
	// ordinary chat:message whose text is the emoji's name and which carries
	// the emoji (game.ChatMessage.Emoji).
	EvChatEmoji = "chat:emoji" // {emojiId} → {messageId}
)

// Server → client events.
const (
	EvSessionReady    = "session:ready"    // socket
	EvSessionReplaced = "session:replaced" // socket (the OLD one)
	EvRoomJoined      = "room:joined"      // socket: TableView
	EvRoomState       = "room:state"       // per viewer: TableView
	EvRoomMoved       = "room:moved"       // socket
	EvRoomLeft        = "room:left"        // socket
	EvRoomClosed      = "room:closed"      // every viewer of a destroyed table
	EvRoomKicked      = "room:kicked"      // socket
	EvGameHandStarted = "game:handStarted" // room
	EvPlayerHand      = "player:hand"      // every viewer socket
	EvPlayerCards     = "player:cards"     // owner only
	EvGameTurn        = "game:turn"        // room (no options)
	EvGameYourTurn    = "game:yourTurn"    // player on turn (options)
	EvGameActionOut   = "game:action"      // room (same name as the inbound event)
	EvGameSideshowReq = "game:sideshowRequested"
	EvGameSideshowRev = "game:sideshowReveal" // the two players only
	EvGameSideshowRes = "game:sideshowResolved"
	// Variation tables (Go only). Both are public and carry no cards but the
	// turned-up one, and both only repeat what room:state's `variation` block
	// says — a client that reconnects mid-window has the block and nothing else.
	EvGameVariationSelecting = "game:variationSelecting" // room: who is choosing, until when
	EvGameVariationSelected  = "game:variationSelected"  // room: what was chosen, and by whom or what
	EvGameShowdown           = "game:showdown"
	EvGameHandEnded          = "game:handEnded"
	EvChatMessageOut         = "chat:message"
	EvChatHistoryOut         = "chat:history"
	EvGameError              = "game:error" // socket: {code, message}
)

// Messages the socket layer itself puts on the wire.
const (
	MsgRateLimited       = "Slow down"
	MsgSignedInElsewhere = "Signed in from another device"
	MsgMovedToBusier     = "Moved to a table with other players waiting."
	MsgInternalError     = "Something went wrong"
	MsgNotAtTable        = "You are not at a table"
	MsgChatRateLimited   = "You are sending messages too quickly"
)

// emojiLookupTimeout bounds chat:emoji's one database read (Deps.Emojis.Owns),
// so a stalled PostgreSQL fails that send rather than holding the handler.
const emojiLookupTimeout = 5 * time.Second

// Rate limits (createRateLimiter, per socket, fixed window).
const (
	ActionRateLimit    = 30
	ActionRateWindowMs = 5000
	// ActionIDMaxLength: a longer or empty actionId is ignored (fresh uuid).
	ActionIDMaxLength = 64
	// ReservedActionIDSeparator: an actionId containing it is ignored too —
	// every server-generated chip_ledger.action_id is colon-separated, and a
	// client must not be able to take one of those keys first (see
	// Handler.action).
	ReservedActionIDSeparator = ':'
)

// KnownErrorCodes is the label set for game_socket_errors_total{code} and
// game_invalid_moves_total{code} (socket/index.js KNOWN_ERROR_CODES).
var KnownErrorCodes = map[string]struct{}{
	// rooms and seating
	"already_in_room": {}, "already_seated": {}, "insufficient_chips": {}, "invalid_stake": {},
	"no_other_table": {}, "not_in_room": {}, "not_seated": {}, "over_entry_cap": {}, "private_table": {},
	"invalid_room_code": {}, "room_not_found": {}, "table_full": {}, "table_not_offered": {}, "unknown_action": {},
	"wrong_game": {},
	// moves
	"already_seen": {}, "duplicate_action": {}, "invalid_bet": {}, "no_hand": {}, "not_in_hand": {},
	"not_your_turn": {}, "persist_failed": {}, "show_unavailable": {},
	// sideshow
	"already_asked": {}, "neighbour_is_blind": {}, "no_neighbour": {}, "no_sideshow": {},
	"not_your_sideshow": {}, "sideshow_pending": {}, "too_few_players": {}, "you_are_blind": {},
	// force sideshow and missile (Go only)
	"no_hammers": {}, "no_missiles": {},
	// variation tables (Go only)
	"no_variation": {}, "variation_already_selected": {}, "not_selecting": {}, "invalid_variation": {},
	"variation_expired": {}, "variation_pending": {},
	// poker rooms (Go only)
	"invalid_action": {}, "invalid_amount": {}, "invalid_discard": {},
	// chat
	"chat_rate_limited": {},
	// chat:emoji (Go only)
	"unknown_emoji": {}, "emoji_retired": {}, "emoji_locked": {},
	// auth
	"invalid_device_id": {}, "invalid_session": {}, "invalid_token": {}, "missing_token": {},
	"provider_unconfigured": {}, "unknown_provider": {}, "unknown_user": {},
	// the socket layer's own
	"rate_limited": {}, "internal_error": {},
}

// KnownEvents is the set of inbound event names counted in
// game_socket_messages_total{event}. (Outbound names are trusted constants.)
var KnownEvents = map[string]struct{}{
	EvLobbyList: {}, EvRoomQuickJoin: {}, EvRoomCreate: {}, EvRoomJoinCode: {}, EvRoomSwitch: {},
	EvRoomLeave: {}, EvGameAction: {}, EvGameSideshowResp: {}, EvPlayerReqCards: {}, EvChatMessage: {},
	EvChatHistory: {}, EvPingRTT: {}, EvGameSelectVariation: {}, EvGameSelectCards: {}, EvPokerAction: {},
	EvChatEmoji: {},
}

// ---- inbound payloads ----

// The inbound structs are filled by the decoders in payload.go, never by
// json.Unmarshal directly: Node destructured `payload ?? {}` with JavaScript's
// loose typing, so a non-object payload means "all defaults" and a wrongly
// typed field is coerced (String(), truthiness) or dropped exactly as the
// Node handler would have done. Each doc below says what its decoder stores.

// LobbyListRequest ← lobby:list. Category is the string sent ("" → no
// filter); a truthy non-string (42, {}) becomes a filter no table can match
// — Node's `!category || table.category === category` returned [] for it.
type LobbyListRequest struct {
	Category string `json:"category"`
}

// QuickJoinRequest ← room:quickJoin. BootAmount nil → config default (absent
// or null); a positive integer as sent; any other value (0, 200.5, "lots",
// true) is stored as −1 so the RoomManager refuses it with invalid_stake in
// Node's check order (after already_in_room). Category: the string sent, ""
// for a non-string (→ seen).
type QuickJoinRequest struct {
	BootAmount *int64 `json:"bootAmount"`
	Category   string `json:"category"`
}

// CreateRequest ← room:create. IsPrivate nil → true (the destructuring
// default applies to undefined only); null, false, 0, "" → public; any other
// value → private (Node stored it raw and tested truthiness). BootAmount as
// for QuickJoinRequest; it is ignored for private tables (requirement 22).
type CreateRequest struct {
	BootAmount *int64 `json:"bootAmount"`
	IsPrivate  *bool  `json:"isPrivate"`
	Category   string `json:"category"`
}

// JoinCodeRequest ← room:joinCode. Code is `String(code ?? ”)`: "" for
// absent/null, "[object Object]" for an object, digits for a number; the
// RoomManager upper-cases it.
type JoinCodeRequest struct {
	Code string `json:"code"`
}

// ActionRequest ← game:action. Action is String(action) — "undefined" when
// absent, "[object Object]" for an object — so the unknown_action message
// interpolates exactly what Node's template literal did; it must be in
// game.AllActions. Amount is kept raw (nil when absent) so the handler can
// apply Node's type rule: absent/null → no amount; a JSON number that is a
// safe integer → that; anything else (string "100", array, boolean, 1.5,
// 1e300) → invalid_bet "Bet amount must be a whole number". ActionID is the
// string sent ("" for a non-string) and is used only when 1..64 UTF-16 units
// long.
type ActionRequest struct {
	Action string `json:"action"`
	// ActionIsString is whether `action` arrived as a JSON string. Only a
	// string can name an action (Node: VALID_ACTIONS.has(action) is false for
	// anything else); Action still carries String(action) for the message, so
	// ["see"] is `Unknown action "see"` — never the see it spells (owner's "fix
	// all bugs", 24 Sep 2026).
	ActionIsString bool            `json:"-"`
	Amount         json.RawMessage `json:"amount"`
	ActionID       string          `json:"actionId"`
}

// SideshowRespondRequest ← game:sideshowRespond. Accept is the raw value
// (nil when absent). Only a JSON `true` accepts (Node: `accept === true`);
// anything else declines.
type SideshowRespondRequest struct {
	Accept json.RawMessage `json:"accept"`
}

// SelectVariationRequest ← game:selectVariation. Variation is the string sent,
// or "" for ANYTHING that is not a JSON string — a number, a boolean, an array,
// an object, null, or no field at all — so every hostile shape arrives at the
// Table as the empty string and is refused invalid_variation by the same
// allowlist a misspelt one is (game.ParseVariation; exact match, no folding).
type SelectVariationRequest struct {
	Variation string `json:"variation"`
}

// ChatRequest ← chat:message. Text is the string sent, a number's decimal
// string, or "" for anything else (DECISIONS.md §4); the Table sanitises it.
type ChatRequest struct {
	Text string `json:"text"`
}

// ChatEmojiRequest ← chat:emoji. EmojiID is the id sent — a JSON number or its
// decimal text, as the REST buy takes it — when it is a positive integer, and
// 0 for anything else (a fraction, a negative, a boolean, an object, null or no
// field at all), which names no row and is refused unknown_emoji.
type ChatEmojiRequest struct {
	EmojiID int64 `json:"emojiId"`
}

// ---- acks ----

// ErrorAck is every refusal: {ok:false, code, message}.
type ErrorAck struct {
	OK      bool   `json:"ok"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

// OKAck is `{ok:true}` with nothing else (room:leave when unseated,
// chat:message when the text sanitised away).
type OKAck struct {
	OK bool `json:"ok"`
}

// RoomAck ← room:quickJoin / create / joinCode / switch.
type RoomAck struct {
	OK       bool          `json:"ok"`
	RoomID   string        `json:"roomId"`
	Code     string        `json:"code"`
	Category game.Category `json:"category"`
}

// LeaveAck ← room:leave when seated.
type LeaveAck struct {
	OK     bool   `json:"ok"`
	RoomID string `json:"roomId"`
}

// LobbyListAck ← lobby:list.
type LobbyListAck struct {
	OK      bool                `json:"ok"`
	Tables  []game.TableSummary `json:"tables"`
	Options game.LobbyOptions   `json:"options"`
}

// ActionAck ← game:action: {ok:true} + game.ActResult fields.
type ActionAck struct {
	OK bool `json:"ok"`
	game.ActResult
}

// SideshowAck ← game:sideshowRespond.
type SideshowAck struct {
	OK bool `json:"ok"`
	game.SideshowOutcome
}

// VariationAck ← game:selectVariation: {ok:true, variation, selectedBy, turnUp?}.
type VariationAck struct {
	OK bool `json:"ok"`
	game.VariationResult
}

// SelectCardsRequest ← game:selectCards. Cards is the list as sent; any entry
// that is not a string becomes "", which names no card, so the table refuses
// the whole pick as not the player's own cards rather than guessing at it.
type SelectCardsRequest struct {
	Cards []string
}

// PickAck ← game:selectCards: the three that now play, the best three those
// five could have made, and whether they are the same.
type PickAck struct {
	OK bool `json:"ok"`
	game.PickResult
}

// CardsAck ← player:requestCards: [] unless seen.
type CardsAck struct {
	OK    bool     `json:"ok"`
	Cards []string `json:"cards"`
}

// ChatAck ← chat:message when a message was stored.
type ChatAck struct {
	OK        bool   `json:"ok"`
	MessageID string `json:"messageId"`
}

// ChatHistoryAck ← chat:history.
type ChatHistoryAck struct {
	OK    bool `json:"ok"`
	Count int  `json:"count"`
}

// PingAck ← ping:rtt: {sentAt, serverTime} — NO `ok` field. sentAt is echoed
// as received (raw JSON, `null` included); when the client sent no argument
// the key is ABSENT, as Node's `{ sentAt: undefined }` serialised — hence
// omitempty on the RawMessage (nil → omitted, `null` → kept).
type PingAck struct {
	SentAt     json.RawMessage `json:"sentAt,omitempty"`
	ServerTime int64           `json:"serverTime"`
}

// ---- outbound payloads ----

// PublicGameConfig is session:ready.config (publicGameConfig()): a few game
// constants plus the spread LobbyOptions.
type PublicGameConfig struct {
	MaxPlayers         int   `json:"maxPlayers"`
	MinPlayers         int   `json:"minPlayers"`
	BootAmount         int64 `json:"bootAmount"`
	TurnTimeoutMs      int64 `json:"turnTimeoutMs"`
	WelcomeChips       int64 `json:"welcomeChips"`
	MaxBetRounds       int   `json:"maxBetRounds"` // the GENERIC default (20), not a table's
	SideshowTimeoutMs  int64 `json:"sideshowTimeoutMs"`
	SideshowMinPlayers int   `json:"sideshowMinPlayers"`

	// MinClientBuild is the oldest Android versionCode this server will talk
	// to. Absent (0) means no floor. Clients below it show the update screen
	// instead of the lobby — see MIN_CLIENT_BUILD in internal/config.
	MinClientBuild int `json:"minClientBuild"`

	// TableConfigVersion is the version of the table catalogue this server
	// runs (RoomManager.TableConfigVersion — GET /api/tables' `version` and
	// ETag). A client holding a catalogue of the same version keeps it; one
	// holding another fetches it again. "" only on a server with no rooms.
	TableConfigVersion string `json:"tableConfigVersion"`

	game.LobbyOptions
}

// ResumeOffer is session:ready.resume — present only when a lapsed seat's
// table is offered back (takeResumeOffer). Flutter auto-joins it with
// room:joinCode.
type ResumeOffer struct {
	RoomID     string        `json:"roomId"`
	Code       string        `json:"code"`
	Category   game.Category `json:"category"`
	BootAmount int64         `json:"bootAmount"`
}

// SessionReady is session:ready.
type SessionReady struct {
	User   *db.User         `json:"user"`
	Config PublicGameConfig `json:"config"`
	Resume *ResumeOffer     `json:"resume,omitempty"` // key absent when nil (Node spread)
}

// MessageOnly is session:replaced / the `message`-only payloads.
type MessageOnly struct {
	Message string `json:"message"`
}

// GameErrorEvent is game:error.
type GameErrorEvent struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// RoomMovedEvent is room:moved. There is NO `state` key — the snapshot is the
// room:joined that follows (Flutter's `j['state']` branch is dead code).
type RoomMovedEvent struct {
	FromRoomID string `json:"fromRoomId"`
	ToRoomID   string `json:"toRoomId"`
	Code       string `json:"code"`
	Message    string `json:"message"`
}

// RoomIDOnly is room:left / room:closed.
type RoomIDOnly struct {
	RoomID string `json:"roomId"`
}

// RoomKickedEvent is room:kicked.
type RoomKickedEvent struct {
	RoomID  string `json:"roomId"`
	Reason  string `json:"reason"`
	Message string `json:"message"`
}

// Room-scoped game events are the game payload with roomId added (Node
// `{...payload, roomId}`); embedding flattens the fields.

type HandStartedEvent struct {
	game.HandStartedEvent
	RoomID string `json:"roomId"`
}

// PlayerHandEvent is player:hand — cards stay on the server until "see".
type PlayerHandEvent struct {
	RoomID      string `json:"roomId"`
	Dealt       bool   `json:"dealt"`       // true
	CardsHidden bool   `json:"cardsHidden"` // true
}

// PlayerCardsEvent is player:cards (owner only).
type PlayerCardsEvent struct {
	RoomID string   `json:"roomId"`
	Cards  []string `json:"cards"`
}

// TurnEvent is game:turn (room; NO options).
type TurnEvent struct {
	RoomID    string `json:"roomId"`
	UserID    string `json:"userId"`
	SeatIndex int    `json:"seatIndex"`
	Deadline  int64  `json:"deadline"`
	TimeoutMs int64  `json:"timeoutMs"`
}

// YourTurnEvent is game:yourTurn (player on turn only).
type YourTurnEvent struct {
	RoomID    string           `json:"roomId"`
	Deadline  int64            `json:"deadline"`
	TimeoutMs int64            `json:"timeoutMs"`
	Options   game.TurnOptions `json:"options"`
}

type ActionEvent struct {
	game.ActionEvent
	RoomID string `json:"roomId"`
}

type SideshowRequestedEvent struct {
	game.SideshowRequestedEvent
	RoomID string `json:"roomId"`
}

// SideshowRevealEvent is game:sideshowReveal (two players only).
type SideshowRevealEvent struct {
	RoomID string              `json:"roomId"`
	Reveal game.SideshowReveal `json:"reveal"`
}

type SideshowResolvedEvent struct {
	game.SideshowResolvedEvent
	RoomID string `json:"roomId"`
}

// VariationSelectingEvent is game:variationSelecting.
type VariationSelectingEvent struct {
	game.VariationSelectingEvent
	RoomID string `json:"roomId"`
}

// VariationSelectedEvent is game:variationSelected.
type VariationSelectedEvent struct {
	game.VariationSelectedEvent
	RoomID string `json:"roomId"`
}

type ShowdownEvent struct {
	game.ShowdownEvent
	RoomID string `json:"roomId"`
}

type HandEndedEvent struct {
	game.HandEndedEvent
	RoomID string `json:"roomId"`
}

// ChatMessageEvent is chat:message.
type ChatMessageEvent struct {
	game.ChatMessage
	RoomID string `json:"roomId"`
}

// ChatHistoryEvent is chat:history.
type ChatHistoryEvent struct {
	RoomID   string             `json:"roomId"`
	Messages []game.ChatMessage `json:"messages"` // [] never null
}
