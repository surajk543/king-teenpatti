// The seats round the casino table (owner's table polish brief, 25 Sep 2026:
// "a responsive seat-positioning system based on the table bounds. Support:
// 2, 3, 4, 5 players ... Player positions should follow the table perimeter
// naturally ... adapt to: screen width, screen height, aspect ratio, table
// size ... Never allow: player names to clip, cards to clip, buttons to go
// outside the safe area, pot to overlap player cards, betting controls to
// become inaccessible").
//
// First the ring as the pure function it is — places from the seat count, the
// table and the pod's width — then the table laid out for real at two to five
// places, at every phone size the table is checked on and a narrow and a short
// one, where no seat may cover another, the pot, the viewer's cards, the tag,
// the corners' controls or the keys.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/buy_chips.dart';
import 'package:teenpatti/widgets/casino_table.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';
import 'package:teenpatti/widgets/playing_card.dart';
import 'package:teenpatti/widgets/seat_pod.dart';
import 'package:teenpatti/widgets/seat_ring.dart';
import 'package:teenpatti/widgets/table_chrome.dart';

import 'table_scenes.dart';

/// The phones the table is checked on, and a narrow one (a 640dp phone with
/// its navigation bar down the side) and a short one.
const _sizes = [
  Size(640, 360),
  Size(732, 412),
  Size(844, 390),
  Size(891, 411),
  Size(915, 412),
  Size(592, 360),
  Size(800, 340),
];

/// The screens the table is laid out on for real: the phones, the narrow
/// one, and a tablet. (800x340, shorter than any phone in landscape, is
/// checked as geometry only: its end seats and its top corners' controls
/// cannot both have the room, and the keys are given it.)
const _screens = [
  Size(640, 360),
  Size(732, 412),
  Size(844, 390),
  Size(891, 411),
  Size(915, 412),
  Size(592, 360),
  Size(1280, 800),
];

/// The felt TableScreen lays out on a screen of [size] with no insets: right
/// of the rail, inside the felt's padding (_Felt.build, tableNoticeArea).
Size _felt(Size size) {
  final pad = Dim.feltPad(size.width);
  final w = size.width - Dim.railW(size.width) - 2 * pad;
  final h = size.height - Space.xxs;
  return Size(w, h);
}

SeatRing _ring(int seats, Size screen) {
  final felt = _felt(screen);
  return SeatRing.of(
    seats: seats,
    table: TableGeometry.of(felt),
    podW: Dim.podW(felt.width, felt.height),
  );
}

Finder _private(String name) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

/// A table of [n] places, every place taken, the seat at its right end on
/// turn — the tallest an end seat's column gets (the turn's ring round it).
TableScene _places(int n) => TableScene('$n-places', (s) {
  s.config = s.config.copyWith(maxPlayers: n);
  s.handleState(placesRoom(n));
});

