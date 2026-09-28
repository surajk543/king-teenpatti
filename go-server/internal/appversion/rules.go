package appversion

import (
	"encoding/json"
	"net/http"
	"strings"
)

// The four states a client can be in (owner, 28 Sep 2026). FORCE_UPDATE and
// SOFT_UPDATE are never stored: they are what Evaluate works out from the
// versions. A platform's row stores NORMAL or MAINTENANCE only.
const (
	// StatusNormal: the version is supported and nothing newer is announced.
	StatusNormal = "NORMAL"
	// StatusSoftUpdate: supported, but a newer version is announced
	// (latest_version); the app offers the update and may be told Later.
	StatusSoftUpdate = "SOFT_UPDATE"
	// StatusForceUpdate: below the platform's minimum_version; the app must
	// be updated before it may play, and the server refuses it at every
	// signed-in door (update_required).
	StatusForceUpdate = "FORCE_UPDATE"
	// StatusMaintenance: the platform's row says the game is closed; nobody
	// on it may play whatever their version (maintenance).
	StatusMaintenance = "MAINTENANCE"
)

// The platforms a client may declare. android and ios are the app builds,
// judged against their own row. bot, tool and web are this project's own
// clients — the resident bot fleet (bot-play/) and tools/bot.js, the ramp
// test, the parity harness and the scratch scripts, and the dev browser client
// — which are never version-gated and never held by maintenance: they are not
// the app, and the gate exists for the app.
const (
	PlatformAndroid = "android"
	PlatformIOS     = "ios"
	PlatformBot     = "bot"
	PlatformTool    = "tool"
	PlatformWeb     = "web"
)

// DefaultPlatform is the row an UNDECLARED client is judged against: every
// install of the app that predates the gate is an Android build (the iOS app
// has never shipped), so a client that names no platform is one of those —
// or a script — and android's maintenance and store link are the ones that
// apply to it.
const DefaultPlatform = PlatformAndroid

// AppPlatforms are the platforms that have a row: the app builds.
var AppPlatforms = []string{PlatformAndroid, PlatformIOS}

// How a client declares itself: REST headers, and the socket handshake's auth
// object beside `token`.
const (
	HeaderPlatform = "X-App-Platform"
	HeaderVersion  = "X-App-Version"
	AuthPlatform   = "appPlatform"
	AuthVersion    = "appVersion"
)

// Kind is how the gate treats a declared platform.
type Kind int

const (
	// KindUndeclared: no platform, or one this server does not know. Judged
	// against DefaultPlatform's maintenance; version-gated only when
	// APP_VERSION_REQUIRED is on, and then refused (it names no version to
	// admit).
	KindUndeclared Kind = iota
	// KindApp: android or ios, judged against its own row.
	KindApp
	// KindExempt: bot, tool or web — never gated.
	KindExempt
)

// KindOf classifies a platform as Client.Platform holds it.
func KindOf(platform string) Kind {
	switch platform {
	case PlatformAndroid, PlatformIOS:
		return KindApp
	case PlatformBot, PlatformTool, PlatformWeb:
		return KindExempt
	}
	return KindUndeclared
}

// maxDeclared bounds what is kept of a declared platform or version: enough
// for anything real, and never a line's worth of a client's choosing in a log.
const maxDeclared = 32

// Client is what a request or a connection says about the app that made it.
// Platform is trimmed and lower-cased; Version is as sent, trimmed. Both are
// "" when not declared, and both are cut to 32 bytes.
type Client struct {
	Platform string
	Version  string
}

// NewClient normalises a declared platform and version.
func NewClient(platform, version string) Client {
	return Client{
		Platform: clip(strings.ToLower(strings.TrimSpace(platform))),
		Version:  clip(strings.TrimSpace(version)),
	}
}

// ClientFromRequest reads the X-App-Platform and X-App-Version headers.
func ClientFromRequest(r *http.Request) Client {
	return NewClient(r.Header.Get(HeaderPlatform), r.Header.Get(HeaderVersion))
}

