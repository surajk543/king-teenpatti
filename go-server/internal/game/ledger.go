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
// is still recorded. A zero-delta row is not noise: it is what says this
// player was in the hand and how it ended for them.
//
// # Money only
//
// The ledger writes MONEY and nothing else (Player stats v2, owner 27 Sep
// 2026): no gameplay counter is written in these transactions any more. The
// counters a write resolves travel beside it (SettleRequest.Stats) and reach
// the table's StatsRecorder only once it has committed, which queues them for
// the live store; a flusher moves them into PostgreSQL in batches
// (internal/stats).
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
	// max(0, chips + delta), UPDATE users (chips, updated_at); INSERT
	// chip_ledger with the entry's ActionID and Reason (a zero delta is STILL
	// written) — and for an entry carrying a table tax, the win gross and a
	// table_tax row after it (LedgerRows), in the same transaction. Returns
	// every settled balance and, per player, the winning-tax rate their level
	// carries after the XP this settle awarded (SettleResult.TaxBps).
	// req.Stats is not the ledger's: no counter is written here (Player stats
	// v2) — it is carried for the table, which records it once the write has
	// committed (StatsRecorder). The Table retries it unchanged on failure;
	// the UNIQUE action ids are what make that safe.
	Settle(ctx context.Context, req SettleRequest) (SettleResult, error)
}

// Checkpoint reasons — the `chip_ledger.reason` of the three moments.
const (
	// LedgerReasonHandPacked is the pack checkpoint: the player folded, so
	// their stake is fixed and their wallet is brought up to date at once.
	// It carries no counters — the outcome row at the hand end does.
	LedgerReasonHandPacked = "hand_packed"
	// LedgerReasonHandLeft is the leave/switch checkpoint: the player is
	// gone from the table, their wallet must be right immediately, and it is
	// the write their departure is counted after (hands_left), because they
	// will not be at the hand-end write.
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
	// Outcome marks the row that RESOLVES the hand for this player, and so
	// the one their counters are computed from (StatsForEntry: hand_win,
	// hand_loss, hand_left). The pack checkpoint is not an outcome — the
	// player is still at the table and the hand-end write will resolve them.
	Outcome bool
	// IsWinner drives hands_won, total_winnings and biggest_pot.
	IsWinner bool
	// Push marks a hand that ended level for this player: 3-Card Poker's tie
	// against the house, where both bets come back (internal/poker). It is
	// neither a win nor a loss, so it moves no counter at all — without it a
	// push counted as one or the other, and a player's lifetime winnings grew
	// by a stake that was only handed back. Never set by Teen Patti.
	Push bool
	// DidChaal drives hands_played on an outcome row (requirement 16).
	DidChaal bool
	// LeftMidHand drives hands_left (player_stats; the wire's handsLeftMid),
	// and excludes the row from hands_lost.
	LeftMidHand bool
	// Pot is the hand's pot, used for total_winnings/biggest_pot when
	// IsWinner. With several winners (a poker split or side pot) it is THIS
	// winner's share: the counters are per entry, so each winning entry
	// carries what its player took.
	Pot int64
	// Tax is the TABLE TAX withheld from this entry's winnings (owner, 26 Sep
	// 2026; TableTax): set on the winner's hand-end entry at a taxed table,
	// and 0 on every other entry and at every other table. Delta is already
	// NET of it — the wallet moves by Delta, as for every entry — and the
	// ledger writes the entry as TWO rows (LedgerRows): the win at its gross
	// figure, Delta + Tax, and the tax as a table_tax row of −Tax. Never set
	// by the poker family.
	Tax int64
	// WonWith is the Teen Patti hand the winner held, as the table counts it
	// (handRules / playedHand: a variation's wild cards make the hand, under
	// 5-Card the three that played) — HandCategory.Code: TRAIL,
	// PURE_SEQUENCE, SEQUENCE, COLOR, PAIR or HIGH_CARD — on the winner's
	// hand-end entry at a Teen Patti table, however the hand ended; "" on
	// every other entry and in the poker family. The daily XP of the WIN_HAND
	// sources is earned by it (owner, 27 Sep 2026: "Win by Pair +1 XP … Win by
	// Trail +20 XP").
	WonWith string
	// Game and Variant name the family and variant the row was written by
	// (chip_ledger.game / .variant, V1.0.0__baseline.sql): "" for a Teen
	// Patti table, whose rows are byte for byte what they were; GamePoker and
	// the poker category for a poker room (POKER_PLAN.md §6).
	Game    Game
	Variant Category
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
	// PlayedMs is the hand's duration, from the deal to its end, in ms (owner,
	// 26 Sep 2026): the active play each player the hand-end write resolves
	// adds to their XP window in the live store, where the 30- and 60-minute
	// XP is earned (db.Ledger hands it on after the commit). A retry resends
	// it unchanged. 0 adds nothing.
	PlayedMs int64
	// Stats are the counters this hand resolves, one per player it counts
	// for (StatsForEntry plus the held hand and the variation), computed when
	// the hand ended — the cards and the rules are gone by the time a retry
	// lands. The ledger never reads them: the table records them once a
	// Settle of this request has COMMITTED (on the first attempt or a retry,
	// never on duplicate_action — Settler), so a hand is counted at most
	// once, and only when its money moved.
	Stats []HandStats
}

