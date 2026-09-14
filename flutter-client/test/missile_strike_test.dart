// A missile volley (owner, 14 Sep 2026): one missile from the firer to every
// other player still in the hand, seen by every viewer; the showdown the
// server sends straight after held until the last missile lands, then the
// cards turned over and the winner celebrated; one volley however many copies
// of its action arrive; and nothing left behind when the hand moves on
// mid-flight.
//
// The events are fed in the order the server sends them: game:action, then
// game:showdown with every hand, the snapshot that settles the seats, and
// game:handEnded.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/game_connection.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/state/missile_strike.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/hammer_flight.dart';
import 'package:teenpatti/widgets/missile_flight.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/seat_pod.dart';

const _ids = ['u0', 'u1', 'u2', 'u3', 'u4'];

const _cards = {
  'u0': ['As', 'Ad', 'Ah'],
  'u1': ['Kc', 'Kd', '4s'],
  'u2': ['Qs', 'Js', 'Ts'],
  'u3': ['9c', '9d', '2h'],
  'u4': ['2c', '7d', '9h'],
};

/// A seen table of five, the viewer (u0) in seat 0. [status] overrides a
/// seat's status by user id; [turn] is who is to act.
RoomState _room({
  int handNo = 4,
  Map<String, String> status = const {},
  String state = 'betting',
  String? turn = 'u0',
  int pot = 6000,
}) {
  String statusOf(String id) => status[id] ?? 'active';
  final onTurn = turn == 'u0' && state == 'betting';
  return RoomState.fromJson({
    'roomId': 'r1',
    'code': 'ABCD2345',
    'category': 'seen',
    'chipsHidden': false,
    'state': state,
    'handNo': handNo,
    'dealerSeat': 2,
    'minPlayers': 2,
    'bootAmount': 200,
    'turnTimeoutMs': 25000,
    'startsAt': 0,
    'pot': pot,
    'maxPot': 2000000,
    'stake': 400,
    if (turn != null && state == 'betting')
      'turn': {'seatIndex': _ids.indexOf(turn), 'userId': turn, 'deadline': 0},
    'you': {
      'seatIndex': 0,
      'chips': 200000,
      'status': statusOf('u0'),
      'isBlind': false,
      'blindMovesLeft': 0,
      'contributed': 1200,
      'missedTurns': 0,
      'maxMissedTurns': 3,
      'cards': _cards['u0'],
      'canMissile': onTurn,
      if (onTurn)
        'options': {
          'canSee': false,
          'canPack': true,
          'canSideshow': false,
          'raiseSteps': [800, 1600],
          'chips': 200000,
          'currentStake': 400,
        },
    },
    'seats': [
      for (final (i, id) in _ids.indexed)
        {
          'seatIndex': i,
          'userId': id,
          'displayName': 'Player $i',
          'avatarUrl': null,
          'chips': 200000,
          'status': statusOf(id),
          'isBlind': false,
          'lastBet': 400,
          'lastAction': statusOf(id) == 'packed' ? 'pack' : 'chaal',
          'contributed': 1200,
          'connected': true,
          'cardCount': 3,
        },
    ],
  });
}

({String userId, String action, String? reason}) _missileFrom(String id) =>
    (userId: id, action: GameAction.missile, reason: null);

/// game:showdown for a missile: every hand still in, u2's the best.
ShowdownNews _showdownOf(Iterable<String> inHand) => (
  reveals: [
    for (final id in inHand)
      Reveal.fromJson({
        'userId': id,
        'displayName': 'Player ${id.substring(1)}',
        'cards': _cards[id],
        'handName': id == 'u2' ? 'Pure Sequence' : 'High Card',
        'won': id == 'u2',
      }),
  ],
  result: '',
  winnerId: null,
  winnerName: '',
  pot: 0,
  nextHandAt: 0,
  reason: 'missile',
);

/// game:handEnded for the same hand.
ShowdownNews _handEnded() => (
  reveals: const [],
  result: 'Player 2 won 6,000',
  winnerId: 'u2',
  winnerName: 'Player 2',
  pot: 6000,
  nextHandAt: DateTime.now().millisecondsSinceEpoch + 8000,
  reason: 'missile',
);

