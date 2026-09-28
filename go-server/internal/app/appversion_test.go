package app

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/appversion"
	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket/testclient"
)

// The app version gate on the real wiring (owner, 28 Sep 2026): the rows in
// PostgreSQL, the public GET /api/app-config, every signed-in REST route and
// the socket handshake. The cache is off (APP_VERSION_CACHE_MS=0) so an
// UPDATE here is enforced on the very next request, as it is within 15 s in
// production.
func newGatedApp(t *testing.T, required bool) (*App, *db.DB, *httptest.Server) {
	t.Helper()
	a, database := newApp(t, func(c *config.Config) {
		c.AppVersion.CacheTTL = 0
		c.AppVersion.Required = required
	})
	ts := httptest.NewServer(a.Handler())
	t.Cleanup(ts.Close)
	return a, database, ts
}

func setVersions(t *testing.T, database *db.DB, platform, minimum, latest string) {
	t.Helper()
	if _, err := database.Pool.Exec(context.Background(),
		`UPDATE app_versions SET minimum_version = $2, latest_version = $3 WHERE platform = $1`, platform, minimum, latest); err != nil {
		t.Fatal(err)
	}
}

func setMaintenance(t *testing.T, database *db.DB, on bool, message *string) {
	t.Helper()
	status := "NORMAL"
	if on {
		status = "MAINTENANCE"
	}
	if _, err := database.Pool.Exec(context.Background(), `UPDATE app_versions SET status = $1, message = $2`, status, message); err != nil {
		t.Fatal(err)
	}
}

func declared(platform, version string) func(*http.Request) {
	return func(r *http.Request) {
		if platform != "" {
			r.Header.Set(appversion.HeaderPlatform, platform)
		}
		if version != "" {
			r.Header.Set(appversion.HeaderVersion, version)
		}
	}
}

func both(fs ...func(*http.Request)) func(*http.Request) {
	return func(r *http.Request) {
		for _, f := range fs {
			f(r)
		}
	}
}

func bearer(token string) func(*http.Request) {
	return func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+token) }
}

func appConfig(t *testing.T, a *App, target string, mutate func(*http.Request)) appversion.AppConfigResponse {
	t.Helper()
	res, body := get(t, a.Handler(), http.MethodGet, target, mutate)
	if res.StatusCode != http.StatusOK || res.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("GET %s: %d %q %s", target, res.StatusCode, res.Header.Get("Cache-Control"), body)
	}
	var out appversion.AppConfigResponse
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatalf("GET %s: %v %s", target, err, body)
	}
	return out
}

type refusalBody struct {
	Error          string  `json:"error"`
	Message        string  `json:"message"`
	StoreURL       *string `json:"storeUrl"`
	MinimumVersion *string `json:"minimumVersion"`
}

func refusalOf(t *testing.T, body []byte) refusalBody {
	t.Helper()
	var out refusalBody
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatalf("%v: %s", err, body)
	}
	return out
}

