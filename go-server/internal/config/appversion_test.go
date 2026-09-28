package config

import (
	"testing"
	"time"
)

// The app version gate's two keys (28 Sep 2026): the undeclared-client switch
// is off by default — deploying the gate must lock nobody out — and the rows
// are cached 15 s; 0 reads every time, a negative figure stops the boot.
func TestTheAppVersionGateKeysAreConfigurable(t *testing.T) {
	def := mustLoad(t, map[string]string{})
	if def.AppVersion != (AppVersionConfig{Required: false, CacheTTL: 15 * time.Second}) {
		t.Fatalf("defaults %+v", def.AppVersion)
	}
	got := mustLoad(t, map[string]string{"APP_VERSION_REQUIRED": "true", "APP_VERSION_CACHE_MS": "0"})
	if got.AppVersion != (AppVersionConfig{Required: true, CacheTTL: 0}) {
		t.Fatalf("configured %+v", got.AppVersion)
	}
	for _, bad := range []map[string]string{
		{"APP_VERSION_CACHE_MS": "-1"},
		{"APP_VERSION_CACHE_MS": "soon"},
	} {
		if _, err := FromEnv(env(bad)); err == nil {
			t.Errorf("%v was accepted", bad)
		}
	}
	// Neither is a table key: the table catalogue's source is unaffected.
	for _, key := range TableEnvKeys() {
		if key == "APP_VERSION_REQUIRED" || key == "APP_VERSION_CACHE_MS" {
			t.Errorf("%s must not be a table env key", key)
		}
	}
}
