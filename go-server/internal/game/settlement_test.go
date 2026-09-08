package game

// Port of server/test/settlement.test.js and server/test/chipPersistence.test.js
// (money conservation), plus the ledger-failure paths (boot refused, bet
// refused, settlement retried / abandoned, duplicate_action on a retry) and
// the actor properties the Node suite could not express: chip conservation
// under random play, no deadlock behind a slow listener, no timer firing
// after Destroy, ErrTableDestroyed from every post.

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"strings"
	"sync"
	"testing"
	"time"
)

// ------------------------------------------------------ settlement.test.js

const (
	settleBoot  int64 = 100
	settleStart int64 = 200000
)

func settleConfig() TableConfig {
	return TableConfig{
		Category:           CategorySeen,
		BootAmount:         settleBoot,
		MaxPlayers:         5,
		MinPlayers:         2,
		TurnTimeout:        25 * time.Second,
		MaxBetRounds:       20,
		PotLimitMultiplier: 1024,
		MaxRaiseSteps:      8,
		NextHandDelay:      6 * time.Second,
		ChatMaxHistory:     100,
		ChatMaxLength:      140,
	}
}

// bank is the settlement.test.js "real database" stand-in: settle applies
// each delta to the player's pre-hand balance.
type bank struct {
	mu       sync.Mutex
	balances map[string]int64
}

func newBank() *bank { return &bank{balances: map[string]int64{}} }

func (b *bank) set(id string, v int64) {
	b.mu.Lock()
	b.balances[id] = v
	b.mu.Unlock()
}

func (b *bank) get(id string) (int64, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	v, ok := b.balances[id]
	return v, ok
}

func (b *bank) total() int64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	var sum int64
	for _, v := range b.balances {
		sum += v
	}
	return sum
}

// bankLedger: bookless bets (persisted 0), settle moves the whole net.
func bankLedger(bk *bank, start int64) func(h *harness) Ledger {
	return func(h *harness) Ledger {
		return NewMemoryLedger(MemoryLedgerHooks{
			Settle: func(hand HandRecord, entries []SettleEntry) (map[string]int64, error) {
				h.recordSettle(hand, entries)
				balances := map[string]int64{}
				for _, e := range entries {
					before, ok := bk.get(e.UserID)
					if !ok {
						before = start
					}
					after := before + e.Delta
					bk.set(e.UserID, after)
					balances[e.UserID] = after
				}
				return balances, nil
			},
		})
	}
}

func settleTable(t *testing.T) (*harness, *bank) {
	bk := newBank()
	h := newHarness(t, settleConfig(), withLedger(bankLedger(bk, settleStart)), withID("settle-room", "SETL01"))
	return h, bk
}

func (h *harness) bankSeat(bk *bank, id string, chips int64) {
	bk.set(id, chips)
	h.seat(id, chips)
}

// assertConserved is Node's assertConserved: Σdelta 0, Σcontributed == pot,
// one winner netting pot - own stake.
func assertConserved(t *testing.T, record settleCall) {
	t.Helper()
	eq(t, sumDeltas(record.entries), int64(0), "the sum of all deltas must be zero")
	eq(t, sumContributed(record.hand.Summary), record.hand.Pot, "the pot equals everything staked")
	var winners []SettleEntry
	for _, e := range record.entries {
		if e.IsWinner {
			winners = append(winners, e)
		}
	}
	eq(t, len(winners), 1, "exactly one winner")
	var own int64
	for _, row := range record.hand.Summary {
		if row.UserID == winners[0].UserID {
			own = row.Contributed
		}
	}
	eq(t, winners[0].Delta, record.hand.Pot-own, "the winner nets the pot minus their own stake")
}

func TestChipsAreConservedWhenEveryoneElsePacks(t *testing.T) {
	h, bk := settleTable(t)
	for _, id := range []string{"a", "b", "c"} {
		h.bankSeat(bk, id, settleStart)
	}
	h.advance(6 * time.Second)
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	assertConserved(t, h.lastSettled())
	eq(t, bk.total(), settleStart*3, "bank total unchanged")
}

func TestChipsAreConservedThroughAShow(t *testing.T) {
	h, bk := settleTable(t)
	h.bankSeat(bk, "a", settleStart)
	h.bankSeat(bk, "b", settleStart)
	h.advance(6 * time.Second)
	h.setCards("a", "As", "Ah", "Ad")
	h.setCards("b", "2s", "7h", "9d")

	h.mustAct(h.turnUser(), ActionSee, ActRequest{})
	h.mustAct(h.turnUser(), ActionRaise, ActRequest{})
	h.mustAct(h.turnUser(), ActionShow, ActRequest{})
	assertConserved(t, h.lastSettled())
	eq(t, *h.lastHandEnded().WinnerID, "a", "the trail wins")
}

func TestChipsAreConservedThroughAForcedShowdown(t *testing.T) {
	bk := newBank()
	cfg := settleConfig()
	cfg.MaxBetRounds = 4
	h := newHarness(t, cfg, withLedger(bankLedger(bk, settleStart)))
	for _, id := range []string{"a", "b", "c"} {
		h.bankSeat(bk, id, settleStart)
	}
	h.advance(6 * time.Second)
	for i := 0; i < 60 && h.hasHand(); i++ {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
	eq(t, h.hasHand(), false, "ended")
	assertConserved(t, h.lastSettled())
}

func TestChipsAreConservedWhenAPlayerLeavesMidHand(t *testing.T) {
	h, bk := settleTable(t)
	for _, id := range []string{"a", "b", "c"} {
		h.bankSeat(bk, id, settleStart)
	}
	h.advance(6 * time.Second)
	quitter := h.turnUser()
	h.mustAct(quitter, ActionChaal, ActRequest{})
	h.remove(quitter, LeaveReasonLeft)
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})

	record := h.lastSettled()
	assertConserved(t, record)
	paid := false
	for _, e := range record.entries {
		if e.UserID == quitter && e.Delta < 0 {
			paid = true
		}
	}
	eq(t, paid, true, "the player who left still paid what they staked")
}

func TestChipsAreConservedWhenEveryPlayerTimesOutButOne(t *testing.T) {
	h, bk := settleTable(t)
	for _, id := range []string{"a", "b", "c"} {
		h.bankSeat(bk, id, settleStart)
	}
	h.advance(6 * time.Second)
	h.advance(25 * time.Second)
	h.advance(25 * time.Second)
	eq(t, h.hasHand(), false, "ended")
	assertConserved(t, h.lastSettled())
}

