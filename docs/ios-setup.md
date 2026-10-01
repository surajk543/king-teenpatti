# Running King Teen Patti on iOS

The Flutter client builds for iOS as of this commit. Everything that can be
done from Linux is done and committed; this is the rest, which needs a Mac.

Nothing here has been compiled or run — there is no macOS or Xcode on the
development box. Treat the first `flutter run` as the real test, not a
formality.

---

## 1. What is already in the repo

| | |
|---|---|
| `flutter-client/ios/` | the Xcode project, generated with Flutter 3.44 and then edited (below) |
| Bundle identifier | `com.sungamestudio.kingteenpatti` — the same string as Android's `applicationId`, in all three configurations |
| Display name | **King Teen Patti** (`CFBundleDisplayName`) |
| Orientation | landscape only, both ways up, iPhone and iPad (requirement 23) |
| Status bar | hidden from launch, matching Android's immersive-sticky |
| App icon | every size in `AppIcon.appiconset`, rendered from `assets/app_icon.svg`, alpha stripped because Apple rejects an icon that carries one |
| Launch screen | the app mark centred and "powered by sungamestudio.com" at the foot, on `#FAF7F0` / `#0B0B0B` — the same two colours and the same layout as `drawable/launch_background.xml` |
| Cleartext for local dev | `NSAllowsLocalNetworking`, the narrow equivalent of Android's `usesCleartextTraffic` |
| Google sign-in hooks | `GIDClientID` and the URL scheme, both fed from `ios/Flutter/*.xcconfig` |
| Sign in with Apple | the button on the sign-in screen (iOS only), `Runner/Runner.entitlements` with the capability, and the server's `apple` provider (§4) |
| App Store purchases | StoreKit 2 through `in_app_purchase`; each receipt goes to `POST /api/purchases/apple` (§5) |
| iPad | runs full screen (`UIRequiresFullScreen`): a landscape-only iPad app that allowed Split View is refused at upload |
| Export compliance | `ITSAppUsesNonExemptEncryption = false` in `Info.plist`, so App Store Connect does not ask at every upload |

Version and build number come from `pubspec.yaml` (`1.10.0+20` on 2 Oct 2026) through
`$(FLUTTER_BUILD_NAME)` / `$(FLUTTER_BUILD_NUMBER)`, exactly as on Android — do
not set them in Xcode.

## 2. First run on the Mac

```bash
git pull                   # master at or after 7294763: the production default (§3)
cd flutter-client
flutter clean && flutter pub get
flutter run                # production; generates ios/Podfile, runs pod install, builds
```

There is no `ios/Podfile` in the repo on purpose: Flutter writes one that
matches the Flutter version installed on the machine, which is safer than a
copy pinned here. Commit it once it appears, along with `Podfile.lock`.

For a device rather than the simulator, open `ios/Runner.xcworkspace` (the
**workspace**, not the project) once and set **Runner → Signing & Capabilities
→ Team**. A free Apple ID is enough to run on your own phone; the bundle id
above is already registered to nobody, so if Xcode refuses it, change it in
Xcode and change `applicationId` on Android to match, or the two stores end up
holding different apps.

Minimum iOS is **15.0** (`IPHONEOS_DEPLOYMENT_TARGET`; 13.0 until 2 Oct 2026).
StoreKit 2, which the purchases use, starts at iOS 15, and the server verifies
StoreKit 2's signed transactions and nothing older. If the Podfile Flutter
writes says less, set its `platform :ios` line to `'15.0'` as well.

## 3. Pointing at a server

**The default is production, `https://prod.sungamestudio.com`** (owner, 27 Sep
2026: "in frontend when UI is build it should by default call prod api"; it was
preprod from 24 Sep 2026, and `api.sungamestudio.com` before that). A build with
no define talks to production, is labelled production, and carries the
production Google Web client id. Name any other environment with one of the
files in `flutter-client/config/` — never with a lone `--dart-define`, which
changes the address without the label (`config/README.md`):

```bash
flutter run --dart-define-from-file=config/production.json           # production (= no define)
flutter run --dart-define-from-file=config/preprod.json              # preprod.sungamestudio.com
flutter run --dart-define-from-file=config/local-ios-simulator.json  # a server on this Mac, from the simulator
```

The Android emulator's `10.0.2.2` alias does not exist here, which is why the
simulator has a file of its own (`http://localhost:3000`). A real iPhone reaches
a server on the Mac at the Mac's LAN address: copy `local-ios-simulator.json`
and change the host. `NSAllowsLocalNetworking` covers both without weakening
anything for production traffic.

**Preprod runs an older server** (v1.2.0 on 27 Sep 2026): no Friends, no player
levels, no winning tax. The app hides what its server does not offer — the
Friends key on a 404, the level key and the tax pill with no level in the
account — so a build pointed at preprod looks as if those features were
missing. Build against production to see them.

