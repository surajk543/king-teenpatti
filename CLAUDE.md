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
> `db/{index,ledger,users}.js` → `internal/db/{db,ledger,users}.go` (+ `schema.sql`),
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
| **Game server** | `go-server/` | **The server** — live in production since `go-server/ops/DEPLOY.md` was run (Sept 2026). Go 1.27, one static binary, **PostgreSQL 18** via `pgx`. Database-first money model (§5). Wire-identical to the Node original it replaced — same protocol, JWTs, schema, ledger rows, `/health`, `game_*` metrics (141/141 black-box parity suites). §5–§7 describe its behaviour; §14 its shape. |
| Node.js server | *(removed)* | The original implementation, removed from the repo on 8 Sep 2026 (`git log -- server/`, last commit `c19963b`; `multi_node` branch). Its behaviour is what §5–§7 document; its file names are what those sections cite. Not a rollback target unless restored from history first (`go-server/ops/rollback-to-node.sh` explains). |
| Mobile client | `flutter-client/` | **The live client.** Flutter 3.44 / Dart 3.12, Material 3 via FlexColorScheme. Android is the shipping platform; `ios/` exists and is configured (`docs/ios-setup.md`) but has never been compiled — there is no macOS here. |
| Browser client | `go-server/public/` | Zero-build vanilla-JS reference client served at `/` by the Go binary (`PUBLIC_DIR`) — **in dev only; production hides it** (`ROOT_REDIRECT=/dashboard/`, §7.4/§9) and serves just `privacy/`, `profiles/` from that dir. **Lags behind** — no sideshow, kick, rename, entry-cap or Indian-numbering UI. |
| Tools | `tools/` | Small Node ≥ 20 package (`npm install` first): `npm run bot` (practice bots), `npm run ramp` (staged load test), `npm run parity` / `parity:diff` (black-box suites in `tools/parity/`). Clients of the server; also lend `node_modules` to two Go interop tests. |
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
│   ├── cmd/gameplay/main.go      entrypoint: godotenv .env → config → db → app → listen; SIGTERM = graceful 8 s; -version
│   ├── internal/
│   │   ├── config/config.go      ALL env → one immutable Config (Defaults(); strict integer parsing); parse.go
│   │   ├── game/
│   │   │   ├── table.go          THE rules engine (actor; Table, run(), every Node _method minus the underscore)
│   │   │   ├── view.go           serializeFor / betOptions / turnOptions / summary — the redacted wire structs
│   │   │   ├── events.go         Listener (one method per table event) + payload structs
│   │   │   ├── snapshot.go       the server-side full state (cards, bets, deadlines) saved to Redis; never sent to clients
│   │   │   ├── roommanager.go    lobby menu, quick-join, switch, consolidation, sweeper; injects the Ledger
│   │   │   ├── handrank.go       Evaluate/Compare/PickWinner
│   │   │   ├── deck.go           52 cards, crypto/rand shuffle, 2-char wire codes ("As","Td")
│   │   │   ├── chat.go           in-memory per-room chat buffer (actor-owned)
│   │   │   ├── constants.go      Category / TableState / SeatState / Action / WinReason + verbatim messages
│   │   │   ├── errors.go         GameError, every snake_case code and refusal message
│   │   │   ├── ledger.go         Ledger interface (Checkpoint/Settle — the three checkpoints, §5.1) + MemoryLedger for unit tests
│   │   │   ├── clock.go          Clock interface, RealClock, Millis;  testclock/ = deterministic clock (Advance)
│   │   │   └── *_test.go         table, tablerules, sideshow, settlement, roommanager, handrank, deck, chat, wire, review_*, interop (needs NODE_REFERENCE_DIR)
│   │   ├── sio/                  our own Engine.IO v4 + Socket.IO v5 server, websocket only (protocol.go, conn.go, server.go)
│   │   ├── socket/               the game protocol on sio: handler.go (Attach, guard, one method per event, grace, resume offers), wire.go (every event/ack), payload.go; testclient/
│   │   ├── auth/                 tokens.go (JWT HS256), providers.go (Google/Facebook/guest/fake), http.go (routes, RequireAuth, WriteError), handlers.go (the 8 REST handlers), text.go
│   │   ├── db/                   db.go (pgxpool, search_path as connection param, WithTx, DropSchema), schema.sql (embedded DDL — users + chip_ledger ONLY), ledger.go (THE money transactions: Checkpoint / Settle), users.go (login upsert, rewards, names, avatars); dbtest/
│   │   ├── metrics/              names.go (every game_* metric), metrics.go (registry, Bind*, Handler, HTTPMiddleware, SafeLabel)
│   │   ├── app/                  app.go (mux, REST, socket endpoint, Start/Shutdown), health.go, static.go (PUBLIC_DIR + embedded assets/socket.io.min.js)
│   │   └── util/                 UUID, RoomCode, slog JSON logger
│   ├── public/                   browser client (index.html, client.js, style.css, theme.css) + profiles/ (15 Noto Emoji animal SVGs, Apache 2.0)
│   ├── .env.example              every env key the server reads, with defaults (+ Go-only PG_STATEMENT_TIMEOUT_MS)
│   ├── ops/                      build.sh, gameplay-go.service, install-go-server.sh, rollback-to-node.sh, lib.sh, DEPLOY.md
│   │   └── monitoring/           Prometheus + Grafana + alerts + nginx bundle, MONITORING.md (formerly server/ops/monitoring)
│   ├── PORT_PLAN.md / DECISIONS.md / PORT_NOTES/   architecture + Node→Go file map + concurrency rules; every settled ambiguity; per-package port notes + specs/ (cite the removed Node source)
│   ├── bin/                      build output (git-ignored: bin/, .env, *.log)
│   └── go.mod, go.sum
├── tools/                        Node package (npm install here first): bot.js, ramptest.mjs, parity.mjs, parity-diff.mjs
│   ├── package.json              scripts: bot / ramp / parity / parity:diff; deps socket.io-client, ws, pg, jsonwebtoken
│   └── parity/                   black-box suites (game, money, lobby, stakes, rest, protocol, resume, invalid, metrics) + lib/ (harness, launch, raw client, csharpJsonPort.js)
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
    │   ├── theme/app_theme.dart `AppTheme.paletteFor(scheme, category, bootAmount)` → TablePalette: seen=gold, blind<1000=sapphire(tertiary), blind≥1000=royal purple; used by lobby card, felt, _CategoryTag ("BLIND · 5,000")
    │   ├── screens/table_screen.dart `_MissedTurnsStrip` (zero-height OverflowBox over the Pack button: `_BlindMovesPill` + `_MissedTurns`, always visible), `_BetFlights` (chip from seat to pot on every contributed increase), `_AmbientGlow`
    │   ├── screens/lobby_screen.dart `_DriftingChips` ambient background
    │   └── widgets/seat_pod.dart `BubbleSide {above,left,right}`: chat bubble hung off the column END in a zero-height OverflowBox — rim seats grow it up over their own cards/badge (max 1.7×podW, pointer tail up at the pod), the viewer's grows up from the column top (2.1×podW, tail down). Pods paint AFTER tag/pot/status in the felt Stack so a bubble is never hidden.
    │   │     GameState: bubbles hold `bubbleFor` = 8s; a second line from the same player queues in `_bubbleQueue` and shows when the first expires; `_clearBubbles()` on leave/kick.
    │   │     `_MissedTurnsStrip`: width comes from the pod geometry, not a share of the screen — `podLeft - left - Space.xl`, clamped 110..360 (200.1 at 891x411, 301.3 at 1280x800). Compact (one line, no explanation) when that corner is under 260, on a compact/short screen, or when the blind-moves row is sharing the plate: four rows grew it up into the left seat's caption. `_CategoryTag` text shrinks via FittedBox (slot w*0.30).
    │   ├── net/game_connection.dart  Socket.IO streams; every move carries a fresh actionId
    │   ├── net/api_client.dart   REST
    │   ├── models/dtos.dart      wire DTOs mirroring server JSON
    │   ├── screens/{login,lobby,table}_screen.dart
    │   ├── widgets/              premium_surface, seat_pod, playing_card, poker_chip, liquid_fill,
    │   │                         fireworks, avatar, buy_chips, rules_sheet
    │   ├── theme/app_theme.dart  FlexColorScheme + shadow/lift helpers
    │   └── l10n/strings.dart     hand-written 5-language table (en/hi/bn/gu/pa)
    ├── assets/card_back.svg
    ├── test/number_format_test.dart
    ├── android/                  applicationId com.sungamestudio.kingteenpatti, sensorLandscape, cleartext on
    └── ios/                      bundle id com.sungamestudio.kingteenpatti, landscape-only, status bar hidden,
                                  NSAllowsLocalNetworking; GIDClientID + URL scheme come from Flutter/*.xcconfig.
                                  NO Podfile (Flutter writes one on the Mac); never built here — docs/ios-setup.md
```

There is no CI, Dockerfile, ESLint or Prettier anywhere. `cd go-server && go test -race ./...`
(+ `go vet`, `gofmt -l`), the parity harness (`cd tools && npm run parity`, §7.6/§14) and
`cd flutter-client && flutter analyze && flutter test` are the whole verification story.

---

## 3. Environment requirements

| Tool | Version in use | Notes |
|---|---|---|
| **Go** | 1.27.1 at `~/.local/go` | **Not on PATH** — `export PATH=$HOME/.local/go/bin:$PATH`. `go-server/ops/build.sh` installs exactly this version there when missing (sha256 checked against go.dev). `go.mod` says `go 1.27`. |
| Node.js | v22.22.1 (`>=20`) | Still needed for `tools/` (bots, ramp, parity — ESM, `node:test`), for two Go interop tests that borrow `tools/node_modules`, and by the Flutter toolchain. **Not** needed to run the server. |
| npm | 9.2.0 | `cd tools && npm install` once. |
| **PostgreSQL** | 18.6, local, port 5432 | DB `gameplay`, user/password `postgres`/`postgres`. Default `DATABASE_URL` in config points here. `psql` and `pg_isready` are installed. Go tests skip (not fail) when it is unreachable. |
| Flutter | 3.44.7 stable (`/snap/bin/flutter`) | Dart 3.12.2 — this is the **minimum** `pubspec.lock` accepts. Code uses records, switch expressions, `'k': ?v` null-aware map entries, `DropdownButtonFormField(initialValue:)`. |
| Android SDK | `~/Android/Sdk` | **Not on PATH** — `export PATH="$PATH:$HOME/Android/Sdk/platform-tools:$HOME/Android/Sdk/emulator:$HOME/Android/Sdk/cmdline-tools/latest/bin"` |
| Emulator images | `system-images;android-36;google_apis;x86_64` (+ android-34) | AVDs: `TP_API36` (Pixel 6), `TP_Small` (Nexus 5, 640×360dp — tightest), `TP_Tablet`, `TP_Tall` (Pixel 7 Pro), `Pixel_6_API_34`. |
| ffmpeg | 8.0 | stitch/crop `screenrecord` output |
| Python 3 + Pillow | 12.x | ad-hoc screenshot diffing, launcher-icon generation |
| Linux desktop toolchain | absent | `flutter test` prints a GTK/clang warning first — noise |

Shell quirks on this machine: zsh with `grep`→`ugrep` and `find`→`bfs` aliases; an unquoted
`--include=*.js` (or `*.go`) fails with "no matches found" — quote it; `cd` in one Bash call can leak
into the next — use absolute paths.

Server ↔ client: the app's default `SERVER_URL` is the **production backend
`https://api.sungamestudio.com`** (REST + Socket.IO over TLS; verified 2026‑09‑08 to run the current
server code). For a local server build with `--dart-define=SERVER_URL=http://10.0.2.2:3000`
(the emulator's alias for the host loopback) or `http://<lan-ip>:3000` for a real device on the LAN —
`usesCleartextTraffic` stays on for exactly that.
`usesCleartextTraffic="true"` in the manifest makes plain http work.

---

## 4. Commands

### Server (`cd go-server`, `export PATH=$HOME/.local/go/bin:$PATH`)
```bash
cp .env.example .env            # optional; defaults work for local dev. Set JWT_SECRET for prod.
go run ./cmd/gameplay           # → http://0.0.0.0:3000 (needs Postgres up); reads ./.env; browser client from ./public
go build ./... && go vet ./... && test -z "$(gofmt -l .)"    # compiles, vets, formatted — part of "done"
go test ./...                   # every package; Postgres-backed suites use schema test_<pkg>_<rand> and skip without a DB
go test -race ./...             # the actor/lock rules (§14.1) are exactly what the race detector checks
go test ./internal/game -run 'Sideshow'        # one package / tests matching a regex (names are sentences: TestASideshowNeedsThreePlayersInTheHand)
go test -count=1 ./internal/db ./internal/app  # force the DB suites to re-run (no cache)
bash ops/build.sh && ./bin/gameplay            # static, stripped, version-stamped binary (bin/ is git-ignored); -version prints the stamp
PORT=3001 PG_SCHEMA=test_x ./bin/gameplay      # spare port + throwaway schema (drop it after)
```

### Tools (`cd tools`, Node ≥ 20 — `npm install` once)
```bash
npm run bot -- --count 3 --boot 200  --category blind --offset 0            # practice bots on http://localhost:3000
npm run bot -- --count 3 --boot 5000 --category blind --offset 4            # 2nd group needs its own --offset
npm run bot -- --count 8 --boot 200 --category blind --churn 40             # bots hop tables → room:switch testable
npm run bot -- --url https://api.sungamestudio.com --count 3 --boot 200 --category blind   # against production
npm run ramp -- --url http://localhost:3000 --stages 10,50,200,1000 --hold 40 --boot 200 --category blind --out ramp.json
npm run parity                                                              # black-box suites vs ../go-server/bin/gameplay (build first)
npm run parity -- --filter game,money --keep                                # some suites; keep server logs + schemas
npm run parity -- --url http://127.0.0.1:3000 --schema public --filter rest # attach to a running server instead of spawning
npm run parity:diff -- --a go --b http://127.0.0.1:3000 --schema-b public   # frame-by-frame traffic diff (spawned binary vs live)
```

Find/stop the server safely (read §12.1 before reaching for `pkill`):
```bash
ss -lptn 'sport = :3000'                      # shows the PID
kill <pid>                                    # SIGTERM: settles live pots, closes sockets, exits within 8 s
nohup ./bin/gameplay > /tmp/server.log 2>&1 &        # start in a SEPARATE command from the kill (from go-server/)
```

Useful Postgres checks:
```bash
PGPASSWORD=postgres psql -h localhost -U postgres -d gameplay -c "select display_name, chips from users order by chips desc limit 10"
# ledger must reconcile to wallets:
PGPASSWORD=postgres psql -h localhost -U postgres -d gameplay -Atc "select count(*) from users u join (select user_id, sum(delta) s from chip_ledger group by user_id) l on l.user_id=u.id where l.s <> u.chips"   # expect 0
PGPASSWORD=postgres psql -h localhost -U postgres -d gameplay -c "select nspname from pg_namespace where nspname like 'test_%'"   # leftover test schemas (should be none)
```

### Flutter client (`cd flutter-client`)
```bash
flutter pub get
flutter analyze                 # must be clean (it is)
flutter test                    # 6 tests (number formatting)
flutter test tool/render_icons.dart   # re-render launcher/adaptive/splash PNGs from assets/app_icon.svg (not part of `flutter test`)
flutter build apk --debug       # ~7s incremental; build/app/outputs/flutter-apk/app-debug.apk
flutter build apk --debug --dart-define=SERVER_URL=http://10.0.2.2:3000   # local server on the emulator
flutter build apk --debug --dart-define=SERVER_URL=http://192.168.1.10:3000  # local server, real device
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell monkey -p com.sungamestudio.kingteenpatti -c android.intent.category.LAUNCHER 1   # launch
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
**PostgreSQL holds money and audit only, in exactly two tables — `users` and `chip_ledger`.** There
is no `game_states`, no `pots` and no `hands` table any more (`schema.sql` drops all three, guarded;
see §7.3). A bet is **not** a database transaction, and neither is the deal.

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
  → UPDATE users SET chips = chips + delta, <counters>     DELTA, never an absolute
  → INSERT chip_ledger (…, action_id UNIQUE)               one row per player per checkpoint
  → COMMIT
```

- **Deltas, never absolutes.** `delta = seat.chips now − chips as last written to PostgreSQL`
  (`chipsWritten` on the hand's contribution record, so it lives in the snapshot and survives a
  restart). It is never `SET chips = <live value>`: a reward credits PostgreSQL without touching the
  Redis seat, and an absolute overwrite at the next checkpoint would erase it.
- **Rewards are lobby-only.** `POST /api/rewards/milestone|bonus` return **409 `seated`** before any
  DB work, matching the rule display name and avatar already had. That closes the concurrent-credit
  hole at its source; the delta above is the belt to that pair of braces. Its real value is that it
  makes an invariant true: *a seated player's wallet cannot change except at these three moments.*
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
`handRank.js` → `handrank.go`, `deck.js` → `deck.go`; `_method` → `method`.

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
  pot cap is `maxPot` (0 = uncapped).
- **SEE** is free, allowed off-turn, doesn't move the turn or reset the clock. After `maxBlindMoves`
  (4) blind bets the cards auto-reveal; that last bet is still charged at the blind rate.
- **Turn clock** 25s → `missedTurns++`, `_pack('timeout')`; at `maxMissedTurns` (3) emits
  `kick {reason:'idle'}`. `missedTurns` resets to 0 only **after a successful move**. The table only
  *emits* `kick`; RoomManager/socket layer removes the player.
- **Rounds** count when the turn steps *over* `startSeat` (by `_distance`, not equality).
  `round >= maxBetRounds` → forced showdown. `pot + stake > maxPot` → `POT_LIMIT` showdown.
- **Show**: exactly 2 active seats; costs `showCost = chaal`; **null/unaffordable cost →
  `insufficient_chips`** (a show is never free). Exact ties: show-payer loses, else nearest the dealer's
  left. The pot is never split.
- **Sideshow** (req. 33): `sideshowBlockedReason` order `no_hand | not_in_hand | not_your_turn |
  sideshow_pending | already_asked | too_few_players | you_are_blind | no_neighbour |
  neighbour_is_blind`. Clock stopped while pending (6s). Only `toUserId` may answer. Tie goes
  **against the asker**. When the *asked* player loses, `_pack(..., {advanceTurn:false})` — the turn
  never left the asker. Clock re-armed with `_setTurn(fromSeat, {freshTurn:false})` so
  `sideshowAskedThisTurn` survives (one ask per turn). Participant leaving → resolved `'left'`;
  `_endHand` clears the timer. The sideshow is **free** (the brief specified no bet — flagged as an
  exploit vs. standard rules).
- **Leaving mid-hand** = pack; stake stays; `leftMidHand=true`; `lastDeparture` gets the pot if all
  leave (`ALL_LEFT`). Winner identified by **userId**, not seat.
- `_sweepUnfunded` only between hands (`if (this.hand) return`); it sets `seat.kickPending` so a
  seat is kicked once even if two sweeps run before the queued removal lands.
- **`serializeFor` redaction (do not break)**: `you.cards` only when `!viewer.isBlind`; other seats
  carry only `cardCount`; on BLIND tables others' `chips` is **`null`** (not 0) + `chipsHidden:true`;
  `missedTurns/maxMissedTurns/options` only in `you`; `sideshow` carries ids/seats/`expiresAt`, never
  cards. Public everywhere: `lastBet, lastAction, contributed, isBlind, connected, status`.
- `_snapshot()` is the *server-side* full state (cards and the hand's per-player unbanked bets
  included) saved to the **live store (Redis) only** — never to PostgreSQL, never to a client.
- **Events**: `state, seatUpdated, chat, handStarted, cards, turn, action, showdown, handEnded, kick,
  sideshowRequested, sideshowReveal, sideshowResolved, persistError, error`. `seatUpdated` has no
  listener; `persistError` is logged by RoomManager only.

### 6.2 `roomManager.js` (→ `roommanager.go`; DECISIONS §3 lists the few deliberate differences)
- `quickJoin`: `_assertNotSeated` → `assertStakeAllowed` (`tableStakes`) → `normalizeCategory`
  (unknown → **seen**) → `assertTableOffered` (`lobbyTables` pair) → chips ≥ boot →
  `_assertUnderEntryCap` → fullest public non-full table with same boot+category, else `createTable`.
  Sync.
- `switchTable` (**async**): same boot+category, **no entry cap**, leaves with reason `'moved'`
  (skips consolidation). `leave`, `destroyTable`, `consolidateTables`, `sweepEmptyTables`,
  `_movePlayer`, `shutdown` are **async** and must be awaited. `leave` deletes `playerRooms` *before*
  awaiting the removal.
- `createTable`: public seen → `{maxRaiseSteps: 2, maxBetRounds: 7, maxPot: 1_200_000}`; private →
  boot forced to `privateBoot`, `{maxPot: 500_000, maxRaiseSteps: 2}`; public blind → full ladder,
  uncapped. Constructs `Table` with `ledger: this.ledger` (defaults to `createLedger()` unless tests
  pass `settle`/`persistChips`).
- `lobbyOptions()` → `{categories, stakes, tables:[{category, bootAmount, maxPot, maxBlindMoves}],
  entryCap*, privateBoot, privateMaxPot}`. Clients render `tables` verbatim.
- Sweeper interval (unref'd): merges lone players on idle public tables of the same
  `category:boot` into the oldest; sweeps empty tables older than a **hardcoded** 30s.

### 6.3 `handRank.js` / `deck.js` (→ `handrank.go` / `deck.go`)
`HIGH_CARD 0 < PAIR < COLOR < SEQUENCE < PURE_SEQUENCE < TRAIL 5`. Runs: **A-K-Q > A-2-3 > K-Q-J >
… > 4-3-2**. Suits never break ties. `pickWinner` is exported but `table.js` re-implements the tie
loop — keep consistent. Wire hand names are the **English** `CATEGORY_NAMES` and Flutter shows them
untranslated.

---

## 7. Server — platform

Go equivalents: `socket/index.js` → `internal/socket/{handler,wire,payload}.go` on top of
`internal/sio` (our own Engine.IO/Socket.IO server, websocket only); `auth/routes.js` →
`internal/auth/{http,handlers}.go`; `db/` → `internal/db/`; `config/index.js` →
`internal/config/config.go`; `metrics/index.js` → `internal/metrics/{names,metrics}.go`. The full
event-by-event contract is also written down in `go-server/PORT_NOTES/specs/spec-socket-protocol.md`.

### 7.1 Socket.IO contract (`socket/index.js` → `internal/socket/handler.go`, `wire.go`)
Handshake: JWT in `handshake.auth.token`; `io.use` is async (`await findById`). Failures →
`connect_error` `missing_token | invalid_session | unknown_user | unauthorized`. One live socket per
user (`session:replaced` to the old one). On connect: `session:ready {user, config}`; if still seated
→ `room:joined` + `chat:history` (**why restarted bots land on their previous table**).

`guard`: rate limit **30/5s per socket** (a trip acks `{ok:false, code:'rate_limited'}` **and** emits
`game:error rate_limited` — both servers; the old "no ack" note was stale), then ack
`{ok:true,…}` or `{ok:false, code, message}` **and** `game:error` (reported twice — clients dedupe).

| Client → server | Payload | Ack |
|---|---|---|
| `lobby:list` | `{category?}` | `{tables, options}` (used only by scratch/tests) |
| `room:quickJoin` | `{bootAmount?, category?}` | `{roomId, code, category}` |
| `room:create` | `{isPrivate=true, category?}` | `{roomId, code, category}` — boot ignored |
| `room:joinCode` | `{code}` | `{roomId, code, category}` |
| `room:switch` | `{}` | `{roomId, code, category}` |
| `room:leave` | `{}` | `{roomId}` or `{}` |
| `game:action` | `{action, amount?, actionId?}` | table.act result; `actionId` (≤64 chars) becomes the ledger row's unique id |
| `game:sideshowRespond` | `{accept}` (only `=== true` accepts) | `{accepted, packedUserId}` |
| `player:requestCards` | `{}` | `{cards}` (empty unless seen) |
| `chat:message` | `{text}` | `{messageId}` — own 5/5s limiter (`chat_rate_limited`) |
| `chat:history` | `{}` | `{count}` (no client sends it) |
| `ping:rtt` | `sentAt` | `{sentAt, serverTime}` — **unguarded**, no `ok` |

| Server → client | Audience |
|---|---|
| `session:ready {user, config}` / `session:replaced` | socket |
| `room:joined` / `room:state` — `serializeFor(viewer)` | **per viewer** |
| `room:moved {fromRoomId, toRoomId, code, message}` — **no `state`**; the snapshot is the `room:joined` that follows | socket |
| `room:left` / `room:closed` / `room:kicked {roomId, reason, message}` | socket |
| `game:handStarted {…participants}` then per-socket `player:hand` | room |
| `player:cards {cards}` | owner only |
| `game:turn {userId, seatIndex, deadline, timeoutMs}` (no options) | room |
| `game:yourTurn {deadline, timeoutMs, options}` | player on turn |
| `game:action {userId, action, amount, pot, stake, reason?\|auto?}` | room |
| `game:sideshowRequested` / `game:sideshowResolved` | room (no cards) |
| `game:sideshowReveal {reveal}` | **the two players only** |
| `game:showdown {reveals, reason}` / `game:handEnded {…nextHandAt}` | room |
| `chat:message` / `chat:history` / `game:error` | room / socket / socket |

Production: `https://api.sungamestudio.com` (REST + Socket.IO over TLS) — the Flutter default since 2026‑09‑08; runs the current server code (verified: 10-rung blind ladder, `invalid_bet` on string amounts).
Client coverage: **Flutter** never sends `lobby:list`, `chat:history`, `ping:rtt`, and never listens
to `game:handStarted`, `player:hand`, `game:turn`, `game:yourTurn` — it derives turn and options
from `room:state.turn` / `you.options`. Changing `you.options` affects Flutter; changing
`game:yourTurn` does not. **Browser** ignores `room:kicked` and all `game:sideshow*`.
Input guards (`socket/index.js`): `game:action.amount` must be a JS number and safe integer (strings/arrays/booleans → `invalid_bet`);
rate-limited requests are acked `{ok:false, code:'rate_limited'}`; `RoomManager.join()` asserts one seat per player (also closes
`room:create` to a seated player); `player:requestCards` outside a table → `not_in_room`. Covered by `internal/socket/invalidmoves_test.go` and `tools/parity/invalid.test.js`.
Disconnect: seat held `reconnectGraceMs` (60s) then `await rooms.leave(userId,'disconnected')`; just before
leaving, `resumeOffers.set(userId, {roomId, at})`. On connect: if still seated → `room:joined` + `chat:history`
re-sent (resume); else `takeResumeOffer(userId)` (fresh within `resumeOfferMs`, table alive and not full, offered
once) rides on `session:ready.resume {roomId, code, category, bootAmount}` and the Flutter client auto-joins it
with `room:joinCode`. Voluntary leave / kick never create an offer (the grace timer finds no seat).
`room:switch` must `untrackRoom` *before* `switchTable` and re-track on failure.

### 7.2 REST (`auth/routes.js` → `internal/auth/http.go` + `handlers.go`)
`POST /api/auth/login {provider: google|facebook|guest, idToken|accessToken|deviceId, displayName?}`
→ `{token, user, isNew, welcomeChips}`; `GET /api/auth/me`; `POST /api/rewards/milestone|bonus`
(**409 `seated` while at a table** — rewards are lobby-only so a seated wallet only ever moves at the
three checkpoints, §5.1); `GET /api/profiles` (unauthenticated);
`POST /api/profile/avatar {avatar|null}` and `POST /api/profile/name {name}` (409 `seated` while at
a table; live in `playerRoutes({isSeated})`, **not** `authRoutes`);
`GET /api/rooms` (no client);
**`POST /api/purchases/google {productId, purchaseToken}`** — verifies the token with Google and banks
the pack through a `purchase` ledger row (action_id `gplay:<token>`), so a replay credits once. **There
is no Apple counterpart**, which is why the Flutter chip store does not start on iOS (§8.4);
`GET /health`. Errors `{error: code, message}`. Guest id = `sha256('teenpatti:'+deviceId)`, deviceId
≥ 8 chars. `AUTH_ALLOW_FAKE_PROVIDERS=true` lets google/facebook skip verification (tests, browser
stubs). **A refused login is logged** (`login refused` WARN: provider, code, status, reason with the
credential cut out — `handlers.go logRefusedLogin`, since 10 Sep 2026); other AuthErrors are written
to the client only, so `journalctl -u gameplay | grep 'login refused'` is where a "Google sign-in
doesn't work" report starts.

### 7.3 Database (`db/` → `internal/db/`)
`pg` Pool (`DATABASE_URL`, `PG_POOL_MAX`), `search_path` set as a connection **option**
(`-c search_path=<schema>,public`). `openDatabase({url, schema})` creates the schema if missing and
runs `schema.sql` (fully idempotent: IF NOT EXISTS / CREATE OR REPLACE / DO-block trigger).
`withTransaction(fn)` = BEGIN/COMMIT/ROLLBACK. `dropSchema()` refuses `public`. **int8 and numeric
are parsed to JS numbers** (`pg.types.setTypeParser(20|1700)`) — without that, `chips` and `SUM()`
come back as strings.

Tables — **there are exactly two**: `users` (wallet = `chips BIGINT CHECK ≥ 0`, counters,
`milestone_claimed`, `next_bonus_at`, `avatar_choice`, `deleted_at`) and **`chip_ledger`** (`action_id UNIQUE`,
`hand_id`, `delta`, `balance`, `reason`; append-only trigger). `game_states`, `pots` and `hands` were
all removed on 9 Sep 2026 — PostgreSQL holds money and audit only. `schema.sql` drops each on an
existing database, but **only when it is empty**, so a restored backup is left for a human; every
reference to a retired table goes through `EXECUTE` because PL/pgSQL plans before it evaluates and a
direct reference stops parsing once the table is gone (that bug crash-looped production on
9 Sep 2026 — `d949179`). Timestamps
are epoch-ms BIGINT. Rewards: milestone 25,000 / 25 hands (`didChaal` only), timed 10,000 / 4h —
constants in `users.js`. Display names: `NAME_PATTERN = /^[\p{L}\p{N}][\p{L}\p{N}\p{M} ]*$/u` —
**`\p{M}` is essential** for Indic vowel signs.

**`users` rows are never deleted** (owner's decision, 10 Sep 2026): trigger `users_no_delete`
(`users_immutable_rows()`, `schema.sql`, created only when missing) raises on every DELETE from every
caller — the server never issues one; the deletion route was removed on 10 Sep 2026 at the
owner's request, so nothing in the code deletes or pseudonymises a user. Removing a row is a
deliberate privileged step: `sudo -u postgres psql gameplay`, `ALTER TABLE users DISABLE TRIGGER
users_no_delete`, delete, re-enable. Prod's app role `gameplay_app` still **owns** the table and the
function (it runs `schema.sql`), so it could disable the trigger; DEPLOY.md §7 has the one-time
ownership transfer that closes that (owner → `postgres`, `GRANT SELECT, INSERT, UPDATE` back), which
needs sudo on the host and is why the function is create-if-missing rather than CREATE OR REPLACE.
Test: `TestUserRowsAreNeverDeleted` (`internal/db/users_delete_test.go`).

Ledger `reason` values: `welcome_bonus, hand_packed, hand_left, hand_win, hand_loss,
milestone_reward, timed_bonus, purchase, account_deleted, legacy_reconciliation, test_fixture`.
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

| Env | Default | Purpose |
|---|---|---|
| `NODE_ENV` | development | `production` refuses to start on the default JWT secret / fake providers (the Go binary keeps the key name; the unit sets it) |
| `PORT` / `HOST` / `CORS_ORIGIN` | 3000 / 0.0.0.0 / `*` | |
| `JWT_SECRET` / `JWT_EXPIRES_IN` | dev-only-insecure-secret / 30d | |
| `GOOGLE_CLIENT_IDS`, `FACEBOOK_APP_ID/SECRET` | empty → 503 | |
| `AUTH_ALLOW_FAKE_PROVIDERS` | false | |
| **`DATABASE_URL`** | `postgres://postgres:postgres@localhost:5432/gameplay` | |
| **`PG_SCHEMA`** | `public` | tests use `test_<suite>_<rand>` and drop it after |
| **`PG_POOL_MAX`** | 10 | |
| `PG_STATEMENT_TIMEOUT_MS` | 15000 | **Go server only**: Postgres `statement_timeout` per pooled connection so a hung query fails one ledger write instead of freezing a table; 0 = no limit (Node behaviour) |
| `WELCOME_CHIPS` / `BOOT_AMOUNT` | 200000 / 200 | |
| `TABLE_STAKES` | `200,5000` | empty = any (tests) |
| `LOBBY_TABLES` | `seen:200,blind:200,blind:5000` | the menu; empty = any pair (tests) |
| `MAX_PLAYERS_PER_ROOM` / `MIN_PLAYERS_TO_START` | 5 / 2 | 5 is also hardcoded in Flutter `_places` and browser CSS |
| `TURN_TIMEOUT_MS` | 25000 | |
| `MAX_BET_ROUNDS` / `POT_LIMIT_MULTIPLIER` / `MAX_RAISE_STEPS` | 20 / 1024 / 8 | defaults only; `createTable` overrides all three per category (seen: 7 / 1024 / 2, blind: 0 / 0 / 0) |
| `SEEN_MAX_RAISE_STEPS` / `SEEN_MAX_BET_ROUNDS` / `SEEN_MAX_POT` | 2 / 7 / 1200000 | brief says "10 moves"; code is 7 rounds |
| `MAX_BLIND_MOVES` | 4 | |
| `ENTRY_CAP_BOOT` / `ENTRY_CAP_CATEGORY` / `ENTRY_CAP_MAX_CHIPS` | 200 / blind / 500000 | |
| `MAX_MISSED_TURNS` | 3 | |
| **`MIN_CLIENT_BUILD`** | 0 | The oldest client build allowed to play, sent to every client in `session:ready.config.minClientBuild`. A client below it is held on the update screen with no way past (Flutter `_belowMinimumBuild`/`_forceUpdate`). **0 = no floor**, which is what production runs; raise it only after the newer build is actually live in the store, or the floor locks everyone out of a version they cannot yet install. This is the server-authoritative gate — Play's own in-app check (`AppUpdate`) is a separate, best-effort nudge that fails open. |
| `SIDESHOW_TIMEOUT_MS` / `SIDESHOW_MIN_PLAYERS` | 6000 / 3 | |
| `DISPLAY_NAME_MAX` | 24 | also hardcoded: providers.js `.slice(0,24)`, Flutter login/lobby `maxLength: 24` |
| `PRIVATE_BOOT` / `PRIVATE_MAX_POT` / `PRIVATE_MAX_RAISE_STEPS` | 200 / 500000 / 2 | |
| `NEXT_HAND_DELAY_MS` / `CONSOLIDATE_INTERVAL_MS` / `RECONNECT_GRACE_MS` | 4000 / 15000 / 60000 | |
| `RESUME_OFFER_MS` | 600000 | how long a lapsed seat's table is offered back via `session:ready.resume` |
| `BLIND_MAX_RAISE_STEPS` / `BLIND_MAX_BET_ROUNDS` / `BLIND_POT_LIMIT_MULTIPLIER` | 0 / 0 / 0 | blind tables: 0 = unlimited (ladder to the stack, no per-bet ceiling, no forced showdown) |
| `CHAT_MAX_HISTORY` / `CHAT_MAX_LENGTH` / `CHAT_RATE_LIMIT` / `CHAT_RATE_WINDOW_MS` | 100 / 140 / 5 / 5000 | Flutter's chat field allows **200** — chars 141–200 are dropped server-side |
| `METRICS_ENABLED` / `METRICS_PATH` / `METRICS_PREFIX` | true / `/metrics` / `game_server_` | Prometheus exposition (req. 35); prefix applies to prom-client's default process metrics only |
| `METRICS_TOKEN` / `METRICS_ALLOW_IPS` | empty / empty | bearer token and/or comma-separated client IPs required to scrape; both empty = open (fine behind a firewall, wrong on the internet) |
| **`REDIS_URL`** | empty | **The live store — where ALL game state lives** (§5.1). Empty = an in-process store: single instance, and a restart loses every table (players re-join; nothing is reconstructed). Set (`redis://127.0.0.1:6379/0`) → Redis, and the boot **fails fast** if it is unreachable. There is no `SNAPSHOT_FLUSH_MS`: PostgreSQL keeps no game state, so there is nothing to flush to it. |
| `LIVE_STATE_TTL_MS` | 86400000 | how long a table snapshot that stops updating survives in the live store |
| `LIVE_INSTANCE_ID` | `hostname:pid` | presence / matchmaking owner tag (`Load()` only; `Defaults()`/`FromEnv()` carry `""`) |
| `LIVE_RECONCILE_MS` | 30000 | how often the live store is pinged, refilled from memory after an outage, and swept for stray seat/summary keys; 0 disables |
| `LOG_LEVEL` | info | slog level (`util.ParseLogLevel`) |
| `ROOT_REDIRECT` | empty | **Go-only.** Set (**production: `/dashboard/`**, the Grafana login) it hides the browser client: `GET /` → 302 to the value, every top-level file of `PUBLIC_DIR` (`index.html`, `client.js`, the stylesheets) and `/socket.io/socket.io(.min).js` → 404; subdirectories keep serving — `privacy/` (Play listing link), `profiles/` (Flutter avatars via `/api/profiles`). Empty = browser client at `/` (dev, parity). The rule is the directory layout, not a filename list (`static.go`). |

There is no `go-server/.env` on the dev box (it is git-ignored); the server runs on these defaults.
Production's lives at `/var/www/gameplay/king-teenpatti/go-server/.env` (`PG_POOL_MAX=50`, `JWT_SECRET`, `METRICS_TOKEN`, …).

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
- Live-store metrics (`internal/live` + the restart sequence): `live_store_operations_total{op,result}`,
  `live_store_duration_seconds{op}` (buckets 0.1 ms…1 s), `live_store_errors_total{op}`, `live_store_reconciles_total{result}`,
  `restored_tables_total` (**unlabelled** — the live store is the only source a table can come back from),
  `restored_seats_total`. `/health` gains `live: {kind, ok, tables}` after `db`. **There are no
  `game_snapshot_*` series, no `game_restore_reconciled/rejected_total` and no
  `game_refunded_pots/chips_total`** — the first two belonged to the abandoned PostgreSQL backstop,
  the third to `RefundOrphanedPots`, which went when PostgreSQL stopped holding pots (§5.1).
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
  - `internal/socket` (invalid moves, hostile payloads, leaks, money, concurrency, stack), `internal/sio` (framing, server,
    concurrency), `internal/auth`, `internal/config`, `internal/metrics` (the label rule), `cmd/gameplay` (version stamp).
  - **Node-assisted tests, all `t.Skip` without their prerequisite:** `internal/auth/nodeinterop_test.go` (tokens minted by
    `jsonwebtoken` verify in Go and vice versa) and `internal/sio/interop_test.go` (real `socket.io-client`) use
    **`tools/node_modules`** — `cd tools && npm install`. `internal/game/interop_test.go` (every hand ranking and every
    sanitising result vs the Node engine) needs **`NODE_REFERENCE_DIR`** = a checkout of the removed `server/` tree with
    `node_modules` (`git worktree add /tmp/node-ref c19963b && (cd /tmp/node-ref/server && npm ci)`).
  - Leftover schemas after a crash: `select nspname from pg_namespace where nspname like 'test_%'` (§4).
- **Parity harness** (`tools/parity/`, run with `cd tools && npm run parity`): black-box `node:test` suites — `game`, `money`
  (audits the books the profile wrote), `lobby`, `stakes`, `rest`, `protocol` (raw frames via `lib/csharpJsonPort.js`), `resume`,
  `invalid`, `metrics` — over real sockets against a server it spawns (`--target go` is the only target; default binary
  `../go-server/bin/gameplay`, `--bin` overrides) on a throwaway schema per **profile** (config is read once, so suites needing
  different timeouts get their own server process), or against a running server with `--url … --schema …`. `--filter a,b`,
  `--keep` (logs + schemas), `--serve [--profile main]`, `--verbose`. `npm run parity:diff -- --a go --b <url|go>` drives one fixed
  scenario against two servers and diffs the normalised recordings (uuids/codes/JWTs/timestamps/cards masked, consecutive
  identical `room:state` collapsed; `--out <dir>` keeps them). The Node target is gone — the last Node-vs-Go run was 141/141.
- **`tools/bot.js`** (`npm run bot -- …`) flags: `--count --boot --category --url --offset --churn`. **16** fixed identities
  (Ravi Meera Arjun Kavya Vikram Anita Rohit Neha Priya Aman Sneha Karan Pooja Rahul Isha Dev; device id `practice-bot-<slot>-<name>`);
  groups use `--offset 0/4/8/12` — a second group **must** use `--offset`. Bots always `see`, ask sideshow 45%, answer 75/15/10
  accept/decline/lapse; retry `already_in_room` for 60s. `--url https://api.sungamestudio.com` runs them against production.
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
  db:{total,idle,waiting}}`. Under Go `process.node` is the runtime string (`go1.27.1`), `loopLag*` are scheduler-latency
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
  reward countdown. **Any `context.watch<GameState>()` rebuilds every second.**
- `GameConnection`: websocket-only Socket.IO; broadcast `Stream`s; every emit via `emitWithAck`; a
  refusal is `{ok:false, message}` → `notice`. `request()` awaits an ack with an 8s timeout.
  **Every `act()` sends a fresh `actionId` (uuid v4)** for server-side idempotency. The `room:moved`
  `j['state']` branch is dead code (server sends no `state` there).
- DTOs (`dtos.dart`): `const` classes + tolerant `fromJson`; server enums as `static const String`
  classes; `Seat.chips` **nullable** (null = withheld, never 0).
- SharedPreferences: `deviceId`, `token`, `darkMode`, `lang`, `numbers`, `noWinningsAck:<userId>`.
- **No-winnings confirmation** (`state/consent.dart`, `_ConsentGate` in `main.dart`, added 11 Sep 2026):
  after sign-in (either door, or a restored session) the lobby/table is covered by a panel — "I confirm
  that I do not have any expectations of winning any monetary or other enrichment from playing this
  game." — until the player taps *I confirm*. `GameState.consentPending` gates it; `loadConsent()` runs
  at every session start, `acceptConsent()` writes `noWinningsAck:<userId>` so that **account** is never
  asked again on that device (quit, relaunch, resume included). Keyed per account, not per device: a
  second account on the same phone is asked once for itself. Client-only, nothing goes to the server.
  Not shown over the update screen. Back while it is up = the usual quit question. `test/consent_test.dart`.

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
- **Lobby**: rail of square `_TableCard`s from `config.tables` (server order), capped at 400dp tall;
  `_CategoryBadge` (sheen + `SpinningChip`, blind delayed 900ms), `LivelyChipStack`, `_CardFact`
  rows, entry-cap overlay; `_TopBar` `fromLTRB(240,…)` clears the bonus chip, `tight` < 760;
  `_MilestoneChip` above `BuyChipsButton` ("Coming soon"); one `endDrawer` for stats/settings.
- **Table** (rebuilt around the felt on 10–11 Sep 2026 — `fb47ba4`, `b83b273`, `81a5981`; the bar
  across the foot and the cloth under it are both gone, and the screenshots in `docs/play-store/`
  predate all of it). `_TableScreenState.build` **watches nothing** (a per-second Scaffold rebuild
  destroyed the open drawer) and sets **`resizeToAvoidBottomInset: false`** — the soft keyboard used
  to squeeze the rail and the chat panel until both painted overflow stripes; the chat drawer lifts
  its own composer over the keyboard and drops its title while typing.
  `_LeftPanel {menu, chat}` shares one `drawer`.
  **There is no `_ActionBar`.** The keys live in the corners they are pressed in: `_SideRail`
  (BuyChips `+` at the head, then menu, then chat — each key fills the rail so the target stays
  ≥44dp, which is why they sit flush to the screen edge on a 360dp phone), `_PackKey` bottom-left
  with `_MissedTurnsStrip` riding above it, and `_ActionCluster` bottom-right (`Sideshow` over
  `− Chaal +`).
  `_Felt`: seats at fractional `_places` (5 only), viewer at view seat 0, `Dim.podW(feltW, feltH) =
  min(feltH*0.270, feltW*0.150).clamp(60,140)`, pods clamped inside. Overlays: `_CategoryTag`,
  `_Pot`/`_PotPulse` at `_potDy` 0.46, `_Status` at 0.28, `_SideshowLink/Prompt`, `_Showdown`.
  **`_Showdown` is now only `Fireworks(focus: winner)` + `_PotToWinner`** — the scrim and the banner
  over the middle of the table were removed (owner, 10 Sep 2026): the scrim greyed every revealed
  hand a player wanted to compare against, and the result is announced on the winner's own pod by
  `_WinnerFlash` instead. `handLive` gates bet pills.
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
  sideshow peek the hand answers the question itself, with `_handName` above it (suppressed on the
  winner, whose `_WinnerFlash` ribbon already carries the ranking).
- **Per-frame clocks** (`LiquidFill`, `_SideshowCountdown`) compute from `deadlineMs -
  DateTime.now()` inside an `AnimationController` — never from the 1s tick. No clock-skew correction.
- **Theme**: FlexColorScheme with explicit palettes (the "one seed" comment is stale);
  `_raisedButtons` = state-driven elevation (`liftElevation`: disabled 0, pressed rest/3, hover 2×),
  tinted `shadowFor`, transparent surfaceTint; text buttons flat. `PremiumSurface` = the one raised
  treatment (3 shadows + bevel + optional `Glint`).
- **i18n**: `AppLang` × 5; `Strings(lang)` with English → key fallback. **New keys go in all five
  maps + a getter.** Teen Patti vocabulary transliterated. Still-English strings: `'YOU'`, `'Table
  ${code}'`, `'hand N'`, private-card body, picture-picker labels, `'Switch theme'`, chat `'You'`,
  the `'$winner won N'` banner (bypasses lakh formatting), and **wire hand names**.
- **Android**: `com.sungamestudio.kingteenpatti`, `sensorLandscape`, cleartext, INTERNET (needed in
  release). **Icon & splash** come from one file, `assets/app_icon.svg` (crown over A♥ A♠ Q♥, all paths, no fonts):
  `tool/render_icons.dart` renders `mipmap-*/ic_launcher.png` (legacy), `mipmap-*/ic_launcher_foreground.png` +
  `mipmap-anydpi-v26/ic_launcher.xml` (adaptive, bg `@color/ic_launcher_background` #2B363B), `drawable-*/splash_icon.png`,
  and the 200×80dp `splash_branding.png` (DejaVu Sans, light/night variants). `values-v31` sets `windowSplashScreenAnimatedIcon`
  + `windowSplashScreenBrandingImage`; pre-12 uses `drawable(-night)(-v21)/launch_background.xml` layer-lists. The Flutter
  `SplashScreen` shows the same SVG + line; the login title carries the SVG at 40dp. Release **signed with debug keys**
  (TODO in `build.gradle.kts`).
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
lobby from `config.tables`. No `room:kicked`, no sideshow, no rename/entry-cap/numbering.
Google/Facebook buttons are stubs needing `AUTH_ALLOW_FAKE_PROVIDERS` (the Google one sends **no
idToken**; against production it is a guaranteed 401 `missing_token` — not a server fault). Chat
`maxlength=140`. Treat as a protocol smoke-test surface. **Production hides it** (`ROOT_REDIRECT=/dashboard/`,
§7.4, since 10 Sep 2026): `/` bounces to the Grafana login and the client's files are 404, while
`privacy/` and `profiles/` under the same dir stay served.

---

## 10. Requirements index (`Requirements.txt`)
1 login providers · 2 DB per identity (brief says SQLite; **now Postgres by owner's decision**) ·
3 ≤5/room · 4 ≥2 to start · 5 2 lakh welcome · 6a–g core play · 7 persistence · 8 room chat ·
9 +/− stepper · 10 auto-pack · **(no 11)** · 12 collapsible chat · 13 Blind/Seen × 200/5000 ·
14 Show reveal · 15 pot to last leaver · 16 stats (played = made a chaal) · 17 25k/25 hands ·
18 4h 10k bonus · 19 Seen: one double, forced showdown (brief 10 moves / code 7 rounds) ·
20 provider avatar · 21 avatar picker, locked when seated · 22 private table · 23 landscape/M3 ·
24 merge lone rooms · 25 leave confirm · 26 4h reward top-left · 27 milestone bottom-right ·
28 square cards + sweep · 29 display name · 30 entry cap (not on switch) · 31 3 auto-packs → kick,
below boot → kick · 32 boot deducted at start · 33 sideshow · 34 Indian numbering + toggle.
Verbal additions: menu = exactly seen 200 / blind 200 / blind 5000; seen pot cap 1.2M; buy-chips
button; category tag; winner chip flight; action-bar icons; chat as left drawer; missed-turn warning.

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
  key). `go test` caches: use `-count=1` when a DB-backed suite must really re-run.
- **Bots reconnect to their previous table** (server restores seated users on connect). Use
  `--churn`, or wait out the 30s grace.
- A stray `go-server/gameplay` (a `go build` with no `-o`) is untracked and not git-ignored — only
  `bin/` is. Delete it or build with `ops/build.sh`.
- `adb exec-out screencap` back-to-back returns **stale duplicate frames**; sleep ≥1s between grabs.
  Detect Flutter overflows with `adb logcat -d | grep -ic overflowed`.
- `screenrecord` silently falls back to 1280×720 letterboxed; crop with ffmpeg `crop=1280:588:0:66`.
- Pixel 7 Pro AVD: `settings put secure stylus_handwriting_enabled 0`.
- Use `uiautomator dump` bounds for taps; screenshot coordinates are display-scaled.
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
- Every login **overwrites `display_name`** with the provider's name — a rename is clobbered on next
  login (known, unresolved vs. req. 29).
- Rate-limit trips ack `{ok:false, code:'rate_limited'}` (both servers). `room:create` does not
  `broadcastState`. `roomCode()` has no collision check in Node (Go regenerates until unique).
  `sweepEmptyTables` uses a hardcoded 30s. `handsToNextMilestone` says 25 (not 0)
  at an exact multiple — use `milestoneAvailable`.
- Dead surface with no caller: `GET /api/rooms`, inbound `lobby:list`, `chat:history`, `ping:rtt`.
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
- `FractionallySizedBox` with only `widthFactor` and a childless child **collapses to zero height**
  (needed `heightFactor: 1`, `alignment: centerLeft`).
- Both `game:showdown` and `game:handEnded` hit `onShowdown`; only the latter has `nextHandAt`.
- Refused moves surface **twice** (ack + `game:error`).
- `GameConfig.fromJson` ints fall to 0 → `config.maxPlayers == 0 ? 5 : …` guards.
- `Avatar` SVG branch has no `errorBuilder`. `_PotChips` animates only on increase. `PlayingCard`
  flips only face-down↔up. Only 5 `_places`.
- Google sign-in works (`google_sign_in` 7.x, `net/social_sign_in.dart`); the **Web** client id is the
  `serverClientId` and arrives as `--dart-define=GOOGLE_SERVER_CLIENT_ID`, without which sign-in
  succeeds and returns no `idToken`. Facebook was removed on 10 Sep 2026 (§8.4). A build with no client
  id throws `SignInUnavailable` and says so rather than blaming the network; "use provider picture"
  is still disabled.
- `main()` awaits `/api/auth/me` with no timeout before the first frame.
- Chat field `maxLength: 200` vs server 140 (see §7.4).

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
- **`docs/play-store/screenshots/` are out of date** — they show the pale felt and the action bar
  across the foot, both gone since 10 Sep 2026. The 512x512 icon and the 1024x500 feature graphic in
  the same directory are current. Re-shoot before the listing goes to review.
- `flutter-client/ios/` has never been compiled (no macOS here) and carries no `Podfile` — Flutter
  writes one on the Mac at first build. `docs/ios-setup.md` §5 lists what is deliberately off there.
- `flutter-client/test/widget_test.dart` was **deleted on purpose** (template counter test).
- `tools/parity/lib/csharpJsonPort.js` / `protocol.test.js` guard a wire format whose C# original is gone.
- `GameConnection.onCards`/`requestCards()` wired but unused; `room:moved` `state` branch dead.
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
  **websocket only** (`transport=polling` → HTTP 400 `Transport unknown`); serves the embedded
  `socket.io.min.js` (`internal/app/assets/`, MIT, copied from the former
  `server/node_modules/socket.io/client-dist`) so the browser client in `go-server/public` works
  unchanged. Every shipped client is websocket-only.
- **DB via `pgx`** (`internal/db`): `schema.sql` (embedded; the only copy now — idempotent DDL run at
  every start — `users` and `chip_ledger` only, plus guarded drops of the retired `game_states`,
  `pots` and `hands`), the `Checkpoint`/`Settle` transactions of §5.1, `search_path` as a connection parameter,
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
  exactly like Node.
- **Metrics** (`internal/metrics`): every `game_*` series identical; process/runtime metrics are
  `game_server_process_*` + `game_server_go_*` (goroutines, GC, memstats, `sched_latencies_seconds`)
  — **no `game_server_nodejs_*`**. `/health` keeps every Node key (`process.node` = `go1.27.1`,
  `loopLag*` = scheduler-latency percentiles, `externalMb` = 0) and adds `goroutines`, `numCpu`,
  `gomaxprocs`. Grafana's former "Node.js" row is now "Runtime"; alerts
  `GameServerSchedulerLatencyHigh` / `GameServerGoroutinesHigh` / `GameServerMemoryHigh` replaced
  the three `nodejs_*` ones (§7.5 bundle at `go-server/ops/monitoring/`, `MONITORING.md`).
- Small honest deviations: JSON 404 for unknown `/api/*`, 400 `invalid_json` for bad bodies,
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
bash ops/build.sh                 # static, stripped, `-X main.version=$(git describe)` → bin/gameplay; installs Go 1.27.1 to ~/.local/go if missing
./bin/gameplay -version           # gameplay <describe> go1.27.1 linux/amd64
PORT=3001 HOST=127.0.0.1 PG_SCHEMA=test_x ./bin/gameplay      # spare port + throwaway schema (drop it after)
# parity (from tools/, `npm install` once): the black-box suites against the built binary, and a traffic diff
cd ../tools && npm run parity                                 # --bin <path> / --filter a,b / --keep / --url <running server> --schema <s>
npm run parity:diff -- --a go --b http://127.0.0.1:3000 --schema-b public
```
Bots (`npm run bot`), ramptest (`npm run ramp`), the Flutter debug build (`--dart-define=SERVER_URL=http://10.0.2.2:3000`)
and the §4 ledger-reconciliation psql check (`0`) are the acceptance run — unchanged tooling, Go on the other end.
Two Go tests borrow `tools/node_modules` and one needs `NODE_REFERENCE_DIR` (§7.6); all skip cleanly without them.

### 14.3 Production deploy (`go-server/ops/DEPLOY.md` has every command; `steps.txt` the short form)
Host `148.113.24.201` (`ssh deploy@…`), checkout `/var/www/gameplay/king-teenpatti` on **`master`**
(go-server was merged in PR #2), unit **`gameplay.service`** (the same name Node used — nginx →
`127.0.0.1:3000`, Prometheus job `game-server` with bearer token, `journalctl -u gameplay` all
unchanged). The unit's `WorkingDirectory`, `EnvironmentFile` and `PUBLIC_DIR` are all under
`go-server/`: `EnvironmentFile=/var/www/gameplay/king-teenpatti/go-server/.env` (same keys as the old
`server/.env`, which the installer copies over once; `PG_POOL_MAX=50` stays),
`PUBLIC_DIR=/var/www/gameplay/king-teenpatti/go-server/public`. No Go toolchain on the host beforehand:
`ops/build.sh` installs Go 1.27.1 into `~/.local/go` (sha256 checked against go.dev) and builds a static binary.
```bash
cd /var/www/gameplay/king-teenpatti && git pull origin master
bash go-server/ops/build.sh                                       # as deploy, no sudo
sudo bash go-server/ops/install-go-server.sh                      # FIRST TIME: backs up the Node unit → gameplay.service.node.bak, copies server/.env → go-server/.env, installs gameplay-go.service AS gameplay.service, restarts, checks /health process.node = go… and /metrics 200, then rm -rf's server/ from the host (KEEP_NODE_TREE=1 skips; a differing server/.env is kept as go-server/.env.node.bak)
sudo systemctl restart gameplay                                   # every later deploy (after git pull + build.sh)
sudo systemctl status gameplay --no-pager && sudo journalctl -u gameplay -n 20 --no-pager
curl -s 127.0.0.1:3000/health | python3 -m json.tool | head -20   # process.node must start with "go"
# rollback = restore the Node tree from history FIRST (rollback-to-node.sh refuses otherwise), then swap the unit back
git checkout c19963b -- server && (cd server && npm ci --omit=dev) && cp go-server/.env server/.env
sudo bash go-server/ops/rollback-to-node.sh                       # back to Node in ~10 s once the tree is back; the unit backup is kept
```
Then: `/health`, `curl -s 127.0.0.1:9090/api/v1/targets` (game-server `up`), bots against production
(`cd tools && npm install && npm run bot -- --url https://api.sungamestudio.com --count 3 --boot 200 --category blind`),
the ledger check. One-time after the first Go deploy: re-import
`go-server/ops/monitoring/grafana/dashboards/king-teenpatti.json` through the Grafana API
(`POST /api/dashboards/db`, `overwrite:true`), point Prometheus's `rule_files` at
`go-server/ops/monitoring/prometheus/alerts.yml` (the path moved) and `sudo systemctl reload prometheus` —
commands in DEPLOY.md §6. Restart semantics are Node's: SIGTERM → live pots settled (first active seat,
`all_left`), sockets closed, exit within 8 s (`TimeoutStopSec=15`). Node stays installed on the host only
for `tools/`.
