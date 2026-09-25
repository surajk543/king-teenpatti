import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import 'avatar.dart';
import 'picture_shelf.dart';
import 'poker_chip.dart';

/// What a prize is called: "10 Lakh chips", "5 diamonds", "4 hammers",
/// "2 missiles", a picture's name, "No prize".
String luckyPrizeLabel(Strings t, LuckyPrize prize) => switch (prize.type) {
  LuckyReward.chips => t.priceIn(
    PictureCurrency.coin,
    formatChips(prize.amount),
  ),
  LuckyReward.diamond => t.priceIn(
    PictureCurrency.diamond,
    formatChips(prize.amount),
  ),
  LuckyReward.hammer => t.priceIn(PictureCurrency.hammer, '${prize.amount}'),
  LuckyReward.missile => t.countMissiles(prize.amount),
  LuckyReward.profilePicture || LuckyReward.tablePicture => prize.pictureName,
  _ => t.luckyNoPrize,
};

/// A prize as its two lines: what leads — the figure, a picture's name, or
/// "No prize" — and what follows it — the wallet's word, what kind of
/// picture, or nothing (26 Sep 2026, the Lucky Draw polish: "Reward amount
/// should be the primary information. Reward type should be secondary").
///
/// The two are cut out of [luckyPrizeLabel], so every language keeps its own
/// sentence and its own grammar — "1 hammer" and "4 hammers", "1 हथौड़ा" and
/// "4 हथौड़े" — with no second set of words to drift from the first. The
/// figure's word runs on to the next space, so a count that carries its
/// classifier keeps it ("4টি" over "হাতুড়ি"). Where the figure cannot be
/// found in the sentence, the sentence leads alone.
({String amount, String unit}) luckyPrizeParts(Strings t, LuckyPrize prize) {
  final phrase = luckyPrizeLabel(t, prize);
  if (prize.isPicture) {
    return (
      amount: phrase,
      unit: prize.type == LuckyReward.profilePicture
          ? t.luckyProfilePicture
          : t.luckyTablePicture,
    );
  }
  final figure = switch (prize.type) {
    LuckyReward.chips || LuckyReward.diamond => formatChips(prize.amount),
    LuckyReward.hammer || LuckyReward.missile => '${prize.amount}',
    _ => null,
  };
  final at = figure == null ? -1 : phrase.indexOf(figure);
  if (at < 0) return (amount: phrase, unit: '');
  var end = at + figure!.length;
  final space = RegExp(r'\s');
  while (end < phrase.length && !space.hasMatch(phrase[end])) {
    end++;
  }
  return (
    amount: phrase.substring(at, end),
    unit: '${phrase.substring(0, at)} ${phrase.substring(end)}'.trim(),
  );
}

/// The ink a prize is written in, the accent of the wallet it fills: gold
/// for chips and pictures, the diamonds' blue, the hammers' copper, the
/// missiles' coral — the store's own inks for each — and a quiet grey for
/// the empty slot (the Lucky Draw polish: "Hammer: warm orange/gold accent.
/// Chips: gold accent. No Prize: neutral muted accent").
Color luckyPrizeInk(LuckyPrize prize, ThemeData theme) {
  final b = theme.brightness;
  return switch (prize.type) {
    LuckyReward.chips ||
    LuckyReward.profilePicture ||
    LuckyReward.tablePicture => AppTheme.goldInk(b),
    LuckyReward.diamond => diamondInkOn(b),
    LuckyReward.hammer => hammerInkOn(b),
    LuckyReward.missile => missileInkOn(b),
    _ => theme.colorScheme.onSurface.withValues(alpha: AppTheme.inkLowOn(b)),
  };
}

/// A prize's mark: the wallet it fills, drawn as the top bar and the store draw
/// that wallet, or the picture itself.
class LuckyPrizeGlyph extends StatelessWidget {
  const LuckyPrizeGlyph({
    super.key,
    required this.prize,
    required this.size,
    this.brightness,
    this.animate = false,
  });

  final LuckyPrize prize;
  final double size;

