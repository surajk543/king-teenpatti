// 5-Card Teen Patti, as the client sees it (owner, 18 Sep 2026).
//
// A seventh variation: every player holds FIVE cards and plays the best three.
// The SERVER finds those three and names them (`best`); the player never
// picks, and the client never decides how many cards anybody holds — it draws
// `variation.cardsPerPlayer` backs, `seats[].cardCount` backs, and whatever
// `you.cards` carries. Every hand is dealt three and topped up to five the
// moment 5-Card is chosen, so the same hand is seen both ways.
//
// A five-card hand must stand in the box a three-card one does, and a
// three-card table must be exactly what it was.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/hand_fan.dart';
import 'package:teenpatti/widgets/playing_card.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/seat_pod.dart';
import 'package:teenpatti/widgets/variation_prompt.dart';

const _ids = ['u0', 'u1', 'u2', 'u3', 'u4'];
const _five = ['As', 'Ks', 'Qs', '7d', '7c'];
const _best = ['As', 'Ks', 'Qs'];

int get _now => DateTime.now().millisecondsSinceEpoch;

/// The snapshot's variation block. [selected] null is the window still open.
Map<String, dynamic> _variation({
  String? selected,
  Object? cardsPerPlayer,
  bool withCardsPerPlayer = true,
}) => {
  'selecting': selected == null,
  'userId': 'u2',
  'displayName': 'Player 2',
  'seatIndex': 2,
  'startedAt': _now,
  'deadline': _now + 10000,
  'timeoutMs': 10000,
  'options': Variation.all,
  'selected': selected,
  'selectedBy': selected == null ? null : VariationSelectedBy.player,
  if (withCardsPerPlayer)
    'cardsPerPlayer':
        cardsPerPlayer ?? (selected == Variation.fiveCard ? 5 : 3),
};

/// A table of five with the viewer (u0) in seat 0.
RoomState _room({
  String category = 'variation',
  Object? variation,
  List<String> cards = const [],
  Map<String, dynamic>? hand,
  int cardCount = 3,
  String status = 'active',
}) => RoomState.fromJson({
  'roomId': 'r1',
  'code': 'ABCD2345',
  'category': category,
  'chipsHidden': category != 'seen',
  'state': 'betting',
  'handNo': 4,
  'dealerSeat': 4,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'startsAt': 0,
  'pot': 1000,
  'maxPot': 0,
  'stake': 200,
  'turn': {'seatIndex': 2, 'userId': 'u2', 'deadline': _now + 25000},
  'variation': ?variation,
  'you': {
    'seatIndex': 0,
    'chips': 200000,
    'status': status,
    'isBlind': cards.isEmpty,
    'blindMovesLeft': 4,
    'contributed': 200,
    'missedTurns': 0,
    'maxMissedTurns': 3,
    'cards': cards,
    'hand': ?hand,
  },
  'seats': [
    for (final (i, id) in _ids.indexed)
      {
        'seatIndex': i,
        'userId': id,
        'displayName': 'Player $i',
        'avatarUrl': null,
        'chips': 200000,
        'status': i == 0 ? status : 'active',
        'isBlind': i == 0 ? cards.isEmpty : true,
        'lastBet': 200,
        'lastAction': 'boot',
        'contributed': 200,
        'connected': true,
        'cardCount': cardCount,
      },
  ],
});

/// The five-card hand, looked at, with the server's best three named.
RoomState _fiveCardRoom() => _room(
  variation: _variation(selected: Variation.fiveCard),
  cards: _five,
  cardCount: 5,
  hand: {
    'handName': 'Pure Sequence',
    'wild': const <String>[],
    'playsAs': _five,
    'best': _best,
  },
);

GameState _newState(RoomState room) {
  // Play is never started here; the override only keeps the purchase plugin
  // from registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  state
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Player 0',
      'chips': 200000,
      'diamond': 2,
      'hammer': 20,
      'missile': 1,
    })
    ..room = room
    ..screen = Screen.table;
  return state;
}

