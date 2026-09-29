// Each player's level on their pod at the table (owner, 29 Sep 2026: "In
// gametable In every player pod show their game level icon on top right of
// player pod"): the level's art (the owner's Lottie, `room:state` seats[].level)
// on the top-right corner of every pod — the viewer's too — a little past the
// corner, taking no layout and no taps; nothing where the level has no art yet
// or the server sent none; the one-second tick never rebuilding its Lottie;
// and nothing overflowing at 592x360–915x412, x1.0 and x1.25.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/level_art.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/seat_pod.dart';

import 'level_fixtures.dart';
import 'table_scenes.dart';

final _art = find.byKey(const ValueKey('seat-level-art'));

Future<GameState> _pump(
  WidgetTester tester, {
  Size screen = const Size(891, 411),
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
  final state = sceneState(
    TableScene('levels', (s) => s.handleState(levelsRoom())),
  );
  await tester.pumpWidget(
    tableApp(
      state: state,
      feedback: feedback,
      theme: dark ? AppTheme.dark(sound: false) : AppTheme.light(sound: false),
    ),
  );
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  return state;
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

/// The pod of the seat at [index].
Finder _podOf(int index) =>
    find.byWidgetPredicate((w) => w is SeatPod && w.seat?.seatIndex == index);

/// The pod's own box (the plaque, and the turn ring round it while on turn):
/// the Stack the art is laid over.
Rect _podBox(WidgetTester tester, Finder art) =>
    tester.getRect(find.ancestor(of: art, matching: find.byType(Stack)).first);

/// The glass plaque itself.
Rect _plaque(WidgetTester tester, int index) => tester.getRect(
  find
      .descendant(of: _podOf(index), matching: find.byType(PremiumGlassPanel))
      .first,
);

void main() {
  setUpAll(() async {
    await loadLevelFonts();
  });
  setUp(primeLevelArt);
  tearDownAll(PictureCache.clearMemory);

  test('the wire: a seat\'s level and its art, or none', () {
    final room = levelsRoom();
    final seats = {for (final s in room.seats) s.seatIndex: s};
    expect(
      seats[0]!.level,
      const SeatLevel(
        level: 10,
        assetUrl: 'https://drive.test/levels/10.json',
        assetFormat: 'LOTTIE',
      ),
    );
    expect(seats[0]!.level!.hasArt, isTrue);
    expect(seats[2]!.level!.level, 20);
    expect(seats[2]!.level!.hasArt, isFalse);
    expect(seats[3]!.level, isNull);
    expect(SeatLevel.maybe({'level': 0}), isNull);
    expect(SeatLevel.maybe('x'), isNull);
  });

  testWidgets('every pod with a level\'s art wears it on its top-right '
      'corner, the viewer\'s too; none where there is no art or no level', (
    tester,
  ) async {
    await _pump(tester);
    expect(tester.takeException(), isNull);
    for (final (index, url) in [
      (0, levelArtUrl(10)),
      (1, levelArtUrl(3)),
      (4, levelArtUrl(1)),
    ]) {
      final art = find.descendant(of: _podOf(index), matching: _art);
      expect(art, findsOneWidget, reason: 'seat $index');
      expect(tester.widget<LevelArt>(art).assetUrl, url);
      final a = tester.getRect(art);
      final box = _podBox(tester, art);
      final side = box.width * SeatPod.levelShare;
      expect(a.width, closeTo(side, 0.5), reason: 'seat $index');
      // On the pod's top-right corner, a little past it each way.
      expect(
        a.right,
        closeTo(box.right + side * SeatPod.levelOverhang, 1.0),
        reason: 'seat $index',
      );
      expect(
        a.top,
        closeTo(box.top - side * SeatPod.levelOverhang, 1.0),
        reason: 'seat $index',
      );
      // Over the plaque's own corner (the viewer's, on turn, inside its ring).
      final plaque = _plaque(tester, index);
      expect(
        a.contains(plaque.topRight + const Offset(-1, 1)),
        isTrue,
        reason: 'seat $index: $a over $plaque',
      );
      // Drawn: the Lottie is there.
      expect(
        find.descendant(of: art, matching: find.byType(LottieBuilder)),
        findsOneWidget,
      );
    }
    for (final index in [2, 3]) {
      expect(
        find.descendant(of: _podOf(index), matching: _art),
        findsNothing,
        reason: 'seat $index',
      );
    }
    // It takes no taps: a tap is the pod's.
    final guard = tester.widget<IgnorePointer>(
      find.ancestor(of: _art.first, matching: find.byType(IgnorePointer)).first,
    );
    expect(guard.ignoring, isTrue);
    await _unmount(tester);
  });

  testWidgets('the one-second tick never rebuilds a pod\'s level art', (
    tester,
  ) async {
    final state = await _pump(tester);
    final before = [
      for (final e in _art.evaluate()) (e as StatefulElement).state,
    ];
    final rebuilt = <String>[];
    debugOnRebuildDirtyWidget = (element, _) {
      var underArt = false;
      element.visitAncestorElements((e) {
        if (e.widget.key == const ValueKey('seat-level-art')) {
          underArt = true;
          return false;
        }
        return true;
      });
      // LevelArt itself is asked to build every tick and hands back the
      // subtree it kept; what counts is what is under it.
      if (underArt) {
        rebuilt.add(element.widget.runtimeType.toString());
      }
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    for (var i = 0; i < 3; i++) {
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      state.notifyListeners();
      await tester.pump(const Duration(seconds: 1));
    }
    debugOnRebuildDirtyWidget = null;
    expect(
      rebuilt,
      isEmpty,
      reason: 'nothing under the art is rebuilt by the tick: $rebuilt',
    );
    final after = [
      for (final e in _art.evaluate()) (e as StatefulElement).state,
    ];
    expect(
      after,
      before,
      reason: 'the same states: nothing rebuilt from nothing',
    );
    await _unmount(tester);
  });

  for (final size in const [
    Size(592, 360),
    Size(640, 360),
    Size(844, 390),
    Size(915, 412),
  ]) {
    for (final scale in [1.0, 1.25]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()} x$scale: '
          'nothing overflows, every art on screen', (tester) async {
        for (final dark in [true, false]) {
          await _pump(tester, screen: size, scale: scale, dark: dark);
          expect(tester.takeException(), isNull);
          expect(_art, findsNWidgets(3));
          for (final e in _art.evaluate()) {
            final r = tester.getRect(find.byWidget(e.widget));
            expect(
              r.left >= 0 &&
                  r.top >= 0 &&
                  r.right <= size.width &&
                  r.bottom <= size.height,
              isTrue,
              reason: '${dark ? 'dark' : 'light'}: $r off the screen',
            );
          }
          await _unmount(tester);
        }
      });
    }
  }
}
