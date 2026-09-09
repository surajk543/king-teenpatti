import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The turn clock, drawn as liquid rising inside a player's pod.
///
/// The surface ripples so it reads as something filling rather than a bar
/// growing: two sine waves at different speeds and phases, which is enough to
/// stop the crest looking mechanical. When the pod is full the player's time is
/// up, so the level is the clock and the colour is how urgent it has become.
///
/// Nothing here can end a turn. The deadline is the server's, the server
/// enforces the timeout, and no clock-skew correction is applied — a pod that
/// fills a little early or late is a cosmetic error, whereas a client that
/// believed its own arithmetic would be a rules error.
class LiquidFill extends StatefulWidget {
  const LiquidFill({
    super.key,
    required this.deadlineMs,
    required this.totalMs,
    required this.colour,
  });

  /// When this player's turn runs out, in epoch milliseconds, and how long the
  /// turn was to begin with.
  ///
  /// The level is worked out here, once per frame, rather than being handed in
  /// as a number: the game state only republishes about once a second, and a
  /// level that steps once a second is exactly what makes a rising liquid look
  /// like it is stuttering.
  final int deadlineMs;
  final int totalMs;
  final Color colour;

  @override
  State<LiquidFill> createState() => _LiquidFillState();
}

class _LiquidFillState extends State<LiquidFill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  /// How full the pod is right now, straight off the wall clock.
  double _level() {
    if (widget.totalMs <= 0) return 0;

    final left = widget.deadlineMs - DateTime.now().millisecondsSinceEpoch;
    return (1 - left / widget.totalMs).clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The pod around this repaints on every seat update; the liquid repaints on
    // every frame. Without the boundary the second rate wins and the whole pod
    // — gradient, border and three shadows — re-rasterises at 60fps.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _wave,
        builder: (context, _) => CustomPaint(
          size: Size.infinite,
          painter: _LiquidPainter(
            level: _level(),
            phase: _wave.value,
            colour: widget.colour,
          ),
        ),
      ),
    );
  }
}

class _LiquidPainter extends CustomPainter {
  const _LiquidPainter({
    required this.level,
    required this.phase,
    required this.colour,
  });

  final double level;
  final double phase;
  final Color colour;

  /// The meniscus, against the pod's short side.
  ///
  /// A fixed 1.4dp line was the whole liquid at a 56dp pod and invisible at
  /// 148dp. Pod widths run about 82.6 at h=360, 92.6 at h=411 and the 148
  /// ceiling at h=800, so the champagne line lands at 1.82 | 2.04 | 2.40dp —
  /// the clamp floor only bites on a pod smaller than the felt can produce.
  static double _meniscus(Size size) =>
      (size.shortestSide * 0.022).clamp(1.0, 2.4);

  /// The crest, sampled coarsely enough that a tablet-sized pod is not a
  /// hundred-segment path and finely enough that a small one is still a curve.
  Path _surfacePath(Size size, double surface, double amplitude, double speed,
      double shift) {
    final step = math.max(2.0, size.width / 48);
    final path = Path();

    for (var x = 0.0; x <= size.width; x += step) {
      final t = (x / size.width) * 2 * math.pi;
      final y = surface +
          math.sin(t * 1.6 + phase * 2 * math.pi * speed + shift) * amplitude;
      x == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }

    // The loop can stop short of the right edge; sample it exactly.
    final edge = 2 * math.pi * 1.6 + phase * 2 * math.pi * speed + shift;
    return path..lineTo(size.width, surface + math.sin(edge) * amplitude);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (level <= 0) return;

    // Room for the crest to rise above the level without spilling.
    final amplitude = size.height * 0.035 * (level < 0.98 ? 1 : 0.2);
    final surface = size.height * (1 - level);
    final line = _meniscus(size);

    Path body(double shift, double speed) =>
        _surfacePath(size, surface, amplitude, speed, shift)
          ..lineTo(size.width, size.height)
          ..lineTo(0, size.height)
          ..close();

    // The body is denser at the bottom than at the surface, which is what
    // makes it read as a volume of liquid rather than a tinted rectangle.
    final fill = Rect.fromLTRB(
      0,
      math.min(surface, size.height - 1),
      size.width,
      size.height,
    );
    canvas.drawPath(
      body(0, 1.0),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          // Read against a PALE plaque, not a dark one. These alphas were set
          // when the turn colour was a saturated green; champagne at a third
          // of an alpha on a bone pod is a rumour, not a clock.
          colors: [
            colour.withValues(alpha: 0.72),
            colour.withValues(alpha: 0.34),
          ],
        ).createShader(fill),
    );

    // A slower swell running the other way, so the surface is never one wave.
    canvas.drawPath(
      body(math.pi * 0.7, -0.6),
      Paint()..color = colour.withValues(alpha: 0.30),
    );

    final crest = _surfacePath(size, surface, amplitude, 1.0, 0);

    // Light bending through the meniscus: the same liquid, a band thick,
    // sitting above the line rather than below it.
    canvas.drawPath(
      Path.from(crest)
        ..lineTo(size.width, surface - line * 2)
        ..lineTo(0, surface - line * 2)
        ..close(),
      Paint()..color = colour.withValues(alpha: 0.26),
    );

    // Champagne, not the urgency colour: the body carries how much time is
    // left, and a gold line is the one thing on the pod that says liquid.
    canvas
      ..drawPath(
        crest,
        Paint()
          ..color = AppTheme.goldDeep.withValues(alpha: 0.45)
          ..style = PaintingStyle.stroke
          ..strokeWidth = line * 1.8
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.height * 0.02),
      )
      ..drawPath(
        crest,
        Paint()
          ..color = AppTheme.goldDeep.withValues(alpha: 0.95)
          ..style = PaintingStyle.stroke
          ..strokeWidth = line,
      );
  }

  @override
  bool shouldRepaint(_LiquidPainter old) =>
      old.level != level || old.phase != phase || old.colour != colour;
}