**Building or archiving from Xcode** reads none of these files. Xcode takes the
dart-defines the last `flutter` command wrote into
`ios/Flutter/Generated.xcconfig` (git-ignored, so it is whatever this Mac last
ran), and a stale one keeps an old server address even on new code. Before
running or archiving the Runner scheme:

```bash
flutter build ios --config-only --dart-define-from-file=config/production.json
```

To see which server a build talks to, open Settings: the version line ends in
"· preprod" or "· local" off production, and in nothing on production.

## 4. Signing in: Apple and Google

Guest play works with no further setup.

### Sign in with Apple

Built on 2 Oct 2026, because App Review expects it wherever another provider's
sign-in is offered (guideline 4.8). The sign-in screen draws Apple's own button
on iOS only; a tap opens Apple's sheet, and the identity token it returns goes
to `POST /api/auth/login` as `{provider: "apple", idToken, displayName?}`. The
server checks the token's signature against Apple's public keys and its
audience against `APPLE_BUNDLE_IDS` (default: this app's bundle id), so there
is **no key or secret to create** for it.

What it needs from you:

1. **The capability on the App ID.** `Runner/Runner.entitlements` already asks
   for it. With automatic signing (Runner → Signing & Capabilities → Team),
   Xcode enables "Sign In with Apple" on the identifier by itself; check the
   capability is listed on that tab. With manual signing, tick it on the
   identifier at developer.apple.com → Identifiers.
2. **One statement on production's database**, once, before the app is
   submitted — §7 step 2. Until it is run the server answers every Apple login
   503 and says why in its log.

A person's name reaches the app once, at their first authorisation, and is sent
with that login; someone who hides it is named `Player` and five characters,
as a guest is, and can rename themselves in Settings. Apple accounts have no
photo. An Apple account and a Google account are two accounts, even for the
same person.

**Not built: token revocation on account deletion.** Apple's guideline
5.1.1(v) says an app offering Sign in with Apple "should" revoke the user's
Apple tokens when the account is deleted. In-app deletion exists and works for
Apple accounts like any other; the revoke call needs a Sign in with Apple
private key (`.p8`) on the server and is the first thing to add if App Review
asks for it.

### Google

Google needs one more OAuth client — the four Android ones and the Web one
already registered do not cover iOS (`docs/social-login-setup.md` lists them).

1. Google Cloud → **Google Auth Platform → Clients → Create client → iOS**.
2. Bundle ID: `com.sungamestudio.kingteenpatti`.
3. The client's panel shows a **Client ID** and an **iOS URL scheme** (the
   client id with its two halves swapped). Put both in
   `flutter-client/ios/Flutter/Debug.xcconfig` **and** `Release.xcconfig`:

   ```
   GOOGLE_IOS_CLIENT_ID=265025011940-xxxxxxxx.apps.googleusercontent.com
   GOOGLE_IOS_URL_SCHEME=com.googleusercontent.apps.265025011940-xxxxxxxx
   ```

4. The Web client id needs nothing more: the server checks the token's
   audience against it on both platforms, a build with no define already
   carries it, and every `config/*.json` names it
   (`265025011940-0k4kh3ljcopn2pmkpb0q1rhbe8er8h09.apps.googleusercontent.com`).

Left empty, the build still works and "Continue with Google" fails saying the
provider is unavailable, which is the truth — but **do not submit it that
way**: a reviewer who taps a button that does not work rejects the build.
Nothing needs adding to `GOOGLE_CLIENT_IDS` on the server.

## 5. The store on iOS

On since 2 Oct 2026. Every product is sold through Apple's in-app purchase,
as Apple requires of digital goods, under **the same product ids as Play**.

How a purchase travels: the player taps a pack → StoreKit's sheet → the
purchase arrives in the app as a *signed transaction* → the app posts it to
`POST /api/purchases/apple {productId, transaction}` → the server verifies
Apple's signature on it (against Apple Root CA - G3, compiled into the server;
no call to Apple and no credentials), checks it is this app's and this
product's, and banks it once under Apple's transaction id → only then does the
app *finish* the transaction with StoreKit. A purchase whose banking failed
(no network, the app killed) stays unfinished and is posted again at the start
of the next session; StoreKit will not sell the same pack again until then, so
the app says "Finishing an earlier purchase" and finishes it.

**Sandbox purchases are credited on production**, and must be: TestFlight
builds, sandbox testers and App Review all buy in Apple's sandbox, where
nothing is charged, and a reviewer whose purchase is refused rejects the
build. Only people you invite can buy that way (TestFlight testers and sandbox
accounts are yours to create). The server logs each one with
`"environment":"Sandbox"`; `APPLE_IAP_ENVIRONMENTS=Production` in the server's
`.env` turns them away, and should never be set while a build is in review.

