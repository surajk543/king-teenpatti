/// Where the seats stand round the casino table (owner's table polish brief,
/// 25 Sep 2026: "a responsive seat-positioning system based on the table
/// bounds. Support: 2, 3, 4, 5 players ... Player positions should follow the
/// table perimeter naturally ... Do NOT use arbitrary pixel positions").
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';
import 'casino_table.dart';
import 'hand_fan.dart';

/// One place at the table, in view order: [view] 0 is the viewer, 1 the seat
/// on their left, and on clockwise round the table.
@immutable
class SeatSpot {
  const SeatSpot({
    required this.view,
    required this.angle,
    required this.anchor,
    this.head = false,
  });

  /// The place's index in view order (0 = the viewer).
  final int view;

  /// Where on the ring the place stands, in degrees measured the way the
  /// screen turns (y grows downwards): 90 the viewer at the foot, 180 the
  /// table's left end, 270 its head, 360 its right end.
  final double angle;

  /// Where the place is pinned on the felt, in the felt's own coordinates:
  ///
  /// * a seat round the rim — the middle of its column (pod, cards, bet),
  ///   which the felt positions by its centre;
  /// * the [head] seat — the top-centre of its pod, which the felt positions
  ///   by its top, with the seat's cards and bet laid beside the pod;
  /// * the viewer — x the middle of their pod, y the floor line their pod and
  ///   hand stand on (a distance up from the felt's bottom edge).
  final Offset anchor;

  /// The seat at the head of the table, across from the viewer: a two- or
  /// four-seat table has one. The head is where the category tag and the pot
  /// stand in line, so a column hung down from it would lie across both; the
  /// head seat's pod sits at the top of the felt instead, with its cards and
  /// bet BESIDE it ([SeatRing.headUnitWidth]), and the tag moves to its left.
  final bool head;

  /// Whether this is the viewer's own place.
  bool get isViewer => view == 0;
}

/// The seats round the table: a pure function of how many places the table
/// has, the table's own geometry ([TableGeometry]) and the pod's width — not
/// of who is sitting in them, so the chairs never move when a player joins or
/// leaves (an empty place keeps its chair).
///
/// **The ring.** Every seat round the rim stands on one ellipse concentric
/// with the table: [rxShare] of the table's half-width across, [ryShare] of
/// its height deep, centred [centreShare] of the way down it. A seat's column
/// is pinned on the ring by its middle, so its pod — the column's upper half —
/// is what meets the rail: the side seats' pods over the table's rounded ends,
/// the upper seats' astride its far rail. The ring sits in the upper half of
/// the table because the lower half is the viewer's: their pod and hand on the
/// near rail and the key clusters in both bottom corners, which no seat's
/// column may reach.
///
/// **The spread.** The viewer is at the foot of the table (90°). Everyone else
/// is spread evenly, clockwise from the viewer's left, over the rest of the
/// table — the arc from its left end (180°) round the head (270°) to its right
/// end (360°), the first and last seats at the two ends:
///
/// | places | the others at            |
/// |--------|--------------------------|
/// | 2      | 270 (the head)           |
/// | 3      | 180, 360                 |
/// | 4      | 180, 270 (head), 360     |
/// | 5      | 180, 240, 300, 360       |
///
/// Five places reproduce, within a dp, where the seats stood before there was
/// a ring (the columns the felt was tuned around on 10 Sep 2026): the end
/// seats flush with the felt's sides and 0.44 down it, the upper pair at 0.275
/// and 0.725 of its width and 0.30 down.
///
/// **The viewer** stands on the floor, not on the ring: their pod at
/// [viewerShare] of the felt's width with their hand fanned to its right —
/// and never so far right that the hand reaches the key cluster, nor so far
/// left that the pod reaches Missile and Pack ([keysLeftFor],
/// [leftKeysRightFor], [handWidthFor]). Not centred: the key cluster fills the
/// bottom-right corner, and on a 640dp phone the hand already ends where the
/// cluster begins; centred, it would lie under the minus key. On a narrow
/// phone (592dp: a 640dp one with its navigation bar down the side) it did
/// even at [viewerShare], and the viewer moves left until it does not; the
/// cards come first (the brief's order).
///
/// Every column is kept inside the felt, which is itself inside the safe
/// area, the rail and the felt's padding ([safe] reserves more), and — given
/// where the corner keys start ([keysTopFor]) and the top corners' controls
/// end ([cornersBottomFor]) — clear of both: where the ring would bring a
/// seat at the table's end down onto the keys at its tallest (an iPhone's
/// 844x390, whose right-hand seat on turn at the text ceiling ended on the
/// cluster's top edge), it rises off them and stops under the Shop key and
/// the wallet. On the Android phones the table was tuned on an end seat
/// rises 6dp at most, and nothing else moves.
@immutable
class SeatRing {
  const SeatRing._({
    required this.seats,
    required this.table,
    required this.podW,
    required this.spots,
    required this.bounds,
  });

