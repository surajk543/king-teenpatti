package app

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket/testclient"
)

// diamondsAndMissiles reads one account's two soft wallets.
func diamondsAndMissiles(t *testing.T, database *db.DB, userID string) (diamonds, missiles int64) {
	t.Helper()
	if err := database.Pool.QueryRow(context.Background(),
		`SELECT diamond, missile FROM users WHERE id = $1`, userID).Scan(&diamonds, &missiles); err != nil {
		t.Fatal(err)
	}
	return diamonds, missiles
}

// POST /api/store/missiles over HTTP, against PostgreSQL: a new account holds
// 9 diamonds and 1 missile; a trade answers {user, charged, diamonds, missiles}
// and moves the wallets once per requestId; a replay, an unknown pack, a bad
// requestId, a short wallet and a malformed body each get their own answer
// with nothing moved; and a seated player may trade, with their seat and
// their chips untouched.
func TestTheMissileStoreTradesDiamondsForMissilesOverHTTP(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()

	token, id := login(t, ts.URL, "missile-store-buyer", "Trader")
	if d, m := diamondsAndMissiles(t, database, id); d != 9 || m != 1 {
		t.Fatalf("a new account holds %d diamonds and %d missiles, want 9 and 1", d, m)
	}
	walletBefore, ledgerBefore := walletAndLedger(t, database, id)
	trade := func(body any) restAnswer {
		t.Helper()
		r := postJSON(ts.URL, token, "/api/store/missiles", body)
		if r.err != nil {
			t.Fatal(r.err)
		}
		return r
	}
	userOf := func(r restAnswer) map[string]any {
		t.Helper()
		u, ok := r.body["user"].(map[string]any)
		if !ok {
			t.Fatalf("no user in %v", r.body)
		}
		return u
	}

	// The wallet is set to 12 diamonds so the first trade, the 10-diamond pack,
	// leaves exactly 2.
	if _, err := database.Pool.Exec(ctx, `UPDATE users SET diamond = 12 WHERE id = $1`, id); err != nil {
		t.Fatal(err)
	}
	r := trade(map[string]any{"packId": "missiles_1", "requestId": "trade-1"})
	if r.status != http.StatusOK || len(r.body) != 4 || r.body["charged"] != true || r.body["diamonds"] != float64(10) || r.body["missiles"] != float64(1) {
		t.Fatalf("first trade: %d %v", r.status, r.body)
	}
	if u := userOf(r); u["diamond"] != float64(2) || u["missile"] != float64(2) || u["id"] != id {
		t.Fatalf("the answer's user: %v", u)
	}

	r = trade(map[string]any{"packId": "missiles_1", "requestId": "trade-1"})
	if r.status != http.StatusOK || r.body["charged"] != false || r.body["diamonds"] != float64(0) || r.body["missiles"] != float64(0) {
		t.Fatalf("a replay: %d %v", r.status, r.body)
	}
	if u := userOf(r); u["diamond"] != float64(2) || u["missile"] != float64(2) {
		t.Fatalf("a replay's user: %v", u)
	}

	r = trade(map[string]any{"packId": "missiles_5", "requestId": "trade-2"})
	if r.status != http.StatusConflict || r.body["error"] != "not_enough_diamonds" || r.body["message"] != "You need 48 diamonds for this pack" {
		t.Fatalf("a short wallet: %d %v", r.status, r.body)
	}
	if r = trade(map[string]any{"packId": "missiles_1", "requestId": "trade-2b"}); r.status != http.StatusConflict || r.body["message"] != "You need 10 diamonds for this pack" {
		t.Fatalf("the cheapest pack from a short wallet: %d %v", r.status, r.body)
	}
	// An id never on sale, and ids only earlier price lists had.
	for _, pack := range []string{"missiles_3", "missiles_2", "missiles_50", "missiles_6", "missiles_13", "missiles_30"} {
		r = trade(map[string]any{"packId": pack, "requestId": "trade-3"})
		if r.status != http.StatusBadRequest || r.body["error"] != "unknown_pack" || r.body["message"] != "That missile pack does not exist" {
			t.Fatalf("an unknown pack %s: %d %v", pack, r.status, r.body)
		}
	}
	for _, bad := range []any{"", strings.Repeat("r", 65), nil} {
		body := map[string]any{"packId": "missiles_1"}
		if bad != nil {
			body["requestId"] = bad
		}
		if r = trade(body); r.status != http.StatusBadRequest || r.body["error"] != "invalid_request_id" {
			t.Fatalf("requestId %q: %d %v", bad, r.status, r.body)
		}
	}
	if r = trade(map[string]any{"packId": "missiles_5", "requestId": strings.Repeat("r", 64)}); r.status != http.StatusConflict || r.body["error"] != "not_enough_diamonds" {
		t.Fatalf("a 64-character requestId is valid (and this wallet is short): %d %v", r.status, r.body)
	}

	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/store/missiles", bytes.NewReader([]byte(`{"packId":`)))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusBadRequest || !strings.Contains(string(raw), `"error":"invalid_json"`) {
		t.Fatalf("a malformed body: %d %s", res.StatusCode, raw)
	}
	if r = postJSON(ts.URL, "", "/api/store/missiles", map[string]any{"packId": "missiles_1", "requestId": "anon"}); r.status != http.StatusUnauthorized {
		t.Fatalf("no session: %d %v", r.status, r.body)
	}

	if d, m := diamondsAndMissiles(t, database, id); d != 2 || m != 2 {
		t.Fatalf("after the refusals the wallet holds %d diamonds and %d missiles, want 2 and 2", d, m)
	}
	var trades int64
	if err := database.Pool.QueryRow(ctx, `SELECT count(*) FROM missile_purchases WHERE user_id = $1`, id).Scan(&trades); err != nil || trades != 1 {
		t.Fatalf("%d trades recorded (%v), want 1", trades, err)
	}

	// Seated: diamonds and missiles are nothing a seat holds.
	c := dial(t, ts.URL, token)
	mustOK(t, c, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"})
	seatBefore := seatOf(t, a, id)
	if _, err := database.Pool.Exec(ctx, `UPDATE users SET diamond = 90 WHERE id = $1`, id); err != nil {
		t.Fatal(err)
	}
	r = trade(map[string]any{"packId": "missiles_10", "requestId": "trade-seated"})
	if r.status != http.StatusOK || r.body["charged"] != true || r.body["diamonds"] != float64(90) || r.body["missiles"] != float64(10) {
		t.Fatalf("a seated trade: %d %v", r.status, r.body)
	}
	if u := userOf(r); u["diamond"] != float64(0) || u["missile"] != float64(12) {
		t.Fatalf("a seated trade's user: %v", u)
	}
	if a.Rooms().GetTableForPlayer(id) == nil || seatOf(t, a, id) != seatBefore {
		t.Fatal("a trade moved the player off their seat or changed its chips")
	}
	if wallet, ledger := walletAndLedger(t, database, id); wallet != walletBefore || ledger != ledgerBefore {
		t.Fatalf("a missile trade moved chips: wallet %d→%d, ledger %d→%d", walletBefore, wallet, ledgerBefore, ledger)
	}
}

