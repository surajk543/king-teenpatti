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
	// onSettled hears of every hand-end settlement that committed (OnSettled).
	onSettled func(SettledHand)
}

// NewLedger builds the ledger. m may be nil (no observations); clock nil →
// time.Now.
func NewLedger(d *DB, m *metrics.Metrics, clock func() time.Time) *Ledger {
	return &Ledger{db: d, metrics: m, clock: clock}
}

// SettledHand is what a hand-end settlement that committed hands on, after
// the commit, to OnSettled's hook — the XP the transaction awarded and the
// play time it leaves for the live store (owner, 26 Sep 2026).
type SettledHand struct {
	HandID string
	// Players are the players the hand-end write resolved as having completed
	// the hand — dealt in and at the table when it ended — in ascending id
	// order: the ones whose XP window it opened or rolled, and whose play the
	// hand adds to.
	Players []string
	// Windows is the XP window each of Players' play counts in: the epoch ms
	// it opened (player_xp.window_start), as the settle left it.
	Windows map[string]int64
	// PlayedMs is the hand's duration (game.SettleRequest.PlayedMs): the
	// active play each of Players adds to their XP window in the live store.
	PlayedMs int64
	// Window is how long an XP window lasts (xp_settings.window_ms, read in
	// the settle's transaction); 0 when no XP is awarded at all.
	Window time.Duration
	// Levels are the players whose XP the settlement changed, each with the
	// standing they now have — what each is told of in player:level.
	Levels map[string]Standing
}

// OnSettled sets the hook that hears of every hand-end settlement after it
// has COMMITTED — never of one that failed, and never inside the transaction.
// It is called on the caller's goroutine (a table's actor), so it must not
// block: the app pushes player:level and hands the play time to a goroutine
// of its own (internal/xp). Set it before the ledger is used; nil clears it.
func (l *Ledger) OnSettled(fn func(SettledHand)) { l.onSettled = fn }

var _ game.Ledger = (*Ledger)(nil)

// Checkpoint implements game.Ledger: ONE player's pack or leave checkpoint,
// in one transaction.
//
//	SELECT chips FROM users WHERE id = $1 FOR UPDATE          (no row → unknown_user)
//	UPDATE users SET chips = chips + delta, updated_at
//	INSERT INTO chip_ledger (…, action_id UNIQUE)             (replay → duplicate_action, whole txn rolls back)
//
// The delta is what the Table computed (`chips now − chips as last written`);
// this never writes an absolute value, so a reward credited to a seated
// player is not erased. A zero delta still writes its row.
//
// Money only (Player stats v2, owner 27 Sep 2026): no gameplay counter is
// written here. A departure's counters reach PostgreSQL through the live
// store and the stats flusher (internal/stats), recorded by the table once
// this transaction has committed.
//
// A replay is refused duplicate_action carrying the delta the row already
// holding its action id recorded (game.DuplicateCheckpoint), read back after
// the rollback: the Table advances what it counts as written by exactly that
// much (game.LandedDelta; Table.checkpoint). When the row cannot be read back
// the refusal is the bare duplicate_action, and the Table treats the write as
// refused rather than guess.
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
		var dup *game.GameError
		if errors.As(err, &dup) && dup.Code == game.CodeDuplicateAction {
			if landed, ok := l.landedDelta(ctx, req.Entry.ActionID); ok {
				return game.CheckpointResult{}, game.DuplicateCheckpoint(dup.Message, landed)
			}
		}
		return game.CheckpointResult{}, err
	}
	return result, nil
}