  /// The ring for a table of [seats] places laid on [table], with pods
  /// [podW] wide.
  factory SeatRing.of({
    required int seats,
    required TableGeometry table,
    required double podW,
    EdgeInsets safe = EdgeInsets.zero,
    double? keysTop,
    double? cornersBottom,
    double? keysLeft,
    double? leftKeysRight,
    double handWidth = 0,
  }) {
    final n = clampSeats(seats);
    final felt = table.felt;
    final bounds = safe.deflateRect(Offset.zero & felt);
    final outer = table.outer.outerRect;
    final centre = Offset(
      outer.center.dx,
      outer.top + outer.height * centreShare,
    );
    final rx = outer.width / 2 * rxShare;
    final ry = outer.height * ryShare;

    // The viewer: at their share of the felt, their hand (fanned [Space.md]
    // right of their pod) clear of the key cluster and their pod clear of
    // Missile and Pack; where both cannot be had, the hand's is kept.
    final viewerHi = keysLeft == null
        ? double.infinity
        : keysLeft - Space.sm - handWidth - Space.md - podW / 2;
    final viewerLo = leftKeysRight == null
        ? double.negativeInfinity
        : leftKeysRight + Space.sm + podW / 2;
    final preferred = bounds.left + bounds.width * viewerShare;
    final viewerX = viewerLo <= viewerHi
        ? preferred.clamp(viewerLo, viewerHi).toDouble()
        : viewerHi;
    final spots = <SeatSpot>[
      SeatSpot(
        view: 0,
        angle: 90,
        anchor: Offset(
          _clampX(viewerX, bounds, podW),
          bounds.bottom - felt.height * floorShare,
        ),
      ),
    ];
    for (var view = 1; view < n; view++) {
      final angle = angleOf(view, n);
      final rad = angle * math.pi / 180;
      if (_isHead(angle)) {
        spots.add(
          SeatSpot(
            view: view,
            angle: angle,
            head: true,
            anchor: Offset(centre.dx, bounds.top + headTop),
          ),
        );
        continue;
      }
      final point = centre + Offset(rx * math.cos(rad), ry * math.sin(rad));
      // The corner keys are not the seats' to cover: where the ring is too
      // low for them, a column is raised until its foot — the tallest it
      // gets — stands clear of the keys' top. A seat at the table's END also
      // stands under a top corner's control (the Shop key, the wallet), and
      // is kept below it; where the two leave less room than the tallest
      // column, the keys win (the brief's order: cards, then the betting
      // controls, then the pot, then the seats).
      final half = columnShare * podW / 2;
      final hi = keysTop == null ? double.infinity : keysTop - Space.sm - half;
      final end = angle == 180 || angle == 360;
      final lo = !end || cornersBottom == null
          ? double.negativeInfinity
          : cornersBottom + Space.sm + half;
      final y = lo <= hi ? point.dy.clamp(lo, hi).toDouble() : hi;
      spots.add(
        SeatSpot(
          view: view,
          angle: angle,
          anchor: Offset(_clampX(point.dx, bounds, podW), y),
        ),
      );
    }
    return SeatRing._(
      seats: n,
      table: table,
      podW: podW,
      spots: List.unmodifiable(spots),
      bounds: bounds,
    );
  }

