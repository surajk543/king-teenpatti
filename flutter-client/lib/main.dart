import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'l10n/strings.dart';
import 'screens/login_screen.dart';
import 'screens/splash_screen.dart';
import 'screens/update_screen.dart';
import 'screens/lobby_screen.dart';
import 'screens/table_screen.dart';
import 'models/dtos.dart';
import 'settings/feedback_settings.dart';
import 'state/game_state.dart';
import 'theme/app_theme.dart';
import 'widgets/glass_panels.dart';
import 'widgets/poker_chip.dart';
import 'widgets/premium_surface.dart';

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
  // Separate from GameState on purpose: two booleans that no seat, card or
  // chip should rebuild for. Loaded behind the splash like everything else.
  final feedback = FeedbackSettings();

  // The first frame is the splash; the session check, connection and resume
  // all happen behind it and move the app on when they are done.
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: const KingTeenPattiApp(),
    ),
  );
  unawaited(state.start());
  unawaited(feedback.load());
}

class KingTeenPattiApp extends StatelessWidget {
  const KingTeenPattiApp({super.key});

  @override
  Widget build(BuildContext context) {
    final mode = context.select<GameState, ThemeMode>((s) => s.themeMode);
    final sound = context.select<FeedbackSettings, bool>((f) => f.sound);

    return MaterialApp(
      title: 'King Teen Patti',
      debugShowCheckedModeBanner: false,
      // Rebuilt when the Sound switch moves, which is what carries the
      // setting into Material's own per-button click.
      theme: AppTheme.light(sound: sound),
      darkTheme: AppTheme.dark(sound: sound),
      themeMode: mode,
      locale: context.select<GameState, AppLang>((s) => s.lang).locale,
      // The whole app crosses between palettes rather than snapping, which is
      // what makes the toggle feel like one movement.
      themeAnimationDuration: const Duration(milliseconds: 420),
      themeAnimationCurve: Curves.easeOutCubic,
      // Both of these belong above the root Navigator and the root
      // ScaffoldMessenger, not around `home`: dialogs, the picture sheet, the
      // chip store and every snack bar are built from those, so a wrapper
      // around `home` would miss precisely the surfaces with the least room to
      // give — the store shelf, the rules cards, the toast.
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        // The app is landscape, dense and full of fixed instrument heights.
        // The OS scale reaches 2.0 on Android, which no panel here survives;
        // 1.25 is as far as the type can grow before a card stops fitting.
        minScaleFactor: 0.9,
        maxScaleFactor: 1.25,
        // One blur, app-wide. Whichever panel asks with the highest priority
        // gets it and every other GlassMode.auto surface renders tinted, so
        // opening a dialog over a drawer never stacks two filters.
        child: GlassBudget(child: child ?? const SizedBox.shrink()),
      ),
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
    final resuming = context.select<GameState, bool>(
      (s) => s.resuming && s.screen != Screen.splash,
    );
    // Only over the game itself: the update screen outranks it, and there is
    // nobody to ask on the splash or the sign-in screen.
    final consent = context.select<GameState, bool>(
      (s) =>
          s.consentPending &&
          (s.screen == Screen.lobby || s.screen == Screen.table),
    );

    return _NoticeHost(
      child: Stack(
        fit: StackFit.expand,
        children: [
          _BackGuard(
            screen: screen,
            child: _ScreenFade(
              screen: screen,
              child: switch (screen) {
                Screen.splash => const SplashScreen(),
                Screen.update => const UpdateScreen(),
                Screen.login => const LoginScreen(),
                Screen.lobby => const LobbyScreen(),
                Screen.table => const TableScreen(),
              },
            ),
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
          // Above the resume veil: a player being returned to their table can
          // read and confirm the statement while the table resolves behind it,
          // and the game stays covered until they have.
          IgnorePointer(
            ignoring: !consent,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 380),
              child: consent
                  ? const _ConsentGate(key: ValueKey('consent-gate'))
                  : const SizedBox.shrink(key: ValueKey('no-consent')),
            ),
          ),
        ],
      ),
    );
  }
}

