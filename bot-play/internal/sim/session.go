package sim

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"sync"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// session is one simulated game connection: protocol.Session on the bot's
// side, and an entry of Server.sessions on the actor's.
type session struct {
	srv    *Server
	id     int
	acct   *account
	events chan protocol.Event // capacity SessionBuffer+1: the last slot is the disconnect's
	done   chan struct{}
	mu     sync.Mutex
	err    error

	// Owned by the actor.
	closed               bool
	lat                  *rng.Rand
	inAt, outAt          time.Time // the latest scheduled arrival each way, so order is kept
	inQueued, outQueued  int       // messages scheduled and not yet arrived
	rateLimit, chatLimit window
}

// window is a fixed-window rate limiter (the server's createRateLimiter).
type window struct {
	start time.Time
	n     int
}

func (w *window) allow(now time.Time, limit int, span time.Duration) bool {
	if now.Sub(w.start) >= span {
		w.start, w.n = now, 0
	}
	w.n++
	return w.n <= limit
}

// Emit sends an event without asking for an acknowledgement.
func (c *session) Emit(ctx context.Context, event string, payload any) error {
	raw, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	select {
	case <-c.done:
		return protocol.ErrClosed
	default:
	}
	return c.srv.post(ctx, func() { c.srv.inbound(c, event, raw, nil) })
}

// Request sends an event and waits for its acknowledgement.
func (c *session) Request(ctx context.Context, event string, payload any, ack any) error {
	raw, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	select {
	case <-c.done:
		return protocol.ErrClosed
	default:
	}
	reply := make(chan json.RawMessage, 1)
	if err := c.srv.post(ctx, func() { c.srv.inbound(c, event, raw, reply) }); err != nil {
		return err
	}
	decode := func(body json.RawMessage) error {
		if ack == nil {
			return nil
		}
		return json.Unmarshal(body, ack)
	}
	select {
	case body := <-reply:
		return decode(body)
	case <-ctx.Done():
		return ctx.Err()
	case <-c.done:
		select {
		case body := <-reply:
			return decode(body)
		default:
			return protocol.ErrClosed
		}
	}
}

// Events is the ordered stream of inbound events, ending with EvDisconnect.
func (c *session) Events() <-chan protocol.Event { return c.events }

// Done is closed when the connection has ended.
func (c *session) Done() <-chan struct{} { return c.done }

// Err is why the connection ended: protocol.ErrClosed after Close, or the
// simulation's reason (a drop, an overflow, a newer connection, shutdown).
func (c *session) Err() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.err
}

// Close ends the connection. Safe to call more than once.
func (c *session) Close() error {
	if c.srv.do(func() { c.srv.closeSession(c, protocol.ErrClosed) }) != nil {
		<-c.done // the server has stopped, and closed every session on its way
	}
	return nil
}

type dialer struct{ s *Server }

// Dialer opens simulated game connections.
func (s *Server) Dialer() protocol.Dialer { return dialer{s} }

// Dial connects as the account the token names. An unknown token is refused
// as the server's handshake refuses it: connect_error unknown_user.
func (d dialer) Dial(ctx context.Context, token string) (protocol.Session, error) {
	return call(ctx, d.s, func() (protocol.Session, error) { return d.s.connect(token) })
}

// connect is the handshake: one live connection per account (an older one is
// told session:replaced and closed), session:ready, and — when the account is
// still seated, within the reconnect grace — room:joined with its seat.
func (s *Server) connect(token string) (protocol.Session, error) {
	acct := s.byToken[token]
	if acct == nil {
		return nil, &protocol.ConnectError{Message: protocol.CodeUnknownUser}
	}
	if old := acct.sess; old != nil {
		body, _ := json.Marshal(messageWire{Message: "Signed in from another device"})
		s.deliver(old, protocol.Event{Name: protocol.EvSessionReplaced, Data: body})
		s.closeSession(old, errReplaced)
	}
	s.sessionSeq++
	acct.conns++
	stream := int(binary.BigEndian.Uint32(s.digest("latency", acct.id))) + acct.conns
	c := &session{srv: s, id: s.sessionSeq, acct: acct, done: make(chan struct{}),
		events: make(chan protocol.Event, s.cfg.SessionBuffer+1), lat: rng.Derive(s.cfg.Seed^saltLatency, stream)}
	s.sessions[c.id] = c
	acct.sess = c

	ready := sessionReadyWire{User: s.userOf(acct), Config: s.configWire()}
	if o := acct.resume; o != nil && acct.seat == nil {
		acct.resume = nil // offered once
		if !o.t.dead && !o.t.full() && s.now().Sub(o.at) <= resumeOfferFor {
			ready.Resume = &protocol.ResumeOffer{RoomID: o.t.id, Code: o.t.code, Category: o.t.entry.Category, BootAmount: o.t.entry.BootAmount}
		}
	}
	s.send(c, protocol.EvSessionReady, ready)
	if st := acct.seat; st != nil {
		st.grace.cancel()
		st.grace = nil
		st.t.emitState()
		s.send(c, protocol.EvRoomJoined, st.t.view(acct))
	}
	s.log.Debug("connected", "userId", acct.id, "session", c.id)
	return c, nil
}

