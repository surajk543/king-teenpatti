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

/// A chip that turns over now and then.
///
/// It spins rather than spinning continuously: a chip revolving forever in the
/// corner of a lobby card is movement the eye has to keep dismissing. One turn,
/// then a few seconds of stillness, reads as a flourish instead.
class SpinningChip extends StatefulWidget {
  const SpinningChip({
    super.key,
    required this.colour,
    this.size = 22,
    this.turn = const Duration(milliseconds: 1100),
    this.rest = const Duration(milliseconds: 3400),
    this.delay = Duration.zero,
  });

  final Color colour;
  final double size;

  /// How long one revolution takes, and how long the chip sits still between
  /// revolutions.
  final Duration turn;
  final Duration rest;

  /// Staggers this chip against its neighbours, so a row of them does not turn
  /// in lockstep.
  final Duration delay;

  @override
  State<SpinningChip> createState() => _SpinningChipState();
}

class _SpinningChipState extends State<SpinningChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.turn + widget.rest,
  );

  /// Where in the cycle the turn ends and the rest begins.
  late final double _spinsUntil =
      widget.turn.inMilliseconds / (widget.turn + widget.rest).inMilliseconds;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(widget.delay, () {
      if (mounted) _c.repeat();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        child: PokerChip(colour: widget.colour, size: widget.size),
        builder: (context, chip) {
          final t = _c.value;
          // Eased through the turn so it starts and stops softly, then flat
          // through the rest.
          final angle = t >= _spinsUntil
              ? 0.0
              : Curves.easeInOutCubic.transform(t / _spinsUntil) * math.pi * 2;

          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              // A little perspective, or the chip reads as squashing rather
              // than turning.
              ..setEntry(3, 2, 0.0015)
              ..rotateY(angle),
            child: chip,
          );
        },
      ),
    );
  }
}

/// A stack of chips that drops into place on first paint and then breathes.
///
/// The chips land one after another from the bottom of the pile up, which is
/// the order they would be set down in.
class LivelyChipStack extends StatefulWidget {
  const LivelyChipStack({super.key, required this.colours, this.size = 22});

  final List<Color> colours;
  final double size;

  @override
  State<LivelyChipStack> createState() => _LivelyChipStackState();
}

class _LivelyChipStackState extends State<LivelyChipStack>
    with SingleTickerProviderStateMixin {
  /// The idle float, once everything has landed. Slow and small: this is the
  /// pile settling, not bouncing.
  late final AnimationController _float = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  )..repeat();

  @override
  void dispose() {
    _float.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lift = widget.size * 0.22;
    final count = widget.colours.length;

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _float,
        builder: (context, _) => Transform.translate(
          offset: Offset(0, math.sin(_float.value * math.pi * 2) * 1.4),
          child: SizedBox(
            width: widget.size,
            height: widget.size + lift * (count - 1),
            child: Stack(
              children: [
                // Bottom of the pile first, so each chip overlaps the one below.
                for (var i = count - 1; i >= 0; i--)
                  Positioned(
                    top: lift * i,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      // The lower a chip is in the pile, the sooner it lands.
                      duration: Duration(milliseconds: 420 + (count - 1 - i) * 130),
                      curve: Curves.easeOutBack,
                      builder: (context, landed, chip) => Transform.translate(
                        offset: Offset(0, -22 * (1 - landed)),
                        child: Opacity(opacity: landed.clamp(0.0, 1.0), child: chip),
                      ),
                      child: PokerChip(
                        colour: widget.colours[count - 1 - i],
                        size: widget.size,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
