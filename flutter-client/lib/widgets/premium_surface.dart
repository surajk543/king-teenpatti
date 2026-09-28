import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_theme.dart';
import '../theme/depth.dart';
import '../theme/theme_colors.dart';

/// The app's one raised-surface treatment: a tinted gradient, a lit edge in an
/// accent colour, and a shadow.
///
/// Everything that reads as an object — a lobby card, the table itself, a
/// player's pod — is built from this, so the game room and the lobby are
/// visibly the same app rather than two that merely resemble each other. It is
/// also what keeps surfaces visible in dark mode, where a flat container
/// disappears into the page.
class PremiumSurface extends StatelessWidget {
  const PremiumSurface({
    super.key,
    required this.accent,
    required this.child,
    this.radius = Radii.lg,
    this.glint = false,
    this.borderWidth = 1.5,
    this.tint,
    this.elevated = true,
    this.bevel,
    this.bloom,
    this.cloth,
  });

  /// Fills the surface with the game's baize instead of a tinted panel.
  ///
  /// Set on the lobby's table cards so a card is a swatch of the room it opens:
  /// tap the purple one and the felt you land on is the same purple cloth. The
  /// value is the table's accent, and the cloth is mixed exactly as the felt
  /// mixes it, so the two cannot drift apart.
  ///
  /// Anything drawn on top must switch to felt ink — see AppTheme.onFelt.
  final Color? cloth;

  /// The colour of the lit edge and of the gradient's tint.
  final Color accent;
  final Widget child;
  final double radius;

  /// Adds the travelling highlight (requirement 28's sweep).
  final bool glint;
  final double borderWidth;

  /// How strongly the accent tints the surface. Defaults per theme.
  final double? tint;
  final bool elevated;

  /// Whether the surface's edge catches the light: 0 asks for none, anything
  /// else (and null, the default) lights it as the depth ladder lights a card
  /// ([SurfaceLight]) — a line along the top edge that curls into the
  /// corners, and a shade along the foot.
  ///
  /// It was the depth of a straight band of light across the top, and before
  /// that the corner radius, which is right for a card and absurd for the
  /// felt: at `radius: h / 2` the highlight washed over the top half of the
  /// table. Light catches a bevel, and a bevel is a line whatever the corner
  /// does.
  final double? bevel;

  /// The alpha of the accent bloom under the surface.
  ///
  /// A bloom is a reserved signal — the felt, the winner's pod and the
  /// buy-chips button — so that when something blooms it means the game did
  /// something. Pass 0 to drop it.
  final double? bloom;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;

    final strength = tint ?? (dark ? 0.20 : 0.13);
    final baize = cloth == null
        ? null
        : AppTheme.feltColours(theme.brightness, accent: cloth);
    final top =
        baize?.core ??
        Color.alphaBlend(
          accent.withValues(alpha: strength),
          scheme.surfaceContainerHigh,
        );
    final bottom =
        baize?.rim ??
        (dark ? scheme.surfaceContainerLowest : scheme.surfaceContainerLow);
    // The same tinted shadow the buttons cast, so everything in the app is lit
    // from one place.
    final shadow = AppTheme.shadowFor(theme.brightness);
    final bloomAlpha = bloom ?? (dark ? 0.14 : 0.13);
    final lip = bevel ?? math.min(radius, 3.0);
    // The light the surface catches as a card on the depth ladder: its top
    // edge lit — as brightly as its bevel always was — curling into its
    // corners, its foot in shade, and by night a breath of light over its
    // upper part. Under what is on it.
    final light = Depth.of(context)
        .light(Elevation.card)
        .copyWith(rim: Colors.white.withValues(alpha: dark ? 0.14 : 0.34));

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [top, bottom],
        ),
        border: Border.all(
          color: accent.withValues(alpha: dark ? 0.55 : 0.35),
          width: borderWidth,
        ),
        // Three layers rather than one. A single soft shadow reads as a blur
        // behind the card; a tight contact shadow under the edge, a broader
        // ambient one, and a faint bloom in the card's own accent is what makes
        // it read as an object sitting on something. The alphas are far higher
        // in dark mode than they look: 0.16 of black on a #0B0E11 ground is
        // nothing at all.
        boxShadow: elevated
            ? [
                BoxShadow(
                  color: shadow.withValues(alpha: dark ? 0.72 : 0.16),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
                BoxShadow(
                  color: shadow.withValues(alpha: dark ? 0.50 : 0.13),
                  blurRadius: 26,
                  offset: const Offset(0, 12),
                ),
                if (bloomAlpha > 0)
                  BoxShadow(
                    color: accent.withValues(alpha: bloomAlpha),
                    blurRadius: 34,
                    spreadRadius: -8,
                    offset: const Offset(0, 8),
                  ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          children: [
            // Light catching the top edge, and the shade along the foot. A
            // lit edge is what separates a panel from a rectangle of colour,
            // and it costs nothing to draw. A bevel of 0 asks for none.
            if (lip > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: SurfaceLight(radius: radius, light: light),
                  ),
                ),
              ),
            glint ? Glint(child: child) : child,
          ],
        ),
      ),
    );
  }
}