// landedDelta is the delta of the chip_ledger row holding actionID, for a
// checkpoint just refused duplicate_action: ok is false when the row cannot
// be read (the database has gone away since, or the purge took the row in
// the instant between). One indexed read, on the refusal path only.
func (l *Ledger) landedDelta(ctx context.Context, actionID string) (int64, bool) {
	if actionID == "" {
		return 0, false
	}
	var delta int64
	if err := l.db.Pool.QueryRow(ctx, `SELECT delta FROM chip_ledger WHERE action_id = $1`, actionID).Scan(&delta); err != nil {
		return 0, false
	}
	return delta, true
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

	// The wallet is all this writes on users. The hand's counters are not the
	// ledger's any more (Player stats v2): the table records them once this
	// transaction has committed (game.StatsForEntry, SettleRequest.Stats), and
	// they reach player_stats by the flusher's group commit.
	if _, err := tx.Exec(ctx, `UPDATE users SET chips = $1, updated_at = $2 WHERE id = $3`,
		balance, at, entry.UserID); err != nil {
		return 0, err
	}

	// A zero delta is still recorded: the row is what says this player was in
	// the hand and how it ended for them. A winner who paid the winning tax is
	// written as two rows (game.LedgerRows): the win GROSS, then the tax as a
	// table_tax row of its own — so the hand's hand_* rows still sum to zero
	// and the tax is exactly the chips that left the game. The wallet moves
	// once, by the entry's Delta; each row carries the balance it leaves, the
	// last the wallet's.
	rows := game.LedgerRows(handID, entry)
	after := balance - entry.Delta // the rows' deltas sum to entry.Delta
	for _, row := range rows {
		after += row.Delta
		if err := appendLedgerFor(ctx, tx, row.UserID, handID, row.ActionID, row.Delta, after, row.Reason, at, string(row.Game), string(row.Variant)); err != nil {
			return 0, err
		}
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
//
// The same transaction does the hand's XP (owner, 26–27 Sep 2026; awardXP):
// it opens or rolls the XP window of every player it resolves as having
// completed the hand — an outcome row of a player who did not leave mid-hand —
// and awards the winner the WIN_HAND source of the hand they won with
// (SettleEntry.WonWith), once a window; a replay's rollback takes the XP with
// it, so a hand is never counted twice either. It then reads the standing of
// every player it wrote, AFTER that XP: SettleResult.TaxBps, the rate each
// seat deals its next hand with — the lower of the level's and the badges',
// so a badge that has run out since the last hand stops counting here. Only
// once it has committed is OnSettled's hook told (SettledHand).
func (l *Ledger) Settle(ctx context.Context, req game.SettleRequest) (game.SettleResult, error) {
	var result game.SettleResult
	var settled SettledHand
	started := time.Now()
	err := l.transact(metrics.OpSettle, func() error {
		return l.db.WithTx(ctx, func(tx pgx.Tx) error {
			at := now(l.clock)
			result = game.SettleResult{Balances: make(map[string]int64, len(req.Entries))}
			settled = SettledHand{HandID: req.HandID, PlayedMs: req.PlayedMs, Levels: map[string]Standing{}, Windows: map[string]int64{}}
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
				result.Balances[entry.UserID] = balance
			}

			// The hand's XP, after every wallet: the player_xp rows are locked
			// in the same ascending order the wallets were, so two settlements
			// sharing players cannot deadlock on them either.
			rules, err := loadXPRules(ctx, tx)
			if err != nil {
				return err
			}
			settled.Window = rules.window()
			var changed []string
			written := make([]string, 0, len(ordered))
			for _, entry := range ordered {
				if _, ok := result.Balances[entry.UserID]; !ok {
					continue // the account is gone: nothing was written for it
				}
				written = append(written, entry.UserID)
				if !entry.Outcome || entry.LeftMidHand {
					continue // a leaver did not complete the hand
				}
				settled.Players = append(settled.Players, entry.UserID)
				// Every player who completed the hand has their window opened
				// or rolled; the winner earns the WIN_HAND source of the hand
				// they won with (owner, 27 Sep 2026: "Win by Pair +1 XP … 1
				// time"), once a window.
				var sources []xpSourceRow
				if entry.IsWinner {
					sources = rules.wonWith(entry.WonWith)
				}
				award, err := awardXP(ctx, tx, rules, entry.UserID, at, sources)
				if err != nil {
					return err
				}
				if rules.on {
					settled.Windows[entry.UserID] = award.windowStart
				}
				if award.granted > 0 {
					changed = append(changed, entry.UserID)
				}
			}
			standings, err := standingsOf(ctx, tx, at, written)
			if err != nil {
				return err
			}
			result.TaxBps = make(map[string]int, len(standings))
			for userID, standing := range standings {
				result.TaxBps[userID] = standing.TaxBps
			}
			for _, userID := range changed {
				settled.Levels[userID] = standings[userID]
			}
			return nil
		})
	})
	if l.metrics != nil && l.metrics.SettlementDuration != nil {
		l.metrics.SettlementDuration.Observe(time.Since(started).Seconds())
	}
	if err != nil {
		return game.SettleResult{}, err
	}
	if l.onSettled != nil {
		l.onSettled(settled)
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
// past the balance check. A deleted account (deleted_at set) reads as no row
// (24 Sep 2026): its wallet was emptied through account_deleted, so a
// checkpoint that still found it would record a debit the zero floor then
// hid, and SUM(delta) would stop equalling chips for that account.
func lockWallet(ctx context.Context, tx pgx.Tx, userID string) (int64, error) {
	var chips int64
	err := tx.QueryRow(ctx, `SELECT chips FROM users WHERE id = $1 AND deleted_at = 0 FOR UPDATE`, userID).Scan(&chips)
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
	return appendLedgerFor(ctx, tx, userID, handID, actionID, delta, balance, reason, at, "", "")
}

// appendLedgerFor is appendLedger with the row's game family and variant
// (chip_ledger.game / .variant, V1.0.0): NULL for a Teen Patti row and for
// every non-hand row, so those rows are byte for byte what they were; the
// poker family and its variant for a poker room's checkpoint (POKER_PLAN.md
// §6).
func appendLedgerFor(ctx context.Context, tx pgx.Tx, userID, handID, actionID string, delta, balance int64, reason string, at int64, gameFamily, variant string) error {
	_, err := tx.Exec(ctx, `INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at, game, variant)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
		userID, nullIfEmpty(handID), nullIfEmpty(actionID), delta, balance, reason, at, nullIfEmpty(gameFamily), nullIfEmpty(variant))
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
