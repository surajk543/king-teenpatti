package db

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
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

// The mission types a source can have (xp_sources.mission_type; owner,
// 28 Sep 2026: "Add a new mission type: ONE_TIME … The system should now
// support DAILY and ONE_TIME. Do not remove or modify the existing DAILY
// behavior").
const (
	// MissionDaily is earned times_per_window in each rolling window, the
	// window resetting what may be earned — every source before one-time
	// missions, and the column's DEFAULT. Its kinds are XPKindPlayTime and
	// XPKindWinHand.
	MissionDaily = "DAILY"
	// MissionOneTime is earned ONCE in a player's life: when the hands they
	// complete bring its progress to its target (player_xp_missions). No
	// window resets it, its XP is never counted in a window's, and a daily
	// cap never limits it. Its kinds are the four below.
	MissionOneTime = "ONE_TIME"
)

// The kinds of ONE_TIME mission this build knows. Each counts the hands a
// player COMPLETES — the players a hand-end settle resolves as at the table
// when the hand ended, as the daily window counts them — within the source's
// scope (xpSourceRow.inScope). A ONE_TIME source of any other kind, or with
// no target, earns nothing, as a DAILY source of an unknown kind does.
const (
	// XPKindHandsPlayed counts the hands the player PLAYED: made a voluntary
	// bet — a chaal, raise or show at Teen Patti, any chips beyond the forced
	// blinds or ante at poker — requirement 16's "played", the rule
	// player_stats.hands_played and the HANDS_PLAYED milestone count by
	// (game.SettleEntry.DidChaal).
	XPKindHandsPlayed = "HANDS_PLAYED"
	// XPKindHandsWon counts the hands the player WON (game.SettleEntry.IsWinner,
	// player_stats.hands_won's rule): the winner of a Teen Patti hand, a
	// winner of a poker pot, and at 3-Card Poker a player who beat the dealer
	// or whose dealer did not qualify — a push is no win.
	XPKindHandsWon = "HANDS_WON"
	// XPKindCategoriesPlayed counts the DIFFERENT table categories (seen,
	// blind, variation and the four poker ones — the table catalogue's own
	// taxonomy) the player has played a hand at.
	XPKindCategoriesPlayed = "CATEGORIES_PLAYED"
	// XPKindVariationsPlayed counts the DIFFERENT variations (MUFLIS, AK47,
	// JOKER, HUKAM, LOWEST_JOKER, HIGHEST_JOKER, FIVE_CARD) the player has
	// played a Variation hand under.
	XPKindVariationsPlayed = "VARIATIONS_PLAYED"
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
	// AssetURL and AssetFormat are the level's art (player_levels.asset_url —
	// the owner's Lottie, 29 Sep 2026), which the app draws in the emoji's
	// place; ABSENT on a level with none yet.
	AssetURL    string `json:"assetUrl,omitempty"`
	AssetFormat string `json:"assetFormat,omitempty"`
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
	// Missions are where the player stands on the ONE_TIME missions (owner,
	// 28 Sep 2026): every active one they have made progress on or
	// completed, in the missions' order — a mission not listed is at 0 of
	// its target (GET /api/levels' missions say which there are). ABSENT
	// while there is none. No window touches them, so nothing here resets.
	Missions []MissionProgress `json:"missions,omitempty"`
}

