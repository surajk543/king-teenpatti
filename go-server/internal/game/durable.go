package game

// The durable backstop (LIVE_STATE_PLAN.md, "Reconstructing Redis from
// PostgreSQL"): game_states stays as the copy the live store is rebuilt from
// when Redis comes up empty, written asynchronously so the money transaction
// stays small. The game package only defines the two contracts; internal/db
// implements them (SnapshotWriter, and the reads over game_states /
// chip_ledger). A nil SnapshotSink or DurableSource is a no-op everywhere.

import "context"

// SnapshotSink is the durable backstop: PostgreSQL's game_states, written
// asynchronously so the money transaction stays small. MarkDirty must never
// block the actor — it hands over the newest snapshot for a room and returns.
//
// The table feeds it at the two HAND BOUNDARIES only (Table.markDurable):
// the hand's opening state and the table at rest after settlement. Between
// them the live store carries every mutation and the ledger carries the
// money; a durable row is therefore at most one hand behind, and
// ReconcileWithLedger closes that gap on the way back.
type SnapshotSink interface {
	MarkDirty(roomID string, seq int64, handID string, snapshot []byte)
	MarkDeleted(roomID string)
}

// DurableSnapshot is one row of game_states.
type DurableSnapshot struct {
	RoomID    string
	HandID    string
	Seq       int64
	State     []byte
	UpdatedAt int64
}

// LedgerContribution is one player's stake in a hand as the chip_ledger
// tells it. The slice HandContributions returns is in LEDGER ORDER — each
// player positioned by their most recent row for the hand — so its last
// element is whoever put chips in last. ReconcileWithLedger uses that to
// decide where play resumes (see reopenTurn).
type LedgerContribution struct {
	// UserID is the player who staked.
	UserID string
	// Amount is everything they have banked for this hand (boot + bets +
	// show) as a positive number.
	Amount int64
}

// DurableSource supplies the snapshots the live store did not have, and the
// ledger totals used to correct a stale one.
type DurableSource interface {
	LoadSnapshots(ctx context.Context) ([]DurableSnapshot, error)
	// HandContributions returns what each player has banked for that hand
	// (chip_ledger rows with reason boot|bet|show, as positive numbers), in
	// ledger order — the player who moved last comes last.
	HandContributions(ctx context.Context, handID string) ([]LedgerContribution, error)
}
