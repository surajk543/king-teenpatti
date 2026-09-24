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

/// A card's words above its key: its blocks one under another, as wide as the
/// card, scaled down together when they would stand taller than [maxHeight] —
/// and never under the card's corner keys ([keepClear]).
///
/// A card is square and its sizes follow its side, but its words are set in
/// the player's script and at the player's text size, and Devanagari stands
/// taller than Latin: at 1.25x on a 640dp phone some columns want more height
/// than the key at the foot leaves them. Scaling the column as one keeps every
/// line of every block (the brief: "don't just hide text"), and laying the
/// blocks out at the card's width divided by the scale before scaling them
/// down keeps the column spanning the card — a FittedBox round the column
/// would shrink it towards its left edge and leave a ragged margin at its
/// right. Where the blocks fit, the scale is 1 and nothing moves.
///
/// [keepClear] is a zone at the column's top right, in the card's own units:
/// a block that starts inside it is laid out that much narrower, at whatever
/// scale the column ends up at. A table card's two corner keys stand there,
/// and the further a column is scaled down, the more of it rises beside them:
/// a block that runs under a key is a block a player cannot read (5-Card
/// Draw's line did, scaled to 0.75 on a 640dp phone).
class CardColumn extends MultiChildRenderObjectWidget {
  const CardColumn({
    super.key,
    this.maxHeight,
    this.keepClear = Size.zero,
    required super.children,
  });

  /// The most the column may stand, besides what its parent allows.
  final double? maxHeight;

  /// The corner of the column no block may reach into: this wide from its
  /// right edge, this tall from its top.
  final Size keepClear;

  @override
  RenderCardColumn createRenderObject(BuildContext context) =>
      RenderCardColumn(maxHeight: maxHeight, keepClear: keepClear);

  @override
  void updateRenderObject(BuildContext context, RenderCardColumn renderObject) {
    renderObject
      ..maxHeight = maxHeight
      ..keepClear = keepClear;
  }
}

/// Where a [CardColumn] put one of its blocks.
class CardColumnParentData extends ContainerBoxParentData<RenderBox> {}

/// The render object behind [CardColumn].
class RenderCardColumn extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, CardColumnParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, CardColumnParentData> {
  RenderCardColumn({this._maxHeight, this._keepClear = Size.zero});

  double? _maxHeight;
  double? get maxHeight => _maxHeight;
  set maxHeight(double? value) {
    if (value == _maxHeight) return;
    _maxHeight = value;
    markNeedsLayout();
  }

  Size _keepClear;
  Size get keepClear => _keepClear;
  set keepClear(Size value) {
    if (value == _keepClear) return;
    _keepClear = value;
    markNeedsLayout();
  }

  double _scale = 1;

  /// How far the column was scaled down at its last layout: 1 where its
  /// blocks fit.
  double get scale => _scale;

  final LayerHandle<TransformLayer> _transform = LayerHandle<TransformLayer>();

  /// Below this the words would be too small to read at any text size, and
  /// the column stands as tall as it must instead.
  static const double _minScale = 0.5;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! CardColumnParentData) {
      child.parentData = CardColumnParentData();
    }
  }

  /// The column's height, in its own units, with its blocks laid out for a
  /// column [width] wide scaled by [scale]; every block placed unless [dry].
  double _heightAt(double width, double scale, {required bool dry}) {
    final wide = width / scale;
    final clearW = _keepClear.width / scale;
    final clearH = _keepClear.height;
    var y = 0.0;
    var child = firstChild;
    while (child != null) {
      final data = child.parentData! as CardColumnParentData;
      // A block that starts beside the keys is set short of them for its
      // whole height: it is one box.
      final inCorner = clearW > 0 && y * scale < clearH;
      final constraints = BoxConstraints(
        maxWidth: math.max(0.0, inCorner ? wide - clearW : wide),
      );
      final Size size;
      if (dry) {
        size = child.getDryLayout(constraints);
      } else {
        child.layout(constraints, parentUsesSize: true);
        size = child.size;
        data.offset = Offset(0, y);
      }
      y += size.height;
      child = data.nextSibling;
    }
    return y;
  }

  /// The largest scale, down to [_minScale], at which the blocks stand no
  /// taller than [limit], and the column's height at it in its own units.
  (double, double) _fit(double width, double limit, {required bool dry}) {
    final whole = _heightAt(width, 1, dry: dry);
    if (whole <= limit || !limit.isFinite) return (1, whole);

    // Set wider, the blocks wrap into fewer lines and stand no taller: the
    // share the limit is of the whole is a scale that fits, or close to one.
    var fits = math.max(_minScale, limit / whole);
    var height = _heightAt(width, fits, dry: dry);
    while (height * fits > limit && fits > _minScale) {
      fits = math.max(_minScale, fits * 0.95);
      height = _heightAt(width, fits, dry: dry);
    }
    if (height * fits > limit) return (fits, height);

    // Then as close under the limit as a few halvings bring it.
    var over = 1.0;
    var last = fits;
    for (var i = 0; i < 6; i++) {
      final mid = (fits + over) / 2;
      final h = _heightAt(width, mid, dry: dry);
      last = mid;
      if (h * mid <= limit) {
        fits = mid;
        height = h;
      } else {
        over = mid;
      }
    }
    // The blocks stand where the last try left them: set them again at the
    // scale that fits if that was not it.
    if (!dry && last != fits) height = _heightAt(width, fits, dry: false);
    return (fits, height);
  }

  double _limit(BoxConstraints constraints) =>
      math.min(_maxHeight ?? double.infinity, constraints.maxHeight);

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final width = constraints.maxWidth;
    final (scale, height) = _fit(width, _limit(constraints), dry: true);
    return constraints.constrain(Size(width, height * scale));
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final (scale, height) = _fit(width, _limit(constraints), dry: false);
    _scale = scale;
    size = constraints.constrain(Size(width, height * scale));
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    var widest = 0.0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      widest = math.max(widest, child.getMinIntrinsicWidth(double.infinity));
    }
    return widest;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    var widest = 0.0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      widest = math.max(widest, child.getMaxIntrinsicWidth(double.infinity));
    }
    return widest;
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    var total = 0.0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      total += child.getMinIntrinsicHeight(width);
    }
    return math.min(total, _maxHeight ?? double.infinity);
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    var total = 0.0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      total += child.getMaxIntrinsicHeight(width);
    }
    return math.min(total, _maxHeight ?? double.infinity);
  }

  Matrix4 get _scaling => Matrix4.diagonal3Values(_scale, _scale, 1);

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_scale == 1) {
      _transform.layer = null;
      defaultPaint(context, offset);
      return;
    }
    _transform.layer = context.pushTransform(
      needsCompositing,
      offset,
      _scaling,
      defaultPaint,
      oldLayer: _transform.layer,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (_scale == 1) {
      return defaultHitTestChildren(result, position: position);
    }
    return result.addWithPaintTransform(
      transform: _scaling,
      position: position,
      hitTest: (result, position) =>
          defaultHitTestChildren(result, position: position),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final offset = (child.parentData! as CardColumnParentData).offset;
    transform
      ..multiply(_scaling)
      ..translateByDouble(offset.dx, offset.dy, 0, 1);
  }

  @override
  void dispose() {
    _transform.layer = null;
    super.dispose();
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(DoubleProperty('maxHeight', _maxHeight, defaultValue: null))
      ..add(DiagnosticsProperty<Size>('keepClear', _keepClear))
      ..add(DoubleProperty('scale', _scale, defaultValue: 1.0));
  }
}
