// The table catalogue on the wire (23 Sep 2026): `GET /api/tables` read as a
// menu, every figure a table plays by read onto its entry — and, just as
// important, `session:ready` and an older server's menu read exactly as they
// were, with every new figure absent rather than a made-up zero.
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/models/dtos.dart';

import 'table_config_fixture.dart';

void main() {
  group('a menu without the catalogue', () {
    test('reads a table entry as before, every new figure null', () {
      final table = LobbyTable.fromJson(const {
        'category': 'seen',
        'bootAmount': 200,
        'maxPot': 2000000,
        'maxBlindMoves': 4,
      });
      expect(table.category, 'seen');
      expect(table.bootAmount, 200);
      expect(table.maxPot, 2000000);
      expect(table.maxBlindMoves, 4);
      expect(table.engine, isNull);
      expect(table.key, isNull);
      expect(table.isPrivate, isNull);
      expect(table.sortOrder, isNull);
      expect(table.maxRaiseSteps, isNull);
      expect(table.maxBetRounds, isNull);
      expect(table.potLimitMultiplier, isNull);
      expect(table.turnTimeoutMs, isNull);
      expect(table.maxMissedTurns, isNull);
      expect(table.sideshowTimeoutMs, isNull);
      expect(table.sideshowMinPlayers, isNull);
      expect(table.nextHandDelayMs, isNull);
      expect(table.unfundedGraceMs, isNull);
      expect(table.missileRevealExtraMs, isNull);
      expect(table.variationSelectTimeoutMs, isNull);
      expect(table.fiveCardPickTimeoutMs, isNull);
    });

    test('a session config has no version and no private templates', () {
      final config = GameConfig.fromJson(
        sessionConfig(tableConfigVersion: null),
      );
      expect(config.tableConfigVersion, isNull);
      expect(config.privateTables, isEmpty);
      expect(config.tables, hasLength(8));
      expect(config.tables.first.turnTimeoutMs, isNull);
      expect(config.maxPlayers, 5);
      expect(config.turnTimeoutMs, 25000);
    });

    test('a session config from a catalogue server names its version', () {
      final config = GameConfig.fromJson(sessionConfig(minClientBuild: 7));
      expect(config.tableConfigVersion, versionA);
      expect(config.minClientBuild, 7);
      // session:ready never carries the templates, whatever the server.
      expect(config.privateTables, isEmpty);
    });

    test('garbage where the new keys go reads as absent, not as a crash', () {
      final table = LobbyTable.fromJson(const {
        'category': 'blind',
        'bootAmount': 5000,
        'maxPot': 0,
        'key': 7,
        'isPrivate': 'yes',
        'turnTimeoutMs': 'soon',
        'sortOrder': null,
      });
      expect(table.key, isNull);
      expect(table.isPrivate, isNull);
      expect(table.turnTimeoutMs, isNull);
      expect(table.sortOrder, isNull);
      final config = GameConfig.fromJson({
        ...sessionConfig(),
        'tableConfigVersion': '',
        'privateTables': 'none',
      });
      expect(config.tableConfigVersion, isNull);
      expect(config.privateTables, isEmpty);
    });

    test('the fallback menu is unchanged', () {
      expect(GameConfig.fallback.tableConfigVersion, isNull);
      expect(GameConfig.fallback.privateTables, isEmpty);
      expect(GameConfig.fallback.tables, hasLength(3));
    });
  });

  group('a catalogue body', () {
    test('parses whole: every session key, every figure, the templates', () {
      final config = GameConfig.fromCatalogue(catalogueBody());
      expect(config, isNotNull);
      config!;
      expect(config.tableConfigVersion, versionA);
      expect(config.maxPlayers, 5);
      expect(config.minPlayers, 2);
      expect(config.bootAmount, 200);
      expect(config.turnTimeoutMs, 25000);
      expect(config.sideshowTimeoutMs, 6000);
      expect(config.categories, contains('omaha'));
      expect(config.stakes, [200, 5000, 50000, 1000000]);
      expect(config.entryCapMaxChips, 500000);
      expect(config.privateBoot, 200);
      expect(config.privateMaxPot, 500000);
      // No session-scoped figure comes from the catalogue.
      expect(config.minClientBuild, 0);
      expect(config.tables, hasLength(8));

      final seen = config.tables.first;
      expect(seen.category, 'seen');
      expect(seen.bootAmount, 200);
      expect(seen.maxPot, 2000000);
      expect(seen.key, 'seen:200');
      expect(seen.isPrivate, isFalse);
      expect(seen.sortOrder, 10);
      expect(seen.maxRaiseSteps, 2);
      expect(seen.maxBetRounds, 7);
      expect(seen.potLimitMultiplier, 1024);
      expect(seen.turnTimeoutMs, 25000);
      expect(seen.maxMissedTurns, 3);
      expect(seen.sideshowTimeoutMs, 6000);
      expect(seen.sideshowMinPlayers, 3);
      expect(seen.nextHandDelayMs, 4000);
      expect(seen.unfundedGraceMs, 30000);
      expect(seen.missileRevealExtraMs, 3000);
      expect(seen.variationSelectTimeoutMs, 0);
      expect(seen.fiveCardPickTimeoutMs, 0);

      final variation = config.tables.firstWhere(
        (t) => t.category == 'variation',
      );
      expect(variation.variationSelectTimeoutMs, 10000);
      expect(variation.fiveCardPickTimeoutMs, 8000);
      expect(variation.maxChips, 1000000000);

      final draw = config.tables.firstWhere(
        (t) => t.category == 'five_card_draw',
      );
      expect(draw.isPoker, isTrue);
      expect(draw.ante, 50000);
      expect(draw.minBuyIn, 500000);
      expect(draw.maxDiscards, 3);
      expect(draw.holeCards, 5);

      expect(config.privateTables.map((t) => t.key), [
        'private:seen',
        'private:blind',
      ]);
      expect(config.privateTables.every((t) => t.isPrivate == true), isTrue);
      expect(config.privateTables.first.maxPot, 500000);
      expect(config.privateTables.first.hasBand, isFalse);
    });

    test('reads the same menu session:ready describes', () {
      final catalogue = GameConfig.fromCatalogue(catalogueBody())!;
      final session = GameConfig.fromJson(sessionConfig());
      expect(catalogue.tableConfigVersion, session.tableConfigVersion);
      expect(catalogue.tables.length, session.tables.length);
      for (var i = 0; i < session.tables.length; i++) {
        final a = catalogue.tables[i];
        final b = session.tables[i];
        expect(
          [a.category, a.bootAmount, a.maxPot, a.maxBlindMoves, a.minChips],
          [b.category, b.bootAmount, b.maxPot, b.maxBlindMoves, b.minChips],
        );
      }
    });

    for (final (name, broken) in <(String, Map<String, dynamic> Function())>[
      ('has no version', () => catalogueBody()..remove('version')),
      ('has an empty version', () => catalogueBody()..['version'] = ''),
      ('has a numeric version', () => catalogueBody()..['version'] = 42),
      ('has no tables', () => catalogueBody()..remove('tables')),
      (
        'has tables that are not objects',
        () {
          return catalogueBody()..['tables'] = [1, 2];
        },
      ),
      ('has no privateTables', () => catalogueBody()..remove('privateTables')),
      ('has no maxPlayers', () => catalogueBody()..remove('maxPlayers')),
      ('has maxPlayers 0', () => catalogueBody()..['maxPlayers'] = 0),
      (
        'has categories that are not a list',
        () {
          return catalogueBody()..['categories'] = 'seen';
        },
      ),
    ]) {
      test('is refused when it $name', () {
        expect(GameConfig.fromCatalogue(broken()), isNull);
      });
    }

    test('is refused when it is not an object at all', () {
      expect(GameConfig.fromCatalogue(null), isNull);
      expect(GameConfig.fromCatalogue(const []), isNull);
      expect(GameConfig.fromCatalogue('menu'), isNull);
    });
  });

  group("a room's own entry", () {
    final config = GameConfig.fromCatalogue(
      catalogueBody(privateBlindMoves: 6),
    )!;

    test('a private table reads its template by category', () {
      final entry = config.entryFor(
        category: 'seen',
        bootAmount: 200,
        isPrivate: true,
      );
      expect(entry?.key, 'private:seen');
      expect(entry?.maxBlindMoves, 6);
    });

    test('a public table reads its lobby entry by category and stake', () {
      final entry = config.entryFor(
        category: 'seen',
        bootAmount: 200,
        isPrivate: false,
      );
      expect(entry?.key, 'seen:200');
      expect(entry?.maxBlindMoves, 4);
    });

    test('a private table on a server without templates reads the public '
        'entry of its pair, as before the catalogue', () {
      final session = GameConfig.fromJson(sessionConfig());
      final entry = session.entryFor(
        category: 'seen',
        bootAmount: 200,
        isPrivate: true,
      );
      expect(entry?.category, 'seen');
      expect(entry?.bootAmount, 200);
    });

    test('a table the menu does not carry has no entry', () {
      expect(
        config.entryFor(category: 'seen', bootAmount: 777, isPrivate: false),
        isNull,
      );
    });
  });

  test('copyWith changes only what it is given', () {
    final config = GameConfig.fromCatalogue(catalogueBody())!;
    final floored = config.copyWith(minClientBuild: 9);
    expect(floored.minClientBuild, 9);
    expect(floored.tableConfigVersion, versionA);
    expect(identical(floored.tables, config.tables), isTrue);
    expect(identical(floored.privateTables, config.privateTables), isTrue);
    expect(floored.maxPlayers, config.maxPlayers);
    expect(floored.entryCapCategory, config.entryCapCategory);
  });
}
