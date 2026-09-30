import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import 'fact_mark.dart';

/// The owner's info mark (29 Sep 2026: "use this icon for info on top right
/// for seen 200 table, 50000 table, blind 200, blind 50000, variation etc.
/// and change color acc to card type"): an "i" in a ring, with waves rippling
/// out of it and fading, two seconds a loop. 120 units square, 23.976 fps; no
/// 3D, no expressions, no images — a phone plays it as the file has it
/// (CLAUDE.md §12.3). On a card its grey "i" and blue waves are that card's
/// colour at their own luminances ([FactMark.tint]).
const String infoWaveAsset = 'assets/animations/Info icon wave.json';

/// The "i" and its ring: layer "i Outlines", the one layer of that name.
const List<String> infoWaveGlyph = ['i Outlines', '**'];

/// The "i" and its ring by day: a slate, 5.9:1 on the white card — the file's
/// pale grey (#ACB6C3) is 2.1:1 there, where the icon it replaced was the
/// card's ink. By night the file's grey stands 7.4:1 on the card, as it is.
const Color infoWaveDayGlyph = Color(0xFF5B6574);

/// The "i" by day, in the card's colour at the slate's luminance.
List<ValueDelegate<Object>> _recolour(
  Brightness brightness,
  Color Function(Color) tint,
) => brightness == Brightness.light
    ? [
        ValueDelegate.color(infoWaveGlyph, value: tint(infoWaveDayGlyph)),
        ValueDelegate.strokeColor(infoWaveGlyph, value: tint(infoWaveDayGlyph)),
      ]
    : const [];

/// Where the mark sits in its file: the waves at their widest span 4–116 both
/// ways round the middle, and that 112 units fills the box, so no ripple
/// leaves the key's disc; the ring round the "i" (layer "Shape Layer 3",
/// 34–86) is then 12dp in a 26dp box, about the ring of the info glyph it
/// replaced.
const FactMarkArt infoWaveArt = FactMarkArt(
  asset: infoWaveAsset,
  canvas: 120,
  centre: Offset(60, 60),
  extent: 112,
  fallback: Icons.info_outline_rounded,
  recolour: _recolour,
);

/// A table card's info key's mark, filling the key's disc ([size] across,
/// [FactMark]), in [tint], the card's colour.
class InfoWave extends StatelessWidget {
  const InfoWave({
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
    art: infoWaveArt,
    size: size,
    fallbackInk: fallbackInk,
    boxKey: const ValueKey('info-wave'),
    tint: tint,
  );
}
