# CLAUDE.md — King Teen Patti

Project context for AI coding sessions. Read this before touching anything. It records what the
code does, why it is shaped the way it is, and the traps that have already bitten people here.

> **The Node.js server was removed from this repository on 8 Sep 2026.** `server/` (Node 22 +
> Express + Socket.IO + `pg`) is gone from `master`; the Go server in `go-server/` is the only
> server. The Node code lives in git history — `git log -- server/`; the last commit that carries the
> tree is `c19963b` (`git checkout c19963b -- server` restores it; the `multi_node` branch also still
> has it). **§5–§7 remain the authoritative description of the game's behaviour** — the Go port
> reproduces it wire-for-wire, and `go-server/DECISIONS.md` / `go-server/PORT_PLAN.md` §9 list the
> only deliberate differences — but their file citations (`table.js`, `roomManager.js`,
> `socket/index.js`, `db/ledger.js`, `auth/routes.js`, `config/index.js`, `metrics/index.js` …) name
> the *removed* Node source. Translate with `go-server/PORT_PLAN.md` §2; the short version:
> `table.js` → `internal/game/table.go` (+ `view.go` for `serializeFor`/`betOptions`, `events.go`,
> `snapshot.go`), `roomManager.js` → `internal/game/roommanager.go`, `handRank.js`/`deck.js`/`chat.js`
> → `internal/game/{handrank,deck,chat}.go`, `socket/index.js` → `internal/socket/{handler,wire}.go`,
> `auth/{routes,providers,tokens}.js` → `internal/auth/{http,handlers,providers,tokens}.go`,
> `db/{index,ledger,users}.js` → `internal/db/{db,ledger,users}.go` (+ `migration/V1.0.0__baseline.sql`, `V1.0.1__seed.sql`),
> `config/index.js` → `internal/config/config.go`, `metrics/index.js` →
> `internal/metrics/{metrics,names}.go`, `src/index.js` → `cmd/gameplay/main.go` + `internal/app/`.
> Node's `_private` methods keep their names minus the underscore in Go (`_endHand` → `endHand`).
> The bots/ramp/parity tooling moved to `tools/` (a Node package). §14 describes the Go server itself.

> **Read the working tree, never `git show HEAD:…`**, to learn current behaviour — uncommitted work is
> normal here (see §13).

---

## 1. What this project is

A turn-based multiplayer **Teen Patti** (3-card Indian poker) game:

| Part | Path | Status |
|---|---|---|
| **Game server** | `go-server/` | **The server** — live in production since `go-server/ops/DEPLOY.md` was run (Sept 2026). Go 1.27, one static binary, PostgreSQL via `pgx` (**16.15 on production**, 18.6 on the dev box — checked 29 Sep 2026). Database-first money model (§5). Wire-identical to the Node original it replaced — same protocol, JWTs, schema, ledger rows, `/health`, `game_*` metrics (141/141 black-box parity suites). §5–§7 describe its behaviour; §14 its shape. **Since 19 Sep 2026 it also runs the Poker family** (§6.5): 3-Card Poker, 5-Card Draw, Texas Hold'em and Omaha as rooms beside the Teen Patti tables, in `internal/poker/`. **Since 23 Sep 2026 its table configuration can live in PostgreSQL** (owner: "all table related config store in database"): the engines (Teen Patti, Poker), the categories under them, and every lobby table with every figure it plays by, read once at boot when `TABLE_CONFIG_SOURCE=db` (§7.3, §7.4) and served to the app as `GET /api/tables` (§7.2). Configuration only — game state stays in Redis. |
| Node.js server | *(removed)* | The original implementation, removed from the repo on 8 Sep 2026 (`git log -- server/`, last commit `c19963b`; `multi_node` branch). Its behaviour is what §5–§7 document; its file names are what those sections cite. **No longer a rollback target at all** (12 Sep 2026): it reads and writes `users.avatar_choice`, which the schema dropped for `active_picture_id`, and knows nothing of the picture-catalogue tables — so it cannot run against this database. `ops/rollback-to-node.sh` was deleted rather than left as a recovery script that would fail when used; rolling back now means the previous **Go** tag (DEPLOY.md §5). |
| Mobile client | `flutter-client/` | **The live client.** Flutter 3.44 / Dart 3.12, Material 3 via FlexColorScheme. Android is the shipping platform; `ios/` exists and is configured (`docs/ios-setup.md`) but has never been compiled — there is no macOS here. |
| Browser client | `go-server/public/` | Zero-build vanilla-JS reference client served at `/` by the Go binary (`PUBLIC_DIR`) — **in dev only; production hides it** (`ROOT_REDIRECT=/dashboard/`, §7.4/§9) and serves just `privacy/`, `profiles/` from that dir. **Lags behind** — no sideshow, kick, rename, entry-cap or Indian-numbering UI. |
| Tools | `tools/` | Small Node ≥ 20 package (`npm install` first): `npm run bot` (practice bots), `npm run ramp` (staged load test), `npm run parity` / `parity:diff` (black-box suites in `tools/parity/`). Clients of the server; also lend `node_modules` to two Go interop tests. `tools/lottie/flatten_orientation.py` (Python 3, stdlib) flattens a Lottie's 3D orientation and `tools/lottie/bake_loop_expressions.py` writes its `loopOut()` expressions out as keyframes, both for the phone players (§12.3). `tools/tables/make_table_pictures.py` (Python 3, stdlib) draws the 16 SVG table pictures in `go-server/public/tables/` — eight designs, a day and a night file each (§7.3); `tools/tables/make_background_pattern.py` re-encodes the owner's Background Pattern Lottie (`background-pattern.json`, 122 KB) into the two 31 KB Drive files beside it, day and night (§7.3); `tools/tables/make_thank_you_day.py` recolours the owner's Thank You Lottie into its day file, deep gold for the light ground (§7.3). |
| **Bot fleet** | `bot-play/` | The resident bots that keep production's lobby populated (`bot-play.service` on the game host, loopback to `:3000`). **Go since 27 Sep 2026** (module `github.com/surajk543/king-teenpatti/bot-play`, one static binary; the Node fleet it replaced is in git history, tagged `bot-play/v1.0.0`): `BOT_COUNT` bots (320 in the unit, about 200 seated at once: 30–50 at each of Seen 200, Seen 50,000, Blind 200, Blind 50,000 and Variation 50,000 — `BOT_LOBBY_TABLES`, `BOT_FLEET_PER_TABLE=30,50`, owner 27 Sep 2026), guest devices `botplay-<6 digits>` the server marks `is_bot`, each on its own goroutine, event loop and websocket-only Socket.IO connection, in sessions of play with rests between. Six personality families (CAUTIOUS … BEGINNER) stable per identity, blind/seen play, raises up the server's ladder, hand strength from a copy of `handrank.go` pinned by a fingerprint of all 22,100 hands (variation hands read from the server's `you.hand`), log-normal reaction times ending 3 s inside the turn clock, tables from `GET /api/tables`, chat under a per-table budget, a lost ack resent with the same `actionId`. `go run ./cmd/bot-play` (`BOT_MODE=simulation BOT_SEED=12345` runs an in-process stand-in server), `go test -race ./...`; `bot-play/README.md` is the reference. Separate from `tools/bot.js`, the practice bots for manual testing. |
| Load reports | `docs/load-reports/` | ramp-test HTML + JSON (the 2026‑09‑08 production runs, 1,000 → 4,000 players). |
| Unity client | `unity-client/` | **Removed** (Sept 2026). A JS port of its Socket.IO parser survives as `tools/parity/lib/csharpJsonPort.js` and still exercises the raw wire protocol. |
| Brief | `Requirements.txt` | 34 numbered requirements at lines 6–88 (**there is no #11**). Code comments cite these ("Requirement 22"). |
| Docs | `docs/ios-setup.md` (what a Mac still has to do), `README.md`, `go-server/README.md`, `go-server/PORT_PLAN.md`, `go-server/DECISIONS.md`, `go-server/PORT_NOTES/` (incl. `specs/spec-socket-protocol.md`), `go-server/ops/DEPLOY.md`, `steps.txt` | `CLAUDE.md` is the detailed reference. |

The server is the single authority: it deals, shuffles with `crypto/rand` (Node: `crypto.randomInt`), validates every bet
against a ladder it recomputes itself, decides winners, and redacts state per viewer so a client never
receives a card or a hidden stack it should not see. Clients only render snapshots and forward intent.

---

## 2. Repository layout

```
king-teenpatti/
├── CLAUDE.md                     this file
├── README.md                     project overview
├── Requirements.txt              the numbered brief (1–34, no 11)
├── steps.txt                     the six-line production deploy routine (tracked)
├── recordings/                   empty local dir (no root .gitignore; git doesn't show it)
├── docs/load-reports/            ramp-test reports, HTML + JSON (2026‑09‑08 production runs; formerly server/loadtest-report/)
├── go-server/                    THE server (§14): Go 1.27, module github.com/surajk543/king-teenpatti/go-server
│   ├── cmd/gameplay/main.go      entrypoint: godotenv .env → config → db → app → listen; SIGTERM = graceful max(8 s, statement timeout + 5 s); -version
│   │                         tableconfig.go: -export-table-config (the env-composed table catalogue as a psql script on stdout) and
│   │                         -check-table-config (reads the database's catalogue WITHOUT migrating, judges it as a db boot would; exit 0/1/2) — both run before the server, §4
│   │                         migrate.go: -migrate (29 Sep 2026) — applies every embedded migration through the SAME db.Open a boot uses (db.Options.Applied
│   │                         reports each script; db.MigrationError names a failing one), prints them, exits 0/1; no Redis, listener or jobs; deploy.sh runs it
│   ├── internal/
│   │   ├── config/config.go      ALL env → one immutable Config (Defaults(); strict integer parsing); parse.go;
│   │   │                         tables.go = the table catalogue contract (23 Sep 2026): TABLE_CONFIG_SOURCE, TableEnvKeys, Categories, EngineOf,
│   │   │                         TableEngine/TableCategory/TableSettings/TableSpec, TableCatalogue{Engines, Categories, Settings, Public, Private},
│   │   │                         GameConfig.Spec (THE answer to "what does a new table of this category and boot play by"), HasPrivate, FromDatabase,
│   │   │                         EffectiveCatalogue, WithCatalogue, Validate (leaves a bad row out with a reason), SameRules
│   │   ├── game/
│   │   │   ├── room.go           the Room interface every table implements (Teen Patti AND poker; RulesSpec — what a room plays by, from its frozen config), RoomFactory/RoomSpec (.Table = the resolved TableSpec)/RoomDeps/RoomHooks, AsTable (§6.5)
│   │   │   ├── actor.go          the shell a room is built on: Actor (one goroutine, run/post), LiveState (Redis snapshot + fence), Settler (the hand-end retry chain)
│   │   │   ├── table.go          THE Teen Patti rules engine (embeds the three above; Table, run(), every Node _method minus the underscore)
│   │   │   ├── view.go           serializeFor / betOptions / turnOptions / summary — the redacted wire structs
│   │   │   ├── events.go         Listener (one method per table event) + payload structs
│   │   │   ├── snapshot.go       the server-side full state (cards, bets, deadlines) saved to Redis; never sent to clients
│   │   │   ├── roommanager.go    lobby menu, quick-join, switch, consolidation, sweeper, draining (roommanager_live.go: restore → drainReason); injects the Ledger
│   │   │   ├── tablespec.go      a Teen Patti TableConfig built from a config.TableSpec (tableConfigFromSpec) and back (Table.RulesSpec)
│   │   │   ├── tableconfig.go    the menu rows (each entry with its Spec), TableConfigPayload — the GET /api/tables body, engines included — and its version (sha256)
│   │   │   ├── handrank.go       Evaluate/Compare/PickWinner — the ONE hand ranking
│   │   │   ├── variation.go      Variation Teen Patti's rules (§6.4): the six variations as a wild rule + a comparison direction laid over Evaluate
│   │   │   ├── table_variation.go  the variation WINDOW: who chooses, the server's clock, closeVariation (exactly once), SelectVariation, snapshot/restore
│   │   │   ├── deck.go           52 cards, crypto/rand shuffle, 2-char wire codes ("As","Td")
│   │   │   ├── chat.go           in-memory per-room chat buffer (actor-owned)
│   │   │   ├── constants.go      Category / TableState / SeatState / Action / WinReason + verbatim messages
│   │   │   ├── errors.go         GameError, every snake_case code and refusal message
│   │   │   ├── ledger.go         Ledger interface (Checkpoint/Settle — the three checkpoints, §5.1) + MemoryLedger for unit tests
│   │   │   ├── clock.go          Clock interface, RealClock, Millis;  testclock/ = deterministic clock (Advance)
│   │   │   └── *_test.go         table, tablerules, sideshow, settlement, roommanager, handrank, deck, chat, wire, tablecatalogue, review_*, interop (needs NODE_REFERENCE_DIR)
│   │   ├── poker/                THE POKER FAMILY (§6.5; Go only, owner 19 Sep 2026): variant.go (the four VariantConfigs, streets, actions, win reasons),
│   │   │                         eval5.go (Evaluate5 / BestOf / BestHoldem / BestOmaha — the five-card ranking), eval3.go (3-Card Poker's, over game.Evaluate),
│   │   │                         pot.go (SidePots, Award), table.go (the room: seats, join/leave, clocks, the three checkpoints), hand.go (the deal, the streets,
│   │   │                         every move, the showdown, settle), flow_threecard.go (against the house), view.go (TableView — the redacted wire), events.go
│   │   │                         (poker.Listener + payloads), snapshot.go ("game":"poker" first), factory.go (RoomFactory, ConfigFor/ConfigFromSpec, the menu entry), errors.go
│   │   ├── sio/                  our own Engine.IO v4 + Socket.IO v5 server, websocket only (protocol.go, conn.go, server.go)
│   │   ├── socket/               the game protocol on sio: handler.go (Attach, guard, one method per event, grace, resume offers), wire.go (every event/ack), payload.go,
│   │   │                         poker.go (poker:action in, the poker:* events out — the Handler's poker.Listener); testclient/
│   │   ├── appversion/           the app version gate (28 Sep 2026, §7.2): semver.go (Parse/Compare — the ONE version comparison), rules.go (Evaluate: NORMAL/SOFT_UPDATE/FORCE_UPDATE/MAINTENANCE, the platforms, LegacyMinClientBuild), source.go (the app_versions rows behind a TTL cache), gate.go (Gate.Admit/Check, the refusal and the GET /api/app-config body, the logs)
│   │   ├── auth/                 tokens.go (JWT HS256), providers.go (Google/guest/fake; Facebook commented out — switched off 23 Sep 2026, §7.2), http.go (routes, RequireAuth, WriteError), handlers.go (the 8 REST handlers), text.go, reports.go (Report Player's POST /api/reports and GET /api/reports/limit, §7.2), rewardprograms.go (GET /api/reward-programs and POST /api/reward-programs/claim, §7.2)
│   │   ├── db/                   db.go (pgxpool, search_path as connection param, WithTx, DropSchema, Migrations, Options.SkipMigrations), migration/ (embedded, Flyway-named V<version>__<name>.sql, applied in version order — the founding PAIR since 23 Sep 2026: V1.0.0__baseline.sql = all DDL (users.is_bot, chip_ledger.game/variant with the guarded blocks that add them to an older database, the four table-configuration tables) and V1.0.1__seed.sql = DML (the 45 pictures, the engines and categories, table_settings, the table_configs rows); since 28 Sep 2026 DML-only seeds may follow them, V1.0.2__seed-festive-capybara.sql the first (Festive Capybara) — §7.3), ledger.go (THE money transactions: Checkpoint / Settle), users.go (login upsert, rewards, names, the worn picture), pictures.go (the catalogue, ownership and the chip purchase), tableconfigs.go (TableConfigs.Load — the table catalogue as the database holds it — and ExportTableConfigSQL), luckydraw.go (the Lucky Draw: State, Spin — draw, grant and record in one transaction, §7.3), reports.go (player_reports: Submit — the limits and the insert in one transaction, §7.3), rewardprograms.go (the reward programs, §7.3: State and Claim — the period, the streak and the calendar day worked out in Go from the claims, one transaction a program) and grant.go (grantReward — the ONE grant of a reward of any kind, the Lucky Draw's and the programs'); dbtest/
│   │   ├── metrics/              names.go (every game_* metric), metrics.go (registry, Bind*, Handler, HTTPMiddleware, SafeLabel)
│   │   ├── app/                  app.go (mux, REST, socket endpoint, Start/Shutdown), health.go, static.go (PUBLIC_DIR + embedded assets/socket.io.min.js),
│   │   │                         tableconfig.go (resolveTableCatalogue — the catalogue settled once, before anything is built from it; GET /api/tables; /health.tableConfig)
│   │   └── util/                 UUID, RoomCode, slog JSON logger
│   ├── public/                   browser client (index.html, client.js, style.css, theme.css) + profiles/ (15 Noto Emoji animal SVGs, Apache 2.0) + tables/ (16 generated SVG table pictures, §7.3; served in production like profiles/) + levels/ (Level 1's art with its loop baked, §6.6)
│   ├── .env.example              every env key the server reads, with defaults (+ Go-only PG_STATEMENT_TIMEOUT_MS)
│   ├── ops/                      deploy.sh (the one-command deploy of a tag, §14.3), build.sh, release.sh, prod-version.sh, gameplay-go.service, install-go-server.sh, install-monitoring.sh, lib.sh, DEPLOY.md
│   │   └── monitoring/           Prometheus + Grafana + alerts + nginx bundle, MONITORING.md (formerly server/ops/monitoring)
│   ├── PORT_PLAN.md / DECISIONS.md / PORT_NOTES/   architecture + Node→Go file map + concurrency rules; every settled ambiguity; per-package port notes + specs/ (cite the removed Node source)
│   ├── POKER_PLAN.md             the Poker family's design report (10 sections: what is reused, what was generalised, the events, the state, the risks, the phases)
│   ├── bin/                      build output (git-ignored: bin/, .env, *.log)
│   └── go.mod, go.sum
├── tools/                        Node package (npm install here first): bot.js, ramptest.mjs, parity.mjs, parity-diff.mjs
│   ├── package.json              scripts: bot / ramp / parity / parity:diff; deps socket.io-client, ws, pg, jsonwebtoken
│   └── parity/                   black-box suites (game, money, lobby, stakes, rest, protocol, resume, invalid, metrics, variation, poker) + lib/ (harness, launch, raw client,
│                                 csharpJsonPort.js, poker5.mjs — an independent five-card and three-card evaluator, the poker suite's oracle)
├── bot-play/                     the resident bot fleet — Go since 27 Sep 2026, module github.com/surajk543/king-teenpatti/bot-play (the Node
│   │                             fleet is in git history, tag bot-play/v1.0.0); README.md is its reference
│   ├── cmd/bot-play/main.go      -config (default configs/bot.yaml) / -version; server or simulation mode; waits for GET /api/tables;
│   │                             builds the shared bot.Deps; SIGINT/SIGTERM → every bot finishes its hand and leaves (60 s, then hard)
│   ├── configs/bot.yaml          every key at its default, its env override named beside it
│   ├── internal/
│   │   ├── config/               config.go (Default, Load: defaults → YAML → env → Validate), yaml.go (strict walk: unknown key / wrong
│   │   │                         type / two spellings stop the boot naming the line), env.go (EnvKeys), validate.go (device prefix must
│   │   │                         start botplay-, debug addr loopback only, dev_replenish simulation only)
│   │   ├── protocol/             wire.go (events, payloads, codes), transport.go (API / Dialer / Session — the server and the simulator both implement them)
│   │   ├── bot/                  identity.go (botplay-<%06d>, name, FNV seed → personality), bot.go (Bot, Deps), lifecycle.go (Run: sessions,
│   │   │   │                     sign-in, reconnect), play.go (the event loop's handlers: turn, resend with the same actionId, sideshow,
│   │   │   │                     variation, 5-Card pick, hand end, leave/search/join/switch, chat), manager.go (staggered start, graceful
│   │   │   │                     Stop), fleet.go (the process's registry of its own bots' user ids and seats), scheduler.go (one timer a bot)
│   │   │   ├── state/            state.go (the lifecycle state machine, Session, Snapshot), opponents.go (per-opponent reads)
│   │   │   ├── strategy/         personality.go (six families, DefaultProfiles, ApplyTuning), teen_patti.go (Decide, Legal, imperfections,
│   │   │   │                     SideshowAnswer), blind.go, seen.go, variation.go (ChooseVariation, ChoosePlayedCards)
│   │   │   ├── decision/         hand_strength.go (the classic ranking; TestRankingIsTheServers = a SHA-256 of all 22,100 hands' server
│   │   │   │                     scores), evaluator.go (variation hands from you.hand), variation_tables.go, betting.go (rungs, RaiseAmount), risk.go
│   │   │   ├── table/            finder.go (the menu: GET /api/tables, refreshed by session:ready's tableConfigVersion), selector.go, switcher.go (AfterHand reasons)
│   │   │   ├── timing/           human_delay.go (DefaultRanges, For: log-normal, safety margin before every deadline), reaction.go
│   │   │   ├── interaction/      chat.go (moments, probabilities, cooldown, TableBudget), messages.go, emote.go (NoEmotes: chat:emoji needs owned emojis)
│   │   │   └── connection/       websocket.go (Engine.IO v4 / Socket.IO v5, websocket only, slow-consumer policy), rest.go, reconnect.go (Backoff)
│   │   ├── sim/                  BOT_MODE=simulation: an in-process stand-in server (simplified rules, chips conserved; never decides a real hand)
│   │   ├── metrics/              bot_* Prometheus series (label vocabularies, no ids), serve.go (/metrics, /healthz, /debug/bots[/{bot}])
│   │   └── clock/, rng/          Real/Fake clock; seeded streams (rng.Derive(seed, bot number))
│   ├── ops/                      build.sh (static, stamps `git describe --match 'bot-play/v*'` → bin/bot-play), install.sh, bot-play.service
│   ├── Dockerfile                distroless static image (docker build -t bot-play bot-play/)
│   └── go.mod, go.sum            go 1.27; gorilla/websocket, prometheus client_golang, yaml.v3
└── flutter-client/
    ├── pubspec.yaml              package name `teenpatti` (imports are package:teenpatti/...), sdk ^3.12.2
    ├── lib/
    │   ├── main.dart             landscape lock, Provider root, screen switch (no Navigator); runApp first, `state.start()` behind the splash
    │   ├── screens/splash_screen.dart  `Screen.splash` (initial): assets/app_icon.svg + "powered by sungamestudio.com"; held ≥ `GameState.minSplash` (1.4s), then login/lobby (or straight to the table if a snapshot arrived)
    │   ├── state/game_state.dart the ONE ChangeNotifier + formatChips / NumberSystem globals
    │   │     `resuming` veil on cold start (start() → _beginResume → session:ready.resume ? joinByCode : 900ms wait; room:joined lifts it with t.welcomeBack)
    │   │     `appVersion` from package_info_plus (settings drawer footer); formatChips abbreviates >100000 to TWO decimals (3.24 Lakh, 32.77 Crore)
    │   │     Chat pacing (client-side): `GameState.sendChat()` returns bool, starts `chatCooldown` (4s); `canChat`/`chatCooldownLeft` drive `_ChatCountdown` (ring + seconds) in the rail icon and the send key; `_ChatDrawer._send` unfocuses and pops the drawer after a successful send.
    │   │     `tableScaffold`/`lobbyScaffold` GlobalKeys: main.dart `_BackGuard` closes an open drawer/endDrawer first; only then asks leave (table) / quit (lobby).
    │   │     `_armSeatCheck()`: on a warm `session:ready` while `room != null`, if no snapshot follows within 1.8s the seat is gone (server restarted / room closed) → lobby + t.tableLost. Cold start uses the `resuming` veil instead.
    │   ├── theme/app_theme.dart `AppTheme.paletteFor(scheme, category, bootAmount)` → TablePalette: one accent a game mode at every stake (24 Sep 2026) — seen=gold, blind=sapphire(tertiary), variation=violet (`violetPalette`), poker=teal; `privatePalette` = emerald (scheme.primary); `TablePalette.ink` = the accent as type on a card; used by lobby card, felt, _CategoryTag ("BLIND · 5,000")
    │   ├── screens/table_screen.dart `_BlindDots` (the blind bets left, as dots under "See cards" on the viewer's own hand — the missed-turns box over the Pack key was removed 13 Sep 2026, owner), `_BetFlights` (chip from seat to pot on every contributed increase), `_AmbientGlow`
    │   ├── screens/lobby_screen.dart `_DriftingChips` ambient background
    │   └── widgets/seat_pod.dart `BubbleSide {above,left,right}`: chat bubble hung off the column END in a zero-height OverflowBox — rim seats grow it up over their own cards/badge (max 1.7×podW, pointer tail up at the pod), the viewer's grows up from the column top (2.1×podW, tail down). Pods paint AFTER tag/pot/status in the felt Stack so a bubble is never hidden.
    │   │     GameState: bubbles hold `bubbleFor` = 8s; a second line from the same player queues in `_bubbleQueue` and shows when the first expires; `_clearBubbles()` on leave/kick.
    │   │     `_CategoryTag` text shrinks via FittedBox (slot w*0.30).
    │   ├── net/game_connection.dart  Socket.IO streams; every move carries a fresh actionId
    │   ├── net/api_client.dart   REST; tableConfig({version}) = GET /api/tables with If-None-Match (304 before decoding, 404 = a server with no catalogue, 12 s timeout)
    │   ├── models/dtos.dart      wire DTOs mirroring server JSON (LobbyTable's catalogue figures and engine, GameConfig.fromCatalogue/engines/privateTables/tableConfigVersion, TableEngineInfo)
    │   ├── state/table_config_cache.dart  TableConfigCache (SharedPreferences `tableConfig`: the phone's copy of GET /api/tables) + MenuPrecedence (pure: which menu the lobby shows) — §8.1
    │   ├── screens/{login,lobby,table}_screen.dart; screens/poker_table_screen.dart (the poker felt, mounted by table_screen when room.isPoker — §8.4); screens/lucky_draw_screen.dart (the Lucky Draw's wheel, prizes and spin — §8.4); screens/reward_programs_screen.dart (the login streaks and calendar rewards — §8.4)
    │   ├── widgets/table_chrome.dart  the chrome both felts share (rail, drawers, keys, wallet, reconnecting veil), moved out of table_screen.dart
    │   ├── theme/table_theme.dart  the table's type scale and tokens: TableType/SeatType, TableSpace, TableScrim, TableInk, TableAmbient (§8.4); widgets/edge_fade.dart EdgeFade
    │   ├── widgets/casino_table.dart  the casino table (24 Sep 2026, §8.4): TableGeometry (one stadium at fixed shares of the felt), CasinoTableSurface (static,
    │   │                         one layer), TableAmbientEffects (the breathing lamp on the cloth, the near rail warming on the viewer's turn)
    │   ├── widgets/seat_ring.dart  SeatRing (25 Sep 2026, §8.4): where 2..5 seats stand round that table — a pure function of the seat count, the table
    │   │                         and the pod's width; the head seat's cards beside its pod; the corners' controls bound it
    │   ├── widgets/playing_card.dart  THE card (§8.4 "The playing cards"): PlayingCard (face, back, the turn), CardFaceMetrics (where everything on a face goes),
    │   │                         CardFacePainter/CardStockPainter (the printed face; the stock's gold edge, faces and backs), cardRankFit, CardPips/SuitMark/paintPip
    │   ├── widgets/hand_fan.dart  HandFan (25 Sep 2026): the viewer's own fan as pure geometry — places, lean, which card is on top — for `_OwnHand` and SeatRing
    │   ├── widgets/              premium_surface, game_card (the lobby's one card shell, and CardColumn/CardGap/CardRule/CardSpace — its words, §8.4), seat_pod, poker_chip, liquid_fill,
    │   │                         fireworks, avatar, avatar_badge (the badge on the player's picture, §6.6), buy_chips, chip_store, picture_shelf,
    │   │                         rules_sheet, own_record (the lobby's Stats drawer, §8.4), level_art (a level's Lottie, §6.6),
    │   │                         variation_prompt (the variation table's on-felt picker, "is selecting" line, announcement, wild-card edge — §8.4),
    │   │                         wild_transform (a wild card of the viewer's own hand turning into the card it played as — §8.4),
    │   │                         weekly_login (the weekly login popup: the owner's calendar, its day cards and the reward panel — §8.4),
    │   │                         pot_coins (the pot's coins on the felt, the owner's Lottie drawn by a painter in the table's colour — §8.4)
    │   ├── theme/app_theme.dart  FlexColorScheme + shadow/lift helpers, Space/Radii/Motion/Breaks/Dim, Inter
    │   ├── theme/theme_colors.dart  GlassColors ThemeExtension (obsidian / frosted-ice tokens, §8.4); CasinoTableColors (the casino table's, §8.4)
    │   ├── theme/depth.dart      the depth ladder (28 Sep 2026, §8.4): Elevation, Depth/DepthScheme (every shadow and edge light), SurfaceLight, OuterShadow
    │   ├── widgets/glass_components.dart  tapHaptic, PressScale, GlassCard, GlassButton, GlassTextField, GlassThemeSwitcher
    │   ├── widgets/level_accent.dart  LevelAccent/LevelColours (30 Sep 2026, §8.4 "The Settings drawer"): the open lobby level's colour in the two lobby drawers
    │   ├── state/theme_preference.dart  themeMode read/write (+ legacy darkMode); state/consent.dart  the no-winnings flag
    │   └── l10n/strings.dart     hand-written 5-language table (en/hi/bn/gu/pa)
    ├── assets/card_back.svg, assets/app_icon.svg, assets/fonts/ (Inter 400/500/600/700 + OFL licence), assets/sfx/ (synthesised clips),
    │                         assets/sound/ (the owner's recordings, §8.4 "Sounds": see card sound.mp3 — the look at a hand;
    │                         Card Distribute.mp3 — each card of the deal; hammer hit.mp3 — a Force Sideshow's hammer;
    │                         Missile hit.mp3 — a missile volley; Card click.mp3 — a tap on any lobby key or card, and Back in the lobby;
    │                         winner.mp3 — a hand's winner named, heard by the whole table),
    │                         assets/animations/Fireworks.json (Lottie 5.5.7, 512x512, 2.43s — the winner's burst),
    │                         assets/animations/Lucky Draw Spinner.json (Lottie 5.10, 300x300 — the owner's prize wheel, §8.4)
    ├── test/  number_format, connection_failure, consent, theme_preference, … poker_table (§8.4), table_config_{dtos,cache,menu}, table_engines (§8.1),
    │          reward_programs and weekly_login on reward_fixtures.dart (§8.4), pot_coins (§8.4 "The pot's coins"),
    │          casino_table, seat_ring, premium_cards (§8.4); by hand, not `_test`: table_shots and card_shots (pictures)
    ├── android/                  applicationId com.sungamestudio.kingteenpatti, sensorLandscape, cleartext in DEBUG builds only (src/debug manifest),
    │                             no Android backup (allowBackup=false + res/xml/data_extraction_rules.xml), USE_BIOMETRIC/USE_FINGERPRINT removed
    └── ios/                      bundle id com.sungamestudio.kingteenpatti, landscape-only, status bar hidden,
                                  NSAllowsLocalNetworking; GIDClientID + URL scheme come from Flutter/*.xcconfig.
                                  NO Podfile (Flutter writes one on the Mac); never built here — docs/ios-setup.md
```

There is no CI, ESLint or Prettier anywhere, and one Dockerfile (`bot-play/Dockerfile`, the bot fleet's). `cd go-server && go test -race ./...`
(+ `go vet`, `gofmt -l`), the parity harness (`cd tools && npm run parity`, §7.6/§14),
`cd bot-play && go test -race ./...` and `cd flutter-client && flutter analyze && flutter test` are the whole verification story.

---

## 3. Environment requirements

| Tool | Version in use | Notes |
|---|---|---|
| **Go** | 1.27.1 at `~/.local/go` | **Not on PATH** — `export PATH=$HOME/.local/go/bin:$PATH`. `go-server/ops/build.sh` installs exactly this version there when missing (sha256 checked against go.dev); `bot-play/ops/build.sh` uses the same toolchain (running that script when it is missing). Both `go.mod`s say `go 1.27`. |
| Node.js | v22.22.1 (`>=20`) | Still needed for `tools/` (bots, ramp, parity — ESM, `node:test`), for two Go interop tests that borrow `tools/node_modules`, and by the Flutter toolchain. **Not** needed to run the server or the bot fleet (`bot-play/` is Go since 27 Sep 2026). |
| npm | 9.2.0 | `cd tools && npm install` once. |
| **PostgreSQL** | 18.6, local, port 5432 (production runs **16.15**: 18 records every NOT NULL in `pg_constraint`, 16 does not, so a catalogue count of constraints differs between them by exactly the NOT NULL columns) | DB `gameplay`, user/password `postgres`/`postgres`. Default `DATABASE_URL` in config points here. `psql` and `pg_isready` are installed. Go tests skip (not fail) when it is unreachable. |
| Flutter | 3.44.7 stable (`/snap/bin/flutter`) | Dart 3.12.2 — this is the **minimum** `pubspec.lock` accepts. Code uses records, switch expressions, `'k': ?v` null-aware map entries, `DropdownButtonFormField(initialValue:)`. |
| Android SDK | `~/Android/Sdk` | **Not on PATH** — `export PATH="$PATH:$HOME/Android/Sdk/platform-tools:$HOME/Android/Sdk/emulator:$HOME/Android/Sdk/cmdline-tools/latest/bin"` |
| Emulator images | `system-images;android-36;google_apis;x86_64` (+ android-34) | AVDs: `TP_API36` (Pixel 6), `TP_Small` (Nexus 5, 640×360dp — tightest), `TP_Tablet`, `TP_Tall` (Pixel 7 Pro), `Pixel_6_API_34`. |
| ffmpeg | 8.0 | stitch/crop `screenrecord` output |
| Python 3 + Pillow | 12.x | ad-hoc screenshot diffing, launcher-icon generation |
| Linux desktop toolchain | absent | `flutter test` prints a GTK/clang warning first — noise |

Shell quirks on this machine: zsh with `grep`→`ugrep` and `find`→`bfs` aliases; an unquoted
`--include=*.js` (or `*.go`) fails with "no matches found" — quote it; `cd` in one Bash call can leak
into the next — use absolute paths.

Server ↔ client: the backend's address is ONE build-time setting, `lib/config/server_config.dart`
(`ServerConfig.url`, `--dart-define=SERVER_URL`; REST at `<url>/api/...`, the Socket.IO handshake at
`<url>/socket.io/`). The privacy policy the settings drawer opens is NOT on that host: it is the studio site's
**`https://sungamestudio.com/privacy/`** (`ServerConfig.privacyUrl`, `--dart-define=PRIVACY_URL`, in every `config/*.json`;
owner, 24 Sep 2026 — the page the Play listing names; `https://prod.sungamestudio.com/privacy/`, which 1.2.2+9 opened,
answers 404). **With no define the app talks to
PRODUCTION, `https://prod.sungamestudio.com`, labelled `production`, with the production Google Web client id** (owner,
27 Sep 2026: "in frontend when UI is build it should by default call prod api"; the default was preprod from 24 Sep 2026,
and `api.sungamestudio.com` before), so a plain build is the store build and preprod or a local server must be named with a
define — and the store build still names production explicitly:
`flutter build appbundle --release --dart-define-from-file=flutter-client/config/production.json` — **production is
`https://prod.sungamestudio.com`** (owner, 24 Sep 2026: "ui should call https://prod.sungamestudio.com/ to connect backend";
`api.sungamestudio.com` stopped resolving that day, so a store build of `flutter-client/v1.2.1` or older reaches no server;
`test/release_config_test.dart` pins `config/production.json`, https and no trailing slash). `flutter-client/config/`
holds one JSON per environment (`production`, `preprod`, `local-emulator`, and since 27 Sep 2026 `local-ios-simulator` —
`http://localhost:3000`, since the Android emulator's `10.0.2.2` does not exist on a Mac: `SERVER_URL`, `APP_ENV`,
`PRIVACY_URL`, `GOOGLE_SERVER_CLIENT_ID`; an Xcode build reads none of them but the last `flutter` command's
`ios/Flutter/Generated.xcconfig`, so run `flutter build ios --config-only --dart-define-from-file=config/production.json`
first — `docs/ios-setup.md` §3);
`APP_ENV` is shown beside the version in the settings drawer unless it is `production`. A local server is
`--dart-define=SERVER_URL=http://10.0.2.2:3000` (the emulator's alias for the host loopback) or `http://<lan-ip>:3000` for a
real device on the LAN — in a **DEBUG** build only: `usesCleartextTraffic="true"` lives in
`android/app/src/debug/AndroidManifest.xml`, so a release or profile build refuses plain http (production is HTTPS, as it
should be; corrected 24 Sep 2026 — this said "in the manifest"). `test/server_config_test.dart` pins the default.
**`SERVER_URL` and `APP_ENV` are independent defines** — nothing ties the label to the backend, so a lone
`--dart-define=SERVER_URL=https://api…` is a production build labelled "· preprod"; always build from a
`config/*.json` file (`flutter-client/config/README.md`, 24 Sep 2026).

---

## 4. Commands

### Server (`cd go-server`, `export PATH=$HOME/.local/go/bin:$PATH`)
```bash
cp .env.example .env            # optional; defaults work for local dev. Set JWT_SECRET for prod. It names TABLE_CONFIG_SOURCE=db (see below)
go run ./cmd/gameplay           # → http://0.0.0.0:3000 (needs Postgres up); reads ./.env; browser client from ./public
go build ./... && go vet ./... && test -z "$(gofmt -l .)"    # compiles, vets, formatted — part of "done"
go test ./...                   # every package; Postgres-backed suites use schema test_<pkg>_<rand> and skip without a DB
go test -race ./...             # the actor/lock rules (§14.1) are exactly what the race detector checks
go test ./internal/game -run 'Sideshow'        # one package / tests matching a regex (names are sentences: TestASideshowNeedsThreePlayersInTheHand)
go test -count=1 ./internal/db ./internal/app  # force the DB suites to re-run (no cache)
bash ops/build.sh && ./bin/gameplay            # static, stripped, version-stamped binary (bin/ is git-ignored); -version prints the stamp
PORT=3001 PG_SCHEMA=test_x ./bin/gameplay      # spare port + throwaway schema (drop it after)
# the table catalogue (§7.3/§7.4) — both read ./.env and start no server (no logger on stdout: the export's stdout is SQL alone):
./bin/gameplay -export-table-config > tables.sql    # the catalogue the ENV keys compose, as one psql transaction (stderr: which keys, how to apply)
PGPASSWORD=postgres psql -h localhost -U postgres -d gameplay -f tables.sql   # PGOPTIONS='-c search_path=<schema>' first on any PG_SCHEMA but public
./bin/gameplay -check-table-config                  # the database's catalogue judged as a db boot would: exit 0 clean, 1 rows left out, 2 unusable
./bin/gameplay -migrate                             # every migration script, exactly as a boot applies them, then exit (reads ./.env; PG_SCHEMA honoured)
curl -s localhost:3000/api/tables | python3 -m json.tool | head -40    # what the server enforces (and the app caches)
curl -s 'localhost:3000/api/app-config?platform=android&version=1.5.0' | python3 -m json.tool   # the app version gate's verdict for a build (§7.2)
curl -s localhost:3000/health | python3 -c 'import json,sys; print(json.load(sys.stdin)["tableConfig"])'   # {source, version, fallback}
```

**Dev clocks and menus are env keys, and a table env key works only in env mode** (23 Sep 2026). Unset,
`TABLE_CONFIG_SOURCE` resolves to `env` the moment ANY table key is set, so on this box (no `.env`)
`POKER_TURN_TIMEOUT_MS=90000 go run ./cmd/gameplay` still plays a 90 s poker clock. A `.env` copied from
`.env.example` says `TABLE_CONFIG_SOURCE=db`, and then every table key is ignored (one WARN names them):
add `TABLE_CONFIG_SOURCE=env` to the command, or `UPDATE table_configs SET turn_timeout_ms = 90000 WHERE
table_key = 'texas_holdem:50000'` and restart — the catalogue is read once, at boot.

### Tools (`cd tools`, Node ≥ 20 — `npm install` once)
```bash
npm run bot -- --count 3 --boot 200  --category blind --offset 0            # practice bots on http://localhost:3000
npm run bot -- --count 3 --boot 5000 --category blind --offset 4            # 2nd group needs its own --offset
npm run bot -- --count 8 --boot 200 --category blind --churn 40             # bots hop tables → room:switch testable
npm run bot -- --url https://prod.sungamestudio.com --count 3 --boot 200 --category blind   # against production
npm run ramp -- --url http://localhost:3000 --stages 10,50,200,1000 --hold 40 --boot 200 --category blind --out ramp.json
npm run parity                                                              # black-box suites vs ../go-server/bin/gameplay (build first)
npm run parity -- --filter game,money --keep                                # some suites; keep server logs + schemas
npm run parity -- --url http://127.0.0.1:3000 --schema public --filter rest # attach to a running server instead of spawning
npm run parity:diff -- --a go --b http://127.0.0.1:3000 --schema-b public   # frame-by-frame traffic diff (spawned binary vs live)
```

Find/stop the server safely (read §12.1 before reaching for `pkill`):
```bash
ss -lptn 'sport = :3000'                      # shows the PID
kill <pid>                                    # SIGTERM: settles live pots, closes sockets, exits within max(8 s, PG_STATEMENT_TIMEOUT_MS + 5 s)
nohup ./bin/gameplay > /tmp/server.log 2>&1 &        # start in a SEPARATE command from the kill (from go-server/)
```

Useful Postgres checks:
```bash
PGPASSWORD=postgres psql -h localhost -U postgres -d gameplay -c "select display_name, chips from users order by chips desc limit 10"
# ledger must reconcile to wallets — exact only for accounts the purge has not touched: LEDGER_PURGE (§7.4) deletes
# hand_* rows older than 10 min, so on a server up that long every account that played returns here (zero-sum across them)
PGPASSWORD=postgres psql -h localhost -U postgres -d gameplay -Atc "select count(*) from users u join (select user_id, sum(delta) s from chip_ledger group by user_id) l on l.user_id=u.id where l.s <> u.chips"   # expect 0
PGPASSWORD=postgres psql -h localhost -U postgres -d gameplay -c "select nspname from pg_namespace where nspname like 'test_%'"   # leftover test schemas (should be none)
```

### Flutter client (`cd flutter-client`)
```bash
flutter pub get
flutter analyze                 # must be clean (it is)
flutter test                    # every suite under test/ (number formatting, connection failures, consent, … the table catalogue and the engine lobby)
flutter test tool/render_icons.dart   # re-render launcher/adaptive/splash PNGs from assets/app_icon.svg (not part of `flutter test`)
flutter build apk --debug       # ~7s incremental; build/app/outputs/flutter-apk/app-debug.apk
flutter build apk --debug       # no define → PRODUCTION (https://prod.sungamestudio.com, §3): name preprod or a local server with a config file
flutter build apk --debug --dart-define-from-file=config/local-emulator.json   # local server on the emulator (= SERVER_URL=http://10.0.2.2:3000)
flutter build apk --debug --dart-define=SERVER_URL=http://192.168.1.10:3000  # local server, real device
flutter build apk --debug --dart-define-from-file=config/local-emulator.json --dart-define=SHOW_POKER=true   # the Poker family back in the lobby (engines → categories); off by default, §8.4 — always beside a config file, or the build talks to production
flutter build appbundle --release --dart-define-from-file=config/production.json   # THE STORE BUILD: prod.sungamestudio.com + the Google client id
# NEVER distribute --split-per-abi APKs: build 8 becomes 1008/2008/4008, which no MIN_CLIENT_BUILD floor holds and Play can
# never update. build.gradle.kts refuses a split RELEASE build (24 Sep 2026; --android-project-arg=allowSplitPerAbiRelease=true
# for a throwaway test build). The Play upload is the App Bundle; a universal `flutter build apk --release` is fine to sideload.
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.sungamestudio.kingteenpatti/.MainActivity   # launch (monkey … 1 also launches it but injects ONE random event — it once opened the store and an unlock question)
adb shell am force-stop com.sungamestudio.kingteenpatti
```

### Emulator / verification helpers
```bash
emulator -avd TP_Tall -gpu host -no-snapshot-save &
adb wait-for-device; until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 3; done
adb shell settings put secure stylus_handwriting_enabled 0   # Pixel 7 Pro AVD: stop the stylus tutorial stealing focus
adb exec-out screencap -p > shot.png
adb shell uiautomator dump /sdcard/ui.xml && adb shell cat /sdcard/ui.xml | tr '>' '\n' | grep -o 'content-desc="[^"]\+"[^/]*bounds="[^"]*"'
adb logcat -c; ...; adb logcat -d | grep -ic "overflowed"     # Flutter RenderFlex overflow detector (0 = clean)
adb shell screenrecord --time-limit 170 --bit-rate 8000000 /sdcard/seg.mp4   # falls back to 1280x720 on 3120x1440 devices
```

---

## 5. Architecture

```
 Flutter / browser client                 go-server/internal  (Node names in §5–§7: auth/routes.js, socket/index.js, db/*.js)
 ┌──────────────────────┐   REST (JWT)    ┌─────────────┐      ┌────────────────────┐
 │ GameState (Provider) │◄──────────────►│ auth/        │◄────►│ db/users.go        │
 │  ├ ApiClient         │                └─────────────┘      │ (pgxpool)          │
 │  └ GameConnection    │   Socket.IO     ┌─────────────┐      │                    │
 │     (websocket only) │◄──────────────►│ socket/      │──┐   │ db/ledger.go       │
 └──────────────────────┘  per-viewer     └─────────────┘  │   │  bet / collectBoot │
                           room:state           ▲          ▼   │  / settle          │
                                                │   ┌──────────┴──┐  one transaction │
                                                └───┤ RoomManager │◄──── each ───────┘
                                                    │  └ Table    │
                                                    └─────────────┘
```

### 5.1 The money model (three checkpoints)
**Owner's decision, 9 Sep 2026 — this replaced the batched-bet model of `3fa983d`, which had itself
replaced the per-bet "database-first" one.** All game state lives in **Redis and nowhere else**.
**PostgreSQL holds money and audit** — the wallet on `users`, every movement in `chip_ledger` — beside
the accounts, the picture catalogue and the purchase records, and since 23 Sep 2026 the **table
configuration** (owner: "PostgreSQL stores table CONFIG, never state"): what KIND of table the lobby
offers and every figure it plays by, read once at boot (§7.3). None of it is the table being played:
a table copies its figures into its own config when it opens and never reads the database again. There
is no `game_states`, no `pots` and no `hands` table any more (retired 9 Sep 2026; the baseline no
longer creates them — see §7.3). A bet is **not** a database transaction, and neither is the deal.

The wallet is brought up to date at exactly three moments, each taking that player's chips as the
live state has them:

| Moment | `reason` | `action_id` | Scope |
|---|---|---|---|
| a player **packs** | `hand_packed` | `<handId>:packed:<userId>` | that player only |
| a player **leaves / switches / is kicked** | `hand_left` | `<handId>:left:<userId>` | that player only |
| the **hand ends**, winner decided | `hand_win` / `hand_loss` | `<handId>:settle:<userId>` | everyone still at the table |
| the deal, chaal, raise, show, see | — | — | **nothing is written** |

A bet therefore never leaves the process:

```
validate in memory (turn, amount ∈ ladder, actionId unused this hand, seat.chips ≥ amount)
  → seat.chips -= amount; seat.contributed += amount; hand.pot += amount
  → emit 'action'/'state'; the actor saves the snapshot to Redis at the end of the closure
```

and the transactions that DO run have this shape:

```
  → BEGIN
  → SELECT chips FROM users WHERE id=$1 FOR UPDATE        lock the wallet row(s), ascending id
  → UPDATE users SET chips = chips + delta                  DELTA, never an absolute
  (no counter is written here since Player stats v2, 27 Sep 2026: the table hands a hand's counters to the stats
   recorder once this COMMIT has happened, and a flusher adds them to player_stats in batches — §7.3)
  → INSERT chip_ledger (…, action_id UNIQUE)               one row per player per checkpoint
  → COMMIT
```

- **Deltas, never absolutes.** `delta = seat.chips now − chips as last written to PostgreSQL`
  (`chipsWritten` on the hand's contribution record, so it lives in the snapshot and survives a
  restart). It is never `SET chips = <live value>`: a reward credits PostgreSQL without touching the
  Redis seat, and an absolute overwrite at the next checkpoint would erase it.
- **Chip prizes and chip-priced picture purchases are lobby-only.** `POST /api/lucky-draw/spin` (since 24 Sep 2026,
  §7.2 — its prize may be chips; until 30 Sep 2026 the three lobby rewards `POST /api/rewards/milestone|bonus|daily` too,
  removed that day — below)
  returns **409 `seated`** before any DB work, matching the rule display name already had, and
  `POST /api/profile/picture/buy` refuses a **COIN** picture to a seated player with the same 409 —
  decided inside the purchase transaction (`db.Pictures.BuyAtTable` → `ErrPictureAtTable`), from the
  row being charged. That closes the concurrent-credit hole at its source; the delta above is the
  belt to that pair of braces. Its real value is that it makes an invariant true: *a seated player's
  chips cannot change except at these three moments.* **Diamonds are outside it** (owner, 13 Sep
  2026): nothing at a table reads or writes `users.diamond`, so a DIAMOND picture may be bought at
  the table, and any picture may be worn there (`POST /api/profile/avatar` → `Deps.PictureWorn` →
  `RoomManager.SetPlayerAvatar` → `Table.SetAvatar`, which updates the seat and emits state).
  **The lobby side is serialised with taking a seat** (13 Sep 2026, after a race that could create chips): every lobby door
  (quickJoin, joinCode, create, the resume auto-join) reads the wallet (`RoomManagerOptions.LoadPlayer`) under the player's
  seat-lock stripe, and every lobby-only wallet change — a COIN picture, the Lucky Draw spin (the rewards too, until they went on 30 Sep 2026), and since 24 Sep 2026 `DELETE /api/account`
  (§7.2) — runs inside `RoomManager.WhileUnseated` under the same stripe, as does a Play chip pack (`CreditBoughtChips`: the database credit and the seat top-up together), each
  on a context of its own rather than the request's. A purchase can therefore never land between a join's wallet read and its
  seat. While a table's refused hand-end settle is still retrying (`TableOptions.SettlementOwed` → the manager's `owed` count)
  or a destroyed table is still settling a seat (`departing`), that player gets 409 `seated` for lobby wallet changes and the
  Go-only `settlement_pending` ("Your last hand is still being saved; try again in a moment") for joins (DECISIONS.md §3).
- **`hand.actionIDs` is keyed per player** (`<userId>:<actionId>`, 24 Sep 2026, owner's "fix all bugs"): one player's
  id never refuses another's move; a bare id in an older snapshot is still honoured.
- **Resolve once, record twice.** A player who packs gets a `hand_packed` row and then a `hand_loss`
  row at the hand end whose delta computes to **zero** — the money moves once, while the outcome row
  still carries `hands_played`/`hands_lost`. A player who left is not in the hand-end write at all.
  A zero-delta row is not noise; it is what says this player was in the hand and how it ended.
- **`chip_ledger.action_id` is UNIQUE, and that is a mechanism, not just an audit key.** It is what
  terminates the settle retry: `Settle` retries up to 10 times with backoff, and a commit whose
  acknowledgement was lost (`statement_timeout`, a dropped connection) would otherwise run
  `chips = chips + delta` a second time and pay the winner the pot twice. The replay raises 23505,
  which `internal/db/ledger.go` maps to `duplicate_action`, which `table.go` reads as the success it
  is. Note this only works *because* the writes are deltas — an absolute write would have been
  idempotent by accident. A **replay within a live hand** is refused in memory instead
  (`duplicate_action`, `hand.actionIDs`).
- `chip_ledger` is **append-only**: a trigger raises on UPDATE/DELETE. `TRUNCATE` is the only way to
  clear it, and doing so needs one reconciling row per account or the §4 invariant breaks.
- The two-owners guard is the live store's per-table `seq`: a refused compare-and-set
  (`live.ErrStale`) **fences** the table.
- **Losing Redis loses the hands, and that is the accepted design.** Nothing is reconstructed —
  every player simply rejoins. A player holding 1,00,000 who had put 25,000 into the pot gets the
  full 1,00,000 back, because that is what PostgreSQL last knew; the 25,000 is un-made. The same
  player who instead *leaves* is written through at 75,000. The one real cost: a player who had
  already **packed** keeps their reduced balance while nobody wins the pot, so those chips leave the
  economy. `tools/crashtest.mjs` measures that explicitly as `stranded` and asserts
  `wallets + stranded` is invariant — chips can never be created, and any loss is exactly what an
  interrupted hand had already taken.
- `Table` never touches the DB directly. It is given a `Ledger` `{Checkpoint, Settle}` (production:
  `internal/db/ledger.go`; tests: `MemoryLedger`). `table.version` increments per committed write.
- **Every mutation runs through the table's serial queue** (`run`). A DB round-trip can therefore
  never interleave with a turn timeout; `hand.turnToken` additionally makes a late-firing timeout a
  no-op. Consequence in Node: `act`, `removePlayer`, `startHand`, `destroy`, `respondToSideshow`
  returned **Promises**; `addPlayer`, `postChat`, `setConnected`, `serializeFor` stayed synchronous.
- Settlement (`endHand`) is the one place memory is updated before the write completes — the hand
  *is* over. If the settle transaction fails the table pays the winner in memory and retries the
  idempotent write in the background (10 attempts, backoff) so the DB catches up.

### 5.2 Flow of a hand
`WAITING → STARTING (nextHandDelayMs) → BETTING → SHOWDOWN → WAITING`. Boots are taken from the seat
and the pot **in memory and Redis only** — the deal writes nothing to PostgreSQL (§5.1). A player who
cannot cover the boot is kicked before a card is dealt.
After every mutation the table emits `state`; the socket layer sends each viewer
`table.serializeFor(viewerId)` — never a room-wide snapshot.

---

## 6. Server — game engine (`server/src/game/` → `go-server/internal/game/`)

Written against the Node source and kept as the behavioural spec. Go equivalents: `table.js` →
`table.go` (+ `view.go`, `events.go`, `snapshot.go`), `roomManager.js` → `roommanager.go`,
`handRank.js` → `handrank.go`, `deck.js` → `deck.go`; `_method` → `method`. Since 19 Sep 2026 the
RoomManager holds **`game.Room`s** (`room.go`), of which `*game.Table` is the Teen Patti kind and
`*poker.Table` the poker kind (§6.5); `game.AsTable(room)` is how code that needs the Teen Patti
table gets it. Nothing in §6.1–§6.4 changed for it.

**Engines → categories → tables** (owner, 23 Sep 2026: "Teen Patti engines / Poker engines"). Every
category belongs to exactly one ENGINE — `seen`, `blind`, `variation` to `teen_patti`, the four poker
categories to `poker` (`config.EngineOf`, which a test holds to `game.Category.Game()`; the values are
`game.GameTeenPatti`/`GamePoker`, and `chip_ledger.game`'s `'poker'`). The categories are flat: a poker
variant is a category of the Poker engine, not a kind of Teen Patti's `variation`. The code always had
this; since 23 Sep 2026 the database does too (`table_engines`, `table_categories`, §7.3), and each
table of the lobby is a `table_configs` row under a category. **A category is data AND code**: the
database lists it, but only the engine written for it can play it, so the server leaves out (with a
logged reason) a category it does not know or one filed under the wrong engine (seen under poker).
**Where a new table's figures come from**: `config.GameConfig.Spec(category, boot, private)` — the one
answer every table is built from, the lobby card is drawn from and `GET /api/tables` serves, so they
can never disagree. With a catalogue loaded (db mode, §7.4) it is that pair's `table_configs` row (a
private table: its category's template); otherwise it composes the env keys exactly as the server
always did (`TableRules`, the global scalars, the poker knobs — pinned figure by figure in
`config/tables_test.go`).

### 6.1 `table.js` (→ `table.go`)
**Seat:** `{ userId, displayName, avatarUrl, chips, status, isBlind, blindMoves, cards, lastBet,
lastAction, contributed, connected, socketId, missedTurns, sideshowAskedThisTurn, seatIndex }`.
**Hand:** `{ id, handNo, pot, stake, round, packedUserIds, turnSeat, startSeat, seatOrder,
showRequestedBy, sideshow, lastDeparture, turnDeadline, turnToken, contributions: Map<userId,
{contributed, persisted, status, sawCards, cards, didChaal, leftMidHand}> }`.

- **Turn order**: clockwise = ascending seat index (`_nextActiveSeat`). `_rightActiveSeat` walks
  *downward* — "the player on your right" acted just before you (who a sideshow is asked of).
- **Ladder** (`betOptions`): `base = isBlind ? stake : 2*stake`; rungs double while
  `≤ min(bootAmount*potLimitMultiplier, chips)`, `≤ maxPot - pot`, `< maxRaiseSteps`. A client amount
  must be exactly a rung (`invalid_bet`); `raise ≥ 2*steps[0]`. `hand.stake` stays in **blind units**
  (`floor(amount/2)` after a seen bet). The `potLimitMultiplier` product is a *per-bet* ceiling; the
  pot cap is `maxPot` (0 = uncapped). **When the pot cap is what bars the way and no whole rung fits
  under it, the remaining headroom is offered as the single rung** (12 Sep 2026). Without it a capped
  table strands: a seen player's smallest legal bet is the entire per-bet ceiling (2,04,800 at boot
  200) once the stake has outgrown it, so a pot 1,56,600 short of its cap offered **nobody** a rung —
  everyone still in could only Pack, and the POT_LIMIT showdown the cap exists to cause never ran. A
  player who simply cannot afford the chaal still gets no rung; only the cap creates this one.
- **SEE** is free, allowed off-turn, doesn't move the turn or reset the clock. After `maxBlindMoves`
  (4) blind bets the cards auto-reveal; that last bet is still charged at the blind rate.
- **Turn clock** 25s → `missedTurns++`, `_pack('timeout')`; at `maxMissedTurns` (3) emits
  `kick {reason:'idle'}`. `missedTurns` resets to 0 only **after a successful move** — and a `see` is
  not one (24 Sep 2026, owner's "fix all bugs": Node reset it on any act, so tapping See once a hand
  defeated the idle kick; `TestAPlayerWhoOnlyLooksIsStillKickedIdle`). **Since 27 Sep 2026 (owner) three
  answers that are not moves clear it too** — answering a sideshow (accept or decline), choosing the
  variation, choosing the 5-Card three (`Table.clearMissedTurns`; a lapse clears nothing;
  `presence_test.go`) — and **a restore never charges one**: a turn whose deadline passed while the
  process was down gets a fresh, full clock from the restore instead of timing out at once (`resumeTimers`,
  Teen Patti and poker alike; it used to pack them and count a miss, so a restart could idle-kick a player
  on their second). The table only *emits* `kick`; RoomManager/socket layer removes the player — and an
  idle kick of a player with no live socket leaves a resume offer (§7.1). The app warns after every miss
  (§8.4 "The missed-turn warning").
- **Rounds** count when the turn steps *over* `startSeat` (by `_distance`, not equality).
  `round >= maxBetRounds` → forced showdown. `pot + stake > maxPot` → `POT_LIMIT` showdown.
- **Show**: exactly 2 active seats; costs `showCost = chaal`; **null/unaffordable cost →
  `insufficient_chips`** (a show is never free). Exact ties: show-payer loses, else the tied seat nearest
  the dealer going clockwise, **the dealer's own seat first** (distance 0 — `table.go` `resolveShowdown`,
  pinned by `review_showdown_winners_test.go` and DECISIONS.md; "nearest the dealer's left" was loose
  wording, corrected 24 Sep 2026 after the live winner audit saw a missile tie go to the dealer's seat).
  The pot is never split.
- **Sideshow** (req. 33): `sideshowBlockedReason` order `no_hand | not_in_hand | not_your_turn |
  sideshow_pending | already_asked | too_few_players | you_are_blind | no_neighbour |
  neighbour_is_blind`. Clock stopped while pending (6s). Only `toUserId` may answer. Tie goes
  **against the asker**. When the *asked* player loses, `_pack(..., {advanceTurn:false})` — the turn
  never left the asker. Clock re-armed with `_setTurn(fromSeat, {freshTurn:false})` so
  `sideshowAskedThisTurn` survives (one ask per turn). Participant leaving → resolved `'left'`;
  `_endHand` clears the timer. The sideshow is **free** (the brief specified no bet — flagged as an
  exploit vs. standard rules). **While a request stands `act` refuses every move but `see` with
  `sideshow_pending`** (24 Sep 2026, owner's "fix all bugs"; Node let the asker bet on, the turn moved
  round, and a late acceptance then froze the hand on a packed seat or skipped a turn), and the loser's
  pack advances the turn exactly when the loser holds it (`hand.turnSeat`), never by assumption. The asker's
  `you.options` say the same meanwhile: `raiseSteps: []`, `chaal`/`raise`/`maxBet`/`show` null, `canPack` false
  (and the sideshow, force and missile flags false), so the Flutter keys grey out; the ladder comes back when it resolves.
- **Missile** (owner, 14 Sep 2026; Go only): `ActionMissile`, on the firer's turn with **at least 3 players still in the
  hand** (the firer included; blind or seen) and **holding the chips a show would cost them** (`Table.showCost`, their chaal — held, not paid; owner, 14 Sep 2026), costs 1 missile and no chips (`MissileWallet.SpendMissile`, charged once per
  `<handId>:missile:<userId>:<actionId>` in `missile_spends`) and ends the hand: every player still in shows, the best
  hand takes the pot, exact ties go against the firer (win reason `missile`). Refusals in order `no_hand | not_in_hand |
  not_your_turn | sideshow_pending | pick_pending | too_few_players | insufficient_chips | duplicate_action | no_missiles | persist_failed`. `you.canMissile`
  (also in `you.options`) is the rules-minus-the-count answer. The next deal waits `NEXT_HAND_DELAY_MS +
  MISSILE_REVEAL_EXTRA_MS` so the client's volley and the reveal fit before it.
- **Variation window** (owner, 18 Sep 2026; Go only; rules in §6.4): on a `CategoryVariation` table `startHand` deals as
  always and then calls `beginVariation(firstSeat, undealt[0])` INSTEAD of `setTurn`: the player to the dealer's left has
  `VARIATION_SELECT_TIMEOUT_MS` (10 s) to choose the hand's variation. **While the window is open nobody is on turn** —
  `hand.turnSeat` stays -1, no turn clock runs, `you.options` is null — and `act` refuses everything but `see` with
  `variation_pending`. `closeVariation` is the ONE place it closes, guarded by `window.open`, reached by three closures on
  the actor: `SelectVariation` (`PLAYER`), the window's timer (`TIMEOUT` → `MUFLIS`), the chooser leaving (`LEFT` →
  `MUFLIS`, then `advanceTurn` past their seat). They are serialised by the actor, so a pick and a timeout in the same
  instant choose once — whichever runs first wins, the other finds the window closed; a pick that reaches the actor at or
  past the deadline loses to the clock even before the timer's closure has run (`variation_expired`). Closing gives the
  chooser a FRESH turn with a full clock; a lapse is not a missed turn. `SelectVariation` refusals in order `no_hand |
  not_seated | no_variation | variation_already_selected | not_selecting | invalid_variation | variation_expired`.
  `endHand`/`destroy`/`suspend`/`fence` stop the window's timer; `resumeTimers` re-arms it for what is LEFT of the original
  deadline (or closes it at once) and must run BEFORE the "no turn recorded → open play" branch. The window and the
  turned-up card live in `SnapshotHand.variation`.
- **Leaving mid-hand** = pack; stake stays; `leftMidHand=true`; `lastDeparture` gets the pot if all
  leave (`ALL_LEFT`). Winner identified by **userId**, not seat.
- `_sweepUnfunded` only between hands (`if (this.hand) return`); it sets `seat.kickPending` so a
  seat is kicked once even if two sweeps run before the queued removal lands. **Go only, since
  11 Sep 2026 (owner):** a short seat is not kicked at once but held for `UNFUNDED_GRACE_MS` (30 s) —
  `seat.unfundedUntil`, one table timer (`armUnfundedTimer`/`expireUnfunded`, re-armed on restore,
  stopped by destroy/suspend/fence), sent to that player alone as `you.unfundedDeadline`. The sweep
  runs the instant a hand ends (`endHand → maybeStart`), so without it a player buying chips could
  never beat the kick; `Table.CreditChips` drops the grace once the boot is covered and calls
  `maybeStart`. A seat sitting a hand out is shown out mid-hand when its grace lapses.
- **`serializeFor` redaction (do not break)**: `you.cards` only when `!viewer.isBlind`; other seats
  carry only `cardCount`; on BLIND **and VARIATION** tables (`Category.HidesChips`; variation since 18 Sep 2026, owner:
  "no one can see other player amount") others' `chips` is **`null`** (not 0) + `chipsHidden:true`;
  `you.hand {handName, category, wild, playsAs}` (Go only, §6.4) is the viewer's OWN hand as the variation counts it and
  is in `you` alone, present only once they have seen their cards AND the variation is chosen;
  `missedTurns/maxMissedTurns/options` (and `unfundedDeadline` while a short seat is held) only in `you`; `sideshow` carries ids/seats/`expiresAt`, never
  cards. Public everywhere: `lastBet, lastAction, contributed, isBlind, connected, status`.
- `_snapshot()` is the *server-side* full state (cards and the hand's per-player unbanked bets
  included) saved to the **live store (Redis) only** — never to PostgreSQL, never to a client.
- **Events**: `state, seatUpdated, chat, handStarted, cards, turn, action, showdown, handEnded, kick,
  sideshowRequested, sideshowReveal, sideshowResolved, persistError, error`. `seatUpdated` has no
  listener; `persistError` is logged by RoomManager only.

### 6.2 `roomManager.js` (→ `roommanager.go`; DECISIONS §3 lists the few deliberate differences)
- `quickJoin`: `_assertNotSeated` → `assertStakeAllowed` (`tableStakes`) → `normalizeCategory`
  (exactly `blind` → blind, exactly `variation` → variation (Go only), anything else → **seen**; the set is closed at
  three and normalised in THREE places that must agree — `config.NormalizeCategory`, `game.NormalizeCategory` and
  `NewTable`, which is also where a table restored from Redis gets its category back) → `assertTableOffered` (`lobbyTables` pair) → chips ≥ boot →
  `_assertUnderEntryCap` → **`assertWithinTableBand`** → fullest public non-full table with same boot+category,
  else `createTable`.
  Sync. The categories are seven since 19 Sep 2026 (the four poker ones too, §6.5), and the fields these checks read —
  `TableStakes`, `LobbyTables`, the entry cap — come from the table catalogue in db mode (`GameConfig.WithCatalogue`
  writes them from the rows, so no check changed, §7.4). **In db mode `assertUnderEntryCap` checks nothing**: the
  settings' entry cap is folded into the matching table's band (`tableMaxChips`) and `assertWithinTableBand` refuses
  with the same `over_entry_cap` code and message, and a row's own `max_chips` wins over it at the card AND the door —
  checking the settings' cap as well would refuse a player the row lets in.
- `switchTable` (**async**): same boot+category, the other public non-full table with the **fewest players** (Go, owner
  25 Sep 2026: "try to find table who has lowest player" — `pickEmptiestTableLocked`, seats taken plus seats held, ties drawn with
  crypto/rand; a random pick from 13 Sep, and Node took the fullest, which quickJoin still does). **When every other table of the
  kind is full, or there is none, a NEW table of that boot and category is opened for the player** (same day: "if all the tables are
  fully filled then create a new table for that player"), and closed again if the move is then refused, so no empty table is left
  behind (`TestARefusedSwitchLeavesNoNewTableBehind`). `no_other_table` now answers only a table whose pair the lobby no longer
  opens (`AssertStakeAllowed`/`AssertTableOffered`; the seat is kept). **No entry cap**, leaves with reason `'moved'`
  (skips consolidation). **Since 24 Sep 2026 (owner, "fix all bugs") a switch is refused `insufficient_chips` BEFORE the
  seat is given up when the seat's stack does not cover the target's boot or a poker room's buy-in**
  (`assertAdmitsMove`): a short seat used to hop tables to restart its unfunded grace for ever, and a poker stack below the
  buy-in was vacated, refused by the target and then by its own room's buy-in on the way back — seated nowhere. The stack
  BAND is still not applied on a switch (a band is an entry rule, `TestRoomsSwitchIgnoresTheStackBand`), nor the entry cap.
  `leave`, `destroyTable`, `consolidateTables`, `sweepEmptyTables`,
  `_movePlayer`, `shutdown` are **async** and must be awaited. `leave` deletes `playerRooms` *before*
  awaiting the removal.
- `createTable`: public seen → `{maxRaiseSteps: 2, maxBetRounds: 7, maxPot: 2_000_000}`; private →
  boot forced to `privateBoot`, `{maxPot: 500_000, maxRaiseSteps: 2}`; public blind → full ladder,
  uncapped. Constructs `Table` with `ledger: this.ledger` (defaults to `createLedger()` unless tests
  pass `settle`/`persistChips`). **In Go (`newTableLocked`, 23 Sep 2026) those are the env composition's
  figures and every one comes through `g.Spec(resolved, boot, private)`**: the category is settled first — a
  variation table the menu does not offer is seen; a PRIVATE table of a category with no active private
  template (db mode, `GameConfig.HasPrivate`) is seen; a poker category without a factory, or whose factory
  refuses, is seen — then a Teen Patti table's `TableConfig` is `tableConfigFromSpec(resolved, spec, chat)`
  and a poker room gets the spec as `RoomSpec.Table` (`poker.ConfigFromSpec`). The table copies every figure
  into its own config and snapshot, so an edit to the catalogue reaches only tables opened after the restart
  that loads it.
- `lobbyOptions()` → `{categories, stakes, tables:[{category, bootAmount, maxPot, maxBlindMoves}],
  entryCap*, privateBoot, privateMaxPot}`. Clients render `tables` verbatim. In Go each entry's
  `maxPot`/`maxBlindMoves` (and a poker entry's facts, `RoomFactory.MenuEntry(spec, …)`) come from that
  entry's `Spec` (`menuRows`), so the card states exactly what the table it opens plays by; the JSON is byte
  for byte what it was in env mode. `TableConfig()` / `TableConfigVersion()` are the same menu with every
  figure beside it — the `GET /api/tables` body and its sha256 version (§7.2) — built ONCE in
  `NewRoomManager` (the config is immutable) and handed out as copies.
- **Draining** (Go only, 23 Sep 2026). A room restored from Redis keeps the rules frozen in its snapshot
  whatever the configuration now says. `drainReason` (at `registerRestored`, before the room is visible to
  matchmaking) marks a PUBLIC room `rm.draining` when its category+boot has left a non-empty menu, or when
  `!room.RulesSpec().SameRules(g.Spec(category, boot, false))` (durations compared in whole ms, the grain a
  snapshot keeps). A draining room plays on and `room:joinCode` still reaches it, but quick-join and a switch
  never send anybody to it, and consolidation never moves a player from an undrained table onto it. It may be
  consolidation's SOURCE (requirement 24; without it the lone players a restart strands on old rules never meet the
  fresh table quick-join opens, nor — pair delisted — each other): `ConsolidateTables` targets the group's oldest
  UNDRAINED single, moving a drained one's player there only if `admitsFromDrained` (the pair's band with the entry
  cap folded in, the env entry cap, a poker room's `RulesSpec().MinBuyIn` — `movePlayer` checks none of them); the
  drained singles still alone then merge among themselves (`mergeDrained`), each onto the oldest playing by the same
  frozen rules (`wholeMillis(RulesSpec())`, `SameRules`), and the target stays drained. It is swept like any table
  once empty (the mark goes in `destroyTable`/`Suspend`, a consolidation's emptying included), and one INFO `table
  draining` line names it. Without it a
  poker room frozen with a higher buy-in than its card shows would refuse (`insufficient_chips`) every player
  the card let through while quick-join kept choosing it. A private room is never drained — its code is its
  only door.
- Sweeper interval (unref'd): merges lone players on idle public tables of the same
  `category:boot` into the oldest (undrained, above); sweeps empty tables older than a **hardcoded** 30s. Every consolidation
  move (not only a drained one's) now needs a stack that covers the target's boot / poker buy-in (`assertAdmitsMove`, 24 Sep
  2026): a poker player who had played below the buy-in was moved off, refused, and could not be put back. Such a player
  simply stays where they are. `review_switch_admission_test.go`.

### 6.3 `handRank.js` / `deck.js` (→ `handrank.go` / `deck.go`)
`HIGH_CARD 0 < PAIR < COLOR < SEQUENCE < PURE_SEQUENCE < TRAIL 5`. Runs: **A-K-Q > A-2-3 > K-Q-J >
… > 4-3-2**. Suits never break ties. `pickWinner` is exported but `table.js` re-implements the tie
loop — keep consistent. Wire hand names are the **English** `CATEGORY_NAMES` and Flutter shows them
untranslated.

### 6.4 Variation Teen Patti — the rules (`variation.go`; Go only, owner 18 Sep 2026)
A third category, **`variation`**: it BETS as a blind table does — since 28 Sep 2026 (owner: "no limit on chaal if a
player has money", "the bug is that i am only able to raise one time in variation 50000") `config.TableRules` gives a public
variation table a ladder to the stack, no round cap and no per-bet ceiling (0/0/0, fixed rather than read from `BLIND_*`;
a private one keeps `PRIVATE_MAX_RAISE_STEPS`' two rungs); until then it took the seen table's two-rung ladder and its
7-round forced showdown — and its SECRECY
from the blind one (`Category.HidesChips`: other stacks are `null`), and it has **NO pot limit** (owner, 18 Sep 2026;
`VARIATION_MAX_POT_BOOTS` 0 — the one variation-only rule key, a cap counted in that table's own BOOTS because one fixed
figure cannot fit several stakes: the seen table's 20 Lakh is two boots at the 10 Lakh table, where every hand would be
dealt straight into the POT_LIMIT showdown; a private variation table keeps `PRIVATE_MAX_POT`). The default menu offers
it at **two stakes only, 50,000 and 10 Lakh**, behind the stack bands blind's tables of those stakes have. (Those are
the env keys' composition; in db mode each variation row carries its own ladder, `max_pot`, and the two windows, which
a CHECK keeps above 0 — seeded to exactly these figures, §7.3. A database seeded before 28 Sep 2026 keeps the old seen
ladder on its variation rows until `UPDATE table_configs SET max_bet_rounds = 0, pot_limit_multiplier = 0 WHERE category =
'variation'; UPDATE table_configs SET max_raise_steps = 0 WHERE category = 'variation' AND NOT is_private;` and a restart.) Every hand
is decided by one of **seven** variations, chosen in the window §6.1 describes. Wire values, matched EXACTLY by
`ParseVariation` (no trimming, no case folding — `muflis` and `Lowest Joker` are `invalid_variation`): `MUFLIS`, `AK47`,
`JOKER`, `HUKAM`, `LOWEST_JOKER`, `HIGHEST_JOKER`, and — added LAST, so the six before it keep their places —
`FIVE_CARD`.
- **One ranking, not seven.** Every variation but Muflis is classic Teen Patti with some cards WILD, and Muflis is
  classic compared the other way round. `VariationRules{Variation, WildRank, WildSuit}` carries a wild rule and a
  direction; its **zero value is classic**, which is what a seen or blind table holds, so `resolveShowdown` and
  `settleSideshow` — the only two places hands are compared — call `t.handRules().EvaluateHand/CompareHands`
  unconditionally and nothing changes for the old categories.
- **`evaluateWithWilds` searches rather than reasons**: each wild may stand for any card of the deck that is not a
  natural card of the same hand (never a duplicate of one it holds; it MAY be a card another player holds — jokers are
  per hand), no two wilds for the same card, every candidate goes to the one `Evaluate`, the strongest wins. ≤ 50
  evaluations for one wild, 1,275 for two; three wilds are answered from a constant (a trail of aces) that a test holds
  to the exhaustive search. Three wild cards are SHOWN as that trail too (`acesStoodFor`, 26 Sep 2026): a held ace stands for itself and the other
  cards for aces the hand does not hold — handing out A♠ A♥ A♦ in seat order showed [4♠ 7♠ A♠] as [A♠ A♥ A♦], the 4♠ standing
  for the A♠ the player held (`variation_standins_test.go`, all 560 hands of three AK47 cards; a deal the parity suite hit). The result keeps the player's REAL cards in `Cards`, names the wild ones in `Wild`, and takes
  `Category`/`Name`/`Score` from the hand they made.
- **MUFLIS** `Compare(b, a)`; the ace stays high, so 5-3-2 off-suit is the best hand there is and A-A-A the worst.
  **AK47** every A, K, 4, 7. **JOKER** every card of the RANK of the turned-up card. **HUKAM** every card of its SUIT
  (a wild suit — the brief said "trump/wild"; `EvaluateHukam` is where a true trump rule would go). **LOWEST_JOKER** /
  **HIGHEST_JOKER** per hand: its lowest / highest rank and every duplicate of it (3-3-K → both threes; a trail → all
  three); the ace is high.
- **The turned-up card** is `Deal`'s own `remaining[0]` — the top of the deck the hands came from, so it is in nobody's
  hand — kept on every variation hand and put on the wire (`turnUp`) ONLY once JOKER or HUKAM has been chosen.
- Exact ties are unchanged: the show-payer / missile firer loses, else nearest the dealer's left; a sideshow's asker loses.
- **FIVE_CARD — 5-Card Teen Patti** (owner, 18 Sep 2026): every player HOLDS five cards and PLAYS the best three,
  which THEY choose (owner, 19 Sep 2026: "when user clicks on 'see cards' … give user extra time so that he can choose 3 cards among 5"; the server used to find the strongest three itself). The window is per PLAYER and per hand, opens the moment five cards are in front of someone who can see them — their tap on See cards, or the top-up landing on a player already looking — and lasts `FIVE_CARD_PICK_TIMEOUT_MS` (8 s). Lapsing plays THE FIRST THREE THEY WERE DEALT, which is also what a player who never looks plays, so every hand always has three cards to compare. `table_fivecard.go` holds all of it: `playedCards`/`playedHand` (the ONE way a hand is scored at the showdown, at a sideshow and in a player's own view), `beginPick`, `SelectCards` (socket `game:selectCards {cards:[3]}`, refusals `no_hand | not_seated | not_in_hand | not_picking | duplicate_action | invalid_pick`), `settlePick` — the one place a choice is made, guarded by `picked` already being set, so a pick and its own deadline arriving together decide exactly once — and ONE `pickTimer` armed for the earliest window outstanding, which `expirePicks` sweeps and re-arms. `extendTurn` pushes a chooser's turn out to cover the whole window and a full turn after it, so choosing never costs them the time to act — **only the picker's own turn, and only while they hold it** (24 Sep 2026, owner's "fix all bugs": it used to extend whoever held the turn, so every other player's look topped the holder up), and a chooser who looked during the variation window gets it when their turn starts (`closeVariation` → `extendTurnForPick`). **A comparison a player forces waits for the hands it would judge** (same day): a Sideshow, Force Sideshow, Missile or Show is refused `pick_pending` ("Wait a moment: a player is still choosing their three cards") while any of those hands is inside a window with a deadline — at most `FIVE_CARD_PICK_TIMEOUT_MS` — and `canSideshow`/`canForceSideshow`/`canMissile`/`show` read false/null meanwhile; before, it played their first three with the window still open. **A showdown the SERVER starts waits too** (same day): `advanceTurn`'s round-cap (`forced_showdown`) and pot-cap (`pot_limit`) showdowns go through `serverShowdown`, which — while any hand still in has an open window with a deadline — records the reason on the hand (`hand.deferredShowdown`, in the snapshot as `SnapshotHand.deferredShowdown`, absent otherwise), stops the turn clock and puts nobody on turn (`turn.seatIndex` -1, every move `not_your_turn`, a look still allowed); `runDeferredShowdown` runs it exactly once, on the actor, the moment the last window closes — the player's choice (`selectCards`), the lapse (`expirePicks`, after settling every lapsed window) or the picker leaving (`removePlayer`) — and `resumeTimers` resumes a restored deferral (a lapsed window on the pick clock's zero delay, none left: at once) instead of reopening play. A packed seat's window closes with the pack and `selectCards` from it is `not_in_hand`. The choice is in the snapshot (`SnapshotSeat.picking/picked/pickedBy/pickUntil`, validated on restore against the cards that seat holds), so a restart neither re-asks a player who answered nor gives one who has not a fresh clock. **`Variation.CardsPerPlayer()` is the one place that number lives** (5 for
  FIVE_CARD, `BaseCardsPerPlayer` 3 for everything else) — the engine carries no "3" of its own. The flow stays
  deal → window → choice, so **every hand is still DEALT three**: `beginVariation(firstSeat, undealt)` takes the
  turned-up card from `undealt[0]` and draws a two-card **top-up** per player from `undealt[1:]`, round the table in
  deal order (`drawExtraCards` → `variationWindow.extra`, `SnapshotVariation.Extra`). Drawn at the deal, not at the
  choice, so it is part of the hand: a restart mid-window deals the same two cards, and nothing about the choice can
  influence them. It is server-only until dealt. `closeVariation` announces, then — when the chosen variation's
  `CardsPerPlayer()` is more than three — `dealExtraCards` appends each seat's top-up to `seat.cards` AND the hand's
  `contribution.cards` (a fresh slice, never an append into the deal's backing array), re-sends `cards` to a player
  already looking, and `extra` is dropped either way. A player who left during the window has no seat to deal to; a
  timeout or a departed chooser is still MUFLIS with three cards each. `extra` is nil when the deck could not cover
  everyone (no table the lobby opens: 5×3 + 1 + 5×2 = 26 of 52), and then FIVE_CARD is neither on that hand's menu
  (`variationWindow.options`) nor accepted (`invalid_variation`). `validateSnapshot` refuses a top-up that is not two
  real cards each or repeats a card in play. **`EvaluateBest(cards)`** is the evaluator: every three-card combination
  (`ThreeCardCombinations`, C(5,3) = 10) scored by the ONE classic `Evaluate` and the strongest kept by the ONE classic
  `Compare` — no second ranking to drift. It keeps all five in `Cards` and names the strongest three in **`Best`**, in
  the order held — which since 19 Sep 2026 is what a player is TOLD they could have played (`you.hand.bestPossible`),
  not what plays; combinations are walked in index order and a later one must be STRICTLY better, so which three are
  named is deterministic among ties, and being ties it cannot change who wins. No card is wild and nothing is reversed.
- **`PlaysAs`** (`EvaluatedHand`, set with `Wild`, nil without a wild card): the hand as it was COUNTED, index for index
  with `Cards` — a wild card replaced by the stand-in the search chose (`best.Cards[len(naturals):]` dealt back into the
  player's own order), every other card itself. `Table.ownHandView` puts it in **`you.hand`** for a viewer who is not
  blind once `hand.variation.selected` is set — and since 24 Sep 2026 every showdown reveal and sideshow-reveal hand carries it too
  (`Reveal.PlaysAs`, `SideshowHand.PlaysAs`, present exactly with `Wild`), so the table can show the hand that won rather than the
  cards it was dealt, so a player who looked during the window gets it the moment the choice
  lands; the hand's end drops it (`t.hand == nil`). It is that player's own cards run through a public rule: nobody
  else's snapshot carries any of it (`TestYourOwnHandIsNamedOnceYouHaveSeenItAndTheVariationIsChosen`).

### 6.5 The Poker family (`internal/poker/`; Go only, owner 19 Sep 2026 — `go-server/POKER_PLAN.md` is the design report)
Four more categories, each a **room beside the Teen Patti tables** in the same RoomManager, the same lobby, the same
socket layer, the same live store and the same three money checkpoints (§5.1): **`three_card_poker`** (against the
house), **`five_card_draw`**, **`texas_holdem`** and **`omaha`**. `Category.Game()` sorts every category into
`GameTeenPatti` or `GamePoker`; `IsPoker()`, `Known()` and `PokerCategories` are the helpers. The brief's rule was
**do not break Teen Patti**, and the shape follows from it:
- **`game.Room`** (`room.go`) is the interface the RoomManager, the socket layer, the sweeper, the live-store restore
  and the metrics now hold — `*game.Table` implements it unchanged in behaviour, `*poker.Table` implements it too.
  A room is opened by the **`RoomFactory`** registered for its game (`RoomManagerOptions.Factories`;
  `poker.Factory{Listener}` is wired in `app.go`), given `RoomSpec` (id, code, category, boot, private) and `RoomDeps`
  (ledger, clock, live store, config, hooks). Restoring from Redis peeks `{"game","roomId","createdAt"}` first and
  dispatches on `game` (absent = Teen Patti), so a Teen Patti snapshot is read exactly as before. The poker snapshot
  keeps its config under `pokerConfig`, not `config`, so a Go tag from BEFORE the family — which reads every snapshot
  as a Teen Patti one and never checks `category` — refuses it at its first check and drops the room instead of
  rebuilding it as a seen table (`TestAPokerSnapshotHasNoConfigKey`; DEPLOY.md §5).
- **`game.Actor` / `LiveState` / `Settler`** (`actor.go`) are the pieces of the Teen Patti `Table` that had nothing to
  do with Teen Patti — the one goroutine with `run`/`post`, the per-closure Redis snapshot with its two-owners fence,
  the hand-end settle retry chain — extracted so the poker room is built on the SAME shell (`Table` embeds all three;
  `t.run`, `t.destroyed`, `t.liveSeq` are promoted). The actor rules of §14.1 apply to a poker room word for word.
- **Money is the three checkpoints and nothing new**: a **fold** writes `hand_packed`, a **leave / kick** `hand_left`,
  the **hand end** `hand_win` / `hand_loss` — same `action_id` shapes, same deltas, same UNIQUE guard, same purge. The
  only schema change is **`chip_ledger.game` and `chip_ledger.variant`** (nullable TEXT; `V1.0.2__chip_ledger_game.sql`
  until 23 Sep 2026, folded into the baseline since — §7.3): `'poker'` + the category on a poker row, NULL on every Teen Patti row, so the audit can tell them apart —
  **3-Card Poker is played against a house with no wallet**, so its hands are not zero-sum (chips a player wins enter
  the economy like a reward, chips they lose leave it like a purchase); `tools/parity/money.test.js` exempts exactly
  `variant='three_card_poker'` from the per-hand sum and nothing else. Every other poker hand conserves chips and every
  wallet still equals its ledger sum (the §4 psql check stays 0).
- **The variants** are fixed in `poker.Variants` (`VariantConfig`: hole cards, board, blinds or ante, dealer, draw,
  the streets), nothing about how they play is configurable. **Stake = the table's boot** (the `LOBBY_TABLES` entry's
  in env mode, the `table_configs` row's `boot_amount` in db mode): the **big blind** at
  Hold'em/Omaha (small = half) and the **ante** at 3-Card Poker / 5-Card Draw. The default menu offers **one table per
  game, all four at 50,000** (owner, 19 Sep 2026), so the buy-in is 5 Lakh everywhere — above the welcome (§7.4). Three
  deployment figures: the turn clock (env: `POKER_TURN_TIMEOUT_MS`, 0 = `TURN_TIMEOUT_MS`), the buy-in (env:
  `POKER_MIN_BUYIN_BOOTS` 10 × boot; db: the row's `min_buy_in` in CHIPS, at least the boot — a stack below it cannot
  sit, `insufficient_chips`, and a seated one is held for `UNFUNDED_GRACE_MS` then kicked, as a short Teen Patti seat
  is) and the exchange limit (env: `POKER_MAX_DISCARDS` 3, 0..5; db: `max_discards`) — each a `table_configs` column in
  db mode, per table (`poker.ConfigFromSpec`). A poker room has **no pot limit** (`MaxPot()` 0) and
  **hides every other stack** (owner, 19 Sep 2026: "in poker do not show opponent chips"): `Category.HidesChips()` is
  true for the four poker categories as it is for blind and variation, so `chipsHidden:true` and every `seats[].chips`
  but the viewer's own is **`null`** (never 0). The lobby card, the table info dialog and the rules sheet all say
  "Only your own chips are visible".
- **Hold'em / Omaha**: button, small and big blind posted at the deal (a short stack posts what it has, all-in),
  streets `preflop → flop → turn → river`, first to act preflop is left of the big blind, after it left of the button;
  bets are TO an amount (`raise` = the whole street bet after it; `minRaise` = the last raise size, at least the big
  blind), `allIn` puts the stack in whatever the street's bet is, a street ends when every live seat has acted and
  matched (or is all-in); when nobody left can act the remaining board is run out. **Side pots** (`SidePots`) by
  contribution level, each paid to the best hand among its eligible seats, odd chips clockwise from the button
  (`Award`); everyone folding to one player ends it `last_standing` with no reveal. **Dead money** (24 Sep 2026, owner "fix
  all bugs"): a folded or departed player's chips never come back to them, even the part nobody matched — they go to the
  highest pot a player still in can win, and when the players still in put nothing in (the blinds walking out on the first
  player to act) the pot is opened to them; it used to be paid to nobody and the blinds were destroyed. The last player
  standing gets a hand-end row even with 0 chips in (`settle` skipped it). Only a player STILL IN gets back an excess nobody
  could call. **An all-in for less than a full raise does not reopen the betting**: whoever has acted since the last full
  raise may call or fold only (`raiseTo` resets `acted` only on a full raise, `mayRaise`), and **no raise is offered when no
  other player still in can act** (every opponent all-in). `review_money_fixes_test.go`. Omaha's hand is **exactly two**
  hole cards and three board cards (`BestOmaha`), never five of nine; Hold'em's the best five of seven (`BestHoldem`).
- **5-Card Draw**: an ante each, five cards, `predraw` betting, then the **draw** in turn from the button's left —
  `{action:"draw", cards:[…]}` names up to `maxDiscards` of the player's own cards (none = stand pat; a card not held,
  one named twice or too many → `invalid_discard`), the room announces only HOW MANY (`poker:draw`) and re-sends the
  new hand to its owner (`poker:cards`) — then `postdraw` betting and the showdown.
- **3-Card Poker** (`flow_threecard.go`): every participant antes, three cards each and three to the dealer; in turn
  each player **plays** (a second bet equal to the ante) or **folds** (the ante is the house's) — so a seat is dealt in only
  holding **2 × ante** (`dealInChips`, 24 Sep 2026; below it the seat is unfunded, held for the grace and shown out, where a
  stack of one ante used to be dealt in and offered only a fold); then the dealer turns
  up: **qualifies with queen-high or better** (`DealerQualifies`) — not qualified: play bet returned and ante paid 1:1
  to everyone still in; qualified: each hand against the dealer's, win → both bets paid 1:1, lose → both taken, tie →
  push. The ranking is `Evaluate3` — `game.Evaluate` with ace-low-lowest, **Straight Flush > Three of a Kind >
  Straight > Flush > Pair > High Card** (3-Card Poker's order, not Teen Patti's, where Trail beats a Pure Sequence).
  No ante bonus, no pair-plus (documented, not built). Win reason `dealer`.
- **`Evaluate5`** (`eval5.go`) is the ONE five-card ranking: High Card 0 … Straight Flush 8, **Royal Flush 9**;
  the wheel A-2-3-4-5 is a straight with high card 5; `Combinations`/`BestOf` walk every five of n.
  `tools/parity/lib/poker5.mjs` is an INDEPENDENT evaluator written from the rules, and the poker parity suite checks
  every reveal's `handName`/`best` against it, so the two would have to share a mistake to agree.
- **`TableView`** (`view.go`): every key a Teen Patti snapshot has for the same concept keeps its name and shape
  (`roomId, code, isPrivate, category, chipsHidden, state, handNo, dealerSeat, maxPlayers, minPlayers, bootAmount,
  turnTimeoutMs, startsAt, pot, turn, you, seats`), plus **`game:"poker"`** and **`poker {variant, street, community,
  pots, currentBet, minRaise, smallBlind, bigBlind, ante, holeCards, maxDiscards, minBuyIn, dealer?, result?}`**.
  Redaction: `you.cards` are the viewer's own hole cards and nobody else's; other seats carry `cardCount`; the
  dealer's cards and every revealed hand are on `poker.result` only after the showdown (kept until the next deal for
  a viewer arriving mid-celebration); the board is public. `you.options` — `{street, fold, check, call, callAmount,
  bet, minBet, maxBet, raise, minRaise, maxRaise, allIn, allInAmount, play, playAmount, draw, maxDiscards}` — is what
  the player on turn may do **with every amount the server will accept**; the client draws its keys from it and the
  server validates the move against the same figures. **There is no all-in move** (owner, 19 Sep 2026: "remove the
  option ALL in one button"): `ActionAllIn` is refused, `applyAllIn` is gone and `Options` carries no
  `allIn`/`allInAmount`, because every amount is already capped at the player's stack — the maximum bet or raise IS
  the shove, a call short of the bet is the all-in call, and a stack smaller than the minimum bet is offered that
  stack as the minimum. The boolean `allIn` on a seat, an ack and a `poker:action` event, which marks a move that put
  the last chip in, is a different thing and stays. `you.hand {handName, category, best}` names what the viewer's
  own cards make right now. `poker.pots` mid-hand are the chips COLLECTED at the ends of streets; the current street's
  bets are `seats[].streetBet` (what a card room leaves in front of the players); `pot` is everything.
- **Refusals**: the Teen Patti codes where they mean the same (`no_hand`, `not_seated`, `not_in_hand`,
  `not_your_turn`, `duplicate_action`, `insufficient_chips`, `persist_failed`, `unknown_action`) plus
  `invalid_action` (not allowed now), `invalid_amount` (not whole / outside `[min,max]`), `invalid_discard`, and
  **`wrong_game`** — a `game:*` move sent to a poker room, or `poker:action` to a Teen Patti table. Turn clock
  `POKER_TURN_TIMEOUT_MS` → a fold with `reason:"timeout"` (a check where a check is free), `missedTurns` and the
  idle kick as at a Teen Patti table. A player leaving mid-hand folds (`hand_left`); the room destroyed mid-hand
  refunds every pot to its contributors (`all_left`).
- **Events** (`poker.Listener`, an interface of its own so no Teen Patti implementer changed; the socket layer's
  `pokerEvents` implements it): `OnState, OnChat, OnHandStarted, OnCards, OnTurn, OnAction, OnStreet, OnDraw,
  OnShowdown, OnHandEnded`. A new street emits a snapshot (`beginStreet` → `emitState`) so a reconnecting client and
  a client that only reads `room:state` see the board and the options without the `poker:street` event.
- **Tests**: `internal/poker/{eval,pot,table}_test.go` (the rankings against known hands, the wheel, Omaha's
  exactly-two, side pots and odd chips, every variant's flow on the fake clock, timeouts, leaves, the restart);
  `internal/socket/poker_test.go` (the wire, `wrong_game` both ways); `tools/parity/poker.test.js` (profile `poker`:
  all four variants over real sockets with the independent oracle and the money audit). `tools/bot.js --category
  texas_holdem|omaha|five_card_draw|three_card_poker` plays a loose game from `poker:yourTurn`'s options.

---

### 6.6 The winning tax, player levels, badges and the daily XP (table-tax branch; owner, 26–27 Sep 2026)
**Fresh deployment, no migration logic** (owner: "we will do fresh deploymnet, so we don't need migration logic"): every table
and column below is in `V1.0.0__baseline.sql`'s CREATE TABLEs and every row in `V1.0.1__seed.sql`; nothing ALTERs anything — but
the one-time missions' three `xp_sources` columns (28 Sep 2026), which a database already holding the daily XP lacks, each have a
catalogue-guarded block too, and `player_xp_missions` is a plain CREATE TABLE IF NOT EXISTS.
- **The tax** (`game/tabletax.go`): at a table that TAXES ITS WINNERS (`TableConfig.WinnerTax`; `table_configs.winner_tax`, a
  `LOBBY_TABLES` entry's `tax=1`) — **every public Seen, Blind and Variation table** (owner: "Apply this tax rule on all the
  tables, blind, seen, variation"); never a private table or a poker room — the ONE winner of a hand pays their rate of their
  **winnings** (`WinnerWinnings` = the pot less the winner's own contribution; owner: "tax will be on total pot amount - amount
  player contributed") and only when those winnings are **50 Lakh or more** (`WinnerTaxMinWinnings`, `table_configs.tax_min_winnings`,
  env `WINNER_TAX_MIN_WINNINGS` 5000000; "no tax for winning amount less than 50 Lakh" — 30 Lakh at first: "30 lakh is the limit on
  winning amount not on pot limit"). `TableTax` floors, overflow-safe.
  The seat is credited the pot less the tax; the ledger writes the win GROSS and the tax as its own **`table_tax`** row (action
  `<handId>:tax:<userId>`), so a hand's `hand_*` rows still sum to 0. The rate is captured when a seat sits down
  (`NewPlayer.TaxBps`) and refreshed from every hand-end settle (`SettleResult.TaxBps`); a hand pays the rate it was dealt with.
  Wire: `room:state.winnerTax` + `winnerTaxMinWinnings`, `you.taxBps` (the viewer's own; no seat carries another's), and
  `game:handEnded.tax`/`taxBps` — all ABSENT on an untaxed table, whose bytes are unchanged; menu entries carry `winnerTax` and
  `winnerTaxMinWinnings`. Metric `game_table_tax_chips_total{category}`.
- **Levels** (`player_levels`, `db/levels.go`): 50 levels by XP alone, each with a title, an emoji and a rate — the owner's
  bracket, **20% at Level 1 down to 6% at Level 50** (round(2000 − (L−1)·1400/49) bps). Levels and XP NEVER expire; XP never
  grants a badge ("VIP Tag is not granted by XP"). A steeper slab — 30% at Level 1, 20% at Level 5, 2% at Level 50 — was asked
  for on 27 Sep 2026 and withdrawn the same hour ("don't apply new tax slab rate") once it was pointed out that, with every
  player holding Regular at 20% and the LOWEST rate charged, Levels 1–4 would never apply.
- **The levels' art** (owner, 29 Sep 2026: "Instead of using icons use lottie animations json for showing player Level and
  update the database according to that and UI … if there is no url, you show empty icon … meanwhile i will provide u other
  urls"): `player_levels.asset_url`/`asset_format` (the badges' twin; in the CREATE TABLE and two catalogue-guarded ALTERs —
  nine guarded ALTERs now, §7.3), sent as `assetUrl`/`assetFormat` (omitted when none) on `user.playerLevel`, its `next`,
  every `GET /api/levels` rung and a friend profile's `level`. **The seed fills a level's art only where `asset_url` IS NULL**
  (a guarded `UPDATE … FROM (VALUES …)` right after the ladder's INSERT in `V1.0.1__seed.sql`), every boot: a URL added to that
  list reaches every database at its next boot, production's included, while an owner's own URL — or `''`, none on purpose —
  is never touched. **All 50 levels have art** (the owner's list, 29 Sep 2026: 14 first, the other 36 the same evening); each
  file was checked for what a phone cannot play (§12.3) and played in the app's own Lottie player, and SIX are served by this
  server as fixed copies in `go-server/public/levels/` (served in production like `profiles/`;
  `TestTheLevelArtServedHereIsInThePublicDir` holds each to a Lottie with no `loopOut`): Level 1 `newbie.json` and 41
  `overlord.json` (their `loopOut('pingpong')` baked, `tools/lottie/bake_loop_expressions.py`), 20 `high-roller.json` and 25
  `supreme-ace.json` (their `loopOut`s baked), 22 `royal-ace.json` (a `Math.sin` bob of the whole badge, sampled into a
  keyframe a frame) and 32 `royal-titan.json` (two paths that copied other layers' paths by expression — empty on a phone —
  given those paths). Level 20's first upload was 4.1 MB of 161 embedded images; the owner replaced it the same evening
  (43 KB), and the seed moves exactly that old URL onto the new file (`TestLevel20sFirstArtIsMovedOntoItsReplacementAndNothingElse`).
  The other 44 are the owner's Drive files; what expressions they keep a phone skips harmlessly (overshoot and
  inertial-bounce finishes; 28's and 40's `time × Rotation Speed` spins, whose speed is 0). Heaviest now: 47 (Immortal King),
  1.6 MB of 102 embedded images. **Every level's art is kept on the phone** (owner, the same day: "Make sure you cache the all
  level icons in phone"): reading the ladder (`GameState.loadLevelLadder`, at a sign-in when not held) hands every level's
  art URL to `PictureCache.keep`, which fetches each one not yet on the disk, one after another, and writes it there WITHOUT
  holding it in memory (the memory layer is 64 entries, the faces on screen); after the first run it costs a directory
  lookup a URL and no network, and a level shown reads its file from the disk (`test/level_art_cache_test.dart`). The
  `or` a check finds on a star shape (`sr`) is its outer ROUNDNESS, not 3D orientation. A changed URL goes into the seed's
  VALUES and `levels_test.go`'s `ownersLevelArt` together. The emoji (`icon`) stays in the table and
  on the wire for anything with no art to draw. **The app** (`widgets/level_art.dart` `LevelArt`, over `EmojiArt` with its
  stand-in off, handing back the same subtree while its inputs hold so the one-second tick never rebuilds the Lottie) draws
  the art wherever the emoji was: the level screen's medal (`level-emblem-art`) and every rung of All levels (one size,
  `LevelRow.markSize` 30), the top bar's "Lv 10" line (`lobby-level-art`, 1.3× the line, painted past it so the row is no
  taller), the lobby's level key (its medal glyph where there is no art — a key is never an empty disc), **every player's
  pod at the table** (below), the player drawer's level line, the Stats drawer's head and a level up on the mission bar. The
  table's tax pill carried the level's art at its right for an hour and then no level at all (owner, the same day: "In
  gametable in tax pill only show badge icon and badge name and tax" — §6.6 "The app"). A level with no art yet shows an empty
  square where the mark has a fixed place (the medal, a rung) and nothing where it stands before words; words never carry the
  emoji any more ("Level 10 · Rising Star", "77 XP to Rookie", the level-up toast). Tests: `internal/db/levels_test.go`
  (the seeded art, the fill rule across a reboot, the served file), `upgrade_boot_test.go`, `db_test.go`; Flutter
  `level_screen_test` (the medal, every rung), `lobby_level_bar_test`, `table_tax_test` (the pill: badge only), with the
  fixtures' `levelArtUrl`/`primeLevelArt` (all 50, as the seed; a level with no art is written by hand where a test needs one).
  **Every player's level on their pod** (owner, 29 Sep 2026: "In gametable In every player pod show their game level icon on
  top right of player pod"): `room:state.seats[].level` = `{level, assetUrl?, assetFormat?}` (`game.SeatLevel`, `SeatView.Level`,
  ABSENT for a seat whose level is not known and on an empty chair) — the level and its art and nothing else of the standing (no
  XP, rate or badge of another player), public on every viewer's snapshot, at Teen Patti tables (a poker room's view carries none).
  Taken at sit-down (`NewPlayer.Level` ← `db.User.Player()` ← `Standing.SeatLevel()`), refreshed by every hand-end settle
  (`SettleResult.Levels`, read from the same `Standing` the settle's `player:level` is — `Table.adoptLevels`, on the first
  attempt or the Settler's retry; a level below 1 is ignored), carried by a switch or consolidation move (`SeatInfo.Level`) and
  kept in the snapshot (`SnapshotSeat.Level`; an invalid one is dropped on restore, never a refused table). The app
  (`Seat.level`, `SeatLevel` in `dtos.dart`) draws it in a DISC in the pod's top-right corner, the viewer's pod too (owner, the same
  day: "Level icon on pod should be inside a circular container and increase its size also"; `SeatLevelMark` in `seat_pod.dart`,
  `seat-level-mark`): the table's charcoal in both themes (the tax pill's and the plates') under a 1.5dp gold rim, the raised step
  of the depth ladder's shadow and light, and the `LevelArt` (`seat-level-art`) at `artShare` 0.88 of it, clipped to the circle.
  `SeatPod.levelShare` 0.36 of the pod (the bare art it replaced was 0.3), flush with the pod's right edge and `levelLift` 0.03 of
  the pod over its top — INSIDE the corner, not centred on it: the seat ring sets the pods against the screen's edge, the head seat
  6dp under the top, and the far seats against the category tag and the wallet, so a disc centred on the corner ran off the screen
  or over them at every phone size (the first cut); 0.36 is the most the corner holds clear of the picture, the viewer's included.
  **The name line gives the disc its room** (`SeatPod.levelReserve`: the disc's width less the pod's padding, on the right only,
  so a short name sits left of centre beside it; on turn less by `turnRingOutset`, since the ring stands inside the pod's box
  and narrows the plaque while the disc stays put — "YOU" beside the dealer's button read "Y…" on turn until it did; "YOU"
  may also be set down to `SeatName.youMinScale` 0.62, and a shrunk name's letter spacing now shrinks with it — tracked
  "YOU" overflowed the room it was shrunk into) — which costs a long name: `SeatName` sets it down to 0.78 and then cuts it, and
  at 640x360 a guest's "Guest0E00B" is cut at ×1.0 and ×1.25 on a pod that wears a disc (whole without one, set smaller at ×1.25). A `Positioned`
  in the pod's outer Stack (`Clip.none`) — no layout, no seat moves — under an `IgnorePointer` (a tap is the pod's), placed from the
  pod's box, so it does not move when the turn ring grows round the plaque. Nothing where the level has no art yet or the server
  sent none. Tests: `internal/game/seatlevel_test.go` (every viewer sees it, a level-up adopted from the settle, the restore),
  `internal/app/tabletax_test.go` (real sockets: Level 1's art on every seat), Flutter `test/seat_level_test.dart` (the wire; the
  disc — a gold-rimmed circle with a shadow, its size, its corner, the art centred, clipped and larger than before; none without
  art; the name line clear of it and centred where there is none; the tick rebuilding nothing under it; both themes; and at two to
  five places at 592x360–1280x800 ×1.0/×1.25 every disc on the screen and over no other seat, the pot, the viewer's cards, the
  tag, a key, the Shop key, the wallet or its own picture; scene `levelsRoom()` and `placesRoom(levels:)` / `seatLevelJson` in
  `table_scenes.dart`).
- **Badges** (`badges`, `user_badges`, `badge_purchases`): held BESIDE the level, many per player, each grant with an
  `expires_at` filled from `validity_days` by the `user_badges_expiry` trigger (0 = for ever). The rate a player pays is the
  **lowest of their level's and every unexpired badge's** (`playerLevelJoins`, the one statement of the rule; `db.Standing`,
  embedded in `db.User`, so `user.playerLevel` / `user.badges` / `user.taxBps`). The seeded catalogue: **Regular** — every player's
  by default (`is_default`), 20%, lifetime, ₹0, a Lottie, never in the store; and the **Royal Ace / King / Master /
  Emperor / Legend / King of Kings** — 0% for 7/15/30/45/60/90 days at **₹500 / 1,000 / 1,800 / 2,500 / 3,300 / 4,500**
  (Play's own India prices since 27 Sep 2026, owner: "change price to match"; ₹499 … ₹4,499 before), each the owner's Drive Lottie
  (`asset_url`/`asset_format`). **Prices are always whole rupees** (`price_inr`, "price in badges will always be in inr currency"). The store LISTS a badge iff it is not default and has a price. A badge with a `play_product_id` is sold
  through Play (`POST /api/purchases/google` → `db.BadgeForProduct` → `db.CreditBadgePurchase`: one transaction, replay-guarded
  by the purchase token in `badge_purchases`, a running grant EXTENDED by the validity); **every Royal badge has one** (owner,
  27 Sep 2026, who created the six in the Play Console that day — `badge_royal_ace_499`, `badge_royal_king_999`,
  `badge_royal_master_1799`, `badge_royal_emperor_2499`, `badge_royal_legend_3299`, `badge_royal_king_of_kings_4499`; in the seed
  and set by hand on production's rows), so each badge's key shows Play's price and opens Play's sheet. Until then none had one and
  every key asked for it through support; a product set to NULL takes a badge back to that key, and a grant without a purchase is
  still the seed header's `INSERT INTO user_badges …`. `price_inr` is Play's India price for the badge's product (Play
  charged a rupee more than the first list — ₹500 for ₹499, as `chips_a_99` is ₹100 — so the rows were moved to match; the ids keep
  the old figures, since Play never renames a product). The VIP,
  Royal VIP and Elite VIP badges (5%/3%/0%, five years, by hand) were seeded for a day and removed (owner, 27 Sep 2026: "remove
  the entry vip, royal vip and elite vip"); the tests that need a rate between Regular's and the Royal badges' add their own
  badge row (`ownerBadge` in `db/levels_test.go`, a 5% GOLD in `app/tabletax_test.go`).
- **The daily XP** (`xp_sources`, `player_xp_claims`, `xp_settings`, `player_xp`): the owner's eight sources, each ONCE per
  24-hour window that opens at the player's first completed hand — 🎮 Play 15/60/120 active minutes +3/+20/+50, and 👥 Win by
  Pair +1, 🎨 Color +2, 🃏 Sequence +4, 💎 Pure Sequence +8, 🔥 Trail +20 (108 XP a window); no daily cap (`daily_cap` NULL). A
  "Win by" source is the hand the winner held as the table ranks it (`SettleEntry.WonWith`, wild cards counted), at a Teen Patti
  or Variation table; the hand-end settle awards it and opens/rolls every finisher's window. Play time lives in the LIVE store
  (`live.PlayClock`, `xpplay:<userId>`), and `xp.Tracker` asks `db.XP.AwardPlayTime` when a hand crosses a 15/60/120-minute mark.
  `db.awardXP` is the only writer. A player whose XP changed is told on the socket: **`player:level`** (a `db.Standing`).
- **The one-time missions** (owner, 28 Sep 2026: "Add a new mission type: ONE_TIME … permanent missions that a player can
  complete only once … Do not remove or modify the existing DAILY behavior"; branch `one-time-missions`). `xp_sources` gains
  **`mission_type`** (`DAILY` — the DEFAULT, every source before it — | `ONE_TIME`, a CHECK), **`target`** (≥ 1) and **`scope`**
  (NULL any table, an engine `teen_patti`/`poker`, or a category `seen`…`omaha`; checked by the server) — each in the CREATE TABLE
  AND a catalogue-guarded block, as `is_bot` (§7.3; seven guarded ALTERs then, nine since the levels' art). ONE_TIME kinds (`db.XPKind*`): `HANDS_PLAYED`,
  `HANDS_WON`, `CATEGORIES_PLAYED` (different categories) and `VARIATIONS_PLAYED` (different variations); a DAILY source keeps
  `PLAY_TIME`/`WIN_HAND`, and a row of a kind outside its type's is left out. **`player_xp_missions`** (PK `user_id, source_code`,
  → `users`/`xp_sources` CASCADE): `progress`, `seen TEXT[]` (the distinct values counted), `completed_at` (0 = open; frozen once
  set), `xp_awarded`, `CHECK (completed_at > 0 OR xp_awarded = 0)`. **Progress is moved in the hand-end settle's transaction**
  (`advanceMissions`, before `awardXP`) for every player it resolves as having COMPLETED the hand (the daily window's rule: an
  outcome row not `LeftMidHand` — a leaver's hand never counts), by the existing definitions: played = `DidChaal` (requirement 16,
  `player_stats.hands_played`'s rule: a chaal/raise/show, at poker chips beyond the forced ones), won = `IsWinner` (3-Card Poker:
  beating the dealer or a dealer that does not qualify; a push is neither), category = **`SettleRequest.Category`** (new; the
  table's, set by `game.Table` and `poker.Table`), variation = the hand's `HandStats.Variation`. **Completion is inside `awardXP`**:
  one `UPDATE player_xp_missions SET completed_at = now … WHERE completed_at = 0 AND progress >= target`; only the statement that
  changed the row adds the XP — to LIFETIME XP only, never `window_xp`, never limited by a daily cap — and the whole settle (progress,
  completion, XP) rolls back with a replay's `duplicate_action` (§5.1), so neither a retry, a concurrent settle (other pool, other
  process) nor a restart gives it twice (`missions_test.go`, `missions_internal_test.go`: worker A completes, worker B waits on the
  row and grants 0). Nothing at a window's end touches the table. XP off (no `xp_settings` row) moves nothing. Bots are not special:
  as for the daily XP, an `is_bot` account earns them. Account deletion keeps the rows (as `player_xp`). **The owner's eight**
  (V1.0.1, `ON CONFLICT (code) DO NOTHING`, sort_order 110–160 and 210–220, **245 XP in all** — a tenth of the 2,450 first given;
  owner, 28 Sep 2026: "reduce the XP Granted value"): First Hand 1 played +5 · First Win 1 won +10 ·
  Getting Started 10 played +15 · First 5 Wins 5 won +30 · Card Player 50 played +50 · Winning Streak 10 won +75 (ten wins in all,
  not consecutive — the owner's name) · Variation Explorer 1 played `variation` +10 (the other
  reading, different variations, is one UPDATE: `kind = 'VARIATIONS_PLAYED', scope = NULL`) · Game Explorer 3 `CATEGORIES_PLAYED`
  +50 (5 at first; owner, the same day: "make it 3 instead of 5" — with Poker hidden the app offers three games, Seen, Blind and
  Variation, so five could never be reached). **A target lowered by hand** on a database where a player is already at or past it
  completes at the next hand that MOVES the mission (`advanceMissions` returns only the rows it moved): a count mission's next
  counted hand, but a different-games or different-variations mission moves only for a value it has not counted, so such a player
  waits at "3 / 3" for a game they have not played. **The four Poker missions first given with them** (First Poker Hand, First Poker Win, Texas Hold'em Debut, Poker Regular —
  sort_order 170–200) **were taken out the same day** (owner: "Remove Poker and texas related one time XP from DB, we don't need");
  a database that ran the seed with them keeps its rows until they are deleted by hand (`DELETE FROM xp_sources WHERE code IN
  ('FIRST_POKER_HAND','FIRST_POKER_WIN','TEXAS_HOLDEM_DEBUT','POKER_REGULAR')` — `player_xp_missions` CASCADEs). A scope is still an
  open choice for a row an owner adds (`poker`, `texas_holdem` …; `TestScopedMissionsCountOnlyTheirGames` inserts its own). Progress
  counts from the deploy (no backfill from `player_stats`). The seeded missions alone lift a player to Level 2 (100 XP; 19.71%),
  where the first figures reached Level 9.
  **Wire**: `user.playerLevel.missions` — `[{code, type:"ONE_TIME", progress, target, completed, completedAt?, xpAwarded?}]` for every
  ACTIVE mission the player has moved or completed (absent when none; no reset or expiry field) — on every account read and in
  `player:level`, which the settle now also pushes when only a mission's progress moved (`SettledHand.Levels`).
- **`GET /api/levels`** (public, no-cache): every level, every active badge (price, validity, product, art), the sources (code,
  name, icon, kind, `type` (DAILY), `playMinutes`/`hand`, xp, times) and the cap — and since 28 Sep 2026 **`missions`**, the active
  ONE_TIME ones with a target (`type` ONE_TIME, `target`, `scope`), NEVER among `xpSources`: an older app sums every `xpSources`
  entry into the day's "108 XP" and files an unknown kind under "More ways to earn XP".
- **The app** (`widgets/table_tax.dart`): on a taxing table's felt, under the tag, a pill — since 29 Sep 2026 the badge alone
  (owner: "In gametable in tax pill only show badge icon and badge name and tax"): the NAME of the badge the player holds that
  brings their rate lowest (`User.shownBadge`, `badgeTitleOf`) over the rate: "Regular" over "17.43% TAX" (the level's title
  over "Regular · 20% TAX" before; with no badge known, an older server, the rate alone), with that badge's Lottie as the pill's
  EMBLEM at its left, from the plate's top edge to its bottom (`WinningTaxTag.emblemSize`: both lines
  and their padding — the felt reserves exactly that, so it moves nothing; owner, 27 Sep 2026: "increase the badge icon size which
  is shown in game table"; a line tall before), scaled with the words where the slot is narrow; tapped, **the lobby's level screen** — its three tabs, below — since 27 Sep 2026 (owner: "when i click the
  text on my level in gametable, it should pop the same UI which it shows in Lobby about player level, daily xp and levels";
  `showTableLevelInfo`, the `LevelScreen` behind the table's own scrim, `showTableDialog`). Until then it opened the
  **two-pane** popup (standing, rate, level, XP, next level, badges and the daily list on the left; all 50 levels with their
  rates, the viewer's lit, then the badges on the right — the owner had it restored once: "restore that UI, only change was in
  Lobby"), which is KEPT, with its tests (`table_tax_test` opens it directly, `_openTwoPanes`), but opened by nothing on the
  felt: going back is the pill's one line (`showWinningTaxInfo`). It takes the level screen's round close key, its countdowns,
  its badges' time left and its daily ticks following the clock by themselves (`LevelClock`), and "Winning Tax" capitalised. The lobby's **level key** (`LevelKey`, beside Friends, the level number on it) opens
  the **level screen** (`widgets/level_screen.dart` `LevelScreen`, polished 27 Sep 2026 — UI only; `showLevelInfo` →
  `WinningTaxInfo(fromLobby: true)` → `LevelScreen`) in **four tabs** (three until 28 Sep 2026), `LevelTabs`: a glyph and a word each, the active one gold,
  the others muted, sharing the row equally while every word fits its share and by each word's own width once one does not
  (`LevelTabs.widthsFor`: "One-Time XP" beside "My level" at 640dp and text x1.25 — every label ≥ 0.89 with real Indic fonts), over a hairline with a gold underline that SLIDES to the tab tapped (`levelTabSlide` 220 ms, ease-out, no
  bounce) while the content cross-fades and slides 3.5% the same way; title, tabs and a round glass close key (`LevelCloseKey`, a
  34dp disc in a 44dp target) share one line from 560dp of content, two lines below. **My level**: a hero (`LevelHero`) — the
  level's mark in a struck-gold medal with its number (`LevelEmblem`), "Level 10" over the title (MAX LEVEL at Level 50), and at
  the right **Winning Tax**, the rate the account pays (`myTaxBps ?? paysTaxBps`, `formatTaxRate`) and what sets it — following the
  clock (`standingAt`): a badge that runs out while the screen is open stops setting it the moment its card says Expired (the same
  lowest-rate rule over the badges still running) and the account is read again (`refreshUser`) for the server's own figure; the XP card
  (`LevelXpCard`) — "23 / 100 XP" (XP against the next level's threshold) and "77 XP to 🔰 Rookie", a bar from this level's
  threshold that fills ONCE (`LevelBar`, a `TweenAnimationBuilder`; it waits for the ladder, which says where the level starts),
  "Next: Level 2 · 🔰 Rookie · 100 XP · 19.71% tax"; the badges as cards (`HeldBadgeCard`: the Lottie 44dp, an "Active" tag,
  "0% Winning Tax", Lifetime / days and hours left ("29d 14h left", `grantOf`, however long the grant — never an end date) /
  "Expires in 5h 9m" in amber within a day / "Expired", dimmed, for a grant that runs out while the screen is open —
  there is no badge history, so that is the only Expired it can show — and "Sets your rate" on the one that does); a player with
  Regular alone gets `RoyalBadgeHint` — its rate the catalogue's lowest (`royalRateOf`, "…down to 0%"), shown once the catalogue
  is read — with a "See badges" key to the store's Badges shelf; then "How Winning Tax works", a line
  each: only the winner pays, on net winnings; net winnings = the pot − your own chips; the floor; higher levels pay less; a badge
  can lower it; the lowest rate applies. **Daily
  XP**: `DailySummary` — "Earned today 24 / 108 XP" (each source's XP × its claims in the running window, or `today.xp` where a
  cap is set; `DailyClaims`) over a bar, the reset counting down ("Resets in 23h 45m 19s", `ResetsIn`) or, before the day's first
  hand, "Your day starts with your next hand." — and a window that ends while the tab is open turns to that at once, its ticks
  cleared (the tab's body is a `LevelClock<bool>` on the window); **Daily XP Complete** only when every source's claims reach its `times`; the
  play-time milestones as a TRACK (`PlayTrack`: 15 · 60 · 120 min, each rung reached ticked in the scheme's green with its +XP,
  the track green as far as the last one — completion green, progress gold) under the line "Each milestone gives its XP once a day as your active play reaches it, and they add up" — the server grants
  EVERY rung the window's play has reached (`xpRules.played` → `AwardPlayTime`: 73 XP at 120 minutes), so the screen never says
  "the highest milestone only"; the winning hands as tiles (`HandSourceTile`; only `WIN_HAND` sources — a kind the build has no heading for goes under "More
  ways to earn XP"). **One-Time XP** (28 Sep 2026; a tab of its own beside Daily XP since the owner asked the same day — "the
  tab in UI one Time XP, on the side of Daily XP" — it was a section under the daily list for its first hours; `LevelInfoTab.oneTime`,
  `Icons.task_alt_rounded`, pane key `winning-tax-one-time`): the **One-Time missions** (`OneTimeMissionTile`, 230dp tiles in the
  hand tiles' style, no `LevelClock` — no window touches them): the server's title, what it asks in the player's words (`missionTask`,
  `missionGameName`: "Play 10 hands", "Play 1 Variation hand", "Play 3 different games"), "+XP", "7 / 10" beside a 6dp `LevelBar` while
  open, the green tick and "Completed" once done (the tile edged green), never a countdown, the heading "n / 8 completed"; from a
  server without missions the tab says there are none (`xpOneTimeNone`, key `one-time-none`) (`LevelLadder.missions`/`sourceOf`, `LadderSource.type/target/scope`, `PlayerLevel.missions` →
  `MissionProgress`; `dailyMax` sums the daily sources alone, `levelSignatureOf` includes the missions; 15 strings in all five
  languages, and the tab's `xpOneTimeTab`/`xpOneTimeNone`; `test/one_time_missions_test.dart`, scenes `one_time` and `one_time_end` in
  `test/level_shots.dart`). **All levels**: a fixed head — the first column's name (Level, or Badges once their own heading has scrolled
  under it), an outlined capsule key beside it down to the badges (↑ back to the viewer's rung once there), Tax at the right —
  the 50 rungs (`LevelRow`: the number on a disc — solid gold for the viewer's, tinted for a rung passed — the mark at ONE size in a
  42dp slot (two emoji fit whole), title, threshold, "You" / "Next", the rate), scrolled to the viewer's, then the catalogue
  (`CatalogueBadgeRow`: Lottie, "Everyone · Lifetime · Free" / "Lasts 15 days · ₹1,000"; a Royal badge on a struck-gold ring with a
  faint gold edge and "Available", or "Yours" and the time left where the viewer holds it) and "Badges are held beside your level;
  XP never earns one." Solid tags ("You", "Yours", MAX LEVEL) are struck gold (`AppTheme.goldFace`) under charcoal in both themes;
  the quiet ink is a step firmer by night (`levelQuietInk`); tabs and close keep their tap for a screen reader. The screen
  `select`s `levelViewOf` — the account compared by `levelSignatureOf`, so a fresh copy of the same account rebuilds nothing —
  instead of watching GameState (which notifies every second): only `LevelClock` pieces — a countdown, a grant's words, the hero's
  rate, the daily window — follow the clock, so the tick never rebuilds a Lottie or refills a bar. 33 strings in all five languages. `test/level_screen_test.dart` (levels 1/2/10/25/50, the figures, the
  badges, the daily states, the milestones, long names in English, Hindi and Bengali, the sliding underline, the tick — rebuilds
  recorded with `debugOnRebuildDirtyWidget` on every tab —, a grant and a daily window running out while open (the hero, the ticks,
  the table popup too), a screen reader pressing each tab and Close, no badges at all, the ladder's heads, the table popup's two
  panes, and every tab
  at 592x360–1280x800 ×1.0/×1.25 in all five languages and both themes); pictures by hand, `test/level_shots.dart` (fixtures in
  `test/level_fixtures.dart`). **No lobby card carries the player's standing** (owner, 29 Sep 2026: "Remove the badge and
  level symbol and tax text from card, seen card, variation, all card, instead add a badge on profile pic top right lobby"):
  the Seen, Blind and Variation cards and every taxing table card carried, from 27 Sep 2026, a corner of the level's mark,
  the badge that sets the rate and the rate paid (`LobbyCardBadge`, which replaced the "20% TAX" pill on the boot's line);
  it went, with its two strings (`cardBadgeSemantics`/`cardRateSemantics`). **The badge is on the player's picture instead**
  — the top bar's and, the same day ("In settings profile also u need to add badge"), the Settings drawer's portrait (72dp, 90dp since 30 Sep 2026 — owner: "make it large more 25 percent, keep badge size same"; its badge and pencil still sized from 72, `markDiameter`)
  (`widgets/avatar_badge.dart` `AvatarBadge`, laid by `_AvatarWithPip(badge: true)`): the badge that brings the player's
  rate lowest (`User.shownBadge` — Regular for everybody, a Royal badge where one runs) as its own Lottie (`BadgeArt`),
  `AvatarBadge.sizeFor` 0.74 of the picture's diameter, its middle on the rim at the picture's top-right
  (`centreFor`: 0.82, 0.17 of the diameter — at 0.84 the Regular rosette's ribbons reached the name on a 640dp phone), over
  the picture and its edit pip. No level mark and no rate (the level is the line under the name; the rate the level screen's
  and the ⓘ popup's). It takes no layout (a `Positioned` in the picture's `Stack`, `Clip.none`: the name keeps its box, the
  top rail's arithmetic holds) and no taps (`IgnorePointer`: a tap on it is a tap on the picture). No badge (an older
  server): nothing. The top bar watches GameState and hands it a new widget every second, so it `select`s only its figures
  and hands back the SAME subtree while they and its size hold: the tick never rebuilds the Lottie — `level_screen_test`'s
  "rebuilds nothing" check, with the lobby behind the level screen, holds it. A screen reader hears "Regular badge"
  (`avatarBadgeSemantics`, all five languages). `test/avatar_badge_test.dart` (no badge, level mark or rate on any card —
  front, category tables, engines and poker games; which badge; none without one; a purchase while open; the tick; taps;
  the words; the Settings portrait; and on the picture's top-right, on screen, clear of the name, the name's box unchanged
  at 592x360–1280x800 ×1.0/×1.25, English and Hindi, both themes). The table info
  says "No tax on winnings under 50 Lakh."; the store's last shelf is **Badges** (`StoreTab.badges`): each listed badge's Lottie,
  name, "0% Winning Tax", validity, and its price on the key — the key opening Play for a Play badge, else the support popup
  (address to copy, a `mailto:` key). Every string in all five languages. A mission a `player:level` shows completed is
  announced on a bar at the top of every screen for 5 s (§8.4 "The XP mission bar"); a level up that came with one is said on
  that bar, with the winning tax it changed ("Winning tax now 19.71%"), not in the toast.
- **Also on this branch** (owner, 27 Sep 2026): a new account starts with **10 Lakh chips**, 20 hammers and 1 missile (since 30 Sep 2026
  the `welcome_rewards` rows, §7.3, seeded 5 Lakh chips)
  (`WELCOME_CHIPS` 1000000); **Blind 200 is open up to 20 Lakh** (`ENTRY_CAP_MAX_CHIPS` 2000000), **Blind 5,000 up to 20 Crore**
  (`max=200000000`; "for 5000 keep entry upto 20 Crore"), **Blind and Variation 50,000 up to 200 Crore** (`max=2000000000`; "for
  50000 table keep entry upto 200 Crore" — Seen 50,000 stays open to all); and **the two 10 Lakh tables, Blind and Variation, are
  20 Lakh tables** ("Change 10 Lakh boot table to 20Lakh boot table"; `TABLE_STAKES` `200,5000,50000,2000000`, both still 50
  Crore or more to enter). In config's `Defaults()`, `.env.example` and the seed's `table_settings`/`table_configs` rows alike.

## 7. Server — platform

Go equivalents: `socket/index.js` → `internal/socket/{handler,wire,payload}.go` on top of
`internal/sio` (our own Engine.IO/Socket.IO server, websocket only); `auth/routes.js` →
`internal/auth/{http,handlers}.go`; `db/` → `internal/db/`; `config/index.js` →
`internal/config/config.go`; `metrics/index.js` → `internal/metrics/{names,metrics}.go`. The full
event-by-event contract is also written down in `go-server/PORT_NOTES/specs/spec-socket-protocol.md`.

### 7.1 Socket.IO contract (`socket/index.js` → `internal/socket/handler.go`, `wire.go`)
Handshake: JWT in `handshake.auth.token`; `io.use` is async (`await findById`). Failures →
`connect_error` `missing_token | invalid_session | unknown_user | account_disabled | session_replaced | unauthorized`, and the app
version gate's `update_required | maintenance` (below, 28 Sep 2026). One live socket per
user (`session:replaced` to the old one). **One signed-in DEVICE per account** (owner, 28 Sep 2026: "when someone is already
logged in with google account in one device and some other guy tries to login with same google account in diff device, the
first one will be auto logout and showing message someone has logged in your account and new guy will see the live state of
game"; §7.2 "One signed-in device"): every login counts a new session (`user_sessions.version`, §7.3) and signs it into its
token as `sv`; a token whose `sv` is not the account's current one is refused **`session_replaced`** at the handshake (and at
every signed-in REST door, 401), and the login itself ends a live socket of an EARLIER session before it answers
(`Deps.SignedIn` → `socket.Handler.ReplaceSessions`, which leaves the login's own or a later session alone): that socket is told
`session:replaced` and let go, its seat held for the reconnect grace, which the new device's connection takes over
(`room:joined`, the live hand). A join from a socket whose session was replaced in between is refused `session_replaced` by
`freshUser`, and the guard ends that socket (never the account's newer one). On connect: `session:ready {user, config}`; if still seated
→ `room:joined` + `chat:history` (**why restarted bots land on their previous table**).
**The app version gate at the handshake** (owner, 28 Sep 2026; §7.2 "The app version gate"): the auth object also carries
**`appPlatform`** (`android` | `ios` — the app builds; `bot` | `tool` | `web` — this project's own clients) and **`appVersion`**
(MAJOR.MINOR.PATCH) beside `token`, and the middleware judges them BEFORE it reads the token (`appversion.Gate.Admit`): a build below
its platform's minimum is refused **`connect_error update_required`** and a platform in maintenance **`connect_error maintenance`**,
each with `data: {message, storeUrl?, minimumVersion?}` (`sio.ConnectRefusal` — the one CONNECT_ERROR that carries data). A
middleware refusal is final for socket.io's clients (no reconnect storm; `TestAHandshakeRefusedForAnOldVersionIsNotRetried` proves it
with the real socket.io-client, and the Flutter client lets the socket go as well). A socket that declares nothing — every install
that predates the gate, and any script — is admitted unless `APP_VERSION_REQUIRED` is on. **An already-connected socket is never
dropped when the rows change**: the gate is at the door (a handshake, a REST call), so an operator's UPDATE never cuts a player off
mid-hand; a real maintenance is a restart, whose graceful shutdown settles the pots (§14.3). `session:ready.config.minClientBuild` is
now per connection: the larger of `MIN_CLIENT_BUILD` and the build number its platform's `minimum_version` translates to
(`appversion.LegacyMinClientBuild` — an undeclared socket is judged by android's row), which is how raising a minimum also holds the
installs that predate the gate on their own update screen.

`guard`: rate limit **30/5s per socket, and (Go, 24 Sep 2026) the same 30/5s per ACCOUNT** — a second limiter keyed on the
user survives a reconnect, which used to reset the count (`userLimiters`, pruned by the presence heartbeat) — (a trip acks `{ok:false, code:'rate_limited'}` **and** emits
`game:error rate_limited` — both servers; the old "no ack" note was stale), then ack
`{ok:true,…}` or `{ok:false, code, message}` **and** `game:error` (reported twice — clients dedupe).

| Client → server | Payload | Ack |
|---|---|---|
| `lobby:list` | `{category?}` | `{tables, options}` (used only by scratch/tests); each `options.tables[]` entry carries `minChips`/`maxChips`, the stack band |
| `room:quickJoin` | `{bootAmount?, category?}` | `{roomId, code, category}` |
| `room:create` | `{isPrivate=true, category?}` | `{roomId, code, category}` — boot ignored |
| `room:joinCode` | `{code}` — exactly 8 letters or digits, any case (owner, 13 Sep 2026: every table's code is issued 8 long, `util.DefaultRoomCodeLength`; any other shape → `invalid_room_code` "Table codes are 8 letters and numbers" before any lookup; Flutter's field lets nothing else in and holds Join until 8) | `{roomId, code, category}` |
| `room:switch` | `{}` | `{roomId, code, category}` |
| `room:leave` | `{}` | `{roomId}` or `{}` |
| `game:action` | `{action, amount?, actionId?}` | table.act result; `actionId` (≤64 chars) becomes the ledger row's unique id; `action:"missile"` acks `{ok, action, missiles}` (§6.1). `action` must be a JSON **string** (`["see"]` → `unknown_action`, as Node; 24 Sep 2026). A `chaal` whose amount is a raise rung (≥ 2× the first) is played, acked and broadcast as the **`raise`** it is (same day) — the Flutter client sends `chaal` only for the first rung |
| `game:sideshowRespond` | `{accept}` (only `=== true` accepts) | `{accepted, packedUserId}` |
| `game:selectVariation` (**Go only**, variation tables, §6.1/§6.4) | `{variation}` — one of the seven exact wire values; **no player id**, the chooser is the socket's user; any non-string is `""` → `invalid_variation` | `{variation, selectedBy, turnUp?, cardsPerPlayer}` |
| `game:selectCards` (**Go only**, 5-Card hands, §6.4) | `{cards:[3]}` — three of the player's OWN five, in any order; **no player id**, the chooser is the socket's user; a non-string entry is `""`, which names no card | `{picked, best, wasBest}` — the three that now play (in the order HELD), the strongest three those five could have made, and whether they are the same hand |
| `player:requestCards` | `{}` | `{cards}` (empty unless seen) |
| `poker:action` (**Go only**, poker rooms, §6.5) | `{action, amount?, cards?, actionId?}` — `fold\|check\|call\|bet\|raise\|allIn\|play\|draw`; `amount` is the TOTAL street bet for bet/raise (safe integer, else `invalid_amount`); `cards` the codes to discard on a draw | `{ok, action, amount?, allIn?, discarded?}`; `wrong_game` at a Teen Patti table, and `game:action`/`game:sideshowRespond`/`game:selectVariation` answer `wrong_game` at a poker room |
| `chat:message` | `{text}` | `{messageId}` — own 5/5s limiter (`chat_rate_limited`) |
| `chat:emoji` (**Go only**, 26 Sep 2026, §7.2 "Emojis") | `{emojiId}` (a number or its text) | `{messageId}`; refusals in order `not_in_room`, `unknown_emoji`, `emoji_retired`, `emoji_locked` (not owned, or its rental has run out — read from the DB on every send), `chat_rate_limited` (the SAME limiter as `chat:message`). The room then sends its ordinary `chat:message` whose `text` is the emoji's name and which carries **`emoji {id, name, url, assetFormat}`** — present only on an emoji line (a typed line is byte for byte what it was), kept in `chat:history`, at Teen Patti tables and poker rooms alike (`game.Room.PostEmoji`) |
| `chat:history` | `{}` | `{count}` (no client sends it) |
| `ping:rtt` | `sentAt` | `{sentAt, serverTime}` — **unguarded**, no `ok` |

| Server → client | Audience |
|---|---|
| `session:ready {user, config}` / `session:replaced` — `config` is the table-wide figures + `LobbyOptions` + `welcomeChips`/`minClientBuild`, and since 23 Sep 2026 **`tableConfigVersion`** (the ONLY change to it: the version of the table catalogue this server enforces, `GET /api/tables`' `version`/ETag, §7.2; `""` only on a server with no rooms). A client holding that version keeps its catalogue; one holding another fetches it again. `config` still carries the whole menu (`tables`), so an installed app older than the catalogue needs nothing new | socket |
| `room:joined` / `room:state` — `serializeFor(viewer)`; a Teen Patti snapshot carries `tablePicture` (the picture the table shows, §7.2; null when none; absent from a poker snapshot) | **per viewer** |
| `room:moved {fromRoomId, toRoomId, code, message}` — **no `state`**; the snapshot is the `room:joined` that follows | socket |
| `room:left` / `room:closed` / `room:kicked {roomId, reason, message}` | socket |
| `game:handStarted {…participants}` then per-socket `player:hand` | room |
| `player:cards {cards}` | owner only |
| `game:turn {userId, seatIndex, deadline, timeoutMs}` (no options) | room |
| `game:yourTurn {deadline, timeoutMs, options}` | player on turn |
| `game:action {userId, action, amount, pot, stake, reason?\|auto?}` | room |
| `game:sideshowRequested` / `game:sideshowResolved` | room (no cards) |
| `game:sideshowReveal {reveal}` | **the two players only** |
| `game:variationSelecting {userId, displayName, seatIndex, startedAt, deadline, timeoutMs, options}` / `game:variationSelected {userId, displayName, seatIndex, variation, selectedBy: PLAYER\|TIMEOUT\|LEFT, turnUp?}` (**Go only**) — both only repeat `room:state.variation`, which is all a reconnecting client has | room |
| `game:showdown {reveals, reason}` / `game:handEnded {…nextHandAt}` | room |
| **Poker rooms only** (Go, §6.5; a poker room sends NO `game:*`/`player:*` event and a Teen Patti table no `poker:*` one): `poker:handStarted {handId, handNo, variant, dealerSeat, smallBlind, bigBlind, ante, pot, participants}` · `poker:turn {userId, seatIndex, street, deadline, timeoutMs}` · `poker:action {userId, seatIndex, action, amount, street, pot, allIn?, reason?, discarded?}` · `poker:street {street, community, pot}` · `poker:draw {userId, seatIndex, discarded}` · `poker:showdown {reveals[{userId, seatIndex, cards, best, handName, category, won, outcome?}], community, dealer?, reason}` · `poker:handEnded {handId, handNo, variant, reason, pot, pots[{amount, eligible, winners[{userId, seatIndex, amount, handName}]}], reveals, community, dealer?, summary, nextHandAt}` (all with `roomId`) | room |
| `poker:cards {cards}` (the deal, and the new hand after a draw) · `poker:yourTurn {street, deadline, timeoutMs, options}` | owner only / player on turn |
| `chat:message` / `chat:history` / `game:error` | room / socket / socket |
| `friend:request {requestId, player, createdAt}` / `friend:accepted {requestId, player, friendsSince}` (**Go only**, Friends at the table, 26 Sep 2026, §7.2) — sent by the REST layer, not by a socket event: once `POST /api/friends/requests` (201) / its `…/accept` (200) has committed, to the request's recipient / original sender; `player` is a `PlayerCard` (the sender / the accepter), `friend:request` byte for byte an `incoming[]` item of `GET /api/friends/requests`. Lobby or table alike; never to a room, never kept for an account with no socket, nothing for a reject, a removal or a refusal | that account's live socket |

Production: **`https://prod.sungamestudio.com`** (REST + Socket.IO over TLS) since 24 Sep 2026 — verified that day: `/health` answered with the Go server built from `542e957` (table config from the database, the Redis live store), and `/api/tables`, `/api/profiles` and `/socket.io/` answer. `privacy/` and `account-deletion/` do NOT (404, rechecked the same day); the pages are served at `https://sungamestudio.com/privacy/` and `/account-deletion/` (§7.2). It was `https://api.sungamestudio.com` until then — a name that no longer resolves — which was also the Flutter default from 2026‑09‑08 until 24 Sep 2026, when the default became preprod (§3, `ServerConfig`).
Client coverage: **Flutter** never sends `lobby:list`, `chat:history`, `ping:rtt`, and never listens
to `game:handStarted`, `player:hand`, `game:turn`, `game:yourTurn` — it derives turn and options
from `room:state.turn` / `you.options`. Changing `you.options` affects Flutter; changing
`game:yourTurn` does not. **Browser** ignores `room:kicked` and all `game:sideshow*`.
**Variation tables on the wire** (Go only): `room:state.variation {selecting, userId, displayName, seatIndex, startedAt,
deadline, timeoutMs, options, selected, selectedBy, turnUp?}` — public, identical for every viewer, **ABSENT (not null) on
seen and blind tables and between hands**, so those snapshots are byte for byte what they were. While `selecting`,
`turn.seatIndex` is -1 and `you.options` null. `game:showdown`/`game:handEnded` gain `variation` + `turnUp`, and each
reveal (and sideshow-reveal hand) gains `wild` — which of its cards played wild — and, since 24 Sep 2026, **`playsAs`** beside it
(owner: "on show or sideshow, show updated cards not the base cards"): the hand as it was COUNTED, index for index with `cards`, a
wild card as the card it stood for; sent exactly when `wild` is; `handName`/`category` are what the hand
MADE. All omitted where they do not apply. `session:ready.config.categories` is `[seen, blind]` plus `variation` only
when the menu offers one. `variation.options` is the menu THIS hand offers (seven values, `FIVE_CARD` last) and
**`variation.cardsPerPlayer`** is what every player in the hand holds right now — 3 from the deal and under the six
three-card variations, 5 once FIVE_CARD is chosen and the server has topped each hand up; the ack and
`game:variationSelected` carry it too, `seats[].cardCount` and `you.cards` follow it, and a client never decides it. A
variation table's snapshot has `chipsHidden:true` and `maxPot:0`, and its `you` gains
**`hand {handName, category, wild:[], playsAs:[], best:[], picking?, pickDeadline?, pickTimeoutMs?, pickedBy?,
bestPossible?}`** — `best` is the three of `you.cards` that are counted (all three of a three-card hand, and under
FIVE_CARD the three the PLAYER chose, or the first three where their window lapsed). While `picking` is true a choice is
still owed and `handName`, `category` and `best` are all EMPTY — naming the hand would hand the player the answer — with
`pickDeadline` (epoch ms) and `pickTimeoutMs` (the WHOLE window, not what is left of it: the client's bar drains from
`deadline − total`, and sending the remainder drained it early). Once the choice is made `pickedBy` is `PLAYER` or
`TIMEOUT` and `bestPossible` names the strongest three those five could have made, which is what lets the table say "you
played this; the best was that" with no second ranking. A seat also carries a public **`picking`** while its player is
still choosing, so the table can say who it is waiting on — never WHICH cards they are choosing between; showdown `reveals[]` and the two sideshow-reveal hands gain
`best` only under FIVE_CARD, where `cards` holds all five — (never null arrays; ABSENT on seen and blind tables, while the viewer
is blind, and until the variation is chosen) — what the Flutter table turns the viewer's wild cards into.
Input guards (`socket/index.js`): `game:action.amount` must be a JS number and safe integer (strings/arrays/booleans → `invalid_bet`);
rate-limited requests are acked `{ok:false, code:'rate_limited'}`; `RoomManager.join()` asserts one seat per player (also closes
`room:create` to a seated player); `player:requestCards` outside a table → `not_in_room`. Covered by `internal/socket/invalidmoves_test.go` and `tools/parity/invalid.test.js`.
Disconnect: seat held `reconnectGraceMs` (60s) then `await rooms.leave(userId,'disconnected')`; just before
leaving, `resumeOffers.set(userId, {roomId, at})`. On connect: if still seated → `room:joined` + `chat:history`
re-sent (resume); else `takeResumeOffer(userId)` (fresh within `resumeOfferMs`, table alive and not full, offered
once) rides on `session:ready.resume {roomId, code, category, bootAmount}` and the Flutter client auto-joins it
with `room:joinCode`. Voluntary leave / kick never create an offer (the grace timer finds no seat) — **except an
idle kick of a player with NO live socket** (Go, owner 27 Sep 2026): the turn clocks keep running through the grace,
so a disconnected player is often shown out by their third missed turn before the grace ends, and `OnPlayerKicked`
then stores the same offer `graceExpired` would have (`putResumeOffer`, `RESUME_OFFER_MS`); the returning app sits
down afresh at 0 misses if the table is alive and has room. A connected idler still gets none
(`TestAnIdleKickWhileDisconnectedLeavesAResumeOffer`, `TestIdleKick`). Silent drops are noticed by the Engine.IO
heartbeat (20 s ping / 25 s timeout) before the 60 s grace starts; a phone the app itself sends to the background
closes its socket after 8 s (§8.1).
`room:switch` must `untrackRoom` *before* `switchTable` and re-track on failure; on success it untracks every table but the RESULT's `To`, and `room:moved` (`OnPlayerMoved`) is ignored unless the player is still seated at its target — a consolidation racing a switch left the socket subscribed to a table it was not seated at (24 Sep 2026).

### 7.2 REST (`auth/routes.js` → `internal/auth/http.go` + `handlers.go`)
`POST /api/auth/login {provider: google|guest, idToken|deviceId, displayName?}`
→ `{token, user, isNew, welcomeChips, welcome?}` — **`welcome`** (30 Sep 2026) only on the login that created the account: `{chips,
diamonds, hammers, missiles, pictures, tablePictures, emojis}`, what the `welcome_rewards` rows granted (§7.3), each item in its catalogue
route's shape with `owned:true`; `welcomeChips` is its chips (0 for a returning player) (**Facebook is switched off for now** — owner, 23 Sep 2026, `94061a2`:
`VerifyFacebook` and its `case` are commented out, so `provider:"facebook"` with an `accessToken` answers 400
`unknown_provider`, fake path included; the app draws no Facebook button; `docs/social-login-setup.md` §2 says what to
uncomment); `GET /api/auth/me` (takes off a worn rental that has run out, as
login and `GET /api/profiles` do — a saved session comes back through here, never through login); **the three lobby rewards
are gone** (owner, 30 Sep 2026: "Remove 24-hour daily reward, 4-hour bonus, and milestone reward") — the milestone (25,000
chips every 25 hands), the 4-hour bonus (10,000) and the daily bonus (1,00,000 chips + 1 hammer): `POST
/api/rewards/milestone|bonus|daily` answer the JSON 404 of any unknown `/api/*` route, and the account object carries no
`rewards` key, which is what hides all three chips in an installed app from before (1.7.0 draws them only when `user.rewards`
is there); **`GET /api/profiles`** — the picture catalogue from `profile_pictures`, active rows only, in
`sort_order` then `id`: `{profiles:[{id, name, url, assetFormat, currency, type, cost, durationDays, durationHours, sortOrder, owned, expiresAt}]}` — a rental lasts `durationDays` days plus `durationHours` hours (both 0: for ever; the hours since 14 Sep 2026, owner) — `assetFormat` is IMAGE (jpg/jpeg/png, one loader), SVG, LOTTIE (Lottie JSON/.lottie at the url) or RIVE (.riv binary), how the client renders what `url` serves; `currency` is COIN (chips), DIAMOND (`users.diamond`) or HAMMER (`users.hammer`, owner 14 Sep 2026), the wallet `cost` is paid from. The token is
**optional**: without one every FREE row reads `owned:true` and every PREMIUM one `owned:false`;
with one, `owned` also covers the premium pictures that player has bought. A bad token is ignored,
not refused;
`POST /api/profile/avatar {avatar|null}` — `avatar` is a **profile_pictures id** (a JSON number or
its text; it was a bundled file name before the catalogue existed). null/absent takes the picture
off. Unknown id → 400 `unknown_avatar`, retired row → 400 `picture_retired`, a premium picture the
player has not bought → **403 `picture_locked`**. **Allowed while seated** (owner, 13 Sep 2026; it was 409
`seated`): the new face goes straight onto the seat — `Table.SetAvatar` updates it, emits state, saves the snapshot;
**`POST /api/profile/picture/buy {pictureId}`** — unlocks a premium picture with chips: one
`picture_purchase` ledger row (`action_id` `picture:<userId>:<pictureId>`, UNIQUE, so a double click
cannot charge twice) plus a `user_profile_pictures` row, in one transaction under the wallet lock.
Answers `{user, picture, charged, spent}`; `charged:false` means it was already owned. Free → 400
`picture_free`, too poor → 409 `picture_chips`. A **`currency: DIAMOND`** row is paid from `users.diamond` instead, and a **`currency: HAMMER`** row from `users.hammer` —
debited in the same transaction under the same wallet lock, with **no ledger row** (`chip_ledger` backs
the chips invariant and nothing else; a hammer picture writes no `hammer_spends` row either) — and a shortage of either is the same 409 `picture_chips` code
carrying that currency's message ("You need 30 hammers to unlock this picture."). **Buying does not wear it** — that is a separate
avatar POST. **At a table** a DIAMOND or HAMMER picture sells (`Pictures.BuyAtTable`, `Picture.PaidInChips()`); a COIN one → 409 `seated`
"You can only buy a chip-priced picture in the lobby.";
`POST /api/profile/name {name}` (409 `seated` while at a table; these live in
`playerRoutes({isSeated})`, **not** `authRoutes`);
**`DELETE /api/account`** (restored 20 Sep 2026, removed 10 Sep) — the player erases their own
account, which Google Play requires of any app that creates one; this game creates one on first
launch, so it applies to everybody. **409 `seated`** first ("Leave the table before deleting your
account"): a seated wallet is only banked at the three checkpoints (§5.1), so emptying it mid-hand
would settle that hand against a balance that has stopped existing. Otherwise 200 `{deleted:true}`.
**Since 24 Sep 2026 the deletion runs INSIDE `Deps.WhileUnseated`** (`RoomManager.WhileUnseated`, the seat-lock stripe, §5.1)
rather than after an unlocked `isSeated` look, which a quickJoin or switch could beat — seating a deleted account with the chips
`account_deleted` had just removed, the winner then paid chips that no longer existed — and it answers 409 `seated` too while the
player is departing or owed a refused settle. `lockWallet` also skips a deleted row (`deleted_at = 0`), so no checkpoint ever lands
on one, and the player's sockets are ended (`Deps.AccountDeleted` → `socket.Handler.EndSession`); a request that still reaches the
socket layer for a deleted account is `unknown_user` and ends the session (it was `internal_error` + an ERROR line).
`db.Users.DeleteAccount` **pseudonymises** — the row stays (the `users_no_delete` trigger and the
ledger's CASCADE both forbid removing it), emptied of display name, email, `avatar_url`,
`active_picture_id` and the provider identity, with `deleted_at` stamped; clearing the identity is
what frees `(provider, provider_user_id)` so the same device signs in afterwards as somebody new.
The wallet is emptied through an `account_deleted` ledger row (action_id `delete:<userId>`), never
`chips = 0`, or `SUM(delta) == chips` would break for every deleted account for ever. The JWT keeps
its signature but names nothing, since `selectUser` filters deleted rows → `unknown_user`. The
client rotates the **device id** as well as dropping the token (`GameState.deleteAccount`), or a
guest would sign straight back into the id just freed. Public page: `/account-deletion/` (served in
production because `ROOT_REDIRECT` hides only top-level files, §7.4), linked from `privacy/`. **The URLs of record** (owner,
24 Sep 2026 — the Play Console's and the app's) are the studio site's **`https://sungamestudio.com/privacy/`** and
**`https://sungamestudio.com/account-deletion/`**, which serve `go-server/public/privacy/` and `account-deletion/` byte for
byte; `prod.sungamestudio.com` answers 404 for both;
`GET /api/rooms` (no client; **signed-in only, and no `code`/`pot` per table since 24 Sep 2026** — it handed anyone every live
table's join code and pot; `app.RoomListing`; paged since 27 Sep 2026, `{tables, total, nextCursor, options}`, below);
**Pagination** (owner, 27 Sep 2026: "All apis should be pagination and default page size is 20" — "make sure that reported user
should be fetched using pagination, and same with friend list, as user scroll, then it will fetch more pagination";
`auth/pagination.go`). Every route that lists what grows with a player — `GET /api/friends`, `GET /api/friends/requests`, `GET
/api/reports/mine`, and `GET /api/rooms` — answers one page: `?limit=N` (**20 when absent**, `auth.DefaultPageSize`; at most 100,
`MaxPageSize`, a larger one read as 100; at least 1) and `?cursor=C` (the previous page's `nextCursor`, opaque base64url), and the
body carries `total` (all of them) and `nextCursor` (null on the last page). A limit that is not a whole number ≥ 1, or a
cursor the route did not write, is **400 `invalid_page`** "That page does not exist." Two kinds of cursor: an OFFSET into an
order the server makes itself (`OffsetCursor` — the friends, sorted by presence from the live store, which no query can page,
so the whole list is read, sorted and cut, `PageBounds`; the live tables) and a KEYSET `(created_at, id)` for a newest-first
table (`db.Keyset`, `(created_at, id) < (at, id)`, one row over the limit to know if another page follows — the requests and the
reports: a row added at the top while the player scrolls neither repeats one nor hides one). The requests' first answer is
both boxes' first pages with `incomingTotal`/`outgoingTotal`/`nextIncoming`/`nextOutgoing`; the next page of a box is
`?box=incoming|outgoing&cursor=…` → `{requests, total, nextCursor}` (a cursor with no box, or an unknown box, is
`invalid_page`). The catalogues — `/api/profiles`, `/api/emojis`, `/api/table-pictures`, `/api/levels` (since 28 Sep 2026 with
the one-time `missions` beside `xpSources`, §6.6), `/api/tables` — are fixed sets the app needs whole and stay one answer. An installed app from before reads only the first page of each (20).
`internal/auth/pagination_test.go`, `internal/db/friends_test.go` (`TestPendingRequestsComeAPageAtATimeNewestFirst`),
`internal/db/reports_test.go`, `internal/app/pagination_test.go` (25 requests, friends and reports, 20 then 5, every refusal);
**`GET /api/tables`** (Go only, 23 Sep 2026; `app/tableconfig.go` `tablesHandler`) — **the table catalogue this
process enforces**, served from memory (`RoomManager.TableConfig()`, never a fresh database read, which could show a
client an edit the process does not play by until its next start). **Public**: no token, since the app fetches it
before sign-in and it holds nothing a lobby card does not. `Cache-Control: no-cache`, `ETag: "<version>"`, and a
request whose `If-None-Match` names that version (weak compare, `*` too) is answered **304** with no body. Body
(`game.TableConfigPayload`, every slice non-nil): `version` (hex sha256 of the payload marshalled with `version:""`,
so it changes exactly when anything a client reads changes — `session:ready.config.tableConfigVersion` is the same
string), `source` (`db` | `env`), the table-wide scalars and lists exactly as `session:ready.config` has them
(`maxPlayers, minPlayers, bootAmount, turnTimeoutMs, maxBetRounds, sideshowTimeoutMs, sideshowMinPlayers, categories,
stakes, entryCap*, privateBoot, privateMaxPot` — one parser reads either), then **`tables`** — `session:ready.config.tables`
entry for entry (same order, keys and values, poker facts included) plus `key` (`"seen:200"`), **`engine`**
(`teen_patti` | `poker`, always present), `isPrivate`, `sortOrder`, `maxRaiseSteps`, `maxBetRounds`,
`potLimitMultiplier`, `turnTimeoutMs`, `maxMissedTurns`, `sideshowTimeoutMs`, `sideshowMinPlayers`, `nextHandDelayMs`,
`unfundedGraceMs`, `missileRevealExtraMs`, `variationSelectTimeoutMs`, `fiveCardPickTimeoutMs` — then
**`privateTables`** (one per category with an active private template, same shape, `key:"private:<category>"`, band 0)
and **`engines`**: `[{code, name, sortOrder, categories:[{code, name, sortOrder}]}]`, every active engine with its
active categories (env mode: the defaults, Teen Patti {seen, blind, variation} then Poker {the four}). The names are
the database's admin labels — the app names the engines and categories it knows in its own five languages and shows
`name` only for a code it has never heard of. Nothing session-scoped (no `welcomeChips`, no `minClientBuild`): a phone
caches the body across sessions and players (§8.1). No per-table `maxPlayers`/`minPlayers` — the server has one of each;
**`GET /api/table-pictures`** / **`POST /api/table-pictures/use {pictureId|null}`** / **`POST /api/table-pictures/buy {pictureId}`**
(owner, 15 Sep 2026; merged 23 Sep 2026; `auth/handlers.go` `TablePictures`/`UseTablePicture`/`BuyTablePicture`, `db/tablepictures.go`) —
the picture a player lays on their TABLE, the profile-picture trio again for the cloth: the catalogue from `table_pictures`
(`{tablePictures:[{id, name, dayUrl, nightUrl, assetFormat, currency, type, cost, durationDays, durationHours, sortOrder, owned,
expiresAt}]}`, token optional as for `/api/profiles`); laying one (`pictureId` a number or its text, null/absent takes it off; 400
`unknown_table_picture` / `picture_retired`, 403 `picture_locked`; **allowed while seated** — `Deps.TablePictureLaid` →
`RoomManager.SetPlayerTablePicture` → `Table.SetTablePicture` puts it on the seat and emits state); and buying one — one
`table_picture_purchase` ledger row (action_id `table:<userId>:<pictureId>:<n>`, `n` = that pair's `purchases`, so a lapsed rental
can be bought again) plus a `user_table_pictures` row under the wallet lock, `{user, picture, charged, spent}`, DIAMOND/HAMMER from
their `users` column with no ledger row, a COIN row 409 `seated` at a table ("You can only buy a chip-priced table picture in the
lobby."). The account carries the laid pair as **`user.tablePicture {id, dayUrl, nightUrl, assetFormat, currency, cost}`** (null when
none; `LEFT JOIN user_table_choice`/`table_pictures` in `userFromAt`, **joined only while the rental still runs** — since the
23 Sep 2026 review: the account is what every seat is built from (`User.Player` → `LoadPlayer`), so a lapsed rental reads as none the
instant it lapses, sweep or no sweep). The sweeps: login and `me` run both (`takeOffLapsedPicture`), `GET /api/profiles` the worn
picture's only, `GET /api/table-pictures` the laid one's only — and a table sweep that finds the rental over also **tells the seat**
(`tablePictureLapsed` → `Deps.TablePictureLaid(user, nil)`), so a seated player's lapsed cloth leaves every viewer's felt at once
rather than when they next leave. `DELETE /api/account` takes the laid picture off with the rest (`user_table_choice` has no `users`
CASCADE to fire, since `users` rows are never deleted). **A Teen Patti table shows ONE picture to everyone**: `Table.tablePicture()`
picks among the seats' — DIAMOND over HAMMER over COIN, then the dearer, the lowest seat on a tie (`game/tablepicture.go`
`outranks`) — and `room:state.tablePicture {…, userId}` (null when nobody has laid one) is the same for every viewer; the seat's
copy is in the snapshot (`SnapshotSeat.tablePicture`), so a restart keeps it. **Poker rooms show none**: the feature predates §6.5
and the poker felt has the board where the picture would go, so a poker snapshot has no `tablePicture` key, `SetPlayerTablePicture`
does nothing at a poker room, and the choice waits on the account for the next Teen Patti table — the app says so
(`tablePokerNote`, the Tables shelf's blurb at a poker room and the notice after laying there).
**`POST /api/purchases/google {productId, purchaseToken}`** — verifies the token with Google and banks
the pack through a `purchase` ledger row (action_id `gplay:<token>`), so a replay credits once. The same endpoint sells
**diamond packs** (owner, 13 Sep 2026): `diamonds_1_49`, `diamonds_5_199`, `diamonds_20_699`, `diamonds_100_2999`
(`purchase.Catalogue`, `Product.Diamonds`) → `db.CreditDiamondPurchase` adds to `users.diamond` with **no ledger row**,
guarded by `diamond_purchases` (PK = the purchase token, `ON CONFLICT DO NOTHING`), and the answer carries `diamonds`
beside `chips` (one of them 0). All four product ids must exist as managed products in the Play Console. **There
is no Apple counterpart**, which is why the Flutter chip store does not start on iOS (§8.4);
**`POST /api/store/missiles {packId, requestId}`** (owner, 14 Sep 2026) — trades diamonds for missiles in
packs: `missiles_1` (15 diamonds for 1 — 10 until the owner raised it later on 14 Sep 2026), `missiles_5` (73 for 5), `missiles_10` (140 for 10), `missiles_20` (220 for 20), in one transaction under the
wallet lock (`db.Missiles.TradeMissiles`), replay-guarded by `missile_purchases` (`request_id` = `<userId>:<requestId>`).
Answers `{user, charged, diamonds, missiles}` — `charged:false` with 0 and 0 on a replay; 400 `unknown_pack` /
`invalid_request_id` (a non-string `requestId` is `invalid_request_id`, each field read on its own — 24 Sep 2026; it spoiled the
whole decode and read as `unknown_pack`), 409 `not_enough_diamonds`. Allowed while seated: diamonds and missiles sit outside §5.1;
**Emojis** (owner, 26 Sep 2026: "add a feature of buying emoji which will be type of LOTTIE animation, which user can
buy, just like we have added the feature of profile picture … this emoji can buy from store also … when user click that
emoji then that emoji message will send to all players just like chat messages"; `db/emojis.go`, `auth/handlers.go`
`Emojis`/`BuyEmoji`) — the profile-picture model for something SENT rather than worn. **`GET /api/emojis`** (token
optional, as `/api/profiles`): `{emojis:[{id, name, url, assetFormat, currency, type, cost, durationDays, durationHours,
sortOrder, owned, expiresAt}]}`, active rows in `sort_order`. **`POST /api/emojis/buy {emojiId}`** (signed in, the wallet
rate limiter): `{user, emoji, charged, spent}` — COIN through a `chip_ledger` row, reason **`emoji_purchase`**, action_id
`emoji:<userId>:<emojiId>:<n>`, LOBBY-ONLY (409 `seated` "You can only buy a chip-priced emoji in the lobby."); DIAMOND
and HAMMER from their `users` column with no ledger row, at a table too; owned-and-running → `charged:false`; a lapsed
rental renewed. Refusals 400 `unknown_emoji` / `emoji_retired` / `emoji_free`, 409 `emoji_unaffordable` (the wallet
and the price in the message). Sending is the socket's `chat:emoji` (§7.1).
**`GET /api/lucky-draw[?code=]`** / **`POST /api/lucky-draw/spin {actionId, code?}`** (owner, 24 Sep 2026; `auth/handlers.go`
`LuckyDraw`/`SpinLuckyDraw`, `db/luckydraw.go`; the tables in §7.3) — the Lucky Draw, a six-slot wheel the SERVER spins. The GET
(signed in; allowed at a table, it only reads) answers `{draw:{code, name, spinnerType, cooldownMs}, slots:[{slotNumber, rewardType,
rewardValue, rewardRefId, picture?|tablePicture?}], nextSpinAt}` for the first active draw in `sort_order` (today the owner's
`BEGINNER_LUCKY_DRAW`) or the one `code` names — a picture prize carries its catalogue row with `owned` for this player, `nextSpinAt` is
0 when a spin is due, and **the weights never leave the server**; no draw, a retired one or one with no slot that can be won → 503
`lucky_draw_unavailable`. The spin reads nothing but its key and the draw's code (a `slotNumber` or prize in the body is ignored):
under `Deps.WhileUnseated` (409 `seated` at a table — a CHIPS prize moves the wallet, §5.1) and the wallet lock it checks the cooldown
from the player's last row in `user_lucky_draws` (409 `lucky_draw_not_ready` with `readyAt`), draws one active slot with
`crypto/rand` over the weights laid end to end, grants the prize and records the spin in ONE transaction, and answers `{actionId,
slotNumber, reward:{type, value, refId, picture?|tablePicture?}, alreadyOwned, replayed, nextSpinAt, user}`. An `actionId` (1–64,
else 400 `invalid_action_id`) that has already spun answers that spin again, `replayed:true`, granting nothing; it rides the wallet
limiter (§7.4);
**`GET /api/reward-programs`** / **`POST /api/reward-programs/claim`** (owner's brief, 30 Sep 2026; `auth/rewardprograms.go`,
`db/rewardprograms.go`; the tables and the algorithm in §7.3, the app in §8.1/§8.4) — the reward programs: the login streaks and the
calendar rewards. The GET (signed in; allowed at a table, it only reads) answers `{programs:[{program:{id, code, name, mode, periodType,
timezone, weekStartDay, resetOnMissedDay, startsAt, endsAt, periodStart, periodEnd}, today ("2006-01-02" in the program's zone),
dayOfPeriod, periodDays, currentDay, claimedToday, claimedDays, rewards:[{day, rewardType, rewardValue, rewardRefId, claimed,
picture?|tablePicture?|emoji?|badge?}]}]}` — every active program in `sort_order` as it stands for THIS player (`currentDay` is the day
today's claim counts, or counted, as; `claimedDays` a streak's current run, a calendar's days claimed this period; an item reward carries
its catalogue row with `owned`, a badge `{code, title, icon, validityDays, assetUrl?, assetFormat?, held, expiresAt}`); 503
`reward_programs_unavailable` from a server with no store. The POST claims TODAY of every program — **the body is ignored: nothing a
client sends decides a reward** — under `Deps.WhileUnseated` (409 `seated` "Collect your rewards from the lobby, not while you are at a
table." — a CHIPS reward is a lobby-only credit, §5.1) and the wallet limiter, one transaction a program, and answers
`{granted:[{programCode, programName, mode, periodType, day, rewardType, rewardValue, rewardRefId, picture?|…, alreadyOwned, claimedAt}],
programs, user}` — `granted` is what THIS call gave, empty once today is claimed (every later call of the day), so a client celebrates
exactly that and never twice; idempotent by construction (the action_id is `reward:<userId>:<programCode>:<claimDate>`), so no client
key. **The login does not claim, and nor does the app by itself**: the lobby reads the programs as it appears and puts the weekly
login popup up while today's is still to collect (§8.1/§8.4); the claim is the player's tap — which is also what keeps a seated
player's chips out of it;
**A disabled account** (owner, 26 Sep 2026: "Add a flag is_active in users table by default keep its value true and
when it is marked false, it means user is disabled … he cannot join the table also"): `users.is_active` (§7.3), switched
off by hand — `UPDATE users SET is_active = FALSE WHERE id = …` — and back on the same way, with nothing else about the
account touched (wallet, ledger, pictures). Read with every account read (`db.User.Disabled`, `json:"-"`: never on the
wire, and negated so a `User` built anywhere but from a row — a test's fake store — is enabled). Every door answers
**`account_disabled`** "Your account is disabled. Please contact support." (`auth.AccountDisabledError`, 403): the
LOGIN (refused inside `UpsertFromProfile` before the row is touched — `db.ErrAccountDisabled`, so `last_login_at` does
not move; logged `login refused`), `RequireAuth` (`GET /api/auth/me` — a cold start's restored session — and every
signed-in request), the socket HANDSHAKE (`connect_error account_disabled`, so no seat is resumed), and every way into a
seat — the socket layer's `freshUser` (quickJoin, joinCode, create, switch) and the RoomManager's `LoadPlayer` under the
seat lock — after which the guard ends the session as it does a deleted account's. A seat already taken plays on while
its socket lasts; once that drops, the reconnect is refused and the seat lapses after the grace.
`internal/app/accountdisabled_test.go`; the app's popup is §8.1.
**One signed-in device** (owner, 28 Sep 2026, §7.1): `db.Users.UpsertFromProfile` — every login, any provider, new account
or not — counts a new session in its transaction (`startSession`: `user_sessions.version + 1`, 1 for the first, under the login's
row lock, so two logins at once number themselves one after the other); the account read carries it (`db.User.SessionVersion`,
`json:"-"`, never on the wire) and `Tokens.Issue` signs it as the JWT's `sv` (left out at 0). `auth.SessionCurrent(claims, user)`
is the one comparison: `RequireAuth` answers **401 `session_replaced`** "Your account has been signed in on another device." for
any other figure (after the disabled check), and the handshake the same code. A token from before sessions were counted carries no
`sv` (0), as does an account with no row, so every session alive at the deploy stays good until that account's next login. The
catalogues' optional-token routes (`/api/profiles`, `/api/table-pictures`, `/api/emojis`) only read `owned` for the token's
subject and do not check it. The last device to sign in is the one that plays; signing in again on the first takes the account
back the same way. `internal/app/singlesession_test.go` (a Google account mid-hand: the first socket told and ended before the
second connects, its token refused at `me`, a wallet door and the handshake, the new socket handed the same room and hand and
the seat kept past the grace; a token without `sv` good until the next login; three sign-ins in a row; a late hand-over never
ends the latest session's socket).
**The app version gate** (owner's brief, 28 Sep 2026: "the backend controls the minimum supported app version … The backend must
ALSO enforce the minimum version for important API/WebSocket access so an old client cannot bypass the Flutter UI";
`internal/appversion`, `db/appversions.go`, `app/appversion.go`). Four states — **NORMAL**, **SOFT_UPDATE** (supported, a newer
version announced), **FORCE_UPDATE** (below the platform's minimum), **MAINTENANCE** (the platform's row says closed) — decided by ONE
rule, `appversion.Evaluate`, from the `app_versions` rows (§7.3) and what the client DECLARES: headers **`X-App-Platform`** and
**`X-App-Version`** on REST, `appPlatform`/`appVersion` in the handshake's auth (§7.1). One semver comparison (`appversion.Parse`:
MAJOR.MINOR.PATCH as numbers, a `+build` suffix ignored, anything else invalid — 1.10.0 > 1.9.0). The rule, in order: `bot`, `tool`,
`web` → NORMAL always (never version-gated, never held by maintenance: bot-play, tools/bot.js, the ramp test, the parity harness and
the scratch scripts, the browser client all declare one); the row the client is judged by (its own for `android`/`ios`, android's for
anything undeclared — every install that predates the gate is an Android build) in MAINTENANCE → MAINTENANCE (it outranks an update);
undeclared → FORCE_UPDATE only when `APP_VERSION_REQUIRED` is on, else NORMAL; an app build with a minimum set (above 0.0.0) → FORCE_UPDATE
below it, **and with no version or a malformed one** (a real build always sends its own); else SOFT_UPDATE below `latest_version`, else
NORMAL. **`GET /api/app-config`** — public, no token, **never gated**, `Cache-Control: no-store` — answers the caller's state from its
headers (or `?platform=&version=` for an operator's curl; a header wins): `{status, platform, version (as parsed, or null), minimumVersion,
latestVersion, storeUrl, message, android: {status, minimumVersion, latestVersion, storeUrl, message}, ios: {…}}` ("0.0.0" = none;
nothing internal — the versions, store links and messages are what the listings say anyway). **Every signed-in REST route** refuses
(`auth.Handler.AdmitApp`, the first thing `RequireAuth` does — before the token, so the check never depends on who the player is):
**426** `{error: "update_required", message, storeUrl?, minimumVersion?}` and **503** `{error: "maintenance", message}` — the
`{error, message}` shape with two `omitempty` fields added to `ErrorResponse`; `message` is the row's, else the server's
("A new version of King Teen Patti is required to continue playing." / "King Teen Patti is temporarily unavailable. Please try again
later."). **Never gated**: the login (so an old app can learn it must update), `/api/app-config`, `/health`, `/metrics`, static files and
the public catalogues (`/api/tables`, `/api/profiles`, `/api/table-pictures`, `/api/emojis`, `/api/levels`). The rows are read through
a cache of `APP_VERSION_CACHE_MS` (15 s; `appversion.Source` — one read per TTL however busy, a failed read keeps the last good one, and
before the first read the gate is open, which a boot's own read makes moot). Counted and logged (§7.5): `APP_VERSION_CHECK` /
`SOFT_UPDATE_DETECTED` per check, `FORCE_UPDATE_REJECTED` / `MAINTENANCE_REJECTED` per REST refusal and `WEBSOCKET_VERSION_REJECTED` per
handshake refusal, each with platform, appVersion, minimumVersion, latestVersion and the route pattern — once a minute per kind, and
never a user id. **The legacy floor**: installs that predate the gate read only `session:ready.config.minClientBuild`, so a connection
is sent `max(MIN_CLIENT_BUILD, LegacyMinClientBuild(row.minimum_version))` — the first build number at least that version among the
releases that predate the gate (1.0.0+1 … 1.5.0+13, a closed list in `appversion`), 14 for any minimum above 1.5.0, 0 with no floor — so
one UPDATE of `minimum_version` holds the old installs too, with the switch off. A declaring build (1.6.0+14 or later) is never below
it. `internal/appversion/*_test.go` (the semver cases, the rule's every branch, the legacy floor, the cache, the counters and logs),
`internal/app/appversion_test.go` (the brief's backend tests on the real wiring: each platform's state, REST 426/503 on every signed-in
door and none on the public ones, the handshake's refusals and their data, per-connection `minClientBuild`, a live socket kept through
an UPDATE, the switch, the §15 change without a restart), `appversion_reconnect_test.go` (the real socket.io-client: one knock and no
reconnect after `update_required`, a network drop still retried), `db/appversions_test.go` (the seed, the CHECKs, the trigger, an older
database brought forward). Operator steps: `go-server/ops/DEPLOY.md` "The app version gate".
**Friends V1** (owner's brief, 26 Sep 2026: "Friends System V1 … FRIENDS MUST BE A LOBBY FEATURE … Friends can see
whether another friend is online and, if they are currently playing, which game/table TYPE and variant they are playing …
This live information MUST come from Redis, NEVER PostgreSQL"; `auth/friends.go`, `db/friends.go`, `game/playing.go`).
**Ownership**: `users` = identity, account, wallet; **`player_stats`** = gameplay statistics (§7.3); **`friend_requests`**
/ **`friendships`** = the graph (§7.3); Redis = presence; Go decides everything, Flutter renders. The **Player ID** is
`users.id` (trimmed and lower-cased before the primary-key lookup). Every answer is a dedicated DTO (`PlayerCard` =
`{userId, displayName, profilePicture:{id, url}}`, the url resolved as the user object's `avatarUrl`) — never a `db.User`,
never chips/diamond/hammer/missile/wallet/purchases/email/provider, never a room or table id or a Redis key (the app tests
scan every body for them). Routes, all signed in; the four writes through the `wallet(…)` limiter; allowed while seated
(they move no wallet): **`GET /api/players/{playerId}`** → `{player, friendStatus: NONE|PENDING_SENT|PENDING_RECEIVED|
FRIENDS|SELF, requestId?}` (`requestId` only with PENDING_*); **`GET /api/players/{playerId}/profile`** → `{profile:
{…PlayerCard, friendStatus, requestId?, presence? {status: ONLINE|PLAYING|OFFLINE, online, playing, game?, variant?},
stats {handsPlayed, handsWon, handsLost, handsLeft, winRate, categories {teenPatti, variation, poker}}}}` (the per-game
record since Player stats v2 — counts, the hands held and the variations played, never a chip figure) — `presence` ONLY for
FRIENDS or SELF; `winRate` =
round(100·won/played, 2), 0 with no hands; no total winnings or biggest pot (chip figures); **`GET /api/friends`** →
`{friends: [PlayerCard + {status, online, playing, game?, variant?, friendsSince}], total, nextCursor}` — one page (Pagination,
above), PLAYING then ONLINE then OFFLINE, then name; **`GET /api/friends/requests`** → `{incoming, outgoing}` of `{requestId,
player, createdAt}` (a page of each, with their totals and next cursors), PENDING only, newest first; **`POST /api/friends/requests {userId}`** → 201 `{requestId, friendStatus: PENDING_SENT}`; **`POST
/api/friends/requests/{requestId}/accept`** → `{friend}` and **`/reject`** → `{requestId, status: REJECTED}`; **`DELETE
/api/friends/{friendUserId}`** → `{removed: true}`. Refusals: 400 `invalid_player_id`, 404 `player_not_found` (unknown,
deleted or disabled), 400 `self_request`, 409 `already_friends`, 409 `request_already_sent`, 409 `request_already_received`
(+ their `requestId`), 404 `request_not_found` (also a request not addressed to the caller), 409 `request_not_pending`, 404
`not_friends`. **Race-safe**: one PENDING per unordered pair is the partial unique index's job, and a send that loses the
race (23505) is re-read into the right refusal; send, accept and account deletion lock the two `users` rows `FOR KEY SHARE`
in id order and then the request, one order everywhere, so they cannot deadlock. Accept is ONE transaction (the request
`FOR UPDATE`, recipient and PENDING checked, ACCEPTED, A→B and B→A `ON CONFLICT DO NOTHING`); remove is one transaction
deleting both rows. Deleted and disabled accounts are left out of the friend list and both request lists (a list entry
must never lead to a profile that answers 404). `DELETE /api/account` also cancels the player's PENDING requests and
deletes their friendships, in its transaction. **Presence** reuses the existing `kt:online` (set on connect, refreshed by
the 30 s heartbeat, lapses after 90 s, cleared when the account's live socket closes) and adds ONE record per seated player,
**`kt:playing:<userId>`** = `{"game":"TEEN_PATTI|POKER","variant":"<CATEGORY upper-cased>","updatedAt":<ms>}` — never a
room id — written in the same MULTI as the seat mirror (`live.Store.SetSeated(ctx, user, room, playing, ttl)`: every join,
a switch or consolidation move's target, the restore), refreshed by `ReconcileLive`'s every-pass seat rewrite (so it never
lapses under a seated player), deleted with the seat (`ClearSeated`: leave, kick, grace lapse, a move's source, destroy,
`sweepStrays`). Its TTL is `game.PlayingTTLFor(LIVE_RECONCILE_MS)` — three reconcile intervals, at least 90 s — and none at
all with the reconciler off. Read in one pipelined round trip per 500 ids (`live.Store.Presence`: `HMGET kt:online` +
`MGET kt:playing:…`, metrics op `presence`); status is PLAYING when the record exists (online then true: a player inside
the 60 s reconnect grace stays "Playing now" rather than flickering offline), else ONLINE, else OFFLINE; a failing live store
answers every friend OFFLINE with one WARN. The metrics middleware labels the new routes by PATTERN (`/api/players/{playerId}`
…), never by id. V1 had no socket events and the app polled (§8.4); **Friends at the table** (owner, 26 Sep 2026: "in a
gametable, if a player clicks other player pod then a drawer from right side will open, where he can send friend request and
player by clicking his pod can accept the friend request") added two PUSHES and nothing else server-side — the routes were
already allowed while seated: once a request (201) or an accept (200) has committed and its answer is written, the handler
calls `Deps.FriendRequestSent(recipientID, item)` / `Deps.FriendRequestAccepted(senderID, FriendAccepted)`, which `app.go`
wires to `socket.Handler.NotifyFriendRequest`/`NotifyFriendAccepted` → `friend:request` / `friend:accepted` on that
account's live socket (§7.1; nil-safe hooks, auth never imports socket). `db.Friends.Send` returns the request as its
recipient lists it and `Accept` both sides of the new friendship (`db.AcceptedRequest`), read back in their transactions.
Tests: `internal/db/{friends,player_stats}_test.go`,
`internal/auth/friends_test.go`, `internal/app/friends_test.go` (the eight routes end to end, presence over real sockets
for every variant, the grace, a restart, a failing store), `internal/game/roommanager_playing_test.go`, the live conformance
suite on all three stores; the pushes in `internal/{auth,app}/friendpush_test.go` and `internal/socket/friends_test.go` (both
events over real sockets, nothing on reject/remove/refusal or to an account with no socket, two players seated mid-hand
befriending each other with no `seated` refusal, no wallet word, room id or code in a push).
**Report Player** (owner's brief, 27 Sep 2026: "A player sitting at a gameplay table must be able to report another player
currently at the same table … Go server is authoritative"; `auth/reports.go`, `db/reports.go`, `game/report.go`). THREE routes,
**`POST /api/reports {reportedUserId, reason, description?}`** → **201 `{"success":true,"message":"Report submitted
successfully.","limit":{…}}`** and nothing more (no report id, status, table or hand), and **`GET /api/reports/limit`** →
`{limit:{max, used, remaining, windowMs, availableAt, waitMs}}` — the caller's OWN standing against the limit (owner, 27 Sep
2026: "if user has reported 2 player, then reporting by him should be disabled in UI, and show a cool down time in UI when can
he report again"; `db.Reports.Quota`, the same count `Submit` makes — `reportQuota`, shared — with `availableAt` the moment
enough counted reports leave the window, the server's clock, and `waitMs` how long that is from the answer, so a phone with a
wrong clock still counts to the server's moment; both 0 while a report is open; signed in, not counted against the attempt
limiter). The same `limit` rides on the 201 (absent if the read failed — the report is filed anyway) and on the 429
`report_limit_reached` (`db.ReportLimitReached.Quota`). And **`GET /api/reports/mine`** (owner, 27 Sep 2026: "see all the
players he reported in detail status, description, time he reported but don't show the reported user id, by default it will
sorted in latest reported user") → `{reports:[{player:{displayName, profilePicture:{id, url}, gone}, reason, description, game,
category, variant, status, createdAt, updatedAt}]}` — the caller's own reports, newest first (`created_at DESC, id DESC`, off
the reporter index), a page at a time (`total`, `nextCursor` — Pagination, above; keyset); `db.Reports.Filed` resolves the name and picture as Friends
does and blanks both for an account deleted since (`gone`); NO user id, report id, table or hand
(`TestTheReporterListsTheirOwnReportsAndNoIDOfAnybody`); signed in, a read of the caller's rows alone. REST, as Friends at the table is: a persistent
account action made from the table's player drawer, allowed while seated, and never through the table's actor — **a report
changes nothing in the game** (no pause, kick, fold or ban; `TestAReportFromTheTableIsFiledWithTheTableAndTheHandAndChangesNothing`).
Signed in (`RequireAuth`), the `wallet(…)` per-IP limiter, and a per-ACCOUNT attempt limiter (`REPORT_ATTEMPT_*`, every
request counted, refused or not). The body is read field by field and ONLY those three: `reporterUserId`, `tableId`, `handId`,
`game`, `status`, `createdAt` … sent by a client are ignored. Reasons, matched exactly: `CHEATING, HARASSMENT, ABUSIVE_LANGUAGE,
SPAM, INAPPROPRIATE_BEHAVIOR, SUSPICIOUS_GAMEPLAY, COLLUSION, EXPLOITING_BUG, OTHER` (`auth.ReportReasons`; OTHER needs a
description). The description: CR LF → LF, other control and format characters → space, trimmed, at most
`REPORT_DESCRIPTION_MAX` (500) CODE POINTS (the app counts the same way). Refusals in order: 401/403 (auth), 429 `rate_limited`,
400 `invalid_json`, 400 `invalid_player_id`, 400 `self_report`, 400 `invalid_report_reason`, 400 `description_required`, 400
`description_too_long`, 409 `player_not_at_table` (checked BEFORE existence, so a guessed id reveals nothing), 404
`player_not_found` (deleted since), 409 `already_reported`, 429 `report_limit_reached` (+ `Retry-After`), 500 `internal_error`.
**Where the two met is the server's** (`Deps.ReportContext` → `RoomManager.ReportContext`): both indexed at the same room now
(`playerRooms`) → a posted read of the room, `Room.ReportContexts` (Teen Patti and poker alike): the room id, `game`
(`teen_patti|poker`), category, variant (a Variation hand's chosen variation, the poker variant, else none) and hand — the one
the REPORTED player is in, else the last one they were dealt into there (`Table.lastHand`, memory only, set in `setHand(nil)`),
else none. Otherwise a **recent-departure memory** (`coPlayers`, own mutex, never held with `mu` or while a table is called):
when a player leaves a room — leave, kick, lapsed grace, switch, consolidation move (`vacateFrom`, `movePlayer`) or the room
closing on them (`destroyTable`, unless fenced) — the manager asks the room once where everybody stood and remembers each pair
both ways for `REPORT_RECENT_MS` (10 min; ≤ 64 table-mates a player, swept lazily). **A restart forgets the departures** (a
restored room still answers for everyone seated at it): a player who left before it is no longer reportable — accepted and
tested (`TestAfterARestartSeatedPlayersStayReportableAndOnesWhoLeftBeforeDoNot`, `TestTheLimitAndTheTableSurviveARestartTheDeparturesDoNot`).
The abuse guards live in PostgreSQL (`db.Reports.Submit`, one transaction under `pg_advisory_xact_lock(hashtext('king-teenpatti:
player_report'), hashtext(reporter))` — per reporter, not a users row lock, so it never meets a wallet lock): one report per
reporter → player per hand (and the partial UNIQUE index under it), one per pair per `REPORT_PAIR_WINDOW_MS` (24 h), and
**`REPORT_MAX_PER_REPORTER` (2) per rolling `REPORT_WINDOW_MS` (24 h), counted from the reporter's own rows** (owner: "a player
may submit at most 2 reports in any 24 hours") — so no restart, reconnect or second process resets it, and two reports racing
for the last slot file exactly one (`TestConcurrentReportsWithOneSlotLeftFileExactlyOne`, proven to fail without the lock
through the `SetReportCounted` seam); the retry moment counts a lowered limit right (the report whose leaving brings the count
under it, not always the oldest; `TestTheQuotaSaysWhatSubmitWillDecideAndWhenTheNextReportOpens`). No moderation route exists
(every other method on `/api/reports` is the JSON 404): the data model is ready for one (§7.3), none is built. Tests: `internal/{db,auth,app,game,config}/report*_test.go`.
`GET /health` (since 23 Sep 2026 it ends with `tableConfig: {source, version, fallback}` — where the tables came
from; `fallback:true` is a `TABLE_CONFIG_SOURCE=db` boot that could not use the database's catalogue and runs the env
composition, the one state an operator must go and fix). Errors `{error: code, message}`. Guest id = `sha256('teenpatti:'+deviceId)`, deviceId
≥ 8 chars. `AUTH_ALLOW_FAKE_PROVIDERS=true` lets google skip verification (tests, browser
stubs; it did facebook too until Facebook was switched off). **A refused login is logged** (`login refused` WARN: provider, code, status, reason with the
credential cut out — `handlers.go logRefusedLogin`, since 10 Sep 2026); other AuthErrors are written
to the client only, so `journalctl -u gameplay | grep 'login refused'` is where a "Google sign-in
doesn't work" report starts.

### 7.3 Database (`db/` → `internal/db/`)
`pg` Pool (`DATABASE_URL`, `PG_POOL_MAX`), `search_path` set as a connection **option**
(`-c search_path=<schema>,public`). `openDatabase({url, schema})` creates the schema if missing and applies
**`internal/db/migration/*.sql`** in version order. They are named the Flyway way
(`V<version>__<description>.sql`) and split DDL from DML. **There is no schema history table**: the server
applies EVERY script on EVERY boot, so each one must be idempotent (IF NOT EXISTS / CREATE OR REPLACE / ON CONFLICT DO
NOTHING / a catalogue lookup before an unguarded trigger or column). A script that is not idempotent does not
fail the first time — it fails on the next restart, in production.

**Two founding scripts** (owner, 23 Sep 2026: "merge all DDL and DML into 2 files"; DML-only seeds may follow them
since 28 Sep 2026, below) —
**`V1.0.0__baseline.sql`**, ALL the structure (every table, column, check, index, function and trigger), and
**`V1.0.1__seed.sql`**, the rows: the 45 pictures, then the table catalogue (engines, categories, `table_settings`,
`table_configs`). The seed was `V1.0.1__seed_profile_pictures.sql` until then; nothing records a script's name, so the
rename changed nothing for any database. `TestMigrationsAreVersionedOrderedAndSplitByKind` (`db_test.go`) pins the pair:
those two first, no CREATE/ALTER/INDEX in the seed, and in the baseline an `ALTER TABLE` only as an `EXECUTE` string inside a
catalogue-guarded block (exactly nine: `users.is_bot`, `users.is_active` (26 Sep 2026, written straight into the baseline the same way), `chip_ledger.game`, `chip_ledger.variant`, since 28 Sep 2026 the one-time missions' `xp_sources.mission_type`, `.target` and `.scope`, and since 29 Sep 2026 the levels' art, `player_levels.asset_url` and `.asset_format`, §6.6). How it got here: the 14 Sep 2026 consolidation (owner, for a
production deploy onto an EMPTY database) folded V1.0.2–V1.0.5 in and dropped the blocks that brought older databases
forward (git history, `ccff445`); later that day `duration_hours`, `V1.0.2__timed_bonus_milestone.sql`,
`V1.0.3__seed_new_pictures.sql`, the 9-diamond default and the HAMMER currency were folded in too, so a database built
before them cannot take this build without the hand steps in the baseline's header or a fresh start (DEPLOY.md §8) —
the TIMED_BONUS CHECK reaches only a `user_milestones` table built afresh (production's, from go-server/v1.1.0, refuses
every four-hour bonus claim until the hand ALTER). Then the first two scripts written AFTER production ran the pair:
**`V1.0.2__chip_ledger_game.sql`** (19 Sep 2026, the Poker family, §6.5 — in tags go-server/v1.1.1 and v1.1.2) and
**`V1.0.3__users_is_bot.sql`** (22 Sep 2026, never tagged). On 23 Sep 2026 both were **folded into the baseline**, with
the four table-configuration tables, and each of those columns is now written TWICE: in its `CREATE TABLE`, so a fresh
database is built with it, and — moved verbatim — in the **catalogue-guarded `DO` block** right after that
`CREATE TABLE` (`information_schema.columns` lookup, then `EXECUTE 'ALTER TABLE … ADD COLUMN …'` only where the column is
missing). Those blocks are what an OLDER database needs at its next boot, and they are kept for production: a database
last booted by go-server/v1.1.2 (production's) has `game`/`variant` and lacks `is_bot`, so this build's first boot there runs one
`ALTER TABLE users ADD COLUMN is_bot …` — which needs the app role to own `users` (DEPLOY.md §7: run it once as
`postgres` first where §7 is applied). `TestABootBringsAnOlderDatabaseForward` (`upgrade_boot_test.go`) takes that path:
the columns and the configuration tables dropped, one boot, and a login and a poker-tagged checkpoint work. **Never
`ADD COLUMN IF NOT EXISTS`**: it takes ACCESS EXCLUSIVE on the table even when the column exists, and every restart would
queue behind any reader (`TestABootSurvivesALongReaderHoldingTheTables` is the guard, now holding the four
configuration tables too; the 9 Sep crash loop is the reason).

**The next change goes INTO `V1.0.0`, never into a new file** (the baseline's header, 23 Sep 2026): the seed runs
right after the baseline and BEFORE anything numbered later, so a seed row that needed a column a `V1.0.2` added would
fail every boot — fresh databases included — before `V1.0.2` had run. **DDL the seed depends on lives in V1.0.0**, which
runs first; keeping all of it there is what "two files" means. **Later scripts may hold ROWS only** (owner, 28 Sep 2026:
"Create new file V1.0.2__seed.sql and ADD a insert idempotent profile_pictures"): after the pair come seed scripts named
`V<version>__seed….sql`, **`V1.0.2__seed-festive-capybara.sql`** the first (Festive Capybara, below; `V1.0.2__seed.sql` for its
first hour, renamed by the owner: "change seed file name seed-festive-capybara") — they run after both founding scripts,
so they depend on the baseline and nothing depends on them. `TestMigrationsAreVersionedOrderedAndSplitByKind` holds each to
it: named a seed, no CREATE/ALTER/DROP/TRUNCATE/DELETE/UPDATE, and one `ON CONFLICT` per `INSERT` (an INSERT … DO UPDATE is
refused too: a seed never rewrites a row an owner has edited). Structure still goes into V1.0.0, however late. A new table is one `CREATE TABLE IF NOT EXISTS`; a new
column is written twice, as `is_bot` and `game`/`variant` are. What a boot does NOT do is change what an existing
column already IS — a CHECK, a default, a type: `CREATE TABLE IF NOT EXISTS` is a no-op where the table exists, and
that stays **a deliberate one-off step run by hand**, or a fresh start. **Every index is created inside a catalogue
guard** (a `to_regclass` lookup in a `DO` block) since 29 Sep 2026: a bare `CREATE INDEX IF NOT EXISTS` takes a SHARE lock
on its table even when the index exists, so every boot — and `gameplay -migrate` beside a live server — briefly blocked the
writes to 12 tables (the ledger, the purchase tables); `TestABootThatChangesNothingWaitsForNoWriter` holds a boot that
changes nothing to taking no such lock, and `TestMigrationsAreVersionedOrderedAndSplitByKind` every `CREATE INDEX` to a guard.
A release that ADDS an index or column still takes its lock once (up to the 3 s `lock_timeout`): deploy it at a quiet hour.
The other catalogue guards (the baseline's
`idx_users_last_login`, `users_no_delete` created only when missing) are for DEPLOY.md §7, where the app role no longer
owns `users`.
`withTransaction(fn)` = BEGIN/COMMIT/ROLLBACK. `dropSchema()` refuses `public`. **int8 and numeric
are parsed to JS numbers** (`pg.types.setTypeParser(20|1700)`) — without that, `chips` and `SUM()`
come back as strings.

Tables — **there are exactly forty-three, and none of them is game state** (the reward programs' three since 30 Sep 2026 — `reward_programs`, `reward_program_rewards`, `user_reward_claims` — in their own paragraph after the welcome) (`welcome_rewards` since 30 Sep 2026, what a new account is granted, in its own paragraph after the app versions) (`app_versions` since 28 Sep 2026, the app version gate's configuration, in its own paragraph just before the ledger reasons) (`player_xp_missions` since 28 Sep 2026, each player's one-time XP missions, §6.6) (`user_sessions` since 28 Sep 2026, the sign-in each token must carry, in its own paragraph after the player reports) (Report Player's `player_reports` since 27 Sep 2026, moderation audit, in its own paragraph after the friends graph) (Player stats v2's `player_variation_stats` and
`stats_flushes` since 27 Sep 2026, in the statistics paragraph below) (the emojis' two since 26 Sep 2026, below the Lucky Draw's paragraph; `player_stats`, `friend_requests` and `friendships` since the same day, Friends V1, §7.2; and eight of levels, badges and the daily XP since 27 Sep 2026 — `player_levels`, `badges`, `user_badges`, `badge_purchases`, `xp_sources`, `xp_settings`, `player_xp`, `player_xp_claims`, §6.6): ten of accounts, money and the picture
catalogue, three of the table pictures (`table_pictures`, `user_table_pictures`, `user_table_choice` — the paragraph after the
`users` trigger below; merged 23 Sep 2026) (`user_milestones`, `diamond_purchases`, `hammer_purchases`, `hammer_spends`, `missile_purchases` and
`missile_spends` are below), and since 23 Sep 2026 **four of table configuration** — `table_engines`,
`table_categories`, `table_settings`, `table_configs` (the last paragraph of this list), and since 24 Sep 2026 **three of the Lucky
Draw** — `lucky_draws`, `lucky_draw_slots`, `user_lucky_draws` (the paragraph before the ledger reasons). `users` (wallet = `chips BIGINT
CHECK ≥ 0`, **`diamond INTEGER NOT NULL DEFAULT 9 CHECK ≥ 0`** — the premium currency, nine per new account (owner, 14 Sep 2026; two, and one before that, earlier the same day), never
ledgered —, **`hammer INTEGER NOT NULL DEFAULT 20 CHECK ≥ 0`** — what a Force Sideshow costs, 20 per account, never ledgered —, **`missile INTEGER NOT NULL DEFAULT 1 CHECK ≥ 0`** — what a missile costs, one per new account, never ledgered —,
counters, `active_picture_id`, `deleted_at`, and since 22 Sep 2026 **`is_bot BOOLEAN NOT NULL DEFAULT FALSE`** (in the baseline's `CREATE TABLE users` and its guarded block since 23 Sep 2026) — true for every bot the project runs (owner, 27 Sep 2026: "any bot who plays that should be marked is_bot true"; the `bot-play/` fleet alone until then), set at login from the guest DEVICE ID's namespace (`config.BotDevicePrefixes`, env `BOT_DEVICE_PREFIX`, a comma-separated list, default `botplay-,practice-bot-,ramp-bot-`: the Go fleet's `botplay-<6 digits>` (and the Node fleet's before it, `botplay-v1-<n>`, `botplay-v1-<n>-g<gen>` when rotated), `tools/bot.js`'s practice bots `practice-bot-<slot>-<name>` and the ramp test's `ramp-bot-<n>-device-id`; each entry trimmed, an empty one dropped). A **label, never a permission**: nothing in the game reads it, it is absent from every wire struct (`TestMarkingABotDoesNotLeakToTheClient` — a seat that announced itself as a bot would tell a player exactly what the fleet exists not to tell them), and the login **ORs** rather than assigns so a mark is never cleared. Empty prefix marks nobody, never everybody), and since 26 Sep 2026 **`is_active BOOLEAN NOT NULL DEFAULT TRUE`** (column and guarded block, as `is_bot`; §7.2 "A disabled account"),
**`user_milestones`** (**retired 30 Sep 2026** with the three rewards, §7.2: nothing reads or writes it, and it stays in the
baseline so a rollback to go-server/v1.12.0 on a database this build made still finds it; owner, 14 Sep 2026: the rewards each player had collected, moved off `users`, where they were `milestone_claimed` and `next_bonus_at` — `user_id`, `milestone` HANDS_PLAYED|TIMED_BONUS|DAILY_BONUS (TIMED_BONUS in the baseline's CHECK since `V1.0.2__timed_bonus_milestone.sql` was folded into it; production's table, built by go-server/v1.1.0, keeps the two-value CHECK — and refuses every four-hour bonus claim — until a fresh start or the hand ALTER in the baseline's header), PK on the pair, `claimed_up_to`, `next_claim_at`, `times_claimed`, `last_claimed_at`; one row per player per milestone, inserted on the first claim and updated in place after (`db.collectMilestone`), read through two LEFT JOINs in `userFrom`, so no row reads as nothing collected and both bonuses ready),
**`chip_ledger`** (`action_id UNIQUE`, `hand_id`, `delta`, `balance`, `reason`, and since 19 Sep 2026 `game`/`variant` — `'poker'` + the poker category on a poker row, NULL on every Teen Patti row, §6.5; append-only trigger),
and the picture catalogue added 12 Sep 2026 (owner): **`profile_pictures`** (`name`, `asset_url`
UNIQUE, `asset_format` IMAGE|SVG|LOTTIE|RIVE, `currency` COIN|DIAMOND|HAMMER, `type` FREE|PREMIUM, `cost` with a CHECK that free is 0 and premium is > 0, `is_active`,
`sort_order`) and **`user_profile_pictures`** (`user_id`, `profile_picture_id`, PK on the pair) —
who has bought what. A FREE picture needs **no** ownership row: everyone may wear it, so the table
holds only what somebody paid for. `V1.0.1__seed.sql` (THE PICTURES) seeds 15 hosted animals (2 free, 13 coin-priced rentals), four LOTTIE rentals priced in chips (owner, 14 Sep 2026; sold in the lobby only, like every chip-priced picture) — Love Sheep 10 Lakh for 1 hour, Love Birds 30 Lakh for 3 hours, Error 404 1 Crore for 10 days, Anima Bot 1 Crore for 5 days — and
21 more LOTTIE rentals, 16 priced in HAMMERS (Love and Kiss, added the same day, 25 hammers for 10 days — its seed row was 2 until the owner changed it in place after production had run the seed, so only a database built from scratch has 25 and production keeps 2 (owner's choice, 14 Sep 2026)) and 5 in DIAMONDS (owner, 14 Sep 2026: a hammer picture costs ten times the figure in brackets below, which was its diamond price until then, and is rented for as many days as it costs — Swirling Dots 30 hammers for 50 days; Butterfly Flapping, Waving Tiger Cub, Indian Flag, Jolly King and Jolly Queen are priced in diamonds instead, at 4, 3, 5, 5 and 5, for 100 days. The seed now runs free → chip-priced → hammer-priced → diamond-priced with sort_order 10–400 in that order, so the sort_orders in brackets below are the old ones; the seed's header table is the current list) — Orange Ballerina (1, sort_order 160), Butterfly Flapping (4, 170; its first Drive upload beats its wings with 3D orientation the phone players ignore — §12.3 — so the row points at a second Drive upload of the flattened copy; go-server/v1.3.0 served that copy itself as `/profiles/butterfly-flapping.json`, and a rollback to that tag seeds the path again as a second row — DEPLOY.md §5), Toucan Flying (a landscape 1920×1080 canvas, 3, 180), Live Chatbot (1, 190), Paper Plane (1, 200), Bouncing Dots (1, 210), Monarch Butterfly (4, 220), Lovestruck Cat (5, 230), Waving Tiger Cub (5, 240; a tiny `loopOut()` detail in its head holds still on phones, which run no expressions), Galloping Horse (1, 250; a black silhouette flipbook, about 1.2:1 against the dark theme's picture circles), Gamer Raccoon (6, 260), Cool Cat (10, 270), Indian Flag (10, 280; it sits high and left in its canvas, so the round picture loses most of its pole), Jolly King (10, 290), Jolly Queen (10, 300; both move only through `loopOut()` expressions, so both are served from Drive as copies baked by `tools/lottie/bake_loop_expressions.py`, not as their original uploads), Shooting Game (8, 310; a video turned into a 28-frame flipbook of embedded WebP images with no transparency, so its round picture is a white disc), Spider (8, 320; a landscape 3840×2160 canvas whose centre square is the whole spider; its dark legs fade on the dark theme), Swirling Dots (3, 330; uploaded as "Dots Loader"), Sporty Avocado (9, 340; black line art that all but disappears on the dark theme; its 12 "Kleaner" overshoot expressions do not run on phones, which looked the same) and Blazing Fire (1, 350; the animated Noto Emoji 🔥, CC BY 4.0) — inserted with `ON CONFLICT (asset_url) DO NOTHING`, so re-pricing or retiring one is an UPDATE
the next boot will not undo; on an empty database they number 1 (Bear) to 40 (Jolly Queen). The last five, and then Love Sheep, Love Birds, Error 404, Anima Bot and Love and Kiss, were added to the consolidated seed on 14 Sep 2026, before production had run it. Production has now run it (go-server/v1.1.0), and the next five were appended to the seed too (owner, 14 Sep 2026; they came as `V1.0.3__seed_new_pictures.sql` and were folded back in) — a row appended there reaches every database at its next boot, a changed row only a fresh database — **Bodybuilder** (50 Crore chips for 50 days, sort_order 195, uploaded as "Bodybuilder lifting heavy barbell"), **Butterfly** (100 Crore chips for 100 days, 197, the dearest picture; not Butterfly Flapping or Monarch Butterfly), **Dog Dancing** (30 hammers for 30 days, 352), **Dance** (20 hammers for 10 days, 354) and **Cockroach** (10 hammers for 15 days, 356; first priced at 80 Crore chips), none with 3D layers, expressions or embedded images — rows 41 to 45 on an empty database. Then **Festive Capybara** (owner, 28 Sep 2026: "Hammer 1 PREMIUM LOTTIE", "validity 3 day"; **1 hammer for 3 days**, sort_order 358 — after Cockroach, before the first diamond picture), the first row of **`V1.0.2__seed-festive-capybara.sql`** rather than of the seed (above) — row 46 on an empty database: "Festive Capybara.json" as uploaded, 350×350, 3.2 s, Lottie 5.12.1, 228 KB, no 3D, text or embedded images, and five "Kleaner" expressions whose overshoot the phones skip, as Sporty Avocado's (§12.3), so the original is served. The catalogue test (`TestTheSeededCatalogueHoldsEveryPictureAtTheOwnersPrices`) derives its counts from its price maps and `added`, so a later picture is a line in each. **`diamond_purchases`** (`purchase_token` PK, `user_id`, `product_id`, `diamonds`, `created_at`) is the replay guard and record for Play diamond packs — diamonds never enter `chip_ledger`; **`hammer_purchases`** is its twin for Play hammer packs, and **`hammer_spends`** (`action_id` PK — `<handId>:force:<userId>:<client actionId>` —, `user_id`, `hand_id`, `created_at`) is the one row per spend a Force Sideshow's hammer is charged against. **`missile_purchases`** (`request_id` PK, `user_id`, `diamonds`, `missiles`, `created_at`) and **`missile_spends`** (`action_id` PK, `user_id`, `hand_id`, `created_at`) are the same pair for missiles: a diamonds-for-missiles trade and a missile fired. `users.avatar_choice` (the old free-text `/profiles/x.svg` path) was
migrated into `active_picture_id` and dropped on 12 Sep 2026; the block that did it (and the guarded drops of the
retired `game_states`, `pots` and `hands`, removed 9 Sep 2026 — `d949179` is the crash loop a direct reference to one
caused) left the files when the schema was declared from scratch that evening (`79266b2`), so today's baseline neither
creates nor drops any of them: a database still carrying one was restored from an old backup, and dropping it is a
human's call. `avatar_url` **stays** — it is the Google (or Facebook, while that was on) photo, a different thing from a chosen picture, and what "use my social
picture" falls back to.

**The table configuration** (owner, 23 Sep 2026: "all table related config store in database"; `V1.0.0`'s TABLE
CONFIGURATION section). CONFIGURATION, not state: a row says what KIND of table the lobby offers, the way
`profile_pictures` says what a picture costs; a table in play copies every figure into its own config when it opens,
keeps it in its Redis snapshot and never looks here again. All four are app-role owned and reference nothing of `users`,
so DEPLOY.md §7 changes nothing for them; durations are in milliseconds, like the env keys they replace; timestamps
epoch-ms with a DEFAULT; no index beyond the keys each declares (each is read whole, once per boot).
- **`table_engines`** (`code` PK — `teen_patti` | `poker`, `config.EngineTeenPatti`/`EnginePoker` —, `name` an admin
  label, `sort_order`, `is_active`) and **`table_categories`** (`code` PK — the seven categories —, **`engine REFERENCES
  table_engines (code)`**, `name`, `sort_order`, `is_active`): the taxonomy of §6 ("Teen Patti engines / Poker engines",
  the owner, the same day).
- **`table_settings`** — ONE row (`id SMALLINT PK CHECK (id = 1)`): the figures that belong to no single table —
  `default_boot_amount` (BOOT_AMOUNT), `stakes BIGINT[]` (TABLE_STAKES verbatim; empty = any stake; **a table's own
  boot is always allowed** — `TableCatalogue.Validate` appends, after the listed stakes and in menu order, the boot of
  every active public row the array lacks, silently, so a new table is ONE row: in db mode the menu is what restricts
  the pairs, `AssertTableOffered`, and `AssertStakeAllowed`, which runs first, would otherwise refuse every join at a
  card the lobby shows), `max_players`
  (2..5) and `min_players` — here and on no table row, because every installed client lays its seats out from the ONE
  `maxPlayers` session:ready advertises —, the ADVERTISED `turn_timeout_ms` (≥ 5000), `max_bet_rounds`,
  `sideshow_timeout_ms` (0 or ≥ 1000), `sideshow_min_players`, and requirement 30's `entry_cap_boot`,
  `entry_cap_category REFERENCES table_categories (code)`, `entry_cap_max_chips` (0 disables).
- **`table_configs`** — one row per PUBLIC lobby table (the menu, in `sort_order`) and one PRIVATE template per category
  (what `room:create` opens; a category with no active template folds a private create to seen), **every figure fully
  resolved on its own row** — no inheritance, no NULL meaning "the default". `category REFERENCES table_categories
  (code)`; `boot_amount` (the boot; the big blind at Hold'em/Omaha, the ante at 3-Card Poker/5-Card Draw);
  `is_private`; **`table_key` GENERATED ALWAYS AS `'category:boot'` or `'private:category'` STORED UNIQUE** — the
  identity quick-join, switch, consolidation, the live lobby, resume offers and the metrics all key a public table on,
  declared in the CREATE TABLE so a boot that changes nothing takes no SHARE lock and makes no ownership check;
  `min_chips`/`max_chips` (the stack band, public only); Teen Patti's `max_pot`, `max_raise_steps`, `max_bet_rounds`,
  `pot_limit_multiplier`, `max_blind_moves` (0 = no limit for each, the blind rule); `turn_timeout_ms` (≥ 5000),
  `max_missed_turns`, `sideshow_timeout_ms`, `sideshow_min_players`, `next_hand_delay_ms`, `unfunded_grace_ms`,
  `missile_reveal_extra_ms`; variation's `variation_select_timeout_ms`/`five_card_pick_timeout_ms` (a CHECK makes both
  > 0 on a variation row: a 0 window never lapses); poker's `min_buy_in` (in CHIPS; a CHECK makes it ≥ the boot on a
  poker row) and `max_discards` (0..5); `sort_order`; `is_active`. **The rule and timer columns have NO DEFAULT**: a row
  typed by hand that forgets one fails there and then instead of playing by a number nobody chose. A figure a category
  does not read (a poker row's ladder, a seen row's buy-in) is stored as written and zeroed by the server on load.
- **Foreign keys, not enumerated CHECKs**, so the set stays OPEN: a future engine or category is a seed row, never a
  change to a constraint an existing database already has (the trap `profile_pictures_currency_check` sprang when
  HAMMER arrived). The keys refuse a row naming a category nobody declared; what they cannot say is whether THIS build
  can play it, so `config.TableCatalogue.Validate` leaves out — with an ERROR `table config row left out` each, and the
  boot carries on — an engine it does not run, a category it does not know or one filed under the wrong engine (seen
  under poker), every table under a category that did not survive, and a row PostgreSQL accepted but the engine must not
  open (a band min over max, a poker buy-in under the boot, a per-bet ceiling that overflows). Only a catalogue that
  cannot run a lobby — no (or an invalid) settings row, no public table, no private **seen** template, or a read that
  fails — is refused, and then the server
  runs the env composition instead (`/health.tableConfig.fallback: true`), because refusing to boot over a hand edit
  would turn an unrelated restart into a crash loop.
- **`is_active` works at every level**: `db.TableConfigs.Load` reads a table only when its row, its category AND its
  engine are active (one read-only REPEATABLE READ transaction, tables schema-qualified), so one `UPDATE` retires one
  table, a whole category (every Variation table) or a whole engine (all of Poker) — silently, because what is switched
  off on purpose is not a problem to report. **`seen` and `teen_patti` cannot be switched off**: the private template
  room:create opens is seen's, and losing it makes the catalogue unusable — the boot falls back to the env
  composition rather than hiding anything. (To keep seen out of the LOBBY, retire its public rows.) Retire with
  `is_active = FALSE`, never DELETE (a DELETE of an engine or category is refused while anything names it, and the seed
  puts a seeded row back).
- **The seed policy** (`V1.0.1__seed.sql`, THE TABLES): engines and categories `ON CONFLICT (code) DO NOTHING`, ACTIVE
  wherever the code is missing (a category puts nothing in front of a player by itself); the settings row `ON CONFLICT
  (id) DO NOTHING`; the 12 public tables of the default menu (sort_order 10–120) and 7 private templates (1010–1070, boot
  200) `ON CONFLICT (table_key) DO NOTHING` with **`is_active` = whether the catalogue was EMPTY** (asked separately for
  public and private rows). So a fresh database gets everything active; **a table appended to the seed in a later
  release reaches an existing database INACTIVE** — it goes live when the owner sets `is_active = TRUE`, after raising
  `MIN_CLIENT_BUILD` to a build that can draw it (the way variation and poker were rolled out), never because a server
  restarted; a row already there is never touched, so an owner's `UPDATE` survives every restart; a seed row changed
  in place reaches only a fresh database (the picture rule); a seeded row DELETEd or re-keyed comes back inactive. The
  VALUES were generated from `config.Defaults().Game.EffectiveCatalogue()` and **`TestTheSeededTableCatalogueIsTheDefaults`**
  loads them back out of a fresh schema and compares them figure by figure — a server switched to db on this seed plays
  exactly as one on the defaults did, and a default changed in `config` without the seed fails that test naming the
  table. The seed is the CODE's default menu: a deployment whose `.env` configures its own gets its own into the
  database with `gameplay -export-table-config` (§4, DEPLOY.md §3).

**Gameplay statistics live in `player_stats`**, per game since **Player stats v2** (27 Sep 2026, owner: "maintain stats
acc to only three category: teenpatti variation and poker … how many times he got trail, pair, highcard, pure sequence,
sequence also. how many muflis, ak47, other gameplay type he played … store this info in redis, then async you can update by
group commit so that u don't call postgres db multiple times"). **`player_stats`**: one row per player per BUCKET — PK
`(user_id, category)`, `category` TEEN_PATTI (seen and blind, public or private), VARIATION or POKER (`game.StatsBucket`, no
CHECK: an open set) — with the six outcome counters (`hands_played` = made a voluntary bet, `hands_won`, `hands_lost`,
`hands_left` = abandoned mid-hand, `total_winnings` = GROSS chips taken in pots won — a taxed win counts the whole pot, the
`table_tax` row nothing — and `biggest_pot`) and the hand each player HELD at a Teen Patti or Variation hand end (`trail`,
`pure_sequence`, `sequence`, `color`, `pair`, `high_card`, as the table counted it: wild cards make the category, under
5-Card the three that played; all 0 on a POKER row). **`player_variation_stats`**: per player per variation (MUFLIS … FIVE_CARD,
open set), `hands_played`/`hands_won`. **`stats_flushes`**: the flusher's receipts, one row per batch committed — what makes a
batch count once. **The path** (`internal/stats`, `internal/live/stats.go`/`redis_stats.go`, `db/stats.go`): the ledger writes
MONEY ONLY (and the settle's XP); a table works out each hand's `game.HandStats` while the cards and rules are still there,
carries them on `SettleRequest.Stats`, and hands them to its `StatsRecorder` only once the write has COMMITTED — on the first
attempt or the Settler's retry, never on `duplicate_action` — so a hand counts at most once and only when its money moved (a
leaver is counted at the leave's committed checkpoint). `stats.Recorder` queues them off the actor into the live store
(`kt:stats:<userId>`, one round trip a hand); `stats.Flusher`, every `STATS_FLUSH_MS` (10 s), moves up to `STATS_FLUSH_BATCH`
(500) players out atomically under a batch id (`TakeStatsBatch`), adds them in ONE PostgreSQL transaction with its receipt,
and only then finishes the batch in the live store — a crash in between replays the batch, which its receipt makes a no-op.
Losing the live store loses the counters not yet flushed (at most one interval), as it loses the hands in play. So the figures
TRAIL play by up to one interval: every account read sums a player's rows (`statsColumns`, two correlated subqueries; the wire
`user` keeps the six career totals with their old keys and adds **`stats {teenPatti, variation, poker}`** per game), the
HANDS_PLAYED milestone reads the sum, and the app re-reads the account when the Stats drawer opens and once more
`GameState.statsCatchUpAfter` (11 s) after leaving a table. `DELETE /api/account` deletes the rows; pending counters are dropped
from the live store, best effort, and a flush that still finds some adds nothing to a deleted account. **`users` has no stat
column** (owner, 26 Sep 2026: "only store in player_stats table"). **A database go-server/v1.6.0 built** holds `player_stats` as
one row per player: the baseline REFUSES to boot on it, naming the fix (a fresh database, DEPLOY.md §5/§8 —
`TestABootOnTheV160PlayerStatsIsRefusedNamingTheFix`), and a rollback from v2 to v1.6.0 needs a fresh database too, since
v1.6.0 writes its counters with `ON CONFLICT (user_id)`. A rollback to go-server/v1.5.0 or older, which reads the old `users`
columns, needs one as well. **The
friends graph**: **`friend_requests`** (`id` BIGSERIAL, `requester_id`/`recipient_id` → `users` CASCADE, `status`
PENDING|ACCEPTED|REJECTED|CANCELLED, timestamps, `CHECK requester <> recipient`; `UNIQUE INDEX … (LEAST(requester_id,
recipient_id), GREATEST(…)) WHERE status = 'PENDING'` — no duplicate and no A→B beside B→A — plus the two partial indexes
the incoming and outgoing lists read) and **`friendships`** (`id`, `user_id`/`friend_user_id` → `users` CASCADE,
`created_at`, `UNIQUE (user_id, friend_user_id)`, `CHECK` not self; two rows per friendship). All three are plain CREATE
TABLE / INDEX IF NOT EXISTS in `V1.0.0` (nothing alters `users`), so an existing database gains them at its next boot, and
under DEPLOY.md §7 they need only its REFERENCES and UPDATE grants (`handover_boot_test.go` re-creates them). No presence of
any kind is stored in PostgreSQL.

**Player reports** (owner, 27 Sep 2026; §7.2 "Report Player"): **`player_reports`** — `id` BIGSERIAL, `reporter_user_id` /
`reported_user_id` → `users` CASCADE (users are never deleted; an account deletion keeps its reports, as it keeps its ledger),
`reason` TEXT (an OPEN set the server checks — no CHECK, so a new reason is code, the Lucky Draw's `reward_type` rule),
`description` TEXT (NULL for none), `game`, `category`, `variant` (NULL for none), `table_id` (the room id) and `hand_id` (NULL
when none is known) — REFERENCES by value to the authoritative data, never a copy of the hand —, `status` PENDING | UNDER_REVIEW
| ACTION_TAKEN | DISMISSED (a CLOSED set, a CHECK, as `friend_requests.status`; moderation's to set, never a player's),
`created_at`/`updated_at` (epoch ms, server-stamped), `CHECK` not self. Indexes: `(reported_user_id, created_at)`,
`(reporter_user_id, created_at)` (also what the per-reporter limit counts), `(status, created_at)`, and **UNIQUE
`player_reports_one_per_hand (hand_id, reporter_user_id, reported_user_id) WHERE hand_id IS NOT NULL`** — the hand lookup and
the one-report-per-hand guarantee in one. A plain CREATE TABLE / INDEX IF NOT EXISTS after `friendships` (nothing alters
`users`; `handover_boot_test.go` re-creates it under §7), nothing in the seed. **`PurgeLedger` keeps every `chip_ledger` row of
a hand a report names** (`NOT EXISTS … player_reports.hand_id`): the hand's rows are the one authoritative record of it
PostgreSQL holds, so a moderator can still read the hand after `LEDGER_PURGE_AFTER_MS`; a report filed after its hand's rows
were purged names a hand with no rows. A moderation system to come adds its own table naming `player_reports (id)` for the
actions it records; a player's history filed and received is the two player indexes.

**Sessions** (owner, 28 Sep 2026; §7.1/§7.2 "One signed-in device"): **`user_sessions`** — `user_id` PK → `users` CASCADE,
`version` BIGINT ≥ 0 (how many times the account has signed in since the table existed), `updated_at`. A side table, as
`user_table_choice` is, so no `ALTER TABLE users` and no DEPLOY.md §7 one-off: a plain CREATE TABLE IF NOT EXISTS after
`user_milestones`, nothing in the seed, joined into every account read (`userFromAt`, `COALESCE(us.version, 0)`), written by
every login (`startSession`). An existing database gains it at its next boot, empty: every account reads 0, which is what every
token issued before it carries (`handover_boot_test.go` re-creates it under §7).

Timestamps are epoch-ms BIGINT. Rewards (removed 30 Sep 2026, §7.2): milestone 25,000 / 25 hands (`didChaal` only), timed bonus 10,000 / 4h, and beside it the Go-only daily bonus 1,00,000 chips + 1 hammer / 24h (owner, 14 Sep 2026) — they were constants in `db/users.go`, never configurable. Display names: `NAME_PATTERN = /^[\p{L}\p{N}][\p{L}\p{N}\p{M} ]*$/u` —
**`\p{M}` is essential** for Indic vowel signs.

**`users` rows are never deleted** (owner's decision, 10 Sep 2026): trigger `users_no_delete`
(`users_immutable_rows()`, `V1.0.0__baseline.sql`, created only when missing) raises on every DELETE from every
caller — the server never issues one. **`DELETE /api/account` pseudonymises instead** (restored
20 Sep 2026 for the Play listing, after being removed on 10 Sep: Play requires apps that create an
account to offer deletion in-app AND at a public URL, and this game creates one on first launch, so
shipping without it risked the review — §7.2). It empties the row rather than removing it, because
`chip_ledger.user_id … ON DELETE CASCADE` would take the money audit with it. Removing a row is a
deliberate privileged step: `sudo -u postgres psql gameplay`, `ALTER TABLE users DISABLE TRIGGER
users_no_delete`, delete, re-enable. Prod's app role `gameplay_app` still **owns** the table and the
function (it runs the migrations), so it could disable the trigger; DEPLOY.md §7 has the one-time
ownership transfer that closes that (owner → `postgres`, `GRANT SELECT, INSERT, UPDATE, REFERENCES` back — REFERENCES because a table a boot creates with a foreign key to users, such as `diamond_purchases`, needs it; and every migration statement that would need to OWN users, like the baseline's `idx_users_last_login`, is catalogue-guarded so it skips work already done, proven by `TestTheAppRoleBootsTwiceBeforeAndAfterUsersIsHandedToTheSuperuser` — tags up to go-server/v1.3.0 predate that guard and cannot boot once §7 is applied), which
needs sudo on the host and is why the function is create-if-missing rather than CREATE OR REPLACE.
Test: `TestUserRowsAreNeverDeleted` (`internal/db/users_delete_test.go`).

**The table pictures (owner, 15 Sep 2026; merged into master from the `table-pictures` branch on 23 Sep 2026)** are three
more tables — **seventeen in all then, twenty since the Lucky Draw's three (24 Sep 2026)** — declared in `V1.0.0__baseline.sql` (TABLE PICTURES, right after `user_profile_pictures`)
and seeded in `V1.0.1__seed.sql` (THE TABLE PICTURES, between the profile pictures and the table catalogue). On the branch they were
a pair of their own, `V1.0.2__table_pictures.sql` and `V1.0.3__seed_table_pictures.sql`, written while a script that had run
somewhere was never edited; the merge folded them into the two files under the rule above (`TestMigrationsAreVersionedOrderedAndSplitByKind`
pins where). Deliberately nothing but `CREATE TABLE IF NOT EXISTS` (and one index): no ALTER and nothing on `users`, so a database
built before them takes them at its next boot as `gameplay_app`, whether or not DEPLOY.md §7 has handed `users` to the superuser (a
table with a foreign key to `users` needs only the REFERENCES grant §7 gives; `handover_boot_test.go` re-creates them under §7).
Three tables:
**`table_pictures`** (`profile_pictures` with `asset_url` split into `day_asset_url` UNIQUE — the seed's conflict key — and
`night_asset_url`; same `asset_format`/`currency`/`type`/`cost`/`duration_days`/`duration_hours`/`is_active`/`sort_order` and CHECKs),
**`user_table_pictures`** (who bought which, `expires_at`, `purchases` — the twin of `user_profile_pictures`) and
**`user_table_choice`** (`user_id` PK → `table_picture_id`: the picture each player has LAID, one row or none; this is
`users.active_picture_id` for the table, kept as a side table because a `users` column would be an `ALTER TABLE users` and a §7
one-off on every deploy that carries it; `ON DELETE CASCADE` on the picture, so deleting a catalogue row clears the tables it was on).
The seed holds **five rows, the owner's own art** (owner, 15 Sep 2026: "apply this only"; the fifth 24 Sep 2026), all LOTTIE, all hosted in the owner's Drive
`table_pictures` folder (`uc?export=download&id=…`, never the `/file/d/…/view` page), all rented for chips — so sold in the lobby only
(§5.1). The first two have a night file made here, where a Drive upload travels through a tool call and size is the constraint; Welcome
reads on both grounds and is its own night file; Thank You has a day file made here that the owner uploaded (729 KB). **Lines
Background** — 1 lakh chips / 7 days, sort_order 75 (seeded at 10 hammers / 30 days and re-priced by the owner on 16 Sep 2026; a database
that ran the seed in between keeps the hammer price until the UPDATE in the seed's header): 23 layers of black lines on a transparent
1500×1500 canvas, no 3D and no expressions; its **night file** ("Lines Background Night.json") has the lines in white — 22 strokes
recoloured, editor metadata dropped, each layer's 120 per-frame trim-offset keyframes re-encoded as the same curve sampled adaptively
within 1° with a hold across the 360→0 wrap — 30 KB against 101. **Background Pattern** — 5 lakh chips / 7 days, sort_order 80 (owner,
16 Sep 2026): 96 rounded tiles in two blues that pop in one after another over four seconds on a transparent 1500×1000 canvas, hold, and
shrink away together (Lottie 5.5.3, 25 fps, 6 s — a screenshot can land in the empty half-second at the loop's end and show a bare felt).
The owner's 122 KB export is kept as `tools/tables/background-pattern.json` and **both** Drive files ("Background Pattern.json",
"Background Pattern Night.json") are made from it by `tools/tables/make_background_pattern.py`, committed beside it: the pop-in written
once per colour as a precomp and each tile an instance of it started at its own frame — `st` shifts a precomp's contents and nothing
else, the convention of every Bodymovin export (Fireworks.json's shifted layers carry their keyframes in composition time) and of both
players — with the shared shrink-out as the instance's own keyframes, the two double-bouncing tiles (55, 64) kept whole, and the path as
the `rc` it is; 31 KB each, checked keyframe for keyframe against the export and byte for byte after upload. Its night file swaps the pale
blue (#E3F2FD, a tint that all but vanishes on the light ground) for a navy (#1B2F42) that sits on the dark ground the same way and keeps
the mid blue. **Welcome** — 1.5 lakh chips / 7 days, sort_order 85 (owner, 16 Sep 2026; 1 lakh for a few hours that day): the word written on in a rainbow gradient stroke
over 7.6 s on a transparent 428×123 banner canvas (Lottie 4.8.0, one layer, no 3D, no expressions), the owner's own upload
("Welcome.json"); a rainbow reads on both grounds, so `night_asset_url` repeats `day_asset_url` (only the day URL is UNIQUE), and its
banner shape is fitted whole on the felt (§8.4 `pictureFitFor`) rather than cropped to two letters. **Thank You** — 30 lakh chips /
7 days, sort_order 90 (owner, 16 Sep 2026): the words in gold (#FCC700) with 35 gold shapes around them on a 1080×1080 canvas (Lottie
5.11.0, 10 s, 728 KB — the heaviest file; its text layer embeds its glyphs as `chars`, so no font is needed), the owner's own upload,
public — the NIGHT file. That gold all but vanishes on the light ground (owner, 16 Sep 2026: "Thank you text not visible in Day mode"),
so the DAY file ("Thank You Day.json") is the same Lottie with its 140 shape fills and its text fill in `AppTheme.goldDeep` #8A6A18,
written by `tools/tables/make_thank_you_day.py`, which checks that nothing else differs; its 7,722 per-frame keyframes cannot be
re-sampled without changing the twinkle, so at 729 KB it is far above what a Drive upload from here carries and the owner uploaded it
("Thank You Day.json", same folder, public; proved on TP_Small in the light theme from a scratch `http.server` first and from Drive
after). **Circle Background Pattern** — 3 lakh chips / 7 days, sort_order 95 (owner, 24 Sep 2026): three circles turning once
every 5 s over a pastel gradient (sky blue → grey-green → peach, spinning inside each circle under a soft white rim) on a
1920×1080 canvas (Lottie 5.5.8, 60 fps, 3.6 KB, no 3D/expressions/text), the owner's upload "Circle Background Pattern .json"
(trailing space and all). Its background rectangle is OPAQUE, so it brings its own ground and one file serves both themes
(`night_asset_url` = `day_asset_url`); a 16:9 canvas is a scene, so the felt crops it to the square — `pictureFitFor` and
`TablePictureGround.bannerAspect` draw the banner line at **2:1** since this row (1.6:1 before), Welcome at 3.5:1 staying the
banner. **Changing a seeded row's day URL changes its conflict key**: Thank You was seeded with the upload as both files first, so the
seed carries a guarded UPDATE that moves such a row onto the day file before the INSERT (a no-op elsewhere) — without it the next
boot of a database that ran the earlier seed would add a second Thank You. **A file uploaded from here is private
until the owner sets "Anyone with the link"** (the connector cannot; a phone gets Google's sign-in page instead of the file until then — and
kept it as the picture until §8.4's `looksLikeHtml` guard, 16 Sep 2026); the owner shared all three Drive night/day files that day. There is no free row and none is needed:
"Flowing chips", the game as it comes, is always on the shelf. Eight SVG designs with a day and a night file each were drawn for this shelf by
`tools/tables/make_table_pictures.py` into `go-server/public/tables/<slug>-{day,night}.svg` (served like `profiles/`, §9) and seeded
that day; the owner took their rows out, keeping the catalogue to their own art — the files and the script remain, unseeded, and a row for
one is the seeded row's shape with the two `/tables/` paths (the DAY file a pale cloth for the light theme's dark ink, the NIGHT file a
deep one for the dark theme's light ink; a picture's art must read on its own ground or the words on the table go with it).

**The emojis (owner, 26 Sep 2026)** are two more tables in `V1.0.0__baseline.sql`: **`emojis`** (`profile_pictures`'
columns — `name`, `asset_url` UNIQUE, `asset_format` LOTTIE only, `currency` COIN|DIAMOND|HAMMER, `type` FREE|PREMIUM
with the free-is-0 CHECK, `cost`, `duration_days`/`duration_hours`, `is_active`, `sort_order`) and **`user_emojis`**
(`user_id`, `emoji_id`, `acquired_at`, `expires_at`, `purchases`; PK on the pair — the twin of `user_profile_pictures`;
a FREE emoji needs no row). `V1.0.1__seed.sql`'s THE EMOJIS holds the owner's NINETEEN, every one a Drive-hosted Lottie at
**5 hammers for 30 days** (checked: no 3D, no expressions, no images), `ON CONFLICT (asset_url) DO NOTHING`: Angry,
Dollar, Crying, Hi Face, Clapping Hands, Cowboy Hat Face, Muscle, Plane Face, Knife, Sleeping, Squinting Face with
Tongue, Crying Face, Enraged Face, Chill Face, Face Blowing a Kiss, Kiss Face, Ok, No Face, Tongue Face (sort_order 10–190, the order they were
given; the names are the Drive titles without "Emoji" — the app never shows a Drive title).
`TestTheSeededEmojisAreTheOwnersNineteenAtFiveHammersForThirtyDays`. Twice a batch of links repeated one link where the owner's upload to the emoji folder held another file; the batch's unlinked files were taken as meant (Chill Face, Face Blowing a Kiss, Kiss Face; Tongue Face).

**The Lucky Draw (owner, 24 Sep 2026)** is three more tables in `V1.0.0__baseline.sql` (LUCKY DRAW, after `missile_spends`) and one
draw in `V1.0.1__seed.sql` (THE LUCKY DRAW, last). **`lucky_draws`** (`code` UNIQUE, `name`, `spinner_type` TEXT default `STANDARD` —
a label for how the client may dress the wheel —, `cooldown_ms` ≥ 0, `is_active`, `sort_order`) and **`lucky_draw_slots`**
(`lucky_draw_id` → `lucky_draws` ON DELETE CASCADE, `slot_number` 1..6 UNIQUE per draw, `reward_type` TEXT, `reward_value` ≥ 0 or NULL,
`reward_ref_id` TEXT, `weight` INTEGER **CHECK > 0**, `is_active`, `sort_order`) are CONFIGURATION, read on every request, so an owner's
`UPDATE` is on the wheel at the next look — no restart. **`reward_type` is TEXT checked by the server, not an ENUM or a CHECK**, so a
future `AVATAR_FRAME`, `CARD_BACK` or `TITLE` is a row and code, never a migration: `db.LuckyDraws` knows `CHIPS`, `DIAMOND`,
`HAMMER`, `MISSILE` (value > 0; the last three ≤ 2³¹−1), `PROFILE_PICTURE`/`TABLE_PICTURE` (`reward_ref_id` = the catalogue row's
id as text, the row active) and `NO_REWARD` (the empty slot: a spin that wins nothing); a slot it cannot grant is left off the wheel
with a WARN (`lucky draw slot left out`) and never drawn, and a draw with none left is `lucky_draw_unavailable`. The default draw is
the first ACTIVE one in `sort_order`, so switching the lobby to another draw is two UPDATEs. **`user_lucky_draws`** is the history,
append-only by use: `user_id` → `users` (CASCADE), `lucky_draw_id`, `slot_id`, a SNAPSHOT of `reward_type`/`reward_value`/
`reward_ref_id` (a later edit of the slot never rewrites what somebody won), **`action_id` UNIQUE** (`lucky:<userId>:<client
actionId>` — the replay guard, as `chip_ledger`'s is), `created_at`; the cooldown is `last created_at + cooldown_ms`, read under the
wallet lock. The spin grants through the existing paths: CHIPS through `chip_ledger` (`appendLedger`, reason **`lucky_draw`**, same
action_id — the §4 invariant holds), DIAMOND/HAMMER/MISSILE as deltas on their `users` columns with no ledger row (as their purchases
are), a picture as the ownership row a purchase writes (`user_profile_pictures`/`user_table_pictures`, the rental term the shop sells
it for, from now; `purchases` untouched) — **never worn or laid** (the player puts it on). A picture already owned and running is left
exactly as it was (`alreadyOwned:true`, the spin still recorded); a lapsed rental is renewed in place. Grant and record are one
transaction, so a prize that cannot be granted leaves no spin and a spin that cannot be recorded takes its prize back out
(`TestASpinIsGrantedAndRecordedTogetherOrNotAtAll`). The seed is the owner's own SQL, verbatim (24 Sep 2026): **BEGINNER_LUCKY_DRAW**
"Beginner Lucky Draw", `spinner_type` BEGINNER, a spin every **three days** (259200000 ms), slots 1 HAMMER 1 (weight 25), 2 HAMMER 4
(15), 3 CHIPS 10,00,000 (20), 4 CHIPS 1,00,000 (20), 5 NO_REWARD (10), 6 CHIPS 5,00,000 (10) — `ON CONFLICT DO NOTHING` on the code and
on (draw, slot), so an owner's UPDATE survives every restart. A picture prize is set by natural key, since BIGSERIAL ids differ between
databases: `UPDATE lucky_draw_slots SET reward_type='PROFILE_PICTURE', reward_value=NULL, reward_ref_id=(SELECT id::text FROM
profile_pictures WHERE name='Lovestruck Cat') WHERE …` (the seed's header has the table-picture twin).

**The app versions (owner, 28 Sep 2026; §7.2 "The app version gate")** are one table, **`app_versions`**, at the END of
`V1.0.0__baseline.sql` (APP VERSIONS) and seeded at the end of `V1.0.1__seed.sql` (THE APP VERSIONS): one row per app platform —
`platform` (PK; an OPEN set, a lower-case word CHECKed for shape, not an enumeration: a platform this build does not know is a row it
never reads), `status` NORMAL | MAINTENANCE, `minimum_version` and `latest_version` (TEXT CHECKed to MAJOR.MINOR.PATCH without leading
zeros, `'0.0.0'` = none — so a typo fails at the UPDATE, never locks players out), `store_url` (≤ 500), `message` (NULL = the app's own
words, ≤ 500), `created_at`/`updated_at` epoch ms — `updated_at` follows every UPDATE through the `app_versions_touch` trigger (function
replaced on every boot, trigger created only when missing). **The seed puts NO floor**: android `NORMAL, 0.0.0, 0.0.0`, the Play listing
(public, fixed by the package), ios the same with no store link — so deploying the gate changes nothing for anybody — `ON CONFLICT
(platform) DO NOTHING`, so an operator's UPDATE survives every restart. CONFIGURATION like the table catalogue, **but read while the
server runs** (the gate's 15 s cache, §7.4), which is the one reason it is a table: env keys are read once at boot and the table
catalogue once at boot, and the owner asked to "change the minimum supported Android/iOS version from the backend and immediately
prevent older clients" with no restart and no app release — the Lucky Draw's precedent (configuration read per request). One table,
not two: per-platform rows carry maintenance too, so `UPDATE app_versions SET status = 'MAINTENANCE'` (no WHERE) is the global switch
and a `WHERE platform = 'ios'` a partial one. It references nothing and nothing references it (so DEPLOY.md §7 changes nothing for it).
`db/appversions_test.go` (the seed holds no floor, an operator's UPDATE read back and every typo refused by a CHECK, the trigger, one boot
bringing a database that lacks the table forward with an UPDATE surviving two more boots).
**The welcome (owner, 30 Sep 2026: "new account will get how much coins, hammers, diamonds, profile_picture, emoji — this data should
come from database, user might get some or all rewards")** is one table, **`welcome_rewards`** (`V1.0.0`, beside the Lucky Draw's model;
`db/welcome.go`): `code` UNIQUE (the seed's conflict key), `reward_type` TEXT (an OPEN set the server checks — `CHIPS`, `DIAMOND`,
`HAMMER`, `MISSILE` with a `reward_value` > 0, and `PROFILE_PICTURE`, `TABLE_PICTURE`, `EMOJI` with `reward_ref_id` = the catalogue row's
id as text), `is_active`, `sort_order`, timestamps with a touch trigger. **Every new account reads the ACTIVE rows inside its login
transaction** (no cache: an owner's UPDATE applies to the very next account, no restart): rows of one wallet add up, the `users` row is
inserted with chips, diamond, hammer and missile set EXPLICITLY to those totals (0 where no row gives any — the column DEFAULTs 9/20/1
no longer decide a new account's wallets), the `welcome_bonus` ledger row as before, and each picture, table picture or emoji as the
ownership row a purchase or a Lucky Draw prize writes (the shop's term from now, `purchases` 1), never worn or laid. "Some or all" is
which rows are active. A row that cannot be granted (unknown type, zero value, a bad, retired or FREE item, an overflow, the same item
twice) is left out with one WARN `welcome reward left out` and never fails a login. Seeded (`V1.0.1`, THE WELCOME): **`chips`
500000** (owner, 30 Sep 2026: "Also add 5Lakh chips in welcome reward"), `diamonds` **5** and `hammers` **10** (the owner's own edit of
the seed the same evening — 9 and 20, the old `users` DEFAULTs, until then; a database that ran the earlier seed keeps 9 and 20 until
an UPDATE, `ON CONFLICT DO NOTHING`), `missiles` 1.
**In production (`NODE_ENV=production`) the rows decide**: `WELCOME_CHIPS` writes the chips row only into a table with none, and a boot
whose `WELCOME_CHIPS` was set and differs logs one WARN and leaves the row alone — production's `.env` says 300000, so a deploy of this
build moves a new account from 3 Lakh to 5 Lakh and logs that WARN. **Outside production** (tests, parity, a local run)
`WELCOME_CHIPS` SETS the chips row at every boot (`db.Users.SetWelcomeChipsWins`, `app.New` passes `cfg.Env != production`; logged
`welcome chips row set from WELCOME_CHIPS (not production)`), so every test and parity schema starts accounts at its pinned figure; a
store built without the app (a test, a tool) does the same before its first new account. Switch a grant off with `is_active = FALSE`, never DELETE (a
seeded row, and the chips row, come back at boot). A picture: `INSERT INTO welcome_rewards (code, reward_type, reward_ref_id,
sort_order) VALUES ('welcome_picture', 'PROFILE_PICTURE', (SELECT id::text FROM profile_pictures WHERE name = 'Lovestruck Cat'), 50)
ON CONFLICT (code) DO NOTHING;` (`TABLE_PICTURE` from `table_pictures`, `EMOJI` from `emojis`). `session:ready.config.welcomeChips` is
the active chips rows' sum through a 15 s cache (`db.WelcomeChipsCache`). Bots get it too. `internal/db/welcome_test.go`,
`internal/app/welcome_test.go`; checked live on the dev server (hammers off, a picture and an emoji on: a new guest got exactly those).
**The reward programs (owner's brief, 30 Sep 2026: one unified REWARD PROGRAM system — LOGIN_STREAK and CALENDAR modes × WEEKLY and
MONTHLY periods, "exactly three generic tables", every reward through the existing wallets and catalogues, never a per-program table, a
`user_login_streaks` or a streak column on `users`; the routes in §7.2, the app in §8.1/§8.4)** are three tables at the end of
`V1.0.0__baseline.sql` (REWARD PROGRAMS, after the welcome) and four programs at the end of `V1.0.1__seed.sql` (THE REWARD PROGRAMS):
**`reward_programs`** (`code` UNIQUE, `^[A-Z0-9_]{1,64}$`; `name`; `mode` LOGIN_STREAK | CALENDAR; `period_type` WEEKLY | MONTHLY;
`timezone`, an IANA name, default UTC; `week_start_day` 1..7, Monday 1; `reset_on_missed_day`, a streak's alone — a CHECK holds it FALSE
on a calendar; `starts_at`/`ends_at`, a campaign's window, NULL for always, in order; `is_active`; `sort_order`; timestamps with a touch
trigger), **`reward_program_rewards`** (`program_id` → `reward_programs` ON DELETE CASCADE; `day_number` 1..31, UNIQUE per program;
`reward_type` — an OPEN set the server checks, as the Lucky Draw's: CHIPS / DIAMOND / HAMMER / MISSILE with `reward_value` > 0 and no
ref, PROFILE_PICTURE / TABLE_PICTURE / EMOJI / BADGE with `reward_ref_id` = the catalogue row's id as text (a badge's `code`) and no
value, NO_REWARD with neither — the shape CHECK holds those nine and lets any other type through for a build that knows it;
`is_active`; `sort_order`) and **`user_reward_claims`** (`user_id` → `users` CASCADE; `program_id`; `period_start_at` epoch ms;
`day_number`; `claim_date` DATE, the day in the program's zone; a SNAPSHOT of `reward_type`/`reward_value`/`reward_ref_id`, so a reward
re-pointed later never rewrites what somebody was given; **`action_id` UNIQUE** = `reward:<userId>:<programCode>:<claimDate>`;
`claimed_at`), under ONE guarded unique index, `user_reward_claims_period_idx (user_id, program_id, period_start_at, claim_date DESC)` —
the one-claim-a-day guarantee and the streak's one read in one. **The streak is DERIVED from the claims** (`db/rewardprograms.go`,
`RewardPrograms.State`/`Claim`): the period is calendar math in the program's zone (`periodOf`: a WEEKLY period from the
`week_start_day`'s midnight to the next, a MONTHLY from the 1st's to the next 1st's — never 7 × 86400000, so a week across a
daylight-saving change is still seven days; `time/tzdata` is compiled in, so a zone loads on a bare host), and the day is read from the
LATEST claim, never `MAX(day_number)` (`streakAt`): a streak's today is that claim's day + 1 when it was yesterday, its day when it was
today (claimed already), 1 after a gap where `reset_on_missed_day` (else day + 1 — the missed day simply skipped), and 1 when the
period turned (a streak never crosses a week or a month, which is what the period index says); a calendar's day is today's place in
the period, a missed day missed (`calendarAt`). **A claim is ONE transaction a program** (`claimOne`), under the seat-lock stripe
(`Deps.WhileUnseated`, §5.1): `lockWallet` → this period's claims → the day → the day's reward (a day with none is claimed as NO_REWARD,
so the run still counts) → `grantReward` (`db/grant.go`, the Lucky Draw's grant generalised and now the ONE grant of a reward of any
kind, the draw's too: CHIPS through `chip_ledger`, reason **`reward_program`**, the claim's action_id; DIAMOND / HAMMER / MISSILE as
deltas on their `users` columns with no ledger row; a picture, table picture or emoji as the ownership row a purchase writes, for the
shop's term, a lapsed rental renewed, one still running left alone — `alreadyOwned`; a badge through `BadgeExpiry`, a running grant
extended) → INSERT the claim; a 23505 on the action_id or the period index is a replay and grants nothing, so two requests at once, a
retry and a second process all grant a day once (`TestTwoRequestsAtOnceGrantADaysRewardOnce`: eight goroutines over two pools, one
grant). Independent programs: each claims on its own, a refusal of one never touches another. A program outside its window, or in a
zone the server cannot load, is left out with one WARN (`reward program left out`); a day whose catalogue item is retired, gone or FREE is
left out too (`reward program day left out`) and neither shown nor granted. **Seeded**: `WEEKLY_LOGIN` (the owner's own list, edited into
the seed by the owner on 30 Sep 2026: Day 1 10,000 chips · 2 20,000 · 3 30,000 · 4 40,000 · 5 50,000 · 6 60,000 · 7 1 hammer — until that
evening chips, hammers and diamonds alternating), and `MONTHLY_LOGIN`, `WEEKLY_CALENDAR` and `MONTHLY_CALENDAR` as programs WITHOUT
days and INACTIVE (`is_active = FALSE`: the owner commented their day lists out of the seed the same day; a program with no days would be
left out of the wire and grant nothing, so each waits for its `reward_program_rewards` rows and an `UPDATE … SET is_active = TRUE` — the
seed's header shows the shape; the Go tests build the example day lists they need themselves, `exampleDays` in
`internal/db/rewardprograms_test.go`) — all UTC, Monday weeks, the streaks resetting on a miss, sort_order 10–40; every item by natural
key (`SELECT id::text FROM emojis WHERE name = …`, `SELECT code FROM badges …`) and a day whose item the catalogue lacks NOT inserted;
`ON CONFLICT (code)` / `(program_id, day_number) DO NOTHING`, so an owner's UPDATE survives every boot (the seed's header shows the UPDATE
and a campaign INSERT with a window). A reward changed by hand applies
to claims from then on. Tests: `internal/db/rewardprograms_test.go` (the brief's matrix: the first login, consecutive days, a missed day
with and without reset, a duplicate, the week's and the month's end, February and a leap year, every reward type landing where its
purchase would, the race, a repointed day, a zone and its week, a campaign's window, an empty day, an unloadable zone, the seed),
`rewardprograms_internal_test.go` (the period math, `streakAt`, `calendarAt`, the key), `internal/app/rewardprograms_test.go` (the
routes on the real wiring: 401, a forged body ignored, four grants, wallet == ledger, nothing twice, 409 `seated` at a table).
Ledger `reason` values: `welcome_bonus, hand_packed, hand_left, hand_win, hand_loss, table_tax (§6.6: the winner's winning tax, action `<handId>:tax:<userId>`, always negative),
milestone_reward, timed_bonus, daily_bonus (the three retired 30 Sep 2026 — history rows only, never purged), purchase, picture_purchase, table_picture_purchase, emoji_purchase, lucky_draw, reward_program (30 Sep 2026: a reward program's CHIPS reward, always positive, action_id `reward:<userId>:<programCode>:<claimDate>` — never purged), account_deleted, legacy_reconciliation,
test_fixture`. (`lucky_draw` is a Lucky Draw CHIPS prize — a chip source, always positive, action_id
`lucky:<userId>:<actionId>`.) (`picture_purchase` is a premium profile picture bought with chips — a chip **sink**,
always a negative delta, action_id `picture:<userId>:<pictureId>`; `table_picture_purchase` is the same for a table picture,
action_id `table:<userId>:<pictureId>:<n>`.)
(`purchase` is a Google Play chip pack, action_id `gplay:<token>`; `account_deleted` empties the
wallet when a player deletes their account, action_id `delete:<userId>` — chips leave the economy
there, which is correct, the player has gone.) The first three of the hand
reasons are the three checkpoints of §5.1. `boot`, `bet`, `show` and `refund` are **retired** — no
code writes them; rows carrying them are pre-9 Sep 2026 history (production's were cleared that day,
replaced by one `legacy_reconciliation` row per account so the invariant below stayed true).
**Invariant to keep true:** `SUM(chip_ledger.delta) per user == users.chips` (the psql check in §4
must return 0). The import wrote 12 `legacy_reconciliation` rows to make the old data satisfy it.

### 7.4 Config (`config/index.js` → `internal/config/config.go`) — env → default. Built **once at startup**.
Every key below is listed with its default in **`go-server/.env.example`** (copy to `go-server/.env`;
`cmd/gameplay` loads it with godotenv, never overriding real env). The Go loader parses integers
**strictly** (a malformed value stops the binary, key named in the log) and rejects unknown
`LOBBY_TABLES` categories at load. Three keys are Go-only: `PG_STATEMENT_TIMEOUT_MS` (below),
`ROOT_REDIRECT` (below) and `PUBLIC_DIR` (browser-client dir; default `./public` relative to cwd,
fallback `go-server/public`; not in `.env.example` — `config.go` documents it).

**Keys marked † configure TABLES, and are read only when `TABLE_CONFIG_SOURCE` is `env`** (owner, 23 Sep 2026:
"all table related config store in database"). They are `config.TableEnvKeys()`: `BOOT_AMOUNT`, `TABLE_STAKES`,
`LOBBY_TABLES`, `MAX_PLAYERS_PER_ROOM`, `MIN_PLAYERS_TO_START`, `TURN_TIMEOUT_MS`, `MAX_BET_ROUNDS`,
`POT_LIMIT_MULTIPLIER`, `MAX_RAISE_STEPS`, `SEEN_*`, `BLIND_*`, `MAX_BLIND_MOVES`, `ENTRY_CAP_*`, `MAX_MISSED_TURNS`,
`SIDESHOW_*`, `PRIVATE_*`, `NEXT_HAND_DELAY_MS`, `UNFUNDED_GRACE_MS`, `MISSILE_REVEAL_EXTRA_MS`, `VARIATION_*`,
`FIVE_CARD_PICK_TIMEOUT_MS`, `POKER_*`. In **db** mode the figures come from the four configuration tables (§7.3),
read ONCE by `app.New` (`resolveTableCatalogue`, before the socket layer, the REST handler and the RoomManager are
built, so all three hold one catalogue for the life of the process), and every † key set is IGNORED with one WARN
naming them ("keep them for a rollback to a build that predates the table catalogue"). **An edit to the rows applies
at the next restart, to tables opened after it**: hot reload was rejected — the manager reads `rm.game` lock-free from
many goroutines, and a table restored from Redis keeps the rules in its snapshot (and is drained if they no longer
match, §6.2). Where each key lands in db mode: `BOOT_AMOUNT`, `TABLE_STAKES`, `MAX_PLAYERS_PER_ROOM`,
`MIN_PLAYERS_TO_START`, `ENTRY_CAP_*` and the ADVERTISED `TURN_TIMEOUT_MS`/`MAX_BET_ROUNDS`/`SIDESHOW_*` →
`table_settings`; each `LOBBY_TABLES` entry → one public `table_configs` row (`category`, `boot_amount`, `min_chips`,
`max_chips`, a `pot=` as `max_pot`), carrying every figure the category rules compose for it (`SEEN_*`/`BLIND_*`/
`MAX_RAISE_STEPS`/`POT_LIMIT_MULTIPLIER`/`MAX_BET_ROUNDS` → the ladder columns, `VARIATION_MAX_POT_BOOTS` × boot →
a variation row's `max_pot`, `POKER_MIN_BUYIN_BOOTS` × boot → `min_buy_in`, the clocks and kicks → their `_ms`
columns); `PRIVATE_*` → the private templates. `gameplay -export-table-config` writes exactly that translation.

| Env | Default | Purpose |
|---|---|---|
| **`TABLE_CONFIG_SOURCE`** | unset → `env` if ANY † key is set, else `db` | **Go-only (23 Sep 2026).** `db` — the table catalogue in PostgreSQL; `env` — the † keys and `Defaults()`, composed exactly as every build before it did (the rows are seeded but not read). Anything else stops the boot. **Unset, it follows the † keys**, so a deployment whose `.env` pins its menu (production's names `LOBBY_TABLES`) keeps exactly that menu on deploy until someone switches it on purpose — one WARN then says how (export, check, set `db`, restart: DEPLOY.md §3). `Defaults()` and `.env.example` say `db`. A db boot whose catalogue cannot run a lobby logs ERROR and runs the env composition instead (`/health.tableConfig` `{source:"env", fallback:true}`). Tests (`internal/app`'s `testConfig`), the parity harness (`BASE_ENV` names `env`; only the `menu` profile runs `db`, §7.6), `parity-diff`, chiptest and crashtest name `env` — they configure clocks and menus through the † keys and rely on `LOBBY_TABLES=''` meaning any pair, which a db catalogue has no equivalent of. |
| `NODE_ENV` | development | `production` refuses to start on the default JWT secret, on a JWT secret shorter than **32 bytes** (the empty one included — Go only, 24 Sep 2026: an empty HMAC key let anyone forge a session for any user id), or with fake providers (the Go binary keeps the key name; the unit sets it) |
| `PORT` / `HOST` / `CORS_ORIGIN` | 3000 / 0.0.0.0 / `*` | |
| **`WS_COMPRESSION`** | true | **Go-only (26 Sep 2026).** Negotiate websocket permessage-deflate (RFC 7692) with every client that offers it — they all do: dart:io's WebSocket (the Flutter app), the browsers, node's `ws` (bots, `tools/`). `sio.Options.EnableCompression`; gorilla negotiates no context takeover both ways, so each message is deflated on its own, and frames under `sio.DefaultCompressMinBytes` (256: pings, acks, action broadcasts) go out plain. Measured locally at 500 bots: the server's traffic per player **8.9 → 4.1 KB/s (−54%)**, move ack p95 3 → 4 ms, the game process's CPU about a quarter higher — traffic, not CPU, was what the 26 Sep production ladder showed filling first. `false` = plain frames, Node's behaviour (engine.io 6 left perMessageDeflate off); a restart applies it. A debug line `sio: websocket open` says whether each connection is compressed. |
| `JWT_SECRET` / `JWT_EXPIRES_IN` | dev-only-insecure-secret / 30d | |
| `GOOGLE_CLIENT_IDS`, `FACEBOOK_APP_ID/SECRET` | empty → 503 | Facebook's pair is read and unused while Facebook sign-in is switched off (23 Sep 2026, §7.2). `GOOGLE_CLIENT_IDS` must name the Web client `265025011940-0k4kh3ljcopn2pmkpb0q1rhbe8er8h09.apps.googleusercontent.com`: `prod.sungamestudio.com` answered every Google login 503 `provider_unconfigured` until the owner set it and restarted on 24 Sep 2026 (a dummy-token login then answered 401 `invalid_token`); a login answered 503 there means it is missing again — §12.3 |
| `AUTH_ALLOW_FAKE_PROVIDERS` | false | |
| **`REST_LOGIN_RATE_LIMIT`** / **`REST_WALLET_RATE_LIMIT`** / **`REST_RATE_WINDOW_MS`** | 60 / 120 / 60000 | **Go-only (24 Sep 2026).** Per-client-IP fixed-window limits (`config.RESTRateConfig`, `auth/ratelimit.go`): `POST /api/auth/login`, and the doors that move a wallet (Play purchases, picture and table-picture buys, the missile store, `DELETE /api/account`). Over it: **429** `{error:"rate_limited"}` + `Retry-After`, one WARN `rest rate limited` per IP per window. 0 = that limit off. The IP is the peer's, or nginx's `X-Real-IP` from a loopback peer; a loopback peer with no `X-Real-IP` (bot-play, `tools/`, tests) is never limited. Generous on purpose — CGNAT puts many players behind one IP. |
| **`DATABASE_URL`** | `postgres://postgres:postgres@localhost:5432/gameplay` | |
| **`PG_SCHEMA`** | `public` | tests use `test_<suite>_<rand>` and drop it after |
| **`PG_POOL_MAX`** | 10 | |
| `PG_STATEMENT_TIMEOUT_MS` | 15000 | **Go server only**: Postgres `statement_timeout` per pooled connection so a hung query fails one ledger write instead of freezing a table; 0 = no limit (Node behaviour) |
| **`LEDGER_PURGE_INTERVAL_MS`** | 300000 (5 min) | **Go server only.** How often the in-process purge goroutine runs (`App.startLedgerPurge`, a `time.NewTicker`, first pass one interval *after* boot — a server restarted more often never purges). **0 is the only way to turn the job off.** |
| **`LEDGER_PURGE_AFTER_MS`** | 600000 (10 min) | **Go server only.** A `chip_ledger` row is deleted once older than this — but **only** `hand_win`/`hand_loss`/`hand_packed`/`hand_left` (`db.purgeableReasons`, hardcoded in the query): `purchase`, `picture_purchase`, `milestone_reward`, `timed_bonus`, `welcome_bonus` are never purged, since their UNIQUE `action_id` is a standing double-credit guard — nor, since 27 Sep 2026, any row of a hand a player report names (`player_reports.hand_id`, §7.3). Deletion is allowed only inside `PurgeLedger`'s own transaction, which sets `app.ledger_purge`; the append-only trigger refuses every other DELETE and every UPDATE. **Trap: 0 does NOT disable it** — the cutoff becomes `now`, so the next pass takes every purgeable row. Now equal to `RESUME_OFFER_MS`, so a retry at the edge of the resume window can find its `action_id` already gone (was 24h for that margin). |
| `WELCOME_CHIPS` / `BOOT_AMOUNT` † | 500000 / 200 | only `BOOT_AMOUNT` is a table key (db: `table_settings.default_boot_amount`). **Since 30 Sep 2026 the `welcome_rewards` `chips` row is the welcome** (§7.3; seeded 500000, 5 Lakh — the default here matches): in production `WELCOME_CHIPS` never writes over it and a differing value is one WARN; outside production it SETS the row at every boot (tests, parity, a local run); a negative one stops the boot, 0 writes the row switched off. 10 Lakh from 27 Sep 2026 (owner: "every new user will get 1 missile 20 Hammers and 10Lakh coin"), 3 lakh from 14 Sep 2026, 2 lakh before. **Production's `.env` sets `WELCOME_CHIPS` explicitly**, so a new default changes nothing there until that line does |
| `TABLE_STAKES` † | `200,5000,50000,2000000` | empty = any (tests); db: `table_settings.stakes` (an empty array is any; a non-empty one gains the boot of every active public row it lacks, since a table's own boot is always an allowed stake, §7.3) |
| **`LOBBY_TABLES`** † | `seen:200:tax=1,blind:200:tax=1,blind:5000:max=200000000:tax=1,blind:50000:max=2000000000:tax=1,blind:2000000:min=500000000:tax=1,variation:50000:max=2000000000:tax=1,variation:2000000:min=500000000:tax=1,seen:50000:pot=50000000:tax=1,three_card_poker:50000,five_card_draw:50000,texas_holdem:50000,omaha:50000` (27 Sep 2026: every Teen Patti table `tax=1`, §6.6; the top Blind and Variation tables at 20 Lakh, 10 Lakh before; Blind 5,000 open to 20 Cr, 5 Cr before; the 50,000 Blind and Variation tables to 200 Cr, 100 Cr before — what the prose below says of 10 Lakh, 5 Cr and 100 Cr is the earlier menu) | the menu; empty = any pair (tests). **`pot=N` is a table's OWN pot cap** (Go only; owner, 19 Sep 2026: a second seen table, boot 50,000, open to all, pot limit 5 Crore — `LobbyTable.MaxPot`, read by `TableRules` and `MenuMaxPot` through `menuPotFor(category, boot)`): it wins over the category's cap (`SEEN_MAX_POT` is 40 boots at 50,000, so every hand there would be dealt into the POT_LIMIT showdown), changes nothing else — the ladder and rounds stay the category's — and a private table never reads it. 5 Crore is 5,00,00,000 = `50000000`; `500000000` is 50 Crore. The new entry is LAST in the list like every later addition; the Flutter lobby files it under Seen by category. Categories are `seen`, `blind`, (Go only, 18 Sep 2026) **`variation`** and (Go only, 19 Sep 2026, §6.5) the four poker ones **`three_card_poker`, `five_card_draw`, `texas_holdem`, `omaha`** — anything else stops the boot. A poker entry's boot is its big blind (Hold'em, Omaha) or ante (3-Card Poker, 5-Card Draw); its `minChips` on the menu is raised to the table's `minBuyIn` (`POKER_MIN_BUYIN_BOOTS` × boot) and each `options.tables[]` entry carries `game`, `smallBlind`, `bigBlind`, `ante`, `minBuyIn`, `holeCards`, `maxDiscards` (omitted on Teen Patti entries). Poker keeps **one table per game, all four at 50,000** (owner, 19 Sep 2026: "in poker category only keep one table 50000 for each gameplay"; it was six entries at 200 and 5,000 earlier that day) — so blinds 25,000/50,000, an ante of 50,000, and a buy-in of **5,00,000** at every poker table, which is MORE than the 3,00,000 welcome: a brand-new account sees the whole Poker category shut until it has won 5 Lakh, and `POKER_MIN_BUYIN_BOOTS` (4 = 2 Lakh) is the one key that changes that without touching the stake. The four default poker entries are LAST; an older Go tag cannot boot on a `.env` that lists one, and an installed app older than the first poker-aware build draws each as a seen table — raise `MIN_CLIENT_BUILD` first. Variation keeps **two tables only, 50,000 and 10 Lakh** (owner, 18 Sep 2026), behind the bands blind's tables of those stakes have; its entries are LAST so the five before them keep their places, and clients are told of the category (`config.categories`) only when it is listed. **Rollout:** an installed app older than the build that knows the category draws that card as a seen table and never shows the picker, so every hand there is a server-chosen Muflis — raise `MIN_CLIENT_BUILD` first. **Production's `.env` sets `LOBBY_TABLES` explicitly**, so the new default changes nothing there until that line does; a Go tag older than this cannot boot on a `.env` that lists `variation:`. Each entry is `category:boot` plus an optional **stack band** — `max=N` shuts the table to a player holding MORE than N, `min=N` to one holding LESS. Exactly the limit is allowed at either end. A band whose min exceeds its max fails at load (it would advertise a table nobody could join). **In db mode** the menu is the active public `table_configs` rows in `sort_order` (§7.3) and this key is ignored; the rollout rule becomes the row's: a table appended to the seed arrives inactive on an existing database, and goes live with `is_active = TRUE` after `MIN_CLIENT_BUILD` — never by a restart. A row with an unknown category is left out with a logged reason, not a stopped boot. |
| `MAX_PLAYERS_PER_ROOM` / `MIN_PLAYERS_TO_START` † | 5 / 2 | the Teen Patti felt lays out 2..5 places round its table from it (`SeatRing`, §8.4); 5 is still hardcoded in the poker felt's `seatPlaces` and the browser CSS |
| `TURN_TIMEOUT_MS` † | 25000 | |
| `MAX_BET_ROUNDS` / `POT_LIMIT_MULTIPLIER` / `MAX_RAISE_STEPS` † | 20 / 1024 / 8 | defaults only; `createTable` overrides all three per category (seen: 7 / 1024 / 2, blind: 0 / 0 / 0) |
| `SEEN_MAX_RAISE_STEPS` / `SEEN_MAX_BET_ROUNDS` / `SEEN_MAX_POT` † | 2 / 7 / **2000000** | brief says "10 moves"; code is 7 rounds. **20 Lakh is the most a seen hand can pay** (owner, 12 Sep 2026): the moment the pot reaches it every player still in shows and the best hand takes it (`potCapReached` → `resolveShowdown(…, WinPotLimit)`), and `betOptions` headroom stops a bet that would carry the pot past it. `SEEN_MAX_RAISE_STEPS 2` is the two-rung ladder — chaal, or one raise — so a seen player raises once per turn. None of the three reaches a public variation table since 28 Sep 2026: it bets as a blind one, fixed in code (§6.4). |
| `MAX_BLIND_MOVES` † | 4 | |
| **`WINNER_TAX_MIN_WINNINGS`** † | 5000000 | **Go-only (27 Sep 2026, §6.6).** The smallest WINNINGS (the pot less the winner's own chips) a table that taxes its winners (`LOBBY_TABLES` `tax=1`) taxes; 0 taxes any. db: `table_configs.tax_min_winnings` per row. |
| `ENTRY_CAP_BOOT` / `ENTRY_CAP_CATEGORY` / `ENTRY_CAP_MAX_CHIPS` † | 200 / blind / 2000000 | Blind 200 is open up to 20 Lakh (owner, 27 Sep 2026; 5 Lakh before). Requirement 30, and now the oldest case of the band above: `RoomManager.tableMaxChips` folds this trio into the matching menu entry's `maxChips`, so the lobby draws it from the same field as every other table. A `max=` on that entry in `LOBBY_TABLES` wins, being the more specific statement. |
| `MAX_MISSED_TURNS` † | 3 | |
| **`UNFUNDED_GRACE_MS`** † | 30000 | **Go-only.** How long a seat that can no longer cover the boot is held between hands before the `insufficient_chips` kick, so a player can buy chips and stay; `you.unfundedDeadline` carries the deadline to that player and the Flutter status line counts it down. 0 = kicked at once (Node's rule). |
| **`VARIATION_SELECT_TIMEOUT_MS`** † | 10000 | **Go-only.** How long the player who opens a variation table's hand has to choose its variation before the SERVER chooses Muflis. The client's countdown is decoration. 0 = the window never lapses on its own (it still closes when the chooser leaves) — never in production: a chooser who walks away holds the table for the whole reconnect grace. Given to variation tables only; a seen or blind table's `TableConfig` and snapshot are unchanged. |
| **`FIVE_CARD_PICK_TIMEOUT_MS`** † | 8000 | **Go-only** (owner, 19 Sep 2026). The EXTRA time a player gets, once their five cards are in front of them under 5-Card Teen Patti, to choose which three of them play (§6.4). Per player and per hand; lapsing plays the first three they were dealt. A chooser whose turn is running has it pushed out to cover the window and a full turn after it. 0 = the window never lapses, and a hand can then sit on a player who has looked and will not choose until their turn clock packs them — never in production. Given to variation tables only. |
| **`VARIATION_MAX_POT_BOOTS`** † | 0 | **Go-only.** A public variation table's pot cap, counted in BOOTS of that table; **0 = no pot limit, the default** (owner, 18 Sep 2026). A count of boots and not a figure because variation runs at several stakes (§6.4). `MenuMaxPot(category, boot)` advertises exactly what `TableRules` gives the table. A product that overflows int64 for any variation table on the menu stops the boot with the key named; a negative value does too. |
| **`POKER_TURN_TIMEOUT_MS`** / **`POKER_MIN_BUYIN_BOOTS`** / **`POKER_MAX_DISCARDS`** † | 0 / 10 / 3 | **Go-only** (§6.5). A poker decision's clock (0 = `TURN_TIMEOUT_MS`); the smallest stack that may sit at a poker room, in boots of that table (at least 1; the menu's `minChips`); how many cards a 5-Card Draw player may exchange (0..5, else the boot stops). How each variant plays is fixed in `poker.Variants`, not here. |
| **`MISSILE_REVEAL_EXTRA_MS`** † | 3000 | **Go-only.** Added to `NEXT_HAND_DELAY_MS` after a missile showdown (§6.1), so the client's volley, its explosions and a look at every hand fit before the next deal. |
| **`MIN_CLIENT_BUILD`** | 0 | The oldest client build allowed to play, sent to every client in `session:ready.config.minClientBuild`. A client below it is held on the update screen with no way past (Flutter `_belowMinimumBuild`/`_forceUpdate`). **0 = no floor**, which is what production runs; raise it only after the newer build is actually live in the store, or the floor locks everyone out of a version they cannot yet install. Play's own in-app check (`AppUpdate`) is a separate, best-effort nudge that fails open (a Soft Update prompt since 28 Sep 2026). **Since the app version gate (28 Sep 2026) this is the floor UNDER each connection's `minClientBuild`**, which is the larger of it and the build number the platform's `app_versions.minimum_version` translates to (§7.2) — so a raised minimum version already raises it for the installs that predate the gate, and this can stay 0. The gate's own minimum is a version, enforced by the server at every signed-in door; this key is enforced by the app alone. |
| **`APP_VERSION_REQUIRED`** | false | **Go-only (28 Sep 2026; §7.2 "The app version gate").** true = refuse every client that declares no app platform — every install that predates the gate — with FORCE_UPDATE (REST 426 `update_required`, `connect_error update_required`). `bot`, `tool` and `web` are never refused. Turn it on ONLY once the oldest build the store still serves sends `X-App-Platform` (the first build with the gate) and the android `minimum_version` holds everything older — until then it would lock out apps nobody has updated yet (DEPLOY.md "The app version gate"). A restart applies it. |
| **`APP_VERSION_CACHE_MS`** | 15000 | **Go-only (28 Sep 2026).** How long the `app_versions` rows are cached in the process — the longest an operator's UPDATE (a raised minimum, a maintenance) takes to be enforced. 0 reads the table on every request. A negative value stops the boot. The versions, store links, maintenance and messages themselves are NOT keys: they are the rows (§7.3). |
| `SIDESHOW_TIMEOUT_MS` / `SIDESHOW_MIN_PLAYERS` † | 6000 / 3 | |
| `DISPLAY_NAME_MAX` | 24 | also hardcoded: providers.js `.slice(0,24)`, Flutter login/lobby `maxLength: 24` |
| `PRIVATE_BOOT` / `PRIVATE_MAX_POT` / `PRIVATE_MAX_RAISE_STEPS` † | 200 / 500000 / 2 | db: the private templates (`is_private` rows, one per category); `privateBoot`/`privateMaxPot` on the wire are the seen template's |
| `NEXT_HAND_DELAY_MS` † / `CONSOLIDATE_INTERVAL_MS` / `RECONNECT_GRACE_MS` | 4000 / 15000 / 60000 | only the first is a table key |
| `RESUME_OFFER_MS` | 600000 | how long a lapsed seat's table is offered back via `session:ready.resume` |
| `BLIND_MAX_RAISE_STEPS` / `BLIND_MAX_BET_ROUNDS` / `BLIND_POT_LIMIT_MULTIPLIER` † | 0 / 0 / 0 | blind tables: 0 = unlimited (ladder to the stack, no per-bet ceiling, no forced showdown) |
| `CHAT_MAX_HISTORY` / `CHAT_MAX_LENGTH` / `CHAT_RATE_LIMIT` / `CHAT_RATE_WINDOW_MS` | 100 / 140 / 5 / 5000 | Flutter's chat field allows **200** — chars 141–200 are dropped server-side |
| `METRICS_ENABLED` / `METRICS_PATH` / `METRICS_PREFIX` | true / `/metrics` / `game_server_` | Prometheus exposition (req. 35); prefix applies to prom-client's default process metrics only |
| `METRICS_TOKEN` / `METRICS_ALLOW_IPS` | empty / empty | bearer token and/or comma-separated client IPs required to scrape; both empty = open (fine behind a firewall, wrong on the internet) |
| **`REDIS_URL`** | empty | **The live store — where ALL game state lives** (§5.1). Empty = an in-process store: single instance, and a restart loses every table (players re-join; nothing is reconstructed). Set (`redis://127.0.0.1:6379/0`) → Redis, and the boot **fails fast** if it is unreachable. There is no `SNAPSHOT_FLUSH_MS`: PostgreSQL keeps no game state, so there is nothing to flush to it. |
| `LIVE_STATE_TTL_MS` | 86400000 | how long a table snapshot that stops updating survives in the live store |
| `LIVE_INSTANCE_ID` | `hostname:pid` | presence / matchmaking owner tag (`Load()` only; `Defaults()`/`FromEnv()` carry `""`) |
| `LIVE_RECONCILE_MS` | 30000 | how often the live store is pinged, refilled from memory after an outage, and swept for stray seat/summary keys; 0 disables |
| **`REPORT_MAX_PER_REPORTER`** / **`REPORT_WINDOW_MS`** / **`REPORT_PAIR_WINDOW_MS`** / **`REPORT_DESCRIPTION_MAX`** / **`REPORT_RECENT_MS`** / **`REPORT_ATTEMPT_LIMIT`** / **`REPORT_ATTEMPT_WINDOW_MS`** | 2 / 86400000 / 86400000 / 500 / 600000 / 10 / 60000 | **Go-only (Report Player, 27 Sep 2026, §7.2).** At most 2 reports per player in any 24 h (owner; rolling, counted from `player_reports` in the filing transaction — 429 `report_limit_reached`; 0 = no limit, a zero window under a live limit stops the boot); one report per reporter → player per pair window (0 = only one per hand, which always holds; 409 `already_reported`); the longest description in code points (1..2000); how long a player who left stays reportable by those they sat with (in MEMORY: a restart forgets it; 0 = only players seated with the reporter now); and the per-ACCOUNT request limit before anything is read (429 `rate_limited`; 0 = off). |
| **`STATS_FLUSH_MS`** / **`STATS_FLUSH_BATCH`** | 10000 / 500 | **Go-only (Player stats v2, 27 Sep 2026, §7.3).** How often the flusher moves the players' pending statistics from the live store into PostgreSQL, and the most players one flush transaction holds (a pass takes batch after batch until nobody waits). The interval is also how far a player's statistics and the hands-played milestone may trail play. **Trap: `STATS_FLUSH_MS=0` turns the flusher OFF** — nothing is flushed, not even at shutdown; the counters wait in the live store for a process that flushes. |
| `LOG_LEVEL` | info | slog level (`util.ParseLogLevel`) |
| `ROOT_REDIRECT` | empty | **Go-only.** Set (**production: `/dashboard/`**, the Grafana login) it hides the browser client: `GET /` → 302 to the value, every top-level file of `PUBLIC_DIR` (`index.html`, `client.js`, the stylesheets) and `/socket.io/socket.io(.min).js` → 404; subdirectories keep serving — `privacy/` (Play listing link), `profiles/` (Flutter avatars via `/api/profiles`). Empty = browser client at `/` (dev, parity). The rule is the directory layout, not a filename list (`static.go`). |

There is no `go-server/.env` on the dev box (it is git-ignored); the server runs on these defaults — so with no †
key set, `TABLE_CONFIG_SOURCE` resolves to `db` and the dev server plays the seeded catalogue (which is the defaults).
Production's lives at `/var/www/gameplay/king-teenpatti/go-server/.env` (`PG_POOL_MAX=50`, `JWT_SECRET`, `METRICS_TOKEN`,
`LOBBY_TABLES`, `WELCOME_CHIPS`, …) — its `LOBBY_TABLES` line keeps it in env mode until DEPLOY.md §3's switch.

### 7.5 Metrics (`src/metrics/index.js` → `internal/metrics/{names,metrics}.go`, requirement 35) & Grafana (requirement 36)
- One registry (default label `service="king-teenpatti"`), exposed by `Metrics.Handler()` on `GET /metrics`
  (token/IP-guarded per `config.metrics`). `HTTPMiddleware()` runs before body parsing and labels by
  **route pattern** (`RouteLabelFor`, else `static`/`unmatched`) — never the raw URL.
- Process/runtime metrics carry `game_server_`: `game_server_process_*` (CPU, RSS, open/max fds, start time,
  `process_uptime_seconds`, network bytes) and `game_server_go_*` (goroutines, threads, GC, memstats,
  `go_sched_latencies_seconds` — the event-loop-lag analogue). **No `game_server_nodejs_*` series** since the Go
  switch; the Node build's `nodejs_*` set is documented historically in `MONITORING.md`.
- Game metrics (`game_…`): sockets (`connected_sockets`, `_peak`, `connections_total`, `disconnections_total{reason}`,
  `reconnects_total{kind=seat_held|offer}`, `socket_errors_total{code}`, `socket_messages_total{event}`, `socket_emits_total{event}`,
  `session_replaced_total`); tables (scrape-time gauges via `bindRooms(rooms)`: `players_online`, `active_games`, `waiting_games`,
  `tables{category,stake}`); counters `games_started_total{category}`, `games_completed_total{category,reason}`,
  `games_abandoned_total{category}`, `moves_total{action}`, `invalid_moves_total{code}`, `turn_timeouts_total`, `kicks_total{reason}`,
  `chat_messages_total`, `pot_settled_chips_total`; histograms (buckets 1 ms…1 s) `move_processing_duration_seconds{action}`,
  `creation_duration_seconds`, `join_duration_seconds{route=quick_join|code|create|switch|resume}`, `state_update_duration_seconds`,
  `hand_start_duration_seconds`, `settlement_duration_seconds`, `db_transaction_duration_seconds{op=bet|boot|settle}` (+ `_errors_total{op,code}`
  — `op=bet` is now the transaction that BANKS a departing player's bets, not one per bet, §5.1);
  pool gauges `db_pool_connections/idle_connections/waiting_requests` via `bindPool(getPool)`; HTTP `http_requests_total` /
  `http_request_duration_seconds{method,route,status_code}`.
- Player-stats metrics (Player stats v2, §7.3): `game_stats_flushes_total{result}` and the histogram `game_stats_flush_players`
  (players per committed batch); the live-store ops `record_stats`, `take_stats_batch`, `stats_batches` and the batch finish
  and drop join the `op` labels below.
- Live-store metrics (`internal/live` + the restart sequence): `live_store_operations_total{op,result}`,
  `live_store_duration_seconds{op}` (buckets 0.1 ms…1 s), `live_store_errors_total{op}`, `live_store_reconciles_total{result}`,
  `restored_tables_total` (**unlabelled** — the live store is the only source a table can come back from),
  `restored_seats_total`. `/health` gains `live: {kind, ok, tables}` after `db`. **There are no
  `game_snapshot_*` series, no `game_restore_reconciled/rejected_total` and no
  `game_refunded_pots/chips_total`** — the first two belonged to the abandoned PostgreSQL backstop,
  the third to `RefundOrphanedPots`, which went when PostgreSQL stopped holding pots (§5.1).
- The app version gate (28 Sep 2026; §7.2): **`game_app_version_checks_total{platform,status}`** — every `GET /api/app-config`
  verdict — and **`game_app_version_rejections_total{platform,status,via}`** — every signed-in REST call (`via="rest"`) and socket
  handshake (`via="socket"`) the gate refused. `platform` ∈ android, ios, bot, tool, web, `none` (nothing declared), `other` (a platform
  the server does not know); `status` ∈ normal, soft_update, force_update, maintenance — lower-cased, `metrics.AppPlatforms` /
  `AppStatuses` / `AppVias` fold anything else to `other`. **The version a client sent is never a label** (it is in the log line). The
  catalogue in `metrics_test.go` is 46 since. `rate(game_app_version_rejections_total{status="force_update"}[5m])` is how many old
  builds are still knocking after a minimum was raised.
- **Label rule (enforced by `SafeLabel()` and `internal/metrics/metrics_test.go` + `tools/parity/metrics.test.js`):** no socket/user/room id,
  table code, name, URL or IP ever becomes a label value. `Table` stays uninstrumented — counters are fed from its events in the
  socket layer, timings from the socket handlers, `RoomManager.CreateTable` and `db/ledger.go`; `game` must not import `metrics`
  (it takes `MetricsHooks` func fields).
- Ops bundle: **`go-server/ops/monitoring/`** (formerly `server/ops/monitoring/`) — `prometheus/prometheus.yml` + `alerts.yml`,
  `docker-compose.yml` (Prometheus, Grafana, postgres_exporter, nginx-prometheus-exporter, node_exporter), Grafana provisioning +
  `grafana/dashboards/king-teenpatti.json` (sections System · Runtime (formerly Node.js) · WebSockets · Multiplayer Game · Latency ·
  PostgreSQL · Nginx) **and `king-teenpatti-logs.json`** (uid `king-teenpatti-logs`, added 10 Sep 2026: the gameplay journal in
  **Loki** — Alloy ships `journalctl -u gameplay` as stream `{service_name="gameplay"}`, every line the slog JSON, `| json` parses it;
  rows Volume · Warnings & errors · Sessions & money (incl. `login refused`) · Server lifecycle · All logs), **plus the split set**
  `king-teenpatti-{system,runtime,sockets,game,latency,postgres,nginx,redis}.json` — one dashboard per row of the combined one,
  **generated** by `grafana/split_dashboards.py` (never hand-edit them; `--check` before commit). All ten live in Grafana folder
  `king-teenpatti-dashboards`, tagged `king-teenpatti`, and reach each other through the "King Teen Patti dashboards" drop-down;
  import = `POST /api/dashboards/db` with a service-account token, `overwrite:true`, `folderUid: king-teenpatti-dashboards`),
  `nginx/king-teenpatti.conf.example` (websocket proxy, `stub_status`, `worker_connections 16384` — the 768
  default capped production at ~1,500 players on 2026‑09‑08), and `MONITORING.md` (runbook + requirement 35/36 checklist). Postgres
  internals come from postgres_exporter, not the game server. Production's Prometheus/Grafana were pointed at the old path once;
  DEPLOY.md §6 has the re-import and `rule_files` steps.
- **`go-server/ops/install-monitoring.sh`** (owner, 27 Sep 2026: "install grafana and prometheus on prod", then Loki) is how
  `prod.sungamestudio.com` runs it: system packages, not compose — Prometheus and the four exporters (Ubuntu), Grafana, Loki and
  Alloy (apt.grafana.com, pinned `.deb` fallbacks checked by sha256), every listener on 127.0.0.1, Grafana served at
  `https://<domain>/dashboard/` by an nginx snippet that also answers `/metrics` 404 to the internet. Idempotent; `sudo bash
  go-server/ops/install-monitoring.sh`, or `sudo env MON_DIR=<dir> bash …` for another copy of `ops/monitoring`. **Disk**:
  Prometheus + Grafana under 1 GB (TSDB `retention.size` 640 MiB ≈ 10–15 days at today's rate; Grafana logs to its file only,
  daily/16 MiB, 7 days); Loki under 3 GB on its own loop-mounted volume (`/var/lib/loki.img` → `/var/lib/loki`), kept off the
  ceiling by `loki-disk-guard.timer`, which shortens `/etc/loki/runtime.yml`'s retention (180 days at most) when the volume
  passes 80%. No debug logging anywhere (owner): Loki at warn, Alloy drops the game server's DEBUG lines. The Grafana admin
  password is set (random, `/root/grafana-admin-password`) only on a Grafana the script installs; an existing one's is never
  touched. `MONITORING.md` "Installing on the game host" is the reference.

### 7.6 Tests & tools
- **Go test suites** (`cd go-server && go test -race ./...`; names are sentences, `TestASideshowNeedsThreePlayersInTheHand`):
  - `internal/game` — no DB. `NewTable` with `game.NewMemoryLedger(hooks)` + `testclock.Fake`; `clock.Advance(d)` is
    synchronous and waits for every fired callback (Node's `await advance(ms)`); after an indirect removal (a kick) use
    `table.Settled()`. Every suite passes a full config (Table uses it raw). Deterministic showdowns via the test
    `harness` in `table_test.go` (`h.setCards(id, "As", "9s", "4s")` — an unexported seam in package `game`, never an
    exported method). A `PersistChips` hook that returns an error
    **refuses** the move (`persist_failed`); a bookless `MemoryLedger` banks 0 (`persisted` semantics, §12.2). Suites:
    `table`, `tablerules`, `sideshow`, `settlement`, `roommanager` (+ `_fixture`), `handrank`, `deck`, `chat`, `wire`
    (null-vs-absent JSON rules), `review_money*`/`review_concurrency` (adversarial), `interop` (see below).
  - `internal/db`, `internal/app` — **Postgres-backed** via `dbtest.Open(t, "<pkg>")`: schema `test_<pkg>_<rand>`, dropped in
    `t.Cleanup`, `t.Skip` when `TEST_DATABASE_URL`/`DATABASE_URL`/the default is unreachable. `internal/app` = the old
    `integration`/`socketProtocol`/`stakes`/`statsAndRewards`/`metrics` process suites (real sockets through
    `socket/testclient`, `/health`, `/metrics`, static files, review_headers); `internal/db` = ledger transactions
    (`duplicate_action`, `stale_state`), users/rewards, `NormalizeDisplayName`, `statement_timeout`, review_money.
  - **The ranking audit** (24 Sep 2026, after the owner's "a pair is showing Trail" report): `internal/game/review_ranking_oracle_test.go`
    — an oracle classic evaluator written from §6.3 and wild masks from §6.4's rule text, brute-forced, against Evaluate/Compare
    and every VariationRules over all 22,100 hands (AK47, LOWEST/HIGHEST_JOKER exhaustive; JOKER for all 13 ranks, HUKAM all 4
    suits; Muflis reversed; FIVE_CARD best-of-ten; every natural pair under every rule set is a Trail only with a wild card) —
    ~1 min, ~3 min under `-race`; `review_showdown_winners_test.go` — who WINS at seen, blind and every variation table with
    deterministic cards (shows, forced and pot-limit showdowns in every seat order, sideshows, ties, pot to the winner);
    `flutter-client/test/review_reveal_naming_test.dart` — the reveal shows the wire's name and marks exactly the wild cards,
    and a source scan proves the app ranks nothing itself. The audit's live half (112 hands on the local server judged by an
    independent JS evaluator, 0 mismatches) was a scratch script, not kept.
  - **Variation Teen Patti** (§6.1, §6.4): `internal/game/variation_test.go` (the six rule sets; a wild never makes a hand
    worse, never duplicates a held card, three wilds against an exhaustive search) and `table_variation_test.go` (the window:
    the six picks, timeout → MUFLIS, who may choose, the pick-versus-clock race run 200 times under `-race`, chooser leaves,
    hand/table ends mid-window, restart mid-window keeping the ORIGINAL deadline, and "a seen table's JSON has no variation
    key"); `internal/socket/variation_test.go` is the same over real sockets.
  - **The table catalogue** (§7.3, §7.4; 23 Sep 2026): `internal/config/tables_test.go` (`Spec` composes figure by
    figure what `newTableLocked` and `poker.ConfigFor` always built; the default catalogue survives the database round
    trip; `Validate` leaves bad rows out and holds every table to the taxonomy — blind filed under poker takes its five
    tables, no Poker engine takes eight, seen under poker is unusable; `SameRules` ignores only band, place and engine);
    `internal/db/tableconfigs_test.go` (**`TestTheSeededTableCatalogueIsTheDefaults`**, a row appended to a non-empty
    catalogue arrives inactive, an inactive category or engine hides every table under it, the foreign keys, no DEFAULT on
    a figure, the CHECK floors, the export round trip — env menu and taxonomy — applied twice and across a reboot,
    `SkipMigrations`), `upgrade_boot_test.go` (`TestABootBringsAnOlderDatabaseForward`), and `db_test.go`/`bootlock_test.go`/
    `handover_boot_test.go` counting the four tables; `internal/game/tablecatalogue_test.go` (a row's figures reach the
    table, the card and the payload; private fold; the entry cap as the band in db mode; DRAINING — a changed or delisted
    restored table is never matched into, `JoinByCode` still reaches it, and a drained poker room does not trap the buy-in;
    `EngineOf` agrees with `Category.Game()`; the payload's version is its own hash); `internal/poker/factory_test.go`
    (`ConfigFromSpec`, `MenuEntry` from a spec); `internal/socket/tableconfig_test.go` (`session:ready.config` keys +
    `tableConfigVersion`); `internal/app/tableconfig_test.go` (a db-sourced server plays by the seed and not the env,
    `GET /api/tables` = the session menu under one version with ETag/304, an edited row applies at the next boot only, a
    bad row is left out and the boot carries on, an unusable catalogue — or no database — falls back); and
    `cmd/gameplay/tableconfig_test.go` (the export is SQL alone on stdout, refuses an unusable catalogue; the check's
    exit codes; export → apply → check is the env menu).
  - `internal/socket` (invalid moves, hostile payloads, leaks, money, concurrency, stack), `internal/sio` (framing, server,
    concurrency), `internal/auth`, `internal/config`, `internal/metrics` (the label rule), `cmd/gameplay` (version stamp).
  - **Node-assisted tests, all `t.Skip` without their prerequisite:** `internal/auth/nodeinterop_test.go` (tokens minted by
    `jsonwebtoken` verify in Go and vice versa) and `internal/sio/interop_test.go` (real `socket.io-client`) use
    **`tools/node_modules`** — `cd tools && npm install`. `internal/game/interop_test.go` (every hand ranking and every
    sanitising result vs the Node engine) needs **`NODE_REFERENCE_DIR`** = a checkout of the removed `server/` tree with
    `node_modules` (`git worktree add /tmp/node-ref c19963b && (cd /tmp/node-ref/server && npm ci)`).
  - **The one-time XP missions** (§6.6; 28 Sep 2026): `internal/db/missions_test.go` (the owner's eight as seeded, and no Poker
    one; partial progress to completion; nothing again after it — 24 h, a week, a new login, a restart; a replayed settle; eight concurrent
    settles through two pools and one hand from both; the daily XP beside the missions exactly as alone, a daily cap limiting the
    daily XP only; missions the test adds scoped to Poker count only poker hands, one scoped to Texas Hold'em only Texas Hold'em; different categories and
    variations; leavers and money-only rows; misconfigured or switched-off missions; the ladder's two lists; a database from before
    them brought forward by one boot), `missions_internal_test.go` (worker A completes, worker B waits on the row and grants 0;
    twelve racing transactions grant once), `game/missions_category_test.go` and `poker/missions_category_test.go` (the settle names
    the table's category), `app/tabletax_test.go` (First Win over a real socket and its `player:level`; `GET /api/levels`'
    `missions`). The daily tests in `levels_test.go` switch the missions off (`f.dailyXPOnly()`) to keep their exact totals.
  - **The Lucky Draw** (§7.3; 24 Sep 2026): `internal/db/luckydraw_test.go` on the seeded beginner draw (six prizes in wheel
    order, no weight on the wire; the first active draw in `sort_order` is the lobby's; every prize into its wallet, chips through the
    ledger; the empty slot pays nothing and starts the cooldown; a picture unlocked for its shop term and never put on; owned left
    alone, lapsed renewed; the cooldown kept by the server; one action id one spin, an 8-way burst included; unwinnable slots neither
    offered nor drawn; weight > 0; grant and record together or not at all; a deleted account cannot spin), `luckydraw_internal_test.go`
    (`pickWeighted` lays arbitrary weights end to end; 60,000 `crypto/rand` draws follow them), `internal/app/luckydraw_test.go` (the
    two routes on the real wiring: auth, a forged prize ignored, the replay, 409 with `readyAt`, 409 `seated` at a table). Flutter:
    `test/lucky_draw_test.dart` (the wire, the wheel geometry — the slot the server names is the slot under the needle —, the lobby key
    opens the screen, six prizes, the key quiet while a spin is out, the wheel stops on the server's slot, the prize, the countdown, and
    640x360 at x1.25 in all five languages).
  - **The reward programs** (§7.3; 30 Sep 2026): `internal/db/rewardprograms_test.go` (the brief's matrix on the seeded catalogue —
    `onlyPrograms` retires the rest; the first login, consecutive days, a missed day with and without reset, a duplicate, the week's
    and the month's end, February and a leap year, every reward type where its purchase would land, eight requests at once over two
    pools granting once, a repointed day keeping its snapshot, a Kolkata program dated in its own zone and week, a campaign's window,
    an empty day still counting, an unloadable zone left out, the four seeded programs), `rewardprograms_internal_test.go` (the period
    math — week start days, month lengths, 2000 and 2100, a New York week across DST is 167 hours —, `streakAt`, `calendarAt`, the
    claim key), `internal/app/rewardprograms_test.go` (the two routes on real wiring). Flutter: `test/reward_programs_test.dart`
    (§8.4).
  - Leftover schemas after a crash: `select nspname from pg_namespace where nspname like 'test_%'` (§4).
- **Parity harness** (`tools/parity/`, run with `cd tools && npm run parity`): black-box `node:test` suites — `game`, `money`
  (audits the books the profile wrote), `lobby`, `stakes`, `rest`, `protocol` (raw frames via `lib/csharpJsonPort.js`), `resume`,
  `invalid`, `metrics` — over real sockets against a server it spawns (`--target go` is the only target; default binary
  `../go-server/bin/gameplay`, `--bin` overrides) on a throwaway schema per **profile** (config is read once, so suites needing
  different timeouts get their own server process), or against a running server with `--url … --schema …`. `--filter a,b`,
  `--keep` (logs + schemas), `--serve [--profile main]`, `--verbose`. `npm run parity:diff -- --a go --b <url|go>` drives one fixed
  scenario against two servers and diffs the normalised recordings (uuids/codes/JWTs/timestamps/cards masked, consecutive
  identical `room:state` collapsed; `--out <dir>` keeps them). The Node target is gone — the last Node-vs-Go run was 141/141.
- **Parity and the table catalogue** (23 Sep 2026): `BASE_ENV` (`lib/launch.mjs`) names `TABLE_CONFIG_SOURCE=env`, so every
  profile but one plays its tables from the env keys (`LOBBY_TABLES=''` = any pair), as the server always composed them.
  The **`menu`** profile runs `TABLE_CONFIG_SOURCE=db` on its fresh schema — the SEEDED catalogue — while its env
  deliberately says `BOOT_AMOUNT=100`, 1.2 s clocks and a lifted menu: every exact assertion of the seed's figures in
  `stakes.test.js` and in `rest.test.js`'s `GET /api/tables` tests (a profile's `only` map runs just those, through
  `--test-name-pattern`) also proves the keys were ignored. `CONFIG_KEYS` (`lib/harness.mjs`) includes
  `tableConfigVersion`; `money.test.js`'s exact table list includes the four configuration tables. `parity-diff`,
  `chiptest.mjs` and `crashtest.mjs` name `env` for the same reason.
- **Parity profile `poker`** runs `tools/parity/poker.test.js` (60 s clocks, the default menu's poker entries): snapshot keys and
  redaction, the `wrong_game` wall both ways, Hold'em with the oracle (`lib/poker5.mjs`) checking every reveal and chips conserved,
  fold-to-one, Omaha's exactly-two rule, 5-Card Draw's exchange, 3-Card Poker's verdict against the dealer — and the `money` audit over
  those books (a 3-Card Poker hand is exempt from the per-hand zero-sum by its `variant`, §6.5). 7/7 + 8/8 on 19 Sep 2026.
- **Parity profiles `variation` and `variation-timeout`** run `tools/parity/variation.test.js` (each runs its own half and
  skips the other's — a profile is one server process with one window length) plus the `money` audit over the books those
  hands wrote. On macOS two `metrics.test.js` tests fail for reasons that predate this (`bind 127.0.0.2`, no
  `process_resident_memory_bytes`); proven against a HEAD build on 18 Sep 2026.
- **`tools/bot.js`** also takes `--category variation` and **`--variation <MUFLIS|AK47|JOKER|HUKAM|LOWEST_JOKER|HIGHEST_JOKER|FIVE_CARD|random|none>`**
  (default `random`, which picks from the `options` the SERVER sent, so FIVE_CARD is chosen only where it is offered): the
  chooser's pick, made once per table-and-hand from `room:state`; `none` never answers, which is how to watch the server's
  timeout choose Muflis. Bots never read their cards, so 5-Card needed nothing else. `variation.test.js` uses
  `tools/parity/lib/handrank.js` (the Node fleet's `bot-play/src/handrank.js` until bot-play went Go, 27 Sep 2026) as an
  INDEPENDENT oracle that a FIVE_CARD `best` really is the best of the ten
  combinations, and deep-scans every frame a client received for card codes that are not that player's own — keep both. The resident fleet (`bot-play/`, Go)
  reads `GET /api/tables` at start — the public `teen_patti` tables of `table.categories`, with their stack bands, no table
  hard-coded — and follows `session:ready.config.tableConfigVersion`: the first bot to meet a version it does not hold hands
  the fleet that session's menu and refreshes it once; a table refused `table_not_offered` is retired until the next read
  (`bot-play/internal/bot/table/finder.go`, `bot-play/README.md`).
- **`tools/bot.js`** also plays the poker rooms: `--category three_card_poker|five_card_draw|texas_holdem|omaha` answers
  `poker:yourTurn` from its `options` alone (`decidePoker`: check when free, call small bets, fold to a bet over a third of the stack half the time,
  open or min-raise now and then, play against the dealer three times in four, stand pat or exchange one or two) — bots never read
  their cards, so nothing else was needed.
- **`tools/bot.js`** (`npm run bot -- …`) flags: `--count --boot --category --url --offset --churn`. **16** fixed identities
  (Ravi Meera Arjun Kavya Vikram Anita Rohit Neha Priya Aman Sneha Karan Pooja Rahul Isha Dev; device id `practice-bot-<slot>-<name>`);
  groups use `--offset 0/4/8/12` — a second group **must** use `--offset`. Bots always `see`, ask sideshow 45%, answer 75/15/10
  accept/decline/lapse; retry `already_in_room` for 60s. `--url https://prod.sungamestudio.com` runs them against production.
- **`tools/ramptest.mjs`** (`npm run ramp -- …`) — staged capacity test: `--url --stages 10,25,…,1000 --hold 40 --boot 200
  --category blind --out ramp.json [--idOffset N for a second generator]`. Adds players in batches, holds each stage, records
  login/connect/action-ack latency percentiles, moves/s, hands/min, `/health` RTT, the server's `process` vital signs, and its own
  event-loop lag (generator-bound detector). Stops at p95 > 3000 ms, errors > 10 %, or < 90 % connected. Bots are guests
  `LoadBot<n>` (fixed device ids `ramp-bot-<n>-device-id`, so re-runs reuse accounts). Reports: **`docs/load-reports/`**
  (HTML + JSON; the 2026‑09‑08 production runs on the Node build: 1,000 players p95 40 ms no ceiling; the nginx
  `worker_connections` ceiling at ~1,500; 4,000 connected with 0 errors after the fix, p95 ~1 s on one Node core). On the
  12-core dev box, both servers local, the same ramp gave **Go 4,000 players at ack p95 5 ms vs Node 255 ms** (no report file
  committed for that run yet).
- `GET /health` returns `{ok, uptime, tables, players, activeHands, sockets, process:{pid,node,rssMb,heapUsedMb,heapTotalMb,
  externalMb,cpuPercent (share of one core since the previous call), loopLagP50Ms/P99Ms/MaxMs, goroutines, numCpu, gomaxprocs},
  db:{total,idle,waiting}, live:{kind,ok,tables}, version, tableConfig:{source, version, fallback}}` (the last since
  23 Sep 2026, §7.2). **`version`** is the go-server release tag `ops/build.sh` stamped in
  (`v1.0.1`, or `v1.0.1-3-gabc1234` past a tag, `dev` for a plain `go build`) — the answer to "which build is prod on?"
  without an ssh, which is what `ops/prod-version.sh` reads. Under Go `process.node` is the runtime string (`go1.27.1`), `loopLag*` are scheduler-latency
  percentiles, `externalMb` is 0, `db.waiting` an acquire-wait delta (usually 0).
- The Node scratch scripts (`kicktest.mjs`, `peek-tmp.mjs`) and `test/loadtest.js` went with `server/`; `npm run ramp` covers the
  load-test role, `tools/parity/money.test.js` the books audit.

---

## 8. Flutter client (`flutter-client/lib`)

### 8.1 Shape
- **No Navigator.** `_Root` switches Login/Lobby/Table on `GameState.screen`; the server drives it
  (`room:state` → table; `room:left/closed/kicked` → lobby). `PopScope(canPop:false)` everywhere.
- Landscape only, immersive sticky.
- **One `ChangeNotifier`** — `GameState` — with a `Timer.periodic(1s, notifyListeners)` for the
  countdowns (the rewards' until 30 Sep 2026; the Lucky Draw's, rentals, grace clocks). **Any `context.watch<GameState>()` rebuilds every second.**
- `GameConnection`: websocket-only Socket.IO; broadcast `Stream`s; every emit via `emitWithAck`; a
  refusal is `{ok:false, message}` → `notice`. `request()` awaits an ack with an 8s timeout.
  **Every `act()` sends a fresh `actionId` (uuid v4)** for server-side idempotency. The `room:moved`
  `j['state']` branch is dead code (server sends no `state` there). **`connect()` builds with `enableForceNew()`**
  (24 Sep 2026, owner's "fix all bugs"; B7): without it `socket_io_client` handed every later session the Socket it
  cached on the first connect and reconnected it with the FIRST token (§12.3) — after a sign-out the next account's
  socket signed in as the previous one, and after Delete account it presented the deleted account's token
  (`connect_error unknown_user` → "Service not available" over the new guest's consent panel, and no socket at all).
  A `connect_error` from a socket that is no longer `_socket` is dropped. `test/connection_session_test.dart`.
- DTOs (`dtos.dart`): `const` classes + tolerant `fromJson`; server enums as `static const String`
  classes; `Seat.chips` **nullable** (null = withheld, never 0).
- SharedPreferences: `deviceId`, `token`, `themeMode` (`system|dark|light`, `state/theme_preference.dart`;
  the old `darkMode` bool is read once when `themeMode` is absent and never written again), `lang`,
  `numbers`, `noWinningsAck:<userId>`, `soundOn`/`vibrateOn` (`settings/feedback_settings.dart`), `quickMessageOrder` and
  `quickCustomMessages` (25 Sep 2026, the player's order of the quick messages and their own lines, §8.4), and since 23 Sep
  2026 **`tableConfig`** — the phone's copy of `GET /api/tables`. **None of the app's data is backed up or carried to
  another phone** (24 Sep 2026, owner's "fix all bugs"; RC-07): `token` is a 30-day JWT and `deviceId` IS a guest's
  account (guest id = sha256('teenpatti:'+deviceId)), and a device-to-device transfer left two phones signed in as one
  player. `android:allowBackup="false"` plus `dataExtractionRules` (`res/xml/data_extraction_rules.xml`, every domain
  excluded from cloud-backup and device-transfer — Android 12+ ignores allowBackup for D2D). The price: a guest who
  reinstalls starts a new account; Google sign-in keeps one.
- **Play purchases** (`net/purchases.dart`, 24 Sep 2026, owner's "fix all bugs"; RC-03): bought with
  `buyConsumable(autoConsume: false)` and CONSUMED (`InAppPurchaseAndroidPlatformAddition.consumePurchase`) only after
  `POST /api/purchases/google` has banked it — the plugin's default consumed a pack the moment Play reported it, before
  the app or the server had seen it, so a credit that failed on the network was lost for good (Play never re-delivers a
  consumed purchase). `Purchases.redeliver()` lists Play's OWNED purchases (`queryPastPurchases`, not
  `restorePurchases`, which marks a pending purchase `restored` and drops the whole list when the subs query fails) and
  posts each paid one again; GameState calls it on every `session:ready` (cold start, sign-in, reconnect). The server is
  idempotent on the token (`gplay:<token>`). A refusal finishes the purchase only when it is a verdict on the receipt
  (`receiptRefusalIsFinal`: 400, 402); 401/403/408/429/5xx keep it owned for the next session. In-flight and finished
  tokens are de-duplicated. A consume that fails acknowledges instead (the server acknowledges on credit too).
  `test/purchases_consume_test.dart`.
- **The table catalogue on the phone** (owner, 23 Sep 2026: "the UI fetches it, stores it on the phone, and re-fetches it
  at every login"; `state/table_config_cache.dart`). `TableConfigCache` keeps ONE entry under `tableConfig`:
  `{"schema":1, "version", "fetchedAt", "body"}`, `body` being the server's JSON exactly as it came (a later build can
  read keys this one does not know). An entry that is corrupt, of another `schema`, or whose version does not match its
  body is discarded, never half-read; a body that is not a usable catalogue (`GameConfig.fromCatalogue`: a non-empty
  string `version`, `tables` and `privateTables` lists of objects, `maxPlayers` > 0) is never written, so a broken
  answer cannot replace a good copy. It is the SERVER's menu, not the player's, so it survives sign-out and account
  deletion. **When**: a cold start applies the copy right after the preferences load, before the socket is wired
  (`restoreCachedMenu`), so the first lobby frame is the menu this server last described, not `GameConfig.fallback`;
  every sign-in — a restored session after `me()`, guest, Google — starts `_loadTableConfig()` (unawaited, one in flight
  at a time, errors swallowed: offline keeps the menu on screen and the next sign-in asks again), which sends the held
  version as `If-None-Match` (a 304 re-applies the held copy; a 404 is an older server, and the copy is left alone).
  **Which menu wins** is `MenuPrecedence`, a pure function (`test/table_config_menu_test.dart`): a `session:ready` with
  NO `tableConfigVersion` is a server that predates the catalogue — its config is the menu exactly as before, nothing
  is fetched; a version EQUAL to the catalogue held keeps the catalogue and takes only `minClientBuild` from the
  session (session-scoped, never cached, never lifted by a menu swap); a DIFFERENT version shows the session's menu
  and fetches (once the build floor has let this build through); a catalogue that arrives is shown only when no session
  has named a version yet or it is the version the latest one named — otherwise it is late, kept, not shown. Every menu
  write goes through ONE `GameState._applyMenu`, which also steps the lobby back a level when the menu no longer offers
  the engine or category on screen. `GameConnection` passes `config: null` (not `GameConfig.fallback`) when
  `session:ready` has no config, and the menu already held stays. The server stays authoritative: a stale copy can
  only mis-draw a card for a moment — every door is checked again server-side. The richer per-table figures are used
  where they exist: the table info dialog's turn time (a poker room's own clock, which it used to show as the Teen
  Patti one) and `table_screen`'s blind-move dots — `GameConfig.entryFor` tries a PRIVATE room's template in
  `privateTables` by category first, then the public entry of the pair, then 4. Seats are still laid out from the one
  global `config.maxPlayers`.
- **The app's lifecycle** (owner, 27 Sep 2026: "a locked or backgrounded phone keeps its way back";
  `GameState.handleLifecycle`, fed by one `AppLifecycleListener` in `main.dart`). Until then the app ignored it: a
  phone locked at a table kept its socket, the server saw a CONNECTED player who never moved, and three turn clocks
  later (~83 s) idle-kicked them with no resume offer, the `room:kicked` going to a phone that was not listening.
  Now `paused` while seated (`room != null`, signed in) arms `GameState.backgroundGrace` (**8 s**); when it runs
  out the socket is closed (`_conn.disconnect()`, `offline = true` for the reconnecting veil, the table left on
  screen), which starts the server's reconnect grace at once. `resumed` cancels the timer, or — the socket having
  been closed — connects again with the session's token, and the warm `session:ready` does the rest: the held
  seat's `room:joined`, or the resume offer taken with `room:joinCode` (§7.1: after the grace, or after an idle
  kick while disconnected), or neither and the seat check sends the player to the lobby with `tableLost`.
  `inactive` (a shade, a system dialog, the app switcher) and `hidden` do nothing; the lobby does nothing. **The
  delay** spares a quick trip out of the app — Play's purchase sheet, Google sign-in, the privacy page, a support
  e-mail — a reconnect; nothing is lost either way (the held seat or the offer brings the player back), and 8 s
  is under a third of a turn clock. **A purchase in flight** (`purchaseInFlight`: Play's sheet open —
  `Purchases.buying`, from `buy()` until Play reports anything but pending, 10 min at most — or Play's in-app update)
  keeps the socket up; the check runs again every 8 s and closes it once the purchase is over. A purchase Play reports
  as PENDING (`purchasePending`, a slow payment such as UPI) does NOT count: it can stay pending for days or be
  abandoned and never reported again, and counting it held a seated phone's socket open for the rest of the session —
  the idle kick with no way back again (the verifier's finding, 27 Sep 2026); its receipt is banked over REST, which
  needs no socket. A purchase sheet Play refuses to open (`buyConsumable` answers false, without a throw, and nothing
  ever arrives on the stream) is not counted as open, and is reported as a failed purchase in the player's language
  (`Purchases.notLaunched` → `Strings.purchaseNotLaunched`; `test/purchases_consume_test.dart`).
  `test/app_lifecycle_test.dart`.
- **A disabled account** (owner, 26 Sep 2026; server side §7.2): every door answers `account_disabled`
  (`accountDisabledCode`, `net/api_client.dart`), and the app turns it into ONE popup wherever it arrives —
  `ApiClient.onAccountDisabled` fires from `_decode` for the login, a cold start's `me()` and any signed-in request;
  `GameConnection` passes the handshake's `connect_error {message: account_disabled}` and a table's refusal on as
  that code. `GameState._accountWasDisabled` signs out (the token goes; the DEVICE ID STAYS, so a guest cannot sign
  straight into a fresh account) and raises `accountDisabled`; on a cold start it leaves the splash to finish. The sign-in
  screen then shows `AccountDisabledDialog` ("Account disabled", "Your account is disabled. Please contact support.",
  `ServerConfig.supportEmail` support@sungamestudio.com selectable, Close) once, and `dismissAccountDisabled` clears
  it; the sign-in flows write no error line for that code. `test/account_disabled_test.dart` (the hook, the guest
  sign-in, the popup, 640x360 x1.25 in all five languages).
- **Signed in on another device** (owner, 28 Sep 2026; server side §7.1/§7.2 "One signed-in device"): `session_replaced`
  (`sessionReplacedCode`, `net/api_client.dart`) reaches the app three ways — a REST 401 (`ApiClient.onSessionReplaced`, fired
  from `_decode` with the token the refused request carried, read off `response.request`'s `Authorization`, so a late answer
  about a token this phone has already signed in past is dropped), the handshake's `connect_error`, and the `session:replaced`
  push that ends a live connection (`GameConnection`, from the CURRENT socket only; it used to be a toast, "Signed in from another
  device", and the phone kept its token — backgrounded and back, it reconnected and took the seat back). `GameState
  ._sessionWasReplaced` signs out (the token goes, so nothing reconnects on it; the device id stays) and raises
  `sessionReplaced`; on a cold start the splash finishes first, as for a disabled account; with nobody signed in it does
  nothing. The sign-in screen shows `SessionReplacedDialog` ("Signed in on another device" — someone signed in to the account on
  another device, so this one was signed out; signing in again here signs the other out) once; `dismissSessionReplaced`. main.dart's
  `_TableRoutes` now also closes every route over the lobby or the table when the screen goes to the sign-in screen from either — a
  picture sheet open when the push landed stood over the sign-in screen, emptied. The new device lands on the live table through
  the ordinary `room:joined` (behind the no-winnings panel where that account has not confirmed on that phone). Two strings in all
  five languages. `test/session_replaced_test.dart` (the hook and its token, the push at a table, a cold start, a late 401 about an
  older token, a stray word with nobody signed in, the sheet closed under the popup, the popup at 640x360 ×1.25 in all five
  languages). Played on TP_Tall and the Play emulator against a local server: one account on both, the first seated mid-hand;
  the second's sign-in put the popup on the first and the live hand on the second; and a Google account signed in again elsewhere.
- **No-winnings confirmation** (`state/consent.dart`, `_ConsentGate` in `main.dart`, added 11 Sep 2026):
  after sign-in (either door, or a restored session) the lobby/table is covered by a panel — "I confirm
  that I do not have any expectations of winning any monetary or other enrichment from playing this
  game." — until the player taps *I confirm*. `GameState.consentPending` gates it; `loadConsent()` runs
  at every session start, `acceptConsent()` writes `noWinningsAck:<userId>` so that **account** is never
  asked again on that device (quit, relaunch, resume included). Keyed per account, not per device: a
  second account on the same phone is asked once for itself. Client-only, nothing goes to the server.
  Not shown over the update screen. Back while it is up = the usual quit question. `test/consent_test.dart`.
- **The welcome rewards popup** (30 Sep 2026; server §7.2/§7.3): a new account's login carries `welcome` (`WelcomeGrant`, `dtos.dart`;
  `ApiClient.loginGuest`/`loginProvider`), which the two login doors leave in **`GameState.welcomePending`** (`_welcomeGranted`: the
  block, or an older server's `welcomeChips` alone, or a grant of nothing — a returning account never has one). **A new account meets
  three things in a fixed order** (owner, the same day: "WHen user login with new account it should show first consent pop up "before
  you play", then after show pop up Welcome Rewards which user must select confirm otherwise not able to proceed then Weekly Login pop
  up"): the no-winnings statement, then this popup, then the weekly login popup. `widgets/welcome_rewards.dart` `WelcomeRewardsPanel` is
  the consent gate's twin — a layer in main.dart's root Stack right after it (`welcome-rewards`, shown while `welcomePending` stands,
  `consentPending` is false and the screen is the lobby or a table), never a route: a tap outside does nothing (the scrim is an opaque
  `ColoredBox`), Back offers to quit as under the statement (`_BackGuard` skips the click and `closeLobbyLevel` while it is up), and the
  one way on is its **Confirm** key (`welcome-rewards-confirm` → `GameState.confirmWelcome`, which clears the grant and offers the weekly
  login; `offerWeeklyLogin` answers false while a welcome waits, as it does while consent is pending). The card: a gift mark and "Welcome
  rewards", "Added to your account:" (or "Welcome to King Teen Patti!" for a grant of nothing), one row a reward (`prizesOf`: chips,
  diamonds, hammers, missiles, then each picture, table picture and emoji by name, as `RewardPrize`s drawn with the reward programs'
  `rewardPrizeLabel`/`rewardPrizeIcon`/`rewardPrizeInk` — "5 Lakh chips", "Lovestruck Cat picture"; the wallet rows two to a line on a
  card `twoUpFrom` 300dp or wider when there are more than three rows, an item's row always the whole width, since "Circle Background
  Pattern table picture" is cut in half a card at ×1.25), the rows one Semantics node whose label is `welcomeNotice`'s line. It scrolls
  as the consent panel does. `welcomeNotice` (`game_state.dart`) — "Welcome! Added to your account: 10 Lakh chips · 9 diamonds · 20
  hammers · 1 missile · 1 picture · 1 emoji", singular and plural right (the wallet words are `priceIn`/`countMissiles`'), the plain
  welcome for nothing, the chips alone from an older server — was the sign-in's toast until the popup took its place the same day and
  is now what a screen reader hears of the list. Sign-out and account deletion forget a grant not yet confirmed. Three strings in all
  five languages (`welcomeRewardsTitle`, `welcomeRewardsLead`, `welcomeConfirm`). The picture and table-picture catalogue loaders drop
  an answer made under another token (as the emoji loader did), so a cold start's anonymous read landing late can no longer show a
  granted picture locked. `test/welcome_grant_test.dart` (the grant's reading and summary; the sign-in leaving it for the popup, nothing
  for a returning account, sign-out forgetting it), `test/welcome_rewards_test.dart` (the rows in the summary's order; the strings; the
  card in Hindi; the layout; nothing for nothing; the ORDER in the app as main.dart builds it — the statement, then the popup, a tap
  outside and Back doing nothing to it, Confirm, then the weekly login, and no claim by any of it; a returning account; the state's
  offer; 640x360 and 592x360 ×1.25 in all five languages and both themes, no word cut, Confirm reachable).
- **The reward programs on the phone** (30 Sep 2026; server §7.2/§7.3; the popup, the chip, the screen and the celebration §8.4).
  `GameState.loadRewardPrograms()` GETs `/api/reward-programs` whenever the lobby appears (`_RewardsChip`'s first build, once the
  resume veil is down), at every `session:ready` in the lobby (`_wire`) and when the rewards screen opens — never at a table — and
  keeps the answer as `rewardPrograms` (`RewardProgramState` in `dtos.dart`); then `offerWeeklyLogin()` puts the weekly login popup
  up (`weeklyLoginOffer`) when a WEEKLY login streak's today is still to collect and that day has not been offered this session
  (`_weeklyOfferedFor`, `<code>:<today>`; the chip's tap offers it `again`). **Nothing is claimed by itself** (owner: "if user has
  claimed it should not show when user start the app, otherwise show it" — the claim is the player's tap):
  `claimRewardPrograms({celebrate})` POSTs `/api/reward-programs/claim` on the popup's Collect (`celebrate: false` — the popup shows
  what was given) or the screen's (the lobby's celebration then shows `rewardsGranted`), answers the grants, takes the answer's
  `programs` and `user` (the wallet after), re-reads the catalogues when an item was won (`_loadPictures`), and is refused at a table
  (`room != null`; the server would answer 409 `seated`). A 404 or 503 (an older server, none running) leaves `rewardPrograms` null and
  is no failure; a lost network is one only while nothing is held (`rewardProgramsFailed`; Try again → `loadRewardPrograms()`); an
  answer to a session that has ended is dropped; sign-out and deletion forget everything, the popup included.
  `test/reward_programs_test.dart`, `test/weekly_login_test.dart`.
- **The app version gate** (owner, 28 Sep 2026; server side §7.1/§7.2 "The app version gate"; `net/app_version.dart`). The app
  **declares itself** — `appPlatformName()` (`android` | `ios` from `defaultTargetPlatform`, null elsewhere) and pubspec's version
  from `package_info_plus` (read and AWAITED at start, 2 s bound — it used to be fire-and-forget) — as `X-App-Platform` /
  `X-App-Version` on every `_headers()` request (`ApiClient.appPlatform/appVersion`) and as `appPlatform`/`appVersion` in the
  handshake's auth (`GameConnection.appPlatform/appVersion`): **both or neither** — a build that cannot read its own version declares
  nothing, rather than an app platform with no version, which a server with a minimum must refuse. **No minimum lives in the app.**
  **At start** (`GameState.start`, behind the splash), BEFORE the saved session is restored: `GET /api/app-config`
  (`ApiClient.appConfig`, 12 s, public) → `evaluateAppConfig` — the server's own verdict and the app's reading of its platform's row
  with the one Dart `SemVer`, **the stricter wins** — then FORCE_UPDATE → `Screen.update`, MAINTENANCE → `Screen.maintenance`, and
  neither the session nor the socket is touched (the token is KEPT); else `_restoreSession` as before, and a SOFT_UPDATE offered once
  the app is up. Unreachable (offline, slow, refused) → exactly the old behaviour; a 404 (a server that predates the gate) → NORMAL,
  its `minClientBuild` floor still in force. **Later** (`_appGateRefused`), every "must update" path comes to the SAME screens: a REST
  426 / 503 from any request (`ApiClient.onAppGate`, fired from `_decode` before `AppGateRefusal` — an `ApiException` — is thrown), the
  handshake's `connect_error update_required | maintenance` (`GameConnection.onAppGate`; the connection lets its socket go itself —
  `scheduleMicrotask(socket.dispose)` — and emits no `onError`), and the legacy `session:ready.minClientBuild` floor (`_forceUpdate`).
  It lets the socket go, cancels the background-return reconnect (`_closedForBackground`), the seat check and the resume veil, clears the
  table, and **keeps the token**: nothing reconnects — not the lifecycle's resume, not a seat check — until the update, or Try again. A
  network failure is still retried by socket_io_client exactly as before. **Force Update** (`screens/update_screen.dart` `UpdateScreen`,
  the old update screen restyled, same frame — `LobbyGround`, `DriftingChips`, `PremiumSurface`, `SpinningChip`): "Update required", the
  operator's message or `updateBody`, **Update now** (`GameState.startUpdate`: Play's in-place flow when Play reported one, else the
  store link the SERVER named for this platform — `openStoreUrl`, url_launcher external — and only when it named none the old
  `storeListingUris()` pair; nothing opened → toast `updateStoreUnavailable`), "Your version 1.4.2 · Required 1.5.0". **No Later, no
  Skip, no way past.** **Maintenance** (`MaintenanceScreen`, same frame, a construction mark): "Under maintenance", the server's message
  or `maintenanceBody`, **Try again** (`retryAppGate`: re-asks; open again → back where the player was, a saved session to the lobby and
  its table; still closed or now too old → that screen; unreachable → it stays with `serviceUnavailable`). **Soft Update**
  (`SoftUpdatePrompt`, a layer in main.dart's root stack above the consent panel, the consent panel's shape — `softUpdateShown`: only
  over the sign-in screen or the lobby, never a table, not under the resume veil): "New version available", **Update now** / **Later**;
  Later (`laterSoftUpdate`) writes the announcement to SharedPreferences **`softUpdateLater`** (`SoftUpdateMemory`: `latest:<version>`
  or `play:<installed>`) and it is not asked again until something newer is announced. **Play's own "newer build" report
  (`AppUpdate`), which used to put up the blocking update screen, is now this nudge**: only the server's minimum blocks (the lead's call —
  "don't let it fight the new screens"). Eleven keys in all five languages (the update title/body reworded to the brief's). Tests:
  `test/app_version_test.dart` (the semver cases, the stricter-wins reading, the refusals, the headers), `app_gate_test.dart` (the brief's
  Flutter tests on GameState: a supported build enters declaring itself; FORCE_UPDATE stands before sign-in, keeps the token, has no
  Later; Update now opens Play on Android and the App Store on iOS, a store that will not open is a toast; SOFT_UPDATE and Later once
  per announcement; MAINTENANCE with its message and Try again; a mid-session handshake refusal and a REST 426 to the same screen with no
  reconnect; offline as before; the legacy floor), `app_gate_socket_test.dart` (the real socket_io_client against an in-process
  Engine.IO server: one knock after `update_required`, a network drop still retried, the app's lifecycle reconnecting nothing),
  `app_gate_screens_test.dart` (the three surfaces at 640x360 x1.25 in five languages, both themes), and the harness
  `test/app_gate_shots.dart` (run by hand; it borrows the Mac's own Indic fonts when the Noto ones are absent).

- **No server, no toast** (owner, 28 Sep 2026: "when app shows service not available, it shows loader screen until it
  gets connected"). `GameState.serviceDown` is raised by a handshake that got no answer (`GameConnection.unreachable`: a
  connect_error that is not the server's `{message: code}`), by any notice that says the server could not be reached (main.dart
  `_saysUnreachable`, the filter that used to turn such a notice into the "Service not available" toast), by the maintenance
  screen's Try again with no server, and by a start whose `me()` got no answer (the network, a timeout, a 5xx) — which now KEEPS
  the token and waits (`_whenReachable`), where it used to drop it and sign the player out over a network blip. While it is up
  `_ServiceVeil` (main.dart, above every other layer) shows the game's loader — "Please wait..." over "Connection lost.
  Reconnecting…" — and `GET /api/app-config` is asked every `GameState.serviceProbeEvery` (3 s); the veil comes down when the
  socket connects or, with no socket expected, when the server answers (a maintenance screen then asks again). A handshake the
  server REFUSED (`GameConnection.refused`: an expired or revoked token, or one another server issued) is no outage — that
  session could wait for ever — and signs out to the sign-in screen, as a start with such a token does. The sign-in screen keeps
  its own error line. `test/service_down_test.dart`; `app_gate_test` 7 expects the loader. Played on TP_API36: the demo server
  stopped put the veil up within seconds, and restarted, brought the lobby back on the same session.

### 8.2 GameState essentials
New hand = `handNo` changed → clears celebration/sideshow reveal, resets `raiseIndex`. **The
celebration has its own timer** (`nextHandAt`, 6s fallback) — it used to clear only on the next deal,
which stranded a lone winner behind the banner forever. `switching` suppresses `onLeft` during
`room:switch`. `bet()` sends `chaal` when amount == `raiseSteps.first`, else `raise`.
`createPrivate()` sends category **seen** (the browser sends **blind**) — a private table's chip
visibility depends on which client created it.

### 8.3 Money formatting (req. 34)
`formatChips(int)` reads two **module-level globals** `chipNumberSystem` / `chipUnits`, written only
by `GameState._publishNumberFormat()`. Abbreviate only `> 100000`; Indian `3.24 Lakh`/`2.5 Crore`/`32.77 Crore`
(2dp, rounded, trailing zeros trimmed); international keeps digits below 1,000,000 then `1.2 Million`. Tests reset the globals
in `tearDown`. `_sampleIn()` mutates the global to preview — don't interleave.

### 8.4 UI
- **The game's loader** (owner, 28 Sep 2026: "change the loader of game … use this lottie json … whereever loader you are
  showing show this loader, and below text also please wait..."; `widgets/game_loader.dart`): the owner's
  `assets/animations/GameLoader.json` (540×540, 2.2 s, a teal arc chasing a dark one round a ring; no 3D, expressions or
  images) in place of every Material spinner the app drew — `test/game_loader_test.dart` holds `lib/` to none. **`GameLoader`**,
  the ring over "Please wait..." (`pleaseWait`, all five languages) and, where the screen named what it waits for, that line
  under it (the reconnecting plate, the switching veil, the resume veil, the service veil), stands wherever content is still
  coming: a table or poker room not yet received, the Friends page, the Lucky Draw, the level screen and the tax popup before
  the ladder, the player and own-seat drawers, a store shelf, a paged list's next page. Inside a key or over a tile being
  bought, where a line of words cannot fit (Play as Guest, Update now / Try again, the drawer keys, Accept, the price keys, the
  spin key, a picture or emoji being bought, the name field, Switch table), **`GameLoaderRing`** alone, in the old spinner's
  box. The file's black arc is drawn in the theme's ink (or the key's) by a `ValueDelegate` — black vanished on the dark theme
  — and the file is never edited; the ring fills its box (`gameLoaderRingShare`: the ring's 196 of the canvas's 540 units,
  the rest drawn past the box through an `OverflowBox`).
- **The version gate's three surfaces** (28 Sep 2026; the flow is §8.1 "The app version gate"): `Screen.update` (Force Update) and
  `Screen.maintenance` share ONE frame, `_GatePanel` in `screens/update_screen.dart` — the update screen's own since before the gate:
  the room's ground and drifting chips, one solid gold-edged `PremiumSurface` (solid, not glass: the chips drift behind it), a mark
  (the `SpinningChip`; a construction glyph in a gold disc for maintenance), the title in `headlineSmall`, the body in `bodyMedium`, one
  full-width primary `GlassButton` (Update now / Try again, a spinner while it works) and a tabular footnote (the versions, or the
  build); it scrolls, so three lines of Bengali at x1.25 on a 360dp phone never overflow. The Soft Update prompt is the consent panel's
  shape (a 0.72 ground tint, one `GlassCard` taking the blur lease) with Later as a text key beside a primary Update now. No new colours
  or type: `test/app_gate_screens_test.dart`, `test/app_gate_shots.dart`.
- **Teen Patti only, by default, since 27 Sep 2026** (owner: "do this change in UI only, remove poker category and In UI
  only show three cards seen, blind, variation"). ONE build-time switch, `AppFeatures.poker` (`lib/config/features.dart`,
  `--dart-define=SHOW_POKER=true`, off by default; a mutable static only so tests can flip it). Off, the lobby leaves every
  table of a hidden engine out of everything it reads (`GameState.lobbyShowsEngine`: its engine list, category lists, table
  lists and a group card's counts), and where exactly one engine is left to show it skips the engine level
  (`GameState.lobbyFrontEngine`): the FRONT is Seen, Blind, Variation (the categories with a table, in the usual order) then
  `_PrivateCard`; a category's tables stand behind a `_BackTile` saying `backToCategories` ("All games"), and Back — the tile
  or `_BackGuard` → `closeLobbyLevel` — returns to the front in one step, then answers false (the quit question). The
  record's switch (`PlayerStatsGrid`, `statsViews()`) is All · Teen Patti · Variation — three across where they fit, else All
  across the top over the two games — and the general rules sheet drops its poker section. **Server-side nothing changed**:
  poker tables are still in `session:ready.config.tables` and `GET /api/tables`, `TableConfigCache` keeps the body verbatim,
  All still counts poker hands, and the poker felt, DTOs and refusal texts stay built in. The lobby offers no way into a poker
  room, but a player can still meet two poker things, deliberately: a seat still held at a poker room, or one lapsed within
  `RESUME_OFFER_MS` (`session:ready.resume` → `joinByCode`), from an older build that showed Poker still opens the poker felt —
  their chips are at that table; and a friend playing poker on another build (the store's 1.2.x included) shows as
  "Poker • Texas Hold'em" on the Friends page — where that friend really is. The front and a category's tables are sized
  together (`lobbyRailSide`'s `also`: each stops cleanly at the other's side), so opening Blind does not shrink the cards; on
  a 640dp phone the private card, now the fourth, starts just past the edge. With `SHOW_POKER=true` everything below is
  exactly as it was.
  `test/lobby_teen_patti_only_test.dart`; the engine/poker suites set the switch on in `setUp`.
- **Lobby — three levels since 23 Sep 2026: engines → categories → tables** (owner: "IN UI also give two cards: Teen
  Patti and Poker. inside TeenPatti give seen, blind and variation. Inside poker give three card poker, five card draw,
  texas holdem, omaha"). The FRONT is one `_EngineCard` per engine the server offers a table in (`GameState.lobbyEngines`:
  Teen Patti, gold; Poker, teal) and `_PrivateCard` last; inside an engine, a `_BackTile` ("All games") then one
  `_CategoryCard` per category of it (`lobbyCategoriesIn(engine)`); inside a category, a `_BackTile` naming the engine
  it returns to, then that category's `_TableCard`s (`lobbyTablesIn(category, engine:)`). Engine and category cards are
  both a `_GroupCard` (the text below about the category card holds for both; an engine card's key says "View games").
  **An engine card's coin is `assets/animations/Poker Chip Shuffle.json`** (owner, 23 Sep 2026: "use this animation on
  teenPatti and Poker card … change coin colour accord to the card coin u have, but animation should be same"):
  `widgets/chip_shuffle.dart` `ChipShuffle`, a 2 s / 60 fps loop of twelve copies of one red chip, recoloured at RUNTIME
  by ValueDelegates (the file is never edited or baked) — the five red body shades take the card's own coin shades
  (`poker_chip.dart` `chipBodyShades`, so it cannot drift from the static coin), the white/grey inlays take champagne
  (`AppTheme.goldBright`) scaled by lightness; two layers use a MULTIPLY blend (the spots are set to coin ÷ champagne so
  they show the coin exactly; the neutral shadow layer is left alone). Category and table cards keep the static coin.
  Decoded once for the app, inside a RepaintBoundary, and the one-second lobby tick never restarts it
  (`test/chip_shuffle_test.dart` pins the file's layers, the recolour and the no-restart rule).
  **The grouping is data-driven**: a table's engine is `LobbyTable.engine` from the catalogue (`GameState.lobbyEngineOf`),
  else — `session:ready`, an older server — a poker category is Poker's and everything else Teen Patti's; the order of
  engines and of each engine's categories is `GameConfig.engines`' `sortOrder` when present, else the built-in
  `GameState.lobbyTaxonomy` (Seen, Blind, Variation; 3-Card Poker, 5-Card Draw, Texas Hold'em, Omaha — the seed's own
  taxonomy, so the lobby looks the same from either source). Names are the client's five-language strings (`teenPatti`,
  `poker`, the category names); the database's `name` is shown only for an engine or category code this build has never
  heard of, which then gets a card of its own (`lobbyEngineServerName`/`lobbyServerName`). `GameState.lobbyEngine` and
  `lobbyCategory` (never a category without its engine) replace the old single field; `_BackGuard` closes one level at a
  time (`closeLobbyLevel`), sign-out returns to the front, the rail is keyed `lobby-rail:<engine>[:<category>]`.
  `test/table_engines_test.dart`. What follows describes the two-level lobby of 18 Sep 2026 whose inner levels these
  are: **two levels in one rail** (owner, 18 Sep 2026: "in lobby give 3 category — Seen, Blind, Variation — and
  when the user selects Blind go into that and show all the Blind table cards"). The FRONT was one `_CategoryCard` per
  category the server offers a table in (`GameState.lobbyCategories`, always Seen · Blind · Variation; an unknown
  category is filed under Seen) and `_PrivateCard` last; a category card is the table card's own frosted square in the
  category's colour (`_categoryPalette`) stating its blurb, boot range ("200 – 10 Lakh"), table count and how many are
  **open to you**, under a "View tables" capsule, and is never padlocked — its tables are where the padlocks are. **The
  "open to you" row's mark is the owner's `assets/animations/Lock.json`** (29 Sep 2026: "use this lock animation on lobby
  card instead of using lock icons in front of text 'open to you'. Make sure it look visible in dark and night mode";
  `widgets/open_lock.dart` `OpenLock`, handed to `_CardFact.glyph`): a white padlock breathing on a blue disc (#2987FF),
  210 units square, 3 s a loop, no 3D, expressions or images, played in its OWN colours — the blue stands 4.7:1 on the
  night card and 3.5:1 on the day card, the white lock 3.5:1 on the blue (`test/open_lock_test.dart`). Its disc fills the
  icon's box (`openLockDiscShare` 100/210, the canvas drawn past the box through an `OverflowBox`); still and faded
  (`quietOpacity` 0.45) when no table is open, as the "0" is said quietly; memoised as `ChipShuffle` is, so the tick never
  touches it, with `RenderCache.drawingCommands` and the old icon as its fallback. **Every table card's "Entry" row carries
  the owner's `assets/animations/Wallet.json`** the same way (the same day: "The Entry icon on table card use this
  animation"; `widgets/entry_wallet.dart` `EntryWallet`): a blue wallet, gradient back and frosted front with a clasp,
  fanning open and shut twice in a 2 s loop, 1080 units square, no 3D, expressions or images, in its own colours — the
  back's deep blue (#4088F4) 4.4:1 on the night card and 3.5:1 on the day card, the frosted front lighter by design. Its
  rest pose (620 units wide, centred at 581,595) fills the icon's box; fanned open it reaches a quarter of the box past
  its left edge and an eighth past its foot, into the card's margin. Still (not faded — the card's 0.42 is the quiet) on
  a table the player cannot sit at. **The "Pot limit" row carries the owner's `assets/animations/Piggy Bank.json`** (the
  same day: "use this for piggy bank for card icon"; `widgets/pot_piggy.dart` `PotPiggy`): a pale blue piggy bank on a
  round near-white ground, coins dropping in, a 1 s loop, 500 units square; the ground (layer `I`, a 396-unit circle)
  fills the box, still on a shut table. By day its pale blues vanish into the white card (1.1:1, 1.4:1), so by day ALONE
  the ground is drawn in the lock's blue (`potPiggyDayGround` #2987FF, 3.5:1; the pig on it 2.5:1). **All three marks
  take their card's colour** (the same day: "change the wallet color and lock and piggy bank animation color acc to
  card, yellow, blue, purple, but keep the animation"): `FactMark.tint` = the card's `palette.accent` (Seen gold, Blind
  sapphire, Variation violet; an engine card's own), laid on every coloured part of the file by `tintAt` — the accent's
  hue and saturation at the part's OWN luminance, whites and greys untouched — so every contrast figure above holds in
  every colour and a gold is a deep gold, never a yellow lost on the white card. Colours and strokes through `['**']`
  colour callbacks; the wallet's gradients from its recorded stops (`entryWalletGradient`: a gradient's colour callback is
  handed an empty list, and a list of the wrong length throws in paint); the piggy's day ground after them, so it wins.
  The delegates are made once per art, colour and brightness and kept (`_delegatesFor`): the render cache keys on a
  callback's identity, so cards of one colour share frames and another colour never replays them. **Every table card's
  rules key (the book under ⓘ) plays the owner's `assets/animations/Rule Book.json`** (the same day: "use this icon for
  rule book on card"; `widgets/rule_book.dart` `RuleBook`, `_CardCornerKey.glyph`): a black-outlined book hopping and
  flicking its pages over its shadow, 2 s, 500 units square, in the card's colour like the other three (outline and pages
  as drawn); its whole loop (76–423 × 7–441) fits `_ruleBookSize` 22dp, centred in the key's 28dp disc where the 16dp
  glyph was, and it always plays (the keys work on a shut card too). `test/rule_book_test.dart`; `lobby_click_sound_test`
  and `table_tax_test` find the key by `ValueKey('rule-book')`. **The coins at a card's top left play the owner's
  `assets/animations/Coins.json`** (the same day: "use this animation in lobby cards on top left for coin and change
  color acc to card"; `widgets/card_coins.dart` `CardCoins`): a pile of gold coins, the front one spinning and a sparkle
  crossing it, 2 s, 800 units square, in the card's colour — beside every category card's name (where the two-chip
  `LivelyChipStack` was: `titleSize × 1.1`, a little taller than the name's capitals — `× 0.62 × 1.22`, the pile's height, until the
  owner asked for bigger coins on 30 Sep 2026) and in every table card's badge (where the `SpinningChip` was: `h × 0.94`, the
  most the badge holds — the pile is 0.8 of its width tall and the badge clips; `h × 0.72` before). The boot row's chip pile and the engine cards' `ChipShuffle` are as they were. Its whole
  loop (30–728 × 122–684) fits the box by its width. `test/card_coins_test.dart`. **Every table card's ⓘ key plays the
  owner's `assets/animations/Info icon wave.json`** (the same day: "use this icon for info on top right … and change
  color acc to card type"; `widgets/info_wave.dart` `InfoWave`, `_CardCornerKey.glyph`): an "i" in a ring with waves
  rippling out, 2 s, 120 units square, in the card's colour; the waves at their widest (4–116) fill 26dp, inside the key's
  28dp disc and its hairline, the ring round the "i" (34–86) 12dp. The first cut took 46–74 for the waves and drew them four
  times too large, past the card's edge: `LottieDrawable.draw` fits with `BoxFit.scaleDown` by default, so the test that
  measured the file drew its 120 units at 120px on a 480px canvas and read a quarter of the art — a measuring draw passes
  `fit: BoxFit.fill`, and the test now also measures the pixels the widget itself paints. The file's "i" (layer `i Outlines`, #ACB6C3) is 2.1:1 on the white card, so by day it is a
  slate (`infoWaveDayGlyph` #5B6574, 5.9:1) in the card's colour; by night the file's grey (7.4:1). The table info popup
  keeps the plain icon. `test/info_wave_test.dart`; `lobby_click_sound_test` and `table_tax_test` find the key by
  `ValueKey('info-wave')`. The marks are one
  widget, `widgets/fact_mark.dart` `FactMark` over a `FactMarkArt` (asset, canvas, where the art sits at rest, fallback
  icon, gradient stops, a brightness recolour): the box, the `OverflowBox`, the memo, the render cache.
  `test/entry_wallet_test.dart`, `test/pot_piggy_test.dart` (the rest pose, the fanned reach and the ground measured off
  the files, the contrast, the day ground in pixels, the tick, still when shut, and every Seen, Blind and Variation table
  card at 640x360 and 1280x800 ×1.25 in both themes, in Inter, each in its card's colour), `test/fact_mark_test.dart`
  (`tintAt` in every card colour and theme, the lock's disc and the wallet in violet pixel by pixel with no file blue left,
  the motion kept, one colour's callbacks shared and another's not). The table info popup (ⓘ) keeps the plain icons. An animating Lottie rebuilds ITSELF at its
  frame rate (the lottie package's `setState`), so `avatar_badge_test`'s "the tick never rebuilds it" counts rebuilds
  under the badge only. INSIDE
  a category the rail is a slim `_BackTile` (the category's name over "All games"; its key the owner's `assets/animations/Back
  Button.json` since 30 Sep 2026 — "use this back button animation for going back instead of using that icon"; `widgets/back_mark.dart`
  `BackMark` over `FactMark`: a ring and arrow that press, sweep out left and come back in from the right, 1.53 s, 1080 units with the
  ring at 364–714 filling the 44dp key — the ring is the key's edge, over its well fill — every stroke and fill in the card's display
  ink (the file's charcoal #2B2B2B vanished by night); `test/back_mark_test.dart`) then that category's `_TableCard`s from
  `GameState.lobbyTablesIn(category)`, **joinable → shut**, each group in the server's order. `GameState.lobbyCategory`
  (null = the front) lives in GameState, not the lobby's State: main.dart's `_BackGuard` closes it before it offers to
  quit (not while the consent panel is up), it survives a visit to a table (leave a Blind table → the Blind tables), it
  is cleared on sign-out and when a new `session:ready` menu no longer lists it, and it is never persisted. Each level is
  its own `ListView` keyed `lobby-rail:<category>` inside an `AnimatedSwitcher`, so a category opens at its first card
  — the key holds nothing that ticks, or the one-second notify would restart the fade — and inside a category cards
  take orb places from index 1 (index 0 spills LEFT, which would be over the back tile). The private card's Create and
  Join keys take a `Space.sm` margin and their word in a `FittedBox(scaleDown)` (24 Sep 2026: Bengali "তৈরি করুন" read
  "তৈরি ..." on TP_Small; `test/private_card_keys_test.dart`), and the settings drawer's display-name error wraps
  (`errorMaxLines`, it was cut to "Letters, numbers and spaces ..."; `test/name_error_test.dart`). **Every table card carries two
  corner keys**, one over the other at its top-right (`_CardCornerKey`: each a full 44dp target whose tap wins the arena
  over the card's own, so it never sits the player down; drawn above a shut card's fade; stacked rather than side by
  side so neither reaches the badge on a 640dp phone). **ⓘ** opens `_TableInfoDialog`: game, boot, entry (the card's own
  `entryValue`), blind moves, pot limit, players, turn time, the viewer's chips, who sees whose chips, and whether they
  can sit or what it would take. The **rules key** under it opens `showRules(context, table: table)` — the rules of
  THAT table: "How this table plays" first (`_RulesSheet._tableRules`, a sentence a rule with the table's own figures —
  blind moves, the pot cap or "no limit" — and no number for what the menu does not carry), then the rankings, and the
  six variations only for a variation table; the plain Rules button (`table: null`) is the whole reference.
  `test/lobby_categories_test.dart`.
  Bucketed rather than sorted because Dart's `List.sort` is not
  stable and the server's order decides the rest. `GameState.tableShut(table)` is the single
  eligibility answer used by both the ordering and the card, so the rail can never file a card under
  "you can join these" and then draw it padlocked;
  `_CategoryBadge` (sheen + `SpinningChip`, blind delayed 900ms), `LivelyChipStack`, `_CardFact`
  rows (including **Entry**, the table's stack band: "Up to 5 Crore", "50 Crore or more", or "Open to all"),
  shut-table overlay — a padlock and `cappedTitle` when the player has outgrown the table, a rising arrow and
  `lockedTitle` when they have not grown into it, both faded to 0.42 so the stake stays readable;
  `_TopBar` (owner, 13 Sep 2026, "more letters of the name"): the profile picture opens the bar — the 4-hour bonus chip
  stood before it until the three lobby rewards were removed (30 Sep 2026, §7.2), and its slot (`Dim.bonusSlotW`, now
  `Dim.cornerChipW`, the Lucky Draw chip's cap) is the name's — and the Settings key closes it, alone in the pill (`_BarActions`) that
  held the record, Settings and Sign out until 30 Sep 2026 ("The lobby's foot", below). **The picture is a fifth bigger than the bar's own measure** (owner,
  30 Sep 2026: "In Top Left increase Profile size but don't increase size of badge"): `Dim.avatarD` = `Dim.avatarMarkD` (the old 0.135h,
  44..64) + the pip's allowance + one pad (58.7dp at 360 tall, 66.5 at 411), drawn through an `OverflowBox` into half of the bar's pad
  above and below, while the bar (`Dim.topRailH`) is still sized from `avatarMarkD` — a bar grown with the picture took 10dp from the
  rail of cards and broke its whole-card stops at 732x412 — and the badge and edit mark keep `avatarMarkD`'s size
  (`_AvatarWithPip.markDiameter`; the badge still centred by `AvatarBadge.centreFor` on the bigger picture's rim); the name and the balance share one
  `Expanded` in which the balance keeps its natural width up to 65% of that room (53% when `tight`, i.e. less than
  `Breaks.tightBar` 470dp for the whole bar — no landscape phone now) and scales down past it, and the name takes the rest — it was a
  `Flexible` beside a `Spacer` and a flex-4 balance, which handed it a sixth of the free space ("Gu…"). On a tight bar
  the Shop key is icon-only (`ShopButton(compact: true)`, tooltip "Shop"). TP_Tall shows "Guest0E00B" whole; TP_Small
  "Guest63…". The balance shows chips then diamonds (gem + count, `_diamondInkOn` — pale blue on dark glass, deep blue on light).
  **The bar reads in groups** (owner, 24 Sep 2026: "visually separate: bonus, profile, currency, Shop, utility"): the
  wallets stand in `_WalletPill` (the `_BarActions` pill's own fill and hairline, hugging its figures) with the Shop key
  against its right end; on a tight bar the steps round the avatar and inside the pill are `Space.sm`, which with the
  53% cap keeps the balance's scale where it was and gives the name 4dp more than before the pill (a 640dp phone now
  shows "Guest0E00B" whole; `test/lobby_polish_test.dart`). The Shop key is an ICE face since 30 Sep 2026 (owner: "The Shop button background colour yellow does not look good with blue icon,
  change yellow to something else which looks good in day and night mode both"; `ShopFace` in `widgets/buy_chips.dart`): white → pale
  blue (#FFFFFF → #EAF3FF → #D3E6FF by day, a step dimmer by night, #E2EDFF → #CADFFF → #B6D2FA), a 1.5dp rim in the icon's own blue
  #1365E8 (0.75 by day — what clears 3:1 on the pale bars — 0.55 by night), "Shop" in #0E4FC0 (≥ 4.69:1 on every stop), a blue bloom
  where the gold one was; `test/shop_face_test.dart`. It was struck gold (`AppTheme.goldFace`, #F1D27A → #D4A514 → #B8890F), which the
  blue shopfront clashed with; the struck gold stays Chaal's, the spin key's and the level tags'. On a still lift; its highlight crosses once every 6 s (it swept every
  3.2 s over a breathing bloom) — at the table too, the same widget. **Its glyph is the owner's
  `assets/animations/Shop.json`** (29 Sep 2026: "use this icon for Shop"; `widgets/shop_mark.dart` `ShopMark`, in the
  storefront icon's 19dp box so the key keeps its width): a shopfront that builds itself — walls, awning, door, window —
  then catches a glint, in its own blues and whites (gold would vanish on the gold face). The file starts EMPTY, is built
  from frame 40 and still from frame 61, so it plays through once as the key appears and then loops frames 40–90
  (`FactMarkArt.loopFrom`, a controller in `FactMark`), the glint drawing in again every 1.7 s and the key never blank;
  told to stand still it stands built. `test/shop_mark_test.dart`;
  **The player's level and XP under the name** (owner, 27 Sep 2026: "In the Lobby on Top show current level of player and
  xp progress bar for next level"; `widgets/lobby_level_bar.dart` `LobbyLevelBar`, placed by `_NameBlock`): the name's second
  line — the level's mark and number ("🌟 Lv 10") at the left, the figure ("4,180 / 5,200 XP") at the right, over a 4dp gold
  bar spanning both (the level screen's own `LevelBar`, which animates when a `player:level` push moves the XP — a new level
  is a new bar, keyed by the level, that fills from empty: kept, it tweened DOWN from the old level's fill, which read as XP lost), at most
  230dp (× the text scale) wide; at Level 50 "MAX LEVEL" over a full bar. Chosen over a ring round the picture because a line
  under the name takes no width from the name or the wallets (the name's box is exactly what it is without a level — held at
  every screen, scale, language and theme by `test/lobby_level_bar_test.dart`) and can carry the figure in words, which a ring
  cannot. Where the block is narrow the row gives way a step at a time before any type shrinks: the figure drops "XP", then the
  mark goes, then the goal (the XP alone), then the word "Lv"/"लेवल"/"লেভেল" becomes the number on a gold plate (the foot key's
  badge), and only then is it scaled — never below 0.7 at 592x360–1280x800, ×1.0 and ×1.25, in all five languages. The progress
  is `levelProgressOf` (`level_screen.dart`, which the XP card and the table's tax popup read too): it needs the ladder
  (`GET /api/levels`), now read at every sign-in when not held; until it arrives the line shows the level and the figure with
  no bar rather than one measured from 0 XP. Built `const` and `select`ing only its figures (`_LevelBarView`), so the bar's
  one-second rebuilds never reach it. A tap anywhere on the name block (name or line) opens `showLevelInfo` with `lobbyClick`;
  its Semantics is one button, "Level 10, 4,180 of 5,200 XP" (`levelBarSemantics`/`levelBarTopSemantics`, `levelShort`, all
  five languages). The GUEST provider tag keeps its line only where name, tag and level line fit the bar's content height
  (measured with a `TextPainter`, §12.3) — 891x411 ×1.0 and 1280x800 keep it, 891x411 ×1.25 drops it; the tight bar never had it.
  The foot's `LevelKey` stays (the owner did not ask to remove it; it is the level screen's key where the name block is cut
  short); **it and the Friends key are 56dp round keys with 36dp discs since 30 Sep 2026** (owner: "increase the size of friend
  icon and level icon which is in bottom right"; 44dp keys with 28dp discs before — `LevelKey.side`/`disc`, `FriendsKey.side`,
  `_Mark.size`, their glyphs 21dp; `lobbyNoticeArea` still measures the foot keys, so a toast keeps clear of them). Pictures by hand:
  `test/lobby_level_bar_shots.dart` (run like table_shots);
  **The lobby's foot** (since the three rewards went, 30 Sep 2026 — owner: "Remove 24-hour daily reward, 4-hour bonus, and
  milestone reward"): the Lucky Draw chip alone in the bottom-left corner (`_LuckyDrawChip`, keyed `_luckyChip`) and the
  level key and Friends in the bottom-right (a Row keyed `_footKeys`) — **and between them, since the same evening, the record's key**
  (`_StatsKey`, keyed `stats-key`; owner: "move the player stats button from top left to bottom right of screen"): the level key's shape,
  56dp with a 36dp disc, the bar's own `Icons.insights_outlined` and `yourRecord` tooltip, opening the Stats drawer through the same
  `_open(context, _EndPanel.stats)` — so every test that taps the record's icon or tooltip still finds it, at the foot. **The top bar's
  Sign out key went with it** (owner: "remove the sign out button from top left" … "but keep the sign out button in seetings drawer"):
  `_BarActions` is the Settings key alone in its pill, and Sign out is the Settings drawer's ACCOUNT row, which still asks first
  (`_confirmSignOut`) — where the daily bonus (`_DailyBonusChip`, beside the
  Lucky Draw), the milestone chip (`_MilestoneChip`) and, in the top bar, the 4-hour `_BonusChip` stood, with their popup
  (`openBonusDetails`), their glyph line (`_rewardLine`, `_CornerChip.reward`) and `Dim.dailyBonusW` — all removed, with
  `bonus_chip_icons_test`, `bonus_details_test` and `daily_bonus_test`. The rail keeps a band clear at its foot the height of
  the Lucky Draw chip's two lines or a touch target, whichever is taller, and `lobbyNoticeArea` keeps a toast between the two
  corners; one `endDrawer` for stats/settings. The reward celebration stays, for what lands in a wallet in the lobby — a pack,
  a Premium Package, a missile trade. A `_CornerChip` is a pill of the cards' own surface (`GlassCapsule(surface:
  GlassSurface.card)`) with its mark in a 28dp disc (`_ChipMark`: gold-lit while a spin can be taken, a quiet well while it
  is coming), a `cardMuted` title and the figure in the card's ink (gold when ready), capped at `Dim.cornerChipW`. The top bar's
  `tight` is measured against the whole bar now, so no landscape phone is tight: the Shop key shows its word and "Guest0E00B" is
  whole at 640x360 ×1.25 (cut a little at 592x360 ×1.25). `test/lobby_rewards_removed_test.dart` (an account still carrying an old
  `rewards` object draws none of it; the four foot keys on screen, in their corners, one size and clear of each other; the record's key
  under the bar and no Sign out key or glyph in it; the toast area between them).
- **Friends V1 — a LOBBY feature** (owner's brief, 26 Sep 2026; server side §7.2/§7.3; `screens/friends_screen.dart`,
  `state/friends_state.dart`, `models/friends.dart`), with ONE table surface since the same evening (**Friends at the
  table**, owner: "in a gametable, if a player clicks other player pod then a drawer from right side will open, where he
  can send friend request and player by clicking his pod can accept the friend request"; `widgets/player_drawer.dart`):
  a tap on ANOTHER occupied seat's pod — on the Teen Patti and the poker felt, never the viewer's own, never an empty
  chair (`playerDrawerSeat`), the plaque only — opens `PlayerDrawer`, the tables' Scaffold `endDrawer` (right side,
  `TableSpace.drawerW`, `TableScrim.drawer`, `endDrawerEnableOpenDragGesture: false`; the Scaffold still watches nothing;
  back closes it first; the variation window closes it as it does the left drawer): the player's picture and name at
  once from the seat — the whole drawer ONE scroll, head included, the close key (`seat-close`, a round well) pinned over
  its top-right (owner, 29 Sep 2026: "When i open player drawer, then scrolling gets stuck": beside the large portrait the
  fixed head took a quarter of a landscape phone's drawer and a drag begun on it moved nothing) — the picture LARGE, 68dp
  (`_Head.pictureRadius` 34; 22 before), with their level's disc on its
  top-right (owner, 29 Sep 2026: "profile pic should be big and in top right of profile pic it should show his level
  icon"): the pods' own `SeatLevelMark` (`seat-player-level-mark` / `-art`), 0.44 of the picture, its middle on the
  picture's rim at 45°, the seat's level at once and the profile's (the fresher) once it has come, none where neither has
  art — then `GET /api/players/{id}/profile` — and with it their **level** under the name ("Level 10 · Rising Star" —
  its art, which stood before the words, is the portrait's disc now; `_LevelLine`, gold, on `levelStrut`, set smaller
  rather than cut; owner, 27 Sep 2026: "In game table each
  player can see each other level of player also by clicking other player pod … but players should not able to see each
  other total winnings and biggest pot"; the profile's `level {level, title, icon}` — `auth.ProfileLevel`, read through
  `playerLevelJoins` like every account's, absent where the ladder has none — and nothing else of the standing: no XP, no
  rate, no badge; another player's winnings and biggest pot never reach the phone and would be dropped if they did,
  `StatsByCategory.fromJson(chips: false)`) — NONE **Add Friend** (gold primary) → **Request Sent** (dead);
  PENDING_RECEIVED **Accept** (gold) + **Reject** (outlined); FRIENDS a ✓ Friends tag (no Remove at a table); a refusal
  re-reads and shows its note in the drawer — for a friend, **"Friends for 3 days"** under the name in the head (owner,
  26 Sep 2026: "show each other at the top how long they are friends in time"; `_FriendsFor`, from the friend list's
  `friendsSince` via `FriendsState.friendsSinceOf`, the same moment for both, in the largest whole unit — minutes, hours,
  days, months of 30 days, years — or "Friends since just now", counted again every 30 s, up to three lines beside the
  large portrait; `Strings.friendsFor`, which
  added months and years to the time units) — and the record through the ONE `PlayerStatsGrid`
  (`widgets/player_profile.dart`, `RecordSurface.lobby|table`, shared with the lobby profile; the lobby's Stats drawer drew
  it too, as `PlayerStatsGrid.own` — removed with its chip tiles — until its own presentation of 27 Sep 2026, "The Stats drawer" below): since Player stats v2 (27 Sep 2026) a game switch — All · Teen Patti ·
  Variation · Poker (`StatsCategory`, `models/player_stats.dart`) — over the counts, and for Teen Patti and Variation the hands
  held (Trail down to High Card) and the variations played; counts in thousands grouping, and no chip figure. **Every hand
  wears an icon** (owner, 27 Sep 2026: "there is no icon in hands held category in player stats, add icons also"):
  `HandTally.icons` — the daily XP's own "Win by" marks, 🔥 Trail, 💎 Pure Sequence, 🃏 Sequence, 🎨 Color, 👥 Pair, and ☝️
  High Card (🔝 drew as a blue "TOP" key) — drawn by ONE `HandIcon` (`player_profile.dart`, decoration only: the name is
  what a screen reader hears) over the count in the record's cells and before the name in the Stats drawer's
  `HandResultGrid`, whose width sum counts the widest icon so every name of a column starts at one edge. No presence, no wallet, no
  table id. Its own state slot (`FriendsState.seatPlayer/seatProfile/openSeat/closeSeat`), apart from the page's.
  **A drawer opened again shows the profile read last time at once** (owner, 29 Sep 2026: "if i close that pod, open again it
  should show previous fetched record and meanwhile it will async api to fetch latest record, and it will update, otherwise it
  will show previous fetched record"): `FriendsState` keeps each player's last profile (`_seatCache`, `cachedSeatProfile`, at
  most `seatCacheSize` 64 players, the one opened longest ago going first); `openSeat` puts it on show and reads the profile
  again — no loader, the record there — and the fresh one replaces it when it lands; a read that fails keeps it (the drawer
  says nothing while it has a profile), and only `player_not_found` drops it. Every change to what a player is to the viewer
  (`_restate`, `_noLongerPending`, `_restateSeat`: a request, an accept, a removal, a push) updates the kept copy too, so a
  reopened drawer never offers a move from before it; `reset()` (sign-out, account deletion) forgets them all. A seat
  whose player has asked the viewer wears **`SeatRequestBadge`** (a gold person-add disc on the lower-LEFT corner of their
  picture — on the pod's top corner it covered a long name's first letter), and a seat whose player is the viewer's
  FRIEND wears **`SeatFriendMark`** (owner, 26 Sep 2026: "if two or more friends are on same table … their should appear
  small icon on each of them … while other are not their friend so they cannot see that icon"; a green disc on the
  picture's lower-RIGHT corner, named "Friend") — both laid over the picture in a Stack that is always there
  (`SeatPod.requestBadge/friendMark`, `markSide`), so neither changes the pod's size or the ring, never on the viewer's
  own pod or an empty chair, on both felts. Decided ON THE PHONE from the viewer's own lists, never sent to anyone:
  each friend sees the mark on the other's pod because each is in the other's list, and nobody else sees either.
  `FriendsState.tableOpened()` reads the incoming requests AND the friends list ONCE as a table opens (in
  `handleState`); `isFriend` answers from ONE id set kept with the friends list by every read, accept, push and remove;
  the pushes and the moves keep both — nothing polls at a table, and removal is lobby-only, so the list read at the
  table's opening stays right for the sitting.
  **The pushes** (§7.1): `GameConnection.onFriendRequest/onFriendAccepted`, registered before connect (a push can beat
  `session:ready`); `GameState.handleFriendRequest` → the request joins the incoming list and a toast says "{name} sent
  you a friend request." — "… Tap their seat to answer." when the sender sits at the viewer's table (`seatedHere`), no toast
  for a sender blocked in the table chat; `handleFriendAccepted` → "{name} accepted your friend request."; an open drawer or
  page showing that player re-reads. The source scan in `test/friends_page_test.dart` now holds that the table files know
  the drawer and the badge and never the Friends page, its key or presence. `test/friends_table_test.dart` (73: both felts, the friend mark, the friendship's age,
  every status, the moves, the pushes, 640x360 ×1.25 in all five languages both themes); pictures by hand,
  `test/friends_table_shots.dart`. **The viewer's own pod** (owner, 27 Sep 2026: "player can click his own pod and it will
  his own stats which you show when you click in lobby and also shows his friend list with status who all are online and
  other info") opens the same end drawer in its own mode (`FriendsState.ownOpen`, `openOwn`; `ownDrawerSeat`/`openOwnDrawer`
  in `player_drawer.dart`, so the felts still know only that file): `OwnSeatBody` (`widgets/own_seat_drawer.dart`), as wide
  as the lobby's Stats drawer (`widthFor`, 300–420dp) — the Stats drawer's `PlayerStatsHeader` (picture, name, level,
  badges, its close key) over two tabs, **Your record** (`OwnRecord` and its footnote, the lobby's own, the viewer's winnings
  and biggest pot included — their own) and **Friends** ("2 online" beside the word, `friendsOnlineCount`): every friend,
  PLAYING, ONLINE, OFFLINE, by name, with the Friends page's own presence lines (`FriendPresenceLines`, moved with
  `PresenceDot` and `presenceGameLine` into `widgets/friend_presence.dart`, which the page re-exports) — read, not acted on.
  Opening it re-reads the account (`refreshUser`, as the Stats drawer does) and the friend list, and the list is read again
  every `FriendsState.pollEvery` (15 s) while it shows (its own timer, gone with it). No friends says so; a list that cannot
  be read offers Retry. This is the one place a table shows where a friend is: `friends_page_test`'s source scan allows
  presence through `own_seat_drawer.dart` alone. `test/friends_table_test.dart` "the viewer's own drawer" (the record, the
  friends in order with their presence, the 15 s read that stops on close, empty and failing lists, both tabs at 640x360
  ×1.25 in every language, both themes, both felts); pictures `own`/`ownFriends` in `friends_table_shots.dart`. **The key**
  (`FriendsKey`) is a round 44dp key of the corner chips' card surface in the lobby's bottom-right corner, beside the level key (just left of the milestone chip until that went, 30 Sep 2026) —
  not in the top bar, where a fourth key would have cut the player's name at text ×1.0 on a 640dp phone (the wallet pill
  takes 53% of a tight bar); the people glyph in a 28dp disc, turning gold with a soft glow and a count badge ("9+" past 9)
  while requests wait; hidden signed out and on a server from before Friends (404). `lobbyNoticeArea` keeps toasts off it
  where 160dp remain, and gives a toast the plain foot (null) while a page or dialog covers the lobby
  (`ModalRoute.isCurrentOf` on the foot keys, `_footKeys` — on the milestone chip until 30 Sep 2026): kept between chips hidden under the Friends page, its toasts stood 156dp
  wide on a 640dp phone and broke over three lines. **The page** (`showFriends`, risen from the foot like the store and the Lucky Draw; gold-edged glass by
  night, the warm card by day): a header with the title, Add Friend and close, then "Your Player ID" — the full UUID, scaled
  to fit and never cut — and Copy ("Copied" for 2 s); on a landscape phone two columns, Friend Requests (Accept / Reject)
  and Friends (PLAYING, ONLINE, OFFLINE, then name: a green dot and "Online · Playing now" in gold over "Teen Patti • Seen" /
  "Poker • Texas Hold'em" in the app's own engine and category names, or a grey dot and "Offline"), each with pull to
  refresh; one list below 520dp. **Add Friend** searches by Player ID and the card's action follows `friendStatus` (Add
  Friend · Request Sent · Accept · a Friends tag · "That's you"), refusals in words under it. A landscape phone's keyboard
  leaves the panel 70–110dp, so while it is up the header steps aside (`FriendsScreen.typingRoom`, 160dp) and the field and
  Search stand alone above it — with the header the field stood under the keyboard on TP_Small; Search puts the keyboard
  away and the header back. The gap under the header lives inside Add Friend's own scroll view (`padding: top`), because a
  scroll view that overflows clips at its top edge and the field's floating label stands half above the field's box — the
  test holds the field, its label and Search inside the scroll view and above the keyboard at 640x360, 732x412 and 915x412,
  ×1.0 and ×1.25, in all five languages. **Profile**: picture, name,
  presence (friends and self only), the relationship's action or Remove Friend (asked first in a `GlassDialog`), and five stat
  tiles — hands played, won, lost, left mid-hand, win rate — in plain thousands grouping, never `formatChips`. No wallet
  figure, word or icon on any of it. **`FriendsState`** is its own notifier owned by `GameState` (the page watches only it, so
  the one-second tick never rebuilds the page): the badge's count at every sign-in, whenever the lobby appears (back from a
  table too), every 60 s while the lobby shows (not while the page is open) and when the page closes; the page's lists when it
  opens, every 15 s while it is on screen (the timer tied to the page's own lifetime) and on pull or Retry; an answer that set
  out before an accept, reject or remove is dropped so it cannot undo it; the page closes itself if the app leaves the lobby.
  **The lists are paged** (owner, 27 Sep 2026, the server's Pagination, §7.2): the friends and the requests waiting come 20 at a
  time and the next page as a list is scrolled within 240dp of its end — or at once when a page does not fill the view —
  with a spinner at the end meanwhile (`widgets/paged_scroll.dart` `PagedScroll`/`PagedFooter`; `FriendsState.loadMoreFriends`,
  `loadMoreIncoming`, `hasMore…`, `loadingMore…`); the section counts and the lobby key's badge are the TOTALS (`friendsTotal`,
  `incomingCount`), kept by every accept, reject, removal and push, not the rows read; a poll or a pull re-reads as far down as
  the player had scrolled (a page of that many, at most 100). **A table reads every page** (`tableOpened`, 100 a page), since
  the friend mark and the request badge are for whoever sits down. The Reported tab and the viewer's own drawer's Friends tab
  page the same way (`PlayerReports.loadMoreMine`). `test/paging_test.dart` (a fake server that really pages: 45 friends, 26
  requests, 25 reports, 230 friends at a table; the scroll, the spinner, the fill rule, the totals).
  56 strings in five languages. Tests: `friends_{dtos,api,state,page,table}_test.dart` (204) on `friends_fixture.dart`, a fake
  server built from the contract; pictures by hand, `test/friends_shots.dart`.
- **Report Player** (owner's brief, 27 Sep 2026; server side §7.2/§7.3; `widgets/report_player.dart`,
  `state/player_reports.dart`, `models/report.dart`, `ApiClient.reportPlayer`). The table's **player drawer** is the player
  menu: under the move the two players' standing offers sits a quiet line, `ReportPlayerRow` (`seat-report`: a flag and
  "Report player" in the metadata ink, no fill, no gold, a 44dp target — never a key on the felt), on both felts, never on the
  viewer's own pod. It turns the drawer — **a page of the drawer, never a route** — to `ReportPlayerPage` under the same head
  (the player's picture and name): nine reasons as pills (`_ReasonChip`: the chosen one ticked and gold-edged, not colour alone;
  a screen reader hears one choice among several), a description field (hint "optional", or "required" for OTHER; stopped at 500
  CODE POINTS by `_CodePointLimit`, the server's measure, with a "n / 500" count), **Submit report** (the drawer's primary gold
  `DrawerKey` — made public for it — dead until a reason, and a description for OTHER; while sending it spins, reads
  "Submitting…", and neither it nor Cancel can be pressed: `PlayerReports.submit` does nothing while one is out) and Cancel.
  Filed: "✓ Report submitted / Thank you for helping keep the game fair. / Our team will review the report." (a green tick,
  the brief's words), Done back to the card, whose line then reads "✓ Reported", dead, for the session (`wasReported`; also
  after `already_reported`). Every refusal is said in the page in the player's language (`reportRefusalText`:
  already_reported, report_limit_reached and rate_limited alike, player_not_at_table, an invalid or gone player, the
  description's two, no connection — a 12 s timeout —, anything else "something went wrong"), and the report can be sent again.
  **The limit on the phone** (owner, 27 Sep 2026: "if user has reported 2 player, then reporting by him should be disabled in
  UI, and show a cool down time in UI when can he report again"): `PlayerReports.limit` (`ReportLimit`, `models/report.dart`:
  the server's `waitMs` added to the moment its answer arrived) is read as every other player's drawer opens
  (`refreshLimit`, from `openPlayerDrawer`; skipped within `limitFresh` 10 s of the last read or while one is out; a 404 — a
  server from before — leaves it null and the line as it was) and taken from a filed report's 201 and a 429's body. While it
  is used up (`limited`) the line is `seat-report-limited`: dead, an hourglass, "Report limit reached · 2 of 2 reports used",
  and under it in gold `ReportCooldown` — "You can report again in 23h 41m 5s", its own one-second timer (the drawer rebuilds
  for nothing), rounded up so it never reads 0s while waiting. A player already reported still reads "✓ Reported". The report
  that uses the last one says the same under the thank-you (`report-sent-cooldown`); a limit met elsewhere, answered 429 with
  its wait, puts "Report limit reached" and the countdown in the page's note and keeps Submit dead (`canSubmit`). The moment
  the wait ends a timer (`_limitOpened`, half a second past it) brings the line back and reads the limit again; sign-out forgets
  it (`reset`). `PlayerReports.clock` is the tests' seam. Three strings in all five languages (`reportLimitTitle`,
  `reportLimitUsed`, `reportAgainIn`). Played on TP_Small against the local server: an account with two reports filed opened a
  third player's drawer to the dead line counting down from 23h 34m 46s, and a tap did nothing.
  **The Reported tab** (owner, 27 Sep 2026: "There is friends button in lobby, when user clicked it, then add one more tab,
  where user can see all the players he reported in detail status, description, time he reported but don't show the reported
  user id, by default it will sorted in latest reported user"): the Friends page's list head is two tabs, **Friends** and
  **Reported** (`_PageTabs` in `friends_screen.dart` — the level screen's look for two: a glyph and a word each, gold for the one
  showing, a sliding gold underline, each a 44dp target at most 190dp wide, the word set smaller rather than cut), beside Add
  Friend and Close; the page's mark gave its place to them. The Player ID heads the Friends tab alone. Reported reads
  `GET /api/reports/mine` as it opens (`PlayerReports.loadMine`/`mine`, `FiledReport` in `models/report.dart`, sorted newest
  first again on the phone — `FiledReport.newestFirst`, stable) and lists each report on the page's own pane: the picture and
  name ("Deleted player" in italics, a crossed-out person, for an account gone since), the status at the row's right end
  (`ReportStatusTag`: an icon and a word on a wash of its ink — Pending amber, Under review blue, Action taken the friends'
  green, Dismissed quiet, an unknown one by the server's word), the reason and where the two met ("Cheating · Teen Patti •
  Seen", `tableKindLine` in `friend_presence.dart`), the description whole, and "Reported 27/09/2026 · 7:44 PM"
  (`reportedWhen`: the day as numbers, the time by the phone's 12/24-hour setting). Pull to refresh; "You have not reported
  anyone."; a failed read offers Retry; a server without the route (404) is an empty list. Sign-out forgets it. Ten strings in
  all five languages. `test/reported_tab_test.dart` (20: the wire and the order, both tabs, every row's words, no id even one
  a server wrongly sent, empty, failure and retry, an older server, sign-out, and 640x360 ×1.25 in all five languages and
  592x360 in English and Hindi, both themes). Played on TP_Small against the local server.
  The client sends `{reportedUserId, reason, description?}` and nothing else. `PlayerReports` is GameState's own notifier
  beside `FriendsState` (no one-second rebuilds), reset at sign-out; the drawer listens to both, drops the page when it shuts
  or another seat opens, keeps a separate list (and scroll) per page, and rides above the keyboard with its head stepped aside
  while typing, as the chat drawer does. 32 strings in all five languages. `test/report_player_test.dart` (51: the limit's
  wire and countdown, the dead line counting down and coming back, the last report's countdown, a 429 with its wait on the
  page, an older server, sign-out, the limited line at 640x360 ×1.25 in every language and theme; and: both felts,
  the quiet line, no route, the exact body, loading and no double send, the thank-you, OTHER, the 500 code points, every
  refusal in every language, a closed page ignoring a late answer, the keyboard, and 640x360 ×1.25 in all five languages and
  both themes with the Noto fonts).
- **The XP mission bar** (owner, 27 Sep 2026: "whenever xp mission completed, show top notification bar for 5 seconds
  showing this is completed and xp increased"; app only — `state/xp_missions.dart`, `widgets/xp_mission_bar.dart`). **Detection**
  (`XpMissions.completions`, pure): only a `player:level` (`GameState.handlePlayerLevel`) can raise one, and only when the XP ROSE
  and the new standing carries a daily window; within one window (the same `resetsAt`, give or take a minute) a source is completed when its claim count
  went up; when the window changed — rolled over, or opened by this very award (a window opens at the player's first completed
  hand, which may be a win) — the counts are read from nothing, so the reset counts are never a completion and a count that fell
  never is one. It compares against `GameState._xpSeen` — the standing the last push, or the session's start (a sign-in, a cold
  start's `me()`, `session:ready`: `_seeStanding`), left — NOT the account, because the `/api/auth/me` refresh every showdown
  starts can land the award's figures before the push that announces them; a login, `me()` or `session:ready` therefore never
  raises a bar. A ONE_TIME mission (28 Sep 2026, §6.6) is one too: completed in the new standing and not in the baseline — no
  window needed — after the award's daily ones, named by its title, with the XP the server says it gave (`xpAwarded`); a push
  that only moved a mission's progress (the XP did not rise) raises none. `_xpSeen` only moves FORWARD (lifetime XP never falls): the play-time tracker pushes from its own goroutine and a
  hand's settle from the table's, so an older standing can be heard after a newer one, and compared against it would announce a
  mission again. **One bar per mission, queued** (not one bar listing them): each is its own achievement, one line fits the slim
  bar, and a screen reader hears one at a time; several in one award come in the ladder's order with running totals, and a level
  up rides on the award's last bar ("Level up! 🔰 Level 2 · Rookie", and "Winning tax now 19.71%" under it when the level
  changed the rate — `XpMissionNews.levelUpTaxBps`; none when a badge keeps it lower) and replaces the level-up toast. Names,
  XP and order come from the level ladder (`xpSourceName`), which is usually NOT on the phone (it is read when the level popup,
  the level screen or the Badges shelf opens): an award that completes a mission without it waits in
  `_awardsAwaitingLadder` while the award reads it, and is queued, in the order the awards came, when the read ends — as best it
  can when the read fails ("Daily XP mission"; an XP only for a lone mission, none for two sharing one award). **The bar** (`XpMissionHost`, in main.dart's builder in a Stack beside the toasts' Scaffold — above the
  Navigator, so over the lobby, both felts, drawers, sheets and dialogs): slides down from the top edge inside the safe area
  (`topGap` 4dp), comes with the owner's `assets/sound/notification.mp3` (`FeedbackSettings.xpNotification`, full volume, behind the Sound switch, once a bar), stays `hold` **15 s** (owner, 27 Sep 2026: "toast message should remain for 15 seconds"; 5 s before) with a gold line draining along its foot, slides away; its **×** key (`xp-mission-close`, a 24dp disc in a 44dp target at the bar's right end — no Tooltip: the bar stands above the Navigator, with no Overlay; "give a cross button also in toast message") or a tap anywhere on it sends it early, one tap one bar; the next waits
  `between` 180 ms — never two at once. As wide as its words, centred, up to `maxWidthFor(w)`: at a table 0.6 of the safe width
  (260..440dp), clear of the Shop key and the wallet, the keys and the viewer's cards at 592x360–915x412 ×1.0/×1.25 on both felts
  (it covers the top seats' heads for the 5 s); in the lobby half (260..420dp), clear of the picture and the drawer keys — the
  top bar has no gap in its middle, so there it lies over the name and the wallet pill, and below about 700dp the Shop key. The
  mission's emoji in a gold-ringed disc with a green tick, the mission in the display ink, "+1 XP" on a gold wash, "24 / 100 XP"
  quiet. The mission and the level up are never set smaller or cut: a long one takes a second line (two at most), so the tallest
  bar — a Bengali Pure Sequence and "Level 44 · Supreme Overlord" with its tax at 592x360 ×1.25 — is six lines, 147dp, still
  clear of every key. The lobby cards' opaque body under the glass, gold live hairline, both themes. A `Semantics(liveRegion)`
  reads its lines. Four strings in all five languages; the Indic titles put the mission after "Mission complete:" ("मिशन पूरा:
  Pair से जीतें"), since the mission's name is an imperative there. `test/xp_mission_toast_test.dart` (the rule, the queue, the 5 s, the tap, the level up, what
  shows nothing, the forward-only baseline, the wait for the ladder, the tax on the bar, `session:ready` and `player:level` through
  `GameState.start()`'s own wiring on a fed connection, the bar in `KingTeenPattiApp` itself, over a dialog and the table drawer,
  both felts and the lobby's corners, every language and size); pictures by hand, `test/xp_mission_shots.dart` (run like
  table_shots; `longLevel` is the tallest bar).
- **Emojis** (owner, 26 Sep 2026; server side §7.1/§7.2/§7.3; `widgets/emoji_shelf.dart`, `widgets/emoji_art.dart`).
  `EmojiItem`/`ChatEmoji` DTOs, `ApiClient.emojis`/`buyEmoji`, `GameConnection.sendEmoji` (`chat:emoji`), `GameState.emojis`
  (loaded with the pictures, warmed into `PictureCache`), `buyEmoji` → `bought | notEnough | refused`, `sendEmoji` sharing
  the chat cooldown. **The store's seventh shelf, Emojis** (`StoreTab.emojis`): each tile plays its Lottie (`EmojiArt`,
  fitted whole) under the shelf badge (✓ Owned / padlocked price) and the term; a locked one asks first with the emoji
  large; a chip-priced one at a table is lobby-only; a short hammer or diamond wallet is offered its shelf. **The table:
  an emoji key** (`ValueKey('rail-emoji')`, a smiley) on the left rail of both felts under the chat key — the rail column
  now centred between the Shop key and the corner keys (`SideRail.columnTop`) so four keys fit a 360dp phone — opening
  `EmojiDrawer`, a page of the table's left drawer (never a route): owned emojis to send (tap = send + close; dimmed with
  the dial during the cooldown), locked ones with their price, **bought right there** (owner, 28 Sep 2026: "no need to
  send player to store, he buy emoji there itself"; `unlockEmoji` over the drawer — the store opens only for a wallet too
  short, on that wallet's shelf; the heading `emojiUnlockMore` reads "Tap one to unlock it"). The app buys one emoji at
  a time (`GameState.buyEmoji` refuses a second while `buyingEmoji` is set), so while one is being bought its tile wears
  the game's ring and EVERY locked tile — in the drawer and on the store's shelf — takes no tap until the answer comes
  back; `unlockEmoji` entered meanwhile says "Please wait..." rather than dropping the tap (review, 29 Sep 2026). **An emoji plays over
  its sender's seat for `GameState.emojiBubbleFor` = 5 s** (owner: "5 seconds instead of 4") on every phone, the sender's
  too, in the chat bubble's place (`SeatPod.emoji`, a one-deep queue per seat), and sits in the chat log as a small
  playing Lottie beside the name; a blocked sender's is hidden. **Two emojis never overlap** (owner, 28 Sep 2026: "if
  overlap then change the direction"): each plays at its bubble's place for one invisible frame, is measured
  (`SeatPod.emojiKey`), and `_Felt._placeEmojis` moves a newer one that would meet one already playing to the first of its
  seat's `EmojiPlace`s that stays on the felt and meets none — beside the pod towards the table's middle, above it, beside it
  on the other side (the viewer's: over their cards, then left), preferring places off other pods — pointing at the pod
  from its side (`_TailSide`); ordered by the server's stamp, the same on every phone; kept while it plays.
  `test/emoji_overlap_test.dart`, scene `19c-every-seat-emoji`. 18 strings in five languages.
  `test/emoji_{state,store,table}_test.dart`.
- **The reward programs** (owner's brief, 30 Sep 2026; `screens/reward_programs_screen.dart`, server side §7.2/§7.3, the claim §8.1).
  **The lobby chip** (`_RewardsChip`, keyed `rewards-chip`) stands beside the Lucky Draw's in the bottom-left corner — the two in one Row
  under `_luckyChip`, so `lobbyNoticeArea` keeps a toast off both: REWARDS over "Collect now", lit, while any program's today is
  unclaimed, else the longest streak ("3 day streak") or "Collected today"; its room is kept, unseen, while the first read is out (as
  the Lucky Draw's is); none from a server with no programs; a tap opens the weekly login popup while its day waits, else the screen.
  **The weekly login popup** (owner, the same day: "Use this animation which shows up everyday in case of weekly login and put the
  prize in blue boxes, it should pop after login and if user has claimed it should not show when user start the app, otherwise show
  it"; then "Calender size should be big and it should play animation where all box one by one come up and then rewards on them
  boxes"; then the polish brief the same evening — "Premium King Teen Patti Reward Vault", not "generic calendar popup";
  `widgets/weekly_login.dart`): the owner's `assets/animations/WeekLy.json` — a desk calendar, 600×250, 30 fps, 3 s, no 3D,
  expressions or images, whose seven boxes (four on the top row, three on the bottom) pop in one after another over two seconds and
  pop out again by its end — CROPPED to the card (`WeeklyCalendarGeometry.window` 188,58–412,236; the white solid, the sparkles and
  the skyline ground hidden), taking the panel's whole height on the left, played ONCE to `holdFrame` 66 (every box in and still,
  before the first leaves) and held there. **Restyled as it plays, never edited** (`WeeklyCalendar.delegates(brightness, state,
  {collected, level})`): the card's body, header band and ring holes in the theme's glass tones — charcoal by night, warm off-white by
  day (`WeeklyCardColours`) — its outline and rings thinner and softer, and each box in its DAY's colour (`weeklyDayStateOf`:
  `claimed` and `current` gold, `next` the blind table's cyan, `locked` dark glass, `finalDay` the seventh's purple). **Then the prizes
  land on the boxes one by one** — the boxes first, the owner's order — (`_DayCard`, keyed `weekly-box-<day>`, `revealStagger` 110 ms
  apart with the boxes' own overshoot, placed from the file's geometry — `boxCentres`, `boxSide`, `boxPops`, read off its layers and
  held to the file by `test/weekly_login_test.dart` — so the prize and the box cannot drift apart): "DAY n" (FINAL on an unclaimed
  Day 7), the prize's mark and its figure — **the figure the largest thing on the card, every size a share of the box's side**
  (`figureSize` 0.235 of it, `markSize` 0.27, `labelSize` 0.135, set down whole where the phone's text size would overflow; owner,
  30 Sep 2026: "Make Text size bigger of reward money which u show in calender"; 9.5 fixed before) — a collected day struck gold with a
  ✓ badge straddling its corner, today's ringed in gold, a touch larger, with a breathing glow, the next day in cyan glass, the days
  beyond dark with a small lock, the seventh gold over purple; a `_ProgressThread` between the days of a row, gold as far as the run
  has come. **The panel** (`WeeklyLoginOverlay`, a `Positioned.fill` in the lobby's Stack under the celebration, while
  `weeklyLoginOffer` stands and the resume veil is down; a tap outside, the × `LevelCloseKey` and Back — `_BackGuard` — close it):
  the lobby's glass (`PremiumGlassPanel`, `Elevation.overlay`) with a gold edge and a soft light behind it, the calendar 60% of its
  width (55% under 600dp inner), and on the right the reward hierarchy — the program's name in capitals, 🔥 "2 DAY STREAK" / "START
  YOUR STREAK TODAY", what the mode means (the one line that gives way), TODAY'S REWARD over the prize in large gold, NEXT REWARD, and
  the gold `LuckyGoldKey` **Collect now** — which claims (`claimRewardPrograms(celebrate: false)`) and turns the hero into "✓ + 20,000
  CHIPS" (the other programs' grants under it, `rewardsAlso`), fireworks, the day's card struck gold, and the key **Continue**; a
  claim that fails says so in the hero's place and keeps the key. **Inside a Blind or Variation level the popup takes the level's
  colour** as the two drawers do (owner, the same day: "In day mode, when i click "Rewards" button after going into blind catalogue,
  then daily Streak background color should be changed acc to card color, same with when i go in variation catalogue"): the lobby lays
  `LevelAccent(palette: drawerPalette)` over the overlay, and the panel's wash (`tint`), its edge, the light behind it and the
  calendar card's glass (`WeeklyCardColours.of(b, level)`, `LevelColours.inHue`) take the level's hue — ice and sapphire, lavender and
  violet, by day and by night — the house gold at the front and inside Seen, and the day cards' own colours everywhere. **It waits
  behind "Before you play"** (owner: "The weekly pop should not come in background of the text "Before you Play" it should come after,
  when i click "I confirm""): `offerWeeklyLogin` answers false until `loadConsent` has settled the account (`_consentKnownFor`) and
  while `consentPending`; `loadConsent` offers once it finds the account clear and `acceptConsent` offers on the tap. Offered once a
  day a session; the next start offers it again while it is still to collect. Strings `todaysReward`, `rewardsAlso`,
  `todaysRewardTitle`, `continueKey`, `weeklyFinal` in all five languages. `test/weekly_login_test.dart` (23: the file's geometry,
  layers, pops and traps; the delegates, the day states, the level's hue on the card and not on the boxes; the boxes then the prizes,
  the file held at its frame; the popup behind consent, after sign-in, not when collected; the figure's size; the level's colour inside
  Blind and Variation and the house gold at the front and inside Seen; Collect and Continue, nothing celebrated twice, once a day, the
  chip, a new day, a tap outside and Back, a failed claim, and 640x360 / 592x360 ×1.25 in all five languages and both themes) on
  `test/reward_fixtures.dart` (the fake server, `rewardState(consented:)`, the fonts); pictures by hand, `test/weekly_login_shots.dart`.
  **The screen** (`showRewardPrograms`, a page risen from the foot like the
  Lucky Draw's; it reads again as it opens, the day may have turned; a gold **Collect now** key in its header while any program's
  today waits, `reward-programs-collect`, which claims and closes the screen over the lobby's celebration): one `_ProgramPanel` a program — a LOGIN STREAK / CALENDAR tag
  (gold / the blind table's sapphire), the program's name (the four seeded ones in the player's language, `rewardProgramName`; any other
  by the server's `name`), the headline — **"3 day streak"** (`streakDays`; "Start your streak today" at 0) for a streak, **"Day 10
  reward"** (`calendarDayReward`) for a calendar, the brief's §27 difference kept on the screen — on a second line where the three cannot
  share one (a `Wrap`: 640dp at ×1.25 cut "Monthly Calendar Rewards" in a Row), what the mode means under it, then the days: a week's
  seven in one row (`_WeekRow`: a streak's "Day 3" over its weekday, a calendar's weekday over its date; **96dp tall since 30 Sep 2026**
  — owner: "Increase the size of each box of Day along with text"; 68 before), a month's 28–31 seven to a row
  (`_MonthGrid`, the date; the page scrolls, the grid does not) — each `_DayTile` its reward's mark in its wallet's ink and its figure
  ("10,000", "×2", an item's name — `rewardPrizeShort`, `rewardPrizeIcon`, `rewardPrizeInk`; the type `_DayTile.labelSize` 13,
  `subSize` 12, `markSize` 22, `figureSize` 15.5, the figure the largest — the label ramp's 11 for all of it before), a green tick when
  collected, a gold ring for today, faded and padlocked when not reached, faded when missed (a calendar's past day nobody claimed),
  everything inside set down to fit (`FittedBox`) and never cut, and a `Semantics` label saying its day, its reward and its standing — and "Next reward: 1 diamond"
  (`nextReward`: today's while it waits, tomorrow's once collected, none past the period). The dates on the tiles are the server's
  `today` counted along the run or the period (`dateOfDay`) — labels only; every decision is the server's. **The celebration**
  (`_RewardCelebration` → `_GrantsSummary`, keyed `rewards-celebration`): the lobby's reward overlay with a gift for its hero, "Daily
  rewards collected!", one line per grant ("+ 20,000 chips", "Clapping Hands emoji", "(already yours)" after an item the player had;
  `rewardPrizeLabel`) and the programs and days they came from, closed by its key or a tap; shown ONLY from a claim's answer with
  something in `granted` — reopening the app never shows a reward twice. 42 strings in all five languages (the weekdays' short names
  among them). `test/reward_programs_test.dart` (40: the wire, the words in every language, GameState's every path — a read on the
  lobby's appearance and every `session:ready`, the claim only on the player's tap —, the screen's Collect key, the chip's words and
  its place beside the Lucky Draw and clear of the foot's keys at 592x360–1280x800 ×1.0/×1.25 in both themes, the screen's headlines,
  tiles, next reward and what a screen reader hears, no line cut at 640x360 ×1.25 in all five languages and both themes, the
  celebration's lines and close, and nothing raised by a claim that gave nothing).
- **The Lucky Draw** (owner, 24 Sep 2026; `screens/lucky_draw_screen.dart`, server side §7.2/§7.3). **The lobby key** is a
  `_CornerChip` alone in the bottom-left corner (`_LuckyDrawChip`, keyed `_luckyChip`, so `lobbyNoticeArea` keeps a toast off it; the
  daily bonus stood beside it until 30 Sep 2026): LUCKY DRAW over "Spin now" while a spin is due (gold, a small drawn wheel —
  `LuckyWheelGlyph` — turning a third of a turn now and then, as the hourglass breathes), else the wait as `HH:MM:SS` running past 24
  hours (`formatSpinClock`); a tap opens the draw either way. Hidden while `GameState.luckyDraw` is null — no draw open, or a server
  that predates it (404) — which `loadLuckyDraw()` reads at every sign-in and again when the screen opens. **The screen**
  (`showLuckyDraw`, a `showGeneralDialog` page risen from the foot like the store; `PopScope` holds it while the wheel turns): the
  owner's Lottie on the left (`LuckyWheel`, `assets/animations/Lucky Draw Spinner.json`), the six prizes two to a row on the right
  (slot number, the wallet's mark, "10 Lakh chips" / "4 hammers" / a picture's name / "No prize"), and the key: **SPIN NOW** · **SPINNING…**
  (from the tap until the prize is shown, disabled) · **NEXT FREE SPIN** over the clock (disabled; NEXT SPIN until the polish below); the header says "One free spin every 3
  days." **The client draws nothing**: the tap sends `POST /api/lucky-draw/spin` with a fresh uuid `actionId` (retried once with the
  SAME id after a transport failure, as the missile trade is), the wheel — since the polish below from the tap, until then only once the server had answered — turns five
  turns and on to the slot the server named in **6 s along `LuckySpinCurve`** — its speed a smoothstep up to full over 1.5 s, full speed (under
  two turns a second) for 0.9 s, then (1 − x)³(1 + 3x) down over 3.5 s, a long creep to rest (owner, 24 Sep 2026, on the first cut,
  which left at full speed and slowed from the first frame: "not smooth … at least run for 5-6 seconds, slowly increase its speed and
  the end slowly reduce its speed") — a few degrees off centre (`luckyNudge`, looks only). The Lottie and the six badges are built
  once per size (`_artAt`/`_badgesAt`, each badge behind a `RepaintBoundary`), so a frame of the spin only moves them. **How the file is
  steered**: its wheel is layer 12, the one layer named `L` whose rotation is keyframed (721° → 2526°); a `ValueDelegate.transformRotation`
  on `['L']` answers `LuckyWheel.angle` for a native rotation of a turn or more and the layer's own value otherwise (the other `L`
  layers stand at 0° or 20°), so the Lottie and the Flutter prize badges on its wedges (ivory discs at 57 of the wheel's 84 units,
  `LuckyWheelGeometry`) are drawn from the same angle and cannot disagree; slot n is wedge n−1, centred 60(n−1)° clockwise from the
  top, under the needle when the angle ≡ −60(n−1). Only frames 0–150 play (the rim's lights, looping); the rest flash the file's own
  first wedge whatever was won, so they never do, and the layers named `S` (a currency glyph printed on that wedge, and the sparkles)
  are hidden. **The rim's bulbs blink for as long as the wheel is on screen** (owner, 24 Sep 2026: "The wheel outer dots should blink
  always"): the file turns each between an ivory and a pale yellow every half second, two rings out of step, which on a gold rim barely
  read, so a `ValueDelegate.color` on `['L', 'L', 'G', 'F']` (the bulbs' precomps only — the wedges' ivory is out of its reach) draws
  the yellow lit (`luckyBulbLit`, lemon) and the ivory unlit (`luckyBulbUnlit`, rust) — `luckyBulbColour` — and the rings chase.
  `frameRate: FrameRate.max` and no `RenderCache`: the wheel's own keyframes change every frame of the loop, which is
  what repaints it, and a cache would replay frames without the server's angle. **The prize** (`_LuckyPrizeCard`, built from the
  lobby's reward celebration — scrim, `Fireworks`, `PremiumSurface`, `SpinningChip`): "Congratulations! You won 10 Lakh chips", the
  wallet's mark in its ink, a picture as itself with "Yours for 50 days" (or "It is already yours…") and **Wear it** / **Use it**
  (`chooseAvatar`/`chooseTablePicture` — winning never puts it on); the empty slot says "Better luck next time!" with no fireworks.
  The wallet takes the spin's `user` at once and a picture prize re-reads the catalogues. 26 strings in all five languages.
- **The Lucky Draw polish** (owner's brief, 26 Sep 2026: "make THIS design look significantly more polished, premium and
  exciting while preserving the existing visual identity" — header, wheel left, six prizes right, key at the foot; presentation
  only, the server still draws). The screen is split into `widgets/lucky_wheel.dart` (the geometry, the motion, `LuckyWheel`,
  `LuckyWheelGlyph`), `lucky_prizes.dart`, `lucky_spin_key.dart` and `lucky_reveal.dart`, all re-exported by the screen. **The
  wheel turns from the tap** (it waited for the answer until then): `LuckySpinMotion`, the `Simulation` of an unbounded
  controller, gathers speed along `LuckySpinCurve`'s smoothstep (1.5 s) and holds full speed (641°/s, the curve's 5.5 turns in
  6 s) until the server answers; `landOn` then picks the one moment to leave full speed from which the curve's run-down (3.6 s)
  rests exactly on `luckySpinTarget` — five turns at least, one more per 360° a late answer costs — so the answer shows nowhere
  in the turn, and a prompt one rests the wheel 5.7–6.3 s after the tap; a refusal or no answer (`stop`) runs it down from its
  own speed (≥ 0.5 s) with no prize and gives the key back at rest. At rest the winning wedge lights in two beats to a resting
  glow (`luckyWedgeLight`; warm gold — white read pink on the red wedges) and its tile swells, glows, pops its mark and takes one
  shine while the others drop to half (`LuckyDrawScreen.litFor` 1.1 s) — the empty slot is only outlined, pale, and ringed in
  grey: where the wheel stopped, not something won; the prize follows `revealAfter` (900 ms) later. The wheel stands ~10%
  larger (the canvas window tightened to the art, 48..252 × 26..274, and 8dp of chrome given back: the rim 198.5 → 217.7dp at
  640x360) over a stage it casts — a gold light round the rim that breathes (`Motion.breath`, ±16%) only while a free spin
  waits, brighter while it turns and low while it recharges (`LuckyWheelLight`), the stand's shadow and, by day, the disc's
  own; the file's cream needle and cap are left out (`luckyHubColour`) and drawn again in struck gold, outlined, shadowed,
  under a domed cap with a glint. **The key** (`LuckySpinKey`, the one widget that watches the one-second tick; the
  screen `select`s): SPIN NOW in `AppTheme.goldFace` with the wheel glyph, a gold bloom and `PressScale` (`LuckyGoldKey`);
  SPINNING… and NEXT FREE SPIN (`luckyNextFreeSpin`) over the server's clock and an hourglass, on the plaque with a gold
  hairline; FREE SPIN (`luckyFreeSpin`) tags the title while a spin is due. **The tiles** lead with the figure over the wallet's
  word (`luckyPrizeParts` cuts both out of the one sentence per language, so "1 hammer"/"4 hammers" and a Bengali classifier
  keep their grammar; one line where the tile is too short for two; the empty slot in the quieter label role), the mark in a
  well tinted with its wallet's ink (`luckyPrizeInk`: gold, copper, blue, coral, a grey for the empty slot) that gives way to
  the words on a narrow tile, the slot's number quiet in the top-left. **The page** is obsidian glass by night and the lobby's
  card warmed to cream by day (on opaque white: the lobby ghosted through), gold along its top edge, at most 1040×640 on a
  tablet. **The reveal** arrives from 0.9 and settles, its mark popping over a swelling gold light, the prize figure-first,
  its action on the gold key and Close in neutral ink; the empty slot is a shrug —
  "Better luck next time!" over "No prize", no fireworks, no overshoot. `test/lucky_draw_test.dart` (44: the motion millisecond
  by millisecond for every answer time and slot, the wedge's beats, the hub's colours, the parts in all five languages, the
  tile's two layouts, the gold key, tap to rest in ≈ 6 s with no jolt at the answer, the win lit in its tile alone before the
  reveal, the empty slot's grey ring, refusals at once and mid-turn, the wait, the wheel's size, and 640x360 and 592x360 ×1.25
  in all five languages with no tile's words cut); pictures by hand, `test/lucky_shots.dart` (every journey at 640x360,
  891x411, 592x360, 915x412 and 1280x800, both themes, ×1.0 and ×1.25, and Hindi at 640x360 and 592x360;
  `--dart-define=SHOTS_DIR=… ICON_FONT=…`, as `table_shots`).
- **Table** (rebuilt around the felt on 10–11 Sep 2026 — `fb47ba4`, `b83b273`, `81a5981`; the bar
  across the foot and the cloth under it are both gone — a table came back under the seats on 24 Sep 2026, the casino
  table below — and the screenshots in `docs/play-store/` predate all of it). `_TableScreenState.build` **watches nothing** (a per-second Scaffold rebuild
  destroyed the open drawer) and sets **`resizeToAvoidBottomInset: false`** — the soft keyboard used
  to squeeze the rail and the chat panel until both painted overflow stripes; the chat drawer lifts
  its own composer over the keyboard and drops its title while typing.
  `_LeftPanel {menu, chat}` shares one `drawer`. The menu (`_TableDrawer`) heads with `_ThemeFlip`, a one-tap
  light/dark key, where the table code was (owner, 13 Sep 2026); only a **private** table still shows `Table <code>`
  (`RoomState.isPrivate`, from the wire's `isPrivate`), since that code is how friends get in. **Its small-caps line is
  the category alone** — `SEEN`, or the poker variant's name at a poker room — beside the `_SeatedFor` clock: the
  `· hand N` it carried went on 24 Sep 2026 (owner, from a phone screenshot of "SEEN · han… 0:05:25": "some hand info
  text is visible, remove that text from UI"), and the two branches became ONE `FittedBox(scaleDown)` line — the poker
  name was already shrunk to fit, and `VARIATION` alone still ellipsised on a 640dp phone at ×1.25 — so the line is
  never cut; `test/table_drawer_test.dart` holds both headers to that at 640x360 x1.25.
  **There is no `_ActionBar`.** The keys live in the corners they are pressed in: the lobby's `ShopButton`
  top-left (13 Sep 2026, replacing the gold `+` that headed the rail; it opens the store on Chips), `_SideRail`
  (menu, chat — each key fills the rail so the target stays
  ≥44dp, which is why they sit flush to the screen edge on a 360dp phone), `_PackKey` bottom-left with the Missile key directly above it, and `_ActionCluster` bottom-right (`Force Sideshow` and
  `Sideshow` over `− Chaal +`; Chaal is dark on the player's own turn when they cannot pay the chaal — `GameState.canChaal`, an empty server ladder — and keeps showing the price, owner 14 Sep 2026). **The quick messages are a tab of the chat drawer** (owner, 14 Sep 2026; they had a third rail
  key and a `_QuickDrawer` of their own): `ChatDrawer` heads with two `ChatTab`s and the block key after them —
  **Quick messages first, then Table chat, then Block** — and **opens on Quick messages every time** (owner, 27 Sep 2026:
  "when i click chat message icon the first tab should be quick message, then table chat, then block"; until then it
  opened on the chat, Table chat the first tab), and sends a quick line through `sendChat` and closes, as a typed one does.
  The block key toggles the players page and a second tap goes back to the tab it was opened from; a long-press on a
  chat line still opens it. Since the drawer now opens a tab away from the conversation, **opening it no longer clears the
  unread count** (`_open` in both felts called `markChatRead`): the lines stay counted on the rail's key and on the Table
  chat tab (a gold `Badge`, `ValueKey('chat-tab-unread')`) until that tab is up, and the drawer clears them there, after
  the frame, including lines that land while it shows. **Every line of the chat log shows when it was sent** (owner,
  27 Sep 2026: "show timing in every chat message in table ui"): `ChatTime`, from `ChatMessage.at` — the server's stamp,
  never the phone's receive time — in local hours and minutes through `MaterialLocalizations.formatTimeOfDay`
  (`chatTimeLabel`), following the phone's 24-hour setting (`MediaQuery.alwaysUse24HourFormatOf`: "3:07 PM" / "15:07";
  the app has no Material localisations for its four Indic languages, so the 12-hour form says AM/PM in every
  language), in the quiet tier's type (`TableType.metadata(figures: true)`) at a firmer night ink (`ChatTime.inkAlpha`:
  0.56 by night, where the tier's 0.46 measured 4.4:1 on the dark drawer; the tier's 0.68 by day). Every time ends at the
  right edge, one width
  (`ChatTime.widthFor`, the widest time of the day in that format and text size): a player's words keep the drawer's
  whole measure and the time stands at the right of their LAST line on its baseline (`ChatTime.liftOver`) — an inline
  blank as wide as the time ends the words, so the last line makes room or gives the time a line of its own. An emoji
  line (`_EmojiLine`) carries it at the right of its row, level with the emoji, and never cuts the sender's name for it:
  when name, emoji and time cannot share a row the name takes the whole row (and a second line where even that is too
  narrow) and the emoji and its time stand under it — beside a fixed time column "Guest0E00B" was cut at 640x360 ×1.25.
  The emoji's `Semantics` is its own node, so the time is not read into "Ravi sent Laughing". A `ChatSystemLine` keeps a
  time column at its right and may take three lines (two before), so "<a 24-letter name> joined the table" is whole at
  592 and 640dp ×1.25. A line with no stamp (`at` 0) shows none. Seat bubbles carry no time.
  `test/chat_time_test.dart` (the order, the unread count, 12 and 24 hours, the system and emoji lines, the time's
  contrast in both themes, emoji and joined lines under names up to 24 letters, 592x360 / 640x360 / 915x412 at x1.0 and
  x1.25 in all five languages and both themes); pictures by hand, `test/chat_shots.dart`.
  **Each quick message stands in a box of its own with an icon for its meaning** (owner, 24 Sep 2026: "in quick chat
  message also add some icons, and every message of quick message should be in some box"): `QuickLine` is a tinted, flat
  `GlassCard` (`Radii.md`, `Space.sm` apart, `Space.lg` in from the drawer's sides, the whole box the target at
  ≥ `Dim.minTouch + Space.md`) with `quickMessageIcons[i]` at its left — a const list in `table_chrome.dart` index for
  index with `Strings.quickMessages` (eye-off for play blind, bolt for play fast, trophy for how you win it, … help for
  help me), held to the list's length in every language by `test/chat_drawer_test.dart`; the cooldown still greys the box
  and counts the seconds on it. **The player orders the quick messages themselves** (owner, 25 Sep 2026: "make sure user can
  drag and reorder the quick message in UI … save that order in UI only"): the page is a `ReorderableListView` keyed by
  each line's index; a box drags at once by the grip at its right (`QuickDragHandle`, six dots, which takes its own taps so a
  missed drag says nothing to the table) or after a long-press on the rest of it — the two starters side by side, never
  nested (`QuickLine.reorder`), since an outer one takes the pointer from the grip's. The order is indices into
  `Strings.quickMessages`, so it holds in every language: `GameState.quickMessageOrder` (`normaliseQuickOrder` — a later
  build's added line joins at the end, a dropped one is skipped), `moveQuickMessage`, and SharedPreferences
  `quickMessageOrder` (`state/quick_message_order.dart`), read in `start()` (`restoreQuickOrder`); nothing reaches the
  server and the words sent never change. **The player adds lines of their own** (owner, 25 Sep 2026: "Add a button in quick
  message drawer so that when user clicks and type and save that typed message will be seen in quick message list, add
  icon in custom saved quick message … when user restart the app, make sure ordering and custom message should be
  preserved in phone"): an **Add message** key at the page's foot (gold on the drawer's well — the outline theme's grey
  read as switched off) opens a field with Save/Cancel where the chat page keeps its composer, so it rides above the
  keyboard the same way — in the drawer, never a popup. Saved (`GameState.addCustomQuickMessage` → `QuickAddResult`), the
  line goes to the TOP, wears `customQuickMessageIcon` (a pencil note), is said with one tap and dragged like any other, and
  carries a bin (`QuickDeleteKey`, its own taps; set lines have none). It is kept as the server will read it
  (`cleanQuickMessage`: control characters spaced, spaces collapsed, trimmed, cut to 140 — CHAT_MAX_LENGTH — never between a
  surrogate pair); a blank line is ignored, one the list already says (a set line in this language, or their own) is
  refused with a note, and a player keeps at most `maxCustomQuickMessages` (10). Order keys are `"<index>"` for a set line
  (so an order saved before this reads as it did) and `"c:<uuid>"` for their own; their lines live in SharedPreferences
  `quickCustomMessages` (JSON, oldest first) beside `quickMessageOrder`, both written on every change and read together by
  `restoreQuickOrder`, so a restart finds the lines and their places. `test/quick_message_order_test.dart` (a drop settles
  only frame by frame — one long `pump` runs the drop animation once; the "restart" is a new GameState reading the saved
  preferences). **Blocking is a page of the drawer, never a popup** (owner, 24 Sep 2026: "when user click
  on block button do not show pop up, instead show block button of players in drawer itself and in chat messages DO NOT
  SHOW ANY unblock message, only message should appear"): the header's block key toggles a third page,
  `_ChatView.players` — `ChatPlayers`, every other seat from `room.seats` (rebuilt live, so a player who leaves drops
  off it) with one outline `GlassButton` whose label follows `isBlocked` (Block ↔ Unblock, nothing asked either way),
  `blockNobody` when the viewer is alone — and a long-press on somebody else's line opens the same page; the key is lit
  while the page is up or a block is in force, since the chat page now shows the messages and the composer only.
  `showBlockPlayers`, `confirmBlock` (the two `GlassDialog`s) and `_BlockedRow` ("Blocked: Name · Unblock") are gone,
  with `blockPlayerQ`/`blockBody`/`blockedLabel` from all five maps; `test/chat_drawer_test.dart` mounts the drawer at
  640×360 ×1.25 in all five languages, counts routes through a `NavigatorObserver` (none pushed) and finds every box,
  icon and key.
  **The chat key and both tabs play Lotties** (`_RailLottie`, `animate` only on the selected tab):
  `assets/animations/Message.json` (a speech bubble) and `assets/animations/Quick message.json` (an envelope sending a
  paper plane), both drawn in the theme's ink by `ValueDelegate`s — onSurface at full strength, black on the light theme,
  white on the dark — with the envelope's disc hidden and its letter in the surface colour (`_envelopeInInk`, matched
  by layer and group name, pinned by `test/message_glyph_test.dart`). The envelope's canvas is drawn at 45dp inside a
  24dp layout slot (`OverflowBox`), so it is larger than the bubble without growing its tab. The chat cooldown
  replaces the rail glyph with `_ChatCountdown`, and each quick line counts it down. `Quick message.json` is a copy flattened by
  `tools/lottie/flatten_orientation.py` (its flap opened with `rx`). **The Force key** reads "Force Sideshow" on two
  lines (`_MachinedKey.stackLabel`) beside `assets/animations/Hammer.json` (`_MachinedKey.glyph`), which swings only
  while the key can be used; no cost line — the confirmation states the hammer.
  **Missiles** (owner, 14 Sep 2026; rules in §6.1): the Missile key over Pack carries, as its second line and as Chaal carries its bet, the rocket mark and **the missiles the player HOLDS** (owner, 24 Sep 2026: "Missile count is not updated in missile button when user have used that missile" — it wrote the constant 1 a shot spends, `missileCost`, so it read 1 for ever after the only missile was fired; now `user.missile`, which the fired missile's ack sets and a store pack raises, the same figure as the wallet pill, dropping to 0 the moment the shot is acknowledged because `_MissileKey` watches GameState; `missileCost` survives in `GameState.hasMissile`, which still mutes the key, and in `test/missile_wallet_test.dart`; a wider count scales down in `MachinedKey`'s FittedBox — `test/missile_key_test.dart` has the shot, the pack and a three-figure count at 640x360 ×1.25), then a chip and the chips a show would cost the player (`_MissileLine`, drawn through `MachinedKey.detail`) (`GameState.missileChips`: the server's first rung on turn, else the stake's chaal; owner, 14 Sep 2026 — §6.1's server refuses a missile to a player short of it), plays `assets/animations/Missile.json` (a copy
  with its one `loopOut()` baked; the nose points up-right, frames 30–60 loop) while `canMissile`, is greyed with no
  missiles and then offers the store's **Missiles** tab (between Hammers and Pictures, diamonds for missiles: 1 for 15, 5 for 73, 10 for 140, 20 for 220), and asks
  first (`_fireMissile`). Every viewer sees the volley (`state/missile_strike.dart`, `widgets/missile_flight.dart`): one
  missile from the firer's pod to each player still in, 70 ms apart, **1.3 s in the air**, then
  `assets/animations/explosion.json` on each pod for **0.44 s** (its own length), and only then (`MissileTiming.reveal`)
  are the held `game:showdown`/`game:handEnded` let go — the cards turn over and the winner is celebrated, never over the
  blasts (owner). The table's wallet pill and the lobby bar count diamonds · hammers · missiles. `_WhileStillOpen`, which
  closes a Force Sideshow or missile question when the move is taken away, pops only while its dialog is still the current
  route: firing ends the hand while the question is still animating out, and its unconditional pop used to take the table
  with it — a black screen on the phone that fired (14 Sep 2026).
  `_Felt`: seats on the `SeatRing` (2..5 places, the casino table below), viewer at view seat 0, `Dim.podW(feltW, feltH) =
  min(feltH*0.270, feltW*0.150).clamp(60,140)`, pods clamped inside. Overlays: `_CategoryTag`,
  `_Pot`/`_PotPulse` at `_potDy` 0.46, `_Status` at 0.325 (0.28 until the casino table's far rail, below), `_SideshowLink/Prompt`, `_Showdown`.
  **`_Showdown` is now only `_WinnerBurst(focus: winner)` + `PotFlight`** (`widgets/pot_flight.dart`, rebuilt 14 Sep 2026 when the owner found the winner's coins not smooth: each of the 9 chips makes the same 0.9 s trip 60 ms behind the one before, so none overtakes — the old `_PotToWinner` gave each what was left of one 1.7 s clock — fades and grows in at the pot and out on the seat, drags no ghost copy, and the run is ONE `CustomPainter` repainting off its controller through `PokerChipBrush` instead of 18 widgets with an Opacity and a rotated raster each; `test/pot_flight_test.dart`) — since 12 Sep 2026 the
  burst is **`assets/animations/Fireworks.json` through `Lottie.asset`**, played ONCE per win (keyed
  on `handNo`, so the one-second reward tick cannot restart it) and centred on the winner's seat;
  the hand-painted `Fireworks` widget stays in `widgets/fireworks.dart` for the lobby's win banner.
  **Do not hand it an animated SVG**: `flutter_svg`'s compiler has no `animate`/`animateTransform`
  handling, so one lands on the felt as a single still frame with nothing logged to say why. The scrim and the banner
  over the middle of the table were removed (owner, 10 Sep 2026): the scrim greyed every revealed
  hand a player wanted to compare against, and the result is announced on the winner's own pod by
  `_WinnerFlash` instead. `handLive` gates bet pills. While `you.unfundedDeadline` is set, `_Status` shows `buyChipsToStay` (amber, counting down) in place of the waiting/starting line.
- **The missed-turn warning** (owner, 27 Sep 2026: "warn before the kick"; `widgets/missed_turns_notice.dart`). A turn
  clock running out packs the player (poker: checks where free, stands pat, else folds) and counts a miss; until
  then nothing on the table said so — `you.missedTurns` reached only `TurnBuzzer`'s vibration. Now `_Status` (and
  `_PokerStatus`) show `MissedTurnsNotice`, a small charcoal `Plate` in the status slot (the poker felt's pocket
  right of the pot during a hand), drawn from `you.missedTurns` / `you.maxMissedTurns` alone
  (`missedTurnsWarning`): after a miss "You missed your turn — auto-packed" over "Missed turns: 1 of 3" (poker:
  "You missed your turn", or `pokerTimedOut` for a clock fold), one short of the kick "Last warning" over "One
  more missed turn and you leave the table" (the alarm red; the first in the tax amber); nothing when the count
  is 0 or the table never shows anybody out. **Each is said for 5 s** (owner, 27 Sep 2026: "missed turn text show only
  for 5 seconds only and warning text also show for 5 seconds only"; `GameState.missedTurnsNoticeFor`,
  `missedTurnsNoticeShowing`): from the first snapshot that carries a new count at this table (`_trackMissedTurns`, a
  timer), then the slot goes back to its line; a snapshot repeating the count (a move, a reconnect) raises nothing, the
  next miss raises it again, and a count back at 0 (any move, a sideshow answered, a variation or 5-Card three chosen,
  §6.1) resets it. Below the seat held for a
  purchase and the variation's notices (Teen Patti) or the draw / play-or-fold asks (poker), above the waiting and
  starting lines. **Where**: the status slot at a five- or three-place table; at a table with a HEAD seat (two and
  four places) a pocket right of the pot (`_Felt.headNoticePocket`, `_PocketNotice`), from under the head seat's pod
  — and the turn's ring round it, `SeatPod.turnRingOutset` 5.5dp a side, the pod hanging from its top — to the key
  cluster, and from the pot's slot to the right-hand seat's column (centred on the status line there it stood on the
  head pod); on the poker felt its own band of the pocket, from under the top-right seat's column
  (`SeatRing.columnShare`) to the keys (`_PokerFelt._noticeBand`; centred on the pocket it stood on that seat's In
  Pot capsule in the Indic languages at ×1.25 from 844dp up). Measured at 1.35× (the pocket 1.9×) the slot's width so
  its title breaks in two — wider where a line would need a third and be cut (`MissedTurnsNotice.wrapWidthFor`:
  English at 592x360 ×1.25, Bengali and Punjabi) — then scaled to the slot and to `maxHeight` (the room between the
  slot and the pot's plate, `_Felt.statusRoom`, or the pocket's band), so it never reaches the pot, a key, a card, a
  seat or the winning tax's pill and nothing on it is cut short. Strings
  `autoPacked`, `missedYourTurn`, `missedTurnsCount`, `lastWarning`, `missOneMore` in all five languages
  (`autoPackedOne`/`missedTurnsLabel` went); the idle kick's English `kickedIdle` now says "in a row" as the other
  four did. `test/missed_turns_test.dart` (the count 1 → 2 → 0 on both felts, 640x360 ×1.25 in all five
  languages both themes with the Noto fonts, and every phone size 592x360–915x412 ×1.0/×1.25 in all five languages
  at tables of two to five places and on the poker felt, no line cut); scenes 36–41 in `table_scenes.dart` (40 and
  41 the two- and four-place tables).
- **The table polish** (owner's brief, 24 Sep 2026: "a polish pass, not a redesign" — type scale, spacing, clipping,
  subtle accents, responsiveness, the keys' hierarchy; presentation only, nothing of the lobby's). **One type scale**,
  `theme/table_theme.dart`: `TableType` roles taken from the theme's ramp — `pot` 20/w700, `modalTitle` 17, `system`
  15 (`strong` w700: the sideshow question, the PACKED plate), `item`/`chips` 15, **`primaryAction` 14/w700**,
  **`secondaryAction` 13.5/w600**, `info` 13.5/w500, `modalBody`/`chatText` 13.5, `chatName` 13.5/w700, `boot` 12/w700,
  `label` 12, `actionDetail` 12, `metadata` 12/w500 in `inkLowOn`, `count` 12 (small 10.5), `caps`/`handName` in tracked
  capitals, every figure tabular — and `SeatType` (`TableType.seat(theme, podW)`), which scales a seat's name, YOU, the
  BLIND/SEEN tag, hand name, status line, stack, bet, In Pot, speech and WINNER from the pod's width over a floor (name
  10, stack 11.5, status 9, speech 12). No widget on the table picks a font size of its own; `seat_pod.dart`'s
  `_kName`/`_kStack`/… constants are gone. **Spacing** — `TableSpace`: every corner control stands `edge`
  (`Dim.feltPad`) in from its safe edge and `gap` (`Dim.gap`) from the top or foot, so Shop and the wallet (`TopCorner`,
  on both felts) line up with Missile/Pack and the key cluster; `drawerW` (w × 0.44, 280–400 — 282dp on a 640dp phone,
  where the app drawer is 260) for both table drawers; a menu row is `rowHeight` 48 with its glyph in a 24dp slot.
  **Scrims and ambient light** — `TableScrim.drawer` (ink900 at 0.40, `drawerScrimColor` on both table Scaffolds),
  `.dialog` (ink900 at 0.45, `showTableDialog` — every dialog raised from the table), `.picker` (the variation and
  5-Card pickers' gradient, figures unchanged), all under Material's black 0.54 that turned the light room to grey mud;
  `TableAmbient`: the room's drifting chips at strength 1.8 (2.6 put a 42% grey disc behind the keys by day), a seat's
  colour orb soft-edged at 0.46 / 0.34 outside the glass (dark / light; 0.95 before), 0.74 of the pod and spilling a
  tenth, and the turn ring breathing every 1150 ms (780) with a fixed box — only its colour and stroke move. **The
  console is not all equal** — `KeyRole {primary, secondary, destructive, special}` on `MachinedKey` (`primary: true` is
  shorthand): PRIMARY Chaal (a poker room's Check/Call, Draw, Play) is struck gold (`AppTheme.goldFace`, the Shop key's
  face), named in `primaryAction` in charcoal, and the ONE key that breathes (`KeyPulse(breathe:)`); SECONDARY Sideshow,
  Force Sideshow, Show, the ± steppers (and poker's Bet/Raise) are the plaque with a STILL glow while on offer;
  DESTRUCTIVE Pack (and poker's Fold) wear the error ink on glyph, name and hairline and never glow; SPECIAL Missile (25 Sep
  2026) is the plaque washed with the missile's coral (`edge`, `missileInkOn`), its hairline coral live or dead, a still
  coral glow on offer, its name in the surface's ink. Every dead key and stepper fades to `deadKeyOpacity` 0.5 (0.42 until
  25 Sep 2026, which left a dead key's name under 3:1 on the light theme), glyph and words together (a dead key's ink is
  the surface's). `KeyPulse` keeps one tree shape
  and stops its controller while nothing breathes. **Drawers and dialogs** — `MenuRow`: a row that acts names itself in
  the full ink (Leave table in the error ink), a row that only reports (Your chips, Boot, Max pot) in `TableType.info` at
  `inkMed` beside its gold figure; `dialogTitle`/`dialogBody`/`dialogActions(destructive:)` — the leave question's glyph
  and its Leave key in the error colour, every other question's key gold, the acting key's word in `inkOnFill`
  (charcoal on the dark theme's salmon error, where white read 2.8:1; white on the light theme's brick) and the quiet
  key (Stay, Cancel) in neutral ink, not the scheme's emerald. The PACKED plate is charcoal in both themes, so it says
  PACKED in `TableInk.alarm` (the dark scheme's red) in both — the light brick read under 3:1 on it. Chat lines now
  follow the phone's text size (a `RichText` ignores it unless given the `textScaler`; they were fixed at ×1.0), so at
  ×1.25 on a 640dp phone fewer lines fit and the list fades at the top. **Chat** — a line the table wrote (no
  `userId`: joined, left) is a centred, muted `ChatSystemLine` with its time at the right (27 Sep 2026; it was signed
  "Table:" in the colour an empty id hashed to, a red); a player's line is signed in the full ink at w700 (the viewer's in gold), their colour kept in the bar
  beside it; the composer and its hint in the chat's own type; the two tabs keep their names on up to two lines at one
  measured height (`ChatTab.heightFor`). **Clipping** — the table has no carousel; what scrolls, fades:
  `widgets/edge_fade.dart` `EdgeFade` masks a scrollable's edge only while there is more beyond it (the menu, the chat,
  the quick messages, the players page; a reversed list fades at its top), one `ShaderMask` whatever it shows so the list
  keeps its place. The store's tab strip, cut at whole tabs, was left alone (it is the lobby's sheet too).
  `test/table_polish_test.dart` holds the ladder, the seat scale, the tokens, the key roles on turn and off, the one
  active turn ring, the drawer's width and scrim, the destructive leave dialog, the chat's signatures, `EdgeFade`, and
  every state at 640x360 ×1.25 in all five languages with every key on screen and clear of the others. The scenes are
  `test/table_scenes.dart` (room:state JSON; 23–25 are the 2-, 3- and 4-place tables), which the screenshot harness
  `test/table_shots.dart` — not part of `flutter test`; `flutter test test/table_shots.dart --dart-define=SHOTS_DIR=<abs dir>
  --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf` — pictures at 640x360,
  732x412, 844x390, 891x411 and 915x412, both themes, ×1.0 and ×1.25, in Hindi, behind a camera cutout, and at a narrow
  592x360.
- **The casino table** (owner's brief, 24 Sep 2026: "transform the current gameplay screen from a mostly flat background
  into a more recognizable premium casino table experience"; presentation only — no game logic, networking, betting,
  card logic or state management changed). `widgets/casino_table.dart`: `TableGeometry.of(feltSize)` is ONE stadium at
  fixed shares of the felt — x 0.012..0.988, y 0.24..0.945, semicircle ends, a rail of 0.034 of the felt's height held to
  9..18dp — laid out to MEET the seats where they already were (the five places the felt was tuned around, now the
  `SeatRing`'s, below): the far rail runs under the two top pods, the
  ends under the side pods, the near rail under the viewer's pod and hand, and the pot (0.46) sits on the cloth. Nothing on
  the felt moved for it but the waiting line: the far rail at 0.24 lies between the category tag above it (0.075, off the
  table) and the waiting line, which came down from 0.28, where it straddled the rail's inner edge, to 0.325 on the cloth
  (25 Sep 2026) — with the two-line notices that share its slot (who is choosing a variation or their cards, which
  variation was chosen) on the cloth too and 15dp or more above the pot at 640x360–915x412, ×1.0 and ×1.25, English and
  Hindi (`test/casino_table_test.dart`). `CasinoTableSurface` paints it once into its own layer (`isComplex`,
  `willChange: false`; every soft edge a gradient or a blurred `RRect`, the one blur Impeller draws analytically): by day
  a pearl rail lit from above round a soft teal cloth with a thin champagne rim; by night a graphite rail round a deep
  teal cloth that falls to near black, a subtler gold rim and a controlled cyan glow — `CasinoTableColors`
  (`theme/theme_colors.dart`), a `ThemeExtension` on both themes, so one painter serves both and the theme's cross-fade
  carries the table. **Each Teen Patti game lays its own cloth** (owner, 25 Sep 2026: "keep different table color for
  seen, blind, variation gameplay"): `TableCloth {centre, edge, line, lip}`, `TableCloth.tinted(accent, brightness)` takes
  only the HUE of the game's accent (`AppTheme.paletteFor` — the lobby card's and the tag's colour, so the three can never
  disagree) and lays the same lightness and restraint on each, never saturated (0.40 at most by day, 0.42 by night) — a
  soft champagne, a pale cyan, a lavender by day; a deep olive-gold, sapphire, plum by night (a yellow leans a few degrees to
  amber there); `AppTheme.tableColours(scheme)` fills `CasinoTableColors.cloths` for `AppTheme.clothGames` (seen, blind,
  variation), `clothFor(category)` answers the game's cloth or the fallback `cloth` — a soft teal, `TableCloth.tealHue`
  172, in the same tones (25 Sep 2026; emerald before) — for any other, and `_Felt` passes `room.category` (a private
  table is its game's too). **Depth** (owner's polish brief, 25 Sep 2026: "subtle layered depth: outer shadow;
  champagne/gold outer rim; subtle inner rim; soft cyan/teal felt surface; very subtle inner shadow ... Do NOT make it
  photorealistic"): a tight contact shadow under the soft one, the rim, an inner rim — a thread of the rim's champagne
  just outside the seam — and an inner shadow all round the cloth's edge (a blurred band of the cloth's `lip` outside
  it, clipped, so only its soft inner half falls on the cloth), all in the one static layer.
  A short phone (`Breaks.isShort`) drops the line printed on the cloth and the glow. The table's words
  keep their inks: charcoal on the pale cloths, white on the dark ones, ≥4.5:1 on every cloth and the rail alike
  (`test/casino_table_test.dart`, which also samples the painted pixels in both themes for every game, holds each cloth
  to its game's hue and every cloth away from red, and checks which cloth each table — a private one too — lays). `TableAmbientEffects` replaced `_AmbientLamp`: the same breathing lamp, clipped to the cloth
  now, and a warm light on the near rail in front of the viewer while it is their turn — its own layer, repainting every
  frame while the table's never does. Paint order in `_Felt`: the table, the ambient light, the deal and bet flights (the
  deal still leaves from just above the middle of the table, 0.42, as it always did), the paid table picture
  (`_TableCentrepiece` — over the cloth), then the tag, the pot, the status line and the seats; the room's `DriftingChips`
  drift under the table and show round it. **Poker rooms have no table**: their board (0.29) and 3-Card Poker's dealer
  hand stand where the far rail goes, so `poker_table_screen.dart` was left as it was. A host behind the far rail — an
  illustrated dealer, a layered SVG animated by the table's state — was tried with the table and removed on 25 Sep 2026
  (owner: "remove women from the table"); she is recoverable from commits `6a01773`/`a6314af`.
- **The seat ring and the second table polish** (owner's brief, 25 Sep 2026 — 14 points, presentation only: "Do NOT
  change: game logic, betting logic, networking ... state management, card logic, game rules, existing assets"; "Do NOT
  add the female dealer yet"). **Seats** — `widgets/seat_ring.dart` `SeatRing`, a PURE function of the seat count
  (`config.maxPlayers`, held to 2..5; 0 reads 5), the `TableGeometry` and the pod's width: the viewer on the floor at the
  foot (90°, x `viewerShare` 0.265 — not centred: their hand is fanned to the right of their pod and on a 640dp phone it
  already ends where the key cluster begins — and bounded by the corner keys, `keysLeftFor`/`leftKeysRightFor`/
  `handWidthFor` — `HandFan.widthFor` since the premium cards: the hand clear of the cluster, the pod clear of Missile and Pack, the hand's clearance winning; 10dp left
  of 0.265 at 640x360, 40dp at a narrow 592x360, where the third card lay under the minus key; unchanged from 732dp up),
  everyone else on ONE ellipse concentric with the table (`centreShare` 0.284
  of the table's height down it, `rxShare` 0.922 of its half-width across, `ryShare` 0.23 of its height deep), spread
  evenly clockwise from its left end round the head to its right end — 2: 270 (the head); 3: 180/360; 4: 180/270/360;
  5: 180/240/300/360 — each column pinned by its middle as before. Five places land within a dp of the tuned
  `seatPlaces` (0.05/0.275/0.725/0.95 across, 0.44/0.30 down). A player joining or leaving moves nobody; an empty place
  keeps its chair. **The head seat** (2 and 4 places) cannot hang a column down the table's middle — the tag and the pot
  stand there — so its pod sits `headTop` from the felt's top with its cards and bet BESIDE it (`SeatPod.beside`, unit
  `headUnitWidth` = 2 pods + `headGap`), the category tag moves to its left (`tagSlot`), and the waiting line drops under
  its pod. **The corners bound the ring** (`SeatRing.forFelt`: `keysTopFor`, `cornersBottomFor`): an end seat whose
  tallest column (`columnShare` 2.05 pods, turn ring and text ceiling included) would reach the key clusters rises off
  them, and stays under the Shop key and the wallet; where there is room for neither (a screen under 360dp tall) the keys
  win. On the Android phones the felt was tuned on an end seat rises 6dp at most (891x411; an iPhone's 844x390, where the
  right-hand seat on turn at ×1.25 ended on the cluster's top edge, is the one it was for). The felt, `tableNoticeArea`
  and `tableWalletRoom` all read `SeatRing.forFelt`, so the three cannot disagree; the poker felt has no table and keeps its
  five `seatPlaces`. `test/seat_ring_test.dart`: angles, symmetry, bounds and corners at seven screens (800x340 as
  geometry only), five places against the tuned layout, and the table laid out for real at 2–5 places at 640x360, 732x412,
  844x390, 891x411, 915x412, a narrow 592x360 and a 1280x800 tablet, ×1.0 and ×1.25, with no seat over another seat, the
  pot, the viewer's cards or pod, the tag, the Shop key, the wallet or any key. **YOU** — the viewer's pod glows at
  `TableAmbient.mineGlow` 0.75 (its colour inside the glass and the halo round its turn ring; the ring's gold edge and the
  turn clock are untouched). **Seats** — every capsule on a seat (BLIND/SEEN, a hand's name, the bet badge, In Pot) is cut to
  one corner, `_kCapsule` 0.08 (0.08/0.08/0.10/0.07 before); a name is never cut while it can be set smaller —
  `SeatName` shrinks it to `minScale` 0.78 of its size first ("Vikramaditya" read "Vikramad…" at 640x360 ×1.25), and only a
  name that would need less (24 letters) ends in an ellipsis (`test/seat_name_test.dart`, in Inter). **In Pot** — `SeatType.inPot`, the seat's quietest words:
  0.078 of the pod over an 8.5 floor (the bet is 0.105), the metadata tier's ink (`inPotLabelAlpha` 0.68 by day, 0.56 by
  night; the figure `inPotFigureAlpha` 0.78/0.70) on a lighter capsule (`inPotPlate` 0.6), still ≥4.5:1 on every cloth.
  **Pot** — `_PotPulse` sets the plinth on the cloth with a soft shadow and gives off a steadier gold (0.08 + 0.04 breath at
  rest, the flare as before). **The viewer's hand** stands `TableSpace.handLift` (6dp; since the premium cards at least 6dp, up
  to `HandFan.liftFor` where the pot leaves room — "The playing cards", next) off the floor with one soft shadow
  on the cloth under the fan (none under a packed hand); card backs and faces untouched then (the cards themselves: "The playing
  cards", next). **Left controls** — the rail's
  menu and chat `RailKey`s are machined plaques (plaque, resting champagne hairline, the console's lift), not glass, so
  they read as the table's controls beside Missile and Pack. **Light** — the table's room is pearl (`TableGround.pearl`
  #FAF8F4 closing to `pearlEdge`), not the app's cool grey. `test/table_polish_test.dart` holds the special role and its
  coral glow, In Pot's size and contrast, a dead key's 3:1, and the YOU glow.
- **The playing cards** (owner's brief, 25 Sep 2026: "make the actual Teen Patti playing cards look significantly more premium
  and polished … Do NOT redesign the entire gameplay table"; presentation only — no game, card or network logic changed). ONE
  card, `widgets/playing_card.dart` `PlayingCard`, for every card the app draws (the viewer's hand, the rim seats, the poker
  board and hole cards, the dealer's hand, the rules sheet, the 5-Card picker), scaled by its height. **The face is printed
  stock**, one painter (`CardFacePainter`) under the card's own repaint boundary: warm ivory lit from its upper-left
  (`AppTheme.cardFaceHigh` #FFFDF8 → `cardFaceLow` #F2EAD9; `cardFace` stays the stock's middle tone for tabs and marks), a
  thin cut edge in a restrained warm gold (`AppTheme.cardRim` #C8AE78, 0.7–1.1dp — `CardStockPainter.paintEdge`, which
  the BACK and the flying backs of `DealFlights` wear too, so every card on the table is the same stock), a white hairline
  just inside its top half and a faint light along its top edge (the lacquer), and two shadows (`PlayingCard.shadows`: a
  tight contact shadow and a wider soft one, `AppTheme.shadowFor` — black by night, slate by day; none under a dimmed card).
  Corner `PlayingCard.cornerShare` 0.058 of the height (the back's own artwork is 0.0595), which `WildEdge`, `SetBack`,
  `WildTransform`, the poker board's empty slots and the deal's flying backs now read instead of a literal 0.055. The
  aspect stays 5:7, a poker card's. **The rank leads** ("RANK > SUIT > secondary card details"): set in Inter w700 — the
  app's own face, no new font — fitted to a CAP HEIGHT (`_interCapShare` 0.727, never the line box), so a 5 and a Q stand
  exactly as tall; a 10 is condensed across (down to 0.8) rather than shrunk, its figures set close (`cardRankFit`, public
  for the tests); the suit under it and the centre pip are PAINTED (`paintPip`, the `CardPips` silhouettes — Inter has no
  suit glyphs and Android would draw them from the colour emoji font), red hearts and diamonds, black spades and clubs
  (`pipRed`/`pipBlack` unchanged, ≥5.5:1 and ≥15:1 on the stock). The replaced monoline drawn ranks (`CardRankGlyph`) are gone.
  **`CardFaceMetrics.of(height)`** is where everything goes: FULL from `compactBelow` 56dp — rank cap 0.21h in a 0.235h
  column 0.055h in, a 0.115h pip under it, a 0.34h centre pip at 0.665h (an ace's 0.44h, higher), the pip shaded a touch
  lighter at its top — and **a clean face**: every card, a court card too, is its rank, its suit and one large centre pip on
  the bare stock, nothing boxed (the owner's refinement the same day: "premium traditional playing cards, not UI tiles"; the
  first cut ruled a court card's pip inside a gold window, `courtFrame`, removed with `PlayingCard.isCourt`); COMPACT below
  it (a rim seat's cards, 33dp on a 592x360 phone to 45dp): rank 0.27h (8.9dp at the smallest) in a 0.30h column that ends
  inside the half of the card a rim seat's five-card fan leaves showing, and no hairline or shading — small faces drop
  detail, never rank.
  **The viewer's hand is one hand** (`widgets/hand_fan.dart` `HandFan`, pure geometry, shared with `SeatRing.handWidthFor`
  so the ring keeps exactly the room the fan takes): three cards `step` 0.58 of a card apart (18% overlap before, which
  read as three cards; 0.62 in the first cut), the outer two leaning `tilt` 4° out about their foot (the owner's refinement:
  "left −4°, centre 0°, right +4°"; 4.5° in the first cut) and the middle one upright, raised `proud` 0.035, `topScale` 1.04
  of its neighbours' size (`AnimatedScale` from its foot, `HandFan.scaleFor` — a plain hand of three only: five stand too
  close for a larger card on top to leave its neighbours' indices clear) and **painted last, on top**
  (`HandFan.paintOrder`: outside in — `_OwnHand` builds its cards in that order, so a test that reads the fan in tree order
  reads it in PAINT order; the tests read it left to right). No glow on any card: the stock, its edge and the shadow do the
  work. The middle card covers its
  neighbours' inner edges, so a card to the right of the one on top prints its index in its TOP-RIGHT corner instead
  (`PlayingCard.indexOnRight`, `HandFan.indexOnRight`; one index a card, never two — a second peeked out in fragments from
  under its neighbour when tried): every card shows its rank and suit whole. The cards are `cardScale` 1.05 of `Dim.handH`
  — a little more prominent — which the tighter overlap pays for: the box (`HandFan.widthFor`, `leanShare` 0.08) is 2.06
  table hand heights wide against the old 2.07 and 1.13 tall against 1.12. **Five cards stand in the same box**: the box is
  always the five-card run (`wideRun` 1.52 card widths, 0.38 a step — the least that clears each index once the 4° lean
  opens its top) and a three-card hand is fanned tighter, centred in it; the 5-Card choice (`_BestThreeStage`) is acted out
  as before, the two set aside tucked 0.24 apart underneath and the best three 0.52 apart on top, the middle of those three
  painted last. **The hand stands a little higher** (the refinement: "slightly UP, for more breathing room between the cards
  and the bottom action controls"): `_LiftedHand` lays the viewer's column (their hand's name at a showdown, their bet and
  the fan, keyed `own-hand-column`) out knowing its height (`_HandPlacement`, a `SingleChildLayoutDelegate`) and stands it
  `HandFan.liftFor` — 0.15 of a card, 13dp on a 640x360 phone, 15dp on a 915x412 one — off the floor wherever its top
  then stays under the pot's plate (the pot's type line, padding and hairline, text-scaled, plus `Space.sm`), as far as it
  can where it cannot, and never less than `TableSpace.handLift`, the 6dp it stood before. Its left is the pod's right plus
  `Space.md`, as it was, so the ring's clearance of the key clusters (592 and 640 wide) is untouched. When the column's
  height changes — the hand's name arriving at a showdown takes the room the lift had on a 640x360 phone at ×1.25 — the lift
  GLIDES (`Motion.slow`, started after the frame: layout may not start an animation) instead of jumping; the first placement
  is at once. **Motion**: a card waits `flipDelay` before it turns, and the viewer's hand and a rim seat's
  reveal turn left to right `PlayingCard.flipStagger` 50 ms apart (five cards have turned in 0.62 s, inside
  `_BestThreeStage.beforeAside`'s 650 ms; `WildTransform` waits the same beat before its own turn); the turn itself
  (`flipFor` 420 ms) now lifts the card — 5% larger, 5% of its height up, its shadow further below it — and the band of
  light crossing it is a warm white; the face is built once and only moved by the turn, and a card turning back over keeps
  its face for its half of the turn. The entrance (`_Dealt`, table_screen) is dealt like a card: in from the middle of the
  table over 78% of 460 ms, a touch small then a touch past life-size and just past its lean, then set down onto its place
  (`_beat` 95 ms apart — a hand of three is down in 0.65 s; `FadeTransition` over its first 30%); one tree shape from the
  first frame to rest, so the card under it never rebuilds. `DealFlights` keeps its one pre-rendered back and one painter.
  **The back** keeps its artwork (the crown medallion on the lattice, `assets/card_back.svg`, unchanged) under the stock's
  gold edge and a faint top light (`CardStockPainter(face: false)`); `tint` still recolours the printing only
  (`BlendMode.color`), so a SEEN back is green under a gold edge. A DIMMED card (a packed hand, a beaten rim seat) is
  drained and a third darker but OPAQUE (`PlayingCard._drained`): at 55% opacity, as it was, every overlap of the tighter
  fan showed through as a bright bar across a packed hand. Found by the new tests and fixed: the 5-Card picker's hint line
  stood 2–4dp taller than the row was sized around at text ×1.25 and overflowed the panel (`CardPickPrompt`).
  `test/premium_cards_test.dart`: the stock's contrast, the rank's share at every height a card is drawn at, every rank in
  its column and a 10 condensed not shrunk (Inter loaded), the painted pips' colours sampled from a render and bare stock
  where a frame would be, the fan's lean, scale and paint order, **no index under another card and no card under a key,
  the pot, the bet badge or the viewer's pod at 592x360, 640x360, 732x412, 844x390, 891x411 and 915x412, ×1.0 and ×1.25**
  (the owner's four hands Q♠ A♣ J♥, 5♣ 9♣ 5♦, A♠ K♥ Q♦, 10♠ J♣ Q♥, a ten on the right, five being chosen from, five set
  out — separating-axis tests on the rotated quads), the hand's lift (never below 6dp, never above `liftFor`, never into
  the pot, the whole `liftFor` for a plain hand at ×1.0) and its glide when the name arrives, a rim card's rank ≥ 8.5dp on
  the narrowest phone, a card's beat, the hand turning left to right, a dealt hand landed inside 0.7 s, and the back's
  crown, tint and stock. Pictures: `test/table_shots.dart` scenes 26–32 (the four hands on the viewer's turn — 26
  5♣ 9♣ 5♦, 27 A♠ K♥ Q♦, 31 Q♠ A♣ J♥, 32 10♠ J♣ Q♥ — a 5-Card hand, a 5-Card showdown at the rim, a wild card turned; the
  harness's `SHOTS_ONLY` takes `a,b` for either and `a+b` for both), and `test/card_shots.dart` — the faces at six heights on
  each game's cloth in both themes, and frame by frame the turn ("See cards") and the deal — by hand, like table_shots:
  `flutter test test/card_shots.dart --dart-define=SHOTS_DIR=<abs dir> --dart-define=ICON_FONT=<…>/MaterialIcons-Regular.otf`.
- **The final table polish** (owner's brief, 26 Sep 2026: "a FINAL GAMEPLAY UI POLISH PASS … POLISH, DON'T REDESIGN";
  presentation only — the geometry, the card faces and every rule untouched). **Hierarchy**, Chaal over the pot over the
  contributions: the pot's plinth (`_Pot`) hugs its pile and figure inside the fifth of the felt it used to fill whatever it
  held (169dp round "6,800" on a 891dp phone, wider and darker than the Chaal key; about 95 now — only a figure past the fifth
  shrinks; since the pot's coins (30 Sep 2026, below) the pile takes what the figure leaves of the fifth, `_Pot.pileWidth`, so a figure
  the plinth can hold is still never set down for it); the viewer's own bet badge is scaled `_Felt.myBetScale` 1.1 of their pod (1.22, whose figure was 14dp at 891, the
  Chaal key's name size) and stands over their cards on a rim seat's terms (`myBetShown`: in the hand, or beaten while the
  showdown is on show — a packed hand wore a live-looking "BLIND 400" over its PACKED plate); `KeyPulse.still` 0.12 (0.18)
  against a primary breath of `breathLow`..`breathHigh` 0.22..0.40 (0.16..0.40), so Chaal's faintest glow outshines every other
  lit key; Pack's edge the error ink at the live-hairline alpha (0.55; glyph and name keep the red); Force Sideshow
  `KeyRole.special` in the hammer's copper (`hammerInkOn`), as Missile wears its coral — the brief's "SPECIAL/CONDITIONAL",
  where the 25 Sep brief had it secondary. **Turn**: the ring round the pod on turn, and round its picture, draws its edge by
  day in `AppTheme.goldOnLight` (reddening as the beat does), where champagne measured 1.0–1.3:1 on the pale room, rail and
  cloths — by night the beat, as before; its faintest edge `TableAmbient.turnEdgeFloor` 0.62 by night, 0.85 by day (3:1 on the
  room and rail, 2.2:1 on the palest cloths' edge). **Cards**: `HandFan.step` 0.54 (0.58) — a little more overlap, every index
  clear, the box and everything round it unchanged. **Sideshow**: the key keeps naming the player while the viewer's own request
  waits (`room.sideshow`), dead; its thread and the Force Sideshow's (`_SideshowLink`) paint on the cloth under the tag, the pot
  and every seat, where they had scored through "In Pot", bet badges and stacks. Left as recorded: the Shop key's gold, the seat
  ring, the poker felt's own pot bar. `test/table_final_polish_test.dart` (in Inter: the test font's em-wide glyphs overflow a
  real pot), the brief's two other hands in `premium_cards_test.dart`, scenes 33 (6♠ 8♦ Q♥), 34 (K♣ 2♣ 7♠) and 35 (a sideshow
  waiting on its answer).
- **The end of a hand and the coin flow** (owner, 26 Sep 2026: "check winner animation and coin flow, make it smooth";
  presentation only — no rule, server timing, wire or GameState change). **Bets**: `_BetFlights` (now `BetFlights`,
  `widgets/pot_flight.dart`, one painter through `PokerChipBrush`) stamped each chip with the time its ticker had reached when it
  last stopped, while the ticker restarted from nought — every bet after the first at a table flashed a frame at its seat and left
  0.64 s later than the one before (1.28, 1.9 s …, the next hand's boots too); its clock now only moves forward, a chip rises in at
  its seat, a switch flies nothing, and the pot's flare and the pile's lift wait for the chip to come down on the PILE, where bets
  now land (`BetFlights.landsAt` 540 ms; the figure still counts from the bet). **The celebration** runs off one clock in
  `_FeltState` (`_Party`, `WinnerTiming`) from the frame after `game:handEnded` names the winner — nothing on `game:showdown`, where
  the fireworks used to go up over the middle of the felt and jump to the winner, grown, a moment later: the fireworks at once (with
  `TurnBuzzer`'s win sound), then at the RESULT, once the hands shown down have turned (`WinnerTiming.turnOf`: 520 ms for three
  cards, 620 for five; at once when none was), the ribbon's strike (the pod's "Winner" tag fading in with it) and the pot off its
  pile onto the winner's stack pill (`PotFlight.progress`; the poker felt's flight keeps its own clock) — the plinth holds the whole
  pot until the chips set off and falls as they leave (`PotFlight.leftAt`), the stack holds until the first lands (720 ms after the
  result) and rises with them (`landedAt`, `SeatPod.stackLanding`), each through `LiveFigure`, rebuilt only when the words change;
  they used to count the plinth to nought in 550 ms and jump the stack before a chip had moved. `FireworksArt` parses the file when
  the table opens (11–95 ms, on the first win's frame before) and a painter draws it at the screen's rate (`FrameRate.max`; the
  `Lottie.asset` stepped at 30 fps). The celebration's Positioned is keyed: the missile volley leaving the Stack 80 ms after the
  reveal (or a 5-Card verdict timing out) had rebuilt it from nothing, restarting the fireworks and the pot. The shine crosses and
  comes back (`winnerShine`, `repeat(reverse)`, the band slid, not its stops pinned) — it flipped the word from deep gold to bright
  every 2.2 s (231/255 in one frame; 10 now) — and strike and shine are set by render objects (`_StrikeScale`, `_ShineMask`), not
  rebuilt. **The whole screen repainted every frame**: a rebuild inside the felt's LayoutBuilder lays the builder out again, and
  the pot's breathing glow (an AnimatedBuilder round the plate) rebuilt every frame, which, the felt being loosely constrained,
  relaid out and re-recorded the table screen — rail, keys, the viewer's hand — for as long as the table was open. The felt is now a
  relayout and repaint boundary (same size), the glow a painter on its own layer (`_PotGlowPainter`), the room's `DriftingChips`
  behind a boundary at the table: idle and through the celebration's tail the felt's and the screen's layers are re-recorded in 0
  of 30 frames (59 of 60 before). `test/winner_flow_test.dart`; pictures by hand, `test/winner_shots.dart` (the sequence frame by
  frame, `<run>_t<ms>.png`, 640x360 and 891x411 both themes, key frames at 592x360, 915x412, ×1.25 and Hindi; fixture
  `test/winner_scenes.dart`); `table_final_polish_test` now waits for the flare fired at the landing.
- **The pot's coins** (owner, 30 Sep 2026: "Use this animation on game Table for pot coins, change color of coin acc to blind, seen
  and variation table"; `widgets/pot_coins.dart`): the owner's `assets/animations/PotCoin.json` — fourteen gold coins falling one after
  another into three stacks (three, four and seven high) with a coin standing on edge on each, a rupee mark on its face; 1920×1080,
  24 fps, 120 frames, every coin at rest by frame 75, no 3D, expressions or images — stands on the pot's plinth where the painted
  `ChipStack` of four was (`_PotChips` → `PotCoins`), cropped to the pile at rest (`PotCoinsArt.window` 315,102–1641,960; the coins
  fall in from above it and the plate's `ClipRRect` clips them), in the TABLE's colour: `AppTheme.paletteFor` of the room's category —
  gold at a seen table, sapphire at a blind one, violet at a variation one (a private table its game's) — laid on the file's four golds
  at their own luminances (`tintAt`, the lobby marks' rule; `potCoinsDelegates(tint)`, made once per colour), the white rupee marks
  untouched. **Drawn by a painter, never the Lottie widget**: the file is parsed once as the table opens (`PotCoinsArt.load()` beside
  `FireworksArt.load()`, or on the pile's first build) and `PotCoinsPainter`, on the pile's own `RepaintBoundary`, draws the frame a
  `ValueNotifier` holds — the clock rounded to the file's 24 fps, so it repaints 24 times a second and not on every tick (§12.3: the
  Lottie widget's per-frame `setState` under the felt's `LayoutBuilder` laid the felt out and re-recorded it on every frame; lottie
  3.5.1's `LottieDrawable` takes its delegates AFTER construction, its constructor resolving them against a layer it has not built).
  **It plays once** — from the first frame to `builtFrame` 75 as the table opens (3.1 s, the pile forming) — and holds; every time
  chips land on the pot (`BetFlights.landsAt`, the moment the pile lifts) `_PotChips` counts a landing and the last eight coins and the
  three standing ones fall in again from `topUpFrame` 35 (1.7 s, six coins staying at rest); the pot resetting to nought drops nothing;
  looped whole it would empty the pot every five seconds. If the file cannot be read the painted stack stands in, in the table's
  colour. **Its width is what the figure leaves** (`_Pot.pileWidth`): `_PotChips.pileShare` 1.9 chip sizes at most (about the painted
  stack's width plus its lift, so the plinth is no taller than it was), less what the figure — measured with a `TextPainter` at the
  phone's text size — needs of the plinth's fifth of the felt, never under `pileMin` 1.0 chip sizes (the old stack's width): at
  592x360 ×1.25 the pile is 15dp and "6,800" is whole, at 891x411 the pile 36dp. Poker rooms keep their own pot bar.
  `test/pot_coins_test.dart` (9: the file — canvas, rate, length, twenty layers of golds and white, no traps; every coin inside the
  window at rest and filling it, the coins above it at the top-up frame, ten landing after it and six resting; the widget's box, its
  painter and no Lottie widget, its clock through the built frame, the hold and the top-up at the file's rate; the delegates per colour
  and the tint's hue and luminance; a seen, a blind and a variation table's pile in its own colour, left of a whole figure, both
  themes; a landing topping the pile up once and a reset dropping nothing); `winner_flow_test`'s repaint checks hold the felt still
  under it; `table_final_polish_test` the figure whole beside it. `seenTurnRoom(category:, boot:)` in `table_scenes.dart` builds the
  same table as a blind or a variation one.
- **Variation tables** (owner, 18 Sep 2026; server side §6.1/§6.4). Everything is drawn from `room:state.variation`
  (`VariationState` in `dtos.dart`; `GameState.variation`, `variationSelecting`, `variationIsMine`, `shownVariation`,
  `shownTurnUp`) — the two `game:variation*` events only say the same thing a moment sooner, so a reconnect mid-window
  rebuilds the right view with the server's ORIGINAL deadline. **The picker is a panel in the felt's Stack
  (`widgets/variation_prompt.dart` `VariationPrompt`), never a `showDialog` route** — no route can outlive the move it
  asked about (the missile question's black screen, above): title "Choose Variation", whole seconds counting down from
  `deadline − now` on its own controller (visual only; the server's clock decides) and never more than the window's own
  whole seconds (`countdownSeconds`, 24 Sep 2026: a phone running behind the server read a 10 s window as 11 — the same
  cap holds the 5-Card pick, `VariationState.secondsLeft` and the unfunded seat's grace), a draining bar, six keys three to a
  row, a one-line rule under each where the screen is not short. It takes the top 64% of the felt so the chooser's own
  hand and "See cards" stay usable (the server allows `see` in the window). **Dark glass with depth** since 28 Sep 2026
  (owner: "not glasmorpphism and have no depth, and add icon also"; `_PickerGlass`: a translucent obsidian body in both
  themes — no blur on the felt —, the overlay's light and shadow from the dark depth ladder, cast round it, a gold
  hairline; a shuffle mark beside the title, `_TitleMark`); each key a raised tile (`DepthFace`, the raised shadow) with
  its variation's glyph over its name (`variationIcon`: swap for Muflis, a target for AK47, masks for Joker, a medal for
  Hukam, double arrows down/up for Lowest/Highest Joker, a fan of cards for 5-Card), the chosen one struck gold. Each key is exactly its stated height —
  `_VariationKey.compactHeight` 44dp (the touch floor), `roomyHeight` 64dp — because its hairline and the panel's are
  PAINTED inside them rather than drawn as a border (an `Ink` border pads its child by its width, which made every key
  2dp taller); the mark is 15dp over a name alone, 16dp over a name and its note, and the words keep their room (the
  panel is 166dp at 640x360, 224dp on a roomy screen, the sums in `VariationPrompt`'s doc); a finger on a key takes its
  raised light to a third (`pressedLight`). `test/variation_picker_keys_test.dart`; scene `19b-variation-picker` in
  `table_scenes.dart`. A tap darkens all six and
  `GameState.selectVariation` **awaits the ack**: taken → dark until the snapshot removes the panel however slow the link;
  refused or unanswered → the keys come back. As the window opens for the viewer, the drawers close and any sheet over
  the table is popped (`popUntil(isFirst)`, as `_TableRoutes` does). Everyone else gets `VariationSelectingLine` in
  `_Status` ("Ravi is selecting variation…" + the seconds) and the chooser's pod is on the clock. When it closes,
  `variationAnnounced` holds "Variation: AK47" for 3 s — once per hand whether the event, the snapshot or both said so —
  with "Time ran out — Muflis was chosen" (`TIMEOUT`) or "<name> left — Muflis was chosen" (`LEFT`) under it, and
  `_CategoryTag` reads "VARIATION · AK47" / "· Joker · 10" / "· Hukam · ♥" through the showdown (`lastVariation`, cleared
  by the next deal, a change of table, or the celebration ending). **The Hukam suit on the tag is PAINTED, not typed** (owner,
  24 Sep 2026: "in Variation Game play when user selects Hukam, then the icon on top is not visible properly" — the light-theme
  screenshot showed "VARIATION · Hukam · ♣" with the ♣ BLACK on the dark pill while the rest of the label was gold): the tag was one
  gold `Text` ending in a bare U+2663, a glyph the bundled Inter lacks, so Android drew it from the colour emoji font, which ignores the
  text colour — a black club or spade on the pill, a red emoji heart for hearts. `variationTagParts` (`variation_prompt.dart`) now
  splits the label into `words` (the Joker rank "10" stays plain digits among them) and a `suit` LETTER, and `_CategoryTag` is a
  `Text.rich` whose `WidgetSpan` draws it as a `SuitMark` (`playing_card.dart`: a pale rounded card face, `cardFace` at 0.92, with
  the `CardPips` silhouette in `PlayingCard.inkFor(suit)` — red hearts and diamonds, black spades and clubs, so the suit's colour
  survives on the dark pill in both themes — sized to the label's line, font size × line height, so the tag does not grow;
  `test/suit_mark_test.dart`, and `variation_table_test.dart` pumps the Hukam tag at 640×360 ×1.25 and finds the pip, not a '♣').
  `variationTagText` still returns the glyph string (`VariationTagParts.text`) for the tests. The "4♠" tab under a turned wild card
  (`_RealCardTab`, `wild_transform.dart`) paints its suit the same way — rank in type beside a `CardPips` in the suit's ink, keyed
  `wild-real-card:<code>` — though on its white face the emoji colour had happened to be right; the `cardLabel`/`WildTransform`
  semantics strings keep the glyph, being spoken, not drawn, and the rules sheet prints no suit as text (its examples are
  `PlayingCard`s, which paint their pips). At a reveal a rim seat's fan shows the hand as it was COUNTED when the
  server sends `playsAs` (`SeatPod.playsAs`, 24 Sep 2026: the wild 7♣ of K♠ K♦ 7♣ shows as the K♣ it stood for; a server without it,
  or a hand with no wild card, shows the cards as dealt), and the cards that played as wild carry a gold
  edge (`WildEdge`, from the reveal's `wild`, matched against the dealt cards) — since 24 Sep 2026 a 2dp edge in `AppTheme.gold` (`goldDeep` on the light theme)
  with a gold star at the card's head on the side the index is not: the 1.5dp champagne edge it had was 1.24:1 against the card
  face, the same contrast as the card's own edge, and the owner read a wild-made Trail as "a pair showing Trail". Nothing on a
  rim seat re-ranks anything: the name is the wire's `handName`, and a natural PAIR plus a wild card IS a Trail by §6.4. Palette: violet since 24 Sep 2026 (owner: "VARIATION: Purple"; rani pink before — `AppTheme.violetPalette`, `_violet` #7650CC / `_violetDark`,
  `Icons.shuffle_rounded`; the table tag's mark is its accent lifted 40% toward white by day, on the tag's ink plate, where
  blind's sapphire — every blind table's since that day — was 2.5:1); the lobby card says `variationTableNote` as its ONE blurb line. A seen or blind table draws
  exactly what it did. Tests: `test/variation_table_test.dart` (640x360 at text x1.25 in all five languages),
  `variation_strings_test.dart`, `variation_palette_test.dart`, `five_card_test.dart`. **A wild card of the viewer's own hand turns into the
  card it played as** (owner, 18 Sep 2026; `widgets/wild_transform.dart` `WildTransform`, fed by `you.hand` —
  `OwnHand.standInFor`): it gathers gold light, lifts, turns a quarter on its long axis with the face swapped edge-on,
  and comes back under a ring of sparks (1.15 s, 190 ms apart along the fan), then STAYS turned — gold edge, a "WILD"
  ribbon at its head, the real card ("4♠") on a tab at its foot. It plays once: after the card's own face-up flip when
  both arrived together, at once when the choice lands on a player already looking; built already knowing (a reconnect)
  it shows the finished state; and it keeps the last stand-in when `you.hand` goes at the hand's end, so the hand does
  not turn back under the showdown. It adds nothing to the card's box (the fan's Stack is `Clip.none` for its halo).
  `_OwnHandName` names the live hand from `you.hand.handName`, faded in after the turn (`_AfterTheTurn`, keyed on
  `handNo`). `test/wild_transform_test.dart`. **5-Card Teen Patti on the felt** (owner, 18 Sep 2026; server §6.4): the
  client never decides how many cards anybody holds. Face down, `_OwnHand` draws the viewer's own `seats[].cardCount`
  backs, then `variation.cardsPerPlayer` (`VariationState.cardsPerPlayer`: absent or garbage reads 3, clamped 3..5),
  then 3 — the seat's count FIRST, because the server drops the variation block the moment a hand ends while the cards
  stay until the next deal, and a blind winner's fan fell to three backs beside four seats showing five. Face up it
  draws whatever `you.cards` (or the reveal) carries. **A five-card fan stands in the SAME box as the three-card one**
  (on a 640dp phone the hand sits between the viewer's pod and the action keys with nothing to spare): since the premium
  cards (25 Sep 2026, "The playing cards" above) the box is the five-card run, 0.38 of a card a step, and three cards are
  fanned tighter inside it (until then the outer cards kept a three-card hand's places, 0.82 apart, and five shared the
  run 0.41 apart); `five_card_test.dart` pins both. The two
  top-up cards arrive through the existing `_Dealt` entrance, not pop. Once `you.hand.best` names three of FIVE those
  three rise 0.08h and the other two are set back (`SetBack` in `variation_prompt.dart`: a wash and an 8% shrink that
  never changes the card's box or the tree shape, so `WildTransform`/`PlayingCard` state survives). **The choice is acted
  out, once per hand** (owner, 18 Sep 2026: "the two cards are low and then rearrange the cards that bring the selected
  cards at top"; `_BestThreeStage`, stages `held → aside → arranged`): the faces turn over in the order held (650 ms), the
  two that do not count dip 0.06h and are set back (520 ms), then the fan is RE-DEALT — those two take the left places,
  underneath and tucked 0.24 of a card apart, and the best three the right ones, on top and raised, 0.52 of a card apart
  instead of the five-card 0.38 (0.58 against 0.41 until the premium cards), so each one's middle pip reads as well as its
  corner (owner, 19 Sep 2026: "the front three cards' symbols are not visible properly"); the first and last card keep
  their places, so the box is unchanged, and the middle of the three is painted last, on top. Each group
  keeps the order held. Places, lean and paint
  order follow the SLOT; each card stays keyed by the index it was dealt at, so it slides with its flip and wild state
  intact, and every index still reads. A fan built already knowing (a reconnect, a blind hand's showdown arriving with
  the table) opens arranged with no animation. After the hand
  it falls back to the reveal's or the sideshow peek's `best`. Rim seats (`seat_pod.dart`): three cards or fewer take
  the old `Row` untouched; four or five overlap inside the same width and height, so a five-card reveal does not move
  the seat's column (`test/seat_reveal_layout_test.dart` has the case), with the cards not in `best` set back. **The
  picker is always two rows**: `VariationPrompt.perRowFor(n) = max(3, ceil(n/2))` — seven keys stand four over three in
  a panel 72% of the screen wide (clamped 340..600; six or fewer keep three across at 60%), so it grows sideways and
  its 169dp height at 640x360 is unchanged. `test/five_card_test.dart`. The rules sheet (`rules_sheet.dart`) has a **Variation tables** section
  under the rankings: an intro and the six variations, each with an example hand whose wild cards carry `WildEdge`
  (`test/rules_variation_test.dart`).
- **Poker tables** (owner's brief, 19 Sep 2026; server side §6.5). The lobby front gains a **POKER** card (teal,
  `Icons.casino_rounded`, `AppTheme.paletteFor` for the four categories and the `poker` family — before the seen
  fall-through) whose rail lists the four variants with their own facts: the variant on the badge, blinds ("100 / 200") or
  ante, buy-in ("from 2,000" — the server's `minBuyIn`, which is also the card's Entry), cards each, and "exchange up to"
  on Draw; the info dialog and `showRules(table:)` have poker branches and the rules sheet a poker-ranking section.
  `LobbyTable.game/isPoker` and `GameState.lobbyCategoryOrder` file every `three_card_poker | five_card_draw |
  texas_holdem | omaha` entry under Poker. (Since 23 Sep 2026 the Poker card is the Poker ENGINE's front card, which
  opens one category card per game and each of those its tables — the Lobby bullet above; the table cards are these.)
  **`screens/table_screen.dart` mounts `PokerTableScreen`
  (`screens/poker_table_screen.dart`) when `room.isPoker`**; the chrome both felts share — `LeftPanel`, `SideRail`,
  `TableDrawer`, `ChatDrawer`, `MachinedKey`, `StepperKey`, `Plate`, `TableWallet`, `Reconnecting`, `seatPlaces` … —
  moved to `widgets/table_chrome.dart` as pure renames (a private `_SideRail` wrapper stays in `table_screen.dart`
  because `table_wallet_layout_test` finds it by name). **Everything on the poker felt is drawn from `room:state`**
  (`RoomState.game/poker`, `PokerState`, `PokerOptions`, `PokerPot`, `PokerDealer`, `PokerReveal`, `PokerResult` in
  `dtos.dart`; a `you.options` with a `street` key parses as `PokerOptions` and never as `TurnOptions`, so
  `GameState.options`/`myTurn` are null/false at a poker table and `myPokerTurn`/`pokerOptions` take over):
  `_StreetTag` ("Texas Hold'em · Pre-flop", the stake between hands), `_Board` (five slots, faint outlines until dealt),
  `_Pots` (the plinth, side-pot capsules when there is more than one), `_DealerHand` (3-Card Poker's three backs at the
  top, cards + hand name + qualifies/does not qualify at the reveal), `_PokerStatus`, `_OwnHandLine` from `you.hand`,
  `_PokerHand` (the viewer's hole cards fanned face up from `you.cards` — 2, 4 or 5; after the river the ones not in
  `you.hand.best` are set back; on the draw street a tap marks a card — lift + gold edge — into
  `GameState.discardSelection`), `_PokerKeys` (Fold bottom-left where Pack is, and bottom-right `[Check|Call][All-in]`
  over `[−][Bet|Raise][+]`; the Draw N / Stand pat key or the Play key with the ante replaces the bet row on those
  streets), `_PokerCelebration` (winner ribbon with the hand name, fireworks, pot flights, armed by `poker:handEnded`
  OR a snapshot whose `poker.result` arrives first — once per `handNo`). The bet stepper: `pokerBetAmount` between
  the options' min/max, stepped by `pokerStepBet`; `pokerBetOrRaise` sends `bet` when nobody has bet the street and
  `raise` TO the figure otherwise; every move through `GameConnection.pokerAct` with a fresh uuid `actionId`. Seat pods
  take a `poker` flag: no BLIND/SEEN, no green backs, "Fold" not "Pack", the street bet on a gold chip badge, an ALL-IN
  ribbon; Teen Patti paths unchanged. `refusalText` translates the poker codes at poker tables only. ~85 strings in all
  five languages. Tests: `test/poker_table_test.dart` (DTOs, a Hold'em turn at 640×360 ×1.25 in all five languages,
  the stepper's clamping, the draw street's marking, the 3-Card decision, a finished hand's reveals). **Played on the
  emulator on 19 Sep 2026** against `tools/bot.js` at all four variants: Hold'em (call, bet each street, a straight
  wins the showdown with both bots' hands revealed and named), Draw (mark one card, Draw 1, a straight after the
  draw), 3-Card (Play, a non-qualifying dealer pays every seat) and Omaha (four hole cards), no RenderFlex overflows.
  Note the poker clock is `POKER_TURN_TIMEOUT_MS` (25 s by default): the first emulator hand folded me on the clock
  while I was reading screenshots, which is correct — run the dev server with `POKER_TURN_TIMEOUT_MS=90000` to play by
  hand (a table env key, so it takes effect only in env mode — which an unset `TABLE_CONFIG_SOURCE` becomes the moment
  it is set; with `TABLE_CONFIG_SOURCE=db` in a `.env`, add `TABLE_CONFIG_SOURCE=env` or edit the row — §4).
  **The rulebook key** (owner, 19 Sep 2026: "in each poker gameplay add an icon of rulebook and which tells about that
  specific table gameplay not other"): the poker rail carries a THIRD key under menu and chat, the book glyph the lobby's
  table cards use, and it opens `showRules` scoped to the room being played — "How this table plays" with that table's own
  figures, then that table's ranking and nothing else. **3-Card Poker shows the THREE-card order** (`_threeCardExamples`,
  from `eval3.go`: Straight Flush, Three of a Kind, Straight, Flush, Pair, High Card, with A-K-Q the best straight and
  A-2-3 the worst — neither the five-card order nor Teen Patti's, where a Trail beats a Pure Sequence); the other three
  keep the five-card list. The heading is `pokerTableRankingTitle` on one table's sheet and `pokerRulesTitle` ("Poker
  tables") only on the general one. A poker table's drawer Rules row is scoped the same way; a **Teen Patti table grows no
  key and its drawer still opens the whole reference** — the rankings, the seven variations and the poker family.
  `test/poker_rules_test.dart` (the key at each variant, the three-card ranking, the Teen Patti control, every sheet in all
  five languages), `poker_lobby_test.dart`, `poker_dtos_test.dart`, `poker_strings_test.dart`.
- **The seat pod** (`widgets/seat_pod.dart`) carries the rest of it. An unoccupied place draws
  `_emptySeat()` — a dashed outline and a chair, never a blank pod. The viewer's badge and total are
  **not** in their column: they hang over their own fanned hand (`SeatBet(totalFirst: true)`), and
  their name stays inside their pod. A rim seat shows, in order: pod, cards, then `SeatBet` — and
  since 11 Sep 2026 **BLIND/SEEN is written on the card fan, not in the badge**
  (`SeatPod._category`), which leaves the badge under the pod as a chip and a figure. A seat that has
  not bet yet has no badge at all rather than an empty capsule. **A seen opponent's card backs turn
  green** (`AppTheme.cardSeenBack`, applied as `PlayingCard.tint` through `BlendMode.color` so the
  printed crown survives) and the word is written in that same green (`AppTheme.seenInk`); BLIND
  keeps the quiet ink. None of it applies to a packed seat or to face-up cards — at a showdown or a
  sideshow peek the hand answers the question itself, with `_handName` laid over the foot of the face-up fan as a capsule (suppressed on the
  winner, whose `_WinnerFlash` ribbon already carries the ranking). **A seat's column must not change height at the
  reveal** (owner, 14 Sep 2026): `_Felt` places it by its middle, so the name used to take a line above the cards and a
  loser's bet badge dropped out below them, and every beaten player's cards jumped down the felt when a missile's result
  came in. The name now rides on the cards, and `_betShown` keeps a showdown loser's badge while the finished hand is on
  show (`test/seat_reveal_layout_test.dart`). A **sideshow** names only the hand that
  **won** it (the reveal's `packedUserId` marks the loser): the loser's cards still turn face up but
  carry no ranking, and when the viewer wins, `_OwnHandName` names their hand over their own cards
  (it used to appear only at a showdown, so a sideshow the viewer won put the label on the loser).
- **Per-frame clocks** (`LiquidFill`, `_SideshowCountdown`) compute from `deadlineMs -
  DateTime.now()` inside an `AnimationController` — never from the 1s tick. No clock-skew correction.
- **Sounds** (`settings/feedback_settings.dart`, fired by `TurnBuzzer` in `table_chrome.dart` on both felts): one low-latency
  `AudioPlayer` per clip, played as sonification with no audio focus (music keeps playing), all behind the Sound switch.
  **Until 29 Sep 2026 no DEBUG build played a single one of these** (owner: "Make sure hammer sound plays when i hit force
  sideshow", "Make sure missile sounds plays when i hit in gametable"): the shared `FeedbackSettings.uiSound` context set
  `mixWithOthers` on iOS's ambient category, which `AudioContextIOS` asserts is allowed only on playback, playAndRecord or
  multiRoute, so it threw inside `playClip` on every clip and the catch played the platform click instead — the deal, the
  look, the hammer, the missile and the lobby click were all the same system tick (a release build strips asserts and never
  hit it). Ambient mixes with other audio by itself, so the option went. Every sound test replaces `playClip`, so none had
  built the real context; `test/feedback_audio_context_test.dart` does, with asserts on. **Checking a clip on an emulator**:
  a play the app ASKS for proves nothing — look for an `AT::add` whose client is the APP's pid in `adb shell dumpsys
  media.audio_flinger` (the system's own clicks are pid 1000's), and its frame count is the clip's length (the missile
  187,776 at 44.1 kHz, the hammer 94,464 at 48 kHz on TP_Small). The emulator's own output reached the host silent here, so a
  host recording is no check.
  `assets/sfx/` holds the synthesised clips (tick, coins, alarm, door, win); **`assets/sound/see card sound.mp3`** is the
  owner's recording (26 Sep 2026: "this sound should be played when player see cards — when I see card then also and
  someone also see card then also"), played at full volume by `cards()` whenever a player dealt into the hand turns from
  blind to seen — the viewer or anybody else, by a tap on See cards or by the reveal the fourth blind bet forces (the
  server's only `isBlind = false` is `Table.see`). `TurnBuzzer` follows the look per hand and per player (`seenHand`,
  `seenBy`): a new deal, an empty seat (whose `isBlind` reads false — the wire leaves it out; it used to count, so a blind
  player getting up sounded like a look) and a player waiting for the next deal are no look, and there is none at a poker
  table. The look plays whatever else the frame brought — the chips of that fourth blind bet used to drown it — and only
  a win silences it. `sfx/card.wav` is no longer played. `test/see_cards_sound_test.dart`.
  **The deal** (owner, 26 Sep 2026: "when card is being distributed then use this sound … remove old sound … 12 times if 4
  player plays and 15 times if 5 player plays, 6 times if 2 player plays"): `DealFlights` plays **`assets/sound/Card
  Distribute.mp3`** (`FeedbackSettings.dealCard`, full volume) once for EVERY card it deals — cards each × players dealt in
  (`dealtSeats`), 115 ms apart — in place of the `tick` that clicked as each card landed (`tap()` still clicks the Sound
  switch on). The clip rustles for 200 ms and swishes to a peak at 380 ms, so card k is heard at `DealFlights.soundOf(k)` =
  `stagger × k + soundAt` (400 ms), its peak landing with the card; a late frame plays every card it passed, so the count is
  always exact. It overlaps itself four deep, so it has `dealCardVoices` (5) players taken in turn — on the ONE player a clip
  had, each card stopped the last before its swish began and only the final card was heard. **The hammer** (same day: "when
  someone hit force side show then this sound should be played"): **`assets/sound/hammer hit.mp3`** (`hammerHit()`, 0.85 —
  it strikes at full scale) for everybody at the table, as everybody sees the hammer — off the felt's hammer clock
  (`_thudIfDue`, the missile buzz's pattern) at `HammerTiming.sound` (810 ms): the clip strikes 90–100 ms in, so it lands
  with `impact`; a strike joined after the landing is not heard late, and an ordinary sideshow has no hammer and no sound.
  On the emulators (a build logging each clip): a two-player deal played 6, a four-player one 12, each Force Sideshow one
  hammer, and Android's audio service logged every start — though, as above, what those debug builds sounded was the platform click. `test/deal_sound_test.dart`, `test/hammer_strike_test.dart`.
  **The missile** (same day: "this is the sound should be played when user click on missile button and everybody should
  listen this sound"): **`assets/sound/Missile hit.mp3`** (`missileHit()`, 0.85 — its blast is at full scale), 4.3 s: the
  missiles' roar from 0.2 s, the blast at 1.4 s, a rumble to 3.8 s. Played once per volley from its LAUNCH, where the felt
  starts it (`_launchVolley`) — for the firer and everybody else at the table, since every client builds the volley from the
  missile's `game:action` — so the roar rides the flight and the blast comes as the first missiles land
  (`MissileTiming.flight` 1.3 s). A volley the table draws later than `MissileTiming.soundLate` (250 ms) into it (a
  reconnect) is not heard, nor is a missile with nobody to aim at. On the emulators Small6's missile played it once on
  both phones, the firer's and another player's. `test/missile_strike_test.dart`. **The winner** (owner, 29 Sep 2026: "This sound should be played when player wins in gameTable" — everybody at the table, the owner chose when asked): **`assets/sound/winner.mp3`** (`FeedbackSettings.win(mine:)`, full volume — it peaks at −1 dB but runs a few dB under the hammer), 4.15 s, on EVERY phone at the table the moment the hand's winner is named (`TurnBuzzer`: `winnerId` set and a result, once a hand, on both felts) — the frame the fireworks go up; only the winner's own phone also buzzes. A table arrived at with its hand already won (a poker room's snapshot keeps its result until the next deal) is not heard. It replaced `sfx/win.wav`, which only the winner heard and which is no longer played. On TP_Small, packed and watching the bots, every hand's end played the whole clip on the app's own track (199,296 frames at 48 kHz) and the speaker recording matched it at 0.97. `test/winner_sound_test.dart`. **A lobby card** (same day: "this
  sound should be played when user click on card" — the lobby's cards, the owner chose): **`assets/sound/Card click.mp3`**
  (`cardClick()`, full volume; a click 60 ms in, gone by 150 ms) on a tap on an engine card (Teen Patti, Poker), a category
  card (`_GroupCard`) or a table the player may sit at (`_TableCard`, where the door `enterTable()` still plays with it). A
  padlocked table card goes nowhere and stays quiet. `test/card_click_sound_test.dart`. **Every lobby key and Back**
  (owner, 27 Sep 2026: "This Card click.mp3 sound should be played when i click back button and any button in Lobby
  UI"): the same click, once per tap, through ONE helper, `lobbyClick(context)` (`widgets/glass_components.dart`, beside
  `tapHaptic`; nothing without a `FeedbackSettings` in scope) — the top bar (the picture, Shop, Settings; the
  record and Sign out until 30 Sep 2026), the foot (the Lucky Draw, the level key, the record, Friends), the back
  tile, a table card's ⓘ and rules keys (their own click only: the key wins the tap over the card, which neither clicks
  nor opens), the private card's Create and Join, the reward celebration's close key, and the cards as before. The shared
  widgets take it as a flag — `GlassCapsule(click:)` (every `_CornerChip`, `LevelKey`, `FriendsKey`), `GlassButton(click:)`,
  `ShopButton(click:)` (the lobby's only; the table's keeps Material's tick) — and a control that clicks turns Material's
  own platform tick off (`enableFeedback: false`), so a tap is heard once. **System Back** clicks whenever the LOBBY takes
  it (main.dart `_BackGuard`): closing the Stats or Settings drawer, going up a level (`closeLobbyLevel`), or asking to
  quit — not the quit question's own keys, not under the no-winnings panel, not under a cold start's resume veil (the
  player sees the veil, not the lobby: `!state.resuming`), not at the table or sign-in, and never when a dialog, sheet or
  page is over the lobby (it takes Back itself). Silent: a padlocked table card, a disabled key (Join before 8
  characters), the celebration's scrim, the code field and its keyboard Enter, and
  the no-winnings panel's *I confirm* (the panel covers the lobby; it is not a lobby key). The tests hear Material's
  tick too (`SystemSound.play` on a mocked platform channel, a sound-on theme): every key that clicks makes no tick. **Not yet extended** (surfaces opened FROM the lobby, their own keys keep Material's tick): the Stats and
  Settings drawers' rows, the table-info popup, the rules sheet, the sign-out and quit questions, the
  picture picker, the store, the Lucky Draw page, the level popup, the Friends page. Rapid taps restart the one voice the
  clip has (`_playAsset` stops it and plays again), so each tap clicks and nothing stacks. The seam the tests hear
  through is `FeedbackSettings.playClip` (`@visibleForTesting`), after the Sound switch has decided.
  `test/lobby_click_sound_test.dart`. **Found with it, and fixed** (it predates the click, master `b7f9c27` threw it too): a
  tap on a category card and another on the same spot straight after — the back tile coming in over the leaving front —
  put two front levels in the rail's `AnimatedSwitcher`, each with the private card under the same `GlobalKey`
  ("Duplicate GlobalKey detected in widget tree"). `_LobbyScreenState` now makes the private card's and its code field's
  keys afresh each time the rail comes back to the front; a front still leaving keeps the old ones.
- **The Settings drawer** (owner's brief, 26 Sep 2026: "Settings = premium + clean + calm + functional", some 20–30% of the
  store's language; presentation only — every dialog and what every row does is as it was; the app is landscape-only, so the
  brief's portrait case does not arise). `_LobbyDrawer`, which the Stats drawer shares, takes a fixed `head` (`_DrawerHead`: a
  32dp mark, the title in titleMedium w700, a muted line that may take two lines and steps aside while the keyboard is up, the
  close key) over a list that scrolls under an `EdgeFade`, on a body laid over its glass (`_DrawerBody`): the lobby cards'
  charcoal by night (`GlassColors.dark.cardFill` — the bare glass was near-black over the dimmed room), the table room's pearl
  by day (`TableGround.pearl` — it was grey milk-glass), lerped on the ground's lightness so the appearance control inside it
  cross-fades it. Four named groups (`settingsProfile`, `settingsGameExperience`, `appearance`, `settingsAccount`; tracked
  capitals in English only) under "Personalize your game experience" (`settingsSubtitle`): PROFILE — the portrait with a thin
  gold ring (`_AvatarWithPip(ringed: true)`, the drawer's copy only), the name and language fields in one type on one well
  (`_DrawerBody.well`, a warm stone by day), the language field naming the language in its own words alone
  (`selectedItemBuilder`; "বাংলা · Bengali" was cut at ×1.25, the list keeps both names); GAME EXPERIENCE — one `_SettingsGroup`
  pane: the number format as ONE row (the choice in gold, the player's own money under it, a chevron) that opens in place onto
  the same two `_NumberOption` tiles (now in the store's gold for a chosen thing) and closes on a choice, `_SystemName` keeping
  "Indian · Lakh, Crore" on one line where it fits and the units under the name where not, then `FeedbackToggles(grouped: true)`;
  APPEARANCE; ACCOUNT — Privacy policy (an open-in-new mark), Sign out NEUTRAL (it was red beside Delete; since 30 Sep 2026 the one
  Sign out in the lobby, the top bar's key having gone — owner: "keep the sign out button in seetings drawer"), and Delete my account
  apart as the one red row; then the version, centred and muted, with the environment quieter after it off production
  (`versionEnvironmentTag`). The switches are gold when on (`FeedbackSwitchStyle`: `AppTheme.goldFace`'s middle by night under a
  charcoal thumb, its foot by day under a white one; off keeps 3:1) — in the table's menu drawer too, whose row geometry is
  unchanged — and `GlassThemeSwitcher` is a sunk well (`track:`, optional) with the chosen segment in the store's gold wash and
  champagne edge and the other two in the body ink, not white38 — on the login screen and the table drawer alike. **Inside a Blind or
  Variation level both lobby drawers take that level's colour** (owner, 30 Sep 2026: "when i open setting while Entering Blind Card,
  then Setting drawer Shade colour should change acc to card type colour, for seen it is correct, but for blind and variation make it
  correct"; `widgets/level_accent.dart`): the lobby lays `LevelAccent(palette:)` over its `endDrawer` with the level the room is lit
  by (the category open, else the engine's palette), and `LevelAccent.of` answers `LevelColours` — or null for the gold levels (the
  front, Seen, Teen Patti), where everything draws exactly what it drew. Then the ground is the pearl by day and the charcoal by
  night turned to the level's hue at their own lightness, 1.8× as saturated (`LevelColours.inHue`: Blind's ice and deep blue-charcoal,
  Variation's lavender and plum), the wells the same stone in that hue, and the gold's roles take the level's accent — a fill
  (`fill`: the head mark's disc, the switches' track through `FeedbackSwitchStyle.track(accent:)`, the chosen segment's and number
  format's wash), ink (`ink`: the accent by night, the palette's ink by day), and the hairline (`hairline`, `chosenEdge`) — on the head
  mark, the head's rule, the portrait's ring and pencil, the number format, the switches and `GlassThemeSwitcher`. The Stats drawer
  takes the ground, the rule, the portrait's ring and the chosen scope (`_StatsInk._inLevel`: chevron, tick, wash); its money stays
  gold. Nothing outside the scope (the top bar, the table's drawer, the login screen's switcher) reads it. `test/level_accent_test.dart`
  (the colours per level and theme, the drawer's ground, mark, ring, switches and chosen appearance inside Blind and Variation in both
  themes, Seen and the front unchanged, the Stats drawer). `test/settings_drawer_test.dart` (640x360 ×1.25 in all five
  languages: nothing cut short, the head in place at the list's end; the number format row; the switches; the appearance
  control; Sign out and Delete still asking; the keyboard; the ring; the environment tag); pictures by hand,
  `test/settings_shots.dart` (run like table_shots).
- **The Stats drawer** (owner's brief, 27 Sep 2026: "Do NOT use tabs … The drawer should feel like ONE continuous player
  profile … Poker must NOT appear anywhere in this drawer"; presentation only — models, DTOs, GameState and the server
  untouched; `widgets/own_record.dart`). `_StatsDrawer` keeps the shared shell (`_LobbyDrawer`, `_DrawerBody`) but is wider
  than Settings (`_StatsDrawer.widthFor`: 46% of the screen held to 300–420dp — 300 at 592 and 640, 410 at 891, 420 on a
  tablet; `Dim.drawerW`'s 260 left a card too narrow three across at ×1.25), and it `select`s the account and the language
  rather than watching GameState, so the one-second tick rebuilds only today's-XP line where the server keeps one. The head
  is its own (`PlayerStatsHeader`, `_DrawerHead` untouched for Settings): the picture in a thin gold ring, the name in
  titleMedium w700 (ellipsised), "Level 1 · 🌱 Newbie · 23 XP" at 12.5 in a quieter ink (set a touch smaller before it takes
  a second line, `_FitLine`), the badges held after it in a quieter ink on the same line where both fit whole, else on a line
  of their own (`_LevelAndBadges`, `stats-badges`), a small 28dp close disc; "Your record"
  is gone from it (the rail key keeps the words). Then, one list: PERFORMANCE with the scope menu at its right
  (`StatsScopeSelector`: the scope's name and a gold chevron on a quiet capsule, a whole 44dp target; an `OverlayPortal` menu
  anchored under its right edge — a small glass card on the drawer's blur budget (`GlassMode.auto`: the drawer holds the one
  lease, so over the drifting chips it is its near-opaque body, not a second per-frame blur), thin border, small shadow, All Games · Teen Patti · Variations
  with the chosen one in gold with a check (by day `AppTheme.goldDeep`, 4.6:1 on its wash where the money gold read 4.27),
  fading and rising in over 160ms (one `CurvedAnimation`, made and disposed with the controller); a tap outside puts it away; no route, no tabs);
  Played · Won · Lost three across (`PerformanceStatCard`: glyph, the figure at 19, the label at 10.5 — "Played",
  `statsPlayed`, not "Hands played", which took two lines at ×1.25 in a 300dp drawer); Total winnings and
  Biggest pot two across, the only gold in the record (figure and glyph, on a card with a breath of gold); "Left mid-hand:
  75" as one quiet line; HAND RESULTS ("Hands held" renamed, `HandResultGrid`: two across, name at the start, count at the
  end — given only the room the name's longest word leaves, a third of the cell at least, and set smaller in it, so "Pure
  Sequence" beside "18,182" is never cut; measured round the grid, whose rows ask intrinsic heights a cell's builder cannot
  answer; each hand's icon at the cell's start — `HandIcon`, below); VARIATIONS PLAYED (`VariationStatsList`: a hairline-parted list, PLAYED/WON columns right-aligned). Section names at
  11 in tracked capitals in English only. A scope changes only what is under the menu, in a 200ms fade and 6dp rise; the
  scope survives a scroll (`AutomaticKeepAliveClientMixin` — a jump to the list's end once dropped it back to All Games).
  **What each scope shows is the model's own**: All Games is `User.totals` (which, being the server's career totals, include
  poker hands — no figure is re-added), and the model counts hands only for Teen Patti and Variation and variations only for
  Variation (`StatsCategory.countsHands/listsVariations`), so where a scope has no such part the section stays with one quiet
  line saying which scope has it; an empty part says "No hand results yet" / "No variation games played yet". Per-variation
  "played" counts every hand dealt under it while Hands played counts hands with a move in them (requirement 16), so the
  variations may sum past it — left as the data says. By night: charcoal body, cards a breath of white with a barely-there
  hairline and no shadow, muted ink white at 0.58; by day: warm pearl body, whiter cards edged in a warm stone (#E8E1D5) with a
  soft diffused shadow, warm charcoal (#1D1B18) and warm grey (#6E685E) inks — the footnote under the record too
  (`StatsFootnote`; the theme's quiet ink it had read 3:1 by day). The two sets are BLENDED by `GlassColors.dayShare` (how far
  the theme has come from obsidian to ice, read off the lerping ground — what `_DrawerBody.dayOf` reads too), not chosen by
  brightness, so a theme change with the drawer open cross-fades them with the body instead of snapping them at its middle. The Friends page and the table's player drawer
  still draw `PlayerStatsGrid` with its four-game switch, unchanged. `test/stats_drawer_test.dart` (no tab/segmented control,
  exactly three scopes and no Poker anywhere, each scope's figures, the head, the quiet left-mid-hand line, gold only on money,
  10.5 Crore fitting, empty states, the menu's semantics and anchoring, the other two places unchanged, and every scope, its end
  and the open menu at 592x360, 640x360, 844x390, 915x412 and 1280x800, ×1.0 and ×1.25, all five languages, both themes; the
  footnote's and the chosen scope's contrast by day, the badges' line, no rebuild on GameState's notifies, the cross-fade, and
  hand results in four to six figures with all seven variations at 592, 640 and 891 ×1.25 — `bigCountsJson`);
  fixture `test/stats_drawer_fixture.dart`; pictures by hand, `test/stats_drawer_shots.dart` (run like table_shots).
- **Theme** ("Glassmorphic Premium", 11 Sep 2026): FlexColorScheme with explicit palettes (the "one seed"
  comment is stale) plus a `GlassColors` ThemeExtension (`theme/theme_colors.dart`) holding the glass
  tokens per brightness — **Obsidian** dark (ground `#0D0E12`→`#08080A`, fill white 0.04/0.08, border
  white 0.12→0.04, blur 16, type white/white70/white38) and **Frosted ice** light (ground
  `#F4F5F7`→`#EAECEF`, fill white 0.62/0.70, white highlight + black 0.06 border, blur 20, type
  `#121316`/`#4A4D55`). `GlassColors.of(context)`; it lerps with the 420 ms theme cross-fade. Typeface
  **Inter** (bundled, `assets/fonts/`, OFL; `AppTheme.fontFamily`), tabular figures on money.
  `PremiumGlassPanel` (the ONE glass primitive, `widgets/premium_surface.dart`) paints the spec: a
  near-transparent gradient body over the blur (or an opaque body when tinted), a 2dp sheen and a 1px
  top→bottom gradient hairline (`GlassHairline` painter; gold when `live`); `sigma: null` = the theme's.
  **Blur budget unchanged**: one `GlassBudget` lease, `GlassMode.auto` claimants only over static or
  covered backdrops — never on the felt or over the lobby's drifting chips (`tinted` there).
  `widgets/glass_components.dart`: `tapHaptic(context)` (`HapticFeedback.lightImpact`, gated on the
  Vibration switch), `PressScale` (Listener-based 0.97 press-down; never enters the gesture arena),
  `GlassCard`, `GlassButton` (Material's Filled/Outlined/TextButton underneath → `enableFeedback`,
  `liftElevation`, disabled all still work; `primary|glass|outline|text`), `GlassTextField` (every
  input property passed through), `GlassThemeSwitcher` (System · Dark · Light, `SpringSimulation`
  thumb, haptic, calls `GameState.setThemeMode`). Three modes: `GameState.themeMode` may be
  `ThemeMode.system`; `setThemeMode()` persists; `toggleTheme()` kept (from `system` it flips away from
  the platform brightness). **Dark glass is the default** for a fresh install
  (`ThemePreference.fallback`). **The native launch screens are dark on every system setting too** (11 Sep
  2026): `values/`, `values-v31/`, `drawable(-v21)/launch_background.xml` are copies of their `-night`
  twins, `render_icons.dart` writes light-on-dark branding for both, and iOS `LaunchBackground` is
  `#0D0E12` in both appearances — so a light-mode phone never flashes a pale frame before the dark
  default paints. A player who picks Light or System still gets it once the app is up. Screen changes are fade-through (`_ScreenFade`: veil + 0.96→1 scale).
  Solid things stay solid by design: felt, cards, chips, the on-cloth `_Plate`s, the machined
  console keys — glass is for what COVERS the game. **The lobby's cards and the table's seat pods
  are the exception** (owner, 11 Sep 2026, after a reference of frosted cards over colour orbs). **The lobby's cards are
  one `GameCard` since 24 Sep 2026** (`widgets/game_card.dart`; owner's lobby polish brief: "keep the ambient glow
  concept, but make it much more subtle … like ambient lighting behind the UI, NOT like a large colored circle"): the
  engine, category, table and private cards and the back tile are `PremiumGlassPanel(surface: GlassSurface.card)` —
  the theme's card tokens in `GlassColors` (`cardFill`/`cardFillEnd`: white at 0.97→0.94 by day, rgb(35,38,42) at 0.92 →
  rgb(28,30,33) at 0.88 by night; `cardBorder` #E2E4E7 / white 0.10; `cardHighlight`; `cardShadow`, deeper by night;
  `cardMuted`, the quiet tier that clears 4.5:1 on the card), `Radii.xl` 22 — with the mode's accent spent on the top
  of the hairline (`edge`) and on a light behind the card, `CardLight`: one radial gradient inside the card's clip, in
  the accent brought to full colour (`orbColours(accent).$1`), peaking at `GlassColors.glowStrength` and gone by
  `glowReach` of the side — **0.05 / 0.56 by day and 0.18 / 0.72 by night** since the owner's final pass (24 Sep 2026:
  "keep the hues, reduce the tint", light ≈ 3–6%, dark ≈ 15–25%; it was 0.12 / 0.62 and 0.22 / 0.78), the hairline's
  `edge` at 0.36 / 0.32 (0.50 / 0.42). The two orbs it replaced — a sharp disc behind each card and a blurred copy
  inside it, placed by `_orbPlace` — showed round the cards as coloured circles, loudest on the light theme. A shut
  table is drawn unlit. The room itself takes the open level's colour through the lamp's pool (`_RoomLight` →
  `LobbyGround`, `accentStrength` 1.2 by day and 2.0 by night, faded over `Motion.arrive`; none at the front), and
  the corner keys, the foot key, the private card's mark and its Create key carry less of the accent than they did
  (fills by about a third, edges by a sixth). A group card's name is in the card's own ink; facts carry the mode's
  glyphs, money in gold; the foot key `_SitCapsule` is neutral glass with the mode's accent in its edge, a breath of it
  in its fill and on its arrow; the private card's Create key the same in emerald (`_accentKeyStyle`).
  **The final pass** (owner, 24 Sep 2026 — typography, clipping, spacing, tint and responsiveness, "no redesign"):
  - *The rail stops on whole cards and a glimpse of the next* (`lobbyRailSide`). The owner's "Only your own chips are
    vis…", "Entry Up…", "Tap to sit down…" was a table card two-thirds on screen: on a phone 844dp wide or more an
    inner level's fourth card stood 79–89% on screen. The side is now the largest, no more than the rail's height
    allows (`fit`), at which every card before the first partial one stands whole and `Space.xl` clear of the edge and
    that one shows
    15–60% of itself (or every card is whole) — never below 196dp (`_sideMin`: smaller, a table card's words would have
    to shrink). A level inside an engine is sized as if it held four cards, so categories and tables stay one size. At
    844–1280dp every level now stops cleanly (a blind level at 915×412: three whole tables and 15% of the fourth, at
    246dp where they were 270); where no clean side ≥ 196 exists the rail keeps `fit` — a 640×360 front's private card
    at 61%, an iPhone 844×390 inner level inside its notch insets at 70%. A level of another size than the last eases
    to it, and the list's end padding is `Space.xl − Space.lg`, so the last card stops as far from the edge as the first
    starts (it stopped 34dp in).
  - *A card's words stand in a `CardColumn`* (`widgets/game_card.dart`; the group, table and private cards): its blocks
    one under another, as wide as the card. When they stand taller than the room above the foot key, the air between
    them (`CardGap`, and the facts' `CardRule` hairlines) gives way first, down to half, and only then is the column
    scaled as one — laid out at the width ÷ the scale, so it still spans the card (the `FittedBox(topLeft)` it replaced
    shrank it towards its left edge, a ragged right margin). `keepClear` keeps a table card's words out of its corner
    keys (`_cornerKeysReach`: their discs, 40×84dp from the card's top right) at any scale — 5-Card Draw's line ran
    under the rules key at 0.75. On a 640×360 phone at 1.0 a blind table's card fits whole; the densest card, 5-Card
    Draw (five facts under a two-line line), is scaled to 0.85 (0.80 on master) and Hold'em to 0.94 (0.95); at ×1.25 a
    blind card to 0.95 (0.89), and the Hindi blind card fits by its air alone (0.98).
  - *Type* (`_CardMetrics`): the boot `s × 0.108` (22–36dp; 24.5 on a 640dp phone, where it was `s × 0.14`, 32) — a
    step under a group card's name (`s × 0.112`), still the largest figure on a table card and under twice its next
    largest words; the badge's word 11–15dp (10 on a 640dp phone before); every blurb in the body's ink (the variation
    and poker lines a half-step heavier where they were display-ink semibold), allowed a third line — and a SEEN or BLIND table card has none since 29 Sep 2026 (owner: "Everyone's chips visible" off the 200 and 50,000 tables, then "Only your own chips are visible" off the 200, 5,000, 50,000 and 20 Lakh ones; the SEEN and BLIND category cards, the ⓘ popup and the rules sheet still say it, and Variation and poker cards keep their own line; `lobby_categories_test`); a fact's label
    shrinks to the room its value leaves rather than "bo…", and a fact row is never shorter than its glyphs; the foot
    key's words shrink rather than ellipsise.
  - *Spacing* on the cards' own 4dp grid, **`CardSpace`** (4/8/12/16/20/24/32) — **the app-wide `Space` ramp
    (2/4/6/10/14/20/28/40) is untouched**, since every other screen is laid out on it, and a test holds both. Three tiers
    from the side, compact < 240 ≤ regular < 320 ≤ roomy: margin 12/16/20, between blocks 8/8/12, badge to boot 4/4/8,
    mark to words 12/12/16, above the foot key 4/8/16, either side of a fact rule 4/4/8 (a group card's 4/8/12). A category card's name stands TWICE its gap above its
    line (an engine card's once — it has the most to hold; 16/16/24; owner, 30 Sep 2026: "add some space between 'Seen' and 'Everyone's chips visible'").
  - *The private card* stands its code field and its keys together on its foot (two Spacers had split them), its name
    and line at the top in a `CardColumn` (at ×1.3 the line was cut mid-sentence); the English hint is tracked 2, not the
    code's 6 ("TABLE C…").
  - *Left as they were*: the top bar (at ×1.25 on a 640dp phone its name still ends "Guest…" and its wallet scales to
    0.79 — 0.62 for a 99,999 Crore wallet beside a 24-letter name — exactly as on master), the corner chips (no overlap
    at any size tried), and the back tile.
  The back tile is lighter than the cards: unlit, a neutral key, the level's name in the card's ink over a 20×3 bar in
  the level's colour. `test/lobby_polish_test.dart` holds the modes' accents and inks (≥ 4.5:1 on the card), the card
  tokens and the tint to the brief's ranges, no `GlassOrb` in the lobby, the boot as the largest figure on a table card
  and under twice the next, the keys' accent edges, the wallet pill and the name's width, the room light, the 4dp grid,
  the rail's stops (`lobbyRailSide` at six widths, and the rendered rail at 732–1280dp on every level, its end
  included), the `CardColumn` (air before words, full width when scaled, the keys' zone kept at any scale) and, at
  640×360 ×1.0 and ×1.25, no card line cut short or under a corner key; `lobby_categories_test` reads the engine
  card's column scale.
  **Seat pods** (`SeatPod._pod`) keep the orb pair from `widgets/glass_orb.dart` (`orbColours`,
  `GlassOrb`), coloured by `GameState.colourFor` (the player's chat
  colour, so a pod and its chat name match) and — soft-edged, at `TableAmbient`'s opacities since the table polish of
  24 Sep 2026 — spilling a tenth of the pod width out of
  `OrbCorner` (odd view index top-right, 2 and 4 top-left — always towards open felt, never under the
  rail or a card fan; the viewer's is `contained`, glow inside the glass and no orb outside, because
  between the missed-turns plate and their own cards there is no felt to spill into — on TP_Small a
  spilled orb lay under the plate). Turn and winner state ride on the glass: `live` (gold hairline) plus a wash
  of the beat / primary colour; at rest the glass is plain frosted white.
  `_raisedButtons` = state-driven elevation (`liftElevation`: disabled 0, pressed rest/3, hover 2×),
  tinted `shadowFor`, transparent surfaceTint; text buttons flat. `PremiumSurface` = the one raised
  treatment (3 shadows + bevel + optional `Glint`).
- **The depth pass** (owner, 28 Sep 2026: "Do not redesign the UI. Preserve the exact current layout and visual language.
  Make the existing UI feel physically layered and naturally elevated using depth, luminance separation, soft ambient
  shadows, subtle inner highlights, translucent surfaces and nested elevation. Keep the same colors, typography, spacing,
  card shapes, buttons and icons. Improve depth, not decoration."; presentation only — no size, padding, position, radius,
  type, colour token or icon moved, and every geometry test passes unchanged). **One ladder**, `theme/depth.dart`:
  `Elevation {ground, well, card, raised, overlay}`, NESTED — a surface's shadow says how far it stands above the surface
  directly under it, so a key on a card casts the key's small shadow on the card (`raised`, 2dp contact + 9dp ambient),
  a pane on the room the pane's (`card` = exactly what `AppTheme.glassShadow` always cast), and a dialog, drawer or sheet
  that plus a far soft reach round itself (`overlay`, `DepthScheme.overlayReach`, 48dp, 22 down). `Depth.of(context)` (lerped
  on `GlassColors.dayShare`, so it cross-fades with the theme) or `Depth.forBrightness` (the plates and the wallet, dark in
  both themes) holds every number: per level its shadow pair in `AppTheme.shadowFor`, and the light it catches
  (`SurfaceLight`, `DepthLight`) — a line just inside the hairline lit along the top edge and curling down into the
  corners, a shade along the foot, and by night a breath of light over the upper half (0.04–0.05 white: luminance
  separation, since on obsidian a shadow cannot show). A **well** is the light turned over (shaded top inside edge, lit lip,
  no shadow). **A translucent surface casts round itself and never under itself** (`OuterShadow`, `DepthShadow`: the shadow
  clipped to outside its shape) — under glass or a veil of colour a `BoxDecoration` shadow shows through and changes the
  surface's own colour (the first cut turned the lobby's wallet pill grey by day and near-black by night, and darkened
  the Lucky page through its blur). **Where**: `PremiumGlassPanel.depth` (default `card`; its flat 2dp sheen is now
  `SurfaceLight`, rimmed in the theme's own `highlight`/`cardHighlight` at card height); `overlay` for `GlassDialog`,
  `GlassDrawerPanel`, `NoticeToast`, the lobby's two drawers, the store, the picture picker, the level screen, the
  table-tax popup, the Lucky Draw and Friends pages, the consent and soft-update panels and the switching veil;
  `GlassCapsule` at `raised` (the corner chips, the level and Friends keys); `GlassCard.depth`; `PremiumSurface`'s straight
  3px bevel → `SurfaceLight`. On anything else a `DepthFace` (the light under a surface's content) and, for Material
  buttons, `raisedKeyFace` (a `ButtonStyle.backgroundBuilder`: lit while pressable, a third while pressed in, none when
  dead — a dead key sits flush, as its shadow does): `MachinedKey` (not the struck-gold face, which has its own lit edge),
  `StepperKey`, `RailKey`, `GlassButton` (primary at 0.35, text flat), the lobby card's View tables key, the store's price
  key; `Plate` (its flat 1px top line → the dark ladder's edge), the table's `WalletPill` and the lobby's wallet and bar
  pills (`DepthShadow`); nested cards one step above their sheet — `LevelCard`, `LuckyPrizeTile` (shadowed by night too
  now), the settings groups, `PerformanceStatCard` (light only: by night it is glass on glass and casts nothing); wells —
  the pod's stack pill and `GlassThemeSwitcher`'s track. By day the lobby cards' ambient reaches a little further
  (`GlassColors.light.cardShadow`: 0x1A over 26dp, 11 down, spread −3; 0x14 over 20dp before). Static paint only (every
  painter compares all its inputs), no new blur and no new colour; left as they were: the store's navigation keys, the
  picture tiles, the casino table, the cards, the Shop and Chaal gold. `test/depth_ladder_test.dart` (the ladder's order and
  colours, the pane's shadow unchanged, night and day light, the well, the cross-fade, the light moving nothing, a key lit
  only while pressable, overlays' reach, and a translucent pill's middle pixel unchanged by its shadow — proven to fail with
  a shadow painted under it); the rest of the suite unchanged (on this Mac the same 43 Indic-font failures as master);
  pictures by hand with the `*_shots.dart` harnesses.
- **The Google photo on the picture shelf** (owner, 28 Sep 2026: "in profile picture selection show his google profile image
  also, which he can select again after selecting different profile picture"; `picture_shelf.dart` `providerPictureOf`,
  `providerPictureKey`, `shelfCount`). The account's own sign-in photo (`user.providerAvatarUrl`) is the FIRST tile of the All
  shelf — the picker's and the store's Pictures shelf alike, whichever way the prices run — as a `ProfilePicture` of its own (id -1,
  FREE, owned, named "Google photo", or "Your photo" for another provider): "✓ Wearing" while no catalogue picture is worn (the
  account's face then IS that photo), "✓ Owned" otherwise, and a tap takes the catalogue picture off (`chooseAvatar(null)` →
  `POST /api/profile/avatar {avatar: null}`; nothing is sent when it is already worn). None for a guest or an account whose provider
  sent no photo, and never on a priced shelf; the All shelf's menu counts it (`shelfCount`). It replaced the header's unlabelled
  person icon (`Icons.account_circle_outlined`, "Use my Google picture" as its tooltip), which did the same and was not found. Two
  strings (`googlePhoto`, `ownPhoto`) in all five languages. `test/provider_photo_test.dart`. Played on the Play emulator with a
  Google account: first tile "Wearing", Bear worn, the Google photo tapped back on.
- **The picture picker** (`openPicturePicker`, with a day/night `DayNightSwitch` — sun, switch, moon, `GameState.toggleTheme` — at the top of its header since 14 Sep 2026 (owner), and headed by the player's display name where it read "Your picture" (owner, the same day); its shelf — `PictureFilter`, `PictureFilterMenu`, `pictureShelf`,
  `PictureChoice`, `unlockPicture`, `DiamondBalance` — lives in `widgets/picture_shelf.dart`, shared with the chip
  store's **Pictures** tab (`chip_store.dart` `_StoreTabs`: Chips | Diamonds | Pictures in the header — **every shelf heads with the
  wallet it sells or spends, Chips with the player's chips since 24 Sep 2026** (owner: "In store when user click on Coins tab, then it is
  not showing users current coin on top, just like we show for hammer"; it was the one shelf with no balance): `ChipBalance`, the
  `HammerBalance` pill's twin in `picture_shelf.dart` — the lobby wallet's coin and `formatChips` in champagne on the dark pill; at a
  table the SEAT's stack (what the drawer's "Your chips" shows and where a pack bought there lands), in the lobby the wallet; its width,
  floored at a two-decimal lakh figure, is counted into the header's `walletW` on every shelf, so the tabs never move from one shelf to
  the next and the blurb gives up the room (`test/store_chips_test.dart`: 640x360 at x1.25 in all five languages, a wallet change under
  an open store, the seat at a table); **and Missiles with the missiles held beside the diamonds a pack is traded for, since 24 Sep 2026**
  (owner: "In store when user click on Missile tab, then it should also show the user current missile count just like it is showing
  diamond count"; it headed with the diamonds alone): `MissileBalance`, the missiles twin of `DiamondBalance`/`HammerBalance` —
  `missileIcon` in the missile's coral on the dark pill — inside `MissileWalletBalances`, diamonds then missiles (the order the table's `WalletPill` and the trade dialog give the two) in ONE dark panel,
  exactly as `PictureWalletBalances` pairs diamonds and hammers (two framed pills one over the other would stand taller than a one-line
  header at x1.25): in a row where the widest blurb keeps its line beside it, stacked otherwise, its stacked width counted into
  `walletW` on every shelf. The diamond, hammer and missile pills and both panels are now one private `_WalletBalance` row (bare, `framed: false`,
  inside a `_WalletPanel`; `ChipBalance` keeps its own coin row), so the Pictures/Tables shelves draw what they did pixel for pixel and the Diamonds/Hammers pills gain only
  tabular figures; the count reads `user.missile` under the store's watch, so a trade raises it at once (`test/store_missiles_test.dart`) — the **Diamonds** tab (`diamondPacks`, `_DiamondPackCard`: 1/₹49, 5/₹199 ⭐, 20/₹699 🔥, 100/₹2,999) is offered at a table too, and a credited pack celebrates as `rewardWon.kind == 'diamonds'`; at a table the picture key
  is **Animated** (`_StoreTabs.animatedOnly`, owner 13 Sep 2026): the animated shelf alone, no shelf menu, bought with hammers (since 14 Sep 2026; diamonds before) and worn on the seat at once; the chip packs are drawn as lobby table cards —
  frosted glass over a baked orb, a still plate, count-up figure, one fact, a price capsule — coloured sapphire → purple → gold
  up the range; the Pictures tab heads its grid with the worn picture, large and centred, beside the shelf menu); requirement 21): a horizontal strip
  of the active catalogue, one **shelf** at a time: a menu pinned above the grid (`_PictureFilterMenu`, 13 Sep 2026)
  picks All (the default) or Premium in one wallet — chips (a poker-chip glyph), hammers (the hammer) or diamonds (the gem),
  `PictureFilter.menu`, in a pill that follows the theme — a slate well with charcoal type and deep gold by day, charcoal with light type and pale gold at night; it was the dark pill in both until the owner caught it (owner, 14 Sep 2026; it offered Free, Premium (IMAGE/SVG) and Premium (Animated) before, so a free
  picture is now on All alone; `PictureFilter.animated` survives only as the store's at-table shelf), each with its count; a second menu on its right, `PictureSortMenu` (owner, 14 Sep 2026), orders any shelf by price — low to high by default, or high to low — through `shelfOrder`, which sorts each wallet's pictures among themselves with the wallets in the order chips → hammers → diamonds and a free picture the cheapest (before it only the premium animated pictures ran cheapest first,
  owner 13 Sep 2026 — re-dealt into their own slots, so on All the group stays where the catalogue put it). A picture the player has not bought is drawn at
  full colour (owner, 14 Sep 2026; dimmed to 0.55 before) with a gold padlock-and-price pill (`_PriceTag`; a DIAMOND row shows a gem instead and a HAMMER row the hammer
  glyph, each with its unlock dialog in its own currency — "Toucan Flying costs 30 hammers and is yours for 100 days", a singular
  line for 1 — and the sheet's and the store's Pictures header carry diamonds and hammers together in one pill, stacked where a
  row would cut the blurb; a player short of the picture's currency is offered that currency's store tab, switched in place when
  the store is already open, and at a table the app refuses a COIN picture itself; `GameState.buyPicture` answers
  `bought | notEnough | refused`) — shown rather than hidden, because
  knowing what is behind the padlock is the whole reason anyone buys one. Tapping a locked one asks
  first (`GlassDialog`, `t.unlockTitle`/`unlockBody`/`unlock`, with the picture itself large and playing under the title — `_PictureOnOffer`, which the "Not enough hammers/diamonds" offer of the store's shelf shows too, owner 14 Sep 2026), **the price named in the title row** (`PriceAndWallet`, "Price" over its wallet's pill — owner, 28 Sep 2026: "it is not showing cost after clicking on it, it is showing how many hammers i have": the one pill was the player's balance, at the foot of a body a 360dp phone scrolled out of view; the "Not enough" offer puts "You have" beside it; the table-picture and emoji questions the same), then `GameState.buyPicture` buys it,
  re-reads the catalogue (`owned` is per viewer) and wears it. The tick follows
  `user.activePictureId == p.id` — it used to compare the choice PATH to the picture's id, so
  nothing was ever ticked. `state.buyingPicture` puts a spinner on the one tile being bought.
- **The picture shelves' tiles** (the store polish, 26 Sep 2026 — the brief's "EQUIPPED / OWNED / LOCKED: 🔒 Price, duration",
  "IN USE", never by colour alone; presentation only, `picture_shelf.dart`/`table_picture_shelf.dart`). Every tile of the Pictures
  shelf, the picker, the Animated shelf and the Tables shelf reads: picture (or preview), ONE `ShelfBadge`, name, small print. The
  badge is **"✓ Wearing"** (`t.wearing`, the store head's `_WornTag` look: solid `AppTheme.gold`, ink900, champagne rim, `Radii.xs`)
  on the worn picture and **"✓ In use"** on the laid table picture; **"✓ Owned"** (`pictureOwned`, new in all five languages) in the
  scheme's green on everything the player can put on now — free pictures and the Flowing chips too; or the price as a small purchase
  key (`PriceTag`: a pill washed and rimmed in the wallet's ink — `goldInk`, `diamondInkOn`, `hammerInkOn` — with a padlock on EVERY
  price, the gem or hammer beside it, the figure in full ink; the hammer and gem used to replace the padlock). One height for all:
  the label ramp's smallest step on ONE measured line (`ShelfBadge.lineHeightFor`: the language's badge words and figures together,
  §12.3 — a price and "आपकी" stood 3dp apart), 12dp glyphs, scaled whole rather than cut on the narrowest tile at ×1.25.
  `UnlockedTag` and `_InUseTag` (champagne on a pale wash — unreadable by day) are gone, and the term left the price pill: a
  rental's term (`rentalTerm`, so "1 day", not "1 days") or the time left (`rentalTagLeft`) is `ShelfDetail`, quiet ink and a clock
  under the name (it overflowed the tile as "42 मिनट बाकी" at 640x360 ×1.25). Names take the label ramp's natural case and
  tracking (labelSmall on faces, labelMedium on tables; 10dp at 0.8 tracking before), two lines on both shelves (a table's one line
  cut "Circle Background Patt…"). The ring or frame agrees with the badge: `shelfGoldOn` (`goldInk` — the champagne ring vanished by
  day) and a still `shelfGlow` on the worn/laid one, `shelfOwnedLine` (primary at 0.7) round everything owned, the hairline round
  the rest; locked pictures stay at full colour. `ShelfGrid` sets whole columns in a centred block with every row — the last too —
  starting at its left edge (a centred `Wrap` set a short last row between the columns), rows `Space.lg` apart; `ShelfTileEntrance`
  fades and lifts each tile once (keyed by id; `Motion.enter`, `Motion.stagger` a beat capped at 6, no timers);
  `ShelfBadgeSwitcher` crosses a tile's badge over when it changes kind (a purchase), with the store's fade and 0.985 scale;
  `PressScale` is off while a tile is being bought. `test/picture_shelf_states_test.dart` (every state and its words, glyphs,
  rings and small print on both shelves, the Flowing chips in use, the columns, the entrance, the cross-over, and at 640x360 ×1.25
  in all five languages, both themes, store, picker and the Animated shelf: every word inside its tile, names uncut, badges one
  height and never scaled below 85%); `hammer_pictures_test` now finds the padlock on every price and the term under the name.
  Pictures: `test/picture_shelf_shots.dart` (by hand, like table_shots).
- **The Tables tab** (`StoreTab.tables`, owner 15 Sep 2026; `widgets/table_picture_shelf.dart`): the sixth store shelf sells the
  cloths a player lays on their OWN table. Each tile (`TablePictureChoice`, the pack cards' width, wider than tall) shows the pair
  split down the middle — the day file on the left, the night file on the right (`TablePicturePreview`, a sun and a moon in the
  corners) — under the picture shelf's own `PriceTag` / `UnlockedTag` (made public for it) or an "In use" tick; the first tile is
  **Flowing chips — the default background** (owner: "an option to restore the default flowing chips"), drawn as the real
  `DriftingChips` over the split ground, and a tap lays nothing (`chooseTablePicture(null)`). A right-aligned `DayNightSwitch` sits over the
  shelf (owner, 16 Sep 2026: "one button for switching day to dark mode"), flipping the theme as the picture menu's does, so either half of
  every tile can be seen whole on its own ground. Locked → `unlockTablePicture` (the same three answers as
  `unlockPicture`: chip-priced at a table says `tableChipsLobbyOnly`, a short hammer/diamond wallet gets `offerWalletShelf` — now shared
  and taking a `preview` — else the question with `unlockTableBody`, whose price is `Strings.priceIn(currency, cost)`), then
  `GameState.buyTablePicture` → `chooseTablePicture`. Owned → laid at once, no "already unlocked" stop. `tableShelfOrder` runs free →
  chips → hammers → diamonds, cheapest first. **On the table it is a small square centred on the pot** (owner, 15 Sep 2026 — it was
  the whole room in place of the flowing chips for an hour, then "at the centre of the pot, small, square"): `_TableCentrepiece` in
  `_Felt`'s Stack at `(0.5, _potDy)`, side `min(w*0.37, h*0.53)` (`0.32/0.46` until the owner asked for "a little bit" bigger on
  16 Sep 2026), under the tag and the pot plinth and over the flights, painting
  `TablePictureGround` (not `TableGround`, the room's floor) with `GameState.tablePictureUrl(brightness)` — the day url on the light theme,
  the night url on the dark — from **`room.tablePicture`** (`GameState.shownTablePicture`: the table's pick among everyone seated, §7.2),
  not the viewer's own `user.tablePicture` (`laidTablePicture`, which only the store tick reads); nothing when the table shows none. **The
  `DriftingChips` show only while the table shows no picture** (`_RoomBackdrop`, a `select` on `shownTablePicture != null`; owner: "remove
  the flowing coins, we have applied the one we bought") — they come back when the last picture is taken off or its owner leaves.
**Only once the file can actually be drawn** (`_ChipsUntilDrawable`, 23 Sep 2026 review): on the server's word alone the room went
bare while a fetch the phone could not make just then (offline, a host answering with a page, a RIVE row) left the felt empty for the
sitting; the chips now stay until the file for this theme is in `PictureCache`, and a failed fetch is retried on `pictureRetryDelay`'s
clock (4, 8, 16 s, then every 30 s) by both the backdrop and `CachedPictureBox`, which never retried before. A Lottie plays. **No box** (owner: "it should look like part of the background"):
  a `dstIn` `ShaderMask` fades it radially from `backdropStrength` (0.85 — 0.55, then 0.7, until the owner asked twice for "a little bit" more on 16 Sep 2026) at the middle (`featherFrom` 0.35 of the half-side) to nothing at
  the inscribed circle's rim, so the square's corners are clear and no edge is ever drawn — an offscreen pass the size of the square,
  not the screen, which is what makes it affordable under a playing Lottie (a full-screen `Opacity` would not be). The store tile shows the pair at full strength, each half on its theme's ground
  (`_SplitGround`: bone left, obsidian right), so a transparent canvas previews as it will look. `CachedPictureBox` is `Avatar`'s loader
  for a rectangle, and shows NOTHING on a failed fetch rather than a placeholder. **A Lottie's fit follows its canvas** (16 Sep 2026:
  `pictureFitFor(lottieCanvasAspect(bytes))`, the `w`/`h` read off the file's head): near enough square covers the box, cropped — Lines
  Background 1:1, Background Pattern 3:2 — while a banner or a column past 2:1 (`bannerAspect`; 1.6:1 until Circle Background Pattern's 16:9 scene, 24 Sep 2026) is
  `contain`ed whole (Welcome, 428×123; cropped it was two letters of the middle). SVGs and bitmaps still cover. **On the felt a banner stands ABOVE the plinth** (23 Sep 2026, TP_Tall:
  fitted whole into the square centred on the pot, Welcome was a strip under "1,600" with one stroke peeking out): `TablePictureGround`
  reads the canvas off the cached bytes and draws a canvas wider than `bannerAspect` (2:1) across the square's width in the band at
  `bannerLift` −0.45 (between the status line and the plinth's top), faded at its two ends instead of radially; a square-ish canvas is
  drawn as before. **The header's tab strip scrolled** (15 Sep 2026) when six keys crowded the blurb off its two lines on a
  640dp phone at the 1.25 text ceiling — gone since 27 Sep 2026: the shelf keys have a row of their own and every one is
  always on screen ("The store navigation", below). **The header's height is MEASURED** (24 Sep 2026, B1): each line the taller of the
  Latin line and what every shelf's title and blurb take in the fonts the phone draws them in (`_measuredLine`, §12.3) —
  the Hindi Chips blurb overflowed it by a pixel on TP_Small — and the worn picture's name under it the same way;
  `test/store_header_scripts_test.dart` opens every shelf at 640x360 in all five languages at x1.0 and x1.25 with the Noto
  fallback. The Pictures blurb names every wallet a picture sells for ("chips, hammers or diamonds"; the Animated shelf at
  a table "hammers or diamonds"), since five pictures cost diamonds. `_loadPictures` loads both catalogues; the lobby rental watch covers a laid premium table too.
- **The store polish** (owner's brief, 26 Sep 2026: "a UI POLISH task, NOT a complete redesign"; `widgets/chip_store.dart`,
  presentation only — no price, pack, mark, purchase or trade path changed; the picture and table TILES are not part of it).
  **One product card**, `_StoreProductCard`, for every pack of the Chips, Diamonds, Hammers and Missiles shelves and the Premium
  Packages (`_PackCard`, `_PremiumPackCard`, `_CountPackCard` are thin wrappers now): a badge slot kept on every card so a row's
  figures stand level, the product's icon and figure, the secondary lines, the purchase key, every size from one scale on the
  card's box (`_CardMetrics`). **One figure size a shelf** (`_fitFigures`: the largest at which the shelf's widest figure fits
  beside its icon — "12 Crore" was set larger than "5.28 Crore" beside it), the largest type on the card. **A badge only where the
  owner marked the pack** (`_StoreBadge`: ⭐ POPULAR, 🔥 BEST VALUE, PREMIUM and the Premium Package filled in the card's colour,
  STARTER outlined, the chip shelf's marks now wearing `shelfMarkGlyph` too); an unmarked chip pack said its bonus on a plate and
  under its figure, an unmarked count pack its wallet's name twice, and the plate's poker chip sat on DIAMONDS. **The glow** is one
  soft orb, 0.54 of the card's side at 0.50 by night and 0.38 by day (a 0.62 orb at 0.62/0.46 over a sharp twin at 1.0/0.9), in the
  card's top right corner and clipped by it — the twin spilled past every card's right edge as a hard crescent. **The purchase
  key** (`_PriceButton`) is a raised key rimmed in the STORE's ink (`AppTheme.goldInk`, `diamondInkOn`, `hammerInkOn`,
  `missileInkOn`) with a filled arrow disc and the price in full ink, where the grey glass capsule read as switched off by day; the
  card presses to 0.97 (`PressScale`; 0.955 on its own scale before) and lights the key under the finger. **The grid fills its
  row** (`_ShelfGeometry`: columns at `Dim.packW`, widened — 186×159dp at 640x360 where 140×147 stood centred with 95dp empty either
  side, the figure 26.5px where a card-by-card fit left about 17), near square where the body allows and never over 80% of it, so
  the next row always shows; the row cut by the sheet's foot fades (`EdgeFade`, the pack shelves only: over the Pictures and
  Tables shelves' Lotties a mask is an offscreen pass every frame), and the Tables shelf keeps `Dim.packW` tiles. **The shelf
  keys** were 44dp circles in the header's row, in a strip that stopped on whole keys and scrolled — replaced on 27 Sep 2026 by
  the navigation below. The shelf's glyph, title (w700) and blurb, and the shelf itself, fade in with a 0.985 scale; a card rises
  14dp (26) in `Motion.base` (420ms until 27 Sep 2026); the grab handle is the resting hairline; the Pictures and Tables glyph is `goldDeep` by day (champagne vanished on the light sheet). **The
  Pictures head** (`_PicturesHead`): the worn picture, "Your picture", its name and `_WornTag` — "✓ Wearing · 7d left" struck in
  solid gold — between the two menus, 57dp tall on a 640x360 phone where the 96dp portrait took 105 of a 206dp shelf. Tests:
  `test/store_polish_test.dart` (the keys at the touch floor, no scroll view round them, row fill, one figure size and the
  hierarchy, badges, the orb, the key, 0.97, the head in five languages, every word inside its card at 640x360 ×1.25 with the Noto
  fonts); `store_chips`/`hammers`/`missiles_test` updated (the navigation's hammer found in the navigation, no unmarked plates).
  Pictures: `test/store_shots.dart` — every shelf (Badges since 27 Sep 2026), the store at a table (its Animated, Chips and Badges
  shelves), the picker, at 640x360, 891x411, 592x360, 915x412 and 1280x800, both themes, ×1.0 and ×1.25, and Hindi, emoji drawn
  from Noto Color Emoji — by hand, like table_shots.
- **The store navigation** (owner's brief, 27 Sep 2026: "I do NOT want the user to horizontally scroll the main store navigation
  ... all categories visible at once on small screens"; `widgets/chip_store.dart`, presentation only — no shelf, price, pack or
  purchase changed). The sheet is two rows over the products. **The header**: the shelf's glyph, its title (w700) over its blurb,
  the shelf's own balance (`ChipBalance`, `DiamondBalance`, `HammerBalance`, `PictureWalletBalances`, `MissileWalletBalances`; none
  on Badges) and the close key — the balance beside the close key on every screen, so it can never meet a shelf key; the blurb
  takes as many lines (1–3) as the widest blurb of all the shelves needs beside the widest balance of all the shelves, so nothing
  moves from shelf to shelf; a wallet pair stands in a row where that blurb keeps one line beside it (at 891x411 again, stacked at
  640x360 ×1.25). **The navigation** (`_StoreTabs`, one `InkWell` keyed `store-tab-<shelf>` a shelf) is a row of its own the
  sheet's whole width, EVERY shelf's key on screen in the lobby and at a table (the table's eight are the lobby's with Pictures
  named Animated): each key its glyph (18dp) over its word (`labelSmall` 10.5, set solid), at least 44dp each way, 45–48dp tall.
  `_StoreTabs.layoutFor` MEASURES the words in this language at this text scale and lays the keys out: one row of equal keys
  where every word fits an equal share (at most `maxKeyWidth` 120, so a tablet's row stops short of the edge); else one row of keys
  as wide as their words with the room left shared out, the 6dp gap tightened to 4 before a second row is let in (the table's
  English keys at 592x360 ×1.25 missed one row by 1dp); else balanced rows of equal keys (four over four, four over three), which
  no landscape phone here needs — every size tested (592–1280dp, ×1.0 and ×1.25, all five languages) is one row, and 480dp at
  ×1.25 is the proof of the wrap. No scroll view, no fade, no `_revealTab`. The key that is on: a gold wash laid OVER the others'
  well (champagne by day, where gold read tan; straight on the grey sheet the lit key was the darkest on the row and its word
  2.5:1), its rim in full champagne (`goldBright` / `goldDeep`, the 1.5dp rim every key has), a soft gold glow round it (blur 10,
  spread −2; the others carry no shadow at all — a transparent one is still painted blurred), its glyph in gold and its word in
  gold at w700 (`goldBright` by night, `_StoreTabs.dayWordInk` #6B5212 by day, 5.6:1 on the lit face), full size; the others
  quiet ink on a faint well and hairline, drawn to 0.96 — every change in `Motion.base` (220ms). **Height**: on a short screen
  (`Breaks.isShort`, under 380dp) the sheet has no grab handle, a step less padding at its top and foot, 4dp either side of the
  navigation (6 elsewhere) and 2dp above and below each key's glyph and word (`shortPadY`; 4 elsewhere, never under 44dp), and
  everywhere it stands `sheetGap` (3% of the screen, 10–40dp) under
  the top — it was 88% of the screen, 43dp of scrim on a 360dp phone — so with the navigation's row a 360dp phone at ×1.25 still
  shows a whole row of pack cards (131–148dp tall, the figures no smaller than before) and a glimpse of the next. The sheet enters
  in `Motion.slow` (300ms; 420 before). **On a phone** (`!Breaks.isExpanded`) **a shelf's own controls stand beside its
  products** (`_ChipStoreState._sideControls`; review, 27 Sep 2026): the Pictures head — the worn picture over the filter and
  order menus (`_PicturesHead(rail: true)`, at most 40% of the header's width) — in a column at the grid's left, and the Tables
  shelf's `DayNightSwitch` at its right (its tiles then at most a tenth under `Dim.packW`, so a 592dp phone keeps three to the
  row); over the grid, the head's 57dp had cut a 360dp phone's first row of faces through their names at ×1.25 with nothing of
  the next showing, and 844x390/915x412 the same. A tablet keeps both over the grid. **Columns** stay `_ShelfGeometry`'s least-card-width rule (`Dim.packW`): 3 at 592 and
  640, 4 at 732, 844, 891 and 915, 5 at 1280. `test/store_nav_test.dart` (86): at 592x360, 640x360, 732x412, 844x390, 915x412
  and 1280x800, ×1.0 and ×1.25, all five languages with the Noto fonts, both themes, lobby and table — no horizontal scroll view
  outside the products and none round the keys, one row, every key inside the sheet with its word whole and clear of the close
  key and the balance, and each tapped on to its shelf; one row of equal keys at 891x411 in every language; the balanced wrap at
  480dp; the Chips shelf's whole first row (3/3/4/4/4/4/5 columns), a glimpse of the next, every word whole and the figures ≥22dp
  tall in English and Hindi; the close key; the on key's glow, rim, scale and 200–250ms; every key's word no wider than its key
  (its intrinsic width — a word set with no clip always has its key's box); every word at 4.5:1 or more on its face, on and
  off, both themes (sampled from the rendered screen at 3×); and EVERY shelf, lobby and table, at 592x360 and 640x360 ×1.0 and
  ×1.25, 732x412, 844x390, 915x412 and 1280x800 ×1.25, all five languages: a whole first row, every word of it above the fold,
  and a glimpse of the next.
- **`Avatar` has two different fallbacks and the difference is deliberate.** No picture at all → the
  player's initial, which still says whose seat it is. A picture that was supposed to load and did
  not (a retired file, a dead Google URL, a phone that lost the network) → `assets/default_avatar.svg`,
  bundled rather than fetched because the whole point of it is to be there when a fetch has just
  failed. Every loader (`Image.memory`, `SvgPicture.memory`, `Lottie.memory`, fed by `PictureCache`) routes its
  `errorBuilder` to it. Which loader runs is the catalogue's `assetFormat` when the caller has one (the
  picker), otherwise the downloaded bytes' magic numbers (`pictureKindOf` in `net/picture_cache.dart`) —
  a seat pod or the top bar receives a worn picture as a bare URL, often with no extension. A RIVE row
  draws the default too: no Rive runtime ships yet. Never a
  broken box.
- **A picture is downloaded once per URL and kept on the phone** (owner, 13 Sep 2026: opening the store must never
  fetch pictures again). `PictureCache` answers from memory, then `<app support>/pictures/<sha1(url)>`, and only then
  the network, writing through a `.part` rename; `GameState` warms it when the catalogue arrives. A URL's contents are
  treated as immutable, so **a changed picture needs a new URL** — a file replaced in place is never re-fetched. **A web
  page is never kept** (16 Sep 2026): a host that will not hand a file out answers 200 with a page — Drive's sign-in for a
  file not (yet) shared, a quota notice, a captive portal — and one such answer used to be cached as the picture for good
  (TP_Tall fetched Background Pattern's day file in the minute before the owner shared it and drew a bare felt from then on).
  `_download` now refuses `text/html` and anything `looksLikeHtml` (`<!doctype html` / `<html`, not an SVG's `<!DOCTYPE svg`),
  and `_read` deletes such a file it finds on disk and fetches again; `test/picture_cache_test.dart` pins the sniff.
- **i18n**: `AppLang` × 5; `Strings(lang)` with English → key fallback. **New keys go in all five
  maps + a getter.** Teen Patti vocabulary transliterated. Still-English strings: `'YOU'`, `'Table
  ${code}'`, private-card body, picture-picker labels, `'Switch theme'`, chat `'You'`,
  the `'$winner won N'` banner (bypasses lakh formatting), and **wire hand names**.
- **Android**: `com.sungamestudio.kingteenpatti`, `sensorLandscape`, cleartext in DEBUG builds only
  (`src/debug/AndroidManifest.xml`), INTERNET (needed in release), no backup (`allowBackup="false"` +
  `data_extraction_rules.xml`, §8.1), and the `USE_BIOMETRIC`/`USE_FINGERPRINT` that androidx.biometric merges in (via
  google_sign_in's androidx.credentials) removed with `tools:node="remove"` (24 Sep 2026; the merged manifest holds
  INTERNET, BILLING and ACCESS_NETWORK_STATE only; `test/release_config_test.dart` pins all three). The Play upload is
  the **App Bundle**; `build.gradle.kts` refuses a `--split-per-abi` RELEASE build (§4). **Icon & splash** come from one file, `assets/app_icon.svg` (crown over A♥ A♠ Q♥, all paths, no fonts):
  `tool/render_icons.dart` renders `mipmap-*/ic_launcher.png` (legacy), `mipmap-*/ic_launcher_foreground.png` +
  `mipmap-anydpi-v26/ic_launcher.xml` (adaptive, bg `@color/ic_launcher_background` #2B363B), `drawable-*/splash_icon.png`,
  and the 200×80dp `splash_branding.png` (DejaVu Sans, light/night variants). `values-v31` sets `windowSplashScreenAnimatedIcon`
  + `windowSplashScreenBrandingImage`; pre-12 uses `drawable(-night)(-v21)/launch_background.xml` layer-lists. The Flutter
  `SplashScreen` shows the same SVG + line; the login title carries the SVG at 40dp. **Release is signed with the upload
  key** (`android/key.properties` → the CN=Sun Game Studio keystore, SHA-1 `7C:D8:…:55:8A`, `docs/social-login-setup.md`
  §2): `build.gradle.kts` reads that file when it exists and **falls back to debug signing when it does not**, so a clone
  without the key still builds `--release` and cannot accidentally ship — Play refuses a debug-signed upload. Both the
  file and the keystore are git-ignored, and losing either means never being able to update the listing again.
  **On the Mac this repository now lives on, `key.properties` names a DIFFERENT keystore** (found 24 Sep 2026):
  `android/upload-keystore.jks`, generated there on 10 Sep 2026 at 23:27 IST (CN=Sun Game Studio, OU=Mobile, SHA-1
  `3D:D3:39:BF:61:95:29:DA:68:C2:B5:CD:D4:B4:0D:31:4A:5C:7F:66`), after `7C:D8` had signed the first release on the Linux box
  (`~/Downloads/app-release.apk`, 1.0.0+3, OU=King Teen Patti, carries it). Neither Google nor, by every record here, Play knows
  `3D:D3`: a release built on the Mac is refused Google sign-in (`UNREGISTERED_ON_API_CONSOLE`, §12.3) and should be refused
  as an upload by a Play listing whose upload key is `7C:D8`. Build the store bundle with the `7C:D8` keystore, or have Play
  reset the upload key to `3D:D3` and register that fingerprint as an Android OAuth client — `docs/social-login-setup.md`.
  `flutter build apk --release` / `flutter build appbundle --release` both want
  `--dart-define=GOOGLE_SERVER_CLIENT_ID=…` or Google sign-in returns no `idToken` (§12.3).
- **iOS** (`flutter-client/ios/`, added 11 Sep 2026, **never compiled — no macOS on this box**): same bundle id as the
  Android `applicationId`, `CFBundleDisplayName` "King Teen Patti", landscape-only in `Info.plist` (SystemChrome only
  narrows what the system already allows, so a portrait entry would let the launch screen appear sideways),
  `UIStatusBarHidden` for immersive-sticky's absence, `NSAllowsLocalNetworking` as the `usesCleartextTraffic`
  equivalent. `tool/render_icons.dart` also writes `AppIcon.appiconset` (**alpha stripped via Pillow** — Apple rejects
  an icon with an alpha channel) and the `LaunchImage`/`LaunchBranding` sets the storyboard draws on
  `LaunchBackground.colorset` (#FAF7F0 / #0B0B0B, Android's two launch colours). Two things are deliberately
  Android-only and must stay so until the server catches up: `Purchases.start()` (the receipt goes to
  `/api/purchases/google`, so StoreKit would take money and credit nothing) and `AppUpdate` (`in_app_update` is an
  Android plugin; the server's `MIN_CLIENT_BUILD` floor still works and `storeListingUris()` needs
  `--dart-define=APPLE_APP_ID`). `docs/ios-setup.md` is the runbook.

---

## 9. Browser client (`go-server/public/`)
Vanilla JS IIFE (`client.js`, `style.css`, `theme.css`, `index.html`, `profiles/`); served at `/` by the
Go binary from `PUBLIC_DIR` (default `./public` from `go-server/`), with `/socket.io/socket.io.js`
coming from the embedded bundle in `internal/app/assets/`. `localStorage tp_token/tp_device/tp_theme`;
lobby from `session:ready`'s `config.tables` (it never calls `GET /api/tables`). No `room:kicked`, no sideshow, no rename/entry-cap/numbering.
The Google button is a stub needing `AUTH_ALLOW_FAKE_PROVIDERS` (it sends **no
idToken**; against production it is a guaranteed 401 `missing_token` — not a server fault); the Facebook button is an
HTML comment and its handler commented out while Facebook is switched off (23 Sep 2026). Chat
`maxlength=140`. Treat as a protocol smoke-test surface. **Production hides it** (`ROOT_REDIRECT=/dashboard/`,
§7.4, since 10 Sep 2026): `/` bounces to the Grafana login and the client's files are 404, while
`privacy/` and `profiles/` under the same dir stay served.

---

## 10. Requirements index (`Requirements.txt`)
1 login providers (Google and guest; Facebook switched off for now, 23 Sep 2026) · 2 DB per identity (brief says SQLite; **now Postgres by owner's decision**) ·
3 ≤5/room · 4 ≥2 to start · 5 3 lakh welcome (2 lakh until 14 Sep 2026; with 9 diamonds, 20 hammers and 1 missile; 10 Lakh since 27 Sep 2026; since 30 Sep 2026 whatever the
`welcome_rewards` rows say — chips, diamonds, hammers, missiles, pictures, emojis, some or all, §7.3 — seeded 5 Lakh, 5, 10 and 1 since the owner's seed edit that evening; 9 and 20 for its first hours) · 6a–g core play · 7 persistence · 8 room chat ·
9 +/− stepper · 10 auto-pack · **(no 11)** · 12 collapsible chat · 13 Blind/Seen × 200/5000 (and, since 18 Sep 2026, a third
category **Variation** × 50,000 / 10 Lakh (20 Lakh since 27 Sep 2026), hidden stacks, no pot limit, and since 28 Sep 2026 blind's
betting — raise as far as the chips go, no round cap — §6.4: the first player to act picks Muflis, AK47,
Joker, Hukam, Lowest Joker or Highest Joker for the hand in a server-timed 10 s, else the server picks Muflis; the lobby
shows the three categories first and a category's tables inside it, §8.4 — and since 23 Sep 2026 the two engines,
Teen Patti and Poker, in front of them) ·
14 Show reveal · 15 pot to last leaver · 16 stats (played = made a chaal) · 17 25k/25 hands ·
18 4h 10k bonus (and beside it, since 14 Sep 2026, a daily bonus of 1 lakh + 1 hammer every 24h; both removed 30 Sep 2026, with 17's milestone, owner) · 19 Seen: one double, forced showdown (brief 10 moves / code 7 rounds) ·
20 provider avatar · 21 avatar picker (a DB catalogue since 12 Sep 2026: free
pictures plus premium ones bought with chips, diamonds or (since 14 Sep 2026) hammers; not locked when seated since 13 Sep 2026 — worn at the table, and a diamond or hammer one bought there) · 22 private table · 23 landscape/M3 ·
24 merge lone rooms · 25 leave confirm · 26 4h bonus top-left (the daily bonus bottom-left) · 27 milestone bottom-right (26 and 27 gone with the rewards, 30 Sep 2026) ·
28 square cards + sweep · 29 display name · 30 entry cap (not on switch; generalised 12 Sep 2026 to a per-table
**stack band** — `config.LobbyTable.MinChips/MaxChips`, in db mode a row's `min_chips`/`max_chips`, enforced by `assertWithinTableBand` on every LOBBY door into a
seat (quick-join, join by code, create), shown on every lobby card; a switch or a consolidation move within the pair is exempt, as from the cap —
a band decides who may sit down, not who may stay or move sideways — though since 24 Sep 2026 both need the target's boot / poker buy-in) · 31 3 auto-packs → kick,
below boot → kick · 32 boot deducted at start · 33 sideshow · 34 Indian numbering + toggle.
Verbal additions: menu = exactly seen 200 / blind 200 / blind 5000; seen pot cap 1.2M; buy-chips
button; category tag; winner chip flight; action-bar icons; chat as left drawer; missed-turn warning.
**The Poker family** (owner's 45-section brief, 19 Sep 2026; `go-server/POKER_PLAN.md`, §6.5): 3-Card Poker against a
Q-high-qualifying dealer, 5-Card Draw with configurable discards, Texas Hold'em best-of-seven, Omaha exactly-two —
a family of rooms beside the Teen Patti tables, server-authoritative, sanitised per viewer, one nullable pair of ledger
columns, and Teen Patti's wire byte for byte what it was.
**The table catalogue in PostgreSQL** (owner, 23 Sep 2026: "merge all DDL and DML into 2 files" and "all table related
config store in database … the UI fetches it, stores it on the phone, and re-fetches it at every login"; then "make this
category table/db level also: Teen Patti engines / Poker engines"): two migration files, four configuration tables
(§7.3), `TABLE_CONFIG_SOURCE` (§7.4), `GET /api/tables` (§7.2), the phone's copy (§8.1), the three-level lobby (§8.4) —
PostgreSQL holding table CONFIG and never state.
**The Lucky Draw** (owner's brief, 24 Sep 2026, and the owner's BEGINNER_LUCKY_DRAW seed the same day): a six-slot wheel in the lobby,
spun, granted and recorded by the server (weighted `crypto/rand`, cooldown, idempotent `action_id`, one transaction), prizes in the
existing wallets and picture catalogues, `reward_type` open for future kinds — §7.2, §7.3, §8.4.
**The reward programs** (owner's brief, 30 Sep 2026; §7.2, §7.3, §8.1, §8.4): one system for LOGIN_STREAK and CALENDAR modes × WEEKLY
and MONTHLY periods on three generic tables, every reward through the existing wallets, ledger and catalogues, the streak derived from
the latest claim in the program's own zone, one transaction a program, idempotent per day; `GET /api/reward-programs`,
`POST /api/reward-programs/claim`; the lobby's REWARDS chip, the screen ("3 day streak" against "Day 10 reward") and the celebration.
**Report Player** (owner's brief, 27 Sep 2026; §7.2, §7.3, §8.4): a player at a table reports another at it (or one who shared
it within 10 minutes) from the player drawer; the server derives the table, game, category, variant and hand, enforces 2
reports per 24 hours per reporter in PostgreSQL, and files a PENDING row that changes nothing in the game. With both used the
drawer's Report line is off and counts down to when the next opens (`GET /api/reports/limit`).
**The winning tax, levels and badges** (owner, 26–27 Sep 2026; §6.6): the one winner of a hand at every public Seen, Blind
and Variation table pays their rate — the lowest of their level's (20% at Level 1 to 6% at Level 50, by XP) and their badges'
(Regular 20% for everyone; the Royal badges 0%, sold for rupees through support) — of their winnings of 50 Lakh or more; a
daily XP of eight sources; the lobby's level key; the store's Badges shelf.

---

## 11. Coding conventions
**Server (Go — `go-server/PORT_PLAN.md` §7 is the full list)**: `gofmt`, `go vet` clean, no `//nolint`;
doc comments on every exported identifier written as the spec, citing the Node file/function and
`Requirement N`; `game.GameError{Code, Message}` / `auth.AuthError{Code, Message, Status}` with
**snake_case** codes, compared by `Code` never by message (messages are the verbatim Node strings in
`errors.go`/`http.go`/`wire.go`); no package-level mutable state — config is passed, not imported;
`context.Context` first on anything that does I/O (Table/RoomManager methods take none);
`*slog.Logger` with Node's `meta` attribute names (`roomId`, `userId`, `code`, …); `Table` never logs
— it emits; wire types are explicit structs with json tags in the producing package (never
`map[string]any`; nil-vs-empty slices matter — PORT_PLAN §4.1); money `int64`, wire timestamps
epoch-ms `int64`; typed string enums; unexported Table internals keep Node's names minus the
underscore. **Exported Table methods post to the actor with `run`; unexported ones never do
(re-entering `run` from the actor deadlocks); a `Listener` never calls back into its table.**
`game` must not import `metrics`; nothing but `app`/`cmd` imports `socket`/`app`.
*(The Node conventions this replaced — ESM, `node:*` imports, `_private` methods, `async` money paths
through `_run` — still explain the shape of §5–§7 and of the port notes.)*
**Client**: `flutter_lints`, single quotes, British spelling; `final state = context.watch<GameState>();
final t = state.t;` at the top of `build`; M3 roles via `theme.colorScheme`; `.withValues(alpha:)`;
`late final AnimationController … ..repeat()` + `AnimatedBuilder` + `RepaintBoundary`;
`CustomPainter.shouldRepaint` compares all inputs; `LayoutBuilder` thresholds + `FittedBox`.
**The table** (`theme/table_theme.dart`, §8.4): text on the felt, its drawers and its dialogs asks `TableType` for its
ROLE (a seat's, `TableType.seat(theme, podW)`) and never sets a `fontSize` of its own; spacing is `TableSpace`, the dim
behind a drawer or a dialog `TableScrim` (dialogs through `showTableDialog`), ambient light `TableAmbient`, the table's
own colours `CasinoTableColors` (one painter, both themes); a console key states its `KeyRole` — one primary on the
console, never a second. **A card** is a `PlayingCard` at a height and nothing else: where anything on its face goes is
`CardFaceMetrics`, its corner `PlayingCard.cornerShare`, its shadows `PlayingCard.shadows`, and the viewer's fan `HandFan`
— never a second card widget, a literal card radius or a fan's numbers written out again.
**Depth** is the ladder's (`theme/depth.dart`, §8.4 "The depth pass"): a new surface states its `Elevation` —
`PremiumGlassPanel.depth`, `DepthFace`, `raisedKeyFace`, `DepthShadow` — rather than a shadow, an edge light or a sheen of
its own; a translucent surface casts round itself (`DepthShadow`), never through a `BoxDecoration.boxShadow` under it.

---

## 12. Gotchas

### 12.1 Operational
- **Verified end-to-end on 2026‑09‑07**: a Chaal tapped in the Flutter app on the Pixel 6 emulator
  produced a `chip_ledger` row and `SUM(delta) == chips` for the account. **Since 9 Sep 2026 a bet
  writes nothing at all**: the row appears only when that player packs, leaves, or the hand ends
  (§5.1), and it carries the net delta since their last checkpoint rather than the bet amount.
  Repeat the check after any change to `internal/db/ledger.go` or `Table.chargeToPot`;
  `cd tools && node chiptest.mjs` automates it (wallet on pack, on leave — mid-hand included — on
  switch, and at the hand end).
- **`pgrep -f`/`pkill -f` match your own shell command line** and kill the session (exit 137/144) —
  ~6 times so far. Use `pgrep -f "[b]ot\.js"`, find the server by port (`ss -lptn`), and **never
  put a kill and a start in one command**. **`pgrep -f 'bot.js'` also matches any shell whose command
  line merely *mentions* `bot.js`** (the `npm run bot` wrapper, a `Monitor`/`until` loop, this very
  grep) — so don't kill by pattern at all: record the PIDs you start (`npm run bot … & echo $!`, or
  `pgrep -f "[b]ot\.js"` immediately after) and `kill`/`wait` on those.
- **Restart the server after any Go change** — `go run`/the binary is a long-lived process running old
  code until restarted (a client once fell back to a default because `publicGameConfig` lacked a new
  key). `go test` caches: use `-count=1` when a DB-backed suite must really re-run. **The same goes for an edit to the
  table catalogue** (`table_configs` and the rest, §7.3): it is read once, at boot, so an `UPDATE` does nothing until the
  restart — and then only for tables opened after it (a table restored from Redis keeps its frozen rules, and is drained
  if they changed). Check what the process actually runs with `curl -s localhost:3000/api/tables` or
  `/health`'s `tableConfig.version`, never with a `SELECT`.
- **Bots reconnect to their previous table** (server restores seated users on connect). Use
  `--churn`, or wait out the 30s grace.
- A stray `go-server/gameplay` (a `go build` with no `-o`) is untracked and not git-ignored — only
  `bin/` is. Delete it or build with `ops/build.sh`.
- `adb exec-out screencap` back-to-back returns **stale duplicate frames**; sleep ≥1s between grabs.
  Detect Flutter overflows with `adb logcat -d | grep -ic overflowed`.
- `screenrecord` silently falls back to 1280×720 letterboxed; crop with ffmpeg `crop=1280:588:0:66`.
- Pixel 7 Pro AVD: `settings put secure stylus_handwriting_enabled 0`.
- Use `uiautomator dump` bounds for taps; screenshot coordinates are display-scaled. **A dump can be
  stale on Flutter screens**: each dump re-attaches accessibility and may hand back the *previous*
  screen's tree for seconds to minutes (the lobby's nodes while the table is up), so never decide which
  screen is showing from a dump taken after a transition — dialogs dump fresh. For scripted play on the
  table read pixels instead: the Chaal key is gold only on your turn, the rail's `+` only while the
  table is on screen.
- Test schemas are dropped in `t.Cleanup` (Go) / the parity harness's teardown (`--keep` keeps them
  on purpose); a crashed run can leave `test_*` schemas — see §4 psql check and `DROP SCHEMA test_x CASCADE`.

### 12.2 Server
(Behavioural; written against the Node code and still true of the Go port unless DECISIONS.md says otherwise.)
- Node's `pg` returned BIGINT/NUMERIC as **strings** unless parsed; `pgx` scans them into `int64`
  directly — keep money `int64` end to end and never a second pool/driver with different parsing.
- `search_path` is a connection *parameter* (`db.go`), never a per-connection `SET` — the pool would
  race it.
- A `Table` with no `'error'` listener emits `persistError` instead when a settle retry is abandoned;
  RoomManager attaches both listeners. Bare unit-test tables don't.
- `_endHand` credits the winner in memory only when `balances` **lacks the key** — a returned
  balance of exactly 0 is valid; never `|| fallback`.
- **A login names only a NEW account** (Go, 24 Sep 2026, fixing req. 29): `UpsertFromProfile` writes the profile's
  `display_name` on INSERT only; later logins refresh email and the provider photo and leave the name alone, so a rename
  (`POST /api/profile/name`) survives — Node overwrote it at every login, a guest's with the generated `Guest8D049`.
- Rate-limit trips ack `{ok:false, code:'rate_limited'}` (both servers). `room:create` does not
  `broadcastState`. `roomCode()` has no collision check in Node (Go regenerates until unique).
  `sweepEmptyTables` uses a hardcoded 30s. `handsToNextMilestone` says 25 (not 0)
  at an exact multiple — use `milestoneAvailable`.
- Dead surface with no caller: `GET /api/rooms` (signed-in only since 24 Sep 2026, no codes or pots), inbound `lobby:list`, `chat:history`, `ping:rtt`.
- **HTTP answers carry `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`** (24 Sep
  2026, `app.setSecurityHeaders`; not on `/socket.io/`), and a signed-in answer or a login is `Cache-Control: no-store`
  (`auth.RequireAuth`, `Login`); `GET /api/tables` keeps its own `no-cache` + ETag. HSTS is nginx's.
  (`GET /api/auth/me/hands` was **removed** on 9 Sep 2026 with the `hands` table — it now 404s.)
- **SQLite is gone entirely** (file, driver, import tool). The 41 old accounts (4,494 hands, 16,471
  ledger rows) were imported once on 2026‑09‑07; 12 of them didn't reconcile (the old `kicktest.mjs`
  wrote `users.chips` with no ledger row; old settlement clamped at 0) and got a
  `legacy_reconciliation` row each. The `test_fixture` reason is what dev-only chip grants use
  (always via a ledger row, never a bare `UPDATE users`).
- **`persisted` is reported by the ledger, not assumed.** `ledger.bet()`/`collectBoot()` return how
  much they actually banked (all of it for Postgres; `0` for a `memoryLedger` with no `persistChips`
  hook). `_endHand`'s `delta = net + persisted` therefore gives the `settle` callback *net* deltas
  summing to 0 in bookless unit tests, and *payout-only* deltas (winner `+pot`, losers `0`) in
  production. Assuming `persisted = amount` broke conservation in four unit tests.

### 12.3 Flutter
- The 1s ticker: `watch` GameState only where per-second rebuilds are wanted.
- **The viewer's fan is built in PAINT order, not the order it holds its cards** (25 Sep 2026, `HandFan.paintOrder`): the
  middle card is built last so it is on top. `tester.widgetList` over `_OwnHand` therefore reads `As 4c Kd` for a hand held
  `As Kd 4c`; read it left to right by the widgets' global x (`five_card_test.dart` `_leftToRight`), or by the entrance's
  `ValueKey('<handNo>-<dealt index>')`.
- **Every child of the felt's Stack carries a key** (26 Sep 2026, `table_screen.dart` `_Felt`). Overlays come and go in the
  middle of its children — a sideshow's thread, a hammer's, the pickers — and the framework matches unkeyed siblings by
  their place: a sideshow request appearing (the practice bots ask on nearly half their turns), or being answered,
  shifted every later child one place along, rebuilding each seat's pod as its neighbour's and dealing the viewer's hand
  again. A new overlay takes a key of its own; `test/felt_keys_test.dart` holds every child to one.
- **A `Future` cached across widget tests completes into a dead zone.** Every `testWidgets` runs in its own fake-async
  zone, and a future that completed inside one of them runs the continuation of every later `await` on it in THAT zone,
  which nobody pumps any more: the await never returns (24 Sep 2026: an asset drawn in the first screenshot of a run and
  in none after it). Keep what an asset loader has loaded as a VALUE and use it synchronously, and load such assets in
  `setUpAll`, where async is real, in the picture harnesses.
- `FractionallySizedBox` with only `widthFactor` and a childless child **collapses to zero height**
  (needed `heightFactor: 1`, `alignment: centerLeft`).
- Both `game:showdown` and `game:handEnded` hit `onShowdown`; only the latter has `nextHandAt`.
- Refused moves surface **twice** (ack + `game:error`). `GameState.refusalText` says a code in the player's language
  where it has words for it; since 24 Sep 2026 that includes the server's `sideshow_pending` (a move while the player's
  own sideshow request still waits for its answer) and `pick_pending` (Sideshow, Force Sideshow, Missile or Show while a
  player is still choosing their three cards under 5-Card) — `test/pending_refusals_test.dart`.
- **`socket_io_client` reuses a cached Socket across `io.io()` calls** (3.1.6): it caches one Manager per host and
  compares the URL's EMPTY path with the `'/'` key the socket is stored under, so it never sees the namespace as
  taken and returns the same Socket — reconnected with the auth it was first built with. Every connect must pass
  `enableForceNew()` (GameConnection does, §8.1), or a new token never reaches the server.
- **A line that mixes scripts is taller than either font's line.** Inter has no Indic glyphs; a phone draws them from
  its Noto fonts while the spaces, commas and figures stay in Inter, each run is fitted to the style's `height` in its
  own font's proportions, and the line takes the larger ascent AND the larger descent. Any box sized from
  `fontSize × height` alone can overflow in Hindi, Bengali, Gujarati or Punjabi (the chip store's header did, B1,
  24 Sep 2026): measure with a `TextPainter` (`chip_store.dart _measuredLine`). The test engine has no system fonts, so
  a layout test must load the Noto fonts and name them as the theme's fallback (`test/script_fonts.dart`) to see it.
- **Toasts are painted above the Navigator** (13 Sep 2026). `main.dart`'s `builder` wraps the Navigator in a
  transparent, never-resized `Scaffold`: a snack bar shows only on the outermost Scaffold its messenger knows, so
  every `notice` lands on top of sheets, dialogs and drawers. Before it the screens' own Scaffolds painted toasts
  *under* the picture sheet, and a refused unlock ("not enough diamonds") looked like a tap that did nothing.
  `NoticeToast.snackBar` sets its width through side margins so the bottom margin can clear the keyboard, which
  that Scaffold ignores. Never give it `resizeToAvoidBottomInset: true` — it would squeeze every screen, the table included.
- **A Lottie that moves in 3D does not move on a phone.** Flutter's `lottie` (3.5.1) ignores a layer's `or`
  (orientation) and draws `rx`/`ry` only as a `cos()` stretch about the anchor (no shear, no perspective), where lottie-web
  (the LottieFiles preview, any browser) plays the full 3D matrix — close for a lone flip (the quick-message envelope's flap
  looked right either way), wrong once `or` or a second axis joins in. Butterfly Flapping beat its wings that way, and on a phone both wings sat still on top of each
  other. Before seeding a Lottie, look for `"or"`/`"rx"`/`"ry"` keyframes; `python3 tools/lottie/flatten_orientation.py
  in.json out.json` bakes them into 2D rotation and scale on null parents, exact frame for frame, and the result is
  uploaded in place of the original (Butterfly Flapping's flattened copy lives on Drive). **Expressions do not run on phones either** (`"x"` fields — `loopOut()` is the
  common one): Flutter's lottie logs "Lottie doesn't support expressions" and the property stops after its keyframes. Check
  how much that shows (render with and without the loop baked in) before deciding a file needs reworking. When it
  matters, `python3 tools/lottie/bake_loop_expressions.py in.json out.json` writes `loopOut()` / `loopOut('pingpong')`
  out as keyframes (exact against lottie-web on Jolly King: 0 differing pixels at 251 frames); upload the result in place of the original
  (Jolly King and Jolly Queen live on Drive this way) or serve it from `go-server/public/profiles/`.
- `GameConfig.fromJson` ints fall to 0 → `config.maxPlayers == 0 ? 5 : …` guards. The same tolerant reader parses the
  cached and fetched table catalogue; its per-table figures are NULL, never 0, when the server did not send them, so a
  missing figure is never mistaken for a real zero (the screens then fall back as before).
- `_PotChips` animates only on increase (the lift, and since 30 Sep 2026 the pot coins' top-up — §8.4 "The pot's coins"). `PlayingCard`
  flips only face-down↔up.
- **The Lottie widget under the felt's `LayoutBuilder` lays the felt out on every frame** (30 Sep 2026): `Lottie`'s state calls
  `setState` at the file's frame rate, and a rebuild inside a `LayoutBuilder`'s subtree schedules the builder's layout, which re-runs
  the felt's callback and re-records its picture 24 times a second (`winner_flow_test` "the pot breathing between hands repaints its
  glow, not the felt or the screen" catches it). Anything animated on the felt is drawn by a painter from a parsed
  `LottieComposition` (`FireworksArt`, `PotCoinsArt` + `PotCoinsPainter`, `repaint:` a listenable) — never the widget. The poker felt has only 5 `seatPlaces`; the Teen Patti felt's `SeatRing` lays 2..5.
- Google sign-in works (`google_sign_in` 7.x, `net/social_sign_in.dart`); the **Web** client id is the
  `serverClientId` and arrives as `--dart-define=GOOGLE_SERVER_CLIENT_ID`, without which sign-in
  succeeds and returns no `idToken`. Facebook was removed on 10 Sep 2026, restored on 22 Sep (`5b43510`) and
  **switched off again on 23 Sep 2026** (owner, `94061a2`): the button, `SocialSignIn.facebook()`, the
  `flutter_facebook_auth` dependency and its manifest entries are commented out, not deleted — `docs/social-login-setup.md`
  §2 says what to uncomment to bring it back; no visible line offers it (the picture sheet's guest tooltip and "Use my
  Google or Facebook picture" named it until 24 Sep 2026 — `test/release_strings_test.dart`). A build with no client
  id throws `SignInUnavailable` and says so rather than blaming the network; "use provider picture"
  is still disabled. **Tested end to end on 24 Sep 2026** on the `Pixel_9` AVD (`google_apis_playstore`, a Google account
  signed in — the one emulator here that can): the release build's account picker opens under the app's own name and icon
  (Credential Manager survives R8: `CredentialProviderPlayServicesImpl` is in the bundle's dex), and then Google refuses a Mac-built
  release — logcat `status=UNREGISTERED_ON_API_CONSOLE`, the plugin `canceled: [16] Account reauth failed.` — because its
  signing certificate (`3D:D3…`, §8.4) has no Android OAuth client. That arrives as `canceled`, AFTER the account is picked,
  and it used to return null: the player was dropped back on the login screen with nothing said. A player backing out
  reads `[16] Cancelled by user.` (the back key and a tap outside alike), so `SocialSignIn.playerCancelled` now keeps only a
  description that says "cancel" (or none) as the player's and turns the rest into `SignInUnavailable`
  (`test/google_sign_in_cancel_test.dart`). **What Google sign-in needs, outside the code** (none of it could be done from
  here): `GOOGLE_CLIENT_IDS` on production — `prod.sungamestudio.com` answered 503 `provider_unconfigured` that day, so
  every store-build Google login failed after the picker (the owner set it and restarted the same afternoon; the
  probe then answered 401); Android OAuth clients for the three Play app-signing
  fingerprints (the store build's runtime signature), for whichever upload key signs a sideloaded release, and for
  this Mac's debug key `1B:0E:D1:3A:8D:6F:EF:60:41:E5:4A:86:58:73:F6:4E:C4:FE:F1:F2` (the registered debug client is the
  Linux box's `A0:54…`); and the consent screen published. `docs/social-login-setup.md` has the list.
- `main()` awaits `/api/auth/me` with no timeout before the first frame.
- Chat field `maxLength: 200` vs server 140 (see §7.4).
- **The winner's seat is `won`, not `active`** — `endHand` moves it there the moment it settles, and
  the seat keeps that status until the next deal. Any "is this seat still playing" test must count it
  (`seat_pod.dart` `_inHand` does; `_OwnHand` did not, so the viewer's own cards vanished off the felt
  at the moment they were told they had won with them). Its partner `lost` is what a showdown loser
  gets — `_OwnHand` still draws that one dimmed under a **PACKED** plate, which is wrong for a hand
  that was beaten rather than folded.
- **The bet stepper is per-turn, not per-hand.** `GameState.raiseIndex` resets on a new hand *and*
  whenever `you.options` reappears (the server sends options only to the player on turn, so that is
  this seat's turn beginning) and on `see()`, whose ladder is double the blind one. Left to persist,
  a raise made on one turn is silently re-made on the next — for more, because the ladder climbed
  with the stake it had just raised.
- **A `late final AnimationController` first read in `dispose()` breaks the teardown.** The initializer
  runs there, `vsync: this` looks up `TickerMode` on a deactivated element, the throw lands inside
  `_InactiveElements._unmount` and leaves the tree half unmounted — and the *next* screen dies on an
  `_ElementLifecycle.inactive` assertion when it reuses `tableScaffold` (the red screen after sit alone →
  Leave → join a hand, 11 Sep 2026). `DealFlights` (`widgets/deal_flight.dart` since 14 Sep 2026, rebuilt when the owner found the deal not smooth: each card the same 0.8 s trip 115 ms behind the last, on a clock as long as the deal needs — the old one-clock version cut the last cards off mid-air at four or five players — and the back rendered once into an image that one painter draws, instead of a whole `PlayingCard` with shadows, an SVG, an Opacity and a rotation per card per frame, and only to seats with a player in the hand (`dealtSeats`) where both versions had dealt cards to empty chairs too; `test/deal_flight_test.dart`) touches its controller only when a deal arrives, so
  it is nullable and created on demand (`_controller ??=`, `_controller?.dispose()`). Any controller not
  read in `initState` or on every build path needs the same. The stack showed in `flutter run`'s
  console, not in `adb logcat`.

---

## 13. Known stale / leftover items
- `go-server/PORT_NOTES/*.md` and `specs/` cite `server/src/...` files that no longer exist (they are
  the record of the port; `PORT_NOTES/README.md` says so). `go-server/internal/**` doc comments do the same
  on purpose — "Node: `_endHand`" is the spec reference, not a live path.
- `docs/load-reports/` holds only the Node-build production runs; the Go dev-box ramp (4,000 players,
  p95 5 ms) has no committed report yet.
- `go-server/.env.example` does not list `PUBLIC_DIR` (documented in `config.go`, §7.4, §14).
- `go-server/bin/` is git-ignored (so are `go-server/.env`, `*.log`, `tools/node_modules`); a stray
  `go-server/gameplay` binary from a bare `go build` is not — delete it (§12.1).
- `flutter-client/README.md` and `pubspec.yaml description` are `flutter create` boilerplate.
- **`docs/play-store/screenshots/` were re-shot on 22 Sep 2026** for the 1.1.0 listing, replacing the
  9 Sep set that still showed the pale felt and the action bar across the foot (both gone since
  10 Sep). The six now there — `01-lobby`, `02-teen-patti-blind`, `03-variation`, `04-texas-holdem`,
  `05-card-ranking`, `06-chip-store` — are the dark theme in English, shot on TP_API36 against a
  local server with `tools/bot.js` filling the seats. **They are 2400x1350, letterboxed, and that is
  deliberate**: Play refuses a phone screenshot wider than 16:9 and that AVD is 20:9, so each
  2400x1080 grab is centred on a 16:9 canvas filled with the app's own ground colour (invisible
  against the dark theme) rather than cropped — a crop would take 240px off each side, which is the
  Shop key and the whole right-hand action cluster. Re-shoot the same way, never with a side crop.
  The 512x512 icon and the 1024x500 feature graphic in the same directory are current.
- `flutter-client/ios/` has never been compiled (no macOS here) and carries no `Podfile` — Flutter
  writes one on the Mac at first build. `docs/ios-setup.md` §5 lists what is deliberately off there.
- `flutter-client/test/widget_test.dart` was **deleted on purpose** (template counter test).
- `tools/parity/lib/csharpJsonPort.js` / `protocol.test.js` guard a wire format whose C# original is gone.
- **Parity has one known failure** (13 Sep 2026): `lobby.test.js` "the entry cap guards the cheapest blind table from
  the lobby, not from a switch" tops a wallet up in PostgreSQL *while the player is seated* and expects `room:switch` to
  seat them with it (2000001 since Blind 200's cap became 20 Lakh, 27 Sep 2026; 500001 before); the Go switch carries the
  in-memory seat (1000). A seated wallet only moves at the three
  checkpoints (§5.1), so this is a test-versus-design question for the owner, not a regression. Its sibling failure —
  `session:ready.config` lacking `minClientBuild` — was a stale key list, fixed in `tools/parity/lib/harness.mjs`.
- `GameConnection.onCards`/`requestCards()` wired but unused; `room:moved` `state` branch dead.
- **The seed's table rows are hand-committed generated text** (23 Sep 2026): the VALUES in `V1.0.1__seed.sql`'s THE
  TABLES were generated from `config.Defaults().Game.EffectiveCatalogue()` by a throwaway test that was not kept. A
  default changed in `config` must be carried into the seed by hand; `TestTheSeededTableCatalogueIsTheDefaults` fails
  and names the drifting table until it is. (The seed's picture prose still says "against a 2,00,000 welcome"; the
  welcome has been 3 lakh since 14 Sep 2026.)
- **The browser client does not read the catalogue**: `go-server/public/client.js` draws `session:ready`'s `config.tables`
  (it never calls `GET /api/tables`), which follows the rows, so a table retired in the database leaves it right. The
  resident fleet does read it since the Go rebuild (27 Sep 2026; `GET /api/tables` + `tableConfigVersion`, §7.6); the Node
  fleet joined four hard-coded tables.
- The Grafana dashboard JSON links to `go-server/ops/monitoring/MONITORING.md` on `master`; production's
  imported copy still carries the old `server/ops/monitoring` link until re-imported (DEPLOY.md §6).
- Local demo video: `~/Downloads/king-teenpatti-walkthrough.mp4`.

---

## 14. Go server (`go-server/`)

The server, in production since 8 Sep 2026: a port of the Node `server/src` that is **wire-identical**
— everything a client or the database can observe on a success path is reproduced exactly (events,
acks, error codes, null-vs-absent JSON rules, JWT claims, REST bodies/statuses, schema + ledger rows,
`/health` keys, `game_*` metric names/labels/buckets). The Node tree it was ported from is gone from the
repo (top note); `go-server/PORT_PLAN.md` is the architecture + Node→Go file map + concurrency rules;
`go-server/DECISIONS.md` settles every ambiguity and **overrides** PORT_PLAN §9 where they differ;
`go-server/PORT_NOTES/*.md` + `specs/` are the per-package porting notes and behavioural specs (they
cite the removed Node files). `go-server/README.md` is the short tour; `go-server/ops/DEPLOY.md` the
deploy runbook; `steps.txt` the six-line routine.

### 14.1 Shape
- **One process, one static binary** (`CGO_ENABLED=0`), Go 1.27; the scheduler uses every core
  (`GOMAXPROCS` = all cores). **Redis is the live store** (`REDIS_URL`, §5.1): all game state lives
  there and nowhere else, and tables come back from it across a restart. Losing it loses the hands:
  nothing is reconstructed and every player simply re-joins (§5.1). Still no cluster — one process
  owns every table.
- **Table = actor.** `game.NewTable` starts one goroutine that owns the table; every mutation and
  every read of actor state is a closure posted with `run(fn)` that blocks until done — Node's
  `_run` queue made synchronous. Exported methods post; unexported internals never call `run`
  (posting from the actor deadlocks). Timers post back via `clock.AfterFunc`; `hand.turnToken`
  makes a late timer a no-op. Events (`game.Listener`) are delivered synchronously on the actor —
  a listener must never call back into that table (the kick path therefore runs in a goroutine via
  `RoomManager.tableHooks`). Lock-free atomics for `PlayerCount/IsFull/State/Version/…`.
- **RoomManager** guards only its two maps; the mutex is never held while calling a table. Joins
  reserve `playerRooms` before `AddPlayer`. **Socket layer** (`internal/socket`) likewise never
  holds its lock while calling a table or emitting. PORT_PLAN §3.4 is the deadlock checklist.
- **Own Socket.IO server** (`internal/sio`): Engine.IO v4 + Socket.IO v5 on `gorilla/websocket`,
  **websocket only** (`transport=polling` → HTTP 400 `Transport unknown`), permessage-deflate negotiated since 26 Sep 2026 (`WS_COMPRESSION`, §7.4); serves the embedded
  `socket.io.min.js` (`internal/app/assets/`, MIT, copied from the former
  `server/node_modules/socket.io/client-dist`) so the browser client in `go-server/public` works
  unchanged. Every shipped client is websocket-only.
- **DB via `pgx`** (`internal/db`): `migration/V*.sql` (embedded; Flyway-named, the founding pair since 23 Sep 2026 —
  `V1.0.0__baseline.sql` all DDL, `V1.0.1__seed.sql` DML — then DML-only seeds since 28 Sep 2026, `V1.0.2__seed-festive-capybara.sql`
  the first — applied in version order, idempotent, run at
  every start: forty-three tables (§7.3) — the welcome grant, the reward programs, money, accounts, the app version gate's rows, the sign-in each token must carry, gameplay stats, the friends graph, the player reports, the levels, badges and one-time XP missions, the picture catalogues (profile and table), the emojis, the four table-configuration tables, the Lucky Draw's three, no game
  state — §7.3), `TableConfigs.Load`/`ExportTableConfigSQL` (the table catalogue), the `Checkpoint`/`Settle` transactions of §5.1, `search_path` as a connection parameter,
  `statement_timeout` per pooled connection (`PG_STATEMENT_TIMEOUT_MS`). Money-path fixes vs Node
  (all in DECISIONS §2): wallet locks before the `hands` insert, settle retry continues after table
  destroy, client `actionId` containing `:` replaced by a uuid, `duplicate_action` on a settle retry
  = success.
- **Config** (`internal/config`): same env keys as §7.4 (`go-server/.env.example`) plus `PUBLIC_DIR`
  (browser client dir; default `./public` relative to cwd — i.e. `go-server/public` when started from
  `go-server/` — fallback `go-server/public` from the repo root), `ROOT_REDIRECT` (hides the browser
  client behind a 302 to the Grafana login in production, §7.4) and `PG_STATEMENT_TIMEOUT_MS`
  (default 15000; `0` = Node's no-limit behaviour). Integers parse strictly; unknown `LOBBY_TABLES`
  categories fail at load; `NODE_ENV=production` refuses the default `JWT_SECRET` and fake providers
  exactly like Node — and, Go only since 24 Sep 2026, any `JWT_SECRET` under 32 bytes (DEPLOY.md: check production's before
  deploying). Since 23 Sep 2026 `TABLE_CONFIG_SOURCE` decides whether the TABLE keys are read at all (§7.4):
  in db mode `app.New` loads the catalogue from PostgreSQL once, validates it — a bad row is left out with an ERROR and
  the boot carries on; an unusable catalogue falls back to the env composition — and lays it over `GameConfig`
  (`WithCatalogue`) on its own copy of the Config, before the socket layer, the REST handler and the RoomManager are
  built from it.
- **Metrics** (`internal/metrics`): every `game_*` series identical; process/runtime metrics are
  `game_server_process_*` + `game_server_go_*` (goroutines, GC, memstats, `sched_latencies_seconds`)
  — **no `game_server_nodejs_*`**. `/health` keeps every Node key (`process.node` = `go1.27.1`,
  `loopLag*` = scheduler-latency percentiles, `externalMb` = 0) and adds `goroutines`, `numCpu`,
  `gomaxprocs`. Grafana's former "Node.js" row is now "Runtime"; alerts
  `GameServerSchedulerLatencyHigh` / `GameServerGoroutinesHigh` / `GameServerMemoryHigh` replaced
  the three `nodejs_*` ones (§7.5 bundle at `go-server/ops/monitoring/`, `MONITORING.md`).
- Small honest deviations: **the reward programs** (§7.2/§7.3/§8.4; 30 Sep 2026) — three tables, `GET /api/reward-programs`,
  `POST /api/reward-programs/claim`, `reward_program` ledger rows; nothing of a table's wire, snapshot or ledger row changed; **the app version gate** (§7.1/§7.2/§7.3/§7.4; 28 Sep 2026) — `app_versions`, `GET /api/app-config`,
  426 `update_required` / 503 `maintenance` on signed-in routes and the same two codes as `connect_error` (with data), the
  per-connection `minClientBuild`, `APP_VERSION_REQUIRED` / `APP_VERSION_CACHE_MS`; a client that declares nothing is served exactly as
  before while the switch is off and no row is in maintenance; **one signed-in device per account** (§7.1/§7.2/§7.3; 28 Sep 2026) — `user_sessions`, the JWT's `sv`,
  `session_replaced` (401 and connect_error), and a login ending an earlier session's live socket with `session:replaced`;
  **Report Player** (§7.2/§7.3; 27 Sep 2026) — `POST /api/reports`, `player_reports`, `Room.ReportContexts`, the manager's recent-departure memory, and the ledger purge sparing a reported hand's rows (no wire, snapshot or ledger row of a table changed); **the table pictures** (§7.2/§7.3; merged 23 Sep 2026) — three tables, three REST endpoints,
  `user.tablePicture`, `room:state.tablePicture` on Teen Patti snapshots, `table_picture_purchase` ledger rows; **the Poker family** (§6.5) — four poker categories, `poker:action` in, the nine `poker:*` events
  out, `game`/`poker` on a poker room's `room:state`, `chip_ledger.game`/`variant`, `wrong_game`; a Teen Patti table's wire,
  snapshot and ledger rows are unchanged; **Variation Teen Patti** — the `variation` category, `game:selectVariation`, the two
  `game:variation*` broadcasts, `room:state.variation`, `variation`/`turnUp`/`wild` on reveals (§6.1, §6.4, §7.1; all of it
  ABSENT on seen and blind tables, whose wire is unchanged); **the table catalogue** (23 Sep 2026, §7.3/§7.4) — the
  tables' configuration in PostgreSQL behind `TABLE_CONFIG_SOURCE`, `GET /api/tables`, `session:ready.config.tableConfigVersion`,
  `/health.tableConfig`, draining of restored tables whose rules changed, and the two `-export-table-config` /
  `-check-table-config` flags (with the seed and in env mode every table plays, and every other key of the wire reads,
  as before); `room:state` carries `isPrivate` (13 Sep 2026, for the Flutter drawer), a seated player may wear a picture and buy a diamond one, a join is refused `settlement_pending` while that player's last hand is still being settled, JSON 404 for unknown `/api/*`, 400 `invalid_json` for bad bodies,
  HS256-only JWT verification (Node also took HS384/512), room codes regenerated until unique,
  `room:create {isPrivate:false}` validated like `quickJoin`, `already_in_room` checked before a
  table is created. Full list: PORT_PLAN §9 + DECISIONS.md. **Anything else that differs is a bug.**

### 14.2 Commands (`export PATH=$HOME/.local/go/bin:$PATH`)
```bash
cd go-server
go build ./... && go vet ./... && test -z "$(gofmt -l .)"
go test ./...                     # Postgres-backed tests use schema test_<pkg>_<rand> (dbtest.Open) and skip without a DB
go test -race ./...               # the actor/lock rules are exactly what the race detector checks
go run ./cmd/gameplay             # dev run: ./.env if present, port 3000, browser client from ./public
bash ops/build.sh                 # static, stripped, release tag → main.version → bin/gameplay; installs Go 1.27.1 to ~/.local/go if missing
./bin/gameplay -version           # gameplay v1.0.1 go1.27.1 linux/amd64
./bin/gameplay -export-table-config > tables.sql   # the env-composed table catalogue as SQL (reads ./.env; no server)
./bin/gameplay -check-table-config                 # the database's catalogue as a db boot would judge it: exit 0 / 1 / 2
# release tags (§14.4): cut one, see what it would be, and check what prod actually runs
bash ops/release.sh patch         # go-server/v1.0.0 → go-server/v1.0.1 (annotated; does NOT push)
bash ops/release.sh --current     # the newest tag and what `git describe` renders now
./bin/gameplay -migrate           # apply every migration and exit (what deploy.sh runs before a restart)
bash ops/prod-version.sh          # curls /health on production and says IN SYNC or BEHIND (exit 2)
PORT=3001 HOST=127.0.0.1 PG_SCHEMA=test_x ./bin/gameplay      # spare port + throwaway schema (drop it after)
# parity (from tools/, `npm install` once): the black-box suites against the built binary, and a traffic diff
cd ../tools && npm run parity                                 # --bin <path> / --filter a,b / --keep / --url <running server> --schema <s>
npm run parity:diff -- --a go --b http://127.0.0.1:3000 --schema-b public
```
Bots (`npm run bot`), ramptest (`npm run ramp`), the Flutter debug build (`--dart-define-from-file=config/local-emulator.json`)
and the §4 ledger-reconciliation psql check (`0`) are the acceptance run — unchanged tooling, Go on the other end.
Two Go tests borrow `tools/node_modules` and one needs `NODE_REFERENCE_DIR` (§7.6); all skip cleanly without them.

### 14.4 Release tags (added 12 Sep 2026, owner)
Tags are named **`go-server/vX.Y.Z`** — component-scoped because this repository ships three things on
their own schedules (server, Flutter client, bot fleet), so one plain `vX.Y.Z` would have to mean all
three at once. `ops/build.sh` stamps `git describe --tags --match 'go-server/v*'` into `main.version`,
which surfaces in three places: `bin/gameplay -version`, the server's first journal line, and
**`GET /health`'s `version`**. The last is the useful one — it makes confirming a deploy a `curl` from
anywhere rather than an ssh, and `ops/prod-version.sh` compares it with the newest local tag and exits
2 when prod is behind. **A restart that silently failed looks exactly like a successful one from
outside**, and that is what this exists to catch.

The Flutter client is tagged the same way, by hand: **`flutter-client/vX.Y.Z`**, cut on the commit whose `pubspec.yaml` carries that version, so the tag, the app's version name and the build number a store listing shows all agree (first cut 19 Sep 2026, `flutter-client/v1.1.0` = `1.1.0+4`, the build that carries Variation, the Poker family and the 5-Card picker). `flutter-client/v1.2.0` = `1.2.0+7`; the release after it is **`1.2.1+8`** (24 Sep 2026, owner's "fix all bugs" — pubspec had stayed at 1.2.0+7 while eleven client commits landed after the tag; `test/release_config_test.dart` holds the build number past 7). `flutter-client/v1.2.1` = `1.2.1+8` was tagged with
`config/production.json` still naming `api.sungamestudio.com`, which stopped resolving the same day, so its store build
reaches no server and was never the Play build; **`1.2.2+9`** is the same app pointed at `https://prod.sungamestudio.com`
(owner, 24 Sep 2026), tagged `flutter-client/v1.2.2` — but its privacy row opened `https://prod.sungamestudio.com/privacy/`,
which answers 404, and a Google sign-in its signature was refused ended in silence, so **`1.2.3+10`** follows the same day:
the policy at `https://sungamestudio.com/privacy/` (`PRIVACY_URL`, §3) and a refused sign-in said on screen (§12.3); the test
holds the build number past 9. **`MIN_CLIENT_BUILD` is raised to a build number that exists in the store, never to one that is only tagged here** — the floor holds every older client on the update screen, so a floor above what Play is serving takes the game down for everyone with no way for a player to get past it.

The bot fleet is tagged **`bot-play/vX.Y.Z`**, by hand (there is no `release.sh` for it): `bot-play/ops/build.sh` stamps `git describe --tags --match 'bot-play/v*'` (the `bot-play/` prefix dropped) into `main.version`, which `bin/bot-play -version` and the `bot-play starting` log line print. `bot-play/v1.0.0` is the Node fleet's; until the Go fleet's first tag is cut its build reads `v1.0.0-<n>-g<sha>`.

`ops/release.sh patch|minor|major|vX.Y.Z` cuts an annotated tag. It refuses a dirty tree and refuses a
commit that already carries one — a tag has to name a commit someone else can rebuild byte for byte,
or the stamp is a lie — and it **never pushes**: a published version number cannot be withdrawn once
anyone has fetched it, so it prints `git push origin go-server/vX.Y.Z` for a human to run. With no tags
at all, `git describe` falls back to the bare commit, which is why production reported `0d78eae`
before the first tag existed.

### 14.3 Production deploy (`go-server/ops/DEPLOY.md` has every command; `steps.txt` the short form)
**Since 29 Sep 2026 production runs a TAG and is deployed with one command** (owner: "Create a script whenever i run it
applies all ddl/dml from migration folder and then it takes latest pull and deploy backend tag"; "deploy specific tag"):
on the host, as `write`, inside `tmux`, `bash go-server/ops/deploy.sh [go-server/vX.Y.Z] [--dry-run] [--force]
[--allow-downgrade]`. It fetches branches and tags, fast-forwards the host's `master`, checks the tag out DETACHED, builds it,
runs the NEW binary's `gameplay -migrate` as the unit's user from its working directory BEFORE the restart (a failing script
stops the deploy with nothing restarted: exit 2), restarts only when the running build differs, waits for `/health` to
report the tag and watches it 30 s more, rolling back by itself when the build never answers or falls over (exit 3; 4 when
the rollback is down too). It refuses tracked edits, a second deploy (flock), an unreadable unit, a tag older than what
runs without `--allow-downgrade`, and any tag older than `go-server/v1.7.0`; it restores the previous build on a dropped
session or Ctrl-C; every run is logged in `.git/deploy-logs/`. Never run the migration files with `psql -f` as `postgres`:
tables it created would be owned by `postgres` and the server could not write to them. The host's checkout sits on a
detached HEAD at the tag it runs (since the by-hand v1.10.2 deploy); `git pull origin master` is no longer part of a deploy.
The by-hand fallback (fetch --force, checkout --detach the tag, build.sh, `sudo -u "$(systemctl show gameplay -p User --value)" ./bin/gameplay -migrate` — production's unit runs as `gameplay`, not the template's `deploy`, restart,
wait for `/health`) and the first run's command are in `steps.txt` and DEPLOY.md §3 "One-command deploy". The history
below describes the hosts and the switch to Go.

**Hosts, by public DNS on 24 Sep 2026: `prod.sungamestudio.com` → `129.121.135.218` is production; `preprod.sungamestudio.com`
→ `148.113.24.201`, the host the rest of this section was written against; `api.sungamestudio.com` no longer resolves.** The
production box's ssh user and checkout path are not recorded here — confirm them before following the commands below there.
Host `148.113.24.201` (`ssh deploy@…`), checkout `/var/www/gameplay/king-teenpatti` on **`master`**
(go-server was merged in PR #2), unit **`gameplay.service`** (the same name Node used — nginx →
`127.0.0.1:3000`, Prometheus job `game-server` with bearer token, `journalctl -u gameplay` all
unchanged). The unit's `WorkingDirectory`, `EnvironmentFile` and `PUBLIC_DIR` are all under
`go-server/`: `EnvironmentFile=/var/www/gameplay/king-teenpatti/go-server/.env` (same keys as the old
`server/.env`, which the installer copies over once; `PG_POOL_MAX=50` stays),
`PUBLIC_DIR=/var/www/gameplay/king-teenpatti/go-server/public`. No Go toolchain on the host beforehand:
`ops/build.sh` installs Go 1.27.1 into `~/.local/go` (sha256 checked against go.dev) and builds a static binary.
```bash
# every deploy is of a TAG (29 Sep 2026, owner): steps.txt step 1, DEPLOY.md "Every later deploy"
cd /var/www/gameplay/king-teenpatti && git fetch origin --tags --force && git checkout --detach go-server/vX.Y.Z
bash go-server/ops/build.sh                                       # as deploy, no sudo
sudo bash go-server/ops/install-go-server.sh                      # FIRST TIME: backs up the Node unit → gameplay.service.node.bak, copies server/.env → go-server/.env, installs gameplay-go.service AS gameplay.service, restarts, checks /health process.node = go… and /metrics 200, then rm -rf's server/ from the host (KEEP_NODE_TREE=1 skips; a differing server/.env is kept as go-server/.env.node.bak)
sudo systemctl restart gameplay                                   # every later deploy (after the tag's checkout + build.sh)
sudo systemctl status gameplay --no-pager && sudo journalctl -u gameplay -n 20 --no-pager
curl -s 127.0.0.1:3000/health | python3 -m json.tool | head -20   # process.node must start with "go"
# rollback = the PREVIOUS GO TAG, never Node (it cannot run against this schema — DEPLOY.md §5)
git checkout go-server/v1.1.0 && bash go-server/ops/build.sh && sudo systemctl restart gameplay
bash go-server/ops/prod-version.sh                                # must report the tag you rolled back to
```
Then: `/health`, `curl -s 127.0.0.1:9090/api/v1/targets` (game-server `up`), bots against production
(`cd tools && npm install && npm run bot -- --url https://prod.sungamestudio.com --count 3 --boot 200 --category blind`),
the ledger check. One-time after the first Go deploy: re-import
`go-server/ops/monitoring/grafana/dashboards/king-teenpatti.json` through the Grafana API
(`POST /api/dashboards/db`, `overwrite:true`), point Prometheus's `rule_files` at
`go-server/ops/monitoring/prometheus/alerts.yml` (the path moved) and `sudo systemctl reload prometheus` —
commands in DEPLOY.md §6. Restart semantics are Node's: SIGTERM → live pots settled (first active seat,
`all_left`), sockets closed, exit within `max(8 s, PG_STATEMENT_TIMEOUT_MS + 5 s)` — 20 s by default since 24 Sep 2026, so an
actor stuck in a stalled write still settles its pot; a budget that runs out logs `shutdown budget ran out; rooms abandoned`
with the ids (`TimeoutStopSec=30`, was 15 — the installed unit is a copy: re-copy it and `daemon-reload`, DEPLOY.md). Node stays installed on the host only
for `tools/`.

**The table-catalogue release (23 Sep 2026) is a two-step deploy** (DEPLOY.md §3 has every command). Production's
`.env` names `LOBBY_TABLES`, so the first boot resolves `TABLE_CONFIG_SOURCE` to `env` and plays exactly the menu it
did; that boot creates the four configuration tables and seeds the CODE's default catalogue, which production does not
read yet — and, on production's database (last booted by go-server/v1.1.2), runs the one guarded `ALTER TABLE users ADD COLUMN is_bot`
(run it as `postgres` first where DEPLOY.md §7 is applied). The switch is then deliberate: `./bin/gameplay
-export-table-config` with production's `.env` → psql → `-check-table-config` → `TABLE_CONFIG_SOURCE=db` in the `.env`
→ restart → `/health.tableConfig.source == "db"` and `GET /api/tables`. From then on a table, a category or an engine
is edited with an `UPDATE` and a restart; **keep the † keys in the `.env`** — a rollback to a tag older than the
catalogue reads them and knows nothing of the rows.
