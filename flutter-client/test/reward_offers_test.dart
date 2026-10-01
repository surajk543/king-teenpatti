// One reward popup a program (owner, 2 Oct 2026: "for every reward type
// sequential or calender there should be different pop up, not a single pup
// up to collect all reward").
//
// These hold the lobby to: a popup for every program whose today waits, in
// the server's order, "n of m", none for a program broken or collected; each
// popup in its own kind's look — the owner's calendar for the weekly login
// streak, the program's own days for every other (a sequential login's steps
// joined by chevrons, a calendar's pages, a breaking calendar's chain, a
// month's dates) — its headline in its kind's ink and words; each collecting
// its own program alone, by its key or by today's day on its card, Continue
// bringing the next; no popup put up behind the rewards screen; and every
// popup whole at 640x360 and 592x360 x1.25 in all five languages, both
// themes.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/screens/reward_programs_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';

import 'reward_fixtures.dart';

/// The programs, in the server's order: five waiting today, one broken and
/// one collected.
const _waiting = [
  'WEEKLY_LOGIN',
  'WEEKLY_SEQUENTIAL_LOGIN',
  'WEEKLY_CALENDAR',
  'WEEKLY_BREAK_CALENDAR',
  'MONTHLY_CALENDAR',
];

/// A weekly calendar on its Wednesday, today to collect.
Map<String, Object?> _calendarWeek({
  required String code,
  required String progression,
  required List<String> states,
}) => progressedWeekJson(
  code: code,
  mode: 'CALENDAR',
  progression: progression,
  states: states,
  currentDay: 3,
  claimedToday: false,
  canClaim: true,
  nextDay: 3,
);

List<Map<String, Object?>> _programs() => [
  activeResetWeekJson(),
  activeSequentialWeekJson(),
  _calendarWeek(
    code: 'WEEKLY_CALENDAR',
    progression: 'SEQUENTIAL',
    states: const [
      'CLAIMED',
      'MISSED',
      'AVAILABLE',
      'LOCKED',
      'LOCKED',
      'LOCKED',
      'LOCKED',
    ],
  ),
  _calendarWeek(
    code: 'WEEKLY_BREAK_CALENDAR',
    progression: 'BREAK',
    states: const [
      'CLAIMED',
      'CLAIMED',
      'AVAILABLE',
      'LOCKED',
      'LOCKED',
      'LOCKED',
      'LOCKED',
    ],
  ),
  progressedMonthJson(),
  brokenCalendarWeekJson(code: 'WEEKLY_BROKEN_CALENDAR'),
  completedWeekJson(code: 'WEEKLY_DONE'),
];

/// A server with [_programs] whose claims collect the one program they name:
/// its day to collect turns collected, it can no longer be claimed today, and
/// the grant is that day's reward. Every request is kept in [sent]; one
/// server, whatever client the app makes.
MockClient Function() _server(List<http.Request> sent) {
  final byCode = {
    for (final p in _programs())
      ((p['program']! as Map<String, Object?>)['code']! as String): p,
  };
  Future<http.Response> answer(http.Request request) async {
    sent.add(request);
    final path = request.url.path;
    if (path == '/api/reward-programs/claim' && request.method == 'POST') {
      final named =
          (jsonDecode(request.body) as Map<String, Object?>)['programCode'];
      final granted = <Map<String, Object?>>[];
      for (final code in byCode.keys.toList()) {
        final p = byCode[code]!;
        if ((named != null && code != named) || p['canClaim'] != true) {
          continue;
        }
        final rewards = (p['rewards']! as List).cast<Map<String, Object?>>();
        final i = rewards.indexWhere((d) => d['state'] == 'AVAILABLE');
        final day = rewards[i];
        byCode[code] = {
          ...p,
          'rewards': [
            for (final (k, d) in rewards.indexed)
              k == i ? {...d, 'state': 'CLAIMED', 'claimed': true} : d,
          ],
          'canClaim': false,
          'claimedToday': true,
          'claimedDays': (p['claimedDays']! as int) + 1,
        };
        granted.add(
          grantJson(code: code, day: day['day']! as int, reward: day),
        );
      }
      return rewardJson({
        'serverTime': progressionServerTime,
        'granted': granted,
        'programs': byCode.values.toList(),
        'user': userJson(),
      });
    }
    if (path == '/api/reward-programs') {
      return rewardJson(progressedProgramsJson(byCode.values.toList()));
    }
    if (path == '/api/friends/requests') {
      return rewardJson({
        'incoming': const [],
        'outgoing': const [],
        'incomingTotal': 0,
        'outgoingTotal': 0,
        'nextIncoming': null,
        'nextOutgoing': null,
      });
    }
    if (path == '/api/friends') {
      return rewardJson({'friends': const [], 'total': 0, 'nextCursor': null});
    }
    return rewardJson({'error': 'not_found'}, 404);
  }

  return () => MockClient(answer);
}

