// The engines and their categories (owner, 23 Sep 2026: "Make this category
// is table/db level also: Teen Patti engines / Poker engines").
//
// The server keeps the lobby's hierarchy as data now — `table_engines`, and
// under each engine its `table_categories` — and `GET /api/tables` carries it
// as `engines`, with every table naming its own `engine`. The lobby is built
// on it (owner, 23 Sep 2026: "give two cards: Teen Patti and Poker"): one
// front card per ENGINE, inside it one card per CATEGORY, both in the order
// the server gives. Without it — `session:ready`, an older server — the lobby
// files by the fixed taxonomy and must come out the same, and these tests
// hold both halves.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/state/table_config_cache.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'table_config_fixture.dart';

/// The front cards of the seeded taxonomy, and the categories inside each.
const _engines = [TableEngine.teenPatti, TableEngine.poker];
const _teenPatti = [
  TableCategory.seen,
  TableCategory.blind,
  TableCategory.variation,
];
const _poker = [
  TableCategory.threeCardPoker,
  TableCategory.fiveCardDraw,
  TableCategory.texasHoldem,
  TableCategory.omaha,
];

/// A family this build has never heard of, as a later server's taxonomy
/// would add it: an engine of its own with one category.
Map<String, dynamic> _rummyEngine({int sortOrder = 30}) => {
  'code': 'rummy',
  'name': 'Rummy',
  'sortOrder': sortOrder,
  'categories': [
    {'code': 'points_rummy', 'name': 'Points Rummy', 'sortOrder': 80},
  ],
};

/// A table of that family, in the catalogue's shape.
Map<String, dynamic> _rummyTable({String? engine = 'rummy'}) => {
  'category': 'points_rummy',
  'bootAmount': 1000,
  'maxPot': 0,
  'maxBlindMoves': 0,
  'minChips': 0,
  'maxChips': 0,
  'engine': ?engine,
  'key': 'points_rummy:1000',
  'isPrivate': false,
  'sortOrder': 130,
};

/// The catalogue body with [extraTables] after the default menu's.
Map<String, dynamic> _body({
  List<Map<String, dynamic>>? engines,
  List<Map<String, dynamic>> extraTables = const [],
  bool withVariation = true,
}) {
  final body = catalogueBody(engines: engines, withVariation: withVariation);
  return body..['tables'] = [...body['tables'] as List, ...extraTables];
}

/// The same body as a server from before the engines would send it: no
/// `engines`, and no `engine` on any table.
Map<String, dynamic> _withoutEngines(Map<String, dynamic> body) => {
  for (final e in body.entries)
    if (e.key != 'engines')
      e.key: switch (e.key) {
        'tables' || 'privateTables' => [
          for (final table in e.value as List)
            {
              for (final f in (table as Map<String, dynamic>).entries)
                if (f.key != 'engine') f.key: f.value,
            },
        ],
        _ => e.value,
      },
};

GameConfig _catalogue(Map<String, dynamic> body) =>
    GameConfig.fromCatalogue(body)!;

GameState _state(
  GameConfig config, {
  AppLang lang = AppLang.english,
  // Above the poker tables' 5 Lakh buy-in, so every table is open.
  int chips = 2000000,
}) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = Screen.lobby
    ..config = config
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

/// Every engine's categories and every category's tables, as the lobby would
/// show them inside each.
Map<String, List<String>> _filing(GameState state) => {
  for (final engine in state.lobbyEngines)
    for (final category in state.lobbyCategoriesIn(engine))
      '$engine/$category': [
        for (final table in state.lobbyTablesIn(category, engine: engine))
          '${table.category}:${table.bootAmount}',
      ],
};

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
  // The cards' entrances and the stake's count-up.
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

