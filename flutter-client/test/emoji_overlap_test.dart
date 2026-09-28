// Emojis never land on each other (owner, 28 Sep 2026: "when two players send
// emoji in any game table then their emoji should not overlap, if overlap then
// change the direction so that it does not overlap"). An emoji plays in its
// bubble's own place; one whose place will not do moves beside or above its
// sender's pod — never over another seat's pod or into another seat's own
// place — and where none of those will do, onto its sender's own pod, which
// is always free. Wherever it plays it keeps that place while it plays, stays
// on the felt, and is never under anything painted after it: a seat the felt
// paints later, the viewer's own hand, the keys and controls the screen stands
// over the felt. In every order the players send in, at a poker room too.
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

/// [userId]'s emoji, wherever it plays, stands over nothing the felt or the
/// screen paints after it: it is seen whole.
void _expectOnTop(
  WidgetTester tester,
  String userId,
  List<String> seated, {
  bool poker = false,
}) {
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

/// Every order [ids] can be sent in (all 120 of five).
List<List<String>> _orders(List<String> ids) => ids.length <= 1
    ? [ids]
    : [
        for (final first in ids)
          for (final rest in _orders([
            for (final id in ids)
              if (id != first) id,
          ]))
            [first, ...rest],
      ];

/// The felt's own box, which every emoji plays inside.
Rect _feltOf(WidgetTester tester, {bool poker = false}) => tester.getRect(
  find
      .descendant(
        of: _private(poker ? '_PokerFelt' : '_Felt'),
        matching: find.byType(LayoutBuilder),
      )
      .first,
);

/// Every emoji playing on the felt, by its sender: where it stands and in
/// which of its seat's places — found in one walk of the tree.
Map<String, ({Rect rect, EmojiPlace place})> _playing(WidgetTester tester) => {
  for (final element in find.byKey(const ValueKey('seat-emoji')).evaluate())
    if (element.findAncestorWidgetOfExactType<SeatPod>() case final seat?)
      if ((seat.seat?.userId, element.renderObject) case (
        final String id,
        final RenderBox box,
      ))
        id: (
          rect: Rect.fromPoints(
            box.localToGlobal(Offset.zero),
            box.localToGlobal(box.size.bottomRight(Offset.zero)),
          ),
          place: seat.emojiPlace,
        ),
};

/// What every emoji is held to, measured once: the felt, each seat and its
/// pod, and what is painted over each seat ([_paintedOver]). None of it moves
/// while emojis come and go — an emoji takes no room in its seat.
typedef _Stage = ({
  Rect felt,
  Map<String, Rect> seats,
  Map<String, Rect> pods,
  Map<String, Map<String, Rect>> over,
});

_Stage _stageOf(
  WidgetTester tester,
  List<String> seated, {
  bool poker = false,
}) => (
  felt: _feltOf(tester, poker: poker),
  seats: {for (final id in seated) id: tester.getRect(_podOf(id))},
  pods: {for (final id in seated) id: tester.getRect(_plaqueOf(id))},
  over: {
    for (final id in seated) id: _paintedOver(tester, id, seated, poker: poker),
  },
);

/// What is wrong with the emojis of [playing] as they stand ([now]), or
/// null: one missing; off the felt (3); moved from where it [settled] (4);
/// not at its sender's seat — hung off its column, beside or above its pod,
/// or on it (5); under anything painted after its seat (2); meeting another
/// (1).
String? _faultIn(
  List<String> playing,
  Map<String, ({Rect rect, EmojiPlace place})> now,
  Map<String, Rect> settled,
  _Stage stage,
) {
  for (final id in playing) {
    final emoji = now[id];
    if (emoji == null) return '$id\'s emoji is not playing';
    final (:rect, :place) = emoji;
    final where = '$rect (${place.name})';
    final on = stage.felt.inflate(1);
    if (!on.contains(rect.topLeft) || !on.contains(rect.bottomRight)) {
      return '$id\'s emoji $where is off the felt ${stage.felt}';
    }
    if (settled[id] case final was?
        when (rect.topLeft - was.topLeft).distance >= 1 ||
            (rect.width - was.width).abs() >= 1) {
      return '$id\'s emoji moved from $was to $where';
    }
    final seat = stage.seats[id]!;
    final pod = stage.pods[id]!;
    final atSeat = switch (place) {
      EmojiPlace.column => rect.inflate(pod.width * 0.1).overlaps(seat),
      EmojiPlace.pod =>
        pod.inflate(0.5).contains(rect.topLeft) &&
            pod.inflate(0.5).contains(rect.bottomRight),
      _ => rect.inflate(pod.width * 0.1).overlaps(pod),
    };
    if (!atSeat) return '$id\'s emoji $where is away from its seat $seat';
    for (final MapEntry(key: what, value: over) in stage.over[id]!.entries) {
      if (over.overlaps(rect.deflate(1))) {
        return '$id\'s emoji $where is under $what $over';
      }
    }
  }
  for (final a in playing) {
    for (final b in playing) {
      if (a.compareTo(b) >= 0) continue;
      if (now[a]!.rect.deflate(2).overlaps(now[b]!.rect.deflate(2))) {
        return '$a\'s emoji ${now[a]!.rect} (${now[a]!.place.name}) meets '
            '$b\'s ${now[b]!.rect} (${now[b]!.place.name})';
      }
    }
  }
  return null;
}

/// Sends each of [orders] at the table [state] is at — one emoji a player,
/// 300 ms apart — checking every emoji playing after each send, and lets them
/// all end before the next order. The orders that went wrong, each with its
/// first fault; and how often each place was taken ([places]).
Future<List<String>> _sweep(
  WidgetTester tester,
  GameState state,
  List<List<String>> orders,
  List<String> seated, {
  bool poker = false,
  Map<EmojiPlace, int>? places,
}) async {
  final stage = _stageOf(tester, seated, poker: poker);
  final faults = <String>[];
  var clock = 100000;
  for (final order in orders) {
    final settled = <String, Rect>{};
    String? fault;
    for (var i = 0; i < order.length; i++) {
      clock += 300;
      state.handleChat(_emoji(order[i], order[i], clock));
      // The frame that lays it out in its own place and places it, then the
      // frame it plays in where it was placed, 300 ms on.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final now = _playing(tester);
      fault ??= _faultIn(order.sublist(0, i + 1), now, settled, stage);
      if (now[order[i]] case final sent?) {
        settled[order[i]] = sent.rect;
        places?.update(sent.place, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    if (fault != null) faults.add('${order.join(' > ')}: $fault');
    await tester.pump(GameState.emojiBubbleFor);
    await tester.pump();
    expect(_playing(tester), isEmpty, reason: '${order.join(' > ')} ended');
  }
  return faults;
}

String _report(List<String> faults, int of) =>
    '${faults.length} of $of orders went wrong\n${faults.take(12).join('\n')}';

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

/// A table of [places] places, everyone seated and nobody sending.
TableScene _placesScene(int places) => TableScene('$places-places', (s) {
  s.config = s.config.copyWith(maxPlayers: places);
  s.handleState(placesRoom(places));
});

/// [userId]'s pod has its emoji ON it ([EmojiPlace.pod]): fitted inside the
/// pod's box, exactly where [SeatPod.emojiOnPod] says.
void _expectOnPod(WidgetTester tester, String userId) {
  expect(_placeOf(tester, userId), EmojiPlace.pod, reason: userId);
  final pod = tester.getRect(_plaqueOf(userId));
  final mine = tester.getRect(_emojiOf(userId));
  final want = SeatPod.emojiOnPod(pod);
  expect(
    (mine.topLeft - want.topLeft).distance,
    lessThan(0.5),
    reason: '$userId $mine, not $want',
  );
  expect(
    (mine.bottomRight - want.bottomRight).distance,
    lessThan(0.5),
    reason: userId,
  );
  expect(pod.contains(mine.topLeft) && pod.contains(mine.bottomRight), isTrue);
}

void main() {
  const everyone = ['u0', 'u1', 'u2', 'u3', 'u4'];

  // Every order the five players can send in, 300 ms apart (the second review
  // of 28 Sep 2026: with every emoji sent at once the viewer is always placed
  // first, and the orders in which it is not were never tried — in half of
  // them two emojis met). After every send, every emoji playing is checked:
  // none meets another (1), none is under anything painted after its seat
  // (2), none is off the felt (3), none has moved since it landed (4), and
  // each is at its sender's seat (5). All 120 orders at each size.
  for (final (size, scale) in const [
    (Size(640, 360), 1.0),
    (Size(915, 412), 1.25),
    (Size(592, 360), 1.25),
    (Size(844, 390), 1.25),
  ]) {
    testWidgets('at ${_nameOf(size, scale)}, every order of five emojis '
        '300 ms apart', (tester) async {
      final orders = _orders(everyone);
      final state = await _mount(
        tester,
        _scene('17-dealing'),
        size: size,
        textScale: scale,
      );
      final faults = await _sweep(tester, state, orders, everyone);
      expect(faults, isEmpty, reason: _report(faults, orders.length));
      expect(tester.takeException(), isNull);
      await _unmount(tester, state);
    });
  }

  // And on the poker felt: the room of the scene of every poker seat at once
  // (15b, whose emojis are set without the clock that ends them, so the sweep
  // takes the same room from 15).
  for (final (size, scale) in const [
    (Size(640, 360), 1.0),
    (Size(915, 412), 1.25),
  ]) {
    testWidgets('at ${_nameOf(size, scale)}, a poker room: every order of '
        'five emojis 300 ms apart', (tester) async {
      final orders = _orders(everyone);
      final state = await _mount(
        tester,
        _scene('15-poker-holdem'),
        size: size,
        textScale: scale,
      );
      final faults = await _sweep(tester, state, orders, everyone, poker: true);
      expect(faults, isEmpty, reason: _report(faults, orders.length));
      expect(tester.takeException(), isNull);
      await _unmount(tester, state);
    });
  }

  // The tables of two, three and four places: every order too.
  for (final (size, scale) in const [
    (Size(592, 360), 1.25),
    (Size(640, 360), 1.0),
    (Size(915, 412), 1.25),
  ]) {
    for (final places in const [2, 3, 4]) {
      testWidgets('at ${_nameOf(size, scale)}, $places places: every order '
          '300 ms apart', (tester) async {
        final seated = everyone.take(places).toList();
        final orders = _orders(seated);
        final state = await _mount(
          tester,
          _placesScene(places),
          size: size,
          textScale: scale,
        );
        final faults = await _sweep(tester, state, orders, seated);
        expect(faults, isEmpty, reason: _report(faults, orders.length));
        expect(tester.takeException(), isNull);
        await _unmount(tester, state);
      });
    }
  }

  // The review's own cases: Ravi's, then Meera's, then the viewer's — and
  // Meera's then the viewer's. The viewer's own place meets Meera's; beside
  // their pod is their hand on one side and Missile and Pack on the other;
  // above it and to the left is Ravi's own place (where the first fix slid
  // it, and where Ravi's met it). So it plays on the viewer's own pod — and
  // Ravi's, sent after it, still plays in its own place.
  for (final (size, scale) in const [
    (Size(592, 360), 1.25),
    (Size(640, 360), 1.0),
    (Size(640, 360), 1.25),
    (Size(640, 360), 1.3),
    (Size(732, 412), 1.0),
    (Size(800, 360), 1.0),
    (Size(844, 390), 1.0),
    (Size(844, 390), 1.25),
    (Size(891, 411), 1.0),
    (Size(915, 412), 1.0),
    (Size(915, 412), 1.25),
    (Size(1024, 600), 1.0),
  ]) {
    testWidgets('at ${_nameOf(size, scale)}, Ravi\'s, Meera\'s, then the '
        'viewer\'s: the viewer\'s plays on their pod', (tester) async {
      final state = await _mount(
        tester,
        _scene('17-dealing'),
        size: size,
        textScale: scale,
      );
      await _send(tester, state, _emoji('u1', 'Ravi', 1000));
      await _send(tester, state, _emoji('u2', 'Meera', 1300));
      await _send(tester, state, _emoji('u0', 'Priya', 1600));
      expect(_placeOf(tester, 'u1'), EmojiPlace.column);
      expect(_placeOf(tester, 'u2'), EmojiPlace.column);
      _expectOnPod(tester, 'u0');
      _expectOnScreen(tester, const ['u0', 'u1', 'u2'], size);
      _expectApart(tester, const ['u0', 'u1', 'u2']);
      for (final id in const ['u0', 'u1', 'u2']) {
        _expectOnTop(tester, id, everyone);
      }
      expect(tester.takeException(), isNull);
      await tester.pump(GameState.emojiBubbleFor);
      await _unmount(tester, state);
    });

    testWidgets('at ${_nameOf(size, scale)}, Meera\'s then the viewer\'s, '
        'then Ravi\'s: Ravi\'s own place was kept for him', (tester) async {
      final state = await _mount(
        tester,
        _scene('17-dealing'),
        size: size,
        textScale: scale,
      );
      await _send(tester, state, _emoji('u2', 'Meera', 1000));
      await _send(tester, state, _emoji('u0', 'Priya', 1300));
      expect(_placeOf(tester, 'u2'), EmojiPlace.column);
      _expectOnPod(tester, 'u0');
      await _send(tester, state, _emoji('u1', 'Ravi', 1600));
      expect(_placeOf(tester, 'u1'), EmojiPlace.column);
      _expectOnPod(tester, 'u0');
      _expectApart(tester, const ['u0', 'u1', 'u2']);
      for (final id in const ['u0', 'u1', 'u2']) {
        _expectOnTop(tester, id, everyone);
      }
      expect(tester.takeException(), isNull);
      await tester.pump(GameState.emojiBubbleFor);
      await _unmount(tester, state);
    });
  }

  // Where a seat's own emoji plays, as the felt reckons it before anything
  // is drawn there (SeatPod.emojiHome), is where it does play: every seat,
  // at every number of places and on the poker felt.
  for (final (size, scale) in const [
    (Size(592, 360), 1.25),
    (Size(640, 360), 1.0),
    (Size(915, 412), 1.25),
  ]) {
    for (final (label, scene, seated) in [
      for (final places in const [2, 3, 4, 5])
        (
          '$places places',
          _placesScene(places),
          everyone.take(places).toList(),
        ),
      ('a poker room', _scene('15-poker-holdem'), everyone),
    ]) {
      testWidgets('at ${_nameOf(size, scale)}, $label: each seat\'s own place '
          'is where the felt reckons it', (tester) async {
        final state = await _mount(tester, scene, size: size, textScale: scale);
        for (final id in seated) {
          await _send(tester, state, _emoji(id, id, 1000));
          expect(_placeOf(tester, id), EmojiPlace.column);
          final seatPod = tester.widget<SeatPod>(_podOf(id));
          final pod = tester.getRect(_plaqueOf(id));
          final home = seatPod.emojiHome(
            seat: tester.getRect(_podOf(id)),
            pod: pod,
            bubble: SeatPod.emojiBubbleSize(pod.width),
          );
          final mine = tester.getRect(_emojiOf(id));
          expect(
            (mine.topLeft - home.topLeft).distance,
            lessThan(0.5),
            reason: '$id $mine, not $home',
          );
          expect((mine.bottomRight - home.bottomRight).distance, lessThan(0.5));
          await tester.pump(GameState.emojiBubbleFor);
        }
        expect(tester.takeException(), isNull);
        await _unmount(tester, state);
      });
    }
  }

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

    // The first review of 28 Sep 2026: the viewer's emoji, moved off Meera's,
    // stood beside their pod over their own cards — and the felt paints the
    // hand after the viewer's seat, so the cards covered three quarters of it;
    // its other side was under Missile and Pack. Either way round, the one
    // that moves is seen whole.
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
          // And it is plainly the viewer's: on their own pod.
          _expectOnPod(tester, 'u0');
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
    // one side and Missile and Pack on the other, both drawn over it, and
    // above it to the left is Ravi's own place: theirs plays on their own pod
    // (the second review, 28 Sep 2026).
    await _send(tester, state, _emoji('u2', 'Meera', 1000));
    expect(_placeOf(tester, 'u2'), EmojiPlace.column);
    final meera = tester.getRect(_emojiOf('u2'));
    await _send(tester, state, _emoji('u0', 'Priya', 2000));
    expect(_placeOf(tester, 'u2'), EmojiPlace.column);
    _expectAt(tester.getRect(_emojiOf('u2')), meera);
    _expectOnPod(tester, 'u0');
    _expectApart(tester, ['u0', 'u2']);
    final mine = tester.getRect(_emojiOf('u0'));

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
    // Beside her pod, towards the middle of the table.
    expect(_placeOf(tester, 'u2'), EmojiPlace.right);
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
