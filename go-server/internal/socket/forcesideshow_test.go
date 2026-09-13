package socket

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// forced is a three-player seen table, every hand looked at, with the player
// on turn, the player on their right (who a sideshow goes to) and the third.
type forced struct {
	table                    *game.Table
	onTurn, asked, bystander *player
}

func (st *stack) forcedTable() *forced {
	st.t.Helper()
	boot := st.uniqueStake()
	ps := []*player{st.player("F1"), st.player("F2"), st.player("F3")}
	for _, p := range ps {
		st.hammers.Set(p.user.ID, 20)
		st.mustOK(p.c, EvRoomQuickJoin, map[string]any{"bootAmount": boot, "category": "seen"})
	}
	if _, err := ps[0].c.Wait(EvGameHandStarted, func(raw json.RawMessage) bool {
		var e struct{ Participants []string }
		return json.Unmarshal(raw, &e) == nil && len(e.Participants) == 3
	}, eventTimeout); err != nil {
		st.t.Fatalf("no three-player hand: %v", err)
	}
	for _, p := range ps {
		if _, err := p.c.Wait(EvRoomState, func(raw json.RawMessage) bool { return str(raw, "state") == "betting" }, eventTimeout); err != nil {
			st.t.Fatalf("no betting snapshot: %v", err)
		}
	}
	for _, p := range ps {
		st.mustOK(p.c, EvGameAction, map[string]any{"action": "see"})
	}
	table := st.rooms.GetTableForPlayer(ps[0].user.ID)
	view := st.view(table, ps[0].user.ID)
	byID := map[string]*player{}
	for _, p := range ps {
		byID[p.user.ID] = p
	}
	f := &forced{table: table, onTurn: byID[*view.Turn.UserID]}
	// The player on the right is the nearest occupied seat BELOW the one on
	// turn, wrapping round to the top.
	turnSeat := view.Turn.SeatIndex
	best, top := -1, -1
	for _, s := range view.Seats {
		if s.Empty || s.SeatIndex == turnSeat {
			continue
		}
		if s.SeatIndex < turnSeat && s.SeatIndex > best {
			best = s.SeatIndex
		}
		if s.SeatIndex > top {
			top = s.SeatIndex
		}
	}
	if best < 0 {
		best = top
	}
	for _, s := range view.Seats {
		if !s.Empty && s.SeatIndex == best {
			f.asked = byID[s.UserID]
		}
	}
	for _, p := range ps {
		if p != f.onTurn && p != f.asked {
			f.bystander = p
		}
	}
	return f
}

