// No server, no toast (owner, 28 Sep 2026: "when app shows service not
// available, it shows loader screen until it gets connected").
//
// Held here: a start that cannot reach the server keeps the saved session and
// waits under the loader — it used to drop the token and sign the player out
// — and carries on the moment the server answers; a handshake with no answer
// raises the loader and never a toast, and the connect lowers it; a handshake
// the server turned DOWN is not an outage (that session could wait for ever)
// but a sign-out, as a start with such a token goes; and the veil itself —
// "Please wait..." over "Reconnecting…", above everything — replaces the
// "Service not available" toast a request that could not get through used to
// raise.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/main.dart';
import 'package:teenpatti/net/game_connection.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/widgets/game_loader.dart';

import 'app_version_test.dart' show appConfigJson;

/// A socket the test speaks for: its errors, its connects.
class _Socket extends GameConnection {
  _Socket() : super('http://127.0.0.1:9');

  final errors = StreamController<({String? code, String message})>.broadcast();
  final connected = StreamController<bool>.broadcast();
  final connects = <String>[];
  bool up = false;
  bool _open = false;

  @override
  Stream<({String? code, String message})> get onError => errors.stream;

  @override
  Stream<bool> get onConnected => connected.stream;

  @override
  bool get isConnected => up;

  @override
  bool get hasSocket => _open;

  @override
  void connect(String token) {
    connects.add(token);
    _open = true;
  }

  @override
  void disconnect() {
    _open = false;
    up = false;
  }
}

/// The server, reachable or not ([down]): GET /api/app-config and
/// /api/auth/me; everything else 404.
class _Server {
  bool down = false;

  MockClient get client => MockClient((request) async {
    if (down) throw const SocketException('Connection refused');
    switch (request.url.path) {
      case '/api/app-config':
        return http.Response(jsonEncode(appConfigJson()), 200);
      case '/api/auth/me':
        return http.Response(jsonEncode({'user': _userJson}), 200);
    }
    return http.Response('{"error":"not_found"}', 404);
  });
}

const _userJson = {
  'id': 'u0',
  'provider': 'guest',
  'displayName': 'Ravi',
  'chips': 245000,
};

GameState _state(GameConnection socket) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9', connection: socket);
  debugDefaultTargetPlatformOverride = null;
  return state..lang = AppLang.english;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'token': 'saved-token'});
    PackageInfo.setMockInitialValues(
      appName: 'King Teen Patti',
      packageName: 'com.sungamestudio.kingteenpatti',
      version: '1.6.2',
      buildNumber: '15',
      buildSignature: '',
    );
  });

  testWidgets('a start that cannot reach the server keeps the session and '
      'waits under the loader, then carries on once it answers', (
    tester,
  ) async {
    final socket = _Socket();
    final state = _state(socket);
    final server = _Server()..down = true;
    unawaited(http.runWithClient(state.start, () => server.client));
    await tester.pump(const Duration(seconds: 2));
    expect(state.serviceDown, isTrue);
    expect(state.screen, Screen.splash, reason: 'waiting, not signed out');
    expect(socket.connects, isEmpty);
    expect(state.notice, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('token'), 'saved-token', reason: 'the token stays');

    // Still down at the next check: still waiting.
    await tester.pump(GameState.serviceProbeEvery);
    expect(state.serviceDown, isTrue);

    // The server is back: the next check lowers the loader and the session
    // is restored as if nothing had happened.
    server.down = false;
    await tester.pump(GameState.serviceProbeEvery);
    await tester.pump(const Duration(seconds: 2));
    expect(state.serviceDown, isFalse);
    expect(state.screen, Screen.lobby);
    expect(state.user?.displayName, 'Ravi');
    expect(socket.connects, ['saved-token']);
    state.dispose();
  });

  test('a handshake with no answer raises the loader and never a toast; the '
      'connect lowers it', () async {
    final socket = _Socket();
    final state = _state(socket);
    addTearDown(state.dispose);
    await http.runWithClient(state.start, () => _Server().client);
    expect(state.screen, Screen.lobby);
    expect(state.serviceDown, isFalse);

    socket.errors.add((
      code: GameConnection.unreachable,
      message: 'Could not reach the table: WebSocketException',
    ));
    await pumpEventQueue();
    expect(state.serviceDown, isTrue);
    expect(state.notice, isNull, reason: 'no "Service not available" toast');
    expect(state.screen, Screen.lobby, reason: 'the session is not dropped');

    socket.up = true;
    socket.connected.add(true);
    await pumpEventQueue();
    expect(state.serviceDown, isFalse);
  });

  test('a handshake the server turned down is not an outage: out to the '
      'sign-in screen, no loader and no toast', () async {
    final socket = _Socket();
    final state = _state(socket);
    addTearDown(state.dispose);
    await http.runWithClient(state.start, () => _Server().client);
    expect(state.screen, Screen.lobby);

    socket.errors.add((code: GameConnection.refused, message: 'unknown_user'));
    await pumpEventQueue();
    expect(state.serviceDown, isFalse);
    expect(state.notice, isNull);
    expect(state.screen, Screen.login);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('token'), isNull);
  });

  testWidgets('a request that could not get through raises the veil — "Please '
      'wait..." over "Reconnecting…", above everything — in place of the '
      '"Service not available" toast', (tester) async {
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _state(_Socket())..screen = Screen.login;
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
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('service-veil')), findsNothing);

    // What a failed purchase, say, used to leave as a toast.
    state.notice = 'Could not reach the server.';
    // ignore: invalid_use_of_protected_member
    state.notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.serviceDown, isTrue);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text(state.t.serviceUnavailable), findsNothing);
    final veil = find.byKey(const ValueKey('service-veil'));
    expect(veil, findsOneWidget);
    expect(
      find.descendant(of: veil, matching: find.byType(GameLoader)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: veil, matching: find.text(state.t.pleaseWait)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: veil, matching: find.text(state.t.reconnecting)),
      findsOneWidget,
    );
    // Nothing behind it can be pressed: the veil takes the tap.
    final hits = tester.hitTestOnBinding(tester.getCenter(veil)).path;
    final veilBox = tester.renderObject(
      find.descendant(of: veil, matching: find.byType(ColoredBox)).first,
    );
    expect(hits.any((e) => identical(e.target, veilBox)), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    state.dispose();
  });
}
