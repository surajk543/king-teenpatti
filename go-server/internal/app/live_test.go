package app

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	dto "github.com/prometheus/client_model/go"

	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
	"github.com/surajk543/king-teenpatti/go-server/internal/livetest"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket/testclient"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// The live-state startup sequence end to end (LIVE_STATE_PLAN.md): a process
// with a hand in progress is replaced; the next one rebuilds the table from
// the shared store, refunds the pot nobody is playing, holds the seats, and
// the players land back at their table.

// REDIS_URL set but unreachable → New fails fast with the store's error;
// nothing is half-started.
func TestLiveOpenFailsFastWhenRedisIsUnreachable(t *testing.T) {
	database := dbtest.Open(t, "app")
	cfg := testConfig(t, publicDir(t))
	cfg.RedisURL = "redis://127.0.0.1:1/0" // port 1: nothing listens
	started := time.Now()
	a, err := New(Options{Config: cfg, DB: database, Logger: util.NewLogger("error", io.Discard)})
	if err == nil {
		_ = a.Shutdown(context.Background())
		t.Fatal("New succeeded with an unreachable Redis")
	}
	if !strings.Contains(err.Error(), "live store") {
		t.Fatalf("error = %v, want it to name the live store", err)
	}
	if took := time.Since(started); took > liveOpenTimeout+2*time.Second {
		t.Fatalf("New took %s to fail", took)
	}
}

// login creates a guest through the REST API of one app and returns its
// token and id.
func login(t *testing.T, baseURL, deviceID, name string) (token, userID string) {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"provider": "guest", "deviceId": deviceID, "displayName": name})
	res, err := http.Post(baseURL+"/api/auth/login", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var out struct {
		Token string `json:"token"`
		User  struct {
			ID string `json:"id"`
		} `json:"user"`
	}
	if err := json.NewDecoder(res.Body).Decode(&out); err != nil || res.StatusCode != http.StatusOK || out.Token == "" {
		t.Fatalf("login %s: %d %v %+v", name, res.StatusCode, err, out)
	}
	return out.Token, out.User.ID
}

func dial(t *testing.T, baseURL, token string) *testclient.Client {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, err := testclient.Dial(ctx, baseURL, token)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(c.Close)
	if _, err := c.Wait(socket.EvSessionReady, nil, 4*time.Second); err != nil {
		t.Fatalf("no session:ready: %v", err)
	}
	return c
}

func mustOK(t *testing.T, c *testclient.Client, event string, payload any) testclient.Ack {
	t.Helper()
	ack, err := c.Call(event, payload, 4*time.Second)
	if err != nil || !ack.OK {
		t.Fatalf("%s: %v %s", event, err, ack.Raw)
	}
	return ack
}

func jsonPath(raw json.RawMessage, path string) any {
	var cur any
	if err := json.Unmarshal(raw, &cur); err != nil {
		return nil
	}
	for _, key := range strings.Split(path, ".") {
		m, ok := cur.(map[string]any)
		if !ok {
			return nil
		}
		cur = m[key]
	}
	return cur
}

