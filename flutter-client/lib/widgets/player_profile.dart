import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../config/features.dart';
import '../l10n/strings.dart';
import '../models/friends.dart';
import '../models/player_stats.dart';
import '../theme/app_theme.dart';
import '../theme/table_theme.dart';
import '../theme/theme_colors.dart';
import 'glass_components.dart';
import 'premium_surface.dart';

// What a player's profile shows wherever it is shown (owner, 26 Sep 2026):
// the lobby's Friends page and the table's player drawer draw the same record
// from the same widget, and mark a friendship in the same green. Counts only
// on another player's record: nothing there is, or names, a wallet. (The
// lobby's Stats drawer lays the player's own record out on its own terms,
// [OwnRecord], from the same model and helpers.)

/// The green a friendship is marked in — the ✓ Friends tag, and on the lobby's
/// Friends page the dot beside a friend who is online: the dark scheme's mint
/// on charcoal, and a deeper green that holds 4:1 on the day's white.
Color friendsGreen(Brightness b) =>
    b == Brightness.dark ? AppTheme.mintOnInk : const Color(0xFF1E8E57);

/// A count as the app writes one: grouped by thousands, never abbreviated —
/// hands are not money. Public for the lobby's Stats drawer ([OwnRecord]),
/// which writes the same counts in a presentation of its own.
String countText(int n) {
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

/// The width of each of [columns] cells sharing a row [width] wide with [gap]
/// between them — a hair short of the exact share, so rounding can never make
/// a full row one cell too wide and send its last cell down a row.
double _cellWidth(double width, int columns, double gap) =>
    math.max(0, (width - gap * (columns - 1)) / columns - 0.001);

/// Where a record stands, which decides its type and how many tiles share a
/// row: the lobby — the Friends page's profile — or a table's player drawer, whose words take the table's own roles
/// ([TableType]), as everything at a table does.
enum RecordSurface { lobby, table }

/// The name a view of a record goes by on its key: All, then each game by the
/// lobby's own name for it, in the player's language ("Teen Patti",
/// "Variation", "Poker").
String statsCategoryName(Strings t, StatsCategory category) =>
    switch (category) {
      StatsCategory.all => t.statsAll,
      StatsCategory.teenPatti => friendlyName(t.teenPatti),
      StatsCategory.variation => friendlyName(t.variation),
      StatsCategory.poker => friendlyName(t.poker),
    };

/// Another player's record — the ONE widget both places that show one draw it
/// with: the lobby's Friends page and a table's player drawer. The lobby's
/// Stats drawer, the player's own, is laid out on its own terms since
/// 27 Sep 2026 ([OwnRecord]: no switch, no Poker) from the same model and the
/// same helpers ([countText], [EvenGrid]).
///
/// Player stats v2 (owner, 27 Sep 2026: "Show the stats acc to each
/// category"): a switch over the record — All · Teen Patti · Variation ·
/// Poker — and under the view chosen, its figures: hands played, won, lost and
/// left mid-hand, then the win rate. Teen Patti and Variation add the hands
/// held, Trail down to High Card; Variation also the variations its hands were played under,
/// with the hands won under each. All is the totals, the record as it read
/// before it was kept game by game. The record has no chip figure in any view
/// — not drawn, and not even read ([PlayerStats.categories]).
class PlayerStatsGrid extends StatefulWidget {
  /// Another player's record, from their profile.
  PlayerStatsGrid({
    super.key,
    required this.t,
    required PlayerStats stats,
    this.surface = RecordSurface.lobby,
  }) : totals = stats.totals,
       games = stats.categories;

  final Strings t;

  /// Every game together: the view called All.
  final CategoryStats totals;

  /// Each game on its own.
  final StatsByCategory games;

  final RecordSurface surface;

  /// How many figure tiles share a row [width] wide, of [tiles] in all: all
  /// five on a wide page; otherwise three, or two where three would stand
  /// under 100dp each — a table's drawer — since there "Left mid-hand" in Bengali at text x1.25 takes more
  /// than its two lines.
  static int figureColumns(RecordSurface surface, double width, int tiles) {
    if (surface == RecordSurface.lobby && tiles <= 5 && width >= 560) {
      return tiles;
    }
    return width >= 3 * _minTile + 2 * _gap ? 3 : 2;
  }

  static const double _gap = Space.sm;

  /// The narrowest a figure tile may stand three to a row.
  static const double _minTile = 100;

  @override
  State<PlayerStatsGrid> createState() => _PlayerStatsGridState();
}

class _PlayerStatsGridState extends State<PlayerStatsGrid> {
  /// The view on show: All until the player chooses a game. Kept while the
  /// record is read again (a request answered under it), and gone with it.
  StatsCategory _view = StatsCategory.all;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final view = _view;
    // The fill of what is sunk into the record — the switch's track, the
    // hands held, the variations: the theme's own well.
    final well = GlassColors.of(context).wellFill;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _CategorySwitch(
          t: w.t,
          shown: view,
          surface: w.surface,
          well: well,
          onChoose: (category) {
            if (category != _view) setState(() => _view = category);
          },
        ),
        const SizedBox(height: Space.md),
        // The record grows or shrinks to the view chosen rather than jumping,
        // and the one view crosses over the other.
        AnimatedSize(
          duration: Motion.base,
          curve: Motion.standard,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: Motion.base,
            switchInCurve: Motion.standard,
            switchOutCurve: Motion.standard,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topCenter,
              children: [...previous, ?current],
            ),
            child: _RecordView(
              key: ValueKey('stats-view-${view.name}'),
              t: w.t,
              view: view,
              stats: view == StatsCategory.all ? w.totals : w.games.of(view),
              surface: w.surface,
              well: well,
            ),
          ),
        ),
      ],
    );
  }
}

