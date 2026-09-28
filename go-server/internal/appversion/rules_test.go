package appversion

import (
	"encoding/json"
	"net/http/httptest"
	"testing"
)

// The brief's example (§16): Android and iOS configured independently.
func briefConfig() Config {
	return Config{Platforms: map[string]PlatformConfig{
		PlatformAndroid: {
			Status: StatusNormal, MinimumVersion: MustParse("1.5.0"), LatestVersion: MustParse("1.6.0"),
			StoreURL: "https://play.google.com/store/apps/details?id=com.sungamestudio.kingteenpatti",
		},
		PlatformIOS: {
			Status: StatusNormal, MinimumVersion: MustParse("1.4.0"), LatestVersion: MustParse("1.5.0"),
			StoreURL: "https://apps.apple.com/app/id1234567890",
		},
	}}
}

func TestEvaluateJudgesEachPlatformByItsOwnRow(t *testing.T) {
	cfg := briefConfig()
	cases := []struct {
		name              string
		platform, version string
		want              string
		row               string
	}{
		// 1, 2: a supported version.
		{"supported android", "android", "1.6.0", StatusNormal, "android"},
		{"supported ios", "ios", "1.5.0", StatusNormal, "ios"},
		{"newer than latest", "android", "1.7.3", StatusNormal, "android"},
		// 3, 4: below the platform's minimum.
		{"old android", "android", "1.4.2", StatusForceUpdate, "android"},
		{"old ios", "ios", "1.3.9", StatusForceUpdate, "ios"},
		// 1.4.2 is fine on iOS, whose minimum is 1.4.0 — the rows are independent.
		{"ios at a version android refuses", "ios", "1.4.2", StatusSoftUpdate, "ios"},
		// 5, 6: supported, but a newer version is announced.
		{"android at the minimum", "android", "1.5.0", StatusSoftUpdate, "android"},
		{"android between", "android", "1.5.9", StatusSoftUpdate, "android"},
		{"ios at the minimum", "ios", "1.4.0", StatusSoftUpdate, "ios"},
		// Numbers, not text.
		{"1.10.0 is above 1.6.0", "android", "1.10.0", StatusNormal, "android"},
		// A build suffix is ignored.
		{"android 1.5.0+13", "android", "1.5.0+13", StatusSoftUpdate, "android"},
		// The platform is read case-insensitively and trimmed.
		{"Android in capitals", " Android ", "1.4.2", StatusForceUpdate, "android"},
		// 8: a missing or malformed version from an app build, with a floor set.
		{"android, no version", "android", "", StatusForceUpdate, "android"},
		{"android, malformed", "android", "1.6", StatusForceUpdate, "android"},
		{"ios, malformed", "ios", "latest", StatusForceUpdate, "ios"},
		// Undeclared: allowed while APP_VERSION_REQUIRED is off (below for on).
		{"nothing declared", "", "", StatusNormal, "android"},
		{"a version with no platform", "", "1.0.0", StatusNormal, "android"},
		{"an unknown platform", "windows", "1.0.0", StatusNormal, "android"},
		// This project's own clients are never gated.
		{"bot", "bot", "", StatusNormal, ""},
		{"tool", "tool", "0.0.1", StatusNormal, ""},
		{"web", "web", "", StatusNormal, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			v := Evaluate(cfg, NewClient(c.platform, c.version), false)
			if v.Status != c.want || v.Platform != c.row {
				t.Errorf("%s/%q: %s against %q, want %s against %q", c.platform, c.version, v.Status, v.Platform, c.want, c.row)
			}
			if v.Status == StatusForceUpdate && v.StoreURL != cfg.For(c.row).StoreURL {
				t.Errorf("a force update names %q, want the row's store %q", v.StoreURL, cfg.For(c.row).StoreURL)
			}
		})
	}
}

