import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import '../theme/theme_colors.dart';
import 'fact_mark.dart';

/// The owner's back key (30 Sep 2026: "after clicking Lobby card … use this
/// back button animation for going back instead of using that icon"): an
/// arrow in a ring that gives a small press, sweeps out to the left and comes
/// back in from the right, a second and a half a loop. 1080 units square,
/// 30 fps; no 3D, no expressions, no images — a phone plays it as the file has
/// it (CLAUDE.md §12.3).
const String backMarkAsset = 'assets/animations/Back Button.json';

/// The file draws its ring and arrow in a charcoal (#2B2B2B) that all but
/// vanishes on the dark theme, so every stroke and fill of it is drawn in
/// the display ink of the card it stands on — white by night, the light
/// theme's near-black by day — as the arrow glyph it replaced was.
List<ValueDelegate<Object>> _inInk(
  Brightness brightness,
  Color Function(Color) tint,
) {
  final ink = brightness == Brightness.dark
      ? GlassColors.dark.textDisplay
      : GlassColors.light.textDisplay;
  return [
    ValueDelegate.color(const ['**'], value: ink),
    ValueDelegate.strokeColor(const ['**'], value: ink),
  ];
}

/// Where the key sits in its file: the ring spans 364–714 both ways at rest
/// and the press only draws it in (380–698 at its smallest), so that 350
/// units fills the box — the ring is the key's own edge.
const FactMarkArt backMarkArt = FactMarkArt(
  asset: backMarkAsset,
  canvas: 1080,
  centre: Offset(539, 539),
  extent: 350,
  fallback: Icons.arrow_back_rounded,
  recolour: _inInk,
);

/// A lobby level's back key ([size] across, [FactMark]): the ring and arrow of
/// the owner's Lottie in the card's display ink.
class BackMark extends StatelessWidget {
  const BackMark({super.key, required this.size, required this.fallbackInk});

  final double size;

  /// The colour of the arrow drawn instead if the file cannot be read.
  final Color fallbackInk;

  @override
  Widget build(BuildContext context) => FactMark(
    art: backMarkArt,
    size: size,
    fallbackInk: fallbackInk,
    boxKey: const ValueKey('back-mark'),
  );
}
