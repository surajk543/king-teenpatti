# bot-play — the resident bot fleet

A fleet of bot players, written in Go, that keeps the lobby's Teen Patti tables
populated so a real player who opens the app finds a game in progress. Each bot
is an ordinary client of the game server: it signs in as a guest device, reads
the table menu the server publishes, sits down with `room:quickJoin`, plays only
the moves the server offers in `you.options`, and leaves. The server stays the
authority on every rule, every seat and every chip; a bot decides only **what**
to do and **when**.

It replaced the Node fleet (`src/`, `test/`, `package.json`, tagged
`bot-play/v1.0.0`) on 27 Sep 2026; that code is in git history.

```bash
cd bot-play && export PATH=$HOME/.local/go/bin:$PATH      # Go 1.27 (CLAUDE.md §3)
BOT_COUNT=10 go run ./cmd/bot-play                         # 10 bots against http://127.0.0.1:3000
BOT_MODE=simulation BOT_SEED=12345 BOT_COUNT=10 go run ./cmd/bot-play   # no server: the in-process simulator
go test -race ./...                                        # every package, ~10 s
bash ops/build.sh                                          # bin/bot-play, static, version-stamped
```

---

## Architecture

```
cmd/bot-play/main.go      flags (-config, -version) → config.Load → the menu → Deps → Manager.Start → SIGINT/SIGTERM → Manager.Stop
internal/
  config/                 config.go (Default, Load), yaml.go (strict YAML walk), env.go (EnvKeys), validate.go
  protocol/               wire.go (events, payloads, refusal codes), transport.go (the API / Dialer / Session interfaces)
  bot/                    identity.go, bot.go (Bot, Deps), lifecycle.go (sessions, sign-in, reconnect),
                          play.go (the event handlers), manager.go (start, stop), fleet.go (registry), scheduler.go
    state/                state.go (lifecycle state machine, Session, Snapshot), opponents.go (reads of other players)
    strategy/             personality.go (six families), teen_patti.go (Decide, Legal, imperfections, sideshow answers),
                          blind.go, seen.go, variation.go (the variation choice, the 5-Card pick)
    decision/             hand_strength.go (the server's ranking), evaluator.go, variation_tables.go, betting.go, risk.go
    table/                finder.go (the menu), selector.go (where to sit), switcher.go (when to move)
    timing/               human_delay.go, reaction.go (reaction times)
    interaction/          chat.go, messages.go (the lines), emote.go (NoEmotes)
    connection/           websocket.go (Socket.IO client), rest.go (REST client), reconnect.go (Backoff)
  sim/                    BOT_MODE=simulation: an in-process stand-in server
  metrics/                Prometheus metrics, /healthz, the debug view
  clock/, rng/            real and fake clocks; seeded random streams
```

**One bot = one goroutine, one event loop, one connection.** `Bot.Run` is the
bot's whole life on its own goroutine: sessions of play separated by rests. While
connected, `loop` is its single event loop — a `select` over the connection's
ordered event stream, the bot's scheduler and the stop signal — so all of a bot's
state belongs to that goroutine and needs no lock. The scheduler (`scheduler.go`)
keeps everything the bot means to do later (its move on this turn, a chat line,
getting up after the hand) in order under ONE timer. Each bot has its own
connection (a reader and a writer goroutine underneath) and its own random
streams, so a slow or disconnected bot never holds up another.

**What the bots share** is `bot.Deps`, none of it per-bot state: the REST API and
the websocket dialer (or the simulator's), the menu (`table.Finder`, one copy for
the fleet), the clock, the timing model, the per-table chat budget, the metrics,
the personality profiles, the configuration, the logger and the behaviour seed.

**The fleet registry** (`fleet.go`) is this process's memory of its own bots:
which user ids are the fleet's, and which table each sits at. It lets a bot tell
a table of fellow bots from one with a real player, spread the fleet across
tables, and keep bots from greeting each other in chorus. Nothing in it reaches
the server, and the server's `is_bot` label is never read (it is not on the wire).
Another fleet process's bots count as humans to this one.

**The lifecycle** is an explicit state machine (`state/state.go`); every
transition is one INFO `state` log line and moves the `bot_state` gauge:

```
OFFLINE → CONNECTING → ONLINE → SEARCHING_TABLE → JOINING_TABLE →
WAITING_FOR_HAND ⇄ PLAYING ⇄ WAITING_FOR_ACTION → PROCESSING_RESULT →
(WAITING_FOR_HAND | LEAVING_TABLE / SWITCHING_TABLE → SEARCHING_TABLE)
RECONNECTING from anywhere a connection can drop; RESTING between sessions
```

A transition the table does not list is logged at WARN (`state (unexpected
transition)`) and made anyway: a surprise never wedges a bot.

**The server is `protocol.API` + `protocol.Dialer`.** `connection.HTTPAPI` and
`connection.Dialer` implement them against the real server, `sim.Server` against
the simulator, so a bot runs the same code in both modes.

## Identity and sign-in

- **Device id `botplay-<six digits>`** — bot *i* of the fleet is
  `<bots.device_prefix><%06d of start_index+i>`: `botplay-000001`,
  `botplay-000002`, … The prefix **must** start with `botplay-` (config refuses
  anything else): the game server marks an account `is_bot` at login from the
  guest device id's namespace (go-server `BOT_DEVICE_PREFIX`, default
  `botplay-,practice-bot-,ramp-bot-`). The bot sends nothing else to say what it
  is, and `is_bot` is on no wire struct, so no player can tell.
