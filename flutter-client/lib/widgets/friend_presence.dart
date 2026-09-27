import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../models/friends.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/theme_colors.dart';
import 'player_profile.dart' show friendsGreen;

// Where a friend is, as the app writes it: the dot, "Online" / "Offline",
// "Playing now" and the game they are at — never which table, never what they
// hold. Shared by the lobby's Friends page and, since 27 Sep 2026, the
// table's own drawer (a tap on the viewer's own pod: their friends, "who all
// are online"; OwnSeatDrawer).

/// "Teen Patti • Seen", "Poker • Texas Hold'em": the game a playing friend is
/// at, in the app's own localized names for its engines and categories. A
/// game or variant this build has never heard of goes by the server's name for
/// it, where the table catalogue gives one ([engineName], [categoryName]),
/// and failing that by its code, tidied. Null while they are not playing.
String? presenceGameLine(
  Strings t,
  FriendPresence presence, {
  String? Function(String engine)? engineName,
  String? Function(String category)? categoryName,
}) {
  if (!presence.isPlaying) return null;
  final game = presence.game;
  final variant = presence.variant;
  final parts = <String>[
    if (game != null)
      switch (game) {
        PresenceGame.teenPatti => friendlyName(t.teenPatti),
        PresenceGame.poker => friendlyName(t.poker),
        _ => engineName?.call(game.toLowerCase()) ?? _tidy(game),
      },
    if (variant != null) _variantName(t, variant, categoryName),
  ];
  return parts.isEmpty ? null : parts.join(' • ');
}

/// "Teen Patti • Seen" for a game and a category as the wire codes them
/// (`teen_patti`, `seen`) — where a filed report was made (the Friends
/// page's Reported tab), in the same words a playing friend's game is
/// written in. Null when neither is known.
String? tableKindLine(
  Strings t,
  String game,
  String category, {
  String? Function(String engine)? engineName,
  String? Function(String category)? categoryName,
}) {
  final parts = <String>[
    if (game.isNotEmpty)
      switch (game.toUpperCase()) {
        PresenceGame.teenPatti => friendlyName(t.teenPatti),
        PresenceGame.poker => friendlyName(t.poker),
        _ => engineName?.call(game.toLowerCase()) ?? _tidy(game),
      },
    if (category.isNotEmpty) _variantName(t, category, categoryName),
  ];
  return parts.isEmpty ? null : parts.join(' • ');
}

String _variantName(
  Strings t,
  String variant,
  String? Function(String category)? categoryName,
) {
  final category = variant.toLowerCase();
  if (TableCategory.isPoker(category)) return t.pokerVariantName(category);
  return switch (category) {
    TableCategory.seen => friendlyName(t.seen),
    TableCategory.blind => friendlyName(t.blind),
    TableCategory.variation => friendlyName(t.variation),
    _ => categoryName?.call(category) ?? _tidy(variant),
  };
}

/// A code as words: `NEW_GAME` → "New Game".
String _tidy(String code) => friendlyName(code.replaceAll('_', ' ').trim());

/// Where a friend is: a dot and a word — green "Online", grey "Offline" —
/// and while they play, "Playing now" and the game under it. Never where
/// they sit, never what they hold.
class FriendPresenceLines extends StatelessWidget {
  const FriendPresenceLines({
    super.key,
    required this.t,
    required this.presence,
  });

  final Strings t;
  final FriendPresence presence;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final b = theme.brightness;
    final glass = GlassColors.of(context);
    final online = presence.isOnline;
    final state = context.read<GameState>();
    final game = presenceGameLine(
      t,
      presence,
      engineName: state.lobbyEngineServerName,
      categoryName: state.lobbyServerName,
    );
    final small = text.bodySmall!;
    // The dot stands on the first line, where "Online" is, when "Playing now"
    // takes a second one (Hindi at text x1.25 does).
    final firstLine =
        MediaQuery.textScalerOf(context).scale(small.fontSize ?? 12) *
        (small.height ?? 1.2);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(
                top: math.max(0.0, (firstLine - PresenceDot.size) / 2),
              ),
              child: PresenceDot(online: online),
            ),
            const SizedBox(width: Space.sm),
            Flexible(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: online ? t.presenceOnline : t.presenceOffline,
                      style: small.copyWith(
                        color: online ? glass.textBody : glass.cardMuted,
                      ),
                    ),
                    if (presence.isPlaying) ...[
                      TextSpan(
                        text: '  ·  ',
                        style: small.copyWith(color: glass.cardMuted),
                      ),
                      TextSpan(
                        text: t.playingNow,
                        style: AppTheme.label(
                          small,
                          colour: AppTheme.goldInk(b),
                          weight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (game != null)
          Padding(
            padding: const EdgeInsets.only(left: PresenceDot.size + Space.sm),
            child: Text(
              game,
              key: const ValueKey('friend-game'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: small.copyWith(color: glass.cardMuted),
            ),
          ),
      ],
    );
  }
}

/// The presence dot: green online, grey offline.
class PresenceDot extends StatelessWidget {
  const PresenceDot({super.key, required this.online});

  final bool online;

  static const double size = 8;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final glass = GlassColors.of(context);
    final colour = online ? friendsGreen(b) : glass.cardMuted;
    return Container(
      key: ValueKey(online ? 'presence-dot-online' : 'presence-dot-offline'),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colour,
        boxShadow: online
            ? [BoxShadow(color: colour.withValues(alpha: 0.5), blurRadius: 4)]
            : null,
      ),
    );
  }
}
