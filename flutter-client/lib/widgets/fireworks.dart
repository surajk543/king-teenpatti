import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Fireworks over the table when a hand is won.
///
/// Painted rather than animated with widgets: a few hundred particles as
/// separate widgets would cost a rebuild each per frame, where this is one
/// canvas and one repaint. Bursts are staggered and seeded per hand, so two
/// wins in a row do not look identical.
class Fireworks extends StatefulWidget {
  const Fireworks({
    super.key,
    required this.seed,
    this.bursts = 6,
    this.focus,
  });

  /// Anything stable for this win — the hand number works — so the pattern is
  /// fixed while the celebration is on screen and different the next time.
  final int seed;
  final int bursts;

  /// Where the bursts gather, as a fraction of this widget's box. Null
  /// scatters them across it; a point clusters them there — over the winner's
  /// seat, so the celebration is about a player rather than the room.
  final Offset? focus;

  @override
  State<Fireworks> createState() => _FireworksState();
}

class _FireworksState extends State<Fireworks>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(
            size: Size.infinite,
            painter: _FireworksPainter(
              t: _c.value,
              seed: widget.seed,
              bursts: widget.bursts,
              focus: widget.focus,
              palette: [
                scheme.secondary,
                scheme.primary,
                scheme.tertiary,
                const Color(0xFFFFD54F),
                const Color(0xFFFF8A65),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FireworksPainter extends CustomPainter {
  _FireworksPainter({
    required this.t,
    required this.seed,
    required this.bursts,
    required this.focus,
    required this.palette,
  });

  final double t;
  final int seed;
  final int bursts;
  final Offset? focus;
  final List<Color> palette;

  static const int _perBurst = 26;

  @override
  void paint(Canvas canvas, Size size) {
    for (var b = 0; b < bursts; b++) {
      final rng = math.Random(seed * 977 + b * 31);

      // Each burst has its own place, colour and moment in the loop —
      // scattered across the table, or gathered around a point when one is
      // given, with enough spread that they still read as separate bursts.
      final origin = focus == null
          ? Offset(
              size.width * (0.12 + rng.nextDouble() * 0.76),
              size.height * (0.10 + rng.nextDouble() * 0.55),
            )
          : Offset(
              (focus!.dx + (rng.nextDouble() - 0.5) * 0.30) * size.width,
              (focus!.dy + (rng.nextDouble() - 0.5) * 0.30) * size.height,
            );
      final colour = palette[rng.nextInt(palette.length)];
      final start = rng.nextDouble() * 0.7;

      // Local time for this burst, wrapped into the loop.
      var local = (t - start) % 1.0;
      if (local < 0) local += 1.0;
      if (local > 0.55) continue; // spent; wait for the next cycle

      final life = local / 0.55;
      final reach = size.shortestSide * (0.20 + rng.nextDouble() * 0.16);

      for (var p = 0; p < _perBurst; p++) {
        final angle = (2 * math.pi / _perBurst) * p + rng.nextDouble() * 0.22;
        final speed = 0.65 + rng.nextDouble() * 0.35;

        // Ease out along the ray, and let gravity pull the tail down.
        final travel = reach * speed * (1 - math.pow(1 - life, 2.4));
        final gravity = size.shortestSide * 0.16 * life * life;

        final at = origin +
            Offset(math.cos(angle) * travel, math.sin(angle) * travel + gravity);

        final fade = (1 - life) * (1 - life);
        if (fade <= 0.01) continue;

        canvas.drawCircle(
          at,
          (2.6 - 1.6 * life).clamp(0.6, 3.0),
          Paint()
            ..color = colour.withValues(alpha: fade)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.2),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_FireworksPainter old) =>
      old.t != t || old.seed != seed || old.focus != focus;
}
