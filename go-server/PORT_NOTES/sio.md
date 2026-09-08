# PORT_NOTES — internal/sio (Engine.IO v4 + Socket.IO v5 server, WebSocket only)

Owner scope: everything under `internal/sio/` — `protocol.go` (frame grammar), `conn.go` (one
Engine.IO connection: reader / single writer + heartbeat / dispatcher), `server.go` (`Server`,
`Socket`, rooms, `Broadcast`), `errors.go` (disconnect reasons), and the tests `protocol_test.go`,
`server_test.go`, `interop_test.go`. No new module dependencies (gorilla/websocket only).

Reference implementations read line by line: `server/node_modules/engine.io@6.6.10`
(`build/socket.js`, `build/server.js`), `socket.io@4.8.3` (`dist/client.js`, `namespace.js`,
`socket.js`, `index.js`), `engine.io-parser@5.2.3`, `socket.io-parser@4.2.7`; the Node server's
options in `server/src/index.js` (`pingInterval 20000, pingTimeout 25000, maxHttpBufferSize 1e5`);
`server/test/helpers/csharpJsonPort.js` + `socketProtocol.test.js` for the exact frame strings.

## What is implemented

| Area | Node behaviour reproduced | Where |
|---|---|---|
| Handshake | `GET /socket.io/?EIO=4&transport=websocket` + Upgrade → `0{"sid":…,"upgrades":[],"pingInterval":20000,"pingTimeout":25000,"maxPayload":100000}` (key order and values identical to engine.io's `onOpen`). Refusals are engine.io's JSON bodies with HTTP 400 in `verify()` order: transport ≠ websocket → `{"code":0,"message":"Transport unknown"}` (polling included, DECISIONS §1); `sid=` query → `{"code":1,"message":"Session ID unknown"}`; non-GET → `{"code":2,"message":"Bad handshake method"}`; no Upgrade → `{"code":3,"message":"Bad request"}`; `EIO≠4` → `{"code":5,"message":"Unsupported protocol version"}`; `CheckOrigin` false → gorilla 403. | `server.go ServeHTTP`, `writeHandshakeError` |
| Heartbeat | engine.io 6.6.10 v4 schedule exactly: first `2` PingInterval after OPEN; a `3` clears the pong timer and re-arms the interval (`pingIntervalTimer.refresh()`); no pong within PingTimeout → `ping timeout`. No ping is re-scheduled until a pong arrives (as `schedulePing` runs only from the pong handler). A client-sent `2` is engine.io's "invalid heartbeat direction" → `transport error`. Heartbeat runs on the writer goroutine, so a handler blocked on the DB never trips it. | `conn.go writeLoop` |
| CONNECT | `40{auth}` (or bare `40`, or `40{}`) → middleware chain in `Use` order on the dispatcher goroutine (may block) → first error → `44{"message":"<err.Error()>"}` and the transport stays open (Node sends CONNECT_ERROR and keeps the engine socket; the client may CONNECT again) → success → `40{"sid":"<fresh id>"}` → `OnConnection` before any event of that socket is dispatched. A CONNECT to another namespace → `44/<nsp>,{"message":"Invalid namespace"}`. A middleware result arriving after the transport is gone is dropped ("next called after client was closed"). | `conn.go connectNamespace` |
| Socket id | socket.io 4 never reuses the Engine.IO sid as `socket.id` ("sensitive information", socket.js): every CONNECT gets a fresh 20-char base64url id (the previous draft reused the sid for the first socket — changed, see "Bugs fixed"). | `conn.go connectNamespace`, `newSID` |
| EVENT / ACK | `42["name",args…]` → registered `Handler(args[1:], nil)`; `42<id>[…]` → `Handler(args, ack)`, `ack(payload…)` writes `43<id>[payload…]` once (later calls dropped, Node's `sent` guard); `ack()` with nothing → `43<id>[]`; unknown event → never acked (EventEmitter semantics, DECISIONS §1); numeric event names tolerated and ignored; client ACK packets ignored ("bad ack"). Handlers run serially per socket, concurrently across sockets. | `conn.go dispatchEvent`, `ackFunc` |
| Server emits | `Socket.Emit` → `42["name",payload…]`; `Broadcast.Emit` (`Server.To(room)`) serialises once and sends to each member once even if it is in several addressed rooms. JSON is `JSON.stringify`-shaped: no HTML escaping, UTF-8 raw, no trailing newline. Emits never block the caller. | `server.go Emit`, `Broadcast.Emit`, `marshalJSON` |
| Disconnect | client `41` → `client namespace disconnect` (transport kept; a new CONNECT builds a new socket); `Socket.Disconnect(close)` → `41` queued, disconnect callbacks run **synchronously on the caller** with `server namespace disconnect` (both `close` values — `disconnect(true)` in Node runs `socket.disconnect()` on every namespace socket before closing), `close=true` then closes the transport after flushing; WebSocket close frame / EOF / TCP drop → `transport close`; read/write error, oversized frame (`SetReadLimit(MaxPayload)`), write timeout, write-queue overflow → `transport error`; unknown Engine.IO type or empty frame → `parse error`; undecodable Socket.IO packet, binary frame, `b…` base64 payload, reserved event name, `5`/`6` attachments → `forced close`; EVENT/ACK/DISCONNECT before CONNECT, second CONNECT, client CONNECT_ERROR, event for another namespace, connect timeout → `forced server close`; `Server.Close` → `server shutting down` (no `41`, as `io.close()`). A `41` immediately followed by the TCP close keeps `client namespace disconnect` (the closed notice is queued behind the packets). | `conn.go readLoop`, `handle`, `errors.go` |
| Write path | one writer goroutine per connection (gorilla allows one), fed by a bounded queue (`WriteQueueSize` 512); each write bounded by `WriteTimeout` (10 s); overflow or timeout → `transport error`, never blocking the emitter (a Table actor). Graceful closes flush the queue for at most `min(WriteTimeout, 2 s)`; a watchdog hard-closes the WebSocket `closeLimit+1s` after `terminate` so a write already blocked on a dead client cannot hold the connection — or `Shutdown` — for the whole WriteTimeout. | `conn.go enqueue`, `write`, `closeTransport`, `terminate` |
| Rooms | `Join/Leave/Rooms` (own id joined on connect, as socket.io does), `To(room).Emit`, membership swept on disconnect before the callbacks run (`_cleanup` → `leaveAll`). Socket room set and the server's room index change together under the socket lock (lock order Socket.mu → Server.mu; the server never calls into a socket while holding its lock). | `server.go Join/Leave/connect/close` |
| Lifecycle | `ClientsCount` = open Engine.IO connections (`io.engine.clientsCount`); `Close` terminates every connection and refuses new upgrades with 503; `Shutdown(ctx)` = Close + wait for all three goroutines of every connection (a handler still running delays it until it returns or ctx expires). | `server.go Close/Shutdown` |
| Handshake facts | `Handshake{Auth, Query, Headers, Address, Time}` — the `?token=` query fallback the Node middleware accepted is available through `Query` (DECISIONS §1). | `server.go Handshake` |

Not implemented, on purpose (PORT_PLAN §9 / DECISIONS §1): long-polling and upgrades, binary
attachments (the game never sends binary), namespaces other than `/`, connection-state recovery,
adapters. Node's exact `base64id` alphabet is not reproduced (ids are 15 random bytes base64url,
20 chars — DECISIONS §1 "opaque").

## Bugs fixed

1. **`TestRoomBroadcast` failure (server_test.go:556, "read frame: i/o timeout") — a test bug,
   not a broadcast bug.** The test proved "the non-member receives nothing" by reading from that
   client with a 150 ms deadline and expecting a timeout. gorilla/websocket makes **every read error
   permanent** (`conn.go`: "Once this method returns a non-nil error, all subsequent calls return the
   same error" — `c.readErr` is sticky), so the timed-out probe poisoned the connection and the next
   legitimate read on it (the both-rooms broadcast) failed with the same i/o timeout. The same
   pattern made the later "no duplicate" / "left socket receives nothing" assertions vacuous (they
   were asserting on an already-poisoned connection). Room broadcast itself was correct: `To(room).Emit`
   reaches every member exactly once, `Join` is not racing the emit (the test joins after
   `OnConnection` returned), and the writer drops nothing. Fix: `expectNothingThenMarker` emits a
   marker straight to the socket and requires the *next* frame to be that marker — frames on one
   connection are ordered, so anything queued earlier would arrive first. The test now also checks
   the server-side room index against the sockets' own view.
2. **Join racing a disconnect leaked dead room members.** `Socket.Join` updated the socket's own
   room set under `s.mu` but the server's room index *after* releasing the lock, so a Join that
   interleaved with `close()` (which copies the room set, then sweeps the index) could re-insert a
   disconnected socket into `Server.rooms` forever (a room that never empties; broadcasts to a
   corpse). `Join/Leave/connect/close` now update both structures under `s.mu`.
   `TestJoinRacingDisconnectLeavesNoDeadMembers` (4 goroutines × 300 joins racing a `41`, 150
   connections) fails on the old code on its first iteration under `-race`.
3. **A write failing after the peer had already closed replaced the disconnect reason.** gorilla
   refuses writes once it has answered a close frame (`ErrCloseSent`), so a broadcast racing a
   client's clean departure (`41` + close frame) made the writer `terminate("transport error")`,
   which also made the dispatcher drop the queued `41`. Node reports `client namespace disconnect`
   there (its close event fires before the failed writes are noticed). The reader now records its
   reason (`readReason`) before publishing `readDone`; a write failure or queue overflow after that
   defers to it and leaves the queued packets to the dispatcher (`TestWriteFailureAfterPeerCloseKeepsTheReadersReason`).
4. **A blocked write held the connection for the whole WriteTimeout, past the app's 8 s shutdown
   budget.** `terminate` arms a force-close watchdog (`closeLimit + 1 s`, closeLimit =
   `min(WriteTimeout, 2 s)`); `closeTransport` stops it. `TestShutdownIsNotHeldByABlockedWrite`
   (WriteTimeout 30 s, client not reading) fails without it.
5. **Socket id = Engine.IO sid.** Changed to socket.io 4's fresh id per CONNECT (see above). Nothing
   in `internal/socket`/`internal/app` compares the two; the interop test asserts they differ.
6. `TestMiddlewareResultAfterTransportCloseIsIgnored` had a no-op `waitFor(… || true)`; it now waits
   for the reader to notice the close and asserts the never-connected socket holds no rooms.

## Test summary

`go build ./internal/sio/... && go vet ./internal/sio/... && go test -race -count=3 ./internal/sio/...`
→ **ok** (≈21 s); also green with `-count=10` and `-cpu 1,2,8`. `gofmt -l internal/sio` is empty.
38 tests:

* **protocol_test.go** — `EncodePacket` string-exact against socket.io-parser (`2["x",{}]`,
  `217[…]`, `317[…]`, `30[…]`, `0{"sid":"s"}`, `1`, `4{"message":…}`, `4/admin,{…}`); `DecodePacket`
  grammar (namespace, ack id, empty frame = CONNECT, numeric event names); every payload shape
  socket.io-parser throws on; round trip; `marshalJSON` = `JSON.stringify`; sid shape.
* **server_test.go** — handshake OPEN exact; all six refusal bodies + POST + gorilla `ErrBadHandshake`;
  CheckOrigin 403; CONNECT with middleware/handshake facts/`session:ready`; bare `40` → nil Auth;
  auth rejection `44{"message":"invalid_session"}` / `missing_token` then a successful retry on the
  same transport; invalid namespace; event with/without ack, empty ack, ack id 0; unknown event never
  acked; emit framing/unicode/ordering across goroutines; room broadcast (fixed) + Join/disconnect
  race; client `41`; transport close (close frame and TCP drop); `41`-then-close keeps its reason;
  write failure after peer close keeps the reader's reason; `Disconnect(true)` synchronous callbacks
  + `41` + close; `Disconnect(false)` keeps the transport; ping timeout with 60/80 ms options; pongs keep
  it alive (≥4 pings/400 ms); client ping = transport error; ignored engine types; oversized frame
  (MaxPayload 1024) = transport error; 13 malformed-packet cases with Node's reasons; event before
  CONNECT; connect timeout; middleware result after close ignored; slow client overflow never blocks
  the emitter; blocked write does not hold Shutdown; `Close` → `server shutting down` + 503 for new
  upgrades; `Shutdown` honours ctx with a handler in flight; 100 concurrent sockets + broadcast +
  goroutine count back to baseline.
* **interop_test.go** — starts the Go server in-process and runs `socket.io-client@4.8.3` under `node`
  (skips when `node` is not on PATH or the module is not found via `$SIO_NODE_MODULES`, `$NODE_PATH`,
  or `../../../server/node_modules`): connect with `auth:{token}` (`socket.id ≠ engine.id`, transport
  websocket), receive `session:ready`, `emitWithAck('room:quickJoin')` → exact ack JSON, ack with no
  payload → `[]`, event without ack answered by a room broadcast (quotes, `<b>&` raw), heartbeat at
  150/300 ms (≥3 pings in 700 ms, still connected), `connect_error` with message `invalid_session`
  for a bad token, server `Disconnect(true)` seen client-side as `io server disconnect`, clean
  `socket.disconnect()`; server side sees exactly 2 connections and reasons
  `[server namespace disconnect, client namespace disconnect]`.

## Deviations (each traces to DECISIONS.md / PORT_PLAN.md)

| Topic | Node | Go | Why |
|---|---|---|---|
| Transport | websocket + polling | websocket only; polling → 400 `{"code":0,"message":"Transport unknown"}` | DECISIONS §1 |
| Outbound buffering | unbounded | queue 512 frames, 10 s per write, overflow/timeout → `transport error`; graceful flush ≤ min(WriteTimeout, 2 s) + force-close watchdog | PORT_PLAN §3.3 "never block the caller"; the 8 s shutdown budget |
| Handshake refusal body for Upgrade requests | text/html | the same JSON as for plain requests | invisible to every client; documented in `ServeHTTP` |
| `Socket.Emit` after the namespace socket disconnected but the transport is still open | writes the packet | returns `ErrSocketClosed` | not observable by the game (it only emits to sockets it tracks as live) |
| Disconnect callbacks vs. an in-flight handler | `disconnect` fires when the transport closes even while an async handler is pending | callbacks run after the current handler returns (serial dispatcher) | actor discipline; `Shutdown` waits for it |
| Malformed body / binary | waits for attachments | closes with `forced close` | DECISIONS §1 "malformed packet closes the connection" |
| sid alphabet | `base64id` | 15 random bytes, base64url, 20 chars | DECISIONS §1 |

## Notes for the integrator

* Mount with `mux.Handle("/socket.io/", srv)` (`Options.Path` is informational; the mux prefix does the
  routing). Build with `sio.Options{PingInterval: 20s, PingTimeout: 25s, MaxPayload: 1e5, CheckOrigin:
  <from config.CORSOrigin>, Logger}` — zero values already give the Node server's numbers.
* Order of setup: `srv.Use(authMiddleware)` → `srv.OnConnection(fn)` → serve. `OnConnection` runs on
  the socket's dispatcher goroutine after the `40{"sid"}` ack is queued and **before** any event of
  that socket is dispatched, so `s.On(...)` registrations inside it see every event.
* `Middleware` may block (Postgres lookup). Return `errors.New("<code>")` — the code becomes
  `44{"message":"<code>"}` verbatim (DECISIONS §1: `missing_token | invalid_session | unknown_user |
  unauthorized`). Store the user with `s.SetData`.
* `Socket.Disconnect(true)` runs the socket's `OnDisconnect` callbacks **synchronously on the
  caller's goroutine** before returning (Node's `disconnect(true)` did the same) — the
  `session:replaced` path in `internal/socket` relies on it. Emit `session:replaced` first, then
  `Disconnect(true)`; both frames are flushed before the close frame.
* `Handler`s run serially per socket and concurrently across sockets; they may block. Never hold
  `socket.Handler.mu` while calling `Emit`/`Join`/`Disconnect` (PORT_PLAN §3.3) — none of them block
  on the network, but `Disconnect` runs callbacks.
* `Socket.ID()` is a fresh id per CONNECT, distinct from the Engine.IO sid; treat it as opaque.
  `Handshake().Query.Get("token")` is the legacy `?token=` fallback.
* Disconnect reasons handed to `OnDisconnect` are exactly socket.io's strings; feed them through
  `metrics.SafeLabel(reason, sio.KnownDisconnectReasons, "other")` — `forced server close` and
  `parse error` fold to `other` as in Node.
* `Server.Close()` returns immediately; `Shutdown(ctx)` waits for every connection goroutine — a
  handler blocked on the DB delays it until it returns or ctx expires (the app's 8 s budget).
* `ClientsCount()` is `/health.sockets` (`io.engine.clientsCount`).
* Seen while checking neighbours: `go test ./internal/socket/` currently fails at setup with
  "missing go.sum entry for github.com/kylelemons/godebug/diff (imported by
  prometheus/client_golang/prometheus/testutil)" — a `go.sum` entry the metrics/socket tests need
  (`go get github.com/prometheus/client_golang/prometheus/testutil@v1.24.1`), not an sio issue.
  `internal/app` tests pass against the current sio.
* The scratchpad spec (`spec-socket-protocol.md`) referenced by the plan no longer exists on disk;
  this package was audited directly against the library sources listed at the top and the Node
  wire tests.
