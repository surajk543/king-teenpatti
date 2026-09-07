import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';

/// The app's Material 3 theme.
///
/// Both schemes come from one seed so light and dark are the same palette at
/// different tones, which is what keeps the two modes recognisably the same
/// game rather than two different skins. Everything the UI draws reads its
/// colour from the scheme; the only exceptions are the felt and the cards,
/// which are physical objects and look the same under any lighting.
/// The colours one table is told apart by.
///
/// Three tables, three identities: the seen table is gold, the small blind
/// table is sapphire, the high-stakes blind table is royal purple. The lobby
/// card, the felt, the tag over the pot and the badges all draw from the same
/// palette, so the room a player sits down in matches the card they tapped.
class TablePalette {
  const TablePalette({
    required this.accent,
    required this.container,
    required this.onContainer,
    required this.icon,
    required this.tint,
  });

  /// The table's signature colour: borders, glows, the chip stack.
  final Color accent;

  /// A filled surface in the table's colour, for badges and tags.
  final Color container;
  final Color onContainer;

  /// The mark the table carries: an eye, a crossed eye, or a crown.
  final IconData icon;

  /// How deeply the felt and the card are washed in the accent.
  final double tint;
}

class AppTheme {
  const AppTheme._();

  /// A deep casino green, used as the seed for both schemes.
  static const Color _seed = Color(0xFF0F5236);
  static const Color _gold = Color(0xFFC9A227);

  /// The rim around the table, and the accent on chips and stakes.
  static const Color gold = _gold;

  /// Royal purple for the high-stakes blind table, one shade per brightness.
  static const Color _royal = Color(0xFF6D4BC4);
  static const Color _royalDark = Color(0xFFC9B3FF);

  /// The palette for a table of this category and stake. Blind tables at or
  /// above 1,000 boot are the high-stakes ones and wear the purple.
  static TablePalette paletteFor(
    ColorScheme scheme, {
    required String category,
    required int bootAmount,
  }) {
    final dark = scheme.brightness == Brightness.dark;
    if (category != 'blind') {
      return TablePalette(
        accent: _gold,
        container: scheme.secondaryContainer,
        onContainer: scheme.onSecondaryContainer,
        icon: Icons.visibility_rounded,
        tint: dark ? 0.26 : 0.18,
      );
    }
    if (bootAmount >= 1000) {
      return TablePalette(
        accent: dark ? _royalDark : _royal,
        container: dark ? const Color(0xFF3B2A6B) : const Color(0xFFE9DEFF),
        onContainer: dark ? const Color(0xFFEDE4FF) : const Color(0xFF261452),
        icon: Icons.workspace_premium_rounded,
        tint: dark ? 0.34 : 0.24,
      );
    }
    return TablePalette(
      accent: scheme.tertiary,
      container: scheme.tertiaryContainer,
      onContainer: scheme.onTertiaryContainer,
      icon: Icons.visibility_off_rounded,
      tint: dark ? 0.26 : 0.18,
    );
  }

  /// A playing card's face is white and its pips red or black, whatever the
  /// theme is doing.
  static const Color cardFace = Color(0xFFF8F8F5);
  static const Color pipRed = Color(0xFFC62828);
  static const Color pipBlack = Color(0xFF1A1A1A);

  /// The colour a raised control casts.
  ///
  /// Not black: a neutral shadow under a warm gold-and-green palette reads as
  /// grubby. Tinting it towards the seed keeps the depth without dulling what
  /// is underneath — and in the dark scheme it goes darker than the surface
  /// rather than lighter, or the buttons would glow instead of lift.
  static Color shadowFor(Brightness brightness) => brightness == Brightness.dark
      ? const Color(0xFF000000)
      : const Color(0xFF0B3524);

