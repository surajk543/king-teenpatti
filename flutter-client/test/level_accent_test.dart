// The lobby's drawers in the open level's colour (owner, 30 Sep 2026: "when
// i open setting while Entering Blind Card, then Setting drawer Shade colour
// should change acc to card type colour, for seen it is correct, but for
// blind and variation make it correct").
//
// Inside Blind the Settings drawer is ice where Seen's is cream, and its gold
// — the head mark, the portrait's ring, the switches, the chosen number
// format and appearance — is sapphire; inside Variation lavender and violet.
// Seen and the front draw exactly what they drew. These hold LevelColours to
// the level's hue at the house's own lightness, the drawer to wearing it in
// both themes, Seen to the gold, and the Stats drawer's ring to the level's
// colour with its money still gold.
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
import 'package:teenpatti/theme/theme_colors.dart';
import 'package:teenpatti/widgets/avatar.dart';
import 'package:teenpatti/widgets/feedback_toggles.dart';
import 'package:teenpatti/widgets/level_accent.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/table_ground.dart';

GameState _state(ThemeMode mode) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = AppLang.english
    ..screen = Screen.lobby
    ..themeMode = mode
    ..appVersion = '1.2.3 (10)'
    ..config = GameConfig.fromJson({
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'categories': ['seen', 'blind', 'variation'],
      'tables': [
        {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
        {'category': 'blind', 'bootAmount': 200, 'maxChips': 2000000},
        {'category': 'variation', 'bootAmount': 50000},
      ],
    })
    ..user = User.fromJson({
      'id': 'u1',
      'provider': 'guest',
      'displayName': 'Ravi',
      'chips': 3245000,
    });
}

/// The lobby at 640x360, the level [category] open (none: the front), and
/// the drawer behind [key] — Settings' tune glyph, or the Stats key.
Future<GameState> _open(
  WidgetTester tester, {
  required Brightness brightness,
  String? category,
  IconData key = Icons.tune_rounded,
}) async {
  tester.view.physicalSize = const Size(640, 360);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final mode = brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
  final state = _state(mode);
  final settings = FeedbackSettings();
  addTearDown(() {
    state.dispose();
    settings.dispose();
  });
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: settings),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(sound: false),
        darkTheme: AppTheme.dark(sound: false),
        themeMode: mode,
        builder: (context, child) => GlassBudget(child: child!),
        home: const LobbyScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
  if (category != null) {
    state.openLobbyCategory(category);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(state.lobbyCategory, category);
  }
  await tester.tap(find.byIcon(key).first);
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  return state;
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

/// Scrolls the drawer's list until [f] is built and on screen.
Future<void> _reveal(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(
    f,
    80,
    scrollable: find
        .descendant(of: find.byType(Drawer), matching: find.byType(Scrollable))
        .first,
  );
  await tester.pump(const Duration(seconds: 1));
}

Finder _inDrawer(Finder f) =>
    find.descendant(of: find.byType(Drawer), matching: f, skipOffstage: false);

/// The drawer's ground: the gradient laid over its glass, top colour first.
List<Color> _ground(WidgetTester tester) {
  final body = find.descendant(
    of: find.byType(Drawer),
    matching: find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_DrawerBody',
    ),
  );
  expect(body, findsOneWidget);
  final box = tester.widget<DecoratedBox>(
    find.descendant(of: body, matching: find.byType(DecoratedBox)).first,
  );
  return ((box.decoration as BoxDecoration).gradient! as LinearGradient).colors;
}

double _hue(Color c) => HSLColor.fromColor(c).hue;

