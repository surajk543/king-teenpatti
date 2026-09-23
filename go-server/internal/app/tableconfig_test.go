package app

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/livetest"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket/testclient"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// The table catalogue at boot (owner, 23 Sep 2026: "all table related config
// store in database", then "Teen Patti engines / Poker engines"):
// TABLE_CONFIG_SOURCE=db reads the four configuration tables once — the
// engines, the categories under them, table_settings and table_configs — GET
// /api/tables serves what the server then enforces, and /health says where it
// came from.

// syncBuffer is a log sink the race detector accepts: the app logs from its
// own goroutines while a test reads what was written.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// logLine is the first JSON log line whose msg is msg, or nil.
func (b *syncBuffer) logLine(msg string) map[string]any {
	for _, line := range strings.Split(b.String(), "\n") {
		var entry map[string]any
		if json.Unmarshal([]byte(line), &entry) == nil && entry["msg"] == msg {
			return entry
		}
	}
	return nil
}

// logLines is every JSON log line whose msg is msg.
func (b *syncBuffer) logLines(msg string) []map[string]any {
	var out []map[string]any
	for _, line := range strings.Split(b.String(), "\n") {
		var entry map[string]any
		if json.Unmarshal([]byte(line), &entry) == nil && entry["msg"] == msg {
			out = append(out, entry)
		}
	}
	return out
}

// dbSourced is testConfig switched to the database catalogue, with every
// table figure the env composition reads set to something the seed does NOT
// say — so whatever the server advertises or plays by can only have come from
// the rows. The keys "set" are what a deployment's .env would still list.
func dbSourced(t *testing.T) *config.Config {
	t.Helper()
	cfg := testConfig(t, publicDir(t))
	cfg.TableConfigSource = config.TableConfigSourceDB
	cfg.TableEnvKeysSet = []string{"BOOT_AMOUNT", "TABLE_STAKES", "LOBBY_TABLES", "TURN_TIMEOUT_MS", "SIDESHOW_TIMEOUT_MS", "MAX_BLIND_MOVES"}
	cfg.Game.BootAmount = 5000                   // the seed: 200
	cfg.Game.TurnTimeout = 9 * time.Second       // the seed: 25000 ms
	cfg.Game.SideshowTimeout = 2 * time.Second   // the seed: 6000 ms
	cfg.Game.MaxBlindMoves = 2                   // the seed: 4
	cfg.Game.TableStakes = []int64{}             // any stake; the seed: four
	cfg.Game.LobbyTables = []config.LobbyTable{} // any pair; the seed: twelve tables
	return cfg
}

// bootLogged is newAppOn with the app's log kept for the test to read.
func bootLogged(t *testing.T, cfg *config.Config, database *db.DB) (*App, *syncBuffer) {
	t.Helper()
	logs := &syncBuffer{}
	a, err := New(Options{Config: cfg, DB: database, Logger: util.NewLogger("info", logs), Live: livetest.New()})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		if err := a.Shutdown(ctx); err != nil {
			t.Errorf("Shutdown: %v", err)
		}
	})
	return a, logs
}

// sessionReadyConfig signs a fresh guest in and returns session:ready.config
// with the client, still connected.
func sessionReadyConfig(t *testing.T, baseURL, device string) (map[string]json.RawMessage, *testclient.Client) {
	t.Helper()
	tok, _ := login(t, baseURL, device, "Tables")
	c := dial(t, baseURL, tok)
	ready, ok := c.Last(socket.EvSessionReady)
	if !ok {
		t.Fatal("no session:ready")
	}
	var body struct {
		Config map[string]json.RawMessage `json:"config"`
	}
	if err := json.Unmarshal(ready, &body); err != nil {
		t.Fatal(err)
	}
	return body.Config, c
}

// tablesBody is GET /api/tables decoded as a map, with its response.
func tablesBody(t *testing.T, h http.Handler, mutate func(*http.Request)) (*http.Response, map[string]json.RawMessage) {
	t.Helper()
	res, raw := get(t, h, http.MethodGet, "/api/tables", mutate)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("GET /api/tables: %d %s", res.StatusCode, raw)
	}
	var body map[string]json.RawMessage
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatalf("GET /api/tables: %v: %s", err, raw)
	}
	return res, body
}

