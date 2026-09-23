# tools/ — client-side tooling for the King Teen Patti server

Everything in this folder **connects to a game server as a client**. Nothing here runs a server.
It is a small Node package whose only dependencies are client libraries (`socket.io-client`,
`ws`, `pg`, `jsonwebtoken`), the same libraries the Flutter app and the browser client are
compatible with. These scripts used to live inside the Node server folder; when the server was
ported to Go the tooling stayed in JavaScript and moved here.

Requirements: Node 20+ and a one-time `npm install` in this folder. A Postgres URL is needed only
by the parity harness (it creates and drops throwaway schemas).

```bash
cd tools && npm install
```

## What is here

| Path | Purpose | Run |
|---|---|---|
| `bot.js` | Practice bots. Guest players with fixed names (Ravi, Meera, Arjun, …) that sit at a table and play a plausible game: always see, bet, raise, ask for sideshows, answer them, pack. Used to fill tables for demos and manual testing, locally or on production. | `npm run bot -- --url https://api.sungamestudio.com --count 4 --boot 200 --category blind` |
| `ramptest.mjs` | Staged load generator. Adds guest players in stages, holds each stage, records login/connect/action-ack latency percentiles, moves per second, hands per minute, `/health` round trip and the server's own vital signs, and stops on its own when latency or errors cross a threshold. Writes a JSON report. Every load report in `docs/load-reports/` came from it. | `npm run ramp -- --url https://api.sungamestudio.com --stages 1000,2000,3000,4000 --hold 75 --out ramp.json` |
| `parity.mjs` + `parity/` | Black-box regression suite for the wire contract: 141 tests that drive a server over the real protocol (REST, raw Engine.IO frames, lobby, full hands, sideshow, invalid moves, resume, chat, metrics) and then audit the database (every wallet equals its ledger sum, pots equal their banked rows, one ledger row per action id). It spawns the Go binary on a free port with a throwaway schema per profile and tears everything down. This is the suite that proved the Go port equal to the Node server. | `npm run parity` (spawns `../go-server/bin/gameplay`), `npm run parity -- --filter game`, `npm run parity -- --url http://127.0.0.1:3000 --schema public` |
| `parity-diff.mjs` | Records one scripted three-player scenario against two servers and diffs the normalised per-socket event streams and ledger rows (ids, timestamps and card codes masked; key order ignored). Exit code 1 on any difference. | `npm run parity:diff -- --a go --b http://127.0.0.1:3000 --schema-b public` |
| `crashtest.mjs` | Failure-and-recovery acceptance tests for the live-state architecture. Four scenarios, each playing real hands and then breaking something for real: **crash** (SIGKILL the server, Redis survives → tables restored from Redis), **redis-flush** (FLUSHALL under a running server → play must not notice, and the reconciler refills Redis without waiting for a move), **redis-loss** (server killed *and* Redis wiped → nothing is rebuilt: PostgreSQL holds no game state, so no table and no seat comes back, every open pot is refunded exactly once, a player who had left mid-hand keeps their banked bets, and everyone rejoins into fresh tables), **no-redis** (no live store at all → a restart loses the tables and refunds the pots). Every scenario ends by auditing the books: each wallet equals the sum of its own ledger rows, wallets plus open pots are unchanged, and no hand was both settled and refunded. | `npm run crashtest`<br>`npm run crashtest -- --scenario redis-loss --keep` |
| `chiptest.mjs` | Proves a player's chips are correct in PostgreSQL the moment they leave a table, between hands and mid-hand. The server is wallet-based: `users.chips` is debited inside the transaction of every boot, bet and show, so the seat mirrors the wallet rather than holding a separate stack. The test compares what the table showed, what REST reports, what `users.chips` holds and what the player's ledger rows sum to, and finally that no chips were created or destroyed. | `npm run chiptest` |
| `host-metrics.mjs` | Companion to the ramp: for every stage of a ramp report, pulls what the server host recorded during that stage's exact hold window from its Prometheus (per-core CPU, I/O wait, memory, goroutines, sockets, database latency and commit rate) and writes them alongside. Needs a tunnel to the host's Prometheus. | `ssh -N -L 19090:127.0.0.1:9090 deploy@host &`<br>`npm run hostmetrics -- --prom http://127.0.0.1:19090 --ramp ramp.json` |
| `ramp-report.mjs` | Turns a ramp run into one self-contained HTML report: the verdict and a plain-English summary computed from the data, the per-stage ladder with p95/p99 coloured by band, a chart per figure against the player count (ack latency p50/p95/p99, login and connect, actions/s, hands/min, host CPU per core, game CPU and RSS, goroutines, sockets, PostgreSQL CPU/backends/TPS/transaction latency, Redis memory/commands/latency, network, nginx, the generator's own lag) each with its numbers in a table, per-stage resource tables, time series over the whole run with every hold window shaded, and a methodology section. Inline CSS and SVG drawn by the script — no JavaScript, no images, no chart library; the typeface is the only thing fetched. Sections whose input was not given say "not collected". | `npm run report -- --ramp ramp.json --host ramp-host.json --samples host-samples.jsonl --title "Preprod, 1K–9K" --out ramp.html` |
| `parity/poker.test.js` + `parity/lib/poker5.mjs` | The Poker family's black-box suite (profile `poker`): every variant over real sockets — snapshot keys and redaction, the `wrong_game` wall between the families, Hold'em with chips conserved, fold-to-one, Omaha's exactly-two rule, 5-Card Draw's exchange, 3-Card Poker against the dealer — with `poker5.mjs`, a five-card and three-card evaluator written from the rules and not ported from the server, checking every reveal's `handName` and `best`. `money.test.js` then audits those books, exempting only 3-Card Poker hands (played against a house with no wallet) from the per-hand zero-sum. | `npm run parity -- --filter poker` |
| `parity/lib/csharpJsonPort.js` | A raw Socket.IO frame parser (a port of the retired Unity client's parser). The protocol tests use it to assert exact packet strings instead of trusting a client library. | used by `parity/protocol.test.js` |

Two Go tests also borrow this folder's `node_modules`: the JWT interop test signs and verifies
tokens with the real `jsonwebtoken`, and the Socket.IO server test connects the real
`socket.io-client`. They skip when the folder has not been installed.

## Bot flags

| Flag | Default | Meaning |
|---|---|---|
| `--url` | `http://localhost:3000` | Server base URL. |
| `--count` | 2 | Bots to start (max 16 identities per offset range). |
| `--boot` | 200 | Table stake: 200 or 5000 on the production menu. |
| `--category` | seen | `seen`, `blind` or `variation` (Variation Teen Patti), or a poker room — `three_card_poker`, `five_card_draw`, `texas_holdem`, `omaha` (the server's menu must offer it). At a poker room a bot answers `poker:yourTurn` from the options the server sent: it checks when it can, calls small bets, folds to a bet over a third of its stack half the time, opens or min-raises now and then, plays against the dealer three times in four, and stands pat or exchanges a card or two at the draw. |
| `--variation` | random | Variation tables only: what a bot picks when it is the chooser — `MUFLIS`, `AK47`, `JOKER`, `HUKAM`, `LOWEST_JOKER`, `HIGHEST_JOKER`, `FIVE_CARD` (5-Card Teen Patti: the server tops every hand up to five and plays the best three), `random`, or `none` to never answer and let the server's 10-second clock choose Muflis. |
| `--offset` | 0 | Identity offset. A second bot group must use its own offset (`0`, `4`, `8`, `12`) or the accounts collide. |
| `--churn` | 0 | Seconds between table hops. Makes bots leave and quick-join elsewhere, which exercises consolidation and `room:switch`. |

Bots reconnect to the table they were seated at if restarted within the 60-second grace period,
because the server holds their seats; use `--churn` or wait it out.

## Ramp flags

| Flag | Default | Meaning |
|---|---|---|
| `--url` | required | Server base URL. |
| `--stages` | `10,25,50,…` | Comma list of concurrent player counts to hold in turn. |
| `--hold` | 40 | Seconds to hold each stage. |
| `--boot`, `--category` | 200, blind | Which table every bot quick-joins. |
| `--idOffset` | 0 | Guest accounts are `ramp-bot-<n>`; give a second generator its own range. |
| `--out` | none | Path of the JSON report. |
| `--workers` | 0 | Fork N generator processes and split the players between them. One Node process saturates its own event loop somewhere around 5,000 sockets; ten workers on a 12-core machine carry 50,000. The parent drives the stages, polls `/health` and merges every worker's raw samples, so percentiles stay exact. |

Stop rules: ack p95 above 3,000 ms, error rate above 10 %, or fewer than 90 % of players
connected ends the run, and the last healthy stage is the ceiling. Watch the report's `gen-lag`
column: if it climbs, the generator itself is the bottleneck and the latencies above it are
suspect — add `--workers`. Above about 28,000 players one machine runs out of ephemeral TCP
ports to a single destination, whatever the worker count.

## Report flags

| Flag | Default | Meaning |
|---|---|---|
| `--ramp` | required | The ramp JSON `ramptest.mjs --out` wrote. |
| `--host` | none | The host JSON `host-metrics.mjs` wrote for that ramp. Without it the host, PostgreSQL, Redis, network and nginx sections say "not collected" and the game-server charts fall back to what the generator read from `/health`. |
| `--samples` | none | The `loadtest/host-sampler.py` JSONL from the host for the whole run. Without it the time-series section says "not collected". |
| `--title` | `Ramp report — <url>` | The page title and headline. |
| `--out` | `<ramp name>-report.html` | Where to write the page. |

Every figure in the page is a figure from the files: milliseconds stay whole, megabytes keep one
decimal, percentages one, and nothing is estimated. Open the result in a browser; it prints in
light or dark following the system setting.

## Parity harness notes

- Profiles: `main` (short timers), `slow` (for the rate-limit and timeout cases), `metrics`
  (with a metrics token and IP allow-list), `menu` (the real table menu), `variation`,
  `variation-timeout` and `poker`. Each profile is a separate server process because
  configuration is read once at start.
- Every profile but `menu` runs `TABLE_CONFIG_SOURCE=env`: its tables come from the env keys
  (`LOBBY_TABLES=''` meaning any stake and category), as the server always composed them. `menu`
  runs `TABLE_CONFIG_SOURCE=db`, so the server plays the table catalogue the seed writes into
  its fresh schema, while the env still says `BOOT_AMOUNT=100`, 1.2 s clocks and a lifted menu on
  purpose: the suites seeing the seed's figures proves those keys are ignored. It runs
  `stakes.test.js` and, from `rest.test.js`, only the `GET /api/tables` tests (a profile's `only`
  map passes a `--test-name-pattern`).
- `chiptest.mjs`, `crashtest.mjs` and `parity-diff.mjs` set `TABLE_CONFIG_SOURCE=env` for the same
  reason.
- `--keep` leaves the schemas and server logs in place for debugging; the summary prints the log
  directory.
- The Node server this suite was first written against is no longer in the repository. The
  suites only target the Go binary now; the recorded Node-versus-Go results are in
  `go-server/PORT_NOTES/`.
