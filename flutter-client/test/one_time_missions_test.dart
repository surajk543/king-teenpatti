// The ONE_TIME missions (owner, 28 Sep 2026: "One-time missions are
// permanent missions that a player can complete only once … For ONE_TIME
// missions: incomplete shows "7 / 10"; completed shows "✓ Completed" … ONE_TIME
// missions should NOT show a misleading "24h remaining" timer").
//
// Held here: the wire — the ladder's missions apart from its daily sources
// (so the day's "108 XP" is never inflated), a ONE_TIME entry filed with the
// missions wherever a server lists it, a player's progress; what each mission
// asks, in the player's words; the Daily XP tab's One-Time section — "7 / 10"
// over a bar while open, "✓ Completed" once done, no countdown on any of
// them, how many are done — and nothing of it from a server before the
// missions; the XP mission bar announcing a completion as it announces a
// daily one, and never a mission already completed or a push that moved
// progress alone; and the tab at 640x360 x1.25 in all five languages and both
// themes, nothing overflowing, nothing cut.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/state/xp_missions.dart';
import 'package:teenpatti/widgets/level_screen.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/table_tax.dart';
import 'package:teenpatti/widgets/xp_mission_bar.dart';

import 'level_fixtures.dart';

/// A player at Level 10 part-way through the daily XP, with [missions].
Map<String, Object?> _level({
  List<Map<String, Object?>> missions = const [],
  List<String> claimed = const ['PLAY_15_MIN', 'PLAY_60_MIN', 'WIN_PAIR'],
  int xp = 4180,
}) => levelAt(10, xp: xp, claimed: claimed, missions: missions);

/// Three done, two part-way, the rest untouched.
final List<Map<String, Object?>> _someDone = [
  missionAt('FIRST_HAND', 1, 1, completed: true, xpAwarded: 5),
  missionAt('FIRST_WIN', 1, 1, completed: true, xpAwarded: 10),
  missionAt('GETTING_STARTED', 7, 10),
  missionAt('FIRST_5_WINS', 3, 5),
  missionAt('VARIATION_EXPLORER', 1, 1, completed: true, xpAwarded: 10),
];

Future<GameState> _openDaily(
  WidgetTester tester, {
  required Map<String, Object?> level,
  bool withMissions = true,
  Size screen = const Size(891, 411),
  double scale = 1.0,
  bool dark = true,
  AppLang lang = AppLang.english,
}) async {
  final state = levelState(
    level: level,
    lang: lang,
    ladderRead: ladder(withMissions: withMissions),
  );
  await pumpLevelLobby(tester, state, screen: screen, scale: scale, dark: dark);
  await openLevelScreen(tester);
  await showLevelTab(tester, 'daily');
  return state;
}

String _textOf(WidgetTester tester, Key key) =>
    tester.widget<Text>(find.byKey(key, skipOffstage: false)).data!;

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

PlayerLevel _pl(Map<String, Object?> j) => PlayerLevel.maybe(j)!;

