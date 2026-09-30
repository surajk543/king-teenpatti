package db

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// The rewards this server can give a player outside a hand — the vocabulary
// the Lucky Draw (lucky_draw_slots.reward_type), the welcome
// (welcome_rewards.reward_type) and the reward programs
// (reward_program_rewards.reward_type) share, written the same way in each
// table. TEXT in the database and checked here, never by an ENUM or a closed
// CHECK: a later kind of reward is a row and a release, never a change to a
// constraint every database already carries. A row of a kind a build does
// not grant is left out with a logged reason by the store that reads it.
const (
	// RewardChips, RewardDiamond, RewardHammer and RewardMissile carry an
	// amount (reward_value > 0) for that wallet.
	RewardChips   = "CHIPS"
	RewardDiamond = "DIAMOND"
	RewardHammer  = "HAMMER"
	RewardMissile = "MISSILE"
	// RewardProfilePicture, RewardTablePicture and RewardEmoji name a
	// catalogue row by its id in reward_ref_id (as text); RewardBadge names a
	// badge by its code (badges.code, the table's key).
	RewardProfilePicture = "PROFILE_PICTURE"
	RewardTablePicture   = "TABLE_PICTURE"
	RewardEmoji          = "EMOJI"
	RewardBadge          = "BADGE"
	// RewardNone gives nothing: a Lucky Draw slot that pays nothing, a day of
	// a reward program with nothing on it (its claim is still recorded, so a
	// streak keeps counting through it).
	RewardNone = "NO_REWARD"
)

// Grant is one reward about to be given: its kind, the amount of a wallet
// reward, and the catalogue row of an item reward, resolved for the player
// (Owned and ExpiresAt for a picture or an emoji, Held for a badge), which
// grantReward updates to what the player holds afterwards.
type Grant struct {
	Type         string
	Value        *int64
	Picture      *Picture
	TablePicture *TablePicture
	Emoji        *Emoji
	Badge        *BadgeItem
}

// amount is the wallet reward's amount, 0 for an item.
func (g *Grant) amount() int64 {
	if g.Value == nil {
		return 0
	}
	return *g.Value
}

// grantReward gives the player the reward, inside the caller's transaction
// and under its wallet lock (chips is the balance the lock read), and reports
// whether an item reward was one they already had — the ONE grant path of
// every reward given outside a hand (the Lucky Draw's prize, a reward
// program's day):
//
//   - CHIPS: the wallet and a chip_ledger row (reason as given, action_id
//     key), so SUM(chip_ledger.delta) == users.chips still holds — the
//     invariant every chip movement keeps (CLAUDE.md §5.1).
//   - DIAMOND, HAMMER, MISSILE: a delta on the users column, never ledgered,
//     as a hammer pack's hammers and a missile trade are; the caller's own
//     record (the spin, the claim) is the receipt.
//   - NO_REWARD: nothing.
//   - PROFILE_PICTURE, TABLE_PICTURE, EMOJI: the ownership row a purchase
//     would write, for the term the shop would sell it for, counted from now
//     — and NOT put on or picked: what a player wears, lays or sends stays
//     their choice. One already theirs (free, or bought and running) is left
//     exactly as it is: no second row — the key forbids one — and no longer
//     rental; a lapsed rental is renewed in place. `purchases` is not raised:
//     a reward is not a purchase.
//   - BADGE: the grant a purchase would write (user_badges), for the badge's
//     validity; a grant still running is EXTENDED by it, as
//     CreditBadgePurchase extends one, a lapsed grant starts now, and one
//     held for ever is left as it is.
func grantReward(ctx context.Context, tx pgx.Tx, userID, key string, chips int64, g *Grant, at int64, reason string) (bool, error) {
	switch g.Type {
	case RewardNone:
		return false, nil
	case RewardChips:
		balance := chips + g.amount()
		if _, err := tx.Exec(ctx,
			`UPDATE users SET chips = $2, updated_at = $3 WHERE id = $1`, userID, balance, at); err != nil {
			return false, err
		}
		return false, appendLedger(ctx, tx, userID, "", key, g.amount(), balance, reason, at)
	case RewardDiamond:
		_, err := tx.Exec(ctx, `UPDATE users SET diamond = diamond + $2, updated_at = $3 WHERE id = $1`, userID, g.amount(), at)
		return false, err
	case RewardHammer:
		_, err := tx.Exec(ctx, `UPDATE users SET hammer = hammer + $2, updated_at = $3 WHERE id = $1`, userID, g.amount(), at)
		return false, err
	case RewardMissile:
		_, err := tx.Exec(ctx, `UPDATE users SET missile = missile + $2, updated_at = $3 WHERE id = $1`, userID, g.amount(), at)
		return false, err
	case RewardProfilePicture:
		pic := g.Picture
		if pic == nil {
			return false, fmt.Errorf("grant: profile picture reward with no picture")
		}
		if pic.Free() || pic.Owned {
			return true, nil
		}
		expiresAt := rentalEnd(pic.DurationDays, pic.DurationHours, at)
		if _, err := tx.Exec(ctx,
			`INSERT INTO user_profile_pictures (user_id, profile_picture_id, acquired_at, expires_at, purchases)
			 VALUES ($1, $2, $3, $4, 1)
			 ON CONFLICT (user_id, profile_picture_id) DO UPDATE
			    SET acquired_at = EXCLUDED.acquired_at,
			        expires_at  = EXCLUDED.expires_at`,
			userID, pic.ID, at, expiresAt); err != nil {
			return false, err
		}
		pic.Owned, pic.ExpiresAt = true, expiresAt
		return false, nil
	case RewardTablePicture:
		pic := g.TablePicture
		if pic == nil {
			return false, fmt.Errorf("grant: table picture reward with no picture")
		}
		if pic.Free() || pic.Owned {
			return true, nil
		}
		expiresAt := rentalEnd(pic.DurationDays, pic.DurationHours, at)
		if _, err := tx.Exec(ctx,
			`INSERT INTO user_table_pictures (user_id, table_picture_id, acquired_at, expires_at, purchases)
			 VALUES ($1, $2, $3, $4, 1)
			 ON CONFLICT (user_id, table_picture_id) DO UPDATE
			    SET acquired_at = EXCLUDED.acquired_at,
			        expires_at  = EXCLUDED.expires_at`,
			userID, pic.ID, at, expiresAt); err != nil {
			return false, err
		}
		pic.Owned, pic.ExpiresAt = true, expiresAt
		return false, nil
	case RewardEmoji:
		em := g.Emoji
		if em == nil {
			return false, fmt.Errorf("grant: emoji reward with no emoji")
		}
		if em.Free() || em.Owned {
			return true, nil
		}
		expiresAt := rentalEnd(em.DurationDays, em.DurationHours, at)
		if _, err := tx.Exec(ctx,
			`INSERT INTO user_emojis (user_id, emoji_id, acquired_at, expires_at, purchases)
			 VALUES ($1, $2, $3, $4, 1)
			 ON CONFLICT (user_id, emoji_id) DO UPDATE
			    SET acquired_at = EXCLUDED.acquired_at,
			        expires_at  = EXCLUDED.expires_at`,
			userID, em.ID, at, expiresAt); err != nil {
			return false, err
		}
		em.Owned, em.ExpiresAt = true, expiresAt
		return false, nil
	case RewardBadge:
		b := g.Badge
		if b == nil {
			return false, fmt.Errorf("grant: badge reward with no badge")
		}
		if b.Held && b.ExpiresAt == 0 {
			// Held for ever already: there is nothing a grant could add.
			return true, nil
		}
		expires := BadgeExpiry(b.current, b.ValidityDays, at)
		if _, err := tx.Exec(ctx,
			`INSERT INTO user_badges (user_id, badge_code, granted_at, expires_at)
			 VALUES ($1, $2, $3, $4)
			 ON CONFLICT (user_id, badge_code) DO UPDATE
			   SET granted_at = EXCLUDED.granted_at, expires_at = EXCLUDED.expires_at`,
			userID, b.Code, at, expires); err != nil {
			return false, err
		}
		b.Held, b.ExpiresAt, b.current = true, expires, &expires
		return false, nil
	}
	return false, fmt.Errorf("grant: cannot give a %q reward", g.Type)
}

