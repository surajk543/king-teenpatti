package auth

import (
	"bytes"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// The REST doors that mint accounts or move wallets are limited per client IP
// (auth-2, 24 Sep 2026): a script could create guest accounts — each with the
// welcome chips — or guess guest device ids as fast as the server answered.

func TestTheIPLimiterCountsAFixedWindowPerIP(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	l := newIPLimiter(2, time.Minute, func() time.Time { return now })
	for i := 0; i < 2; i++ {
		if ok, _, _ := l.allow("198.51.100.7"); !ok {
			t.Fatalf("request %d refused under the limit", i+1)
		}
	}
	ok, wait, first := l.allow("198.51.100.7")
	if ok || !first || wait != time.Minute {
		t.Fatalf("third request: ok=%v first=%v wait=%v", ok, first, wait)
	}
	if _, _, first := l.allow("198.51.100.7"); first {
		t.Fatal("only the window's first refusal is the first")
	}
	if ok, _, _ := l.allow("203.0.113.9"); !ok {
		t.Fatal("another IP shares the count")
	}
	now = now.Add(time.Minute)
	if ok, _, _ := l.allow("198.51.100.7"); !ok {
		t.Fatal("a new window did not reset the count")
	}
	if len(l.windows) != 1 {
		t.Fatalf("lapsed windows kept: %d", len(l.windows))
	}
	if ok, _, _ := newIPLimiter(0, time.Minute, nil).allow("x"); !ok {
		t.Fatal("a limit of 0 must be off")
	}
}

func TestTheClientIPIsThePeerOrNginxsRealIPFromLoopback(t *testing.T) {
	for _, tc := range []struct {
		remote, realIP, want string
	}{
		{"198.51.100.7:5000", "", "198.51.100.7"},
		{"198.51.100.7:5000", "10.9.9.9", "198.51.100.7"}, // a direct client cannot pick its IP
		{"127.0.0.1:41000", "203.0.113.9", "203.0.113.9"}, // nginx on this host
		{"[::1]:41000", "203.0.113.9", "203.0.113.9"},
		{"127.0.0.1:41000", "", ""}, // local traffic: bots, tools, tests
	} {
		r := httptest.NewRequest(http.MethodPost, "/api/auth/login", nil)
		r.RemoteAddr = tc.remote
		if tc.realIP != "" {
			r.Header.Set("X-Real-IP", tc.realIP)
		}
		if got := clientIP(r); got != tc.want {
			t.Errorf("peer %s X-Real-IP %q: %q, want %q", tc.remote, tc.realIP, got, tc.want)
		}
	}
}

func TestLoginsPastTheLimitAreRefused429FromThatIPOnly(t *testing.T) {
	h := newHarness(t)
	cfg := *h.cfg
	cfg.RESTRate.Login = 3
	cfg.RESTRate.Wallet = 2
	cfg.RESTRate.Window = time.Minute
	handler := NewHandler(Deps{
		Config:   &cfg,
		Users:    h.store,
		Pictures: h.pictures,
		Tokens:   h.tokens,
		Verifier: NewVerifier(&cfg),
		Logger:   slog.New(slog.NewJSONHandler(h.logs, nil)),
	})
	h.mux = http.NewServeMux()
	handler.Register(h.mux)

	var token string
	for i := 0; i < 3; i++ {
		token, _ = h.login("device-rate-limit-"+string(rune('a'+i))+"-01", "")
	}
	res := h.do(http.MethodPost, "/api/auth/login", map[string]any{"provider": "guest", "deviceId": "device-rate-limit-z-01"})
	expectError(t, res, http.StatusTooManyRequests, CodeRateLimited)
	if res.header.Get("Retry-After") == "" {
		t.Error("a 429 carries Retry-After")
	}
	if !bytes.Contains(h.logs.Bytes(), []byte("rest rate limited")) {
		t.Error("the refusal is not logged")
	}

	// Another client IP is not held back by this one.
	req := httptest.NewRequest(http.MethodPost, "/api/auth/login",
		bytes.NewBufferString(`{"provider":"guest","deviceId":"device-rate-limit-other-01"}`))
	req.Header.Set("Content-Type", "application/json")
	req.RemoteAddr = "203.0.113.9:4000"
	rec := httptest.NewRecorder()
	h.mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("another IP: %d %s", rec.Code, rec.Body.String())
	}

	// The wallet doors have their own count.
	for i := 0; i < 2; i++ {
		if res := h.do(http.MethodPost, "/api/rewards/bonus", map[string]any{}, bearer(token)...); res.status == http.StatusTooManyRequests {
			t.Fatalf("wallet request %d limited under the limit", i+1)
		}
	}
	res = h.do(http.MethodPost, "/api/rewards/bonus", map[string]any{}, bearer(token)...)
	expectError(t, res, http.StatusTooManyRequests, CodeRateLimited)
	// Reading one's own account is not a wallet door.
	if res := h.do(http.MethodGet, "/api/auth/me", nil, bearer(token)...); res.status != http.StatusOK {
		t.Fatalf("/api/auth/me: %d %s", res.status, res.raw)
	}
}

// A signed-in answer and a login's answer are never kept by a cache (auth-3).
func TestSignedInAnswersAndLoginsAreNoStore(t *testing.T) {
	h := newHarness(t)
	res := h.do(http.MethodPost, "/api/auth/login", map[string]any{"provider": "guest", "deviceId": "device-no-store-0001"})
	if res.status != http.StatusOK || res.header.Get("Cache-Control") != "no-store" {
		t.Fatalf("login: %d Cache-Control %q", res.status, res.header.Get("Cache-Control"))
	}
	token := res.body["token"].(string)
	if res := h.do(http.MethodGet, "/api/auth/me", nil, bearer(token)...); res.header.Get("Cache-Control") != "no-store" {
		t.Fatalf("/api/auth/me Cache-Control %q", res.header.Get("Cache-Control"))
	}
}
