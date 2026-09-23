// The phone's copy of the table catalogue (23 Sep 2026): what a cold start
// opens the lobby on before the server has said a word. It must come back
// exactly as it went in, and anything that is not a copy this build wrote —
// corrupt, another schema, a broken body — must be thrown away rather than
// half-read, and must never replace a good copy.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/state/table_config_cache.dart';

import 'table_config_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a phone that never fetched has no copy', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(TableConfigCache.read(prefs), isNull);
  });

  test('a catalogue comes back exactly as it was kept', () async {
    final body = catalogueBody();
    final at = DateTime.fromMillisecondsSinceEpoch(1790000000000);
    expect(await TableConfigCache.write(body, now: at), isTrue);

    // A relaunched app reads the same store through a fresh instance.
    final prefs = await SharedPreferences.getInstance();
    final cached = TableConfigCache.read(prefs);
    expect(cached, isNotNull);
    expect(cached!.version, versionA);
    expect(cached.fetchedAt, 1790000000000);
    expect(cached.body, body);
    expect(cached.config.tableConfigVersion, versionA);
    expect(cached.config.tables, hasLength(8));
    expect(cached.config.privateTables, hasLength(2));
  });

  test('the envelope is the documented one', () async {
    await TableConfigCache.write(catalogueBody(), now: DateTime(2026, 9, 23));
    final prefs = await SharedPreferences.getInstance();
    final entry =
        jsonDecode(prefs.getString(TableConfigCache.key)!)
            as Map<String, dynamic>;
    expect(entry.keys.toSet(), {'schema', 'version', 'fetchedAt', 'body'});
    expect(entry['schema'], 1);
    expect(entry['version'], versionA);
    expect(entry['body'], catalogueBody());
  });

  test('keys the server added later survive the round trip', () async {
    final body = catalogueBody()..['somethingNew'] = {'a': 1};
    await TableConfigCache.write(body);
    final prefs = await SharedPreferences.getInstance();
    expect(TableConfigCache.read(prefs)!.body['somethingNew'], {'a': 1});
  });

  test('a newer catalogue replaces the older one', () async {
    await TableConfigCache.write(catalogueBody());
    await TableConfigCache.write(catalogueBody(version: versionB));
    final prefs = await SharedPreferences.getInstance();
    expect(TableConfigCache.read(prefs)!.version, versionB);
  });

  test('a broken body is never written over a good copy', () async {
    await TableConfigCache.write(catalogueBody());
    expect(await TableConfigCache.write(const {}), isFalse);
    expect(
      await TableConfigCache.write(catalogueBody()..remove('tables')),
      isFalse,
    );
    expect(
      await TableConfigCache.write(catalogueBody()..['version'] = ''),
      isFalse,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(TableConfigCache.read(prefs)!.version, versionA);
  });

  for (final (name, stored) in <(String, String)>[
    ('is not JSON', '{not json'),
    ('is not an object', '[1, 2, 3]'),
    (
      'has another schema',
      jsonEncode({
        'schema': 2,
        'version': versionA,
        'fetchedAt': 0,
        'body': catalogueBody(),
      }),
    ),
    (
      'has no schema',
      jsonEncode({
        'version': versionA,
        'fetchedAt': 0,
        'body': catalogueBody(),
      }),
    ),
    (
      'holds a body that is not a catalogue',
      jsonEncode({
        'schema': 1,
        'version': versionA,
        'fetchedAt': 0,
        'body': {'version': versionA},
      }),
    ),
    (
      'names a version its body does not',
      jsonEncode({
        'schema': 1,
        'version': versionB,
        'fetchedAt': 0,
        'body': catalogueBody(),
      }),
    ),
  ]) {
    test('an entry that $name is discarded', () async {
      SharedPreferences.setMockInitialValues({TableConfigCache.key: stored});
      final prefs = await SharedPreferences.getInstance();
      expect(TableConfigCache.read(prefs), isNull);
      // Removed, not merely skipped.
      await pumpEventQueue();
      expect(prefs.containsKey(TableConfigCache.key), isFalse);
    });
  }

  test('clear forgets the copy', () async {
    await TableConfigCache.write(catalogueBody());
    await TableConfigCache.clear();
    final prefs = await SharedPreferences.getInstance();
    expect(TableConfigCache.read(prefs), isNull);
  });
}
