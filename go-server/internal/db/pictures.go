package db

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// Picture types (profile_pictures.type). FREE is worn by anyone; PREMIUM has
// to be bought with chips before it can be worn.
const (
	PictureFree    = "FREE"
	PicturePremium = "PREMIUM"
)

// Picture is one catalogue row as a client sees it (GET /api/profiles).
//
// URL, not ImageURL, is the JSON key: the clients have read `url` off this
// listing since the pictures were a directory listing, and the catalogue is a
// change of where the list comes from, not of what a picture is to a client.
// Everything after it is new — the name to show, whether it costs chips, and
// whether this particular player may wear it.
type Picture struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
	URL  string `json:"url"`
	// Type is PictureFree or PicturePremium.
	Type string `json:"type"`
	// Cost in chips. Always 0 for a free picture (the schema's
	// free_picture_cost_check makes that an invariant, not a convention).
	Cost      int64 `json:"cost"`
	SortOrder int   `json:"sortOrder"`
	// Owned is whether this viewer may wear it: every free picture, plus the
	// premium ones they have bought. False everywhere for an anonymous caller.
	Owned bool `json:"owned"`
}

// Free reports whether the picture costs nothing and needs no ownership row.
func (p Picture) Free() bool { return p.Type == PictureFree }

// Catalogue failures the HTTP layer maps to its own codes and messages. They
// are values rather than strings so a caller compares with errors.Is and never
// by parsing a message.
var (
	// ErrPictureUnknown is no such row (or an id that was never a number).
	ErrPictureUnknown = errors.New("db: no such profile picture")
	// ErrPictureInactive is a retired row: is_active = FALSE. Still owned and
	// still worn by whoever had it, but not on offer any more.
	ErrPictureInactive = errors.New("db: profile picture is retired")
	// ErrPictureFree is a buy request for a picture that costs nothing —
	// there is nothing to sell, and charging 0 would write a pointless ledger
	// row and an ownership row the wear check does not need.
	ErrPictureFree = errors.New("db: profile picture is free")
	// ErrPictureChips is a wallet that cannot cover the price.
	ErrPictureChips = errors.New("db: not enough chips for this picture")
	// ErrPictureLocked is a wear request for a premium picture the player has
	// not bought.
	ErrPictureLocked = errors.New("db: profile picture is not owned")
)

// Pictures is the profile-picture catalogue and who owns what.
type Pictures struct {
	db    *DB
	users *Users
	clock func() time.Time
}

// NewPictures builds the store. users is used to return the fresh wallet after
// a purchase; clock nil → time.Now.
func NewPictures(d *DB, users *Users, clock func() time.Time) *Pictures {
	return &Pictures{db: d, users: users, clock: clock}
}

// pictureColumns is the catalogue row, aliased p.
const pictureColumns = `p.id, p.name, p.image_url, p.type, p.cost, p.sort_order`

// ownedJoin resolves ownership for one viewer. $1 is the user id; an empty
// string matches nobody, which is exactly right for an anonymous caller — they
// own the free pictures and nothing else.
const ownedJoin = ` LEFT JOIN user_profile_pictures o
                      ON o.profile_picture_id = p.id AND o.user_id = $1 `

// ownedExpr is the wear test: free, or bought.
const ownedExpr = `(p.type = 'FREE' OR o.user_id IS NOT NULL)`

