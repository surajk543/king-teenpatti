package game

// Adversarial money review (white-box). Each test pins one way the books
// could stop agreeing with the wallets — SUM(chip_ledger.delta) == users.chips,
// pots.amount == banked rows, nobody paid twice, nobody's pot lost — and is
// written to FAIL on the code as reviewed, then kept as a regression test once
// the hole is closed.

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// persistingLedger stands in for db.Ledger under the three-checkpoint money
// model: every checkpoint applies its delta to a fake wallet and records the
// action id (the UNIQUE index), and settle can be made to fail on demand so a
// test can ask "did the pot ever reach the winner's wallet?".
type persistingLedger struct {
	mu          sync.Mutex
	wallets     map[string]int64
	failSettle  bool
	settleCalls int
	settled     map[string]int // hand id → committed settles
	// rows is the action_id UNIQUE index: a checkpoint already written is
	// never written (or applied) twice.
	rows map[string]bool
}

func newPersistingLedger() *persistingLedger {
	return &persistingLedger{wallets: map[string]int64{}, settled: map[string]int{}, rows: map[string]bool{}}
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

func (l *persistingLedger) total() int64 {
	l.mu.Lock()
	defer l.mu.Unlock()
	var sum int64
	for _, v := range l.wallets {
		sum += v
	}
	return sum
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

// applyLocked is the db ledger's applyCheckpoint: one row, one delta, and the
// UNIQUE index refusing a replay.
func (l *persistingLedger) applyLocked(e SettleEntry) error {
	if l.rows[e.ActionID] {
		return NewGameError(CodeDuplicateAction, MsgDuplicateAction)
	}
	l.rows[e.ActionID] = true
	l.wallets[e.UserID] += e.Delta
	return nil
}

func (l *persistingLedger) Checkpoint(_ context.Context, req CheckpointRequest) (CheckpointResult, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if err := l.applyLocked(req.Entry); err != nil {
		return CheckpointResult{}, err
	}
	return CheckpointResult{Balance: l.wallets[req.Entry.UserID]}, nil
}

func (l *persistingLedger) Settle(_ context.Context, req SettleRequest) (SettleResult, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.settleCalls++
	if l.failSettle {
		return nil, errors.New("database unavailable")
	}
	if l.settled[req.HandID] > 0 {
		return nil, NewGameError(CodeDuplicateAction, MsgDuplicateAction)
	}
	l.settled[req.HandID]++
	out := SettleResult{}
	for _, e := range req.Entries {
		if err := l.applyLocked(e); err != nil {
			return nil, err
		}
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

	// The winner has never been written this hand, so their settlement delta
	// is the pot less everything they staked — the same end figure the
	// per-bet model produced.
	winnerBefore := ledger.wallet(winner)
	winnerStaked := h.mustSeat(winner).Contributed

	ledger.setFailSettle(true)
	h.mustAct(loser, ActionPack, ActRequest{})
	eq(t, h.hasHand(), false, "hand over")
	eq(t, ledger.settledCount(handID), 0, "settle did not land")
	eq(t, h.clock.Pending() >= 1, true, "a retry is armed")
	eq(t, h.table.PendingSettlements(), 0, "the actor still owns the retry")

	// The database is back — but the table goes away first (last player
	// leaves → RoomManager destroys it).
	ledger.setFailSettle(false)
	if err := h.table.Destroy(); err != nil {
		t.Fatal(err)
	}
	eq(t, h.table.PendingSettlements(), 1, "the write is still owed after Destroy")

	h.advance(10 * time.Minute)

	if ledger.settledCount(handID) != 1 {
		t.Fatalf("REVIEW: the settlement of hand %s was abandoned by Destroy; the winner %s never received the pot of %d in the database (wallet %d, expected %d)",
			handID, winner, pot, ledger.wallet(winner), winnerBefore+pot-winnerStaked)
	}
	eq(t, ledger.wallet(winner), winnerBefore+pot-winnerStaked, "the winner's wallet holds the pot")
	eq(t, h.table.PendingSettlements(), 0, "nothing left owed")
	if err := h.table.WaitSettlements(context.Background()); err != nil {
		t.Fatalf("WaitSettlements: %v", err)
	}
	eq(t, len(h.table.SettlementsLanded()), 1, "one late settlement reported")
	eq(t, h.clock.Pending(), 0, "no timer left behind")
}

// TestReviewADetachedSettlementIsAbandonedAfterTenAttemptsAndReported: the
// cap and the report survive the move off the actor — WaitSettlements names
// the hand, and the chain stops (no timer left behind, no event after
// Destroy).
func TestReviewADetachedSettlementIsAbandonedAfterTenAttemptsAndReported(t *testing.T) {
	ledger := newPersistingLedger()
	h := reviewTable(t, ledger)
	handID := h.lastHandStarted().HandID
	ledger.setFailSettle(true)
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	if err := h.table.Destroy(); err != nil {
		t.Fatal(err)
	}
	events := h.rec.count()
	// Retry 1 was owed by the actor (attempt 1 armed at 6 s); the detached
	// chain continues from that attempt: 6+12+18+24+30×6 = 240 s.
	h.advance(5 * time.Minute)
	eq(t, ledger.settledCount(handID), 0, "never landed")
	eq(t, h.table.PendingSettlements(), 0, "chain finished")
	eq(t, h.clock.Pending(), 0, "no timer left behind")
	eq(t, h.rec.count(), events, "no event after Destroy")
	err := h.table.WaitSettlements(context.Background())
	if err == nil || !strings.Contains(err.Error(), handID) {
		t.Fatalf("WaitSettlements should name the abandoned hand, got %v", err)
	}
	eq(t, ledger.settleCalls, 11, "1 on the actor + 10 detached attempts")
}

// TestReviewWaitSettlementsHonoursItsContext: a shutdown budget must not be
// held hostage by a database that never answers.
func TestReviewWaitSettlementsHonoursItsContext(t *testing.T) {
	ledger := newPersistingLedger()
	h := reviewTable(t, ledger)
	ledger.setFailSettle(true)
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	if err := h.table.Destroy(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if err := h.table.WaitSettlements(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expected the context to expire, got %v", err)
	}
	// And an undestroyed table has nothing to wait for.
	other := reviewTable(t, newPersistingLedger())
	if err := other.table.WaitSettlements(context.Background()); err != nil {
		t.Fatal(err)
	}
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

// TestReviewTableDropsAClientActionIDInAReservedNamespace: the exploit was a
// client sending another player's "<userId>:milestone:25" as its own bet's
// actionId, which would take that ledger key and make the victim's milestone
// claim fail on the UNIQUE index. Since 9 Sep 2026 a bet writes no ledger row
// at all and every action id the ledger sees is server-minted, so the hole is
// closed by construction — this test pins that: NO client-supplied id ever
// reaches the ledger, and every id that does is one of ours.
func TestReviewTableDropsAClientActionIDInAReservedNamespace(t *testing.T) {
	var sent []string
	h := newHarness(t, settleConfig(), withLedger(func(h *harness) Ledger {
		return &captureLedger{
			inner:        mirrorLedger(h),
			onCheckpoint: func(r CheckpointRequest) { sent = append(sent, r.Entry.ActionID) },
			onSettle: func(r SettleRequest) {
				for _, e := range r.Entries {
					sent = append(sent, e.ActionID)
				}
			},
		}
	}))
	h.seat("a", settleStart)
	h.seat("b", settleStart)
	h.advance(6 * time.Second)

	first := h.turnUser()
	h.mustAct(first, ActionChaal, ActRequest{ActionID: "b:milestone:25"})
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{ActionID: "client-token-1"})
	eq(t, len(sent), 0, "a bet reaches no ledger at all")

	handID := h.lastHandStarted().HandID
	for h.hasHand() {
		h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	}
	if len(sent) == 0 {
		t.Fatal("the hand end wrote nothing")
	}
	for _, id := range sent {
		if id == "b:milestone:25" || id == "client-token-1" {
			t.Fatalf("REVIEW: a client action id reached the ledger as %q", id)
		}
		if !strings.HasPrefix(id, handID+":") {
			t.Fatalf("REVIEW: the ledger saw an id this server did not mint: %q", id)
		}
	}
}

// TestReviewCroreScaleWalletsNeitherOverflowNorLosePrecision: a 50-crore
// stack (the dev database holds two) on an uncapped blind table gets a
// ladder bounded by its stack with no int64 wrap, and its chips reach the
// wire as an exact JSON integer (Go marshals int64 losslessly; nothing on
// the path goes through float64).
func TestReviewCroreScaleWalletsNeitherOverflowNorLosePrecision(t *testing.T) {
	const crore50 = int64(50_00_00_000)
	cfg := settleConfig()
	cfg.Category = CategoryBlind
	cfg.MaxBetRounds, cfg.PotLimitMultiplier, cfg.MaxRaiseSteps, cfg.MaxPot = 0, 0, 0, 0
	h := newHarness(t, cfg)
	h.seat("rich", crore50)
	h.seat("richer", 1<<62) // absurd, but must not wrap the ladder
	h.advance(6 * time.Second)

	for _, id := range []string{"rich", "richer"} {
		var options BetOptions
		h.read(func() { options = h.table.betOptions(h.table.findSeat(id)) })
		chips := h.mustSeat(id).Chips
		for _, step := range options.Steps {
			if step <= 0 || step > chips {
				t.Fatalf("%s: rung %d outside (0, %d]", id, step, chips)
			}
		}
		// The ladder must run all the way up the stack when uncapped: one more
		// doubling would not fit.
		if options.Max == nil || *options.Max*2 <= chips {
			t.Fatalf("%s: ladder stopped at %v with %d in the stack", id, options.Max, chips)
		}
	}
	view := h.view("rich")
	raw, err := json.Marshal(view)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"chips":`+strconv.FormatInt(crore50-settleBoot, 10)) {
		t.Fatalf("exact chips missing from the wire JSON: %s", raw)
	}
}

// TestReviewASettleRetryFiringAsTheTableIsDestroyedIsBankedExactlyOnce: the
// handoff window — the retry timer has fired and its callback is queued
// behind Destroy on the actor. Destroy sees Stop() fail and the callback is
// told ErrTableDestroyed; between them the write must be attempted by exactly
// one detached chain and counted exactly once (PendingSettlements returns to
// 0 and WaitSettlements returns).
func TestReviewASettleRetryFiringAsTheTableIsDestroyedIsBankedExactlyOnce(t *testing.T) {
	ledger := newPersistingLedger()
	h := reviewTable(t, ledger)
	handID := h.lastHandStarted().HandID
	ledger.setFailSettle(true)
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	ledger.setFailSettle(false)

	// Occupy the actor so the next two posts queue behind it, in order:
	// Destroy first, then the retry timer's callback (fired by Advance).
	gate := make(chan struct{})
	busy := make(chan struct{})
	go func() {
		_ = h.table.run(func() {
			close(busy)
			<-gate
		})
	}()
	<-busy
	destroyed := make(chan error, 1)
	go func() { destroyed <- h.table.Destroy() }()
	time.Sleep(20 * time.Millisecond)
	advanced := make(chan struct{})
	go func() {
		h.advance(6 * time.Second) // fires the retry (attempt 1) → its run() queues behind Destroy
		close(advanced)
	}()
	time.Sleep(20 * time.Millisecond)
	close(gate)

	if err := <-destroyed; err != nil {
		t.Fatal(err)
	}
	<-advanced
	eq(t, h.table.PendingSettlements(), 1, "exactly one chain owed")
	h.advance(10 * time.Minute)
	eq(t, ledger.settledCount(handID), 1, "banked exactly once")
	eq(t, h.table.PendingSettlements(), 0, "counted exactly once")
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := h.table.WaitSettlements(ctx); err != nil {
		t.Fatalf("WaitSettlements: %v", err)
	}
}
