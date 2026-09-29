// The player's level and XP bar at the top of the lobby (owner, 27 Sep 2026:
// "In the Lobby on Top show current level of player and xp progress bar for
// next level"): under the name in the top bar, the level's mark and number,
// the figure toward the next level and a slim gold bar — MAX LEVEL and a full
// bar at the top of the ladder, no bar until the ladder says where the level
// starts. Held here: what it shows from the account at levels 1, 10, 49 and
// 50; a `player:level` push moving it, the bar animating; the one-second tick
// never rebuilding it; a tap opening the level screen with the lobby's click;
// what a screen reader hears; and, at seven screens, text x1.0 and x1.25, all
// five languages and both themes, that nothing overflows, the name keeps
// every dp it had without the level (the layout master draws), and the
// wallets stand exactly where and as wide as they did.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/widgets/level_art.dart';
import 'package:teenpatti/widgets/level_screen.dart';
import 'package:teenpatti/widgets/lobby_level_bar.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'level_fixtures.dart';

/// Every lobby click, counted.
class _Heard extends FeedbackSettings {
  int clicks = 0;

  @override
  void cardClick() => clicks++;
}

/// The account as a player usually finds the lobby: a guest's generated name
/// and the 4-hour bonus counting down, the bar's widest neighbour of the name.
User _user(Map<String, Object?>? level, {String name = 'Guest0E00B'}) =>
    User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': name,
      'chips': 324500,
      'diamond': 9,
      'hammer': 20,
      'missile': 1,
      'playerLevel': ?level,
      'badges': [regularBadge()],
      'rewards': {
        'bonusReward': 10000,
        'bonusReadyAt': DateTime.now()
            .add(const Duration(hours: 3, minutes: 12))
            .millisecondsSinceEpoch,
        'bonusAvailable': false,
        'milestoneReward': 25000,
        'handsToNextMilestone': 25,
      },
    });

