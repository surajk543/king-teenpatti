package appversion

import (
	"context"
	"log/slog"
	"sync"
	"time"
)

// Loader reads the configuration from where it is kept (db.AppVersions: the
// app_versions table).
type Loader interface {
	Load(ctx context.Context) (Config, error)
}

// LoaderFunc adapts a function to Loader.
type LoaderFunc func(ctx context.Context) (Config, error)

// Load calls f.
func (f LoaderFunc) Load(ctx context.Context) (Config, error) { return f(ctx) }

// loadTimeout bounds one read of the configuration.
const loadTimeout = 2 * time.Second

// Source is the configuration behind a short in-process cache
// (APP_VERSION_CACHE_MS): read at most once per TTL, so an operator's UPDATE of
// a row is enforced within that many seconds — no restart, no app release —
// while a busy server reads the table a handful of times a minute rather than
// once per request.
//
// When a read fails the last configuration read is kept and the read is tried
// again on the next request; one WARN says so, and one INFO when it reads
// again. Before any read has succeeded the configuration is the empty one —
// every platform open, no floor — which is fail-open by design: a gate that
// locked every player out because PostgreSQL blinked at boot would be a worse
// failure than an old client let in, and the app builds a minimum shuts out
// could not be served anyway while the database that holds their wallets is
// down.
//
// A caller that finds the cache stale while another is already reading it is
// served the stale configuration rather than queued behind the read.
type Source struct {
	loader Loader
	ttl    time.Duration
	now    func() time.Time
	log    *slog.Logger

	mu         sync.Mutex
	cfg        Config
	loaded     bool
	loadedAt   time.Time
	refreshing bool
	failing    bool
}

// NewSource builds a Source. ttl 0 reads on every call; now nil is time.Now;
// log nil is slog.Default().
func NewSource(loader Loader, ttl time.Duration, now func() time.Time, log *slog.Logger) *Source {
	if now == nil {
		now = time.Now
	}
	if log == nil {
		log = slog.Default()
	}
	return &Source{loader: loader, ttl: ttl, now: now, log: log}
}

// Current is the configuration, read afresh when the cached copy is older
// than the TTL.
func (s *Source) Current(ctx context.Context) Config {
	if s == nil || s.loader == nil {
		return Config{}
	}
	s.mu.Lock()
	if s.loaded && s.ttl > 0 && s.now().Sub(s.loadedAt) < s.ttl {
		cfg := s.cfg
		s.mu.Unlock()
		return cfg
	}
	if s.refreshing {
		cfg := s.cfg
		s.mu.Unlock()
		return cfg
	}
	s.refreshing = true
	s.mu.Unlock()

	rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), loadTimeout)
	cfg, err := s.loader.Load(rctx)
	cancel()

	s.mu.Lock()
	defer s.mu.Unlock()
	s.refreshing = false
	if err != nil {
		if !s.failing {
			s.failing = true
			s.log.Warn("app version config read failed; keeping the last one", "error", err.Error(), "haveConfig", s.loaded)
		}
		return s.cfg
	}
	if s.failing {
		s.failing = false
		s.log.Info("app version config read again")
	}
	s.cfg, s.loaded, s.loadedAt = cfg, true, s.now()
	return cfg
}

// Invalidate makes the next Current read afresh (tests, and a caller that has
// just written the rows itself).
func (s *Source) Invalidate() {
	if s == nil {
		return
	}
	s.mu.Lock()
	// The copy held stays, for a read that fails; it is merely stale now.
	s.loadedAt = time.Time{}
	s.mu.Unlock()
}
