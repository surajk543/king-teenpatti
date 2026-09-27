import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../models/player_stats.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/theme_colors.dart';
import 'avatar.dart';
import 'glass_components.dart';
import 'player_profile.dart' show EvenGrid, countText;
import 'premium_surface.dart';
import 'table_tax.dart' show badgeTitleOf, levelLineOf, levelStrut, xpTodayOf;

// The lobby's Stats drawer: the player's own record as ONE continuous
// profile (owner, 27 Sep 2026: "Do NOT use tabs … The drawer should feel like
// ONE continuous player profile … Poker must NOT appear anywhere in this
// drawer"). Who the player is, then PERFORMANCE with a small menu choosing
// the scope — All Games, Teen Patti or Variations — then HAND RESULTS and
// VARIATIONS PLAYED.
//
// A presentation of the lobby's own. The record is the one the Friends page
// and a table's player drawer draw with [PlayerStatsGrid], read from the
// same model ([CategoryStats], [StatsByCategory]) and written with the same
// counts ([countText]) and names ([HandTally.names], [Strings.variationName]);
// only how it is laid out differs, and those two places are untouched by it.
// Nothing here counts anything: every figure is the account's, as sent.

/// The three scopes the drawer offers — and only these: a poker hand is not
/// a Teen Patti hand, and the drawer is about Teen Patti (owner, 27 Sep 2026).
enum StatsScope {
  allGames,
  teenPatti,
  variations;

  /// The view of the record the scope reads — the model's own, so what each
  /// scope counts ([StatsCategory.countsHands], [StatsCategory.listsVariations])
  /// is decided where it always was.
  StatsCategory get category => switch (this) {
    StatsScope.allGames => StatsCategory.all,
    StatsScope.teenPatti => StatsCategory.teenPatti,
    StatsScope.variations => StatsCategory.variation,
  };
}

/// A scope's name on the menu, in the player's language: "All Games",
/// Teen Patti by the lobby's own name for it, "Variations".
String statsScopeName(Strings t, StatsScope scope) => switch (scope) {
  StatsScope.allGames => t.statsAllGames,
  StatsScope.teenPatti => friendlyName(t.teenPatti),
  StatsScope.variations => t.statsVariations,
};

/// The drawer's inks and surfaces, designed for each theme rather than one
/// inverted into the other (owner's brief, 27 Sep 2026: "Design Day Mode
/// intentionally — do NOT simply invert Night Mode").
///
/// By night the drawer is the lobby cards' charcoal, and a card is a breath
/// of white over it with a hairline barely there — glass on glass, so no
/// shadow. By day the drawer is warm pearl, and a card is whiter than it, edged
/// in a warm stone and lifted by a soft, diffused shadow; the muted tier is a
/// warm grey that holds 5:1 on the pearl rather than the cool slate.
///
/// The two sets are blended by how far the theme has come from night to day
/// ([GlassColors.dayShare]), not chosen by its brightness: the drawer's body
/// under these cards cross-fades with the theme's 420ms change, and cards
/// chosen by brightness would snap over it at the change's middle, where the
/// brightness flips (a system switch with the drawer open).
class _StatsInk {
  const _StatsInk({
    required this.day,
    required this.primary,
    required this.secondary,
    required this.muted,
    required this.cardFill,
    required this.cardBorder,
    required this.cardShadow,
    required this.moneyFill,
    required this.moneyBorder,
    required this.cellFill,
    required this.cellBorder,
    required this.rule,
    required this.gold,
    required this.chosenGold,
    required this.ring,
    required this.quietFill,
    required this.trigger,
    required this.triggerOpen,
    required this.triggerEdgeOpen,
    required this.menuBody,
    required this.menuShadow,
    required this.chosenWash,
  });

  static const Color _stone = Color(0xFFE8E1D5);

