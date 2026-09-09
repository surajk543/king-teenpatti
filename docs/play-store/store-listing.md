# Play Store listing copy — King Teen Patti

Paste these into **Grow users → Store presence → Main store listing**. Character
limits are Play's, and every field below is inside them (measured, not
estimated — see the check at the bottom of this file).

---

## App name  *(30 characters)*

```
King Teen Patti
```

## Short description  *(80 characters)*

This is the line under the icon in search results. It sells the install.

```
Play Teen Patti at real tables with players across India. Free chips daily.
```

## Full description  *(4000 characters)*

```
King Teen Patti brings the card game everyone at home already knows to your
phone — the same three cards, the same boot, the same blind, the same argument
about who was bluffing.

Sit down at a table and play. There is always a game running.

REAL TABLES, REAL PLAYERS
Every table seats five and deals as soon as two players are ready. No waiting
rooms, no filling a lobby. Quick Join drops you straight into a hand.

PLAY BLIND OR PLAY SEEN
Run blind and pay half, or look at your cards and pay full. Four blind moves
before your cards turn face up. The betting ladder doubles the way it does at
home, and the app never lets you bet an amount that is not legal.

SIDESHOW
Ask the player on your right to compare cards privately. Lower hand packs.
They can refuse. Nobody else sees a thing.

THREE TABLES
Seen at a 200 boot, Blind at 200, and Blind at 5,000 for a bigger game. Chip
counts stay hidden at blind tables, so nobody plays your stack instead of your
cards.

PRIVATE TABLES
Create a table, share the code, and play only with the people you invite.

FREE CHIPS
Two lakh chips to start. Ten thousand more every four hours. Twenty-five
thousand every twenty-five hands you play. You never have to spend anything to
keep playing.

BUILT FOR INDIA
Chips shown in lakh and crore, or switch to international numbering. Play in
English, Hindi, Bengali, Gujarati or Punjabi.

CHAT AT THE TABLE
Talk to the players you are up against, in the drawer beside the felt.

TRACK YOUR GAME
Hands played, hands won, biggest pot and lifetime winnings, kept for as long as
you play.

---

IMPORTANT: King Teen Patti is a free social card game. Chips are virtual game
credits with no real-world value. They cannot be cashed out, withdrawn,
transferred or exchanged for money or anything of value. There are no cash
prizes and no payouts. Nothing you win here is money.

Practising at a social card game does not mean you will do well at gambling for
money.

Chip packs can be bought to keep playing. Buying is optional — the game is
completely playable without spending anything.

18+. Not intended for children.
```

---

## Graphics checklist

Play will not let you publish without these. Sizes are hard requirements.

| Asset | Requirement | Where it comes from |
|---|---|---|
| **App icon** | 512 × 512 PNG, 32-bit, under 1 MB | Render from `flutter-client/assets/app_icon.svg` at 512 px — the same crown-over-A♥A♠Q♥ mark the launcher icon uses |
| **Feature graphic** | 1024 × 500 PNG or JPG, no transparency | Must be made. It is shown at the top of your listing and in promotions. |
| **Phone screenshots** | 2 minimum, 8 maximum. 16:9 or 9:16, each side 320–3840 px | `adb exec-out screencap -p` on `TP_Tall`, landscape |
| **Tablet screenshots** | Optional, but Play down-ranks listings without them | `TP_Tablet` AVD |

**Suggested eight screenshots**, in this order — the first two are the only ones
most people see:

1. A live table mid-hand, pot visible, five seats filled
2. The showdown banner with fireworks and the winning hand
3. The lobby with all three table cards
4. Blind vs Seen — the action bar with the betting ladder open
5. A sideshow prompt on screen
6. The chip store
7. The chat drawer open at a table
8. The stats drawer

Take them against the bot fleet running on production, so the tables are full
and the seats have real names in them rather than three empty chairs.

---

## Other listing fields

| Field | Value |
|---|---|
| App category | Games → **Card** |
| Tags | Card, Casino *(Play may propose "Casino" — accept it; it is where Teen Patti apps sit)* |
| Contact email | `support@sungamestudio.com` — **must be a working inbox**, Play shows it publicly and users write to it |
| Website | `https://sungamestudio.com` (optional) |
| Privacy policy | `https://api.sungamestudio.com/privacy/` |

---

## Before you paste any of this

**`support@sungamestudio.com` has to exist.** It is on the public listing, it is
in the privacy policy, and it is the address account-deletion requests arrive
at. A bouncing contact address is a listing rejection.
