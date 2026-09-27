package sim

import (
	"encoding/json"
	"strconv"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/decision"
	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
)

// view is the table as one viewer may see it (the server's serializeFor):
// their own cards only once they have seen them, never anybody else's, their
// options only while they are on turn, and other stacks null where the table
// hides them.
func (t *table) view(viewer *account) roomStateWire {
	v := roomStateWire{RoomID: t.id, Code: t.code, Category: t.entry.Category, ChipsHidden: t.r.hidesChips,
		State: t.state, HandNo: t.handNo, DealerSeat: t.dealer, MaxPlayers: len(t.seats), MinPlayers: minPlayers,
		BootAmount: t.entry.BootAmount, TurnTimeoutMs: t.turnTimeout.Milliseconds(), MaxPot: t.r.maxPot,
		Stake: t.entry.BootAmount, Seats: make([]seatWire, len(t.seats))}
	if !t.startsAt.IsZero() {
		v.StartsAt = ptr(millis(t.startsAt))
	}
	h := t.hand
	if h != nil {
		v.Pot, v.Stake, v.Round = h.pot, h.stake, h.round
		if ss := h.sideshow; ss != nil {
			v.Sideshow = &protocol.SideshowView{FromUserID: ss.from.acct.id, FromSeat: ss.from.idx,
				ToUserID: ss.to.acct.id, ToSeat: ss.to.idx, ExpiresAt: millis(ss.expires)}
		}
		v.Variation = t.variationView()
		v.Turn = &protocol.TurnView{SeatIndex: h.turn}
		if h.turn >= 0 && t.seats[h.turn] != nil {
			v.Turn.UserID = ptr(t.seats[h.turn].acct.id)
		}
		if !h.deadline.IsZero() {
			v.Turn.Deadline = ptr(millis(h.deadline))
		}
	}
	if st := viewer.seat; st != nil && st.t == t {
		you := &youWire{SeatIndex: st.idx, Chips: viewer.chips, Status: st.status, IsBlind: st.isBlind,
			Contributed: st.contributed, MissedTurns: st.missed, MaxMissedTurns: maxMissedTurns, Cards: []string{}}
		if st.isBlind {
			you.BlindMovesLeft = max(0, t.r.maxBlindMoves-st.blindMoves)
		} else {
			you.Cards = append(you.Cards, st.cards...)
			you.Hand = t.ownHand(st)
		}
		if h != nil && h.turn == st.idx && st.status == protocol.SeatActive {
			you.Options = ptr(t.options(st))
		}
		v.You = you
	}
	for i, st := range t.seats {
		if st == nil {
			v.Seats[i] = seatWire{empty: true, SeatIndex: i}
			continue
		}
		w := seatWire{SeatIndex: i, UserID: st.acct.id, DisplayName: st.acct.name, Status: st.status, IsBlind: st.isBlind,
			LastBet: st.lastBet, LastAction: st.lastAction, Contributed: st.contributed,
			Connected: st.acct.sess != nil, CardCount: len(st.cards)}
		if !t.r.hidesChips || st.acct == viewer {
			w.Chips = ptr(st.acct.chips)
		}
		v.Seats[i] = w
	}
	return v
}

// variationView is room:state.variation: absent between hands and on seen
// and blind tables.
func (t *table) variationView() *protocol.VariationView {
	h := t.hand
	if h == nil || h.vw == nil {
		return nil
	}
	vw := h.vw
	out := &protocol.VariationView{Selecting: vw.open, UserID: vw.chooser.id, DisplayName: vw.chooser.name,
		SeatIndex: vw.seatIdx, StartedAt: millis(vw.started), Deadline: ptr(millis(vw.deadline)),
		TimeoutMs: variationWindow.Milliseconds(), Options: variations, CardsPerPlayer: 3}
	if !vw.open {
		out.Selected, out.SelectedBy = ptr(vw.selected), ptr(vw.by)
	}
	return out
}

// ownHand is you.hand on a variation table once the viewer has seen and the
// variation is chosen: their three cards as the classic ranking names them.
func (t *table) ownHand(st *seat) *protocol.YouHand {
	h := t.hand
	if h == nil || h.vw == nil || h.vw.open || len(st.cards) != 3 {
		return nil
	}
	hand, err := decision.Rank(st.cards)
	if err != nil {
		return nil
	}
	return &protocol.YouHand{HandName: hand.Name, Category: hand.Category, Wild: []string{},
		PlaysAs: append([]string(nil), st.cards...), Best: append([]string(nil), st.cards...)}
}

// emitState sends every connected player at the table their own snapshot.
func (t *table) emitState() {
	for _, st := range t.seats {
		if st != nil && st.acct.sess != nil {
			t.s.send(st.acct.sess, protocol.EvRoomState, t.view(st.acct))
		}
	}
}

// broadcast sends one payload to every connected player at the table.
func (t *table) broadcast(event string, payload any) {
	body, err := json.Marshal(payload)
	if err != nil {
		t.s.log.Error("sim: cannot marshal an event", "event", event, "error", err)
		return
	}
	for _, st := range t.seats {
		if st != nil {
			t.s.sendRaw(st.acct.sess, event, body)
		}
	}
}

func (t *table) broadcastAction(st *seat, action string, amount int64, reason string, auto *bool) {
	pot, stake := int64(0), int64(0)
	if t.hand != nil {
		pot, stake = t.hand.pot, t.hand.stake
	}
	t.broadcast(protocol.EvGameActionOut, protocol.ActionEvent{RoomID: t.id, UserID: st.acct.id, Action: action,
		Amount: amount, Auto: auto, Pot: pot, Stake: stake, Reason: reason})
}

// post adds a chat line and sends it to the room; a nil user is the table's
// own line (joined, left).
func (t *table) post(userID *string, name, text string, system bool) chatWire {
	t.s.messageSeq++
	msg := chatWire{ID: t.s.uuid("chat", strconv.Itoa(t.s.messageSeq)), UserID: userID, DisplayName: name,
		Text: text, At: millis(t.s.now()), System: system, RoomID: t.id}
	t.broadcast(protocol.EvChatMessage, msg)
	return msg
}

func (t *table) system(text string) { t.post(nil, "", text, true) }
