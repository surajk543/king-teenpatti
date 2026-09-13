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
	// PictureCurrencyCoin / PictureCurrencyDiamond name the wallet a PREMIUM
	// row's cost is paid from. COIN is chips and moves through chip_ledger;
	// DIAMOND debits users.diamond directly — the chips invariant's ledger is
	// not diamonds' business.
	PictureCurrencyCoin    = "COIN"
	PictureCurrencyDiamond = "DIAMOND"
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
	// AssetFormat tells the client how to play what URL serves: "IMAGE"
	// (jpg/jpeg/png — one loader for all three), "SVG", "LOTTIE" (a Lottie
	// JSON or .lottie zip fetched and played) or "RIVE" (a Rive .riv
	// binary). It rides the wire so a catalogue row can change loader
	// without a client release — hosted URLs rarely carry an extension to
	// guess from.
	AssetFormat string `json:"assetFormat"`
	// Currency names the wallet Cost is paid from: "COIN" (chips) or
	// "DIAMOND". Always "COIN" for a free row — nothing is charged.
	Currency string `json:"currency"`
	// Type is PictureFree or PicturePremium.
	Type string `json:"type"`
	// Cost in the row's Currency — chips or diamonds. Always 0 for a free
	// picture (the schema's free_picture_cost_check makes that an invariant,
	// not a convention).
	Cost int64 `json:"cost"`
	// DurationDays is how long a purchase lasts; 0 is for ever.
	DurationDays int `json:"durationDays"`
	SortOrder    int `json:"sortOrder"`
	// Owned is whether this viewer may wear it RIGHT NOW: every free picture,
	// plus the premium ones they have bought and whose rental has not run out.
	// False everywhere for an anonymous caller.
	Owned bool `json:"owned"`
	// ExpiresAt is when this viewer's rental of it runs out (epoch ms), or 0
	// when they do not own it or own it for ever. It is what lets the picker
	// say "4 days left" rather than only "yours".
	ExpiresAt int64 `json:"expiresAt"`
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
	// ErrPictureDiamonds is the diamond wallet that cannot cover the price.
	// Same wire code as ErrPictureChips (clients match by code); the
	// message names the currency that was actually short.
	ErrPictureDiamonds = errors.New("db: not enough diamonds for this picture")
	// ErrPictureLocked is a wear request for a premium picture the player has
	// not bought.
	ErrPictureLocked = errors.New("db: profile picture is not owned")
	// ErrPictureAtTable is BuyAtTable refusing a COIN picture: a seated
	// player's chips move only at the hand checkpoints.
	ErrPictureAtTable = errors.New("db: a chip-priced picture cannot be bought at a table")
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
const pictureColumns = `p.id, p.name, p.asset_url, p.asset_format, p.currency, p.type, p.cost, p.duration_days, p.sort_order`

// ownedJoin resolves ownership for one viewer. $1 is the user id; an empty
// string matches nobody, which is exactly right for an anonymous caller — they
// own the free pictures and nothing else.
//
// The expiry is tested HERE, in the join, rather than trusted to a sweep having
// run: a lapsed rental stops counting the instant it lapses, whether or not
// anybody has logged in since. The sweep at login only tidies what the player
// is WEARING; it is not what decides who owns what.
const ownedJoin = ` LEFT JOIN user_profile_pictures o
                      ON o.profile_picture_id = p.id AND o.user_id = $1
                     AND (o.expires_at = 0 OR o.expires_at > %d) `

// ownedExpr is the wear test: free, or bought and not yet run out.
const ownedExpr = `(p.type = 'FREE' OR o.user_id IS NOT NULL)`

// expiryExpr is the viewer's own expiry for this picture, 0 when it never runs
// out or they do not own it.
const expiryExpr = `COALESCE(o.expires_at, 0)`

// ownedJoinNow is ownedJoin with this instant baked in.
//
// The time is interpolated rather than bound as a parameter, and that is safe
// because it is an int64 this process just read off its own clock — never
// anything a caller sent. It keeps the two query parameters as ($1 user, $2 id)
// for every reader, which is what the callers below are written against.
func (p *Pictures) ownedJoinNow() string {
	return fmt.Sprintf(ownedJoin, now(p.clock))
}

// DayMs is a rental day. Durations are stored in days because a human edits
// them; everything the server does with one is milliseconds.
const DayMs int64 = 24 * 60 * 60 * 1000

