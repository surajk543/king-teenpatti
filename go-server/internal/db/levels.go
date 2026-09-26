package db

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// Player levels, badges and XP (owner, 26 Sep 2026: "create table which
// stores every player xp and ac to their level, tax will be applied"; then
// 27 Sep 2026: "Vip is not a level, it is badge, User can hold multiple
// badges … the tax will be applied acc to minimum of badge or player level";
// V1.0.0's PLAYER LEVELS). player_levels is the ladder — fifty levels reached
// by XP — each with the title and icon it is shown by and the WINNING TAX it
// carries: the share of the winnings, in basis points, a table that taxes
// its winners (table_configs.winner_tax) takes from the winner of a hand
// (game.TableTax). badges are held beside the level — Regular by everyone,
// for life (owner, 27 Sep 2026: "By default every user will hold this Regular
// badge 20 percent tax"); the Royal badges by whoever they are given to or
// who buys one (user_badges), each for its validity — and a badge may bring
// the rate lower. xp_sources and xp_settings say what earns XP and how long a player's
// day lasts (with no daily cap, as seeded: owner, 27 Sep 2026, "Don't set any
// daily limit to xp"); player_xp holds each player's XP and their day's window.
// Levels and XP never expire; a badge grant does.
//
// A player's STANDING — level, badges and the rate that follows, the lowest of
// the level's and the badges' — is resolved on every read, never cached: an
// owner's UPDATE, a grant, or a grant running out shows at the next read. A
// table seat captures its player's rate when they sit down (User.Player) and
// refreshes it from every hand-end settle (game.SettleResult.TaxBps), so a
// table never reads these tables itself.

// The kinds of daily XP source this build knows (xp_sources.kind; owner,
// 27 Sep 2026: "Daily XP user can get store this info in db"). A source of any
// other kind is ignored, as is an inactive one: it awards nothing.
const (
	// XPKindPlayTime is play_minutes of active play in the window — the play
	// time kept in the live store (live.PlayClock), never here — awarded
	// asynchronously once the window's play reaches it (XP.AwardPlayTime).
	XPKindPlayTime = "PLAY_TIME"
	// XPKindWinHand is a Teen Patti or Variation hand won holding hand_rank
	// (game.HandCategory.Code: PAIR, COLOR, SEQUENCE, PURE_SEQUENCE, TRAIL,
	// HIGH_CARD), as the table ranks it — awarded in the hand-end settle.
	XPKindWinHand = "WIN_HAND"
)

// PlayerLevel is user.playerLevel on the wire — the viewer's OWN level, never
// another player's. A level is XP alone: it never expires, and no badge is
// one.
type PlayerLevel struct {
	// Level, Title and Icon are the player's level (player_levels): the
	// highest level their XP has reached. Icon is the owner's emoji, exactly
	// as stored.
	Level int    `json:"level"`
	Title string `json:"title"`
	Icon  string `json:"icon"`
	// XP is the player's lifetime XP (player_xp.xp; 0 with no row). It is only
	// ever added to.
	XP int64 `json:"xp"`
	// TaxBps is the winning tax the LEVEL carries, in basis points (2000 =
	// 20.00%). What the player pays is Standing.TaxBps, which a badge may
	// bring lower.
	TaxBps int `json:"taxBps"`
	// Next is the level XP reaches next; ABSENT at the top of the ladder.
	Next *NextLevel `json:"next,omitempty"`
	// Today is the player's XP in their current window against the daily cap;
	// ABSENT while there is no daily cap (owner, 27 Sep 2026: "Don't set any
	// daily limit to xp" — xp_settings.daily_cap NULL, as seeded).
	Today *XPToday `json:"today,omitempty"`
	// Daily is what the player has earned of the daily XP in their current
	// window — how many times each source (by code) — and when the window
	// resets; ABSENT while no window is running, when every source is there
	// to be earned (owner, 27 Sep 2026: "After 24 hours this will be reset,
	// so user can claim this again").
	Daily *XPDaily `json:"daily,omitempty"`
}

