import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme/app_theme.dart';
import '../theme/theme_colors.dart';
import 'glass_orb.dart';
import 'premium_surface.dart';

/// The steps inside a lobby card, on the 4dp grid the owner's final polish
/// brief asks the cards to keep (24 Sep 2026: "consistent 4/8/12/16/20/24/32").
///
/// For the insides of the lobby's cards only — margins, the gaps between a
/// card's blocks, the air round a rule or beside a mark. The app-wide [Space]
/// ramp (2, 4, 6, 10, 14, 20, 28, 40) is deliberately not a 4dp grid and is
/// left exactly as it is: every other screen is laid out on it.
abstract final class CardSpace {
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s32 = 32;
}

/// One card on the lobby's rail — an engine, a category, a table, the private
/// room, the way back — in its game mode's colour (owner, 24 Sep 2026: "the
/// same component should work in both modes").
///
/// The card itself stays neutral: the theme's card surface
/// ([GlassSurface.card]), lit from above. The mode's accent is spent on two
/// things and nothing else — a light behind the card, which shows through it
/// as ambient light rather than as a disc, and the top of its hairline — so
/// the card's content is always the brightest thing on it. How strong that
/// light is and how far it reaches are the theme's ([GlassColors.glowStrength],
/// [GlassColors.glowReach]): a fainter, smaller pool by day, a stronger one by
/// night.
///
/// It replaced a pair of saturated discs — a sharp one behind each card and a
/// blurred copy inside it — whose edges stood round the cards as coloured
/// circles, loudest on the light theme. The light is a radial gradient now,
/// which fades to nothing by itself: no blur, no edge, one shader, painted
/// inside the card's own clip so the rail never cuts it off.
class GameCard extends StatelessWidget {
  const GameCard({
    super.key,
    required this.accent,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.lit = true,
    this.light = const Alignment(0.75, -1),
  });

  /// The mode's accent ([TablePalette.accent]).
  final Color accent;
  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Whether the mode's light is on. A table the player cannot sit at is
  /// drawn without it: the light is an invitation.
  final bool lit;

  /// Where the light is brightest, in the card's own alignment: over its top
  /// right by default — the lamp hangs over the room, and a card's words
  /// start at its left.
  final Alignment light;

  @override
  Widget build(BuildContext context) {
    final glass = GlassColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return PremiumGlassPanel(
      surface: GlassSurface.card,
      radius: Radii.xl,
      padding: padding,
      // A hint of the mode along the lit top of the hairline, no more (owner's
      // final pass: "keep the hue, reduce the tint").
      edge: lit ? accent.withValues(alpha: dark ? 0.32 : 0.36) : null,
      behind: lit
          ? CardLight(
              // The accent brought to full colour, as the old orbs were: a
              // deep light-theme accent would light the card grey.
              colour: orbColours(accent).$1,
              strength: glass.glowStrength,
              reach: glass.glowReach,
              centre: light,
            )
          : null,
      child: child,
    );
  }
}

/// The light behind a game card, as it shows through the card's body: a pool
/// of [colour] at [strength] where it is brightest, gone by [reach] of the
/// card's side.
///
/// Never repainted once drawn — the card rebuilds with the lobby's
/// one-second tick, and nothing about its light ever changes with it.
class CardLight extends StatelessWidget {
  const CardLight({
    super.key,
    required this.colour,
    required this.strength,
    required this.reach,
    this.centre = const Alignment(0.75, -1),
  });

  final Color colour;
  final double strength;
  final double reach;
  final Alignment centre;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: centre,
          radius: reach,
          // A soft shoulder rather than a linear fall: bright enough at its
          // heart to read as the mode's colour, and long gone before the
          // card's words at the far side.
          colors: [
            colour.withValues(alpha: strength),
            colour.withValues(alpha: strength * 0.45),
            colour.withValues(alpha: 0),
          ],
          stops: const [0, 0.42, 1],
        ),
      ),
    ),
  );
}