// GET /api/app-config: public — no token — and never gated itself. Each
// platform is judged by its own row; the brief's NORMAL, SOFT_UPDATE,
// FORCE_UPDATE and MAINTENANCE, and a missing or broken version handled
// without a crash.
func TestTheAppConfigAnswersEachPlatformItsOwnState(t *testing.T) {
	a, database, _ := newGatedApp(t, false)
	const play = "https://play.google.com/store/apps/details?id=com.sungamestudio.kingteenpatti"

	// The seed: no floor anywhere, nothing announced.
	if got := appConfig(t, a, "/api/app-config", declared("android", "1.0.0")); got.Status != appversion.StatusNormal ||
		got.MinimumVersion != "0.0.0" || got.StoreURL != play || got.Android.StoreURL != play || got.IOS.MinimumVersion != "0.0.0" {
		t.Fatalf("on the seed: %+v", got)
	}

	// The brief's example: independent rows.
	setVersions(t, database, "android", "1.5.0", "1.6.2")
	setVersions(t, database, "ios", "1.4.0", "1.5.0")
	for _, c := range []struct {
		platform, version, want string
	}{
		{"android", "1.6.2", appversion.StatusNormal},      // 1
		{"ios", "1.5.0", appversion.StatusNormal},          // 2
		{"android", "1.4.2", appversion.StatusForceUpdate}, // 3
		{"ios", "1.3.0", appversion.StatusForceUpdate},     // 4
		{"android", "1.5.0", appversion.StatusSoftUpdate},  // 5
		{"ios", "1.4.2", appversion.StatusSoftUpdate},      // 6
		{"android", "1.10.0", appversion.StatusNormal},     // numbers, not text
		{"android", "", appversion.StatusForceUpdate},      // 8: a build that hides its version
		{"android", "1.6", appversion.StatusForceUpdate},   // 8: malformed
		{"", "", appversion.StatusNormal},                  // undeclared: the switch is off
		{"bot", "", appversion.StatusNormal},
	} {
		got := appConfig(t, a, "/api/app-config", declared(c.platform, c.version))
		if got.Status != c.want {
			t.Errorf("%s %q: %s, want %s", c.platform, c.version, got.Status, c.want)
		}
	}
	got := appConfig(t, a, "/api/app-config", declared("ios", "1.3.0"))
	if got.Platform != "ios" || got.Version == nil || *got.Version != "1.3.0" || got.MinimumVersion != "1.4.0" || got.LatestVersion != "1.5.0" ||
		got.StoreURL != "" || got.Android.MinimumVersion != "1.5.0" || got.IOS.MinimumVersion != "1.4.0" {
		t.Errorf("an old iOS build is shown its own row: %+v", got)
	}
	// An operator's curl: the query stands in for the headers, which win.
	if got := appConfig(t, a, "/api/app-config?platform=android&version=1.4.2", nil); got.Status != appversion.StatusForceUpdate || got.StoreURL != play {
		t.Errorf("by query: %+v", got)
	}
	if got := appConfig(t, a, "/api/app-config?platform=android&version=1.4.2", declared("android", "1.6.2")); got.Status != appversion.StatusNormal {
		t.Errorf("headers over the query: %+v", got)
	}

	// 7: maintenance, with its message; and never a force update.
	msg := "Back at 14:00 IST"
	setMaintenance(t, database, true, &msg)
	for _, c := range [][2]string{{"android", "1.4.2"}, {"android", "1.6.2"}, {"ios", "1.5.0"}, {"", ""}} {
		got := appConfig(t, a, "/api/app-config", declared(c[0], c[1]))
		if got.Status != appversion.StatusMaintenance || got.Message == nil || *got.Message != msg {
			t.Errorf("%v in maintenance: %+v", c, got)
		}
	}
	if got := appConfig(t, a, "/api/app-config", declared("tool", "")); got.Status != appversion.StatusNormal {
		t.Errorf("a tool in maintenance: %s", got.Status)
	}
	setMaintenance(t, database, false, nil)
	if got := appConfig(t, a, "/api/app-config", declared("android", "1.6.2")); got.Status != appversion.StatusNormal || got.Message != nil {
		t.Errorf("out of maintenance: %+v", got)
	}

	// Counted by platform and state, never by version.
	res, body := get(t, a.Handler(), http.MethodGet, "/metrics", func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+metricsToken) })
	if res.StatusCode != http.StatusOK || !containsAll(string(body),
		`game_app_version_checks_total{platform="android",service="king-teenpatti",status="force_update"}`,
		`game_app_version_checks_total{platform="ios",service="king-teenpatti",status="soft_update"}`,
		`game_app_version_checks_total{platform="none",service="king-teenpatti",status="maintenance"}`) {
		t.Errorf("the check counters: %d\n%s", res.StatusCode, grepLines(string(body), "game_app_version"))
	}
}

