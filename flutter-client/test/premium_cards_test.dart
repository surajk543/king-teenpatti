// The playing cards (premium-card brief, 25 Sep 2026: "the actual Teen Patti
// playing cards look significantly more premium and polished" — the table
// itself unchanged).
//
// The face: red and black read on the ivory stock at every height a card is
// drawn at, the rank leads (a quarter of a small card, a fifth of a large
// one), a 10 fits its corner condensed rather than shrunk, and the index and
// the centre pip never meet. The painted pixels are the right colours, and
// nothing on any face is boxed (the owner's refinement: "premium traditional
// playing cards, not UI tiles").
//
// The fan: 4° out at either end, the middle card upright, 4% larger and ON
// TOP, and no card's index under another card — the four hands the owner
// names, a ten on the right, five being chosen from, and five with the best
// three set out — and at every phone size, at text x1.0 and x1.25, no card of
// the viewer's under a key, the pot, their bet or their own pod; the hand
// lifted off the floor as far as the pot allows, never less than before.
//
// The motion: a hand turns over left to right, a card waits its beat before
// turning, and a dealt hand has landed inside 0.7 s. The back: the crown still,
// the SEEN green still, on the same gold-edged stock as the face.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/theme/table_theme.dart';
import 'package:teenpatti/widgets/hand_fan.dart';
import 'package:teenpatti/widgets/playing_card.dart';
import 'package:teenpatti/widgets/seat_pod.dart';
import 'package:teenpatti/widgets/table_chrome.dart';

import 'table_scenes.dart';

/// WCAG's contrast ratio between two opaque colours.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return la > lb ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05);
}

Finder _private(String type) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

/// The viewer's own cards, in the order they are PAINTED — the card on top
/// last.
Finder get _ownCards => find.descendant(
  of: _private('_OwnHand'),
  matching: find.byType(PlayingCard),
);

/// [local], a rectangle in [box]'s own coordinates, as the four corners it
/// lands on on the screen — through every rotation and scale above it.
List<Offset> _quad(RenderBox box, Rect local) => [
  box.localToGlobal(local.topLeft),
  box.localToGlobal(local.topRight),
  box.localToGlobal(local.bottomRight),
  box.localToGlobal(local.bottomLeft),
];

List<Offset> _rectQuad(Rect r) => [
  r.topLeft,
  r.topRight,
  r.bottomRight,
  r.bottomLeft,
];

/// Whether two convex quadrilaterals overlap by more than half a pixel
/// (separating-axis test).
bool _overlap(List<Offset> a, List<Offset> b) {
  for (final poly in [a, b]) {
    for (var i = 0; i < poly.length; i++) {
      final edge = poly[(i + 1) % poly.length] - poly[i];
      final axis = Offset(-edge.dy, edge.dx) / edge.distance;
      double lo(List<Offset> p) =>
          p.map((q) => q.dx * axis.dx + q.dy * axis.dy).reduce(math.min);
      double hi(List<Offset> p) =>
          p.map((q) => q.dx * axis.dx + q.dy * axis.dy).reduce(math.max);
      if (hi(a) <= lo(b) + 0.5 || hi(b) <= lo(a) + 0.5) return false;
    }
  }
  return true;
}

/// What a card of the viewer's shows of its rank and suit, in its own
/// coordinates: the rank as wide as it is set, and the pip under it, in the
/// corner the card prints its index in.
List<Rect> _indexInk(PlayingCard card) {
  final m = CardFaceMetrics.of(card.height);
  final right = card.indexOnRight;
  final column = m.rank(right: right);
  final fit = cardRankFit(PlayingCard.rankOf(card.code!), card.height);
  return [
    Rect.fromCenter(
      center: column.center,
      width: fit.width,
      height: column.height,
    ),
    m.indexPipBox(right: right),
  ];
}

