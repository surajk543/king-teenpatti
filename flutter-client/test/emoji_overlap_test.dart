// Emojis never land on each other (owner, 28 Sep 2026: "when two players send
// emoji in any game table then their emoji should not overlap, if overlap then
// change the direction so that it does not overlap"). An emoji plays in its
// bubble's own place; one that would meet an emoji already playing moves
// beside or above its sender's pod, and keeps that place while it plays.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/seat_pod.dart';

import 'table_scenes.dart';

Future<GameState> _mount(
  WidgetTester tester,
  TableScene scene, {
  Size size = const Size(640, 360),
  double textScale = 1.0,
  bool dark = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final state = sceneState(scene);
  await tester.pumpWidget(
    tableApp(
      state: state,
      feedback: feedback,
      theme: dark ? AppTheme.dark(sound: false) : AppTheme.light(sound: false),
    ),
  );
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pump(const Duration(milliseconds: 900));
  return state;
}

Future<void> _unmount(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

TableScene _scene(String prefix) =>
    tableScenes.firstWhere((s) => s.name.startsWith(prefix));

Finder _podOf(String userId) =>
    find.byWidgetPredicate((w) => w is SeatPod && w.seat?.userId == userId);

Finder _emojiOf(String userId) => find.descendant(
  of: _podOf(userId),
  matching: find.byKey(const ValueKey('seat-emoji')),
);

EmojiPlace _placeOf(WidgetTester tester, String userId) =>
    tester.widget<SeatPod>(_podOf(userId)).emojiPlace;

ChatMessage _emoji(String userId, String name, int at) => ChatMessage(
  userId: userId,
  displayName: name,
  text: 'Kiss Face',
  at: at,
  emoji: const ChatEmoji(id: 17, name: 'Kiss Face', url: ''),
);

/// Sends [line] and lets it land and settle.
Future<void> _send(
  WidgetTester tester,
  GameState state,
  ChatMessage line,
) async {
  state.handleChat(line);
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Where it was, give or take the settling of a column still dealing.
void _expectAt(Rect actual, Rect was) =>
    expect((actual.topLeft - was.topLeft).distance, lessThan(1));

void _expectApart(WidgetTester tester, List<String> ids) {
  final rects = {for (final id in ids) id: tester.getRect(_emojiOf(id))};
  for (final a in ids) {
    for (final b in ids) {
      if (a.compareTo(b) >= 0) continue;
      expect(
        rects[a]!.deflate(2).overlaps(rects[b]!.deflate(2)),
        isFalse,
        reason: '$a ${rects[a]} meets $b ${rects[b]}',
      );
    }
  }
}

void main() {
  const everyone = ['u0', 'u1', 'u2', 'u3', 'u4'];

  for (final (size, scale) in [
    (const Size(592, 360), 1.25),
    (const Size(640, 360), 1.0),
    (const Size(640, 360), 1.25),
    (const Size(732, 412), 1.0),
    (const Size(844, 390), 1.25),
    (const Size(891, 411), 1.0),
    (const Size(915, 412), 1.25),
  ]) {
    final name = '${size.width.toInt()}x${size.height.toInt()} x$scale';
    testWidgets('at $name every seat\'s emoji at once, none on another', (
      tester,
    ) async {
      final state = await _mount(
        tester,
        _scene('19c-every-seat-emoji'),
        size: size,
        textScale: scale,
      );
      expect(tester.takeException(), isNull);
      for (final id in everyone) {
        expect(_emojiOf(id), findsOneWidget, reason: id);
        final r = tester.getRect(_emojiOf(id));
        expect(r.left, greaterThanOrEqualTo(-1), reason: '$id $r');
        expect(r.top, greaterThanOrEqualTo(-1), reason: '$id $r');
        expect(r.right, lessThanOrEqualTo(size.width + 1), reason: '$id $r');
        expect(r.bottom, lessThanOrEqualTo(size.height + 1), reason: '$id $r');
      }
      _expectApart(tester, everyone);
      await _unmount(tester, state);
    });
  }

  testWidgets('the later emoji moves; the earlier keeps its place', (
    tester,
  ) async {
    final state = await _mount(tester, _scene('17-dealing'));
    // Meera's first, in its own place under her pod; the viewer's own place,
    // over their pod, would meet it, so theirs stands beside their pod.
    await _send(tester, state, _emoji('u2', 'Meera', 1000));
    expect(_placeOf(tester, 'u2'), EmojiPlace.column);
    final meera = tester.getRect(_emojiOf('u2'));
    await _send(tester, state, _emoji('u0', 'Priya', 2000));
    expect(_placeOf(tester, 'u2'), EmojiPlace.column);
    _expectAt(tester.getRect(_emojiOf('u2')), meera);
    expect(_placeOf(tester, 'u0'), isNot(EmojiPlace.column));
    _expectApart(tester, ['u0', 'u2']);
    // Pointing at its own pod: beside it, level with it.
    final pod = tester.getRect(
      find
          .descendant(of: _podOf('u0'), matching: find.byType(GestureDetector))
          .first,
    );
    final mine = tester.getRect(_emojiOf('u0'));
    expect(mine.center.dy, closeTo(pod.center.dy, 2));

    // Meera's ends; the viewer's stays where it is rather than jumping back.
    // Meera's was sent 0.4s before the viewer's: at 5.2s hers has gone and
    // theirs still plays.
    await tester.pump(const Duration(milliseconds: 4400));
    expect(_emojiOf('u2'), findsNothing);
    _expectAt(tester.getRect(_emojiOf('u0')), mine);
    await tester.pump(GameState.emojiBubbleFor);
    await tester.pump(const Duration(milliseconds: 400));
    expect(_emojiOf('u0'), findsNothing);
    expect(tester.takeException(), isNull);
    await _unmount(tester, state);
  });

  testWidgets('the other way round, Meera\'s is the one that moves', (
    tester,
  ) async {
    final state = await _mount(tester, _scene('17-dealing'));
    await _send(tester, state, _emoji('u0', 'Priya', 1000));
    final mine = tester.getRect(_emojiOf('u0'));
    await _send(tester, state, _emoji('u2', 'Meera', 2000));
    expect(_placeOf(tester, 'u0'), EmojiPlace.column);
    _expectAt(tester.getRect(_emojiOf('u0')), mine);
    expect(_placeOf(tester, 'u2'), isNot(EmojiPlace.column));
    _expectApart(tester, ['u0', 'u2']);
    await tester.pump(GameState.emojiBubbleFor);
    await tester.pump(const Duration(milliseconds: 400));
    await _unmount(tester, state);
  });

  testWidgets('an emoji meeting nothing plays in its own place', (
    tester,
  ) async {
    final state = await _mount(tester, _scene('17-dealing'));
    await _send(tester, state, _emoji('u1', 'Ravi', 1000));
    await _send(tester, state, _emoji('u4', 'Vikramaditya', 2000));
    expect(_placeOf(tester, 'u1'), EmojiPlace.column);
    expect(_placeOf(tester, 'u4'), EmojiPlace.column);
    // Queued behind the first: placed again when its turn comes.
    await _send(tester, state, _emoji('u1', 'Ravi', 3000));
    await tester.pump(GameState.emojiBubbleFor);
    await tester.pump(const Duration(milliseconds: 400));
    expect(_emojiOf('u1'), findsOneWidget);
    expect(_placeOf(tester, 'u1'), EmojiPlace.column);
    await tester.pump(GameState.emojiBubbleFor);
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    await _unmount(tester, state);
  });
}
