import 'package:flutter/material.dart';

import 'fact_mark.dart';

/// The owner's lock (29 Sep 2026: "use this lock animation on lobby card
/// instead of using lock icons in front of text 'open to you'. Make sure it
/// look visible in dark and night mode"): a white padlock breathing between
/// 95% and 105% on a blue disc, a paler copy of the disc circling behind it,
/// three seconds a loop. 210 units square, 29.97 fps; no 3D, no expressions,
/// no images — a phone plays it as the file has it (CLAUDE.md §12.3).
///
/// The blue disc (#2987FF) stands clear of both the night card (rgb
/// 35,38,42) and the day card (white) — about 4.7:1 and 3.5:1, over the 3:1
/// a mark needs — and the white lock on the blue reads the same on either
/// ground. On a card it is drawn in that card's colour at the same
/// luminances ([FactMark.tint]), so those figures hold in gold and violet
/// too.
const String openLockAsset = 'assets/animations/Lock.json';

/// The blue disc's diameter as a share of the file's canvas: an ellipse 100
/// across, centred on the 210-unit square. The circling copy behind it stands
/// out past the disc by at most 17 units (15 of travel and half its stroke),
/// at a fifth of its strength.
const double openLockDiscShare = 100 / 210;

/// Where the lock sits in its file: the disc at the middle of the canvas fills
/// the icon's box.
const FactMarkArt openLockArt = FactMarkArt(
  asset: openLockAsset,
  canvas: 210,
  centre: Offset(105, 105),
  extent: 100,
  fallback: Icons.lock_open_rounded,
);

/// The open lock, its disc [size] across — the box the fact row's icon had
/// ([FactMark]).
///
/// The circling copy spills at most a sixth of [size] past the box, inside
/// the gap the row leaves beside it.
///
/// [quiet] — no table open — stands the lock still and faded, as the row says
/// its "0" quietly; otherwise it loops for as long as it is on screen.
class OpenLock extends StatelessWidget {
  const OpenLock({
    super.key,
    required this.size,
    required this.fallbackInk,
    this.tint,
    this.quiet = false,
  });

  /// The disc's diameter, and the square the lock takes in layout.
  final double size;

  /// The colour of the icon drawn instead if the file cannot be read.
  final Color fallbackInk;

  /// The card's colour, laid over the file's ([FactMark.tint]); none for the
  /// file's own.
  final Color? tint;

  /// Still and faded, for a count of nothing.
  final bool quiet;

  /// The strength of a [quiet] lock.
  static const double quietOpacity = 0.45;

  @override
  Widget build(BuildContext context) => FactMark(
    art: openLockArt,
    size: size,
    fallbackInk: fallbackInk,
    boxKey: const ValueKey('open-lock'),
    tint: tint,
    animate: !quiet,
    opacity: quiet ? quietOpacity : 1,
  );
}
