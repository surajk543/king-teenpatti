package db_test

// Player levels and XP (owner, 26 Sep 2026; db/levels.go, V1.0.0's PLAYER
// LEVELS): the owner's ladder as seeded, the level rule — a badge never reached by
// XP — the one award function with its daily cap and rolling window, the XP a
// hand-end settle awards in its own transaction, and the two ledger rows of a
// taxed win.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// ownersLevels is the owner's table, exactly (26 Sep 2026, with the tax bracket
// of 27 Sep 2026: 20% at Level 1 to 6% at Level 50): level, the XP that
// reaches it, title, icon and winning tax in basis points. A badge is not a
// level (owner, 27 Sep 2026: "Vip is not a level, it is badge"). The icons are written with escapes
// so an editor cannot drop a U+FE0F variation selector or merge two emoji.
var ownersLevels = []struct {
	level  int
	minXP  int64
	title  string
	icon   string
	taxBps int
}{
	{1, 0, "Newbie", "\U0001F331", 2000},
	{2, 100, "Rookie", "\U0001F530", 1971},
	{3, 250, "Beginner", "\u2B50", 1943},
	{4, 500, "Player", "\U0001F3AE", 1914},
	{5, 800, "Regular", "\U0001F7E2", 1886},
	{6, 1200, "Challenger", "\u2694\uFE0F", 1857},
	{7, 1700, "Skilled", "\U0001F3AF", 1829},
	{8, 2300, "Contender", "\U0001F6E1\uFE0F", 1800},
	{9, 3000, "Fighter", "\u2694\uFE0F", 1771},
	{10, 4000, "Rising Star", "\U0001F31F", 1743},
	{11, 5200, "Pro Player", "\U0001F3C5", 1714},
	{12, 6700, "Veteran", "\U0001F396\uFE0F", 1686},
	{13, 8500, "Expert", "\U0001F9E0", 1657},
	{14, 10500, "Specialist", "\U0001F4A0", 1629},
	{15, 13000, "Ace", "\U0001F0CF", 1600},
	{16, 16000, "Elite", "\U0001F48E", 1571},
	{17, 20000, "Master", "\U0001F451", 1543},
	{18, 25000, "Grand Master", "\U0001F451\u2694\uFE0F", 1514},
	{19, 31000, "Champion", "\U0001F3C6", 1486},
	{20, 38000, "High Roller", "\U0001F4B0", 1457},
	{21, 46000, "Royal", "\U0001F451", 1429},
	{22, 55000, "Royal Ace", "\U0001F0CF\U0001F451", 1400},
	{23, 65000, "Royal Master", "\U0001F451\U0001F48E", 1371},
	{24, 76000, "Supreme", "\U0001F531", 1343},
	{25, 88000, "Supreme Ace", "\U0001F531\U0001F0CF", 1314},
	{26, 102000, "Legend", "\U0001F320", 1286},
	{27, 118000, "Legendary", "\u2728", 1257},
	{28, 136000, "Grand Legend", "\U0001F31F\U0001F451", 1229},
	{29, 156000, "Immortal", "\u267E\uFE0F", 1200},
	{30, 178000, "Titan", "\u26A1", 1171},
	{31, 202000, "Elite Titan", "\u26A1\U0001F48E", 1143},
	{32, 228000, "Royal Titan", "\u26A1\U0001F451", 1114},
	{33, 256000, "Emperor", "\U0001F451", 1086},
	{34, 286000, "Royal Emperor", "\U0001F451\U0001F48E", 1057},
	{35, 318000, "Supreme Emperor", "\U0001F531\U0001F451", 1029},
	{36, 352000, "King", "\U0001F451", 1000},
	{37, 390000, "Grand King", "\U0001F451\U0001F3C6", 971},
	{38, 432000, "Royal King", "\U0001F451\U0001F48E", 943},
	{39, 478000, "Supreme King", "\U0001F531\U0001F451", 914},
	{40, 528000, "Master King", "\U0001F451\u2694\uFE0F", 886},
	{41, 585000, "Overlord", "\U0001F525", 857},
	{42, 650000, "Grand Overlord", "\U0001F525\U0001F451", 829},
	{43, 725000, "Royal Overlord", "\U0001F525\U0001F48E", 800},
	{44, 810000, "Supreme Overlord", "\U0001F525\U0001F531", 771},
	{45, 900000, "Mythic", "\U0001F30C", 743},
	{46, 1000000, "Mythic King", "\U0001F30C\U0001F451", 714},
	{47, 1150000, "Immortal King", "\u267E\uFE0F\U0001F451", 686},
	{48, 1350000, "Legendary King", "\U0001F31F\U0001F451", 657},
	{49, 1600000, "Supreme Legend", "\U0001F531\U0001F31F", 629},
	{50, 2000000, "King of Kings", "\U0001F451\U0001F451", 600},
}

// ownersLevelArt is each level's art as the owner has given it so far (29 Sep
// 2026: "Instead of using icons use lottie animations json for showing player
// Level"): Level 1 served by this server as the copy with its loopOut()
// written out, the rest the owner's Drive uploads. A level not here has none
// yet (asset_url NULL).
var ownersLevelArt = map[int]string{
	1:  "/levels/newbie.json",
	2:  "https://drive.google.com/uc?export=download&id=1X5ONeIYMh2Q6348MsQGU9YO1Ut9j0RjR",
	3:  "https://drive.google.com/uc?export=download&id=1046FnHvyBeXHRzuQAyflU-Z994XLMuZG",
	4:  "https://drive.google.com/uc?export=download&id=1UteuLgAVMFKBXSDGtMs_7LCJKixrZhP8",
	5:  "https://drive.google.com/uc?export=download&id=1o0Ch-l1nosmMomDocrKO061DnCAIOOcR",
	6:  "https://drive.google.com/uc?export=download&id=1JBH14iM0z78skBTliTzYlU1aHl3-c6S2",
	7:  "https://drive.google.com/uc?export=download&id=16LUCeHS--xT7pWcup9xWLOzI7slpIDba",
	8:  "https://drive.google.com/uc?export=download&id=1DVOEYt6eBhpjhfYqNI-0XTzAXmWsDg7c",
	9:  "https://drive.google.com/uc?export=download&id=1-oNEE7AIBgDltplByb_hUT4TjyNU4TQ8",
	10: "https://drive.google.com/uc?export=download&id=11E2kIWN-I3d1Df_ZiikOlbfJVR8bCkkd",
	11: "https://drive.google.com/uc?export=download&id=1uPdZgu0zaHe3Cxev7RxRFe5bdDFJ9uax",
	12: "https://drive.google.com/uc?export=download&id=1v7t6TppF5xMO1tHiZaUiM0Vk_hWDtpru",
	13: "https://drive.google.com/uc?export=download&id=1p-DiB6Ywhwg9nu1o22MoObJU4dp5pQa2",
	14: "https://drive.google.com/uc?export=download&id=12TiIf1ghpANIC9CTpHN7-DPgSjqCekN7",
	15: "https://drive.google.com/uc?export=download&id=1KbguHCl0hnDNPiD5mC4WBUqfjoNqrXHO",
	16: "https://drive.google.com/uc?export=download&id=1St9AZX05qFedF40zf0rZhQ6ATFTkCytQ",
	17: "https://drive.google.com/uc?export=download&id=1ec87R_lGM3EZHXAVIhjt0eYDslLzKk95",
	18: "https://drive.google.com/uc?export=download&id=1fq3eVEu739XZBBN5Jkt_m4TLc_P5zIUK",
	19: "https://drive.google.com/uc?export=download&id=1_agD2lEmfPN-sQcgm853aqwG9ujd0R2K",
	20: "/levels/high-roller.json",
	21: "https://drive.google.com/uc?export=download&id=1UNCYMfWQ1FNKW_4skDQefTTPvP7lr_ja",
	22: "/levels/royal-ace.json",
	23: "https://drive.google.com/uc?export=download&id=1SkpRRudplWyT7IKEpOAucp0UPrrQG9iZ",
	24: "https://drive.google.com/uc?export=download&id=1tStW2xVARGhsutKETNaJna5gj4opBSAv",
	25: "/levels/supreme-ace.json",
	26: "https://drive.google.com/uc?export=download&id=1_aeUxyPcY8y8vjS5XCGle2GVJ58H1W_S",
	27: "https://drive.google.com/uc?export=download&id=1JJf7FXDtLbABcU6QV4dDC3AjTaB42d9G",
	28: "https://drive.google.com/uc?export=download&id=1waubm1JDH69aO-Wi_SJ2NPU2LuhAmLul",
	29: "https://drive.google.com/uc?export=download&id=1IQv0oHWum_kyAvvuNLhvV6UsiEdf7u8S",
	30: "https://drive.google.com/uc?export=download&id=1NVhpS0i9DiahWamLqOsqlCPh9FpJEgqZ",
	31: "https://drive.google.com/uc?export=download&id=1t5mpo6BYOrECuoRAsPTgAmwTJEGSwH9Z",
	32: "/levels/royal-titan.json",
	33: "https://drive.google.com/uc?export=download&id=1wLDxV_GkYrhpyLDDSP9cC7zUi4Hh9Cnz",
	34: "https://drive.google.com/uc?export=download&id=1J0cl9aGb3Gvhgbov49FCyPjtuo7W96az",
	35: "https://drive.google.com/uc?export=download&id=1gvFRTrz1C_faOiIZUoe8y8adVdCyXM57",
	36: "https://drive.google.com/uc?export=download&id=1SqX6So-jtLzeOpoqdXzdIGJgquZXZiJk",
	37: "https://drive.google.com/uc?export=download&id=1Ngplvi2rKX0rjFxzXOR4ODx9L38UQDHE",
	38: "https://drive.google.com/uc?export=download&id=1AoW8XeczJTYOC3Q0H8DjCXVwbudMoGcP",
	39: "https://drive.google.com/uc?export=download&id=1jaEC17ASGxNDJAyyulBVhO0NBVmI_iAa",
	40: "https://drive.google.com/uc?export=download&id=15go9POUg8_3nsjz6xPHmZqxzYxnMNcu7",
	41: "/levels/overlord.json",
	42: "https://drive.google.com/uc?export=download&id=1eZF7faadc4hjZ-lUxGMggz99gT03tGEM",
	43: "https://drive.google.com/uc?export=download&id=1W6PhSsxNDQbxLwWiFHhOfc0INgw-exov",
	44: "https://drive.google.com/uc?export=download&id=1kF5cZ7xd6k6QEklwo0BGee6NteAdvXBM",
	45: "https://drive.google.com/uc?export=download&id=1Mt08RZaAuazPJORoXaWkBBvdpOzGX1qU",
	46: "https://drive.google.com/uc?export=download&id=1vN8VIjlRK6NOKTlQ_7YBZIQMDGelamjM",
	47: "https://drive.google.com/uc?export=download&id=1xcnpkXAsum0i6DwbrK5AhAC4qbXB9adX",
	48: "https://drive.google.com/uc?export=download&id=1W33Jv1LFLAvh_0wmKOWh9ktpUK5aFzQX",
	49: "https://drive.google.com/uc?export=download&id=11X5XK7q6HExMJZ-zUPoxZW9vYFDD5B3r",
	50: "https://drive.google.com/uc?export=download&id=1IyDWBxn-9lcQeZVkTQQY1gzE3zTBuZdA",
}

