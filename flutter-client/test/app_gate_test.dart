// The app version gate on the phone (owner, 28 Sep 2026): the app asks the
// server what this build may do BEFORE sign-in, and the answer — NORMAL,
// SOFT_UPDATE, FORCE_UPDATE or MAINTENANCE — decides where it goes. A refusal
// met later (a REST 426 / 503, the socket handshake's connect_error) comes to
// the same screens and stops the socket for good. The brief's Flutter tests
// 1–8, on GameState and the real screens.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/main.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/app_version.dart';
import 'package:teenpatti/net/game_connection.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';

import 'app_version_test.dart' show appConfigJson;
import 'table_scenes.dart';

const _play =
    'https://play.google.com/store/apps/details?id=com.sungamestudio.kingteenpatti';
const _appStore = 'https://apps.apple.com/app/id1234567890';

/// A socket that records what the app asks of it and lets the test speak for
/// the server's handshake.
class _Socket extends GameConnection {
  _Socket() : super('http://127.0.0.1:9');

  final gate = StreamController<AppGateVerdict>.broadcast();
  final session =
      StreamController<
        ({User user, GameConfig? config, ResumeHint? resume})
      >.broadcast();
  final connects = <String>[];

  /// What each connect declared: (platform, version).
  final declared = <(String?, String?)>[];
  int disconnects = 0;

  @override
  Stream<AppGateVerdict> get onAppGate => gate.stream;

  @override
  Stream<({User user, GameConfig? config, ResumeHint? resume})> get onSession =>
      session.stream;

  @override
  void connect(String token) {
    connects.add(token);
    declared.add((appPlatform, appVersion));
  }

  @override
  void disconnect() => disconnects++;
}

/// The server: GET /api/app-config answers [config] (null: unreachable), GET
/// /api/auth/me the user (or [me] when given), everything else 404. Records
/// every request.
class _Server {
  _Server(this.config);

  Map<String, dynamic>? config;
  http.Response Function(http.Request)? me;
  final requests = <http.Request>[];

  MockClient get client => MockClient((request) async {
    requests.add(request);
    switch (request.url.path) {
      case '/api/app-config':
        final c = config;
        if (c == null) throw const SocketException('offline');
        return http.Response(jsonEncode(c), 200, request: request);
      case '/api/auth/me':
        final answer = me;
        if (answer != null) return answer(request);
        return http.Response(
          jsonEncode({'user': _userJson}),
          200,
          request: request,
        );
    }
    return http.Response('{"error":"not_found"}', 404, request: request);
  });

  Iterable<String> get paths => requests.map((r) => r.url.path);
}

const _userJson = {
  'id': 'u0',
  'provider': 'guest',
  'displayName': 'Ravi',
  'chips': 245000,
};

GameState _state(_Socket socket) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9', connection: socket);
  debugDefaultTargetPlatformOverride = null;
  return state..lang = AppLang.english;
}

void _installed(String version, String build) =>
    PackageInfo.setMockInitialValues(
      appName: 'King Teen Patti',
      packageName: 'com.sungamestudio.kingteenpatti',
      version: version,
      buildNumber: build,
      buildSignature: '',
    );

