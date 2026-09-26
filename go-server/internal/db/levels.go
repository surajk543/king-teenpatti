package db

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// Player levels and XP (owner, 26 Sep 2026: "create table which stores every
// player xp and ac to their level, tax will be applied"; V1.0.0's PLAYER
// LEVELS). player_levels is the ladder — fifty levels reached by XP and the
// VIP tier, which XP never reaches — each with the title and icon it is shown
// by and the WINNING TAX it carries: the share of the whole pot, in basis
// points, a table that taxes its winners (table_configs.winner_tax) takes from
// the winner of a hand (game.TableTax). xp_sources and xp_settings say what
// earns XP and how much a player may earn in a day; player_xp holds each
// player's XP, their day's window and — set by hand — a level override.
//
// A player's level is resolved on every read, never cached: an owner's UPDATE
// to the ladder shows at the next read. A table seat captures its player's
// rate when they sit down (User.Player) and refreshes it from every hand-end
// settle (game.SettleResult.TaxBps), so a table never reads these tables
// itself.

// The XP sources this build knows (xp_sources.code). A row with any other code
// is ignored, as is an inactive one: it awards nothing.
const (
	// XPSourceHandCompleted is a hand completed — every player the hand-end
	// write resolves (dealt in and at the table when it ended; a packed player
	// completed it, a leaver did not).
	XPSourceHandCompleted = "HAND_COMPLETED"
	// XPSourceHandWon is a hand won, on top of HAND_COMPLETED.
	XPSourceHandWon = "HAND_WON"
	// XPSourceActive30Min / XPSourceActive60Min are 30 and 60 minutes of
	// active play in one window — the play time kept in the live store
	// (live.PlayClock), never here — each earned once a window, awarded
	// asynchronously (XP.Award).
	XPSourceActive30Min = "ACTIVE_30_MIN"
	XPSourceActive60Min = "ACTIVE_60_MIN"
	// XPSourceDailyPlayBonus is the daily play bonus: granted by the award
	// that OPENS a player's window, whatever the source that opened it, and
	// by no other (awardXP) — once a window.
	XPSourceDailyPlayBonus = "DAILY_PLAY_BONUS"
)

