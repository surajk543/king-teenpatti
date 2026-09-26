// The backend's address is one build-time setting (owner, 24 Sep 2026: "this
// should be configurable"): production unless a define says otherwise (owner,
// 27 Sep 2026: "it should by default call prod api"), and every
// request the app makes hangs off it. The privacy policy is the one page that
// does not: it is the studio's own site's.
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/config/server_config.dart';
import 'package:teenpatti/net/social_sign_in.dart';
import 'package:teenpatti/state/game_state.dart';

void main() {
  test('with no define the app talks to production, and says so', () {
    // `flutter test` passes no --dart-define, so this is the compiled default.
    expect(ServerConfig.url, 'https://prod.sungamestudio.com');
    expect(ServerConfig.environment, 'production');
    expect(ServerConfig.isProduction, isTrue);
    expect(GameState.defaultServerUrl, ServerConfig.url);
    // …and signs in with Google against the production Web client.
    expect(
      SocialSignIn.serverClientId,
      '265025011940-0k4kh3ljcopn2pmkpb0q1rhbe8er8h09.apps.googleusercontent.com',
    );
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