/// The depth ladder's light ([Depth], [SurfaceLight]) on a rounded surface
/// that is not a glass panel — a key, a pill, a plate, a tile, a well: laid
/// over the surface's own body and under [child], so nothing on the surface
/// is covered and nothing about its size or place changes.
///
/// Put it between the surface's decoration and its content, sized as the
/// surface is: `DecoratedBox(decoration, child: DepthFace(child: content))`.
class DepthFace extends StatelessWidget {
  const DepthFace({
    super.key,
    required this.radius,
    required this.child,
    this.level = Elevation.raised,
    this.brightness,
    this.strength = 1,
  });

  /// The surface's corner radius; a capsule may pass [Radii.pill].
  final double radius;

  /// Where the surface stands on the ladder.
  final Elevation level;

  /// The ladder of a surface that is one brightness whatever the theme —
  /// the dark plates and the wallet on the table; null follows the theme.
  final Brightness? brightness;

  /// How much of the light a surface takes: less on a saturated fill, and on
  /// a key pressed in.
  final double strength;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = brightness == null
        ? Depth.of(context)
        : Depth.forBrightness(brightness!);
    return CustomPaint(
      painter: SurfaceLight(
        radius: radius,
        light: scheme.light(level).scaled(strength),
      ),
      child: child,
    );
  }
}

/// The corner radius of a button's [shape], for its face's light: a capsule
/// for a stadium or a circle (and for no shape at all, Material 3's own
/// button shape), the top-left corner of a rounded rectangle.
double radiusOfShape(ShapeBorder? shape) => switch (shape) {
  RoundedRectangleBorder(:final borderRadius) =>
    borderRadius.resolve(TextDirection.ltr).topLeft.x,
  ContinuousRectangleBorder(:final borderRadius) =>
    borderRadius.resolve(TextDirection.ltr).topLeft.x,
  _ => Radii.pill,
};

/// A button's background builder ([ButtonStyle.backgroundBuilder]) that lays
/// the ladder's [Elevation.raised] light on the key under its label: lit
/// while it can be pressed, a third of it while a finger holds it down, and
/// none at all when it cannot be pressed — a dead key sits flush, as its
/// shadow already does ([AppTheme.liftElevation]).
ButtonLayerBuilder raisedKeyFace({
  required double radius,
  double strength = 1,
  Brightness? brightness,
}) => (context, states, child) {
  if (child == null || states.contains(WidgetState.disabled)) {
    return child ?? const SizedBox.shrink();
  }
  return DepthFace(
    radius: radius,
    brightness: brightness,
    strength: states.contains(WidgetState.pressed) ? strength / 3 : strength,
    child: child,
  );
};

/// How a glass panel renders.
///
/// [blurred] is a real `BackdropFilter`; [tinted] is the identical fill, sheen,
/// hairline and shadow with no filter. [auto] asks the [GlassBudget] whether a
/// blur is affordable and settles for [tinted] when it is not.
enum GlassMode { auto, blurred, tinted }

/// What a glass panel's body is made of.
enum GlassSurface {
  /// A pane laid over the game — a drawer, a dialog, a pill, a notice — and
  /// every panel that does not ask for anything else.
  pane,

