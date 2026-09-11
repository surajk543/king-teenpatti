import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_theme.dart';
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

  /// How deep the lit top edge runs.
  ///
  /// It used to be the corner radius, which is right for a card and absurd for
  /// the felt: at `radius: h / 2` the highlight washed over the top half of the
  /// table. Light catches a bevel, and a bevel is a couple of pixels whatever
  /// the corner does.
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
            glint ? Glint(child: child) : child,
            // Light catching the top bevel. Two or three pixels of brightness
            // along the upper edge is what separates a panel from a rectangle
            // of colour, and it costs nothing to draw.
            if (lip > 0)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: lip,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withValues(alpha: dark ? 0.14 : 0.34),
                          Colors.white.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// How a glass panel renders.
///
/// [blurred] is a real `BackdropFilter`; [tinted] is the identical fill, sheen,
/// hairline and shadow with no filter. [auto] asks the [GlassBudget] whether a
/// blur is affordable and settles for [tinted] when it is not.
enum GlassMode { auto, blurred, tinted }

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
    this.elevated = true,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;

  /// The panel's own inset. No default: see the class doc.
  final EdgeInsetsGeometry padding;

  final GlassMode mode;

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
    if (widget.mode != GlassMode.auto || _asked) return;
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
    final blurring = _blurring;

    // Over a blur the panel is barely more than the blur: a whisper of white
    // on obsidian, milk on ice, because the softened backdrop IS the body.
    // Nothing behind a tinted panel is being blurred, so that panel has to
    // carry its own body or it reads as a smear.
    final List<Color> body;
    if (blurring) {
      Color washed(Color c) => widget.tint == null
          ? c
          : Color.alphaBlend(widget.tint!.withValues(alpha: 0.10), c);
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
    // fading below. Live (focused, claimable, the primary thing on screen) it
    // is the app's gold hairline, so the accent still means something.
    final live = AppTheme.hairlineColour(theme.brightness, live: true);
    final border = widget.live
        ? [live, live]
        : [glass.borderTop, glass.borderBottom];

    final panel = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.radius),
        boxShadow: widget.elevated
            ? AppTheme.glassShadow(theme.brightness)
            : null,
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
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: body,
                    ),
                  ),
                ),
              ),
            ),
            // A fixed 2dp sheen, never the corner radius.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 2,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        glass.highlight,
                        glass.highlight.withValues(alpha: 0),
                      ],
                    ),
                  ),
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

    // A blur is an offscreen pass; keeping it off its neighbours' repaints is
    // the whole point of paying for one at all.
    return blurring ? RepaintBoundary(child: panel) : panel;
  }
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