// 9: every signed-in REST route refuses an app too old to play — 426 in the
// server's {error, message} shape with the store link and the minimum — and a
// platform in maintenance with 503; the version gate runs before the token,
// so an old build with an expired token is told to update. The login, the
// app config, /health and the public catalogues are never gated.
func TestSignedInRESTRefusesAnUnsupportedVersion(t *testing.T) {
	a, database, ts := newGatedApp(t, false)
	token, _ := login(t, ts.URL, "appver-rest-device-01", "Old Phone")
	setVersions(t, database, "android", "1.5.0", "1.6.2")

	h := a.Handler()
	res, body := get(t, h, http.MethodGet, "/api/auth/me", both(bearer(token), declared("android", "1.4.2")))
	r := refusalOf(t, body)
	if res.StatusCode != http.StatusUpgradeRequired || r.Error != auth.CodeUpdateRequired || r.Message != appversion.MsgUpdateRequired ||
		r.StoreURL == nil || *r.StoreURL != "https://play.google.com/store/apps/details?id=com.sungamestudio.kingteenpatti" ||
		r.MinimumVersion == nil || *r.MinimumVersion != "1.5.0" || res.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("an old android at /api/auth/me: %d %q %s", res.StatusCode, res.Header.Get("Cache-Control"), body)
	}
	// Before the token: no token, a bad one, an old build — update_required.
	for _, mutate := range []func(*http.Request){declared("android", "1.0.0"), both(bearer("not-a-token"), declared("android", "1.0.0"))} {
		if res, body := get(t, h, http.MethodGet, "/api/auth/me", mutate); res.StatusCode != http.StatusUpgradeRequired {
			t.Errorf("an old build without a good token: %d %s", res.StatusCode, body)
		}
	}
	// Every signed-in door, wallet ones included.
	for _, door := range []struct{ method, path string }{
		{http.MethodPost, "/api/rewards/daily"}, {http.MethodPost, "/api/profile/name"},
		{http.MethodGet, "/api/lucky-draw"}, {http.MethodGet, "/api/friends"}, {http.MethodGet, "/api/rooms"},
		{http.MethodDelete, "/api/account"},
	} {
		if res, body := get(t, h, door.method, door.path, both(bearer(token), declared("android", "1.4.2"))); res.StatusCode != http.StatusUpgradeRequired {
			t.Errorf("%s %s for an old build: %d %s", door.method, door.path, res.StatusCode, body)
		}
	}
	// A supported build, a newer one (soft update: never refused), the tools
	// and — with the switch off — a client that declares nothing: through.
	for _, mutate := range []func(*http.Request){
		declared("android", "1.5.0"), declared("android", "1.6.2"), declared("ios", "0.0.1"),
		declared("bot", ""), declared("", ""), declared("windows", "1.0.0"),
	} {
		if res, body := get(t, h, http.MethodGet, "/api/auth/me", both(bearer(token), mutate)); res.StatusCode != http.StatusOK {
			t.Errorf("/api/auth/me: %d %s", res.StatusCode, body)
		}
	}
	// The login is never gated: an old app can learn it must update.
	if status, body := loginRaw(t, ts.URL, "appver-rest-device-02"); status != http.StatusOK {
		t.Errorf("a login: %d %s", status, body)
	}
	// Never gated: the app config, /health, the public catalogues.
	for _, path := range []string{"/api/app-config", "/health", "/api/tables", "/api/profiles", "/api/levels", "/api/emojis", "/api/table-pictures"} {
		if res, body := get(t, h, http.MethodGet, path, declared("android", "1.0.0")); res.StatusCode != http.StatusOK {
			t.Errorf("GET %s for an old build: %d %s", path, res.StatusCode, body)
		}
	}

	// Maintenance: 503, the row's message, for every app build whatever its
	// version and for a client that declares nothing — never for the tools.
	msg := "Back at 14:00 IST"
	setMaintenance(t, database, true, &msg)
	for _, mutate := range []func(*http.Request){declared("android", "1.6.2"), declared("android", "1.0.0"), declared("ios", "1.5.0"), declared("", "")} {
		res, body := get(t, h, http.MethodGet, "/api/auth/me", both(bearer(token), mutate))
		r := refusalOf(t, body)
		if res.StatusCode != http.StatusServiceUnavailable || r.Error != auth.CodeMaintenance || r.Message != msg || r.StoreURL != nil || r.MinimumVersion != nil {
			t.Errorf("/api/auth/me in maintenance: %d %s", res.StatusCode, body)
		}
	}
	if res, body := get(t, h, http.MethodGet, "/api/auth/me", both(bearer(token), declared("tool", ""))); res.StatusCode != http.StatusOK {
		t.Errorf("a tool in maintenance: %d %s", res.StatusCode, body)
	}
	setMaintenance(t, database, false, nil)
	res, body = get(t, h, http.MethodGet, "/api/auth/me", both(bearer(token), declared("", "")))
	if res.StatusCode != http.StatusOK {
		t.Errorf("out of maintenance: %d %s", res.StatusCode, body)
	}
	mres, mbody := get(t, h, http.MethodGet, "/metrics", func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+metricsToken) })
	if mres.StatusCode != http.StatusOK || !containsAll(string(mbody),
		`game_app_version_rejections_total{platform="android",service="king-teenpatti",status="force_update",via="rest"}`,
		`game_app_version_rejections_total{platform="none",service="king-teenpatti",status="maintenance",via="rest"}`) {
		t.Errorf("the rejection counters:\n%s", grepLines(string(mbody), "game_app_version"))
	}
}

