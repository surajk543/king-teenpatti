// What the release carries, read straight off the files the build reads
// (24 Sep 2026, owner's "fix all bugs"; release review RC-02, RC-07, RC-08).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('the version is past the last tagged release, 1.2.0+7', () {
    // flutter-client/v1.2.0 is 1.2.0+7; Play refuses a versionCode it has
    // already seen, and MIN_CLIENT_BUILD cannot tell two builds of one number
    // apart. Every release after it carries a higher build number.
    final line = RegExp(
      r'^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(_read('pubspec.yaml'));
    expect(line, isNotNull);
    final build = int.parse(line!.group(4)!);
    final name = [1, 2, 3].map((i) => int.parse(line.group(i)!)).toList();
    expect(build, greaterThanOrEqualTo(8));
    // The name moves with it: 1.2.0 is the tagged release.
    final isAfter120 =
        name[0] > 1 ||
        (name[0] == 1 && (name[1] > 2 || (name[1] == 2 && name[2] > 0)));
    expect(isAfter120, isTrue, reason: 'version name ${name.join('.')}');
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
