package appversion

import (
	"context"
	"log/slog"
	"sync"
	"time"
)

// Where a refusal happened, for Hooks.Rejected and the logs.
const (
	ViaREST   = "rest"
	ViaSocket = "socket"
)

// The refusal codes, in the server's {error: code, message} shape (REST) and
// as a CONNECT_ERROR's message (the socket handshake).
const (
	// CodeUpdateRequired: FORCE_UPDATE — REST 426, connect_error.
	CodeUpdateRequired = "update_required"
	// CodeMaintenance: MAINTENANCE — REST 503, connect_error.
	CodeMaintenance = "maintenance"
)

// The server's own words for a refusal whose row carries no message. The app
// shows its own translation of them unless the row's message is set.
const (
	MsgUpdateRequired = "A new version of King Teen Patti is required to continue playing."
	MsgMaintenance    = "King Teen Patti is temporarily unavailable. Please try again later."
)

// The log events (owner's brief, §19), in each line's `event` attribute.
const (
	EventCheck             = "APP_VERSION_CHECK"
	EventSoftUpdate        = "SOFT_UPDATE_DETECTED"
	EventForceRejected     = "FORCE_UPDATE_REJECTED"
	EventMaintenance       = "MAINTENANCE_REJECTED"
	EventWebSocketRejected = "WEBSOCKET_VERSION_REJECTED"
)

// Hooks are the Gate's reports to the metrics (app: metrics.Metrics). Nil
// fields are skipped. Every label value passed is from a closed set: platform
// is Client.Label, status a Status* constant, via a Via* constant.
type Hooks struct {
	// Checked is every GET /api/app-config verdict.
	Checked func(platform, status string)
	// Rejected is every refused signed-in REST request and socket handshake.
	Rejected func(platform, status, via string)
}

// logEvery is how often one kind of line — the same event, platform, version,
// state and door — is logged at most: an old app retrying keeps its metric
// counting and its log quiet.
const logEvery = time.Minute

// Gate is the version gate the signed-in REST doors (auth.Handler.RequireAuth)
// and the socket handshake (socket.Handler) ask, and GET /api/app-config
// reports. A nil *Gate admits everyone, reads the empty configuration and
// logs nothing (unit tests that wire no gate).
type Gate struct {
	source   *Source
	required bool
	envFloor int
	log      *slog.Logger
	now      func() time.Time
	hooks    Hooks

	logMu  sync.Mutex
	logged map[string]time.Time
}

// GateOptions builds a Gate.
type GateOptions struct {
	Source *Source
	// Required is APP_VERSION_REQUIRED: refuse a client that declares no app
	// platform (every install that predates the gate) with FORCE_UPDATE.
	Required bool
	// EnvMinClientBuild is MIN_CLIENT_BUILD, the build floor that predates
	// the gate; session:ready's minClientBuild is never below it.
	EnvMinClientBuild int
	Logger            *slog.Logger
	Now               func() time.Time
	Hooks             Hooks
}