// 8: with no minimum set, a missing or broken version harms nobody.
func TestAMissingOrMalformedVersionIsAllowedWhileThereIsNoFloor(t *testing.T) {
	cfg := Config{} // no rows: open, no floor, nothing announced
	for _, version := range []string{"", "1.6", "garbage", "v1.2.3", "1.5.0"} {
		if v := Evaluate(cfg, NewClient("android", version), false); v.Status != StatusNormal {
			t.Errorf("android %q with no floor: %s", version, v.Status)
		}
	}
	// A latest with no minimum announces, and never blocks.
	cfg = Config{Platforms: map[string]PlatformConfig{PlatformAndroid: {Status: StatusNormal, LatestVersion: MustParse("2.0.0")}}}
	if v := Evaluate(cfg, NewClient("android", "1.0.0"), false); v.Status != StatusSoftUpdate {
		t.Errorf("below latest, no minimum: %s", v.Status)
	}
	if v := Evaluate(cfg, NewClient("android", "junk"), false); v.Status != StatusNormal {
		t.Errorf("malformed, no minimum: %s", v.Status)
	}
}

// 7: maintenance is maintenance, whatever the version, and never a force
// update; it outranks one.
func TestMaintenanceHoldsEveryAppClientButTheProjectsOwnTools(t *testing.T) {
	cfg := briefConfig()
	android := cfg.Platforms[PlatformAndroid]
	android.Status = StatusMaintenance
	android.Message = "Back at 14:00 IST"
	cfg.Platforms[PlatformAndroid] = android

	for _, version := range []string{"1.6.0", "1.4.2", ""} {
		v := Evaluate(cfg, NewClient("android", version), false)
		if v.Status != StatusMaintenance || v.Message != "Back at 14:00 IST" {
			t.Errorf("android %q in maintenance: %s %q", version, v.Status, v.Message)
		}
	}
	// Undeclared clients are android installs: held too.
	if v := Evaluate(cfg, NewClient("", ""), false); v.Status != StatusMaintenance {
		t.Errorf("undeclared in android's maintenance: %s", v.Status)
	}
	// iOS has its own row, still open.
	if v := Evaluate(cfg, NewClient("ios", "1.5.0"), false); v.Status != StatusNormal {
		t.Errorf("ios while android is in maintenance: %s", v.Status)
	}
	// The project's own clients play on.
	for _, p := range []string{"bot", "tool", "web"} {
		if v := Evaluate(cfg, NewClient(p, ""), true); v.Status != StatusNormal {
			t.Errorf("%s in maintenance: %s", p, v.Status)
		}
	}
	refusal := RefusalOf(Evaluate(cfg, NewClient("android", "1.4.2"), false))
	if refusal.Code != CodeMaintenance || refusal.Message != "Back at 14:00 IST" || refusal.StoreURL != "" || refusal.MinimumVersion != "" {
		t.Errorf("the maintenance refusal: %+v", refusal)
	}
}

// The undeclared switch (APP_VERSION_REQUIRED): off, nothing that declares
// nothing is refused; on, every such client is — and still no bot or tool.
func TestTheUndeclaredSwitchRefusesOnlyClientsThatDeclareNoAppPlatform(t *testing.T) {
	cfg := briefConfig()
	for _, c := range []Client{NewClient("", ""), NewClient("", "9.9.9"), NewClient("windows", "9.9.9")} {
		if v := Evaluate(cfg, c, true); v.Status != StatusForceUpdate || v.Platform != PlatformAndroid {
			t.Errorf("%+v with the switch on: %s against %q", c, v.Status, v.Platform)
		} else if r := RefusalOf(v); r.Code != CodeUpdateRequired || r.StoreURL != cfg.Platforms[PlatformAndroid].StoreURL || r.MinimumVersion != "1.5.0" {
			t.Errorf("the refusal an undeclared client gets: %+v", r)
		}
	}
	for _, c := range []Client{NewClient("bot", ""), NewClient("tool", ""), NewClient("web", ""), NewClient("android", "1.6.0")} {
		if v := Evaluate(cfg, c, true); v.Blocks() {
			t.Errorf("%+v with the switch on: %s", c, v.Status)
		}
	}
}

