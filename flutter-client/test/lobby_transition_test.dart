// The lobby's levels give way in one movement (owner, 26 Sep 2026: "when I
// click the Teen Patti card and go to Seen, that transition is not smooth").
// Two animations used to be stacked — the rail's cross-fade hid the old level
// while every card of the new one waited out its own staggered entrance — so
// the rail emptied and the cards trickled back in. Now the old level is gone in
// the first 30% while the new one slides in along the rail and fades in over
// the rest, its cards with it; Back mirrors the direction; the lobby's first
// appearance keeps its stagger.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

const _menu = <Map<String, Object>>[
  {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
  {'category': 'blind', 'bootAmount': 200, 'maxChips': 500000},
  {'category': 'blind', 'bootAmount': 5000, 'maxChips': 50000000},
  {'category': 'variation', 'bootAmount': 50000, 'maxChips': 1000000000},
];

GameState _state() {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = AppLang.english
    ..screen = Screen.lobby
    ..config = GameConfig.fromJson({
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'tables': _menu,
    })
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Ravi',
      'chips': 300000,
      'diamond': 9,
      'hammer': 20,
      'missile': 1,
    });
}

Future<void> _pumpLobby(WidgetTester tester, GameState state) async {
  tester.view.physicalSize = const Size(640, 360);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(sound: false),
        builder: (context, child) => GlassBudget(child: child!),
        home: const LobbyScreen(),
      ),
    ),
  );
}

/// Lets time pass frame by frame: a single long pump fires a card's delayed
/// start inside the jump and paints it only on the last frame.
Future<void> _frames(WidgetTester tester, Duration total) async {
  const frame = Duration(milliseconds: 16);
  for (var t = Duration.zero; t < total; t += frame) {
    await tester.pump(frame);
  }
}

Finder _rail(String level) => find.byKey(ValueKey('lobby-rail:$level'));

/// The rail's own transition: the FadeTransition and SlideTransition
/// _railTransition wraps the level's ListView in (the nearest ones above it).
double _railOpacity(WidgetTester tester, String level) => tester
    .widget<FadeTransition>(
      find
          .ancestor(of: _rail(level), matching: find.byType(FadeTransition))
          .first,
    )
    .opacity
    .value;

double _railShift(WidgetTester tester, String level) => tester
    .widget<SlideTransition>(
      find
          .ancestor(of: _rail(level), matching: find.byType(SlideTransition))
          .first,
    )
    .position
    .value
    .dx;

/// Every card's entrance inside a rail: a card's _Entrance is a FadeTransition
/// straight around a SlideTransition (a card may hold other fades of its own,
/// some hidden at rest, which say nothing about how it arrived).
Iterable<double> _cardOpacities(WidgetTester tester, String level) => tester
    .widgetList<FadeTransition>(
      find.descendant(of: _rail(level), matching: find.byType(FadeTransition)),
    )
    .where((f) => f.child is SlideTransition)
    .map((f) => f.opacity.value);

void main() {
  testWidgets('the lobby first appears with its staggered entrance', (
    tester,
  ) async {
    final state = _state();
    await _pumpLobby(tester, state);
    await tester.pump(const Duration(milliseconds: 16));
    // The first card is on its way in and the last has not started.
    expect(_cardOpacities(tester, '').any((o) => o < 1), isTrue);
    await _frames(tester, const Duration(seconds: 2));
    expect(_cardOpacities(tester, '').every((o) => o == 1), isTrue);
  });

  testWidgets('going in, the old level is gone before the new one arrives, '
      'which slides in from the right with its cards', (tester) async {
    final state = _state();
    await _pumpLobby(tester, state);
    await tester.pump(const Duration(seconds: 2));

    state.openLobbyEngine('teen_patti');
    await tester.pump();
    // 40% of the way (Motion.slow is 300 ms): the front has gone, Teen Patti
    // is fading in and still to the right of its place.
    await tester.pump(const Duration(milliseconds: 120));
    expect(_railOpacity(tester, ''), 0);
    final inOpacity = _railOpacity(tester, 'teen_patti');
    expect(inOpacity, greaterThan(0));
    expect(inOpacity, lessThan(1));
    expect(_railShift(tester, 'teen_patti'), greaterThan(0));
    // Its cards came with it: none waits to make an entrance of its own.
    expect(_cardOpacities(tester, 'teen_patti').every((o) => o == 1), isTrue);

    await tester.pump(const Duration(milliseconds: 200));
    expect(_rail(''), findsNothing);
    expect(_railOpacity(tester, 'teen_patti'), 1);
    expect(_railShift(tester, 'teen_patti'), 0);

    // And on into a category, the same way.
    state.openLobbyCategory('seen', engine: 'teen_patti');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(_railOpacity(tester, 'teen_patti'), 0);
    expect(_railShift(tester, 'teen_patti:seen'), greaterThan(0));
    expect(
      _cardOpacities(tester, 'teen_patti:seen').every((o) => o == 1),
      isTrue,
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(_railOpacity(tester, 'teen_patti:seen'), 1);
  });

  testWidgets('Back mirrors it: the level returned to comes in from the left', (
    tester,
  ) async {
    final state = _state();
    await _pumpLobby(tester, state);
    await tester.pump(const Duration(seconds: 2));
    state.openLobbyEngine('teen_patti');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    state.closeLobbyLevel();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(_railOpacity(tester, 'teen_patti'), 0);
    expect(_railShift(tester, ''), lessThan(0));
    expect(_cardOpacities(tester, '').every((o) => o == 1), isTrue);
    await tester.pump(const Duration(milliseconds: 200));
    expect(_railShift(tester, ''), 0);
    expect(_railOpacity(tester, ''), 1);
  });
}