// A missile fired through the socket, against PostgreSQL: the wallet is
// db.Missiles, so no_missiles comes from users.missile with the hand left
// running; the shot is charged once into missile_spends under the hand's key;
// every client hears the showdown and the hand end with reason missile; and
// the books balance — every wallet agrees with its ledger and the three
// wallets still sum to three welcome grants. A replay of the same actionId
// after the hand is over is refused and charges nothing.
func TestAMissileFiredThroughTheSocketIsChargedToPostgreSQLAndSettlesTheHand(t *testing.T) {
	a, database := newApp(t, func(cfg *config.Config) {
		cfg.Game.NextHandDelay = 400 * time.Millisecond
		cfg.Game.TurnTimeout = 20 * time.Second
		cfg.Game.MissileRevealExtra = 500 * time.Millisecond
	})
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()

	type seated struct {
		id string
		c  *testclient.Client
	}
	var players []seated
	for i, name := range []string{"Agni", "Prithvi", "Trishul"} {
		token, id := login(t, ts.URL, fmt.Sprintf("missile-socket-%d", i), name)
		players = append(players, seated{id: id, c: dial(t, ts.URL, token)})
	}
	for _, p := range players {
		mustOK(t, p.c, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 300, "category": "seen"})
	}
	if _, err := players[0].c.Wait(socket.EvGameHandStarted, func(raw json.RawMessage) bool {
		var e struct{ Participants []string }
		return json.Unmarshal(raw, &e) == nil && len(e.Participants) == 3
	}, 6*time.Second); err != nil {
		t.Fatalf("no three-player hand: %v", err)
	}
	table := a.Rooms().GetTableForPlayer(players[0].id)
	view, err := table.SerializeFor(players[0].id)
	if err != nil || view.Turn == nil || view.Turn.UserID == nil {
		t.Fatalf("no turn: %v %+v", err, view)
	}
	var firer seated
	for _, p := range players {
		if p.id == *view.Turn.UserID {
			firer = p
		}
	}

	if _, err := database.Pool.Exec(ctx, `UPDATE users SET missile = 0 WHERE id = $1`, firer.id); err != nil {
		t.Fatal(err)
	}
	ack, err := firer.c.Call(socket.EvGameAction, map[string]any{"action": "missile", "actionId": "db-missile-1"}, 4*time.Second)
	if err != nil || ack.OK || ack.Code != "no_missiles" {
		t.Fatalf("an empty users.missile: %v %s", err, ack.Raw)
	}
	if !table.HasHand() {
		t.Fatal("a refused missile ended the hand")
	}

	if _, err := database.Pool.Exec(ctx, `UPDATE users SET missile = 1 WHERE id = $1`, firer.id); err != nil {
		t.Fatal(err)
	}
	marks := make([]int, len(players))
	for i, p := range players {
		marks[i] = p.c.Mark()
	}
	ack = mustOK(t, firer.c, socket.EvGameAction, map[string]any{"action": "missile", "actionId": "db-missile-1"})
	if string(ack.Raw) != `{"ok":true,"action":"missile","missiles":0}` {
		t.Fatalf("ack %s", ack.Raw)
	}
	if _, m := diamondsAndMissiles(t, database, firer.id); m != 0 {
		t.Fatalf("users.missile = %d after the shot, want 0", m)
	}
	var spends int64
	if err := database.Pool.QueryRow(ctx,
		`SELECT count(*) FROM missile_spends WHERE user_id = $1 AND action_id LIKE '%:missile:' || $1 || ':db-missile-1'`,
		firer.id).Scan(&spends); err != nil || spends != 1 {
		t.Fatalf("%d missile_spends rows (%v), want 1", spends, err)
	}

	for i, p := range players {
		if _, err := p.c.WaitFrom(marks[i], socket.EvGameShowdown, func(raw json.RawMessage) bool {
			var e struct {
				Reason  string            `json:"reason"`
				Reveals []json.RawMessage `json:"reveals"`
			}
			return json.Unmarshal(raw, &e) == nil && e.Reason == "missile" && len(e.Reveals) == 3
		}, 4*time.Second); err != nil {
			t.Fatalf("player %d heard no missile showdown: %v", i, err)
		}
		if _, err := p.c.WaitFrom(marks[i], socket.EvGameHandEnded, func(raw json.RawMessage) bool {
			return jsonPath(raw, "reason") == "missile"
		}, 4*time.Second); err != nil {
			t.Fatalf("player %d heard no missile hand end: %v", i, err)
		}
	}

	var total int64
	for _, p := range players {
		wallet, ledger := walletAndLedger(t, database, p.id)
		if wallet != ledger {
			t.Fatalf("wallet %d disagrees with its ledger %d", wallet, ledger)
		}
		total += wallet
	}
	if total != 3*a.cfg.Game.WelcomeChips {
		t.Fatalf("the three wallets hold %d, want %d: a missile hand is zero-sum", total, 3*a.cfg.Game.WelcomeChips)
	}

	ack, err = firer.c.Call(socket.EvGameAction, map[string]any{"action": "missile", "actionId": "db-missile-1"}, 4*time.Second)
	if err != nil || ack.OK {
		t.Fatalf("a replay after the hand: %v %s", err, ack.Raw)
	}
	if err := database.Pool.QueryRow(ctx, `SELECT count(*) FROM missile_spends WHERE user_id = $1`, firer.id).Scan(&spends); err != nil || spends != 1 {
		t.Fatalf("a replay was charged: %d rows (%v)", spends, err)
	}
}
