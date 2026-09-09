package game

import (
	"context"
	"errors"
)

// Ledger is where the chips are actually kept.
//
// # The money model (owner's decision, 9 Sep 2026)
//
// ALL game state lives in the live store (Redis). PostgreSQL holds money and
// audit only, and it is written at exactly THREE moments, each of which takes
// a player's chips as the live state has them and makes the wallet agree:
//
//	a player LEAVES or SWITCHES table   → that player only   (reason hand_left)
//	a player PACKS                      → that player only   (reason hand_packed)
//	the HAND ENDS (a winner is decided) → everyone still at the table
//	                                      (reason hand_win / hand_loss)
//
// Nothing else writes: not the deal, not a chaal, raise, show or see. Those
// move chips at the seat, in the pot and in the Redis snapshot, and nowhere
// else.
//
// # Deltas, never absolutes
//
// Every write is `UPDATE users SET chips = chips + delta`, where the Table
// computed `delta = seat.chips now − seat.chips as last written`. It is never
// `SET chips = <value from the live state>`: a seated player can claim the
// four-hour bonus or a milestone reward, which credits PostgreSQL and not the
// seat, and an absolute overwrite at the next checkpoint would erase it. With
// a delta the reward survives, and with no concurrent credit the resulting
// wallet equals the live figure exactly.
//
// A player written twice for the same hand (packed, then settled) computes a
// zero delta the second time, so the money moves once while the outcome row
// and its counters are still recorded. A zero-delta row is not noise: it is
// what says this player was in the hand and how it ended for them.
//
// # Errors and idempotency
//
// Every method is ONE transaction: it either wholly happens or wholly does
// not. On failure it returns a *GameError whose Code is one of
// KnownLedgerCodes (duplicate_action, insufficient_chips, unknown_user,
// invalid_amount, persist_failed); the Table maps it with refusal(). Each
// entry carries its own `chip_ledger.action_id` — "<handId>:packed:<userId>",
// "<handId>:left:<userId>", "<handId>:settle:<userId>" — which is UNIQUE, so
// a replayed write raises a unique violation, rolls the whole transaction
// back and comes out as duplicate_action: the Table treats that on a retry as
// the success it is.
//
// The Table calls these from its actor goroutine and blocks on them — the
// whole point: no timer or other move can interleave while a write is in
// flight. ctx is the Table's context (cancelled by Destroy).
type Ledger interface {
	// Checkpoint writes ONE player's chips through: the pack checkpoint and
	// the leave/switch checkpoint. No hands row.
	Checkpoint(ctx context.Context, req CheckpointRequest) (CheckpointResult, error)

	// Settle is the HAND-END checkpoint: every player still at the table.
	// Per entry, in ascending userId
	// order: lock the wallet (skip silently if the row is gone), balance =
	// max(0, chips + delta), UPDATE users (chips, hands_played += DidChaal
	// when Outcome, hands_won += IsWinner, hands_lost += Outcome &&
	// !IsWinner && !LeftMidHand, hands_left_mid += LeftMidHand,
	// total_winnings += Pot if winner, biggest_pot = GREATEST(…, Pot if
	// winner), updated_at); INSERT chip_ledger with the entry's ActionID and
	// Reason (a zero delta is STILL written). Returns every settled balance.
	// The Table retries it unchanged on failure; the UNIQUE action ids are
	// what make that safe.
	Settle(ctx context.Context, req SettleRequest) (SettleResult, error)
}

// Checkpoint reasons — the `chip_ledger.reason` of the three moments.
const (
	// LedgerReasonHandPacked is the pack checkpoint: the player folded, so
	// their stake is fixed and their wallet is brought up to date at once.
	// It carries no counters — the outcome row at the hand end does.
	LedgerReasonHandPacked = "hand_packed"
	// LedgerReasonHandLeft is the leave/switch checkpoint: the player is
	// gone from the table, their wallet must be right immediately, and
	// hands_left_mid is incremented here because they will not be at the
	// hand-end write.
	LedgerReasonHandLeft = "hand_left"
)

// SettleEntry is one player's row at one checkpoint. The Table computes
// Delta; the ledger applies it and writes exactly one chip_ledger row.
type SettleEntry struct {
	// UserID is whose wallet moves.
	UserID string
	// Delta is `chips now − chips as last written to PostgreSQL`, so it may
	// be negative (they staked), positive (they won) or zero (already
	// written; the row records the outcome only).
	Delta int64
	// ActionID is the row's unique id: PackedActionID / LeftActionID /
	// SettleActionID.
	ActionID string
	// Reason is the chip_ledger reason: hand_packed, hand_left, hand_win or
	// hand_loss.
	Reason string
	// Outcome marks the row that RESOLVES the hand for this player and
	// therefore carries the counters (hand_win, hand_loss, hand_left). The
	// pack checkpoint is not an outcome — the player is still at the table
	// and the hand-end write will resolve them.
	Outcome bool
	// IsWinner drives hands_won, total_winnings and biggest_pot.
	IsWinner bool
	// DidChaal drives hands_played on an outcome row (requirement 16).
	DidChaal bool
	// LeftMidHand drives hands_left_mid, and excludes the row from hands_lost.
	LeftMidHand bool
	// Pot is the hand's pot, used for total_winnings/biggest_pot when
	// IsWinner.
	Pot int64
}

