package socket

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"

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

	// disconnectMu / disconnected make the disconnect bookkeeping run exactly
	// once and let a second caller WAIT for a run in flight. sio runs the
	// callbacks synchronously inside Disconnect(true), as Node did; the
	// replacement path in onConnection still calls onDisconnect itself so the
	// seat hand-over is ordered the same way even if the transport happened
	// to die on another goroutine at that instant (spec §10.2).
	disconnectMu sync.Mutex
	disconnected bool
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
	// lapsing: userId → closed when graceExpired has finished giving the seat
	// up. A sign-in that lands in the middle of a lapse waits for it instead
	// of restoring a seat that is about to be removed under it (Node deleted
	// the index synchronously before its first await, so its connection
	// handler could never see that half-finished lapse).
	lapsing map[string]chan struct{}

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
	if deps.Clock == nil {
		deps.Clock = game.RealClock{}
	}
	if deps.Config == nil {
		deps.Config = config.Defaults()
	}
	log := deps.Logger
	if log == nil {
		log = slog.Default()
	}
	return &Handler{
		deps:            deps,
		log:             log,
		roomSockets:     make(map[string]map[*sio.Socket]struct{}),
		userSockets:     make(map[string]*sio.Socket),
		pendingRemovals: make(map[string]game.Timer),
		resumeOffers:    make(map[string]resumeOffer),
		lapsing:         make(map[string]chan struct{}),
	}
}

// SetRooms supplies the RoomManager. Must be called before Attach.
func (h *Handler) SetRooms(rooms *game.RoomManager) {
	h.deps.Rooms = rooms
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
	h.srv = srv
	srv.Use(h.authenticate)
	srv.OnConnection(h.onConnection)
}

// Stats is attachSocketHandlers' return value (unused by Node's index.js but
// kept): {sockets: len(userSockets), rooms: len(roomSockets)}.
type Stats struct {
	Sockets int `json:"sockets"`
	Rooms   int `json:"rooms"`
}

// Stats reports the live maps' sizes.
func (h *Handler) Stats() Stats {
	h.mu.Lock()
	defer h.mu.Unlock()
	return Stats{Sockets: len(h.userSockets), Rooms: len(h.roomSockets)}
}

// rooms is the RoomManager (set by New or SetRooms).
func (h *Handler) rooms() *game.RoomManager { return h.deps.Rooms }

// cfg is the configuration.
func (h *Handler) cfg() *config.Config { return h.deps.Config }

// now is the injected clock — every wire timestamp and every rate-limit
// window comes from here, never from time.Now (PORT_PLAN.md §4.3).
func (h *Handler) now() time.Time { return h.deps.Clock.Now() }

// sessionOf returns the socket's session, or nil before the handshake stored one.
func sessionOf(s *sio.Socket) *session {
	sess, _ := s.Data().(*session)
	return sess
}

// ------------------------------------------------------------- handshake

// authenticate is the io.use middleware (socket/index.js:378-391).
func (h *Handler) authenticate(s *sio.Socket) error {
	token := handshakeToken(s.Handshake())
	claims, err := h.deps.Tokens.Verify(token)
	if err != nil {
		var ae *auth.AuthError
		if errors.As(err, &ae) && ae.Code != "" {
			return errors.New(ae.Code)
		}
		return errors.New(auth.CodeUnauthorized)
	}
	user, err := h.deps.Users.FindByID(context.Background(), claims.Subject)
	if err != nil {
		// DECISIONS.md §1: a database failure is reported as `unauthorized`,
		// never as a SQLSTATE (Node leaked the pg error code here).
		h.log.Warn("socket handshake user lookup failed", "error", err.Error())
		return errors.New(auth.CodeUnauthorized)
	}
	if user == nil {
		return errors.New(auth.CodeUnknownUser)
	}
	cfg := h.cfg()
	s.SetData(&session{
		user:        user,
		rateLimiter: newRateLimiter(ActionRateLimit, ActionRateWindowMs*time.Millisecond, h.now),
		chatLimiter: newRateLimiter(cfg.Chat.RateLimit, cfg.Chat.RateWindow, h.now),
	})
	return nil
}

// handshakeToken is `socket.handshake.auth?.token ?? socket.handshake.query?.token`:
// the CONNECT auth object's token unless it is null/absent, else the `token`
// query parameter ("" → missing_token). A non-string auth token is passed on
// verbatim so Tokens.Verify refuses it as invalid_session (Node: jwt.verify
// threw "jwt must be a string"); a falsy one (0, false, "") is "" →
// missing_token, as Node's `if (!token)` did.
func handshakeToken(hs sio.Handshake) string {
	if raw, ok := hs.Auth["token"]; ok {
		kind := kindOf(raw)
		if kind != kindNull {
			if s, isString := jsonString(raw, kind); isString {
				return s
			}
			if jsTruthy(raw, kind) {
				return string(bytes.TrimSpace(raw))
			}
			return ""
		}
	}
	if hs.Query == nil {
		return ""
	}
	return hs.Query.Get("token")
}

// ------------------------------------------------------------ connection

