import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/table_theme.dart';
import 'glass_components.dart';

/// "SEE CARDS": the viewer's look at their own blind hand, standing just ABOVE
/// the cards it turns, centred on them (owner's redesign brief, 3 Oct 2026:
/// "The current SEE CARDS button should NOT cover the cards ... Center aligned
/// with the player's cards. Positioned immediately ABOVE the cards ... Rounded
/// pill shape. Glass/dark translucent background. Thin gold border. Small eye
/// icon ... Subtle gold glow. Clearly tappable. It should look like part of
/// the card interaction rather than a generic button"). Until then it was a
/// ghost key laid over the middle of the fan.
///
/// Dark glass in both themes — it stands on the VIP table's emerald by day and
/// its wine-red by night — with the blind bets the player has left as dots
/// under the words ([BlindDots]): the count lives on the key that ends it.
/// The glow is still: a key that breathes is the console's Chaal alone.
///
/// The tap is the one it always was (`GameState.see`), once; the key leaves
/// when the server says the player is no longer blind, cross-fading out while
/// the cards turn over under it (`PlayingCard`'s flip).
class SeeCardsButton extends StatelessWidget {
  const SeeCardsButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.width,
    required this.height,
    this.blindLeft,
    this.blindMax,
    this.blindLabel,
  });

  /// "See cards", in the player's language. Set in capitals: a no-op for the
  /// Indic scripts, which have no case.
  final String label;
  final VoidCallback onPressed;
  final double width;
  final double height;

  /// The blind bets left and the table's allowance, for the dots; no dots
  /// without both.
  final int? blindLeft;
  final int? blindMax;

  /// What a screen reader hears for the dots ("Blind moves left").
  final String? blindLabel;

  /// The key's own key, for a test or a tutorial to find it by.
  static const Key tapKey = ValueKey('see-cards');

  /// The brief's 120–160dp, by the screen's width.
  static double widthFor(double screenWidth) =>
      (screenWidth * 0.17).clamp(120.0, 160.0);

  /// The brief's 40–48dp: 42 on a short phone, where the felt has least room
  /// over the cards, 46 elsewhere.
  static double heightFor(double screenHeight) =>
      screenHeight < 400 ? 42.0 : 46.0;

  /// The pill's gold, its edge's and its glow's.
  static const Color gold = AppTheme.goldBright;

  /// Dark, warm glass: a near-black with a brown undertone, a step lighter at
  /// its top where the table's lamp catches it.
  static const List<Color> glass = [Color(0xE8231B14), Color(0xF20C0907)];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dots = blindLeft != null && blindMax != null && blindMax! > 0;
    final style = TableType.secondaryAction(theme).copyWith(
      color: gold,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.8,
      height: 1.1,
    );
    const shape = StadiumBorder();

    return Semantics(
      button: true,
      label: dots ? '$label, ${blindLabel ?? ''} $blindLeft/$blindMax' : label,
      excludeSemantics: true,
      child: PressScale(
        child: SizedBox(
          width: width,
          height: height,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              shape: StadiumBorder(
                side: BorderSide(
                  color: gold.withValues(alpha: 0.78),
                  width: 1.3,
                ),
              ),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: glass,
              ),
              shadows: [
                // The subtle gold glow, and the contact shadow that sets the
                // pill on the cloth rather than floating it.
                BoxShadow(
                  color: gold.withValues(alpha: 0.30),
                  blurRadius: 16,
                  spreadRadius: -2,
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Material(
              type: MaterialType.transparency,
              shape: shape,
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: tapKey,
                customBorder: shape,
                splashColor: gold.withValues(alpha: 0.18),
                highlightColor: gold.withValues(alpha: 0.08),
                onTap: () {
                  tapHaptic(context);
                  onPressed();
                },
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: height * 0.32),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.visibility_rounded,
                        color: gold,
                        size: height * 0.42,
                      ),
                      SizedBox(width: height * 0.18),
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                label.toUpperCase(),
                                maxLines: 1,
                                style: style,
                              ),
                              if (dots) ...[
                                const SizedBox(height: 3),
                                BlindDots(
                                  left: blindLeft!,
                                  max: blindMax!,
                                  label: blindLabel,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// How many bets this player may still make without looking at their cards,
/// as dots rather than a fraction: on a 25-second clock a row of dots is read
/// at a glance and "3/4" is read twice. It sits under "SEE CARDS", where the
/// choice it counts down to is made.
class BlindDots extends StatelessWidget {
  const BlindDots({
    super.key,
    required this.left,
    required this.max,
    this.label,
  });

  final int left;
  final int max;

  /// What a screen reader hears before "left/max".
  final String? label;

  @override
  Widget build(BuildContext context) {
    // The last blind move is worth a warmer mark: the next bet after it turns
    // the cards face up whether the player looked or not.
    final lastOne = left <= 1;

    return Semantics(
      label: '${label ?? ''} $left/$max'.trim(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < max; i++)
            Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : Space.xs),
              child: _Pip(
                filled: i < left,
                colour: lastOne ? AppTheme.amber : AppTheme.goldBright,
              ),
            ),
        ],
      ),
    );
  }
}

/// One blind move, spent or unspent.
class _Pip extends StatelessWidget {
  const _Pip({required this.filled, required this.colour});

  final bool filled;
  final Color colour;

  @override
  Widget build(BuildContext context) => Container(
    width: 5,
    height: 5,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: filled ? colour : Colors.transparent,
      border: filled
          ? null
          : Border.all(color: AppTheme.ink400, width: Dim.hairline),
    ),
  );
}
