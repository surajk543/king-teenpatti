// The weekly login popup (owner, 30 Sep 2026: "Use this animation which
// shows up everyday in case of weekly login and put the prize in blue boxes,
// it should pop after login and if user has claimed it should not show when
// user start the app, otherwise show it").
//
// These hold the owner's file to what the widget assumes of it (the canvas,
// seven boxes where its layers put them, popping when they do, no 3D,
// expressions or images, the white solid), the calendar to laying each
// prize over its box and popping it with the box, and the popup to: up in
// the lobby after sign-in while today's day is still to collect and not when
// it is collected; Collect claiming, showing what was given and Close
// putting it away, with nothing celebrated twice; a day put away not offered
// again in the session, brought back by the REWARDS chip, and a new day
// offered; a tap outside and Back closing it; a failed claim said and the
// key kept; and every word whole at 640x360 and 592x360 x1.25 in all five
// languages, both themes.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/main.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/screens/reward_programs_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/widgets/weekly_login.dart';

import 'reward_fixtures.dart';

List<String> _posts(List<http.Request> sent) => [
  for (final r in sent)
    if (r.method == 'POST') r.url.path,
];

/// The programs with the weekly streak's third day still to collect.
Map<String, Object?> _due({String today = wednesday, int day = 3}) => {
  'programs': [
    streakJson(day: day, claimedToday: false, today: today),
    calendarJson(),
  ],
};

/// The programs with everything collected.
Map<String, Object?> _collected() => {
  'programs': [streakJson(), calendarJson(claimedToday: true)],
};

/// The claim's answer to the third day: its chips and the calendar's emoji.
Map<String, Object?> _claimed() => claimJson(
  granted: twoGrants(),
  programs: [streakJson(), calendarJson(claimedToday: true)],
  chips: 1020000,
);

Finder get _overlay => find.byKey(const ValueKey('weekly-login-overlay'));
Finder get _panel => find.byKey(const ValueKey('weekly-login-panel'));
Finder get _collect => find.byKey(const ValueKey('weekly-login-collect'));
Finder get _done => find.byKey(const ValueKey('weekly-login-done'));
Finder get _close => find.byKey(const ValueKey('weekly-login-close'));
Finder _box(int day) => find.byKey(ValueKey('weekly-box-$day'));

/// The lobby pumped and its read answered, the popup's entrance and the
/// calendar's pop-in over.
Future<void> _pumpDue(WidgetTester tester, GameState state) async {
  await pumpRewardLobby(tester, state);
  await tester.pump(const Duration(seconds: 2));
  await tester.pump(const Duration(milliseconds: 500));
}

