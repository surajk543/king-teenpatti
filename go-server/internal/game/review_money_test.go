package game

// Adversarial money review (white-box). Each test pins one way the books
// could stop agreeing with the wallets — SUM(chip_ledger.delta) == users.chips,
// pots.amount == banked rows, nobody paid twice, nobody's pot lost — and is
// written to FAIL on the code as reviewed, then kept as a regression test once
// the hole is closed.

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// persistingLedger stands in for db.Ledger: boots and bets really leave the
// account (Persisted = amount), settle credits the payout deltas, and every
// call can be made to fail on demand. It records what has been banked so a
// test can ask "did the pot ever reach the winner's wallet?".
type persistingLedger struct {
	mu          sync.Mutex
	wallets     map[string]int64
	failSettle  bool
	settleCalls int
	settled     map[string]int // hand id → committed settles
	pots        map[string]int64
}

func newPersistingLedger() *persistingLedger {
	return &persistingLedger{wallets: map[string]int64{}, settled: map[string]int{}, pots: map[string]int64{}}
}

func (l *persistingLedger) set(id string, chips int64) {
	l.mu.Lock()
	l.wallets[id] = chips
	l.mu.Unlock()
}

func (l *persistingLedger) wallet(id string) int64 {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.wallets[id]
}

func (l *persistingLedger) setFailSettle(v bool) {
	l.mu.Lock()
	l.failSettle = v
	l.mu.Unlock()
}

func (l *persistingLedger) settledCount(handID string) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.settled[handID]
}

func (l *persistingLedger) Bet(_ context.Context, req BetRequest) (BetResult, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.wallets[req.UserID] < req.Amount {
		return BetResult{}, NewGameError(CodeInsufficientChips, "insufficient")
	}
	l.wallets[req.UserID] -= req.Amount
	l.pots[req.HandID] += req.Amount
	return BetResult{Balance: l.wallets[req.UserID], Persisted: req.Amount}, nil
}

func (l *persistingLedger) CollectBoot(_ context.Context, req CollectBootRequest) (CollectBootResult, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, e := range req.Entries {
		if l.wallets[e.UserID] < e.Amount {
			return CollectBootResult{}, &GameError{Code: CodeInsufficientChips, Message: "insufficient", UserID: e.UserID}
		}
	}
	balances := map[string]int64{}
	for _, e := range req.Entries {
		l.wallets[e.UserID] -= e.Amount
		l.pots[req.HandID] += e.Amount
		balances[e.UserID] = l.wallets[e.UserID]
	}
	return CollectBootResult{Balances: balances, Persisted: req.BootAmount}, nil
}

func (l *persistingLedger) Settle(_ context.Context, req SettleRequest) (SettleResult, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.settleCalls++
	if l.failSettle {
		return nil, errors.New("database unavailable")
	}
	if l.settled[req.Hand.ID] > 0 {
		return nil, NewGameError(CodeDuplicateAction, MsgDuplicateAction)
	}
	l.settled[req.Hand.ID]++
	out := SettleResult{}
	for _, e := range req.Entries {
		l.wallets[e.UserID] += e.Delta
		out[e.UserID] = l.wallets[e.UserID]
	}
	return out, nil
}

// reviewTable seats a and b with settleStart each on a persisting ledger and
// deals the first hand.
func reviewTable(t *testing.T, ledger *persistingLedger) *harness {
	t.Helper()
	h := newHarness(t, settleConfig(), withLedger(func(*harness) Ledger { return ledger }))
	ledger.set("a", settleStart)
	ledger.set("b", settleStart)
	h.seat("a", settleStart)
	h.seat("b", settleStart)
	h.advance(6 * time.Second)
	if !h.hasHand() {
		t.Fatal("no hand dealt")
	}
	return h
}

// TestReviewDestroyMustNotAbandonAPendingSettlement: the settlement write
// fails (database blip), the winner is paid in memory and a retry is armed.
// Before the retry fires the table is destroyed — exactly what RoomManager
// does the moment the last player leaves, when a lone winner is consolidated
// away, on the empty-table sweep, or on shutdown. The armed retries are
// stopped, so the pot never reaches the winner's wallet: the losers' stakes
// stay debited, pots.amount stays open, and the winner is out the whole pot.
//
// Node has the same hole (`if (this._destroyed) return` in the retry
// callback); DECISIONS.md says latent bugs no client relies on are fixed.
func TestReviewDestroyMustNotAbandonAPendingSettlement(t *testing.T) {
	ledger := newPersistingLedger()
	h := reviewTable(t, ledger)
	handID := h.lastHandStarted().HandID
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	pot := h.pot()
	loser := h.turnUser()
	winner := h.otherActive(loser)

	ledger.setFailSettle(true)
	h.mustAct(loser, ActionPack, ActRequest{})
	eq(t, h.hasHand(), false, "hand over")
	eq(t, ledger.settledCount(handID), 0, "settle did not land")
	eq(t, h.clock.Pending() >= 1, true, "a retry is armed")

	// The database is back — but the table goes away first (last player
	// leaves → RoomManager destroys it).
	ledger.setFailSettle(false)
	if err := h.table.Destroy(); err != nil {
		t.Fatal(err)
	}

	h.advance(10 * time.Minute)

	if ledger.settledCount(handID) != 1 {
		t.Fatalf("REVIEW: the settlement of hand %s was abandoned by Destroy; the winner %s never received the pot of %d in the database (wallet %d, expected %d)",
			handID, winner, pot, ledger.wallet(winner), settleStart-settleBoot+pot-settleBoot)
	}
	eq(t, ledger.wallet(winner), settleStart-settleBoot+pot, "the winner's wallet holds the pot")
}

// TestReviewDestroyMidHandWithAFailingLedgerStillSettlesLater: shutdown or a
// sweep ends a live hand (all_left → first active seat) while the database is
// unavailable. The settle fails, a retry is armed and immediately stopped by
// the same destroy — the pot is orphaned.
func TestReviewDestroyMidHandWithAFailingLedgerStillSettlesLater(t *testing.T) {
	ledger := newPersistingLedger()
	h := reviewTable(t, ledger)
	handID := h.lastHandStarted().HandID
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	pot := h.pot()

	ledger.setFailSettle(true)
	if err := h.table.Destroy(); err != nil {
		t.Fatal(err)
	}
	ended := h.lastHandEnded()
	eq(t, ended.Reason, WinAllLeft, "destroy ends the hand")
	if ended.WinnerID == nil {
		t.Fatal("a winner was named")
	}
	winner := *ended.WinnerID
	eq(t, ledger.settledCount(handID), 0, "settle failed at destroy time")

	ledger.setFailSettle(false)
	h.advance(10 * time.Minute)
	if ledger.settledCount(handID) != 1 {
		t.Fatalf("REVIEW: pot %d of hand %s never paid to %s after Destroy (wallet %d)", pot, handID, winner, ledger.wallet(winner))
	}
}