// game:action {action:"forceSideshow"} goes through the guard like every move:
// validated (case-sensitive action, the seat, the turn), refused twice over
// (ack + game:error) with its own no_hammers code, and acked with the hammers
// left. The two players see each other's cards; the third hears only how it
// ended; the move is counted under its own action label.
func TestForceSideshowIsGuardedValidatedAndAcked(t *testing.T) {
	st := newStack(t, nil)
	f := st.forcedTable()

	if opts := st.view(f.table, f.onTurn.user.ID).You.Options; opts == nil || !opts.CanForceSideshow || !opts.CanSideshow {
		t.Fatalf("the player on turn is offered both sideshows: %+v", opts)
	}
	st.mustFail(f.onTurn.c, EvGameAction, map[string]any{"action": "ForceSideshow"}, game.CodeUnknownAction)
	st.mustFail(f.bystander.c, EvGameAction, map[string]any{"action": "forceSideshow", "actionId": "off-turn"}, game.CodeNotYourTurn)

	st.hammers.Set(f.onTurn.user.ID, 0)
	mark := f.onTurn.c.Mark()
	ack := st.mustFail(f.onTurn.c, EvGameAction, map[string]any{"action": "forceSideshow", "actionId": "broke"}, game.CodeNoHammers)
	if ack.Message != game.MsgNoHammers {
		t.Fatalf("no_hammers message %q", ack.Message)
	}
	if _, err := f.onTurn.c.WaitFrom(mark, EvGameError, func(raw json.RawMessage) bool { return str(raw, "code") == game.CodeNoHammers }, eventTimeout); err != nil {
		t.Fatalf("the refusal is also emitted as game:error: %v", err)
	}
	if v := metricValue(st.metrics.InvalidMovesTotal.WithLabelValues(game.CodeNoHammers)); v != 1 {
		t.Fatalf("invalid_moves_total{no_hammers} = %v", v)
	}
	if st.hammers.Charges() != 0 || st.view(f.table, f.onTurn.user.ID).You.Options == nil {
		t.Fatal("a refused Force Sideshow spent a hammer or moved the turn")
	}

	st.hammers.Set(f.onTurn.user.ID, 20)
	ack = st.mustOK(f.onTurn.c, EvGameAction, map[string]any{"action": "forceSideshow", "actionId": "sock-force-1"})
	var body map[string]any
	if err := json.Unmarshal(ack.Raw, &body); err != nil {
		t.Fatal(err)
	}
	if len(body) != 5 || body["action"] != "forceSideshow" || body["toUserId"] != f.asked.user.ID || body["hammers"] != float64(19) {
		t.Fatalf("ack %s", ack.Raw)
	}
	packed, _ := body["packedUserId"].(string)
	if packed != f.onTurn.user.ID && packed != f.asked.user.ID {
		t.Fatalf("packedUserId %q is neither of the two", packed)
	}
	if st.hammers.Balance(f.onTurn.user.ID) != 19 || st.hammers.Charges() != 1 {
		t.Fatalf("wallet %d after %d charges", st.hammers.Balance(f.onTurn.user.ID), st.hammers.Charges())
	}

	for _, p := range []*player{f.onTurn, f.asked} {
		raw, err := p.c.Wait(EvGameSideshowRev, nil, eventTimeout)
		if err != nil {
			t.Fatalf("%s saw no reveal: %v", p.user.DisplayName, err)
		}
		var e struct {
			Reveal game.SideshowReveal `json:"reveal"`
		}
		if err := json.Unmarshal(raw, &e); err != nil || e.Reveal.Reason != game.SideshowForced || e.Reveal.PackedUserID != packed || len(e.Reveal.Hands) != 2 {
			t.Fatalf("reveal to %s: %s", p.user.DisplayName, raw)
		}
	}
	raw, err := f.bystander.c.Wait(EvGameSideshowRes, nil, eventTimeout)
	if err != nil {
		t.Fatal(err)
	}
	var resolved game.SideshowResolvedEvent
	if err := json.Unmarshal(raw, &resolved); err != nil || resolved.Reason != game.SideshowForced || !resolved.Accepted ||
		resolved.FromUserID != f.onTurn.user.ID || resolved.ToUserID != f.asked.user.ID || resolved.PackedUserID == nil || *resolved.PackedUserID != packed {
		t.Fatalf("the room hears %s", raw)
	}
	time.Sleep(100 * time.Millisecond)
	if n := len(f.bystander.c.All(EvGameSideshowRev)); n != 0 {
		t.Fatalf("the third player received %d reveals", n)
	}
	for _, p := range []*player{f.onTurn, f.asked, f.bystander} {
		if n := len(p.c.All(EvGameSideshowReq)); n != 0 {
			t.Fatalf("%s was sent a sideshow request", p.user.DisplayName)
		}
	}
	if v := metricValue(st.metrics.MovesTotal.WithLabelValues(string(game.ActionForceSideshow))); v != 1 {
		t.Fatalf("moves_total{forceSideshow} = %v", v)
	}

	// The same request again is refused — whichever way the hand went — and
	// charges nothing.
	ack = st.mustFail(f.onTurn.c, EvGameAction, map[string]any{"action": "forceSideshow", "actionId": "sock-force-1"}, "")
	switch ack.Code {
	case game.CodeAlreadyAsked, game.CodeNotYourTurn, game.CodeNotInHand:
	default:
		t.Fatalf("a replayed Force Sideshow: %s", ack.Raw)
	}
	if st.hammers.Charges() != 1 {
		t.Fatalf("a replay was charged: %d charges", st.hammers.Charges())
	}
}
