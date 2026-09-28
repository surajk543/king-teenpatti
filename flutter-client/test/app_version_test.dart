// The app version gate's client half (owner, 28 Sep 2026): the one version
// comparison the app has, how it reads the server's answers, and how it
// declares itself. The server decides every verdict; these hold that the app
// reads them the way the server means them.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/net/api_client.dart';
import 'package:teenpatti/net/app_version.dart';

SemVer v(String s) => SemVer.tryParse(s)!;

const _play =
    'https://play.google.com/store/apps/details?id=com.sungamestudio.kingteenpatti';
const _appStore = 'https://apps.apple.com/app/id1234567890';

/// The brief's example (§16): Android and iOS configured independently.
Map<String, dynamic> appConfigJson({
  String status = 'NORMAL',
  String androidMin = '1.5.0',
  String androidLatest = '1.6.2',
  String iosMin = '1.4.0',
  String iosLatest = '1.5.0',
  String androidStatus = 'NORMAL',
  String? message,
}) => {
  'status': status,
  'platform': 'android',
  'version': null,
  'minimumVersion': androidMin,
  'latestVersion': androidLatest,
  'storeUrl': _play,
  'message': message,
  'android': {
    'status': androidStatus,
    'minimumVersion': androidMin,
    'latestVersion': androidLatest,
    'storeUrl': _play,
    'message': message,
  },
  'ios': {
    'status': 'NORMAL',
    'minimumVersion': iosMin,
    'latestVersion': iosLatest,
    'storeUrl': _appStore,
    'message': null,
  },
};

