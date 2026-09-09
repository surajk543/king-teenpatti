package db

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// Reward constants (db/users.js).
const (
	// MilestoneReward is granted when a "hands played" milestone is collected
	// (requirement 17).
	MilestoneReward int64 = 25000
	// MilestoneEvery is the hands-played step between milestones.
	MilestoneEvery = 25
	// TimedBonusReward is the 4-hourly bonus (requirement 18).
	TimedBonusReward int64 = 10000
	// TimedBonusInterval is how long the timed bonus takes to recharge.
	TimedBonusInterval = 4 * time.Hour
)

// Provider values (users.provider CHECK).
const (
	ProviderGoogle   = "google"
	ProviderFacebook = "facebook"
	ProviderGuest    = "guest"
)

// Rewards is user.rewards on the wire (publicUser).
type Rewards struct {
	// MilestoneAvailable: milestoneFor(hands_played) > milestone_claimed.
	MilestoneAvailable bool `json:"milestoneAvailable"`
	// MilestoneAt is floor(hands_played / 25) * 25.
	MilestoneAt     int   `json:"milestoneAt"`
	MilestoneReward int64 `json:"milestoneReward"`
	MilestoneEvery  int   `json:"milestoneEvery"`
	// HandsToNextMilestone is 25 - (hands_played % 25) — NOTE it says 25, not
	// 0, at an exact multiple (CLAUDE.md §12.2); clients use MilestoneAvailable.
	HandsToNextMilestone int `json:"handsToNextMilestone"`
	// BonusReadyAt is next_bonus_at (epoch ms); 0 = ready now.
	BonusReadyAt    int64 `json:"bonusReadyAt"`
	BonusAvailable  bool  `json:"bonusAvailable"` // now >= BonusReadyAt
	BonusReward     int64 `json:"bonusReward"`
	BonusIntervalMs int64 `json:"bonusIntervalMs"`
}

// User is the account as every client sees it (users.js publicUser) — the
// `user` of POST /api/auth/login, GET /api/auth/me, the reward and profile
// responses and session:ready. Field order and names are the wire contract.
type User struct {
	ID          string  `json:"id"`
	Provider    string  `json:"provider"`
	DisplayName string  `json:"displayName"`
	Email       *string `json:"email"` // null for guests
	// AvatarURL is avatar_choice if set, else avatar_url (a picture chosen
	// in-game wins over the provider's); null when neither.
	AvatarURL *string `json:"avatarUrl"`
	// ProviderAvatarURL is the raw avatar_url column.
	ProviderAvatarURL *string `json:"providerAvatarUrl"`
	AvatarChoice      *string `json:"avatarChoice"`
	Chips             int64   `json:"chips"`
	HandsPlayed       int     `json:"handsPlayed"`
	HandsWon          int     `json:"handsWon"`
	HandsLost         int     `json:"handsLost"`
	HandsLeftMid      int     `json:"handsLeftMid"`
	TotalWinnings     int64   `json:"totalWinnings"`
	BiggestPot        int64   `json:"biggestPot"`
	Rewards           Rewards `json:"rewards"`
	CreatedAt         int64   `json:"createdAt"`   // epoch ms
	LastLoginAt       int64   `json:"lastLoginAt"` // epoch ms
}

// Player converts to the seat-level view the RoomManager needs.
func (u *User) Player() game.Player {
	return game.Player{ID: u.ID, DisplayName: u.DisplayName, AvatarURL: u.AvatarURL, Chips: u.Chips}
}

// Profile is a verified login identity (auth providers → UpsertFromProfile).
type Profile struct {
	Provider       string // ProviderGoogle | ProviderFacebook | ProviderGuest
	ProviderUserID string // Google sub | Facebook id | sha256 of the device id
	DisplayName    string
	Email          *string
	AvatarURL      *string
}

// RewardResult is what the two claim endpoints return. Claimed=false carries
// Reason ("not_available" | "not_ready") and, for the timed bonus, ReadyAt;
// Claimed=true carries Amount and Milestone (milestone) or ReadyAt (bonus).
// The HTTP layer maps Claimed=false to 409 — see auth.Handler.
type RewardResult struct {
	Claimed   bool   `json:"claimed"`
	Reason    string `json:"reason,omitempty"`
	Amount    int64  `json:"amount,omitempty"`
	Milestone int    `json:"milestone,omitempty"`
	ReadyAt   int64  `json:"readyAt,omitempty"`
	User      *User  `json:"user"`
}

