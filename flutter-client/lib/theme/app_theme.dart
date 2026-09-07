import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';

/// The app's Material 3 theme.
///
/// Both schemes come from one seed so light and dark are the same palette at
/// different tones, which is what keeps the two modes recognisably the same
/// game rather than two different skins. Everything the UI draws reads its
/// colour from the scheme; the only exceptions are the felt and the cards,
/// which are physical objects and look the same under any lighting.
class AppTheme {
  const AppTheme._();

  /// A deep casino green, used as the seed for both schemes.
  static const Color _seed = Color(0xFF0F5236);
  static const Color _gold = Color(0xFFC9A227);

  /// The rim around the table, and the accent on chips and stakes.
  static const Color gold = _gold;

  /// A playing card's face is white and its pips red or black, whatever the
  /// theme is doing.
  static const Color cardFace = Color(0xFFF8F8F5);
  static const Color pipRed = Color(0xFFC62828);
  static const Color pipBlack = Color(0xFF1A1A1A);

  static ThemeData light() => FlexThemeData.light(
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
      );

  static ThemeData dark() => FlexThemeData.dark(
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
      );

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
