# PORT_NOTES — internal/socket (the realtime protocol)

Owner scope: `internal/socket/handler.go`, `payload.go`, `wire.go`, `testclient/` and the tests
`stack_test.go`, `handler_test.go`, `invalidmoves_test.go`, `payload_test.go`. Port of
`server/src/socket/index.js` (`attachSocketHandlers`, 762 lines) on top of `internal/sio`.

The handler was written by the previous engineer and left unverified. This pass audited every
handler, listener and the connection/disconnect paths against `spec-socket-protocol.md`,
`spec-config-metrics.md` §2.12, DECISIONS.md and the Node source line by line, fixed what differed,
and wrote the test suite that had been missing.

## Audit result

Everything below was checked against the Node source and found to match (or to match the
DECISIONS.md ruling where the two differ):

| Area | Node | Go | Verdict |
|---|---|---|---|
| Handshake token | `auth?.token ?? query?.token`; `""` → missing_token; non-string → jwt.verify throws → invalid_session | `handshakeToken`: same `??` semantics, JS truthiness for non-strings, falsy → `""` | match (white-box test `TestHandshakeTokenSelection`) |
| Handshake refusals | `44{"message":<code>}` — `missing_token`/`invalid_session`/`unknown_user`/`unauthorized`; a pg error leaked its SQLSTATE | the code only; a `FindByID` error is `unauthorized` | DECISIONS §1 |
| Connection sequence | counters → replace previous (session:replaced, `disconnect(true)` **synchronously** runs the old socket's disconnect handler) → cancel grace timer (`seat_held`) → resume resolution → `session:ready {user, config, resume?}` → seated: track, `setConnected(true, id)` (→ room:state) , room:joined, chat:history | identical order; `sio.Socket.Disconnect(true)` runs the callbacks synchronously and `onDisconnect` is additionally called explicitly (idempotent, waits for a run in flight) | match (`TestSecondSignInReplacesTheFirst`: order `session:ready, room:state, room:joined, chat:history`, one `room:state connected:false` then `true` to the other viewer, `reconnects_total{seat_held}` = 1, no timer left armed) |
| `resume` | absent unless `takeResumeOffer` returns one: offered ONCE, ≤ `RESUME_OFFER_MS` old, table alive and not full | `omitempty` pointer; same four checks | match (5 resume tests) |
| `guard` | `socket_messages_total{event}` first; fixed window 30/5 s per socket; trip → `socket_errors_total{rate_limited}`, `game:error` **then** ack `{ok:false, code:'rate_limited', message:'Slow down'}`; `game_invalid_moves_total` untouched; GameError → ack `{ok:false, code, message}` then `game:error {code,message}`; other error → ack raw message under `internal_error`, `game:error internal_error 'Something went wrong'`; success `{ok:true, ...}` | same; a handler panic is recovered into the internal_error path | match |
| `payload ?? {}` + destructuring | non-object payloads behave as `{}`; field values keep JS typing | `payload.go` decoders (`decodePayload`, `jsString`, `jsTruthy`, `bootArg`, `parseAmount`, `chatTextArg`) | match; `TestGarbageOnEveryEventIsAcked` runs the 13 garbage payloads × 6 events |
| `lobby:list` | `category ?? null`; truthy non-string matches nothing | `noSuchCategory` sentinel; falsy → no filter | match |
| `room:quickJoin` | `bootAmount ?? default` (0/-5/'lots' reach `invalid_stake` AFTER `already_in_room`); track → setConnected → room:joined → chat:history → broadcastState → ack | `invalidBoot` sentinel (−1) so the RoomManager refuses in Node's position; same tail | match (`TestJoinEventOrder`: exactly `room:state, room:joined, chat:history, room:state`) |
| `room:create` | `isPrivate = true` default for undefined only; public create had no validation; seated player left an orphan table; creator gets only `room:joined` + `chat:history`, no broadcast | `already_in_room` before creation; public create validated `invalid_stake → table_not_offered → insufficient_chips → over_entry_cap`; a Join race destroys the unused table; same emits | DECISIONS §3 (`TestPublicCreateIsValidatedLikeQuickJoin`, `TestSeatingRefusals`) |
| `room:joinCode` | `String(code ?? '').toUpperCase()` | `jsString` + RoomManager upper-cases | match |
| `room:switch` | untrack old room FIRST; on error re-track if the table exists; success: track, setConnected, room:joined, chat:history, broadcast target, broadcast vacated; no room:left/room:moved | same; on error re-tracks only while still seated there and sends `room:left` when the seat is gone | DECISIONS §3 (`TestSwitchTable`) |
| `room:leave` | leaver stays tracked during `rooms.leave` (hears chat/pack/handEnded/room:state you:null/room:closed), then untrack, `room:left`, broadcast, ack `{roomId}`; unseated → `{}` | same | match (`TestLeavingFreesTheSeat`, `TestLeaveMidHandOrder`) |
| `game:action` | `unknown_action` (`Unknown action "${String(action)}"`) → `not_in_room` → amount must be a JSON number AND safe integer for EVERY action → actionId honoured only for 1–64 UTF-16 units → timed `table.act` → `moves_total` on success | same order; `utf16Len` | match (`TestNonNumericAmountsAreRefusedBeforeTheTable`, `TestReplayedActionIDChargesNobodyTwice`) |
| `game:sideshowRespond` | `accept === true` only | `acceptsSideshow` byte-compares the literal | match |
| `player:requestCards` | `not_in_room`; `[]` unless seen; emits `player:cards` only when seen | same | match |
| `chat:message` | `not_in_room` BEFORE the 5/5 s chat limiter; every seated attempt counts; `String(text)`; blank → `{ok:true}` without `messageId` | same; text coercion per DECISIONS §4 (numbers → decimal string, other non-strings → `""`) | match / DECISIONS §4 (`TestChatCoercionLengthAndBlank`) |
| `chat:history`, `ping:rtt` | `{count}`; ping unguarded, no `ok`, `sentAt` echoed raw / absent | same (`PingAck.SentAt` RawMessage omitempty) | match |
| Listener → wire | state → per-viewer `room:state`; handStarted → room + per-socket `player:hand`; cards → owner; turn → room (no options) + `game:yourTurn` (options) to the player; action (`reason` only on pack, `auto` only on see; `timeout` → counter); sideshowRequested/Resolved → room; sideshowReveal → the two players (counted once); showdown/handEnded → room (+ completed/abandoned/pot counters); chat → room (+ counter) | same; all inline on the actor, no posting calls | match (`TestSideshowEventsAudience`, `TestQuickJoinDealsAHandAndRedactsCards`, `TestGameMetrics`) |
| Kick | Node's listener awaited `rooms.leave` inside the table event | `OnKick` is a no-op here; `RoomManager.tableHooks` leaves in a goroutine and calls `OnPlayerKicked` → `kicks_total{reason}`, `room:kicked {roomId, reason, message}`, untrack, broadcast | PORT_PLAN §9 (`TestIdleKick`, `TestUnfundedKickBetweenHands`) |
| `tableDestroyed` / `playerMoved` | `room:closed` to tracked viewers (counted once if any); mover: untrack, track, setConnected, `room:moved` (no state), `room:joined`, chat:history, broadcast | same | match (`TestTableDestroyedUnderneathViewers`, `TestConsolidationMovesTheLonePlayer`: `room:closed(old)` precedes `room:moved`) |
| Disconnect | counters (`disconnections_total{reason}` folded); delete `userSockets` only if it is this socket; seated → untrack, `setConnected(false)`, grace timer → offer written BEFORE `rooms.leave(userId,'disconnected')` → broadcast | same; the timer is created and recorded under `mu` | match |
| `Stats()` | `{sockets: userSockets.size, rooms: roomSockets.size}` | same | match |

### Bugs fixed in handler.go

1. **Peak-gauge race.** `connected_sockets_peak` was written after releasing `mu`; two simultaneous
   connections could publish a lower high-water mark after a higher one. The gauge is now set under
   the lock (Prometheus `Set` is non-blocking).
2. **Dead sockets tracked on a room.** `trackRoom` accepted a socket that had already disconnected
   (the `session:replaced` path disconnects the old socket from another goroutine while its join
   handler may still be finishing; sio's `Join` is a no-op for it). Node left such a socket in
   `roomSockets` until the table closed. `trackRoom` now ignores a disconnected socket. Nothing on the
   wire changes; the per-room map no longer leaks.
3. **wire.go comment** for `room:create` said "boot ignored"; it is forced to `PrivateBoot` only for
   private tables (public creates are validated, DECISIONS §3).

### Bug fixed in testclient

`Dial` sent the CONNECT as `440{...}` (Engine.IO `4` prepended to an already complete `40…`), which
sio refused as an undecodable packet and closed — every connection died silently because `Dial`
also returned success when the transport closed before a CONNECT reply. Now `40{"token":…}` is sent
and `Dial` fails with "transport closed before the CONNECT reply" in that case.

## Deliberate deviations (each traces to DECISIONS.md)

| Deviation | Where | Ruling |
|---|---|---|
| Handshake DB failure is `unauthorized`, never a SQLSTATE | `authenticate` | DECISIONS §1 |
| `room:create {isPrivate:false}` validated like quickJoin; `already_in_room` before any table exists | `create` | DECISIONS §3 |
| `room:switch` failure after the seat was given up restores the seat (RoomManager) / sends `room:left` if the source is gone | `switchTable` | DECISIONS §3 |
| Chat `text`: objects/arrays/booleans/null → `""` (Node posted `"[object Object]"`, `"true"`, `"a,b"`) | `chatTextArg` | DECISIONS §4 |
| Kick handled off-actor via `RoomListener.OnPlayerKicked` | `OnKick` no-op | PORT_PLAN §9 actor rule |
| `table_destroyed` may appear as an ack code (post to a destroyed table); folds to `other` in metrics | `refusalOf` | PORT_PLAN §9 |
| Rate-limited requests are acked | `guard` | Not a deviation — Node acks too (`sock:460`); CLAUDE.md §7.1's "no ack" note is stale |

Not reproduced on purpose (INCIDENTAL, no client can observe): JSON key order; a client that sends
two data arguments with an ack id gets an ack from Go (Node handed the second argument as `ack`);
a handler panic becomes `internal_error` instead of Node's TypeError message text.

## How it was tested

`stack_test.go` builds the process suites' stack in-process: `sio.Server` + `Handler` +
`game.RoomManager` on `game.NewMemoryLedger` with a `PersistChips` hook that debits a fake wallet
and refuses a repeated `action_id` as `duplicate_action` (the UNIQUE constraint), a fake `UserStore`
(mutable chips, injectable outage), `auth.Tokens`, a real `metrics.Metrics`, real timers with the
Node suites' durations (`BOOT_AMOUNT=100`, `TURN_TIMEOUT_MS=60000`, `NEXT_HAND_DELAY_MS=150`,
`RECONNECT_GRACE_MS=400`, `TABLE_STAKES=''`, `LOBBY_TABLES=''`), behind `httptest`, driven by
`testclient`. No Postgres, no new module dependency (metric values are read through
`client_model`, already indirect in go.mod).

- **`handler_test.go` (35 tests)** — mirrors of `integration.test.js` (handshake refusals, quick-join
  deals a hand with `you.cards == []` and `cardCount` only for others, full hand see + show with
  `player:cards` to the owner only, out-of-turn refusal delivered twice, turn timeout →
  `last_standing` + `reason:'timeout'`, five-player cap, private create/join-by-code with boot forced
  to 200, leave frees the seat, second sign-in replaces the first, blind vs seen rooms, `sneaky` →
  seen, seen shows every stack / blind others' chips `null`, lobby list + filters, chat audience,
  backlog with system lines, chat refusals/flood/blank, history dies with the room, reconnect inside
  grace, lapsed seat offered back once, voluntary leave / closed table / stale offer / full table not
  offered, `/health`-style `Stats`), plus exact event ORDER on join (`room:state, room:joined,
  chat:history, room:state`), leave (removal traffic → `room:closed` → `room:left`), switch, and
  consolidation (`room:closed(old)` → `room:state(new)` → `room:moved` → `room:joined` →
  `chat:history`), idle kick after 3 missed turns, unfunded kick between hands, sideshow audience
  (reveal to the two players only, counted once), `ping:rtt` unguarded/no `ok`/echo, unknown event
  never acked, socket + game metrics (`metrics.test.js` socket parts incl. the cardinality sweep
  over every `game_*` label), internal-error double report, table destroyed under viewers.
- **`invalidmoves_test.go` (16 tests)** — every case of `invalidMoves.test.js`: out-of-turn
  chaal/pack/show/sideshow, off-ladder figures, non-numeric amounts (`"100"`, `"abc"`, `1.5`, `{}`,
  `[n]`, `true`, `"1e3"`, ±2^53) refused before the table for every action, `1e3` reaching the
  ladder, unknown/`__proto__`/absent/object/null actions with the exact interpolated message,
  `not_in_room`, show with three players, sideshow with two, unasked answer, see twice, replayed
  `actionId` charging nobody twice (one ledger row; `duplicate_action` on a genuine replay; 66-unit
  id replaced, 64-unit id honoured), requestCards outside a table and no card code ever reaching the
  other socket (frame-level scan), seating refusals (`already_in_room` on quickJoin/joinCode/create
  with no orphan table, `room_not_found`, `{$gt:''}` code, `-5`/`'lots'`/`0`/`200.5` stakes, `null`
  payload = default join), unfunded join, sixth player, chat coercion/length/blank (the other player
  hears exactly the 140-char line, `12345`, `hello table`; `1e3` is said as `1000`), garbage on every
  gameplay event acked within 1.5 s, 60-request burst → exactly 31 `rate_limited` acks matched by
  `game:error`s, chips conserved.
- **`payload_test.go` (11 tests)** — white-box: `parseAmount`, `jsString`, `jsTruthy`, non-object
  payloads, every decoder, `utf16Len`, `groupThousands`, handshake token selection, the fixed-window
  limiter.

Final run (`go build ./internal/socket/... && go vet ./internal/socket/... && gofmt -l` empty):

```
go test -race -count=1 ./internal/socket/...   → ok  (62 tests, ~22 s)
go test -race -count=4 ./internal/socket/...   → ok  (no flake in 4 consecutive runs)
```

(The ~5 s of `TestGarbageOnEveryEventIsAcked` is the limiter window the Node test also waits out.)

## Requests for other packages

- **internal/game (RoomManager)** — informational, nothing blocking: the handler duplicates
  `_assertUnderEntryCap` (`Handler.assertUnderEntryCap`, message `Players with more than 500,000
  chips cannot join this table`) for the DECISIONS §3 public-create validation because the
  RoomManager's `assertUnderEntryCap` is unexported. Exporting it (or a `ValidatePublicCreate(user,
  boot, category)` that runs the four checks in quickJoin order) would let the handler drop its copy
  and keep the two messages from ever drifting.
- **internal/sio** — none. `Disconnect(true)` running the callbacks synchronously, `Join` being a
  no-op after disconnect, and `Emit` never blocking are exactly what the handler relies on.
- **internal/app** — build order is `socket.New` → `game.NewRoomManager{TableListener: h, Listener:
  h}` → `h.SetRooms` → `h.Attach(sio)`, as `app.New` already does; `Handler.Stats()` is available for
  `/health` if wanted (Node did not use it).
- **CLAUDE.md §7.1** (doc, not code): "trip → `game:error rate_limited`, **no ack**" is stale — Node
  acks `{ok:false, code:'rate_limited'}` (`socket/index.js:460`) and so does Go.
- **go.mod** (shared file, FYI): the tests read metric values through
  `github.com/prometheus/client_model/go` (`(prometheus.Metric).Write(&dto.Metric)`), which promotes
  that module from `// indirect` to a direct requirement — it was already in the build graph, so no
  new module enters `go.sum`'s dependency set (`go mod tidy` also adds checksum lines for
  `kylelemons/godebug` and `klauspost/compress`, test-only dependencies of client_golang). If the
  integrator prefers go.mod untouched, `metricValue`/`observations` in `stack_test.go` can be
  rewritten over `Registry.Gather()` without the import.

## Notes for the integrator

- `Deps.Metrics` may be nil (every observation is guarded); `Deps.Clock` nil → `RealClock`; the
  rate-limit windows and every wire timestamp come from `Deps.Clock`, latencies from the wall clock.
- `Handler.mu` is never held while calling a Table, the RoomManager or `Socket.Emit`; `game.Listener`
  methods run on the actor and only read the `*View` — keep it that way (PORT_PLAN §3.4).
- `onDisconnect` is idempotent per socket and serialised by `session.disconnectMu`; it is invoked by
  sio's disconnect callback and, in the replacement path, explicitly after `previous.Disconnect(true)`.
- `testclient` is reusable by `internal/app` integration tests: `Dial/DialAuth/DialQuery`, `Request`
  (with ack), `Emit`, `Wait/WaitFrom/Since/Mark`, `Frames()` for byte-level assertions,
  `NoPayload{}` for `42["event"]`.
- Acceptance against the real clients (bots, ramptest, Flutter) is still to be run against the
  assembled binary — nothing in this layer needed a client change.
