import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../settings/feedback_settings.dart';
import '../state/game_state.dart';

/// Plays the lobby's music while the lobby is on screen (owner, 2 Oct 2026:
/// "play when player is in Lobby, when player joins the table, then this
/// sound should be switched off").
///
/// It only says WHEN — [FeedbackSettings.lobbyMusic] plays it, behind the
/// Sound switch. "In the lobby" is the lobby SCREEN: the store, the Friends
/// page, a drawer or a popup opened over it are still the lobby, and the
/// music plays on under them. A table (Teen Patti or poker), the sign-in
/// screen, the splash and the update screens are not; nor is the moment a
/// cold start spends behind its "resuming your table" veil, on its way to a
/// seat. The music is held while the app is not in front and carries on when
/// it is back ([FeedbackSettings.holdMusic]).
class LobbyMusic extends StatefulWidget {
  const LobbyMusic({super.key, required this.child});

  final Widget child;

  @override
  State<LobbyMusic> createState() => _LobbyMusicState();
}

class _LobbyMusicState extends State<LobbyMusic> with WidgetsBindingObserver {
  FeedbackSettings? _feedback;
  bool? _inLobby;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _feedback?.holdMusic(held: false);
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _feedback?.holdMusic(held: true);
      case AppLifecycleState.inactive:
        // A notification shade, a system dialog, the store's purchase sheet:
        // the app is still on screen.
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _feedback?.lobbyMusic(playing: false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inLobby = context.select<GameState, bool>(
      (s) => s.screen == Screen.lobby && !s.resuming,
    );
    final feedback = _feedback = context.read<FeedbackSettings>();
    if (inLobby != _inLobby) {
      _inLobby = inLobby;
      feedback.lobbyMusic(playing: inLobby);
    }
    return widget.child;
  }
}
