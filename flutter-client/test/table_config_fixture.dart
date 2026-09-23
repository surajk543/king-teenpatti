// A `GET /api/tables` body exactly as the server's contract describes it
// (design §F6 and §E5, 23 Sep 2026): `session:ready.config`'s shape, every
// table entry carrying its session keys plus its engine and the figures it
// plays by, the private templates beside the menu, and the engines with the
// categories each plays. Shared by the catalogue's tests.

/// A 64-hex version, as the server computes it (sha256 of the body).
const versionA =
    '3f1c0b5e6a7d8c9b0a1f2e3d4c5b6a79808f7e6d5c4b3a291807f6e5d4c3b2a1';
const versionB =
    'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';

Map<String, dynamic> _teenPatti({
  required String category,
  required int boot,
  required int maxPot,
  required int sortOrder,
  bool private = false,
  int minChips = 0,
  int maxChips = 0,
  int maxRaiseSteps = 2,
  int maxBetRounds = 7,
  int potLimitMultiplier = 1024,
  int maxBlindMoves = 4,
  int variationSelectTimeoutMs = 0,
  int fiveCardPickTimeoutMs = 0,
}) => {
  'category': category,
  'bootAmount': boot,
  'maxPot': maxPot,
  'maxBlindMoves': maxBlindMoves,
  'minChips': minChips,
  'maxChips': maxChips,
  'engine': 'teen_patti',
  'key': private ? 'private:$category' : '$category:$boot',
  'isPrivate': private,
  'sortOrder': sortOrder,
  'maxRaiseSteps': maxRaiseSteps,
  'maxBetRounds': maxBetRounds,
  'potLimitMultiplier': potLimitMultiplier,
  'turnTimeoutMs': 25000,
  'maxMissedTurns': 3,
  'sideshowTimeoutMs': 6000,
  'sideshowMinPlayers': 3,
  'nextHandDelayMs': 4000,
  'unfundedGraceMs': 30000,
  'missileRevealExtraMs': 3000,
  'variationSelectTimeoutMs': variationSelectTimeoutMs,
  'fiveCardPickTimeoutMs': fiveCardPickTimeoutMs,
};

Map<String, dynamic> _poker({
  required String category,
  required int sortOrder,
  int turnTimeoutMs = 25000,
}) {
  const boot = 50000;
  final board = category == 'texas_holdem' || category == 'omaha';
  return {
    'category': category,
    'bootAmount': boot,
    'maxPot': 0,
    'maxBlindMoves': 0,
    'minChips': 500000,
    'maxChips': 0,
    'game': 'poker',
    if (board) 'smallBlind': boot ~/ 2,
    if (board) 'bigBlind': boot,
    if (!board) 'ante': boot,
    'minBuyIn': 500000,
    'holeCards': switch (category) {
      'texas_holdem' => 2,
      'omaha' => 4,
      'five_card_draw' => 5,
      _ => 3,
    },
    if (category == 'five_card_draw') 'maxDiscards': 3,
    'engine': 'poker',
    'key': '$category:$boot',
    'isPrivate': false,
    'sortOrder': sortOrder,
    'maxRaiseSteps': 0,
    'maxBetRounds': 0,
    'potLimitMultiplier': 0,
    'turnTimeoutMs': turnTimeoutMs,
    'maxMissedTurns': 3,
    'sideshowTimeoutMs': 6000,
    'sideshowMinPlayers': 3,
    'nextHandDelayMs': 4000,
    'unfundedGraceMs': 30000,
    'missileRevealExtraMs': 3000,
    'variationSelectTimeoutMs': 0,
    'fiveCardPickTimeoutMs': 0,
  };
}

/// The taxonomy the server seeds (§E2): Teen Patti playing seen, blind and
/// variation, Poker playing the four poker games, each with its admin label
/// and sort order — in the `engines` shape of §E5. A fresh list every call,
/// so a test may edit it.
List<Map<String, dynamic>> defaultEngines() => [
  {
    'code': 'teen_patti',
    'name': 'Teen Patti',
    'sortOrder': 10,
    'categories': [
      {'code': 'seen', 'name': 'Seen', 'sortOrder': 10},
      {'code': 'blind', 'name': 'Blind', 'sortOrder': 20},
      {'code': 'variation', 'name': 'Variation', 'sortOrder': 30},
    ],
  },
  {
    'code': 'poker',
    'name': 'Poker',
    'sortOrder': 20,
    'categories': [
      {'code': 'three_card_poker', 'name': '3-Card Poker', 'sortOrder': 40},
      {'code': 'five_card_draw', 'name': '5-Card Draw', 'sortOrder': 50},
      {'code': 'texas_holdem', 'name': "Texas Hold'em", 'sortOrder': 60},
      {'code': 'omaha', 'name': 'Omaha', 'sortOrder': 70},
    ],
  },
];