/// A layer of the file by name.
Map<String, dynamic> _layer(Map<String, dynamic> file, String name) =>
    (file['layers'] as List).cast<Map<String, dynamic>>().firstWhere(
      (l) => l['nm'] == name,
    );

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadRewardFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the file', () {
    test('is what the calendar assumes: the canvas, seven boxes where its '
        'layers put them, popping when they do, the white solid, and nothing '
        'a phone cannot play', () {
      final file =
          jsonDecode(File(WeeklyCalendarGeometry.asset).readAsStringSync())
              as Map<String, dynamic>;
      expect(file['w'], WeeklyCalendarGeometry.canvas.width);
      expect(file['h'], WeeklyCalendarGeometry.canvas.height);
      expect(file['fr'], WeeklyCalendarGeometry.frameRate);
      expect(file['op'], WeeklyCalendarGeometry.frames);
      expect(file['ddd'] ?? 0, 0);
      // No expressions (a property's "x" as a string), no images.
      expect(jsonEncode(file).contains('"x":"'), isFalse);
      for (final asset in (file['assets'] as List).cast<Map>()) {
        expect(asset.containsKey('p'), isFalse, reason: 'an image');
      }
      final solid = _layer(file, WeeklyCalendarGeometry.solidLayer);
      expect(solid['ty'], 1);
      expect(solid['sw'], 600);
      expect(solid['sh'], 250);

      for (var day = 1; day <= 7; day++) {
        final layer = _layer(file, WeeklyCalendarGeometry.boxLayers[day - 1]);
        final ks = layer['ks'] as Map<String, dynamic>;
        final a = (ks['a']['k'] as List).cast<num>();
        final p = (ks['p']['k'] as List).cast<num>();
        final group = (layer['shapes'] as List).first as Map<String, dynamic>;
        final items = (group['it'] as List).cast<Map<String, dynamic>>();
        final tr = items.firstWhere((i) => i['ty'] == 'tr');
        final gp = (tr['p']['k'] as List).cast<num>();
        final path = items.firstWhere((i) => i['ty'] == 'sh');
        final vertices = (path['ks']['k']['v'] as List)
            .cast<List>()
            .map((v) => v.cast<num>())
            .toList();
        // The box's centre: its group's position carried through the layer
        // (the layer rests at 100%), and its half-side the path's reach.
        final centre = Offset(
          (gp[0] - a[0] + p[0]).toDouble(),
          (gp[1] - a[1] + p[1]).toDouble(),
        );
        final want = WeeklyCalendarGeometry.boxCentres[day - 1];
        expect((centre - want).distance, lessThan(0.01), reason: 'day $day');
        final reach = vertices
            .map((v) => v[0].abs().toDouble())
            .reduce((x, y) => x > y ? x : y);
        expect(
          (reach - WeeklyCalendarGeometry.boxSide / 2).abs(),
          lessThan(0.01),
          reason: 'day $day',
        );
        // Its pop: from the first scale keyframe to the first at 100%
        // after the overshoot.
        final scale = (ks['s']['k'] as List).cast<Map<String, dynamic>>();
        final start = scale.first['t'] as num;
        final rest =
            scale.skip(1).firstWhere((k) => (k['s'] as List).first == 100)['t']
                as num;
        expect(
          (start.toInt(), rest.toInt()),
          WeeklyCalendarGeometry.boxPops[day - 1],
          reason: 'day $day',
        );
        // At rest by the held frame, and still there.
        expect(rest, lessThanOrEqualTo(WeeklyCalendarGeometry.holdFrame));
        final leaves =
            scale.firstWhere(
                  (k) =>
                      (k['t'] as num) > rest && (k['s'] as List).first != 100,
                )['t']
                as num;
        expect(leaves, greaterThan(WeeklyCalendarGeometry.holdFrame));
      }
      // The window inside the canvas, and every box inside the window.
      final window = WeeklyCalendarGeometry.window;
      expect(
        (Offset.zero & WeeklyCalendarGeometry.canvas).contains(window.topLeft),
        isTrue,
      );
      for (var day = 1; day <= 7; day++) {
        final box = WeeklyCalendarGeometry.boxOf(day);
        expect(window.contains(box.topLeft), isTrue, reason: 'day $day');
        expect(window.contains(box.bottomRight), isTrue, reason: 'day $day');
      }
    });

    test('the delegates hide the solid, paint every box the one blue, and '
        'by night the ground in charcoal', () {
      for (final b in Brightness.values) {
        final values = WeeklyCalendar.delegates(b).values!;
        expect(values.length, b == Brightness.dark ? 9 : 8, reason: b.name);
        expect(values.first.keyPath, [WeeklyCalendarGeometry.solidLayer]);
        for (var day = 1; day <= 7; day++) {
          expect(
            values[day].keyPath.first,
            WeeklyCalendarGeometry.boxLayers[day - 1],
          );
        }
        if (b == Brightness.dark) {
          expect(values.last.keyPath.first, WeeklyCalendarGeometry.groundLayer);
        }
      }
    });
  });

  group('the calendar', () {
    testWidgets('lays each prize over its box, popping with it, and plays '
        'the file once to its held frame', (tester) async {
      await setRewardView(tester);
      final state = rewardState();
      final feedback = FeedbackSettings();
      addTearDown(feedback.dispose);
      final program = RewardProgramState.fromJson(
        streakJson(claimedToday: false),
      );
      final size = WeeklyCalendar.sizeFor(510);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        rewardApp(
          state,
          feedback,
          Scaffold(
            body: Center(
              child: WeeklyCalendar(
                key: const ValueKey('cal'),
                state: program,
                size: size,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final origin = tester.getTopLeft(find.byKey(const ValueKey('cal')));
      final t = state.t;
      // Before any box has popped, Day 7's prize is at nothing.
      double scaleOf(int day) => tester
          .widget<Transform>(
            find
                .descendant(of: _box(day), matching: find.byType(Transform))
                .first,
          )
          .transform
          .entry(0, 0);
      expect(scaleOf(7), lessThan(0.01));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));
      for (var day = 1; day <= 7; day++) {
        final overlay = tester.getRect(_box(day));
        final box = WeeklyCalendar.boxRectIn(size, day).shift(origin);
        expect((overlay.left - box.left).abs(), lessThan(0.5), reason: '$day');
        expect(
          (overlay.right - box.right).abs(),
          lessThan(0.5),
          reason: '$day',
        );
        expect(
          (overlay.bottom - box.bottom).abs(),
          lessThan(0.5),
          reason: '$day',
        );
        expect(overlay.top, lessThan(box.top), reason: '$day');
        expect((scaleOf(day) - 1).abs(), lessThan(0.01), reason: '$day');
      }
      // What a screen reader hears: Day 1 collected, Day 3 today's, Day 4
      // not reached, each with its prize.
      String heard(int day) => tester.getSemantics(_box(day)).label;
      expect(heard(1), contains(t.rewardDay(1)));
      expect(heard(1), contains('10,000'));
      expect(heard(1), contains(t.rewardTileClaimed));
      expect(heard(3), contains(t.rewardToday));
      expect(heard(3), contains('20,000'));
      expect(heard(4), contains(t.rewardTileLocked));
      // The file's clock, held where every box is in and still.
      final lottie = tester.widget<Lottie>(find.byType(Lottie));
      expect(
        lottie.controller!.value,
        closeTo(
          WeeklyCalendarGeometry.holdFrame / WeeklyCalendarGeometry.frames,
          0.001,
        ),
      );
      handle.dispose();
      await unmountReward(tester, state);
    });
  });

  group('the popup', () {
    testWidgets('pops after sign-in while today is still to collect, with '
        'the week\'s prizes in its boxes, and not when it is collected', (
      tester,
    ) async {
      await setRewardView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final state = rewardState();
        await _pumpDue(tester, state);
        expect(tester.takeException(), isNull);
        expect(_overlay, findsOneWidget);
        expect(state.weeklyLoginOffer?.program.code, 'WEEKLY_LOGIN');
        final t = state.t;
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('weekly-login-headline')))
              .data,
          t.streakDays(2),
        );
        final prize = rewardPrizeLabel(
          t,
          RewardPrize.fromJson(dayJson(3, 'CHIPS', value: 20000)),
        );
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('weekly-login-today')))
              .data,
          t.todaysReward(prize),
        );
        for (var day = 1; day <= 7; day++) {
          expect(_box(day), findsOneWidget, reason: 'day $day');
        }
        expect(_collect, findsOneWidget);
        expect(_done, findsNothing);
        // Nothing claimed by itself.
        expect(_posts(sent), isEmpty);
        await unmountReward(tester, state);
      }, () => fakeRewards(sent: sent, programs: _due()));
      final quiet = <http.Request>[];
      await http.runWithClient(() async {
        final state = rewardState();
        await _pumpDue(tester, state);
        expect(_overlay, findsNothing);
        expect(state.weeklyLoginOffer, isNull);
        await unmountReward(tester, state);
      }, () => fakeRewards(sent: quiet, programs: _collected()));
    });

    testWidgets('Collect claims, shows what was given — the other programs\' '
        'too — and Close puts it away; nothing is celebrated twice', (
      tester,
    ) async {
      await setRewardView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final state = rewardState();
        await _pumpDue(tester, state);
        final t = state.t;
        await tester.tap(_collect);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(seconds: 1));
        expect(_posts(sent), ['/api/reward-programs/claim']);
        expect(tester.takeException(), isNull);
        // What was given, on the popup: the day's chips, and the
        // calendar's emoji beside it.
        final collected = tester
            .widget<Text>(find.byKey(const ValueKey('weekly-login-collected')))
            .data!;
        expect(collected, contains('20,000'));
        expect(collected, contains('Clapping Hands'));
        expect(collected, contains(t.rewardsAlso('').trim()));
        expect(_collect, findsNothing);
        expect(_done, findsOneWidget);
        // The streak is three now, the wallet took the chips, the third
        // box is collected, and the lobby's celebration stays down.
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('weekly-login-headline')))
              .data,
          t.streakDays(3),
        );
        expect(state.user?.chips, 1020000);
        expect(state.rewardsGranted, isNull);
        expect(find.byKey(const ValueKey('rewards-celebration')), findsNothing);
        expect(state.weeklyLoginOffer, isNotNull);
        await tester.tap(_done);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(_overlay, findsNothing);
        expect(state.weeklyLoginOffer, isNull);
        // The chip says the streak: nothing is due any more.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('rewards-chip')),
            matching: find.text(t.streakDays(3)),
          ),
          findsOneWidget,
        );
        await unmountReward(tester, state);
      }, () => fakeRewards(sent: sent, programs: _due(), claim: _claimed()));
    });

    testWidgets('a day put away is not offered again in the session, the '
        'REWARDS chip brings it back, and a new day is offered', (
      tester,
    ) async {
      await setRewardView(tester);
      final sent = <http.Request>[];
      var today = wednesday;
      await http.runWithClient(
        () async {
          final state = rewardState();
          await _pumpDue(tester, state);
          expect(_overlay, findsOneWidget);
          await tester.tap(_close);
          await tester.pump();
          expect(_overlay, findsNothing);
          // Read again (a session:ready): the same day, still unclaimed,
          // is not put up again.
          await state.loadRewardPrograms();
          await tester.pump();
          expect(_overlay, findsNothing);
          expect(state.weeklyLoginDue, isNotNull);
          // The chip brings it back.
          await tester.tap(find.byKey(const ValueKey('rewards-chip')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          expect(_overlay, findsOneWidget);
          expect(find.byType(RewardProgramsScreen), findsNothing);
          await tester.tap(_close);
          await tester.pump();
          // A new day: offered.
          today = '2026-10-08';
          await state.loadRewardPrograms();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          expect(_overlay, findsOneWidget);
          await unmountReward(tester, state);
        },
        // Answered per request: the day turns while the lobby is up.
        () => MockClient((request) async {
          sent.add(request);
          if (request.url.path == '/api/reward-programs') {
            return rewardJson(
              _due(today: today, day: today == wednesday ? 3 : 4),
            );
          }
          return rewardJson({'error': 'not_found'}, 404);
        }),
      );
    });

    testWidgets('a tap outside closes it, and so does Back', (tester) async {
      await setRewardView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final state = rewardState();
        await _pumpDue(tester, state);
        expect(_overlay, findsOneWidget);
        // A tap on the panel is the panel's; one on the scrim closes.
        await tester.tap(_panel, warnIfMissed: false);
        await tester.pump();
        expect(_overlay, findsOneWidget);
        await tester.tapAt(const Offset(4, 4));
        await tester.pump();
        expect(_overlay, findsNothing);
        await unmountReward(tester, state);
      }, () => fakeRewards(sent: sent, programs: _due()));

      // Back, in the app as main.dart builds it.
      SharedPreferences.setMockInitialValues({
        'soundOn': false,
        'vibrateOn': false,
      });
      final quiet = <http.Request>[];
      await http.runWithClient(() async {
        final state = rewardState();
        final feedback = FeedbackSettings();
        await feedback.load();
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
        await tester.pump(const Duration(seconds: 2));
        expect(find.byType(LobbyScreen), findsOneWidget);
        expect(_overlay, findsOneWidget);
        await tester
            .state<NavigatorState>(find.byType(Navigator).first)
            .maybePop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(_overlay, findsNothing);
        expect(find.byType(LobbyScreen), findsOneWidget);
        await unmountReward(tester, state);
      }, () => fakeRewards(sent: quiet, programs: _due()));
    });

    testWidgets('a claim that fails says so and keeps the key', (tester) async {
      await setRewardView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState();
          await _pumpDue(tester, state);
          await tester.tap(_collect);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          expect(_posts(sent), ['/api/reward-programs/claim']);
          expect(
            find.byKey(const ValueKey('weekly-login-note')),
            findsOneWidget,
          );
          expect(_collect, findsOneWidget);
          expect(_done, findsNothing);
          expect(_overlay, findsOneWidget);
          await unmountReward(tester, state);
        },
        () => fakeRewards(
          sent: sent,
          programs: _due(),
          claimResponse: http.Response(
            jsonEncode({'error': 'internal_error', 'message': 'no'}),
            500,
          ),
        ),
      );
    });

    for (final screen in const [Size(640, 360), Size(592, 360)]) {
      for (final lang in AppLang.values) {
        testWidgets(
          'fits a ${screen.width.toInt()}x${screen.height.toInt()} phone at '
          'text x1.25 in ${lang.name}, both themes, no word cut',
          (tester) async {
            await setRewardView(tester, screen: screen, textScale: 1.25);
            for (final brightness in Brightness.values) {
              final sent = <http.Request>[];
              await http.runWithClient(() async {
                final state = rewardState(lang: lang);
                final feedback = FeedbackSettings();
                addTearDown(feedback.dispose);
                await tester.pumpWidget(
                  rewardApp(
                    state,
                    feedback,
                    const LobbyScreen(),
                    brightness: brightness,
                  ),
                );
                await tester.pump();
                await tester.pump(const Duration(seconds: 1));
                await tester.pump(const Duration(seconds: 2));
                await tester.pump(const Duration(milliseconds: 500));
                final reason = '${lang.name} ${brightness.name}';
                expect(tester.takeException(), isNull, reason: reason);
                expect(_overlay, findsOneWidget, reason: reason);
                final view = Offset.zero & screen;
                final panel = tester.getRect(_panel);
                expect(view.contains(panel.topLeft), isTrue, reason: reason);
                expect(
                  view.contains(panel.bottomRight - const Offset(1, 1)),
                  isTrue,
                  reason: '$reason $panel',
                );
                expectRewardWhole(tester, _panel, reason);
                // Every box inside the calendar, the calendar inside the
                // panel.
                final calendar = tester.getRect(
                  find.byKey(const ValueKey('weekly-calendar')),
                );
                expect(panel.contains(calendar.topLeft), isTrue);
                expect(
                  panel.contains(calendar.bottomRight - const Offset(1, 1)),
                  isTrue,
                );
                for (var day = 1; day <= 7; day++) {
                  final box = tester.getRect(_box(day));
                  expect(
                    calendar.contains(box.topLeft) &&
                        calendar.contains(box.bottomRight - const Offset(1, 1)),
                    isTrue,
                    reason: '$reason day $day $box in $calendar',
                  );
                }
                // The key, whole and reachable.
                expect(_collect, findsOneWidget, reason: reason);
                expect(
                  view.contains(tester.getRect(_collect).bottomRight),
                  isTrue,
                  reason: reason,
                );
                await unmountReward(tester, state);
              }, () => fakeRewards(sent: sent, programs: _due()));
            }
          },
        );
      }
    }
  });
}
