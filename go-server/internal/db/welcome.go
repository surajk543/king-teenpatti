package db

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

// What a new account may be welcomed with (welcome_rewards.reward_type; owner,
// 30 Sep 2026: "new account will get how much coins, hammers, diamonds,
// profile_picture, emoji — this data should come from database, user might
// get some or all rewards"). TEXT in the database and checked here, never by a
// CHECK or an ENUM, as lucky_draw_slots.reward_type is: a later kind of welcome
// is a row and a release, never a change to a constraint every database already
// carries. A row of a kind this build does not know is left out of the grant
// with a logged reason (planWelcome).
const (
	// WelcomeRewardChips, …Diamond, …Hammer and …Missile are an amount
	// (reward_value > 0) added to that wallet; rows of one kind add up.
	WelcomeRewardChips   = "CHIPS"
	WelcomeRewardDiamond = "DIAMOND"
	WelcomeRewardHammer  = "HAMMER"
	WelcomeRewardMissile = "MISSILE"
	// WelcomeRewardProfilePicture, …TablePicture and …Emoji are a PREMIUM
	// catalogue row (reward_ref_id = its id as text) the new account owns from
	// its first moment, for the term the shop rents it for — never worn or
	// laid: that stays the player's choice.
	WelcomeRewardProfilePicture = "PROFILE_PICTURE"
	WelcomeRewardTablePicture   = "TABLE_PICTURE"
	WelcomeRewardEmoji          = "EMOJI"
)

// WelcomeChipsCode is the code of the welcome_rewards row the server writes at
// boot from WELCOME_CHIPS when the table has none (EnsureChipsRow). It is the
// one row the seed does not carry: a deployment's first boot puts its own
// .env's welcome there, and from then on the row decides.
const WelcomeChipsCode = "chips"

// welcomeChipsSortOrder places the chips row first, before the seed's
// diamonds (20), hammers (30) and missiles (40).
const welcomeChipsSortOrder = 10

// WelcomeGrant is what a new account was welcomed with — POST /api/auth/login's
// `welcome`, present exactly when the login created the account. The four
// wallets are the totals the account was inserted with (0 where no row gives
// any); each item is the catalogue row exactly as its catalogue route serves it
// (GET /api/profiles, /api/table-pictures, /api/emojis), owned, with the rental
// term it was granted for in ExpiresAt. The slices are never nil: a client
// reads `[]`, never null.
type WelcomeGrant struct {
	Chips         int64          `json:"chips"`
	Diamonds      int64          `json:"diamonds"`
	Hammers       int64          `json:"hammers"`
	Missiles      int64          `json:"missiles"`
	Pictures      []Picture      `json:"pictures"`
	TablePictures []TablePicture `json:"tablePictures"`
	Emojis        []Emoji        `json:"emojis"`
}

// NewWelcomeGrant is a grant of nothing, its lists empty (not nil).
func NewWelcomeGrant() *WelcomeGrant {
	return &WelcomeGrant{Pictures: []Picture{}, TablePictures: []TablePicture{}, Emojis: []Emoji{}}
}

// WelcomeLeftOut is a welcome_rewards row a new account was NOT given, and
// why: logged (`welcome reward left out`), never a refused login.
type WelcomeLeftOut struct {
	Code   string
	Type   string
	Reason string
}

// SignIn is a login's outcome (Users.SignIn): the account, whether this login
// created it, and — only then — what it was welcomed with.
type SignIn struct {
	User  *User
	IsNew bool
	// Welcome is set exactly when IsNew is.
	Welcome *WelcomeGrant
}

// Welcome is the welcome_rewards table: what a new account is given.
// Configuration, read afresh for every new account (no cache), so an owner's
// UPDATE applies to the very next one with no restart — the Lucky Draw's
// precedent.
type Welcome struct {
	db    *DB
	clock func() time.Time
}

// NewWelcome builds the store; clock nil → time.Now.
func NewWelcome(d *DB, clock func() time.Time) *Welcome {
	return &Welcome{db: d, clock: clock}
}

// WelcomeChipsRow is the chips row as EnsureChipsRow left it.
type WelcomeChipsRow struct {
	// Created: this call wrote the row (the table had none coded 'chips').
	Created bool
	// Type, Value and Active are the row's reward_type, reward_value (0 when
	// NULL) and is_active — an owner may have changed any of them.
	Type   string
	Value  int64
	Active bool
	// Total is the chips a new account gets now: every active CHIPS row the
	// grant would count, this one included.
	Total int64
}