  /// A game card: the lobby's cards and the chips at its corners (owner,
  /// 24 Sep 2026). Near-opaque in the theme's card tokens
  /// ([GlassColors.cardFill] and the rest) — its own body, edge, lit top line
  /// and shadow, by night and by day — because it is the thing being read.
  card,
}

/// The single glass primitive.
///
/// A `BackdropFilter` does not cache: it re-reads and re-blurs its backdrop on
/// every frame that backdrop repaints. On the table screen the backdrop is dirty
/// every frame forever (the ambient lamp breathes, bet flights fly), so a
/// "persistent" blur there is a 60fps blur. That is why the table's rail and
/// action console are [tinted] — a blur of smooth emerald baize produces smooth
/// emerald baize, at 23% of the screen, every frame — and why blur is reserved
/// for transient overlays that cover what is behind them anyway.
///
/// [padding] is required on purpose. Every panel that inherited a default
/// padding in the draft asked for more room than its container had, at every
/// device size; the fix is that a panel never guesses.
class PremiumGlassPanel extends StatefulWidget {
  const PremiumGlassPanel({
    super.key,
    required this.child,
    required this.padding,
    this.mode = GlassMode.tinted,
    this.sigma,
    this.priority = 0,
    this.radius = Radii.lg,
    this.live = false,
    this.tint,
    this.behind,
    this.elevated = true,
    this.clipBehavior = Clip.antiAlias,
    this.surface = GlassSurface.pane,
    this.edge,
    this.depth = Elevation.card,
  });

  final Widget child;

  /// Where the panel stands on the depth ladder ([Elevation]): what it casts
  /// and how its edge is lit. A [Elevation.card] by default — a lobby card, a
  /// seat pod, a pane on the room; [Elevation.overlay] for a dialog, a drawer
  /// or a sheet laid over the room; [Elevation.raised] for a chip or a pill.
  /// A lobby card ([GlassSurface.card]) at [Elevation.card] keeps the theme's
  /// own card shadow ([GlassColors.cardShadow]).
  final Elevation depth;

  /// The panel's own inset. No default: see the class doc.
  final EdgeInsetsGeometry padding;

  final GlassMode mode;

  /// A pane over the game, or one of the lobby's game cards.
  final GlassSurface surface;

  /// The colour the hairline starts from at the top edge, fading to the
  /// resting edge at the foot: a game card's mode accent, so the card is lit
  /// in its colour along one line rather than washed in it. Ignored while
  /// [live], which has its own.
  final Color? edge;

  /// Blur radius, when this panel blurs at all. Null takes the theme's own —
  /// 16 on obsidian, 20 on ice ([GlassColors.sigma]). Never above 24: the
  /// cost is roughly linear in area and there is no visual return past it.
  final double? sigma;

  /// Which panel wins when two [GlassMode.auto] panels want the one blur.
  /// A full-screen overlay claims a higher priority than the drawer beneath it.
  final int priority;

  final double radius;

  /// A live panel wears the brighter of the two hairline alphas: focused,
  /// claimable, or the primary thing on screen.
  final bool live;

  /// An optional wash of colour through the fill — a table's accent, say.
  final Color? tint;

  /// What shows through the glass: painted over the body, under the sheen and
  /// the hairline, and clipped with them. A panel that cannot afford a live
  /// blur draws here, already softened, the colour a blur would have let
  /// through — which is how the lobby's cards get their frosted orbs.
  final Widget? behind;

  final bool elevated;
  final Clip clipBehavior;

  @override
  State<PremiumGlassPanel> createState() => _PremiumGlassPanelState();
}

class _PremiumGlassPanelState extends State<PremiumGlassPanel> {
  /// Cached per sigma so a filter is never allocated in `build`.
  static final Map<double, ui.ImageFilter> _blurCache = {};

  static ui.ImageFilter _blur(double sigma) => _blurCache.putIfAbsent(
    sigma,
    () => ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
  );

