package socket

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/metrics"
	"github.com/surajk543/king-teenpatti/go-server/internal/poker"
	"github.com/surajk543/king-teenpatti/go-server/internal/sio"
)

// The poker family on the wire (POKER_PLAN.md §7): one inbound event,
// poker:action, and the poker.Listener that turns a poker room's events into
// poker:* messages. Every room-level event — room:joined, room:state,
// room:left, room:kicked, room:closed, room:moved, chat:*, session:* — is the
// same for both families and lives in handler.go; only the game events differ.
// A Teen Patti table never sends any of these, and a poker room never sends a
// game:* event, so neither family's clients see the other's vocabulary.

// Client → server.
const (
	// EvPokerAction is {action, amount?, cards?, actionId?} → PokerActionAck.
	// action is fold | check | call | bet | raise | allIn | play | draw; amount
	// is the total street bet for bet / raise; cards names the cards to
	// discard on a draw.
	EvPokerAction = "poker:action"
)

// Server → client.
const (
	EvPokerHandStarted = "poker:handStarted" // room
	EvPokerCards       = "poker:cards"       // owner only: hole cards, and the new hand after a draw
	EvPokerTurn        = "poker:turn"        // room (no options)
	EvPokerYourTurn    = "poker:yourTurn"    // player on turn (options)
	EvPokerActionOut   = "poker:action"      // room (same name as the inbound event)
	EvPokerStreet      = "poker:street"      // room: a street began, the board so far
	EvPokerDraw        = "poker:draw"        // room: a player exchanged n cards
	EvPokerShowdown    = "poker:showdown"    // room
	EvPokerHandEnded   = "poker:handEnded"   // room
)

// PokerActionRequest ← poker:action.
type PokerActionRequest struct {
	Action   string
	Amount   json.RawMessage // nil when absent
	Cards    []string        // the strings of a `cards` array; nil when absent or not an array
	ActionID string
}

// PokerActionAck ← poker:action.
type PokerActionAck struct {
	OK bool `json:"ok"`
	poker.ActResult
}

// Room-scoped poker events are the payload with roomId added, as the Teen
// Patti ones are.

type PokerHandStartedEvent struct {
	poker.HandStartedEvent
	RoomID string `json:"roomId"`
}

type PokerCardsEvent struct {
	RoomID string   `json:"roomId"`
	Cards  []string `json:"cards"`
}

type PokerTurnEvent struct {
	RoomID    string       `json:"roomId"`
	UserID    string       `json:"userId"`
	SeatIndex int          `json:"seatIndex"`
	Street    poker.Street `json:"street"`
	Deadline  int64        `json:"deadline"`
	TimeoutMs int64        `json:"timeoutMs"`
}

type PokerYourTurnEvent struct {
	RoomID    string        `json:"roomId"`
	Street    poker.Street  `json:"street"`
	Deadline  int64         `json:"deadline"`
	TimeoutMs int64         `json:"timeoutMs"`
	Options   poker.Options `json:"options"`
}

type PokerActionEvent struct {
	poker.ActionEvent
	RoomID string `json:"roomId"`
}

type PokerStreetEvent struct {
	poker.StreetEvent
	RoomID string `json:"roomId"`
}

type PokerDrawEvent struct {
	poker.DrawEvent
	RoomID string `json:"roomId"`
}

type PokerShowdownEvent struct {
	poker.ShowdownEvent
	RoomID string `json:"roomId"`
}

type PokerHandEndedEvent struct {
	poker.HandEndedEvent
	RoomID string `json:"roomId"`
}

// pokerActionLabels is poker.ActionNames as a label set for the move
// metrics (moves_total{action}, move_processing_duration_seconds{action}).
var pokerActionLabels = func() map[string]struct{} {
	out := make(map[string]struct{}, len(poker.ActionNames))
	for _, a := range poker.ActionNames {
		out[a] = struct{}{}
	}
	return out
}()

// knownPokerWinReasons is the label set for games_completed_total{reason}
// at a poker room.
var knownPokerWinReasons = func() map[string]struct{} {
	out := make(map[string]struct{}, len(poker.WinReasons))
	for _, r := range poker.WinReasons {
		out[r] = struct{}{}
	}
	return out
}()

