# Google and Facebook sign-in — what is built, and what is still needed

The code on both sides is finished. Guest, Google and Facebook all run through
one path: the provider hands back a credential, `POST /api/auth/login` verifies
it, and the session that comes back is the same one guest play gets. All three
buttons are on the login screen at all times.

What is **not** in the repository is the credentials, because they only exist
inside your Google Cloud and Facebook developer accounts. Until they are
supplied, tapping either provider button says so plainly ("Google sign-in is
not available in this version") instead of failing as though the server were
down.

Nothing below is a code change. It is four values, in four places.

---

## Facts you will be asked for

| | |
|---|---|
| Package / applicationId | `com.sungamestudio.kingteenpatti` |
| Debug keystore SHA-1 | `A0:54:6D:CF:0D:B9:25:B9:0E:75:0A:A7:94:A2:CC:76:7C:1F:93:EB` |
| Play app-signing SHA-1 | Play Console → **Protected with Play → Play Store protection → Manage Play app signing** |

**Register both SHA-1s.** The debug one makes sign-in work on the emulator and
on any `flutter build apk --debug` you install by hand. The Play one is the
only fingerprint an installed-from-Play build has — Play re-signs your upload,
so the upload key's fingerprint is not what reaches Google at runtime. Omitting
it is the single most common reason a login that worked in testing fails the
moment it ships.

---

## 0. What already exists

Created 10 Sep 2026 in Cloud project **King Teen Patti** (`king-teen-patti-508120`):

| Client | Type | Purpose |
|---|---|---|
| King Teen Patti — debug | Android | package + debug SHA-1, so Play Services trusts the app |
| King Teen Patti backend | Web | the `serverClientId` / `aud` — **the only id used anywhere** |

The Web client id is:

```
265025011940-0k4kh3ljcopn2pmkpb0q1rhbe8er8h09.apps.googleusercontent.com
```

It is not a secret — it ships inside the APK. The Web client's *secret* is
unused by this project and can be deleted.

Still outstanding for Google: a second Android client carrying the Play
app-signing SHA-1, and **Audience → Publish app**.

> **Where the Play fingerprint lives.** Google's support article and Google's
> own console disagree. The article says *Play Store distribution → Go to Play
> app signing*; the console's help text on the client form says *Play Store
> protection → Manage Play app signing*. Trust the console — it is the thing
> being clicked. Older accounts may still show *Test and release → App
> integrity*.

## 1. Google

In the Google Cloud console, on the project you want the game under:

1. **Google Auth Platform** (`/auth/overview`) → **GET STARTED**. This is where
   the old *APIs & Services → OAuth consent screen* went; it is now split into
   Overview / Branding / Audience / Clients / Data Access / Verification Center.
   Audience must be **External** — Internal needs a Workspace organisation and
   would reject every consumer account with `org_internal`.
2. **Data Access → ADD OR REMOVE SCOPES** — tick exactly `openid`,
   `userinfo.email`, `userinfo.profile`. All three are classed *non-sensitive*,
   and that is the entire reason this app can publish without Google's review.
   One sensitive scope turns that into mandatory verification with a demo video
   and a hard 100-user cap.
3. **Branding** — fill **Authorised domains** (`sungamestudio.com`, bare apex)
   *first*; the home-page and privacy-policy fields stay locked until it saves.
4. **Clients → CREATE CLIENT → Android.** Package name and SHA-1 as above.
   The form takes one fingerprint, so debug and Play app-signing need **two
   separate Android clients**, not two rows on one. (The old *APIs & Services →
   Credentials* page still works and lists the same objects.)
5. **Clients → CREATE CLIENT → Web application.** Leave *Authorised JavaScript
   origins* and *Authorised redirect URIs* empty — they govern browser
   redirects, and none happens here: the token is minted on-device by Play
   Services. Copy this one's client id.
6. **Audience → Publish app.** Until you do, sign-in is refused for anyone not
   listed under *Test users*, and a test-user slot is consumed permanently the
   moment it is added — removing the person does not give it back.

The Web client id is what both remaining steps want. It is what makes Google
return an `idToken` at all — with only the Android clients the sign-in
succeeds and hands back a credential the server cannot verify.

- App, at build time: `--dart-define=GOOGLE_SERVER_CLIENT_ID=<web client id>`
- Server, in `go-server/.env`: `GOOGLE_CLIENT_IDS=<web client id>`

They must be the same string. The server checks the token's `aud` against that
list, and a mismatch is rejected as `Wrong recipient`.

## 2. Facebook

> **The Facebook button is currently hidden** (owner's decision, 10 Sep 2026 —
> Google first, Facebook later). It is gated on `SocialSignIn.facebookConfigured`
> in `login_screen.dart`, so building with `--dart-define=FACEBOOK_APP_ID=…`
> brings it back and nothing else needs editing.
>
> Google is deliberately **not** gated the same way: it has shipped, so a
> forgotten build flag must produce a visible message rather than a silently
> missing sign-in option. Facebook has never shipped, so an offer that cannot
> be honoured is only a dead end. That asymmetry is intentional.

At developers.facebook.com, create an app and add the **Facebook Login**
product for Android.

- Settings → Basic → **App ID**
- Settings → Advanced → **Client token**
- Settings → Basic → **App secret** (server only — never in the app)
- Facebook Login → Settings → add the package name and the **key hashes**
  (base64 of the SHA-1, both of them — the console shows the command)

Then fill in `flutter-client/android/app/src/main/res/values/strings.xml`:

```xml
<string name="facebook_app_id">1234567890</string>
<string name="facebook_client_token">abc123…</string>
<string name="fb_login_protocol_scheme">fb1234567890</string>
```

The native SDK reads them from resources before any Dart runs, which is why
they live there and not in a `--dart-define`. The dart-define below is separate
and only tells the app the button can work.

- App, at build time: `--dart-define=FACEBOOK_APP_ID=1234567890`
- Server, in `go-server/.env`: `FACEBOOK_APP_ID=…` and `FACEBOOK_APP_SECRET=…`

---

## 3. Building with the credentials

```bash
cd flutter-client
flutter build appbundle --release \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=<web client id>.apps.googleusercontent.com \
  --dart-define=FACEBOOK_APP_ID=1234567890
```

Leave a define out and that provider's button reports itself unavailable rather
than misbehaving, so a partial rollout is safe: Google can ship before Facebook.

## 4. Restarting the server

`go-server/.env` is read **once at startup**, so the three new keys do nothing
until the unit restarts:

```bash
sudo systemctl restart gameplay
```

---

## When a Google sign-in fails

Android's Credential Manager reports several **configuration** errors as
`canceled`, *after* an account has been picked — indistinguishable from the
player changing their mind. `google_sign_in_android`'s own README says so. The
app therefore logs every failure before deciding what to do with it:

```bash
adb logcat | grep "Google sign-in"
```

| What you see | What it means |
|---|---|
| `canceled` with no account picker shown | genuinely dismissed |
| `canceled` right after picking an account | wrong SHA-1, or the wrong Cloud project |
| `clientConfigurationError` | package name or fingerprint does not match any Android client |
| `no idToken` | `GOOGLE_SERVER_CLIENT_ID` missing at build time, or not the **Web** client |
| `Wrong recipient` from our server | app id and `GOOGLE_CLIENT_IDS` differ |
| `provider_unconfigured` (503) | server env empty, or `gameplay` not restarted |

Two traps that waste the most time here: console changes take **5 minutes to a
few hours** to propagate, so an immediate retest measures nothing; and Google
sign-in cannot be tested on this machine's emulators at all — both installed
system images are `google_apis`, which has no Play Store and so no Google
account. Use a `google_apis_playstore` image or a real device.

## One thing to fix before this ships

The privacy policy and the Play **Data safety** form currently both state that
the app collects no email address. Google and Facebook sign-in return one, and
the server stores it. Both have to be updated in the same release that turns
these on, or the listing is inaccurate.

- `go-server/public/privacy/index.html`
- `docs/play-store/content-rating-and-data-safety.md`
