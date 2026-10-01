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
//
// The progression (owner, 1 Oct 2026: "show current reward cycle, current
// day, claimed days, available reward, locked rewards, broken state, next
// period countdown … Use server timestamps as the source of truth. Do not
// make Flutter calculate reward eligibility"): each panel also dates its
// cycle ("Oct 5 – Oct 11"), says what a missed day does (RESET, SEQUENTIAL,
// BREAK), heads a broken cycle "Reward streak broken" with the day missed and
// when the next cycle starts, and counts down to the next period on a clock
// of its own. A day's standing is the server's `state` wherever it sends one
// — CLAIMED, AVAILABLE, MISSED, LOCKED — and the day that can be collected
// now says so and collects that program alone with a tap.

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

/// What a program's progression means, in a line under its head: a missed
/// day breaks the cycle (BREAK), sends the run back to Day 1 (RESET), or
/// costs nothing — a login run goes on with the next day, a calendar's missed
/// date is missed and the rest still wait (SEQUENTIAL, which is also every
/// program an older server describes without one).
String rewardProgramHint(Strings t, RewardProgramInfo p) =>
    switch (p.progression) {
      RewardProgression.breaks => t.rewardBreakHint,
      RewardProgression.reset => t.rewardStreakHint,
      _ =>
        p.isStreak
            ? t.rewardStreakHintNoReset
            : p.isWeekly
            ? t.rewardCalendarWeekHint
            : t.rewardCalendarMonthHint,
    };

/// A cycle's dates as a label: "Oct 5 – Oct 11", in the player's language —
/// the server's dates read as they are, never converted between zones. Null
/// where the server sent none.
String? rewardCycleLabel(Strings t, RewardCycle? cycle) {
  final first = cycle?.firstDay;
  final last = cycle?.lastDay;
  if (first == null || last == null) return null;
  return '${t.dateShort(first)} – ${t.dateShort(last)}';
}

/// When the next cycle starts, for "New rewards start …": its weekday for a
/// week, its date for a month; null where the server sent no next period.
String? rewardNextCycleStart(Strings t, RewardProgramState s) {
  final first = s.nextCycle?.firstDay;
  if (first == null) return null;
  return s.program.isWeekly ? t.weekdayFull(first.weekday) : t.dateShort(first);
}

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
    // Collecting is the player's tap (30 Sep 2026): the key stands while
    // any program's today can be collected — the server's verdict — and the
    // lobby's celebration shows what it gave once the screen has closed over
    // it. A day's tile collects its own program the same way (1 Oct 2026).
    final claiming = context.select<GameState, bool>(
      (s) => s.rewardClaimPending,
    );
    final claimingCode = context.select<GameState, String?>(
      (s) => s.rewardClaimProgram,
    );
    final t = Strings(lang);
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final b = theme.brightness;
    final dark = b == Brightness.dark;
    final screen = MediaQuery.sizeOf(context);
    final short = Breaks.isShort(screen.height);

    Future<void> collect({String? programCode}) async {
      final state = context.read<GameState>();
      final granted = await state.claimRewardPrograms(programCode: programCode);
      if (granted != null && context.mounted) {
        await Navigator.maybePop(context);
      }
    }

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
        itemBuilder: (context, i) {
          final code = programs[i].program.code;
          return _ProgramPanel(
            state: programs[i],
            t: t,
            claiming: claiming,
            // A claim of every program collects this one too.
            collecting:
                claiming && (claimingCode == null || claimingCode == code),
            onCollect: (named) => collect(programCode: named),
            onCycleTurned: context.read<GameState>().rewardCycleTurned,
          );
        },
      );
    }

    final titleStyle = AppTheme.label(
      (short ? text.titleMedium : text.titleLarge)!,
      weight: FontWeight.w700,
    );
    final due = programs?.any((p) => p.canClaimToday) ?? false;

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

/// A tile's standing — the server's `state` wherever it sends one: collected;
/// collectable now (today's); missed (a required day nobody claimed — on a
/// broken cycle, the day that broke it); or not reached, or no longer
/// reachable.
enum _DayState { claimed, available, missed, locked }

/// One program's panel: its head, its cycle's dates, what its progression
/// means — or, broken, the day missed and when the next cycle starts — its
/// days, what the next one gives and how long until the next period.
class _ProgramPanel extends StatelessWidget {
  const _ProgramPanel({
    required this.state,
    required this.t,
    this.claiming = false,
    this.collecting = false,
    this.onCollect,
    this.onCycleTurned,
  });

