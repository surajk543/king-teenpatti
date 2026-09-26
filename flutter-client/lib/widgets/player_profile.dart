import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/friends.dart';
import '../theme/app_theme.dart';
import '../theme/table_theme.dart';
import '../theme/theme_colors.dart';
import 'premium_surface.dart';

// What a player's profile shows wherever it is shown (owner, 26 Sep 2026):
// the lobby's Friends page and the table's player drawer draw the same record
// from the same widget, and mark a friendship in the same green. Counts only:
// nothing here is, or names, a wallet.

/// The green a friendship is marked in — the ✓ Friends tag, and on the lobby's
/// Friends page the dot beside a friend who is online: the dark scheme's mint
/// on charcoal, and a deeper green that holds 4:1 on the day's white.
Color friendsGreen(Brightness b) =>
    b == Brightness.dark ? AppTheme.mintOnInk : const Color(0xFF1E8E57);

/// A count as the app writes one: grouped by thousands, never abbreviated —
/// hands are not money.
String _count(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// A win rate as a share: "57.25%", "50%" — two places at most, and none of
/// the trailing zeros.
String _rate(double percent) {
  var text = percent.toStringAsFixed(2);
  if (text.contains('.')) text = text.replaceFirst(RegExp(r'\.?0+$'), '');
  return '$text%';
}

/// Where a record stands, which decides its type and how many tiles share a
/// row: the lobby's Friends page, or a table's player drawer — whose words take
/// the table's own roles ([TableType]), as everything at a table does.
enum RecordSurface { lobby, table }

/// A player's record: hands played, won, lost, left mid-hand, and the win rate
/// — five tiles, the ONE widget the lobby's profile and the table's player
/// drawer both draw it with. Counts only: no chip figure has a place on a
/// profile.
class PlayerStatsGrid extends StatelessWidget {
  const PlayerStatsGrid({
    super.key,
    required this.t,
    required this.stats,
    this.surface = RecordSurface.lobby,
  });

  final Strings t;
  final PlayerStats stats;
  final RecordSurface surface;

  /// How many tiles share a row [width] wide: all five on a wide page, three
  /// on a phone's profile. A table's drawer is narrower than any page, and
  /// there three tiles stood under 90dp, where "Left mid-hand" in Bengali at
  /// text x1.25 takes more than its two lines: two to a row until each tile
  /// has 100dp.
  int columnsFor(double width) => switch (surface) {
    RecordSurface.lobby => width >= 560 ? 5 : 3,
    RecordSurface.table => width >= 3 * 100 + 2 * _gap ? 3 : 2,
  };

  static const double _gap = Space.sm;

  @override
  Widget build(BuildContext context) {
    final tiles = <(IconData, String, String)>[
      (Icons.style_outlined, t.handsPlayed, _count(stats.handsPlayed)),
      (Icons.emoji_events_outlined, t.won, _count(stats.handsWon)),
      (Icons.trending_down_rounded, t.lost, _count(stats.handsLost)),
      (Icons.exit_to_app_rounded, t.leftMidHand, _count(stats.handsLeft)),
      (Icons.percent_rounded, t.winRate, _rate(stats.winRate)),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final columns = columnsFor(box.maxWidth);
        final width = (box.maxWidth - _gap * (columns - 1)) / columns;
        return Wrap(
          key: const ValueKey('friend-stats'),
          spacing: _gap,
          runSpacing: _gap,
          children: [
            for (final (i, tile) in tiles.indexed)
              SizedBox(
                width: width,
                child: _StatTile(
                  key: ValueKey('friend-stat-$i'),
                  icon: tile.$1,
                  label: tile.$2,
                  value: tile.$3,
                  surface: surface,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// One figure of the record, over what it counts, on a card of the lobby's
/// own surface.
class _StatTile extends StatelessWidget {
  const _StatTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.surface,
  });

  final IconData icon;
  final String label;
  final String value;
  final RecordSurface surface;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final glass = GlassColors.of(context);
    final table = surface == RecordSurface.table;
    // The display ink, not the lobby's gold: gold is how the lobby writes
    // money, and none of these is money.
    final figure = table
        ? TableType.chips(theme, colour: glass.textDisplay)
        : AppTheme.money(text.titleMedium!, colour: glass.textDisplay);
    // The label's light tracking, not the ramp's small caps: spread over
    // Devanagari, tracking pulls the vowel signs off.
    final caption = table
        ? TableType.metadata(theme, colour: glass.cardMuted)
        : AppTheme.label(
            text.labelSmall!,
            colour: glass.cardMuted,
            weight: FontWeight.w500,
          );
    return PremiumGlassPanel(
      surface: GlassSurface.card,
      radius: Radii.md,
      elevated: false,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.md,
      ),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: glass.cardMuted),
            const SizedBox(height: Space.xxs),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value, maxLines: 1, style: figure),
            ),
            const SizedBox(height: Space.xxs),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: caption,
            ),
          ],
        ),
      ),
    );
  }
}
