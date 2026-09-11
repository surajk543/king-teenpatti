// The three-way theme setting, and the old two-way toggle it replaced.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/state/theme_preference.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  test('a fresh install opens in dark glass', () async {
    expect(ThemePreference.read(await prefsWith({})), ThemeMode.dark);
  });

  test('every choice round-trips', () async {
    for (final mode in ThemeMode.values) {
      final prefs = await prefsWith({});
      await ThemePreference.write(mode, prefs);
      expect(ThemePreference.read(prefs), mode);
    }
  });

  test('an old install keeps the day or night it had chosen', () async {
    expect(
      ThemePreference.read(await prefsWith({'darkMode': false})),
      ThemeMode.light,
    );
    expect(
      ThemePreference.read(await prefsWith({'darkMode': true})),
      ThemeMode.dark,
    );
  });

  test('the new setting outranks the old toggle', () async {
    final prefs = await prefsWith({'darkMode': true, 'themeMode': 'system'});
    expect(ThemePreference.read(prefs), ThemeMode.system);
  });

  test('an unreadable value falls back rather than throwing', () async {
    expect(
      ThemePreference.read(await prefsWith({'themeMode': 'sepia'})),
      ThemeMode.dark,
    );
  });
}