void main() {
  group('the ring', () {
    test('holds a table to two to five places', () {
      expect(SeatRing.clampSeats(0), 5);
      expect(SeatRing.clampSeats(1), 2);
      expect(SeatRing.clampSeats(3), 3);
      expect(SeatRing.clampSeats(9), 5);
    });

    test('spreads the others evenly from the table\'s left end round the '
        'head to its right end', () {
      expect([for (var v = 1; v < 2; v++) SeatRing.angleOf(v, 2)], [270]);
      expect([for (var v = 1; v < 3; v++) SeatRing.angleOf(v, 3)], [180, 360]);
      expect(
        [for (var v = 1; v < 4; v++) SeatRing.angleOf(v, 4)],
        [180, 270, 360],
      );
      expect(
        [for (var v = 1; v < 5; v++) SeatRing.angleOf(v, 5)],
        [180, 240, 300, 360],
      );
      for (var n = 2; n <= 5; n++) {
        expect(SeatRing.angleOf(0, n), 90, reason: 'the viewer, at the foot');
      }
    });

    for (final size in _sizes) {
      final label = '${size.width.toInt()}x${size.height.toInt()}';
      test('every place stands on the table and inside the felt at $label', () {
        final felt = _felt(size);
        for (var n = 2; n <= 5; n++) {
          final ring = _ring(n, size);
          final podW = ring.podW;
          expect(ring.spots, hasLength(n));
          expect(ring.spots.first.isViewer, isTrue);
          // The viewer on the floor, their pod inside the felt.
          final me = ring.spots.first.anchor;
          expect(me.dx - podW / 2, greaterThanOrEqualTo(0));
          expect(me.dy, closeTo(felt.height * (1 - SeatRing.floorShare), 1e-6));

          for (final spot in ring.rim) {
            final why = '$label, $n places, seat ${spot.view}';
            if (spot.head) {
              // The head seat: its pod at the top of the felt, its unit
              // inside it.
              expect(
                spot.anchor.dx,
                closeTo(felt.width / 2, 1e-6),
                reason: why,
              );
              expect(ring.headLeft, greaterThanOrEqualTo(0), reason: why);
              expect(
                ring.headLeft + ring.headUnitWidth,
                lessThanOrEqualTo(felt.width),
                reason: why,
              );
              expect(spot.anchor.dy, SeatRing.headTop, reason: why);
            } else {
              // A column a pod wide, inside the felt from side to side.
              expect(spot.anchor.dx - podW / 2, greaterThanOrEqualTo(-1e-6));
              expect(
                spot.anchor.dx + podW / 2,
                lessThanOrEqualTo(felt.width + 1e-6),
                reason: why,
              );
              // Its pod meets the table: the column's middle is inside the
              // table's outline, in its upper half.
              final table = ring.table.outer.outerRect;
              expect(table.contains(spot.anchor), isTrue, reason: why);
              expect(spot.anchor.dy, lessThan(table.center.dy), reason: why);
            }
          }
        }
      });

      test('the table is symmetric about its middle at $label', () {
        final w = _felt(size).width;
        for (var n = 2; n <= 5; n++) {
          final ring = _ring(n, size);
          for (var v = 1; v < n; v++) {
            final a = ring.spots[v];
            final b = ring.spots[n - v];
            expect(a.angle + b.angle, closeTo(540, 1e-9));
            expect(a.anchor.dx + b.anchor.dx, closeTo(w, 1e-6));
            expect(a.anchor.dy, closeTo(b.anchor.dy, 1e-6));
          }
        }
      });
    }

    test('the corners keep the table\'s ends off the keys and under the top '
        'controls on a very short screen, and move nothing on a phone', () {
      for (final size in _sizes) {
        final felt = _felt(size);
        final keysTop = SeatRing.keysTopFor(size, felt.height);
        final corners = SeatRing.cornersBottomFor(size);
        for (var n = 2; n <= 5; n++) {
          final free = _ring(n, size);
          final kept = SeatRing.forFelt(seats: n, screen: size, felt: felt);
          for (var v = 1; v < n; v++) {
            final spot = kept.spots[v];
            final why = '$size $n $v';
            if (spot.head) continue;
            final half = SeatRing.columnShare * kept.podW / 2;
            final room = keysTop - corners - 2 * Space.sm;
            final end = spot.angle == 180 || spot.angle == 360;
            {
              // Clear of the keys, the column at its tallest: always.
              expect(
                spot.anchor.dy + half,
                lessThanOrEqualTo(keysTop - Space.sm + 1e-6),
                reason: why,
              );
            }
            if (end && room >= 2 * half) {
              // And under the top corners' controls.
              expect(
                spot.anchor.dy - half,
                greaterThanOrEqualTo(corners + Space.sm - 1e-6),
                reason: why,
              );
            }
            expect(spot.anchor.dx, free.spots[v].anchor.dx, reason: why);
          }
          // On the Android phones the felt was tuned on the ring barely
          // moves: an end seat rises a few dp at most, and nothing else.
          if (const [
            Size(640, 360),
            Size(732, 412),
            Size(891, 411),
            Size(915, 412),
          ].contains(size)) {
            for (var v = 1; v < n; v++) {
              final rise = free.spots[v].anchor.dy - kept.spots[v].anchor.dy;
              expect(
                rise,
                inInclusiveRange(0, Space.sm),
                reason: '$size $n $v',
              );
            }
          }
        }
      }
    });

    test("the viewer's hand clears the key cluster and their pod Missile "
        'and Pack', () {
      for (final size in _sizes) {
        final felt = _felt(size);
        final ring = SeatRing.forFelt(seats: 5, screen: size, felt: felt);
        final me = ring.spots.first.anchor;
        final hand = SeatRing.handWidthFor(Dim.handH(felt.height));
        final handRight = me.dx + ring.podW / 2 + Space.md + hand;
        expect(
          handRight,
          lessThanOrEqualTo(
            SeatRing.keysLeftFor(size, felt.width) - Space.sm + 1e-6,
          ),
          reason: '$size',
        );
        expect(
          me.dx - ring.podW / 2,
          greaterThanOrEqualTo(
            SeatRing.leftKeysRightFor(size) + Space.sm - 1e-6,
          ),
          reason: '$size',
        );
        // Where the keys leave the room, the place the felt was tuned with.
        if (size.width >= 732) {
          expect(
            me.dx,
            closeTo(felt.width * SeatRing.viewerShare, 1e-6),
            reason: '$size',
          );
        }
      }
    });

    test('only a two- or four-place table seats somebody at the head', () {
      for (var n = 2; n <= 5; n++) {
        final ring = _ring(n, const Size(891, 411));
        expect(ring.head != null, n == 2 || n == 4, reason: '$n places');
      }
    });

    test('five places stand within a dp of where the felt was tuned', () {
      for (final size in _sizes) {
        final felt = _felt(size);
        final ring = _ring(5, size);
        final podW = ring.podW;
        for (var v = 1; v < 5; v++) {
          // The old places, clamped inside the felt as _Felt.at() clamped.
          final old = seatPlaces[v];
          final x = (old.dx * felt.width).clamp(
            podW / 2,
            felt.width - podW / 2,
          );
          expect(ring.spots[v].anchor.dx, closeTo(x, 1), reason: '$size $v');
          expect(
            ring.spots[v].anchor.dy,
            closeTo(old.dy * felt.height, 1),
            reason: '$size $v',
          );
        }
        expect(
          ring.spots.first.anchor.dx,
          closeTo(seatPlaces.first.dx * felt.width, 1e-6),
        );
      }
    });

    test(
      'the tag stands over the far rail, or beside the head seat\'s pod',
      () {
        for (final size in _sizes) {
          for (var n = 2; n <= 5; n++) {
            final ring = _ring(n, size);
            final felt = _felt(size);
            final tag = ring.tagSlot(
              width: felt.width * 0.30,
              centreY: felt.height * 0.075,
              height: 24,
            );
            final pod = ring.headPod;
            if (pod == null) {
              expect(tag.center.dx, closeTo(felt.width / 2, 1e-6));
            } else {
              expect(tag.right, lessThanOrEqualTo(pod.left - Space.md + 1e-6));
              expect(tag.left, greaterThanOrEqualTo(ring.podW / 2 - 1e-6));
              expect(tag.overlaps(pod), isFalse);
            }
          }
        }
      },
    );
  });

  group('the table at two to five places', () {
    for (final size in _screens) {
      for (final scale in [1.0, 1.25]) {
        final label = '${size.width.toInt()}x${size.height.toInt()} x$scale';
        testWidgets('no seat covers another, the pot, the cards or the keys '
            'at $label', (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final screen = Offset.zero & size;
          final problems = <String>[];

          for (var n = 2; n <= 5; n++) {
            final feedback = await silentFeedback();
            final state = sceneState(_places(n));
            await tester.pumpWidget(
              tableApp(
                state: state,
                feedback: feedback,
                theme: AppTheme.dark(sound: false),
              ),
            );
            await tester.pump(const Duration(milliseconds: 900));
            await tester.pump(const Duration(milliseconds: 900));
            expect(tester.takeException(), isNull, reason: '$label $n');

            final pods = find.byType(SeatPod);
            expect(pods, findsNWidgets(n), reason: '$label: $n places');
            final rim = <Rect>[];
            Rect? mine;
            for (var i = 0; i < n; i++) {
              final rect = tester.getRect(pods.at(i));
              if (tester.widget<SeatPod>(pods.at(i)).isMe) {
                mine = rect;
              } else {
                rim.add(rect);
              }
            }
            expect(mine, isNotNull);

            final cardFinder = find.descendant(
              of: _private('_OwnHand'),
              matching: find.byType(PlayingCard),
            );
            var cards = tester.getRect(cardFinder.first);
            for (var i = 1; i < cardFinder.evaluate().length; i++) {
              cards = cards.expandToInclude(tester.getRect(cardFinder.at(i)));
            }
            // A corner's keys as drawn, without the padding round them.
            Rect keysOf(String corner) {
              final keys = find.descendant(
                of: _private(corner),
                matching: find.byWidgetPredicate(
                  (w) => w is MachinedKey || w is StepperKey,
                ),
              );
              var rect = tester.getRect(keys.first);
              for (var i = 1; i < keys.evaluate().length; i++) {
                rect = rect.expandToInclude(tester.getRect(keys.at(i)));
              }
              return rect;
            }

            final pot = tester.getRect(_private('_Pot'));
            final others = <String, Rect>{
              'pot': pot,
              "viewer's cards": cards,
              "viewer's pod": mine!,
              'category tag': tester.getRect(_private('_CategoryTag')),
              'key cluster': keysOf('_ActionCluster'),
              'pack key': keysOf('_PackKey'),
              'missile key': keysOf('_MissileKey'),
              'shop key': tester.getRect(find.byType(ShopButton)),
              'wallet': tester.getRect(find.byType(WalletPill)),
            };

            void clear(String a, Rect ra, String b, Rect rb) {
              final o = ra.intersect(rb);
              if (o.width > 0.5 && o.height > 0.5) {
                problems.add('$label, $n places: $a $ra overlaps $b $rb');
              }
            }

            for (final (i, a) in rim.indexed) {
              // On the screen, whole.
              expect(
                screen.inflate(0.5).contains(a.topLeft) &&
                    screen.inflate(0.5).contains(a.bottomRight),
                isTrue,
                reason: '$label, $n places: seat $i at $a is off the screen',
              );
              for (final (j, b) in rim.indexed) {
                if (j > i) clear('seat $i', a, 'seat $j', b);
              }
              others.forEach((what, rect) => clear('seat $i', a, what, rect));
            }
            // The pot never lies on anybody's cards, the viewer's included,
            // and no key on the viewer's cards or pod.
            clear('pot', pot, "viewer's cards", cards);
            for (final corner in ['key cluster', 'pack key', 'missile key']) {
              clear("viewer's cards", cards, corner, others[corner]!);
              clear("viewer's pod", mine, corner, others[corner]!);
            }
            // The fan is as wide as the ring was told it would be.
            final feltH = size.height - Space.xxs;
            expect(
              tester.getSize(_private('_OwnHand')).width,
              closeTo(SeatRing.handWidthFor(Dim.handH(feltH)), 0.5),
            );
            expect(
              screen.inflate(0.5).contains(mine.topLeft) &&
                  screen.inflate(0.5).contains(mine.bottomRight),
              isTrue,
              reason: '$label, $n places: the viewer is off the screen',
            );

            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(seconds: 10));
            state.dispose();
            feedback.dispose();
          }
          expect(problems, isEmpty);
        });
      }
    }

    testWidgets('a player leaving or joining moves nobody else', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(891, 411);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final feedback = await silentFeedback();
      addTearDown(feedback.dispose);

      Future<Map<String, Rect>> podsOf(TableScene scene) async {
        final state = sceneState(scene);
        await tester.pumpWidget(
          tableApp(
            state: state,
            feedback: feedback,
            theme: AppTheme.dark(sound: false),
          ),
        );
        await tester.pump(const Duration(milliseconds: 900));
        final rects = <String, Rect>{};
        final pods = find.byType(SeatPod);
        for (var i = 0; i < pods.evaluate().length; i++) {
          final seat = tester.widget<SeatPod>(pods.at(i)).seat;
          if (seat != null && seat.occupied) {
            rects[seat.userId!] = tester.getRect(pods.at(i));
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 10));
        state.dispose();
        return rects;
      }

      final full = await podsOf(
        TableScene('all-in', (s) => s.handleState(placesRoom(5))),
      );
      // Meera (u2) gets up: her chair stays, and nobody else moves.
      final emptied = await podsOf(
        TableScene(
          'meera-left',
          (s) => s.handleState(placesRoom(5, empty: const [2])),
        ),
      );
      expect(emptied.keys, isNot(contains('u2')));
      for (final id in emptied.keys) {
        expect(emptied[id], full[id], reason: id);
      }
    });
  });
}
