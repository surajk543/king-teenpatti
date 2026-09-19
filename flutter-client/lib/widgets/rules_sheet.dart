import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/theme_colors.dart';
import 'glass_components.dart';
import 'glass_panels.dart';
import 'playing_card.dart';
import 'premium_surface.dart';
import 'variation_prompt.dart';

/// The hand rankings, shown over whatever the player was looking at.
///
/// Deliberately translucent: it is a reference, not a place you go. The table
/// or the lobby stays visible behind it so a player can check what beats what
/// without losing their place.
///
/// With a [table] — the rules key on a lobby table card (owner, 18 Sep 2026:
/// "clicking it shows the rules according to the table he selected") — the
/// sheet opens on how THAT table plays, with the table's own figures in the
/// sentences, and carries the variations only when it is a variation
/// table. Without one (the Rules button) it is the whole reference.
Future<void> showRules(BuildContext context, {LobbyTable? table}) {
  return showDialog<void>(
    context: context,
    // One ink for both themes, at a light alpha (lighter than the store's
    // 0.72): the light theme's own ground would not dim the table at all, so
    // the barrier darkens it either way and the table stays readable behind.
    barrierColor: AppTheme.ink900.withValues(alpha: 0.45),
    builder: (context) => _RulesSheet(table: table),
  );
}

class _RulesSheet extends StatelessWidget {
  const _RulesSheet({this.table});

  /// The table whose rules were asked for, or null for the general sheet.
  final LobbyTable? table;

  /// How [table] plays, a sentence a rule. Every figure is the server's own
  /// menu entry, so the sheet cannot state a term the table does not keep; what
  /// the menu does not carry (the number of betting rounds) is not given a
  /// number here.
  static List<String> _tableRules(Strings t, LobbyTable table) {
    if (table.isPoker) return _pokerTableRules(t, table);
    final category = GameState.lobbyCategoryOf(table);
    final seen = category == TableCategory.seen;
    final blind = category == TableCategory.blind;
    return [
      if (category == TableCategory.variation) t.ruleVariationPick,
      seen ? t.everyoneChips : t.onlyYourChips,
      t.ruleBlindMoves(table.maxBlindMoves),
      // A blind table's ladder runs to the stack; seen and variation tables
      // raise once a turn.
      blind ? t.ruleRaiseFree : t.ruleRaiseOnce,
      table.potUncapped
          ? t.rulePotOpen
          : t.rulePotCapped(formatChips(table.maxPot)),
      // Blind tables have no forced showdown; the other two do.
      if (!blind) t.ruleRoundsEnd,
      t.ruleShowTwo,
    ];
  }

  /// How a poker table plays: enough of THAT game to sit down and play it —
  /// the blinds or the ante, the buy-in, the cards dealt, the streets in the
  /// order they come, what a bet names, and how the hand is decided. Every
  /// figure is the server's own (the menu entry, or the room's `poker` block
  /// through [LobbyTable.ofRoom]), so the sheet cannot state a term the table
  /// does not keep.
  ///
  /// Only the table's own game is described. At a poker table this is the
  /// whole sheet bar its ranking (owner, 19 Sep 2026: "tells about that
  /// specific table gameplay not other").
  static List<String> _pokerTableRules(Strings t, LobbyTable table) {
    final variant = table.category;
    final threeCard = variant == PokerVariant.threeCardPoker;
    final blinds = table.smallBlind > 0 || table.bigBlind > 0;
    return [
      t.pokerVariantNote(variant),
      if (blinds)
        t.rulePokerBlinds(
          formatChips(table.smallBlind),
          formatChips(table.bigBlind > 0 ? table.bigBlind : table.bootAmount),
        )
      else
        t.rulePokerAnte(
          formatChips(table.ante > 0 ? table.ante : table.bootAmount),
        ),
      if (table.minBuyIn > 0) t.rulePokerBuyIn(formatChips(table.minBuyIn)),
      if (table.holeCards > 0) t.rulePokerHoleCards(table.holeCards),
      // The betting rounds, in order, and then what a figure on a key means.
      switch (variant) {
        PokerVariant.texasHoldem || PokerVariant.omaha => t.rulePokerStreets,
        PokerVariant.fiveCardDraw => t.rulePokerDrawStreets,
        PokerVariant.threeCardPoker => t.rulePokerPlayBet,
        _ => t.rulePokerBestHandWins,
      },
      if (!threeCard) t.rulePokerBetTo,
      switch (variant) {
        PokerVariant.texasHoldem => t.rulePokerHoldemWin,
        PokerVariant.omaha => t.rulePokerOmahaWin,
        PokerVariant.fiveCardDraw => t.rulePokerDrawWin(
          table.maxDiscards > 0 ? table.maxDiscards : 5,
        ),
        PokerVariant.threeCardPoker => t.rulePokerThreeCardWin,
        _ => t.rulePokerBestHandWins,
      },
      if (threeCard) t.rulePokerDealerQualifies else t.rulePokerBestHandWins,
      // Owner, 19 Sep 2026: "in poker do not show opponent chips".
      t.onlyYourChips,
    ];
  }