Refunds are not handled on either store: a pack Apple refunds later stays in
the wallet.

**In-app updates** have no Apple equivalent. The server's version gate still
works (`app_versions`, the `ios` row); its Update key opens the store link that
row names, so set it once the app has an id (§7 step 6). The older
`--dart-define=APPLE_APP_ID=…` fallback still works when the row names none.

## 6. Before you start: what Apple will look at

Things that decide a review, from Apple's guidelines as understood here —
check them against the current text before relying on them:

- **Simulated gambling** (Teen Patti and poker with virtual chips): allowed,
  with the age rating's gambling questions answered truthfully, which gives the
  highest age band. Real-money gambling is a different category this app is
  not in: chips cannot be cashed out, and the app already makes every player
  confirm that before playing.
- **4.3 (spam / saturated categories)**: card and casino games are a crowded
  category and Apple sometimes rejects a new one as a duplicate. The review
  notes (§7 step 5) should say what is this game's own.
- **Everything a reviewer can tap must work**: guest play, both sign-in
  buttons, at least one purchase in the sandbox, account deletion (Settings →
  Delete my account).
- **No mention of Android or Google Play** in the app or the listing. The app
  has none on iOS screens; keep the description and screenshots free of them.
- **Chat is user-generated content**: block and report exist (the table's
  player drawer and chat drawer), which is what guideline 1.2 asks for.
- On an Individual account the store shows **your legal name** as the seller.

## 7. Releasing, step by step

The order matters: the server goes first, because an iOS build that reaches a
server without the Apple routes can neither sign in with Apple nor bank a
purchase (it keeps the purchase unfinished and retries, so nothing is lost,
but a reviewer would see a purchase that never arrives).

### Step 1 — deploy the server

Tag and deploy the server build that carries the Apple routes
(`go-server/ops/deploy.sh`, as any release). Nothing in the `.env` has to
change: the two new keys default to this app
(`APPLE_BUNDLE_IDS=com.sungamestudio.kingteenpatti`,
`APPLE_IAP_ENVIRONMENTS=Production,Sandbox`). After the restart the journal
should say `app store purchases enabled`.

### Step 2 — let the database hold Apple accounts (once)

Production's `users.provider` CHECK predates Apple, and a boot never changes a
CHECK a table already has. Until this is run the journal says
`Sign in with Apple disabled` at every start and Apple logins answer 503:

```sql
SET statement_timeout = '10s';
ALTER TABLE users DROP CONSTRAINT users_provider_check;
ALTER TABLE users ADD CONSTRAINT users_provider_check
  CHECK (provider IN ('google', 'facebook', 'guest', 'apple')) NOT VALID;
ALTER TABLE users VALIDATE CONSTRAINT users_provider_check;
```

Run it as the owner of `users` (`postgres` where DEPLOY.md §7 has been
applied, otherwise the app role), at a quiet hour — the first two statements
take a brief exclusive lock — then **restart the server**, which reads the
constraint only at boot. The journal line is then gone. A fresh database is
built with the new CHECK and needs none of this.

### Step 3 — the Mac

```bash
git pull
cd flutter-client
flutter clean && flutter pub get
flutter build ios --config-only --dart-define-from-file=config/production.json
open ios/Runner.xcworkspace
```

