package game_test

// Regression tests for the 24 Sep 2026 release review (owner: "fix all
// bugs"): a room:switch or a consolidation move must never take a player off
// their seat to put them somewhere that will not have them. The target's boot
// (and a poker room's buy-in) is checked on the stack the seat holds BEFORE
// the seat is given up — insufficient_chips, and the player stays put. The
// stack BAND is deliberately not applied (TestRoomsSwitchIgnoresTheStackBand).

import (
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/poker"
)

func withUnfundedGrace(g *config.GameConfig, _ *game.RoomManagerOptions) {
	g.UnfundedGrace = time.Hour
}

// LR-4 / TPS-5: a seat short of the boot, held under the unfunded grace,
// used to hop to another table of the pair — and every landing granted a
// fresh grace, so it was never shown out. Refused now, as quick-join refuses
// the same stack, and the player keeps the seat (and the grace) they had.
func TestASwitchIsRefusedToAStackBelowTheTargetsBootAndKeepsTheSeat(t *testing.T) {
	f := newRoomsFixture(t, withUnfundedGrace)
	first := f.createTable(game.CreateTableOptions{BootAmount: 200, Category: "seen"})
	second := f.createTable(game.CreateTableOptions{BootAmount: 200, Category: "seen"})
	f.mustJoin(second, f.player("Other", 10_000))
	short := f.player("Short", 150)
	f.mustJoin(first, short)

	_, err := f.rooms.SwitchTable(short)
	expectCode(t, err, game.CodeInsufficientChips)
	if at := f.rooms.GetTableForPlayer(short.ID); at == nil || at.ID() != first.ID() {
		t.Fatalf("the refused switch moved or unseated the player: %v", at)
	}
	if ids := seatedIDs(t, first); !equalStrings(ids, []string{short.ID}) {
		t.Fatalf("first table seats %v", ids)
	}
	if ids := seatedIDs(t, second); len(ids) != 1 {
		t.Fatalf("second table seats %v", ids)
	}
	// Exactly the boot may still move.
	even := f.player("Even", 200)
	third := f.createTable(game.CreateTableOptions{BootAmount: 200, Category: "blind"})
	fourth := f.createTable(game.CreateTableOptions{BootAmount: 200, Category: "blind"})
	f.mustJoin(fourth, f.player("Q", 10_000))
	f.mustJoin(third, even)
	if res, err := f.rooms.SwitchTable(even); err != nil || res.To.ID() != fourth.ID() {
		t.Fatalf("a stack of exactly the boot was refused a switch: %v", err)
	}
}

// losePokerBlind seats a (exactly the buy-in) and b at room, deals, and has
// a — the button, so the small blind, first to act heads-up — fold, leaving
// a below the buy-in but above the boot. Returns a's stack.
func losePokerBlind(t *testing.T, f *roomsFixture, room game.Room, a, b game.Player) int64 {
	t.Helper()
	f.mustJoin(room, a)
	f.mustJoin(room, b)
	pt := room.(*poker.Table)
	if err := pt.StartHand(); err != nil {
		t.Fatal(err)
	}
	if _, err := pt.Act(a.ID, poker.ActionFold, poker.ActRequest{}); err != nil {
		t.Fatalf("a folds: %v", err)
	}
	seat, err := room.FindSeat(a.ID)
	if err != nil || seat == nil {
		t.Fatalf("a's seat: %v", err)
	}
	return seat.Chips
}

// PM-5 / LR-5: a poker stack below the buy-in asked to switch. It used to be
// taken off its seat, refused by the target's buy-in, then refused its OWN
// seat back by the same buy-in — seated nowhere. Now it is refused before
// anything moves.
func TestAPokerSwitchBelowTheBuyInIsRefusedAndKeepsTheSeat(t *testing.T) {
	f := newRoomsFixture(t, withUnfundedGrace)
	first := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: 50_000, Category: "texas_holdem"})
	second := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: 50_000, Category: "texas_holdem"})
	buyIn := first.RulesSpec().MinBuyIn
	if buyIn != 500_000 {
		t.Fatalf("buy-in %d", buyIn)
	}
	f.mustJoin(second, f.player("Other", 1_000_000))
	a := f.player("A", buyIn)
	chips := losePokerBlind(t, f, first, a, f.player("B", 1_000_000))
	if chips >= buyIn || chips < 50_000 {
		t.Fatalf("a holds %d", chips)
	}

	_, err := f.rooms.SwitchTable(a)
	expectCode(t, err, game.CodeInsufficientChips)
	if at := f.rooms.GetTableForPlayer(a.ID); at == nil || at.ID() != first.ID() {
		t.Fatalf("the refused switch unseated the player: %v", at)
	}
	if seat, err := first.FindSeat(a.ID); err != nil || seat == nil || seat.Chips != chips {
		t.Fatalf("a's seat after the refusal: %+v %v", seat, err)
	}
}

// PM-4: consolidation must not unseat a poker player whose stack fell below
// the buy-in. It used to move them off, be refused by the target's buy-in,
// fail to put them back (the same buy-in) and leave them seated nowhere, told
// nothing. Now the move is skipped and they keep playing where they are.
func TestConsolidationLeavesAPokerStackBelowTheBuyInWhereItIs(t *testing.T) {
	f := newRoomsFixture(t, withUnfundedGrace)
	older := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: 50_000, Category: "texas_holdem"})
	f.clock.Advance(time.Second)
	newer := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: 50_000, Category: "texas_holdem"})
	f.mustJoin(older, f.player("P", 1_000_000))
	a := f.player("A", newer.RulesSpec().MinBuyIn)
	b := f.player("B", 1_000_000)
	chips := losePokerBlind(t, f, newer, a, b)
	f.mustLeave(b.ID, game.LeaveReasonLeft)
	f.mustConsolidate()

	if at := f.rooms.GetTableForPlayer(a.ID); at == nil || at.ID() != newer.ID() {
		t.Fatalf("consolidation moved or unseated a stack below the buy-in: %v", at)
	}
	if seat, err := newer.FindSeat(a.ID); err != nil || seat == nil || seat.Chips != chips {
		t.Fatalf("a's seat: %+v %v", seat, err)
	}
	if text := f.logText(); containsAny(text, "could not restore the seat", "table consolidation failed") {
		t.Fatalf("a failed move was attempted:\n%s", text)
	}
}

func containsAny(s string, subs ...string) bool {
	for _, sub := range subs {
		if strings.Contains(s, sub) {
			return true
		}
	}
	return false
}
