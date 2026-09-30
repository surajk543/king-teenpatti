import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/depth.dart';
import '../theme/theme_colors.dart';
import '../widgets/game_loader.dart';
import '../widgets/glass_components.dart';
import '../widgets/picture_shelf.dart'
    show diamondInkOn, hammerInkOn, missileIcon, missileInkOn;
import '../widgets/premium_surface.dart';

// The reward programs' screen (owner, 30 Sep 2026): the login streaks and
// the calendar rewards the server runs, one panel each, drawn from
// GET /api/reward-programs (or a claim's answer) and nothing else — the
// server has decided every day, every reward and every claim; the panel says
// which days are collected, which is today and what comes next. A LOGIN
// STREAK panel is headed "3 day streak" and its tiles are Day 1 … Day 7 of
// the RUN; a CALENDAR panel is headed "Day 10 reward" and its tiles are the
// week's days or the month's dates — the brief's §27, and the difference §2
// insists on, kept on the screen.

/// Opens the rewards over the lobby, the way the Lucky Draw opens: a page of
/// its own, risen from the foot of the screen, which the back gesture
/// closes.
Future<void> showRewardPrograms(BuildContext context) {
  // Read again as it opens: the day may have turned while the app was up.
  unawaited(context.read<GameState>().loadRewardPrograms());
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: AppTheme.ink900.withValues(alpha: 0.72),
    transitionDuration: Motion.enter,
    pageBuilder: (_, a, b) => const RewardProgramsScreen(),
    transitionBuilder: (context, anim, _, child) {
      final fade = Motion.standard.transform(anim.value);
      return Opacity(
        opacity: fade,
        child: Transform.translate(
          offset: Offset(0, 40 * (1 - fade)),
          child: child,
        ),
      );
    },
  );
}

/// What a reward is called: "10,000 chips", "1 hammer", "Clapping Hands
/// emoji", "Royal Ace badge · 7 days".
String rewardPrizeLabel(Strings t, RewardPrize p) => switch (p.kind) {
  RewardKind.chips => t.priceIn('COIN', formatChips(p.amount)),
  RewardKind.hammer => t.priceIn('HAMMER', '${p.amount}'),
  RewardKind.diamond => t.priceIn('DIAMOND', '${p.amount}'),
  RewardKind.missile => t.countMissiles(p.amount),
  RewardKind.emoji => t.rewardEmojiName(p.itemName),
  RewardKind.profilePicture => t.rewardPictureName(p.itemName),
  RewardKind.tablePicture => t.rewardTablePictureName(p.itemName),
  RewardKind.badge =>
    (p.badge?.validityDays ?? 0) > 0
        ? t.rewardBadgeDays(p.itemName, p.badge!.validityDays)
        : t.rewardBadgeName(p.itemName),
  _ => t.rewardNothing,
};

/// A tile's figure: "10,000" for chips, "×2" for a count, an item's name.
String rewardPrizeShort(RewardPrize p) => switch (p.kind) {
  RewardKind.chips => formatChips(p.amount),
  RewardKind.hammer ||
  RewardKind.diamond ||
  RewardKind.missile => '×${p.amount}',
  RewardKind.none => '',
  _ => p.itemName,
};

/// The reward's mark.
IconData rewardPrizeIcon(RewardPrize p) => switch (p.kind) {
  RewardKind.chips => Icons.toll_rounded,
  RewardKind.hammer => Icons.hardware,
  RewardKind.diamond => Icons.diamond_rounded,
  RewardKind.missile => missileIcon,
  RewardKind.emoji => Icons.emoji_emotions_rounded,
  RewardKind.profilePicture => Icons.face_rounded,
  RewardKind.tablePicture => Icons.table_bar_rounded,
  RewardKind.badge => Icons.workspace_premium_rounded,
  _ => Icons.card_giftcard_rounded,
};

/// The reward's ink: each soft wallet its own, chips and every item gold.
Color rewardPrizeInk(RewardPrize p, Brightness b) => switch (p.kind) {
  RewardKind.hammer => hammerInkOn(b),
  RewardKind.diamond => diamondInkOn(b),
  RewardKind.missile => missileInkOn(b),
  _ => AppTheme.goldInk(b),
};

/// The rewards page.
class RewardProgramsScreen extends StatelessWidget {
  const RewardProgramsScreen({super.key});

  /// The panel at its largest, the Lucky Draw's measure.
  static const Size largest = Size(1040, 640);

