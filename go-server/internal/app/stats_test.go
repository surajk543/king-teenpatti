package app

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/livetest"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// Player stats v2 (owner, 27 Sep 2026) on the real wiring: a hand played over
// the socket is counted by its table once its settle commits, queued by the
// recorder into the live store, moved into PostgreSQL by the flusher, and read
// back as user.stats — nothing of it written in the money transactions.

// statsOf reads GET /api/auth/me's user.stats.<path>.
func statsOf(t *testing.T, baseURL, token, path string) any {
	t.Helper()
	status, raw := friendsCall(t, baseURL, token, http.MethodGet, "/api/auth/me", "")
	if status != http.StatusOK {
		t.Fatalf("GET /api/auth/me: %d %s", status, raw)
	}
	return jsonField(t, raw, "user."+path)
}

func TestAHandPlayedOverTheSocketReachesTheAccountByTheFlusher(t *testing.T) {
	a, database := newApp(t, func(cfg *config.Config) { cfg.Game.TurnTimeout = 20 * time.Second })
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	tokA, idA := login(t, ts.URL, "stats-socket-alice-01", "Alice")
	tokB, idB := login(t, ts.URL, "stats-socket-bob-0001", "Bob")
	c1, c2 := dial(t, ts.URL, tokA), dial(t, ts.URL, tokB)
	join := map[string]any{"bootAmount": 200, "category": "seen"}
	mustOK(t, c1, socket.EvRoomQuickJoin, join)
	mustOK(t, c2, socket.EvRoomQuickJoin, join)
	if _, err := c1.Wait(socket.EvGameHandStarted, nil, 4*time.Second); err != nil {
		t.Fatal(err)
	}
	table := game.AsTable(a.Rooms().GetTableForPlayer(idA))
	view, err := table.SerializeFor(idA)
	if err != nil || view.Turn == nil || view.Turn.UserID == nil {
		t.Fatalf("no turn: %v", err)
	}
	folderToken, winnerToken := tokA, tokB
	client := c1
	if *view.Turn.UserID == idB {
		folderToken, winnerToken, client = tokB, tokA, c2
	}
	mustOK(t, client, socket.EvGameAction, map[string]any{"action": "pack"})
	if _, err := c1.Wait(socket.EvGameHandEnded, nil, 4*time.Second); err != nil {
		t.Fatal(err)
	}

	// Nothing reached PostgreSQL in the hand's own transactions.
	var rows int64
	if err := database.Pool.QueryRow(context.Background(), `SELECT count(*) FROM player_stats`).Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("%d player_stats rows before any flush (%v): the ledger writes money only", rows, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	report, err := a.FlushStats(ctx)
	if err != nil || report.Players != 2 {
		t.Fatalf("the flush: %+v %v", report, err)
	}
	if got := statsOf(t, ts.URL, winnerToken, "stats.teenPatti.handsWon"); got != float64(1) {
		t.Fatalf("the winner's teenPatti.handsWon = %v", got)
	}
	if got := statsOf(t, ts.URL, folderToken, "stats.teenPatti.handsLost"); got != float64(1) {
		t.Fatalf("the folder's teenPatti.handsLost = %v", got)
	}
	if got := statsOf(t, ts.URL, folderToken, "handsLost"); got != float64(1) {
		t.Fatalf("the folder's total handsLost = %v", got)
	}
	// Each held a hand the server counted, whether they looked or not.
	for _, tok := range []string{winnerToken, folderToken} {
		hands, _ := statsOf(t, ts.URL, tok, "stats.teenPatti.hands").(map[string]any)
		var held float64
		for _, n := range hands {
			held += n.(float64)
		}
		if held != 1 {
			t.Fatalf("teenPatti.hands = %v, want one hand held", hands)
		}
	}
	if got := statsOf(t, ts.URL, winnerToken, "stats.variation.variations"); got == nil {
		t.Fatal("variation.variations is not a list")
	}
	if got := statsOf(t, ts.URL, winnerToken, "stats.poker.handsPlayed"); got != float64(0) {
		t.Fatalf("poker.handsPlayed = %v", got)
	}
}

// A shutdown settles the hands in play (the in-process store) and flushes
// their statistics before the process goes.
func TestShutdownFlushesTheStatisticsOfTheHandsItSettles(t *testing.T) {
	database := dbtest.Open(t, "app")
	cfg := testConfig(t, publicDir(t))
	a, err := New(Options{Config: cfg, DB: database, Logger: util.NewLogger("error", io.Discard)})
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	tokA, idA := login(t, ts.URL, "stats-shutdown-alice-1", "Alice")
	tokB, idB := login(t, ts.URL, "stats-shutdown-bob-001", "Bob")
	c1, c2 := dial(t, ts.URL, tokA), dial(t, ts.URL, tokB)
	join := map[string]any{"bootAmount": 200, "category": "blind"}
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
	var won, lost int64
	if err := database.Pool.QueryRow(context.Background(), `SELECT COALESCE(SUM(hands_won), 0), COALESCE(SUM(hands_lost), 0)
	     FROM player_stats WHERE category = 'TEEN_PATTI' AND user_id IN ($1, $2)`, idA, idB).Scan(&won, &lost); err != nil {
		t.Fatal(err)
	}
	if won != 1 || lost != 1 {
		t.Fatalf("after shutdown: %d won, %d lost — the settled hand's statistics were not flushed", won, lost)
	}
}

// DELETE /api/account removes the player's statistics from PostgreSQL and
// drops what was still waiting in the live store; a flush brings nothing back.
func TestDeletingAnAccountDropsItsStatisticsEverywhere(t *testing.T) {
	store := livetest.New()
	database := dbtest.Open(t, "app")
	a := newAppOn(t, testConfig(t, publicDir(t)), database, store)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	tok, id := login(t, ts.URL, "stats-delete-gone-0001", "Gone")
	hand := []game.HandStats{{UserID: id, Bucket: game.StatsPoker, Played: 1, Won: 1, Winnings: 500}}
	a.statsRecorder.Record(hand)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := a.FlushStats(ctx); err != nil {
		t.Fatal(err)
	}
	if got := statsOf(t, ts.URL, tok, "stats.poker.handsWon"); got != float64(1) {
		t.Fatalf("before the deletion: %v", got)
	}
	// Another hand's counters, still waiting in the live store.
	a.statsRecorder.Record(hand)
	if err := a.statsRecorder.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	if store.PendingStats(id) == nil {
		t.Fatal("nothing waiting in the live store")
	}
	status, raw := friendsCall(t, ts.URL, tok, http.MethodDelete, "/api/account", "")
	if status != http.StatusOK {
		t.Fatalf("DELETE /api/account: %d %s", status, raw)
	}
	if store.PendingStats(id) != nil {
		t.Fatal("the deleted account's pending statistics survive in the live store")
	}
	if _, err := a.FlushStats(ctx); err != nil {
		t.Fatal(err)
	}
	var rows int64
	if err := database.Pool.QueryRow(context.Background(), `SELECT (SELECT count(*) FROM player_stats WHERE user_id = $1) +
	     (SELECT count(*) FROM player_variation_stats WHERE user_id = $1)`, id).Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("%d statistics rows for a deleted account (%v)", rows, err)
	}
}