// onConnection is io.on('connection') — see Attach for the ordered contract.
func (h *Handler) onConnection(s *sio.Socket) {
	sess := sessionOf(s)
	if sess == nil {
		// Cannot happen: the middleware refuses the CONNECT without a user.
		s.Disconnect(true)
		return
	}
	user := sess.user

	// 1. counters. The peak is kept in a plain variable (not read back from
	// the gauge) and published under the lock so two connections arriving at
	// once can never write a lower high-water mark after a higher one.
	//
	// 2 (first half). The single-session rule is decided and RECORDED in the
	// same critical section: `previous` is read and userSockets[user] is
	// claimed together. Node's synchronous handler could not be interleaved;
	// here two sign-ins for one account completing at the same instant would
	// otherwise both read the same `previous`, both replace it, and both
	// stay live (the gap held a SetConnected post to a possibly busy actor).
	// Claiming first means the second of the two finds the first and replaces
	// it, exactly as if they had arrived one after the other.
	// 8. (registered before the claim below: from the moment userSockets
	// names this socket another sign-in may Disconnect it from its own
	// goroutine, and a socket closed before its callback is registered would
	// never run onDisconnect; the callback is idempotent — see onDisconnect)
	s.OnDisconnect(func(reason string) { h.onDisconnect(s, reason) })

	h.incConnections()
	h.mu.Lock()
	h.liveSockets++
	if h.liveSockets > h.peakSockets {
		h.peakSockets = h.liveSockets
		h.setPeak(h.peakSockets)
	}
	previous := h.userSockets[user.ID]
	h.userSockets[user.ID] = s
	lapse := h.lapsing[user.ID]
	h.mu.Unlock()

	// 2 (second half). one live session per account: a second login kicks
	// the first, which stops a player opening two clients on the same seat.
	if previous != nil && previous != s && previous.ID() != s.ID() {
		h.incSessionReplaced()
		h.emitTo(previous, EvSessionReplaced, MessageOnly{Message: MsgSignedInElsewhere})
		previous.Disconnect(true)
		// Node ran the previous socket's disconnect handler synchronously
		// inside disconnect(true): the seat is marked disconnected and a grace
		// timer armed before the new socket looks for a pending removal.
		// Force the same order here (a no-op if sio already ran it).
		h.onDisconnect(previous, sio.ReasonServerNamespaceDisc)
	}
	h.mu.Lock()
	// 3. cancel a pending removal — this is a reconnect inside the grace window.
	pending, hadPending := h.pendingRemovals[user.ID]
	if hadPending {
		delete(h.pendingRemovals, user.ID)
	}
	h.mu.Unlock()
	if hadPending {
		if pending != nil {
			pending.Stop()
		}
		h.incReconnect(metrics.ReconnectSeatHeld)
	}

	// A grace period that expired at this very moment is still giving the
	// seat up (graceExpired has passed its "reconnected?" check and is about
	// to Leave). Restoring the seat now would hand this socket room:joined
	// for a seat that vanishes a moment later with no room:left; wait for the
	// lapse to finish and take the resume offer it leaves behind instead.
	if lapse != nil {
		select {
		case <-lapse:
		case <-time.After(lapseWait):
			h.log.Warn("sign-in waited too long for a lapsing seat", "userId", user.ID)
		}
	}

	// 4. restore a player who was mid-hand when their connection dropped; if
	// the seat has already lapsed, `resume` names the table they were at.
	var existing *game.Table
	if rooms := h.rooms(); rooms != nil {
		existing = rooms.GetTableForPlayer(user.ID)
	}
	var resume *ResumeOffer
	if existing != nil {
		h.mu.Lock()
		delete(h.resumeOffers, user.ID)
		h.mu.Unlock()
	} else {
		resume = h.takeResumeOffer(user.ID)
	}
	if resume != nil {
		h.incReconnect(metrics.ReconnectOffer)
	}

	// 5.
	h.emitTo(s, EvSessionReady, SessionReady{User: user, Config: h.publicGameConfig(), Resume: resume})

	// 6.
	if existing != nil {
		started := time.Now()
		h.trackRoom(existing.ID(), s)
		if _, err := existing.SetConnected(user.ID, true, s.ID()); err != nil {
			h.log.Warn("resume: setConnected failed", "userId", user.ID, "roomId", existing.ID(), "error", err.Error())
		}
		if view, err := existing.SerializeFor(user.ID); err == nil {
			h.emitTo(s, EvRoomJoined, view)
		}
		h.observeJoin(metrics.RouteResume, started)
		h.sendChatHistory(existing, s)
	}

	// 7.
	s.On(EvLobbyList, h.guard(s, EvLobbyList, func(args []json.RawMessage) (any, error) {
		return h.lobbyList(s, decodeLobbyList(args))
	}))
	s.On(EvRoomQuickJoin, h.guard(s, EvRoomQuickJoin, func(args []json.RawMessage) (any, error) {
		return h.quickJoin(s, decodeQuickJoin(args))
	}))
	s.On(EvRoomCreate, h.guard(s, EvRoomCreate, func(args []json.RawMessage) (any, error) {
		return h.create(s, decodeCreate(args))
	}))
	s.On(EvRoomJoinCode, h.guard(s, EvRoomJoinCode, func(args []json.RawMessage) (any, error) {
		return h.joinCode(s, decodeJoinCode(args))
	}))
	s.On(EvRoomSwitch, h.guard(s, EvRoomSwitch, func([]json.RawMessage) (any, error) {
		return h.switchTable(s)
	}))
	s.On(EvRoomLeave, h.guard(s, EvRoomLeave, func([]json.RawMessage) (any, error) {
		return h.leave(s)
	}))
	s.On(EvGameAction, h.guard(s, EvGameAction, func(args []json.RawMessage) (any, error) {
		return h.action(s, decodeAction(args))
	}))
	s.On(EvGameSideshowResp, h.guard(s, EvGameSideshowResp, func(args []json.RawMessage) (any, error) {
		return h.sideshowRespond(s, decodeSideshowRespond(args))
	}))
	s.On(EvPlayerReqCards, h.guard(s, EvPlayerReqCards, func([]json.RawMessage) (any, error) {
		return h.requestCards(s)
	}))
	s.On(EvChatMessage, h.guard(s, EvChatMessage, func(args []json.RawMessage) (any, error) {
		return h.chatMessage(s, decodeChat(args))
	}))
	s.On(EvChatHistory, h.guard(s, EvChatHistory, func([]json.RawMessage) (any, error) {
		return h.chatHistory(s)
	}))
	s.On(EvPingRTT, func(args []json.RawMessage, ack sio.AckFunc) { h.pingRTT(s, args, ack) })
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
	return func(args []json.RawMessage, ack sio.AckFunc) {
		h.incMessages(event)
		sess := sessionOf(s)
		if sess == nil || !sess.rateLimiter.allow() {
			h.incSocketError(game.CodeRateLimited)
			// The refusal is emitted first, then acknowledged — a client
			// awaiting the ack would otherwise hang on it.
			h.emitTo(s, EvGameError, GameErrorEvent{Code: game.CodeRateLimited, Message: MsgRateLimited})
			if ack != nil {
				ack(ErrorAck{OK: false, Code: game.CodeRateLimited, Message: MsgRateLimited})
			}
			return
		}
		result, err := h.call(fn, args)
		if err != nil {
			code, message := refusalOf(err)
			label := metrics.SafeLabel(code, KnownErrorCodes, metrics.OtherLabel)
			h.incSocketError(label)
			if event == EvGameAction {
				h.incInvalidMove(label)
			}
			if ack != nil {
				ack(ErrorAck{OK: false, Code: code, Message: message})
			}
			h.fail(s, err)
			return
		}
		if ack != nil {
			ack(result)
		}
	}
}

// call runs a handler, turning a panic into an internal error so garbage on
// the wire can never take the process (and every honest player) down —
// Node's try/catch swallowed a TypeError the same way.
func (h *Handler) call(fn func(args []json.RawMessage) (any, error), args []json.RawMessage) (result any, err error) {
	defer func() {
		if r := recover(); r != nil {
			h.log.Error("socket handler panicked", "error", fmt.Sprint(r), "stack", string(debug.Stack()))
			result, err = nil, fmt.Errorf("%v", r)
		}
	}()
	return fn(args)
}

// refusalOf is the ack's {code, message}: a GameError's own; an AuthError's
// own (the codes are in KnownErrorCodes); anything else internal_error with
// the raw message (Node: `error.code ?? 'internal_error'`, `error.message`).
func refusalOf(err error) (code, message string) {
	var ge *game.GameError
	if errors.As(err, &ge) {
		return ge.Code, ge.Message
	}
	var ae *auth.AuthError
	if errors.As(err, &ae) {
		return ae.Code, ae.Message
	}
	return game.CodeInternalError, err.Error()
}

// fail is Node's fail(socket, error): a GameError is echoed as game:error
// {code, message}; anything else is logged and reported as internal_error.
func (h *Handler) fail(s *sio.Socket, err error) {
	var ge *game.GameError
	if errors.As(err, &ge) {
		h.emitTo(s, EvGameError, GameErrorEvent{Code: ge.Code, Message: ge.Message})
		return
	}
	h.log.Error("socket handler failed", "error", err.Error())
	h.emitTo(s, EvGameError, GameErrorEvent{Code: game.CodeInternalError, Message: MsgInternalError})
}

// notAtTable is the not_in_room refusal every gameplay handler starts with.
func notAtTable() error { return game.NewGameError(game.CodeNotInRoom, MsgNotAtTable) }

