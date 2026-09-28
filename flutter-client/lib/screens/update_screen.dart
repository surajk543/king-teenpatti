import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../net/app_version.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/depth.dart';
import '../theme/theme_colors.dart';
import '../widgets/drifting_chips.dart';
import '../widgets/game_loader.dart';
import '../widgets/glass_components.dart';
import '../widgets/poker_chip.dart';
import '../widgets/premium_surface.dart';
import '../widgets/table_ground.dart';

/// Force Update: the build is below the minimum the server keeps for its
/// platform (the app version gate, 28 Sep 2026), or below the build floor an
/// older server sends (`minClientBuild`).
///
/// There is no way past it — no Later, no Skip. That is the point: the server
/// refuses this build at every signed-in door anyway, and an old client and a
/// newer server can disagree about the wire, which looks like a broken game
/// rather than an old one. Better to say so plainly here than to let someone
/// sit down at a table and find out later.
///
/// Update now opens the store the server named for this platform — Google
/// Play on Android, the App Store on iOS — or, on Android when Play can,
/// installs in place ([GameState.startUpdate]); when no store can be opened
/// the player is told so. The operator's message, when the server sent one,
/// stands in place of the app's own words.
class UpdateScreen extends StatelessWidget {
  const UpdateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final t = state.t;
    final gate = state.appGate;
    final installed = state.appVersion.split(' ').first;
    final minimum = gate?.minimumVersion;

    return _GatePanel(
      key: const ValueKey('update-screen'),
      mark: SpinningChip(
        colour: AppTheme.gold,
        size: 54,
        turn: const Duration(milliseconds: 1100),
        rest: const Duration(milliseconds: 900),
      ),
      title: t.updateTitle,
      body: gate?.message ?? t.updateBody,
      action: GlassButton(
        key: const ValueKey('update-now'),
        style: GlassButtonStyle.primary,
        expand: true,
        minimumSize: const Size.fromHeight(52),
        onPressed: state.updating ? null : state.startUpdate,
        child: state.updating
            ? const _Working()
            : Text(t.updateNow, textAlign: TextAlign.center),
      ),
      footnote: installed.isNotEmpty && minimum != null
          ? t.updateVersionLine(installed, '$minimum')
          : state.appVersion,
    );
  }
}

/// Maintenance: the server says the game is closed for this platform (the
/// app version gate). Not an update — nothing about this build is wrong — so
/// it says so, shows the operator's message when there is one, and offers
/// Try again, which asks the server afresh and, the game open again, takes
/// the player back where they were ([GameState.retryAppGate]).
class MaintenanceScreen extends StatelessWidget {
  const MaintenanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final t = state.t;
    final theme = Theme.of(context);

    return _GatePanel(
      key: const ValueKey('maintenance-screen'),
      mark: Container(
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppTheme.gold.withValues(alpha: 0.16),
          border: Border.all(color: AppTheme.gold.withValues(alpha: 0.55)),
        ),
        child: Icon(
          Icons.construction_rounded,
          size: 28,
          color: theme.brightness == Brightness.dark
              ? AppTheme.gold
              : AppTheme.goldDeep,
        ),
      ),
      title: t.maintenanceTitle,
      body: state.appGate?.message ?? t.maintenanceBody,
      action: GlassButton(
        key: const ValueKey('maintenance-retry'),
        style: GlassButtonStyle.primary,
        expand: true,
        minimumSize: const Size.fromHeight(52),
        icon: state.checkingAppGate ? null : const Icon(Icons.refresh_rounded),
        onPressed: state.checkingAppGate ? null : state.retryAppGate,
        child: state.checkingAppGate
            ? const _Working()
            : Text(t.maintenanceRetry, textAlign: TextAlign.center),
      ),
      footnote: state.appVersion,
    );
  }
}

/// The frame both gate screens share — the update screen's own, since
/// before the gate: the room's ground with its drifting chips, and one solid
/// panel. Solid, not glass: the chips drift behind it for as long as it is
/// up, and a filter over a moving backdrop re-blurs on every frame. Scrolls,
/// so three lines of Bengali at the 1.25 text ceiling on a 360dp-tall phone
/// never overflow.
class _GatePanel extends StatelessWidget {
  const _GatePanel({
    super.key,
    required this.mark,
    required this.title,
    required this.body,
    required this.action,
    required this.footnote,
  });

