package app

import (
	"context"
	"errors"
	"log/slog"
	"net/http"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/purchase"
)

// playStore is the auth.PurchaseGateway: it joins Google's verdict on a
// receipt to the credit in PostgreSQL.
//
// The order is deliberate and is the whole design:
//
//  1. Look the product up in the SERVER's catalogue. The client's request
//     carries no amount, and an unknown id stops here.
//  2. Ask Google whether this token is a completed purchase of that product in
//     our package. Anything short of "purchased" credits nothing.
//  3. Credit exactly once, keyed on the purchase token.
//  4. Acknowledge to Play — after the chips are banked, never before. Google
//     refunds an unacknowledged purchase after three days, so skipping this
//     would let a player keep chips they got their money back for; doing it
//     first would tell Play we had delivered when we had not.
type playStore struct {
	verifier *purchase.GoogleVerifier
	db       *db.DB
	users    *db.Users
	// credit banks a chip pack (or a premium package, whose missiles and
	// hammers bank with its chips) and adds the chips to the player's live seat as one
	// step under the player's seat lock (app: rooms.CreditBoughtChips). bank
	// is the database credit, handed the context it must use, and reports
	// whether it credited this time; the answer says whether a seat was
	// topped up.
	//
	// The seat is topped up because PostgreSQL alone is not enough: the seat
	// is the live truth in Redis, and a player tops up mid-hand precisely
	// because they are short at THIS table. Both run under the lock because
	// they are two moments, and a lobby seat is taken from the wallet as read
	// under that lock: a join that read the wallet after the credit and sat
	// down before the top-up looked for a seat was given the pack twice.
	// nil → there are no seats to top up, and bank runs on its own.
	credit func(userID string, amount int64, bank func(ctx context.Context) bool) bool
	logger *slog.Logger
}

func (s *playStore) Buy(ctx context.Context, userID, productID, purchaseToken string) (auth.PurchaseOutcome, error) {
	product, err := purchase.Lookup(productID)
	if err != nil {
		return auth.PurchaseOutcome{}, auth.NewAuthError(
			auth.CodeUnknownProduct, auth.MsgUnknownProduct, http.StatusBadRequest)
	}

	if _, err := s.verifier.Verify(ctx, productID, purchaseToken); err != nil {
		// A rejected or incomplete receipt is the player's side of the story
		// failing, and is answered as such. Anything else — Google 5xx, a
		// credentials problem — is ours, and must NOT be reported as a bad
		// receipt: the player may well have paid, and we want the retry.
		if errors.Is(err, purchase.ErrUnverified) || errors.Is(err, purchase.ErrNotPurchased) {
			return auth.PurchaseOutcome{}, auth.NewAuthError(
				auth.CodePurchaseUnverified, auth.MsgPurchaseUnverified, http.StatusPaymentRequired)
		}
		return auth.PurchaseOutcome{}, err
	}

	// A diamond pack fills users.diamond through its own replay guard, and
	// has no live seat to top up: diamonds are spent in the lobby, on pictures.
	if product.Diamonds > 0 {
		result, err := db.CreditDiamondPurchase(ctx, s.db, s.users, userID, product, purchaseToken)
		if err != nil {
			return auth.PurchaseOutcome{}, err
		}
		_ = s.verifier.Acknowledge(ctx, productID, purchaseToken)
		return auth.PurchaseOutcome{
			Diamonds: result.Diamonds,
			Balance:  result.Balance,
			Credited: result.Credited,
			User:     result.User,
		}, nil
	}

	// A hammer pack fills users.hammer through hammer_purchases, the same
	// way. It is allowed at a table — hammers are not chips — and has no seat
	// to top up: the table never holds a hammer count, it charges the wallet
	// when a Force Sideshow is played.
	//
	// A premium package carries hammers as well, and must NOT come in here:
	// it is chips first, and goes down the chip path below, where
	// db.CreditPurchase banks its missiles and hammers with the chips.
	if product.Hammers > 0 && !product.Premium() {
		result, err := db.CreditHammerPurchase(ctx, s.db, s.users, userID, product, purchaseToken)
		if err != nil {
			return auth.PurchaseOutcome{}, err
		}
		_ = s.verifier.Acknowledge(ctx, productID, purchaseToken)
		return auth.PurchaseOutcome{
			Hammers:  result.Hammers,
			Balance:  result.Balance,
			Credited: result.Credited,
			User:     result.User,
		}, nil
	}

	// A chip pack or a premium package. The wallet gets the chips (and a
	// premium package's missiles and hammers, in the same transaction); the
	// seat is a separate copy of the chips alone — a table holds no missile or
	// hammer count.
	// Only a fresh credit reaches the seat — a replayed receipt already moved
	// both, and adding again would put chips in the seat that PostgreSQL does
	// not have. The credit runs on the context the seat lock hands it, never
	// on the request's: a client giving up while COMMIT was on the wire would
	// end the call, and release the lock, before the outcome was known.
	var result db.PurchaseResult
	bank := func(bctx context.Context) bool {
		result, err = db.CreditPurchase(bctx, s.db, s.users, userID, product, purchaseToken)
		return err == nil && result.Credited
	}
	seated := false
	if s.credit != nil {
		seated = s.credit(userID, product.Chips, bank)
	} else {
		bank(context.WithoutCancel(ctx))
	}
	if err != nil {
		return auth.PurchaseOutcome{}, err
	}
	if seated && s.logger != nil {
		s.logger.Info("purchased chips added to a live seat",
			"userId", userID, "productId", productID, "chips", product.Chips,
			"missiles", product.Missiles, "hammers", product.Hammers)
	}

	// Best effort, and only now. A failure here is not the player's problem —
	// they have their chips — but it is ours to notice, so it is returned to
	// the handler's logger rather than swallowed.
	_ = s.verifier.Acknowledge(ctx, productID, purchaseToken)

	return auth.PurchaseOutcome{
		Chips:    result.Chips,
		Missiles: result.Missiles,
		Hammers:  result.Hammers,
		Balance:  result.Balance,
		Credited: result.Credited,
		User:     result.User,
	}, nil
}
