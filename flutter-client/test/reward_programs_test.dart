// The reward programs (owner, 30 Sep 2026): the login streaks and the
// calendar rewards the SERVER runs — it decides every day, every reward and
// every claim; the app reads them as the lobby appears, shows what it is
// told, collects on the player's tap and celebrates only what a claim's
// answer says it gave.
//
// These hold the wire (a program's days, today, the run and the next reward
// read as sent; a claim's grants; the dates the tiles are labelled with),
// the words (a reward named in every language), GameState (one GET as the
// lobby appears and nothing claimed by itself; a tap's POST; nothing at a
// table, an older server, a refusal, a lost network, Try again's GET,
// sign-out), the lobby chip (Collect now while a day waits, then the streak;
// beside the Lucky Draw and clear of the foot's keys; no chip without a
// program), the screen ("3 day streak" over seven tiles, "Day 10 reward"
// over thirty-one, the next reward, the Collect key, the tiles' words for a
// screen reader, no line cut at 640x360 x1.25 in all five languages) and the
// celebration (one line per grant, closed by its key; never from anything but
// a claim's answer). The weekly login popup is `weekly_login_test.dart`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/api_client.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/screens/reward_programs_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';

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

/// The Lucky Draw's chip in its corner beside the rewards', at its widest.
LuckyDrawState _luckyDraw() => LuckyDrawState.fromJson({
  'draw': {
    'code': 'BEGINNER_LUCKY_DRAW',
    'name': 'Beginner Lucky Draw',
    'spinnerType': 'BEGINNER',
    'cooldownMs': 259200000,
  },
  'slots': [
    for (var n = 1; n <= 6; n++)
      {'slotNumber': n, 'rewardType': 'CHIPS', 'rewardValue': 100000 * n},
  ],
  'nextSpinAt': DateTime.now()
      .add(const Duration(hours: 50))
      .millisecondsSinceEpoch,
});

RoomState _table() => RoomState.fromJson({
  'roomId': 'r1',
  'code': 'ABCDEFGH',
  'category': 'seen',
  'state': 'WAITING',
  'maxPlayers': 5,
  'seats': const [],
});