// List returns every picture still on offer, in catalogue order, each marked
// with whether this player may wear it. userID may be "" for an unauthenticated
// caller (the browser client and the bots both list without a token).
//
// Retired rows (is_active = FALSE) are left out: the catalogue is what the
// picker draws, and a picture nobody can choose any more does not belong in it.
// A player still wearing one keeps it — the wear lives on users, not here.
func (p *Pictures) List(ctx context.Context, userID string) ([]Picture, error) {
	rows, err := p.db.Pool.Query(ctx,
		`SELECT `+pictureColumns+`, `+ownedExpr+`, `+expiryExpr+`
		   FROM profile_pictures p`+p.ownedJoinNow()+`
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
		if err := rows.Scan(&pic.ID, &pic.Name, &pic.URL, &pic.AssetFormat, &pic.Currency, &pic.Type, &pic.Cost,
			&pic.DurationDays, &pic.SortOrder, &pic.Owned, &pic.ExpiresAt); err != nil {
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
		`SELECT `+pictureColumns+`, p.is_active, `+ownedExpr+`, `+expiryExpr+`
		   FROM profile_pictures p`+p.ownedJoinNow()+`
		  WHERE p.id = $2`, userID, id).
		Scan(&pic.ID, &pic.Name, &pic.URL, &pic.AssetFormat, &pic.Currency, &pic.Type, &pic.Cost, &pic.DurationDays,
			&pic.SortOrder, &active, &pic.Owned, &pic.ExpiresAt)
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
	// answers with success — they do own it — but nothing was spent this time.
	Charged bool
	// Spent is what left the wallet, in the picture's Currency.
	Spent int64
	// Balance is the chip balance afterwards; a diamond buy leaves it as it was.
	Balance int64
	User    *User
}

// Buy unlocks a premium picture for a player, once, paying for it out of the
// wallet its currency names.
//
// A COIN picture is bought with chips, so it is a wallet movement, and every
// chip movement in this game is a chip_ledger row — `SUM(chip_ledger.delta) per
// user == users.chips` is the invariant the whole money model is checked against
// (CLAUDE.md §5.1), and a bare `UPDATE users SET chips` would break it silently.
// A DIAMOND picture debits users.diamond instead and writes no ledger row: the
// ownership row is its receipt. The COIN transaction is the same shape as every
// other one here:
//
//	SELECT chips FROM users WHERE id = $1 FOR UPDATE    lock the wallet
//	(read the catalogue row and the ownership row under that lock)
//	INSERT chip_ledger (…, action_id 'picture:<user>:<id>:<n>', delta -cost)
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
// A seated player buys through BuyAtTable instead: a seated player's chips may
// only move at the three hand checkpoints (§5.1), and a chip purchase landing
// mid-hand would be written over by the next checkpoint's delta.
func (p *Pictures) Buy(ctx context.Context, userID string, pictureID int64) (*PicturePurchase, error) {
	return p.buy(ctx, userID, pictureID, false)
}

// BuyAtTable is Buy for a player who is seated (owner, 13 Sep 2026). A DIAMOND
// picture is sold exactly as in the lobby — nothing at a table reads or writes
// diamonds — while a COIN picture is refused with ErrPictureAtTable. The rule
// is decided inside the transaction, from the row about to be charged, so a
// re-price between some earlier lookup and the charge cannot slip a chip debit
// past it.
func (p *Pictures) BuyAtTable(ctx context.Context, userID string, pictureID int64) (*PicturePurchase, error) {
	return p.buy(ctx, userID, pictureID, true)
}

func (p *Pictures) buy(ctx context.Context, userID string, pictureID int64, atTable bool) (*PicturePurchase, error) {
	stamp := now(p.clock)
	out := &PicturePurchase{}

	err := p.db.WithTx(ctx, func(tx pgx.Tx) error {
		var chips, diamond int64
		if err := tx.QueryRow(ctx,
			`SELECT chips, diamond FROM users WHERE id = $1 AND deleted_at = 0 FOR UPDATE`, userID).Scan(&chips, &diamond); err != nil {
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
			`SELECT `+pictureColumns+`, p.is_active, `+ownedExpr+`, `+expiryExpr+`
			   FROM profile_pictures p`+p.ownedJoinNow()+`
			  WHERE p.id = $2`, userID, pictureID).
			Scan(&pic.ID, &pic.Name, &pic.URL, &pic.AssetFormat, &pic.Currency, &pic.Type, &pic.Cost, &pic.DurationDays,
				&pic.SortOrder, &active, &pic.Owned, &pic.ExpiresAt)
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
			// Already theirs, and not yet run out. Idempotent success, like a
			// replayed receipt: this is what makes a double-tap cost once.
			out.Charged, out.Spent, out.Balance = false, 0, chips
			return nil
		case atTable && pic.Currency != PictureCurrencyDiamond:
			return ErrPictureAtTable
		}
		// Which wallet pays is the row's currency, not a global: COIN spends
		// chips through chip_ledger below; DIAMOND debits users.diamond
		// directly and writes no ledger row — the chips invariant's ledger is
		// about chips alone. The row lock above serialises double taps either
		// way, and the owned check still makes the second an idempotent
		// success.
		if pic.Currency == PictureCurrencyDiamond {
			if diamond < pic.Cost {
				return ErrPictureDiamonds
			}
		} else if chips < pic.Cost {
			return ErrPictureChips
		}

		// How many times this player has bought this picture BEFORE now, read
		// without the expiry filter. Taking it off the ownership join instead
		// was a real bug: a lapsed rental makes that join empty, so the count
		// came back 0, the action id repeated the first purchase's, the UNIQUE
		// index refused it and the renewal was reported as an already-banked
		// replay — the player got their picture back without paying.
		var priorPurchases int
		if err := tx.QueryRow(ctx,
			`SELECT COALESCE(max(purchases), 0) FROM user_profile_pictures
			  WHERE user_id = $1 AND profile_picture_id = $2`,
			userID, pictureID).Scan(&priorPurchases); err != nil {
			return err
		}

		balance := chips
		if pic.Currency == PictureCurrencyDiamond {
			// The ownership upsert below is the receipt; nothing else is
			// written for a diamond buy.
			if _, err := tx.Exec(ctx,
				`UPDATE users SET diamond = diamond - $2, updated_at = $3 WHERE id = $1`,
				userID, pic.Cost, stamp); err != nil {
				return err
			}
		} else {
			balance = chips - pic.Cost
			// The purchase number, not just the pair, so a lapsed rental can
			// be bought again: the first purchase's action id is already spent
			// and UNIQUE would refuse the second. A double-tap never reaches
			// here — the owned check above returns first, under the same row
			// lock.
			purchase := priorPurchases + 1
			actionID := fmt.Sprintf("picture:%s:%d:%d", userID, pictureID, purchase)
			if err := appendLedger(ctx, tx, userID, "", actionID,
				-pic.Cost, balance, game.LedgerReasonPicturePurchase, stamp); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx,
				`UPDATE users SET chips = $2, updated_at = $3 WHERE id = $1`, userID, balance, stamp); err != nil {
				return err
			}
		}

		// A rental runs from NOW, not from whatever is left of a lapsed one:
		// the old term is over, and adding to it would pay the player for
		// having let it run out.
		var expiresAt int64
		if pic.DurationDays > 0 {
			expiresAt = stamp + int64(pic.DurationDays)*DayMs
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO user_profile_pictures (user_id, profile_picture_id, acquired_at, expires_at, purchases)
			 VALUES ($1, $2, $3, $4, 1)
			 ON CONFLICT (user_id, profile_picture_id) DO UPDATE
			    SET acquired_at = EXCLUDED.acquired_at,
			        expires_at  = EXCLUDED.expires_at,
			        purchases   = user_profile_pictures.purchases + 1`,
			userID, pictureID, stamp, expiresAt); err != nil {
			return err
		}

		out.Picture.Owned = true
		out.Picture.ExpiresAt = expiresAt
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

// ExpireLapsed takes off a picture whose rental has run out, and reports
// whether it had to.
//
// Ownership itself needs no sweep — every read tests the expiry, so a lapsed
// rental stops counting the moment it lapses. What DOES need one is the picture
// the player is wearing: `users.active_picture_id` is a plain column that no
// expiry test passes through, so without this a player would keep a face they
// have stopped paying for until they next opened the picker.
//
// Called when the player comes back — at login, and on /api/auth/me, which is
// how a saved session returns without logging in — and whenever the catalogue
// is listed. Free pictures are never touched — there is nothing to expire.
func (p *Pictures) ExpireLapsed(ctx context.Context, userID string) (bool, error) {
	tag, err := p.db.Pool.Exec(ctx, `
		UPDATE users u
		   SET active_picture_id = NULL, updated_at = $2
		 WHERE u.id = $1
		   AND u.active_picture_id IS NOT NULL
		   AND EXISTS (
		       SELECT 1 FROM profile_pictures p
		        WHERE p.id = u.active_picture_id AND p.type = 'PREMIUM')
		   AND NOT EXISTS (
		       SELECT 1 FROM user_profile_pictures o
		        WHERE o.user_id = u.id
		          AND o.profile_picture_id = u.active_picture_id
		          AND (o.expires_at = 0 OR o.expires_at > $2))`,
		userID, now(p.clock))
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}
