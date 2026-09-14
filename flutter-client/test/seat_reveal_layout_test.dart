// A seat must not move when its hand is shown down (owner, 14 Sep 2026).
//
// Seats are placed by their column's middle, so a column that changes height
// at the reveal moves the whole seat. Before this, a beaten player's column
// gained the hand's name as a line above the cards and lost its bet badge
// below them, and every loser's cards jumped down the felt the moment a
// missile's result came in.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/playing_card.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/seat_pod.dart';

Seat _seat(String status) => Seat.fromJson({
  'seatIndex': 1,
  'userId': 'u1',
  'displayName': 'Anita',
  'avatarUrl': null,
  'chips': 180000,
  'status': status,
  'isBlind': true,
  'lastBet': 200,
  'lastAction': 'chaal',
  'contributed': 600,
  'connected': true,
  'cardCount': 3,
});

GameState _newState() {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state;
}

Future<({Size seat, Offset card})> _measure(
  WidgetTester tester,
  GameState state, {
  required Seat seat,
  List<String>? revealed,
  String? revealedHand,
}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<GameState>.value(
      value: state,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(sound: false),
        home: GlassBudget(
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 110,
                child: SeatPod(
                  seat: seat,
                  isMe: false,
                  isDealer: false,
                  onTurn: false,
                  progress: null,
                  deadlineMs: 0,
                  totalMs: 25000,
                  chipsHidden: false,
                  handLive: true,
                  width: 110,
                  avatarUrl: null,
                  revealed: revealed,
                  revealedHand: revealedHand,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
  final pod = find.byType(SeatPod);
  return (
    seat: tester.getSize(pod),
    card:
        tester.getTopLeft(find.byType(PlayingCard).first) -
        tester.getTopLeft(pod),
  );
}

void main() {
  testWidgets('a beaten seat keeps its size and its cards stay in place when '
      'the hand is shown down', (tester) async {
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _newState();

    // In the hand, cards face down with BLIND on them.
    final before = await _measure(tester, state, seat: _seat('active'));

    // The missile's reveal: the same seat, beaten, its hand turned over and
    // named.
    final after = await _measure(
      tester,
      state,
      seat: _seat('lost'),
      revealed: const ['As', 'Kd', '4c'],
      revealedHand: 'High Card',
    );

    expect(find.text('High Card'), findsOneWidget);
    expect(after.seat, before.seat, reason: 'the column changed height');
    expect(after.card, before.card, reason: 'the cards moved');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    state.dispose();
  });
}
