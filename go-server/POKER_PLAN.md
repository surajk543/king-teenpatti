# POKER_PLAN.md — adding the Poker family beside Teen Patti

The Phase 1 report the brief asked for ("BEFORE WRITING CODE, first give me…"), written
19 Sep 2026 against the working tree at `b59b122` on `variation-teen-patti`. Every claim below
was checked against the code it cites; where CLAUDE.md and the code disagree the code is quoted
and the disagreement is noted, because a design built on the doc would have been wrong.

The rule that shapes everything here: **Teen Patti — seen, blind and variation — must stay
byte for byte what it is on the wire, in the ledger and in the live store.** Parity's exact key
sets (`tools/parity/lib/harness.mjs` `SNAPSHOT_KEYS`/`YOU_KEYS`/`SEAT_KEYS`/`OPTIONS_KEYS`/
`CONFIG_KEYS`), `wire_test.go`'s null-versus-absent bytes and the 141 black-box suites are the
proof, and they are run after every phase.

> **Status (19 Sep 2026, later the same day):** implemented on `variation-teen-patti`. Phase 1
> (the shared core: `game.Room`, `RoomFactory`, `Actor`/`LiveState`/`Settler`, the poker categories
> and config) is `b0966a3`; the server-side family (`internal/poker`, `socket/poker.go`, the
> migration, the unit tests) is `028f344`; the black-box suite, the bots, the rollback guard
> (`pokerConfig`, §9 risk 1) and the docs are `a74856f`; the Flutter client is `0f0358e`; the menu the
> owner asked for (ONE table per game, all four at 50,000) and two money fixes an adversarial review
> found — the antes refunded when every player folded to the dealer, and a refused `hand_left`
> checkpoint that nothing ever retried — are `159b4fc`. `go test -race ./...` is green across all
> 14 packages; parity is 195/217 with the four failures that predate this work (CLAUDE.md §13, plus
> two macOS-only metrics tests). CLAUDE.md §6.5 is now the reference for how the family behaves;
> this file stays as the record of why it is shaped the way it is.

---

## 1. Current game architecture

**One process, one static Go binary** (`cmd/gameplay`), PostgreSQL for money and audit only,
Redis (or an in-process store) for ALL game state, our own Socket.IO server (`internal/sio`).

**The table is an actor.** `game.Table` (`internal/game/table.go`, 3,741 lines) owns every
field of one Teen Patti table from one goroutine; every mutation is a closure posted with
`run()` that blocks until done (`post`/`loop`, table.go:540–594). Exported methods post;
unexported internals never do. Timers post back through `game.Clock.AfterFunc` and are guarded
by tokens/generations (`hand.turnToken`, `startTimerGen`, `unfundedTimerGen`). Events are
delivered synchronously on the actor to one `game.Listener` (events.go), one method per Teen
Patti event; a listener never calls back into its table. After every posted closure that set
`liveDirty`, `flushLive` (livestate.go:97) serialises `t.snapshot()` ONCE under `liveSeq+1` and
saves it with a compare-and-set; `live.ErrStale` fences the table (another process owns it).
`Suspend` (livestate.go:210) is the graceful-restart path; `RoomManager.Restore`
(roommanager_live.go:86) rebuilds every stored table through `validateSnapshot` →
`restoreTable` → `resume()` → `resumeTimers`.

**RoomManager** (`roommanager.go`, 2,256 lines) is the lobby: `tables map[string]*Table`,
`playerRooms` (one seat per wallet), quick-join/create/join-by-code/switch, consolidation of
lone players, the empty-table sweep, the per-user `userLocks` stripes that serialise taking a
seat with every lobby-only wallet change (`WhileUnseated`, `settlementOwed`,
`CreditBoughtChips`), and the live-store index (`kt:lobby:<category>:<boot>`, `kt:seat:<user>`).
It never holds its mutex while calling a table.

**Money** (`game.Ledger{Checkpoint, Settle}`, `db/ledger.go`): three checkpoints — pack,
leave, hand end — each writing `delta = chips now − chipsWritten` under `SELECT … FOR UPDATE`
with a UNIQUE `chip_ledger.action_id`; `duplicate_action` on a retry means the write already
landed. A bet writes nothing. Settlement is memory-first with a retry chain
(`retrySettle`/`settleDetached`, table.go:3131–3294) that outlives the table. **The DB counts
per entry** (`applyCheckpoint`, db/ledger.go:81–134): several `IsWinner` entries in one
`Settle` each get their own `Pot` credited — the single-winner assumption lives only in
`Table.endHand` (table.go:2968–3022), not in the ledger.

