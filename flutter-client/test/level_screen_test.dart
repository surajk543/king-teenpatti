// The level screen (27 Sep 2026): the lobby's level key's popup, polished —
// UI only. Everything on it is the server's figure; this holds that the
// screen reads it truthfully and lays it out cleanly.
//
// Held here: My level at levels 1, 2, 10, 25 and 50 (the top: MAX LEVEL, no
// next level); the Winning Tax with the rate the account says; "23 / 100 XP"
// and "77 XP to Rookie" and the bar's fraction from the ladder; a Royal
// badge's Lottie and the time its grant has left, one about to run out, and
// one that runs out while the screen is open; a player with Regular alone;
// the Daily XP part-earned, complete ("Daily XP Complete" only when every
// source has been earned as often as it can be), not yet begun, and its
// reset counting down; the three play-time milestones shown as the ladder
// of rungs the server grants them as (each once a day, adding up — never
// "the highest only"); long level and badge names; the tabs' underline
// sliding; the one-second lobby tick rebuilding neither a Lottie nor the
// bar; the table's popup still two panes; and every tab at 592x360,
// 640x360, 844x390, 915x412 and 1280x800, text x1.0 and x1.25, in all five
// languages and both themes, with nothing overflowing and nothing cut.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/level_art.dart';
import 'package:teenpatti/widgets/level_screen.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/table_tax.dart';

import 'level_fixtures.dart';

String _text(WidgetTester tester, Key key) {
  final finder = find.byKey(key, skipOffstage: false);
  final widget = tester.widget(finder);
  if (widget is Text) return widget.data ?? widget.textSpan!.toPlainText();
  return (tester.widget<Text>(
    find.descendant(of: finder, matching: find.byType(Text)).first,
  )).data!;
}

/// Every paragraph under [of] that ran out of lines, by its words.
List<String> _cut(Finder of) => [
  for (final e
      in find
          .descendant(
            of: of,
            matching: find.byType(RichText, skipOffstage: false),
          )
          .evaluate())
    if ((e.renderObject! as RenderParagraph).didExceedMaxLines)
      (e.widget as RichText).text.toPlainText(),
];

/// How far each FittedBox under [of] has shrunk what it holds (1 = not at
/// all), by the box's first words.
Map<String, double> _fitScales(WidgetTester tester, Finder of) => {
  for (final e
      in find
          .descendant(
            of: of,
            matching: find.byType(FittedBox, skipOffstage: false),
          )
          .evaluate())
    if ((e.renderObject! as RenderBox) case final RenderBox box
        when box.hasSize && box.size.width > 0)
      if ((box as RenderProxyBox).child case final RenderBox child?
          when child.hasSize && child.size.width > 0)
        _firstWords(e): math.min(
          1.0,
          math.min(
            box.size.width / child.size.width,
            box.size.height / child.size.height,
          ),
        ),
};

String _firstWords(Element e) {
  String? words;
  void visit(Element child) {
    if (words != null) return;
    final w = child.widget;
    if (w is RichText) {
      words = w.text.toPlainText();
      return;
    }
    child.visitChildren(visit);
  }

  e.visitChildren(visit);
  return words ?? '${e.widget.key ?? e.widget.runtimeType}#${e.hashCode}';
}

/// The widget types rebuilt while [body] runs.
Future<Set<Type>> _rebuiltDuring(Future<void> Function() body) async {
  final rebuilt = <Type>{};
  final before = debugOnRebuildDirtyWidget;
  debugOnRebuildDirtyWidget = (element, _) =>
      rebuilt.add(element.widget.runtimeType);
  try {
    await body();
  } finally {
    debugOnRebuildDirtyWidget = before;
  }
  return rebuilt;
}

