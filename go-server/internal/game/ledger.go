package game

import (
	"context"
	"errors"
)

// Ledger is where the chips are actually kept — the port of the three
// functions in server/src/db/ledger.js. Production hands the Table
// db.Ledger (PostgreSQL); unit tests hand it a MemoryLedger.
//
// Every method is ONE transaction: it either wholly happens or wholly does
// not. On failure it returns a *GameError whose Code is one of
// KnownLedgerCodes (duplicate_action, insufficient_chips, stale_state, no_pot,
// unknown_user, invalid_amount, persist_failed); the Table maps it with
// refusal() (only insufficient_chips and duplicate_action survive to the
// client; the rest become persist_failed).
//
// The Table calls these from its actor goroutine and blocks on them — the
// whole point: no timer or other move can interleave while a write is in
// flight. ctx is the Table's context (cancelled by Destroy).
type Ledger interface {
	// Bet is a chaal, raise or show: one player's chips into the pot.
	// Sequence (ledger.js bet): validate amount → BEGIN → SELECT chips FOR
	// UPDATE (unknown_user if no row; insufficient_chips if chips < amount) →
	// UPDATE users.chips → UPDATE pots.amount += (no_pot if no row) → INSERT
	// chip_ledger(action_id UNIQUE → duplicate_action) → COMMIT. The table
	// snapshot no longer rides in the transaction (LIVE_STATE_PLAN.md): the
	// actor saves it to the live store and the durable sink afterwards.
	Bet(ctx context.Context, req BetRequest) (BetResult, error)

	// CollectBoot opens the pot and takes the boot from every participant in
	// one transaction. Wallet rows are locked IN ASCENDING userId ORDER so two
	// tables sharing a player cannot deadlock. Any single player short of the
	// boot refuses the whole start with insufficient_chips + UserID set.
	// Writes: users.chips per player; INSERT pots(hand_id, room_id,
	// boot_amount, amount=total, opened_at); one chip_ledger row per player
	// with action_id BootActionID(handId, userId).
	CollectBoot(ctx context.Context, req CollectBootRequest) (CollectBootResult, error)

	// Settle ends a hand in one transaction: per entry in ascending userId
	// order: lock the wallet (skip silently if the row is gone), balance =
	// max(0, chips + delta), UPDATE users (chips, hands_played += didChaal,
	// hands_won += isWinner, hands_lost += !isWinner && !leftMidHand,
	// hands_left_mid += leftMidHand, total_winnings += pot if winner,
	// biggest_pot = GREATEST(…, pot if winner), updated_at); INSERT
	// chip_ledger with action_id SettleActionID(handId, userId), reason
	// hand_win / hand_loss (a zero delta is STILL written); then INSERT hands
	// … ON CONFLICT (id) DO NOTHING (after the wallet locks — its winner_id
	// foreign key locks the winner's row, see db.Ledger.Settle); UPDATE pots
	// SET closed_at, winner_id. Returns every settled balance. Idempotent by construction, which is what lets
	// the Table retry it.
	Settle(ctx context.Context, req SettleRequest) (SettleResult, error)
}

// BetRequest ← ledger.bet({...}) arguments.
type BetRequest struct {
	UserID string
	Amount int64
	RoomID string
	HandID string
	// ActionID is the client's own id for the move (≤ 64 chars) or a fresh
	// util.UUID() when the client sent none. Unique on chip_ledger.
	ActionID string
	// Reason is LedgerReasonBet or LedgerReasonShow.
	Reason string
	// BalanceBefore is what the seat believed it held; the DB figure wins.
	BalanceBefore int64
}

// BetResult ← `{ balance, persisted }`.
type BetResult struct {
	// Balance is the wallet after the deduction — the seat adopts it.
	Balance int64
	// Persisted is how much of the stake the account was actually debited:
	// all of it for Postgres; 0 for a MemoryLedger without PersistChips.
	// The Table adds it to the contribution's `persisted` so settlement can
	// compute delta = net + persisted (CLAUDE.md §12.2 "persisted is reported
	// by the ledger, not assumed").
	Persisted int64
}

// BootEntry is one participant in CollectBootRequest.
type BootEntry struct {
	UserID        string
	Amount        int64 // always the boot
	BalanceBefore int64
}

// CollectBootRequest ← ledger.collectBoot({...}).
type CollectBootRequest struct {
	RoomID     string
	HandID     string
	BootAmount int64
	Entries    []BootEntry
}

// CollectBootResult ← `{ balances, persisted }`.
type CollectBootResult struct {
	// Balances is userId → wallet after the boot, for every entry. The Table
	// prefers this over seat.chips - boot when the key is present.
	Balances map[string]int64
	// Persisted is the boot amount actually debited per player (bootAmount
	// for Postgres, 0 for a bookless MemoryLedger).
	Persisted int64
}

// SettleEntry is one contributor's outcome, deltas already computed by the
// Table (_endHand): delta = net + persisted where net is pot - contributed
// for the winner, -contributed for a loser, 0 when there is no winner.
type SettleEntry struct {
	UserID      string
	Delta       int64
	IsWinner    bool
	DidChaal    bool // requirement 16: drives hands_played
	LeftMidHand bool // drives hands_left_mid, and excludes from hands_lost
}

// SettleRequest ← ledger.settle({...}).
type SettleRequest struct {
	Hand    HandRecord
	Entries []SettleEntry
}

