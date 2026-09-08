package db

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/metrics"
)

// UniqueViolation is PostgreSQL SQLSTATE 23505. A violation whose constraint
// or detail mentions action_id is the one database error expected in normal
// play: a retried move, refused as duplicate_action.
const UniqueViolation = "23505"

// Ledger is the PostgreSQL game.Ledger (db/ledger.js). Every method is one
// transaction under WithTx, timed into game_db_transaction_duration_seconds{op}
// and counted on failure in game_db_transaction_errors_total{op,code}; boot
// also feeds game_hand_start_duration_seconds and settle
// game_settlement_duration_seconds (Node wrapped them the same way).
//
// Every error leaves here as a *game.GameError with a KnownLedgerCodes code
// (Classify); the driver error is kept in Cause for logs.
type Ledger struct {
	db      *DB
	metrics *metrics.Metrics // may be nil (tests)
	clock   func() time.Time
}

// NewLedger builds the ledger. m may be nil (no observations); clock nil →
// time.Now.
func NewLedger(d *DB, m *metrics.Metrics, clock func() time.Time) *Ledger {
	return &Ledger{db: d, metrics: m, clock: clock}
}

var _ game.Ledger = (*Ledger)(nil)

// Bet implements game.Ledger — see the interface doc for the exact statement
// sequence. SQL (verbatim from ledger.js, table names unqualified — the
// connection's search_path resolves them):
//
//	SELECT chips FROM users WHERE id = $1 FOR UPDATE
//	UPDATE users SET chips = $1, updated_at = $2 WHERE id = $3
//	UPDATE pots SET amount = amount + $1 WHERE hand_id = $2         (rowCount 0 → no_pot)
//	INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at) VALUES (…)
//	INSERT INTO game_states … ON CONFLICT (room_id) DO UPDATE SET … WHERE game_states.version < EXCLUDED.version  (rowCount 0 → stale_state)
//
// Amount ≤ 0 → invalid_amount before BEGIN. Returns {balance, persisted: amount}.
func (l *Ledger) Bet(ctx context.Context, req game.BetRequest) (game.BetResult, error) {
	panic("not ported: (*Ledger).Bet")
}

// CollectBoot implements game.Ledger. Entries are sorted by UserID ascending
// before any lock. insufficient_chips carries UserID. Pot row:
//
//	INSERT INTO pots (hand_id, room_id, boot_amount, amount, opened_at) VALUES ($1,$2,$3,$4,$5)
//
// with amount = Σ entry.Amount. One ledger row per entry (action_id
// game.BootActionID), then saveState. Returns {balances, persisted: bootAmount}.
func (l *Ledger) CollectBoot(ctx context.Context, req game.CollectBootRequest) (game.CollectBootResult, error) {
	panic("not ported: (*Ledger).CollectBoot")
}

// Settle implements game.Ledger. Statements:
//
//	INSERT INTO hands (id, room_id, hand_no, pot, winner_id, win_reason, boot_amount, started_at, ended_at, summary_json)
//	  VALUES ($1,…,$10::jsonb) ON CONFLICT (id) DO NOTHING
//	-- per entry, userId ascending:
//	SELECT chips FROM users WHERE id = $1 FOR UPDATE                (no row → skip the entry)
//	UPDATE users SET chips=$1, hands_played=hands_played+$2, hands_won=hands_won+$3, hands_lost=hands_lost+$4,
//	       hands_left_mid=hands_left_mid+$5, total_winnings=total_winnings+$6, biggest_pot=GREATEST(biggest_pot,$7),
//	       updated_at=$8 WHERE id=$9
//	INSERT INTO chip_ledger (…) -- action_id game.SettleActionID, reason hand_win|hand_loss, delta may be 0
//	UPDATE pots SET closed_at = $1, winner_id = $2 WHERE hand_id = $3
//	saveState(roomId, handId NULL, version, state)
//
// balance = max(0, chips + delta). summary_json is json.Marshal(hand.Summary)
// ([] when empty, never null).
func (l *Ledger) Settle(ctx context.Context, req game.SettleRequest) (game.SettleResult, error) {
	panic("not ported: (*Ledger).Settle")
}

// Classify turns any error into the *game.GameError the Table expects
// (ledger.js classify): a *game.GameError passes through; a pgconn.PgError
// with Code UniqueViolation whose ConstraintName or Detail contains
// "action_id" → duplicate_action ("That move has already been applied");
// anything else → persist_failed with the message of err and Cause = err.
func Classify(err error) *game.GameError {
	panic("not ported: db.Classify")
}

// lockWallet: SELECT chips … FOR UPDATE; unknown_user when no row.
func lockWallet(ctx context.Context, tx pgx.Tx, userID string) (int64, error) {
	panic("not ported")
}

// appendLedger inserts one chip_ledger row. handID/actionID "" → NULL.
func appendLedger(ctx context.Context, tx pgx.Tx, userID, handID, actionID string, delta, balance int64, reason string, at int64) error {
	panic("not ported")
}

// saveState upserts game_states, refusing to go backwards in version
// (stale_state). version 0 with a nil state → no-op (Node: undefined version).
// state is json.Marshal'd; nil → "{}".
func saveState(ctx context.Context, tx pgx.Tx, roomID, handID string, version int64, state *game.Snapshot, at int64) error {
	panic("not ported")
}