// tableEntry is the entry of a /api/tables (or session:ready) list whose
// category and boot are these.
func tableEntry(t *testing.T, list json.RawMessage, category string, boot int64) map[string]any {
	t.Helper()
	var entries []map[string]any
	if err := json.Unmarshal(list, &entries); err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if e["category"] == category && e["bootAmount"] == float64(boot) {
			return e
		}
	}
	return nil
}

func tableHealth(t *testing.T, a *App) TableConfigHealth {
	t.Helper()
	res, body := get(t, a.Handler(), http.MethodGet, "/health", nil)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("/health: %d %s", res.StatusCode, body)
	}
	var h struct {
		TableConfig TableConfigHealth `json:"tableConfig"`
	}
	if err := json.Unmarshal(body, &h); err != nil {
		t.Fatal(err)
	}
	return h.TableConfig
}

// seedEngines is the taxonomy V1.0.1__seed.sql writes — which is also what an
// env-sourced server serves (config.DefaultTableEngines and
// DefaultTableCategories) — as GET /api/tables carries it.
func seedEngines() []game.TableConfigEngine {
	return []game.TableConfigEngine{
		{Code: "teen_patti", Name: "Teen Patti", SortOrder: 10, Categories: []game.TableConfigCategory{
			{Code: "seen", Name: "Seen", SortOrder: 10},
			{Code: "blind", Name: "Blind", SortOrder: 20},
			{Code: "variation", Name: "Variation", SortOrder: 30},
		}},
		{Code: "poker", Name: "Poker", SortOrder: 20, Categories: []game.TableConfigCategory{
			{Code: "three_card_poker", Name: "3-Card Poker", SortOrder: 40},
			{Code: "five_card_draw", Name: "5-Card Draw", SortOrder: 50},
			{Code: "texas_holdem", Name: "Texas Hold'em", SortOrder: 60},
			{Code: "omaha", Name: "Omaha", SortOrder: 70},
		}},
	}
}

// enginesOf is a /api/tables body's engines, decoded.
func enginesOf(t *testing.T, body map[string]json.RawMessage) []game.TableConfigEngine {
	t.Helper()
	var engines []game.TableConfigEngine
	if err := json.Unmarshal(body["engines"], &engines); err != nil || engines == nil {
		t.Fatalf("engines %s: %v", body["engines"], err)
	}
	return engines
}

// entriesOf is one of a /api/tables body's table lists, decoded as maps.
func entriesOf(t *testing.T, body map[string]json.RawMessage, key string) []map[string]any {
	t.Helper()
	var entries []map[string]any
	if err := json.Unmarshal(body[key], &entries); err != nil || entries == nil {
		t.Fatalf("%s %s: %v", key, body[key], err)
	}
	return entries
}

// assertFiledByEngine checks that every entry of a /api/tables body — the
// menu and the private templates — names the engine its category is played
// by, and returns how many of each list there are.
func assertFiledByEngine(t *testing.T, body map[string]json.RawMessage) (tables, private int) {
	t.Helper()
	for _, key := range []string{"tables", "privateTables"} {
		for _, e := range entriesOf(t, body, key) {
			category, _ := e["category"].(string)
			if e["engine"] != config.EngineOf(category) {
				t.Errorf("%s: %s is filed under engine %v, want %s", key, e["key"], e["engine"], config.EngineOf(category))
			}
		}
	}
	return len(entriesOf(t, body, "tables")), len(entriesOf(t, body, "privateTables"))
}

func rawString(raw json.RawMessage) string {
	var s string
	_ = json.Unmarshal(raw, &s)
	return s
}

func rawNumber(raw json.RawMessage) float64 {
	var n float64
	_ = json.Unmarshal(raw, &n)
	return n
}

