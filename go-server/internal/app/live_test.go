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

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
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

func TestRestartRestoresTablesHoldsSeatsAndRefundsOrphanedPots(t *testing.T) {
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
	var liveHand string
	if err := database.Pool.QueryRow(context.Background(), `SELECT hand_id FROM pots WHERE room_id = $1 AND closed_at IS NULL`, roomID).Scan(&liveHand); err != nil {
		t.Fatalf("live pot: %v", err)
	}
	// An orphan: a pot opened by a table that will not be in the store.
	ledger := db.NewLedger(database, nil, nil)
	if _, err := ledger.CollectBoot(context.Background(), game.CollectBootRequest{
		RoomID: "orphan-room", HandID: "orphan-hand", BootAmount: 200,
		Entries: []game.BootEntry{{UserID: idA, Amount: 200}, {UserID: idB, Amount: 200}},
	}); err != nil {
		t.Fatal(err)
	}
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
	var stillOpen int64
	if err := database.Pool.QueryRow(context.Background(), `SELECT COUNT(*) FROM pots WHERE hand_id = $1 AND closed_at IS NULL`, liveHand).Scan(&stillOpen); err != nil || stillOpen != 1 {
		t.Fatalf("the suspended hand's pot must stay open (%d, %v)", stillOpen, err)
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
	refund := second.Refund()
	if refund.Pots != 1 || refund.Contributors != 2 || refund.Chips != 400 || refund.Skipped != 1 {
		t.Fatalf("refund report = %+v (the orphan refunded, the live hand skipped)", refund)
	}
	var closedOrphan, openLive int64
	_ = database.Pool.QueryRow(context.Background(), `SELECT COUNT(*) FROM pots WHERE hand_id = 'orphan-hand' AND closed_at IS NOT NULL AND winner_id IS NULL`).Scan(&closedOrphan)
	_ = database.Pool.QueryRow(context.Background(), `SELECT COUNT(*) FROM pots WHERE hand_id = $1 AND closed_at IS NULL`, liveHand).Scan(&openLive)
	if closedOrphan != 1 || openLive != 1 {
		t.Fatalf("pots after refund: orphan closed=%d live open=%d", closedOrphan, openLive)
	}
	for _, id := range []string{idA, idB} {
		var chips, ledgerSum int64
		_ = database.Pool.QueryRow(context.Background(), `SELECT chips FROM users WHERE id = $1`, id).Scan(&chips)
		_ = database.Pool.QueryRow(context.Background(), `SELECT COALESCE(SUM(delta),0)::bigint FROM chip_ledger WHERE user_id = $1`, id).Scan(&ledgerSum)
		if chips != chipsBefore[id]+200 {
			t.Fatalf("user %s chips %d, want the orphan boot back (%d)", id, chips, chipsBefore[id]+200)
		}
		if chips != ledgerSum {
			t.Fatalf("user %s: SUM(delta) %d != chips %d", id, ledgerSum, chips)
		}
	}
	if v := metricValue(second.metrics.RestoredTablesTotal.WithLabelValues("live")); v != 1 {
		t.Fatalf("restored_tables_total = %v", v)
	}
	if v := metricValue(second.metrics.RestoredSeatsTotal); v != 2 {
		t.Fatalf("restored_seats_total = %v", v)
	}
	if v := metricValue(second.metrics.RefundedPotsTotal); v != 1 {
		t.Fatalf("refunded_pots_total = %v", v)
	}
	if v := metricValue(second.metrics.RefundedChipsTotal); v != 400 {
		t.Fatalf("refunded_chips_total = %v", v)
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
	// The live hand's pot has been settled by now (Alice won last standing) —
	// nothing about the restored hand was ever refunded.
	var refundRows int64
	_ = database.Pool.QueryRow(context.Background(), `SELECT COUNT(*) FROM chip_ledger WHERE hand_id = $1 AND reason = $2`, liveHand, db.LedgerReasonRefund).Scan(&refundRows)
	if refundRows != 0 {
		t.Fatalf("the restored hand was refunded (%d rows)", refundRows)
	}
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
	var open int64
	if err := database.Pool.QueryRow(context.Background(), `SELECT COUNT(*) FROM pots WHERE closed_at IS NULL`).Scan(&open); err != nil || open != 0 {
		t.Fatalf("open pots after a memory-store shutdown: %d (%v)", open, err)
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

// The durable backstop end to end (LIVE_STATE_PLAN.md "Redis and the server
// both die"): the live store is EMPTY on restart, game_states has the room →
// the table is rebuilt from it, reconciled against the ledger, and written
// straight back into the live store.
func TestRestartWithEmptyLiveStoreRestoresFromGameStates(t *testing.T) {
	if !durableRestoreWired {
		t.Skip("TODO(live-game): RoomManager.Restore pass 2 (DurableSource) is not wired yet")
	}
	database := dbtest.Open(t, "app")
	cfg := testConfig(t, publicDir(t))
	cfg.Game.TurnTimeout = 20 * time.Second
	cfg.Game.ReconnectGrace = 700 * time.Millisecond
	cfg.SnapshotFlush = 50 * time.Millisecond

	// Process 1 plays a hand; the writer flushes game_states on its own.
	first := newAppOn(t, cfg, database, livetest.New())
	ts1 := httptest.NewServer(first.Handler())
	defer ts1.Close()
	tokA, idA := login(t, ts1.URL, "durable-device-alice-1", "Alice")
	tokB, idB := login(t, ts1.URL, "durable-device-bob-0001", "Bob")
	a1, b1 := dial(t, ts1.URL, tokA), dial(t, ts1.URL, tokB)
	join := map[string]any{"bootAmount": 200, "category": "seen"}
	joined := mustOK(t, a1, socket.EvRoomQuickJoin, join)
	mustOK(t, b1, socket.EvRoomQuickJoin, join)
	roomID, _ := jsonPath(joined.Raw, "roomId").(string)
	if _, err := a1.Wait(socket.EvGameHandStarted, nil, 4*time.Second); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	if err := first.Shutdown(ctx); err != nil { // suspend + final Flush
		t.Fatalf("shutdown 1: %v", err)
	}
	var rows int64
	if err := database.Pool.QueryRow(context.Background(), `SELECT COUNT(*) FROM game_states WHERE room_id = $1`, roomID).Scan(&rows); err != nil || rows != 1 {
		t.Fatalf("game_states rows for the room = %d (%v)", rows, err)
	}

	// Process 2: the live store came back EMPTY.
	empty := livetest.New()
	second := newAppOn(t, cfg, database, empty)
	restored := second.Restore()
	if restored.Tables != 1 || restored.Seats != 2 || restored.HandsInProgress != 1 {
		t.Fatalf("restore report = %+v", restored)
	}
	if _, fromPostgres, _, _ := restoreBreakdown(restored); fromPostgres != 1 {
		t.Fatalf("restore did not come from postgres: %+v", restored)
	}
	if empty.Tables() != 1 {
		t.Fatalf("the restored table was not written back into the live store (%d)", empty.Tables())
	}
	if second.Refund().Pots != 0 {
		t.Fatalf("the live hand's pot was refunded: %+v", second.Refund())
	}
	// Ledger invariant after a durable restore: the table's pot equals the
	// ledger's total for the hand.
	table := second.Rooms().GetTable(roomID)
	if table == nil {
		t.Fatal("table not registered")
	}
	view, err := table.SerializeFor(idA)
	if err != nil {
		t.Fatal(err)
	}
	var ledgerPot int64
	_ = database.Pool.QueryRow(context.Background(), `SELECT -SUM(delta)::bigint FROM chip_ledger WHERE hand_id = $1 AND reason IN ('boot','bet','show')`, restored.HandIDs[0]).Scan(&ledgerPot)
	if view.Pot != ledgerPot {
		t.Fatalf("restored pot %d != ledger total %d", view.Pot, ledgerPot)
	}
	// Both seats are held; Alice returns to the rebuilt table.
	ts2 := httptest.NewServer(second.Handler())
	defer ts2.Close()
	a2 := dial(t, ts2.URL, tokA)
	if rejoined, err := a2.Wait(socket.EvRoomJoined, nil, 4*time.Second); err != nil || jsonPath(rejoined, "roomId") != roomID {
		t.Fatalf("Alice not back at her table: %v %s", err, rejoined)
	}
	_ = idB
}
