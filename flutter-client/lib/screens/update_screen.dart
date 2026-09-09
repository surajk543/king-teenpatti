import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../net/app_update.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../widgets/drifting_chips.dart';
import '../widgets/poker_chip.dart';
import '../widgets/premium_surface.dart';
import '../widgets/table_ground.dart';

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
    final state = context.watch<GameState>();
    final t = state.t;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    // Play can install in place, or only send them to the listing. The button
    // says which, because "Update now" that opens a store page is a small lie.
    final inPlace = state.updateStatus == UpdateStatus.available;

    return Scaffold(
      body: LobbyGround(
        child: Stack(
          fit: StackFit.expand,
          children: [
            const IgnorePointer(child: DriftingChips(strength: 1.6)),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.xl,
                  vertical: Space.lg,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: Dim.dialogW(width)),
                  // Solid, not glass: the chips behind it drift for as long as
                  // this screen is up, and a filter over a moving backdrop
                  // re-blurs on every frame of it.
                  child: PremiumSurface(
                    accent: AppTheme.gold,
                    child: Padding(
                      padding: const EdgeInsets.all(Space.xxl),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SpinningChip(
                            colour: AppTheme.gold,
                            size: 54,
                            turn: const Duration(milliseconds: 1100),
                            rest: const Duration(milliseconds: 900),
                          ),
                          const SizedBox(height: Space.xl),
                          Text(
                            t.updateTitle,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineSmall,
                          ),
                          const SizedBox(height: Space.md),
                          Text(
                            t.updateBody,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurface
                                  .withValues(alpha: AppTheme.inkMed),
                            ),
                          ),
                          const SizedBox(height: Space.xl),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed:
                                  state.updating ? null : state.startUpdate,
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(52),
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
                                    ),
                            ),
                          ),
                          if (state.appVersion.isNotEmpty) ...[
                            const SizedBox(height: Space.lg),
                            Text(
                              state.appVersion,
                              style: AppTheme.money(
                                theme.textTheme.labelSmall ??
                                    const TextStyle(),
                                weight: FontWeight.w500,
                                colour: scheme.onSurface.withValues(alpha: 0.40),
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
      ),
    );
  }
}
