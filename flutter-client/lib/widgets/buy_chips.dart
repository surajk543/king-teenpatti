import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../settings/feedback_settings.dart';

import '../state/game_state.dart';
import '../theme/app_theme.dart';
import 'chip_store.dart';
import 'glass_components.dart';
import 'poker_chip.dart';
import 'shop_mark.dart';

/// The buy-chips button. Opens the chip store (`chip_store.dart`).
///
/// It is here in both the lobby and the game room because running dry is
/// exactly when a player looks for it, and that happens at the table as often
/// as before sitting down.
///
/// It is also the one gold control in the app. Everything around it —
/// felt, pods, plates, cards — is charcoal, cloth or bone, so a struck-metal
/// pill is the single loudest thing on either screen without having to shout,
/// and nothing else is allowed to borrow that fill.
///
/// The store shows the real shelf and the real prices, but no payment path is
/// wired up: choosing a pack says so and charges nothing. That is deliberate —
/// a button that looks like it took money is worse than one that admits it
/// cannot yet.
class BuyChipsButton extends StatelessWidget {
  const BuyChipsButton({super.key, this.compact = false});

  /// The game room's version: the same button with the label dropped, because
  /// the felt has less room to spare than the lobby.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.watch<GameState>().t;

    // A struck edge: bright along the top, deep along the bottom, so the pill
    // reads as a piece of metal catching the room's one lamp. The ink on it is
    // the app's own dark-on-light ink, the same one a card face uses.
    const face = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFE4BF52), AppTheme.gold, AppTheme.goldDeep],
      stops: [0, 0.55, 1],
    );

    final radius = BorderRadius.circular(
      compact ? Dim.minTouch / 2 : Radii.pill,
    );

    // The press-down scale sits outside the bloom so the glow shrinks with
    // the key rather than staying put behind it.
    return PressScale(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          // A bloom is the app's reserved "the game did something" signal, and
          // this is the one control that carries it standing still: it is an
          // offer, not a move.
          boxShadow: AppTheme.controlShadow(
            theme.brightness,
            elevation: 4,
            bloom: AppTheme.gold,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: Ink(
            decoration: BoxDecoration(
              gradient: face,
              borderRadius: radius,
              // The lit top bevel, in the same champagne the rest of the app
              // uses for a lit edge.
              border: Border(
                top: BorderSide(
                  color: AppTheme.goldBright.withValues(alpha: 0.75),
                ),
              ),
            ),
            child: InkWell(
              // Material's own click, gated on the player's Sound switch —
              // otherwise a silenced game would still tick on every tap.
              enableFeedback: context.select<FeedbackSettings, bool>(
                (f) => f.sound,
              ),
              onTap: () => showChipStore(context),
              splashColor: AppTheme.inkOnLight.withValues(alpha: 0.16),
              highlightColor: AppTheme.inkOnLight.withValues(alpha: 0.08),
              child: ConstrainedBox(
                // Both shapes clear the touch floor: a 44dp disc on the felt,
                // a 44dp-tall pill in the lobby.
                constraints: const BoxConstraints(
                  minWidth: Dim.minTouch,
                  minHeight: Dim.minTouch,
                ),
                child: compact
                    ? const Center(
                        child: Icon(
                          Icons.add_rounded,
                          size: 24,
                          color: AppTheme.inkOnLight,
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Space.lg,
                          vertical: Space.sm,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Dark stock on the gold face; a gold chip on a gold
                            // pill is a hole.
                            const PokerChip(
                              colour: AppTheme.inkOnLight,
                              size: 20,
                            ),
                            const SizedBox(width: Space.sm),
                            Text(
                              t.buyChips,
                              style: AppTheme.label(
                                theme.textTheme.labelLarge ?? const TextStyle(),
                                colour: AppTheme.inkOnLight,
                                weight: FontWeight.w700,
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

/// The Shop button in the lobby's top bar.
///
/// The same destination as [BuyChipsButton], but it lives in the rail beside
/// the balance rather than in a corner of the floor: the place a player
/// already looks when they want to know what they can afford is the place to
/// offer them more. The same widget is the table's top-left Shop key.
///
/// An ice face ([ShopFace]) lifted a little off the bar, rimmed and lit in the
/// blue its shop is drawn in, with a restrained blue bloom under it (owner,
/// 30 Sep 2026: "The Shop button background colour yellow does not look good
/// with blue icon, change yellow to something else which looks good in day
/// and night mode both" — it was struck gold, [AppTheme.goldFace], from
/// 24 Sep 2026). One thing moves, slowly enough to notice rather than nag: a
/// soft highlight crosses the face every six seconds and spends the rest of
/// the cycle off its edge, so the key is still far more often than not.
class ShopButton extends StatefulWidget {
  const ShopButton({super.key, this.compact = false, this.click = false});

  /// The storefront alone, without the word. The lobby's top bar asks for it
  /// when the row is tight (a 640dp phone), where the label cost the player's
  /// name its letters; a tooltip still names the key.
  final bool compact;

  /// The lobby's Shop key: the tap plays [lobbyClick] in place of Material's
  /// platform tick (owner, 27 Sep 2026). The table's Shop key keeps the tick.
  final bool click;

  @override
  State<ShopButton> createState() => _ShopButtonState();
}

/// The Shop key's face (owner, 30 Sep 2026): the ice its shop was drawn
/// for. `assets/animations/Shop.json` is a shopfront stroked in #1365E8 and
/// filled in white and pale blues, so the key is a white-to-pale-blue face
/// rimmed in that blue, its word in a deeper blue, its bloom blue — one
/// family, where the struck gold it replaced set the icon's blue against its
/// complement.
///
/// By day the face is the brief's ice, and the rim, a slate contact shadow
/// and the bloom are what stand it off the pale bar, which it all but
/// matches. By night a white key would be the brightest thing on the obsidian
/// by far — glare — so the face is the same gradient a step down and the rim
/// quieter; the word and the icon keep their contrast on both (the tests
/// measure every stop).
abstract final class ShopFace {
  /// The blue the owner's shop is stroked in: the rim and the bloom.
  static const Color iconBlue = Color(0xFF1365E8);

  /// The word "Shop" (and the fallback storefront): a deeper blue of the
  /// same hue, 5.7:1 on the day face's foot and 4.7:1 on the night face's —
  /// the night face can go no dimmer than that without losing its word.
  static const Color ink = Color(0xFF0E4FC0);

  /// The face, lit at the top and a paler blue at the foot.
  static LinearGradient face(Brightness b) => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: b == Brightness.dark ? _night : _day,
    stops: const [0, 0.52, 1],
  );

  static const List<Color> _day = [
    Color(0xFFFFFFFF),
    Color(0xFFEAF3FF),
    Color(0xFFD3E6FF),
  ];
  static const List<Color> _night = [
    Color(0xFFE2EDFF),
    Color(0xFFCADFFF),
    Color(0xFFB6D2FA),
  ];

  /// The rim, all round the key, in the icon's blue. By day it is what
  /// parts an all-but-white key from an all-but-white bar, so it is laid
  /// strong enough to stand 3:1 against the lobby's bar and the table's pearl
  /// room over every stop of the face; by night the face itself stands
  /// clear of the obsidian and the rim is only its edge.
  static const double rimWidth = 1.5;
  static Color rim(Brightness b) =>
      iconBlue.withValues(alpha: b == Brightness.dark ? 0.55 : 0.75);

  /// What the key casts: a contact shadow and a soft one under it, and the
  /// blue bloom — the key's standing offer, as the gold one was.
  static List<BoxShadow> shadows(Brightness b) => b == Brightness.dark
      ? [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            blurRadius: 7.5,
            offset: const Offset(0, 2.4),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.26),
            blurRadius: 3,
            offset: const Offset(0, 0.75),
          ),
          BoxShadow(
            color: iconBlue.withValues(alpha: 0.24),
            blurRadius: 18,
            spreadRadius: -4,
            offset: const Offset(0, 3),
          ),
        ]
      : [
          BoxShadow(
            color: AppTheme.shadowFor(b).withValues(alpha: 0.22),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
          BoxShadow(
            color: AppTheme.shadowFor(b).withValues(alpha: 0.16),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
          BoxShadow(
            color: iconBlue.withValues(alpha: 0.20),
            blurRadius: 16,
            spreadRadius: -3,
            offset: const Offset(0, 3),
          ),
        ];
}

/// The key's shop, where the storefront icon was.
const Widget _shopMark = ShopMark(size: 19, fallbackInk: ShopFace.ink);

class _ShopButtonState extends State<ShopButton>
    with SingleTickerProviderStateMixin {
  // Created here, never lazily: a late controller first read in dispose()
  // builds itself against a deactivated element and takes the teardown with it
  // (CLAUDE.md §12.3).
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 6000),
  )..repeat();

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.watch<GameState>().t;
    final radius = BorderRadius.circular(Radii.pill);
    final brightness = theme.brightness;

    // The lift is still, so it is laid once, outside the animation. The face
    // is opaque, so its shadow may sit under it (CLAUDE.md §8.4 "The depth
    // pass": only a translucent surface must cast round itself).
    return DecoratedBox(
      key: const ValueKey('shop-key-lift'),
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: ShopFace.shadows(brightness),
      ),
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _sweep,
          builder: (context, child) {
            // The sweep crosses in the first fifth of the cycle and rests for
            // the rest of it: a shine every second would be a fairground, not
            // an offer.
            final t0 = (_sweep.value / 0.2).clamp(0.0, 1.0);

            return ClipRRect(
              borderRadius: radius,
              child: Stack(
                children: [
                  child!,
                  // The highlight itself: a soft diagonal band travelling left
                  // to right, off both edges at the ends of its run.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: FractionallySizedBox(
                        widthFactor: 0.35,
                        alignment: Alignment(-2.6 + 5.2 * t0, 0),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Colors.white.withValues(alpha: 0),
                                Colors.white.withValues(alpha: 0.30),
                                Colors.white.withValues(alpha: 0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
          // Built once and handed to the builder: the face does not depend on
          // the animation, so it must not be rebuilt sixty times a second.
          child: PressScale(
            // The rim is painted OVER the face rather than drawn as the Ink's
            // border, which would pad the key by its width: the key keeps
            // exactly the size it had.
            child: DecoratedBox(
              key: const ValueKey('shop-key-rim'),
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(
                  color: ShopFace.rim(brightness),
                  width: ShopFace.rimWidth,
                ),
              ),
              child: Material(
                color: Colors.transparent,
                borderRadius: radius,
                clipBehavior: Clip.antiAlias,
                child: Ink(
                  key: const ValueKey('shop-key-face'),
                  decoration: BoxDecoration(
                    gradient: ShopFace.face(brightness),
                    borderRadius: radius,
                    // The lit top edge of the ice.
                    border: Border(
                      top: BorderSide(
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                  child: InkWell(
                    enableFeedback:
                        !widget.click &&
                        context.select<FeedbackSettings, bool>((f) => f.sound),
                    onTap: () {
                      if (widget.click) lobbyClick(context);
                      showChipStore(context);
                    },
                    splashColor: AppTheme.inkOnLight.withValues(alpha: 0.16),
                    highlightColor: AppTheme.inkOnLight.withValues(alpha: 0.08),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: Dim.minTouch,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Space.md,
                          vertical: Space.xs,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // The owner's shop Lottie (29 Sep 2026) in the
                            // storefront icon's box.
                            if (widget.compact)
                              Tooltip(message: t.shop, child: _shopMark)
                            else
                              _shopMark,
                            if (!widget.compact)
                              const SizedBox(width: Space.xs),
                            if (!widget.compact)
                              Text(
                                t.shop,
                                style: AppTheme.label(
                                  theme.textTheme.labelLarge ??
                                      const TextStyle(),
                                  colour: ShopFace.ink,
                                  weight: FontWeight.w700,
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
          ),
        ),
      ),
    );
  }
}
