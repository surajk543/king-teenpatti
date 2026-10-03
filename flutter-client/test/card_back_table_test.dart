// Card backs at the table (owner, 3 Oct 2026: "Add a table cards_background
// which users can buy just like user can buy profile_pictures … add one more
// tab Cards in Store which user can buy"; decided with the owner: everybody
// at the table sees each player's back on that player's face-down cards, the
// viewer's own hand shows the viewer's, and the bundled Royal Fox stays
// everybody's default).
//
// Held here: every rim seat's face-down cards wear that seat's back and the
// viewer's hand the viewer's seat's, a seat in none the Royal Fox; a back
// chosen mid-hand reaches the viewer's cards with the snapshot that puts it on
// their seat; the SEEN green lies over a bought back as over any; the poker
// felt keeps the Royal Fox; and the deal flies each card in the back of the
// seat it is dealt to — each back rendered once, the Royal Fox standing in
// for one still coming — repainting nothing for it but the deal's own layer.
//
// Decoding is real work a widget test's fake clock never finishes, so the
// backs are primed first (card_background_fixtures.dart): each a miniature,
// the card in a colour of its own, so a pixel says which back is drawn.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/card_back_art.dart';
import 'package:teenpatti/widgets/casino_table.dart';
import 'package:teenpatti/widgets/deal_flight.dart';
import 'package:teenpatti/widgets/playing_card.dart';
import 'package:teenpatti/widgets/seat_pod.dart';

import 'card_background_fixtures.dart';
import 'table_scenes.dart';

/// Pixels read back from a picture.
class _Pixels {
  _Pixels(this.width, this.height, this.data);

  final int width;
  final int height;
  final ByteData data;

  Color at(num x, num y) {
    final i = (y.floor() * width + x.floor()) * 4;
    return Color.fromARGB(
      data.getUint8(i + 3),
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
    );
  }

  Color atPoint(Offset p) => at(p.dx, p.dy);
}

/// What [key]'s repaint boundary paints, read back at one pixel a point.
Future<_Pixels> _grab(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData();
    final pixels = _Pixels(image.width, image.height, data!);
    image.dispose();
    return pixels;
  }))!;
}

/// Whether a colour is [expected] to within a few levels a channel, opaque.
Matcher _colour(Color expected, {double within = 0.06}) => predicate<Color>(
  (actual) =>
      (actual.r - expected.r).abs() <= within &&
      (actual.g - expected.g).abs() <= within &&
      (actual.b - expected.b).abs() <= within &&
      actual.a > 0.98,
  'the colour $expected',
);

/// Whether a colour has the SEEN green's hue: a back looked at.
final Matcher _seenGreen = predicate<Color>(
  (actual) =>
      (HSLColor.fromColor(actual).hue -
                  HSLColor.fromColor(AppTheme.cardSeenBack).hue)
              .abs() <=
          12 &&
      HSLColor.fromColor(actual).saturation > 0.15,
  'the SEEN green',
);

final _tiger = seededCard('Royal Tiger');
final _demon = seededCard('Brutal Demon');
final _lion = seededCard('Royal Lion');
final _owl = seededCard('Royal Owl with Fox');

/// The backs the table's scene dresses its seats in ([cardBacksWorn]).
List<SeededCard> get _worn => [
  for (final name in cardBacksWorn.values) seededCard(name),
];

/// The colour the Royal Fox is painted in where a test needs to see it drawn
/// by the deal: none of the seeded backs' colours.
const _fox = Color(0xFFFF00FF);

/// Makes the Royal Fox, as the deal draws it ([CardBackImages.peek] of null),
/// a card all in [colour].
Future<void> _foxIn(WidgetTester tester, Color colour) async {
  await tester.runAsync(() async {
    final png = await cardPicturePng(null, card: colour, size: 70);
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    codec.dispose();
    CardBackImages.debugPut(null, frame.image);
  });
}