// Reward refusal reasons (RewardResult.Reason).
const (
	RewardNotAvailable = "not_available" // milestone: nothing new to collect
	RewardNotReady     = "not_ready"     // timed bonus: still recharging
)

// Display-name validation errors (users.js normalizeDisplayName throws
// Error(code)); auth.Handler maps them to 400 {error: code, message}.
var (
	ErrEmptyName   = errors.New("empty_name")
	ErrNameTooLong = errors.New("name_too_long")
	ErrInvalidName = errors.New("invalid_name")
)

// NamePattern is requirement 29's rule: starts with a letter or digit; then
// letters, digits, COMBINING MARKS and single spaces. \p{M} is essential —
// without it every Devanagari/Bengali/Gujarati/Gurmukhi name with a vowel
// sign is rejected.
var NamePattern = regexp.MustCompile(`^[\p{L}\p{N}][\p{L}\p{N}\p{M} ]*$`)

// NormalizeDisplayName trims, collapses internal whitespace to single spaces,
// then: empty → ErrEmptyName; more than maxLength UTF-16 code units →
// ErrNameTooLong (Node's `trimmed.length`, DECISIONS.md §4: an astral
// character counts 2); !NamePattern → ErrInvalidName. Whitespace is JS's `\s`
// class (isJSSpace), which is what both `trim()` and `/\s+/g` used.
func NormalizeDisplayName(raw string, maxLength int) (string, error) {
	trimmed := collapseJSSpace(strings.TrimFunc(raw, isJSSpace))
	if trimmed == "" {
		return "", ErrEmptyName
	}
	if utf16Length(trimmed) > maxLength {
		return "", ErrNameTooLong
	}
	if !NamePattern.MatchString(trimmed) {
		return "", ErrInvalidName
	}
	return trimmed, nil
}

// isJSSpace is JavaScript's `\s` (WhiteSpace + LineTerminator): Go's
// unicode.IsSpace plus U+FEFF (BOM), minus U+0085 (NEL), which JS does not
// count as whitespace (DECISIONS.md §4 "matching JS \s").
func isJSSpace(r rune) bool {
	if r == 0xFEFF {
		return true
	}
	if r == 0x85 {
		return false
	}
	return unicode.IsSpace(r)
}

// collapseJSSpace is `.replace(/\s+/g, ' ')`: every run of JS whitespace
// becomes one ASCII space.
func collapseJSSpace(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	inRun := false
	for _, r := range s {
		if isJSSpace(r) {
			if !inRun {
				b.WriteByte(' ')
				inRun = true
			}
			continue
		}
		inRun = false
		b.WriteRune(r)
	}
	return b.String()
}

// utf16Length is JavaScript's String.prototype.length: code points above
// U+FFFF are a surrogate pair and count 2.
func utf16Length(s string) int {
	n := 0
	for _, r := range s {
		if r >= 0x10000 {
			n += 2
		} else {
			n++
		}
	}
	return n
}

// Users is the account store (db/users.js).
type Users struct {
	db           *DB
	welcomeChips int64
	clock        func() time.Time
}

// NewUsers builds the store. welcomeChips is config.Game.WelcomeChips
// (requirement 5); clock nil → time.Now.
func NewUsers(d *DB, welcomeChips int64, clock func() time.Time) *Users {
	return &Users{db: d, welcomeChips: welcomeChips, clock: clock}
}

// queryer is the slice of *pgxpool.Pool and pgx.Tx the store reads through,
// so publicUser can be built inside and outside a transaction alike.
type queryer interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

// userColumns is every users column, in DDL order, so a row scans into
// userRow without depending on `SELECT *` column ordering.
const userColumns = `id, provider, provider_user_id, display_name, email, avatar_url, chips,
       hands_played, hands_won, hands_lost, hands_left_mid, total_winnings, biggest_pot,
       milestone_claimed, next_bonus_at, avatar_choice, created_at, updated_at, last_login_at`

// userRow is one users row as stored (snake_case columns).
type userRow struct {
	id, provider, providerUserID, displayName string
	email, avatarURL, avatarChoice            *string
	chips                                     int64
	handsPlayed, handsWon                     int
	handsLost, handsLeftMid                   int
	totalWinnings, biggestPot                 int64
	milestoneClaimed                          int
	nextBonusAt                               int64
	createdAt, updatedAt, lastLoginAt         int64
}

