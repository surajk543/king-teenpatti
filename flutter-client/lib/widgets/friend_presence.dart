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
/// and while they play, "Playing now" and the game on a small chip of the
/// game's own colour under it ([PlayingChip]). Never where they sit, never
/// what they hold.
///
/// Its depth (owner, 28 Sep 2026: "add DEPTH and subtle visual hierarchy"):
/// the lit dot is set into its surface with a bezel and a halo; the game a
/// friend is at stands on the chip, a step above the row, while "Online" and
/// "Offline" stay flat metadata.
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
    // The dot stands on the middle of the first line, where "Online" is, when
    // the words take a second one (Hindi at text x1.25 does).
    final firstLine =
        MediaQuery.textScalerOf(context).scale(small.fontSize ?? 12) *
        (small.height ?? 1.2);

    Widget status({required bool withPlaying}) => Row(
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
                if (withPlaying) ...[
                  TextSpan(
                    text: '  ·  ',
                    style: small.copyWith(color: glass.cardMuted),
                  ),
                  TextSpan(
                    text: t.playingNow,
                    style: PlayingChip.leadStyle(
                      small,
                      PlayingChip.paletteOf(theme.colorScheme, presence),
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
    );

    if (!presence.isPlaying) return status(withPlaying: false);
    return LayoutBuilder(
      builder: (context, box) {
        // "Playing now" rides on the chip with the game where the two share
        // one line of it; where they would not (a 640dp phone at x1.25), it
        // keeps its place on the status line, as it always stood, and the
        // chip carries the game alone — so a playing friend's row is never a
        // line taller than it was.
        final together = PlayingChip.fitsTogether(
          context,
          t,
          game,
          box.maxWidth,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            status(withPlaying: !together),
            // The line under the status as close as it stood before the
            // chip: the chip's own edge parts them.
            const SizedBox(height: Space.xxs),
            PlayingChip(t: t, presence: presence, game: game, lead: together),
          ],
        );
      },
    );
  }
}

/// "Playing now" and the game a friend is at — "Teen Patti • Seen", "Poker •
/// Texas Hold'em" — as a small chip standing on the row: the well a thing
/// set on a pane is made of, washed with the game's own colour (its lobby
/// card's and its table's, [AppTheme.paletteFor]: gold for Seen, sapphire for
/// Blind, violet for Variation, teal for poker), lit along its top, edged in
/// the colour and casting a contact shadow ([GlassColors.nestedShadow]).
///
/// "Playing now" leads in the colour's ink; the game follows a step quieter.
/// Without [lead] the chip carries the game alone, "Playing now" standing on
/// the status line above it ([FriendPresenceLines]).
class PlayingChip extends StatelessWidget {
  const PlayingChip({
    super.key = const ValueKey('friend-playing'),
    required this.t,
    required this.presence,
    required this.game,
    this.lead = true,
  });

  final Strings t;
  final FriendPresence presence;

  /// [presenceGameLine]'s words for where they are; null to say only
  /// "Playing now".
  final String? game;

  /// Whether "Playing now" is written on the chip, before the game.
  final bool lead;

  /// How much smaller the game is set than "Playing now": a half step.
  static const double gameStep = 0.5;

  /// How strongly the chip's hairline is drawn in the game's colour.
  static const double edgeAlpha = 0.36;

  /// The chip's inset round its words.
  static const EdgeInsets padding = EdgeInsets.symmetric(
    horizontal: Space.sm,
    vertical: Space.xxs,
  );

  /// "Playing now" in the game's ink, a step bolder than the game.
  static TextStyle leadStyle(TextStyle small, TablePalette palette) =>
      AppTheme.label(small, colour: palette.ink, weight: FontWeight.w700);

  /// The game, a half step under "Playing now", in the body's ink.
  static TextStyle gameStyle(TextStyle small, GlassColors glass) =>
      small.copyWith(
        color: glass.textBody,
        fontWeight: FontWeight.w500,
        fontSize: (small.fontSize ?? 12) - gameStep,
      );

