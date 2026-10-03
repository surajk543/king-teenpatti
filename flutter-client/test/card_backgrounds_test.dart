// Card backs on the wire and in the app's state (owner, 3 Oct 2026: "Add a
// table cards_background which users can buy just like user can buy
// profile_pictures … add one more tab Cards in Store which user can buy …
// keep the price of all cards 5 Hammers validaity 10 days").
//
// What is pinned here, without a screen: the crop, a worn back and a
// catalogue row as the server sends them (tolerant of what it would never
// send); a seat's back and the account's kept through every copy the app
// makes of them; the three REST calls, their bodies, headers and refusals;
// and GameState — the catalogue read with the session's token and its
// pictures kept on the phone's disk, buying (the row owned at once, then
// worn), one purchase at a time, a refusal's reading (a chip-priced back at a
// table in the player's own words), the viewer's own back at a table, the
// rental watch taking a lapsed back off, and sign-out and account deletion
// forgetting it all, the decoded backs with it. The drawing is
// card_back_art_test.dart; the fixtures are shared with the table and the
// store's tests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/api_client.dart';
import 'package:teenpatti/net/app_version.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/widgets/card_back_art.dart';

import 'card_background_fixtures.dart';

/// A GameState that never starts Play: the override keeps the purchase plugin
/// from registering an Android billing client in a unit test.
GameState _state() {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://api.test');
  debugDefaultTargetPlatformOverride = null;
  return state;
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

http.Response _refusal(String code, String message, int status) =>
    _json({'error': code, 'message': message}, status);

/// The server's card-back routes, and the reads a purchase makes around them
/// (the other catalogues and the account), as a fake that keeps a wallet,
/// what is owned and what is worn — and records every call.
class _Server {
  _Server({Map<int, int>? owned, this.hammer = 20, this.chosen})
    : owned = owned ?? {};

  /// Owned backs, id → epoch ms the rental runs out.
  Map<int, int> owned;
  int hammer;
  SeededCard? chosen;

  /// When set, the purchase answers this instead of selling.
  http.Response? refuseBuy;

  /// Called as the catalogue is asked for, before it answers.
  void Function()? onCatalogue;

  final calls = <String>[];
  final bodies = <String, Object?>{};

  static const rentalEnds = 1893456000000; // 2030

  MockClient get client => MockClient(_answer);

  Future<http.Response> _answer(http.Request r) async {
    final call = '${r.method} ${r.url.path}';
    calls.add(call);
    if (r.body.isNotEmpty) bodies[call] = jsonDecode(r.body);
    switch (call) {
      case 'GET /api/card-backgrounds':
        onCatalogue?.call();
        return _json(cardCatalogueJson(owned: owned));
      case 'POST /api/card-backgrounds/buy':
        final refused = refuseBuy;
        if (refused != null) return refused;
        final id = (jsonDecode(r.body) as Map)['cardBackgroundId'] as int;
        final card = seededCards.firstWhere((c) => c.id == id);
        owned = {...owned, id: rentalEnds};
        hammer -= 5;
        return _json({
          'user': cardAccountJson(card: chosen, hammer: hammer),
          'cardBackground': cardBackgroundJson(
            card,
            owned: true,
            expiresAt: rentalEnds,
          ),
          'charged': true,
          'spent': 5,
        });
      case 'POST /api/card-backgrounds/use':
        final id = (jsonDecode(r.body) as Map)['cardBackgroundId'];
        chosen = id == null ? null : seededCards.firstWhere((c) => c.id == id);
        return _json({'user': cardAccountJson(card: chosen, hammer: hammer)});
      case 'GET /api/auth/me':
        return _json({'user': cardAccountJson(card: chosen, hammer: hammer)});
      case 'GET /api/profiles':
        return _json({'profiles': <Object>[]});
      case 'GET /api/table-pictures':
        return _json({'tablePictures': <Object>[]});
      case 'GET /api/emojis':
        return _json({'emojis': <Object>[]});
    }
    return _refusal('not_found', 'Not found', 404);
  }
}

void main() {
  setUp(() {
    // Nothing reaches a disk, and nothing is signed: the catalogue's warm-up
    // fetches nothing in a unit test.
    PictureCache.debugUseDirectory(null);
    PictureCache.debugResetSigning();
  });
  tearDown(() {
    CardBackImages.debugClear();
    PictureCache.clearMemory();
    PictureCache.debugResetSigning();
  });

  final tiger = seededCard('Royal Tiger');
  final demon = seededCard('Brutal Demon');

  group('the wire', () {
    test('a crop is read when it is one, and is nothing when it is not', () {
      expect(
        CardCrop.fromJson({'x': 0.2035, 'y': 0.0805, 'w': 0.6007, 'h': 0.841}),
        const CardCrop(x: 0.2035, y: 0.0805, w: 0.6007, h: 0.841),
      );
      // Whole numbers are numbers: the whole picture is a crop too.
      expect(
        CardCrop.fromJson({'x': 0, 'y': 0, 'w': 1, 'h': 1}),
        const CardCrop(x: 0, y: 0, w: 1, h: 1),
      );
      // The rounding in adding two decimals is not a crop off the picture.
      expect(
        CardCrop.fromJson({'x': 0.7, 'y': 0, 'w': 0.3000000001, 'h': 1}),
        isNotNull,
      );
      for (final raw in <Object?>[
        null,
        'crop',
        [0.1, 0.1, 0.5, 0.7],
        <String, Object?>{},
        {'x': 0.1, 'y': 0.1, 'w': 0.5}, // no height
        {'x': '0.1', 'y': 0.1, 'w': 0.5, 'h': 0.7}, // not a number
        {'x': 0.1, 'y': 0.1, 'w': 0.5, 'h': double.nan},
        {'x': 0.1, 'y': 0.1, 'w': double.infinity, 'h': 0.7},
        {'x': -0.1, 'y': 0.1, 'w': 0.5, 'h': 0.7}, // a corner off the picture
        {'x': 0.1, 'y': -0.01, 'w': 0.5, 'h': 0.7},
        {'x': 0.1, 'y': 0.1, 'w': 0, 'h': 0.7}, // no size
        {'x': 0.1, 'y': 0.1, 'w': 0.5, 'h': -0.7},
        {'x': 0.6, 'y': 0.1, 'w': 0.5, 'h': 0.7}, // past the right edge
        {'x': 0.1, 'y': 0.4, 'w': 0.5, 'h': 0.7}, // past the foot
        {'x': 0.1, 'y': 0.1, 'w': 1.2, 'h': 0.7},
      ]) {
        expect(CardCrop.fromJson(raw), isNull, reason: '$raw');
      }
      // In a picture's pixels.
      expect(
        tiger.crop.rectIn(1024, 1024),
        Rect.fromLTWH(
          0.2291 * 1024,
          0.1262 * 1024,
          0.5417 * 1024,
          0.7584 * 1024,
        ),
      );
    });

    test('every seeded crop is the card\'s own 5:7, inside its picture', () {
      for (final card in seededCards) {
        final rect = card.crop.rectIn(1024, 1024);
        expect(rect.width / rect.height, closeTo(240 / 336, 0.0015));
        expect(rect.right, lessThanOrEqualTo(1024));
        expect(rect.bottom, lessThanOrEqualTo(1024));
        expect(CardCrop.fromJson(cardCropJson(card.crop)), card.crop);
      }
      expect(seededCards.map((c) => c.id).toSet(), hasLength(8));
      expect(seededCards.map((c) => c.sortOrder).toList(), [
        10,
        20,
        30,
        40,
        50,
        60,
        70,
        80,
      ]);
    });

    test('a worn back is read with its row, picture and crop — or is the '
        'Royal Fox', () {
      final art = CardBackArt.fromJson(cardBackJson(tiger))!;
      expect(art.id, tiger.id);
      expect(
        art.url,
        'https://a91cb23b3b93a35dd9ea50db7b855e18.r2.cloudflarestorage.com/'
        'king-teenpatti/cards/Royal%20Tiger.jpg',
      );
      expect(art.crop, tiger.crop);
      expect(art, tiger.art);
      expect(art.hashCode, tiger.art.hashCode);

      // A raster with no format named is still a raster.
      expect(
        CardBackArt.fromJson({'url': tiger.url})?.url,
        tiger.url,
        reason: 'no format, no id, no crop',
      );
      expect(CardBackArt.fromJson({'url': tiger.url})?.id, isNull);
      expect(
        CardBackArt.fromJson({'url': tiger.url, 'assetFormat': 'image'}),
        isNotNull,
      );
      // An unreadable crop is no crop: the whole picture is the card.
      expect(
        CardBackArt.fromJson({
          'id': 7,
          'url': tiger.url,
          'crop': {'x': 0.9, 'y': 0, 'w': 0.5, 'h': 1},
        })?.crop,
        isNull,
      );
      // Nothing to draw is the Royal Fox.
      for (final raw in <Object?>[
        null,
        'Royal Tiger',
        <String, Object?>{},
        {'id': 7},
        {'id': 7, 'url': ''},
        {'id': 7, 'url': '   '},
        {'id': 7, 'url': 42},
        {'id': 7, 'url': tiger.url, 'assetFormat': 'LOTTIE'},
        {'id': 7, 'url': tiger.url, 'assetFormat': 'SVG'},
      ]) {
        expect(CardBackArt.fromJson(raw), isNull, reason: '$raw');
      }
    });

    test('a catalogue row reads every field the contract names', () {
      final row = CardBackground.fromJson(
        cardBackgroundJson(tiger, owned: true, expiresAt: 99),
      );
      expect(row.id, 7);
      expect(row.name, 'Royal Tiger');
      expect(row.url, tiger.url);
      expect(row.assetFormat, 'IMAGE');
      expect(row.crop, tiger.crop);
      expect(row.currency, 'HAMMER');
      expect(row.type, 'PREMIUM');
      expect(row.cost, 5);
      expect(row.durationDays, 10);
      expect(row.durationHours, 0);
      expect(row.sortOrder, 70);
      expect(row.owned, isTrue);
      expect(row.expiresAt, 99);
      expect(row.free, isFalse);
      expect(row.locked, isFalse);
      expect(row.rented, isTrue);
      expect(row.pricedInHammers, isTrue);
      expect(row.pricedInDiamonds, isFalse);
      expect(row.art, tiger.art);

      // The eight, as seeded: 5 hammers for 10 days, none owned yet.
      final catalogue = seededCatalogue();
      expect(catalogue, hasLength(8));
      for (final c in catalogue) {
        expect(c.cost, 5, reason: c.name);
        expect(c.pricedInHammers, isTrue, reason: c.name);
        expect(c.durationDays, 10, reason: c.name);
        expect(c.locked, isTrue, reason: c.name);
        expect(c.crop, isNotNull, reason: c.name);
      }
    });

    test('a sparse row reads as a free IMAGE priced in chips, not owned', () {
      final row = CardBackground.fromJson({
        'id': 3,
        'name': 'Plain',
        'url': '/cards/plain.jpg',
      });
      expect(row.assetFormat, 'IMAGE');
      expect(row.crop, isNull);
      expect(row.currency, 'COIN');
      expect(row.type, 'FREE');
      expect(row.free, isTrue);
      expect(row.cost, 0);
      expect(row.rented, isFalse);
      expect(row.owned, isFalse);
      expect(row.expiresAt, 0);
      expect(row.sortOrder, 0);
      expect(row.art, const CardBackArt(id: 3, url: '/cards/plain.jpg'));
    });

    test('the account keeps its back through every copy a move makes', () {
      final user = User.fromJson(cardAccountJson(card: tiger));
      expect(user.cardBackground, tiger.art);
      expect(user.activeCardBackgroundId, 7);
      expect(user.withHammer(3).cardBackground, tiger.art);
      expect(user.withMissile(0).cardBackground, tiger.art);
      final standing = Standing.maybe({
        'playerLevel': {
          'level': 2,
          'title': 'Rookie',
          'xp': 120,
          'taxBps': 1971,
        },
      })!;
      expect(user.withStanding(standing).cardBackground, tiger.art);
      // None chosen, and a server from before card backs.
      expect(User.fromJson(cardAccountJson()).cardBackground, isNull);
      expect(User.fromJson(cardAccountJson()).activeCardBackgroundId, isNull);
      final older = cardAccountJson()..remove('cardBackground');
      expect(User.fromJson(older).cardBackground, isNull);
    });

    test('every seat carries its own back, absent from an empty chair and '
        'kept when the table redraws a status', () {
      final room = RoomState.fromJson(
        cardRoomJson(
          seats: [
            cardSeatJson(seatIndex: 0, userId: 'me', card: tiger),
            cardSeatJson(seatIndex: 1, card: demon),
            cardSeatJson(seatIndex: 2),
            cardSeatJson(seatIndex: 3, userId: null, status: 'empty'),
          ],
        ),
      );
      expect(room.seats.map((s) => s.cardBackground).toList(), [
        tiger.art,
        demon.art,
        null,
        null,
      ]);
      expect(room.seats[1].withStatus('packed').cardBackground, demon.art);
      // The key absent and the key null read alike.
      expect(
        Seat.fromJson({
          ...cardSeatJson(seatIndex: 2),
          'cardBackground': null,
        }).cardBackground,
        isNull,
      );
    });
  });

  group('the routes', () {
    test('GET /api/card-backgrounds sends the token and the build, and reads '
        'the rows', () async {
      late http.Request seen;
      final client = MockClient((r) async {
        seen = r;
        return _json(cardCatalogueJson(owned: {7: 1234}));
      });
      final api = ApiClient('http://api.test')
        ..appPlatform = 'android'
        ..appVersion = '1.11.0';
      final rows = await http.runWithClient(
        () => api.cardBackgrounds('tok'),
        () => client,
      );
      expect(seen.method, 'GET');
      expect(seen.url.toString(), 'http://api.test/api/card-backgrounds');
      expect(seen.headers['Authorization'], 'Bearer tok');
      expect(seen.headers[appPlatformHeader], 'android');
      expect(seen.headers[appVersionHeader], '1.11.0');
      expect(rows.map((c) => c.name).toList(), [
        for (final c in seededCards) c.name,
      ]);
      expect(rows.where((c) => c.owned).single.id, 7);
      expect(rows.firstWhere((c) => c.id == 7).expiresAt, 1234);
    });

    test('without a token it is anonymous, and a server from before card '
        'backs is an empty catalogue', () async {
      final auth = <String?>[];
      var status = 200;
      final client = MockClient((r) async {
        auth.add(r.headers['Authorization']);
        return status == 404
            ? _refusal('not_found', 'Not found', 404)
            : _json({'cardBackgrounds': null});
      });
      final api = ApiClient('http://api.test');
      expect(
        await http.runWithClient(api.cardBackgrounds, () => client),
        isEmpty,
        reason: 'a null list is no rows',
      );
      status = 404;
      expect(
        await http.runWithClient(() => api.cardBackgrounds('t'), () => client),
        isEmpty,
      );
      expect(auth, [null, 'Bearer t']);
    });

    test(
      'POST use sends the id, or null to go back to the Royal Fox',
      () async {
        final bodies = <Object?>[];
        final paths = <String>[];
        final client = MockClient((r) async {
          paths.add('${r.method} ${r.url.path}');
          final body = jsonDecode(r.body) as Map;
          bodies.add(body);
          final id = body['cardBackgroundId'] as int?;
          return _json({
            'user': cardAccountJson(card: id == null ? null : tiger),
          });
        });
        final api = ApiClient('http://api.test');
        final worn = await http.runWithClient(
          () => api.useCardBackground('tok', 7),
          () => client,
        );
        expect(worn.cardBackground, tiger.art);
        final off = await http.runWithClient(
          () => api.useCardBackground('tok', null),
          () => client,
        );
        expect(off.cardBackground, isNull);
        expect(paths, everyElement('POST /api/card-backgrounds/use'));
        expect(bodies, [
          {'cardBackgroundId': 7},
          {'cardBackgroundId': null},
        ]);
      },
    );

    test('POST buy sends the id and reads the wallet, the row and whether it '
        'charged', () async {
      final server = _Server(hammer: 20);
      final r = await http.runWithClient(
        () => ApiClient('http://api.test').buyCardBackground('tok', 7),
        () => server.client,
      );
      expect(server.bodies['POST /api/card-backgrounds/buy'], {
        'cardBackgroundId': 7,
      });
      expect(r.charged, isTrue);
      expect(r.spent, 5);
      expect(r.user.hammer, 15);
      expect(r.cardBackground?.id, 7);
      expect(r.cardBackground?.owned, isTrue);
      expect(r.cardBackground?.expiresAt, _Server.rentalEnds);

      // Already owned and running: nothing charged.
      final again = await http.runWithClient(
        () => ApiClient('http://api.test').buyCardBackground('tok', 7),
        () => MockClient(
          (_) async => _json({
            'user': cardAccountJson(hammer: 15),
            'charged': false,
            'spent': 0,
          }),
        ),
      );
      expect(again.charged, isFalse);
      expect(again.spent, 0);
      expect(again.cardBackground, isNull, reason: 'no row in the answer');
    });

    for (final (code, status) in [
      ('unknown_card_background', 400),
      ('picture_retired', 400),
      ('picture_free', 400),
      ('picture_locked', 403),
      ('picture_chips', 409),
      ('seated', 409),
    ]) {
      test('a refusal arrives with its code: $code', () async {
        final client = MockClient(
          (_) async => _refusal(code, 'The server says no.', status),
        );
        final api = ApiClient('http://api.test');
        final refused = isA<ApiException>()
            .having((e) => e.code, 'code', code)
            .having((e) => e.status, 'status', status)
            .having((e) => e.message, 'message', 'The server says no.');
        await expectLater(
          http.runWithClient(() => api.buyCardBackground('t', 7), () => client),
          throwsA(refused),
        );
        await expectLater(
          http.runWithClient(() => api.useCardBackground('t', 7), () => client),
          throwsA(refused),
        );
      });
    }
  });

  group('GameState', () {
    test('the catalogue is read with the token, and an answer for a session '
        'that has ended is dropped', () async {
      final server = _Server(owned: {7: _Server.rentalEnds});
      final state = _state()..debugToken = 'tok';
      await http.runWithClient(
        state.reloadCardBackgrounds,
        () => server.client,
      );
      expect(state.cardBackgrounds, hasLength(8));
      expect(state.cardBackgrounds.where((c) => c.owned).single.id, 7);

      // Asked under one token, answered after another signed in: dropped.
      final gate = Completer<void>();
      final slow = MockClient((r) async {
        await gate.future;
        return _json(cardCatalogueJson());
      });
      final load = http.runWithClient(state.reloadCardBackgrounds, () => slow);
      state.debugToken = 'somebody-else';
      gate.complete();
      await load;
      expect(
        state.cardBackgrounds.where((c) => c.owned).single.id,
        7,
        reason: 'the other session\'s answer was not taken',
      );
      state.dispose();
    });

    test('buying marks the row owned at once, wears it, and reads the '
        'catalogue again', () async {
      final server = _Server(hammer: 20);
      final state = _state()
        ..debugToken = 'tok'
        ..user = User.fromJson(cardAccountJson(hammer: 20))
        ..cardBackgrounds = seededCatalogue();
      bool? ownedWhenReread;
      server.onCatalogue = () => ownedWhenReread ??= state.cardBackgrounds
          .firstWhere((c) => c.id == 7)
          .owned;
      final busy = <int?>[];
      state.addListener(() => busy.add(state.buyingCardBackground));

      final result = await http.runWithClient(
        () => state.buyCardBackground(7),
        () => server.client,
      );
      await pumpEventQueue();

      expect(result, PictureBuyResult.bought);
      expect(server.calls.first, 'POST /api/card-backgrounds/buy');
      expect(server.calls, contains('GET /api/card-backgrounds'));
      expect(
        server.calls.indexOf('POST /api/card-backgrounds/use'),
        greaterThan(server.calls.indexOf('GET /api/auth/me')),
        reason: 'worn once the account and the shelves are read again',
      );
      expect(server.bodies['POST /api/card-backgrounds/use'], {
        'cardBackgroundId': 7,
      });
      expect(ownedWhenReread, isTrue, reason: 'the padlock went at once');
      expect(state.cardBackgrounds.firstWhere((c) => c.id == 7).owned, isTrue);
      expect(state.user!.hammer, 15);
      expect(state.chosenCardBack, tiger.art);
      expect(state.user!.activeCardBackgroundId, 7);
      expect(busy.first, 7, reason: 'the tile spun while it was bought');
      expect(state.buyingCardBackground, isNull);
      state.dispose();
    });

    test('one purchase at a time', () async {
      final gate = Completer<void>();
      final server = _Server();
      final client = MockClient((r) async {
        if (r.url.path == '/api/card-backgrounds/buy') await gate.future;
        return server._answer(r);
      });
      final state = _state()
        ..debugToken = 'tok'
        ..user = User.fromJson(cardAccountJson())
        ..cardBackgrounds = seededCatalogue();
      final first = http.runWithClient(
        () => state.buyCardBackground(7),
        () => client,
      );
      expect(state.buyingCardBackground, 7);
      expect(
        await http.runWithClient(
          () => state.buyCardBackground(1),
          () => client,
        ),
        PictureBuyResult.refused,
      );
      gate.complete();
      expect(await first, PictureBuyResult.bought);
      expect(
        server.calls.where((c) => c == 'POST /api/card-backgrounds/buy'),
        hasLength(1),
      );
      // Signed out, nothing is bought.
      state.debugToken = null;
      expect(await state.buyCardBackground(1), PictureBuyResult.refused);
      state.dispose();
    });

    test('a hammer or diamond shortage is the offer of that shelf; a '
        'chip-priced back refused at a table is said in the player\'s '
        'language; anything else is the server\'s sentence', () async {
      final state = _state()
        ..cardBackgrounds = [
          ...seededCatalogue(),
          CardBackground.fromJson(
            cardBackgroundJson(seededCard('Demon Hell'), currency: 'DIAMOND')
              ..['id'] = 20,
          ),
          CardBackground.fromJson(
            cardBackgroundJson(seededCard('Royal Lion'), currency: 'COIN')
              ..['id'] = 30,
          ),
        ];
      final short = ApiException(
        'You need 5 hammers to unlock this card back.',
        code: 'picture_chips',
        status: 409,
      );
      expect(state.cardBackgroundRefused(7, short), PictureBuyResult.notEnough);
      expect(
        state.cardBackgroundRefused(20, short),
        PictureBuyResult.notEnough,
      );
      expect(state.notice, isNull, reason: 'the offer says it, not a toast');
      // Chips are no shelf's to refill: the server's sentence.
      expect(state.cardBackgroundRefused(30, short), PictureBuyResult.refused);
      expect(state.notice, short.message);
      // A chip-priced back at a table — seated, leaving one, or a last hand
      // still being saved — in the player's words, as the shelf says it
      // before asking, never the server's English.
      final seated = ApiException(
        'You can only buy a chip-priced card back in the lobby.',
        code: 'seated',
        status: 409,
      );
      expect(state.cardBackgroundRefused(30, seated), PictureBuyResult.refused);
      expect(state.notice, state.t.cardChipsLobbyOnly);
      state.lang = AppLang.hindi;
      expect(state.cardBackgroundRefused(30, seated), PictureBuyResult.refused);
      expect(state.notice, const Strings(AppLang.hindi).cardChipsLobbyOnly);
      expect(state.notice, isNot(seated.message));
      state.lang = AppLang.english;
      // A row this phone does not hold is no shelf to offer.
      expect(state.cardBackgroundRefused(99, short), PictureBuyResult.refused);

      // Through the purchase itself.
      final server = _Server()
        ..refuseBuy = _refusal('picture_chips', short.message, 409);
      state.debugToken = 'tok';
      state.notice = null;
      expect(
        await http.runWithClient(
          () => state.buyCardBackground(7),
          () => server.client,
        ),
        PictureBuyResult.notEnough,
      );
      expect(state.buyingCardBackground, isNull);
      expect(server.calls, isNot(contains('POST /api/card-backgrounds/use')));
      server.refuseBuy = _refusal(
        'picture_retired',
        'That card back is no longer available.',
        400,
      );
      expect(
        await http.runWithClient(
          () => state.buyCardBackground(7),
          () => server.client,
        ),
        PictureBuyResult.refused,
      );
      expect(state.notice, 'That card back is no longer available.');
      // No server at all.
      expect(
        await http.runWithClient(
          () => state.buyCardBackground(7),
          () => MockClient((_) async => throw http.ClientException('offline')),
        ),
        PictureBuyResult.refused,
      );
      expect(state.notice, 'Could not reach the server.');
      await pumpEventQueue();
      state.dispose();
    });

    test(
      'choosing null goes back to the Royal Fox, and a refusal is said',
      () async {
        final server = _Server(owned: {7: _Server.rentalEnds}, chosen: tiger);
        final state = _state()
          ..debugToken = 'tok'
          ..user = User.fromJson(cardAccountJson(card: tiger));
        expect(state.chosenCardBack, tiger.art);
        await http.runWithClient(
          () => state.chooseCardBackground(null),
          () => server.client,
        );
        expect(server.bodies['POST /api/card-backgrounds/use'], {
          'cardBackgroundId': null,
        });
        expect(state.chosenCardBack, isNull);

        await http.runWithClient(
          () => state.chooseCardBackground(1),
          () => MockClient(
            (_) async => _refusal(
              'picture_locked',
              'Unlock that card back before you can use it.',
              403,
            ),
          ),
        );
        expect(state.notice, 'Unlock that card back before you can use it.');
        expect(state.chosenCardBack, isNull, reason: 'nothing changed');
        await pumpEventQueue();
        state.dispose();
      },
    );

    test('the viewer\'s own cards wear their seat\'s back — the Royal Fox at '
        'a poker room or away from a table', () {
      final state = _state()..user = User.fromJson(cardAccountJson());
      expect(state.ownCardBack, isNull, reason: 'no table');
      final seats = [
        cardSeatJson(seatIndex: 0, card: demon),
        cardSeatJson(seatIndex: 2, userId: 'me', card: tiger),
      ];
      state.room = RoomState.fromJson(cardRoomJson(seats: seats, youSeat: 2));
      expect(state.ownCardBack, tiger.art);
      state.room = RoomState.fromJson(
        cardRoomJson(
          seats: [
            seats[0],
            cardSeatJson(seatIndex: 2, userId: 'me'),
          ],
          youSeat: 2,
        ),
      );
      expect(state.ownCardBack, isNull, reason: 'their seat wears none');
      state.room = RoomState.fromJson(
        cardRoomJson(seats: seats, youSeat: 2, game: 'poker'),
      );
      expect(state.ownCardBack, isNull, reason: 'a poker room');
      final watching = cardRoomJson(seats: seats)..remove('you');
      state.room = RoomState.fromJson(watching);
      expect(state.ownCardBack, isNull, reason: 'not seated');
      state.dispose();
    });

    test('the rental watch reads the catalogue and the account while the '
        'chosen back can lapse, and takes it off once it has', () async {
      // The rental has run out: the server's catalogue no longer has it
      // owned, and its account comes back with no back.
      final server = _Server();
      final state = _state()
        ..debugToken = 'tok'
        ..screen = Screen.lobby
        ..user = User.fromJson(cardAccountJson(card: tiger))
        ..cardBackgrounds = seededCatalogue(owned: {7: 1000});
      await http.runWithClient(state.checkRental, () => server.client);
      await pumpEventQueue();
      expect(
        server.calls,
        containsAll(['GET /api/card-backgrounds', 'GET /api/auth/me']),
      );
      expect(state.chosenCardBack, isNull);
      expect(state.cardBackgrounds.firstWhere((c) => c.id == 7).locked, isTrue);
      state.dispose();
    });

    test('the rental watch makes no call when nothing chosen can lapse, nor '
        'away from the lobby', () async {
      final server = _Server();
      final free = CardBackground.fromJson(
        cardBackgroundJson(
          tiger,
          type: 'FREE',
          cost: 0,
          durationDays: 0,
          owned: true,
        ),
      );
      final state = _state()
        ..debugToken = 'tok'
        ..screen = Screen.lobby
        ..user = User.fromJson(cardAccountJson(card: tiger))
        ..cardBackgrounds = [free];
      await http.runWithClient(state.checkRental, () => server.client);
      expect(server.calls, isEmpty, reason: 'a free back never lapses');

      state.user = User.fromJson(cardAccountJson());
      await http.runWithClient(state.checkRental, () => server.client);
      expect(server.calls, isEmpty, reason: 'nothing chosen');

      state
        ..user = User.fromJson(cardAccountJson(card: tiger))
        ..cardBackgrounds = seededCatalogue(owned: {7: _Server.rentalEnds})
        ..screen = Screen.table;
      await http.runWithClient(state.checkRental, () => server.client);
      expect(server.calls, isEmpty, reason: 'at a table');
      state.dispose();
    });

    test(
      'the catalogue\'s pictures are kept on the phone\'s disk, signed in '
      'one request — never warmed into the memory the faces live in',
      () async {
        final dir = Directory.systemTemp.createTempSync('card-backs');
        addTearDown(() => dir.deleteSync(recursive: true));
        PictureCache.debugUseDirectory(dir);
        final signings = <List<String>>[];
        PictureCache.signer = (locations) async {
          signings.add(locations);
          return SignedAssets({
            for (final l in locations)
              l: 'https://signed.test/${Uri.parse(l).pathSegments.last}',
          }, DateTime.now().add(const Duration(minutes: 10)));
        };
        final server = _Server();
        final png = await cardPicturePng(tiger.crop, card: tiger.colour);
        final client = MockClient((r) async {
          if (r.url.host == 'signed.test') {
            return http.Response.bytes(
              png,
              200,
              headers: {'content-type': 'image/png'},
            );
          }
          return server._answer(r);
        });
        List<File> kept() => [
          for (final f in dir.listSync())
            if (f is File && !f.path.endsWith('.part')) f,
        ];
        final state = _state()..debugToken = 'tok';
        await http.runWithClient(() async {
          await state.reloadCardBackgrounds();
          // Kept by itself, one after another, after the catalogue is read.
          for (var i = 0; i < 300 && kept().length < seededCards.length; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        }, () => client);
        expect(state.cardBackgrounds, hasLength(seededCards.length));
        expect(kept(), hasLength(seededCards.length), reason: 'every back');
        expect(signings, hasLength(1), reason: 'one signing for the lot');
        expect(signings.single.toSet(), {for (final c in seededCards) c.url});
        for (final card in seededCards) {
          expect(
            PictureCache.peek(card.url),
            isNull,
            reason: '${card.name} pushed no face out of memory',
          );
        }
        state.dispose();
      },
    );

    test('signing out forgets the backs this account owns, and lets go of '
        'the backs decoded for it', () async {
      SharedPreferences.setMockInitialValues({'token': 'tok'});
      PictureCache.prime(
        tiger.url,
        await cardPicturePng(tiger.crop, card: tiger.colour),
      );
      expect(await CardBackImages.load(tiger.art), isNotNull);
      expect(CardBackImages.debugCount, 1);
      final state = _state()
        ..debugToken = 'tok'
        ..user = User.fromJson(cardAccountJson(card: tiger))
        ..cardBackgrounds = seededCatalogue(owned: {7: _Server.rentalEnds})
        ..buyingCardBackground = 3;
      await state.signOut();
      expect(state.cardBackgrounds, isEmpty);
      expect(state.buyingCardBackground, isNull);
      expect(state.chosenCardBack, isNull);
      expect(CardBackImages.debugCount, 0);
      state.dispose();
    });

    test('deleting the account forgets them too', () async {
      SharedPreferences.setMockInitialValues({'token': 'tok'});
      PictureCache.prime(
        tiger.url,
        await cardPicturePng(tiger.crop, card: tiger.colour),
      );
      expect(await CardBackImages.load(tiger.art), isNotNull);
      final state = _state()
        ..debugToken = 'tok'
        ..user = User.fromJson(cardAccountJson(card: tiger))
        ..cardBackgrounds = seededCatalogue(owned: {7: _Server.rentalEnds});
      final refused = await http.runWithClient(
        state.deleteAccount,
        () => MockClient((_) async => _json({'deleted': true})),
      );
      expect(refused, isNull);
      expect(state.cardBackgrounds, isEmpty);
      expect(state.chosenCardBack, isNull);
      expect(CardBackImages.debugCount, 0);
      state.dispose();
    });
  });
}
