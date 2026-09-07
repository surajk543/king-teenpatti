import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/game_state.dart';
import 'playing_card.dart';

/// The hand rankings, shown over whatever the player was looking at.
///
/// Deliberately translucent: it is a reference, not a place you go. The table
/// or the lobby stays visible behind it so a player can check what beats what
/// without losing their place.
Future<void> showRules(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (context) => const _RulesSheet(),
  );
}

class _RulesSheet extends StatelessWidget {
  const _RulesSheet();

  /// Every ranking, strongest first, each with a hand that shows it. The order
  /// and the names are the server's own — this is a picture of how the
  /// showdown actually scores, not a separate description of the rules.
  static const List<(String, List<String>)> _examples = [
    ('trail', ['Ah', 'Ad', 'Ac']),
    ('pureSeq', ['Kh', 'Qh', 'Jh']),
    ('seq', ['Ks', 'Qd', 'Jc']),
    ('color', ['As', '9s', '4s']),
    ('pair', ['Qh', 'Qc', '7d']),
    ('high', ['Ad', 'Jc', '8s']),
  ];

  @override
  Widget build(BuildContext context) {
    final t = context.watch<GameState>().t;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final labels = {
      'trail': (t.rankTrail, t.rankTrailNote),
      'pureSeq': (t.rankPureSeq, t.rankPureSeqNote),
      'seq': (t.rankSeq, t.rankSeqNote),
      'color': (t.rankColor, t.rankColorNote),
      'pair': (t.rankPair, t.rankPairNote),
      'high': (t.rankHigh, t.rankHighNote),
    };

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          // Translucent, so the game reads through it.
          color: scheme.surface.withValues(alpha: 0.86),
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: scheme.primary.withValues(alpha: 0.45), width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.menu_book_outlined, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      t.rulesTitle,
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              Text(t.rulesBeats, style: theme.textTheme.bodySmall),
              const SizedBox(height: 10),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (var i = 0; i < _examples.length; i++)
                        _Row(
                          place: i + 1,
                          name: labels[_examples[i].$1]!.$1,
                          note: labels[_examples[i].$1]!.$2,
                          cards: _examples[i].$2,
                          // Each rank beats every one below it, which the
                          // arrow between rows says without words.
                          showArrow: i < _examples.length - 1,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.runOrder,
                        style: theme.textTheme.labelLarge
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    Text(t.runOrderNote, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.place,
    required this.name,
    required this.note,
    required this.cards,
    required this.showArrow,
  });

  final int place;
  final String name;
  final String note;
  final List<String> cards;
  final bool showArrow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: scheme.primaryContainer,
              child: Text(
                '$place',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 168,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800)),
                  Text(note,
                      maxLines: 2,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            const Spacer(),
            for (final c in cards) PlayingCard(height: 46, code: c),
          ],
        ),
        if (showArrow)
          Icon(Icons.keyboard_arrow_down,
              size: 16, color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
      ],
    );
  }
}
