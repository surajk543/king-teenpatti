package db

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

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

// Checkpoint implements game.Ledger: ONE player's pack or leave checkpoint,
// in one transaction.
//
//	SELECT chips FROM users WHERE id = $1 FOR UPDATE          (no row → unknown_user)
//	UPDATE users SET chips = chips + delta, counters…, updated_at
//	INSERT INTO chip_ledger (…, action_id UNIQUE)             (replay → duplicate_action, whole txn rolls back)
//
// The delta is what the Table computed (`chips now − chips as last written`);
// this never writes an absolute value, so a reward credited to a seated
// player is not erased. A zero delta still writes its row.
func (l *Ledger) Checkpoint(ctx context.Context, req game.CheckpointRequest) (game.CheckpointResult, error) {
	var result game.CheckpointResult
	err := l.transact(metrics.OpCheckpoint, func() error {
		return l.db.WithTx(ctx, func(tx pgx.Tx) error {
			balance, err := applyCheckpoint(ctx, tx, req.Entry, req.HandID, now(l.clock))
			if errors.Is(err, errAccountGone) {
				// Settle skips a deleted account silently (its rows went with
				// it); a single-player checkpoint has nothing else to do, so
				// it says so.
				return game.Errorf(game.CodeUnknownUser, "unknown user %s", req.Entry.UserID)
			}
			if err != nil {
				return err
			}
			result = game.CheckpointResult{Balance: balance}
			return nil
		})
	})
	if err != nil {
		return game.CheckpointResult{}, err
	}
	return result, nil
}

// applyCheckpoint writes one player's row against a wallet it locks itself,
// and returns the balance it left. An account that no longer exists is
// skipped silently (Node's `continue`), reporting a balance of 0.
func applyCheckpoint(ctx context.Context, tx pgx.Tx, entry game.SettleEntry, handID string, at int64) (int64, error) {
	chips, err := lockWallet(ctx, tx, entry.UserID)
	if err != nil {
		if game.CodeOf(err, "") == game.CodeUnknownUser {
			return 0, errAccountGone
		}
		return 0, err
	}

	// Never below zero: the CHECK on users.chips would reject an overdraft,
	// and a checkpoint is a correction, not a bet.
	balance := chips + entry.Delta
	if balance < 0 {
		balance = 0
	}

	// Counters land on the row that RESOLVES the hand for this player: the
	// settlement row, or the leave row for someone who walked out. A pack
	// checkpoint moves money only. "Played" means chips beyond the boot —
	// posting the ante and folding straight away is not a hand played
	// (requirement 16).
	played, won, lost, left := 0, 0, 0, 0
	var gross int64
	if entry.Outcome {
		played = boolToInt(entry.DidChaal)
		won = boolToInt(entry.IsWinner)
		lost = boolToInt(!entry.IsWinner && !entry.LeftMidHand)
		left = boolToInt(entry.LeftMidHand)
		if entry.IsWinner {
			gross = entry.Pot
		}
	}

	if _, err := tx.Exec(ctx, `UPDATE users
          SET chips          = $1,
              hands_played   = hands_played + $2,
              hands_won      = hands_won + $3,
              hands_lost     = hands_lost + $4,
              hands_left_mid = hands_left_mid + $5,
              total_winnings = total_winnings + $6,
              biggest_pot    = GREATEST(biggest_pot, $7),
              updated_at     = $8
        WHERE id = $9`,
		balance, played, won, lost, left, gross, gross, at, entry.UserID); err != nil {
		return 0, err
	}

	// A zero delta is still recorded: the row is what says this player was in
	// the hand and how it ended for them.
	if err := appendLedger(ctx, tx, entry.UserID, handID, entry.ActionID, entry.Delta, balance, entry.Reason, at); err != nil {
		return 0, err
	}
	return balance, nil
}

// errAccountGone marks a checkpoint whose wallet row has been deleted: the
// entry is skipped, not failed (the ledger rows went with the account).
var errAccountGone = errors.New("account gone")

