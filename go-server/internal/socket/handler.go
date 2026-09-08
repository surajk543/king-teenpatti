package socket

import (
	"context"
	"encoding/json"
	"log/slog"
	"sync"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/metrics"
	"github.com/surajk543/king-teenpatti/go-server/internal/sio"
)

// UserStore is what the handshake and the joins need from db.Users.
type UserStore interface {
	FindByID(ctx context.Context, id string) (*db.User, error)
}

// Deps wires the realtime layer.
type Deps struct {
	Config  *config.Config
	Rooms   *game.RoomManager
	Users   UserStore
	Tokens  *auth.Tokens
	Metrics *metrics.Metrics // nil → no observations (tests)
	Clock   game.Clock       // nil → game.RealClock{}
	Logger  *slog.Logger
}

// session is socket.data: the authenticated user plus the per-socket rate
// limiters. Stored via sio.Socket.SetData.
type session struct {
	user        *db.User
	rateLimiter *rateLimiter // 30 / 5 s, every guarded event
	chatLimiter *rateLimiter // config.Chat.RateLimit / RateWindow
}

// resumeOffer remembers the table a lapsed seat was at (resumeOffers map).
type resumeOffer struct {
	roomID string
	at     time.Time
}

// Handler is attachSocketHandlers' closure state. It implements
// game.Listener (table events → wire) and game.RoomListener (room events →
// wire); the app passes it to game.NewRoomManager as both (see New).
//
// # Locking
//
// mu guards the four maps. It is NEVER held while calling into a Table or
// the RoomManager (both may block on an actor) and never while emitting to a
// socket (a slow client must not stall the table). Pattern: lock → copy what
// is needed → unlock → act.
//
// game.Listener methods run ON a table's actor goroutine: they may use the
// *game.View and may take mu briefly, but must not call Table/RoomManager
// methods (see game.Listener). Room-level work they need is deferred to
// RoomListener callbacks, which the RoomManager already delivers off-actor.
type Handler struct {
	deps Deps
	srv  *sio.Server
	log  *slog.Logger

	mu sync.Mutex
	// roomSockets: roomId → sockets viewing that table (for per-viewer state).
	roomSockets map[string]map[*sio.Socket]struct{}
	// userSockets: userId → the ONE live socket (single-session rule).
	userSockets map[string]*sio.Socket
	// pendingRemovals: userId → grace timer armed on disconnect.
	pendingRemovals map[string]game.Timer
	// resumeOffers: userId → where they were when the grace period lapsed.
	resumeOffers map[string]resumeOffer

	liveSockets int
	peakSockets int
}

// New builds the Handler (the closure state of attachSocketHandlers).
// deps.Rooms may be nil at this point: the RoomManager needs the Handler as
// its listeners and the Handler needs the RoomManager at request time, so the
// app builds them in this order — h := socket.New(deps); rooms :=
// game.NewRoomManager({TableListener: h, Listener: h, …}); h.SetRooms(rooms);
// h.Attach(srv).
func New(deps Deps) *Handler {
	panic("not ported: socket.New")
}

// SetRooms supplies the RoomManager. Must be called before Attach.
func (h *Handler) SetRooms(rooms *game.RoomManager) {
	panic("not ported: (*Handler).SetRooms")
}

// Attach registers the handshake middleware and the connection handler on
// srv (attachSocketHandlers).
//
// Handshake (io.use): token = handshake.auth.token, falling back to
// query.token; Tokens.Verify → Users.FindByID(sub); nil user →
// "unknown_user"; any AuthError → its Code; any other error → "unauthorized".
// The middleware error message IS the code (CONNECT_ERROR {"message": code}).
//
// Connection (io.on('connection')), in order:
//  1. counters: connections_total++, connected_sockets++, liveSockets++,
//     peak gauge;
//  2. single session: a previous socket for the user gets
//     session:replaced {message: MsgSignedInElsewhere} and Disconnect(true)
//     (session_replaced_total++); userSockets[user] = socket;
//  3. a pending grace timer is stopped (reconnects_total{seat_held}++);
//  4. existing = Rooms.GetTableForPlayer(user); resume = existing == nil ?
//     takeResumeOffer(user) : nil; if existing → delete any resume offer; if
//     resume → reconnects_total{offer}++;
//  5. emit session:ready {user, config: PublicGameConfig, resume?};
//  6. if existing (timed join_duration{route:"resume"}): track the socket in
//     roomSockets[existing]; Join the sio room; existing.SetConnected(user,
//     true, socket.ID()); emit room:joined SerializeFor(user); then
//     chat:history;
//  7. register every guarded handler (see guard) and ping:rtt;
//  8. OnDisconnect (see onDisconnect).
func (h *Handler) Attach(srv *sio.Server) {
	panic("not ported: (*Handler).Attach")
}

