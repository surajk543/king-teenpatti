import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import 'fact_mark.dart';

/// The owner's piggy bank (29 Sep 2026: "use this for piggy bank for card
/// icon"): a pale blue piggy bank on a round ground, coins dropping into it,
/// a second a loop. 500 units square, 29.97 fps; no 3D, no expressions, no
/// images — a phone plays it as the file has it (CLAUDE.md §12.3).
const String potPiggyAsset = 'assets/animations/Piggy Bank.json';

/// The file's ground, a near-white blue (#EBF4FF): layer "I", the one layer
/// of that name.
const List<String> potPiggyGround = ['I', '**'];

/// The ground by day: the lock's blue ([OpenLock], #2987FF) — on a card, the
/// card's colour at that blue's luminance ([FactMark.tint]), as every other
/// part of the file is.
///
/// By night the file reads as it is — its near-white ground stands about
/// 13.7:1 on the night card, the pale pig on it as drawn. By day that ground
/// and the pig's pale blues all but vanish into the white card (1.1:1 and
/// 1.4:1), so the ground alone is set in the lock's blue: 3.5:1 on the day
/// card, the pig on it 2.5:1 and its snout 3.2:1, the coins' white "$" on
/// their blue as drawn.
const Color potPiggyDayGround = Color(0xFF2987FF);

/// The ground by day, in the card's colour at the lock blue's luminance.
List<ValueDelegate<Object>> _recolour(
  Brightness brightness,
  Color Function(Color) tint,
) => brightness == Brightness.light
    ? [ValueDelegate.color(potPiggyGround, value: tint(potPiggyDayGround))]
    : const [];

/// Where the piggy bank sits in its file: the ground, a circle 396 units
/// across at the middle of the canvas, fills the icon's box. The pig's feet
/// stand 26 units below it (a fifteenth of the box) and the coins fall inside
/// it.
const FactMarkArt potPiggyArt = FactMarkArt(
  asset: potPiggyAsset,
  canvas: 500,
  centre: Offset(249.5, 249.5),
  extent: 396,
  fallback: Icons.savings_rounded,
  recolour: _recolour,
);

/// The Pot limit row's piggy bank on a lobby table card, [size] across — the
/// box the fact row's icon had ([FactMark]).
///
/// [still] — a table the player cannot sit at, drawn faded under its padlock
/// — stands it on its first frame; the card's own fade is all the quiet it
/// needs.
class PotPiggy extends StatelessWidget {
  const PotPiggy({
    super.key,
    required this.size,
    required this.fallbackInk,
    this.tint,
    this.still = false,
  });

  final double size;

  /// The colour of the icon drawn instead if the file cannot be read.
  final Color fallbackInk;

  /// The card's colour, laid over the file's ([FactMark.tint]); none for the
  /// file's own.
  final Color? tint;

  final bool still;

  @override
  Widget build(BuildContext context) => FactMark(
    art: potPiggyArt,
    size: size,
    fallbackInk: fallbackInk,
    boxKey: const ValueKey('pot-piggy'),
    tint: tint,
    animate: !still,
  );
}
