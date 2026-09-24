// The lobby's levels.
//
// 18 Sep 2026 (owner): "In lobby give 3 category: Seen, Blind, Variation. When
// the user selects Blind then go into that and show all the Blind table cards
// — 200, 5000, 50000, 10L." And, later the same day: "in variation keep only
// two tables, 50000 and 10 Lakh", with no pot limit on either.
//
// 23 Sep 2026 (owner): "IN UI also give two cards: Teen Patti and Poker.
// inside TeenPatti give seen, blind and variation. Inside poker give three
// card poker, five card draw, texas holdem, omaha".
//
// So three levels in one rail: the ENGINES the server offers a table in, then
// the private card; inside an engine its CATEGORIES behind a tile that leads
// back; inside a category its TABLES behind another. Which engines, categories
// and tables is the server's menu — the lobby draws whatever `config.tables`
// lists, so an older server with a shorter menu is still a lobby a player can
// use. The poker side is held by poker_lobby_test.dart.
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
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/chip_shuffle.dart';
import 'package:teenpatti/widgets/game_card.dart';
import 'package:teenpatti/widgets/poker_chip.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

/// The Teen Patti part of the server's default menu: one seen table, blind at
/// four stakes, and variation at the top two of them, uncapped.
const _menu = <Map<String, Object>>[
  {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
  {'category': 'blind', 'bootAmount': 200, 'maxChips': 500000},
  {'category': 'blind', 'bootAmount': 5000, 'maxChips': 50000000},
  {'category': 'blind', 'bootAmount': 50000, 'maxChips': 1000000000},
  {'category': 'blind', 'bootAmount': 1000000, 'minChips': 500000000},
  {'category': 'variation', 'bootAmount': 50000, 'maxChips': 1000000000},
  {'category': 'variation', 'bootAmount': 1000000, 'minChips': 500000000},
];

/// One table of a poker game, as a session menu lists it.
Map<String, Object> _poker(String category) => {
  'category': category,
  'bootAmount': 50000,
  'maxPot': 0,
  'maxBlindMoves': 0,
  'minChips': 500000,
  'game': 'poker',
};

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
  int chips = 300000,
  AppLang lang = AppLang.english,
  List<Map<String, Object>> tables = _menu,
}) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
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
  Brightness brightness = Brightness.dark,
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
        theme: brightness == Brightness.dark
            ? AppTheme.dark(sound: false)
            : AppTheme.light(sound: false),
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

