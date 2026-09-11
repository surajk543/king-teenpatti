import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../settings/feedback_settings.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import 'glass_components.dart';

/// The sound and vibration switches.
///
/// Kept together and kept out of GameState: they are the two settings that
/// change how the game FEELS rather than anything about the game, and nothing
/// on the felt should rebuild when one is flipped.
class FeedbackToggles extends StatelessWidget {
  const FeedbackToggles({super.key});

  @override
  Widget build(BuildContext context) {
    final feedback = context.watch<FeedbackSettings>();
    final t = context.read<GameState>().t;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _FeedbackSwitch(
          icon: feedback.sound
              ? Icons.volume_up_rounded
              : Icons.volume_off_rounded,
          label: t.soundLabel,
          value: feedback.sound,
          onChanged: feedback.setSound,
        ),
        _FeedbackSwitch(
          icon: feedback.vibrate
              ? Icons.vibration_rounded
              : Icons.smartphone_rounded,
          label: t.vibrationLabel,
          value: feedback.vibrate,
          onChanged: feedback.setVibrate,
        ),
      ],
    );
  }
}

class _FeedbackSwitch extends StatelessWidget {
  const _FeedbackSwitch({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface;

    // No panel of its own: the drawer around the row is the surface. The
    // press-scale and the haptic are the row's only chrome.
    //
    // haptic: false, uniquely among the app's rows. This row has two targets
    // — the text and the thumb — and the thumb is its own gesture that the
    // row's InkWell never sees, while the PressScale is a raw Listener that
    // sees BOTH. Left to tap for itself it would buzz twice for a thumb tap
    // and once for everything else. So the two targets tap for themselves and
    // the scale stays silent.
    return PressScale(
      haptic: false,
      child: InkWell(
        // Material's own click, gated on the player's Sound switch —
        // otherwise a silenced game would still tick on every tap.
        enableFeedback: context.select<FeedbackSettings, bool>((f) => f.sound),
        onTap: () {
          // Read before the flip, so silencing vibration still acknowledges
          // the tap that silenced it.
          tapHaptic(context);
          onChanged(!value);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.lg,
            vertical: Space.sm,
          ),
          child: Row(
            children: [
              // The icon carries the state as well as the switch does — a
              // crossed-out speaker is readable at a glance where a switch
              // position alone is not.
              Icon(
                icon,
                size: 20,
                color: value ? ink : ink.withValues(alpha: AppTheme.inkLow),
              ),
              const SizedBox(width: Space.lg),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: value ? ink : ink.withValues(alpha: AppTheme.inkMed),
                  ),
                ),
              ),
              // The thumb is its own gesture: a tap on it never reaches the
              // row's InkWell. It taps for itself, then hands the caller's
              // callback the value exactly once.
              Switch(
                value: value,
                onChanged: (v) {
                  tapHaptic(context);
                  onChanged(v);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
