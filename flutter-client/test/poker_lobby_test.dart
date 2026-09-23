// The poker family in the lobby: one POKER card on the front beside Teen
// Patti, the four games inside it as cards of their own — 3-Card Poker, 5-Card
// Draw, Texas Hold'em, Omaha (owner, 23 Sep 2026) — and inside each game its
// tables, each card stating its own terms. On a menu that offers no poker
// table, none of it.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/rules_sheet.dart';

/// The Teen Patti part of the server's default menu.
const _teenPatti = <Map<String, Object>>[
  {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
  {'category': 'blind', 'bootAmount': 200, 'maxChips': 500000},
  {'category': 'blind', 'bootAmount': 5000, 'maxChips': 50000000},
  {'category': 'variation', 'bootAmount': 50000, 'maxChips': 1000000000},
];

/// The four poker entries as the server lists them (§6.5) — **one table per
/// game, all four at boot 50,000**, which is what `LOBBY_TABLES` has offered
/// since go-server's `159b4fc`: blinds 25,000 / 50,000 on the board games, an
/// ante of 50,000 on the others, and a buy-in of ten boots (5 Lakh) on each.
/// The figures matter here — a five-figure blind pair and a six-figure buy-in
/// are what the cards actually have to hold.
const _boot = 50000;
const _buyIn = 500000;
const _pokerEntries = <Map<String, Object>>[
  {
    'category': 'texas_holdem',
    'bootAmount': _boot,
    'maxPot': 0,
    'maxBlindMoves': 0,
    'minChips': _buyIn,
    'game': 'poker',
    'smallBlind': _boot ~/ 2,
    'bigBlind': _boot,
    'minBuyIn': _buyIn,
    'holeCards': 2,
  },
  {
    'category': 'omaha',
    'bootAmount': _boot,
    'maxPot': 0,
    'maxBlindMoves': 0,
    'minChips': _buyIn,
    'game': 'poker',
    'smallBlind': _boot ~/ 2,
    'bigBlind': _boot,
    'minBuyIn': _buyIn,
    'holeCards': 4,
  },
  {
    'category': 'five_card_draw',
    'bootAmount': _boot,
    'maxPot': 0,
    'maxBlindMoves': 0,
    'minChips': _buyIn,
    'game': 'poker',
    'ante': _boot,
    'minBuyIn': _buyIn,
    'holeCards': 5,
    'maxDiscards': 3,
  },
  {
    'category': 'three_card_poker',
    'bootAmount': _boot,
    'maxPot': 0,
    'maxBlindMoves': 0,
    'minChips': _buyIn,
    'game': 'poker',
    'ante': _boot,
    'minBuyIn': _buyIn,
    'holeCards': 3,
  },
];

const _menu = [..._teenPatti, ..._pokerEntries];

GameConfig _config(List<Map<String, Object>> tables) => GameConfig.fromJson({
  'maxPlayers': 5,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'entryCapBoot': 200,
  'entryCapCategory': 'blind',
  'entryCapMaxChips': 500000,
  'tables': tables,
});

GameState _state({
  // Above the poker tables' 5 Lakh buy-in, so every one of them is open.
  int chips = 2000000,
  AppLang lang = AppLang.english,
  List<Map<String, Object>> tables = _menu,
}) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = Screen.lobby
    ..config = _config(tables)
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Ravi',
      'chips': chips,
      'diamond': 9,
      'hammer': 20,
      'missile': 1,
    });
}

Future<void> _loadInter() async {
  final inter = FontLoader('Inter');
  for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
  }
  await inter.load();
}