func TestRestartRestoresTablesAndHoldsSeats(t *testing.T) {
	database := dbtest.Open(t, "app")
	store := livetest.New()
	cfg := testConfig(t, publicDir(t))
	cfg.Game.TurnTimeout = 20 * time.Second // the restored hand must still be on its first turn below
	cfg.Game.ReconnectGrace = 700 * time.Millisecond
	logger := util.NewLogger("error", io.Discard)

	// ---- process 1: two players, a hand in progress, plus a pot nobody plays.
	first := newAppOn(t, cfg, database, store)
	ts1 := httptest.NewServer(first.Handler())
	defer ts1.Close()
	tokA, idA := login(t, ts1.URL, "restart-device-alice-1", "Alice")
	tokB, idB := login(t, ts1.URL, "restart-device-bob-0001", "Bob")
	a1, b1 := dial(t, ts1.URL, tokA), dial(t, ts1.URL, tokB)
	join := map[string]any{"bootAmount": 200, "category": "seen"}
	joined := mustOK(t, a1, socket.EvRoomQuickJoin, join)
	mustOK(t, b1, socket.EvRoomQuickJoin, join)
	roomID, _ := jsonPath(joined.Raw, "roomId").(string)
	code, _ := jsonPath(joined.Raw, "code").(string)
	if _, err := a1.Wait(socket.EvGameHandStarted, nil, 4*time.Second); err != nil {
		t.Fatalf("hand never started: %v", err)
	}
	if _, err := a1.Wait(socket.EvRoomState, func(p json.RawMessage) bool { return jsonPath(p, "state") == "betting" }, 4*time.Second); err != nil {
		t.Fatal(err)
	}
	liveHand := jsonPath(mustSnapshotOfApp(t, first, roomID), "hand.id").(string)
	chipsBefore := map[string]int64{}
	for _, id := range []string{idA, idB} {
		if err := database.Pool.QueryRow(context.Background(), `SELECT chips FROM users WHERE id = $1`, id).Scan(new(int64)); err != nil {
			t.Fatal(err)
		}
		var c int64
		_ = database.Pool.QueryRow(context.Background(), `SELECT chips FROM users WHERE id = $1`, id).Scan(&c)
		chipsBefore[id] = c
	}

	// ---- the process is replaced: suspended into the store, not settled.
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	if err := first.Shutdown(ctx); err != nil {
		t.Fatalf("shutdown 1: %v", err)
	}
	if !a1.WaitClosed(4*time.Second) || !b1.WaitClosed(4*time.Second) {
		t.Fatal("sockets not closed by the shutdown")
	}
	if store.Tables() != 1 {
		t.Fatalf("store holds %d tables after the suspend, want 1", store.Tables())
	}
	// Nothing was written for the suspended hand: the deal and every bet in
	// it live only in the store.
	var rowsForHand int64
	if err := database.Pool.QueryRow(context.Background(), `SELECT COUNT(*) FROM chip_ledger WHERE hand_id = $1`, liveHand).Scan(&rowsForHand); err != nil || rowsForHand != 0 {
		t.Fatalf("the suspended hand wrote %d ledger rows (%v)", rowsForHand, err)
	}

	// ---- process 2 on the same store and database.
	second, err := New(Options{Config: cfg, DB: database, Logger: logger, Live: store})
	if err != nil {
		t.Fatalf("New (second process): %v", err)
	}
	t.Cleanup(func() { _ = second.Shutdown(context.Background()) })
	restored := second.Restore()
	if restored.Tables != 1 || restored.Seats != 2 || restored.HandsInProgress != 1 || len(restored.HandIDs) != 1 || restored.HandIDs[0] != liveHand {
		t.Fatalf("restore report = %+v", restored)
	}
	if stats := second.Rooms().Stats(); stats.Tables != 1 || stats.Players != 2 || stats.ActiveHands != 1 {
		t.Fatalf("rooms after restore = %+v", stats)
	}
	for _, id := range []string{idA, idB} {
		var chips, ledgerSum int64
		_ = database.Pool.QueryRow(context.Background(), `SELECT chips FROM users WHERE id = $1`, id).Scan(&chips)
		_ = database.Pool.QueryRow(context.Background(), `SELECT COALESCE(SUM(delta),0)::bigint FROM chip_ledger WHERE user_id = $1`, id).Scan(&ledgerSum)
		if chips != chipsBefore[id] {
			t.Fatalf("user %s chips %d, want them untouched across the restart (%d)", id, chips, chipsBefore[id])
		}
		if chips != ledgerSum {
			t.Fatalf("user %s: SUM(delta) %d != chips %d", id, ledgerSum, chips)
		}
	}
	if v := metricValue(second.metrics.RestoredTablesTotal); v != 1 {
		t.Fatalf("restored_tables_total = %v", v)
	}
	if v := metricValue(second.metrics.RestoredSeatsTotal); v != 2 {
		t.Fatalf("restored_seats_total = %v", v)
	}

	// /health reports the store and the one table it holds.
	res, body := get(t, second.Handler(), http.MethodGet, "/health", nil)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("/health: %d %s", res.StatusCode, body)
	}
	var h struct {
		Tables int `json:"tables"`
		Live   struct {
			Kind   string `json:"kind"`
			OK     bool   `json:"ok"`
			Tables int    `json:"tables"`
		} `json:"live"`
	}
	if err := json.Unmarshal(body, &h); err != nil || h.Tables != 1 || h.Live.Kind != "fake" || !h.Live.OK || h.Live.Tables != 1 {
		t.Fatalf("/health after restore: %s (%v)", body, err)
	}

	// Alice comes back inside the grace: session:ready without an offer, then
	// room:joined with the restored hand.
	ts2 := httptest.NewServer(second.Handler())
	defer ts2.Close()
	a2 := dial(t, ts2.URL, tokA)
	ready, _ := a2.Last(socket.EvSessionReady)
	if jsonPath(ready, "resume") != nil {
		t.Fatalf("held seat came with an offer: %s", ready)
	}
	rejoined, err := a2.Wait(socket.EvRoomJoined, nil, 4*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if jsonPath(rejoined, "roomId") != roomID || jsonPath(rejoined, "code") != code || jsonPath(rejoined, "state") != "betting" ||
		jsonPath(rejoined, "handNo") != float64(1) || jsonPath(rejoined, "you.status") != "active" {
		t.Fatalf("restored snapshot for Alice: %s", rejoined)
	}
	if turn := jsonPath(rejoined, "turn.userId"); turn == nil {
		t.Fatalf("the restored hand has no turn: %s", rejoined)
	}

	// Bob never returns: his seat lapses into an offer, the hand ends for Alice.
	if _, err := a2.Wait(socket.EvGameActionOut, func(p json.RawMessage) bool {
		return jsonPath(p, "userId") == idB && jsonPath(p, "reason") == "disconnected"
	}, 3*time.Second); err != nil {
		t.Fatalf("Bob's seat did not lapse: %v", err)
	}
	if offer, ok := store.Offer(idB); !ok || offer.RoomID != roomID {
		t.Fatalf("offer for Bob = %+v %v", offer, ok)
	}
	b2 := dial(t, ts2.URL, tokB)
	readyB, _ := b2.Last(socket.EvSessionReady)
	if jsonPath(readyB, "resume.roomId") != roomID || jsonPath(readyB, "resume.code") != code {
		t.Fatalf("Bob's session:ready.resume = %s", readyB)
	}
	// The restored hand has settled by now (Alice won last standing), so it
	// finally reaches PostgreSQL — one outcome row per player, and no other.
	var outcomeRows int64
	_ = database.Pool.QueryRow(context.Background(), `SELECT COUNT(*) FROM chip_ledger WHERE hand_id = $1`, liveHand).Scan(&outcomeRows)
	if outcomeRows == 0 {
		t.Fatal("the restored hand never reached the books")
	}
	var mismatched int64
	_ = database.Pool.QueryRow(context.Background(), `SELECT COUNT(*) FROM users u
	  JOIN (SELECT user_id, SUM(delta) s FROM chip_ledger GROUP BY user_id) l ON l.user_id = u.id
	 WHERE l.s <> u.chips`).Scan(&mismatched)
	if mismatched != 0 {
		t.Fatalf("%d wallet(s) disagree with their ledger", mismatched)
	}
}