// Stats is attachSocketHandlers' return value (unused by Node's index.js but
// kept): {sockets: len(userSockets), rooms: len(roomSockets)}.
type Stats struct {
	Sockets int `json:"sockets"`
	Rooms   int `json:"rooms"`
}

// Stats reports the live maps' sizes.
func (h *Handler) Stats() Stats {
	panic("not ported: (*Handler).Stats")
}

// guard wraps a request handler (socket/index.js guard): count
// socket_messages_total{event}; rate-limit (trip → socket_errors_total
// {rate_limited}, game:error {rate_limited, MsgRateLimited} AND ack
// ErrorAck{rate_limited} — acked, not dropped); run; ack the result (a
// struct whose first field is OK=true); on error: code = SafeLabel(CodeOf(err,
// internal_error), KnownErrorCodes, other), socket_errors_total{code}++, for
// game:action also invalid_moves_total{code}++, ack ErrorAck{code, message}
// AND emit game:error — the refusal is reported TWICE on purpose; clients
// dedupe. A non-GameError/AuthError is logged `socket handler failed` and
// reported as internal_error / MsgInternalError.
func (h *Handler) guard(s *sio.Socket, event string, fn func(args []json.RawMessage) (any, error)) sio.Handler {
	panic("not ported: (*Handler).guard")
}

// ---- request handlers (one method per client event; see the CLAUDE.md
// §7.1 table for payload → ack) ----

// lobbyList: {tables: Rooms.ListTables({category}), options: LobbyOptions}.
func (h *Handler) lobbyList(s *sio.Socket, req LobbyListRequest) (any, error) {
	panic("not ported")
}

// quickJoin (timed join_duration{quick_join}): fresh = Users.FindByID (the
// seat needs the CURRENT chips, not the handshake snapshot); Rooms.QuickJoin
// (bootAmount ?? default, category); track + sio Join; SetConnected(true,
// socket.ID()); emit room:joined; then chat:history; then broadcastState;
// ack RoomAck.
func (h *Handler) quickJoin(s *sio.Socket, req QuickJoinRequest) (any, error) {
	panic("not ported")
}

// create (timed {create}): fresh user; Rooms.CreateTable({boot ?? default,
// isPrivate ?? true, category}); Rooms.Join(table, fresh, socket.ID());
// track; emit room:joined; chat:history; ack RoomAck. NOTE: no broadcastState
// (Node omits it; the creator already has the snapshot).
func (h *Handler) create(s *sio.Socket, req CreateRequest) (any, error) {
	panic("not ported")
}

// joinCode (timed {code}): fresh user; Rooms.JoinByCode; track; SetConnected;
// room:joined; chat:history; broadcastState; RoomAck.
func (h *Handler) joinCode(s *sio.Socket, req JoinCodeRequest) (any, error) {
	panic("not ported")
}

// switchTable (timed {switch}): fresh user; leaving = GetTableForPlayer;
// UNTRACK the socket from the old room FIRST (leaving may destroy it, and
// room:closed must not land on this socket mid-switch); Rooms.SwitchTable —
// on error re-track the old room (if it still exists) and rethrow; track the
// target, SetConnected, room:joined, chat:history, broadcastState(target);
// broadcastState(from) if it still exists; RoomAck.
func (h *Handler) switchTable(s *sio.Socket) (any, error) {
	panic("not ported")
}

// leave: table = GetTableForPlayer; nil → OKAck{}. Rooms.Leave(user,
// "left"); untrack; emit room:left {roomId}; broadcastState if the table
// still exists; LeaveAck{roomId}.
func (h *Handler) leave(s *sio.Socket) (any, error) {
	panic("not ported")
}

// action: validate Action ∈ game.AllActions (unknown_action `Unknown action
// "<a>"`); table = GetTableForPlayer (not_in_room MsgNotAtTable); parse
// Amount per ActionRequest's doc; actionId per ActionIDMaxLength; timed
// move_duration{action} around table.Act; moves_total{action}++ on success;
// ack ActionAck.
func (h *Handler) action(s *sio.Socket, req ActionRequest) (any, error) {
	panic("not ported")
}