In Xcode: Runner → Signing & Capabilities → **Team** = your developer team,
automatic signing on; confirm **Sign In with Apple** is listed. Fill the two
Google values (§4). Run once on your own iPhone (`flutter run --release`
against production) before going further — this project has never been
compiled for iOS, so expect the first build to need a fix or two (a Podfile
`platform` line, a plugin's minimum version). Commit `ios/Podfile` and
`Podfile.lock` once they exist.

### Step 4 — App Store Connect: agreements and the app record

1. **Business → Agreements, Tax and Banking**: accept the **Paid Apps**
   agreement and complete the tax and bank forms. In-app purchases do not load,
   even in the sandbox, until it is active.
2. **Apps → + → New App**: iOS; name `King Teen Patti` (Apple may say it is
   taken — a suffix is fine, the name on the phone stays `CFBundleDisplayName`);
   bundle id `com.sungamestudio.kingteenpatti`; any SKU, e.g. `kingteenpatti`.
3. Note the **Apple ID** of the app (App Information → General): it is the
   `<id>` of steps 6 and 8.

### Step 5 — App Store Connect: products, privacy, rating, listing

**In-app purchases** (Monetization → In-App Purchases): create each of the 27
products as a **Consumable** with **exactly** these ids — the server refuses
any other — a display name and description, the price nearest the figure, and
a review screenshot (the store shelf showing that pack will do):

| | Product ids (₹ list price) |
|---|---|
| Chips | `chips_a_99` (99) · `chips_b_199` (199) · `chips_c_399` (399) · `chips_d_999` (999) · `chips_e_1499` (1,499) · `chips_f_2999` (2,999) · `chips_g_4999` (4,999) · `chips_h_6900` (6,900) · `chips_i_7900` (7,900) |
| Diamonds | `diamonds_1_49` (49) · `diamonds_5_199` (199) · `diamonds_20_699` (699) · `diamonds_100_2999` (2,999) |
| Hammers | `hammers_20_300` (300) · `hammers_50_699` (699) · `hammers_100_1299` (1,299) · `hammers_250_2999` (2,999) |
| Premium packages | `premium_1_9999` (9,999) · `premium_2_14999` (14,999) · `premium_3_19999` (19,999) · `premium_4_29999` (29,999) |
| Badges | `badge_royal_ace_499` (500) · `badge_royal_king_999` (1,000) · `badge_royal_master_1799` (1,800) · `badge_royal_emperor_2499` (2,500) · `badge_royal_legend_3299` (3,300) · `badge_royal_king_of_kings_4499` (4,500) |

The first in-app purchases must be **submitted together with the app version**
(tick them on the version's page, "In-App Purchases and Subscriptions"). What
each id is worth is the server's (`go-server/internal/purchase/catalogue.go`,
and the `badges` table for the six badges); the store shows Apple's own price
for each, whatever it is set to.

**Sandbox tester** (Users and Access → Sandbox → Test Accounts): one account,
for buying on your own phone without being charged.

**App Privacy** — what the app collects, all *linked to the user*, none *used
for tracking* (there is no advertising and no third-party analytics):
Contact Info (name, and email address from Google or Apple sign-in) ·
Identifiers (user id, and a device id for guest accounts) · Purchases ·
User Content (chat messages, player reports) · Usage Data (gameplay
statistics). Privacy policy URL: `https://sungamestudio.com/privacy/`.

**Age rating**: answer the gambling questions as *simulated gambling,
frequent*; no real-money gambling, no contests. Say yes to user-generated
content / messaging where asked (the table chat).

**Listing**: description, keywords, support URL, the 1024×1024 icon (Xcode
takes it from the build), and screenshots — landscape, for 6.9" and 6.5"
iPhones, and for a 13" iPad because the project targets iPad too
(`TARGETED_DEVICE_FAMILY = "1,2"`; set it to `1` in Xcode to ship iPhone-only
and skip the iPad set). Take them from the iOS simulator; never reuse the
Android ones if they show an Android status bar or the Play badge.

**App Review Information**: no demo account is needed — say so: "Tap Play as
Guest; no sign-in required." In the notes: the chips are virtual, cannot be
cashed out or transferred for value, and nothing can be won; where account
deletion is (Settings → Delete my account); and what sets the game apart.

**Pricing and availability**: free; choose the countries. A few (mainland
China, South Korea among them) have their own rules for games or simulated
gambling — leave them off the first release.

### Step 6 — tell the server where the app lives

Once the app has its Apple ID:

```sql
UPDATE app_versions
   SET store_url = 'https://apps.apple.com/app/id<id>'
 WHERE platform = 'ios';
```

No restart: the version gate reads the row within 15 seconds.

### Step 7 — build, upload, test

```bash
flutter build ipa --release --dart-define-from-file=config/production.json
```

Upload `build/ios/ipa/*.ipa` with Apple's **Transporter** app (or Xcode →
Organizer → Distribute App). It appears under TestFlight after processing.
Install it through TestFlight and go through this on a real iPhone, signed in
to the sandbox account for the purchases:

1. Play as Guest → a table → a hand played to its end.
2. Sign out → Continue with Apple → a new account, named as your Apple ID →
   sign out and in again → the same account.
3. Continue with Google → your Google account, the same one as on Android.
4. Shop → buy the smallest chip pack → the chips arrive and the celebration
   shows; buy it again at once (it must sell twice).
5. Buy a pack at a table → the seat's chips rise.
6. Start a purchase, switch to airplane mode before it completes or kill the
   app on the confirmation → reopen → the chips arrive without paying again.
7. Buy a badge, a diamond pack, a hammer pack.
8. Settings → Delete my account.
9. Lock the phone at a table for two minutes → unlock → back at the table.

On the server, `journalctl -u gameplay | grep 'app store purchase banked'`
shows each purchase with `"environment":"Sandbox"`.

### Step 8 — submit

Attach the build to the version, tick the in-app purchases, **Add for
Review**. Reviews of a first submission with purchases commonly come back
with questions; answer in the Resolution Center rather than resubmitting
unchanged.

After release, raising `app_versions.minimum_version` for `ios` holds old
builds on the update screen exactly as on Android — only ever to a version
the App Store is already serving.

The privacy policy at `https://sungamestudio.com/privacy/` describes Google
sign-in and what is stored; add Sign in with Apple and App Store purchases to
it before submitting, since the label above has to agree with it.
