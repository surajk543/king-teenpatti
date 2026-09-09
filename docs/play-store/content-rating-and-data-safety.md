# App content answers — content rating, data safety, target audience

Answers for the **App content** section of Play Console, derived from what the
code actually does rather than from what a card game usually does. Where I
checked something, the file is cited.

A Data safety declaration that does not match the app's behaviour is a policy
violation, not a paperwork error — so read the "why" column before ticking
anything.

---

## 1. Content rating (IARC questionnaire)

Category: **Game**

| Question | Answer | Why |
|---|---|---|
| Violence | No | |
| Sexuality / nudity | No | |
| Language | No | The app ships no profanity. Player chat is user-generated and is declared separately below. |
| Controlled substances | No | |
| Crude humour | No | |
| **Gambling — does the game simulate gambling?** | **Yes** | Teen Patti is a wagering card game. Players bet chips, there is a pot, and there is a showdown. |
| **Gambling — can players gamble with real money or win real money/prizes?** | **No** | Chips cannot be cashed out, transferred or exchanged for anything of value. There is no payout path in the code — `chip_ledger` only ever moves chips between accounts. |
| Users can interact or communicate | **Yes** | Table chat, `internal/game/chat.go` |
| Shares user's location | No | The app never requests location. Only `INTERNET` is declared in the manifest. |
| Allows purchase of digital goods | **Yes** | Nine chip packs via Google Play Billing |
| User-generated content | **Yes** | Chat messages and display names |

Answering "simulated gambling" honestly typically lands the app around
PEGI 12 / ESRB Teen / 12+ in India, sometimes higher. Let the questionnaire
produce the rating — do not aim for a number.

## 2. Target audience and content

| Field | Answer |
|---|---|
| Target age groups | **18 and over, only.** Do not tick any age band below 18. |
| Appeals to children | **No** |
| Ads | **No** — the app contains no advertising and no ad SDK |

Ticking any under-18 band on a simulated-gambling game pulls the app into
Families policy, which it cannot satisfy. This is the single easiest way to get
rejected.

## 3. Data safety

**Does your app collect or share any of the required user data types?** Yes.
**Is all user data encrypted in transit?** Yes — HTTPS/TLS to
`api.sungamestudio.com`.
**Do you provide a way to request data deletion?** Yes — see the gap in §4.

None of it is **shared** with anyone. There are no analytics, advertising,
tracking or crash-reporting SDKs in the app at all — the entire dependency list
is `flex_color_scheme`, `socket_io_client`, `http`, `provider`,
`shared_preferences`, `uuid`, `flutter_svg`, `package_info_plus`,
`in_app_purchase`, `in_app_update`.

| Data type | Collected | Shared | Required | Purpose | Why |
|---|---|---|---|---|---|
| Personal info → **Name** | Yes | No | Yes | App functionality | The display name a player types, shown at the table |
| Financial info → **Purchase history** | Yes | No | No | App functionality | The product id and Play receipt token, kept in `chip_ledger` so a receipt cannot be credited twice |
| Messages → **Other in-app messages** | Yes | No | No | App functionality | Table chat. **Do not tick "processed ephemerally"** — a 100-message room buffer outlives the request that created it, which is more than Play's definition allows. |
| App activity → **App interactions** | Yes | No | Yes | App functionality | Chip balance, hands played/won/lost, biggest pot, lifetime winnings |
| Device or other IDs → **Device or other IDs** | Yes | No | Yes | App functionality, Account management | The device id identifies a returning guest. **Do not tick "processed ephemerally"** — although the raw id is never stored (it is hashed on arrival, `SHA-256`), the hash derived from it is persisted as the account key. |

Explicitly **not** collected, and must be left unticked: location (any
precision), contacts, photos/videos, files, calendar, health, email address,
phone number, address, payment card details, advertising ID, installed apps,
web browsing history, search history.

> Payment card details never reach us. Google Play takes the payment and tells
> the server only that a purchase completed, which is why "Payment info" is not
> collected even though the app sells things.

## 4. The gap that will bounce this submission

**Play requires apps that let users create an account to offer account
deletion — both inside the app and at a publicly reachable URL that does not
require installing the app.** King Teen Patti creates an account on first
launch (a guest account keyed to the hashed device id), so this applies.

Today it has neither:

- no in-app "Delete my account" — the settings drawer has no such option
- no deletion URL — the privacy policy names an email address, and Play has
  been rejecting email-only for this since 2024

Two pieces of work close it:

1. `DELETE /api/account` on the server, plus a "Delete my account" item in the
   settings drawer with a confirmation. Deleting must keep the `chip_ledger`
   rows (tax record) while clearing the identity from `users`, or the
   reconciliation invariant in CLAUDE.md §7.3 breaks — so this is a
   pseudonymise, not a `DELETE FROM users`.
2. A page at `https://api.sungamestudio.com/account-deletion/` explaining what
   is deleted, what is kept and why, and how to request it without the app.

Neither is large. Ask and I will write both.

## 5. Other App content declarations

| Declaration | Answer |
|---|---|
| Privacy policy URL | `https://api.sungamestudio.com/privacy/` |
| App access | All functionality available without special access — but **give Play the licence-tester account anyway**, since a reviewer who cannot get past the login sees nothing |
| News app | No |
| COVID-19 contact tracing | No |
| Data safety | §3 above |
| Government app | No |
| Financial features | **No** — declare no financial features. Selling virtual chips is not a financial product; there is no lending, investment, insurance or money transfer. |
| Health | No |