/// A bare page with a key that opens the rewards, as the lobby's chip does.
Future<void> _openScreen(WidgetTester tester, GameState state) async {
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
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadRewardFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the wire', () {
    test('a program reads its days in order, today, the run and what is '
        'next', () {
      final s = RewardProgramState.fromJson({
        ...streakJson(),
        'rewards': weeklyLoginRewards(claimed: 3).reversed.toList(),
      });
      expect(s.program.code, 'WEEKLY_LOGIN');
      expect(s.program.isStreak, isTrue);
      expect(s.program.isWeekly, isTrue);
      expect(s.program.resetOnMissedDay, isTrue);
      expect(s.today, wednesday);
      expect(s.dayOfPeriod, 3);
      expect(s.periodDays, 7);
      expect(s.currentDay, 3);
      expect(s.claimedToday, isTrue);
      expect(s.claimedDays, 3);
      expect(s.rewards.map((d) => d.day), [1, 2, 3, 4, 5, 6, 7]);
      expect(s.rewards.map((d) => d.claimed), [
        true,
        true,
        true,
        false,
        false,
        false,
        false,
      ]);
      expect(s.rewardFor(3)?.prize.kind, RewardKind.chips);
      expect(s.rewardFor(3)?.prize.amount, 20000);
      expect(s.rewardFor(8), isNull);
      // Collected today: the next reward is tomorrow's, Day 4's diamond.
      expect(s.nextDay, 4);
      expect(s.nextReward?.prize.kind, RewardKind.diamond);
    });

    test('the next reward is today while it waits, tomorrow once collected, '
        'and none past the period', () {
      final waiting = RewardProgramState.fromJson(
        streakJson(claimedToday: false),
      );
      expect(waiting.nextDay, 3);
      expect(waiting.claimedDays, 2);
      final last = RewardProgramState.fromJson(
        streakJson(day: 7, claimedToday: true),
      );
      expect(last.nextDay, isNull);
      expect(last.nextReward, isNull);
      final calendar = RewardProgramState.fromJson(calendarJson());
      expect(calendar.program.isStreak, isFalse);
      expect(calendar.nextDay, 10);
      expect(calendar.nextReward?.prize.kind, RewardKind.emoji);
      expect(calendar.nextReward?.prize.itemName, 'Clapping Hands');
      final collected = RewardProgramState.fromJson(
        calendarJson(claimedToday: true),
      );
      expect(collected.nextDay, 11);
      expect(collected.claimedDays, 7);
    });

    test("a day's date comes from today: a streak counts back along its "
        'run, a calendar along the period', () {
      final streak = RewardProgramState.fromJson(streakJson());
      // Day 3 is Wednesday 7 October; Day 1 was the Monday, Day 7 will be
      // the Sunday.
      expect(streak.todayDate, DateTime.utc(2026, 10, 7));
      expect(streak.dateOfDay(3), DateTime.utc(2026, 10, 7));
      expect(streak.dateOfDay(1), DateTime.utc(2026, 10, 5));
      expect(streak.weekdayOfDay(1), DateTime.monday);
      expect(streak.weekdayOfDay(7), DateTime.sunday);
      final calendar = RewardProgramState.fromJson(calendarJson());
      expect(calendar.dateOfDay(1), DateTime.utc(2026, 10, 1));
      expect(calendar.dateOfDay(31), DateTime.utc(2026, 10, 31));
      expect(calendar.weekdayOfDay(1), DateTime.thursday);
      // A streak on Day 5 whose today is the 7th began on the 3rd.
      final older = RewardProgramState.fromJson(streakJson(day: 5));
      expect(older.dateOfDay(1), DateTime.utc(2026, 10, 3));
      // No date at all: today, at least.
      final bare = RewardProgramState.fromJson({
        ...streakJson(),
        'today': 'someday',
      });
      final now = DateTime.now().toUtc();
      expect(bare.todayDate, DateTime.utc(now.year, now.month, now.day));
    });

    test('a reward is its kind: a wallet amount, an item with its catalogue '
        'row, a badge with its days, or nothing', () {
      final chips = RewardPrize.fromJson(dayJson(1, 'CHIPS', value: 10000));
      expect(chips.kind, RewardKind.chips);
      expect(chips.isWallet, isTrue);
      expect(chips.isItem, isFalse);
      expect(chips.amount, 10000);
      expect(chips.itemName, '');

      final emoji = RewardPrize.fromJson(
        dayJson(10, 'EMOJI', ref: '5', emoji: clappingHands),
      );
      expect(emoji.isItem, isTrue);
      expect(emoji.refId, '5');
      expect(emoji.emoji?.name, 'Clapping Hands');
      expect(emoji.itemName, 'Clapping Hands');
      expect(emoji.amount, 0);

      final picture = RewardPrize.fromJson(
        dayJson(25, 'PROFILE_PICTURE', ref: '26', picture: lovestruckCat),
      );
      expect(picture.picture?.name, 'Lovestruck Cat');
      expect(picture.itemName, 'Lovestruck Cat');

      final table = RewardPrize.fromJson(
        dayJson(25, 'TABLE_PICTURE', ref: '1', tablePicture: linesBackground),
      );
      expect(table.tablePicture?.name, 'Lines Background');
      expect(table.itemName, 'Lines Background');

      final badge = RewardPrize.fromJson(
        dayJson(31, 'BADGE', ref: 'ROYAL_ACE', badge: royalAce),
      );
      expect(badge.badge?.code, 'ROYAL_ACE');
      expect(badge.badge?.validityDays, 7);
      expect(badge.badge?.held, isFalse);
      expect(badge.itemName, 'Royal Ace');

      final none = RewardPrize.fromJson(dayJson(4, 'NO_REWARD'));
      expect(none.isNothing, isTrue);
      expect(none.isWallet, isFalse);
      expect(none.isItem, isFalse);

      // A kind this build has never heard of is neither a wallet nor an
      // item, and is still read.
      final other = RewardPrize.fromJson(dayJson(4, 'CARD_BACK', ref: '9'));
      expect(other.kind, 'CARD_BACK');
      expect(other.isWallet, isFalse);
      expect(other.isItem, isFalse);
    });

    test('a claim reads what it gave, every program after and the account', () {
      final r = RewardClaimResult.fromJson(
        claimJson(granted: twoGrants(), chips: 1020000),
      );
      expect(r.granted.length, 2);
      final first = r.granted.first;
      expect(first.programCode, 'WEEKLY_LOGIN');
      expect(first.mode, RewardMode.loginStreak);
      expect(first.periodType, RewardPeriod.weekly);
      expect(first.day, 3);
      expect(first.prize.kind, RewardKind.chips);
      expect(first.prize.amount, 20000);
      expect(first.alreadyOwned, isFalse);
      expect(first.claimedAt, 1791801600000);
      final second = r.granted[1];
      expect(second.programCode, 'MONTHLY_CALENDAR');
      expect(second.prize.isItem, isTrue);
      expect(second.prize.itemName, 'Clapping Hands');
      expect(r.programs.map((p) => p.program.code), [
        'WEEKLY_LOGIN',
        'MONTHLY_CALENDAR',
      ]);
      expect(r.user?.chips, 1020000);
      // Nothing given, no account: an empty answer still reads.
      final empty = RewardClaimResult.fromJson(const {});
      expect(empty.granted, isEmpty);
      expect(empty.programs, isEmpty);
      expect(empty.user, isNull);
    });

    test('only real programs and real days are kept', () {
      expect(rewardProgramsFromJson('garbage'), isEmpty);
      expect(rewardProgramsFromJson(null), isEmpty);
      final programs = rewardProgramsFromJson([
        'not a program',
        7,
        {
          ...streakJson(),
          'rewards': [
            ...weeklyLoginRewards(),
            dayJson(0, 'CHIPS', value: 1),
            dayJson(-3, 'CHIPS', value: 1),
            'not a day',
          ],
        },
      ]);
      expect(programs.length, 1);
      expect(programs.single.rewards.map((d) => d.day), [1, 2, 3, 4, 5, 6, 7]);
      // A program with no program block reads as nothing, not a crash.
      final bare = RewardProgramState.fromJson(const {'today': wednesday});
      expect(bare.program.code, '');
      expect(bare.rewards, isEmpty);
      expect(bare.nextDay, isNull);
    });
  });

  group('the words', () {
    test('a reward is named in every language: the figure for chips, the '
        'count for a wallet, the item by its name', () {
      for (final lang in AppLang.values) {
        final t = Strings(lang);
        final chips = rewardPrizeLabel(
          t,
          RewardPrize.fromJson(dayJson(1, 'CHIPS', value: 10000)),
        );
        expect(chips, contains('10,000'), reason: lang.name);
        final hammers = rewardPrizeLabel(
          t,
          RewardPrize.fromJson(dayJson(6, 'HAMMER', value: 2)),
        );
        expect(hammers, contains('2'), reason: lang.name);
        expect(hammers, isNot(equals(chips)), reason: lang.name);
        final oneHammer = rewardPrizeLabel(
          t,
          RewardPrize.fromJson(dayJson(2, 'HAMMER', value: 1)),
        );
        expect(oneHammer, isNot(equals(hammers)), reason: lang.name);
        final diamond = rewardPrizeLabel(
          t,
          RewardPrize.fromJson(dayJson(4, 'DIAMOND', value: 1)),
        );
        expect(diamond, isNotEmpty, reason: lang.name);
        expect(diamond, isNot(equals(oneHammer)), reason: lang.name);
        final emoji = rewardPrizeLabel(
          t,
          RewardPrize.fromJson(
            dayJson(10, 'EMOJI', ref: '5', emoji: clappingHands),
          ),
        );
        expect(emoji, contains('Clapping Hands'), reason: lang.name);
        expect(emoji, isNot(equals('Clapping Hands')), reason: lang.name);
        final badge = rewardPrizeLabel(
          t,
          RewardPrize.fromJson(
            dayJson(31, 'BADGE', ref: 'ROYAL_ACE', badge: royalAce),
          ),
        );
        expect(badge, contains('Royal Ace'), reason: lang.name);
        expect(badge, contains('7'), reason: lang.name);
        final forever = rewardPrizeLabel(
          t,
          RewardPrize.fromJson(
            dayJson(
              31,
              'BADGE',
              ref: 'ROYAL_ACE',
              badge: {...royalAce, 'validityDays': 0},
            ),
          ),
        );
        expect(forever, contains('Royal Ace'), reason: lang.name);
        expect(forever, isNot(contains('7')), reason: lang.name);
        expect(
          rewardPrizeLabel(t, RewardPrize.fromJson(dayJson(4, 'NO_REWARD'))),
          t.rewardNothing,
          reason: lang.name,
        );
        // The four seeded programs in the player's language; any other by
        // the name the server gave it.
        final names = {
          for (final code in const [
            'WEEKLY_LOGIN',
            'MONTHLY_LOGIN',
            'WEEKLY_CALENDAR',
            'MONTHLY_CALENDAR',
          ])
            t.rewardProgramName(code, 'x'),
        };
        expect(names.length, 4, reason: lang.name);
        expect(names, isNot(contains('x')), reason: lang.name);
        expect(
          t.rewardProgramName('DECEMBER_2026', 'December Rewards'),
          'December Rewards',
        );
        // The headline, both ways, the seven weekdays, and the popup's two.
        expect(t.streakDays(3), contains('3'), reason: lang.name);
        expect(t.streakDays(1), isNot(equals(t.streakDays(2))));
        expect(t.calendarDayReward(10), contains('10'), reason: lang.name);
        final weekdays = {for (var d = 1; d <= 7; d++) t.weekdayShort(d)};
        expect(weekdays.length, 7, reason: lang.name);
        expect(t.todaysReward(chips), contains(chips), reason: lang.name);
        expect(t.rewardsAlso(emoji), contains(emoji), reason: lang.name);
      }
    });

    test('the short figure on a tile', () {
      expect(
        rewardPrizeShort(
          RewardPrize.fromJson(dayJson(1, 'CHIPS', value: 10000)),
        ),
        '10,000',
      );
      expect(
        rewardPrizeShort(RewardPrize.fromJson(dayJson(6, 'HAMMER', value: 2))),
        '×2',
      );
      expect(
        rewardPrizeShort(
          RewardPrize.fromJson(
            dayJson(10, 'EMOJI', ref: '5', emoji: clappingHands),
          ),
        ),
        'Clapping Hands',
      );
      expect(
        rewardPrizeShort(RewardPrize.fromJson(dayJson(4, 'NO_REWARD'))),
        '',
      );
    });
  });

  group('GameState', () {
    test('a read is one GET with the session; it claims nothing', () async {
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final state = rewardState();
        addTearDown(state.dispose);
        await state.loadRewardPrograms();
        expect(_gets(sent), ['/api/reward-programs']);
        expect(_posts(sent), isEmpty);
        expect(sent.single.headers['Authorization'], 'Bearer tok');
        expect(state.rewardPrograms?.map((p) => p.program.code), [
          'WEEKLY_LOGIN',
          'MONTHLY_CALENDAR',
        ]);
        expect(state.rewardProgramsFailed, isFalse);
        expect(state.rewardsGranted, isNull);
        expect(state.user?.chips, 1000000);
      }, () => fakeRewards(sent: sent));
    });

    test('a claim sends one POST with the session, takes what it gave, the '
        'programs and the account, and celebrates the grants', () async {
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          addTearDown(state.dispose);
          var notified = 0;
          state.addListener(() => notified++);
          final granted = await state.claimRewardPrograms();
          expect(_posts(sent), ['/api/reward-programs/claim']);
          final post = sent.singleWhere((r) => r.method == 'POST');
          expect(post.headers['Authorization'], 'Bearer tok');
          expect(post.body, '{}');
          expect(granted?.length, 2);
          expect(state.rewardClaimPending, isFalse);
          expect(state.rewardProgramsFailed, isFalse);
          expect(state.rewardPrograms?.map((p) => p.program.code), [
            'WEEKLY_LOGIN',
            'MONTHLY_CALENDAR',
          ]);
          expect(state.user?.chips, 1020000);
          expect(state.rewardsGranted?.length, 2);
          expect(state.rewardsGranted?.first.prize.amount, 20000);
          expect(notified, greaterThanOrEqualTo(2));
          // An item won: the shelves are read again for who owns what.
          await pumpEventQueue();
          expect(sent.map((r) => r.url.path), contains('/api/profiles'));
          state.dismissRewardsGranted();
          expect(state.rewardsGranted, isNull);
        },
        () => fakeRewards(
          sent: sent,
          claim: claimJson(granted: twoGrants(), chips: 1020000),
        ),
      );
    });

    test('every tap claims; nothing granted raises no celebration; a claim '
        'told not to celebrate leaves the celebration to its caller', () async {
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final state = rewardState();
        addTearDown(state.dispose);
        final first = await state.claimRewardPrograms();
        final second = await state.claimRewardPrograms();
        expect(_posts(sent).length, 2);
        expect(first, isEmpty);
        expect(second, isEmpty);
        expect(state.rewardsGranted, isNull);
        expect(state.rewardPrograms?.length, 2);
        // The shelves were not read: nothing was won.
        expect(sent.map((r) => r.url.path), isNot(contains('/api/profiles')));
      }, () => fakeRewards(sent: sent, claim: claimJson()));
      final quiet = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          addTearDown(state.dispose);
          final granted = await state.claimRewardPrograms(celebrate: false);
          expect(granted?.length, 2);
          expect(state.rewardsGranted, isNull);
          expect(state.user?.chips, 1020000);
        },
        () => fakeRewards(
          sent: quiet,
          claim: claimJson(granted: twoGrants(), chips: 1020000),
        ),
      );
    });

    test('nothing is claimed or read at a table, or signed out', () async {
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final seated = rewardState()..room = _table();
        addTearDown(seated.dispose);
        expect(await seated.claimRewardPrograms(), isNull);
        expect(sent, isEmpty);
        final out = rewardState(signedIn: false);
        addTearDown(out.dispose);
        expect(await out.claimRewardPrograms(), isNull);
        await out.loadRewardPrograms();
        expect(sent, isEmpty);
      }, () => fakeRewards(sent: sent));
    });

    test(
      'a server without the programs shows none, and that is no failure',
      () async {
        for (final status in [404, 503]) {
          final sent = <http.Request>[];
          await http.runWithClient(
            () async {
              final state = rewardState();
              addTearDown(state.dispose);
              await state.loadRewardPrograms();
              expect(state.rewardPrograms, isNull);
              expect(state.rewardProgramsFailed, isFalse);
              expect(state.weeklyLoginOffer, isNull);
              expect(await state.claimRewardPrograms(), isNull);
              expect(state.rewardPrograms, isNull);
              expect(state.rewardProgramsFailed, isFalse);
              expect(state.rewardsGranted, isNull);
            },
            () {
              final refusal = http.Response(
                jsonEncode({'error': 'reward_programs_unavailable'}),
                status,
              );
              return fakeRewards(
                sent: sent,
                claimResponse: refusal,
                programsResponse: refusal,
              );
            },
          );
        }
      },
    );

    test('a claim refused at a table changes nothing', () async {
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          addTearDown(state.dispose);
          expect(await state.claimRewardPrograms(), isNull);
          expect(_posts(sent).length, 1);
          expect(state.rewardPrograms, isNull);
          expect(state.rewardProgramsFailed, isFalse);
          expect(state.rewardsGranted, isNull);
          expect(state.user?.chips, 1000000);
        },
        () => fakeRewards(
          sent: sent,
          claimResponse: http.Response(
            jsonEncode({
              'error': 'seated',
              'message': 'Collect your rewards from the lobby.',
            }),
            409,
          ),
        ),
      );
    });

    test(
      'a claim the network lost is a failure only while nothing is held',
      () async {
        final sent = <http.Request>[];
        var down = true;
        await http.runWithClient(
          () async {
            final state = rewardState();
            addTearDown(state.dispose);
            expect(await state.claimRewardPrograms(), isNull);
            expect(state.rewardPrograms, isNull);
            expect(state.rewardProgramsFailed, isTrue);
            // Try again reads without claiming.
            down = false;
            await state.loadRewardPrograms();
            expect(sent.last.method, 'GET');
            expect(sent.last.url.path, '/api/reward-programs');
            expect(state.rewardPrograms?.length, 2);
            expect(state.rewardProgramsFailed, isFalse);
            expect(state.rewardsGranted, isNull);
            // Held now: a later loss keeps what is held and says nothing.
            down = true;
            expect(await state.claimRewardPrograms(), isNull);
            expect(state.rewardPrograms?.length, 2);
            expect(state.rewardProgramsFailed, isFalse);
          },
          () => MockClient((request) async {
            sent.add(request);
            if (down) throw const SocketException('no route');
            if (request.url.path == '/api/reward-programs') {
              return rewardJson({
                'programs': [streakJson(), calendarJson()],
              });
            }
            return rewardJson({'error': 'not_found'}, 404);
          }),
        );
      },
    );

    test('an answer to a session that has ended is dropped', () async {
      final sent = <http.Request>[];
      final release = Completer<void>();
      await http.runWithClient(
        () async {
          final state = rewardState();
          addTearDown(state.dispose);
          final claim = state.claimRewardPrograms();
          expect(state.rewardClaimPending, isTrue);
          await state.signOut();
          release.complete();
          expect(await claim, isNull);
          expect(state.rewardPrograms, isNull);
          expect(state.rewardsGranted, isNull);
          expect(state.user, isNull);
        },
        () => fakeRewards(
          sent: sent,
          release: release,
          claim: claimJson(granted: twoGrants()),
        ),
      );
    });

    test(
      'sign-out forgets the programs, the popup and the celebration',
      () async {
        final sent = <http.Request>[];
        await http.runWithClient(
          () async {
            final state = rewardState();
            addTearDown(state.dispose);
            await state.claimRewardPrograms();
            expect(state.rewardPrograms, isNotNull);
            expect(state.rewardsGranted, isNotNull);
            await state.loadRewardPrograms();
            await state.signOut();
            expect(state.rewardPrograms, isNull);
            expect(state.rewardsGranted, isNull);
            expect(state.weeklyLoginOffer, isNull);
            expect(state.rewardProgramsFailed, isFalse);
          },
          () => fakeRewards(
            sent: sent,
            claim: claimJson(granted: twoGrants()),
            programs: {
              'programs': [streakJson(claimedToday: false), calendarJson()],
            },
          ),
        );
      },
    );

    test(
      'the API answers null on 404 and 503, throws the refusal otherwise',
      () async {
        for (final status in [404, 503]) {
          await http.runWithClient(
            () async {
              final api = ApiClient(rewardServer);
              expect(await api.rewardPrograms('tok'), isNull);
              expect(await api.claimRewardPrograms('tok'), isNull);
            },
            () => MockClient(
              (_) async => http.Response(
                jsonEncode({'error': 'reward_programs_unavailable'}),
                status,
              ),
            ),
          );
        }
        await http.runWithClient(
          () async {
            await expectLater(
              ApiClient(rewardServer).claimRewardPrograms('tok'),
              throwsA(
                isA<ApiException>().having((e) => e.code, 'code', 'seated'),
              ),
            );
          },
          () => MockClient(
            (_) async => http.Response(
              jsonEncode({'error': 'seated', 'message': 'Not here.'}),
              409,
            ),
          ),
        );
      },
    );
  });

  group('the lobby', () {
    testWidgets('reads as it appears and claims nothing, keeps the chip\'s '
        'room meanwhile, then says the streak and opens the screen', (
      tester,
    ) async {
      await setRewardView(tester);
      final sent = <http.Request>[];
      final release = Completer<void>();
      await http.runWithClient(
        () async {
          final state = rewardState();
          await pumpRewardLobby(tester, state);
          // The read is out: one GET, no POST, the chip's room kept and
          // nothing shown.
          expect(_gets(sent), ['/api/reward-programs']);
          expect(_posts(sent), isEmpty);
          expect(find.byKey(const ValueKey('rewards-chip')), findsNothing);
          final held = find.ancestor(
            of: find.text(state.t.rewardsChip),
            matching: find.byType(Visibility),
          );
          expect(held, findsOneWidget);
          expect(tester.widget<Visibility>(held).visible, isFalse);
          release.complete();
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          // Landed, everything collected: the chip says the streak, no
          // popup, no celebration.
          final chip = find.byKey(const ValueKey('rewards-chip'));
          expect(chip, findsOneWidget);
          expect(
            find.descendant(of: chip, matching: find.text(state.t.rewardsChip)),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: chip,
              matching: find.text(state.t.streakDays(3)),
            ),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('weekly-login-overlay')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey('rewards-celebration')),
            findsNothing,
          );
          expect(_posts(sent), isEmpty);
          // A tap opens the screen, which reads again — the day may have
          // turned — and shows the programs.
          await tester.tap(chip);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pump(const Duration(milliseconds: 600));
          expect(find.byType(RewardProgramsScreen), findsOneWidget);
          expect(_gets(sent).length, 2);
          expect(_posts(sent), isEmpty);
          expect(
            find.byKey(const ValueKey('reward-program-WEEKLY_LOGIN')),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const ValueKey('reward-programs-close')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          expect(find.byType(RewardProgramsScreen), findsNothing);
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          release: release,
          programs: {
            'programs': [streakJson(), calendarJson(claimedToday: true)],
          },
        ),
      );
    });

    testWidgets('while a reward waits the chip says Collect now', (
      tester,
    ) async {
      await setRewardView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          await pumpRewardLobby(tester, state);
          final chip = find.byKey(const ValueKey('rewards-chip'));
          expect(chip, findsOneWidget);
          expect(
            find.descendant(
              of: chip,
              matching: find.text(state.t.rewardsCollect),
            ),
            findsOneWidget,
          );
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          programs: {
            'programs': [streakJson(), calendarJson()],
          },
        ),
      );
    });

    testWidgets('a server with no programs shows no chip', (tester) async {
      await setRewardView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          await pumpRewardLobby(tester, state);
          expect(_gets(sent), ['/api/reward-programs']);
          expect(find.byKey(const ValueKey('rewards-chip')), findsNothing);
          expect(find.text(state.t.rewardsChip), findsNothing);
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          programsResponse: http.Response(
            jsonEncode({'error': 'not_found'}),
            404,
          ),
        ),
      );
    });

    for (final (screen, scale) in const [
      (Size(640, 360), 1.25),
      (Size(592, 360), 1.25),
      (Size(915, 412), 1.0),
      (Size(1280, 800), 1.25),
    ]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          'at ${screen.width.toInt()}x${screen.height.toInt()} x$scale '
          '(${brightness.name}) the chip stands beside the Lucky Draw, on '
          'the screen, clear of the foot keys, and a toast keeps off it',
          (tester) async {
            await setRewardView(tester, screen: screen, textScale: scale);
            final sent = <http.Request>[];
            await http.runWithClient(
              () async {
                final state = rewardState()..luckyDraw = _luckyDraw();
                await pumpRewardLobby(tester, state, brightness: brightness);
                expect(tester.takeException(), isNull);
                final t = state.t;
                final rewards = tester.getRect(
                  find.byKey(const ValueKey('rewards-chip')),
                );
                final lucky = tester.getRect(
                  find.byKey(const ValueKey('lucky-draw-chip')),
                );
                final level = tester.getRect(
                  find.byKey(const ValueKey('level-key')),
                );
                final record = tester.getRect(
                  find.byKey(const ValueKey('stats-key')),
                );
                final friends = tester.getRect(find.byTooltip(t.friends));
                final onScreen = Offset.zero & screen;
                for (final (name, r) in [
                  ('the rewards', rewards),
                  ('the Lucky Draw', lucky),
                  ('the level key', level),
                  ('the record', record),
                  ('Friends', friends),
                ]) {
                  expect(r.isEmpty, isFalse, reason: name);
                  expect(
                    onScreen.contains(r.topLeft) &&
                        onScreen.contains(r.bottomRight - const Offset(1, 1)),
                    isTrue,
                    reason: '$name at $r',
                  );
                  expect(
                    r.height,
                    greaterThanOrEqualTo(Dim.minTouch),
                    reason: name,
                  );
                }
                // In the left-hand corner after the Lucky Draw, level with it.
                expect(rewards.left, greaterThanOrEqualTo(lucky.right));
                expect((rewards.bottom - lucky.bottom).abs(), lessThan(1));
                expect(rewards.overlaps(lucky), isFalse);
                expect(rewards.overlaps(level), isFalse);
                expect(rewards.overlaps(record), isFalse);
                expect(rewards.overlaps(friends), isFalse);
                expect(rewards.right, lessThan(level.left));
                // Its two lines whole.
                expectRewardWhole(
                  tester,
                  find.byKey(const ValueKey('rewards-chip')),
                  '${screen.width.toInt()} x$scale',
                );
                // A toast keeps off both chips.
                final lobby = tester.element(find.byType(LobbyScreen));
                final toast = lobbyNoticeArea(lobby);
                expect(toast, isNotNull);
                expect(toast!.left, greaterThanOrEqualTo(rewards.right));
                await unmountReward(tester, state);
              },
              () => fakeRewards(
                sent: sent,
                programs: {
                  'programs': [streakJson(), calendarJson(claimedToday: true)],
                },
              ),
            );
          },
        );
      }
    }
  });

  group('the screen', () {
    testWidgets('a streak is headed by its run, a calendar by its day; the '
        'week has seven tiles and the month thirty-one; the next reward is '
        'named; every tile says its day, its reward and its standing; and '
        'Collect claims and closes', (tester) async {
      await setRewardView(tester, textScale: 1.25);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          final handle = tester.ensureSemantics();
          await _openScreen(tester, state);
          final t = state.t;
          expect(tester.takeException(), isNull);
          expect(find.byType(RewardProgramsScreen), findsOneWidget);
          expect(find.text(t.rewardsTitle), findsOneWidget);
          // Opening read (no claim), and the screen shows the answer.
          expect(_gets(sent), ['/api/reward-programs']);
          expect(_posts(sent), isEmpty);

          // The streak: "3 day streak", LOGIN STREAK, seven tiles, Day 4's
          // diamond next.
          final streak = find.byKey(
            const ValueKey('reward-program-WEEKLY_LOGIN'),
          );
          expect(streak, findsOneWidget);
          expect(
            tester
                .widget<Text>(
                  find.byKey(const ValueKey('reward-headline-WEEKLY_LOGIN')),
                )
                .data,
            t.streakDays(3),
          );
          expect(
            find.descendant(
              of: streak,
              matching: find.text(t.rewardModeStreak),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: streak,
              matching: find.text(t.rewardProgramName('WEEKLY_LOGIN', '')),
            ),
            findsOneWidget,
          );
          for (var k = 1; k <= 7; k++) {
            expect(
              find.byKey(ValueKey('reward-day-WEEKLY_LOGIN-$k')),
              findsOneWidget,
              reason: 'day $k',
            );
          }
          expect(
            find.byKey(const ValueKey('reward-day-WEEKLY_LOGIN-8')),
            findsNothing,
          );
          final next = tester.widget<Text>(
            find.byKey(const ValueKey('reward-next-WEEKLY_LOGIN')),
          );
          expect(next.data, contains(t.rewardNext));
          expect(
            next.data,
            contains(
              rewardPrizeLabel(
                t,
                RewardPrize.fromJson(dayJson(4, 'DIAMOND', value: 1)),
              ),
            ),
          );
          // What a screen reader hears of Day 3 — today's, collected — and
          // of Day 5, not reached, and Day 1, collected on Monday.
          String heard(String code, int k) => tester
              .getSemantics(find.byKey(ValueKey('reward-day-$code-$k')))
              .label;
          expect(heard('WEEKLY_LOGIN', 3), contains(t.rewardDay(3)));
          expect(heard('WEEKLY_LOGIN', 3), contains(t.weekdayShort(3)));
          expect(heard('WEEKLY_LOGIN', 3), contains('20,000'));
          expect(heard('WEEKLY_LOGIN', 3), contains(t.rewardTileClaimed));
          expect(heard('WEEKLY_LOGIN', 5), contains(t.rewardTileLocked));
          expect(heard('WEEKLY_LOGIN', 1), contains(t.weekdayShort(1)));

          // The calendar: "Day 10 reward", CALENDAR, thirty-one tiles, the
          // 4th missed, the 10th today's and waiting, the emoji next.
          final list = find.byKey(const ValueKey('reward-programs-list'));
          final calendar = find.byKey(
            const ValueKey('reward-program-MONTHLY_CALENDAR'),
          );
          await tester.dragUntilVisible(calendar, list, const Offset(0, -120));
          await tester.pump();
          expect(
            tester
                .widget<Text>(
                  find.byKey(
                    const ValueKey('reward-headline-MONTHLY_CALENDAR'),
                  ),
                )
                .data,
            t.calendarDayReward(10),
          );
          expect(
            find.descendant(
              of: calendar,
              matching: find.text(t.rewardModeCalendar),
            ),
            findsOneWidget,
          );
          for (var k = 1; k <= 31; k++) {
            expect(
              find.byKey(ValueKey('reward-day-MONTHLY_CALENDAR-$k')),
              findsOneWidget,
              reason: 'day $k',
            );
          }
          expect(
            find.byKey(const ValueKey('reward-day-MONTHLY_CALENDAR-32')),
            findsNothing,
          );
          expect(heard('MONTHLY_CALENDAR', 4), contains(t.rewardTileMissed));
          expect(heard('MONTHLY_CALENDAR', 9), contains(t.rewardTileClaimed));
          expect(heard('MONTHLY_CALENDAR', 10), contains(t.rewardToday));
          expect(heard('MONTHLY_CALENDAR', 10), contains('Clapping Hands'));
          expect(heard('MONTHLY_CALENDAR', 11), contains(t.rewardTileLocked));
          expect(heard('MONTHLY_CALENDAR', 31), contains('Royal Ace'));
          expect(
            tester
                .widget<Text>(
                  find.byKey(const ValueKey('reward-next-MONTHLY_CALENDAR')),
                )
                .data,
            contains('Clapping Hands'),
          );
          handle.dispose();

          // The calendar's 10th waits: Collect stands, claims on a tap, and
          // the screen closes over the lobby's celebration.
          final collect = find.byKey(const ValueKey('reward-programs-collect'));
          expect(collect, findsOneWidget);
          await tester.tap(collect);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pump(const Duration(milliseconds: 600));
          expect(_posts(sent), ['/api/reward-programs/claim']);
          expect(find.byType(RewardProgramsScreen), findsNothing);
          expect(state.rewardsGranted?.length, 2);
          expect(state.user?.chips, 1020000);
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          programs: {
            'programs': [streakJson(), calendarJson()],
          },
          claim: claimJson(granted: twoGrants(), chips: 1020000),
        ),
      );
    });

    testWidgets('with everything collected there is no Collect key', (
      tester,
    ) async {
      await setRewardView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          await _openScreen(tester, state);
          expect(
            find.byKey(const ValueKey('reward-programs-collect')),
            findsNothing,
          );
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          programs: {
            'programs': [streakJson(), calendarJson(claimedToday: true)],
          },
        ),
      );
    });

    testWidgets('a streak not yet begun says so, and a day that gives '
        'nothing is drawn as none', (tester) async {
      await setRewardView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          final handle = tester.ensureSemantics();
          await _openScreen(tester, state);
          final t = state.t;
          expect(
            tester
                .widget<Text>(
                  find.byKey(const ValueKey('reward-headline-WEEKLY_LOGIN')),
                )
                .data,
            t.streakStart,
          );
          expect(
            tester
                .getSemantics(
                  find.byKey(const ValueKey('reward-day-WEEKLY_LOGIN-2')),
                )
                .label,
            contains(t.rewardNothing),
          );
          handle.dispose();
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          programs: {
            'programs': [
              {
                ...streakJson(day: 1, claimedToday: false),
                'rewards': [
                  dayJson(1, 'CHIPS', value: 10000),
                  dayJson(3, 'CHIPS', value: 20000),
                ],
              },
            ],
          },
        ),
      );
    });

    testWidgets('with nothing running it says so; a failed read offers Try '
        'again, which reads without claiming', (tester) async {
      await setRewardView(tester);
      final sent = <http.Request>[];
      var down = true;
      await http.runWithClient(
        () async {
          final state = rewardState();
          await _openScreen(tester, state);
          final t = state.t;
          expect(find.text(t.rewardLoadFailed), findsOneWidget);
          expect(find.text(t.luckyRetry), findsOneWidget);
          down = false;
          await tester.tap(find.text(t.luckyRetry));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          expect(sent.last.method, 'GET');
          expect(sent.last.url.path, '/api/reward-programs');
          expect(find.text(t.rewardNone), findsOneWidget);
          expect(find.text(t.luckyRetry), findsNothing);
          await unmountReward(tester, state);
        },
        () => MockClient((request) async {
          sent.add(request);
          if (down) throw const SocketException('no route');
          return rewardJson({'programs': const []});
        }),
      );
    });

    for (final lang in AppLang.values) {
      testWidgets('fits a 640x360 phone at text x1.25 in ${lang.name}, no '
          'line cut, in both themes', (tester) async {
        await setRewardView(tester, textScale: 1.25);
        for (final brightness in Brightness.values) {
          final sent = <http.Request>[];
          await http.runWithClient(
            () async {
              final state = rewardState(lang: lang);
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
              expect(tester.takeException(), isNull);
              final reason = '${lang.name} ${brightness.name}';
              final view = Offset.zero & const Size(640, 360);
              // The Collect key, whole and on the screen.
              final collect = find.byKey(
                const ValueKey('reward-programs-collect'),
              );
              expect(collect, findsOneWidget, reason: reason);
              expectRewardWhole(tester, collect, '$reason collect');
              expect(
                view.contains(tester.getRect(collect).bottomRight),
                isTrue,
                reason: reason,
              );
              for (final code in const ['WEEKLY_LOGIN', 'MONTHLY_CALENDAR']) {
                final panel = find.byKey(ValueKey('reward-program-$code'));
                await tester.dragUntilVisible(
                  panel,
                  find.byKey(const ValueKey('reward-programs-list')),
                  const Offset(0, -120),
                );
                await tester.pump();
                expectRewardWhole(tester, panel, reason);
                final headline = find.byKey(ValueKey('reward-headline-$code'));
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
                // The panel inside the page, side to side.
                final r = tester.getRect(panel);
                expect(r.left, greaterThanOrEqualTo(view.left), reason: reason);
                expect(r.right, lessThanOrEqualTo(view.right), reason: reason);
                // Its tiles, every one, and their words never cut: a tile
                // sets them down instead. (Counted while the panel is on
                // screen: the list lets a panel go once it has scrolled far
                // enough away.)
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
                expect(
                  tiles,
                  findsNWidgets(code == 'WEEKLY_LOGIN' ? 7 : 31),
                  reason: '$reason $code',
                );
                expectRewardWhole(tester, tiles, '$reason $code tiles');
              }
              await unmountReward(tester, state);
            },
            () => fakeRewards(
              sent: sent,
              programs: {
                'programs': [streakJson(), calendarJson()],
              },
            ),
          );
        }
      });
    }
  });

  group('the celebration', () {
    testWidgets('lists what the claim gave, one line each, and closes', (
      tester,
    ) async {
      await setRewardView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState()
            ..rewardPrograms = rewardProgramsFromJson([
              streakJson(),
              calendarJson(claimedToday: true),
            ])
            ..rewardsGranted = [
              for (final g in [
                ...twoGrants(),
                grantJson(
                  code: 'MONTHLY_CALENDAR',
                  day: 25,
                  reward: dayJson(
                    25,
                    'TABLE_PICTURE',
                    ref: '1',
                    tablePicture: linesBackground,
                  ),
                  alreadyOwned: true,
                ),
              ])
                RewardGrant.fromJson(g),
            ];
          await pumpRewardLobby(tester, state);
          expect(tester.takeException(), isNull);
          final t = state.t;
          final party = find.byKey(const ValueKey('rewards-celebration'));
          expect(party, findsOneWidget);
          expect(
            find.descendant(
              of: party,
              matching: find.text(t.rewardsCollectedTitle),
            ),
            findsOneWidget,
          );
          String lineOf(Map<String, Object?> reward) =>
              rewardPrizeLabel(t, RewardPrize.fromJson(reward));
          expect(
            find.descendant(
              of: party,
              matching: find.text(
                '+ ${lineOf(dayJson(3, 'CHIPS', value: 20000))}',
              ),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: party,
              matching: find.text(
                lineOf(dayJson(10, 'EMOJI', ref: '5', emoji: clappingHands)),
              ),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: party,
              matching: find.textContaining(t.rewardAlreadyOwned),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: party,
              matching: find.textContaining(
                t.rewardProgramName('WEEKLY_LOGIN', ''),
              ),
            ),
            findsOneWidget,
          );
          // The lobby's own purchase celebration is not shown as well.
          expect(find.text(t.rewardCollected), findsNothing);
          await tester.tap(find.text(t.tapToClose));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(state.rewardsGranted, isNull);
          expect(party, findsNothing);
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          programs: {
            'programs': [streakJson(), calendarJson(claimedToday: true)],
          },
        ),
      );
    });

    testWidgets('the lobby claims nothing by itself: no celebration until the '
        'player collects', (tester) async {
      await setRewardView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          await pumpRewardLobby(tester, state);
          expect(_gets(sent), ['/api/reward-programs']);
          expect(_posts(sent), isEmpty);
          expect(state.rewardPrograms, isNotNull);
          expect(state.rewardsGranted, isNull);
          expect(
            find.byKey(const ValueKey('rewards-celebration')),
            findsNothing,
          );
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          programs: {
            'programs': [streakJson(), calendarJson()],
          },
        ),
      );
    });
  });
}
