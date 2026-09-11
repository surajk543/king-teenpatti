import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which of the three looks the player chose — system, dark glass or light
/// glass — and how that choice survives a restart.
///
/// Kept apart from [GameState] for the same reason the consent flag is: the
/// state cannot be built in a unit test (its constructor starts Play billing),
/// and this is the one piece of theme logic worth a test — that an old
/// install's `darkMode` boolean is still honoured after the three-way setting
/// replaced it.
class ThemePreference {
  const ThemePreference._();

  /// The setting since the three-way switcher: 'system' | 'dark' | 'light'.
  static const key = 'themeMode';

  /// What the old day/night toggle wrote. Read when [key] is absent, never
  /// written again.
  static const legacyKey = 'darkMode';

  /// Dark glass is the app's home look, so it is what a fresh install opens
  /// in. An install that had already chosen with the old toggle keeps that
  /// choice; one that never touched it (no boolean saved) gets the default.
  static const fallback = ThemeMode.dark;

  static ThemeMode read(SharedPreferences prefs) {
    switch (prefs.getString(key)) {
      case 'system':
        return ThemeMode.system;
      case 'dark':
        return ThemeMode.dark;
      case 'light':
        return ThemeMode.light;
    }
    return switch (prefs.getBool(legacyKey)) {
      true => ThemeMode.dark,
      false => ThemeMode.light,
      null => fallback,
    };
  }

  static String encode(ThemeMode mode) => switch (mode) {
    ThemeMode.system => 'system',
    ThemeMode.dark => 'dark',
    ThemeMode.light => 'light',
  };

  static Future<void> write(ThemeMode mode, [SharedPreferences? prefs]) async {
    prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(key, encode(mode));
  }
}
