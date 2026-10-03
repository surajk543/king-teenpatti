package db

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// LedgerReasonCardBackgroundPurchase is chip_ledger.reason for a chip-priced
// card back (owner, 3 Oct 2026): a chip SINK, always a negative delta, its
// action_id "cardbg:<userId>:<cardBackgroundId>:<n>" — n counting that pair's
// purchases, so a lapsed rental can be bought again. The seeded card backs are
// priced in hammers and write no ledger row; this is the row a card back an
// owner re-prices in chips is bought through. Like every purchase's, never
// purged (db.purgeableReasons is the four hand checkpoints alone).
const LedgerReasonCardBackgroundPurchase = "card_background_purchase"

// CardBackground is one row of the card-back catalogue as a client sees it
// (GET /api/card-backgrounds): the back of a player's cards (owner, 3 Oct
// 2026: "Add a table cards_background which users can buy just like user can
// buy profile_pictures … add one more tab Cards in Store which user can buy …
// keep the price of all cards 5 Hammers validity 10 days"). It is Picture with
// the card's place in its picture beside the URL: the owner's art is product
// shots, the card on a dark ground at a different size and place in each, and
// Crop is the card's rectangle there, which a client draws stretched to its
// card.
//
// The default back — the owner's Royal Fox, bundled with the app — is no row
// of this catalogue: a player who has chosen nothing wears it, and the app's
// Cards shelf shows it as its first tile, owned by everyone.
type CardBackground struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
	// URL is the file's location in the private R2 bucket
	// (cards_background.asset_url), the key's spaces written %20, which a
	// phone opens through POST /api/assets/sign.
	URL string `json:"url"`
	// AssetFormat is "IMAGE", the one format a card back is drawn from
	// (game.CardBackgroundFormat; the column's CHECK allows nothing else).
	AssetFormat string `json:"assetFormat"`
	// Crop is where the card is in its picture, as fractions of the picture
	// (crop_x, crop_y, crop_w, crop_h); ABSENT when the row has none — the
	// whole picture is the card.
	Crop *game.CardCrop `json:"crop,omitempty"`
	// Currency names the wallet Cost is paid from: "COIN" (chips), "DIAMOND"
	// or "HAMMER". Always "COIN" on a free row.
	Currency string `json:"currency"`
	// Type is PictureFree or PicturePremium.
	Type string `json:"type"`
	Cost int64  `json:"cost"`
	// DurationDays and DurationHours are the rental term, added together; both
	// 0 is for ever.
	DurationDays  int `json:"durationDays"`
	DurationHours int `json:"durationHours"`
	SortOrder     int `json:"sortOrder"`
	// Owned is whether this viewer may choose it right now: every free card
	// back, plus the premium ones they have bought whose rental has not run
	// out. False everywhere for an anonymous caller but on a free row.
	Owned bool `json:"owned"`
	// ExpiresAt is when this viewer's rental runs out (epoch ms), or 0 when
	// they do not own it or own it for ever.
	ExpiresAt int64 `json:"expiresAt"`
}

// Free reports whether the card back costs nothing and needs no ownership row.
func (c CardBackground) Free() bool { return c.Type == PictureFree }

// PaidInChips reports whether buying the card back moves chips — Picture's
// rule: only a DIAMOND or HAMMER row is paid from a wallet no seat holds.
func (c CardBackground) PaidInChips() bool {
	return c.Currency != PictureCurrencyDiamond && c.Currency != PictureCurrencyHammer
}

// ErrCardBackgroundUnknown is no such card back (or an id that was never a
// number). Every other refusal a card back can meet is a profile picture's —
// ErrPictureInactive, ErrPictureUnlisted, ErrPictureFree, ErrPictureChips,
// ErrPictureDiamonds, ErrPictureHammers, ErrPictureAtTable — because the rule
// is the same one; only "which catalogue" differs, and the HTTP layer words
// that.
var ErrCardBackgroundUnknown = errors.New("db: no such card back")