  static final _StatsInk _night = _StatsInk(
    day: 0,
    primary: GlassColors.dark.textDisplay,
    secondary: Colors.white.withValues(alpha: 0.74),
    // 0.58 rather than the cards' 0.50: the section names and the labels are
    // small, and "muted" must never mean "hard to read".
    muted: Colors.white.withValues(alpha: 0.58),
    cardFill: Colors.white.withValues(alpha: 0.055),
    cardBorder: Colors.white.withValues(alpha: 0.07),
    // Two clear shadows, not none, so each lerps into its day twin.
    cardShadow: const [
      BoxShadow(color: Color(0x003A2F1E), blurRadius: 2, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x003A2F1E), blurRadius: 14, offset: Offset(0, 4)),
    ],
    moneyFill: Color.alphaBlend(
      AppTheme.gold.withValues(alpha: 0.07),
      Colors.white.withValues(alpha: 0.045),
    ),
    moneyBorder: AppTheme.goldBright.withValues(alpha: 0.16),
    cellFill: Colors.white.withValues(alpha: 0.035),
    cellBorder: _stone.withValues(alpha: 0),
    rule: Colors.white.withValues(alpha: 0.07),
    gold: AppTheme.goldOnDark,
    chosenGold: AppTheme.goldOnDark,
    ring: AppTheme.goldBright.withValues(alpha: 0.85),
    quietFill: Colors.white.withValues(alpha: 0.06),
    trigger: Colors.white.withValues(alpha: 0.06),
    triggerOpen: Colors.white.withValues(alpha: 0.09),
    triggerEdgeOpen: AppTheme.hairlineColour(Brightness.dark, live: true),
    menuBody: const Color(0xFF26292E).withValues(alpha: 0.90),
    menuShadow: AppTheme.shadowFor(Brightness.dark).withValues(alpha: 0.40),
    chosenWash: AppTheme.gold.withValues(alpha: 0.12),
  );

  static final _StatsInk _day = _StatsInk(
    day: 1,
    primary: const Color(0xFF1D1B18),
    secondary: const Color(0xFF4A463F),
    muted: const Color(0xFF6E685E),
    cardFill: Colors.white.withValues(alpha: 0.82),
    cardBorder: _stone,
    cardShadow: const [
      BoxShadow(color: Color(0x0A3A2F1E), blurRadius: 2, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x0F3A2F1E), blurRadius: 14, offset: Offset(0, 4)),
    ],
    moneyFill: Color.alphaBlend(
      AppTheme.gold.withValues(alpha: 0.06),
      Colors.white.withValues(alpha: 0.88),
    ),
    moneyBorder: AppTheme.gold.withValues(alpha: 0.32),
    cellFill: Colors.white.withValues(alpha: 0.56),
    cellBorder: _stone.withValues(alpha: 0.7),
    rule: const Color(0xFFE6E0D4),
    gold: AppTheme.goldOnLight,
    // The chosen scope's name is 13.5dp, not large text, and on its gold
    // wash the money gold measured 4.27:1; the deep gold holds 4.6 there.
    chosenGold: AppTheme.goldDeep,
    ring: AppTheme.gold,
    quietFill: const Color(0xFF3A2F1E).withValues(alpha: 0.05),
    trigger: Colors.white.withValues(alpha: 0.80),
    triggerOpen: Colors.white.withValues(alpha: 0.95),
    triggerEdgeOpen: AppTheme.hairlineColour(Brightness.light, live: true),
    menuBody: Colors.white.withValues(alpha: 0.86),
    menuShadow: AppTheme.shadowFor(Brightness.light).withValues(alpha: 0.12),
    chosenWash: AppTheme.gold.withValues(alpha: 0.08),
  );

  factory _StatsInk.of(BuildContext context) {
    final day = GlassColors.of(context).dayShare;
    if (day <= 0) return _night;
    if (day >= 1) return _day;
    return _StatsInk.lerp(_night, _day, day);
  }

  factory _StatsInk.lerp(_StatsInk a, _StatsInk b, double t) {
    Color c(Color x, Color y) => Color.lerp(x, y, t) ?? x;
    return _StatsInk(
      day: t,
      primary: c(a.primary, b.primary),
      secondary: c(a.secondary, b.secondary),
      muted: c(a.muted, b.muted),
      cardFill: c(a.cardFill, b.cardFill),
      cardBorder: c(a.cardBorder, b.cardBorder),
      cardShadow: BoxShadow.lerpList(a.cardShadow, b.cardShadow, t) ?? const [],
      moneyFill: c(a.moneyFill, b.moneyFill),
      moneyBorder: c(a.moneyBorder, b.moneyBorder),
      cellFill: c(a.cellFill, b.cellFill),
      cellBorder: c(a.cellBorder, b.cellBorder),
      rule: c(a.rule, b.rule),
      gold: c(a.gold, b.gold),
      chosenGold: c(a.chosenGold, b.chosenGold),
      ring: c(a.ring, b.ring),
      quietFill: c(a.quietFill, b.quietFill),
      trigger: c(a.trigger, b.trigger),
      triggerOpen: c(a.triggerOpen, b.triggerOpen),
      triggerEdgeOpen: c(a.triggerEdgeOpen, b.triggerEdgeOpen),
      menuBody: c(a.menuBody, b.menuBody),
      menuShadow: c(a.menuShadow, b.menuShadow),
      chosenWash: c(a.chosenWash, b.chosenWash),
    );
  }

  /// How far from night (0) to day (1) — for the few choices that are not a
  /// colour.
  final double day;
  final Color primary;
  final Color secondary;
  final Color muted;
  final Color cardFill;
  final Color cardBorder;
  final List<BoxShadow> cardShadow;
  final Color moneyFill;
  final Color moneyBorder;
  final Color cellFill;
  final Color cellBorder;
  final Color rule;

  /// The lobby's gold for money and the chosen scope — never for a count.
  final Color gold;

  /// The chosen scope's name in the open menu: the gold, deepened by day.
  final Color chosenGold;

  /// The portrait's ring.
  final Color ring;

  /// The close key's disc: a shade off the drawer.
  final Color quietFill;

  /// The scope key's capsule, shut and open, and its edge while open.
  final Color trigger;
  final Color triggerOpen;
  final Color triggerEdgeOpen;

  /// The open menu's body under its blur, a shade from opaque, and its
  /// shadow.
  final Color menuBody;
  final Color menuShadow;

  /// The chosen scope's row in the open menu.
  final Color chosenWash;
}

/// The small print under the drawer's record — "A hand counts as played once
/// you have made a move in it." — in the record's own muted ink, which holds
/// 5:1 on the day's pearl, where the theme's quiet ink measured 3:1.
class StatsFootnote extends StatelessWidget {
  const StatsFootnote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ink = _StatsInk.of(context);
    return Text(
      text,
      style: AppTheme.label(
        Theme.of(context).textTheme.bodySmall!,
        colour: ink.muted,
        weight: FontWeight.w500,
      ),
    );
  }
}

