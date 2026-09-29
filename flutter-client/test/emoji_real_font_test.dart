// Emojis over the table in the app's own face, Inter, as a phone lays the
// table out (the fourth look at the emoji placement, 29 Sep 2026). The other
// emoji suites run in the test font, whose em-wide letters make every word
// and capsule wider and every line a little taller: two things were found
// only here.
//
// A lone emoji plays in its own place. At 592x360 x1.25 on a seen table,
// where each pod carries its stack, Ravi's own place ended 1.1dp inside the
// room the viewer's pod takes when their turn ring comes on, and a lone emoji
// of his went onto his pod. What may come while an emoji plays is now let
// reach 2dp into its bubble's rounded edge (EmojiPlacement).
//
// An emoji keeps its place while the viewer's hand is named at a showdown.
// When the viewer's hand is named, their hand's column is laid out a line
// taller at once and its lift glides it back towards the floor over 300 ms
// (_LiftedHand). Measured as it stood, that column's box rose over the corner
// of the upper-left seat's emoji at 592x360 x1.25 for those 300 ms, and the
// placement moved the emoji off its own place. The felt now reckons the hand
// where it comes to rest; what the column holds over that corner meanwhile is
// only the name's capsule, centred on the fan — and in Inter the widest name
// there is ("Pure Sequence") stays clear of the emoji all the way down (the
// test font's letters would make the capsule half as wide again).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/seat_pod.dart';

import 'script_fonts.dart';
import 'table_scenes.dart';

Finder _podOf(String userId) =>
    find.byWidgetPredicate((w) => w is SeatPod && w.seat?.userId == userId);

Finder _emojiOf(String userId) => find.descendant(
  of: _podOf(userId),
  matching: find.byKey(const ValueKey('seat-emoji')),
);

Finder _private(String type) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

String _nameOf(Size size, double scale) =>
    '${size.width.toInt()}x${size.height.toInt()} x$scale';

void main() {
  setUpAll(loadScriptFonts);

  // Every name a hand can have, the widest last.
  const names = [
    'High Card',
    'Pair',
    'Color',
    'Sequence',
    'Trail',
    'Pure Sequence',
  ];

  for (final (size, scale) in const [
    (Size(592, 360), 1.25),
    (Size(640, 360), 1.0),
    (Size(640, 360), 1.25),
    (Size(844, 390), 1.25),
    (Size(915, 412), 1.25),
  ]) {
    testWidgets('at ${_nameOf(size, scale)}, the viewer wins while Meera\'s '
        'emoji plays: whatever their hand is called, it keeps its place and '
        'nothing is drawn over it', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final feedback = await silentFeedback();
      addTearDown(feedback.dispose);
      final state = sceneState(
        tableScenes.firstWhere((s) => s.name.startsWith('20-')),
      );
      await tester.pumpWidget(
        tableApp(
          state: state,
          feedback: feedback,
          theme: AppTheme.dark(sound: false),
        ),
      );
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump(const Duration(milliseconds: 900));

      var clock = 10000;
      var hand = 20;
      for (final name in names) {
        hand += 1;
        state.handleState(seenOpponentTurnRoom(handNo: hand));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 900));
        state.handleChat(
          ChatMessage(
            userId: 'u2',
            displayName: 'Meera',
            text: 'Kiss Face',
            at: clock += 10000,
            emoji: const ChatEmoji(id: 17, name: 'Kiss Face', url: ''),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester.widget<SeatPod>(_podOf('u2')).emojiPlace,
          EmojiPlace.column,
          reason: name,
        );
        final meera = tester.getRect(_emojiOf('u2'));

        state.handleState(youWonRoom(handNo: hand));
        youWonShowdown(state, handName: name);
        await tester.pump();
        var elapsed = Duration.zero;
        for (final at in const [
          Duration(milliseconds: 16),
          Duration(milliseconds: 50),
          Duration(milliseconds: 100),
          Duration(milliseconds: 166),
          Duration(milliseconds: 300),
          Duration(milliseconds: 700),
        ]) {
          await tester.pump(at - elapsed);
          elapsed = at;
          final now = tester.getRect(_emojiOf('u2'));
          expect(
            (now.topLeft - meera.topLeft).distance,
            lessThan(1),
            reason: '$name, ${at.inMilliseconds} ms: moved from $meera to $now',
          );
          final capsule = tester.getRect(_private('_OwnHandName'));
          expect(
            capsule.overlaps(now.deflate(1)),
            isFalse,
            reason:
                '$name, ${at.inMilliseconds} ms: the name $capsule over '
                'Meera\'s emoji $now',
          );
        }
        // At rest, not even the column's box reaches it.
        expect(
          tester
              .getRect(find.byKey(const ValueKey('own-hand-column')))
              .overlaps(meera.deflate(1)),
          isFalse,
          reason: name,
        );
        await tester.pump(GameState.emojiBubbleFor);
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
      state.dispose();
    });
  }

  // A lone emoji, every seat's in turn, whatever the table is doing.
  for (final (size, scale) in const [
    (Size(592, 360), 1.0),
    (Size(592, 360), 1.25),
    (Size(640, 360), 1.0),
    (Size(640, 360), 1.25),
    (Size(732, 412), 1.0),
    (Size(844, 390), 1.25),
    (Size(891, 411), 1.0),
    (Size(915, 412), 1.25),
    (Size(1024, 600), 1.0),
  ]) {
    testWidgets('at ${_nameOf(size, scale)}, a lone emoji plays in its own '
        'place while the table waits, when it is dealt, on the viewer\'s '
        'turn, at a seen table and when the viewer has won', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final feedback = await silentFeedback();
      addTearDown(feedback.dispose);
      final state = sceneState(
        tableScenes.firstWhere((s) => s.name.startsWith('01-')),
      );
      await tester.pumpWidget(
        tableApp(
          state: state,
          feedback: feedback,
          theme: AppTheme.dark(sound: false),
        ),
      );
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump(const Duration(milliseconds: 900));
      var clock = 10000;
      var hand = 30;
      for (final (label, setUp) in <(String, void Function(GameState))>[
        ('waiting', (s) => s.handleState(waitingRoom())),
        ('dealt', (s) => s.handleState(opponentTurnRoom(handNo: ++hand))),
        (
          'the viewer on turn',
          (s) => s.handleState(blindTurnRoom(handNo: ++hand, turnSeat: 0)),
        ),
        (
          'a seen hand',
          (s) => s.handleState(seenOpponentTurnRoom(handNo: ++hand)),
        ),
        (
          'won',
          (s) {
            s.handleState(youWonRoom(handNo: ++hand));
            youWonShowdown(s);
          },
        ),
      ]) {
        setUp(state);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 900));
        for (final id in const ['u0', 'u1', 'u2', 'u3', 'u4']) {
          state.handleChat(
            ChatMessage(
              userId: id,
              displayName: id,
              text: 'Kiss Face',
              at: clock += 10000,
              emoji: const ChatEmoji(id: 17, name: 'Kiss Face', url: ''),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            tester.widget<SeatPod>(_podOf(id)).emojiPlace,
            EmojiPlace.column,
            reason: '$id, $label',
          );
          await tester.pump(GameState.emojiBubbleFor);
          await tester.pump();
        }
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
      state.dispose();
    });
  }
}