/// Taps a card that may be off the end of the rail on a narrow phone.
Future<void> _tapInRail(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(target);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

/// The rail on screen, by its key: `lobby-rail:` at the front,
/// `lobby-rail:<engine>` inside an engine, `lobby-rail:<engine>:<category>`
/// inside a category.
Finder _rail(String level) =>
    find.byKey(ValueKey('lobby-rail:$level'), skipOffstage: false);

/// A text that reads [name] however it is broken over lines: the back tile
/// stands a name of two words on two lines.
Finder _named(String name) => find.byWidgetPredicate(
  (w) => w is Text && w.data?.replaceAll('\n', ' ') == name,
  skipOffstage: false,
);

void main() {
  setUpAll(_loadInter);

  group('the engines', () {
    test('are Teen Patti then Poker, whatever order the menu is in', () {
      final state = _state(
        tables: [
          _poker('omaha'),
          ..._menu.reversed,
          _poker('three_card_poker'),
        ],
      );
      addTearDown(state.dispose);
      expect(state.lobbyEngines, [TableEngine.teenPatti, TableEngine.poker]);
    });

    test('are only the ones the server offers a table in', () {
      final state = _state();
      addTearDown(state.dispose);
      expect(state.lobbyEngines, [TableEngine.teenPatti]);
      expect(state.lobbyCategoriesIn(TableEngine.poker), isEmpty);
      expect(state.lobbyTablesOf(TableEngine.poker), isEmpty);

      // And one the server does not offer cannot be gone into.
      state.openLobbyEngine(TableEngine.poker);
      expect(state.lobbyEngine, isNull);

      final pokerOnly = _state(tables: [_poker('texas_holdem')]);
      addTearDown(pokerOnly.dispose);
      expect(pokerOnly.lobbyEngines, [TableEngine.poker]);
    });

    test('count every table of theirs', () {
      final state = _state(tables: [..._menu, _poker('omaha')]);
      addTearDown(state.dispose);
      expect(state.lobbyTablesOf(TableEngine.teenPatti), hasLength(7));
      expect(state.lobbyTablesOf(TableEngine.poker).map((t) => t.category), [
        'omaha',
      ]);
    });
  });

  group('the categories', () {
    test('inside Teen Patti are Seen, Blind, Variation, whatever order the '
        'menu is in', () {
      final state = _state(tables: _menu.reversed.toList());
      addTearDown(state.dispose);
      expect(state.lobbyCategoriesIn(TableEngine.teenPatti), [
        TableCategory.seen,
        TableCategory.blind,
        TableCategory.variation,
      ]);
    });

    test('are only the ones the server offers a table in', () {
      final state = _state(
        tables: [
          {'category': 'seen', 'bootAmount': 200},
          {'category': 'blind', 'bootAmount': 200},
          {'category': 'blind', 'bootAmount': 5000},
        ],
      );
      addTearDown(state.dispose);
      expect(state.lobbyCategoriesIn(TableEngine.teenPatti), [
        TableCategory.seen,
        TableCategory.blind,
      ]);
      expect(state.lobbyTablesIn(TableCategory.variation), isEmpty);

      // And one the server does not offer cannot be gone into — nor does
      // trying open its engine.
      state.openLobbyCategory(TableCategory.variation);
      expect(state.lobbyCategory, isNull);
      expect(state.lobbyEngine, isNull);
    });

    test('file a category this build has never heard of under Seen', () {
      final state = _state(
        tables: [
          {'category': 'seen', 'bootAmount': 200},
          {'category': 'royal', 'bootAmount': 5000},
        ],
      );
      addTearDown(state.dispose);
      expect(state.lobbyEngines, [TableEngine.teenPatti]);
      expect(state.lobbyCategoriesIn(TableEngine.teenPatti), [
        TableCategory.seen,
      ]);
      expect(state.lobbyTablesIn(TableCategory.seen).map((t) => t.bootAmount), [
        200,
        5000,
      ]);
    });

    test(
      'hold their tables in the order of the stakes, the shut ones last',
      () {
        // 3 Lakh: under the blind 200 table's 5 Lakh ceiling, short of the
        // 10 Lakh table's 50 Crore floor.
        final state = _state(chips: 300000);
        addTearDown(state.dispose);
        expect(
          state.lobbyTablesIn(TableCategory.blind).map((t) => t.bootAmount),
          [200, 5000, 50000, 1000000],
        );
        expect(
          state.lobbyTablesIn(TableCategory.variation).map((t) => t.bootAmount),
          [50000, 1000000],
        );
        expect(
          state.lobbyTablesIn(TableCategory.seen).map((t) => t.bootAmount),
          [200],
        );
        // The engine named, the same answer.
        expect(
          state
              .lobbyTablesIn(TableCategory.blind, engine: TableEngine.teenPatti)
              .map((t) => t.bootAmount),
          [200, 5000, 50000, 1000000],
        );
        expect(
          state.lobbyTablesIn(TableCategory.blind, engine: TableEngine.poker),
          isEmpty,
        );

        // 60 Crore has outgrown the two cheapest blind tables, which go last,
        // still in the order of their stakes.
        final rich = _state(chips: 600000000);
        addTearDown(rich.dispose);
        expect(
          rich.lobbyTablesIn(TableCategory.blind).map((t) => t.bootAmount),
          [50000, 1000000, 200, 5000],
        );
      },
    );
  });

  group('the levels', () {
    test('open one at a time, and Back closes the deepest first', () {
      final state = _state();
      addTearDown(state.dispose);
      var notified = 0;
      state.addListener(() => notified++);

      expect(state.lobbyEngine, isNull);
      expect(state.lobbyCategory, isNull);
      expect(state.closeLobbyLevel(), isFalse, reason: 'nothing was open');
      expect(notified, 0);

      state.openLobbyEngine(TableEngine.teenPatti);
      expect(state.lobbyEngine, TableEngine.teenPatti);
      expect(state.lobbyCategory, isNull);
      expect(notified, 1);
      state.openLobbyEngine(TableEngine.teenPatti);
      expect(notified, 1, reason: 'already there');

      state.openLobbyCategory(TableCategory.blind);
      expect(state.lobbyEngine, TableEngine.teenPatti);
      expect(state.lobbyCategory, TableCategory.blind);
      expect(notified, 2);
      state.openLobbyCategory(TableCategory.blind);
      expect(notified, 2, reason: 'already there');

      // Back: the category first, then the engine, then nothing.
      expect(state.closeLobbyLevel(), isTrue);
      expect(state.lobbyCategory, isNull);
      expect(state.lobbyEngine, TableEngine.teenPatti);
      expect(notified, 3);
      expect(state.closeLobbyLevel(), isTrue);
      expect(state.lobbyEngine, isNull);
      expect(notified, 4);
      expect(state.closeLobbyLevel(), isFalse);
      expect(notified, 4);
    });

    test('a category opened from the front opens its engine too, so Back '
        'goes through the engine', () {
      final state = _state(tables: [..._menu, _poker('omaha')]);
      addTearDown(state.dispose);
      state.openLobbyCategory(TableCategory.omaha);
      expect(state.lobbyEngine, TableEngine.poker);
      expect(state.lobbyCategory, TableCategory.omaha);

      // Straight across to another engine's category.
      state.openLobbyCategory(TableCategory.variation);
      expect(state.lobbyEngine, TableEngine.teenPatti);
      expect(state.lobbyCategory, TableCategory.variation);

      // A category named with the wrong engine is not opened.
      state.openLobbyCategory(
        TableCategory.omaha,
        engine: TableEngine.teenPatti,
      );
      expect(state.lobbyCategory, TableCategory.variation);

      expect(state.closeLobbyLevel(), isTrue);
      expect(state.lobbyEngine, TableEngine.teenPatti);
      expect(state.closeLobbyLevel(), isTrue);
      expect(state.lobbyEngine, isNull);
    });

    test(
      'opening an engine from inside a category starts at its categories',
      () {
        final state = _state(tables: [..._menu, _poker('omaha')]);
        addTearDown(state.dispose);
        state.openLobbyCategory(TableCategory.blind);
        state.openLobbyEngine(TableEngine.poker);
        expect(state.lobbyEngine, TableEngine.poker);
        expect(state.lobbyCategory, isNull);
      },
    );

    test('are still open after a visit to a table', () {
      final state = _state();
      addTearDown(state.dispose);
      state.openLobbyCategory(TableCategory.variation);
      state.screen = Screen.table;
      state.screen = Screen.lobby;
      expect(state.lobbyEngine, TableEngine.teenPatti);
      expect(state.lobbyCategory, TableCategory.variation);
    });

    test('are forgotten when the player signs out', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final state = _state();
      addTearDown(state.dispose);
      state.openLobbyCategory(TableCategory.blind);
      await state.signOut();
      expect(state.lobbyEngine, isNull);
      expect(state.lobbyCategory, isNull);
    });

    test('a menu that drops the open category leaves the player in its '
        'engine; one that drops the engine, at the front', () {
      final state = _state(tables: [..._menu, _poker('omaha')]);
      addTearDown(state.dispose);

      state.openLobbyCategory(TableCategory.variation);
      state.handleSessionMenu(_config([..._menu.take(5), _poker('omaha')]));
      expect(state.lobbyEngine, TableEngine.teenPatti);
      expect(state.lobbyCategory, isNull);

      // A menu that still has it keeps the player where they are.
      state.openLobbyCategory(TableCategory.blind);
      state.handleSessionMenu(_config([..._menu, _poker('omaha')]));
      expect(state.lobbyCategory, TableCategory.blind);

      state.openLobbyCategory(TableCategory.omaha);
      state.handleSessionMenu(_config(_menu));
      expect(state.lobbyEngine, isNull);
      expect(state.lobbyCategory, isNull);

      // And an engine that stays with no open category stays open.
      state.openLobbyEngine(TableEngine.teenPatti);
      state.handleSessionMenu(_config(_menu.take(2).toList()));
      expect(state.lobbyEngine, TableEngine.teenPatti);
    });
  });

  test('the new words are written in every language', () {
    for (final lang in AppLang.values) {
      final t = Strings(lang);
      for (final key in ['teenPatti', 'teenPattiTableNote', 'viewGames']) {
        final own = t.ownEntry(key);
        expect(own, isNotNull, reason: '${lang.code} has no "$key"');
        expect(own!.trim(), isNotEmpty, reason: '${lang.code} "$key"');
        if (lang != AppLang.english) {
          expect(
            own,
            isNot(const Strings(AppLang.english).ownEntry(key)),
            reason: '${lang.code} "$key" is the English',
          );
        }
      }
    }
  });

  for (final (screen, scale) in [
    (const Size(640, 360), 1.25),
    (const Size(891, 411), 1.0),
  ]) {
    final name = '${screen.width.toInt()}x${screen.height.toInt()} x$scale';

    for (final lang in AppLang.values) {
      testWidgets('at $name in ${lang.englishName} the lobby opens on the '
          'engines, Teen Patti on its categories, and a category on its '
          'tables — and Back walks up again', (tester) async {
        final state = _state(lang: lang, tables: [..._menu, _poker('omaha')]);
        final t = Strings(lang);
        await _pumpLobby(tester, state, screen: screen, textScale: scale);
        expect(tester.takeException(), isNull);

        // The front: Teen Patti, Poker and the private card; no category and
        // no table yet.
        expect(_rail(''), findsOneWidget);
        expect(find.text(t.viewGames, skipOffstage: false), findsNWidgets(2));
        expect(find.text(t.teenPatti, skipOffstage: false), findsOneWidget);
        expect(find.text(t.poker, skipOffstage: false), findsOneWidget);
        expect(
          find.text(t.teenPattiTableNote, skipOffstage: false),
          findsOneWidget,
        );
        expect(find.text(t.viewTables, skipOffstage: false), findsNothing);
        expect(find.text(t.tapToSit, skipOffstage: false), findsNothing);
        expect(
          find.text(t.backToCategories, skipOffstage: false),
          findsNothing,
        );
        expect(find.text(t.privateTable, skipOffstage: false), findsOneWidget);

        // Into Teen Patti: its three categories behind the way back to every
        // game, and no private card.
        await _tapInRail(
          tester,
          find.text(t.viewGames, skipOffstage: false).first,
        );
        await _settleLevel(tester);
        expect(tester.takeException(), isNull);
        expect(state.lobbyEngine, TableEngine.teenPatti);
        expect(state.lobbyCategory, isNull);
        expect(_rail(TableEngine.teenPatti), findsOneWidget);
        expect(find.text(t.viewGames, skipOffstage: false), findsNothing);
        expect(find.text(t.viewTables, skipOffstage: false), findsNWidgets(3));
        for (final category in [t.seen, t.blind, t.variation]) {
          expect(find.text(category, skipOffstage: false), findsOneWidget);
        }
        expect(
          find.text(t.backToCategories, skipOffstage: false),
          findsOneWidget,
        );
        // The tile names where the player is.
        expect(_named(t.teenPatti), findsOneWidget);
        expect(find.text(t.privateTable, skipOffstage: false), findsNothing);
        expect(find.text(t.tapToSit, skipOffstage: false), findsNothing);

        // Into Blind: its four tables, behind a way back to Teen Patti.
        await _tapInRail(
          tester,
          find.text(t.viewTables, skipOffstage: false).at(1),
        );
        await _settleLevel(tester);
        expect(tester.takeException(), isNull);
        expect(state.lobbyCategory, TableCategory.blind);
        expect(
          _rail('${TableEngine.teenPatti}:${TableCategory.blind}'),
          findsOneWidget,
        );
        expect(find.text(t.viewTables, skipOffstage: false), findsNothing);
        expect(
          find.text(t.backToCategories, skipOffstage: false),
          findsNothing,
        );
        expect(find.text(t.teenPatti, skipOffstage: false), findsOneWidget);
        expect(
          find.text(t.tapToSit, skipOffstage: false),
          findsNWidgets(4),
          reason: 'blind 200, 5,000, 50,000 and 10 Lakh',
        );

        // Back to Teen Patti, by the tile that names it.
        await _tapInRail(tester, find.text(t.teenPatti, skipOffstage: false));
        await _settleLevel(tester);
        expect(tester.takeException(), isNull);
        expect(state.lobbyEngine, TableEngine.teenPatti);
        expect(state.lobbyCategory, isNull);
        expect(find.text(t.viewTables, skipOffstage: false), findsNWidgets(3));
        expect(find.text(t.tapToSit, skipOffstage: false), findsNothing);

        // And back to the front.
        await _tapInRail(
          tester,
          find.text(t.backToCategories, skipOffstage: false),
        );
        await _settleLevel(tester);
        expect(tester.takeException(), isNull);
        expect(state.lobbyEngine, isNull);
        expect(find.text(t.viewGames, skipOffstage: false), findsNWidgets(2));
        expect(find.text(t.privateTable, skipOffstage: false), findsOneWidget);

        await _unmount(tester);
        state.dispose();
      });
    }

    // The chip shuffle on the two engine cards (owner, 23 Sep 2026): each in
    // the colours of the coin its card had, beside its own title, inside its
    // card, the card's facts still at full size — and the one-second rebuild
    // the lobby's cards take never reaching the animation.
    for (final brightness in Brightness.values) {
      for (final lang in AppLang.values) {
        testWidgets('at $name in ${lang.englishName}, ${brightness.name}, the '
            'engine cards shuffle chips in their own coin\'s colours, and fit', (
          tester,
        ) async {
          final state = _state(lang: lang, tables: [..._menu, _poker('omaha')]);
          final t = Strings(lang);
          await _pumpLobby(
            tester,
            state,
            screen: screen,
            textScale: scale,
            brightness: brightness,
          );
          expect(tester.takeException(), isNull);

          final shuffles = find.byType(ChipShuffle, skipOffstage: false);
          expect(shuffles, findsNWidgets(2));
          final scheme = Theme.of(tester.element(shuffles.first)).colorScheme;
          expect(scheme.brightness, brightness);
          expect(
            [
              for (final e in shuffles.evaluate())
                (e.widget as ChipShuffle).colour,
            ],
            [
              // Teen Patti's gold, Poker's teal: what the coins were drawn in.
              AppTheme.paletteFor(
                scheme,
                category: TableCategory.seen,
                bootAmount: 200,
              ).accent,
              AppTheme.paletteFor(
                scheme,
                category: TableCategory.pokerFamily,
                bootAmount: 200,
              ).accent,
            ],
          );

          for (final (i, title) in [t.teenPatti, t.poker].indexed) {
            final shuffle = shuffles.at(i);
            final slot = tester.getRect(shuffle);
            final name = tester.getRect(find.text(title, skipOffstage: false));
            final card = tester.getRect(
              find
                  .ancestor(of: shuffle, matching: find.byType(AspectRatio))
                  .first,
            );
            // Beside its own title, on the same line, and inside its card.
            expect(slot.right, lessThanOrEqualTo(name.left), reason: title);
            expect(
              (slot.center.dy - name.center.dy).abs(),
              lessThan(1),
              reason: title,
            );
            expect(card.contains(slot.topLeft), isTrue, reason: title);
            expect(card.contains(slot.bottomRight), isTrue, reason: title);
            // The card's words are never shrunk to make room for it (its
            // column, CardColumn, would scale them down as one).
            RenderObject? box = tester.renderObject(shuffle);
            while (box is! RenderCardColumn) {
              box = box!.parent;
            }
            expect(
              box.scale,
              1,
              reason: '$title: the facts were scaled down to fit',
            );
          }

          // A tick rebuilds every card; the shuffles keep their state and
          // their whole subtree.
          final before = [
            for (final e in shuffles.evaluate())
              (
                (e as StatefulElement).state,
                tester.widget(
                  find
                      .descendant(
                        of: find.byWidget(e.widget),
                        matching: find.byType(RepaintBoundary),
                        skipOffstage: false,
                      )
                      .first,
                ),
              ),
          ];
          state.notifyListeners();
          await tester.pump(const Duration(seconds: 1));
          final after = [
            for (final e in shuffles.evaluate())
              (
                (e as StatefulElement).state,
                tester.widget(
                  find
                      .descendant(
                        of: find.byWidget(e.widget),
                        matching: find.byType(RepaintBoundary),
                        skipOffstage: false,
                      )
                      .first,
                ),
              ),
          ];
          for (final (i, (was, subtree)) in before.indexed) {
            expect(after[i].$1, same(was));
            expect(after[i].$2, same(subtree));
          }

          // Inside an engine the category cards keep their settling pile.
          await _tapInRail(
            tester,
            find.text(t.viewGames, skipOffstage: false).first,
          );
          await _settleLevel(tester);
          expect(tester.takeException(), isNull);
          expect(find.byType(ChipShuffle, skipOffstage: false), findsNothing);
          expect(
            find.byType(LivelyChipStack, skipOffstage: false),
            findsNWidgets(3),
          );

          await _unmount(tester);
          state.dispose();
        });
      }
    }

    testWidgets('at $name Variation holds its two tables, uncapped', (
      tester,
    ) async {
      final state = _state();
      const t = Strings(AppLang.english);
      await _pumpLobby(tester, state, screen: screen, textScale: scale);
      await _tapInRail(tester, find.text(t.viewGames, skipOffstage: false));
      await _settleLevel(tester);
      await _tapInRail(
        tester,
        find.text(t.viewTables, skipOffstage: false).at(2),
      );
      await _settleLevel(tester);
      expect(tester.takeException(), isNull);
      expect(state.lobbyCategory, TableCategory.variation);
      // 50,000 and 10 Lakh, and both of them variation cards.
      expect(find.text(t.tapToSit, skipOffstage: false), findsNWidgets(2));
      expect(
        find.text(t.variationTableNote, skipOffstage: false),
        findsNWidgets(2),
      );
      // "In all variation tables, do not keep any pot limit."
      expect(find.text(t.potUnlimited, skipOffstage: false), findsNWidgets(2));
      await _unmount(tester);
      state.dispose();
    });
  }

  testWidgets('the Teen Patti card says its stakes, its tables and how many '
      'are open to this player', (tester) async {
    final state = _state(chips: 300000);
    const t = Strings(AppLang.english);
    await _pumpLobby(tester, state, screen: const Size(891, 411));
    // Every Teen Patti table: 200 to 10 Lakh, seven of them, five open to a
    // 3 Lakh stack (the two 10 Lakh tables want 50 Crore).
    expect(find.text('200 – 10 Lakh', skipOffstage: false), findsOneWidget);
    expect(find.text(t.tablesLabel, skipOffstage: false), findsOneWidget);
    expect(find.text('7', skipOffstage: false), findsOneWidget);
    expect(find.text(t.openToYouLabel, skipOffstage: false), findsOneWidget);
    expect(find.text('5', skipOffstage: false), findsOneWidget);
    await _unmount(tester);
    state.dispose();
  });

  testWidgets('a category card says its stakes, its tables and how many are '
      'open to this player', (tester) async {
    final state = _state(chips: 300000);
    const t = Strings(AppLang.english);
    await _pumpLobby(tester, state, screen: const Size(891, 411));
    state.openLobbyEngine(TableEngine.teenPatti);
    await _settleLevel(tester);
    // Blind runs 200 to 10 Lakh, Variation 50,000 to 10 Lakh; Seen is the one
    // stake.
    expect(find.text('200 – 10 Lakh', skipOffstage: false), findsOneWidget);
    expect(find.text('50,000 – 10 Lakh', skipOffstage: false), findsOneWidget);
    expect(find.text(t.tablesLabel, skipOffstage: false), findsNWidgets(3));
    expect(find.text(t.openToYouLabel, skipOffstage: false), findsNWidgets(3));
    await _unmount(tester);
    state.dispose();
  });

  for (final lang in AppLang.values) {
    testWidgets('in ${lang.englishName} every table card has an info key that '
        'opens what the server says about that table', (tester) async {
      final state = _state(lang: lang, chips: 300000);
      final t = Strings(lang);
      await _pumpLobby(
        tester,
        state,
        screen: const Size(640, 360),
        textScale: 1.25,
      );
      state.openLobbyCategory(TableCategory.blind);
      await _settleLevel(tester);

      // One per table card, shut ones included.
      final keys = find.bySemanticsLabel(t.tableInfoTitle, skipOffstage: false);
      expect(keys, findsNWidgets(4));

      // The cheapest blind table: tapping the key opens the popup and does NOT
      // sit the player down.
      await _tapInRail(tester, keys.first);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      expect(state.screen, Screen.lobby);
      expect(find.textContaining(t.tableInfoTitle), findsOneWidget);
      // How much a player can bring, how many blind moves, and the rest.
      expect(find.text(t.entryLabel), findsWidgets);
      expect(
        find.text(t.entryUpTo.replaceFirst('{cap}', formatChips(500000))),
        findsWidgets,
      );
      expect(find.text(t.maxBlindsLabel), findsWidgets);
      expect(find.text(t.potUnlimited), findsWidgets);
      expect(find.text(t.playersUpTo(5)), findsOneWidget);
      expect(find.text(t.secondsEach(25)), findsOneWidget);
      expect(find.text(t.onlyYourChips), findsWidgets);
      expect(find.text(t.canSitHere), findsOneWidget);

      await tester.tap(find.byTooltip(t.close));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text(t.canSitHere), findsNothing);

      await _unmount(tester);
      state.dispose();
    });
  }

  for (final lang in AppLang.values) {
    testWidgets('in ${lang.englishName} every table card has a rules key that '
        'opens the rules of THAT table', (tester) async {
      final state = _state(lang: lang, chips: 300000);
      final t = Strings(lang);
      await _pumpLobby(
        tester,
        state,
        screen: const Size(640, 360),
        textScale: 1.25,
      );

      // A blind table: its own chips, a ladder that keeps doubling, no pot
      // limit, no forced showdown — and nothing about variations.
      state.openLobbyCategory(TableCategory.blind);
      await _settleLevel(tester);
      final blindKeys = find.bySemanticsLabel(
        t.tableRulesKey,
        skipOffstage: false,
      );
      expect(blindKeys, findsNWidgets(4), reason: 'one on every table card');
      await _tapInRail(tester, blindKeys.first);
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      expect(state.screen, Screen.lobby, reason: 'the key does not sit down');
      expect(find.text(t.tableRulesTitle), findsOneWidget);
      expect(find.text(t.onlyYourChips), findsWidgets);
      expect(find.text(t.ruleBlindMoves(4)), findsOneWidget);
      expect(find.text(t.ruleRaiseFree), findsOneWidget);
      expect(find.text(t.rulePotOpen), findsOneWidget);
      expect(find.text(t.ruleRoundsEnd), findsNothing);
      expect(find.text(t.ruleVariationPick), findsNothing);
      expect(
        find.text(t.variationRulesTitle, skipOffstage: false),
        findsNothing,
      );
      // The rankings are part of every table's rules.
      expect(find.text(t.rankTrail, skipOffstage: false), findsOneWidget);
      await tester.tap(find.byTooltip(t.close));
      await tester.pump(const Duration(milliseconds: 500));

      // The seen table: open chips, one raise a turn, and its pot cap by name.
      state.closeLobbyLevel();
      state.openLobbyCategory(TableCategory.seen);
      await _settleLevel(tester);
      await _tapInRail(
        tester,
        find.bySemanticsLabel(t.tableRulesKey, skipOffstage: false).first,
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      expect(find.text(t.everyoneChips), findsWidgets);
      expect(find.text(t.ruleRaiseOnce), findsOneWidget);
      expect(find.text(t.rulePotCapped(formatChips(2000000))), findsOneWidget);
      expect(find.text(t.ruleRoundsEnd), findsOneWidget);
      expect(find.text(t.ruleVariationPick), findsNothing);
      await tester.tap(find.byTooltip(t.close));
      await tester.pump(const Duration(milliseconds: 500));

      // A variation table: who picks, hidden chips, no pot limit — and the six
      // variations under the rankings.
      state.closeLobbyLevel();
      state.openLobbyCategory(TableCategory.variation);
      await _settleLevel(tester);
      await _tapInRail(
        tester,
        find.bySemanticsLabel(t.tableRulesKey, skipOffstage: false).first,
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      expect(find.text(t.ruleVariationPick), findsOneWidget);
      expect(find.text(t.onlyYourChips), findsWidgets);
      expect(find.text(t.rulePotOpen), findsOneWidget);
      expect(find.text(t.ruleRoundsEnd), findsOneWidget);
      expect(
        find.text(t.variationRulesTitle, skipOffstage: false),
        findsOneWidget,
      );
      for (final wire in Variation.all) {
        expect(
          find.text(t.variationName(wire), skipOffstage: false),
          findsOneWidget,
          reason: wire,
        );
      }

      await _unmount(tester);
      state.dispose();
    });
  }

  testWidgets(
    'the info of a table shut to the player says what it would take',
    (tester) async {
      final state = _state(chips: 300000);
      const t = Strings(AppLang.english);
      await _pumpLobby(tester, state, screen: const Size(891, 411));
      state.openLobbyCategory(TableCategory.variation);
      await _settleLevel(tester);

      // Variation 10 Lakh needs 50 Crore; it is the second, shut card.
      final keys = find.bySemanticsLabel(t.tableInfoTitle, skipOffstage: false);
      expect(keys, findsNWidgets(2));
      await _tapInRail(tester, keys.last);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      expect(find.text(t.variationTableNote), findsWidgets);
      expect(find.text(t.canSitHere), findsNothing);
      expect(
        find.text(t.lockedBody.replaceFirst('{min}', formatChips(500000000))),
        findsWidgets,
      );
      await _unmount(tester);
      state.dispose();
    },
  );

  testWidgets('an older server with seen and blind only shows one engine and '
      'two categories in it', (tester) async {
    final state = _state(
      tables: [
        {'category': 'seen', 'bootAmount': 200},
        {'category': 'blind', 'bootAmount': 200},
        {'category': 'blind', 'bootAmount': 5000},
      ],
    );
    const t = Strings(AppLang.english);
    await _pumpLobby(tester, state, screen: const Size(891, 411));
    expect(tester.takeException(), isNull);
    expect(find.text(t.viewGames, skipOffstage: false), findsOneWidget);
    expect(find.text(t.poker, skipOffstage: false), findsNothing);
    state.openLobbyEngine(TableEngine.teenPatti);
    await _settleLevel(tester);
    expect(tester.takeException(), isNull);
    expect(find.text(t.viewTables, skipOffstage: false), findsNWidgets(2));
    expect(find.text(t.variation, skipOffstage: false), findsNothing);
    await _unmount(tester);
    state.dispose();
  });

  testWidgets('a category that leaves the menu leaves the player in its '
      'engine, not at an empty rail', (tester) async {
    final state = _state();
    const t = Strings(AppLang.english);
    await _pumpLobby(tester, state, screen: const Size(891, 411));
    state.openLobbyCategory(TableCategory.variation);
    await _settleLevel(tester);
    expect(find.text(t.tapToSit, skipOffstage: false), findsNWidgets(2));

    // A new menu without variation, arriving the way a fetched catalogue
    // does: the lobby goes back to Teen Patti's categories.
    state.handleCatalogue(
      _config([
        {'category': 'seen', 'bootAmount': 200},
        {'category': 'blind', 'bootAmount': 200},
      ]),
    );
    await _settleLevel(tester);
    expect(tester.takeException(), isNull);
    expect(state.lobbyEngine, TableEngine.teenPatti);
    expect(state.lobbyCategory, isNull);
    expect(find.text(t.viewTables, skipOffstage: false), findsNWidgets(2));
    expect(find.text(t.tapToSit, skipOffstage: false), findsNothing);
    await _unmount(tester);
    state.dispose();
  });

  testWidgets('a menu written straight over the one on screen never strands '
      'the rail at an empty level', (tester) async {
    const t = Strings(AppLang.english);

    // Past _applyMenu, as a test (or a future writer) might: the state still
    // names Poker and Omaha, and the rail shows the front, which is where a
    // menu without them would have left the player.
    final state = _state(tables: [..._menu, _poker('omaha')]);
    state.openLobbyCategory(TableCategory.omaha);
    state.config = _config(_menu);
    expect(state.lobbyEngine, TableEngine.poker);
    await _pumpLobby(tester, state, screen: const Size(891, 411));
    expect(tester.takeException(), isNull);
    expect(_rail(''), findsOneWidget);
    expect(find.text(t.viewGames, skipOffstage: false), findsOneWidget);
    await _unmount(tester);

    // A category gone from an engine that stays: that engine's categories.
    state.openLobbyCategory(TableCategory.variation);
    expect(state.lobbyEngine, TableEngine.teenPatti);
    state.config = _config(_menu.take(5).toList());
    await _pumpLobby(tester, state, screen: const Size(891, 411));
    expect(tester.takeException(), isNull);
    expect(_rail(TableEngine.teenPatti), findsOneWidget);
    expect(find.text(t.viewTables, skipOffstage: false), findsNWidgets(2));
    await _unmount(tester);
    state.dispose();
  });
}
