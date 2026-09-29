// The lobby's Stats drawer as one continuous player profile (the owner's
// brief, 27 Sep 2026: "Do NOT use tabs … Poker must NOT appear anywhere in
// this drawer"). No switch of tabs: a small menu beside PERFORMANCE chooses
// All Games, Teen Patti or Variations, and each shows the model's own figures
// for it; the head names the player and their level, and no longer says "Your
// record"; hands left mid-hand stand apart from played, won and lost; HAND
// RESULTS and VARIATIONS PLAYED show what the scope counts, or say plainly
// why they do not; long names end in an ellipsis and 10.5 Crore fits. Every
// scope fits five landscape phones and a tablet at text x1.0 and x1.25, in
// all five languages, by day and by night — and the Friends page's profile
// and a table's player drawer still draw another player's record with its
// four games, as before.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/config/features.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/player_stats.dart';
import 'package:teenpatti/screens/friends_screen.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/hammer_flight.dart';
import 'package:teenpatti/widgets/own_record.dart';
import 'package:teenpatti/widgets/player_drawer.dart';
import 'package:teenpatti/widgets/player_profile.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/seat_pod.dart';
import 'package:teenpatti/widgets/table_ground.dart';

import 'friends_fixture.dart';
import 'player_stats_fixture.dart';
import 'script_fonts.dart';
import 'stats_drawer_fixture.dart';
import 'table_scenes.dart' show silentFeedback, tableApp;

// --------------------------------------------------------------- finders

Finder _key(String key) => find.byKey(ValueKey(key));

Finder _inDrawer(Finder matching) =>
    find.descendant(of: find.byType(Drawer), matching: matching);

/// [text] in the widget keyed [key], or that widget itself.
Finder _textIn(String key, String text) =>
    find.descendant(of: _key(key), matching: find.text(text), matchRoot: true);

Rect _onScreen(RenderBox box) =>
    MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);

/// Every line of the drawer's words as it draws them.
List<RenderParagraph> _paragraphs(WidgetTester tester, Finder root) => [
  for (final e
      in find.descendant(of: root, matching: find.byType(RichText)).evaluate())
    if (e.renderObject case final RenderParagraph p
        when p.attached && p.hasSize)
      p,
];

String _plain(RenderParagraph p) => p.text.toPlainText();

// ----------------------------------------------------------------- mounting

