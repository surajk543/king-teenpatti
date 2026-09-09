import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The room the felt sits in.
///
/// A deep charcoal floor, one warm pool where the lamp hangs over the table,
/// and a vignette that closes the corners so the eye is pulled to the middle.
/// It is opaque and completely static — no controller, no `BlendMode` other
/// than the default — which is what lets everything above it animate without
/// dragging a full-screen gradient through the raster on every frame.
class TableGround extends StatelessWidget {
  const TableGround({
    super.key,
    required this.child,
    this.accent,
    this.lamp = const Alignment(0, -0.5),
  });

  final Widget child;

  /// A whisper of the table's own identity in the room, so the lobby card a
  /// player tapped and the room they land in are the same colour.
  final Color? accent;

  /// Where the overhead pool falls. The table is above centre, so the light is
  /// too.
  final Alignment lamp;

  @override
  Widget build(BuildContext context) => _Ground(
        lamp: lamp,
        lampAlpha: 0.075,
        lampSpread: 0.95,
        vignette: 0.62,
        accent: accent,
        child: child,
      );
}

/// The same room, arranged for the lobby: the light is centred and softer,
/// because there is no one object here to sit under it.
class LobbyGround extends StatelessWidget {
  const LobbyGround({super.key, required this.child, this.accent});

  final Widget child;
  final Color? accent;

  @override
  Widget build(BuildContext context) => _Ground(
        lamp: const Alignment(-0.15, -0.35),
        lampAlpha: 0.05,
        lampSpread: 1.25,
        vignette: 0.48,
        accent: accent,
        child: child,
      );
}

class _Ground extends StatelessWidget {
  const _Ground({
    required this.child,
    required this.lamp,
    required this.lampAlpha,
    required this.lampSpread,
    required this.vignette,
    required this.accent,
  });

  final Widget child;
  final Alignment lamp;
  final double lampAlpha;
  final double lampSpread;
  final double vignette;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final dark = brightness == Brightness.dark;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Its own layer: the ground never changes, and everything painted over
        // it does. Without the boundary a breathing lamp three layers up
        // re-rasterises this gradient sixty times a second.
        RepaintBoundary(
          child: CustomPaint(
            isComplex: true,
            willChange: false,
            painter: _GroundPainter(
              base: AppTheme.ground(brightness),
              edge: AppTheme.groundEdge(brightness),
              lampColour: AppTheme.lampWarm,
              // A warm pool reads on charcoal and turns parchment yellow, so
              // light mode gets a fraction of it.
              lampAlpha: dark ? lampAlpha : lampAlpha * 0.45,
              lamp: lamp,
              lampSpread: lampSpread,
              vignette: dark ? vignette : vignette * 0.45,
              accent: accent,
              accentAlpha: dark ? 0.05 : 0.035,
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class _GroundPainter extends CustomPainter {
  const _GroundPainter({
    required this.base,
    required this.edge,
    required this.lampColour,
    required this.lampAlpha,
    required this.lamp,
    required this.lampSpread,
    required this.vignette,
    required this.accent,
    required this.accentAlpha,
  });

  final Color base;
  final Color edge;
  final Color lampColour;
  final double lampAlpha;
  final Alignment lamp;
  final double lampSpread;
  final double vignette;
  final Color? accent;
  final double accentAlpha;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = base);

    final centre = lamp.alongSize(size);
    final pool = Rect.fromCircle(
      center: centre,
      radius: size.shortestSide * lampSpread,
    );

    if (accent != null && accentAlpha > 0) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            colors: [
              accent!.withValues(alpha: accentAlpha),
              accent!.withValues(alpha: 0),
            ],
          ).createShader(pool),
      );
    }

    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          colors: [
            lampColour.withValues(alpha: lampAlpha),
            lampColour.withValues(alpha: 0),
          ],
          stops: const [0, 1],
        ).createShader(pool),
    );

    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          radius: 0.9,
          colors: [
            edge.withValues(alpha: 0),
            edge.withValues(alpha: vignette),
          ],
          stops: const [0.42, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GroundPainter old) =>
      old.base != base ||
      old.edge != edge ||
      old.lampColour != lampColour ||
      old.lampAlpha != lampAlpha ||
      old.lamp != lamp ||
      old.lampSpread != lampSpread ||
      old.vignette != vignette ||
      old.accent != accent ||
      old.accentAlpha != accentAlpha;
}
