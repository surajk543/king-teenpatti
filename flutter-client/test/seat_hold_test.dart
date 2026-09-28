// A seat holds still whatever its column holds (29 Sep 2026, the third
// review of the emoji placement). A rim seat is placed by its column's
// middle, and its column grew a row of cards at the deal of a table whose
// seats held none and gave its bet badge up for a status line at every
// hand's end: its pod moved 14 to 36dp, and every emoji playing over the
// table moved with it. Now the rows under a rim seat's pod stand at their
// tallest whatever they hold — as tall as the dealt seat always was, so the
// dealt table is laid out as it was — and the pod is where it will be.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/seat_pod.dart';

import 'script_fonts.dart';
import 'table_scenes.dart';

Future<GameState> _mount(
  WidgetTester tester,
  TableScene scene, {
  Size size = const Size(640, 360),
  double textScale = 1.0,
  AppLang lang = AppLang.english,
  bool scripts = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final state = sceneState(scene, lang: lang);
  final theme = AppTheme.dark(sound: false);
  await tester.pumpWidget(
    tableApp(
      state: state,
      feedback: feedback,
      theme: scripts ? withScriptFallback(theme) : theme,
    ),
  );
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pump(const Duration(milliseconds: 900));
  return state;
}

Future<void> _unmount(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

Finder _podOf(String userId) =>
    find.byWidgetPredicate((w) => w is SeatPod && w.seat?.userId == userId);

/// A seat's plaque: its glass, inside the turn's ring when it is on turn.
Finder _plaqueOf(String userId) => find
    .descendant(of: _podOf(userId), matching: find.byType(PremiumGlassPanel))
    .first;

/// The viewer's pod box, ring and all: it stands on the floor.
Finder _viewerPod() => find
    .descendant(of: _podOf('u0'), matching: find.byType(GestureDetector))
    .first;

String _nameOf(Size size, double scale) =>
    '${size.width.toInt()}x${size.height.toInt()} x$scale';

void main() {
  setUpAll(loadScriptFonts);

  const rim = ['u1', 'u2', 'u3', 'u4'];

  // The table through a hand and into the next, the turn going round, the
  // viewer packing: every rim seat's plaque stays where it was, and the
  // viewer's pod stays on the floor.
  for (final (size, scale) in const [
    (Size(592, 360), 1.25),
    (Size(640, 360), 1.0),
    (Size(844, 390), 1.25),
    (Size(915, 412), 1.25),
    (Size(1024, 600), 1.0),
  ]) {
    testWidgets('at ${_nameOf(size, scale)}, no seat moves from a table '
        'waiting for its first deal, through the deal, the turn going round '
        'and a pack, to the next', (tester) async {
      final state = await _mount(
        tester,
        TableScene('waiting', (s) => s.handleState(waitingRoom())),
        size: size,
        textScale: scale,
      );
      Map<String, double> centres() => {
        for (final id in rim) id: tester.getRect(_plaqueOf(id)).center.dy,
      };
      final was = centres();
      final floor = tester.getRect(_viewerPod()).bottom;
      for (final (label, room) in <(String, RoomState)>[
        ('the deal', opponentTurnRoom(handNo: 1)),
        ('the viewer on turn', blindTurnRoom(handNo: 1, turnSeat: 0)),
        ('Vikramaditya on turn', blindTurnRoom(handNo: 1, turnSeat: 4)),
        ('the viewer packed', missedTurnsRoom(handNo: 1, winnerTax: false)),
        ('waiting again', waitingRoom()),
        ('the next deal', opponentTurnRoom(handNo: 2)),
      ]) {
        state.handleState(room);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 900));
        final now = centres();
        for (final id in rim) {
          expect(
            (now[id]! - was[id]!).abs(),
            lessThan(1),
            reason: '$id\'s plaque moved at $label: ${was[id]} → ${now[id]}',
          );
        }
        expect(
          (tester.getRect(_viewerPod()).bottom - floor).abs(),
          lessThan(0.5),
          reason: 'the viewer\'s pod left the floor at $label',
        );
      }
      expect(tester.takeException(), isNull);
      await _unmount(tester, state);
    });
  }

  // A poker room's street bets come and go with every street.
  for (final (size, scale) in const [
    (Size(640, 360), 1.0),
    (Size(915, 412), 1.25),
  ]) {
    testWidgets('at ${_nameOf(size, scale)}, a poker room: no seat moves '
        'when a new street takes every street bet away', (tester) async {
      final state = await _mount(
        tester,
        tableScenes.firstWhere((s) => s.name.startsWith('15-poker-holdem')),
        size: size,
        textScale: scale,
      );
      final was = {
        for (final id in rim) id: tester.getRect(_plaqueOf(id)).center.dy,
      };
      state.handleState(pokerNewStreetRoom());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      for (final id in rim) {
        expect(
          (tester.getRect(_plaqueOf(id)).center.dy - was[id]!).abs(),
          lessThan(1),
          reason: id,
        );
      }
      expect(tester.takeException(), isNull);
      await _unmount(tester, state);
    });
  }

  // The rows are held at the height the dealt seat always stood: in the
  // fonts a phone draws, a seat's bet badge over its "In Pot" line fills the
  // held row exactly where its figures fit at full size, so the dealt table
  // is laid out as it was; and in every language, at the text ceiling, what
  // the rows hold never runs past them.
  testWidgets('in Inter at 640x360 x1.0, a dealt seat\'s bet fills its held '
      'row to the foot', (tester) async {
    final state = await _mount(
      tester,
      tableScenes.firstWhere((s) => s.name.startsWith('01-opponent-turn')),
      scripts: true,
    );
    for (final id in rim) {
      final seat = tester.getRect(_podOf(id));
      final bet = tester.getRect(
        find.descendant(of: _podOf(id), matching: find.byType(SeatBet)),
      );
      expect((seat.bottom - bet.bottom).abs(), lessThan(0.5), reason: id);
    }
    expect(tester.takeException(), isNull);
    await _unmount(tester, state);
  });

  for (final lang in AppLang.values) {
    for (final scale in const [1.0, 1.25]) {
      testWidgets('in ${lang.englishName} at 592x360 x$scale, what a seat\'s '
          'rows hold stays inside them, dealt, packed and waiting', (
        tester,
      ) async {
        if (!haveScriptFonts()) {
          markTestSkipped('the Noto script fonts are not installed');
          return;
        }
        final state = await _mount(
          tester,
          tableScenes.firstWhere(
            (s) => s.name.startsWith('01-opponent-turn'),
          ),
          size: const Size(592, 360),
          textScale: scale,
          lang: lang,
          scripts: true,
        );
        for (final (label, room) in <(String, RoomState)>[
          ('dealt', opponentTurnRoom()),
          ('seats packed', youWonRoom()),
          ('waiting', waitingRoom()),
        ]) {
          state.handleState(room);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 900));
          for (final id in rim) {
            final seat = tester.getRect(_podOf(id));
            for (final part in [
              find.descendant(of: _podOf(id), matching: find.byType(SeatBet)),
              find.descendant(of: _podOf(id), matching: find.byType(Text)),
            ]) {
              for (var i = 0; i < part.evaluate().length; i++) {
                final r = tester.getRect(part.at(i));
                expect(
                  r.bottom,
                  lessThanOrEqualTo(seat.bottom + 0.5),
                  reason: '$id, $label: $r runs past the seat $seat',
                );
              }
            }
          }
        }
        expect(tester.takeException(), isNull);
        await _unmount(tester, state);
      });
    }
  }
}
