package db

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// TablePicture is one row of the table-picture catalogue as a client sees it
// (GET /api/table-pictures): the cloth a player lays on their own table
// (owner, 15 Sep 2026). It is Picture with the one URL split in two — the app
// draws its table on a pale ground by day and a deep one by night, and writes
// on it in ink that follows the theme, so a picture that reads on one ground
// is lost on the other. DayURL is drawn in the light theme, NightURL in the
// dark one, and the client switches with the theme; AssetFormat is one for
// the pair.
type TablePicture struct {
	ID       int64  `json:"id"`
	Name     string `json:"name"`
	DayURL   string `json:"dayUrl"`
	NightURL string `json:"nightUrl"`
	// AssetFormat is how the client plays both URLs: "IMAGE", "SVG", "LOTTIE"
	// or "RIVE", as on a profile picture.
	AssetFormat string `json:"assetFormat"`
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
	// Owned is whether this viewer may lay it right now: every free picture,
	// plus the premium ones they have bought whose rental has not run out.
	Owned bool `json:"owned"`
	// ExpiresAt is when this viewer's rental runs out (epoch ms), or 0 when
	// they do not own it or own it for ever.
	ExpiresAt int64 `json:"expiresAt"`
}

// Free reports whether the picture costs nothing and needs no ownership row.
func (p TablePicture) Free() bool { return p.Type == PictureFree }

// PaidInChips reports whether buying the picture moves chips — Picture's rule:
// only a DIAMOND or HAMMER row is paid from a wallet no seat holds.
func (p TablePicture) PaidInChips() bool {
	return p.Currency != PictureCurrencyDiamond && p.Currency != PictureCurrencyHammer
}

// ErrTablePictureUnknown is no such table picture (or an id that was never a
// number). Every other refusal a table picture can meet is a profile
// picture's — ErrPictureInactive, ErrPictureFree, ErrPictureChips,
// ErrPictureDiamonds, ErrPictureHammers, ErrPictureLocked, ErrPictureAtTable —
// because the rule is the same one; only "which catalogue" differs, and the
// HTTP layer words that.
var ErrTablePictureUnknown = errors.New("db: no such table picture")

// TablePictures is the table-picture catalogue, who owns what, and which
// picture each player has laid.
type TablePictures struct {
	db    *DB
	users *Users
	clock func() time.Time
}

// NewTablePictures builds the store. users is used to return the fresh
// account after a purchase or a change of table; clock nil → time.Now.
func NewTablePictures(d *DB, users *Users, clock func() time.Time) *TablePictures {
	return &TablePictures{db: d, users: users, clock: clock}
}

// tablePictureColumns is the catalogue row, aliased p.
const tablePictureColumns = `p.id, p.name, p.day_asset_url, p.night_asset_url, p.asset_format, p.currency, p.type, p.cost, p.duration_days, p.duration_hours, p.sort_order`

// tableOwnedJoin resolves ownership for one viewer ($1), with the expiry
// tested in the join as ownedJoin does for profile pictures: a lapsed rental
// stops counting the instant it lapses, whether or not a sweep has run.
const tableOwnedJoin = ` LEFT JOIN user_table_pictures o
                           ON o.table_picture_id = p.id AND o.user_id = $1
                          AND (o.expires_at = 0 OR o.expires_at > %d) `

func (p *TablePictures) ownedJoinNow() string {
	return fmt.Sprintf(tableOwnedJoin, now(p.clock))
}

// scanTablePicture reads one row selected with tablePictureColumns followed by
// is_active, ownedExpr and expiryExpr.
func scanTablePicture(row pgx.Row) (TablePicture, bool, error) {
	var pic TablePicture
	var active bool
	err := row.Scan(&pic.ID, &pic.Name, &pic.DayURL, &pic.NightURL, &pic.AssetFormat, &pic.Currency, &pic.Type, &pic.Cost,
		&pic.DurationDays, &pic.DurationHours, &pic.SortOrder, &active, &pic.Owned, &pic.ExpiresAt)
	return pic, active, err
}

