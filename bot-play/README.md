# bot-play — the resident bot players

A Node fleet of bot players that keeps the lobby's tables populated, so a real
player who opens the app finds a game in progress rather than three empty
tables.

The bots speak **only the public protocol** — the same events the Flutter
client sends, acting only on the options the server hands them. They have no
privileged view of anyone's cards, because they are given none: the server
redacts state per viewer, and a bot is just another viewer.

```bash
cd bot-play && npm install
npm start                        # 66 per category = 198 bots
npm start -- --per-category 10   # a smaller fleet
npm run dev                      # six per category, for a laptop
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

`--per-category 66` means 66 bots in **each of the three lobby tables**
(`seen:200`, `blind:200`, `blind:5000`) — 198 in total. A table seats five, so
that fills roughly thirteen tables per category.

| Flag / env | Default | Meaning |
|---|---|---|
| `--server-url` / `SERVER_URL` | `http://127.0.0.1:3000` | Where the game server is |
| `--per-category` / `PER_CATEGORY` | 66 | Bots in *each* category, not per table |
| `--switch-every` / `SWITCH_EVERY` | 240 | Seconds between a bot considering another table at the SAME stake; 0 disables |
| `--hop-every` / `HOP_EVERY` | 1800 | Seconds between a bot considering a DIFFERENT stake; 0 disables |
| `--start-stagger-ms` / `START_STAGGER_MS` | 250 | Gap between starting each bot |
| `--on-broke` / `ON_BROKE` | `rotate` | `rotate` or `retire` — see below |
| `--quiet` / `QUIET` | off | Only log chip-minting rotations and the heartbeat |

## How they behave like people

The point is not that a bot plays well. It is that a table of five does not
read as one program with five sockets.

- **A persona per bot, derived from its index and never changing.** How often
  it folds, whether it raises or calls, how eagerly it looks at its cards, how
  much it talks, how long it takes. The same seat plays the same way tomorrow,
  which is what makes it a person rather than a dice roll.
- **Think time varies**, and a big pot slows everyone down — a real player
  thinks harder about a decision that costs more. Rarely, a bot takes a much
  longer pause: someone put their phone down. Always bounded so it never eats
  the 25-second turn clock, because a bot that times out is not "human", it is
  a bot that misses turns and gets kicked for idling.
- **Chat is grouped by what just happened** — a greeting on sitting down, a
  different register for winning big than for losing small — drawn without
  immediate repetition, and sent by only a minority of bots on any hand.
  "Big" is measured against the table's boot, so the same excitement reads
  correctly at 200 and at 5,000.
- **Some sideshow asks are simply left to expire.** A table where every ask is
  answered within two seconds is a table of programs.
- **They have faces.** Each bot wears one of the server's bundled profile
  pictures, chosen from its index so the same seat keeps the same animal every
  run. Five identical grey initials around a table is the tell that gives the
  fleet away before anyone reads a name. Set after login, because the
  server refuses a picture change at a table (409 `seated`) — and if that
  refusal comes anyway, because the fleet restarted inside the server's
  60-second reconnect grace and every seat was still held, the bot steps out
  of its restored seat once, puts the picture on, and sits back down
  (`stepOutForPicture`; the log line is `stepped out for a picture`). Until
  10 Sep 2026 that refusal was swallowed, which is how a whole fleet ran
  faceless for a day after a restart.
- **They wander between tables.** This is not decoration: the server seats a
  player at the *fullest* table with room, so without churn exactly one table
  per category ever has a free seat, and every arriving real player lands in
  the same one. Bots coming and going keep seats open across the lobby.
- **A few change stake.** `room:switch` means "another table of the same boot
  and category" — changing stake is leaving one game for another, so it is a
  leave and a fresh quick-join, as a player would do it from the lobby. Only
  the ~28% of personas with a `hopRate` ever do, and rarely: a fleet that
  redistributed itself often would leave whole stakes empty in waves. Without
  it, the three lobby tables would each hold the same fixed sixty-six accounts
  for ever.

## Running out of chips

A bot that cannot cover the boot is kicked, and something has to happen.

- **`--on-broke retire`** leaves the seat empty. Honest, visible in the log,
  and the fleet quietly shrinks over weeks.
- **`--on-broke rotate`** (default) gives that bot a fresh guest identity,
  which the server greets with `WELCOME_CHIPS`. The fleet stays at full
  strength and **this creates chips** — every rotation adds 200,000 to the
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

18 bots against a local server for three minutes, on the three-checkpoint
money model:

```
87 hands completed        chat messages   249
checkpoints written       hand_win 87 · hand_loss 87 · hand_left 72 · hand_packed 47
net movement between players           0      ← nothing created or destroyed
wallets disagreeing with the ledger    0
join refusals                          0
kicks                                  0
```

`hand_left 72` is the table switching working: a switch is a departure, and a
departure is a checkpoint.

**Chat, measured at the defaults:** 1.2 messages per table per minute — a line
roughly every fifty seconds at the table a player is sitting at. The earlier
rates gave 0.3, one line every three and a half minutes, which reads as an
empty room rather than a quiet one.

**12 invalid moves out of 213** remain, all of one kind — `no_hand`,
`not_in_hand`, `not_your_turn`, `show_unavailable`. These are lost races, not
bugs: a bot decides after thinking, and the hand can end while it thinks. A
turn-sequence guard (the same idea as the server's own `hand.turnToken`) halved
them, and the remaining window is network latency, which a real client shares.
They are **not logged** because they are not actionable, but they do still
increment `game_invalid_moves_total` — so a spike there on production is worth
distinguishing from a real client bug.

## Deploying

```bash
sudo bash ops/install.sh          # installs and starts bot-play.service
journalctl -u bot-play -f         # watch the fleet
sudo systemctl stop bot-play      # seats are released cleanly on SIGTERM
```

The unit waits for the game server rather than exiting when it is not there
yet, because a fleet that restart-loops on boot order is worse than one that
waits.

## Two things to decide before running this on production

**Bots and real players share the economy.** Chips move between them, and the
gameplay reasons above net to exactly zero — but a real player winning takes
chips out of the fleet, and losing puts them in. Over time the fleet's total
drifts, and `--on-broke rotate` refills it by minting.

**198 bots play continuously**, which is real load: roughly 39 tables dealing
hands without pause. That is small against measured capacity (production served
14,000 players at 1,835 actions/s), but it is not nothing, and it is load the
game carries even at 3am with nobody playing. `--per-category` is the dial.