// freshUser re-reads the account (the seat needs CURRENT chips, not the
// handshake snapshot). A vanished row is an internal error, as Node's
// TypeError on `null.id` was.
func (h *Handler) freshUser(userID string) (*db.User, error) {
	fresh, err := h.deps.Users.FindByID(context.Background(), userID)
	if err != nil {
		return nil, err
	}
	if fresh == nil {
		return nil, fmt.Errorf("user %s no longer exists", userID)
	}
	return fresh, nil
}

// ---- request handlers (one method per client event; see the CLAUDE.md
// §7.1 table for payload → ack) ----

// lobbyList: {tables: Rooms.ListTables({category}), options: LobbyOptions}.
func (h *Handler) lobbyList(_ *sio.Socket, req LobbyListRequest) (any, error) {
	rooms := h.rooms()
	tables := rooms.ListTables(game.ListOptions{Category: game.Category(req.Category)})
	if tables == nil {
		tables = []game.TableSummary{}
	}
	return LobbyListAck{OK: true, Tables: tables, Options: rooms.LobbyOptions()}, nil
}

// quickJoin (timed join_duration{quick_join}): fresh = Users.FindByID (the
// seat needs the CURRENT chips, not the handshake snapshot); Rooms.QuickJoin
// (bootAmount ?? default, category); track + sio Join; SetConnected(true,
// socket.ID()); emit room:joined; then chat:history; then broadcastState;
// ack RoomAck.
func (h *Handler) quickJoin(s *sio.Socket, req QuickJoinRequest) (any, error) {
	user := sessionOf(s).user
	started := time.Now()
	var table *game.Table
	err := func() error {
		fresh, err := h.freshUser(user.ID)
		if err != nil {
			return err
		}
		boot := h.cfg().Game.BootAmount
		if req.BootAmount != nil {
			boot = *req.BootAmount
		}
		// Seating announces the arrival to players already in the room; this
		// player sees it a moment later in the history they are sent below.
		table, err = h.rooms().QuickJoin(fresh.Player(), game.QuickJoinOptions{BootAmount: boot, Category: req.Category})
		if err != nil {
			return err
		}
		return h.seatSocket(table, s, user.ID)
	}()
	h.observeJoin(metrics.RouteQuickJoin, started)
	if err != nil {
		return nil, err
	}
	h.sendChatHistory(table, s)
	h.broadcastState(table)
	return roomAck(table), nil
}

// seatSocket is the tail shared by every join route: track the socket,
// SetConnected(true, socketId) — which emits state, so every viewer including
// this socket receives room:state first — then room:joined with this
// viewer's own snapshot.
func (h *Handler) seatSocket(table *game.Table, s *sio.Socket, userID string) error {
	h.trackRoom(table.ID(), s)
	if _, err := table.SetConnected(userID, true, s.ID()); err != nil {
		return err
	}
	view, err := table.SerializeFor(userID)
	if err != nil {
		return err
	}
	h.emitTo(s, EvRoomJoined, view)
	if !s.Connected() {
		// The join outlived its socket: a second sign-in replaced it while
		// the seat was being taken (Node had the same window across its
		// awaits and left the seat with no live socket, no grace timer and
		// no resume offer — the account answered already_in_room to every
		// join until the idle kick 75 s later). Hand the seat to the live
		// socket if there is one, else start the grace clock.
		h.orphanedSeat(table, s, userID)
	}
	return nil
}

// orphanedSeat is the tail of a join whose socket died on the way: attach
// the account's live socket to the seat (a sign-in that arrived before the
// seat existed found nothing to restore), or, with no live socket, mark the
// seat disconnected and arm the grace timer so it lapses like any other.
func (h *Handler) orphanedSeat(table *game.Table, dead *sio.Socket, userID string) {
	roomID := table.ID()
	h.mu.Lock()
	live := h.userSockets[userID]
	_, viewing := h.roomSockets[roomID][live]
	h.mu.Unlock()
	if live != nil && live != dead && live.Connected() {
		if viewing {
			return // its own sign-in already restored the seat
		}
		h.log.Info("join finished on a replaced socket; seat handed to the live session", "userId", userID, "roomId", roomID)
		h.trackRoom(roomID, live)
		if _, err := table.SetConnected(userID, true, live.ID()); err != nil {
			return
		}
		if view, err := table.SerializeFor(userID); err == nil {
			h.emitTo(live, EvRoomJoined, view)
		}
		h.sendChatHistory(table, live)
		return
	}
	h.log.Info("join finished on a dead socket; holding the seat", "userId", userID, "roomId", roomID)
	h.untrackRoom(roomID, dead)
	if _, err := table.SetConnected(userID, false, ""); err != nil {
		return
	}
	h.holdSeat(userID)
}

// roomAck is the {roomId, code, category} every join route answers with.
func roomAck(table *game.Table) RoomAck {
	return RoomAck{OK: true, RoomID: table.ID(), Code: table.Code(), Category: table.Category()}
}

// create (timed {create}): fresh user; Rooms.CreateTable({boot ?? default,
// isPrivate ?? true, category}); Rooms.Join(table, fresh, socket.ID());
// track; emit room:joined; chat:history; ack RoomAck. NOTE: no broadcastState
// (Node omits it; the creator already has the snapshot).
//
// DECISIONS.md §3: already_in_room is checked BEFORE any table is created,
// and a PUBLIC create is validated like quickJoin — invalid_stake,
// table_not_offered, insufficient_chips, over_entry_cap, in that order.
// A private create is unchanged (boot forced to PrivateBoot; requirement 22).
func (h *Handler) create(s *sio.Socket, req CreateRequest) (any, error) {
	user := sessionOf(s).user
	started := time.Now()
	var table *game.Table
	err := func() error {
		fresh, err := h.freshUser(user.ID)
		if err != nil {
			return err
		}
		rooms := h.rooms()
		if rooms.GetTableForPlayer(user.ID) != nil {
			return game.NewGameError(game.CodeAlreadyInRoom, msgAlreadyInRoom)
		}
		isPrivate := req.IsPrivate == nil || *req.IsPrivate
		boot := h.cfg().Game.BootAmount
		if req.BootAmount != nil {
			boot = *req.BootAmount
		}
		category := game.NormalizeCategory(req.Category)
		if !isPrivate {
			if err := rooms.AssertStakeAllowed(boot); err != nil {
				return err
			}
			if err := rooms.AssertTableOffered(boot, category); err != nil {
				return err
			}
			if fresh.Chips < boot {
				return game.NewGameError(game.CodeInsufficientChips, msgInsufficientToJoin)
			}
			if err := h.assertUnderEntryCap(fresh.Chips, boot, category); err != nil {
				return err
			}
		}
		table = rooms.CreateTable(game.CreateTableOptions{BootAmount: boot, IsPrivate: isPrivate, Category: req.Category})
		if err := rooms.Join(table, fresh.Player(), s.ID()); err != nil {
			// Only a race with another join of the same account can get here
			// (the seat check above ran first). Do not leave an empty table
			// behind for the sweeper — nobody is on it.
			if table.IsEmpty() {
				if derr := rooms.DestroyTable(table.ID()); derr != nil {
					h.log.Warn("create: could not remove unused table", "roomId", table.ID(), "error", derr.Error())
				}
			}
			return err
		}
		h.trackRoom(table.ID(), s)
		view, err := table.SerializeFor(user.ID)
		if err != nil {
			return err
		}
		h.emitTo(s, EvRoomJoined, view)
		return nil
	}()
	h.observeJoin(metrics.RouteCreate, started)
	if err != nil {
		return nil, err
	}
	h.sendChatHistory(table, s)
	return roomAck(table), nil
}