  /// Whether "Playing now" and [game] share one line of a chip no wider than
  /// [width], at the phone's text size, in the words' own fonts.
  static bool fitsTogether(
    BuildContext context,
    Strings t,
    String? game,
    double width,
  ) {
    if (game == null || !width.isFinite) return true;
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall!;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    double measure(String words, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: words, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final w = painter.width;
      painter.dispose();
      return w;
    }

    // Any palette: every game's lead is the same face and weight.
    final palette = AppTheme.paletteFor(
      theme.colorScheme,
      category: 'seen',
      bootAmount: 0,
    );
    final need =
        measure(t.playingNow, leadStyle(small, palette)) +
        Space.sm +
        measure(game, gameStyle(small, GlassColors.of(context))) +
        padding.horizontal +
        2 * Dim.hairline;
    // A pixel to spare, for rounding.
    return need + 1 <= width;
  }

  /// The palette of the game [presence] names: its category's, or — with no
  /// category — the engine's (poker's teal; anything else the Seen table's
  /// gold, as the lobby draws a category it does not know).
  static TablePalette paletteOf(ColorScheme scheme, FriendPresence presence) {
    final variant = presence.variant?.toLowerCase();
    final category =
        variant ?? (presence.game == PresenceGame.poker ? 'poker' : 'seen');
    return AppTheme.paletteFor(scheme, category: category, bootAmount: 0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final palette = paletteOf(theme.colorScheme, presence);
    final small = theme.textTheme.bodySmall!;
    final body = Color.alphaBlend(
      palette.accent.withValues(alpha: glass.chipTint),
      glass.wellFill,
    );
    final words = game;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.sm),
        // Lit along its top, as every pane in the app is.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.alphaBlend(glass.highlight, body), body],
          stops: const [0, 0.55],
        ),
        border: Border.all(
          color: palette.accent.withValues(alpha: edgeAlpha),
          width: Dim.hairline,
        ),
        boxShadow: glass.nestedShadow,
      ),
      child: Wrap(
        spacing: Space.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (lead || words == null)
            Text(
              t.playingNow,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: leadStyle(small, palette),
            ),
          if (words != null)
            Text(
              words,
              key: const ValueKey('friend-game'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: gameStyle(small, glass),
            ),
        ],
      ),
    );
  }
}

/// The presence dot: green online, grey offline.
///
/// A lit dot is a small bead set into its surface: its green lit from the
/// upper left, a bezel of the surface round it ([Dim.presenceRing],
/// [GlassColors.presenceRing]) and a halo of its own green outside that
/// ([GlassColors.presenceGlow]), all drawn outside its box, so the line keeps
/// its measure. Offline is the plain grey dot it always was — quieter, not
/// dimmed as though something had broken.
class PresenceDot extends StatelessWidget {
  const PresenceDot({super.key, required this.online});

  final bool online;

  static const double size = 8;

  /// How far the bead's lit side is lifted towards white.
  static const double lit = 0.35;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final glass = GlassColors.of(context);
    if (!online) {
      return Container(
        key: const ValueKey('presence-dot-offline'),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: glass.cardMuted,
        ),
      );
    }
    final green = friendsGreen(b);
    return Container(
      key: const ValueKey('presence-dot-online'),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-0.35, -0.4),
          radius: 0.9,
          colors: [Color.lerp(green, Colors.white, lit)!, green],
        ),
        // Painted in order, the halo first: the bezel over it, the bead over
        // both.
        boxShadow: [
          BoxShadow(
            color: green.withValues(alpha: glass.presenceGlow),
            blurRadius: Dim.presenceHalo,
            spreadRadius: Dim.presenceRing,
          ),
          BoxShadow(color: glass.presenceRing, spreadRadius: Dim.presenceRing),
        ],
      ),
    );
  }
}