/// The account the fixtures build, swapped in while the screen is open.
Future<void> _swapUser(
  WidgetTester tester,
  GameState state, {
  required Map<String, Object?> level,
  List<Map<String, Object?>>? badges,
  int? taxBps,
}) async {
  state.user = playerUser(level: level, badges: badges, taxBps: taxBps);
  // ignore: invalid_use_of_protected_member
  state.notifyListeners();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Finder _inScreen(Finder f) =>
    find.descendant(of: find.byType(LevelScreen), matching: f);

double _barFraction(WidgetTester tester, Key key) => tester
    .widget<FractionallySizedBox>(
      find.descendant(
        of: find.byKey(key),
        matching: find.byType(FractionallySizedBox),
      ),
    )
    .widthFactor!;

Future<GameState> _open(
  WidgetTester tester, {
  required Map<String, Object?> level,
  List<Map<String, Object?>>? badges,
  int? taxBps,
  String tab = 'mine',
  Size screen = const Size(891, 411),
  double scale = 1.0,
  bool dark = true,
  AppLang lang = AppLang.english,
  bool withLadder = true,
  bool withMissions = false,
  List<(int, int, String, String, int)> levels = ownersLevels,
}) async {
  final state = levelState(
    level: level,
    badges: badges,
    taxBps: taxBps,
    lang: lang,
    withLadder: withLadder,
    ladderRead: ladder(levels: levels, withMissions: withMissions),
  );
  await pumpLevelLobby(tester, state, screen: screen, scale: scale, dark: dark);
  await openLevelScreen(tester);
  if (tab != 'mine') await showLevelTab(tester, tab);
  return state;
}

/// The table's tax popup, opened over a bare page at [size] and [scale].
Future<void> _pumpTablePopup(
  WidgetTester tester,
  GameState state,
  Size size,
  double scale,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        theme: levelTheme(),
        builder: (context, child) => GlassBudget(child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open'),
              onPressed: () => showWinningTaxInfo(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  setUpAll(() async {
    await loadLevelFonts();
    primeBadges();
  });
  tearDownAll(PictureCache.clearMemory);

  group('My level', () {
    for (final (n, xp) in [(1, 23), (2, 150), (10, 4180), (25, 94400)]) {
      testWidgets('level $n: the hero, the Winning Tax, the XP and the next '
          'level, all from the data', (tester) async {
        final state = await _open(tester, level: levelAt(n, xp: xp));
        final t = state.t;
        final (_, minXp, title, _, bps) = ownersLevels[n - 1];
        final next = ownersLevels[n];
        expect(find.text(t.levelNumber(n)), findsOneWidget);
        expect(_text(tester, const ValueKey('level-hero-title')), title);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('level-emblem-number')),
            matching: find.text('$n'),
          ),
          findsOneWidget,
        );
        // The medal holds the level's art (29 Sep 2026), drawn — never the
        // emoji; empty where the owner has sent none yet.
        final emblem = tester.widget<LevelArt>(
          find.byKey(const ValueKey('level-emblem-art')),
        );
        expect(emblem.assetUrl, n <= levelsWithArt ? levelArtUrl(n) : '');
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('level-emblem-art')),
            matching: find.byKey(
              ValueKey(n <= levelsWithArt ? 'level-art' : 'level-art-empty'),
            ),
          ),
          findsOneWidget,
        );
        expect(find.text(ownersLevels[n - 1].$4), findsNothing);
        // Winning Tax, with the rate the account pays and what sets it.
        final rate = find.byKey(const ValueKey('winning-tax-rate'));
        expect(
          find.descendant(of: rate, matching: find.text('Winning Tax')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: rate, matching: find.text(formatTaxRate(bps))),
          findsOneWidget,
        );
        expect(
          find.descendant(of: rate, matching: find.text(t.rateSetByLevel)),
          findsOneWidget,
        );
        // XP against the next level's threshold, what is left, the bar from
        // this level's threshold, the next level and its rate.
        expect(
          _text(tester, const ValueKey('level-xp-of')),
          '${formatChips(xp)} / ${formatChips(next.$2)} XP',
        );
        expect(
          _text(tester, const ValueKey('level-xp-to-next')),
          t.xpToNext(formatChips(next.$2 - xp), next.$3),
        );
        expect(
          _barFraction(tester, const ValueKey('winning-tax-progress')),
          moreOrLessEquals((xp - minXp) / (next.$2 - minXp), epsilon: 1e-9),
        );
        expect(
          _text(tester, const ValueKey('level-next')),
          t.levelNextLine(
            t.levelName(next.$1, next.$3),
            formatChips(next.$2),
            formatTaxRate(next.$5),
          ),
        );
        expect(find.byKey(const ValueKey('level-max')), findsNothing);
        await unmountLevel(tester, state);
      });
    }

    testWidgets('level 1 at 23 XP reads "23 / 100 XP" and "77 XP to '
        'Rookie"', (tester) async {
      final state = await _open(tester, level: levelAt(1, xp: 23));
      expect(_text(tester, const ValueKey('level-xp-of')), '23 / 100 XP');
      expect(
        _text(tester, const ValueKey('level-xp-to-next')),
        '77 XP to Rookie',
      );
      expect(
        _barFraction(tester, const ValueKey('winning-tax-progress')),
        moreOrLessEquals(0.23),
      );
      await unmountLevel(tester, state);
    });

    testWidgets('level 50 is MAX LEVEL: no next level, a full bar, the top '
        'noted', (tester) async {
      final state = await _open(tester, level: levelAt(50, xp: 2150000));
      final t = state.t;
      expect(find.byKey(const ValueKey('level-max')), findsOneWidget);
      // In the screen: the lobby's top bar behind it says MAX LEVEL too
      // (lobby_level_bar_test).
      expect(_inScreen(find.text(t.levelMax)), findsOneWidget);
      expect(find.byKey(const ValueKey('level-next')), findsNothing);
      expect(
        _text(tester, const ValueKey('level-xp-of')),
        '${formatChips(2150000)} XP',
      );
      expect(_text(tester, const ValueKey('level-xp-to-next')), t.topLevelNote);
      expect(_barFraction(tester, const ValueKey('winning-tax-progress')), 1.0);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('winning-tax-rate')),
          matching: find.text('6%'),
        ),
        findsOneWidget,
      );
      await unmountLevel(tester, state);
    });

    testWidgets('before the ladder is read the XP is named and the bar waits', (
      tester,
    ) async {
      final state = await _open(
        tester,
        level: levelAt(10, xp: 4180),
        withLadder: false,
      );
      expect(_text(tester, const ValueKey('level-xp-of')), '4,180 / 5,200 XP');
      expect(_barFraction(tester, const ValueKey('winning-tax-progress')), 0.0);
      await unmountLevel(tester, state);
    });
  });

  group('badges', () {
    testWidgets('an active Royal badge: its Lottie, its rate, the time its '
        'grant has left, and that it sets the rate', (tester) async {
      final state = await _open(
        tester,
        level: levelAt(10, xp: 4180),
        badges: [
          regularBadge(),
          royalBadge('ROYAL_KING', const Duration(days: 12, hours: 1)),
        ],
        taxBps: 0,
      );
      final t = state.t;
      final card = find.byKey(const ValueKey('my-badge-ROYAL_KING'));
      expect(card, findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('badge-art-ROYAL_KING')),
          matching: find.byType(LottieBuilder),
        ),
        findsOneWidget,
      );
      // Days and hours left, from the real expiry (brief §21).
      expect(
        _text(tester, const ValueKey('badge-grant-ROYAL_KING')),
        anyOf(
          t.timeLeft('12${t.unitDayShort} 1${t.unitHourShort}'),
          t.timeLeft('12${t.unitDayShort} 0${t.unitHourShort}'),
        ),
      );
      expect(
        find.descendant(of: card, matching: find.text(t.badgeTaxLine('0%'))),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('badge-sets-rate-ROYAL_KING')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('winning-tax-rate')),
          matching: find.text(t.rateSetByBadge('Royal King')),
        ),
        findsOneWidget,
      );
      // Regular is lifetime; no store hint for a Royal holder.
      expect(
        _text(tester, const ValueKey('badge-grant-REGULAR')),
        t.badgeLifetime,
      );
      expect(find.byKey(const ValueKey('royal-badge-hint')), findsNothing);
      // Held, running: Active — in words, not colour alone.
      expect(
        find.byKey(const ValueKey('badge-active-ROYAL_KING')),
        findsOneWidget,
      );
      await unmountLevel(tester, state);
    });

    testWidgets('a grant within a day of its end says "Expires in …"', (
      tester,
    ) async {
      final state = await _open(
        tester,
        level: levelAt(10, xp: 4180),
        badges: [
          regularBadge(),
          royalBadge('ROYAL_ACE', const Duration(hours: 5, minutes: 10)),
        ],
        taxBps: 0,
      );
      final t = state.t;
      // Near its end a grant is counted in hours and minutes.
      expect(
        _text(tester, const ValueKey('badge-grant-ROYAL_ACE')),
        anyOf(
          t.badgeExpiresIn('5${t.unitHourShort} 10${t.unitMinuteShort}'),
          t.badgeExpiresIn('5${t.unitHourShort} 9${t.unitMinuteShort}'),
        ),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('my-badge-ROYAL_ACE')),
          matching: find.byIcon(Icons.warning_amber_rounded),
        ),
        findsOneWidget,
      );
      await unmountLevel(tester, state);
    });

    testWidgets('a grant of 30 days or more still counts down in days and '
        'hours, never an end date', (tester) async {
      final state = await _open(
        tester,
        level: levelAt(10, xp: 4180),
        badges: [
          regularBadge(),
          royalBadge('ROYAL_KING_OF_KINGS', const Duration(days: 90)),
          royalBadge('ROYAL_MASTER', const Duration(days: 30, hours: 14)),
        ],
        taxBps: 0,
      );
      final t = state.t;
      expect(
        _text(tester, const ValueKey('badge-grant-ROYAL_KING_OF_KINGS')),
        t.timeLeft('89${t.unitDayShort} 23${t.unitHourShort}'),
      );
      expect(
        _text(tester, const ValueKey('badge-grant-ROYAL_MASTER')),
        anyOf(
          t.timeLeft('30${t.unitDayShort} 14${t.unitHourShort}'),
          t.timeLeft('30${t.unitDayShort} 13${t.unitHourShort}'),
        ),
      );
      await unmountLevel(tester, state);
    });

    testWidgets('a grant that runs out while the screen is open says Expired '
        'and dims, and the hero stops counting it at the same moment', (
      tester,
    ) async {
      final state = await _open(
        tester,
        level: levelAt(10, xp: 4180),
        badges: [
          regularBadge(),
          royalBadge('ROYAL_ACE', const Duration(days: 5)),
        ],
        taxBps: 0,
      );
      final t = state.t;
      // The grant's clock starts only once the screen is up and warm, so how
      // long the first open takes cannot eat into it.
      await _swapUser(
        tester,
        state,
        level: levelAt(10, xp: 4180),
        badges: [
          regularBadge(),
          royalBadge('ROYAL_ACE', const Duration(seconds: 4)),
        ],
        taxBps: 0,
      );
      final rate = find.byKey(const ValueKey('winning-tax-rate'));
      expect(
        _text(tester, const ValueKey('badge-grant-ROYAL_ACE')),
        t.badgeExpiresIn('1${t.unitMinuteShort}'),
      );
      expect(
        find.byKey(const ValueKey('badge-active-ROYAL_ACE')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: rate, matching: find.text('0%')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: rate,
          matching: find.text(t.rateSetByBadge('Royal Ace')),
        ),
        findsOneWidget,
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 4300)),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        _text(tester, const ValueKey('badge-grant-ROYAL_ACE')),
        t.badgeExpired,
      );
      final opacity = tester.widget<AnimatedOpacity>(
        find.ancestor(
          of: find.byKey(const ValueKey('badge-grant-ROYAL_ACE')),
          matching: find.byType(AnimatedOpacity),
        ),
      );
      expect(opacity.opacity, 0.5);
      expect(
        find.byKey(const ValueKey('badge-active-ROYAL_ACE')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('badge-sets-rate-ROYAL_ACE')),
        findsNothing,
      );
      // The hero no longer says 0% from a badge that has run out: the lower
      // of the level's rate (17.43%) and Regular's (20%), set by the level.
      expect(
        find.descendant(of: rate, matching: find.text('0%')),
        findsNothing,
      );
      expect(
        find.descendant(of: rate, matching: find.text('17.43%')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: rate, matching: find.text(t.rateSetByLevel)),
        findsOneWidget,
      );
      await unmountLevel(tester, state);
    });

    testWidgets('a player with Regular alone is shown it, lifetime, and '
        'where the Royal badges are', (tester) async {
      final state = await _open(tester, level: levelAt(1, xp: 23));
      expect(find.byKey(const ValueKey('my-badge-REGULAR')), findsOneWidget);
      expect(find.byType(HeldBadgeCard), findsOneWidget);
      expect(find.byKey(const ValueKey('royal-badge-hint')), findsOneWidget);
      expect(find.byKey(const ValueKey('royal-badge-store')), findsOneWidget);
      final t = state.t;
      // The hint's rate is the catalogue's, never a figure of the app's own.
      expect(
        find.text(t.badgeRoyalHint('0%'), skipOffstage: false),
        findsOneWidget,
      );
      // How the tax works, a line each; the floor from the menu.
      for (final line in [
        t.taxNoteWinner,
        t.taxNoteNet,
        t.winningTaxFrom('50 Lakh'),
        t.winningTaxFalls,
        t.taxNoteBadge,
      ]) {
        expect(find.text(line, skipOffstage: false), findsOneWidget);
      }
      await unmountLevel(tester, state);
    });

    testWidgets('the catalogue marks a Royal badge the viewer holds, with its '
        'time left, and keeps Regular unmarked', (tester) async {
      final state = await _open(
        tester,
        level: levelAt(10, xp: 4180),
        badges: [
          regularBadge(),
          royalBadge('ROYAL_ACE', const Duration(days: 5, hours: 1)),
        ],
        taxBps: 0,
        tab: 'ladder',
      );
      final t = state.t;
      bool lit(String code) => tester
          .widget<CatalogueBadgeRow>(
            find.byKey(ValueKey('ladder-badge-$code'), skipOffstage: false),
          )
          .lit;
      expect(lit('ROYAL_ACE'), isTrue);
      expect(lit('REGULAR'), isFalse);
      expect(lit('ROYAL_KING'), isFalse);
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey('ladder-badge-ROYAL_KING'),
            skipOffstage: false,
          ),
          matching: find.text(
            '${t.badgeLasts(15)} · ₹999',
            skipOffstage: false,
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.text(t.badgesBesideLevel, skipOffstage: false),
        findsOneWidget,
      );
      await unmountLevel(tester, state);
    });
  });

  group('Daily XP', () {
    testWidgets('part earned: the XP earned today, the reached milestones, '
        'the hands ticked, and not complete', (tester) async {
      final state = await _open(
        tester,
        level: levelAt(
          10,
          xp: 4180,
          claimed: ['PLAY_15_MIN', 'PLAY_60_MIN', 'WIN_PAIR'],
        ),
        tab: 'daily',
      );
      expect(_text(tester, const ValueKey('daily-xp-earned')), '24 / 108 XP');
      expect(
        _barFraction(tester, const ValueKey('daily-bar')),
        moreOrLessEquals(24 / 108),
      );
      expect(find.byKey(const ValueKey('daily-complete')), findsNothing);
      Finder earned(String name) =>
          find.byKey(ValueKey('xp-earned-$name'), skipOffstage: false);
      expect(earned('Play 15 active minutes'), findsOneWidget);
      expect(earned('Play 60 active minutes'), findsOneWidget);
      expect(earned('Play 120 active minutes'), findsNothing);
      expect(earned('Win by Pair'), findsOneWidget);
      expect(earned('Win by Trail'), findsNothing);
      await unmountLevel(tester, state);
    });

    testWidgets('every source earned: Daily XP Complete', (tester) async {
      final state = await _open(
        tester,
        level: levelAt(10, xp: 4180, claimed: allSourceCodes),
        tab: 'daily',
      );
      final t = state.t;
      expect(_text(tester, const ValueKey('daily-xp-earned')), '108 / 108 XP');
      expect(find.byKey(const ValueKey('daily-complete')), findsOneWidget);
      expect(find.text(t.xpDailyComplete), findsOneWidget);
      await unmountLevel(tester, state);
    });

    testWidgets('Complete only when each source reaches its times: one that '
        'can be earned twice, earned once, keeps it open', (tester) async {
      final json = ladderJson();
      final sources = [
        for (final s in json['xpSources']! as List)
          {
            ...(s as Map<String, Object?>),
            if (s['code'] == 'WIN_TRAIL') 'times': 2,
          },
      ];
      final state = levelState(
        level: levelAt(10, xp: 4180, claimed: allSourceCodes),
        ladderRead: LevelLadder.maybe({...json, 'xpSources': sources}),
      );
      await pumpLevelLobby(tester, state);
      await openLevelScreen(tester);
      await showLevelTab(tester, 'daily');
      expect(find.byKey(const ValueKey('daily-complete')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('xp-source-WIN_TRAIL')),
          matching: find.text('1/2'),
        ),
        findsOneWidget,
      );
      await unmountLevel(tester, state);
    });

    testWidgets('the reset counts down by itself', (tester) async {
      final state = await _open(
        tester,
        level: levelAt(
          10,
          xp: 4180,
          claimed: ['WIN_PAIR'],
          resetsIn: const Duration(hours: 5),
        ),
        tab: 'daily',
      );
      final first = _text(tester, const ValueKey('daily-reset'));
      expect(first, startsWith('Resets in 4h 59m'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)),
      );
      await tester.pump(const Duration(seconds: 1));
      final later = _text(tester, const ValueKey('daily-reset'));
      expect(later, startsWith('Resets in 4h 59m'));
      expect(later, isNot(first));
      await unmountLevel(tester, state);
    });

    testWidgets('before the day\'s first hand: nothing earned, and the day '
        'starts with the next hand', (tester) async {
      final state = await _open(
        tester,
        level: levelAt(3, into: 40, resetsIn: null),
        tab: 'daily',
      );
      final t = state.t;
      expect(_text(tester, const ValueKey('daily-xp-earned')), '0 / 108 XP');
      expect(find.byKey(const ValueKey('daily-reset')), findsNothing);
      expect(_text(tester, const ValueKey('daily-idle')), t.xpWindowIdle);
      await unmountLevel(tester, state);
    });

    // The server grants every play-time rung the window's play has reached
    // (xpRules.played → AwardPlayTime: 3 + 20 + 50 at 120 minutes), so the
    // screen shows each rung earned on its own and never "the highest only".
    for (final (reached, claimed, xp) in [
      (15, ['PLAY_15_MIN'], 3),
      (60, ['PLAY_15_MIN', 'PLAY_60_MIN'], 23),
      (120, ['PLAY_15_MIN', 'PLAY_60_MIN', 'PLAY_120_MIN'], 73),
    ]) {
      testWidgets('the play-time track at $reached minutes: every rung '
          'reached ticked, $xp XP', (tester) async {
        final state = await _open(
          tester,
          level: levelAt(10, xp: 4180, claimed: claimed),
          tab: 'daily',
        );
        final t = state.t;
        for (final minutes in [15, 60, 120]) {
          expect(
            find.byKey(
              ValueKey('xp-earned-${t.xpPlayMinutes(minutes)}'),
              skipOffstage: false,
            ),
            minutes <= reached ? findsOneWidget : findsNothing,
            reason: '$minutes at $reached',
          );
        }
        expect(
          _text(tester, const ValueKey('daily-xp-earned')),
          '$xp / 108 XP',
        );
        expect(find.text(t.xpPlayTimeNote), findsOneWidget);
        // The gold track runs from the first rung to the last one reached.
        final fill = find.byKey(const ValueKey('play-track-fill'));
        expect(fill, reached == 15 ? findsNothing : findsOneWidget);
        await unmountLevel(tester, state);
      });
    }
  });

  group('All levels', () {
    testWidgets("every rung, the viewer's lit and in view, the next marked, "
        'and a key down to the badges', (tester) async {
      final state = await _open(
        tester,
        level: levelAt(25, xp: 94400),
        tab: 'ladder',
      );
      final rows = tester
          .widgetList<LevelRow>(find.byType(LevelRow, skipOffstage: false))
          .toList();
      expect(rows.length, 50);
      expect(
        [for (final r in rows) r.level.level],
        [for (var l = 1; l <= 50; l++) l],
      );
      expect(
        [
          for (final r in rows)
            if (r.you) r.level.level,
        ],
        [25],
      );
      final you = find.ancestor(
        of: find.byKey(const ValueKey('ladder-you')),
        matching: find.byType(LevelRow),
      );
      final pane = tester.getRect(
        find.byKey(const ValueKey('winning-tax-ladder')),
      );
      final row = tester.getRect(you);
      expect(
        pane.contains(row.topCenter) && pane.contains(row.bottomCenter),
        isTrue,
      );
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('ladder-next'), skipOffstage: false),
          matching: find.byType(LevelRow, skipOffstage: false),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<LevelRow>(
              find.ancestor(
                of: find.byKey(
                  const ValueKey('ladder-next'),
                  skipOffstage: false,
                ),
                matching: find.byType(LevelRow, skipOffstage: false),
              ),
            )
            .level
            .level,
        26,
      );

      await tester.tap(find.byKey(const ValueKey('ladder-jump-badges')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      final regular = tester.getRect(
        find.byKey(const ValueKey('ladder-badge-REGULAR')),
      );
      expect(pane.contains(regular.topCenter), isTrue);
      await unmountLevel(tester, state);
    });
  });

  group('names', () {
    const long = 'Supreme Grand Overlord of the Royal Kingdom';
    final levels = [(1, 0, long, '🔥🔱', 2000), ...ownersLevels.skip(1)];
    for (final (size, scale, lang) in [
      (const Size(592, 360), 1.25, AppLang.english),
      (const Size(891, 411), 1.0, AppLang.english),
      (const Size(592, 360), 1.25, AppLang.hindi),
      (const Size(592, 360), 1.25, AppLang.bengali),
    ]) {
      testWidgets('a long level name and a long badge name are never cut '
          '(${size.width.toInt()}, x$scale, ${lang.code})', (tester) async {
        final state = await _open(
          tester,
          lang: lang,
          level: levelAt(1, xp: 23, levels: levels),
          levels: levels,
          badges: [
            regularBadge(),
            royalBadge(
              'ROYAL_SUPREME_LONG',
              const Duration(days: 3),
              title: 'Royal Supreme King of Kings Edition',
            ),
          ],
          taxBps: 0,
          screen: size,
          scale: scale,
        );
        expect(tester.takeException(), isNull);
        expect(_text(tester, const ValueKey('level-hero-title')), long);
        expect(_cut(find.byType(LevelScreen)), isEmpty);
        await showLevelTab(tester, 'ladder');
        expect(tester.takeException(), isNull);
        expect(_cut(find.byType(LevelScreen)), isEmpty);
        await unmountLevel(tester, state);
      });
    }
  });

  group('the tabs', () {
    testWidgets('the underline slides to the tab tapped in 220 ms, easing '
        'out, and the content changes under it', (tester) async {
      final state = await _open(tester, level: levelAt(10, xp: 4180));
      final indicator = find.byKey(const ValueKey('level-tab-indicator'));
      final slide = tester.widget<AnimatedPositioned>(indicator);
      expect(slide.duration, levelTabSlide);
      expect(levelTabSlide.inMilliseconds, inInclusiveRange(200, 250));
      expect(slide.curve, Curves.easeOutCubic);
      final bar = tester.getRect(
        find.ancestor(of: indicator, matching: find.byType(LevelTabs)),
      );
      final w = bar.width / LevelInfoTab.values.length;
      final start = tester.getRect(indicator);
      expect(start.center.dx, moreOrLessEquals(bar.left + w / 2, epsilon: 1));

      await tester.tap(find.byKey(const ValueKey('level-tab-daily')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final mid = tester.getRect(indicator);
      expect(mid.center.dx, greaterThan(start.center.dx + 1));
      expect(mid.center.dx, lessThan(bar.left + 1.5 * w - 1));
      await tester.pump(const Duration(milliseconds: 200));
      final end = tester.getRect(indicator);
      expect(end.center.dx, moreOrLessEquals(bar.left + 1.5 * w, epsilon: 1));
      expect(find.byKey(const ValueKey('winning-tax-daily')), findsOneWidget);
      expect(find.byKey(const ValueKey('winning-tax-standing')), findsNothing);
      // Each tab a full touch target; the close key too.
      for (final tab in ['mine', 'daily', 'oneTime', 'ladder']) {
        expect(
          tester.getSize(find.byKey(ValueKey('level-tab-$tab'))).height,
          greaterThanOrEqualTo(44),
        );
      }
      final close = tester.getSize(
        find.byKey(const ValueKey('winning-tax-close')),
      );
      expect(close.width, greaterThanOrEqualTo(44));
      expect(close.height, greaterThanOrEqualTo(44));
      await tester.tap(find.byKey(const ValueKey('winning-tax-close')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(LevelScreen), findsNothing);
      await unmountLevel(tester, state);
    });

    test('the tabs share the row equally while every word fits its share, '
        'and by what each word needs once one does not', () {
      expect(LevelTabs.widthsFor(400, [80, 90, 100, 70]), [100, 100, 100, 100]);
      const need = [100.0, 96.0, 124.0, 100.0];
      final shared = LevelTabs.widthsFor(360, need);
      expect(shared.fold<double>(0, (a, b) => a + b), moreOrLessEquals(360));
      // One scale for every word: each share the same part of its need.
      for (var i = 0; i < need.length; i++) {
        expect(shared[i] / need[i], moreOrLessEquals(360 / 420), reason: '$i');
      }
    });

    testWidgets('640x360 at text x1.25: "One-Time XP" keeps its size beside '
        'three shorter words, and the underline stands under it', (
      tester,
    ) async {
      final state = await _open(
        tester,
        level: levelAt(10, xp: 4180),
        screen: const Size(640, 360),
        scale: 1.25,
        withMissions: true,
      );
      final oneTime = find.byKey(const ValueKey('level-tab-oneTime'));
      for (final e in _fitScales(tester, oneTime).entries) {
        expect(e.value, greaterThanOrEqualTo(0.85), reason: e.key);
      }
      expect(
        tester.getSize(oneTime).width,
        greaterThan(
          tester.getSize(find.byKey(const ValueKey('level-tab-mine'))).width,
        ),
      );
      await showLevelTab(tester, 'oneTime');
      final under = tester.getRect(
        find.byKey(const ValueKey('level-tab-indicator')),
      );
      final tab = tester.getRect(oneTime);
      expect(under.left, greaterThanOrEqualTo(tab.left));
      expect(under.right, lessThanOrEqualTo(tab.right));
      expect(
        find.byKey(const ValueKey('winning-tax-one-time')),
        findsOneWidget,
      );
      await unmountLevel(tester, state);
    });

    testWidgets("the lobby's one-second tick rebuilds nothing on any tab: "
        'no rung, no card, no Lottie, not the bar', (tester) async {
      final state = await _open(
        tester,
        level: levelAt(
          10,
          xp: 4180,
          claimed: ['PLAY_15_MIN', 'WIN_PAIR'],
          missions: [
            missionAt('FIRST_HAND', 1, 1, completed: true, xpAwarded: 5),
            missionAt('GETTING_STARTED', 7, 10),
          ],
        ),
        badges: [
          regularBadge(),
          royalBadge('ROYAL_KING', const Duration(days: 12)),
        ],
        taxBps: 0,
        withMissions: true,
      );
      final lottie = find.descendant(
        of: find.byKey(const ValueKey('badge-art-ROYAL_KING')),
        matching: find.byType(LottieBuilder),
      );
      final before = tester.state(lottie);
      const never = {
        LevelScreen,
        LevelHero,
        LevelXpCard,
        LevelBar,
        HeldBadgeCard,
        BadgeArt,
        LottieBuilder,
        RoyalBadgeHint,
        DailySummary,
        PlayTrack,
        HandSourceTile,
        OneTimeMissionTile,
        LevelRow,
        CatalogueBadgeRow,
      };
      for (final tab in ['mine', 'daily', 'oneTime', 'ladder']) {
        if (tab != 'mine') await showLevelTab(tester, tab);
        final rebuilt = await _rebuiltDuring(() async {
          for (var i = 0; i < 3; i++) {
            // ignore: invalid_use_of_protected_member
            state.notifyListeners();
            await tester.pump(const Duration(milliseconds: 16));
          }
        });
        expect(rebuilt.intersection(never), isEmpty, reason: tab);
      }
      await showLevelTab(tester, 'mine');
      expect(
        _barFraction(tester, const ValueKey('winning-tax-progress')),
        moreOrLessEquals(0.15),
      );
      await unmountLevel(tester, state);
      expect(before, isNotNull);
    });

    testWidgets('a fresh copy of the same account rebuilds nothing; a change '
        'to it does', (tester) async {
      final level = levelAt(10, xp: 4180);
      final state = await _open(tester, level: level);
      final same = await _rebuiltDuring(
        () => _swapUser(tester, state, level: level),
      );
      expect(same.intersection({LevelScreen, LevelHero, LevelRow}), isEmpty);
      final changed = await _rebuiltDuring(
        () => _swapUser(tester, state, level: levelAt(10, xp: 4190)),
      );
      expect(changed, contains(LevelScreen));
      expect(_text(tester, const ValueKey('level-xp-of')), '4,190 / 5,200 XP');
      await unmountLevel(tester, state);
    });

    testWidgets('a screen reader can press every tab and the close key', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final state = await _open(tester, level: levelAt(10, xp: 4180));
      final t = state.t;

      for (final (label, pane) in [
        (t.xpDailyTitle, 'winning-tax-daily'),
        (t.allLevelsTitle, 'winning-tax-ladder'),
        (t.levelTabMine, 'winning-tax-standing'),
      ]) {
        final node = tester.getSemantics(
          find.descendant(
            of: find.byType(LevelTabs),
            matching: find.bySemanticsLabel(label),
          ),
        );
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
        node.owner!.performAction(node.id, SemanticsAction.tap);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(ValueKey(pane)), findsOneWidget, reason: label);
      }
      final close = tester.getSemantics(
        find.byKey(const ValueKey('winning-tax-close')),
      );
      expect(close.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      close.owner!.performAction(close.id, SemanticsAction.tap);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(LevelScreen), findsNothing);
      handle.dispose();
      await unmountLevel(tester, state);
    });
  });

  group('the clock', () {
    testWidgets('a daily window that ends while the tab is open clears its '
        'ticks and its XP and says the day starts with the next hand', (
      tester,
    ) async {
      final claimed = ['PLAY_15_MIN', 'WIN_PAIR'];
      final state = await _open(
        tester,
        level: levelAt(10, xp: 4180, claimed: claimed),
        tab: 'daily',
      );
      final t = state.t;
      await _swapUser(
        tester,
        state,
        level: levelAt(
          10,
          xp: 4180,
          claimed: claimed,
          resetsIn: const Duration(seconds: 4),
        ),
      );
      expect(_text(tester, const ValueKey('daily-xp-earned')), '4 / 108 XP');
      expect(find.byKey(const ValueKey('daily-reset')), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('xp-earned-Win by Pair'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 4300)),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_text(tester, const ValueKey('daily-xp-earned')), '0 / 108 XP');
      expect(_text(tester, const ValueKey('daily-idle')), t.xpWindowIdle);
      expect(find.byKey(const ValueKey('daily-reset')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('daily-summary')),
          matching: find.byIcon(Icons.timer_outlined),
        ),
        findsNothing,
      );
      for (final name in ['Win by Pair', t.xpPlayMinutes(15)]) {
        expect(
          find.byKey(ValueKey('xp-earned-$name'), skipOffstage: false),
          findsNothing,
          reason: name,
        );
      }
      await unmountLevel(tester, state);
    });

    testWidgets("the table's popup follows the clock too: a window that ends "
        'clears its ticks, a grant that ends drops its time left', (
      tester,
    ) async {
      final state = levelState(
        level: levelAt(
          10,
          xp: 4180,
          claimed: ['WIN_PAIR'],
          resetsIn: const Duration(minutes: 30),
        ),
      );
      await _pumpTablePopup(tester, state, const Size(891, 411), 1.0);
      await _swapUser(
        tester,
        state,
        level: levelAt(
          10,
          xp: 4180,
          claimed: ['WIN_PAIR'],
          resetsIn: const Duration(seconds: 4),
        ),
        badges: [
          regularBadge(),
          royalBadge('ROYAL_ACE', const Duration(seconds: 4)),
        ],
        taxBps: 0,
      );
      Finder ticked() => find.byKey(
        const ValueKey('xp-earned-Win by Pair'),
        skipOffstage: false,
      );
      Finder aceLeft() => find.descendant(
        of: find.byKey(const ValueKey('my-badge-ROYAL_ACE')),
        matching: find.textContaining('left'),
      );
      expect(ticked(), findsOneWidget);
      expect(aceLeft(), findsOneWidget);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 4300)),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 400));
      expect(ticked(), findsNothing);
      expect(aceLeft(), findsNothing);
      await unmountLevel(tester, state);
    });
  });

  group('edge cases', () {
    testWidgets('an account with no badges at all (an older server): no '
        'badge section, the Royal hint from the catalogue, nothing broken', (
      tester,
    ) async {
      final state = levelState(level: levelAt(4, xp: 520));
      state.user = User.fromJson({
        'id': 'u0',
        'provider': 'guest',
        'displayName': 'Priya',
        'chips': 1000,
        'playerLevel': levelAt(4, xp: 520),
        'badges': const <Object?>[],
      });
      await pumpLevelLobby(tester, state);
      await openLevelScreen(tester);
      final t = state.t;
      expect(tester.takeException(), isNull);
      expect(find.byType(HeldBadgeCard), findsNothing);
      expect(find.text(t.yourBadgesTitle), findsNothing);
      expect(find.byKey(const ValueKey('royal-badge-hint')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('winning-tax-rate')),
          matching: find.text(t.rateSetByLevel),
        ),
        findsOneWidget,
      );
      await unmountLevel(tester, state);
    });

    testWidgets('the Royal hint waits for the catalogue', (tester) async {
      final state = await _open(
        tester,
        level: levelAt(1, xp: 23),
        withLadder: false,
      );
      expect(find.byKey(const ValueKey('royal-badge-hint')), findsNothing);
      await unmountLevel(tester, state);
    });

    testWidgets('at the top level "This is the top level." is said once', (
      tester,
    ) async {
      final state = await _open(tester, level: levelAt(50, xp: 2150000));
      expect(
        find.text(state.t.topLevelNote, skipOffstage: false),
        findsOneWidget,
      );
      await unmountLevel(tester, state);
    });

    testWidgets('a daily source of a kind this build has no heading for is '
        'listed under a plain one, never as a winning hand', (tester) async {
      final json = ladderJson();
      final sources = [
        ...(json['xpSources']! as List),
        {
          'code': 'INVITE_FRIEND',
          'name': 'Invite a friend',
          'icon': '💌',
          'kind': 'SOCIAL',
          'xp': 5,
          'times': 1,
        },
      ];
      final state = levelState(
        level: levelAt(10, xp: 4180),
        ladderRead: LevelLadder.maybe({...json, 'xpSources': sources}),
      );
      await pumpLevelLobby(tester, state);
      await openLevelScreen(tester);
      await showLevelTab(tester, 'daily');
      final t = state.t;
      final other = find.text(t.xpOtherTitle, skipOffstage: false);
      expect(other, findsOneWidget);
      final hands = find.text(t.xpWinHandsTitle, skipOffstage: false);
      final invite = find.byKey(
        const ValueKey('xp-source-INVITE_FRIEND'),
        skipOffstage: false,
      );
      final trail = find.byKey(
        const ValueKey('xp-source-WIN_TRAIL'),
        skipOffstage: false,
      );
      // The winning hands' heading, their tiles, then the other heading and
      // the new source under it.
      expect(
        tester.getTopLeft(hands).dy,
        lessThan(tester.getTopLeft(trail).dy),
      );
      expect(
        tester.getTopLeft(trail).dy,
        lessThan(tester.getTopLeft(other).dy),
      );
      expect(
        tester.getTopLeft(other).dy,
        lessThan(tester.getTopLeft(invite).dy),
      );
      await unmountLevel(tester, state);
    });

    testWidgets('the solid tags are struck gold under charcoal words, in '
        'the light theme too', (tester) async {
      final state = await _open(
        tester,
        level: levelAt(25, xp: 94400),
        dark: false,
        tab: 'ladder',
      );
      final tag = find.descendant(
        of: find.byKey(const ValueKey('ladder-you')),
        matching: find.byType(Container),
      );
      final box =
          tester.widget<Container>(tag.first).decoration! as BoxDecoration;
      expect(box.gradient, AppTheme.goldFace);
      // Charcoal on the gradient's darkest stop.
      double lum(Color c) {
        double ch(double v) =>
            v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4) * 1.0;
        return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
      }

      final dark = lum(AppTheme.goldFace.colors.last);
      final ink = lum(AppTheme.ink900);
      expect((dark + 0.05) / (ink + 0.05), greaterThanOrEqualTo(4.5));
      await unmountLevel(tester, state);
    });

    testWidgets('a Royal badge the viewer does not hold is Available, on a '
        'gold ring; Regular has neither', (tester) async {
      final state = await _open(
        tester,
        level: levelAt(10, xp: 4180),
        badges: [
          regularBadge(),
          royalBadge('ROYAL_ACE', const Duration(days: 5)),
        ],
        taxBps: 0,
        tab: 'ladder',
      );
      Finder k(String key) => find.byKey(ValueKey(key), skipOffstage: false);
      expect(k('ladder-badge-available-ROYAL_KING'), findsOneWidget);
      expect(k('ladder-badge-ring-ROYAL_KING'), findsOneWidget);
      expect(k('ladder-badge-available-ROYAL_ACE'), findsNothing);
      expect(k('ladder-badge-yours-ROYAL_ACE'), findsOneWidget);
      expect(k('ladder-badge-available-REGULAR'), findsNothing);
      expect(k('ladder-badge-ring-REGULAR'), findsNothing);
      await unmountLevel(tester, state);
    });

    testWidgets('past the badges\' heading the column heads name the badges, '
        'and the key leads back up to the viewer\'s level', (tester) async {
      final state = await _open(
        tester,
        level: levelAt(25, xp: 94400),
        tab: 'ladder',
      );
      final t = state.t;
      expect(
        _text(tester, const ValueKey('ladder-head-column')),
        t.levelColumn,
      );
      // The badges' own heading carries no second "Tax".
      final heading = find.ancestor(
        of: find.text(t.badgesTitle, skipOffstage: false),
        matching: find.byType(LevelSection, skipOffstage: false),
      );
      expect(
        find.descendant(
          of: heading,
          matching: find.text(t.taxColumn, skipOffstage: false),
        ),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('ladder-jump-badges')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        _text(tester, const ValueKey('ladder-head-column')),
        t.badgesTitle,
      );
      expect(find.byKey(const ValueKey('ladder-jump-levels')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ladder-jump-levels')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        _text(tester, const ValueKey('ladder-head-column')),
        t.levelColumn,
      );
      final pane = tester.getRect(
        find.byKey(const ValueKey('winning-tax-ladder')),
      );
      final you = tester.getRect(find.byKey(const ValueKey('ladder-you')));
      expect(pane.contains(you.center), isTrue);
      await unmountLevel(tester, state);
    });

    testWidgets('every rung\'s mark is its art at one size — an empty square '
        'of that size where the owner has sent none yet', (tester) async {
      final state = await _open(
        tester,
        level: levelAt(25, xp: 94400),
        tab: 'ladder',
        screen: const Size(592, 360),
        scale: 1.25,
      );
      var drawn = 0, empty = 0;
      for (final e
          in find
              .byKey(const ValueKey('ladder-mark'), skipOffstage: false)
              .evaluate()) {
        final slot = find.byElementPredicate((x) => identical(x, e));
        final art = tester.widget<LevelArt>(
          find.descendant(
            of: slot,
            matching: find.byType(LevelArt, skipOffstage: false),
          ),
        );
        expect(art.size, LevelRow.markSize);
        if (find
            .descendant(
              of: slot,
              matching: find.byKey(
                const ValueKey('level-art'),
                skipOffstage: false,
              ),
            )
            .evaluate()
            .isNotEmpty) {
          drawn++;
          expect(art.assetUrl, startsWith('https://drive.test/levels/'));
        } else {
          empty++;
          expect(
            find.descendant(
              of: slot,
              matching: find.byKey(
                const ValueKey('level-art-empty'),
                skipOffstage: false,
              ),
            ),
            findsOneWidget,
          );
        }
        // No emoji any more.
        expect(
          find.descendant(
            of: slot,
            matching: find.byType(RichText, skipOffstage: false),
          ),
          findsNothing,
        );
      }
      expect(drawn, greaterThan(0), reason: 'some rungs built with art');
      expect(drawn + empty, greaterThan(0));
      await unmountLevel(tester, state);
    });
  });

  group("the table's popup", () {
    for (final (size, scale) in [
      (const Size(640, 360), 1.0),
      (const Size(640, 360), 1.25),
      (const Size(891, 411), 1.0),
      (const Size(891, 411), 1.25),
    ]) {
      testWidgets('keeps its two panes and no tabs '
          '(${size.width.toInt()}x${size.height.toInt()} x$scale)', (
        tester,
      ) async {
        final state = levelState(level: levelAt(10, xp: 4180));
        await _pumpTablePopup(tester, state, size, scale);
        expect(tester.takeException(), isNull);
        expect(find.byType(LevelScreen), findsNothing);
        expect(find.byKey(const ValueKey('level-tab-mine')), findsNothing);
        final standing = tester.getRect(
          find.byKey(const ValueKey('winning-tax-standing')),
        );
        final ladder = tester.getRect(
          find.byKey(const ValueKey('winning-tax-ladder')),
        );
        expect(standing.right, lessThanOrEqualTo(ladder.left));
        expect(_cut(find.byType(WinningTaxInfo)), isEmpty);
        expect(find.text('Winning Tax'), findsOneWidget);
        await unmountLevel(tester, state);
      });
    }
  });

  group('layout', () {
    const sizes = [
      Size(592, 360),
      Size(640, 360),
      Size(844, 390),
      Size(915, 412),
      Size(1280, 800),
    ];
    for (final size in sizes) {
      for (final scale in [1.0, 1.25]) {
        for (final dark in [true, false]) {
          final label =
              '${size.width.toInt()}x${size.height.toInt()} x$scale '
              '${dark ? 'dark' : 'light'}';
          testWidgets('$label: every tab in every language, nothing '
              'overflowing, nothing cut', (tester) async {
            for (final lang in AppLang.values) {
              final state = await _open(
                tester,
                level: levelAt(
                  25,
                  xp: 94400,
                  claimed: ['PLAY_15_MIN', 'WIN_PAIR'],
                  missions: [
                    missionAt(
                      'FIRST_HAND',
                      1,
                      1,
                      completed: true,
                      xpAwarded: 5,
                    ),
                    missionAt('GETTING_STARTED', 7, 10),
                    missionAt('GAME_EXPLORER', 2, 3),
                  ],
                ),
                withMissions: true,
                badges: [
                  regularBadge(),
                  royalBadge('ROYAL_KING', const Duration(days: 12)),
                  royalBadge('ROYAL_ACE', const Duration(hours: 3)),
                ],
                taxBps: 0,
                screen: size,
                scale: scale,
                dark: dark,
                lang: lang,
              );
              final t = state.t;
              final where = '$label ${lang.code}';
              expect(tester.takeException(), isNull, reason: where);
              final panel = tester.getRect(
                find.descendant(
                  of: find.byType(LevelScreen),
                  matching: find.byType(PremiumGlassPanel),
                ),
              );
              for (final tab in ['mine', 'daily', 'oneTime', 'ladder']) {
                if (tab != 'mine') await showLevelTab(tester, tab);
                expect(tester.takeException(), isNull, reason: '$where $tab');
                expect(
                  _cut(find.byType(LevelScreen)),
                  isEmpty,
                  reason: '$where $tab',
                );
                // The title and the tabs never shrunk past legibility.
                for (final key in [
                  'level-tab-mine',
                  'level-tab-daily',
                  'level-tab-oneTime',
                  'level-tab-ladder',
                ]) {
                  for (final e in _fitScales(
                    tester,
                    find.byKey(ValueKey(key)),
                  ).entries) {
                    expect(
                      e.value,
                      greaterThanOrEqualTo(0.85),
                      reason: '$where $tab $key ${e.key}',
                    );
                  }
                }
                final title = find.ancestor(
                  of: find.byKey(const ValueKey('level-screen-title')),
                  matching: find.byType(FittedBox),
                );
                for (final e in _fitScales(
                  tester,
                  find.ancestor(of: title, matching: find.byType(Row)).first,
                ).entries) {
                  expect(
                    e.value,
                    greaterThanOrEqualTo(0.85),
                    reason: '$where $tab title ${e.key}',
                  );
                }
                // The title and the tabs whole, inside the panel.
                for (final key in [
                  'level-screen-title',
                  'level-tab-mine',
                  'level-tab-daily',
                  'level-tab-oneTime',
                  'level-tab-ladder',
                  'winning-tax-close',
                ]) {
                  final r = tester.getRect(find.byKey(ValueKey(key)));
                  expect(
                    panel.inflate(0.5).contains(r.topLeft) &&
                        panel.inflate(0.5).contains(r.bottomRight),
                    isTrue,
                    reason: '$where $tab $key $r in $panel',
                  );
                }
              }
              await showLevelTab(tester, 'mine');
              // The Winning Tax and its percentage whole, inside the panel.
              final rate = _inScreen(
                find.descendant(
                  of: find.byKey(const ValueKey('winning-tax-rate')),
                  matching: find.text('0%'),
                ),
              );
              expect(rate, findsOneWidget, reason: where);
              final r = tester.getRect(rate);
              expect(panel.contains(r.topLeft), isTrue, reason: where);
              expect(panel.contains(r.bottomRight), isTrue, reason: where);
              expect(find.text(t.winningTaxTitle), findsOneWidget);
              await unmountLevel(tester, state);
            }
          });
        }
      }
    }
  });
}
