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

// bankLedger applies every checkpoint's delta to a fake wallet — the pack and
// leave rows as well as the settlement's — which is exactly what db.Ledger
// does.
func bankLedger(bk *bank, start int64) func(h *harness) Ledger {
	return func(h *harness) Ledger {
		return NewMemoryLedger(MemoryLedgerHooks{
			Checkpoint: func(args CheckpointArgs) error {
				h.recordCheckpoint(args)
				before, ok := bk.get(args.Entry.UserID)
				if !ok {
					before = start
				}
				bk.set(args.Entry.UserID, before+args.Entry.Delta)
				return nil
			},
			Settle: func(req SettleRequest, entries []SettleEntry) (map[string]int64, error) {
				h.recordSettle(req, entries)
				balances := map[string]int64{}
				for _, e := range entries {
					v, ok := bk.get(e.UserID)
					if !ok {
						v = start
					}
					balances[e.UserID] = v
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

// assertConserved: the pot is exactly what everybody staked, there is exactly
// one winner, and the winner's settlement delta is the pot less whatever of
// their own stake had not already been written through (nothing, unless they
// packed — which a winner never does).
//
// Note what it can NO LONGER assert: Σ of the settlement deltas is not zero,
// because a packer's stake moved at their own checkpoint and their outcome
// row carries a delta of zero. Conservation is a property of ALL the hand's
// ledger rows, and the bank-backed suites check that directly
// (accounts.total()).
func assertConserved(t *testing.T, h *harness, record settleCall) {
	t.Helper()
	ended := h.lastEnded()
	eq(t, sumContributed(ended.Summary), ended.Pot, "the pot equals everything staked")
	var winners []SettleEntry
	for _, e := range record.entries {
		if e.IsWinner {
			winners = append(winners, e)
		}
	}
	eq(t, len(winners), 1, "exactly one winner")
	if ended.WinnerID == nil || *ended.WinnerID != winners[0].UserID {
		t.Fatalf("the settled winner %s is not the announced one %v", winners[0].UserID, ended.WinnerID)
	}
	var own int64
	for _, row := range ended.Summary {
		if row.UserID == winners[0].UserID {
			own = row.Contributed
		}
	}
	eq(t, winners[0].Delta, ended.Pot-own, "the winner nets the pot minus their own stake")
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
	assertConserved(t, h, h.lastSettled())
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
	assertConserved(t, h, h.lastSettled())
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
	assertConserved(t, h, h.lastSettled())
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
	assertConserved(t, h, record)
	// They were resolved at their own leave checkpoint and are not in the
	// hand-end write; the bank shows what they paid.
	for _, e := range record.entries {
		if e.UserID == quitter {
			t.Fatal("a player who left must not be written again at the hand end")
		}
	}
	left, _ := bk.get(quitter)
	eq(t, left < settleStart, true, "the player who left still paid what they staked")
	eq(t, bk.total(), settleStart*3, "chips are conserved")
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
	assertConserved(t, h, h.lastSettled())
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

// The seat is the truth for a stack, and the ledger follows it: whatever
// Settle reports back, the Table keeps its own figures. (Before 9 Sep 2026 it
// adopted the balances the ledger returned, which is why "a settled balance
// of exactly 0 is valid, not missing" mattered; the checkpoint model has no
// such adoption.)
func TestTheSeatKeepsItsOwnFiguresWhateverSettleReports(t *testing.T) {
	h := newHarness(t, settleConfig(), withLedger(func(h *harness) Ledger {
		return NewMemoryLedger(MemoryLedgerHooks{
			Settle: func(req SettleRequest, entries []SettleEntry) (map[string]int64, error) {
				balances := map[string]int64{}
				for _, e := range entries {
					balances[e.UserID] = 0 // nonsense on purpose
				}
				return balances, nil
			},
		})
	}), withID("zero-room", "ZERO01"))
	h.seatNamed("a", "A", settleStart)
	h.seatNamed("b", "B", settleStart)
	h.advance(6 * time.Second)
	loser := h.turnUser()
	winner := h.otherActive(loser)
	h.mustAct(loser, ActionPack, ActRequest{})
	eq(t, h.mustSeat(loser).Chips, settleStart-settleBoot, "the packer keeps their stack")
	eq(t, h.mustSeat(winner).Chips, settleStart+settleBoot, "and the winner keeps the pot they were paid in memory")
}

// THE DEAL WRITES NOTHING (owner's decision of 9 Sep 2026): the boot comes
// out of the seat in memory, the wallet is untouched, and the contribution
// remembers the pre-boot figure so the first checkpoint can compute its
// delta. There is no boot transaction left to refuse a hand.
func TestTheDealWritesNothingToTheLedger(t *testing.T) {
	var writes int
	h := newHarness(t, settleConfig(), withLedger(func(h *harness) Ledger {
		return &captureLedger{
			inner:        emptyLedger(h),
			onCheckpoint: func(CheckpointRequest) { writes++ },
			onSettle:     func(SettleRequest) { writes++ },
		}
	}))
	h.seat("a", settleStart)
	h.seat("b", settleStart)
	h.advance(6 * time.Second)
	eq(t, h.hasHand(), true, "dealt")
	eq(t, writes, 0, "no ledger call at the deal")
	eq(t, h.table.Version(), int64(0), "and nothing committed")
	eq(t, h.mustSeat("a").Chips, settleStart-settleBoot, "the boot came out of the seat")
	eq(t, len(h.rec.all("persistError")), 0, "nothing could fail")

	snap := mustSnapshot(h)
	for _, c := range snap.Hand.Contributions {
		eq(t, c.ChipsWritten, settleStart, "PostgreSQL still holds the pre-boot figure")
		eq(t, c.Chips, settleStart-settleBoot, "the live state holds the post-boot one")
	}
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

// accountsLedger is chipPersistence.test.js's toy ledger, brought forward to
// the three-checkpoint model: the Checkpoint hook applies one delta to the
// fake account per ledger row (a pack, a leave, and every entry of the
// settlement), and records the movement so a test can count rows.
func accountsLedger(t *testing.T, accounts *bank, movements *[]movement) func(h *harness) Ledger {
	return func(h *harness) Ledger {
		var mu sync.Mutex
		return NewMemoryLedger(MemoryLedgerHooks{
			Checkpoint: func(args CheckpointArgs) error {
				h.recordCheckpoint(args)
				before, _ := accounts.get(args.Entry.UserID)
				after := before + args.Entry.Delta
				if after < 0 {
					return fmt.Errorf("%s went negative", args.Entry.UserID)
				}
				accounts.set(args.Entry.UserID, after)
				mu.Lock()
				*movements = append(*movements, movement{args.Entry.UserID, args.Entry.Delta, args.Entry.Reason})
				mu.Unlock()
				return nil
			},
			Settle: func(req SettleRequest, entries []SettleEntry) (map[string]int64, error) {
				// The Checkpoint hook above has already moved every account:
				// MemoryLedger calls it once per entry before this. Only the
				// balances are reported back.
				h.recordSettle(req, entries)
				balances := map[string]int64{}
				for _, e := range entries {
					v, _ := accounts.get(e.UserID)
					balances[e.UserID] = v
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

// THE BOOT DOES NOT LEAVE THE ACCOUNT AT THE DEAL (owner's decision of
// 9 Sep 2026). It comes out of the seat; PostgreSQL learns of it at the
// player's first checkpoint.
func TestTheBootLeavesTheSeatButNotYetTheAccount(t *testing.T) {
	h, accounts, movements := bankTable(t)
	h.seatNamed("alice", "ALICE", bankStart)
	accounts.set("alice", bankStart)
	h.seatNamed("bob", "BOB", bankStart)
	accounts.set("bob", bankStart)
	h.advance(6 * time.Second)

	eq(t, mustGet(t, accounts, "alice"), bankStart, "alice's wallet is untouched")
	eq(t, mustGet(t, accounts, "bob"), bankStart, "bob's wallet is untouched")
	eq(t, h.mustSeat("alice").Chips, bankStart-bankBoot, "but her seat has paid the ante")
	eq(t, h.pot(), bankBoot*2, "pot")
	eq(t, len(*movements), 0, "no ledger row at the deal")

	// The hand ends: now both wallets catch up in one row each.
	h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	eq(t, len(*movements), 3, "the packer's checkpoint and both outcome rows")
	eq(t, accounts.total(), bankStart*2, "chips are conserved")
}

// A chaal is not a database write (owner's decision of 9 Sep 2026): the chips
// move at the seat and in the live store, and the account follows at the
// player's next checkpoint — here, the hand end.
func TestAChaalReachesTheAccountAtTheHandEndNotWhenItIsMade(t *testing.T) {
	h, accounts, movements := bankTable(t)
	accounts.set("alice", bankStart)
	accounts.set("bob", bankStart)
	h.seatNamed("alice", "ALICE", bankStart)
	h.seatNamed("bob", "BOB", bankStart)
	h.advance(6 * time.Second)

	player := h.turnUser()
	stake := h.stake()
	h.mustAct(player, ActionChaal, ActRequest{})

	eq(t, mustGet(t, accounts, player), bankStart, "the account did NOT move with the bet")
	eq(t, h.mustSeat(player).Chips, bankStart-bankBoot-stake, "but the seat did")
	eq(t, len(*movements), 0, "and nothing reached the books")

	// The other player packs, so `player` wins the pot.
	other := h.otherActive(player)
	h.mustAct(other, ActionPack, ActRequest{})
	pot := bankBoot*2 + stake
	eq(t, mustGet(t, accounts, player), bankStart-bankBoot-stake+pot, "the winner's whole hand lands in one row")
	eq(t, mustGet(t, accounts, other), bankStart-bankBoot, "and the packer's in theirs")
	eq(t, accounts.total(), bankStart*2, "chips are conserved")
	rows := map[string]int{}
	for _, m := range *movements {
		rows[m.userID]++
	}
	eq(t, rows[player], 1, "one row for the winner")
	eq(t, rows[other], 2, "two for the packer: the pack checkpoint and the outcome")
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
	loserStaked := h.mustSeat(loser).Contributed
	winnerStaked := h.mustSeat(winner).Contributed

	h.mustAct(loser, ActionPack, ActRequest{})

	eq(t, mustGet(t, accounts, winner), bankStart-winnerStaked+pot, "the winner's wallet is stake out, pot in")
	eq(t, mustGet(t, accounts, loser), bankStart-loserStaked, "the loser paid what they staked, once")
	eq(t, accounts.total(), bankStart*2, "chips are conserved")
	// The settlement deltas: the winner nets the pot less their own stake,
	// and the packer's row is zero because their pack already moved it.
	for _, e := range h.lastSettled().entries {
		if e.IsWinner {
			eq(t, e.Delta, pot-winnerStaked, "winner delta")
		} else {
			eq(t, e.Delta, int64(0), "the packer's money moved at the pack")
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
	eq(t, mustGet(t, accounts, quitter), bankStart, "nothing is written while they play")

	// Leaving mid-hand resolves them at once — their wallet has to be right
	// the moment they are gone — and their stake stays in the pot.
	h.remove(quitter, LeaveReasonLeft)
	eq(t, mustGet(t, accounts, quitter), bankStart-staked, "everything they staked is banked, and stays in the pot")

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

// The seat can never hold more than the wallet — the property that makes the
// in-memory balance check as safe as the wallet lock it replaced. During a
// hand the account is AHEAD of the seat by exactly the bets not yet banked,
// so the seat is always the smaller number and the flush can never overdraw.
func TestASeatNeverHoldsMoreThanItsAccount(t *testing.T) {
	h, accounts, _ := bankTable(t)
	accounts.set("alice", bankStart)
	accounts.set("bob", bankStart)
	h.seatNamed("alice", "ALICE", bankStart)
	h.seatNamed("bob", "BOB", bankStart)
	h.advance(6 * time.Second)

	for i := 0; i < 4 && h.hasHand(); i++ {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
		for _, id := range h.activeIDs() {
			seat := h.mustSeat(id).Chips
			account := mustGet(t, accounts, id)
			if seat > account {
				t.Fatalf("%s: seat %d exceeds account %d — a flush could overdraw the wallet", id, seat, account)
			}
			eq(t, seat-account, h.unwritten(id), id+": the account is ahead by exactly what has not been written")
		}
	}
	// At the hand boundary they agree again.
	for h.hasHand() {
		h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	}
	for _, id := range []string{"alice", "bob"} {
		eq(t, h.mustSeat(id).Chips, mustGet(t, accounts, id), id+" out of step at rest")
	}
}

// -------------------------------------------------- ledger failure paths

// A bet no longer has a ledger transaction of its own (owner's decision of
// 9 Sep 2026), so the two refusals the database used to produce are made in
// memory instead — and a refused bet must still change absolutely nothing.
func TestAReplayedBetIsRefusedAndChangesNothing(t *testing.T) {
	h := newHarness(t, settleConfig())
	h.seat("a", settleStart)
	h.seat("b", settleStart)
	h.advance(6 * time.Second)
	player := h.turnUser()

	// The first move under this action id goes through.
	h.mustAct(player, ActionChaal, ActRequest{ActionID: "dup-same-id"})
	other := h.turnUser()
	h.mustAct(other, ActionChaal, ActRequest{ActionID: "other-id"})
	eq(t, h.turnUser(), player, "the turn came back")

	before := h.mustSeat(player)
	pot := h.pot()
	deadline := h.lastTurn().Deadline
	mark := h.rec.count()

	_, err := h.act(player, ActionChaal, ActRequest{ActionID: "dup-same-id"})
	codeIs(t, err, CodeDuplicateAction)
	var ge *GameError
	errors.As(err, &ge)
	eq(t, ge.Message, MsgDuplicateAction, "message")

	names := h.rec.names()[mark:]
	eq(t, strings.Join(names, ","), "persistError", "only a persistError is emitted")
	pe := h.rec.last("persistError").(PersistErrorEvent)
	eq(t, pe.UserID, player, "persistError userId")
	eq(t, pe.Reason, LedgerReasonBet, "persistError reason")
	after := h.mustSeat(player)
	eq(t, after.Chips, before.Chips, "chips unchanged")
	eq(t, after.Contributed, before.Contributed, "contributed unchanged")
	eq(t, h.pot(), pot, "pot unchanged")
	eq(t, h.turnUser(), player, "turn unchanged")
	eq(t, h.lastTurn().Deadline, deadline, "clock untouched")

	// A fresh id on the same move goes through.
	h.mustAct(player, ActionChaal, ActRequest{ActionID: "fresh-id"})
	eq(t, h.pot() > pot, true, "the pot moved")
}

// A checkpoint the ledger refuses never stops the move: the pack or the
// departure has already happened at the table. The failure is reported, the
// player's chipsWritten is NOT advanced, and the hand-end write therefore
// still carries their whole delta — so nothing is lost, only late.
func TestACheckpointTheLedgerRefusesIsReportedAndCarriedToTheHandEnd(t *testing.T) {
	var refuse error
	accounts := newBank()
	movements := &[]movement{}
	h := newHarness(t, bankConfig(), withLedger(func(h *harness) Ledger {
		inner := accountsLedger(t, accounts, movements)(h)
		return &captureLedger{inner: inner, checkpoint: func(r CheckpointRequest) (CheckpointResult, error) {
			if refuse != nil {
				return CheckpointResult{}, refuse
			}
			return inner.Checkpoint(context.Background(), r)
		}}
	}))
	for _, id := range []string{"alice", "bob", "carol"} {
		accounts.set(id, bankStart)
		h.seatNamed(id, strings.ToUpper(id), bankStart)
	}
	h.advance(6 * time.Second)
	player := h.turnUser()
	h.mustAct(player, ActionChaal, ActRequest{})
	staked := h.mustSeat(player).Contributed
	pot := h.pot()

	// Bring the turn back round to them so they can pack.
	for i := 0; i < 4 && h.turnUser() != player; i++ {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
	staked = h.mustSeat(player).Contributed
	pot = h.pot()

	refuse = errors.New("connection reset")
	h.mustAct(player, ActionPack, ActRequest{})
	eq(t, h.pot(), pot, "their stake stays in the pot")
	pe := h.rec.last("persistError").(PersistErrorEvent)
	eq(t, pe.Reason, LedgerReasonHandPacked, "reported as a pack checkpoint failure")
	eq(t, pe.UserID, player, "for the packer")
	eq(t, mustGet(t, accounts, player), bankStart, "their wallet is untouched")

	// The hand ends with the ledger back: the whole delta lands then.
	refuse = nil
	for h.hasHand() {
		h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	}
	eq(t, mustGet(t, accounts, player), bankStart-staked, "the refused checkpoint was carried to the hand end")
	eq(t, accounts.total(), bankStart*3, "chips are conserved")
}

func TestASettlementTheLedgerRefusesIsPaidInMemoryAndRetried(t *testing.T) {
	var failSettle bool
	var settleCalls []string
	h := newHarness(t, settleConfig(), withLedger(func(h *harness) Ledger {
		inner := mirrorLedger(h)
		return &captureLedger{inner: inner, settle: func(r SettleRequest) (SettleResult, error) {
			settleCalls = append(settleCalls, r.HandID)
			if failSettle {
				return nil, errors.New("settle down")
			}
			return inner.Settle(context.Background(), r)
		}}
	}))
	h.seat("a", settleStart)
	h.seat("b", settleStart)
	h.advance(6 * time.Second)
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{}) // writes nothing: version stays 1
	pot := h.pot()
	loser := h.turnUser()
	winner := h.otherActive(loser)
	winnerBefore := h.mustSeat(winner).Chips

	failSettle = true
	mark := h.rec.count()
	h.mustAct(loser, ActionPack, ActRequest{})

	eq(t, h.hasHand(), false, "the hand is over whatever the database says")
	eq(t, h.mustSeat(winner).Chips, winnerBefore+pot, "the winner is paid in memory")
	eq(t, h.table.Version(), int64(1), "version not bumped on a failed settle")
	names := h.rec.names()[mark:]
	eq(t, strings.Join(names, ","), "action,persistError,handEnded,state,state", "pack → failed settle → handEnded → state → state(starting)")
	pe := h.rec.all("persistError")[0].(PersistErrorEvent)
	eq(t, pe.Reason, "settle", "reason settle")
	eq(t, len(settleCalls), 1, "first attempt")

	// Retry 1 fires after NextHandDelay × 1 = 6 s; the next hand's countdown
	// also fires at 6 s, but the retry timer was armed first (inside endHand,
	// before maybeStart) so it runs first. It re-sends the same record.
	failSettle = false
	mark = h.rec.count()
	h.advance(6 * time.Second)
	eq(t, len(settleCalls), 2, "retried once")
	eq(t, settleCalls[1], settleCalls[0], "the same hand is re-sent")
	eq(t, h.table.Version(), int64(2), "the retry committed; the next deal writes nothing")
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
			attempts[r.HandID]++
			if r.HandID != firstHand {
				return inner.Settle(context.Background(), r)
			}
			switch attempts[r.HandID] {
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
	eq(t, h.table.Version(), int64(2), "the retry committed; the next deal writes nothing")
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
			Settle: func(SettleRequest, []SettleEntry) (map[string]int64, error) { return nil, errors.New("settle down") },
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
// after every step that Σaccounts + the BANKED part of the pot never changes,
// that every seated player's seat is their account less their unbanked bets
// (so the seat can never exceed the wallet), and that every settlement's
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
				// The pot's UNBANKED part (bets that have not reached the
				// books) is still sitting in the accounts, so it must not be
				// counted twice.
				if got := accounts.total() + h.pot() - h.unwrittenPot(); got != total {
					t.Fatalf("after %s: accounts+bankedPot = %d, want %d", step, got, total)
				}
				for _, id := range h.occupiedIDs() {
					have, account := h.mustSeat(id).Chips, mustGet(t, accounts, id)
					if have > account {
						t.Fatalf("after %s: %s seat %d exceeds account %d", step, id, have, account)
					}
					if have-account != h.unwritten(id) {
						t.Fatalf("after %s: %s seat %d, account %d, unwritten %d", step, id, have, account, h.unwritten(id))
					}
				}
			}
			settledSoFar := 0
			for step := 0; step < 400; step++ {
				check(fmt.Sprintf("step %d", step))
				if h.settledCount() > settledSoFar {
					h.mu.Lock()
					for _, rec := range h.settled[settledSoFar:] {
						winners := 0
						for _, e := range rec.entries {
							if e.IsWinner {
								winners++
							}
							if e.ActionID != SettleActionID(rec.req.HandID, e.UserID) {
								t.Fatalf("hand %s: entry for %s carries %q", rec.req.HandID, e.UserID, e.ActionID)
							}
							if !e.Outcome {
								t.Fatalf("hand %s: settlement entry for %s is not an outcome row", rec.req.HandID, e.UserID)
							}
						}
						if winners != 1 {
							t.Fatalf("hand %s has %d winners", rec.req.HandID, winners)
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
			// Every account movement was one of the three checkpoints.
			for _, m := range *movements {
				switch m.reason {
				case LedgerReasonHandPacked, LedgerReasonHandLeft, LedgerReasonHandWin, LedgerReasonHandLoss:
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
	eq(t, h.table.Version(), int64(0), "the deal writes nothing")
	h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	eq(t, h.table.Version(), int64(0), "nor does a bet")
	h.mustAct(h.turnUser(), ActionSee, ActRequest{})
	eq(t, h.table.Version(), int64(0), "see is free")
	h.mustAct(h.turnUser(), ActionShow, ActRequest{})
	eq(t, h.table.Version(), int64(1), "the settlement is the only write")
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

// The two correctness traps of the three-checkpoint model, together.
//
// TRAP 1 — resolve each player exactly once. A packer IS written at the hand
// end (their outcome row and its counters belong there), but their money must
// move only at the pack: the settlement entry's delta is zero, so two rows
// coexist and the wallet moves once. A player who LEFT is resolved at their
// own checkpoint and is not in the hand-end write at all.
//
// TRAP 2 — a delta, never an absolute. A reward credited to a seated player
// mid-hand survives the next checkpoint.
func TestAPackerIsWrittenTwiceButChargedOnce(t *testing.T) {
	var checkpoints []CheckpointRequest
	var settles []SettleRequest
	accounts := newBank()
	movements := &[]movement{}
	h := newHarness(t, bankConfig(), withLedger(func(h *harness) Ledger {
		return &captureLedger{
			inner:        accountsLedger(t, accounts, movements)(h),
			onCheckpoint: func(r CheckpointRequest) { checkpoints = append(checkpoints, r) },
			onSettle:     func(r SettleRequest) { settles = append(settles, r) },
		}
	}))
	for _, id := range []string{"alice", "bob", "carol"} {
		accounts.set(id, bankStart)
		h.seatNamed(id, strings.ToUpper(id), bankStart)
	}
	h.advance(6 * time.Second)

	packer := h.turnUser()
	h.mustAct(packer, ActionChaal, ActRequest{ActionID: "packer-bet-1"})
	for i := 0; i < 4 && h.turnUser() != packer; i++ {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
	staked := h.mustSeat(packer).Contributed
	eq(t, len(checkpoints), 0, "nothing written while they play")
	eq(t, mustGet(t, accounts, packer), bankStart, "and their wallet has not moved")

	h.mustAct(packer, ActionPack, ActRequest{})
	eq(t, len(checkpoints), 1, "the pack writes them through")
	eq(t, checkpoints[0].Entry.UserID, packer, "the packer")
	eq(t, checkpoints[0].Entry.Delta, -staked, "their whole stake, as a delta")
	eq(t, checkpoints[0].Entry.Reason, LedgerReasonHandPacked, "reason")
	eq(t, checkpoints[0].Entry.Outcome, false, "no counters yet")
	eq(t, mustGet(t, accounts, packer), bankStart-staked, "wallet up to date")

	for h.hasHand() {
		h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	}
	eq(t, len(settles), 1, "one settlement")
	var settled *SettleEntry
	for i := range settles[0].Entries {
		if settles[0].Entries[i].UserID == packer {
			settled = &settles[0].Entries[i]
		}
	}
	if settled == nil {
		t.Fatal("the packer must still be resolved at the hand end")
	}
	eq(t, settled.Delta, int64(0), "but their money moved at the pack")
	eq(t, settled.Reason, LedgerReasonHandLoss, "the outcome row is a loss")
	eq(t, settled.Outcome, true, "which is where hands_lost lands")
	eq(t, settled.ActionID != checkpoints[0].Entry.ActionID, true, "two distinct action ids, so both rows coexist")
	eq(t, mustGet(t, accounts, packer), bankStart-staked, "the wallet moved exactly once")

	rows := 0
	for _, m := range *movements {
		if m.userID == packer {
			rows++
		}
	}
	eq(t, rows, 2, "two ledger rows: the pack and the outcome")
	eq(t, accounts.total(), bankStart*3, "chips are conserved")
}

// TRAP 2: a reward claimed while seated credits PostgreSQL and not the seat.
// The next checkpoint writes a DELTA, so the reward survives; an absolute
// overwrite would erase it.
func TestARewardCreditedMidHandSurvivesTheNextCheckpoint(t *testing.T) {
	const reward int64 = 10000
	accounts := newBank()
	movements := &[]movement{}
	h := newHarness(t, bankConfig(), withLedger(accountsLedger(t, accounts, movements)))
	for _, id := range []string{"alice", "bob", "carol"} {
		accounts.set(id, bankStart)
		h.seatNamed(id, strings.ToUpper(id), bankStart)
	}
	h.advance(6 * time.Second)

	player := h.turnUser()
	h.mustAct(player, ActionChaal, ActRequest{})
	for i := 0; i < 4 && h.turnUser() != player; i++ {
		h.mustAct(h.turnUser(), ActionChaal, ActRequest{})
	}
	staked := h.mustSeat(player).Contributed

	// The four-hour bonus lands in PostgreSQL while they are at the table.
	// (The REST handlers refuse this now — auth.Handler.Bonus returns 409
	// `seated` — but the money path must not depend on that gate.)
	before, _ := accounts.get(player)
	accounts.set(player, before+reward)

	h.mustAct(player, ActionPack, ActRequest{})
	eq(t, mustGet(t, accounts, player), bankStart+reward-staked,
		"the checkpoint applied a delta, so the reward is still there")

	for h.hasHand() {
		h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	}
	eq(t, mustGet(t, accounts, player), bankStart+reward-staked, "and the hand end did not erase it either")
	eq(t, accounts.total(), bankStart*3+reward, "nothing created or destroyed beyond the reward")
}

// A player who LEFT mid-hand is resolved at their own checkpoint — their
// wallet is right the moment they are gone — and is NOT written again at the
// hand end.
func TestLeavingMidHandResolvesThePlayerOnceAtTheirOwnCheckpoint(t *testing.T) {
	var checkpoints []CheckpointRequest
	var settles []SettleRequest
	accounts := newBank()
	movements := &[]movement{}
	h := newHarness(t, bankConfig(), withLedger(func(h *harness) Ledger {
		return &captureLedger{
			inner:        accountsLedger(t, accounts, movements)(h),
			onCheckpoint: func(r CheckpointRequest) { checkpoints = append(checkpoints, r) },
			onSettle:     func(r SettleRequest) { settles = append(settles, r) },
		}
	}))
	for _, id := range []string{"alice", "bob", "carol"} {
		accounts.set(id, bankStart)
		h.seatNamed(id, strings.ToUpper(id), bankStart)
	}
	h.advance(6 * time.Second)

	quitter := h.turnUser()
	h.mustAct(quitter, ActionChaal, ActRequest{})
	staked := h.mustSeat(quitter).Contributed
	eq(t, len(checkpoints), 0, "nothing written while they play")

	h.remove(quitter, LeaveReasonLeft)
	eq(t, len(checkpoints), 1, "the departure writes them through")
	eq(t, checkpoints[0].Entry.UserID, quitter, "the leaver")
	eq(t, checkpoints[0].Entry.Delta, -staked, "their whole stake")
	eq(t, checkpoints[0].Entry.Reason, LedgerReasonHandLeft, "reason")
	eq(t, checkpoints[0].Entry.Outcome, true, "this row resolves them")
	eq(t, checkpoints[0].Entry.LeftMidHand, true, "hands_left_mid lands here")
	eq(t, mustGet(t, accounts, quitter), bankStart-staked, "wallet right the moment they are gone")

	for h.hasHand() && len(h.activeIDs()) > 1 {
		h.mustAct(h.turnUser(), ActionPack, ActRequest{})
	}
	eq(t, len(settles), 1, "one settlement")
	for _, e := range settles[0].Entries {
		if e.UserID == quitter {
			t.Fatal("a player who left must not be written again at the hand end")
		}
	}
	rows := 0
	for _, m := range *movements {
		if m.userID == quitter {
			rows++
		}
	}
	eq(t, rows, 1, "exactly one ledger row, never two")
	eq(t, accounts.total(), bankStart*3, "chips are conserved")
}
