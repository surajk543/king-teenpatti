import 'package:flutter/material.dart';

import 'fact_mark.dart';

/// The owner's casino chips (1 Oct 2026: "Use this animation on top left of
/// lobby cards, change colour acc to card"): ten chips dropped one on another
/// into a stack over its first 1.7 seconds, the top one last, which then
/// stands to the end of a four-second loop. 400 units square, 30 fps; no 3D,
/// no expressions, no images — a phone plays it as the file has it
/// (CLAUDE.md §12.3). It replaced the owner's pile of coins (29 Sep 2026,
/// Coins.json, in git history). On a card its golds are that card's colour at
/// their own luminances ([FactMark.tint]): gold on Seen, blue on Blind, violet
/// on Variation; the chips' white faces and grey sides stay as they are.
const String cardChipsAsset = 'assets/animations/Casino Chips.json';

/// Where the chips sit in their file: across the whole loop — the top chip
/// pops in 30 units above where it lands — they span 106–294 across and 5–367
/// down, and that 362-unit height fills the box, so the stack never leaves
/// it. The standing stack (35–367 down) is 0.92 of the box's height and 0.52
/// of its width.
const FactMarkArt cardChipsArt = FactMarkArt(
  asset: cardChipsAsset,
  canvas: 400,
  centre: Offset(200, 186),
  extent: 362,
  fallback: Icons.toll_rounded,
);

/// The chips at the top left of a lobby card — beside a category card's name
/// and in a table card's badge — [size] across ([FactMark]), in [tint], the
/// card's colour.
class CardChips extends StatelessWidget {
  const CardChips({
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
    art: cardChipsArt,
    size: size,
    fallbackInk: fallbackInk,
    boxKey: const ValueKey('card-chips'),
    tint: tint,
  );
}
