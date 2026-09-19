// The rulebook key at a poker table (owner, 19 Sep 2026: "in each poker
// gameplay add an icon of rulebook and which tells about that specific table
// gameplay not other"). The key is in the rail, and the sheet it opens names
// ONE game — never the other three, never Teen Patti — and shows that game's
// own ranking: three-card at 3-Card Poker, five-card everywhere else.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

int get _now => DateTime.now().millisecondsSinceEpoch;

/// The four games as the server lists them, one table each at boot 50,000.
const _boot = 50000;
const _buyIn = 500000;

const _variants = <String, ({int hole, bool blinds, int discards})>{
  'texas_holdem': (hole: 2, blinds: true, discards: 0),
  'omaha': (hole: 4, blinds: true, discards: 0),
  'five_card_draw': (hole: 5, blinds: false, discards: 3),
  'three_card_poker': (hole: 3, blinds: false, discards: 0),
};

RoomState _pokerRoom(String variant) {
  final v = _variants[variant]!;
  return RoomState.fromJson({
    'roomId': 'p1',
    'code': 'ABCD2345',
    'category': variant,
    'game': 'poker',
    'chipsHidden': false,
    'state': 'betting',
    'handNo': 3,
    'dealerSeat': 1,
    'maxPlayers': 5,
    'minPlayers': 2,
    'bootAmount': _boot,
    'turnTimeoutMs': 25000,
    'pot': 0,
    'turn': {'seatIndex': 1, 'userId': 'u1', 'deadline': _now + 25000},
    'you': {
      'seatIndex': 0,
      'chips': 2000000,
      'status': 'active',
      'cards': const <String>[],
      'missedTurns': 0,
      'maxMissedTurns': 3,
    },
    'seats': [
      for (var i = 0; i < 2; i++)
        {
          'seatIndex': i,
          'userId': 'u$i',
          'displayName': 'Player $i',
          'chips': 2000000,
          'status': 'active',
          'connected': true,
          'cardCount': v.hole,
        },
    ],
    'poker': {
      'variant': variant,
      'street': v.blinds ? 'preflop' : 'predraw',
      'community': const <String>[],
      'pots': const <Map<String, dynamic>>[],
      'smallBlind': v.blinds ? _boot ~/ 2 : 0,
      'bigBlind': v.blinds ? _boot : 0,
      'ante': v.blinds ? 0 : _boot,
      'holeCards': v.hole,
      'maxDiscards': v.discards,
      'minBuyIn': _buyIn,
    },
  });
}

/// A Teen Patti room, to prove its own drawer is untouched.
RoomState _teenPattiRoom() => RoomState.fromJson({
  'roomId': 'r1',
  'code': 'ABCD2345',
  'category': 'seen',
  'state': 'betting',
  'handNo': 3,
  'maxPlayers': 5,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'pot': 400,
  'you': {'seatIndex': 0, 'chips': 20000, 'status': 'active'},
  'seats': [
    for (var i = 0; i < 2; i++)
      {
        'seatIndex': i,
        'userId': 'u$i',
        'displayName': 'Player $i',
        'chips': 20000,
        'status': 'active',
        'connected': true,
        'cardCount': 3,
      },
  ],
});

GameState _newState(RoomState room, {AppLang lang = AppLang.english}) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Player 0',
      'chips': 2000000,
      'diamond': 2,
      'hammer': 20,
      'missile': 1,
    })
    ..screen = Screen.table
    ..handleState(room);
}

Future<void> _loadInter() async {
  final inter = FontLoader('Inter');
  for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
  }
  await inter.load();
}