// XPDaily is PlayerLevel.Daily: the running window's claims per source code
// (only sources earned at least once; never null) and when the window resets
// (epoch ms).
type XPDaily struct {
	Claimed  map[string]int `json:"claimed"`
	ResetsAt int64          `json:"resetsAt"`
}

// NextLevel is PlayerLevel.Next: the level, what it is shown by, the XP that
// reaches it and the rate it carries.
type NextLevel struct {
	Level  int    `json:"level"`
	Title  string `json:"title"`
	Icon   string `json:"icon"`
	MinXP  int64  `json:"minXp"`
	TaxBps int    `json:"taxBps"`
}

// XPToday is PlayerLevel.Today, sent only where an owner has set a daily cap:
// the XP earned in the running window, the cap on it (xp_settings.daily_cap)
// and when the window runs out (epoch ms; XP and
// ResetsAt are 0 when no window is running — the next hand opens one). The
// window limits what may still be earned today, never what was.
type XPToday struct {
	XP       int   `json:"xp"`
	Cap      int   `json:"cap"`
	ResetsAt int64 `json:"resetsAt"`
}

// Badge is one badge a player holds (owner, 27 Sep 2026: "Vip is not a level,
// it is badge, User can hold multiple badges"): user.badges on the wire,
// every badge the player holds now, in the badges' sort order.
type Badge struct {
	Code  string `json:"code"`
	Title string `json:"title"`
	Icon  string `json:"icon"`
	// TaxBps is the winning tax the badge brings its holder's down to (the
	// seed's: Regular 20%, every Royal badge 0%); null
	// on a badge an owner has given no rate.
	TaxBps *int `json:"taxBps"`
	// ExpiresAt is when the player's grant of it runs out, epoch ms; 0 for a
	// badge held for ever — a default one, or a grant with no end.
	ExpiresAt int64 `json:"expiresAt"`
	// IsDefault marks a badge every player holds, for life (Regular).
	IsDefault bool `json:"isDefault"`
	// AssetURL and AssetFormat are the badge's art (badges.asset_url — a
	// Royal badge's Lottie); ABSENT on a badge shown by its icon alone.
	AssetURL    string `json:"assetUrl,omitempty"`
	AssetFormat string `json:"assetFormat,omitempty"`
}

// Standing is everything one player's winning tax is decided by: their level,
// the badges they hold, and the rate that follows — the LOWEST of the level's
// and every badge's (owner, 27 Sep 2026: "the tax will be applied acc to
// minimum of badge or player level"). Embedded in User, so its three fields
// are user.playerLevel, user.badges and user.taxBps on the wire; and the
// payload of player:level, which a player's socket is sent after an award
// that changed their XP has committed.
type Standing struct {
	PlayerLevel PlayerLevel `json:"playerLevel"`
	// Badges are the badges the player holds now; never null.
	Badges []Badge `json:"badges"`
	// TaxBps is the winning tax the player pays: what a table that taxes its
	// winners takes from this player's win, as of the start of the hand. Their
	// seat captures it (User.Player).
	TaxBps int `json:"taxBps"`
}