- **Login** is `POST /api/auth/login {provider:"guest", deviceId, displayName}` —
  the door every guest uses. The display name (a first name, sometimes with a
  suffix — `Kabir_07`, `Meera`, `Rohanking` — from the bot's number) is written by
  the server only when the account is created.
- **A face.** A bot wearing no picture puts on a FREE, non-RIVE one from
  `GET /api/profiles`, chosen from its number, so a table of bots is not five
  grey initials.
- **Personality is stable per identity.** A bot's family is placed by its number
  on a golden-ratio sequence, weighted by `bots.personality_mix` (with the default
  even mix, ten consecutive bots cover all six families), and its traits are drawn
  from a seed hashed from its device id (FNV-1a). The same account plays the same way on every
  run, whatever the fleet's seed.
- **Behaviour seed.** Every decision, delay and chat line is drawn from
  `rng.Derive(seed, number)` — the bot's own stream. `seed` (`BOT_SEED`) 0 draws
  it from the clock in server mode; a simulation with no seed uses 12345, so it is
  repeatable by default.

## Configuration

`configs/bot.yaml` (or the file `-config` names), then the environment, then
validation — read once at start. Every key in the shipped `configs/bot.yaml` is at
its default and commented with its environment variable; the file may be deleted
(a missing `configs/bot.yaml` is not an error; a missing file named with
`-config` is). The YAML reading is strict: an unknown key, a wrong type (`3.5`
where a whole number is read, `yes` where `true`/`false` is), or one setting given
under both its spellings (`min_duration_minutes: 20` and `min_duration: 20m`)
stops the process naming the key and its line. A bad environment value stops it
naming the variable.

| Environment | Default | Key |
|---|---|---|
| `BOT_MODE` | `server` | `mode`: `server` or `simulation` |
| `SERVER_URL` | `http://127.0.0.1:3000` | `server_url`: REST at `<url>/api/…`, Socket.IO at `<url>/socket.io/` |
| `WS_URL` | *(derived)* | `ws_url`: a `ws://`/`wss://` address when it is not `server_url`'s |
| `BOT_SEED` | `0` | `seed`: 0 = from the clock (simulation: 12345) |
| `BOT_COUNT` | `20` | `bots.count`, 0–10000 |
| `BOT_DEVICE_PREFIX` | `botplay-` | `bots.device_prefix`: must start `botplay-`; letters, digits, `-_.`, ≤ 48 |
| `BOT_START_INDEX` | `1` | `bots.start_index`: the first bot's number (the last must be ≤ 999999) |
| `BOT_MIN_HANDS` | `3` | `table.min_hands`: never leave a table before this, bar a forced reason |
| `BOT_MAX_HANDS` | `20` | `table.max_hands`: always move on by this many |
| `BOT_SESSION_MIN_MINUTES` | `20` | `session.min_duration` |
| `BOT_SESSION_MAX_MINUTES` | `120` | `session.max_duration` |
| `BOT_CATEGORIES` | `seen,blind,variation` | `table.categories` |
| `BOT_ENABLE_CHAT` | `true` | `interaction.enable_chat` |
| `BOT_DEBUG_ADDR` | *(off)* | `debug.addr`: loopback only |
| `BOT_DEBUG_SHOW_CARDS` | `false` | `debug.show_cards` |
| `BOT_METRICS_ADDR` | *(off)* | `metrics.addr` |
| `LOG_LEVEL` | `info` | `log.level`: debug, info, warn, error |
| `LOG_FORMAT` | `json` | `log.format`: json or text |
| `BOT_RECONNECT_MAX_DELAY_SECONDS` | `30` | `reconnect.max_delay` |
| `BOT_COLLECT_BONUS` | `true` | `bankroll.collect_bonus`: a broke bot collects the 6-hour bonus |
| `BOT_DEV_REPLENISH` | `false` | `bankroll.dev_replenish`: refused outside simulation |
| `BOT_BOOTS_TO_SIT` | `25` | `table.boots_to_sit` |
| `BOT_LOBBY_TABLES` | *(every table)* | `table.lobby_tables`: the lobby tables the fleet plays, comma-separated entries `category:boot`, each optionally `:fleet=FLOOR-CEILING` (*The fleet's layout*, below) |
| `BOT_FLEET_PER_TABLE` | `0,0` | `table.fleet_per_table`: `floor,ceiling` of the fleet's bots at every lobby table named without a `fleet=` of its own |

Switches read `1/0`, `true/false`, `yes/no`, `on/off`; anything else is an error
(a switch typed wrong must not read as off). An empty variable is unset.

The YAML sections, in `configs/bot.yaml`'s order:

- **`bots`** — `count`, `device_prefix`, `start_index`, `start_stagger_ms`
  ([400, 2500]: the gap between starting one bot and the next, drawn per bot),
  `personality_mix` (family → weight; empty = even).
- **`session`** — `min_duration_minutes` 20, `max_duration_minutes` 120,
  `rest_min_minutes` 5, `rest_max_minutes` 45 (or `min_duration: 20m` …). A
  session's length is drawn inside the personality's own span (the *Session*
  column below) clamped to these: `min_duration` and `max_duration` are hard limits,
  the personality only narrows them. The rest is drawn between the two rest figures (four times as long
  after an account the server refused).
- **`table`** — `min_hands`, `max_hands`, `categories`, `category_weights`,
  `boots_to_sit` 25 (sit only with that many boots), `search_delay_ms`
  [2500, 8000], `max_bots_per_table` 0 (no limit), `no_human_patience_seconds`
  0 (never move for want of a human), `lobby_tables` [] (every table; an
  entry may carry its own `:fleet=FLOOR-CEILING`) and `fleet_per_table`
  [0, 0] (*The fleet's layout*, below).
- **`timing`** — `min_reaction_ms` 700, `max_reaction_ms` 5000,
  `safety_margin_ms` 3000, `ranges` (kind → [min_ms, max_ms]).
- **`strategy`** — `enable_blind`, `enable_seen` (not both false), `tuning`
  (family → trait → [low, high], e.g. `{AGGRESSIVE: {blind_rate: [0.40, 0.60]}}`).
- **`interaction`** — `enable_chat`, `enable_emotes` (false: see *Chat*),
  `probabilities` (moment → [low, high]), `cooldown_seconds` 12,
  `table_gap_seconds` 6, `table_per_min` 6, `language` `mixed` | `english`.
- **`reconnect`** — `base_delay_ms` 1000, `max_delay_seconds` 30,
  `max_attempts` 0 (for ever).
- **`bankroll`** — `collect_bonus` true (a broke bot collects the lobby's 6-hour
  bonus, 25,000 chips, `POST /api/rewards/bonus`), `dev_replenish` false.
- **`debug`** — `addr`, `show_cards`. **`metrics`** — `addr`. **`log`** — `level`,
  `format`.

## Running

All from `bot-play/`, with Go on the path (`export PATH=$HOME/.local/go/bin:$PATH`).

```bash
# one bot, readable logs, against the dev server on :3000
BOT_COUNT=1 LOG_FORMAT=text go run ./cmd/bot-play

# ten bots against a server on another port, with the debug view
BOT_COUNT=10 SERVER_URL=http://127.0.0.1:3001 BOT_DEBUG_ADDR=127.0.0.1:9101 go run ./cmd/bot-play

# a hundred bots from the built binary, metrics and the debug view on one address
bash ops/build.sh
BOT_COUNT=100 SERVER_URL=http://127.0.0.1:3000 BOT_METRICS_ADDR=127.0.0.1:9101 BOT_DEBUG_ADDR=127.0.0.1:9101 ./bin/bot-play

# simulation: no server, no accounts, no real chips — repeatable from the seed
BOT_MODE=simulation BOT_SEED=12345 BOT_COUNT=10 go run ./cmd/bot-play
BOT_MODE=simulation BOT_SEED=12345 BOT_COUNT=100 ./bin/bot-play

# a second process beside the first: a range of numbers of its own
BOT_COUNT=50 BOT_START_INDEX=1001 ./bin/bot-play

./bin/bot-play -version                     # bot-play <git describe>
./bin/bot-play -config /path/to/other.yaml  # a file of your own; the environment still overrides it
```

The bots start staggered (0.4–2.5 s apart by default: a hundred take about two
and a half minutes to all arrive). The process first reads `GET /api/tables` and,
while the server is not answering, waits — trying every three seconds, with a WARN
`waiting for the game server` on the first try and every tenth — rather than
exiting. `Ctrl-C` (SIGINT) or SIGTERM stops the fleet gracefully (*Stopping*).

**Build.** `bash ops/build.sh` builds `bin/bot-play` — `CGO_ENABLED=0`, stripped,
with `main.version` set from `git describe --tags --match 'bot-play/v*'` minus the
`bot-play/` prefix (`v1.0.0-221-ge18cdce-dirty` while the newest tag is the Node
fleet's; `dev` from a plain `go build`). It uses the Go that
`go-server/ops/build.sh` installs in `~/.local/go` (running that script first when
there is none and no `go` on the path). Tags are cut by hand, `bot-play/vX.Y.Z`,
like the server's (CLAUDE.md §14.4).

**systemd** (on the game host):

```bash
bash ops/build.sh                    # as the checkout's owner
sudo bash ops/install.sh             # copies ops/bot-play.service to /etc/systemd/system/, enables, restarts
sudo BOT_USER=gameplay bash ops/install.sh   # the same, run as that user
journalctl -u bot-play -f            # watch it
sudo systemctl restart bot-play      # after a rebuild
sudo systemctl stop bot-play         # every bot finishes its hand and leaves
sudo bash ops/install.sh uninstall   # stop and remove
```

The unit runs as `BOT_USER` — unset, the user the installed fleet already runs as
(drop-ins included), else the unit's own `deploy`; production has no `deploy` and
runs it as `gameplay`, the game server's own user (30 Sep 2026: the unit as
shipped restart-looped there on systemd's 217/USER, so `install.sh` now refuses a
user the host does not have, or who cannot run the binary). It runs
`bin/bot-play -config configs/bot.yaml` in
`/var/www/gameplay/king-teenpatti/bot-play` with `BOT_MODE=server`,
`SERVER_URL=http://127.0.0.1:3000`, `BOT_COUNT=450`, the fleet's five lobby
tables and their sizes (`BOT_LOBBY_TABLES`, `BOT_FLEET_PER_TABLE`, *Production
notes*), `BOT_BOOTS_TO_SIT=20`, metrics on
`BOT_METRICS_ADDR=127.0.0.1:9101` and the debug view on `BOT_DEBUG_ADDR=127.0.0.1:9102`
(9100 is node_exporter's in `go-server/ops/monitoring`); `Restart=always`, `KillSignal=SIGTERM`,
`TimeoutStopSec=75` (the fleet's own grace is 60 s). It is ordered after
`gameplay.service` without requiring it: the fleet waits for the server. To move
a dial, edit the installed copy's `Environment=` lines (or `ops/bot-play.service`
and re-run `install.sh`), then `systemctl daemon-reload` and restart.

**Docker** (from the repository root):

```bash
docker build -t bot-play bot-play/                      # --build-arg VERSION=… stamps the version
docker run --rm --network host -e BOT_COUNT=10 -e SERVER_URL=http://127.0.0.1:3000 bot-play
```

A distroless static image running as nonroot, with `configs/` baked in and
`BOT_MODE=server`; configure it with `-e` variables.

## The debug view and metrics

Both are off until an address is set, and both belong on loopback. The debug view
has no authentication and names every bot and its account — exactly what the
fleet exists not to tell players — so `debug.addr` is **refused** unless it is
`127.0.0.1`, `::1` or `localhost`. Given the same address, one listener serves
both.

```bash
curl -s 127.0.0.1:9102/healthz                      # {"ok":true,"bots":N}  (the debug listener)
curl -s 127.0.0.1:9102/debug/bots | head -40        # every bot, JSON
curl -s '127.0.0.1:9102/debug/bots?format=text'     # every bot, text
curl -s 127.0.0.1:9102/debug/bots/botplay-000017    # one bot by device id (or user id), text; ?format=json
curl -s 127.0.0.1:9101/metrics | grep '^bot_'
```

A bot's snapshot: device id, user id, personality, state and since when, table
key and room, hand number, blind or seen, the last decision, its reason and the
reaction time, chips, the session's hands, wins and losses, reconnects and the
last error. **Cards are stripped** unless `debug.show_cards` /
`BOT_DEBUG_SHOW_CARDS` is on. Port 9100 is node_exporter's in the monitoring
bundle — use another.

## How a bot plays

The package `strategy` is pure: every decision is a function of what the server
showed this seat (`you.options`, `you.cards`, `you.hand`, the public table), the
bot's personality, its memory of the hand and its random stream. **Every move it
returns is one the options allow, and every amount a rung of the ladder the server
sent** (`strategy.Legal`, held over random turns by `TestDecideIsAlwaysLegal`); a
decision that has gone stale by the time its delay ends is decided again. Force
Sideshow and Missile are never used — they cost hammers and missiles.

### Personalities

Six families (`strategy.DefaultProfiles`). Each bot draws every trait uniformly
inside its family's range, so two AGGRESSIVE bots are alike in kind but not the
same player. `strategy.tuning` overrides any range.

| Family | Blind rate | Tightness | Aggression | Bluff | Mistakes | Hands at a table | Session (min) | At the table |
|---|---|---|---|---|---|---|---|---|
| CAUTIOUS | 0.20–0.35 | 0.62–0.85 | 0.10–0.30 | 0.01–0.04 | 0.01–0.03 | 10–40 | 30–120 | folds what is not clearly good, raises small, settles with sideshows, low stakes, stays put |
| BALANCED | 0.35–0.50 | 0.42–0.62 | 0.35–0.55 | 0.04–0.09 | 0.02–0.04 | 8–30 | 25–100 | the regular; reads opponents most (Adapt 0.70–0.95); the strongest family |
| AGGRESSIVE | 0.45–0.65 | 0.20–0.42 | 0.65–0.92 | 0.10–0.22 | 0.03–0.06 | 5–22 | 20–80 | raises often and high, bluffs, high stakes, moves tables readily, quick |
| LOOSE | 0.40–0.60 | 0.05–0.28 | 0.30–0.55 | 0.06–0.14 | 0.04–0.08 | 6–25 | 20–90 | plays almost everything, pays to see it through, shows often; leaks chips |
| RANDOM | 0.25–0.60 | 0.15–0.85 | 0.15–0.85 | 0.05–0.20 | 0.08–0.16 | 4–30 | 15–90 | wide ranges and high Noise (0.35–0.60): bent thresholds and the odd whim |
| BEGINNER | 0.30–0.55 | 0.30–0.60 | 0.20–0.50 | 0.02–0.08 | 0.10–0.20 | 5–20 | 10–45 | the most mistakes, thinks slowly, plays small; the weakest family |

The other traits: BlindLove (how long a blind intent lasts), Noise, Adapt,
SideshowRate, ShowRate, ChatRate, Pace, Distracted, StakeAppetite, TableMoves,
StopLossBoots and TakeProfitBoots (`personality.go`; `TraitNames()` lists the
tuning names). A big loss in a hand (10 boots or more) puts a bot on tilt: it
plays looser for a few hands, the tilt fading by 30% a hand.

**Imperfections** sit over every chosen move, at the personality's Mistake rate:
a bad call, a needless fold, a small raise on nothing, a big hand not made to pay,
one change of mind a hand; a player with Noise above 0.25 (RANDOM, mostly) makes
(Noise − 0.25) × 0.5 of its moves on a whim — under one in five for the noisiest.
Every one is still a legal move, and its reason in the log is `MISTAKE_*` or
`RANDOM_WHIM`.

**Opponent reads** (`state/opponents.go`): in memory for as long as the process
runs, each bot keeps counts on up to 256 players (aggression, looseness, fold and
blind rates, a style — passive, aggressive, tight, loose), shrunk towards neutral
on few observations. They feed the table's pressure and, for an adaptive player,
how much it leans on folders and away from callers.

### Blind or seen

A hand starts with a plan (`NewHandMemory`): stay blind for a number of bets, or
look at once. The chance of a blind intent is the bot's BlindRate on a seen table,
a tenth less on a variation table, and at a **blind table** three quarters of the
hands it would have looked at are played blind too (0.30 → 0.825). The plan is
1–4 blind bets on a seen table, 1–6 at a blind table, varied hand to hand. A
careful player may look straight after the deal (`LookEarly`: never with a blind
plan or a BlindLove of 0.75 or more, and far less at a blind table).

On each blind turn the bot weighs a look: the plan (unlikely before it is done;
then 0.6 on a seen table and only 0.22 at a blind one, rising each extra turn),
how little it loves blind play, the raises it has faced and the table's pressure,
the price (a blind chaal over 4% of the stack pulls, strongly past 10%), the chips
already in, the crowd, and noise — every pull but the plan counting for less than
half at a blind table. Staying blind is mostly a blind chaal; an aggressive player
now and then raises blind, a heads-up player now and then shows blind, a tight one
very rarely packs without looking. A blind chaal it cannot afford makes it look
first. The server turns the cards up itself at the table's blind-move limit.
`strategy.enable_blind: false` looks at the first chance; `enable_seen: false`
never looks voluntarily.

### Betting

With its cards seen (`seen.go`) the bot reads its hand's Strength (below), bends
it by its Noise, and judges it against the opponents still in:
win ≈ strength^opponents, discounted by how much of the table's pressure it
believes. In order:

1. **Heads-up, a show ends it** — when confident, short-stacked, tired of a long
   hand, pressed with a fair hand, or curious; a monster sometimes keeps betting.
2. **A chaal out of reach** leaves a show (heads-up) or a pack.
3. **A middling hand asks a sideshow** to settle cheaply — more as the hand drags
   on and the pressure mounts.
4. **Strong** (a sequence or better, or a win estimate over the strong bar, which
   pressure raises and aggression lowers): raise up the ladder, or slow-play it
   with a chaal.
5. **Middling** (over the call bar — pot odds, tightness, patience, pressure and
   the price, eased by chips already in): chaal, now and then raise.
6. **Weak**: bluff (more heads-up, less into raises, more against folders), float
   a chaal that costs next to nothing, take a sideshow's free chance, or fold.

**Raise sizing** (`decision.RaiseAmount`): only the server's rungs
(`options.raiseSteps[1:]`, at least twice the chaal, covered by the stack). The
budget is the stack × clamp(0.03 + 0.3·aggression·power, 0.02, 0.5); among the
rungs inside it the pick climbs from the lowest up to ⌊u·(1 + 3·aggression·power)⌋
rungs; the lowest raise when none fits.

**Pressure** (`decision.NewPressure`), 0..1: 0.45 × the raises faced
(1 − 0.6ⁿ), 0.25 × the biggest raise against the boot (log scale, 1 at 64 boots),
0.20 × the opponents' aggression, 0.08 × their looseness, − 0.05 per opponent still
blind. A player with no read counts as neutral (0.5).

**Answering a sideshow**: 5–10% of asks are let lapse (a player who did not
notice); a hand above its bar accepts 80–95% of the time, a weaker one 8–28%.

### Hand strength

`decision/hand_strength.go` is a client copy of the server's classic ranking
(`go-server/internal/game/handrank.go`), which a separate module cannot import.
It is **pinned to the server's own results**: `TestRankingIsTheServers` hashes
every one of the 22,100 three-card hands with its score and compares the SHA-256
and the per-category counts with a fingerprint taken from the server's `Evaluate`
on 27 Sep 2026. Strength is a hand's percentile among all 22,100 (ties counted
half). The bot uses it only to judge its own cards — the server's showdown decides
every hand.

On a **variation** table the bot never re-implements wild cards: it reads the
server's own evaluation of its hand (`you.hand`: the three that counted —
`playsAs`, else `best`), ranks those three classically, and reads the percentile
through a fixed per-variation table estimated offline (`variation_tables.go`), at
a lower confidence. MUFLIS is the classic percentile upside down. While a 5-Card
pick is open, or no variation is chosen yet, the hand is unknown and the bot stays
in only while it is cheap.

**The variation window**: the chooser picks from the options the **server**
offered this hand (never a list of its own — FIVE_CARD is absent when the deck
cannot cover it), mildly weighted by personality (a loose player likes Muflis, an
aggressive one the wild-card variations), and lets the window lapse at its
Distracted rate (1–9%), which makes the server choose Muflis. **5-Card**: it plays
its best three of five (`BestThree`, which names the same three as the server's
`bestPossible`), but slips to another three — usually a near miss — 4–16% of the
time (the careful least, beginners most) and lets the window lapse at half its
Distracted rate.

### Human-like timing

Every action waits a reaction time (`timing.HumanDelay.For`): the window's floor
plus a log-normal draw whose median sits 30% of the way up the window (σ 0.5,
redrawn past the top), so most reactions are quick with a tail of slow ones. Pace,
the decision's complexity, how marginal the hand is and a raise faced slow it; a
routine blind chaal is quicker. Decisions are held inside
`[min_reaction, max_reaction]` (0.7–5 s), and a distracted bot now and then pauses
another 2.5–15 s (someone put the phone down). No delay is a round figure.

| Kind | Default (ms) | Kind | Default (ms) |
|---|---|---|---|
| `see` | 500–1800 | `show` | 1500–4000 |
| `look_early` | 600–2200 | `sideshow` (asking) | 1200–3500 |
| `blind_chaal` | 700–1900 | `answer_sideshow` | 900–3200 |
| `chaal` | 800–2500 | `pick_variation` | 1500–5000 |
| `fold` | 700–2200 | `pick_cards` | 1500–4500 |
| `small_raise` | 1000–3000 | `difficult` | 2000–5000 |
| `large_raise` | 1500–4000 | `leave_table` | 1500–5000 |
| `chat` | 1000–5000 | `join_table`, `search_table` | 1000–4000, 2500–8000 |

`see`, `look_early`, `leave_table` and `chat` are shaped by pace alone; the rest
are decisions. `join_table` and `search_table` are configurable but not drawn
today (the idle gap before a search is `table.search_delay`). **Deadline safety**:
a delay always ends `safety_margin` (3 s) before the turn's or the window's
deadline — drawn into the last stretch before the margin when the draw would pass
it — and when less than that is left the bot acts after a short beat (≥ 150 ms).
A bot that timed out would be packed and, three times in a row, kicked for idling.

### Tables: choosing, staying, moving

**The menu** is the server's: `GET /api/tables` at start, the public
`teen_patti` tables of the allowed categories (`seen`, `blind`, `variation` —
never a poker room, whatever the configuration says), with each table's stack
band. No table key or stake is in the code. When a `session:ready` names a
`tableConfigVersion` the fleet does not hold, that session's own table list
replaces the menu at once and ONE bot refreshes it for the fleet. A table refused
`table_not_offered` is retired until the menu is next read.

**Choosing** (`table.Select`): the tables whose band admits the stack and whose
boot it covers `boots_to_sit` (8) times over — or, when none is that deep, the
cheapest the stack can sit at at all — drawn in proportion to (never simply the
best of): stake fit (a Gaussian over the stakes the stack can reach, centred on
the family's appetite: CAUTIOUS low to middling, BEGINNER low, AGGRESSIVE high),
comfort (the bankroll in boots against the depth it wants), the category weight,
fleet occupancy (a table the fleet is thin on weighs up to twice the average) and
recency (½ for the table just played), flattened by Noise. Then
`room:quickJoin {bootAmount, category}`; the server picks the table.

**After every hand it played** (`table.AfterHand`) a bot stays or moves, always
getting up before the next deal (a bot still seated then is dealt in):

| Reason | Move | When |
|---|---|---|
| `SESSION_OVER` | end the session | its planned length has run out |
| `NOT_OFFERED`, `SHORT_STACK`, `NOT_ADMITTED` | hop (else end) | forced, before `min_hands` too |
| `IDLE_TABLE` | hop (else end) | no hand dealt for 60–120 s (by TableMoves) |
| `MAX_HANDS` | switch or hop | `max_hands` reached |
| *(before `min_hands`)* | stay | |
| `STOP_LOSS`, `TAKE_PROFIT` | hop (else switch) | lost / won its StopLoss / TakeProfit boots here |
| `UNSUITABLE` | hop | under half the boots-to-sit depth with a cheaper table open, or the stake has drifted from its appetite |
| `TOO_MANY_BOTS` | switch | more fleet bots here than `max_bots_per_table` |
| `NO_HUMANS` | switch | no human here for `no_human_patience` |
| `TABLE_EMPTYING` | re-queue at this stake | two players or fewer, none human, and the fleet has a busier table of this kind (else stay; a human is never left heads-up) |
| `PLANNED_HANDS` | switch, sometimes hop | this sitting's planned hands (drawn per sitting from the personality inside `[min_hands, max_hands]`) are played |
| `RANDOM` | switch | a small per-hand chance, scaled by TableMoves |

A **switch** is `room:switch` (the server seats the bot at the quietest other
table of the same boot and category, or opens one); a **hop** is `room:leave` and
a fresh choice elsewhere; a **re-queue** is `room:leave` then `room:quickJoin` at
the same stake, which seats it at the fullest table with room. Besides, every
12–20 s a seated bot checks its session's end and whether its table has dealt no
hand for 70–130 s — a bot left alone deals no hands — and then leaves it for
another (`idle_table`). The server's own consolidation merges lone players too.

### Chat

Short, lowercase, Hinglish and English mixed (`interaction.language: mixed`, each
bot leaning its own way; or `english`), and mostly nothing: a moment gets a line
with a chance between the moment's low and high by the bot's ChatRate.

| Moment | Chance | Moment | Chance |
|---|---|---|---|
| `join` (sat down) | 0.10–0.25 | `big_raise` (someone raised ≥ 16 boots) | 0.03–0.10 |
| `welcome` (someone sat down) | 0.03–0.10 | `playing_blind` (after a blind raise) | 0.02–0.08 |
| `win` | 0.05–0.15 | `sideshow_won` / `sideshow_lost` | 0.04–0.10 / 0.03–0.08 |
| `big_win` (pot ≥ 12 boots) | 0.10–0.25 | `packed` | 0.02–0.06 |
| `loss` | 0.03–0.10 | `low_chips` (moving for a short stack) | 0.04–0.10 |
| `big_loss` | 0.06–0.16 | `leave` | 0.20–0.40 |
| `nice_hand` (someone won with a pure sequence or trail) | 0.03–0.10 | `reply_hi` (someone said hi) | 0.20–0.50 |
| `strong_hand` (after raising a strong hand) | 0.02–0.06 | `reply_name` (someone said its name) | 0.40–0.70 |

`variation` and `five_card` are raised once a hand, when the hand's variation is
announced (the line never names it: the announcement is on the felt already). A bot welcomes another bot 15% as often as a human, answers
another bot one time in ten, and avoids its own last three lines. **Budgets**: a
12-second cooldown per bot, and per table — across the whole fleet — one bot line
every 6 s and six a minute (`TableBudget`), far inside the server's 5 lines / 5 s
and 140 characters. The budget is spent when a line is decided; it goes out as
`chat:message` after a `chat`-kind pause.

**Emotes are not used** (`interaction.NoEmotes`): the server's `chat:emoji` sends
only an emoji the account **owns**, and the bots buy nothing — no emojis, premium
pictures, hammers or missiles. `emote.go` is where a version that buys and sends
them would connect.

## Reconnect

- **Backoff** 1 s, 2 s, 4 s, 8 s, 16 s, then 30 s (`reconnect.base_delay`,
  `max_delay`), each spread ±30% so a fleet that lost the server together does not
  come back in lockstep; `max_attempts` 0 retries for ever (a limit ends the
  session and the bot rests). A failing login backs off the same way.
- **The seat comes back by itself.** A seat the server still holds (inside its
  60-second reconnect grace, or restored from Redis after a server restart)
  arrives as `room:joined` on connect, and the bot picks the hand up where it is.
- **A resume offer** (`session:ready.resume`, the server's offer of a table whose
  seat lapsed) is taken with `room:joinCode`; refused, the bot looks for a table.
- **Neither**: after the usual idle gap the bot looks for a table.
- **A lost acknowledgement.** A move whose ack the connection took with it is
  remembered; if the same turn is still open after the reconnect, the move is
  **resent with the SAME `actionId`**, so the server applies it once (a copy it
  already has is refused `duplicate_action`, which the bot reads as done).
- **`unknown_user`, `invalid_session`, `missing_token`, `unauthorized`** at the
  handshake → the bot signs in again (after a wiped database, as a new account).
- **`account_disabled`**, or **`session:replaced`** (another connection signed in
  as this bot) → the session ends and the bot rests four times as long.
- A connection that sends no `session:ready` within 20 s is dropped and redialled.

**The connection** (`connection/websocket.go`) is a websocket-only Engine.IO v4 /
Socket.IO v5 client — the Flutter app's transport — with the JWT in the
handshake's `auth.token`, and `auth.appPlatform: "bot"` beside it (as the
`X-App-Platform: bot` header on every REST call): the game server's app version
gate (28 Sep 2026) never refuses a bot — not for a minimum version, not for a
maintenance, not with `APP_VERSION_REQUIRED` on. The server pings every 20 s and the client only answers
(a client ping would end the connection); 45 s with nothing from the server is a
dead connection. permessage-deflate is offered, frames under 256 bytes go out
plain, a frame over the server's `maxPayload` is refused before it is sent, and a
request's ack waits 8 s. **Slow consumer**: events are delivered in order and
never dropped; when a bot leaves 256 undelivered for 10 s the connection is ended
(and redialled) rather than let it miss what the table said. REST (`rest.go`) is
one pooled HTTP client for the fleet, 15 s a call; tokens travel only in headers
and are never logged.

## Stopping

SIGINT or SIGTERM asks every running bot to stop: a bot not in a hand leaves its
table at once; one in a hand plays it out, then gets up before the next deal; a
resting bot simply stops. Each leaves with `room:leave` and disconnects, so no seat
is left to the server's 60-second reconnect grace. After 60 s any bot still going
is stopped hard, and the `stopped` log line counts them (`forced`). The systemd
unit allows 75 s.

## Logs

JSON on stdout by default (`LOG_FORMAT=text` for reading by eye), one object a
line with `time`, `level` and `msg`. Every line a bot writes carries **`bot`**
(its device id); after sign-in its lines carry **`user`** too, except the `state`
lines. The ones to know:

| `msg` | Fields |
|---|---|
| `bot-play starting` | `version`, `mode`, `bots`, `prefix`, `server`, `seed`, `config` |
| `fleet layout` | `tables`: each lobby table the fleet plays with the size it keeps there, as an entry would give it (`blind:200:fleet=50-80`); only when `table.lobby_tables` names any |
| `table menu` | `version`, `tables` |
| `state` | `from`, `to`, and `table`, `hand`, `reason`, `attempt`, `for` where they apply |
| `session planned` | `length`, `personality` |
| `seated` | `table`, `room`, `planned_hands` |
| `action` | `table`, `hand`, `action`, `amount`, `reason` (e.g. `MEDIUM_HAND_LOW_PRESSURE`), `blind`, `delay` |
| `left table` | `table`, `reason`, `hands`, `net` |
| `switching table`, `leaving for another table`, `ending session` | `reason` (and `hands`) |
| `move refused`, `join refused` | `action` or `table`, `code` |
| `kicked`, `connection lost`, `login failed`, `account disabled: this bot cannot play` | the reason or error |
| `fleet` (every 5 min) | `bots`, `running`, `seated`, `hands`, and a count per state |
| `simulation` (every 30 s, simulation mode) | `accounts`, `tables`, `hands`, `moves`, `refusals`, `drops` |
| `stopped` | `forced` |

## Metrics

At `metrics.addr`, every series labelled `service="bot-play"`, beside the Go
runtime's `go_*` and `process_*`. As on the game server, no bot id, user id, room,
table code, name or free text is ever a label value: every label comes from a
small vocabulary and anything outside it is `other`.

| Metric | Labels |
|---|---|
| `bot_connected` | — (bots with a live connection) |
| `bot_disconnected_total` | `reason` (`lost`, `session_end`, `fatal`, `stopped`) |
| `bot_reconnect_total` | `result` (`ok`, `failed`) |
| `bot_state`, `bot_state_transitions_total` | `state`; `from`, `to` |
| `bot_table_join_total`, `bot_table_leave_total` | `category`; `reason` |
| `bot_hand_started_total`, `bot_hand_completed_total` | `category`; `category`, `result` (`win`, `loss`, `fold`) |
| `bot_action_total` | `action`, `blind` |
| `bot_refused_total` | `code` (the server's refusal codes) |
| `bot_decision_latency_seconds` | — (computing a decision, not the pause) |
| `bot_reaction_delay_seconds` | `kind` (the human pause drawn) |
| `bot_chat_total` | `moment` |

No job in `go-server/ops/monitoring/` scrapes the fleet yet.

## Testing

```bash
go test -race ./...                                    # every package; the race detector checks the loop/goroutine rules
go test ./internal/bot/decision -run RankingIsTheServers -v
BOTPLAY_LIVE_URL=http://127.0.0.1:3000 go test -run Live -v ./internal/bot/connection/   # one guest against a real server
go build ./... && go vet ./... && test -z "$(gofmt -l .)"
```

About 250 tests, their names written as sentences:

- **decision** — the ranking pinned to the server's fingerprint over all 22,100
  hands, known orders, `BestThree` matching the server's choice among equal
  hands; evaluation on seen, blind and variation tables, Muflis upside down,
  5-Card, the variation tables; pot odds, ladder rungs, raise sizing, pressure.
- **strategy** — family ranges and blind rates (`TestBlindRateRangesAreTheBriefs`),
  personalities alike but not identical, deterministic draws, tuning; the blind
  plan, pressure and price making a bot look, blind tables played far more blind;
  strong hands bet and weak ones fold, families recognisably different, mistakes
  legal and marked; **every decision legal** over random turns; the variation
  chosen only from the server's options, the 5-Card pick, sideshow answers.
- **table** — the menu from the catalogue and from a session, bands inclusive at
  both ends, never a poker table; selection by stake, comfort, occupancy and
  recency; each lobby table's own floor and ceiling of the fleet (a table under
  its own floor first, one at its own ceiling full while another under a higher
  one is chosen); every switcher reason, min and max hands, a human never
  abandoned heads-up.
- **timing** — every window, the skew, pace and difficulty, no round figures,
  **no delay past the deadline's margin**, the short beat, distracted pauses.
- **interaction** — every moment has lines and a chance, no line says "bot", the
  cooldown, the per-table budget (under contention too), no repeats, languages.
- **connection** — the socket URL, the handshake and its refusals, events in
  order, compressed frames, acks, timeouts, server pings answered, a silent server
  detected, disconnect and close packets, the slow-consumer policy, the token never
  logged; the REST client and its errors; the backoff.
- **bot** — against a scripted fake server: sign in and sit at a Teen Patti
  table, a restored seat resumed without a join, a legal move with a fresh
  `actionId`, **a lost ack resent with the same `actionId`**, a stale decision
  dropped, stop after the hand and not during it, a retired table, a full table, a
  chip kick looking again, a server restart, a wiped account signing in
  again, the scheduler, the registry, every family in a fleet of ten, a table's
  own ceiling letting the fleet grow there.
- **config**, **metrics**, **state** — strict YAML and environment reading, the
  shipped file at the defaults, validation, a lobby table's `fleet=` option and
  every refusal of it, the production unit's environment (`ops/bot-play.service`)
  loading as the owner's layout; labels never ids; the debug view
  stripping cards; opponent reads.
- **sim** — hands complete and chips are conserved at every kind of table, round
  and pot caps, refusal codes, idle kicks, the reconnect grace, sideshows,
  variation windows, switches, a dropped slow reader, **the same seed plays the
  same hands** (on a fake clock), a concurrent fleet on the real clock with
  latency and drops, payloads in the server's shapes.

## Simulation mode

`BOT_MODE=simulation` runs the fleet against `internal/sim`, an in-process
stand-in server that speaks the real server's wire shapes, so the bots run exactly
the code they run in production — with no server, no accounts and no real chips.
Its menu mirrors the default lobby's Teen Patti tables (`seen:200`, `blind:200` up
to 20 Lakh, `blind:5000` up to 20 Crore, `variation:50000` up to 200 Crore), with a
welcome of 10 Lakh, five seats, a 25 s turn clock, 4 s between hands and 5–40 ms of
latency on every socket message. It is a **test harness, not the game**: no
PostgreSQL or Redis (a wallet is its seat's stack while seated, and chips are
conserved exactly), six variations played with the classic ranking (Muflis
reversed; no wild cards, no FIVE_CARD), and no Force Sideshow, missile, winning
tax, consolidation, private tables, emojis or unfunded grace. The real server's
rules are the only rules. `bankroll.dev_replenish` is allowed here only: a broke
bot comes back as a fresh account (`botplay-000017-g1`) with a new welcome.

With `BOT_SEED` fixed the personalities, session plans and every decision stream
are the same from run to run. The simulation runs on the real clock, so its
hand-for-hand replay is proven on a fake clock in the tests
(`TestTheSameSeedPlaysTheSameHands`).

## Troubleshooting

- **The server is not up.** At start the fleet waits (`waiting for the game
  server`); later, logins and connections back off and retry. Nothing exits.
- **`account disabled: this bot cannot play`** — the server's `users.is_active`
  is false for that account (CLAUDE.md §7.2). The bot rests four times as long and
  tries again each session; switch it back on with `UPDATE users SET is_active =
  TRUE WHERE …`.
- **`table_not_offered`** — the menu the fleet holds is older than the server's.
  The table is retired until the next read (a session naming a new
  `tableConfigVersion`, or a restart of the fleet); the server's catalogue itself
  changes only at a server restart.
- **`no table admits this stack; resting`** — the bot's stack fits no table's
  boot and band; it rests and tries again next session.
- **Bots alone at a table** deal no hands: after 70–130 s the bot moves on
  (`table idle, moving on`), and after a hand a table of two bots is left for a
  busier one of the same stake.
- **`kicked` with `reason: idle`** should never happen (every delay ends 3 s
  before the turn clock) — look for a blocked bot: its state, reaction and last
  error in the debug view.
- **Rate limits** (`bot_refused_total{code="rate_limited"}`): a refused move is
  decided again, a refused join retried 3–7 s later. The server's REST limits do
  not apply over loopback with no `X-Real-IP`; off-host, through nginx, logins are
  60 a minute per IP.
- **`session replaced`** — two processes share device ids: give the second its
  own `BOT_START_INDEX` range.
- **`state (unexpected transition)`** WARN — a lifecycle path the table does not
  list; harmless, but worth a report.

## Production notes

- **Runs on the game host over loopback** (`http://127.0.0.1:3000`): no nginx, no
  TLS, no edge filter between the fleet and the game — hundreds of sockets from one
  address through the public endpoint is the shape a DDoS filter drops (it did, on
  9 Sep 2026, to the load generator). Set `SERVER_URL` only for a fleet that
  genuinely runs off-host.
- **Bankroll: the bots obey the wallet.** They sit only where their stack is
  admitted, and otherwise rest. A bot whose stack no table admits — kicked for
  chips, refused a seat for them, or signing in broke — first collects the
  lobby's **6-hour bonus** (25,000 chips, `POST /api/rewards/bonus`) as any player
  may, and looks again: 25,000 sits at a 200 table, so a broke bot plays again
  within six hours. Without it (30 Sep 2026, when the game server removed the
  daily, 4-hour and milestone rewards and the fleet stopped collecting) a broke
  bot rested for good and the fleet shrank. The daily bonus and the milestone
  stay gone: their routes answer 404 and the fleet does not ask them.
  `collect_bonus` (`BOT_COLLECT_BONUS`) switches it off.
  **They never mint chips against a real server**: `dev_replenish` is refused
  outside simulation (the Node fleet's `--on-broke rotate` did mint, one welcome
  per rotation). They buy nothing and spend no hammers, missiles or diamonds.
- **New accounts.** The Go fleet's device ids (`botplay-000001` …) are not the
  Node fleet's (`botplay-v1-<n>`), so its first sign-ins create new guest accounts,
  each credited the server's `WELCOME_CHIPS` once, as any new guest is (production's
  database was rebuilt from scratch on 27 Sep 2026, so there are no Node accounts
  left there to strand). Keep `BOT_DEVICE_PREFIX` and
  `BOT_START_INDEX` fixed from then on, or every change is a new set of accounts.
