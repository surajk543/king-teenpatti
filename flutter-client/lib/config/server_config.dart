/// Where the app talks to — the ONE place the backend's address lives.
///
/// Every request goes to [url]: REST under `<url>/api/...`, the Socket.IO
/// handshake at `<url>/socket.io/` (websocket only), and the pages the server
/// serves beside the API ([page]). There is no second host or path setting.
///
/// It is set at BUILD time, never edited in code:
///
///     flutter build apk --dart-define-from-file=config/production.json   # the store build
///     flutter build apk --dart-define-from-file=config/preprod.json      # what the default is
///     flutter build apk --debug --dart-define=SERVER_URL=http://10.0.2.2:3000   # a local server
///
/// `config/*.json` holds one file per environment (`SERVER_URL`, `APP_ENV`,
/// and the Google server client id the sign-in needs). With no define at all
/// the app talks to PREPROD (owner, 24 Sep 2026: "change the prefix to
/// preprod … this should be configurable"), so a build nobody configured
/// can never reach the production accounts by accident — and a store build
/// MUST name production explicitly.
class ServerConfig {
  const ServerConfig._();

  /// The scheme, host and port the app is built against, with no trailing
  /// slash. Default: the preprod backend.
  static const String url = String.fromEnvironment(
    'SERVER_URL',
    defaultValue: 'https://preprod.sungamestudio.com',
  );

  /// A short name for the environment [url] points at — `preprod`,
  /// `production`, `local` — shown beside the app version in the settings
  /// drawer when it is not production, so a tester can tell which server a
  /// build talks to without reading its traffic.
  static const String environment = String.fromEnvironment(
    'APP_ENV',
    defaultValue: 'preprod',
  );

  /// Whether this build talks to the production backend.
  static bool get isProduction => environment == 'production';

  /// A page the server serves beside the API — `page('privacy/')` — on the
  /// same host the app is built against.
  static Uri page(String path) =>
      Uri.parse('$url/${path.startsWith('/') ? path.substring(1) : path}');
}