// playerLevelJoins are the joins that resolve the standing of the player a
// query reads as `u` (users) at the instant %[1]d (epoch ms, baked in with
// fmt.Sprintf — every query that uses them is formatted, and they hold no
// other verb): their player_xp row (px; none = 0 XP, no window), the level
// it puts them on (lv), the level XP reaches next (nx), the XP settings (xs)
// and the badges they hold then (bd). They are THE statement of the rule —
// every account read and every rate the ledger hands a table go through them:
//
//   - the level is the HIGHEST level whose min_xp the XP has reached, and,
//     should the ladder have no level that low (an owner's edit), the LOWEST
//     rung; the next level is the lowest-numbered level above it;
//   - the badges are every active badge that is a default (Regular) or that
//     user_badges gives the player with a grant that has not run out
//     (expires_at 0, or after this instant);
//   - bd.tax_bps is the lowest rate among those badges (NULL when none sets
//     one), and the rate the player pays is the lower of it and the level's
//     (levelRow.standing);
//   - dc.claimed is how many times the player has earned each daily XP
//     source in their window (player_xp_claims of that window_start).
const playerLevelJoins = `
  LEFT JOIN player_xp px ON px.user_id = u.id
  LEFT JOIN LATERAL (
       SELECT pl.level, pl.title, pl.icon, pl.tax_bps
         FROM player_levels pl
        ORDER BY (pl.min_xp <= COALESCE(px.xp, 0)) DESC,
                 CASE WHEN pl.min_xp <= COALESCE(px.xp, 0) THEN pl.level END DESC NULLS LAST,
                 pl.level
        LIMIT 1) lv ON TRUE
  LEFT JOIN LATERAL (
       SELECT pl.level, pl.title, pl.icon, pl.min_xp, pl.tax_bps
         FROM player_levels pl
        WHERE pl.level > lv.level
        ORDER BY pl.level
        LIMIT 1) nx ON TRUE
  LEFT JOIN xp_settings xs ON xs.id = 1
  LEFT JOIN LATERAL (
       SELECT MIN(b.tax_bps) AS tax_bps,
              json_agg(json_build_object(
                  'code', b.code, 'title', b.title, 'icon', b.icon, 'taxBps', b.tax_bps,
                  'expiresAt', CASE WHEN b.is_default THEN 0 ELSE ub.expires_at END,
                  'isDefault', b.is_default,
                  'assetUrl', COALESCE(b.asset_url, ''), 'assetFormat', COALESCE(b.asset_format, ''))
                ORDER BY b.sort_order, b.code) AS list
         FROM badges b
         LEFT JOIN user_badges ub ON ub.user_id = u.id AND ub.badge_code = b.code
        WHERE b.is_active
          AND (b.is_default OR (ub.user_id IS NOT NULL AND (ub.expires_at = 0 OR ub.expires_at > %[1]d)))) bd ON TRUE
  LEFT JOIN LATERAL (
       SELECT json_object_agg(c.source_code, c.claims) AS claimed
         FROM player_xp_claims c
        WHERE c.user_id = u.id AND c.window_start = px.window_start AND c.claims > 0) dc ON TRUE `

// playerLevelColumns are what playerLevelJoins resolve, in levelRow's order.
const playerLevelColumns = `COALESCE(px.xp, 0), COALESCE(px.window_start, 0), COALESCE(px.window_xp, 0),
       lv.level, lv.title, lv.icon, lv.tax_bps,
       nx.level, nx.title, nx.icon, nx.min_xp, nx.tax_bps,
       xs.daily_cap, COALESCE(xs.window_ms, 0),
       bd.tax_bps, COALESCE(bd.list, '[]'::json), COALESCE(dc.claimed, '{}'::json)`

// levelRow is one player's playerLevelColumns as scanned.
type levelRow struct {
	xp, windowStart int64
	windowXP        int
	level           *int
	title, icon     *string
	taxBps          *int
	nextLevel       *int
	nextTitle       *string
	nextIcon        *string
	nextMinXP       *int64
	nextTaxBps      *int
	dailyCap        *int // nil: no daily cap
	windowMs        int64
	badgeTaxBps     *int
	badges          []byte
	claimed         []byte
}

// targets are levelRow's Scan destinations, in playerLevelColumns' order.
func (r *levelRow) targets() []any {
	return []any{&r.xp, &r.windowStart, &r.windowXP,
		&r.level, &r.title, &r.icon, &r.taxBps,
		&r.nextLevel, &r.nextTitle, &r.nextIcon, &r.nextMinXP, &r.nextTaxBps,
		&r.dailyCap, &r.windowMs,
		&r.badgeTaxBps, &r.badges, &r.claimed}
}