/// A card's words above its key, as wide as the card and scaled down as one
/// when they stand taller than [maxHeight] (or, with none given, than the room
/// the parent allows) — a long translation, a large text size, a poker
/// table's five facts.
///
/// The column is laid out wider by the factor it is about to be scaled by, so
/// that once scaled it still reaches the card's right edge. A [FittedBox] did
/// this job before and scaled the column's width with its height: the values
/// of a scaled card's facts stopped a strip short of the right edge, out of
/// line with the key under them (owner's final pass, 24 Sep 2026: "proper card
/// boundaries"). Where the column fits, nothing is scaled and nothing moves.
class CardColumnFit extends SingleChildRenderObjectWidget {
  const CardColumnFit({super.key, this.maxHeight, required super.child});

  final double? maxHeight;

  @override
  RenderCardColumnFit createRenderObject(BuildContext context) =>
      RenderCardColumnFit(maxHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderCardColumnFit renderObject,
  ) {
    renderObject.maxHeight = maxHeight;
  }
}

/// The render object of [CardColumnFit].
class RenderCardColumnFit extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  RenderCardColumnFit(this._maxHeight);

  double? _maxHeight;
  double? get maxHeight => _maxHeight;
  set maxHeight(double? value) {
    if (value == _maxHeight) return;
    _maxHeight = value;
    markNeedsLayout();
  }

  double _scale = 1;

  /// How far the column was scaled down to fit: 1 where it fits.
  double get scale => _scale;

  /// The largest scale, no more than 1, at which the column laid out
  /// `width / scale` wide stands no taller than [limit] once scaled, from
  /// [heightAt] — the column's height at a given width, which can only fall
  /// as the width grows (wider, the words wrap less).
  static double _fit(
    double width,
    double limit,
    double Function(double width) heightAt,
  ) {
    final natural = heightAt(width);
    // Where it fits, or where there is no room to fit it into at all.
    if (natural <= limit || limit <= 0) return 1;
    // Always fits: laid out wider, the column is no taller than it was.
    var fits = limit / natural;
    // The scale its height at that width would allow, which fits too unless
    // the narrower layout it implies wraps a line more; the answer lies
    // between the two.
    var over = math.min(1.0, limit / heightAt(width / fits));
    if (over <= fits) return fits;
    if (heightAt(width / over) * over <= limit) return over;
    for (var i = 0; i < 4; i++) {
      final mid = (fits + over) / 2;
      if (heightAt(width / mid) * mid <= limit) {
        fits = mid;
      } else {
        over = mid;
      }
    }
    return fits;
  }

  double _limit(BoxConstraints constraints) =>
      math.min(_maxHeight ?? double.infinity, constraints.maxHeight);

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    final width = constraints.maxWidth;
    double heightAt(double w) =>
        child.getDryLayout(BoxConstraints.tightFor(width: w)).height;
    final scale = _fit(width, _limit(constraints), heightAt);
    return constraints.constrain(Size(width, heightAt(width / scale) * scale));
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      _scale = 1;
      size = constraints.smallest;
      return;
    }
    final width = constraints.maxWidth;
    double heightAt(double w) {
      child.layout(BoxConstraints.tightFor(width: w), parentUsesSize: true);
      return child.size.height;
    }

    _scale = _fit(width, _limit(constraints), heightAt);
    // The layout the column keeps is the one it is painted at.
    final height = heightAt(width / _scale);
    size = constraints.constrain(Size(width, height * _scale));
  }

  Matrix4 get _transform => Matrix4.diagonal3Values(_scale, _scale, 1);

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    if (_scale == 1) {
      layer = null;
      context.paintChild(child, offset);
      return;
    }
    layer = context.pushTransform(
      needsCompositing,
      offset,
      _transform,
      (context, offset) => context.paintChild(child, offset),
      oldLayer: layer as TransformLayer?,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.multiply(_transform);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintTransform(
      transform: _transform,
      position: position,
      hitTest: (result, position) => child.hitTest(result, position: position),
    );
  }
}
