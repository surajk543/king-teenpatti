import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/table_theme.dart';
import 'table_tax.dart' show BadgeArt;

/// The badge that brings the player's winning tax lowest, in the top-right
/// corner of the lobby's Seen, Blind and Variation cards (owner, 27 Sep 2026:
/// "On Lobby in top right of card show the badge with minimum tax user
/// holding" — "show badge only on seen, blind and variation card"): its own
/// art ([BadgeArt], the Lottie the level screen and the table's tax pill
/// play) over its rate ("20%" for Regular, "0%" for a Royal badge) on the tax's
/// amber pill ([WinningTaxPill]'s look).
///
/// Which badge is [User.shownBadge], the one the table's tax pill shows; the
/// rate is that badge's own. Nothing where the player holds no badge (a
/// server from before badges) or it carries no rate. It takes no taps of its
/// own: a tap on it is a tap on the card.
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

    return Semantics(
      label: t.cardBadgeSemantics(view.title, rate),
      excludeSemantics: true,
      child: Column(
        key: const ValueKey('lobby-card-badge'),
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: artSize,
            height: artSize * (1 - LobbyCardBadge.tuck),
            child: OverflowBox(
              maxHeight: artSize,
              alignment: Alignment.topCenter,
              child: BadgeArt(
                size: artSize,
                icon: view.icon,
                assetUrl: view.assetUrl,
                assetFormat: view.assetFormat,
                label: view.title,
              ),
            ),
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
    required this.title,
    required this.icon,
    required this.assetUrl,
    required this.assetFormat,
    required this.taxBps,
    required this.lang,
  });

  final String title;
  final String icon;
  final String assetUrl;
  final String assetFormat;
  final int taxBps;
  final AppLang lang;

  static _BadgeView? of(GameState s) {
    final badge = s.user?.shownBadge;
    final bps = badge?.taxBps;
    if (badge == null || bps == null) return null;
    return _BadgeView(
      title: badge.title,
      icon: badge.icon,
      assetUrl: badge.assetUrl,
      assetFormat: badge.assetFormat,
      taxBps: bps,
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
      other.taxBps == taxBps &&
      other.lang == lang;

  @override
  int get hashCode =>
      Object.hash(title, icon, assetUrl, assetFormat, taxBps, lang);
}
