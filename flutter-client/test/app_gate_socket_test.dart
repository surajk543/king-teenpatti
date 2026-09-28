// The socket side of the app version gate (owner, 28 Sep 2026), over a real
// socket_io_client against a small Engine.IO v4 / Socket.IO v5 server in the
// test: the handshake carries the build's platform and version beside the
// token; a refusal (update_required) is heard once, the socket is let go and
// NOTHING reconnects — while a network drop is still retried, as it always
// was. The brief's Flutter test 8.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/net/app_version.dart';
import 'package:teenpatti/net/game_connection.dart';
import 'package:teenpatti/state/game_state.dart';

import 'app_version_test.dart' show appConfigJson;

/// Just enough of the game server's socket: the Engine.IO open packet, and a
/// CONNECT answered by [refusal] (a CONNECT_ERROR, as the version gate's
/// handshake middleware sends it) or accepted.
class _FakeSocketServer {
  late HttpServer _http;
  int upgrades = 0;
  final connects = <Map<String, dynamic>>[];
  final _open = <WebSocket>[];
  String? refusal;

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = 400;
        await request.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(request);
      upgrades++;
      _open.add(ws);
      ws.add(
        '0{"sid":"engine-$upgrades","upgrades":[],"pingInterval":25000,'
        '"pingTimeout":20000,"maxPayload":100000}',
      );
      ws.listen((data) {
        if (data is! String || !data.startsWith('40')) return;
        final auth = data.length > 2 ? jsonDecode(data.substring(2)) : {};
        connects.add(Map<String, dynamic>.from(auth as Map));
        final refused = refusal;
        ws.add(refused != null ? '44$refused' : '40{"sid":"socket-$upgrades"}');
      }, onDone: () => _open.remove(ws));
    });
  }

  String get url => 'http://127.0.0.1:${_http.port}';

  /// The network goes: every transport closes under the client.
  Future<void> drop() async {
    for (final ws in List.of(_open)) {
      await ws.close();
    }
  }

  Future<void> close() async {
    await drop();
    await _http.close(force: true);
  }
}

const _updateRequired =
    '{"message":"update_required","data":{"message":"A new version of King Teen '
    'Patti is required to continue playing.","storeUrl":"https://play.google.com/'
    'store/apps/details?id=com.sungamestudio.kingteenpatti","minimumVersion":"1.5.0"}}';

Future<void> _until(
  bool Function() done, {
  Duration within = const Duration(seconds: 6),
}) async {
  final end = DateTime.now().add(within);
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  late _FakeSocketServer server;
  setUp(() async {
    server = _FakeSocketServer();
    await server.start();
  });
  tearDown(() => server.close());

  test('a handshake refused as too old is heard once, and the socket never '
      'knocks again', () async {
    server.refusal = _updateRequired;
    final conn = GameConnection(server.url)
      ..appPlatform = 'android'
      ..appVersion = '1.4.2';
    addTearDown(conn.dispose);
    final heard = <AppGateVerdict>[];
    final errors = <String?>[];
    conn.onAppGate.listen(heard.add);
    conn.onError.listen((e) => errors.add(e.code));

    conn.connect('a-token');
    await _until(() => heard.isNotEmpty);
    expect(heard, hasLength(1));
    expect(heard.single.status, AppGateStatus.forceUpdate);
    expect(heard.single.minimumVersion, SemVer.tryParse('1.5.0'));
    expect(errors, isEmpty, reason: 'not a network error, not a toast');
    expect(server.connects.single, {
      'token': 'a-token',
      appPlatformAuthKey: 'android',
      appVersionAuthKey: '1.4.2',
    });

    // Three seconds — several reconnect delays — and not one more knock.
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(server.upgrades, 1);
    expect(server.connects, hasLength(1));
    expect(conn.debugSocket, isNull);
  });

  test('a network drop is still retried, as it always was', () async {
    final conn = GameConnection(server.url)
      ..appPlatform = 'android'
      ..appVersion = '1.6.0';
    addTearDown(conn.dispose);
    final ups = <bool>[];
    conn.onConnected.listen(ups.add);
    conn.connect('a-token');
    await _until(() => ups.contains(true));
    expect(server.upgrades, 1);

    await server.drop();
    await _until(() => server.upgrades >= 2);
    expect(
      server.upgrades,
      greaterThanOrEqualTo(2),
      reason: 'reconnected by itself',
    );
    await _until(() => ups.where((u) => u).length >= 2);
    expect(ups.where((u) => u).length, greaterThanOrEqualTo(2));
  });

  test('the app, refused at the handshake mid-session, puts up the update '
      'screen and reconnects on nothing — not the return from the '
      'background, not a second', () async {
    SharedPreferences.setMockInitialValues({'token': 'saved-token'});
    PackageInfo.setMockInitialValues(
      appName: 'King Teen Patti',
      packageName: 'com.sungamestudio.kingteenpatti',
      version: '1.6.0',
      buildNumber: '14',
      buildSignature: '',
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final state = GameState(serverUrl: server.url)..lang = AppLang.english;
    debugDefaultTargetPlatformOverride = null;
    addTearDown(state.dispose);

    // REST answers from a stand-in (the socket is the real one): the app
    // config says NORMAL, the saved session holds.
    final rest = MockClient((r) async {
      switch (r.url.path) {
        case '/api/app-config':
          return http.Response(jsonEncode(appConfigJson()), 200);
        case '/api/auth/me':
          return http.Response(
            jsonEncode({
              'user': {'id': 'u0', 'displayName': 'Ravi', 'chips': 1000},
            }),
            200,
          );
      }
      return http.Response('{"error":"not_found"}', 404);
    });
    // The server raised the minimum between the check and the handshake.
    server.refusal = _updateRequired;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await http.runWithClient(state.start, () => rest);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    await _until(() => state.screen == Screen.update);
    expect(state.screen, Screen.update);
    expect(server.connects.single[appVersionAuthKey], '1.6.0');

    state.handleLifecycle(AppLifecycleState.paused);
    state.handleLifecycle(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(server.upgrades, 1, reason: 'one handshake, refused, and no other');
    expect(state.screen, Screen.update);
  });
}
