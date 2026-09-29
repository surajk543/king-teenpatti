package poker

import (
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/game/testclock"
)

// A poker room counts down before a deal exactly as a Teen Patti table does
// (game/countdown.go): the countdown alone for a first deal, the celebration
// and then the countdown after a hand, and startsInMs on its snapshot.

func (h *harness) view(id string) *TableView {
	h.t.Helper()
	v, err := h.table.SerializeFor(id)
	if err != nil {
		h.t.Fatal(err)
	}
	return v
}

func TestAPokerRoomCountsDownBeforeEveryDeal(t *testing.T) {
	h := newHarness(t, TexasHoldem) // NextHandDelay 4 s
	h.seat("a", 5000)

	raw, _ := json.Marshal(h.view("a"))
	var keys map[string]json.RawMessage
	_ = json.Unmarshal(raw, &keys)
	if _, ok := keys["startsInMs"]; ok {
		t.Fatal("waiting: startsInMs must be absent")
	}

	h.seat("b", 5000)
	v := h.view("a")
	if v.State != game.TableStarting || v.StartsInMs == nil || *v.StartsInMs != game.StartCountdown.Milliseconds() {
		t.Fatalf("a first deal: state %s, startsInMs %v, want 3000", v.State, v.StartsInMs)
	}
	h.clock.Advance(game.StartCountdown - time.Millisecond)
	if err := h.act("a", ActionCheck); !isCode(err, game.CodeNoHand) {
		t.Fatalf("a move before the deal: %v, want no_hand", err)
	}
	h.clock.Advance(time.Millisecond)
	if h.handID() == "" {
		t.Fatal("dealt at the end of the countdown")
	}

	// A hand's end: the celebration, then the countdown, to nextHandAt.
	h.mustAct(h.turn(), ActionFold)
	if h.handID() != "" {
		t.Fatal("the hand is over")
	}
	v = h.view("a")
	if v.StartsInMs == nil || *v.StartsInMs != h.cfg.NextHandDelay.Milliseconds() {
		t.Fatalf("after a hand: startsInMs %v, want the whole window", v.StartsInMs)
	}
	end := h.clock.Now()

	// A departure cancels it; a return inside the window keeps the hold.
	h.clock.Advance(500 * time.Millisecond)
	if _, err := h.table.RemovePlayer("b", game.LeaveReasonLeft); err != nil {
		t.Fatal(err)
	}
	if v := h.view("a"); v.State != game.TableWaiting || v.StartsAt != nil || v.StartsInMs != nil {
		t.Fatalf("cancelled: %s %v %v", v.State, v.StartsAt, v.StartsInMs)
	}
	h.seat("c", 5000)
	v = h.view("a")
	if v.StartsAt == nil || *v.StartsAt != game.Millis(end.Add(h.cfg.NextHandDelay)) {
		t.Fatalf("held to the last hand's nextHandAt: %v", v.StartsAt)
	}
	h.clock.Advance(end.Add(h.cfg.NextHandDelay).Sub(h.clock.Now()))
	if h.handID() == "" {
		t.Fatal("dealt at the hold")
	}
}

func isCode(err error, code string) bool {
	var ge *game.GameError
	return errors.As(err, &ge) && ge.Code == code
}

// A refused hand-end settle is retried at the money path's own pace
// (game.SettleRetryBase, 4 s), not the 6 s window between hands the
// countdown made the default — the same rule as a Teen Patti table's.
func TestAPokerRoomRetriesARefusedSettleAfterFourSecondsNotTheWindow(t *testing.T) {
	var mu sync.Mutex
	refuse, calls := true, 0
	ledger := game.NewMemoryLedger(game.MemoryLedgerHooks{
		Settle: func(game.SettleRequest, []game.SettleEntry) (map[string]int64, error) {
			mu.Lock()
			defer mu.Unlock()
			calls++
			if refuse {
				return nil, errors.New("settle down")
			}
			return map[string]int64{}, nil
		},
	})
	h := newHarness(t, TexasHoldem)
	h.cfg.NextHandDelay = 6 * time.Second
	clock := testclock.New(start)
	table := NewTable(TableOptions{
		ID: "room-2", Code: "ROOM0002", Config: h.cfg, Listener: newRecorder(),
		Deps: game.RoomDeps{Clock: clock, Ledger: ledger},
	})
	t.Cleanup(func() { _ = table.Destroy() })
	for _, id := range []string{"a", "b"} {
		if _, err := table.AddPlayer(game.NewPlayer{UserID: id, DisplayName: id, Chips: 5000, SocketID: "s-" + id}); err != nil {
			t.Fatal(err)
		}
	}
	clock.Advance(game.StartCountdown)
	view, err := table.SerializeFor("a")
	if err != nil || view.Turn == nil || view.Turn.UserID == nil {
		t.Fatalf("no hand dealt: %v", err)
	}
	if _, err := table.Act(*view.Turn.UserID, ActionFold, ActRequest{}); err != nil {
		t.Fatal(err)
	}
	count := func() int { mu.Lock(); defer mu.Unlock(); return calls }
	if count() != 1 {
		t.Fatalf("the hand's end settled %d times, want 1", count())
	}
	mu.Lock()
	refuse = false
	mu.Unlock()
	clock.Advance(game.SettleRetryBase - time.Millisecond)
	if count() != 1 {
		t.Fatal("retried before 4 s")
	}
	clock.Advance(time.Millisecond)
	if count() != 2 {
		t.Fatalf("retried %d times at 4 s, want once", count()-1)
	}
}

// A poker room's first turn waits for the app's two-second deal as a Teen
// Patti table's does (game.DealHold); every later turn has its plain clock.
func TestAPokerRoomsFirstTurnWaitsForTheDeal(t *testing.T) {
	h := newHarnessTuned(t, TexasHoldem, nil, func(c *Config) { c.DealHold = game.DealAnimation })
	h.seat("a", 5000)
	h.seat("b", 5000)
	h.clock.Advance(game.StartCountdown)
	if h.handID() == "" {
		t.Fatal("dealt at the end of the countdown")
	}
	dealt := h.clock.Now()
	v := h.view("a")
	if v.Turn.Deadline == nil || *v.Turn.Deadline != game.Millis(dealt.Add(game.DealAnimation+h.cfg.TurnTimeout)) {
		t.Fatalf("the first turn's deadline %v, want the deal's end plus a whole clock", v.Turn.Deadline)
	}
	first := h.turn()
	h.clock.Advance(h.cfg.TurnTimeout)
	if h.turn() != first {
		t.Fatal("a whole clock after the deal the first player is still on turn")
	}
	h.mustAct(first, ActionCall)
	v = h.view("a")
	if *v.Turn.Deadline != game.Millis(h.clock.Now().Add(h.cfg.TurnTimeout)) {
		t.Fatalf("the next turn's deadline %v, want a plain clock", *v.Turn.Deadline)
	}
	if got := snapshotConfig(h.cfg).DealHoldMs; got != 2000 {
		t.Fatalf("saved dealHoldMs %d, want 2000", got)
	}
	back, err := configFrom(snapshotConfig(h.cfg))
	if err != nil || back.DealHold != game.DealAnimation {
		t.Fatalf("restored DealHold %v (%v), want 2 s", back.DealHold, err)
	}
}