  GlassAllowance? _allowance;
  bool _holdsLease = false;
  bool _asked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A card never blurs, so it never holds the one lease another panel
    // could have spent.
    if (widget.mode != GlassMode.auto ||
        widget.surface == GlassSurface.card ||
        _asked) {
      return;
    }
    _asked = true;
    _allowance = GlassBudget.maybeOf(context);
    // A panel decides once, when it mounts, and keeps that decision for its
    // lifetime unless it is preempted. Re-deciding mid-life would pop a blur in
    // and out underneath a player's finger.
    _holdsLease =
        _allowance?.claim(
          this,
          priority: widget.priority,
          onRevoked: _onRevoked,
        ) ??
        false;
  }

  void _onRevoked() {
    if (!mounted) {
      _holdsLease = false;
      return;
    }
    setState(() => _holdsLease = false);
  }

  @override
  void dispose() {
    if (_holdsLease) _allowance?.release(this);
    super.dispose();
  }

  bool get _blurring => switch (widget.mode) {
    GlassMode.blurred => true,
    GlassMode.tinted => false,
    GlassMode.auto => _holdsLease,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    final card = widget.surface == GlassSurface.card;
    // A card is near-opaque: nothing behind it would show through a blur.
    final blurring = _blurring && !card;

    // Over a blur the panel is barely more than the blur: a whisper of white
    // on obsidian, milk on ice, because the softened backdrop IS the body.
    // Nothing behind a tinted panel is being blurred, so that panel has to
    // carry its own body or it reads as a smear. A game card carries the
    // theme's card body, lit from above.
    Color washed(Color c) => widget.tint == null
        ? c
        : Color.alphaBlend(widget.tint!.withValues(alpha: 0.10), c);
    final List<Color> body;
    if (card) {
      body = [washed(glass.cardFill), washed(glass.cardFillEnd)];
    } else if (blurring) {
      body = [washed(glass.fill), washed(glass.fillStrong)];
    } else {
      final base = AppTheme.panelBase(theme.brightness);
      final c = widget.tint == null
          ? base
          : Color.alphaBlend(widget.tint!.withValues(alpha: 0.14), base);
      body = dark
          ? [c.withValues(alpha: 0.84), c.withValues(alpha: 0.94)]
          : [c.withValues(alpha: 0.88), c.withValues(alpha: 0.96)];
    }

    // Resting, the border is the spec's one-pixel gradient — lit above,
    // fading below — or a card's own edge, which may start from its mode's
    // accent. Live (focused, claimable, the primary thing on screen) it is the
    // app's gold hairline, so the accent still means something.
    final live = AppTheme.hairlineColour(theme.brightness, live: true);
    final rest = card
        ? [widget.edge ?? glass.cardBorder, glass.cardBorder]
        : [widget.edge ?? glass.borderTop, glass.borderBottom];
    final border = widget.live ? [live, live] : rest;

    // Where the panel stands on the depth ladder: what it casts, and the
    // light along its edges. Under the panel, the shadow a card has always
    // cast — the theme's own card shadow for a lobby card, the pane's for a
    // pane — or a raised capsule's small one; an overlay keeps that and
    // throws its far reach round itself, outside its body only, so neither a
    // blur behind the glass nor the glass itself is darkened by it. A panel
    // at card height keeps the theme's own lit top line
    // ([GlassColors.cardHighlight], [GlassColors.highlight]) along its edge.
    final depth = Depth.of(context);
    final level = widget.depth;
    final atCard = level == Elevation.card;
    final raised = level == Elevation.raised;
    final shadows = !widget.elevated
        ? null
        : raised
        ? depth.shadows(Elevation.raised)
        : card
        ? glass.cardShadow
        : depth.shadows(Elevation.card);
    final reach = widget.elevated && level == Elevation.overlay
        ? depth.overlayReach
        : const <BoxShadow>[];
    var light = depth.light(level);
    if (atCard) {
      light = light.copyWith(rim: card ? glass.cardHighlight : glass.highlight);
    }

    final panel = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.radius),
        boxShadow: shadows,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        clipBehavior: widget.clipBehavior,
        child: Stack(
          children: [
            // The filter is always positioned and the padded child is always
            // the one non-positioned child: it is what the Stack takes its size
            // from. Reverse that and the panel collapses to nothing.
            if (blurring)
              Positioned.fill(
                child: BackdropFilter(
                  filter: _blur(widget.sigma ?? glass.sigma),
                  child: const ColoredBox(color: Colors.transparent),
                ),
              ),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      // A card is lit from above, as the room is; a pane
                      // catches the light across its diagonal.
                      begin: card ? Alignment.topCenter : Alignment.topLeft,
                      end: card
                          ? Alignment.bottomCenter
                          : Alignment.bottomRight,
                      colors: body,
                    ),
                  ),
                ),
              ),
            ),
            if (widget.behind != null)
              Positioned.fill(child: IgnorePointer(child: widget.behind!)),
            // The light the panel catches at its height on the ladder: its top
            // edge lit and its foot in shade, just inside the hairline, and by
            // night a breath of light over its upper part. It replaces a flat
            // 2dp sheen straight across the top, which the corners cut off
            // and which said nothing about the foot.
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: SurfaceLight(radius: widget.radius, light: light),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: GlassHairline(radius: widget.radius, colors: border),
                ),
              ),
            ),
            Padding(padding: widget.padding, child: widget.child),
          ],
        ),
      ),
    );

    // An overlay's far reach, round it and never under it.
    final lifted = reach.isEmpty
        ? panel
        : CustomPaint(
            painter: OuterShadow(radius: widget.radius, shadows: reach),
            child: panel,
          );

    // A blur is an offscreen pass; keeping it off its neighbours' repaints is
    // the whole point of paying for one at all.
    return blurring ? RepaintBoundary(child: lifted) : lifted;
  }
}

