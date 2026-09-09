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
| Play app-signing SHA-1 | Play Console → Test and release → **App signing** |

**Register both SHA-1s.** The debug one makes sign-in work on the emulator and
on any `flutter build apk --debug` you install by hand. The Play one is the
only fingerprint an installed-from-Play build has — Play re-signs your upload,
so the upload key's fingerprint is not what reaches Google at runtime. Omitting
it is the single most common reason a login that worked in testing fails the
moment it ships.

---

## 1. Google

In the Google Cloud console, on the project you want the game under:

1. **APIs & Services → OAuth consent screen** — set it up (External), add your
   own account as a test user until it is published.
2. **Credentials → Create credentials → OAuth client ID → Android.** Package
   name and SHA-1 as above. Do this **twice**, once per SHA-1.
3. **Credentials → Create credentials → OAuth client ID → Web application.**
   This one you never use directly in the app; you copy its client id.

The Web client id is what both remaining steps want. It is what makes Google
return an `idToken` at all — with only the Android clients the sign-in
succeeds and hands back a credential the server cannot verify.

- App, at build time: `--dart-define=GOOGLE_SERVER_CLIENT_ID=<web client id>`
- Server, in `go-server/.env`: `GOOGLE_CLIENT_IDS=<web client id>`

They must be the same string. The server checks the token's `aud` against that
list, and a mismatch is rejected as `Wrong recipient`.

## 2. Facebook

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

## One thing to fix before this ships

The privacy policy and the Play **Data safety** form currently both state that
the app collects no email address. Google and Facebook sign-in return one, and
the server stores it. Both have to be updated in the same release that turns
these on, or the listing is inaccurate.

- `go-server/public/privacy/index.html`
- `docs/play-store/content-rating-and-data-safety.md`
