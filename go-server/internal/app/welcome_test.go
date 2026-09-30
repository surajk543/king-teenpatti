package app

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
)

// What a new account is given comes from the welcome_rewards rows (owner,
// 30 Sep 2026), on the real wiring: the boot (outside production) sets the
// chips row from WELCOME_CHIPS, POST /api/auth/login answers a new account with its
// `welcome` — each item exactly as its catalogue route lists it — and a
// returning one without it, session:ready's welcomeChips follows the rows, and
// an owner's UPDATE reaches the next account with no restart.
func TestTheLoginAnswersANewAccountWithWhatItWasWelcomedWith(t *testing.T) {
	a, database := newApp(t, func(cfg *config.Config) { cfg.Game.WelcomeChips = 350000 })
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()
	if _, err := database.Pool.Exec(ctx, `INSERT INTO welcome_rewards (code, reward_type, reward_ref_id, sort_order) VALUES
		('welcome_picture', 'PROFILE_PICTURE', (SELECT id::text FROM profile_pictures WHERE name = 'Lovestruck Cat'), 50),
		('welcome_table_picture', 'TABLE_PICTURE', (SELECT id::text FROM table_pictures WHERE name = 'Lines Background'), 60),
		('welcome_emoji', 'EMOJI', (SELECT id::text FROM emojis WHERE name = 'Clapping Hands'), 70)`); err != nil {
		t.Fatal(err)
	}

	status, raw := loginRaw(t, ts.URL, "welcome-new-device")
	if status != http.StatusOK {
		t.Fatalf("login: %d %s", status, raw)
	}
	var body map[string]json.RawMessage
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatal(err)
	}
	if keys := sortedKeys(body); strings.Join(keys, ",") != "isNew,token,user,welcome,welcomeChips" {
		t.Fatalf("a new account's login answers %v", keys)
	}
	if string(body["isNew"]) != "true" || string(body["welcomeChips"]) != "350000" {
		t.Fatalf("isNew %s welcomeChips %s", body["isNew"], body["welcomeChips"])
	}
	var welcome map[string]json.RawMessage
	if err := json.Unmarshal(body["welcome"], &welcome); err != nil {
		t.Fatal(err)
	}
	if keys := sortedKeys(welcome); strings.Join(keys, ",") != "chips,diamonds,emojis,hammers,missiles,pictures,tablePictures" {
		t.Fatalf("welcome keys %v", keys)
	}
	for key, want := range map[string]string{"chips": "350000", "diamonds": "5", "hammers": "10", "missiles": "1"} {
		if string(welcome[key]) != want {
			t.Errorf("welcome.%s = %s, want %s", key, welcome[key], want)
		}
	}
	var token string
	_ = json.Unmarshal(body["token"], &token)
	var user struct {
		ID      string `json:"id"`
		Chips   int64  `json:"chips"`
		Diamond int64  `json:"diamond"`
		Hammer  int64  `json:"hammer"`
		Missile int64  `json:"missile"`
	}
	_ = json.Unmarshal(body["user"], &user)
	if user.Chips != 350000 || user.Diamond != 5 || user.Hammer != 10 || user.Missile != 1 {
		t.Fatalf("the account as answered: %+v", user)
	}

	// Each item is the catalogue route's own item for this player, byte for
	// byte: owned, with the term it was granted for.
	authed := func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+token) }
	for list, route := range map[string]string{
		"pictures":      "/api/profiles",
		"tablePictures": "/api/table-pictures",
		"emojis":        "/api/emojis",
	} {
		var items []map[string]json.RawMessage
		if err := json.Unmarshal(welcome[list], &items); err != nil || len(items) != 1 {
			t.Fatalf("welcome.%s = %s", list, welcome[list])
		}
		item := items[0]
		if string(item["owned"]) != "true" || string(item["expiresAt"]) == "0" {
			t.Errorf("welcome.%s[0] is not owned for a term: %v", list, item)
		}
		res, catalogueRaw := get(t, a.Handler(), http.MethodGet, route, authed)
		if res.StatusCode != http.StatusOK {
			t.Fatalf("GET %s: %d", route, res.StatusCode)
		}
		var catalogue map[string][]map[string]json.RawMessage
		if err := json.Unmarshal(catalogueRaw, &catalogue); err != nil {
			t.Fatal(err)
		}
		found := false
		for _, entries := range catalogue {
			for _, entry := range entries {
				if string(entry["id"]) == string(item["id"]) {
					found = true
					if !reflect.DeepEqual(entry, item) {
						t.Errorf("GET %s lists %v, the welcome said %v", route, entry, item)
					}
				}
			}
		}
		if !found {
			t.Errorf("GET %s does not list the welcome's %s", route, list)
		}
	}

	// A returning player: the answer as it always was.
	status, raw = loginRaw(t, ts.URL, "welcome-new-device")
	var again map[string]json.RawMessage
	if err := json.Unmarshal(raw, &again); err != nil || status != http.StatusOK {
		t.Fatalf("second login: %d %s", status, raw)
	}
	if keys := sortedKeys(again); strings.Join(keys, ",") != "isNew,token,user,welcomeChips" ||
		string(again["isNew"]) != "false" || string(again["welcomeChips"]) != "0" {
		t.Fatalf("a returning player's login: %s", raw)
	}

	// session:ready tells the next new account's chips.
	config, _ := sessionReadyConfig(t, ts.URL, "welcome-session-device")
	if string(config["welcomeChips"]) != "350000" {
		t.Fatalf("session:ready.config.welcomeChips = %s", config["welcomeChips"])
	}

	// An owner's UPDATE: the very next account, no restart; session:ready
	// once its cache has turned over.
	if _, err := database.Pool.Exec(ctx, `UPDATE welcome_rewards SET reward_value = 125000 WHERE code = 'chips'`); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Pool.Exec(ctx, `UPDATE welcome_rewards SET is_active = FALSE WHERE code IN ('hammers', 'welcome_picture', 'welcome_table_picture', 'welcome_emoji')`); err != nil {
		t.Fatal(err)
	}
	status, raw = loginRaw(t, ts.URL, "welcome-later-device")
	var later struct {
		WelcomeChips int64 `json:"welcomeChips"`
		Welcome      struct {
			Chips, Diamonds, Hammers, Missiles int64
			Pictures, TablePictures, Emojis    []json.RawMessage
		} `json:"welcome"`
	}
	if err := json.Unmarshal(raw, &later); err != nil || status != http.StatusOK {
		t.Fatalf("login after the UPDATE: %d %s", status, raw)
	}
	if w := later.Welcome; later.WelcomeChips != 125000 || w.Chips != 125000 || w.Diamonds != 5 || w.Hammers != 0 || w.Missiles != 1 ||
		w.Pictures == nil || len(w.Pictures) != 0 || len(w.TablePictures) != 0 || len(w.Emojis) != 0 {
		t.Fatalf("after the UPDATE: %s", raw)
	}
	a.welcomeChips.Invalidate()
	config, _ = sessionReadyConfig(t, ts.URL, "welcome-session-device-2")
	if string(config["welcomeChips"]) != "125000" {
		t.Fatalf("session:ready.config.welcomeChips after the UPDATE = %s", config["welcomeChips"])
	}
}

