// Command bot-play runs the King Teen Patti bot fleet: BOT_COUNT bots that
// sign in as guest devices in the botplay- namespace, find Teen Patti tables
// on the menu the game server publishes, play, move between tables, rest
// between sessions and reconnect after failures — as normal clients of the
// game server, which stays the authority on every rule.
//
//	BOT_COUNT=10 BOT_MODE=server go run ./cmd/bot-play          # against SERVER_URL (default http://127.0.0.1:3000)
//	BOT_COUNT=10 BOT_MODE=simulation BOT_SEED=12345 go run ./cmd/bot-play
//
// Configuration: configs/bot.yaml (or -config), then environment variables;
// README.md lists every key.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/connection"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/interaction"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/state"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/strategy"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/table"
	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/timing"
	"github.com/surajk543/king-teenpatti/bot-play/internal/clock"
	"github.com/surajk543/king-teenpatti/bot-play/internal/config"
	"github.com/surajk543/king-teenpatti/bot-play/internal/metrics"
	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
	"github.com/surajk543/king-teenpatti/bot-play/internal/sim"
)

// version is stamped at build time (-ldflags "-X main.version=…").
var version = "dev"

func main() {
	configPath := flag.String("config", "", "YAML configuration (default: "+config.DefaultPath+" when present)")
	showVersion := flag.Bool("version", false, "print the version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println("bot-play", version)
		return
	}
	if err := run(*configPath); err != nil {
		fmt.Fprintln(os.Stderr, "bot-play:", err)
		os.Exit(1)
	}
}

func run(configPath string) error {
	path := configPath
	if path == "" {
		path = config.DefaultPath // skipped when absent; any other missing path is an error
	}
	cfg, err := config.Load(path, os.Getenv)
	if err != nil {
		return err
	}
	log := newLogger(cfg)
	seed := cfg.Seed
	if seed == 0 {
		seed = uint64(time.Now().UnixNano())
	}
	log.Info("bot-play starting", "version", version, "mode", cfg.Mode, "bots", cfg.Bots.Count,
		"prefix", cfg.Bots.DevicePrefix, "server", cfg.ServerURL, "seed", seed, "config", path)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	hard, cancelHard := context.WithCancel(context.Background())
	defer cancelHard()

	clk := clock.Clock(clock.Real{})
	var api protocol.API
	var dialer protocol.Dialer
	switch cfg.Mode {
	case "simulation":
		srv := sim.NewServer(sim.Config{Seed: seed, Clock: clk, Log: log.With("component", "sim")})
		defer srv.Close()
		api, dialer = srv.API(), srv.Dialer()
		go logSimStats(ctx, srv, log)
	default:
		api = connection.NewHTTPAPI(cfg.ServerURL, nil)
		dialer = connection.NewDialer(cfg.ServerURL, cfg.WSURL, connection.DialOptions{Log: log.With("component", "connection")})
	}

	finder := table.NewFinder(api, cfg.Table.Categories, clk.Now)
	if err := waitForMenu(ctx, finder, log); err != nil {
		return nil // interrupted while waiting
	}
	profiles, err := strategy.ApplyTuning(strategy.DefaultProfiles, cfg.Strategy.Tuning)
	if err != nil {
		return err
	}
	tcfg, err := timingConfig(cfg)
	if err != nil {
		return err
	}
	if _, err := interaction.ParseProbabilities(cfg.Interaction.Probabilities); err != nil {
		return fmt.Errorf("interaction.probabilities: %w", err)
	}
	var m *metrics.Metrics
	if cfg.Metrics.Addr != "" || cfg.Debug.Addr != "" {
		m = metrics.New()
	}
	deps := bot.Deps{
		API:      api,
		Dialer:   dialer,
		Finder:   finder,
		Clock:    clk,
		Delay:    timing.New(tcfg),
		Budget:   interaction.NewTableBudget(cfg.Interaction.TableGap, cfg.Interaction.TablePerMin),
		Emoter:   interaction.NoEmotes{},
		Metrics:  m,
		Fleet:    bot.NewFleet(),
		Profiles: profiles,
		Config:   cfg,
		Log:      log,
		Seed:     seed,
	}
	mgr := bot.NewManager(deps)
	serve(hard, cfg, m, mgr, log)
	mgr.Start(hard)

	<-ctx.Done()
	log.Info("stopping: every bot finishes its hand and leaves")
	grace, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	forced := mgr.Stop(grace)
	log.Info("stopped", "forced", forced)
	return nil
}

