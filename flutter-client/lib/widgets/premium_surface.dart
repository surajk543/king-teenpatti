import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

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
    this.radius = 24,
    this.glint = false,
    this.borderWidth = 1.5,
    this.tint,
    this.elevated = true,
  });

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;

    final strength = tint ?? (dark ? 0.20 : 0.13);
    final top = Color.alphaBlend(
      accent.withValues(alpha: strength),
      scheme.surfaceContainerHigh,
    );
    final bottom = dark ? scheme.surfaceContainerLowest : scheme.surfaceContainerLow;
    // The same tinted shadow the buttons cast, so everything in the app is lit
    // from one place.
    final shadow = AppTheme.shadowFor(theme.brightness);

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
        // it read as an object sitting on something.
        boxShadow: elevated
            ? [
                BoxShadow(
                  color: shadow.withValues(alpha: dark ? 0.62 : 0.16),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
                BoxShadow(
                  color: shadow.withValues(alpha: dark ? 0.45 : 0.13),
                  blurRadius: 22,
                  offset: const Offset(0, 10),
                ),
                BoxShadow(
                  color: accent.withValues(alpha: dark ? 0.20 : 0.13),
                  blurRadius: 30,
                  spreadRadius: -6,
                  offset: const Offset(0, 6),
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
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: radius,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: dark ? 0.10 : 0.34),
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

/// A thin highlight that travels across a surface, corner to corner, over and
/// over (requirement 28).
///
/// Deliberately narrow and faint: a wide, bright band covers the whole surface
/// at once, and that does not read as a moving light — it reads as a blink.
class Glint extends StatefulWidget {
  const Glint({super.key, required this.child, this.period = const Duration(milliseconds: 4200)});

  final Widget child;
  final Duration period;

  @override
  State<Glint> createState() => _GlintState();
}

class _GlintState extends State<Glint> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.period)..repeat();

  static const double _halfBand = 0.07;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strength =
        Theme.of(context).brightness == Brightness.dark ? 0.11 : 0.16;

    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
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
      ],
    );
  }
}