// CardBackgrounds is the card-back catalogue, who owns what, and which card
// back each player has chosen: TablePictures' API one for one.
type CardBackgrounds struct {
	db    *DB
	users *Users
	clock func() time.Time
}

// NewCardBackgrounds builds the store. users is used to return the fresh
// account after a purchase or a change of card back; clock nil → time.Now.
func NewCardBackgrounds(d *DB, users *Users, clock func() time.Time) *CardBackgrounds {
	return &CardBackgrounds{db: d, users: users, clock: clock}
}

// cardBackgroundColumns is the catalogue row, aliased p.
const cardBackgroundColumns = `p.id, p.name, p.asset_url, p.asset_format, p.crop_x, p.crop_y, p.crop_w, p.crop_h, p.currency, p.type, p.cost, p.duration_days, p.duration_hours, p.sort_order`

// cardOwnedJoin resolves ownership for one viewer ($1), with the expiry
// tested in the join as ownedJoin does for profile pictures: a lapsed rental
// stops counting the instant it lapses, whether or not a sweep has run.
const cardOwnedJoin = ` LEFT JOIN user_cards_background o
                          ON o.card_background_id = p.id AND o.user_id = $1
                         AND (o.expires_at = 0 OR o.expires_at > %d) `

func (c *CardBackgrounds) ownedJoinNow() string {
	return fmt.Sprintf(cardOwnedJoin, now(c.clock))
}

// cardBackgroundShelfExpr is pictureShelfExpr for the card backs (is_listed):
// a card back is on this viewer's shelf when it is listed, or when they have
// it — an ownership row still running, or the one they have chosen. $1 is the
// viewer.
const cardBackgroundShelfExpr = `(p.is_listed OR o.user_id IS NOT NULL
         OR p.id = (SELECT c.card_background_id FROM user_cards_background_choice c WHERE c.user_id = $1))`

// cropOf is the card's rectangle from the four crop columns: set when all four
// are (the column's CHECK holds it to all four or none), nil otherwise.
func cropOf(x, y, w, h *float64) *game.CardCrop {
	if x == nil || y == nil || w == nil || h == nil {
		return nil
	}
	return &game.CardCrop{X: *x, Y: *y, W: *w, H: *h}
}

// scanCardBackground reads one row selected with cardBackgroundColumns
// followed by is_active, ownedExpr and expiryExpr — and then into extra, in
// order, any columns a caller selected after those (Buy's is_listed).
func scanCardBackground(row pgx.Row, extra ...any) (CardBackground, bool, error) {
	var cb CardBackground
	var active bool
	var x, y, w, h *float64
	err := row.Scan(append([]any{&cb.ID, &cb.Name, &cb.URL, &cb.AssetFormat, &x, &y, &w, &h, &cb.Currency, &cb.Type, &cb.Cost,
		&cb.DurationDays, &cb.DurationHours, &cb.SortOrder, &active, &cb.Owned, &cb.ExpiresAt}, extra...)...)
	cb.Crop = cropOf(x, y, w, h)
	return cb, active, err
}

