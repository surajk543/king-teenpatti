package game_test

import (
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// A player who bets and then switches tables must carry their REDUCED stack to
// the new seat.
//
// The bug this guards: SwitchTable was handed a game.Player whose Chips had
// been read from the wallet before the switch began. Leaving mid-hand is a
// checkpoint (CLAUDE.md §5.1), so by the time the player is re-seated that
// figure is stale by exactly what they had staked — and re-seating on it gave
// the stake back. The ledger was right and the seat was wrong.
//
// It compounded: the inflated seat also became `chipsWritten` for the next
// hand, so every later checkpoint was computed against a base above the
// wallet. On production this drifted 573 bot accounts (the fleet switches
// tables every few minutes) until a delta outran the wallet and the overdraft
// clamp fired.
func TestSwitchingTablesCarriesTheReducedStackNotTheStaleWallet(t *testing.T) {
	f := newRoomsFixture(t, nil)

	const start int64 = 2_000_000
	home := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: 200, Category: "blind"})
	away := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: 200, Category: "blind"})
	a, b := seatTwoAndDeal(t, f, home, start)

	// Whoever is on turn plays a chaal, so their seat is now demonstrably
	// below the wallet the switch would otherwise re-seat them on.
	mover := a
	if turnUser(t, home) == b.ID {
		mover = b
	}
	if _, err := home.Act(mover.ID, game.ActionChaal, game.ActRequest{}); err != nil {
		t.Fatalf("chaal: %v", err)
	}

	seat, err := home.FindSeat(mover.ID)
	if err != nil || seat == nil {
		t.Fatalf("seat before the switch: %v", err)
	}
	staked := start - seat.Chips
	if staked <= 0 {
		t.Fatalf("the boot and the chaal should have left the seat below %d, got %d", start, seat.Chips)
	}
	before := seat.Chips

	if _, err := f.rooms.SwitchTable(mover); err != nil {
		t.Fatalf("switch: %v", err)
	}

	moved, err := away.FindSeat(mover.ID)
	if err != nil || moved == nil {
		t.Fatalf("seat after the switch: %v", err)
	}
	if moved.Chips == start {
		t.Fatalf("the switch handed the stake back: seated with %d, the wallet as it was read before "+
			"the checkpoint, rather than the %d actually held", start, before)
	}
	if moved.Chips != before {
		t.Fatalf("new seat has %d, want %d (staked %d)", moved.Chips, before, staked)
	}
}

// A player who switches BETWEEN hands has nothing staked, so nothing changes —
// the guard above must not cost them chips in the ordinary case.
func TestSwitchingBetweenHandsKeepsTheFullStack(t *testing.T) {
	f := newRoomsFixture(t, nil)

	const start int64 = 2_000_000
	home := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: 200, Category: "blind"})
	away := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: 200, Category: "blind"})

	mover := f.player("Mover", start)
	f.mustJoin(home, mover)

	if _, err := f.rooms.SwitchTable(mover); err != nil {
		t.Fatalf("switch: %v", err)
	}
	moved, err := away.FindSeat(mover.ID)
	if err != nil || moved == nil {
		t.Fatalf("seat after the switch: %v", err)
	}
	if moved.Chips != start {
		t.Fatalf("nothing was staked, so the stack should be untouched: got %d, want %d", moved.Chips, start)
	}
}