// closeSession ends a connection: its last event is EvDisconnect, then its
// stream closes. A seated account keeps its seat for the reconnect grace;
// after it, the seat is given up and offered back once at the next connect.
func (s *Server) closeSession(c *session, why error) {
	if c.closed {
		return
	}
	c.closed = true
	c.mu.Lock()
	c.err = why
	c.mu.Unlock()
	body, _ := json.Marshal(disconnectWire{Reason: why.Error()})
	c.events <- protocol.Event{Name: protocol.EvDisconnect, Data: body} // the reserved slot
	close(c.events)
	close(c.done)
	delete(s.sessions, c.id)
	acct := c.acct
	if acct.sess != c {
		return
	}
	acct.sess = nil
	st := acct.seat
	if st == nil || why == errServerClosed {
		return
	}
	st.t.emitState()
	st.grace = s.after(reconnectGrace, func() {
		if acct.seat == st && acct.sess == nil {
			acct.resume = &resumeOffer{t: st.t, at: s.now()}
			st.t.removeSeat(st, "disconnected")
		}
	})
}

// dropOne is DropEvery: a random live connection is cut, as a network would.
func (s *Server) dropOne() {
	s.after(s.cfg.DropEvery, s.dropOne)
	list := s.sessionList()
	if len(list) == 0 {
		return
	}
	c := list[s.drop.IntN(len(list))]
	s.stats.Drops++
	s.log.Info("dropping a connection", "userId", c.acct.id, "seated", c.acct.seat != nil)
	s.closeSession(c, errDropped)
}

// ---- latency and delivery ----

func (s *Server) delay(c *session) time.Duration {
	lo, hi := s.lat[0], s.lat[1]
	if hi <= 0 {
		return 0
	}
	return lo + time.Duration(c.lat.Float64()*float64(hi-lo))
}

// inbound receives a client message after its simulated one-way delay,
// keeping this connection's messages in the order they were sent.
func (s *Server) inbound(c *session, event string, raw json.RawMessage, reply chan json.RawMessage) {
	if c.closed {
		return
	}
	now := s.now()
	at := now.Add(s.delay(c))
	if at.Before(c.inAt) {
		at = c.inAt
	}
	c.inAt = at
	if !at.After(now) && c.inQueued == 0 {
		s.handle(c, event, raw, reply)
		return
	}
	c.inQueued++
	s.schedule(at, func() {
		c.inQueued--
		if !c.closed {
			s.handle(c, event, raw, reply)
		}
	})
}

// send marshals payload now — the state as it is at this instant — and
// delivers it after the connection's simulated delay.
func (s *Server) send(c *session, event string, payload any) {
	if c == nil || c.closed {
		return
	}
	body, err := json.Marshal(payload)
	if err != nil {
		s.log.Error("sim: cannot marshal an event", "event", event, "error", err)
		return
	}
	s.sendRaw(c, event, body)
}

func (s *Server) sendRaw(c *session, event string, body json.RawMessage) {
	if c == nil || c.closed {
		return
	}
	s.enqueue(c, func() { s.deliver(c, protocol.Event{Name: event, Data: body}) })
}