  /// The ground the mark sits on, when it is not the theme's (the wheel's
  /// ivory badges).
  final Brightness? brightness;

  /// Whether an animated picture plays.
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final b = brightness ?? Theme.of(context).brightness;
    final picture = prize.picture;
    return switch (prize.type) {
      LuckyReward.chips => PokerChip(colour: AppTheme.gold, size: size),
      LuckyReward.diamond => Icon(
        Icons.diamond_rounded,
        size: size,
        color: diamondInkOn(b),
      ),
      LuckyReward.hammer => Icon(
        Icons.hardware,
        size: size,
        color: hammerInkOn(b),
      ),
      LuckyReward.missile => Icon(
        missileIcon,
        size: size,
        color: missileInkOn(b),
      ),
      LuckyReward.profilePicture when picture != null => Avatar(
        url: context.read<GameState>().absoluteUrl(picture.url),
        format: picture.assetFormat,
        fallback: picture.name,
        radius: size / 2,
        animate: animate,
      ),
      LuckyReward.profilePicture => Icon(
        Icons.face_rounded,
        size: size,
        color: AppTheme.goldDeep,
      ),
      LuckyReward.tablePicture => Icon(
        Icons.table_bar_rounded,
        size: size,
        color: b == Brightness.dark ? AppTheme.goldBright : AppTheme.goldDeep,
      ),
      _ => Icon(
        Icons.sentiment_neutral_rounded,
        size: size,
        color: b == Brightness.dark ? Colors.white54 : Colors.black45,
      ),
    };
  }
}

/// The six prizes, two to a row in wheel order — slot 1 and 2, 3 and 4, 5 and
/// 6 — every tile the same height. The slot just won is ringed in gold; while
/// the win is being shown ([showingWin]) the others step back.
class LuckyPrizeGrid extends StatelessWidget {
  const LuckyPrizeGrid({
    super.key,
    required this.slots,
    required this.t,
    this.won,
    this.lit,
    this.showingWin = false,
  });

  final List<LuckySlot> slots;
  final Strings t;

  /// The slot just won; null while none is.
  final int? won;

  /// How far the moment of the win has run ([LuckyPrizeTile.lit]).
  final Animation<double>? lit;

  /// The win is on show: the tiles that did not win are dimmed.
  final bool showingWin;