// TestADatabaseSourcedServerPlaysByTheSeedNotTheEnv: with
// TABLE_CONFIG_SOURCE=db and every table env figure set to something else,
// the server advertises, admits and deals by the seeded rows — the default
// stake, the clocks, the stakes list and the menu are the database's — while
// the caller's Config is left exactly as it was handed in, and the env keys
// it still lists are named once, in a WARN, as ignored.
func TestADatabaseSourcedServerPlaysByTheSeedNotTheEnv(t *testing.T) {
	database := dbtest.Open(t, "app")
	cfg := dbSourced(t)
	a, logs := bootLogged(t, cfg, database)

	if h := tableHealth(t, a); h.Source != config.TableConfigSourceDB || h.Fallback || h.Version != a.Rooms().TableConfigVersion() || len(h.Version) != 64 {
		t.Fatalf("/health tableConfig = %+v, want db with the manager's version", h)
	}
	warns := logs.logLines("table env keys are ignored in db mode")
	if len(warns) != 1 || warns[0]["level"] != "WARN" || !reflect.DeepEqual(warns[0]["keys"], []any{"BOOT_AMOUNT", "TABLE_STAKES", "LOBBY_TABLES", "TURN_TIMEOUT_MS", "SIDESHOW_TIMEOUT_MS", "MAX_BLIND_MOVES"}) {
		t.Errorf("the ignored keys were not named in one WARN: %v\n%s", warns, logs)
	}
	if logs.logLine("table config row left out") != nil || logs.logLine("table config in the database is unusable; running the env composition instead") != nil {
		t.Errorf("the seed was reported as faulty:\n%s", logs)
	}
	// New worked on its own copy.
	if cfg.Game.Catalogue != nil || cfg.Game.BootAmount != 5000 || cfg.Game.TurnTimeout != 9*time.Second || len(cfg.Game.LobbyTables) != 0 {
		t.Fatalf("New changed the caller's Config: catalogue %v, boot %d, turn %s, %d tables",
			cfg.Game.Catalogue != nil, cfg.Game.BootAmount, cfg.Game.TurnTimeout, len(cfg.Game.LobbyTables))
	}

	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	sess, c := sessionReadyConfig(t, ts.URL, "tables-db-seed-01")
	for key, want := range map[string]float64{"bootAmount": 200, "turnTimeoutMs": 25000, "sideshowTimeoutMs": 6000, "maxPlayers": 5, "minPlayers": 2} {
		if got := rawNumber(sess[key]); got != want {
			t.Errorf("session:ready.config.%s = %v, want the seed's %v", key, got, want)
		}
	}
	var stakes []int64
	_ = json.Unmarshal(sess["stakes"], &stakes)
	if !reflect.DeepEqual(stakes, []int64{200, 5000, 50000, 1000000}) {
		t.Errorf("stakes = %v, want the seed's", stakes)
	}
	var menu []map[string]any
	_ = json.Unmarshal(sess["tables"], &menu)
	if len(menu) != 12 || menu[0]["category"] != "seen" || menu[0]["bootAmount"] != float64(200) {
		t.Fatalf("the menu is not the seed's twelve tables: %d, first %v", len(menu), menu[0])
	}
	if blind := tableEntry(t, sess["tables"], "blind", 200); blind == nil || blind["maxBlindMoves"] != float64(4) {
		t.Errorf("blind 200 advertises %v blind moves, want the seed's 4", blind["maxBlindMoves"])
	}
	if got := rawString(sess["tableConfigVersion"]); got != a.Rooms().TableConfigVersion() {
		t.Errorf("tableConfigVersion %q, the manager's %q", got, a.Rooms().TableConfigVersion())
	}

	// A quick-join naming nothing sits at the seed's default stake, at a
	// table on the seed's clock; a stake the rows do not list is refused.
	mustOK(t, c, socket.EvRoomQuickJoin, map[string]any{})
	joined, err := c.Wait(socket.EvRoomJoined, nil, 4*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if jsonPath(joined, "bootAmount") != float64(200) || jsonPath(joined, "turnTimeoutMs") != float64(25000) || jsonPath(joined, "category") != "seen" {
		t.Fatalf("seated at %v %v on a %v ms clock, want seen 200 on 25000", jsonPath(joined, "category"), jsonPath(joined, "bootAmount"), jsonPath(joined, "turnTimeoutMs"))
	}
	tok, _ := login(t, ts.URL, "tables-db-seed-02", "Stake")
	other := dial(t, ts.URL, tok)
	ack, err := other.Call(socket.EvRoomQuickJoin, map[string]any{"bootAmount": 777, "category": "seen"}, 4*time.Second)
	if err != nil || ack.OK || ack.Code != "invalid_stake" {
		t.Fatalf("a stake the rows do not list: %v %s", err, ack.Raw)
	}
}

// TestGetApiTablesIsTheSessionMenuUnderOneVersion: GET /api/tables is public,
// revalidated (no-cache + ETag) and answers 304 to the version a client holds;
// every key it shares with session:ready.config holds the same value there —
// the menu entry for entry — and its version is session:ready's
// tableConfigVersion. It also carries the taxonomy: the engines with their
// categories, and every table filed under its engine. In both modes.
func TestGetApiTablesIsTheSessionMenuUnderOneVersion(t *testing.T) {
	database := dbtest.Open(t, "app")
	for _, mode := range []struct {
		name    string
		cfg     *config.Config
		source  string
		tables  int
		private int
	}{
		{"db", dbSourced(t), config.TableConfigSourceDB, 12, 7},
		{"env", func() *config.Config {
			cfg := testConfig(t, publicDir(t))
			cfg.Game.LobbyTables = []config.LobbyTable{{Category: "seen", BootAmount: 200}, {Category: "blind", BootAmount: 5000, MaxChips: 50000000}, {Category: "texas_holdem", BootAmount: 200}}
			return cfg
		}(), config.TableConfigSourceEnv, 3, 6},
	} {
		t.Run(mode.name, func(t *testing.T) {
			a := newAppOn(t, mode.cfg, database, livetest.New())
			h := a.Handler()
			res, body := tablesBody(t, h, nil)
			version := rawString(body["version"])
			if len(version) != 64 || version != a.Rooms().TableConfigVersion() {
				t.Fatalf("version %q, the manager's %q", version, a.Rooms().TableConfigVersion())
			}
			if res.Header.Get("Cache-Control") != "no-cache" || res.Header.Get("ETag") != `"`+version+`"` {
				t.Errorf("Cache-Control %q ETag %q", res.Header.Get("Cache-Control"), res.Header.Get("ETag"))
			}
			if !strings.HasPrefix(res.Header.Get("Content-Type"), "application/json") {
				t.Errorf("Content-Type %q", res.Header.Get("Content-Type"))
			}
			if rawString(body["source"]) != mode.source {
				t.Errorf("source %s, want %s", body["source"], mode.source)
			}
			for _, key := range []string{"welcomeChips", "minClientBuild", "tableConfigVersion"} {
				if _, ok := body[key]; ok {
					t.Errorf("/api/tables carries the session-scoped %s", key)
				}
			}
			// The taxonomy: the seed's engines and categories (from env, the
			// same defaults), and every table filed under its engine.
			if got := enginesOf(t, body); !reflect.DeepEqual(got, seedEngines()) {
				t.Errorf("engines = %+v, want the seed's %+v", got, seedEngines())
			}
			if tables, private := assertFiledByEngine(t, body); tables != mode.tables || private != mode.private {
				t.Errorf("%d tables and %d private templates, want %d and %d", tables, private, mode.tables, mode.private)
			}

			ts := httptest.NewServer(h)
			defer ts.Close()
			sess, _ := sessionReadyConfig(t, ts.URL, "tables-api-"+mode.name+"-01")
			if rawString(sess["tableConfigVersion"]) != version {
				t.Fatalf("session:ready.config.tableConfigVersion %s, /api/tables %s", sess["tableConfigVersion"], version)
			}
			for key, raw := range sess {
				switch key {
				case "welcomeChips", "minClientBuild", "tableConfigVersion":
					continue
				case "tables":
					var want, got []map[string]any
					_ = json.Unmarshal(raw, &want)
					_ = json.Unmarshal(body["tables"], &got)
					if len(want) != mode.tables || len(got) != len(want) {
						t.Fatalf("tables: session %d, /api/tables %d, want %d", len(want), len(got), mode.tables)
					}
					for i := range want {
						for k, v := range want[i] {
							if !reflect.DeepEqual(got[i][k], v) {
								t.Errorf("tables[%d].%s: session %v, /api/tables %v", i, k, v, got[i][k])
							}
						}
					}
				default:
					var want, got any
					_ = json.Unmarshal(raw, &want)
					_ = json.Unmarshal(body[key], &got)
					if !reflect.DeepEqual(got, want) {
						t.Errorf("%s: session %s, /api/tables %s", key, raw, body[key])
					}
				}
			}

			// Revalidation: the version a client holds (strong, weak, in a
			// list, or any) is 304 with no body; another is the body again.
			for _, inm := range []string{`"` + version + `"`, `W/"` + version + `"`, `"stale", "` + version + `"`, `*`} {
				res, raw := get(t, h, http.MethodGet, "/api/tables", func(r *http.Request) { r.Header.Set("If-None-Match", inm) })
				if res.StatusCode != http.StatusNotModified || len(raw) != 0 || res.Header.Get("ETag") != `"`+version+`"` {
					t.Errorf("If-None-Match %s: %d %q ETag %q", inm, res.StatusCode, raw, res.Header.Get("ETag"))
				}
			}
			if res, _ := tablesBody(t, h, func(r *http.Request) { r.Header.Set("If-None-Match", `"stale"`) }); res.StatusCode != http.StatusOK {
				t.Errorf("a stale version: %d", res.StatusCode)
			}
		})
	}
}

// TestAnEditedRowTakesEffectAtTheNextBootOnly: the rows are read once. An
// UPDATE changes nothing on a running server — its /api/tables and its
// version stay — and everything on the next one: the new figure on the card,
// on a table it opens, a renamed engine in the taxonomy, under a new version.
func TestAnEditedRowTakesEffectAtTheNextBootOnly(t *testing.T) {
	database := dbtest.Open(t, "app")
	first, _ := bootLogged(t, dbSourced(t), database)
	_, before := tablesBody(t, first.Handler(), nil)

	if _, err := database.Pool.Exec(context.Background(),
		`UPDATE table_configs SET turn_timeout_ms = 31000, max_blind_moves = 3 WHERE table_key = 'blind:200';
		 UPDATE table_engines SET name = 'Poker Room' WHERE code = 'poker'`); err != nil {
		t.Fatal(err)
	}
	_, still := tablesBody(t, first.Handler(), nil)
	if !reflect.DeepEqual(still, before) {
		t.Fatal("a running server's catalogue changed under it")
	}

	second, _ := bootLogged(t, dbSourced(t), database)
	_, after := tablesBody(t, second.Handler(), nil)
	if rawString(after["version"]) == rawString(before["version"]) {
		t.Fatal("an edited catalogue kept its version")
	}
	blind := tableEntry(t, after["tables"], "blind", 200)
	if blind == nil || blind["turnTimeoutMs"] != float64(31000) || blind["maxBlindMoves"] != float64(3) {
		t.Fatalf("blind 200 after the edit: %v", blind)
	}
	if seen := tableEntry(t, after["tables"], "seen", 200); seen["turnTimeoutMs"] != float64(25000) {
		t.Errorf("the edit reached seen 200: %v", seen["turnTimeoutMs"])
	}
	want := seedEngines()
	want[1].Name = "Poker Room"
	if got := enginesOf(t, after); !reflect.DeepEqual(got, want) {
		t.Errorf("engines after the rename = %+v, want %+v", got, want)
	}

	ts := httptest.NewServer(second.Handler())
	defer ts.Close()
	_, c := sessionReadyConfig(t, ts.URL, "tables-edited-01")
	mustOK(t, c, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "blind"})
	joined, err := c.Wait(socket.EvRoomJoined, nil, 4*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if jsonPath(joined, "turnTimeoutMs") != float64(31000) {
		t.Fatalf("a blind 200 table opened after the edit runs a %v ms clock, want 31000", jsonPath(joined, "turnTimeoutMs"))
	}
}

// TestARowTheEngineMustNotOpenIsLeftOutAndTheBootCarriesOn: what the foreign
// keys and CHECKs accept but no engine can open — a category this server does
// not know (its own table_categories row added first, as the FK demands), a
// category filed under the wrong engine, a table whose per-bet ceiling
// overflows — is left out with one ERROR per problem naming the row; the rest
// of the catalogue runs, from the database, and the table that row described
// is simply not offered: not on the menu, not in the taxonomy, refused at the
// door.
func TestARowTheEngineMustNotOpenIsLeftOutAndTheBootCarriesOn(t *testing.T) {
	for _, tc := range []struct {
		name     string
		sql      string
		category string
		boot     int64
		problems []string // one substring per ERROR line, in order
		tables   int
		private  int
		engines  func([]game.TableConfigEngine) []game.TableConfigEngine
	}{
		{
			name: "a category this server does not know",
			sql: `INSERT INTO table_categories (code, engine, name, sort_order) VALUES ('rummy', 'teen_patti', 'Rummy', 80);
			      UPDATE table_configs SET category = 'rummy' WHERE table_key = 'blind:5000'`,
			category: "blind", boot: 5000,
			problems: []string{`category rummy left out: unknown category "rummy"`, "table rummy:5000 left out"},
			tables:   11, private: 7,
			engines: func(e []game.TableConfigEngine) []game.TableConfigEngine { return e },
		},
		{
			name:     "a category filed under the wrong engine",
			sql:      `UPDATE table_categories SET engine = 'teen_patti' WHERE code = 'omaha'`,
			category: "omaha", boot: 50000,
			problems: []string{"category omaha left out: omaha is a poker category, not teen_patti", "table omaha:50000 left out", "table private:omaha left out"},
			tables:   11, private: 6,
			engines: func(e []game.TableConfigEngine) []game.TableConfigEngine {
				e[1].Categories = e[1].Categories[:3]
				return e
			},
		},
		{
			name:     "a table whose per-bet ceiling overflows",
			sql:      `UPDATE table_configs SET pot_limit_multiplier = 9223372036854775807 WHERE table_key = 'seen:50000'`,
			category: "seen", boot: 50000,
			problems: []string{"table seen:50000 left out: boot_amount × pot_limit_multiplier overflows"},
			tables:   11, private: 7,
			engines: func(e []game.TableConfigEngine) []game.TableConfigEngine { return e },
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database := dbtest.Open(t, "app")
			if _, err := database.Pool.Exec(context.Background(), tc.sql); err != nil {
				t.Fatal(err)
			}
			a, logs := bootLogged(t, dbSourced(t), database)

			lines := logs.logLines("table config row left out")
			if len(lines) != len(tc.problems) {
				t.Fatalf("%d ERRORs, want %d:\n%s", len(lines), len(tc.problems), logs)
			}
			for i, want := range tc.problems {
				if lines[i]["level"] != "ERROR" || !strings.Contains(lines[i]["problem"].(string), want) {
					t.Errorf("ERROR %d = %v, want one saying %q", i, lines[i], want)
				}
			}
			if h := tableHealth(t, a); h.Source != config.TableConfigSourceDB || h.Fallback {
				t.Fatalf("/health tableConfig = %+v, want db, no fallback", h)
			}
			_, body := tablesBody(t, a.Handler(), nil)
			if tables, private := assertFiledByEngine(t, body); tables != tc.tables || private != tc.private {
				t.Errorf("%d tables and %d private templates, want %d and %d", tables, private, tc.tables, tc.private)
			}
			if e := tableEntry(t, body["tables"], tc.category, tc.boot); e != nil {
				t.Errorf("the left-out %s %d is still on the menu: %v", tc.category, tc.boot, e)
			}
			if got, want := enginesOf(t, body), tc.engines(seedEngines()); !reflect.DeepEqual(got, want) {
				t.Errorf("engines = %+v, want %+v", got, want)
			}

			ts := httptest.NewServer(a.Handler())
			defer ts.Close()
			_, c := sessionReadyConfig(t, ts.URL, "tables-left-out-01")
			ack, err := c.Call(socket.EvRoomQuickJoin, map[string]any{"bootAmount": tc.boot, "category": tc.category}, 4*time.Second)
			if err != nil || ack.OK || ack.Code != "table_not_offered" {
				t.Fatalf("the left-out table: %v %s", err, ack.Raw)
			}
		})
	}
}