**Cards** (`deck.go`, `handrank.go`, `variation.go`): `Card{Rank 2..14, Suit byte}`, 2-char
wire codes, crypto/rand Fisher–Yates, `Deal(count, cardsPer)` returning the untouched stub;
`Evaluate` (3 cards only, panics otherwise), `Compare` (element-wise over `Score []int`,
category first), the wild-card search and `EvaluateBest` (best 3 of 5) for Variation.

**Socket layer** (`internal/socket/handler.go`, 1,859 lines): one `Handler` is the sio
connection handler, the `game.Listener` and the `game.RoomListener`. `guard` wraps every
inbound event (30/5 s limiter, panic recovery, ack + `game:error` twice, metrics);
`room:joined`/`room:state` are ALWAYS per viewer via `SerializeFor(viewerID)`; the
reconnect grace, resume offers (in the live store), presence and single-session rule are
game-neutral. It holds `*game.Table` concretely in ~30 places and `*game.RoomManager` in `Deps`.

**Flutter** (`flutter-client/lib`): no Navigator; `GameState` (one ChangeNotifier, 1 s tick)
turns every `room:state` into `RoomState` and flips `screen`; the table screen
(`table_screen.dart`, ~5,700 lines) is one Scaffold whose felt places exactly five seats; the
action bar is `you.options.raiseSteps` through `GameState.bet()`; the lobby is a two-level rail
derived from `config.tables`, with any unknown category filed under Seen.

**Category is the only discriminator today**, and it is a CLOSED set of three normalised in
seven places: `config/parse.go:134` (LOBBY_TABLES whitelist), `config.NormalizeCategory`
(config.go:751), `game.NormalizeCategory` (roommanager.go:535), `newTableCore` (table.go:479 —
also the RESTORE path: an unknown category in the live store restores as a seen table),
`app.roomsHandler` (app.go:842), `socket.knownCategories` (handler.go:1607) and Flutter
`lobbyCategoryOf` (game_state.dart:1538). `validateSnapshot` never looks at the category.

## 2. Relevant existing files

| Area | Files | Role for Poker |
|---|---|---|
| Actor / live store / settle chain | `internal/game/table.go` (post/run/loop 540–594, retrySettle 3131–3294, destroy 3297), `livestate.go` (flushLive, fence, Suspend, restore, validateSnapshot) | the shell to EXTRACT and share (§4) |
| Rules engine | `table.go` (hand/seat structs 203–296, betOptions 1847, advanceTurn 1815, endHand 2943), `table_variation.go`, `view.go`, `events.go`, `snapshot.go`, `constants.go`, `errors.go` | Teen Patti only; untouched except for `Category` and `Snapshot.Game` |
| Cards | `deck.go`, `handrank.go`, `variation.go` | reused as-is; poker adds its own evaluators |
| Money | `internal/game/ledger.go`, `internal/db/ledger.go`, `ledger_purge.go`, `migration/V1.0.0__baseline.sql` | reused as-is; one new migration |
| Lobby | `roommanager.go`, `roommanager_live.go`, `internal/live/{store,common,redis,memory}.go` | generalised over a `Room` interface |
| Config | `internal/config/{config,parse}.go`, `.env.example` | poker categories, `PokerVariantConfig`, env keys |
| Sockets | `internal/socket/{handler,wire,payload}.go` | `poker:*` events; `Room` instead of `*Table` |
| App / metrics / auth | `internal/app/app.go`, `internal/metrics/{metrics,names}.go`, `internal/auth/http.go` | `Room` at the seams; poker labels |
| Flutter | `lib/state/game_state.dart`, `models/dtos.dart`, `net/game_connection.dart`, `screens/{lobby,table}_screen.dart`, `widgets/*`, `l10n/strings.dart`, `theme/app_theme.dart` | Poker lobby section, poker table screen, DTOs, strings |
| Tests / tools | `internal/game/*_test.go`, `internal/socket/stack_test.go`, `internal/app/*_test.go`, `tools/parity/*`, `tools/bot.js`, `bot-play/` | new poker suites; a poker parity profile; a poker bot brain |

