package main

// The two table-catalogue tools the binary carries (owner, 23 Sep 2026: "all
// table related config store in database"), handled by main BEFORE run: they
// start no server, open no live store and log nothing on stdout.
//
//	gameplay -export-table-config   the SQL that makes the database hold the
//	                                catalogue the env keys compose — SQL alone
//	                                on stdout, so it can be piped into psql
//	gameplay -check-table-config    reads the database's catalogue WITHOUT
//	                                running a migration and judges it as a
//	                                TABLE_CONFIG_SOURCE=db boot would
//
// The switch of a deployment whose .env configures its tables is the pair of
// them: export with that .env (TABLE_CONFIG_SOURCE=env), pipe it into psql,
// check, then set TABLE_CONFIG_SOURCE=db and restart — so the database holds
// the menu the deployment plays today rather than the code's defaults.

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/joho/godotenv"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// Exit codes of -check-table-config (and of -export-table-config's refusals).
const (
	exitTablesClean    = 0 // every active row is usable
	exitTablesLeftOut  = 1 // the boot would leave rows out (and log each)
	exitTablesUnusable = 2 // the boot would fall back to the env composition, or the check could not run
)

// checkTableConfigTimeout bounds -check-table-config's connect and read.
const checkTableConfigTimeout = 15 * time.Second

// loadDotEnv applies ./.env as run does (godotenv never overrides a variable
// the process already has) and says what it did, for the tools' stderr. A
// missing file is not an error, as it is not for the server; a file that
// cannot be read or parsed is — the tools would otherwise describe a
// configuration the server does not run.
func loadDotEnv() (string, error) {
	path := ".env"
	if wd, err := os.Getwd(); err == nil {
		path = filepath.Join(wd, ".env")
	}
	err := godotenv.Load()
	switch {
	case err == nil:
		return "read " + path, nil
	case errors.Is(err, fs.ErrNotExist):
		return "no .env at " + path + ": the process environment only", nil
	default:
		return "", fmt.Errorf("cannot read %s: %w", path, err)
	}
}

// exportTableConfig is -export-table-config: the env keys (and the code's
// defaults for every key unset) composed exactly as a TABLE_CONFIG_SOURCE=env
// server composes them — config.GameConfig.EffectiveCatalogue with no
// catalogue loaded, whatever TABLE_CONFIG_SOURCE says, so the default engines
// and categories with the env's tables under them — written as the psql
// script db.ExportTableConfigSQL makes. stdout gets the script and nothing
// else; stderr gets where the configuration came from, which table keys are
// set (a warning when none is: that is the code's default catalogue, which
// the seed already holds), anything a db boot would leave out, and the psql
// command that applies it (with the search_path a schema other than public
// needs).
//
// A catalogue a db boot could not use at all — the harness's empty menu, say —
// is refused with nothing on stdout (exitTablesLeftOut, as for any bad
// configuration): piped into psql it would retire every table in the
// database, and the next db boot would fall back to the env composition.
func exportTableConfig(lookup config.Lookup, envNote string, now time.Time, stdout, stderr io.Writer) int {
	fmt.Fprintln(stderr, envNote)
	cfg, err := config.FromEnv(lookup)
	if err != nil {
		fmt.Fprintln(stderr, "error:", err)
		return exitTablesLeftOut
	}
	g := cfg.Game
	g.Catalogue = nil
	cat := g.EffectiveCatalogue()

	var composedFrom string
	if len(cfg.TableEnvKeysSet) == 0 {
		composedFrom = "the code's defaults (no table env key is set)"
		fmt.Fprintln(stderr, "warning: no table env key is set, so this is the code's default catalogue — which V1.0.1__seed.sql already holds on a fresh database. Export with the .env of the deployment you are switching.")
	} else {
		composedFrom = "the env keys " + strings.Join(cfg.TableEnvKeysSet, ", ")
		fmt.Fprintln(stderr, "table env keys set:", strings.Join(cfg.TableEnvKeysSet, ", "))
		if cfg.TableConfigSource == config.TableConfigSourceDB {
			fmt.Fprintln(stderr, "note: TABLE_CONFIG_SOURCE=db here; the export composes the env keys regardless.")
		}
	}

	check := cat
	check.Source = config.TableConfigSourceDB
	_, problems, err := check.Validate()
	for _, problem := range problems {
		fmt.Fprintln(stderr, "warning: a db boot would report:", problem)
	}
	if err != nil {
		fmt.Fprintf(stderr, "error: this catalogue could not run a lobby from the database (%v); nothing exported\n", err)
		return exitTablesLeftOut
	}

	// The script names its tables bare (db.ExportTableConfigSQL), so on any
	// schema but public psql must be told where they are.
	apply := `psql "$DATABASE_URL" -f <this file>`
	nonPublic := cfg.DB.Schema != "" && cfg.DB.Schema != "public"
	if nonPublic {
		apply = `PGOPTIONS='-c search_path=` + cfg.DB.Schema + `' ` + apply
	}
	header := []string{
		"King Teen Patti table configuration: gameplay -export-table-config, build " + version + ", " + now.UTC().Format(time.RFC3339),
		"Composed from " + composedFrom + ".",
		fmt.Sprintf("%d public tables, %d private templates, %d engines, %d categories.", len(cat.Public), len(cat.Private), len(cat.Engines), len(cat.Categories)),
		"Apply: " + apply,
		"Then: gameplay -check-table-config, set TABLE_CONFIG_SOURCE=db and restart.",
	}
	fmt.Fprint(stdout, db.ExportTableConfigSQL(cat, header))
	fmt.Fprintf(stderr, "exported %d public tables and %d private templates, under %d engines and %d categories\n",
		len(cat.Public), len(cat.Private), len(cat.Engines), len(cat.Categories))
	fmt.Fprintln(stderr, "apply with:", apply)
	if nonPublic {
		fmt.Fprintf(stderr, "PG_SCHEMA is %s, not public: the script names its tables bare, so psql must lead its search_path with %s — the PGOPTIONS above does that\n",
			cfg.DB.Schema, cfg.DB.Schema)
	}
	return exitTablesClean
}

