// Which menu the lobby shows once the table catalogue exists (23 Sep 2026).
//
// Three sources can describe it — the phone's copy of the catalogue, the
// server's `session:ready`, and a freshly fetched catalogue — and they can
// disagree: the phone's copy can be from before the server changed its tables,
// a fetch can land after the server has moved on, and an older server has no
// catalogue at all. The rules are one pure function ([MenuPrecedence]); these
// tests hold it to every case, then hold GameState to using it, then hold the
// REST call to the answers the rules are written against.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/api_client.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/state/table_config_cache.dart';

import 'table_config_fixture.dart';

GameConfig _catalogue({String version = versionA, int pokerTurnMs = 25000}) =>
    GameConfig.fromCatalogue(
      catalogueBody(version: version, pokerTurnMs: pokerTurnMs),
    )!;

GameConfig _session({String? version = versionA, int minClientBuild = 0}) =>
    GameConfig.fromJson(
      sessionConfig(
        tableConfigVersion: version,
        minClientBuild: minClientBuild,
      ),
    );

GameState _state() {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the rules', () {
    test('an old server (no version) with nothing held: the session menu, '
        'and nothing to fetch', () {
      final session = _session(version: null);
      final d = MenuPrecedence.onSession(session: session, catalogue: null);
      expect(identical(d.config, session), isTrue);
      expect(d.refetch, isFalse);
    });

    test('an old server while a catalogue is held: still the session menu, '
        'exactly as before the catalogue, and nothing fetched', () {
      final session = _session(version: null, minClientBuild: 3);
      final d = MenuPrecedence.onSession(
        session: session,
        catalogue: _catalogue(),
      );
      expect(identical(d.config, session), isTrue);
      expect(d.config.privateTables, isEmpty);
      expect(d.refetch, isFalse);
    });

    test('the version held: the catalogue stays, with only the session\'s '
        'build floor taken', () {
      final catalogue = _catalogue();
      final d = MenuPrecedence.onSession(
        session: _session(minClientBuild: 12),
        catalogue: catalogue,
      );
      expect(d.refetch, isFalse);
      expect(d.config.tableConfigVersion, versionA);
      expect(d.config.minClientBuild, 12);
      // Still the rich menu: the templates and the per-table figures.
      expect(d.config.privateTables, hasLength(2));
      expect(d.config.tables.first.turnTimeoutMs, 25000);
      expect(identical(d.config.tables, catalogue.tables), isTrue);
    });

    test('another version: the session menu, and the catalogue fetched', () {
      final session = _session(version: versionB);
      final d = MenuPrecedence.onSession(
        session: session,
        catalogue: _catalogue(),
      );
      expect(identical(d.config, session), isTrue);
      expect(d.refetch, isTrue);
    });

    test('a version with nothing held yet: the session menu, and a fetch', () {
      final session = _session();
      final d = MenuPrecedence.onSession(session: session, catalogue: null);
      expect(identical(d.config, session), isTrue);
      expect(d.refetch, isTrue);
    });

    test('a catalogue before any session is shown, floorless', () {
      final shown = MenuPrecedence.onCatalogue(
        catalogue: _catalogue(),
        announced: null,
        minClientBuild: 0,
      );
      expect(shown?.tableConfigVersion, versionA);
      expect(shown?.minClientBuild, 0);
    });

    test('the catalogue the session named is shown, keeping its floor', () {
      final shown = MenuPrecedence.onCatalogue(
        catalogue: _catalogue(),
        announced: versionA,
        minClientBuild: 12,
      );
      expect(shown?.tableConfigVersion, versionA);
      expect(shown?.minClientBuild, 12);
      expect(shown?.privateTables, hasLength(2));
    });

    test('a late catalogue, from before the server changed its menu, is not '
        'shown', () {
      expect(
        MenuPrecedence.onCatalogue(
          catalogue: _catalogue(),
          announced: versionB,
          minClientBuild: 0,
        ),
        isNull,
      );
    });
  });

  group('GameState', () {
    test('a cold start with no copy opens on the fallback menu', () async {
      final state = _state();
      addTearDown(state.dispose);
      state.restoreCachedMenu(await SharedPreferences.getInstance());
      expect(identical(state.config, GameConfig.fallback), isTrue);
    });

    test(
      'a cold start opens on the phone\'s copy, with no build floor',
      () async {
        await TableConfigCache.write(catalogueBody(pokerTurnMs: 90000));
        final state = _state();
        addTearDown(state.dispose);
        state.restoreCachedMenu(await SharedPreferences.getInstance());
        expect(state.config.tableConfigVersion, versionA);
        expect(state.config.minClientBuild, 0);
        expect(state.lobbyEngines, [TableEngine.teenPatti, TableEngine.poker]);
        expect(state.lobbyCategoriesIn(TableEngine.teenPatti), [
          TableCategory.seen,
          TableCategory.blind,
          TableCategory.variation,
        ]);
        expect(
          state.lobbyTablesOf(TableEngine.poker).first.turnTimeoutMs,
          90000,
        );
      },
    );

    test('then a session naming the same catalogue keeps it, and takes the '
        'floor', () async {
      await TableConfigCache.write(catalogueBody());
      final state = _state();
      addTearDown(state.dispose);
      state.restoreCachedMenu(await SharedPreferences.getInstance());
      final refetch = state.handleSessionMenu(_session(minClientBuild: 4));
      expect(refetch, isFalse);
      expect(state.config.privateTables, hasLength(2));
      expect(state.config.minClientBuild, 4);
    });

    test('then a session naming another catalogue replaces the copy and asks '
        'for the new one', () async {
      await TableConfigCache.write(catalogueBody());
      final state = _state();
      addTearDown(state.dispose);
      state.restoreCachedMenu(await SharedPreferences.getInstance());
      final refetch = state.handleSessionMenu(_session(version: versionB));
      expect(refetch, isTrue);
      expect(state.config.tableConfigVersion, versionB);
      expect(state.config.privateTables, isEmpty);

      // The fetch lands with the version the session named: shown, keeping
      // the session's floor.
      state.handleSessionMenu(_session(version: versionB, minClientBuild: 5));
      state.handleCatalogue(_catalogue(version: versionB));
      expect(state.config.tableConfigVersion, versionB);
      expect(state.config.privateTables, hasLength(2));
      expect(state.config.minClientBuild, 5);
    });

    test(
      'then an old server\'s session is the menu, as before the catalogue',
      () async {
        await TableConfigCache.write(catalogueBody());
        final state = _state();
        addTearDown(state.dispose);
        state.restoreCachedMenu(await SharedPreferences.getInstance());
        final session = _session(version: null);
        expect(state.handleSessionMenu(session), isFalse);
        expect(identical(state.config, session), isTrue);
      },
    );

    test('a late catalogue is held but not shown, and is used without a '
        'fetch once a session names it', () {
      final state = _state();
      addTearDown(state.dispose);
      final sessionB = _session(version: versionB);
      state.handleSessionMenu(sessionB);
      state.handleCatalogue(_catalogue(version: versionA));
      expect(identical(state.config, sessionB), isTrue);

      // The server goes back to A (a rollback): the catalogue held is it.
      expect(state.handleSessionMenu(_session(minClientBuild: 2)), isFalse);
      expect(state.config.tableConfigVersion, versionA);
      expect(state.config.privateTables, hasLength(2));
      expect(state.config.minClientBuild, 2);
    });

    test('a session with no config keeps the menu held', () {
      final state = _state();
      addTearDown(state.dispose);
      state.handleCatalogue(_catalogue());
      final before = state.config;
      expect(state.handleSessionMenu(null), isFalse);
      expect(identical(state.config, before), isTrue);
    });

    test('a new menu without the open category or engine closes it, '
        'whichever source brought the menu', () {
      final state = _state();
      addTearDown(state.dispose);
      state.handleCatalogue(_catalogue());
      state.openLobbyCategory(TableCategory.variation);
      expect(state.lobbyCategory, TableCategory.variation);

      // A catalogue that dropped variation: back to Teen Patti's categories.
      state.handleCatalogue(
        GameConfig.fromCatalogue(
          catalogueBody(version: versionB, withVariation: false),
        )!,
      );
      expect(state.lobbyCategory, isNull);
      expect(state.lobbyEngine, TableEngine.teenPatti);

      // And a session whose menu has no poker: back to the front.
      state.openLobbyCategory(TableCategory.texasHoldem);
      expect(state.lobbyEngine, TableEngine.poker);
      expect(state.lobbyCategory, TableCategory.texasHoldem);
      state.handleSessionMenu(
        GameConfig.fromJson(
          sessionConfig(
            tableConfigVersion: null,
            tables: [
              {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
            ],
          ),
        ),
      );
      expect(state.lobbyCategory, isNull);
      expect(state.lobbyEngine, isNull);
    });
  });

  group('GET /api/tables', () {
    test('a catalogue comes back checked, with its raw body', () async {
      late http.Request sent;
      final api = ApiClient(
        'http://server',
        client: MockClient((request) async {
          sent = request;
          return http.Response(
            jsonEncode(catalogueBody()),
            200,
            headers: {'etag': '"$versionA"'},
          );
        }),
      );
      final answer = await api.tableConfig();
      expect(sent.url.path, '/api/tables');
      expect(sent.headers.containsKey('If-None-Match'), isFalse);
      expect(sent.headers.containsKey('Authorization'), isFalse);
      expect(answer, isA<TableConfigFresh>());
      final fresh = answer as TableConfigFresh;
      expect(fresh.body, catalogueBody());
      expect(fresh.config.tableConfigVersion, versionA);
    });

    test(
      'the version held goes as If-None-Match, and a 304 is not decoded',
      () async {
        late http.Request sent;
        final api = ApiClient(
          'http://server',
          client: MockClient((request) async {
            sent = request;
            // No body at all, as a 304 has none.
            return http.Response('', 304);
          }),
        );
        final answer = await api.tableConfig(version: versionA);
        expect(sent.headers['If-None-Match'], '"$versionA"');
        expect(answer, isA<TableConfigNotModified>());
      },
    );

    test('an older server\'s 404 is an answer, not a failure', () async {
      final api = ApiClient(
        'http://server',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'error': 'not_found', 'message': 'Not found'}),
            404,
          ),
        ),
      );
      expect(await api.tableConfig(), isA<TableConfigAbsent>());
    });

    test(
      'a 200 that is not a catalogue throws rather than being kept',
      () async {
        final api = ApiClient(
          'http://server',
          client: MockClient(
            (_) async => http.Response(
              jsonEncode(catalogueBody()..remove('privateTables')),
              200,
            ),
          ),
        );
        await expectLater(
          api.tableConfig(),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              'invalid_table_config',
            ),
          ),
        );
      },
    );

    test('any other refusal throws', () async {
      final api = ApiClient(
        'http://server',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'error': 'internal', 'message': 'boom'}),
            500,
          ),
        ),
      );
      await expectLater(api.tableConfig(), throwsA(isA<ApiException>()));
    });
  });
}
