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

/// What is painted over every seat — the viewer's own hand and cards, and
/// the controls the screen stands over the felt's corners — by name.
Map<String, Rect> _overEverySeat(WidgetTester tester, {bool poker = false}) {
  final cards = find.descendant(
    of: _private(poker ? '_PokerHand' : '_OwnHand'),
    matching: find.byType(PlayingCard),
  );
  return {
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
      if (_private(key).evaluate().isNotEmpty)
        key: tester.getRect(_private(key)),
    'the Shop key': tester.getRect(find.byType(ShopButton)),
    'the wallet': tester.getRect(find.byType(TableWallet)),
  };
}

/// What [userId]'s seat is saying, while it says it.
Finder _speechOf(String userId) =>
    find.descendant(of: _podOf(userId), matching: _private('_Bubble'));

/// Everything painted over [userId]'s seat, by name: the seats the felt paints
/// after it — the rim in view order, then the viewer's — and what they are
/// saying, the part of its own seat that stands beside its pod (the head
/// seat's cards), and what is painted over every seat ([_overEverySeat]). In
/// these scenes seat i is `u<i>` and the viewer is u0, so the order is
/// [seated]'s with u0 last. [shared] is [_overEverySeat], measured once.
Map<String, Rect> _paintedOver(
  WidgetTester tester,
  String userId,
  List<String> seated, {
  bool poker = false,
  Map<String, Rect>? shared,
  Map<String, Rect>? seats,
}) {
  final order = [...seated.where((id) => id != 'u0'), 'u0'];
  final later = order.sublist(order.indexOf(userId) + 1);
  final seat = seats?[userId] ?? tester.getRect(_podOf(userId));
  final pod = tester.getRect(_plaqueOf(userId));
  return {
    for (final id in later) ...{
      'seat $id': seats?[id] ?? tester.getRect(_podOf(id)),
      if (_speechOf(id).evaluate().isNotEmpty)
        'what $id is saying': tester.getRect(_speechOf(id)),
      for (final (i, text)
          in find
              .descendant(of: _podOf(id), matching: find.byType(Text))
              .evaluate()
              .indexed)
        'the words of $id ($i)': tester.getRect(
          find.byElementPredicate((e) => e == text),
        ),
    },
    if (seat.right - pod.right > 0.5)
      'its own cards': Rect.fromLTRB(
        pod.right,
        seat.top,
        seat.right,
        seat.bottom,
      ),
    ...shared ?? _overEverySeat(tester, poker: poker),
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

/// How a sweep's orders are named: all of them, or one in [every].
String _which(int every) => every == 1 ? 'every order' : 'one order in $every';

/// Every [n]th of [orders], from the first: a deterministic part of a sweep
/// where all of them would make the suite too slow to run.
List<List<String>> _everyNth(List<List<String>> orders, int n) => [
  for (var i = 0; i < orders.length; i += n) orders[i],
];

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
/// pod, each seat's own place ([SeatPod.emojiHome]), and what is painted over
/// each seat ([_paintedOver]). None of it moves while emojis come and go — an
/// emoji takes no room in its seat.
typedef _Stage = ({
  Rect felt,
  Map<String, Rect> seats,
  Map<String, Rect> pods,
  Map<String, Rect> homes,
  Map<String, Map<String, Rect>> over,
});

/// The stage as it stands. What the viewer's hand paints over the seats is
/// its cards, its name's capsule and its bet badge, each where it is drawn
/// this frame — the deal's cards in flight included — and, with [handAtRest],
/// the hand's whole column too: the box it is laid out in, which is empty
/// round those three and, for the 300 ms its lift glides after the hand's
/// name arrives at a showdown, stands a few dp higher than where it comes to
/// rest (the felt keeps emojis from under the box at rest). A sweep asks for
/// the box once whatever it did has settled.
_Stage _stageOf(
  WidgetTester tester,
  List<String> seated, {
  bool poker = false,
  bool handAtRest = true,
}) {
  // One walk of the tree — the sweeps measure this after every send and
  // through every step — for what the finders above find one at a time.
  final seats = <String, Rect>{};
  final pods = <String, Rect>{};
  final homes = <String, Rect>{};
  final speech = <String, Rect>{};
  final words = <String, List<Rect>>{};
  final shared = <String, Rect>{};
  Rect? felt;
  var cards = 0;
  Rect rectOf(Element e) {
    final box = e.renderObject! as RenderBox;
    return Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    );
  }

  final keys = poker
      ? const {'_PokerKeys', '_FoldKey'}
      : const {'_MissileKey', '_PackKey', '_ActionCluster'};
  final hand = poker ? '_PokerHand' : '_OwnHand';
  final feltType = poker ? '_PokerFelt' : '_Felt';
  void visit(Element e, {bool inHand = false, bool inFelt = false}) {
    final widget = e.widget;
    final type = widget.runtimeType.toString();
    if (widget is SeatPod && widget.seat?.userId != null) {
      final id = widget.seat!.userId!;
      seats[id] = rectOf(e);
      Element? plaque;
      Element? said;
      final texts = words[id] = [];
      void inner(Element c) {
        if (plaque == null && c.widget is GestureDetector) plaque = c;
        if (said == null && c.widget.runtimeType.toString() == '_Bubble') {
          said = c;
        }
        // Every word the seat writes: the viewer's status line stands over
        // their pod, outside their seat's box.
        if (c.widget is Text) texts.add(rectOf(c));
        c.debugVisitOnstageChildren(inner);
      }

      e.debugVisitOnstageChildren(inner);
      if (plaque case final p?) {
        final pod = pods[id] = rectOf(p);
        homes[id] = widget.emojiHome(
          seat: seats[id]!,
          pod: pod,
          bubble: SeatPod.emojiBubbleSize(widget.width),
        );
      }
      if (said case final w?) speech[id] = rectOf(w);
      return;
    }
    if (inFelt && felt == null && widget is LayoutBuilder) felt = rectOf(e);
    if (inHand && widget is PlayingCard) {
      shared['the viewer\'s card ${cards++}'] = rectOf(e);
    }
    // The hand's column: the Teen Patti felt's once it has settled
    // ([handAtRest]); the poker felt's, which stands on the floor and does not
    // glide, always.
    if (handAtRest &&
        widget.key ==
            (poker
                ? const ValueKey('own-hand')
                : const ValueKey('own-hand-column')) &&
        !shared.containsKey('the viewer\'s hand')) {
      shared['the viewer\'s hand'] = rectOf(e);
    }
    // What the hand draws over its cards: its name's capsule and its bet.
    if (type == '_OwnHandName' || type == '_OwnHandLine') {
      shared['the viewer\'s hand name'] = rectOf(e);
    }
    if (widget is SeatBet) shared['the viewer\'s bet'] = rectOf(e);
    if (keys.contains(type) && !shared.containsKey(type)) {
      shared[type] = rectOf(e);
    }
    if (widget is ShopButton && !shared.containsKey('the Shop key')) {
      shared['the Shop key'] = rectOf(e);
    }
    if (widget is TableWallet && !shared.containsKey('the wallet')) {
      shared['the wallet'] = rectOf(e);
    }
    e.debugVisitOnstageChildren(
      (c) => visit(
        c,
        inHand: inHand || type == hand,
        inFelt: inFelt || type == feltType,
      ),
    );
  }

  tester.binding.rootElement!.debugVisitOnstageChildren(visit);
  final order = [...seated.where((id) => id != 'u0'), 'u0'];
  return (
    felt: felt!,
    seats: {for (final id in seated) id: seats[id]!},
    pods: {for (final id in seated) id: pods[id]!},
    homes: {for (final id in seated) id: homes[id]!},
    over: {
      for (final id in seated)
        id: {
          for (final later in order.sublist(order.indexOf(id) + 1)) ...{
            'seat $later': seats[later]!,
            'what $later is saying': ?speech[later],
            for (final (i, text) in words[later]!.indexed)
              'the words of $later ($i)': text,
          },
          if (seats[id]!.right - pods[id]!.right > 0.5)
            'its own cards': Rect.fromLTRB(
              pods[id]!.right,
              seats[id]!.top,
              seats[id]!.right,
              seats[id]!.bottom,
            ),
          ...shared,
        },
    },
  );
}

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
    // Never over another seat's pod, wherever it plays (the design's hard
    // rule, which keeps every pod free for its own seat's last place)…
    for (final MapEntry(key: other, value: pod) in stage.pods.entries) {
      if (other != id && pod.deflate(2).overlaps(rect.deflate(2))) {
        return '$id\'s emoji $where is over $other\'s pod $pod';
      }
    }
    // …and, moved, never in another seat's own place, where it would be
    // read as that seat's: an own place the felt holds, over no pod.
    if (place != EmojiPlace.column && place != EmojiPlace.pod) {
      for (final MapEntry(key: other, value: home) in stage.homes.entries) {
        if (other == id) continue;
        if (!on.contains(home.topLeft) || !on.contains(home.bottomRight)) {
          continue;
        }
        if (stage.pods.entries.any(
          (p) => p.key != other && p.value.deflate(2).overlaps(home.deflate(2)),
        )) {
          continue;
        }
        if (home.deflate(2).overlaps(rect.deflate(2))) {
          return '$id\'s emoji $where is in $other\'s own place $home';
        }
      }
    }
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

/// A change the table goes through while emojis play: its name, what it
/// does to the table, and when after it to look — through any animation it
/// starts (a deal's cards fly in over its first half second).
typedef _Step = ({String name, void Function(GameState state) apply});

/// How long after a step every emoji is looked at again: through the deal's
/// entrance, frame by frame at first.
const _watch = [
  Duration(milliseconds: 16),
  Duration(milliseconds: 50),
  Duration(milliseconds: 100),
  Duration(milliseconds: 166),
  Duration(milliseconds: 300),
  Duration(milliseconds: 700),
];

/// Sends each of [orders] at a table put into [start] — one emoji a player,
/// [gap] apart — and then, while they all still play, takes the table
/// through [steps] (the review of 29 Sep 2026: a deal to a table that was
/// waiting, a hand won and the next dealt, the turn going round, a poker
/// street). After every send, and again and again after every step
/// ([_watch]), every emoji playing is checked against the table AS IT NOW
/// STANDS: none meets another (1), none is under anything painted after its
/// seat (2), none is off the felt (3), none has moved since it landed (4),
/// and each is at its sender's seat (5). The orders that went wrong, each
/// with its first fault; and how often each place was taken ([places]).
Future<List<String>> _sweepThrough(
  WidgetTester tester,
  GameState state,
  List<List<String>> orders,
  List<String> seated, {
  required void Function(GameState state) start,
  List<_Step> steps = const [],
  List<String>? seatedAfter,
  bool poker = false,
  Duration gap = const Duration(milliseconds: 300),
  List<Duration> watch = _watch,
  Map<EmojiPlace, int>? places,
}) async {
  final faults = <String>[];
  var clock = 100000;
  for (final order in orders) {
    start(state);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    final settled = <String, Rect>{};
    String? fault;
    for (var i = 0; i < order.length; i++) {
      clock += gap.inMilliseconds;
      state.handleChat(_emoji(order[i], order[i], clock));
      await tester.pump();
      await tester.pump(gap);
      final now = _playing(tester);
      fault ??= _faultIn(
        order.sublist(0, i + 1),
        now,
        settled,
        _stageOf(tester, seated, poker: poker),
      );
      if (now[order[i]] case final sent?) {
        settled[order[i]] = sent.rect;
        places?.update(sent.place, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    for (final step in steps) {
      step.apply(state);
      await tester.pump();
      var elapsed = Duration.zero;
      for (final at in watch) {
        await tester.pump(at - elapsed);
        elapsed = at;
        if (fault != null) continue;
        final why = _faultIn(
          order,
          _playing(tester),
          settled,
          _stageOf(
            tester,
            seatedAfter ?? seated,
            poker: poker,
            handAtRest: at == watch.last,
          ),
        );
        if (why != null) {
          fault = 'after ${step.name}, ${at.inMilliseconds} ms: $why';
        }
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

  // The third review (29 Sep 2026): placed once, the emojis moved with their
  // seats. Emojis sent while a table waits for its first deal, then the deal
  // (every rim seat's column grew a row of cards, and placed by its middle
  // rose, the viewer's emoji ending on Meera's in every order at 640 and
  // 1024); a hand the viewer wins and the next deal (their "Winner" line
  // lifted their emoji onto Ravi's pod at 592 ×1.25). Every order, looked at
  // again and again through each step: now the seats hold still and a placed
  // emoji is pinned.
  for (final (size, scale, every) in const [
    (Size(640, 360), 1.0, 1),
    (Size(1024, 600), 1.0, 1),
    (Size(592, 360), 1.25, 3),
    (Size(915, 412), 1.25, 3),
  ]) {
    testWidgets('at ${_nameOf(size, scale)}, ${_which(every)} of five emojis '
        'while the table waits, then the deal', (tester) async {
      final orders = _everyNth(_orders(everyone), every);
      final places = <EmojiPlace, int>{};
      final state = await _mount(
        tester,
        _scene('01-opponent-turn'),
        size: size,
        textScale: scale,
      );
      final faults = await _sweepThrough(
        tester,
        state,
        orders,
        everyone,
        start: (s) => s.handleState(waitingRoom()),
        steps: [
          (
            name: 'the deal',
            apply: (s) => s.handleState(opponentTurnRoom(handNo: 1)),
          ),
        ],
        places: places,
      );
      expect(faults, isEmpty, reason: _report(faults, orders.length));
      expect(tester.takeException(), isNull);
      await _unmount(tester, state);
    });
  }

  for (final (size, scale, every) in const [
    (Size(592, 360), 1.25, 1),
    (Size(640, 360), 1.0, 3),
    (Size(915, 412), 1.25, 3),
  ]) {
    testWidgets('at ${_nameOf(size, scale)}, ${_which(every)} of five emojis, '
        'then the viewer wins and the next hand is dealt', (tester) async {
      final orders = _everyNth(_orders(everyone), every);
      final state = await _mount(
        tester,
        _scene('20-opponent-turn-seen'),
        size: size,
        textScale: scale,
      );
      final faults = await _sweepThrough(
        tester,
        state,
        orders,
        everyone,
        start: (s) => s.handleState(seenOpponentTurnRoom()),
        steps: [
          (
            name: 'the win',
            apply: (s) {
              s.handleState(youWonRoom());
              youWonShowdown(s);
            },
          ),
          (
            name: 'the next deal',
            apply: (s) => s.handleState(seenOpponentTurnRoom(handNo: 8)),
          ),
        ],
      );
      expect(faults, isEmpty, reason: _report(faults, orders.length));
      expect(tester.takeException(), isNull);
      await _unmount(tester, state);
    });
  }

  // The turn going round the table while every emoji plays: the ring round
  // the pod on turn makes its box taller, and the viewer's turn lights the
  // keys at the foot.
  for (final (size, scale, every) in const [
    (Size(640, 360), 1.0, 3),
    (Size(592, 360), 1.25, 3),
    (Size(915, 412), 1.25, 3),
  ]) {
    testWidgets('at ${_nameOf(size, scale)}, ${_which(every)} of five emojis '
        'while the turn goes round', (tester) async {
      final orders = _everyNth(_orders(everyone), every);
      final state = await _mount(
        tester,
        _scene('01-opponent-turn'),
        size: size,
        textScale: scale,
      );
      _Step turn(int seat) => (
        name: 'the turn to u$seat',
        apply: (s) => s.handleState(blindTurnRoom(turnSeat: seat)),
      );
      final faults = await _sweepThrough(
        tester,
        state,
        orders,
        everyone,
        start: (s) => s.handleState(blindTurnRoom(turnSeat: 2)),
        steps: [turn(3), turn(4), turn(0), turn(1)],
        watch: const [Duration(milliseconds: 16), Duration(milliseconds: 300)],
      );
      expect(faults, isEmpty, reason: _report(faults, orders.length));
      expect(tester.takeException(), isNull);
      await _unmount(tester, state);
    });
  }

  // A poker room's new street: every street bet leaves its badge.
  for (final (size, scale, every) in const [
    (Size(640, 360), 1.0, 1),
    (Size(915, 412), 1.25, 3),
  ]) {
    testWidgets('at ${_nameOf(size, scale)}, a poker room: ${_which(every)} '
        'of five emojis, then a new street', (tester) async {
      final orders = _everyNth(_orders(everyone), every);
      final state = await _mount(
        tester,
        _scene('15-poker-holdem'),
        size: size,
        textScale: scale,
      );
      final faults = await _sweepThrough(
        tester,
        state,
        orders,
        everyone,
        poker: true,
        start: (s) => s.handleState(pokerRoom()),
        steps: [
          (
            name: 'the turn card',
            apply: (s) => s.handleState(pokerNewStreetRoom()),
          ),
        ],
      );
      expect(faults, isEmpty, reason: _report(faults, orders.length));
      expect(tester.takeException(), isNull);
      await _unmount(tester, state);
    });
  }

  // Tables of two, three and four places, waiting and then dealt.
  for (final (size, scale) in const [
    (Size(592, 360), 1.25),
    (Size(640, 360), 1.0),
    (Size(915, 412), 1.25),
  ]) {
    for (final places in const [2, 3, 4]) {
      testWidgets('at ${_nameOf(size, scale)}, $places places: every order '
          'while the table waits, then the deal', (tester) async {
        final seated = everyone.take(places).toList();
        final orders = _orders(seated);
        final state = await _mount(
          tester,
          _placesScene(places),
          size: size,
          textScale: scale,
        );
        final faults = await _sweepThrough(
          tester,
          state,
          orders,
          seated,
          start: (s) => s.handleState(waitingRoom(places: places)),
          steps: [
            (
              name: 'the deal',
              apply: (s) => s.handleState(
                blindTurnRoom(handNo: 1, places: places, turnSeat: places - 1),
              ),
            ),
          ],
        );
        expect(faults, isEmpty, reason: _report(faults, orders.length));
        expect(tester.takeException(), isNull);
        await _unmount(tester, state);
      });
    }
  }

  // Somebody sits down in the one empty chair while the others' emojis play.
  for (final (size, scale) in const [
    (Size(592, 360), 1.25),
    (Size(915, 412), 1.25),
  ]) {
    testWidgets('at ${_nameOf(size, scale)}, a player sits down in an empty '
        'chair while one order in two of the others\' emojis plays', (
      tester,
    ) async {
      final state = await _mount(
        tester,
        _placesScene(5),
        size: size,
        textScale: scale,
      );
      final faults = <String>[];
      for (final empty in const [1, 2, 3, 4]) {
        final others = everyone.where((id) => id != 'u$empty').toList();
        final orders = _everyNth(_orders(others), 2);
        faults.addAll([
          for (final fault in await _sweepThrough(
            tester,
            state,
            orders,
            others,
            seatedAfter: everyone,
            start: (s) => s.handleState(placesRoom(5, empty: [empty])),
            steps: [
              (
                name: 'u$empty sitting down',
                apply: (s) => s.handleState(placesRoom(5)),
              ),
            ],
            watch: const [
              Duration(milliseconds: 16),
              Duration(milliseconds: 300),
            ],
          ))
            'u$empty\'s chair: $fault',
        ]);
      }
      expect(faults, isEmpty, reason: _report(faults, 4 * 12));
      expect(tester.takeException(), isNull);
      await _unmount(tester, state);
    });
  }

  // What a seat painted after another is saying lies over the other's seat:
  // an emoji of the other's, sent while the words are up, is kept from under
  // them.
  for (final (size, scale) in const [
    (Size(592, 360), 1.25),
    (Size(640, 360), 1.0),
    (Size(915, 412), 1.25),
  ]) {
    testWidgets('at ${_nameOf(size, scale)}, an emoji sent while a seat '
        'painted after its sender is talking is not under the words', (
      tester,
    ) async {
      final state = await _mount(
        tester,
        _scene('17-dealing'),
        size: size,
        textScale: scale,
      );
      const order = ['u1', 'u2', 'u3', 'u4', 'u0'];
      var clock = 500000;
      for (var s = 1; s < order.length; s++) {
        final speaker = order[s];
        for (final sender in order.take(s)) {
          clock += 1000;
          state.handleChat(
            ChatMessage(
              userId: speaker,
              displayName: speaker,
              text: 'That was a close one, next hand is mine',
              at: clock,
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(_speechOf(speaker), findsOneWidget, reason: speaker);
          await _send(tester, state, _emoji(sender, sender, clock + 1));
          _expectOnScreen(tester, [sender], size);
          _expectOnTop(tester, sender, everyone);
          await tester.pump(const Duration(seconds: 9));
          await tester.pump();
        }
      }
      expect(tester.takeException(), isNull);
      await _unmount(tester, state);
    });
  }

  // A lone emoji plays in its own place, whatever the table is doing — the
  // third review saw the viewer's, while the table waited for its first deal,
  // go onto their own pod at 592 to 915dp, their "Waiting" line having lifted
  // its place into Meera's pod.
  for (final (size, scale) in _phones) {
    testWidgets('at ${_nameOf(size, scale)}, a lone emoji plays in its own '
        'place while the table waits, when it is dealt and when the viewer '
        'has won', (tester) async {
      final state = await _mount(
        tester,
        _scene('01-opponent-turn'),
        size: size,
        textScale: scale,
      );
      var clock = 700000;
      for (final (label, setUp) in <(String, void Function(GameState))>[
        ('waiting', (s) => s.handleState(waitingRoom())),
        ('dealt', (s) => s.handleState(opponentTurnRoom(handNo: 1))),
        (
          'the viewer on turn',
          (s) => s.handleState(blindTurnRoom(turnSeat: 0)),
        ),
        ('a seen hand', (s) => s.handleState(seenOpponentTurnRoom(handNo: 2))),
        (
          'won',
          (s) {
            s.handleState(youWonRoom(handNo: 3));
            youWonShowdown(s);
          },
        ),
      ]) {
        setUp(state);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 900));
        for (final id in everyone) {
          clock += 1000;
          await _send(tester, state, _emoji(id, id, clock));
          expect(
            _placeOf(tester, id),
            EmojiPlace.column,
            reason: '$id, $label',
          );
          _expectOnTop(tester, id, everyone);
          await tester.pump(GameState.emojiBubbleFor);
          await tester.pump();
        }
      }
      expect(tester.takeException(), isNull);
      await _unmount(tester, state);
    });
  }

  // The review's own cases: Ravi's, then Meera's, then the viewer's — and
  // Meera's then the viewer's. The viewer's own place meets Meera's; beside
  // their pod is their hand on one side and Missile and Pack on the other;
  // above it and to the left is Ravi's own place (where the first fix slid
  // it, and where Ravi's met it). So it plays on the viewer's own pod — and
  // Ravi's, sent after it, still plays in its own place. Except at 592x360
  // x1.25: the ring stands the viewer 40dp left of its place there to keep
  // their hand clear of the keys, and since their own place stands over
  // their pod rather than over the status line above it (29 Sep 2026) it
  // no longer meets Meera's at all, so nothing moves.
  for (final (size, scale, meets) in const [
    (Size(592, 360), 1.25, false),
    (Size(640, 360), 1.0, true),
    (Size(640, 360), 1.25, true),
    (Size(640, 360), 1.3, true),
    (Size(732, 412), 1.0, true),
    (Size(800, 360), 1.0, true),
    (Size(844, 390), 1.0, true),
    (Size(844, 390), 1.25, true),
    (Size(891, 411), 1.0, true),
    (Size(915, 412), 1.0, true),
    (Size(915, 412), 1.25, true),
    (Size(1024, 600), 1.0, true),
  ]) {
    // The viewer's own place against Meera's emoji where it plays: whether
    // they meet is what the expectation above says for this size.
    void expectMeeting(WidgetTester tester) {
      final viewer = tester.widget<SeatPod>(_podOf('u0'));
      final home = viewer.emojiHome(
        seat: tester.getRect(_podOf('u0')),
        pod: tester.getRect(_plaqueOf('u0')),
        bubble: SeatPod.emojiBubbleSize(viewer.width),
      );
      expect(
        home.deflate(2).overlaps(tester.getRect(_emojiOf('u2')).deflate(2)),
        meets,
        reason: 'the viewer\'s own place $home and Meera\'s emoji',
      );
    }

    void expectViewer(WidgetTester tester) => meets
        ? _expectOnPod(tester, 'u0')
        : expect(_placeOf(tester, 'u0'), EmojiPlace.column);

    testWidgets('at ${_nameOf(size, scale)}, Ravi\'s, Meera\'s, then the '
        'viewer\'s: the viewer\'s plays '
        '${meets ? 'on their pod' : 'in its own place'}', (tester) async {
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
      expectMeeting(tester);
      expectViewer(tester);
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
      expectMeeting(tester);
      expectViewer(tester);
      await _send(tester, state, _emoji('u1', 'Ravi', 1600));
      expect(_placeOf(tester, 'u1'), EmojiPlace.column);
      expectViewer(tester);
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
  // is drawn there (SeatPod.emojiHome), is where it does play: in its first
  // frame, hung in the bubble's own place before the felt has placed it, and
  // from the next on, pinned there — with no jump between the two. Every
  // seat, at every number of places, on the poker felt, and at a table
  // waiting for its first deal.
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
      (
        'a table waiting for its first deal',
        TableScene('waiting', (s) => s.handleState(waitingRoom())),
        everyone,
      ),
    ]) {
      testWidgets('at ${_nameOf(size, scale)}, $label: each seat\'s own place '
          'is where the felt reckons it', (tester) async {
        final state = await _mount(tester, scene, size: size, textScale: scale);
        for (final id in seated) {
          state.handleChat(_emoji(id, id, 1000));
          // The first frame: the bubble's own place, before it is placed.
          await tester.pump();
          expect(
            tester.widget<SeatPod>(_podOf(id)).emojiPin,
            isNull,
            reason: '$id, first frame',
          );
          final seatPod = tester.widget<SeatPod>(_podOf(id));
          final pod = tester.getRect(_plaqueOf(id));
          final home = seatPod.emojiHome(
            seat: tester.getRect(_podOf(id)),
            pod: pod,
            bubble: SeatPod.emojiBubbleSize(pod.width),
          );
          final first = tester.getRect(_emojiOf(id));
          expect(
            (first.topLeft - home.topLeft).distance,
            lessThan(0.5),
            reason: '$id $first, not $home',
          );
          expect(
            (first.bottomRight - home.bottomRight).distance,
            lessThan(0.5),
          );
          // Placed, and pinned exactly there.
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(_placeOf(tester, id), EmojiPlace.column, reason: id);
          expect(tester.widget<SeatPod>(_podOf(id)).emojiPin, isNotNull);
          final pinned = tester.getRect(_emojiOf(id));
          expect(
            (pinned.topLeft - first.topLeft).distance,
            lessThan(0.5),
            reason: '$id jumped from $first to $pinned',
          );
          expect(
            (pinned.bottomRight - first.bottomRight).distance,
            lessThan(0.5),
          );
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
    // that moves is seen whole. (At 592x360 x1.25 the two own places do not
    // meet, and neither moves: the review's own cases, above.)
    final meets = !(size == const Size(592, 360) && scale == 1.25);
    for (final (first, then) in const [('u2', 'u0'), ('u0', 'u2')]) {
      testWidgets('at $name, $then\'s after $first\'s: '
          '${meets ? 'the one that moves stands over nothing painted after '
                    'it' : 'neither moves'}', (tester) async {
        final state = await _mount(
          tester,
          _scene('17-dealing'),
          size: size,
          textScale: scale,
        );
        await _send(tester, state, _emoji(first, first, 1000));
        final later = tester.widget<SeatPod>(_podOf(then));
        final home = later.emojiHome(
          seat: tester.getRect(_podOf(then)),
          pod: tester.getRect(_plaqueOf(then)),
          bubble: SeatPod.emojiBubbleSize(later.width),
        );
        expect(
          home.deflate(2).overlaps(tester.getRect(_emojiOf(first)).deflate(2)),
          meets,
          reason: '$then\'s own place $home and $first\'s emoji',
        );
        await _send(tester, state, _emoji(then, then, 2000));
        expect(tester.takeException(), isNull);
        expect(_placeOf(tester, first), EmojiPlace.column);
        if (!meets) {
          expect(_placeOf(tester, then), EmojiPlace.column);
          _expectApart(tester, [first, then]);
          _expectOnTop(tester, then, everyone);
          await tester.pump(GameState.emojiBubbleFor);
          await tester.pump(const Duration(milliseconds: 400));
          await _unmount(tester, state);
          return;
        }
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