// TestAnInactiveCategoryOrEngineHidesItsTablesWithoutAWord: switching a
// category off (is_active = FALSE) takes every table of it off the menu, its
// private template with them, and the category out of the taxonomy; switching
// an engine off does that for every category under it — all of Poker in one
// UPDATE. It is a decision, not a fault: nothing is logged as left out, the
// server still runs from the database, and the doors agree with the menu — a
// quick-join is refused table_not_offered and a private create naming the
// category opens a seen table.
func TestAnInactiveCategoryOrEngineHidesItsTablesWithoutAWord(t *testing.T) {
	for _, tc := range []struct {
		name       string
		sql        string
		hidden     string // a category it hides
		boot       int64  // a stake that category was offered at
		tables     int
		private    int
		engines    func([]game.TableConfigEngine) []game.TableConfigEngine
		categories []string // session:ready.config.categories
	}{
		{
			name:   "one category",
			sql:    `UPDATE table_categories SET is_active = FALSE WHERE code = 'variation'`,
			hidden: "variation", boot: 50000,
			tables: 10, private: 6,
			engines: func(e []game.TableConfigEngine) []game.TableConfigEngine {
				e[0].Categories = e[0].Categories[:2]
				return e
			},
			categories: []string{"seen", "blind", "three_card_poker", "five_card_draw", "texas_holdem", "omaha"},
		},
		{
			name:   "a whole engine",
			sql:    `UPDATE table_engines SET is_active = FALSE WHERE code = 'poker'`,
			hidden: "texas_holdem", boot: 50000,
			tables: 8, private: 3,
			engines:    func(e []game.TableConfigEngine) []game.TableConfigEngine { return e[:1] },
			categories: []string{"seen", "blind", "variation"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database := dbtest.Open(t, "app")
			if _, err := database.Pool.Exec(context.Background(), tc.sql); err != nil {
				t.Fatal(err)
			}
			a, logs := bootLogged(t, dbSourced(t), database)
			for _, msg := range []string{"table config row left out", "table config in the database is unusable; running the env composition instead"} {
				if line := logs.logLine(msg); line != nil {
					t.Errorf("switching %s off was reported as a fault: %v", tc.hidden, line)
				}
			}
			if h := tableHealth(t, a); h.Source != config.TableConfigSourceDB || h.Fallback {
				t.Fatalf("/health tableConfig = %+v, want db, no fallback", h)
			}

			_, body := tablesBody(t, a.Handler(), nil)
			if tables, private := assertFiledByEngine(t, body); tables != tc.tables || private != tc.private {
				t.Errorf("%d tables and %d private templates, want %d and %d", tables, private, tc.tables, tc.private)
			}
			for _, key := range []string{"tables", "privateTables"} {
				for _, e := range entriesOf(t, body, key) {
					if e["category"] == tc.hidden {
						t.Errorf("%s still lists %v", key, e["key"])
					}
				}
			}
			if got, want := enginesOf(t, body), tc.engines(seedEngines()); !reflect.DeepEqual(got, want) {
				t.Errorf("engines = %+v, want %+v", got, want)
			}

			ts := httptest.NewServer(a.Handler())
			defer ts.Close()
			sess, c := sessionReadyConfig(t, ts.URL, "tables-inactive-01")
			var categories []string
			_ = json.Unmarshal(sess["categories"], &categories)
			if !reflect.DeepEqual(categories, tc.categories) {
				t.Errorf("session:ready.config.categories = %v, want %v", categories, tc.categories)
			}
			ack, err := c.Call(socket.EvRoomQuickJoin, map[string]any{"bootAmount": tc.boot, "category": tc.hidden}, 4*time.Second)
			if err != nil || ack.OK || ack.Code != "table_not_offered" {
				t.Fatalf("a quick-join at the hidden %s: %v %s", tc.hidden, err, ack.Raw)
			}
			created := mustOK(t, c, socket.EvRoomCreate, map[string]any{"isPrivate": true, "category": tc.hidden})
			if category := jsonPath(created.Raw, "category"); category != "seen" {
				t.Errorf("a private create naming the hidden %s opened a %v table, want seen", tc.hidden, category)
			}
		})
	}
}

