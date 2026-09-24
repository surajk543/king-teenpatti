import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/theme_colors.dart';
import 'glass_orb.dart';
import 'premium_surface.dart';

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
      edge: lit ? accent.withValues(alpha: dark ? 0.42 : 0.50) : null,
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
