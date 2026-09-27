package sim

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
	"github.com/surajk543/king-teenpatti/bot-play/internal/rng"
)

// The request handlers: each answers (ack, nil) or (nil, refusal), with the
// server's codes and messages (game/roommanager.go, game/errors.go), checked
// in the server's order.

var (
	refAlreadyInRoom = refuse(protocol.CodeAlreadyInRoom, "You are already seated at a table")
	refNotAtTable    = refuse(protocol.CodeNotInRoom, "You are not at a table")
	refNoHand        = refuse(protocol.CodeNoHand, "No hand is in progress")
	refNotInHand     = refuse(protocol.CodeNotInHand, "You are not in this hand")
)

// quickJoin is room:quickJoin {bootAmount?, category?}: the fullest open
// table of that category and boot, or a new one.
func (s *Server) quickJoin(c *session, raw json.RawMessage) (any, *refusal) {
	var req struct {
		BootAmount json.RawMessage `json:"bootAmount"`
		Category   json.RawMessage `json:"category"`
	}
	decode(raw, &req)
	acct := c.acct
	if acct.seat != nil {
		return nil, refAlreadyInRoom
	}
	boot := int64(200)
	if b := string(bytes.TrimSpace(req.BootAmount)); b != "" && b != "null" {
		if n, err := strconv.ParseInt(b, 10, 64); err == nil && n > 0 {
			boot = n
		} else {
			return nil, refuse(protocol.CodeInvalidStake, "That stake is not valid")
		}
	}
	if !slices.Contains(s.stakes(), boot) {
		parts := []string{}
		for _, b := range s.stakes() {
			parts = append(parts, strconv.FormatInt(b, 10))
		}
		return nil, refuse(protocol.CodeInvalidStake, "Stake must be one of: "+strings.Join(parts, ", "))
	}
	var category string
	_ = json.Unmarshal(req.Category, &category)
	if category != protocol.CategoryBlind && category != protocol.CategoryVariation {
		category = protocol.CategorySeen // the server's NormalizeCategory: exact matches only
	}
	entry, ok := s.entryFor(category, boot)
	if !ok {
		parts := []string{}
		for _, e := range s.menu {
			parts = append(parts, e.Category+" "+strconv.FormatInt(e.BootAmount, 10))
		}
		return nil, refuse(protocol.CodeTableNotOffered, "The lobby offers: "+strings.Join(parts, ", "))
	}
	if ref := admits(acct, entry); ref != nil {
		return nil, ref
	}
	var pick *table
	for _, t := range s.tables {
		if t.entry.Key == entry.Key && !t.full() && (pick == nil || t.occupied() > pick.occupied()) {
			pick = t
		}
	}
	if pick == nil {
		pick = s.newTable(entry)
	}
	pick.sit(acct)
	return roomAck{OK: true, RoomID: pick.id, Code: pick.code, Category: pick.entry.Category}, nil
}

// joinCode is room:joinCode {code}: the door a resume offer uses.
func (s *Server) joinCode(c *session, raw json.RawMessage) (any, *refusal) {
	var req struct {
		Code string `json:"code"`
	}
	decode(raw, &req)
	acct := c.acct
	if acct.seat != nil {
		return nil, refAlreadyInRoom
	}
	code := strings.ToUpper(req.Code)
	valid := len(code) == 8
	for _, r := range code {
		valid = valid && (unicode.IsDigit(r) || (r >= 'A' && r <= 'Z'))
	}
	if !valid {
		return nil, refuse(protocol.CodeInvalidRoomCode, "Table codes are 8 letters and numbers")
	}
	t := s.byCode[code]
	if t == nil || t.dead {
		return nil, refuse(protocol.CodeRoomNotFound, "No table with that code")
	}
	if t.full() {
		return nil, refuse(protocol.CodeTableFull, "That table is full")
	}
	if ref := admits(acct, t.entry); ref != nil {
		return nil, ref
	}
	t.sit(acct)
	return roomAck{OK: true, RoomID: t.id, Code: t.code, Category: t.entry.Category}, nil
}

