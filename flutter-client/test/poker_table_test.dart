// The poker felt, as the client draws it from one snapshot: a Hold'em turn
// with a board and the keys, 5-Card Draw's draw street with tappable cards, a
// 3-Card Poker decision against the dealer, and a finished hand. Every one of
// them must lay out on the tightest phone with nothing striped.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/poker_table_screen.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/playing_card.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/table_chrome.dart';

const _ids = ['u0', 'u1', 'u2', 'u3', 'u4'];

int get _now => DateTime.now().millisecondsSinceEpoch;

Map<String, dynamic> _seat(int i, {int cards = 2, bool allIn = false}) => {
  'seatIndex': i,
  'userId': _ids[i],
  'displayName': 'Player $i',
  'avatarUrl': null,
  'chips': allIn ? 0 : 20000,
  'status': 'active',
  'connected': true,
  'cardCount': cards,
  'contributed': 400,
  'streetBet': 200,
  'allIn': allIn,
  'lastAction': 'call',
  'dealer': i == 4,
};

/// A poker room of five with the viewer (u0) in seat 0.
RoomState _room({
  String variant = 'texas_holdem',
  String street = 'flop',
  String state = 'betting',
  List<String> community = const ['Ah', '7d', '9c'],
  List<String> myCards = const ['Ks', 'Kd'],
  int cards = 2,
  Map<String, dynamic>? options,
  Map<String, dynamic>? dealer,
  Map<String, dynamic>? result,
  bool myTurn = true,
}) => RoomState.fromJson({
  'roomId': 'p1',
  'code': 'ABCD2345',
  'category': variant,
  'game': 'poker',
  'chipsHidden': false,
  'state': state,
  'handNo': 3,
  'dealerSeat': 4,
  'maxPlayers': 5,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'startsAt': null,
  'pot': 2000,
  'turn': myTurn
      ? {'seatIndex': 0, 'userId': 'u0', 'deadline': _now + 25000}
      : {'seatIndex': 1, 'userId': 'u1', 'deadline': _now + 25000},
  'you': {
    'seatIndex': 0,
    'chips': 20000,
    'status': 'active',
    'cards': myCards,
    'contributed': 400,
    'streetBet': 200,
    'allIn': false,
    'missedTurns': 0,
    'maxMissedTurns': 3,
    'options': ?options,
  },
  'seats': [for (var i = 0; i < 5; i++) _seat(i, cards: cards, allIn: i == 3)],
  'poker': {
    'variant': variant,
    'street': street,
    'community': community,
    'pots': [
      {
        'amount': 1600,
        'eligible': [0, 1, 2, 3, 4],
      },
      {
        'amount': 400,
        'eligible': [0, 1, 2, 4],
      },
    ],
    'currentBet': 400,
    'minRaise': 200,
    'smallBlind': 100,
    'bigBlind': 200,
    'ante': 0,
    'holeCards': cards,
    'maxDiscards': variant == 'five_card_draw' ? 3 : 0,
    'minBuyIn': 2000,
    'dealer': ?dealer,
    'result': ?result,
  },
});

const _holdemOptions = <String, dynamic>{
  'street': 'flop',
  'fold': true,
  'check': false,
  'call': true,
  'callAmount': 200,
  'bet': false,
  'minBet': 0,
  'maxBet': 0,
  'raise': true,
  'minRaise': 600,
  'maxRaise': 20200,
  'allIn': true,
  'allInAmount': 20000,
  'play': false,
  'playAmount': 0,
  'draw': false,
  'maxDiscards': 0,
};

GameState _newState(RoomState room) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  state
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Player 0',
      'chips': 20000,
      'diamond': 2,
      'hammer': 20,
      'missile': 1,
    })
    ..screen = Screen.table
    ..handleState(room);
  return state;
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

MachinedKey _key(WidgetTester tester, String label) =>
    tester.widget<MachinedKey>(
      find.byWidgetPredicate((w) => w is MachinedKey && w.label == label),
    );

