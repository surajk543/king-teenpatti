/// Player stats v2 on the wire (owner, 27 Sep 2026: "maintain stats acc to
/// only three category: teenpatti variation and poker … how many times he got
/// trail, pair, highcard, pure sequence, sequence also. how many muflis, ak47,
/// other gameplay type he played").
///
/// A record is kept in three games — Teen Patti (the seen and blind tables),
/// Variation and Poker — and the server sends each under its own key of
/// `stats`: on the player's own account (the user object, with its two chip
/// figures) and on another player's profile (`stats.categories`, never a chip
/// figure). Plain readers, tolerant as every DTO in the app: a game, a figure,
/// a tally or a list the server did not send reads as zeros or empty, never as
/// an error, and nothing here counts, ranks or decides anything — the hands a
/// player held are the server's tally, read as sent.
library;

int _int(dynamic v) => v is num && v.isFinite ? v.toInt() : 0;
Map<String, dynamic> _map(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

/// Which view of a record is on show: every game together, or one of the
/// three the server keeps. The three games' names are the keys of `stats` on
/// the wire (`teenPatti`, `variation`, `poker`).
enum StatsCategory {
  all,
  teenPatti,
  variation,
  poker;

  /// Whether the view counts the hands held — Trail down to High Card:
  /// Teen Patti's and Variation's. A poker hand is not a Teen Patti hand.
  bool get countsHands => this == teenPatti || this == variation;

  /// Whether the view lists the variations the hands were played under:
  /// Variation's alone.
  bool get listsVariations => this == variation;
}

/// How often a player held each Teen Patti hand, as the table counted it — a
/// variation's wild cards make the hand (a pair and a joker IS a trail), and
/// under 5-Card the three that played count. One of the six for every hand
/// they finished, so the six sum to those hands.
class HandTally {
  const HandTally({
    this.trail = 0,
    this.pureSequence = 0,
    this.sequence = 0,
    this.color = 0,
    this.pair = 0,
    this.highCard = 0,
  });

  final int trail;
  final int pureSequence;
  final int sequence;
  final int color;
  final int pair;
  final int highCard;

  /// The six hands' names, strongest first: the server's own English names
  /// for them, which the app shows untranslated wherever a hand is named
  /// (CLAUDE.md §6.3).
  static const names = [
    'Trail',
    'Pure Sequence',
    'Sequence',
    'Color',
    'Pair',
    'High Card',
  ];

  /// Each hand's icon, in the order of [names] (owner, 27 Sep 2026: "there is
  /// no icon in hands held category in player stats, add icons also"): the
  /// daily XP's own "Win by" marks (`xp_sources.icon` — 🔥 Trail, 💎 Pure
  /// Sequence, 🃏 Sequence, 🎨 Color, 👥 Pair), so a hand wears the same icon
  /// on the record as on its mission, and ☝️ for High Card — one card, the
  /// highest — which has no mission (🔝 drew as a blue "TOP" key beside the
  /// others). ☝ is text by default, so it carries U+FE0F and a phone draws it
  /// in colour from its emoji font like the other five.
  static const icons = ['🔥', '💎', '🃏', '🎨', '👥', '\u261D\uFE0F'];

  /// The six as the wire keys them, in the order of [names].
  static const fields = [
    'trail',
    'pureSequence',
    'sequence',
    'color',
    'pair',
    'highCard',
  ];

  /// The six counts in the order of [names].
  List<int> get counts => [
    trail,
    pureSequence,
    sequence,
    color,
    pair,
    highCard,
  ];

  /// Every hand counted: the hands finished.
  int get total => counts.fold(0, (sum, n) => sum + n);

  factory HandTally.fromJson(Map<String, dynamic> j) => HandTally(
    trail: _int(j['trail']),
    pureSequence: _int(j['pureSequence']),
    sequence: _int(j['sequence']),
    color: _int(j['color']),
    pair: _int(j['pair']),
    highCard: _int(j['highCard']),
  );
}

/// The hands played under one variation, and how many of them were won.
class VariationTally {
  const VariationTally({
    required this.variation,
    this.handsPlayed = 0,
    this.handsWon = 0,
  });

  /// The variation's wire value — MUFLIS, AK47, JOKER, HUKAM, LOWEST_JOKER,
  /// HIGHEST_JOKER, FIVE_CARD. An open set: one this build has never heard of
  /// is kept, and named as the server sent it.
  final String variation;
  final int handsPlayed;
  final int handsWon;

  factory VariationTally.fromJson(Map<String, dynamic> j) => VariationTally(
    variation: j['variation'] is String
        ? (j['variation'] as String).trim()
        : '',
    handsPlayed: _int(j['handsPlayed']),
    handsWon: _int(j['handsWon']),
  );

  /// The list as the server sent it, in its order (Muflis first, a variation
  /// it has no place for last). Anything that is not a variation — no name —
  /// is dropped rather than drawn as a blank row; never null.
  static List<VariationTally> listFrom(Object? raw) => raw is List
      ? raw
            .whereType<Map>()
            .map((e) => VariationTally.fromJson(Map<String, dynamic>.from(e)))
            .where((v) => v.variation.isNotEmpty)
            .toList()
      : const <VariationTally>[];
}

/// One game's record — or, for [StatsCategory.all], every game's together.
class CategoryStats {
  const CategoryStats({
    this.handsPlayed = 0,
    this.handsWon = 0,
    this.handsLost = 0,
    this.handsLeft = 0,
    this.totalWinnings = 0,
    this.biggestPot = 0,
    this.totalTaxPaid = 0,
    this.winRate = 0,
    this.hands = const HandTally(),
    this.variations = const <VariationTally>[],
  });

  /// A game not played yet: zeros everywhere.
  static const empty = CategoryStats();

  final int handsPlayed;
  final int handsWon;
  final int handsLost;

  /// Hands left before the end.
  final int handsLeft;

  /// The two chip figures: the pots won, gross, and the largest of them. Only
  /// ever read from the player's own account — 0 on another player's record,
  /// whatever the server sent ([CategoryStats.fromJson]'s `chips`).
  final int totalWinnings;
  final int biggestPot;

  /// The winning tax the player has paid in this game (owner, 2 Oct 2026:
  /// "player can see how mch tax they paid in stats button, but other player
  /// cannot see other player tax information"): the chips withheld from
  /// their taxed wins, which [totalWinnings] — gross — still counts. A chip
  /// figure like the two above: read from the player's own account alone, 0
  /// on another player's record whatever the server sent, and 0 from a
  /// server that does not count it yet.
  final int totalTaxPaid;

  /// Per cent of the hands played that were won, 0 to 100, to two places.
  final double winRate;

  /// The hands held: Teen Patti's and Variation's (zeros elsewhere).
  final HandTally hands;

  /// The variations played under: Variation's alone (empty elsewhere).
  final List<VariationTally> variations;

  /// Read from one game's object. [chips] false reads a record that must not
  /// carry a chip figure — another player's — so [totalWinnings],
  /// [biggestPot] and [totalTaxPaid] stay 0 even were the server to send
  /// them.
  factory CategoryStats.fromJson(Map<String, dynamic> j, {bool chips = true}) {
    final rate = j['winRate'];
    return CategoryStats(
      handsPlayed: _int(j['handsPlayed']),
      handsWon: _int(j['handsWon']),
      handsLost: _int(j['handsLost']),
      handsLeft: _int(j['handsLeft']),
      totalWinnings: chips ? _int(j['totalWinnings']) : 0,
      biggestPot: chips ? _int(j['biggestPot']) : 0,
      totalTaxPaid: chips ? _int(j['totalTaxPaid']) : 0,
      winRate: rate is num && rate.isFinite
          ? rate.toDouble().clamp(0.0, 100.0)
          : 0,
      hands: HandTally.fromJson(_map(j['hands'])),
      variations: VariationTally.listFrom(j['variations']),
    );
  }
}

/// A record's three games: `stats` on the player's own account, and
/// `stats.categories` on another player's profile.
class StatsByCategory {
  const StatsByCategory({
    this.teenPatti = CategoryStats.empty,
    this.variation = CategoryStats.empty,
    this.poker = CategoryStats.empty,
  });

  final CategoryStats teenPatti;
  final CategoryStats variation;
  final CategoryStats poker;

  /// The game [category] names; [StatsCategory.all] is not a game of its own
  /// (the record's totals are), and reads as [CategoryStats.empty].
  CategoryStats of(StatsCategory category) => switch (category) {
    StatsCategory.teenPatti => teenPatti,
    StatsCategory.variation => variation,
    StatsCategory.poker => poker,
    StatsCategory.all => CategoryStats.empty,
  };

  /// [chips] as [CategoryStats.fromJson] reads it: false for another
  /// player's.
  factory StatsByCategory.fromJson(
    Map<String, dynamic> j, {
    bool chips = true,
  }) => StatsByCategory(
    teenPatti: CategoryStats.fromJson(_map(j['teenPatti']), chips: chips),
    variation: CategoryStats.fromJson(_map(j['variation']), chips: chips),
    poker: CategoryStats.fromJson(_map(j['poker']), chips: chips),
  );
}