/// The catalogue body. [version] names it; [pokerTurnMs] is the poker
/// tables' own clock (the server's default is the Teen Patti one);
/// [privateBlindMoves] is the private seen template's blind allowance;
/// [engines] replaces [defaultEngines]. A menu without variation tables
/// still lists the variation CATEGORY, as the server does: a category is
/// active or not on its own, whatever tables it has.
Map<String, dynamic> catalogueBody({
  String version = versionA,
  int pokerTurnMs = 25000,
  int privateBlindMoves = 4,
  bool withVariation = true,
  List<Map<String, dynamic>>? engines,
}) => {
  'version': version,
  'source': 'db',
  'maxPlayers': 5,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'maxBetRounds': 20,
  'sideshowTimeoutMs': 6000,
  'sideshowMinPlayers': 3,
  'categories': [
    'seen',
    'blind',
    if (withVariation) 'variation',
    'three_card_poker',
    'five_card_draw',
    'texas_holdem',
    'omaha',
  ],
  'stakes': [200, 5000, 50000, 1000000],
  'entryCapBoot': 200,
  'entryCapCategory': 'blind',
  'entryCapMaxChips': 500000,
  'privateBoot': 200,
  'privateMaxPot': 500000,
  'tables': [
    _teenPatti(category: 'seen', boot: 200, maxPot: 2000000, sortOrder: 10),
    _teenPatti(
      category: 'blind',
      boot: 200,
      maxPot: 0,
      sortOrder: 20,
      maxChips: 500000,
      maxRaiseSteps: 0,
      maxBetRounds: 0,
      potLimitMultiplier: 0,
    ),
    _teenPatti(
      category: 'blind',
      boot: 5000,
      maxPot: 0,
      sortOrder: 30,
      maxChips: 50000000,
      maxRaiseSteps: 0,
      maxBetRounds: 0,
      potLimitMultiplier: 0,
    ),
    if (withVariation)
      _teenPatti(
        category: 'variation',
        boot: 50000,
        maxPot: 0,
        sortOrder: 60,
        maxChips: 1000000000,
        variationSelectTimeoutMs: 10000,
        fiveCardPickTimeoutMs: 8000,
      ),
    _poker(
      category: 'three_card_poker',
      sortOrder: 90,
      turnTimeoutMs: pokerTurnMs,
    ),
    _poker(
      category: 'five_card_draw',
      sortOrder: 100,
      turnTimeoutMs: pokerTurnMs,
    ),
    _poker(
      category: 'texas_holdem',
      sortOrder: 110,
      turnTimeoutMs: pokerTurnMs,
    ),
    _poker(category: 'omaha', sortOrder: 120, turnTimeoutMs: pokerTurnMs),
  ],
  'privateTables': [
    _teenPatti(
      category: 'seen',
      boot: 200,
      maxPot: 500000,
      sortOrder: 1010,
      private: true,
      maxBlindMoves: privateBlindMoves,
    ),
    _teenPatti(
      category: 'blind',
      boot: 200,
      maxPot: 500000,
      sortOrder: 1020,
      private: true,
      maxRaiseSteps: 2,
      maxBetRounds: 0,
      potLimitMultiplier: 0,
    ),
  ],
  'engines': engines ?? defaultEngines(),
};

/// `session:ready.config` for the same menu: the session keys only, no
/// `version`/`source`/`privateTables`/`engines` and no per-table `engine`
/// (§E5 leaves session:ready unchanged), and — from a server that has the
/// catalogue — `tableConfigVersion`. [tables] defaults to the catalogue's
/// entries cut down to what session:ready carries.
Map<String, dynamic> sessionConfig({
  String? tableConfigVersion = versionA,
  int minClientBuild = 0,
  List<Map<String, dynamic>>? tables,
}) {
  const sessionKeys = {
    'category',
    'bootAmount',
    'maxPot',
    'maxBlindMoves',
    'minChips',
    'maxChips',
    'game',
    'smallBlind',
    'bigBlind',
    'ante',
    'minBuyIn',
    'holeCards',
    'maxDiscards',
  };
  final full = catalogueBody();
  return {
    'maxPlayers': 5,
    'minPlayers': 2,
    'bootAmount': 200,
    'turnTimeoutMs': 25000,
    'welcomeChips': 300000,
    'maxBetRounds': 20,
    'sideshowTimeoutMs': 6000,
    'sideshowMinPlayers': 3,
    'minClientBuild': minClientBuild,
    'categories': full['categories'],
    'stakes': full['stakes'],
    'entryCapBoot': 200,
    'entryCapCategory': 'blind',
    'entryCapMaxChips': 500000,
    'privateBoot': 200,
    'privateMaxPot': 500000,
    'tables':
        tables ??
        [
          for (final t in full['tables'] as List)
            {
              for (final e in (t as Map<String, dynamic>).entries)
                if (sessionKeys.contains(e.key)) e.key: e.value,
            },
        ],
    'tableConfigVersion': ?tableConfigVersion,
  };
}
