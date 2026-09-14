// The pot's flight to the winner (owner, 14 Sep 2026: the winner's coins did
// not move smoothly). Every chip makes the same trip, none overtakes the chip
// that left before it, each fades in at the pot and out on the seat without a
// jump between frames, and the run is one painter with no layer per chip.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/widgets/pot_flight.dart';

/// Every 4 ms — faster than any phone draws — from the start to past the end.
Iterable<Duration> _frames() sync* {
  const step = Duration(milliseconds: 4);
  for (var at = Duration.zero; at <= PotFlight.total + step; at += step) {
    yield at;
  }
}

void main() {
  test('every chip makes the same trip, and the run is over by its total', () {
    for (var i = 0; i < PotFlight.chips; i++) {
      final flying = [
        for (final at in _frames())
          if (potChipAt(i, at) != null) at,
      ];
      expect(flying, isNotEmpty);
      expect(
        (flying.last - flying.first).inMilliseconds,
        closeTo(PotFlight.flight.inMilliseconds, 8),
        reason: 'chip $i',
      );
      expect(flying.first, greaterThanOrEqualTo(PotFlight.stagger * i));
      expect(potChipAt(i, PotFlight.total), isNull);
    }
  });

  test('no chip overtakes the chip that left before it', () {
    for (final at in _frames()) {
      for (var i = 1; i < PotFlight.chips; i++) {
        final ahead = potChipAt(i - 1, at);
        final behind = potChipAt(i, at);
        if (ahead != null && behind != null) {
          expect(behind.along, lessThanOrEqualTo(ahead.along));
        }
      }
    }
  });

  test(
    'a chip grows in at the pot and fades out on the seat, never jumping',
    () {
      for (var i = 0; i < PotFlight.chips; i++) {
        final path = [for (final at in _frames()) ?potChipAt(i, at)];

        expect(path.first.alpha, lessThan(0.1), reason: 'no pop at the pot');
        expect(path.first.along, lessThan(0.01));
        expect(path.first.bow.abs(), lessThan(0.05));
        expect(path.last.alpha, lessThan(0.1), reason: 'no pop on the seat');
        expect(path.last.along, greaterThan(0.99));
        expect(path.last.bow.abs(), lessThan(0.05));
        expect(path.map((c) => c.alpha).reduce(math.max), 1.0);

        for (var k = 1; k < path.length; k++) {
          expect((path[k].alpha - path[k - 1].alpha).abs(), lessThan(0.15));
          expect((path[k].along - path[k - 1].along).abs(), lessThan(0.02));
          expect((path[k].bow - path[k - 1].bow).abs(), lessThan(0.05));
        }
      }
    },
  );

  testWidgets('is one painter with no layer per chip, and finishes', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            Positioned.fill(
              child: PotFlight(
                from: Offset(400, 200),
                to: Offset(100, 350),
                size: 24,
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    Finder inFlight(Type type) => find.descendant(
      of: find.byType(PotFlight),
      matching: find.byType(type),
    );
    expect(inFlight(Opacity), findsNothing);
    expect(inFlight(Transform), findsNothing);
    expect(inFlight(CustomPaint), findsOneWidget);

    await tester.pump(PotFlight.total);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