Future<void> _pumpLobby(
  WidgetTester tester,
  GameState state, {
  required Size screen,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(sound: false),
        builder: (context, child) => GlassBudget(child: child!),
        home: const LobbyScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _settleLevel(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _tapInRail(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(target);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

/// The plain rules reference — `showRules(context)` with no table — opened
/// from a bare host. The lobby reaches it through its settings drawer and the
/// table through its menu; neither route is what this is asking about.
Future<void> _pumpRules(
  WidgetTester tester,
  GameState state, {
  required Size screen,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    ChangeNotifierProvider<GameState>.value(
      value: state,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(sound: false),
        builder: (context, child) => GlassBudget(child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showRules(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// A text that reads [name] however it is broken over lines: the back tile
/// stands a name of two words on two lines.
Finder _named(String name) => find.byWidgetPredicate(
  (w) => w is Text && w.data?.replaceAll('\n', ' ') == name,
  skipOffstage: false,
);

void main() {
  setUpAll(_loadInter);

  group('the menu', () {
    test('puts Poker on the front after Teen Patti, and the four games inside '
        'it in the owner\'s order, whatever the menu\'s', () {
      final state = _state();
      addTearDown(state.dispose);
      expect(state.lobbyEngines, [TableEngine.teenPatti, TableEngine.poker]);
      expect(state.lobbyCategoriesIn(TableEngine.poker), [
        TableCategory.threeCardPoker,
        TableCategory.fiveCardDraw,
        TableCategory.texasHoldem,
        TableCategory.omaha,
      ]);
      // Every poker table counts on the Poker card, in the server's order.
      expect(state.lobbyTablesOf(TableEngine.poker).map((t) => t.category), [
        'texas_holdem',
        'omaha',
        'five_card_draw',
        'three_card_poker',
      ]);
      // Each game holds its own table.
      for (final wire in TableCategory.pokerCategories) {
        expect(state.lobbyTablesIn(wire).map((t) => t.category), [
          wire,
        ], reason: wire);
        expect(
          GameState.lobbyEngineOf(state.lobbyTablesIn(wire).single),
          TableEngine.poker,
        );
      }
      // And none of them under Teen Patti, or under Seen, where an unknown
      // category goes.
      expect(state.lobbyCategoriesIn(TableEngine.teenPatti), [
        TableCategory.seen,
        TableCategory.blind,
        TableCategory.variation,
      ]);
      expect(state.lobbyTablesIn(TableCategory.seen).map((t) => t.category), [
        'seen',
      ]);
    });

    test('offers only the games it has a table for', () {
      final state = _state(tables: [..._teenPatti, _pokerEntries.first]);
      addTearDown(state.dispose);
      expect(state.lobbyCategoriesIn(TableEngine.poker), [
        TableCategory.texasHoldem,
      ]);
      state.openLobbyCategory(TableCategory.omaha);
      expect(state.lobbyCategory, isNull);
    });

    test('without a poker entry offers no Poker card', () {
      final state = _state(tables: _teenPatti);
      addTearDown(state.dispose);
      expect(state.lobbyEngines, [TableEngine.teenPatti]);
      expect(state.lobbyTablesOf(TableEngine.poker), isEmpty);
      state.openLobbyEngine(TableEngine.poker);
      expect(state.lobbyEngine, isNull);
      state.openLobbyCategory(TableCategory.texasHoldem);
      expect(state.lobbyEngine, isNull);
      expect(state.lobbyCategory, isNull);
    });

    test('shuts a poker table to a stack under its buy-in', () {
      final poor = _state(chips: _buyIn - 1);
      addTearDown(poor.dispose);
      for (final table in poor.lobbyTablesOf(TableEngine.poker)) {
        expect(poor.tableShut(table), isTrue, reason: table.category);
      }
      final rich = _state(chips: _buyIn);
      addTearDown(rich.dispose);
      for (final table in rich.lobbyTablesOf(TableEngine.poker)) {
        expect(rich.tableShut(table), isFalse, reason: table.category);
      }
    });
  });

  for (final (screen, scale) in [
    (const Size(640, 360), 1.25),
    (const Size(891, 411), 1.0),
  ]) {
    final name = '${screen.width.toInt()}x${screen.height.toInt()} x$scale';

    for (final lang in AppLang.values) {
      testWidgets('at $name in ${lang.englishName} the front has a Poker card, '
          'the four games are inside it, and each game holds its table', (
        tester,
      ) async {
        final state = _state(lang: lang);
        final t = Strings(lang);
        await _pumpLobby(tester, state, screen: screen, textScale: scale);
        expect(tester.takeException(), isNull);

        // Teen Patti, Poker and the private card; the poker card carries the
        // family's name and its one line.
        expect(find.text(t.viewGames, skipOffstage: false), findsNWidgets(2));
        expect(find.text(t.poker, skipOffstage: false), findsOneWidget);
        expect(
          find.text(t.pokerTableNote, skipOffstage: false),
          findsOneWidget,
        );
        expect(find.text(t.viewTables, skipOffstage: false), findsNothing);

        // Into Poker: the four games, each a card named for its game and
        // saying how it is played, behind the way back to every game. Poker
        // is the LAST engine card, and named by `last` rather than by index
        // because the rail is a ListView — scrolling to a card can dispose
        // the first, and an index taken before the scroll then names another.
        await _tapInRail(
          tester,
          find.text(t.viewGames, skipOffstage: false).last,
        );
        await _settleLevel(tester);
        expect(tester.takeException(), isNull);
        expect(state.lobbyEngine, TableEngine.poker);
        expect(state.lobbyCategory, isNull);
        expect(
          find.byKey(
            const ValueKey('lobby-rail:${TableEngine.poker}'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        expect(find.text(t.viewTables, skipOffstage: false), findsNWidgets(4));
        expect(find.text(t.tapToSit, skipOffstage: false), findsNothing);
        expect(
          find.text(t.backToCategories, skipOffstage: false),
          findsOneWidget,
        );
        for (final wire in TableCategory.pokerCategories) {
          expect(
            find.text(t.pokerVariantName(wire), skipOffstage: false),
            findsOneWidget,
            reason: wire,
          );
          expect(
            find.text(t.pokerVariantNote(wire), skipOffstage: false),
            findsOneWidget,
            reason: wire,
          );
        }
        // Nothing a Teen Patti card says.
        expect(find.text(t.seen, skipOffstage: false), findsNothing);
        expect(find.text(t.blind, skipOffstage: false), findsNothing);

        // Into each game in turn: its one table, badged with the game's name
        // and stating its terms, behind a way back to Poker.
        var blinds = 0, antes = 0, discards = 0;
        for (final wire in TableCategory.pokerCategories) {
          await _tapInRail(
            tester,
            find.text(t.pokerVariantName(wire), skipOffstage: false),
          );
          await _settleLevel(tester);
          expect(tester.takeException(), isNull, reason: wire);
          expect(state.lobbyCategory, wire);
          expect(
            find.text(t.tapToSit, skipOffstage: false),
            findsOneWidget,
            reason: wire,
          );
          expect(find.text(t.viewTables, skipOffstage: false), findsNothing);
          // The table card's own line, and the way back naming the game
          // (the tile) beside the table's badge.
          expect(
            find.text(t.pokerVariantNote(wire), skipOffstage: false),
            findsOneWidget,
            reason: wire,
          );
          expect(
            _named(t.pokerVariantName(wire)),
            findsNWidgets(2),
            reason: wire,
          );
          expect(find.text(t.buyInLabel, skipOffstage: false), findsOneWidget);
          expect(
            find.text(t.buyInFrom(formatChips(_buyIn)), skipOffstage: false),
            findsOneWidget,
          );
          expect(
            find.text(t.holeCardsLabel, skipOffstage: false),
            findsOneWidget,
          );
          blinds += tester
              .widgetList(find.text(t.blindsLabel, skipOffstage: false))
              .length;
          antes += tester
              .widgetList(find.text(t.anteLabel, skipOffstage: false))
              .length;
          discards += tester
              .widgetList(find.text(t.maxDiscardsLabel, skipOffstage: false))
              .length;
          if (wire == TableCategory.texasHoldem ||
              wire == TableCategory.omaha) {
            expect(
              find.text(
                '${formatChips(_boot ~/ 2)} / ${formatChips(_boot)}',
                skipOffstage: false,
              ),
              findsOneWidget,
              reason: wire,
            );
          }
          // Nothing a Teen Patti card says.
          expect(
            find.text(t.maxBlindsLabel, skipOffstage: false),
            findsNothing,
          );
          expect(find.text(t.potLimitLabel, skipOffstage: false), findsNothing);

          // Back to Poker, by the tile that names it.
          await _tapInRail(tester, find.text(t.poker, skipOffstage: false));
          await _settleLevel(tester);
          expect(tester.takeException(), isNull, reason: wire);
          expect(state.lobbyEngine, TableEngine.poker);
          expect(state.lobbyCategory, isNull);
        }
        // Blinds on the two board games, an ante on the other two, discards
        // on Draw alone.
        expect(blinds, 2);
        expect(antes, 2);
        expect(discards, 1);

        await _unmount(tester);
        state.dispose();
      });
    }
  }

  testWidgets('a menu without poker shows Teen Patti alone and no Poker', (
    tester,
  ) async {
    final state = _state(tables: _teenPatti);
    const t = Strings(AppLang.english);
    await _pumpLobby(tester, state, screen: const Size(891, 411));
    expect(tester.takeException(), isNull);
    expect(find.text(t.viewGames, skipOffstage: false), findsOneWidget);
    expect(find.text(t.teenPatti, skipOffstage: false), findsOneWidget);
    expect(find.text(t.poker, skipOffstage: false), findsNothing);
    await _unmount(tester);
    state.dispose();
  });

  testWidgets('tapping a poker card sits the player at that game', (
    tester,
  ) async {
    final state = _state();
    const t = Strings(AppLang.english);
    await _pumpLobby(tester, state, screen: const Size(891, 411));
    state.openLobbyCategory(TableCategory.omaha);
    await _settleLevel(tester);
    // The join goes to a socket that is not connected: the state reports
    // that as a notice rather than throwing, and the category stays open.
    await _tapInRail(tester, find.text(t.tapToSit, skipOffstage: false));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(state.lobbyEngine, TableEngine.poker);
    expect(state.lobbyCategory, TableCategory.omaha);
    expect(state.screen, Screen.lobby);
    await _unmount(tester);
    state.dispose();
  });

  testWidgets("a poker card's info key says the game's own terms", (
    tester,
  ) async {
    final state = _state();
    const t = Strings(AppLang.english);
    await _pumpLobby(
      tester,
      state,
      screen: const Size(640, 360),
      textScale: 1.25,
    );
    state.openLobbyCategory(TableCategory.texasHoldem);
    await _settleLevel(tester);
    final keys = find.bySemanticsLabel(t.tableInfoTitle, skipOffstage: false);
    expect(keys, findsOneWidget);

    // Texas Hold'em's one table.
    await _tapInRail(tester, keys.first);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(state.screen, Screen.lobby);
    expect(
      find.textContaining(t.pokerVariantName('texas_holdem')),
      findsWidgets,
    );
    expect(find.text(t.pokerVariantNote('texas_holdem')), findsWidgets);
    expect(find.text(t.blindsLabel), findsWidgets);
    expect(find.text(t.buyInFrom(formatChips(_buyIn))), findsWidgets);
    expect(find.text(t.holeCardsLabel), findsWidgets);
    // A poker room keeps every stack to its owner (owner, 19 Sep 2026).
    expect(find.text(t.onlyYourChips), findsWidgets);
    expect(find.text(t.everyoneChips), findsNothing);
    expect(find.text(t.playersUpTo(5)), findsOneWidget);
    expect(find.text(t.canSitHere), findsOneWidget);
    expect(find.text(t.maxBlindsLabel), findsNothing);
    expect(find.text(t.potLimitLabel), findsNothing);
    await tester.tap(find.byTooltip(t.close));
    await tester.pump(const Duration(milliseconds: 500));

    await _unmount(tester);
    state.dispose();
  });

  testWidgets("a poker card's info key names the table's own turn clock when "
      'the table catalogue sends one', (tester) async {
    // The catalogue (GET /api/tables, 23 Sep 2026) states each table's clock.
    // A poker room's is its own — POKER_TURN_TIMEOUT_MS — and the popup used
    // to show the table-wide Teen Patti figure beside it.
    final state = _state(
      tables: [
        ..._teenPatti,
        {..._pokerEntries.first, 'turnTimeoutMs': 90000},
        ..._pokerEntries.skip(1),
      ],
    );
    const t = Strings(AppLang.english);
    await _pumpLobby(
      tester,
      state,
      screen: const Size(640, 360),
      textScale: 1.25,
    );
    state.openLobbyCategory(TableCategory.texasHoldem);
    await _settleLevel(tester);
    final keys = find.bySemanticsLabel(t.tableInfoTitle, skipOffstage: false);

    // Texas Hold'em carries its own clock.
    await _tapInRail(tester, keys.first);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(find.text(t.secondsEach(90)), findsOneWidget);
    expect(find.text(t.secondsEach(25)), findsNothing);
    await tester.tap(find.byTooltip(t.close));
    await tester.pump(const Duration(milliseconds: 500));

    // Omaha's entry names none (a session menu): the table-wide figure.
    state.openLobbyCategory(TableCategory.omaha);
    await _settleLevel(tester);
    await _tapInRail(tester, keys.first);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(t.secondsEach(25)), findsOneWidget);
    await tester.tap(find.byTooltip(t.close));
    await tester.pump(const Duration(milliseconds: 500));

    await _unmount(tester);
    state.dispose();
  });

  testWidgets("a poker card's rules key opens that game's rules and the "
      'poker ranking, not Teen Patti\'s', (tester) async {
    final state = _state();
    const t = Strings(AppLang.english);
    await _pumpLobby(
      tester,
      state,
      screen: const Size(640, 360),
      textScale: 1.25,
    );
    state.openLobbyCategory(TableCategory.threeCardPoker);
    await _settleLevel(tester);
    final keys = find.bySemanticsLabel(t.tableRulesKey, skipOffstage: false);
    expect(keys, findsOneWidget);

    // 3-Card Poker's table: the dealer's qualification is a rule.
    await _tapInRail(tester, keys.first);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    expect(state.screen, Screen.lobby);
    expect(find.text(t.tableRulesTitle), findsOneWidget);
    expect(find.text(t.pokerVariantNote('three_card_poker')), findsWidgets);
    expect(find.text(t.rulePokerAnte(formatChips(_boot))), findsOneWidget);
    expect(find.text(t.rulePokerBuyIn(formatChips(_buyIn))), findsOneWidget);
    expect(find.text(t.rulePokerHoleCards(3)), findsOneWidget);
    expect(find.text(t.rulePokerThreeCardWin), findsOneWidget);
    expect(find.text(t.rulePokerDealerQualifies), findsWidgets);
    // ONE table's sheet carries that table's ranking and nothing else
    // (owner, 19 Sep 2026), so the family heading gives way to the table's
    // and 3-Card Poker shows its own three-card order — which has no royal
    // flush in it at all.
    expect(find.text(t.pokerRulesTitle, skipOffstage: false), findsNothing);
    expect(
      find.text(t.pokerTableRankingTitle, skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.text(t.pokerRankName('royalFlush'), skipOffstage: false),
      findsNothing,
    );
    expect(
      find.text(t.pokerRankName('threeOfAKind'), skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text(t.rankTrail, skipOffstage: false), findsNothing);
    expect(find.text(t.variationRulesTitle, skipOffstage: false), findsNothing);
    await tester.ensureVisible(
      find.text(t.pokerRankName('highCard'), skipOffstage: false),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);

    await _unmount(tester);
    state.dispose();
  });

  testWidgets('the general rules keep the Teen Patti rankings and add the '
      'poker ranking under them', (tester) async {
    final state = _state();
    const t = Strings(AppLang.english);
    // `showRules(context)` with no table is the plain reference, which the
    // lobby's settings drawer and the table's menu both open. Driven from a
    // bare host rather than through the drawer, which is the lobby's own
    // business and is tested where the lobby is.
    await _pumpRules(tester, state, screen: const Size(891, 411));
    expect(tester.takeException(), isNull);
    expect(find.text(t.rankTrail, skipOffstage: false), findsOneWidget);
    expect(find.text(t.pokerRulesTitle, skipOffstage: false), findsOneWidget);
    // Nine of the ten rungs; "High Card" is checked with `findsWidgets`
    // because the Teen Patti ranking above names it too, in the same words.
    for (final rank in const [
      'royalFlush',
      'straightFlush',
      'fourOfAKind',
      'fullHouse',
      'flush',
      'straight',
      'threeOfAKind',
      'twoPair',
    ]) {
      expect(
        find.text(t.pokerRankName(rank), skipOffstage: false),
        findsOneWidget,
        reason: rank,
      );
    }
    expect(
      find.text(t.pokerRankName('highCard'), skipOffstage: false),
      findsWidgets,
    );
    await _unmount(tester);
    state.dispose();
  });
}