/// The views of a record the switch offers: All and every game — Poker only
/// in a build that shows the Poker family ([AppFeatures.poker]; owner,
/// 27 Sep 2026: "remove poker category"). Its figures are still in the
/// server's record and still counted in All; there is just no key to them.
List<StatsCategory> statsViews() => [
  for (final view in StatsCategory.values)
    if (view != StatsCategory.poker || AppFeatures.poker) view,
];

/// All · Teen Patti · Variation (· Poker): which view of the record is on
/// show, as a segmented control sunk into its panel — the chosen view raised
/// out of it in the gold a chosen thing wears (the appearance control's own
/// words), the others in the body ink.
///
/// Every view across where every name fits its share on one line; otherwise
/// two to a row — two over two of four, and of three All across the whole
/// top row over the two games, rather than one key alone in half a row —
/// the width of a landscape drawer (260dp on a 640dp phone) and the names in
/// five languages at text x1.25 being what they are. Each segment is a whole
/// touch target.
class _CategorySwitch extends StatelessWidget {
  const _CategorySwitch({
    required this.t,
    required this.shown,
    required this.surface,
    required this.well,
    required this.onChoose,
  });

  final Strings t;
  final StatsCategory shown;
  final RecordSurface surface;
  final Color well;
  final ValueChanged<StatsCategory> onChoose;

  /// The inset between the track and its segments, and between segments.
  static const double _pad = 3;

  /// How far a segment's name stands in from its sides.
  static const double _inset = Space.sm;