// scanUser scans one row selected with userColumns; pgx.ErrNoRows → nil, nil.
func scanUser(row pgx.Row) (*userRow, error) {
	var r userRow
	err := row.Scan(&r.id, &r.provider, &r.providerUserID, &r.displayName, &r.email, &r.avatarURL, &r.chips,
		&r.handsPlayed, &r.handsWon, &r.handsLost, &r.handsLeftMid, &r.totalWinnings, &r.biggestPot,
		&r.milestoneClaimed, &r.nextBonusAt, &r.avatarChoice, &r.createdAt, &r.updatedAt, &r.lastLoginAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &r, nil
}

// selectUser is Node's selectUser(client, id): SELECT … FROM users WHERE id = $1.
//
// A deleted account is invisible here, which is what makes deletion take
// effect immediately: a JWT is valid for 30 days, so a token minted before
// the account was deleted would otherwise keep working until it expired.
// Every authenticated path — RequireAuth and the socket handshake both — ends
// up in this query, and gets "unknown user" instead.
func selectUser(ctx context.Context, q queryer, id string) (*userRow, error) {
	return scanUser(q.QueryRow(ctx,
		`SELECT `+userColumns+` FROM users WHERE id = $1 AND deleted_at = 0`, id))
}

// publicUser is users.js publicUser(row): the wire object. bonusAvailable is
// evaluated now, at serialisation time, so two reads of one row can differ.
func (u *Users) publicUser(r *userRow) *User {
	if r == nil {
		return nil
	}
	milestone := MilestoneFor(r.handsPlayed)
	// A picture chosen in-game wins over the one the provider gave us.
	// JS `avatar_choice || avatar_url`: an empty-string choice falls through.
	avatarURL := r.avatarURL
	if r.avatarChoice != nil && *r.avatarChoice != "" {
		avatarURL = r.avatarChoice
	}
	return &User{
		ID:                r.id,
		Provider:          r.provider,
		DisplayName:       r.displayName,
		Email:             r.email,
		AvatarURL:         avatarURL,
		ProviderAvatarURL: r.avatarURL,
		AvatarChoice:      r.avatarChoice,
		Chips:             r.chips,
		HandsPlayed:       r.handsPlayed,
		HandsWon:          r.handsWon,
		HandsLost:         r.handsLost,
		HandsLeftMid:      r.handsLeftMid,
		TotalWinnings:     r.totalWinnings,
		BiggestPot:        r.biggestPot,
		Rewards: Rewards{
			MilestoneAvailable:   milestone > r.milestoneClaimed,
			MilestoneAt:          milestone,
			MilestoneReward:      MilestoneReward,
			MilestoneEvery:       MilestoneEvery,
			HandsToNextMilestone: MilestoneEvery - (r.handsPlayed % MilestoneEvery),
			BonusReadyAt:         r.nextBonusAt,
			BonusAvailable:       now(u.clock) >= r.nextBonusAt,
			BonusReward:          TimedBonusReward,
			BonusIntervalMs:      TimedBonusInterval.Milliseconds(),
		},
		CreatedAt:   r.createdAt,
		LastLoginAt: r.lastLoginAt,
	}
}

// FindByID returns the user or nil, nil when absent (SELECT * FROM users
// WHERE id = $1). The socket layer calls this on EVERY connect and every
// join, so keep it one indexed query.
func (u *Users) FindByID(ctx context.Context, id string) (*User, error) {
	row, err := selectUser(ctx, u.db.Pool, id)
	if err != nil {
		return nil, err
	}
	return u.publicUser(row), nil
}

// FindByProvider looks up by (provider, provider_user_id); nil, nil when absent.
func (u *Users) FindByProvider(ctx context.Context, provider, providerUserID string) (*User, error) {
	row, err := scanUser(u.db.Pool.QueryRow(ctx,
		`SELECT `+userColumns+` FROM users WHERE provider = $1 AND provider_user_id = $2
		   AND deleted_at = 0`,
		provider, providerUserID))
	if err != nil {
		return nil, err
	}
	return u.publicUser(row), nil
}

// upsertAttempts bounds the retry of a first login that lost the race to an
// identical concurrent first login (DECISIONS.md §5).
const upsertAttempts = 5

// UpsertFromProfile finds or creates the account behind a verified profile
// (requirements 1, 2, 5, 7). One transaction: SELECT … FOR UPDATE by
// provider identity; if found UPDATE display_name = profile.DisplayName (or
// the existing name when empty — NOTE this overwrites any in-game rename on
// every login, a known unresolved issue vs requirement 29), email =
// COALESCE($2, email), avatar_url = COALESCE($3, avatar_url), updated_at =
// last_login_at = now → isNew=false. Else INSERT users (id util.UUID(),
// chips = welcomeChips, created/updated/last_login = now) and the welcome
// ledger row (hand_id NULL, action_id NULL, delta = balance = welcomeChips,
// reason welcome_bonus) → isNew=true.
//
// Two simultaneous first logins for one identity both see no row (FOR UPDATE
// locks nothing when there is nothing to lock) and both INSERT; the loser's
// unique violation on (provider, provider_user_id) is caught here and the
// whole transaction is retried, which now finds the winner's row and takes
// the UPDATE path — so exactly one account and one welcome_bonus row ever
// exist (DECISIONS.md §5; Node answered that request with HTTP 500).
func (u *Users) UpsertFromProfile(ctx context.Context, p Profile) (user *User, isNew bool, err error) {
	// Captured before BEGIN, as Node does (`const timestamp = now()`).
	timestamp := now(u.clock)

	for attempt := 1; ; attempt++ {
		user, isNew, err = u.upsertOnce(ctx, p, timestamp)
		if err == nil {
			return user, isNew, nil
		}
		if attempt < upsertAttempts && isUniqueViolationOn(err, "provider_user_id") {
			continue
		}
		return nil, false, err
	}
}

// upsertOnce is one attempt at UpsertFromProfile's transaction.
func (u *Users) upsertOnce(ctx context.Context, p Profile, timestamp int64) (user *User, isNew bool, err error) {
	err = u.db.WithTx(ctx, func(tx pgx.Tx) error {
		existing, err := scanUser(tx.QueryRow(ctx,
			`SELECT `+userColumns+` FROM users WHERE provider = $1 AND provider_user_id = $2 FOR UPDATE`,
			p.Provider, p.ProviderUserID))
		if err != nil {
			return err
		}

		if existing != nil {
			displayName := p.DisplayName
			if displayName == "" {
				displayName = existing.displayName // Node: `profile.displayName || existing.display_name`
			}
			if _, err := tx.Exec(ctx, `UPDATE users
            SET display_name  = $1,
                email         = COALESCE($2, email),
                avatar_url    = COALESCE($3, avatar_url),
                updated_at    = $4,
                last_login_at = $4
          WHERE id = $5`,
				displayName, p.Email, p.AvatarURL, timestamp, existing.id); err != nil {
				return err
			}
			row, err := selectUser(ctx, tx, existing.id)
			if err != nil {
				return err
			}
			user, isNew = u.publicUser(row), false
			return nil
		}

		id := util.UUID()
		chips := u.welcomeChips

		if _, err := tx.Exec(ctx, `INSERT INTO users (id, provider, provider_user_id, display_name, email, avatar_url,
                          chips, created_at, updated_at, last_login_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $8, $8)`,
			id, p.Provider, p.ProviderUserID, p.DisplayName, p.Email, p.AvatarURL, chips, timestamp); err != nil {
			return err
		}

		// The insert and the welcome-grant ledger row go in one transaction
		// so a crash can never leave an account whose balance is not backed
		// by the ledger. Written even when welcomeChips is 0.
		if err := appendLedger(ctx, tx, id, "", "", chips, chips, game.LedgerReasonWelcomeBonus, timestamp); err != nil {
			return err
		}

		row, err := selectUser(ctx, tx, id)
		if err != nil {
			return err
		}
		user, isNew = u.publicUser(row), true
		return nil
	})
	if err != nil {
		return nil, false, err
	}
	return user, isNew, nil
}

// ApplyChipDelta adjusts a wallet with a matching ledger row, row locked,
// refusing a negative result (applyChipDelta). Not used by gameplay — grants,
// tooling and corrections only. Returns the new balance. Errors are plain
// errors, not GameErrors, as in Node: "unknown user <id>" / "insufficient
// chips for <id>". handID/actionID "" → NULL.
func (u *Users) ApplyChipDelta(ctx context.Context, userID string, delta int64, reason, handID, actionID string) (int64, error) {
	var balance int64
	err := u.db.WithTx(ctx, func(tx pgx.Tx) error {
		var chips int64
		err := tx.QueryRow(ctx, `SELECT chips FROM users WHERE id = $1 FOR UPDATE`, userID).Scan(&chips)
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("unknown user %s", userID)
		}
		if err != nil {
			return err
		}

		balance = chips + delta
		if balance < 0 {
			return fmt.Errorf("insufficient chips for %s", userID)
		}

		timestamp := now(u.clock) // Node captures it after the lock here
		if _, err := tx.Exec(ctx, `UPDATE users SET chips = $1, updated_at = $2 WHERE id = $3`, balance, timestamp, userID); err != nil {
			return err
		}
		return appendLedger(ctx, tx, userID, handID, actionID, delta, balance, reason, timestamp)
	})
	if err != nil {
		return 0, err
	}
	return balance, nil
}