// EnsureChipsRow writes the chips row — code 'chips', CHIPS, amount,
// sort_order 10 — when welcome_rewards has no row coded 'chips', and reports
// the row as it stands. It never changes a row that is there: after a
// deployment's first boot the ROW decides, and a later WELCOME_CHIPS is only
// compared with it (app.New warns when they differ). An amount of 0 writes
// the row switched off, so it is not left out with a WARN at every new
// account; a negative one is refused.
func (w *Welcome) EnsureChipsRow(ctx context.Context, amount int64) (WelcomeChipsRow, error) {
	if amount < 0 {
		return WelcomeChipsRow{}, fmt.Errorf("welcome chips must not be negative, got %d", amount)
	}
	var out WelcomeChipsRow
	err := w.db.WithTx(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx,
			`INSERT INTO welcome_rewards (code, reward_type, reward_value, is_active, sort_order)
			 VALUES ($1, $2, $3, $4, $5)
			 ON CONFLICT (code) DO NOTHING`,
			WelcomeChipsCode, WelcomeRewardChips, amount, amount > 0, welcomeChipsSortOrder)
		if err != nil {
			return err
		}
		out.Created = tag.RowsAffected() == 1
		var value *int64
		if err := tx.QueryRow(ctx,
			`SELECT reward_type, reward_value, is_active FROM welcome_rewards WHERE code = $1`,
			WelcomeChipsCode).Scan(&out.Type, &value, &out.Active); err != nil {
			return err
		}
		if value != nil {
			out.Value = *value
		}
		plan, err := planWelcome(ctx, tx, now(w.clock), false)
		if err != nil {
			return err
		}
		out.Total = plan.chips
		return nil
	})
	return out, err
}

// Chips is what the next new account would get in chips: the active CHIPS
// rows as the grant counts them. What session:ready's welcomeChips says,
// through WelcomeChipsCache.
func (w *Welcome) Chips(ctx context.Context) (int64, error) {
	var chips int64
	err := w.db.WithTx(ctx, func(tx pgx.Tx) error {
		plan, err := planWelcome(ctx, tx, now(w.clock), false)
		if err != nil {
			return err
		}
		chips = plan.chips
		return nil
	})
	return chips, err
}

// welcomeRow is one welcome_rewards row as stored.
type welcomeRow struct {
	code  string
	kind  string
	value *int64
	ref   *string
}

// welcomePlan is what a new account is about to be given: the wallets'
// totals, the catalogue rows to own, and the rows left out.
type welcomePlan struct {
	chips, diamonds, hammers, missiles int64
	pictures                           []Picture
	tables                             []TablePicture
	emojis                             []Emoji
	leftOut                            []WelcomeLeftOut
}

