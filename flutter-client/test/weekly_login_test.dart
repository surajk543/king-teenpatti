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
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/level_accent.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
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

Finder get _overlay => find.byKey(const ValueKey('reward-offer-overlay'));
Finder get _panel => find.byKey(const ValueKey('reward-offer-panel'));
Finder get _collect => find.byKey(const ValueKey('reward-offer-collect'));
Finder get _done => find.byKey(const ValueKey('reward-offer-done'));
Finder get _close => find.byKey(const ValueKey('reward-offer-close'));
Finder _box(int day) => find.byKey(ValueKey('weekly-box-$day'));
Finder get _headline => find.byKey(const ValueKey('reward-offer-headline'));
Finder get _position => find.byKey(const ValueKey('reward-offer-position'));

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

/// The lobby's menu with a Seen, a Blind and a Variation table, so a level
/// can be opened under the popup.
GameConfig _threeTables() => GameConfig.fromJson({
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
});

/// The popup's glass panel, its solid base by day, and its ambient light.
PremiumGlassPanel _glass(WidgetTester tester) => tester.widget(
  find.ancestor(of: _panel, matching: find.byType(PremiumGlassPanel)).first,
);

Color? _base(WidgetTester tester) =>
    (tester
                .widget<DecoratedBox>(
                  find.byKey(const ValueKey('reward-offer-base')),
                )
                .decoration
            as BoxDecoration)
        .color;

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

    test('the delegates hide the solid, the sparkles and the ground, restyle '
        'the card, and paint every box in its day\'s colour', () {
      final program = RewardProgramState.fromJson(
        streakJson(claimedToday: false),
      );
      for (final b in Brightness.values) {
        final values = WeeklyCalendar.delegates(b, program).values!;
        final paths = values.map((v) => v.keyPath.join('/')).toList();
        for (final hidden in const [
          WeeklyCalendarGeometry.solidLayer,
          WeeklyCalendarGeometry.sparklesLayer,
          WeeklyCalendarGeometry.groundLayer,
        ]) {
          expect(paths, contains(hidden), reason: '${b.name} $hidden');
        }
        // The card: its outline and rings (a colour and a width each), its
        // holes, its header band and its body.
        const card = WeeklyCalendarGeometry.cardLayer;
        for (final group in [
          ...WeeklyCalendarGeometry.outlineGroups,
          ...WeeklyCalendarGeometry.ringGroups,
        ]) {
          expect(
            paths.where((p) => p == '$card/$group/**').length,
            2,
            reason: '${b.name} $group',
          );
        }
        for (final group in [
          ...WeeklyCalendarGeometry.holeGroups,
          WeeklyCalendarGeometry.headerGroup,
          WeeklyCalendarGeometry.bodyGroup,
        ]) {
          expect(
            paths,
            contains('$card/$group/**'),
            reason: '${b.name} $group',
          );
        }
        // Every box, in its day's colour: Days 1 and 2 collected (gold),
        // Day 3 today's (gold), Day 4 next (cyan glass), Day 5 beyond
        // (dark glass), Day 7 the week's own.
        final colours = WeeklyCardColours.of(b);
        Color boxOf(int day) =>
            values
                    .firstWhere(
                      (v) =>
                          v.keyPath.first ==
                          WeeklyCalendarGeometry.boxLayers[day - 1],
                    )
                    .value!
                as Color;
        expect(boxOf(1), AppTheme.gold, reason: b.name);
        expect(boxOf(2), AppTheme.gold, reason: b.name);
        expect(boxOf(3), AppTheme.gold, reason: b.name);
        expect(boxOf(4), colours.upcoming, reason: b.name);
        expect(boxOf(5), colours.lockedBox, reason: b.name);
        expect(boxOf(6), colours.lockedBox, reason: b.name);
        expect(boxOf(7), colours.finalBox, reason: b.name);
      }
      // The states themselves.
      expect(weeklyDayStateOf(program, 1), WeeklyDayState.claimed);
      expect(weeklyDayStateOf(program, 3), WeeklyDayState.current);
      expect(weeklyDayStateOf(program, 4), WeeklyDayState.next);
      expect(weeklyDayStateOf(program, 6), WeeklyDayState.locked);
      expect(weeklyDayStateOf(program, 7), WeeklyDayState.finalDay);
      expect(
        weeklyDayStateOf(program, 3, collected: 3),
        WeeklyDayState.claimed,
      );
      final week = RewardProgramState.fromJson(
        streakJson(day: 7, claimedToday: true),
      );
      expect(weeklyDayStateOf(week, 7), WeeklyDayState.claimed);
    });

    test('inside a Blind or Variation level the card\'s glass takes the '
        'level\'s hue at its own lightness, and the boxes keep their days\' '
        'colours', () {
      final program = RewardProgramState.fromJson(
        streakJson(claimedToday: false),
      );
      for (final b in Brightness.values) {
        final house = WeeklyCardColours.of(b);
        for (final category in const ['blind', 'variation']) {
          final palette = AppTheme.paletteFor(
            _scheme(b),
            category: category,
            bootAmount: 200,
          );
          final level = LevelColours(palette, b);
          final colours = WeeklyCardColours.of(b, level);
          for (final (mine, theirs) in [
            (colours.body, house.body),
            (colours.header, house.header),
            (colours.outline, house.outline),
            (colours.ring, house.ring),
          ]) {
            expect(
              _hueGap(_hue(mine), _hue(palette.accent)),
              lessThan(8),
              reason: '${b.name} $category $mine',
            );
            expect(
              HSLColor.fromColor(mine).lightness,
              closeTo(HSLColor.fromColor(theirs).lightness, 0.02),
              reason: '${b.name} $category $mine',
            );
          }
          expect(colours.upcoming, house.upcoming);
          expect(colours.lockedBox, house.lockedBox);
          expect(colours.finalBox, house.finalBox);
          // The delegates carry the same: the body in the hue, the boxes as
          // at the front.
          final values = WeeklyCalendar.delegates(
            b,
            program,
            level: level,
          ).values!;
          Color valueOf(bool Function(ValueDelegate) where) =>
              values.firstWhere(where).value! as Color;
          expect(
            valueOf(
              (v) =>
                  v.keyPath.length > 1 &&
                  v.keyPath[1] == WeeklyCalendarGeometry.bodyGroup,
            ),
            colours.body,
          );
          expect(
            valueOf(
              (v) => v.keyPath.first == WeeklyCalendarGeometry.boxLayers[0],
            ),
            AppTheme.gold,
          );
          expect(
            valueOf(
              (v) => v.keyPath.first == WeeklyCalendarGeometry.boxLayers[4],
            ),
            house.lockedBox,
          );
        }
        // No level: the house set, untouched.
        expect(WeeklyCardColours.of(b, null).body, house.body);
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
      expect(scaleOf(1), lessThan(0.01));
      expect(scaleOf(7), lessThan(0.01));
      // The boxes are in by two seconds; no prize has landed yet.
      await tester.pump(const Duration(milliseconds: 2100));
      expect(scaleOf(1), lessThan(0.01));
      expect(scaleOf(7), lessThan(0.01));
      // Then the prizes, one after another: Day 1's before Day 7's. (The
      // prizes' clock starts on the frame after the boxes' clock is done.)
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(WeeklyCalendar.revealStagger * 2);
      expect(scaleOf(1), greaterThan(0.3));
      expect(scaleOf(7), lessThan(0.01));
      await tester.pump(const Duration(seconds: 2));
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
        expect((overlay.top - box.top).abs(), lessThan(0.5), reason: '$day');
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
      final lottie = tester.widget<Lottie>(
        find.descendant(
          of: find.byType(WeeklyCalendar),
          matching: find.byType(Lottie),
        ),
      );
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
    testWidgets('waits behind "Before you play" and pops, from the start of '
        'its animation, when the player confirms', (tester) async {
      await setRewardView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final state = rewardState(consented: false);
        await _pumpDue(tester, state);
        // Read, due, and yet not up: the panel covers the lobby.
        expect(state.rewardOffersDue, isNotEmpty);
        expect(state.rewardOffer, isNull);
        expect(_overlay, findsNothing);
        await state.acceptConsent();
        await tester.pump();
        expect(_overlay, findsOneWidget);
        // From the start: no box has popped, no prize has landed.
        final lottie = tester.widget<Lottie>(
          find.descendant(
            of: find.byType(WeeklyCalendar),
            matching: find.byType(Lottie),
          ),
        );
        expect(lottie.controller!.value, lessThan(0.05));
        await tester.pump(WeeklyCalendar.sequenceLength);
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          lottie.controller!.value,
          closeTo(
            WeeklyCalendarGeometry.holdFrame / WeeklyCalendarGeometry.frames,
            0.001,
          ),
        );
        await unmountReward(tester, state);
      }, () => fakeRewards(sent: sent, programs: _due()));
    });

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
        expect(state.rewardOffer?.program.code, 'WEEKLY_LOGIN');
        final t = state.t;
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('reward-offer-headline')))
              .data,
          t.streakDays(2).toUpperCase(),
        );
        final prize = rewardPrizeLabel(
          t,
          RewardPrize.fromJson(dayJson(3, 'CHIPS', value: 20000)),
        );
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('reward-offer-today')))
              .data,
          prize.toUpperCase(),
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
        expect(state.rewardOffer, isNull);
        await unmountReward(tester, state);
      }, () => fakeRewards(sent: quiet, programs: _collected()));
    });

    testWidgets('the prize\'s figure is the largest type on a day card, '
        'sized from the box, and drawn whole', (tester) async {
      await setRewardView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final state = rewardState();
        await _pumpDue(tester, state);
        // Every prize landed.
        await tester.pump(const Duration(seconds: 2));
        for (final day in const [1, 3, 5, 7]) {
          final box = tester.getRect(_box(day));
          final figure = find.byKey(ValueKey('weekly-figure-$day'));
          final style = tester.widget<Text>(figure).style!;
          expect(
            style.fontSize,
            closeTo((box.width * 0.235).clamp(11.0, 19.0), 0.01),
            reason: 'day $day',
          );
          // Larger than the day's label and than the 9.5 it was.
          final label = tester
              .widgetList<Text>(
                find.descendant(of: _box(day), matching: find.byType(Text)),
              )
              .first
              .style!
              .fontSize!;
          expect(style.fontSize, greaterThan(label), reason: 'day $day');
          expect(style.fontSize, greaterThan(9.5), reason: 'day $day');
          // Set down whole at the phone's own text size: the column fits
          // the box, so the figure is drawn at its size, not scaled away.
          final drawn = tester.getRect(figure);
          expect(
            drawn.height,
            greaterThanOrEqualTo(style.fontSize! * 1.15 * 0.85),
            reason: 'day $day $drawn',
          );
          expect(box.contains(drawn.topLeft), isTrue, reason: 'day $day');
          expect(
            box.contains(drawn.bottomRight - const Offset(1, 1)),
            isTrue,
            reason: 'day $day $drawn in $box',
          );
        }
        await unmountReward(tester, state);
      }, () => fakeRewards(sent: sent, programs: _due()));
    });

    for (final b in Brightness.values) {
      testWidgets('inside Blind and Variation the popup takes the level\'s '
          'colour, and the house gold at the front and inside Seen '
          '(${b.name})', (tester) async {
        await setRewardView(tester);
        final sent = <http.Request>[];
        await http.runWithClient(() async {
          final state = rewardState()..config = _threeTables();
          final feedback = FeedbackSettings();
          addTearDown(feedback.dispose);
          await tester.pumpWidget(
            rewardApp(state, feedback, const LobbyScreen(), brightness: b),
          );
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          await tester.pump(const Duration(seconds: 3));
          expect(_overlay, findsOneWidget);
          final dark = b == Brightness.dark;
          final scheme = _scheme(b);

          void expectHouse(String where) {
            final glass = _glass(tester);
            expect(glass.tint, dark ? isNull : AppTheme.gold, reason: where);
            expect(
              glass.edge,
              AppTheme.gold.withValues(alpha: dark ? 0.3 : 0.42),
              reason: where,
            );
            expect(
              _base(tester),
              dark ? isNull : AppTheme.panelBase(b),
              reason: where,
            );
          }

          Future<void> expectLevel(String category) async {
            state.openLobbyCategory(category);
            await tester.pump();
            await tester.pump(const Duration(seconds: 1));
            expect(state.lobbyCategory, category);
            final palette = AppTheme.paletteFor(
              scheme,
              category: category,
              bootAmount: 200,
            );
            final level = LevelColours(palette, b);
            final glass = _glass(tester);
            expect(glass.tint, palette.accent, reason: category);
            expect(
              glass.edge,
              palette.accent.withValues(alpha: dark ? 0.3 : 0.42),
              reason: category,
            );
            // By day a solid ground in the level's hue under the glass.
            expect(
              _base(tester),
              dark ? isNull : level.pearl,
              reason: category,
            );
            if (!dark) {
              expect(
                _hueGap(_hue(_base(tester)!), _hue(palette.accent)),
                lessThan(8),
                reason: category,
              );
            }
            // The calendar's glass in the hue too.
            final lottie = tester.widget<Lottie>(
              find.descendant(
                of: find.byType(WeeklyCalendar),
                matching: find.byType(Lottie),
              ),
            );
            final body =
                lottie.delegates!.values!
                        .firstWhere(
                          (v) =>
                              v.keyPath.length > 1 &&
                              v.keyPath[1] == WeeklyCalendarGeometry.bodyGroup,
                        )
                        .value!
                    as Color;
            expect(body, WeeklyCardColours.of(b, level).body, reason: category);
          }

          expectHouse('the front');
          await expectLevel('blind');
          await expectLevel('variation');
          // Seen is the gold's own; the front again is too.
          state.openLobbyCategory('seen');
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          expectHouse('seen');
          while (state.closeLobbyLevel()) {
            await tester.pump();
          }
          await tester.pump(const Duration(seconds: 1));
          expect(state.lobbyCategory, isNull);
          expectHouse('the front again');
          expect(tester.takeException(), isNull);
          await unmountReward(tester, state);
        }, () => fakeRewards(sent: sent, programs: _due()));
      });
    }

    testWidgets('one popup a program: Collect claims its program alone and '
        'shows what it gave, and Continue brings the next program\'s own '
        'popup — "2 of 2", its own look — which collects its own; nothing is '
        'celebrated twice', (tester) async {
      await setRewardView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final state = rewardState();
        await _pumpDue(tester, state);
        final t = state.t;
        final scheme = Theme.of(tester.element(_panel)).colorScheme;
        // The weekly login streak first: the owner's calendar, "1 of 2".
        expect(state.rewardOffer?.program.code, 'WEEKLY_LOGIN');
        expect(find.byKey(const ValueKey('weekly-calendar')), findsOneWidget);
        expect(find.byKey(const ValueKey('reward-offer-stage')), findsNothing);
        expect(
          tester.widget<Text>(_position).data,
          t.rewardOfferPosition(1, 2).toUpperCase(),
        );
        await tester.tap(_collect);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(seconds: 1));
        // The claim named this program, and gave its chips alone.
        expect(claimedPrograms(sent), ['WEEKLY_LOGIN']);
        expect(tester.takeException(), isNull);
        final collected = tester
            .widget<Text>(find.byKey(const ValueKey('reward-offer-collected')))
            .data!;
        expect(collected, contains('20,000'));
        expect(collected, isNot(contains('CLAPPING HANDS')));
        expect(collected, isNot(contains(t.rewardsAlso('').trim())));
        expect(_collect, findsNothing);
        expect(_done, findsOneWidget);
        expect(
          tester.widget<Text>(_headline).data,
          t.streakDays(3).toUpperCase(),
        );
        expect(state.user?.chips, 1020000);
        expect(state.rewardsGranted, isNull);
        expect(find.byKey(const ValueKey('rewards-celebration')), findsNothing);

        // Continue: the calendar's own popup — its days as its panel draws
        // them, sapphire, "DAY 10 REWARD", "2 of 2" — with nothing claimed.
        await tester.tap(_done);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(state.rewardOffer?.program.code, 'MONTHLY_CALENDAR');
        expect(
          find.byKey(const ValueKey('reward-offer-MONTHLY_CALENDAR')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('weekly-calendar')), findsNothing);
        final stage = find.byKey(const ValueKey('reward-offer-stage'));
        expect(stage, findsOneWidget);
        expect(
          find.descendant(
            of: stage,
            matching: find.byKey(
              const ValueKey('reward-day-MONTHLY_CALENDAR-10'),
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: stage,
            matching: find.byIcon(Icons.calendar_month_rounded),
          ),
          findsOneWidget,
        );
        expect(
          tester.widget<Text>(_headline).data,
          t.calendarDayReward(10).toUpperCase(),
        );
        expect(
          tester.widget<Text>(_headline).style?.color,
          AppTheme.paletteFor(scheme, category: 'blind', bootAmount: 0).ink,
        );
        expect(
          tester.widget<Text>(_position).data,
          t.rewardOfferPosition(2, 2).toUpperCase(),
        );
        expect(_collect, findsOneWidget);
        expect(claimedPrograms(sent), ['WEEKLY_LOGIN']);
        // Today's page collects it, as the key would: this program alone.
        await tester.tap(
          find.byKey(const ValueKey('reward-collect-MONTHLY_CALENDAR-10')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(seconds: 1));
        expect(claimedPrograms(sent), ['WEEKLY_LOGIN', 'MONTHLY_CALENDAR']);
        expect(
          tester
              .widget<Text>(
                find.byKey(const ValueKey('reward-offer-collected')),
              )
              .data,
          contains('CLAPPING HANDS'),
        );
        expect(state.rewardsGranted, isNull);
        await tester.tap(_done);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(_overlay, findsNothing);
        expect(state.rewardOffer, isNull);
        // The chip says the streak: nothing is due any more.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('rewards-chip')),
            matching: find.text(t.streakDays(3)),
          ),
          findsOneWidget,
        );
        await unmountReward(tester, state);
      }, fakeNamedClaims(sent: sent));
    });

    testWidgets('an older server\'s claim collects every program whichever is '
        'named: the popup says what the others gave too, and no popup follows '
        'for a program already collected', (tester) async {
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
        expect(claimedPrograms(sent), ['WEEKLY_LOGIN']);
        final collected = tester
            .widget<Text>(find.byKey(const ValueKey('reward-offer-collected')))
            .data!;
        expect(collected, contains('20,000'));
        expect(collected, contains('Clapping Hands'));
        expect(collected, contains(t.rewardsAlso('').trim()));
        await tester.tap(_done);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(_overlay, findsNothing);
        expect(state.rewardOffer, isNull);
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
          expect(state.rewardOffer?.program.code, 'WEEKLY_LOGIN');
          // Put away, the next program's popup comes up; put away too,
          // none.
          await tester.tap(_close);
          await tester.pump();
          expect(state.rewardOffer?.program.code, 'MONTHLY_CALENDAR');
          expect(_overlay, findsOneWidget);
          await tester.tap(_close);
          await tester.pump();
          expect(_overlay, findsNothing);
          // Read again (a session:ready): the same days, still unclaimed,
          // are not put up again.
          await state.loadRewardPrograms();
          await tester.pump();
          expect(_overlay, findsNothing);
          expect(state.rewardOffersDue, hasLength(2));
          // The chip brings them back, both.
          await tester.tap(find.byKey(const ValueKey('rewards-chip')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          expect(state.rewardOffer?.program.code, 'WEEKLY_LOGIN');
          expect(find.byType(RewardProgramsScreen), findsNothing);
          await tester.tap(_close);
          await tester.pump();
          expect(state.rewardOffer?.program.code, 'MONTHLY_CALENDAR');
          await tester.tap(_close);
          await tester.pump();
          expect(_overlay, findsNothing);
          // A new day for the streak: its popup alone — the calendar's day
          // has been offered.
          today = '2026-10-08';
          await state.loadRewardPrograms();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          expect(state.rewardOffer?.program.code, 'WEEKLY_LOGIN');
          expect(state.rewardOfferCount, 1);
          expect(_position, findsNothing);
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
        // A tap on the panel is the panel's; one on the scrim puts the
        // popup away — and the next program's comes up, which a second tap
        // outside puts away too.
        await tester.tap(_panel, warnIfMissed: false);
        await tester.pump();
        expect(state.rewardOffer?.program.code, 'WEEKLY_LOGIN');
        await tester.tapAt(const Offset(4, 4));
        await tester.pump();
        expect(state.rewardOffer?.program.code, 'MONTHLY_CALENDAR');
        await tester.pump(const Duration(milliseconds: 400));
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
        // Back puts each program's popup away in turn, then nothing is
        // over the lobby.
        for (final next in ['MONTHLY_CALENDAR', null]) {
          await tester
              .state<NavigatorState>(find.byType(Navigator).first)
              .maybePop();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(state.rewardOffer?.program.code, next);
        }
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
            find.byKey(const ValueKey('reward-offer-note')),
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
          'text x1.25 in ${lang.name}, both themes, a streak running and '
          'one not yet begun, no word cut',
          (tester) async {
            await setRewardView(tester, screen: screen, textScale: 1.25);
            // Day 3 of a running streak ("2 DAY STREAK"), and Day 1 of one
            // not yet begun ("START YOUR STREAK TODAY", the widest line a
            // new player meets).
            for (final (brightness, day) in [
              for (final b in Brightness.values)
                for (final d in const [3, 1]) (b, d),
            ]) {
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
                      const LobbyScreen(),
                      brightness: brightness,
                    ),
                  );
                  await tester.pump();
                  await tester.pump(const Duration(seconds: 1));
                  await tester.pump(const Duration(seconds: 2));
                  await tester.pump(const Duration(milliseconds: 500));
                  final reason = '${lang.name} ${brightness.name} day $day';
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
                  // The streak's line whole and inside the panel.
                  final headline = find.byKey(
                    const ValueKey('reward-offer-headline'),
                  );
                  expect(
                    tester.widget<Text>(headline).data,
                    (day > 1
                            ? state.t.streakDays(day - 1)
                            : state.t.streakStart)
                        .toUpperCase(),
                    reason: reason,
                  );
                  expect(
                    tester.getRect(headline).right,
                    lessThanOrEqualTo(panel.right),
                    reason: reason,
                  );
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
                          calendar.contains(
                            box.bottomRight - const Offset(1, 1),
                          ),
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
                },
                () => fakeRewards(
                  sent: sent,
                  programs: _due(day: day),
                ),
              );
            }
          },
        );
      }
    }
  });
}