// NewGate builds the Gate.
func NewGate(o GateOptions) *Gate {
	if o.Logger == nil {
		o.Logger = slog.Default()
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	return &Gate{
		source:   o.Source,
		required: o.Required,
		envFloor: o.EnvMinClientBuild,
		log:      o.Logger,
		now:      o.Now,
		hooks:    o.Hooks,
		logged:   make(map[string]time.Time),
	}
}

// Required reports APP_VERSION_REQUIRED.
func (g *Gate) Required() bool { return g != nil && g.required }

// Config is the configuration in force (cached).
func (g *Gate) Config(ctx context.Context) Config {
	if g == nil {
		return Config{}
	}
	return g.source.Current(ctx)
}

// Evaluate judges c against the configuration in force.
func (g *Gate) Evaluate(ctx context.Context, c Client) Verdict {
	if g == nil {
		return Verdict{Status: StatusNormal}
	}
	return Evaluate(g.Config(ctx), c, g.required)
}

// Check is GET /api/app-config's verdict for c, counted (Hooks.Checked) and
// logged: APP_VERSION_CHECK, or SOFT_UPDATE_DETECTED when a newer version is
// announced to it. It also answers the configuration the verdict was reached
// on, so the answer's rows are the ones that decided it.
func (g *Gate) Check(ctx context.Context, c Client) (Verdict, Config) {
	if g == nil {
		return Verdict{Status: StatusNormal}, Config{}
	}
	cfg := g.Config(ctx)
	v := Evaluate(cfg, c, g.required)
	if g.hooks.Checked != nil {
		g.hooks.Checked(c.Label(), v.Status)
	}
	event := EventCheck
	if v.Status == StatusSoftUpdate {
		event = EventSoftUpdate
	}
	g.logOnce(slog.LevelInfo, "app version check", event, c, v, "app_config")
	return v, cfg
}

// Admit decides whether c may pass a signed-in door: a REST request (via
// ViaREST, endpoint its route pattern) or a socket handshake (ViaSocket). It
// answers the verdict and false for FORCE_UPDATE and MAINTENANCE — counted
// (Hooks.Rejected) and logged: FORCE_UPDATE_REJECTED or MAINTENANCE_REJECTED
// for REST, WEBSOCKET_VERSION_REJECTED for the socket — and true for anything
// else.
func (g *Gate) Admit(ctx context.Context, c Client, via, endpoint string) (Verdict, bool) {
	if g == nil {
		return Verdict{Status: StatusNormal}, true
	}
	v := g.Evaluate(ctx, c)
	if !v.Blocks() {
		return v, true
	}
	if g.hooks.Rejected != nil {
		g.hooks.Rejected(c.Label(), v.Status, via)
	}
	event := EventForceRejected
	switch {
	case via == ViaSocket:
		event = EventWebSocketRejected
	case v.Status == StatusMaintenance:
		event = EventMaintenance
	}
	g.logOnce(slog.LevelWarn, "app version rejected", event, c, v, endpoint)
	return v, false
}

// MinClientBuild is session:ready's config.minClientBuild for c
// (Config.MinClientBuild with MIN_CLIENT_BUILD as the floor).
func (g *Gate) MinClientBuild(ctx context.Context, c Client, envFloor int) int {
	if g == nil {
		return envFloor
	}
	return g.Config(ctx).MinClientBuild(c, envFloor)
}

// logOnce writes one line per (event, platform, version, status, endpoint)
// per logEvery. Nothing about the player: the gate runs before anyone is
// signed in, and a version and a platform are all it knows.
func (g *Gate) logOnce(level slog.Level, msg, event string, c Client, v Verdict, endpoint string) {
	key := event + "|" + c.Label() + "|" + c.Version + "|" + v.Status + "|" + endpoint
	now := g.now()
	g.logMu.Lock()
	if last, ok := g.logged[key]; ok && now.Sub(last) < logEvery {
		g.logMu.Unlock()
		return
	}
	if len(g.logged) > 4096 {
		g.logged = make(map[string]time.Time)
	}
	g.logged[key] = now
	g.logMu.Unlock()
	g.log.Log(context.Background(), level, msg,
		"event", event,
		"platform", c.Label(),
		"appVersion", c.Version,
		"status", v.Status,
		"minimumVersion", v.MinimumVersion.String(),
		"latestVersion", v.LatestVersion.String(),
		"endpoint", endpoint)
}

// Refusal is what a blocked client is told beside the code: the words to show
// and, for an update, where to get it and what it must be at least. REST adds
// these to its {error, message} body; the socket handshake sends them as the
// CONNECT_ERROR's data.
type Refusal struct {
	// Code is CodeUpdateRequired or CodeMaintenance.
	Code string `json:"-"`
	// Message is the row's message, else MsgUpdateRequired / MsgMaintenance.
	Message string `json:"message"`
	// StoreURL (update only) is the row's store link; absent when it has none.
	StoreURL string `json:"storeUrl,omitempty"`
	// MinimumVersion (update only) is the version the app must reach.
	MinimumVersion string `json:"minimumVersion,omitempty"`
}

// RefusalOf is the Refusal for a blocking verdict.
func RefusalOf(v Verdict) Refusal {
	if v.Status == StatusMaintenance {
		msg := v.Message
		if msg == "" {
			msg = MsgMaintenance
		}
		return Refusal{Code: CodeMaintenance, Message: msg}
	}
	msg := v.Message
	if msg == "" {
		msg = MsgUpdateRequired
	}
	r := Refusal{Code: CodeUpdateRequired, Message: msg, StoreURL: v.StoreURL}
	if !v.MinimumVersion.IsZero() {
		r.MinimumVersion = v.MinimumVersion.String()
	}
	return r
}

// PlatformInfo is one platform's row as GET /api/app-config shows it: public
// facts, nothing an operator would not print on the store listing.
type PlatformInfo struct {
	// Status is the row's: NORMAL or MAINTENANCE.
	Status string `json:"status"`
	// MinimumVersion and LatestVersion: "0.0.0" is none.
	MinimumVersion string  `json:"minimumVersion"`
	LatestVersion  string  `json:"latestVersion"`
	StoreURL       string  `json:"storeUrl"`
	Message        *string `json:"message"`
}

// AppConfigResponse is GET /api/app-config: the caller's own state — worked
// out by the server from the X-App-Platform / X-App-Version it sent (or the
// platform and version query parameters) — with the row it was judged
// against, and every app platform's row beside it.
type AppConfigResponse struct {
	// Status is the caller's: NORMAL, SOFT_UPDATE, FORCE_UPDATE or MAINTENANCE.
	Status string `json:"status"`
	// Platform is the platform the caller declared, as understood; "" when
	// none.
	Platform string `json:"platform"`
	// Version is the caller's declared version as parsed; null when none was
	// sent or it is not MAJOR.MINOR.PATCH.
	Version *string `json:"version"`
	// MinimumVersion, LatestVersion, StoreURL and Message are those of the row
	// the caller was judged against (android's for a caller that declared no
	// app platform).
	MinimumVersion string  `json:"minimumVersion"`
	LatestVersion  string  `json:"latestVersion"`
	StoreURL       string  `json:"storeUrl"`
	Message        *string `json:"message"`
	// Android and IOS are each app platform's row.
	Android PlatformInfo `json:"android"`
	IOS     PlatformInfo `json:"ios"`
}

// Response builds GET /api/app-config's body for client c and verdict v.
func Response(cfg Config, c Client, v Verdict) AppConfigResponse {
	row := cfg.For(DefaultPlatform)
	if v.Platform != "" {
		row = cfg.For(v.Platform)
	}
	out := AppConfigResponse{
		Status:         v.Status,
		Platform:       c.Platform,
		MinimumVersion: row.MinimumVersion.String(),
		LatestVersion:  row.LatestVersion.String(),
		StoreURL:       row.StoreURL,
		Message:        optional(row.Message),
		Android:        infoOf(cfg.For(PlatformAndroid)),
		IOS:            infoOf(cfg.For(PlatformIOS)),
	}
	if parsed, ok := c.Parsed(); ok {
		s := parsed.String()
		out.Version = &s
	}
	return out
}

func infoOf(p PlatformConfig) PlatformInfo {
	status := p.Status
	if status != StatusMaintenance {
		status = StatusNormal
	}
	return PlatformInfo{
		Status:         status,
		MinimumVersion: p.MinimumVersion.String(),
		LatestVersion:  p.LatestVersion.String(),
		StoreURL:       p.StoreURL,
		Message:        optional(p.Message),
	}
}

func optional(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}