void main() {
  setUpAll(() async {
    await loadLevelFonts();
    primeBadges();
  });
  tearDownAll(PictureCache.clearMemory);

  group('the wire', () {
    test('the missions stand apart from the daily sources: the day\'s most '
        'is still the eight daily sources\' 108', () {
      final l = ladder(withMissions: true);
      expect(l.sources.map((s) => s.code), allSourceCodes);
      expect(l.sources.every((s) => !s.oneTime), isTrue);
      expect(l.dailyMax, 108);
      expect(l.missions.map((m) => m.code), [
        for (final m in ownersMissions) m.$1,
      ]);
      final texas = l.sourceOf('TEXAS_HOLDEM_DEBUT')!;
      expect(texas.oneTime, isTrue);
      expect(texas.target, 1);
      expect(texas.scope, 'texas_holdem');
      expect(texas.xp, 15);
      expect(l.sourceOf('WIN_PAIR')!.oneTime, isFalse);
    });

    test('a ONE_TIME entry among the daily sources is filed with the '
        'missions, and never sums into the day', () {
      final json = ladderJson();
      final stray = {
        'code': 'FIRST_HAND',
        'name': 'First Hand',
        'kind': 'HANDS_PLAYED',
        'type': 'ONE_TIME',
        'target': 1,
        'xp': 50,
        'times': 1,
      };
      final l = LevelLadder.maybe({
        ...json,
        'xpSources': [...(json['xpSources']! as List), stray],
      })!;
      expect(l.dailyMax, 108);
      expect(l.missions.map((m) => m.code), ['FIRST_HAND']);
    });

    test('a server from before the missions: no missions, every source '
        'daily; a mission with no target is not offered', () {
      final old = ladder();
      expect(old.missions, isEmpty);
      expect(
        old.sources.every((s) => s.type == LadderSource.typeDaily),
        isTrue,
      );
      final json = ladderJson(withMissions: true);
      final l = LevelLadder.maybe({
        ...json,
        'missions': [
          {'code': 'NO_TARGET', 'kind': 'HANDS_PLAYED', 'xp': 5},
        ],
      })!;
      expect(l.missions, isEmpty);
    });

    test('a player\'s progress: listed missions, 0 for the rest, completed '
        'with when and what it gave', () {
      final level = _pl(_level(missions: _someDone));
      expect(level.missionOf('GETTING_STARTED')!.progress, 7);
      expect(level.missionOf('GETTING_STARTED')!.completed, isFalse);
      final first = level.missionOf('FIRST_WIN')!;
      expect(first.completed, isTrue);
      expect(first.xpAwarded, 10);
      expect(first.completedAt, greaterThan(0));
      expect(level.missionOf('CARD_PLAYER'), isNull);
      expect(_pl(_level()).missions, isEmpty);
    });

    test('the account\'s signature follows the missions, so the screen '
        'redraws when a hand moves one on', () {
      // One level read, its missions swapped: the daily window's reset (read
      // off the clock) is the same in all three.
      final base = _level(missions: _someDone);
      final a = playerUser(level: base);
      final b = playerUser(
        level: {
          ...base,
          'missions': [
            ..._someDone.take(2),
            missionAt('GETTING_STARTED', 8, 10),
            ..._someDone.skip(3),
          ],
        },
      );
      expect(levelSignatureOf(a), isNot(levelSignatureOf(b)));
      expect(
        levelSignatureOf(a),
        levelSignatureOf(playerUser(level: {...base})),
      );
    });
  });

  group('what each asks', () {
    test('the owner\'s twelve, in English', () {
      final t = Strings(AppLang.english);
      final l = ladder(withMissions: true);
      expect(
        {for (final m in l.missions) m.code: missionTask(t, m)},
        {
          'FIRST_HAND': 'Play 1 hand',
          'FIRST_WIN': 'Win 1 hand',
          'GETTING_STARTED': 'Play 10 hands',
          'FIRST_5_WINS': 'Win 5 hands',
          'CARD_PLAYER': 'Play 50 hands',
          'WINNING_STREAK': 'Win 10 hands',
          'FIRST_POKER_HAND': 'Play 1 Poker hand',
          'FIRST_POKER_WIN': 'Win 1 Poker hand',
          'TEXAS_HOLDEM_DEBUT': "Play 1 Texas Hold'em hand",
          'POKER_REGULAR': 'Play 50 Poker hands',
          'VARIATION_EXPLORER': 'Play 1 Variation hand',
          'GAME_EXPLORER': 'Play 5 different games',
        },
      );
      // A mission is named by its title; the task says what it asks.
      expect(xpSourceName(t, l.sourceOf('CARD_PLAYER')!), 'Card Player');
      // The variations reading (one UPDATE on the server).
      const variations = LadderSource(
        code: 'VARIATION_EXPLORER',
        xp: 100,
        kind: LadderSource.kindVariationsPlayed,
        type: LadderSource.typeOneTime,
        target: 3,
      );
      expect(missionTask(t, variations), 'Play 3 different variations');
    });

    test('every language has words for every task, none left in English', () {
      final english = Strings(AppLang.english);
      final l = ladder(withMissions: true);
      for (final lang in AppLang.values.where((l) => l != AppLang.english)) {
        final t = Strings(lang);
        for (final m in l.missions) {
          expect(
            missionTask(t, m),
            isNot(missionTask(english, m)),
            reason: '${lang.code} ${m.code}',
          );
          expect(
            missionTask(t, m),
            isNot(contains('{')),
            reason: '${lang.code} ${m.code}',
          );
        }
        for (final s in [
          t.xpOneTimeTitle,
          t.xpOneTimeNote,
          t.xpMissionCompleted,
          t.xpOneTimeDone(3, 12),
        ]) {
          expect(s, isNot(contains('{')), reason: lang.code);
        }
        expect(t.xpOneTimeTitle, isNot(english.xpOneTimeTitle));
        expect(t.xpMissionCompleted, isNot(english.xpMissionCompleted));
      }
    });
  });

  group('the Daily XP tab', () {
    testWidgets('a One-Time section under the daily XP: "7 / 10" over a bar '
        'while open, "✓ Completed" once done, how many are done — and the '
        'day\'s figure untouched', (tester) async {
      final state = await _openDaily(
        tester,
        level: _level(missions: _someDone),
      );
      final t = state.t;
      // The daily summary is the daily sources' alone.
      expect(_textOf(tester, const ValueKey('daily-xp-earned')), '24 / 108 XP');
      expect(
        find.byKey(const ValueKey('one-time-missions'), skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.text(t.xpOneTimeDone(3, 12), skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text(t.xpOneTimeTitle, skipOffstage: false), findsOneWidget);
      expect(find.text(t.xpOneTimeNote, skipOffstage: false), findsOneWidget);
      // Open, part-way: its progress and its bar.
      expect(
        _textOf(tester, const ValueKey('xp-mission-progress-GETTING_STARTED')),
        '7 / 10',
      );
      final bar = tester.widget<LevelBar>(
        find.byKey(
          const ValueKey('xp-mission-bar-GETTING_STARTED'),
          skipOffstage: false,
        ),
      );
      expect(bar.fraction, moreOrLessEquals(0.7));
      expect(
        _textOf(tester, const ValueKey('xp-mission-progress-FIRST_5_WINS')),
        '3 / 5',
      );
      // Untouched: 0 of its target.
      expect(
        _textOf(tester, const ValueKey('xp-mission-progress-CARD_PLAYER')),
        '0 / 50',
      );
      expect(
        _textOf(tester, const ValueKey('xp-mission-progress-GAME_EXPLORER')),
        '0 / 5',
      );
      // Completed: the tick and the word, in the completion green, and no
      // progress line.
      for (final code in ['FIRST_HAND', 'FIRST_WIN', 'VARIATION_EXPLORER']) {
        final done = find.byKey(
          ValueKey('xp-mission-done-$code'),
          skipOffstage: false,
        );
        expect(done, findsOneWidget, reason: code);
        expect(
          find.descendant(of: done, matching: find.text(t.xpMissionCompleted)),
          findsOneWidget,
        );
        final tick = tester.widget<Icon>(
          find.descendant(
            of: done,
            matching: find.byIcon(Icons.check_circle_rounded),
          ),
        );
        expect(tick.color, Theme.of(tester.element(done)).colorScheme.primary);
        expect(
          find.byKey(
            ValueKey('xp-mission-progress-$code'),
            skipOffstage: false,
          ),
          findsNothing,
        );
      }
      // The title, what it asks and the XP it gives.
      final tile = find.byKey(
        const ValueKey('xp-mission-TEXAS_HOLDEM_DEBUT'),
        skipOffstage: false,
      );
      for (final words in [
        "Texas Hold'em Debut",
        "Play 1 Texas Hold'em hand",
        '+15 XP',
        '0 / 1',
      ]) {
        expect(
          find.descendant(of: tile, matching: find.text(words)),
          findsOneWidget,
          reason: words,
        );
      }
      // No countdown on any mission: no reset, no timer.
      final section = find.byType(OneTimeMissionTile, skipOffstage: false);
      expect(section, findsNWidgets(12));
      for (final e in section.evaluate()) {
        final of = find.byWidget(e.widget, skipOffstage: false);
        expect(
          find.descendant(of: of, matching: find.byType(ResetsIn)),
          findsNothing,
        );
        expect(
          find.descendant(of: of, matching: find.byIcon(Icons.timer_outlined)),
          findsNothing,
        );
        expect(
          find.descendant(of: of, matching: find.textContaining('Resets')),
          findsNothing,
        );
      }
      await unmountLevel(tester, state);
    });

    testWidgets('a completed mission keeps its tick when the daily window '
        'has run out: no window touches it', (tester) async {
      final state = await _openDaily(
        tester,
        level: levelAt(10, xp: 4180, resetsIn: null, missions: _someDone),
      );
      expect(_textOf(tester, const ValueKey('daily-xp-earned')), '0 / 108 XP');
      expect(
        find.byKey(
          const ValueKey('xp-mission-done-FIRST_HAND'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        _textOf(tester, const ValueKey('xp-mission-progress-GETTING_STARTED')),
        '7 / 10',
      );
      await unmountLevel(tester, state);
    });

    testWidgets('a server from before the missions: the tab is the daily XP '
        'alone', (tester) async {
      final state = await _openDaily(
        tester,
        level: _level(),
        withMissions: false,
      );
      expect(
        find.byKey(const ValueKey('one-time-missions'), skipOffstage: false),
        findsNothing,
      );
      expect(
        find.byType(OneTimeMissionTile, skipOffstage: false),
        findsNothing,
      );
      expect(_textOf(tester, const ValueKey('daily-xp-earned')), '24 / 108 XP');
      await unmountLevel(tester, state);
    });

    testWidgets('a hand that moves a mission on redraws it', (tester) async {
      final state = await _openDaily(
        tester,
        level: _level(missions: _someDone),
      );
      expect(
        _textOf(tester, const ValueKey('xp-mission-progress-GETTING_STARTED')),
        '7 / 10',
      );
      state.user = playerUser(
        level: _level(
          xp: 4330,
          missions: [
            ..._someDone.take(2),
            missionAt(
              'GETTING_STARTED',
              10,
              10,
              completed: true,
              xpAwarded: 15,
            ),
            ..._someDone.skip(3),
          ],
        ),
      );
      // ignore: invalid_use_of_protected_member
      state.notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        find.byKey(
          const ValueKey('xp-mission-done-GETTING_STARTED'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.text(state.t.xpOneTimeDone(4, 12), skipOffstage: false),
        findsOneWidget,
      );
      await unmountLevel(tester, state);
    });
  });

  group('the XP mission bar', () {
    final l = ladder(withMissions: true);
    final window = DateTime.now().millisecondsSinceEpoch + 20 * hourMs;
    Map<String, Object?> at(
      int xp, {
      Map<String, int> claimed = const {},
      List<Map<String, Object?>> missions = const [],
      int? resetsAt,
    }) => {
      ..._level(xp: xp, missions: missions),
      'daily': {'claimed': claimed, 'resetsAt': resetsAt ?? window},
    };

    test('a one-time completion is announced as a daily one is, with the XP '
        'it gave and its title', () {
      final news = XpMissions.completions(
        _pl(at(4180, missions: [missionAt('GETTING_STARTED', 9, 10)])),
        _pl(
          at(
            4330,
            missions: [
              missionAt(
                'GETTING_STARTED',
                10,
                10,
                completed: true,
                xpAwarded: 15,
              ),
            ],
          ),
        ),
        l,
      );
      expect(news.map((n) => n.code), ['GETTING_STARTED']);
      expect(news.single.xp, 15);
      expect(news.single.total, 4330);
      final lines = XpMissionBar.linesFor(
        Strings(AppLang.english),
        news.single,
        l,
      );
      expect(lines.title, 'Getting Started completed');
      expect(lines.gained, '+15 XP');
      expect(lines.mark, '🚀');
    });

    test('a daily source and a mission in one award: two bars, the daily '
        'one first, the running totals adding up', () {
      final news = XpMissions.completions(
        _pl(at(10, claimed: {'PLAY_15_MIN': 1})),
        _pl(
          at(
            26,
            claimed: {'PLAY_15_MIN': 1, 'WIN_PAIR': 1},
            missions: [
              missionAt('FIRST_HAND', 1, 1, completed: true, xpAwarded: 5),
              missionAt('FIRST_WIN', 1, 1, completed: true, xpAwarded: 10),
            ],
          ),
        ),
        l,
      );
      expect(news.map((n) => n.code), ['WIN_PAIR', 'FIRST_HAND', 'FIRST_WIN']);
      expect(news.map((n) => n.xp), [1, 5, 10]);
      expect(news.map((n) => n.total), [11, 16, 26]);
    });

    test('never a mission completed before, a push that moved progress '
        'alone, or a window rolling over', () {
      final done = [
        missionAt('FIRST_HAND', 1, 1, completed: true, xpAwarded: 5),
      ];
      // Progress alone: no XP, no bar.
      expect(
        XpMissions.completions(
          _pl(at(4180, missions: [...done, missionAt('CARD_PLAYER', 3, 50)])),
          _pl(at(4180, missions: [...done, missionAt('CARD_PLAYER', 4, 50)])),
          l,
        ),
        isEmpty,
      );
      // A daily award beside a mission completed long ago: the daily one only.
      final news = XpMissions.completions(
        _pl(at(4180, missions: done)),
        _pl(at(4181, claimed: {'WIN_PAIR': 1}, missions: done)),
        l,
      );
      expect(news.map((n) => n.code), ['WIN_PAIR']);
      // A new window with a mission already done: nothing of the mission.
      expect(
        XpMissions.completions(
          _pl(at(4181, claimed: {'WIN_PAIR': 1}, missions: done)),
          _pl(
            at(
              4182,
              claimed: {'WIN_PAIR': 1},
              missions: done,
              resetsAt: window + dayMs,
            ),
          ),
          l,
        ).map((n) => n.code),
        ['WIN_PAIR'],
      );
    });

    test('player:level queues a mission the account completed', () {
      final state = levelState(level: at(4180), ladderRead: l);
      state.seeSessionStanding();
      state.handlePlayerLevel(
        Standing.maybe({
          'playerLevel': at(
            4185,
            missions: [
              missionAt('FIRST_HAND', 1, 1, completed: true, xpAwarded: 5),
            ],
          ),
          'badges': [regularBadge()],
          'taxBps': 1743,
        })!,
      );
      expect(state.xpMissions.queue.map((n) => n.code), ['FIRST_HAND']);
      state.dispose();
    });
  });

  group('layout', () {
    for (final dark in [true, false]) {
      testWidgets('640x360 x1.25 ${dark ? 'dark' : 'light'}: the One-Time '
          'section in every language, nothing overflowing, nothing cut, every '
          'tile inside the panel', (tester) async {
        for (final lang in AppLang.values) {
          final state = await _openDaily(
            tester,
            level: _level(missions: _someDone),
            screen: const Size(640, 360),
            scale: 1.25,
            dark: dark,
            lang: lang,
          );
          final where = '${lang.code} ${dark ? 'dark' : 'light'}';
          expect(tester.takeException(), isNull, reason: where);
          expect(_cut(find.byType(LevelScreen)), isEmpty, reason: where);
          final panel = tester.getRect(
            find.descendant(
              of: find.byType(LevelScreen),
              matching: find.byType(PremiumGlassPanel),
            ),
          );
          final tiles = find.byType(OneTimeMissionTile, skipOffstage: false);
          expect(tiles, findsNWidgets(12), reason: where);
          for (final e in tiles.evaluate()) {
            final r = tester.getRect(
              find.byWidget(e.widget, skipOffstage: false),
            );
            expect(
              r.left >= panel.left - 0.5 && r.right <= panel.right + 0.5,
              isTrue,
              reason:
                  '$where ${(e.widget as OneTimeMissionTile).mission.code} $r in $panel',
            );
          }
          // Scrolled into view, the last tile draws whole too.
          await tester.ensureVisible(
            find.byKey(
              const ValueKey('xp-mission-GAME_EXPLORER'),
              skipOffstage: false,
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
          expect(tester.takeException(), isNull, reason: where);
          await unmountLevel(tester, state);
        }
      });
    }
  });
}