Future<void> _pumpTable(
  WidgetTester tester,
  GameState state, {
  Size screen = const Size(640, 360),
  double textScale = 1.25,
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
        home: const TableScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _teardown(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

void main() {
  setUpAll(_loadInter);

  test('a poker room reads as the menu entry it would have had', () {
    final holdem = LobbyTable.ofRoom(_pokerRoom('texas_holdem'))!;
    expect(holdem.isPoker, isTrue);
    expect(holdem.category, 'texas_holdem');
    expect(holdem.bootAmount, _boot);
    expect(holdem.smallBlind, _boot ~/ 2);
    expect(holdem.bigBlind, _boot);
    expect(holdem.ante, 0);
    expect(holdem.minBuyIn, _buyIn);
    expect(holdem.holeCards, 2);
    expect(holdem.maxPot, 0, reason: 'a poker room has no pot limit');

    final draw = LobbyTable.ofRoom(_pokerRoom('five_card_draw'))!;
    expect(draw.ante, _boot);
    expect(draw.smallBlind, 0);
    expect(draw.maxDiscards, 3);
    expect(draw.holeCards, 5);

    // A Teen Patti room is not one of these at all.
    expect(LobbyTable.ofRoom(_teenPattiRoom()), isNull);
  });

  for (final variant in _variants.keys) {
    testWidgets("the rail's rulebook key at a $variant table opens that "
        "game's rules and nothing else", (tester) async {
      const t = Strings(AppLang.english);
      final state = _newState(_pokerRoom(variant));
      await _pumpTable(tester, state);
      expect(tester.takeException(), isNull);

      // The key is in the rail, beside the menu and the chat, and it is the
      // lobby card's own rules key by name.
      final key = find.byTooltip(t.tableRulesKey);
      expect(key, findsOneWidget);
      await tester.tap(key);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);

      // This game, with this table's figures.
      expect(find.text(t.tableRulesTitle), findsOneWidget);
      expect(find.text(t.pokerVariantNote(variant)), findsOneWidget);
      expect(find.text(t.rulePokerBuyIn(formatChips(_buyIn))), findsOneWidget);
      expect(find.text(t.rulePokerHoleCards(_variants[variant]!.hole)),
          findsOneWidget);
      if (_variants[variant]!.blinds) {
        expect(
          find.text(
            t.rulePokerBlinds(formatChips(_boot ~/ 2), formatChips(_boot)),
          ),
          findsOneWidget,
        );
      } else {
        expect(find.text(t.rulePokerAnte(formatChips(_boot))), findsOneWidget);
      }

      // And NOT the other three games, nor Teen Patti, nor the variations.
      for (final other in _variants.keys) {
        if (other == variant) continue;
        expect(
          find.textContaining(t.pokerVariantName(other), skipOffstage: false),
          findsNothing,
          reason: '$variant names $other',
        );
        expect(
          find.text(t.pokerVariantNote(other), skipOffstage: false),
          findsNothing,
          reason: '$variant explains $other',
        );
      }
      expect(find.text(t.rankTrail, skipOffstage: false), findsNothing);
      expect(find.text(t.rulesBeats, skipOffstage: false), findsNothing);
      expect(find.text(t.variationRulesTitle, skipOffstage: false), findsNothing);
      expect(find.text(t.pokerRulesIntro, skipOffstage: false), findsNothing);

      await _teardown(tester, state);
    });
  }

  testWidgets('a 3-Card Poker table shows the three-card ranking, not the '
      "five-card one and not Teen Patti's", (tester) async {
    const t = Strings(AppLang.english);
    final state = _newState(_pokerRoom('three_card_poker'));
    await _pumpTable(tester, state);
    await tester.tap(find.byTooltip(t.tableRulesKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);

    expect(find.text(t.pokerTableRankingTitle), findsOneWidget);
    expect(find.text(t.pokerThreeCardRankingIntro), findsOneWidget);
    // Six rungs, in 3-Card Poker's own order (eval3.go): Straight Flush,
    // Three of a Kind, Straight, Flush, Pair, High Card. Every rung is on
    // screen, and the two the five-card ladder alone has are not.
    for (final rank in const [
      'straightFlush',
      'threeOfAKind',
      'straight',
      'flush',
      'pair',
      'highCard',
    ]) {
      expect(
        find.text(t.pokerRankName(rank), skipOffstage: false),
        findsOneWidget,
        reason: rank,
      );
    }
    for (final rank in const ['royalFlush', 'fourOfAKind', 'fullHouse', 'twoPair']) {
      expect(
        find.text(t.pokerRankName(rank), skipOffstage: false),
        findsNothing,
        reason: 'the five-card ladder\'s $rank is not played here',
      );
    }
    // Straight Flush stands first and Three of a Kind second — the other way
    // round from Teen Patti, where a Trail beats a Pure Sequence.
    final flush = tester.getRect(
      find.text(t.pokerRankName('straightFlush'), skipOffstage: false),
    );
    final trips = tester.getRect(
      find.text(t.pokerRankName('threeOfAKind'), skipOffstage: false),
    );
    final straight = tester.getRect(
      find.text(t.pokerRankName('straight'), skipOffstage: false),
    );
    final plainFlush = tester.getRect(
      find.text(t.pokerRankName('flush'), skipOffstage: false),
    );
    expect(flush.top, lessThan(trips.top));
    expect(trips.top, lessThan(straight.top));
    expect(
      straight.top,
      lessThan(plainFlush.top),
      reason: 'a straight beats a flush here',
    );
    expect(find.text(t.rulePokerThreeCardRuns), findsOneWidget);

    await _teardown(tester, state);
  });

  testWidgets('a Hold\'em table keeps the five-card ranking', (tester) async {
    const t = Strings(AppLang.english);
    final state = _newState(_pokerRoom('texas_holdem'));
    await _pumpTable(tester, state);
    await tester.tap(find.byTooltip(t.tableRulesKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);

    expect(find.text(t.pokerTableRankingIntro), findsOneWidget);
    for (final rank in const [
      'royalFlush',
      'straightFlush',
      'fourOfAKind',
      'fullHouse',
      'flush',
      'straight',
      'threeOfAKind',
      'twoPair',
      'pair',
      'highCard',
    ]) {
      expect(
        find.text(t.pokerRankName(rank), skipOffstage: false),
        findsOneWidget,
        reason: rank,
      );
    }
    // The streets, and what a figure on a bet key means.
    expect(find.text(t.rulePokerStreets), findsOneWidget);
    expect(find.text(t.rulePokerBetTo), findsOneWidget);
    // The 3-Card footnote is not shown at a table that never sees a dealer.
    expect(
      find.text(t.rulePokerDealerQualifies, skipOffstage: false),
      findsNothing,
    );
    await _teardown(tester, state);
  });

  testWidgets('the Teen Patti table has no rulebook key in its rail, and its '
      'drawer still opens the whole reference', (tester) async {
    const t = Strings(AppLang.english);
    final state = _newState(_teenPattiRoom());
    await _pumpTable(tester, state);
    expect(tester.takeException(), isNull);
    expect(find.byTooltip(t.tableRulesKey), findsNothing);

    state.tableScaffold.currentState!.openDrawer();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // The menu is a list: the Rules row sits below the fold on this surface.
    final rules = find.text(t.rules, skipOffstage: false);
    await tester.dragUntilVisible(
      rules,
      find.byType(Scrollable).last,
      const Offset(0, -80),
    );
    await tester.pump();
    await tester.tap(rules);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    // The whole reference: Teen Patti's rankings AND the poker family.
    expect(find.text(t.rankTrail, skipOffstage: false), findsOneWidget);
    expect(find.text(t.pokerRulesTitle, skipOffstage: false), findsOneWidget);
    expect(find.text(t.variationRulesTitle, skipOffstage: false),
        findsOneWidget);
    await _teardown(tester, state);
  });

  for (final lang in AppLang.values) {
    testWidgets('in ${lang.englishName} every poker table\'s sheet lays out '
        'with nothing striped', (tester) async {
      for (final variant in _variants.keys) {
        final state = _newState(_pokerRoom(variant), lang: lang);
        final t = Strings(lang);
        await _pumpTable(tester, state);
        await tester.tap(find.byTooltip(t.tableRulesKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.takeException(), isNull, reason: '$lang $variant');
        expect(find.text(t.pokerVariantNote(variant)), findsOneWidget);
        await _teardown(tester, state);
      }
    });
  }
}
