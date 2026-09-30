import 'package:flutter/material.dart';

import 'fact_mark.dart';

/// The owner's shop (29 Sep 2026: "use this icon for Shop"): a shopfront
/// that builds itself — the walls rise, the striped awning drops, the door
/// and window appear — and then catches a glint in its window. 1000 units
/// square, 90 frames at 29 fps (3.1 s); no 3D, no expressions, no images — a
/// phone plays it as the file has it (CLAUDE.md §12.3). Its own blues and
/// whites, on the Shop key's ice face (`ShopFace` in buy_chips.dart, 30 Sep
/// 2026 — the key was struck gold until then, the icon's blue set against its
/// complement).
///
/// The file starts EMPTY and is complete from frame 40 to its end, the glint
/// drawing in between frames 54 and 60 and holding. So it is played through
/// once, the shop built as the key appears, and then from frame 40 on for as
/// long as it is on screen: the glint draws in again every 1.7 s and the key
/// is never blank.
const String shopMarkAsset = 'assets/animations/Shop.json';

/// Where the shop sits in its file: built, it spans 174–824 both ways; its
/// middle is the box's and it is drawn a little larger than the box (600 of
/// its 650 units fill it — the storefront glyph it replaced drew about 16 of
/// its 19dp), the rest in the key's padding. The build's widest moment
/// (152–846 across) stays inside that padding too.
const FactMarkArt shopMarkArt = FactMarkArt(
  asset: shopMarkAsset,
  canvas: 1000,
  centre: Offset(499, 499),
  extent: 600,
  fallback: Icons.storefront_rounded,
  loopFrom: 40 / 90,
);

/// The Shop key's shop, [size] across ([FactMark]) — the box the storefront
/// icon had, so the key keeps its width.
class ShopMark extends StatelessWidget {
  const ShopMark({super.key, required this.size, required this.fallbackInk});

  final double size;

  /// The colour of the icon drawn instead if the file cannot be read.
  final Color fallbackInk;

  @override
  Widget build(BuildContext context) => FactMark(
    art: shopMarkArt,
    size: size,
    fallbackInk: fallbackInk,
    boxKey: const ValueKey('shop-mark'),
  );
}
