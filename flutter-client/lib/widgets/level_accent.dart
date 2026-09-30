import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/theme_colors.dart';
import 'table_ground.dart';

/// The open lobby level's colour, for what a lobby drawer draws in the house
/// gold (owner, 30 Sep 2026: "when i open setting while Entering Blind Card,
/// then Setting drawer Shade colour should change acc to card type colour, for
/// seen it is correct, but for blind and variation make it correct").
///
/// The lobby lays it over its two drawers, Settings and Stats, with the
/// palette of the level on screen — the room's own light, [AppTheme.paletteFor]
/// of the category open, or of the engine open — and the pieces inside them
/// that wear gold ask [LevelAccent.of]: the drawer's pearl, its head mark and
/// rule, the portrait's ring and pencil, the chosen number format, the sound
/// and vibration switches and the appearance control. Where no scope stands
/// (every other screen, the table's drawer), or the level's colour IS the
/// gold (the front, Seen, Teen Patti), [of] answers null and every one of them
/// draws exactly what it drew before: Seen was already right.
class LevelAccent extends InheritedWidget {
  const LevelAccent({super.key, required this.palette, required super.child});

  /// The palette the scope is coloured by — a category (`blind`,
  /// `variation`, …) or `poker` for the poker family — or null for the house
  /// gold.
  final String? palette;

  /// The colours of the level in scope, in the theme's brightness, or null
  /// where the house gold stands.
  static LevelColours? of(BuildContext context) {
    final key = context
        .dependOnInheritedWidgetOfExactType<LevelAccent>()
        ?.palette;
    if (key == null) return null;
    final scheme = Theme.of(context).colorScheme;
    final palette = AppTheme.paletteFor(scheme, category: key, bootAmount: 200);
    if (palette.accent == AppTheme.gold) return null;
    return LevelColours(palette, scheme.brightness);
  }

  @override
  bool updateShouldNotify(LevelAccent oldWidget) =>
      palette != oldWidget.palette;
}

/// A level's colour in each role the house gold plays in a drawer, one
/// brightness at a time.
///
/// The gold's roles and what takes them:
/// - a FILL — a wash, a disc, a switch's track: the level's accent (the
///   accent is pale by night and deep by day, as the gold's middle and foot
///   are), so a charcoal thumb stands on it by night and a white one by day.
/// - INK — a chosen word, a glyph: the accent by night (champagne's place) and
///   the palette's ink by day (deep gold's).
/// - a HAIRLINE — the same two, at the house hairline's own strengths.
/// - the drawer's GROUND — the pearl by day and the charcoal by night, turned
///   to the level's hue at their own lightness, a touch more saturated so the
///   hue reads: the Seen drawer's cream is the gold's, and this is Blind's
///   ice and Variation's lavender in the same measure.
class LevelColours {
  const LevelColours(this.palette, this.brightness);

  final TablePalette palette;
  final Brightness brightness;

  bool get _dark => brightness == Brightness.dark;

  /// Where the house fills with gold.
  Color get fill => palette.accent;

  /// Where the house writes in gold.
  Color get ink => _dark ? palette.accent : palette.ink;

  /// The house hairline ([AppTheme.hairlineColour]) in the level's colour.
  Color hairline({bool live = false}) => _dark
      ? palette.accent.withValues(
          alpha: live ? AppTheme.hairlineLive : AppTheme.hairlineResting,
        )
      : palette.ink.withValues(
          alpha: live
              ? AppTheme.hairlineLiveLight
              : AppTheme.hairlineRestingLight,
        );

  /// The edge a chosen thing wears: champagne at 0.55 by night, the live
  /// hairline by day — the store's own words for "chosen", in this colour.
  Color get chosenEdge =>
      _dark ? palette.accent.withValues(alpha: 0.55) : hairline(live: true);

  /// How much more saturated than the house's own the drawer's ground is
  /// laid, so a cool or violet hue reads at pearl's lightness as the warm
  /// cream does.
  static const double groundSaturation = 1.8;

  /// The level's hue.
  double get hue => HSLColor.fromColor(palette.accent).hue;

  /// [base] in the level's hue at its own lightness and alpha.
  Color inHue(Color base) {
    final hsl = HSLColor.fromColor(base);
    return hsl
        .withHue(hue)
        .withSaturation((hsl.saturation * groundSaturation).clamp(0.0, 1.0))
        .toColor()
        .withValues(alpha: base.a);
  }

  /// The day's pearl and its stone edge, in the level's hue.
  Color get pearl => inHue(TableGround.pearl);
  Color get pearlEdge => inHue(TableGround.pearlEdge);

  /// The night's charcoal, top and foot, in the level's hue.
  Color get charcoal => inHue(GlassColors.dark.cardFill);
  Color get charcoalEnd => inHue(GlassColors.dark.cardFillEnd);
}
