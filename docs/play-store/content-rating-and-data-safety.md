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

## 4. Account deletion — done

Play requires apps that let users create an account to offer deletion **both
inside the app and at a publicly reachable URL** that does not require
installing the app. King Teen Patti creates a guest account on first launch, so
this applies to every player.

> **Neither route exists any more.** The in-app option, the public page and
> `DELETE /api/account` were all removed on 10 Sep 2026 at the owner's request,
> after the Play requirement was put to them. Deletion is now by email only —
> `support@sungamestudio.com`, as the privacy policy says. **Expect this to be
> raised at review**, and be ready either to restore the feature (it is one
> commit back in history) or to argue the email route satisfies the policy.
> The `deleted_at` column and the `selectUser` filter stay, so accounts
> pseudonymised while the route existed remain hidden.

**It pseudonymises rather than deletes, and the schema forces that.**
`chip_ledger.user_id REFERENCES users (id) ON DELETE CASCADE`, so removing the
row would take the money audit with it — the one table that is append-only
precisely because it must never be lost. The row stays, emptied of everything
that identifies anyone: display name, email, both avatar fields and the
provider identity are cleared, and `deleted_at` is stamped.

Two consequences worth knowing:

- **The wallet is emptied through a ledger row**, not by writing `chips = 0`.
  `SUM(chip_ledger.delta) == users.chips` is the invariant the whole money
  model is audited against, and zeroing the column alone would break it for
  every deleted account, permanently — the append-only trigger means it could
  never be repaired in place.
- **Clearing the provider identity is what frees `(provider,
  provider_user_id)`**, so the same device signing in afterwards gets a new
  account with a fresh welcome bonus instead of being handed the deleted one
  back.

Deletion bites immediately even though a JWT lives 30 days, because every
authenticated path resolves the user through `db.selectUser`, which does not
return deleted accounts.

Answer Play's **"Do you provide a way for users to request that their data be
deleted?"** with *Yes*, and give the public URL above.

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
