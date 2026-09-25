/// The viewer's own hand, fanned: pure geometry.
library;

import 'playing_card.dart';

/// Where each card of the viewer's own hand stands, how far it leans and which
/// is on top — shared by the table's `_OwnHand`, which draws the fan, and
/// `SeatRing`, which keeps the room for it clear of the keys.
///
/// **One hand, not three cards** (premium-card brief, 25 Sep 2026: "controlled
/// overlap so the three cards read as one hand"). Three cards stand [step] of
/// a card apart — each side card shows its outer 62%, its index, its corner
/// pip and most of its centre pip — the left one turned [tilt] out one way,
/// the right one as far the other, the middle one upright, raised [proud] and
/// ON TOP, the one card whose face is whole. Because the middle card covers
/// its neighbours' inner edges, a card to its right shows only its right
/// side, and prints its index in its top-RIGHT corner
/// ([PlayingCard.indexOnRight], [indexOnRight]) so that no rank is ever under
/// another card.
///
/// **Five cards stand in the same box** (5-Card Teen Patti, CLAUDE.md §8.4):
/// their run, first card to last, is [wideRun] — 0.37 of a card a step, the
/// least that still clears each card's index once the fan's tilt has opened
/// its top — and the box is always as wide as that run, so a hand topped up
/// from three to five never takes more of the felt. Three cards are fanned
/// tighter, centred in it.
///
/// **A little more prominent than any other card** (the brief: "For the YOU
/// player, make the cards slightly more prominent"): [cardScale] of the
/// table's hand height, which the tighter overlap pays for: the box is a
/// little narrower than the old eighteen-percent overlap's (2.04 card heights
/// of the table's against 2.07) and, at [heightShare], barely taller (1.13
/// against 1.12), so nothing it stands beside moves — on a 640x360 phone the
/// column over it already reaches the pot.
abstract final class HandFan {
  /// The viewer's cards, as a multiple of the table's hand height
  /// (`Dim.handH`).
  static const double cardScale = 1.05;

  /// Between the cards of a hand of three, in card widths.
  static const double step = 0.62;

  /// First card to last of a hand of four or five, in card widths.
  static const double wideRun = 1.48;

  /// How far the outer cards lean out, in radians: 4.5°, within the brief's
  /// 3–5°. The cards between lean in proportion to where they stand.
  static const double tilt = 0.0785;

  /// The room kept each side of the run for the outer cards' lean and their
  /// shadows, as a share of the card's height.
  static const double leanShare = 0.085;

  /// How far the middle card of a plain hand stands proud of the others, as
  /// a share of its height.
  static const double proud = 0.035;

  /// The fan's box is this many card heights tall: room for the highest a
  /// card is raised (the best three of five, 0.08); the shadows under the
  /// cards, and their lean, are painted past it.
  static const double heightShare = 1.08;

  /// The viewer's card height for a table whose hand height is [handHeight].
  static double cardHeightFor(double handHeight) => handHeight * cardScale;

  static double cardWidthFor(double cardHeight) =>
      cardHeight * PlayingCard.aspect;

  /// First card to last, for a hand of [count] cards [cardWidth] wide.
  static double runFor(int count, double cardWidth) => count <= 1
      ? 0
      : count <= 3
      ? step * cardWidth * (count - 1)
      : wideRun * cardWidth;

  /// The fan's box: as wide as the widest hand, whatever this one holds.
  static double widthFor(double cardHeight) {
    final w = cardWidthFor(cardHeight);
    return w + wideRun * w + 2 * leanShare * cardHeight;
  }

  static double heightFor(double cardHeight) => cardHeight * heightShare;

  /// Where the first card of a hand of [count] stands in the box: after the
  /// lean's room, and a shorter run centred in the widest.
  static double startFor(int count, double cardHeight) {
    final w = cardWidthFor(cardHeight);
    return leanShare * cardHeight + (wideRun * w - runFor(count, w)) / 2;
  }

  /// The lean of a card standing [along] a run of [run]: [tilt] out at
  /// either end, upright in the middle.
  static double angleAt(double along, double run) =>
      run <= 0 ? 0 : (along / run - 0.5) * 2 * tilt;

  /// Whether the card in [slot] prints its index on its right: it stands to
  /// the right of the card on top, [topSlot], whose face covers its left.
  static bool indexOnRight(int slot, int topSlot) => slot > topSlot;

  /// The order [count] places are painted in, first to last: from the outside
  /// in, so the middle place is on top and each card lies over the one
  /// further out than it (left before right where two are as far out).
  static List<int> paintOrder(int count) {
    final mid = (count - 1) / 2;
    return List<int>.generate(count, (i) => i)..sort((a, b) {
      final out = (b - mid).abs().compareTo((a - mid).abs());
      return out != 0 ? out : a.compareTo(b);
    });
  }
}
