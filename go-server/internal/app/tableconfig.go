package app

// The table catalogue at boot and on the wire (owner, 23 Sep 2026: "all table
// related config store in database … the UI fetches it, stores it on the
// phone, and re-fetches it at every login"). New resolves it ONCE, before the
// socket layer, the REST handler and the RoomManager are built, and hands all
// three the one *config.Config that carries it; GET /api/tables serves what
// the RoomManager then enforces, and /health says where it came from.

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// tableConfigLoadTimeout bounds the boot's one read of the four configuration
// tables: a handful of small queries, still finite so a hung database cannot
// hold the process in "starting" forever.
const tableConfigLoadTimeout = 10 * time.Second

// TableConfigHealth is /health.tableConfig: where the tables this process
// plays by came from, and the version GET /api/tables and session:ready
// carry. Source is "db" (the configuration tables) or "env" (the env keys
// composed); Fallback is true when TABLE_CONFIG_SOURCE=db asked for the
// database and the boot could not use what it found there, so it runs the
// env composition instead (Source is then "env") — the one state an operator
// must go and fix.
type TableConfigHealth struct {
	Source   string `json:"source"`
	Version  string `json:"version"`
	Fallback bool   `json:"fallback"`
}

// resolveTableCatalogue settles cfg.Game's tables before anything is built
// from them, and returns what /health reports (Version is filled in once the
// RoomManager has computed it). cfg is New's own copy of Options.Config, so
// the caller's is never touched.
//
// TABLE_CONFIG_SOURCE=db: db.TableConfigs.Load (the active engines, their
// active categories and the active table_configs rows under both — so a
// category or an engine switched off hides its tables, on purpose and without
// a word) → TableCatalogue.Validate → one ERROR `table config row left out`
// per problem (an engine or a category this build cannot play, a category
// filed under the wrong engine, a table under a category left out, a row
// PostgreSQL accepted but the engine must not open: each is left out, and the
// boot carries on) → cfg.Game.WithCatalogue(valid). A catalogue that cannot
// run a lobby at all — no settings row, no public table, no private seen
// template (switching the seen category or the Teen Patti engine off does
// that), the read itself failing, no database — is one ERROR, and the server
// runs the env composition instead (Fallback): refusing to boot over a hand
// edit would turn an unrelated restart into a crash loop, and the composition
// is the menu the server ran before the catalogue existed. Table env keys set
// in this mode are ignored; one WARN names them.
//
// TABLE_CONFIG_SOURCE=env: cfg.Game is left as FromEnv composed it. With
// table env keys set — which is what makes an unset TABLE_CONFIG_SOURCE mean
// env — one WARN says how to move that menu into the database. (Config does
// not record whether the source was named or inferred, so the WARN also
// follows an explicit TABLE_CONFIG_SOURCE=env beside table keys, where it is
// the same advice.)
func resolveTableCatalogue(cfg *config.Config, database *db.DB, logger *slog.Logger) TableConfigHealth {
	if cfg.TableConfigSource != config.TableConfigSourceDB {
		if len(cfg.TableEnvKeysSet) > 0 {
			logger.Warn("table config comes from the env keys, not the database",
				"keys", cfg.TableEnvKeysSet,
				"hint", exportHint(cfg.DB.Schema))
		}
		return TableConfigHealth{Source: config.TableConfigSourceEnv}
	}
	if len(cfg.TableEnvKeysSet) > 0 {
		logger.Warn("table env keys are ignored in db mode",
			"keys", cfg.TableEnvKeysSet,
			"hint", "keep them for a rollback to a build that predates the table catalogue")
	}
	fallback := func(err error) TableConfigHealth {
		logger.Error("table config in the database is unusable; running the env composition instead",
			"error", err.Error(),
			"hint", "gameplay -check-table-config lists every problem")
		return TableConfigHealth{Source: config.TableConfigSourceEnv, Fallback: true}
	}
	if database == nil || database.Pool == nil {
		return fallback(errors.New("no database to read table_configs from"))
	}
	ctx, cancel := context.WithTimeout(context.Background(), tableConfigLoadTimeout)
	defer cancel()
	loaded, err := db.NewTableConfigs(database).Load(ctx)
	if err != nil {
		return fallback(err)
	}
	valid, problems, err := loaded.Validate()
	for _, problem := range problems {
		logger.Error("table config row left out", "problem", problem)
	}
	if err != nil {
		return fallback(err)
	}
	cfg.Game = cfg.Game.WithCatalogue(valid)
	return TableConfigHealth{Source: config.TableConfigSourceDB}
}

// exportHint is how an env-sourced deployment moves its tables into the
// database: export them with the .env it runs, apply, check, switch. The
// export names its tables bare, so on a schema other than public psql must
// lead its search_path with that schema.
func exportHint(schema string) string {
	psql := `psql "$DATABASE_URL"`
	if schema != "" && schema != "public" {
		psql = `PGOPTIONS='-c search_path=` + schema + `' ` + psql
	}
	return "to move it into the database, from the directory of this .env: ./bin/gameplay -export-table-config | " + psql +
		", then ./bin/gameplay -check-table-config, set TABLE_CONFIG_SOURCE=db and restart"
}

// tablesHandler is GET /api/tables: the table catalogue the RoomManager
// enforces (game.TableConfigPayload) — every table, every private template,
// and the engines and categories they are filed under — served from memory,
// never a fresh database read, which could show a client an edit this process
// does not play by until its next start. Public: a client fetches it before
// it has signed in, and it holds nothing a lobby card does not.
//
// A client keeps the body across sessions and asks again at every login, so
// the response is revalidated rather than cached blind: `Cache-Control:
// no-cache` and `ETag: "<version>"`, and a request whose If-None-Match names
// that version is answered 304 with no body. The version is the one
// session:ready.config.tableConfigVersion carries, so a client that holds it
// need not ask at all.
func (a *App) tablesHandler(w http.ResponseWriter, r *http.Request) {
	payload := a.rooms.TableConfig()
	w.Header().Set("Cache-Control", "no-cache")
	if payload.Version != "" {
		etag := `"` + payload.Version + `"`
		w.Header().Set("ETag", etag)
		if etagMatches(r.Header.Get("If-None-Match"), etag) {
			w.WriteHeader(http.StatusNotModified)
			return
		}
	}
	auth.WriteJSON(w, http.StatusOK, payload)
}

// etagMatches is If-None-Match's weak comparison (RFC 9110 §13.1.2): "*", or
// any listed entity tag equal to etag once a W/ prefix is set aside.
func etagMatches(header, etag string) bool {
	for _, candidate := range strings.Split(header, ",") {
		candidate = strings.TrimSpace(candidate)
		if candidate == "*" {
			return true
		}
		if strings.TrimPrefix(candidate, "W/") == etag {
			return true
		}
	}
	return false
}