// MissionProgress is one ONE_TIME mission as its player stands on it
// (player_xp_missions): its code, its type (always ONE_TIME), how far they
// have come against the source's target, and — once completed, which is for
// good — when, and the XP it gave. It carries no reset or expiry: a one-time
// mission has none. Completed and awarded are one moment (the settle that
// reached the target gave the XP in the same transaction), so there is no
// separate claim.
type MissionProgress struct {
	Code        string `json:"code"`
	Type        string `json:"type"`
	Progress    int    `json:"progress"`
	Target      int    `json:"target"`
	Completed   bool   `json:"completed"`
	CompletedAt int64  `json:"completedAt,omitempty"`
	XPAwarded   int    `json:"xpAwarded,omitempty"`
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
	// AssetURL and AssetFormat are the level's art, as PlayerLevel's.
	AssetURL    string `json:"assetUrl,omitempty"`
	AssetFormat string `json:"assetFormat,omitempty"`
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

// SeatLevel is the standing's level as a table shows it on the player's pod
// (game.SeatLevel: the number and the art); nil for a ladder with no level.
func (s Standing) SeatLevel() *game.SeatLevel {
	if s.PlayerLevel.Level <= 0 {
		return nil
	}
	return &game.SeatLevel{Level: s.PlayerLevel.Level, AssetURL: s.PlayerLevel.AssetURL, AssetFormat: s.PlayerLevel.AssetFormat}
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
//     source in their window (player_xp_claims of that window_start);
//   - om.list is where they stand on each active ONE_TIME mission they have
//     moved on or completed (player_xp_missions) — no window in it: nothing
//     about a one-time mission resets.
const playerLevelJoins = `
  LEFT JOIN player_xp px ON px.user_id = u.id
  LEFT JOIN LATERAL (
       SELECT pl.level, pl.title, pl.icon, pl.tax_bps, pl.asset_url, pl.asset_format
         FROM player_levels pl
        ORDER BY (pl.min_xp <= COALESCE(px.xp, 0)) DESC,
                 CASE WHEN pl.min_xp <= COALESCE(px.xp, 0) THEN pl.level END DESC NULLS LAST,
                 pl.level
        LIMIT 1) lv ON TRUE
  LEFT JOIN LATERAL (
       SELECT pl.level, pl.title, pl.icon, pl.min_xp, pl.tax_bps, pl.asset_url, pl.asset_format
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
        WHERE c.user_id = u.id AND c.window_start = px.window_start AND c.claims > 0) dc ON TRUE
  LEFT JOIN LATERAL (
       SELECT json_agg(json_build_array(m.source_code, m.progress, s.target, m.completed_at, m.xp_awarded)
                ORDER BY s.sort_order, s.code) AS list
         FROM player_xp_missions m
         JOIN xp_sources s ON s.code = m.source_code
        WHERE m.user_id = u.id AND s.is_active AND s.mission_type = 'ONE_TIME' AND s.target IS NOT NULL
          AND (m.progress > 0 OR m.completed_at > 0)) om ON TRUE `

// playerLevelColumns are what playerLevelJoins resolve, in levelRow's order.
const playerLevelColumns = `COALESCE(px.xp, 0), COALESCE(px.window_start, 0), COALESCE(px.window_xp, 0),
       lv.level, lv.title, lv.icon, lv.tax_bps, COALESCE(lv.asset_url, ''), COALESCE(lv.asset_format, ''),
       nx.level, nx.title, nx.icon, nx.min_xp, nx.tax_bps, COALESCE(nx.asset_url, ''), COALESCE(nx.asset_format, ''),
       xs.daily_cap, COALESCE(xs.window_ms, 0),
       bd.tax_bps, COALESCE(bd.list, '[]'::json), COALESCE(dc.claimed, '{}'::json),
       COALESCE(om.list, '[]'::json)`

// levelRow is one player's playerLevelColumns as scanned.
type levelRow struct {
	xp, windowStart int64
	windowXP        int
	level           *int
	title, icon     *string
	taxBps          *int
	art, artFormat  string // the level's art ('' for none)
	nextLevel       *int
	nextTitle       *string
	nextIcon        *string
	nextMinXP       *int64
	nextTaxBps      *int
	nextArt         string
	nextArtFormat   string
	dailyCap        *int // nil: no daily cap
	windowMs        int64
	badgeTaxBps     *int
	badges          []byte
	claimed         []byte
	missions        []byte
}

// targets are levelRow's Scan destinations, in playerLevelColumns' order.
func (r *levelRow) targets() []any {
	return []any{&r.xp, &r.windowStart, &r.windowXP,
		&r.level, &r.title, &r.icon, &r.taxBps, &r.art, &r.artFormat,
		&r.nextLevel, &r.nextTitle, &r.nextIcon, &r.nextMinXP, &r.nextTaxBps, &r.nextArt, &r.nextArtFormat,
		&r.dailyCap, &r.windowMs,
		&r.badgeTaxBps, &r.badges, &r.claimed, &r.missions}
}

// oneTimeMissions reads om.list — [code, progress, target, completed_at,
// xp_awarded] per mission — into the wire's list; nil for none, and nil for a
// list that somehow does not decode, which shows no progress rather than
// failing the account read.
func (r levelRow) oneTimeMissions() []MissionProgress {
	if len(r.missions) == 0 {
		return nil
	}
	var rows [][]json.RawMessage
	if err := json.Unmarshal(r.missions, &rows); err != nil {
		return nil
	}
	var out []MissionProgress
	for _, row := range rows {
		if len(row) != 5 {
			return nil
		}
		m := MissionProgress{Type: MissionOneTime}
		var completedAt int64
		if json.Unmarshal(row[0], &m.Code) != nil || json.Unmarshal(row[1], &m.Progress) != nil ||
			json.Unmarshal(row[2], &m.Target) != nil || json.Unmarshal(row[3], &completedAt) != nil ||
			json.Unmarshal(row[4], &m.XPAwarded) != nil {
			return nil
		}
		if completedAt > 0 {
			m.Completed, m.CompletedAt = true, completedAt
		}
		out = append(out, m)
	}
	return out
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
	p.AssetURL, p.AssetFormat = r.art, r.artFormat
	if r.nextLevel != nil && r.nextMinXP != nil {
		next := &NextLevel{Level: *r.nextLevel, MinXP: *r.nextMinXP, AssetURL: r.nextArt, AssetFormat: r.nextArtFormat}
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
	// The one-time missions whatever the window says: a window that has run
	// out resets the daily claims above and never these.
	p.Missions = r.oneTimeMissions()
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
	sources  []xpSourceRow // active DAILY sources this build knows, in sort_order
	missions []xpSourceRow // active ONE_TIME missions this build knows, in sort_order
}

// xpSourceRow is one active XP source of a kind this build knows: a DAILY
// source or a ONE_TIME mission (missionType).
type xpSourceRow struct {
	code        string
	kind        string
	missionType string // MissionDaily or MissionOneTime
	playMinutes int    // XPKindPlayTime: the minutes of play that earn it
	handRank    string // XPKindWinHand: the hand a win must be held with
	target      int    // ONE_TIME: the progress that completes it (>= 1)
	scope       string // ONE_TIME: "" any table, an engine code, or a category code
	xp          int
	times       int // times_per_window (DAILY)
	sortOrder   int
}

// oneTime reports whether s is a ONE_TIME mission.
func (s xpSourceRow) oneTime() bool { return s.missionType == MissionOneTime }

// validMissionScope reports whether scope is one a ONE_TIME mission may
// name: none (""), an engine (teen_patti, poker — game.Game) or one of the
// seven categories this build knows.
func validMissionScope(scope string) bool {
	return scope == "" || scope == string(game.GameTeenPatti) || scope == string(game.GamePoker) || game.Category(scope).Known()
}

// inScope reports whether a hand at a table of category c counts for the
// mission: every hand for no scope; a hand at that engine's tables for an
// engine's code; a hand at that category's tables for a category's. A hand
// whose category is not known counts only where there is no scope.
func (s xpSourceRow) inScope(c game.Category) bool {
	switch {
	case s.scope == "":
		return true
	case !c.Known():
		return false
	case s.scope == string(c):
		return true
	default:
		return s.scope == string(c.Game())
	}
}

// loadXPRules reads the rules in q's transaction. A source of a kind this
// build does not know, missing what its kind needs, or of a mission type its
// kind does not belong to, is left out: it earns nothing. So is a ONE_TIME
// mission with no target, or a scope this build does not know.
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
	rows, err := q.Query(ctx, `SELECT code, kind, mission_type, play_minutes, hand_rank, target, scope, xp, times_per_window, sort_order
	     FROM xp_sources WHERE is_active ORDER BY sort_order, code`)
	if err != nil {
		return xpRules{}, fmt.Errorf("read xp_sources: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var s xpSourceRow
		var minutes, target *int
		var hand, scope *string
		if err := rows.Scan(&s.code, &s.kind, &s.missionType, &minutes, &hand, &target, &scope, &s.xp, &s.times, &s.sortOrder); err != nil {
			return xpRules{}, fmt.Errorf("read xp_sources: %w", err)
		}
		if s.missionType == MissionOneTime {
			switch s.kind {
			case XPKindHandsPlayed, XPKindHandsWon, XPKindCategoriesPlayed, XPKindVariationsPlayed:
			default:
				continue
			}
			if target == nil || *target < 1 {
				continue
			}
			s.target = *target
			if scope != nil {
				s.scope = *scope
			}
			if !validMissionScope(s.scope) {
				continue
			}
			r.missions = append(r.missions, s)
			continue
		}
		if s.missionType != MissionDaily {
			continue
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
	// its times in the window, or a cap left nothing, or none was asked for),
	// the one-time missions' included.
	granted int
	// completed are the ONE_TIME missions this award completed — the ones
	// whose completion THIS call wrote — in the order asked.
	completed []string
	// windowStart is the window the award counted in (epoch ms).
	windowStart int64
	// newWindow says this award opened the player's window.
	newWindow bool
}

// awardXP is THE ONE WAY XP IS EARNED (owner, 26–27 Sep 2026), whatever the
// source — the hand-end settle's WIN_HAND and ONE_TIME missions and the live
// store's PLAY_TIME alike — in the caller's transaction:
//
//  1. the player's player_xp row is created if missing and LOCKED;
//  2. if no window is running (none yet, or window_start + window_ms has
//     passed) a new one opens now, with nothing earned in it — "After 24
//     hours this will be reset, so user can claim this again";
//  3. each DAILY source asked for (in sort_order) that the player has
//     earned fewer than its times_per_window in the window
//     (player_xp_claims) is granted its xp — or, where an owner has set a
//     daily cap, what the cap leaves of it — and its claim counted;
//  4. each ONE_TIME mission asked for is COMPLETED, once, if its progress
//     has reached its target (advanceMissions) and it is not complete yet:
//     one conditional UPDATE of its player_xp_missions row
//     (completed_at 0 → now) under the row's lock, and only when that
//     statement changed the row is the mission's xp granted — a second call,
//     in this transaction or any other, finds it completed and grants
//     nothing (owner, 28 Sep 2026: "If already completed: award nothing, and
//     do not create another XP transaction");
//  5. what was granted is added to the lifetime xp; what the DAILY sources
//     granted to the window's xp too — a one-time mission's XP is never the
//     window's, so it neither fills a daily cap nor is limited by one.
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
		if source.oneTime() {
			// The completion IS the claim: the row changes from not
			// completed to completed exactly once, whoever asks, however
			// often. The XP rides on that change and nothing else.
			tag, err := tx.Exec(ctx, `UPDATE player_xp_missions
			    SET completed_at = $3, xp_awarded = $4, updated_at = $3
			  WHERE user_id = $1 AND source_code = $2 AND completed_at = 0 AND progress >= $5`,
				userID, source.code, at, source.xp, source.target)
			if err != nil {
				return award, fmt.Errorf("complete mission %s for %s: %w", source.code, userID, err)
			}
			if tag.RowsAffected() == 0 {
				continue // completed before, or not reached: nothing
			}
			award.completed = append(award.completed, source.code)
			xp += int64(source.xp)
			award.granted += source.xp
			continue
		}
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

// missionHand is what one hand a player COMPLETED says to their ONE_TIME
// missions (the hand-end settle's outcome row for a player who did not leave
// mid-hand): the category of the table it was played at, whether they played
// it (a voluntary bet, requirement 16) and won it, and the variation it was
// played under ("" at every table but a variation one).
type missionHand struct {
	category  game.Category
	played    bool
	won       bool
	variation string
}

// missionProgressSQL moves one player's missions on by one hand, in ONE
// statement however many missions the hand counts for — a settle runs it once
// per player who completed the hand, whatever they have completed already.
// $1 is the player, $2 the missions' codes and $3 what each counts: "" for a
// count (a hand played, a hand won), else the DIFFERENT value — a category, a
// variation — to add to what it has seen; $4 is now. A mission's row is
// inserted by the first hand that moves it and moved on otherwise, and — the
// WHERE of ON CONFLICT DO UPDATE — a completed row is never touched (its
// progress is frozen at its completion), nor a different-value mission's row
// by a value it has already counted. RETURNING names only the rows that
// moved, with their progress now. The codes come in order, so two statements
// lock one player's rows in one order (the settle holds the player's wallet
// lock besides).
const missionProgressSQL = `INSERT INTO player_xp_missions AS m (user_id, source_code, progress, seen, created_at, updated_at)
     SELECT $1, d.code, 1, CASE WHEN d.value = '' THEN '{}'::text[] ELSE ARRAY[d.value] END, $4, $4
       FROM unnest($2::text[], $3::text[]) AS d(code, value)
      ORDER BY d.code
     ON CONFLICT (user_id, source_code) DO UPDATE
        SET progress   = CASE WHEN cardinality(EXCLUDED.seen) = 0 THEN m.progress + 1 ELSE cardinality(m.seen) + 1 END,
            seen       = m.seen || EXCLUDED.seen,
            updated_at = EXCLUDED.updated_at
      WHERE m.completed_at = 0
        AND (cardinality(EXCLUDED.seen) = 0 OR NOT (EXCLUDED.seen[1] = ANY (m.seen)))
  RETURNING source_code, progress`

// advanceMissions moves userID's ONE_TIME missions on by one hand they
// completed, in the caller's transaction (the hand-end settle's, under the
// player's wallet lock), and returns the missions whose progress has now
// reached their target — for awardXP to complete, which it does once — and
// whether any mission's progress moved. A mission already completed never
// moves again (owner, 28 Sep 2026: "Once completed: the mission never
// resets; the player can never receive XP from that mission again"). With
// XP off (no settings row) nothing moves.
func advanceMissions(ctx context.Context, tx pgx.Tx, rules xpRules, userID string, at int64, hand missionHand) (reached []xpSourceRow, moved bool, err error) {
	if !rules.on {
		return nil, false, nil
	}
	// What this hand counts for: a hand for the count kinds it satisfies, a
	// value for the different-value kinds.
	counts := map[string]xpSourceRow{}
	var codes, values []string
	for _, m := range rules.missions {
		if !m.inScope(hand.category) {
			continue
		}
		value := ""
		switch m.kind {
		case XPKindHandsPlayed:
			if !hand.played {
				continue
			}
		case XPKindHandsWon:
			if !hand.won {
				continue
			}
		case XPKindCategoriesPlayed:
			if !hand.played || !hand.category.Known() {
				continue
			}
			value = string(hand.category)
		case XPKindVariationsPlayed:
			if !hand.played || hand.variation == "" {
				continue
			}
			value = hand.variation
		default:
			continue
		}
		counts[m.code] = m
		codes = append(codes, m.code)
		values = append(values, value)
	}
	if len(codes) == 0 {
		return nil, false, nil
	}
	rows, err := tx.Query(ctx, missionProgressSQL, userID, codes, values, at)
	if err != nil {
		return nil, false, fmt.Errorf("move missions for %s: %w", userID, err)
	}
	defer rows.Close()
	for rows.Next() {
		var code string
		var progress int
		if err := rows.Scan(&code, &progress); err != nil {
			return nil, false, fmt.Errorf("move missions for %s: %w", userID, err)
		}
		moved = true
		if m := counts[code]; progress >= m.target {
			reached = append(reached, m)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, false, fmt.Errorf("move missions for %s: %w", userID, err)
	}
	// In the missions' order, as awardXP is asked.
	sort.SliceStable(reached, func(i, j int) bool {
		if reached[i].sortOrder != reached[j].sortOrder {
			return reached[i].sortOrder < reached[j].sortOrder
		}
		return reached[i].code < reached[j].code
	})
	return reached, moved, nil
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
// of it lasts; the active DAILY XP sources in their order; the active
// ONE_TIME missions in theirs; the day's cap (null: none, as seeded) and the
// window's length.
// Configuration only: nothing about any player.
type LevelLadder struct {
	Levels []LadderLevel `json:"levels"` // [] when the ladder is empty, never null
	Badges []LadderBadge `json:"badges"` // the active ones; [] when none
	// XPSources are the active DAILY sources; [] when none. A ONE_TIME
	// mission is never among them: an app from before them sums every
	// source's xp × times as the most a window can earn (its "108 XP") and
	// lists a kind it does not know under "More ways to earn XP" — a mission
	// here would have been both.
	XPSources []LadderSource `json:"xpSources"`
	// Missions are the active ONE_TIME missions (owner, 28 Sep 2026), with a
	// target, in their order; [] when none. Where a player stands on each is
	// their own account's (user.playerLevel.missions).
	Missions []LadderSource `json:"missions"`
	DailyCap *int           `json:"dailyCap"` // null: no daily cap (as seeded), or no xp_settings row
	WindowMs int64          `json:"windowMs"` // how long a day's window lasts
}

// LadderLevel is one rung of LevelLadder.
type LadderLevel struct {
	Level  int    `json:"level"`
	Title  string `json:"title"`
	Icon   string `json:"icon"`
	MinXP  int64  `json:"minXp"`
	TaxBps int    `json:"taxBps"`
	// AssetURL and AssetFormat are the level's art (player_levels.asset_url,
	// the owner's Lottie); ABSENT on a level with none yet.
	AssetURL    string `json:"assetUrl,omitempty"`
	AssetFormat string `json:"assetFormat,omitempty"`
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

// LadderSource is one active XP source — a daily source or a one-time
// mission: its code, the owner's label (the app names the daily kinds it
// knows in its own five languages and shows this only for one it has never
// heard of; a one-time mission's label is its TITLE, "First Hand", beside the
// app's own words for what it asks), its icon, what earns it — its kind with
// the play minutes or the hand it needs, or a one-time mission's target and
// scope — its type, the XP it gives and how many times a window it can be
// earned (1 for a one-time mission, which has no window).
type LadderSource struct {
	Code        string `json:"code"`
	Name        string `json:"name"`
	Icon        string `json:"icon"`
	Kind        string `json:"kind"`
	Type        string `json:"type"` // MissionDaily or MissionOneTime
	PlayMinutes *int   `json:"playMinutes,omitempty"`
	HandRank    string `json:"hand,omitempty"`
	// Target is a one-time mission's: the progress that completes it — hands,
	// or different games or variations. ABSENT on a daily source.
	Target *int `json:"target,omitempty"`
	// Scope is a one-time mission's: the engine (teen_patti, poker) or the
	// category (seen … omaha) its hands must be played at; ABSENT for any
	// table, and on a daily source.
	Scope string `json:"scope,omitempty"`
	XP    int    `json:"xp"`
	Times int    `json:"times"`
}

// Ladder reads the whole ladder now: an owner's UPDATE to a level, a badge, a
// source or the cap is on it at the next read.
func (x *XP) Ladder(ctx context.Context) (LevelLadder, error) {
	out := LevelLadder{Levels: []LadderLevel{}, Badges: []LadderBadge{}, XPSources: []LadderSource{}, Missions: []LadderSource{}}
	rows, err := x.db.Pool.Query(ctx,
		`SELECT level, title, icon, min_xp, tax_bps, COALESCE(asset_url, ''), COALESCE(asset_format, '')
		   FROM player_levels ORDER BY level`)
	if err != nil {
		return LevelLadder{}, fmt.Errorf("read player_levels: %w", err)
	}
	for rows.Next() {
		var l LadderLevel
		if err := rows.Scan(&l.Level, &l.Title, &l.Icon, &l.MinXP, &l.TaxBps, &l.AssetURL, &l.AssetFormat); err != nil {
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
		`SELECT code, name, icon, kind, mission_type, play_minutes, hand_rank, target, scope, xp, times_per_window
		   FROM xp_sources WHERE is_active ORDER BY sort_order, code`)
	if err != nil {
		return LevelLadder{}, fmt.Errorf("read xp_sources: %w", err)
	}
	for rows.Next() {
		var s LadderSource
		var hand, scope *string
		var target *int
		if err := rows.Scan(&s.Code, &s.Name, &s.Icon, &s.Kind, &s.Type, &s.PlayMinutes, &hand, &target, &scope, &s.XP, &s.Times); err != nil {
			rows.Close()
			return LevelLadder{}, fmt.Errorf("read xp_sources: %w", err)
		}
		if hand != nil {
			s.HandRank = *hand
		}
		if s.Type == MissionOneTime {
			// A mission with no target can never be completed: it is not
			// offered (loadXPRules leaves it out too).
			if target == nil || *target < 1 {
				continue
			}
			s.Target, s.PlayMinutes, s.HandRank, s.Times = target, nil, "", 1
			if scope != nil {
				s.Scope = *scope
			}
			out.Missions = append(out.Missions, s)
			continue
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