void main() {
  setUpAll(_loadInter);

  test('a poker snapshot parses, and a Teen Patti one carries no poker', () {
    final room = _room(options: _holdemOptions);
    expect(room.isPoker, isTrue);
    expect(room.game, 'poker');
    expect(room.poker!.variant, 'texas_holdem');
    expect(room.poker!.community, ['Ah', '7d', '9c']);
    expect(room.poker!.pots, hasLength(2));
    expect(room.you!.pokerOptions, isNotNull);
    expect(room.you!.options, isNull, reason: 'a poker map is never a ladder');
    expect(room.you!.pokerOptions!.minRaise, 600);
    expect(room.seats[3].allIn, isTrue);
    expect(room.seats[4].dealer, isTrue);

    final teenPatti = RoomState.fromJson({
      'roomId': 'r1',
      'category': 'seen',
      'state': 'betting',
      'you': {
        'seatIndex': 0,
        'options': {
          'raiseSteps': [400],
        },
      },
      'seats': const [],
    });
    expect(teenPatti.isPoker, isFalse);
    expect(teenPatti.poker, isNull);
    expect(teenPatti.game, '');
    expect(teenPatti.you!.options, isNotNull);
    expect(teenPatti.you!.pokerOptions, isNull);
  });

  for (final lang in AppLang.values) {
    testWidgets('in ${lang.englishName} a Hold\'em turn draws the board, the '
        'pots and the keys with nothing striped', (tester) async {
      final state = _newState(_room(options: _holdemOptions))..lang = lang;
      final t = Strings(lang);
      await _pumpTable(tester, state);
      expect(tester.takeException(), isNull);
      expect(find.byType(PokerTableScreen), findsOneWidget);
      expect(state.isPokerTable, isTrue);
      expect(state.myPokerTurn, isTrue);
      expect(state.options, isNull, reason: 'no Teen Patti key may light');

      // The three board cards are face up; two places are still empty.
      final board = tester
          .widgetList<PlayingCard>(find.byType(PlayingCard))
          .where((c) => c.code != null && ['Ah', '7d', '9c'].contains(c.code))
          .length;
      expect(board, 3);

      // Call for 200 and the raise key, lit; Check is not offered.
      expect(_key(tester, t.call).alive, isTrue);
      expect(_key(tester, t.call).amount, formatChips(200));
      expect(_key(tester, t.raise).alive, isTrue);
      expect(_key(tester, t.raise).amount, formatChips(600));
      expect(_key(tester, t.allIn).alive, isTrue);
      expect(_key(tester, t.fold).alive, isTrue);
      expect(
        find.text(
          '${t.pokerVariantName('texas_holdem')} · '
          '${t.pokerStreetName('flop')}',
        ),
        findsOneWidget,
      );
      await _teardown(tester, state);
    });
  }

  testWidgets('the stepper walks the raise between the server\'s ends', (
    tester,
  ) async {
    final state = _newState(_room(options: _holdemOptions));
    expect(state.pokerBetAmount, 600);
    state.pokerStepBet(1);
    expect(state.pokerBetAmount, 800);
    state.pokerStepBet(-5);
    expect(state.pokerBetAmount, 600, reason: 'never below the least raise');
    state.pokerBetTo(1000000);
    expect(state.pokerBetAmount, 20200, reason: 'never above the most');
    state.dispose();
  });

  testWidgets('on the draw street the viewer\'s cards mark for the exchange', (
    tester,
  ) async {
    final state = _newState(
      _room(
        variant: 'five_card_draw',
        street: 'draw',
        community: const [],
        myCards: const ['Ks', 'Kd', '4c', '7h', '9s'],
        cards: 5,
        options: const {
          'street': 'draw',
          'fold': false,
          'check': false,
          'call': false,
          'callAmount': 0,
          'bet': false,
          'raise': false,
          'allIn': false,
          'play': false,
          'draw': true,
          'maxDiscards': 3,
        },
      ),
    );
    const t = Strings(AppLang.english);
    await _pumpTable(tester, state);
    expect(tester.takeException(), isNull);
    expect(find.text(t.exchangeUpTo(3)), findsOneWidget);
    expect(_key(tester, t.standPat).alive, isTrue);

    // The fan overlaps: each card shows its left part, so the tap lands
    // there, as a thumb would, rather than on the card's centre under the
    // next one.
    final card = find.byWidgetPredicate(
      (w) => w is PlayingCard && w.code == '4c',
    );
    await tester.tapAt(tester.getTopLeft(card) + const Offset(6, 14));
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.discardSelection, {'4c'});
    expect(_key(tester, '${t.draw} 1').alive, isTrue);
    expect(tester.takeException(), isNull);
    await _teardown(tester, state);
  });

  testWidgets('a 3-Card Poker decision shows Play, Fold and the dealer', (
    tester,
  ) async {
    final state = _newState(
      _room(
        variant: 'three_card_poker',
        street: 'decision',
        community: const [],
        myCards: const ['Ks', 'Kd', '4c'],
        cards: 3,
        dealer: const {'cardCount': 3, 'cards': <String>[]},
        options: const {
          'street': 'decision',
          'fold': true,
          'play': true,
          'playAmount': 200,
        },
      ),
    );
    const t = Strings(AppLang.english);
    await _pumpTable(tester, state);
    expect(tester.takeException(), isNull);
    expect(find.text(t.playOrFold), findsOneWidget);
    expect(find.text(t.dealerLabel), findsOneWidget);
    expect(_key(tester, t.play).alive, isTrue);
    expect(_key(tester, t.fold).alive, isTrue);
    await _teardown(tester, state);
  });

  testWidgets('a finished hand turns the reveals over and marks the winner', (
    tester,
  ) async {
    final state = _newState(
      _room(
        street: 'showdown',
        state: 'showdown',
        community: const ['Ah', '7d', '9c', '2s', 'Kc'],
        myTurn: false,
        result: {
          'handId': 'h3',
          'reason': 'showdown',
          'community': ['Ah', '7d', '9c', '2s', 'Kc'],
          'pots': [
            {
              'amount': 2000,
              'eligible': [0, 1],
              'winners': [
                {
                  'userId': 'u1',
                  'seatIndex': 1,
                  'amount': 2000,
                  'handName': 'Two Pair',
                },
              ],
            },
          ],
          'reveals': [
            {
              'userId': 'u0',
              'seatIndex': 0,
              'cards': ['Ks', 'Kd'],
              'best': ['Ks', 'Kd', 'Kc', 'Ah', '9c'],
              'handName': 'Three of a Kind',
              'category': 3,
              'won': 0,
            },
            {
              'userId': 'u1',
              'seatIndex': 1,
              'cards': ['Ad', '7c'],
              'best': ['Ad', 'Ah', '7c', '7d', 'Kc'],
              'handName': 'Two Pair',
              'category': 2,
              'won': 2000,
            },
          ],
        },
      ),
    );
    await _pumpTable(tester, state);
    expect(tester.takeException(), isNull);
    expect(state.pokerCelebrating, isTrue);
    // The winner's hole cards are face up at their seat.
    expect(
      find.byWidgetPredicate((w) => w is PlayingCard && w.code == 'Ad'),
      findsOneWidget,
    );
    expect(find.text('Two Pair'), findsWidgets);
    await _teardown(tester, state);
  });
}