// BadgeItem is a badge as a reward names it: the catalogue row, and
// whether this viewer holds it now (Held) and until when (ExpiresAt, epoch
// ms; 0 for ever) — nothing of anybody else's.
type BadgeItem struct {
	Code         string `json:"code"`
	Title        string `json:"title"`
	Icon         string `json:"icon"`
	ValidityDays int    `json:"validityDays"`
	// AssetURL and AssetFormat are the badge's art (a Royal badge's Lottie);
	// ABSENT on a badge shown by its icon alone.
	AssetURL    string `json:"assetUrl,omitempty"`
	AssetFormat string `json:"assetFormat,omitempty"`
	Held        bool   `json:"held"`
	ExpiresAt   int64  `json:"expiresAt"`
	// current is the viewer's user_badges.expires_at as stored, nil with no
	// row: what BadgeExpiry extends.
	current *int64
}

// findBadgeIn is one badge by code with this viewer's grant of it resolved at
// `at`, whether or not it is on offer (active).
func findBadgeIn(ctx context.Context, q queryer, userID, code string, at int64) (b BadgeItem, active, found bool, err error) {
	var assetURL, assetFormat *string
	var current *int64
	err = q.QueryRow(ctx,
		`SELECT b.code, b.title, b.icon, b.validity_days, b.is_active, b.asset_url, b.asset_format, ub.expires_at
		   FROM badges b
		   LEFT JOIN user_badges ub ON ub.badge_code = b.code AND ub.user_id = $1
		  WHERE b.code = $2`, userID, code).
		Scan(&b.Code, &b.Title, &b.Icon, &b.ValidityDays, &active, &assetURL, &assetFormat, &current)
	if errors.Is(err, pgx.ErrNoRows) {
		return BadgeItem{}, false, false, nil
	}
	if err != nil {
		return BadgeItem{}, false, false, err
	}
	if assetURL != nil {
		b.AssetURL = *assetURL
	}
	if assetFormat != nil {
		b.AssetFormat = *assetFormat
	}
	b.current = current
	if current != nil && (*current == 0 || *current > at) {
		b.Held, b.ExpiresAt = true, *current
	}
	return b, active, true, nil
}