func TestTheTotalInPlayIsUnchangedAcrossManyHands(t *testing.T) {
	h, bk := settleTable(t)
	for _, id := range []string{"a", "b", "c", "d"} {
		h.bankSeat(bk, id, settleStart)
	}
	totalBefore := bk.total()

	for hand := 0; hand < 25; hand++ {
		h.advance(6 * time.Second)
		if !h.hasHand() {
			break
		}
		for guard := 1; h.hasHand() && guard <= 80; guard++ {
			player := h.turnUser()
			opts := h.turnOptions(player)
			switch {
			case opts.Show != nil:
				h.mustAct(player, ActionShow, ActRequest{})
			case guard%4 == 0:
				h.mustAct(player, ActionPack, ActRequest{})
			case opts.Chaal != nil:
				h.mustAct(player, ActionChaal, ActRequest{})
			default:
				h.mustAct(player, ActionPack, ActRequest{})
			}
		}
	}
	eq(t, bk.total(), totalBefore, "no chips were created or destroyed across 25 hands")
	if h.handNo() <= 5 {
		t.Fatalf("a meaningful number of hands actually ran: %d", h.handNo())
	}
	eq(t, h.settledCount(), h.handNo(), "every hand was settled once")
}

func TestASettledBalanceOfZeroIsNotTreatedAsAFailedSettlement(t *testing.T) {
	h := newHarness(t, settleConfig(), withLedger(func(h *harness) Ledger {
		return NewMemoryLedger(MemoryLedgerHooks{
			Settle: func(hand HandRecord, entries []SettleEntry) (map[string]int64, error) {
				balances := map[string]int64{}
				for _, e := range entries {
					balances[e.UserID] = 0
				}
				return balances, nil
			},
		})
	}), withID("zero-room", "ZERO01"))
	h.seatNamed("a", "A", settleStart)
	h.seatNamed("b", "B", settleStart)
	h.advance(6 * time.Second)
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	for _, id := range h.occupiedIDs() {
		eq(t, h.mustSeat(id).Chips, int64(0), "the settled balance is used verbatim")
	}
}

func TestABootBalanceOfZeroIsAdoptedByKeyPresence(t *testing.T) {
	// The same rule at hand start (table.js:449-455): a returned balance of 0
	// is a real figure, not a missing one.
	h := newHarness(t, settleConfig(), withLedger(func(h *harness) Ledger {
		return &captureLedger{inner: emptyLedger(h), boot: func(r CollectBootRequest) (CollectBootResult, error) {
			balances := map[string]int64{}
			for _, e := range r.Entries {
				balances[e.UserID] = 0
			}
			return CollectBootResult{Balances: balances, Persisted: r.BootAmount}, nil
		}}
	}))
	h.seat("a", settleStart)
	h.seat("b", settleStart)
	h.advance(6 * time.Second)
	eq(t, h.mustSeat("a").Chips, int64(0), "database figure wins")
	eq(t, h.mustSeat("b").Chips, int64(0), "database figure wins")
	// And a ledger that reports no balances falls back to chips - boot.
	h2 := newHarness(t, settleConfig(), withLedger(func(h *harness) Ledger {
		return &captureLedger{inner: emptyLedger(h), boot: func(r CollectBootRequest) (CollectBootResult, error) {
			return CollectBootResult{Persisted: r.BootAmount}, nil
		}}
	}))
	h2.seat("a", settleStart)
	h2.seat("b", settleStart)
	h2.advance(6 * time.Second)
	eq(t, h2.mustSeat("a").Chips, settleStart-settleBoot, "fallback debit")
}

// ------------------------------------------------- chipPersistence.test.js

const (
	bankBoot  int64 = 200
	bankStart int64 = 100000
)

func bankConfig() TableConfig {
	return TableConfig{
		Category:           CategorySeen,
		BootAmount:         bankBoot,
		MaxPlayers:         5,
		MinPlayers:         2,
		TurnTimeout:        25 * time.Second,
		MaxBetRounds:       40,
		PotLimitMultiplier: 1024,
		MaxRaiseSteps:      8,
		MaxBlindMoves:      4,
		NextHandDelay:      6 * time.Second,
		ChatMaxHistory:     100,
		ChatMaxLength:      140,
	}
}

type movement struct {
	userID string
	delta  int64
	reason string
}

// accountsLedger is chipPersistence.test.js's toy ledger: persistChips moves
// the account on every boot and bet (a negative result would refuse), settle
// applies the deltas.
func accountsLedger(t *testing.T, accounts *bank, movements *[]movement) func(h *harness) Ledger {
	return func(h *harness) Ledger {
		var mu sync.Mutex
		return NewMemoryLedger(MemoryLedgerHooks{
			PersistChips: func(args PersistChipsArgs) error {
				before, _ := accounts.get(args.UserID)
				after := before + args.Delta
				if after < 0 {
					return fmt.Errorf("%s went negative", args.UserID)
				}
				accounts.set(args.UserID, after)
				mu.Lock()
				*movements = append(*movements, movement{args.UserID, args.Delta, args.Reason})
				mu.Unlock()
				return nil
			},
			Settle: func(hand HandRecord, entries []SettleEntry) (map[string]int64, error) {
				h.recordSettle(hand, entries)
				balances := map[string]int64{}
				for _, e := range entries {
					before, _ := accounts.get(e.UserID)
					after := before + e.Delta
					accounts.set(e.UserID, after)
					balances[e.UserID] = after
					mu.Lock()
					*movements = append(*movements, movement{e.UserID, e.Delta, "settle"})
					mu.Unlock()
				}
				return balances, nil
			},
		})
	}
}

func bankTable(t *testing.T) (*harness, *bank, *[]movement) {
	accounts := newBank()
	movements := &[]movement{}
	h := newHarness(t, bankConfig(), withLedger(accountsLedger(t, accounts, movements)), withID("bank-room", "BANK01"))
	return h, accounts, movements
}

func mustGet(t *testing.T, bk *bank, id string) int64 {
	t.Helper()
	v, ok := bk.get(id)
	if !ok {
		t.Fatalf("no account for %s", id)
	}
	return v
}