  /// Elevation for a button, by state: lifted at rest, higher under a pointer,
  /// and pressed down flat under a finger, so it behaves like a physical key.
  ///
  /// A disabled button sits flush. Nothing about it can be pressed, and a
  /// shadow under something dead is the thing that makes a UI look cheap.
  static WidgetStateProperty<double> liftElevation(double rest) =>
      WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return 0;
        if (states.contains(WidgetState.pressed)) return rest / 3;
        if (states.contains(WidgetState.hovered)) return rest * 2;
        return rest;
      });

  /// Adds that lift to every button the app can raise.
  ///
  /// Text buttons are deliberately left flat: they are the quiet half of a
  /// dialog's pair, and a shadow under "Cancel" would fight the button it is
  /// meant to defer to.
  static ThemeData _raisedButtons(ThemeData theme) {
    final shadow = shadowFor(theme.brightness);

    ButtonStyle lift(double rest) => ButtonStyle(
          elevation: liftElevation(rest),
          shadowColor: WidgetStatePropertyAll(shadow),
          // M3 tints a raised surface by elevation as well as shadowing it.
          // The buttons here are already solidly coloured, so the tint only
          // muddies them.
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        );

    return theme.copyWith(
      filledButtonTheme: FilledButtonThemeData(style: lift(3)),
      elevatedButtonTheme: ElevatedButtonThemeData(style: lift(3)),
      outlinedButtonTheme: OutlinedButtonThemeData(style: lift(1)),
    );
  }

  /// The same lift, for a button the button themes do not reach — an icon
  /// button with a background of its own.
  static ButtonStyle raisedIcon(Brightness brightness, {double rest = 3}) =>
      ButtonStyle(
        elevation: liftElevation(rest),
        shadowColor: WidgetStatePropertyAll(shadowFor(brightness)),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      );

  /// The same lift for something drawn by hand rather than by a button — the
  /// bet stepper's amount, say — so a row of controls sits at one height.
  static List<BoxShadow> controlShadow(Brightness brightness,
          {double elevation = 3}) =>
      [
        BoxShadow(
          color: shadowFor(brightness).withValues(alpha: 0.22),
          blurRadius: elevation * 2.5,
          offset: Offset(0, elevation * 0.8),
        ),
        BoxShadow(
          color: shadowFor(brightness).withValues(alpha: 0.10),
          blurRadius: elevation,
          offset: Offset(0, elevation * 0.25),
        ),
      ];

  static ThemeData light() => _raisedButtons(FlexThemeData.light(
        colors: const FlexSchemeColor(
          primary: _seed,
          primaryContainer: Color(0xFF9BF3C0),
          secondary: Color(0xFF6D5C00),
          secondaryContainer: Color(0xFFFFE08B),
          tertiary: Color(0xFF1B6683),
          tertiaryContainer: Color(0xFFC4E7FF),
          appBarColor: Color(0xFFFFE08B),
          error: Color(0xFFBA1A1A),
        ),
        useMaterial3: true,
        subThemesData: _subThemes,
        visualDensity: VisualDensity.standard,
      ));

  static ThemeData dark() => _raisedButtons(FlexThemeData.dark(
        colors: const FlexSchemeColor(
          primary: Color(0xFF7FD6A4),
          primaryContainer: Color(0xFF00522F),
          secondary: Color(0xFFE8C46A),
          secondaryContainer: Color(0xFF574400),
          tertiary: Color(0xFFA0CFE8),
          tertiaryContainer: Color(0xFF1F4C60),
          appBarColor: Color(0xFF574400),
          error: Color(0xFFFFB4AB),
        ),
        useMaterial3: true,
        subThemesData: _subThemes,
        visualDensity: VisualDensity.standard,
      ));

  /// Shared component shaping. The game is full of pills and rounded cards, so
  /// the radii live here rather than being repeated at every call site.
  static const FlexSubThemesData _subThemes = FlexSubThemesData(
    defaultRadius: 20,
    filledButtonRadius: 40,
    elevatedButtonRadius: 40,
    outlinedButtonRadius: 40,
    textButtonRadius: 40,
    cardRadius: 24,
    dialogRadius: 28,
    inputDecoratorRadius: 16,
    inputDecoratorIsFilled: true,
    inputDecoratorBorderType: FlexInputBorderType.outline,
    chipRadius: 10,
    blendOnColors: false,
    interactionEffects: true,
    tintedDisabledControls: true,
  );
}
