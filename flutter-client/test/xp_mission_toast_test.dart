// The bar that says a daily XP mission is done (owner, 27 Sep 2026: "whenever
// xp mission completed, show top notification bar for 5 seconds showing this
// is completed and xp increased"): which awards complete a mission, the queue,
// the five seconds, the tap, the level-up line, what never shows one, and the
// bar over the lobby and both felts at every size, text scale, language and
// theme.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/main.dart' show KingTeenPattiApp;
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/game_connection.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/state/xp_missions.dart';
import 'package:teenpatti/widgets/buy_chips.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/table_chrome.dart';
import 'package:teenpatti/widgets/xp_mission_bar.dart';

import 'level_fixtures.dart';
import 'table_scenes.dart'
    show pokerRoom, seenTurnRoom, silentFeedback, openMenu;

/// One window, fixed, so two standings can share it.
final int windowA = DateTime.now().millisecondsSinceEpoch + 20 * hourMs;
final int windowB = windowA + dayMs;

/// A level-[level] standing's `playerLevel`, at [xp], with the window
/// [resetsAt] (none where null) having earned [claimed].
Map<String, Object?> lv(
  int level,
  int xp, {
  Map<String, int> claimed = const {},
  int? resetsAt,
}) {
  final (n, _, title, icon, taxBps) = ownersLevels[level - 1];
  final next = level < ownersLevels.length ? ownersLevels[level] : null;
  return {
    'level': n,
    'title': title,
    'icon': icon,
    'xp': xp,
    'taxBps': taxBps,
    if (next != null)
      'next': {
        'level': next.$1,
        'title': next.$3,
        'icon': next.$4,
        'minXp': next.$2,
        'taxBps': next.$5,
      },
    if (resetsAt != null) 'daily': {'claimed': claimed, 'resetsAt': resetsAt},
  };
}

PlayerLevel pl(Map<String, Object?> j) => PlayerLevel.maybe(j)!;

Standing standing(
  Map<String, Object?> level, {
  List<Map<String, Object?>>? badges,
  int? taxBps,
}) => Standing.maybe({
  'playerLevel': level,
  'badges': badges ?? [regularBadge()],
  'taxBps': taxBps ?? level['taxBps'],
})!;

/// A socket that is never opened: the session and the standings are fed to
/// the app by hand, as the server's `session:ready` and `player:level` would.
class _FedConnection extends GameConnection {
  _FedConnection() : super('http://127.0.0.1:9');

  final session =
      StreamController<
        ({User user, GameConfig? config, ResumeHint? resume})
      >.broadcast();
  final levels = StreamController<Standing>.broadcast();

  @override
  Stream<({User user, GameConfig? config, ResumeHint? resume})> get onSession =>
      session.stream;

  @override
  Stream<Standing> get onPlayerLevel => levels.stream;
}

GameState stateAt(
  Map<String, Object?> level, {
  AppLang lang = AppLang.english,
  bool withLadder = true,
}) => levelState(level: level, lang: lang, withLadder: withLadder);

/// The app as main.dart builds it: the text scale clamped, the glass budget,
/// the toasts' Scaffold, and the mission bar above it all.
Widget app(
  GameState state,
  FeedbackSettings feedback,
  Widget home,
  bool dark,
) => MultiProvider(
  providers: [
    ChangeNotifierProvider<GameState>.value(value: state),
    ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
  ],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: levelTheme(dark: dark),
    builder: (context, child) => MediaQuery.withClampedTextScaling(
      minScaleFactor: 0.9,
      maxScaleFactor: 1.25,
      child: GlassBudget(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Scaffold(
              backgroundColor: Colors.transparent,
              resizeToAvoidBottomInset: false,
              body: child ?? const SizedBox.shrink(),
            ),
            const XpMissionHost(),
          ],
        ),
      ),
    ),
    home: home,
  ),
);

