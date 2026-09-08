package game_test

// Adversarial money review, RoomManager level: the paths that destroy a table
// (last player leaves, consolidation, sweep, shutdown) while a settlement is
// still owed to the database.

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// flakyLedger is a bookkeeping game.Ledger whose Settle fails while `down`
// is set. Boots and bets leave the wallet (Persisted = amount) as they do in
// Postgres, so a lost settlement is a lost pot.
type flakyLedger struct {
	mu      sync.Mutex
	down    bool
	wallets map[string]int64
	settled map[string]int
	calls   int
}

func newFlakyLedger() *flakyLedger {
	return &flakyLedger{wallets: map[string]int64{}, settled: map[string]int{}}
}

func (l *flakyLedger) setDown(v bool) {
	l.mu.Lock()
	l.down = v
	l.mu.Unlock()
}

func (l *flakyLedger) wallet(id string) int64 {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.wallets[id]
}

func (l *flakyLedger) settledCount(handID string) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.settled[handID]
}

func (l *flakyLedger) Bet(_ context.Context, req game.BetRequest) (game.BetResult, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.wallets[req.UserID] -= req.Amount
	return game.BetResult{Balance: l.wallets[req.UserID], Persisted: req.Amount}, nil
}

func (l *flakyLedger) CollectBoot(_ context.Context, req game.CollectBootRequest) (game.CollectBootResult, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	balances := map[string]int64{}
	for _, e := range req.Entries {
		if _, ok := l.wallets[e.UserID]; !ok {
			l.wallets[e.UserID] = e.BalanceBefore
		}
		l.wallets[e.UserID] -= e.Amount
		balances[e.UserID] = l.wallets[e.UserID]
	}
	return game.CollectBootResult{Balances: balances, Persisted: req.BootAmount}, nil
}

func (l *flakyLedger) Settle(_ context.Context, req game.SettleRequest) (game.SettleResult, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.calls++
	if l.down {
		return nil, errors.New("database unavailable")
	}
	if l.settled[req.Hand.ID] > 0 {
		return nil, game.NewGameError(game.CodeDuplicateAction, game.MsgDuplicateAction)
	}
	l.settled[req.Hand.ID]++
	out := game.SettleResult{}
	for _, e := range req.Entries {
		l.wallets[e.UserID] += e.Delta
		out[e.UserID] = l.wallets[e.UserID]
	}
	return out, nil
}

// endHandWithTheDatabaseDown deals a hand between two players and ends it
// while Settle fails, so the winner is paid in memory only and a retry is
// owed. Returns the table, the hand id and the winner.
func endHandWithTheDatabaseDown(t *testing.T, f *roomsFixture, ledger *flakyLedger) (*game.Table, string, string, string) {
	t.Helper()
	table := f.rooms.CreateTable(game.CreateTableOptions{BootAmount: rmBoot, Category: "seen"})
	a, b := seatTwoAndDeal(t, f, table, rmStart)
	if viewOf(t, table, a.ID).State != game.TableBetting {
		t.Fatal("expected a live betting hand")
	}
	loser := turnUser(t, table)
	winner := a.ID
	if loser == a.ID {
		winner = b.ID
	}
	ledger.setDown(true)
	if _, err := table.Act(loser, game.ActionPack, game.ActRequest{}); err != nil {
		t.Fatalf("pack: %v", err)
	}
	ended := f.tables.endedCopy()
	if len(ended) != 1 {
		t.Fatalf("expected one handEnded, got %d", len(ended))
	}
	handID := ended[0].HandID
	if ledger.settledCount(handID) != 0 {
		t.Fatal("the settle should have failed")
	}
	return table, handID, winner, loser
}

func flakyRooms(t *testing.T, ledger *flakyLedger) *roomsFixture {
	return newRoomsFixture(t, func(g *config.GameConfig, o *game.RoomManagerOptions) {
		openMenu(g, o)
		o.Ledger = ledger
	})
}

// TestReviewTheLastPlayerLeavingDoesNotOrphanTheWinnersPot: after a
// settlement the database refused, both players leave; the empty table is
// destroyed. The write must still land once the database is back.
func TestReviewTheLastPlayerLeavingDoesNotOrphanTheWinnersPot(t *testing.T) {
	ledger := newFlakyLedger()
	f := flakyRooms(t, ledger)
	table, handID, winner, loser := endHandWithTheDatabaseDown(t, f, ledger)
	pot := f.tables.endedCopy()[0].Pot
	winnerWallet := ledger.wallet(winner)

	f.mustLeave(loser, game.LeaveReasonLeft)
	f.mustLeave(winner, game.LeaveReasonLeft)
	if f.rooms.GetTable(table.ID()) != nil {
		t.Fatal("the empty table should have been destroyed")
	}
	eq(t, table.Destroyed(), true, "destroyed")

	ledger.setDown(false)
	f.clock.Advance(10 * time.Minute)
	if got := ledger.settledCount(handID); got != 1 {
		t.Fatalf("REVIEW: hand %s never settled after the table was destroyed (settles: %d); %s is out the pot of %d", handID, got, winner, pot)
	}
	eq(t, ledger.wallet(winner), winnerWallet+pot, "winner paid in the database")
	// destroyTable logs the outcome from a goroutine waiting on the table.
	eventually(t, time.Second, func() bool { return strings.Contains(f.logText(), "late settlement landed") }, "the late settlement to be logged")
	if !strings.Contains(f.logText(), "settlement still owed") {
		t.Fatalf("destroying with an owed settlement should be logged, got:\n%s", f.logText())
	}
}

// TestReviewShutdownWaitsForAnOwedSettlement: Shutdown destroys the tables
// and then waits (within its budget) for settlements the database refused,
// rather than exiting with the pot unbanked.
func TestReviewShutdownWaitsForAnOwedSettlement(t *testing.T) {
	ledger := newFlakyLedger()
	f := flakyRooms(t, ledger)
	table, handID, winner, _ := endHandWithTheDatabaseDown(t, f, ledger)
	pot := f.tables.endedCopy()[0].Pot
	winnerWallet := ledger.wallet(winner)

	// The database recovers just as the process is asked to stop.
	ledger.setDown(false)
	done := make(chan error, 1)
	go func() { done <- f.rooms.Shutdown(context.Background()) }()
	// Shutdown destroys the table (the next-hand countdown dies with it),
	// then blocks on WaitSettlements until the fake retry timer fires; drive
	// the clock once the table is gone.
	eventually(t, 2*time.Second, table.Destroyed, "the table to be destroyed")
	eventually(t, 2*time.Second, func() bool { return f.clock.Pending() > 0 }, "a detached retry armed")
	f.clock.Advance(time.Minute)
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("shutdown: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Shutdown did not return")
	}
	eq(t, ledger.settledCount(handID), 1, "settled during shutdown")
	eq(t, ledger.wallet(winner), winnerWallet+pot, "winner paid")
}

// TestReviewShutdownBudgetIsRespectedWhenTheDatabaseStaysDown: an owed
// settlement must not hold the process past its budget.
func TestReviewShutdownBudgetIsRespectedWhenTheDatabaseStaysDown(t *testing.T) {
	ledger := newFlakyLedger()
	f := flakyRooms(t, ledger)
	endHandWithTheDatabaseDown(t, f, ledger)
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	err := f.rooms.Shutdown(ctx)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expected the budget to expire, got %v", err)
	}
}

func eq[T comparable](t *testing.T, got, want T, what string) {
	t.Helper()
	if got != want {
		t.Fatalf("%s: got %v, want %v", what, got, want)
	}
}
