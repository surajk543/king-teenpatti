import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A poker chip, drawn rather than iconified.
///
/// Material has nothing that reads as a casino chip — the coin and savings
/// glyphs both say "money" but not "table stakes" — and this is small enough
/// to be worth painting: a ring, a face, and the edge dashes that make a chip
/// recognisable at 20 pixels.
class PokerChip extends StatelessWidget {
  const PokerChip({
    super.key,
    required this.colour,
    this.size = 22,
    this.dashes = 6,
  });

  final Color colour;
  final double size;
  final int dashes;

  @override
  Widget build(BuildContext context) {
    final onChip = ThemeData.estimateBrightnessForColor(colour) == Brightness.dark
        ? Colors.white
        : Colors.black87;

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _ChipPainter(colour: colour, edge: onChip, dashes: dashes),
      ),
    );
  }
}

class _ChipPainter extends CustomPainter {
  const _ChipPainter({required this.colour, required this.edge, required this.dashes});

  final Color colour;
  final Color edge;
  final int dashes;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final r = size.width / 2;

    canvas.drawCircle(centre, r, Paint()..color = colour);

    // The dashes sit in the rim, drawn as a thick stroked circle broken up by
    // wedges rather than as separate shapes.
    final rim = Paint()
      ..color = edge.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.3;

    final rect = Rect.fromCircle(center: centre, radius: r * 0.85);
    final sweep = (2 * math.pi / dashes) * 0.45;
    for (var i = 0; i < dashes; i++) {
      final start = (2 * math.pi / dashes) * i - sweep / 2;
      canvas.drawArc(rect, start, sweep, false, rim);
    }

    // The face, and a ring just inside it.
    canvas.drawCircle(centre, r * 0.62, Paint()..color = colour);
    canvas.drawCircle(
      centre,
      r * 0.62,
      Paint()
        ..color = edge.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.1,
    );
  }

  @override
  bool shouldRepaint(_ChipPainter old) =>
      old.colour != colour || old.edge != edge || old.dashes != dashes;
}

/// Three chips stacked, for a stake rather than a single coin.
class ChipStack extends StatelessWidget {
  const ChipStack({super.key, required this.colours, this.size = 22});

  final List<Color> colours;
  final double size;

  @override
  Widget build(BuildContext context) {
    final lift = size * 0.22;

    return SizedBox(
      width: size,
      height: size + lift * (colours.length - 1),
      child: Stack(
        children: [
          // Bottom of the pile first, so each chip overlaps the one below it.
          for (var i = colours.length - 1; i >= 0; i--)
            Positioned(
              top: lift * i,
              child: PokerChip(colour: colours[colours.length - 1 - i], size: size),
            ),
        ],
      ),
    );
  }
}
