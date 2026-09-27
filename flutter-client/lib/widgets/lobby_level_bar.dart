import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import 'glass_components.dart';
import 'level_screen.dart';
import 'table_tax.dart';

/// The player's level at the top of the lobby (owner, 27 Sep 2026: "In the
/// Lobby on Top show current level of player and xp progress bar for next
/// level"): the level's mark and number ("🌟 Lv 10"), a slim gold bar from
/// this level's threshold to the next's, and the figure ("4,180 / 5,200 XP")
/// — or, at the top of the ladder, a full bar and MAX LEVEL.
///
/// It is the second line under the player's name in the lobby's top bar, so
/// it takes no width from the name, the wallets or the keys: the name keeps
/// exactly the room it had. The top bar rebuilds every second for the
/// reward clocks; this is built `const` there and `select`s only the
/// figures it draws, so that tick never reaches it, and the bar ([LevelBar],
/// the level screen's own) animates only when the XP does — a `player:level`
/// push landing while the lobby is open.
///
/// Two rows under the name: the level ("🌟 Lv 10") at the left and the
/// figure at the right, over the bar spanning both. Where the name block is
/// narrow (a 640dp phone keeps the name about a hundred dp) the row gives way
/// a step at a time before any type shrinks: the figure drops its "XP" (the
/// bar under it says what it counts), then the mark goes, then the goal (the
/// bar shows how far is left), then the word for "level" gives way to the
/// number on a gold plate, and only then is the row scaled — so "Lv 10  4,180 / 5,200" stays readable where the whole
/// sentence would have been set in seven-point type.
///
/// The bar waits for the ladder (`GET /api/levels`), which says where this
/// level starts ([levelProgressOf]); until it has been read the row shows the
/// level and the figure alone rather than a bar measured from 0 XP.
///
/// Nothing at all until the account names a level (a server from before
/// levels).
class LobbyLevelBar extends StatelessWidget {
  const LobbyLevelBar({super.key});

  /// The row's type: small, under a titleMedium name.
  static const double fontSize = 10.5;
  static const double lineHeight = 1.15;

  /// The bar's thickness: slim, a line under the words rather than a box.
  static const double barHeight = 4;

  /// Between the words and the bar.
  static const double barGap = 2;

  /// The block never stands wider than this (times the text scale): on a
  /// tablet the name block is half the bar wide, and a bar that long reads as
  /// a divider rather than a gauge.
  static const double maxWidth = 230;

  /// The least room between the level and the figure.
  static const double wordGap = 8;

  /// The block's height at [scaler] — the words' line forced by a strut, so a
  /// mixed-script word ("लेवल 10") or a colour-emoji mark never makes it
  /// taller than the top bar planned for — with the bar under it.
  static double heightFor(TextScaler scaler) =>
      scaler.scale(fontSize) * lineHeight + barGap + barHeight;

  static const StrutStyle _strut = StrutStyle(
    fontSize: fontSize,
    height: lineHeight,
    forceStrutHeight: true,
  );

  /// Builds since start, for the test that holds the one-second tick away.
  @visibleForTesting
  static int builds = 0;

  static double _width(InlineSpan span, TextScaler scaler) {
    final painter = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final w = painter.width;
    painter.dispose();
    return w;
  }

