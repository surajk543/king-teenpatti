import 'dart:async';
import 'dart:math' as math;

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
import '../widgets/level_accent.dart';
import '../widgets/picture_shelf.dart'
    show diamondInkOn, hammerInkOn, missileIcon, missileInkOn;
import '../widgets/premium_surface.dart';
import '../widgets/weekly_login.dart' show WeeklyCardColours;

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
/// closes. While it is open no reward popup is put up behind it
/// ([GameState.rewardsScreenOpen]): each program is collected here instead.
Future<void> showRewardPrograms(BuildContext context) async {
  final state = context.read<GameState>();
  state.rewardsScreenOpen = true;
  // Read again as it opens: the day may have turned while the app was up.
  unawaited(state.loadRewardPrograms());
  try {
    await _showRewardsPage(context);
  } finally {
    state.rewardsScreenOpen = false;
  }
}

Future<void> _showRewardsPage(BuildContext context) {
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

/// A program's colour and mark, for what is drawn outside its panel — its
/// own popup's frame and headline (owner, 2 Oct 2026: "for every reward type
/// sequential or calender there should be different pop up"): the colour and
/// mark its kind wears everywhere ([_ProgramLook]).
({Color accent, Color ink, IconData icon}) rewardProgramStyle(
  RewardProgramInfo p,
  ColorScheme scheme,
) {
  final look = _ProgramLook.of(p, scheme);
  return (accent: look.accent, ink: look.ink, icon: look.icon);
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
    // Collecting is the player's tap (30 Sep 2026), and one program at a
    // time (owner, 2 Oct 2026: "not a single pop up to collect all reward"):
    // a day's tile collects its own program (1 Oct 2026), and the lobby's
    // celebration shows what it gave once the screen has closed over it.
    // There is no key that collects every program at once.
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

/// The shape a program's days take (owner, 1 Oct 2026: "Keep different
/// design in ui for daily login, weekly calendar, for different types"): a
/// login streak's days are medallions threaded on a rail — a run to keep
/// going; a sequential login's are steps taken one after another; a
/// calendar's are the pages of a desk calendar, each dated.
enum _DayShape { medallion, step, page }

/// How one kind of program is drawn — every kind its own: its colour (one of
/// the lobby's palettes, so no colour is new), its mark, the shape of its
/// days, and whether its days are chained — a cycle a missed day breaks.
///
///   login streak, RESET       gold, a flame, medallions on a rail
///   login streak, SEQUENTIAL  emerald, stairs, steps joined by chevrons
///   login streak, BREAK       violet, a chain, medallions on a rail
///   calendar, SEQUENTIAL      sapphire, a calendar, pages
///   calendar, BREAK           violet, a chain, pages joined by links
///   calendar, RESET           gold, a flame, pages
class _ProgramLook {
  const _ProgramLook({
    required this.palette,
    required this.icon,
    required this.shape,
    this.chained = false,
  });

  final TablePalette palette;
  final IconData icon;
  final _DayShape shape;

  /// The days are links of one chain: a missed day breaks it.
  final bool chained;

  Color get accent => palette.accent;

  /// The accent as type and glyph on the panel.
  Color get ink => palette.ink;

  /// Type and glyphs laid ON the accent: a collected medallion's mark.
  Color get onAccent => onFill(accent);

  /// White or charcoal, whichever reads on [fill].
  static Color onFill(Color fill) =>
      ThemeData.estimateBrightnessForColor(fill) == Brightness.dark
      ? Colors.white
      : AppTheme.ink900;

  static _ProgramLook of(RewardProgramInfo p, ColorScheme scheme) {
    final gold = AppTheme.paletteFor(scheme, category: 'seen', bootAmount: 0);
    final violet = AppTheme.violetPalette(scheme);
    if (p.isStreak) {
      return switch (p.progression) {
        RewardProgression.sequential => _ProgramLook(
          palette: AppTheme.privatePalette(scheme),
          icon: Icons.stairs_rounded,
          shape: _DayShape.step,
        ),
        RewardProgression.breaks => _ProgramLook(
          palette: violet,
          icon: Icons.link_rounded,
          shape: _DayShape.medallion,
          chained: true,
        ),
        _ => _ProgramLook(
          palette: gold,
          icon: Icons.local_fire_department_rounded,
          shape: _DayShape.medallion,
        ),
      };
    }
    return switch (p.progression) {
      RewardProgression.breaks => _ProgramLook(
        palette: violet,
        icon: Icons.link_rounded,
        shape: _DayShape.page,
        chained: true,
      ),
      RewardProgression.reset => _ProgramLook(
        palette: gold,
        icon: Icons.local_fire_department_rounded,
        shape: _DayShape.page,
      ),
      _ => _ProgramLook(
        palette: AppTheme.paletteFor(scheme, category: 'blind', bootAmount: 0),
        icon: Icons.calendar_month_rounded,
        shape: _DayShape.page,
      ),
    };
  }
}

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
    final p = state.program;
    final look = _ProgramLook.of(p, theme.colorScheme);
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

    final ground = dark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.white.withValues(alpha: 0.55);
    return Container(
      key: ValueKey('reward-program-${p.code}'),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        // Each kind of program in its own colour: a wash of it from the
        // panel's head, and its edge — the error's while a cycle is broken.
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: const [0, 0.55],
          colors: [
            Color.alphaBlend(
              look.accent.withValues(alpha: dark ? 0.12 : 0.08),
              ground,
            ),
            ground,
          ],
        ),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: broken
              ? theme.colorScheme.error.withValues(alpha: 0.6)
              : look.accent.withValues(alpha: dark ? 0.42 : 0.5),
        ),
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
                    look: look,
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
                  // program's own colour.
                  colour: broken ? theme.colorScheme.error : look.ink,
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
                  look: look,
                  t: t,
                  collecting: collecting,
                  onCollect: tap,
                )
              : _MonthGrid(
                  state: state,
                  look: look,
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

/// "LOGIN STREAK" / "CALENDAR" with the program's mark — a flame, stairs, a
/// calendar, a chain — in the program's own colour ([_ProgramLook]).
class _ModeTag extends StatelessWidget {
  const _ModeTag({required this.label, required this.look});

  final String label;
  final _ProgramLook look;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.xxs,
      ),
      decoration: BoxDecoration(
        color: look.accent.withValues(alpha: dark ? 0.16 : 0.12),
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: look.accent.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(look.icon, size: 13, color: look.ink),
          const SizedBox(width: Space.xs),
          Text(
            label,
            maxLines: 1,
            style: AppTheme.label(
              theme.textTheme.labelSmall!,
              colour: look.ink,
              weight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// A week's seven days in one row, joined the way the program's days are: a
/// rail through a streak's medallions (drawn inside each tile, which stand
/// shoulder to shoulder for it), chevrons between a sequential login's
/// steps, chain links between a breaking calendar's pages; a calendar's
/// other pages stand apart.
class _WeekRow extends StatelessWidget {
  const _WeekRow({
    required this.state,
    required this.look,
    required this.t,
    this.collecting = false,
    this.onCollect,
  });

  final RewardProgramState state;
  final _ProgramLook look;
  final Strings t;
  final bool collecting;
  final VoidCallback? onCollect;

  /// A day's box: taller than the 68 it was (owner, 30 Sep 2026: "Increase
  /// the size of each box of Day along with text"), room for the larger
  /// type [_DayTile] sets.
  static const double tileHeight = 96;

  /// The width a joint — a chevron, a link — takes between two days.
  static const double jointWidth = 14;

  @override
  Widget build(BuildContext context) {
    final days = state.periodDays.clamp(1, 7);
    final medallions = look.shape == _DayShape.medallion;
    final joined =
        look.shape == _DayShape.step ||
        (look.shape == _DayShape.page && look.chained);
    return Row(
      children: [
        for (var k = 1; k <= days; k++) ...[
          if (k > 1 && joined) _Joint(state: state, look: look, after: k - 1),
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: medallions || joined ? 0 : Space.xxs,
              ),
              child: _DayTile(
                program: state,
                look: look,
                day: k,
                days: days,
                rail: medallions,
                t: t,
                height: tileHeight,
                collecting: collecting,
                onCollect: onCollect,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// What joins day [after] to the next: a sequential login's chevron, or a
/// breaking calendar's link — in the program's colour where both days are
/// collected (or the second can be now), broken and in the error ink on both
/// sides of the day whose miss broke the cycle (so the break shows when that
/// is Day 1, the usual case for a player who first opens a breaking calendar
/// mid-week), quiet elsewhere.
class _Joint extends StatelessWidget {
  const _Joint({required this.state, required this.look, required this.after});

  final RewardProgramState state;
  final _ProgramLook look;
  final int after;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final here = _ProgramPanel.stateOf(state, after);
    final next = _ProgramPanel.stateOf(state, after + 1);
    final missed = state.missedDay;
    final broke = missed >= 1 && (after + 1 == missed || after == missed);
    final held =
        here == _DayState.claimed &&
        (next == _DayState.claimed || next == _DayState.available);
    final icon = look.shape == _DayShape.step
        ? Icons.chevron_right_rounded
        : broke
        ? Icons.link_off_rounded
        : Icons.link_rounded;
    return ExcludeSemantics(
      child: SizedBox(
        width: _WeekRow.jointWidth,
        child: Center(
          child: Icon(
            icon,
            key: ValueKey('reward-joint-${state.program.code}-$after'),
            size: _WeekRow.jointWidth,
            color: broke
                ? theme.colorScheme.error
                : held
                ? look.ink
                : glass.cardMuted.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}

/// A month's 28 to 31 days, seven to a row — never 31 large cards on a phone
/// (the brief's §27): the page scrolls, the grid does not. Its days take the
/// program's shape; nothing joins them across the grid's rows.
class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.state,
    required this.look,
    required this.t,
    this.collecting = false,
    this.onCollect,
    this.aspect = 1.2,
  });

  final RewardProgramState state;
  final _ProgramLook look;
  final Strings t;
  final bool collecting;
  final VoidCallback? onCollect;

  /// A cell's width over its height: the screen's 1.2, or what fills a
  /// popup's card.
  final double aspect;

  @override
  Widget build(BuildContext context) {
    final days = state.periodDays.clamp(1, 31);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        mainAxisSpacing: Space.xs,
        crossAxisSpacing: Space.xs,
        childAspectRatio: aspect,
      ),
      itemCount: days,
      itemBuilder: (_, i) => _DayTile(
        program: state,
        look: look,
        day: i + 1,
        days: days,
        t: t,
        height: null,
        collecting: collecting,
        onCollect: onCollect,
      ),
    );
  }
}

/// A program's days for its own popup (owner, 2 Oct 2026: "for every reward
/// type sequential or calender there should be different pop up, not a
/// single pup up to collect all reward"): the days its panel draws — a login
/// streak's medallions on their rail, a sequential login's steps joined by
/// chevrons, a calendar's pages, a breaking cycle's pages joined by its chain
/// — on a card of the program's own colour, headed by its mode's tag and its
/// cycle's dates, filling [size]: a week's seven four over three (the
/// owner's calendar's arrangement), a month's dates seven to a row. Today's
/// day collects the program with a tap ([onCollect]), as on the rewards
/// screen.
class RewardProgramDays extends StatelessWidget {
  const RewardProgramDays({
    super.key,
    required this.state,
    required this.size,
    this.collecting = false,
    this.onCollect,
  });

  final RewardProgramState state;
  final Size size;

  /// A claim of this program is out: its day shows the loader.
  final bool collecting;

  /// Collects the program — null while a claim is out.
  final VoidCallback? onCollect;

  @override
  Widget build(BuildContext context) {
    final t = Strings(context.select<GameState, AppLang>((s) => s.lang));
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final p = state.program;
    final look = _ProgramLook.of(p, theme.colorScheme);
    final cycle = rewardCycleLabel(t, state.cycle);
    final quiet = theme.colorScheme.onSurface.withValues(
      alpha: AppTheme.inkLowOn(theme.brightness),
    );
    // The owner's calendar card's own body — charcoal by night, warm
    // off-white by day, in the open level's hue inside Blind or Variation —
    // and opaque, as that card is: a translucent ground let the lobby's
    // cards show through a popup's days by night.
    final ground = WeeklyCardColours.of(
      theme.brightness,
      LevelAccent.of(context),
    ).body;
    return SizedBox.fromSize(
      size: size,
      child: DecoratedBox(
        key: const ValueKey('reward-offer-stage'),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(
                look.accent.withValues(alpha: dark ? 0.16 : 0.12),
                ground,
              ),
              Color.alphaBlend(
                look.accent.withValues(alpha: dark ? 0.05 : 0.04),
                ground,
              ),
            ],
          ),
          borderRadius: BorderRadius.circular(Radii.lg),
          border: Border.all(
            color: look.accent.withValues(alpha: dark ? 0.5 : 0.55),
            width: 1.5,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Space.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The tag says which kind of program this is; the dates, the
              // cycle it stands in.
              Row(
                children: [
                  _ModeTag(
                    label: p.isStreak
                        ? t.rewardModeStreak
                        : t.rewardModeCalendar,
                    look: look,
                  ),
                  const SizedBox(width: Space.sm),
                  if (cycle != null)
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          cycle,
                          key: const ValueKey('reward-offer-cycle'),
                          maxLines: 1,
                          style: AppTheme.label(
                            theme.textTheme.labelMedium!,
                            colour: quiet,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Space.sm),
              Expanded(
                child: p.isWeekly
                    ? _WeekStage(
                        state: state,
                        look: look,
                        t: t,
                        collecting: collecting,
                        onCollect: onCollect,
                      )
                    : LayoutBuilder(
                        builder: (context, box) {
                          // Cells that fill the card: seven across, as many
                          // rows as the month needs, every row as tall as
                          // the card allows.
                          final days = state.periodDays.clamp(1, 31);
                          final rows = (days / 7).ceil();
                          final cellW = (box.maxWidth - 6 * Space.xs) / 7;
                          final cellH =
                              (box.maxHeight - (rows - 1) * Space.xs) / rows;
                          final aspect = (cellW / cellH).clamp(0.6, 2.0);
                          return Align(
                            alignment: Alignment.topCenter,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: SizedBox(
                                width: box.maxWidth,
                                child: _MonthGrid(
                                  state: state,
                                  look: look,
                                  t: t,
                                  collecting: collecting,
                                  onCollect: onCollect,
                                  aspect: aspect,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A week's seven days for a popup: four over three, each row joined the
/// program's way and centred, its days as wide as the first row's.
class _WeekStage extends StatelessWidget {
  const _WeekStage({
    required this.state,
    required this.look,
    required this.t,
    this.collecting = false,
    this.onCollect,
  });

  final RewardProgramState state;
  final _ProgramLook look;
  final Strings t;
  final bool collecting;
  final VoidCallback? onCollect;

  /// The tallest a row of days stands — a little over the screen's
  /// [_WeekRow.tileHeight]; a taller card centres its rows.
  static const double rowMax = 116;

  @override
  Widget build(BuildContext context) {
    final days = state.periodDays.clamp(1, 7);
    final medallions = look.shape == _DayShape.medallion;
    final joined =
        look.shape == _DayShape.step ||
        (look.shape == _DayShape.page && look.chained);
    final between = medallions
        ? 0.0
        : joined
        ? _WeekRow.jointWidth
        : Space.xs;
    return LayoutBuilder(
      builder: (context, box) {
        final rowH = math.min(rowMax, (box.maxHeight - Space.sm) / 2);
        final tileW = (box.maxWidth - 3 * between) / 4;
        Widget row(int first, int last) => SizedBox(
          height: rowH,
          width: (last - first + 1) * tileW + (last - first) * between,
          child: Row(
            children: [
              for (var k = first; k <= last; k++) ...[
                if (k > first)
                  joined
                      ? _Joint(state: state, look: look, after: k - 1)
                      : SizedBox(width: between),
                SizedBox(
                  width: tileW,
                  child: _DayTile(
                    program: state,
                    look: look,
                    day: k,
                    days: days,
                    rowStart: first,
                    rowEnd: last,
                    rail: medallions,
                    t: t,
                    height: rowH,
                    collecting: collecting,
                    onCollect: onCollect,
                  ),
                ),
              ],
            ],
          ),
        );
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            row(1, math.min(4, days)),
            if (days > 4) ...[const SizedBox(height: Space.sm), row(5, days)],
          ],
        );
      },
    );
  }
}

/// One day, drawn in its program's shape ([_ProgramLook]): a streak's
/// medallion on its rail, a sequential login's step, a calendar's page.
/// Every shape says the same things — the day's label, its reward's mark and
/// figure, and its standing: collected (a tick, the program's colour),
/// collectable now (the program's colour round it, a glow, and a Collect
/// that collects its program with a tap — the loader there while the claim is
/// out), not reached (faded, a padlock) or missed (faded, a ✕ — in the error
/// ink on the day that broke a cycle). Everything inside is set down to fit,
/// never cut.
class _DayTile extends StatelessWidget {
  const _DayTile({
    required this.program,
    required this.look,
    required this.day,
    required this.t,
    required this.height,
    this.days = 0,
    this.rowStart = 1,
    this.rowEnd,
    this.rail = false,
    this.collecting = false,
    this.onCollect,
  });

  final RewardProgramState program;
  final _ProgramLook look;
  final int day;
  final Strings t;

  /// A fixed height, or null to take the grid cell's.
  final double? height;

  /// The days in its row: a medallion's rail runs to neither side of the
  /// row's ends.
  final int days;

  /// The first and last days of the tile's own row, where a medallion's rail
  /// ends: the whole run in a week's one row (the default), each row's own
  /// days where a popup lays the week four over three.
  final int rowStart;
  final int? rowEnd;

  /// A medallion threads the rail through its row (a week's); a month's grid
  /// draws none, since its rows would join the wrong days.
  final bool rail;

  /// The claim out collects this program: the loader in place of Collect.
  final bool collecting;

  /// Collects this program — null while a claim is out, or with nothing to
  /// collect. Only the day that can be collected now takes the tap.
  final VoidCallback? onCollect;

  /// The type on a tile (owner, 30 Sep 2026: "Increase the size of each box
  /// of Day along with text" — the label ramp's smallest step, 11, for
  /// everything before): the day's label, its weekday, the prize's mark and
  /// its figure. A tile too small for them — a month's cell on a phone — sets
  /// its words down whole.
  static const double labelSize = 13;
  static const double subSize = 12;
  static const double markSize = 22;
  static const double figureSize = 15.5;

  /// A calendar page's date, the largest thing on it.
  static const double dateSize = 22;

  /// A medallion's share of its tile's height (and at most of its width,
  /// [medallionWidthShare]); the rail through it.
  static const double medallionShare = 0.40;
  static const double medallionWidthShare = 0.62;
  static const double railWidth = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final b = theme.brightness;
    final dark = b == Brightness.dark;
    final glass = GlassColors.of(context);
    final error = theme.colorScheme.error;
    final code = program.program.code;
    final prize = program.rewardFor(day)?.prize;
    final standing = _ProgramPanel.stateOf(program, day);
    final available = standing == _DayState.available;
    final claimed = standing == _DayState.claimed;
    final today = available || _ProgramPanel.isToday(program, day);
    final collect = onCollect;
    final tappable = available && collect != null;
    final (label, sub) = _ProgramPanel.labelsOf(program, day, t);
    final faded = standing == _DayState.locked || standing == _DayState.missed;
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
    // or date (of its label, where it has no second line), so its words are
    // no taller than its neighbours' and never set down smaller than theirs.
    // A screen reader still hears every word.
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
    final glow = available
        ? [
            BoxShadow(
              color: look.accent.withValues(alpha: dark ? 0.45 : 0.35),
              blurRadius: 10,
            ),
          ]
        : null;

    final labelStyle = AppTheme.label(
      text.labelSmall!,
      fontSize: labelSize,
      colour: today ? look.ink : glass.cardMuted,
      weight: FontWeight.w700,
    );
    final subStyle = text.labelSmall?.copyWith(
      fontSize: subSize,
      color: glass.cardMuted,
    );

    // What every tile of the row keeps to, so that its lines stand level
    // with its neighbours': a weekday or date line wherever any day of the
    // row has one (a streak's days past its cycle have none), and room for
    // the Collect wherever a day of the row can be collected.
    final span = days > 0 ? days : day;
    final rowHasSub = [
      for (var k = 1; k <= span; k++) _ProgramPanel.labelsOf(program, k, t).$2,
    ].any((s) => s != null);
    final rowCollects = [
      for (var k = 1; k <= span; k++) _ProgramPanel.stateOf(program, k),
    ].contains(_DayState.available);
    final collectHeight = rowCollects
        ? _CollectTag.heightFor(context, t.rewardTileCollect)
        : 0.0;

    // One line of a tile, set down on its own to the tile's [width] — so a
    // long prize name ("Clapping Hands") never shrinks the date or the label
    // above it — and always as tall as a line of [style] at its full size
    // (a hidden figure holds it), or [minHeight] where that is taller. Every
    // tile of a row has the same lines, so its column of them is one height,
    // and where that is too tall for the tile all the row's tiles are set
    // down by the same share: a page's date stands as large beside a long
    // name as beside a figure, and every reward's mark and figure stand
    // level along the row.
    Widget fitLine(
      double width,
      Widget line, {
      required TextStyle? style,
      double minHeight = 0,
    }) => SizedBox(
      width: width,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Opacity(opacity: 0, child: Text('0', style: style)),
          if (minHeight > 0) SizedBox(height: minHeight),
          FittedBox(fit: BoxFit.scaleDown, child: line),
        ],
      ),
    );

    // The day's words over its reward, a line each: its label over its
    // weekday or date (a blank line where this day has none but the row
    // does), the Collect in place of the second line, or of the only one.
    List<Widget> headLines(double width) {
      final collectOnLabel = !rowHasSub;
      return [
        fitLine(
          width,
          collectMark != null && collectOnLabel
              ? collectMark
              : Text(label, style: labelStyle),
          style: labelStyle,
          minHeight: collectOnLabel ? collectHeight : 0,
        ),
        if (rowHasSub)
          fitLine(
            width,
            collectMark ?? Text(sub ?? '', style: subStyle),
            style: subStyle,
            minHeight: collectHeight,
          ),
      ];
    }

    Icon markIcon(double size, Color colour) => Icon(
      prize == null ? Icons.remove_rounded : rewardPrizeIcon(prize),
      size: size,
      color: colour,
    );

    final figureStyle = AppTheme.money(
      text.labelSmall!,
      fontSize: figureSize,
      colour: theme.colorScheme.onSurface,
    );
    final figure = Text(
      prize == null ? '' : rewardPrizeShort(prize),
      key: ValueKey('reward-figure-$code-$day'),
      style: figureStyle,
    );
    Widget figureLine(double width) =>
        fitLine(width, figure, style: figureStyle);

    // The standing's mark at the corner: [quiet] where it says nothing loud
    // (a padlock, a ✕ on a day that broke nothing).
    Widget? badge(Color quiet) => switch (standing) {
      _DayState.claimed => Icon(
        Icons.check_circle_rounded,
        size: 14,
        color: theme.colorScheme.primary,
      ),
      _DayState.locked => Icon(Icons.lock_rounded, size: 12, color: quiet),
      _DayState.missed => Icon(
        Icons.cancel_rounded,
        key: ValueKey('reward-missed-$code-$day'),
        size: 13,
        color: program.isBroken ? error : quiet,
      ),
      _DayState.available => null,
    };

    // A login streak: a medallion threaded on the run's rail — in the
    // program's colour where the run holds (both days collected, or the
    // second collectable now), in the error ink on both sides of the day
    // whose miss broke the cycle, quiet elsewhere.
    Widget medallionFace() {
      bool reached(_DayState s) =>
          s == _DayState.claimed || s == _DayState.available;
      final missed = program.missedDay;
      // The rail from day [a] to the next.
      Color railAfter(int a) {
        if (missed >= 1 && (a == missed || a + 1 == missed)) return error;
        final from = _ProgramPanel.stateOf(program, a);
        final to = _ProgramPanel.stateOf(program, a + 1);
        if (from == _DayState.claimed && reached(to)) return look.accent;
        return glass.cardMuted.withValues(alpha: 0.32);
      }

      final railIn = rail && day > rowStart ? railAfter(day - 1) : null;
      final railOut = rail && day < (rowEnd ?? days) ? railAfter(day) : null;
      Widget railPart(Color? colour) => Expanded(
        child: colour == null
            ? const SizedBox.shrink()
            : Center(
                child: Container(height: railWidth, color: colour),
              ),
      );
      final paper = dark ? Colors.white.withValues(alpha: 0.06) : Colors.white;
      final corner = badge(glass.cardMuted);
      return LayoutBuilder(
        builder: (context, box) {
          final h = height ?? box.maxHeight;
          final d = math.min(
            h * medallionShare,
            box.maxWidth * medallionWidthShare,
          );
          final disc = DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: claimed
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [look.palette.rimHigh, look.palette.rimLow],
                    )
                  : null,
              color: claimed
                  ? null
                  : available
                  ? Color.alphaBlend(
                      look.accent.withValues(alpha: dark ? 0.18 : 0.12),
                      paper,
                    )
                  : paper,
              border: claimed
                  ? null
                  : Border.all(
                      color: available ? look.accent : glass.cardBorder,
                      width: available ? 2.5 : 1.2,
                    ),
              boxShadow: glow,
            ),
            child: Center(
              child: markIcon(d * 0.5, claimed ? look.onAccent : ink),
            ),
          );
          return SizedBox(
            height: h,
            child: Column(
              children: [
                SizedBox(
                  height: h * 0.36,
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: headLines(box.maxWidth),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: d,
                  child: Row(
                    children: [
                      railPart(railIn),
                      SizedBox.square(
                        dimension: d,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned.fill(child: disc),
                            if (corner != null)
                              Positioned(top: -3, right: -4, child: corner),
                          ],
                        ),
                      ),
                      railPart(railOut),
                    ],
                  ),
                ),
                const SizedBox(height: Space.xxs),
                Expanded(
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: figureLine(box.maxWidth),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    }

    // A calendar: a desk calendar's page — a band in the program's colour
    // across its head carrying the weekday (a week's), the date large under
    // it, then the reward. The band says the standing too: the program's
    // colour collected or collectable, a pale one ahead, grey for a date gone
    // by, the error's on the day that broke a cycle.
    Widget pageFace() {
      final weekly = program.program.isWeekly;
      final paper = dark ? Colors.white.withValues(alpha: 0.06) : Colors.white;
      final bandFill = switch (standing) {
        _DayState.claimed || _DayState.available => look.accent,
        _DayState.missed =>
          program.isBroken
              ? error.withValues(alpha: 0.24)
              : glass.cardMuted.withValues(alpha: 0.2),
        _DayState.locked => look.accent.withValues(alpha: dark ? 0.36 : 0.3),
      };
      final onBand = _ProgramLook.onFill(
        Color.alphaBlend(bandFill, AppTheme.panelBase(b)),
      );
      final date = weekly ? sub : label;
      final dateStyle = AppTheme.money(
        text.titleMedium!,
        fontSize: dateSize,
        colour: today ? look.ink : theme.colorScheme.onSurface,
      );
      final corner = badge(onBand);
      return LayoutBuilder(
        builder: (context, box) {
          final h = height ?? box.maxHeight;
          final band = weekly ? h * 0.24 : math.max(h * 0.17, 14.0);
          return Container(
            height: h,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: paper,
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(
                color: today ? look.accent : glass.cardBorder,
                width: today ? 1.5 : 1,
              ),
              boxShadow: glow,
            ),
            child: Column(
              children: [
                Container(
                  height: band,
                  width: double.infinity,
                  color: bandFill,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (weekly)
                        Padding(
                          // Clear of the corner's mark on either side.
                          padding: const EdgeInsets.symmetric(
                            horizontal: Space.lg + Space.xxs,
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              label,
                              style: AppTheme.label(
                                text.labelSmall!,
                                fontSize: subSize,
                                colour: onBand,
                                weight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      if (corner != null)
                        Positioned(right: Space.xxs, child: corner),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Space.xxs,
                      Space.xxs,
                      Space.xxs,
                      Space.xs,
                    ),
                    child: LayoutBuilder(
                      builder: (context, body) => Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              fitLine(
                                body.maxWidth,
                                collectMark ??
                                    Text(date ?? '', style: dateStyle),
                                style: dateStyle,
                                minHeight: collectHeight,
                              ),
                              const SizedBox(height: Space.xxs),
                              markIcon(markSize * 0.8, ink),
                              figureLine(body.maxWidth),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    }

    // A sequential login: a step — a square in the program's colour, filled
    // once taken, ringed while it is the one to take.
    Widget stepFace() {
      final fill = switch (standing) {
        _DayState.claimed => look.accent.withValues(alpha: dark ? 0.22 : 0.15),
        _DayState.available => look.accent.withValues(
          alpha: dark ? 0.10 : 0.07,
        ),
        _ =>
          dark
              ? Colors.white.withValues(alpha: 0.04)
              : Colors.black.withValues(alpha: 0.03),
      };
      final corner = badge(glass.cardMuted);
      return Container(
        height: height,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(
            color: today
                ? look.accent
                : claimed
                ? look.accent.withValues(alpha: 0.55)
                : glass.cardBorder,
            width: today ? 1.5 : 1,
          ),
          boxShadow: glow,
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
                child: LayoutBuilder(
                  builder: (context, body) => Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ...headLines(body.maxWidth),
                          const SizedBox(height: Space.xxs),
                          markIcon(markSize, ink),
                          figureLine(body.maxWidth),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (corner != null)
              Positioned(top: Space.xxs, right: Space.xxs, child: corner),
          ],
        ),
      );
    }

    final face = switch (look.shape) {
      _DayShape.medallion => medallionFace(),
      _DayShape.page => pageFace(),
      _DayShape.step => stepFace(),
    };

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
          child: Opacity(opacity: faded ? 0.45 : 1, child: face),
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

  /// At least a line of the tile's own type tall, and taller where the
  /// script's line is (Devanagari, Bengali …): never clipped.
  static const double minHeight = 18;
  static const double padY = 1;

  static TextStyle styleOf(BuildContext context) => AppTheme.label(
    Theme.of(context).textTheme.labelSmall!,
    fontSize: 11,
    colour: AppTheme.ink900,
    weight: FontWeight.w700,
  );

  /// The tag's height for [label] here — its line measured in the type and
  /// the script the phone draws it in (a line that mixes scripts stands
  /// taller than either font's, so it is measured, never worked out), its
  /// padding, and never under [minHeight]: what a tile's line keeps room for
  /// wherever its row has a day to collect.
  static double heightFor(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: styleOf(context)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final height = painter.height + 2 * padY;
    painter.dispose();
    return math.max(minHeight, height);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: minHeight),
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: padY),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: AppTheme.goldFace,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(label, maxLines: 1, style: styleOf(context)),
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