// mustSnapshotOfApp reads a table's server-side snapshot as JSON.
func mustSnapshotOfApp(t *testing.T, a *App, roomID string) json.RawMessage {
	t.Helper()
	table := a.Rooms().GetTable(roomID)
	if table == nil {
		t.Fatalf("table %s not registered", roomID)
	}
	snap, err := table.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(snap)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// With the in-process store a shutdown is a destroy (the pre-Redis
// behaviour): the hand is settled and the store is empty afterwards.
func TestShutdownWithMemoryStoreSettlesTheTables(t *testing.T) {
	database := dbtest.Open(t, "app")
	cfg := testConfig(t, publicDir(t))
	a, err := New(Options{Config: cfg, DB: database, Logger: util.NewLogger("error", io.Discard)})
	if err != nil {
		t.Fatal(err)
	}
	if a.Live().Kind() != "memory" {
		t.Fatalf("store kind %q, want memory with REDIS_URL empty", a.Live().Kind())
	}
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	tokA, _ := login(t, ts.URL, "memory-device-alice-1", "Alice")
	tokB, _ := login(t, ts.URL, "memory-device-bob-0001", "Bob")
	c1, c2 := dial(t, ts.URL, tokA), dial(t, ts.URL, tokB)
	join := map[string]any{"bootAmount": 200, "category": "seen"}
	mustOK(t, c1, socket.EvRoomQuickJoin, join)
	mustOK(t, c2, socket.EvRoomQuickJoin, join)
	if _, err := c1.Wait(socket.EvGameHandStarted, nil, 4*time.Second); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	if err := a.Shutdown(ctx); err != nil {
		t.Fatalf("shutdown: %v", err)
	}
	// The hand was settled on the way down, so its outcome rows are in the
	// books and every wallet still equals its ledger.
	var rows, mismatched int64
	if err := database.Pool.QueryRow(context.Background(), `SELECT COUNT(*) FROM chip_ledger WHERE reason IN ('hand_win','hand_loss')`).Scan(&rows); err != nil || rows == 0 {
		t.Fatalf("the hand was not settled on shutdown: %d rows (%v)", rows, err)
	}
	_ = database.Pool.QueryRow(context.Background(), `SELECT COUNT(*) FROM users u
	  JOIN (SELECT user_id, SUM(delta) s FROM chip_ledger GROUP BY user_id) l ON l.user_id = u.id
	 WHERE l.s <> u.chips`).Scan(&mismatched)
	if mismatched != 0 {
		t.Fatalf("%d wallet(s) disagree with their ledger", mismatched)
	}
	// Closed last: the store refuses every call now.
	if err := a.Live().Ping(context.Background()); err == nil {
		t.Fatal("store still open after Shutdown")
	}
}

// metricValue reads a counter or gauge.
func metricValue(c interface{ Write(*dto.Metric) error }) float64 {
	var out dto.Metric
	if err := c.Write(&out); err != nil {
		return -1
	}
	if out.Counter != nil {
		return out.Counter.GetValue()
	}
	if out.Gauge != nil {
		return out.Gauge.GetValue()
	}
	return -1
}

// A LOST LIVE STORE MEANS THE HAND NEVER HAPPENED (LIVE_STATE_PLAN.md,
// owner's decision of 9 Sep 2026). PostgreSQL holds no game state and nothing
// was written for a hand in progress, so a process that comes up on an empty
// live store restores nothing and every player is back to the balance they
// had before the hand — the owner's example 1.
func TestRestartWithEmptyLiveStoreLosesTheTablesAndTheHandNeverHappened(t *testing.T) {
	database := dbtest.Open(t, "app")
	cfg := testConfig(t, publicDir(t))
	cfg.Game.TurnTimeout = 20 * time.Second
	cfg.Game.ReconnectGrace = 700 * time.Millisecond

	// Process 1 deals a hand and one player chaals.
	first := newAppOn(t, cfg, database, livetest.New())
	ts1 := httptest.NewServer(first.Handler())
	defer ts1.Close()
	tokA, idA := login(t, ts1.URL, "lostlive-device-alice", "Alice")
	tokB, idB := login(t, ts1.URL, "lostlive-device-bobby", "Bob")
	a1, b1 := dial(t, ts1.URL, tokA), dial(t, ts1.URL, tokB)
	join := map[string]any{"bootAmount": 200, "category": "seen"}
	joined := mustOK(t, a1, socket.EvRoomQuickJoin, join)
	mustOK(t, b1, socket.EvRoomQuickJoin, join)
	roomID, _ := jsonPath(joined.Raw, "roomId").(string)
	if _, err := a1.Wait(socket.EvGameHandStarted, nil, 4*time.Second); err != nil {
		t.Fatal(err)
	}
	before := map[string]int64{}
	for _, id := range []string{idA, idB} {
		var chips int64
		_ = database.Pool.QueryRow(context.Background(), `SELECT chips FROM users WHERE id = $1`, id).Scan(&chips)
		before[id] = chips
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	if err := first.Shutdown(ctx); err != nil {
		t.Fatalf("shutdown 1: %v", err)
	}

	// Process 2: the live store came back EMPTY.
	empty := livetest.New()
	second := newAppOn(t, cfg, database, empty)
	restored := second.Restore()
	if restored.Tables != 0 || restored.Seats != 0 {
		t.Fatalf("a table came back from somewhere: %+v", restored)
	}
	if second.Rooms().GetTable(roomID) != nil {
		t.Fatal("the room is registered although nothing could restore it")
	}
	// The owner's example: 1 lakh before the hand, chips staked, Redis dies →
	// they have their pre-hand balance again, because nothing was deducted.
	for _, id := range []string{idA, idB} {
		var chips, ledgerSum int64
		_ = database.Pool.QueryRow(context.Background(), `SELECT chips FROM users WHERE id = $1`, id).Scan(&chips)
		_ = database.Pool.QueryRow(context.Background(), `SELECT COALESCE(SUM(delta),0)::bigint FROM chip_ledger WHERE user_id = $1`, id).Scan(&ledgerSum)
		if chips != before[id] {
			t.Fatalf("user %s chips %d, want their pre-hand balance %d", id, chips, before[id])
		}
		if chips != ledgerSum {
			t.Fatalf("user %s: SUM(delta) %d != chips %d", id, ledgerSum, chips)
		}
	}
	// And the players can sit down again and play.
	ts2 := httptest.NewServer(second.Handler())
	defer ts2.Close()
	a2, b2 := dial(t, ts2.URL, tokA), dial(t, ts2.URL, tokB)
	fresh := mustOK(t, a2, socket.EvRoomQuickJoin, join)
	mustOK(t, b2, socket.EvRoomQuickJoin, join)
	if newRoom, _ := jsonPath(fresh.Raw, "roomId").(string); newRoom == roomID {
		t.Fatal("the lost room came back")
	}
	if _, err := a2.Wait(socket.EvGameHandStarted, nil, 4*time.Second); err != nil {
		t.Fatalf("a fresh hand did not deal: %v", err)
	}
}

// PostgreSQL holds MONEY AND AUDIT ONLY: a fresh schema has `users` and
// `chip_ledger` and nothing else — no game_states, no pots, no hands.
func TestPostgresHoldsNoGameState(t *testing.T) {
	database := dbtest.Open(t, "app")
	cfg := testConfig(t, publicDir(t))
	app := newAppOn(t, cfg, database, livetest.New())
	ts := httptest.NewServer(app.Handler())
	defer ts.Close()
	tokA, _ := login(t, ts.URL, "nogamestate-device-al", "Alice")
	tokB, _ := login(t, ts.URL, "nogamestate-device-bo", "Bob")
	a, b := dial(t, ts.URL, tokA), dial(t, ts.URL, tokB)
	join := map[string]any{"bootAmount": 200, "category": "seen"}
	mustOK(t, a, socket.EvRoomQuickJoin, join)
	mustOK(t, b, socket.EvRoomQuickJoin, join)
	if _, err := a.Wait(socket.EvGameHandStarted, nil, 4*time.Second); err != nil {
		t.Fatal(err)
	}
	rows, err := database.Pool.Query(context.Background(),
		`SELECT tablename FROM pg_tables WHERE schemaname = current_schema() ORDER BY tablename`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var tables []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatal(err)
		}
		tables = append(tables, name)
	}
	if len(tables) != 2 || tables[0] != "chip_ledger" || tables[1] != "users" {
		t.Fatalf("schema tables = %v, want [chip_ledger users]", tables)
	}
}

// /health is polled by uptime checks, dashboards and the load generator. It
// must cost the live store ONE call whatever the table count — it used to
// enumerate every table, which on production (9 Sep 2026) meant ~1,130 Redis
// round trips per health check, drove /health p95 to 1.1 s at 7,000 players
// and eventually timed it out while the game itself was serving 1,598
// actions a second.
func TestHealthAsksTheLiveStoreForACountNotAListing(t *testing.T) {
	database := dbtest.Open(t, "app")
	store := livetest.New()
	app := newAppOn(t, testConfig(t, publicDir(t)), database, store)
	ts := httptest.NewServer(app.Handler())
	defer ts.Close()

	// A few tables so a listing would be visibly more expensive than a count.
	for _, id := range []string{"r1", "r2", "r3", "r4", "r5"} {
		if err := store.SaveTable(context.Background(), id, 1, []byte(`{}`), time.Hour); err != nil {
			t.Fatal(err)
		}
	}
	listsBefore, countsBefore := store.Calls(livetest.OpListTables), store.Calls(livetest.OpCountTables)

	for i := 0; i < 3; i++ {
		res, err := http.Get(ts.URL + "/health")
		if err != nil {
			t.Fatal(err)
		}
		var body struct {
			Live struct {
				OK     bool `json:"ok"`
				Tables int  `json:"tables"`
			} `json:"live"`
		}
		if err := json.NewDecoder(res.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		if !body.Live.OK || body.Live.Tables != 5 {
			t.Fatalf("/health live = %+v, want ok with 5 tables", body.Live)
		}
	}

	if got := store.Calls(livetest.OpListTables) - listsBefore; got != 0 {
		t.Fatalf("/health enumerated the store %d time(s); it must only count", got)
	}
	if got := store.Calls(livetest.OpCountTables) - countsBefore; got != 3 {
		t.Fatalf("/health made %d count calls for 3 requests, want 3", got)
	}
}