// ------------------------------------------------------------------ header

/// Who the player is, at the head of the drawer: their picture in a thin gold
/// ring, their name — the strongest words in the drawer — and under it their
/// level, "Level 1 · 🌱 Newbie · 23 XP", quieter. The badges they hold follow
/// in a quieter ink still — on the level's line where both fit whole
/// ([_LevelAndBadges]) — and today's XP where the server keeps a daily
/// window. The way out is a small, quiet key: the drawer's content, not its
/// close button, is what the eye should land on.
///
/// Stays put while the record scrolls under it ([_LobbyDrawer]'s head).
class PlayerStatsHeader extends StatelessWidget {
  const PlayerStatsHeader({
    super.key,
    required this.t,
    required this.name,
    required this.avatarUrl,
    this.level,
    this.badges = const [],
  });

  final Strings t;
  final String name;
  final String? avatarUrl;
  final PlayerLevel? level;
  final List<PlayerBadge> badges;

  /// The portrait's footprint, ring included.
  static const double portrait = 40;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final ink = _StatsInk.of(context);
    final lvl = level;
    final levelStyle = AppTheme.label(
      text.bodySmall!,
      fontSize: 12.5,
      colour: ink.secondary,
      weight: FontWeight.w500,
    );
    final quiet = AppTheme.label(
      text.bodySmall!,
      fontSize: 11.5,
      colour: ink.muted,
      weight: FontWeight.w500,
    );
    const ringWidth = 1.5;
    const ringGap = 2.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.lg,
        Space.md,
        Space.xs,
        Space.md,
      ),
      child: Row(
        children: [
          Avatar(
            url: avatarUrl,
            fallback: name,
            radius: portrait / 2 - ringWidth - ringGap,
            ring: ink.ring,
            ringWidth: ringWidth,
            ringGap: ringGap,
            animate: true,
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              key: const ValueKey('stats-level'),
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  key: const ValueKey('stats-name'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.label(
                    text.titleMedium!,
                    colour: ink.primary,
                    weight: FontWeight.w700,
                  ),
                ),
                if (lvl != null || badges.isNotEmpty) ...[
                  const SizedBox(height: Space.xxs),
                  _LevelAndBadges(
                    level: lvl == null ? null : levelLineOf(t, lvl),
                    badges: badges.isEmpty
                        ? null
                        : badges.map(badgeTitleOf).join(' · '),
                    levelStyle: levelStyle,
                    badgeStyle: quiet,
                  ),
                  if (lvl?.today case final today?)
                    _XpTodayLine(today: today, style: quiet),
                ],
              ],
            ),
          ),
          _CloseKey(ink: ink),
        ],
      ),
    );
  }
}

/// The level line and the badges held: on ONE line — "Level 1 · 🌱 Newbie ·
/// 23 XP · Regular", the badges in the quieter ink — wherever both fit at
/// their size, so the head stays the name over one line (the owner's brief:
/// the name over "Level 1 · 🌱 Newbie · 23 XP"), and where they do not, the
/// level line ([_FitLine]) over the badges on a line of their own rather than
/// either one cut or set small.
class _LevelAndBadges extends StatelessWidget {
  const _LevelAndBadges({
    required this.level,
    required this.badges,
    required this.levelStyle,
    required this.badgeStyle,
  });

  final String? level;
  final String? badges;
  final TextStyle levelStyle;
  final TextStyle badgeStyle;

  static const String _joint = ' · ';

  @override
  Widget build(BuildContext context) {
    final level = this.level;
    final badges = this.badges;
    Widget badgeText() => Text(
      badges!,
      key: const ValueKey('stats-badges'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      strutStyle: levelStrut(badgeStyle),
      style: badgeStyle,
    );
    if (level == null) return badgeText();
    final levelLine = _FitLine(
      level,
      key: const ValueKey('stats-level-line'),
      style: levelStyle,
    );
    if (badges == null) return levelLine;
    return LayoutBuilder(
      builder: (context, box) {
        final painter = TextPainter(
          text: TextSpan(
            children: [
              TextSpan(text: level, style: levelStyle),
              TextSpan(text: '$_joint$badges', style: badgeStyle),
            ],
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final width = painter.width;
        painter.dispose();
        if (width > box.maxWidth) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              levelLine,
              const SizedBox(height: Space.xxs),
              badgeText(),
            ],
          );
        }
        // Measured whole, so no part of it needs fitting: the level as a
        // plain line, keyed as [_FitLine] keys it.
        return Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            KeyedSubtree(
              key: const ValueKey('stats-level-line'),
              child: Text(
                level,
                maxLines: 1,
                softWrap: false,
                strutStyle: levelStrut(levelStyle),
                style: levelStyle,
              ),
            ),
            Text(
              _joint,
              maxLines: 1,
              strutStyle: levelStrut(badgeStyle),
              style: badgeStyle,
            ),
            Flexible(child: badgeText()),
          ],
        );
      },
    );
  }
}

/// The level line on one line wherever it can be: as it is where it fits,
/// set a little smaller where it nearly does — "लेवल 1 · 🌱 Newbie · 23 XP"
/// at text x1.25 in a 300dp drawer, which on two lines made the head a third
/// of a 360dp phone's height — and only past that on two lines, cut after the
/// second rather than set too small to read.
class _FitLine extends StatelessWidget {
  const _FitLine(this.text, {super.key, required this.style});

