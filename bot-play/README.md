# bot-play — the resident bot players

A Node fleet of bot players that keeps the lobby's tables populated, so a real
player who opens the app finds a game in progress rather than three empty
tables.

The bots speak **only the public protocol** — the same events the Flutter
client sends, acting only on the options the server hands them. They have no
privileged view of anyone's cards, because they are given none: the server
redacts state per viewer, and a bot is just another viewer. What a bot knows is
what a player knows: its own cards once it has looked, the table, and what the
others just did.

```bash
cd bot-play && npm install
npm start                        # 243 bots, 20–25 seated at each lobby table
npm start -- --per-category 10   # a smaller fleet
npm run dev                      # six per category, for a laptop
npm test                         # the decision, hand-ranking, persona and chat rules
```

## Where it connects

`SERVER_URL` defaults to **`http://127.0.0.1:3000`** — the game server's own
port, not the public HTTPS address — and that default is right in both places:

- **In production** the fleet runs *on the game host*, so loopback skips nginx,
  skips TLS termination and skips the provider's edge protection. That last one
  is not theoretical: two hundred sockets opening from one address through the
  public endpoint is exactly the shape a DDoS filter drops, and on 9 Sep 2026
  it did — repeatedly, to the load generator.
- **In development** the go-server also listens on `127.0.0.1:3000`, so the
  same default works with no configuration.

Set `SERVER_URL` only when the bots genuinely run off-host.

## The fleet

The fleet covers **four lobby tables** — `seen:200`, `blind:200`,
`blind:5000` and, since 22 Sep 2026, `variation:50000` — and holds a target
number of bots **seated at each one**:

| Lobby table | Pool | Seated |
|---|---|---|
| `seen:200` | 66 | 20–25 |
| `blind:200` | 66 | 20–25 |
| `blind:5000` | 66 | 20–25 |
| `variation:50000` | 45 | 12–18 |

The pool is how many accounts belong to that table; only the seated figure is
playing at any moment, because a bot plays a sitting and then rests (*Sittings*,
below). Twenty to twenty-five at one lobby card is four or five tables of that
stake running at once — a table seats five.

**`--online-min` / `--online-max` are counts, not percentages** (changed
22 Sep 2026). They used to be a share of the pool, and the fleet could never
reach it: a sitting ends by itself after ~20 hands and a rest averages 25
minutes, so the seated count settles at the duty cycle those two imply — about
a third — whatever share was configured. The old default asked for 75–95% of
66, i.e. 50–63 per table, and produced 19–27; the log read `19/59` every tick
with nothing actually wrong. An absolute target is one the fleet can hold, so
the number in the log is now the number at the table.

Variation is deliberately smaller. Its boot is 50,000, so a fresh bot sits
down with six boots where a 200 table gives it fifteen hundred, and a bot that
busts is replaced by a **new account carrying a new welcome bonus**
(`--on-broke`). Fewer seats there means less of the fleet exposed to that, and
richer bots reach it by hopping — `hop` only ever offers a table the bot can
afford (`--boots-to-sit`).

| Flag / env | Default | Meaning |
|---|---|---|
| `--server-url` / `SERVER_URL` | `http://127.0.0.1:3000` | Where the game server is |
| `--per-category` / `PER_CATEGORY` | 66 | Default pool for a lobby table (variation overrides it) |
| `--variation-pool` / `VARIATION_POOL` | 45 | Pool for the variation table |
| `--online-min` / `ONLINE_MIN` | 20 | Fewest bots seated at a lobby table |
| `--online-max` / `ONLINE_MAX` | 25 | Most bots seated at a lobby table |
| `--boots-to-sit` / `BOOTS_TO_SIT` | 8 | Boots a bot wants before it will hop to a table |
| `--session-hands` / `SESSION_HANDS` | 20 | Average hands in a sitting before a bot gets up |
| `--rest-minutes` / `REST_MINUTES` | 25 | Average minutes away between sittings |
| `--steady` / `STEADY` | off | Everyone online and nobody gets up — the fleet before 12 Sep 2026 |
| `--chat-scale` / `CHAT_SCALE` | 1 | Multiplies how often bots talk; 0 silences the fleet |
| `--switch-every` / `SWITCH_EVERY` | 240 | Seconds between a bot considering another table at the SAME stake; 0 disables |
| `--hop-every` / `HOP_EVERY` | 900 | Seconds between a bot considering a DIFFERENT stake; 0 disables |
| `--start-stagger-ms` / `START_STAGGER_MS` | 250 | Gap between starting each bot |
| `--on-broke` / `ON_BROKE` | `rotate` | `rotate` or `retire` — see below |
| `--quiet` / `QUIET` | off | Only log chip-minting rotations and the heartbeat |
| `--verbose` / `VERBOSE` | off | Log every bet with the bot's hand — for watching a small fleet |