// TestTheSeededLevelsAreTheOwnersTable: a fresh database holds the owner's
// fifty levels exactly — thresholds, titles, rates — and every icon code point
// for code point.
func TestTheSeededLevelsAreTheOwnersTable(t *testing.T) {
	f := newFixture(t)
	rows, err := f.d.Pool.Query(f.ctx, `SELECT level, min_xp, title, icon, tax_bps, asset_url, asset_format
	     FROM player_levels ORDER BY level`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	i := 0
	for rows.Next() {
		var level, bps int
		var minXP int64
		var title, icon string
		var art, format *string
		if err := rows.Scan(&level, &minXP, &title, &icon, &bps, &art, &format); err != nil {
			t.Fatal(err)
		}
		// The art the owner has given so far; NULL (not yet given) on the rest.
		if want, ok := ownersLevelArt[level]; ok {
			if art == nil || *art != want || format == nil || *format != "LOTTIE" {
				t.Errorf("level %d's art is %v %v, want the LOTTIE %s", level, art, format, want)
			}
		} else if art != nil || format != nil {
			t.Errorf("level %d has art %v %v, but the owner has sent none", level, art, format)
		}
		if i >= len(ownersLevels) {
			t.Fatalf("an extra level %d", level)
		}
		want := ownersLevels[i]
		i++
		if level != want.level || minXP != want.minXP || title != want.title || bps != want.taxBps {
			t.Errorf("level %d: %d %q %d, want %d %d %q %d", level, minXP, title, bps, want.level, want.minXP, want.title, want.taxBps)
		}
		if icon != want.icon {
			t.Errorf("level %d's icon is %+q, want %+q", level, icon, want.icon)
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if i != len(ownersLevels) || i != 50 {
		t.Fatalf("%d levels, want the owner's 50", i)
	}
	// The daily XP, as the owner gave it (27 Sep 2026): each once a window —
	// every one of them DAILY. The one-time missions seeded beside them (28 Sep
	// 2026) are TestTheSeededOneTimeMissionsAreTheOwnersEight's.
	srcRows, err := f.d.Pool.Query(f.ctx, `SELECT code, name, icon, kind, COALESCE(play_minutes, 0), COALESCE(hand_rank, ''),
	       xp, times_per_window, is_active FROM xp_sources WHERE mission_type = 'DAILY' ORDER BY sort_order`)
	if err != nil {
		t.Fatal(err)
	}
	var sources []string
	for srcRows.Next() {
		var code, name, icon, kind, hand string
		var minutes, xp, times int
		var active bool
		if err := srcRows.Scan(&code, &name, &icon, &kind, &minutes, &hand, &xp, &times, &active); err != nil {
			t.Fatal(err)
		}
		sources = append(sources, fmt.Sprintf("%s|%s|%+q|%s|%d|%s|%d|%d|%v", code, name, icon, kind, minutes, hand, xp, times, active))
	}
	srcRows.Close()
	wantSources := []string{
		`PLAY_15_MIN|Play 15 active minutes|"\U0001f3ae"|PLAY_TIME|15||3|1|true`,
		`PLAY_60_MIN|Play 60 active minutes|"\U0001f3ae"|PLAY_TIME|60||20|1|true`,
		`PLAY_120_MIN|Play 120 active minutes|"\U0001f3ae"|PLAY_TIME|120||50|1|true`,
		`WIN_PAIR|Win by Pair|"\U0001f465"|WIN_HAND|0|PAIR|1|1|true`,
		`WIN_COLOR|Win by Color|"\U0001f3a8"|WIN_HAND|0|COLOR|2|1|true`,
		`WIN_SEQUENCE|Win by Sequence|"\U0001f0cf"|WIN_HAND|0|SEQUENCE|4|1|true`,
		`WIN_PURE_SEQUENCE|Win by Pure Sequence|"\U0001f48e"|WIN_HAND|0|PURE_SEQUENCE|8|1|true`,
		`WIN_TRAIL|Win by Trail|"\U0001f525"|WIN_HAND|0|TRAIL|20|1|true`,
	}
	if strings.Join(sources, "\n") != strings.Join(wantSources, "\n") {
		t.Errorf("xp_sources:\n%s\nwant:\n%s", strings.Join(sources, "\n"), strings.Join(wantSources, "\n"))
	}
	if f.count(`SELECT count(*) FROM xp_settings WHERE id = 1 AND daily_cap IS NULL AND window_ms = 86400000`) != 1 {
		t.Error("xp_settings must be a 24-hour window with no daily cap (owner: \"Don't set any daily limit to xp\")")
	}
	if f.count(`SELECT count(*) FROM player_xp`) != 0 {
		t.Error("the seed gives nobody XP")
	}
}

// TestTheSeededBadgesAreTheOwners (owner, 27 Sep 2026: the Royal badges; "By
// default every user will hold this Regular badge 20 percent tax … validaity
// life time, do not show this badge in store, its price zero"; "remove the
// entry vip, royal vip and elite vip"): Regular is everyone's, for life, at
// 20% and ₹0, with its Lottie; then the six Royal badges and nothing else;
// nobody is given one by the seed.
func TestTheSeededBadgesAreTheOwners(t *testing.T) {
	f := newFixture(t)
	rows, err := f.d.Pool.Query(f.ctx, `SELECT code, title, icon, tax_bps, validity_days, price_inr, COALESCE(play_product_id, ''),
	       COALESCE(asset_url, ''), COALESCE(asset_format, ''), is_default, is_active FROM badges ORDER BY sort_order`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var got []string
	for rows.Next() {
		var code, title, icon, product, asset, format string
		var bps, price *int
		var days int
		var def, active bool
		if err := rows.Scan(&code, &title, &icon, &bps, &days, &price, &product, &asset, &format, &def, &active); err != nil {
			t.Fatal(err)
		}
		rate, rupees := "none", "no price"
		if bps != nil {
			rate = fmt.Sprint(*bps)
		}
		if price != nil {
			rupees = fmt.Sprintf("₹%d", *price)
		}
		asset = strings.TrimPrefix(asset, "https://drive.google.com/uc?export=download&id=")
		got = append(got, fmt.Sprintf("%s/%s/%+q/%s/%dd/%s/%q/%s:%s/default=%v/active=%v",
			code, title, icon, rate, days, rupees, product, format, asset, def, active))
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	// The Royal badges the store lists (owner, 27 Sep 2026: "for badges use
	// this entry, not vips entry"): 0% for 7 to 90 days at ₹500 to ₹4,500 (Play's own prices),
	// each with the owner's Lottie on Drive, and each sold in the app under
	// the Play product the owner created for it. The store does not list
	// Regular, everyone's by default, and it has no product.
	want := []string{
		`REGULAR/Regular/""/2000/0d/₹0/""/LOTTIE:1zz4gVBpw579xeR1LLn3dBd3Os3cG8jQT/default=true/active=true`,
		`ROYAL_ACE/Royal Ace/""/0/7d/₹500/"badge_royal_ace_499"/LOTTIE:1lwt8uXauqnX77WEb73xZAbTz_TR-rJKm/default=false/active=true`,
		`ROYAL_KING/Royal King/""/0/15d/₹1000/"badge_royal_king_999"/LOTTIE:1Frs4uv6oAkxK9YgHhh52Rwi_kCRpngNU/default=false/active=true`,
		`ROYAL_MASTER/Royal Master/""/0/30d/₹1800/"badge_royal_master_1799"/LOTTIE:1ifJxiC6l59fQ1i-RulfLn2SzJfw5sgiJ/default=false/active=true`,
		`ROYAL_EMPEROR/Royal Emperor/""/0/45d/₹2500/"badge_royal_emperor_2499"/LOTTIE:1gBUNiLrdoSqkL29UEKCI7DjqAr8wZiSd/default=false/active=true`,
		`ROYAL_LEGEND/Royal Legend/""/0/60d/₹3300/"badge_royal_legend_3299"/LOTTIE:1kn5KJLW96mcMaXLygpvM_sIxPA7L1Ov-/default=false/active=true`,
		`ROYAL_KING_OF_KINGS/Royal King of Kings/""/0/90d/₹4500/"badge_royal_king_of_kings_4499"/LOTTIE:1A1ckgYQjocbcYfeJsOKFNO8hCrCDCWNI/default=false/active=true`,
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("badges:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	if f.count(`SELECT count(*) FROM user_badges`) != 0 {
		t.Error("the seed gives nobody a badge")
	}
}

// dailyXPOnly switches the ONE_TIME missions off (28 Sep 2026), for a test
// of the DAILY XP alone: a first hand and a first win complete missions too,
// and their XP would stand in every total the daily rules are checked by.
// missions_test.go checks the two together — the daily sources earning
// exactly what they do here beside the missions' XP.
func (f *fixture) dailyXPOnly() {
	f.t.Helper()
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE xp_sources SET is_active = FALSE WHERE mission_type = 'ONE_TIME'`); err != nil {
		f.t.Fatal(err)
	}
}

// setXP gives a player xp directly.
func (f *fixture) setXP(userID string, xp int64) {
	f.t.Helper()
	if _, err := f.d.Pool.Exec(f.ctx, `INSERT INTO player_xp (user_id, xp, created_at, updated_at) VALUES ($1, $2, 1, 1)
	     ON CONFLICT (user_id) DO UPDATE SET xp = EXCLUDED.xp`, userID, xp); err != nil {
		f.t.Fatal(err)
	}
}

// grant gives a player a badge with the seed header's statement, as an owner
// would — for the badge's validity from now, which renews a grant already
// there.
func (f *fixture) grant(userID, code string) {
	f.t.Helper()
	if _, err := f.d.Pool.Exec(f.ctx, `INSERT INTO user_badges (user_id, badge_code) VALUES ($1, $2)
     ON CONFLICT (user_id, badge_code) DO UPDATE
        SET granted_at = EXCLUDED.granted_at, expires_at = EXCLUDED.expires_at`, userID, code); err != nil {
		f.t.Fatal(err)
	}
}

// grantUntil gives a player a badge until expiresAt (epoch ms; 0: for ever) —
// the seed header's statement for a term of the grant's own.
func (f *fixture) grantUntil(userID, code string, expiresAt int64) {
	f.t.Helper()
	if _, err := f.d.Pool.Exec(f.ctx, `INSERT INTO user_badges (user_id, badge_code, expires_at) VALUES ($1, $2, $3)
     ON CONFLICT (user_id, badge_code) DO UPDATE SET expires_at = EXCLUDED.expires_at`, userID, code, expiresAt); err != nil {
		f.t.Fatal(err)
	}
}

// ownerBadge adds a badge the way an owner would, by hand: a rate, a validity
// in days and a place in the badges' order (the seed's are Regular at 10 and
// the Royal badges at 20 to 70). The seed's own badges are Regular's 20% and
// the Royal badges' 0%, so a test of the lowest-rate rule makes the ones in
// between it needs.
func (f *fixture) ownerBadge(code, title string, taxBps, validityDays, sortOrder int) {
	f.t.Helper()
	if _, err := f.d.Pool.Exec(f.ctx, `INSERT INTO badges (code, title, icon, tax_bps, validity_days, sort_order)
	     VALUES ($1, $2, '', $3, $4, $5)`, code, title, taxBps, validityDays, sortOrder); err != nil {
		f.t.Fatal(err)
	}
}

// badgeCodes are the codes of the badges a standing holds, in order.
func badgeCodes(s db.Standing) string {
	codes := make([]string, len(s.Badges))
	for i, b := range s.Badges {
		codes[i] = b.Code
	}
	return strings.Join(codes, ",")
}

// TestTheLevelFollowsTheXP: the highest level whose threshold the XP has
// reached, with the next one beside it; the ladder's lowest rung when an
// owner's edit leaves no level that low; and the account — Regular its only
// badge (owner, 27 Sep 2026: "By default every user will hold this Regular
// badge 20 percent tax") — pays its level's rate, which the seat it is built
// from carries.
// TestTheLevelArtFillsWhatIsMissingAndKeepsAnOwnersOwn: the seed's art list
// fills a level's asset_url only where it is NULL — every boot, so a URL added
// to the list later reaches a database whose ladder is older — and never
// touches an owner's own URL or a level set to ” (none on purpose).
func TestTheLevelArtFillsWhatIsMissingAndKeepsAnOwnersOwn(t *testing.T) {
	f := newFixture(t)
	// The levels the owner has not sent art for yet: the first takes an
	// owner's own URL by hand, the second is left without.
	var missing []int
	for level := 1; level <= 50 && len(missing) < 2; level++ {
		if _, ok := ownersLevelArt[level]; !ok {
			missing = append(missing, level)
		}
	}
	want := map[int]string{
		1: ownersLevelArt[1],                // refilled
		4: ownersLevelArt[4],                // refilled
		2: "https://owner.test/rookie.json", // the owner's own, kept
		3: "",                               // none on purpose, kept
	}
	queries := []string{
		`UPDATE player_levels SET asset_url = NULL, asset_format = NULL WHERE level IN (1, 4)`,
		`UPDATE player_levels SET asset_url = 'https://owner.test/rookie.json', asset_format = 'LOTTIE' WHERE level = 2`,
		`UPDATE player_levels SET asset_url = '', asset_format = NULL WHERE level = 3`,
	}
	if len(missing) > 0 {
		queries = append(queries, fmt.Sprintf(
			`UPDATE player_levels SET asset_url = 'https://owner.test/own.json', asset_format = 'LOTTIE' WHERE level = %d`, missing[0]))
		want[missing[0]] = "https://owner.test/own.json" // the owner's own on a level the seed has none for
	}
	if len(missing) > 1 {
		want[missing[1]] = "<NULL>" // not given yet
	}
	for _, q := range queries {
		if _, err := f.d.Pool.Exec(f.ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	// Another boot on the same schema.
	d, err := db.Open(f.ctx, db.Options{URL: testURL(), Schema: f.d.Schema, PoolMax: 2})
	if err != nil {
		t.Fatalf("the boot: %v", err)
	}
	t.Cleanup(d.Close)
	art := func(level int) string {
		t.Helper()
		var url *string
		if err := d.Pool.QueryRow(f.ctx, `SELECT asset_url FROM player_levels WHERE level = $1`, level).Scan(&url); err != nil {
			t.Fatal(err)
		}
		if url == nil {
			return "<NULL>"
		}
		return *url
	}
	for level, w := range want {
		if got := art(level); got != w {
			t.Errorf("level %d's art after a boot: %q, want %q", level, got, w)
		}
	}
	// '' reads as no art at all.
	if l := levelOn(t, d, 3); l.AssetURL != "" || l.AssetFormat != "" {
		t.Errorf("level 3 set to '': %+v, want no art", l)
	}
}

// TestTheLevelArtServedHereIsInThePublicDir: a level's art named by a path
// (Level 1's, /levels/newbie.json) is a file this server serves from its
// public dir — in production too, where ROOT_REDIRECT hides only the top
// level — and a Lottie a phone can play all the way through: no loopOut()
// left in it (CLAUDE.md §12.3).
func TestLevel20sFirstArtIsMovedOntoItsReplacementAndNothingElse(t *testing.T) {
	f := newFixture(t)
	// A database that took the first list: Level 20 on its 4.1 MB upload.
	// Level 21 on an owner's own URL stays whatever it is.
	for _, q := range []string{
		`UPDATE player_levels SET asset_url = 'https://drive.google.com/uc?export=download&id=1ABHkYZ0N3O_BDBI1UpBfoVvWilXPTnxf' WHERE level = 20`,
		`UPDATE player_levels SET asset_url = 'https://owner.test/royal.json' WHERE level = 21`,
	} {
		if _, err := f.d.Pool.Exec(f.ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	d, err := db.Open(f.ctx, db.Options{URL: testURL(), Schema: f.d.Schema, PoolMax: 2})
	if err != nil {
		t.Fatalf("the boot: %v", err)
	}
	t.Cleanup(d.Close)
	if got := levelOn(t, d, 20); got.AssetURL != "/levels/high-roller.json" || got.AssetFormat != "LOTTIE" {
		t.Errorf("level 20 after a boot: %q %q, want the served replacement", got.AssetURL, got.AssetFormat)
	}
	if got := levelOn(t, d, 21).AssetURL; got != "https://owner.test/royal.json" {
		t.Errorf("level 21 after a boot: %q, want the owner's own kept", got)
	}
}

func TestTheLevelArtServedHereIsInThePublicDir(t *testing.T) {
	for level, url := range ownersLevelArt {
		if !strings.HasPrefix(url, "/") {
			continue
		}
		if strings.Count(url, "/") < 2 {
			t.Errorf("level %d's art %s sits at the top of the public dir, which production hides", level, url)
		}
		raw, err := os.ReadFile(filepath.Join("..", "..", "public", filepath.FromSlash(url)))
		if err != nil {
			t.Fatalf("level %d's art: %v", level, err)
		}
		var lottie struct {
			V      string            `json:"v"`
			W      int               `json:"w"`
			Layers []json.RawMessage `json:"layers"`
		}
		if err := json.Unmarshal(raw, &lottie); err != nil || lottie.V == "" || lottie.W <= 0 || len(lottie.Layers) == 0 {
			t.Errorf("level %d's art %s is not a Lottie: %v", level, url, err)
		}
		if strings.Contains(string(raw), "loopOut") {
			t.Errorf("level %d's art %s still loops with loopOut(), which a phone does not run", level, url)
		}
	}
}

// levelOn is one rung of the ladder as d reads it.
func levelOn(t *testing.T, d *db.DB, level int) db.LadderLevel {
	t.Helper()
	ladder, err := db.NewXP(d, nil).Ladder(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, l := range ladder.Levels {
		if l.Level == level {
			return l
		}
	}
	t.Fatalf("no level %d", level)
	return db.LadderLevel{}
}

func TestTheLevelFollowsTheXP(t *testing.T) {
	f := newFixture(t)
	u := f.user("Climber")
	fresh := f.find(u.ID).PlayerLevel
	want := db.PlayerLevel{Level: 1, Title: "Newbie", Icon: "\U0001F331", XP: 0, TaxBps: 2000,
		AssetURL: ownersLevelArt[1], AssetFormat: "LOTTIE",
		Next: &db.NextLevel{Level: 2, Title: "Rookie", Icon: "\U0001F530", MinXP: 100, TaxBps: 1971,
			AssetURL: ownersLevelArt[2], AssetFormat: "LOTTIE"}}
	if !reflect.DeepEqual(fresh, want) {
		t.Fatalf("a new account: %+v, want %+v", fresh, want)
	}
	if got := f.find(u.ID); badgeCodes(got.Standing) != "REGULAR" || got.TaxBps != 2000 ||
		got.Badges[0].TaxBps == nil || *got.Badges[0].TaxBps != 2000 || got.Badges[0].ExpiresAt != 0 ||
		got.Badges[0].Title != "Regular" || !got.Badges[0].IsDefault || got.Badges[0].AssetFormat != "LOTTIE" {
		t.Errorf("a new account holds Regular alone, for life, and pays its level's rate: %+v", got.Standing)
	}
	if p := f.find(u.ID).Player(); p.TaxBps != 2000 {
		t.Errorf("the seat is built at the account's rate: %d", p.TaxBps)
	}
	for _, tc := range []struct {
		xp    int64
		level int
		title string
		bps   int
		next  int
	}{
		{99, 1, "Newbie", 2000, 2},
		{100, 2, "Rookie", 1971, 3},
		{4000, 10, "Rising Star", 1743, 11},
		{5199, 10, "Rising Star", 1743, 11},
		{1_999_999, 49, "Supreme Legend", 629, 50},
		{2_000_000, 50, "King of Kings", 600, 0},
	} {
		f.setXP(u.ID, tc.xp)
		got := f.find(u.ID).PlayerLevel
		if got.Level != tc.level || got.Title != tc.title || got.TaxBps != tc.bps || got.XP != tc.xp {
			t.Errorf("%d XP: %+v, want level %d %q at %d", tc.xp, got, tc.level, tc.title, tc.bps)
		}
		if paid := f.find(u.ID).TaxBps; paid != tc.bps {
			t.Errorf("%d XP pays %d, want the level's %d", tc.xp, paid, tc.bps)
		}
		if tc.next == 0 && got.Next != nil || tc.next != 0 && (got.Next == nil || got.Next.Level != tc.next) {
			t.Errorf("%d XP: next %+v, want level %d", tc.xp, got.Next, tc.next)
		}
	}
	// An owner's edit that leaves no level as low as the XP: the lowest rung.
	other := f.user("Bottom")
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE player_levels SET min_xp = 10 WHERE level = 1`); err != nil {
		t.Fatal(err)
	}
	if got := f.find(other.ID).PlayerLevel; got.Level != 1 || got.TaxBps != 2000 || got.Next == nil || got.Next.Level != 2 {
		t.Errorf("below every threshold: %+v, want the lowest rung with level 2 next", got)
	}
}

// TestXPNeverGrantsABadge (owner, 26 Sep 2026: "remember VIP Tag is not
// granted by XP" — true of every badge; 27 Sep 2026: "Vip is not a level, it is badge"): any amount
// of XP stops at level 50 with nothing next and leaves the player with
// Regular alone; an award never writes a badge; levels and XP never expire
// ("there is no validity on player level", "XP also never expire").
func TestXPNeverGrantsABadge(t *testing.T) {
	f := newFixture(t)
	u := f.user("Grinder")
	f.setXP(u.ID, 9_000_000_000)
	got := f.find(u.ID)
	if got.PlayerLevel.Level != 50 || got.PlayerLevel.TaxBps != 600 || got.PlayerLevel.Next != nil ||
		badgeCodes(got.Standing) != "REGULAR" || got.TaxBps != 600 {
		t.Fatalf("more XP than level 50 needs: %+v, want level 50 at 6%%, Regular alone, nothing next", got.Standing)
	}
	// A win with a trail and two hours of play, all the XP a day holds.
	h := f.playHand(f.ledger, u.ID, f.user("Rival").ID, "TRAIL")
	xp := db.NewXP(f.d, nil)
	if _, changed, err := xp.AwardPlayTime(f.ctx, u.ID, h.Windows[u.ID], 2*time.Hour); err != nil || !changed {
		t.Fatalf("award: %v %v", changed, err)
	}
	if n := f.count(`SELECT count(*) FROM user_badges WHERE user_id = $1`, u.ID); n != 0 {
		t.Fatal("an award must never grant a badge")
	}
	// The next level is only ever a level.
	f.setXP(u.ID, 1_700_000)
	if got := f.find(u.ID).PlayerLevel; got.Next == nil || got.Next.Level != 50 {
		t.Fatalf("level 49's next is level 50: %+v", got.Next)
	}

	var pgErr *pgconn.PgError
	for name, sql := range map[string]string{
		"a rate above the whole pot": `UPDATE player_levels SET tax_bps = 10001 WHERE level = 1`,
		"a negative XP":              `UPDATE player_xp SET xp = -1 WHERE user_id = '` + u.ID + `'`,
		"a badge above the pot":      `UPDATE badges SET tax_bps = 10001 WHERE code = 'ROYAL_KING'`,
		"a negative validity":        `UPDATE badges SET validity_days = -1 WHERE code = 'ROYAL_KING'`,
		"a grant ending before 1970": `INSERT INTO user_badges (user_id, badge_code, expires_at) VALUES ('` + u.ID + `', 'ROYAL_KING', -1)`,
	} {
		if _, err := f.d.Pool.Exec(f.ctx, sql); !errors.As(err, &pgErr) || pgErr.Code != "23514" {
			t.Errorf("%s must be refused by a CHECK, got %v", name, err)
		}
	}
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE player_levels SET min_xp = NULL WHERE level = 50`); !errors.As(err, &pgErr) || pgErr.Code != "23502" {
		t.Errorf("a level with no XP threshold must be refused, got %v", err)
	}
	if _, err := f.d.Pool.Exec(f.ctx, `INSERT INTO user_badges (user_id, badge_code) VALUES ($1, 'NOBODY')`, u.ID); !errors.As(err, &pgErr) || (pgErr.Code != "23503" && pgErr.Code != "23502") {
		t.Errorf("a grant of a badge that does not exist must be refused, got %v", err)
	}
}

// TestTheWinningTaxIsTheLowestOfTheLevelAndTheBadges (owner, 27 Sep 2026:
// "the tax will be applied acc to minimum of badge or player level"): a badge
// given by the seed header's plain INSERT lasts its validity from the grant;
// the player holds Regular and every badge given, in the badges' order; the
// rate they pay — on the account, on the seat built from it, and in a
// settlement's rates — is the lowest of their level's and their badges'; a
// retired badge stops counting; and deleting the account takes its badges.
func TestTheWinningTaxIsTheLowestOfTheLevelAndTheBadges(t *testing.T) {
	f := newFixture(t)
	f.ownerBadge("GOLD", "Gold", 500, 1825, 12)
	f.ownerBadge("PLATINUM", "Platinum", 300, 1825, 14)
	u := f.user("Maharaja")
	before := time.Now().UnixMilli()
	f.grant(u.ID, "GOLD")
	after := time.Now().UnixMilli()
	got := f.find(u.ID)
	if badgeCodes(got.Standing) != "REGULAR,GOLD" || got.TaxBps != 500 || got.PlayerLevel.TaxBps != 2000 {
		t.Fatalf("Level 1 with Gold: %+v, want Regular and Gold, paying Gold's 5%%", got.Standing)
	}
	gold := got.Badges[1]
	const fiveYears = int64(1825 * 24 * time.Hour / time.Millisecond)
	if gold.Title != "Gold" || gold.TaxBps == nil || *gold.TaxBps != 500 || gold.ExpiresAt < before+fiveYears || gold.ExpiresAt > after+fiveYears {
		t.Errorf("the Gold grant: %+v, want 5%% for its validity (1825 days) from the grant", gold)
	}
	if p := got.Player(); p.TaxBps != 500 {
		t.Errorf("the seat is built at the rate paid: %d", p.TaxBps)
	}
	// A level whose rate is lower than every badge's is what is paid.
	f.setXP(u.ID, 2_000_000)
	if paid := f.find(u.ID).TaxBps; paid != 500 {
		t.Errorf("Level 50 (6%%) with Gold (5%%) pays %d, want 500", paid)
	}
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE player_levels SET tax_bps = 450 WHERE level = 50`); err != nil {
		t.Fatal(err)
	}
	if paid := f.find(u.ID).TaxBps; paid != 450 {
		t.Errorf("a level at 4.5%% under Gold's 5%% pays %d, want 450", paid)
	}
	// Several badges: the lowest counts, and they read in the badges' order.
	f.grant(u.ID, "ROYAL_KING")
	f.grant(u.ID, "PLATINUM")
	got = f.find(u.ID)
	if badgeCodes(got.Standing) != "REGULAR,GOLD,PLATINUM,ROYAL_KING" || got.TaxBps != 0 {
		t.Fatalf("four badges: %+v, want all four and Royal King's 0%%", got.Standing)
	}
	// The settlement hands the seat the rate paid.
	other := f.user("Rival")
	hand := "hand-badges-" + randomSuffix(t)
	settled, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: "r", HandID: hand, Entries: []game.SettleEntry{
		settleEntry(hand, u.ID, 100, true, true, 200), settleEntry(hand, other.ID, -100, false, true, 0),
	}})
	if err != nil {
		t.Fatal(err)
	}
	if settled.TaxBps[u.ID] != 0 || settled.TaxBps[other.ID] != 2000 {
		t.Errorf("the rates the seats take: %+v", settled.TaxBps)
	}
	// A retired badge stops counting; the next lowest decides.
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE badges SET is_active = FALSE WHERE code = 'ROYAL_KING'`); err != nil {
		t.Fatal(err)
	}
	if got := f.find(u.ID); badgeCodes(got.Standing) != "REGULAR,GOLD,PLATINUM" || got.TaxBps != 300 {
		t.Errorf("Royal King retired: %+v, want Platinum's 3%%", got.Standing)
	}
	// Regular is 20%, above any level's: with no other badge, the level
	// decides.
	if _, err := f.d.Pool.Exec(f.ctx, `DELETE FROM user_badges WHERE user_id = $1`, u.ID); err != nil {
		t.Fatal(err)
	}
	if got := f.find(u.ID); badgeCodes(got.Standing) != "REGULAR" || got.TaxBps != 450 {
		t.Errorf("Regular alone: %+v, want the level's 4.5%%", got.Standing)
	}
	// A default badge is every player's with no row, for ever, and counts
	// like any other: another an owner adds with a lower rate is what they
	// pay.
	if _, err := f.d.Pool.Exec(f.ctx, `INSERT INTO badges (code, title, icon, tax_bps, validity_days, is_default, sort_order)
	     VALUES ('HOUSE', 'House', '🏠', 400, 0, TRUE, 5)`); err != nil {
		t.Fatal(err)
	}
	if got := f.find(u.ID); badgeCodes(got.Standing) != "HOUSE,REGULAR" || got.TaxBps != 400 || got.Badges[0].ExpiresAt != 0 ||
		!got.Badges[0].IsDefault {
		t.Errorf("an owner's default badge: %+v, want everyone holding it at its 4%%", got.Standing)
	}
	if got := f.find(other.ID); badgeCodes(got.Standing) != "HOUSE,REGULAR" {
		t.Errorf("the default badge is every player's: %+v", got.Standing)
	}
	if _, err := f.d.Pool.Exec(f.ctx, `DELETE FROM badges WHERE code = 'HOUSE'`); err != nil {
		t.Fatal(err)
	}
	// An account deleted takes its badges with it.
	f.grant(u.ID, "GOLD")
	if err := f.users.DeleteAccount(f.ctx, u.ID); err != nil {
		t.Fatal(err)
	}
	if n := f.count(`SELECT count(*) FROM user_badges WHERE user_id = $1`, u.ID); n != 0 {
		t.Errorf("a deleted account keeps %d badges", n)
	}
}

// TestABadgeStopsCountingWhenItsGrantRunsOut (owner, 27 Sep 2026: "add
// validity column in badges so that when it expires, player will not get tax
// benefit"): a badge counts until the instant its grant runs out and not from
// then on — on the account, and in the rate a settlement hands the seat —
// while the level and the XP never run out; the plain grant renews it for
// another validity; and a grant naming 0 lasts for ever.
func TestABadgeStopsCountingWhenItsGrantRunsOut(t *testing.T) {
	f := newFixture(t)
	clock := &testClock{now: time.Now()}
	users := db.NewUsers(f.d, welcome, clock.Now)
	ledger := db.NewLedger(f.d, nil, clock.Now)
	u := f.user("Temporary")
	f.setXP(u.ID, 4000) // Level 10, 17.43%, never to expire
	ends := clock.Now().UnixMilli() + int64(time.Hour/time.Millisecond)
	f.grantUntil(u.ID, "ROYAL_KING", ends)
	read := func() *db.User {
		t.Helper()
		got, err := users.FindByID(f.ctx, u.ID)
		if err != nil || got == nil {
			t.Fatalf("read: %v", err)
		}
		return got
	}
	if got := read(); got.TaxBps != 0 || badgeCodes(got.Standing) != "REGULAR,ROYAL_KING" || got.Badges[1].ExpiresAt != ends {
		t.Fatalf("while it runs: %+v", got.Standing)
	}
	clock.Advance(time.Hour - time.Millisecond)
	if got := read(); got.TaxBps != 0 {
		t.Fatalf("a millisecond before it runs out: %d, want 0", got.TaxBps)
	}
	clock.Advance(time.Millisecond)
	got := read()
	if got.TaxBps != 1743 || badgeCodes(got.Standing) != "REGULAR" || got.PlayerLevel.Level != 10 || got.PlayerLevel.XP != 4000 {
		t.Fatalf("run out: %+v, want Level 10's 17.43%% and the level and XP kept", got.Standing)
	}
	// The settlement hands the seat the rate without it.
	other := f.user("Opponent")
	hand := "hand-expiry-" + randomSuffix(t)
	settled, err := ledger.Settle(f.ctx, game.SettleRequest{RoomID: "r", HandID: hand, Entries: []game.SettleEntry{
		settleEntry(hand, u.ID, 100, true, true, 200), settleEntry(hand, other.ID, -100, false, true, 0),
	}})
	if err != nil {
		t.Fatal(err)
	}
	if settled.TaxBps[u.ID] != 1743 {
		t.Errorf("the settled rate after the grant ran out: %d, want 1743", settled.TaxBps[u.ID])
	}
	// The row stays as the record; the plain grant renews it for its
	// validity, fifteen days, from the database's now.
	if n := f.count(`SELECT count(*) FROM user_badges WHERE user_id = $1`, u.ID); n != 1 {
		t.Fatalf("an expired grant is kept as the record: %d rows", n)
	}
	f.grant(u.ID, "ROYAL_KING")
	if f.count(`SELECT count(*) FROM user_badges WHERE user_id = $1 AND badge_code = 'ROYAL_KING'
	     AND expires_at = granted_at + 15::bigint * 86400000`, u.ID) != 1 {
		t.Error("the plain grant renews the badge for its validity from now")
	}
	// A grant naming 0 is for ever, whatever the badge's validity.
	f.grantUntil(u.ID, "ROYAL_ACE", 0)
	clock.Advance(10 * 365 * 24 * time.Hour)
	if got := read(); badgeCodes(got.Standing) != "REGULAR,ROYAL_ACE" || got.TaxBps != 0 || got.Badges[1].ExpiresAt != 0 {
		t.Errorf("ten years on: %+v, want Royal Ace for ever and Royal King run out", got.Standing)
	}
	// A badge with no validity lasts for ever when granted plainly.
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE badges SET validity_days = 0 WHERE code = 'ROYAL_MASTER'`); err != nil {
		t.Fatal(err)
	}
	f.grant(u.ID, "ROYAL_MASTER")
	if n := f.count(`SELECT count(*) FROM user_badges WHERE user_id = $1 AND badge_code = 'ROYAL_MASTER' AND expires_at = 0`, u.ID); n != 1 {
		t.Error("a badge of 0 days is granted for ever")
	}
}

// testClock is a clock a test moves by hand.
type testClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *testClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *testClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

// playHand settles a two-player Teen Patti hand through ledger — winner beats
// loser holding wonWith ("" for a poker-style entry that names no hand) — and
// returns what the ledger told its OnSettled hook.
func (f *fixture) playHand(ledger *db.Ledger, winner, loser, wonWith string) db.SettledHand {
	f.t.Helper()
	seen := &settledHands{}
	ledger.OnSettled(seen.hook)
	defer ledger.OnSettled(nil)
	hand := "hand-xp-" + randomSuffix(f.t)
	w := settleEntry(hand, winner, 100, true, true, 200)
	w.WonWith = wonWith
	if _, err := ledger.Settle(f.ctx, game.SettleRequest{RoomID: "r", HandID: hand, PlayedMs: 60_000, Entries: []game.SettleEntry{
		w, settleEntry(hand, loser, -100, false, true, 0),
	}}); err != nil {
		f.t.Fatal(err)
	}
	hands := seen.all()
	if len(hands) != 1 {
		f.t.Fatalf("OnSettled heard %d settlements, want 1", len(hands))
	}
	return hands[0]
}

// TestEachDailyXPSourceIsEarnedOnceAWindow (owner, 27 Sep 2026: "Daily XP user
// can get … 1 time … After 24 hours this will be reset, so user can claim this
// again"; "Don't set any daily limit to xp"): the first hand a player completes
// opens their window; a win earns the source of the hand it was won with, once
// a window, and a hand no source names earns nothing; play reaches the
// 15-, 60- and 120-minute sources once each, and play counted for a window
// gone by earns nothing; the account carries what has been earned in the
// window and when it resets, and no "today" (there is no cap); and 24 hours
// on, every source is there to be earned again.
func TestEachDailyXPSourceIsEarnedOnceAWindow(t *testing.T) {
	f := newFixture(t)
	f.dailyXPOnly()
	clock := &testClock{now: time.UnixMilli(1_800_000_000_000)}
	ledger := db.NewLedger(f.d, nil, clock.Now)
	xp := db.NewXP(f.d, clock.Now)
	users := db.NewUsers(f.d, welcome, clock.Now)
	a, b := f.user("Daily"), f.user("Other")
	read := func(id string) db.PlayerLevel {
		t.Helper()
		got, err := users.FindByID(f.ctx, id)
		if err != nil || got == nil {
			t.Fatalf("read %s: %v", id, err)
		}
		return got.PlayerLevel
	}
	opened := clock.Now().UnixMilli()

	// A win with a pair: +1, and both players' windows open.
	h := f.playHand(ledger, a.ID, b.ID, "PAIR")
	if h.Windows[a.ID] != opened || h.Windows[b.ID] != opened || h.Window != 24*time.Hour {
		t.Fatalf("the windows: %+v, want both opened at %d", h.Windows, opened)
	}
	if got := read(a.ID); got.XP != 1 || got.Today != nil || got.Daily == nil ||
		!reflect.DeepEqual(got.Daily.Claimed, map[string]int{"WIN_PAIR": 1}) || got.Daily.ResetsAt != opened+86_400_000 {
		t.Fatalf("after a pair: %+v (daily %+v), want 1 XP, WIN_PAIR earned, reset in 24 h", got, got.Daily)
	}
	if got := read(b.ID); got.XP != 0 || got.Daily == nil || len(got.Daily.Claimed) != 0 {
		t.Fatalf("the loser: %+v, want no XP and an open window with nothing earned", got)
	}
	if raw, _ := json.Marshal(read(a.ID)); strings.Contains(string(raw), `"today"`) || !strings.Contains(string(raw), `"daily":{"claimed":{"WIN_PAIR":1}`) {
		t.Errorf("the wire: %s", raw)
	}
	// Another pair: nothing (once a window); a trail: +20; a high card, which
	// no source names: nothing.
	f.playHand(ledger, a.ID, b.ID, "PAIR")
	f.playHand(ledger, a.ID, b.ID, "TRAIL")
	f.playHand(ledger, a.ID, b.ID, "HIGH_CARD")
	if got := read(a.ID); got.XP != 21 || !reflect.DeepEqual(got.Daily.Claimed, map[string]int{"WIN_PAIR": 1, "WIN_TRAIL": 1}) {
		t.Fatalf("pair, trail, high card: %+v %+v, want 21 XP", got, got.Daily)
	}

	// Play time: 14 minutes earns nothing, 15 the 15-minute source, 119 the
	// 60-minute one, 120 the 120-minute one, and asking again nothing more.
	window := h.Windows[a.ID]
	for _, step := range []struct {
		play    time.Duration
		changed bool
		xp      int64
	}{
		{14 * time.Minute, false, 21},
		{15 * time.Minute, true, 24},
		{15 * time.Minute, false, 24},
		{119 * time.Minute, true, 44},
		{120 * time.Minute, true, 94},
		{5 * time.Hour, false, 94},
	} {
		got, changed, err := xp.AwardPlayTime(f.ctx, a.ID, window, step.play)
		if err != nil || changed != step.changed {
			t.Fatalf("%v of play: changed %v %v, want %v", step.play, changed, err, step.changed)
		}
		if changed && got.PlayerLevel.XP != step.xp {
			t.Fatalf("%v of play: %d XP, want %d", step.play, got.PlayerLevel.XP, step.xp)
		}
		if lvl := read(a.ID); lvl.XP != step.xp {
			t.Fatalf("%v of play: the account holds %d XP, want %d", step.play, lvl.XP, step.xp)
		}
	}
	// Play counted for another window earns nothing.
	if _, changed, err := xp.AwardPlayTime(f.ctx, b.ID, window-1, 3*time.Hour); err != nil || changed {
		t.Fatalf("play for a window gone by: %v %v", changed, err)
	}
	// Nor does a player with no window at all.
	if _, changed, err := xp.AwardPlayTime(f.ctx, f.user("Nobody").ID, window, 3*time.Hour); err != nil || changed {
		t.Fatalf("no window: %v %v", changed, err)
	}

	// 24 hours on the window has run out: nothing is running, the next hand
	// opens a new one, and every source can be earned again.
	clock.Advance(24 * time.Hour)
	if got := read(a.ID); got.Daily != nil {
		t.Fatalf("a window run out: daily %+v, want none", got.Daily)
	}
	if _, changed, err := xp.AwardPlayTime(f.ctx, a.ID, window, 3*time.Hour); err != nil || changed {
		t.Fatalf("the old window's play: %v %v", changed, err)
	}
	h = f.playHand(ledger, a.ID, b.ID, "PAIR")
	if h.Windows[a.ID] != clock.Now().UnixMilli() {
		t.Fatalf("the new window opened at %d, want now", h.Windows[a.ID])
	}
	if got := read(a.ID); got.XP != 95 || !reflect.DeepEqual(got.Daily.Claimed, map[string]int{"WIN_PAIR": 1}) {
		t.Fatalf("a new window's pair: %+v %+v, want 95 XP", got, got.Daily)
	}
	if got, changed, err := xp.AwardPlayTime(f.ctx, a.ID, h.Windows[a.ID], 15*time.Minute); err != nil || !changed || got.PlayerLevel.XP != 98 {
		t.Fatalf("a new window's 15 minutes: %+v %v %v, want 98 XP", got.PlayerLevel, changed, err)
	}
	// XP never falls and never expires: it is all still there.
	if marks, win, err := xp.PlayMarks(f.ctx); err != nil || !reflect.DeepEqual(marks, []time.Duration{15 * time.Minute, time.Hour, 2 * time.Hour}) || win != 24*time.Hour {
		t.Fatalf("play marks %v over %v: %v", marks, win, err)
	}
	// An inactive source earns nothing, and a source of a kind this build
	// does not know is never offered.
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE xp_sources SET is_active = FALSE WHERE code = 'WIN_TRAIL';
	     INSERT INTO xp_sources (code, name, kind, xp, is_active, sort_order) VALUES ('MYSTERY', 'x', 'MOON_PHASE', 99, TRUE, 5)`); err != nil {
		t.Fatal(err)
	}
	f.playHand(ledger, a.ID, b.ID, "TRAIL")
	if got := read(a.ID); got.XP != 98 {
		t.Fatalf("an inactive source: %d XP, want 98", got.XP)
	}
	if marks, _, _ := xp.PlayMarks(f.ctx); len(marks) != 3 {
		t.Fatalf("an unknown kind among the marks: %v", marks)
	}
}

// TestAnOwnersDailyCapHoldsTheWindow: where an owner sets a daily cap (the seed
// sets none), a window's XP stops at it — a source the cap leaves nothing of
// is not counted as earned, so a later window can still earn it — a cap of 0
// earns nothing, and with no settings row there is no XP (and no window) at
// all.
func TestAnOwnersDailyCapHoldsTheWindow(t *testing.T) {
	f := newFixture(t)
	f.dailyXPOnly()
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE xp_settings SET daily_cap = 50`); err != nil {
		t.Fatal(err)
	}
	clock := &testClock{now: time.UnixMilli(1_800_000_000_000)}
	ledger := db.NewLedger(f.d, nil, clock.Now)
	xp := db.NewXP(f.d, clock.Now)
	users := db.NewUsers(f.d, welcome, clock.Now)
	a, b := f.user("Capped"), f.user("Rival")
	h := f.playHand(ledger, a.ID, b.ID, "TRAIL")
	// 20, then 3 + 20 of play, then 7 of the 120-minute 50: 50 in all.
	got, changed, err := xp.AwardPlayTime(f.ctx, a.ID, h.Windows[a.ID], 2*time.Hour)
	if err != nil || !changed || got.PlayerLevel.XP != 50 || got.PlayerLevel.Today == nil ||
		*got.PlayerLevel.Today != (db.XPToday{XP: 50, Cap: 50, ResetsAt: h.Windows[a.ID] + 86_400_000}) {
		t.Fatalf("a capped window: %+v %v %v", got.PlayerLevel, changed, err)
	}
	// Capped: a pair earns nothing, and is not counted as earned.
	f.playHand(ledger, a.ID, b.ID, "PAIR")
	u, _ := users.FindByID(f.ctx, a.ID)
	if u.PlayerLevel.XP != 50 || u.PlayerLevel.Daily.Claimed["WIN_PAIR"] != 0 {
		t.Fatalf("past the cap: %+v %+v", u.PlayerLevel, u.PlayerLevel.Daily)
	}
	// The next window starts over.
	clock.Advance(24 * time.Hour)
	f.playHand(ledger, a.ID, b.ID, "PAIR")
	if u, _ := users.FindByID(f.ctx, a.ID); u.PlayerLevel.XP != 51 || u.PlayerLevel.Today.XP != 1 {
		t.Fatalf("the next window: %+v", u.PlayerLevel)
	}
	// A cap of 0 earns nothing; no settings row, no XP and no window.
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE xp_settings SET daily_cap = 0`); err != nil {
		t.Fatal(err)
	}
	f.playHand(ledger, a.ID, b.ID, "TRAIL")
	if u, _ := users.FindByID(f.ctx, a.ID); u.PlayerLevel.XP != 51 {
		t.Fatalf("a cap of 0: %d XP", u.PlayerLevel.XP)
	}
	if _, err := f.d.Pool.Exec(f.ctx, `DELETE FROM xp_settings`); err != nil {
		t.Fatal(err)
	}
	other := f.user("NoRules")
	if h := f.playHand(ledger, other.ID, b.ID, "TRAIL"); len(h.Windows) != 0 || h.Window != 0 {
		t.Fatalf("no settings row: windows %v over %v", h.Windows, h.Window)
	}
	if n := f.count(`SELECT count(*) FROM player_xp WHERE user_id = $1`, other.ID); n != 0 {
		t.Fatal("with XP off a settle writes no player_xp")
	}
	if marks, win, err := xp.PlayMarks(f.ctx); err != nil || marks != nil || win != 0 {
		t.Fatalf("no settings row: marks %v over %v: %v", marks, win, err)
	}
}

// settledHands records the ledger's OnSettled hook.
type settledHands struct {
	mu    sync.Mutex
	hands []db.SettledHand
}

func (s *settledHands) hook(h db.SettledHand) {
	s.mu.Lock()
	s.hands = append(s.hands, h)
	s.mu.Unlock()
}

func (s *settledHands) all() []db.SettledHand {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]db.SettledHand(nil), s.hands...)
}

// TestATaxedWinIsTheWinGrossAndTheTaxAsItsOwnRow: the winner's hand-end
// entry with a Tax is two chip_ledger rows in the one settlement — hand_win at
// the GROSS figure, then table_tax of minus the tax under <handId>:tax:<userId>,
// its balance the wallet's — so the hand's hand_* rows still sum to zero, the
// tax is exactly what left the game, every wallet reconciles, and a replay of
// the settlement changes nothing: no row, no chip and no XP twice.
func TestATaxedWinIsTheWinGrossAndTheTaxAsItsOwnRow(t *testing.T) {
	f := newFixture(t)
	f.dailyXPOnly()
	seen := &settledHands{}
	f.ledger.OnSettled(seen.hook)
	a, b := f.user("Winner"), f.user("Loser")
	room, hand := "room-tax", "hand-tax-"+randomSuffix(t)
	const pot, stake = int64(2000), int64(1000)
	tax := game.TableTax(pot, 2000)
	winner := settleEntry(hand, a.ID, pot-stake-tax, true, true, pot)
	winner.Tax = tax
	winner.WonWith = "SEQUENCE"
	req := game.SettleRequest{RoomID: room, HandID: hand, PlayedMs: 95_000, Entries: []game.SettleEntry{
		winner, settleEntry(hand, b.ID, -stake, false, true, 0),
	}}
	settled, err := f.ledger.Settle(f.ctx, req)
	if err != nil {
		t.Fatal(err)
	}
	if settled.Balances[a.ID] != welcome+pot-stake-tax || settled.Balances[b.ID] != welcome-stake {
		t.Fatalf("balances %+v", settled.Balances)
	}
	if f.chips(a.ID) != welcome+pot-stake-tax {
		t.Fatalf("the winner's wallet %d, want the pot less their stake less the tax", f.chips(a.ID))
	}

	rows := f.handLedgerRows(hand)
	if len(rows) != 3 {
		t.Fatalf("%d rows for the hand, want the loss, the gross win and the tax: %+v", len(rows), rows)
	}
	var handSum int64
	var taxRow *ledgerRow
	for i, r := range rows {
		switch r.Reason {
		case game.LedgerReasonTableTax:
			taxRow = &rows[i]
		case game.LedgerReasonHandWin:
			handSum += r.Delta
			if r.UserID != a.ID || r.Delta != pot-stake || r.Balance != welcome+pot-stake || *r.ActionID != game.SettleActionID(hand, a.ID) {
				t.Errorf("the win row %+v: want the gross %d at balance %d", r, pot-stake, welcome+pot-stake)
			}
		default:
			handSum += r.Delta
		}
	}
	if handSum != 0 {
		t.Errorf("the hand's hand_* rows sum to %d, want 0", handSum)
	}
	if taxRow == nil || taxRow.UserID != a.ID || taxRow.Delta != -tax || taxRow.Balance != f.chips(a.ID) ||
		taxRow.ActionID == nil || *taxRow.ActionID != game.TaxActionID(hand, a.ID) || taxRow.HandID == nil || *taxRow.HandID != hand {
		t.Fatalf("the tax row %+v: want -%d under %s at the wallet's balance, same hand", taxRow, tax, game.TaxActionID(hand, a.ID))
	}
	f.reconcile()
	// No counter moves here (Player stats v2, 27 Sep 2026): the ledger writes
	// money and XP only, and the table records the hand's counters after the
	// commit, through the stats flusher — the pot counted once, gross, the tax
	// row nothing (game.TestATaxedWinCountsThePotOnceAndTheTaxNothing).
	if u := f.find(a.ID); u.HandsWon != 0 || u.HandsPlayed != 0 || u.TotalWinnings != 0 || u.BiggestPot != 0 {
		t.Errorf("the settle wrote the winner's counters: %+v", u)
	}

	// The hand's XP, in the same transaction: a won it with a sequence (4),
	// and it opened both windows.
	if got := f.find(a.ID).PlayerLevel.XP; got != 4 {
		t.Errorf("the winner's XP %d, want the sequence's 4", got)
	}
	if got := f.find(b.ID).PlayerLevel.XP; got != 0 {
		t.Errorf("the loser's XP %d, want 0", got)
	}
	if settled.TaxBps[a.ID] != 2000 || settled.TaxBps[b.ID] != 2000 {
		t.Errorf("the rates the seats take: %+v", settled.TaxBps)
	}
	hands := seen.all()
	if len(hands) != 1 {
		t.Fatalf("OnSettled heard %d settlements, want 1", len(hands))
	}
	h := hands[0]
	if h.HandID != hand || h.PlayedMs != 95_000 || h.Window != 24*time.Hour || len(h.Players) != 2 ||
		len(h.Levels) != 1 || h.Levels[a.ID].PlayerLevel.XP != 4 || len(h.Windows) != 2 {
		t.Errorf("the settled hand: %+v", h)
	}

	// A replay — a retry whose first commit's answer was lost.
	if _, err := f.ledger.Settle(f.ctx, req); codeOf(t, err) != game.CodeDuplicateAction {
		t.Fatalf("a replay must be duplicate_action, got %v", err)
	}
	if n := len(f.handLedgerRows(hand)); n != 3 || f.chips(a.ID) != welcome+pot-stake-tax {
		t.Fatalf("the replay wrote something: %d rows, wallet %d", n, f.chips(a.ID))
	}
	if f.find(a.ID).PlayerLevel.XP != 4 || f.find(b.ID).PlayerLevel.XP != 0 {
		t.Fatal("the replay awarded XP again")
	}
	if len(seen.all()) != 1 {
		t.Fatal("a settlement that did not commit must not be heard of")
	}
	f.reconcile()
}

// TestTheSettleOpensTheWindowOfThoseWhoCompletedTheHand: every outcome row of
// a player still at the table — a push included — has its player's window
// opened (their play time counts in it), a leaver's row and a money-only row
// do not; and a poker hand's winner, whose entry names no Teen Patti hand,
// earns no "Win by …" XP.
func TestTheSettleOpensTheWindowOfThoseWhoCompletedTheHand(t *testing.T) {
	f := newFixture(t)
	f.dailyXPOnly()
	seen := &settledHands{}
	f.ledger.OnSettled(seen.hook)
	win, lose, push, leaver, money := f.user("W"), f.user("L"), f.user("P"), f.user("Gone"), f.user("Money")
	hand := "poker-hand-" + randomSuffix(t)
	pushed := settleEntry(hand, push.ID, 0, false, true, 0)
	pushed.Push = true
	gone := settleEntry(hand, leaver.ID, 0, false, true, 0)
	gone.LeftMidHand = true
	moneyOnly := game.SettleEntry{UserID: money.ID, Delta: -50, ActionID: game.SettleActionID(hand, money.ID), Reason: game.LedgerReasonHandLoss}
	entries := []game.SettleEntry{
		settleEntry(hand, win.ID, 150, true, true, 200), settleEntry(hand, lose.ID, -100, false, true, 0),
		pushed, gone, moneyOnly,
	}
	for i := range entries {
		entries[i].Game, entries[i].Variant = game.GamePoker, game.Category("texas_holdem")
	}
	if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: "poker", HandID: hand, PlayedMs: 60_000, Entries: entries}); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{win.ID, lose.ID, push.ID, leaver.ID, money.ID} {
		if got := f.find(id).PlayerLevel.XP; got != 0 {
			t.Errorf("%s: %d XP, want 0", f.find(id).DisplayName, got)
		}
	}
	h := seen.all()[0]
	if len(h.Players) != 3 || len(h.Levels) != 0 || len(h.Windows) != 3 {
		t.Errorf("the settled hand's players %v, windows %v and levels %v: the three who completed it", h.Players, h.Windows, h.Levels)
	}
	if n := f.count(`SELECT count(*) FROM player_xp WHERE window_start > 0 AND user_id IN ($1, $2, $3)`, win.ID, lose.ID, push.ID); n != 3 {
		t.Errorf("%d windows opened, want 3", n)
	}
	for _, id := range h.Players {
		if id == leaver.ID || id == money.ID {
			t.Errorf("%s did not complete the hand", id)
		}
	}
}

// TestTableTaxRowsAreNeverPurged: the purge takes a hand's hand_* rows once
// they are old enough and never its table_tax row — the house's revenue
// record, like a purchase.
func TestTableTaxRowsAreNeverPurged(t *testing.T) {
	f := newFixture(t)
	a, b := f.user("Kept"), f.user("Purged")
	hand := "hand-purge-" + randomSuffix(t)
	winner := settleEntry(hand, a.ID, 1000-400, true, true, 2000)
	winner.Tax = 400
	if _, err := f.ledger.Settle(f.ctx, game.SettleRequest{RoomID: "r", HandID: hand, Entries: []game.SettleEntry{
		winner, settleEntry(hand, b.ID, -1000, false, true, 0),
	}}); err != nil {
		t.Fatal(err)
	}
	deleted, err := f.d.PurgeLedger(f.ctx, time.Now().Add(time.Hour).UnixMilli())
	if err != nil {
		t.Fatal(err)
	}
	if deleted < 2 {
		t.Fatalf("the purge took %d rows, want the hand's hand_* rows", deleted)
	}
	rows := f.handLedgerRows(hand)
	if len(rows) != 1 || rows[0].Reason != game.LedgerReasonTableTax || rows[0].Delta != -400 {
		t.Fatalf("after the purge the hand keeps %+v, want its table_tax row alone", rows)
	}
}

// TestAnAccountReadSurvivesAnEmptyLadder: the standing rides the account's
// own read — a Users store with no player_xp row, a deleted level ladder, no
// settings row or no badges still reads the account (Level 0, no rate, no
// cap, no badge), never an error.
func TestAnAccountReadSurvivesAnEmptyLadder(t *testing.T) {
	f := newFixture(t)
	u := f.user("Ladderless")
	if _, err := f.d.Pool.Exec(context.Background(), `DELETE FROM player_levels; DELETE FROM xp_settings; DELETE FROM badges`); err != nil {
		t.Fatal(err)
	}
	got := f.find(u.ID)
	if !reflect.DeepEqual(got.PlayerLevel, db.PlayerLevel{}) || got.TaxBps != 0 || got.Badges == nil || len(got.Badges) != 0 {
		t.Fatalf("no ladder: %+v, want the zero level and an empty badge list", got.Standing)
	}
}

// GET /api/levels' read (owner, 27 Sep 2026: the tax pill, tapped, shows "all
// levels and taxes"): every level in order, every active badge with its rate
// and validity, the active XP sources in their order and the day's cap — and
// an owner's UPDATE is on it at the next read.
func TestTheLadderIsEveryLevelAndBadgeWithTheSourcesAndTheCap(t *testing.T) {
	f := newFixture(t)
	x := db.NewXP(f.d, nil)
	ladder, err := x.Ladder(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(ladder.Levels) != 50 {
		t.Fatalf("%d rungs, want 50", len(ladder.Levels))
	}
	for i, l := range ladder.Levels {
		if l.Level != i+1 || l.TaxBps != ownersLevels[i].taxBps || l.MinXP != ownersLevels[i].minXP {
			t.Fatalf("rung %d = %+v: levels 1..50 in order", i, l)
		}
	}
	first, top := ladder.Levels[0], ladder.Levels[49]
	if first.Title != "Newbie" || first.Icon != "\U0001F331" || first.MinXP != 0 || first.TaxBps != 2000 {
		t.Errorf("level 1 = %+v", first)
	}
	// Each rung carries its art where the owner has given it, and none where
	// not yet (the wire leaves the two keys out).
	for _, l := range ladder.Levels {
		if want := ownersLevelArt[l.Level]; l.AssetURL != want || (want != "") != (l.AssetFormat == "LOTTIE") {
			t.Errorf("level %d's art: %q %q, want %q", l.Level, l.AssetURL, l.AssetFormat, want)
		}
	}
	if top.Title != "King of Kings" || top.MinXP != 2000000 || top.TaxBps != 600 {
		t.Errorf("level 50 = %+v", top)
	}
	var badges []string
	for _, b := range ladder.Badges {
		rate, rupees := "none", "-"
		if b.TaxBps != nil {
			rate = fmt.Sprint(*b.TaxBps)
		}
		if b.PriceInr != nil {
			rupees = fmt.Sprint(*b.PriceInr)
		}
		badges = append(badges, fmt.Sprintf("%s:%s:%d:%v:%s:%s:%s", b.Code, rate, b.ValidityDays, b.IsDefault, rupees, b.ProductID, b.AssetFormat))
	}
	if got := strings.Join(badges, ","); got != "REGULAR:2000:0:true:0::LOTTIE,"+
		"ROYAL_ACE:0:7:false:500:badge_royal_ace_499:LOTTIE,ROYAL_KING:0:15:false:1000:badge_royal_king_999:LOTTIE,ROYAL_MASTER:0:30:false:1800:badge_royal_master_1799:LOTTIE,"+
		"ROYAL_EMPEROR:0:45:false:2500:badge_royal_emperor_2499:LOTTIE,ROYAL_LEGEND:0:60:false:3300:badge_royal_legend_3299:LOTTIE,ROYAL_KING_OF_KINGS:0:90:false:4500:badge_royal_king_of_kings_4499:LOTTIE" {
		t.Errorf("badges = %s", got)
	}
	if url := ladder.Badges[1].AssetURL; url != "https://drive.google.com/uc?export=download&id=1lwt8uXauqnX77WEb73xZAbTz_TR-rJKm" {
		t.Errorf("Royal Ace's Lottie is %q", url)
	}
	var codes []string
	for _, s := range ladder.XPSources {
		codes = append(codes, fmt.Sprintf("%s:%d", s.Code, s.XP))
	}
	if got := strings.Join(codes, ","); got != "PLAY_15_MIN:3,PLAY_60_MIN:20,PLAY_120_MIN:50,WIN_PAIR:1,WIN_COLOR:2,WIN_SEQUENCE:4,WIN_PURE_SEQUENCE:8,WIN_TRAIL:20" {
		t.Errorf("sources = %s", got)
	}
	play15, pair := ladder.XPSources[0], ladder.XPSources[3]
	if play15.Name != "Play 15 active minutes" || play15.Icon != "\U0001F3AE" || play15.Kind != db.XPKindPlayTime ||
		play15.PlayMinutes == nil || *play15.PlayMinutes != 15 || play15.Times != 1 || play15.HandRank != "" {
		t.Errorf("the first source: %+v", play15)
	}
	if pair.Kind != db.XPKindWinHand || pair.HandRank != "PAIR" || pair.PlayMinutes != nil || pair.Icon != "\U0001F465" {
		t.Errorf("the pair source: %+v", pair)
	}
	if ladder.DailyCap != nil || ladder.WindowMs != 86400000 {
		t.Errorf("cap %v over %d ms, want none over 24 h", ladder.DailyCap, ladder.WindowMs)
	}

	// An owner's edit is on the next read; an inactive source is left out.
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE xp_sources SET is_active = FALSE WHERE code = 'WIN_PAIR'`); err != nil {
		t.Fatal(err)
	}
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE player_levels SET tax_bps = 1990 WHERE level = 2;
	     UPDATE badges SET is_active = FALSE WHERE code = 'ROYAL_LEGEND'`); err != nil {
		t.Fatal(err)
	}
	ladder, err = x.Ladder(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(ladder.XPSources) != 7 || ladder.Levels[1].TaxBps != 1990 || len(ladder.Badges) != 6 {
		t.Errorf("after the edits: %d sources, level 2 at %d bps, %d badges", len(ladder.XPSources), ladder.Levels[1].TaxBps, len(ladder.Badges))
	}
}