func TestTheBootLeavesTheAccountTheMomentItIsPosted(t *testing.T) {
	h, accounts, movements := bankTable(t)
	h.seatNamed("alice", "ALICE", bankStart)
	accounts.set("alice", bankStart)
	h.seatNamed("bob", "BOB", bankStart)
	accounts.set("bob", bankStart)
	h.advance(6 * time.Second)

	eq(t, mustGet(t, accounts, "alice"), bankStart-bankBoot, "alice's ante is gone")
	eq(t, mustGet(t, accounts, "bob"), bankStart-bankBoot, "bob's ante is gone")
	eq(t, h.pot(), bankBoot*2, "pot")
	eq(t, len(*movements), 2, "two boot movements")
	for _, m := range *movements {
		eq(t, m.reason, LedgerReasonBoot, "reason boot")
		eq(t, m.delta, -bankBoot, "delta")
	}
}

func TestEveryChaalIsBankedAsItIsMade(t *testing.T) {
	h, accounts, movements := bankTable(t)
	accounts.set("alice", bankStart)
	accounts.set("bob", bankStart)
	h.seatNamed("alice", "ALICE", bankStart)
	h.seatNamed("bob", "BOB", bankStart)
	h.advance(6 * time.Second)

	player := h.turnUser()
	before := mustGet(t, accounts, player)
	stake := h.stake()
	h.mustAct(player, ActionChaal, ActRequest{})

	eq(t, mustGet(t, accounts, player), before-stake, "the account moved with the bet")
	eq(t, h.mustSeat(player).Chips, mustGet(t, accounts, player), "seat and account agree")
	last := (*movements)[len(*movements)-1]
	eq(t, last.reason, LedgerReasonBet, "bet reason")
	eq(t, last.userID, player, "bet by the player")
}

func TestTheWinnerIsPaidThePotAndNobodyIsChargedTwice(t *testing.T) {
	h, accounts, _ := bankTable(t)
	accounts.set("alice", bankStart)
	accounts.set("bob", bankStart)
	h.seatNamed("alice", "ALICE", bankStart)
	h.seatNamed("bob", "BOB", bankStart)
	h.advance(6 * time.Second)

	first := h.turnUser()
	h.mustAct(first, ActionChaal, ActRequest{})
	loser := h.turnUser()
	pot := h.pot()
	winner := h.otherActive(loser)
	winnerBefore := mustGet(t, accounts, winner)
	loserBefore := mustGet(t, accounts, loser)

	h.mustAct(loser, ActionPack, ActRequest{})

	eq(t, mustGet(t, accounts, winner), winnerBefore+pot, "paid exactly the pot")
	eq(t, mustGet(t, accounts, loser), loserBefore, "already paid; not charged again")
	eq(t, accounts.total(), bankStart*2, "chips are conserved")
	// With a persisting ledger the deltas are payout-only: winner +pot, loser 0.
	for _, e := range h.lastSettled().entries {
		if e.IsWinner {
			eq(t, e.Delta, pot, "winner delta is the pot")
		} else {
			eq(t, e.Delta, int64(0), "loser owes nothing further")
		}
	}
}

func TestAPlayerWhoWalksOutMidHandDoesNotGetTheirStakeBack(t *testing.T) {
	h, accounts, _ := bankTable(t)
	for _, id := range []string{"alice", "bob", "carol"} {
		accounts.set(id, bankStart)
		h.seatNamed(id, strings.ToUpper(id), bankStart)
	}
	h.advance(6 * time.Second)

	quitter := h.turnUser()
	h.mustAct(quitter, ActionChaal, ActRequest{})
	staked := h.mustSeat(quitter).Contributed
	eq(t, mustGet(t, accounts, quitter), bankStart-staked, "after betting")

	h.remove(quitter, LeaveReasonLeft)
	eq(t, mustGet(t, accounts, quitter), bankStart-staked, "stake stays in the pot")

	for h.hasHand() && len(h.activeIDs()) > 1 {
		h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	}
	eq(t, mustGet(t, accounts, quitter), bankStart-staked, "still not refunded at settlement")
	eq(t, accounts.total(), bankStart*3, "chips are conserved")
}

func TestChipsAreConservedAcrossALongHandOfRaises(t *testing.T) {
	h, accounts, _ := bankTable(t)
	for _, id := range []string{"alice", "bob", "carol"} {
		accounts.set(id, bankStart)
		h.seatNamed(id, strings.ToUpper(id), bankStart)
	}
	h.advance(6 * time.Second)

	for i := 0; i < 9 && h.hasHand(); i++ {
		player := h.turnUser()
		opts := h.betOptions(player)
		if len(opts.Steps) > 1 {
			h.mustAct(player, ActionRaise, amt(opts.Steps[1]))
		} else {
			h.mustAct(player, ActionChaal, amt(opts.Steps[0]))
		}
	}
	for h.hasHand() && len(h.activeIDs()) > 1 {
		h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	}
	eq(t, accounts.total(), bankStart*3, "nothing was created or destroyed")
}

func TestASeatAndItsAccountNeverDisagree(t *testing.T) {
	h, accounts, _ := bankTable(t)
	accounts.set("alice", bankStart)
	accounts.set("bob", bankStart)
	h.seatNamed("alice", "ALICE", bankStart)
	h.seatNamed("bob", "BOB", bankStart)
	h.advance(6 * time.Second)

	for i := 0; i < 4 && h.hasHand(); i++ {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
		for _, id := range h.activeIDs() {
			eq(t, h.mustSeat(id).Chips, mustGet(t, accounts, id), id+" out of step")
		}
	}
}

// -------------------------------------------------- ledger failure paths