  final String text;
  final TextStyle style;

  /// The smallest the line is set before it takes a second line instead:
  /// 12.5dp at x1.25 comes down to 12.8, still the brief's 12–13.
  static const double minScale = 0.8;

  @override
  Widget build(BuildContext context) {
    final strut = levelStrut(style);
    return LayoutBuilder(
      builder: (context, box) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          strutStyle: strut,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final width = painter.width;
        painter.dispose();
        final line = Text(
          text,
          maxLines: 1,
          softWrap: false,
          strutStyle: strut,
          style: style,
        );
        if (width <= box.maxWidth) return line;
        if (width * minScale <= box.maxWidth) {
          return FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: line,
          );
        }
        return Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          strutStyle: strut,
          style: style,
        );
      },
    );
  }
}

/// Today's XP against its cap and the countdown to the window's end — the
/// one line of the drawer that changes every second, so the one widget that
/// listens to the lobby's tick.
class _XpTodayLine extends StatelessWidget {
  const _XpTodayLine({required this.today, required this.style});

  final XpToday today;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final t = context.watch<GameState>().t;
    return Padding(
      padding: const EdgeInsets.only(top: Space.xxs),
      child: Text(
        xpTodayOf(t, today, DateTime.now()),
        key: const ValueKey('stats-xp-today'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AppTheme.money(style, weight: FontWeight.w500),
      ),
    );
  }
}

/// A small, quiet close key: a 28dp disc a shade off the drawer, its cross in
/// the muted ink — inside a whole 44dp touch target.
class _CloseKey extends StatelessWidget {
  const _CloseKey({required this.ink});

  final _StatsInk ink;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: Dim.minTouch,
      height: Dim.minTouch,
      child: PressScale(
        child: IconButton(
          key: const ValueKey('stats-close'),
          padding: EdgeInsets.zero,
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: () => Navigator.pop(context),
          icon: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ink.quietFill,
            ),
            child: Icon(Icons.close_rounded, size: 16, color: ink.secondary),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ record

/// The player's own record, in the drawer's order: PERFORMANCE with the scope
/// menu beside it — played, won and lost; the total winnings and biggest pot;
/// hands left mid-hand, quieter — then HAND RESULTS and VARIATIONS PLAYED.
///
/// The scope is state of its own: All Games until the player chooses, kept
/// while the account is read again under it. A scope changes only what is
/// under the menu, which crosses over in a short fade and a small rise; the
/// head and the menu stay where they are.
class OwnRecord extends StatefulWidget {
  OwnRecord({super.key, required this.t, required User? user})
    : totals = user?.totals ?? CategoryStats.empty,
      games = user?.stats ?? const StatsByCategory();

  final Strings t;

  /// Every game together — the account's six totals, as the model gives them.
  final CategoryStats totals;

  /// Each game on its own.
  final StatsByCategory games;

  /// How the scoped part of the record crosses over: 200ms, inside the
  /// brief's 150–250.
  static const Duration crossOver = Duration(milliseconds: 200);

  @override
  State<OwnRecord> createState() => _OwnRecordState();
}

class _OwnRecordState extends State<OwnRecord>
    with AutomaticKeepAliveClientMixin {
  StatsScope _scope = StatsScope.allGames;

  /// Kept while the drawer's list scrolls: a lazy list lets go of a row it
  /// has laid out of sight, and a jump to the drawer's end did exactly that,
  /// putting the scope back to All Games under the player.
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final w = widget;
    final scope = _scope;
    final category = scope.category;
    final stats = scope == StatsScope.allGames
        ? w.totals
        : w.games.of(category);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: StatsSectionHeader(label: w.t.statsPerformance, t: w.t),
            ),
            const SizedBox(width: Space.sm),
            StatsScopeSelector(
              t: w.t,
              scope: scope,
              onChanged: (next) {
                if (next != _scope) setState(() => _scope = next);
              },
            ),
          ],
        ),
        const SizedBox(height: Space.xs),
        AnimatedSize(
          duration: OwnRecord.crossOver,
          curve: Motion.standard,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: OwnRecord.crossOver,
            switchInCurve: Motion.standard,
            switchOutCurve: Motion.standard,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topCenter,
              children: [...previous, ?current],
            ),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: AnimatedBuilder(
                animation: animation,
                // Rises 6dp into place: a small vertical movement, not a
                // slide.
                builder: (context, child) => Transform.translate(
                  offset: Offset(0, 6 * (1 - animation.value)),
                  child: child,
                ),
                child: child,
              ),
            ),
            child: _ScopeView(
              key: ValueKey('stats-view-${scope.name}'),
              t: w.t,
              category: category,
              stats: stats,
            ),
          ),
        ),
      ],
    );
  }
}

/// One scope of the record: everything under the menu.
class _ScopeView extends StatelessWidget {
  const _ScopeView({
    super.key,
    required this.t,
    required this.category,
    required this.stats,
  });

  final Strings t;
  final StatsCategory category;
  final CategoryStats stats;