  @override
  Widget build(BuildContext context) {
    builds++;
    final view = context.select<GameState, _LevelBarView?>(_LevelBarView.of);
    if (view == null) return const SizedBox.shrink();
    final t = Strings(view.lang);
    final theme = Theme.of(context);
    final gold = AppTheme.goldInk(theme.brightness);
    final base = DefaultTextStyle.of(context).style.merge(
      theme.textTheme.labelSmall!.copyWith(
        fontSize: fontSize,
        height: lineHeight,
      ),
    );
    final tagStyle = AppTheme.money(base, colour: gold);
    final figureStyle = AppTheme.money(
      base,
      colour: gold,
      weight: FontWeight.w600,
    );

    final next = view.nextMinXp;
    final fraction = levelFractionOf(
      xp: view.xp,
      nextMinXp: next,
      fromXp: view.fromXp,
    );
    final xp = formatChips(view.xp);
    final max = next == null ? null : formatChips(next);
    final label = max == null
        ? t.levelBarTopSemantics(view.level, xp)
        : t.levelBarSemantics(view.level, xp, max);

    // The words, fullest first: each how the level is named and the figure.
    final word = t.levelShort(view.level);
    final mark = view.icon;
    final hasMark = mark.isNotEmpty;
    final candidates = <(_Tag, String)>[
      (
        hasMark ? _Tag.marked : _Tag.word,
        max == null ? t.levelMax : t.xpOf(xp, max),
      ),
      if (max != null) (hasMark ? _Tag.marked : _Tag.word, '$xp / $max'),
      if (hasMark) (_Tag.word, max == null ? t.levelMax : '$xp / $max'),
      // The narrowest bars (a 592dp phone at the text ceiling leaves the
      // name block some seventy dp): the XP alone, the bar showing how far
      // it has to go — and at the top the level over its full bar, which
      // says MAX by itself — and then the number alone on a gold plate, the
      // foot's level key's own badge, where a script's word for "level"
      // ("লেভেল") is itself wider than the room.
      (_Tag.word, max == null ? '' : xp),
      (_Tag.badge, max == null ? '' : xp),
    ];
    InlineSpan tagSpan(_Tag kind) => TextSpan(
      style: kind == _Tag.badge
          ? tagStyle.copyWith(color: AppTheme.ink900)
          : tagStyle,
      children: [
        if (kind == _Tag.marked) TextSpan(text: '$mark '),
        TextSpan(text: kind == _Tag.badge ? '${view.level}' : word),
      ],
    );
    const badgePad = 4.0;

    return Semantics(
      key: const ValueKey('lobby-level-bar'),
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: () => openLobbyLevel(context),
      child: LayoutBuilder(
        builder: (context, box) {
          final scaler = MediaQuery.textScalerOf(context);
          final w = math.min(box.maxWidth, scaler.scale(maxWidth));
          var (kind, figure) = candidates.last;
          var fits = false;
          for (final (k, f) in candidates) {
            final need =
                _width(tagSpan(k), scaler) +
                (k == _Tag.badge ? 2 * badgePad : 0) +
                (f.isEmpty
                    ? 0
                    : wordGap +
                          _width(
                            TextSpan(text: f, style: figureStyle),
                            scaler,
                          ));
            if (need <= w) {
              (kind, figure) = (k, f);
              fits = true;
              break;
            }
          }
          final tagText = Text.rich(
            tagSpan(kind),
            key: const ValueKey('lobby-level-tag'),
            maxLines: 1,
            softWrap: false,
            strutStyle: _strut,
          );
          final tag = kind != _Tag.badge
              ? tagText
              : DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppTheme.gold,
                    borderRadius: BorderRadius.circular(Radii.xs),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: badgePad),
                    child: tagText,
                  ),
                );
          final figureText = Text(
            figure,
            key: const ValueKey('lobby-level-xp'),
            maxLines: 1,
            softWrap: false,
            strutStyle: _strut,
            style: figureStyle,
          );
          final words = figure.isEmpty
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: FittedBox(fit: BoxFit.scaleDown, child: tag),
                )
              : fits
              ? Row(children: [tag, const Spacer(), figureText])
              : FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      tag,
                      const SizedBox(width: wordGap),
                      figureText,
                    ],
                  ),
                );
          return SizedBox(
            width: w,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                words,
                if (fraction != null) ...[
                  const SizedBox(height: barGap),
                  // A new level is a new bar: it fills from empty to the new
                  // level's share. Kept, the one bar would tween DOWN from
                  // the old level's fill, which reads as XP being lost.
                  KeyedSubtree(
                    key: ValueKey('lobby-level-run-${view.level}'),
                    child: LevelBar(
                      key: const ValueKey('lobby-level-progress'),
                      fraction: fraction,
                      height: barHeight,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// How the row names the level: its mark and word ("🌟 Lv 10"), the word
/// alone ("Lv 10"), or the number on a gold plate.
enum _Tag { marked, word, badge }

/// Opens the level screen from the lobby's top bar, with the lobby's click.
void openLobbyLevel(BuildContext context) {
  lobbyClick(context);
  showLevelInfo(context);
}

/// What the line draws, as one comparable value: the level, its mark, the
/// XP, the next threshold, this level's own threshold from the ladder, the
/// language and the number system (both change the figures' words). A fresh
/// copy of the same account — every `me()` re-read — compares equal, and the
/// one-second tick changes none of it.
@immutable
class _LevelBarView {
  const _LevelBarView({
    required this.level,
    required this.icon,
    required this.xp,
    required this.nextMinXp,
    required this.fromXp,
    required this.lang,
    required this.numbers,
  });

  final int level;
  final String icon;
  final int xp;
  final int? nextMinXp;
  final int? fromXp;
  final AppLang lang;
  final NumberSystem numbers;

  static _LevelBarView? of(GameState s) {
    final level = s.user?.playerLevel;
    if (level == null) return null;
    return _LevelBarView(
      level: level.level,
      icon: level.icon,
      xp: level.xp,
      nextMinXp: level.next?.minXp,
      fromXp: s.levelLadder?.levelOf(level.level)?.minXp,
      lang: s.lang,
      numbers: s.numbers,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _LevelBarView &&
      other.level == level &&
      other.icon == icon &&
      other.xp == xp &&
      other.nextMinXp == nextMinXp &&
      other.fromXp == fromXp &&
      other.lang == lang &&
      other.numbers == numbers;

  @override
  int get hashCode =>
      Object.hash(level, icon, xp, nextMinXp, fromXp, lang, numbers);
}
