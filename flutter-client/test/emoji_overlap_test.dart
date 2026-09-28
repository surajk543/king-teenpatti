// Emojis never land on each other (owner, 28 Sep 2026: "when two players send
// emoji in any game table then their emoji should not overlap, if overlap then
// change the direction so that it does not overlap"). An emoji plays in its
// bubble's own place; one that would meet an emoji already playing moves
// beside or above its sender's pod, and keeps that place while it plays —
// never under anything painted after it: a seat the felt paints later, the
// viewer's own hand, the keys and controls the screen stands over the felt.
// At a poker room too.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/buy_chips.dart';
import 'package:teenpatti/widgets/playing_card.dart';
import 'package:teenpatti/widgets/seat_pod.dart';
import 'package:teenpatti/widgets/table_chrome.dart';

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

Finder _private(String type) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

/// Everything painted over [userId]'s seat, by name: the seats the felt paints
/// after it — the rim in view order, then the viewer's — the part of its own
/// seat that stands beside its pod (the head seat's cards), the viewer's own
/// hand, and the controls the screen stands over the felt's corners. In these
/// scenes seat i is `u<i>` and the viewer is u0, so the order is [seated]'s
/// with u0 last.
Map<String, Rect> _paintedOver(
  WidgetTester tester,
  String userId,
  List<String> seated, {
  bool poker = false,
}) {
  final order = [...seated.where((id) => id != 'u0'), 'u0'];
  final later = order.sublist(order.indexOf(userId) + 1);
  final cards = find.descendant(
    of: _private(poker ? '_PokerHand' : '_OwnHand'),
    matching: find.byType(PlayingCard),
  );
  final seat = tester.getRect(_podOf(userId));
  final pod = tester.getRect(_plaqueOf(userId));
  return {
    for (final id in later) 'seat $id': tester.getRect(_podOf(id)),
    if (seat.right - pod.right > 0.5)
      'its own cards': Rect.fromLTRB(
        pod.right,
        seat.top,
        seat.right,
        seat.bottom,
      ),
    for (var i = 0; i < cards.evaluate().length; i++)
      'the viewer\'s card $i': tester.getRect(cards.at(i)),
    if (!poker)
      'the viewer\'s hand': tester.getRect(
        find.byKey(const ValueKey('own-hand-column')),
      ),
    for (final key
        in poker
            ? const ['_PokerKeys', '_FoldKey']
            : const ['_MissileKey', '_PackKey', '_ActionCluster'])
      key: tester.getRect(_private(key)),
    'the Shop key': tester.getRect(find.byType(ShopButton)),
    'the wallet': tester.getRect(find.byType(TableWallet)),
  };
}

/// A seat's plaque: the pod itself, which its emoji points at.
Finder _plaqueOf(String userId) => find
    .descendant(of: _podOf(userId), matching: find.byType(GestureDetector))
    .first;

/// [userId]'s emoji, if it has moved from its own place, stands over nothing
/// the felt or the screen paints after it: it is seen whole.
void _expectOnTop(
  WidgetTester tester,
  String userId,
  List<String> seated, {
  bool poker = false,
}) {
  if (_placeOf(tester, userId) == EmojiPlace.column) return;
  final emoji = tester.getRect(_emojiOf(userId));
  for (final MapEntry(key: what, value: r) in _paintedOver(
    tester,
    userId,
    seated,
    poker: poker,
  ).entries) {
    expect(
      r.overlaps(emoji.deflate(1)),
      isFalse,
      reason: '$userId\'s emoji $emoji is under $what $r',
    );
  }
}

/// Every emoji inside the screen.
void _expectOnScreen(WidgetTester tester, List<String> ids, Size size) {
  for (final id in ids) {
    expect(_emojiOf(id), findsOneWidget, reason: id);
    final r = tester.getRect(_emojiOf(id));
    expect(r.left, greaterThanOrEqualTo(-1), reason: '$id $r');
    expect(r.top, greaterThanOrEqualTo(-1), reason: '$id $r');
    expect(r.right, lessThanOrEqualTo(size.width + 1), reason: '$id $r');
    expect(r.bottom, lessThanOrEqualTo(size.height + 1), reason: '$id $r');
  }
}

const _phones = [
  (Size(592, 360), 1.25),
  (Size(640, 360), 1.0),
  (Size(640, 360), 1.25),
  (Size(732, 412), 1.0),
  (Size(844, 390), 1.25),
  (Size(891, 411), 1.0),
  (Size(915, 412), 1.25),
];

String _nameOf(Size size, double scale) =>
    '${size.width.toInt()}x${size.height.toInt()} x$scale';

