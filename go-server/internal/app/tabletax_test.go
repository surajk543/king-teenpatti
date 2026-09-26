package app

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket/testclient"
)

// The winning tax and the player levels over real sockets and PostgreSQL
// (owner, 26 Sep 2026). A table that taxes its winners says so on its menu
// entry and its snapshot, tells each player their own rate, takes the rate of
// the WINNER's level from the whole pot, and books the win gross with the tax
// beside it; the hand's XP reaches each player as player:level. An untaxed
// table's frames carry none of it.

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
	rookie, vip := newPlayer("tax-socket-rookie", "Rookie"), newPlayer("tax-socket-vip", "Maharaja")
	// VIP by hand — the seed header's statement, the only way there is.
	if _, err := database.Pool.Exec(ctx, `INSERT INTO player_xp (user_id, level_override, created_at, updated_at)
	     VALUES ($1, (SELECT level FROM player_levels WHERE is_vip), 1, 1)`, vip.id); err != nil {
		t.Fatal(err)
	}
	rookie.c, vip.c = dial(t, ts.URL, rookie.token), dial(t, ts.URL, vip.token)

	// session:ready: the player's own level, and the menu entry's flag.
	ready, _ := rookie.c.Last(socket.EvSessionReady)
	if got, _ := json.Marshal(jsonPath(ready, "user.playerLevel")); string(got) !=
		`{"icon":"🌱","level":1,"next":{"icon":"🔰","level":2,"minXp":100,"taxBps":1980,"title":"Rookie"},"taxBps":2000,"title":"Newbie","today":{"cap":50,"resetsAt":0,"xp":0},"vip":false,"xp":0}` {
		t.Errorf("a new account's playerLevel: %s", got)
	}
	vipReady, _ := vip.c.Last(socket.EvSessionReady)
	if got, _ := json.Marshal(jsonPath(vipReady, "user.playerLevel")); string(got) !=
		`{"icon":"💎👑","level":51,"taxBps":400,"title":"VIP","today":{"cap":50,"resetsAt":0,"xp":0},"vip":true,"xp":0}` {
		t.Errorf("a VIP's playerLevel: %s", got)
	}
	if e := menuEntry(t, ready, "blind", 1000); e["winnerTax"] != true {
		t.Errorf("the taxing table's menu entry: %v", e)
	}
	if e := menuEntry(t, ready, "seen", 200); e["winnerTax"] != nil {
		t.Errorf("an untaxed table's menu entry has no winnerTax: %v", e)
	}

	marks := map[string]int{rookie.id: rookie.c.Mark(), vip.id: vip.c.Mark()}
	for _, p := range []taxPlayer{rookie, vip} {
		mustOK(t, p.c, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 1000, "category": "blind"})
	}
	betting := func(raw json.RawMessage) bool {
		return jsonPath(raw, "state") == "betting" && jsonPath(raw, "handNo") == float64(1) && jsonPath(raw, "turn.userId") != nil
	}
	var onTurn string
	for _, p := range []taxPlayer{rookie, vip} {
		state := decodeMap(t, p.frame(t, marks[p.id], socket.EvRoomState, betting))
		if state["winnerTax"] != true {
			t.Errorf("the taxing table's snapshot: winnerTax %v", state["winnerTax"])
		}
		want := 2000.0
		if p.id == vip.id {
			want = 400
		}
		if you, _ := state["you"].(map[string]any); you["taxBps"] != want {
			t.Errorf("%s's you.taxBps %v, want %v", p.id, you["taxBps"], want)
		}
		for _, s := range state["seats"].([]any) {
			if seat, _ := s.(map[string]any); seat != nil {
				if _, ok := seat["taxBps"]; ok {
					t.Errorf("a seat carries a rate: %v", seat)
				}
			}
		}
		onTurn, _ = jsonPath(mustRaw(t, state), "turn.userId").(string)
	}

	// The player on turn packs; the other takes the whole pot, 2 × 1,000.
	packer, winner := rookie, vip
	if onTurn == vip.id {
		packer, winner = vip, rookie
	}
	wantBps := int64(2000)
	if winner.id == vip.id {
		wantBps = 400
	}
	const pot = int64(2000)
	wantTax := game.TableTax(pot, int(wantBps))
	walletBefore, _ := walletAndLedger(t, database, winner.id)
	for _, p := range []taxPlayer{rookie, vip} {
		marks[p.id] = p.c.Mark()
	}
	mustOK(t, packer.c, socket.EvGameAction, map[string]any{"action": "pack", "actionId": "tax-pack-1"})

	var handID string
	for _, p := range []taxPlayer{rookie, vip} {
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
	for _, p := range []taxPlayer{rookie, vip} {
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

	// player:level: each player told their own XP — HAND_COMPLETED and the
	// daily bonus for both, HAND_WON for the winner.
	for _, p := range []taxPlayer{rookie, vip} {
		lv := decodeMap(t, p.frame(t, marks[p.id], socket.EvPlayerLevel, nil))
		wantXP := 6.0
		if p.id == winner.id {
			wantXP = 7
		}
		today, _ := lv["today"].(map[string]any)
		if lv["xp"] != wantXP || today["xp"] != wantXP || today["cap"] != 50.0 || today["resetsAt"].(float64) <= 0 {
			t.Errorf("%s's player:level %v, want %v XP today", p.id, lv, wantXP)
		}
		if p.id == vip.id && (lv["vip"] != true || lv["level"] != 51.0 || lv["next"] != nil) {
			t.Errorf("the VIP stays VIP: %v", lv)
		}
		// /api/auth/me reads the same.
		req, _ := http.NewRequest(http.MethodGet, ts.URL+"/api/auth/me", nil)
		req.Header.Set("Authorization", "Bearer "+p.token)
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		var me struct {
			User db.User `json:"user"`
		}
		if err := json.NewDecoder(res.Body).Decode(&me); err != nil || me.User.PlayerLevel.XP != int64(wantXP) {
			t.Errorf("/api/auth/me for %s: %+v %v", p.id, me.User.PlayerLevel, err)
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

func mustRaw(t *testing.T, v any) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