  TextStyle _style(ThemeData theme, {required bool on, Color? colour}) {
    final weight = on ? FontWeight.w700 : FontWeight.w600;
    return surface == RecordSurface.table
        ? TableType.label(theme, colour: colour, weight: weight)
        : AppTheme.label(
            theme.textTheme.labelMedium!,
            colour: colour,
            weight: weight,
          );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    final views = statsViews();
    final names = {for (final view in views) view: statsCategoryName(t, view)};

    return LayoutBuilder(
      builder: (context, box) {
        // Measured in the chosen segment's heavier weight, so no name outgrows
        // its segment the moment it is chosen.
        final measure = _style(theme, on: true);
        var widest = 0.0;
        for (final name in names.values) {
          final painter = TextPainter(
            text: TextSpan(text: name, style: measure),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          widest = math.max(widest, painter.width);
          painter.dispose();
        }
        final inner = box.maxWidth - 2 * _pad;
        final across = views.length;
        final oneRow =
            (inner - (across - 1) * _pad) / across >= widest + 2 * _inset + 1;
        final columns = oneRow ? across : 2;
        final width = _cellWidth(inner, columns, _pad);
        // Where the views do not fill every row, the first row is the short
        // one and its keys share it: of three, All across the top over the
        // two games, the whole record over its parts.
        final short = views.length % columns;
        final shortWidth = short == 0 ? width : _cellWidth(inner, short, _pad);

        return DecoratedBox(
          key: const ValueKey('stats-categories'),
          decoration: BoxDecoration(
            color: well,
            borderRadius: BorderRadius.circular(oneRow ? Radii.pill : Radii.md),
            border: Border.all(
              color: dark ? glass.borderTop : glass.borderBottom,
              width: Dim.hairline,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(_pad),
            child: Wrap(
              spacing: _pad,
              runSpacing: _pad,
              children: [
                for (final (i, view) in views.indexed)
                  SizedBox(
                    width: i < short ? shortWidth : width,
                    height: Dim.minTouch,
                    child: _Segment(
                      key: ValueKey('stats-category-${view.name}'),
                      label: names[view]!,
                      on: view == shown,
                      pill: oneRow,
                      style: _style,
                      onTap: () => onChoose(view),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One view's key in the switch.
class _Segment extends StatelessWidget {
  const _Segment({
    super.key,
    required this.label,
    required this.on,
    required this.pill,
    required this.style,
    required this.onTap,
  });

  final String label;

  /// The view on show.
  final bool on;

  /// A pill in a single row; a rounded key in a grid of two to a row.
  final bool pill;
  final TextStyle Function(ThemeData theme, {required bool on, Color? colour})
  style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final b = theme.brightness;
    final dark = b == Brightness.dark;
    final radius = BorderRadius.circular(pill ? Radii.pill : Radii.sm);
    // The chosen name in champagne on its gold, as the appearance control
    // writes its choice; the others in the body ink, which reads as more
    // choices rather than as switched off.
    final ink = on
        ? (dark ? AppTheme.goldBright : AppTheme.goldDeep)
        : glass.textBody;

    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: on,
        inMutuallyExclusiveGroup: true,
        child: AnimatedContainer(
          duration: Motion.base,
          curve: Motion.standard,
          decoration: BoxDecoration(
            borderRadius: radius,
            color: on
                ? Color.alphaBlend(
                    AppTheme.gold.withValues(alpha: dark ? 0.18 : 0.10),
                    glass.thumb,
                  )
                : glass.thumb.withValues(alpha: 0),
            border: Border.all(
              color: on
                  ? (dark
                        ? AppTheme.goldBright.withValues(alpha: 0.55)
                        : AppTheme.hairlineColour(b, live: true))
                  : Colors.transparent,
              width: Dim.hairline,
            ),
            boxShadow: on
                ? AppTheme.controlShadow(b, elevation: dark ? 1.5 : 2)
                : const [],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: radius,
              enableFeedback: soundOn(context),
              onTap: () {
                if (!on) tapHaptic(context);
                onTap();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: _CategorySwitch._inset,
                ),
                child: Center(
                  // Set smaller rather than cut, where even two over two leave
                  // a name less room than it needs.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: AnimatedDefaultTextStyle(
                      duration: Motion.base,
                      curve: Motion.standard,
                      style: style(theme, on: on, colour: ink),
                      child: Text(label, maxLines: 1),
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

/// One view of the record: its figures, and the hands held and the
/// variations played where the view counts them.
class _RecordView extends StatelessWidget {
  const _RecordView({
    super.key,
    required this.t,
    required this.view,
    required this.stats,
    required this.surface,
    required this.well,
  });

  final Strings t;
  final StatsCategory view;
  final CategoryStats stats;
  final RecordSurface surface;
  final Color well;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Figures(t: t, stats: stats, surface: surface),
        if (view.countsHands) ...[
          const SizedBox(height: Space.lg),
          _SectionTitle(
            icon: Icons.style_rounded,
            label: t.handsHeld,
            surface: surface,
          ),
          const SizedBox(height: Space.sm),
          _HandsHeld(tally: stats.hands, surface: surface, well: well),
        ],
        if (view.listsVariations) ...[
          const SizedBox(height: Space.lg),
          _SectionTitle(
            icon: Icons.shuffle_rounded,
            label: t.variationsPlayed,
            surface: surface,
          ),
          const SizedBox(height: Space.sm),
          _VariationsPlayed(
            t: t,
            played: stats.variations,
            surface: surface,
            well: well,
          ),
        ],
      ],
    );
  }
}

/// The view's figures, a tile each: hands played, won, lost, left mid-hand,
/// then the win rate.
class _Figures extends StatelessWidget {
  const _Figures({required this.t, required this.stats, required this.surface});

  final Strings t;
  final CategoryStats stats;
  final RecordSurface surface;

  @override
  Widget build(BuildContext context) {
    final tiles = <(IconData, String, String)>[
      (Icons.style_outlined, t.handsPlayed, countText(stats.handsPlayed)),
      (Icons.emoji_events_outlined, t.won, countText(stats.handsWon)),
      (Icons.trending_down_rounded, t.lost, countText(stats.handsLost)),
      (Icons.exit_to_app_rounded, t.leftMidHand, countText(stats.handsLeft)),
      (Icons.percent_rounded, t.winRate, _rate(stats.winRate)),
    ];
    const gap = PlayerStatsGrid._gap;
    return LayoutBuilder(
      builder: (context, box) {
        final columns = PlayerStatsGrid.figureColumns(
          surface,
          box.maxWidth,
          tiles.length,
        );
        return EvenGrid(
          key: const ValueKey('friend-stats'),
          columns: columns,
          gap: gap,
          children: [
            for (final (i, tile) in tiles.indexed)
              _StatTile(
                key: ValueKey('friend-stat-$i'),
                icon: tile.$1,
                label: tile.$2,
                value: tile.$3,
                surface: surface,
              ),
          ],
        );
      },
    );
  }
}

/// Cells laid [columns] to a row, [gap] apart and as wide as each other,
/// every cell of a row as tall as the tallest in it — so a caption that takes
/// two lines in one language ("Pure Sequence", "Left mid-hand") does not leave
/// its neighbours standing short beside it. A last row that is not full keeps
/// the others' widths. Public for the lobby's Stats drawer, whose tiles stand
/// in the same even rows.
class EvenGrid extends StatelessWidget {
  const EvenGrid({
    super.key,
    required this.columns,
    required this.gap,
    required this.children,
  });

  final int columns;
  final double gap;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = (children.length / columns).ceil();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var row = 0; row < rows; row++) ...[
          if (row > 0) SizedBox(height: gap),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var column = 0; column < columns; column++) ...[
                  if (column > 0) SizedBox(width: gap),
                  Expanded(
                    child: row * columns + column < children.length
                        ? children[row * columns + column]
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
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
    // The display ink for a count, not the lobby's gold: gold is how the
    // lobby writes money, and a count of hands is not money.
    final ink = glass.textDisplay;
    final figure = table
        ? TableType.chips(theme, colour: ink)
        : AppTheme.money(text.titleMedium!, colour: ink);
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

/// The name over one part of a view — the hands held, the variations played —
/// with its glyph: a step quieter than the figures above it.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.icon,
    required this.label,
    required this.surface,
  });

  final IconData icon;
  final String label;
  final RecordSurface surface;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface.withValues(alpha: AppTheme.inkMed);
    final style = surface == RecordSurface.table
        ? TableType.label(theme, colour: ink)
        : AppTheme.label(theme.textTheme.labelMedium!, colour: ink);
    return Semantics(
      header: true,
      child: Row(
        children: [
          Icon(icon, size: 16, color: ink),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

/// How often the player held each Teen Patti hand, Trail down to High Card —
/// named as the table names them, in the server's English (CLAUDE.md §6.3) —
/// each over its count on a well of its own: a step under the figures above,
/// which stand on raised cards.
class _HandsHeld extends StatelessWidget {
  const _HandsHeld({
    required this.tally,
    required this.surface,
    required this.well,
  });

  final HandTally tally;
  final RecordSurface surface;
  final Color well;

  /// The narrowest a hand's cell may stand three to a row.
  static const double _minCell = 96;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final glass = GlassColors.of(context);
    final table = surface == RecordSurface.table;
    final figure = table
        ? TableType.chips(theme, colour: glass.textDisplay)
        : AppTheme.money(text.titleSmall!, colour: glass.textDisplay);
    final caption = table
        ? TableType.metadata(theme, colour: glass.cardMuted)
        : AppTheme.label(
            text.labelSmall!,
            colour: glass.cardMuted,
            weight: FontWeight.w500,
          );
    final counts = tally.counts;
    const gap = PlayerStatsGrid._gap;
    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth >= 3 * _minCell + 2 * gap ? 3 : 2;
        return EvenGrid(
          key: const ValueKey('stats-hands'),
          columns: columns,
          gap: gap,
          children: [
            for (final (i, name) in HandTally.names.indexed)
              Container(
                key: ValueKey('stats-hand-${HandTally.fields[i]}'),
                padding: const EdgeInsets.all(Space.sm),
                decoration: BoxDecoration(
                  color: well,
                  borderRadius: BorderRadius.circular(Radii.sm),
                  border: Border.all(
                    color: glass.cardBorder,
                    width: Dim.hairline,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        countText(counts[i]),
                        maxLines: 1,
                        style: figure,
                      ),
                    ),
                    const SizedBox(height: Space.xxs),
                    Text(
                      name,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: caption,
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The variations the view's hands were played under, as a small table: each
/// by the name the picker gives it, then the hands played under it and the
/// hands won — in the server's order, Muflis first. A variation this build has
/// never heard of goes by the name the server sent.
class _VariationsPlayed extends StatelessWidget {
  const _VariationsPlayed({
    required this.t,
    required this.played,
    required this.surface,
    required this.well,
  });

  final Strings t;
  final List<VariationTally> played;
  final RecordSurface surface;
  final Color well;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final glass = GlassColors.of(context);
    final table = surface == RecordSurface.table;
    final muted = table
        ? TableType.metadata(theme, colour: glass.cardMuted)
        : AppTheme.label(
            text.labelSmall!,
            colour: glass.cardMuted,
            weight: FontWeight.w500,
          );
    if (played.isEmpty) {
      return Text(
        t.statsNoVariations,
        key: const ValueKey('stats-variations-none'),
        style: muted,
      );
    }
    final name = table
        ? TableType.info(theme, colour: glass.textBody)
        : AppTheme.label(
            text.bodyMedium!,
            colour: glass.textBody,
            weight: FontWeight.w500,
          );
    final figure = table
        ? TableType.chips(theme, colour: glass.textDisplay)
        : AppTheme.money(text.titleSmall!, colour: glass.textDisplay);
    final rule = BoxDecoration(
      border: Border(
        top: BorderSide(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
          width: Dim.hairline,
        ),
      ),
    );
    const nameCell = EdgeInsets.fromLTRB(
      Space.md,
      Space.sm,
      Space.xs,
      Space.sm,
    );
    const figureCell = EdgeInsets.fromLTRB(
      Space.sm,
      Space.sm,
      Space.md,
      Space.sm,
    );

    Widget head(String words) => Padding(
      padding: const EdgeInsets.fromLTRB(Space.sm, Space.sm, Space.md, 0),
      child: Text(words, maxLines: 1, textAlign: TextAlign.end, style: muted),
    );

    Widget figureOf(int n, String key) => Padding(
      padding: figureCell,
      child: Text(
        countText(n),
        key: ValueKey(key),
        maxLines: 1,
        textAlign: TextAlign.end,
        style: figure,
      ),
    );

    return Container(
      key: const ValueKey('stats-variations'),
      decoration: BoxDecoration(
        color: well,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: glass.cardBorder, width: Dim.hairline),
      ),
      child: Table(
        columnWidths: const {
          0: FlexColumnWidth(),
          1: IntrinsicColumnWidth(),
          2: IntrinsicColumnWidth(),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(
            children: [
              const SizedBox.shrink(),
              head(t.statsPlayed),
              head(t.statsWon),
            ],
          ),
          for (final (i, v) in played.indexed)
            TableRow(
              decoration: i == 0 ? null : rule,
              children: [
                Padding(
                  padding: nameCell,
                  child: Text(
                    t.variationName(v.variation),
                    key: ValueKey('stats-variation-${v.variation}'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: name,
                  ),
                ),
                figureOf(
                  v.handsPlayed,
                  'stats-variation-${v.variation}-played',
                ),
                figureOf(v.handsWon, 'stats-variation-${v.variation}-won'),
              ],
            ),
        ],
      ),
    );
  }
}
