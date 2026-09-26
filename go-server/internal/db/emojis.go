package db

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// EmojiFormatLottie is the one asset_format an emoji row may carry: every
// emoji is a Lottie the client downloads once and plays.
const EmojiFormatLottie = "LOTTIE"

// Emoji is one row of the emoji catalogue as a client sees it (GET
// /api/emojis; owner, 26 Sep 2026): an animated emoji a player sends to their
// table. It is Picture's shape, key for key — the app draws the Emojis shelf
// with the picture shelf's tiles — for a thing that is SENT rather than worn:
// owning one is what lets a player send it with chat:emoji (Emojis.Owns).
type Emoji struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
	// URL is the Lottie JSON the client downloads (and keeps: a URL's contents
	// are treated as immutable on the phone, so a changed emoji needs a new
	// URL).
	URL string `json:"url"`
	// AssetFormat is always "LOTTIE" (the schema's CHECK). It rides the wire
	// anyway, as a picture's does, so a later format is a row and a client
	// release rather than a change to what this key means.
	AssetFormat string `json:"assetFormat"`
	// Currency names the wallet Cost is paid from: "COIN" (chips), "DIAMOND"
	// or "HAMMER". "COIN" on a free row — nothing is charged.
	Currency string `json:"currency"`
	// Type is PictureFree or PicturePremium: the FREE/PREMIUM rule is the
	// pictures' own (free_emoji_cost_check).
	Type string `json:"type"`
	// Cost in the row's Currency; always 0 for a free emoji.
	Cost int64 `json:"cost"`
	// DurationDays and DurationHours are how long a purchase lasts, added
	// together; both 0 is for ever.
	DurationDays  int `json:"durationDays"`
	DurationHours int `json:"durationHours"`
	SortOrder     int `json:"sortOrder"`
	// Owned is whether this viewer may SEND it right now: every free emoji,
	// plus the premium ones they have bought whose rental has not run out.
	// Only the free ones for an anonymous caller.
	Owned bool `json:"owned"`
	// ExpiresAt is when this viewer's rental of it runs out (epoch ms), or 0
	// when they do not own it or own it for ever.
	ExpiresAt int64 `json:"expiresAt"`
}

// Free reports whether the emoji costs nothing and needs no ownership row.
func (e Emoji) Free() bool { return e.Type == PictureFree }

// PaidInChips reports whether buying the emoji moves chips — Picture's rule:
// only a DIAMOND or HAMMER row is paid from a wallet no seat holds, so anything
// else, a currency this build does not know included, is refused at a table
// rather than sold.
func (e Emoji) PaidInChips() bool {
	return e.Currency != PictureCurrencyDiamond && e.Currency != PictureCurrencyHammer
}

// ForChat is the emoji as a chat line carries it (game.ChatEmoji): which row,
// its name, and the Lottie to play — never its price or its owner.
func (e Emoji) ForChat() game.ChatEmoji {
	return game.ChatEmoji{ID: e.ID, Name: e.Name, URL: e.URL, AssetFormat: e.AssetFormat}
}

// The emoji store's refusals. Values, compared with errors.Is, so the HTTP and
// socket layers each word them as their own code and never parse a message.
var (
	// ErrEmojiUnknown is no such row (or an id that was never a number).
	ErrEmojiUnknown = errors.New("db: no such emoji")
	// ErrEmojiInactive is a retired row: is_active = FALSE. Neither listed,
	// sold nor sent any more — whoever bought it keeps the ownership row, but
	// an emoji exists to be sent, and a retired one cannot be.
	ErrEmojiInactive = errors.New("db: emoji is retired")
	// ErrEmojiFree is a buy request for an emoji that costs nothing: every
	// player already has it, and charging 0 would write a pointless ledger row
	// and an ownership row the send check does not need.
	ErrEmojiFree = errors.New("db: emoji is free")
	// ErrEmojiUnaffordable is the wallet the emoji's currency names that
	// cannot cover its price. Buy returns it as an *EmojiShortage, which
	// errors.Is matches to this and which says which wallet and how much.
	ErrEmojiUnaffordable = errors.New("db: not enough to buy this emoji")
	// ErrEmojiLocked is a send (Owns) of a premium emoji the player has not
	// bought, or whose rental has run out.
	ErrEmojiLocked = errors.New("db: emoji is not owned")
	// ErrEmojiAtTable is BuyAtTable refusing a COIN emoji: a seated player's
	// chips move only at the hand checkpoints (CLAUDE.md §5.1).
	ErrEmojiAtTable = errors.New("db: a chip-priced emoji cannot be bought at a table")
)