// Settle implements game.Ledger: the HAND-END checkpoint. ONE transaction,
// every entry through applyCheckpoint in ascending userId order — wallets
// locked in order so two tables sharing a player cannot deadlock, and that is
// now the ONLY lock this transaction takes (the `hands` table is gone, so
// there is no foreign-key lock on the winner's row to order around any more;
// DECISIONS §2's rule about inserting `hands` after the wallets is moot).
//
// The retry path (Table.retrySettle) resends exactly this request; a replay
// hits the per-entry action ids' UNIQUE index, rolls the whole transaction
// back and returns duplicate_action, which the Table reads as the success it
// is. That uniqueness is the settle-retry safety mechanism: a commit whose
// acknowledgement is lost must never pay the winner the pot twice.
func (l *Ledger) Settle(ctx context.Context, req game.SettleRequest) (game.SettleResult, error) {
	var result game.SettleResult
	started := time.Now()
	err := l.transact(metrics.OpSettle, func() error {
		return l.db.WithTx(ctx, func(tx pgx.Tx) error {
			at := now(l.clock)
			balances := make(game.SettleResult, len(req.Entries))
			ordered := make([]game.SettleEntry, len(req.Entries))
			copy(ordered, req.Entries)
			sort.SliceStable(ordered, func(i, j int) bool { return ordered[i].UserID < ordered[j].UserID })

			for _, entry := range ordered {
				balance, err := applyCheckpoint(ctx, tx, entry, req.HandID, at)
				if errors.Is(err, errAccountGone) {
					continue
				}
				if err != nil {
					return err
				}
				balances[entry.UserID] = balance
			}
			result = balances
			return nil
		})
	})
	if l.metrics != nil && l.metrics.SettlementDuration != nil {
		l.metrics.SettlementDuration.Observe(time.Since(started).Seconds())
	}
	if err != nil {
		return nil, err
	}
	return result, nil
}

// transact runs one ledger operation under its metrics (ledger.js transact):
// the transaction's duration by operation, and — when it fails — a count by
// error code. Every failure leaves here as a *game.GameError, whatever it
// started out as. fn is the whole operation including any pre-BEGIN
// validation, exactly the span Node timed.
func (l *Ledger) transact(op string, fn func() error) error {
	started := time.Now()
	err := fn()
	if l.metrics != nil && l.metrics.DBTransactionDuration != nil {
		l.metrics.DBTransactionDuration.WithLabelValues(op).Observe(time.Since(started).Seconds())
	}
	if err == nil {
		return nil
	}
	refusal := Classify(err)
	if l.metrics != nil && l.metrics.DBTransactionErrors != nil {
		code := metrics.SafeLabel(refusal.Code, game.KnownLedgerCodes, metrics.OtherLabel)
		l.metrics.DBTransactionErrors.WithLabelValues(op, code).Inc()
	}
	return refusal
}

// Classify turns any error into the *game.GameError the Table expects
// (ledger.js classify): a *game.GameError passes through; a pgconn.PgError
// with Code UniqueViolation whose ConstraintName or Detail contains
// "action_id" → duplicate_action ("That move has already been applied");
// anything else → persist_failed with the message of err and Cause = err.
// nil → nil.
func Classify(err error) *game.GameError {
	if err == nil {
		return nil
	}
	var ge *game.GameError
	if errors.As(err, &ge) {
		return ge
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == UniqueViolation && containsAny("action_id", pgErr.Detail, pgErr.ConstraintName) {
		return game.NewGameError(game.CodeDuplicateAction, "That move has already been applied")
	}
	message := err.Error()
	if message == "" {
		message = "database write failed"
	}
	return &game.GameError{Code: game.CodePersistFailed, Message: message, Cause: err}
}

// lockWallet: SELECT chips … FOR UPDATE; unknown_user when no row. Locking
// first, then reading, is what stops two bets from the same account racing
// past the balance check.
func lockWallet(ctx context.Context, tx pgx.Tx, userID string) (int64, error) {
	var chips int64
	err := tx.QueryRow(ctx, `SELECT chips FROM users WHERE id = $1 FOR UPDATE`, userID).Scan(&chips)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, game.Errorf(game.CodeUnknownUser, "unknown user %s", userID)
	}
	if err != nil {
		return 0, err
	}
	return chips, nil
}

// appendLedger inserts one chip_ledger row. handID/actionID "" → NULL.
func appendLedger(ctx context.Context, tx pgx.Tx, userID, handID, actionID string, delta, balance int64, reason string, at int64) error {
	_, err := tx.Exec(ctx, `INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7)`,
		userID, nullIfEmpty(handID), nullIfEmpty(actionID), delta, balance, reason, at)
	return err
}

// containsAny reports whether any of the haystacks contains needle.
func containsAny(needle string, haystacks ...string) bool {
	for _, h := range haystacks {
		if strings.Contains(h, needle) {
			return true
		}
	}
	return false
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