// List returns every table picture still on offer, in catalogue order, each
// marked with whether this player may lay it. userID may be "" for an
// unauthenticated caller, who owns the free pictures and nothing else.
// Retired rows are left out; a player still using one keeps it — the choice
// lives in user_table_choice, not here.
func (p *TablePictures) List(ctx context.Context, userID string) ([]TablePicture, error) {
	rows, err := p.db.Pool.Query(ctx,
		`SELECT `+tablePictureColumns+`, p.is_active, `+ownedExpr+`, `+expiryExpr+`
		   FROM table_pictures p`+p.ownedJoinNow()+`
		  WHERE p.is_active
		  ORDER BY p.sort_order, p.id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	// Never nil: the wire contract is {"tablePictures": []} on an empty
	// catalogue, and a nil slice marshals to null.
	pictures := []TablePicture{}
	for rows.Next() {
		pic, _, err := scanTablePicture(rows)
		if err != nil {
			return nil, err
		}
		pictures = append(pictures, pic)
	}
	return pictures, rows.Err()
}

// Find is one table picture by id, with this viewer's ownership resolved,
// whether or not it is still on offer — the second result says. A missing row
// is ErrTablePictureUnknown.
func (p *TablePictures) Find(ctx context.Context, userID string, id int64) (TablePicture, bool, error) {
	pic, active, err := scanTablePicture(p.db.Pool.QueryRow(ctx,
		`SELECT `+tablePictureColumns+`, p.is_active, `+ownedExpr+`, `+expiryExpr+`
		   FROM table_pictures p`+p.ownedJoinNow()+`
		  WHERE p.id = $2`, userID, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return TablePicture{}, false, ErrTablePictureUnknown
	}
	if err != nil {
		return TablePicture{}, false, err
	}
	return pic, active, nil
}

// TablePicturePurchase is what Buy did: PicturePurchase for a table picture.
type TablePicturePurchase struct {
	Picture TablePicture
	// Charged is false when the player already owned it — success, nothing
	// spent this time.
	Charged bool
	// Spent is what left the wallet, in the picture's Currency.
	Spent int64
	// Balance is the chip balance afterwards; a diamond or hammer buy leaves
	// it as it was.
	Balance int64
	User    *User
}

// Buy unlocks a premium table picture for a player, paying for it out of the
// wallet its currency names, in one transaction under the wallet lock — the
// transaction Pictures.Buy runs, against the table tables: a COIN price is a
// chip_ledger row (reason table_picture_purchase, action_id
// "table:<user>:<id>:<n>", UNIQUE) and a wallet delta, so
// SUM(chip_ledger.delta) == users.chips still holds; a DIAMOND or HAMMER price
// is a delta on its users column with the ownership row as its receipt. The
// row lock serialises double taps and the owned check makes the second an
// idempotent success; the UNIQUE action_id catches a replay whose first commit
// was acknowledged into a dropped connection.
//
// A seated player buys through BuyAtTable: their chips may only move at the
// three hand checkpoints (CLAUDE.md §5.1).
func (p *TablePictures) Buy(ctx context.Context, userID string, pictureID int64) (*TablePicturePurchase, error) {
	return p.buy(ctx, userID, pictureID, false)
}

// BuyAtTable is Buy for a seated player: a DIAMOND or HAMMER picture sells as
// in the lobby — no seat holds either count — and a COIN one is refused with
// ErrPictureAtTable, decided inside the transaction from the row about to be
// charged.
func (p *TablePictures) BuyAtTable(ctx context.Context, userID string, pictureID int64) (*TablePicturePurchase, error) {
	return p.buy(ctx, userID, pictureID, true)
}

func (p *TablePictures) buy(ctx context.Context, userID string, pictureID int64, atTable bool) (*TablePicturePurchase, error) {
	stamp := now(p.clock)
	out := &TablePicturePurchase{}

	err := p.db.WithTx(ctx, func(tx pgx.Tx) error {
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
		pic, active, err := scanTablePicture(tx.QueryRow(ctx,
			`SELECT `+tablePictureColumns+`, p.is_active, `+ownedExpr+`, `+expiryExpr+`
			   FROM table_pictures p`+p.ownedJoinNow()+`
			  WHERE p.id = $2`, userID, pictureID))
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrTablePictureUnknown
		}
		if err != nil {
			return err
		}

		out.Picture = pic
		switch {
		case !active:
			return ErrPictureInactive
		case pic.Free():
			return ErrPictureFree
		case pic.Owned:
			out.Charged, out.Spent, out.Balance = false, 0, chips
			return nil
		case atTable && pic.PaidInChips():
			return ErrPictureAtTable
		}
		switch pic.Currency {
		case PictureCurrencyDiamond:
			if diamond < pic.Cost {
				return ErrPictureDiamonds
			}
		case PictureCurrencyHammer:
			if hammer < pic.Cost {
				return &PictureHammerShortage{Cost: pic.Cost}
			}
		default:
			if chips < pic.Cost {
				return ErrPictureChips
			}
		}

		// Purchases so far, read without the expiry filter, so a renewal's
		// action id never repeats the first purchase's (Pictures.buy says why).
		var priorPurchases int
		if err := tx.QueryRow(ctx,
			`SELECT COALESCE(max(purchases), 0) FROM user_table_pictures
			  WHERE user_id = $1 AND table_picture_id = $2`,
			userID, pictureID).Scan(&priorPurchases); err != nil {
			return err
		}

		balance := chips
		switch pic.Currency {
		case PictureCurrencyDiamond:
			if _, err := tx.Exec(ctx,
				`UPDATE users SET diamond = diamond - $2, updated_at = $3 WHERE id = $1`,
				userID, pic.Cost, stamp); err != nil {
				return err
			}
		case PictureCurrencyHammer:
			if _, err := tx.Exec(ctx,
				`UPDATE users SET hammer = hammer - $2, updated_at = $3 WHERE id = $1`,
				userID, pic.Cost, stamp); err != nil {
				return err
			}
		default:
			balance = chips - pic.Cost
			actionID := fmt.Sprintf("table:%s:%d:%d", userID, pictureID, priorPurchases+1)
			if err := appendLedger(ctx, tx, userID, "", actionID,
				-pic.Cost, balance, game.LedgerReasonTablePicturePurchase, stamp); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx,
				`UPDATE users SET chips = $2, updated_at = $3 WHERE id = $1`, userID, balance, stamp); err != nil {
				return err
			}
		}

		// A rental runs from now, not from what was left of a lapsed one.
		var expiresAt int64
		if term := int64(pic.DurationDays)*DayMs + int64(pic.DurationHours)*HourMs; term > 0 {
			expiresAt = stamp + term
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO user_table_pictures (user_id, table_picture_id, acquired_at, expires_at, purchases)
			 VALUES ($1, $2, $3, $4, 1)
			 ON CONFLICT (user_id, table_picture_id) DO UPDATE
			    SET acquired_at = EXCLUDED.acquired_at,
			        expires_at  = EXCLUDED.expires_at,
			        purchases   = user_table_pictures.purchases + 1`,
			userID, pictureID, stamp, expiresAt); err != nil {
			return err
		}

		out.Picture.Owned = true
		out.Picture.ExpiresAt = expiresAt
		out.Charged, out.Spent, out.Balance = true, pic.Cost, balance
		return nil
	})

	// A replay whose first commit landed but whose answer was lost: the money
	// moved and the picture is theirs, so this is the success it is.
	if err != nil && isUniqueViolationOn(err, "action_id") {
		user, ferr := p.users.FindByID(ctx, userID)
		if ferr != nil {
			return nil, ferr
		}
		pic, _, ferr := p.Find(ctx, userID, pictureID)
		if ferr != nil {
			return nil, ferr
		}
		return &TablePicturePurchase{Picture: pic, Charged: false, Balance: user.Chips, User: user}, nil
	}
	if err != nil {
		return nil, err
	}

	user, err := p.users.FindByID(ctx, userID)
	if err != nil {
		return nil, err
	}
	out.User = user
	return out, nil
}