Finder get _overlay => find.byKey(const ValueKey('reward-offer-overlay'));
Finder get _panel => find.byKey(const ValueKey('reward-offer-panel'));
Finder get _stage => find.byKey(const ValueKey('reward-offer-stage'));
Finder get _collect => find.byKey(const ValueKey('reward-offer-collect'));
Finder get _done => find.byKey(const ValueKey('reward-offer-done'));
Finder get _close => find.byKey(const ValueKey('reward-offer-close'));
Finder get _headline => find.byKey(const ValueKey('reward-offer-headline'));
Finder get _position => find.byKey(const ValueKey('reward-offer-position'));

/// The joints a program's card draws between its days.
Finder _joints(String code) => find.descendant(
  of: _stage,
  matching: find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key as ValueKey<String>).value.startsWith('reward-joint-$code-'),
  ),
);

/// The circles on a program's card: a streak's medallions.
int _discs(WidgetTester tester) => tester
    .widgetList<DecoratedBox>(
      find.descendant(of: _stage, matching: find.byType(DecoratedBox)),
    )
    .where(
      (d) =>
          d.decoration is BoxDecoration &&
          (d.decoration as BoxDecoration).shape == BoxShape.circle,
    )
    .length;

/// The day each waiting program has to collect today.
const _today = {
  'WEEKLY_LOGIN': 3,
  'WEEKLY_SEQUENTIAL_LOGIN': 4,
  'WEEKLY_CALENDAR': 3,
  'WEEKLY_BREAK_CALENDAR': 3,
  'MONTHLY_CALENDAR': 10,
};

/// The lobby pumped and its read answered, the first popup's entrance over.
Future<void> _pumpLobby(WidgetTester tester, GameState state) async {
  await pumpRewardLobby(tester, state);
  await tester.pump(const Duration(seconds: 2));
  await tester.pump(const Duration(milliseconds: 500));
}

