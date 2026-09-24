// The Teen Patti table in each state the table polish brief names (24 Sep
// 2026), built from room:state JSON as the server sends it, and the app it is
// mounted in. Not a test file: test/table_shots.dart pictures these scenes and
// test/table_polish_test.dart lays them out.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/widgets/buy_chips.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/rules_sheet.dart';

int get _now => DateTime.now().millisecondsSinceEpoch;

const _ids = ['u0', 'u1', 'u2', 'u3', 'u4'];
const _names = ['Priya', 'Ravi', 'Meera', 'Arjun', 'Vikramaditya'];

Map<String, dynamic> _seat(
  int i, {
  String status = 'active',
  bool blind = true,
  int lastBet = 400,
  int contributed = 1400,
  int? chips,
  bool connected = true,
  String lastAction = 'chaal',
}) => {
  'seatIndex': i,
  'userId': _ids[i],
  'displayName': _names[i],
  'avatarUrl': null,
  'chips': chips,
  'status': status,
  'isBlind': blind,
  'lastBet': lastBet,
  'lastAction': lastAction,
  'contributed': contributed,
  'connected': connected,
  'cardCount': 3,
};

RoomState _room({
  String category = 'blind',
  int boot = 200,
  String state = 'betting',
  int handNo = 7,
  int pot = 6800,
  int stake = 400,
  int maxPot = 0,
  int? turnSeat,
  int turnLeftMs = 14000,
  required List<Map<String, dynamic>> seats,
  required Map<String, dynamic> you,
  Map<String, dynamic>? sideshow,
}) => RoomState.fromJson({
  'roomId': 'r1',
  'code': 'ABCD2345',
  'category': category,
  'chipsHidden': category != 'seen',
  'state': state,
  'handNo': handNo,
  'dealerSeat': 3,
  'maxPlayers': 5,
  'minPlayers': 2,
  'bootAmount': boot,
  'turnTimeoutMs': 25000,
  'startsAt': 0,
  'pot': pot,
  'maxPot': maxPot,
  'stake': stake,
  'turn': turnSeat == null
      ? {'seatIndex': -1, 'userId': null, 'deadline': 0}
      : {
          'seatIndex': turnSeat,
          'userId': _ids[turnSeat],
          'deadline': _now + turnLeftMs,
        },
  'you': you,
  'seats': seats,
  'sideshow': ?sideshow,
});

Map<String, dynamic> _you({
  String status = 'active',
  bool blind = true,
  List<String> cards = const [],
  int blindMovesLeft = 3,
  Map<String, dynamic>? options,
  bool canMissile = false,
  int chips = 245000,
}) => {
  'seatIndex': 0,
  'chips': chips,
  'status': status,
  'isBlind': blind,
  'blindMovesLeft': blindMovesLeft,
  'contributed': 1400,
  'missedTurns': 0,
  'maxMissedTurns': 3,
  'cards': cards,
  'canMissile': canMissile,
  'options': ?options,
};

/// Five at a blind table, the viewer blind and every stack but theirs hidden.
List<Map<String, dynamic>> _blindSeats() => [
  _seat(0, chips: 245000),
  _seat(1),
  _seat(2, blind: false, lastBet: 800, contributed: 2200),
  _seat(3),
  _seat(4, blind: false, lastBet: 800, contributed: 1800),
];

/// Five at a seen table, stacks public, most of them looking.
List<Map<String, dynamic>> _seenSeats({List<String> packed = const []}) => [
  for (var i = 0; i < 5; i++)
    _seat(
      i,
      chips: [245000, 1820000, 96000, 12500000, 530000][i],
      blind: i == 2,
      lastBet: i == 2 ? 400 : 800,
      contributed: [2600, 2600, 1400, 2600, 3400][i],
      status: packed.contains(_ids[i]) ? 'packed' : 'active',
    ),
];

/// What a scene does once the table is up: open a drawer, ask a question.
typedef SceneAct = Future<void> Function(WidgetTester tester, GameState state);