  final RewardProgramState state;
  final Strings t;

  /// A claim is out: no day can be tapped meanwhile.
  final bool claiming;

  /// The claim out collects this program: its collectable day shows the
  /// loader in place of its Collect.
  final bool collecting;

  /// Collects this program alone, by its code: a day's tile tapped.
  final void Function(String code)? onCollect;

  /// The next period has begun: the programs are read again.
  final Future<void> Function()? onCycleTurned;

  /// Where day [k] stands: the server's word where it sends one — it decides
  /// and the phone only draws — else read from the program's figures, as an
  /// older server's always were.
  static _DayState stateOf(RewardProgramState s, int k) {
    switch (s.rewardFor(k)?.state) {
      case RewardDayState.claimed:
        return _DayState.claimed;
      case RewardDayState.available:
        return _DayState.available;
      case RewardDayState.missed:
        return _DayState.missed;
      case RewardDayState.locked:
        return _DayState.locked;
    }
    if (s.program.isStreak) {
      // The run: every day up to today's counts; the rest are not reached.
      if (k <= s.claimedDays) return _DayState.claimed;
      if (s.isBroken) {
        return k == s.missedDay ? _DayState.missed : _DayState.locked;
      }
      if (k == s.currentDay && s.canClaimToday) return _DayState.available;
      return _DayState.locked;
    }
    if (s.rewardFor(k)?.claimed ?? false) return _DayState.claimed;
    if (s.isBroken) {
      return k == s.missedDay ? _DayState.missed : _DayState.locked;
    }
    if (k == s.dayOfPeriod) {
      if (s.canClaimToday) return _DayState.available;
      return s.claimedToday ? _DayState.claimed : _DayState.locked;
    }
    if (k < s.dayOfPeriod) return _DayState.missed;
    return _DayState.locked;
  }

  /// Whether [date] lies inside the program's current cycle — the server's
  /// `period`; always, from a server that sends none.
  static bool inCycle(RewardProgramState s, DateTime date) {
    final first = s.cycle?.firstDay;
    final last = s.cycle?.lastDay;
    if (first == null || last == null) return true;
    return !date.isBefore(first) && !date.isAfter(last);
  }

  /// Whether day [k] is today's — the one to collect, or collected today.
  /// None on a broken cycle, nor on a run completed before today.
  static bool isToday(RewardProgramState s, int k) {
    if (!s.isActive && !s.claimedToday) return false;
    return s.program.isStreak ? k == s.currentDay : k == s.dayOfPeriod;
  }

