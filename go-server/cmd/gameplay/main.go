// Command gameplay is the King Teen Patti game server — the Go port of
// `node server/src/index.js`. Single process; Go's scheduler uses every core.
//
// Boot sequence (index.js entrypoint block, extended by LIVE_STATE_PLAN.md):
//  1. godotenv.Load() if a .env exists in the working directory (Node:
//     `import 'dotenv/config'`); missing file is not an error;
//  2. config.Load() — fails fast on production misconfiguration;
//  3. logger from LOG_LEVEL;
//  4. db.Open (schema bootstrap);
//  5. app.New: opens the live store (REDIS_URL set and unreachable → exit 1),
//     starts the durable snapshot writer, rebuilds the tables the store (or
//     game_states) holds, refunds orphaned pots, holds the restored seats;
//     then Start opens the listener;
//  6. on SIGINT/SIGTERM: log `shutting down {signal}`, app.Shutdown with an
//     8 s budget (tables suspended into Redis, or settled without it; the
//     final game_states flush; the store closed last), db.Close, exit 0 — or
//     exit 1 when the budget runs out.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"

	"github.com/joho/godotenv"

	"github.com/surajk543/king-teenpatti/go-server/internal/app"
	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// shutdownBudget mirrors Node's `setTimeout(() => process.exit(1), 8000)`.
const shutdownBudget = 8 * time.Second

// errShutdownTimedOut is returned when the budget runs out; main exits 1, as
// Node's hard timer did.
var errShutdownTimedOut = errors.New("shutdown did not finish within 8s")

// version is the build identifier stamped by ops/build.sh
// (`-ldflags "-X main.version=$(git describe --always --dirty)"`); a plain
// `go build` leaves it at "dev". Printed by `gameplay -version` and logged once
// at startup so `journalctl -u gameplay` shows which build is running.
var version = "dev"

// versionString is the `-version` output: `gameplay <version> <go> <os>/<arch>`.
func versionString() string {
	return fmt.Sprintf("gameplay %s %s %s/%s", version, runtime.Version(), runtime.GOOS, runtime.GOARCH)
}

func main() {
	showVersion := flag.Bool("version", false, "print the build version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println(versionString())
		return
	}
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// run is main without os.Exit so it can be exercised from a test.
func run() error {
	_ = godotenv.Load() // optional .env, exactly like dotenv/config

	cfg, err := config.Load()
	if err != nil {
		return err
	}
	logger := util.NewLogger(cfg.LogLevel, os.Stdout)
	logger.Info("gameplay build", "version", version, "go", runtime.Version())

	// A signal is observed by name so the log line matches Node's
	// `shutting down {signal: 'SIGTERM'}`.
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(signals)

	ctx := context.Background()
	database, err := db.Open(ctx, db.Options{URL: cfg.DB.URL, Schema: cfg.DB.Schema, PoolMax: cfg.DB.PoolMax, StatementTimeout: time.Duration(cfg.DB.StatementTimeoutMs) * time.Millisecond, Logger: logger})
	if err != nil {
		return err
	}

	// app.New also opens the live store from cfg (REDIS_URL, LIVE_INSTANCE_ID)
	// and runs the restart sequence; a store that is configured but
	// unreachable, or that cannot be listed, is a startup failure.
	server, err := app.New(app.Options{Config: cfg, DB: database, Logger: logger, Version: version})
	if err != nil {
		database.Close()
		return err
	}

	errCh := make(chan error, 1)
	go func() { errCh <- server.Start(ctx) }()

	var signalName string
	select {
	case err := <-errCh:
		// The listener failed (port in use, …) or closed on its own.
		database.Close()
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	case sig := <-signals:
		signalName = sig.String()
		if s, ok := sig.(syscall.Signal); ok {
			switch s {
			case syscall.SIGINT:
				signalName = "SIGINT"
			case syscall.SIGTERM:
				signalName = "SIGTERM"
			}
		}
	}
	logger.Info("shutting down", "signal", signalName)

	// Node: io.close(); await rooms.shutdown(); server.close(); closeDatabase();
	// exit 0 — with a hard exit 1 after 8 s if any step hangs.
	sctx, cancel := context.WithTimeout(context.Background(), shutdownBudget)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- server.Shutdown(sctx) }()
	select {
	case err := <-done:
		if err != nil {
			logger.Error("shutdown finished with errors", "error", err.Error())
		}
	case <-sctx.Done():
		return errShutdownTimedOut
	}
	// pgxpool.Close blocks until every acquired connection is released. A
	// table actor still inside a hung statement never releases its own, so
	// the close is bounded by the same budget — Node's process.exit(1) timer
	// covered this step too.
	closed := make(chan struct{})
	go func() {
		database.Close()
		close(closed)
	}()
	select {
	case <-closed:
		return nil
	case <-sctx.Done():
		return errShutdownTimedOut
	}
}
