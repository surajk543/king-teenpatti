// The poker felt, as the client draws it from one snapshot: a Hold'em turn
// with a board and the keys, 5-Card Draw's draw street with tappable cards, a
// 3-Card Poker decision against the dealer, and a finished hand. Every one of
// them must lay out on the tightest phone with nothing striped.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/main.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/game_connection.dart';
import 'package:teenpatti/screens/poker_table_screen.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/deal_flight.dart';
import 'package:teenpatti/widgets/playing_card.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/seat_pod.dart';
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

/// A widget of the poker felt that the screen keeps to itself. The felt's
/// pieces are private to `poker_table_screen.dart` on purpose — nothing
/// outside the screen builds one — so a layout test that has to measure one
/// finds it by the name it prints rather than by a type it cannot name.
Finder _private(String name) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

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
      expect(_key(tester, t.fold).alive, isTrue);
      // There is no All-in key (owner, 19 Sep 2026): the raise stepper's top
      // end is the whole stack, so the shove is the maximum raise.
      expect(
        find.byWidgetPredicate((w) => w is MachinedKey && w.label == t.allIn),
        findsNothing,
      );
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

  // --- the felt's places (Pixel 6 findings, 19 Sep 2026)

  /// The draw street with a hand name to draw: the viewer's own "Straight"
  /// capsule and bet stand over their cards, and the status line asks for
  /// the exchange.
  RoomState drawRoom({String? handName}) => RoomState.fromJson({
    ..._room(
      variant: 'five_card_draw',
      street: 'draw',
      community: const [],
      myCards: const ['Ks', 'Qd', 'Jc', 'Th', '9s'],
      cards: 5,
      options: const {
        'street': 'draw',
        'fold': false,
        'check': false,
        'call': false,
        'draw': true,
        'maxDiscards': 3,
      },
    ).toJson(handName: handName),
  });

  for (final (screen, scale) in [
    (const Size(640, 360), 1.25),
    (const Size(914, 411), 1.0), // a Pixel 6
    (const Size(891, 411), 1.0), // a Pixel 7 Pro
  ]) {
    final name = '${screen.width.toInt()}x${screen.height.toInt()} x$scale';

    testWidgets('at $name the status line has a place of its own, clear of '
        "the viewer's hand name, bet, the seats and the keys", (tester) async {
      final state = _newState(drawRoom(handName: 'Straight'));
      const t = Strings(AppLang.english);
      await _pumpTable(tester, state, screen: screen, textScale: scale);
      expect(tester.takeException(), isNull);

      final status = tester.getRect(
        find.descendant(
          of: _private('_PokerStatus'),
          matching: find.byType(Text),
        ),
      );
      expect(find.text(t.exchangeUpTo(3)), findsOneWidget);
      final handName = tester.getRect(_private('_OwnHandLine'));
      expect(find.text('Straight'), findsOneWidget);
      final myBet = tester.getRect(
        find.byWidgetPredicate((w) => w is SeatBet && w.totalFirst),
      );
      final keys = tester.getRect(_private('_PokerKeys'));
      final hand = tester.getRect(_private('_PokerHand'));
      final failures = <String>[];
      void clears(String what, Rect other) {
        final overlap = status.intersect(other);
        if (overlap.width > 0 && overlap.height > 0) {
          failures.add('the status $status lies over $what $other');
        }
      }

      clears("the viewer's hand name", handName);
      clears("the viewer's bet", myBet);
      clears("the viewer's cards", hand);
      clears('the keys', keys);
      final seatFinder = find.byType(SeatPod);
      for (var i = 0; i < seatFinder.evaluate().length; i++) {
        clears('seat $i', tester.getRect(seatFinder.at(i)));
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
      // And the two things the status used to sit on do not sit on each
      // other either.
      expect(handName.intersect(myBet).height, lessThanOrEqualTo(0));
      await _teardown(tester, state);
    });
  }

  testWidgets('on the draw and decision streets the empty Check / Call row '
      'is not drawn, and the cluster keeps its height', (tester) async {
    const t = Strings(AppLang.english);
    // A key by its label, not a Text: a seat that is all-in says so on the
    // felt too, and the question here is only which KEYS are drawn.
    Finder keyLabelled(String label) =>
        find.byWidgetPredicate((w) => w is MachinedKey && w.label == label);

    final holdem = _newState(_room(options: _holdemOptions));
    await _pumpTable(tester, holdem);
    final withRow = tester.getRect(_private('_PokerKeys'));
    // The betting streets draw the Check/Call row; there is no All-in key on
    // any street (owner, 19 Sep 2026).
    expect(keyLabelled(t.call), findsOneWidget);
    expect(keyLabelled(t.allIn), findsNothing);
    await _teardown(tester, holdem);

    final draw = _newState(drawRoom());
    await _pumpTable(tester, draw);
    expect(tester.takeException(), isNull);
    expect(keyLabelled(t.call), findsNothing);
    expect(keyLabelled(t.check), findsNothing);
    expect(keyLabelled(t.standPat), findsOneWidget);
    final withoutRow = tester.getRect(_private('_PokerKeys'));
    expect(withoutRow.height, withRow.height);
    expect(withoutRow.width, withRow.width);
    await _teardown(tester, draw);

    final decision = _newState(
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
    await _pumpTable(tester, decision);
    expect(tester.takeException(), isNull);
    expect(keyLabelled(t.allIn), findsNothing);
    expect(keyLabelled(t.play), findsOneWidget);
    expect(tester.getRect(_private('_PokerKeys')).height, withRow.height);
    await _teardown(tester, decision);
  });

  testWidgets("at the 3-Card reveal the dealer's line stays above the pot, "
      'and no side-pot capsules are drawn', (tester) async {
    const t = Strings(AppLang.english);
    for (final (screen, scale) in [
      (const Size(640, 360), 1.25),
      (const Size(891, 411), 1.0),
    ]) {
      final state = _newState(
        _room(
          variant: 'three_card_poker',
          street: 'showdown',
          state: 'showdown',
          community: const [],
          myCards: const ['Ks', 'Kd', '4c'],
          cards: 3,
          myTurn: false,
          dealer: const {'cardCount': 3, 'cards': <String>[]},
          result: {
            'handId': 'h3',
            'reason': 'dealer',
            'community': <String>[],
            'pots': [
              {
                'amount': 400,
                'eligible': [0],
              },
              {
                'amount': 400,
                'eligible': [1],
              },
              {
                'amount': 400,
                'eligible': [2],
              },
            ],
            'reveals': [
              {
                'userId': 'u0',
                'seatIndex': 0,
                'cards': ['Ks', 'Kd', '4c'],
                'best': ['Ks', 'Kd', '4c'],
                'handName': 'Pair',
                'category': 1,
                'won': 400,
                'outcome': 'win',
              },
            ],
            'dealer': {
              'cardCount': 3,
              'cards': ['Jh', '8d', '3c'],
              'handName': 'High Card',
              'category': 0,
              'qualified': false,
            },
          },
        ),
      );
      await _pumpTable(tester, state, screen: screen, textScale: scale);
      expect(tester.takeException(), isNull);
      expect(find.textContaining(t.dealerNotQualified), findsOneWidget);
      final dealer = tester.getRect(_private('_DealerHand'));
      final pot = tester.getRect(_private('_Pots'));
      expect(
        dealer.bottom,
        lessThanOrEqualTo(pot.top),
        reason: '$screen: the dealer $dealer runs into the pot $pot',
      );
      // No pot capsules at all: the plinth alone says what is on the table.
      // ("In Pot" on every seat's badge is a different thing, which is why
      // this asks the capsule and not the words.)
      expect(_private('_PotCapsule'), findsNothing);
      // The outcome rides on the viewer's hand name.
      expect(find.text('Pair · ${t.outcomeWin}'), findsWidgets);
      await _teardown(tester, state);
    }
  });

  /// A 3-Card hand as the SETTLED snapshot carries it: `poker.dealer` is the
  /// empty block the server sends once `t.hand` is nil, and the whole reveal
  /// — the dealer's cards, its name, its verdict, and every player's hand —
  /// is in `poker.result`, which is kept until the next deal.
  RoomState settledThreeCard({int? startsAt}) => RoomState.fromJson({
    ..._room(
      variant: 'three_card_poker',
      street: '',
      state: 'waiting',
      community: const [],
      myCards: const ['Ks', 'Kd', '4c'],
      cards: 3,
      myTurn: false,
      dealer: const {'cardCount': 0, 'cards': <String>[]},
      result: {
        'handId': 'h3',
        'reason': 'dealer',
        'community': <String>[],
        'pots': [
          {
            'amount': 400,
            'eligible': [0],
            'winners': [
              {
                'userId': 'u0',
                'seatIndex': 0,
                'amount': 800,
                'handName': 'Pair',
              },
            ],
          },
        ],
        'reveals': [
          {
            'userId': 'u0',
            'seatIndex': 0,
            'cards': ['Ks', 'Kd', '4c'],
            'best': ['Ks', 'Kd', '4c'],
            'handName': 'Pair',
            'category': 1,
            'won': 800,
            'outcome': 'win',
          },
          {
            'userId': 'u1',
            'seatIndex': 1,
            'cards': ['9h', '5d', '2c'],
            'best': ['9h', '5d', '2c'],
            'handName': 'High Card',
            'category': 0,
            'won': 0,
            'outcome': 'lose',
          },
        ],
        // No `cardCount` here: ResultView.Dealer is a DealerReveal, which
        // has none — the count has to come from the cards themselves.
        'dealer': {
          'cards': ['Qh', '8d', '3c'],
          'handName': 'High Card',
          'category': 0,
          'qualified': true,
        },
      },
    ).toJson(),
    'startsAt': ?startsAt,
  });

  testWidgets("a settled hand's snapshot alone keeps the dealer's cards face "
      'up and every reveal on the felt, before and after the celebration', (
    tester,
  ) async {
    const t = Strings(AppLang.english);
    // A client that reconnected into it: no poker:showdown, no
    // poker:handEnded, only the snapshot.
    final state = _newState(settledThreeCard(startsAt: _now + 4000));
    await _pumpTable(tester, state);
    expect(tester.takeException(), isNull);
    expect(state.pokerShowing, isTrue);

    void drawnInFull(String when) {
      // The dealer's three cards are face up, and its verdict is written
      // under them rather than under three backs.
      for (final code in const ['Qh', '8d', '3c']) {
        expect(
          find.byWidgetPredicate((w) => w is PlayingCard && w.code == code),
          findsOneWidget,
          reason: '$when: the dealer keeps $code face up',
        );
      }
      expect(find.textContaining(t.dealerQualifies), findsOneWidget, reason: when);
      expect(
        find.byWidgetPredicate(
          (w) => w is PlayingCard && w.code != null && w.code!.isNotEmpty,
        ).evaluate().length,
        greaterThanOrEqualTo(9),
        reason: '$when: the dealer and both revealed hands',
      );
      // Every player's hand, not only the viewer's.
      for (final code in const ['9h', '5d', '2c', 'Ks', 'Kd', '4c']) {
        expect(
          find.byWidgetPredicate((w) => w is PlayingCard && w.code == code),
          findsOneWidget,
          reason: '$when: seat 1 and the viewer keep $code face up',
        );
      }
    }

    drawnInFull('while the celebration is up');

    // And once the celebration's own clock has run out, with no new deal yet:
    // the hand stays on the felt until the snapshot stops carrying it. The
    // celebration runs to the deal the server SCHEDULED, which the deal can
    // always land a beat after.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.pokerCelebrating, isFalse);
    expect(state.pokerResult, isNotNull, reason: 'the snapshot still has it');
    expect(tester.takeException(), isNull);
    drawnInFull('after the celebration');

    await _teardown(tester, state);
  });

  testWidgets('the clock folding the viewer is said on the felt and as a '
      'notice', (tester) async {
    const t = Strings(AppLang.english);
    final state = _newState(_room(options: _holdemOptions));
    // Somebody else's fold on the clock is not this player's news.
    state.handlePokerAction((
      userId: 'u2',
      seatIndex: 2,
      action: 'fold',
      amount: 0,
      street: 'flop',
      reason: 'timeout',
    ));
    expect(state.notice, isNull);
    expect(state.pokerTimedOutHand, isNull);

    state.handlePokerAction((
      userId: 'u0',
      seatIndex: 0,
      action: 'fold',
      amount: 0,
      street: 'flop',
      reason: 'timeout',
    ));
    expect(state.notice, t.pokerTimedOut);
    expect(state.pokerTimedOutHand, 3);

    // The snapshot that folds them follows; the felt says so for the rest
    // of the hand.
    state.handleState(
      RoomState.fromJson({
        ..._room(myTurn: false).toJson(),
        'you': {..._room().toJson()['you'] as Map, 'status': 'packed'},
      }),
    );
    await _pumpTable(tester, state);
    expect(tester.takeException(), isNull);
    expect(find.text(t.pokerTimedOut), findsOneWidget);

    // The next deal clears it.
    state.handleState(
      RoomState.fromJson({..._room(options: _holdemOptions).toJson(), 'handNo': 4}),
    );
    expect(state.pokerTimedOutHand, isNull);
    await _teardown(tester, state);
  });

  testWidgets('the deal flies as many cards as the game gives each player, '
      'the hand comes in one card at a time, and a new board card lands '
      'where it lies', (tester) async {
    final state = _newState(
      _room(
        variant: 'omaha',
        cards: 4,
        myCards: const ['Ks', 'Kd', 'Qh', 'Jc'],
        options: _holdemOptions,
      ),
    );
    await _pumpTable(tester, state, screen: const Size(914, 411), textScale: 1);
    expect(tester.takeException(), isNull);

    Finder inDeal(Type type) => find.descendant(
      of: find.byType(DealFlights),
      matching: find.byType(type),
    );
    // Omaha deals four, and the felt says so rather than the Teen Patti three.
    expect(tester.widget<DealFlights>(find.byType(DealFlights)).cards, 4);
    // A hand already under way when the client arrived is not re-dealt.
    expect(inDeal(CustomPaint), findsNothing);

    // The next deal puts cards in the air, through the Teen Patti felt's own
    // flight layer.
    state.handleState(
      RoomState.fromJson({
        ..._room(
          variant: 'omaha',
          cards: 4,
          myCards: const ['Ks', 'Kd', 'Qh', 'Jc'],
          community: const [],
          street: 'preflop',
          options: _holdemOptions,
        ).toJson(),
        'handNo': 4,
      }),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(inDeal(CustomPaint), findsOneWidget);

    // The viewer's own four arrive one behind the other, not all at once.
    double ownAlpha(int i, String code) => tester
        .widget<Opacity>(
          find
              .descendant(
                of: find.byKey(ValueKey('own-4-$i-$code')),
                matching: find.byType(Opacity),
              )
              .first,
        )
        .opacity;
    await tester.pump(const Duration(milliseconds: 1));
    expect(
      ownAlpha(0, 'Ks'),
      greaterThan(ownAlpha(3, 'Jc')),
      reason: 'the first card is further along than the last',
    );

    // The flop, and then the turn: a card landing on the board grows and
    // fades in where it lies, once — and only the new one does.
    void street(String name, List<String> community) => state.handleState(
      RoomState.fromJson({
        ..._room(
          variant: 'omaha',
          cards: 4,
          myCards: const ['Ks', 'Kd', 'Qh', 'Jc'],
          community: community,
          street: name,
          options: _holdemOptions,
        ).toJson(),
        'handNo': 4,
      }),
    );
    street('flop', const ['Ah', '7d', '9c']);
    await tester.pump();
    await tester.pump(Motion.enter);
    street('turn', const ['Ah', '7d', '9c', '2s']);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    Opacity boardCard(String code) => tester.widget<Opacity>(
      find
          .descendant(
            of: find.byKey(ValueKey('board-$code')),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(boardCard('2s').opacity, lessThan(0.2), reason: 'the new card');
    expect(boardCard('Ah').opacity, 1.0, reason: 'the flop does not replay');
    await tester.pump(Motion.enter);
    expect(boardCard('2s').opacity, 1.0);
    expect(tester.takeException(), isNull);

    await _teardown(tester, state);
  });

  testWidgets("the table menu's header keeps the whole game name and no hand "
      'number, and titles the blinds like every other row', (tester) async {
    const t = Strings(AppLang.english);
    for (final (screen, scale) in [
      (const Size(640, 360), 1.25),
      (const Size(914, 411), 1.0), // a Pixel 6, where it was cut
    ]) {
      final state = _newState(_room(options: _holdemOptions));
      await _pumpTable(tester, state, screen: screen, textScale: scale);
      state.tableScaffold.currentState!.openDrawer();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);

      // The game's name alone: the hand number that followed it ("· hand 3")
      // went on 24 Sep 2026 (owner: "some hand info text is visible, remove
      // that text from UI").
      final header = find.text(t.pokerVariantName('texas_holdem'));
      expect(header, findsOneWidget, reason: '$screen');
      expect(
        find.textContaining('hand 3'),
        findsNothing,
        reason: '$screen: the hand number is back in the header',
      );
      // Shrunk to the line, never cut: an ellipsised header reads as a
      // different game ("Texas Hold'em · …", Pixel 6, 19 Sep 2026).
      expect(
        tester.renderObject<RenderParagraph>(header).didExceedMaxLines,
        isFalse,
        reason: '$screen: the header is ellipsised',
      );

      // "Blinds", not "blinds": a row title beside "Your chips".
      expect(find.text(t.blindsTitle), findsOneWidget, reason: '$screen');
      expect(find.text(t.blindsLabel), findsNothing, reason: '$screen');
      expect(
        t.blindsTitle,
        isNot(t.blindsLabel),
        reason: 'the card label is lowercase, the row title is not',
      );
      await _teardown(tester, state);
    }
  });

  testWidgets('the timeout notice reaches the screen as a toast', (
    tester,
  ) async {
    const t = Strings(AppLang.english);
    final state = _newState(_room(options: _holdemOptions));
    // The app's OWN root, not the bare harness above: the toast is raised on
    // the transparent Scaffold `KingTeenPattiApp` wraps the Navigator in
    // (main.dart), so showing it at all depends on that plumbing.
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final feedback = FeedbackSettings();
    addTearDown(feedback.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<GameState>.value(value: state),
          ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
        ],
        child: const KingTeenPattiApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text(t.pokerTimedOut), findsNothing);

    state.handlePokerAction((
      userId: 'u0',
      seatIndex: 0,
      action: 'fold',
      amount: 0,
      street: 'flop',
      reason: 'timeout',
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text(t.pokerTimedOut), findsWidgets);
    expect(state.notice, isNull, reason: 'the host clears it once shown');
    await _teardown(tester, state);
  });

  // --- the wire's order: showdown, settle, handEnded, then the snapshot

  group('a finished hand', () {
    Map<String, dynamic> resultJson() => {
      'handId': 'h3',
      'reason': 'showdown',
      'community': ['Ah', '7d', '9c', '2s', 'Kc'],
      'pots': [
        {
          'amount': 2000,
          'eligible': [0, 1],
          'winners': [
            {'userId': 'u0', 'seatIndex': 0, 'amount': 2000, 'handName': 'Three of a Kind'},
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
          'won': 2000,
        },
        {
          'userId': 'u1',
          'seatIndex': 1,
          'cards': ['Ad', '7c'],
          'best': ['Ad', 'Ah', '7c', '7d', 'Kc'],
          'handName': 'Two Pair',
          'category': 2,
          'won': 0,
        },
      ],
    };
    RoomState ended({int? startsAt}) => RoomState.fromJson({
      ..._room(
        street: 'showdown',
        state: 'showdown',
        community: const ['Ah', '7d', '9c', '2s', 'Kc'],
        myTurn: false,
        result: resultJson(),
      ).toJson(),
      'startsAt': ?startsAt,
    });
    PokerShowdownNews showdown() => (
      result: PokerResult.fromJson({...resultJson(), 'handId': '', 'pots': []}),
      nextHandAt: 0,
      reason: 'showdown',
      ended: false,
    );
    PokerShowdownNews handEnded(int nextHandAt) => (
      result: PokerResult.fromJson(resultJson()),
      nextHandAt: nextHandAt,
      reason: 'showdown',
      ended: true,
    );

    test('is drawn from the events, and the snapshot after them adds no '
        'second celebration', () async {
      final state = _newState(_room(myTurn: false));
      var notified = 0;
      state.addListener(() => notified++);
      final nextHandAt = _now + 400;

      state.handlePokerShowdown(showdown());
      expect(state.pokerCelebrating, isTrue);
      expect(state.pokerShowing, isTrue);
      expect(state.pokerResult!.reveals, hasLength(2));
      expect(state.pokerResult!.pots, isEmpty, reason: 'the reveal frame');
      expect(state.winnerId, isNull, reason: 'no pots yet');

      state.handlePokerShowdown(handEnded(nextHandAt));
      expect(state.pokerResult!.pots, hasLength(1));
      expect(state.winnerId, 'u0');
      expect(state.iWon, isTrue);
      expect(state.winnerPot, 2000);
      expect(state.showdownResult, isNotEmpty);

      final before = notified;
      state.handleState(ended(startsAt: nextHandAt));
      expect(state.pokerCelebrating, isTrue);
      expect(state.pokerShowing, isTrue);
      expect(notified, before + 1, reason: 'one notify for the snapshot');

      // The celebration ends when the next hand is due, not before.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(state.pokerCelebrating, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(state.pokerCelebrating, isFalse);
      expect(state.pokerShowing, isFalse);
      // The snapshot still holds the result; the felt only stops showing
      // it as finished.
      expect(state.room!.poker!.result, isNotNull);
      state.dispose();
    });

    test('is drawn from the snapshot alone, for a client that reconnected '
        'into it', () async {
      final state = _newState(_room(myTurn: false));
      state.handleState(ended(startsAt: _now + 300));
      expect(state.pokerCelebrating, isTrue);
      expect(state.pokerShowing, isTrue);
      expect(state.pokerResult!.reveals, hasLength(2));
      expect(state.winnerId, 'u0');
      expect(state.iWon, isTrue);
      // A second snapshot of the same finished hand changes nothing.
      state.handleState(ended(startsAt: _now + 300));
      expect(state.pokerCelebrating, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(state.pokerCelebrating, isFalse);
      state.dispose();
    });

    test('celebrated from the snapshot first is not celebrated again by a '
        'late event, and the next deal clears it', () {
      final state = _newState(_room(myTurn: false));
      state.handleState(ended());
      expect(state.pokerCelebrating, isTrue);
      state.handlePokerShowdown(handEnded(_now + 4000));
      expect(state.pokerCelebrating, isTrue);
      expect(state.pokerResult!.pots, hasLength(1));

      state.handleState(
        RoomState.fromJson({..._room(myTurn: false).toJson(), 'handNo': 4}),
      );
      expect(state.pokerCelebrating, isFalse);
      expect(state.pokerResult, isNull);
      expect(state.winnerId, isNull);
      expect(state.showdownResult, isEmpty);
      state.dispose();
    });
  });
}

/// The snapshot as JSON again, so a test can vary one key of it. Only the
/// keys the tests vary are written out; the rest round-trip through the
/// fixture.
extension on RoomState {
  Map<String, dynamic> toJson({String? handName}) => {
    'roomId': roomId,
    'code': code,
    'category': category,
    'game': game,
    'chipsHidden': chipsHidden,
    'state': state,
    'handNo': handNo,
    'dealerSeat': dealerSeat,
    'maxPlayers': 5,
    'minPlayers': minPlayers,
    'bootAmount': bootAmount,
    'turnTimeoutMs': turnTimeoutMs,
    'startsAt': startsAt == 0 ? null : startsAt,
    'pot': pot,
    'turn': turn == null
        ? null
        : {
            'seatIndex': turn!.seatIndex,
            'userId': turn!.userId,
            'deadline': turn!.deadline,
          },
    'you': {
      'seatIndex': you!.seatIndex,
      'chips': you!.chips,
      'status': you!.status,
      'cards': you!.cards,
      'contributed': you!.contributed,
      'streetBet': you!.streetBet,
      'allIn': you!.allIn,
      'missedTurns': you!.missedTurns,
      'maxMissedTurns': you!.maxMissedTurns,
      if (you!.pokerOptions != null)
        'options': {
          'street': you!.pokerOptions!.street,
          'fold': you!.pokerOptions!.fold,
          'check': you!.pokerOptions!.check,
          'call': you!.pokerOptions!.call,
          'callAmount': you!.pokerOptions!.callAmount,
          'bet': you!.pokerOptions!.bet,
          'minBet': you!.pokerOptions!.minBet,
          'maxBet': you!.pokerOptions!.maxBet,
          'raise': you!.pokerOptions!.raise,
          'minRaise': you!.pokerOptions!.minRaise,
          'maxRaise': you!.pokerOptions!.maxRaise,
          'play': you!.pokerOptions!.play,
          'playAmount': you!.pokerOptions!.playAmount,
          'draw': you!.pokerOptions!.draw,
          'maxDiscards': you!.pokerOptions!.maxDiscards,
        },
      if (handName != null)
        'hand': {
          'category': 4,
          'handName': handName,
          'cards': you!.cards,
          'best': you!.cards,
        },
    },
    'seats': [
      for (final s in seats)
        {
          'seatIndex': s.seatIndex,
          'userId': s.userId,
          'displayName': s.displayName,
          'avatarUrl': s.avatarUrl,
          'chips': s.chips,
          'status': s.status,
          'connected': s.connected,
          'cardCount': s.cardCount,
          'contributed': s.contributed,
          'streetBet': s.streetBet,
          'allIn': s.allIn,
          'lastAction': s.lastAction,
          'dealer': s.dealer,
        },
    ],
    'poker': {
      'variant': poker!.variant,
      'street': poker!.street,
      'community': poker!.community,
      'pots': [
        for (final p in poker!.pots)
          {
            'amount': p.amount,
            'eligible': p.eligible,
            'winners': [
              for (final w in p.winners)
                {
                  'userId': w.userId,
                  'seatIndex': w.seatIndex,
                  'amount': w.amount,
                  'handName': w.handName,
                },
            ],
          },
      ],
      'currentBet': poker!.currentBet,
      'minRaise': poker!.minRaise,
      'smallBlind': poker!.smallBlind,
      'bigBlind': poker!.bigBlind,
      'ante': poker!.ante,
      'holeCards': poker!.holeCards,
      'maxDiscards': poker!.maxDiscards,
      'minBuyIn': poker!.minBuyIn,
      if (poker!.dealer != null)
        'dealer': {
          'cardCount': poker!.dealer!.cardCount,
          'cards': poker!.dealer!.cards,
          'handName': poker!.dealer!.handName,
          'category': poker!.dealer!.category,
          'qualified': ?poker!.dealer!.qualified,
        },
      if (poker!.result != null)
        'result': {
          'handId': poker!.result!.handId,
          'reason': poker!.result!.reason,
          'community': poker!.result!.community,
          'pots': [
            for (final p in poker!.result!.pots)
              {
                'amount': p.amount,
                'eligible': p.eligible,
                'winners': [
                  for (final w in p.winners)
                    {
                      'userId': w.userId,
                      'seatIndex': w.seatIndex,
                      'amount': w.amount,
                      'handName': w.handName,
                    },
                ],
              },
          ],
          'reveals': [
            for (final r in poker!.result!.reveals)
              {
                'userId': r.userId,
                'seatIndex': r.seatIndex,
                'cards': r.cards,
                'best': r.best,
                'handName': r.handName,
                'category': r.category,
                'won': r.won,
                'outcome': ?r.outcome,
              },
          ],
          if (poker!.result!.dealer != null)
            'dealer': {
              'cardCount': poker!.result!.dealer!.cardCount,
              'cards': poker!.result!.dealer!.cards,
              'handName': poker!.result!.dealer!.handName,
              'category': poker!.result!.dealer!.category,
              'qualified': ?poker!.result!.dealer!.qualified,
            },
        },
    },
  };
}
