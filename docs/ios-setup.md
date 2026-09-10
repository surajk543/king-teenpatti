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

Version and build number come from `pubspec.yaml` (`1.0.0+3`) through
`$(FLUTTER_BUILD_NAME)` / `$(FLUTTER_BUILD_NUMBER)`, exactly as on Android — do
not set them in Xcode.

## 2. First run on the Mac

```bash
git pull
cd flutter-client
flutter pub get
flutter run                # generates ios/Podfile, runs pod install, builds
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

Minimum iOS is **13.0** (`IPHONEOS_DEPLOYMENT_TARGET`). If a pod demands more,
raise it in Xcode and in the Podfile's `platform :ios` line together.

## 3. Pointing at a server

The default is production, `https://api.sungamestudio.com`, and needs nothing.

For a server running on the Mac itself, note that the Android emulator's
`10.0.2.2` alias does not exist here:

```bash
flutter run --dart-define=SERVER_URL=http://localhost:3000       # simulator
flutter run --dart-define=SERVER_URL=http://192.168.1.10:3000    # real device, Mac's LAN IP
```

`NSAllowsLocalNetworking` covers both without weakening anything for
production traffic.

## 4. Google sign-in

Guest play works with no further setup. Google needs one more OAuth client —
the four Android ones and the Web one already registered do not cover iOS
(`docs/social-login-setup.md` lists them).

1. Google Cloud → **Google Auth Platform → Clients → Create client → iOS**.
2. Bundle ID: `com.sungamestudio.kingteenpatti`.
3. The client's panel shows a **Client ID** and an **iOS URL scheme** (the
   client id with its two halves swapped). Put both in
   `flutter-client/ios/Flutter/Debug.xcconfig` **and** `Release.xcconfig`:

   ```
   GOOGLE_IOS_CLIENT_ID=265025011940-xxxxxxxx.apps.googleusercontent.com
   GOOGLE_IOS_URL_SCHEME=com.googleusercontent.apps.265025011940-xxxxxxxx
   ```

4. Build with the Web client id as before — the server checks the token's
   audience against it on both platforms, so this half does not change:

   ```bash
   flutter run --dart-define=GOOGLE_SERVER_CLIENT_ID=265025011940-0k4kh3ljcopn2pmkpb0q1rhbe8er8h09.apps.googleusercontent.com
   ```

Left empty, the build still works and "Continue with Google" fails saying the
provider is unavailable, which is the truth.

Nothing needs adding to `GOOGLE_CLIENT_IDS` on the server: it verifies the
audience, and the audience is the Web client on iOS too.

## 5. What is deliberately not on iOS yet

**The chip store is off.** `Purchases.start()` returns early on iOS. This is
not an oversight and should not be "fixed" by deleting the check: the client
sends a receipt to `POST /api/purchases/google`, the server verifies it *with
Google*, and `GameState._deliverPurchase` completes a receipt the server
refuses so it is not redelivered for ever. Wire StoreKit into that as it stands
and a player pays Apple and is credited nothing. The shelf still shows its
prices and Buy answers "the store isn't live yet".

Turning it on needs two things that do not exist: `POST /api/purchases/apple`
verifying against the App Store Server API, and products in App Store Connect
carrying the same ids as Play (`chips_a_99` … `chips_i_7900`,
`flutter-client/lib/widgets/chip_store.dart`).

**In-app updates are off**, because Apple has no equivalent of Play's in-place
update. `in_app_update` is an Android-only plugin and `AppUpdate.check()`
answers "none" on iOS without asking. The forced update still works — it is
driven by the server's `MIN_CLIENT_BUILD`, not by the store — but the button
opens the listing rather than installing, and it needs the App Store id that
Apple assigns when the app record is created:

```bash
flutter build ipa --dart-define=APPLE_APP_ID=1234567890
```

Without it `storeListingUris()` returns nothing and the screen says the update
did not finish, rather than opening a page for somebody else's app.

## 6. Releasing

Not attempted, and not close: it needs a paid Apple Developer Program
membership, an app record in App Store Connect, a privacy nutrition label, and
App Review — a separate exercise from the Play launch. When it happens:

```bash
flutter build ipa \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=<web client id> \
  --dart-define=APPLE_APP_ID=<app store id>
```

Before archiving, check that `GOOGLE_IOS_URL_SCHEME` in `Release.xcconfig` is
filled in — an empty URL scheme is the one thing here that builds cleanly and
fails only in front of a reviewer.

The privacy policy at `https://api.sungamestudio.com/privacy/` already
describes Google sign-in and what is stored; it says nothing Android-specific,
so it stands for iOS as it is.
