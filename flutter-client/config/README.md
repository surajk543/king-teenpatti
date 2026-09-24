# Build-time environments

One file per backend the app can be built against, passed with
`--dart-define-from-file`:

```bash
flutter build appbundle --release --dart-define-from-file=config/production.json   # the Play build — prod.sungamestudio.com
flutter build apk --debug          --dart-define-from-file=config/preprod.json      # preprod.sungamestudio.com (also the default with no define)
flutter build apk --debug          --dart-define-from-file=config/local-emulator.json   # a server on this machine, from the emulator
```

Keys: `SERVER_URL` (REST, Socket.IO and the served pages all hang off it — `lib/config/server_config.dart`),
`APP_ENV` (`preprod` | `production` | `local`, shown beside the version in the settings drawer unless production)
and `GOOGLE_SERVER_CLIENT_ID` (the Web client id Google sign-in needs for an idToken; a public id, not a secret).

**`SERVER_URL` and `APP_ENV` are two separate defines and nothing ties them together** — always build from one of
these files, never with a lone `--dart-define`. `--dart-define=SERVER_URL=https://prod.sungamestudio.com` on its own
makes a production build labelled "· preprod"; `APP_ENV=production` on its own hides the label on a preprod build.
The label is the only on-screen sign of which backend a build talks to.

**Production is `https://prod.sungamestudio.com`** (owner, 24 Sep 2026). It was `https://api.sungamestudio.com`
until that name stopped resolving the same day — so a build of `flutter-client/v1.2.1` or older made from
`production.json` reaches no server. `SERVER_URL` is the scheme and host with NO trailing slash:
`ServerConfig.page` joins paths as `<url>/<path>`, and `https://prod.sungamestudio.com/` would ask for `//api/…`.
`test/release_config_test.dart` pins all of it.

**Plain `http://` works in DEBUG builds only.** `usesCleartextTraffic="true"` is in
`android/app/src/debug/AndroidManifest.xml`, not the main manifest, so a release or profile build (targetSdk 36)
refuses cleartext — which is what production wants. A phone on the LAN wants `http://<lan-ip>:3000` in a DEBUG build:
copy `local-emulator.json` and change the host.

**The Play upload is the App Bundle** — `flutter build appbundle --release --dart-define-from-file=config/production.json`
(Play cuts the per-device APKs itself, with the real version code). A universal `flutter build apk --release` is fine
for a sideload. **Never distribute `--split-per-abi` APKs**: each carries the build number plus an ABI offset
(1008, 2008, 4008 for build 8), so no `MIN_CLIENT_BUILD` floor holds a phone that installed one, and Play can never
update it (its 9 is "older" than 2008). `android/app/build.gradle.kts` refuses a split-per-ABI RELEASE build
(24 Sep 2026); a throwaway test build may pass `--android-project-arg=allowSplitPerAbiRelease=true`.