/// The popup on screen put away by its close key, the next one's entrance
/// over.
Future<void> _next(WidgetTester tester) async {
  await tester.tap(_close);
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadRewardFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('one popup a program', () {
    testWidgets('every program waiting today gets a popup of its own, in the '
        'server\'s order, "n of 5", each in its own kind\'s look — and none '
        'for a program broken or collected', (tester) async {
      await setRewardView(tester, screen: const Size(915, 412));
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final state = rewardState();
        await _pumpLobby(tester, state);
        expect(tester.takeException(), isNull);
        final t = state.t;
        final scheme = Theme.of(tester.element(_panel)).colorScheme;
        final gold = AppTheme.paletteFor(
          scheme,
          category: 'seen',
          bootAmount: 0,
        );
        final sapphire = AppTheme.paletteFor(
          scheme,
          category: 'blind',
          bootAmount: 0,
        );
        final emerald = AppTheme.privatePalette(scheme);
        final violet = AppTheme.violetPalette(scheme);
        final shown = <String>[];
        for (final (i, code) in _waiting.indexed) {
          expect(state.rewardOffer?.program.code, code);
          expect(
            find.byKey(ValueKey('reward-offer-$code')),
            findsOneWidget,
            reason: code,
          );
          shown.add(code);
          expect(
            tester.widget<Text>(_position).data,
            t.rewardOfferPosition(i + 1, _waiting.length).toUpperCase(),
            reason: code,
          );
          final headline = tester.widget<Text>(_headline);
          Finder mark(IconData icon) =>
              find.descendant(of: _panel, matching: find.byIcon(icon));
          switch (code) {
            case 'WEEKLY_LOGIN':
              // The owner's calendar, the streak in gold under a flame.
              expect(
                find.byKey(const ValueKey('weekly-calendar')),
                findsOneWidget,
              );
              expect(_stage, findsNothing);
              expect(headline.data, t.streakDays(2).toUpperCase());
              expect(headline.style?.color, gold.ink);
              expect(mark(Icons.local_fire_department_rounded), findsWidgets);
            case 'WEEKLY_SEQUENTIAL_LOGIN':
              // Emerald steps joined by chevrons, under stairs.
              expect(
                find.byKey(const ValueKey('weekly-calendar')),
                findsNothing,
              );
              expect(_stage, findsOneWidget);
              expect(_discs(tester), 0);
              expect(_joints(code), findsNWidgets(5));
              expect(
                find.descendant(
                  of: _stage,
                  matching: find.byIcon(Icons.chevron_right_rounded),
                ),
                findsNWidgets(5),
              );
              expect(headline.data, t.streakDays(3).toUpperCase());
              expect(headline.style?.color, emerald.ink);
              expect(mark(Icons.stairs_rounded), findsWidgets);
            case 'WEEKLY_CALENDAR':
              // Sapphire pages standing apart, "DAY 3 REWARD".
              expect(_stage, findsOneWidget);
              expect(_discs(tester), 0);
              expect(_joints(code), findsNothing);
              expect(headline.data, t.calendarDayReward(3).toUpperCase());
              expect(headline.style?.color, sapphire.ink);
              expect(mark(Icons.calendar_month_rounded), findsWidgets);
            case 'WEEKLY_BREAK_CALENDAR':
              // Violet pages joined by the chain, whole while it holds.
              expect(_stage, findsOneWidget);
              expect(_joints(code), findsNWidgets(5));
              expect(
                find.descendant(
                  of: _stage,
                  matching: find.byIcon(Icons.link_rounded),
                ),
                findsNWidgets(6),
              );
              expect(
                find.descendant(
                  of: _stage,
                  matching: find.byIcon(Icons.link_off_rounded),
                ),
                findsNothing,
              );
              expect(headline.data, t.calendarDayReward(3).toUpperCase());
              expect(headline.style?.color, violet.ink);
            case 'MONTHLY_CALENDAR':
              // The month's dates on a sapphire card, the 10th to collect.
              expect(_stage, findsOneWidget);
              for (var k = 1; k <= 31; k++) {
                expect(
                  find.descendant(
                    of: _stage,
                    matching: find.byKey(ValueKey('reward-day-$code-$k')),
                  ),
                  findsOneWidget,
                  reason: '$code $k',
                );
              }
              expect(
                find.byKey(ValueKey('reward-collect-$code-10')),
                findsOneWidget,
              );
              expect(headline.data, t.calendarDayReward(10).toUpperCase());
              expect(headline.style?.color, sapphire.ink);
          }
          // Each one waits for the player: nothing is claimed by a popup.
          expect(claimedPrograms(sent), isEmpty);
          await _next(tester);
        }
        expect(shown, _waiting);
        expect(_overlay, findsNothing);
        expect(state.rewardOffer, isNull);
        expect(state.rewardOfferCount, 0);
        await unmountReward(tester, state);
      }, _server(sent));
    });

    for (final b in Brightness.values) {
      testWidgets('${b.name}: no popup lets the lobby show through it — by '
          'night every popup blurs it, not only the first, and every '
          'program\'s card stands on a solid ground', (tester) async {
        await setRewardView(tester, screen: const Size(915, 412));
        final sent = <http.Request>[];
        await http.runWithClient(() async {
          final state = rewardState();
          await pumpRewardLobby(tester, state, brightness: b);
          await tester.pump(const Duration(seconds: 2));
          await tester.pump(const Duration(milliseconds: 500));
          for (final code in _waiting) {
            expect(state.rewardOffer?.program.code, code);
            // By night the panel is glass over the lobby, and only the blur
            // keeps the lobby's cards out of it; by day it is a card on a
            // solid base and blurs nothing.
            expect(
              find.descendant(
                of: find.byKey(const ValueKey('reward-offer-base')),
                matching: find.byType(BackdropFilter),
              ),
              b == Brightness.dark ? findsOneWidget : findsNothing,
              reason: code,
            );
            if (code != 'WEEKLY_LOGIN') {
              final card = tester.widget<DecoratedBox>(_stage).decoration;
              final colours =
                  ((card as BoxDecoration).gradient! as LinearGradient).colors;
              for (final c in colours) {
                expect(c.a, 1.0, reason: '$code $c');
              }
            }
            await _next(tester);
          }
          expect(_overlay, findsNothing);
          await unmountReward(tester, state);
        }, _server(sent));
      });
    }

    testWidgets('each popup collects its own program alone — by its key, or '
        'by today\'s day on its card — and Continue brings the next', (
      tester,
    ) async {
      await setRewardView(tester, screen: const Size(915, 412));
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final state = rewardState();
        await _pumpLobby(tester, state);
        for (final (i, code) in _waiting.indexed) {
          expect(state.rewardOffer?.program.code, code);
          // Every other popup by today's day on its card; the rest, and the
          // owner's calendar, by the key.
          final day = find.byKey(
            ValueKey('reward-collect-$code-${_today[code]}'),
          );
          if (i.isOdd) {
            expect(day, findsOneWidget, reason: code);
            await tester.tap(day);
          } else {
            await tester.tap(_collect);
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pump(const Duration(seconds: 1));
          expect(claimedPrograms(sent), _waiting.sublist(0, i + 1));
          expect(_done, findsOneWidget, reason: code);
          expect(
            find.byKey(const ValueKey('reward-offer-collected')),
            findsOneWidget,
          );
          // Nothing celebrated twice: the popup shows what it gave.
          expect(state.rewardsGranted, isNull);
          await tester.tap(_done);
          await tester.pump();
          await tester.pump(const Duration(seconds: 2));
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(_overlay, findsNothing);
        expect(state.rewardOffersDue, isEmpty);
        // Every claim named its program: none collected every program.
        expect(claimedPrograms(sent).contains(null), isFalse);
        await unmountReward(tester, state);
      }, _server(sent));
    });

    testWidgets('no popup is put up behind the rewards screen: a day that '
        'turns while it is open is offered once it has closed', (tester) async {
      await setRewardView(tester, screen: const Size(915, 412));
      final sent = <http.Request>[];
      var programs = [activeResetWeekJson()];
      await http.runWithClient(
        () async {
          final state = rewardState();
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
          await tester.pump();
          // Read with the streak's day collected: nothing to offer.
          programs = [completedWeekJson()];
          await state.loadRewardPrograms();
          expect(state.rewardOffer, isNull);
          await tester.tap(find.text('open'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          expect(state.rewardsScreenOpen, isTrue);
          // A new day while the screen is open: no popup behind it.
          programs = [activeResetWeekJson()];
          await state.loadRewardPrograms();
          await tester.pump();
          expect(state.rewardOffer, isNull);
          await tester.tap(find.byKey(const ValueKey('reward-programs-close')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          expect(state.rewardsScreenOpen, isFalse);
          // The lobby reads again, and offers it.
          await state.loadRewardPrograms();
          expect(state.rewardOffer?.program.code, 'WEEKLY_LOGIN');
          await unmountReward(tester, state);
        },
        () => MockClient((request) async {
          sent.add(request);
          if (request.url.path == '/api/reward-programs') {
            return rewardJson(progressedProgramsJson(programs));
          }
          return rewardJson({'error': 'not_found'}, 404);
        }),
      );
    });

    for (final screen in const [Size(640, 360), Size(592, 360)]) {
      for (final lang in AppLang.values) {
        testWidgets('every kind of popup fits a ${screen.width.toInt()}x'
            '${screen.height.toInt()} phone at text x1.25 in ${lang.name}, '
            'both themes: on the screen, its card inside it, no word cut', (
          tester,
        ) async {
          await setRewardView(tester, screen: screen, textScale: 1.25);
          for (final brightness in Brightness.values) {
            final sent = <http.Request>[];
            await http.runWithClient(() async {
              final state = rewardState(lang: lang);
              await pumpRewardLobby(tester, state, brightness: brightness);
              await tester.pump(const Duration(seconds: 2));
              await tester.pump(const Duration(milliseconds: 500));
              final view = Offset.zero & screen;
              for (final code in _waiting) {
                final reason = '${lang.name} ${brightness.name} $code';
                expect(tester.takeException(), isNull, reason: reason);
                expect(state.rewardOffer?.program.code, code);
                final panel = tester.getRect(_panel);
                expect(view.contains(panel.topLeft), isTrue, reason: reason);
                expect(
                  view.contains(panel.bottomRight - const Offset(1, 1)),
                  isTrue,
                  reason: '$reason $panel',
                );
                expectRewardWhole(tester, _panel, reason);
                // The card (or the owner's calendar) inside the panel.
                final card = code == 'WEEKLY_LOGIN'
                    ? find.byKey(const ValueKey('weekly-calendar'))
                    : _stage;
                final r = tester.getRect(card);
                expect(
                  panel.contains(r.topLeft) &&
                      panel.contains(r.bottomRight - const Offset(1, 1)),
                  isTrue,
                  reason: '$reason $r in $panel',
                );
                // The key, whole and reachable.
                expect(_collect, findsOneWidget, reason: reason);
                expect(
                  view.contains(tester.getRect(_collect).bottomRight),
                  isTrue,
                  reason: reason,
                );
                await _next(tester);
              }
              expect(_overlay, findsNothing);
              await unmountReward(tester, state);
            }, _server(sent));
          }
        });
      }
    }
  });
}
