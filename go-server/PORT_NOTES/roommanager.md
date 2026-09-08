# PORT_NOTES — internal/game/roommanager.go (RoomManager)

Owner scope: `internal/game/roommanager.go`, `internal/game/roommanager_test.go`,
`internal/game/roommanager_fixture_test.go`. Port of `server/src/game/roomManager.js` (515 lines) per
`PORT_NOTES/specs/spec-room-manager.md`, `PORT_PLAN.md` §3.2 and `DECISIONS.md` §3. No other file was
edited; no module dependency was added. All 25 `panic("not ported")` stubs are gone.

## What is ported

| Node (`roomManager.js`) | Go | Notes |
|---|---|---|
| constructor (`ledger ?? (settle \|\| persistChips ? null : createLedger())`) | `NewRoomManager` | `Ledger` nil → `NewMemoryLedger(opts.LedgerHooks)`. **New optional field** `RoomManagerOptions.LedgerHooks MemoryLedgerHooks` (additive; the app passes `Ledger`). The game package cannot build the Postgres ledger — `app` does. |
| `setInterval` sweeper | `StartSweeper` / `Shutdown` | Driven by the injected `Clock` (DECISIONS §3): `clock.AfterFunc(ConsolidateInterval, tick)` re-arms itself; consolidate then sweep, a consolidate error skips the sweep, both logged `table sweep failed`. `ConsolidateInterval <= 0` disables it (warn). `sweeperOnce` makes a second call a no-op; `Shutdown` stops it. |
| `normalizeCategory` | `NormalizeCategory` (package func, skeleton) | strict `"blind"` else seen. |
| `assertStakeAllowed` / `assertTableOffered` | same names | messages verbatim: `That stake is not valid`, `Stake must be one of: 200, 5000`, `The lobby offers: seen 200, blind 200, blind 5000`. Empty lists = unrestricted. |
| `createTable` / `_createTable` | `CreateTable` → `newTableLocked` + `announceCreated` | Rules via `config.GameConfig.TableRules` (seen 2/7/1024/1.2M; blind 0/0/0/0; private → boot `PrivateBoot`, `MaxPot 500_000`, `MaxRaiseSteps 2`); every other `TableConfig` field copied from `config.Game`/`config.Chat`. Order: register → `OnTableCreated` → log `table created {roomId, code, bootAmount, category, isPrivate, maxPot(null for 0)}` → `ObserveCreation`. Codes regenerated until unique among live tables. |
| `getTable`, `getTableByCode` (upper-cases), `getTableForPlayer`, `listTables`, `lobbyOptions`, `stats` | same | `ListTables`/`LiveTables` return creation order (Node's Map order); `Summary()` is called outside `mu`. `LobbyOptions.Stakes/Tables` are always non-nil (`[]` on the wire); `MaxPot` via `GameConfig.MenuMaxPot`. |
| `quickJoin` | `QuickJoin` | check order `already_in_room → invalid_stake → (normalise) → table_not_offered → insufficient_chips → over_entry_cap` (message `Players with more than 500,000 chips cannot join this table`, en-US grouping). Fullest public non-full same boot+category, ties to the earliest created; table state ignored; else create. |
| `joinByCode` | `JoinByCode` | `already_in_room → room_not_found → table_full ("That table is full") → insufficient_chips → over_entry_cap (public only)`. No stake/menu check. |
| `switchTable` | `SwitchTable` | `not_in_room` ("You are not at a table") / `private_table` / `no_other_table` ("No other blind table at this stake has a free seat right now"); no entry cap; leave reason `moved` (no consolidation; emptied source destroyed **before** the new seat is taken, Node's order). |
| `join` | `Join` | reserve index under `mu` before `AddPlayer`, roll back on failure. |
| `leave` | `Leave` | index deleted first; `RemovePlayer(reason)` (reason reaches the wire as the pack's `game:action.reason`); emptied → destroy; else `reason != "moved"` → `ConsolidateTables`. `nil, nil` when unseated. |
| `destroyTable` | `DestroyTable` | index entries + table out of the maps under `mu`, then `Destroy()` (settles a live pot), `OnTableDestroyed`, log `table destroyed`. No-op for an unknown id. |
| `consolidateTables` / `_movePlayer` | `ConsolidateTables` / `movePlayer` | public, no hand, waiting, exactly one player; grouped `category:boot` in first-seen order; oldest by `CreatedAt` (ties by creation sequence) is the target; chips copied from the seat, `socketId` kept; event order **source events → target events → OnTableDestroyed(source) → OnPlayerMoved** (asserted by `TestRoomsConsolidationEventOrder`); restore on failure. |
| `sweepEmptyTables` | `SweepEmptyTables` | hardcoded 30 s (`createdAt < now-30s`, strict), empty, waiting; injected Clock. |
| `shutdown` | `Shutdown(ctx)` | stop sweeper, destroy every table in creation order (live hands settled `all_left`). Returns when done or `ctx.Err()` at expiry (destroys carry on in the background). |
| `table.on('error'/'persistError')` + the socket layer's `table.on('kick')` | `tableHooks` | forwards every event to the socket layer's `Listener`; `OnPersistError` → warn `table write refused {roomId, reason, error}`; `OnError` → error `table error {roomId, error}`; `OnKick` → new goroutine: if still seated **at that table** → `Leave(uid, reason)` → `RoomListener.OnPlayerKicked{RoomID, UserID, Reason, Message}` (or log `kick failed`). |

## Concurrency design (beyond PORT_PLAN §3.2 — please review)

`mu` protects only `tables`, `order`, `pending`, `playerRooms` and is never held across a Table call.
Three additions were needed to make the Node semantics hold under real parallelism; all are inside
`roommanager.go` and invisible on the wire:

1. **Seat holds (`pending`).** Node's quick-join never failed with `table_full` because nothing could
   interleave between "pick the fullest table" and `addPlayer`. In Go, fifty simultaneous quick-joins all
   picked the same 4-seat table and 45 of them were refused by the Table. Now a pick (or a creation) and a
   *seat hold* happen in one `mu` critical section; `pickTableLocked`/`fullLocked` count held seats; the
   hold is converted into the index entry + `AddPlayer` afterwards (`seatHeld`) and released whatever
   happens. `Join` takes a hold too, so a table whose last seat is held refuses `table_full` (Table wording
   "This table is full") instead of sending a sixth player to the actor. Switch and consolidation hold the
   target seat from the moment it is chosen, so the "target filled up in between" restore path is only
   reachable when the target is destroyed under them.
2. **Per-player striped locks (`userLocks`, 256 stripes, FNV).** A seat transition flips the index and then
   posts to a Table; two transitions for the *same* player racing through that gap (a `room:leave` while a
   sweep moves that lone player; a kick racing a switch) could strand a seat nobody is indexed for. Every
   transition of one player (Join/QuickJoin/Leave/SwitchTable/movePlayer/the kick goroutine's Leave) holds
   that player's stripe for its duration. Stripes are never nested and never held together with `mu`
   (which is taken and released inside), so no deadlock is possible; a stripe *is* held across the Table
   call — deliberately: it blocks only other transitions of the same (or a same-stripe) player, never the
   manager. `TestRoomsConcurrentLeaveAndConsolidationNeverStrandASeat` exercises it.
3. **`destroyTable(id, onlyIfUnclaimed)`.** Leave, movePlayer, SwitchTable and SweepEmptyTables destroy an
   emptied table only if it is still empty **and** nobody holds a seat / index reservation on it (Node's
   `if (table.isEmpty)` could not see a half-finished join). `DestroyTable` (public; Shutdown and the socket
   layer's create-failure cleanup) stays unconditional.

Other Go-only details: `order` (creation sequence) breaks `CreatedAt` ties (a fake clock stamps every table
alike; Node relied on Map insertion order); `Join` on a table that is not registered (already destroyed)
returns `ErrTableDestroyed` (`table_destroyed`) instead of seating on a dying table; `Leave`/`movePlayer`
treat `ErrTableDestroyed` from `RemovePlayer` as "already gone"; `QuickJoin` re-picks (≤ 3) when the table it
picked was destroyed under it; a table `QuickJoin` created for a join that then failed is removed at once
instead of waiting for the 30 s sweep.

## Deviations (each traced)

| Behaviour | Node | Go | Authority |
|---|---|---|---|
| `switchTable` join failure after leaving | player left unseated, ack `table_full` | seat on the source restored; if the source was destroyed the error is returned and the caller finds the player unseated | DECISIONS §3 |
| Room codes | no collision check | regenerated until unique among live tables | DECISIONS §3 |
| Sweeper clock / 30 s age | real `setInterval` + `Date.now()` | injected `Clock` (same interval, same hardcoded 30 s) | DECISIONS §3 |
| Public `room:create` validation / `already_in_room` before creating | not validated / table leaked | done in `socket/handler.go` (it calls `AssertStakeAllowed`/`AssertTableOffered`/`CreateTable`/`Join`); RoomManager's `CreateTable` stays unvalidated like Node | DECISIONS §3 |
| `LOBBY_TABLES` unknown category | advertised, unjoinable | rejected by `config.FromEnv` | DECISIONS §3 |
| Kick handling | socket listener awaited `rooms.leave` on the table event | `tableHooks.OnKick` goroutine → `Leave` → `OnPlayerKicked`; guard is "still seated at the kicking table" (Node's synchronous handler could only ever see that state) | PORT_PLAN §9 |
| `QuickJoinOptions.BootAmount == 0` | skeleton doc said "0 → default boot" | **validated as given → `invalid_stake`**, matching Node's `bootAmount <= 0` check (`stakes.test.js` "a malformed stake is refused"). The socket layer already resolves absent/null to the default before calling (DECISIONS §7), so a 0 here is a client that sent 0 and Node refused it. `CreateTableOptions.BootAmount 0 → default` is unchanged. | wire behaviour (spec §5.2, §17.4) |
| Quick-join races (`table_full` from the Table under load), same-player transition races | unobservable in Node | seat holds + per-player stripes (above) | PORT_PLAN §3.2 ("never seat a player twice / never exceed MaxPlayers") |
| `Shutdown` | no bound | `ctx` bounds the wait; destroys continue in the background after expiry | skeleton contract |

## Tests (`roommanager_test.go`, external package `game_test`, fixture in `roommanager_fixture_test.go`)

Real `Table`s, bookless `MemoryLedger` (Node's `settle: () => ({})`), `testclock.Fake` (hence the external
test package — `testclock` imports `game`), recording `Listener`/`RoomListener`, log captured through slog.
89 tests, all under `-race`:

- `consolidation.test.js` — all 15 cases, plus tie-break by creation order, seat chips/socket preserved,
  and the exact event order.
- `lobbyRules.test.js` — the 10 entry-cap / switch cases, plus cap disabled by 0, private → `private_table`,
  fullest-other-table choice, `moved` skips consolidation and destroys the emptied source, mid-hand switch
  packs with reason `moved`.
- `privateTables.test.js` — the 8 RoomManager cases (ladder `[200,400]`, raise 800 → `invalid_bet`, pot
  ceilings, snapshot `maxPot`, uncapped ladder to the stack).
- `tableRules.test.js` — the 5 RoomManager cases (incl. 120 blind chaals never force a showdown, seen forces
  after 7 rounds) plus a full `TableConfig` equality check for seen / blind / private-blind / private-seen /
  unknown-category tables.
- `stakes.test.js` (in-process parts, real default menu) — all 9, including the verbatim `lobbyOptions` JSON,
  `[]` never null for an empty menu, check order, fullest-table clustering with ties by age, a sixth player
  opens a new table, private tables never picked/listed.
- Join/leave/lifecycle: `JoinByCode` codes and messages (incl. case-insensitive codes, private skips the cap),
  index rollback on Table refusals, join on a destroyed table, leave reasons on the wire, emptied table
  destroyed, 30 s sweep (29 s kept, exactly 30 s kept, 30 s+1 ms swept), sweeper ticks & stop on Shutdown,
  Shutdown settles live hands (`all_left`, full pot) and honours an expired ctx, Stats JSON, ListTables
  filters, 300 unique 6-char upper-case codes, creation metric/log/listener.
- Hooks: insufficient-chips kick (emitted mid-`AddPlayer`, Leave completes, `OnPlayerKicked` fields), idle
  kick (`MaxMissedTurns 1`, message `Left the table after 1 missed turns`), stale kick ignored,
  `table write refused` (boot) and `table error` (settlement abandoned after 10 attempts: 1 + 10 persist
  errors) logged and forwarded.
- Concurrency: 50 goroutines quick-joining → every player seated exactly once, no table over `MaxPlayers`,
  index consistent, then 50 concurrent leaves empty the room; 50 concurrent joins of one account (three
  routes) → exactly one seat; 8 tables with kicks racing funded joins → every kick completes; lone players
  leaving while a sweep merges them (10 rounds) → nobody stranded or double-indexed.

Not deterministically testable and therefore not covered: the switch/move *restore* paths (they now require
the target to be destroyed in the sub-millisecond window after the hold); the code is a straight
`seat(source)` and is logged.

Final run:
```
$ go build ./internal/game/... && go vet ./internal/game/... && go test -race ./internal/game/...
ok  	github.com/surajk543/king-teenpatti/go-server/internal/game	4.9s
ok  	github.com/surajk543/king-teenpatti/go-server/internal/game/testclock	1.0s
$ go test -race -count=5 -run TestRooms ./internal/game/     # ok
$ go test -race -count=30 -run 'TestRoomsConcurrent|TestRoomsKick|TestRoomsIdleKick|TestRoomsShutdown|TestRoomsSweeper|TestRoomsSettlement' ./internal/game/   # ok
$ go test -race -run TestRooms -v ./internal/game/ | grep -c '^--- PASS'
89
```
`gofmt -l` clean on the three files; `go vet ./...` clean for the module.

## Requests for other packages

- **socket/handler.go (create route):** the cleanup `if table.IsEmpty() { rooms.DestroyTable(id) }` after a
  failed `Join` is unconditional; a public table created there can, in the same instant, have seats *held*
  by concurrent quick-joiners (they would then get `table_destroyed`). Vanishingly rare and only on the
  create-failure path; if you want it airtight, ask me to export a claim-aware `DestroyEmptyTable` (it exists
  unexported as `destroyTable(id, true)`).
- **socket/handler.go (quickJoin):** the handler resolves absent/null `bootAmount` to the default before
  calling `QuickJoin` — keep doing that; `QuickJoin` now refuses `0` with `invalid_stake` as Node did
  (see deviations).
- **config:** nothing — `GameConfig.TableRules`, `MenuMaxPot`, `NormalizeCategory` are used as delivered.
- **table.go:** nothing needed. (Observed while testing: everything RoomManager relies on — `Seats`,
  `FindSeat`, `SetConnected`, `Destroy` settling `all_left`, kick emission inside `AddPlayer`, retry-settle
  → `OnError` after 10 attempts — behaves as its doc says.)

## Notes for the integrator

- Build order is unchanged: `socket.New` → `game.NewRoomManager{Ledger: db ledger, Clock, TableListener: h,
  Listener: h, Logger, Metrics}` → `h.SetRooms` → `metrics.BindRooms(rooms)` → `rooms.StartSweeper()`.
- `RoomListener.OnPlayerKicked` is called from a RoomManager goroutine *after* the seat is gone; the socket
  layer emits `room:kicked`, untracks, and re-broadcasts if the table still exists (its `OnKick` stays a
  no-op). `OnTableDestroyed` fires for tables nobody ever tracked too (a quick-join's own failed table) —
  harmless for the current handler.
- Consolidation event order is Node's, so the moved player's `room:closed` precedes `room:moved`/`room:joined`
  (DECISIONS §1 requires exactly that).
- `Shutdown(ctx)`: pass the 8 s budget ctx; live pots are settled through `Table.Destroy` before it returns.
- Log lines (slog attrs): `table created {roomId, code, bootAmount, category, isPrivate, maxPot}`,
  `table destroyed {roomId}`, `player moved to a busier table {userId, fromRoomId, toRoomId}`,
  `table write refused {roomId, reason, error}`, `table error {roomId, error}`, `kick failed {userId, reason,
  error}`, `table sweep failed {error}`, `table consolidation failed, restoring seat {error}`,
  `table switch failed, restoring seat {userId, roomId, error}`.
- `Stats.Players` is `len(playerRooms)`; seat holds are not counted (they are not seats yet), and a player
  mid-`Leave` is already uncounted (Node's "off the index first"). `LiveTables` is what the metric gauges
  should read; it never blocks on an actor.
