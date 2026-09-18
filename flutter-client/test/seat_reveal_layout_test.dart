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
import 'package:teenpatti/widgets/variation_prompt.dart';

Seat _seat(String status, {int cardCount = 3}) => Seat.fromJson({
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
  'cardCount': cardCount,
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
  List<String> best = const [],
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
                  best: best,
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

  // 5-Card (owner, 18 Sep 2026): a seat holds five cards in the width three
  // take, and at the reveal all five turn over with the two that did not
  // count set back — none of which may move the seat either.
  testWidgets('a seat holding five cards is the size of one holding three, '
      'and keeps it when all five are shown down', (tester) async {
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _newState();

    final three = await _measure(tester, state, seat: _seat('active'));
    expect(find.byType(PlayingCard), findsNWidgets(3));
    expect(find.byType(SetBack), findsNothing, reason: 'a three-card fan');

    final five = await _measure(
      tester,
      state,
      seat: _seat('active', cardCount: 5),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(PlayingCard), findsNWidgets(5));
    expect(five.seat, three.seat, reason: 'five backs made the seat larger');
    expect(five.card.dy, three.card.dy, reason: 'the cards moved down');
    // The five stand inside the pod's own width.
    final pod = tester.getRect(find.byType(SeatPod));
    for (final element in find.byType(PlayingCard).evaluate()) {
      final box = element.renderObject! as RenderBox;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      expect(rect.left, greaterThanOrEqualTo(pod.left - 0.01));
      expect(rect.right, lessThanOrEqualTo(pod.right + 0.01));
    }
    expect(
      tester.widgetList<SetBack>(find.byType(SetBack)).any((w) => w.setBack),
      isFalse,
      reason: 'nothing is set back while the cards are face down',
    );

    final shown = await _measure(
      tester,
      state,
      seat: _seat('lost', cardCount: 5),
      revealed: const ['As', 'Ks', 'Qs', '7d', '7c'],
      revealedHand: 'Pure Sequence',
      best: const ['As', 'Ks', 'Qs'],
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Pure Sequence'), findsOneWidget);
    expect(find.byType(PlayingCard), findsNWidgets(5));
    expect(
      tester
          .widgetList<PlayingCard>(find.byType(PlayingCard))
          .map((c) => c.code),
      ['As', 'Ks', 'Qs', '7d', '7c'],
    );
    expect(
      tester.widgetList<SetBack>(find.byType(SetBack)).map((w) => w.setBack),
      [false, false, false, true, true],
      reason: 'the best three stand, the other two are set back',
    );
    expect(shown.seat, five.seat, reason: 'the column changed height');
    expect(shown.card, five.card, reason: 'the cards moved');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    state.dispose();
  });
}