/// [DepthScheme.shadows] at [level] cast by a translucent rounded surface —
/// glass, a veil of colour, a pill of the room's ink — round it and never
/// under it ([OuterShadow]), so the surface keeps its own colour: put it
/// round the surface, `DepthShadow(radius: r, child: surface)`.
class DepthShadow extends StatelessWidget {
  const DepthShadow({
    super.key,
    required this.radius,
    required this.child,
    this.level = Elevation.raised,
  });

  /// The surface's corner radius; a capsule may pass [Radii.pill].
  final double radius;

  /// Where the surface stands on the ladder.
  final Elevation level;

  final Widget child;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: OuterShadow(
      radius: radius,
      shadows: Depth.of(context).shadows(level),
    ),
    child: child,
  );
}

/// How many blurred panels may exist at once, and who currently holds them.
///
/// This is a mutable object rather than a value carried down the tree because
/// the panels that need demoting are never descendants of the overlay that
/// demotes them: a drawer, a dialog and the table's chrome are siblings, and an
/// inherited value re-provided beneath an overlay reaches only that overlay.
/// Panels take a lease when they mount and give it back when they unmount, and
/// a higher-priority claimant preempts a lower-priority holder.
class GlassAllowance {
  GlassAllowance({this.allowance = 1});

  /// How many blurs may be composited at once. One, on the table screen, is
  /// the honest number.
  final int allowance;

  final List<_GlassLease> _leases = [];

  /// Whether a blur is free right now, without taking it.
  bool get hasFree => _leases.length < allowance;

  /// Takes a lease for [holder]. Returns false if none was available and none
  /// could be preempted, in which case the caller renders tinted.
  bool claim(
    Object holder, {
    required int priority,
    required VoidCallback onRevoked,
  }) {
    if (_leases.any((l) => identical(l.holder, holder))) return true;

    if (!hasFree) {
      _GlassLease? weakest;
      for (final lease in _leases) {
        if (lease.priority < priority &&
            (weakest == null || lease.priority < weakest.priority)) {
          weakest = lease;
        }
      }
      if (weakest == null) return false;
      _leases.remove(weakest);
      _revoke(weakest);
    }

    _leases.add(_GlassLease(holder, priority, onRevoked));
    return true;
  }

  void release(Object holder) =>
      _leases.removeWhere((l) => identical(l.holder, holder));

  /// A claim happens while the claimant is building, so the panel losing its
  /// blur cannot be marked dirty until that build is over.
  void _revoke(_GlassLease lease) {
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      lease.onRevoked();
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) => lease.onRevoked());
  }
}

