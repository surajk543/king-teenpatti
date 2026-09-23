// The backend's address is one build-time setting (owner, 24 Sep 2026: "this
// should be configurable"): preprod unless a define says otherwise, and every
// URL the app uses hangs off it.
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

  test('a served page hangs off the same host, whichever way the path is written', () {
    expect(ServerConfig.page('privacy/').toString(), 'https://preprod.sungamestudio.com/privacy/');
    expect(ServerConfig.page('/privacy/').toString(), 'https://preprod.sungamestudio.com/privacy/');
  });
}
