// A rented card back runs out (owner, 3 Oct 2026: "when validity of premium
// card expires, it restores default card"). The server takes it off every
// seat at that moment and says when the moment is — `cardBackground.expiresAt`
// on every seat and on the account (epoch ms, absent for never) — and the
// phone does not wait for its next word: from the moment, every card that
// wore the back wears the bundled Royal Fox.
//
// Held here: the expiry read off the wire (and none for anything that is not
// one); a back running out at its moment, to the millisecond; the account's
// chosen back and a rental on the Cards shelf letting go at theirs; at the
// table, each rim seat's cards and the viewer's own turning to the Royal Fox
// at their own back's moment — before any room:state says so, with one notify
// and nothing rebuilt in between — a late snapshot still carrying the back
// changing nothing, and the deal flying the Royal Fox, cards already in the
// air included; an open Cards shelf turning the back's tile to its padlock
// and price and the Royal Fox's to In use at the moment, in the lobby and at
// a table; and GameState reading the catalogue and the account again when
// the back was the player's own — never for somebody else's, never for a far
// rental before its day, never at a poker room's.
//
// Everything runs on the fake clock a widget test's pumps advance
// (cardBackClock set to it), the way a phone's clock runs past a rental's
// end.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/card_back_art.dart';
import 'package:teenpatti/widgets/card_back_shelf.dart';
import 'package:teenpatti/widgets/chip_store.dart';
import 'package:teenpatti/widgets/deal_flight.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';
import 'package:teenpatti/widgets/playing_card.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/seat_pod.dart';

import 'card_background_fixtures.dart';
import 'table_scenes.dart';

final _tiger = seededCard('Royal Tiger');
final _demon = seededCard('Brutal Demon');
final _lion = seededCard('Royal Lion');
final _owl = seededCard('Royal Owl with Fox');
final _hunter = seededCard('Dragon Hunter');

const _english = Strings(AppLang.english);

/// The fake clock's now, epoch ms.
int _now(WidgetTester tester) =>
    tester.binding.clock.now().millisecondsSinceEpoch;

/// Card backs read on the test's fake clock — the one its pumps advance —
/// until the test ends.
void _onTheFakeClock(WidgetTester tester) {
  cardBackClock = () => tester.binding.clock.now();
  addTearDown(() => cardBackClock = DateTime.now);
}

/// Pumps until [at] (epoch ms on the fake clock) is [before] away.
Future<void> _pumpUntil(
  WidgetTester tester,
  int at, {
  Duration before = Duration.zero,
}) async {
  final wait = at - before.inMilliseconds - _now(tester);
  expect(wait, greaterThanOrEqualTo(0), reason: 'the moment has passed');
  await tester.pump(Duration(milliseconds: wait));
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

/// The account and the catalogue as the server answers them, asked now —
/// and the other reads a refresh makes — recording every call; with a
/// [gate], every answer waits for it.
class _Server {
  _Server({required this.account, required this.catalogue});

  Map<String, dynamic> Function() account;
  Map<String, dynamic> Function() catalogue;
  Completer<void>? gate;

  final calls = <String>[];

  MockClient get client => MockClient(_answer);

  Future<http.Response> _answer(http.Request r) async {
    final call = '${r.method} ${r.url.path}';
    calls.add(call);
    final held = gate;
    if (held != null) await held.future;
    switch (call) {
      case 'GET /api/card-backgrounds':
        return _json(catalogue());
      case 'GET /api/auth/me':
        return _json({'user': account()});
      case 'GET /api/profiles':
        return _json({'profiles': <Object>[]});
      case 'GET /api/table-pictures':
        return _json({'tablePictures': <Object>[]});
      case 'GET /api/emojis':
        return _json({'emojis': <Object>[]});
    }
    return _json({'error': 'not_found', 'message': 'Not found'}, 404);
  }

  /// Whether the catalogue was asked for — the first of a refresh's reads.
  bool get catalogueAsked => calls.contains('GET /api/card-backgrounds');

  /// Whether the catalogue and the account were both asked for: the account
  /// is read once the catalogues have answered.
  bool get reread =>
      calls.contains('GET /api/card-backgrounds') &&
      calls.contains('GET /api/auth/me');
}

/// A GameState that never starts Play: the override keeps the purchase plugin
/// from registering an Android billing client in a test.
GameState _state({
  Screen screen = Screen.lobby,
  String? token = 'tok',
  User? user,
  List<CardBackground> cards = const [],
}) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://api.test');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..debugToken = token
    ..screen = screen
    ..user = user
    ..cardBackgrounds = cards;
}

