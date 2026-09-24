package auth

import (
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// CodeRateLimited is the REST refusal of a client IP over its limit (429).
const CodeRateLimited = "rate_limited"

// MsgRateLimited is its message.
const MsgRateLimited = "Too many requests; try again in a moment"

// ipLimiter is a fixed-window request counter per client IP (24 Sep 2026,
// owner's "fix all bugs"; config.RESTRateConfig). limit 0 lets everything
// through.
type ipLimiter struct {
	limit  int
	window time.Duration
	now    func() time.Time

	mu      sync.Mutex
	windows map[string]*ipWindow
	swept   time.Time
}

type ipWindow struct {
	start time.Time
	count int
}

func newIPLimiter(limit int, window time.Duration, now func() time.Time) *ipLimiter {
	if now == nil {
		now = time.Now
	}
	return &ipLimiter{limit: limit, window: window, now: now, windows: map[string]*ipWindow{}}
}

// allow counts one request from ip; false (with how long until its window
// ends, and whether this is the window's first refusal) once the window's
// count passes the limit.
func (l *ipLimiter) allow(ip string) (ok bool, wait time.Duration, first bool) {
	if l == nil || l.limit <= 0 || l.window <= 0 {
		return true, 0, false
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	// Drop lapsed windows once a window, so the map holds only the IPs seen
	// in the last one.
	if now.Sub(l.swept) >= l.window {
		for key, w := range l.windows {
			if now.Sub(w.start) >= l.window {
				delete(l.windows, key)
			}
		}
		l.swept = now
	}
	w := l.windows[ip]
	if w == nil || now.Sub(w.start) >= l.window {
		w = &ipWindow{start: now}
		l.windows[ip] = w
	}
	w.count++
	if w.count > l.limit {
		return false, w.start.Add(l.window).Sub(now), w.count == l.limit+1
	}
	return true, 0, false
}

// clientIP is the IP a REST limit counts against, and "" for a request that
// is not limited. The peer's address, unless the peer is loopback: then the
// request came through nginx on this host, which names the real client in
// X-Real-IP (ops/monitoring/nginx: `proxy_set_header X-Real-IP
// $remote_addr`, overwriting whatever the client sent) — or it is local
// traffic with no such header (the bot fleet on the game host, the tools, the
// tests), which is not limited. A header from any other peer is ignored, so a
// client reaching the port directly cannot pick its own IP.
func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	peer := net.ParseIP(host)
	if peer != nil && peer.IsLoopback() {
		return strings.TrimSpace(r.Header.Get("X-Real-IP"))
	}
	return host
}

// limited wraps next in a per-IP limit: over it, 429 {error: rate_limited}
// with Retry-After (whole seconds, at least 1), logged once per IP per window.
func (h *Handler) limited(l *ipLimiter, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if ip := clientIP(r); ip != "" {
			if ok, wait, first := l.allow(ip); !ok {
				secs := int((wait + time.Second - 1) / time.Second)
				if secs < 1 {
					secs = 1
				}
				w.Header().Set("Retry-After", strconv.Itoa(secs))
				if first && h.deps.Logger != nil {
					h.deps.Logger.Warn("rest rate limited", "path", r.URL.Path, "ip", ip)
				}
				WriteJSON(w, http.StatusTooManyRequests, ErrorResponse{Error: CodeRateLimited, Message: MsgRateLimited})
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}
