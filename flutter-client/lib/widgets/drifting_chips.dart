import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'poker_chip.dart';

/// Faint poker chips rising through a screen, each on its own slow path.
///
/// Seven chips, fixed paths, one ticker. Drawn well behind the lobby's cards
/// or the table's felt, at low opacity: the point is that the surface is
/// alive, not that anything is happening on it. One widget, so the lobby and
/// every game room breathe the same way.
class DriftingChips extends StatefulWidget {
  const DriftingChips({super.key});

  @override
  State<DriftingChips> createState() => _DriftingChipsState();
}

class _DriftingChipsState extends State<DriftingChips>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 28),
  )..repeat();

  // x as a fraction of the width, size in dp, speed in screens per cycle,
  // phase offset, wobble amplitude in dp.
  static const _paths = <(double, double, double, double, double)>[
    (0.06, 34, 1.0, 0.00, 18),
    (0.19, 22, 1.6, 0.35, 12),
    (0.33, 46, 0.8, 0.70, 22),
    (0.52, 26, 1.3, 0.15, 14),
    (0.68, 38, 0.9, 0.55, 20),
    (0.83, 20, 1.7, 0.85, 10),
    (0.94, 30, 1.1, 0.40, 16),
  ];

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final colours = [
      scheme.primary,
      AppTheme.gold,
      scheme.tertiary,
      AppTheme.paletteFor(scheme, category: 'blind', bootAmount: 5000).accent,
    ];

    return LayoutBuilder(
      builder: (context, box) => AnimatedBuilder(
        animation: _clock,
        builder: (context, _) {
          final t = _clock.value;
          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              for (var i = 0; i < _paths.length; i++)
                () {
                  final (fx, size, speed, phase, wobble) = _paths[i];
                  // Rises from below the bottom edge to above the top, then
                  // comes round again.
                  final progress = (t * speed + phase) % 1.0;
                  final y = box.maxHeight * (1.1 - 1.3 * progress);
                  final x = fx * box.maxWidth +
                      wobble * math.sin((t * 6.283 * speed) + i);
                  return Positioned(
                    left: x - size / 2,
                    top: y - size / 2,
                    child: Opacity(
                      opacity: dark ? 0.16 : 0.11,
                      child: Transform.rotate(
                        angle: t * 6.283 * (i.isEven ? 1 : -1),
                        child: PokerChip(
                          colour: colours[i % colours.length],
                          size: size,
                        ),
                      ),
                    ),
                  );
                }(),
            ],
          );
        },
      ),
    );
  }
}