func TestABetTheLedgerRefusesChangesNothing(t *testing.T) {
	var refuse error
	h := newHarness(t, settleConfig(), withLedger(func(h *harness) Ledger {
		inner := mirrorLedger(h)
		return &captureLedger{inner: inner, bet: func(r BetRequest) (BetResult, error) {
			if refuse != nil {
				return BetResult{}, refuse
			}
			return inner.Bet(context.Background(), r)
		}}
	}))
	h.seat("a", settleStart)
	h.seat("b", settleStart)
	h.advance(6 * time.Second)
	player := h.turnUser()
	before := h.mustSeat(player)
	pot := h.pot()
	deadline := h.lastTurn().Deadline

	cases := []struct {
		ledgerErr error
		code      string
		message   string
	}{
		{NewGameError(CodeInsufficientChips, "db says no"), CodeInsufficientChips, MsgInsufficientForBet},
		{NewGameError(CodeDuplicateAction, "seen it"), CodeDuplicateAction, MsgDuplicateAction},
		{NewGameError(CodeStaleState, "old"), CodePersistFailed, MsgPersistFailed},
		{errors.New("connection reset"), CodePersistFailed, MsgPersistFailed},
	}
	for _, c := range cases {
		refuse = c.ledgerErr
		mark := h.rec.count()
		_, err := h.act(player, ActionChaal, ActRequest{ActionID: "dup-same-id"})
		codeIs(t, err, c.code)
		var ge *GameError
		errors.As(err, &ge)
		eq(t, ge.Message, c.message, "message for "+c.code)
		if !errors.Is(err, c.ledgerErr) && ge.Cause != c.ledgerErr {
			t.Fatal("the ledger error is kept as Cause")
		}
		// Nothing changed: no state, no action; only a persistError.
		names := h.rec.names()[mark:]
		eq(t, strings.Join(names, ","), "persistError", "only a persistError is emitted")
		pe := h.rec.last("persistError").(PersistErrorEvent)
		eq(t, pe.UserID, player, "persistError userId")
		eq(t, pe.Delta, -settleBoot, "persistError delta")
		eq(t, pe.Reason, LedgerReasonBet, "persistError reason")
		after := h.mustSeat(player)
		eq(t, after.Chips, before.Chips, "chips unchanged")
		eq(t, after.Contributed, before.Contributed, "contributed unchanged")
		eq(t, after.LastBet, int64(0), "no last bet")
		eq(t, h.pot(), pot, "pot unchanged")
		eq(t, h.turnUser(), player, "turn unchanged")
		eq(t, h.table.Version(), int64(1), "version unchanged")
		eq(t, h.lastTurn().Deadline, deadline, "clock untouched")
	}
	// A refused show is reported with reason "show".
	refuse = errors.New("down")
	_, err := h.act(player, ActionShow, ActRequest{})
	codeIs(t, err, CodePersistFailed)
	eq(t, h.rec.last("persistError").(PersistErrorEvent).Reason, LedgerReasonShow, "show reason")

	// And once the ledger is back, the same move goes through.
	refuse = nil
	h.mustAct(player, ActionChaal, ActRequest{})
	eq(t, h.table.Version(), int64(2), "version rises on the commit")
}

func TestABootRefusedForInsufficientChipsKicksTheUnfundedSeatWithoutARetry(t *testing.T) {
	var refuse *GameError
	h := newHarness(t, settleConfig(), withLedger(func(h *harness) Ledger {
		inner := mirrorLedger(h)
		return &captureLedger{inner: inner, boot: func(r CollectBootRequest) (CollectBootResult, error) {
			if refuse != nil {
				return CollectBootResult{}, refuse
			}
			return inner.CollectBoot(context.Background(), r)
		}}
	}))
	h.seat("a", settleStart)
	h.seat("b", settleStart)
	refuse = &GameError{Code: CodeInsufficientChips, Message: "wallet short", UserID: "b"}
	mark := h.rec.count()
	h.advance(6 * time.Second)

	eq(t, h.hasHand(), false, "nothing dealt")
	eq(t, h.state(), TableWaiting, "back to waiting")
	eq(t, h.mustSeat("b").Chips, settleBoot-1, "the seat's stale balance is corrected to boot-1")
	eq(t, h.mustSeat("a").Chips, settleStart, "a untouched")
	kicks := h.kickEvents()
	eq(t, len(kicks), 1, "one kick")
	eq(t, kicks[0].UserID, "b", "the unfunded player")
	eq(t, kicks[0].Reason, KickReasonInsufficientChips, "reason")
	eq(t, kicks[0].Message, KickMessageInsufficientChips, "message")
	eq(t, strings.Join(h.rec.names()[mark:], ","), "persistError,kick,state", "startRefused order")
	pe := h.rec.last("persistError").(PersistErrorEvent)
	eq(t, pe.Reason, LedgerReasonBoot, "persistError reason boot")
	eq(t, h.clock.Pending(), 0, "no retry timer armed on this path")
	eq(t, h.table.Version(), int64(0), "version unchanged")
	if h.view("a").StartsAt != nil {
		t.Fatal("startsAt cleared")
	}

	// The unfunded player is removed (by the room manager in production);
	// with a funded third player the table restarts on the waiting branch.
	refuse = nil
	h.seat("c", settleStart)
	h.remove("b", KickReasonInsufficientChips)
	eq(t, h.state(), TableStarting, "restart after the removal")
	h.advance(6 * time.Second)
	eq(t, h.hasHand(), true, "dealt")
}

func TestABootRefusedForAnotherReasonIsRetriedAfterTheDelay(t *testing.T) {
	failures := 0
	h := newHarness(t, settleConfig(), withLedger(func(h *harness) Ledger {
		inner := mirrorLedger(h)
		return &captureLedger{inner: inner, boot: func(r CollectBootRequest) (CollectBootResult, error) {
			if failures > 0 {
				failures--
				return CollectBootResult{}, errors.New("database unavailable")
			}
			return inner.CollectBoot(context.Background(), r)
		}}
	}))
	h.seat("a", settleStart)
	h.seat("b", settleStart)
	failures = 2
	h.advance(6 * time.Second) // first attempt fails
	eq(t, h.hasHand(), false, "refused")
	eq(t, h.state(), TableWaiting, "waiting")
	eq(t, h.clock.Pending(), 1, "a retry timer is armed")
	eq(t, len(h.kickEvents()), 0, "nobody kicked")
	h.advance(6 * time.Second) // retry → maybeStart → starting again
	eq(t, h.state(), TableStarting, "countdown restarted")
	h.advance(6 * time.Second) // second attempt fails
	eq(t, h.hasHand(), false, "refused again")
	h.advance(6 * time.Second) // retry → starting
	h.advance(6 * time.Second) // third attempt succeeds
	eq(t, h.hasHand(), true, "dealt once the database is back")
	eq(t, len(h.rec.all("persistError")), 2, "two boot refusals reported")
	eq(t, h.table.Version(), int64(1), "one committed write")
}