// EmojiShortage is Buy refusing an emoji its wallet cannot cover. errors.Is(err,
// ErrEmojiUnaffordable) is true of it; Currency and Cost are the row's, read
// under the same wallet lock as the balance they were compared with, so the
// refusal can say "You need 5 diamonds to unlock this emoji."
type EmojiShortage struct {
	// Currency is PictureCurrencyCoin, PictureCurrencyDiamond or
	// PictureCurrencyHammer — the wallet that was short.
	Currency string
	Cost     int64
}

func (e *EmojiShortage) Error() string {
	return fmt.Sprintf("%v: it costs %d %s", ErrEmojiUnaffordable, e.Cost, e.Currency)
}

// Unwrap makes errors.Is(err, ErrEmojiUnaffordable) true.
func (e *EmojiShortage) Unwrap() error { return ErrEmojiUnaffordable }

// Emojis is the emoji catalogue and who owns what.
type Emojis struct {
	db    *DB
	users *Users
	clock func() time.Time
}

// NewEmojis builds the store. users is used to return the fresh wallet after a
// purchase; clock nil → time.Now.
func NewEmojis(d *DB, users *Users, clock func() time.Time) *Emojis {
	return &Emojis{db: d, users: users, clock: clock}
}

// emojiColumns is the catalogue row, aliased e.
const emojiColumns = `e.id, e.name, e.asset_url, e.asset_format, e.currency, e.type, e.cost, e.duration_days, e.duration_hours, e.sort_order`

// emojiOwnedJoin resolves ownership for one viewer ($1; "" matches nobody, an
// anonymous caller owning the free emojis and nothing else), with the expiry
// tested IN the join as the pictures' is: a lapsed rental stops counting the
// instant it lapses, and there is no sweep for emojis at all — nothing is worn.
const emojiOwnedJoin = ` LEFT JOIN user_emojis o
                           ON o.emoji_id = e.id AND o.user_id = $1
                          AND (o.expires_at = 0 OR o.expires_at > %d) `

// emojiOwnedExpr is the send test: free, or bought and not yet run out.
const emojiOwnedExpr = `(e.type = 'FREE' OR o.user_id IS NOT NULL)`

// ownedJoinNow is emojiOwnedJoin with this instant baked in. Interpolated, not
// bound, for the reason Pictures.ownedJoinNow gives: it is an int64 this
// process read off its own clock, and it keeps every reader's parameters
// ($1 user, $2 id).
func (e *Emojis) ownedJoinNow() string {
	return fmt.Sprintf(emojiOwnedJoin, now(e.clock))
}

// selectEmoji is one row by id ($2) for a viewer ($1): the catalogue columns,
// is_active, the send test and the viewer's expiry.
func (e *Emojis) selectEmoji() string {
	return `SELECT ` + emojiColumns + `, e.is_active, ` + emojiOwnedExpr + `, ` + expiryExpr + `
	          FROM emojis e` + e.ownedJoinNow() + `
	         WHERE e.id = $2`
}

// scanEmoji reads one row selected with emojiColumns followed by is_active,
// emojiOwnedExpr and expiryExpr.
func scanEmoji(row pgx.Row) (Emoji, bool, error) {
	var em Emoji
	var active bool
	err := row.Scan(&em.ID, &em.Name, &em.URL, &em.AssetFormat, &em.Currency, &em.Type, &em.Cost,
		&em.DurationDays, &em.DurationHours, &em.SortOrder, &active, &em.Owned, &em.ExpiresAt)
	return em, active, err
}

