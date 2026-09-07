import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The turn clock, drawn as liquid rising inside a player's pod.
///
/// The surface ripples so it reads as something filling rather than a bar
/// growing: two sine waves at different speeds and phases, which is enough to
/// stop the crest looking mechanical. When the pod is full the player's time is
/// up, so the level is the clock and the colour is how urgent it has become.
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

  @override
  void paint(Canvas canvas, Size size) {
    if (level <= 0) return;

    // Room for the crest to rise above the level without spilling.
    final amplitude = size.height * 0.035 * (level < 0.98 ? 1 : 0.2);
    final surface = size.height * (1 - level);

    void wave(double shift, double speed, double alpha) {
      final path = Path()..moveTo(0, size.height);

      for (var x = 0.0; x <= size.width; x += 2) {
        final t = (x / size.width) * 2 * math.pi;
        final y = surface +
            math.sin(t * 1.6 + phase * 2 * math.pi * speed + shift) * amplitude;
        path.lineTo(x, y);
      }

      path
        ..lineTo(size.width, size.height)
        ..close();

      canvas.drawPath(path, Paint()..color = colour.withValues(alpha: alpha));
    }

    // A body and a lighter swell in front of it, so the liquid has depth.
    wave(0, 1.0, 0.30);
    wave(math.pi * 0.7, -0.6, 0.22);

    // A bright line on the surface, which is what sells it as a liquid.
    final crest = Path();
    for (var x = 0.0; x <= size.width; x += 2) {
      final t = (x / size.width) * 2 * math.pi;
      final y = surface + math.sin(t * 1.6 + phase * 2 * math.pi) * amplitude;
      x == 0 ? crest.moveTo(x, y) : crest.lineTo(x, y);
    }

    canvas.drawPath(
      crest,
      Paint()
        ..color = colour.withValues(alpha: 0.75)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
  }

  @override
  bool shouldRepaint(_LiquidPainter old) =>
      old.level != level || old.phase != phase || old.colour != colour;
}