  /// A tile's words: a streak's "Day 3" over its weekday (a week's, while
  /// its run's dates are known — a broken or long-finished run's are not on
  /// the phone — and only for a day its cycle holds) or alone (a month's); a
  /// weekly calendar's weekday over its date; a monthly calendar's date.
  static (String, String?) labelsOf(RewardProgramState s, int k, Strings t) {
    final p = s.program;
    if (p.isStreak) {
      // A run never crosses its cycle: begun on a Thursday, its Day 5 would
      // fall on the next cycle's Monday, which starts again at Day 1 — so
      // that day stands on no weekday at all.
      final dated =
          p.isWeekly &&
          (s.isActive || s.claimedToday) &&
          inCycle(s, s.dateOfDay(k));
      return (t.rewardDay(k), dated ? t.weekdayShort(s.weekdayOfDay(k)) : null);
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
    final broken = state.isBroken;
    final headline = broken
        ? t.rewardBrokenTitle
        : state.isCompleted
        ? t.rewardAllCollected
        : p.isStreak
        ? (state.claimedDays > 0
              ? t.streakDays(state.claimedDays)
              : t.streakStart)
        : t.calendarDayReward(state.dayOfPeriod);
    // A broken cycle says what was missed and when the next one starts in
    // place of what the progression means.
    final restart = broken ? rewardNextCycleStart(t, state) : null;
    final brokenLines = [
      if (broken && state.missedDay >= 1) t.rewardMissedDay(state.missedDay),
      if (restart != null) t.rewardNewCycleStarts(restart),
    ];
    final hintStyle = text.bodySmall?.copyWith(color: quiet);
    final cycle = rewardCycleLabel(t, state.cycle);
    final next = state.nextReward;
    final upcoming = state.nextCycle;
    final collect = onCollect;
    final tap = claiming || collect == null ? null : () => collect(p.code);

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
                style: AppTheme.money(
                  text.titleSmall!,
                  // A broken cycle in the theme's error ink; the rest in the
                  // lobby's money gold.
                  colour: broken ? theme.colorScheme.error : gold,
                ),
              ),
            ],
          ),
          // The cycle the panel stands in: "Oct 5 – Oct 11".
          if (cycle != null) ...[
            const SizedBox(height: Space.xxs),
            Row(
              children: [
                Icon(Icons.date_range_rounded, size: 14, color: quiet),
                const SizedBox(width: Space.xs),
                Flexible(
                  child: Text(
                    cycle,
                    key: ValueKey('reward-cycle-${p.code}'),
                    style: AppTheme.label(text.labelMedium!, colour: quiet),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: Space.xs),
          if (brokenLines.isEmpty)
            Text(
              rewardProgramHint(t, p),
              key: ValueKey('reward-hint-${p.code}'),
              style: hintStyle,
            )
          else
            for (final (i, line) in brokenLines.indexed)
              Text(
                line,
                key: ValueKey('reward-broken-${p.code}-$i'),
                style: hintStyle,
              ),
          const SizedBox(height: Space.sm),
          p.isWeekly
              ? _WeekRow(
                  state: state,
                  t: t,
                  collecting: collecting,
                  onCollect: tap,
                )
              : _MonthGrid(
                  state: state,
                  t: t,
                  collecting: collecting,
                  onCollect: tap,
                ),
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
                    style: hintStyle,
                  ),
                ),
              ],
            ),
          ],
          // How long until the next period, on a clock of its own.
          if (upcoming != null && upcoming.startsInMs != null) ...[
            const SizedBox(height: Space.xs),
            NextCycleCountdown(
              key: ValueKey('reward-countdown-${p.code}'),
              next: upcoming,
              weekly: p.isWeekly,
              t: t,
              style: hintStyle,
              iconColour: quiet,
              onStarted: onCycleTurned,
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
  const _WeekRow({
    required this.state,
    required this.t,
    this.collecting = false,
    this.onCollect,
  });

  final RewardProgramState state;
  final Strings t;
  final bool collecting;
  final VoidCallback? onCollect;

  /// A day's box: taller than the 68 it was (owner, 30 Sep 2026: "Increase
  /// the size of each box of Day along with text"), room for the larger
  /// type [_DayTile] sets.
  static const double tileHeight = 96;

  @override
  Widget build(BuildContext context) {
    final days = state.periodDays.clamp(1, 7);
    return Row(
      children: [
        for (var k = 1; k <= days; k++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.xxs),
              child: _DayTile(
                program: state,
                day: k,
                t: t,
                height: tileHeight,
                collecting: collecting,
                onCollect: onCollect,
              ),
            ),
          ),
      ],
    );
  }
}

/// A month's 28 to 31 days, seven to a row — never 31 large cards on a phone
/// (the brief's §27): the page scrolls, the grid does not.
class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.state,
    required this.t,
    this.collecting = false,
    this.onCollect,
  });

  final RewardProgramState state;
  final Strings t;
  final bool collecting;
  final VoidCallback? onCollect;

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
      itemBuilder: (_, i) => _DayTile(
        program: state,
        day: i + 1,
        t: t,
        height: null,
        collecting: collecting,
        onCollect: onCollect,
      ),
    );
  }
}

/// One day: its label, its reward's mark and figure, and its standing — a
/// green tick when collected; a gold ring for today, and on the day that can
/// be collected now a Collect that collects its program with a tap (the
/// loader there while the claim is out); faded and locked when not reached;
/// faded and crossed when missed — in the error ink on the day that broke a
/// cycle. Everything inside is set down to fit the tile, never cut.
class _DayTile extends StatelessWidget {
  const _DayTile({
    required this.program,
    required this.day,
    required this.t,
    required this.height,
    this.collecting = false,
    this.onCollect,
  });

  final RewardProgramState program;
  final int day;
  final Strings t;

  /// A fixed height, or null to take the grid cell's.
  final double? height;

  /// The claim out collects this program: the loader in place of Collect.
  final bool collecting;

  /// Collects this program — null while a claim is out, or with nothing to
  /// collect. Only the day that can be collected now takes the tap.
  final VoidCallback? onCollect;