/// [card]'s catalogue row as this player holds it.
CardBackground _row(GameState state, SeededCard card) =>
    state.cardBackgrounds.firstWhere((c) => c.id == card.id);

/// Lets a fake server's answers through.
Future<void> _answers(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }
}

// ------------------------------------------------------------- the table

Finder _pod(String userId) =>
    find.byWidgetPredicate((w) => w is SeatPod && w.seat?.userId == userId);

final Finder _ownHand = find.byWidgetPredicate(
  (w) => w.runtimeType.toString() == '_OwnHand',
);

/// The backs the playing cards under [of] are drawn in.
List<CardBackArt?> _backsIn(WidgetTester tester, Finder of) => [
  for (final card in tester.widgetList<PlayingCard>(
    find.descendant(of: of, matching: find.byType(PlayingCard)),
  ))
    card.back,
];

/// A back as the deal records it: its picture and crop — the row and the
/// term are nothing to a card in the air.
CardBackArt _dealtAs(SeededCard card) =>
    CardBackArt(url: card.url, crop: card.crop);

/// The pictures the cards under [of] show: each card's own back, or null
/// for the Royal Fox.
List<CardBackArt?> _drawnIn(WidgetTester tester, Finder of) => [
  for (final image in tester.widgetList<CardBackImage>(
    find.descendant(of: of, matching: find.byType(CardBackImage)),
  ))
    image.art,
];

/// Pixels read back from a picture.
class _Pixels {
  _Pixels(this.width, this.data);

  final int width;
  final ByteData data;

  Color at(Offset p) {
    final i = (p.dy.floor() * width + p.dx.floor()) * 4;
    return Color.fromARGB(
      data.getUint8(i + 3),
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
    );
  }
}

Future<_Pixels> _grab(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData();
    final pixels = _Pixels(image.width, data!);
    image.dispose();
    return pixels;
  }))!;
}

/// Whether a colour is [expected] to within a few levels a channel.
bool _near(Color actual, Color expected) =>
    (actual.r - expected.r).abs() <= 0.06 &&
    (actual.g - expected.g).abs() <= 0.06 &&
    (actual.b - expected.b).abs() <= 0.06;

/// A point well inside [card] — below the light along its top, clear of its
/// gold edge — and outside every rect in [avoid] (the BLIND / SEEN capsule
/// laid over a seat's fan), as card_back_table_test reads one.
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
/// boundary [key] can read; no session, so nothing is read again.
Future<GameState> _mountTable(
  WidgetTester tester,
  RoomState room,
  GlobalKey key,
) async {
  tester.view.physicalSize = const Size(891, 411);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final state = sceneState(
    TableScene('card backs running out', (s) => s.handleState(room)),
  );
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: tableApp(
        state: state,
        feedback: feedback,
        theme: AppTheme.dark(sound: false),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pump(const Duration(milliseconds: 900));
  return state;
}

Future<void> _unmountTable(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

// -------------------------------------------------------------- the shelf

/// An empty screen as main.dart builds one, and the store opened on its
/// Cards shelf.
Future<void> _openCards(
  WidgetTester tester,
  GameState state,
  FeedbackSettings feedback,
) async {
  tester.view.physicalSize = const Size(891, 411);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late BuildContext host;
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(sound: false),
        builder: (context, child) => GlassBudget(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            resizeToAvoidBottomInset: false,
            body: child,
          ),
        ),
        home: Builder(
          builder: (context) {
            host = context;
            return const SizedBox.expand();
          },
        ),
      ),
    ),
  );
  unawaited(showChipStore(host, opensOn: StoreTab.cards));
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
}

Future<void> _closeStore(
  WidgetTester tester,
  GameState state,
  FeedbackSettings feedback,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
  state.dispose();
  feedback.dispose();
}

/// The tile showing [name].
Finder _tile(String name) => find
    .ancestor(of: find.text(name), matching: find.byType(CardBackChoice))
    .first;