func TestASettlementTheLedgerRefusesIsPaidInMemoryAndRetried(t *testing.T) {
	var failSettle bool
	var settleCalls []int64
	h := newHarness(t, settleConfig(), withLedger(func(h *harness) Ledger {
		inner := mirrorLedger(h)
		return &captureLedger{inner: inner, settle: func(r SettleRequest) (SettleResult, error) {
			settleCalls = append(settleCalls, r.Version)
			if failSettle {
				return nil, errors.New("settle down")
			}
			return inner.Settle(context.Background(), r)
		}}
	}))
	h.seat("a", settleStart)
	h.seat("b", settleStart)
	h.advance(6 * time.Second)
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{}) // version 2
	pot := h.pot()
	loser := h.turnUser()
	winner := h.otherActive(loser)
	winnerBefore := h.mustSeat(winner).Chips

	failSettle = true
	mark := h.rec.count()
	h.mustAct(loser, ActionPack, ActRequest{})

	eq(t, h.hasHand(), false, "the hand is over whatever the database says")
	eq(t, h.mustSeat(winner).Chips, winnerBefore+pot, "the winner is paid in memory")
	eq(t, h.table.Version(), int64(2), "version not bumped on a failed settle")
	names := h.rec.names()[mark:]
	eq(t, strings.Join(names, ","), "action,persistError,handEnded,state,state", "pack → failed settle → handEnded → state → state(starting)")
	pe := h.rec.all("persistError")[0].(PersistErrorEvent)
	eq(t, pe.Reason, "settle", "reason settle")
	eq(t, len(settleCalls), 1, "first attempt")
	eq(t, settleCalls[0], int64(3), "version 3 offered")

	// Retry 1 fires after NextHandDelay × 1 = 6 s; the next hand's countdown
	// also fires at 6 s, but the retry timer was armed first (inside endHand,
	// before maybeStart) so it runs first. It re-sends the same record with
	// the live version + 1 — still 3, since nothing committed meanwhile.
	failSettle = false
	mark = h.rec.count()
	h.advance(6 * time.Second)
	eq(t, len(settleCalls), 2, "retried once")
	eq(t, settleCalls[1], int64(3), "live version + 1")
	eq(t, h.table.Version(), int64(4), "retry committed 3, the next boot 4")
	eq(t, h.rec.names()[mark], "state", "a successful retry re-broadcasts state")
	if got := h.rec.all("persistError"); len(got) != 1 {
		t.Fatalf("no further persist errors: %d", len(got))
	}
	eq(t, h.hasHand(), true, "the next hand was dealt")
}

func TestASettleRetryRefusedAsDuplicateActionCountsAsSuccess(t *testing.T) {
	// DECISIONS.md §2: the write already landed.
	attempts := map[string]int{}
	var firstHand string
	h := newHarness(t, settleConfig(), withLedger(func(h *harness) Ledger {
		inner := mirrorLedger(h)
		return &captureLedger{inner: inner, settle: func(r SettleRequest) (SettleResult, error) {
			attempts[r.Hand.ID]++
			if r.Hand.ID != firstHand {
				return inner.Settle(context.Background(), r)
			}
			switch attempts[r.Hand.ID] {
			case 1:
				return nil, errors.New("timeout after commit")
			case 2:
				return nil, NewGameError(CodeDuplicateAction, "That move has already been applied")
			}
			return inner.Settle(context.Background(), r)
		}}
	}))
	h.seat("a", settleStart)
	h.seat("b", settleStart)
	h.advance(6 * time.Second)
	firstHand = h.lastHandStarted().HandID
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	eq(t, attempts[firstHand], 1, "first attempt failed")
	eq(t, h.table.Version(), int64(1), "version not bumped")

	h.advance(6 * time.Second) // retry 1 → duplicate_action → success; then the next deal
	eq(t, attempts[firstHand], 2, "one retry")
	eq(t, h.table.Version(), int64(3), "retry committed version 2, the next boot version 3")
	eq(t, len(h.rec.all("persistError")), 1, "only the first failure was reported")
	h.advance(5 * time.Minute)
	eq(t, attempts[firstHand], 2, "no third settle attempt for that hand")
	if len(h.rec.all("error")) != 0 {
		t.Fatal("never abandoned")
	}
}

func TestASettlementIsAbandonedAfterTenRetries(t *testing.T) {
	h := newHarness(t, settleConfig(), withLedger(func(h *harness) Ledger {
		return NewMemoryLedger(MemoryLedgerHooks{
			Settle: func(HandRecord, []SettleEntry) (map[string]int64, error) { return nil, errors.New("settle down") },
		})
	}))
	// Keep the table from dealing again so the timers are only retries.
	h.seat("a", settleStart)
	h.seat("b", settleStart)
	h.advance(6 * time.Second)
	loser := h.turnUser()
	h.mustAct(loser, ActionPack, ActRequest{})
	// Leave one player seated so no next hand is dealt: only the retry
	// timers remain (the countdown is cancelled by the departure).
	for _, id := range h.occupiedIDs() {
		if id != loser {
			h.remove(id, LeaveReasonLeft)
		}
	}
	eq(t, h.state(), TableWaiting, "countdown cancelled")
	// Delays: 6,12,18,24,30,30,30,30,30,30 = 240 s.
	h.advance(4 * time.Minute)
	persist := h.rec.all("persistError")
	// 1 × "settle" + 10 × "settle_retry" (Node: _retrySettle attempts 1..10).
	eq(t, len(persist), 11, "one settle failure plus ten retry failures")
	eq(t, persist[0].(PersistErrorEvent).Reason, "settle", "first")
	for i := 1; i <= 10; i++ {
		pe := persist[i].(PersistErrorEvent)
		eq(t, pe.Reason, "settle_retry", "retry reason")
		eq(t, pe.Attempt, i, "attempt number")
	}
	errs := h.rec.all("error")
	eq(t, len(errs), 1, "abandoned once")
	if !strings.Contains(errs[0].(error).Error(), "failed after 10 attempts") {
		t.Fatalf("error %v", errs[0])
	}
	eq(t, h.clock.Pending(), 0, "no retry timer left")
}

// ------------------------------------------------------------ properties