// PlayerLevel is user.playerLevel on the wire — the viewer's OWN level, never
// another player's — and the payload of player:level, which a player's socket
// is sent after an award that changed their XP has committed.
type PlayerLevel struct {
	// Level, Title and Icon are the player's level (player_levels): the
	// override set by hand when there is one, else the highest level their XP
	// has reached. Icon is the owner's emoji, exactly as stored.
	Level int    `json:"level"`
	Title string `json:"title"`
	Icon  string `json:"icon"`
	// XP is the player's lifetime XP (player_xp.xp; 0 with no row).
	XP int64 `json:"xp"`
	// TaxBps is the winning tax the level carries, in basis points (2000 =
	// 20.00%): what a table that taxes its winners takes from this player's
	// win, as of the start of the hand.
	TaxBps int `json:"taxBps"`
	// VIP is the level's is_vip: the VIP tier, which only a level set by hand
	// ever reaches.
	VIP bool `json:"vip"`
	// Next is the level XP reaches next; ABSENT at the top of the ladder and
	// for a level set by hand (the VIP tier, or any override). Never the VIP
	// tier: XP does not grant it.
	Next *NextLevel `json:"next,omitempty"`
	// Today is the player's XP in their current window against the daily cap.
	Today XPToday `json:"today"`
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

// XPToday is PlayerLevel.Today: the XP earned in the running window, the cap
// on it (xp_settings.daily_cap) and when the window runs out (epoch ms; XP and
// ResetsAt are 0 when no window is running — the next hand opens one).
type XPToday struct {
	XP       int   `json:"xp"`
	Cap      int   `json:"cap"`
	ResetsAt int64 `json:"resetsAt"`
}

// playerLevelJoins are the joins that resolve the level of the player a query
// reads as `u` (users): their player_xp row (px; none = 0 XP, no override, no
// window), the level it puts them on (lv), the level XP reaches next (nx) and
// the XP settings (xs). They are THE statement of the level rule — every
// account read and every level the ledger hands a table go through them:
//
//   - a level set by hand (level_override) wins, VIP or not;
//   - otherwise the level is the HIGHEST non-VIP level whose min_xp the XP has
//     reached — a VIP tier (is_vip, min_xp NULL) is never considered, so no
//     amount of XP reaches it — and, should the ladder have no level that low
//     (an owner's edit), the LOWEST rung;
//   - the next level is the lowest-numbered non-VIP level above that one, and
//     there is none after an override.
const playerLevelJoins = `
  LEFT JOIN player_xp px ON px.user_id = u.id
  LEFT JOIN LATERAL (
       SELECT pl.level, pl.title, pl.icon, pl.tax_bps, pl.is_vip
         FROM player_levels pl
        WHERE pl.level = px.level_override
       UNION ALL
       SELECT r.level, r.title, r.icon, r.tax_bps, r.is_vip FROM (
            SELECT pl.level, pl.title, pl.icon, pl.tax_bps, pl.is_vip
              FROM player_levels pl
             WHERE px.level_override IS NULL AND NOT pl.is_vip AND pl.min_xp IS NOT NULL
             ORDER BY (pl.min_xp <= COALESCE(px.xp, 0)) DESC,
                      CASE WHEN pl.min_xp <= COALESCE(px.xp, 0) THEN pl.level END DESC NULLS LAST,
                      pl.level
             LIMIT 1) r
       LIMIT 1) lv ON TRUE
  LEFT JOIN LATERAL (
       SELECT pl.level, pl.title, pl.icon, pl.min_xp, pl.tax_bps
         FROM player_levels pl
        WHERE px.level_override IS NULL AND NOT pl.is_vip AND pl.min_xp IS NOT NULL
          AND pl.level > lv.level
        ORDER BY pl.level
        LIMIT 1) nx ON TRUE
  LEFT JOIN xp_settings xs ON xs.id = 1 `

// playerLevelColumns are what playerLevelJoins resolve, in levelRow's order.
const playerLevelColumns = `COALESCE(px.xp, 0), COALESCE(px.window_start, 0), COALESCE(px.window_xp, 0),
       lv.level, lv.title, lv.icon, lv.tax_bps, lv.is_vip,
       nx.level, nx.title, nx.icon, nx.min_xp, nx.tax_bps,
       COALESCE(xs.daily_cap, 0), COALESCE(xs.window_ms, 0)`

// levelRow is one player's playerLevelColumns as scanned.
type levelRow struct {
	xp, windowStart int64
	windowXP        int
	level           *int
	title, icon     *string
	taxBps          *int
	vip             *bool
	nextLevel       *int
	nextTitle       *string
	nextIcon        *string
	nextMinXP       *int64
	nextTaxBps      *int
	dailyCap        int
	windowMs        int64
}

// targets are levelRow's Scan destinations, in playerLevelColumns' order.
func (r *levelRow) targets() []any {
	return []any{&r.xp, &r.windowStart, &r.windowXP,
		&r.level, &r.title, &r.icon, &r.taxBps, &r.vip,
		&r.nextLevel, &r.nextTitle, &r.nextIcon, &r.nextMinXP, &r.nextTaxBps,
		&r.dailyCap, &r.windowMs}
}

// playerLevel is the wire object at nowMs. A ladder with no level at all
// (every row deleted) reads as Level 0 with no rate.
func (r levelRow) playerLevel(nowMs int64) PlayerLevel {
	p := PlayerLevel{XP: r.xp, Today: XPToday{Cap: r.dailyCap}}
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
	if r.vip != nil {
		p.VIP = *r.vip
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
	if r.windowStart > 0 && nowMs < r.windowStart+r.windowMs {
		p.Today.XP = r.windowXP
		p.Today.ResetsAt = r.windowStart + r.windowMs
	}
	return p
}

// playerLevelsOf resolves the level of every account in userIDs (deleted ones
// included — the settle reads what it wrote), keyed by id. An id with no users
// row is absent.
func playerLevelsOf(ctx context.Context, q queryer, nowMs int64, userIDs []string) (map[string]PlayerLevel, error) {
	out := make(map[string]PlayerLevel, len(userIDs))
	if len(userIDs) == 0 {
		return out, nil
	}
	rows, err := q.Query(ctx, `SELECT u.id, `+playerLevelColumns+` FROM users u`+playerLevelJoins+`WHERE u.id = ANY($1)`, userIDs)
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
		out[id] = r.playerLevel(nowMs)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read player levels: %w", err)
	}
	return out, nil
}

// xpRules are xp_settings and the active xp_sources, read once per
// transaction that awards XP: an owner's UPDATE applies at the next award,
// with no restart. on is false when there is no settings row, and then no XP
// is awarded at all.
type xpRules struct {
	on       bool
	dailyCap int
	windowMs int64
	sources  map[string]xpSourceRow // active sources by code
}

type xpSourceRow struct {
	xp        int
	sortOrder int
}

// loadXPRules reads the rules in q's transaction.
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
	r.sources = map[string]xpSourceRow{}
	rows, err := q.Query(ctx, `SELECT code, xp, sort_order FROM xp_sources WHERE is_active`)
	if err != nil {
		return xpRules{}, fmt.Errorf("read xp_sources: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var code string
		var s xpSourceRow
		if err := rows.Scan(&code, &s.xp, &s.sortOrder); err != nil {
			return xpRules{}, fmt.Errorf("read xp_sources: %w", err)
		}
		r.sources[code] = s
	}
	if err := rows.Err(); err != nil {
		return xpRules{}, fmt.Errorf("read xp_sources: %w", err)
	}
	return r, nil
}

// window is how long an XP window lasts under these rules.
func (r xpRules) window() time.Duration { return time.Duration(r.windowMs) * time.Millisecond }

// xpAward is what one award did.
type xpAward struct {
	// granted is the XP added (0: the cap was reached, or every source asked
	// for is inactive or unknown).
	granted int
	// newWindow says this award opened the player's window.
	newWindow bool
}

// awardXP is THE ONE WAY XP IS EARNED (owner, 26 Sep 2026), whatever the
// source — the hand-end settle's HAND_COMPLETED and HAND_WON and the live
// store's ACTIVE_30_MIN and ACTIVE_60_MIN alike — in the caller's transaction:
//
//  1. the player's player_xp row is created if missing and LOCKED;
//  2. if no window is running (none yet, or window_start + window_ms has
//     passed) a new one opens now, with nothing earned in it — "it will be
//     reset after 24 hours": the cap, the daily bonus and the play marks all
//     start over;
//  3. each source asked for that is known and active is granted what the cap
//     leaves of it — min(its xp, daily_cap − window_xp) — in xp_sources
//     sort_order; and when step 2 opened the window, so is the DAILY PLAY
//     BONUS, whoever asked (that is what makes it once a window);
//  4. what was granted is added to the lifetime xp and the window's xp.
//
// It never writes level_override: XP moves a player up the ladder, never onto
// the VIP tier (player_levels' CHECKs and the level rule see to the rest). A
// player's level after it is read with playerLevelsOf.
func awardXP(ctx context.Context, tx pgx.Tx, rules xpRules, userID string, at int64, sources ...string) (xpAward, error) {
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
	for _, source := range rules.grants(award.newWindow, sources) {
		g := min(source.xp, rules.dailyCap-windowXP)
		if g <= 0 {
			continue
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

// grants are the sources an award grants, in sort_order (then code): each
// asked-for source that is known and active, and the daily play bonus when
// the award opens a window. Each at most once.
func (r xpRules) grants(newWindow bool, asked []string) []xpSourceRow {
	codes := map[string]bool{}
	for _, code := range asked {
		switch code {
		case XPSourceHandCompleted, XPSourceHandWon, XPSourceActive30Min, XPSourceActive60Min:
			codes[code] = true
		}
	}
	if newWindow {
		codes[XPSourceDailyPlayBonus] = true
	}
	type granted struct {
		code string
		row  xpSourceRow
	}
	var list []granted
	for code := range codes {
		if row, ok := r.sources[code]; ok {
			list = append(list, granted{code, row})
		}
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].row.sortOrder != list[j].row.sortOrder {
			return list[i].row.sortOrder < list[j].row.sortOrder
		}
		return list[i].code < list[j].code
	})
	out := make([]xpSourceRow, len(list))
	for i, g := range list {
		out[i] = g.row
	}
	return out
}

// XP is the award door for the sources that are not a hand's — the 30- and
// 60-minute active-play XP, which the live store's play time earns after the
// hand end that crossed the mark has been written (internal/xp) — each award
// its own transaction through awardXP, under the same rules.
type XP struct {
	db    *DB
	clock func() time.Time
}

// NewXP builds the door; clock nil → time.Now.
func NewXP(d *DB, clock func() time.Time) *XP {
	return &XP{db: d, clock: clock}
}

// Award awards source to userID in a transaction of its own and returns the
// player's level after it and whether their XP changed (false: the cap was
// reached, the source is inactive or unknown, or the account is gone or
// deleted — which earns nothing).
func (x *XP) Award(ctx context.Context, userID, source string) (PlayerLevel, bool, error) {
	var level PlayerLevel
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
		award, err := awardXP(ctx, tx, rules, userID, at, source)
		if err != nil {
			return err
		}
		changed = award.granted > 0
		levels, err := playerLevelsOf(ctx, tx, at, []string{userID})
		if err != nil {
			return err
		}
		level = levels[userID]
		return nil
	})
	if err != nil {
		return PlayerLevel{}, false, err
	}
	return level, changed, nil
}

// Window is how long an XP window lasts (xp_settings.window_ms), read now: the
// live store's play-time window lasts as long. 0 when there is no settings
// row (no XP is awarded then).
func (x *XP) Window(ctx context.Context) (time.Duration, error) {
	rules, err := loadXPRules(ctx, x.db.Pool)
	if err != nil {
		return 0, err
	}
	return rules.window(), nil
}

// LevelOf is userID's level now, as their account read would give it.
func (x *XP) LevelOf(ctx context.Context, userID string) (PlayerLevel, bool, error) {
	levels, err := playerLevelsOf(ctx, x.db.Pool, now(x.clock), []string{userID})
	if err != nil {
		return PlayerLevel{}, false, err
	}
	level, ok := levels[userID]
	return level, ok, nil
}
