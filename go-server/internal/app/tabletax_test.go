package app

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket/testclient"
)

// The winning tax and the player levels over real sockets and PostgreSQL
// (owner, 26–27 Sep 2026). A table that taxes its winners says so on its menu
// entry and its snapshot, with the smallest winnings it taxes, tells each
// player their own rate, takes the WINNER's rate — the lowest of their level's
// and their badges' — of what they won (the pot less their own chips), and
// books the win gross with the tax beside it; the hand's XP reaches each
// player as player:level. An untaxed table's frames carry none of it.

type taxPlayer struct {
	id, token string
	c         *testclient.Client
}

func (p taxPlayer) frame(t *testing.T, mark int, event string, pred func(json.RawMessage) bool) json.RawMessage {
	t.Helper()
	raw, err := p.c.WaitFrom(mark, event, pred, 6*time.Second)
	if err != nil {
		t.Fatalf("%s: no %s: %v", p.id, event, err)
	}
	return raw
}

func decodeMap(t *testing.T, raw json.RawMessage) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("%s: %v", raw, err)
	}
	return m
}

func menuEntry(t *testing.T, ready json.RawMessage, category string, boot float64) map[string]any {
	t.Helper()
	tables, _ := jsonPath(ready, "config.tables").([]any)
	for _, e := range tables {
		entry, _ := e.(map[string]any)
		if entry["category"] == category && entry["bootAmount"] == boot {
			return entry
		}
	}
	t.Fatalf("no %s:%v on the menu: %s", category, boot, ready)
	return nil
}

