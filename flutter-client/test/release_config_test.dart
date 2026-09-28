// What the release carries, read straight off the files the build reads
// (24 Sep 2026, owner's "fix all bugs"; release review RC-02, RC-07, RC-08).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('the version is past the last tagged release, 1.6.1+15', () {
    // flutter-client/v1.6.1 is 1.6.1+15 (29 Sep 2026); 1.6.2+16 carries the
    // review's fixes: progress while an emoji is bought in the drawer, and the
    // variation keys' true height and words.
    // flutter-client/v1.6.0 is 1.6.0+14 (28 Sep 2026); 1.6.1+15 carries the
    // table fixes: raising at Variation, the picker's glass, emojis that never
    // overlap, buying an emoji in the drawer and the price in unlock dialogs.
    // flutter-client/v1.5.0 is 1.5.0+13 (28 Sep 2026); 1.6.0+14 carries the app
    // version gate (the first build that declares itself), the one-time XP
    // missions, the depth pass and the game's loader.
    // flutter-client/v1.4.0 is 1.4.0+12 (27 Sep 2026); 1.5.0+13 carries one
    // signed-in device per account and the Google photo on the picture shelf.
    // flutter-client/v1.3.0 is 1.3.0+11 (27 Sep 2026); 1.4.0+12 carried Report
    // Player, pagination and the lobby and store changes after it.
    // flutter-client/v1.2.2 is 1.2.2+9; Play refuses a versionCode it has
    // already seen, and MIN_CLIENT_BUILD cannot tell two builds of one number
    // apart. Every release after it carries a higher build number. (1.2.1+8
    // was tagged with production.json still naming api.sungamestudio.com,
    // which stopped resolving the same day, so its store build reaches no
    // server; 1.2.2+9 opens the privacy policy on prod.sungamestudio.com
    // rather than the studio's page — 24 Sep 2026.)
    final line = RegExp(
      r'^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(_read('pubspec.yaml'));
    expect(line, isNotNull);
    final build = int.parse(line!.group(4)!);
    final name = [1, 2, 3].map((i) => int.parse(line.group(i)!)).toList();
    expect(build, greaterThan(15));
    // The name moves with it: 1.2.2 is the tagged release.
    final isAfter122 =
        name[0] > 1 ||
        (name[0] == 1 && (name[1] > 2 || (name[1] == 2 && name[2] > 2)));
    expect(isAfter122, isTrue, reason: 'version name ${name.join('.')}');
  });

  test('the store build talks to production at prod.sungamestudio.com', () {
    // Owner, 24 Sep 2026: "ui should call https://prod.sungamestudio.com/ to
    // connect backend" — api.sungamestudio.com no longer resolves. The Play
    // build is `--dart-define-from-file=config/production.json`, so this file
    // IS the store build's backend: scheme and host, https, and no trailing
    // slash (ApiClient joins `<url>/api/...`, and a trailing slash would ask
    // for `//api/...`). APP_ENV says production, which hides the environment
    // label, so nothing on screen would say it was wrong. The privacy policy
    // is the studio's page, the one the Play listing names (owner, same day).
    final production =
        jsonDecode(_read('config/production.json')) as Map<String, dynamic>;
    expect(production['SERVER_URL'], 'https://prod.sungamestudio.com');
    expect(production['APP_ENV'], 'production');
    expect(production['PRIVACY_URL'], 'https://sungamestudio.com/privacy/');
    expect(
      production['GOOGLE_SERVER_CLIENT_ID'],
      '265025011940-0k4kh3ljcopn2pmkpb0q1rhbe8er8h09.apps.googleusercontent.com',
      reason:
          'the Web client of Cloud project king-teen-patti-508120 — the '
          'audience the server checks against GOOGLE_CLIENT_IDS '
          '(docs/social-login-setup.md)',
    );
    for (final file in Directory('config').listSync().whereType<File>()) {
      if (!file.path.endsWith('.json')) continue;
      final config = jsonDecode(file.readAsStringSync()) as Map;
      final url = config['SERVER_URL'] as String;
      expect(url, isNot(endsWith('/')), reason: file.path);
      expect(url, isNot(contains('api.sungamestudio.com')), reason: file.path);
      // Every build opens the one policy and can ask Google for an idToken.
      expect(
        config['PRIVACY_URL'],
        production['PRIVACY_URL'],
        reason: file.path,
      );
      expect(
        config['GOOGLE_SERVER_CLIENT_ID'],
        production['GOOGLE_SERVER_CLIENT_ID'],
        reason: file.path,
      );
    }
  });

  test('nothing of the app is backed up or carried to another phone', () {
    // SharedPreferences hold the session JWT and the guest deviceId, which is
    // a guest's whole account.
    final manifest = _read('android/app/src/main/AndroidManifest.xml');
    expect(manifest, contains('android:allowBackup="false"'));
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
    final rules = _read(
      'android/app/src/main/res/xml/data_extraction_rules.xml',
    );
    for (final section in ['cloud-backup', 'device-transfer']) {
      final body = RegExp(
        '<$section>(.*?)</$section>',
        dotAll: true,
      ).firstMatch(rules)?.group(1);
      expect(body, isNotNull, reason: section);
      for (final domain in ['sharedpref', 'file', 'root', 'database']) {
        expect(
          body,
          contains('<exclude domain="$domain" path="." />'),
          reason: '$section must exclude $domain',
        );
      }
      expect(body, isNot(contains('<include')), reason: section);
    }
  });

  test('a release build split per ABI is refused', () {
    // RC-05: --split-per-abi adds 1000/2000/4000 to the build number, which no
    // MIN_CLIENT_BUILD floor catches and Play can never update. Proved by
    // hand: `flutter build apk --release --split-per-abi` fails at Gradle's
    // configuration with this reason.
    final gradle = _read('android/app/build.gradle.kts');
    expect(gradle, contains('findProperty("split-per-abi")'));
    expect(gradle, contains('allowSplitPerAbiRelease'));
    expect(gradle, contains('throw GradleException('));
  });

  test('the biometric permissions a dependency merges in are removed', () {
    final manifest = _read('android/app/src/main/AndroidManifest.xml');
    expect(
      manifest,
      contains('xmlns:tools="http://schemas.android.com/tools"'),
    );
    for (final permission in ['USE_BIOMETRIC', 'USE_FINGERPRINT']) {
      expect(
        manifest,
        contains(
          '<uses-permission android:name="android.permission.$permission" '
          'tools:node="remove"/>',
        ),
      );
    }
  });
}