Future<void> _pumpTable(
  WidgetTester tester,
  GameState state, {
  required Size screen,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(sound: false),
        builder: (context, child) => GlassBudget(child: child!),
        home: const TableScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  await _settle(tester);
}

/// Long enough for every card's entrance and every settle to have finished.
/// In steps, not one jump: a card's entrance starts from a timer, and an
/// animation started by a timer needs a frame after it to begin at all.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

/// Takes the table down and lets every timer it scheduled run out.
Future<void> _teardown(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

Finder get _ownHand =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == '_OwnHand');

Finder _inOwnHand(Type type) =>
    find.descendant(of: _ownHand, matching: find.byType(type));

/// Where each of the viewer's cards stands in its fan: its left edge and how
/// far it is raised off the fan's foot — left to right. (Not in the order the
/// cards are built: since the premium-card brief, 25 Sep 2026, the fan paints
/// from the outside in, its middle card last, on top — HandFan.paintOrder.)
List<({double left, double bottom})> _slots(WidgetTester tester) => [
  for (final p in tester.widgetList<AnimatedPositioned>(
    _inOwnHand(AnimatedPositioned),
  ))
    (left: p.left!, bottom: p.bottom!),
]..sort((a, b) => a.left.compareTo(b.left));

/// The widgets [finder] matches, left to right across the felt: the order the
/// viewer's fan HOLDS its cards in, which since 25 Sep 2026 is not the order
/// they are painted in (see [_slots]).
List<T> _leftToRight<T extends Widget>(WidgetTester tester, Finder finder) {
  final elements = finder.evaluate().toList()
    ..sort((a, b) => _centreX(a).compareTo(_centreX(b)));
  return [for (final e in elements) e.widget as T];
}

double _centreX(Element element) {
  final box = element.renderObject! as RenderBox;
  return box.localToGlobal(box.size.center(Offset.zero)).dx;
}

/// The codes of the viewer's cards, left to right.
List<String?> _ownCodes(WidgetTester tester) => _leftToRight<PlayingCard>(
  tester,
  _inOwnHand(PlayingCard),
).map((c) => c.code).toList();

/// The codes of the viewer's cards in the order they are painted, the card
/// on top last.
List<String?> _paintedCodes(WidgetTester tester) => tester
    .widgetList<PlayingCard>(_inOwnHand(PlayingCard))
    .map((c) => c.code)
    .toList();

void main() {
  setUpAll(() async {
    final inter = FontLoader('Inter');
    for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
    }
    await inter.load();
  });

  group('the snapshot', () {
    test('5-Card is the last of the menu, under the server\'s own name', () {
      expect(Variation.fiveCard, 'FIVE_CARD');
      expect(Variation.all.last, Variation.fiveCard);
      expect(Variation.all, hasLength(7));
      expect(Variation.usesTurnUp(Variation.fiveCard), isFalse);
    });

    test('says how many cards each player holds', () {
      expect(_room(variation: _variation()).variation!.cardsPerPlayer, 3);
      expect(
        _room(
          variation: _variation(selected: Variation.ak47),
        ).variation!.cardsPerPlayer,
        3,
      );
      expect(
        _room(
          variation: _variation(selected: Variation.fiveCard),
        ).variation!.cardsPerPlayer,
        5,
      );
    });

    test('from a server that does not say, every player holds three', () {
      final v = _room(
        variation: _variation(
          selected: Variation.muflis,
          withCardsPerPlayer: false,
        ),
      ).variation!;
      expect(v.cardsPerPlayer, 3);
    });

    test('a nonsense card count is held to what the felt can draw', () {
      for (final (raw, want) in <(Object, int)>[
        ('five', 3),
        (true, 3),
        ([5], 3),
        ({'n': 5}, 3),
        (0, 3),
        (-2, 3),
        (4, 4),
        (5.0, 5),
        (52, 5),
        (double.nan, 3),
        (double.infinity, 3),
      ]) {
        final v = _room(
          variation: _variation(
            selected: Variation.fiveCard,
            cardsPerPlayer: raw,
          ),
        ).variation!;
        expect(v.cardsPerPlayer, want, reason: '$raw');
      }
    });

    test('names the three of the viewer\'s five that count', () {
      final hand = _fiveCardRoom().you!.hand!;
      expect(hand.best, _best);
      expect(hand.handName, 'Pure Sequence');
      expect(hand.wild, isEmpty);
      // Nothing stood in for anything: no card of the five turns.
      for (final (i, code) in _five.indexed) {
        expect(hand.standInFor(code, i), isNull);
      }
    });

    test('with no best, or a broken one, singles nothing out', () {
      for (final raw in <Object?>[
        null,
        'As',
        7,
        true,
        {'a': 1},
      ]) {
        final hand = OwnHand.fromJson({'handName': 'Pair', 'best': raw});
        expect(hand.best, isEmpty, reason: '$raw');
      }
      final mixed = OwnHand.fromJson({
        'best': ['As', 7, null, '', 'K', 'Kd'],
      });
      expect(mixed.best, ['As', 'Kd'], reason: 'only usable codes are kept');
    });

    test('a reveal and a sideshow hand carry best only under 5-Card', () {
      final reveal = Reveal.fromJson({
        'userId': 'u1',
        'cards': _five,
        'handName': 'Pure Sequence',
        'won': true,
        'best': _best,
      });
      expect(reveal.cards, _five);
      expect(reveal.best, _best);
      expect(
        Reveal.fromJson({
          'userId': 'u1',
          'cards': ['Ah', '7d', '9c'],
        }).best,
        isEmpty,
      );
      expect(Reveal.fromJson({'userId': 'u1', 'best': 'As'}).best, isEmpty);

      final peek = SideshowHand.fromJson({
        'userId': 'u1',
        'cards': _five,
        'handName': 'Pure Sequence',
        'best': _best,
      });
      expect(peek.best, _best);
      expect(SideshowHand.fromJson({'userId': 'u1'}).best, isEmpty);
    });
  });

  group('the viewer\'s own hand', () {
    for (final (screen, scale) in [
      (const Size(640, 360), 1.25),
      (const Size(891, 411), 1.0),
    ]) {
      final name = '${screen.width.toInt()}x${screen.height.toInt()} x$scale';

      testWidgets('at $name five cards stand in the box three do, with the '
          'best three lifted', (tester) async {
        // Three cards first, for the box to hold the five to.
        final three = _newState(
          _room(
            variation: _variation(selected: Variation.muflis),
            cards: const ['As', 'Ks', 'Qs'],
            hand: {
              'handName': 'Pure Sequence',
              'wild': const <String>[],
              'playsAs': const ['As', 'Ks', 'Qs'],
              'best': const ['As', 'Ks', 'Qs'],
            },
          ),
        );
        await _pumpTable(tester, three, screen: screen, textScale: scale);
        expect(tester.takeException(), isNull);
        final threeBox = tester.getRect(_ownHand);
        final threeSlots = _slots(tester);
        expect(threeSlots, hasLength(3));
        await _teardown(tester, three);

        final state = _newState(_fiveCardRoom());
        await _pumpTable(tester, state, screen: screen, textScale: scale);
        expect(tester.takeException(), isNull);

        expect(_inOwnHand(PlayingCard), findsNWidgets(5));
        // Built already knowing the best three, the fan opens re-dealt: the
        // two that do not count underneath on the left, the three that do on
        // top on the right, each group in the order held — and, since the
        // premium-card brief (25 Sep 2026), the middle of those three painted
        // last, on top, as the middle card of any hand is.
        expect(_ownCodes(tester), ['7d', '7c', 'As', 'Ks', 'Qs']);
        expect(_paintedCodes(tester), ['7d', '7c', 'As', 'Qs', 'Ks']);
        expect(
          tester.getRect(_ownHand),
          rectMoreOrLessEquals(threeBox, epsilon: 0.01),
          reason: 'a five-card hand must not take more of the felt',
        );

        // The outer two cards stand at the two ends of the box's run, which a
        // three-card hand is fanned tighter inside, centred (HandFan, 25 Sep
        // 2026 — until then three cards stood as far apart as five did).
        final slots = _slots(tester);
        expect(slots, hasLength(5));
        final cardH = tester.getSize(_inOwnHand(PlayingCard).first).height;
        final cardW = cardH * PlayingCard.aspect;
        expect(slots.first.left, closeTo(HandFan.startFor(5, cardH), 0.001));
        expect(
          slots.last.left - slots.first.left,
          closeTo(HandFan.wideRun * cardW, 0.001),
        );
        final threeRun = threeSlots.last.left - threeSlots.first.left;
        expect(threeRun, closeTo(2 * HandFan.step * cardW, 0.001));
        expect(
          threeSlots.first.left - slots.first.left,
          closeTo((HandFan.wideRun * cardW - threeRun) / 2, 0.001),
          reason: 'three cards are centred in the box five fill',
        );
        // The two set aside are tucked close together; the three that count
        // share the rest of the run evenly, far enough apart that each one's
        // index AND most of its middle pip are clear of the card laid over it.
        expect(slots[1].left - slots[0].left, closeTo(cardW * 0.24, 0.001));
        expect(slots[2].left - slots[1].left, closeTo(cardW * 0.24, 0.001));
        final wide = slots[3].left - slots[2].left;
        expect(slots[4].left - slots[3].left, closeTo(wide, 0.001));
        expect(wide, closeTo((HandFan.wideRun - 2 * 0.24) / 2 * cardW, 0.001));
        expect(wide, greaterThan(CardFaceMetrics.of(cardH).index().right));

        // The best three are lifted; the other two are left down, set back.
        expect(slots.map((s) => s.bottom > 0), [
          false,
          false,
          true,
          true,
          true,
        ]);
        expect(slots.take(2).map((s) => s.bottom), everyElement(0));
        expect(
          _leftToRight<SetBack>(
            tester,
            _inOwnHand(SetBack),
          ).map((w) => w.setBack),
          [true, true, false, false, false],
        );
        // And the hand is named, as any variation hand is.
        expect(find.text('Pure Sequence'), findsOneWidget);
        expect(find.text('VARIATION · 5-Card'), findsOneWidget);

        await _teardown(tester, state);
      });
    }

    testWidgets('face down it draws as many backs as the server says, and the '
        'top-up arrives without the hand growing', (tester) async {
      // The window is open: three dealt, nobody has five yet.
      final state = _newState(_room(variation: _variation()));
      await _pumpTable(
        tester,
        state,
        screen: const Size(640, 360),
        textScale: 1.25,
      );
      expect(_inOwnHand(PlayingCard), findsNWidgets(3));
      final box = tester.getRect(_ownHand);
      expect(find.text(state.t.seeCards), findsOneWidget);

      // 5-Card is chosen: every hand in play is topped up to five.
      state.handleState(
        _room(
          variation: _variation(selected: Variation.fiveCard),
          cardCount: 5,
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(_inOwnHand(PlayingCard), findsNWidgets(5));
      // The two new cards are on their way in, not simply there. Read by the
      // index each card was dealt at (its entrance's key), not in the order
      // the fan paints them (outside in, since 25 Sep 2026).
      final arriving = [
        for (var i = 0; i < 5; i++)
          tester
              .widget<FadeTransition>(
                find
                    .descendant(
                      of: find.byKey(ValueKey('4-$i')),
                      matching: find.byType(FadeTransition),
                    )
                    .first,
              )
              .opacity
              .value,
      ];
      expect(arriving.sublist(0, 3), everyElement(1.0));
      expect(arriving.sublist(3), everyElement(lessThan(1.0)));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(_ownHand),
        rectMoreOrLessEquals(box, epsilon: 0.01),
      );
      expect(
        tester
            .widgetList<PlayingCard>(_inOwnHand(PlayingCard))
            .map((c) => c.code),
        everyElement(isNull),
        reason: 'still face down: the player has not looked',
      );
      // Looking still works, and nothing is singled out before it.
      expect(find.text(state.t.seeCards), findsOneWidget);
      expect(
        tester.widgetList<SetBack>(_inOwnHand(SetBack)).any((w) => w.setBack),
        isFalse,
      );

      // They look: five faces, and the server's best three.
      state.handleState(_fiveCardRoom());
      await tester.pump();
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text(state.t.seeCards), findsNothing);
      expect(
        tester
            .widgetList<PlayingCard>(_inOwnHand(PlayingCard))
            .map((c) => c.code),
        unorderedEquals(_five),
      );
      expect(
        tester.getRect(_ownHand),
        rectMoreOrLessEquals(box, epsilon: 0.01),
      );

      await _teardown(tester, state);
    });

    // The server drops the variation block the moment a hand ends, while the
    // cards stay on the felt until the next deal. A player who never looked —
    // winning because everyone else packed, or waiting out a hand they folded
    // — has no cards and no reveal to count, so their own fan fell from five
    // backs to three beside four seats still showing five.
    for (final status in ['won', 'packed']) {
      testWidgets('a blind player who $status keeps five backs once the hand is '
          'over and the variation block has gone', (tester) async {
        final state = _newState(
          _room(
            variation: _variation(selected: Variation.fiveCard),
            cardCount: 5,
          ),
        );
        await _pumpTable(
          tester,
          state,
          screen: const Size(640, 360),
          textScale: 1.25,
        );
        expect(_inOwnHand(PlayingCard), findsNWidgets(5));

        // The hand ends: same seats, same five cards each, no variation block.
        state.handleState(_room(cardCount: 5, status: status));
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.takeException(), isNull);
        expect(state.variation, isNull);
        expect(
          _inOwnHand(PlayingCard),
          findsNWidgets(5),
          reason: 'the seat still holds five; the fan says so',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      });
    }

    testWidgets('a player already looking sees three become five', (
      tester,
    ) async {
      final state = _newState(
        _room(variation: _variation(), cards: const ['As', '7d', 'Ks']),
      );
      await _pumpTable(tester, state, screen: const Size(891, 411));
      expect(_inOwnHand(PlayingCard), findsNWidgets(3));
      final box = tester.getRect(_ownHand);

      // The same snapshot that says FIVE_CARD carries all five and the best.
      state.handleState(
        _room(
          variation: _variation(selected: Variation.fiveCard),
          cards: const ['As', '7d', 'Ks', 'Qs', '7c'],
          cardCount: 5,
          hand: {
            'handName': 'Pure Sequence',
            'wild': const <String>[],
            'playsAs': const ['As', '7d', 'Ks', 'Qs', '7c'],
            'best': const ['As', 'Ks', 'Qs'],
          },
        ),
      );
      await tester.pump();
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(_ownHand),
        rectMoreOrLessEquals(box, epsilon: 0.01),
      );
      // The best three are whichever the server named, wherever they were
      // held: once the fan has been re-dealt they are the three on top.
      expect(_ownCodes(tester), ['7d', '7c', 'As', 'Ks', 'Qs']);
      expect(_paintedCodes(tester).skip(2), unorderedEquals(_best));
      expect(_slots(tester).map((s) => s.bottom > 0), [
        false,
        false,
        true,
        true,
        true,
      ]);

      await _teardown(tester, state);
    });

    // Owner, 18 Sep 2026: "show an animation that the two cards are low and
    // then rearrange the cards that bring the selected cards at top".
    testWidgets('tapping See cards acts the choice out: the faces turn in the '
        'order held, the two that do not count go low, then the best three '
        'come to the top', (tester) async {
      const held = ['As', '7d', 'Ks', '7c', 'Qs'];
      final state = _newState(
        _room(
          variation: _variation(selected: Variation.fiveCard),
          cardCount: 5,
        ),
      );
      await _pumpTable(
        tester,
        state,
        screen: const Size(640, 360),
        textScale: 1.25,
      );
      await _settle(tester);
      final box = tester.getRect(_ownHand);
      final rest = _slots(tester);

      // Left to right, as the fan holds them (it paints its middle card last).
      List<String?> codes() => _ownCodes(tester);
      List<bool> setBack() => _leftToRight<SetBack>(
        tester,
        _inOwnHand(SetBack),
      ).map((w) => w.setBack).toList();

      // They look.
      state.handleState(
        _room(
          variation: _variation(selected: Variation.fiveCard),
          cards: held,
          cardCount: 5,
          hand: {
            'handName': 'Pure Sequence',
            'wild': const <String>[],
            'playsAs': held,
            'best': _best,
          },
        ),
      );
      await tester.pump();

      // 1. The faces turn over where they lie; nothing is singled out yet.
      await tester.pump(const Duration(milliseconds: 300));
      expect(codes(), held);
      expect(setBack(), everyElement(isFalse));
      expect(_slots(tester), rest);

      // 2. The two that do not count go low and are set back; nobody has
      //    moved along the fan and nothing has risen.
      await tester.pump(const Duration(milliseconds: 500));
      expect(codes(), held);
      expect(setBack(), [false, true, false, true, false]);
      final low = _slots(tester);
      expect(low.map((s) => s.left), rest.map((s) => s.left));
      expect(low.map((s) => s.bottom < 0), [false, true, false, true, false]);
      expect(low.map((s) => s.bottom > 0), everyElement(isFalse));

      // 3. The fan is re-dealt: the three that count are on top, raised, in
      //    the order they were held; the other two are underneath, back on
      //    the cloth's line.
      await tester.pump(const Duration(milliseconds: 600));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(codes(), ['7d', '7c', 'As', 'Ks', 'Qs']);
      expect(setBack(), [true, true, false, false, false]);
      final dealt = _slots(tester);
      // Same first and last place; the three that count stand wider apart
      // than the five did, so their faces read.
      expect(dealt.first.left, rest.first.left);
      expect(dealt.last.left, closeTo(rest.last.left, 0.001));
      expect(
        dealt[3].left - dealt[2].left,
        greaterThan((rest[1].left - rest[0].left) * 1.3),
      );
      expect(dealt.map((s) => s.bottom > 0), [false, false, true, true, true]);
      expect(dealt.take(2).map((s) => s.bottom), everyElement(0));
      expect(
        tester.getRect(_ownHand),
        rectMoreOrLessEquals(box, epsilon: 0.01),
        reason: 'the hand never takes more of the felt',
      );

      // It plays once: another snapshot of the same hand moves nothing.
      state.handleState(
        _room(
          variation: _variation(selected: Variation.fiveCard),
          cards: held,
          cardCount: 5,
          hand: {
            'handName': 'Pure Sequence',
            'wild': const <String>[],
            'playsAs': held,
            'best': _best,
          },
        ),
      );
      await tester.pump();
      expect(codes(), ['7d', '7c', 'As', 'Ks', 'Qs']);
      expect(_slots(tester), dealt);

      await _teardown(tester, state);
    });
  });

  group('the other seats', () {
    testWidgets('hold five backs in the width of three, and show all five '
        'with the best three standing', (tester) async {
      // Three-card pods first, for their size.
      final three = _newState(
        _room(variation: _variation(selected: Variation.muflis)),
      );
      await _pumpTable(
        tester,
        three,
        screen: const Size(640, 360),
        textScale: 1.25,
      );
      Finder pod(String id) =>
          find.byWidgetPredicate((w) => w is SeatPod && w.seat?.userId == id);
      final threeSizes = {for (final id in _ids) id: tester.getSize(pod(id))};
      await _teardown(tester, three);

      final state = _newState(_fiveCardRoom());
      await _pumpTable(
        tester,
        state,
        screen: const Size(640, 360),
        textScale: 1.25,
      );
      expect(tester.takeException(), isNull);
      for (final id in _ids.skip(1)) {
        expect(
          find.descendant(of: pod(id), matching: find.byType(PlayingCard)),
          findsNWidgets(5),
          reason: id,
        );
        expect(tester.getSize(pod(id)), threeSizes[id], reason: id);
      }

      // The showdown: all five turned over at the seat, two of them set back.
      state.handleShowdown((
        reveals: [
          Reveal.fromJson({
            'userId': 'u3',
            'displayName': 'Player 3',
            'cards': ['2c', '9h', '9d', 'Jc', '9s'],
            'handName': 'Trail',
            'won': false,
            'best': ['9h', '9d', '9s'],
          }),
        ],
        result: '',
        winnerId: null,
        winnerName: '',
        pot: 0,
        nextHandAt: 0,
        reason: 'show',
      ));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widgetList<PlayingCard>(
              find.descendant(
                of: pod('u3'),
                matching: find.byType(PlayingCard),
              ),
            )
            .map((c) => c.code),
        ['2c', '9h', '9d', 'Jc', '9s'],
      );
      expect(
        tester
            .widgetList<SetBack>(
              find.descendant(of: pod('u3'), matching: find.byType(SetBack)),
            )
            .map((w) => w.setBack),
        [true, false, false, true, false],
      );
      expect(tester.getSize(pod('u3')), threeSizes['u3']);

      await _teardown(tester, state);
    });
  });

  group('a three-card table', () {
    for (final category in ['seen', 'blind']) {
      testWidgets('of the $category kind is laid out exactly as it was', (
        tester,
      ) async {
        final state = _newState(
          _room(category: category, cards: const ['As', 'Kd', '4c']),
        );
        await _pumpTable(tester, state, screen: const Size(891, 411));
        expect(tester.takeException(), isNull);

        expect(_inOwnHand(PlayingCard), findsNWidgets(3));
        final cardH = tester.getSize(_inOwnHand(PlayingCard).first).height;
        final cardW = cardH * PlayingCard.aspect;
        // The fan of the premium-card brief (25 Sep 2026; until then an 18%
        // overlap with the right-hand card on top, which read as three cards
        // rather than one hand): HandFan's — the cards 0.62 of a card apart,
        // centred in the box a five-card hand needs, the middle card raised
        // and painted last, on top. Nothing else on the table moves for it.
        final start = HandFan.startFor(3, cardH);
        final slots = _slots(tester);
        final lefts = [
          start,
          start + cardW * HandFan.step,
          start + 2 * cardW * HandFan.step,
        ];
        for (var i = 0; i < 3; i++) {
          expect(slots[i].left, closeTo(lefts[i], 0.001));
        }
        expect(slots.map((s) => s.bottom), [0, cardH * HandFan.proud, 0]);
        expect(
          tester.getSize(_ownHand),
          Size(HandFan.widthFor(cardH), HandFan.heightFor(cardH)),
        );
        expect(_ownCodes(tester), ['As', 'Kd', '4c']);
        expect(_paintedCodes(tester), ['As', '4c', 'Kd']);
        // Nothing is set back anywhere, and every other seat holds three.
        expect(
          tester
              .widgetList<SetBack>(find.byType(SetBack))
              .any((w) => w.setBack),
          isFalse,
        );
        for (final id in _ids.skip(1)) {
          final cards = find.descendant(
            of: find.byWidgetPredicate(
              (w) => w is SeatPod && w.seat?.userId == id,
            ),
            matching: find.byType(PlayingCard),
          );
          expect(cards, findsNWidgets(3), reason: id);
          expect(
            find.descendant(
              of: find.byWidgetPredicate(
                (w) => w is SeatPod && w.seat?.userId == id,
              ),
              matching: find.byType(SetBack),
            ),
            findsNothing,
            reason: 'a row of three is drawn as it always was',
          );
        }

        await _teardown(tester, state);
      });
    }
  });
}