// §15, the operational change: Android's minimum raised from 1.5.0 to 1.6.0 on
// a running server. 1.5.0 goes from NORMAL to FORCE_UPDATE, 1.6.0 stays
// NORMAL — no restart, no app release.
func TestRaisingTheMinimumTakesEffectWithoutARestart(t *testing.T) {
	a, database, ts := newGatedApp(t, false)
	token, _ := login(t, ts.URL, "appver-raise-device-01", "Raiser")
	setVersions(t, database, "android", "1.5.0", "0.0.0")
	h := a.Handler()
	me := func(version string) int {
		res, _ := get(t, h, http.MethodGet, "/api/auth/me", both(bearer(token), declared("android", version)))
		return res.StatusCode
	}
	if me("1.5.0") != http.StatusOK || me("1.6.0") != http.StatusOK {
		t.Fatal("before the change")
	}
	setVersions(t, database, "android", "1.6.0", "0.0.0")
	if got := me("1.5.0"); got != http.StatusUpgradeRequired {
		t.Errorf("android 1.5.0 after the minimum rose to 1.6.0: %d", got)
	}
	if got := me("1.6.0"); got != http.StatusOK {
		t.Errorf("android 1.6.0: %d", got)
	}
	if got := appConfig(t, a, "/api/app-config", declared("android", "1.5.0")); got.Status != appversion.StatusForceUpdate {
		t.Errorf("the app config for 1.5.0: %s", got.Status)
	}
}