  /// The type on a tile (owner, 30 Sep 2026: "Increase the size of each box
  /// of Day along with text" — the label ramp's smallest step, 11, for
  /// everything before): the day's label, its weekday, the prize's mark and
  /// its figure, the largest thing on the tile. A tile too small for them —
  /// a month's cell on a phone — sets the column down whole.
  static const double labelSize = 13;
  static const double subSize = 12;
  static const double markSize = 22;
  static const double figureSize = 15.5;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final b = theme.brightness;
    final dark = b == Brightness.dark;
    final glass = GlassColors.of(context);
    final gold = AppTheme.goldInk(b);
    final code = program.program.code;
    final prize = program.rewardFor(day)?.prize;
    final standing = _ProgramPanel.stateOf(program, day);
    final available = standing == _DayState.available;
    final today = available || _ProgramPanel.isToday(program, day);
    final collect = onCollect;
    final tappable = available && collect != null;
    final (label, sub) = _ProgramPanel.labelsOf(program, day, t);
    final faded = standing == _DayState.locked || standing == _DayState.missed;
    final fill = switch (standing) {
      _DayState.claimed => AppTheme.gold.withValues(alpha: dark ? 0.16 : 0.12),
      _DayState.available => AppTheme.gold.withValues(
        alpha: dark ? 0.08 : 0.06,
      ),
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
        _DayState.available => '${t.rewardToday}, ${t.rewardTileCollect}',
        _DayState.missed => t.rewardTileMissed,
        _DayState.locked => t.rewardTileLocked,
      },
    ].join(', ');
    // The day to collect now says so: its Collect — or the loader, at the
    // Collect's own size, while the claim is out — in place of its weekday
    // or date (of its date, in a month's cell), so its column is no taller
    // than its neighbours' and is never set down smaller than theirs. A
    // screen reader still hears every word.
    final Widget? collectMark = !available
        ? null
        : collecting
        ? Stack(
            key: ValueKey('reward-collecting-$code-$day'),
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: 0,
                child: _CollectTag(label: t.rewardTileCollect),
              ),
              const GameLoaderRing(size: 14),
            ],
          )
        : _CollectTag(
            key: ValueKey('reward-collect-$code-$day'),
            label: t.rewardTileCollect,
          );

    return Semantics(
      key: ValueKey('reward-day-$code-$day'),
      label: words,
      button: tappable,
      onTap: tappable ? collect : null,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: tappable
              ? () {
                  lobbyClick(context);
                  collect();
                }
              : null,
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
                            if (collectMark != null && sub == null)
                              collectMark
                            else
                              Text(
                                label,
                                style: AppTheme.label(
                                  text.labelSmall!,
                                  fontSize: _DayTile.labelSize,
                                  colour: today ? gold : glass.cardMuted,
                                  weight: FontWeight.w700,
                                ),
                              ),
                            if (sub != null)
                              collectMark ??
                                  Text(
                                    sub,
                                    style: text.labelSmall?.copyWith(
                                      fontSize: _DayTile.subSize,
                                      color: glass.cardMuted,
                                    ),
                                  ),
                            const SizedBox(height: Space.xxs),
                            Icon(
                              prize == null
                                  ? Icons.remove_rounded
                                  : rewardPrizeIcon(prize),
                              size: _DayTile.markSize,
                              color: ink,
                            ),
                            Text(
                              prize == null ? '' : rewardPrizeShort(prize),
                              key: ValueKey('reward-figure-$code-$day'),
                              style: AppTheme.money(
                                text.labelSmall!,
                                fontSize: _DayTile.figureSize,
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
                        size: 14,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  if (standing == _DayState.locked)
                    Positioned(
                      top: Space.xxs,
                      right: Space.xxs,
                      child: Icon(
                        Icons.lock_rounded,
                        size: 12,
                        color: glass.cardMuted,
                      ),
                    ),
                  if (standing == _DayState.missed)
                    Positioned(
                      top: Space.xxs,
                      right: Space.xxs,
                      child: Icon(
                        Icons.cancel_rounded,
                        key: ValueKey('reward-missed-$code-$day'),
                        size: 13,
                        color: program.isBroken
                            ? theme.colorScheme.error
                            : glass.cardMuted,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Collect" on the day that can be collected now: the gold key's face in
/// small, so the tile reads as something to press.
class _CollectTag extends StatelessWidget {
  const _CollectTag({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    // At least a line of the tile's own type tall, and taller where the
    // script's line is (Devanagari, Bengali …): never clipped.
    return Container(
      constraints: const BoxConstraints(minHeight: 18),
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 1),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: AppTheme.goldFace,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: AppTheme.label(
          Theme.of(context).textTheme.labelSmall!,
          fontSize: 11,
          colour: AppTheme.ink900,
          weight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// "Next weekly rewards in 3d 8h": the wait to the next period, counted down
/// on a timer of its own — the screen above it never rebuilds for the tick —
/// from the moment the server's answer arrived ([RewardNextCycle.startsAt]),
/// never from the phone's clock against a date. Above an hour it moves a
/// minute at a time, below it a second. At zero its line goes and it asks
/// once ([onStarted]) for the programs again: the new cycle has begun.
class NextCycleCountdown extends StatefulWidget {
  const NextCycleCountdown({
    super.key,
    required this.next,
    required this.weekly,
    required this.t,
    this.onStarted,
    this.style,
    this.iconColour,
  });

  final RewardNextCycle next;

  /// A week's program ("Next weekly rewards"), else a month's.
  final bool weekly;
  final Strings t;
  final Future<void> Function()? onStarted;
  final TextStyle? style;
  final Color? iconColour;

  /// The wait in words: days and hours from a day up ("3d 8h"), hours and
  /// minutes from an hour ("5h 12m"), minutes and seconds under it ("12m
  /// 5s", "45s"). Whole seconds round up, so a wait never reads as none.
  static String waitWords(Duration left, Strings t) {
    final secs = (left.inMilliseconds + 999) ~/ 1000;
    if (secs >= Duration.secondsPerDay) {
      final d = secs ~/ Duration.secondsPerDay;
      final h = secs % Duration.secondsPerDay ~/ Duration.secondsPerHour;
      return '$d${t.unitDayShort} $h${t.unitHourShort}';
    }
    if (secs >= Duration.secondsPerHour) {
      final h = secs ~/ Duration.secondsPerHour;
      final m = secs % Duration.secondsPerHour ~/ Duration.secondsPerMinute;
      return '$h${t.unitHourShort} $m${t.unitMinuteShort}';
    }
    final m = secs ~/ Duration.secondsPerMinute;
    final s = secs % Duration.secondsPerMinute;
    return m > 0
        ? '$m${t.unitMinuteShort} $s${t.unitSecondShort}'
        : '$s${t.unitSecondShort}';
  }

  /// The line at [now]; null once the period has begun, or when there is
  /// nothing to count.
  static String? lineAt(
    Strings t,
    RewardNextCycle next, {
    required bool weekly,
    required DateTime now,
  }) {
    final left = next.leftAt(now);
    if (left == null || left <= Duration.zero) return null;
    return t.rewardNextCycleIn(weekly: weekly, time: waitWords(left, t));
  }

  @override
  State<NextCycleCountdown> createState() => _NextCycleCountdownState();
}

class _NextCycleCountdownState extends State<NextCycleCountdown> {
  Timer? _timer;
  String? _line;

  /// Whether [NextCycleCountdown.onStarted] has been asked for this start.
  bool _asked = false;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void didUpdateWidget(covariant NextCycleCountdown old) {
    super.didUpdateWidget(old);
    if (old.next.startsAt != widget.next.startsAt ||
        old.weekly != widget.weekly ||
        old.t.lang != widget.t.lang) {
      _begin();
    }
  }

  /// Counts towards [NextCycleCountdown.next] from now. An answer that came
  /// with the period already begun is the server's own word on it: nothing
  /// to count, and nothing to ask again.
  void _begin() {
    _timer?.cancel();
    _timer = null;
    _line = _read();
    _asked = _line == null;
    _schedule();
  }

  String? _read() => NextCycleCountdown.lineAt(
    widget.t,
    widget.next,
    weekly: widget.weekly,
    now: rewardClock(),
  );

  void _schedule() {
    final left = widget.next.leftAt(rewardClock());
    if (left == null || left <= Duration.zero) return;
    final cadence = left > const Duration(hours: 1)
        ? const Duration(minutes: 1)
        : const Duration(seconds: 1);
    _timer = Timer(left < cadence ? left : cadence, _tick);
  }

  void _tick() {
    _timer = null;
    if (!mounted) return;
    final line = _read();
    if (line != _line) setState(() => _line = line);
    if (line == null) {
      if (!_asked) {
        _asked = true;
        unawaited(widget.onStarted?.call());
      }
      return;
    }
    _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final line = _line;
    if (line == null) return const SizedBox.shrink();
    return Row(
      children: [
        Icon(Icons.schedule_rounded, size: 16, color: widget.iconColour),
        const SizedBox(width: Space.xs),
        Flexible(child: Text(line, style: widget.style)),
      ],
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