  /// 3-Card Poker's ranking, strongest first, each with a three-card hand
  /// that shows it (go-server/internal/poker/eval3.go `CategoryNames3`). It is
  /// NEITHER of the other two orders on this sheet: a straight beats a flush
  /// (Teen Patti's does not) and three of a kind beats a straight flush in
  /// Teen Patti but loses to it here.
  static const List<(String, List<String>)> _threeCardExamples = [
    ('straightFlush', ['Qs', 'Js', 'Ts']),
    ('threeOfAKind', ['8s', '8h', '8d']),
    ('straight', ['Ac', 'Kd', 'Qs']),
    ('flush', ['Ad', 'Jd', '5d']),
    ('pair', ['Kh', 'Kc', '7d']),
    ('highCard', ['Kd', 'Jc', '8s']),
  ];

  /// The poker ranking, strongest first, each with a five-card hand that
  /// shows it (go-server/internal/poker). The names are the server's own.
  static const List<(String, List<String>)> _pokerExamples = [
    ('royalFlush', ['As', 'Ks', 'Qs', 'Js', 'Ts']),
    ('straightFlush', ['9h', '8h', '7h', '6h', '5h']),
    ('fourOfAKind', ['Kc', 'Kd', 'Kh', 'Ks', '3d']),
    ('fullHouse', ['Qs', 'Qh', 'Qd', '7c', '7d']),
    ('flush', ['Ad', 'Jd', '8d', '5d', '2d']),
    ('straight', ['Tc', '9d', '8s', '7h', '6c']),
    ('threeOfAKind', ['8s', '8h', '8d', 'Kc', '4d']),
    ('twoPair', ['Jh', 'Jc', '5s', '5d', 'Ac']),
    ('pair', ['Ah', 'Ad', '9c', '6s', '3h']),
    ('highCard', ['Kd', 'Jc', '8s', '5h', '2c']),
  ];

  /// Every ranking, strongest first, each with a hand that shows it. The order
  /// and the names are the server's own — this is a picture of how the
  /// showdown actually scores, not a separate description of the rules.
  static const List<(String, List<String>)> _examples = [
    ('trail', ['Ah', 'Ad', 'Ac']),
    ('pureSeq', ['Kh', 'Qh', 'Jh']),
    ('seq', ['Ks', 'Qd', 'Jc']),
    ('color', ['As', '9s', '4s']),
    ('pair', ['Qh', 'Qc', '7d']),
    ('high', ['Ad', 'Jc', '8s']),
  ];