func TestTheRefusalCarriesTheRowsMessageOrTheServersWords(t *testing.T) {
	cfg := briefConfig()
	r := RefusalOf(Evaluate(cfg, NewClient("android", "1.0.0"), false))
	if r.Code != CodeUpdateRequired || r.Message != MsgUpdateRequired || r.MinimumVersion != "1.5.0" ||
		r.StoreURL != "https://play.google.com/store/apps/details?id=com.sungamestudio.kingteenpatti" {
		t.Errorf("update refusal: %+v", r)
	}
	ios := cfg.Platforms[PlatformIOS]
	ios.Message = "Please update from the App Store."
	ios.StoreURL = ""
	cfg.Platforms[PlatformIOS] = ios
	r = RefusalOf(Evaluate(cfg, NewClient("ios", "1.0.0"), false))
	if r.Message != "Please update from the App Store." || r.StoreURL != "" {
		t.Errorf("ios refusal with a message and no store: %+v", r)
	}
	body, _ := json.Marshal(r)
	if string(body) != `{"message":"Please update from the App Store.","minimumVersion":"1.4.0"}` {
		t.Errorf("the refusal's data on the wire: %s", body)
	}
	r = RefusalOf(Verdict{Status: StatusMaintenance})
	if r.Code != CodeMaintenance || r.Message != MsgMaintenance {
		t.Errorf("maintenance with no message: %+v", r)
	}
}

// The installs that predate the gate read only config.minClientBuild, so a
// minimum version is translated into the build number that holds them to it.
func TestTheLegacyBuildFloorFollowsTheMinimumVersion(t *testing.T) {
	cases := map[string]int{
		"0.0.0":  0,  // no floor
		"0.0.1":  1,  // every release is at least 1.0.0+1
		"1.0.0":  1,  // nobody held
		"1.1.1":  5,  // 1.1.0+4 held
		"1.2.1":  8,  // …up to 1.2.0+7
		"1.2.5":  11, // the first release at or above 1.2.5 is 1.3.0+11
		"1.4.0":  12, // 1.3.0+11 held, 1.4.0+12 and 1.5.0+13 through
		"1.5.0":  13, // only 1.5.0+13 through
		"1.5.1":  14, // every legacy install held
		"1.6.0":  14,
		"1.10.0": 14,
		"9.0.0":  14,
	}
	for min, want := range cases {
		if got := LegacyMinClientBuild(MustParse(min)); got != want {
			t.Errorf("LegacyMinClientBuild(%s) = %d, want %d", min, got, want)
		}
	}
	// The table is ordered and closed at 1.5.0+13.
	for i := 1; i < len(legacyReleases); i++ {
		if !legacyReleases[i-1].version.Less(legacyReleases[i].version) || legacyReleases[i-1].firstBuild >= legacyReleases[i].firstBuild {
			t.Errorf("legacyReleases out of order at %d", i)
		}
	}
	if last := legacyReleases[len(legacyReleases)-1]; last.firstBuild != LastLegacyBuild || last.version != MustParse("1.5.0") {
		t.Errorf("the last legacy release is %v+%d", last.version, last.firstBuild)
	}
}

func TestMinClientBuildIsTheLargerOfTheEnvFloorAndTheDerivedOne(t *testing.T) {
	cfg := briefConfig() // android minimum 1.5.0 → 13; ios 1.4.0 → 12
	cases := []struct {
		client   Client
		envFloor int
		want     int
	}{
		{NewClient("", ""), 0, 13},             // an undeclared install: android's
		{NewClient("android", "1.6.0"), 0, 13}, // a declaring build: its own row
		{NewClient("ios", "1.5.0"), 0, 12},
		{NewClient("ios", "1.5.0"), 20, 20}, // MIN_CLIENT_BUILD above wins
		{NewClient("bot", ""), 0, 0},        // the tools: the env floor alone
		{NewClient("tool", ""), 7, 7},
		{NewClient("windows", ""), 0, 13},
	}
	for _, c := range cases {
		if got := cfg.MinClientBuild(c.client, c.envFloor); got != c.want {
			t.Errorf("MinClientBuild(%+v, %d) = %d, want %d", c.client, c.envFloor, got, c.want)
		}
	}
	if got := (Config{}).MinClientBuild(NewClient("", ""), 0); got != 0 {
		t.Errorf("no floor anywhere: %d", got)
	}
}

