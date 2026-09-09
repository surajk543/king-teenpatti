import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Champagne sparks over the table when a hand is won.
///
/// Painted rather than animated with widgets: a few hundred particles as
/// separate widgets would cost a rebuild each per frame, where this is one
/// canvas and — because every particle is one sprite out of a baked atlas —
/// one draw call. Bursts are staggered and seeded per hand, so two wins in a
/// row do not look identical.
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

/// Champagne and white gold, and nothing else.
///
/// The saturated hues this used to carry — a school-bus yellow and a salmon —
/// were the two colours that fought hardest with charcoal and emerald, and
/// they were what made a win read as a party toy rather than a table.
const List<Color> _champagne = [
  AppTheme.goldBright,
  Color(0xFFFFF4DA),
  AppTheme.gold,
  Color(0xFFE8D9AE),
  AppTheme.boneInk,
];

class _FireworksState extends State<Fireworks>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  /// One soft dot and one soft streak, baked once.
  ///
  /// Every particle used to be its own [MaskFilter] draw, which is its own
  /// small blur: 8 bursts of 26 was 208 blurs per frame, during the frame that
  /// also carries the banner, the pot flight and five pods. Out of an atlas the
  /// same particles are a single [Canvas.drawAtlas], and the count stops
  /// mattering.
  /// Built in [initState] rather than as a lazy field: `dispose` disposes it,
  /// and a lazy initialiser would construct one there if it were never read.
  late final ui.Image _sprites;

  static const double _spriteSide = 32;
  static const Rect _dot = Rect.fromLTWH(0, 0, _spriteSide, _spriteSide);
  static const Rect _streak = Rect.fromLTWH(_spriteSide, 0, 64, _spriteSide);

  static ui.Image _bakeSprites() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const white = Color(0xFFFFFFFF);

    Paint falloff(double radius, Offset centre) => Paint()
      ..shader = ui.Gradient.radial(centre, radius, [
        white,
        white.withValues(alpha: 0.55),
        white.withValues(alpha: 0),
      ], [
        0,
        0.45,
        1,
      ]);

    const middle = Offset(16, 16);
    canvas.drawCircle(middle, 16, falloff(16, middle));

    // The streak is the same falloff stretched along x, so a spark keeps its
    // soft head and gains a tail; the transform rotates it onto its own ray.
    canvas
      ..save()
      ..translate(_spriteSide, 0)
      ..scale(2, 1)
      ..drawCircle(middle, 16, falloff(16, middle))
      ..restore();

    return recorder.endRecording().toImageSync(96, _spriteSide.toInt());
  }

  @override
  void initState() {
    super.initState();
    _sprites = _bakeSprites();
  }

  @override
  void dispose() {
    _c.dispose();
    _sprites.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
              palette: _champagne,
              sprites: _sprites,
              dot: _dot,
              streak: _streak,
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
    required this.sprites,
    required this.dot,
    required this.streak,
  });

  final double t;
  final int seed;
  final int bursts;
  final Offset? focus;
  final List<Color> palette;
  final ui.Image sprites;
  final Rect dot;
  final Rect streak;

  static const int _perBurst = 30;

  /// How much of the 2600ms cycle a burst is alive for.
  static const double _life = 0.46;

  /// Sparks are sized against the box, so a tablet is not a sparse version of
  /// a phone: 360 -> 0.88 | 411 -> 1.00 | 800 -> 1.35 (landscape, so the box's
  /// short side is the screen height).
  static double _gauge(Size size) =>
      (size.shortestSide / 411).clamp(0.85, 1.35);

  @override
  void paint(Canvas canvas, Size size) {
    final gauge = _gauge(size);

    // One list per attribute, filled across every burst, spent in one call.
    final transforms = <RSTransform>[];
    final rects = <Rect>[];
    final colours = <Color>[];

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
      if (local > _life) continue; // spent; wait for the next cycle

      final life = local / _life;
      final reach = size.shortestSide * (0.20 + rng.nextDouble() * 0.16);

      // The cork's flash: bright and gone before the sparks have travelled.
      if (life < 0.22) {
        final flash = 1 - life / 0.22;
        transforms.add(RSTransform.fromComponents(
          rotation: 0,
          scale: reach * 0.16 * flash / dot.width,
          anchorX: dot.width / 2,
          anchorY: dot.height / 2,
          translateX: origin.dx,
          translateY: origin.dy,
        ));
        rects.add(dot);
        colours.add(colour.withValues(alpha: 0.32 * flash * flash));
      }

      for (var p = 0; p < _perBurst; p++) {
        // Better than half a slot of jitter, because particles on an exact
        // ring read as a sparkler wheel rather than as a burst.
        const slot = 2 * math.pi / _perBurst;
        final angle = slot * p + (rng.nextDouble() - 0.5) * slot * 1.6;
        final speed = 0.55 + rng.nextDouble() * 0.55;
        final grade = 0.7 + rng.nextDouble() * 0.6;

        // Ease out along the ray, and let gravity pull the tail down.
        final travel = reach * speed * (1 - math.pow(1 - life, 2.4));
        final gravity = size.shortestSide * 0.16 * life * life;

        final cos = math.cos(angle);
        final sin = math.sin(angle);
        final at = origin + Offset(cos * travel, sin * travel + gravity);

        final fade = (1 - life) * (1 - life);
        if (fade <= 0.01) continue;

        // A spark lies along the direction it is actually moving, which is the
        // ray early on and increasingly straight down as gravity takes over.
        final along = reach * speed * 2.4 * math.pow(1 - life, 1.4);
        final falling = size.shortestSide * 0.32 * life;
        final heading = math.atan2(sin * along + falling, cos * along);

        final length = ((7.0 - 4.5 * life) * gauge * grade).clamp(1.4, 9.0);

        transforms.add(RSTransform.fromComponents(
          rotation: heading,
          scale: length / streak.width,
          anchorX: streak.width / 2,
          anchorY: streak.height / 2,
          translateX: at.dx,
          translateY: at.dy,
        ));
        rects.add(streak);
        colours.add(colour.withValues(alpha: fade));
      }
    }

    if (transforms.isEmpty) return;

    canvas.drawAtlas(
      sprites,
      transforms,
      rects,
      colours,
      // The sprite is white, so modulating by the particle's colour tints it
      // and multiplies the two alphas — which is the fade.
      BlendMode.modulate,
      null,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_FireworksPainter old) =>
      old.t != t ||
      old.seed != seed ||
      old.bursts != bursts ||
      old.focus != focus ||
      old.sprites != sprites ||
      old.dot != dot ||
      old.streak != streak ||
      !listEquals(old.palette, palette);
}