Finder _pod(String userId) =>
    find.byWidgetPredicate((w) => w is SeatPod && w.seat?.userId == userId);

final Finder _ownHand = find.byWidgetPredicate(
  (w) => w.runtimeType.toString() == '_OwnHand',
);

/// The playing cards drawn under [of].
List<PlayingCard> _cardsIn(WidgetTester tester, Finder of) => tester
    .widgetList<PlayingCard>(
      find.descendant(of: of, matching: find.byType(PlayingCard)),
    )
    .toList();

/// The viewer's card on top of their fan — the middle one, dealt second.
Finder _ownTopCard(int handNo) => find.descendant(
  of: find.byKey(ValueKey('own-card-$handNo-1')),
  matching: find.byType(PlayingCard),
);

/// A point well inside [card] — below the light along its top, clear of its
/// gold edge — and outside every rect in [avoid] (the BLIND / SEEN capsule
/// laid over a seat's fan).
Offset _inside(Rect card, {List<Rect> avoid = const []}) {
  for (final (fx, fy) in const [
    (0.3, 0.8),
    (0.7, 0.8),
    (0.3, 0.4),
    (0.7, 0.4),
    (0.5, 0.85),
  ]) {
    final p = Offset(card.left + card.width * fx, card.top + card.height * fy);
    if (avoid.every((r) => !r.inflate(1).contains(p))) return p;
  }
  fail('no point of $card is clear of $avoid');
}

/// The BLIND / SEEN capsule on [userId]'s cards.
List<Rect> _capsules(WidgetTester tester, GameState state, String userId) => [
  for (final word in [state.t.blind, state.t.seen])
    for (final text
        in find
            .descendant(of: _pod(userId), matching: find.text(word))
            .evaluate())
      tester.getRect(
        find
            .ancestor(
              of: find.byWidget(text.widget),
              matching: find.byType(Container),
            )
            .first,
      ),
];

