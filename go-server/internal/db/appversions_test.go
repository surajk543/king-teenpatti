package db_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/appversion"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
)

const playListing = "https://play.google.com/store/apps/details?id=com.sungamestudio.kingteenpatti"

func loadAppVersions(t *testing.T, d *db.DB) appversion.Config {
	t.Helper()
	cfg, err := db.NewAppVersions(d).Load(context.Background())
	if err != nil {
		t.Fatalf("AppVersions.Load: %v", err)
	}
	return cfg
}

// The seed opens both platforms with no floor and nothing announced:
// deploying the gate changes nothing for anybody.
func TestTheSeededAppVersionsHoldNoFloor(t *testing.T) {
	d := dbtest.Open(t, "appver")
	cfg := loadAppVersions(t, d)
	if len(cfg.Platforms) != 2 {
		t.Fatalf("the seed holds %d platforms, want android and ios: %+v", len(cfg.Platforms), cfg.Platforms)
	}
	android, ios := cfg.Platforms["android"], cfg.Platforms["ios"]
	want := appversion.PlatformConfig{Status: appversion.StatusNormal, StoreURL: playListing}
	if android != want {
		t.Errorf("android seeded as %+v, want %+v", android, want)
	}
	if ios != (appversion.PlatformConfig{Status: appversion.StatusNormal}) {
		t.Errorf("ios seeded as %+v, want open with no floor and no store", ios)
	}
	for _, c := range []appversion.Client{
		appversion.NewClient("android", "0.0.1"), appversion.NewClient("ios", "1.0.0"),
		appversion.NewClient("android", ""), appversion.NewClient("", ""),
	} {
		if v := appversion.Evaluate(cfg, c, false); v.Status != appversion.StatusNormal {
			t.Errorf("%+v on the seed: %s", c, v.Status)
		}
	}
	if n := cfg.MinClientBuild(appversion.NewClient("", ""), 0); n != 0 {
		t.Errorf("the seed's build floor is %d, want none", n)
	}
}

