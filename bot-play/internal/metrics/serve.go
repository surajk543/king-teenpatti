package metrics

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/state"
)

// shutdownGrace is how long Serve waits for requests in flight once ctx ends.
const shutdownGrace = 5 * time.Second

// Serve runs the HTTP endpoints on addr until ctx ends:
//
//	GET /metrics            Prometheus exposition (when m is not nil)
//	GET /healthz            {"ok":true,"bots":N}
//	GET /debug/bots         every bot's snapshot, JSON (?format=text for text)
//	GET /debug/bots/{bot}   one bot, text (brief §34); ?format=json for JSON
//
// Cards are shown only when showCards; otherwise they are stripped from every
// snapshot. Bind to loopback: there is no authentication.
//
// A nil m serves no /metrics and a nil snapshots no /debug (both 404), so the
// metrics and the debug view may be served on two addresses by two calls —
// Serve(ctx, metricsAddr, m, nil, false, log) and Serve(ctx, debugAddr, nil,
// snapshots, showCards, log) — or on one. An empty addr serves nothing and
// returns nil at once. Serve returns nil after a clean shutdown, and the
// listener's or server's error otherwise.
func Serve(ctx context.Context, addr string, m *Metrics, snapshots func() []state.Snapshot, showCards bool, log *slog.Logger) error {
	if log == nil {
		log = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	if addr == "" {
		return nil
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	srv := &http.Server{
		Handler:           Handler(m, snapshots, showCards),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		ErrorLog:          slog.NewLogLogger(log.Handler(), slog.LevelWarn),
	}
	log.Info("observability serving", "addr", ln.Addr().String(), "metrics", m != nil, "debug", snapshots != nil)

	shut := make(chan error, 1)
	go func() {
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), shutdownGrace)
		defer cancel()
		shut <- srv.Shutdown(sctx)
	}()
	if err := srv.Serve(ln); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	if err := <-shut; err != nil {
		return err
	}
	log.Info("observability stopped", "addr", ln.Addr().String())
	return nil
}

// Handler is Serve's routes, for tests and for mounting elsewhere.
func Handler(m *Metrics, snapshots func() []state.Snapshot, showCards bool) http.Handler {
	mux := http.NewServeMux()
	if m != nil {
		mux.Handle("GET /metrics", promhttp.HandlerFor(m.reg, promhttp.HandlerOpts{
			Registry:          m.labeled, // promhttp_metric_handler_errors_total beside the rest, labelled alike
			EnableOpenMetrics: true,
		}))
	}
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		n := 0
		if snapshots != nil {
			n = len(snapshots())
		}
		writeJSON(w, http.StatusOK, struct {
			OK   bool `json:"ok"`
			Bots int  `json:"bots"`
		}{true, n})
	})
	if snapshots != nil {
		mux.HandleFunc("GET /debug/bots", func(w http.ResponseWriter, r *http.Request) {
			list := visible(snapshots(), showCards)
			switch r.URL.Query().Get("format") {
			case "", "json":
				writeJSON(w, http.StatusOK, list)
			case "text":
				var b strings.Builder
				for i, s := range list {
					if i > 0 {
						b.WriteString("\n")
					}
					b.WriteString(s.String())
				}
				writeText(w, http.StatusOK, b.String())
			default:
				writeText(w, http.StatusBadRequest, "format is json or text\n")
			}
		})
		mux.HandleFunc("GET /debug/bots/{bot}", func(w http.ResponseWriter, r *http.Request) {
			name := r.PathValue("bot")
			var found *state.Snapshot
			for _, s := range visible(snapshots(), showCards) {
				if s.Bot == name || (s.UserID != "" && s.UserID == name) {
					found = &s
					break
				}
			}
			if found == nil {
				writeText(w, http.StatusNotFound, "unknown bot\n")
				return
			}
			switch r.URL.Query().Get("format") {
			case "", "text":
				writeText(w, http.StatusOK, found.String())
			case "json":
				writeJSON(w, http.StatusOK, found)
			default:
				writeText(w, http.StatusBadRequest, "format is text or json\n")
			}
		})
	}
	return mux
}

// visible is a copy of the snapshots in bot order, never nil, with the cards
// taken out unless showCards.
func visible(in []state.Snapshot, showCards bool) []state.Snapshot {
	out := make([]state.Snapshot, len(in))
	copy(out, in)
	for i := range out {
		if showCards {
			out[i].Cards = slices.Clone(out[i].Cards)
		} else {
			out[i].Cards = nil
		}
	}
	slices.SortStableFunc(out, func(a, b state.Snapshot) int { return cmp.Compare(a.Bot, b.Bot) })
	return out
}

func noStore(w http.ResponseWriter, contentType string) {
	h := w.Header()
	h.Set("Content-Type", contentType)
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	noStore(w, "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

func writeText(w http.ResponseWriter, status int, body string) {
	noStore(w, "text/plain; charset=utf-8")
	w.WriteHeader(status)
	_, _ = io.WriteString(w, body)
}