// TestChipConservationUnderRandomPlay drives many hands of random legal play
// (chaal/raise at any rung, pack, see, show, sideshow with every answer,
// timeouts and kicks, leaves and rejoins) on a persisting ledger and checks
// after every step that Σaccounts + pot never changes, that every seated
// player's seat agrees with their account, and that every settlement's
// deltas add up to the pot.
func TestChipConservationUnderRandomPlay(t *testing.T) {
	for seed := int64(1); seed <= 10; seed++ {
		t.Run(fmt.Sprintf("seed=%d", seed), func(t *testing.T) {
			rng := rand.New(rand.NewSource(seed))
			accounts := newBank()
			movements := &[]movement{}
			cfg := TableConfig{
				Category:           Category([]string{"seen", "blind"}[rng.Intn(2)]),
				BootAmount:         100,
				MaxPlayers:         5,
				MinPlayers:         2,
				TurnTimeout:        25 * time.Second,
				MaxBetRounds:       []int{0, 3, 7}[rng.Intn(3)],
				PotLimitMultiplier: []int64{0, 4, 1024}[rng.Intn(3)],
				MaxRaiseSteps:      []int{0, 2, 8}[rng.Intn(3)],
				MaxPot:             []int64{0, 20000}[rng.Intn(2)],
				MaxBlindMoves:      4,
				MaxMissedTurns:     3,
				SideshowTimeout:    6 * time.Second,
				SideshowMinPlayers: 3,
				NextHandDelay:      4 * time.Second,
			}
			h := newHarness(t, cfg, withLedger(accountsLedger(t, accounts, movements)), withKickHandler())
			const start int64 = 20000
			ids := []string{"p1", "p2", "p3", "p4", "p5"}
			var total int64
			for _, id := range ids[:4] {
				accounts.set(id, start)
				h.seat(id, start)
				total += start
			}
			check := func(step string) {
				h.waitKicks()
				if got := accounts.total() + h.pot(); got != total {
					t.Fatalf("after %s: accounts+pot = %d, want %d", step, got, total)
				}
				for _, id := range h.occupiedIDs() {
					if have := h.mustSeat(id).Chips; have != mustGet(t, accounts, id) {
						t.Fatalf("after %s: %s seat %d != account %d", step, id, have, mustGet(t, accounts, id))
					}
				}
			}
			settledSoFar := 0
			for step := 0; step < 400; step++ {
				check(fmt.Sprintf("step %d", step))
				if h.settledCount() > settledSoFar {
					h.mu.Lock()
					for _, rec := range h.settled[settledSoFar:] {
						// Persisting ledger: winner +pot, everyone else 0.
						if got := sumDeltas(rec.entries); got != rec.hand.Pot {
							t.Fatalf("hand %d deltas sum to %d, want the pot %d", rec.hand.HandNo, got, rec.hand.Pot)
						}
						if got := sumContributed(rec.hand.Summary); got != rec.hand.Pot {
							t.Fatalf("hand %d contributions %d != pot %d", rec.hand.HandNo, got, rec.hand.Pot)
						}
						winners := 0
						for _, e := range rec.entries {
							if e.IsWinner {
								winners++
							}
						}
						if winners != 1 {
							t.Fatalf("hand %d has %d winners", rec.hand.HandNo, winners)
						}
					}
					settledSoFar = len(h.settled)
					h.mu.Unlock()
				}
				roll := rng.Intn(100)
				switch {
				case roll < 6:
					for _, id := range ids {
						if h.seatInfo(id) == nil && !h.table.IsFull() {
							v, ok := accounts.get(id)
							if !ok || v < cfg.BootAmount {
								total += start - v
								accounts.set(id, start)
								v = start
							}
							h.seat(id, v)
							break
						}
					}
				case roll < 10:
					occ := h.occupiedIDs()
					if len(occ) > 0 {
						h.remove(occ[rng.Intn(len(occ))], LeaveReasonLeft)
					}
				case roll < 20:
					h.advance(time.Duration(rng.Intn(30)) * time.Second)
				default:
					if !h.hasHand() {
						h.advance(cfg.NextHandDelay)
						continue
					}
					player := h.turnUser()
					opts := h.turnOptions(player)
					move := rng.Intn(100)
					var err error
					switch {
					case move < 25 && opts.CanSee:
						_, err = h.act(player, ActionSee, ActRequest{})
					case move < 30:
						// The right-hand neighbour looks off turn (what a sideshow
						// needs); already_seen is a legal refusal here.
						if right := h.rightOf(player); right != "" {
							_, _ = h.act(right, ActionSee, ActRequest{})
						}
					case move < 45 && opts.CanSideshow:
						if _, err = h.act(player, ActionSideshow, ActRequest{}); err == nil {
							to := h.view(player).Sideshow.ToUserID
							switch rng.Intn(3) {
							case 0:
								_, err = h.respond(to, true)
							case 1:
								_, err = h.respond(to, false)
							default:
								h.advance(7 * time.Second)
							}
						}
					case move < 50 && opts.Show != nil:
						_, err = h.act(player, ActionShow, ActRequest{})
					case move < 57:
						_, err = h.act(player, ActionPack, ActRequest{})
					case move < 64:
						h.advance(cfg.TurnTimeout)
					case len(opts.RaiseSteps) > 0:
						rung := opts.RaiseSteps[rng.Intn(len(opts.RaiseSteps))]
						action := ActionChaal
						if rung >= opts.RaiseSteps[0]*2 && rng.Intn(2) == 0 {
							action = ActionRaise
						}
						_, err = h.act(player, action, amt(rung))
					default:
						_, err = h.act(player, ActionPack, ActRequest{})
					}
					if err != nil {
						t.Fatalf("step %d: %v", step, err)
					}
				}
			}
			check("end")
			if h.handNo() < 3 {
				t.Fatalf("only %d hands played", h.handNo())
			}
			t.Logf("%s table: %d hands, %d settlements, %d showdowns, %d sideshows asked / %d compared, %d kicks, %d timeouts",
				cfg.Category, h.handNo(), h.settledCount(), len(h.rec.all("showdown")), len(h.sideshowRequested()),
				len(h.sideshowReveals()), len(h.kickEvents()), countPackReason(h.actions(), PackReasonTimeout))
			// Every account movement was a boot, bet, show or settle.
			for _, m := range *movements {
				switch m.reason {
				case LedgerReasonBoot, LedgerReasonBet, LedgerReasonShow, "settle":
				default:
					t.Fatalf("unexpected movement %+v", m)
				}
			}
		})
	}
}