void _setView(
  WidgetTester tester, {
  Size size = const Size(640, 360),
  double scale = 1.25,
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// The lobby with its Stats drawer open, signed in with [me].
Future<GameState> _openStats(
  WidgetTester tester, {
  AppLang lang = AppLang.english,
  Brightness brightness = Brightness.dark,
  Map<String, dynamic>? me,
}) async {
  final state = statsDrawerState(lang: lang, me: me);
  final feedback = FeedbackSettings();
  addTearDown(() {
    state.dispose();
    feedback.dispose();
  });
  await tester.pumpWidget(
    statsApp(state, feedback, const LobbyScreen(), brightness: brightness),
  );
  await tester.pump(const Duration(seconds: 1));
  await tester.tap(find.byIcon(Icons.insights_outlined).first);
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  // The record's entrance starts on the frame the drawer settles in.
  await tester.pump(const Duration(milliseconds: 600));
  return state;
}

Future<void> _closeApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.ensureVisible(_key('stats-scope'));
  await tester.pump();
  await tester.tap(_key('stats-scope'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Chooses [scope] from the menu and lets the record cross over.
Future<void> _choose(WidgetTester tester, StatsScope scope) async {
  await _openMenu(tester);
  await tester.tap(_key('stats-scope-option-${scope.name}'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _scrollToEnd(WidgetTester tester) async {
  final position = tester
      .state<ScrollableState>(_inDrawer(find.byType(Scrollable)).first)
      .position;
  position.jumpTo(position.maxScrollExtent);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// A count grouped by thousands, as the record writes one.
String _grouped(int n) {
  final s = '$n';
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// The scope on show, figure by figure, from the account's own JSON [game]:
/// played, won, lost, the two chip figures, hands left mid-hand; the hands
/// held and the variations where the model counts them for [scope].
void _expectScope(
  WidgetTester tester,
  Strings t,
  StatsScope scope,
  Map<String, dynamic> game,
) {
  final where = scope.name;
  expect(_key('stats-view-${scope.name}'), findsOneWidget, reason: where);
  for (final other in StatsScope.values.where((s) => s != scope)) {
    expect(_key('stats-view-${other.name}'), findsNothing, reason: where);
  }
  for (final (key, label, value) in [
    ('stats-played', t.statsPlayed, _grouped(game['handsPlayed'] as int)),
    ('stats-won', t.won, _grouped(game['handsWon'] as int)),
    ('stats-lost', t.lost, _grouped(game['handsLost'] as int)),
    (
      'stats-total-winnings',
      t.totalWinnings,
      formatChips(game['totalWinnings'] as int),
    ),
    ('stats-biggest-pot', t.biggestPot, formatChips(game['biggestPot'] as int)),
  ]) {
    expect(_textIn(key, label), findsOneWidget, reason: '$where $key');
    expect(_textIn(key, value), findsOneWidget, reason: '$where $key');
  }
  final left = (game['handsLeft'] ?? game['handsLeftMid']) as int;
  final line = tester
      .widget<RichText>(
        find.descendant(
          of: _key('stats-left-mid-hand-text'),
          matching: find.byType(RichText),
        ),
      )
      .text
      .toPlainText();
  expect(line, '${t.leftMidHand}: ${_grouped(left)}', reason: where);

  final countsHands = scope.category.countsHands;
  expect(_key('stats-hands'), countsHands ? findsOneWidget : findsNothing);
  expect(_key('stats-hands-hint'), countsHands ? findsNothing : findsOneWidget);
  if (countsHands) {
    final hands = game['hands'] as Map<String, int>;
    for (final (i, field) in HandTally.fields.indexed) {
      final cell = 'stats-hand-$field';
      expect(_textIn(cell, HandTally.names[i]), findsOneWidget, reason: where);
      expect(_textIn(cell, '${hands[field]}'), findsOneWidget, reason: where);
      // Each hand wears its icon, the daily XP's own mark for it.
      expect(_textIn(cell, HandTally.icons[i]), findsOneWidget, reason: where);
    }
  }
  final lists = scope.category.listsVariations;
  expect(
    _key('stats-variations'),
    lists ? findsOneWidget : findsNothing,
    reason: where,
  );
  expect(
    _key('stats-variations-hint'),
    lists ? findsNothing : findsOneWidget,
    reason: where,
  );
  if (lists) {
    final rows = game['variations'] as List<Map<String, dynamic>>;
    final tops = <double>[];
    for (final row in rows) {
      final name = row['variation'] as String;
      expect(
        tester.widget<Text>(_key('stats-variation-$name')).data,
        t.variationName(name),
      );
      expect(
        _textIn('stats-variation-$name-played', '${row['handsPlayed']}'),
        findsOneWidget,
      );
      expect(
        _textIn('stats-variation-$name-won', '${row['handsWon']}'),
        findsOneWidget,
      );
      tops.add(tester.getRect(_key('stats-variation-$name')).top);
    }
    // In the server's order, Muflis first.
    expect(tops, [...tops]..sort(), reason: where);
  }
}

/// Every word of the drawer — the open menu too — whole and inside the
/// panel, nothing thrown; the player's name alone may end in an ellipsis
/// when [longName].
void _expectFits(WidgetTester tester, String where, {bool longName = false}) {
  expect(tester.takeException(), isNull, reason: where);
  final panel = tester.getRect(find.byType(Drawer));
  final lines = _paragraphs(tester, find.byType(Drawer));
  expect(lines.length, greaterThan(12), reason: '$where: nothing built');
  for (final p in lines) {
    final line = _plain(p);
    final isName =
        longName &&
        p ==
            tester.renderObject(
              find.descendant(
                of: _key('stats-name'),
                matching: find.byType(RichText),
              ),
            );
    if (!isName) {
      expect(p.didExceedMaxLines, isFalse, reason: '$where: "$line" cut');
    }
    final rect = _onScreen(p);
    expect(
      rect.left,
      greaterThanOrEqualTo(panel.left - 0.5),
      reason: '$where: "$line" $rect outside $panel',
    );
    expect(
      rect.right,
      lessThanOrEqualTo(panel.right + 0.5),
      reason: '$where: "$line" $rect outside $panel',
    );
  }
}

/// WCAG contrast of [fg] laid over [bg].
double _contrast(Color fg, Color bg) {
  final a = Color.alphaBlend(fg, bg).computeLuminance();
  final b = bg.computeLuminance();
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

/// The drawer's body by day at its foot, the darker of its two stops: the
/// pearl a step towards its edge ([TableGround.pearlEdge]).
final Color _dayFoot = Color.lerp(
  TableGround.pearl,
  TableGround.pearlEdge,
  0.4,
)!;

/// The fill of the card keyed [key] (a [PerformanceStatCard]).
Color _cardFill(WidgetTester tester, String key) {
  final box = tester.widget<Container>(
    find.descendant(of: _key(key), matching: find.byType(Container)).first,
  );
  return (box.decoration! as BoxDecoration).color!;
}

// ------------------------------------------ the other two places, unchanged

Future<void> _settlePage(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 300));
}

Finder _plaqueOf(String userId) => find.descendant(
  of: find.byWidgetPredicate((w) => w is SeatPod && w.seat?.userId == userId),
  matching: find.byType(PodImpact),
);

/// Another player's record as it has always been drawn: [PlayerStatsGrid]
/// with its switch of four games — Poker among them — under [root].
void _expectOldRecord(WidgetTester tester, Finder root, Strings t) {
  expect(
    find.descendant(of: root, matching: find.byType(PlayerStatsGrid)),
    findsOneWidget,
  );
  expect(
    find.descendant(of: root, matching: find.byType(OwnRecord)),
    findsNothing,
  );
  expect(
    find.descendant(of: root, matching: _key('stats-categories')),
    findsOneWidget,
  );
  // Every game the build shows (statsViews): Poker only in a SHOW_POKER
  // build (owner, 27 Sep 2026: "remove poker category").
  for (final view in StatsCategory.values) {
    expect(
      find.descendant(of: root, matching: _key('stats-category-${view.name}')),
      statsViews().contains(view) ? findsOneWidget : findsNothing,
      reason: view.name,
    );
  }
  expect(
    _textIn('stats-category-poker', friendlyName(t.poker)),
    AppFeatures.poker ? findsOneWidget : findsNothing,
  );
  expect(_textIn('friend-stat-0', '1,498'), findsOneWidget);
  expect(_textIn('friend-stat-4', t.winRate), findsOneWidget);
}

// ------------------------------------------------------------------- main

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadScriptFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({'soundOn': false}));

  group('one continuous profile', () {
    testWidgets('no tabs, no segmented switch and no switch of games in the '
        'drawer: one menu beside PERFORMANCE', (tester) async {
      _setView(tester);
      final state = await _openStats(tester);
      final t = state.t;
      for (final type in [TabBar, TabBarView, SegmentedButton<Object>]) {
        expect(_inDrawer(find.byType(type)), findsNothing, reason: '$type');
      }
      expect(_inDrawer(find.byType(DefaultTabController)), findsNothing);
      expect(_inDrawer(find.byType(PlayerStatsGrid)), findsNothing);
      expect(_inDrawer(_key('stats-categories')), findsNothing);
      for (final view in StatsCategory.values) {
        expect(_key('stats-category-${view.name}'), findsNothing);
      }
      expect(_inDrawer(find.byType(OwnRecord)), findsOneWidget);
      expect(_inDrawer(find.byType(StatsScopeSelector)), findsOneWidget);
      // PERFORMANCE and its menu share a row; the menu says the scope.
      final head = tester.getRect(find.text(t.statsPerformance.toUpperCase()));
      final menu = tester.getRect(_key('stats-scope'));
      expect(menu.center.dy, closeTo(head.center.dy, 2));
      expect(menu.left, greaterThan(head.right));
      expect(_textIn('stats-scope', t.statsAllGames), findsOneWidget);
      // The trigger is small; its touch target is whole.
      expect(menu.height, greaterThanOrEqualTo(Dim.minTouch - 0.5));
      await _closeApp(tester);
    });

    testWidgets('the menu offers exactly All Games, Teen Patti and '
        'Variations, anchored under its key, and Poker is nowhere', (
      tester,
    ) async {
      _setView(tester, size: const Size(891, 411), scale: 1.0);
      final state = await _openStats(tester);
      final t = state.t;
      await _openMenu(tester);
      final menu = _key('stats-scope-menu');
      expect(menu, findsOneWidget);
      final options = find.descendant(
        of: menu,
        matching: find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'stats-scope-option-',
              ),
        ),
      );
      expect(options, findsNWidgets(3));
      expect(
        [
          for (final scope in StatsScope.values)
            tester
                .widget<Text>(
                  find.descendant(
                    of: _key('stats-scope-option-${scope.name}'),
                    matching: find.byType(Text),
                  ),
                )
                .data,
        ],
        ['All Games', 'Teen Patti', 'Variations'],
      );
      // Anchored: under the key, its right edge on the key's.
      final key = tester.getRect(_key('stats-scope'));
      final box = tester.getRect(menu);
      expect(box.top, greaterThanOrEqualTo(key.bottom - 12));
      expect(box.right, closeTo(key.right, 1));
      // Not a route: nothing pushed over the lobby.
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      // The chosen scope in gold with a check; the others plain.
      final chosen = _key('stats-scope-option-allGames');
      expect(
        find.descendant(of: chosen, matching: find.byIcon(Icons.check_rounded)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _key('stats-scope-option-teenPatti'),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsNothing,
      );
      expect(
        tester
            .widget<Text>(
              find.descendant(of: chosen, matching: find.byType(Text)),
            )
            .style
            ?.color,
        AppTheme.goldInk(Brightness.dark),
      );
      // No Poker in the drawer or its menu, in any scope, in any language.
      void noPoker(String where) {
        for (final root in [find.byType(Drawer), menu]) {
          if (root.evaluate().isEmpty) continue;
          for (final p in _paragraphs(tester, root)) {
            for (final lang in AppLang.values) {
              final word = friendlyName(Strings(lang).poker);
              expect(_plain(p), isNot(contains(word)), reason: where);
            }
            expect(
              _plain(p).toLowerCase(),
              isNot(contains('poker')),
              reason: where,
            );
            // The poker game's own figures are never shown either.
            expect(_plain(p), isNot(contains('206')), reason: where);
          }
        }
      }

      noPoker('menu open');
      expect(_key('stats-category-poker'), findsNothing);
      await tester.tap(_key('stats-scope-option-allGames'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      for (final scope in StatsScope.values) {
        await _choose(tester, scope);
        noPoker(scope.name);
        await _scrollToEnd(tester);
        noPoker('${scope.name} end');
      }
      expect(t.lang, AppLang.english);
      await _closeApp(tester);
    });

    testWidgets('each scope shows the account\'s own figures for it, and '
        'crosses over in a short fade', (tester) async {
      _setView(tester, size: const Size(891, 411), scale: 1.0);
      final state = await _openStats(tester);
      final t = state.t;
      final me = guestWithStatsJson();
      final games = me['stats'] as Map<String, dynamic>;
      _expectScope(tester, t, StatsScope.allGames, me);
      for (final (scope, game) in [
        (StatsScope.teenPatti, games['teenPatti']),
        (StatsScope.variations, games['variation']),
        (StatsScope.teenPatti, games['teenPatti']),
        (StatsScope.allGames, me),
      ]) {
        await _openMenu(tester);
        await tester.tap(_key('stats-scope-option-${scope.name}'));
        // Mid-fade: both views are there, the new one on its way in.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 90));
        expect(_key('stats-view-${scope.name}'), findsOneWidget);
        final fade = tester
            .widgetList<FadeTransition>(
              find.ancestor(
                of: _key('stats-view-${scope.name}'),
                matching: find.byType(FadeTransition),
              ),
            )
            .first;
        expect(fade.opacity.value, inExclusiveRange(0, 1));
        await tester.pump(const Duration(milliseconds: 300));
        _expectScope(tester, t, scope, game as Map<String, dynamic>);
        // The menu put itself away.
        expect(_key('stats-scope-menu'), findsNothing);
        expect(
          _textIn('stats-scope', statsScopeName(t, scope)),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
      expect(OwnRecord.crossOver.inMilliseconds, inInclusiveRange(150, 250));
      await _closeApp(tester);
    });

    testWidgets('a tap outside the menu puts it away and changes nothing', (
      tester,
    ) async {
      _setView(tester, size: const Size(891, 411), scale: 1.0);
      await _openStats(tester);
      await _openMenu(tester);
      expect(_key('stats-scope-menu'), findsOneWidget);
      await tester.tapAt(
        tester.getRect(find.byType(Drawer)).bottomLeft + const Offset(40, -30),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_key('stats-scope-menu'), findsNothing);
      expect(_key('stats-view-allGames'), findsOneWidget);
      // The drawer is still open.
      expect(find.byType(Drawer), findsOneWidget);
      await _closeApp(tester);
    });

    testWidgets('the scope is the selected one of a group, to a screen reader '
        'too, and the key says what it chooses', (tester) async {
      _setView(tester, size: const Size(891, 411), scale: 1.0);
      final handle = tester.ensureSemantics();
      final state = await _openStats(tester);
      final t = state.t;
      expect(
        tester.getSemantics(_key('stats-scope')),
        isSemantics(
          isButton: true,
          hasTapAction: true,
          label: '${t.statsScopeLabel}: ${t.statsAllGames}',
        ),
      );
      await _openMenu(tester);
      expect(
        tester.getSemantics(_key('stats-scope-option-allGames')),
        isSemantics(
          isButton: true,
          isSelected: true,
          isInMutuallyExclusiveGroup: true,
          hasTapAction: true,
          label: 'All Games',
        ),
      );
      expect(
        tester.getSemantics(_key('stats-scope-option-variations')),
        isSemantics(isButton: true, isSelected: false, label: 'Variations'),
      );
      handle.dispose();
      await _closeApp(tester);
    });

    testWidgets('the scope stays chosen while the drawer scrolls to its end '
        'and back', (tester) async {
      _setView(tester, size: const Size(640, 360), scale: 1.25);
      await _openStats(tester);
      await _choose(tester, StatsScope.variations);
      await _scrollToEnd(tester);
      expect(_key('stats-view-variations'), findsOneWidget);
      expect(_key('stats-variations'), findsOneWidget);
      final position = tester
          .state<ScrollableState>(_inDrawer(find.byType(Scrollable)).first)
          .position;
      position.jumpTo(0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(_key('stats-view-variations'), findsOneWidget);
      await _closeApp(tester);
    });
  });

  group('the head', () {
    testWidgets('the name, strongest, over "Level 1 · Newbie · 23 XP"; no '
        '"Your record"; a small close key that closes', (tester) async {
      _setView(tester, size: const Size(891, 411), scale: 1.0);
      final state = await _openStats(tester);
      final t = state.t;
      expect(_inDrawer(find.text(t.yourRecord)), findsNothing);
      final name = tester.widget<Text>(_key('stats-name'));
      expect(name.data, 'Guest23AF1');
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: _key('stats-level-line'),
                matching: find.byType(Text),
              ),
            )
            .data,
        'Level 1 · Newbie · 23 XP',
      );
      final level = tester.widget<Text>(
        find.descendant(
          of: _key('stats-level-line'),
          matching: find.byType(Text),
        ),
      );
      expect(name.style!.fontSize, inInclusiveRange(16, 18));
      expect(name.style!.fontWeight, FontWeight.w700);
      expect(level.style!.fontSize, inInclusiveRange(12, 13));
      // Quieter than the name: a muted ink, not the name's.
      expect(level.style!.color, isNot(name.style!.color));
      // The badges held, quieter still — and where they fit, on the level
      // line, so the head is the name over one line.
      expect(tester.widget<Text>(_key('stats-badges')).data, 'Regular');
      final badges = tester.widget<Text>(_key('stats-badges'));
      expect(badges.style!.color, isNot(level.style!.color));
      expect(
        tester.getRect(_key('stats-badges')).center.dy,
        closeTo(tester.getRect(_key('stats-level-line')).center.dy, 2),
      );
      expect(
        tester.getRect(_key('stats-badges')).left,
        greaterThan(tester.getRect(_key('stats-level-line')).right),
      );
      // The close key: a 28dp disc in a whole touch target.
      final close = tester.getRect(_key('stats-close'));
      expect(close.width, greaterThanOrEqualTo(Dim.minTouch - 0.5));
      await tester.tap(_key('stats-close'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(Drawer), findsNothing);
      await _closeApp(tester);
    });

    testWidgets('a long name ends in an ellipsis inside the head, and the '
        'close key keeps its place', (tester) async {
      _setView(tester, size: const Size(592, 360), scale: 1.25);
      await _openStats(
        tester,
        me: guestWithStatsJson(name: 'Vikramadityasinghrathore'),
      );
      final p = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: _key('stats-name'),
          matching: find.byType(RichText),
        ),
      );
      expect(p.didExceedMaxLines, isTrue, reason: 'cut with an ellipsis');
      final name = _onScreen(p);
      final close = tester.getRect(_key('stats-close'));
      expect(name.right, lessThanOrEqualTo(close.left + 0.5));
      _expectFits(tester, 'long name', longName: true);
      await _closeApp(tester);
    });
  });

  group('the record', () {
    testWidgets('hands left mid-hand is a quiet line, not a card beside '
        'played, won and lost', (tester) async {
      _setView(tester, size: const Size(891, 411), scale: 1.0);
      await _openStats(tester);
      final left = _key('stats-left-mid-hand');
      expect(left, findsOneWidget);
      expect(
        find.ancestor(of: left, matching: find.byType(PerformanceStatCard)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: _key('stats-performance'),
          matching: find.byType(PerformanceStatCard),
        ),
        findsNWidgets(3),
      );
      expect(
        find.descendant(
          of: _key('stats-winning'),
          matching: find.byType(PerformanceStatCard),
        ),
        findsNWidgets(2),
      );
      final line = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: _key('stats-left-mid-hand-text'),
          matching: find.byType(RichText),
        ),
      );
      expect(
        tester.getRect(left).height,
        lessThan(tester.getRect(_key('stats-played')).height / 2),
      );
      expect(
        (line.text as TextSpan).style!.fontSize!,
        lessThan(
          tester
              .widget<Text>(_textIn('stats-played', '1,498'))
              .style!
              .fontSize!,
        ),
      );
      await _closeApp(tester);
    });

    testWidgets('three across, then two across; gold for the two chip '
        'figures alone, by night and by day', (tester) async {
      for (final b in Brightness.values) {
        _setView(tester, size: const Size(640, 360), scale: 1.25);
        await _openStats(tester, brightness: b);
        final played = tester.getRect(_key('stats-played'));
        final won = tester.getRect(_key('stats-won'));
        final lost = tester.getRect(_key('stats-lost'));
        expect(won.top, closeTo(played.top, 0.5));
        expect(lost.top, closeTo(played.top, 0.5));
        expect(won.left, greaterThan(played.right));
        final winnings = tester.getRect(_key('stats-total-winnings'));
        final biggest = tester.getRect(_key('stats-biggest-pot'));
        expect(biggest.top, closeTo(winnings.top, 0.5));
        expect(winnings.top, greaterThan(played.bottom));
        final gold = AppTheme.goldInk(b);
        Color? ink(String key, String text) =>
            tester.widget<Text>(_textIn(key, text)).style?.color;
        expect(ink('stats-total-winnings', formatChips(105000500)), gold);
        expect(ink('stats-biggest-pot', formatChips(12500000)), gold);
        for (final (key, text) in [
          ('stats-played', '1,498'),
          ('stats-won', '610'),
          ('stats-lost', '813'),
        ]) {
          expect(ink(key, text), isNot(gold), reason: '$b $key');
        }
        // Night: white figures; day: a warm charcoal, never pure black.
        final count = ink('stats-played', '1,498')!;
        if (b == Brightness.dark) {
          expect(count.computeLuminance(), greaterThan(0.9));
        } else {
          expect(count.computeLuminance(), lessThan(0.05));
          expect(count, isNot(Colors.black));
        }
        // No hands' count is gold either.
        await _choose(tester, StatsScope.teenPatti);
        expect(
          tester.widget<Text>(_textIn('stats-hand-pair', '153')).style?.color,
          isNot(gold),
        );
        await _closeApp(tester);
      }
    });

    testWidgets('99.9 Lakh, 1.25 Crore and 10.5 Crore fit their cards on the '
        'narrowest phone at the largest text', (tester) async {
      _setView(tester, size: const Size(592, 360), scale: 1.25);
      await _openStats(tester);
      for (final scope in [StatsScope.allGames, StatsScope.teenPatti]) {
        await _choose(tester, scope);
        for (final key in ['stats-total-winnings', 'stats-biggest-pot']) {
          final card = tester.getRect(_key(key));
          final p = tester.renderObject<RenderParagraph>(
            find
                .descendant(of: _key(key), matching: find.byType(RichText))
                .at(0),
          );
          final figure = _onScreen(p);
          expect(figure.left, greaterThanOrEqualTo(card.left));
          expect(
            figure.right,
            lessThanOrEqualTo(card.right),
            reason: '$scope $key ${_plain(p)}',
          );
        }
      }
      await _choose(tester, StatsScope.allGames);
      expect(
        _textIn('stats-total-winnings', formatChips(105000500)),
        findsOneWidget,
      );
      expect(formatChips(105000500), '10.5 Crore');
      expect(formatChips(12500000), '1.25 Crore');
      expect(formatChips(9990000), '99.9 Lakh');
      await _closeApp(tester);
    });

    testWidgets('"Hands held" is now HAND RESULTS, two to a row, and '
        'VARIATIONS PLAYED a list with PLAYED and WON', (tester) async {
      _setView(tester, size: const Size(891, 411), scale: 1.0);
      final state = await _openStats(tester);
      final t = state.t;
      await _choose(tester, StatsScope.variations);
      expect(_inDrawer(find.text(t.handsHeld)), findsNothing);
      expect(find.text(t.statsHandResults.toUpperCase()), findsOneWidget);
      expect(find.text(t.variationsPlayed.toUpperCase()), findsOneWidget);
      final trail = tester.getRect(_key('stats-hand-trail'));
      final pure = tester.getRect(_key('stats-hand-pureSequence'));
      final sequence = tester.getRect(_key('stats-hand-sequence'));
      expect(pure.top, closeTo(trail.top, 0.5));
      expect(sequence.top, greaterThan(trail.bottom));
      expect(sequence.left, closeTo(trail.left, 0.5));
      // Each hand's icon at the start of its cell, before its name, and the
      // names of one column starting at one edge whatever the icon's width.
      expect(HandTally.icons, hasLength(HandTally.names.length));
      final nameLefts = <double>[];
      for (final (i, field) in HandTally.fields.indexed) {
        final icon = tester.getRect(_key('stats-hand-icon-$field'));
        final name = tester.getRect(
          _textIn('stats-hand-$field', HandTally.names[i]),
        );
        final cell = tester.getRect(_key('stats-hand-$field'));
        expect(icon.left, greaterThanOrEqualTo(cell.left), reason: field);
        expect(icon.right, lessThanOrEqualTo(name.left + 0.5), reason: field);
        expect(icon.center.dy, closeTo(cell.center.dy, 2), reason: field);
        if (i.isEven) nameLefts.add(name.left - cell.left);
      }
      for (final left in nameLefts) {
        expect(left, closeTo(nameLefts.first, 0.5));
      }
      await _scrollToEnd(tester);
      expect(_textIn('stats-variations', 'PLAYED'), findsOneWidget);
      expect(_textIn('stats-variations', 'WON'), findsOneWidget);
      // The figures stand in right-aligned columns.
      final a = tester.getRect(_key('stats-variation-MUFLIS-played'));
      final b = tester.getRect(_key('stats-variation-FIVE_CARD-played'));
      expect(a.right, closeTo(b.right, 0.5));
      final c = tester.getRect(_key('stats-variation-MUFLIS-won'));
      final d = tester.getRect(_key('stats-variation-FIVE_CARD-won'));
      expect(c.right, closeTo(d.right, 0.5));
      await _closeApp(tester);
    });

    testWidgets('empty states: a new account says so in plain words, and a '
        'scope that does not count a part says which does', (tester) async {
      _setView(tester, size: const Size(640, 360), scale: 1.25);
      final state = await _openStats(tester, me: newAccountJson());
      final t = state.t;
      // All Games: the model counts neither part for it.
      expect(_textIn('stats-played', '0'), findsOneWidget);
      expect(_textIn('stats-total-winnings', '0'), findsOneWidget);
      expect(
        find.text(t.statsHandResultsHint, skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.text(t.statsVariationsHint, skipOffstage: false),
        findsOneWidget,
      );
      // Teen Patti: no hands yet; the variations are Variations'.
      await _choose(tester, StatsScope.teenPatti);
      expect(_key('stats-hands-none'), findsOneWidget);
      expect(find.text(t.statsNoHandResults), findsOneWidget);
      expect(_key('stats-hands'), findsNothing);
      expect(
        find.text(t.statsVariationsHint, skipOffstage: false),
        findsOneWidget,
      );
      // Variations: neither yet.
      await _choose(tester, StatsScope.variations);
      await _scrollToEnd(tester);
      expect(_key('stats-hands-none'), findsOneWidget);
      expect(_key('stats-variations-none'), findsOneWidget);
      expect(find.text(t.statsNoVariationGames), findsOneWidget);
      expect(_key('stats-variations'), findsNothing);
      // The structure stays: both section names in every scope.
      expect(find.text(t.statsHandResults.toUpperCase()), findsOneWidget);
      expect(find.text(t.variationsPlayed.toUpperCase()), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _closeApp(tester);
    });
  });

  // The review of 27 Sep 2026: the footnote's ink, the chosen scope's by day,
  // hand names beside large counts, the badges' line, the tick, and the
  // theme's cross-fade.
  group('readable, whole and still', () {
    testWidgets('the footnote is in the record\'s muted ink, 4.5:1 or more '
        'by day', (tester) async {
      for (final b in Brightness.values) {
        _setView(tester, size: const Size(891, 411), scale: 1.0);
        final state = await _openStats(tester, brightness: b);
        await _scrollToEnd(tester);
        final note = tester.widget<Text>(
          find.descendant(
            of: find.byType(StatsFootnote),
            matching: find.byType(Text),
          ),
        );
        expect(note.data, state.t.playedNote);
        final header = tester.widget<Text>(
          find.text(state.t.statsPerformance.toUpperCase()),
        );
        expect(note.style!.color, header.style!.color, reason: '$b');
        if (b == Brightness.light) {
          expect(
            _contrast(note.style!.color!, _dayFoot),
            greaterThanOrEqualTo(4.5),
          );
        }
        await _closeApp(tester);
      }
    });

    testWidgets('by day the chosen scope\'s name holds 4.5:1 on its gold '
        'wash, and the menu keeps the drawer\'s blur budget', (tester) async {
      _setView(tester, size: const Size(891, 411), scale: 1.0);
      await _openStats(tester, brightness: Brightness.light);
      await _openMenu(tester);
      final chosen = _key('stats-scope-option-allGames');
      final label = tester.widget<Text>(
        find.descendant(of: chosen, matching: find.byType(Text)),
      );
      expect(label.style!.color, AppTheme.goldDeep);
      final row = tester.widget<Container>(
        find.descendant(of: chosen, matching: find.byType(Container)).first,
      );
      final wash = (row.decoration! as BoxDecoration).color!;
      // The wash over the menu's body over the drawer's pearl.
      final ground = Color.alphaBlend(
        wash,
        Color.alphaBlend(Colors.white.withValues(alpha: 0.86), _dayFoot),
      );
      expect(_contrast(label.style!.color!, ground), greaterThanOrEqualTo(4.5));
      expect(
        tester.widget<PremiumGlassPanel>(_key('stats-scope-menu')).mode,
        GlassMode.auto,
      );
      await _closeApp(tester);
    });

    testWidgets('the badges share the level\'s line only where both fit '
        'whole', (tester) async {
      _setView(tester, size: const Size(592, 360), scale: 1.25);
      await _openStats(tester, lang: AppLang.hindi);
      final level = tester.getRect(_key('stats-level-line'));
      final badges = tester.getRect(_key('stats-badges'));
      final together = (badges.center.dy - level.center.dy).abs() < 2;
      if (together) {
        expect(badges.left, greaterThan(level.right));
      } else {
        expect(badges.top, greaterThanOrEqualTo(level.bottom - 0.5));
      }
      _expectFits(tester, 'hindi head');
      await _closeApp(tester);
    });

    testWidgets('the lobby\'s notifies rebuild nothing in the drawer', (
      tester,
    ) async {
      _setView(tester, size: const Size(891, 411), scale: 1.0);
      final state = await _openStats(tester);
      Future<void> expectStill(String where) async {
        final header = tester.widget(find.byType(PlayerStatsHeader));
        final record = tester.widget(find.byType(OwnRecord));
        final played = tester.widget(_key('stats-played'));
        // What the one-second tick does: a notify with nothing of the
        // account's changed.
        for (var i = 0; i < 3; i++) {
          state.clearNotice();
          await tester.pump(const Duration(seconds: 1));
        }
        expect(
          identical(tester.widget(find.byType(PlayerStatsHeader)), header),
          isTrue,
          reason: where,
        );
        expect(
          identical(tester.widget(find.byType(OwnRecord)), record),
          isTrue,
          reason: where,
        );
        expect(
          identical(tester.widget(_key('stats-played')), played),
          isTrue,
          reason: where,
        );
      }

      await expectStill('All Games');
      await _choose(tester, StatsScope.variations);
      await expectStill('Variations');
      expect(_key('stats-view-variations'), findsOneWidget);
      await _closeApp(tester);
    });

    testWidgets('the cards cross-fade with the theme rather than snap at its '
        'middle', (tester) async {
      _setView(tester, size: const Size(891, 411), scale: 1.0);
      final state = await _openStats(tester);
      final night = _cardFill(tester, 'stats-played');
      final feedback = FeedbackSettings();
      addTearDown(feedback.dispose);
      await tester.pumpWidget(
        statsApp(
          state,
          feedback,
          const LobbyScreen(),
          brightness: Brightness.light,
        ),
      );
      // A third of the way through: the theme's brightness is still dark,
      // and the cards have already set off towards day.
      await tester.pump(const Duration(milliseconds: 60));
      final early = _cardFill(tester, 'stats-played');
      expect(
        Theme.of(tester.element(_key('stats-played'))).brightness,
        Brightness.dark,
      );
      expect(early, isNot(night));
      await tester.pump(const Duration(seconds: 1));
      final day = _cardFill(tester, 'stats-played');
      expect(early, isNot(day));
      expect(day, isNot(night));
      await _closeApp(tester);
    });
  });

  // Hand results in four, five and six figures, and all seven variations,
  // on the phones where a count once squeezed its hand's name into an
  // ellipsis — in every language, by night and by day.
  group('fits with the largest counts', () {
    for (final size in const [Size(592, 360), Size(640, 360), Size(891, 411)]) {
      for (final b in Brightness.values) {
        for (final lang in AppLang.values) {
          final where =
              '${size.width.toInt()}x${size.height.toInt()} x1.25 '
              '${b.name} ${lang.name}';
          testWidgets(where, (tester) async {
            _setView(tester, size: size, scale: 1.25);
            await _openStats(
              tester,
              lang: lang,
              brightness: b,
              me: bigCountsJson(),
            );
            for (final scope in [StatsScope.teenPatti, StatsScope.variations]) {
              await _choose(tester, scope);
              _expectFits(tester, '$where ${scope.name}');
              for (final (i, field) in HandTally.fields.indexed) {
                // Never a word broken: a name takes no more lines than it
                // has words ("Sequen" over "ce" at 592dp, once).
                final name = tester.renderObject<RenderParagraph>(
                  find.descendant(
                    of: _textIn('stats-hand-$field', HandTally.names[i]),
                    matching: find.byType(RichText),
                    matchRoot: true,
                  ),
                );
                final lines = {
                  for (final b in name.getBoxesForSelection(
                    TextSelection(
                      baseOffset: 0,
                      extentOffset: HandTally.names[i].length,
                    ),
                  ))
                    b.top.round(),
                };
                expect(
                  lines.length,
                  lessThanOrEqualTo(HandTally.names[i].split(' ').length),
                  reason: '$where ${scope.name} $field broken',
                );
                final cell = tester.getRect(_key('stats-hand-$field'));
                for (final p in _paragraphs(
                  tester,
                  _key('stats-hand-$field'),
                )) {
                  final r = _onScreen(p);
                  expect(
                    r.right,
                    lessThanOrEqualTo(cell.right + 0.5),
                    reason: '$where ${scope.name} $field "${_plain(p)}"',
                  );
                }
              }
              await _scrollToEnd(tester);
              _expectFits(tester, '$where ${scope.name} end');
              final position = tester
                  .state<ScrollableState>(
                    _inDrawer(find.byType(Scrollable)).first,
                  )
                  .position;
              position.jumpTo(0);
              await tester.pump(const Duration(milliseconds: 100));
            }
            await _closeApp(tester);
          });
        }
      }
    }
  });

  group('the words', () {
    test('every new word is in all five languages, section names in capitals '
        'in English only', () {
      const keys = [
        'statsPerformance',
        'statsAllGames',
        'statsVariations',
        'statsScopeLabel',
        'statsHandResults',
        'statsNoHandResults',
        'statsNoVariationGames',
        'statsHandResultsHint',
        'statsVariationsHint',
      ];
      const english = Strings(AppLang.english);
      expect(english.statsPerformance, 'Performance');
      expect(english.statsAllGames, 'All Games');
      expect(english.statsVariations, 'Variations');
      expect(english.statsHandResults, 'Hand results');
      expect(english.statsNoHandResults, 'No hand results yet');
      expect(english.statsNoVariationGames, 'No variation games played yet');
      for (final lang in AppLang.values) {
        final t = Strings(lang);
        for (final key in keys) {
          final own = t.ownEntry(key);
          expect(own, isNotNull, reason: '${lang.name} $key');
          expect(own!.trim(), isNotEmpty);
          if (lang != AppLang.english) {
            expect(own, isNot(english.ownEntry(key)), reason: lang.name);
          }
          expect(own.toLowerCase(), isNot(contains('poker')));
          expect(own, isNot(contains(Strings(lang).poker)));
        }
        expect(
          [for (final s in StatsScope.values) statsScopeName(t, s)],
          [t.statsAllGames, friendlyName(t.teenPatti), t.statsVariations],
        );
      }
    });
  });

  // Every scope, the menu open and the drawer scrolled to its end, at every
  // size the app is checked on, at both text sizes, in every language, by
  // night and by day.
  group('fits', () {
    const sizes = [
      Size(592, 360),
      Size(640, 360),
      Size(844, 390),
      Size(915, 412),
      Size(1280, 800),
    ];
    for (final size in sizes) {
      for (final scale in const [1.0, 1.25]) {
        for (final b in Brightness.values) {
          for (final lang in AppLang.values) {
            final where =
                '${size.width.toInt()}x${size.height.toInt()} x$scale '
                '${b.name} ${lang.name}';
            testWidgets(where, (tester) async {
              _setView(tester, size: size, scale: scale);
              await _openStats(tester, lang: lang, brightness: b);
              // A drawer of its own width: never less than 300dp, never more
              // than 420, and never the whole screen.
              final drawer = tester.getRect(find.byType(Drawer));
              expect(drawer.width, inInclusiveRange(300, 420));
              expect(drawer.width, lessThan(size.width * 0.55));
              for (final scope in StatsScope.values) {
                await _choose(tester, scope);
                _expectFits(tester, '$where ${scope.name}');
                await _scrollToEnd(tester);
                _expectFits(tester, '$where ${scope.name} end');
                final position = tester
                    .state<ScrollableState>(
                      _inDrawer(find.byType(Scrollable)).first,
                    )
                    .position;
                position.jumpTo(0);
                await tester.pump(const Duration(milliseconds: 100));
              }
              await _openMenu(tester);
              final menu = tester.getRect(_key('stats-scope-menu'));
              expect(menu.right, lessThanOrEqualTo(size.width));
              expect(menu.left, greaterThanOrEqualTo(0));
              expect(menu.bottom, lessThanOrEqualTo(size.height));
              for (final p in _paragraphs(tester, _key('stats-scope-menu'))) {
                expect(p.didExceedMaxLines, isFalse, reason: _plain(p));
                final r = _onScreen(p);
                expect(r.right, lessThanOrEqualTo(menu.right + 0.5));
              }
              expect(tester.takeException(), isNull);
              await _closeApp(tester);
            });
          }
        }
      }
    }
  });

  group('another player\'s record is drawn as before', () {
    testWidgets('the Friends page profile', (tester) async {
      _setView(tester);
      final server = statsProfileServer();
      await http.runWithClient(() async {
        final state = signedInState();
        final feedback = FeedbackSettings();
        addTearDown(feedback.dispose);
        await tester.pumpWidget(
          statsApp(
            state,
            feedback,
            Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showFriends(context),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await _settlePage(tester);
        await tester.ensureVisible(_key('friend-u-meera'));
        await tester.pump();
        await tester.tap(_key('friend-u-meera'));
        await _settlePage(tester);
        _expectOldRecord(tester, find.byType(FriendsScreen), state.t);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        state.dispose();
      }, () => server.client);
    });

    testWidgets('a table\'s player drawer', (tester) async {
      _setView(tester);
      final server = statsTableServer();
      await http.runWithClient(() async {
        final state = statsTableState();
        final feedback = await silentFeedback();
        addTearDown(feedback.dispose);
        state.handleState(statsTableRoom());
        await tester.pumpWidget(
          tableApp(
            state: state,
            feedback: feedback,
            theme: statsTheme(Brightness.dark),
          ),
        );
        await tester.pump(const Duration(milliseconds: 900));
        await tester.pump(const Duration(milliseconds: 900));
        await tester.tap(_plaqueOf('u1'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 100));
        _expectOldRecord(tester, find.byType(PlayerDrawer), state.t);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 10));
        state.dispose();
      }, () => server.client);
    });
  });
}