/// Starts [state] against [server] as [platform] (android by default).
Future<void> _start(
  GameState state,
  _Server server, {
  TargetPlatform platform = TargetPlatform.android,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await http.runWithClient(state.start, () => server.client);
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'token': 'saved-token'});
    _installed('1.4.2', '12');
  });

  // 1.
  test('a supported build enters the application, declaring itself', () async {
    _installed('1.6.2', '15');
    final socket = _Socket();
    final state = _state(socket);
    addTearDown(state.dispose);
    final server = _Server(appConfigJson());
    await _start(state, server);

    expect(state.screen, Screen.lobby);
    expect(state.appGate, isNull);
    expect(state.softUpdate, isNull, reason: '1.6.2 is the latest');
    final paths = server.paths.toList();
    expect(paths, contains('/api/auth/me'));
    expect(
      paths.indexOf('/api/app-config'),
      lessThan(paths.indexOf('/api/auth/me')),
      reason: 'asked before the session is restored',
    );
    final me = server.requests.firstWhere((r) => r.url.path == '/api/auth/me');
    expect(me.headers[appPlatformHeader], 'android');
    expect(me.headers[appVersionHeader], '1.6.2');
    expect(socket.connects, ['saved-token']);
    expect(socket.declared.single, ('android', '1.6.2'));
  });

  // 2, 3.
  test('a build below the minimum stands on the update screen, and never '
      'reaches sign-in, the lobby or the socket', () async {
    final socket = _Socket();
    final state = _state(socket);
    addTearDown(state.dispose);
    final server = _Server(appConfigJson(status: 'FORCE_UPDATE'));
    await _start(state, server);

    expect(state.screen, Screen.update);
    expect(state.appGate?.status, AppGateStatus.forceUpdate);
    expect(state.appGate?.storeUrl, _play);
    expect(state.appGate?.minimumVersion, SemVer.tryParse('1.5.0'));
    expect(server.paths, isNot(contains('/api/auth/me')));
    expect(socket.connects, isEmpty);
    expect(state.softUpdate, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('token'),
      'saved-token',
      reason: 'not a verdict on the account',
    );
  });

  // 4.
  test('Update now opens the Google Play listing the server named', () async {
    final state = _state(_Socket());
    addTearDown(state.dispose);
    final opened = <Uri>[];
    state.openStoreUrl = (uri) async {
      opened.add(uri);
      return true;
    };
    await _start(state, _Server(appConfigJson(status: 'FORCE_UPDATE')));
    await state.startUpdate();
    expect(opened, [Uri.parse(_play)]);
    expect(state.notice, isNull);
  });

  // 5.
  test(
    'Update now on iOS opens the App Store listing the server named',
    () async {
      final state = _state(_Socket());
      addTearDown(state.dispose);
      final opened = <Uri>[];
      state.openStoreUrl = (uri) async {
        opened.add(uri);
        return true;
      };
      final server = _Server(appConfigJson(iosMin: '1.5.0'));
      await _start(state, server, platform: TargetPlatform.iOS);
      expect(server.requests.first.headers[appPlatformHeader], 'ios');
      expect(state.screen, Screen.update);
      await state.startUpdate();
      expect(opened, [Uri.parse(_appStore)]);
    },
  );

  test('a store that cannot be opened is said, never a crash', () async {
    final state = _state(_Socket());
    addTearDown(state.dispose);
    var tries = 0;
    state.openStoreUrl = (uri) async {
      tries++;
      throw PlatformException(code: 'ACTIVITY_NOT_FOUND');
    };
    await _start(state, _Server(appConfigJson(status: 'FORCE_UPDATE')));
    await state.startUpdate();
    expect(tries, 1, reason: 'the server named a store: only that one');
    expect(state.notice, Strings(AppLang.english).updateStoreUnavailable);
    expect(state.updating, isFalse);
    expect(state.screen, Screen.update);
  });

  // 6.
  test('a soft update is offered once per announcement, and Later lets the '
      'player carry on', () async {
    _installed('1.5.0', '13'); // at the minimum, below the latest (1.6.2)
    final socket = _Socket();
    final state = _state(socket);
    addTearDown(state.dispose);
    await _start(state, _Server(appConfigJson()));
    expect(state.screen, Screen.lobby, reason: 'supported: the game is open');
    expect(state.softUpdate?.status, AppGateStatus.softUpdate);
    expect(socket.connects, ['saved-token']);

    await state.laterSoftUpdate();
    expect(state.softUpdate, isNull);
    expect(state.screen, Screen.lobby);

    // The next launch, the same announcement: not asked again.
    final again = _state(_Socket());
    addTearDown(again.dispose);
    await _start(again, _Server(appConfigJson()));
    expect(again.softUpdate, isNull);

    // Something newer announced: asked once more.
    final newer = _state(_Socket());
    addTearDown(newer.dispose);
    await _start(newer, _Server(appConfigJson(androidLatest: '1.7.0')));
    expect(newer.softUpdate?.latestVersion, SemVer.tryParse('1.7.0'));
  });

  // 7.
  test('maintenance stands on its own screen with the server\'s message, and '
      'Try again takes the player back once it is over', () async {
    _installed('1.6.2', '15');
    final socket = _Socket();
    final state = _state(socket);
    addTearDown(state.dispose);
    final server = _Server(
      appConfigJson(
        status: 'MAINTENANCE',
        androidStatus: 'MAINTENANCE',
        message: 'Back at 14:00 IST',
      ),
    );
    await _start(state, server);
    expect(state.screen, Screen.maintenance);
    expect(state.appGate?.status, AppGateStatus.maintenance);
    expect(state.appGate?.message, 'Back at 14:00 IST');
    expect(socket.connects, isEmpty);

    // Still closed: the screen stays.
    await http.runWithClient(state.retryAppGate, () => server.client);
    expect(state.screen, Screen.maintenance);

    // Unreachable: the screen stays and says so.
    server.config = null;
    await http.runWithClient(state.retryAppGate, () => server.client);
    expect(state.screen, Screen.maintenance);
    expect(state.notice, isNotNull);

    // Open again: back where the player was.
    server.config = appConfigJson();
    await http.runWithClient(() async {
      await state.retryAppGate();
      // The restored session's reads (pictures, the table catalogue…) land
      // before the state is disposed.
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }, () => server.client);
    expect(state.screen, Screen.lobby);
    expect(state.appGate, isNull);
    expect(socket.connects, ['saved-token']);
  });

  // 8.
  test('the handshake refusing the build mid-session puts up the update '
      'screen and nothing reconnects — not even the return from the '
      'background', () async {
    _installed('1.6.2', '15');
    final socket = _Socket();
    final state = _state(socket);
    addTearDown(state.dispose);
    await _start(state, _Server(appConfigJson()));
    state
      ..screen = Screen.table
      ..handleState(opponentTurnRoom());
    expect(state.room, isNotNull);
    state.handleLifecycle(AppLifecycleState.paused);

    socket.gate.add(
      AppGateVerdict.fromConnectError({
        'message': 'update_required',
        'data': {'storeUrl': _play, 'minimumVersion': '1.7.0'},
      })!,
    );
    await pumpEventQueue();

    expect(state.screen, Screen.update);
    expect(state.room, isNull);
    expect(socket.disconnects, greaterThan(0));
    expect(state.appGate?.minimumVersion, SemVer.tryParse('1.7.0'));
    state.handleLifecycle(AppLifecycleState.resumed);
    await pumpEventQueue();
    expect(socket.connects, ['saved-token'], reason: 'no reconnect');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('token'), 'saved-token');
  });

  test(
    'a REST 426 from any signed-in request comes to the same screen',
    () async {
      _installed('1.6.2', '15');
      final socket = _Socket();
      final state = _state(socket);
      addTearDown(state.dispose);
      final server = _Server(appConfigJson());
      await _start(state, server);
      expect(state.screen, Screen.lobby);

      server.me = (r) => http.Response(
        jsonEncode({
          'error': 'update_required',
          'message':
              'A new version of King Teen Patti is required to continue playing.',
          'storeUrl': _play,
          'minimumVersion': '1.7.0',
        }),
        426,
        request: r,
      );
      await http.runWithClient(state.refreshUser, () => server.client);
      expect(state.screen, Screen.update);
      expect(state.appGate?.storeUrl, _play);
      expect(socket.disconnects, greaterThan(0));

      // A 503 maintenance from a request is the maintenance screen.
      state.handleAppGate(
        AppGateVerdict.fromRefusal({
          'error': 'maintenance',
          'message': 'Back soon',
        })!,
      );
      expect(state.screen, Screen.maintenance);
      expect(state.appGate?.message, 'Back soon');
    },
  );

  test('offline at start, the app does what it always did: the server still '
      'refuses an unsupported build at every door', () async {
    final socket = _Socket();
    final state = _state(socket);
    addTearDown(state.dispose);
    await _start(state, _Server(null));
    expect(state.screen, Screen.lobby);
    expect(state.appGate, isNull);
    expect(socket.connects, ['saved-token']);
  });

  test('the legacy build floor (session:ready minClientBuild) lands on the '
      'same update screen, with the store the server named', () async {
    final socket = _Socket();
    final state = _state(socket);
    addTearDown(state.dispose);
    await _start(state, _Server(appConfigJson(androidMin: '1.0.0')));
    expect(state.screen, Screen.lobby);
    socket.session.add((
      user: User.fromJson(_userJson),
      config: GameConfig.fromJson({'maxPlayers': 5, 'minClientBuild': 14}),
      resume: null,
    ));
    await pumpEventQueue();
    expect(state.screen, Screen.update);
    expect(state.appGate?.status, AppGateStatus.forceUpdate);
    expect(state.appGate?.storeUrl, _play);
  });

  testWidgets(
    'the update screen has Update now and no Later, Skip or way past',
    (tester) async {
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = _state(_Socket())
        ..screen = Screen.update
        ..appVersion = '1.4.2 (12)';
      state.handleAppGate(
        AppGateVerdict(
          AppGateStatus.forceUpdate,
          storeUrl: _play,
          minimumVersion: SemVer.tryParse('1.5.0'),
        ),
      );
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<GameState>.value(value: state),
            ChangeNotifierProvider<FeedbackSettings>.value(
              value: FeedbackSettings(),
            ),
          ],
          child: const KingTeenPattiApp(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      final t = Strings(AppLang.english);
      expect(find.text(t.updateTitle), findsOneWidget);
      expect(find.text(t.updateNow), findsOneWidget);
      expect(find.text(t.updateVersionLine('1.4.2', '1.5.0')), findsOneWidget);
      for (final escape in [
        t.softUpdateLater,
        'Later',
        'Skip',
        'Maybe later',
        t.cancel,
      ]) {
        expect(find.text(escape), findsNothing, reason: escape);
      }
      expect(find.byType(BackButton), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      state.dispose();
    },
  );
}