func countPackReason(actions []ActionEvent, reason string) int {
	n := 0
	for _, a := range actions {
		if a.Action == ActionPack && a.Reason == reason {
			n++
		}
	}
	return n
}

// slowListener sleeps in every callback and, on kicks, calls back into the
// table from a goroutine — the RoomManager pattern.
func TestNoDeadlockWithASlowListenerAndConcurrentCallers(t *testing.T) {
	h := newHarness(t, settleConfig(), withKickHandler())
	h.rec.delay = 200 * time.Microsecond
	for _, id := range []string{"a", "b", "c", "d"} {
		h.seat(id, settleStart)
	}
	h.advance(6 * time.Second)

	done := make(chan struct{})
	go func() {
		defer close(done)
		var wg sync.WaitGroup
		// Readers hammer the posting reads while movers act; a wrong move is
		// a legal refusal, never a hang.
		for i := 0; i < 8; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				for n := 0; n < 40; n++ {
					_, _ = h.table.SerializeFor("a")
					_, _ = h.table.Seats()
					_, _ = h.table.Summary()
					_, _ = h.table.Act([]string{"a", "b", "c", "d"}[n%4], ActionChaal, ActRequest{})
					if n%10 == 0 {
						_, _ = h.table.PostChat("a", "hello")
					}
				}
			}(i)
		}
		wg.Wait()
	}()
	select {
	case <-done:
	case <-time.After(20 * time.Second):
		t.Fatal("deadlock: concurrent callers behind a slow listener never finished")
	}
	// The clock keeps working too: time out whoever is on turn.
	if h.hasHand() {
		h.advance(25 * time.Second)
	}
	if err := h.table.Settled(); err != nil {
		t.Fatal(err)
	}
}

func TestTimersNeverFireAfterDestroyAndPostsReturnErrTableDestroyed(t *testing.T) {
	h := newHarness(t, sideshowConfig(), withLedger(emptyLedger))
	for _, id := range []string{"a", "b", "c"} {
		h.seat(id, sideshowStart)
	}
	h.startHand()
	for _, id := range []string{"a", "b", "c"} {
		h.mustAct(id, ActionSee, ActRequest{})
	}
	// Arm every kind of timer: the start timer is still armed from the
	// countdown, the turn clock is running, and a sideshow request is pending.
	h.mustAct(h.turnUser(), ActionSideshow, ActRequest{})
	if h.clock.Pending() < 2 {
		t.Fatalf("expected the start and sideshow timers armed, have %d", h.clock.Pending())
	}

	if err := h.table.Destroy(); err != nil {
		t.Fatal(err)
	}
	eq(t, h.table.Destroyed(), true, "destroyed")
	eq(t, h.clock.Pending(), 0, "Destroy stopped every timer")
	eq(t, h.lastHandEnded().Reason, WinAllLeft, "the live hand was ended")
	eq(t, h.table.HasHand(), false, "no hand")
	count := h.rec.count()
	h.advance(time.Hour)
	eq(t, h.rec.count(), count, "no event after Destroy")

	// Every post is refused with ErrTableDestroyed.
	_, err := h.table.AddPlayer(NewPlayer{UserID: "z", DisplayName: "z", Chips: 1000})
	if !errors.Is(err, ErrTableDestroyed) {
		t.Fatalf("AddPlayer: %v", err)
	}
	if _, err := h.table.RemovePlayer("a", LeaveReasonLeft); !errors.Is(err, ErrTableDestroyed) {
		t.Fatalf("RemovePlayer: %v", err)
	}
	if _, err := h.table.Act("a", ActionChaal, ActRequest{}); !errors.Is(err, ErrTableDestroyed) {
		t.Fatalf("Act: %v", err)
	}
	if _, err := h.table.RespondToSideshow("a", true); !errors.Is(err, ErrTableDestroyed) {
		t.Fatalf("RespondToSideshow: %v", err)
	}
	if err := h.table.StartHand(); !errors.Is(err, ErrTableDestroyed) {
		t.Fatalf("StartHand: %v", err)
	}
	if _, err := h.table.SetConnected("a", false, ""); !errors.Is(err, ErrTableDestroyed) {
		t.Fatalf("SetConnected: %v", err)
	}
	if err := h.table.SetChips("a", 5); !errors.Is(err, ErrTableDestroyed) {
		t.Fatalf("SetChips: %v", err)
	}
	if _, err := h.table.PostChat("a", "hi"); !errors.Is(err, ErrTableDestroyed) {
		t.Fatalf("PostChat: %v", err)
	}
	if _, err := h.table.SerializeFor("a"); !errors.Is(err, ErrTableDestroyed) {
		t.Fatalf("SerializeFor: %v", err)
	}
	if _, err := h.table.Seats(); !errors.Is(err, ErrTableDestroyed) {
		t.Fatalf("Seats: %v", err)
	}
	if _, err := h.table.FindSeat("a"); !errors.Is(err, ErrTableDestroyed) {
		t.Fatalf("FindSeat: %v", err)
	}
	if _, err := h.table.Summary(); !errors.Is(err, ErrTableDestroyed) {
		t.Fatalf("Summary: %v", err)
	}
	if _, err := h.table.ChatHistory(); !errors.Is(err, ErrTableDestroyed) {
		t.Fatalf("ChatHistory: %v", err)
	}
	if err := h.table.Settled(); !errors.Is(err, ErrTableDestroyed) {
		t.Fatalf("Settled: %v", err)
	}
	if err := h.table.Destroy(); !errors.Is(err, ErrTableDestroyed) {
		t.Fatalf("second Destroy: %v", err)
	}
	eq(t, CodeOf(err, ""), CodeTableDestroyed, "code")
	// Lock-free reads still work.
	eq(t, h.table.PlayerCount(), 3, "seats are not cleared by destroy (Node kept them)")
	eq(t, h.table.State(), TableWaiting, "state after the ended hand")
}

func TestALateTimerCallbackAfterDestroyIsIgnored(t *testing.T) {
	// A real time.AfterFunc can fire just as Destroy runs; the callback's post
	// must come back ErrTableDestroyed rather than mutating a dead table.
	h := newHarness(t, tableConfig())
	h.seat("a", tableStart)
	h.seat("b", tableStart)
	h.advance(6 * time.Second)
	var fired func()
	h.read(func() {
		// Grab the armed turn-timer callback by re-arming through the clock.
		seatIndex := h.table.hand.turnSeat
		token := h.table.hand.turnToken
		fired = func() { _ = h.table.run(func() { h.table.onTurnTimeout(seatIndex, token) }) }
	})
	if err := h.table.Destroy(); err != nil {
		t.Fatal(err)
	}
	count := h.rec.count()
	fired() // must not block or emit
	eq(t, h.rec.count(), count, "nothing happened")
}