  /// The variations of a variation table (owner, 18 Sep 2026), in the
  /// server's menu order, each with a hand that shows it, which of its cards
  /// play wild there, and which are held but do not count. The names and the
  /// one-line rules are the ones the table's own picker shows
  /// ([Strings.variationName], [Strings.variationNote]).
  static const List<(String, List<String>, List<String>, List<String>)>
  _variations = [
    // The best hand there is when the lowest hand wins.
    (Variation.muflis, ['5s', '3h', '2d'], [], []),
    // The 4 is wild: J-Q and a wild card make a sequence.
    (Variation.ak47, ['Jh', 'Qs', '4s'], ['4s'], []),
    // A nine was turned up, so the nine is wild: a trail of fives.
    (Variation.joker, ['9h', '5s', '5c'], ['9h'], []),
    // A heart was turned up, so the heart is wild: a pure sequence in spades.
    (Variation.hukam, ['8h', 'Qs', 'Js'], ['8h'], []),
    (Variation.lowestJoker, ['3h', '8d', 'Ks'], ['3h'], []),
    (Variation.highestJoker, ['3h', '8d', 'Ks'], ['Ks'], []),
    // The owner's own example: five cards held, and the pure sequence in
    // spades is what is played — the pair of sevens is set back, as the two
    // cards that do not count are on the felt ([SetBack]).
    (Variation.fiveCard, ['As', 'Ks', 'Qs', '7d', '7c'], [], ['7d', '7c']),
  ];

  /// Whether the sheet is scoped to a 3-Card Poker table, which alone is
  /// scored by [_threeCardExamples].
  bool get _threeCardTable =>
      table != null && table!.category == PokerVariant.threeCardPoker;

  /// The ranking this sheet shows.
  List<(String, List<String>)> get _ranking =>
      _threeCardTable ? _threeCardExamples : _pokerExamples;