// Messages the RoomManager uses for the two refusals the public-create
// validation reproduces (roomManager.js quickJoin / _assertUnderEntryCap).
const (
	msgAlreadyInRoom      = "You are already seated at a table"
	msgInsufficientToJoin = "Not enough chips to join this table"
	msgOverEntryCapFormat = "Players with more than %s chips cannot join this table"
)

// assertUnderEntryCap is roomManager.js _assertUnderEntryCap (requirement 30)
// for the public-create route: only when EntryCapMaxChips > 0 and the
// (boot, category) pair is the capped table; exactly the cap is allowed.
func (h *Handler) assertUnderEntryCap(chips, boot int64, category game.Category) error {
	g := h.cfg().Game
	cap := g.EntryCapMaxChips
	if cap <= 0 || boot != g.EntryCapBoot || string(category) != g.EntryCapCategory || chips <= cap {
		return nil
	}
	return game.Errorf(game.CodeOverEntryCap, msgOverEntryCapFormat, groupThousands(cap))
}

// groupThousands is Number#toLocaleString('en-US') for an integer: comma
// thousands grouping, no decimals ("500,000").
func groupThousands(n int64) string {
	digits := fmt.Sprintf("%d", n)
	sign := ""
	if digits[0] == '-' {
		sign, digits = "-", digits[1:]
	}
	var out []byte
	for i, c := range []byte(digits) {
		if i > 0 && (len(digits)-i)%3 == 0 {
			out = append(out, ',')
		}
		out = append(out, c)
	}
	return sign + string(out)
}

// joinCode (timed {code}): fresh user; Rooms.JoinByCode; track; SetConnected;
// room:joined; chat:history; broadcastState; RoomAck.
func (h *Handler) joinCode(s *sio.Socket, req JoinCodeRequest) (any, error) {
	user := sessionOf(s).user
	started := time.Now()
	var table *game.Table
	err := func() error {
		fresh, err := h.freshUser(user.ID)
		if err != nil {
			return err
		}
		table, err = h.rooms().JoinByCode(fresh.Player(), req.Code)
		if err != nil {
			return err
		}
		return h.seatSocket(table, s, user.ID)
	}()
	h.observeJoin(metrics.RouteCode, started)
	if err != nil {
		return nil, err
	}
	h.sendChatHistory(table, s)
	h.broadcastState(table)
	return roomAck(table), nil
}

// switchTable (timed {switch}): fresh user; leaving = GetTableForPlayer;
// UNTRACK the socket from the old room FIRST (leaving may destroy it, and
// room:closed must not land on this socket mid-switch); Rooms.SwitchTable —
// on error re-track the old room (if it still exists) and rethrow; track the
// target, SetConnected, room:joined, chat:history, broadcastState(target);
// broadcastState(from) if it still exists; RoomAck.
//
// DECISIONS.md §3 on a failure AFTER the seat was given up: the RoomManager
// restores the seat when it can; this layer re-tracks the socket only while
// the player is still seated at the old table, and sends room:left when the
// seat is gone so the client returns to the lobby with the error.
func (h *Handler) switchTable(s *sio.Socket) (any, error) {
	user := sessionOf(s).user
	rooms := h.rooms()
	started := time.Now()
	var result game.SwitchResult
	err := func() error {
		fresh, err := h.freshUser(user.ID)
		if err != nil {
			return err
		}
		// Stop listening to the old room *first*. Leaving it can destroy it —
		// if this player was the last one there — and a table being destroyed
		// tells everyone still tracking it that the room closed. That message
		// would land on this socket and read as "you have been thrown out",
		// moments before the join it is in the middle of.
		leaving := rooms.GetTableForPlayer(user.ID)
		if leaving != nil {
			h.untrackRoom(leaving.ID(), s)
		}
		result, err = rooms.SwitchTable(fresh.Player())
		if err != nil {
			if leaving != nil {
				switch {
				case rooms.GetTableForPlayer(user.ID) == leaving:
					// The seat was never given up (or was restored): put the
					// socket back where it was listening.
					h.trackRoom(leaving.ID(), s)
				case rooms.GetTableForPlayer(user.ID) == nil:
					h.emitTo(s, EvRoomLeft, RoomIDOnly{RoomID: leaving.ID()})
				}
			}
			return err
		}
		return h.seatSocket(result.To, s, user.ID)
	}()
	h.observeJoin(metrics.RouteSwitch, started)
	if err != nil {
		return nil, err
	}
	h.sendChatHistory(result.To, s)
	h.broadcastState(result.To)
	// The table they left has one fewer player; everyone still there should
	// see that straight away.
	if result.From != nil {
		if vacated := rooms.GetTable(result.From.ID()); vacated != nil {
			h.broadcastState(vacated)
		}
	}
	return roomAck(result.To), nil
}

// leave: table = GetTableForPlayer; nil → OKAck{}. Rooms.Leave(user,
// "left"); untrack; emit room:left {roomId}; broadcastState if the table
// still exists; LeaveAck{roomId}.
//
// The leaving socket stays tracked while the removal runs, so it receives
// whatever the table emits on the way out (the system chat line, its own pack
// if it was in a hand, room:state with you: null, and room:closed when it
// was the last player) BEFORE room:left — exactly Node's order.
func (h *Handler) leave(s *sio.Socket) (any, error) {
	user := sessionOf(s).user
	rooms := h.rooms()
	table := rooms.GetTableForPlayer(user.ID)
	if table == nil {
		return OKAck{OK: true}, nil
	}
	roomID := table.ID()
	if _, err := rooms.Leave(user.ID, game.LeaveReasonLeft); err != nil {
		return nil, err
	}
	h.untrackRoom(roomID, s)
	h.emitTo(s, EvRoomLeft, RoomIDOnly{RoomID: roomID})
	if still := rooms.GetTable(roomID); still != nil {
		h.broadcastState(still)
	}
	return LeaveAck{OK: true, RoomID: roomID}, nil
}

// actionLabels is VALID_ACTIONS as a label set for the move metrics.
var actionLabels = func() map[string]struct{} {
	out := make(map[string]struct{}, len(game.AllActions))
	for a := range game.AllActions {
		out[string(a)] = struct{}{}
	}
	return out
}()

