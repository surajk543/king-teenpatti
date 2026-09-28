// The app version gate's three surfaces (owner, 28 Sep 2026) — Force Update,
// Maintenance and the optional Soft Update prompt — at the tightest phone the
// app is checked on (640x360) with the text at its 1.25 ceiling, in all five
// languages and both themes: every word on screen, nothing overflowing, and
// the keys each one owes (and only those).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/net/app_version.dart';
import 'package:teenpatti/screens/update_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'script_fonts.dart';

GameState _state(AppLang lang) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..appVersion = '1.4.2 (12)';
}

Future<void> _pump(
  WidgetTester tester,
  GameState state,
  Widget child, {
  required bool dark,
}) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(
          value: FeedbackSettings(),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: withScriptFallback(
          dark ? AppTheme.dark(sound: false) : AppTheme.light(sound: false),
        ),
        builder: (context, child) => GlassBudget(child: child!),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _clear(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  state.dispose();
}

void main() {
  setUpAll(loadScriptFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final dark in [true, false]) {
    final theme = dark ? 'dark' : 'light';
    testWidgets('Force Update fits 640x360 at x1.25 in all five languages '
        '($theme), with Update now and no way past', (tester) async {
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.25;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final lang in AppLang.values) {
        final t = Strings(lang);
        final state = _state(lang)
          ..handleAppGate(
            AppGateVerdict(
              AppGateStatus.forceUpdate,
              storeUrl: 'https://play.google.com/store/apps/details?id=x',
              minimumVersion: SemVer.tryParse('1.5.0'),
            ),
          );
        await _pump(tester, state, const UpdateScreen(), dark: dark);
        expect(find.text(t.updateTitle), findsOneWidget, reason: '$lang');
        expect(find.text(t.updateBody), findsOneWidget, reason: '$lang');
        expect(find.text(t.updateNow), findsOneWidget, reason: '$lang');
        expect(
          find.text(t.updateVersionLine('1.4.2', '1.5.0')),
          findsOneWidget,
          reason: '$lang',
        );
        expect(find.text(t.softUpdateLater), findsNothing, reason: '$lang');
        expect(tester.takeException(), isNull, reason: '$lang overflowed');
        await _clear(tester, state);
      }
    });

    testWidgets('Maintenance fits 640x360 at x1.25 in all five languages '
        '($theme), with Try again and the operator\'s message', (tester) async {
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.25;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final lang in AppLang.values) {
        final t = Strings(lang);
        for (final message in [
          null,
          'Back at 14:00 IST — we are moving to a faster server.',
        ]) {
          final state = _state(lang)
            ..handleAppGate(
              AppGateVerdict(AppGateStatus.maintenance, message: message),
            );
          await _pump(tester, state, const MaintenanceScreen(), dark: dark);
          expect(
            find.text(t.maintenanceTitle),
            findsOneWidget,
            reason: '$lang',
          );
          expect(
            find.text(message ?? t.maintenanceBody),
            findsOneWidget,
            reason: '$lang',
          );
          expect(
            find.text(t.maintenanceRetry),
            findsOneWidget,
            reason: '$lang',
          );
          expect(find.text(t.updateNow), findsNothing, reason: 'not an update');
          expect(tester.takeException(), isNull, reason: '$lang overflowed');
          await _clear(tester, state);
        }
      }
    });

    testWidgets('the Soft Update prompt fits 640x360 at x1.25 in all five '
        'languages ($theme), with Update now and Later', (tester) async {
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.25;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final lang in AppLang.values) {
        final t = Strings(lang);
        final state = _state(lang);
        await _pump(tester, state, const SoftUpdatePrompt(), dark: dark);
        expect(find.text(t.softUpdateTitle), findsOneWidget, reason: '$lang');
        expect(find.text(t.softUpdateBody), findsOneWidget, reason: '$lang');
        expect(find.text(t.updateNow), findsOneWidget, reason: '$lang');
        expect(find.text(t.softUpdateLater), findsOneWidget, reason: '$lang');
        expect(tester.takeException(), isNull, reason: '$lang overflowed');
        await _clear(tester, state);
      }
    });
  }

  testWidgets('Later on the prompt puts it away and lets the player on', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _state(AppLang.english)
      ..screen = Screen.lobby
      ..softUpdate = AppGateVerdict(
        AppGateStatus.softUpdate,
        latestVersion: SemVer.tryParse('1.6.2'),
      );
    expect(softUpdateShown(state), isTrue);
    await _pump(tester, state, const SoftUpdatePrompt(), dark: true);
    await tester.tap(find.byKey(const ValueKey('soft-update-later')));
    await tester.pump();
    expect(state.softUpdate, isNull);
    expect(softUpdateShown(state), isFalse);
    // Never over a table.
    state
      ..softUpdate = const AppGateVerdict(AppGateStatus.softUpdate)
      ..screen = Screen.table;
    expect(softUpdateShown(state), isFalse);
    await _clear(tester, state);
  });

  test('every word of the gate is in all five languages', () {
    final english = Strings(AppLang.english);
    for (final lang in AppLang.values) {
      final t = Strings(lang);
      for (final key in [
        'updateTitle',
        'updateBody',
        'updateNow',
        'updateVersionLine',
        'updateStoreUnavailable',
        'softUpdateTitle',
        'softUpdateBody',
        'softUpdateLater',
        'maintenanceTitle',
        'maintenanceBody',
        'maintenanceRetry',
      ]) {
        expect(t.ownEntry(key), isNotNull, reason: '$lang lacks $key');
      }
      expect(t.updateVersionLine('1.4.2', '1.5.0'), contains('1.4.2'));
      expect(t.updateVersionLine('1.4.2', '1.5.0'), contains('1.5.0'));
      if (lang != AppLang.english) {
        expect(
          t.maintenanceTitle,
          isNot(english.maintenanceTitle),
          reason: '$lang',
        );
      }
    }
  });
}