  final Widget mark;
  final String title;
  final String body;
  final Widget action;
  final String footnote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final width = MediaQuery.sizeOf(context).width;

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
                  child: PremiumSurface(
                    accent: AppTheme.gold,
                    child: Padding(
                      padding: const EdgeInsets.all(Space.xxl),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          mark,
                          const SizedBox(height: Space.xl),
                          Text(
                            title,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              color: glass.textDisplay,
                            ),
                          ),
                          const SizedBox(height: Space.md),
                          Text(
                            body,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: glass.textBody,
                            ),
                          ),
                          const SizedBox(height: Space.xl),
                          action,
                          if (footnote.isNotEmpty) ...[
                            const SizedBox(height: Space.lg),
                            Text(
                              footnote,
                              textAlign: TextAlign.center,
                              style: AppTheme.money(
                                theme.textTheme.labelSmall ?? const TextStyle(),
                                weight: FontWeight.w500,
                                colour: glass.textMuted,
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

class _Working extends StatelessWidget {
  const _Working();

  @override
  Widget build(BuildContext context) =>
      GameLoaderRing(size: 20, ink: Theme.of(context).colorScheme.onPrimary);
}

/// Soft Update: a newer version is announced (the server's latest_version,
/// or Play's own report of a newer build) while this one is still supported.
/// A layer over the sign-in screen or the lobby — never over a table — with
/// Update now and Later; Later puts it away until something newer is
/// announced ([GameState.laterSoftUpdate]). The consent panel's shape: a
/// tint, not a blur, and one glass card that takes the blur lease itself.
class SoftUpdatePrompt extends StatelessWidget {
  const SoftUpdatePrompt({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final lang = context.select<GameState, AppLang>((s) => s.lang);
    final updating = context.select<GameState, bool>((s) => s.updating);
    final t = Strings(lang);
    final width = MediaQuery.sizeOf(context).width;
    final state = context.read<GameState>();

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: AppTheme.ground(theme.brightness).withValues(alpha: 0.72),
        ),
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.xl,
              vertical: Space.lg,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: Dim.dialogW(width)),
              // As the consent panel: this layer has no Scaffold above it.
              child: Material(
                type: MaterialType.transparency,
                child: GlassCard(
                  mode: GlassMode.auto,
                  priority: 21,
                  depth: Elevation.overlay,
                  radius: Radii.lg,
                  padding: const EdgeInsets.all(Space.xl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.system_update_rounded,
                            size: 20,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: Space.md),
                          Expanded(
                            child: Text(
                              t.softUpdateTitle,
                              style: AppTheme.label(
                                theme.textTheme.titleMedium ??
                                    const TextStyle(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: Space.md),
                      Text(
                        t.softUpdateBody,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: glass.textBody,
                        ),
                      ),
                      const SizedBox(height: Space.xl),
                      Row(
                        children: [
                          Expanded(
                            child: GlassButton(
                              key: const ValueKey('soft-update-later'),
                              style: GlassButtonStyle.text,
                              minimumSize: const Size.fromHeight(48),
                              label: t.softUpdateLater,
                              onPressed: state.laterSoftUpdate,
                            ),
                          ),
                          const SizedBox(width: Space.md),
                          Expanded(
                            child: GlassButton(
                              key: const ValueKey('soft-update-now'),
                              style: GlassButtonStyle.primary,
                              minimumSize: const Size.fromHeight(48),
                              onPressed: updating ? null : state.startUpdate,
                              child: updating
                                  ? const _Working()
                                  : Text(
                                      t.updateNow,
                                      textAlign: TextAlign.center,
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Whether the soft update prompt belongs on screen now: offered, over the
/// sign-in screen or the lobby only (never a table, a splash or a gate
/// screen), and not while a cold start is still finding its table.
bool softUpdateShown(GameState s) =>
    s.softUpdate?.status == AppGateStatus.softUpdate &&
    (s.screen == Screen.login || s.screen == Screen.lobby) &&
    !s.resuming;