  /// The notes under the ranking: on the general sheet every rule that
  /// differs by game, and on one table's sheet only what is true there.
  List<String> _rankingNotes(Strings t) {
    if (table == null) {
      return [
        t.pokerThreeCardRanking,
        t.rulePokerOmahaWin,
        t.rulePokerDealerQualifies,
      ];
    }
    return switch (table!.category) {
      PokerVariant.threeCardPoker => [
        t.pokerThreeCardRanking,
        t.rulePokerThreeCardRuns,
      ],
      PokerVariant.omaha => [t.rulePokerOmahaWin],
      PokerVariant.texasHoldem => [t.rulePokerHoldemWin],
      PokerVariant.fiveCardDraw => [t.rulePokerBestHandWins],
      _ => [t.rulePokerBestHandWins],
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = context.watch<GameState>().t;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Champagne on charcoal, its deep end on bone: goldBright on a light
    // panel is not a colour, it is a smudge.
    final champagne = theme.brightness == Brightness.dark
        ? AppTheme.goldBright
        : AppTheme.goldDeep;
    // The example hands are the one thing here that must scale: 41.4dp at
    // h=360, 47.3 at h=411, 66 (the ceiling) at h=800.
    final cardH = Dim.ruleCardH(MediaQuery.sizeOf(context).height);

    final labels = {
      'trail': (t.rankTrail, t.rankTrailNote),
      'pureSeq': (t.rankPureSeq, t.rankPureSeqNote),
      'seq': (t.rankSeq, t.rankSeqNote),
      'color': (t.rankColor, t.rankColorNote),
      'pair': (t.rankPair, t.rankPairNote),
      'high': (t.rankHigh, t.rankHighNote),
    };

    // Already glass: GlassDialog is GlassMode.auto at priority 20 and takes
    // the app's one blur when it is free.
    return GlassDialog(
      padding: const EdgeInsets.all(Space.xl),
      title: Row(
        children: [
          Icon(Icons.menu_book_outlined, size: 20, color: champagne),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              table == null
                  ? t.rulesTitle
                  : '${t.rulesTitle} · '
                        '${table!.isPoker ? t.pokerVariantName(table!.category) : t.variationOrCategory(GameState.lobbyCategoryOf(table!))} '
                        '${formatChips(table!.bootAmount)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.label(
                theme.textTheme.titleMedium ?? const TextStyle(),
              ),
            ),
          ),
          PressScale(
            child: IconButton(
              tooltip: t.close,
              icon: const Icon(Icons.close_rounded, size: 20),
              onPressed: () => Navigator.pop(context),
              // shrinkWrap + the 44dp floor: a Material icon button lays out
              // at 48 otherwise, taller than the title row.
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                minimumSize: const Size.square(Dim.minTouch),
              ),
            ),
          ),
        ],
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The chosen table first: that is what the player asked about.
          if (table != null) ...[
            Text(
              t.tableRulesTitle,
              style: AppTheme.label(
                theme.textTheme.titleSmall ?? const TextStyle(),
              ),
            ),
            const SizedBox(height: Space.sm),
            for (final rule in _tableRules(t, table!))
              Padding(
                padding: const EdgeInsets.only(bottom: Space.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: champagne,
                        ),
                      ),
                    ),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: Text(
                        rule,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurface.withValues(
                            alpha: AppTheme.inkMed,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: Space.lg),
          ],
          // A poker table's rules are the poker ranking alone: the Teen Patti
          // rankings are not how that table scores.
          if (table == null || !table!.isPoker) ...[
            Text(
              t.rulesBeats,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: AppTheme.inkLow),
              ),
            ),
            const SizedBox(height: Space.md),
            for (var i = 0; i < _examples.length; i++)
              _Row(
                place: i + 1,
                name: labels[_examples[i].$1]!.$1,
                note: labels[_examples[i].$1]!.$2,
                cards: _examples[i].$2,
                cardHeight: cardH,
                numeral: champagne,
                // A rule under every rank but the last: the list is ordered,
                // and the numerals already say which way.
                ruled: i < _examples.length - 1,
              ),
            const SizedBox(height: Space.md),
            // An inner well of tinted glass — tinted, never blurred: the
            // dialog around it already holds the app's one blur, and a nested
            // filter would sample the dialog's own layer every frame.
            PremiumGlassPanel(
              mode: GlassMode.tinted,
              radius: Radii.sm,
              elevated: false,
              padding: const EdgeInsets.all(Space.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.runOrder,
                    style: AppTheme.label(
                      theme.textTheme.labelLarge ?? const TextStyle(),
                    ),
                  ),
                  const SizedBox(height: Space.xxs),
                  Text(
                    t.runOrderNote,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface.withValues(
                        alpha: AppTheme.inkMed,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // The poker ranking. On the general sheet it is the family's
          // five-card one with the footnotes that differ by game; on ONE
          // table's sheet it is that table's ranking and nothing else —
          // three-card at 3-Card Poker (`eval3.go`, a different order from
          // both the five-card one and Teen Patti's), five-card everywhere
          // else — with no mention of the other three games (owner, 19 Sep
          // 2026). Never on a Teen Patti table's.
          if (table == null || table!.isPoker) ...[
            if (table == null) const SizedBox(height: Space.xl),
            Row(
              children: [
                Icon(Icons.casino_rounded, size: 18, color: champagne),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Text(
                    table == null ? t.pokerRulesTitle : t.pokerTableRankingTitle,
                    style: AppTheme.label(
                      theme.textTheme.titleSmall ?? const TextStyle(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.sm),
            Text(
              table == null
                  ? t.pokerRulesIntro
                  : _threeCardTable
                  ? t.pokerThreeCardRankingIntro
                  : t.pokerTableRankingIntro,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: AppTheme.inkMed),
              ),
            ),
            const SizedBox(height: Space.sm),
            for (var i = 0; i < _ranking.length; i++)
              _Row(
                place: i + 1,
                name: t.pokerRankName(_ranking[i].$1),
                note: '',
                cards: _ranking[i].$2,
                cardHeight: cardH * (_threeCardTable ? 1.0 : 0.8),
                numeral: champagne,
                ruled: i < _ranking.length - 1,
              ),
            const SizedBox(height: Space.md),
            // The footnotes: the whole set on the general sheet, and on one
            // table's sheet only what is true of THAT game.
            PremiumGlassPanel(
              mode: GlassMode.tinted,
              radius: Radii.sm,
              elevated: false,
              padding: const EdgeInsets.all(Space.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (i, note) in _rankingNotes(t).indexed) ...[
                    if (i > 0) const SizedBox(height: Space.xxs),
                    Text(
                      note,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurface.withValues(
                          alpha: AppTheme.inkMed,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],

          // Variation tables: what they are, then the ways a hand can be
          // decided there. Under the rankings because every one of them IS
          // those rankings — with some cards wild, or read the other way up.
          // Left out of a seen or blind table's own rules: it is not how that
          // table plays.
          if (table == null ||
              GameState.lobbyCategoryOf(table!) == TableCategory.variation) ...[
            const SizedBox(height: Space.xl),
            Row(
              children: [
                Icon(Icons.shuffle_rounded, size: 18, color: champagne),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Text(
                    t.variationRulesTitle,
                    style: AppTheme.label(
                      theme.textTheme.titleSmall ?? const TextStyle(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.sm),
            Text(
              t.variationRulesIntro,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: AppTheme.inkMed),
              ),
            ),
            const SizedBox(height: Space.sm),
            for (var i = 0; i < _variations.length; i++)
              _Row(
                name: t.variationName(_variations[i].$1),
                note: t.variationNote(_variations[i].$1),
                cards: _variations[i].$2,
                wild: _variations[i].$3,
                setBack: _variations[i].$4,
                wildLabel: t.wildCard,
                cardHeight: cardH,
                numeral: champagne,
                ruled: i < _variations.length - 1,
              ),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    this.place,
    required this.name,
    required this.note,
    required this.cards,
    required this.cardHeight,
    required this.numeral,
    required this.ruled,
    this.wild = const [],
    this.wildLabel = '',
    this.setBack = const [],
  });

  /// Which of [cards] are held but not counted — the two of a 5-Card hand that
  /// are not among its best three — drawn set back as they are on the felt.
  final List<String> setBack;

  /// Where the hand ranks, or null for a row that is not one of an order — the
  /// variations are alternatives, not places.
  final int? place;

  /// Which of [cards] play wild in this example, drawn with the gold edge a
  /// wild card carries on the felt ([WildEdge]); [wildLabel] is its name for a
  /// screen reader.
  final List<String> wild;
  final String wildLabel;
  final String name;
  final String note;
  final List<String> cards;
  final double cardHeight;

  /// The champagne the sheet settled on for this brightness.
  final Color numeral;
  final bool ruled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.sm),
          child: Row(
            children: [
              SizedBox(
                // A ranking gutter, not a badge: the numerals line up on their
                // right edge and the rows read as one column of places.
                width: 22,
                child: Text(
                  place == null ? '•' : '$place',
                  textAlign: TextAlign.right,
                  style: AppTheme.money(
                    theme.textTheme.titleMedium ?? const TextStyle(),
                    colour: numeral.withValues(alpha: 0.75),
                  ),
                ),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: AppTheme.label(
                        theme.textTheme.titleSmall ?? const TextStyle(),
                      ),
                    ),
                    Text(
                      note,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        // The quiet tier's own token, not a faded onSurface:
                        // it is the one tuned for contrast in both themes.
                        color: GlassColors.of(context).textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Space.md),
              // A hair of air between the cards so each keeps its own shadow;
              // PlayingCard now casts outside its box.
              for (final c in cards)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.xxs),
                  child: SetBack(
                    setBack: setBack.contains(c),
                    cardHeight: cardHeight,
                    child: WildEdge(
                      wild: wild.contains(c),
                      cardHeight: cardHeight,
                      label: wildLabel,
                      child: PlayingCard(height: cardHeight, code: c),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (ruled)
          Divider(
            height: 1,
            thickness: Dim.hairline,
            color: AppTheme.ink400.withValues(alpha: 0.25),
          ),
      ],
    );
  }
}