## How they play

The point is not that a bot plays well. It is that a table of five does not read
as one program with five sockets — and that a player who watches a hand to the
end sees bets that made sense for the cards that turn over.

- **They judge their cards.** `src/handrank.js` is a port of the server's own
  ranking (`go-server/internal/game/handrank.go`), checked against the server's
  scores for all 22,100 possible hands with no difference. A bot places its hand
  among all the others and weighs that against how many players are still in and
  how hard they have been betting (`src/brain.js`).
- **Strong hands bet big — the high chaal.** A raise names a rung of the ladder
  the server sent: higher the stronger the hand and the more aggressive the
  player, but capped at a share of the stack, because a person bets big on a big
  hand without shoving a week's winnings on a whim. Until 12 Sep 2026 every raise
  was simply the smallest one on offer. Now and then a strong hand is slow-played
  with a plain chaal instead.
- **Middling hands stay in while the price is right**, or settle it cheaply — a
  sideshow against the neighbour, or a show when two are left. And patience runs
  out: the longer a hand drags on, the sooner a middling hand folds, compares or
  shows. Blind tables never force a showdown, and a table of middling hands
  paying chaal round after round is not how people play.
- **Weak hands fold**, unless it is a bluffer's moment. Most personas almost
  never bluff; a few do it a lot, and more often heads-up.
- **Blind is a style.** A careful player looks straight after the deal (the table
  shows their green SEEN backs); a blind-lover rides it for rounds, sometimes
  raising blind to lean on the table; anyone looks once the price climbs or
  someone starts raising.
- **At a blind table, blind is the game** (13 Sep 2026). Every bot there prefers
  blind moves: the chance of looking starts far lower and climbs slowly with each
  blind bet (`lookChanceFor` in `src/brain.js`), so a casual bot plays most of a
  hand blind, a blind-lover more, a careful one a little less. Pressure still
  counts — a bet worth a real share of the stack, or a table raising hard, makes
  anyone look sooner — and the server turns the cards up itself after the
  table's blind-move limit. Seen tables are unchanged.
- **At a variation table they call the game** (22 Sep 2026). The player to the
  dealer's left names the hand's variation inside a server-timed window, and a
  bot picks from the menu the **server** offered for that hand — never from a
  list of its own, because `FIVE_CARD` is absent when the deck could not cover
  a two-card top-up for everyone, and naming it then is refused. The persona
  leans (a loose player likes Muflis, where junk becomes gold; an aggressive
  one likes the wild-card variations) but only mildly, so a table sees all
  seven over an evening rather than one per seat. Everything is read from
  `room:state.variation`, not the `game:variation*` events — the snapshot is
  what a reconnecting client has, and what the Flutter client uses too.
- **Under 5-Card they choose which three play.** `bestThreeOf` is a port of the
  server's `EvaluateBest`, down to which of two equally strong combinations it
  names, so a bot's pick matches the `bestPossible` the server reports. Not
  always, though: a small share of picks are the wrong three, because someone
  glancing at five cards on a phone takes the obvious pair and misses the
  flush, and a fleet that found the optimum every single time would be the one
  thing at the table that never errs.
- **A big loss stings.** A bot that just lost big plays looser for a few hands,
  then settles.
- **Every move is one the server offered, and every amount a rung it sent.**
  `test/brain.test.js` checks that over thousands of random turns, together with
  "a strong hand bets and a weak one folds" and "an aggressive player chaals
  higher up the ladder than a careful one".

## How they behave like people

- **A persona per bot, derived from its index and never changing.** Its style —
  a *rock* who folds, a *shark*, a *maniac*, a *calling station*, a *casual* —
  how tight and aggressive it is, how long it stays blind, how much it bluffs,
  talks, stays and thinks. The same seat plays the same way tomorrow, which is
  what makes it a person rather than a dice roll.