void main() {
  group('semantic versions', () {
    test('compare as numbers, never as text — the brief\'s cases', () {
      expect(v('1.4.2') < v('1.5.0'), isTrue);
      expect(v('1.5.0') == v('1.5.0'), isTrue);
      expect(v('1.5.0').compareTo(v('1.5.0')), 0);
      expect(v('1.6.0') > v('1.5.0'), isTrue);
      expect(v('1.10.0') > v('1.9.0'), isTrue);
      // Which a string comparison gets backwards.
      expect('1.10.0'.compareTo('1.9.0') < 0, isTrue);
      expect(v('2.0.0') > v('1.99.99'), isTrue);
      expect(v('1.0.10') > v('1.0.9'), isTrue);
    });

    test('read MAJOR.MINOR.PATCH, a +build suffix ignored, nothing else', () {
      expect(v('1.5.0+13'), v('1.5.0'));
      expect(v('1.5.0+build.7-rc1'), v('1.5.0'));
      expect(v('0.0.0').isZero, isTrue);
      expect(v('123456789.0.1').major, 123456789);
      for (final bad in [
        '',
        ' 1.5.0',
        '1.5.0 ',
        'v1.5.0',
        '1.5',
        '1',
        '1.5.0.0',
        '1..0',
        '1.5.0-beta',
        '1.5.0+',
        '1.5.0+a..b',
        '01.5.0',
        '1.05.0',
        '-1.5.0',
        'a.b.c',
        '1234567890.0.0',
      ]) {
        expect(SemVer.tryParse(bad), isNull, reason: bad);
      }
      expect(SemVer.tryParse(null), isNull);
    });
  });

  group('the app config', () {
    test('each platform is judged by its own row, and the stricter reading '
        'of the server\'s verdict and the app\'s own wins', () {
      final config = AppConfigInfo.fromJson(appConfigJson());
      AppGateStatus judge(String platform, String version) => evaluateAppConfig(
        config.withStatus(null),
        platform: platform,
        version: version,
      ).status;
      expect(judge('android', '1.6.2'), AppGateStatus.normal);
      expect(judge('ios', '1.5.0'), AppGateStatus.normal);
      expect(judge('android', '1.4.2'), AppGateStatus.forceUpdate);
      expect(judge('ios', '1.3.9'), AppGateStatus.forceUpdate);
      expect(judge('android', '1.5.0'), AppGateStatus.softUpdate);
      expect(judge('ios', '1.4.2'), AppGateStatus.softUpdate);
      expect(judge('android', '1.10.0'), AppGateStatus.normal);

      // The server says FORCE_UPDATE of a build its own rows would let
      // through: the stricter reading stands.
      final strict = AppConfigInfo.fromJson(
        appConfigJson(status: 'FORCE_UPDATE'),
      );
      expect(
        evaluateAppConfig(strict, platform: 'android', version: '1.6.2').status,
        AppGateStatus.forceUpdate,
      );
      // …and a NORMAL answer about a build below the minimum does not open
      // the game to it.
      expect(
        evaluateAppConfig(
          AppConfigInfo.fromJson(appConfigJson()),
          platform: 'android',
          version: '1.4.2',
        ).status,
        AppGateStatus.forceUpdate,
      );
    });

    test(
      'a verdict carries the row\'s store link, versions and the operator\'s '
      'own words — never the server\'s default sentence',
      () {
        final force = evaluateAppConfig(
          AppConfigInfo.fromJson(appConfigJson(status: 'FORCE_UPDATE')),
          platform: 'ios',
          version: '1.0.0',
        );
        expect(force.storeUrl, _appStore);
        expect(force.minimumVersion, v('1.4.0'));
        expect(force.message, isNull);

        final maintenance = evaluateAppConfig(
          AppConfigInfo.fromJson(
            appConfigJson(
              status: 'MAINTENANCE',
              androidStatus: 'MAINTENANCE',
              message: 'Back at 14:00 IST',
            ),
          ),
          platform: 'android',
          version: '1.6.2',
        );
        expect(maintenance.status, AppGateStatus.maintenance);
        expect(maintenance.message, 'Back at 14:00 IST');
      },
    );

    test('a REST refusal and a handshake refusal read as the same verdicts', () {
      final rest = AppGateVerdict.fromRefusal({
        'error': 'update_required',
        'message':
            'A new version of King Teen Patti is required to continue playing.',
        'storeUrl': _play,
        'minimumVersion': '1.6.0',
      })!;
      expect(rest.status, AppGateStatus.forceUpdate);
      expect(rest.storeUrl, _play);
      expect(rest.minimumVersion, v('1.6.0'));
      expect(rest.message, isNull, reason: 'the app says it in its own words');

      final socket = AppGateVerdict.fromConnectError({
        'message': 'maintenance',
        'data': {'message': 'Back at 14:00 IST'},
      })!;
      expect(socket.status, AppGateStatus.maintenance);
      expect(socket.message, 'Back at 14:00 IST');

      expect(AppGateVerdict.fromRefusal({'error': 'invalid_session'}), isNull);
      expect(
        AppGateVerdict.fromConnectError({'message': 'account_disabled'}),
        isNull,
      );
      expect(AppGateVerdict.fromConnectError('timeout'), isNull);
    });
  });

  group('the REST client', () {
    test('declares the platform and version on every request, both or '
        'neither, and hears the gate\'s refusals', () async {
      final seen = <http.BaseRequest>[];
      final heard = <AppGateVerdict>[];
      final api = ApiClient('http://api.test')..onAppGate = heard.add;

      MockClient server(int status, Map<String, dynamic> body) =>
          MockClient((r) async {
            seen.add(r);
            return http.Response(jsonEncode(body), status, request: r);
          });

      // Undeclared until it knows both.
      api.appPlatform = 'android';
      await http.runWithClient(
        () => api.me('tok'),
        () => server(200, {
          'user': {'id': 'u1'},
        }),
      );
      expect(seen.last.headers.containsKey(appPlatformHeader), isFalse);

      api.appVersion = '1.4.2';
      final error = await http.runWithClient(
        () =>
            api.me('tok').then<Object?>((_) => null, onError: (Object e) => e),
        () => server(426, {
          'error': 'update_required',
          'message':
              'A new version of King Teen Patti is required to continue playing.',
          'storeUrl': _play,
          'minimumVersion': '1.5.0',
        }),
      );
      expect(seen.last.headers[appPlatformHeader], 'android');
      expect(seen.last.headers[appVersionHeader], '1.4.2');
      expect(error, isA<AppGateRefusal>());
      expect((error as AppGateRefusal).code, updateRequiredCode);
      expect(error.status, 426);
      expect(heard.single.status, AppGateStatus.forceUpdate);
      expect(heard.single.storeUrl, _play);

      final down = await http.runWithClient(
        () =>
            api.me('tok').then<Object?>((_) => null, onError: (Object e) => e),
        () => server(503, {'error': 'maintenance', 'message': 'Back soon'}),
      );
      expect(
        (down as AppGateRefusal).verdict.status,
        AppGateStatus.maintenance,
      );
      expect(heard.last.message, 'Back soon');

      // Any other 503 is not the gate's.
      await http.runWithClient(
        () =>
            api.me('tok').then<Object?>((_) => null, onError: (Object e) => e),
        () => server(503, {'error': 'provider_unconfigured', 'message': 'x'}),
      );
      expect(heard, hasLength(2));
    });

    test('GET /api/app-config: public, declared, and absent on an older '
        'server', () async {
      final api =
          ApiClient(
              'http://api.test',
              client: MockClient((r) async {
                expect(r.url.path, '/api/app-config');
                expect(r.headers[appPlatformHeader], 'ios');
                expect(r.headers.containsKey('Authorization'), isFalse);
                return http.Response(
                  jsonEncode(appConfigJson(status: 'SOFT_UPDATE')),
                  200,
                );
              }),
            )
            ..appPlatform = 'ios'
            ..appVersion = '1.4.2';
      final config = (await api.appConfig())!;
      expect(config.status, AppGateStatus.softUpdate);
      expect(config.ios.storeUrl, _appStore);

      final older = ApiClient(
        'http://api.test',
        client: MockClient(
          (_) async => http.Response('{"error":"not_found"}', 404),
        ),
      );
      expect(await older.appConfig(), isNull);
    });
  });

  test('Later is remembered per announcement', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    expect(SoftUpdateMemory.shouldOffer(prefs, 'latest:1.6.2'), isTrue);
    await SoftUpdateMemory.later(prefs, 'latest:1.6.2');
    expect(SoftUpdateMemory.shouldOffer(prefs, 'latest:1.6.2'), isFalse);
    expect(SoftUpdateMemory.shouldOffer(prefs, 'latest:1.7.0'), isTrue);
  });
}

extension on AppConfigInfo {
  /// This answer with the server's own verdict taken out, so a test can
  /// read what the app makes of the rows alone.
  AppConfigInfo withStatus(AppGateStatus? status) =>
      AppConfigInfo(status: status, android: android, ios: ios);
}