// TestAnUnusableCatalogueFallsBackToTheEnvComposition: a catalogue that
// cannot run a lobby — no active public table, no settings row, or no private
// seen template (which switching the seen category off also means: its
// template goes with its tables) — is one ERROR, and the server runs the env
// composition it ran before the catalogue existed rather than refusing to
// boot; /health says so (source env, fallback true), and so do /api/tables
// and session:ready.
func TestAnUnusableCatalogueFallsBackToTheEnvComposition(t *testing.T) {
	for _, tc := range []struct{ name, sql string }{
		{"no public table", `UPDATE table_configs SET is_active = FALSE WHERE NOT is_private`},
		{"no settings row", `DELETE FROM table_settings`},
		{"the seen category switched off", `UPDATE table_categories SET is_active = FALSE WHERE code = 'seen'`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database := dbtest.Open(t, "app")
			if _, err := database.Pool.Exec(context.Background(), tc.sql); err != nil {
				t.Fatal(err)
			}
			a, logs := bootLogged(t, dbSourced(t), database)
			line := logs.logLine("table config in the database is unusable; running the env composition instead")
			if line == nil || line["level"] != "ERROR" {
				t.Fatalf("no ERROR for the unusable catalogue:\n%s", logs)
			}
			if h := tableHealth(t, a); h.Source != config.TableConfigSourceEnv || !h.Fallback || h.Version != a.Rooms().TableConfigVersion() {
				t.Fatalf("/health tableConfig = %+v, want env with fallback", h)
			}
			_, body := tablesBody(t, a.Handler(), nil)
			if rawString(body["source"]) != config.TableConfigSourceEnv || rawNumber(body["turnTimeoutMs"]) != 9000 || rawNumber(body["bootAmount"]) != 5000 {
				t.Fatalf("/api/tables: source %s, turn %s, boot %s — want the env composition", body["source"], body["turnTimeoutMs"], body["bootAmount"])
			}
			ts := httptest.NewServer(a.Handler())
			defer ts.Close()
			sess, _ := sessionReadyConfig(t, ts.URL, "tables-fallback-01")
			if rawNumber(sess["turnTimeoutMs"]) != 9000 {
				t.Fatalf("session:ready.config.turnTimeoutMs %s, want the env's 9000", sess["turnTimeoutMs"])
			}
		})
	}
}