// action: validate Action ∈ game.AllActions (unknown_action `Unknown action
// "<a>"`); table = GetTableForPlayer (not_in_room MsgNotAtTable); parse
// Amount per ActionRequest's doc; actionId per ActionIDMaxLength; timed
// move_duration{action} around table.Act; moves_total{action}++ on success;
// ack ActionAck.
func (h *Handler) action(s *sio.Socket, req ActionRequest) (any, error) {
	user := sessionOf(s).user
	if _, ok := game.AllActions[game.Action(req.Action)]; !ok {
		return nil, game.Errorf(game.CodeUnknownAction, game.MsgUnknownActionFormat, req.Action)
	}
	table := h.rooms().GetTableForPlayer(user.ID)
	if table == nil {
		return nil, notAtTable()
	}

	// `amount` is what the player picked with the +/- stepper. The table
	// validates it against the ladder it computes itself, so a tampered
	// client cannot bet an arbitrary figure. Only a real integer will do:
	// "100", [100] or true are not figures we want to guess for.
	amountKind := kindAbsent
	if req.Amount != nil {
		amountKind = kindOf(req.Amount)
	}
	amount, ok := parseAmount(req.Amount, amountKind)
	if !ok {
		return nil, game.NewGameError(game.CodeInvalidBet, game.MsgBetNotWhole)
	}

	// `actionId` is the client's own id for this move. It goes onto the
	// ledger row and is unique there, so a retried request — the ack got
	// lost, the button was pressed twice — is refused rather than charged
	// twice. A client that sends none (or one out of range) gets a fresh id
	// and no protection. The same column carries the server's own
	// deterministic ids ("<handId>:boot:<userId>", "<handId>:settle:<userId>",
	// "<userId>:milestone:<n>"); an id shaped like one of those — any colon —
	// is not a token, it is an attempt to occupy a key the server will need
	// (another player's milestone id fits in 64 chars), so it is dropped too.
	actionID := ""
	if n := utf16Len(req.ActionID); n > 0 && n <= ActionIDMaxLength && !strings.ContainsRune(req.ActionID, ReservedActionIDSeparator) {
		actionID = req.ActionID
	}

	label := metrics.SafeLabel(req.Action, actionLabels, metrics.OtherLabel)
	started := time.Now()
	result, err := table.Act(user.ID, game.Action(req.Action), game.ActRequest{Amount: amount, ActionID: actionID})
	h.observeMove(label, started)
	if err != nil {
		return nil, err
	}
	h.incMove(label)
	return ActionAck{OK: true, ActResult: result}, nil
}

// sideshowRespond: table (not_in_room); table.RespondToSideshow(user, accept
// === true); ack SideshowAck.
func (h *Handler) sideshowRespond(s *sio.Socket, req SideshowRespondRequest) (any, error) {
	user := sessionOf(s).user
	table := h.rooms().GetTableForPlayer(user.ID)
	if table == nil {
		return nil, notAtTable()
	}
	outcome, err := table.RespondToSideshow(user.ID, acceptsSideshow(req.Accept))
	if err != nil {
		return nil, err
	}
	return SideshowAck{OK: true, SideshowOutcome: outcome}, nil
}

// requestCards: table (not_in_room); seat = table.FindSeat; if nil, blind or
// no cards → CardsAck{[]}; else cards = SerializeFor(user).You.Cards; emit
// player:cards {roomId, cards}; CardsAck{cards}.
func (h *Handler) requestCards(s *sio.Socket) (any, error) {
	user := sessionOf(s).user
	table := h.rooms().GetTableForPlayer(user.ID)
	if table == nil {
		return nil, notAtTable()
	}
	seat, err := table.FindSeat(user.ID)
	if err != nil {
		return nil, err
	}
	if seat == nil || seat.IsBlind || len(seat.Cards) == 0 {
		return CardsAck{OK: true, Cards: []string{}}, nil
	}
	view, err := table.SerializeFor(user.ID)
	if err != nil {
		return nil, err
	}
	cards := []string{}
	if view.You != nil && view.You.Cards != nil {
		cards = view.You.Cards
	}
	h.emitTo(s, EvPlayerCards, PlayerCardsEvent{RoomID: table.ID(), Cards: cards})
	return CardsAck{OK: true, Cards: cards}, nil
}

// chatMessage: table (not_in_room); chatLimiter trip → chat_rate_limited
// (MsgChatRateLimited); msg = table.PostChat(user, text); nil → OKAck; else
// ChatAck{msg.ID}. The chat:message broadcast itself comes from OnChat.
//
// Chat gets its own, tighter allowance: a player flooding the room log is
// throttled well before they trip the general limiter. Every seated send
// counts, whether or not anything is posted; an unseated send is refused
// with not_in_room first and does not consume the chat allowance.
func (h *Handler) chatMessage(s *sio.Socket, req ChatRequest) (any, error) {
	sess := sessionOf(s)
	table := h.rooms().GetTableForPlayer(sess.user.ID)
	if table == nil {
		return nil, notAtTable()
	}
	if !sess.chatLimiter.allow() {
		return nil, game.NewGameError(game.CodeChatRateLimited, MsgChatRateLimited)
	}
	msg, err := table.PostChat(sess.user.ID, req.Text)
	if err != nil {
		return nil, err
	}
	if msg == nil {
		return OKAck{OK: true}, nil
	}
	return ChatAck{OK: true, MessageID: msg.ID}, nil
}

// chatHistory: table (not_in_room); sendChatHistory; ChatHistoryAck{count}.
func (h *Handler) chatHistory(s *sio.Socket) (any, error) {
	user := sessionOf(s).user
	table := h.rooms().GetTableForPlayer(user.ID)
	if table == nil {
		return nil, notAtTable()
	}
	count := h.sendChatHistory(table, s)
	return ChatHistoryAck{OK: true, Count: count}, nil
}

// pingRTT is registered directly (no guard, no rate limit, no `ok`):
// socket_messages_total{ping:rtt}++; ack PingAck{sentAt (echoed raw),
// serverTime: now ms}.
func (h *Handler) pingRTT(_ *sio.Socket, args []json.RawMessage, ack sio.AckFunc) {
	h.incMessages(EvPingRTT)
	if ack == nil {
		return
	}
	reply := PingAck{ServerTime: game.Millis(h.now())}
	if len(args) > 0 {
		reply.SentAt = args[0]
	}
	ack(reply)
}

// ------------------------------------------------------------ disconnect

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
// Runs exactly once per socket, whichever caller gets there first.
func (h *Handler) onDisconnect(s *sio.Socket, reason string) {
	sess := sessionOf(s)
	if sess == nil {
		return
	}
	sess.disconnectMu.Lock()
	defer sess.disconnectMu.Unlock()
	if sess.disconnected {
		return
	}
	sess.disconnected = true
	user := sess.user

	h.decConnected()
	h.mu.Lock()
	if h.liveSockets > 0 {
		h.liveSockets--
	}
	if h.userSockets[user.ID] == s {
		delete(h.userSockets, user.ID)
	}
	h.mu.Unlock()
	h.incDisconnection(metrics.SafeLabel(reason, sio.KnownDisconnectReasons, metrics.OtherLabel))

	rooms := h.rooms()
	if rooms == nil {
		return
	}
	table := rooms.GetTableForPlayer(user.ID)
	if table == nil {
		return
	}

	h.untrackRoom(table.ID(), s)
	if _, err := table.SetConnected(user.ID, false, ""); err != nil {
		h.log.Debug("disconnect: setConnected failed", "userId", user.ID, "error", err.Error())
	}

	// Hold the seat briefly so a flaky mobile connection does not cost the
	// player their place mid-hand; their turn still times out normally.
	h.holdSeat(user.ID)

	h.log.Debug("socket disconnected", "userId", user.ID, "reason", reason)
}

// holdSeat arms the grace timer for a seat whose socket is gone. The timer
// is created and recorded under the lock so a reconnect can never observe
// the seat held with no timer to cancel.
func (h *Handler) holdSeat(userID string) {
	h.mu.Lock()
	if old, ok := h.pendingRemovals[userID]; ok && old != nil {
		old.Stop()
	}
	h.pendingRemovals[userID] = h.deps.Clock.AfterFunc(h.cfg().Game.ReconnectGrace, func() { h.graceExpired(userID) })
	h.mu.Unlock()
}

