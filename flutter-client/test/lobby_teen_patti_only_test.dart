// The lobby of the default build: Teen Patti only (owner, 27 Sep 2026: "do
// this change in UI only, remove poker category and In UI only show three
// cards seen, blind, variation").
//
// The switch is the app's alone (AppFeatures.poker, SHOW_POKER, off by
// default). The server still offers its poker tables, in `session:ready` and
// in `GET /api/tables`, so every test here runs on a menu that HAS them: the
// front shows Seen, Blind and Variation and then the private card, with no
// engine card and no poker word; a category's tables stand behind a tile that
// says "All games" and leads back to the front in one step; the record's
// switch is All · Teen Patti · Variation; the general rules sheet has no
// poker section. With the switch on, the engines are back — the three-level
// lobby is held by lobby_categories_test.dart and table_engines_test.dart.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/config/features.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/models/player_stats.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/game_card.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/rules_sheet.dart';

import 'script_fonts.dart';
import 'table_config_fixture.dart';

// ------------------------------------------------------------------ menus

/// The catalogue as `GET /api/tables` serves it: the engines named, the
/// seven Teen Patti tables and the four poker ones.
GameConfig _catalogue() => GameConfig.fromCatalogue(catalogueBody())!;

/// A session menu as `session:ready` carries it, with no engines named: the
/// lobby files the poker tables by their `game`.
GameConfig _sessionMenu() => GameConfig.fromJson({
  'maxPlayers': 5,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'tables': [
    {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
    {'category': 'blind', 'bootAmount': 200, 'maxChips': 2000000},
    {'category': 'blind', 'bootAmount': 5000, 'maxChips': 200000000},
    {'category': 'variation', 'bootAmount': 50000, 'maxChips': 2000000000},
    for (final category in TableCategory.pokerCategories)
      {
        'category': category,
        'bootAmount': 50000,
        'minChips': 500000,
        'game': 'poker',
      },
  ],
});

GameState _state({
  GameConfig? config,
  AppLang lang = AppLang.english,
  int chips = 3000000,
}) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = Screen.lobby
    ..config = config ?? _catalogue()
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

// ----------------------------------------------------------------- pumping

Future<void> _pump(
  WidgetTester tester,
  GameState state,
  Widget home, {
  Size screen = const Size(891, 411),
  double textScale = 1.0,
  Brightness brightness = Brightness.dark,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  final theme = brightness == Brightness.dark
      ? AppTheme.dark(sound: false)
      : AppTheme.light(sound: false);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        // The phone's Noto fonts behind Inter, so a Hindi card is laid out
        // with Hindi glyph widths.
        theme: withScriptFallback(theme),
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: 0.9,
          maxScaleFactor: 1.25,
          child: GlassBudget(child: child!),
        ),
        home: home,
      ),
    ),
  );
  await _settle(tester);
}

/// The cards' entrances, a level's transition and the stakes' count-up.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

/// The rail on show, whatever level it holds.
final _rail = find.byWidgetPredicate(
  (w) =>
      w is ListView &&
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('lobby-rail:'),
);

String _railLevel(WidgetTester tester) =>
    (tester.widget<ListView>(_rail).key! as ValueKey<String>).value;

Rect _onScreen(RenderBox box) =>
    MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);

/// Every line of text on screen.
List<String> _allText(WidgetTester tester) => [
  for (final e in find.byType(RichText, skipOffstage: false).evaluate())
    (e.widget as RichText).text.toPlainText(),
];

/// Every word that would say Poker, in [t]'s language and in English.
List<String> _pokerWords(Strings t) => {
  t.poker,
  friendlyName(t.poker),
  t.pokerTableNote,
  for (final category in TableCategory.pokerCategories) ...[
    t.pokerVariantName(category),
    t.pokerVariantNote(category),
  ],
  'Poker',
  'POKER',
  "Hold'em",
  'Omaha',
}.where((w) => w.isNotEmpty).toList();

void _expectNoPoker(WidgetTester tester, Strings t, String where) {
  for (final line in _allText(tester)) {
    for (final word in _pokerWords(t)) {
      expect(
        line.contains(word),
        isFalse,
        reason: '$where: "$line" names poker ("$word")',
      );
    }
  }
}

