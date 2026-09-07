import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../state/game_state.dart';

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

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Card(
                margin: const EdgeInsets.symmetric(horizontal: 24),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(32, 28, 32, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                Flexible(
                                  child: RichText(
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    text: TextSpan(
                                      style: theme.textTheme.headlineMedium
                                          ?.copyWith(fontWeight: FontWeight.w800),
                                      children: [
                                        TextSpan(
                                          text: 'King ',
                                          style: TextStyle(color: theme.colorScheme.onSurface),
                                        ),
                                        TextSpan(
                                          text: 'Teen Patti',
                                          style: TextStyle(color: theme.colorScheme.secondary),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                // The game's mark beside its name — the same
                                // artwork as the launcher icon and the splash.
                                SvgPicture.asset(
                                  'assets/app_icon.svg',
                                  width: 40,
                                  height: 40,
                                  semanticsLabel: 'King Teen Patti icon',
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Switch theme',
                            onPressed: state.toggleTheme,
                            icon: Icon(state.themeMode == ThemeMode.dark
                                ? Icons.light_mode_outlined
                                : Icons.dark_mode_outlined),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(t.signInSubtitle, style: theme.textTheme.bodyLarge),
                      const SizedBox(height: 20),
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
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        onPressed: state.busy ? null : () => _signIn(context),
                        icon: state.busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.sports_esports_outlined),
                        label: Text(state.busy ? t.signingIn : t.playAsGuest),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                        ),
                      ),
                      const SizedBox(height: 10),
                      // Google and Facebook are wired on the server; the native
                      // sign-in SDKs are not bundled in this build yet.
                      FilledButton.tonalIcon(
                        onPressed: null,
                        icon: const Icon(Icons.g_mobiledata),
                        label: Text(t.continueGoogle),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                      ),
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        onPressed: null,
                        icon: const Icon(Icons.facebook_outlined),
                        label: Text(t.continueFacebook),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                      ),
                      if (state.loginError != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          state.loginError!,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: theme.colorScheme.error),
                        ),
                      ],
                      const SizedBox(height: 14),
                      // Which build this is, for anyone reporting what they saw.
                      Text(
                        state.appVersion.isEmpty
                            ? t.appVersion
                            : '${t.appVersion} ${state.appVersion}',
                        textAlign: TextAlign.right,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          letterSpacing: 0.3,
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
