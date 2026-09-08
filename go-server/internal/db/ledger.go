package db

import (
	"context"
	"encoding/json"
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

// Bet implements game.Ledger — see the interface doc for the exact statement
// sequence. SQL (verbatim from ledger.js, table names unqualified — the
// connection's search_path resolves them):
//
//	SELECT chips FROM users WHERE id = $1 FOR UPDATE
//	UPDATE users SET chips = $1, updated_at = $2 WHERE id = $3
//	UPDATE pots SET amount = amount + $1 WHERE hand_id = $2         (rowCount 0 → no_pot)
//	INSERT INTO chip_ledger (user_id, hand_id, action_id, delta, balance, reason, created_at) VALUES (…)
//
// Amount ≤ 0 → invalid_amount before BEGIN. Returns {balance, persisted: amount}.
//
// The game_states upsert that used to close this transaction (Node's
// stale_state guard) is gone: the table snapshot now lives in the live store
// (LIVE_STATE_PLAN.md), saved by the table actor AFTER the money has
// committed, and the two-owners guard is the store's per-table sequence
// (live.ErrStale). A money transaction touches only users, pots and
// chip_ledger.
func (l *Ledger) Bet(ctx context.Context, req game.BetRequest) (game.BetResult, error) {
	var result game.BetResult
	err := l.transact(metrics.OpBet, func() error {
		// Defence in depth: the Table has already matched the amount against
		// the ladder. Checked before any transaction is opened, as Node does.
		if req.Amount <= 0 {
			return game.NewGameError(game.CodeInvalidAmount, "bet amount must be a positive integer")
		}
		reason := req.Reason
		if reason == "" {
			reason = game.LedgerReasonBet // Node: `reason = 'bet'` default parameter
		}

		return l.db.WithTx(ctx, func(tx pgx.Tx) error {
			at := now(l.clock)

			chips, err := lockWallet(ctx, tx, req.UserID)
			if err != nil {
				return err
			}
			if chips < req.Amount {
				return game.Errorf(game.CodeInsufficientChips, "insufficient chips for %s", req.UserID)
			}
			balance := chips - req.Amount

			// The wallet is debited FIRST so a duplicate action id or a stale
			// state below rolls the debit back with everything else.
			if _, err := tx.Exec(ctx, `UPDATE users SET chips = $1, updated_at = $2 WHERE id = $3`, balance, at, req.UserID); err != nil {
				return err
			}

			pot, err := tx.Exec(ctx, `UPDATE pots SET amount = amount + $1 WHERE hand_id = $2`, req.Amount, req.HandID)
			if err != nil {
				return err
			}
			if pot.RowsAffected() == 0 {
				return game.Errorf(game.CodeNoPot, "no open pot for hand %s", req.HandID)
			}

			if err := appendLedger(ctx, tx, req.UserID, req.HandID, req.ActionID, -req.Amount, balance, reason, at); err != nil {
				return err
			}

			// `persisted` tells the table how much of this stake the account
			// has already been debited — here, all of it — so settlement knows
			// the only movement left is the payout.
			result = game.BetResult{Balance: balance, Persisted: req.Amount}
			return nil
		})
	})
	if err != nil {
		return game.BetResult{}, err
	}
	return result, nil
}

// CollectBoot implements game.Ledger. Entries are sorted by UserID ascending
// before any lock. insufficient_chips carries UserID. Pot row:
//
//	INSERT INTO pots (hand_id, room_id, boot_amount, amount, opened_at) VALUES ($1,$2,$3,$4,$5)
//
// with amount = Σ entry.Amount. One ledger row per entry (action_id
// game.BootActionID). Returns {balances, persisted: bootAmount}. No state
// write (see Bet).
func (l *Ledger) CollectBoot(ctx context.Context, req game.CollectBootRequest) (game.CollectBootResult, error) {
	var result game.CollectBootResult
	started := time.Now()
	err := l.transact(metrics.OpBoot, func() error {
		return l.db.WithTx(ctx, func(tx pgx.Tx) error {
			at := now(l.clock)

			// All wallet rows are locked in a fixed order (by user id) so two
			// tables that happen to share a player cannot deadlock against
			// each other (DECISIONS.md §2: byte-wise ascending).
			ordered := make([]game.BootEntry, len(req.Entries))
			copy(ordered, req.Entries)
			sort.SliceStable(ordered, func(i, j int) bool { return ordered[i].UserID < ordered[j].UserID })

			balances := make(map[string]int64, len(ordered))
			var total int64
			for _, entry := range ordered {
				chips, err := lockWallet(ctx, tx, entry.UserID)
				if err != nil {
					return err
				}
				if chips < entry.Amount {
					// The seat that could not cover the boot is named so
					// _startRefused can show that player out rather than retry
					// the start every NextHandDelay forever.
					return &game.GameError{
						Code:    game.CodeInsufficientChips,
						Message: "insufficient chips for " + entry.UserID,
						UserID:  entry.UserID,
					}
				}
				balances[entry.UserID] = chips - entry.Amount
				if _, err := tx.Exec(ctx, `UPDATE users SET chips = $1, updated_at = $2 WHERE id = $3`, balances[entry.UserID], at, entry.UserID); err != nil {
					return err
				}
				total += entry.Amount
			}

			if _, err := tx.Exec(ctx, `INSERT INTO pots (hand_id, room_id, boot_amount, amount, opened_at)
         VALUES ($1, $2, $3, $4, $5)`, req.HandID, req.RoomID, req.BootAmount, total, at); err != nil {
				return err
			}

			for _, entry := range ordered {
				// Deterministic, so a retried start cannot ante the same
				// player twice.
				if err := appendLedger(ctx, tx, entry.UserID, req.HandID, game.BootActionID(req.HandID, entry.UserID),
					-entry.Amount, balances[entry.UserID], game.LedgerReasonBoot, at); err != nil {
					return err
				}
			}

			result = game.CollectBootResult{Balances: balances, Persisted: req.BootAmount}
			return nil
		})
	})
	// The boot transaction is what a hand start costs, so the same span feeds
	// both the ledger histogram and the hand-start one.
	if l.metrics != nil && l.metrics.HandStartDuration != nil {
		l.metrics.HandStartDuration.Observe(time.Since(started).Seconds())
	}
	if err != nil {
		return game.CollectBootResult{}, err
	}
	return result, nil
}

// Settle implements game.Ledger. Statements:
//
//	-- per entry, userId ascending:
//	SELECT chips FROM users WHERE id = $1 FOR UPDATE                (no row → skip the entry)
//	UPDATE users SET chips=$1, hands_played=hands_played+$2, hands_won=hands_won+$3, hands_lost=hands_lost+$4,
//	       hands_left_mid=hands_left_mid+$5, total_winnings=total_winnings+$6, biggest_pot=GREATEST(biggest_pot,$7),
//	       updated_at=$8 WHERE id=$9
//	INSERT INTO chip_ledger (…) -- action_id game.SettleActionID, reason hand_win|hand_loss, delta may be 0
//	INSERT INTO hands (id, room_id, hand_no, pot, winner_id, win_reason, boot_amount, started_at, ended_at, summary_json)
//	  VALUES ($1,…,$10::jsonb) ON CONFLICT (id) DO NOTHING
//	UPDATE pots SET closed_at = $1, winner_id = $2 WHERE hand_id = $3
//
// balance = max(0, chips + delta). summary_json is json.Marshal(hand.Summary)
// ([] when empty, never null). No state write (see Bet); the retry path
// (Table.retrySettle) resends exactly this request.
//
// Deviation from ledger.js, which inserted the hands row FIRST: hands.winner_id
// is a foreign key, so that insert takes a KEY SHARE lock on the winner's
// users row before any wallet has been locked in ascending order — and a
// CollectBoot on another table holding a lower wallet and wanting the
// winner's deadlocks against it (review_money_test.go). Every wallet lock now
// comes first, in order, and the FK lock lands on a row this transaction
// already holds. The rows written are identical.
func (l *Ledger) Settle(ctx context.Context, req game.SettleRequest) (game.SettleResult, error) {
	var result game.SettleResult
	started := time.Now()
	err := l.transact(metrics.OpSettle, func() error {
		return l.db.WithTx(ctx, func(tx pgx.Tx) error {
			at := now(l.clock)
			hand := req.Hand

			summary := hand.Summary
			if summary == nil {
				summary = []game.HandSummaryEntry{} // Node: JSON.stringify(hand.summary ?? [])
			}
			summaryJSON, err := json.Marshal(summary)
			if err != nil {
				return err
			}
			var winReason *string
			if hand.WinReason != "" {
				s := string(hand.WinReason)
				winReason = &s
			}

			balances := make(game.SettleResult, len(req.Entries))
			ordered := make([]game.SettleEntry, len(req.Entries))
			copy(ordered, req.Entries)
			sort.SliceStable(ordered, func(i, j int) bool { return ordered[i].UserID < ordered[j].UserID })

			for _, entry := range ordered {
				chips, err := lockWallet(ctx, tx, entry.UserID)
				if err != nil {
					if game.CodeOf(err, "") == game.CodeUnknownUser {
						continue // the account is gone: no row, no balance (Node `continue`)
					}
					return err
				}

				// Never below zero: a delta here is a payout or a correction,
				// and the wallet CHECK would reject an overdraft anyway.
				balance := chips + entry.Delta
				if balance < 0 {
					balance = 0
				}

				// "Played" means the player committed chips beyond the boot —
				// posting the ante and folding straight away is not a hand
				// played (requirement 16).
				played := boolToInt(entry.DidChaal)
				left := boolToInt(entry.LeftMidHand)
				lost := boolToInt(!entry.IsWinner && !entry.LeftMidHand)
				won := boolToInt(entry.IsWinner)
				var gross int64
				if entry.IsWinner {
					gross = hand.Pot
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
					return err
				}

				// A zero delta is still recorded: the row is what says this
				// player was in the hand and how it ended for them.
				reason := game.LedgerReasonHandLoss
				if entry.IsWinner {
					reason = game.LedgerReasonHandWin
				}
				if err := appendLedger(ctx, tx, entry.UserID, hand.ID, game.SettleActionID(hand.ID, entry.UserID),
					entry.Delta, balance, reason, at); err != nil {
					return err
				}

				balances[entry.UserID] = balance
			}

			// The hand record goes in once every wallet is held (see the
			// deviation note above): its winner_id foreign key locks the
			// winner's users row, which this transaction now already owns.
			if _, err := tx.Exec(ctx, `INSERT INTO hands (id, room_id, hand_no, pot, winner_id, win_reason,
                            boot_amount, started_at, ended_at, summary_json)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb)
         ON CONFLICT (id) DO NOTHING`,
				hand.ID, hand.RoomID, hand.HandNo, hand.Pot, hand.WinnerID, winReason,
				hand.BootAmount, hand.StartedAt, hand.EndedAt, string(summaryJSON)); err != nil {
				return err
			}

			// No rowCount check: a hand settled without a pot row (tests) is
			// tolerated, as in Node.
			if _, err := tx.Exec(ctx, `UPDATE pots SET closed_at = $1, winner_id = $2 WHERE hand_id = $3`, at, hand.WinnerID, hand.ID); err != nil {
				return err
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