// sideshowRespond: table (not_in_room); table.RespondToSideshow(user, accept
// === true); ack SideshowAck.
func (h *Handler) sideshowRespond(s *sio.Socket, req SideshowRespondRequest) (any, error) {
	panic("not ported")
}

// requestCards: table (not_in_room); seat = table.FindSeat; if nil, blind or
// no cards → CardsAck{[]}; else cards = SerializeFor(user).You.Cards; emit
// player:cards {roomId, cards}; CardsAck{cards}.
func (h *Handler) requestCards(s *sio.Socket) (any, error) {
	panic("not ported")
}

// chatMessage: table (not_in_room); chatLimiter trip → chat_rate_limited
// (MsgChatRateLimited); msg = table.PostChat(user, text); nil → OKAck; else
// ChatAck{msg.ID}. The chat:message broadcast itself comes from OnChat.
func (h *Handler) chatMessage(s *sio.Socket, req ChatRequest) (any, error) {
	panic("not ported")
}

// chatHistory: table (not_in_room); sendChatHistory; ChatHistoryAck{count}.
func (h *Handler) chatHistory(s *sio.Socket) (any, error) {
	panic("not ported")
}

// pingRTT is registered directly (no guard, no rate limit, no `ok`):
// socket_messages_total{ping:rtt}++; ack PingAck{sentAt (echoed raw),
// serverTime: now ms}.
func (h *Handler) pingRTT(s *sio.Socket, args []json.RawMessage, ack sio.AckFunc) {
	panic("not ported")
}

// onDisconnect (socket.on('disconnect')): connected_sockets--, liveSockets--,
// disconnections_total{SafeLabel(reason, sio.KnownDisconnectReasons)}++;
// delete userSockets[user] only if it still points at THIS socket; table =
// GetTableForPlayer; nil → return; untrack; table.SetConnected(user, false,
// ""); arm a grace timer (config.Game.ReconnectGrace) →
//
//	delete pendingRemovals[user]; if userSockets has the user → return
//	(reconnected); current = GetTableForPlayer; nil → return;
//	resumeOffers[user] = {current.ID(), now}; Rooms.Leave(user,
//	"disconnected") (error → log `grace removal failed`, return);
//	broadcastState(current) if it still exists.
//
// Voluntary leave / kick never create an offer (the timer finds no seat).
func (h *Handler) onDisconnect(s *sio.Socket, reason string) {
	panic("not ported")
}

// takeResumeOffer pops the user's offer: nil when absent, older than
// config.Game.ResumeOffer, or the table is gone or full. Offered ONCE.
func (h *Handler) takeResumeOffer(userID string) *ResumeOffer {
	panic("not ported")
}

// broadcastState sends every viewer of the table its own TableView
// (room:state), timed as a whole into state_update_duration_seconds and
// counted ONCE in socket_emits_total{room:state}. From a game.Listener
// callback use broadcastView (the View computes inline); from a handler use
// this, which posts SerializeFor per viewer.
func (h *Handler) broadcastState(t *game.Table) {
	panic("not ported")
}

// broadcastView is broadcastState for use INSIDE OnState (no posting).
func (h *Handler) broadcastView(v *game.View) {
	panic("not ported")
}

// sendChatHistory emits chat:history {roomId, messages} to one socket.
func (h *Handler) sendChatHistory(t *game.Table, s *sio.Socket) {
	panic("not ported")
}

// emitTo / emitToRoom / emitToUser count socket_emits_total{event} once and
// send. emitToRoom uses srv.To(roomId).Emit — the sio room, which mirrors
// roomSockets.
func (h *Handler) emitTo(s *sio.Socket, event string, payload any) { panic("not ported") }

func (h *Handler) emitToRoom(roomID, event string, payload any) { panic("not ported") }

func (h *Handler) emitToUser(userID, event string, payload any) { panic("not ported") }

// trackRoom / untrackRoom keep roomSockets and the sio room in step.
func (h *Handler) trackRoom(roomID string, s *sio.Socket) { panic("not ported") }

func (h *Handler) untrackRoom(roomID string, s *sio.Socket) { panic("not ported") }

// publicGameConfig builds session:ready.config from config + LobbyOptions.
func (h *Handler) publicGameConfig() PublicGameConfig {
	panic("not ported")
}

// rateLimiter is createRateLimiter: fixed window, per socket.
type rateLimiter struct {
	limit       int
	window      time.Duration
	windowStart time.Time
	count       int
	now         func() time.Time
	mu          sync.Mutex
}