// switchTable is room:switch: another open table of the same category and
// boot with the fewest players (the oldest on a tie — the server draws
// one), else a new one. The stack must cover the boot before the seat is
// given up; the stack band is not applied, as the server does not.
func (s *Server) switchTable(c *session) (any, *refusal) {
	acct := c.acct
	st := acct.seat
	if st == nil {
		return nil, refNotAtTable
	}
	from := st.t
	if acct.chips < from.entry.BootAmount {
		return nil, refuse(protocol.CodeInsufficientChips, "Not enough chips to join this table")
	}
	var to *table
	for _, t := range s.tables {
		if t != from && t.entry.Key == from.entry.Key && !t.full() && (to == nil || t.occupied() < to.occupied()) {
			to = t
		}
	}
	from.removeSeat(st, "moved")
	if to == nil {
		to = s.newTable(from.entry)
	}
	to.sit(acct)
	return roomAck{OK: true, RoomID: to.id, Code: to.code, Category: to.entry.Category}, nil
}

// leave is room:leave: {roomId} when seated, {} when not.
func (s *Server) leave(c *session) (any, *refusal) {
	st := c.acct.seat
	if st == nil {
		return okAck{OK: true}, nil
	}
	t := st.t
	t.removeSeat(st, "left")
	s.send(c, protocol.EvRoomLeft, roomIDWire{RoomID: t.id})
	return leaveAck{OK: true, RoomID: t.id}, nil
}

// admits applies a lobby door's checks: the boot, then the stack band.
func admits(acct *account, e protocol.TableEntry) *refusal {
	switch {
	case acct.chips < e.BootAmount:
		return refuse(protocol.CodeInsufficientChips, "Not enough chips to join this table")
	case e.MinChips > 0 && acct.chips < e.MinChips:
		return refuse(protocol.CodeBelowTableMinimum, fmt.Sprintf("This table is for players with %s chips or more", thousands(e.MinChips)))
	case e.MaxChips > 0 && acct.chips > e.MaxChips:
		return refuse(protocol.CodeOverEntryCap, fmt.Sprintf("Players with more than %s chips cannot join this table", thousands(e.MaxChips)))
	}
	return nil
}

// act is game:action {action, amount?, actionId?}.
func (s *Server) act(c *session, raw json.RawMessage) (any, *refusal) {
	var req struct {
		Action   string          `json:"action"`
		Amount   json.RawMessage `json:"amount"`
		ActionID string          `json:"actionId"`
	}
	decode(raw, &req)
	st := c.acct.seat
	if st == nil {
		return nil, refNotAtTable
	}
	switch req.Action {
	case protocol.ActionSee, protocol.ActionChaal, protocol.ActionRaise, protocol.ActionPack, protocol.ActionShow,
		protocol.ActionSideshow, protocol.ActionForceSideshow, protocol.ActionMissile:
	default:
		return nil, refuse("unknown_action", fmt.Sprintf("Unknown action %q", req.Action))
	}
	var amount *int64 // absent or null: the kind's default; else a JSON number that is a safe integer
	if a := string(bytes.TrimSpace(req.Amount)); a != "" && a != "null" {
		var f float64
		if json.Unmarshal(req.Amount, &f) != nil || f != math.Trunc(f) || math.Abs(f) > 1<<53-1 {
			return nil, refuse(protocol.CodeInvalidBet, "Bet amount must be a whole number")
		}
		amount = ptr(int64(f))
	}
	ack, ref := st.t.act(st, req.Action, amount, req.ActionID)
	if ref == nil {
		s.stats.Moves++
	}
	return ack, ref
}

// respondSideshow is game:sideshowRespond {accept}: only a JSON true accepts.
func (s *Server) respondSideshow(c *session, raw json.RawMessage) (any, *refusal) {
	var req struct {
		Accept json.RawMessage `json:"accept"`
	}
	decode(raw, &req)
	st := c.acct.seat
	if st == nil {
		return nil, refNotAtTable
	}
	t := st.t
	if t.hand == nil {
		return nil, refNoHand
	}
	ss := t.hand.sideshow
	if ss == nil {
		return nil, refuse(protocol.CodeNoSideshow, "There is no sideshow to answer")
	}
	if ss.to != st {
		return nil, refuse("not_your_sideshow", "That sideshow was not asked of you")
	}
	accept := string(bytes.TrimSpace(req.Accept)) == "true"
	reason := "declined"
	if accept {
		reason = "accepted"
	}
	st.missed = 0
	packed := t.resolveSideshow(accept, reason)
	return sideshowAck{OK: true, Accepted: accept, PackedUserID: packed}, nil
}