// ClientFromAuth reads appPlatform and appVersion from a Socket.IO
// handshake's auth object. A value that is not a JSON string reads as not
// declared.
func ClientFromAuth(auth map[string]json.RawMessage) Client {
	text := func(key string) string {
		var s string
		if raw, ok := auth[key]; ok && json.Unmarshal(raw, &s) == nil {
			return s
		}
		return ""
	}
	return NewClient(text(AuthPlatform), text(AuthVersion))
}

func clip(s string) string {
	if len(s) > maxDeclared {
		return s[:maxDeclared]
	}
	return s
}

// Kind is KindOf(c.Platform).
func (c Client) Kind() Kind { return KindOf(c.Platform) }

// Parsed is the declared version, and whether it is one.
func (c Client) Parsed() (Version, bool) {
	if c.Version == "" {
		return Version{}, false
	}
	v, err := Parse(c.Version)
	return v, err == nil
}

// Label is the platform as a metrics label — a closed set, never the text a
// client sent: android, ios, bot, tool, web; "none" when nothing was declared
// and "other" for a platform this server does not know.
func (c Client) Label() string {
	switch {
	case c.Platform == "":
		return LabelNone
	case c.Kind() == KindUndeclared:
		return LabelOther
	}
	return c.Platform
}

// Metric label values beyond the platforms themselves.
const (
	LabelNone  = "none"
	LabelOther = "other"
)

// PlatformConfig is one platform's row (app_versions): whether it is open,
// the oldest version it lets play, the newest it announces, where to get it,
// and an optional message shown with a force update or a maintenance.
type PlatformConfig struct {
	// Status is StatusNormal or StatusMaintenance.
	Status string
	// MinimumVersion is the oldest version allowed; 0.0.0 = no floor.
	MinimumVersion Version
	// LatestVersion is the newest version announced; 0.0.0 = none. Below it
	// (and at or above the minimum) is SOFT_UPDATE.
	LatestVersion Version
	// StoreURL is where Update now goes; "" leaves the app to its own link.
	StoreURL string
	// Message is shown with a force update or a maintenance; "" = the app's
	// own words.
	Message string
}

// Config is every platform's row, keyed by platform. A platform with no row
// reads as open, with no floor and nothing announced (For).
type Config struct {
	Platforms map[string]PlatformConfig
}

// For is platform's row, or an open one with no floor when there is none.
func (c Config) For(platform string) PlatformConfig {
	if p, ok := c.Platforms[platform]; ok {
		return p
	}
	return PlatformConfig{Status: StatusNormal}
}

// Verdict is Evaluate's answer: the state and what the app needs to show it.
type Verdict struct {
	Status string
	// Platform is the row the client was judged against: its own for an app
	// build, DefaultPlatform for an undeclared client, "" for an exempt one.
	Platform string
	// MinimumVersion, LatestVersion, StoreURL and Message are that row's.
	MinimumVersion Version
	LatestVersion  Version
	StoreURL       string
	Message        string
}

// Blocks reports whether the verdict keeps the client out: FORCE_UPDATE or
// MAINTENANCE.
func (v Verdict) Blocks() bool {
	return v.Status == StatusForceUpdate || v.Status == StatusMaintenance
}