// In production the seed's chips row decides (5 Lakh; owner, 30 Sep 2026): a
// boot whose WELCOME_CHIPS differs is told so in one WARN and writes nothing.
// Outside production WELCOME_CHIPS sets the row (tests, parity, a local run),
// and a production boot after it leaves that row alone — and one that did
// not set WELCOME_CHIPS says nothing.
func TestInProductionTheChipsRowDecidesAndOutsideItWelcomeChipsSetsIt(t *testing.T) {
	database := dbtest.Open(t, "app")

	prodCfg := testConfig(t, publicDir(t))
	prodCfg.Env = config.EnvProduction
	prodCfg.Game.WelcomeChips, prodCfg.Game.WelcomeChipsSet = 350000, true
	prod, prodLogs := bootLogged(t, prodCfg, database)
	logs := prodLogs.String()
	if strings.Count(logs, "differs from the welcome_rewards chips") != 1 || !strings.Contains(logs, `"level":"WARN"`) ||
		!strings.Contains(logs, `"welcomeChipsEnv":350000`) || !strings.Contains(logs, `"newAccountChips":500000`) ||
		strings.Contains(logs, "welcome chips row written") || strings.Contains(logs, "welcome chips row set") {
		t.Fatalf("the production boot's log: %s", logs)
	}
	ts := httptest.NewServer(prod.Handler())
	defer ts.Close()
	status, raw := loginRaw(t, ts.URL, "welcome-seed-decides")
	var body struct {
		WelcomeChips int64 `json:"welcomeChips"`
	}
	if err := json.Unmarshal(raw, &body); err != nil || status != http.StatusOK || body.WelcomeChips != 500000 {
		t.Fatalf("the seed's 5 Lakh decides in production: %d %s", status, raw)
	}

	devCfg := testConfig(t, publicDir(t))
	devCfg.Game.WelcomeChips, devCfg.Game.WelcomeChipsSet = 999, true
	_, devLogs := bootLogged(t, devCfg, database)
	if logs := devLogs.String(); !strings.Contains(logs, `"msg":"welcome chips row set from WELCOME_CHIPS (not production)"`) ||
		strings.Contains(logs, "differs from the welcome_rewards chips") {
		t.Fatalf("the boot outside production: %s", logs)
	}
	var chips int64
	if err := database.Pool.QueryRow(context.Background(),
		`SELECT reward_value FROM welcome_rewards WHERE code = 'chips'`).Scan(&chips); err != nil || chips != 999 {
		t.Fatalf("outside production the row is WELCOME_CHIPS: %d %v", chips, err)
	}

	unsetCfg := testConfig(t, publicDir(t))
	unsetCfg.Env = config.EnvProduction
	unsetCfg.Game.WelcomeChips = 500000 // the default, as it were: not set in the environment
	_, unsetLogs := bootLogged(t, unsetCfg, database)
	if strings.Contains(unsetLogs.String(), "differs from the welcome_rewards chips") ||
		strings.Contains(unsetLogs.String(), "welcome chips row set") {
		t.Fatalf("a production boot with WELCOME_CHIPS unset: %s", unsetLogs.String())
	}
	if err := database.Pool.QueryRow(context.Background(),
		`SELECT reward_value FROM welcome_rewards WHERE code = 'chips'`).Scan(&chips); err != nil || chips != 999 {
		t.Fatalf("production left the row alone: %d %v", chips, err)
	}
}

func sortedKeys(m map[string]json.RawMessage) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