Future<_Heard> _pump(
  WidgetTester tester,
  GameState state, {
  Size screen = const Size(891, 411),
  double scale = 1.0,
  bool dark = true,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final heard = _Heard();
  addTearDown(heard.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: heard),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: levelTheme(dark: dark),
        builder: (context, child) => GlassBudget(child: child!),
        home: const LobbyScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
  return heard;
}

GameState _state({
  Map<String, Object?>? level,
  bool withLadder = true,
  AppLang lang = AppLang.english,
  String name = 'Guest0E00B',
}) {
  final state = levelState(
    level: level ?? levelAt(10, xp: 4180),
    lang: lang,
    withLadder: withLadder,
  );
  state.user = _user(level ?? levelAt(10, xp: 4180), name: name);
  return state;
}

void _notify(GameState state) {
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  state.notifyListeners();
}

final _bar = find.byKey(const ValueKey('lobby-level-bar'));
final _progress = find.byKey(const ValueKey('lobby-level-progress'));
final _figure = find.byKey(const ValueKey('lobby-level-xp'));
final _tag = find.byKey(const ValueKey('lobby-level-tag'));

String _text(WidgetTester tester, Finder f) =>
    tester.renderObject<RenderParagraph>(f).text.toPlainText();

double _target(WidgetTester tester) =>
    tester.widget<LevelBar>(_progress).fraction;

/// The fill the bar draws right now, mid-animation included.
double _drawn(WidgetTester tester) => tester
    .widget<FractionallySizedBox>(
      find.descendant(
        of: _progress,
        matching: find.byType(FractionallySizedBox),
      ),
    )
    .widthFactor!;

Finder _private(String type) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

void main() {
  setUpAll(() async {
    await loadLevelFonts();
    primeBadges();
  });
  tearDownAll(PictureCache.clearMemory);

  group('from the account', () {
    for (final (n, xp, figure, fraction) in [
      (1, 23, '23 / 100 XP', 0.23),
      (10, 4180, '4,180 / 5,200 XP', 0.15),
      (49, 1850000, '18.5 Lakh / 20 Lakh XP', 0.625),
      (50, 2150000, 'MAX LEVEL', 1.0),
    ]) {
      testWidgets('level $n: the art, the number, "$figure" and a bar at '
          '$fraction', (tester) async {
        final state = _state(level: levelAt(n, xp: xp));
        await _pump(tester, state);
        // The level's art before the word where the owner has sent it (29
        // Sep 2026), and never the emoji; the word alone where not yet.
        expect(_text(tester, _tag), 'Lv $n');
        final art = find.byKey(const ValueKey('lobby-level-art'));
        if (n <= levelsWithArt) {
          expect(art, findsOneWidget, reason: 'level $n has art');
          expect(tester.widget<LevelArt>(art).assetUrl, levelArtUrl(n));
          expect(
            tester.getRect(art).right,
            lessThanOrEqualTo(tester.getRect(_tag).left),
            reason: 'the art stands before the word',
          );
        } else {
          expect(art, findsNothing, reason: 'level $n has none yet');
        }
        expect(_text(tester, _figure), figure);
        expect(_target(tester), closeTo(fraction, 1e-9));
        // Settled: the bar draws what it says.
        await tester.pump(const Duration(seconds: 1));
        expect(_drawn(tester), closeTo(fraction, 1e-9));
        // It is the SAME progress the level screen draws.
        expect(
          levelProgressOf(state.user!.playerLevel!, state.levelLadder),
          closeTo(fraction, 1e-9),
        );
        await unmountLevel(tester, state);
      });
    }

    testWidgets('a screen reader hears the level and the XP as one button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final state = _state();
      await _pump(tester, state);
      expect(
        tester.getSemantics(_bar),
        matchesSemantics(
          label: 'Level 10, 4,180 of 5,200 XP',
          isButton: true,
          hasTapAction: true,
        ),
      );
      state.user = _user(levelAt(50, xp: 2150000));
      _notify(state);
      await tester.pump();
      expect(
        tester.getSemantics(_bar),
        matchesSemantics(
          label: 'Level 50, 21.5 Lakh XP, top level',
          isButton: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
      await unmountLevel(tester, state);
    });

    testWidgets('without a level (a server from before levels) there is no '
        'line, and the name block is as it always was', (tester) async {
      final state = _state()..user = _user(null);
      await _pump(tester, state);
      expect(_bar, findsNothing);
      expect(find.byKey(const ValueKey('lobby-name-block')), findsNothing);
      expect(find.text('Guest0E00B'), findsOneWidget);
      await unmountLevel(tester, state);
    });
  });

  group('the ladder', () {
    testWidgets('not read yet: the level and the figure, no bar; the bar '
        'grows in once it arrives', (tester) async {
      final state = _state(withLadder: false);
      await _pump(tester, state);
      expect(_text(tester, _tag), contains('Lv 10'));
      expect(_text(tester, _figure), '4,180 / 5,200 XP');
      expect(_progress, findsNothing);

      state.levelLadder = ladder();
      _notify(state);
      await tester.pump();
      expect(_progress, findsOneWidget);
      expect(_drawn(tester), lessThan(0.15));
      await tester.pump(const Duration(seconds: 1));
      expect(_drawn(tester), closeTo(0.15, 1e-9));
      await unmountLevel(tester, state);
    });

    testWidgets('the top level needs no ladder: a full bar and MAX LEVEL', (
      tester,
    ) async {
      final state = _state(level: levelAt(50, xp: 2150000), withLadder: false);
      await _pump(tester, state);
      expect(_text(tester, _figure), 'MAX LEVEL');
      expect(_target(tester), 1.0);
      await unmountLevel(tester, state);
    });
  });

  group('moving', () {
    testWidgets('a player:level push moves the figure and animates the bar', (
      tester,
    ) async {
      final state = _state();
      await _pump(tester, state);
      expect(_drawn(tester), closeTo(0.15, 1e-9));

      state.handlePlayerLevel(
        Standing.maybe({
          'playerLevel': levelAt(10, xp: 4800),
          'badges': [regularBadge()],
          'taxBps': 1743,
        })!,
      );
      await tester.pump();
      expect(_text(tester, _figure), '4,800 / 5,200 XP');
      await tester.pump(const Duration(milliseconds: 150));
      final mid = _drawn(tester);
      expect(mid, greaterThan(0.15));
      expect(mid, lessThan(4 / 6));
      await tester.pump(const Duration(seconds: 1));
      expect(_drawn(tester), closeTo(4 / 6, 1e-9));

      // Up a level: the new level's own figures, and a bar that fills from
      // empty to them — never one that drains from the old level's fill,
      // which would read as XP lost.
      state.handlePlayerLevel(
        Standing.maybe({
          'playerLevel': levelAt(11, xp: 5300),
          'badges': [regularBadge()],
          'taxBps': 1714,
        })!,
      );
      await tester.pump();
      var last = _drawn(tester);
      expect(last, lessThanOrEqualTo(100 / 1500 + 1e-9));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 70));
        final now = _drawn(tester);
        expect(now, greaterThanOrEqualTo(last - 1e-9), reason: 'frame $i');
        last = now;
      }
      await tester.pump(const Duration(seconds: 1));
      expect(_text(tester, _tag), contains('Lv 11'));
      expect(_text(tester, _figure), '5,300 / 6,700 XP');
      expect(_drawn(tester), closeTo(100 / 1500, 1e-9));
      await unmountLevel(tester, state);
    });

    testWidgets('the lobby\'s one-second tick never rebuilds it, nor does a '
        'fresh copy of the same account', (tester) async {
      final state = _state();
      await _pump(tester, state);
      final before = LobbyLevelBar.builds;
      // The ticks the reward clocks make, and a `me()` re-read.
      for (var i = 0; i < 5; i++) {
        _notify(state);
        await tester.pump(const Duration(seconds: 1));
      }
      state.user = _user(levelAt(10, xp: 4180));
      _notify(state);
      await tester.pump(const Duration(seconds: 1));
      expect(LobbyLevelBar.builds, before);
      // The top bar did rebuild meanwhile (its bonus counts down).
      expect(find.textContaining('3h 1'), findsOneWidget);

      // XP moving does rebuild it.
      state.user = _user(levelAt(10, xp: 4200));
      _notify(state);
      await tester.pump();
      expect(LobbyLevelBar.builds, greaterThan(before));
      await unmountLevel(tester, state);
    });
  });

  group('the tap', () {
    for (final (what, finder) in [
      ('the level line', _bar),
      ('the name', find.text('Guest0E00B')),
    ]) {
      testWidgets('on $what opens the level screen, with the lobby\'s click', (
        tester,
      ) async {
        final state = _state();
        final heard = await _pump(tester, state);
        expect(find.byType(LevelScreen), findsNothing);
        await tester.tap(finder);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 800));
        expect(find.byType(LevelScreen), findsOneWidget);
        expect(heard.clicks, 1);
        await unmountLevel(tester, state);
      });
    }

    testWidgets('the foot\'s level key is still there', (tester) async {
      final state = _state();
      await _pump(tester, state);
      expect(find.byKey(const ValueKey('level-key')), findsOneWidget);
      await unmountLevel(tester, state);
    });
  });

  group('layout', () {
    const screens = [
      Size(592, 360),
      Size(640, 360),
      Size(732, 412),
      Size(844, 390),
      Size(891, 411),
      Size(915, 412),
      Size(1280, 800),
    ];
    for (final screen in screens) {
      for (final scale in const [1.0, 1.25]) {
        final label =
            '${screen.width.toInt()}x${screen.height.toInt()} x$scale';
        testWidgets('at $label, in every language and both themes: nothing '
            'overflows, the name keeps its width and the wallets theirs', (
          tester,
        ) async {
          var smallest = 1.0;
          addTearDown(
            // ignore: avoid_print
            () => print('LAYOUT $label: smallest figure scale $smallest'),
          );
          for (final lang in AppLang.values) {
            for (final dark in [true, false]) {
              for (final name in ['Guest0E00B', 'विक्रमादित्य सिंह राठौड़']) {
                final where =
                    '$label ${lang.code} '
                    '${dark ? 'dark' : 'light'} "$name"';

                // The layout without a level — exactly what master draws.
                final plain = _state(lang: lang, name: name)
                  ..user = _user(null, name: name);
                await _pump(
                  tester,
                  plain,
                  screen: screen,
                  scale: scale,
                  dark: dark,
                );
                expect(tester.takeException(), isNull, reason: where);
                final plainName = tester.getRect(find.text(name));
                final plainWallet = tester.getRect(_private('_WalletPill'));
                await unmountLevel(tester, plain);

                final state = _state(
                  level: levelAt(49, xp: 1850000),
                  lang: lang,
                  name: name,
                );
                await _pump(
                  tester,
                  state,
                  screen: screen,
                  scale: scale,
                  dark: dark,
                );
                expect(tester.takeException(), isNull, reason: where);

                final nameRect = tester.getRect(find.text(name));
                expect(
                  nameRect.width,
                  greaterThanOrEqualTo(plainName.width - 0.01),
                  reason: '$where: the name lost width',
                );
                final wallet = tester.getRect(_private('_WalletPill'));
                expect(wallet, plainWallet, reason: '$where: the wallets');

                // The level's words are whole and inside the bar, under the
                // name and clear of the wallets.
                for (final f in [_tag, _figure]) {
                  final p = tester.renderObject<RenderParagraph>(f);
                  expect(p.didExceedMaxLines, isFalse, reason: where);
                }
                final line = tester.getRect(_bar);
                final rail = tester.getRect(_private('_TopBar'));
                expect(
                  line.top,
                  greaterThanOrEqualTo(nameRect.bottom - 0.5),
                  reason: where,
                );
                expect(
                  line.bottom,
                  lessThanOrEqualTo(rail.bottom),
                  reason: where,
                );
                expect(line.top, greaterThanOrEqualTo(rail.top), reason: where);
                expect(
                  line.right,
                  lessThanOrEqualTo(wallet.left),
                  reason: where,
                );
                expect(line.left, closeTo(nameRect.left, 0.5), reason: where);
                // The figure is legible: never scaled below 70% of its size.
                final figure = tester.getRect(_figure);
                final scaleOf =
                    figure.height /
                    tester.renderObject<RenderParagraph>(_figure).size.height;
                expect(scaleOf, greaterThan(0.7), reason: where);
                smallest = scaleOf < smallest ? scaleOf : smallest;
                await unmountLevel(tester, state);
              }
            }
          }
        });
      }
    }
  });
}
