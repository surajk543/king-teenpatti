// The display-name field's complaint in the settings drawer, whole (24 Sep
// 2026, owner's "fix all bugs"; release review B4). The server's refusal is
// shown under the field, and InputDecoration keeps an error to ONE line by
// default: on TP_Small "Letters, numbers and spaces only." was cut to
// "Letters, numbers and spaces ...". The error now wraps.
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

/// A GameState whose server refuses every name with [refusal].
class _Refusing extends GameState {
  _Refusing(this.refusal) : super(serverUrl: 'http://127.0.0.1:9');

  final String refusal;

  @override
  Future<String?> renameTo(String name) async => refusal;
}

GameState _state(String refusal) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = _Refusing(refusal);
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = AppLang.english
    ..screen = Screen.lobby
    ..config = GameConfig.fromJson({
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'tables': [
        {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
      ],
    })
    ..user = User.fromJson({
      'id': 'u1',
      'provider': 'guest',
      'displayName': 'Ravi',
      'chips': 200000,
    });
}

void main() {
  setUpAll(loadScriptFonts);

  // The server's own sentences (go-server/internal/auth/http.go).
  const refusals = [
    'Letters, numbers and spaces only.',
    'Keep it to 24 characters or fewer.',
  ];
  for (final scale in [1.0, 1.25]) {
    for (final refusal in refusals) {
      testWidgets('at 640x360 at text x$scale the name field shows '
          '"$refusal" whole', (tester) async {
        tester.view.physicalSize = const Size(640, 360);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final state = _state(refusal);
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

        // Settings, then the field's save key.
        await tester.tap(find.byIcon(Icons.tune_rounded).first);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(find.byIcon(Icons.check_rounded));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final error = find.text(refusal);
        expect(error, findsOneWidget);
        expect(
          tester.renderObject<RenderParagraph>(error).didExceedMaxLines,
          isFalse,
          reason: 'x$scale "$refusal" is cut off',
        );
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        state.dispose();
        feedback.dispose();
      });
    }
  }
}
