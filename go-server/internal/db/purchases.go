package db

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/purchase"
)

// PurchaseResult is what CreditPurchase did.
type PurchaseResult struct {
	// Credited is false when this purchase token had already been banked. The
	// caller still answers the client with success — the player did buy the
	// chips, and they are in the wallet — but nothing moved this time.
	Credited bool
	// Chips is what the product is worth, whether or not this call banked it.
	Chips int64
	// Balance is the wallet after the credit, or the current wallet when the
	// purchase was already banked.
	Balance int64
	User    *User
}

// CreditPurchase adds a verified Google Play purchase to a wallet, once.
//
// The whole safety of this rests on one thing: `chip_ledger.action_id` is
// UNIQUE, and a purchase's action id is derived from the Play purchase token
// (purchase.ActionID). A client that replays a receipt — deliberately, or
// because the network dropped the first reply and it retried — collides on
// that index, the transaction rolls back, and the second call reports
// Credited=false instead of doubling the chips. This is the same mechanism
// that stops a settle retry paying a winner twice (CLAUDE.md §5.1); it is
// reused here because a paid purchase is exactly the case where crediting
// twice must be impossible.
//
// The amount comes from the server-side catalogue via the product id, never
// from the caller. The transaction:
//
//	SELECT chips FROM users WHERE id = $1 FOR UPDATE   lock the wallet
//	INSERT chip_ledger (…, action_id 'gplay:<token>')  UNIQUE → replay rolls back
//	UPDATE users SET chips = chips + $n                credit
func CreditPurchase(ctx context.Context, d *DB, users *Users, userID string, p purchase.Product, purchaseToken string) (PurchaseResult, error) {
	if purchaseToken == "" {
		return PurchaseResult{}, errors.New("db: empty purchase token")
	}
	actionID := purchase.ActionID(purchaseToken)
	now := time.Now().UnixMilli()

	var out PurchaseResult
	out.Chips = p.Chips

	err := d.WithTx(ctx, func(tx pgx.Tx) error {
		var chips int64
		if err := tx.QueryRow(ctx,
			`SELECT chips FROM users WHERE id = $1 FOR UPDATE`, userID).Scan(&chips); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return game.Errorf(game.CodeUnknownUser, "unknown user %s", userID)
			}
			return err
		}

		balance := chips + p.Chips
		if err := appendLedger(ctx, tx, userID, "", actionID,
			p.Chips, balance, game.LedgerReasonPurchase, now); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx,
			`UPDATE users SET chips = $2, updated_at = $3 WHERE id = $1`,
			userID, balance, now); err != nil {
			return err
		}
		out.Credited = true
		out.Balance = balance
		return nil
	})

	// A unique violation on action_id is not a failure: it is this purchase
	// having already been banked. Report it as such and let the caller answer
	// the player with the wallet they already have.
	if err != nil && isUniqueViolationOn(err, "action_id") {
		user, ferr := users.FindByID(ctx, userID)
		if ferr != nil {
			return PurchaseResult{}, ferr
		}
		return PurchaseResult{Credited: false, Chips: p.Chips, Balance: user.Chips, User: user}, nil
	}
	if err != nil {
		return PurchaseResult{}, err
	}

	user, err := users.FindByID(ctx, userID)
	if err != nil {
		return PurchaseResult{}, err
	}
	out.User = user
	return out, nil
}