// playerLevel is the level at nowMs. A ladder with no level at all (every row
// deleted) reads as Level 0 with no rate.
func (r levelRow) playerLevel(nowMs int64) PlayerLevel {
	p := PlayerLevel{XP: r.xp}
	if r.level != nil {
		p.Level = *r.level
	}
	if r.title != nil {
		p.Title = *r.title
	}
	if r.icon != nil {
		p.Icon = *r.icon
	}
	if r.taxBps != nil {
		p.TaxBps = *r.taxBps
	}
	if r.nextLevel != nil && r.nextMinXP != nil {
		next := &NextLevel{Level: *r.nextLevel, MinXP: *r.nextMinXP}
		if r.nextTitle != nil {
			next.Title = *r.nextTitle
		}
		if r.nextIcon != nil {
			next.Icon = *r.nextIcon
		}
		if r.nextTaxBps != nil {
			next.TaxBps = *r.nextTaxBps
		}
		p.Next = next
	}
	running := r.windowStart > 0 && nowMs < r.windowStart+r.windowMs
	if r.dailyCap != nil {
		p.Today = &XPToday{Cap: *r.dailyCap}
		if running {
			p.Today.XP = r.windowXP
			p.Today.ResetsAt = r.windowStart + r.windowMs
		}
	}
	if running {
		daily := &XPDaily{Claimed: map[string]int{}, ResetsAt: r.windowStart + r.windowMs}
		if len(r.claimed) > 0 {
			var claimed map[string]int
			if err := json.Unmarshal(r.claimed, &claimed); err == nil {
				for code, n := range claimed {
					daily.Claimed[code] = n
				}
			}
		}
		p.Daily = daily
	}
	return p
}

// standing is the level, the badges and the rate at nowMs: the rate is the
// lower of the level's and the lowest a held badge sets. The rate is read
// from its own column (bd.tax_bps), never from the list, so it is right
// whatever becomes of the list: json_agg of text and integer columns always
// decodes into []Badge, and a list that somehow did not would show no badges
// rather than fail the account read.
func (r levelRow) standing(nowMs int64) Standing {
	s := Standing{PlayerLevel: r.playerLevel(nowMs), Badges: []Badge{}}
	if len(r.badges) > 0 {
		var badges []Badge
		if err := json.Unmarshal(r.badges, &badges); err == nil && badges != nil {
			s.Badges = badges
		}
	}
	s.TaxBps = s.PlayerLevel.TaxBps
	if r.badgeTaxBps != nil && *r.badgeTaxBps < s.TaxBps {
		s.TaxBps = *r.badgeTaxBps
	}
	return s
}