func TestAClientIsReadFromHeadersOrTheHandshakeAuthAndClipped(t *testing.T) {
	r := httptest.NewRequest("GET", "/api/auth/me", nil)
	r.Header.Set(HeaderPlatform, "  iOS ")
	r.Header.Set(HeaderVersion, " 1.6.0 ")
	if c := ClientFromRequest(r); c != (Client{Platform: "ios", Version: "1.6.0"}) {
		t.Errorf("from headers: %+v", c)
	}
	var auth map[string]json.RawMessage
	_ = json.Unmarshal([]byte(`{"token":"t","appPlatform":"android","appVersion":"1.5.0"}`), &auth)
	if c := ClientFromAuth(auth); c != (Client{Platform: "android", Version: "1.5.0"}) {
		t.Errorf("from auth: %+v", c)
	}
	_ = json.Unmarshal([]byte(`{"appPlatform":7,"appVersion":["1.5.0"]}`), &auth)
	if c := ClientFromAuth(auth); c != (Client{}) {
		t.Errorf("non-strings read as undeclared: %+v", c)
	}
	if c := ClientFromAuth(nil); c != (Client{}) {
		t.Errorf("no auth: %+v", c)
	}
	long := NewClient("android", "1.5.0+"+string(make([]byte, 100)))
	if len(long.Version) != 32 {
		t.Errorf("a long version is kept at %d bytes", len(long.Version))
	}
	for platform, label := range map[string]string{"android": "android", "ios": "ios", "bot": "bot", "tool": "tool", "web": "web", "": "none", "windows": "other", "Android": "android"} {
		if got := NewClient(platform, "").Label(); got != label {
			t.Errorf("Label(%q) = %q, want %q", platform, got, label)
		}
	}
}

func TestTheAppConfigResponseReportsTheCallerAndBothRows(t *testing.T) {
	cfg := briefConfig()
	c := NewClient("android", "1.4.2+12")
	body, _ := json.Marshal(Response(cfg, c, Evaluate(cfg, c, false)))
	want := `{"status":"FORCE_UPDATE","platform":"android","version":"1.4.2","minimumVersion":"1.5.0","latestVersion":"1.6.0",` +
		`"storeUrl":"https://play.google.com/store/apps/details?id=com.sungamestudio.kingteenpatti","message":null,` +
		`"android":{"status":"NORMAL","minimumVersion":"1.5.0","latestVersion":"1.6.0","storeUrl":"https://play.google.com/store/apps/details?id=com.sungamestudio.kingteenpatti","message":null},` +
		`"ios":{"status":"NORMAL","minimumVersion":"1.4.0","latestVersion":"1.5.0","storeUrl":"https://apps.apple.com/app/id1234567890","message":null}}`
	if string(body) != want {
		t.Errorf("GET /api/app-config body:\n got %s\nwant %s", body, want)
	}
	// Nothing declared: judged against android, with no version echoed.
	body, _ = json.Marshal(Response(Config{}, Client{}, Evaluate(Config{}, Client{}, false)))
	want = `{"status":"NORMAL","platform":"","version":null,"minimumVersion":"0.0.0","latestVersion":"0.0.0","storeUrl":"","message":null,` +
		`"android":{"status":"NORMAL","minimumVersion":"0.0.0","latestVersion":"0.0.0","storeUrl":"","message":null},` +
		`"ios":{"status":"NORMAL","minimumVersion":"0.0.0","latestVersion":"0.0.0","storeUrl":"","message":null}}`
	if string(body) != want {
		t.Errorf("an empty configuration:\n got %s\nwant %s", body, want)
	}
}
