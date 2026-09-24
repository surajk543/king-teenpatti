// The backend's address is one build-time setting (owner, 24 Sep 2026: "this
// should be configurable"): preprod unless a define says otherwise, and every
// request the app makes hangs off it. The privacy policy is the one page that
// does not: it is the studio's own site's.
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/config/server_config.dart';
import 'package:teenpatti/state/game_state.dart';

void main() {
  test('with no define the app talks to preprod, and says so', () {
    // `flutter test` passes no --dart-define, so this is the compiled default.
    expect(ServerConfig.url, 'https://preprod.sungamestudio.com');
    expect(ServerConfig.environment, 'preprod');
    expect(ServerConfig.isProduction, isFalse);
    expect(GameState.defaultServerUrl, ServerConfig.url);
  });

  test('the privacy policy is the studio site\'s own page', () {
    // Owner, 24 Sep 2026: "Privacy: https://sungamestudio.com/privacy/" — the
    // page the Play listing and the Google consent screen name.
    expect(ServerConfig.privacyUrl, 'https://sungamestudio.com/privacy/');
    final uri = Uri.parse(ServerConfig.privacyUrl);
    expect(uri.scheme, 'https');
    expect(uri.host, 'sungamestudio.com');
  });
}