func TestATaxingTableTaxesTheWinnerAtTheirLevelsRateOverTheSocket(t *testing.T) {
	a, database := newApp(t, func(cfg *config.Config) {
		cfg.Game.LobbyTables = []config.LobbyTable{
			{Category: "blind", BootAmount: 1000, WinnerTax: true},
			{Category: "seen", BootAmount: 200},
		}
		// The hand below is won with winnings of exactly 1,000, which a
		// minimum of 1,000 taxes (30 Lakh in production: a figure a test
		// hand would take hundreds of rounds to reach).
		cfg.Game.WinnerTaxMinWinnings = 1000
		cfg.Game.NextHandDelay = 1500 * time.Millisecond
		cfg.Game.TurnTimeout = 20 * time.Second
	})
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()

	newPlayer := func(device, name string) taxPlayer {
		token, id := login(t, ts.URL, device, name)
		return taxPlayer{id: id, token: token}
	}
	rookie, gold := newPlayer("tax-socket-rookie", "Rookie"), newPlayer("tax-socket-gold", "Maharaja")
	// A badge an owner adds at 5% — between Regular's 20% and the Royal
	// badges' 0%, the only rates the seed has — given by hand with the seed
	// header's statement (owner, 27 Sep 2026: "Vip is not a level, it is
	// badge").
	if _, err := database.Pool.Exec(ctx, `INSERT INTO badges (code, title, icon, tax_bps, validity_days, sort_order)
	     VALUES ('GOLD', 'Gold', '', 500, 30, 15)`); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Pool.Exec(ctx, `INSERT INTO user_badges (user_id, badge_code) VALUES ($1, 'GOLD')`, gold.id); err != nil {
		t.Fatal(err)
	}
	rookie.c, gold.c = dial(t, ts.URL, rookie.token), dial(t, ts.URL, gold.token)

	// session:ready: the player's own standing, and the menu entry's flag.
	ready, _ := rookie.c.Last(socket.EvSessionReady)
	const newbie = `{"assetFormat":"LOTTIE","assetUrl":"` + seededAssets + `levels/01-newbie.json","icon":"🌱","level":1,` +
		`"next":{"assetFormat":"LOTTIE","assetUrl":"` + seededAssets + `levels/02-rookie.json","icon":"🔰","level":2,"minXp":100,"taxBps":1971,"title":"Rookie"},` +
		`"taxBps":2000,"title":"Newbie","xp":0}`
	if got, _ := json.Marshal(jsonPath(ready, "user.playerLevel")); string(got) != newbie {
		t.Errorf("a new account's playerLevel: %s", got)
	}
	// Regular, everyone's by default (owner, 27 Sep 2026: "By default every
	// user will hold this Regular badge 20 percent tax"), with its Lottie.
	if got, _ := json.Marshal(jsonPath(ready, "user.badges")); string(got) !=
		`[{"assetFormat":"LOTTIE","assetUrl":"`+seededAssets+`badges/regular.json","code":"REGULAR","expiresAt":0,"icon":"","isDefault":true,"taxBps":2000,"title":"Regular"}]` ||
		jsonPath(ready, "user.taxBps") != 2000.0 {
		t.Errorf("a new account's badges %s and rate %v", got, jsonPath(ready, "user.taxBps"))
	}
	goldReady, _ := gold.c.Last(socket.EvSessionReady)
	if got, _ := json.Marshal(jsonPath(goldReady, "user.playerLevel")); string(got) != newbie {
		t.Errorf("a badge holder's playerLevel is the level their XP has reached: %s", got)
	}
	if codes := badgeCodesOf(jsonPath(goldReady, "user.badges")); codes != "REGULAR,GOLD" || jsonPath(goldReady, "user.taxBps") != 500.0 {
		t.Errorf("a badge holder's badges %s and rate %v, want Regular and Gold at 5%%", codes, jsonPath(goldReady, "user.taxBps"))
	}
	if e := menuEntry(t, ready, "blind", 1000); e["winnerTax"] != true || e["winnerTaxMinWinnings"] != 1000.0 {
		t.Errorf("the taxing table's menu entry: %v", e)
	}
	if e := menuEntry(t, ready, "seen", 200); e["winnerTax"] != nil || e["winnerTaxMinWinnings"] != nil {
		t.Errorf("an untaxed table's menu entry has no winnerTax: %v", e)
	}

	marks := map[string]int{rookie.id: rookie.c.Mark(), gold.id: gold.c.Mark()}
	for _, p := range []taxPlayer{rookie, gold} {
		mustOK(t, p.c, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 1000, "category": "blind"})
	}
	betting := func(raw json.RawMessage) bool {
		return jsonPath(raw, "state") == "betting" && jsonPath(raw, "handNo") == float64(1) && jsonPath(raw, "turn.userId") != nil
	}
	var onTurn string
	for _, p := range []taxPlayer{rookie, gold} {
		state := decodeMap(t, p.frame(t, marks[p.id], socket.EvRoomState, betting))
		if state["winnerTax"] != true || state["winnerTaxMinWinnings"] != 1000.0 {
			t.Errorf("the taxing table's snapshot: winnerTax %v from %v", state["winnerTax"], state["winnerTaxMinWinnings"])
		}
		want := 2000.0
		if p.id == gold.id {
			want = 500
		}
		if you, _ := state["you"].(map[string]any); you["taxBps"] != want {
			t.Errorf("%s's you.taxBps %v, want %v", p.id, you["taxBps"], want)
		}
		levels := 0
		for _, s := range state["seats"].([]any) {
			if seat, _ := s.(map[string]any); seat != nil {
				if _, ok := seat["taxBps"]; ok {
					t.Errorf("a seat carries a rate: %v", seat)
				}
				// Every player's level on their pod, for every viewer (owner,
				// 29 Sep 2026): both are new accounts, Level 1 with its art.
				if seat["status"] == "empty" {
					continue
				}
				if got, _ := json.Marshal(seat["level"]); string(got) != `{"assetFormat":"LOTTIE","assetUrl":"`+seededAssets+`levels/01-newbie.json","level":1}` {
					t.Errorf("%s's snapshot: seat %v's level %s", p.id, seat["userId"], got)
				}
				levels++
			}
		}
		if levels != 2 {
			t.Errorf("%s's snapshot shows %d levels, want both players'", p.id, levels)
		}
		onTurn, _ = jsonPath(mustRaw(t, state), "turn.userId").(string)
	}

	// The player on turn packs; the other takes the pot, 2 × 1,000, and has
	// WON the packer's 1,000: the tax is the winner's rate of that, never of
	// the pot (owner, 27 Sep 2026: "tax will be on total pot amount - amount
	// player contributed").
	packer, winner := rookie, gold
	if onTurn == gold.id {
		packer, winner = gold, rookie
	}
	wantBps := int64(2000)
	if winner.id == gold.id {
		wantBps = 500
	}
	const pot = int64(2000)
	wantTax := game.TableTax(pot/2, int(wantBps))
	walletBefore, _ := walletAndLedger(t, database, winner.id)
	for _, p := range []taxPlayer{rookie, gold} {
		marks[p.id] = p.c.Mark()
	}
	mustOK(t, packer.c, socket.EvGameAction, map[string]any{"action": "pack", "actionId": "tax-pack-1"})

	var handID string
	for _, p := range []taxPlayer{rookie, gold} {
		ended := decodeMap(t, p.frame(t, marks[p.id], socket.EvGameHandEnded, func(raw json.RawMessage) bool {
			return jsonPath(raw, "handNo") == float64(1)
		}))
		if ended["pot"] != float64(pot) || ended["tax"] != float64(wantTax) || ended["taxBps"] != float64(wantBps) || ended["winnerId"] != winner.id {
			t.Errorf("game:handEnded pot %v tax %v taxBps %v winner %v; want %d, %d at %d bps to %s",
				ended["pot"], ended["tax"], ended["taxBps"], ended["winnerId"], pot, wantTax, wantBps, winner.id)
		}
		handID, _ = ended["handId"].(string)
	}

	// The books: the win gross, the tax as its own row, the hand's hand_*
	// rows summing to zero, every wallet agreeing with its ledger.
	type row struct {
		user, reason, action string
		delta, balance       int64
	}
	rows, err := database.Pool.Query(ctx, `SELECT user_id, reason, action_id, delta, balance FROM chip_ledger WHERE hand_id = $1 ORDER BY id`, handID)
	if err != nil {
		t.Fatal(err)
	}
	var got []row
	for rows.Next() {
		var r row
		if err := rows.Scan(&r.user, &r.reason, &r.action, &r.delta, &r.balance); err != nil {
			t.Fatal(err)
		}
		got = append(got, r)
	}
	rows.Close()
	var handSum int64
	var sawWin, sawTax bool
	for _, r := range got {
		switch r.reason {
		case game.LedgerReasonTableTax:
			sawTax = true
			wallet, _ := walletAndLedger(t, database, winner.id)
			if r.user != winner.id || r.delta != -wantTax || r.action != game.TaxActionID(handID, winner.id) || r.balance != wallet {
				t.Errorf("the tax row %+v: want -%d under %s at %d", r, wantTax, game.TaxActionID(handID, winner.id), wallet)
			}
		case game.LedgerReasonHandWin:
			sawWin = true
			handSum += r.delta
			if r.user != winner.id || r.delta != pot/2 || r.balance != walletBefore+pot/2 {
				t.Errorf("the win row %+v: want the gross %d at %d", r, pot/2, walletBefore+pot/2)
			}
		default:
			handSum += r.delta
		}
	}
	if !sawWin || !sawTax || handSum != 0 {
		t.Fatalf("the hand's rows %+v: a win, a tax, and hand_* rows summing to 0 (got %d)", got, handSum)
	}
	for _, p := range []taxPlayer{rookie, gold} {
		if wallet, ledger := walletAndLedger(t, database, p.id); wallet != ledger {
			t.Errorf("%s: wallet %d, ledger %d", p.id, wallet, ledger)
		}
	}
	if wallet, _ := walletAndLedger(t, database, winner.id); wallet != walletBefore+pot/2-wantTax {
		t.Errorf("the winner's wallet %d, want %d", wallet, walletBefore+pot/2-wantTax)
	}
	if v := metricValue(a.metrics.TableTaxTotal.WithLabelValues("blind")); v != float64(wantTax) {
		t.Errorf("game_table_tax_chips_total{category=blind} = %v, want %d", v, wantTax)
	}

	// The daily XP (owner, 27 Sep 2026): the hand opened both players'
	// windows, and the winner earned the "Win by …" of the hand they won with
	// where one names it (a high card earns nothing) — told of it, and only
	// then, in player:level. The loser earned nothing.
	var winnerXP, loserXP, opened int64
	if err := database.Pool.QueryRow(ctx, `SELECT COALESCE((SELECT xp FROM player_xp WHERE user_id = $1), -1),
	       COALESCE((SELECT xp FROM player_xp WHERE user_id = $2), -1),
	       (SELECT count(*) FROM player_xp WHERE user_id IN ($1, $2) AND window_start > 0)`,
		winner.id, packer.id).Scan(&winnerXP, &loserXP, &opened); err != nil {
		t.Fatal(err)
	}
	var claimed, completed int64
	if err := database.Pool.QueryRow(ctx, `SELECT COALESCE(SUM(s.xp), 0) FROM player_xp_claims c
	       JOIN xp_sources s ON s.code = c.source_code WHERE c.user_id = $1`, winner.id).Scan(&claimed); err != nil {
		t.Fatal(err)
	}
	// The one-time missions (28 Sep 2026) the same hand completed: the winner
	// won without a bet of their own (the other packed first), so First Win —
	// a hand WON — and not First Hand, which needs a hand PLAYED; the packer,
	// who put in nothing beyond the boot, neither.
	if err := database.Pool.QueryRow(ctx, `SELECT COALESCE(SUM(xp_awarded), 0) FROM player_xp_missions WHERE user_id = $1`,
		winner.id).Scan(&completed); err != nil {
		t.Fatal(err)
	}
	if loserXP != 0 || opened != 2 || completed != 10 || claimed+completed != winnerXP ||
		(claimed != 0 && claimed != 1 && claimed != 2 && claimed != 4 && claimed != 8 && claimed != 20) {
		t.Fatalf("the hand's XP: winner %d (daily claims worth %d, missions %d), loser %d, %d windows open", winnerXP, claimed, completed, loserXP, opened)
	}
	standing := decodeMap(t, winner.frame(t, marks[winner.id], socket.EvPlayerLevel, nil))
	lv, _ := standing["playerLevel"].(map[string]any)
	daily, _ := lv["daily"].(map[string]any)
	if _, has := lv["today"]; lv["xp"] != float64(winnerXP) || has || daily == nil || daily["resetsAt"].(float64) <= 0 {
		t.Errorf("the winner's player:level %v, want %d XP, no today, a daily window", standing, winnerXP)
	}
	// …and the push says so: First Win completed, with no reset of any kind.
	var firstWin map[string]any
	for _, m := range lv["missions"].([]any) {
		if mission, _ := m.(map[string]any); mission["code"] == "FIRST_WIN" {
			firstWin = mission
		}
	}
	if firstWin == nil || firstWin["type"] != "ONE_TIME" || firstWin["completed"] != true || firstWin["progress"] != 1.0 ||
		firstWin["target"] != 1.0 || firstWin["xpAwarded"] != 10.0 || firstWin["completedAt"].(float64) <= 0 || firstWin["resetsAt"] != nil {
		t.Errorf("the winner's player:level missions %v, want First Win completed", lv["missions"])
	}
	// /api/auth/me: each player's XP, badges and the rate they pay. First
	// Win's 10 XP (owner, 28 Sep 2026: "reduce the XP Granted value") and at
	// most 20 of daily "Win by" XP stay under Level 2's 100: the winner is
	// still Newbie, at Newbie's 20% where no badge sets a lower rate.
	for _, p := range []taxPlayer{rookie, gold} {
		wantXP, wantLevel := int64(0), 1
		wantCodes, wantRate := "REGULAR", 2000
		if p.id == winner.id {
			wantXP = winnerXP
		}
		if p.id == gold.id {
			wantCodes, wantRate = "REGULAR,GOLD", 500
		}
		req, _ := http.NewRequest(http.MethodGet, ts.URL+"/api/auth/me", nil)
		req.Header.Set("Authorization", "Bearer "+p.token)
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		var me struct {
			User db.User `json:"user"`
		}
		if err := json.NewDecoder(res.Body).Decode(&me); err != nil || me.User.PlayerLevel.XP != wantXP ||
			me.User.PlayerLevel.Daily == nil || me.User.TaxBps != wantRate || me.User.PlayerLevel.Level != wantLevel {
			t.Errorf("/api/auth/me for %s: %+v %v", p.id, me.User.Standing, err)
		}
		codes := make([]string, len(me.User.Badges))
		for i, b := range me.User.Badges {
			codes[i] = b.Code
		}
		if strings.Join(codes, ",") != wantCodes {
			t.Errorf("%s holds %v, want %s", p.id, codes, wantCodes)
		}
		res.Body.Close()
	}

	// An untaxed table: not one frame carries the tax.
	c1, c2 := newPlayer("tax-socket-plain-1", "Plain"), newPlayer("tax-socket-plain-2", "Simple")
	c1.c, c2.c = dial(t, ts.URL, c1.token), dial(t, ts.URL, c2.token)
	for _, p := range []taxPlayer{c1, c2} {
		mustOK(t, p.c, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"})
	}
	state := decodeMap(t, c1.frame(t, 0, socket.EvRoomState, betting))
	turnUser, _ := jsonPath(mustRaw(t, state), "turn.userId").(string)
	plainPacker := c1
	if turnUser == c2.id {
		plainPacker = c2
	}
	mustOK(t, plainPacker.c, socket.EvGameAction, map[string]any{"action": "pack", "actionId": "plain-pack-1"})
	c1.frame(t, 0, socket.EvGameHandEnded, nil)
	for _, p := range []taxPlayer{c1, c2} {
		for _, name := range []string{socket.EvRoomJoined, socket.EvRoomState} {
			for _, raw := range p.c.All(name) {
				m := decodeMap(t, raw)
				you, _ := m["you"].(map[string]any)
				if _, ok := m["winnerTax"]; ok {
					t.Fatalf("an untaxed %s carries winnerTax: %s", name, raw)
				}
				if _, ok := m["winnerTaxMinWinnings"]; ok {
					t.Fatalf("an untaxed %s carries winnerTaxMinWinnings: %s", name, raw)
				}
				if _, ok := you["taxBps"]; ok {
					t.Fatalf("an untaxed %s carries you.taxBps: %s", name, raw)
				}
			}
		}
		for _, raw := range p.c.All(socket.EvGameHandEnded) {
			m := decodeMap(t, raw)
			if _, ok := m["tax"]; ok {
				t.Fatalf("an untaxed game:handEnded carries tax: %s", raw)
			}
			if _, ok := m["taxBps"]; ok {
				t.Fatalf("an untaxed game:handEnded carries taxBps: %s", raw)
			}
		}
	}
}