## 3. What can be reused unchanged

- `game.Card`, `Code()/CardCodes/ParseCards`, `NewDeck`, `Shuffle`, `Deal` and its `remaining`
  stub (deck.go) — community cards, draws and the dealer's hand are slices of the stub, as the
  variation top-up already is (table_variation.go:331).
- `game.Compare` over `Score []int` — proven a total order; a 5-card evaluator that emits
  `[category, tiebreaks…]` compares under it unchanged.
- `game.Evaluate(cards, EvaluateOptions{AceLowIsLowest: true})` — the ready-made 3-Card Poker
  straight order (A-K-Q high, A-2-3 lowest). Tested, and no production caller uses it today.
- `game.Ledger`, `SettleEntry`, `PackedActionID/LeftActionID/SettleActionID`, the four
  `hand_*` reasons, the purge, `duplicate_action`-as-success — per-entry counting already
  handles several winners (split and side pots) with NO interface change.
- `game.Clock`/`RealClock`/`testclock.Fake` and the token-guarded timer idiom.
- `RoomChat`, `ChatMessage`, `SeatInfo`, `NewPlayer`, `Player`, `GameError` + snake_case codes.
- `live.Store` (opaque JSON per room under a seq; buckets `<category>:<boot>`), `Suspend`/
  `Restore` orchestration, `RestoreSeats`, resume offers, presence.
- The whole socket transport: `guard`, the limiter, `refusalOf`, per-viewer broadcast loops,
  `trackRoom/untrackRoom`, reconnect grace, chat, `room:*`/`session:*` events, `parseAmount`
  and the actionId hygiene.
- RoomManager's per-user machinery (`userLocks`, `WhileUnseated`, `settlementOwed`,
  `CreditBoughtChips`, `LoadPlayer`), matchmaking, consolidation, sweeper, stack bands.
- REST, auth, pictures, rewards, purchases, metrics registry, `/health`.
- Flutter: `GameConnection`, `GameState` session/lifecycle/chat/pictures/rewards,
  `_Root`/`_BackGuard`/`_TableRoutes`/`_NoticeHost`, `SeatPod`, `PlayingCard`, `DealFlights`,
  `PotFlight`, `LiquidFill`, the glass kit, `Strings`, `formatChips`, the lobby rail widgets,
  `VariationPrompt` as the template for an on-felt timed choice.
- Test scaffolding: `testclock`, `MemoryLedger` hooks, `dbtest.Open`, `livetest`,
  `socket/testclient`, the parity harness's profile-per-server model.

## 4. What needs to be generalised (and how, without changing Teen Patti bytes)

1. **A `game.Room` interface** at the four concrete-type seams — `RoomManager.tables` and its
   return types, `socket.Deps.Rooms` + `seatSocket/roomAck/broadcastState/sendChatHistory`,
   `metrics.RoomsSource.LiveTables`, `RoomListener.OnTableCreated`/`TableRestoreListener`.
   Its methods are exactly what those callers use today (ID, Code, Category, Game, IsPrivate,
   BootAmount, MaxPot, MaxPlayers, CreatedAt, PlayerCount, IsFull, IsEmpty, HasHand, State,
   Version, LiveSeq, SaveLive, Fenced, Destroyed, ViewFor, Summary, Seats, FindSeat,
   ChatHistory, PostChat, AddPlayer, RemovePlayer, CreditChips, SetConnected, SetAvatar,
   Destroy, Suspend, Settled, PendingSettlements, WaitSettlements, SettlementsLanded,
   RestoreChat, Resume). `*game.Table` satisfies it as it stands (plus two one-line exported
   wrappers, `ViewFor` returning `any` and `RestoreChat`). Nothing in package `game` is
   byte-pinned by parity, so this is a pure Go refactor under `go test -race`.
2. **The actor shell, extracted as pure moves**: `game.Actor` (post/run/loop, destroyed/fenced),
   `game.LiveState` (flushLive/fence/appendChat/delete with a `Snapshot() ([]byte, error)`
   hook) and `game.Settler` (the retry chain with its detached continuation and
   `WaitSettlements`). `Table` embeds them and delegates; every existing test pins the
   behaviour (settlement_test, review_money, livestate_test, roommanager_live_test). If an
   extraction turns out not to be a pure move it is abandoned and poker copies that piece.