/// The table as the app mounts it, seated as Priya in [room], under a
/// boundary [key] can read.
Future<GameState> _mount(
  WidgetTester tester,
  RoomState room, {
  GlobalKey? key,
  Size size = const Size(891, 411),
  bool dark = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final state = sceneState(
    TableScene('card backs', (s) => s.handleState(room)),
  );
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: tableApp(
        state: state,
        feedback: feedback,
        theme: dark
            ? AppTheme.dark(sound: false)
            : AppTheme.light(sound: false),
      ),
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

/// The child layers of [boundary]'s own layer: a new list when it has been
/// recorded again.
List<Layer> _layers(RenderRepaintBoundary boundary) {
  final out = <Layer>[];
  var child = boundary.debugLayer?.firstChild;
  while (child != null) {
    out.add(child);
    child = child.nextSibling;
  }
  return out;
}

bool _same(List<Layer> a, List<Layer> b) =>
    a.length == b.length &&
    [for (var i = 0; i < a.length; i++) identical(a[i], b[i])].every((x) => x);

void main() {
  setUp(() {
    PictureCache.debugUseDirectory(null);
    PictureCache.debugResetSigning();
    forgetCardBacks();
  });
  tearDown(() {
    forgetCardBacks();
    PictureCache.debugResetSigning();
  });

  group('the table', () {
    testWidgets("every rim seat's face-down cards wear that seat's back, the "
        "viewer's hand their own, and a seat in none the Royal Fox", (
      tester,
    ) async {
      await primeCardBacks(tester, _worn);
      final state = await _mount(tester, cardBacksRoom());

      for (var seat = 1; seat < 5; seat++) {
        final cards = _cardsIn(tester, _pod('u$seat'));
        expect(cards, hasLength(3), reason: 'seat $seat');
        final worn = cardBacksWorn[seat];
        for (final card in cards) {
          expect(card.code, isNull, reason: 'seat $seat: face down');
          expect(
            card.back,
            worn == null ? isNull : seededCard(worn).art,
            reason: 'seat $seat',
          );
        }
      }
      final own = _cardsIn(tester, _ownHand);
      expect(own, hasLength(3));
      for (final card in own) {
        expect(card.code, isNull);
        expect(card.back, _tiger.art, reason: "the viewer's seat's back");
      }

      // Drawn as themselves: the bundled Royal Fox on Arjun's three cards and
      // nowhere else, and every back the seats wear by its own picture.
      final fox = find.byWidgetPredicate(
        (w) =>
            w is Image &&
            w.image is AssetImage &&
            (w.image as AssetImage).assetName == PlayingCard.backAsset,
      );
      expect(fox, findsNWidgets(3));
      expect(find.descendant(of: _pod('u3'), matching: fox), findsNWidgets(3));
      await _unmount(tester, state);
    });

    testWidgets('each back reaches the screen: the cards in their own '
        "back's colours, Meera's in green, the viewer's on top of their fan", (
      tester,
    ) async {
      await primeCardBacks(tester, _worn);
      final key = GlobalKey();
      final state = await _mount(tester, cardBacksRoom(), key: key);
      final pixels = await _grab(tester, key);

      Color firstCardOf(String userId) {
        final card = tester.getRect(
          find
              .descendant(of: _pod(userId), matching: find.byType(PlayingCard))
              .first,
        );
        return pixels.atPoint(
          _inside(card, avoid: _capsules(tester, state, userId)),
        );
      }

      // Ravi and Vikramaditya, blind: their backs as they are.
      expect(firstCardOf('u1'), _colour(_demon.colour), reason: 'Ravi');
      expect(firstCardOf('u4'), _colour(_owl.colour), reason: 'Vikramaditya');
      // Meera has looked: her Royal Lion in green.
      expect(firstCardOf('u2'), isNot(_colour(_lion.colour)));
      expect(firstCardOf('u2'), _seenGreen, reason: 'Meera');
      // Arjun wears none: the Royal Fox, and nobody's bought colour.
      final arjun = firstCardOf('u3');
      for (final card in seededCards) {
        expect(arjun, isNot(_colour(card.colour)), reason: card.name);
      }
      // The viewer's own: the Royal Tiger, on the card on top of their fan.
      final top = tester.getRect(_ownTopCard(7));
      expect(
        pixels.atPoint(_inside(top)),
        _colour(_tiger.colour),
        reason: "the viewer's",
      );
      await _unmount(tester, state);
    });

    testWidgets('a back chosen mid-hand reaches the viewer\'s cards with the '
        'snapshot that puts it on their seat', (tester) async {
      await primeCardBacks(tester, _worn);
      final key = GlobalKey();
      final bare = {...cardBacksWorn}..remove(0);
      final state = await _mount(tester, cardBacksRoom(worn: bare), key: key);
      List<CardBackArt?> ownBacks() => [
        for (final card in _cardsIn(tester, _ownHand)) card.back,
      ];
      expect(ownBacks(), [null, null, null], reason: 'the Royal Fox');

      // The account answers first (the store ticks it there): the cards wait
      // for the seat, which is what every other player sees on them.
      state.user = User.fromJson(cardAccountJson(card: _tiger, id: 'u0'));
      state.notifyListeners();
      await tester.pump();
      expect(ownBacks(), [null, null, null]);

      // The server puts it on the seat: the next room:state carries it.
      state.handleState(cardBacksRoom());
      await tester.pump();
      expect(ownBacks(), [_tiger.art, _tiger.art, _tiger.art]);
      final pixels = await _grab(tester, key);
      expect(
        pixels.atPoint(_inside(tester.getRect(_ownTopCard(7)))),
        _colour(_tiger.colour),
        reason: 'drawn on that very frame: the picture was decoded',
      );
      // Nobody else's cards moved.
      expect(
        _cardsIn(tester, _pod('u1')).map((c) => c.back),
        everyElement(_demon.art),
      );
      expect(
        _cardsIn(tester, _pod('u3')).map((c) => c.back),
        everyElement(isNull),
      );
      // And taken off again, the Royal Fox.
      state.handleState(cardBacksRoom(worn: bare));
      await tester.pump();
      expect(ownBacks(), [null, null, null]);
      await _unmount(tester, state);
    });

    testWidgets('the SEEN green lies over a bought back as over the Royal '
        'Fox, and a packed seat keeps its back, struck out', (tester) async {
      await primeCardBacks(tester, _worn);
      final key = GlobalKey();
      final state = await _mount(
        tester,
        cardBacksRoom(packed: const [4]),
        key: key,
      );
      final meera = tester.widgetList<CardBackImage>(
        find.descendant(of: _pod('u2'), matching: find.byType(CardBackImage)),
      );
      expect(meera, hasLength(3));
      for (final back in meera) {
        expect(back.art, _lion.art);
        expect(back.tint, AppTheme.cardSeenBack);
      }
      // Ravi has not looked: his back untinted.
      expect(
        _cardsIn(tester, _pod('u1')).map((c) => c.tint),
        everyElement(isNull),
      );
      // Vikramaditya packed: his cards struck out under his own back, no
      // green on history.
      final vikram = _cardsIn(tester, _pod('u4'));
      expect(vikram, hasLength(3));
      for (final card in vikram) {
        expect(card.dimmed, isTrue);
        expect(card.tint, isNull);
        expect(card.back, _owl.art);
      }
      // On the screen, Meera's lion is green.
      final pixels = await _grab(tester, key);
      final card = tester.getRect(
        find
            .descendant(of: _pod('u2'), matching: find.byType(PlayingCard))
            .last,
      );
      expect(
        pixels.atPoint(_inside(card, avoid: _capsules(tester, state, 'u2'))),
        _seenGreen,
      );
      await _unmount(tester, state);
    });

    testWidgets('the poker felt keeps the Royal Fox whatever a seat wears, on '
        'its cards and in its deal', (tester) async {
      await primeCardBacks(tester, seededCards);
      final json = pokerRoomJson();
      json['seats'] = [
        for (final (i, seat) in (json['seats'] as List).indexed)
          withCardBack(Map<String, dynamic>.from(seat as Map), seededCards[i]),
      ];
      final state = await _mount(tester, RoomState.fromJson(json));
      expect(
        state.room!.seats.map((s) => s.cardBackground),
        everyElement(isNotNull),
        reason: 'carried here, though no server sends a back to a poker room',
      );
      expect(state.ownCardBack, isNull);
      final cards = tester.widgetList<PlayingCard>(find.byType(PlayingCard));
      expect(cards.where((c) => c.code == null), isNotEmpty);
      expect(cards.map((c) => c.back), everyElement(isNull));
      expect(
        tester.widget<DealFlights>(find.byType(DealFlights)).seatBacks,
        isFalse,
      );
      await _unmount(tester, state);
    });

    testWidgets('the Teen Patti felt deals in seat backs', (tester) async {
      final state = await _mount(tester, cardBacksRoom());
      expect(
        tester.widget<DealFlights>(find.byType(DealFlights)).seatBacks,
        isTrue,
      );
      await _unmount(tester, state);
    });
  });

  group('the deal', () {
    late FeedbackSettings feedback;
    late GlobalKey key;

    setUp(() async {
      feedback = await silentFeedback();
      key = GlobalKey();
    });

    Seat seat(int i, SeededCard? card) =>
        Seat.fromJson(cardSeatJson(seatIndex: i, card: card));

    /// A deal's box, 800 x 600: four seats 170 apart along the foot, the
    /// deck high in the middle — far enough apart that a card nearing its
    /// seat stands clear of every other in the air.
    Widget table(
      List<Seat?> seats,
      int handNo, {
      bool seatBacks = true,
      double cardHeight = 40,
    }) => ChangeNotifierProvider<FeedbackSettings>.value(
      value: feedback,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                key: key,
                child: DealFlights(
                  seats: seats,
                  roomId: 'r1',
                  handNo: handNo,
                  centreOf: (i) => Offset(150 + 170.0 * i, 520),
                  deck: const Offset(400, 80),
                  cardHeight: cardHeight,
                  seatBacks: seatBacks,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    /// The deal's box at one pixel a point. The binding takes the deal down
    /// after the test, before its settings go.
    void view(WidgetTester tester) {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      addTearDown(feedback.dispose);
    }

    DealFlightsState flights(WidgetTester tester) =>
        tester.state<DealFlightsState>(find.byType(DealFlights));

    /// The cards in the air now that are fully opaque and stand clear of
    /// every other — where the back a card is drawn in can be read off the
    /// pixel at its middle.
    List<({int card, Offset centre, double alpha})> clear(WidgetTester tester) {
      final flying = flights(tester).cardsInFlight;
      return [
        for (final c in flying)
          if (c.alpha > 0.999 &&
              flying.every(
                (o) => o.card == c.card || (o.centre - c.centre).distance > 60,
              ))
            c,
      ];
    }

    testWidgets('each card flies in the back of the seat it is dealt to — the '
        'Royal Fox for a seat in none — and each back is rendered once', (
      tester,
    ) async {
      view(tester);
      await primeCardBacks(tester, [_tiger, _demon]);
      await _foxIn(tester, _fox);
      final seats = [
        seat(0, _tiger),
        seat(1, _demon),
        seat(2, null),
        seat(3, _tiger),
      ];
      await tester.pumpWidget(table(seats, 0));
      await tester.pumpWidget(table(seats, 7));
      expect(
        flights(tester).backsRendered,
        3,
        reason:
            'the Royal Tiger, the Brutal Demon and the Royal Fox, ready '
            'before anything is dealt — the tiger once for two seats',
      );

      await tester.pumpWidget(table(seats, 8));
      expect(flights(tester).dealtBacks.map((b) => b?.url).toList(), [
        for (var round = 0; round < DealFlights.cardsEach; round++) ...[
          _tiger.url,
          _demon.url,
          null,
          _tiger.url,
        ],
      ]);
      expect(flights(tester).backsRendered, 3, reason: 'nothing new to render');
      expect(
        find.descendant(
          of: find.byType(DealFlights),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
        reason: 'still one painter for every card, whatever it wears',
      );

      final colourOf = [_tiger.colour, _demon.colour, _fox, _tiger.colour];
      final checked = <int>{};
      for (var frame = 0; frame < 80 && checked.length < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 30));
        final ready = [
          for (final c in clear(tester))
            if (!checked.contains(c.card)) c,
        ];
        if (ready.isEmpty) continue;
        final pixels = await _grab(tester, key);
        for (final c in ready) {
          expect(
            pixels.atPoint(c.centre),
            _colour(colourOf[c.card % 4]),
            reason: 'card ${c.card}, to seat ${c.card % 4}',
          );
          checked.add(c.card);
        }
      }
      expect(checked, hasLength(12), reason: 'every card seen in the air');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a back still coming flies as the Royal Fox, and the cards '
        'still in the air take it up the moment it is decoded', (tester) async {
      view(tester);
      await _foxIn(tester, _fox);
      final seats = [seat(0, _tiger), seat(1, null)];
      await tester.pumpWidget(table(seats, 0));
      await tester.pumpWidget(table(seats, 7));
      await tester.pumpWidget(table(seats, 8));
      expect(flights(tester).backsRendered, 1, reason: 'the Royal Fox alone');
      expect(flights(tester).dealtBacks.map((b) => b?.url).toList(), [
        _tiger.url,
        null,
        _tiger.url,
        null,
        _tiger.url,
        null,
      ]);

      // Royal Tiger's first card, in the Royal Fox while its own is coming.
      Future<Color> seatZeroCard() async {
        for (var frame = 0; frame < 60; frame++) {
          final ready = clear(tester).where((c) => c.card.isEven).toList();
          if (ready.isNotEmpty) {
            return (await _grab(tester, key)).atPoint(ready.first.centre);
          }
          await tester.pump(const Duration(milliseconds: 16));
        }
        fail('no card of seat 0 stood clear in the air');
      }

      expect(await seatZeroCard(), _colour(_fox));

      // The tiger lands — decoded for a seat's own cards, say — and the next
      // frame flies it.
      await tester.runAsync(() async {
        PictureCache.prime(
          _tiger.url,
          await cardPicturePng(_tiger.crop, card: _tiger.colour),
        );
        await CardBackImages.load(_tiger.art);
      });
      await tester.pump(const Duration(milliseconds: 16));
      expect(flights(tester).backsRendered, 2);
      expect(await seatZeroCard(), _colour(_tiger.colour));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('without seat backs — the poker felt — every card is the '
        'Royal Fox, whatever the seats wear', (tester) async {
      view(tester);
      await primeCardBacks(tester, [_tiger, _demon]);
      await _foxIn(tester, _fox);
      final seats = [seat(0, _tiger), seat(1, _demon)];
      await tester.pumpWidget(table(seats, 0, seatBacks: false));
      await tester.pumpWidget(table(seats, 7, seatBacks: false));
      await tester.pumpWidget(table(seats, 8, seatBacks: false));
      expect(flights(tester).dealtBacks, everyElement(isNull));
      expect(flights(tester).dealtBacks, hasLength(6));
      expect(flights(tester).backsRendered, 1);
      var seen = 0;
      for (var frame = 0; frame < 60 && seen == 0; frame++) {
        await tester.pump(const Duration(milliseconds: 30));
        final ready = clear(tester);
        if (ready.isEmpty) continue;
        final pixels = await _grab(tester, key);
        for (final c in ready) {
          expect(pixels.atPoint(c.centre), _colour(_fox));
          seen++;
        }
      }
      expect(seen, greaterThan(0));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a back is rendered once a size: dealt again it renders '
        'nothing new, a new card size renders each again, and a back nobody '
        'wears any more is let go', (tester) async {
      view(tester);
      await primeCardBacks(tester, [_tiger, _demon]);
      await _foxIn(tester, _fox);
      final seats = <Seat?>[seat(0, _tiger), seat(1, _demon)];
      await tester.pumpWidget(table(seats, 0));
      await tester.pumpWidget(table(seats, 7));
      await tester.pumpWidget(table(seats, 8));
      await tester.pump(const Duration(seconds: 3));
      expect(flights(tester).backsRendered, 3);

      // The next hand, in the same backs.
      await tester.pumpWidget(table(seats, 9));
      await tester.pump(const Duration(seconds: 3));
      expect(flights(tester).backsRendered, 3);

      // A bigger table: each of the three again, at the new size.
      await tester.pumpWidget(table(seats, 9, cardHeight: 44));
      expect(flights(tester).backsRendered, 6);

      // Ravi gets up, and the demon goes with him: when he sits down again
      // in it, it is rendered anew.
      await tester.pumpWidget(table([seats[0], null], 9, cardHeight: 44));
      await tester.pumpWidget(table(seats, 9, cardHeight: 44));
      expect(flights(tester).backsRendered, 7);
    });
  });

  testWidgets('a deal in seat backs repaints only its own layer: never the '
      'casino table, and the felt on exactly the frames a deal in the Royal '
      'Fox does — none once the hand is laid out', (tester) async {
    await tester.runAsync(() => CardBackImages.load(null));

    /// The frames of a deal on which each layer was recorded again: nobody
    /// on turn, so no seat's clock moves on the felt and only the deal and
    /// the hand's own arrival are left to repaint anything.
    Future<({List<int> table, List<int> felt, List<int> deal})> dealt(
      Map<int, String> worn,
    ) async {
      await primeCardBacks(tester, [
        for (final name in worn.values) seededCard(name),
      ]);
      final state = await _mount(
        tester,
        cardBacksRoom(worn: worn, turnSeat: null),
      );
      RenderRepaintBoundary nearest(Finder above, {bool inside = false}) =>
          tester.renderObject<RenderRepaintBoundary>(
            (inside
                    ? find.descendant(
                        of: above,
                        matching: find.byType(RepaintBoundary),
                      )
                    : find.ancestor(
                        of: above,
                        matching: find.byType(RepaintBoundary),
                      ))
                .first,
          );
      final table = nearest(find.byType(CasinoTableSurface), inside: true);
      final deal = nearest(find.byType(DealFlights));
      final felt = nearest(
        find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Felt'),
      );
      final frames = {table: <int>[], felt: <int>[], deal: <int>[]};
      final last = {for (final b in frames.keys) b: _layers(b)};

      state.handleState(cardBacksRoom(worn: worn, handNo: 8, turnSeat: null));
      // The whole deal of fifteen cards, frame by frame, and a little after.
      for (var frame = 0; frame < 160; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (frame == 60) {
          expect(
            tester
                .state<DealFlightsState>(find.byType(DealFlights))
                .dealtBacks
                .map((b) => b?.url)
                .take(5)
                .toList(),
            [
              for (var i = 0; i < 5; i++)
                worn[i] == null ? null : seededCard(worn[i]!).url,
            ],
            reason: 'dealt in the seats\' backs',
          );
        }
        for (final b in frames.keys) {
          final now = _layers(b);
          if (!_same(last[b]!, now)) frames[b]!.add(frame);
          last[b] = now;
        }
      }
      await _unmount(tester, state);
      return (table: frames[table]!, felt: frames[felt]!, deal: frames[deal]!);
    }

    final plain = await dealt(const {});
    final dressed = await dealt(cardBacksWorn);
    expect(plain.table, isEmpty);
    expect(dressed.table, isEmpty, reason: 'the casino table is never redrawn');
    expect(
      dressed.felt,
      plain.felt,
      reason: 'the backs cost the felt not one frame',
    );
    // Once the hand is laid out the felt is still, and the cards fly on in
    // their own layer, frame after frame, to the last one down.
    final tail = [for (var frame = 50; frame < 140; frame++) frame];
    expect(dressed.felt.where(tail.contains), isEmpty);
    expect(dressed.deal, containsAll(tail));
  });

  testWidgets("the card-back scenes: every seat's back on the table and "
      'every card of the next hand flying in its seat\'s', (tester) async {
    final scene = tableScenes.firstWhere(
      (s) => s.name == '43-cards-backs-dealing',
    );
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final feedback = await silentFeedback();
    addTearDown(feedback.dispose);
    final state = sceneState(scene);
    await tester.pumpWidget(
      tableApp(
        state: state,
        feedback: feedback,
        theme: AppTheme.dark(sound: false),
      ),
    );
    await tester.pump(const Duration(milliseconds: 900));
    await scene.act!(tester, state);
    final deal = tester.state<DealFlightsState>(find.byType(DealFlights));
    expect(deal.backsRendered, 5, reason: 'four backs worn and the Royal Fox');
    expect(deal.dealtBacks.map((b) => b?.url).take(5).toList(), [
      for (var i = 0; i < 5; i++)
        cardBacksWorn[i] == null ? null : seededCard(cardBacksWorn[i]!).url,
    ]);
    expect(deal.cardsInFlight, isNotEmpty);
    expect(tester.takeException(), isNull);
    await _unmount(tester, state);
  });
}