// Use lays a table picture on the player's table (or, with nil, takes it off
// and leaves the table as it comes) and returns the fresh user, whose
// TablePicture now carries the pair of URLs to draw.
//
// Like Users.SetActivePicture it does NOT check ownership — the caller does,
// so the refusal reaches the client as a sentence — and the foreign key is the
// backstop against an id that is not in the catalogue. Wearing a table moves
// no wallet and touches no seat: the picture is drawn by that player's own
// client and nobody else's, so a seated player may change it.
func (p *TablePictures) Use(ctx context.Context, userID string, pictureID *int64) (*User, error) {
	var err error
	if pictureID == nil {
		_, err = p.db.Pool.Exec(ctx, `DELETE FROM user_table_choice WHERE user_id = $1`, userID)
	} else {
		_, err = p.db.Pool.Exec(ctx,
			`INSERT INTO user_table_choice (user_id, table_picture_id, chosen_at) VALUES ($1, $2, $3)
			 ON CONFLICT (user_id) DO UPDATE SET table_picture_id = EXCLUDED.table_picture_id, chosen_at = EXCLUDED.chosen_at`,
			userID, *pictureID, now(p.clock))
	}
	if err != nil {
		return nil, err
	}
	return p.users.FindByID(ctx, userID)
}

// ExpireLapsed takes off a laid table picture whose rental has run out, and
// reports whether it had to — Pictures.ExpireLapsed for the table. Ownership
// itself needs no sweep (every read tests the expiry); the row in
// user_table_choice is what does, or a player keeps a cloth they have stopped
// paying for. Called where the profile sweep is: at login, on /api/auth/me,
// and when this catalogue is listed. Free pictures are never touched.
func (p *TablePictures) ExpireLapsed(ctx context.Context, userID string) (bool, error) {
	tag, err := p.db.Pool.Exec(ctx, `
		DELETE FROM user_table_choice c
		 WHERE c.user_id = $1
		   AND EXISTS (
		       SELECT 1 FROM table_pictures p
		        WHERE p.id = c.table_picture_id AND p.type = 'PREMIUM')
		   AND NOT EXISTS (
		       SELECT 1 FROM user_table_pictures o
		        WHERE o.user_id = c.user_id
		          AND o.table_picture_id = c.table_picture_id
		          AND (o.expires_at = 0 OR o.expires_at > $2))`,
		userID, now(p.clock))
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}
