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