// SettleResult is what a landed hand-end settlement reports.
type SettleResult struct {
	// Balances is userId → the wallet after the write, for every entry whose
	// wallet row exists.
	Balances map[string]int64
	// TaxBps is userId → the winning-tax rate, in basis points, of the
	// player's level AFTER the XP this settle awarded (owner, 26 Sep 2026;
	// tabletax.go), for every settled player whose level the ledger could
	// resolve — read in the settle's own transaction. nil from a ledger that
	// keeps no levels. A Teen Patti table adopts it onto their seats, for the
	// hands they are dealt after (Table.adoptTaxRates).
	TaxBps map[string]int
}

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

// TaxActionID is the action_id of a table-tax row: "<handId>:tax:<userId>".
// UNIQUE like every other, so a settle retry that replays the hand end is
// refused duplicate_action on it too, and the tax is taken once.
func TaxActionID(handID, userID string) string {
	return handID + ":tax:" + userID
}

// LedgerRows is the chip_ledger rows entry is written as, in order — what
// db.Ledger inserts and what MemoryLedger hands its Checkpoint hook, so the
// two cannot disagree. An entry with no Tax is one row, itself. An entry that
// carries a table tax is two (owner, 26 Sep 2026): the entry at its GROSS
// figure — Delta + Tax, what the win would have been untaxed, so the hand's
// hand_* rows still sum to zero — and then a table_tax row of −Tax under
// TaxActionID, a row of its own that moves no counter (Outcome false). The
// rows' deltas sum to entry.Delta, which is what the wallet moves by.
func LedgerRows(handID string, entry SettleEntry) []SettleEntry {
	if entry.Tax <= 0 {
		return []SettleEntry{entry}
	}
	win := entry
	win.Delta = entry.Delta + entry.Tax
	win.Tax = 0
	return []SettleEntry{win, {
		UserID:   entry.UserID,
		Delta:    -entry.Tax,
		ActionID: TaxActionID(handID, entry.UserID),
		Reason:   LedgerReasonTableTax,
		Game:     entry.Game,
		Variant:  entry.Variant,
	}}
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
	// checkpoints and every row of the settlement — one per entry, two for a
	// taxed winner's (LedgerRows). It is where a test's fake wallet moves.
	Checkpoint func(args CheckpointArgs) error
	// Settle, if set, is called once at the hand end with the request and the
	// entries, AFTER the per-entry Checkpoint calls, and returns the
	// post-hand balances. Nil → Settle returns an empty map.
	Settle func(req SettleRequest, entries []SettleEntry) (map[string]int64, error)
	// TaxBps, if set, is called after a Settle that succeeded and supplies
	// SettleResult.TaxBps — the rates the players' levels carry now. Nil →
	// no rates, and every seat keeps the one it has.
	TaxBps func(req SettleRequest) map[string]int
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

// Settle implements Ledger: every ledger row of every entry through the
// Checkpoint hook — a taxed winner's entry as its two rows, the gross win and
// the table tax (LedgerRows), exactly as db.Ledger writes them — then the
// Settle hook's balances (nil → empty, and the Table keeps its own figures).
// The Settle hook sees req.Entries as the Table sent them, Tax included.
func (m *MemoryLedger) Settle(ctx context.Context, req SettleRequest) (SettleResult, error) {
	if m.Hooks.Checkpoint != nil {
		for _, entry := range req.Entries {
			for _, row := range LedgerRows(req.HandID, entry) {
				if err := m.Hooks.Checkpoint(CheckpointArgs{RoomID: req.RoomID, HandID: req.HandID, Entry: row}); err != nil {
					return SettleResult{}, hookRefusal(err)
				}
			}
		}
	}
	result := SettleResult{Balances: map[string]int64{}}
	if m.Hooks.Settle != nil {
		balances, err := m.Hooks.Settle(req, req.Entries)
		if err != nil {
			return SettleResult{}, hookRefusal(err)
		}
		if balances != nil {
			result.Balances = balances
		}
	}
	if m.Hooks.TaxBps != nil {
		result.TaxBps = m.Hooks.TaxBps(req)
	}
	return result, nil
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