// decodePokerAction reads poker:action with the same JavaScript leniency as
// decodeAction: the action is String(action); amount is kept raw for
// parseAmount; cards is the array's string elements, or nil when it is not
// an array (a draw with no array stands pat — the room refuses a non-array
// only through what it does not find in it).
func decodePokerAction(args []json.RawMessage) PokerActionRequest {
	p := decodePayload(args)
	req := PokerActionRequest{}
	raw, kind := p.field("action")
	req.Action = jsString(raw, kind)
	if raw, kind := p.field("amount"); kind != kindAbsent {
		req.Amount = raw
	}
	if raw, kind := p.field("cards"); kind == kindArray {
		var items []json.RawMessage
		if err := json.Unmarshal(raw, &items); err == nil {
			req.Cards = make([]string, 0, len(items))
			for _, item := range items {
				if s, ok := jsonString(item, kindOf(item)); ok {
					req.Cards = append(req.Cards, s)
				} else {
					// A non-string names no card; the room refuses it as
					// not one of the player's cards.
					req.Cards = append(req.Cards, "")
				}
			}
		}
	}
	req.ActionID = stringArg(p.field("actionId"))
	return req
}

// pokerRoom is the *poker.Table the user is seated at: not_in_room when
// unseated, wrong_game at a Teen Patti table.
func (h *Handler) pokerRoom(userID string) (*poker.Table, error) {
	room := h.rooms().GetTableForPlayer(userID)
	if room == nil {
		return nil, notAtTable()
	}
	table, ok := room.(*poker.Table)
	if !ok {
		return nil, game.NewGameError(game.CodeWrongGame, game.MsgWrongGame)
	}
	return table, nil
}

// pokerAction is poker:action: validate the action name (unknown_action),
// find the poker room (not_in_room / wrong_game), parse the amount with the
// safe-integer rule of game:action (invalid_amount for a non-integer), apply
// the actionId hygiene of game:action, then Table.Act, timed and counted
// under the poker action labels.
func (h *Handler) pokerAction(s *sio.Socket, req PokerActionRequest) (any, error) {
	user := sessionOf(s).user
	action := poker.Action(req.Action)
	if _, ok := poker.AllActions[action]; !ok {
		return nil, game.Errorf(game.CodeUnknownAction, game.MsgUnknownActionFormat, req.Action)
	}
	table, err := h.pokerRoom(user.ID)
	if err != nil {
		return nil, err
	}
	act := poker.ActRequest{Cards: req.Cards}
	if req.Amount != nil {
		amount, ok := parseAmount(req.Amount, kindOf(req.Amount))
		if !ok {
			return nil, game.NewGameError(poker.CodeInvalidAmount, poker.MsgAmountNotWhole)
		}
		if amount != nil {
			act.Amount, act.HasAmount = *amount, true
		}
	}
	if n := utf16Len(req.ActionID); n > 0 && n <= ActionIDMaxLength && !strings.ContainsRune(req.ActionID, ReservedActionIDSeparator) {
		act.ActionID = req.ActionID
	}
	label := metrics.SafeLabel(req.Action, pokerActionLabels, metrics.OtherLabel)
	started := time.Now()
	result, err := table.Act(user.ID, action, act)
	h.observeMove(label, started)
	if err != nil {
		return nil, err
	}
	h.incMove(label)
	return PokerActionAck{OK: true, ActResult: result}, nil
}

// ---- poker.Listener (poker room events → wire; ON the room's actor) ----

// pokerEvents is the Handler's poker.Listener. A type of its own because
// game.Listener and poker.Listener share method names (OnState, OnChat…) with
// different parameter types, and Go allows one method of a name per type.
// Everything it needs — the viewers, the emit helpers, the metrics — is the
// Handler's.
type pokerEvents struct {
	h *Handler
}

var _ poker.Listener = (*pokerEvents)(nil)

// PokerListener is what the app hands poker.Factory as its Listener.
func (h *Handler) PokerListener() poker.Listener { return &pokerEvents{h: h} }

