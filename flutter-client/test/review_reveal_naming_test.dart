// Review (24 Sep 2026): how the table NAMES a revealed hand, and where the
// name comes from.
//
// The owner reported that on a variation table "a player has a pair, it is
// showing Trail and he is winning". Under every variation but Muflis and
// 5-Card some cards are WILD, and the server scores a hand as the best classic
// hand its natural cards plus its wild ones can make (go-server
// internal/game/variation.go), so K-K-7 under AK47 IS a Trail — the 7 is wild
// and stands for a king — and the reveal says so twice: `handName: "Trail"`
// and `wild: ["7c"]`. This file establishes what the app does with that:
//
//   1. a rim seat's reveal shows the hand name the wire carries and edges the
//      wild card in gold — and the same three cards under Muflis, with no wild
//      card, show "Pair" with no edge;
//   2. the viewer's own hand turns only the wild card into its stand-in and
//      ribbons only that card;
//   3. the winner's ribbon names what the reveal says;
//   4. a seen or blind table, whose reveals carry no `wild` key, names hands
//      from `handName` unchanged — even a name the bare cards would not make,
//      which is the proof that nothing here re-evaluates;
//   5. nothing in lib/ ranks cards: every hand name on screen is the wire's.
//
// Everything is measured on the 640x360 phone (TP_Small), the tightest screen
// the app ships on, and the wild edge's width there is printed so the UX
// judgement in the review can cite it.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/game_connection.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/playing_card.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/seat_pod.dart';
import 'package:teenpatti/widgets/variation_prompt.dart';
import 'package:teenpatti/widgets/wild_transform.dart';

const _ids = ['u0', 'u1', 'u2', 'u3', 'u4'];
const _phone = Size(640, 360);

int get _now => DateTime.now().millisecondsSinceEpoch;

/// The snapshot's variation block once the window has closed on [variation].
Map<String, dynamic> _selected(String variation) => {
  'selecting': false,
  'userId': 'u1',
  'displayName': 'Player 1',
  'seatIndex': 1,
  'startedAt': _now,
  'deadline': _now,
  'timeoutMs': 10000,
  'options': Variation.all,
  'selected': variation,
  'selectedBy': VariationSelectedBy.player,
};

/// A table of five with the viewer (u0) in seat 0.
///
/// [statuses] overrides a seat's status (`won`, `lost`, `packed`); [youCards]
/// and [youHand] are the viewer's own cards and `you.hand`, the block the
/// server sends this player alone once they have looked and the variation is
/// chosen; [variation] is the snapshot's block, absent on a seen or blind
/// table.
RoomState _room({
  String category = 'variation',
  Map<String, dynamic>? variation,
  String state = 'betting',
  Map<String, String> statuses = const {},
  List<String> youCards = const [],
  Map<String, dynamic>? youHand,
}) => RoomState.fromJson({
  'roomId': 'r1',
  'code': 'ABCD2345',
  'category': category,
  'chipsHidden': category != 'seen',
  'state': state,
  'handNo': 4,
  'dealerSeat': 4,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'startsAt': 0,
  'pot': 1000,
  'maxPot': category == 'seen' ? 2000000 : 0,
  'stake': 200,
  'turn': {'seatIndex': 1, 'userId': 'u1', 'deadline': _now + 25000},
  'variation': ?variation,
  'you': {
    'seatIndex': 0,
    'chips': 200000,
    'status': statuses['u0'] ?? 'active',
    'isBlind': youCards.isEmpty,
    'blindMovesLeft': 4,
    'contributed': 200,
    'missedTurns': 0,
    'maxMissedTurns': 3,
    'cards': youCards,
    'hand': ?youHand,
  },
  'seats': [
    for (final (i, id) in _ids.indexed)
      {
        'seatIndex': i,
        'userId': id,
        'displayName': 'Player $i',
        'avatarUrl': null,
        'chips': category == 'seen' ? 200000 : null,
        'status': statuses[id] ?? 'active',
        'isBlind': id != 'u0' || youCards.isEmpty,
        'lastBet': 200,
        'lastAction': 'chaal',
        'contributed': 600,
        'connected': true,
        'cardCount': 3,
      },
  ],
});