/// The one-time statement that stands between sign-in and the game: the
/// player confirms they expect no money or other enrichment from playing.
///
/// A layer in the root stack rather than a `showDialog` route, so it cannot
/// be dismissed by a tap outside, survives the screen changing underneath it
/// (a table snapshot arriving during a resume), and needs no navigator
/// bookkeeping. The only way past it is the button; back offers to quit the
/// app, as it does anywhere else off the table. Shown once per account on
/// this device ([GameState.consentPending]).
class _ConsentGate extends StatelessWidget {
  const _ConsentGate({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lang = context.select<GameState, AppLang>((s) => s.lang);
    final t = Strings(lang);
    final width = MediaQuery.sizeOf(context).width;

    return Stack(
      fit: StackFit.expand,
      children: [
        // A tint, not a blur: the panel takes the one blur lease itself, and
        // the lobby's drifting chips behind it would re-blur every frame.
        ColoredBox(
          color: AppTheme.ground(theme.brightness).withValues(alpha: 0.72),
        ),
        Center(
          // Scrolls: three lines of Bengali at the 1.25 text-scale ceiling on
          // a 360dp-tall phone is exactly the panel that must not overflow.
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.xl,
              vertical: Space.lg,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: Dim.dialogW(width)),
              child: Material(
                type: MaterialType.transparency,
                child: PremiumGlassPanel(
                  mode: GlassMode.auto,
                  priority: 20,
                  radius: Radii.lg,
                  padding: const EdgeInsets.all(Space.xl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.verified_user_outlined,
                            size: 20,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: Space.md),
                          Expanded(
                            child: Text(
                              t.consentTitle,
                              style: AppTheme.label(
                                theme.textTheme.titleMedium ??
                                    const TextStyle(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: Space.md),
                      // The statement itself, in full ink: it is what the
                      // button below confirms, so it is not to be read as a
                      // caption.
                      Text(
                        t.consentBody,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: Space.md),
                      Text(
                        t.consentNote,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurface.withValues(
                            alpha: AppTheme.inkMed,
                          ),
                        ),
                      ),
                      const SizedBox(height: Space.xl),
                      FilledButton.icon(
                        onPressed: () =>
                            context.read<GameState>().acceptConsent(),
                        icon: const Icon(Icons.check_rounded),
                        label: Text(t.consentAccept),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                        ),
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

/// Every screen resolves out of the room's own charcoal instead of appearing
/// in one frame.
///
/// It is a veil clearing over the incoming screen rather than a cross-fade,
/// because a cross-fade keeps both screens mounted for its duration and both
/// hold a `GlobalKey<ScaffoldState>` off [GameState]: two live table screens
/// inside one 300 ms window is a duplicate-key crash, and a stale lobby
/// scaffold would answer [_BackGuard]'s drawer question. One screen is ever
/// built. The veil is the ground colour, so the lobby never flashes a bright
/// frame on the way to the table.
class _ScreenFade extends StatefulWidget {
  const _ScreenFade({required this.screen, required this.child});

  final Screen screen;
  final Widget child;

  @override
  State<_ScreenFade> createState() => _ScreenFadeState();
}

class _ScreenFadeState extends State<_ScreenFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.slow,
    // Settled: the first screen is already here and has nothing to clear.
    value: 1,
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _c,
    curve: Motion.emphasized,
  );
  late final Animation<double> _veil = ReverseAnimation(_curve);

  @override
  void didUpdateWidget(covariant _ScreenFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.screen != widget.screen) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _curve.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        IgnorePointer(
          // The veil is a full-screen layer animating for 300 ms over a screen
          // that is already busy building itself.
          child: RepaintBoundary(
            child: FadeTransition(
              opacity: _veil,
              child: ColoredBox(
                color: AppTheme.ground(Theme.of(context).brightness),
              ),
            ),
          ),
        ),
      ],
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

    return Stack(
      fit: StackFit.expand,
      children: [
        // The one blur outside a modal. It is affordable because it is on
        // screen for under two seconds, nothing behind it can be touched, and
        // it is doing real work: the lobby the player is not going back to
        // goes out of focus while the table resolves.
        BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: ColoredBox(
            color: AppTheme.ground(theme.brightness).withValues(alpha: 0.72),
          ),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SpinningChip(
                colour: AppTheme.gold,
                size: 56,
                turn: const Duration(milliseconds: 900),
                rest: const Duration(milliseconds: 300),
              ),
              const SizedBox(height: Space.xl),
              Text(
                t.resumingTable,
                textAlign: TextAlign.center,
                // label, not smallCaps: this line is translated, and tracked
                // capitals do nothing to Devanagari but stretch it.
                style: AppTheme.label(
                  theme.textTheme.titleSmall ?? const TextStyle(),
                  colour: theme.colorScheme.onSurface.withValues(
                    alpha: AppTheme.inkMed,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
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
          final midHand =
              room?.state == TableState.betting &&
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
    final theme = Theme.of(context);

    return showDialog<bool>(
      context: context,
      builder: (context) => GlassDialog(
        padding: const EdgeInsets.all(Space.xl),
        title: Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: Space.md),
            Expanded(
              child: Text(
                title,
                style: AppTheme.label(
                  theme.textTheme.titleMedium ?? const TextStyle(),
                ),
              ),
            ),
          ],
        ),
        content: Text(
          body,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(
              alpha: AppTheme.inkMed,
            ),
          ),
        ),
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
          // Tone stays neutral: `notice` is one string with no severity beside
          // it, and colouring a refusal red by guessing at its wording would
          // be wrong in five languages.
          ..showSnackBar(
            NoticeToast.snackBar(context, message: _readable(context, notice)),
          );
        context.read<GameState>().clearNotice();
        _shown = null;
      });
    }

    return widget.child;
  }
}

/// Turns anything machine-shaped into one sentence a player can act on.
///
/// Notices come from a lot of places, and some of them carry whatever the
/// platform threw — a WebSocketException still holding the socket.io URL, its
/// port and its query string was reaching the toast verbatim. That tells a
/// player nothing they can use and tells everyone else more about the backend
/// than they need to know.
///
/// Written as a filter at the point of DISPLAY rather than as a fix to the one
/// string that leaked, so the next exception to find its way into a notice is
/// caught too. Anything that reads as a message for a person is passed through
/// untouched: refusals from the server ("This table is full") are the ones
/// worth showing, and they are the majority.
String _readable(BuildContext context, String notice) {
  const machine = [
    'Exception',
    'Error:',
    'socket.io',
    'http://',
    'https://',
    'EIO=',
    'errno',
    'SocketException',
    'HandshakeException',
    'Failed host lookup',
    // Not machine text, but the same news by another route: the server could
    // not be reached. One sentence for one condition, however it arrived.
    'Could not reach',
  ];
  final leaks = machine.any(notice.contains);
  if (!leaks) return notice;
  return context.read<GameState>().t.serviceUnavailable;
}