func TestAStaleTurnTimeoutIsANoOp(t *testing.T) {
	// The token guard: a timeout for a turn that has since moved on.
	h := newHarness(t, tableConfig())
	for _, id := range []string{"a", "b", "c"} {
		h.seat(id, tableStart)
	}
	h.advance(6 * time.Second)
	var seatIndex int
	var token string
	h.read(func() {
		seatIndex = h.table.hand.turnSeat
		token = h.table.hand.turnToken
	})
	first := h.turnUser()
	h.mustAct(first, ActionChaal, ActRequest{})
	count := h.rec.count()
	h.read(func() { h.table.onTurnTimeout(seatIndex, token) })
	eq(t, h.rec.count(), count, "stale timeout ignored")
	eq(t, h.mustSeat(first).Status, SeatActive, "still active")
	eq(t, h.mustSeat(first).MissedTurns, 0, "no miss recorded")
}

func TestAPanicInAMoveIsReturnedAsInternalErrorAndTheActorSurvives(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("a", tableStart)
	h.seat("b", tableStart)
	h.advance(6 * time.Second)
	// Force a programming error: a two-card hand at showdown panics in Evaluate.
	h.read(func() { h.table.findSeat("a").cards = ParseCards([]string{"As", "Ah"}) })
	_, err := h.act(h.turnUser(), ActionShow, ActRequest{})
	codeIs(t, err, CodeInternalError)
	// The actor is still alive.
	if _, err := h.table.SerializeFor("a"); err != nil {
		t.Fatalf("actor dead after a panic: %v", err)
	}
}

func TestVersionRisesOncePerCommittedWrite(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("a", tableStart)
	h.seat("b", tableStart)
	eq(t, h.table.Version(), int64(0), "fresh")
	h.advance(6 * time.Second)
	eq(t, h.table.Version(), int64(1), "boot")
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	eq(t, h.table.Version(), int64(2), "bet")
	h.mustAct(h.turnUser(), ActionSee, ActRequest{})
	eq(t, h.table.Version(), int64(2), "see is free")
	h.mustAct(h.turnUser(), ActionShow, ActRequest{})
	eq(t, h.table.Version(), int64(4), "show + settle")
}

func TestSetConnectedAndSetChips(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("a", tableStart)
	mark := h.rec.count()
	info, err := h.table.SetConnected("a", false, "")
	if err != nil || info == nil {
		t.Fatalf("SetConnected: %v %v", info, err)
	}
	eq(t, info.Connected, false, "disconnected")
	if info.DisconnectedAt == nil || *info.DisconnectedAt != Millis(h.clock.Now()) {
		t.Fatalf("disconnectedAt %v", info.DisconnectedAt)
	}
	eq(t, info.SocketID, "s-a", "socket id kept when none given")
	eq(t, strings.Join(h.rec.names()[mark:], ","), "seatUpdated,state", "setConnected emits seatUpdated + state")
	eq(t, seatViewOf(h.view("a"), "a").Connected, false, "public connected flag")

	info, _ = h.table.SetConnected("a", true, "s-a2")
	eq(t, info.Connected, true, "reconnected")
	eq(t, info.SocketID, "s-a2", "socket id updated")
	if info.DisconnectedAt != nil {
		t.Fatal("disconnectedAt cleared")
	}
	gone, err := h.table.SetConnected("nobody", true, "")
	if err != nil || gone != nil {
		t.Fatalf("unseated: %v %v", gone, err)
	}

	mark = h.rec.count()
	if err := h.table.SetChips("a", 42); err != nil {
		t.Fatal(err)
	}
	eq(t, h.mustSeat("a").Chips, int64(42), "chips applied")
	eq(t, strings.Join(h.rec.names()[mark:], ","), "seatUpdated", "setChips emits seatUpdated only")
}

func TestCancelStartWhenAFundedPlayerLeavesDuringTheCountdown(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("a", tableStart)
	h.seat("b", tableStart)
	eq(t, h.state(), TableStarting, "countdown")
	mark := h.rec.count()
	h.remove("b", LeaveReasonLeft)
	eq(t, h.state(), TableWaiting, "cancelled")
	eq(t, h.clock.Pending(), 0, "start timer cleared")
	if h.view("a").StartsAt != nil {
		t.Fatal("startsAt cleared")
	}
	eq(t, strings.Join(h.rec.names()[mark:], ","), "seatUpdated,chat,state,state", "cancelStart order")
	h.advance(time.Minute)
	eq(t, h.hasHand(), false, "nothing dealt")
}

func TestAddPlayerEventOrder(t *testing.T) {
	h := newHarness(t, tableConfig())
	h.seat("a", tableStart)
	eq(t, strings.Join(h.rec.names(), ","), "seatUpdated,chat,state", "first seat")
	mark := h.rec.count()
	h.seat("b", tableStart)
	eq(t, strings.Join(h.rec.names()[mark:], ","), "seatUpdated,chat,state,state", "second seat triggers the countdown")
	if h.view("a").StartsAt == nil || *h.view("a").StartsAt != Millis(h.clock.Now().Add(6*time.Second)) {
		t.Fatal("startsAt = now + nextHandDelay")
	}
	mark = h.rec.count()
	h.advance(6 * time.Second)
	eq(t, strings.Join(h.rec.names()[mark:], ","), "handStarted,turn,state", "deal order")
	mark = h.rec.count()
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	eq(t, strings.Join(h.rec.names()[mark:], ","), "action,turn,state,state", "chaal order")
	mark = h.rec.count()
	h.mustAct(h.turnUser(), ActionShow, ActRequest{})
	eq(t, strings.Join(h.rec.names()[mark:], ","), "action,showdown,handEnded,state,state", "show order (second state is STARTING)")
	ended := h.lastHandEnded()
	eq(t, ended.NextHandAt, Millis(h.clock.Now().Add(6*time.Second)), "nextHandAt")
	eq(t, h.state(), TableStarting, "next countdown")
}
