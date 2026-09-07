import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/game_state.dart';
import '../theme/app_theme.dart';
import 'poker_chip.dart';

/// The buy-chips button, and the answer it currently gives.
///
/// It is here in both the lobby and the game room because running dry is
/// exactly when a player looks for it, and that happens at the table as often
/// as before sitting down. There is nothing to sell yet, so it says so plainly
/// rather than being hidden until there is — a control that appears from
/// nowhere later is harder to find than one that has always been there.
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
        onTap: () => _showComingSoon(context),
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

Future<void> _showComingSoon(BuildContext context) {
  final t = context.read<GameState>().t;

  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.storefront_outlined),
      title: Text(t.comingSoon),
      content: Text(t.comingSoonBody),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.close),
        ),
      ],
    ),
  );
}
