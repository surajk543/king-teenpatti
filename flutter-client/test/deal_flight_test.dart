// The deal at the start of a hand (owner, 14 Sep 2026: the deal was not
// smooth). At every table size each card makes the same flight and lands
// before the deal's clock ends — the old one-clock deal cut the last cards off
// mid-air at four and five players — each card fades in at the deck and out at
// the seat without a jump between frames, and the deal is one painter rather
// than a playing-card widget per card in the air.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/widgets/deal_flight.dart';
import 'package:teenpatti/widgets/playing_card.dart';

/// Every 4 ms — faster than any phone draws — from the start to past [until].
Iterable<Duration> _frames(Duration until) sync* {
  const step = Duration(milliseconds: 4);
  for (var at = Duration.zero; at <= until + step; at += step) {
    yield at;
  }
}

Seat _seat(int i) => Seat.fromJson({
  'seatIndex': i,
  'userId': 'u$i',
  'displayName': 'Player $i',
  'chips': 200000,
  'status': 'active',
  'isBlind': true,
  'lastBet': 200,
  'lastAction': 'chaal',
  'contributed': 200,
  'connected': true,
  'cardCount': 3,
});

void main() {
  test('every deal takes two seconds, at a table of two to five and at every '
      "poker room's count (owner, 29 Sep 2026)", () {
    for (var players = 2; players <= 5; players++) {
      for (final each in [2, 3, 4, 5]) {
        final cards = players * each;
        expect(
          (DealFlights.total(cards) - DealFlights.span).inMilliseconds.abs(),
          lessThanOrEqualTo(1),
          reason: '$players players, $each each',
        );
        // The cards set off evenly, each a whole-second flight.
        expect(DealFlights.trip, const Duration(seconds: 1));
        expect(
          DealFlights.landsAt(0, cards),
          DealFlights.trip,
          reason: 'the first card is down after one flight',
        );
      }
    }
    // Slower than it was at a table of two (115 ms apart), never a flicker at
    // five.
    expect(DealFlights.staggerFor(6).inMilliseconds, 200);
    expect(DealFlights.staggerFor(15).inMilliseconds, 71);
  });

  test("a seat's cards land round by round, in the order the deal goes "
      'round the table', () {
    final seats = <Seat?>[_seat(0), null, _seat(2), _seat(3)];
    // Three players, nine cards, 125 ms apart: seat 2 is second in the round.
    for (var round = 0; round < 3; round++) {
      expect(
        DealFlights.seatLandsAt(seats, 2, round),
        DealFlights.landsAt(round * 3 + 1, 9),
      );
    }
    expect(DealFlights.seatLandsAt(seats, 1, 0), isNull, reason: 'no one');
    expect(
      DealFlights.seatLandsAt(seats, 3, 2),
      DealFlights.total(9),
      reason: 'the last seat takes the last card',
    );
  });

  test('at a table of two to five, every card lands before the deal ends', () {
    for (var players = 2; players <= 5; players++) {
      final cards = players * DealFlights.cardsEach;
      final total = DealFlights.total(cards);
      for (var i = 0; i < cards; i++) {
        final flying = [
          for (final at in _frames(total))
            if (dealCardAt(i, at, cards: cards) != null) at,
        ];
        final label = '$players players, card $i';
        expect(flying, isNotEmpty, reason: label);
        expect(
          (flying.last - flying.first).inMilliseconds,
          closeTo(DealFlights.trip.inMilliseconds, 8),
          reason: label,
        );
        expect(flying.last, lessThan(total), reason: label);
        expect(dealCardAt(i, total, cards: cards), isNull, reason: label);
      }
    }
  });

  test('a card fades in at the deck and out at the seat, never jumping', () {
    for (final cards in [6, 15]) {
      final until = DealFlights.total(cards);
      for (var i = 0; i < cards; i++) {
        final path = [
          for (final at in _frames(until)) ?dealCardAt(i, at, cards: cards),
        ];

        expect(path.first.alpha, lessThan(0.1), reason: 'no pop at the deck');
        expect(path.first.along, lessThan(0.01));
        expect(path.first.lift, lessThan(0.01));
        expect(path.last.alpha, lessThan(0.1), reason: 'no pop at the seat');
        expect(path.last.along, greaterThan(0.99));
        expect(path.last.lift, lessThan(0.01));
        expect(path.map((c) => c.alpha).reduce(math.max), 1.0);

        for (var k = 1; k < path.length; k++) {
          expect((path[k].alpha - path[k - 1].alpha).abs(), lessThan(0.15));
          expect((path[k].along - path[k - 1].along).abs(), lessThan(0.02));
          expect((path[k].lift - path[k - 1].lift).abs(), lessThan(0.02));
          expect((path[k].turn - path[k - 1].turn).abs(), lessThan(0.02));
        }
        // Slow and smooth: at its fastest a card covers under 0.7% of its way
        // in a 4 ms step — its average pace half as fast again, where the
        // cubic ease it replaced ran three times its average mid-flight.
        var fastest = 0.0;
        for (var k = 1; k < path.length; k++) {
          fastest = math.max(fastest, path[k].along - path[k - 1].along);
        }
        expect(fastest, lessThan(0.007));
      }
    }
  });

  test('cards go only to seats with a player in the hand', () {
    Seat seat(int i, String status, int cards) => Seat.fromJson({
      'seatIndex': i,
      'userId': status == SeatState.empty ? null : 'u$i',
      'displayName': 'Player $i',
      'chips': 200000,
      'status': status,
      'isBlind': true,
      'lastBet': 0,
      'lastAction': 'chaal',
      'contributed': 0,
      'connected': true,
      'cardCount': cards,
    });

    expect(
      dealtSeats([
        seat(0, SeatState.active, 3),
        seat(1, SeatState.empty, 0), // an empty chair (QA 14 Sep 2026)
        null,
        seat(3, SeatState.active, 3),
        seat(4, 'waiting', 0), // sitting this hand out
      ]),
      [0, 3],
    );
  });

  testWidgets('a deal is one painter and no card widgets, and a player who '
      'has just arrived is dealt nothing', (tester) async {
    final feedback = FeedbackSettings();
    addTearDown(feedback.dispose);

    Widget table(int handNo) => ChangeNotifierProvider<FeedbackSettings>.value(
      value: feedback,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            Positioned.fill(
              child: DealFlights(
                seats: [_seat(0), null, _seat(2)],
                roomId: 'r1',
                handNo: handNo,
                centreOf: (i) => Offset(100.0 + 100 * i, 300),
                deck: const Offset(300, 150),
                cardHeight: 40,
              ),
            ),
          ],
        ),
      ),
    );
    Finder inDeal(Type type) => find.descendant(
      of: find.byType(DealFlights),
      matching: find.byType(type),
    );

    // Arriving at a table whose hand is already under way deals nothing.
    await tester.pumpWidget(table(0));
    await tester.pumpWidget(table(7));
    await tester.pump(const Duration(milliseconds: 300));
    expect(inDeal(CustomPaint), findsNothing);

    // The next hand is dealt, by one painter.
    await tester.pumpWidget(table(8));
    await tester.pump(const Duration(milliseconds: 300));
    expect(inDeal(CustomPaint), findsOneWidget);
    expect(inDeal(PlayingCard), findsNothing);
    expect(inDeal(Opacity), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    expect(inDeal(CustomPaint), findsNothing);

    // A jump (the socket away for a hand or more) is a hand this phone did
    // not see dealt: nothing flies.
    await tester.pumpWidget(table(10));
    await tester.pump(const Duration(milliseconds: 300));
    expect(inDeal(CustomPaint), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets("a new table's first hand is dealt too (29 Sep 2026: handNo "
      '0 → 1, after the 3-2-1)', (tester) async {
    final feedback = FeedbackSettings();
    addTearDown(feedback.dispose);
    Widget table(int handNo) => ChangeNotifierProvider<FeedbackSettings>.value(
      value: feedback,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            Positioned.fill(
              child: DealFlights(
                seats: [_seat(0), null, _seat(2)],
                roomId: 'r1',
                handNo: handNo,
                centreOf: (i) => Offset(100.0 + 100 * i, 300),
                deck: const Offset(300, 150),
                cardHeight: 40,
              ),
            ),
          ],
        ),
      ),
    );
    Finder flying() => find.descendant(
      of: find.byType(DealFlights),
      matching: find.byType(CustomPaint),
    );

    await tester.pumpWidget(table(0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(flying(), findsNothing);
    await tester.pumpWidget(table(1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(flying(), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(flying(), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