  @override
  Widget build(BuildContext context) {
    final ink = _StatsInk.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: Space.xs),
        EvenGrid(
          key: const ValueKey('stats-performance'),
          columns: 3,
          gap: Space.sm,
          children: [
            PerformanceStatCard(
              key: const ValueKey('stats-played'),
              icon: Icons.style_outlined,
              value: countText(stats.handsPlayed),
              // "Played", as the brief's card says: under PERFORMANCE the
              // word "hands" is understood, and "Hands played" took two lines
              // in a 300dp drawer at text x1.25, one card taller than its
              // neighbours.
              label: t.statsPlayed,
            ),
            PerformanceStatCard(
              key: const ValueKey('stats-won'),
              icon: Icons.emoji_events_outlined,
              value: countText(stats.handsWon),
              label: t.won,
            ),
            PerformanceStatCard(
              key: const ValueKey('stats-lost'),
              icon: Icons.trending_down_rounded,
              value: countText(stats.handsLost),
              label: t.lost,
            ),
          ],
        ),
        const SizedBox(height: Space.sm),
        EvenGrid(
          key: const ValueKey('stats-winning'),
          columns: 2,
          gap: Space.sm,
          children: [
            PerformanceStatCard(
              key: const ValueKey('stats-total-winnings'),
              icon: Icons.savings_outlined,
              value: formatChips(stats.totalWinnings),
              label: t.totalWinnings,
              money: true,
            ),
            PerformanceStatCard(
              key: const ValueKey('stats-biggest-pot'),
              icon: Icons.local_fire_department_outlined,
              value: formatChips(stats.biggestPot),
              label: t.biggestPot,
              money: true,
            ),
          ],
        ),
        const SizedBox(height: Space.md),
        _LeftMidHand(t: t, count: stats.handsLeft, ink: ink),
        const SizedBox(height: Space.xl),
        StatsSectionHeader(label: t.statsHandResults, t: t),
        const SizedBox(height: Space.sm),
        if (!category.countsHands)
          _EmptyLine(
            key: const ValueKey('stats-hands-hint'),
            icon: Icons.filter_list_rounded,
            text: t.statsHandResultsHint,
            ink: ink,
          )
        else if (stats.hands.total == 0)
          _EmptyLine(
            key: const ValueKey('stats-hands-none'),
            icon: Icons.style_outlined,
            text: t.statsNoHandResults,
            ink: ink,
          )
        else
          HandResultGrid(tally: stats.hands),
        const SizedBox(height: Space.xl),
        StatsSectionHeader(label: t.variationsPlayed, t: t),
        const SizedBox(height: Space.xs),
        if (!category.listsVariations)
          _EmptyLine(
            key: const ValueKey('stats-variations-hint'),
            icon: Icons.filter_list_rounded,
            text: t.statsVariationsHint,
            ink: ink,
          )
        else if (stats.variations.isEmpty)
          _EmptyLine(
            key: const ValueKey('stats-variations-none'),
            icon: Icons.shuffle_rounded,
            text: t.statsNoVariationGames,
            ink: ink,
          )
        else
          VariationStatsList(t: t, played: stats.variations),
      ],
    );
  }
}

/// The name over one part of the drawer — PERFORMANCE, HAND RESULTS,
/// VARIATIONS PLAYED: 11dp, medium, muted, a step under every figure it
/// heads. Tracked capitals in English only, as the Settings drawer writes
/// its groups: spread over Devanagari or Gurmukhi, tracking pulls the vowel
/// signs off their letters, so the other scripts keep their own shape.
class StatsSectionHeader extends StatelessWidget {
  const StatsSectionHeader({super.key, required this.label, required this.t});

  final String label;
  final Strings t;

  @override
  Widget build(BuildContext context) {
    final english = t.lang == AppLang.english;
    final ink = _StatsInk.of(context);
    return Semantics(
      header: true,
      child: Text(
        english ? label.toUpperCase() : label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTheme.label(
          Theme.of(context).textTheme.labelSmall!,
          fontSize: english ? 11 : 11.5,
          colour: ink.muted,
          weight: FontWeight.w600,
        ).copyWith(letterSpacing: english ? 1.2 : 0),
      ),
    );
  }
}

/// One figure of PERFORMANCE: a small glyph, the figure large, what it counts
/// small under it — on a quiet card of its own. [money] is a chip figure (the
/// total winnings, the biggest pot): the one place the drawer spends its gold,
/// on the figure and its glyph, over a card washed with a breath of it. A
/// count of hands is never gold.
class PerformanceStatCard extends StatelessWidget {
  const PerformanceStatCard({
    super.key,
    required this.icon,
    required this.value,
    required this.label,
    this.money = false,
  });