// SettleResult is userId → balance after settlement for every entry whose
// wallet row exists. The Table tests KEY PRESENCE, not truthiness — a balance
// of exactly 0 is valid (CLAUDE.md §12.2).
type SettleResult map[string]int64

// BootActionID is the deterministic chip_ledger.action_id for a boot:
// "<handId>:boot:<userId>".
func BootActionID(handID, userID string) string {
	return handID + ":boot:" + userID
}

// SettleActionID is the deterministic action_id for a settlement row:
// "<handId>:settle:<userId>".
func SettleActionID(handID, userID string) string {
	return handID + ":settle:" + userID
}

// PersistChipsArgs is what MemoryLedger's PersistChips hook receives for every
// boot and bet (test/helpers; CLAUDE.md §7.6): Delta is negative, Reason one
// of boot | bet | show. A returned error REFUSES the move (persist_failed).
type PersistChipsArgs struct {
	UserID   string
	Delta    int64
	Reason   string
	RoomID   string
	HandID   string
	ActionID string
}

// MemoryLedgerHooks are the two optional callbacks Node's memoryLedger wraps.
type MemoryLedgerHooks struct {
	// Settle, if set, is called at the end of every hand and must return the
	// post-hand balances (userId → balance). Nil → Settle returns an empty
	// map and the Table pays the winner in memory.
	Settle func(hand HandRecord, entries []SettleEntry) (map[string]int64, error)
	// PersistChips, if set, is called for every boot and bet. With it set the
	// stake "really left the account" and Persisted = amount; without it
	// Persisted = 0 and settlement must move the whole net.
	PersistChips func(args PersistChipsArgs) error
}

// MemoryLedger keeps no books of its own (table.js memoryLedger) — for
// tables built without a database. Bet returns BalanceBefore - Amount;
// CollectBoot returns BalanceBefore - Amount per entry. Errors from the hooks
// are wrapped as persist_failed GameErrors (unless already *GameError).
type MemoryLedger struct {
	Hooks MemoryLedgerHooks
}

// NewMemoryLedger builds a MemoryLedger with the given hooks (both optional).
func NewMemoryLedger(hooks MemoryLedgerHooks) *MemoryLedger {
	return &MemoryLedger{Hooks: hooks}
}

// Bet implements Ledger (table.js memoryLedger.bet): with a PersistChips
// hook the stake really left the account and Persisted = Amount; without one
// nothing did, Persisted = 0, and settlement must move the whole net. The
// hook refusing (returning an error) refuses the move.
func (m *MemoryLedger) Bet(ctx context.Context, req BetRequest) (BetResult, error) {
	persisted := int64(0)
	if m.Hooks.PersistChips != nil {
		if err := m.Hooks.PersistChips(PersistChipsArgs{
			UserID:   req.UserID,
			Delta:    -req.Amount,
			Reason:   req.Reason,
			RoomID:   req.RoomID,
			HandID:   req.HandID,
			ActionID: req.ActionID,
		}); err != nil {
			return BetResult{}, hookRefusal(err)
		}
		persisted = req.Amount
	}
	return BetResult{Balance: req.BalanceBefore - req.Amount, Persisted: persisted}, nil
}

// CollectBoot implements Ledger. Persisted is entries[0].Amount when
// PersistChips is set (Node: `entries[0]?.amount ?? 0`), else 0. Entries are
// debited in the order given (Node's memory ledger did not sort them); the
// first hook refusal refuses the whole start, and Balances reports
// BalanceBefore - Amount for every entry.
func (m *MemoryLedger) CollectBoot(ctx context.Context, req CollectBootRequest) (CollectBootResult, error) {
	balances := make(map[string]int64, len(req.Entries))
	for _, entry := range req.Entries {
		if m.Hooks.PersistChips != nil {
			if err := m.Hooks.PersistChips(PersistChipsArgs{
				UserID:   entry.UserID,
				Delta:    -entry.Amount,
				Reason:   LedgerReasonBoot,
				RoomID:   req.RoomID,
				HandID:   req.HandID,
				ActionID: BootActionID(req.HandID, entry.UserID),
			}); err != nil {
				return CollectBootResult{}, hookRefusal(err)
			}
		}
		balances[entry.UserID] = entry.BalanceBefore - entry.Amount
	}
	persisted := int64(0)
	if m.Hooks.PersistChips != nil && len(req.Entries) > 0 {
		persisted = req.Entries[0].Amount
	}
	return CollectBootResult{Balances: balances, Persisted: persisted}, nil
}

// Settle implements Ledger: the Settle hook's balances (nil → empty), or an
// empty map without a hook, in which case the Table pays the winner in
// memory.
func (m *MemoryLedger) Settle(ctx context.Context, req SettleRequest) (SettleResult, error) {
	if m.Hooks.Settle == nil {
		return SettleResult{}, nil
	}
	balances, err := m.Hooks.Settle(req.Hand, req.Entries)
	if err != nil {
		return nil, hookRefusal(err)
	}
	if balances == nil {
		return SettleResult{}, nil
	}
	return SettleResult(balances), nil
}

// hookRefusal is what a hook's error becomes: a *GameError passes through
// with its code (Node's `_refusal` switched on `error.code`), anything else is
// persist_failed with the original error as Cause.
func hookRefusal(err error) error {
	var ge *GameError
	if errors.As(err, &ge) {
		return ge
	}
	return &GameError{Code: CodePersistFailed, Message: err.Error(), Cause: err}
}

var _ Ledger = (*MemoryLedger)(nil)