  @override
  Widget build(BuildContext context) {
    Widget cell(int i) => i < slots.length
        ? LuckyPrizeTile(
            key: ValueKey('lucky-slot-${slots[i].slotNumber}'),
            slot: slots[i],
            t: t,
            won: won == slots[i].slotNumber,
            lit: won == slots[i].slotNumber ? lit : null,
            quiet: showingWin && won != null && won != slots[i].slotNumber,
          )
        : const SizedBox.shrink();
    final rows = (slots.length / 2).ceil().clamp(1, 3);
    return Column(
      children: [
        for (var row = 0; row < rows; row++) ...[
          if (row > 0) const SizedBox(height: Space.sm),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: cell(2 * row)),
                const SizedBox(width: Space.sm),
                Expanded(child: cell(2 * row + 1)),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// One prize (26 Sep 2026, the Lucky Draw polish): its mark in a small well
/// tinted with its wallet's colour, the figure leading in that colour, the
/// wallet's word under it, and the slot's number, quietly, in the corner.
/// The tile itself stays neutral — only the mark and the figure carry the
/// accent, so six tiles never read as six colours.
///
/// The figure and its word stand one over the other where the tile is tall
/// enough for both at the phone's text size, and share a line where it is
/// not; nothing is set smaller to make them fit.
///
/// Won, it is ringed in gold and, for as long as [lit] runs from the stop,
/// swells a little, glows, its mark pops and a shine crosses it once; the
/// ring stays until the next spin. The empty slot, landed on, takes a
/// neutral ring and none of the rest. [quiet] dims a tile that did not win
/// while the win is shown.
class LuckyPrizeTile extends StatelessWidget {
  const LuckyPrizeTile({
    super.key,
    required this.slot,
    required this.t,
    this.won = false,
    this.lit,
    this.quiet = false,
  });

  final LuckySlot slot;
  final Strings t;
  final bool won;
  final Animation<double>? lit;
  final bool quiet;

  /// A rise and a fall over the first [until] of the moment: 0, then 1 at its
  /// middle, then 0 again, and 0 after it.
  static double bump(double v, {double from = 0, double until = 0.5}) {
    final x = ((v - from) / (until - from)).clamp(0.0, 1.0);
    return math.sin(math.pi * x);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final dark = b == Brightness.dark;
    final prize = slot.prize;
    final gold = AppTheme.goldInk(b);
    final radius = BorderRadius.circular(Radii.md);
    // The empty slot, landed on, is ringed in a neutral line and nothing
    // more: where the wheel stopped, not something won.
    final celebrate = won && !prize.isNothing;
    final ring = !won
        ? AppTheme.hairlineColour(b)
        : celebrate
        ? gold
        : theme.colorScheme.onSurface.withValues(alpha: AppTheme.inkLowOn(b));

    final fill = celebrate
        ? Color.alphaBlend(
            AppTheme.gold.withValues(alpha: dark ? 0.16 : 0.10),
            dark ? Colors.white.withValues(alpha: 0.05) : Colors.white,
          )
        : (dark ? Colors.white.withValues(alpha: 0.05) : Colors.white);
    final shadow = AppTheme.shadowFor(b);
    final resting = <BoxShadow>[
      if (!dark) ...[
        BoxShadow(
          color: shadow.withValues(alpha: 0.05),
          blurRadius: 2,
          offset: const Offset(0, 1),
        ),
        BoxShadow(
          color: shadow.withValues(alpha: 0.09),
          blurRadius: 12,
          offset: const Offset(0, 3),
        ),
      ],
    ];

    final content = LayoutBuilder(
      builder: (context, box) => _content(context, box.biggest),
    );

    Widget tile(double swell) => Transform.scale(
      scale: 1 + 0.035 * swell,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: radius,
          border: Border.all(color: ring, width: won ? 2 : Dim.hairline),
          boxShadow: [
            ...resting,
            if (celebrate)
              BoxShadow(
                color: AppTheme.gold.withValues(
                  alpha: (dark ? 0.24 : 0.18) + 0.30 * swell,
                ),
                blurRadius: 18,
                spreadRadius: 0.5,
              ),
          ],
        ),
        child: content,
      ),
    );

    Widget body;
    if (celebrate && lit != null) {
      body = AnimatedBuilder(
        animation: lit!,
        builder: (context, _) {
          final v = lit!.value;
          final shine = ((v - 0.22) / 0.55).clamp(0.0, 1.0);
          return Stack(
            children: [
              Positioned.fill(child: tile(bump(v))),
              if (shine > 0 && shine < 1)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ClipRRect(
                      borderRadius: radius,
                      child: FractionallySizedBox(
                        widthFactor: 0.4,
                        heightFactor: 1,
                        alignment: Alignment(-2.4 + 4.8 * shine, 0),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Colors.white.withValues(alpha: 0),
                                Colors.white.withValues(
                                  alpha: dark ? 0.20 : 0.55,
                                ),
                                Colors.white.withValues(alpha: 0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      );
    } else {
      body = tile(0);
    }

    return Semantics(
      container: true,
      selected: won,
      label: '${slot.slotNumber}. ${luckyPrizeLabel(t, prize)}',
      child: ExcludeSemantics(
        child: AnimatedOpacity(
          opacity: quiet ? 0.5 : 1,
          duration: Motion.base,
          curve: Motion.standard,
          child: body,
        ),
      ),
    );
  }

  Widget _content(BuildContext context, Size size) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final b = theme.brightness;
    final dark = b == Brightness.dark;
    final prize = slot.prize;
    final ink = luckyPrizeInk(prize, theme);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final parts = luckyPrizeParts(t, prize);

    // A tall tile — a tablet's — takes the next step up the type ramp, so
    // the figure still leads a tile three times the size. The empty slot has
    // no figure to lead with, and is the least of the six: its words take
    // the quiet label role, a step above a wallet's word, in its grey.
    final roomy = size.height >= 96;
    final lead = prize.isNothing
        ? AppTheme.label(
            (roomy ? text.titleSmall : text.labelLarge)!,
            colour: ink,
          )
        : prize.isPicture
        ? AppTheme.label(
            (roomy ? text.titleMedium : text.titleSmall)!,
            weight: FontWeight.w700,
          )
        : AppTheme.money(
            (roomy ? text.headlineSmall : text.titleMedium)!,
            colour: ink,
          );
    final follow = AppTheme.label(
      (roomy ? text.labelLarge : text.labelMedium)!,
      colour: theme.colorScheme.onSurface.withValues(alpha: AppTheme.inkMed),
    );
    final number = AppTheme.money(
      text.labelSmall!,
      colour: theme.colorScheme.onSurface.withValues(
        alpha: AppTheme.inkLowOn(b),
      ),
      weight: FontWeight.w600,
    );

    // On a narrow tile the mark gives way to the words: the well is sized by
    // the tile's width as well as its height, and the space either side of it
    // eases in from [Space.md] — a 592dp phone's tile, at the text ceiling,
    // keeps Bengali's "No prize" to two lines. Nothing changes from 640dp up.
    final padH = math.min(Space.md, size.width * 0.06);
    final padV = size.height < 64 ? Space.xs : Space.sm;
    final well = math
        .min(size.height * 0.58, size.width * 0.2)
        .clamp(28.0, 56.0);
    final wordsH = size.height - 2 * padV;

    double lineHeight(String s, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: s, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final h = painter.height;
      painter.dispose();
      return h;
    }

    final stacked =
        parts.unit.isNotEmpty &&
        lineHeight(parts.amount, lead) + lineHeight(parts.unit, follow) <=
            wordsH;

    final Widget words;
    if (parts.unit.isEmpty) {
      words = Text(
        parts.amount,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: lead,
      );
    } else if (stacked) {
      words = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          prize.isPicture
              ? Text(
                  parts.amount,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: lead,
                )
              // A figure is never cut: "10 Lakh" and "1,00,00,000" are the
              // same tile, so a long one is set a little smaller instead.
              : FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(parts.amount, maxLines: 1, style: lead),
                ),
          Text(
            parts.unit,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: follow,
          ),
        ],
      );
    } else {
      words = Text.rich(
        TextSpan(
          children: [
            TextSpan(text: parts.amount, style: lead),
            TextSpan(text: ' ${parts.unit}', style: follow),
          ],
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }

    Widget mark = Container(
      width: well,
      height: well,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: prize.isNothing
            ? theme.colorScheme.onSurface.withValues(alpha: dark ? 0.06 : 0.05)
            : ink.withValues(alpha: dark ? 0.14 : 0.10),
      ),
      child: prize.isPicture
          ? LuckyPrizeGlyph(prize: prize, size: well - 4)
          : LuckyPrizeGlyph(prize: prize, size: well * 0.6),
    );
    final lit = this.lit;
    if (won && !prize.isNothing && lit != null) {
      mark = AnimatedBuilder(
        animation: lit,
        builder: (context, child) => Transform.scale(
          scale: 1 + 0.16 * bump(lit.value, from: 0.06, until: 0.5),
          child: child,
        ),
        child: mark,
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Padding(
          // A step more at the start, where the number stands over the
          // mark's shoulder; the figure keeps the whole of its line.
          padding: EdgeInsetsDirectional.fromSTEB(
            padH + Space.xxs,
            padV,
            padH,
            padV,
          ),
          child: Row(
            children: [
              mark,
              SizedBox(width: padH),
              Expanded(child: words),
            ],
          ),
        ),
        // The slot's number, as the wheel counts it from the top: the
        // quietest thing on the tile, in the corner the round mark leaves
        // free.
        PositionedDirectional(
          top: Space.xs,
          start: Space.sm,
          child: Text('${slot.slotNumber}', style: number),
        ),
      ],
    );
  }
}