// selectVariation is game:selectVariation {variation}: the chooser's answer.
func (s *Server) selectVariation(c *session, raw json.RawMessage) (any, *refusal) {
	var req struct {
		Variation string `json:"variation"`
	}
	decode(raw, &req)
	st := c.acct.seat
	if st == nil {
		return nil, refNotAtTable
	}
	t := st.t
	h := t.hand
	switch {
	case h == nil:
		return nil, refNoHand
	case h.vw == nil:
		return nil, refuse("no_variation", "This table does not play variations")
	case !h.vw.open:
		return nil, refuse(protocol.CodeVariationSelected, "The variation has already been chosen")
	case h.vw.chooser != c.acct:
		return nil, refuse(protocol.CodeNotSelecting, "It is not your turn to choose the variation")
	case !slices.Contains(variations, req.Variation):
		return nil, refuse(protocol.CodeInvalidVariation, "That is not a variation this table offers")
	case !s.now().Before(h.vw.deadline):
		t.closeVariation(protocol.VariationMuflis, "TIMEOUT", true)
		t.emitState()
		return nil, refuse(protocol.CodeVariationExpired, "Time ran out, so Muflis was chosen")
	}
	st.missed = 0
	t.closeVariation(req.Variation, "PLAYER", true)
	t.emitState()
	return variationAck{OK: true, Variation: req.Variation, SelectedBy: "PLAYER", CardsPerPlayer: 3}, nil
}

// selectCards is game:selectCards: nothing is ever picked here, since the
// simulation deals no 5-Card hands.
func (s *Server) selectCards(c *session) (any, *refusal) {
	st := c.acct.seat
	switch {
	case st == nil:
		return nil, refNotAtTable
	case st.t.hand == nil:
		return nil, refNoHand
	case st.status != protocol.SeatActive:
		return nil, refNotInHand
	}
	return nil, refuse(protocol.CodeNotPicking, "There are no cards to choose here")
}

// chat is chat:message {text}: five lines per five seconds, 140 characters.
func (s *Server) chat(c *session, raw json.RawMessage) (any, *refusal) {
	var req struct {
		Text string `json:"text"`
	}
	decode(raw, &req)
	st := c.acct.seat
	if st == nil {
		return nil, refNotAtTable
	}
	if !c.chatLimit.allow(s.now(), chatLimit, chatWindow) {
		return nil, refuse(protocol.CodeChatRateLimited, "You are sending messages too quickly")
	}
	text := []rune(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, strings.TrimSpace(req.Text)))
	text = []rune(strings.TrimSpace(string(text[:min(len(text), chatMaxLength)])))
	if len(text) == 0 {
		return okAck{OK: true}, nil
	}
	msg := st.t.post(&c.acct.id, c.acct.name, string(text), false)
	return chatAck{OK: true, MessageID: msg.ID}, nil
}

// newTable opens a table of a menu entry.
func (s *Server) newTable(e protocol.TableEntry) *table {
	s.tableSeq++
	t := &table{s: s, serial: s.tableSeq, entry: e, r: rulesFor(e),
		turnTimeout: time.Duration(e.TurnTimeoutMs) * time.Millisecond,
		seats:       make([]*seat, s.cfg.MaxPlayers), state: protocol.TableWaiting, dealer: -1,
		deck: rng.Derive(s.cfg.Seed^saltDeck, s.tableSeq)}
	t.id = s.uuid("table", strconv.Itoa(t.serial))
	t.code = s.roomCode(t.serial)
	s.tables = append(s.tables, t)
	s.byCode[t.code] = t
	s.log.Debug("table opened", "roomId", t.id, "table", e.Key)
	return t
}

// thousands is 1234567 → "1,234,567" (the server's formatThousands).
func thousands(n int64) string {
	d := strconv.FormatInt(n, 10)
	var b strings.Builder
	for i, r := range d {
		if i > 0 && (len(d)-i)%3 == 0 && d[i-1] != '-' {
			b.WriteByte(',')
		}
		b.WriteRune(r)
	}
	return b.String()
}