// lapseWait bounds how long a sign-in waits for a lapse in progress (a Leave
// posted to an actor); it only ever runs out when the actor is stuck.
const lapseWait = 5 * time.Second

// graceExpired is the body of the grace timer (see onDisconnect).
func (h *Handler) graceExpired(userID string) {
	h.mu.Lock()
	delete(h.pendingRemovals, userID)
	_, reconnected := h.userSockets[userID]
	var lapse chan struct{}
	if !reconnected {
		// From here until the seat is gone a sign-in must not restore it
		// (see onConnection); the same mu section that found no socket
		// publishes the lapse, so a sign-in either sees the socket claimed
		// first (and we return) or sees the lapse (and waits).
		lapse = make(chan struct{})
		h.lapsing[userID] = lapse
	}
	h.mu.Unlock()
	if reconnected {
		return // reconnected on another socket
	}
	defer func() {
		h.mu.Lock()
		if h.lapsing[userID] == lapse {
			delete(h.lapsing, userID)
		}
		h.mu.Unlock()
		close(lapse)
	}()
	rooms := h.rooms()
	current := rooms.GetTableForPlayer(userID)
	if current == nil {
		return
	}
	roomID := current.ID()
	// The seat goes, but not the memory of where it was: a player who reopens
	// the app in the next few minutes is offered this table back. Written
	// BEFORE the leave so a failed removal still leaves the offer standing.
	h.mu.Lock()
	h.resumeOffers[userID] = resumeOffer{roomID: roomID, at: h.now()}
	h.mu.Unlock()
	if _, err := rooms.Leave(userID, game.LeaveReasonDisconnected); err != nil {
		h.log.Error("grace removal failed", "userId", userID, "error", err.Error())
		return
	}
	if still := rooms.GetTable(roomID); still != nil {
		h.broadcastState(still)
	}
}

// takeResumeOffer pops the user's offer: nil when absent, older than
// config.Game.ResumeOffer, or the table is gone or full. Offered ONCE.
func (h *Handler) takeResumeOffer(userID string) *ResumeOffer {
	h.mu.Lock()
	offer, ok := h.resumeOffers[userID]
	if ok {
		delete(h.resumeOffers, userID) // offered once, valid or not
	}
	h.mu.Unlock()
	if !ok {
		return nil
	}
	if h.now().Sub(offer.at) > h.cfg().Game.ResumeOffer {
		return nil
	}
	rooms := h.rooms()
	if rooms == nil {
		return nil
	}
	table := rooms.GetTable(offer.roomID)
	if table == nil || table.IsFull() {
		return nil
	}
	return &ResumeOffer{RoomID: table.ID(), Code: table.Code(), Category: table.Category(), BootAmount: table.BootAmount()}
}

// ------------------------------------------------------------- emitting

// viewers is a snapshot of the sockets tracked on a room.
func (h *Handler) viewers(roomID string) []*sio.Socket {
	h.mu.Lock()
	defer h.mu.Unlock()
	set := h.roomSockets[roomID]
	out := make([]*sio.Socket, 0, len(set))
	for s := range set {
		out = append(out, s)
	}
	return out
}

// broadcastState sends every viewer of the table its own TableView
// (room:state), timed as a whole into state_update_duration_seconds and
// counted ONCE in socket_emits_total{room:state}. From a game.Listener
// callback use broadcastView (the View computes inline); from a handler use
// this, which posts SerializeFor per viewer.
func (h *Handler) broadcastState(t *game.Table) {
	h.incEmit(EvRoomState)
	started := time.Now()
	for _, s := range h.viewers(t.ID()) {
		sess := sessionOf(s)
		if sess == nil {
			continue
		}
		view, err := t.SerializeFor(sess.user.ID)
		if err != nil {
			break // the table is gone; nothing more to send
		}
		_ = s.Emit(EvRoomState, view)
	}
	h.observeStateUpdate(started)
}

// broadcastView is broadcastState for use INSIDE OnState (no posting).
func (h *Handler) broadcastView(v *game.View) {
	h.incEmit(EvRoomState)
	started := time.Now()
	for _, s := range h.viewers(v.ID()) {
		sess := sessionOf(s)
		if sess == nil {
			continue
		}
		_ = s.Emit(EvRoomState, v.SerializeFor(sess.user.ID))
	}
	h.observeStateUpdate(started)
}

// sendChatHistory emits chat:history {roomId, messages} to one socket and
// returns the number of messages sent (the chat:history ack's count).
func (h *Handler) sendChatHistory(t *game.Table, s *sio.Socket) int {
	messages, err := t.ChatHistory()
	if err != nil || messages == nil {
		messages = []game.ChatMessage{}
	}
	h.emitTo(s, EvChatHistoryOut, ChatHistoryEvent{RoomID: t.ID(), Messages: messages})
	return len(messages)
}

// emitTo / emitToRoom / emitToUser count socket_emits_total{event} once and
// send. emitToRoom uses srv.To(roomId).Emit — the sio room, which mirrors
// roomSockets.
func (h *Handler) emitTo(s *sio.Socket, event string, payload any) {
	h.incEmit(event)
	_ = s.Emit(event, payload)
}

func (h *Handler) emitToRoom(roomID, event string, payload any) {
	h.incEmit(event)
	if h.srv == nil {
		return
	}
	h.srv.To(roomID).Emit(event, payload)
}

func (h *Handler) emitToUser(userID, event string, payload any) {
	h.mu.Lock()
	s := h.userSockets[userID]
	h.mu.Unlock()
	if s != nil {
		h.emitTo(s, event, payload)
	}
}

// trackRoom / untrackRoom keep roomSockets and the sio room in step. A
// socket that has already disconnected is never tracked: its join handler
// may still be finishing (the session:replaced path disconnects the old
// socket from another goroutine), sio's Join is a no-op for it, and nothing
// could ever be delivered to it — Node left such a socket in roomSockets
// until the table closed.
func (h *Handler) trackRoom(roomID string, s *sio.Socket) {
	if !s.Connected() {
		return
	}
	h.mu.Lock()
	set := h.roomSockets[roomID]
	if set == nil {
		set = make(map[*sio.Socket]struct{})
		h.roomSockets[roomID] = set
	}
	set[s] = struct{}{}
	h.mu.Unlock()
	s.Join(roomID)
	if !s.Connected() {
		// Disconnected between the check and the insert: its onDisconnect
		// (which untracks) has already run and found nothing, so undo the
		// insert here rather than carry a dead viewer until the table closes.
		h.untrackRoom(roomID, s)
	}
}

func (h *Handler) untrackRoom(roomID string, s *sio.Socket) {
	h.mu.Lock()
	set := h.roomSockets[roomID]
	if set == nil {
		h.mu.Unlock()
		return
	}
	delete(set, s)
	if len(set) == 0 {
		delete(h.roomSockets, roomID)
	}
	h.mu.Unlock()
	s.Leave(roomID)
}