// ClaimMilestoneReward (requirement 17): lock the row; milestone =
// floor(hands_played/25)*25; if milestone <= milestone_claimed → {Claimed
// false, Reason "not_available", User}. Else chips += MilestoneReward,
// milestone_claimed = milestone, ledger row (action_id
// "<userId>:milestone:<milestone>", reason milestone_reward) → {Claimed true,
// Amount, Milestone, User}. Unknown user → error.
//
// milestone_claimed jumps straight to the current milestone: claiming at 75
// hands after last claiming at 25 pays once — the skipped 50 is forfeited.
func (u *Users) ClaimMilestoneReward(ctx context.Context, userID string) (*RewardResult, error) {
	var result *RewardResult
	err := u.db.WithTx(ctx, func(tx pgx.Tx) error {
		row, err := scanUser(tx.QueryRow(ctx, `SELECT `+userColumns+` FROM users WHERE id = $1 FOR UPDATE`, userID))
		if err != nil {
			return err
		}
		if row == nil {
			return fmt.Errorf("unknown user %s", userID)
		}

		milestone := MilestoneFor(row.handsPlayed)
		if milestone <= row.milestoneClaimed {
			result = &RewardResult{Claimed: false, Reason: RewardNotAvailable, User: u.publicUser(row)}
			return nil
		}

		timestamp := now(u.clock)
		balance := row.chips + MilestoneReward

		if _, err := tx.Exec(ctx, `UPDATE users SET chips = $1, milestone_claimed = $2, updated_at = $3 WHERE id = $4`,
			balance, milestone, timestamp, userID); err != nil {
			return err
		}
		// The deterministic action id makes the same milestone unrepeatable at
		// the database even if the milestone_claimed check were bypassed.
		actionID := fmt.Sprintf("%s:milestone:%d", userID, milestone)
		if err := appendLedger(ctx, tx, userID, "", actionID, MilestoneReward, balance, game.LedgerReasonMilestoneReward, timestamp); err != nil {
			return err
		}

		fresh, err := selectUser(ctx, tx, userID)
		if err != nil {
			return err
		}
		result = &RewardResult{Claimed: true, Amount: MilestoneReward, Milestone: milestone, User: u.publicUser(fresh)}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return result, nil
}

// ClaimTimedBonus (requirement 18): lock the row; if now < next_bonus_at →
// {Claimed false, Reason "not_ready", ReadyAt next_bonus_at, User}. Else
// chips += TimedBonusReward, next_bonus_at = now + 4h, ledger row (action_id
// NULL, reason timed_bonus) → {Claimed true, Amount, ReadyAt, User}.
//
// The next unlock time lives in the database, so the countdown survives a
// restart and cannot be reset by reinstalling the client.
func (u *Users) ClaimTimedBonus(ctx context.Context, userID string) (*RewardResult, error) {
	var result *RewardResult
	err := u.db.WithTx(ctx, func(tx pgx.Tx) error {
		row, err := scanUser(tx.QueryRow(ctx, `SELECT `+userColumns+` FROM users WHERE id = $1 FOR UPDATE`, userID))
		if err != nil {
			return err
		}
		if row == nil {
			return fmt.Errorf("unknown user %s", userID)
		}

		timestamp := now(u.clock)
		if timestamp < row.nextBonusAt {
			result = &RewardResult{Claimed: false, Reason: RewardNotReady, ReadyAt: row.nextBonusAt, User: u.publicUser(row)}
			return nil
		}

		balance := row.chips + TimedBonusReward
		readyAt := timestamp + TimedBonusInterval.Milliseconds()

		if _, err := tx.Exec(ctx, `UPDATE users SET chips = $1, next_bonus_at = $2, updated_at = $3 WHERE id = $4`,
			balance, readyAt, timestamp, userID); err != nil {
			return err
		}
		// No action_id: the next_bonus_at check under the row lock is the guard.
		if err := appendLedger(ctx, tx, userID, "", "", TimedBonusReward, balance, game.LedgerReasonTimedBonus, timestamp); err != nil {
			return err
		}

		fresh, err := selectUser(ctx, tx, userID)
		if err != nil {
			return err
		}
		result = &RewardResult{Claimed: true, Amount: TimedBonusReward, ReadyAt: readyAt, User: u.publicUser(fresh)}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return result, nil
}

// SetDisplayName updates display_name (already normalised) and returns the
// fresh user. A plain UPDATE outside any transaction, then FindByID (Node).
func (u *Users) SetDisplayName(ctx context.Context, userID, displayName string) (*User, error) {
	if _, err := u.db.Pool.Exec(ctx, `UPDATE users SET display_name = $1, updated_at = $2 WHERE id = $3`,
		displayName, now(u.clock), userID); err != nil {
		return nil, err
	}
	return u.FindByID(ctx, userID)
}

// SetAvatarChoice sets avatar_choice ("/profiles/<file>" or nil to clear) and
// returns the fresh user.
func (u *Users) SetAvatarChoice(ctx context.Context, userID string, choice *string) (*User, error) {
	if _, err := u.db.Pool.Exec(ctx, `UPDATE users SET avatar_choice = $1, updated_at = $2 WHERE id = $3`,
		choice, now(u.clock), userID); err != nil {
		return nil, err
	}
	return u.FindByID(ctx, userID)
}

// DeletedDisplayName replaces the name on an account the player has deleted.
// Ledger rows keep pointing at the row, so it needs to read as gone rather
// than as blank.
const DeletedDisplayName = "Deleted player"

// DeleteAccount erases the person behind an account at their own request
// (Google Play requires apps that create accounts to offer this).
//
// It pseudonymises rather than deletes, and the schema forces that:
// chip_ledger.user_id REFERENCES users (id) ON DELETE CASCADE, so removing
// the row would silently take the money audit with it — the one record that
// is append-only precisely because it must never be lost. The row therefore
// stays, emptied of anything that identifies anyone.
//
// Erased: display name, email, both avatar fields, and the provider identity.
// Clearing the identity is what frees (provider, provider_user_id) for reuse,
// so the same device signing in afterwards gets a NEW account with a fresh
// welcome bonus instead of being handed the deleted one back.
//
// The wallet is emptied through a ledger row rather than by writing chips = 0
// directly, because SUM(chip_ledger.delta) == users.chips is the invariant
// the entire money model is audited against (CLAUDE.md §7.3). Zeroing the
// column on its own would break it for every account ever deleted, and the
// append-only trigger means it could never be repaired in place.
//
// Chips leave the economy here. That is the right answer: so has the player.
func (u *Users) DeleteAccount(ctx context.Context, userID string) error {
	return u.db.WithTx(ctx, func(tx pgx.Tx) error {
		var chips int64
		err := tx.QueryRow(ctx,
			`SELECT chips FROM users WHERE id = $1 AND deleted_at = 0 FOR UPDATE`, userID).Scan(&chips)
		if errors.Is(err, pgx.ErrNoRows) {
			// Already deleted, or never existed. Either way there is nothing
			// left to erase, and saying so is not an error the caller can act
			// on differently.
			return nil
		}
		if err != nil {
			return err
		}
		timestamp := now(u.clock)
		if chips > 0 {
			// action_id is unique per account, so a retried delete cannot
			// write the drop twice — the second attempt fails the unique
			// index rather than double-counting. It cannot fire in practice
			// (the account is invisible by then) but the ledger's rule is
			// that every row carries its own idempotency.
			if err := appendLedger(ctx, tx, userID, "", "delete:"+userID,
				-chips, 0, game.LedgerReasonAccountDeleted, timestamp); err != nil {
				return err
			}
		}
		_, err = tx.Exec(ctx, `
			UPDATE users
			   SET chips            = 0,
			       display_name     = $1,
			       email            = NULL,
			       avatar_url       = NULL,
			       avatar_choice    = NULL,
			       provider_user_id = $2,
			       deleted_at       = $3,
			       updated_at       = $3
			 WHERE id = $4`,
			DeletedDisplayName, "deleted:"+util.UUID(), timestamp, userID)
		return err
	})
}

// MilestoneFor is floor(handsPlayed / MilestoneEvery) * MilestoneEvery.
func MilestoneFor(handsPlayed int) int {
	return handsPlayed / MilestoneEvery * MilestoneEvery
}