/// How far apart two hues are round the wheel.
double _hueGap(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

ColorScheme _scheme(Brightness b) =>
    (b == Brightness.dark
            ? AppTheme.dark(sound: false)
            : AppTheme.light(sound: false))
        .colorScheme;

Color _accent(Brightness b, String category) =>
    AppTheme.paletteFor(_scheme(b), category: category, bootAmount: 200).accent;

void main() {
  group('LevelColours', () {
    for (final b in Brightness.values) {
      testWidgets('answers null for the gold levels and the level\'s colour '
          'for Blind, Variation and Poker (${b.name})', (tester) async {
        final seen = <String?, LevelColours?>{};
        for (final key in const [
          null,
          'seen',
          'unheard_of',
          'blind',
          'variation',
          'poker',
        ]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: b == Brightness.dark
                  ? AppTheme.dark(sound: false)
                  : AppTheme.light(sound: false),
              home: LevelAccent(
                palette: key,
                child: Builder(
                  builder: (context) {
                    seen[key] = LevelAccent.of(context);
                    return const SizedBox();
                  },
                ),
              ),
            ),
          );
        }
        expect(seen[null], isNull);
        expect(seen['seen'], isNull, reason: 'Seen was already right');
        expect(seen['unheard_of'], isNull, reason: 'drawn as Seen');
        for (final key in const ['blind', 'variation', 'poker']) {
          final level = seen[key]!;
          expect(level.fill, _accent(b, key), reason: key);
          expect(level.brightness, b);
          // The ground in the level's hue at the house's own lightness.
          for (final (mine, house) in [
            (level.pearl, TableGround.pearl),
            (level.pearlEdge, TableGround.pearlEdge),
            (level.charcoal, GlassColors.dark.cardFill),
            (level.charcoalEnd, GlassColors.dark.cardFillEnd),
          ]) {
            expect(
              _hueGap(_hue(mine), _hue(level.fill)),
              lessThan(8),
              reason: '$key $mine',
            );
            expect(
              HSLColor.fromColor(mine).lightness,
              closeTo(HSLColor.fromColor(house).lightness, 0.01),
              reason: '$key $mine',
            );
            expect(mine.a, closeTo(house.a, 0.001));
          }
        }
        // No place outside a scope is touched.
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                expect(LevelAccent.of(context), isNull);
                return const SizedBox();
              },
            ),
          ),
        );
      });
    }
  });

  group('the Settings drawer', () {
    for (final b in Brightness.values) {
      for (final category in const ['blind', 'variation']) {
        testWidgets('inside $category wears its colour (${b.name})', (
          tester,
        ) async {
          await _open(tester, brightness: b, category: category);
          final accent = _accent(b, category);
          final palette = AppTheme.paletteFor(
            _scheme(b),
            category: category,
            bootAmount: 200,
          );
          final ink = b == Brightness.dark ? accent : palette.ink;

          // The ground: ice or lavender by day, the charcoal turned to the
          // level's hue by night.
          for (final c in _ground(tester)) {
            expect(_hueGap(_hue(c), _hue(accent)), lessThan(8), reason: '$c');
          }

          // The head's mark.
          final mark = tester.widget<Icon>(
            _inDrawer(find.byIcon(Icons.tune_rounded)),
          );
          expect(mark.color, ink);

          // The portrait's ring.
          final ringed = tester
              .widgetList<Avatar>(_inDrawer(find.byType(Avatar)))
              .where((a) => a.ring != null);
          expect(ringed, hasLength(1));
          expect(ringed.single.ring, accent);

          // The switches, on, in the level's accent.
          await _reveal(tester, _inDrawer(find.text('Vibration')));
          final switches = tester.widgetList<Switch>(
            _inDrawer(find.byType(Switch)),
          );
          expect(switches, hasLength(2));
          for (final s in switches) {
            expect(s.trackColor!.resolve({WidgetState.selected}), accent);
          }

          // The appearance control's chosen word.
          final chosen = b == Brightness.dark
              ? Icons.dark_mode_rounded
              : Icons.light_mode_rounded;
          await _reveal(tester, _inDrawer(find.byIcon(chosen)));
          expect(
            tester.widget<Icon>(_inDrawer(find.byIcon(chosen))).color,
            ink,
          );
          expect(tester.takeException(), isNull);
          await _close(tester);
        });
      }

      testWidgets('inside Seen, and at the front, is the gold and pearl it '
          'always was (${b.name})', (tester) async {
        for (final category in const [null, 'seen']) {
          await _open(tester, brightness: b, category: category);
          final ground = _ground(tester);
          if (b == Brightness.light) {
            expect(ground.first, TableGround.pearl.withValues(alpha: 0.94));
          } else {
            expect(ground.first, GlassColors.dark.cardFill);
          }
          expect(
            tester
                .widget<Icon>(_inDrawer(find.byIcon(Icons.tune_rounded)))
                .color,
            AppTheme.goldInk(b),
          );
          final ring = tester
              .widgetList<Avatar>(_inDrawer(find.byType(Avatar)))
              .where((a) => a.ring != null)
              .single
              .ring;
          expect(
            ring,
            b == Brightness.dark ? AppTheme.goldBright : AppTheme.gold,
          );
          await _reveal(tester, _inDrawer(find.text('Vibration')));
          final switches = tester.widgetList<Switch>(
            _inDrawer(find.byType(Switch)),
          );
          expect(switches, hasLength(2));
          for (final s in switches) {
            expect(
              s.trackColor!.resolve({WidgetState.selected}),
              FeedbackSwitchStyle.trackOn(b),
            );
          }
          await _close(tester);
        }
      });
    }
  });

  testWidgets('the Stats drawer inside Blind takes its ground and ring, and '
      'its money stays gold', (tester) async {
    await _open(
      tester,
      brightness: Brightness.light,
      category: 'blind',
      key: Icons.insights_outlined,
    );
    final accent = _accent(Brightness.light, 'blind');
    for (final c in _ground(tester)) {
      expect(_hueGap(_hue(c), _hue(accent)), lessThan(8));
    }
    final ring = tester
        .widgetList<Avatar>(_inDrawer(find.byType(Avatar)))
        .firstWhere((a) => a.ring != null)
        .ring!;
    expect(ring.withValues(alpha: 1), accent);
    // The winnings are written in the money gold, whatever the level.
    final money = find.descendant(
      of: find.byType(Drawer),
      matching: find.textContaining('Crore'),
    );
    for (final e in money.evaluate()) {
      final style = (e.widget as Text).style;
      if (style?.color != null) {
        expect(
          _hueGap(_hue(style!.color!), _hue(AppTheme.goldOnLight)),
          lessThan(4),
        );
      }
    }
    await _close(tester);
  });
}
