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
/// ghost key laid over the middle of the fan. Since the same night it stands
/// a little LEFT of the cards' centre, with air between it and the bet badge
/// on its right (owner: "Move see button to little left and add some space in
/// right side of see pill"; `_OwnBetRow` in table_screen.dart places it).
///
/// Dark glass in both themes — it stands on the VIP table's emerald by day and
/// its wine-red by night — with the blind bets the player has left as dots
/// under its eye and word ([BlindDots]): the count lives on the key that ends
/// it.
/// The glow is still: a key that breathes is the console's Chaal alone.
///
/// The tap is the one it always was (`GameState.see`), once; the key leaves
/// when the server says the player is no longer blind, cross-fading out while
/// the cards turn over under it (`PlayingCard`'s flip).
///
/// It says "SEE" and nothing more (owner, 3 Oct 2026: "instead of showing
/// See cards text, only show text 'See'"): the cards it turns stand right
/// under it. A screen reader still hears the fuller words ([semanticsLabel]).
class SeeCardsButton extends StatelessWidget {
  const SeeCardsButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.width,
    required this.height,
    this.semanticsLabel,
    this.blindLeft,
    this.blindMax,
    this.blindLabel,
  });

  /// The word on the key — "See" in the player's language (`Strings.see`).
  /// Set in capitals: a no-op for the Indic scripts, which have no case.
  final String label;

  /// What a screen reader hears in [label]'s place, before the blind moves
  /// left: the fuller words ("See cards", `Strings.seeCards`), which the key
  /// itself shortens. [label] where null.
  final String? semanticsLabel;
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

  /// The key's BOX, which is what takes the tap: 42dp on a short phone, where
  /// the felt has least room over the cards, 46 elsewhere. The pill drawn in
  /// it is [pillShare] of that ([pillHeightFor]), so the target stays the
  /// brief's 40–48dp while the pill itself is smaller (owner, 3 Oct 2026:
  /// "reduce the size of see button") — and the hand's column, laid out round
  /// the box, stands exactly where it did.
  static double heightFor(double screenHeight) =>
      screenHeight < 400 ? 42.0 : 46.0;

  /// How much of its box the pill fills, top to bottom: 33dp of 42, 36 of 46.
  static const double pillShare = 0.78;

  /// The pill's own height in a box [height] tall.
  static double pillHeightFor(double height) => height * pillShare;

  /// The pill's padding at each end, the eye and the step after it, as shares
  /// of the pill's height.
  static const double _padShare = 0.30;
  static const double _eyeShare = 0.46;
  static const double _gapShare = 0.16;

  /// The widest the pill grows, however long its word: what was its narrowest
  /// when it said "SEE CARDS".
  static const double maxWidth = 120;

  /// The word's type, which [widthFor] measures and the key draws.
  static TextStyle labelStyle(ThemeData theme) =>
      TableType.secondaryAction(theme).copyWith(
        color: gold,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        height: 1.1,
      );

  /// As wide as the pill's eye and its word — or its row of blind dots, when
  /// that is wider — in this language at this text size, and never narrower
  /// than a round-ended pill twice and a fifth as wide as it is tall. It used
  /// to be 120–160dp by the screen's width, the room "SEE CARDS" needed; one
  /// word needs about half that, so the word sets the width now and is never
  /// set smaller to fit it.
  static double widthFor(
    BuildContext context, {
    required String label,
    required double height,
    int? blindMax,
  }) {
    final pill = pillHeightFor(height);
    final painter = TextPainter(
      text: TextSpan(
        text: label.toUpperCase(),
        style: labelStyle(Theme.of(context)),
      ),
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      textScaler: MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling,
      maxLines: 1,
    )..layout();
    final word = painter.width;
    painter.dispose();
    final max = blindMax ?? 0;
    final dots = max > 0 ? max * BlindDots.pip + (max - 1) * Space.xs : 0.0;
    final line = pill * (_eyeShare + _gapShare) + word + 0.8;
    final content =
        pill * 2 * _padShare +
        (line > dots ? line : dots) +
        // A pixel of slack either side, so rounding never sets the word down.
        2;
    return content.clamp(pill * 2.2, maxWidth).ceilToDouble();
  }

  /// The pill's gold, its edge's and its glow's.
  static const Color gold = AppTheme.goldBright;

  /// Dark, warm glass: a near-black with a brown undertone, a step lighter at
  /// its top where the table's lamp catches it.
  static const List<Color> glass = [Color(0xE8231B14), Color(0xF20C0907)];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dots = blindLeft != null && blindMax != null && blindMax! > 0;
    final style = labelStyle(theme);
    final pill = pillHeightFor(height);
    const shape = StadiumBorder();
    final spoken = semanticsLabel ?? label;
    void tap() {
      tapHaptic(context);
      onPressed();
    }

    return Semantics(
      button: true,
      label: dots
          ? '$spoken, ${blindLabel ?? ''} $blindLeft/$blindMax'
          : spoken,
      onTap: tap,
      excludeSemantics: true,
      // The whole box takes the tap, the margins over and under the pill
      // too; a tap on the pill itself is the ink well's, with its ripple.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: tap,
        child: PressScale(
          child: SizedBox(
            width: width,
            height: height,
            child: Center(
              child: SizedBox(
                width: width,
                height: pill,
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
                      // The subtle gold glow, and the contact shadow that sets
                      // the pill on the cloth rather than floating it.
                      BoxShadow(
                        color: gold.withValues(alpha: 0.30),
                        blurRadius: 12,
                        spreadRadius: -2,
                      ),
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.45),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
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
                      onTap: tap,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: pill * _padShare,
                        ),
                        child: Center(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // The eye on the word's own line, and the
                                // dots centred under the two together.
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.visibility_rounded,
                                      color: gold,
                                      size: pill * _eyeShare,
                                    ),
                                    SizedBox(width: pill * _gapShare),
                                    // The word's trailing letter-spacing
                                    // matched on its left, so its ink is
                                    // centred where its box is.
                                    Padding(
                                      padding: EdgeInsets.only(
                                        left: style.letterSpacing ?? 0,
                                      ),
                                      child: Text(
                                        label.toUpperCase(),
                                        maxLines: 1,
                                        style: style,
                                      ),
                                    ),
                                  ],
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
                      ),
                    ),
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
/// at a glance and "3/4" is read twice. It sits under "SEE", where the choice
/// it counts down to is made.
class BlindDots extends StatelessWidget {
  const BlindDots({
    super.key,
    required this.left,
    required this.max,
    this.label,
  });

  final int left;
  final int max;

  /// One dot's diameter.
  static const double pip = 4;

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
    width: BlindDots.pip,
    height: BlindDots.pip,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: filled ? colour : Colors.transparent,
      border: filled
          ? null
          : Border.all(color: AppTheme.ink400, width: Dim.hairline),
    ),
  );
}
