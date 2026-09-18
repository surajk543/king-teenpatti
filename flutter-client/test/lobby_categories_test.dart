// The lobby's two levels (owner, 18 Sep 2026).
//
// "In lobby give 3 category: Seen, Blind, Variation. When the user selects
// Blind then go into that and show all the Blind table cards — 200, 5000,
// 50000, 10L." And, later the same day: "in variation keep only two tables,
// 50000 and 10 Lakh", with no pot limit on either.
//
// The front of the lobby is the categories the server offers a table in, then
// the private card; inside a category are that category's tables behind a tile
// that leads back. Which categories and which tables is the server's menu —
// the lobby draws whatever `config.tables` lists, so an older server with a
// shorter menu is still a lobby a player can use.
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
import 'package:teenpatti/widgets/premium_surface.dart';

/// The server's default menu: one seen table, blind at four stakes, and
/// variation at the top two of them, uncapped.
const _menu = <Map<String, Object>>[
  {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
  {'category': 'blind', 'bootAmount': 200, 'maxChips': 500000},
  {'category': 'blind', 'bootAmount': 5000, 'maxChips': 50000000},
  {'category': 'blind', 'bootAmount': 50000, 'maxChips': 1000000000},
  {'category': 'blind', 'bootAmount': 1000000, 'minChips': 500000000},
  {'category': 'variation', 'bootAmount': 50000, 'maxChips': 1000000000},
  {'category': 'variation', 'bootAmount': 1000000, 'minChips': 500000000},
];

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

void main() {
  setUpAll(_loadInter);

  group('the categories', () {
    test('are Seen, Blind, Variation, whatever order the menu is in', () {
      final state = _state(tables: _menu.reversed.toList());
      addTearDown(state.dispose);
      expect(state.lobbyCategories, [
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
      expect(state.lobbyCategories, [TableCategory.seen, TableCategory.blind]);
      expect(state.lobbyTablesIn(TableCategory.variation), isEmpty);

      // And one the server does not offer cannot be gone into.
      state.openLobbyCategory(TableCategory.variation);
      expect(state.lobbyCategory, isNull);
    });

    test('file a category this build has never heard of under Seen', () {
      final state = _state(
        tables: [
          {'category': 'seen', 'bootAmount': 200},
          {'category': 'royal', 'bootAmount': 5000},
        ],
      );
      addTearDown(state.dispose);
      expect(state.lobbyCategories, [TableCategory.seen]);
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

    test('open and close, and closing says whether there was one to close', () {
      final state = _state();
      addTearDown(state.dispose);
      var notified = 0;
      state.addListener(() => notified++);

      expect(state.lobbyCategory, isNull);
      expect(state.closeLobbyCategory(), isFalse, reason: 'nothing was open');
      expect(notified, 0);

      state.openLobbyCategory(TableCategory.blind);
      expect(state.lobbyCategory, TableCategory.blind);
      expect(notified, 1);
      state.openLobbyCategory(TableCategory.blind);
      expect(notified, 1, reason: 'already there');

      expect(state.closeLobbyCategory(), isTrue);
      expect(state.lobbyCategory, isNull);
      expect(notified, 2);
    });

    test('are still open after a visit to a table', () {
      final state = _state();
      addTearDown(state.dispose);
      state.openLobbyCategory(TableCategory.variation);
      state.screen = Screen.table;
      state.screen = Screen.lobby;
      expect(state.lobbyCategory, TableCategory.variation);
    });

    test('are forgotten when the player signs out', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final state = _state();
      addTearDown(state.dispose);
      state.openLobbyCategory(TableCategory.blind);
      await state.signOut();
      expect(state.lobbyCategory, isNull);
    });
  });

  for (final (screen, scale) in [
    (const Size(640, 360), 1.25),
    (const Size(891, 411), 1.0),
  ]) {
    final name = '${screen.width.toInt()}x${screen.height.toInt()} x$scale';

    for (final lang in AppLang.values) {
      testWidgets('at $name in ${lang.englishName} the lobby opens on the '
          'categories, and a category on its tables', (tester) async {
        final state = _state(lang: lang);
        final t = Strings(lang);
        await _pumpLobby(tester, state, screen: screen, textScale: scale);
        expect(tester.takeException(), isNull);

        // Three categories and the private card; no table yet.
        expect(find.text(t.viewTables, skipOffstage: false), findsNWidgets(3));
        expect(find.text(t.tapToSit, skipOffstage: false), findsNothing);
        expect(
          find.text(t.backToCategories, skipOffstage: false),
          findsNothing,
        );
        expect(find.text(t.privateTable, skipOffstage: false), findsOneWidget);

        // Into Blind: its four tables, the way back, and no private card.
        await _tapInRail(
          tester,
          find.text(t.viewTables, skipOffstage: false).at(1),
        );
        await _settleLevel(tester);
        expect(tester.takeException(), isNull);
        expect(state.lobbyCategory, TableCategory.blind);
        expect(find.text(t.viewTables, skipOffstage: false), findsNothing);
        expect(
          find.text(t.backToCategories, skipOffstage: false),
          findsOneWidget,
        );
        expect(find.text(t.privateTable, skipOffstage: false), findsNothing);
        expect(
          find.text(t.tapToSit, skipOffstage: false),
          findsNWidgets(4),
          reason: 'blind 200, 5,000, 50,000 and 10 Lakh',
        );

        // And back.
        await _tapInRail(
          tester,
          find.text(t.backToCategories, skipOffstage: false),
        );
        await _settleLevel(tester);
        expect(tester.takeException(), isNull);
        expect(state.lobbyCategory, isNull);
        expect(find.text(t.viewTables, skipOffstage: false), findsNWidgets(3));
        expect(find.text(t.tapToSit, skipOffstage: false), findsNothing);

        await _unmount(tester);
        state.dispose();
      });
    }

    testWidgets('at $name Variation holds its two tables, uncapped', (
      tester,
    ) async {
      final state = _state();
      const t = Strings(AppLang.english);
      await _pumpLobby(tester, state, screen: screen, textScale: scale);
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

  testWidgets('a category card says its stakes, its tables and how many are '
      'open to this player', (tester) async {
    final state = _state(chips: 300000);
    const t = Strings(AppLang.english);
    await _pumpLobby(tester, state, screen: const Size(891, 411));
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
      state.closeLobbyCategory();
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
      state.closeLobbyCategory();
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

  testWidgets('an older server with seen and blind only shows two categories', (
    tester,
  ) async {
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
    expect(find.text(t.viewTables, skipOffstage: false), findsNWidgets(2));
    expect(find.text(t.variation, skipOffstage: false), findsNothing);
    await _unmount(tester);
    state.dispose();
  });

  testWidgets('a category that leaves the menu leaves the player at the '
      'categories, not at an empty rail', (tester) async {
    final state = _state();
    const t = Strings(AppLang.english);
    await _pumpLobby(tester, state, screen: const Size(891, 411));
    state.openLobbyCategory(TableCategory.variation);
    await _settleLevel(tester);
    expect(find.text(t.backToCategories, skipOffstage: false), findsOneWidget);

    // The rail is drawn from the menu as it stands: with the category gone the
    // level has no tables, and the state puts the player back at the front.
    state.config = _config([
      {'category': 'seen', 'bootAmount': 200},
      {'category': 'blind', 'bootAmount': 200},
    ]);
    expect(state.lobbyCategories, isNot(contains(TableCategory.variation)));
    expect(state.closeLobbyCategory(), isTrue);
    await _settleLevel(tester);
    expect(tester.takeException(), isNull);
    expect(find.text(t.viewTables, skipOffstage: false), findsNWidgets(2));
    await _unmount(tester);
    state.dispose();
  });
}
