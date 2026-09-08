# PORT_NOTES — internal/game (pure parts: deck, handrank, chat)

Owner scope: `internal/game/deck.go`, `handrank.go`, `chat.go` and their tests
(`deck_test.go`, `handrank_test.go`, `chat_test.go`, `interop_test.go`). The Table,
views, snapshot, ledger, events, clock and RoomManager belong to other engineers.

## What is ported

| Node | Go | Notes |
|---|---|---|
| `deck.js` `SUITS/RANKS/cardCode/parseCard/newDeck` | already in the skeleton | unchanged |
| `deck.js` `shuffle` | `Shuffle` | Fisher–Yates `for i = 51..1: j = cryptoIntn(i+1); swap`. `cryptoIntn` draws 8 bytes from `crypto/rand` with rejection sampling (unbiased, like `crypto.randomInt`); a CSPRNG failure panics as `randomInt` throws. No `math/rand` anywhere in production code. |
| `deck.js` `deal` | `Deal` | round-robin `hands[seat][round] = deck[round*count+seat]`, `remaining = deck[count*cardsPer:]`. Negative counts clamp to 0; asking for more than 52 cards stops at the last card (Node would push `undefined`; unreachable — the Table deals at most 5×3). |
| `handRank.js` `evaluate` | `Evaluate` | exact algorithm order (trail → run → color → pair → high card), doubled run scale A-K-Q 28 > A-2-3 27 > K-Q-J 26 > … > 4-3-2 8, variant A-2-3 = 5, `Cards` in input order. Panics `"a Teen Patti hand must be exactly 3 cards"` on any other length (Node throws a plain Error). |
| `handRank.js` `compare` | `Compare` | element-wise over `max(len)`, missing → 0, first non-zero difference. |
| `handRank.js` `pickWinner` | `PickWinner` | same loop; ties sorted by `tieBreakOrder` index with absent keys last, **stable** (V8's sort is stable, so contender order is preserved among unlisted keys). `WasTie` = more than one contender shared the best score. |
| `CATEGORY_NAMES` | `CategoryNames` | English wire names, untranslated. |
| `chat.js` `RoomChat` | `RoomChat` | `Add` (sanitise, nil when empty, uuid, `at = Millis(clock.Now())`, evict oldest past `MaxHistory`), `AddSystem` (userId nil, displayName `"Table"`, `System:true`, text only truncated — not sanitised), `History` (copy, oldest first), `Size`, `Clear`. Returned pointers are to a copy, never into the buffer. A nil Clock falls back to wall time (bare test buffers). |
| `chat.js` `sanitize` | `SanitizeChat` | see below. |

### SanitizeChat, rule by rule (DECISIONS.md §4)
1. Every rune in Unicode category **C** (Cc, Cf incl. ZWJ/ZWNJ/BOM, Co, Cs) **and every unassigned
   rune** (Cn) becomes one **space** — Node's `/[\p{C}]/gu → ' '` replaces, it does not delete, and that
   is observable (`"a\x00b"` → `"a b"`). Implemented as "keep iff `unicode.In(r, L, M, N, P, S, Z)`".
   An invalid UTF-8 byte is treated as C as well (the only thing Node could have seen there is a lone
   surrogate, which is Cs).
2. Runs of JS `\s` (Go `unicode.IsSpace` + U+FEFF) collapse to a single ASCII space; U+0085 is in Go's
   set but not JS's — irrelevant because it is Cc and already a space after step 1.
3. Trim (same class).
4. Truncate to `maxLength` **UTF-16 code units** (emoji cost 2). A surrogate pair is never split: the
   supplementary rune that would only half fit is dropped whole (DECISIONS §4). `maxLength <= 0` → `""`
   like `slice(0, 0)`.

Number/object coercion (`String(text ?? '')`) is NOT here: `SanitizeChat` takes a `string`. The socket
layer must coerce JSON numbers to their decimal string and treat objects/arrays/booleans/null as `""`
before calling `Table.PostChat` (DECISIONS §4, spec-socket-protocol §7.1.1, `invalidMoves.test.js:392`).

## Doc-comment fix (skeleton was wrong against DECISIONS.md)
`SanitizeChat`'s skeleton comment said the Go port counts **runes** "as a documented, harmless deviation".
DECISIONS.md §4 mandates UTF-16 code units with pair-safe truncation. The implementation and the doc
comment now follow DECISIONS.md. Signature unchanged.

## How it was tested
Mirrors of `server/test/handRank.test.js` (all 15 cases incl. the 3 deck cases) and the buffer half of
`server/test/chat.test.js` (6 cases; the Table half — `postChat`, join/leave lines, `chatHistory`,
snapshot leak — is the table engineer's), plus:
- exhaustive: all C(52,3) = 22 100 hands evaluate; category frequencies 52/48/720/1096/3744/16440;
  score shape per category; suit/order independence; `Compare` antisymmetry and category-first on
  200 000 random pairs, full sort consistency + transitivity sweep, 741 distinct score classes
  (13+12+12+274+156+274); extremes A-A-A top, 5-3-2 offsuit bottom.
- `PickWinner` agrees with `Compare` on 20 000 random showdowns of 2–5 contenders; `tieBreakOrder`
  earliest-wins / absent-last / stable order; variant option honoured; nil for no contenders.
- `cryptoIntn` range and coverage for n = 1..52; 10 shuffles never leave the deck ordered.
- Sanitising: 24 rule cases (C → space, ZWJ/ZWNJ/BOM, Co/Cf/Cn, invalid byte, every JS `\s` member,
  Indic marks survive, UTF-16 truncation and pair safety, `max <= 0`), every code point U+0001–U+1FFFF
  never leaks a C/unassigned rune, JSON shape (`system` absent on player lines, `userId: null` on
  system lines), 100-cap eviction, configurable cap, clear, wall-clock fallback.
- **Node interop (`interop_test.go`)**: runs the real `server/src/game/{handRank,deck,chat}.js` under
  `node --input-type=module -e` and compares: all 22 100 hands (name, score, variant score) → 0
  mismatches; sanitising of `a<cp>b` for every code point U+0001–U+2FFFF plus the unit-test shapes
  (194 569 inputs) → 0 mismatches. Skips cleanly when `node` or `../server` is absent.

Final run (37 tests of mine; the package's other test files also pass at the time of writing):
```
$ go vet ./internal/game/ && go test ./internal/game/ -run '<my tests>' -v | grep -c '^--- PASS'
37
ok  	github.com/surajk543/king-teenpatti/go-server/internal/game	0.832s
$ go test ./internal/game/
ok  	github.com/surajk543/king-teenpatti/go-server/internal/game	0.819s
```
Node used for interop: v22.22.1. Postgres is not needed by this package.

## Deliberate deviations
- **UTF-16 truncation never splits a surrogate pair** (DECISIONS.md §4): Node could emit a lone
  `\udXXX`; Go drops the whole rune. Only reachable with a supplementary-plane character exactly at the
  140-unit (or 24-unit) boundary. Applied to `AddSystem`'s slice too.
- `Deal` clamps negative counts and stops at the end of the deck instead of producing `undefined` cards
  — unreachable from the Table (max 15 cards); no client can observe it.
- Everything else is exact, including keeping `\p{C}` → space (not deletion) and ZWJ destruction.

## Requests for other packages
- **socket layer** (`chat:message` handler): perform Node's `String(text ?? '')` coercion before
  `Table.PostChat` — JSON number → decimal string (`12345` → `"12345"`, asserted by
  `invalidMoves.test.js:392`), `true`/objects/arrays/null → `""` per DECISIONS §4 (note: DECISIONS
  chooses `""` for booleans/objects where Node produced `"true"`/`"[object Object]"`).
- **table engineer**: `Table` should call `PickWinner(contenders, preference, EvaluateOptions{})` with
  `preference` = seats by distance from the dealer's left, show-payer moved to the end (or keep the
  inline loop — DECISIONS §2 requires a test that both agree). `PickWinner` sorts ties stably, so
  contender order matters only for keys absent from the preference list.
- **table engineer**: build the chat with `NewRoomChat(cfg.ChatMaxHistory, cfg.ChatMaxLength, clock)`;
  a nil clock is tolerated but production must pass the Table's clock so `at` follows the test clock.
- No changes needed in files I do not own.

## Notes for the integrator
- `internal/game` tests cannot import `internal/game/testclock` (import cycle); `chat_test.go` carries a
  4-line `stepClock` instead.
- `interop_test.go` shells out to `node` relative to the module (`../server`). It is a parity gate, not a
  unit test: if the Node tree is removed from the repo later, the tests skip rather than fail.
- Test helper names in package `game` are `cards(...)`, `eval(...)`, `beats/ties`, `allHands`,
  `assertScore`, `newChat`, `texts`, `itoa`, `equalInts`, `stepClock`, `nodeServerDir`, `runNode` —
  avoid redeclaring them in other `_test.go` files of the package (`hand` is already a Table type, hence
  `cards`).
