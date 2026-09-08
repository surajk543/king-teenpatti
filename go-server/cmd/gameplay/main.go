// Command gameplay is the King Teen Patti game server — the Go port of
// `node server/src/index.js`. Single process; Go's scheduler uses every core.
//
// Boot sequence (index.js entrypoint block):
//  1. godotenv.Load() if a .env exists in the working directory (Node:
//     `import 'dotenv/config'`); missing file is not an error;
//  2. config.Load() — fails fast on production misconfiguration;
//  3. logger from LOG_LEVEL;
//  4. db.Open (schema bootstrap);
//  5. app.New + Start;
//  6. on SIGINT/SIGTERM: log `shutting down {signal}`, app.Shutdown with an
//     8 s budget, db.Close, exit 0 — or exit 1 when the budget runs out.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
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

func main() {
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

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	database, err := db.Open(ctx, db.Options{URL: cfg.DB.URL, Schema: cfg.DB.Schema, PoolMax: cfg.DB.PoolMax, Logger: logger})
	if err != nil {
		return err
	}

	server, err := app.New(app.Options{Config: cfg, DB: database, Logger: logger})
	if err != nil {
		database.Close()
		return err
	}

	// Not ported yet: the porter of cmd/gameplay replaces this block with
	//   errCh := make(chan error, 1); go func() { errCh <- server.Start(ctx) }()
	//   select { case err := <-errCh: return err; case <-ctx.Done(): }
	//   logger.Info("shutting down", "signal", ...)
	//   sctx, cancel := context.WithTimeout(context.Background(), shutdownBudget); defer cancel()
	//   err = server.Shutdown(sctx); database.Close(); return err
	_ = server
	panic("not ported: main.run")
}