// publicGameConfig builds session:ready.config from config + LobbyOptions.
func (h *Handler) publicGameConfig() PublicGameConfig {
	g := h.cfg().Game
	out := PublicGameConfig{
		MaxPlayers:         g.MaxPlayers,
		MinPlayers:         g.MinPlayers,
		BootAmount:         g.BootAmount,
		TurnTimeoutMs:      g.TurnTimeout.Milliseconds(),
		WelcomeChips:       g.WelcomeChips,
		MaxBetRounds:       g.MaxBetRounds,
		SideshowTimeoutMs:  g.SideshowTimeout.Milliseconds(),
		SideshowMinPlayers: g.SideshowMinPlayers,
	}
	if rooms := h.rooms(); rooms != nil {
		out.LobbyOptions = rooms.LobbyOptions()
	}
	return out
}

// ------------------------------------------------------------ rate limit

// rateLimiter is createRateLimiter: fixed window, per socket.
type rateLimiter struct {
	limit       int
	window      time.Duration
	windowStart time.Time
	count       int
	now         func() time.Time
	mu          sync.Mutex
}

// newRateLimiter anchors the first window at creation (Node: `windowStart =
// Date.now()` when the limiter is built).
func newRateLimiter(limit int, window time.Duration, now func() time.Time) *rateLimiter {
	return &rateLimiter{limit: limit, window: window, windowStart: now(), now: now}
}

// allow returns true while count <= limit inside the current window; a new
// window starts when now - windowStart >= window.
func (r *rateLimiter) allow() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.now()
	if now.Sub(r.windowStart) >= r.window {
		r.windowStart = now
		r.count = 0
	}
	r.count++
	return r.count <= r.limit
}

// --------------------------------------------------------------- metrics
//
// Every observation goes through one of these so a nil Metrics (tests) is a
// no-op and the label discipline (SafeLabel before any variable value) lives
// in one place. Latencies are measured with the wall clock, not the game
// Clock: they are not wire values and a test clock would report 0.

func (h *Handler) mx() *metrics.Metrics { return h.deps.Metrics }

func (h *Handler) incConnections() {
	if m := h.mx(); m != nil {
		m.ConnectionsTotal.Inc()
		m.ConnectedSockets.Inc()
	}
}

func (h *Handler) decConnected() {
	if m := h.mx(); m != nil {
		m.ConnectedSockets.Dec()
	}
}

func (h *Handler) setPeak(peak int) {
	if m := h.mx(); m != nil {
		m.ConnectedSocketsPeak.Set(float64(peak))
	}
}

func (h *Handler) incSessionReplaced() {
	if m := h.mx(); m != nil {
		m.SessionReplacedTotal.Inc()
	}
}

func (h *Handler) incReconnect(kind string) {
	if m := h.mx(); m != nil {
		m.ReconnectsTotal.WithLabelValues(kind).Inc()
	}
}

func (h *Handler) incDisconnection(reason string) {
	if m := h.mx(); m != nil {
		m.DisconnectionsTotal.WithLabelValues(reason).Inc()
	}
}

func (h *Handler) incMessages(event string) {
	if m := h.mx(); m != nil {
		m.SocketMessagesTotal.WithLabelValues(metrics.SafeLabel(event, KnownEvents, metrics.OtherLabel)).Inc()
	}
}

func (h *Handler) incEmit(event string) {
	if m := h.mx(); m != nil {
		m.SocketEmitsTotal.WithLabelValues(event).Inc()
	}
}

func (h *Handler) incSocketError(code string) {
	if m := h.mx(); m != nil {
		m.SocketErrorsTotal.WithLabelValues(code).Inc()
	}
}

func (h *Handler) incInvalidMove(code string) {
	if m := h.mx(); m != nil {
		m.InvalidMovesTotal.WithLabelValues(code).Inc()
	}
}

func (h *Handler) incMove(action string) {
	if m := h.mx(); m != nil {
		m.MovesTotal.WithLabelValues(action).Inc()
	}
}

func (h *Handler) observeMove(action string, started time.Time) {
	if m := h.mx(); m != nil {
		observe(m.MoveDuration.WithLabelValues(action), started)
	}
}

func (h *Handler) observeJoin(route string, started time.Time) {
	if m := h.mx(); m != nil {
		observe(m.JoinDuration.WithLabelValues(route), started)
	}
}

func (h *Handler) observeStateUpdate(started time.Time) {
	if m := h.mx(); m != nil {
		observe(m.StateUpdateDuration, started)
	}
}

func observe(obs prometheus.Observer, started time.Time) {
	obs.Observe(time.Since(started).Seconds())
}

// knownCategories / knownWinReasons are the label sets for the per-table
// counters (socket/index.js KNOWN_CATEGORIES / KNOWN_WIN_REASONS).
var (
	knownCategories = map[string]struct{}{string(game.CategoryBlind): {}, string(game.CategorySeen): {}}
	knownWinReasons = map[string]struct{}{
		string(game.WinLastStanding): {}, string(game.WinShow): {}, string(game.WinForcedShowdown): {},
		string(game.WinAllLeft): {}, string(game.WinPotLimit): {},
	}
)

func categoryLabel(c game.Category) string {
	return metrics.SafeLabel(string(c), knownCategories, metrics.OtherLabel)
}

// ---- game.Listener (table events → wire; ON the actor goroutine) ----

var _ game.Listener = (*Handler)(nil)

// OnState → broadcastView.
func (h *Handler) OnState(v *game.View) { h.broadcastView(v) }

// OnSeatUpdated: nothing (Node had no listener).
func (h *Handler) OnSeatUpdated(v *game.View, seatIndex int) {}

// OnChat: chat_messages_total++; room chat:message {…msg, roomId}.
func (h *Handler) OnChat(v *game.View, msg *game.ChatMessage) {
	if msg == nil {
		return
	}
	if m := h.mx(); m != nil {
		m.ChatMessagesTotal.Inc()
	}
	h.emitToRoom(v.ID(), EvChatMessageOut, ChatMessageEvent{ChatMessage: *msg, RoomID: v.ID()})
}

// OnHandStarted: games_started_total{category}++; room game:handStarted; then
// player:hand {roomId, dealt:true, cardsHidden:true} to every viewer socket
// (counted once). Cards stay on the server until a player pays attention to
// them by pressing "see" — this is what keeps a modified client from peeking.
func (h *Handler) OnHandStarted(v *game.View, e game.HandStartedEvent) {
	if m := h.mx(); m != nil {
		m.GamesStartedTotal.WithLabelValues(categoryLabel(v.Category())).Inc()
	}
	if e.Participants == nil {
		e.Participants = []string{}
	}
	h.emitToRoom(v.ID(), EvGameHandStarted, HandStartedEvent{HandStartedEvent: e, RoomID: v.ID()})
	h.incEmit(EvPlayerHand)
	for _, s := range h.viewers(v.ID()) {
		_ = s.Emit(EvPlayerHand, PlayerHandEvent{RoomID: v.ID(), Dealt: true, CardsHidden: true})
	}
}

// OnCards → emitToUser player:cards.
func (h *Handler) OnCards(v *game.View, e game.CardsEvent) {
	cards := e.Cards
	if cards == nil {
		cards = []string{}
	}
	h.emitToUser(e.UserID, EvPlayerCards, PlayerCardsEvent{RoomID: v.ID(), Cards: cards})
}

