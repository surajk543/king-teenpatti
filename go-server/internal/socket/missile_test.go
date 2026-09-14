package socket

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// game:action {action:"missile"} goes through the guard like every move:
// validated (case-sensitive action, the turn), refused twice over (ack +
// game:error) with its own no_missiles code, and acked with the missiles left.
// Every player hears game:action, then game:showdown with every hand still in,
// then game:handEnded with reason missile — whose nextHandAt carries
// MISSILE_REVEAL_EXTRA_MS, and the next deal keeps to it. The move and the hand
// are counted under their own labels.
func TestAMissileIsGuardedAckedAndShowsEveryHandToTheRoom(t *testing.T) {
	const extra = 600 * time.Millisecond
	st := newStack(t, func(cfg *config.Config) { cfg.Game.MissileRevealExtra = extra })
	f := st.forcedTable()
	players := []*player{f.onTurn, f.asked, f.bystander}

	onTurn := st.view(f.table, f.onTurn.user.ID).You
	if !onTurn.CanMissile || onTurn.Options == nil || !onTurn.Options.CanMissile {
		t.Fatalf("the player on turn with three in the hand is offered a missile: %+v", onTurn)
	}
	if st.view(f.table, f.bystander.user.ID).You.CanMissile {
		t.Fatal("a player off turn is offered a missile")
	}
	state, ok := f.onTurn.c.Last(EvRoomState)
	if !ok || !strings.Contains(string(state), `"canMissile":true`) {
		t.Fatalf("room:state carries you.canMissile: %s", state)
	}

	st.mustFail(f.onTurn.c, EvGameAction, map[string]any{"action": "Missile"}, game.CodeUnknownAction)
	st.mustFail(f.bystander.c, EvGameAction, map[string]any{"action": "missile", "actionId": "off-turn"}, game.CodeNotYourTurn)

	mark := f.onTurn.c.Mark()
	ack := st.mustFail(f.onTurn.c, EvGameAction, map[string]any{"action": "missile", "actionId": "broke"}, game.CodeNoMissiles)
	if ack.Message != game.MsgNoMissiles {
		t.Fatalf("no_missiles message %q", ack.Message)
	}
	if _, err := f.onTurn.c.WaitFrom(mark, EvGameError, func(raw json.RawMessage) bool { return str(raw, "code") == game.CodeNoMissiles }, eventTimeout); err != nil {
		t.Fatalf("the refusal is also emitted as game:error: %v", err)
	}
	if v := metricValue(st.metrics.InvalidMovesTotal.WithLabelValues(game.CodeNoMissiles)); v != 1 {
		t.Fatalf("invalid_moves_total{no_missiles} = %v", v)
	}
	if st.missiles.Charges() != 0 || !f.table.HasHand() {
		t.Fatal("a refused missile spent one or ended the hand")
	}

	st.missiles.Set(f.onTurn.user.ID, 3)
	marks := map[*player]int{}
	for _, p := range players {
		marks[p] = p.c.Mark()
	}
	before := time.Now().UnixMilli()
	ack = st.mustOK(f.onTurn.c, EvGameAction, map[string]any{"action": "missile", "actionId": "sock-missile-1"})
	after := time.Now().UnixMilli()
	var body map[string]any
	if err := json.Unmarshal(ack.Raw, &body); err != nil {
		t.Fatal(err)
	}
	if len(body) != 3 || body["ok"] != true || body["action"] != "missile" || body["missiles"] != float64(2) {
		t.Fatalf("ack %s", ack.Raw)
	}
	if st.missiles.Balance(f.onTurn.user.ID) != 2 || st.missiles.Charges() != 1 {
		t.Fatalf("wallet %d after %d charges", st.missiles.Balance(f.onTurn.user.ID), st.missiles.Charges())
	}

	var nextHandAt int64
	for _, p := range players {
		raw, err := p.c.WaitFrom(marks[p], EvGameHandEnded, nil, eventTimeout)
		if err != nil {
			t.Fatalf("%s heard no handEnded: %v", p.user.DisplayName, err)
		}
		var ended struct {
			Reason     string  `json:"reason"`
			WinnerID   *string `json:"winnerId"`
			WinnerName *string `json:"winnerName"`
			Pot        int64   `json:"pot"`
			NextHandAt int64   `json:"nextHandAt"`
		}
		if err := json.Unmarshal(raw, &ended); err != nil || ended.Reason != "missile" || ended.WinnerID == nil || ended.WinnerName == nil || ended.Pot <= 0 {
			t.Fatalf("handEnded to %s: %s", p.user.DisplayName, raw)
		}
		delay := st.cfg.Game.NextHandDelay.Milliseconds() + extra.Milliseconds()
		if ended.NextHandAt < before+delay || ended.NextHandAt > after+delay {
			t.Fatalf("nextHandAt %d, want now + NEXT_HAND_DELAY_MS + MISSILE_REVEAL_EXTRA_MS (%d..%d)", ended.NextHandAt, before+delay, after+delay)
		}
		nextHandAt = ended.NextHandAt

		var order []string
		for _, e := range p.c.Since(marks[p]) {
			switch e.Name {
			case EvGameActionOut, EvGameShowdown, EvGameHandEnded:
				order = append(order, e.Name)
			}
		}
		if strings.Join(order, ",") != "game:action,game:showdown,game:handEnded" {
			t.Fatalf("%s heard %v", p.user.DisplayName, order)
		}
		action, _ := p.c.WaitFrom(marks[p], EvGameActionOut, nil, eventTimeout)
		if str(action, "action") != "missile" || str(action, "userId") != f.onTurn.user.ID || field(action, "amount") != float64(0) || field(action, "reason") != nil {
			t.Fatalf("game:action to %s: %s", p.user.DisplayName, action)
		}
		showdown, _ := p.c.WaitFrom(marks[p], EvGameShowdown, nil, eventTimeout)
		var sd struct {
			Reason  string        `json:"reason"`
			Reveals []game.Reveal `json:"reveals"`
		}
		if err := json.Unmarshal(showdown, &sd); err != nil || sd.Reason != "missile" || len(sd.Reveals) != 3 {
			t.Fatalf("game:showdown to %s: %s", p.user.DisplayName, showdown)
		}
		for _, r := range sd.Reveals {
			if len(r.Cards) != 3 {
				t.Fatalf("a reveal without its cards: %s", showdown)
			}
		}
	}

	if _, err := f.bystander.c.WaitFrom(marks[f.bystander], EvGameHandStarted, nil, eventTimeout); err != nil {
		t.Fatalf("no next hand: %v", err)
	}
	if dealt := time.Now().UnixMilli(); dealt < nextHandAt-25 {
		t.Fatalf("the next hand was dealt at %d, before the nextHandAt %d it promised", dealt, nextHandAt)
	}

	if v := metricValue(st.metrics.MovesTotal.WithLabelValues(string(game.ActionMissile))); v != 1 {
		t.Fatalf("moves_total{missile} = %v", v)
	}
	if v := metricValue(st.metrics.GamesCompletedTotal.WithLabelValues("seen", "missile")); v != 1 {
		t.Fatalf("games_completed_total{seen,missile} = %v", v)
	}
}
