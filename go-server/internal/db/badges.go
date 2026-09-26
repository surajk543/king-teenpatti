package db

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// Badges bought in the app (owner, 27 Sep 2026: "Add a icon in Store to buy
// badges"). A badge is BUYABLE when its row names a Google Play managed
// product (badges.play_product_id); POST /api/purchases/google, after Google
// has confirmed the receipt, finds the badge by that product id
// (BadgeForProduct) and grants it for its validity (CreditBadgePurchase). As
// seeded none does: the Royal badges the store lists are asked for through
// support ("for all type of royal badges Add a button to contact support in
// store") and granted by hand — so this is the path for
// the badge an owner puts on Play, which is then a row, never code.

// BadgeProduct is a badge the store sells: the badge, the Play product it is
// bought as, its price in whole rupees (always INR — owner, 27 Sep 2026: "price
// in badges will always be in inr currency"; nil where none is set) and how
// many days a purchase lasts (0: for ever).
type BadgeProduct struct {
	Code         string
	Title        string
	ProductID    string
	PriceInr     *int
	ValidityDays int
}

// BadgeForProduct is the ACTIVE badge sold as productID, and whether there is
// one. A retired badge (is_active = FALSE) is not for sale: a receipt for it
// is refused like any unknown product.
func BadgeForProduct(ctx context.Context, d *DB, productID string) (BadgeProduct, bool, error) {
	if productID == "" {
		return BadgeProduct{}, false, nil
	}
	var b BadgeProduct
	err := d.Pool.QueryRow(ctx,
		`SELECT code, title, play_product_id, price_inr, validity_days
		   FROM badges WHERE play_product_id = $1 AND is_active`, productID).
		Scan(&b.Code, &b.Title, &b.ProductID, &b.PriceInr, &b.ValidityDays)
	if errors.Is(err, pgx.ErrNoRows) {
		return BadgeProduct{}, false, nil
	}
	if err != nil {
		return BadgeProduct{}, false, fmt.Errorf("read badge for product %s: %w", productID, err)
	}
	return b, true, nil
}

// BadgePurchaseResult is what a badge purchase did: whether this call granted
// it (false for a purchase token already banked — the badge is where the first
// call put it), the badge, when the player's grant of it now runs out (epoch
// ms, 0: never), and the account after it, its standing included.
type BadgePurchaseResult struct {
	Credited  bool
	Badge     string
	ExpiresAt int64
	User      *User
}

// CreditBadgePurchase grants the badge a verified Play purchase bought, once
// per purchase token, in ONE transaction under the player's row lock: the
// token goes into badge_purchases ON CONFLICT DO NOTHING — the replay guard —
// and only when it went in is the grant written. A grant still running is
// EXTENDED by the badge's validity rather than restarted, so a player who buys
// a 15-day badge twice holds it for thirty days; a lapsed grant, or none, starts
// now; a grant held for ever stays so. A replayed token — a retry after a lost
// reply, Play restoring it on a new install, the same token sent from another
// account — grants nothing and reports the grant its first purchase left.
// Chips never move: a badge is not chips, and chip_ledger never hears of it.
func CreditBadgePurchase(ctx context.Context, d *DB, users *Users, userID string, b BadgeProduct, purchaseToken string, nowMs int64) (BadgePurchaseResult, error) {
	if purchaseToken == "" {
		return BadgePurchaseResult{}, errors.New("db: empty purchase token")
	}
	if b.Code == "" || b.ProductID == "" {
		return BadgePurchaseResult{}, fmt.Errorf("db: badge %q is not sold as a product", b.Code)
	}
	out := BadgePurchaseResult{Badge: b.Code}
	err := d.WithTx(ctx, func(tx pgx.Tx) error {
		var id string
		if err := tx.QueryRow(ctx, `SELECT id FROM users WHERE id = $1 FOR UPDATE`, userID).Scan(&id); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return game.Errorf(game.CodeUnknownUser, "unknown user %s", userID)
			}
			return err
		}
		var current *int64
		err := tx.QueryRow(ctx, `SELECT expires_at FROM user_badges WHERE user_id = $1 AND badge_code = $2`,
			userID, b.Code).Scan(&current)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		expires := BadgeExpiry(current, b.ValidityDays, nowMs)
		tag, err := tx.Exec(ctx,
			`INSERT INTO badge_purchases (purchase_token, user_id, product_id, badge_code, price_inr, expires_at, created_at)
			 VALUES ($1, $2, $3, $4, $5, $6, $7)
			 ON CONFLICT (purchase_token) DO NOTHING`,
			purchaseToken, userID, b.ProductID, b.Code, b.PriceInr, expires, nowMs)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			// Already banked: report the grant that purchase left.
			return tx.QueryRow(ctx, `SELECT badge_code, expires_at FROM badge_purchases WHERE purchase_token = $1`,
				purchaseToken).Scan(&out.Badge, &out.ExpiresAt)
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO user_badges (user_id, badge_code, granted_at, expires_at)
			 VALUES ($1, $2, $3, $4)
			 ON CONFLICT (user_id, badge_code) DO UPDATE
			   SET granted_at = EXCLUDED.granted_at, expires_at = EXCLUDED.expires_at`,
			userID, b.Code, nowMs, expires); err != nil {
			return err
		}
		out.Credited, out.ExpiresAt = true, expires
		return nil
	})
	if err != nil {
		return BadgePurchaseResult{}, err
	}
	user, err := users.FindByID(ctx, userID)
	if err != nil {
		return BadgePurchaseResult{}, err
	}
	out.User = user
	return out, nil
}

// BadgeExpiry is when a grant runs out after a purchase of validityDays at
// nowMs, given the player's grant of that badge now (current: nil for none;
// 0 for one held for ever): for ever where the badge lasts for ever or the
// grant already does; the running grant's end plus the validity while it
// runs; otherwise now plus the validity.
func BadgeExpiry(current *int64, validityDays int, nowMs int64) int64 {
	if validityDays <= 0 || (current != nil && *current == 0) {
		return 0
	}
	from := nowMs
	if current != nil && *current > nowMs {
		from = *current
	}
	return from + int64(validityDays)*86_400_000
}