// enqueue runs arrive after the connection's delay, after everything sent
// on it before. Acknowledgements travel the same way, so an ack never
// overtakes the events sent ahead of it.
func (s *Server) enqueue(c *session, arrive func()) {
	now := s.now()
	at := now.Add(s.delay(c))
	if at.Before(c.outAt) {
		at = c.outAt
	}
	c.outAt = at
	if !at.After(now) && c.outQueued == 0 {
		arrive()
		return
	}
	c.outQueued++
	s.schedule(at, func() {
		c.outQueued--
		if !c.closed {
			arrive()
		}
	})
}

// deliver hands an event to the bot without ever waiting for it: a
// connection whose buffer is full is dropped instead.
func (s *Server) deliver(c *session, ev protocol.Event) {
	if c.closed {
		return
	}
	if len(c.events) >= cap(c.events)-1 {
		s.log.Warn("dropping a connection that stopped reading", "userId", c.acct.id, "buffered", len(c.events))
		s.closeSession(c, errOverflow)
		return
	}
	c.events <- ev
}

// ---- requests ----

// refusal is a {ok:false, code, message} answer.
type refusal struct{ code, msg string }

func refuse(code, msg string) *refusal { return &refusal{code: code, msg: msg} }

// decode is the server's tolerant reading of a payload: anything that does
// not fit leaves the defaults.
func decode(raw json.RawMessage, v any) { _ = json.Unmarshal(raw, v) }

// handle answers one client message: the action rate limit, the event's
// handler, and a refusal reported twice — game:error, then the ack — as the
// server reports it. An event the server has no handler for is not answered.
func (s *Server) handle(c *session, event string, raw json.RawMessage, reply chan json.RawMessage) {
	var ack any
	var ref *refusal
	if !c.rateLimit.allow(s.now(), actionLimit, actionWindow) {
		ref = refuse(protocol.CodeRateLimited, "Slow down")
	} else {
		switch event {
		case protocol.EvRoomQuickJoin:
			ack, ref = s.quickJoin(c, raw)
		case protocol.EvRoomJoinCode:
			ack, ref = s.joinCode(c, raw)
		case protocol.EvRoomSwitch:
			ack, ref = s.switchTable(c)
		case protocol.EvRoomLeave:
			ack, ref = s.leave(c)
		case protocol.EvGameAction:
			ack, ref = s.act(c, raw)
		case protocol.EvGameSideshowRespond:
			ack, ref = s.respondSideshow(c, raw)
		case protocol.EvGameSelectVariation:
			ack, ref = s.selectVariation(c, raw)
		case protocol.EvGameSelectCards:
			ack, ref = s.selectCards(c)
		case protocol.EvChatMessage:
			ack, ref = s.chat(c, raw)
		case protocol.EvChatEmoji:
			ref = refuse("unknown_emoji", "That emoji does not exist")
		default:
			s.log.Warn("sim: no handler for an event; it is not answered", "event", event)
			return
		}
	}
	if ref != nil {
		s.stats.Refusals++
		s.send(c, protocol.EvGameError, gameErrorWire{Code: ref.code, Message: ref.msg})
		ack = errorAck{Code: ref.code, Message: ref.msg}
	}
	if reply != nil {
		body, _ := json.Marshal(ack)
		s.enqueue(c, func() { reply <- body })
	}
}

// configWire is session:ready.config.
func (s *Server) configWire() configWire {
	out := configWire{MaxPlayers: s.cfg.MaxPlayers, MinPlayers: minPlayers, BootAmount: 200,
		TurnTimeoutMs: s.cfg.TurnTimeout.Milliseconds(), WelcomeChips: s.cfg.WelcomeChips, MaxBetRounds: 20,
		SideshowTimeoutMs: sideshowTimeout.Milliseconds(), SideshowMinPlayers: sideshowMinPlayers,
		TableConfigVersion: s.version, Categories: []string{}, Stakes: s.stakes(), Tables: []menuWire{},
		PrivateBoot: 200, PrivateMaxPot: 500_000}
	seen := map[string]bool{}
	for _, e := range s.menu {
		out.Tables = append(out.Tables, menuWire{Category: e.Category, BootAmount: e.BootAmount, MaxPot: e.MaxPot,
			MaxBlindMoves: e.MaxBlindMoves, MinChips: e.MinChips, MaxChips: e.MaxChips})
		if !seen[e.Category] {
			seen[e.Category] = true
			out.Categories = append(out.Categories, e.Category)
		}
	}
	return out
}