/// One state of the table: the snapshots that put it there, and what the
/// player does next, if anything.
class TableScene {
  const TableScene(this.name, this.setup, [this.act]);
  final String name;
  final void Function(GameState state) setup;
  final SceneAct? act;
}

/// Opens the table's menu drawer, as the rail's key does.
Future<void> openMenu(WidgetTester tester, GameState state) async {
  state.tableScaffold.currentState!.openDrawer();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// Opens the chat drawer from the rail.
Future<void> openChat(WidgetTester tester, GameState state) async {
  await tester.tap(find.byTooltip(state.t.tableChat).first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

ChatMessage _line(String? id, String name, String text) =>
    ChatMessage.fromJson({
      'messageId': '$id-$text',
      'userId': id,
      'displayName': name,
      'text': text,
      'at': 0,
      if (id == null) 'system': true,
    });

/// A conversation with two lines the table wrote itself among the players'.
void chatHistory(GameState state) {
  state.chat
    ..add(_line(null, 'Table', 'Vikramaditya joined the table'))
    ..add(_line('u1', 'Ravi', 'Good luck everyone'))
    ..add(_line('u2', 'Meera', 'Please Play fast.'))
    ..add(_line('u0', 'Priya', 'All the best'))
    ..add(
      _line('u4', 'Vikramaditya', 'That was a close one, next hand is mine'),
    )
    ..add(_line(null, 'Table', 'Kavya left the table'))
    ..add(_line('u3', 'Arjun', 'Oops! I should not have played it.'));
}

/// The viewer's seen turn with Sideshow and Force Sideshow on offer — every
/// kind of key on the console lit at once.
RoomState seenTurnRoom() => _room(
  category: 'seen',
  maxPot: 2000000,
  stake: 400,
  turnSeat: 0,
  seats: _seenSeats(),
  you: _you(
    blind: false,
    cards: const ['As', 'Kd', 'Qh'],
    blindMovesLeft: 0,
    canMissile: true,
    options: {
      'canSee': false,
      'canPack': true,
      'canSideshow': true,
      'canForceSideshow': true,
      'sideshowWith': 'Vikramaditya',
      'raiseSteps': [800, 1600],
      'chips': 245000,
      'currentStake': 400,
    },
  ),
);

/// Somebody else's turn at a blind table: nothing on the console to press.
RoomState opponentTurnRoom() =>
    _room(turnSeat: 2, seats: _blindSeats(), you: _you());

final tableScenes = <TableScene>[
  TableScene('01-opponent-turn', (s) => s.handleState(opponentTurnRoom())),
  TableScene('02-your-turn-blind', (s) {
    s.handleState(
      _room(
        turnSeat: 0,
        seats: _blindSeats(),
        you: _you(
          canMissile: true,
          options: {
            'canSee': true,
            'canPack': true,
            'canSideshow': false,
            'canForceSideshow': false,
            'raiseSteps': [400, 800],
            'chips': 245000,
            'currentStake': 400,
          },
        ),
      ),
    );
  }),
  TableScene('03-your-turn-seen-sideshow', (s) {
    s.handleState(seenTurnRoom());
  }),
  TableScene('04-heads-up-show-packed-seats', (s) {
    s.handleState(
      _room(
        category: 'seen',
        maxPot: 2000000,
        turnSeat: 0,
        seats: _seenSeats(packed: ['u1', 'u2', 'u4']),
        you: _you(
          blind: false,
          cards: const ['7s', '7d', 'Kc'],
          blindMovesLeft: 0,
          options: {
            'canSee': false,
            'canPack': true,
            'canSideshow': false,
            'raiseSteps': [800, 1600],
            'show': 800,
            'chips': 245000,
            'currentStake': 400,
          },
        ),
      ),
    );
  }),
  TableScene('05-you-packed', (s) {
    final seats = _blindSeats();
    seats[0] = _seat(0, chips: 245000, status: 'packed');
    s.handleState(
      _room(
        turnSeat: 3,
        seats: seats,
        you: _you(status: 'packed'),
      ),
    );
  }),
  TableScene('06-showdown-card-reveal', (s) {
    final seats = _seenSeats(packed: ['u1', 'u4']);
    seats[0]['status'] = 'lost';
    seats[2]['status'] = 'lost';
    seats[3]['status'] = 'won';
    s.handleState(
      _room(
        category: 'seen',
        state: 'showdown',
        maxPot: 2000000,
        pot: 14200,
        seats: seats,
        you: _you(
          status: 'lost',
          blind: false,
          cards: const ['7s', '7d', 'Kc'],
          blindMovesLeft: 0,
        ),
      ),
    );
    s.handleShowdown((
      reveals: [
        Reveal.fromJson({
          'userId': 'u0',
          'displayName': 'Priya',
          'cards': ['7s', '7d', 'Kc'],
          'handName': 'Pair',
          'won': false,
        }),
        Reveal.fromJson({
          'userId': 'u2',
          'displayName': 'Meera',
          'cards': ['9h', '8h', '2c'],
          'handName': 'High Card',
          'won': false,
        }),
        Reveal.fromJson({
          'userId': 'u3',
          'displayName': 'Arjun',
          'cards': ['Qs', 'Js', 'Ts'],
          'handName': 'Pure Sequence',
          'won': true,
        }),
      ],
      result: 'show',
      winnerId: 'u3',
      winnerName: 'Arjun',
      pot: 14200,
      nextHandAt: _now + 60000,
      reason: 'show',
    ));
  }),
  TableScene('07-you-won', (s) {
    final seats = _seenSeats(packed: ['u1', 'u3', 'u4']);
    seats[0]['status'] = 'won';
    seats[2]['status'] = 'lost';
    s.handleState(
      _room(
        category: 'seen',
        state: 'showdown',
        maxPot: 2000000,
        pot: 14200,
        seats: seats,
        you: _you(
          status: 'won',
          blind: false,
          cards: const ['Ah', 'Ad', 'Ac'],
          blindMovesLeft: 0,
        ),
      ),
    );
    s.handleShowdown((
      reveals: [
        Reveal.fromJson({
          'userId': 'u0',
          'displayName': 'Priya',
          'cards': ['Ah', 'Ad', 'Ac'],
          'handName': 'Trail',
          'won': true,
        }),
        Reveal.fromJson({
          'userId': 'u2',
          'displayName': 'Meera',
          'cards': ['9h', '8h', '2c'],
          'handName': 'High Card',
          'won': false,
        }),
      ],
      result: 'show',
      winnerId: 'u0',
      winnerName: 'Priya',
      pot: 14200,
      nextHandAt: _now + 60000,
      reason: 'show',
    ));
  }),
  TableScene('08-sideshow-asked', (s) {
    s.handleState(
      _room(
        category: 'seen',
        maxPot: 2000000,
        turnSeat: 4,
        seats: _seenSeats(),
        you: _you(
          blind: false,
          cards: const ['Jc', 'Jd', '4s'],
          blindMovesLeft: 0,
        ),
        sideshow: {
          'fromUserId': 'u4',
          'fromSeat': 4,
          'toUserId': 'u0',
          'toSeat': 0,
          'expiresAt': _now + 4000,
        },
      ),
    );
  }),
  TableScene('09-waiting', (s) {
    s.handleState(
      _room(
        state: 'waiting',
        handNo: 0,
        pot: 0,
        seats: [
          _seat(0, chips: 245000, status: 'waiting', contributed: 0),
          _seat(1, status: 'waiting', contributed: 0),
        ],
        you: _you(status: 'waiting'),
      ),
    );
  }),
  TableScene('10-menu-drawer', (s) {
    s.handleState(
      _room(category: 'seen', turnSeat: 2, seats: _seenSeats(), you: _you()),
    );
  }, openMenu),
  TableScene('11-chat-drawer', (s) {
    s.handleState(opponentTurnRoom());
    chatHistory(s);
  }, openChat),
  TableScene('12-quick-messages', (s) => s.handleState(opponentTurnRoom()), (
    tester,
    state,
  ) async {
    await openChat(tester, state);
    await tester.tap(find.text(state.t.quickMessagesTitle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }),
  TableScene('13-rules', (s) => s.handleState(opponentTurnRoom()), (
    tester,
    state,
  ) async {
    showRules(tester.element(find.byType(TableScreen)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }),
  TableScene('14-leave-dialog', (s) => s.handleState(opponentTurnRoom()), (
    tester,
    state,
  ) async {
    await openMenu(tester, state);
    await tester.tap(find.text(state.t.leaveTable));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }),
  TableScene('15-poker-holdem', (s) => s.handleState(pokerRoom())),
  TableScene('16-store-from-table', (s) => s.handleState(opponentTurnRoom()), (
    tester,
    state,
  ) async {
    await tester.tap(find.byType(ShopButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
  }),
];

/// A Hold'em flop with the viewer to call — the poker felt the shared chrome
/// also serves.
RoomState pokerRoom() => RoomState.fromJson({
  'roomId': 'p1',
  'code': 'ABCD2345',
  'category': 'texas_holdem',
  'game': 'poker',
  'chipsHidden': true,
  'state': 'betting',
  'handNo': 3,
  'dealerSeat': 4,
  'maxPlayers': 5,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'pot': 2000,
  'turn': {'seatIndex': 0, 'userId': 'u0', 'deadline': _now + 15000},
  'you': {
    'seatIndex': 0,
    'chips': 20000,
    'status': 'active',
    'cards': ['Ks', 'Kd'],
    'contributed': 400,
    'streetBet': 200,
    'missedTurns': 0,
    'maxMissedTurns': 3,
    'options': {
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
      'play': false,
      'playAmount': 0,
      'draw': false,
      'maxDiscards': 0,
    },
  },
  'seats': [
    for (var i = 0; i < 5; i++)
      {
        'seatIndex': i,
        'userId': _ids[i],
        'displayName': _names[i],
        'chips': i == 0 ? 20000 : null,
        'status': 'active',
        'connected': true,
        'cardCount': 2,
        'contributed': 400,
        'streetBet': 200,
        'lastAction': 'call',
      },
  ],
  'poker': {
    'variant': 'texas_holdem',
    'street': 'flop',
    'community': ['Ah', '7d', '9c'],
    'pots': [
      {
        'amount': 2000,
        'eligible': [0, 1, 2, 3, 4],
      },
    ],
    'currentBet': 400,
    'minRaise': 200,
    'smallBlind': 100,
    'bigBlind': 200,
    'ante': 0,
    'holeCards': 2,
    'maxDiscards': 0,
    'minBuyIn': 2000,
  },
});

/// Feedback with the sound off: the win sound would reach for an audio plugin
/// a test has not got.
Future<FeedbackSettings> silentFeedback() async {
  SharedPreferences.setMockInitialValues({'soundOn': false});
  final feedback = FeedbackSettings();
  await feedback.load();
  return feedback;
}

/// A GameState seated as Priya (u0) and put into [scene].
GameState sceneState(TableScene scene, {AppLang lang = AppLang.english}) {
  // Play is never started here; the override only keeps the purchase plugin
  // from registering an Android billing client in a test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  state
    ..lang = lang
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Priya',
      'chips': 245000,
      'diamond': 9,
      'hammer': 20,
      'missile': 1,
    })
    ..screen = Screen.table;
  scene.setup(state);
  return state;
}

/// The table as the app mounts it: the providers, the text scale clamped to
/// the app's ceiling, the one glass budget, and the root Scaffold the toasts
/// are painted on.
Widget tableApp({
  required GameState state,
  required FeedbackSettings feedback,
  required ThemeData theme,
}) => MultiProvider(
  providers: [
    ChangeNotifierProvider<GameState>.value(value: state),
    ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
  ],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (context, child) => MediaQuery.withClampedTextScaling(
      minScaleFactor: 0.9,
      maxScaleFactor: 1.25,
      child: GlassBudget(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          resizeToAvoidBottomInset: false,
          body: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
    home: const TableScreen(),
  ),
);