/// The name each card on the rail leads with, left to right: the largest
/// words on it.
List<String> _railCardNames(WidgetTester tester, Strings t) {
  final names = [t.seen, t.blind, t.variation, t.privateTable, t.teenPatti];
  final found = <(double, String)>[];
  for (final name in names) {
    for (final e
        in find
            .descendant(
              of: _rail,
              matching: find.text(name, skipOffstage: false),
            )
            .evaluate()) {
      final box = e.renderObject! as RenderBox;
      found.add((_onScreen(box).left, name));
    }
  }
  found.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final (_, name) in found) name];
}

// --------------------------------------------------------------------- main

void main() {
  setUpAll(loadScriptFonts);
  setUp(() => SharedPreferences.setMockInitialValues({'soundOn': false}));
  tearDown(() => AppFeatures.poker = false);

  test('the Poker family is off unless the build says SHOW_POKER', () {
    expect(AppFeatures.poker, isFalse);
    expect(const bool.fromEnvironment('SHOW_POKER'), isFalse);
  });

  for (final (source, menu) in [
    ('GET /api/tables', _catalogue),
    ('session:ready', _sessionMenu),
  ]) {
    group('on a $source menu with poker tables', () {
      test('the menu still holds the server\'s poker tables, and the lobby '
          'shows none of them', () {
        final state = _state(config: menu());
        addTearDown(state.dispose);
        // Untouched: the wire's menu is the server's.
        expect(state.config.tables.where((t) => t.isPoker), hasLength(4));
        expect(state.lobbyEngines, [TableEngine.teenPatti]);
        expect(state.lobbyFrontEngine, TableEngine.teenPatti);
        expect(state.lobbyCategoriesIn(TableEngine.teenPatti), [
          TableCategory.seen,
          TableCategory.blind,
          TableCategory.variation,
        ]);
        expect(state.lobbyCategoriesIn(TableEngine.poker), isEmpty);
        expect(state.lobbyTablesOf(TableEngine.poker), isEmpty);
        expect(
          state.lobbyTablesOf(TableEngine.teenPatti),
          hasLength(state.config.tables.length - 4),
        );
        for (final category in TableCategory.pokerCategories) {
          expect(state.lobbyTablesIn(category), isEmpty);
        }
        for (final category in [
          TableCategory.seen,
          TableCategory.blind,
          TableCategory.variation,
        ]) {
          final tables = state.lobbyTablesIn(category);
          expect(tables, isNotEmpty);
          expect(tables.every((t) => t.category == category), isTrue);
        }
      });

      test('a poker category or the Poker engine never opens, and Teen '
          'Patti\'s categories ARE the front', () {
        final state = _state(config: menu());
        addTearDown(state.dispose);
        state.openLobbyCategory(TableCategory.texasHoldem);
        expect(state.lobbyEngine, isNull);
        expect(state.lobbyCategory, isNull);
        state.openLobbyEngine(TableEngine.poker);
        expect(state.lobbyEngine, isNull);
        state.openLobbyEngine(TableEngine.teenPatti);
        expect(state.lobbyEngine, isNull, reason: 'the front already is');
        expect(state.lobbyCategory, isNull);
      });

      test('Back closes a category to the front in one step, then answers '
          'false so the quit question comes next', () {
        final state = _state(config: menu());
        addTearDown(state.dispose);
        state.openLobbyCategory(TableCategory.blind);
        expect(state.lobbyEngine, TableEngine.teenPatti);
        expect(state.lobbyCategory, TableCategory.blind);
        expect(state.closeLobbyLevel(), isTrue);
        expect(state.lobbyCategory, isNull);
        expect(state.lobbyEngine, isNull);
        expect(state.closeLobbyLevel(), isFalse);
      });

      test('with the Poker family the engines are back', () {
        AppFeatures.poker = true;
        final state = _state(config: menu());
        addTearDown(state.dispose);
        expect(state.lobbyEngines, [TableEngine.teenPatti, TableEngine.poker]);
        expect(state.lobbyFrontEngine, isNull);
        expect(state.lobbyTablesOf(TableEngine.poker), hasLength(4));
        state.openLobbyCategory(TableCategory.blind);
        expect(state.closeLobbyLevel(), isTrue);
        expect(state.lobbyEngine, TableEngine.teenPatti);
        expect(state.closeLobbyLevel(), isTrue);
        expect(state.lobbyEngine, isNull);
        expect(state.closeLobbyLevel(), isFalse);
      });
    });
  }

  test('a menu that drops the open category steps back to the front; a '
      'category the new menu keeps stays open', () {
    final state = _state();
    addTearDown(state.dispose);
    state.openLobbyCategory(TableCategory.variation);
    state.handleCatalogue(
      GameConfig.fromCatalogue(
        catalogueBody(version: versionB, withVariation: false),
      )!,
    );
    expect(state.lobbyCategory, isNull);
    expect(state.lobbyEngine, isNull);

    state.openLobbyCategory(TableCategory.blind);
    state.handleCatalogue(GameConfig.fromCatalogue(catalogueBody())!);
    expect(state.lobbyCategory, TableCategory.blind);
    expect(state.lobbyEngine, TableEngine.teenPatti);
  });

  test('signing out returns the lobby to the front', () async {
    final state = _state();
    addTearDown(state.dispose);
    state.openLobbyCategory(TableCategory.blind);
    await state.signOut();
    expect(state.lobbyCategory, isNull);
    expect(state.lobbyEngine, isNull);
  });

  test('a category is still open after a visit to a table, and Back from '
      'it is still the front in one step', () {
    final state = _state();
    addTearDown(state.dispose);
    state.openLobbyCategory(TableCategory.blind);
    state.screen = Screen.table;
    state.screen = Screen.lobby;
    expect(state.lobbyEngine, TableEngine.teenPatti);
    expect(state.lobbyCategory, TableCategory.blind);
    expect(state.closeLobbyLevel(), isTrue);
    expect(state.lobbyCategory, isNull);
    expect(state.lobbyEngine, isNull);
    expect(state.closeLobbyLevel(), isFalse);
  });

  test('the front and a category\'s tables are sized together: one side at '
      'which both stop on whole cards and a glimpse', () {
    // A 891x411 phone's rail: alone, the front (four cards, no way back)
    // would take 263 and the tables (the way back and four cards) 238.
    const fit = 269.6, width = 891.0;
    final front = lobbyRailSide(
      fit: fit,
      width: width,
      cards: 4,
      backTile: false,
      also: (cards: 4, backTile: true),
    );
    final tables = lobbyRailSide(
      fit: fit,
      width: width,
      cards: 4,
      backTile: true,
      also: (cards: 4, backTile: false),
    );
    expect(front, tables);
    expect(
      front,
      lessThan(
        lobbyRailSide(fit: fit, width: width, cards: 4, backTile: false),
      ),
    );
    // Where no side at or above the floor suits both, both keep what the
    // height allows — still one size.
    expect(
      lobbyRailSide(
        fit: 227,
        width: 640,
        cards: 4,
        backTile: false,
        also: (cards: 4, backTile: true),
      ),
      lobbyRailSide(
        fit: 227,
        width: 640,
        cards: 4,
        backTile: true,
        also: (cards: 4, backTile: false),
      ),
    );
  });

  testWidgets('the front is Seen, Blind, Variation, then the private card — '
      'no engine card and no poker word', (tester) async {
    final state = _state();
    addTearDown(state.dispose);
    await _pump(tester, state, const LobbyScreen());
    final t = state.t;
    expect(tester.takeException(), isNull);
    expect(_railLevel(tester), 'lobby-rail:');
    expect(_railCardNames(tester, t), [
      t.seen,
      t.blind,
      t.variation,
      t.privateTable,
    ]);
    // An engine card's key and name are nowhere; each category card has its
    // own key.
    expect(find.text(t.viewGames, skipOffstage: false), findsNothing);
    expect(find.text(t.teenPatti, skipOffstage: false), findsNothing);
    expect(find.text(t.viewTables, skipOffstage: false), findsNWidgets(3));
    expect(
      find.descendant(of: _rail, matching: find.byType(GameCard)),
      findsNWidgets(4),
    );
    _expectNoPoker(tester, t, 'front');
    await _unmount(tester);
  });

  testWidgets('Blind opens on its own tables behind a tile that says "All '
      'games", and the tile goes back to the front', (tester) async {
    final state = _state(chips: 300000);
    addTearDown(state.dispose);
    await _pump(tester, state, const LobbyScreen());
    final t = state.t;

    final blindCard = find.ancestor(
      of: find.text(t.blind),
      matching: find.byType(GameCard),
    );
    await tester.tap(
      find.descendant(of: blindCard, matching: find.text(t.viewTables)),
    );
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(state.lobbyCategory, TableCategory.blind);
    expect(_railLevel(tester), 'lobby-rail:teen_patti:blind');
    // The back tile, then one card per blind table and no other.
    expect(find.text(t.backToCategories), findsOneWidget);
    final tables = state.lobbyTablesIn(
      TableCategory.blind,
      engine: TableEngine.teenPatti,
    );
    expect(tables.every((table) => table.category == 'blind'), isTrue);
    expect(
      find.descendant(
        of: _rail,
        matching: find.byType(GameCard, skipOffstage: false),
      ),
      findsNWidgets(tables.length + 1),
    );
    expect(find.text(t.seen, skipOffstage: false), findsNothing);
    expect(find.text(t.variation, skipOffstage: false), findsNothing);
    _expectNoPoker(tester, t, 'blind');

    await tester.tap(find.text(t.backToCategories));
    await _settle(tester);
    expect(state.lobbyCategory, isNull);
    expect(state.lobbyEngine, isNull);
    expect(_railLevel(tester), 'lobby-rail:');
    expect(_railCardNames(tester, t), [
      t.seen,
      t.blind,
      t.variation,
      t.privateTable,
    ]);
    await _unmount(tester);
  });

  for (final screen in const [
    Size(640, 360),
    Size(732, 412),
    Size(844, 390),
    Size(891, 411),
    Size(915, 412),
    Size(1280, 800),
  ]) {
    testWidgets('at ${screen.width.toInt()}x${screen.height.toInt()} the '
        'category cards on the front and the tables behind them are one size', (
      tester,
    ) async {
      final state = _state();
      addTearDown(state.dispose);
      await _pump(tester, state, const LobbyScreen(), screen: screen);
      final cards = find.descendant(of: _rail, matching: find.byType(GameCard));
      final front = tester.getSize(cards.first).width;
      state.openLobbyCategory(TableCategory.blind);
      await _settle(tester);
      expect(_railLevel(tester), 'lobby-rail:teen_patti:blind');
      // The first GameCard is the way back; the second is a table.
      final table = tester.getSize(cards.at(1)).width;
      expect(table, closeTo(front, 0.01));
      await _unmount(tester);
    });
  }

  testWidgets('with the Poker family the two engine cards are back', (
    tester,
  ) async {
    AppFeatures.poker = true;
    final state = _state();
    addTearDown(state.dispose);
    await _pump(tester, state, const LobbyScreen());
    final t = state.t;
    expect(find.text(t.viewGames, skipOffstage: false), findsNWidgets(2));
    expect(find.text(t.teenPatti, skipOffstage: false), findsOneWidget);
    expect(find.text(t.poker, skipOffstage: false), findsOneWidget);
    expect(find.text(t.viewTables, skipOffstage: false), findsNothing);
    await _unmount(tester);
  });

  for (final poker in [false, true]) {
    testWidgets(
      poker
          ? 'with the Poker family the record\'s switch has four keys'
          : 'the record\'s switch is All over Teen Patti and Variation, with '
                'no Poker',
      (tester) async {
        AppFeatures.poker = poker;
        final state = _state();
        addTearDown(state.dispose);
        await _pump(
          tester,
          state,
          const LobbyScreen(),
          screen: const Size(640, 360),
          textScale: 1.25,
        );
        await tester.tap(find.byIcon(Icons.insights_outlined).first);
        await _settle(tester);
        expect(tester.takeException(), isNull);
        final t = state.t;
        final shown = [
          for (final view in StatsCategory.values)
            if (find
                .byKey(ValueKey('stats-category-${view.name}'))
                .evaluate()
                .isNotEmpty)
              view,
        ];
        expect(shown, [
          StatsCategory.all,
          StatsCategory.teenPatti,
          StatsCategory.variation,
          if (poker) StatsCategory.poker,
        ]);
        if (!poker) {
          expect(find.text(friendlyName(t.poker)), findsNothing);
          // A drawer too narrow for three across: All takes the top row
          // whole, the two games share the one under it.
          Rect key(StatsCategory v) =>
              tester.getRect(find.byKey(ValueKey('stats-category-${v.name}')));
          final track = tester.getRect(
            find.byKey(const ValueKey('stats-categories')),
          );
          final all = key(StatsCategory.all);
          final teenPatti = key(StatsCategory.teenPatti);
          final variation = key(StatsCategory.variation);
          if (all.top == teenPatti.top) {
            // One row: three across.
            expect(variation.top, all.top);
          } else {
            expect(all.width, greaterThan(track.width - 8));
            expect(teenPatti.top, variation.top);
            expect(teenPatti.top, greaterThan(all.bottom - 0.5));
            expect(
              teenPatti.width + variation.width,
              greaterThan(track.width - 12),
            );
          }
        }
        await _unmount(tester);
      },
    );
  }

  for (final poker in [false, true]) {
    testWidgets(
      poker
          ? 'with the Poker family the general rules sheet has the poker '
                'section'
          : 'the general rules sheet has no poker section',
      (tester) async {
        AppFeatures.poker = poker;
        final state = _state();
        addTearDown(state.dispose);
        await _pump(
          tester,
          state,
          Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showRules(context),
                child: const Text('rules'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('rules'));
        await _settle(tester);
        final t = state.t;
        expect(find.text(t.rankTrail, skipOffstage: false), findsOneWidget);
        expect(
          find.text(t.variationRulesTitle, skipOffstage: false),
          findsOneWidget,
        );
        final pokerParts = [
          t.pokerRulesTitle,
          t.pokerRulesIntro,
          t.pokerRankName('royalFlush'),
          t.pokerRankName('fullHouse'),
        ];
        for (final part in pokerParts) {
          expect(
            find.text(part, skipOffstage: false),
            poker ? findsOneWidget : findsNothing,
            reason: part,
          );
        }
        if (!poker) _expectNoPoker(tester, t, 'rules');
        await _unmount(tester);
      },
    );
  }

  // The tightest phone the app is checked on, at the largest text it allows,
  // in every language, by night and by day: the front and a category's
  // tables lay out with nothing thrown and no card's words cut short.
  for (final brightness in Brightness.values) {
    for (final lang in AppLang.values) {
      testWidgets('at 640x360 x1.25 in ${lang.name} (${brightness.name}) the '
          'front and Blind\'s tables fit', (tester) async {
        final state = _state(lang: lang, chips: 300000);
        addTearDown(state.dispose);
        await _pump(
          tester,
          state,
          const LobbyScreen(),
          screen: const Size(640, 360),
          textScale: 1.25,
          brightness: brightness,
        );
        final t = state.t;
        for (final level in ['front', 'blind']) {
          if (level == 'blind') {
            state.openLobbyCategory(TableCategory.blind);
            await _settle(tester);
          }
          expect(tester.takeException(), isNull, reason: level);
          if (level == 'front') {
            expect(_railCardNames(tester, t).take(3), [
              t.seen,
              t.blind,
              t.variation,
            ]);
          }
          // Every card's words, at the rail's start and at its end: a phone
          // this narrow builds only the cards near the screen.
          final scroll = tester.state<ScrollableState>(
            find.descendant(of: _rail, matching: find.byType(Scrollable)).first,
          );
          for (final end in [false, true]) {
            if (end) {
              scroll.position.jumpTo(scroll.position.maxScrollExtent);
              await tester.pump();
              if (level == 'front') {
                expect(_railCardNames(tester, t).last, t.privateTable);
              }
            }
            final words = find.descendant(
              of: find.byType(CardColumn, skipOffstage: false),
              matching: find.byType(RichText, skipOffstage: false),
            );
            expect(words, findsWidgets);
            for (final e in words.evaluate()) {
              final paragraph = e.renderObject! as RenderParagraph;
              expect(
                paragraph.didExceedMaxLines,
                isFalse,
                reason: '$level: "${paragraph.text.toPlainText()}" cut short',
              );
            }
          }
          scroll.position.jumpTo(0);
          await tester.pump();
          _expectNoPoker(tester, t, level);
        }
        await _unmount(tester);
      });
    }
  }
}