// TestEnvModeWithTableKeysSaysHowToMoveThemIntoTheDatabase: an env-sourced
// server whose environment sets table keys — what makes an unset
// TABLE_CONFIG_SOURCE mean env — WARNs once with the way to switch (on a
// schema other than public, with the search_path psql needs to apply the
// export there); one that sets none says nothing; neither reads the rows, and
// /health reports env with no fallback.
func TestEnvModeWithTableKeysSaysHowToMoveThemIntoTheDatabase(t *testing.T) {
	database := dbtest.Open(t, "app")
	withKeys := testConfig(t, publicDir(t))
	withKeys.TableEnvKeysSet = []string{"LOBBY_TABLES"}
	withKeys.DB.Schema = "gameplay_live"
	a, logs := bootLogged(t, withKeys, database)
	warns := logs.logLines("table config comes from the env keys, not the database")
	if len(warns) != 1 || warns[0]["level"] != "WARN" || !reflect.DeepEqual(warns[0]["keys"], []any{"LOBBY_TABLES"}) {
		t.Fatalf("want one WARN naming the keys, got %v\n%s", warns, logs)
	}
	for _, want := range []string{"-export-table-config", "PGOPTIONS='-c search_path=gameplay_live'", "-check-table-config", "TABLE_CONFIG_SOURCE=db"} {
		if hint, _ := warns[0]["hint"].(string); !strings.Contains(hint, want) {
			t.Errorf("the WARN's hint does not say %q: %s", want, hint)
		}
	}
	if h := tableHealth(t, a); h.Source != config.TableConfigSourceEnv || h.Fallback {
		t.Fatalf("/health tableConfig = %+v, want env without fallback", h)
	}

	_, quiet := bootLogged(t, testConfig(t, publicDir(t)), database)
	if quiet.logLine("table config comes from the env keys, not the database") != nil {
		t.Fatalf("an environment with no table key was warned:\n%s", quiet)
	}
	if line := quiet.logLine("table config ready"); line == nil || line["source"] != "env" || line["fallback"] != false {
		t.Fatalf("no INFO naming the source: %v", line)
	}
}

// TestANewWithoutADatabaseFallsBackRatherThanFailing: db mode with no pool to
// read is the fallback, not a crash.
func TestANewWithoutADatabaseFallsBackRatherThanFailing(t *testing.T) {
	cfg := dbSourced(t)
	a, err := New(Options{Config: cfg, Logger: util.NewLogger("error", io.Discard), Live: livetest.New()})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(func() { _ = a.Shutdown(context.Background()) })
	if a.tableConfig.Source != config.TableConfigSourceEnv || !a.tableConfig.Fallback {
		t.Fatalf("tableConfig = %+v, want the env fallback", a.tableConfig)
	}
}
