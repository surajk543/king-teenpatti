package config

import (
	"testing"
	"time"
)

// The REST rate limits are env keys with generous defaults (auth-2, 24 Sep
// 2026), 0 turns one off, and a negative figure or a zero window under a live
// limit stops the boot.
func TestTheRESTRateLimitsAreConfigurable(t *testing.T) {
	def := mustLoad(t, map[string]string{})
	if def.RESTRate != (RESTRateConfig{Login: 60, Wallet: 120, Window: time.Minute}) {
		t.Fatalf("defaults %+v", def.RESTRate)
	}
	got := mustLoad(t, map[string]string{"REST_LOGIN_RATE_LIMIT": "5", "REST_WALLET_RATE_LIMIT": "0", "REST_RATE_WINDOW_MS": "10000"})
	if got.RESTRate != (RESTRateConfig{Login: 5, Wallet: 0, Window: 10 * time.Second}) {
		t.Fatalf("configured %+v", got.RESTRate)
	}
	for _, bad := range []map[string]string{
		{"REST_LOGIN_RATE_LIMIT": "-1"},
		{"REST_WALLET_RATE_LIMIT": "-5"},
		{"REST_RATE_WINDOW_MS": "0"},
		{"REST_LOGIN_RATE_LIMIT": "ten"},
	} {
		if _, err := FromEnv(env(bad)); err == nil {
			t.Errorf("%v was accepted", bad)
		}
	}
	if _, err := FromEnv(env(map[string]string{"REST_LOGIN_RATE_LIMIT": "0", "REST_WALLET_RATE_LIMIT": "0", "REST_RATE_WINDOW_MS": "0"})); err != nil {
		t.Errorf("both limits off need no window: %v", err)
	}
}