// planWelcome reads the ACTIVE welcome_rewards rows (sort_order, then id) and
// works out the grant they make now. A row it cannot grant is left out (the
// plan says why), never an error:
//
//   - a type this build does not know;
//   - CHIPS, DIAMOND, HAMMER or MISSILE with no amount, or 0; one that would
//     carry its wallet's total past what the column holds (int64 for chips,
//     INTEGER for the other three);
//   - PROFILE_PICTURE, TABLE_PICTURE or EMOJI whose reward_ref_id names no
//     catalogue row, a retired one, or a FREE one (every player has it
//     already), or the same row an earlier welcome reward already gives.
//
// withItems false works out the wallets alone and does not read the
// catalogues (what Chips needs).
func planWelcome(ctx context.Context, q queryer, at int64, withItems bool) (*welcomePlan, error) {
	rows, err := q.Query(ctx,
		`SELECT code, reward_type, reward_value, reward_ref_id
		   FROM welcome_rewards
		  WHERE is_active
		  ORDER BY sort_order, id`)
	if err != nil {
		return nil, err
	}
	// Read to the end before any other query: a transaction serves one
	// result at a time, and the catalogue reads below are queries of their own.
	var raw []welcomeRow
	for rows.Next() {
		var r welcomeRow
		if err := rows.Scan(&r.code, &r.kind, &r.value, &r.ref); err != nil {
			rows.Close()
			return nil, err
		}
		raw = append(raw, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	plan := &welcomePlan{pictures: []Picture{}, tables: []TablePicture{}, emojis: []Emoji{}}
	pictureBy := map[int64]string{}
	tableBy := map[int64]string{}
	emojiBy := map[int64]string{}
	for _, r := range raw {
		reason, err := plan.add(ctx, q, r, at, withItems, pictureBy, tableBy, emojiBy)
		if err != nil {
			return nil, err
		}
		if reason != "" {
			plan.leftOut = append(plan.leftOut, WelcomeLeftOut{Code: r.code, Type: r.kind, Reason: reason})
		}
	}
	return plan, nil
}

// add puts one row into the plan, answering why it must be left out ("" when
// it was added). The by maps remember which welcome reward already gives each
// catalogue row, so the same item named twice is granted once.
func (p *welcomePlan) add(ctx context.Context, q queryer, r welcomeRow, at int64, withItems bool,
	pictureBy, tableBy, emojiBy map[int64]string) (string, error) {
	amount := int64(0)
	if r.value != nil {
		amount = *r.value
	}
	wallet := func(total *int64, max int64) string {
		if amount <= 0 {
			return "no amount"
		}
		if amount > max-*total {
			return "more than the wallet can hold"
		}
		*total += amount
		return ""
	}
	switch r.kind {
	case WelcomeRewardChips:
		return wallet(&p.chips, math.MaxInt64), nil
	case WelcomeRewardDiamond:
		return wallet(&p.diamonds, math.MaxInt32), nil
	case WelcomeRewardHammer:
		return wallet(&p.hammers, math.MaxInt32), nil
	case WelcomeRewardMissile:
		return wallet(&p.missiles, math.MaxInt32), nil
	case WelcomeRewardProfilePicture, WelcomeRewardTablePicture, WelcomeRewardEmoji:
		if !withItems {
			return "", nil
		}
		id, ok := refID(r.ref)
		if !ok {
			return "no catalogue id", nil
		}
		switch r.kind {
		case WelcomeRewardProfilePicture:
			if first, dup := pictureBy[id]; dup {
				return "the same profile picture as welcome reward " + first, nil
			}
			pic, active, found, err := findPictureIn(ctx, q, "", id, at)
			if err != nil {
				return "", err
			}
			if reason := catalogueReason("profile picture", found, active, pic.Free()); reason != "" {
				return reason, nil
			}
			pictureBy[id] = r.code
			p.pictures = append(p.pictures, pic)
		case WelcomeRewardTablePicture:
			if first, dup := tableBy[id]; dup {
				return "the same table picture as welcome reward " + first, nil
			}
			pic, active, found, err := findTablePictureIn(ctx, q, "", id, at)
			if err != nil {
				return "", err
			}
			if reason := catalogueReason("table picture", found, active, pic.Free()); reason != "" {
				return reason, nil
			}
			tableBy[id] = r.code
			p.tables = append(p.tables, pic)
		default:
			if first, dup := emojiBy[id]; dup {
				return "the same emoji as welcome reward " + first, nil
			}
			em, active, found, err := findEmojiIn(ctx, q, "", id, at)
			if err != nil {
				return "", err
			}
			if reason := catalogueReason("emoji", found, active, em.Free()); reason != "" {
				return reason, nil
			}
			emojiBy[id] = r.code
			p.emojis = append(p.emojis, em)
		}
		return "", nil
	}
	return "a reward this server cannot grant", nil
}

// catalogueReason is why a catalogue row cannot be a welcome, or "".
func catalogueReason(what string, found, active, free bool) string {
	switch {
	case !found:
		return "no such " + what
	case !active:
		return "the " + what + " is retired"
	case free:
		return "the " + what + " is free: every player has it already"
	}
	return ""
}

// findEmojiIn is Emojis.Find on a transaction: one emoji with this viewer's
// ownership resolved at `at`, whether or not it is on offer.
func findEmojiIn(ctx context.Context, q queryer, userID string, id, at int64) (em Emoji, active, found bool, err error) {
	em, active, err = scanEmoji(q.QueryRow(ctx,
		`SELECT `+emojiColumns+`, e.is_active, `+emojiOwnedExpr+`, `+expiryExpr+`
		   FROM emojis e`+fmt.Sprintf(emojiOwnedJoin, at)+`
		  WHERE e.id = $2`, userID, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return Emoji{}, false, false, nil
	}
	return em, active, err == nil, err
}

// grant writes the ownership rows of the plan's catalogue items for a new
// account, inside the transaction that created it — the rows a purchase or a
// Lucky Draw prize writes (purchases 1; the shop's rental term from `at`) —
// and returns the grant as the login answers it. Nothing is worn or laid.
func (p *welcomePlan) grant(ctx context.Context, tx pgx.Tx, userID string, at int64) (*WelcomeGrant, error) {
	g := &WelcomeGrant{
		Chips: p.chips, Diamonds: p.diamonds, Hammers: p.hammers, Missiles: p.missiles,
		Pictures: make([]Picture, 0, len(p.pictures)), TablePictures: make([]TablePicture, 0, len(p.tables)),
		Emojis: make([]Emoji, 0, len(p.emojis)),
	}
	for _, pic := range p.pictures {
		expiresAt := rentalEnd(pic.DurationDays, pic.DurationHours, at)
		if _, err := tx.Exec(ctx,
			`INSERT INTO user_profile_pictures (user_id, profile_picture_id, acquired_at, expires_at, purchases)
			 VALUES ($1, $2, $3, $4, 1)
			 ON CONFLICT (user_id, profile_picture_id) DO NOTHING`,
			userID, pic.ID, at, expiresAt); err != nil {
			return nil, err
		}
		pic.Owned, pic.ExpiresAt = true, expiresAt
		g.Pictures = append(g.Pictures, pic)
	}
	for _, pic := range p.tables {
		expiresAt := rentalEnd(pic.DurationDays, pic.DurationHours, at)
		if _, err := tx.Exec(ctx,
			`INSERT INTO user_table_pictures (user_id, table_picture_id, acquired_at, expires_at, purchases)
			 VALUES ($1, $2, $3, $4, 1)
			 ON CONFLICT (user_id, table_picture_id) DO NOTHING`,
			userID, pic.ID, at, expiresAt); err != nil {
			return nil, err
		}
		pic.Owned, pic.ExpiresAt = true, expiresAt
		g.TablePictures = append(g.TablePictures, pic)
	}
	for _, em := range p.emojis {
		expiresAt := rentalEnd(em.DurationDays, em.DurationHours, at)
		if _, err := tx.Exec(ctx,
			`INSERT INTO user_emojis (user_id, emoji_id, acquired_at, expires_at, purchases)
			 VALUES ($1, $2, $3, $4, 1)
			 ON CONFLICT (user_id, emoji_id) DO NOTHING`,
			userID, em.ID, at, expiresAt); err != nil {
			return nil, err
		}
		em.Owned, em.ExpiresAt = true, expiresAt
		g.Emojis = append(g.Emojis, em)
	}
	return g, nil
}

// welcomeChipsReadTimeout bounds one read of the chips a new account gets.
const welcomeChipsReadTimeout = 2 * time.Second

// WelcomeChipsCache is Welcome.Chips behind a short in-process cache: what
// session:ready's config.welcomeChips says (the chips the next new account
// would get), read at most once per TTL however many sockets connect, so an
// owner's UPDATE of the rows is on the wire within that many seconds. The
// appversion.Source pattern: a failed read keeps the last value (one WARN,
// one INFO when it reads again), and a caller that finds the cache stale while
// another is reading it is served the stale value rather than queued.
type WelcomeChipsCache struct {
	welcome *Welcome
	ttl     time.Duration
	now     func() time.Time
	log     *slog.Logger

	mu         sync.Mutex
	value      int64
	loadedAt   time.Time
	loaded     bool
	refreshing bool
	failing    bool
}

// NewWelcomeChipsCache builds the cache holding first — the boot's figure —
// as read now when fresh is true (EnsureChipsRow's Total), or as a stand-in to
// be read over at the first call otherwise. ttl 0 reads on every call; now nil
// is time.Now; log nil is slog.Default().
func NewWelcomeChipsCache(w *Welcome, first int64, fresh bool, ttl time.Duration, now func() time.Time, log *slog.Logger) *WelcomeChipsCache {
	if now == nil {
		now = time.Now
	}
	if log == nil {
		log = slog.Default()
	}
	c := &WelcomeChipsCache{welcome: w, ttl: ttl, now: now, log: log, value: first}
	if fresh {
		c.loaded, c.loadedAt = true, now()
	}
	return c
}

// Current is the chips the next new account would get, read afresh when the
// cached figure is older than the TTL.
func (c *WelcomeChipsCache) Current(ctx context.Context) int64 {
	c.mu.Lock()
	if c.loaded && c.ttl > 0 && c.now().Sub(c.loadedAt) < c.ttl {
		v := c.value
		c.mu.Unlock()
		return v
	}
	if c.refreshing || c.welcome == nil {
		v := c.value
		c.mu.Unlock()
		return v
	}
	c.refreshing = true
	c.mu.Unlock()

	rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), welcomeChipsReadTimeout)
	v, err := c.welcome.Chips(rctx)
	cancel()

	c.mu.Lock()
	defer c.mu.Unlock()
	c.refreshing = false
	if err != nil {
		if !c.failing {
			c.failing = true
			c.log.Warn("welcome chips read failed; keeping the last figure", "error", err.Error(), "welcomeChips", c.value)
		}
		return c.value
	}
	if c.failing {
		c.failing = false
		c.log.Info("welcome chips read again", "welcomeChips", v)
	}
	c.value, c.loaded, c.loadedAt = v, true, c.now()
	return v
}

// Invalidate makes the next Current read afresh (tests).
func (c *WelcomeChipsCache) Invalidate() {
	c.mu.Lock()
	c.loadedAt = time.Time{}
	c.mu.Unlock()
}
