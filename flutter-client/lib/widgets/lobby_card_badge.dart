import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/table_theme.dart';
import 'table_tax.dart' show BadgeArt;

/// The player's standing in the top-right corner of the lobby's Seen, Blind
/// and Variation cards (owner, 27 Sep 2026: "On Lobby in top right of card
/// show the badge with minimum tax user holding" — "show badge only on seen,
/// blind and variation card" — and the same day: "on top right also show
/// player level icon along with badge and under that show tax percentage
/// minimum of badge or level"): the player's level mark (its emoji, "🌟"),
/// then the badge that brings their rate lowest in its own art ([BadgeArt],
/// the Lottie the level screen and the table's tax pill play), and under both
/// the winning tax they actually pay — the lower of the level's rate and the
/// badge's ([rateOf]) — on the tax's amber pill ([WinningTaxPill]'s look).
///
/// Which badge is [User.shownBadge], the one the table's tax pill shows. With
/// no badge (a server from before badges) the level and its rate stand alone;
/// with neither, or no rate at all, nothing. It takes no taps of its own: a tap
/// on it is a tap on the card.
///
/// The card it stands on watches GameState, so it is handed a new
/// [LobbyCardBadge] every second; it `select`s only its own figures and hands
/// back the SAME subtree while they, its size and the theme's brightness are
/// unchanged, so the one-second tick never rebuilds the art (a Lottie) below
/// it — the level screen's rule, held by `level_screen_test` with the lobby
/// behind it.
class LobbyCardBadge extends StatefulWidget {
  const LobbyCardBadge({super.key, required this.artSize});

  /// The art's side; the rate's type follows it.
  final double artSize;

  /// The rate's type size for [artSize], before the phone's text scale.
  static double rateSizeFor(double artSize) => (artSize * 0.3).clamp(9.5, 13.0);

  /// How much of the art's foot the rate's pill lies over: the owner's badge
  /// Lotties draw their emblem in the middle of a square canvas with clear
  /// room round it, so the pill tucks into that room rather than standing a
  /// whole canvas below the emblem.
  static const double tuck = 0.2;

  /// The level mark's size (the emoji's), as a share of [artSize]: about
  /// the badge emblem's own size inside its canvas, so the two read as a
  /// pair.
  static const double levelShare = 0.5;

  /// The rate the corner shows: what the player pays, the lower of the
  /// level's rate and the badge's — the server's own figure
  /// ([User.taxBps]) where it sent one, which is exactly that lower rate
  /// over every badge still running; else the lower of the two here. Null
  /// where neither is known.
  static int? rateOf(User user) {
    final server = user.taxBps;
    if (server != null) return server;
    final level = user.playerLevel?.taxBps;
    final badge = user.shownBadge?.taxBps;
    if (level == null) return badge;
    if (badge == null) return level;
    return level < badge ? level : badge;
  }

  @override
  State<LobbyCardBadge> createState() => _LobbyCardBadgeState();
}

class _LobbyCardBadgeState extends State<LobbyCardBadge> {
  /// What [_built] was built from.
  (_BadgeView, double, Brightness)? _inputs;
  Widget? _built;

  @override
  Widget build(BuildContext context) {
    final view = context.select<GameState, _BadgeView?>(_BadgeView.of);
    if (view == null) return const SizedBox.shrink();
    final brightness = Theme.of(context).brightness;
    final inputs = (view, widget.artSize, brightness);
    if (_inputs != inputs || _built == null) {
      _inputs = inputs;
      _built = _compose(context, view, widget.artSize, brightness);
    }
    return _built!;
  }

