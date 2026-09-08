package db

import (
	"context"
	"errors"
	"regexp"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
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

// HandHistory is one row of GET /api/auth/me/hands (recentHands).
type HandHistory struct {
	ID        string                  `json:"id"`
	RoomID    string                  `json:"roomId"`
	HandNo    int                     `json:"handNo"`
	Pot       int64                   `json:"pot"`
	WinnerID  *string                 `json:"winnerId"`
	WinReason *string                 `json:"winReason"`
	EndedAt   int64                   `json:"endedAt"`
	Summary   []game.HandSummaryEntry `json:"summary"`
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
// then: empty → ErrEmptyName; more than maxLength runes → ErrNameTooLong;
// !NamePattern → ErrInvalidName. (Node counted UTF-16 units; runes here.)
func NormalizeDisplayName(raw string, maxLength int) (string, error) {
	panic("not ported: db.NormalizeDisplayName")
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

// FindByID returns the user or nil, nil when absent (SELECT * FROM users
// WHERE id = $1). The socket layer calls this on EVERY connect and every
// join, so keep it one indexed query.
func (u *Users) FindByID(ctx context.Context, id string) (*User, error) {
	panic("not ported: (*Users).FindByID")
}

// FindByProvider looks up by (provider, provider_user_id); nil, nil when absent.
func (u *Users) FindByProvider(ctx context.Context, provider, providerUserID string) (*User, error) {
	panic("not ported: (*Users).FindByProvider")
}

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
func (u *Users) UpsertFromProfile(ctx context.Context, p Profile) (user *User, isNew bool, err error) {
	panic("not ported: (*Users).UpsertFromProfile")
}

// ApplyChipDelta adjusts a wallet with a matching ledger row, row locked,
// refusing a negative result (applyChipDelta). Not used by gameplay — grants,
// tooling and corrections only. Returns the new balance.
func (u *Users) ApplyChipDelta(ctx context.Context, userID string, delta int64, reason, handID, actionID string) (int64, error) {
	panic("not ported: (*Users).ApplyChipDelta")
}

// RecentHands is GET /api/auth/me/hands (recentHands): hands the user has a
// ledger row for, newest ended first, at most limit.
//
//	SELECT DISTINCT ON (h.id) h.* FROM hands h JOIN chip_ledger l ON l.hand_id = h.id
//	 WHERE l.user_id = $1 ORDER BY h.id, h.ended_at DESC
//
// then sorted by ended_at desc in memory and sliced (as Node does).
func (u *Users) RecentHands(ctx context.Context, userID string, limit int) ([]HandHistory, error) {
	panic("not ported: (*Users).RecentHands")
}

// ClaimMilestoneReward (requirement 17): lock the row; milestone =
// floor(hands_played/25)*25; if milestone <= milestone_claimed → {Claimed
// false, Reason "not_available", User}. Else chips += MilestoneReward,
// milestone_claimed = milestone, ledger row (action_id
// "<userId>:milestone:<milestone>", reason milestone_reward) → {Claimed true,
// Amount, Milestone, User}. Unknown user → error.
func (u *Users) ClaimMilestoneReward(ctx context.Context, userID string) (*RewardResult, error) {
	panic("not ported: (*Users).ClaimMilestoneReward")
}

// ClaimTimedBonus (requirement 18): lock the row; if now < next_bonus_at →
// {Claimed false, Reason "not_ready", ReadyAt next_bonus_at, User}. Else
// chips += TimedBonusReward, next_bonus_at = now + 4h, ledger row (action_id
// NULL, reason timed_bonus) → {Claimed true, Amount, ReadyAt, User}.
func (u *Users) ClaimTimedBonus(ctx context.Context, userID string) (*RewardResult, error) {
	panic("not ported: (*Users).ClaimTimedBonus")
}

// SetDisplayName updates display_name (already normalised) and returns the
// fresh user.
func (u *Users) SetDisplayName(ctx context.Context, userID, displayName string) (*User, error) {
	panic("not ported: (*Users).SetDisplayName")
}

// SetAvatarChoice sets avatar_choice ("/profiles/<file>" or nil to clear) and
// returns the fresh user.
func (u *Users) SetAvatarChoice(ctx context.Context, userID string, choice *string) (*User, error) {
	panic("not ported: (*Users).SetAvatarChoice")
}

// MilestoneFor is floor(handsPlayed / MilestoneEvery) * MilestoneEvery.
func MilestoneFor(handsPlayed int) int {
	return handsPlayed / MilestoneEvery * MilestoneEvery
}
