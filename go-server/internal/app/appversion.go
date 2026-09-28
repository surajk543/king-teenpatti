package app

import (
	"context"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/appversion"
	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/metrics"
)

// newAppGate builds the app version gate (owner, 28 Sep 2026;
// internal/appversion): the app_versions rows behind a cache of
// APP_VERSION_CACHE_MS, APP_VERSION_REQUIRED, MIN_CLIENT_BUILD as the floor
// under every connection's minClientBuild, and the two counters. The first
// read is made here, at boot, and logged — so /api/app-config and the first
// handshake never wait on it, and an operator reading the journal sees what
// the gate enforces. With no database (unit tests) the gate reads the empty
// configuration: every platform open, no floor.
func newAppGate(cfg *config.Config, database *db.DB, m *metrics.Metrics, now func() time.Time, log *slog.Logger) *appversion.Gate {
	var loader appversion.Loader
	if database != nil {
		loader = db.NewAppVersions(database)
	}
	gate := appversion.NewGate(appversion.GateOptions{
		Source:            appversion.NewSource(loader, cfg.AppVersion.CacheTTL, now, log),
		Required:          cfg.AppVersion.Required,
		EnvMinClientBuild: cfg.Game.MinClientBuild,
		Logger:            log,
		Now:               now,
		Hooks:             appversion.Hooks{Checked: m.AppVersionChecked, Rejected: m.AppVersionRejected},
	})
	current := gate.Config(context.Background())
	attrs := []any{"required", cfg.AppVersion.Required, "cacheMs", cfg.AppVersion.CacheTTL.Milliseconds()}
	for _, platform := range appversion.AppPlatforms {
		row := current.For(platform)
		attrs = append(attrs, platform, row.Status+" min "+row.MinimumVersion.String()+" latest "+row.LatestVersion.String())
	}
	log.Info("app version gate ready", attrs...)
	return gate
}

// appConfigHandler is GET /api/app-config (owner, 28 Sep 2026): the app's
// first request, made before sign-in — public, never version-gated, never
// cached. The caller declares itself with X-App-Platform and X-App-Version
// (or, for an operator's curl, ?platform= and ?version=; a header wins), and
// is answered its state — NORMAL, SOFT_UPDATE, FORCE_UPDATE or MAINTENANCE —
// worked out here from the app_versions rows, with what the app needs to show
// it (appversion.AppConfigResponse). Nothing here is internal: the versions,
// the store links and the messages are what the store listings say anyway.
func (a *App) appConfigHandler(w http.ResponseWriter, r *http.Request) {
	client := appversion.ClientFromRequest(r)
	q := r.URL.Query()
	if strings.TrimSpace(r.Header.Get(appversion.HeaderPlatform)) == "" {
		client.Platform = appversion.NewClient(q.Get("platform"), "").Platform
	}
	if strings.TrimSpace(r.Header.Get(appversion.HeaderVersion)) == "" {
		client.Version = appversion.NewClient("", q.Get("version")).Version
	}
	verdict, rows := a.appGate.Check(r.Context(), client)
	w.Header().Set("Cache-Control", "no-store")
	auth.WriteJSON(w, http.StatusOK, appversion.Response(rows, client, verdict))
}