  /// The ring the table screen lays out: on a [felt] of that size, inside a
  /// [screen] of this one, with the pods [Dim.podW] makes of the felt and the
  /// corners' controls where the screen puts them. One function for the felt,
  /// the notices' gap and the wallet's corner, so the three cannot disagree.
  factory SeatRing.forFelt({
    required int seats,
    required Size screen,
    required Size felt,
  }) => SeatRing.of(
    seats: seats,
    table: TableGeometry.of(felt),
    podW: Dim.podW(felt.width, felt.height),
    keysTop: keysTopFor(screen, felt.height),
    cornersBottom: cornersBottomFor(screen),
    keysLeft: keysLeftFor(screen, felt.width),
    leftKeysRight: leftKeysRightFor(screen),
    handWidth: handWidthFor(Dim.handH(felt.height)),
  );

  /// The fewest and most places a table lays out. The server's
  /// MAX_PLAYERS_PER_ROOM is 2..5 (§7.4); a 0 (a config never sent) is five.
  static const int minSeats = 2;
  static const int maxSeats = 5;

  /// [seats] held to what the ring can lay out.
  static int clampSeats(int seats) =>
      seats <= 0 ? maxSeats : seats.clamp(minSeats, maxSeats);

  /// Where the ring's centre is, as a share of the table's height from its
  /// outer top edge. 0.24 + 0.284 x 0.705 = 0.440 of the felt's height.
  static const double centreShare = 0.284;

  /// The ring's half-width, as a share of the table's half-width.
  /// 0.922 x 0.488 = 0.450 of the felt's width: the upper pair at 0.275 and
  /// 0.725 of it, and the ends at 0.05 and 0.95 — inside half a pod of the
  /// felt's sides on every phone, so the end seats stand flush with them.
  static const double rxShare = 0.922;

  /// The ring's half-height, as a share of the table's height.
  /// 0.23 x 0.705 = 0.162 of the felt's height.
  static const double ryShare = 0.23;

  /// Where the viewer's pod stands, as a share of the felt's width, wherever
  /// the corner keys leave it room to (see the class doc): the place the felt
  /// was tuned with, as far towards the middle as the hand goes and still
  /// clears the key cluster on the phones from 732dp up; on a 640dp phone the
  /// keys hold it 10dp to the left of this.
  static const double viewerShare = 0.265;

  /// How far up from the felt's bottom edge the viewer's pod and hand stand,
  /// as a share of the felt's height.
  static const double floorShare = 0.012;

  /// How far down from the top of the felt the head seat's pod starts.
  static const double headTop = Space.xs;

  /// The tallest a rim seat's column gets, as a multiple of its pod's width:
  /// pod, cards, bet and In Pot, with the turn's ring round the pod — 1.86
  /// to 2.05 measured at the phone sizes, the text ceiling included.
  static const double columnShare = 2.05;

  /// Where the corner keys start, down a felt [feltHeight] tall on a screen
  /// of [screen]: the Missile key over Pack on the left and the key cluster's
  /// two rows on the right, each [Dim.keyH] tall and [Dim.gap] apart and off
  /// the foot, which the felt's own foot is (the table screen's layout).
  static double keysTopFor(Size screen, double feltHeight) =>
      feltHeight - 2 * Dim.keyH(screen.height) - 2 * Dim.gap(screen.width);

  /// Where the key cluster starts, across a felt [feltWidth] wide on a
  /// [screen]: its two rows are each two [Dim.minTouch] keys (the steppers,
  /// or Force Sideshow) and a [Dim.keyW] key, [Dim.gap] apart, standing the
  /// felt's own padding in from the safe edge — which is where the felt ends.
  static double keysLeftFor(Size screen, double feltWidth) =>
      feltWidth -
      (2 * Dim.minTouch + 2 * Dim.gap(screen.width) + Dim.keyW(screen.width));

  /// Where Missile and Pack end, across the felt: a [Dim.keyW] key the felt's
  /// padding in from the safe edge, where the rail stands before the felt.
  static double leftKeysRightFor(Size screen) =>
      Dim.keyW(screen.width) - Dim.railW(screen.width);

