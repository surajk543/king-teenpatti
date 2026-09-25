// The felt keeps every seat through a sideshow (26 Sep 2026, found while
// making the end of a hand smooth).
//
// The felt is one Stack whose overlays come and go in the middle of its
// children — a sideshow's thread, a hammer's, the pickers — and the framework
// matches unkeyed siblings by their place. A sideshow request appearing (the
// practice bots ask for one on nearly half their turns), or being answered,
// shifted every later child one place along: every pod was rebuilt as its
// neighbour's and the viewer's hand dealt itself again. Every child is keyed
// now; this holds the seats and the hand still through a sideshow, and every
// child to its key.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/seat_pod.dart';

import 'table_scenes.dart';

Finder _private(String type) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

/// Every seat's pod by its player, and the viewer's hand.
Map<String, Element> _seats() => {
  for (final e in find.byType(SeatPod).evaluate())
    ?(e.widget as SeatPod).seat?.userId: e,
  'own-hand': find.byKey(const ValueKey('own-hand-column')).evaluate().single,
};

/// The felt's Stack: the outermost one under the felt.
Stack _feltStack(WidgetTester tester) => tester.widget<Stack>(
  find.descendant(of: _private('_Felt'), matching: find.byType(Stack)).first,
);

void main() {
  testWidgets('a sideshow asked and answered rebuilds no seat and deals the '
      "viewer's hand once", (tester) async {
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final feedback = await silentFeedback();
    addTearDown(feedback.dispose);
    const cards = ['Jc', 'Jd', '4s'];
    final state = sceneState(
      TableScene('seen', (s) => s.handleState(seenTurnRoom(cards: cards))),
    );
    await tester.pumpWidget(
      tableApp(
        state: state,
        feedback: feedback,
        theme: AppTheme.dark(sound: false),
      ),
    );
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final seats = _seats();
    final dealt = tester.stateList(_private('_Dealt')).toList();
    final cardStates = tester.stateList(_private('PlayingCard')).toList();
    expect(seats.length, 6, reason: 'five players and the hand');
    expect(dealt, hasLength(3));

    Future<void> expectEverythingKept(String when) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final now = _seats();
      for (final id in seats.keys) {
        expect(identical(now[id], seats[id]), isTrue, reason: '$when: $id');
      }
      expect(
        tester.stateList(_private('_Dealt')).toList(),
        dealt,
        reason: "$when: the viewer's hand was dealt again",
      );
      expect(
        tester.stateList(_private('PlayingCard')).toList(),
        cardStates,
        reason: "$when: a card's state was rebuilt or moved to another seat",
      );
      for (final child in _feltStack(tester).children) {
        expect(child.key, isNotNull, reason: '$when: ${child.runtimeType}');
      }
    }

    // Asked: the thread appears between the two seats, under all of them.
    state.handleState(sideshowWaitingRoom());
    await expectEverythingKept('asked');
    expect(state.sideshow, isNotNull);

    // Answered: the thread goes.
    state.handleState(seenTurnRoom(cards: cards));
    await expectEverythingKept('answered');
    expect(state.sideshow, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
    state.dispose();
  });
}