// allow returns true while count <= limit inside the current window; a new
// window starts when now - windowStart >= window.
func (r *rateLimiter) allow() bool {
	panic("not ported: (*rateLimiter).allow")
}

// ---- game.Listener (table events → wire; ON the actor goroutine) ----

var _ game.Listener = (*Handler)(nil)

// OnState → broadcastView.
func (h *Handler) OnState(v *game.View) { panic("not ported") }

// OnSeatUpdated: nothing (Node had no listener).
func (h *Handler) OnSeatUpdated(v *game.View, seatIndex int) {}

// OnChat: chat_messages_total++; room chat:message {…msg, roomId}.
func (h *Handler) OnChat(v *game.View, msg *game.ChatMessage) { panic("not ported") }

// OnHandStarted: games_started_total{category}++; room game:handStarted; then
// player:hand {roomId, dealt:true, cardsHidden:true} to every viewer socket
// (counted once).
func (h *Handler) OnHandStarted(v *game.View, e game.HandStartedEvent) { panic("not ported") }

// OnCards → emitToUser player:cards.
func (h *Handler) OnCards(v *game.View, e game.CardsEvent) { panic("not ported") }

// OnTurn → room game:turn (no options) + user game:yourTurn (options).
func (h *Handler) OnTurn(v *game.View, e game.TurnEvent) { panic("not ported") }

// OnAction: reason == "timeout" → turn_timeouts_total++; room game:action.
func (h *Handler) OnAction(v *game.View, e game.ActionEvent) { panic("not ported") }

// OnSideshowRequested → room game:sideshowRequested.
func (h *Handler) OnSideshowRequested(v *game.View, e game.SideshowRequestedEvent) {
	panic("not ported")
}

// OnSideshowReveal → game:sideshowReveal {roomId, reveal} to each of the two
// users (counted once).
func (h *Handler) OnSideshowReveal(v *game.View, e game.SideshowRevealEvent) { panic("not ported") }

// OnSideshowResolved → room game:sideshowResolved.
func (h *Handler) OnSideshowResolved(v *game.View, e game.SideshowResolvedEvent) {
	panic("not ported")
}

// OnShowdown → room game:showdown.
func (h *Handler) OnShowdown(v *game.View, e game.ShowdownEvent) { panic("not ported") }

// OnHandEnded: reason all_left → games_abandoned_total{category}++, else
// games_completed_total{category, SafeLabel(reason, win reasons)}++; if
// winnerId != nil && pot > 0 → pot_settled_chips_total += pot; room
// game:handEnded.
func (h *Handler) OnHandEnded(v *game.View, e game.HandEndedEvent) { panic("not ported") }

// OnKick: nothing here — the RoomManager performs the Leave and calls
// OnPlayerKicked. (Node did the Leave inside this listener; the Go port
// cannot post from the actor.)
func (h *Handler) OnKick(v *game.View, e game.KickEvent) {}

// OnPersistError: nothing (RoomManager logs).
func (h *Handler) OnPersistError(v *game.View, e game.PersistErrorEvent) {}

// OnError: nothing (RoomManager logs).
func (h *Handler) OnError(v *game.View, err error) {}

// ---- game.RoomListener (room events → wire; OFF the actor) ----

var _ game.RoomListener = (*Handler)(nil)

// OnTableCreated: nothing to wire (the listener is set at construction).
func (h *Handler) OnTableCreated(t *game.Table) {}

// OnTableDestroyed: room:closed {roomId} to every tracked viewer (counted
// once if any), sio Leave, drop roomSockets[roomId].
func (h *Handler) OnTableDestroyed(roomID string) { panic("not ported") }

// OnPlayerMoved (requirement 24): socket = userSockets[user]; target =
// GetTable(to); either nil → return. untrack(from); track(to);
// target.SetConnected(user, true, socket.ID()); emit room:moved {fromRoomId,
// toRoomId, code, MsgMovedToBusier}; emit room:joined SerializeFor(user);
// chat:history; broadcastState(target).
func (h *Handler) OnPlayerMoved(m game.PlayerMove) { panic("not ported") }

// OnPlayerKicked: kicks_total{SafeLabel(reason, game.KnownKickReasons)}++;
// emitToUser room:kicked {roomId, reason, message}; untrack the user's
// socket from the room; broadcastState(table) if it still exists.
func (h *Handler) OnPlayerKicked(k game.PlayerKicked) { panic("not ported") }