// OnTurn → room game:turn (no options) + user game:yourTurn (options). Only
// the player on turn is told which actions are legal and what they cost.
func (h *Handler) OnTurn(v *game.View, e game.TurnEvent) {
	h.emitToRoom(v.ID(), EvGameTurn, TurnEvent{
		RoomID: v.ID(), UserID: e.UserID, SeatIndex: e.SeatIndex, Deadline: e.Deadline, TimeoutMs: e.TimeoutMs,
	})
	if e.Options.RaiseSteps == nil {
		e.Options.RaiseSteps = []int64{}
	}
	h.emitToUser(e.UserID, EvGameYourTurn, YourTurnEvent{
		RoomID: v.ID(), Deadline: e.Deadline, TimeoutMs: e.TimeoutMs, Options: e.Options,
	})
}

// OnAction: reason == "timeout" → turn_timeouts_total++; room game:action.
func (h *Handler) OnAction(v *game.View, e game.ActionEvent) {
	// A pack the clock made on the player's behalf, not one they chose.
	if e.Reason == game.PackReasonTimeout {
		if m := h.mx(); m != nil {
			m.TurnTimeoutsTotal.Inc()
		}
	}
	h.emitToRoom(v.ID(), EvGameActionOut, ActionEvent{ActionEvent: e, RoomID: v.ID()})
}

// OnSideshowRequested → room game:sideshowRequested. A sideshow is public
// knowledge except for the cards: everyone sees who asked whom.
func (h *Handler) OnSideshowRequested(v *game.View, e game.SideshowRequestedEvent) {
	h.emitToRoom(v.ID(), EvGameSideshowReq, SideshowRequestedEvent{SideshowRequestedEvent: e, RoomID: v.ID()})
}

// OnSideshowReveal → game:sideshowReveal {roomId, reveal} to each of the two
// users (counted once). Only the two players involved ever receive the hands.
func (h *Handler) OnSideshowReveal(v *game.View, e game.SideshowRevealEvent) {
	h.incEmit(EvGameSideshowRev)
	payload := SideshowRevealEvent{RoomID: v.ID(), Reveal: e.Reveal}
	for _, userID := range e.UserIDs {
		h.mu.Lock()
		s := h.userSockets[userID]
		h.mu.Unlock()
		if s != nil {
			_ = s.Emit(EvGameSideshowRev, payload)
		}
	}
}

// OnSideshowResolved → room game:sideshowResolved.
func (h *Handler) OnSideshowResolved(v *game.View, e game.SideshowResolvedEvent) {
	h.emitToRoom(v.ID(), EvGameSideshowRes, SideshowResolvedEvent{SideshowResolvedEvent: e, RoomID: v.ID()})
}

// OnShowdown → room game:showdown.
func (h *Handler) OnShowdown(v *game.View, e game.ShowdownEvent) {
	if e.Reveals == nil {
		e.Reveals = []game.Reveal{}
	}
	h.emitToRoom(v.ID(), EvGameShowdown, ShowdownEvent{ShowdownEvent: e, RoomID: v.ID()})
}

// OnHandEnded: reason all_left → games_abandoned_total{category}++, else
// games_completed_total{category, SafeLabel(reason, win reasons)}++; if
// winnerId != nil && pot > 0 → pot_settled_chips_total += pot; room
// game:handEnded.
func (h *Handler) OnHandEnded(v *game.View, e game.HandEndedEvent) {
	if m := h.mx(); m != nil {
		category := categoryLabel(v.Category())
		// A hand everybody walked out of (or one cut short by the table being
		// destroyed) is abandoned; anything else finished with a real outcome.
		if e.Reason == game.WinAllLeft {
			m.GamesAbandonedTotal.WithLabelValues(category).Inc()
		} else {
			m.GamesCompletedTotal.WithLabelValues(category, metrics.SafeLabel(string(e.Reason), knownWinReasons, metrics.OtherLabel)).Inc()
		}
		// With no winner the pot is refunded rather than paid, so it is not a
		// settlement; the last leaver of an abandoned hand does take the pot.
		if e.WinnerID != nil && *e.WinnerID != "" && e.Pot > 0 {
			m.PotSettledTotal.Add(float64(e.Pot))
		}
	}
	if e.Reveals == nil {
		e.Reveals = []game.Reveal{}
	}
	if e.Summary == nil {
		e.Summary = []game.HandSummaryEntry{}
	}
	h.emitToRoom(v.ID(), EvGameHandEnded, HandEndedEvent{HandEndedEvent: e, RoomID: v.ID()})
}

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
func (h *Handler) OnTableDestroyed(roomID string) {
	h.mu.Lock()
	set := h.roomSockets[roomID]
	delete(h.roomSockets, roomID)
	viewers := make([]*sio.Socket, 0, len(set))
	for s := range set {
		viewers = append(viewers, s)
	}
	h.mu.Unlock()
	if len(viewers) > 0 {
		h.incEmit(EvRoomClosed)
	}
	for _, s := range viewers {
		_ = s.Emit(EvRoomClosed, RoomIDOnly{RoomID: roomID})
		s.Leave(roomID)
	}
}

// OnPlayerMoved (requirement 24): socket = userSockets[user]; target =
// GetTable(to); either nil → return. untrack(from); track(to);
// target.SetConnected(user, true, socket.ID()); emit room:moved {fromRoomId,
// toRoomId, code, MsgMovedToBusier}; emit room:joined SerializeFor(user);
// chat:history; broadcastState(target). A player merged onto a busier table
// is re-tracked here and handed the new room, so the move is seamless rather
// than a disconnect.
func (h *Handler) OnPlayerMoved(m game.PlayerMove) {
	h.mu.Lock()
	s := h.userSockets[m.UserID]
	h.mu.Unlock()
	rooms := h.rooms()
	if s == nil || rooms == nil {
		return
	}
	target := rooms.GetTable(m.ToRoomID)
	if target == nil {
		return
	}
	h.untrackRoom(m.FromRoomID, s)
	h.trackRoom(m.ToRoomID, s)
	if _, err := target.SetConnected(m.UserID, true, s.ID()); err != nil {
		h.log.Warn("playerMoved: setConnected failed", "userId", m.UserID, "roomId", m.ToRoomID, "error", err.Error())
	}
	h.emitTo(s, EvRoomMoved, RoomMovedEvent{
		FromRoomID: m.FromRoomID, ToRoomID: m.ToRoomID, Code: target.Code(), Message: MsgMovedToBusier,
	})
	if view, err := target.SerializeFor(m.UserID); err == nil {
		h.emitTo(s, EvRoomJoined, view)
	}
	h.sendChatHistory(target, s)
	h.broadcastState(target)
}

// OnPlayerKicked: kicks_total{SafeLabel(reason, game.KnownKickReasons)}++;
// emitToUser room:kicked {roomId, reason, message}; untrack the user's
// socket from the room; broadcastState(table) if it still exists. They are
// told why, so the lobby can say something better than "you were removed".
func (h *Handler) OnPlayerKicked(k game.PlayerKicked) {
	if m := h.mx(); m != nil {
		m.KicksTotal.WithLabelValues(metrics.SafeLabel(k.Reason, game.KnownKickReasons, metrics.OtherLabel)).Inc()
	}
	h.emitToUser(k.UserID, EvRoomKicked, RoomKickedEvent{RoomID: k.RoomID, Reason: k.Reason, Message: k.Message})
	h.mu.Lock()
	s := h.userSockets[k.UserID]
	h.mu.Unlock()
	if s != nil {
		h.untrackRoom(k.RoomID, s)
	}
	if rooms := h.rooms(); rooms != nil {
		if still := rooms.GetTable(k.RoomID); still != nil {
			h.broadcastState(still)
		}
	}
}