// Evaluate is the rule, the one place a client's state is decided:
//
//   - bot, tool, web: NORMAL, always — never version-gated, never held by
//     maintenance.
//   - the row the client is judged against (its own for android and ios,
//     DefaultPlatform's for anything else) says MAINTENANCE: MAINTENANCE.
//     Maintenance outranks an update: nothing works until it is over, and an
//     update would not change that.
//   - undeclared (no platform, or one this server does not know): FORCE_UPDATE
//     when `required` (APP_VERSION_REQUIRED) is on — it names no version that
//     could be admitted — else NORMAL. Off is the default, because every
//     install that predates the gate, and every script, declares nothing.
//   - android or ios, with a minimum set (above 0.0.0): FORCE_UPDATE when the
//     declared version is below it, and when there is no version or it is
//     malformed (a real build always sends its own, so a missing or broken one
//     cannot be vouched for above the floor). With no minimum, a missing or
//     malformed version is simply NORMAL.
//   - otherwise SOFT_UPDATE when the version is below the announced latest,
//     else NORMAL.
func Evaluate(cfg Config, c Client, required bool) Verdict {
	kind := c.Kind()
	if kind == KindExempt {
		return Verdict{Status: StatusNormal}
	}
	platform := DefaultPlatform
	if kind == KindApp {
		platform = c.Platform
	}
	row := cfg.For(platform)
	v := Verdict{
		Status:         StatusNormal,
		Platform:       platform,
		MinimumVersion: row.MinimumVersion,
		LatestVersion:  row.LatestVersion,
		StoreURL:       row.StoreURL,
		Message:        row.Message,
	}
	if row.Status == StatusMaintenance {
		v.Status = StatusMaintenance
		return v
	}
	if kind == KindUndeclared {
		if required {
			v.Status = StatusForceUpdate
		}
		return v
	}
	version, ok := c.Parsed()
	if !row.MinimumVersion.IsZero() && (!ok || version.Less(row.MinimumVersion)) {
		v.Status = StatusForceUpdate
		return v
	}
	if ok && version.Less(row.LatestVersion) {
		v.Status = StatusSoftUpdate
	}
	return v
}

// legacyReleases are the app's store releases that PREDATE the gate — every
// build that sends no X-App-Version, and knows nothing of update_required —
// with the first build number each version shipped as (flutter-client/
// pubspec.yaml's `version: x.y.z+build`; git: `git log -G '^version:' --
// flutter-client/pubspec.yaml`). The list is closed: every later build
// declares itself and is judged by its version, so nothing is ever added.
var legacyReleases = []struct {
	version    Version
	firstBuild int
}{
	{Version{1, 0, 0}, 1},
	{Version{1, 1, 0}, 4},
	{Version{1, 1, 1}, 5},
	{Version{1, 1, 2}, 6},
	{Version{1, 2, 0}, 7},
	{Version{1, 2, 1}, 8},
	{Version{1, 2, 2}, 9},
	{Version{1, 2, 3}, 10},
	{Version{1, 3, 0}, 11},
	{Version{1, 4, 0}, 12},
	{Version{1, 5, 0}, 13},
}

// LastLegacyBuild is the build number of the last release that predates the
// gate (1.5.0+13). The first build that declares its version is later.
const LastLegacyBuild = 13

// LegacyMinClientBuild is the build-number floor that holds the installs
// which predate the gate to the same minimum `minimum` holds a declaring build
// to. Those installs understand exactly one thing: session:ready's
// config.minClientBuild, a build number their own update screen compares
// against. So a minimum version is translated into the first build number
// that is at least that version: 0 when there is no minimum, the build a
// legacy release first shipped as when the minimum falls among them (a
// minimum of 1.4.0 → 12, holding 1.3.0+11 and older), and LastLegacyBuild+1
// when the minimum is newer than every legacy release (1.6.0 → 14, holding
// every one of them). No build that declares its version is ever below it.
func LegacyMinClientBuild(minimum Version) int {
	if minimum.IsZero() {
		return 0
	}
	for _, r := range legacyReleases {
		if !r.version.Less(minimum) {
			return r.firstBuild
		}
	}
	return LastLegacyBuild + 1
}

// MinClientBuild is session:ready's config.minClientBuild for client: the
// larger of MIN_CLIENT_BUILD (`envFloor`, the manual build floor that
// predates the gate) and LegacyMinClientBuild of the minimum_version of the
// row the client is judged against. An exempt client gets envFloor alone.
func (c Config) MinClientBuild(client Client, envFloor int) int {
	floor := envFloor
	var platform string
	switch client.Kind() {
	case KindExempt:
		return floor
	case KindApp:
		platform = client.Platform
	default:
		platform = DefaultPlatform
	}
	if derived := LegacyMinClientBuild(c.For(platform).MinimumVersion); derived > floor {
		floor = derived
	}
	return floor
}
