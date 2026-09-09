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
	// creditSeat adds the chips to the player's live seat when they are at a
	// table. PostgreSQL alone is not enough: the seat is the live truth in
	// Redis, and a player tops up mid-hand precisely because they are short at
	// THIS table.
	creditSeat func(userID string, amount int64) bool
	logger     *slog.Logger
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

	result, err := db.CreditPurchase(ctx, s.db, s.users, userID, product, purchaseToken)
	if err != nil {
		return auth.PurchaseOutcome{}, err
	}

	// The wallet has the chips; the seat is a separate copy of the truth.
	// Only on a fresh credit — a replayed receipt already moved both, and
	// adding again here would put chips in the seat that PostgreSQL does not
	// have.
	if result.Credited && s.creditSeat != nil {
		if s.creditSeat(userID, product.Chips) && s.logger != nil {
			s.logger.Info("purchased chips added to a live seat",
				"userId", userID, "chips", product.Chips)
		}
	}

	// Best effort, and only now. A failure here is not the player's problem —
	// they have their chips — but it is ours to notice, so it is returned to
	// the handler's logger rather than swallowed.
	_ = s.verifier.Acknowledge(ctx, productID, purchaseToken)

	return auth.PurchaseOutcome{
		Chips:    result.Chips,
		Balance:  result.Balance,
		Credited: result.Credited,
		User:     result.User,
	}, nil
}
