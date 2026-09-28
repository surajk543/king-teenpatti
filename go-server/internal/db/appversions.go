package db

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/appversion"
)

// AppVersions is the app version gate's configuration in PostgreSQL (owner,
// 28 Sep 2026): the app_versions table V1.0.0__baseline.sql declares and
// V1.0.1__seed.sql fills with a row per app platform — whether it is open, the
// oldest version allowed to play, the newest announced, the store link and an
// optional message. Configuration, read while the server runs through
// appversion.Source's short cache, so an operator's UPDATE is enforced within
// APP_VERSION_CACHE_MS; nothing a hand does touches it.
type AppVersions struct {
	db *DB
}

// NewAppVersions builds the reader.
func NewAppVersions(d *DB) *AppVersions {
	return &AppVersions{db: d}
}

// Load reads every row, keyed by platform. It implements appversion.Loader.
// The table is qualified with the pool's schema, as TableConfigs.Load's are:
// a schema that lacks it must fail here, not quietly read public's.
//
// A row whose version is not MAJOR.MINOR.PATCH (the CHECK makes that
// impossible for a row written through it) fails the whole read, so the gate
// keeps the configuration it read last rather than play by a half-read one.
func (a *AppVersions) Load(ctx context.Context) (appversion.Config, error) {
	rows, err := a.db.Pool.Query(ctx, `SELECT platform, status, minimum_version, latest_version, store_url, COALESCE(message, '')
	  FROM `+pgx.Identifier{a.db.Schema, "app_versions"}.Sanitize())
	if err != nil {
		return appversion.Config{}, err
	}
	defer rows.Close()
	cfg := appversion.Config{Platforms: map[string]appversion.PlatformConfig{}}
	for rows.Next() {
		var platform, status, minimum, latest, store, message string
		if err := rows.Scan(&platform, &status, &minimum, &latest, &store, &message); err != nil {
			return appversion.Config{}, err
		}
		minV, err := appversion.Parse(minimum)
		if err != nil {
			return appversion.Config{}, fmt.Errorf("app_versions %s: minimum_version %q: %w", platform, minimum, err)
		}
		latestV, err := appversion.Parse(latest)
		if err != nil {
			return appversion.Config{}, fmt.Errorf("app_versions %s: latest_version %q: %w", platform, latest, err)
		}
		cfg.Platforms[platform] = appversion.PlatformConfig{
			Status:         status,
			MinimumVersion: minV,
			LatestVersion:  latestV,
			StoreURL:       store,
			Message:        message,
		}
	}
	if err := rows.Err(); err != nil {
		return appversion.Config{}, err
	}
	return cfg, nil
}