// List returns every emoji still on offer, in catalogue order (sort_order,
// then id), each marked with whether this player may send it. userID may be ""
// for an unauthenticated caller. Retired rows are left out: the shelf and the
// table's picker are what it draws, and a retired emoji can be neither bought
// nor sent.
func (e *Emojis) List(ctx context.Context, userID string) ([]Emoji, error) {
	rows, err := e.db.Pool.Query(ctx,
		`SELECT `+emojiColumns+`, e.is_active, `+emojiOwnedExpr+`, `+expiryExpr+`
		   FROM emojis e`+e.ownedJoinNow()+`
		  WHERE e.is_active
		  ORDER BY e.sort_order, e.id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	// Never nil: the wire contract is {"emojis": []} on an empty catalogue —
	// which is what a fresh database has, the seed holding no emoji — and a
	// nil slice marshals to null.
	emojis := []Emoji{}
	for rows.Next() {
		em, _, err := scanEmoji(rows)
		if err != nil {
			return nil, err
		}
		emojis = append(emojis, em)
	}
	return emojis, rows.Err()
}

// Find is one emoji by id, with this viewer's ownership resolved, whether or
// not it is still on offer — the second result says. A missing row is
// ErrEmojiUnknown.
func (e *Emojis) Find(ctx context.Context, userID string, id int64) (Emoji, bool, error) {
	em, active, err := scanEmoji(e.db.Pool.QueryRow(ctx, e.selectEmoji(), userID, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return Emoji{}, false, ErrEmojiUnknown
	}
	if err != nil {
		return Emoji{}, false, err
	}
	return em, active, nil
}

// Owns answers whether a player may SEND an emoji now, and with what: the
// socket layer's check for chat:emoji, made against the database on every send
// in one query. It returns the row when the emoji is active and either free
// or theirs on an unexpired rental, and otherwise, in this order,
// ErrEmojiUnknown (no such row), ErrEmojiInactive (retired) or ErrEmojiLocked
// (premium, and not bought or run out).
func (e *Emojis) Owns(ctx context.Context, userID string, emojiID int64) (Emoji, error) {
	em, active, err := e.Find(ctx, userID, emojiID)
	switch {
	case err != nil:
		return Emoji{}, err
	case !active:
		return Emoji{}, ErrEmojiInactive
	case !em.Owned:
		return Emoji{}, ErrEmojiLocked
	}
	return em, nil
}

// EmojiPurchase is what Buy did: PicturePurchase for an emoji.
type EmojiPurchase struct {
	Emoji Emoji
	// Charged is false when the player already owned it, running: success,
	// nothing spent this time.
	Charged bool
	// Spent is what left the wallet, in the emoji's Currency.
	Spent int64
	// Balance is the chip balance afterwards; a diamond or hammer buy leaves
	// it as it was.
	Balance int64
	User    *User
}

// Buy unlocks a premium emoji for a player, paying for it out of the wallet
// its currency names, in one transaction under the wallet lock — the
// transaction Pictures.Buy runs, against the emoji tables:
//
//	SELECT chips, diamond, hammer FROM users WHERE id = $1 FOR UPDATE
//	(read the catalogue row and the ownership row under that lock)
//	COIN:            INSERT chip_ledger (action_id 'emoji:<user>:<id>:<n>',
//	                 reason emoji_purchase, delta -cost); UPDATE users SET chips
//	DIAMOND/HAMMER:  UPDATE users SET diamond|hammer = … - cost (no ledger row)
//	INSERT user_emojis … ON CONFLICT DO UPDATE (the renewal)
//
// A COIN price is a chip_ledger row and a wallet delta together, so
// SUM(chip_ledger.delta) == users.chips still holds; a DIAMOND or HAMMER price
// is a delta on its users column with the ownership row as its receipt. The
// row lock serialises double taps and the owned check makes the second an
// idempotent success (charged:false); the UNIQUE action_id catches a replay
// whose first commit was acknowledged into a dropped connection. n counts that
// pair's purchases, so a lapsed rental is bought again — renewed from now —
// on an action id of its own.
//
// A seated player buys through BuyAtTable: their chips may only move at the
// three hand checkpoints (CLAUDE.md §5.1).
func (e *Emojis) Buy(ctx context.Context, userID string, emojiID int64) (*EmojiPurchase, error) {
	return e.buy(ctx, userID, emojiID, false)
}

// BuyAtTable is Buy for a seated player: a DIAMOND or HAMMER emoji sells as in
// the lobby — no seat holds either count — and a COIN one is refused with
// ErrEmojiAtTable, decided inside the transaction from the row about to be
// charged, so a re-price between an earlier look and the charge cannot slip a
// chip debit past it.
func (e *Emojis) BuyAtTable(ctx context.Context, userID string, emojiID int64) (*EmojiPurchase, error) {
	return e.buy(ctx, userID, emojiID, true)
}

func (e *Emojis) buy(ctx context.Context, userID string, emojiID int64, atTable bool) (*EmojiPurchase, error) {
	stamp := now(e.clock)
	out := &EmojiPurchase{}

	err := e.db.WithTx(ctx, func(tx pgx.Tx) error {
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
		em, active, err := scanEmoji(tx.QueryRow(ctx, e.selectEmoji(), userID, emojiID))
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrEmojiUnknown
		}
		if err != nil {
			return err
		}

		out.Emoji = em
		switch {
		case !active:
			return ErrEmojiInactive
		case em.Free():
			return ErrEmojiFree
		case em.Owned:
			// Already theirs, and not yet run out: idempotent success.
			out.Charged, out.Spent, out.Balance = false, 0, chips
			return nil
		case atTable && em.PaidInChips():
			return ErrEmojiAtTable
		}
		switch em.Currency {
		case PictureCurrencyDiamond:
			if diamond < em.Cost {
				return &EmojiShortage{Currency: PictureCurrencyDiamond, Cost: em.Cost}
			}
		case PictureCurrencyHammer:
			if hammer < em.Cost {
				return &EmojiShortage{Currency: PictureCurrencyHammer, Cost: em.Cost}
			}
		default:
			if chips < em.Cost {
				return &EmojiShortage{Currency: PictureCurrencyCoin, Cost: em.Cost}
			}
		}

		// Purchases so far, read WITHOUT the expiry filter, so a renewal's
		// action id never repeats the first purchase's (Pictures.buy says
		// what went wrong when it was read off the ownership join).
		var priorPurchases int
		if err := tx.QueryRow(ctx,
			`SELECT COALESCE(max(purchases), 0) FROM user_emojis WHERE user_id = $1 AND emoji_id = $2`,
			userID, emojiID).Scan(&priorPurchases); err != nil {
			return err
		}

		balance := chips
		switch em.Currency {
		case PictureCurrencyDiamond:
			if _, err := tx.Exec(ctx,
				`UPDATE users SET diamond = diamond - $2, updated_at = $3 WHERE id = $1`,
				userID, em.Cost, stamp); err != nil {
				return err
			}
		case PictureCurrencyHammer:
			if _, err := tx.Exec(ctx,
				`UPDATE users SET hammer = hammer - $2, updated_at = $3 WHERE id = $1`,
				userID, em.Cost, stamp); err != nil {
				return err
			}
		default:
			balance = chips - em.Cost
			actionID := fmt.Sprintf("emoji:%s:%d:%d", userID, emojiID, priorPurchases+1)
			if err := appendLedger(ctx, tx, userID, "", actionID,
				-em.Cost, balance, game.LedgerReasonEmojiPurchase, stamp); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx,
				`UPDATE users SET chips = $2, updated_at = $3 WHERE id = $1`, userID, balance, stamp); err != nil {
				return err
			}
		}

		// A rental runs from now, not from what was left of a lapsed one.
		var expiresAt int64
		if term := int64(em.DurationDays)*DayMs + int64(em.DurationHours)*HourMs; term > 0 {
			expiresAt = stamp + term
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO user_emojis (user_id, emoji_id, acquired_at, expires_at, purchases)
			 VALUES ($1, $2, $3, $4, 1)
			 ON CONFLICT (user_id, emoji_id) DO UPDATE
			    SET acquired_at = EXCLUDED.acquired_at,
			        expires_at  = EXCLUDED.expires_at,
			        purchases   = user_emojis.purchases + 1`,
			userID, emojiID, stamp, expiresAt); err != nil {
			return err
		}

		out.Emoji.Owned = true
		out.Emoji.ExpiresAt = expiresAt
		out.Charged, out.Spent, out.Balance = true, em.Cost, balance
		return nil
	})

	// A replay whose first commit landed but whose answer was lost: the money
	// moved and the emoji is theirs, so this is the success it is.
	if err != nil && isUniqueViolationOn(err, "action_id") {
		user, ferr := e.users.FindByID(ctx, userID)
		if ferr != nil {
			return nil, ferr
		}
		if user == nil {
			return nil, game.Errorf(game.CodeUnknownUser, "unknown user %s", userID)
		}
		em, _, ferr := e.Find(ctx, userID, emojiID)
		if ferr != nil {
			return nil, ferr
		}
		return &EmojiPurchase{Emoji: em, Charged: false, Balance: user.Chips, User: user}, nil
	}
	if err != nil {
		return nil, err
	}

	user, err := e.users.FindByID(ctx, userID)
	if err != nil {
		return nil, err
	}
	out.User = user
	return out, nil
}
