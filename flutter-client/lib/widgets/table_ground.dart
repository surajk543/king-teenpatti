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

  /// The room by day: pearl rather than the app's cool grey (owner's brief,
  /// 25 Sep 2026: "LIGHT MODE: pearl/white background ... Avoid excessive
  /// gray"), closing to a warm stone at its corners — the pearl rail and the
  /// champagne rim of the table stand in it as in a lit room.
  static const Color pearl = Color(0xFFFAF8F4);
  static const Color pearlEdge = Color(0xFFE6E0D4);

  @override
  Widget build(BuildContext context) => _Ground(
        lamp: lamp,
        lampAlpha: 0.075,
        lampSpread: 0.95,
        vignette: 0.62,
        accent: accent,
        lightBase: pearl,
        lightEdge: pearlEdge,
        child: child,
      );
}

/// The same room, arranged for the lobby: the light is centred and softer,
/// because there is no one object here to sit under it.
class LobbyGround extends StatelessWidget {
  const LobbyGround({
    super.key,
    required this.child,
    this.accent,
    this.accentStrength = 1,
  });

  final Widget child;
  final Color? accent;

  /// How much of [accent] the lamp's pool carries, as a multiple of the
  /// table's whisper: the lobby lets the open level's colour into the room as
  /// its ambient light, and asks for more of it than a table does.
  final double accentStrength;

  @override
  Widget build(BuildContext context) => _Ground(
        lamp: const Alignment(-0.15, -0.35),
        lampAlpha: 0.05,
        lampSpread: 1.25,
        vignette: 0.48,
        accent: accent,
        accentStrength: accentStrength,
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
    this.accentStrength = 1,
    this.lightBase,
    this.lightEdge,
  });

  final Widget child;
  final Alignment lamp;
  final double lampAlpha;
  final double lampSpread;
  final double vignette;
  final Color? accent;
  final double accentStrength;

  /// The floor and its corners by day, when not the app's own ground.
  final Color? lightBase;
  final Color? lightEdge;

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
              base: dark
                  ? AppTheme.ground(brightness)
                  : lightBase ?? AppTheme.ground(brightness),
              edge: dark
                  ? AppTheme.groundEdge(brightness)
                  : lightEdge ?? AppTheme.groundEdge(brightness),
              lampColour: AppTheme.lampWarm,
              // A warm pool reads on charcoal and turns parchment yellow, so
              // light mode gets a fraction of it.
              lampAlpha: dark ? lampAlpha : lampAlpha * 0.45,
              lamp: lamp,
              lampSpread: lampSpread,
              vignette: dark ? vignette : vignette * 0.45,
              accent: accent,
              accentAlpha: (dark ? 0.05 : 0.035) * accentStrength,
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