  final IconData icon;
  final String value;
  final String label;
  final bool money;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final ink = _StatsInk.of(context);
    final figure = AppTheme.money(
      text.titleLarge!,
      fontSize: 19,
      colour: money ? ink.gold : ink.primary,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(
        Space.md,
        Space.sm,
        Space.sm,
        Space.sm,
      ),
      decoration: BoxDecoration(
        color: money ? ink.moneyFill : ink.cardFill,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: money ? ink.moneyBorder : ink.cardBorder,
          width: Dim.hairline,
        ),
        boxShadow: ink.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: money ? ink.gold : ink.muted),
          const SizedBox(height: Space.xs),
          // Set smaller rather than cut: "10.5 Crore" on a 640dp phone at
          // text x1.25 is wider than its half of the row.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, maxLines: 1, style: figure),
          ),
          const SizedBox(height: Space.xxs),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.label(
              text.labelSmall!,
              colour: ink.muted,
              weight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Hands left before their end, kept but quieter than played, won and lost
/// (owner's brief: "NOT with the same visual importance"): one line, "Left
/// mid-hand: 0", no card.
class _LeftMidHand extends StatelessWidget {
  const _LeftMidHand({required this.t, required this.count, required this.ink});

  final Strings t;
  final int count;
  final _StatsInk ink;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final style = AppTheme.label(
      text.bodySmall!,
      colour: ink.muted,
      weight: FontWeight.w500,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.xs),
      child: Row(
        key: const ValueKey('stats-left-mid-hand'),
        children: [
          Icon(Icons.exit_to_app_rounded, size: 14, color: ink.muted),
          const SizedBox(width: Space.sm),
          Flexible(
            child: Text.rich(
              key: const ValueKey('stats-left-mid-hand-text'),
              TextSpan(
                children: [
                  TextSpan(text: '${t.leftMidHand}: '),
                  TextSpan(
                    text: countText(count),
                    style: AppTheme.money(
                      style,
                      colour: ink.secondary,
                      weight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
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

/// A part of the record with nothing to show in this scope: one quiet line
/// with its glyph where the part would stand, never an empty box — so the
/// drawer keeps its shape from scope to scope.
class _EmptyLine extends StatelessWidget {
  const _EmptyLine({
    super.key,
    required this.icon,
    required this.text,
    required this.ink,
  });

  final IconData icon;
  final String text;
  final _StatsInk ink;

  @override
  Widget build(BuildContext context) {
    final style = AppTheme.label(
      Theme.of(context).textTheme.bodySmall!,
      fontSize: 12.5,
      colour: ink.muted,
      weight: FontWeight.w500,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.xs, Space.xs, 0, Space.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 14, color: ink.muted),
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

/// HAND RESULTS: how often the player finished with each Teen Patti hand,
/// Trail down to High Card — named as the table names them, in the server's
/// English (CLAUDE.md §6.3) — two to a row, each a compact cell with its
/// name at the start and its count at the end, so the counts stand in two
/// clean columns down the grid.
///
/// The name comes first. Two to a row, a cell of a 300dp drawer at text
/// x1.25 is some 110dp inside, and "Sequence" beside "2,033" — or "Pure
/// Sequence" beside "18,182" — does not fit it: the name was cut, or broken
/// inside a word. So where any hand's longest word and its count cannot
/// stand side by side in a cell, the grid is one to a row instead, every
/// cell the drawer's width; counts of the size most players have keep the
/// two columns.
class HandResultGrid extends StatelessWidget {
  const HandResultGrid({super.key, required this.tally});

  final HandTally tally;

  static const double _gap = Space.sm;
  static const double _inset = Space.md;

  /// Between a hand's name and its count.
  static const double _between = Space.sm;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final ink = _StatsInk.of(context);
    final counts = tally.counts;
    final name = AppTheme.label(
      text.bodySmall!,
      colour: ink.secondary,
      weight: FontWeight.w500,
    );
    final figure = AppTheme.money(
      text.titleSmall!,
      colour: ink.primary,
      weight: FontWeight.w700,
    );
    final base = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    double widthOf(String words, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: words, style: base.merge(style)),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    // The widest any cell needs: a hand's longest word — the name may take
    // two lines, a word to a line, never a word broken — then its count.
    final longestWord = [
      for (final hand in HandTally.names)
        hand.split(' ').map((word) => widthOf(word, name)).reduce(math.max),
    ];
    var needs = 0.0;
    for (final (i, word) in longestWord.indexed) {
      needs = math.max(
        needs,
        word + _between + widthOf(countText(counts[i]), figure),
      );
    }

    // Measured here, round the grid: its rows are sized by their intrinsic
    // heights, which a builder inside a cell cannot answer.
    return LayoutBuilder(
      builder: (context, box) {
        // Inside the cell's padding and its hairline border, which a
        // Container adds to the padding.
        final cell = (box.maxWidth - _gap) / 2 - 2 * (_inset + Dim.hairline);
        final columns = needs.ceilToDouble() <= cell ? 2 : 1;
        final inner = columns == 2
            ? cell
            : box.maxWidth - 2 * (_inset + Dim.hairline);
        return EvenGrid(
          key: const ValueKey('stats-hands'),
          columns: columns,
          gap: columns == 2 ? _gap : Space.xs,
          children: [
            for (final (i, hand) in HandTally.names.indexed)
              Container(
                key: ValueKey('stats-hand-${HandTally.fields[i]}'),
                constraints: const BoxConstraints(minHeight: 38),
                padding: const EdgeInsets.symmetric(
                  horizontal: _inset,
                  vertical: Space.sm,
                ),
                decoration: BoxDecoration(
                  color: ink.cellFill,
                  borderRadius: BorderRadius.circular(Radii.sm),
                  border: Border.all(
                    color: ink.cellBorder,
                    width: Dim.hairline,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        hand,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: name,
                      ),
                    ),
                    const SizedBox(width: _between),
                    // Measured to fit; set smaller rather than break the
                    // name should a font draw it wider than it measured.
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: math.max(
                          inner - _between - longestWord[i].ceilToDouble(),
                          0,
                        ),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerEnd,
                        child: Text(
                          countText(counts[i]),
                          maxLines: 1,
                          style: figure,
                        ),
                      ),
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

/// VARIATIONS PLAYED: a list, not a table — each variation by the picker's
/// name, then the hands played under it and the hands won, the two figures
/// in columns of their own width at the end, right-aligned in tabular
/// figures; rows parted by a hairline and nothing else. In the server's
/// order, Muflis first; a variation this build has never heard of goes by the
/// name the server sent.
class VariationStatsList extends StatelessWidget {
  const VariationStatsList({super.key, required this.t, required this.played});

  final Strings t;
  final List<VariationTally> played;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final ink = _StatsInk.of(context);
    final english = t.lang == AppLang.english;
    final head = AppTheme.label(
      text.labelSmall!,
      colour: ink.muted,
      weight: FontWeight.w600,
    ).copyWith(letterSpacing: english ? 1.0 : 0);
    final name = AppTheme.label(
      text.bodyMedium!,
      colour: ink.primary,
      weight: FontWeight.w500,
    );
    final playedStyle = AppTheme.money(
      text.bodyMedium!,
      colour: ink.secondary,
      weight: FontWeight.w600,
    );
    final wonStyle = AppTheme.money(
      text.bodyMedium!,
      colour: ink.primary,
      weight: FontWeight.w700,
    );
    final rule = BoxDecoration(
      border: Border(
        top: BorderSide(color: ink.rule, width: Dim.hairline),
      ),
    );
    const figureCell = EdgeInsets.fromLTRB(
      Space.lg,
      Space.md,
      Space.xs,
      Space.md,
    );

    Widget heading(String words) => Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.xs, Space.xs),
      child: Text(
        english ? words.toUpperCase() : words,
        maxLines: 1,
        textAlign: TextAlign.end,
        style: head,
      ),
    );

    Widget figure(int n, String key, TextStyle style) => Padding(
      padding: figureCell,
      child: Text(
        countText(n),
        key: ValueKey(key),
        maxLines: 1,
        textAlign: TextAlign.end,
        style: style,
      ),
    );

    return Table(
      key: const ValueKey('stats-variations'),
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
            heading(t.statsPlayed),
            heading(t.statsWon),
          ],
        ),
        for (final v in played)
          TableRow(
            decoration: rule,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.xs,
                  Space.md,
                  0,
                  Space.md,
                ),
                child: Text(
                  t.variationName(v.variation),
                  key: ValueKey('stats-variation-${v.variation}'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: name,
                ),
              ),
              figure(
                v.handsPlayed,
                'stats-variation-${v.variation}-played',
                playedStyle,
              ),
              figure(
                v.handsWon,
                'stats-variation-${v.variation}-won',
                wonStyle,
              ),
            ],
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- the menu

/// The scope of the record, chosen from a small menu beside PERFORMANCE
/// (owner's brief: "PERFORMANCE    All Games ▾ … The filter is a selector,
/// NOT navigation"): the scope's name and a chevron on a quiet capsule, and
/// under it, anchored to its right edge, a compact glass menu of the three
/// scopes — the chosen one in the lobby's gold with a check.
///
/// The menu is an overlay over the drawer, not a route: a tap anywhere else
/// puts it away, as does choosing. It fades and rises 4dp in from a touch
/// small, over 160ms, and the chevron turns with it.
class StatsScopeSelector extends StatefulWidget {
  const StatsScopeSelector({
    super.key,
    required this.t,
    required this.scope,
    required this.onChanged,
  });

  final Strings t;
  final StatsScope scope;
  final ValueChanged<StatsScope> onChanged;

  static const Duration openFor = Duration(milliseconds: 160);

  @override
  State<StatsScopeSelector> createState() => _StatsScopeSelectorState();
}

class _StatsScopeSelectorState extends State<StatsScopeSelector>
    with SingleTickerProviderStateMixin {
  final _portal = OverlayPortalController();
  final _link = LayerLink();

  /// Created on the first open: most visits to the drawer never open it.
  AnimationController? _motion;

  /// The open and close eased, made once with the controller: a
  /// [CurvedAnimation] listens to its parent until disposed, so one made per
  /// build of the menu would pile listeners up on the controller.
  CurvedAnimation? _curve;

  bool get _open => _portal.isShowing;

  AnimationController get _controller => _motion ??= AnimationController(
    vsync: this,
    duration: StatsScopeSelector.openFor,
    reverseDuration: const Duration(milliseconds: 120),
  );

  Animation<double> get _eased => _curve ??= CurvedAnimation(
    parent: _controller,
    curve: Motion.standard,
    reverseCurve: Curves.easeIn,
  );

  @override
  void dispose() {
    _curve?.dispose();
    _motion?.dispose();
    super.dispose();
  }

  void _show() {
    tapHaptic(context);
    setState(_portal.show);
    _controller.forward(from: 0);
  }

  Future<void> _hide() async {
    final motion = _motion;
    if (motion != null) await motion.reverse();
    if (!mounted) return;
    if (_portal.isShowing) setState(_portal.hide);
  }

  void _choose(StatsScope scope) {
    if (scope != widget.scope) tapHaptic(context);
    widget.onChanged(scope);
    _hide();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final theme = Theme.of(context);
    final ink = _StatsInk.of(context);
    final name = statsScopeName(t, widget.scope);

    final trigger = Semantics(
      // A node of its own: without one the key's label took in every line
      // of the record beside it.
      container: true,
      button: true,
      expanded: _open,
      label: '${t.statsScopeLabel}: $name',
      // The capsule's own words are in the label; the tap is the key's.
      excludeSemantics: true,
      onTap: _open ? _hide : _show,
      child: InkWell(
        key: const ValueKey('stats-scope'),
        borderRadius: BorderRadius.circular(Radii.pill),
        enableFeedback: soundOn(context),
        onTap: _open ? _hide : _show,
        // A whole touch target round a capsule that looks small.
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Dim.minTouch),
          child: Center(
            widthFactor: 1,
            child: AnimatedContainer(
              duration: Motion.fast,
              curve: Motion.standard,
              height: 30,
              padding: const EdgeInsets.only(left: Space.md, right: Space.sm),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.pill),
                color: _open ? ink.triggerOpen : ink.trigger,
                border: Border.all(
                  color: _open ? ink.triggerEdgeOpen : ink.cardBorder,
                  width: Dim.hairline,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConstrainedBox(
                    // Never wider than half the drawer: the section's name
                    // keeps the rest.
                    constraints: const BoxConstraints(maxWidth: 150),
                    child: Text(
                      name,
                      key: const ValueKey('stats-scope-name'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.label(
                        theme.textTheme.labelMedium!,
                        colour: ink.primary,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: Space.xxs),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: StatsScopeSelector.openFor,
                    curve: Motion.standard,
                    child: Icon(
                      Icons.expand_more_rounded,
                      size: 18,
                      color: ink.gold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (overlayContext) => Stack(
          children: [
            // Anywhere else puts the menu away, and nothing under it is
            // touched by that tap.
            Positioned.fill(
              child: GestureDetector(
                key: const ValueKey('stats-scope-barrier'),
                behavior: HitTestBehavior.opaque,
                onTap: _hide,
              ),
            ),
            CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: Alignment.bottomRight,
              followerAnchor: Alignment.topRight,
              offset: const Offset(0, -4),
              child: Align(
                alignment: Alignment.topRight,
                widthFactor: 1,
                heightFactor: 1,
                child: _ScopeMenu(
                  t: t,
                  scope: widget.scope,
                  motion: _eased,
                  onChoose: _choose,
                  // The overlay sits above the drawer's theme; the menu
                  // keeps the drawer's.
                  theme: theme,
                ),
              ),
            ),
          ],
        ),
        child: trigger,
      ),
    );
  }
}

/// The open menu: the three scopes on a small glass card — the drawer's glass
/// under it, a thin border and a small shadow — the chosen one in
/// gold with a check, each row a whole touch target.
class _ScopeMenu extends StatelessWidget {
  const _ScopeMenu({
    required this.t,
    required this.scope,
    required this.motion,
    required this.onChoose,
    required this.theme,
  });

  final Strings t;
  final StatsScope scope;
  final Animation<double> motion;
  final ValueChanged<StatsScope> onChoose;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: theme,
      child: Builder(
        builder: (context) {
          final ink = _StatsInk.of(context);
          return AnimatedBuilder(
            animation: motion,
            builder: (context, child) => Opacity(
              opacity: motion.value,
              child: Transform.translate(
                offset: Offset(0, -4 * (1 - motion.value)),
                child: Transform.scale(
                  scale: 0.96 + 0.04 * motion.value,
                  alignment: Alignment.topRight,
                  child: child,
                ),
              ),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Radii.md),
                  boxShadow: [
                    BoxShadow(
                      color: ink.menuShadow,
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: PremiumGlassPanel(
                  key: const ValueKey('stats-scope-menu'),
                  // The drawer's blur budget, not a blur of its own: the
                  // drawer panel under the menu holds the one lease
                  // ([GlassBudget]), and over the lobby's drifting chips a
                  // second blur would be re-drawn every frame. Where the lease
                  // is taken the body below carries it, a shade from opaque.
                  mode: GlassMode.auto,
                  sigma: 12,
                  radius: Radii.md,
                  elevated: false,
                  padding: const EdgeInsets.symmetric(vertical: Space.xs),
                  // The body a blur lets through, a shade from opaque: the
                  // record under the menu must not read through its words.
                  behind: ColoredBox(color: ink.menuBody),
                  child: IntrinsicWidth(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: 176,
                        maxWidth: 260,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final option in StatsScope.values)
                            _ScopeOption(
                              label: statsScopeName(t, option),
                              option: option,
                              on: option == scope,
                              ink: ink,
                              onTap: () => onChoose(option),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One scope in the open menu.
class _ScopeOption extends StatelessWidget {
  const _ScopeOption({
    required this.label,
    required this.option,
    required this.on,
    required this.ink,
    required this.onTap,
  });

  final String label;
  final StatsScope option;
  final bool on;
  final _StatsInk ink;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: on,
        inMutuallyExclusiveGroup: true,
        child: InkWell(
          key: ValueKey('stats-scope-option-${option.name}'),
          enableFeedback: soundOn(context),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: Dim.minTouch),
            margin: const EdgeInsets.symmetric(horizontal: Space.xs),
            padding: const EdgeInsets.only(left: Space.sm, right: Space.lg),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.sm),
              color: on ? ink.chosenWash : null,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: on
                      ? Icon(Icons.check_rounded, size: 16, color: ink.gold)
                      : null,
                ),
                const SizedBox(width: Space.xs),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.label(
                      text.bodyMedium!,
                      colour: on ? ink.chosenGold : ink.primary,
                      weight: on ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