3. **`Category` grows four poker values and a `Game()` family**: `three_card_poker`,
   `five_card_draw`, `texas_holdem`, `omaha`; `Category.Game()` is `teen_patti` for the three
   Teen Patti categories and `poker` for these. The seven normalisers learn the four values.
   `HidesChips()` stays false for poker (stacks are public in every poker game).
4. **Table construction and restore dispatch on the family**: `RoomManagerOptions.Factories`
   (`map[Game]RoomFactory{New, Restore}`) — package `game` cannot import `poker`, so `app`
   wires the poker factory in. `Restore` peeks at the stored document's `game` key BEFORE any
   Teen Patti parsing; `game.Snapshot` gains `Game string json:"game,omitempty"` (absent =
   Teen Patti, so every existing snapshot and `TestSnapshotRoundTripIsLossless` are unchanged).
5. **Config**: `LobbyTable` entries accept the poker categories; `PokerConfig` (turn timeout,
   min buy-in in boots, max discards, draw timeout) under `GameConfig`; `LobbyTableOption`
   gains poker-only `omitempty` fields (`game`, `smallBlind`, `bigBlind`, `ante`, `minBuyIn`,
   `holeCards`, `maxDiscards`) so Teen Patti entries keep their bytes.
6. **Socket dispatch**: `poker:action` beside `game:action` (the Teen Patti pre-gate against
   `AllActions` and its `unknown_action` precedence are untouched); the Teen Patti-only
   inbound events refuse a poker room with `wrong_game`; `guard`'s invalid-move counter becomes
   a set; label safe-lists gain the poker categories, actions and win reasons.
7. **Flutter**: `RoomState.game` + `poker: PokerState?` (absent on Teen Patti tables);
   `TableScreen.build` switches on the family to mount either today's felt or the new
   `PokerTableScreen`; the table chrome the two share moves to `widgets/table_chrome.dart` as a
   pure move; `lobbyCategoryOf` files the four poker categories under a Poker family card.

## 5. Proposed Poker architecture

```
internal/game        Room, Actor, LiveState, Settler, Category.Game(), Snapshot.Game, RoomFactory
internal/poker       the Poker family (new package, imports game; game never imports it)
  variant.go         Variant (THREE_CARD_POKER | FIVE_CARD_DRAW | TEXAS_HOLDEM | OMAHA),
                     VariantConfig{HoleCards, Community, Streets, MaxDiscards, HasDealer,
                     UseExactlyTwoHole, MinPlayers, MaxPlayers}, the closed table of the four
  eval5.go           Evaluate5 (Royal Flush … High Card, wheel A-2-3-4-5), Hand{Category, Name,
                     Score, Cards, Best}; Combinations(n,k); BestOf(cards,5); BestHoldem(hole,
                     board) = best 5 of 7 (21); BestOmaha(hole, board) = best of C(4,2)×C(5,3) (60)
  eval3.go           Evaluate3 = game.Evaluate(…, AceLowIsLowest) with the top two categories
                     swapped (Straight Flush > Three of a Kind > Straight > Flush > Pair > High)
  pot.go             contributions → side pots; Award(pots, ranking) → payouts, odd chips left
                     of the button; every tie splits
  betting.go         one no-limit betting round: current bet, min raise, who is still to act,
                     Options(seat) {fold, check, call, bet, raise, allIn} with amounts
  table.go           the poker actor: seats, hand, streets, timers, the four flows, settlement
  flow_holdem.go / flow_omaha.go / flow_draw.go / flow_threecard.go   per-variant steps
  view.go            PokerView (the redacted per-viewer wire struct) and YourOptions
  events.go          poker.Listener (its own interface — game.Listener is not widened)
  snapshot.go        poker.Snapshot ("game":"poker"), validate, restore
  errors.go          codes: wrong_game, not_your_turn, invalid_amount, invalid_discard, …
internal/socket      poker:* events, poker.Listener implementation on the same Handler
internal/app         wires poker.Factory into RoomManagerOptions.Factories
```

**Server authority**: the poker table deals, keeps the deck stub and every hole card on the
server, computes the legal options per seat per street, validates every amount against them,
runs the timers (turn, draw, next hand), evaluates the hands and pays the pots. A client sends
intent only. `ViewFor(viewer)` redacts: the viewer's own hole cards, other seats' `cardCount`
only, the dealer's cards only at the reveal, community cards to everyone.