/// What a tile's badge says now: the switcher is keyed on it, so it says it
/// from the first frame of the change.
ShelfBadgeKind _kindOf(WidgetTester tester, Finder tile) => tester
    .widget<ShelfBadgeSwitcher>(
      find.descendant(of: tile, matching: find.byType(ShelfBadgeSwitcher)),
    )
    .kind;

void main() {
  setUp(() {
    // Nothing reaches a disk and nothing is signed: a catalogue's warm-up
    // fetches nothing.
    PictureCache.debugUseDirectory(null);
    PictureCache.debugResetSigning();
    forgetCardBacks();
  });
  tearDown(() {
    forgetCardBacks();
    PictureCache.debugResetSigning();
    cardBackClock = DateTime.now;
  });

  group('the wire', () {
    const at = 1893456000000; // 2030

    test('a worn back carries the moment its rental runs out, on a seat and '
        'on the account, through every copy; anything else is never', () {
      expect(
        CardBackArt.fromJson(cardBackJson(_tiger, expiresAt: at))!.expiresAt,
        at,
      );
      expect(CardBackArt.fromJson(cardBackJson(_tiger))!.expiresAt, 0);
      for (final raw in <Object?>[
        null,
        '1893456000000',
        true,
        <Object>[],
        0,
        -5,
        double.nan,
        double.negativeInfinity,
      ]) {
        final json = cardBackJson(_tiger)..['expiresAt'] = raw;
        expect(CardBackArt.fromJson(json)!.expiresAt, 0, reason: '$raw');
      }
      // A whole number however JSON wrote it.
      expect(
        CardBackArt.fromJson(
          cardBackJson(_tiger)..['expiresAt'] = 1893456000000.0,
        )!.expiresAt,
        at,
      );

      final seat = Seat.fromJson(
        cardSeatJson(seatIndex: 1, card: _demon, expiresAt: at),
      );
      expect(seat.cardBackground, _demon.artUntil(at));
      expect(seat.withStatus(SeatState.packed).cardBackground!.expiresAt, at);

      final user = User.fromJson(cardAccountJson(card: _tiger, expiresAt: at));
      expect(user.cardBackground, _tiger.artUntil(at));
      for (final copy in [user.withHammer(3), user.withMissile(2)]) {
        expect(copy.cardBackground!.expiresAt, at);
      }

      // The same picture with another term is another back to a reader.
      expect(_tiger.artUntil(at), isNot(_tiger.art));
      expect(_tiger.artUntil(at), _tiger.artUntil(at));
      expect(_tiger.artUntil(at).hashCode, _tiger.artUntil(at).hashCode);
    });

    test('a back runs out at its moment, to the millisecond; one with no '
        'expiry never does', () {
      final art = _tiger.artUntil(at);
      DateTime when(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);
      expect(art.expiredAt(when(at - 1)), isFalse);
      expect(art.expiredAt(when(at)), isTrue, reason: 'the server\'s rule');
      expect(art.expiredAt(when(at + 1)), isTrue);
      expect(liveCardBack(art, when(at - 1)), art);
      expect(liveCardBack(art, when(at)), isNull, reason: 'the Royal Fox');
      expect(liveCardBack(null, when(at - 1)), isNull);
      expect(_tiger.art.expiredAt(when(at * 2)), isFalse);
      expect(liveCardBack(_tiger.art, when(at * 2)), _tiger.art);

      // On the card-back clock when no moment is named.
      cardBackClock = () => when(at - 1);
      expect(liveCardBack(art), art);
      cardBackClock = () => when(at);
      expect(liveCardBack(art), isNull);
    });

    test('the account\'s chosen back is none from its moment: the Royal Fox '
        'in use', () {
      final user = User.fromJson(cardAccountJson(card: _tiger, expiresAt: at));
      cardBackClock = () => DateTime.fromMillisecondsSinceEpoch(at - 1);
      expect(user.activeCardBackgroundId, _tiger.id);
      cardBackClock = () => DateTime.fromMillisecondsSinceEpoch(at);
      expect(user.activeCardBackgroundId, isNull);
      // A back bought for ever stays chosen whatever the clock says.
      expect(
        User.fromJson(cardAccountJson(card: _tiger)).activeCardBackgroundId,
        _tiger.id,
      );
    });

    test('a rental on the shelf goes back to its padlock at its moment; one '
        'never bought is locked, and one owned for ever never lapses', () {
      final rented = CardBackground.fromJson(
        cardBackgroundJson(_tiger, owned: true, expiresAt: at),
      );
      DateTime when(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);
      expect(rented.lapsedAt(when(at - 1)), isFalse);
      expect(rented.lapsedAt(when(at)), isTrue);
      cardBackClock = () => when(at - 1);
      expect(rented.locked, isFalse);
      cardBackClock = () => when(at);
      expect(rented.locked, isTrue);
      expect(rented.owned, isTrue, reason: 'as the server last said');

      final never = CardBackground.fromJson(cardBackgroundJson(_tiger));
      expect(never.lapsedAt(when(at)), isFalse, reason: 'not owned at all');
      expect(never.locked, isTrue);
      final forever = CardBackground.fromJson(
        cardBackgroundJson(_tiger, owned: true),
      );
      expect(forever.lapsedAt(when(at * 2)), isFalse);
      cardBackClock = () => when(at * 2);
      expect(forever.locked, isFalse);
      final free = CardBackground.fromJson(
        cardBackgroundJson(
          _tiger,
          type: 'FREE',
          cost: 0,
          durationDays: 0,
          owned: true,
        ),
      );
      expect(free.locked, isFalse);
    });

    test('a free back never lapses on the shelf, whatever term the catalogue '
        'still reports from a time it was sold', () {
      // The server lists a FREE back with a running ownership row left from
      // a time it was sold as owned, with that row's expires_at — while the
      // account carries it with no term: a free back never runs out.
      final free = CardBackground.fromJson(
        cardBackgroundJson(
          _tiger,
          type: 'FREE',
          cost: 0,
          durationDays: 0,
          owned: true,
          expiresAt: at,
        ),
      );
      DateTime when(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);
      expect(free.lapsedAt(when(at)), isFalse);
      expect(free.lapsedAt(when(at * 2)), isFalse);
      cardBackClock = () => when(at);
      expect(free.locked, isFalse, reason: 'no padlock on a free back');
    });
  });

  group('GameState', () {
    testWidgets('at a table: the viewer\'s own back is the Royal Fox from its '
        'moment, before any room:state says so, and the catalogue and the '
        'account are read again — never for somebody else\'s back', (
      tester,
    ) async {
      _onTheFakeClock(tester);
      final mine = _now(tester) + 5000;
      final ravis = _now(tester) + 7000;
      final server = _Server(
        account: () => _now(tester) < mine
            ? cardAccountJson(card: _tiger, expiresAt: mine)
            : cardAccountJson(),
        catalogue: () => cardCatalogueJson(
          owned: {if (_now(tester) < mine) _tiger.id: mine},
        ),
      );
      await http.runWithClient(() async {
        final state = _state(
          screen: Screen.table,
          user: User.fromJson(cardAccountJson(card: _tiger, expiresAt: mine)),
          cards: seededCatalogue(owned: {_tiger.id: mine}),
        );
        state.handleState(cardBacksRoom(expiring: {0: mine, 1: ravis}));
        var told = 0;
        state.addListener(() => told++);
        expect(state.ownCardBack, _tiger.artUntil(mine));
        expect(state.chosenCardBack, _tiger.artUntil(mine));

        await _pumpUntil(tester, mine, before: const Duration(milliseconds: 1));
        expect(state.ownCardBack, _tiger.artUntil(mine));
        expect(state.user!.activeCardBackgroundId, _tiger.id);
        expect(_row(state, _tiger).locked, isFalse);
        expect(told, 0, reason: 'nothing woke anybody before the moment');
        expect(server.calls, isEmpty);

        // The moment: the answers held, to see what the phone does alone.
        server.gate = Completer<void>();
        await tester.pump(const Duration(milliseconds: 1));
        expect(told, 1, reason: 'one notify, at the moment');
        expect(state.ownCardBack, isNull, reason: 'the Royal Fox');
        expect(state.chosenCardBack, isNull);
        expect(state.user!.activeCardBackgroundId, isNull);
        expect(_row(state, _tiger).locked, isTrue);
        // The snapshot is still the server's last: nothing waited for it.
        expect(state.room!.seats[0].cardBackground, _tiger.artUntil(mine));
        expect(server.catalogueAsked, isTrue, reason: '${server.calls}');

        // The server answers: no back on the account, the rental over.
        server.gate!.complete();
        server.gate = null;
        await _answers(tester);
        expect(server.reread, isTrue, reason: '${server.calls}');
        expect(state.user!.cardBackground, isNull);
        expect(_row(state, _tiger).owned, isFalse);
        expect(state.ownCardBack, isNull);

        // Ravi's back is his own business: his cards change at its moment,
        // and nothing is read for it.
        server.calls.clear();
        told = 0;
        expect(
          liveCardBack(state.room!.seats[1].cardBackground),
          _demon.artUntil(ravis),
        );
        await _pumpUntil(tester, ravis);
        expect(told, 1);
        expect(liveCardBack(state.room!.seats[1].cardBackground), isNull);
        await _answers(tester);
        expect(server.calls, isEmpty);
        state.dispose();
      }, () => server.client);
    });

    testWidgets('in the lobby: each of the player\'s rentals is read again at '
        'its own moment, the chosen one and one that is not', (tester) async {
      _onTheFakeClock(tester);
      final first = _now(tester) + 3000;
      final second = _now(tester) + 6000;
      final server = _Server(
        account: () => _now(tester) < first
            ? cardAccountJson(card: _tiger, expiresAt: first)
            : cardAccountJson(),
        catalogue: () => cardCatalogueJson(
          owned: {
            if (_now(tester) < first) _tiger.id: first,
            if (_now(tester) < second) _hunter.id: second,
          },
        ),
      );
      await http.runWithClient(() async {
        final state = _state(
          user: User.fromJson(cardAccountJson(card: _tiger, expiresAt: first)),
          cards: seededCatalogue(owned: {_tiger.id: first, _hunter.id: second}),
        );
        state.notifyListeners();
        await _pumpUntil(
          tester,
          first,
          before: const Duration(milliseconds: 1),
        );
        expect(server.calls, isEmpty);
        await tester.pump(const Duration(milliseconds: 1));
        await _answers(tester);
        expect(server.reread, isTrue);
        expect(state.chosenCardBack, isNull);
        expect(_row(state, _hunter).locked, isFalse, reason: 'still running');

        server.calls.clear();
        await _pumpUntil(tester, second);
        expect(_row(state, _hunter).locked, isTrue, reason: 'at its moment');
        await _answers(tester);
        expect(server.reread, isTrue);
        expect(_row(state, _hunter).owned, isFalse);
        state.dispose();
      }, () => server.client);
    });

    testWidgets('a rental days away wakes nobody before its day — the wake-up '
        'is a day at most, and silent — and a back bought for ever none at '
        'all', (tester) async {
      _onTheFakeClock(tester);
      final far = _now(tester) + const Duration(days: 3).inMilliseconds;
      final server = _Server(
        account: () => cardAccountJson(card: _tiger, expiresAt: far),
        catalogue: () => cardCatalogueJson(owned: {_tiger.id: far}),
      );
      await http.runWithClient(() async {
        final state = _state(
          user: User.fromJson(cardAccountJson(card: _tiger, expiresAt: far)),
          cards: seededCatalogue(owned: {_tiger.id: far}),
        );
        var told = 0;
        state
          ..addListener(() => told++)
          ..notifyListeners();
        told = 0;
        await tester.pump(const Duration(hours: 25));
        await tester.pump(const Duration(hours: 25));
        expect(told, 0, reason: 'woken twice, a day apart, and said nothing');
        expect(server.calls, isEmpty);
        expect(state.chosenCardBack, _tiger.artUntil(far));
        server.gate = Completer<void>();
        await _pumpUntil(tester, far);
        expect(told, 1, reason: 'the moment, and nothing before it');
        expect(state.chosenCardBack, isNull);
        server.gate!.complete();
        server.gate = null;
        await _answers(tester);
        expect(server.reread, isTrue);

        // Bought for ever: no moment to wake for.
        server.calls.clear();
        state
          ..user = User.fromJson(cardAccountJson(card: _tiger))
          ..cardBackgrounds = seededCatalogue(owned: {_tiger.id: 0})
          ..notifyListeners();
        told = 0;
        await tester.pump(const Duration(days: 30));
        expect(told, 0);
        expect(server.calls, isEmpty);
        expect(state.chosenCardBack, _tiger.art);
        state.dispose();
      }, () => server.client);
    });

    testWidgets('a free back\'s term from a time it was sold wakes nobody and '
        'reads nothing: a free back never runs out', (tester) async {
      _onTheFakeClock(tester);
      final at = _now(tester) + 2000;
      final server = _Server(
        account: () => cardAccountJson(card: _tiger),
        catalogue: cardCatalogueJson,
      );
      await http.runWithClient(() async {
        final state = _state(
          user: User.fromJson(cardAccountJson(card: _tiger)),
          cards: [
            CardBackground.fromJson(
              cardBackgroundJson(
                _tiger,
                type: 'FREE',
                cost: 0,
                durationDays: 0,
                owned: true,
                expiresAt: at,
              ),
            ),
          ],
        );
        var told = 0;
        state
          ..addListener(() => told++)
          ..notifyListeners();
        told = 0;
        await tester.pump(const Duration(seconds: 5));
        await _answers(tester);
        expect(told, 0, reason: 'nothing woke for a free back');
        expect(server.calls, isEmpty);
        expect(_row(state, _tiger).locked, isFalse);
        expect(state.chosenCardBack, _tiger.art);
        state.dispose();
      }, () => server.client);
    });

    testWidgets('a poker room\'s backs are not watched — its felt keeps the '
        'Royal Fox — and signed out nothing is read', (tester) async {
      _onTheFakeClock(tester);
      final at = _now(tester) + 2000;
      final server = _Server(
        account: cardAccountJson,
        catalogue: cardCatalogueJson,
      );
      await http.runWithClient(() async {
        final state = _state(screen: Screen.table);
        final poker = cardRoomJson(
          seats: [
            cardSeatJson(seatIndex: 0, card: _tiger, expiresAt: at),
            cardSeatJson(seatIndex: 1, card: _demon, expiresAt: at),
          ],
          game: 'poker',
        );
        state.handleState(RoomState.fromJson(poker));
        var told = 0;
        state.addListener(() => told++);
        await tester.pump(const Duration(seconds: 5));
        expect(told, 0);
        expect(state.ownCardBack, isNull);

        // Signed out, a rental that runs out reads nothing.
        final signedOut = _state(
          token: null,
          user: User.fromJson(
            cardAccountJson(card: _tiger, expiresAt: at + 5000),
          ),
          cards: seededCatalogue(owned: {_tiger.id: at + 5000}),
        )..notifyListeners();
        await tester.pump(const Duration(seconds: 6));
        expect(signedOut.chosenCardBack, isNull);
        expect(server.calls, isEmpty);
        signedOut.dispose();
        state.dispose();
      }, () => server.client);
    });

    testWidgets('disposed, the watch wakes no more', (tester) async {
      _onTheFakeClock(tester);
      final at = _now(tester) + 1000;
      final state = _state(
        token: null,
        user: User.fromJson(cardAccountJson(card: _tiger, expiresAt: at)),
      )..notifyListeners();
      state.dispose();
      // A timer left running would be pending at the end of the test, and
      // one that fired would notify a disposed notifier: neither happens.
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    });
  });

  group('the table', () {
    testWidgets('each rim seat\'s cards and the viewer\'s own turn to the '
        'Royal Fox at their own back\'s moment — before any room:state, one '
        'notify each and nothing rebuilt in between — and a late snapshot '
        'still carrying the backs changes nothing', (tester) async {
      _onTheFakeClock(tester);
      await primeCardBacks(tester, [_tiger, _demon, _lion, _owl]);
      final key = GlobalKey();
      final ravis = _now(tester) + 6000;
      final mine = _now(tester) + 9000;
      final expiring = {1: ravis, 0: mine};
      final state = await _mountTable(
        tester,
        cardBacksRoom(expiring: expiring),
        key,
      );
      var told = 0;
      state.addListener(() => told++);

      expect(
        _backsIn(tester, _pod('u1')),
        everyElement(_demon.artUntil(ravis)),
      );
      expect(_backsIn(tester, _ownHand), everyElement(_tiger.artUntil(mine)));
      final ravisCard = _inside(
        tester.getRect(
          find
              .descendant(of: _pod('u1'), matching: find.byType(PlayingCard))
              .first,
        ),
        avoid: _capsules(tester, state, 'u1'),
      );
      expect(
        _near((await _grab(tester, key)).at(ravisCard), _demon.colour),
        isTrue,
        reason: 'Ravi\'s demon, drawn',
      );

      await _pumpUntil(tester, ravis, before: const Duration(milliseconds: 1));
      expect(told, 0, reason: 'nothing rebuilt the felt before the moment');
      expect(
        _backsIn(tester, _pod('u1')),
        everyElement(_demon.artUntil(ravis)),
      );

      await tester.pump(const Duration(milliseconds: 1));
      expect(told, 1);
      await tester.pump();
      expect(_backsIn(tester, _pod('u1')), everyElement(isNull));
      expect(_drawnIn(tester, _pod('u1')), everyElement(isNull));
      expect(
        _near((await _grab(tester, key)).at(ravisCard), _demon.colour),
        isFalse,
        reason: 'the Royal Fox on Ravi\'s cards now',
      );
      // Nobody else's cards moved.
      expect(_backsIn(tester, _ownHand), everyElement(_tiger.artUntil(mine)));
      expect(_backsIn(tester, _pod('u2')), everyElement(_lion.art));
      expect(_backsIn(tester, _pod('u4')), everyElement(_owl.art));

      await _pumpUntil(tester, mine, before: const Duration(milliseconds: 1));
      expect(told, 1, reason: 'still one');
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(told, 2);
      expect(_backsIn(tester, _ownHand), everyElement(isNull));
      expect(_drawnIn(tester, _ownHand), everyElement(isNull));

      // A room:state from a server a moment behind still carries both: the
      // Royal Fox all the same.
      state.handleState(cardBacksRoom(expiring: expiring));
      await tester.pump();
      expect(_backsIn(tester, _pod('u1')), everyElement(isNull));
      expect(_backsIn(tester, _ownHand), everyElement(isNull));
      expect(_backsIn(tester, _pod('u2')), everyElement(_lion.art));

      // The next deal flies the Royal Fox to those two seats, and every
      // other card in its seat's back.
      state.handleState(cardBacksRoom(handNo: 8, expiring: expiring));
      await tester.pump();
      final deal = tester.state<DealFlightsState>(find.byType(DealFlights));
      final dealt = deal.dealtBacks;
      // Dealt one seat after another, three times round: the seats in the
      // hand are 0..4, each a card a round.
      expect(dealt, hasLength(15));
      for (var round = 0; round < 3; round++) {
        final cards = dealt.sublist(round * 5, round * 5 + 5);
        expect(cards[0], isNull, reason: 'the viewer\'s');
        expect(cards[1], isNull, reason: 'Ravi\'s');
        expect(cards[2], _dealtAs(_lion));
        expect(cards[3], isNull, reason: 'Arjun wears none');
        expect(cards[4], _dealtAs(_owl));
      }
      await _unmountTable(tester, state);
    });

    testWidgets('a card in the air when its back runs out flies on in the '
        'Royal Fox', (tester) async {
      _onTheFakeClock(tester);
      await primeCardBacks(tester, [_tiger, _demon, _lion, _owl]);
      final key = GlobalKey();
      final at = _now(tester) + 4000;
      final expiring = {1: at};
      final state = await _mountTable(
        tester,
        cardBacksRoom(expiring: expiring),
        key,
      );
      // Dealt 300 ms before Ravi's back runs out: the deal runs some two
      // and a half seconds.
      await _pumpUntil(tester, at, before: const Duration(milliseconds: 300));
      state.handleState(cardBacksRoom(handNo: 8, expiring: expiring));
      await tester.pump();
      // The first cards off the deck.
      await tester.pump(const Duration(milliseconds: 50));
      final deal = tester.state<DealFlightsState>(find.byType(DealFlights));
      List<CardBackArt?> ravis() => [
        for (var round = 0; round < 3; round++) deal.dealtBacks[round * 5 + 1],
      ];
      expect(ravis(), everyElement(_dealtAs(_demon)));
      expect(deal.cardsInFlight, isNotEmpty);

      await _pumpUntil(tester, at);
      await tester.pump();
      expect(deal.cardsInFlight, isNotEmpty, reason: 'still in the air');
      expect(ravis(), everyElement(isNull), reason: 'the Royal Fox now');
      expect(deal.dealtBacks[2], _dealtAs(_lion), reason: 'Meera\'s as it was');
      await _unmountTable(tester, state);
    });
  });

  group('the Cards shelf', () {
    for (final screen in [Screen.lobby, Screen.table]) {
      testWidgets('${screen.name}: an open Cards shelf turns the back\'s tile '
          'to its padlock and price, and the Royal Fox\'s to In use, at the '
          'moment its rental runs out — then reads the catalogue and the '
          'account again', (tester) async {
        _onTheFakeClock(tester);
        final at = _now(tester) + 8000;
        final far = _now(tester) + const Duration(days: 9).inMilliseconds;
        final server = _Server(
          account: () => _now(tester) < at
              ? cardAccountJson(card: _tiger, expiresAt: at)
              : cardAccountJson(),
          catalogue: () => cardCatalogueJson(
            owned: {if (_now(tester) < at) _tiger.id: at, _hunter.id: far},
          ),
        );
        await http.runWithClient(() async {
          final state = _state(
            screen: screen,
            user: User.fromJson(cardAccountJson(card: _tiger, expiresAt: at)),
            cards: seededCatalogue(owned: {_tiger.id: at, _hunter.id: far}),
          );
          final feedback = FeedbackSettings();
          await _openCards(tester, state, feedback);
          final fox = find
              .descendant(
                of: find.byKey(const ValueKey(royalFoxTileKey)),
                matching: find.byType(CardBackChoice),
              )
              .first;
          expect(
            _kindOf(tester, _tile('Royal Tiger')),
            ShelfBadgeKind.equipped,
          );
          expect(_kindOf(tester, fox), ShelfBadgeKind.owned);
          expect(_kindOf(tester, _tile('Dragon Hunter')), ShelfBadgeKind.owned);

          server.calls.clear();
          await _pumpUntil(tester, at, before: const Duration(milliseconds: 1));
          expect(
            _kindOf(tester, _tile('Royal Tiger')),
            ShelfBadgeKind.equipped,
          );
          expect(server.calls, isEmpty);

          // The moment, the server's answers held: the shelf turns alone.
          server.gate = Completer<void>();
          await tester.pump(const Duration(milliseconds: 1));
          await tester.pump();
          final tiger = _tile('Royal Tiger');
          expect(_kindOf(tester, tiger), ShelfBadgeKind.locked);
          expect(_kindOf(tester, fox), ShelfBadgeKind.equipped);
          expect(tester.widget<CardBackChoice>(fox).selected, isTrue);
          expect(tester.widget<CardBackChoice>(tiger).selected, isFalse);
          expect(_kindOf(tester, _tile('Dragon Hunter')), ShelfBadgeKind.owned);
          await tester.pump(const Duration(milliseconds: 400));
          // The padlock and the price, 5 hammers, and the term again.
          final price = tester.widget<PriceTag>(
            find.descendant(of: tiger, matching: find.byType(PriceTag)),
          );
          expect(price.cost, 5);
          expect(price.currency, PictureCurrency.hammer);
          expect(
            find.descendant(
              of: tiger,
              matching: find.text(_english.rentalTerm(10, 0)),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(of: fox, matching: find.text(_english.cardInUse)),
            findsOneWidget,
          );
          expect(server.catalogueAsked, isTrue, reason: '${server.calls}');

          server.gate!.complete();
          server.gate = null;
          await _answers(tester);
          expect(server.reread, isTrue, reason: '${server.calls}');
          expect(state.user!.cardBackground, isNull);
          expect(_row(state, _tiger).owned, isFalse);
          expect(_kindOf(tester, _tile('Royal Tiger')), ShelfBadgeKind.locked);
          expect(_kindOf(tester, fox), ShelfBadgeKind.equipped);
          expect(tester.takeException(), isNull);
          await _closeStore(tester, state, feedback);
        }, () => server.client);
      });
    }
  });
}