void main() {
  const everyone = ['u0', 'u1', 'u2', 'u3', 'u4'];

  for (final (size, scale) in _phones) {
    final name = _nameOf(size, scale);
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
      _expectOnScreen(tester, everyone, size);
      _expectApart(tester, everyone);
      for (final id in everyone) {
        _expectOnTop(tester, id, everyone);
      }
      await _unmount(tester, state);
    });

    // The review of 28 Sep 2026: the viewer's emoji, moved off Meera's, stood
    // beside their pod over their own cards — and the felt paints the hand
    // after the viewer's seat, so the cards covered three quarters of it; its
    // other side was under Missile and Pack. Either way round, the one that
    // moves is seen whole.
    for (final (first, then) in const [('u2', 'u0'), ('u0', 'u2')]) {
      testWidgets('at $name, $then\'s after $first\'s: the one that moves '
          'stands over nothing painted after it', (tester) async {
        final state = await _mount(
          tester,
          _scene('17-dealing'),
          size: size,
          textScale: scale,
        );
        await _send(tester, state, _emoji(first, first, 1000));
        await _send(tester, state, _emoji(then, then, 2000));
        expect(tester.takeException(), isNull);
        expect(_placeOf(tester, first), EmojiPlace.column);
        expect(_placeOf(tester, then), isNot(EmojiPlace.column));
        _expectOnScreen(tester, [first, then], size);
        _expectApart(tester, [first, then]);
        _expectOnTop(tester, then, everyone);
        if (then == 'u0') {
          // In the finding's own words: not the viewer's cards, not Missile
          // or Pack, not the key cluster.
          final mine = tester.getRect(_emojiOf('u0')).deflate(1);
          final cards = find.descendant(
            of: _private('_OwnHand'),
            matching: find.byType(PlayingCard),
          );
          expect(cards, findsWidgets);
          for (var i = 0; i < cards.evaluate().length; i++) {
            expect(tester.getRect(cards.at(i)).overlaps(mine), isFalse);
          }
          for (final key in const [
            '_MissileKey',
            '_PackKey',
            '_ActionCluster',
          ]) {
            expect(
              tester.getRect(_private(key)).overlaps(mine),
              isFalse,
              reason: key,
            );
          }
          // And it still points at the viewer's pod: over it, a step clear.
          final pod = tester.getRect(_plaqueOf('u0'));
          expect(mine.bottom, lessThanOrEqualTo(pod.top));
          expect(mine.right, greaterThan(pod.left - 2));
          expect(mine.left, lessThan(pod.right));
        }
        await tester.pump(GameState.emojiBubbleFor);
        await tester.pump(const Duration(milliseconds: 400));
        await _unmount(tester, state);
      });
    }

    // The tables of two, three and four places, every seat at once.
    for (final places in const [2, 3, 4]) {
      testWidgets('at $name, $places places, every seat\'s emoji at once', (
        tester,
      ) async {
        final seated = everyone.take(places).toList();
        final state = await _mount(
          tester,
          TableScene('$places-places-emoji', (s) {
            s.config = s.config.copyWith(maxPlayers: places);
            s.handleState(placesRoom(places));
            everySeatEmoji(s);
          }),
          size: size,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        _expectOnScreen(tester, seated, size);
        _expectApart(tester, seated);
        for (final id in seated) {
          _expectOnTop(tester, id, seated);
        }
        await _unmount(tester, state);
      });
    }

    // A poker room: a held or resumed seat still opens its felt, and emojis
    // play there as at any table.
    testWidgets('at $name, a poker room: every seat\'s emoji at once, none '
        'on another', (tester) async {
      final state = await _mount(
        tester,
        _scene('15b-poker-every-seat-emoji'),
        size: size,
        textScale: scale,
      );
      expect(tester.takeException(), isNull);
      _expectOnScreen(tester, everyone, size);
      _expectApart(tester, everyone);
      for (final id in everyone) {
        _expectOnTop(tester, id, everyone, poker: true);
      }
      await _unmount(tester, state);
    });
  }

  // Every ordered pair of seats, at the narrowest phone and the widest: the
  // later one moves where it must, and never under anything.
  for (final (size, scale) in const [
    (Size(592, 360), 1.25),
    (Size(915, 412), 1.25),
  ]) {
    testWidgets('at ${_nameOf(size, scale)} every pair of seats, either way '
        'round', (tester) async {
      for (final first in everyone) {
        for (final then in everyone) {
          if (first == then) continue;
          final state = await _mount(
            tester,
            _scene('17-dealing'),
            size: size,
            textScale: scale,
          );
          await _send(tester, state, _emoji(first, first, 1000));
          await _send(tester, state, _emoji(then, then, 2000));
          expect(tester.takeException(), isNull, reason: '$first, $then');
          expect(_placeOf(tester, first), EmojiPlace.column);
          _expectOnScreen(tester, [first, then], size);
          _expectApart(tester, [first, then]);
          _expectOnTop(tester, then, everyone);
          await _unmount(tester, state);
        }
      }
    });
  }

  testWidgets('the later emoji moves; the earlier keeps its place', (
    tester,
  ) async {
    final state = await _mount(tester, _scene('17-dealing'));
    // Meera's first, in its own place under her pod; the viewer's own place,
    // over their pod, would meet it. Beside their pod is their own hand on
    // one side and Missile and Pack on the other, both drawn over it, so
    // theirs stands above their pod, slid off Meera's (review, 28 Sep 2026).
    await _send(tester, state, _emoji('u2', 'Meera', 1000));
    expect(_placeOf(tester, 'u2'), EmojiPlace.column);
    final meera = tester.getRect(_emojiOf('u2'));
    await _send(tester, state, _emoji('u0', 'Priya', 2000));
    expect(_placeOf(tester, 'u2'), EmojiPlace.column);
    _expectAt(tester.getRect(_emojiOf('u2')), meera);
    expect(_placeOf(tester, 'u0'), EmojiPlace.above);
    expect(tester.widget<SeatPod>(_podOf('u0')).emojiShift, lessThan(0));
    _expectApart(tester, ['u0', 'u2']);
    // Pointing at its own pod: over it, a step clear, standing over some of
    // it.
    final pod = tester.getRect(_plaqueOf('u0'));
    final mine = tester.getRect(_emojiOf('u0'));
    expect(mine.bottom, lessThanOrEqualTo(pod.top));
    expect(mine.right, greaterThan(pod.left - 1));

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
