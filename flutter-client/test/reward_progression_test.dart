// The reward programs' progression (owner, 1 Oct 2026: "mode = WHAT
// triggers progress, progression_type = HOW progress behaves … The Flutter
// UI should show: current reward cycle, current day, claimed days, available
// reward, locked rewards, broken state, next period countdown … Use server
// timestamps as the source of truth. Do not make Flutter calculate reward
// eligibility"): RESET, SEQUENTIAL and BREAK as the server describes them —
// a program's status, whether a claim can be made, the next day, the
// period's dates, the next period, each day's state — and the claim that
// names one program.
//
// These hold the wire (every new key read, and a server that sends none read
// as it always was), the words (every new key in all five languages, the
// dates, the waits, the hints), the API (a named claim's body, its refusals,
// an older server's 404), GameState (a refusal said in the player's words
// and the programs read again; the weekly popup never offered for a cycle
// that cannot be collected), the lobby chip (Collect by the server's
// verdict; "Streak broken"), the screen (an ACTIVE RESET week, an ACTIVE
// SEQUENTIAL one, the brief's BROKEN CALENDAR+BREAK week, a COMPLETED one, a
// month; the cycle line; the countdown on its own timer, reading the
// programs again once at zero; a day's tile collecting its own program,
// once, the loader on it meanwhile; a refusal on the screen), and every
// panel at 640x360 and 592x360 x1.25 in all five languages and both themes
// with the Noto fonts.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/api_client.dart';
import 'package:teenpatti/screens/reward_programs_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/weekly_login.dart';

import 'reward_fixtures.dart';

List<String> _posts(List<http.Request> sent) => [
  for (final r in sent)
    if (r.method == 'POST') r.url.path,
];

/// The reads of the programs (the lobby's Friends key reads its count too).
List<String> _gets(List<http.Request> sent) => [
  for (final r in sent)
    if (r.method == 'GET' && r.url.path.startsWith('/api/reward-programs'))
      r.url.path,
];

/// The reward clock on the test's fake clock, which its pumps advance.
void _fakeRewardClock(WidgetTester tester) {
  rewardClock = () => tester.binding.clock.now();
  addTearDown(() => rewardClock = DateTime.now);
}

/// A bare page with a key that opens the rewards, as the lobby's chip does.
Future<void> _openScreen(
  WidgetTester tester,
  GameState state, {
  Brightness brightness = Brightness.dark,
}) async {
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  await tester.pumpWidget(
    rewardApp(
      state,
      feedback,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showRewardPrograms(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      brightness: brightness,
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 600));
}

String? _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data;

/// What a screen reader hears of day [k] of program [code].
String _heard(WidgetTester tester, String code, int k) =>
    tester.getSemantics(find.byKey(ValueKey('reward-day-$code-$k'))).label;

/// Every Collect on the screen, of any day of any program.
Finder get _anyCollect => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key as ValueKey<String>).value.startsWith('reward-collect-'),
);

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

/// The new strings, every one translated.
const _newKeys = [
  'rewardTileCollect',
  'rewardBrokenShort',
  'rewardBrokenTitle',
  'rewardAllCollected',
  'rewardBreakHint',
  'rewardMissedDay',
  'rewardNewCycleStarts',
  'rewardNextWeekIn',
  'rewardNextMonthIn',
  'rewardProgramGone',
  'rewardProgramNotRunning',
  'rewardCycleBrokenNotice',
  'rewardCycleCompletedNotice',
  'month1',
  'month2',
  'month3',
  'month4',
  'month5',
  'month6',
  'month7',
  'month8',
  'month9',
  'month10',
  'month11',
  'month12',
  'dateDayMonth',
  'weekdayFull1',
  'weekdayFull2',
  'weekdayFull3',
  'weekdayFull4',
  'weekdayFull5',
  'weekdayFull6',
  'weekdayFull7',
];

/// The four refusals of a claim that names one program.
const _refusals = [
  (404, 'reward_program_not_found'),
  (409, 'reward_program_not_running'),
  (409, 'reward_cycle_broken'),
  (409, 'reward_cycle_completed'),
];

/// Day 3 of the mock's week collected: what the claim's answer says after.
Map<String, Object?> _day3Claimed() => progressedWeekJson(
  progression: 'RESET',
  states: const [
    'CLAIMED',
    'CLAIMED',
    'CLAIMED',
    'LOCKED',
    'LOCKED',
    'LOCKED',
    'LOCKED',
  ],
  currentDay: 3,
  claimedToday: true,
  canClaim: false,
  nextDay: 4,
);