  /// How wide the viewer's fanned hand is on a table whose hand height is
  /// [handHeight] (`Dim.handH`): [HandFan]'s box, which the table screen's
  /// `_OwnHand` draws whatever the hand holds.
  static double handWidthFor(double handHeight) =>
      HandFan.widthFor(HandFan.cardHeightFor(handHeight));

  /// Where the top corners' controls end — the Shop key, the wallet — down
  /// the felt on a screen of [screen]: a touch target [Dim.gap] down from
  /// the safe area's top, which the felt starts [Space.xxs] below.
  static double cornersBottomFor(Size screen) =>
      Dim.gap(screen.width) + Dim.minTouch - Space.xxs;

  /// The angle of the place [view] (1..[seats]-1) at a table of [seats].
  static double angleOf(int view, int seats) {
    final n = clampSeats(seats);
    if (view <= 0) return 90;
    if (n == 2) return 270;
    return 180 + (view - 1) * 180 / (n - 2);
  }

  static bool _isHead(double angle) => (angle - 270).abs() < 1e-6;

  static double _clampX(double x, Rect bounds, double podW) {
    final lo = bounds.left + podW / 2;
    final hi = bounds.right - podW / 2;
    return hi < lo ? bounds.center.dx : x.clamp(lo, hi).toDouble();
  }

  /// How many places the table has.
  final int seats;

  /// The table the ring is laid round.
  final TableGeometry table;

  /// The pods' width, which the columns are kept inside the felt by.
  final double podW;

  /// Every place, in view order: [spots] `[0]` is the viewer.
  final List<SeatSpot> spots;

  /// The box every column is kept inside: the felt, less any [safe] inset.
  final Rect bounds;

  /// The places round the rim, the head seat included, in view order.
  Iterable<SeatSpot> get rim => spots.skip(1);

  /// The head seat, when the table has one.
  SeatSpot? get head {
    for (final spot in rim) {
      if (spot.head) return spot;
    }
    return null;
  }

  /// The gap between the head seat's pod and the cards and bet beside it, as
  /// a share of the pod's width ([SeatPod.beside] lays it out).
  static const double headGapShare = 0.08;

  /// The gap between the head seat's pod and the cards and bet beside it.
  double get headGap => podW * headGapShare;

  /// How wide the head seat stands: its pod, the gap, and a column of cards
  /// and bet as wide as a pod. Laid from the pod's left edge.
  double get headUnitWidth => 2 * podW + headGap;

  /// Where the head seat's unit starts, its pod centred on the head.
  double get headLeft => (head?.anchor.dx ?? bounds.center.dx) - podW / 2;

  /// The head seat's pod, as tall as it is wide ([SeatPod]'s plaque is never
  /// taller than it is wide above a 70dp pod).
  Rect? get headPod {
    final h = head;
    if (h == null) return null;
    return Rect.fromLTWH(h.anchor.dx - podW / 2, h.anchor.dy, podW, podW);
  }

  /// Where a place's flights land and leave from — a bet, a dealt card, the
  /// pot going to its winner, the sideshow's link. [floorY] is the height the
  /// viewer's are drawn at (their column stands on the floor).
  Offset centreOf(int view, {required double floorY}) {
    final spot = spots[view.clamp(0, spots.length - 1)];
    if (spot.isViewer) return Offset(spot.anchor.dx, floorY);
    if (spot.head) return spot.anchor + Offset(0, podW / 2);
    return spot.anchor;
  }

  /// Where the category tag stands: in the middle of the far rail's top edge,
  /// [width] wide and centred at [centreY] — or, when a seat has the head of
  /// the table, beside that seat's pod on its left, as wide as the room there
  /// allows, clear of the Shop key's corner (half a pod in from the felt's
  /// left edge).
  Rect tagSlot({
    required double width,
    required double centreY,
    double height = 0,
  }) {
    final pod = headPod;
    if (pod == null) {
      return Rect.fromCenter(
        center: Offset(bounds.center.dx, centreY),
        width: width,
        height: height,
      );
    }
    final right = pod.left - Space.md;
    final left = math.max(bounds.left + podW / 2, right - width);
    return Rect.fromLTRB(
      math.min(left, right),
      centreY - height / 2,
      right,
      centreY + height / 2,
    );
  }
}