// List returns every card back still on offer, in catalogue order, each
// marked with whether this player may choose it. userID may be "" for an
// unauthenticated caller, who owns the free ones and nothing else. Retired
// rows are left out; a player who has chosen one keeps it — the choice lives
// in user_cards_background_choice, not here. Unlisted rows (is_listed =
// FALSE) are left out too, except to a viewer who has one
// (cardBackgroundShelfExpr). The default back is no row and never listed
// here: the app draws it as the shelf's first tile.
func (c *CardBackgrounds) List(ctx context.Context, userID string) ([]CardBackground, error) {
	rows, err := c.db.Pool.Query(ctx,
		`SELECT `+cardBackgroundColumns+`, p.is_active, `+ownedExpr+`, `+expiryExpr+`
		   FROM cards_background p`+c.ownedJoinNow()+`
		  WHERE p.is_active AND `+cardBackgroundShelfExpr+`
		  ORDER BY p.sort_order, p.id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	// Never nil: the wire contract is {"cardBackgrounds": []} on an empty
	// catalogue, and a nil slice marshals to null.
	backs := []CardBackground{}
	for rows.Next() {
		cb, _, err := scanCardBackground(rows)
		if err != nil {
			return nil, err
		}
		backs = append(backs, cb)
	}
	return backs, rows.Err()
}

// Find is one card back by id, with this viewer's ownership resolved, whether
// or not it is still on offer — the second result says. A missing row is
// ErrCardBackgroundUnknown.
func (c *CardBackgrounds) Find(ctx context.Context, userID string, id int64) (CardBackground, bool, error) {
	cb, active, err := scanCardBackground(c.db.Pool.QueryRow(ctx,
		`SELECT `+cardBackgroundColumns+`, p.is_active, `+ownedExpr+`, `+expiryExpr+`
		   FROM cards_background p`+c.ownedJoinNow()+`
		  WHERE p.id = $2`, userID, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return CardBackground{}, false, ErrCardBackgroundUnknown
	}
	if err != nil {
		return CardBackground{}, false, err
	}
	return cb, active, nil
}

// CardBackgroundPurchase is what Buy did: PicturePurchase for a card back.
type CardBackgroundPurchase struct {
	CardBackground CardBackground
	// Charged is false when the player already owned it — success, nothing
	// spent this time.
	Charged bool
	// Spent is what left the wallet, in the card back's Currency.
	Spent int64
	// Balance is the chip balance afterwards; a diamond or hammer buy leaves
	// it as it was.
	Balance int64
	User    *User
}

// Buy unlocks a premium card back for a player, paying for it out of the
// wallet its currency names, in one transaction under the wallet lock — the
// transaction Pictures.Buy and TablePictures.Buy run, against the card-back
// tables: a COIN price is a chip_ledger row (reason card_background_purchase,
// action_id "cardbg:<user>:<id>:<n>", UNIQUE) and a wallet delta, so
// SUM(chip_ledger.delta) == users.chips still holds; a DIAMOND or HAMMER price
// — the seeded card backs' hammers, five or a Flower back's two — is a delta
// on its users column with the ownership row as its receipt, and no ledger or
// hammer_spends row. The row lock serialises double taps and the owned check
// makes the second an idempotent success; the UNIQUE action_id catches a
// replay whose first commit was acknowledged into a dropped connection. A
// rental runs from now, and a lapsed one is bought afresh.
//
// A seated player buys through BuyAtTable: their chips may only move at the
// three hand checkpoints (CLAUDE.md §5.1).
func (c *CardBackgrounds) Buy(ctx context.Context, userID string, id int64) (*CardBackgroundPurchase, error) {
	return c.buy(ctx, userID, id, false)
}

// BuyAtTable is Buy for a seated player: a DIAMOND or HAMMER card back sells
// as in the lobby — no seat holds either count — and a COIN one is refused
// with ErrPictureAtTable, decided inside the transaction from the row about to
// be charged.
func (c *CardBackgrounds) BuyAtTable(ctx context.Context, userID string, id int64) (*CardBackgroundPurchase, error) {
	return c.buy(ctx, userID, id, true)
}

func (c *CardBackgrounds) buy(ctx context.Context, userID string, id int64, atTable bool) (*CardBackgroundPurchase, error) {
	stamp := now(c.clock)
	out := &CardBackgroundPurchase{}

	err := c.db.WithTx(ctx, func(tx pgx.Tx) error {
		var chips, diamond, hammer int64
		if err := tx.QueryRow(ctx,
			`SELECT chips, diamond, hammer FROM users WHERE id = $1 AND deleted_at = 0 FOR UPDATE`, userID).Scan(&chips, &diamond, &hammer); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return game.Errorf(game.CodeUnknownUser, "unknown user %s", userID)
			}
			return err
		}

		// The catalogue and the ownership row, read inside the wallet lock so
		// "do they already own it" cannot change between the check and the
		// charge.
		var listed bool
		cb, active, err := scanCardBackground(tx.QueryRow(ctx,
			`SELECT `+cardBackgroundColumns+`, p.is_active, `+ownedExpr+`, `+expiryExpr+`, p.is_listed
			   FROM cards_background p`+c.ownedJoinNow()+`
			  WHERE p.id = $2`, userID, id), &listed)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrCardBackgroundUnknown
		}
		if err != nil {
			return err
		}

		out.CardBackground = cb
		switch {
		case !active:
			return ErrPictureInactive
		case cb.Free():
			return ErrPictureFree
		case cb.Owned:
			// Already theirs: idempotent success, before the shelf test, as
			// Pictures.buy has it.
			out.Charged, out.Spent, out.Balance = false, 0, chips
			return nil
		case !listed:
			return ErrPictureUnlisted
		case atTable && cb.PaidInChips():
			return ErrPictureAtTable
		}
		switch cb.Currency {
		case PictureCurrencyDiamond:
			if diamond < cb.Cost {
				return ErrPictureDiamonds
			}
		case PictureCurrencyHammer:
			if hammer < cb.Cost {
				return &PictureHammerShortage{Cost: cb.Cost}
			}
		default:
			if chips < cb.Cost {
				return ErrPictureChips
			}
		}

		// Purchases so far, read without the expiry filter, so a renewal's
		// action id never repeats the first purchase's (Pictures.buy says why).
		var priorPurchases int
		if err := tx.QueryRow(ctx,
			`SELECT COALESCE(max(purchases), 0) FROM user_cards_background
			  WHERE user_id = $1 AND card_background_id = $2`,
			userID, id).Scan(&priorPurchases); err != nil {
			return err
		}

		balance := chips
		switch cb.Currency {
		case PictureCurrencyDiamond:
			if _, err := tx.Exec(ctx,
				`UPDATE users SET diamond = diamond - $2, updated_at = $3 WHERE id = $1`,
				userID, cb.Cost, stamp); err != nil {
				return err
			}
		case PictureCurrencyHammer:
			// A delta under the wallet lock, so a Force Sideshow's hammer
			// taken at the same moment is never written over, and no
			// hammer_spends row — that table is one row per Force Sideshow.
			if _, err := tx.Exec(ctx,
				`UPDATE users SET hammer = hammer - $2, updated_at = $3 WHERE id = $1`,
				userID, cb.Cost, stamp); err != nil {
				return err
			}
		default:
			balance = chips - cb.Cost
			actionID := fmt.Sprintf("cardbg:%s:%d:%d", userID, id, priorPurchases+1)
			if err := appendLedger(ctx, tx, userID, "", actionID,
				-cb.Cost, balance, LedgerReasonCardBackgroundPurchase, stamp); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx,
				`UPDATE users SET chips = $2, updated_at = $3 WHERE id = $1`, userID, balance, stamp); err != nil {
				return err
			}
		}

		// A rental runs from now, not from what was left of a lapsed one.
		var expiresAt int64
		if term := int64(cb.DurationDays)*DayMs + int64(cb.DurationHours)*HourMs; term > 0 {
			expiresAt = stamp + term
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO user_cards_background (user_id, card_background_id, acquired_at, expires_at, purchases)
			 VALUES ($1, $2, $3, $4, 1)
			 ON CONFLICT (user_id, card_background_id) DO UPDATE
			    SET acquired_at = EXCLUDED.acquired_at,
			        expires_at  = EXCLUDED.expires_at,
			        purchases   = user_cards_background.purchases + 1`,
			userID, id, stamp, expiresAt); err != nil {
			return err
		}

		out.CardBackground.Owned = true
		out.CardBackground.ExpiresAt = expiresAt
		out.Charged, out.Spent, out.Balance = true, cb.Cost, balance
		return nil
	})

	// A replay whose first commit landed but whose answer was lost: the money
	// moved and the card back is theirs, so this is the success it is.
	if err != nil && isUniqueViolationOn(err, "action_id") {
		user, ferr := c.users.FindByID(ctx, userID)
		if ferr != nil {
			return nil, ferr
		}
		cb, _, ferr := c.Find(ctx, userID, id)
		if ferr != nil {
			return nil, ferr
		}
		return &CardBackgroundPurchase{CardBackground: cb, Charged: false, Balance: user.Chips, User: user}, nil
	}
	if err != nil {
		return nil, err
	}

	user, err := c.users.FindByID(ctx, userID)
	if err != nil {
		return nil, err
	}
	out.User = user
	return out, nil
}

