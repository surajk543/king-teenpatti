import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/game_state.dart';
import '../theme/app_theme.dart';
import 'chip_store.dart';
import 'poker_chip.dart';

/// The buy-chips button. Opens the chip store (`chip_store.dart`).
///
/// It is here in both the lobby and the game room because running dry is
/// exactly when a player looks for it, and that happens at the table as often
/// as before sitting down.
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
    final scheme = theme.colorScheme;
    final t = context.watch<GameState>().t;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => showChipStore(context),
        child: Container(
          padding: EdgeInsets.fromLTRB(compact ? 10 : 14, 8, compact ? 12 : 16, 8),
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppTheme.gold.withValues(alpha: 0.55)),
            boxShadow: AppTheme.controlShadow(theme.brightness),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PokerChip(colour: AppTheme.gold, size: compact ? 18 : 20),
              SizedBox(width: compact ? 6 : 8),
              Icon(Icons.add_rounded,
                  size: compact ? 15 : 17, color: scheme.onSecondaryContainer),
              if (!compact) ...[
                const SizedBox(width: 4),
                Text(
                  t.buyChips,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: scheme.onSecondaryContainer,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