Future<GameState> _mount(
  WidgetTester tester,
  TableScene scene, {
  required Size size,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final state = sceneState(scene);
  await tester.pumpWidget(
    tableApp(
      state: state,
      feedback: feedback,
      theme: AppTheme.dark(sound: false),
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

TableScene _scene(String prefix) =>
    tableScenes.firstWhere((s) => s.name.startsWith(prefix));

/// A ten on the RIGHT of the hand, where its index is printed in the card's
/// top-right corner — the widest index there is, on the side covered least.
final _tenOnTheRight = TableScene(
  'ten on the right',
  (s) => s.handleState(seenTurnRoom(cards: const ['Jc', 'Qh', 'Ts'])),
);

/// Five cards being chosen from: the fan evenly spread, all five faces up.
final _choosing = TableScene(
  'choosing',
  (s) => s.handleState(fiveCardRoom(choosing: true)),
);

const _sizes = [
  Size(592, 360),
  Size(640, 360),
  Size(732, 412),
  Size(844, 390),
  Size(891, 411),
  Size(915, 412),
];

/// Every height a face is drawn at on the phones above: a rim seat's, the
/// rules sheet's, the 5-Card picker's, the poker board's and the viewer's
/// own, and the tallest a tablet asks for.
const _heights = [
  25.0,
  34.0,
  38.0,
  41.0,
  45.0,
  47.0,
  52.0,
  55.9,
  56.0,
  60.0,
  66.0,
  72.0,
  80.0,
  84.0,
  88.0,
  94.0,
  104.0,
  113.4,
];

const _ranks = [
  'A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K', //
];

void main() {
  setUpAll(() async {
    final inter = FontLoader('Inter');
    for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
    }
    await inter.load();
  });

  group('the face', () {
    test('red and black read on the ivory stock, where it is lightest and '
        'where it is deepest', () {
      for (final stock in [
        AppTheme.cardFaceHigh,
        AppTheme.cardFace,
        AppTheme.cardFaceLow,
      ]) {
        expect(_contrast(AppTheme.pipRed, stock), greaterThanOrEqualTo(4.5));
        expect(_contrast(AppTheme.pipBlack, stock), greaterThanOrEqualTo(7));
      }
      // Hearts and diamonds red, spades and clubs black, and nothing else.
      expect(PlayingCard.inkFor('h'), AppTheme.pipRed);
      expect(PlayingCard.inkFor('d'), AppTheme.pipRed);
      expect(PlayingCard.inkFor('s'), AppTheme.pipBlack);
      expect(PlayingCard.inkFor('c'), AppTheme.pipBlack);
      // Warm ivory, not grey-white: red leads blue on both ends of the stock.
      for (final stock in [AppTheme.cardFaceHigh, AppTheme.cardFaceLow]) {
        expect(
          (stock.r - stock.b) * 255,
          greaterThanOrEqualTo(6),
          reason: '$stock is warm',
        );
      }
    });

    test('the rank leads at every height, and nothing on the face meets', () {
      for (final h in _heights) {
        final m = CardFaceMetrics.of(h);
        final why = '${h}dp';
        expect(m.compact, h < PlayingCard.compactBelow, reason: why);
        // More than a quarter of a small card is rank, a fifth of a large
        // one — never less: small cards drop detail, not rank.
        expect(
          m.rankCap,
          greaterThanOrEqualTo(h * (m.compact ? 0.27 : 0.21) - 1e-9),
          reason: why,
        );
        // Rank over suit over the rest.
        expect(m.indexPip, lessThan(m.rankCap), reason: why);
        expect(m.centrePip, greaterThan(m.rankCap), reason: why);
        for (final right in [false, true]) {
          final column = m.index(right: right);
          expect(column.left, greaterThan(0), reason: why);
          expect(column.right, lessThan(m.width), reason: why);
          // The index stands clear of the centre pip, and of the ace's.
          expect(
            column.bottom,
            lessThan(m.centreY - m.centrePip / 2),
            reason: why,
          );
          expect(column.bottom, lessThan(m.aceY - m.acePip / 2), reason: why);
        }
        expect(m.centreY + m.centrePip / 2, lessThan(h), reason: why);
        expect(m.aceY + m.acePip / 2, lessThan(h), reason: why);
      }
    });

    test('every rank fits its corner; a 10 is condensed, never shrunk', () {
      for (final h in _heights) {
        final m = CardFaceMetrics.of(h);
        for (final rank in _ranks) {
          final fit = cardRankFit(rank, h);
          final why = '$rank at ${h}dp';
          expect(
            fit.width,
            lessThanOrEqualTo(m.indexWidth + 1e-6),
            reason: why,
          );
          expect(fit.shrink, 1.0, reason: '$why is as tall as every rank');
          if (rank == '10') {
            expect(fit.condense, inInclusiveRange(0.8, 1.0), reason: why);
          } else {
            expect(fit.condense, 1.0, reason: '$why is set as drawn');
          }
        }
      }
    });

    testWidgets('red suits are painted red and black suits black, on ivory', (
      tester,
    ) async {
      const h = 100.0;
      const codes = ['5c', '9c', '5d', 'As', 'Kh', 'Qd', 'Jc', 'Ts', '2h'];
      final key = GlobalKey();
      tester.view.physicalSize = const Size(1200, 200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(sound: false),
          home: Center(
            child: RepaintBoundary(
              key: key,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final code in codes)
                    Padding(
                      padding: const EdgeInsets.all(10),
                      child: PlayingCard(code: code, height: h),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final image = await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        return boundary.toImage();
      });
      final bytes = (await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;

      Color pixel(Offset at) {
        final i = (at.dy.round() * image!.width + at.dx.round()) * 4;
        return Color.fromARGB(
          bytes.getUint8(i + 3),
          bytes.getUint8(i),
          bytes.getUint8(i + 1),
          bytes.getUint8(i + 2),
        );
      }

      final m = CardFaceMetrics.of(h);
      for (final (i, code) in codes.indexed) {
        final origin = Offset(10 + i * (m.width + 20), 10);
        final suit = PlayingCard.suitOf(code);
        final rank = PlayingCard.rankOf(code);
        final y = rank == 'A' ? m.aceY : m.centreY;
        // A point well inside every suit's silhouette: a club's centre is
        // the notch between its lobes.
        final corner = m.indexPipBox();
        final pip = pixel(
          origin + Offset(m.width / 2, y) - Offset(0, m.centrePip * 0.15),
        );
        final small = pixel(
          origin + corner.center - Offset(0, corner.height * 0.15),
        );
        final stock = pixel(origin + Offset(m.width * 0.9, h * 0.52));
        for (final (what, ink) in [
          ('centre pip', pip),
          ('corner pip', small),
        ]) {
          final r = ink.r * 255, g = ink.g * 255, b = ink.b * 255;
          if (suit == 'h' || suit == 'd') {
            expect(r, greaterThan(140), reason: '$code $what $ink is red');
            expect(g, lessThan(90), reason: '$code $what $ink is red');
            expect(b, lessThan(100), reason: '$code $what $ink is red');
          } else {
            expect(
              math.max(r, math.max(g, b)),
              lessThan(90),
              reason: '$code $what $ink is black',
            );
          }
        }
        expect(stock.r * 255, greaterThan(235), reason: '$code: ivory');
        expect(stock.b * 255, greaterThan(200), reason: '$code: ivory');
        expect(stock.r, greaterThan(stock.b), reason: '$code: warm ivory');
        // A clean face: round the centre pip, where a court card's window
        // was ruled, is bare stock on every card.
        for (final at in [
          Offset(m.width * 0.13, h * 0.72),
          Offset(m.width * 0.87, h * 0.72),
          Offset(m.width * 0.13, h * 0.47),
          Offset(m.width * 0.87, h * 0.47),
          Offset(m.width * 0.5, h * 0.93),
        ]) {
          final bare = pixel(origin + at);
          expect(
            bare.r * 255,
            greaterThan(230),
            reason: '$code at $at is bare stock, not a frame: $bare',
          );
          expect(bare.b * 255, greaterThan(195), reason: '$code at $at');
        }
      }
      image!.dispose();
    });
  });

  group('the fan', () {
    test('leans 4° out at either end and paints its middle card last, a '
        'touch larger', () {
      final degrees = HandFan.tilt * 180 / math.pi;
      expect(degrees, closeTo(4, 0.01));
      expect(HandFan.topScale, inInclusiveRange(1.02, 1.05));
      expect(HandFan.scaleFor(1, 1, 3), HandFan.topScale);
      expect(HandFan.scaleFor(0, 1, 3), 1.0);
      expect(HandFan.scaleFor(2, 2, 5), 1.0, reason: 'five stand too close');
      expect(HandFan.paintOrder(3), [0, 2, 1]);
      expect(HandFan.paintOrder(5), [0, 4, 1, 3, 2]);
      expect(HandFan.angleAt(0, 1), closeTo(-HandFan.tilt, 1e-12));
      expect(HandFan.angleAt(0.5, 1), 0);
      expect(HandFan.angleAt(1, 1), closeTo(HandFan.tilt, 1e-12));
      // Only a card to the right of the one on top prints its index on the
      // right.
      expect(
        [for (var s = 0; s < 3; s++) HandFan.indexOnRight(s, 1)],
        [false, false, true],
      );
      // A hand of three is fanned tighter than five, inside the same box.
      expect(HandFan.runFor(3, 1), lessThan(HandFan.runFor(5, 1)));
      expect(HandFan.startFor(3, 100), greaterThan(HandFan.startFor(5, 100)));
    });

    for (final (name, scene, count) in [
      ('5c 9c 5d', _scene('26-cards'), 3),
      ('As Kh Qd', _scene('27-cards'), 3),
      ('Qs Ac Jh', _scene('31-cards'), 3),
      ('Ts Jc Qh', _scene('32-cards'), 3),
      ('a ten on the right', _tenOnTheRight, 3),
      ('five cards being chosen from', _choosing, 5),
      ('five cards with the best three set out', _scene('28-cards'), 5),
    ]) {
      for (final size in _sizes) {
        for (final scale in [1.0, 1.25]) {
          final label = '${size.width.toInt()}x${size.height.toInt()} x$scale';
          testWidgets('$name at $label: no index under another card, no card '
              'under a key, the pot or the pod', (tester) async {
            final state = await _mount(
              tester,
              scene,
              size: size,
              textScale: scale,
            );
            expect(tester.takeException(), isNull);
            final cards = _ownCards.evaluate().toList();
            expect(cards, hasLength(count));

            final quads = <List<Offset>>[];
            final inks = <List<List<Offset>>>[];
            for (final element in cards) {
              final card = element.widget as PlayingCard;
              expect(card.code, isNotNull, reason: 'face up');
              final box = element.renderObject! as RenderBox;
              quads.add(_quad(box, Offset.zero & box.size));
              inks.add([for (final r in _indexInk(card)) _quad(box, r)]);
            }

            // The card painted last stands in the middle — of the hand, or of
            // the three that count once they are set out.
            final xs = [for (final q in quads) (q[0].dx + q[2].dx) / 2];
            final sorted = [...xs]..sort();
            final counted = count == 5 && scene != _choosing ? 3 : count;
            expect(
              xs.last,
              closeTo(sorted[count - counted + counted ~/ 2], 0.01),
              reason: 'the middle card is on top',
            );

            // Every card's rank and pip are clear of every card over it — the
            // two set aside under a five-card hand's best three excepted: they
            // are out of the hand, tucked a quarter of a card apart.
            final aside = counted == 3 && count == 5
                ? {
                    for (var i = 0; i < count; i++)
                      if (xs[i] < sorted[2] - 0.01) i,
                  }
                : const <int>{};
            for (var i = 0; i < count; i++) {
              if (aside.contains(i)) continue;
              for (var j = i + 1; j < count; j++) {
                for (final ink in inks[i]) {
                  expect(
                    _overlap(ink, quads[j]),
                    isFalse,
                    reason:
                        '$label: ${(cards[i].widget as PlayingCard).code}\'s '
                        'index is under ${(cards[j].widget as PlayingCard).code}',
                  );
                }
              }
            }

            // A plain hand of three: the middle card upright and a touch
            // larger, the outer two 4° out.
            if (count == 3) {
              double angle(List<Offset> q) =>
                  math.atan2(q[1].dy - q[0].dy, q[1].dx - q[0].dx);
              double width(List<Offset> q) => (q[1] - q[0]).distance;
              final byX = [...quads]
                ..sort((a, b) => a[0].dx.compareTo(b[0].dx));
              expect(angle(byX[0]), closeTo(-HandFan.tilt, 1e-3));
              expect(angle(byX[1]), closeTo(0, 1e-3));
              expect(angle(byX[2]), closeTo(HandFan.tilt, 1e-3));
              expect(
                width(byX[1]) / width(byX[0]),
                closeTo(HandFan.topScale, 1e-3),
              );
              expect(width(byX[2]), closeTo(width(byX[0]), 1e-3));
            }

            // Off the floor: the hand stands as high as HandFan.liftFor where
            // the pot above leaves the room, never lower than it always did,
            // and never up into the pot.
            final column = tester.getRect(
              find.byKey(const ValueKey('own-hand-column')),
            );
            final pod = tester.getRect(
              find.byWidgetPredicate((w) => w is SeatPod && w.isMe),
            );
            final pot = tester.getRect(_private('_Pot'));
            final cardH = (cards.first.widget as PlayingCard).height;
            final lift = pod.bottom - column.bottom;
            expect(
              lift,
              greaterThanOrEqualTo(TableSpace.handLift - 0.5),
              reason: '$label: never lower than it stood',
            );
            expect(
              lift,
              lessThanOrEqualTo(HandFan.liftFor(cardH) + 0.5),
              reason: '$label: lifted a little, not a lot',
            );
            if (lift > TableSpace.handLift + 0.5) {
              expect(
                column.top,
                greaterThanOrEqualTo(pot.bottom),
                reason: '$label: lifted into the pot',
              );
            }
            if (count == 3 && scale == 1.0) {
              expect(
                lift,
                closeTo(HandFan.liftFor(cardH), 0.5),
                reason: '$label: a plain hand has the room to rise',
              );
            }
            // The bet over the hand stands clear of every card.
            final bet = find.descendant(
              of: find.byKey(const ValueKey('own-hand-column')),
              matching: find.byType(SeatBet),
            );
            for (final q in quads) {
              for (var i = 0; i < bet.evaluate().length; i++) {
                expect(
                  _overlap(q, _rectQuad(tester.getRect(bet.at(i)))),
                  isFalse,
                  reason: '$label: a card is under the bet badge',
                );
              }
            }

            // Nothing the viewer presses or reads is under their cards.
            final keys = find.byWidgetPredicate(
              (w) => w is MachinedKey || w is StepperKey,
            );
            final others = <String, Rect>{
              for (var i = 0; i < keys.evaluate().length; i++)
                'key $i': tester.getRect(keys.at(i)),
              'pot': tester.getRect(_private('_Pot')),
              "viewer's pod": tester.getRect(
                find.byWidgetPredicate((w) => w is SeatPod && w.isMe),
              ),
            };
            for (final (i, q) in quads.indexed) {
              others.forEach((what, rect) {
                expect(
                  _overlap(q, _rectQuad(rect)),
                  isFalse,
                  reason: '$label: card $i is under the $what $rect',
                );
              });
              // And on the screen, whole.
              for (final corner in q) {
                expect(
                  (Offset.zero & size).inflate(0.5).contains(corner),
                  isTrue,
                  reason: '$label: card $i runs off the screen at $corner',
                );
              }
            }
            await _unmount(tester, state);
          });
        }
      }
    }

    testWidgets('a rim seat\'s cards keep their rank 8.5dp tall or more on '
        'the narrowest phone', (tester) async {
      final state = await _mount(
        tester,
        _scene('06-showdown'),
        size: const Size(592, 360),
      );
      final rim = find.descendant(
        of: find.byWidgetPredicate((w) => w is SeatPod && !w.isMe),
        matching: find.byType(PlayingCard),
      );
      expect(rim, findsWidgets);
      for (final element in rim.evaluate()) {
        final card = element.widget as PlayingCard;
        final m = CardFaceMetrics.of(card.height);
        expect(m.compact, isTrue);
        expect(
          m.rankCap,
          greaterThanOrEqualTo(8.5),
          reason: '${card.height}dp',
        );
      }
      await _unmount(tester, state);
    });

    testWidgets('the viewer\'s cards are a little larger than the table\'s '
        'hand height, and larger than any rim seat\'s', (tester) async {
      final state = await _mount(
        tester,
        _scene('06-showdown'),
        size: const Size(640, 360),
      );
      final mine = tester.widget<PlayingCard>(_ownCards.first).height;
      final rim = find.descendant(
        of: find.byWidgetPredicate((w) => w is SeatPod && !w.isMe),
        matching: find.byType(PlayingCard),
      );
      for (final element in rim.evaluate()) {
        expect(mine, greaterThan((element.widget as PlayingCard).height * 1.8));
      }
      expect(HandFan.cardScale, inInclusiveRange(1.0, 1.1));
      await _unmount(tester, state);
    });
  });

  group('the motion', () {
    testWidgets('the hand settles back, never jumps, when its name arrives '
        'over it and takes the room its lift had', (tester) async {
      final state = await _mount(
        tester,
        _scene('26-cards'),
        size: const Size(640, 360),
        textScale: 1.25,
      );
      final column = find.byKey(const ValueKey('own-hand-column'));
      final hand = _private('_OwnHand');
      final pod = find.byWidgetPredicate((w) => w is SeatPod && w.isMe);
      double lift() =>
          tester.getRect(pod).bottom - tester.getRect(column).bottom;
      final before = lift();
      final cardTop = tester.getRect(hand).top;
      expect(before, greaterThan(TableSpace.handLift + 1), reason: 'lifted');

      state.handleShowdown((
        reveals: [
          Reveal.fromJson({
            'userId': 'u0',
            'displayName': 'Priya',
            'cards': ['5c', '9c', '5d'],
            'handName': 'Pair',
            'won': false,
          }),
        ],
        result: 'show',
        winnerId: 'u1',
        winnerName: 'Ravi',
        pot: 6800,
        nextHandAt: DateTime.now().millisecondsSinceEpoch + 60000,
        reason: 'show',
      ));
      await tester.pump();
      expect(
        find.descendant(of: column, matching: find.text('Pair')),
        findsOne,
      );
      // The frame the name arrives in, the cards have not moved.
      expect(tester.getRect(hand).top, closeTo(cardTop, 0.01));
      final lifts = <double>[];
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        lifts.add(lift());
      }
      // Down, a little each frame, then still.
      for (var i = 1; i < lifts.length; i++) {
        expect(lifts[i], lessThanOrEqualTo(lifts[i - 1] + 1e-6));
        expect(lifts[i - 1] - lifts[i], lessThan(3), reason: 'no jump');
      }
      expect(lifts.last, lessThan(before));
      // Back to the step it always stood — a 640x360 phone at the text
      // ceiling has no room for the name AND the lift — and never lower.
      expect(lifts.last, closeTo(TableSpace.handLift, 0.5));
      await _unmount(tester, state);
    });

    testWidgets('a card waits its beat, then turns over', (tester) async {
      Widget card(String? code) => MaterialApp(
        home: Center(
          child: PlayingCard(
            code: code,
            height: 90,
            flipDelay: const Duration(milliseconds: 150),
          ),
        ),
      );
      Finder face() => find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is CardFacePainter,
      );
      await tester.pumpWidget(card(null));
      expect(face(), findsNothing);
      await tester.pumpWidget(card('Qd'));
      await tester.pump(const Duration(milliseconds: 120));
      expect(face(), findsNothing, reason: 'still waiting its beat');
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(PlayingCard.flipFor);
      expect(face(), findsOneWidget, reason: 'turned');
      expect(
        (tester.widget<CustomPaint>(face()).painter! as CardFacePainter).code,
        'Qd',
      );
      // And back over, after the same beat.
      await tester.pumpWidget(card(null));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(PlayingCard.flipFor);
      expect(face(), findsNothing);
    });

    testWidgets('the viewer\'s hand turns over left to right, and the seats '
        'at a showdown likewise', (tester) async {
      final state = await _mount(
        tester,
        _scene('26-cards'),
        size: const Size(732, 412),
      );
      final byX = _ownCards.evaluate().toList()
        ..sort((a, b) {
          double x(Element e) =>
              (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dx;
          return x(a).compareTo(x(b));
        });
      expect(
        [for (final e in byX) (e.widget as PlayingCard).flipDelay],
        [for (var i = 0; i < 3; i++) PlayingCard.flipStagger * i],
      );
      await _unmount(tester, state);

      // A five-card hand has turned before its best three are set out.
      expect(
        PlayingCard.flipStagger * 4 + PlayingCard.flipFor,
        lessThan(const Duration(milliseconds: 650)),
      );
    });

    testWidgets('a dealt hand arrives from the middle of the table and has '
        'landed inside 0.7 s', (tester) async {
      final state = await _mount(
        tester,
        _scene('01-opponent'),
        size: const Size(732, 412),
      );
      state.handleState(opponentTurnRoom(handNo: 8));
      await tester.pump();
      final hand = _private('_OwnHand');
      final fades = find.descendant(
        of: hand,
        matching: find.byType(FadeTransition),
      );
      final flights = find.descendant(
        of: hand,
        matching: find.byType(FractionalTranslation),
      );
      expect(fades, findsNWidgets(3));
      expect(flights, findsNWidgets(3));
      // Frame by frame, as a phone draws it: an animation started between
      // two frames begins at the next one.
      var elapsed = Duration.zero;
      var travelled = false;
      while (elapsed < const Duration(milliseconds: 700)) {
        await tester.pump(const Duration(milliseconds: 16));
        elapsed += const Duration(milliseconds: 16);
        travelled |= tester
            .widgetList<FractionalTranslation>(flights)
            .any((f) => f.translation.dy < -0.1);
      }
      expect(travelled, isTrue, reason: 'from up the table, not in place');
      expect(
        tester.widgetList<FadeTransition>(fades).map((f) => f.opacity.value),
        everyElement(1.0),
        reason: 'all three down',
      );
      expect(
        tester
            .widgetList<FractionalTranslation>(flights)
            .map((f) => f.translation),
        everyElement(Offset.zero),
        reason: 'all three in their places',
      );
      await _unmount(tester, state);
    });
  });

  group('the back', () {
    testWidgets('keeps the crown artwork, takes the SEEN green, and is cut '
        'from the same gold-edged stock as a face', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PlayingCard(height: 60),
                PlayingCard(height: 60, tint: AppTheme.cardSeenBack),
              ],
            ),
          ),
        ),
      );
      final backs = tester.widgetList<SvgPicture>(find.byType(SvgPicture));
      expect(backs, hasLength(2));
      expect(backs.first.colorFilter, isNull);
      expect(
        backs.last.colorFilter,
        const ColorFilter.mode(AppTheme.cardSeenBack, BlendMode.color),
      );
      final stock = find.byWidgetPredicate(
        (w) =>
            w is CustomPaint &&
            w.foregroundPainter is CardStockPainter &&
            !(w.foregroundPainter! as CardStockPainter).face,
      );
      expect(stock, findsNWidgets(2));
    });
  });
}
