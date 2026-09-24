// The lobby's private-table card on the tightest phone (24 Sep 2026, owner's
// "fix all bugs"; release review B2): on TP_Small in Bengali the Create key
// read "তৈরি ..." — the label ellipsised inside Material's 24dp padding. Both
// keys now keep their whole word in every language, at the 1.0 and the 1.25
// text scale, shrinking it if they must rather than cutting it.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
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
    ..screen = Screen.lobby
    ..config = GameConfig.fromJson({
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'privateBoot': 200,
      'privateMaxPot': 500000,
      'tables': [
        {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
        {'category': 'blind', 'bootAmount': 200, 'maxChips': 500000},
      ],
    })
    ..user = User.fromJson({
      'id': 'u1',
      'provider': 'guest',
      'displayName': 'Ravi',
      'chips': 200000,
      'diamond': 2,
      'hammer': 20,
      'missile': 1,
    });
}

void main() {
  setUpAll(loadScriptFonts);

  for (final scale in [1.0, 1.25]) {
    for (final lang in AppLang.values) {
      testWidgets('at 640x360 in ${lang.englishName} at text x$scale the '
          'private card keeps Create and Join whole', (tester) async {
        if (!haveScriptFonts()) {
          markTestSkipped('the Noto script fonts are not installed');
          return;
        }
        tester.view.physicalSize = const Size(640, 360);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final state = _state(lang);
        final feedback = FeedbackSettings();
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<GameState>.value(value: state),
              ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
            ],
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: withScriptFallback(AppTheme.dark(sound: false)),
              builder: (context, child) => GlassBudget(child: child!),
              home: const LobbyScreen(),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));

        final t = Strings(lang);
        for (final word in [t.create, t.join]) {
          final label = find.text(word);
          expect(label, findsOneWidget, reason: '${lang.code} "$word"');
          final paragraph = tester.renderObject<RenderParagraph>(label);
          expect(
            paragraph.didExceedMaxLines,
            isFalse,
            reason: '${lang.code} x$scale "$word" is cut off',
          );
          // Whole inside its key: the laid-out words, however scaled, stand
          // within the button they label.
          final key = find.ancestor(
            of: label,
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          );
          final keyBox = tester.getRect(key.first);
          final wordBox = tester.getRect(label);
          expect(
            keyBox.contains(wordBox.topLeft) &&
                keyBox.contains(wordBox.bottomRight - const Offset(0.01, 0.01)),
            isTrue,
            reason: '${lang.code} x$scale "$word" $wordBox in $keyBox',
          );
        }
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        state.dispose();
        feedback.dispose();
      });
    }
  }
}
