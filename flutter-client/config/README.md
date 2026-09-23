# Build-time environments

One file per backend the app can be built against, passed with
`--dart-define-from-file`:

```bash
flutter build appbundle --release --dart-define-from-file=config/production.json   # the Play build — api.sungamestudio.com
flutter build apk --debug          --dart-define-from-file=config/preprod.json      # preprod.sungamestudio.com (also the default with no define)
flutter build apk --debug          --dart-define-from-file=config/local-emulator.json   # a server on this machine, from the emulator
```

Keys: `SERVER_URL` (REST, Socket.IO and the served pages all hang off it — `lib/config/server_config.dart`),
`APP_ENV` (`preprod` | `production` | `local`, shown beside the version in the settings drawer unless production)
and `GOOGLE_SERVER_CLIENT_ID` (the Web client id Google sign-in needs for an idToken; a public id, not a secret).
A phone on the LAN wants `http://<lan-ip>:3000` — copy `local-emulator.json` and change the host.
