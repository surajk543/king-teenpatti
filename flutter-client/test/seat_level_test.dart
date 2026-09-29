// Each player's level on their pod at the table (owner, 29 Sep 2026: "In
// gametable In every player pod show their game level icon on top right of
// player pod"; then "Level icon on pod should be inside a circular container
// and increase its size also"): the level's art (the owner's Lottie,
// `room:state` seats[].level) in a disc in the top-right corner of every pod —
// the viewer's too — taking no layout and no taps, clear of the picture;
// the name line kept clear of it; nothing where the level has no art yet or
// the server sent none; the one-second tick never rebuilding its Lottie; and,
// at two to five places on every phone size, no disc off the screen or over
// another seat, the pot, the viewer's cards, the tag or a key.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/avatar.dart';
import 'package:teenpatti/widgets/buy_chips.dart';
import 'package:teenpatti/widgets/level_art.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';
import 'package:teenpatti/widgets/playing_card.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/seat_pod.dart';
import 'package:teenpatti/widgets/table_chrome.dart';

import 'level_fixtures.dart';
import 'table_scenes.dart';

final _mark = find.byKey(const ValueKey('seat-level-mark'));
final _art = find.byKey(const ValueKey('seat-level-art'));

Future<GameState> _pump(
  WidgetTester tester, {
  Size screen = const Size(891, 411),
  double scale = 1.0,
  bool dark = true,
  RoomState Function()? room,
  int maxPlayers = 5,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final state = sceneState(
    TableScene('levels', (s) {
      s.config = s.config.copyWith(maxPlayers: maxPlayers);
      s.handleState((room ?? levelsRoom)());
    }),
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
  await tester.pump(const Duration(seconds: 10));
}

/// A private widget of the table, by its class name.
Finder _private(String name) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

/// The pod of the seat at [index].
Finder _podOf(int index) =>
    find.byWidgetPredicate((w) => w is SeatPod && w.seat?.seatIndex == index);

/// The pod's own box (the plaque, and the turn ring round it while on turn):
/// the Stack the disc is laid over.
Rect _podBox(WidgetTester tester, Finder mark) =>
    tester.getRect(find.ancestor(of: mark, matching: find.byType(Stack)).first);

/// The glass plaque itself.
Rect _plaque(WidgetTester tester, int index) => tester.getRect(
  find
      .descendant(of: _podOf(index), matching: find.byType(PremiumGlassPanel))
      .first,
);

/// Every place taken, each player at a level with art — a disc on every pod.
RoomState _allLevelled(int places) => placesRoom(
  places,
  levels: {
    for (var i = 0; i < places; i++) i: seatLevelJson([10, 3, 13, 6, 1][i]),
  },
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

  testWidgets('every pod with a level\'s art wears it in a disc on its '
      'top-right corner, the viewer\'s too; none where there is no art or no '
      'level', (tester) async {
    await _pump(tester);
    expect(tester.takeException(), isNull);
    for (final (index, url) in [
      (0, levelArtUrl(10)),
      (1, levelArtUrl(3)),
      (4, levelArtUrl(1)),
    ]) {
      final mark = find.descendant(of: _podOf(index), matching: _mark);
      expect(mark, findsOneWidget, reason: 'seat $index');
      final disc = tester.getRect(mark);
      final box = _podBox(tester, mark);
      final side = box.width * SeatPod.levelShare;

      // A disc: a circle, gold-rimmed, casting a shadow.
      final decoration =
          tester.widget<Container>(mark).decoration! as BoxDecoration;
      expect(decoration.shape, BoxShape.circle, reason: 'seat $index');
      expect(decoration.border, isNotNull);
      expect(decoration.boxShadow, isNotEmpty);
      expect(disc.width, closeTo(side, 0.5), reason: 'seat $index');
      expect(disc.height, closeTo(side, 0.5), reason: 'seat $index');

      // In the pod's top-right corner: flush with its right edge, a hair
      // over its top.
      expect(disc.right, closeTo(box.right, 0.5), reason: 'seat $index');
      expect(
        disc.top,
        closeTo(box.top - box.width * SeatPod.levelLift, 0.5),
        reason: 'seat $index',
      );
      // Over the plaque's own corner (the viewer's, on turn, inside its ring).
      final plaque = _plaque(tester, index);
      expect(
        disc.contains(plaque.topRight + const Offset(-1, 1)),
        isTrue,
        reason: 'seat $index: $disc over $plaque',
      );

      // The art inside it, centred, bigger than the bare art it replaced
      // (0.3 of the pod), and drawn.
      final art = find.descendant(of: mark, matching: _art);
      expect(art, findsOneWidget);
      expect(tester.widget<LevelArt>(art).assetUrl, url);
      final a = tester.getRect(art);
      expect(a.width, closeTo(side * SeatLevelMark.artShare, 0.5));
      expect(a.width, greaterThan(box.width * 0.3));
      expect((a.center - disc.center).distance, lessThan(0.5));
      // Clipped to the disc.
      expect(
        find.ancestor(of: art, matching: find.byType(ClipOval)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: art, matching: find.byType(LottieBuilder)),
        findsOneWidget,
      );
    }
    for (final index in [2, 3]) {
      expect(
        find.descendant(of: _podOf(index), matching: _mark),
        findsNothing,
        reason: 'seat $index',
      );
    }
    // It takes no taps: a tap is the pod's.
    final guard = tester.widget<IgnorePointer>(
      find
          .ancestor(of: _mark.first, matching: find.byType(IgnorePointer))
          .first,
    );
    expect(guard.ignoring, isTrue);
    await _unmount(tester);
  });

  testWidgets('the name line keeps clear of the disc, and only where one is '
      'worn', (tester) async {
    for (final scale in [1.0, 1.25]) {
      await _pump(
        tester,
        screen: const Size(640, 360),
        scale: scale,
        room: () => placesRoom(
          5,
          // Vikramaditya (seat 4) wears one; Meera (seat 2) does not.
          levels: {
            for (final i in [0, 1, 3, 4]) i: seatLevelJson(i + 2),
          },
        ),
      );
      for (var i = 0; i < 5; i++) {
        final pod = _podOf(i);
        final name = tester.getRect(
          find.descendant(of: pod, matching: find.byType(SeatName)),
        );
        final plaque = _plaque(tester, i);
        final mark = find.descendant(of: pod, matching: _mark);
        if (mark.evaluate().isEmpty) {
          // No disc: the name centred on the pod, as it always was.
          expect(i, 2);
          expect(name.center.dx, closeTo(plaque.center.dx, 1.0));
          continue;
        }
        final disc = tester.getRect(mark);
        expect(
          name.right,
          lessThanOrEqualTo(disc.left + 0.5),
          reason: 'x$scale seat $i: the name $name under the disc $disc',
        );
      }
      await _unmount(tester);
    }
  });

  testWidgets('"YOU" and the dealer\'s button keep their line beside the '
      'disc on the viewer\'s turn', (tester) async {
    // On turn the ring stands inside the pod's box and narrows the plaque:
    // the line reserved the off-turn room for the disc and read "Y…".
    for (final size in const [Size(592, 360), Size(640, 360), Size(915, 412)]) {
      for (final scale in [1.0, 1.25]) {
        await _pump(
          tester,
          screen: size,
          scale: scale,
          room: () => levelsRoom(dealerSeat: 0),
        );
        final where = '${size.width.toInt()} x$scale';
        final you = find.descendant(
          of: _podOf(0),
          matching: find.byType(SeatName),
        );
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: you, matching: find.byType(RichText)),
        );
        expect(paragraph.didExceedMaxLines, isFalse, reason: where);
        expect(paragraph.text.toPlainText(), 'YOU', reason: where);
        final disc = tester.getRect(
          find.descendant(of: _podOf(0), matching: _mark),
        );
        // Name and dealer's button together, clear of the disc.
        final line = tester.getRect(
          find.ancestor(of: you, matching: find.byType(Row)).first,
        );
        expect(line.right, lessThanOrEqualTo(disc.left + 0.5), reason: where);
        await _unmount(tester);
      }
    }
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

  testWidgets('both themes draw the disc and nothing overflows', (
    tester,
  ) async {
    for (final dark in [true, false]) {
      await _pump(tester, screen: const Size(640, 360), dark: dark);
      expect(tester.takeException(), isNull);
      expect(_mark, findsNWidgets(3));
      await _unmount(tester);
    }
  });

  for (final size in const [
    Size(592, 360),
    Size(640, 360),
    Size(732, 412),
    Size(844, 390),
    Size(891, 411),
    Size(915, 412),
    Size(1280, 800),
  ]) {
    for (final scale in [1.0, 1.25]) {
      final label = '${size.width.toInt()}x${size.height.toInt()} x$scale';
      testWidgets('$label, two to five places: every disc on the screen and '
          'over nothing but its own pod, and clear of its picture', (
        tester,
      ) async {
        final screen = Offset.zero & size;
        final problems = <String>[];
        for (var n = 2; n <= 5; n++) {
          await _pump(
            tester,
            screen: size,
            scale: scale,
            room: () => _allLevelled(n),
            maxPlayers: n,
          );
          expect(tester.takeException(), isNull, reason: '$label $n');
          expect(_mark, findsNWidgets(n), reason: '$label $n');

          // Everything a disc may not lie on.
          Rect union(Finder f) {
            var rect = tester.getRect(f.first);
            for (var i = 1; i < f.evaluate().length; i++) {
              rect = rect.expandToInclude(tester.getRect(f.at(i)));
            }
            return rect;
          }

          Rect keysOf(String corner) => union(
            find.descendant(
              of: _private(corner),
              matching: find.byWidgetPredicate(
                (w) => w is MachinedKey || w is StepperKey,
              ),
            ),
          );
          final others = <String, Rect>{
            'pot': tester.getRect(_private('_Pot')),
            "viewer's cards": union(
              find.descendant(
                of: _private('_OwnHand'),
                matching: find.byType(PlayingCard),
              ),
            ),
            'category tag': tester.getRect(_private('_CategoryTag')),
            'key cluster': keysOf('_ActionCluster'),
            'pack key': keysOf('_PackKey'),
            'missile key': keysOf('_MissileKey'),
            'shop key': tester.getRect(find.byType(ShopButton)),
            'wallet': tester.getRect(find.byType(WalletPill)),
            'rail': union(find.byType(RailKey)),
          };

          for (var i = 0; i < n; i++) {
            final mark = find.descendant(of: _podOf(i), matching: _mark);
            final disc = tester.getRect(mark);
            if (!screen.inflate(0.5).contains(disc.topLeft) ||
                !screen.inflate(0.5).contains(disc.bottomRight)) {
              problems.add('$label, $n places: seat $i disc $disc off screen');
            }
            void clear(String what, Rect r) {
              final o = disc.intersect(r);
              if (o.width > 0.5 && o.height > 0.5) {
                problems.add(
                  '$label, $n places: seat $i disc $disc over $what $r',
                );
              }
            }

            others.forEach(clear);
            // Nor on its own pod's picture: two circles apart.
            final picture = tester.getRect(
              find
                  .descendant(of: _podOf(i), matching: find.byType(Avatar))
                  .first,
            );
            final gap =
                (picture.center - disc.center).distance -
                picture.width / 2 -
                disc.width / 2;
            if (gap < -0.5) {
              problems.add(
                '$label, $n places: seat $i disc $disc over its picture '
                '$picture by ${(-gap).toStringAsFixed(1)}',
              );
            }
            // Every other seat's column: pod, cards, bet.
            for (var j = 0; j < n; j++) {
              if (j != i) clear('seat $j', tester.getRect(_podOf(j)));
            }
          }
          await _unmount(tester);
        }
        expect(problems, isEmpty);
      });
    }
  }
}
