import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The two ends of the colour behind a glass card: a colour brightened until it
/// reads as light, and a neighbour on the colour wheel so the orb has a
/// direction the way a lit object does — warm colours lean warmer, violets lean
/// magenta.
(Color, Color) orbColours(Color base) {
  final lead = HSLColor.fromColor(
    base,
  ).withSaturation(0.88).withLightness(0.58);
  final shift = lead.hue >= 240 && lead.hue <= 330 ? 32.0 : -34.0;
  return (lead.toColor(), lead.withHue((lead.hue + shift) % 360).toColor());
}

/// A disc of colour behind a glass card — or, [soft], the same disc as the
/// card's glass shows it.
///
/// Neither the lobby nor the table can afford a live backdrop blur: chips drift
/// behind the lobby's rail, the table's lamp breathes and its bet flights fly,
/// and there is one GlassBudget lease for a whole screen. So the blur is baked.
/// The sharp disc is drawn behind the card and a pre-blurred copy in the
/// glass's `behind` slot at the same place, and the pair reads as colour seen
/// through frosted glass. Neither ever changes, so each is rasterised once and
/// only composited after that.
class GlassOrb extends StatelessWidget {
  const GlassOrb({
    super.key,
    required this.colours,
    required this.size,
    required this.opacity,
    this.soft = false,
  });

  final (Color, Color) colours;
  final double size;
  final double opacity;
  final bool soft;

  @override
  Widget build(BuildContext context) {
    final disc = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colours.$1.withValues(alpha: opacity),
            colours.$2.withValues(alpha: opacity),
          ],
        ),
      ),
    );
    final sigma = size * 0.16;
    return RepaintBoundary(
      child: soft
          ? ImageFiltered(
              imageFilter: ui.ImageFilter.blur(
                sigmaX: sigma,
                sigmaY: sigma,
                tileMode: ui.TileMode.decal,
              ),
              child: disc,
            )
          : disc,
    );
  }
}
