import 'package:flutter/material.dart';

import 'fact_mark.dart';

/// The owner's rule book (29 Sep 2026: "use this icon for rule book on
/// card"): a closed book with a bookmark hopping up and flicking its pages
/// open and shut over its shadow, two seconds a loop. 500 units square,
/// 30 fps; no 3D, no expressions, no images — a phone plays it as the file has
/// it (CLAUDE.md §12.3). A black outline round a blue cover, white pages and
/// a yellow bookmark and page edges; on a card, its blues and yellows are
/// that card's colour at their own luminances ([FactMark.tint]), the outline
/// and the pages as drawn.
const String ruleBookAsset = 'assets/animations/Rule Book.json';

/// Where the book sits in its file: across the whole loop — the hop, the
/// pages at their widest, the shadow — it spans 76–423 across and 7–441 down,
/// and that 434-unit height fills the key's box, so the book never leaves it.
const FactMarkArt ruleBookArt = FactMarkArt(
  asset: ruleBookAsset,
  canvas: 500,
  centre: Offset(249.5, 224),
  extent: 434,
  fallback: Icons.menu_book_outlined,
);

/// The rules key's book on a lobby table card, [size] across ([FactMark]),
/// in [tint], the card's colour.
class RuleBook extends StatelessWidget {
  const RuleBook({
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
    art: ruleBookArt,
    size: size,
    fallbackInk: fallbackInk,
    boxKey: const ValueKey('rule-book'),
    tint: tint,
  );
}
