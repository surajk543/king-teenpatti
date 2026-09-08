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

// DurableSource supplies the snapshots the live store did not have, and the
// ledger totals used to correct a stale one.
type DurableSource interface {
	LoadSnapshots(ctx context.Context) ([]DurableSnapshot, error)
	// HandContributions returns userID → chips banked for that hand
	// (chip_ledger rows with reason boot|bet|show, as positive numbers).
	HandContributions(ctx context.Context, handID string) (map[string]int64, error)
}