// Use puts a card back on the player's cards (or, with nil, takes it off and
// leaves the default back) and returns the fresh user, whose CardBackground
// now carries what to draw.
//
// Like Users.SetActivePicture it does NOT check ownership — the caller does,
// so the refusal reaches the client as a sentence — and the foreign key is the
// backstop against an id that is not in the catalogue. Choosing one moves no
// wallet, so a seated player may change it: the caller puts it on their seat
// (RoomManager.SetPlayerCardBackground) for everyone at the table to see.
func (c *CardBackgrounds) Use(ctx context.Context, userID string, id *int64) (*User, error) {
	var err error
	if id == nil {
		_, err = c.db.Pool.Exec(ctx, `DELETE FROM user_cards_background_choice WHERE user_id = $1`, userID)
	} else {
		_, err = c.db.Pool.Exec(ctx,
			`INSERT INTO user_cards_background_choice (user_id, card_background_id, chosen_at) VALUES ($1, $2, $3)
			 ON CONFLICT (user_id) DO UPDATE SET card_background_id = EXCLUDED.card_background_id, chosen_at = EXCLUDED.chosen_at`,
			userID, *id, now(c.clock))
	}
	if err != nil {
		return nil, err
	}
	return c.users.FindByID(ctx, userID)
}

// ExpireLapsed takes off a chosen card back whose rental has run out, and
// reports whether it had to — TablePictures.ExpireLapsed for the cards.
// Ownership itself needs no sweep: every read tests the expiry, the account's
// included, so a lapsed card back reads as the default back the instant it
// lapses. What does need one is the choice row, and the copy on the
// player's seat: the row is deleted here — a renewal then starts on the
// default back until the player chooses again — and the caller tells the
// seat when it had to (RoomManager.SetPlayerCardBackground with nil). The
// seat's copy carries the rental's ExpiresAt (the account's cardBackground
// does), and its table takes it off at that moment by itself (owner, 3 Oct
// 2026: "when validity of premium card expires, it restores default card"),
// so the word to the seat is for a copy that says otherwise: one restored
// from a snapshot written before card backs carried their expiry, or a
// rental ended early by hand. Called where the other sweeps are: at login,
// on /api/auth/me, and when this catalogue is listed. Free card backs are
// never touched.
func (c *CardBackgrounds) ExpireLapsed(ctx context.Context, userID string) (bool, error) {
	tag, err := c.db.Pool.Exec(ctx, `
		DELETE FROM user_cards_background_choice c
		 WHERE c.user_id = $1
		   AND EXISTS (
		       SELECT 1 FROM cards_background p
		        WHERE p.id = c.card_background_id AND p.type = 'PREMIUM')
		   AND NOT EXISTS (
		       SELECT 1 FROM user_cards_background o
		        WHERE o.user_id = c.user_id
		          AND o.card_background_id = c.card_background_id
		          AND (o.expires_at = 0 OR o.expires_at > $2))`,
		userID, now(c.clock))
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}