- **Think time varies**, and a big pot or a big decision (a raise, a show) slows
  everyone down — a real player thinks harder about a move that costs more.
  Looking at your own cards is a glance, and another blind chaal is routine.
  Rarely, a bot takes a much longer pause:
  someone put their phone down. Always bounded so it never eats the 25-second
  turn clock, because a bot that times out is not "human", it is a bot that
  misses turns and gets kicked for idling.
- **Sittings: people come and go.** Each bot plays a sitting — its persona
  decides whether it is a regular who stays forty hands or someone who drops in
  for eight — then gets up between hands, sometimes with a "chalo bye", goes
  offline and rests for minutes to the better part of an hour. `src/fleet.js`
  keeps each category's share online drifting between the two bounds: when a
  category is short it brings a rested bot back, when it is over it asks one to
  get up after its hand, one change per category at a time, so arrivals and
  departures trickle. A bot gets up within a couple of seconds of the hand ending,
  before the next deal, so leaving never throws a boot away. The pool is the same
  fixed identities, so coming and going creates no accounts and mints no welcome
  bonuses. `--steady` turns it off.
- **Chat reacts to what happened** — a greeting on sitting down, a welcome for
  somebody who arrives, a different register for winning big than for losing
  small, a "bluff hai kya" at a big raise, a word after a sideshow, a goodbye, and
  an answer when a person says hi or mentions the bot by name (bots rarely answer
  bots, and do not welcome each other while the fleet is starting). Lines are
  drawn without immediate repetition and each bot keeps a 12-second cooldown.
  **Every table also has a budget** — one bot line every six seconds and six a
  minute at most — so a table of talkative bots never becomes a group chat. "Big"
  is measured against the table's boot, so the same excitement reads correctly at
  200 and at 5,000.
- **Some sideshow asks are simply left to expire**, and the rest are answered by
  the hand: a good hand is glad to compare. A table where every ask is answered
  within two seconds is a table of programs.
- **They have faces.** Each bot wears one of the server's profile pictures,
  chosen from its index so the same seat keeps the same animal every run. Five
  identical grey initials around a table is the tell that gives the fleet away
  before anyone reads a name.

  Only the **FREE** ones, and never a `RIVE` row (`wearableIds`): the app ships
  no Rive runtime yet, so one would show as the default face. A row's
  `currency` (COIN, DIAMOND or HAMMER) only prices PREMIUM pictures, which are never
  taken. The catalogue is rows in `profile_pictures` now, and a
  PREMIUM picture costs chips: a fleet buying its way through it would be two
  hundred accounts quietly draining the chip economy on decoration every
  restart, and the server would refuse them anyway (403 `picture_locked`). How
  many pictures are free is one `UPDATE` away from changing, so the step through
  the list is derived from the list's own length rather than hardcoded —
  `strideFor`. The old fixed stride of 7 put every bot on the SAME face the day
  the catalogue held seven free pictures, which is the opposite of the point.

  Set after login, because the
  server refuses a picture change at a table (409 `seated`) — and if that
  refusal comes anyway, because the fleet restarted inside the server's
  60-second reconnect grace and every seat was still held, the bot steps out
  of its restored seat once, puts the picture on, and sits back down
  (`stepOutForPicture`; the log line is `stepped out for a picture`). Until
  10 Sep 2026 that refusal was swallowed, which is how a whole fleet ran
  faceless for a day after a restart.
- **They wander between tables.** This is not decoration: a quick-join seats a
  player at the *fullest* table with room, so without churn exactly one table
  per category ever has a free seat, and every arriving real player lands in
  the same one. Bots coming and going keep seats open across the lobby. Since
  13 Sep 2026 `room:switch` lands on a **random** other table of the same boot
  and category rather than the fullest, so a wandering bot spreads itself
  evenly instead of piling onto the busiest table; `no_other_table` just leaves
  it where it is.
- **A few change stake.** `room:switch` means "another table of the same boot
  and category" — changing stake is leaving one game for another, so it is a
  leave and a fresh quick-join, as a player would do it from the lobby. Only
  the ~28% of personas with a `hopRate` ever do, and rarely: a fleet that
  redistributed itself often would leave whole stakes empty in waves.

## Running out of chips

