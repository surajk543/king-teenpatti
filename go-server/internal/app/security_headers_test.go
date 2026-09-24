package app

import (
	"net/http"
	"testing"
)

// Every HTTP answer carries nosniff, no framing and no referrer (auth-3, 24
// Sep 2026), and GET /api/tables keeps its own caching: no-cache + ETag, and a
// 304 for the version a client holds.
func TestEveryAnswerCarriesTheSecurityHeadersAndTablesKeepsItsETag(t *testing.T) {
	a, _ := newApp(t, nil)
	h := a.Handler()
	for _, path := range []string{"/health", "/api/tables", "/api/profiles", "/api/nothing-here", "/"} {
		res, _ := get(t, h, http.MethodGet, path, nil)
		for key, want := range map[string]string{
			"X-Content-Type-Options": "nosniff",
			"X-Frame-Options":        "DENY",
			"Referrer-Policy":        "no-referrer",
		} {
			if got := res.Header.Get(key); got != want {
				t.Errorf("%s %s = %q, want %q", path, key, got, want)
			}
		}
	}
	res, _ := get(t, h, http.MethodGet, "/api/tables", nil)
	etag := res.Header.Get("ETag")
	if etag == "" || res.Header.Get("Cache-Control") != "no-cache" {
		t.Fatalf("/api/tables: ETag %q Cache-Control %q", etag, res.Header.Get("Cache-Control"))
	}
	res, _ = get(t, h, http.MethodGet, "/api/tables", func(r *http.Request) { r.Header.Set("If-None-Match", etag) })
	if res.StatusCode != http.StatusNotModified {
		t.Fatalf("If-None-Match its own version: %d", res.StatusCode)
	}
	res, _ = get(t, h, http.MethodGet, "/api/auth/me", signedIn(t, h, "headers-me-device-01"))
	if res.StatusCode != http.StatusOK || res.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("/api/auth/me: %d Cache-Control %q", res.StatusCode, res.Header.Get("Cache-Control"))
	}
}
