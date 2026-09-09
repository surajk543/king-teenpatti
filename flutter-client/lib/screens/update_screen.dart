import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../net/app_update.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../widgets/drifting_chips.dart';
import '../widgets/poker_chip.dart';
import '../widgets/premium_surface.dart';

/// Stands in front of sign-in when Play has a newer build.
///
/// There is no way past it. That is the point: an old client and a newer
/// server can disagree about the wire, and the failure that produces looks
/// like a broken game rather than an old one. Better to say so plainly here
/// than to let someone sit down at a table and find out later.
///
/// It is only ever reached when Play itself reported an update, so a debug or
/// side-loaded build never sees it — the check fails open (net/app_update.dart).
class UpdateScreen extends StatelessWidget {
  const UpdateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<GameState>();
    final t = state.t;
    // Play can install in place, or only send them to the listing. The button
    // says which, because "Update now" that opens a store page is a small lie.
    final inPlace = state.updateStatus == UpdateStatus.available;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const IgnorePointer(child: DriftingChips(strength: 1.6)),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: PremiumSurface(
                  accent: AppTheme.gold,
                  radius: 26,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(30, 28, 30, 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SpinningChip(
                          colour: AppTheme.gold,
                          size: 54,
                          turn: const Duration(milliseconds: 1100),
                          rest: const Duration(milliseconds: 900),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          t.updateTitle,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          t.updateBody,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 22),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed:
                                state.updating ? null : state.startUpdate,
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: const StadiumBorder(),
                            ),
                            child: state.updating
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2.4),
                                  )
                                : Text(
                                    inPlace ? t.updateNow : t.updateOpenStore,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 16,
                                    ),
                                  ),
                          ),
                        ),
                        if (state.appVersion.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Text(
                            state.appVersion,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
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
  }
}
