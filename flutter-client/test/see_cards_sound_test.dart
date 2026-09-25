// A look at a hand is heard (owner, 26 Sep 2026: "this sound should be played
// when player see cards — when I see card then also and someone also see card
// then also, I should hear this sound"): assets/sound/see card sound.mp3,
// played by FeedbackSettings.cards(), which TurnBuzzer calls the moment a
// player dealt into the hand turns from blind to seen — the viewer or anybody
// else at the table, by a tap on See cards or by the reveal the fourth blind
// bet forces.
//
// Two things were wrong with the look it used to hear: it was the quietest of
// a chain in which only one sound played a frame, so the chips of that fourth
// blind bet drowned the cards turning over in the same snapshot; and it counted
// seats rather than players, and an empty seat reads as seen (the wire leaves
// `isBlind` out), so a blind player getting up sounded like a player looking.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/widgets/table_chrome.dart';

/// Every sound and buzz the table asks for, in order.
class _Heard extends FeedbackSettings {
  final heard = <String>[];

  @override
  void cards() => heard.add('see');

  @override
  void potGrew() => heard.add('coins');

  @override
  void win() => heard.add('win');

  @override
  void turn() => heard.add('turn');

  @override
  void missedTurn() => heard.add('missed');

  @override
  void alarm() => heard.add('alarm');
}

const _ids = ['u0', 'u1', 'u2', 'u3'];

/// A seen table of four, the viewer (u0) in seat 0 and u1 on turn. [seen] are
/// the players who have looked; [status] overrides a seat's (`empty` leaves
/// the place unoccupied, as the wire does).
RoomState _room({
  int handNo = 7,
  int pot = 1600,
  Set<String> seen = const {},
  Map<String, String> status = const {},
  bool poker = false,
}) {
  String statusOf(String id) => status[id] ?? 'active';
  return RoomState.fromJson({
    'roomId': 'r1',
    'code': 'ABCD2345',
    'category': poker ? 'texas_holdem' : 'seen',
    if (poker) 'game': 'poker',
    'chipsHidden': poker,
    'state': 'betting',
    'handNo': handNo,
    'dealerSeat': 3,
    'maxPlayers': 5,
    'minPlayers': 2,
    'bootAmount': 200,
    'turnTimeoutMs': 25000,
    'startsAt': 0,
    'pot': pot,
    'maxPot': 2000000,
    'stake': 200,
    'turn': {'seatIndex': 1, 'userId': 'u1', 'deadline': 0},
    'you': {
      'seatIndex': 0,
      'chips': 100000,
      'status': statusOf('u0'),
      'isBlind': !seen.contains('u0'),
      'contributed': 200,
      'missedTurns': 0,
      'maxMissedTurns': 3,
      'cards': seen.contains('u0')
          ? const ['As', 'Kd', 'Qh']
          : const <String>[],
    },
    'seats': [
      for (final (i, id) in _ids.indexed)
        if (statusOf(id) == SeatState.empty)
          {'seatIndex': i, 'status': SeatState.empty}
        else
          {
            'seatIndex': i,
            'userId': id,
            'displayName': 'Player $i',
            'chips': 100000,
            'status': statusOf(id),
            'isBlind': !seen.contains(id),
            'lastBet': 200,
            'contributed': 200,
            'connected': true,
            'cardCount': 3,
          },
    ],
  });
}

Future<(GameState, _Heard)> _mount(WidgetTester tester, RoomState room) async {
  // Play is never started here; the override only keeps the purchase plugin
  // from registering an Android billing client in a test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  state
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Player 0',
      'chips': 100000,
    })
    ..screen = Screen.table
    ..handleState(room);
  final heard = _Heard();
  addTearDown(heard.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: heard),
      ],
      child: const MaterialApp(home: Scaffold(body: TurnBuzzer())),
    ),
  );
  await tester.pump();
  return (state, heard);
}

Future<void> _snapshot(
  WidgetTester tester,
  GameState state,
  RoomState room,
) async {
  state.handleState(room);
  await tester.pump();
}

void main() {
  testWidgets('another player looking at their cards is heard, once', (
    tester,
  ) async {
    final (state, heard) = await _mount(tester, _room());
    expect(heard.heard, isEmpty);

    await _snapshot(tester, state, _room(seen: {'u2'}));
    expect(heard.heard, ['see']);

    // The same table again (the snapshot after a chat line, the reward
    // clock's tick): nothing new was looked at.
    await _snapshot(tester, state, _room(seen: {'u2'}));
    state.notifyListeners();
    await tester.pump();
    expect(heard.heard, ['see']);

    // And the next look is heard too.
    await _snapshot(tester, state, _room(seen: {'u2', 'u3'}));
    expect(heard.heard, ['see', 'see']);
    state.dispose();
  });

  testWidgets('the viewer looking at their own cards is heard', (
    tester,
  ) async {
    final (state, heard) = await _mount(tester, _room());
    await _snapshot(tester, state, _room(seen: {'u0'}));
    expect(heard.heard, ['see']);
    state.dispose();
  });

  testWidgets('the fourth blind bet grows the pot and turns the cards over: '
      'both are heard', (tester) async {
    final (state, heard) = await _mount(tester, _room());
    await _snapshot(tester, state, _room(pot: 2000, seen: {'u1'}));
    expect(heard.heard, ['coins', 'see']);
    state.dispose();
  });

  testWidgets('a new deal, a blind player getting up or somebody sitting '
      'down is no look', (tester) async {
    final (state, heard) = await _mount(tester, _room(seen: {'u1', 'u2'}));

    // The next hand: everybody blind again.
    await _snapshot(tester, state, _room(handNo: 8));
    // A blind player gets up: the empty place reads as seen on the wire.
    await _snapshot(
      tester,
      state,
      _room(handNo: 8, status: {'u3': SeatState.empty}),
    );
    // Somebody sits down to wait for the next deal, not blind.
    await _snapshot(
      tester,
      state,
      _room(handNo: 8, status: {'u3': SeatState.waiting}, seen: {'u3'}),
    );
    expect(heard.heard, isEmpty);

    // A seen player gets up, and then somebody else looks: that is heard.
    await _snapshot(
      tester,
      state,
      _room(handNo: 8, status: {'u3': SeatState.empty}, seen: {'u2'}),
    );
    expect(heard.heard, ['see']);
    state.dispose();
  });

  testWidgets('a poker table has no look to hear', (tester) async {
    final (state, heard) = await _mount(tester, _room(poker: true));
    await _snapshot(tester, state, _room(poker: true, seen: {'u1'}));
    expect(heard.heard, isEmpty);
    state.dispose();
  });

  test('the owner\'s clip is bundled where the sound plays it from', () async {
    expect(FeedbackSettings.seeCardsClip, 'sound/see card sound.mp3');
    final clip = await rootBundle.load(
      'assets/${FeedbackSettings.seeCardsClip}',
    );
    final bytes = clip.buffer.asUint8List();
    expect(bytes.length, greaterThan(10000));
    // An MP3: an ID3 tag, or straight into an MPEG audio frame.
    final id3 = String.fromCharCodes(bytes.take(3)) == 'ID3';
    final frame = bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0;
    expect(id3 || frame, isTrue);
  });
}
