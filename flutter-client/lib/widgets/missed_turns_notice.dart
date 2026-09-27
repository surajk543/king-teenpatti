import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../theme/app_theme.dart';
import '../theme/table_theme.dart';
import 'table_chrome.dart' show Plate;

/// What the table says to a player who has missed turns (requirement 31;
/// owner, 27 Sep 2026: "warn before the kick"): [title] is what happened,
/// [detail] how much of the table's allowance is gone — or, one missed turn
/// short of being shown out, [last] is true and the pair is the last warning.
typedef MissedTurnsWarning = ({String title, String detail, bool last});

/// The warning for [you], or null when there is nothing to warn about.
///
/// Driven by the server alone: `you.missedTurns` and `you.maxMissedTurns` are
/// in every snapshot sent to this player, so the warning appears with the
/// snapshot that counted the miss and goes with the one that cleared it —
/// after any move, a sideshow answered, the variation or the 5-Card three
/// chosen — whatever this phone saw in between (a reconnect included). A table
/// that never shows anybody out (`maxMissedTurns` 0) has nothing to warn of.
///
/// [poker] words it for a poker room, where the clock checks when a check is
/// free and stands pat on the draw — a miss that packs nothing; [folded] is a
/// poker hand the clock folded this hand, said as such.
MissedTurnsWarning? missedTurnsWarning(
  You? you,
  Strings t, {
  bool poker = false,
  bool folded = false,
}) {
  if (you == null || you.missedTurns <= 0 || you.maxMissedTurns <= 0) {
    return null;
  }
  if (you.onLastWarning) {
    return (title: t.lastWarning, detail: t.missOneMore, last: true);
  }
  final title = !poker
      ? t.autoPacked
      : folded
      ? t.pokerTimedOut
      : t.missedYourTurn;
  return (
    title: title,
    detail: t.missedTurnsCount(you.missedTurns, you.maxMissedTurns),
    last: false,
  );
}

/// The warning on the felt: a small charcoal plate in the table's status
/// slot, the title over the count (or the last warning over what happens
/// next).
///
/// On a plate rather than bare on the cloth so the amber and the red read the
/// same on every cloth in both themes (≥4.5:1 on charcoal). Measured at
/// [wrapFactor] times the width it is given, so a long title breaks into two
/// lines before the whole plate is scaled down to the slot — and never taller
/// than [maxHeight], which the felt sets to the room between the slot and the
/// pot, so it can never reach the pot, the keys or the viewer's cards. It
/// takes no taps.
class MissedTurnsNotice extends StatelessWidget {
  const MissedTurnsNotice({
    super.key,
    required this.warning,
    this.maxHeight = double.infinity,
    this.wrapFactor = 1.35,
  });

  final MissedTurnsWarning warning;
  final double maxHeight;
  final double wrapFactor;

  /// The title's ink on the charcoal plate: the winning tax's amber for a
  /// warning (9.4:1), the alarm red for the last one (6.5:1).
  static Color titleInk(bool last) => last ? TableInk.alarm : TableInk.tax;

  /// The plate's padding across, each side.
  static const double _padX = Space.md;

  /// How wide to lay the plate out: [base] (the slot's width × [wrapFactor]),
  /// or wider where the title or the detail would otherwise need a third
  /// line and be cut short (Bengali and Punjabi at a narrow phone's larger
  /// text, 27 Sep 2026) — the plate is then scaled down to the slot a little
  /// further instead.
  static double wrapWidthFor(
    double base,
    List<(String, TextStyle)> lines, {
    required TextScaler scaler,
    required TextDirection direction,
  }) {
    const chrome = 2 * _padX + 2 * Dim.hairline;
    var wrap = base;
    for (final (text, style) in lines) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: direction,
        textScaler: scaler,
        textAlign: TextAlign.center,
        maxLines: 2,
      );
      for (var i = 0; i < 12; i++) {
        painter.layout(maxWidth: math.max(0, wrap - chrome));
        if (!painter.didExceedMaxLines) break;
        wrap *= 1.12;
      }
      painter.dispose();
    }
    return wrap;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = titleInk(warning.last);
    final titleStyle = TableType.system(theme, colour: ink, strong: true);
    final detailStyle = TableType.metadata(
      theme,
      colour: AppTheme.boneInk.withValues(alpha: 0.88),
      figures: true,
    );

    final plate = Plate(
      accent: ink.withValues(alpha: 0.55),
      opacity: 0.82,
      padding: const EdgeInsets.symmetric(
        horizontal: _padX,
        vertical: Space.xs,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            warning.title,
            key: const ValueKey('missed-turns-title'),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
          const SizedBox(height: Space.xxs),
          Text(
            warning.detail,
            key: const ValueKey('missed-turns-detail'),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: detailStyle,
          ),
        ],
      ),
    );

    return IgnorePointer(
      child: Semantics(
        liveRegion: true,
        label: '${warning.title}. ${warning.detail}',
        excludeSemantics: true,
        child: LayoutBuilder(
          builder: (context, c) {
            final wrap = c.maxWidth.isFinite
                ? wrapWidthFor(
                    c.maxWidth * wrapFactor,
                    [
                      (warning.title, titleStyle),
                      (warning.detail, detailStyle),
                    ],
                    scaler: MediaQuery.textScalerOf(context),
                    direction: Directionality.of(context),
                  )
                : double.infinity;
            return ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: wrap),
                  child: plate,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
