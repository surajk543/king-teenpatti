import 'package:flutter/material.dart';

import 'fact_mark.dart';

/// The owner's coins (29 Sep 2026: "use this animation in lobby cards on top
/// left for coin and change color acc to card"): a pile of gold coins, the
/// one in front spinning on its edge and a sparkle crossing the pile, two
/// seconds a loop. 800 units square, 30 fps; no 3D, no expressions, no
/// images — a phone plays it as the file has it (CLAUDE.md §12.3). On a card
/// its golds and oranges are that card's colour at their own luminances
/// ([FactMark.tint]): gold on Seen, blue on Blind, violet on Variation.
const String cardCoinsAsset = 'assets/animations/Coins.json';

/// Where the coins sit in their file: across the whole loop — the front coin
/// at its widest — they span 30–728 across and 122–684 down, and that
/// 698-unit width fills the box, so the pile never leaves it.
const FactMarkArt cardCoinsArt = FactMarkArt(
  asset: cardCoinsAsset,
  canvas: 800,
  centre: Offset(379, 403),
  extent: 698,
  fallback: Icons.toll_rounded,
);

/// The coins at the top left of a lobby card — beside a category card's name
/// and in a table card's badge — [size] across ([FactMark]), in [tint], the
/// card's colour.
class CardCoins extends StatelessWidget {
  const CardCoins({
    super.key,
    required this.size,
    required this.fallbackInk,
    this.tint,
  });

  final double size;

  /// The colour of the icon drawn instead if the file cannot be read.
  final Color fallbackInk;

  /// The card's colour, laid over the file's ([FactMark.tint]); none for the
  /// file's own.
  final Color? tint;

  @override
  Widget build(BuildContext context) => FactMark(
    art: cardCoinsArt,
    size: size,
    fallbackInk: fallbackInk,
    boxKey: const ValueKey('card-coins'),
    tint: tint,
  );
}