**Money**: the three-checkpoint model exactly. Fold → `hand_packed`; leave/switch/kick mid-hand
→ `hand_left`; hand end → one `hand_win` per winner (`IsWinner`, `Pot` = that winner's share)
and `hand_loss` for the rest, in ONE `Settle`. Blinds/antes/bets move in memory only.
`DidChaal` ("played") = a voluntary bet beyond the forced one: call/bet/raise, or PLAY in
3-Card Poker. **3-Card Poker has no counterparty wallet**: the dealer is the house, the
player's row carries their net delta, chips enter or leave the economy exactly as rewards and
picture purchases already do; the per-hand zero-sum audit exempts dealer hands (§6).

**The four flows** (MaxPlayers 5, MinPlayers 2 everywhere — the global figures, so lobby,
consolidation and the Flutter felt need no per-game seat count):
- *Texas Hold'em*: button rotates; SB = boot/2, BB = boot (heads-up: button posts SB); 2 hole
  cards; preflop → flop(3) → turn → river, no-limit, min raise = last raise size; a street
  ends when everyone still in has matched the bet or is all-in; when at most one player can
  still act the board is run out; showdown by best 5 of 7 with side pots; a hand ends early
  when one player is left. Min buy-in 10 × boot (`POKER_MIN_BUYIN_BOOTS`).
- *Omaha*: Hold'em with 4 hole cards and exactly two of them counted.
- *5-Card Draw*: ante = boot from every funded seat at the deal; 5 cards each; betting round
  (min bet = boot); draw round (each player in turn discards 0..`POKER_MAX_DISCARDS` cards,
  timeout = stand pat); second betting round; showdown; side pots.
- *3-Card Poker*: ante = boot; 3 cards each and 3 to the dealer face down; each player in
  turn PLAYs (a second bet equal to the ante) or FOLDs (ante lost); dealer reveals; dealer
  qualifies with Queen-high or better: not qualified → play bets returned and antes paid 1:1;
  qualified → each player's hand against the dealer's, win pays ante and play 1:1, loss takes
  both, a tie pushes. No ante bonus or pair-plus (documented, not built).

**Timers**: `POKER_TURN_TIMEOUT_MS` (default = TURN_TIMEOUT_MS); a lapsed turn checks when it
can and folds otherwise, `missedTurns++`, kick at MAX_MISSED_TURNS as Teen Patti; the draw
window uses the same clock; `NEXT_HAND_DELAY_MS` between hands; `UNFUNDED_GRACE_MS` for a seat
below the min buy-in.

## 6. Proposed database changes (one migration, no new table)

`V1.0.2__chip_ledger_game.sql` — idempotent, runs on every boot:

```sql
ALTER TABLE chip_ledger ADD COLUMN IF NOT EXISTS game    TEXT;
ALTER TABLE chip_ledger ADD COLUMN IF NOT EXISTS variant TEXT;
```

Teen Patti rows leave both NULL, so nothing it writes changes. A poker row carries
`game='poker'`, `variant='texas_holdem'` (etc.). `SettleEntry` gains `Game, Variant string`
(empty → NULL); `appendLedger` inserts them. The brief's `round_id` is the existing `hand_id`;
`hand_result` is the existing `reason` (`hand_win`/`hand_loss`/`hand_packed`/`hand_left`).
Stats: poker hands count in the existing `users` counters (`hands_played` on a voluntary bet,
`hands_won`, `total_winnings`, `biggest_pot` = the most taken in one hand) and towards the
25-hand milestone — no new columns. `db_test.go` pins the script count at three; the
"no ALTER in the baseline" rule is untouched. `money.test.js` learns the two columns:
per-hand zero-sum holds for every hand except `variant = 'three_card_poker'`.

## 7. Proposed socket events (all new names; Teen Patti's are unchanged)

| Client → server | Payload | Ack |
|---|---|---|
| `room:quickJoin` / `room:create` / `room:joinCode` / `room:switch` / `room:leave` | as today; `category` is one of the four poker categories | as today, `category` echoes it |
| `poker:action` | `{action: fold\|check\|call\|bet\|raise\|allIn\|play\|draw, amount?, cards?: [codes to discard], actionId}` — `amount` is the total bet-to for bet/raise; `cards` only with `draw` (empty = stand pat) | `{ok, action, amount?, discarded?}` |

| Server → client | Audience |
|---|---|
| `room:joined` / `room:state` — `PokerView` per viewer, same top-level keys as Teen Patti's where the concept is the same (`roomId, code, isPrivate, category, state, handNo, dealerSeat, maxPlayers, minPlayers, bootAmount, turnTimeoutMs, startsAt, pot, turn, you, seats`), plus `game:"poker"` and a `poker` block (§8) | per viewer |
| `poker:handStarted {handId, handNo, dealerSeat, variant, smallBlind, bigBlind, ante, participants}` | room |
| `poker:cards {cards}` — hole cards at the deal, the new hand after a draw | owner only |
| `poker:turn {userId, seatIndex, street, deadline, timeoutMs}` / `poker:yourTurn {deadline, timeoutMs, options}` | room / player |
| `poker:action {userId, seatIndex, action, amount, street, pot}` | room |
| `poker:street {street, community}` — flop, turn, river dealt | room |
| `poker:draw {userId, seatIndex, discarded}` — how many, never which | room |
| `poker:showdown {reveals:[{userId, seatIndex, cards, best, handName, category, won}], community, dealer?: {cards, handName, qualified}}` | room |
| `poker:handEnded {handId, handNo, variant, pots:[{amount, winners:[{userId, amount, handName}]}], nextHandAt}` | room |
| `game:error {code, message}` — every refusal, as today | socket |

Refusal codes (snake_case, compared by code): `wrong_game` (a Teen Patti event at a poker
table or the reverse), `not_in_hand`, `not_your_turn`, `invalid_action`, `invalid_amount`
("Bet must be between X and Y"), `invalid_discard`, `not_drawing`, `duplicate_action`.

## 8. Proposed game state

**On the wire** (`PokerView.poker`, present only on poker tables):

```json
"game": "poker",
"poker": {
  "variant": "texas_holdem",
  "street": "preflop | flop | turn | river | draw | decision | showdown",
  "community": ["As","Td","7c"],
  "pots": [{"amount": 3000, "eligible": [0,2,3]}],
  "currentBet": 400, "minRaise": 400,
  "smallBlind": 100, "bigBlind": 200, "ante": 0,
  "holeCards": 2, "maxDiscards": 3,
  "dealer": {"cardCount": 3, "cards": [], "handName": "", "qualified": null},
  "result": {"pots": [...]}        // the last hand's payouts, until the next deal
}
```

`seats[]` add `streetBet`, `allIn`, `lastAction` (poker action names) and keep `cardCount`;
`you` adds `streetBet`, `options` (`{fold, check, call, callAmount, bet, minBet, raise,
minRaise, maxRaise, allIn, play, draw, maxDiscards}` — null off turn) and `hand
{handName, category, best}` once the viewer's hand can be named. `state` keeps the four
`TableState` values so `handLive`, summaries, metrics and the lobby index need no change.

**In the live store** (`poker.Snapshot`, `"game":"poker"` first): config, seats (stack,
status, hole cards, street bet, contributed, chipsWritten, didChaal, missedTurns, allIn),
hand (id, no, variant, button, street, deck stub, community, dealer hand, pots/contributions,
current bet, min raise, last aggressor, to-act order, turn seat/deadline, draw deadline),
startsAt, seq/version. Validated on restore as `validateSnapshot` validates Teen Patti's.

**In memory**: the same, as unexported structs on `poker.Table`, actor-owned.

## 9. Risks to existing Teen Patti (and the guard for each)

1. **Restore mis-dispatch**: a poker document under the same key family parsed by the Teen
   Patti path would restore as a seen table (`validateSnapshot` has no category check,
   `newTableCore` folds unknown to seen). Guard: the `game` peek runs BEFORE any parser; the
   Teen Patti parser refuses a non-empty unknown `game`; a test stores one of each and restarts.
   Rollback constraint: a Go tag older than this cannot restore live poker tables — DEPLOY.md
   gets the note (suspend/drain poker tables before rolling back).
2. **Shared wire structs**: any new field on `TableView`/`YouView`/`SeatView`/`TurnOptions`/
   `LobbyOptions`/`PublicGameConfig` changes Teen Patti bytes. Guard: poker has its own view
   types; the only shared additions are `omitempty` and absent on Teen Patti (`Snapshot.Game`,
   poker fields on `LobbyTableOption`); parity's exact key sets stay exact and a poker suite
   gets its own.
3. **The actor/settler extraction** touches the live rules engine. Guard: pure moves only;
   `go test -race ./...` and the full parity run after that step alone, before any poker code.
4. **`Room` interface refactor** changes types in RoomManager/socket/metrics/tests. Guard:
   compile-time (`var _ Room = (*Table)(nil)`), the race suite, parity.
5. **Lobby semantics**: `categories` on `session:ready.config` grows by the poker categories
   the menu offers — a wire change for every client, exactly as variation was. Guard: absent
   when the menu lists no poker table; production's `.env` sets LOBBY_TABLES explicitly, so
   nothing changes there until the owner adds an entry; `MIN_CLIENT_BUILD` is raised in the
   same deploy (an installed build files a poker table under Seen and would draw it as Teen
   Patti).
6. **Stake gate**: poker stakes are the existing `TABLE_STAKES` values (boot = big blind or
   ante), so `AssertStakeAllowed` needs no change.
7. **Consolidation/sweep**: unchanged because poker tables keep MinPlayers 2 and report
   `HasHand`/`State`/`PlayerCount` through the same interface.
8. **Metrics**: poker categories, actions and win reasons are added to the safe-lists so they
   are not folded into `other`; `pot_settled_chips_total` adds the total paid per hand.
9. **The known ALL_LEFT double-outcome row** (a departed winner paid by `destroy`) is a Teen
   Patti hole the poker engine must not copy; it is left as it is in Teen Patti (out of
   scope) and poker's settlement skips a departed player's second row.
10. **Bots**: `bot-play` (the resident fleet) joins a hard-coded seen/blind list and cannot
    reach a poker table; `tools/bot.js` gets a poker brain so parity and the emulator can be
    driven. A bot restored to a poker table after a menu change would be refused `wrong_game`
    on `game:action` and leave.

## 10. Implementation plan (phases, each ending in a green full run)

1. **Shared core, Teen Patti untouched on the wire** — `Room` interface; `Actor`/`LiveState`/
   `Settler` extraction; `Category.Game()` + four values through the seven normalisers;
   `Snapshot.Game`; `RoomFactory` and restore dispatch; config (`PokerConfig`, lobby entries,
   `LobbyTableOption` poker fields); `V1.0.2` migration + `SettleEntry.Game/Variant`. Gate:
   `go build/vet/gofmt`, `go test -race ./...`, `npm run parity` (all profiles).
2. **`internal/poker` foundations** — variants, `eval5` (exhaustive 2,598,960-hand test with
   textbook counts), `eval3` (22,100-hand test), combinations, side pots, betting round,
   the actor, view/snapshot/events, socket `poker:*` wiring, app factory. Gate: unit tests
   with `testclock`, race.
3. **3-Card Poker** flow + tests (dealer qualifies / does not, push, fold, timeout, leave).
4. **5-Card Draw** flow + tests (discard limits, stand pat, timeout, two betting rounds).
5. **Texas Hold'em** flow + tests (blinds incl. heads-up, all-in run-out, side pots, ties,
   odd chips, kick, restart mid-street).
6. **Omaha** flow + tests (exactly-two rule, ties).
7. **Flutter** — DTOs, `PokerState`, `GameState` poker getters/actions, Poker lobby category
   with variant cards, info dialog and rules section, `PokerTableScreen` (felt, community
   cards, pots, dealer pod, hole-card fan, discard selection, action keys with a bet stepper),
   strings ×5, widget tests. Gate: `flutter analyze && flutter test`.
8. **Cross-cutting tests** — socket suite (`internal/socket/poker_test.go`: hostile payloads,
   races, leaks of hole cards), `internal/app` restart/resume with a live poker hand, parity
   profile `poker` (`tools/parity/poker.test.js` with an independent JS evaluator oracle and
   a deep scan for leaked cards; `money.test.js` learns `game`/`variant`), `tools/bot.js`
   poker mode. Gate: `go test -race ./...`, `npm run parity`, flutter tests.
9. **Docs** — CLAUDE.md (§2, §6.5 Poker, §7.1 events, §7.3 migration, §7.4 config, §8.4
   Flutter), DECISIONS.md, `spec-socket-protocol.md`, DEPLOY.md rollout/rollback note,
   `.env.example`.
