// The rules sheet's Variation section (owner, 18 Sep 2026: "in the rules
// button also add a variation rules section").
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/rules_sheet.dart';
import 'package:teenpatti/widgets/variation_prompt.dart';

GameState _state(AppLang lang) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state..lang = lang;
}

Future<void> _openRules(
  WidgetTester tester,
  GameState state, {
  required Size screen,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    ChangeNotifierProvider<GameState>.value(
      value: state,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(sound: false),
        builder: (context, child) => GlassBudget(child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showRules(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  setUpAll(() async {
    final inter = FontLoader('Inter');
    for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
    }
    await inter.load();
  });

  for (final (screen, scale) in [
    (const Size(640, 360), 1.25),
    (const Size(891, 411), 1.0),
  ]) {
    for (final lang in AppLang.values) {
      testWidgets('at ${screen.width.toInt()}x${screen.height.toInt()} x$scale '
          'in ${lang.englishName} the rules name and explain all six '
          'variations', (tester) async {
        final state = _state(lang);
        final t = Strings(lang);
        await _openRules(tester, state, screen: screen, textScale: scale);
        expect(tester.takeException(), isNull);

        // Under the rankings, which are still there.
        expect(find.text(t.rankTrail, skipOffstage: false), findsOneWidget);
        expect(
          find.text(t.variationRulesTitle, skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text(t.variationRulesIntro, skipOffstage: false),
          findsOneWidget,
        );
        for (final wire in Variation.all) {
          expect(
            find.text(t.variationName(wire), skipOffstage: false),
            findsOneWidget,
            reason: wire,
          );
          expect(
            find.text(t.variationNote(wire), skipOffstage: false),
            findsOneWidget,
            reason: wire,
          );
        }

        // It scrolls into view with nothing striped.
        await tester.ensureVisible(
          find.text(
            t.variationName(Variation.highestJoker),
            skipOffstage: false,
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      });
    }
  }

  testWidgets('each example marks the cards that play wild in it', (
    tester,
  ) async {
    final state = _state(AppLang.english);
    await _openRules(tester, state, screen: const Size(891, 411));
    final edged = tester
        .widgetList<WildEdge>(find.byType(WildEdge, skipOffstage: false))
        .where((e) => e.wild)
        .length;
    // AK47, Joker, Hukam, Lowest Joker, Highest Joker: one wild card each.
    // Muflis has none, and nor has any hand in the rankings above.
    expect(edged, 5);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
}