  Widget _compose(
    BuildContext context,
    _BadgeView view,
    double artSize,
    Brightness brightness,
  ) {
    final theme = Theme.of(context);
    final dark = brightness == Brightness.dark;
    final ink = TableInk.taxOn(brightness);
    final rate = formatTaxRate(view.taxBps);
    final fontSize = LobbyCardBadge.rateSizeFor(artSize);
    final t = Strings(view.lang);
    // The mark and the badge's emblem share one line: the art's slot is its
    // canvas less the tuck, the emblem at the canvas's middle, so the mark is
    // centred on that height, not on the slot's.
    final slot = artSize * (1 - LobbyCardBadge.tuck);
    final glyph = artSize * LobbyCardBadge.levelShare;
    final said = [
      if (view.level != null) t.levelNumber(view.level!),
      if (view.badgeTitle != null)
        t.cardBadgeSemantics(view.badgeTitle!, rate)
      else
        t.cardRateSemantics(rate),
    ].join(', ');

    return Semantics(
      label: said,
      excludeSemantics: true,
      child: Column(
        key: const ValueKey('lobby-card-badge'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (view.levelIcon.isNotEmpty)
                SizedBox(
                  height: view.badgeTitle == null ? glyph : slot,
                  child: Padding(
                    // Beside the badge, the mark's middle on the emblem's.
                    padding: EdgeInsets.only(
                      top: view.badgeTitle == null ? 0 : (artSize - glyph) / 2,
                    ),
                    child: Text(
                      view.levelIcon,
                      key: const ValueKey('lobby-card-level'),
                      maxLines: 1,
                      softWrap: false,
                      textScaler: TextScaler.noScaling,
                      style: TextStyle(fontSize: glyph, height: 1),
                    ),
                  ),
                ),
              if (view.levelIcon.isNotEmpty && view.badgeTitle != null)
                SizedBox(width: artSize * 0.04),
              if (view.badgeTitle != null)
                SizedBox(
                  width: artSize,
                  height: slot,
                  child: OverflowBox(
                    maxHeight: artSize,
                    alignment: Alignment.topCenter,
                    child: BadgeArt(
                      size: artSize,
                      icon: view.badgeIcon,
                      assetUrl: view.assetUrl,
                      assetFormat: view.assetFormat,
                      label: view.badgeTitle!,
                    ),
                  ),
                ),
            ],
          ),
          Container(
            key: const ValueKey('lobby-card-badge-rate'),
            padding: EdgeInsets.symmetric(
              horizontal: fontSize * 0.4,
              vertical: 1.5,
            ),
            decoration: BoxDecoration(
              color: ink.withValues(alpha: dark ? 0.14 : 0.10),
              borderRadius: BorderRadius.circular(Radii.xs),
              border: Border.all(
                color: ink.withValues(alpha: dark ? 0.55 : 0.45),
              ),
            ),
            child: Text(
              rate,
              maxLines: 1,
              softWrap: false,
              style: AppTheme.money(
                theme.textTheme.labelSmall!,
                colour: ink,
                weight: FontWeight.w700,
              ).copyWith(fontSize: fontSize, height: 1.1),
            ),
          ),
        ],
      ),
    );
  }
}

/// What [LobbyCardBadge] draws from, compared field by field so a fresh copy
/// of the same account rebuilds nothing.
@immutable
class _BadgeView {
  const _BadgeView({
    required this.level,
    required this.levelIcon,
    required this.badgeTitle,
    required this.badgeIcon,
    required this.assetUrl,
    required this.assetFormat,
    required this.taxBps,
    required this.lang,
  });

  /// The player's level and its mark ("" for none).
  final int? level;
  final String levelIcon;

  /// The badge shown, null for none.
  final String? badgeTitle;
  final String badgeIcon;
  final String assetUrl;
  final String assetFormat;

  /// What the player pays ([LobbyCardBadge.rateOf]).
  final int taxBps;
  final AppLang lang;

  static _BadgeView? of(GameState s) {
    final user = s.user;
    if (user == null) return null;
    final level = user.playerLevel;
    final shown = user.shownBadge;
    final badge = shown?.taxBps == null ? null : shown;
    final rate = LobbyCardBadge.rateOf(user);
    if (rate == null || (badge == null && level == null)) return null;
    return _BadgeView(
      level: level?.level,
      levelIcon: level?.icon ?? '',
      badgeTitle: badge?.title,
      badgeIcon: badge?.icon ?? '',
      assetUrl: badge?.assetUrl ?? '',
      assetFormat: badge?.assetFormat ?? '',
      taxBps: rate,
      lang: s.lang,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _BadgeView &&
      other.level == level &&
      other.levelIcon == levelIcon &&
      other.badgeTitle == badgeTitle &&
      other.badgeIcon == badgeIcon &&
      other.assetUrl == assetUrl &&
      other.assetFormat == assetFormat &&
      other.taxBps == taxBps &&
      other.lang == lang;

  @override
  int get hashCode => Object.hash(
    level,
    levelIcon,
    badgeTitle,
    badgeIcon,
    assetUrl,
    assetFormat,
    taxBps,
    lang,
  );
}