// waitForMenu reads the table menu, waiting for a game server that is not up
// yet rather than exiting (a fleet that restart-loops on boot order is worse
// than one that waits).
func waitForMenu(ctx context.Context, f *table.Finder, log *slog.Logger) error {
	for attempt := 1; ; attempt++ {
		rctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		err := f.Refresh(rctx)
		cancel()
		if err == nil {
			menu := f.Menu()
			keys := make([]string, 0, len(menu.Tables))
			for _, t := range menu.Tables {
				keys = append(keys, t.Key)
			}
			log.Info("table menu", "version", menu.Version, "tables", keys)
			return nil
		}
		if attempt == 1 || attempt%10 == 0 {
			log.Warn("waiting for the game server", "err", err)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(3 * time.Second):
		}
	}
}

// serve runs the observability endpoints: /metrics on metrics.addr, and the
// debug view (every bot, its state and its user id — which tells whoever can
// read it who the bots are) only on debug.addr, which config holds to
// loopback. On one shared address both are served.
func serve(ctx context.Context, cfg config.Config, m *metrics.Metrics, mgr *bot.Manager, log *slog.Logger) {
	start := func(addr string, m *metrics.Metrics, snapshots func() []state.Snapshot, showCards bool) {
		go func() {
			if err := metrics.Serve(ctx, addr, m, snapshots, showCards, log); err != nil && !errors.Is(err, context.Canceled) {
				log.Error("debug/metrics server stopped", "addr", addr, "err", err)
			}
		}()
	}
	switch {
	case cfg.Metrics.Addr != "" && cfg.Metrics.Addr == cfg.Debug.Addr:
		start(cfg.Metrics.Addr, m, mgr.Snapshots, cfg.Debug.ShowCards)
	default:
		if cfg.Metrics.Addr != "" {
			start(cfg.Metrics.Addr, m, nil, false)
		}
		if cfg.Debug.Addr != "" {
			start(cfg.Debug.Addr, nil, mgr.Snapshots, cfg.Debug.ShowCards)
		}
	}
}

func timingConfig(cfg config.Config) (timing.Config, error) {
	ranges, err := timing.ParseRanges(cfg.Timing.Ranges)
	if err != nil {
		return timing.Config{}, fmt.Errorf("timing.ranges: %w", err)
	}
	return timing.Config{
		Ranges:       ranges,
		MinReaction:  cfg.Timing.MinReaction,
		MaxReaction:  cfg.Timing.MaxReaction,
		SafetyMargin: cfg.Timing.SafetyMargin,
	}, nil
}

func newLogger(cfg config.Config) *slog.Logger {
	var level slog.Level
	if err := level.UnmarshalText([]byte(cfg.Log.Level)); err != nil {
		level = slog.LevelInfo
	}
	opts := &slog.HandlerOptions{Level: level}
	if cfg.Log.Format == "text" {
		return slog.New(slog.NewTextHandler(os.Stdout, opts))
	}
	return slog.New(slog.NewJSONHandler(os.Stdout, opts))
}

func logSimStats(ctx context.Context, srv *sim.Server, log *slog.Logger) {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s := srv.Stats()
			log.Info("simulation", "accounts", s.Accounts, "tables", s.Tables, "hands", s.HandsCompleted, "moves", s.Moves, "refusals", s.Refusals, "drops", s.Drops)
		}
	}
}