/// Lets the level's cross-fade and the new cards' entrances run out.
Future<void> _settleLevel(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

/// Taps a card that may be off the end of the rail.
Future<void> _tapInRail(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(target);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

/// A text that reads [name] however it is broken over lines: the back tile
/// stands a name of two words on two lines.
Finder _named(String name) => find.byWidgetPredicate(
  (w) => w is Text && w.data?.replaceAll('\n', ' ') == name,
  skipOffstage: false,
);

void main() {
  group('on the wire', () {
    test('a catalogue names every table\'s engine and lists the engines with '
        'their categories, in the seed\'s order', () {
      final config = _catalogue(catalogueBody());
      for (final table in config.tables) {
        expect(
          table.engine,
          table.isPoker ? TableEngine.poker : TableEngine.teenPatti,
          reason: table.category,
        );
      }
      expect(
        config.privateTables.map((t) => t.engine),
        everyElement(TableEngine.teenPatti),
      );

      expect(config.engines.map((e) => e.code), [
        TableEngine.teenPatti,
        TableEngine.poker,
      ]);
      final teenPatti = config.engines.first;
      expect(teenPatti.name, 'Teen Patti');
      expect(teenPatti.sortOrder, 10);
      expect(teenPatti.categories.map((c) => (c.code, c.name, c.sortOrder)), [
        ('seen', 'Seen', 10),
        ('blind', 'Blind', 20),
        ('variation', 'Variation', 30),
      ]);
      final poker = config.engines.last;
      expect(poker.name, 'Poker');
      expect(poker.sortOrder, 20);
      expect(poker.categories.map((c) => c.code), [
        'three_card_poker',
        'five_card_draw',
        'texas_holdem',
        'omaha',
      ]);
      expect(poker.categories[2].name, "Texas Hold'em");
    });

    test('session:ready carries neither, whatever the server', () {
      final config = GameConfig.fromJson(sessionConfig());
      expect(config.engines, isEmpty);
      expect(config.tables.map((t) => t.engine), everyElement(isNull));
      expect(GameConfig.fallback.engines, isEmpty);
      expect(GameConfig.fallback.tables.map((t) => t.engine), [
        null,
        null,
        null,
      ]);
    });

    test('garbage where the engines go reads as none, and never refuses the '
        'catalogue', () {
      final notAList = GameConfig.fromCatalogue(
        catalogueBody()..['engines'] = 'teen_patti',
      );
      expect(notAList, isNotNull);
      expect(notAList!.engines, isEmpty);

      final mixed = _catalogue(
        catalogueBody()
          ..['engines'] = [
            7,
            {'name': 'No code'},
            {'code': '', 'name': 'Empty code'},
            {
              'code': 'poker',
              'name': 42,
              'sortOrder': 'first',
              'categories': [
                'omaha',
                {'name': 'No code'},
                {'code': 'omaha', 'name': 'Omaha', 'sortOrder': 70},
              ],
            },
            {'code': 'teen_patti', 'categories': 'all'},
          ],
      );
      expect(mixed.engines.map((e) => e.code), ['poker', 'teen_patti']);
      final poker = mixed.engines.first;
      expect(poker.name, '');
      expect(poker.sortOrder, 0);
      expect(poker.categories.map((c) => c.code), ['omaha']);
      expect(mixed.engines.last.categories, isEmpty);

      for (final garbage in [5, '', true]) {
        final table = LobbyTable.fromJson({
          'category': 'seen',
          'bootAmount': 200,
          'maxPot': 0,
          'engine': garbage,
        });
        expect(table.engine, isNull, reason: '$garbage');
      }
    });

    test('a category under the poker engine is a poker table even where the '
        'client has never heard of it', () {
      final table = LobbyTable.fromJson(const {
        'category': 'seven_card_stud',
        'bootAmount': 50000,
        'maxPot': 0,
        'engine': 'poker',
      });
      expect(table.isPoker, isTrue);
      expect(GameState.lobbyEngineOf(table), TableEngine.poker);
      // A game of its own inside Poker, named as the server sends it.
      expect(GameState.lobbyCategoryOf(table), 'seven_card_stud');
    });

    test('a session naming the catalogue held keeps its engines, and copyWith '
        'keeps them unless told otherwise', () {
      final catalogue = _catalogue(catalogueBody());
      final kept = MenuPrecedence.onSession(
        session: GameConfig.fromJson(sessionConfig(minClientBuild: 3)),
        catalogue: catalogue,
      ).config;
      expect(identical(kept.engines, catalogue.engines), isTrue);
      expect(kept.minClientBuild, 3);

      expect(
        identical(catalogue.copyWith().engines, catalogue.engines),
        isTrue,
      );
      expect(catalogue.copyWith(engines: const []).engines, isEmpty);
    });

    test('the phone\'s copy keeps them', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      expect(
        await TableConfigCache.write(catalogueBody(), prefs: prefs),
        isTrue,
      );
      final cached = TableConfigCache.read(prefs);
      expect(cached?.config.engines.map((e) => e.code), [
        TableEngine.teenPatti,
        TableEngine.poker,
      ]);
      expect(cached?.config.tables.first.engine, TableEngine.teenPatti);
    });
  });

  group('the front cards', () {
    test('the seeded taxonomy gives the same engines, categories and tables '
        'whichever source the menu came from', () {
      final withEngines = _state(_catalogue(catalogueBody()));
      final withoutEngines = _state(
        _catalogue(_withoutEngines(catalogueBody())),
      );
      final session = _state(GameConfig.fromJson(sessionConfig()));
      addTearDown(withEngines.dispose);
      addTearDown(withoutEngines.dispose);
      addTearDown(session.dispose);

      for (final state in [withEngines, withoutEngines, session]) {
        expect(state.lobbyEngines, _engines);
        expect(state.lobbyCategoriesIn(TableEngine.teenPatti), _teenPatti);
        expect(state.lobbyCategoriesIn(TableEngine.poker), _poker);
      }
      expect(
        withEngines.lobbyTablesOf(TableEngine.poker).map((t) => t.category),
        ['three_card_poker', 'five_card_draw', 'texas_holdem', 'omaha'],
      );
      expect(_filing(withEngines), _filing(withoutEngines));
      expect(_filing(withEngines), _filing(session));
    });

    test('without engines the lobby files by the fixed taxonomy: its order '
        'whatever the menu\'s, poker under Poker, an unknown category under '
        'Seen', () {
      final body = _withoutEngines(
        _body(extraTables: [_rummyTable(engine: null)]),
      );
      body['tables'] = (body['tables'] as List).reversed.toList();
      final state = _state(_catalogue(body));
      addTearDown(state.dispose);

      expect(state.config.engines, isEmpty);
      expect(state.lobbyEngines, _engines);
      expect(state.lobbyCategoriesIn(TableEngine.teenPatti), _teenPatti);
      expect(state.lobbyCategoriesIn(TableEngine.poker), _poker);
      expect(state.lobbyTablesIn(TableCategory.seen).map((t) => t.category), [
        'points_rummy',
        'seen',
      ]);
      // Nothing to name a card by but the client's own words.
      for (final code in [
        ..._engines,
        ..._teenPatti,
        ..._poker,
        'rummy',
        'points_rummy',
      ]) {
        expect(state.lobbyServerName(code), isNull, reason: code);
        expect(state.lobbyEngineServerName(code), isNull, reason: code);
      }
    });

    test('filing without engines is the rule it always was, under the '
        'engine a table\'s category implies', () {
      LobbyTable table(String category, {String? engine, String game = ''}) =>
          LobbyTable(
            category: category,
            bootAmount: 200,
            maxPot: 0,
            maxBlindMoves: 4,
            game: game,
            engine: engine,
          );
      (String, String) filed(LobbyTable t) =>
          (GameState.lobbyEngineOf(t), GameState.lobbyCategoryOf(t));
      const tp = TableEngine.teenPatti;
      const poker = TableEngine.poker;

      expect(filed(table('blind')), (tp, TableCategory.blind));
      expect(filed(table('texas_holdem')), (poker, 'texas_holdem'));
      expect(filed(table('seven_card_stud', game: 'poker')), (
        poker,
        'seven_card_stud',
      ));
      expect(filed(table('muflis')), (tp, TableCategory.seen));
      // The family's own name is not a category a table can claim.
      expect(filed(table('poker')), (tp, TableCategory.seen));
      expect(filed(table('')), (tp, TableCategory.seen));

      // With an engine: the engine, and the server's own category.
      expect(filed(table('muflis', engine: tp)), (tp, 'muflis'));
      expect(filed(table('', engine: tp)), (tp, TableCategory.seen));
      expect(filed(table('omaha', engine: poker)), (poker, 'omaha'));
      expect(filed(table('points_rummy', engine: 'rummy')), (
        'rummy',
        'points_rummy',
      ));
      // A table with no category of its own goes under its engine's name.
      expect(filed(table('', engine: 'rummy')), ('rummy', 'rummy'));
    });

    test('the categories stand in their sortOrder, not the list\'s', () {
      final engines = defaultEngines();
      final categories = (engines.first['categories'] as List)
          .cast<Map<String, dynamic>>();
      categories.firstWhere((c) => c['code'] == 'variation')['sortOrder'] = 5;
      final pokerGames = (engines.last['categories'] as List)
          .cast<Map<String, dynamic>>();
      pokerGames.firstWhere((c) => c['code'] == 'omaha')['sortOrder'] = 1;
      final state = _state(_catalogue(_body(engines: engines)));
      addTearDown(state.dispose);
      expect(state.lobbyCategoriesIn(TableEngine.teenPatti), [
        TableCategory.variation,
        TableCategory.seen,
        TableCategory.blind,
      ]);
      expect(state.lobbyCategoriesIn(TableEngine.poker), [
        TableCategory.omaha,
        TableCategory.threeCardPoker,
        TableCategory.fiveCardDraw,
        TableCategory.texasHoldem,
      ]);
      expect(state.lobbyEngines, _engines);
    });

    test('the engines stand in their sortOrder: Poker first when the server '
        'puts it first', () {
      final engines = defaultEngines();
      engines.last['sortOrder'] = 5;
      final state = _state(_catalogue(_body(engines: engines)));
      addTearDown(state.dispose);
      expect(state.lobbyEngines, [TableEngine.poker, TableEngine.teenPatti]);
      expect(state.lobbyCategoriesIn(TableEngine.teenPatti), _teenPatti);
    });

    test('equal sortOrders keep the order the server listed them in', () {
      final engines = defaultEngines();
      engines.first['categories'] = [
        {'code': 'blind', 'name': 'Blind', 'sortOrder': 0},
        {'code': 'variation', 'name': 'Variation', 'sortOrder': 0},
        {'code': 'seen', 'name': 'Seen', 'sortOrder': 0},
      ];
      final state = _state(_catalogue(_body(engines: engines)));
      addTearDown(state.dispose);
      expect(state.lobbyCategoriesIn(TableEngine.teenPatti), [
        TableCategory.blind,
        TableCategory.variation,
        TableCategory.seen,
      ]);
    });

    test('a category the server lists but offers no table in has no card', () {
      final state = _state(_catalogue(_body(withVariation: false)));
      addTearDown(state.dispose);
      expect(state.lobbyEngines, _engines);
      expect(state.lobbyCategoriesIn(TableEngine.teenPatti), [
        TableCategory.seen,
        TableCategory.blind,
      ]);
      state.openLobbyCategory(TableCategory.variation);
      expect(state.lobbyCategory, isNull);
    });

    test('an engine this build has never heard of gets a card of its own, in '
        'its place, named by the server, with its categories inside', () {
      final state = _state(
        _catalogue(
          _body(
            engines: [...defaultEngines(), _rummyEngine()],
            extraTables: [_rummyTable()],
          ),
        ),
      );
      addTearDown(state.dispose);

      expect(state.lobbyEngines, [..._engines, 'rummy']);
      expect(state.lobbyCategoriesIn('rummy'), ['points_rummy']);
      expect(state.lobbyTablesIn('points_rummy').map((t) => t.category), [
        'points_rummy',
      ]);
      // Not passed off as a seen table, where a server without engines puts it.
      expect(state.lobbyTablesIn(TableCategory.seen).map((t) => t.category), [
        'seen',
      ]);
      expect(state.lobbyEngineServerName('rummy'), 'Rummy');
      expect(state.lobbyServerName('points_rummy'), 'Points Rummy');
      // The known cards have names of the server's too; the lobby keeps its
      // own words for them.
      expect(state.lobbyEngineServerName(TableEngine.poker), 'Poker');
      expect(state.lobbyEngineServerName(TableEngine.teenPatti), 'Teen Patti');
      expect(state.lobbyServerName(TableCategory.texasHoldem), "Texas Hold'em");

      state.openLobbyEngine('rummy');
      expect(state.lobbyEngine, 'rummy');
      state.openLobbyCategory('points_rummy');
      expect(state.lobbyEngine, 'rummy');
      expect(state.lobbyCategory, 'points_rummy');

      // Placed where its sortOrder says, not merely last.
      final first = _state(
        _catalogue(
          _body(
            engines: [...defaultEngines(), _rummyEngine(sortOrder: 1)],
            extraTables: [_rummyTable()],
          ),
        ),
      );
      addTearDown(first.dispose);
      expect(first.lobbyEngines, ['rummy', ..._engines]);
    });

    test('a Teen Patti category this build has never heard of is a card of '
        'its own, between its neighbours', () {
      final engines = defaultEngines();
      (engines.first['categories'] as List).add({
        'code': 'muflis',
        'name': 'Muflis',
        'sortOrder': 25,
      });
      final state = _state(
        _catalogue(
          _body(
            engines: engines,
            extraTables: [
              {
                'category': 'muflis',
                'bootAmount': 5000,
                'maxPot': 0,
                'engine': TableEngine.teenPatti,
              },
            ],
          ),
        ),
      );
      addTearDown(state.dispose);
      expect(state.lobbyEngines, _engines);
      expect(state.lobbyCategoriesIn(TableEngine.teenPatti), [
        TableCategory.seen,
        TableCategory.blind,
        'muflis',
        TableCategory.variation,
      ]);
      expect(state.lobbyTablesIn('muflis').map((t) => t.bootAmount), [5000]);
      expect(state.lobbyServerName('muflis'), 'Muflis');
    });

    test('a table naming an engine the list leaves out keeps its card, after '
        'the rest', () {
      final state = _state(_catalogue(_body(extraTables: [_rummyTable()])));
      addTearDown(state.dispose);
      expect(state.lobbyEngines, [..._engines, 'rummy']);
      expect(state.lobbyTablesOf('rummy'), hasLength(1));
      expect(state.lobbyCategoriesIn('rummy'), ['points_rummy']);
      expect(state.lobbyEngineServerName('rummy'), isNull);
    });
  });

  group('on screen', () {
    setUpAll(_loadInter);

    for (final lang in [AppLang.english, AppLang.hindi]) {
      testWidgets('in ${lang.englishName} the cards it knows keep their own '
          'words and an unknown engine\'s card is the server\'s', (
        tester,
      ) async {
        // The new family FIRST, where the server's sortOrder puts it — which
        // also keeps its card on screen, the rail being built lazily.
        final state = _state(
          _catalogue(
            _body(
              engines: [...defaultEngines(), _rummyEngine(sortOrder: 1)],
              extraTables: [_rummyTable()],
            ),
          ),
          lang: lang,
        );
        final t = Strings(lang);
        await _pumpLobby(tester, state, screen: const Size(891, 411));
        expect(tester.takeException(), isNull);
        expect(state.lobbyEngines, ['rummy', ..._engines]);

        // The new family's card is the server's word; the ones beside it are
        // still the player's own.
        expect(find.text('Rummy'), findsOneWidget);
        expect(find.text(t.teenPatti), findsOneWidget);
        expect(find.text(t.poker, skipOffstage: false), findsOneWidget);
        // The server's admin labels are never what a known card says.
        for (final label in ['Poker', 'Teen Patti', 'Seen', 'Blind']) {
          expect(find.text(label, skipOffstage: false), findsNothing);
        }

        // Into it: its one category, in the server's words.
        await _tapInRail(tester, find.text(t.viewGames).first);
        await _settleLevel(tester);
        expect(tester.takeException(), isNull);
        expect(state.lobbyEngine, 'rummy');
        expect(find.text('Rummy', skipOffstage: false), findsOneWidget);
        expect(find.text('Points Rummy', skipOffstage: false), findsOneWidget);

        await _tapInRail(tester, find.text(t.viewTables).first);
        await _settleLevel(tester);
        expect(tester.takeException(), isNull);
        expect(state.lobbyCategory, 'points_rummy');
        // The way back names where the player is and where it goes; the
        // table's badge names its category, all in the server's words.
        expect(find.text('Rummy', skipOffstage: false), findsOneWidget);
        expect(_named('Points Rummy'), findsNWidgets(2));
        expect(find.text(t.tapToSit, skipOffstage: false), findsOneWidget);

        await _unmount(tester);
        state.dispose();
      });
    }

    testWidgets('without engines the front is Teen Patti and Poker, and Teen '
        'Patti holds its three categories', (tester) async {
      final state = _state(_catalogue(_withoutEngines(catalogueBody())));
      const t = Strings(AppLang.english);
      await _pumpLobby(tester, state, screen: const Size(891, 411));
      expect(tester.takeException(), isNull);
      expect(find.text(t.viewGames, skipOffstage: false), findsNWidgets(2));
      for (final name in [t.teenPatti, t.poker]) {
        expect(find.text(name, skipOffstage: false), findsOneWidget);
      }
      state.openLobbyEngine(TableEngine.teenPatti);
      await _settleLevel(tester);
      expect(tester.takeException(), isNull);
      expect(find.text(t.viewTables, skipOffstage: false), findsNWidgets(3));
      for (final name in [t.seen, t.blind, t.variation]) {
        expect(find.text(name, skipOffstage: false), findsOneWidget);
      }
      await _unmount(tester);
      state.dispose();
    });
  });
}