// checkTableConfig is -check-table-config: DATABASE_URL / PG_SCHEMA opened
// WITHOUT migrations (db.Options.SkipMigrations — it may run beside a live
// server and changes nothing), the catalogue read (db.TableConfigs.Load) and
// judged (config.TableCatalogue.Validate) exactly as a TABLE_CONFIG_SOURCE=db
// boot judges it. stdout gets what a boot would play by; stderr every
// problem. Exit exitTablesClean when a boot would use every active row,
// exitTablesLeftOut when it would leave some out (and log each), and
// exitTablesUnusable when it would fall back to the env composition — or when
// the check could not read the database at all.
func checkTableConfig(ctx context.Context, lookup config.Lookup, envNote string, stdout, stderr io.Writer) int {
	fmt.Fprintln(stderr, envNote)
	cfg, err := config.FromEnv(lookup)
	if err != nil {
		fmt.Fprintln(stderr, "error:", err)
		return exitTablesUnusable
	}
	ctx, cancel := context.WithTimeout(ctx, checkTableConfigTimeout)
	defer cancel()
	database, err := db.Open(ctx, db.Options{
		URL:              cfg.DB.URL,
		Schema:           cfg.DB.Schema,
		PoolMax:          2,
		StatementTimeout: time.Duration(cfg.DB.StatementTimeoutMs) * time.Millisecond,
		SkipMigrations:   true,
		Logger:           util.NewLogger("warn", stderr),
	})
	if err != nil {
		fmt.Fprintf(stderr, "unusable: cannot open %s (schema %s): %v\n", db.Redact(cfg.DB.URL), cfg.DB.Schema, err)
		return exitTablesUnusable
	}
	defer database.Close()

	loaded, err := db.NewTableConfigs(database).Load(ctx)
	if err != nil {
		fmt.Fprintln(stderr, "unusable:", err)
		return exitTablesUnusable
	}
	valid, problems, err := loaded.Validate()
	for _, problem := range problems {
		fmt.Fprintln(stderr, "problem:", problem)
	}
	if err != nil {
		fmt.Fprintf(stderr, "unusable: %v — a TABLE_CONFIG_SOURCE=db server would run the env composition instead\n", err)
		return exitTablesUnusable
	}
	if cfg.TableConfigSource != config.TableConfigSourceDB {
		fmt.Fprintln(stderr, "note: TABLE_CONFIG_SOURCE resolves to env here, so a server with this environment does not read these rows.")
	}

	fmt.Fprintf(stdout, "table config in schema %s: %d engines, %d categories, %d public tables, %d private templates, %d problems\n",
		cfg.DB.Schema, len(valid.Engines), len(valid.Categories), len(valid.Public), len(valid.Private), len(problems))
	for _, engine := range valid.Engines {
		var codes []string
		for _, category := range valid.Categories {
			if category.Engine == engine.Code {
				codes = append(codes, category.Code)
			}
		}
		fmt.Fprintf(stdout, "  engine %-21s %s\n", engine.Code, strings.Join(codes, ", "))
	}
	for _, spec := range valid.Public {
		fmt.Fprintf(stdout, "  %-28s sort %d\n", spec.Key, spec.SortOrder)
	}
	for _, spec := range valid.Private {
		fmt.Fprintf(stdout, "  %-28s boot %d\n", spec.Key, spec.BootAmount)
	}
	if len(problems) > 0 {
		return exitTablesLeftOut
	}
	return exitTablesClean
}
