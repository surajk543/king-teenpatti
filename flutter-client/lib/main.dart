import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'l10n/strings.dart';
import 'screens/login_screen.dart';
import 'screens/lobby_screen.dart';
import 'screens/table_screen.dart';
import 'models/dtos.dart';
import 'state/game_state.dart';
import 'theme/app_theme.dart';
import 'widgets/poker_chip.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Requirement 23: phones play in landscape only. Both landscape orientations
  // are allowed so the device can be held either way.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  final state = GameState();
  await state.start();

  runApp(
    ChangeNotifierProvider<GameState>.value(value: state, child: const KingTeenPattiApp()),
  );
}

class KingTeenPattiApp extends StatelessWidget {
  const KingTeenPattiApp({super.key});

  @override
  Widget build(BuildContext context) {
    final mode = context.select<GameState, ThemeMode>((s) => s.themeMode);

    return MaterialApp(
      title: 'King Teen Patti',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: mode,
      locale: context.select<GameState, AppLang>((s) => s.lang).locale,
      // The whole app crosses between palettes rather than snapping, which is
      // what makes the toggle feel like one movement.
      themeAnimationDuration: const Duration(milliseconds: 420),
      themeAnimationCurve: Curves.easeOutCubic,
      home: const _Root(),
    );
  }
}

/// Switches between the three screens. There is no navigator: the server drives
/// which screen the player belongs on, and a back gesture should never land
/// them on a table they have left.
class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final screen = context.select<GameState, Screen>((s) => s.screen);
    final resuming = context.select<GameState, bool>((s) => s.resuming);

    return _NoticeHost(
      child: Stack(
        fit: StackFit.expand,
        children: [
          _BackGuard(
            screen: screen,
            child: switch (screen) {
              Screen.login => const LoginScreen(),
              Screen.lobby => const LobbyScreen(),
              Screen.table => const TableScreen(),
            },
          ),
          // On a cold start with a saved session the lobby is ready before the
          // server has said whether the player still has a table. Holding a
          // veil over it for that moment means an app closed mid-hand reopens
          // onto the table, not onto the lobby with the table arriving a beat
          // later.
          IgnorePointer(
            ignoring: !resuming,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 380),
              child: resuming
                  ? const _ResumeVeil(key: ValueKey('resume-veil'))
                  : const SizedBox.shrink(key: ValueKey('no-veil')),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Returning to your table…": what covers the lobby while the server works
/// out where a reopened app belongs.
class _ResumeVeil extends StatelessWidget {
  const _ResumeVeil({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lang = context.select<GameState, AppLang>((s) => s.lang);
    final t = Strings(lang);

    return Material(
      color: theme.colorScheme.surface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SpinningChip(
              colour: theme.colorScheme.primary,
              size: 60,
              turn: const Duration(milliseconds: 900),
              rest: const Duration(milliseconds: 300),
            ),
            const SizedBox(height: 20),
            Text(
              t.resumingTable,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Back never simply drops the player out.
///
/// At a table it offers to leave — the same confirmation the menu gives, since
/// walking out mid-hand costs the stake. Anywhere else it offers to quit. A
/// game where the system back gesture silently closes the app is a game that
/// loses a hand every time someone swipes by accident.
class _BackGuard extends StatelessWidget {
  const _BackGuard({required this.screen, required this.child});

  final Screen screen;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final state = context.read<GameState>();
        final t = state.t;

        // An open drawer — chat, menu, settings, stats — closes first. Back
        // only reaches the leave-or-quit question when nothing is over the
        // screen; otherwise a player closing the chat is asked to leave.
        for (final key in [state.tableScaffold, state.lobbyScaffold]) {
          final scaffold = key.currentState;
          if (scaffold == null) continue;
          if (scaffold.isDrawerOpen) {
            scaffold.closeDrawer();
            return;
          }
          if (scaffold.isEndDrawerOpen) {
            scaffold.closeEndDrawer();
            return;
          }
        }

        if (screen == Screen.table) {
          final room = state.room;
          final midHand = room?.state == TableState.betting &&
              room?.you?.status == SeatState.active;

          final leave = await _ask(
            context,
            icon: Icons.logout,
            title: t.leaveTableQ,
            body: midHand ? t.leaveMidHand : t.leaveAnytime,
            confirm: t.leave,
            cancel: t.stay,
          );
          if (leave == true) state.leaveTable();
          return;
        }

        final quit = await _ask(
          context,
          icon: Icons.exit_to_app,
          title: t.quitGameQ,
          body: t.quitGameBody,
          confirm: t.quit,
          cancel: t.cancel,
        );
        if (quit == true) await SystemNavigator.pop();
      },
      child: child,
    );
  }

  Future<bool?> _ask(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String body,
    required String confirm,
    required String cancel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(icon),
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirm),
          ),
        ],
      ),
    );
  }
}

/// Shows whatever the server last refused, or last granted, as a snack bar.
class _NoticeHost extends StatefulWidget {
  const _NoticeHost({required this.child});
  final Widget child;

  @override
  State<_NoticeHost> createState() => _NoticeHostState();
}

class _NoticeHostState extends State<_NoticeHost> {
  String? _shown;

  @override
  Widget build(BuildContext context) {
    final notice = context.select<GameState, String?>((s) => s.notice);

    if (notice != null && notice != _shown) {
      _shown = notice;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            content: Text(notice),
            behavior: SnackBarBehavior.floating,
            width: 420,
          ));
        context.read<GameState>().clearNotice();
        _shown = null;
      });
    }

    return widget.child;
  }
}
