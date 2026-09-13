package db

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/metrics"
)

// Hammers is the PostgreSQL game.HammerWallet: users.hammer, charged one
// hammer per Force Sideshow (owner, 13 Sep 2026).
//
// It is kept apart from Ledger on purpose. The Ledger is the chips and the
// three checkpoints of the money model (CLAUDE.md §5.1); hammers are not chips,
// a spend writes nothing to chip_ledger, and a seated player's chips are no
// more able to move because of one.
type Hammers struct {
	db      *DB
	metrics *metrics.Metrics // may be nil (tests)
	clock   func() time.Time
}

// NewHammers builds the wallet. m may be nil (no observations); clock nil →
// time.Now.
func NewHammers(d *DB, m *metrics.Metrics, clock func() time.Time) *Hammers {
	return &Hammers{db: d, metrics: m, clock: clock}
}

var _ game.HammerWallet = (*Hammers)(nil)

// SpendHammer implements game.HammerWallet, in one transaction:
//
//	SELECT hammer FROM users WHERE id = $1 FOR UPDATE              lock the wallet (no row → unknown_user)
//	INSERT INTO hammer_spends (action_id, …) ON CONFLICT DO NOTHING
//	  nothing inserted → this key was already paid for: charge nothing, succeed
//	hammer < cost → no_hammers, and the rollback takes the insert back out
//	UPDATE users SET hammer = hammer - cost RETURNING hammer
//
// The insert comes before the balance check so that a retry of a spend that
// committed — its answer lost on the way back — succeeds even when that spend
// took the player's last hammer: it has already been paid for. The wallet row
// is locked first, so two spends by one player queue, and the CHECK on
// users.hammer is the last line against going below zero.
//
// Every error leaves as a *game.GameError: no_hammers as it is, anything else
// through Classify (persist_failed with the driver error as Cause), which the
// Table refuses the move with. A shortage is a refusal, not a failure, so it is
// not counted in game_db_transaction_errors_total.
func (h *Hammers) SpendHammer(ctx context.Context, req game.HammerSpend) (game.HammerSpendResult, error) {
	if req.UserID == "" || req.ActionID == "" {
		return game.HammerSpendResult{}, game.Errorf(game.CodePersistFailed, "hammer spend needs a user and a key")
	}
	started := time.Now()
	var out game.HammerSpendResult
	err := h.db.WithTx(ctx, func(tx pgx.Tx) error {
		at := now(h.clock)
		var hammer int64
		if err := tx.QueryRow(ctx,
			`SELECT hammer FROM users WHERE id = $1 AND deleted_at = 0 FOR UPDATE`, req.UserID).Scan(&hammer); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return game.Errorf(game.CodeUnknownUser, "unknown user %s", req.UserID)
			}
			return err
		}
		tag, err := tx.Exec(ctx,
			`INSERT INTO hammer_spends (action_id, user_id, hand_id, created_at)
			 VALUES ($1, $2, $3, $4)
			 ON CONFLICT (action_id) DO NOTHING`,
			req.ActionID, req.UserID, req.HandID, at)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			out = game.HammerSpendResult{Remaining: hammer, Charged: false}
			return nil
		}
		if hammer < game.ForceSideshowCost {
			return game.NewGameError(game.CodeNoHammers, game.MsgNoHammers)
		}
		var remaining int64
		if err := tx.QueryRow(ctx,
			`UPDATE users SET hammer = hammer - $2, updated_at = $3 WHERE id = $1 RETURNING hammer`,
			req.UserID, game.ForceSideshowCost, at).Scan(&remaining); err != nil {
			return err
		}
		out = game.HammerSpendResult{Remaining: remaining, Charged: true}
		return nil
	})

	if h.metrics != nil && h.metrics.DBTransactionDuration != nil {
		h.metrics.DBTransactionDuration.WithLabelValues(metrics.OpHammerSpend).Observe(time.Since(started).Seconds())
	}
	if err == nil {
		return out, nil
	}
	refusal := Classify(err)
	if refusal.Code != game.CodeNoHammers && h.metrics != nil && h.metrics.DBTransactionErrors != nil {
		code := metrics.SafeLabel(refusal.Code, game.KnownLedgerCodes, metrics.OtherLabel)
		h.metrics.DBTransactionErrors.WithLabelValues(metrics.OpHammerSpend, code).Inc()
	}
	return game.HammerSpendResult{}, refusal
}