// The undeclared switch (APP_VERSION_REQUIRED): on, every client that names no
// app platform is refused update_required at REST and at the handshake — the
// installs that predate the gate — while the tools that declare bot, tool or
// web play on.
func TestTheUndeclaredSwitchRefusesOnlyUndeclaredClients(t *testing.T) {
	a, database, ts := newGatedApp(t, true)
	token, _ := login(t, ts.URL, "appver-switch-device-01", "Switch")
	setVersions(t, database, "android", "1.6.0", "0.0.0")
	h := a.Handler()
	if res, body := get(t, h, http.MethodGet, "/api/auth/me", bearer(token)); res.StatusCode != http.StatusUpgradeRequired ||
		refusalOf(t, body).Error != auth.CodeUpdateRequired || *refusalOf(t, body).MinimumVersion != "1.6.0" {
		t.Errorf("an undeclared client with the switch on: %d %s", res.StatusCode, body)
	}
	for _, p := range []string{"bot", "tool", "web"} {
		if res, body := get(t, h, http.MethodGet, "/api/auth/me", both(bearer(token), declared(p, ""))); res.StatusCode != http.StatusOK {
			t.Errorf("%s with the switch on: %d %s", p, res.StatusCode, body)
		}
	}
	if res, _ := get(t, h, http.MethodGet, "/api/auth/me", both(bearer(token), declared("android", "1.6.0"))); res.StatusCode != http.StatusOK {
		t.Errorf("a declaring build at the minimum: %d", res.StatusCode)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var ce *testclient.ConnectError
	c, err := testclient.Dial(ctx, ts.URL, token)
	if err == nil {
		t.Error("an undeclared socket connected with the switch on")
	} else if !errors.As(err, &ce) || ce.Message != auth.CodeUpdateRequired {
		t.Errorf("an undeclared handshake: %v", err)
	}
	closeClient(c)
	for _, p := range []string{"bot", "tool", "web"} {
		c := dialAs(t, ts.URL, token, p, "")
		c.Close()
	}
}

func closeClient(c *testclient.Client) {
	if c != nil {
		c.Close()
	}
}

// containsAll reports whether text holds every one of subs.
func containsAll(text string, subs ...string) bool {
	for _, s := range subs {
		if !strings.Contains(text, s) {
			return false
		}
	}
	return true
}

func dialAuth(ctx context.Context, baseURL, token, platform, version string) (*testclient.Client, error) {
	auth := map[string]string{"token": token}
	if platform != "" {
		auth[appversion.AuthPlatform] = platform
	}
	if version != "" {
		auth[appversion.AuthVersion] = version
	}
	raw, _ := json.Marshal(auth)
	return testclient.DialAuth(ctx, baseURL, raw)
}

func dialAs(t *testing.T, baseURL, token, platform, version string) *testclient.Client {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, err := dialAuth(ctx, baseURL, token, platform, version)
	if err != nil {
		t.Fatalf("dial as %s %s: %v", platform, version, err)
	}
	t.Cleanup(c.Close)
	if _, err := c.Wait(socket.EvSessionReady, nil, 4*time.Second); err != nil {
		t.Fatalf("no session:ready as %s %s: %v", platform, version, err)
	}
	return c
}

// 10: the handshake refuses an app too old to play with a CONNECT_ERROR whose
// message is update_required and whose data says where to update — before the
// token is read — and a platform in maintenance with maintenance. A supported
// build connects, and session:ready's minClientBuild holds every install that
// predates the gate to the same minimum. A connected socket is not dropped when
// the rows change: the gate is at the door.
func TestTheHandshakeRefusesAnUnsupportedVersion(t *testing.T) {
	a, database, ts := newGatedApp(t, false)
	token, userID := login(t, ts.URL, "appver-socket-device-01", "Socket")
	playing := dialAs(t, ts.URL, token, "android", "1.5.0")
	setVersions(t, database, "android", "1.6.0", "1.7.0")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, err := dialAuth(ctx, ts.URL, token, "android", "1.5.0")
	var ce *testclient.ConnectError
	if err == nil || !errors.As(err, &ce) || ce.Message != auth.CodeUpdateRequired {
		t.Fatalf("an old android handshake: %v", err)
	}
	closeClient(c)
	var data appversion.Refusal
	if err := json.Unmarshal(ce.Data, &data); err != nil || data.Message != appversion.MsgUpdateRequired || data.MinimumVersion != "1.6.0" ||
		data.StoreURL != "https://play.google.com/store/apps/details?id=com.sungamestudio.kingteenpatti" {
		t.Errorf("the refusal's data: %s %v", ce.Data, err)
	}
	// Before the token: an old build with no token at all is told to update,
	// not that its token is missing.
	setVersions(t, database, "ios", "1.4.0", "0.0.0")
	c, err = dialAuth(ctx, ts.URL, "", "ios", "0.0.1")
	if err == nil || !errors.As(err, &ce) || ce.Message != auth.CodeUpdateRequired {
		t.Errorf("an old iOS build with no token: %v, want update_required", err)
	}
	closeClient(c)
	setVersions(t, database, "ios", "0.0.0", "0.0.0")

	// The socket that was playing before the minimum rose plays on.
	if !playing.Connected() {
		t.Error("an UPDATE of the rows dropped a live socket")
	}
	if a.Rooms() == nil || userID == "" {
		t.Fatal("no rooms")
	}

	// A supported build connects; its build floor and an undeclared
	// install's are what the minimum translates to (1.6.0 → 14: every
	// release that predates the gate), a bot's the env floor alone.
	playing.Close()
	for _, c := range []struct {
		platform, version string
		want              int
	}{
		{"android", "1.6.0", 14}, {"", "", 14}, {"bot", "", 0}, {"ios", "1.0.0", 0},
	} {
		client := dialAs(t, ts.URL, token, c.platform, c.version)
		ready, _ := client.Wait(socket.EvSessionReady, nil, 4*time.Second)
		var out struct {
			Config struct {
				MinClientBuild int `json:"minClientBuild"`
			} `json:"config"`
		}
		if err := json.Unmarshal(ready, &out); err != nil || out.Config.MinClientBuild != c.want {
			t.Errorf("%s %q: minClientBuild %d (%v), want %d", c.platform, c.version, out.Config.MinClientBuild, err, c.want)
		}
		client.Close()
	}

	// Maintenance at the handshake: the row's message, no store link.
	msg := "Back at 14:00 IST"
	setMaintenance(t, database, true, &msg)
	for _, who := range [][2]string{{"android", "1.7.0"}, {"", ""}} {
		c, err := dialAuth(ctx, ts.URL, token, who[0], who[1])
		if err == nil || !errors.As(err, &ce) || ce.Message != auth.CodeMaintenance {
			t.Errorf("%v in maintenance: %v", who, err)
		} else if data = (appversion.Refusal{}); json.Unmarshal(ce.Data, &data) != nil || data.Message != msg || data.StoreURL != "" {
			t.Errorf("the maintenance data: %s", ce.Data)
		}
		closeClient(c)
	}
	dialAs(t, ts.URL, token, "bot", "").Close()
	setMaintenance(t, database, false, nil)
	dialAs(t, ts.URL, token, "android", "1.6.5").Close()

	res, body := get(t, a.Handler(), http.MethodGet, "/metrics", func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+metricsToken) })
	if res.StatusCode != http.StatusOK || !containsAll(string(body),
		`game_app_version_rejections_total{platform="android",service="king-teenpatti",status="force_update",via="socket"}`,
		`game_app_version_rejections_total{platform="none",service="king-teenpatti",status="maintenance",via="socket"}`) {
		t.Errorf("the socket rejection counters:\n%s", grepLines(string(body), "game_app_version"))
	}
}