// CheckpointRequest is one player's pack or leave checkpoint.
type CheckpointRequest struct {
	RoomID string
	HandID string
	Entry  SettleEntry
}

// CheckpointResult is the wallet after the write (0 when the account is
// gone). The Table does not adopt it — the seat is the live truth and the
// wallet follows — but it is logged and asserted in tests.
type CheckpointResult struct {
	Balance int64
}

// SettleRequest ← the hand-end checkpoint.
type SettleRequest struct {
	RoomID  string
	HandID  string
	Entries []SettleEntry
}

// SettleResult is userId → balance after the write for every entry whose
// wallet row exists.
type SettleResult map[string]int64

// PackedActionID is the chip_ledger.action_id of a pack checkpoint:
// "<handId>:packed:<userId>".
func PackedActionID(handID, userID string) string {
	return handID + ":packed:" + userID
}

// LeftActionID is the action_id of a leave/switch checkpoint:
// "<handId>:left:<userId>".
func LeftActionID(handID, userID string) string {
	return handID + ":left:" + userID
}

// SettleActionID is the action_id of a hand-end row:
// "<handId>:settle:<userId>".
func SettleActionID(handID, userID string) string {
	return handID + ":settle:" + userID
}

// CheckpointArgs is what MemoryLedger's Checkpoint hook receives for every
// row the table writes — the pack and leave checkpoints and each entry of
// the hand-end settlement. A returned error fails that write (the Table
// reports it and, at the hand end, retries).
type CheckpointArgs struct {
	RoomID string
	HandID string
	Entry  SettleEntry
}

// MemoryLedgerHooks are the optional callbacks a test ledger wraps.
type MemoryLedgerHooks struct {
	// Checkpoint, if set, is called once per ledger row: the pack and leave
	// checkpoints and every entry of the settlement. It is where a test's
	// fake wallet moves.
	Checkpoint func(args CheckpointArgs) error
	// Settle, if set, is called once at the hand end with the request and the
	// entries, AFTER the per-entry Checkpoint calls, and returns the
	// post-hand balances. Nil → Settle returns an empty map.
	Settle func(req SettleRequest, entries []SettleEntry) (map[string]int64, error)
}

// MemoryLedger keeps no books of its own — for tables built without a
// database. Errors from the hooks are wrapped as persist_failed GameErrors
// (unless already *GameError).
type MemoryLedger struct {
	Hooks MemoryLedgerHooks
}

// NewMemoryLedger builds a MemoryLedger with the given hooks (both optional).
func NewMemoryLedger(hooks MemoryLedgerHooks) *MemoryLedger {
	return &MemoryLedger{Hooks: hooks}
}

// Checkpoint implements Ledger: the pack / leave write.
func (m *MemoryLedger) Checkpoint(ctx context.Context, req CheckpointRequest) (CheckpointResult, error) {
	if m.Hooks.Checkpoint != nil {
		if err := m.Hooks.Checkpoint(CheckpointArgs{RoomID: req.RoomID, HandID: req.HandID, Entry: req.Entry}); err != nil {
			return CheckpointResult{}, hookRefusal(err)
		}
	}
	return CheckpointResult{}, nil
}

// Settle implements Ledger: every entry through the Checkpoint hook, then the
// Settle hook's balances (nil → empty, and the Table keeps its own figures).
func (m *MemoryLedger) Settle(ctx context.Context, req SettleRequest) (SettleResult, error) {
	if m.Hooks.Checkpoint != nil {
		for _, entry := range req.Entries {
			if err := m.Hooks.Checkpoint(CheckpointArgs{RoomID: req.RoomID, HandID: req.HandID, Entry: entry}); err != nil {
				return nil, hookRefusal(err)
			}
		}
	}
	if m.Hooks.Settle == nil {
		return SettleResult{}, nil
	}
	balances, err := m.Hooks.Settle(req, req.Entries)
	if err != nil {
		return nil, hookRefusal(err)
	}
	if balances == nil {
		return SettleResult{}, nil
	}
	return SettleResult(balances), nil
}

// hookRefusal is what a hook's error becomes: a *GameError passes through
// with its code, anything else is persist_failed with the original as Cause.
func hookRefusal(err error) error {
	var ge *GameError
	if errors.As(err, &ge) {
		return ge
	}
	return &GameError{Code: CodePersistFailed, Message: err.Error(), Cause: err}
}

var _ Ledger = (*MemoryLedger)(nil)