// standingsOf resolves the standing of every account in userIDs at nowMs
// (deleted ones included — the settle reads what it wrote), keyed by id. An id
// with no users row is absent.
func standingsOf(ctx context.Context, q queryer, nowMs int64, userIDs []string) (map[string]Standing, error) {
	out := make(map[string]Standing, len(userIDs))
	if len(userIDs) == 0 {
		return out, nil
	}
	query := fmt.Sprintf(`SELECT u.id, `+playerLevelColumns+` FROM users u`+playerLevelJoins+`WHERE u.id = ANY($1)`, nowMs)
	rows, err := q.Query(ctx, query, userIDs)
	if err != nil {
		return nil, fmt.Errorf("read player levels: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var r levelRow
		if err := rows.Scan(append([]any{&id}, r.targets()...)...); err != nil {
			return nil, fmt.Errorf("read player levels: %w", err)
		}
		out[id] = r.standing(nowMs)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read player levels: %w", err)
	}
	return out, nil
}

// xpRules are xp_settings and the active xp_sources, read once per
// transaction that awards XP: an owner's UPDATE applies at the next award,
// with no restart. on is false when there is no settings row, and then no XP
// is awarded at all. dailyCap is nil while there is no daily cap (owner,
// 27 Sep 2026: "Don't set any daily limit to xp").
type xpRules struct {
	on       bool
	dailyCap *int
	windowMs int64
	sources  []xpSourceRow // active sources this build knows, in sort_order
}

// xpSourceRow is one active daily XP source of a kind this build knows.
type xpSourceRow struct {
	code        string
	kind        string
	playMinutes int    // XPKindPlayTime: the minutes of play that earn it
	handRank    string // XPKindWinHand: the hand a win must be held with
	xp          int
	times       int // times_per_window
	sortOrder   int
}

// loadXPRules reads the rules in q's transaction. A source of a kind this
// build does not know, or missing what its kind needs, is left out: it earns
// nothing.
func loadXPRules(ctx context.Context, q queryer) (xpRules, error) {
	var r xpRules
	err := q.QueryRow(ctx, `SELECT daily_cap, window_ms FROM xp_settings WHERE id = 1`).Scan(&r.dailyCap, &r.windowMs)
	if errors.Is(err, pgx.ErrNoRows) {
		return xpRules{}, nil
	}
	if err != nil {
		return xpRules{}, fmt.Errorf("read xp_settings: %w", err)
	}
	r.on = true
	rows, err := q.Query(ctx, `SELECT code, kind, play_minutes, hand_rank, xp, times_per_window, sort_order
	     FROM xp_sources WHERE is_active ORDER BY sort_order, code`)
	if err != nil {
		return xpRules{}, fmt.Errorf("read xp_sources: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var s xpSourceRow
		var minutes *int
		var hand *string
		if err := rows.Scan(&s.code, &s.kind, &minutes, &hand, &s.xp, &s.times, &s.sortOrder); err != nil {
			return xpRules{}, fmt.Errorf("read xp_sources: %w", err)
		}
		switch s.kind {
		case XPKindPlayTime:
			if minutes == nil || *minutes <= 0 {
				continue
			}
			s.playMinutes = *minutes
		case XPKindWinHand:
			if hand == nil || *hand == "" {
				continue
			}
			s.handRank = *hand
		default:
			continue
		}
		r.sources = append(r.sources, s)
	}
	if err := rows.Err(); err != nil {
		return xpRules{}, fmt.Errorf("read xp_sources: %w", err)
	}
	return r, nil
}

// window is how long an XP window lasts under these rules.
func (r xpRules) window() time.Duration { return time.Duration(r.windowMs) * time.Millisecond }

// wonWith are the WIN_HAND sources a win holding hand earns ("" earns none).
func (r xpRules) wonWith(hand string) []xpSourceRow {
	if hand == "" {
		return nil
	}
	var out []xpSourceRow
	for _, s := range r.sources {
		if s.kind == XPKindWinHand && s.handRank == hand {
			out = append(out, s)
		}
	}
	return out
}

// played are the PLAY_TIME sources a window's play of play has reached.
func (r xpRules) played(play time.Duration) []xpSourceRow {
	var out []xpSourceRow
	for _, s := range r.sources {
		if s.kind == XPKindPlayTime && play >= time.Duration(s.playMinutes)*time.Minute {
			out = append(out, s)
		}
	}
	return out
}

// playMarks are the minutes of play at which some PLAY_TIME source is earned,
// ascending and each once.
func (r xpRules) playMarks() []time.Duration {
	seen := map[int]bool{}
	var out []time.Duration
	for _, s := range r.sources {
		if s.kind == XPKindPlayTime && !seen[s.playMinutes] {
			seen[s.playMinutes] = true
			out = append(out, time.Duration(s.playMinutes)*time.Minute)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// xpAward is what one award did.
type xpAward struct {
	// granted is the XP added (0: every source asked for was already earned
	// its times in the window, or a cap left nothing, or none was asked for).
	granted int
	// windowStart is the window the award counted in (epoch ms).
	windowStart int64
	// newWindow says this award opened the player's window.
	newWindow bool
}

// awardXP is THE ONE WAY XP IS EARNED (owner, 26–27 Sep 2026), whatever the
// source — the hand-end settle's WIN_HAND and the live store's PLAY_TIME
// alike — in the caller's transaction:
//
//  1. the player's player_xp row is created if missing and LOCKED;
//  2. if no window is running (none yet, or window_start + window_ms has
//     passed) a new one opens now, with nothing earned in it — "After 24
//     hours this will be reset, so user can claim this again";
//  3. each source asked for (in sort_order) that the player has earned fewer
//     than its times_per_window in the window (player_xp_claims) is granted
//     its xp — or, where an owner has set a daily cap, what the cap leaves of
//     it — and its claim counted;
//  4. what was granted is added to the lifetime xp and the window's xp.
//
// Asked for nothing, it only opens (or rolls) the window: the hand-end settle
// does that for every player who completed the hand, so the window a player's
// play time counts in is theirs from their first hand of the day. It only
// ever ADDS: lifetime XP never falls and never expires. XP moves a player up
// the ladder and does nothing else — it never grants a badge. A player's
// standing after it is read with standingsOf.
func awardXP(ctx context.Context, tx pgx.Tx, rules xpRules, userID string, at int64, sources []xpSourceRow) (xpAward, error) {
	var award xpAward
	if !rules.on {
		return award, nil
	}
	if _, err := tx.Exec(ctx, `INSERT INTO player_xp (user_id, created_at, updated_at) VALUES ($1, $2, $2)
	     ON CONFLICT (user_id) DO NOTHING`, userID, at); err != nil {
		return award, fmt.Errorf("award xp to %s: %w", userID, err)
	}
	var xp, windowStart int64
	var windowXP int
	if err := tx.QueryRow(ctx, `SELECT xp, window_start, window_xp FROM player_xp WHERE user_id = $1 FOR UPDATE`, userID).
		Scan(&xp, &windowStart, &windowXP); err != nil {
		return award, fmt.Errorf("award xp to %s: %w", userID, err)
	}
	if windowStart <= 0 || at >= windowStart+rules.windowMs {
		windowStart, windowXP = at, 0
		award.newWindow = true
	}
	award.windowStart = windowStart
	for _, source := range sources {
		var claims int
		var claimedIn int64
		err := tx.QueryRow(ctx, `SELECT claims, window_start FROM player_xp_claims WHERE user_id = $1 AND source_code = $2`,
			userID, source.code).Scan(&claims, &claimedIn)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			claims = 0
		case err != nil:
			return award, fmt.Errorf("award xp to %s: %w", userID, err)
		case claimedIn != windowStart:
			claims = 0 // earned in an earlier window: this one starts afresh
		}
		if claims >= source.times {
			continue
		}
		g := source.xp
		if rules.dailyCap != nil {
			g = min(g, *rules.dailyCap-windowXP)
		}
		if g <= 0 {
			continue
		}
		if _, err := tx.Exec(ctx, `INSERT INTO player_xp_claims (user_id, source_code, window_start, claims, updated_at)
		     VALUES ($1, $2, $3, $4, $5)
		     ON CONFLICT (user_id, source_code) DO UPDATE
		        SET window_start = EXCLUDED.window_start, claims = EXCLUDED.claims, updated_at = EXCLUDED.updated_at`,
			userID, source.code, windowStart, claims+1, at); err != nil {
			return award, fmt.Errorf("award xp to %s: %w", userID, err)
		}
		xp += int64(g)
		windowXP += g
		award.granted += g
	}
	if award.granted == 0 && !award.newWindow {
		return award, nil
	}
	if _, err := tx.Exec(ctx, `UPDATE player_xp SET xp = $2, window_start = $3, window_xp = $4, updated_at = $5
	     WHERE user_id = $1`, userID, xp, windowStart, windowXP, at); err != nil {
		return award, fmt.Errorf("award xp to %s: %w", userID, err)
	}
	return award, nil
}

// XP is the award door for the daily XP that is not a hand's — the PLAY_TIME
// sources, which the live store's play time earns after the hand end that
// carried the play has been written (internal/xp) — each award its own
// transaction through awardXP, under the same rules.
type XP struct {
	db    *DB
	clock func() time.Time
}

// NewXP builds the door; clock nil → time.Now.
func NewXP(d *DB, clock func() time.Time) *XP {
	return &XP{db: d, clock: clock}
}

// AwardPlayTime awards userID every PLAY_TIME source that play — their active
// play in the window that opened at windowStart (epoch ms), as the live store
// keeps it — has reached and they have not yet earned its times in that
// window, in a transaction of its own. It returns their standing after it and
// whether their XP changed (false: nothing new was reached, the window has
// since ended or rolled — the play belongs to a window gone by —, or the
// account is gone or deleted, which earns nothing).
func (x *XP) AwardPlayTime(ctx context.Context, userID string, windowStart int64, play time.Duration) (Standing, bool, error) {
	var level Standing
	var changed bool
	err := x.db.WithTx(ctx, func(tx pgx.Tx) error {
		at := now(x.clock)
		var live bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM users WHERE id = $1 AND deleted_at = 0)`, userID).Scan(&live); err != nil {
			return err
		}
		if !live {
			return nil
		}
		rules, err := loadXPRules(ctx, tx)
		if err != nil {
			return err
		}
		reached := rules.played(play)
		if len(reached) == 0 {
			return nil
		}
		var current int64
		err = tx.QueryRow(ctx, `SELECT window_start FROM player_xp WHERE user_id = $1 FOR UPDATE`, userID).Scan(&current)
		if errors.Is(err, pgx.ErrNoRows) || err == nil && (current != windowStart || at >= current+rules.windowMs) {
			return nil // not this window's play any more
		}
		if err != nil {
			return err
		}
		award, err := awardXP(ctx, tx, rules, userID, at, reached)
		if err != nil {
			return err
		}
		changed = award.granted > 0
		if !changed {
			return nil
		}
		standings, err := standingsOf(ctx, tx, at, []string{userID})
		if err != nil {
			return err
		}
		level = standings[userID]
		return nil
	})
	if err != nil {
		return Standing{}, false, err
	}
	return level, changed, nil
}

// PlayMarks are the minutes of window play at which some PLAY_TIME source is
// earned, ascending (15, 60 and 120 minutes as seeded), and how long a window
// lasts (0 when there is no settings row, and no XP is awarded at all). Read
// now: the play-time tracker asks it to know when a hand's play crosses one.
func (x *XP) PlayMarks(ctx context.Context) ([]time.Duration, time.Duration, error) {
	rules, err := loadXPRules(ctx, x.db.Pool)
	if err != nil {
		return nil, 0, err
	}
	if !rules.on {
		return nil, 0, nil
	}
	return rules.playMarks(), rules.window(), nil
}

// StandingOf is userID's standing now, as their account read would give it.
func (x *XP) StandingOf(ctx context.Context, userID string) (Standing, bool, error) {
	standings, err := standingsOf(ctx, x.db.Pool, now(x.clock), []string{userID})
	if err != nil {
		return Standing{}, false, err
	}
	standing, ok := standings[userID]
	return standing, ok, nil
}

// LevelLadder is the whole level ladder as the app shows it (GET /api/levels;
// owner, 27 Sep 2026: the table's tax pill, tapped, "show everything in detail
// and it also show all levels and taxes"): every level in order with its
// title, icon, the XP that reaches it and the winning tax it carries; every
// active badge with the rate it brings a holder's down to and how long a grant
// of it lasts; the active XP sources in their order; the day's cap (null:
// none, as seeded) and the window's length.
// Configuration only: nothing about any player.
type LevelLadder struct {
	Levels    []LadderLevel  `json:"levels"`    // [] when the ladder is empty, never null
	Badges    []LadderBadge  `json:"badges"`    // the active ones; [] when none
	XPSources []LadderSource `json:"xpSources"` // the active ones; [] when none
	DailyCap  *int           `json:"dailyCap"`  // null: no daily cap (as seeded), or no xp_settings row
	WindowMs  int64          `json:"windowMs"`  // how long a day's window lasts
}

// LadderLevel is one rung of LevelLadder.
type LadderLevel struct {
	Level  int    `json:"level"`
	Title  string `json:"title"`
	Icon   string `json:"icon"`
	MinXP  int64  `json:"minXp"`
	TaxBps int    `json:"taxBps"`
}

// LadderBadge is one badge of LevelLadder: its code, title and icon, the rate
// it brings a holder's down to (null: none), how long a grant of it
// lasts (0: for ever), and whether every player holds it.
type LadderBadge struct {
	Code         string `json:"code"`
	Title        string `json:"title"`
	Icon         string `json:"icon"`
	TaxBps       *int   `json:"taxBps"`
	ValidityDays int    `json:"validityDays"`
	IsDefault    bool   `json:"isDefault"`
	// PriceInr is the badge's price in whole rupees — always INR (owner,
	// 27 Sep 2026) — or null where none is set (a badge given by hand
	// only, which the store does not list).
	PriceInr *int `json:"priceInr"`
	// ProductID is the Google Play managed product the app sells the badge
	// as (badges.play_product_id); ABSENT on a badge it does not sell — a
	// listed one's card offers support instead.
	ProductID string `json:"productId,omitempty"`
	// AssetURL and AssetFormat are the badge's art — a Royal badge's Lottie
	// (badges.asset_url); ABSENT on a badge shown by its icon alone.
	AssetURL    string `json:"assetUrl,omitempty"`
	AssetFormat string `json:"assetFormat,omitempty"`
}

// LadderSource is one active daily XP source: its code, the owner's label
// (the app names the kinds it knows in its own five languages and shows this
// only for one it has never heard of), its icon, what earns it — its kind with
// the play minutes or the hand it needs — the XP it gives and how many times a
// window it can be earned.
type LadderSource struct {
	Code        string `json:"code"`
	Name        string `json:"name"`
	Icon        string `json:"icon"`
	Kind        string `json:"kind"`
	PlayMinutes *int   `json:"playMinutes,omitempty"`
	HandRank    string `json:"hand,omitempty"`
	XP          int    `json:"xp"`
	Times       int    `json:"times"`
}

// Ladder reads the whole ladder now: an owner's UPDATE to a level, a badge, a
// source or the cap is on it at the next read.
func (x *XP) Ladder(ctx context.Context) (LevelLadder, error) {
	out := LevelLadder{Levels: []LadderLevel{}, Badges: []LadderBadge{}, XPSources: []LadderSource{}}
	rows, err := x.db.Pool.Query(ctx,
		`SELECT level, title, icon, min_xp, tax_bps FROM player_levels ORDER BY level`)
	if err != nil {
		return LevelLadder{}, fmt.Errorf("read player_levels: %w", err)
	}
	for rows.Next() {
		var l LadderLevel
		if err := rows.Scan(&l.Level, &l.Title, &l.Icon, &l.MinXP, &l.TaxBps); err != nil {
			rows.Close()
			return LevelLadder{}, fmt.Errorf("read player_levels: %w", err)
		}
		out.Levels = append(out.Levels, l)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return LevelLadder{}, fmt.Errorf("read player_levels: %w", err)
	}
	rows, err = x.db.Pool.Query(ctx,
		`SELECT code, title, icon, tax_bps, validity_days, is_default, price_inr, COALESCE(play_product_id, ''),
		        COALESCE(asset_url, ''), COALESCE(asset_format, '')
		   FROM badges WHERE is_active ORDER BY sort_order, code`)
	if err != nil {
		return LevelLadder{}, fmt.Errorf("read badges: %w", err)
	}
	for rows.Next() {
		var b LadderBadge
		if err := rows.Scan(&b.Code, &b.Title, &b.Icon, &b.TaxBps, &b.ValidityDays, &b.IsDefault, &b.PriceInr, &b.ProductID,
			&b.AssetURL, &b.AssetFormat); err != nil {
			rows.Close()
			return LevelLadder{}, fmt.Errorf("read badges: %w", err)
		}
		out.Badges = append(out.Badges, b)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return LevelLadder{}, fmt.Errorf("read badges: %w", err)
	}
	rows, err = x.db.Pool.Query(ctx,
		`SELECT code, name, icon, kind, play_minutes, hand_rank, xp, times_per_window
		   FROM xp_sources WHERE is_active ORDER BY sort_order, code`)
	if err != nil {
		return LevelLadder{}, fmt.Errorf("read xp_sources: %w", err)
	}
	for rows.Next() {
		var s LadderSource
		var hand *string
		if err := rows.Scan(&s.Code, &s.Name, &s.Icon, &s.Kind, &s.PlayMinutes, &hand, &s.XP, &s.Times); err != nil {
			rows.Close()
			return LevelLadder{}, fmt.Errorf("read xp_sources: %w", err)
		}
		if hand != nil {
			s.HandRank = *hand
		}
		out.XPSources = append(out.XPSources, s)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return LevelLadder{}, fmt.Errorf("read xp_sources: %w", err)
	}
	err = x.db.Pool.QueryRow(ctx, `SELECT daily_cap, window_ms FROM xp_settings WHERE id = 1`).Scan(&out.DailyCap, &out.WindowMs)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return LevelLadder{}, fmt.Errorf("read xp_settings: %w", err)
	}
	return out, nil
}
