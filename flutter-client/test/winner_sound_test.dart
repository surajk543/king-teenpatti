// A hand won is heard (owner, 29 Sep 2026: "This sound should be played when
// player wins in gameTable" — by everybody at the table, the owner chose):
// assets/sound/winner.mp3, played by FeedbackSettings.win(), which TurnBuzzer
// calls once a hand, on every phone, the moment the hand's winner is named —
// the moment the fireworks go up. Only the winner's own phone also buzzes.
// It replaced the synthesised sfx/win.wav, which only the winner heard.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/widgets/table_chrome.dart';

/// Every sound the table asks for, in order.
class _Heard extends FeedbackSettings {
  final heard = <String>[];

  @override
  void win({required bool mine}) => heard.add(mine ? 'win:mine' : 'win');

  @override
  void cards() => heard.add('see');

  @override
  void potGrew() => heard.add('coins');

  @override
  void turn() => heard.add('turn');

  @override
  void missedTurn() => heard.add('missed');

  @override
  void alarm() => heard.add('alarm');
}

/// The clips a FeedbackSettings asks the audio plugin for, with the Sound
/// switch still deciding: the real [FeedbackSettings.win] down to the seam.
class _Clips extends FeedbackSettings {
  final played = <(String, double)>[];

  @override
  Future<void> playClip(
    String asset, {
    required double volume,
    required int voice,
  }) async => played.add((asset, volume));
}

const _ids = ['u0', 'u1', 'u2', 'u3'];

/// A seen table of four, everybody looked, the viewer (u0) in seat 0.
RoomState _room({int handNo = 7}) => RoomState.fromJson({
  'roomId': 'r1',
  'code': 'ABCD2345',
  'category': 'seen',
  'chipsHidden': false,
  'state': 'betting',
  'handNo': handNo,
  'dealerSeat': 3,
  'maxPlayers': 5,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'startsAt': 0,
  'pot': 1600,
  'maxPot': 2000000,
  'stake': 200,
  'turn': {'seatIndex': 1, 'userId': 'u1', 'deadline': 0},
  'you': {
    'seatIndex': 0,
    'chips': 100000,
    'status': 'active',
    'isBlind': false,
    'contributed': 400,
    'missedTurns': 0,
    'maxMissedTurns': 3,
    'cards': const ['As', 'Kd', 'Qh'],
  },
  'seats': [
    for (final (i, id) in _ids.indexed)
      {
        'seatIndex': i,
        'userId': id,
        'displayName': 'Player $i',
        'chips': 100000,
        'status': 'active',
        'isBlind': false,
        'lastBet': 400,
        'contributed': 400,
        'connected': true,
        'cardCount': 3,
      },
  ],
});

GameState _state(RoomState room) {
  // Play is never started here; the override only keeps the purchase plugin
  // from registering an Android billing client in a test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Player 0',
      'chips': 100000,
    })
    ..screen = Screen.table
    ..handleState(room);
}

Future<_Heard> _mount(WidgetTester tester, GameState state) async {
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
  return heard;
}

/// `game:handEnded` naming [winner].
Future<void> _won(WidgetTester tester, GameState state, String winner) async {
  state.handleShowdown((
    reveals: const [],
    result: 'show',
    winnerId: winner,
    winnerName: 'Player ${_ids.indexOf(winner)}',
    pot: 1600,
    nextHandAt: DateTime.now().millisecondsSinceEpoch + 60000,
    reason: 'show',
  ));
  await tester.pump();
}

void main() {
  testWidgets('another player winning is heard at the table, once, and '
      'buzzes nothing here', (tester) async {
    final state = _state(_room());
    final heard = await _mount(tester, state);
    expect(heard.heard, isEmpty);

    await _won(tester, state, 'u2');
    expect(heard.heard, ['win']);

    // The reward clock's tick and the snapshot after the hand: the same win.
    state.notifyListeners();
    await tester.pump();
    state.handleState(_room());
    await tester.pump();
    expect(heard.heard, ['win']);
    state.dispose();
  });

  testWidgets('the viewer winning is heard, and it is theirs', (tester) async {
    final state = _state(_room());
    final heard = await _mount(tester, state);
    await _won(tester, state, 'u0');
    expect(heard.heard, ['win:mine']);
    state.dispose();
  });

  testWidgets('every hand\'s winner is heard', (tester) async {
    final state = _state(_room());
    final heard = await _mount(tester, state);
    await _won(tester, state, 'u1');
    state.handleState(_room(handNo: 8));
    await tester.pump();
    await _won(tester, state, 'u0');
    expect(heard.heard, ['win', 'win:mine']);
    state.dispose();
  });

  testWidgets('a table whose hand was already won before the player arrived '
      'is not heard', (tester) async {
    final state = _state(_room());
    await _won(tester, state, 'u2');
    final heard = await _mount(tester, state);
    state.notifyListeners();
    await tester.pump();
    expect(heard.heard, isEmpty);
    state.dispose();
  });

  test('the win plays winner.mp3 at full volume, behind the Sound switch', () {
    final clips = _Clips();
    clips.win(mine: false);
    clips.win(mine: true);
    expect(clips.played, [
      (FeedbackSettings.winnerClip, 1.0),
      (FeedbackSettings.winnerClip, 1.0),
    ]);
    expect(FeedbackSettings.winnerClip, 'sound/winner.mp3');
    clips.dispose();
  });

  test('winner.mp3 is in the bundle', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final bytes = await rootBundle.load(
      'assets/${FeedbackSettings.winnerClip}',
    );
    expect(bytes.lengthInBytes, greaterThan(100000));
  });
}