/// The claim's answer to the mock's Day 3: its chips, and the week after.
Map<String, Object?> _day3ClaimJson() => {
  'serverTime': progressionServerTime,
  'granted': [
    grantJson(
      code: 'WEEKLY_LOGIN',
      day: 3,
      reward: dayJson(3, 'CHIPS', value: 20000),
    ),
  ],
  'results': [
    {
      'programCode': 'WEEKLY_LOGIN',
      'outcome': 'GRANTED',
      'day': 3,
      'rewardType': 'CHIPS',
      'rewardValue': 20000,
      'claimedAt': 1791801600000,
    },
  ],
  'programs': [_day3Claimed()],
  'user': userJson(chips: 1020000),
};

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadRewardFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the wire', () {
    test('a program from the progression engine reads every new key', () {
      final arrived = DateTime.utc(2026, 10, 7, 12);
      final s = RewardProgramState.fromJson(
        activeResetWeekJson(),
        receivedAt: arrived,
        serverTime: progressionServerTime,
      );
      expect(s.program.progressionType, 'RESET');
      expect(s.program.progression, RewardProgression.reset);
      expect(s.status, RewardStatus.active);
      expect(s.isActive, isTrue);
      expect(s.isBroken, isFalse);
      expect(s.isCompleted, isFalse);
      expect(s.canClaim, isTrue);
      expect(s.canClaimToday, isTrue);
      expect(s.serverNextDay, 3);
      expect(s.nextDay, 3);
      expect(s.nextReward?.prize.amount, 20000);
      expect(s.missedDay, 0);
      expect(s.serverTime, progressionServerTime);
      expect(s.rewards.map((d) => d.state), [
        RewardDayState.claimed,
        RewardDayState.claimed,
        RewardDayState.available,
        RewardDayState.locked,
        RewardDayState.locked,
        RewardDayState.locked,
        RewardDayState.locked,
      ]);
      // The period's dates, as labels.
      expect(s.cycle?.startDate, weekStart);
      expect(s.cycle?.endDate, weekEnd);
      expect(s.cycle?.firstDay, DateTime.utc(2026, 10, 5));
      expect(s.cycle?.lastDay, DateTime.utc(2026, 10, 11));
      // The next period, counted from the moment the answer arrived.
      final next = s.nextCycle!;
      expect(next.startDate, nextMonday);
      expect(next.firstDay?.weekday, DateTime.monday);
      expect(next.startsInMs, threeDaysEightHours);
      expect(next.receivedAt, arrived);
      expect(
        next.startsAt,
        arrived.add(const Duration(milliseconds: threeDaysEightHours)),
      );
      expect(
        next.leftAt(arrived.add(const Duration(days: 1))),
        const Duration(milliseconds: threeDaysEightHours) -
            const Duration(days: 1),
      );
      expect(next.leftAt(arrived.add(const Duration(days: 9))), Duration.zero);
    });

    test('a broken cycle names the day it missed and has no next day; a '
        'completed one has none either; a sequential one goes on', () {
      final broken = RewardProgramState.fromJson(brokenCalendarWeekJson());
      expect(broken.program.progression, RewardProgression.breaks);
      expect(broken.isBroken, isTrue);
      // Not collected today, and still not collectable: the server says so.
      expect(broken.claimedToday, isFalse);
      expect(broken.canClaimToday, isFalse);
      expect(broken.currentDay, 3);
      expect(broken.missedDay, 3);
      expect(broken.dayOfPeriod, 4);
      expect(broken.nextDay, isNull);
      expect(broken.nextReward, isNull);

      final done = RewardProgramState.fromJson(completedWeekJson());
      expect(done.isCompleted, isTrue);
      expect(done.canClaimToday, isFalse);
      expect(done.nextDay, isNull);
      expect(done.missedDay, 0);

      final sequential = RewardProgramState.fromJson(
        activeSequentialWeekJson(),
      );
      expect(sequential.program.progression, RewardProgression.sequential);
      expect(sequential.nextDay, 4);
      expect(sequential.canClaimToday, isTrue);
    });

    test('an older server sends none of it, and is read as it always was', () {
      final waiting = RewardProgramState.fromJson(
        streakJson(claimedToday: false),
      );
      expect(waiting.program.progressionType, '');
      // It reset on a missed day: RESET.
      expect(waiting.program.progression, RewardProgression.reset);
      expect(waiting.status, RewardStatus.active);
      expect(waiting.canClaim, isNull);
      expect(waiting.canClaimToday, isTrue);
      expect(waiting.serverNextDay, isNull);
      expect(waiting.nextDay, 3);
      expect(waiting.cycle, isNull);
      expect(waiting.nextCycle, isNull);
      expect(waiting.serverTime, 0);
      expect(waiting.rewards.map((d) => d.state).toSet(), {null});

      final collected = RewardProgramState.fromJson(streakJson());
      expect(collected.canClaimToday, isFalse);
      expect(collected.nextDay, 4);

      // A streak that did not reset: SEQUENTIAL; and the old calendar is a
      // SEQUENTIAL calendar.
      final noReset = RewardProgramState.fromJson({
        ...streakJson(),
        'program': programJson(
          code: 'WEEKLY_LOGIN',
          mode: 'LOGIN_STREAK',
          periodType: 'WEEKLY',
          reset: false,
        ),
      });
      expect(noReset.program.progression, RewardProgression.sequential);
      final calendar = RewardProgramState.fromJson(calendarJson());
      expect(calendar.program.progression, RewardProgression.sequential);
      expect(calendar.canClaimToday, isTrue);
      expect(calendar.nextDay, 10);
    });

    test('a word the server has never used reads as nothing, and a next '
        'period with no wait is counted from the answer\'s clock', () {
      final odd = RewardProgramState.fromJson({
        ...activeResetWeekJson(),
        'program': {
          ...programJson(
            code: 'WEEKLY_LOGIN',
            mode: 'LOGIN_STREAK',
            periodType: 'WEEKLY',
            reset: false,
          ),
          'progressionType': 'FLEXIBLE',
        },
        'status': 'PAUSED',
        'canClaim': 'yes',
        'nextDay': 'soon',
        'period': {'startDate': '2026-02-31', 'endDate': weekEnd},
        'rewards': [
          {...dayJson(1, 'CHIPS', value: 1), 'state': 'MAYBE'},
        ],
      });
      expect(odd.program.progressionType, 'FLEXIBLE');
      expect(odd.program.progression, RewardProgression.sequential);
      expect(odd.status, RewardStatus.active);
      expect(odd.canClaim, isNull);
      expect(odd.serverNextDay, isNull);
      // No 31 February: no cycle line.
      expect(odd.cycle, isNull);
      expect(odd.rewards.single.state, isNull);

      final arrived = DateTime.utc(2026, 10, 7);
      final counted = RewardProgramState.fromJson(
        {
          ...activeResetWeekJson(),
          'nextPeriod': {
            'startAt': progressionServerTime + 3600000,
            'startDate': nextMonday,
          },
        },
        receivedAt: arrived,
        serverTime: progressionServerTime,
      );
      expect(counted.nextCycle?.startsInMs, 3600000);
      expect(
        counted.nextCycle?.startsAt,
        arrived.add(const Duration(hours: 1)),
      );

      // Nothing to count at all: the date is still read.
      final uncounted = RewardProgramState.fromJson({
        ...activeResetWeekJson(),
        'nextPeriod': {'startDate': nextMonday},
      });
      expect(uncounted.nextCycle?.startsInMs, isNull);
      expect(uncounted.nextCycle?.startsAt, isNull);
      expect(uncounted.nextCycle?.leftAt(DateTime.now()), isNull);
      expect(uncounted.nextCycle?.firstDay, DateTime.utc(2026, 10, 12));

      // A campaign that ends before the next period: none.
      expect(
        RewardProgramState.fromJson(
          progressedWeekJson(
            progression: 'RESET',
            states: List.filled(7, 'LOCKED'),
            currentDay: 1,
            claimedToday: false,
            canClaim: true,
            nextDay: 1,
            nextPeriod: false,
          ),
        ).nextCycle,
        isNull,
      );
    });

    test('a claim reads what it did for every program, and its clock', () {
      final arrived = DateTime.utc(2026, 10, 7);
      final r = RewardClaimResult.fromJson({
        ..._day3ClaimJson(),
        'results': [
          ...(_day3ClaimJson()['results']! as List),
          {'programCode': 'WEEKLY_BREAK_CALENDAR', 'outcome': 'BROKEN'},
          {
            'programCode': 'MONTHLY_CALENDAR',
            'outcome': 'ALREADY_CLAIMED',
            'day': 10,
            'rewardType': 'EMOJI',
            'rewardRefId': '5',
          },
          {'programCode': 'DONE', 'outcome': 'COMPLETED'},
        ],
      }, receivedAt: arrived);
      expect(r.serverTime, progressionServerTime);
      expect(r.granted.single.day, 3);
      expect(r.results.map((o) => o.outcome), [
        RewardOutcome.granted,
        RewardOutcome.broken,
        RewardOutcome.alreadyClaimed,
        RewardOutcome.completed,
      ]);
      final granted = r.results.first;
      expect(granted.programCode, 'WEEKLY_LOGIN');
      expect(granted.day, 3);
      expect(granted.prize?.amount, 20000);
      expect(granted.claimedAt, 1791801600000);
      expect(r.results[1].day, 0);
      expect(r.results[1].prize, isNull);
      expect(r.results[2].prize?.kind, RewardKind.emoji);
      // The programs after, on the answer's clock.
      expect(r.programs.single.serverTime, progressionServerTime);
      expect(r.programs.single.nextCycle?.receivedAt, arrived);
      expect(r.programs.single.canClaimToday, isFalse);
      // An older server's answer has no results.
      expect(RewardClaimResult.fromJson(claimJson()).results, isEmpty);
      expect(RewardClaimResult.fromJson(claimJson()).serverTime, 0);
    });
  });

  group('the words', () {
    test('every new key is in all five languages, and translated', () {
      final english = Strings(AppLang.english);
      for (final lang in AppLang.values) {
        final t = Strings(lang);
        for (final key in _newKeys) {
          final own = t.ownEntry(key);
          expect(own, isNotNull, reason: '${lang.name} lacks $key');
          expect(own, isNotEmpty, reason: '${lang.name} $key');
          if (lang != AppLang.english) {
            expect(
              own,
              isNot(english.ownEntry(key)),
              reason: '${lang.name} $key is the English',
            );
          }
        }
        // Twelve months and seven days, every one its own.
        expect({for (var m = 1; m <= 12; m++) t.monthShort(m)}.length, 12);
        expect({for (var d = 1; d <= 7; d++) t.weekdayFull(d)}.length, 7);
        expect(t.rewardMissedDay(3), contains('3'), reason: lang.name);
        expect(t.rewardNewCycleStarts('X'), contains('X'), reason: lang.name);
        final week = t.rewardNextCycleIn(weekly: true, time: 'T');
        final month = t.rewardNextCycleIn(weekly: false, time: 'T');
        expect(week, contains('T'), reason: lang.name);
        expect(month, contains('T'), reason: lang.name);
        expect(week, isNot(month), reason: lang.name);
        final date = t.dateShort(DateTime.utc(2026, 10, 5));
        expect(date, contains('5'), reason: lang.name);
        expect(date, contains(t.monthShort(10)), reason: lang.name);
        // The refusals GameState says, in this language.
        final state = rewardState(lang: lang, signedIn: false);
        for (final (_, code) in _refusals) {
          expect(state.rewardRefusalText(code), isNotNull, reason: code);
        }
        expect(state.rewardRefusalText('seated'), isNull);
        state.dispose();
      }
    });

    test('dates, waits and hints', () {
      final en = Strings(AppLang.english);
      expect(en.dateShort(DateTime.utc(2026, 10, 5)), 'Oct 5');
      expect(
        Strings(AppLang.hindi).dateShort(DateTime.utc(2026, 10, 5)),
        '5 अक्तू॰',
      );
      expect(
        rewardCycleLabel(en, RewardCycle.fromJson(periodJson())),
        'Oct 5 – Oct 11',
      );
      expect(rewardCycleLabel(en, null), isNull);
      // The wait: days and hours, hours and minutes, minutes and seconds.
      String wait(Duration d) => NextCycleCountdown.waitWords(d, en);
      expect(wait(const Duration(milliseconds: threeDaysEightHours)), '3d 8h');
      expect(wait(const Duration(days: 12, hours: 4, minutes: 3)), '12d 4h');
      expect(wait(const Duration(days: 1)), '1d 0h');
      expect(wait(const Duration(hours: 5, minutes: 12, seconds: 7)), '5h 12m');
      expect(wait(const Duration(minutes: 12, seconds: 5)), '12m 5s');
      // Rounded up: never "0s" while there is still a wait.
      expect(wait(const Duration(seconds: 44, milliseconds: 200)), '45s');
      expect(wait(const Duration(milliseconds: 1)), '1s');
      expect(
        en.rewardNextCycleIn(weekly: true, time: '3d 8h'),
        'Next weekly rewards in 3d 8h',
      );
      expect(
        en.rewardNextCycleIn(weekly: false, time: '12d 4h'),
        'Next monthly rewards in 12d 4h',
      );
      // The line is nothing once the period has begun, or with nothing to
      // count.
      final next = RewardNextCycle(
        startDate: nextMonday,
        startsInMs: 60000,
        receivedAt: DateTime.utc(2026, 10, 7),
      );
      expect(
        NextCycleCountdown.lineAt(
          en,
          next,
          weekly: true,
          now: DateTime.utc(2026, 10, 7),
        ),
        'Next weekly rewards in 1m 0s',
      );
      expect(
        NextCycleCountdown.lineAt(
          en,
          next,
          weekly: true,
          now: DateTime.utc(2026, 10, 7, 0, 1),
        ),
        isNull,
      );
      // What a progression means.
      RewardProgramInfo program(Map<String, Object?> j) =>
          RewardProgramState.fromJson(j).program;
      expect(
        rewardProgramHint(en, program(brokenCalendarWeekJson())),
        en.rewardBreakHint,
      );
      expect(
        rewardProgramHint(en, program(activeResetWeekJson())),
        en.rewardStreakHint,
      );
      expect(
        rewardProgramHint(en, program(activeSequentialWeekJson())),
        en.rewardStreakHintNoReset,
      );
      // A sequential calendar is the calendar it always was.
      expect(
        rewardProgramHint(en, program(progressedMonthJson())),
        en.rewardCalendarMonthHint,
      );
      // An older server's programs, as before.
      expect(rewardProgramHint(en, program(streakJson())), en.rewardStreakHint);
      expect(
        rewardProgramHint(en, program(calendarJson())),
        en.rewardCalendarMonthHint,
      );
      // When the next cycle starts: a week's weekday, a month's date.
      expect(
        rewardNextCycleStart(
          en,
          RewardProgramState.fromJson(brokenCalendarWeekJson()),
        ),
        'Monday',
      );
      expect(
        rewardNextCycleStart(
          en,
          RewardProgramState.fromJson(progressedMonthJson()),
        ),
        'Nov 1',
      );
      expect(
        rewardNextCycleStart(en, RewardProgramState.fromJson(streakJson())),
        isNull,
      );
    });
  });

  group('the API', () {
    test('a claim names its program only when asked to', () async {
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final api = ApiClient(rewardServer);
        final all = await api.claimRewardPrograms('tok');
        final one = await api.claimRewardPrograms(
          'tok',
          programCode: 'WEEKLY_SEQUENTIAL_CAL',
        );
        expect(all, isNotNull);
        expect(one, isNotNull);
      }, () => fakeRewards(sent: sent));
      final posts = sent.where((r) => r.method == 'POST').toList();
      expect(posts.length, 2);
      expect(posts.first.body, '{}');
      expect(jsonDecode(posts.last.body), {
        'programCode': 'WEEKLY_SEQUENTIAL_CAL',
      });
      expect(posts.last.headers['Authorization'], 'Bearer tok');
    });

    test('a named program\'s refusal is thrown with its code; an older '
        'server\'s 404 and none running are nothing', () async {
      for (final (status, code) in _refusals) {
        await http.runWithClient(
          () async {
            await expectLater(
              ApiClient(rewardServer).claimRewardPrograms(
                'tok',
                programCode: 'WEEKLY_BREAK_CALENDAR',
              ),
              throwsA(isA<ApiException>().having((e) => e.code, 'code', code)),
            );
          },
          () => MockClient(
            (_) async => rewardJson({'error': code, 'message': 'No.'}, status),
          ),
        );
      }
      for (final (status, code) in const [
        (404, 'not_found'),
        (503, 'reward_programs_unavailable'),
      ]) {
        await http.runWithClient(() async {
          expect(
            await ApiClient(
              rewardServer,
            ).claimRewardPrograms('tok', programCode: 'WEEKLY_LOGIN'),
            isNull,
          );
        }, () => MockClient((_) async => rewardJson({'error': code}, status)));
      }
    });

    test('a read stamps when it arrived and the server\'s clock', () async {
      final arrived = DateTime.utc(2026, 10, 7, 9);
      rewardClock = () => arrived;
      addTearDown(() => rewardClock = DateTime.now);
      await http.runWithClient(
        () async {
          final programs = await ApiClient(rewardServer).rewardPrograms('tok');
          final s = programs!.single;
          expect(s.serverTime, progressionServerTime);
          expect(s.nextCycle?.receivedAt, arrived);
          expect(
            s.nextCycle?.leftAt(arrived),
            const Duration(milliseconds: threeDaysEightHours),
          );
        },
        () => MockClient(
          (_) async =>
              rewardJson(progressedProgramsJson([activeResetWeekJson()])),
        ),
      );
    });
  });

  group('GameState', () {
    test(
      'a named claim sends its program, and is marked while it is out',
      () async {
        final sent = <http.Request>[];
        final claimRelease = Completer<void>();
        await http.runWithClient(
          () async {
            final state = rewardState();
            addTearDown(state.dispose);
            final claim = state.claimRewardPrograms(
              programCode: 'WEEKLY_LOGIN',
            );
            expect(state.rewardClaimPending, isTrue);
            expect(state.rewardClaimProgram, 'WEEKLY_LOGIN');
            // Nothing else is sent while it is out.
            expect(await state.claimRewardPrograms(), isNull);
            claimRelease.complete();
            final granted = await claim;
            expect(granted?.single.day, 3);
            expect(_posts(sent), ['/api/reward-programs/claim']);
            expect(jsonDecode(sent.single.body), {
              'programCode': 'WEEKLY_LOGIN',
            });
            expect(state.rewardClaimPending, isFalse);
            expect(state.rewardClaimProgram, isNull);
            expect(state.rewardsGranted?.single.day, 3);
            expect(state.rewardPrograms?.single.claimedToday, isTrue);
            expect(state.rewardsDue, isFalse);
            expect(state.user?.chips, 1020000);
          },
          () => fakeRewards(
            sent: sent,
            claim: _day3ClaimJson(),
            claimRelease: claimRelease,
          ),
        );
      },
    );

    test('a named claim refused is said in the player\'s words, and the '
        'programs are read again', () async {
      for (final lang in [AppLang.english, AppLang.hindi]) {
        for (final (status, code) in _refusals) {
          final sent = <http.Request>[];
          await http.runWithClient(
            () async {
              final state = rewardState(lang: lang);
              addTearDown(state.dispose);
              final granted = await state.claimRewardPrograms(
                programCode: 'WEEKLY_BREAK_CALENDAR',
              );
              expect(granted, isNull, reason: code);
              final t = Strings(lang);
              expect(state.notice, switch (code) {
                'reward_program_not_found' => t.rewardProgramGone,
                'reward_program_not_running' => t.rewardProgramNotRunning,
                'reward_cycle_broken' => t.rewardCycleBrokenNotice,
                _ => t.rewardCycleCompletedNotice,
              }, reason: '${lang.name} $code');
              // Never the server's English words.
              expect(state.notice, isNot(contains('No.')));
              // The truth read again, and shown.
              await pumpEventQueue();
              expect(_gets(sent), ['/api/reward-programs'], reason: code);
              expect(state.rewardPrograms?.single.isBroken, isTrue);
              expect(state.rewardProgramsFailed, isFalse);
              expect(state.rewardsGranted, isNull);
              expect(state.rewardClaimPending, isFalse);
            },
            () => fakeRewards(
              sent: sent,
              claimResponse: rewardJson({
                'error': code,
                'message': 'No.',
              }, status),
              programs: progressedProgramsJson([brokenCalendarWeekJson()]),
            ),
          );
        }
      }
    });

    test('what can be collected is the server\'s verdict: the weekly popup '
        'is never offered for a broken cycle, nor one the server says is '
        'done for today', () async {
      for (final program in [
        brokenLoginWeekJson(),
        {...activeResetWeekJson(), 'canClaim': false},
      ]) {
        final sent = <http.Request>[];
        await http.runWithClient(
          () async {
            final state = rewardState();
            addTearDown(state.dispose);
            // The consent's read lands.
            await pumpEventQueue();
            await state.loadRewardPrograms();
            final s = state.rewardPrograms!.single;
            expect(s.claimedToday, isFalse);
            expect(s.canClaimToday, isFalse);
            expect(state.rewardsDue, isFalse);
            expect(state.weeklyLoginDue, isNull);
            expect(state.weeklyLoginOffer, isNull);
            expect(state.offerWeeklyLogin(again: true), isFalse);
            expect(state.weeklyLoginOffer, isNull);
          },
          () => fakeRewards(
            sent: sent,
            programs: progressedProgramsJson([program]),
          ),
        );
      }
      // The control: a day the server says can be collected is offered.
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          addTearDown(state.dispose);
          await pumpEventQueue();
          await state.loadRewardPrograms();
          expect(state.rewardsDue, isTrue);
          expect(state.weeklyLoginOffer?.program.code, 'WEEKLY_LOGIN');
        },
        () => fakeRewards(
          sent: sent,
          programs: progressedProgramsJson([activeResetWeekJson()]),
        ),
      );
    });

    test('a new cycle reads the programs once, however many panels count to '
        'it', () async {
      final sent = <http.Request>[];
      final release = Completer<void>();
      await http.runWithClient(
        () async {
          final state = rewardState();
          addTearDown(state.dispose);
          final first = state.rewardCycleTurned();
          // A second panel at the same moment: the read is already out.
          final second = state.rewardCycleTurned();
          release.complete();
          await Future.wait([first, second]);
          expect(_gets(sent), ['/api/reward-programs']);
          // Straight after, again: nothing more (the server has the new
          // cycle already).
          await state.rewardCycleTurned();
          expect(_gets(sent), ['/api/reward-programs']);
        },
        () => fakeRewards(
          sent: sent,
          release: release,
          programs: progressedProgramsJson([activeResetWeekJson()]),
        ),
      );
    });
  });

  group('the lobby chip', () {
    testWidgets('a broken cycle waits for nothing: no Collect, no popup, '
        '"Streak broken", and a tap opens the screen', (tester) async {
      await setRewardView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          await pumpRewardLobby(tester, state);
          final t = state.t;
          final chip = find.byKey(const ValueKey('rewards-chip'));
          expect(chip, findsOneWidget);
          expect(
            find.descendant(of: chip, matching: find.text(t.rewardBrokenShort)),
            findsOneWidget,
          );
          expect(
            find.descendant(of: chip, matching: find.text(t.rewardsCollect)),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey('weekly-login-overlay')),
            findsNothing,
          );
          await tester.tap(chip);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pump(const Duration(milliseconds: 600));
          expect(find.byType(RewardProgramsScreen), findsOneWidget);
          expect(
            find.byKey(const ValueKey('weekly-login-overlay')),
            findsNothing,
          );
          expect(_posts(sent), isEmpty);
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          programs: progressedProgramsJson([brokenLoginWeekJson()]),
        ),
      );
    });

    testWidgets('Collect follows canClaim, not claimedToday', (tester) async {
      await setRewardView(tester);
      for (final (program, collect) in [
        (activeResetWeekJson(), true),
        ({...activeResetWeekJson(), 'canClaim': false}, false),
      ]) {
        final sent = <http.Request>[];
        await http.runWithClient(
          () async {
            final state = rewardState();
            await pumpRewardLobby(tester, state);
            final t = state.t;
            final chip = find.byKey(const ValueKey('rewards-chip'));
            expect(
              find.descendant(of: chip, matching: find.text(t.rewardsCollect)),
              collect ? findsOneWidget : findsNothing,
            );
            if (!collect) {
              // The run so far, as before: two days.
              expect(
                find.descendant(of: chip, matching: find.text(t.streakDays(2))),
                findsOneWidget,
              );
            }
            await unmountReward(tester, state);
          },
          () => fakeRewards(
            sent: sent,
            programs: progressedProgramsJson([program]),
          ),
        );
      }
    });
  });

  group('the weekly popup', () {
    test('a day is today\'s to collect only by the server\'s word', () {
      final active = RewardProgramState.fromJson(activeResetWeekJson());
      expect(weeklyDayStateOf(active, 1), WeeklyDayState.claimed);
      expect(weeklyDayStateOf(active, 3), WeeklyDayState.current);
      expect(weeklyDayStateOf(active, 4), WeeklyDayState.next);
      expect(weeklyDayStateOf(active, 7), WeeklyDayState.finalDay);
      // Broken: the missed day is no day to collect, nor the one after.
      final broken = RewardProgramState.fromJson(brokenLoginWeekJson());
      expect(weeklyDayStateOf(broken, 2), WeeklyDayState.claimed);
      expect(weeklyDayStateOf(broken, 3), WeeklyDayState.locked);
      expect(weeklyDayStateOf(broken, 4), WeeklyDayState.locked);
      // The server's state for a day outranks the run's figures.
      final odd = RewardProgramState.fromJson(
        progressedWeekJson(
          progression: 'RESET',
          states: const [
            'CLAIMED',
            'CLAIMED',
            'LOCKED',
            'LOCKED',
            'AVAILABLE',
            'LOCKED',
            'LOCKED',
          ],
          currentDay: 3,
          claimedToday: false,
          canClaim: true,
          nextDay: 3,
        ),
      );
      expect(weeklyDayStateOf(odd, 3), isNot(WeeklyDayState.current));
      expect(weeklyDayStateOf(odd, 5), WeeklyDayState.current);
      // Told no claim can be made, with no state for the day: not today's
      // to collect either.
      final told = RewardProgramState.fromJson({
        ...streakJson(claimedToday: false),
        'canClaim': false,
      });
      expect(weeklyDayStateOf(told, 3), isNot(WeeklyDayState.current));
      // An older server, as before.
      final old = RewardProgramState.fromJson(streakJson(claimedToday: false));
      expect(weeklyDayStateOf(old, 2), WeeklyDayState.claimed);
      expect(weeklyDayStateOf(old, 3), WeeklyDayState.current);
      expect(weeklyDayStateOf(old, 4), WeeklyDayState.next);
      // The day just collected, whatever the state still says.
      expect(weeklyDayStateOf(active, 3, collected: 3), WeeklyDayState.claimed);
    });

    testWidgets('a popup up when the cycle can no longer be collected offers '
        'Continue, never Collect', (tester) async {
      await setRewardView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          await pumpRewardLobby(tester, state);
          await tester.pump(const Duration(seconds: 2));
          expect(
            find.byKey(const ValueKey('weekly-login-overlay')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('weekly-login-collect')),
            findsOneWidget,
          );
          // The programs read again meanwhile: the cycle has broken.
          state.rewardPrograms = rewardProgramsFromJson([
            brokenLoginWeekJson(),
          ]);
          // ignore: invalid_use_of_protected_member
          state.notifyListeners();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            find.byKey(const ValueKey('weekly-login-collect')),
            findsNothing,
          );
          final done = find.byKey(const ValueKey('weekly-login-done'));
          expect(done, findsOneWidget);
          await tester.tap(done);
          await tester.pump();
          expect(state.weeklyLoginOffer, isNull);
          expect(_posts(sent), isEmpty);
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          programs: progressedProgramsJson([activeResetWeekJson()]),
        ),
      );
    });
  });

  group('the screen', () {
    testWidgets('a day\'s standing is the server\'s word, never worked out on '
        'the phone: Collect stands where it says AVAILABLE', (tester) async {
      await setRewardView(tester, screen: const Size(915, 412));
      _fakeRewardClock(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          final handle = tester.ensureSemantics();
          await _openScreen(tester, state);
          final t = state.t;
          const code = 'WEEKLY_LOGIN';
          // The run's figures would make Day 3 today's; the server says
          // Day 3 is locked and Day 5 can be collected.
          expect(_heard(tester, code, 3), contains(t.rewardTileLocked));
          expect(_heard(tester, code, 5), contains(t.rewardTileCollect));
          expect(
            find.byKey(const ValueKey('reward-collect-$code-5')),
            findsOneWidget,
          );
          expect(_anyCollect, findsOneWidget);
          handle.dispose();
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          programs: progressedProgramsJson([
            progressedWeekJson(
              progression: 'RESET',
              states: const [
                'CLAIMED',
                'CLAIMED',
                'LOCKED',
                'LOCKED',
                'AVAILABLE',
                'LOCKED',
                'LOCKED',
              ],
              currentDay: 3,
              claimedToday: false,
              canClaim: true,
              nextDay: 3,
            ),
          ]),
        ),
      );
    });

    testWidgets('an ACTIVE RESET week: its cycle, "2 day streak", what a '
        'reset means, Days 1–2 collected, Day 3 to collect, 4–7 locked, the '
        'next reward and the countdown', (tester) async {
      await setRewardView(tester, screen: const Size(915, 412));
      _fakeRewardClock(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          final handle = tester.ensureSemantics();
          await _openScreen(tester, state);
          expect(tester.takeException(), isNull);
          final t = state.t;
          const code = 'WEEKLY_LOGIN';
          expect(_text(tester, 'reward-headline-$code'), t.streakDays(2));
          expect(_text(tester, 'reward-cycle-$code'), 'Oct 5 – Oct 11');
          expect(_text(tester, 'reward-hint-$code'), t.rewardStreakHint);
          for (final k in [1, 2]) {
            expect(_heard(tester, code, k), contains(t.rewardTileClaimed));
          }
          // Day 3: today's, to collect — said, shown and pressable.
          expect(_heard(tester, code, 3), contains(t.rewardToday));
          expect(_heard(tester, code, 3), contains(t.rewardTileCollect));
          expect(_heard(tester, code, 3), contains('20,000'));
          expect(_heard(tester, code, 1), contains(t.weekdayShort(1)));
          expect(
            tester.getSemantics(
              find.byKey(const ValueKey('reward-day-$code-3')),
            ),
            isSemantics(isButton: true, hasTapAction: true),
          );
          expect(
            find.byKey(const ValueKey('reward-collect-$code-3')),
            findsOneWidget,
          );
          expect(_anyCollect, findsOneWidget);
          for (var k = 4; k <= 7; k++) {
            expect(_heard(tester, code, k), contains(t.rewardTileLocked));
          }
          // The next reward: today's, Day 3's chips.
          expect(
            _text(tester, 'reward-next-$code'),
            contains(
              rewardPrizeLabel(
                t,
                RewardPrize.fromJson(dayJson(3, 'CHIPS', value: 20000)),
              ),
            ),
          );
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('reward-countdown-$code')),
              matching: find.text('Next weekly rewards in 3d 8h'),
            ),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('reward-programs-collect')),
            findsOneWidget,
          );
          handle.dispose();
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          programs: progressedProgramsJson([activeResetWeekJson()]),
        ),
      );
    });

    testWidgets('a weekly streak begun on a Thursday dates only the days '
        'its cycle holds: Day 1 Thu to Day 4 Sun, Days 5–7 on no weekday', (
      tester,
    ) async {
      await setRewardView(tester, screen: const Size(915, 412));
      _fakeRewardClock(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          final handle = tester.ensureSemantics();
          await _openScreen(tester, state);
          expect(tester.takeException(), isNull);
          final t = state.t;
          const code = 'WEEKLY_LOGIN';
          expect(_text(tester, 'reward-cycle-$code'), 'Oct 5 – Oct 11');
          // The words drawn inside day k's tile (a locked tile's semantics
          // merge into the panel's, so its own subtree is what to read).
          Finder inTile(int k, String words) => find.descendant(
            of: find.byKey(ValueKey('reward-day-$code-$k')),
            matching: find.text(words),
          );
          // Thursday 8 October is Day 1 — today's, whose Collect stands in
          // its weekday's place, which a screen reader still hears — so
          // Sunday the 11th is Day 4 …
          expect(_heard(tester, code, 1), contains(t.weekdayShort(4)));
          expect(inTile(1, t.rewardTileCollect), findsOneWidget);
          for (final (k, iso) in [(2, 5), (3, 6), (4, 7)]) {
            expect(inTile(k, t.weekdayShort(iso)), findsOneWidget);
          }
          // … and Days 5–7 would fall in the next cycle, which starts again
          // at Day 1: no weekday at all, only the padlock the server sent.
          for (var k = 5; k <= 7; k++) {
            expect(inTile(k, t.rewardDay(k)), findsOneWidget);
            for (var iso = 1; iso <= 7; iso++) {
              expect(inTile(k, t.weekdayShort(iso)), findsNothing);
            }
            expect(_heard(tester, code, k), contains(t.rewardTileLocked));
          }
          handle.dispose();
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          programs: progressedProgramsJson([
            progressedWeekJson(
              progression: 'RESET',
              states: const [
                'AVAILABLE',
                'LOCKED',
                'LOCKED',
                'LOCKED',
                'LOCKED',
                'LOCKED',
                'LOCKED',
              ],
              currentDay: 1,
              claimedToday: false,
              canClaim: true,
              nextDay: 1,
              today: thursday,
              dayOfPeriod: 4,
            ),
          ]),
        ),
      );
    });

    // A streak begun on a Thursday: Day 1 to collect today, Days 2–4 dated
    // Fri to Sun, Days 5–7 past the cycle and on no weekday — every kind of
    // line a row of days can hold.
    for (final (screen, scale, lang) in const [
      (Size(640, 360), 1.0, AppLang.english),
      (Size(592, 360), 1.25, AppLang.english),
      (Size(592, 360), 1.25, AppLang.hindi),
    ]) {
      testWidgets('along a row every day\'s words, mark and figure stand '
          'level — the Collect, dated days and days past the cycle alike — '
          'for a streak\'s medallions and a sequential login\'s steps, at '
          '${screen.width.toInt()}x${screen.height.toInt()} x$scale in '
          '${lang.name}', (tester) async {
        await setRewardView(tester, screen: screen, textScale: scale);
        _fakeRewardClock(tester);
        Map<String, Object?> begunThursday(String code, String progression) =>
            progressedWeekJson(
              code: code,
              progression: progression,
              states: const [
                'AVAILABLE',
                'LOCKED',
                'LOCKED',
                'LOCKED',
                'LOCKED',
                'LOCKED',
                'LOCKED',
              ],
              currentDay: 1,
              claimedToday: false,
              canClaim: true,
              nextDay: 1,
              today: thursday,
              dayOfPeriod: 4,
            );
        final sent = <http.Request>[];
        await http.runWithClient(
          () async {
            final state = rewardState(lang: lang);
            await _openScreen(tester, state);
            expect(tester.takeException(), isNull);
            final t = state.t;
            for (final code in ['WEEKLY_LOGIN', 'WEEKLY_SEQUENTIAL_LOGIN']) {
              await tester.dragUntilVisible(
                find.byKey(ValueKey('reward-program-$code')),
                find.byKey(const ValueKey('reward-programs-list')),
                const Offset(0, -120),
              );
              await tester.pump();
              Finder tile(int k) => find.byKey(ValueKey('reward-day-$code-$k'));
              Rect labelOf(int k) => tester.getRect(
                find.descendant(
                  of: tile(k),
                  matching: find.text(t.rewardDay(k)),
                ),
              );
              Rect figureOf(int k) => tester.getRect(
                find.byKey(ValueKey('reward-figure-$code-$k')),
              );
              final label = labelOf(2);
              final figure = figureOf(2);
              for (var k = 1; k <= 7; k++) {
                expect(
                  labelOf(k).center.dy,
                  moreOrLessEquals(label.center.dy, epsilon: 0.5),
                  reason: '$code Day $k label',
                );
                expect(
                  labelOf(k).height,
                  moreOrLessEquals(label.height, epsilon: 0.5),
                  reason: '$code Day $k label size',
                );
                expect(
                  figureOf(k).center.dy,
                  moreOrLessEquals(figure.center.dy, epsilon: 0.5),
                  reason: '$code Day $k figure',
                );
              }
              expectRewardWhole(
                tester,
                find.byKey(ValueKey('reward-program-$code')),
                '$code at $screen x$scale ${lang.name}',
              );
            }
            await unmountReward(tester, state);
          },
          () => fakeRewards(
            sent: sent,
            programs: progressedProgramsJson([
              begunThursday('WEEKLY_LOGIN', 'RESET'),
              begunThursday('WEEKLY_SEQUENTIAL_LOGIN', 'SEQUENTIAL'),
            ]),
          ),
        );
      });
    }

    testWidgets('every kind of program has a look of its own: a login '
        'streak\'s medallions, a sequential login\'s steps, a calendar\'s '
        'pages, a breaking calendar\'s chain', (tester) async {
      await setRewardView(tester, screen: const Size(915, 412));
      _fakeRewardClock(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          await _openScreen(tester, state);
          expect(tester.takeException(), isNull);
          final list = find.byKey(const ValueKey('reward-programs-list'));
          Finder panel(String code) =>
              find.byKey(ValueKey('reward-program-$code'));
          Future<void> show(String code) async {
            await tester.dragUntilVisible(
              panel(code),
              list,
              const Offset(0, -120),
            );
            await tester.pump();
          }

          Color edgeOf(String code) {
            final box = tester.widget<Container>(panel(code));
            final border = (box.decoration! as BoxDecoration).border! as Border;
            return border.top.color.withValues(alpha: 1);
          }

          int discsIn(String code) => tester
              .widgetList<DecoratedBox>(
                find.descendant(
                  of: panel(code),
                  matching: find.byType(DecoratedBox),
                ),
              )
              .where(
                (d) =>
                    d.decoration is BoxDecoration &&
                    (d.decoration as BoxDecoration).shape == BoxShape.circle,
              )
              .length;
          Icon joint(String code, int after) => tester.widget<Icon>(
            find.byKey(ValueKey('reward-joint-$code-$after')),
          );
          Finder joints(String code) => find.descendant(
            of: panel(code),
            matching: find.byWidgetPredicate(
              (w) =>
                  w.key is ValueKey<String> &&
                  (w.key as ValueKey<String>).value.startsWith(
                    'reward-joint-$code-',
                  ),
            ),
          );

          // The daily login streak (RESET): gold, a flame, seven medallions
          // on a rail — nothing between the days but the rail.
          const login = 'WEEKLY_LOGIN';
          await show(login);
          final scheme = Theme.of(tester.element(panel(login))).colorScheme;
          expect(
            find.descendant(
              of: panel(login),
              matching: find.byIcon(Icons.local_fire_department_rounded),
            ),
            findsOneWidget,
          );
          expect(edgeOf(login), AppTheme.gold);
          expect(discsIn(login), 7);
          expect(joints(login), findsNothing);

          // A sequential login: emerald, stairs, steps joined by chevrons —
          // the one from a collected day to the day to collect lit.
          const steps = 'WEEKLY_SEQUENTIAL_LOGIN';
          await show(steps);
          expect(
            find.descendant(
              of: panel(steps),
              matching: find.byIcon(Icons.stairs_rounded),
            ),
            findsOneWidget,
          );
          expect(edgeOf(steps), scheme.primary.withValues(alpha: 1));
          expect(discsIn(steps), 0);
          expect(joints(steps), findsNWidgets(6));
          expect(joint(steps, 3).icon, Icons.chevron_right_rounded);
          expect(joint(steps, 3).color, scheme.primary);
          expect(joint(steps, 4).color, isNot(scheme.primary));

          // A breaking calendar: violet, a chain, pages joined by links —
          // broken, in the error ink, on both sides of the day whose miss
          // broke it; its panel edged in the error while it is broken.
          const chain = 'WEEKLY_BREAK_CALENDAR';
          await show(chain);
          final violet = AppTheme.violetPalette(scheme).accent;
          expect(edgeOf(chain), scheme.error.withValues(alpha: 1));
          expect(discsIn(chain), 0);
          expect(joints(chain), findsNWidgets(6));
          expect(joint(chain, 1).icon, Icons.link_rounded);
          expect(joint(chain, 1).color, violet);
          expect(joint(chain, 2).icon, Icons.link_off_rounded);
          expect(joint(chain, 2).color, scheme.error);
          expect(joint(chain, 3).icon, Icons.link_off_rounded);
          expect(joint(chain, 3).color, scheme.error);
          expect(joint(chain, 4).icon, Icons.link_rounded);
          expect(joint(chain, 4).color, isNot(scheme.error));

          // The usual break — a player who first opens a breaking calendar
          // mid-week has missed its Monday — shows too: the link out of
          // Day 1 is broken, and the rest of the chain is quiet.
          const monday = 'WEEKLY_BREAK_MONDAY';
          await show(monday);
          expect(edgeOf(monday), scheme.error.withValues(alpha: 1));
          expect(joint(monday, 1).icon, Icons.link_off_rounded);
          expect(joint(monday, 1).color, scheme.error);
          for (var after = 2; after <= 6; after++) {
            expect(joint(monday, after).icon, Icons.link_rounded);
            expect(joint(monday, after).color, isNot(scheme.error));
          }

          // A calendar: sapphire, a calendar, pages standing apart.
          const month = 'MONTHLY_CALENDAR';
          await show(month);
          expect(
            find.descendant(
              of: panel(month),
              matching: find.byIcon(Icons.calendar_month_rounded),
            ),
            findsOneWidget,
          );
          expect(edgeOf(month), scheme.tertiary.withValues(alpha: 1));
          expect(discsIn(month), 0);
          expect(joints(month), findsNothing);

          // A login streak that breaks: violet medallions, the chain's mark,
          // and its rail in the error ink on both sides of the missed Day 3 —
          // a half of the rail in each of Days 2 and 4, both halves in Day 3.
          const breaking = 'WEEKLY_LOGIN_BREAK';
          await show(breaking);
          expect(
            find.descendant(
              of: panel(breaking),
              matching: find.byIcon(Icons.link_rounded),
            ),
            findsOneWidget,
          );
          expect(discsIn(breaking), 7);
          expect(joints(breaking), findsNothing);
          expect(
            tester
                .widgetList<Container>(
                  find.descendant(
                    of: panel(breaking),
                    matching: find.byType(Container),
                  ),
                )
                .where((c) => c.color == scheme.error),
            hasLength(4),
          );
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          programs: progressedProgramsJson([
            activeResetWeekJson(),
            activeSequentialWeekJson(),
            brokenCalendarWeekJson(),
            progressedWeekJson(
              code: 'WEEKLY_BREAK_MONDAY',
              mode: 'CALENDAR',
              progression: 'BREAK',
              status: 'BROKEN',
              states: const [
                'MISSED',
                'LOCKED',
                'LOCKED',
                'LOCKED',
                'LOCKED',
                'LOCKED',
                'LOCKED',
              ],
              currentDay: 1,
              claimedToday: false,
              canClaim: false,
              nextDay: 0,
              today: thursday,
              dayOfPeriod: 4,
            ),
            progressedMonthJson(),
            progressedWeekJson(
              code: 'WEEKLY_LOGIN_BREAK',
              progression: 'BREAK',
              status: 'BROKEN',
              states: const [
                'CLAIMED',
                'CLAIMED',
                'MISSED',
                'LOCKED',
                'LOCKED',
                'LOCKED',
                'LOCKED',
              ],
              currentDay: 3,
              claimedToday: false,
              canClaim: false,
              nextDay: 0,
              today: thursday,
              dayOfPeriod: 4,
            ),
          ]),
        ),
      );
    });

    // The brief's week (the seed's WEEKLY_SEQUENTIAL_CAL): an emoji on Day 5
    // and a badge on Day 7, whose names are far wider than a page.
    for (final (screen, scale) in const [
      (Size(640, 360), 1.0),
      (Size(592, 360), 1.25),
    ]) {
      testWidgets('a page\'s date stands as large beside a long prize name '
          '("Clapping Hands", "Royal Ace") as beside a figure, at '
          '${screen.width.toInt()}x${screen.height.toInt()} x$scale', (
        tester,
      ) async {
        await setRewardView(tester, screen: screen, textScale: scale);
        _fakeRewardClock(tester);
        const code = 'WEEKLY_SEQUENTIAL_CAL';
        const states = [
          'CLAIMED',
          'CLAIMED',
          'CLAIMED',
          'LOCKED',
          'LOCKED',
          'LOCKED',
          'LOCKED',
        ];
        final week = progressedWeekJson(
          code: code,
          mode: 'CALENDAR',
          progression: 'BREAK',
          states: states,
          currentDay: 3,
          claimedToday: true,
          canClaim: false,
          nextDay: 4,
        );
        week['rewards'] = [
          for (final (i, d) in [
            dayJson(1, 'CHIPS', value: 10000),
            dayJson(2, 'HAMMER', value: 1),
            dayJson(3, 'CHIPS', value: 20000),
            dayJson(4, 'DIAMOND', value: 1),
            dayJson(5, 'EMOJI', ref: '5', emoji: clappingHands),
            dayJson(6, 'CHIPS', value: 50000),
            dayJson(7, 'BADGE', ref: 'ROYAL_ACE', badge: royalAce),
          ].indexed)
            {...d, 'claimed': states[i] == 'CLAIMED', 'state': states[i]},
        ];
        final sent = <http.Request>[];
        await http.runWithClient(
          () async {
            final state = rewardState();
            await _openScreen(tester, state);
            expect(tester.takeException(), isNull);
            await tester.dragUntilVisible(
              find.byKey(const ValueKey('reward-program-$code')),
              find.byKey(const ValueKey('reward-programs-list')),
              const Offset(0, -120),
            );
            await tester.pump();
            // A page's date: the one line of it set at the date's size.
            Rect dateOf(int day) {
              final date = find.descendant(
                of: find.byKey(ValueKey('reward-day-$code-$day')),
                matching: find.byWidgetPredicate(
                  (w) => w is Text && w.data != '0' && w.style?.fontSize == 22,
                ),
              );
              expect(date, findsOneWidget, reason: 'Day $day');
              return tester.getRect(date);
            }

            final plain = dateOf(4).height;
            expect(plain, greaterThan(18 * scale));
            for (final day in [1, 2, 3, 5, 6, 7]) {
              expect(
                dateOf(day).height,
                moreOrLessEquals(plain, epsilon: 0.5),
                reason: 'Day $day',
              );
            }
            // The long names are set down to their page, and kept whole.
            for (final day in [5, 7]) {
              final tile = tester.getRect(
                find.byKey(ValueKey('reward-day-$code-$day')),
              );
              final name = tester.getRect(
                find.byKey(ValueKey('reward-figure-$code-$day')),
              );
              expect(name.left, greaterThanOrEqualTo(tile.left - 0.5));
              expect(name.right, lessThanOrEqualTo(tile.right + 0.5));
            }
            expectRewardWhole(
              tester,
              find.byKey(const ValueKey('reward-program-$code')),
              '$code at $screen x$scale',
            );
            await unmountReward(tester, state);
          },
          () =>
              fakeRewards(sent: sent, programs: progressedProgramsJson([week])),
        );
      });
    }

    testWidgets('an ACTIVE SEQUENTIAL week: "3 day streak", a missed day '
        'skipped, Day 4 to collect', (tester) async {
      await setRewardView(tester, screen: const Size(915, 412));
      _fakeRewardClock(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          final handle = tester.ensureSemantics();
          await _openScreen(tester, state);
          final t = state.t;
          const code = 'WEEKLY_SEQUENTIAL_LOGIN';
          expect(_text(tester, 'reward-headline-$code'), t.streakDays(3));
          expect(_text(tester, 'reward-hint-$code'), t.rewardStreakHintNoReset);
          for (final k in [1, 2, 3]) {
            expect(_heard(tester, code, k), contains(t.rewardTileClaimed));
          }
          expect(_heard(tester, code, 4), contains(t.rewardTileCollect));
          expect(
            find.byKey(const ValueKey('reward-collect-$code-4')),
            findsOneWidget,
          );
          expect(_anyCollect, findsOneWidget);
          for (var k = 5; k <= 7; k++) {
            expect(_heard(tester, code, k), contains(t.rewardTileLocked));
          }
          handle.dispose();
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          programs: progressedProgramsJson([activeSequentialWeekJson()]),
        ),
      );
    });

    testWidgets('the brief\'s BROKEN CALENDAR+BREAK week: "Reward streak '
        'broken" in the error ink, "You missed Day 3.", "New rewards start '
        'Monday.", Days 1–2 collected, Day 3 missed, 4–7 locked, and no '
        'Collect anywhere', (tester) async {
      await setRewardView(tester, screen: const Size(915, 412));
      _fakeRewardClock(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          final handle = tester.ensureSemantics();
          await _openScreen(tester, state);
          expect(tester.takeException(), isNull);
          final t = state.t;
          const code = 'WEEKLY_BREAK_CALENDAR';
          final headline = find.byKey(const ValueKey('reward-headline-$code'));
          expect(tester.widget<Text>(headline).data, t.rewardBrokenTitle);
          final error = Theme.of(tester.element(headline)).colorScheme.error;
          expect(tester.widget<Text>(headline).style?.color, error);
          expect(_text(tester, 'reward-cycle-$code'), 'Oct 5 – Oct 11');
          expect(_text(tester, 'reward-broken-$code-0'), 'You missed Day 3.');
          expect(
            _text(tester, 'reward-broken-$code-1'),
            'New rewards start Monday.',
          );
          expect(find.textContaining('New rewards start Mon'), findsOneWidget);
          // The broken lines stand where the progression's hint stood.
          expect(find.byKey(const ValueKey('reward-hint-$code')), findsNothing);
          for (final k in [1, 2]) {
            expect(_heard(tester, code, k), contains(t.rewardTileClaimed));
          }
          expect(_heard(tester, code, 3), contains(t.rewardTileMissed));
          final missed = tester.widget<Icon>(
            find.byKey(const ValueKey('reward-missed-$code-3')),
          );
          expect(missed.color, error);
          for (var k = 4; k <= 7; k++) {
            expect(_heard(tester, code, k), contains(t.rewardTileLocked));
          }
          // A calendar's tiles keep their dates: Monday the 5th.
          expect(_heard(tester, code, 1), contains(t.weekdayShort(1)));
          // Nothing to collect, anywhere; no next reward; the countdown.
          expect(_anyCollect, findsNothing);
          expect(
            find.byKey(const ValueKey('reward-programs-collect')),
            findsNothing,
          );
          expect(find.byKey(const ValueKey('reward-next-$code')), findsNothing);
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('reward-countdown-$code')),
              matching: find.text('Next weekly rewards in 3d 8h'),
            ),
            findsOneWidget,
          );
          expect(
            tester.getSemantics(
              find.byKey(const ValueKey('reward-day-$code-4')),
            ),
            isNot(isSemantics(hasTapAction: true)),
          );
          // A tap on a day sends nothing.
          for (final k in [3, 4]) {
            await tester.tap(find.byKey(ValueKey('reward-day-$code-$k')));
            await tester.pump();
          }
          expect(_posts(sent), isEmpty);
          handle.dispose();
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          programs: progressedProgramsJson([brokenCalendarWeekJson()]),
        ),
      );
    });

    testWidgets('a COMPLETED week: "All rewards collected", every day '
        'collected, nothing to collect, the next week counting down', (
      tester,
    ) async {
      await setRewardView(tester, screen: const Size(915, 412));
      _fakeRewardClock(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          final handle = tester.ensureSemantics();
          await _openScreen(tester, state);
          final t = state.t;
          const code = 'WEEKLY_LOGIN';
          expect(_text(tester, 'reward-headline-$code'), t.rewardAllCollected);
          for (var k = 1; k <= 7; k++) {
            expect(_heard(tester, code, k), contains(t.rewardTileClaimed));
          }
          expect(_anyCollect, findsNothing);
          expect(
            find.byKey(const ValueKey('reward-programs-collect')),
            findsNothing,
          );
          expect(find.byKey(const ValueKey('reward-next-$code')), findsNothing);
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('reward-countdown-$code')),
              matching: find.text('Next weekly rewards in 6h 30m'),
            ),
            findsOneWidget,
          );
          handle.dispose();
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          programs: progressedProgramsJson([completedWeekJson()]),
        ),
      );
    });

    testWidgets('a SEQUENTIAL month: "Oct 1 – Oct 31", the 10th to collect, '
        'the missed dates crossed quietly, November counting down', (
      tester,
    ) async {
      await setRewardView(tester, screen: const Size(915, 412));
      _fakeRewardClock(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          final handle = tester.ensureSemantics();
          await _openScreen(tester, state);
          final t = state.t;
          const code = 'MONTHLY_CALENDAR';
          expect(_text(tester, 'reward-cycle-$code'), 'Oct 1 – Oct 31');
          expect(
            _text(tester, 'reward-headline-$code'),
            t.calendarDayReward(10),
          );
          expect(_text(tester, 'reward-hint-$code'), t.rewardCalendarMonthHint);
          expect(
            find.byKey(const ValueKey('reward-collect-$code-10')),
            findsOneWidget,
          );
          expect(_anyCollect, findsOneWidget);
          for (final k in [4, 6, 8]) {
            expect(_heard(tester, code, k), contains(t.rewardTileMissed));
            final mark = tester.widget<Icon>(
              find.byKey(ValueKey('reward-missed-$code-$k')),
            );
            // Not a broken cycle: the quiet ink, not the error's.
            expect(
              mark.color,
              isNot(
                Theme.of(
                  tester.element(
                    find.byKey(ValueKey('reward-missed-$code-$k')),
                  ),
                ).colorScheme.error,
              ),
            );
          }
          final list = find.byKey(const ValueKey('reward-programs-list'));
          final countdown = find.byKey(
            const ValueKey('reward-countdown-$code'),
          );
          await tester.dragUntilVisible(countdown, list, const Offset(0, -120));
          await tester.pump();
          expect(
            find.descendant(
              of: countdown,
              matching: find.text('Next monthly rewards in 21d 4h'),
            ),
            findsOneWidget,
          );
          handle.dispose();
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          programs: progressedProgramsJson([progressedMonthJson()]),
        ),
      );
    });

    testWidgets('the countdown ticks on its own timer: an hour later it reads '
        'an hour less, and nothing above it rebuilt', (tester) async {
      await setRewardView(tester, screen: const Size(915, 412));
      _fakeRewardClock(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          await _openScreen(tester, state);
          final countdown = find.byKey(
            const ValueKey('reward-countdown-WEEKLY_LOGIN'),
          );
          expect(
            find.descendant(
              of: countdown,
              matching: find.text('Next weekly rewards in 3d 8h'),
            ),
            findsOneWidget,
          );
          final rebuilt = await _rebuiltDuring(() async {
            // GameState's one-second tick, and an hour of the clock.
            // ignore: invalid_use_of_protected_member
            state.notifyListeners();
            await tester.pump();
            await tester.pump(const Duration(hours: 1));
          });
          expect(
            find.descendant(
              of: countdown,
              matching: find.text('Next weekly rewards in 3d 7h'),
            ),
            findsOneWidget,
          );
          expect(rebuilt, contains(NextCycleCountdown));
          expect(rebuilt, isNot(contains(RewardProgramsScreen)));
          // Nothing was asked of the server meanwhile.
          expect(_gets(sent).length, 1);
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          programs: progressedProgramsJson([activeResetWeekJson()]),
        ),
      );
    });

    testWidgets('at zero the countdown reads the programs again, once, and '
        'counts to the next week', (tester) async {
      await setRewardView(tester, screen: const Size(915, 412));
      _fakeRewardClock(tester);
      final sent = <http.Request>[];
      var reads = 0;
      await http.runWithClient(
        () async {
          final state = rewardState();
          await _openScreen(tester, state);
          expect(_gets(sent).length, 1);
          final countdown = find.byKey(
            const ValueKey('reward-countdown-WEEKLY_LOGIN'),
          );
          // Five seconds from the answer, a second and more of it gone.
          expect(
            find.descendant(
              of: countdown,
              matching: find.text('Next weekly rewards in 4s'),
            ),
            findsOneWidget,
          );
          for (var i = 0; i < 8; i++) {
            await tester.pump(const Duration(seconds: 1));
          }
          // Read again once, and the new answer counts to the week after.
          expect(_gets(sent).length, 2);
          expect(
            find.descendant(
              of: countdown,
              matching: find.text('Next weekly rewards in 7d 0h'),
            ),
            findsOneWidget,
          );
          for (var i = 0; i < 20; i++) {
            await tester.pump(const Duration(seconds: 1));
          }
          expect(_gets(sent).length, 2);
          expect(_posts(sent), isEmpty);
          await unmountReward(tester, state);
        },
        () => MockClient((request) async {
          sent.add(request);
          if (request.url.path == '/api/reward-programs') {
            reads++;
            return rewardJson(
              progressedProgramsJson([
                activeResetWeekJson(
                  startsInMs: reads == 1
                      ? 5000
                      : ((7 * 24) * 60 + 30) * 60 * 1000,
                ),
              ]),
            );
          }
          return rewardJson({'error': 'not_found'}, 404);
        }),
      );
    });

    testWidgets('a tap on the day to collect claims its program, once: the '
        'loader on the tile meanwhile, nothing else pressable, then the '
        'screen closes over the celebration', (tester) async {
      await setRewardView(tester, screen: const Size(915, 412));
      _fakeRewardClock(tester);
      final sent = <http.Request>[];
      final claimRelease = Completer<void>();
      await http.runWithClient(
        () async {
          final state = rewardState();
          await _openScreen(tester, state);
          const code = 'WEEKLY_LOGIN';
          final day3 = find.byKey(const ValueKey('reward-day-$code-3'));
          // A tap on a locked day sends nothing.
          await tester.tap(find.byKey(const ValueKey('reward-day-$code-5')));
          await tester.pump();
          expect(_posts(sent), isEmpty);
          await tester.tap(day3);
          await tester.pump();
          expect(_posts(sent), ['/api/reward-programs/claim']);
          final post = sent.lastWhere((r) => r.method == 'POST');
          expect(jsonDecode(post.body), {'programCode': code});
          expect(state.rewardClaimPending, isTrue);
          expect(state.rewardClaimProgram, code);
          // While it is out: the loader where Collect was, and nothing more
          // is sent — not by the tile, not by the header's key.
          expect(
            find.byKey(const ValueKey('reward-collecting-$code-3')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('reward-collect-$code-3')),
            findsNothing,
          );
          await tester.tap(day3);
          await tester.tap(
            find.byKey(const ValueKey('reward-programs-collect')),
          );
          await tester.pump();
          expect(_posts(sent).length, 1);
          claimRelease.complete();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pump(const Duration(milliseconds: 600));
          expect(find.byType(RewardProgramsScreen), findsNothing);
          expect(state.rewardsGranted?.single.day, 3);
          expect(state.rewardClaimPending, isFalse);
          expect(state.rewardClaimProgram, isNull);
          expect(state.user?.chips, 1020000);
          expect(_posts(sent).length, 1);
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          programs: progressedProgramsJson([activeResetWeekJson()]),
          claim: _day3ClaimJson(),
          claimRelease: claimRelease,
        ),
      );
    });

    testWidgets('a day the server will no longer grant: the refusal said, '
        'the screen kept, the truth read again and drawn', (tester) async {
      await setRewardView(tester, screen: const Size(915, 412));
      _fakeRewardClock(tester);
      final sent = <http.Request>[];
      var reads = 0;
      await http.runWithClient(
        () async {
          final state = rewardState();
          await _openScreen(tester, state);
          final t = state.t;
          const code = 'WEEKLY_LOGIN';
          await tester.tap(find.byKey(const ValueKey('reward-day-$code-3')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          expect(state.notice, t.rewardCycleBrokenNotice);
          expect(find.byType(RewardProgramsScreen), findsOneWidget);
          expect(_gets(sent).length, 2);
          expect(_text(tester, 'reward-headline-$code'), t.rewardBrokenTitle);
          expect(_anyCollect, findsNothing);
          expect(state.rewardsGranted, isNull);
          await unmountReward(tester, state);
        },
        () => MockClient((request) async {
          sent.add(request);
          if (request.url.path == '/api/reward-programs/claim') {
            return rewardJson({
              'error': 'reward_cycle_broken',
              'message': 'Broken.',
            }, 409);
          }
          if (request.url.path == '/api/reward-programs') {
            reads++;
            return rewardJson(
              progressedProgramsJson([
                if (reads == 1)
                  activeResetWeekJson()
                else
                  brokenLoginWeekJson(),
              ]),
            );
          }
          return rewardJson({'error': 'not_found'}, 404);
        }),
      );
    });

    for (final lang in AppLang.values) {
      for (final screen in const [Size(640, 360), Size(592, 360)]) {
        testWidgets('every panel fits ${screen.width.toInt()}x'
            '${screen.height.toInt()} at text x1.25 in ${lang.name}, both '
            'themes: no overflow, no word cut', (tester) async {
          await setRewardView(tester, screen: screen, textScale: 1.25);
          _fakeRewardClock(tester);
          for (final brightness in Brightness.values) {
            final sent = <http.Request>[];
            await http.runWithClient(
              () async {
                final state = rewardState(lang: lang);
                await _openScreen(tester, state, brightness: brightness);
                expect(tester.takeException(), isNull);
                final reason =
                    '${lang.name} ${brightness.name} ${screen.width.toInt()}';
                final view = Offset.zero & screen;
                final list = find.byKey(const ValueKey('reward-programs-list'));
                for (final (code, days) in const [
                  ('WEEKLY_LOGIN', 7),
                  ('WEEKLY_BREAK_CALENDAR', 7),
                  ('WEEKLY_LOGIN_DONE', 7),
                  ('WEEKLY_SEQUENTIAL_LOGIN', 7),
                  ('MONTHLY_CALENDAR', 31),
                ]) {
                  final panel = find.byKey(ValueKey('reward-program-$code'));
                  // The panel's foot into view, then the panel whole where
                  // it fits.
                  final foot = find.byKey(ValueKey('reward-countdown-$code'));
                  await tester.dragUntilVisible(
                    foot,
                    list,
                    const Offset(0, -120),
                  );
                  await tester.pump();
                  expect(tester.takeException(), isNull, reason: reason);
                  expectRewardWhole(tester, panel, '$reason $code');
                  final r = tester.getRect(panel);
                  expect(r.left, greaterThanOrEqualTo(view.left));
                  expect(r.right, lessThanOrEqualTo(view.right));
                  final headline = find.byKey(
                    ValueKey('reward-headline-$code'),
                  );
                  expect(
                    tester
                        .renderObject<RenderParagraph>(
                          find.descendant(
                            of: headline,
                            matching: find.byType(RichText),
                          ),
                        )
                        .didExceedMaxLines,
                    isFalse,
                    reason: '$reason $code headline',
                  );
                  final tiles = find.descendant(
                    of: panel,
                    matching: find.byWidgetPredicate(
                      (w) =>
                          w.key is ValueKey<String> &&
                          (w.key as ValueKey<String>).value.startsWith(
                            'reward-day-$code-',
                          ),
                    ),
                  );
                  expect(tiles, findsNWidgets(days), reason: '$reason $code');
                  // The countdown, whole and inside the page.
                  expect(
                    find.descendant(of: foot, matching: find.byType(Text)),
                    findsOneWidget,
                    reason: '$reason $code countdown',
                  );
                  final f = tester.getRect(foot);
                  expect(f.right, lessThanOrEqualTo(view.right));
                }
                // The broken week's lines, in this language.
                final t = state.t;
                await tester.dragUntilVisible(
                  find.byKey(
                    const ValueKey('reward-broken-WEEKLY_BREAK_CALENDAR-1'),
                  ),
                  list,
                  const Offset(0, 120),
                );
                await tester.pump();
                expect(
                  find.text(t.rewardNewCycleStarts(t.weekdayFull(1))),
                  findsOneWidget,
                  reason: reason,
                );
                expect(
                  find.text(t.rewardMissedDay(3)),
                  findsOneWidget,
                  reason: reason,
                );
                await unmountReward(tester, state);
              },
              () => fakeRewards(
                sent: sent,
                programs: progressedProgramsJson([
                  activeResetWeekJson(),
                  brokenCalendarWeekJson(),
                  completedWeekJson(code: 'WEEKLY_LOGIN_DONE'),
                  activeSequentialWeekJson(),
                  progressedMonthJson(),
                ]),
              ),
            );
          }
        });
      }
    }
  });
}