Future<void> mount(
  WidgetTester tester,
  GameState state, {
  Widget home = const LobbyScreen(),
  Size screen = const Size(640, 360),
  double scale = 1.0,
  bool dark = true,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  await tester.pumpWidget(app(state, feedback, home, dark));
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

Future<void> unmount(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

/// Down and settled.
Future<void> arrive(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(XpMissionHost.slideIn + const Duration(milliseconds: 40));
}

final Finder bar = find.byKey(const ValueKey('xp-mission-bar'));

String textOf(WidgetTester tester, String key) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(Text),
      ),
    )
    .data!;

String titleOf(WidgetTester tester) => textOf(tester, 'xp-mission-title');

void main() {
  setUpAll(() async {
    primeBadges();
    await loadLevelFonts();
  });

  group('which awards complete a mission', () {
    final ladder0 = ladder();

    test('a count up in the same window is one mission, with its XP, the '
        'running total and the next level', () {
      final news = XpMissions.completions(
        pl(lv(1, 23, claimed: {'PLAY_15_MIN': 1}, resetsAt: windowA)),
        pl(
          lv(
            1,
            24,
            claimed: {'PLAY_15_MIN': 1, 'WIN_PAIR': 1},
            resetsAt: windowA,
          ),
        ),
        ladder0,
      );
      expect(news, hasLength(1));
      expect(news.single.code, 'WIN_PAIR');
      expect(news.single.xp, 1);
      expect(news.single.total, 24);
      expect(news.single.goal, 100);
      expect(news.single.levelUp, isNull);
    });

    test('the first hand of a window may itself be a win: the new window '
        'counts from nothing', () {
      final news = XpMissions.completions(
        pl(lv(1, 10)),
        pl(lv(1, 12, claimed: {'WIN_COLOR': 1}, resetsAt: windowA)),
        ladder0,
      );
      expect(news.map((n) => n.code), ['WIN_COLOR']);
      expect(news.single.xp, 2);
    });

    test('a window rolling over is no completion — the reset counts are '
        'never read as one — and a decrease or no XP shows nothing', () {
      final before = pl(
        lv(
          2,
          150,
          claimed: {'WIN_PAIR': 1, 'PLAY_15_MIN': 1},
          resetsAt: windowA,
        ),
      );
      // Rolled over, nothing earned yet: the XP did not move.
      expect(
        XpMissions.completions(
          before,
          pl(lv(2, 150, resetsAt: windowB)),
          ladder0,
        ),
        isEmpty,
      );
      // Rolled over with the same counts (a replay of the window's figures)
      // but no XP: not an award.
      expect(
        XpMissions.completions(
          before,
          pl(lv(2, 150, claimed: {'WIN_PAIR': 1}, resetsAt: windowB)),
          ladder0,
        ),
        isEmpty,
      );
      // A decrease.
      expect(
        XpMissions.completions(
          before,
          pl(
            lv(
              2,
              140,
              claimed: {'WIN_PAIR': 1, 'PLAY_15_MIN': 1, 'WIN_TRAIL': 1},
              resetsAt: windowA,
            ),
          ),
          ladder0,
        ),
        isEmpty,
      );
      // No daily block, or no level before.
      expect(XpMissions.completions(before, pl(lv(2, 170)), ladder0), isEmpty);
      expect(
        XpMissions.completions(
          null,
          pl(lv(2, 170, claimed: {'WIN_TRAIL': 1}, resetsAt: windowA)),
          ladder0,
        ),
        isEmpty,
      );
      // A count that fell in the same window.
      expect(
        XpMissions.completions(
          before,
          pl(lv(2, 160, claimed: {'WIN_PAIR': 1}, resetsAt: windowA)),
          ladder0,
        ),
        isEmpty,
      );
    });

    test(
      'a window\'s end read a few milliseconds apart is still one window',
      () {
        final news = XpMissions.completions(
          pl(
            lv(
              10,
              4180,
              claimed: {'PLAY_15_MIN': 1, 'WIN_PAIR': 1},
              resetsAt: windowA,
            ),
          ),
          pl(
            lv(
              10,
              4200,
              claimed: {'PLAY_15_MIN': 1, 'WIN_PAIR': 1, 'PLAY_60_MIN': 1},
              resetsAt: windowA + 3,
            ),
          ),
          ladder0,
        );
        expect(news.map((n) => n.code), ['PLAY_60_MIN']);
      },
    );

    test('two missions in one award are two bars in the ladder\'s order, with '
        'running totals; a level up rides on the last', () {
      final news = XpMissions.completions(
        pl(lv(1, 90, claimed: {'PLAY_15_MIN': 1}, resetsAt: windowA)),
        pl(
          lv(
            2,
            162,
            claimed: {'PLAY_15_MIN': 1, 'PLAY_120_MIN': 1, 'PLAY_60_MIN': 1},
            resetsAt: windowA,
          ),
        ),
        ladder0,
      );
      expect(news.map((n) => n.code), ['PLAY_60_MIN', 'PLAY_120_MIN']);
      expect(news.map((n) => n.xp), [20, 50]);
      expect(news.map((n) => n.total), [110, 162]);
      expect(news.map((n) => n.goal), [250, 250]);
      expect(news.first.levelUp, isNull);
      expect(news.last.levelUp!.level, 2);
      expect(news.map((n) => n.id).toSet(), hasLength(2));
    });

    test('without the ladder the award names the mission later, and a lone '
        'mission carries the whole award', () {
      final news = XpMissions.completions(
        pl(lv(1, 10, resetsAt: windowA)),
        pl(lv(1, 30, claimed: {'WIN_TRAIL': 1}, resetsAt: windowA)),
        null,
      );
      expect(news.single.source, isNull);
      expect(news.single.xp, 20);
      expect(news.single.goal, 100, reason: 'from the standing\'s next level');
      expect(news.single.sourceIn(ladder0)!.icon, '🔥');
    });

    test('two sources the ladder cannot name sharing one award are given no '
        'guess: no XP, no running total until the last, which has the award\'s '
        'own', () {
      final news = XpMissions.completions(
        pl(lv(1, 10, claimed: {'WIN_PAIR': 1}, resetsAt: windowA)),
        pl(
          lv(
            1,
            33,
            claimed: {'WIN_PAIR': 1, 'PLAY_15_MIN': 1, 'PLAY_60_MIN': 1},
            resetsAt: windowA,
          ),
        ),
        null,
      );
      expect(news.map((n) => n.code), ['PLAY_15_MIN', 'PLAY_60_MIN']);
      expect(news.map((n) => n.xp), [null, null]);
      expect(news.map((n) => n.total), [null, 33]);
      // The ladder, read later, names each and says what each gave.
      expect(news.map((n) => n.xpIn(ladder0)), [3, 20]);
      final first = XpMissionBar.linesFor(
        Strings(AppLang.english),
        news.first,
        ladder0,
      );
      expect(first.gained, '+3 XP');
      expect(first.total, isNull);
    });

    test('the award\'s level up carries the tax it changed, and no other bar '
        'does', () {
      final news = XpMissions.completions(
        pl(lv(1, 90, claimed: {'PLAY_15_MIN': 1}, resetsAt: windowA)),
        pl(
          lv(
            2,
            162,
            claimed: {'PLAY_15_MIN': 1, 'PLAY_120_MIN': 1, 'PLAY_60_MIN': 1},
            resetsAt: windowA,
          ),
        ),
        ladder0,
        levelUpTaxBps: 1971,
      );
      expect(news.map((n) => n.levelUpTaxBps), [null, 1971]);
    });
  });

  group('GameState', () {
    test('player:level queues the missions it completed, and a level up '
        'said on the bar is not said again in a toast', () {
      final state = stateAt(lv(1, 95, resetsAt: windowA));
      state.handlePlayerLevel(
        standing(lv(1, 96, claimed: {'WIN_PAIR': 1}, resetsAt: windowA)),
      );
      expect(state.xpMissions.queue.map((n) => n.code), ['WIN_PAIR']);
      expect(state.notice, isNull);

      state.handlePlayerLevel(
        standing(
          lv(
            2,
            116,
            claimed: {'WIN_PAIR': 1, 'WIN_TRAIL': 1},
            resetsAt: windowA,
          ),
        ),
      );
      expect(state.xpMissions.queue.map((n) => n.code), [
        'WIN_PAIR',
        'WIN_TRAIL',
      ]);
      expect(state.xpMissions.queue.last.levelUp!.level, 2);
      expect(state.notice, isNull, reason: 'the bar says the level up');
      state.dispose();
    });

    test('an account refreshed from /api/auth/me before the push still '
        'shows the award; a session start and a repeat show nothing', () {
      final state = stateAt(lv(1, 40, resetsAt: windowA));
      state.handlePlayerLevel(
        standing(lv(1, 41, claimed: {'WIN_PAIR': 1}, resetsAt: windowA)),
      );
      state.xpMissions.clear();
      // me() lands first, already at the award's figures ...
      state.user = playerUser(
        level: lv(
          1,
          43,
          claimed: {'WIN_PAIR': 1, 'WIN_COLOR': 1},
          resetsAt: windowA,
        ),
      );
      expect(state.xpMissions.queue, isEmpty);
      // ... and the push that announces them still does.
      state.handlePlayerLevel(
        standing(
          lv(
            1,
            43,
            claimed: {'WIN_PAIR': 1, 'WIN_COLOR': 1},
            resetsAt: windowA,
          ),
        ),
      );
      expect(state.xpMissions.queue.map((n) => n.code), ['WIN_COLOR']);
      state.xpMissions.clear();

      // The same standing again: nothing.
      state.handlePlayerLevel(
        standing(
          lv(
            1,
            43,
            claimed: {'WIN_PAIR': 1, 'WIN_COLOR': 1},
            resetsAt: windowA,
          ),
        ),
      );
      expect(state.xpMissions.queue, isEmpty);

      // A session (login, cold start, session:ready) brings a standing that
      // earned more while the app was away: what it brings is not announced.
      final away = lv(
        1,
        66,
        claimed: {'WIN_PAIR': 1, 'WIN_COLOR': 1, 'PLAY_60_MIN': 1},
        resetsAt: windowA,
      );
      state.user = playerUser(level: away);
      state.seeSessionStanding();
      state.handlePlayerLevel(standing(away));
      expect(state.xpMissions.queue, isEmpty);
      state.dispose();
    });

    test('a level up that came with a mission tells the new winning tax on '
        'the bar, as the toast it replaces did', () {
      final state = stateAt(lv(1, 95, resetsAt: windowA));
      expect(state.user!.paysTaxBps, 2000);
      state.handlePlayerLevel(
        standing(lv(2, 115, claimed: {'WIN_TRAIL': 1}, resetsAt: windowA)),
      );
      expect(state.user!.paysTaxBps, 1971);
      expect(state.notice, isNull, reason: 'the bar says it');
      final news = state.xpMissions.queue.single;
      expect(news.levelUpTaxBps, 1971);
      final lines = XpMissionBar.linesFor(state.t, news, state.levelLadder);
      expect(lines.levelUp, 'Level up! 🔰 Level 2 · Rookie');
      expect(lines.taxNow, 'Winning tax now 19.71%');
      state.dispose();

      // A badge keeps the rate lower than either level's: the level up is
      // said, and no rate, since none changed.
      final royal = [
        regularBadge(),
        royalBadge('ROYAL_ACE', const Duration(days: 3)),
      ];
      final badged = levelState(
        level: lv(1, 95, resetsAt: windowA),
        badges: royal,
        taxBps: 0,
      );
      badged.handlePlayerLevel(
        standing(
          lv(2, 115, claimed: {'WIN_TRAIL': 1}, resetsAt: windowA),
          badges: royal,
          taxBps: 0,
        ),
      );
      final quiet = badged.xpMissions.queue.single;
      expect(quiet.levelUp!.level, 2);
      expect(quiet.levelUpTaxBps, isNull);
      expect(
        XpMissionBar.linesFor(badged.t, quiet, badged.levelLadder).taxNow,
        isNull,
      );
      expect(badged.notice, isNull);
      badged.dispose();
    });

    test('an older standing heard late neither shows anything nor moves the '
        'baseline back', () {
      final state = stateAt(lv(1, 10, resetsAt: windowA));
      final a = lv(1, 11, claimed: {'WIN_PAIR': 1}, resetsAt: windowA);
      final b = lv(
        1,
        13,
        claimed: {'WIN_PAIR': 1, 'WIN_COLOR': 1},
        resetsAt: windowA,
      );
      for (final s in [a, a, b, a, b]) {
        state.handlePlayerLevel(standing(s));
      }
      expect(state.xpMissions.queue.map((n) => n.code), [
        'WIN_PAIR',
        'WIN_COLOR',
      ]);
      state.dispose();
    });

    test('an award heard before the ladder is read waits for it, and the '
        'awards keep their order', () async {
      final state = stateAt(
        lv(1, 10, claimed: {'WIN_PAIR': 1}, resetsAt: windowA),
        withLadder: false,
      );
      state.handlePlayerLevel(
        standing(
          lv(
            1,
            33,
            claimed: {'WIN_PAIR': 1, 'PLAY_15_MIN': 1, 'PLAY_60_MIN': 1},
            resetsAt: windowA,
          ),
        ),
      );
      state.handlePlayerLevel(
        standing(
          lv(
            1,
            35,
            claimed: {
              'WIN_PAIR': 1,
              'PLAY_15_MIN': 1,
              'PLAY_60_MIN': 1,
              'WIN_COLOR': 1,
            },
            resetsAt: windowA,
          ),
        ),
      );
      expect(state.xpMissions.queue, isEmpty, reason: 'waiting on the ladder');
      expect(state.levelLadderLoading, isTrue);
      // The ladder arrives (this read of it fails: the one on the phone is
      // what the awards are drawn from).
      state.levelLadder = ladder();
      await state.loadLevelLadder();
      await pumpEventQueue();
      final q = state.xpMissions.queue;
      expect(q.map((n) => n.code), ['PLAY_15_MIN', 'PLAY_60_MIN', 'WIN_COLOR']);
      expect(q.map((n) => n.xp), [3, 20, 2]);
      expect(q.map((n) => n.total), [13, 33, 35]);
      state.dispose();
    });

    test('a ladder that cannot be read still lets the award show, as best it '
        'can', () async {
      final state = stateAt(lv(1, 10, resetsAt: windowA), withLadder: false);
      state.handlePlayerLevel(
        standing(lv(1, 30, claimed: {'WIN_TRAIL': 1}, resetsAt: windowA)),
      );
      await state.loadLevelLadder();
      await pumpEventQueue();
      expect(state.levelLadder, isNull);
      final news = state.xpMissions.queue.single;
      expect(news.code, 'WIN_TRAIL');
      expect(news.xp, 20, reason: 'a lone mission carries the whole award');
      state.dispose();
    });

    test('the app\'s own wiring: player:level raises a bar, and the standing '
        'a session:ready brings is the new baseline', () async {
      SharedPreferences.setMockInitialValues({});
      final conn = _FedConnection();
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final state = GameState(
        serverUrl: 'http://127.0.0.1:9',
        connection: conn,
      );
      debugDefaultTargetPlatformOverride = null;
      state.levelLadder = ladder();
      await state.start();

      final s0 = lv(1, 40, claimed: {'WIN_PAIR': 1}, resetsAt: windowA);
      conn.session.add((
        user: playerUser(level: s0),
        config: null,
        resume: null,
      ));
      await pumpEventQueue();
      final s1 = lv(
        1,
        42,
        claimed: {'WIN_PAIR': 1, 'WIN_COLOR': 1},
        resetsAt: windowA,
      );
      conn.levels.add(standing(s1));
      await pumpEventQueue();
      expect(state.xpMissions.queue.map((n) => n.code), ['WIN_COLOR']);
      state.xpMissions.clear();

      // Away for a while (a reconnect): the session brings what was earned
      // meanwhile, and its figures repeated by a push are not announced.
      final away = lv(
        1,
        66,
        claimed: {
          'WIN_PAIR': 1,
          'WIN_COLOR': 1,
          'PLAY_60_MIN': 1,
          'WIN_SEQUENCE': 1,
        },
        resetsAt: windowA,
      );
      conn.session.add((
        user: playerUser(level: away),
        config: null,
        resume: null,
      ));
      await pumpEventQueue();
      conn.levels.add(standing(away));
      await pumpEventQueue();
      expect(state.xpMissions.queue, isEmpty);

      conn.levels.add(
        standing(
          lv(
            1,
            86,
            claimed: {
              'WIN_PAIR': 1,
              'WIN_COLOR': 1,
              'PLAY_60_MIN': 1,
              'WIN_SEQUENCE': 1,
              'WIN_TRAIL': 1,
            },
            resetsAt: windowA,
          ),
        ),
      );
      await pumpEventQueue();
      expect(state.xpMissions.queue.map((n) => n.code), ['WIN_TRAIL']);
      state.dispose();
      await conn.session.close();
      await conn.levels.close();
    });

    test('a sign-out takes the queue with it', () async {
      final state = stateAt(lv(1, 10, resetsAt: windowA));
      state.handlePlayerLevel(
        standing(lv(1, 11, claimed: {'WIN_PAIR': 1}, resetsAt: windowA)),
      );
      expect(state.xpMissions.queue, hasLength(1));
      state.xpMissions.clear();
      expect(state.xpMissions.current, isNull);
      state.dispose();
    });
  });

  group('the bar', () {
    testWidgets('slides down with the mission and its XP, stays five '
        'seconds, and goes', (tester) async {
      final state = stateAt(lv(1, 23, resetsAt: windowA));
      await mount(tester, state);
      expect(bar, findsNothing);

      state.handlePlayerLevel(
        standing(lv(1, 24, claimed: {'WIN_PAIR': 1}, resetsAt: windowA)),
      );
      await arrive(tester);
      expect(bar, findsOneWidget);
      expect(titleOf(tester), 'Win by Pair completed');
      expect(textOf(tester, 'xp-mission-gained'), '+1 XP');
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('xp-mission-total')))
            .data,
        '24 / 100 XP',
      );
      // At the top edge, in the middle.
      final r = tester.getRect(bar);
      expect(r.top, lessThanOrEqualTo(XpMissionHost.topGap + 1));
      expect((r.center.dx - 320).abs(), lessThan(1));

      // Announced to a screen reader, as it arrives.
      final live = find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.properties.liveRegion == true &&
            (w.properties.label ?? '').contains('Win by Pair completed') &&
            (w.properties.label ?? '').contains('+1 XP'),
      );
      expect(live, findsOneWidget);

      await tester.pump(const Duration(milliseconds: 4800));
      expect(bar, findsOneWidget, reason: 'still inside its five seconds');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(
        XpMissionHost.slideOut + const Duration(milliseconds: 50),
      );
      await tester.pump(XpMissionHost.between);
      expect(bar, findsNothing);
      expect(state.xpMissions.queue, isEmpty);
      await unmount(tester, state);
    });

    testWidgets('a tap sends it away early', (tester) async {
      final state = stateAt(lv(1, 23, resetsAt: windowA));
      await mount(tester, state);
      state.handlePlayerLevel(
        standing(lv(1, 43, claimed: {'WIN_TRAIL': 1}, resetsAt: windowA)),
      );
      await arrive(tester);
      await tester.tap(bar);
      await tester.pump();
      await tester.pump(
        XpMissionHost.slideOut + const Duration(milliseconds: 50),
      );
      expect(bar, findsNothing);
      await tester.pump(XpMissionHost.between);
      expect(state.xpMissions.queue, isEmpty);
      await unmount(tester, state);
    });

    testWidgets('two completions queue: one bar at a time, never two', (
      tester,
    ) async {
      final state = stateAt(lv(1, 90, resetsAt: windowA));
      await mount(tester, state);
      state.handlePlayerLevel(
        standing(
          lv(
            2,
            111,
            claimed: {'PLAY_15_MIN': 1, 'WIN_COLOR': 1, 'WIN_SEQUENCE': 1},
            resetsAt: windowA,
          ),
        ),
      );
      await arrive(tester);
      expect(bar, findsOneWidget);
      expect(titleOf(tester), 'Play 15 active minutes completed');
      expect(textOf(tester, 'xp-mission-gained'), '+3 XP');
      expect(find.byKey(const ValueKey('xp-mission-level-up')), findsNothing);

      // A second award lands meanwhile: it waits too.
      state.handlePlayerLevel(
        standing(
          lv(
            2,
            131,
            claimed: {
              'PLAY_15_MIN': 1,
              'WIN_COLOR': 1,
              'WIN_SEQUENCE': 1,
              'WIN_TRAIL': 1,
            },
            resetsAt: windowA,
          ),
        ),
      );
      final seen = <String>[titleOf(tester)];
      for (var i = 0; i < 540; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(bar.evaluate().length, lessThanOrEqualTo(1));
        if (bar.evaluate().isNotEmpty) {
          final title = titleOf(tester);
          if (title != seen.last) seen.add(title);
        }
      }
      expect(seen, [
        'Play 15 active minutes completed',
        'Win by Color completed',
        'Win by Sequence completed',
        'Win by Trail completed',
      ]);
      expect(state.xpMissions.queue, isEmpty);
      await unmount(tester, state);
    });

    testWidgets('a level up adds its line to the award\'s last bar', (
      tester,
    ) async {
      final state = stateAt(lv(1, 95, resetsAt: windowA));
      await mount(tester, state);
      state.handlePlayerLevel(
        standing(lv(2, 115, claimed: {'WIN_TRAIL': 1}, resetsAt: windowA)),
      );
      await arrive(tester);
      expect(titleOf(tester), 'Win by Trail completed');
      expect(textOf(tester, 'xp-mission-gained'), '+20 XP');
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('xp-mission-total')))
            .data,
        '115 / 250 XP',
      );
      expect(
        textOf(tester, 'xp-mission-level-up'),
        'Level up! 🔰 Level 2 · Rookie',
      );
      await unmount(tester, state);
    });

    testWidgets('a window roll-over, a session refresh and a decrease show '
        'nothing', (tester) async {
      final state = stateAt(
        lv(2, 150, claimed: {'WIN_PAIR': 1}, resetsAt: windowA),
      );
      await mount(tester, state);
      state.handlePlayerLevel(standing(lv(2, 150, resetsAt: windowB)));
      await arrive(tester);
      expect(bar, findsNothing);

      // The account refreshed as a login, me() or session:ready does.
      state.user = playerUser(
        level: lv(2, 170, claimed: {'WIN_TRAIL': 1}, resetsAt: windowB),
      );
      state.seeSessionStanding();
      state.notifyListeners();
      await arrive(tester);
      expect(bar, findsNothing);

      state.handlePlayerLevel(
        standing(lv(2, 160, claimed: {'WIN_TRAIL': 1}, resetsAt: windowB)),
      );
      await arrive(tester);
      expect(bar, findsNothing);
      await unmount(tester, state);
    });

    testWidgets('it stands above a dialog and takes the tap', (tester) async {
      final state = stateAt(lv(1, 23, resetsAt: windowA));
      await mount(tester, state);
      final context = tester.element(find.byType(LobbyScreen));
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('Over the lobby')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      state.handlePlayerLevel(
        standing(lv(1, 24, claimed: {'WIN_PAIR': 1}, resetsAt: windowA)),
      );
      await arrive(tester);
      expect(bar, findsOneWidget);
      await tester.tap(bar); // warns if the dialog's barrier took it
      await tester.pump();
      await tester.pump(
        XpMissionHost.slideOut + const Duration(milliseconds: 50),
      );
      expect(bar, findsNothing);
      expect(find.text('Over the lobby'), findsOneWidget);
      await unmount(tester, state);
    });
  });

  group('the bar over the table', () {
    for (final poker in [false, true]) {
      testWidgets('on the ${poker ? 'poker' : 'Teen Patti'} felt it clears the '
          'corners, the keys and the viewer\'s cards', (tester) async {
        // The tallest bar there is: the longest mission, a level up with a
        // long name that takes two lines, and the tax it changed.
        for (final (screen, scale, lang) in const [
          (Size(592, 360), 1.0, AppLang.english),
          (Size(592, 360), 1.25, AppLang.english),
          (Size(592, 360), 1.25, AppLang.bengali),
          (Size(640, 360), 1.0, AppLang.english),
          (Size(640, 360), 1.25, AppLang.english),
          (Size(640, 360), 1.25, AppLang.hindi),
          (Size(915, 412), 1.0, AppLang.english),
          (Size(915, 412), 1.25, AppLang.english),
        ]) {
          {
            final state = stateAt(lv(43, 809992, resetsAt: windowA), lang: lang)
              ..screen = Screen.table
              ..handleState(poker ? pokerRoom() : seenTurnRoom());
            await mount(
              tester,
              state,
              home: const TableScreen(),
              screen: screen,
              scale: scale,
            );
            state.handlePlayerLevel(
              standing(
                lv(
                  44,
                  810000,
                  claimed: {'WIN_PURE_SEQUENCE': 1},
                  resetsAt: windowA,
                ),
              ),
            );
            await arrive(tester);
            final where = '$screen x$scale ${lang.englishName}';
            expect(
              find.byKey(const ValueKey('xp-mission-tax-now')),
              findsOneWidget,
              reason: where,
            );
            expect(bar, findsOneWidget, reason: where);
            expect(tester.takeException(), isNull, reason: where);
            final r = tester.getRect(bar);
            expect(r.top, greaterThanOrEqualTo(0), reason: where);
            // What it must stay clear of is on screen to be cleared.
            expect(find.byType(ShopButton), findsOneWidget, reason: where);
            expect(find.byType(TableWallet), findsOneWidget, reason: where);
            expect(find.byType(MachinedKey), findsWidgets, reason: where);
            if (!poker) {
              expect(
                find.byKey(const ValueKey('own-hand-column')),
                findsOneWidget,
                reason: where,
              );
            }
            expect(r.right, lessThanOrEqualTo(screen.width), reason: where);
            for (final f in [
              find.byType(ShopButton),
              find.byType(TableWallet),
              find.byType(MachinedKey),
              find.byType(StepperKey),
              find.byKey(const ValueKey('own-hand-column')),
            ]) {
              for (final e in f.evaluate()) {
                final box = e.renderObject as RenderBox;
                final other = box.localToGlobal(Offset.zero) & box.size;
                expect(
                  r.overlaps(other.deflate(0.5)),
                  isFalse,
                  reason: '$where: over ${e.widget.runtimeType} at $other',
                );
              }
            }
            // Over the menu drawer too.
            if (!poker &&
                screen.width == 640 &&
                scale == 1.25 &&
                lang == AppLang.english) {
              await openMenu(tester, state);
              expect(bar, findsOneWidget);
            }
            await unmount(tester, state);
          }
        }
      });
    }
  });

  group('the bar over the lobby', () {
    testWidgets('in the app as main.dart builds it', (tester) async {
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = stateAt(lv(1, 23, resetsAt: windowA));
      final feedback = await silentFeedback();
      addTearDown(feedback.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<GameState>.value(value: state),
            ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
          ],
          child: const KingTeenPattiApp(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(LobbyScreen), findsOneWidget);
      state.handlePlayerLevel(
        standing(lv(1, 24, claimed: {'WIN_PAIR': 1}, resetsAt: windowA)),
      );
      await arrive(tester);
      expect(bar, findsOneWidget);
      expect(titleOf(tester), 'Win by Pair completed');
      await tester.tap(bar);
      await tester.pump();
      await tester.pump(
        XpMissionHost.slideOut + const Duration(milliseconds: 50),
      );
      expect(bar, findsNothing);
      await unmount(tester, state);
    });

    testWidgets('it lies over the middle of the top bar, clear of the bonus '
        'chip and the drawer keys', (tester) async {
      for (final screen in const [
        Size(592, 360),
        Size(640, 360),
        Size(915, 412),
      ]) {
        for (final scale in const [1.0, 1.25]) {
          final state = stateAt(lv(43, 809992, resetsAt: windowA));
          await mount(tester, state, screen: screen, scale: scale);
          state.handlePlayerLevel(
            standing(
              lv(
                44,
                810000,
                claimed: {'WIN_PURE_SEQUENCE': 1},
                resetsAt: windowA,
              ),
            ),
          );
          await arrive(tester);
          final where = '$screen x$scale';
          final r = tester.getRect(bar);
          final t = state.t;
          final corners = [
            find.byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_BonusChip',
            ),
            find.byTooltip(t.yourRecord),
            find.byTooltip(t.settings),
          ];
          for (final f in corners) {
            expect(f, findsWidgets, reason: '$where $f');
            for (final e in f.evaluate()) {
              final box = e.renderObject as RenderBox;
              final other = box.localToGlobal(Offset.zero) & box.size;
              expect(
                r.overlaps(other.deflate(0.5)),
                isFalse,
                reason: '$where: over ${e.widget.runtimeType} at $other',
              );
            }
          }
          await unmount(tester, state);
        }
      }
    });
  });

  group('layout', () {
    final screens = const [Size(592, 360), Size(640, 360), Size(915, 412)];
    for (final lang in AppLang.values) {
      testWidgets('in ${lang.englishName}: the longest mission and the longest '
          'level up, with the tax it changed, are never set smaller or cut, in '
          'both themes', (tester) async {
        for (final dark in [true, false]) {
          for (final screen in screens) {
            for (final scale in const [1.0, 1.25]) {
              final state = stateAt(
                lv(43, 809992, resetsAt: windowA),
                lang: lang,
              );
              await mount(
                tester,
                state,
                screen: screen,
                scale: scale,
                dark: dark,
              );
              state.handlePlayerLevel(
                standing(
                  lv(
                    44,
                    810000,
                    claimed: {'WIN_PURE_SEQUENCE': 1},
                    resetsAt: windowA,
                  ),
                ),
              );
              await arrive(tester);
              final where =
                  '${lang.englishName} $screen x$scale '
                  '${dark ? 'dark' : 'light'}';
              expect(tester.takeException(), isNull, reason: where);
              final t = Strings(lang);
              final lines = XpMissionBar.linesFor(
                t,
                state.xpMissions.current!,
                state.levelLadder,
              );
              expect(
                lines.title,
                t.xpMissionDone(t.xpWinBy('Pure Sequence')),
                reason: where,
              );
              expect(titleOf(tester), lines.title, reason: where);
              expect(
                textOf(tester, 'xp-mission-level-up'),
                lines.levelUp,
                reason: where,
              );
              expect(lines.levelUp, contains('Supreme Overlord'));
              expect(
                tester
                    .widget<Text>(
                      find.byKey(const ValueKey('xp-mission-tax-now')),
                    )
                    .data,
                t.xpBarTaxNow('7.71%'),
                reason: where,
              );
              final r = tester.getRect(bar);
              expect(
                r.width,
                lessThanOrEqualTo(
                  XpMissionHost.maxWidthFor(screen.width, lobby: true) + 0.5,
                ),
                reason: where,
              );
              // Six lines at the most (the mission and the level up on two
              // each, in an Indic script at x1.25 on a 592dp phone): tall,
              // for a level up's five seconds, and still clear of every key
              // and the viewer's cards ('the bar over the table').
              expect(r.height, lessThan(screen.height * 0.45), reason: where);
              // The mission and the level up at their own size, on two
              // lines at most, never cut.
              for (final key in ['xp-mission-title', 'xp-mission-level-up']) {
                final p = tester.renderObject<RenderParagraph>(
                  find.descendant(
                    of: find.byKey(ValueKey(key)),
                    matching: find.byType(RichText),
                  ),
                );
                expect(p.didExceedMaxLines, isFalse, reason: '$where $key');
                expect(
                  find.ancestor(
                    of: find.byKey(ValueKey(key)),
                    matching: find.byType(FittedBox),
                  ),
                  findsNothing,
                  reason: '$where $key',
                );
              }
              // The tax whole on its line.
              final tax = tester.renderObject<RenderParagraph>(
                find.descendant(
                  of: find.byKey(const ValueKey('xp-mission-tax-now')),
                  matching: find.byType(RichText),
                ),
              );
              expect(
                tax.getMaxIntrinsicWidth(double.infinity),
                lessThanOrEqualTo(tax.size.width + 0.5),
                reason: '$where tax',
              );
              // The XP row is set smaller before it is ever cut, and never
              // by more than a fifth.
              final total = find.byKey(const ValueKey('xp-mission-total'));
              final row = find.ancestor(
                of: total,
                matching: find.byType(FittedBox),
              );
              final laid = tester.renderObject<RenderBox>(
                find.descendant(of: row, matching: find.byType(Row)).first,
              );
              expect(
                tester.getSize(row).width / laid.size.width,
                greaterThan(0.8),
                reason: '$where row',
              );
              await unmount(tester, state);
            }
          }
        }
      });
    }
  });

  test('every language has its own words for the bar', () {
    for (final lang in AppLang.values) {
      final t = Strings(lang);
      for (final key in [
        'xpMissionDone',
        'xpGained',
        'xpMissionFallback',
        'xpBarTaxNow',
      ]) {
        expect(t.ownEntry(key), isNotNull, reason: '${lang.englishName} $key');
      }
    }
  });
}
