import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'poker_chip.dart';

/// Faint poker chips rising through a screen, each on its own slow path.
///
/// Seventeen chips, fixed paths, one ticker. Drawn well behind the lobby's cards
/// or a panel's contents, at low opacity: the point is that the surface is
/// alive, not that anything is happening on it. One widget, so every screen
/// that uses it breathes the same way.
///
/// Needs a bounded box — it is always given one by a [Positioned.fill] or an
/// expanded [Stack], never dropped into a scrolling column.
///
/// Charcoal on charcoal apart from a single gold chip. Seven coloured discs
/// drifting behind a table is a screensaver; one gold one in a shoal of dark
/// ones is a room with something in it.
class DriftingChips extends StatefulWidget {
  const DriftingChips({super.key, this.strength = 1.0});

  /// Multiplies the base opacity, so one widget can be barely-there in one
  /// place and clearly visible in another.
  ///
  /// The lobby leaves this at 1 and keeps the whisper it was designed with:
  /// there, the chips drift across an open background and a faint hint is
  /// enough. A panel that draws its own fill *over* them shows chips only at
  /// the margins, and at the lobby's strength that margin reads as empty.
  /// Which is why this is a parameter rather than a new constant: the right
  /// opacity depends on what is painted on top.
  final double strength;

  @override
  State<DriftingChips> createState() => _DriftingChipsState();
}

