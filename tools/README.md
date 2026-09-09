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
| `--category` | seen | `seen` or `blind`. |
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

## Parity harness notes

- Profiles: `main` (short timers), `slow` (for the rate-limit and timeout cases), `metrics`
  (with a metrics token and IP allow-list) and `menu` (the real production table menu). Each
  profile is a separate server process because configuration is read once at start.
- `--keep` leaves the schemas and server logs in place for debugging; the summary prints the log
  directory.
- The Node server this suite was first written against is no longer in the repository. The
  suites only target the Go binary now; the recorded Node-versus-Go results are in
  `go-server/PORT_NOTES/`.