  @override
  Widget build(BuildContext context) {
    // Selected, never watched: the one-second tick would rebuild the page.
    final lang = context.select<GameState, AppLang>((s) => s.lang);
    final programs = context.select<GameState, List<RewardProgramState>?>(
      (s) => s.rewardPrograms,
    );
    final busy = context.select<GameState, bool>(
      (s) => s.rewardProgramsLoading || s.rewardClaimPending,
    );
    final failed = context.select<GameState, bool>(
      (s) => s.rewardProgramsFailed,
    );
    final t = Strings(lang);
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final b = theme.brightness;
    final dark = b == Brightness.dark;
    final screen = MediaQuery.sizeOf(context);
    final short = Breaks.isShort(screen.height);

    final Widget body;
    if (programs == null && busy) {
      body = const Center(child: GameLoader());
    } else if (programs == null || programs.isEmpty) {
      body = _Absent(
        failed: programs == null && failed,
        onRetry: context.read<GameState>().loadRewardPrograms,
      );
    } else {
      body = ListView.separated(
        key: const ValueKey('reward-programs-list'),
        padding: const EdgeInsets.only(bottom: Space.md),
        itemCount: programs.length,
        separatorBuilder: (_, _) => const SizedBox(height: Space.md),
        itemBuilder: (_, i) => _ProgramPanel(state: programs[i], t: t),
      );
    }

    final titleStyle = AppTheme.label(
      (short ? text.titleMedium : text.titleLarge)!,
      weight: FontWeight.w700,
    );
    // Collecting is the player's tap (30 Sep 2026): the key stands while
    // any program's today is still to collect, and the lobby's celebration
    // shows what it gave once the screen has closed over it.
    final due = programs?.any((p) => !p.claimedToday) ?? false;
    final claiming = context.select<GameState, bool>(
      (s) => s.rewardClaimPending,
    );
    Future<void> collect() async {
      final state = context.read<GameState>();
      final granted = await state.claimRewardPrograms();
      if (granted != null && context.mounted) {
        await Navigator.maybePop(context);
      }
    }

    final header = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Dim.minTouch),
      child: Row(
        children: [
          Icon(
            Icons.card_giftcard_rounded,
            size: 24,
            color: AppTheme.goldInk(b),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              t.rewardsTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
          ),
          const SizedBox(width: Space.sm),
          if (due)
            GlassButton(
              key: const ValueKey('reward-programs-collect'),
              style: GlassButtonStyle.primary,
              click: true,
              onPressed: claiming ? null : collect,
              child: claiming
                  ? const GameLoaderRing(size: 18)
                  : Text(t.rewardsCollect),
            ),
          if (due) const SizedBox(width: Space.sm),
          PressScale(
            child: IconButton(
              key: const ValueKey('reward-programs-close'),
              tooltip: t.close,
              onPressed: () => Navigator.maybePop(context),
              icon: const Icon(Icons.close_rounded, size: 20),
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                minimumSize: const Size.square(Dim.minTouch),
              ),
            ),
          ),
        ],
      ),
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints.loose(RewardProgramsScreen.largest),
            child: DecoratedBox(
              // By day the card is laid on white of its own: the lobby must
              // not show through a page that is being read.
              decoration: BoxDecoration(
                color: dark ? null : AppTheme.panelBase(b),
                borderRadius: BorderRadius.circular(Radii.lg),
              ),
              child: PremiumGlassPanel(
                mode: GlassMode.auto,
                priority: 20,
                depth: Elevation.overlay,
                radius: Radii.lg,
                // The Lucky Draw's page: obsidian glass by night, the lobby's
                // card warmed to cream by day, a gold edge across the top.
                surface: dark ? GlassSurface.pane : GlassSurface.card,
                tint: dark ? null : AppTheme.gold,
                edge: AppTheme.gold.withValues(alpha: dark ? 0.42 : 0.6),
                padding: const EdgeInsets.fromLTRB(
                  Space.lg,
                  Space.md,
                  Space.lg,
                  Space.md,
                ),
                child: Column(
                  children: [
                    header,
                    const SizedBox(height: Space.sm),
                    Expanded(child: body),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A tile's standing: collected, today's (still to collect), missed (a past
/// calendar day nobody claimed), or not yet reached.
enum _DayState { claimed, today, missed, locked }

/// One program's panel: its head, what its mode means, its days and what the
/// next one gives.
class _ProgramPanel extends StatelessWidget {
  const _ProgramPanel({required this.state, required this.t});

  final RewardProgramState state;
  final Strings t;

  /// Where day [k] stands.
  static _DayState stateOf(RewardProgramState s, int k) {
    if (s.program.isStreak) {
      // The run: every day up to today's counts; the rest are not reached.
      if (k <= s.claimedDays) return _DayState.claimed;
      if (k == s.currentDay && !s.claimedToday) return _DayState.today;
      return _DayState.locked;
    }
    if (s.rewardFor(k)?.claimed ?? false) return _DayState.claimed;
    if (k == s.dayOfPeriod) return _DayState.today;
    if (k < s.dayOfPeriod) return _DayState.missed;
    return _DayState.locked;
  }

  /// Whether day [k] is today's.
  static bool isToday(RewardProgramState s, int k) =>
      s.program.isStreak ? k == s.currentDay : k == s.dayOfPeriod;

  /// A tile's words: a streak's "Day 3" over its weekday (a week's) or
  /// alone (a month's); a weekly calendar's weekday over its date; a monthly
  /// calendar's date.
  static (String, String?) labelsOf(RewardProgramState s, int k, Strings t) {
    final p = s.program;
    if (p.isStreak) {
      return (
        t.rewardDay(k),
        p.isWeekly ? t.weekdayShort(s.weekdayOfDay(k)) : null,
      );
    }
    if (p.isWeekly) {
      return (t.weekdayShort(s.weekdayOfDay(k)), '${s.dateOfDay(k).day}');
    }
    return ('$k', null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final b = theme.brightness;
    final dark = b == Brightness.dark;
    final glass = GlassColors.of(context);
    final p = state.program;
    final gold = AppTheme.goldInk(b);
    final quiet = theme.colorScheme.onSurface.withValues(
      alpha: AppTheme.inkLowOn(b),
    );
    final headline = p.isStreak
        ? (state.claimedDays > 0
              ? t.streakDays(state.claimedDays)
              : t.streakStart)
        : t.calendarDayReward(state.dayOfPeriod);
    final hint = p.isStreak
        ? (p.resetOnMissedDay ? t.rewardStreakHint : t.rewardStreakHintNoReset)
        : (p.isWeekly ? t.rewardCalendarWeekHint : t.rewardCalendarMonthHint);
    final next = state.nextReward;

    return Container(
      key: ValueKey('reward-program-${p.code}'),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: dark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.white.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: glass.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The tag and the name, and the headline at the right — on a
          // second line where the three cannot share one (a 640dp phone at
          // text x1.25), so no word of either is cut.
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Space.sm,
            runSpacing: Space.xxs,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ModeTag(
                    label: p.isStreak
                        ? t.rewardModeStreak
                        : t.rewardModeCalendar,
                    streak: p.isStreak,
                  ),
                  const SizedBox(width: Space.sm),
                  Flexible(
                    child: Text(
                      t.rewardProgramName(p.code, p.name),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.label(
                        text.titleSmall!,
                        weight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              Text(
                headline,
                key: ValueKey('reward-headline-${p.code}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.money(text.titleSmall!, colour: gold),
              ),
            ],
          ),
          const SizedBox(height: Space.xs),
          Text(hint, style: text.bodySmall?.copyWith(color: quiet)),
          const SizedBox(height: Space.sm),
          p.isWeekly
              ? _WeekRow(state: state, t: t)
              : _MonthGrid(state: state, t: t),
          if (next != null && !next.prize.isNothing) ...[
            const SizedBox(height: Space.sm),
            Row(
              children: [
                Icon(
                  rewardPrizeIcon(next.prize),
                  size: 16,
                  color: rewardPrizeInk(next.prize, b),
                ),
                const SizedBox(width: Space.xs),
                Flexible(
                  child: Text(
                    '${t.rewardNext}: ${rewardPrizeLabel(t, next.prize)}',
                    key: ValueKey('reward-next-${p.code}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: quiet),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// "LOGIN STREAK" / "CALENDAR" — a small tag saying which kind of program
/// the panel is, gold for a streak and the blind table's sapphire for a
/// calendar.
class _ModeTag extends StatelessWidget {
  const _ModeTag({required this.label, required this.streak});

  final String label;
  final bool streak;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final ink = streak
        ? AppTheme.goldInk(theme.brightness)
        : theme.colorScheme.tertiary;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.xxs,
      ),
      decoration: BoxDecoration(
        color: ink.withValues(alpha: dark ? 0.16 : 0.12),
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: ink.withValues(alpha: 0.6)),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: AppTheme.label(
          theme.textTheme.labelSmall!,
          colour: ink,
          weight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// A week's seven days in one row.
class _WeekRow extends StatelessWidget {
  const _WeekRow({required this.state, required this.t});

  final RewardProgramState state;
  final Strings t;

  @override
  Widget build(BuildContext context) {
    final days = state.periodDays.clamp(1, 7);
    return Row(
      children: [
        for (var k = 1; k <= days; k++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.xxs),
              child: _DayTile(program: state, day: k, t: t, height: 68),
            ),
          ),
      ],
    );
  }
}

/// A month's 28 to 31 days, seven to a row — never 31 large cards on a phone
/// (the brief's §27): the page scrolls, the grid does not.
class _MonthGrid extends StatelessWidget {
  const _MonthGrid({required this.state, required this.t});

  final RewardProgramState state;
  final Strings t;

  @override
  Widget build(BuildContext context) {
    final days = state.periodDays.clamp(1, 31);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        mainAxisSpacing: Space.xs,
        crossAxisSpacing: Space.xs,
        childAspectRatio: 1.2,
      ),
      itemCount: days,
      itemBuilder: (_, i) =>
          _DayTile(program: state, day: i + 1, t: t, height: null),
    );
  }
}

/// One day: its label, its reward's mark and figure, and its standing — a
/// green tick when collected, a gold ring for today, faded and locked when
/// not yet reached, faded when missed. Everything inside is set down to fit
/// the tile, never cut.
class _DayTile extends StatelessWidget {
  const _DayTile({
    required this.program,
    required this.day,
    required this.t,
    required this.height,
  });

  final RewardProgramState program;
  final int day;
  final Strings t;

  /// A fixed height, or null to take the grid cell's.
  final double? height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final b = theme.brightness;
    final dark = b == Brightness.dark;
    final glass = GlassColors.of(context);
    final gold = AppTheme.goldInk(b);
    final prize = program.rewardFor(day)?.prize;
    final standing = _ProgramPanel.stateOf(program, day);
    final today = _ProgramPanel.isToday(program, day);
    final (label, sub) = _ProgramPanel.labelsOf(program, day, t);
    final faded = standing == _DayState.locked || standing == _DayState.missed;
    final fill = switch (standing) {
      _DayState.claimed => AppTheme.gold.withValues(alpha: dark ? 0.16 : 0.12),
      _DayState.today => AppTheme.gold.withValues(alpha: dark ? 0.08 : 0.06),
      _ =>
        dark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.black.withValues(alpha: 0.03),
    };
    final ink = prize == null ? glass.cardMuted : rewardPrizeInk(prize, b);
    final words = [
      label,
      ?sub,
      prize == null ? t.rewardNothing : rewardPrizeLabel(t, prize),
      switch (standing) {
        _DayState.claimed => t.rewardTileClaimed,
        _DayState.today => t.rewardToday,
        _DayState.missed => t.rewardTileMissed,
        _DayState.locked => t.rewardTileLocked,
      },
    ].join(', ');

    return Semantics(
      key: ValueKey('reward-day-${program.program.code}-$day'),
      label: words,
      child: ExcludeSemantics(
        child: Opacity(
          opacity: faded ? 0.45 : 1,
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(
                color: today ? gold : glass.cardBorder,
                width: today ? 1.5 : 1,
              ),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Space.xxs,
                      Space.xs,
                      Space.xxs,
                      Space.xs,
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            label,
                            style: AppTheme.label(
                              text.labelSmall!,
                              colour: today ? gold : glass.cardMuted,
                              weight: FontWeight.w700,
                            ),
                          ),
                          if (sub != null)
                            Text(
                              sub,
                              style: text.labelSmall?.copyWith(
                                color: glass.cardMuted,
                              ),
                            ),
                          const SizedBox(height: Space.xxs),
                          Icon(
                            prize == null
                                ? Icons.remove_rounded
                                : rewardPrizeIcon(prize),
                            size: 16,
                            color: ink,
                          ),
                          Text(
                            prize == null ? '' : rewardPrizeShort(prize),
                            style: AppTheme.money(
                              text.labelSmall!,
                              colour: theme.colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (standing == _DayState.claimed)
                  Positioned(
                    top: Space.xxs,
                    right: Space.xxs,
                    child: Icon(
                      Icons.check_circle_rounded,
                      size: 12,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                if (standing == _DayState.locked)
                  Positioned(
                    top: Space.xxs,
                    right: Space.xxs,
                    child: Icon(
                      Icons.lock_rounded,
                      size: 10,
                      color: glass.cardMuted,
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

/// No program to show: none running, or none could be read.
class _Absent extends StatelessWidget {
  const _Absent({required this.failed, required this.onRetry});

  final bool failed;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final t = context.read<GameState>().t;
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            failed ? t.rewardLoadFailed : t.rewardNone,
            key: const ValueKey('reward-programs-absent'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(
                alpha: AppTheme.inkMed,
              ),
            ),
          ),
          if (failed) ...[
            const SizedBox(height: Space.md),
            GlassButton(
              style: GlassButtonStyle.glass,
              label: t.luckyRetry,
              onPressed: onRetry,
            ),
          ],
        ],
      ),
    );
  }
}