class _DriftingChipsState extends State<DriftingChips>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 28),
  )..repeat();

  /// x as a fraction of the width, diameter and wobble as fractions of the
  /// box's short side, speed in screens per cycle, phase offset, and whether
  /// the chip turns.
  ///
  /// Sizes are fractions rather than dp because the same seven chips have to
  /// carry a 360dp-tall phone and an 800dp tablet: the largest is 25.9dp at
  /// h=360, 29.6 at h=411 and 57.6 at h=800, the smallest 10.8 | 12.3 | 24.0.
  /// Fixed dp made the layer crowded on the first and sparse on the last.
  ///
  /// The three smallest do not turn. A flat disc spinning in the plane of the
  /// screen reads as a coin seen face-on being twisted, which is subtly wrong;
  /// at that size the rotation was only ever legible as flicker anyway.
  /// (cross, size, speed, phase, wobble, spin, heading)
  ///
  /// `heading` is the direction of travel in turns (0 = left-to-right, 0.25 =
  /// downwards). Seven different headings rather than seven parallel risers:
  /// chips crossing the felt from wherever they happen to come from read as a
  /// room with something going on in it, while a single upward column reads as
  /// a loading screen. `cross` is now the offset ACROSS that heading, so the
  /// paths still do not overlap.
  static const _paths =
      <(double, double, double, double, double, bool, double)>[
    // Fifteen, across a wide spread of sizes: a few large ones drifting slowly
    // read as near the eye, the small quick ones as far off, and that
    // difference is what stops the layer looking like scattered confetti. The
    // big ones are deliberately the slowest — a large disc crossing quickly
    // reads as a thrown object rather than as depth.
    // Two of these are very large and very slow — a chip that fills a good
    // part of the margin, drifting past almost imperceptibly. They are what
    // give the layer depth; without something near the eye, fifteen mid-sized
    // discs read as one flat sheet of confetti.
    (0.02, 0.230, 0.30, 0.12, 0.060, true, 0.09),
    (0.98, 0.185, 0.36, 0.68, 0.055, true, 0.53),
    (0.05, 0.104, 0.55, 0.00, 0.050, true, 0.13),
    (0.12, 0.028, 1.75, 0.62, 0.022, false, 0.62),
    (0.19, 0.062, 1.05, 0.35, 0.038, false, 0.88),
    (0.26, 0.086, 0.70, 0.18, 0.046, true, 0.31),
    (0.33, 0.034, 1.55, 0.77, 0.026, false, 0.74),
    (0.40, 0.070, 0.95, 0.44, 0.042, true, 0.05),
    (0.47, 0.024, 1.90, 0.09, 0.020, false, 0.47),
    (0.54, 0.096, 0.62, 0.83, 0.048, true, 0.21),
    (0.61, 0.044, 1.35, 0.28, 0.030, false, 0.69),
    (0.68, 0.078, 0.82, 0.55, 0.044, true, 0.94),
    (0.75, 0.030, 1.68, 0.71, 0.024, false, 0.38),
    (0.82, 0.058, 1.15, 0.02, 0.036, false, 0.57),
    (0.88, 0.090, 0.66, 0.40, 0.047, true, 0.80),
    (0.93, 0.026, 1.82, 0.91, 0.021, false, 0.11),
    (0.97, 0.066, 1.00, 0.24, 0.040, true, 0.44),
  ];

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final purple =
        AppTheme.paletteFor(scheme, category: 'blind', bootAmount: 5000).accent;
    final colours = [
      AppTheme.ink500,
      AppTheme.ink400,
      AppTheme.gold,
      AppTheme.ink500,
      AppTheme.ink400,
      purple,
      AppTheme.ink400,
    ];
    // The light ground is nearly white, and a gold chip at 7% of an alpha on
    // near-white is not there at all. The dark ground hides far less, so the
    // two are not the same number.
    final alpha = ((dark ? 0.10 : 0.16) * widget.strength).clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, box) {
        final short = math.min(box.maxWidth, box.maxHeight);

        // The boundary is the point of the layout: this subtree is dirty on
        // every frame of a 28s loop, and without it whatever is painted over
        // it — a lobby full of cards, a store shelf — re-rasterises with it.
        return RepaintBoundary(
          child: SizedBox(
            width: box.maxWidth,
            height: box.maxHeight,
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                for (var i = 0; i < _paths.length; i++)
                  _Drifter(
                    clock: _clock,
                    path: _paths[i],
                    index: i,
                    box: Size(box.maxWidth, box.maxHeight),
                    short: short,
                    // The chip itself is handed in as a child so the ticker
                    // moves it without rebuilding its painter every frame.
                    chip: PokerChip(
                      colour: colours[i % colours.length],
                      size: short * _paths[i].$2,
                    ),
                    opacity: alpha,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One chip on one path.
class _Drifter extends StatelessWidget {
  const _Drifter({
    required this.clock,
    required this.path,
    required this.index,
    required this.box,
    required this.short,
    required this.chip,
    required this.opacity,
  });

  final Animation<double> clock;
  final (double, double, double, double, double, bool, double) path;
  final int index;
  final Size box;
  final double short;
  final Widget chip;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final (cross, sizeK, speed, phase, wobbleK, spin, heading) = path;
    final diameter = short * sizeK;
    final wobble = short * wobbleK;
    final theta = heading * 2 * math.pi;
    final dir = Offset(math.cos(theta), math.sin(theta));
    // Perpendicular to travel, so `cross` spreads the paths apart whatever
    // direction they run in.
    final side = Offset(-dir.dy, dir.dx);

    return Positioned(
      left: 0,
      top: 0,
      child: AnimatedBuilder(
        animation: clock,
        child: Opacity(opacity: opacity, child: chip),
        builder: (context, child) {
          final t = clock.value;
          // Enters off one edge and leaves off the opposite one, whatever the
          // heading. The span is the box's diagonal so no direction can cut a
          // chip's run short, and 1.2 of it keeps both ends out of sight.
          final span = 1.2 *
              math.sqrt(box.width * box.width + box.height * box.height);
          final progress = (t * speed + phase) % 1.0;
          final centre = Offset(box.width / 2, box.height / 2);
          final along = (progress - 0.5) * span;
          final across = (cross - 0.5) * span * 0.42 +
              wobble * math.sin((t * 2 * math.pi * speed) + index);
          final p = centre + dir * along + side * across;

          return Transform.translate(
            offset: Offset(p.dx - diameter / 2, p.dy - diameter / 2),
            child: spin
                ? Transform.rotate(
                    angle: t * 2 * math.pi * (index.isEven ? 1 : -1),
                    child: child,
                  )
                : child,
          );
        },
      ),
    );
  }
}
