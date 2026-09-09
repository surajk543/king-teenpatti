import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../net/social_sign_in.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../widgets/premium_surface.dart';
import '../widgets/table_ground.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final t = state.t;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final width = MediaQuery.sizeOf(context).width;

    return Scaffold(
      body: LobbyGround(
        child: SafeArea(
          child: Center(
            // The card is content-sized and scrolls: at the 1.25 text-scale
            // ceiling with an error line showing it stands at ~316dp of the
            // 360 a TP_Small has, and a keyboard takes more than that.
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: Space.lg),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: Dim.dialogW(width)),
                child: PremiumGlassPanel(
                  // The only surface on the screen, over a static ground:
                  // the one case where a real blur costs nothing to keep.
                  mode: GlassMode.auto,
                  radius: Radii.lg,
                  padding: const EdgeInsets.all(Space.xl),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          // The game's mark beside its name — the same
                          // artwork as the launcher icon and the splash.
                          SvgPicture.asset(
                            'assets/app_icon.svg',
                            width: 40,
                            height: 40,
                            semanticsLabel: 'King Teen Patti icon',
                          ),
                          const SizedBox(width: Space.md),
                          Expanded(
                            child: RichText(
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              text: TextSpan(
                                style: theme.textTheme.headlineSmall,
                                children: [
                                  TextSpan(
                                    text: 'King ',
                                    style: TextStyle(color: scheme.onSurface),
                                  ),
                                  TextSpan(
                                    text: 'Teen Patti',
                                    style: TextStyle(
                                      // The champagne only reads on charcoal;
                                      // on bone it takes the deep end.
                                      color: theme.brightness == Brightness.dark
                                          ? AppTheme.goldBright
                                          : AppTheme.goldDeep,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: t.switchTheme,
                            onPressed: state.toggleTheme,
                            icon: Icon(
                              state.themeMode == ThemeMode.dark
                                  ? Icons.light_mode_outlined
                                  : Icons.dark_mode_outlined,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: Space.sm),
                      Text(
                        t.signInSubtitle,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurface.withValues(
                            alpha: AppTheme.inkMed,
                          ),
                        ),
                      ),
                      const SizedBox(height: Space.xl),
                      TextField(
                        controller: _name,
                        maxLength: 24,
                        textInputAction: TextInputAction.done,
                        decoration: InputDecoration(
                          labelText: t.displayName,
                          hintText: t.playerHint,
                          counterText: '',
                        ),
                        onSubmitted: (_) => _signIn(context),
                      ),
                      const SizedBox(height: Space.lg),
                      FilledButton.icon(
                        onPressed: state.busy ? null : () => _signIn(context),
                        icon: state.busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.sports_esports_outlined),
                        label: Text(state.busy ? t.signingIn : t.playAsGuest),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                        ),
                      ),
                      const SizedBox(height: Space.md),
                      // Google is always on screen, even in a build that
                      // carries no client id — it says so when tapped
                      // (SignInUnavailable) instead of vanishing. A player who
                      // signed in with Google last week and finds only Guest
                      // today cannot tell a forgotten build flag from a lost
                      // account, and that is the worse failure.
                      _ProviderButton(
                        icon: Icons.g_mobiledata_rounded,
                        label: t.continueGoogle,
                        busy: state.busy,
                        onPressed: () => state.loginWithProvider(
                          'google',
                          SocialSignIn.google,
                        ),
                      ),
                      if (state.loginError != null) ...[
                        const SizedBox(height: Space.md),
                        Text(
                          state.loginError!,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: Space.lg),
                      // Which build this is, for anyone reporting what they saw.
                      Text(
                        state.appVersion.isEmpty
                            ? t.appVersion
                            : '${t.appVersion} ${state.appVersion}',
                        textAlign: TextAlign.right,
                        style: AppTheme.money(
                          theme.textTheme.labelSmall ?? const TextStyle(),
                          weight: FontWeight.w500,
                          colour: scheme.onSurface.withValues(alpha: 0.40),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _signIn(BuildContext context) =>
      context.read<GameState>().loginAsGuest(_name.text);
}

/// One provider button, in the same shape as the guest key above it.
///
/// Outlined rather than filled: guest play is the path most people take, and
/// two more filled buttons would make the screen argue with itself about where
/// to tap.
class _ProviderButton extends StatelessWidget {
  const _ProviderButton({
    required this.icon,
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: busy ? null : onPressed,
    icon: Icon(icon),
    label: Text(label),
    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
  );
}