class _GlassLease {
  const _GlassLease(this.holder, this.priority, this.onRevoked);

  final Object holder;
  final int priority;
  final VoidCallback onRevoked;
}

/// Installs a [GlassAllowance] over the app.
///
/// It belongs in `MaterialApp.builder`, not around the screen switch: dialogs,
/// modal sheets and snack bars are built from the root Navigator and the root
/// ScaffoldMessenger, both of which sit above anything passed as `home`. Without
/// it, [GlassMode.auto] never blurs — which is a deliberately safe failure, and
/// costs a look rather than a frame.
class GlassBudget extends StatefulWidget {
  const GlassBudget({super.key, this.allowance = 1, required this.child});

  final int allowance;
  final Widget child;

  /// The allowance in scope, or null if none was installed. This does not make
  /// the caller depend on it — the object's identity never changes — so taking
  /// a lease never rebuilds anything but the panel that asked.
  static GlassAllowance? maybeOf(BuildContext context) {
    final element = context
        .getElementForInheritedWidgetOfExactType<_GlassBudgetScope>();
    return (element?.widget as _GlassBudgetScope?)?.allowance;
  }

  @override
  State<GlassBudget> createState() => _GlassBudgetState();
}

class _GlassBudgetState extends State<GlassBudget> {
  late GlassAllowance _allowance = GlassAllowance(allowance: widget.allowance);

  @override
  void didUpdateWidget(GlassBudget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.allowance != widget.allowance) {
      _allowance = GlassAllowance(allowance: widget.allowance);
    }
  }

  @override
  Widget build(BuildContext context) =>
      _GlassBudgetScope(allowance: _allowance, child: widget.child);
}

class _GlassBudgetScope extends InheritedWidget {
  const _GlassBudgetScope({required this.allowance, required super.child});

  final GlassAllowance allowance;

  @override
  bool updateShouldNotify(_GlassBudgetScope oldWidget) =>
      !identical(oldWidget.allowance, allowance);
}

/// The one-pixel border every glass pane wears: a rounded-rectangle stroke in
/// a top-to-bottom gradient, so the edge is lit where the light would catch
/// it and fades where it would not. A `Border` cannot take a gradient, which
/// is why this is a painter.
class GlassHairline extends CustomPainter {
  const GlassHairline({
    required this.radius,
    required this.colors,
    this.width = Dim.hairline,
  });

  final double radius;

  /// Top colour first, bottom colour last.
  final List<Color> colors;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: colors,
      ).createShader(rect);
    // Inset by half the stroke so the whole line lands inside the clip.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect.deflate(width / 2),
        Radius.circular(math.max(0, radius - width / 2)),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(GlassHairline old) =>
      old.radius != radius ||
      old.width != width ||
      !listEquals(old.colors, colors);
}

/// A thin highlight that travels across a surface, corner to corner, over and
/// over (requirement 28).
///
/// Deliberately narrow and faint: a wide, bright band covers the whole surface
/// at once, and that does not read as a moving light — it reads as a blink.
class Glint extends StatefulWidget {
  const Glint({super.key, required this.child, this.period = Motion.sweep});

  final Widget child;
  final Duration period;

  @override
  State<Glint> createState() => _GlintState();
}

class _GlintState extends State<Glint> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.period,
  )..repeat();

  static const double _halfBand = 0.07;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strength = Theme.of(context).brightness == Brightness.dark
        ? 0.11
        : 0.16;

    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            // The band repaints every frame for the life of the surface it
            // sweeps; without this its parent repaints with it.
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) {
                  // Travels from just off one corner to just off the other, so
                  // the stops stay ordered and the band never collapses into a
                  // full-surface flash at either end.
                  final centre = -_halfBand + _c.value * (1 + 2 * _halfBand);

                  return DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Colors.white.withValues(alpha: 0),
                          Colors.white.withValues(alpha: strength),
                          Colors.white.withValues(alpha: 0),
                        ],
                        stops: [
                          (centre - _halfBand).clamp(0.0, 1.0),
                          centre.clamp(0.0, 1.0),
                          (centre + _halfBand).clamp(0.0, 1.0),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}