- **The fleet's layout** (owner, 27 Sep 2026: "seen table 200, 50000, blind 200,
  blind 50000, variation 50000 — each of these tables should have 30-50 bots
  playing"; 30 Sep 2026: "add some bots which plays blind 50000, blind 200 also",
  more of the fleet at Blind 200 and Blind 50,000 than at the other three). The unit
  names the five lobby tables and the size each keeps — a lobby table is a category
  and a boot, however many rooms of five it runs:

  ```
  BOT_LOBBY_TABLES=seen:200,seen:50000,blind:200:fleet=50-80,blind:50000:fleet=50-80,variation:50000
  BOT_FLEET_PER_TABLE=30,50
  ```

  An entry is `category:boot`, optionally followed by `:fleet=FLOOR-CEILING`, that
  table's own floor and ceiling of the fleet's bots — the game server's
  `LOBBY_TABLES` option style (`blind:5000:max=…`). `fleet=` is the only option; a
  table named without it keeps `BOT_FLEET_PER_TABLE`'s; a ceiling of 0 is none, as
  there (`fleet=0-0` takes a table out of the default size). The key stays
  `category:boot` everywhere — the tables played, the fleet's count per table, the
  debug view and the logs (no metric is labelled by table). The same entries work in `configs/bot.yaml`'s
  `lobby_tables` list (with no space after a colon: `blind:200: fleet=…` is a YAML
  mapping). Refused at start, naming the entry: an unknown option (`max=`,
  `pot=` …), an empty one (`blind:200:`), `fleet` with no range, a range that is not
  two whole numbers (`fleet=50`, `fleet=a-b`, `fleet=-5-10`, `fleet=50-80-90`), a
  floor above its ceiling (`fleet=80-50`), or `fleet=` twice; and, as before, a key
  that is not `category:boot`, a category not played, or a table listed twice
  (`blind:200` beside `blind:200:fleet=50-80`).

  A table under its OWN floor is chosen before any other; a bot takes its place
  atomically before it asks for the seat (`Fleet.ClaimTable`, against that table's
  own ceiling), so bots choosing at once never pass a ceiling; a table holding its
  own ceiling takes no more, and a bot with nowhere under a ceiling rests ("every
  table holds its share of the fleet"). Past the floors (190 in all) the fleet
  leans to the tables it is thinnest at (the occupancy weight), so the other three
  climb towards their 50 before the blind tables climb far past theirs. **450 bots** (`BOT_COUNT`; 320 until 30
  Sep 2026, when the ceilings were 5 × 50): a bot sits about 62% of the time
  (sessions of 20–120 minutes, rests of 5–45 — 320 sat about 200 at once), so about
  280 sit at once: the floors take 190, the other three tables fill towards their
  50, and the blind tables hold some 65 each, mid-way up 50–80 as 200 of 320 sat
  mid-way up 30–50. At 400 bots (~250 seated) every table would hold about 50 and
  the blind tables no more than the rest; 500 would fill every ceiling (310) and
  rest the spare. Measured locally, 27 Sep 2026, under the old layout: 205 seated —
  45, 40, 48, 33, 39. `BOT_BOOTS_TO_SIT=20` lets a 10 Lakh account sit at 50,000.
  **The 50,000 tables thin over time**: a bot there that loses drops below 20 boots
  and plays 200 instead, and bots mint nothing — the only chips entering the fleet
  are welcomes — so watch the three 50,000 tables' counts. A new bot's welcome is
  the server's (the `welcome_rewards` chips row since 30 Sep 2026, seeded 5 Lakh):
  under 20 boots of 50,000, so a fresh bot plays the 200 tables, and reaches a
  50,000 table only once both 200 tables hold their ceilings (the selector then
  falls back to the cheapest tables with room) or after winning its depth.
- **The debug view is on `127.0.0.1:9102` in the unit** (metrics on 9101). Leave
  `BOT_DEBUG_SHOW_CARDS` off.
- **Size** is `BOT_COUNT` in the unit (450); with sessions of 20–120 minutes and
  rests of 5–45 not all of them are online at once. Bots 321–450 are new device
  ids, so their first sign-ins create 130 new guest accounts, each credited the
  server's welcome once. Bots and real players share
  the economy, and bots that bet on their cards win from careless play: watch the
  fleet's total chips over time.

## Measured

On 27 Sep 2026, against a local server built from `master` on `:3001`:

- **10 bots, server mode**: every bot signed in and sat at five Teen Patti tables;
  they played with varied reaction times (0.7–6.1 s), blind chaals and raises,
  shows, planned looks and folds.
- **Graceful stop** (SIGTERM mid-play): every bot finished its hand and left,
  `forced=0`, and the server was left with 0 players and 0 sockets.
- **Simulation, `BOT_SEED=12345`, run twice**: identical personalities, session
  plans and move counts — 87 moves and 19 hands in 70 s both times.

- **100 bots, server mode** (27 Sep 2026, the final build, against a local master server on :3001): all 100
  signed in and sat down within the staggered start (~2.5 min); 1,521 moves in the next 3.5 minutes, 63% of
  them blind (chaal 673 · see 295 · pack 264 · raise 175 · show 89 · sideshow 25); the server counted 96
  players at 24 tables with 19 hands in progress; **no warning or error logged**; the runner itself used
  1.5% of one core and 30 MB. With `boots_to_sit: 25` fresh 10 Lakh accounts played the 200 and 5,000 tables
  (116 of 154 seatings) and only bots that had won their depth reached the 50,000 ones. An earlier 100-bot run
  on the same server: 1,809 moves, reaction times p10 0.81 s · p50 1.06 s · p90 2.2 s · max 14 s (one
  distracted pause, still inside the 25 s clock), 2.3% of decisions a deliberate imperfection, 63 table
  moves (stop-loss 24, unsuitable stake 19, take-profit 8, short stack 7, emptying 5), 57 chat lines, the
  personalities 16–17 bots per family; every account the server marked `is_bot`, and every wallet the
  ledger purge had not touched reconciled with its ledger.
- **A server restart under 100 bots**: the 91 connected bots lost their connections at once, all 91
  reconnected (`bot_reconnect_total{result="ok"} 91`) and were seated again 6–12 s later, spread over six
  seconds rather than in one burst; nothing but the expected `connection lost` warnings. Under 10 bots the
  same restart re-seated all ten within 4–6 s.
- **Graceful stop**: SIGTERM to 100 bots — every bot finished its hand and left; 30–50 s, `forced=0`, the
  server left with 0 players and 0 sockets.
- **A table's own fleet size, simulated** (30 Sep 2026, `BOT_MODE=simulation`, `BOT_FLEET_PER_TABLE=30,50`,
  `BOT_BOOTS_TO_SIT=20`, bots started 40–250 ms apart). The simulator's menu is `seen:200`, `blind:200`,
  `blind:5000`, `variation:50000`, so the unit's own line plays three of its five tables there. **The unit's
  line, 450 bots**: every ceiling was reached within 30 s and held through the first minute — 80 at
  `blind:200`, 50 at `seen:200`, 50 at `variation:50000`, never more — and the bots with nowhere under a ceiling rested (301 `every table holds its share`
  lines); as seated bots moved on and the rested ones stayed away, the counts drifted to 60 / 46 / 40 at four
  minutes. **`seen:200,blind:200:fleet=50-80,blind:5000:fleet=50-80,variation:50000`, 220 bots** (between the
  floors' 160 and the ceilings' 260): 59–63 at `blind:200` and 63–79 at `blind:5000` against 46–50 at
  `seen:200` and 30–40 at `variation:50000` over minutes 1–4, every table at or above its own floor. Both
  runs: no error, `forced=0` at the stop. (Every bot starts a session at once in a run of minutes, so
  neither shows production's steady state of sessions and rests.)