A bot that can no longer cover the boot gets up at the end of the hand —
sometimes with a "chips khatam" — rather than sitting at a table it cannot be
dealt into (the server would hold the seat for its 30-second unfunded grace and
then show it out anyway). It then does what a player does in the lobby: collects
the 4-hour bonus if it is due, and sits back down if that covers the boot. If it
does not:

- **`--on-broke retire`** leaves the seat empty. Honest, visible in the log,
  and the fleet quietly shrinks over weeks.
- **`--on-broke rotate`** (default) gives that bot a fresh guest identity,
  which the server greets with `WELCOME_CHIPS`. The fleet stays at full
  strength and **this creates chips** — every rotation adds `WELCOME_CHIPS` (3 lakh in production) to the
  economy out of nothing.

The running total is printed on every rotation and in the five-minute
heartbeat, precisely so that inflation is something you watch rather than
something that happens to you. Rotated accounts carry their generation in the
device id (`botplay-v1-<n>-g<k>`), so the total can be counted in the database
after the fact:

```sql
SELECT count(*), sum(delta) FROM chip_ledger l
  JOIN users u ON u.id = l.user_id
 WHERE l.reason = 'welcome_bonus' AND u.provider_user_id IN (
   SELECT provider_user_id FROM users WHERE display_name IS NOT NULL
 );
```

## Measured

18 bots (six per category) against a local server for four and a half minutes,
with sittings shortened to about four hands and a minute's rest so that coming
and going actually happens inside the window (`--session-hands 4 --rest-minutes 1
--online-min 12 --online-max 18`):

```
hands completed               22        4.9 a minute, 11 moves a hand
moves                         241       chaal 107 · see 65 · pack 31 · raise 16 · show 13 · sideshow 9
raises by size                400 … 40,000 — eleven of the sixteen at 3,200 or more
arrivals · departures         16 · 15   hand_left 0 (nobody gets up after the deal)
timed bonuses collected       2         rotations 0
invalid moves                 0         kicks 0
wallets disagreeing with the ledger     0
chat messages                 57
```

**Hands last about as long as people play them.** The first cut of these rules
measured 21–24 moves and about two and a half minutes a hand: middling hands
kept paying chaal round after round, and every blind chaal got a full think.
Patience and quicker routine moves brought it to eleven moves, roughly fifty
seconds a hand at a busy table. The fleet before 12 Sep 2026 measured 87 hands in
three minutes — hands resolving in seconds because bots folded at random.

**No invalid moves in 241**, where the previous fleet measured 12 in 213. The same
turn-sequence guard is in place, and every move now names an amount the server
offered. Refusals that are lost races (`not_your_turn`, `no_hand`, `not_in_hand`,
`show_unavailable`) are not logged, but they still count in
`game_invalid_moves_total`, so a spike there on production is worth
distinguishing from a real client bug.

**Chat, 57 lines** — about three a table a minute, on the lively side because the
shortened sittings sent a stream of arrivals and goodbyes through the window. At
the production defaults (twenty-hand sittings, twenty-five-minute rests) arrivals
are rare and the rate is lower; the per-table budget caps it at six a minute
whatever happens, and `--chat-scale` turns it down.

## Deploying

```bash
sudo bash ops/install.sh          # installs and starts bot-play.service
journalctl -u bot-play -f         # watch the fleet
sudo systemctl stop bot-play      # seats are released cleanly on SIGTERM
```

The unit waits for the game server rather than exiting when it is not there
yet, because a fleet that restart-loops on boot order is worse than one that
waits. The new flags need no change to the unit: every default above is what
production should run. Add an `Environment=` line to `ops/bot-play.service` only
to move a dial (`STEADY=true` restores the always-on fleet).

## Two things to decide before running this on production

**Bots and real players share the economy.** Chips move between them, and the
gameplay reasons above net to exactly zero — but a real player winning takes
chips out of the fleet, and losing puts them in. Over time the fleet's total
drifts, and `--on-broke rotate` refills it by minting. Bots that now bet on
their cards win more often from careless play than the old dice-rolling fleet
did, so watch that drift after deploying.

**About 72–93 bots play at any moment** (the seated targets summed), which is real load:
roughly thirty-odd tables dealing hands without pause. That is small against
measured capacity (production served 14,000 players at 1,835 actions/s), but it
is not nothing, and it is load the game carries even at 3am with nobody playing.
`--per-category` and `--online-max` are the dials.