/// The rest of a missile's events after its game:action, with every player
/// still in and u2 winning.
void _settle(GameState state, {int handNo = 4}) {
  state
    ..handleShowdown(_showdownOf(_ids))
    ..handleState(
      _room(
        handNo: handNo,
        state: 'showdown',
        turn: null,
        pot: 0,
        status: {for (final id in _ids) id: id == 'u2' ? 'won' : 'lost'},
      ),
    )
    ..handleShowdown(_handEnded());
}

GameState _newState({RoomState? room}) {
  // Play is never started here; the override only keeps the purchase plugin
  // from registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  state
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Player 0',
      'chips': 200000,
      'diamond': 2,
      'hammer': 20,
      'missile': 1,
    })
    ..room = room ?? _room()
    ..screen = Screen.table;
  return state;
}

Future<void> _pumpTable(
  WidgetTester tester,
  GameState state, {
  Size screen = const Size(891, 411),
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  // Parsed for real, so the painter draws the rockets and the blasts.
  await tester.runAsync(MissileArt.load);
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
}

/// Takes the table down and lets every timer it scheduled run out.
Future<void> _teardown(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

SeatPod _podOf(WidgetTester tester, String userId) => tester.widget<SeatPod>(
  find.byWidgetPredicate((w) => w is SeatPod && w.seat?.userId == userId),
);

Finder _private(String type) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

/// The pods whose jolt is wired to a volley.
Iterable<PodImpact> _jolting(WidgetTester tester) => tester
    .widgetList<PodImpact>(find.byType(PodImpact))
    .where((impact) => impact.clock is MissileImpactClock);

/// Whether [userId]'s pod is one of those.
bool _jolts(WidgetTester tester, String userId) => _jolting(tester).any(
  (impact) => find
      .descendant(
        of: find.byWidgetPredicate(
          (w) => w is SeatPod && w.seat?.userId == userId,
        ),
        matching: find.byWidget(impact),
      )
      .evaluate()
      .isNotEmpty,
);

Duration _ms(int ms) => Duration(milliseconds: ms);

/// Everything a held reveal must not have shown yet.
void _expectHeld(WidgetTester tester, GameState state, Iterable<String> ids) {
  expect(state.missileHoldsReveal, isTrue);
  expect(state.showdown, isEmpty);
  expect(state.showdownResult, isEmpty);
  expect(state.winnerId, isNull);
  expect(_private('_Showdown'), findsNothing);
  for (final id in ids) {
    expect(_podOf(tester, id).revealed, isNull, reason: id);
    expect(_podOf(tester, id).seat!.status, SeatState.active, reason: id);
  }
}

/// Everything the released reveal shows.
void _expectReleased(
  WidgetTester tester,
  GameState state,
  Iterable<String> ids,
) {
  expect(state.missileHoldsReveal, isFalse);
  expect(state.showdown, hasLength(5));
  expect(state.winnerId, 'u2');
  expect(_private('_Showdown'), findsOneWidget);
  for (final id in ids) {
    expect(_podOf(tester, id).revealed, _cards[id], reason: id);
  }
  expect(_podOf(tester, 'u2').seat!.status, SeatState.won);
}

void main() {
  testWidgets('your own missile: the reveal waits for the last impact', (
    tester,
  ) async {
    final state = _newState();
    await _pumpTable(tester, state);

    state.handleTableAction(_missileFrom('u0'));
    final strike = state.missileStrike;
    expect(strike, isNotNull);
    expect(strike!.fromUserId, 'u0');
    expect(strike.targetUserIds, ['u1', 'u2', 'u3', 'u4']);
    expect(state.notice, 'You fired a missile');
    expect(state.heldPot, 6000);

    // The server's showdown and settlement arrive in the same breath.
    _settle(state);
    await tester.pump();
    await tester.pump(_ms(16));

    expect(find.byType(MissileFlight), findsOneWidget);
    expect(find.byType(HammerFlight), findsNothing);
    expect(_jolting(tester), hasLength(4));
    for (final id in ['u1', 'u2', 'u3', 'u4']) {
      expect(_jolts(tester, id), isTrue, reason: id);
    }
    expect(_jolts(tester, 'u0'), isFalse, reason: 'the firer is not hit');
    _expectHeld(tester, state, ['u1', 'u2', 'u3', 'u4']);
    expect(state.heldPot, 6000, reason: 'the pot stays until they land');

    // Every missile has landed and the explosions are playing: still held,
    // so the winner is not given away over the blasts.
    await tester.pump(MissileTiming.lastImpact(4) + _ms(200));
    _expectHeld(tester, state, ['u1', 'u2', 'u3', 'u4']);
    expect(state.heldPot, 6000);

    // A breath before the reveal: still held.
    await tester.pump(
      MissileTiming.reveal(4) - MissileTiming.lastImpact(4) - _ms(320),
    );
    _expectHeld(tester, state, ['u1', 'u2', 'u3', 'u4']);

    // The reveal: every hand turns over, and the winner is celebrated.
    await tester.pump(_ms(160));
    await tester.pump();
    _expectReleased(tester, state, ['u1', 'u2', 'u3', 'u4']);
    expect(state.heldPot, isNull);
    expect(find.byType(MissileFlight), findsOneWidget, reason: 'a breath');
    // The missile's own notice is still there; it dropped nothing.
    expect(state.notice, 'You fired a missile');

    // Gone: nothing in the air, the cards and the celebration stay.
    await tester.pump(
      MissileTiming.total(4) - MissileTiming.reveal(4) + _ms(40),
    );
    await tester.pump();
    expect(state.missileStrike, isNull);
    expect(find.byType(MissileFlight), findsNothing);
    expect(_jolting(tester), isEmpty);
    _expectReleased(tester, state, ['u1', 'u2', 'u3', 'u4']);
    expect(tester.takeException(), isNull);

    await _teardown(tester, state);
  });

  testWidgets("an opponent's missile, with the viewer among its targets", (
    tester,
  ) async {
    final state = _newState(room: _room(turn: 'u3'));
    await _pumpTable(tester, state);

    state.handleTableAction(_missileFrom('u3'));
    expect(state.missileStrike!.targetUserIds, ['u0', 'u1', 'u2', 'u4']);
    expect(state.notice, 'Player 3 fired a missile');
    _settle(state);
    await tester.pump();
    await tester.pump(_ms(16));

    expect(find.byType(MissileFlight), findsOneWidget);
    expect(_jolting(tester), hasLength(4));
    expect(_jolts(tester, 'u0'), isTrue, reason: "the viewer's own pod");
    expect(_jolts(tester, 'u3'), isFalse);
    _expectHeld(tester, state, ['u1', 'u2', 'u3', 'u4']);

    await tester.pump(MissileTiming.reveal(4) - _ms(60));
    _expectHeld(tester, state, ['u1', 'u2', 'u3', 'u4']);

    await tester.pump(_ms(100));
    await tester.pump();
    _expectReleased(tester, state, ['u1', 'u2', 'u3', 'u4']);

    await tester.pump(const Duration(seconds: 1));
    expect(state.missileStrike, isNull);
    expect(find.byType(MissileFlight), findsNothing);

    await _teardown(tester, state);
  });

  testWidgets('a missile at a table of three flies two, and only at those '
      'still in', (tester) async {
    final state = _newState(
      room: _room(status: {'u1': 'packed', 'u4': 'packed'}),
    );
    await _pumpTable(tester, state);

    state.handleTableAction(_missileFrom('u0'));
    expect(state.missileStrike!.targetUserIds, ['u2', 'u3']);
    state.handleShowdown(_showdownOf(['u0', 'u2', 'u3']));
    await tester.pump();
    await tester.pump(_ms(16));
    expect(_jolting(tester), hasLength(2));
    expect(_jolts(tester, 'u1'), isFalse);
    expect(state.showdown, isEmpty);

    await tester.pump(MissileTiming.lastImpact(2));
    await tester.pump();
    expect(
      state.showdown,
      isEmpty,
      reason: 'landed, but the explosions are still playing',
    );

    await tester.pump(MissileTiming.reveal(2) - MissileTiming.lastImpact(2));
    await tester.pump();
    expect(state.showdown, hasLength(3));

    await _teardown(tester, state);
  });

  testWidgets('one volley, however many times its action arrives', (
    tester,
  ) async {
    final state = _newState();
    await _pumpTable(tester, state);

    state.handleTableAction(_missileFrom('u0'));
    final strike = state.missileStrike;
    await tester.pump();
    await tester.pump(_ms(200));
    final clock = tester
        .widget<MissileFlight>(find.byType(MissileFlight))
        .clock;
    final before = clock.value;
    expect(before, greaterThan(0));

    state.handleTableAction(_missileFrom('u0'));
    await tester.pump(_ms(16));
    expect(identical(state.missileStrike, strike), isTrue);
    expect(find.byType(MissileFlight), findsOneWidget);
    expect(
      tester.widget<MissileFlight>(find.byType(MissileFlight)).clock.value,
      greaterThan(before),
      reason: 'the volley carried on rather than starting again',
    );

    await _teardown(tester, state);
  });

  testWidgets('a showdown with no missile in the air is shown at once', (
    tester,
  ) async {
    final state = _newState(
      room: _room(status: {for (final id in _ids.skip(1)) id: 'packed'}),
    );
    await _pumpTable(tester, state);

    // Nobody left to aim at: no volley, and nothing held.
    state.handleTableAction(_missileFrom('u0'));
    expect(state.missileStrike, isNull);
    expect(state.missileHoldsReveal, isFalse);
    state.handleShowdown(_handEnded());
    await tester.pump();
    expect(state.winnerId, 'u2');
    expect(find.byType(MissileFlight), findsNothing);

    await _teardown(tester, state);
  });

  const screens = [Size(640, 360), Size(891, 411), Size(1280, 800)];
  for (final screen in screens) {
    final name = '${screen.width.toInt()}x${screen.height.toInt()}';
    testWidgets(
      'at $name a new hand mid-flight takes the volley down cleanly',
      (tester) async {
        final state = _newState();
        await _pumpTable(tester, state, screen: screen);

        state.handleTableAction(_missileFrom('u0'));
        _settle(state);
        await tester.pump();
        // Through launch and most of the flight, frame by frame, so every
        // stage of the painter runs at this size.
        for (var i = 0; i < 45; i++) {
          await tester.pump(_ms(16));
        }
        expect(find.byType(MissileFlight), findsOneWidget);
        expect(_jolting(tester), hasLength(4));

        // The next deal lands while the missiles are still in the air.
        state.handleState(_room(handNo: 5));
        await tester.pump();
        await tester.pump(_ms(16));
        expect(state.missileStrike, isNull);
        expect(state.missileHoldsReveal, isFalse);
        expect(find.byType(MissileFlight), findsNothing);
        expect(_jolting(tester), isEmpty);

        // The old volley's timers find nothing to release, and never raise
        // its showdown over the new hand.
        await tester.pump(const Duration(seconds: 3));
        expect(state.showdown, isEmpty);
        expect(state.winnerId, isNull);
        expect(_podOf(tester, 'u1').revealed, isNull);

        // And the next missile, in the new hand, flies all the way through
        // its impacts and its smoke.
        state.handleTableAction(_missileFrom('u0'));
        _settle(state, handNo: 5);
        await tester.pump();
        // The whole volley, to a breath past the reveal: 2.03 s for four.
        for (var i = 0; i < 180; i++) {
          await tester.pump(_ms(16));
        }
        expect(state.missileStrike, isNull);
        expect(find.byType(MissileFlight), findsNothing);
        expect(state.winnerId, 'u2');
        expect(tester.takeException(), isNull);

        await _teardown(tester, state);
      },
    );
  }
}