// What production's team does (brief §15): Android's minimum raised from 1.5.0
// to 1.6.0 with one UPDATE. The CHECKs refuse what would lock players out by
// accident — a malformed version, an unknown status — and the trigger stamps
// when the row changed.
func TestAnOperatorsUpdateIsReadAndTyposAreRefused(t *testing.T) {
	d := dbtest.Open(t, "appver")
	ctx := context.Background()
	store := db.NewAppVersions(d)
	before := countOf(t, d, `SELECT updated_at FROM app_versions WHERE platform = 'android'`)

	time.Sleep(5 * time.Millisecond)
	execSQL(t, d, `UPDATE app_versions SET minimum_version = '1.5.0', latest_version = '1.6.2' WHERE platform = 'android'`)
	execSQL(t, d, `UPDATE app_versions SET minimum_version = '1.4.0', latest_version = '1.5.0',
	                store_url = 'https://apps.apple.com/app/id1234567890' WHERE platform = 'ios'`)
	cfg, err := store.Load(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if got := cfg.For("android"); got.MinimumVersion != appversion.MustParse("1.5.0") || got.LatestVersion != appversion.MustParse("1.6.2") {
		t.Errorf("android after the update: %+v", got)
	}
	if got := cfg.For("ios"); got.MinimumVersion != appversion.MustParse("1.4.0") || got.StoreURL != "https://apps.apple.com/app/id1234567890" {
		t.Errorf("ios after the update: %+v", got)
	}
	if after := countOf(t, d, `SELECT updated_at FROM app_versions WHERE platform = 'android'`); after <= before {
		t.Errorf("updated_at stayed at %d after an UPDATE (was %d)", after, before)
	}

	// The operational change of §15: minimum 1.5.0 → 1.6.0.
	execSQL(t, d, `UPDATE app_versions SET minimum_version = '1.6.0' WHERE platform = 'android'`)
	cfg = loadAppVersions(t, d)
	if v := appversion.Evaluate(cfg, appversion.NewClient("android", "1.5.0"), false); v.Status != appversion.StatusForceUpdate {
		t.Errorf("android 1.5.0 after the minimum rose to 1.6.0: %s", v.Status)
	}
	if v := appversion.Evaluate(cfg, appversion.NewClient("android", "1.6.0"), false); v.Status != appversion.StatusSoftUpdate {
		t.Errorf("android 1.6.0 (latest 1.6.2): %s", v.Status)
	}
	if v := appversion.Evaluate(cfg, appversion.NewClient("android", "1.6.2"), false); v.Status != appversion.StatusNormal {
		t.Errorf("android 1.6.2: %s", v.Status)
	}

	for _, typo := range []string{
		`UPDATE app_versions SET minimum_version = '1.6' WHERE platform = 'android'`,
		`UPDATE app_versions SET minimum_version = 'v1.6.0' WHERE platform = 'android'`,
		`UPDATE app_versions SET latest_version = '1.06.0' WHERE platform = 'android'`,
		`UPDATE app_versions SET minimum_version = '1.6.0+14' WHERE platform = 'android'`,
		`UPDATE app_versions SET status = 'MAINTAINANCE' WHERE platform = 'android'`,
		`UPDATE app_versions SET status = 'FORCE_UPDATE' WHERE platform = 'android'`,
		`INSERT INTO app_versions (platform) VALUES ('Android')`,
	} {
		if _, err := d.Pool.Exec(ctx, typo); err == nil || !strings.Contains(err.Error(), "check") {
			t.Errorf("%s: %v, want a CHECK violation", typo, err)
		}
	}

	// Maintenance, with a message, and out of it again.
	execSQL(t, d, `UPDATE app_versions SET status = 'MAINTENANCE', message = 'Back at 14:00 IST'`)
	cfg = loadAppVersions(t, d)
	for _, p := range []string{"android", "ios"} {
		if v := appversion.Evaluate(cfg, appversion.NewClient(p, "9.9.9"), false); v.Status != appversion.StatusMaintenance || v.Message != "Back at 14:00 IST" {
			t.Errorf("%s in maintenance: %s %q", p, v.Status, v.Message)
		}
	}
	execSQL(t, d, `UPDATE app_versions SET status = 'NORMAL', message = NULL`)
	if v := appversion.Evaluate(loadAppVersions(t, d), appversion.NewClient("ios", "1.5.0"), false); v.Status != appversion.StatusNormal {
		t.Errorf("out of maintenance: %s", v.Status)
	}
}

// The path production takes: a database built before the gate has no
// app_versions. One boot creates it — with its trigger — and seeds both rows
// with no floor; an operator's UPDATE then survives every later boot, since
// the seed never overwrites a row.
func TestABootBringsAnOlderDatabaseForwardWithTheAppVersionGate(t *testing.T) {
	older := dbtest.Open(t, "appverup")
	execSQL(t, older, `DROP TABLE app_versions`)
	execSQL(t, older, `DROP FUNCTION app_versions_touch()`)
	if n := countOf(t, older, `SELECT count(*) FROM information_schema.tables WHERE table_schema = $1 AND table_name = 'app_versions'`, older.Schema); n != 0 {
		t.Fatal("app_versions was not dropped")
	}

	bootCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	d, err := db.Open(bootCtx, db.Options{URL: testURL(), Schema: older.Schema, PoolMax: 2})
	if err != nil {
		t.Fatalf("the boot that brings the database forward: %v", err)
	}
	t.Cleanup(d.Close)

	cfg := loadAppVersions(t, d)
	if len(cfg.Platforms) != 2 || cfg.For("android").StoreURL != playListing || !cfg.For("android").MinimumVersion.IsZero() || !cfg.For("ios").MinimumVersion.IsZero() {
		t.Fatalf("after the upgrade: %+v", cfg.Platforms)
	}
	if n := countOf(t, d, `SELECT count(*) FROM pg_trigger WHERE tgname = 'app_versions_touch' AND tgrelid = 'app_versions'::regclass`); n != 1 {
		t.Errorf("%d app_versions_touch triggers after the upgrade, want 1", n)
	}

	execSQL(t, d, `UPDATE app_versions SET minimum_version = '1.6.0', latest_version = '1.6.2', message = 'Please update' WHERE platform = 'android'`)
	reboot(t, d)
	reboot(t, d)
	got := loadAppVersions(t, d).For("android")
	if got.MinimumVersion != appversion.MustParse("1.6.0") || got.LatestVersion != appversion.MustParse("1.6.2") || got.Message != "Please update" {
		t.Errorf("an operator's UPDATE after two more boots: %+v", got)
	}
	if n := countOf(t, d, `SELECT count(*) FROM app_versions`); n != 2 {
		t.Errorf("%d rows after three boots, want 2", n)
	}
	if n := countOf(t, d, `SELECT count(*) FROM pg_trigger WHERE tgname = 'app_versions_touch' AND tgrelid = 'app_versions'::regclass`); n != 1 {
		t.Errorf("%d triggers after three boots, want 1", n)
	}
}

// A read from a schema that lacks the table fails rather than reading
// public's, so the gate keeps what it last read.
func TestAReadFromASchemaWithoutTheTableFails(t *testing.T) {
	d := dbtest.Open(t, "appvergone")
	execSQL(t, d, `DROP TABLE app_versions`)
	if _, err := db.NewAppVersions(d).Load(context.Background()); err == nil {
		t.Fatal("a read of a missing app_versions succeeded")
	}
}
