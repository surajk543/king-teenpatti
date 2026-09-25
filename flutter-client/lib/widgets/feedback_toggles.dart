import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../settings/feedback_settings.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import 'glass_components.dart';

/// The sound and vibration switches.
///
/// Kept together and kept out of GameState: they are the two settings that
/// change how the game FEELS rather than anything about the game, and nothing
/// on the felt should rebuild when one is flipped.
///
/// Two placements share it: the table's menu drawer lays the two rows between
/// its own, and the lobby's Settings drawer lays them in a settings group
/// ([grouped], the settings polish of 26 Sep 2026) — the group's inset, its
/// 48dp row rhythm, and [divider] between them.
class FeedbackToggles extends StatelessWidget {
  const FeedbackToggles({super.key, this.grouped = false, this.divider});

  /// Rows sized for a settings group: the group's own inner margin rather than
  /// the drawer's, and [FeedbackSwitchStyle.groupedRowHeight] tall.
  final bool grouped;

  /// Laid between the two rows; none by default.
  final Widget? divider;

  @override
  Widget build(BuildContext context) {
    final feedback = context.watch<FeedbackSettings>();
    // Subscribed to the language, not read once: both drawers place this as a
    // const widget, so their own rebuilds never reach it, and a language
    // picked with the drawer open left these two labels in the old one.
    // Selecting on `lang` alone keeps the one-second tick out of it.
    final t = Strings(context.select<GameState, AppLang>((s) => s.lang));
    final rule = divider;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FeedbackSwitch(
          icon: feedback.sound
              ? Icons.volume_up_rounded
              : Icons.volume_off_rounded,
          label: t.soundLabel,
          value: feedback.sound,
          onChanged: feedback.setSound,
          grouped: grouped,
        ),
        ?rule,
        _FeedbackSwitch(
          icon: feedback.vibrate
              ? Icons.vibration_rounded
              : Icons.smartphone_rounded,
          label: t.vibrationLabel,
          value: feedback.vibrate,
          onChanged: feedback.setVibrate,
          grouped: grouped,
        ),
      ],
    );
  }
}

/// How a settings switch is drawn: the app's gold when it is on, a quiet
/// outline when it is off (the settings polish, 26 Sep 2026).
///
/// Gold because it is the accent every chosen thing in the drawers already
/// wears — the number format's tick, the appearance control's thumb, the
/// store's shelf keys — where the switches alone wore the scheme's green
/// (mint by night), a colour that meant nothing else there. The gold is the
/// struck-gold key's own ([AppTheme.goldFace]): its middle by night, where a
/// charcoal thumb stands on it as the charcoal word does on the gold key, and
/// its deep foot by day, where a white thumb holds 3:1 and the track holds 3:1
/// against the pale drawer. Off, the outline and the thumb keep 3:1 on both
/// grounds, so a switch that is off still reads as a switch.
class FeedbackSwitchStyle {
  const FeedbackSwitchStyle._();

  /// A row's height inside a settings group — the touch target and a margin.
  static const double groupedRowHeight = Dim.minTouch + Space.xs;

  /// The track when on: the struck-gold face's middle by night, its foot by
  /// day.
  static Color trackOn(Brightness b) => b == Brightness.dark
      ? AppTheme.goldFace.colors[1]
      : AppTheme.goldFace.colors.last;

  /// The thumb when on.
  static Color thumbOn(Brightness b) =>
      b == Brightness.dark ? AppTheme.ink800 : Colors.white;

  /// The outline and thumb when off: the ink at a strength that keeps 3:1.
  static Color offInk(ColorScheme scheme) => scheme.onSurface.withValues(
    alpha: scheme.brightness == Brightness.dark ? 0.62 : 0.58,
  );

  static WidgetStateProperty<Color?> thumb(ColorScheme scheme) =>
      WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? thumbOn(scheme.brightness)
            : offInk(scheme),
      );

  static WidgetStateProperty<Color?> track(ColorScheme scheme) =>
      WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? trackOn(scheme.brightness)
            : scheme.onSurface.withValues(alpha: 0.06),
      );

  static WidgetStateProperty<Color?> outline(ColorScheme scheme) =>
      WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? Colors.transparent
            : offInk(scheme),
      );
}

class _FeedbackSwitch extends StatelessWidget {
  const _FeedbackSwitch({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.grouped,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool grouped;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ink = scheme.onSurface;

    final row = Row(
      children: [
        // The icon carries the state as well as the switch does — a
        // crossed-out speaker is readable at a glance where a switch
        // position alone is not.
        Icon(
          icon,
          size: 20,
          color: ink.withValues(
            alpha: value ? AppTheme.inkMed : AppTheme.inkLow,
          ),
        ),
        SizedBox(width: grouped ? Space.md : Space.lg),
        Expanded(
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.label(
              theme.textTheme.bodyMedium!,
              colour: value ? ink : ink.withValues(alpha: AppTheme.inkMed),
              weight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: Space.sm),
        // The thumb is its own gesture: a tap on it never reaches the
        // row's InkWell. It taps for itself, then hands the caller's
        // callback the value exactly once.
        Switch(
          value: value,
          onChanged: (v) {
            tapHaptic(context);
            onChanged(v);
          },
          thumbColor: FeedbackSwitchStyle.thumb(scheme),
          trackColor: FeedbackSwitchStyle.track(scheme),
          trackOutlineColor: FeedbackSwitchStyle.outline(scheme),
          // In a group the whole row is the target, so the switch keeps only
          // its own size and the row keeps the group's rhythm.
          materialTapTargetSize: grouped
              ? MaterialTapTargetSize.shrinkWrap
              : null,
        ),
      ],
    );

    final body = grouped
        ? ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: FeedbackSwitchStyle.groupedRowHeight,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.md,
                vertical: Space.xs,
              ),
              child: row,
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.lg,
              vertical: Space.sm,
            ),
            child: row,
          );

    final inkWell = InkWell(
      // Material's own click, gated on the player's Sound switch —
      // otherwise a silenced game would still tick on every tap.
      enableFeedback: context.select<FeedbackSettings, bool>((f) => f.sound),
      onTap: () {
        // Read before the flip, so silencing vibration still acknowledges
        // the tap that silenced it.
        tapHaptic(context);
        onChanged(!value);
      },
      child: body,
    );

    // No panel of its own: the drawer (or the group) around the row is the
    // surface. MergeSemantics: the row's InkWell is its own semantics node,
    // so a screen reader landed on the row and heard a button with no on/off
    // state while the Switch's toggled state sat on a separate node beside
    // it. Merged, the row reads as one switch that says whether it is on.
    //
    // In the table's drawer the row presses in (haptic: false, uniquely among
    // the app's rows: this row has two targets — the text and the thumb — and
    // the thumb is its own gesture that the row's InkWell never sees, while
    // the PressScale is a raw Listener that sees BOTH; left to tap for itself
    // it would buzz twice for a thumb tap). In a group it does not: a row
    // shrinking inside its group's edge reads as the group coming apart, and
    // the group's own ink says the row was pressed.
    return MergeSemantics(
      child: grouped ? inkWell : PressScale(haptic: false, child: inkWell),
    );
  }
}
