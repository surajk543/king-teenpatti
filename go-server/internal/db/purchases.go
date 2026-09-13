package db

import (
	"context"
	"errors"
	"fmt"
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
	// Diamonds is what a diamond pack is worth, whether or not this call
	// banked it. Zero for any other pack.
	Diamonds int64
	// Hammers is what a hammer pack is worth, whether or not this call banked
	// it. Zero for any other pack.
	Hammers int64
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

// CreditDiamondPurchase adds a verified Google Play diamond pack to a player's
// diamonds, once.
//
// Diamonds are not chips and never touch chip_ledger — that table backs the
// `SUM(delta) == chips` invariant and nothing else — so the replay guard is a
// table of its own: diamond_purchases, whose primary key is the Play purchase
// token. The transaction:
//
//	SELECT diamond FROM users WHERE id = $1 FOR UPDATE      lock the wallet
//	INSERT diamond_purchases (token, …) ON CONFLICT DO NOTHING
//	UPDATE users SET diamond = diamond + $n                  only when the insert took
//
// A replayed receipt — a retry after a lost reply, Play restoring it on a new
// install, or the same token sent from another account — finds its token
// already there, inserts nothing, and reports Credited=false with the wallet
// untouched. The count comes from the server-side catalogue, never the caller.
func CreditDiamondPurchase(ctx context.Context, d *DB, users *Users, userID string, p purchase.Product, purchaseToken string) (PurchaseResult, error) {
	if p.Diamonds <= 0 {
		return PurchaseResult{}, fmt.Errorf("db: product %s grants no diamonds", p.ID)
	}
	out := PurchaseResult{Diamonds: p.Diamonds}
	if err := creditSoftPack(ctx, d, users, userID, p.ID, p.Diamonds, purchaseToken, diamondPack, &out); err != nil {
		return PurchaseResult{}, err
	}
	return out, nil
}

// CreditHammerPurchase adds a verified Google Play hammer pack to a player's
// hammers, once (owner, 13 Sep 2026) — CreditDiamondPurchase's twin, with
// hammer_purchases as the replay guard:
//
//	SELECT hammer FROM users WHERE id = $1 FOR UPDATE       lock the wallet
//	INSERT hammer_purchases (token, …) ON CONFLICT DO NOTHING
//	UPDATE users SET hammer = hammer + $n                    only when the insert took
//
// Hammers are not chips: no chip_ledger row, no seat to top up (a table never
// holds a hammer count), and so no seat lock either — a pack bought at a table
// lands in the wallet the next Force Sideshow is charged to.
func CreditHammerPurchase(ctx context.Context, d *DB, users *Users, userID string, p purchase.Product, purchaseToken string) (PurchaseResult, error) {
	if p.Hammers <= 0 {
		return PurchaseResult{}, fmt.Errorf("db: product %s grants no hammers", p.ID)
	}
	out := PurchaseResult{Hammers: p.Hammers}
	if err := creditSoftPack(ctx, d, users, userID, p.ID, p.Hammers, purchaseToken, hammerPack, &out); err != nil {
		return PurchaseResult{}, err
	}
	return out, nil
}

// softPack is the SQL that banks a pack of a currency outside chip_ledger:
// lock the wallet, record the purchase token (the replay guard), credit.
// Fixed statements per currency, never assembled from input.
type softPack struct {
	lock   string // $1 user id
	record string // $1 token, $2 user id, $3 product id, $4 count, $5 now — ON CONFLICT DO NOTHING
	credit string // $1 user id, $2 count, $3 now
}

var (
	diamondPack = softPack{
		lock: `SELECT diamond FROM users WHERE id = $1 FOR UPDATE`,
		record: `INSERT INTO diamond_purchases (purchase_token, user_id, product_id, diamonds, created_at)
		 VALUES ($1, $2, $3, $4, $5)
		 ON CONFLICT (purchase_token) DO NOTHING`,
		credit: `UPDATE users SET diamond = diamond + $2, updated_at = $3 WHERE id = $1`,
	}
	hammerPack = softPack{
		lock: `SELECT hammer FROM users WHERE id = $1 FOR UPDATE`,
		record: `INSERT INTO hammer_purchases (purchase_token, user_id, product_id, hammers, created_at)
		 VALUES ($1, $2, $3, $4, $5)
		 ON CONFLICT (purchase_token) DO NOTHING`,
		credit: `UPDATE users SET hammer = hammer + $2, updated_at = $3 WHERE id = $1`,
	}
)

// creditSoftPack banks count of a pack's currency once per purchase token and
// fills out's Credited, User and Balance (the chip balance, which a soft pack
// leaves as it was). A replayed token — a retry after a lost reply, Play
// restoring it on a new install, or the same token sent from another account —
// finds its record already there, inserts nothing, and leaves Credited false
// with the wallet untouched. The count comes from the server-side catalogue,
// never the caller.
func creditSoftPack(ctx context.Context, d *DB, users *Users, userID, productID string, count int64, purchaseToken string, pack softPack, out *PurchaseResult) error {
	if purchaseToken == "" {
		return errors.New("db: empty purchase token")
	}
	now := time.Now().UnixMilli()
	err := d.WithTx(ctx, func(tx pgx.Tx) error {
		var held int64
		if err := tx.QueryRow(ctx, pack.lock, userID).Scan(&held); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return game.Errorf(game.CodeUnknownUser, "unknown user %s", userID)
			}
			return err
		}
		tag, err := tx.Exec(ctx, pack.record, purchaseToken, userID, productID, count, now)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			// Already banked: the currency is where the first call put it.
			return nil
		}
		if _, err := tx.Exec(ctx, pack.credit, userID, count, now); err != nil {
			return err
		}
		out.Credited = true
		return nil
	})
	if err != nil {
		*out = PurchaseResult{}
		return err
	}
	user, err := users.FindByID(ctx, userID)
	if err != nil {
		*out = PurchaseResult{}
		return err
	}
	out.User = user
	out.Balance = user.Chips
	return nil
}