/// One `game:showdown` frame. A reveal with `wild: null` leaves the key out,
/// as a seen or blind table's server does.
ShowdownNews _showdown(
  List<({String id, List<String> cards, String name, List<String>? wild})>
  hands, {
  String? winnerId,
  // The hand as it was counted, by player, where the server sends it (24 Sep
  // 2026): a reveal with wild but no playsAs is an older server's.
  Map<String, List<String>> playsAs = const {},
}) => (
  reveals: [
    for (final h in hands)
      Reveal.fromJson({
        'userId': h.id,
        'displayName': 'Player ${h.id.substring(1)}',
        'cards': h.cards,
        'handName': h.name,
        'won': h.id == winnerId,
        'wild': ?h.wild,
        'playsAs': ?playsAs[h.id],
      }),
  ],
  result: '',
  winnerId: winnerId,
  winnerName: winnerId == null ? '' : 'Player ${winnerId.substring(1)}',
  pot: 1000,
  nextHandAt: 0,
  reason: 'show',
);

GameState _newState({RoomState? room}) {
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

Future<void> _loadInter() async {
  final inter = FontLoader('Inter');
  for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
  }
  await inter.load();
}

Future<void> _pumpTable(
  WidgetTester tester,
  GameState state, {
  Size screen = _phone,
  double textScale = 1.0,
  ThemeData? theme,
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
        theme: theme ?? AppTheme.dark(sound: false),
        builder: (context, child) => GlassBudget(child: child!),
        home: const TableScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

/// Runs the clock forward a frame at a time, so timers fire AND the animations
/// they start get frames.
Future<void> _run(WidgetTester tester, Duration total) async {
  const frame = Duration(milliseconds: 40);
  for (var t = Duration.zero; t < total; t += frame) {
    await tester.pump(frame);
  }
}

Future<void> _teardown(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

Finder _private(String type) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

Finder _pod(String userId) =>
    find.byWidgetPredicate((w) => w is SeatPod && w.seat?.userId == userId);

/// The [WildEdge]s of one seat's fan, in card order.
List<WildEdge> _edgesOf(WidgetTester tester, String userId) => tester
    .widgetList<WildEdge>(
      find.descendant(of: _pod(userId), matching: find.byType(WildEdge)),
    )
    .toList();

/// The foreground border a wild [WildEdge] paints, or null when it paints
/// nothing (the card is not wild).
BoxBorder? _edgeBorder(WidgetTester tester, Finder edge) {
  final boxes = tester.widgetList<DecoratedBox>(
    find.descendant(
      of: edge,
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.position == DecorationPosition.foreground &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).border != null,
      ),
    ),
  );
  // The WildEdge's own box is the first: PlayingCard's border is a
  // background decoration, not a foreground one.
  return boxes.isEmpty ? null : (boxes.first.decoration as BoxDecoration).border;
}

void main() {
  setUpAll(_loadInter);

  group('a rim seat at a showdown', () {
    testWidgets(
      'under AK47 shows the Trail the wire named and edges the wild 7 in gold',
      (tester) async {
        final state = _newState(
          room: _room(variation: _selected(Variation.ak47), state: 'showdown'),
        );
        await _pumpTable(tester, state);
        state.handleShowdown(
          _showdown([
            (id: 'u2', cards: ['Ks', 'Kd', '7c'], name: 'Trail', wild: ['7c']),
            (id: 'u3', cards: ['Ah', '9d', '4c'], name: 'High Card', wild: []),
          ], playsAs: {'u2': ['Ks', 'Kd', 'Kc']}),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);

        // The name is the wire's, on the seat that played it.
        expect(
          find.descendant(of: _pod('u2'), matching: find.text('Trail')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: _pod('u3'), matching: find.text('High Card')),
          findsOneWidget,
        );
        expect(find.text('Pair'), findsNothing, reason: 'nothing re-ranked K-K');

        // The faces are the hand as it was COUNTED (owner, 24 Sep 2026: "on
        // show or sideshow, show updated cards not the base cards"): the
        // wild 7 shows as the king it stood for, still marked as the joker.
        expect(
          tester
              .widgetList<PlayingCard>(
                find.descendant(
                  of: _pod('u2'),
                  matching: find.byType(PlayingCard),
                ),
              )
              .map((c) => c.code),
          ['Ks', 'Kd', 'Kc'],
        );

        // Exactly the 7 is edged, in a gold that reads on the face (24 Sep
        // 2026: the champagne edge alone was missed), with a star at its head.
        final edges = _edgesOf(tester, 'u2');
        expect(edges.map((e) => e.wild), [false, false, true]);
        expect(_edgesOf(tester, 'u3').map((e) => e.wild), everyElement(false));
        final wildEdge = find.byWidgetPredicate(
          (w) => w is WildEdge && w.wild && w.child is PlayingCard,
        );
        expect(wildEdge, findsOneWidget);
        final border = _edgeBorder(tester, wildEdge);
        expect(border, isNotNull, reason: 'the wild card paints no edge');
        expect(border!.top.color, AppTheme.gold, reason: 'dark theme: the deep-champagne gold, not the pale one');
        expect(
          find.descendant(
            of: wildEdge,
            matching: find.byWidgetPredicate(
              (w) => w is Icon && w.icon == Icons.auto_awesome_rounded,
            ),
          ),
          findsOneWidget,
          reason: 'the wild card carries a star at its head',
        );
        // A screen reader is told the card is wild.
        expect(
          find.descendant(
            of: wildEdge,
            matching: find.byWidgetPredicate(
              (w) => w is Semantics && w.properties.label == state.t.wildCard,
            ),
          ),
          findsOneWidget,
        );

        // What the edge measures on the 640x360 phone, for the review.
        final cardH = edges.last.cardHeight;
        final cardW = cardH * PlayingCard.aspect;
        final width = math.max(2.0, cardH * 0.06);
        expect(border.top.width, closeTo(width, 0.001));
        // ignore: avoid_print
        print(
          'review: 640x360 rim card ${cardW.toStringAsFixed(1)}x'
          '${cardH.toStringAsFixed(1)}dp, wild edge ${width.toStringAsFixed(2)}dp '
          '${AppTheme.gold} on face ${AppTheme.cardFace} '
          '(the card\'s own rim ${AppTheme.cardRim})',
        );
        await _teardown(tester, state);
      },
    );

    testWidgets('from a server that sends wild but no playsAs, the faces are '
        'the cards as dealt, still edged', (tester) async {
      final state = _newState(
        room: _room(variation: _selected(Variation.ak47), state: 'showdown'),
      );
      await _pumpTable(tester, state);
      state.handleShowdown(
        _showdown([
          (id: 'u2', cards: ['Ks', 'Kd', '7c'], name: 'Trail', wild: ['7c']),
          (id: 'u3', cards: ['Ah', '9d', '4c'], name: 'High Card', wild: []),
        ]),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widgetList<PlayingCard>(
              find.descendant(of: _pod('u2'), matching: find.byType(PlayingCard)),
            )
            .map((c) => c.code),
        ['Ks', 'Kd', '7c'],
      );
      expect(_edgesOf(tester, 'u2').map((e) => e.wild), [false, false, true]);
      await _teardown(tester, state);
    });

    testWidgets('under Muflis the same cards are the Pair the wire names, '
        'with no edge', (tester) async {
      final state = _newState(
        room: _room(variation: _selected(Variation.muflis), state: 'showdown'),
      );
      await _pumpTable(tester, state);
      state.handleShowdown(
        _showdown([
          (id: 'u2', cards: ['Ks', 'Kd', '7c'], name: 'Pair', wild: []),
          (id: 'u3', cards: ['Ah', '9d', '4c'], name: 'High Card', wild: []),
        ]),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(of: _pod('u2'), matching: find.text('Pair')),
        findsOneWidget,
      );
      expect(find.text('Trail'), findsNothing);
      expect(_edgesOf(tester, 'u2').map((e) => e.wild), everyElement(false));
      expect(
        find.byWidgetPredicate((w) => w is WildEdge && w.wild),
        findsNothing,
      );
      await _teardown(tester, state);
    });

    testWidgets('at 640x360 with text at 1.25 the named, edged fan overflows '
        'nothing', (tester) async {
      final state = _newState(
        room: _room(variation: _selected(Variation.ak47), state: 'showdown'),
      );
      await _pumpTable(tester, state, textScale: 1.25);
      state.handleShowdown(
        _showdown([
          (id: 'u1', cards: ['Ks', 'Kd', '7c'], name: 'Trail', wild: ['7c']),
          (id: 'u2', cards: ['Qs', 'Qd', '7h'], name: 'Trail', wild: ['7h']),
          (id: 'u3', cards: ['4h', '4d', '4c'], name: 'Trail', wild: ['4h', '4d', '4c']),
          (id: 'u4', cards: ['Ah', 'Kh', 'Jh'], name: 'Pure Sequence', wild: ['Ah', 'Kh']),
        ]),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(find.text('Trail'), findsNWidgets(3));
      expect(find.text('Pure Sequence'), findsOneWidget);
      expect(_edgesOf(tester, 'u3').map((e) => e.wild), [true, true, true]);
      expect(_edgesOf(tester, 'u4').map((e) => e.wild), [true, true, false]);
      await _teardown(tester, state);
    });
  });

  group("the viewer's own hand", () {
    testWidgets('turns only the wild card into its stand-in, ribbons only it, '
        'and names the hand the server named', (tester) async {
      // Looked, and the variation is chosen: `you.hand` says the 7 is wild and
      // stood for the king of clubs.
      final state = _newState(
        room: _room(
          variation: _selected(Variation.ak47),
          youCards: ['Ks', 'Kd', '7c'],
          youHand: {
            'handName': 'Trail',
            'category': 5,
            'wild': ['7c'],
            'playsAs': ['Ks', 'Kd', 'Kc'],
            'best': ['Ks', 'Kd', '7c'],
          },
        ),
      );
      await _pumpTable(tester, state);
      // The deal's entrance, the turn (1.15 s, staggered along the fan) and
      // the name that follows it.
      await _run(tester, const Duration(seconds: 5));
      expect(tester.takeException(), isNull);

      final cards = tester
          .widgetList<WildTransform>(find.byType(WildTransform))
          .toList();
      expect(cards.map((c) => c.code), ['Ks', 'Kd', '7c']);
      expect(cards.map((c) => c.wild), [false, false, true]);
      expect(cards.map((c) => c.standIn), [null, null, 'Kc']);

      // The 7 now shows the king it played as, with the WILD ribbon and the
      // real card on its tab; the two kings are untouched.
      final faces = tester
          .widgetList<PlayingCard>(
            find.descendant(
              of: find.byType(WildTransform),
              matching: find.byType(PlayingCard),
            ),
          )
          .map((c) => c.code)
          .toList();
      expect(faces, ['Ks', 'Kd', 'Kc']);
      expect(find.text('WILD'), findsOneWidget);
      // The tab names the card really held — its rank in type, its suit a
      // painted pip (24 Sep 2026), never a bare '♣' from a fallback font.
      final tab = find.byKey(const ValueKey('wild-real-card:7c'));
      expect(tab, findsOneWidget, reason: 'the card really held');
      expect(find.descendant(of: tab, matching: find.text('7')), findsOneWidget);
      expect(
        tester
            .widget<CardPips>(
              find.descendant(of: tab, matching: find.byType(CardPips)),
            )
            .suit,
        'c',
      );
      expect(
        find.byKey(const ValueKey('wild-real-card:Ks')),
        findsNothing,
        reason: 'a natural card has no tab',
      );

      // Named from `you.hand.handName`, over the viewer's own cards.
      expect(
        find.descendant(
          of: _private('_OwnHandName'),
          matching: find.text('Trail'),
        ),
        findsOneWidget,
      );
      expect(find.text('Pair'), findsNothing);
      await _teardown(tester, state);
    });

    testWidgets('with nothing wild turns nothing and ribbons nothing', (
      tester,
    ) async {
      final state = _newState(
        room: _room(
          variation: _selected(Variation.muflis),
          youCards: ['Ks', 'Kd', '7c'],
          youHand: {
            'handName': 'Pair',
            'category': 1,
            'wild': const <String>[],
            'playsAs': const <String>[],
            'best': ['Ks', 'Kd', '7c'],
          },
        ),
      );
      await _pumpTable(tester, state);
      await _run(tester, const Duration(seconds: 4));
      expect(tester.takeException(), isNull);
      final cards = tester
          .widgetList<WildTransform>(find.byType(WildTransform))
          .toList();
      expect(cards.map((c) => c.wild), [false, false, false]);
      expect(cards.map((c) => c.standIn), [null, null, null]);
      expect(find.text('WILD'), findsNothing);
      expect(
        find.descendant(
          of: _private('_OwnHandName'),
          matching: find.text('Pair'),
        ),
        findsOneWidget,
      );
      await _teardown(tester, state);
    });

    testWidgets('at the showdown the reveal edges the wild card even for a '
        'player who never looked', (tester) async {
      // Blind to the end: `you.cards` is empty, and the showdown's own copy
      // of the hand is what gets drawn.
      final state = _newState(
        room: _room(variation: _selected(Variation.ak47), state: 'showdown'),
      );
      await _pumpTable(tester, state);
      state.handleShowdown(
        _showdown([
          (id: 'u0', cards: ['Ks', 'Kd', '7c'], name: 'Trail', wild: ['7c']),
          (id: 'u1', cards: ['Ah', '9d', '4c'], name: 'High Card', wild: []),
        ], winnerId: 'u1'),
      );
      await _run(tester, const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
      final cards = tester
          .widgetList<WildTransform>(find.byType(WildTransform))
          .toList();
      expect(cards.map((c) => c.code), ['Ks', 'Kd', '7c']);
      expect(cards.map((c) => c.wild), [false, false, true]);
      // Nothing turns: a showdown reveal names the wild card but not what it
      // stood for, so the real 7 stays on the felt with the gold edge.
      expect(cards.map((c) => c.standIn), [null, null, null]);
      expect(find.text('WILD'), findsNothing);
      expect(
        find.descendant(
          of: _private('_OwnHandName'),
          matching: find.text('Trail'),
        ),
        findsOneWidget,
      );
      await _teardown(tester, state);
    });
  });

  group("the winner's ribbon", () {
    testWidgets('names what the reveal says, once, on the winning seat', (
      tester,
    ) async {
      final state = _newState(
        room: _room(
          variation: _selected(Variation.ak47),
          state: 'showdown',
          statuses: const {'u2': 'won', 'u3': 'lost', 'u0': 'lost'},
        ),
      );
      await _pumpTable(tester, state);
      state.handleShowdown(
        _showdown([
          (id: 'u2', cards: ['Ks', 'Kd', '7c'], name: 'Trail', wild: ['7c']),
          (id: 'u3', cards: ['Ah', 'Kh', 'Qh'], name: 'Pure Sequence', wild: []),
          (id: 'u0', cards: ['2s', '3d', '5c'], name: 'High Card', wild: []),
        ], winnerId: 'u2'),
      );
      await _run(tester, const Duration(milliseconds: 800));
      expect(tester.takeException(), isNull);
      expect(state.winnerId, 'u2');

      final flash = find.descendant(
        of: _pod('u2'),
        matching: _private('_WinnerFlash'),
      );
      expect(flash, findsOneWidget);
      // The ribbon's hand is the reveal's handName, untouched.
      expect((tester.widget(flash) as dynamic).hand, 'Trail');
      expect(find.text('WINNER'), findsOneWidget);
      expect(
        find.descendant(of: flash, matching: find.text('Trail')),
        findsOneWidget,
      );
      // Once on the seat: the fan's capsule is suppressed on the winner so
      // the same word is not written twice.
      expect(
        find.descendant(of: _pod('u2'), matching: find.text('Trail')),
        findsOneWidget,
      );
      // The beaten seat is still named from its own reveal.
      expect(
        find.descendant(of: _pod('u3'), matching: find.text('Pure Sequence')),
        findsOneWidget,
      );
      expect(_private('_WinnerFlash'), findsOneWidget);
      await _teardown(tester, state);
    });

    testWidgets('carries no hand when the reveal carried none (everyone else '
        'packed)', (tester) async {
      final state = _newState(
        room: _room(
          variation: _selected(Variation.ak47),
          state: 'showdown',
          statuses: const {'u2': 'won', 'u0': 'packed', 'u1': 'packed',
            'u3': 'packed', 'u4': 'packed'},
        ),
      );
      await _pumpTable(tester, state);
      state.handleShowdown((
        reveals: const [],
        result: 'Player 2 won 1,000',
        winnerId: 'u2',
        winnerName: 'Player 2',
        pot: 1000,
        nextHandAt: 0,
        reason: 'all_packed',
      ));
      await _run(tester, const Duration(milliseconds: 800));
      expect(tester.takeException(), isNull);
      final flash = _private('_WinnerFlash');
      expect(flash, findsOneWidget);
      expect((tester.widget(flash) as dynamic).hand, isNull);
      expect(find.text('Trail'), findsNothing);
      await _teardown(tester, state);
    });
  });

  group('a seen or blind table', () {
    for (final category in ['seen', 'blind']) {
      testWidgets('($category) names every hand from handName, and edges '
          'nothing', (tester) async {
        final state = _newState(
          room: _room(
            category: category,
            state: 'showdown',
            statuses: const {'u1': 'won', 'u2': 'lost', 'u3': 'lost'},
          ),
        );
        await _pumpTable(tester, state);
        // No `wild` key on any reveal, as the server sends them there.
        state.handleShowdown(
          _showdown([
            (id: 'u1', cards: ['Ks', 'Kd', '7c'], name: 'Pair', wild: null),
            (id: 'u2', cards: ['Ah', '9d', '4c'], name: 'High Card', wild: null),
            // A name the bare cards would NOT make: the app must show it as
            // sent. If anything re-ranked A-A-A it would say Trail here.
            (id: 'u3', cards: ['As', 'Ad', 'Ac'], name: 'Colour', wild: null),
          ], winnerId: 'u1'),
        );
        await _run(tester, const Duration(milliseconds: 800));
        expect(tester.takeException(), isNull);
        expect(state.room?.variation, isNull);

        expect(
          find.descendant(of: _pod('u1'), matching: find.text('Pair')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: _pod('u2'), matching: find.text('High Card')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: _pod('u3'), matching: find.text('Colour')),
          findsOneWidget,
        );
        expect(find.text('Trail'), findsNothing);
        expect(
          find.byWidgetPredicate((w) => w is WildEdge && w.wild),
          findsNothing,
        );
        expect(
          tester.widgetList<WildTransform>(find.byType(WildTransform)).any(
            (c) => c.wild || c.standIn != null,
          ),
          isFalse,
        );
        expect(find.text('WILD'), findsNothing);
        await _teardown(tester, state);
      });
    }
  });

  group('a sideshow', () {
    testWidgets('names only the hand that won it, from the wire, with its wild '
        'card edged', (tester) async {
      final state = _newState(
        room: _room(variation: _selected(Variation.ak47)),
      );
      await _pumpTable(tester, state);
      // u1 asked u2; u1's K-K-7 (the 7 wild) beat u2's pair of nines.
      state.handleSideshowReveal(
        SideshowReveal.fromJson({
          'hands': [
            {
              'userId': 'u1',
              'displayName': 'Player 1',
              'cards': ['Ks', 'Kd', '7c'],
              'handName': 'Trail',
              'wild': ['7c'],
            },
            {
              'userId': 'u2',
              'displayName': 'Player 2',
              'cards': ['9s', '9d', '3c'],
              'handName': 'Pair',
              'wild': const <String>[],
            },
          ],
          'packedUserId': 'u2',
        }),
      );
      // The viewer is neither player: the server sends `game:sideshowReveal`
      // to the two of them alone, but the felt's rule for whom to name is
      // the same on their two screens, and this is that rule.
      await _run(tester, const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(of: _pod('u1'), matching: find.text('Trail')),
        findsOneWidget,
      );
      expect(find.text('Pair'), findsNothing, reason: 'the loser is not named');
      expect(_edgesOf(tester, 'u1').map((e) => e.wild), [false, false, true]);
      expect(_edgesOf(tester, 'u2').map((e) => e.wild), [false, false, false]);
      await _teardown(tester, state);
    });
  });

  group('the source', () {
    test('ranks no cards: every hand name on screen comes from the wire', () {
      // The app draws `handName` from Reveal, SideshowHand, OwnHand and the
      // poker DTOs, and nowhere works a hand's worth out from its cards. A
      // ranking that crept in would be the one way the app could disagree
      // with the server about a Trail.
      final files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      expect(files, isNotEmpty, reason: 'run from the package root');
      final ranking = RegExp(
        r'\b(evaluate(Hand|Cards|3|5)?|handRank|rankHand|scoreHand|'
        r'compareHands|pickWinner|isTrail|isSequence|isPureSequence|isColou?r)\b',
      );
      final offenders = <String>[];
      for (final f in files) {
        final src = f.readAsStringSync();
        if (ranking.hasMatch(src)) offenders.add(f.path);
        if (src.contains('bot-play') || src.contains('handrank')) {
          offenders.add('${f.path} (references the bot fleet\'s evaluator)');
        }
      }
      expect(offenders, isEmpty);
      // The names the reveal DTOs carry are strings read as sent.
      final dtos = File('lib/models/dtos.dart').readAsStringSync();
      expect(dtos, contains("handName: _str(j['handName'])"));
      expect(dtos, isNot(contains('CATEGORY_NAMES')));
    });
  });
}