// badgeCodesOf is the codes of a wire badge list, in order.
func badgeCodesOf(v any) string {
	list, _ := v.([]any)
	codes := make([]string, 0, len(list))
	for _, b := range list {
		if m, ok := b.(map[string]any); ok {
			code, _ := m["code"].(string)
			codes = append(codes, code)
		}
	}
	return strings.Join(codes, ",")
}

func mustRaw(t *testing.T, v any) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// GET /api/levels is public and says the whole ladder (owner, 27 Sep 2026):
// no token, no-cache, every level, every badge with its rate and validity, the
// sources and the cap — and nothing about any player.
func TestTheLevelLadderIsPublicAndWhole(t *testing.T) {
	a, _ := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	res, err := http.Get(ts.URL + "/api/levels")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK || res.Header.Get("Cache-Control") != "no-cache" {
		t.Fatalf("GET /api/levels: %d, Cache-Control %q", res.StatusCode, res.Header.Get("Cache-Control"))
	}
	var body struct {
		Levels []struct {
			Level  int    `json:"level"`
			Title  string `json:"title"`
			Icon   string `json:"icon"`
			MinXP  int64  `json:"minXp"`
			TaxBps int    `json:"taxBps"`
		} `json:"levels"`
		Badges []struct {
			Code         string `json:"code"`
			Title        string `json:"title"`
			TaxBps       *int   `json:"taxBps"`
			ValidityDays int    `json:"validityDays"`
			IsDefault    bool   `json:"isDefault"`
			PriceInr     *int   `json:"priceInr"`
			ProductID    string `json:"productId"`
			AssetURL     string `json:"assetUrl"`
			AssetFormat  string `json:"assetFormat"`
		} `json:"badges"`
		XPSources []struct {
			Code string `json:"code"`
			Name string `json:"name"`
			XP   int    `json:"xp"`
			Type string `json:"type"`
		} `json:"xpSources"`
		Missions []struct {
			Code   string `json:"code"`
			Name   string `json:"name"`
			Kind   string `json:"kind"`
			Type   string `json:"type"`
			Target int    `json:"target"`
			Scope  string `json:"scope"`
			XP     int    `json:"xp"`
		} `json:"missions"`
		DailyCap *int `json:"dailyCap"`
	}
	raw, _ := io.ReadAll(res.Body)
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatalf("%s: %v", raw, err)
	}
	if len(body.Levels) != 50 || body.Levels[0].Title != "Newbie" || body.Levels[0].TaxBps != 2000 ||
		body.Levels[49].TaxBps != 600 || body.Levels[49].MinXP != 2000000 {
		t.Fatalf("the ladder: %+v … %+v (%d rungs), want 50 from 20%% to 6%%", body.Levels[0], body.Levels[len(body.Levels)-1], len(body.Levels))
	}
	if len(body.Badges) != 7 || body.Badges[0].Code != "REGULAR" || !body.Badges[0].IsDefault ||
		body.Badges[0].TaxBps == nil || *body.Badges[0].TaxBps != 2000 || body.Badges[0].PriceInr == nil || *body.Badges[0].PriceInr != 0 ||
		body.Badges[0].ValidityDays != 0 || body.Badges[0].AssetFormat != "LOTTIE" {
		t.Errorf("the badges = %+v", body.Badges)
	}
	// The Royal badges the store lists (owner, 27 Sep 2026): each with its
	// rupee price, its validity, its Lottie and the Play product it is sold
	// under.
	if ace, kings := body.Badges[1], body.Badges[6]; ace.Code != "ROYAL_ACE" || *ace.PriceInr != 500 || ace.ValidityDays != 7 ||
		ace.ProductID != "badge_royal_ace_499" || *ace.TaxBps != 0 || ace.AssetFormat != "LOTTIE" || ace.AssetURL != seededAssets+"badges/royal-ace.json" ||
		kings.Code != "ROYAL_KING_OF_KINGS" || *kings.PriceInr != 4500 || kings.ValidityDays != 90 ||
		kings.ProductID != "badge_royal_king_of_kings_4499" || body.Badges[0].ProductID != "" {
		t.Errorf("the store's badges = %+v %+v", ace, kings)
	}
	if len(body.XPSources) != 8 || body.DailyCap != nil || body.XPSources[0].Code != "PLAY_15_MIN" || body.XPSources[0].XP != 3 {
		t.Errorf("%d sources, cap %v, want no daily cap", len(body.XPSources), body.DailyCap)
	}
	// The one-time missions (28 Sep 2026) beside the daily sources, never
	// among them: xpSources stays the eight DAILY ones an older app sums to
	// its "108 XP a window".
	for _, s := range body.XPSources {
		if s.Type != "DAILY" {
			t.Errorf("a daily source typed %q: %+v", s.Type, s)
		}
	}
	if len(body.Missions) != 8 || body.Missions[0].Code != "FIRST_HAND" || body.Missions[0].Type != "ONE_TIME" ||
		body.Missions[0].Target != 1 || body.Missions[0].XP != 5 || body.Missions[6].Scope != "variation" ||
		body.Missions[7].Kind != "CATEGORIES_PLAYED" || body.Missions[7].Target != 3 {
		t.Errorf("the missions = %+v", body.Missions)
	}
	for _, word := range []string{"userId", "chips", "\"xp\":0,\"window"} {
		if strings.Contains(string(raw), word) {
			t.Errorf("the ladder carries %q: it is configuration only", word)
		}
	}
}
