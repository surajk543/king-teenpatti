// The store's header in the scripts the phone draws from its own fonts
// (24 Sep 2026, owner's "fix all bugs"; release review B1).
//
// Inter has no Devanagari, Bengali, Gujarati or Gurmukhi, so on a phone those
// words come from the system's Noto fonts while the spaces, commas and figures
// between them stay in Inter. A line that mixes the two is taller than either
// font's own line: each run's ascent and descent are scaled to the style's
// height separately, in its own font's proportions, and the line takes the
// larger ascent AND the larger descent. The header was measured with the
// Latin line (17 × 1.25 and 12 × 1.35), and on TP_Small in Hindi the Chips
// shelf's blurb, "जितना बड़ा पैक, उतना बड़ा बोनस", overflowed it by a pixel.
//
// The test gives the theme's type ramp the same Noto fonts as a fallback —
// what Android does by itself — and opens every shelf at 640x360 in all five
// languages, at the 1.0 and the 1.25 text scale, in the lobby and at a table.
// An overflow is a FlutterError, which fails the test by itself.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/chip_store.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'script_fonts.dart';

Future<void> _openStore(
  WidgetTester tester, {
  required GameState state,
  required FeedbackSettings feedback,
  required StoreTab tab,
}) async {
  late BuildContext host;
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: withScriptFallback(AppTheme.dark(sound: false)),
        builder: (context, child) => GlassBudget(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            resizeToAvoidBottomInset: false,
            body: child,
          ),
        ),
        home: Builder(
          builder: (context) {
            host = context;
            return const SizedBox.expand();
          },
        ),
      ),
    ),
  );
  unawaited(showChipStore(host, opensOn: tab));
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
}

Future<void> _closeStore(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
}

GameState _state({required Screen screen, required AppLang lang}) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = screen
    ..user = User.fromJson({
      'id': 'u1',
      'provider': 'guest',
      'displayName': 'Ravi',
      'chips': 1250000000,
      'diamond': 100,
      'hammer': 250,
      'missile': 7,
    });
}

void main() {
  setUpAll(loadScriptFonts);

  for (final scale in [1.0, 1.25]) {
    for (final lang in AppLang.values) {
      for (final atTable in [false, true]) {
        testWidgets('at 640x360 in ${lang.englishName} at text x$scale'
            '${atTable ? ' at a table' : ''}, every shelf header fits its '
            'script', (tester) async {
          if (!haveScriptFonts()) {
            markTestSkipped('the Noto script fonts are not installed');
            return;
          }
          tester.view.physicalSize = const Size(640, 360);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final state = _state(
            screen: atTable ? Screen.table : Screen.lobby,
            lang: lang,
          );
          final feedback = FeedbackSettings();
          for (final tab in StoreTab.values) {
            await _openStore(
              tester,
              state: state,
              feedback: feedback,
              tab: tab,
            );
            expect(
              tester.takeException(),
              isNull,
              reason: '${lang.code} x$scale $tab',
            );
            await _closeStore(tester);
          }
          state.dispose();
          feedback.dispose();
        });
      }
    }
  }
}
