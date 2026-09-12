import 'dart:math' as math;

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
/// It moves, and that is the point of it — a still gold pill next to a counting
/// balance reads as part of the furniture. Two things move, both slow enough to
/// notice rather than nag: a highlight sweeps the face every few seconds, and
/// the bloom behind it breathes. The sweep spends most of its cycle off the
/// right-hand edge, so the button is quiet far more often than it is not.
class ShopButton extends StatefulWidget {
  const ShopButton({super.key});

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
    duration: const Duration(milliseconds: 3200),
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

    const face = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFE4BF52), AppTheme.gold, AppTheme.goldDeep],
      stops: [0, 0.55, 1],
    );

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _sweep,
        builder: (context, child) {
          // The sweep runs over the first third of the cycle and rests for the
          // other two: a shine every second would be a fairground, not an offer.
          final t0 = (_sweep.value / 0.34).clamp(0.0, 1.0);
          final breathing = 0.5 + 0.5 * math.sin(_sweep.value * 2 * math.pi);

          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: AppTheme.controlShadow(
                theme.brightness,
                elevation: 4 + 2 * breathing,
                bloom: AppTheme.gold,
              ),
            ),
            child: ClipRRect(
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
                                Colors.white.withValues(alpha: 0.42),
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
                gradient: face,
                borderRadius: radius,
                border: Border(
                  top: BorderSide(
                    color: AppTheme.goldBright.withValues(alpha: 0.75),
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
                        const Icon(
                          Icons.storefront_rounded,
                          size: 19,
                          color: AppTheme.inkOnLight,
                        ),
                        const SizedBox(width: Space.xs),
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
    );
  }
}
