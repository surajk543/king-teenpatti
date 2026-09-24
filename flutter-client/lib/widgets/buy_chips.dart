import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../settings/feedback_settings.dart';

import '../state/game_state.dart';
import '../theme/app_theme.dart';
import 'chip_store.dart';
import 'glass_components.dart';
import 'poker_chip.dart';

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
/// The same destination as [BuyChipsButton] and the same gold, but it lives in
/// the rail beside the balance rather than in a corner of the floor: the place
/// a player already looks when they want to know what they can afford is the
/// place to offer them more.
///
/// Struck gold ([AppTheme.goldFace]) lifted a little off the bar, with a
/// restrained gold bloom under it — the one strong gold key in the lobby
/// (owner, 24 Sep 2026: "gold gradient, subtle elevation, clean icon,
/// restrained shadow"). One thing moves, slowly enough to notice rather than
/// nag: a soft highlight crosses the face every six seconds and spends the
/// rest of the cycle off its edge, so the key is still far more often than
/// not. The breathing bloom it had is gone; a shadow that pulses is noise.
class ShopButton extends StatefulWidget {
  const ShopButton({super.key, this.compact = false});

  /// The storefront alone, without the word. The lobby's top bar asks for it
  /// when the row is tight (a 640dp phone), where the label cost the player's
  /// name its letters; a tooltip still names the key.
  final bool compact;

  @override
  State<ShopButton> createState() => _ShopButtonState();
}

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

    // The lift is still, so it is laid once, outside the animation.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: AppTheme.controlShadow(
          theme.brightness,
          elevation: 3,
          bloom: AppTheme.gold,
        ),
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
            child: Material(
              color: Colors.transparent,
              borderRadius: radius,
              clipBehavior: Clip.antiAlias,
              child: Ink(
                decoration: BoxDecoration(
                  gradient: AppTheme.goldFace,
                  borderRadius: radius,
                  // The lit top edge of struck metal.
                  border: Border(
                    top: BorderSide(
                      color: Colors.white.withValues(alpha: 0.55),
                    ),
                  ),
                ),
                child: InkWell(
                  enableFeedback: context.select<FeedbackSettings, bool>(
                    (f) => f.sound,
                  ),
                  onTap: () => showChipStore(context),
                  splashColor: AppTheme.inkOnLight.withValues(alpha: 0.16),
                  highlightColor: AppTheme.inkOnLight.withValues(alpha: 0.08),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: Dim.minTouch),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Space.md,
                        vertical: Space.xs,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.compact)
                            Tooltip(
                              message: t.shop,
                              child: const Icon(
                                Icons.storefront_rounded,
                                size: 19,
                                color: AppTheme.inkOnLight,
                              ),
                            )
                          else
                            const Icon(
                              Icons.storefront_rounded,
                              size: 19,
                              color: AppTheme.inkOnLight,
                            ),
                          if (!widget.compact) const SizedBox(width: Space.xs),
                          if (!widget.compact)
                            Text(
                              t.shop,
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
        ),
      ),
    );
  }
}