// OnState → room:state per viewer (the poker TableView).
func (p *pokerEvents) OnState(v *poker.View) {
	h := p.h
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

// OnChat → room chat:message, exactly as a Teen Patti table's.
func (p *pokerEvents) OnChat(v *poker.View, msg *game.ChatMessage) {
	if msg == nil {
		return
	}
	if m := p.h.mx(); m != nil {
		m.ChatMessagesTotal.Inc()
	}
	p.h.emitToRoom(v.ID(), EvChatMessageOut, ChatMessageEvent{ChatMessage: *msg, RoomID: v.ID()})
}

// OnHandStarted: games_started_total{category}++; room poker:handStarted.
func (p *pokerEvents) OnHandStarted(v *poker.View, e poker.HandStartedEvent) {
	if m := p.h.mx(); m != nil {
		m.GamesStartedTotal.WithLabelValues(categoryLabel(v.Category())).Inc()
	}
	if e.Participants == nil {
		e.Participants = []string{}
	}
	p.h.emitToRoom(v.ID(), EvPokerHandStarted, PokerHandStartedEvent{HandStartedEvent: e, RoomID: v.ID()})
}

// OnCards → poker:cards to the owner only.
func (p *pokerEvents) OnCards(v *poker.View, e poker.CardsEvent) {
	cards := e.Cards
	if cards == nil {
		cards = []string{}
	}
	p.h.emitToUser(e.UserID, EvPokerCards, PokerCardsEvent{RoomID: v.ID(), Cards: cards})
}

// OnTurn → room poker:turn (no options) + user poker:yourTurn (options).
func (p *pokerEvents) OnTurn(v *poker.View, e poker.TurnEvent) {
	p.h.emitToRoom(v.ID(), EvPokerTurn, PokerTurnEvent{
		RoomID: v.ID(), UserID: e.UserID, SeatIndex: e.SeatIndex, Street: e.Street, Deadline: e.Deadline, TimeoutMs: e.TimeoutMs,
	})
	p.h.emitToUser(e.UserID, EvPokerYourTurn, PokerYourTurnEvent{
		RoomID: v.ID(), Street: e.Street, Deadline: e.Deadline, TimeoutMs: e.TimeoutMs, Options: e.Options,
	})
}

// OnAction: a fold the clock made counts as a timeout; room poker:action.
func (p *pokerEvents) OnAction(v *poker.View, e poker.ActionEvent) {
	if e.Reason == "timeout" {
		if m := p.h.mx(); m != nil {
			m.TurnTimeoutsTotal.Inc()
		}
	}
	p.h.emitToRoom(v.ID(), EvPokerActionOut, PokerActionEvent{ActionEvent: e, RoomID: v.ID()})
}

// OnStreet → room poker:street.
func (p *pokerEvents) OnStreet(v *poker.View, e poker.StreetEvent) {
	if e.Community == nil {
		e.Community = []string{}
	}
	p.h.emitToRoom(v.ID(), EvPokerStreet, PokerStreetEvent{StreetEvent: e, RoomID: v.ID()})
}

// OnDraw → room poker:draw.
func (p *pokerEvents) OnDraw(v *poker.View, e poker.DrawEvent) {
	p.h.emitToRoom(v.ID(), EvPokerDraw, PokerDrawEvent{DrawEvent: e, RoomID: v.ID()})
}

// OnShowdown → room poker:showdown.
func (p *pokerEvents) OnShowdown(v *poker.View, e poker.ShowdownEvent) {
	if e.Reveals == nil {
		e.Reveals = []poker.Reveal{}
	}
	if e.Community == nil {
		e.Community = []string{}
	}
	p.h.emitToRoom(v.ID(), EvPokerShowdown, PokerShowdownEvent{ShowdownEvent: e, RoomID: v.ID()})
}

// OnHandEnded: games_abandoned_total / games_completed_total{category,
// reason}; pot_settled_chips_total += every pot paid; room poker:handEnded.
func (p *pokerEvents) OnHandEnded(v *poker.View, e poker.HandEndedEvent) {
	if m := p.h.mx(); m != nil {
		category := categoryLabel(v.Category())
		if e.Reason == poker.WinAllLeft {
			m.GamesAbandonedTotal.WithLabelValues(category).Inc()
		} else {
			m.GamesCompletedTotal.WithLabelValues(category, metrics.SafeLabel(string(e.Reason), knownPokerWinReasons, metrics.OtherLabel)).Inc()
			var paid int64
			for _, pot := range e.Pots {
				for _, w := range pot.Winners {
					paid += w.Amount
				}
			}
			if paid > 0 {
				m.PotSettledTotal.Add(float64(paid))
			}
		}
	}
	if e.Pots == nil {
		e.Pots = []poker.PotResult{}
	}
	if e.Reveals == nil {
		e.Reveals = []poker.Reveal{}
	}
	if e.Community == nil {
		e.Community = []string{}
	}
	if e.Summary == nil {
		e.Summary = []poker.HandSummaryEntry{}
	}
	p.h.emitToRoom(v.ID(), EvPokerHandEnded, PokerHandEndedEvent{HandEndedEvent: e, RoomID: v.ID()})
}

// invalidMoveEvents are the inbound events whose refusals count in
// game_invalid_moves_total{code}.
var invalidMoveEvents = map[string]struct{}{EvGameAction: {}, EvGameSelectVariation: {}, EvPokerAction: {}}
