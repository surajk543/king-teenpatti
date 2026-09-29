import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/game_state.dart';
import 'table_tax.dart' show BadgeArt;

/// The badge the player holds, worn on the top-right of their picture in the
/// lobby's top bar and in the Settings drawer (owner, 29 Sep 2026: "Remove
/// the badge and level symbol and tax text from card … instead add a badge on
/// profile pic top right lobby", "In settings profile also u need to add
/// badge") — where the Seen, Blind and Variation cards, and every table card,
/// carried it with the level's mark and the rate until then.
///
/// Which badge is [User.shownBadge]: the one that brings the player's winning
/// tax lowest (Regular for everybody, a Royal badge where one runs), in its
/// own art ([BadgeArt], the Lottie the level screen plays). No level mark and
/// no rate: the level is the line under the name, the rate the level screen's.
/// With no badge (a server from before badges) it draws nothing.
///
/// It takes no layout and no taps: the picture's box is exactly what it was,
/// and a tap on the badge is a tap on the picture. The top bar watches
/// GameState, so it is handed a new [AvatarBadge] every second; it `select`s
/// only its own figures and hands back the SAME subtree while they and its
/// size hold, so the one-second tick never rebuilds the Lottie below it —
/// the level screen's rule, held by `level_screen_test` with the lobby
/// behind it.
class AvatarBadge extends StatefulWidget {
  const AvatarBadge({super.key, required this.size});

  /// The art's side. The owner's badge Lotties draw their emblem in the middle
  /// of a square canvas with clear room round it, so the emblem a player sees
  /// is about [emblemShare] of this.
  final double size;

  /// How much of the art's side its emblem takes.
  static const double emblemShare = 0.5;

  /// The art's side on a picture of [diameter]: an emblem a little larger
  /// than the edit mark at the picture's foot (0.34 of the diameter), so the
  /// badge reads as the more important of the two. At 0.84 the Regular
  /// rosette's ribbons reached the name beside the picture on a 640dp phone.
  static double sizeFor(double diameter) => diameter * 0.74;

  /// Where the art's middle stands on a picture of [diameter], from its
  /// top-left: on the rim at the picture's top-right, so the emblem covers
  /// the edge of the picture rather than its face, and ends at the picture's
  /// right edge rather than past it, towards the name.
  static Offset centreFor(double diameter) =>
      Offset(diameter * 0.82, diameter * 0.17);

  @override
  State<AvatarBadge> createState() => _AvatarBadgeState();
}

class _AvatarBadgeState extends State<AvatarBadge> {
  /// What [_built] was built from.
  (_BadgeView, double)? _inputs;
  Widget? _built;

  @override
  Widget build(BuildContext context) {
    final view = context.select<GameState, _BadgeView?>(_BadgeView.of);
    if (view == null) return const SizedBox.shrink();
    final inputs = (view, widget.size);
    if (_inputs != inputs || _built == null) {
      _inputs = inputs;
      _built = Semantics(
        label: Strings(view.lang).avatarBadgeSemantics(view.title),
        excludeSemantics: true,
        child: SizedBox.square(
          key: const ValueKey('avatar-badge'),
          dimension: widget.size,
          child: BadgeArt(
            size: widget.size,
            icon: view.icon,
            assetUrl: view.assetUrl,
            assetFormat: view.assetFormat,
            label: view.title,
          ),
        ),
      );
    }
    return _built!;
  }
}

/// What [AvatarBadge] draws from, compared field by field so a fresh copy of
/// the same account rebuilds nothing.
@immutable
class _BadgeView {
  const _BadgeView({
    required this.title,
    required this.icon,
    required this.assetUrl,
    required this.assetFormat,
    required this.lang,
  });

  final String title;
  final String icon;
  final String assetUrl;
  final String assetFormat;
  final AppLang lang;

  static _BadgeView? of(GameState s) {
    final badge = s.user?.shownBadge;
    if (badge == null) return null;
    return _BadgeView(
      title: badge.title,
      icon: badge.icon,
      assetUrl: badge.assetUrl,
      assetFormat: badge.assetFormat,
      lang: s.lang,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _BadgeView &&
      other.title == title &&
      other.icon == icon &&
      other.assetUrl == assetUrl &&
      other.assetFormat == assetFormat &&
      other.lang == lang;

  @override
  int get hashCode => Object.hash(title, icon, assetUrl, assetFormat, lang);
}