// List returns every picture still on offer, in catalogue order, each marked
// with whether this player may wear it. userID may be "" for an unauthenticated
// caller (the browser client and the bots both list without a token).
//
// Retired rows (is_active = FALSE) are left out: the catalogue is what the
// picker draws, and a picture nobody can choose any more does not belong in it.
// A player still wearing one keeps it — the wear lives on users, not here.
func (p *Pictures) List(ctx context.Context, userID string) ([]Picture, error) {
	rows, err := p.db.Pool.Query(ctx,
		`SELECT `+pictureColumns+`, `+ownedExpr+`
		   FROM profile_pictures p`+ownedJoin+`
		  WHERE p.is_active
		  ORDER BY p.sort_order, p.id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	// Never nil: the wire contract is `{"profiles": []}` on an empty
	// catalogue, and a nil slice marshals to null.
	pictures := []Picture{}
	for rows.Next() {
		var pic Picture
		if err := rows.Scan(&pic.ID, &pic.Name, &pic.URL, &pic.Type, &pic.Cost, &pic.SortOrder, &pic.Owned); err != nil {
			return nil, err
		}
		pictures = append(pictures, pic)
	}
	return pictures, rows.Err()
}

// Find is one picture by id, with this viewer's ownership resolved, whether or
// not it is still on offer — the caller decides what a retired row means.
// A missing row is ErrPictureUnknown, not a nil result, because every caller
// treats absence as a refusal.
func (p *Pictures) Find(ctx context.Context, userID string, id int64) (Picture, bool, error) {
	var pic Picture
	var active bool
	err := p.db.Pool.QueryRow(ctx,
		`SELECT `+pictureColumns+`, p.is_active, `+ownedExpr+`
		   FROM profile_pictures p`+ownedJoin+`
		  WHERE p.id = $2`, userID, id).
		Scan(&pic.ID, &pic.Name, &pic.URL, &pic.Type, &pic.Cost, &pic.SortOrder, &active, &pic.Owned)
	if errors.Is(err, pgx.ErrNoRows) {
		return Picture{}, false, ErrPictureUnknown
	}
	if err != nil {
		return Picture{}, false, err
	}
	return pic, active, nil
}

// PicturePurchase is what Buy did.
type PicturePurchase struct {
	Picture Picture
	// Charged is false when the player already owned it. The caller still
	// answers with success — they do own it — but no chips moved this time.
	Charged bool
	Spent   int64
	Balance int64
	User    *User
}

// Buy unlocks a premium picture for a player, once, paying for it out of their
// wallet through the ledger.
//
// A picture is bought with chips, so it is a wallet movement, and every wallet
// movement in this game is a chip_ledger row — `SUM(chip_ledger.delta) per user
// == users.chips` is the invariant the whole money model is checked against
// (CLAUDE.md §5.1), and a bare `UPDATE users SET chips` would break it silently.
// The transaction is the same shape as every other one here:
//
//	SELECT chips FROM users WHERE id = $1 FOR UPDATE    lock the wallet
//	(read the catalogue row and the ownership row under that lock)
//	INSERT chip_ledger (…, action_id 'picture:<user>:<id>', delta -cost)
//	UPDATE users SET chips = chips - cost
//	INSERT user_profile_pictures
//
// Two things stop a double charge and they are deliberately both here. The row
// lock serialises two clicks so the second sees the ownership row the first
// wrote. `chip_ledger.action_id` is UNIQUE and derived from the pair, so even a
// retry whose first commit was acknowledged into a dropped connection collides
// on the index and rolls back rather than charging twice — the same mechanism
// that stops a settle paying a winner twice.
//
// The caller must refuse this while the player is seated: a seated player's
// wallet may only move at the three hand checkpoints (§5.1), and a purchase
// landing mid-hand would be written over by the next checkpoint's delta.
func (p *Pictures) Buy(ctx context.Context, userID string, pictureID int64) (*PicturePurchase, error) {
	stamp := now(p.clock)
	out := &PicturePurchase{}

	err := p.db.WithTx(ctx, func(tx pgx.Tx) error {
		var chips int64
		if err := tx.QueryRow(ctx,
			`SELECT chips FROM users WHERE id = $1 AND deleted_at = 0 FOR UPDATE`, userID).Scan(&chips); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return game.Errorf(game.CodeUnknownUser, "unknown user %s", userID)
			}
			return err
		}

		// Read the catalogue and the ownership row inside the wallet lock, so
		// "do they already own it" cannot change under us between the check
		// and the charge.
		var pic Picture
		var active bool
		err := tx.QueryRow(ctx,
			`SELECT `+pictureColumns+`, p.is_active, (o.user_id IS NOT NULL)
			   FROM profile_pictures p`+ownedJoin+`
			  WHERE p.id = $2`, userID, pictureID).
			Scan(&pic.ID, &pic.Name, &pic.URL, &pic.Type, &pic.Cost, &pic.SortOrder, &active, &pic.Owned)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrPictureUnknown
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
			// Already theirs. Idempotent success, like a replayed receipt.
			out.Charged, out.Spent, out.Balance = false, 0, chips
			return nil
		case chips < pic.Cost:
			return ErrPictureChips
		}

		balance := chips - pic.Cost
		actionID := fmt.Sprintf("picture:%s:%d", userID, pictureID)
		if err := appendLedger(ctx, tx, userID, "", actionID,
			-pic.Cost, balance, game.LedgerReasonPicturePurchase, stamp); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx,
			`UPDATE users SET chips = $2, updated_at = $3 WHERE id = $1`, userID, balance, stamp); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO user_profile_pictures (user_id, profile_picture_id, acquired_at)
			 VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`, userID, pictureID, stamp); err != nil {
			return err
		}

		out.Picture.Owned = true
		out.Charged, out.Spent, out.Balance = true, pic.Cost, balance
		return nil
	})

	// A replay whose first commit landed but whose answer was lost: the money
	// already moved and the picture is already theirs, so this is the success
	// it is, exactly as CreditPurchase treats a repeated Play receipt.
	if err != nil && isUniqueViolationOn(err, "action_id") {
		user, ferr := p.users.FindByID(ctx, userID)
		if ferr != nil {
			return nil, ferr
		}
		pic, _, ferr := p.Find(ctx, userID, pictureID)
		if ferr != nil {
			return nil, ferr
		}
		return &PicturePurchase{Picture: pic, Charged: false, Balance: user.Chips, User: user}, nil
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
