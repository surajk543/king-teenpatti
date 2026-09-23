// Table pictures (owner, 15 Sep 2026): the cloth a player lays on their own
// table, in a day file and a night file. The catalogue row and the laid pair
// on the account are read; the felt picks the file the theme wants; the shelf
// orders free → chips → hammers → diamonds; the unlock question names the
// price in its wallet's word; and every new word is written in all five
// languages.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/api_client.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/widgets/table_picture_shelf.dart';

/// Every new key, with the placeholders its text must keep.
const _keys = <String, List<String>>{
  'storeTabTables': [],
  'storeTablesTitle': [],
  'storeTablesBlurb': [],
  'tableDefault': [],
  'tableDefaultHint': [],
  'tableInUse': [],
  'unlockTableTitle': [],
  'unlockTableBody': ['{name}', '{price}'],
  'unlockTableRentBody': ['{name}', '{price}', '{time}'],
  'tableChipsLobbyOnly': [],
  'priceChips': ['{cost}'],
  'priceDiamonds': ['{cost}'],
  'priceHammers': ['{cost}'],
  'priceHammerOne': [],
  'priceDiamondOne': [],
  'tablePokerNote': [],
};

TablePicture _row({
  int id = 3,
  String name = 'Royal Sapphire',
  String currency = 'COIN',
  String type = 'PREMIUM',
  int cost = 50000,
  int days = 7,
  int hours = 0,
  bool owned = false,
}) => TablePicture.fromJson({
  'id': id,
  'name': name,
  'dayUrl': '/tables/royal-sapphire-day.svg',
  'nightUrl': '/tables/royal-sapphire-night.svg',
  'assetFormat': 'SVG',
  'currency': currency,
  'type': type,
  'cost': cost,
  'durationDays': days,
  'durationHours': hours,
  'owned': owned,
  'expiresAt': 0,
});

Map<String, dynamic> _user({Map<String, dynamic>? tablePicture}) => {
  'id': 'u1',
  'provider': 'guest',
  'displayName': 'Guest',
  'email': null,
  'avatarUrl': null,
  'providerAvatarUrl': null,
  'activePictureId': null,
  'tablePicture': tablePicture,
  'chips': 300000,
  'diamond': 9,
  'hammer': 20,
  'missile': 1,
  'handsPlayed': 0,
  'handsWon': 0,
  'handsLost': 0,
  'handsLeftMid': 0,
  'totalWinnings': 0,
  'biggestPot': 0,
};

/// A GameState that never starts Play: the override keeps the purchase plugin
/// from registering an Android billing client in a unit test.
GameState _gameState() {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://example.test');
  debugDefaultTargetPlatformOverride = null;
  return state;
}

void main() {
  const english = Strings(AppLang.english);

  test('a catalogue row carries both files and the profile rules', () {
    final row = _row();
    expect(row.dayUrl, '/tables/royal-sapphire-day.svg');
    expect(row.nightUrl, '/tables/royal-sapphire-night.svg');
    expect(row.forBrightness(Brightness.light), row.dayUrl);
    expect(row.forBrightness(Brightness.dark), row.nightUrl);
    expect(row.free, isFalse);
    expect(row.locked, isTrue);
    expect(row.rented, isTrue);
    expect(row.pricedInDiamonds, isFalse);
    expect(_row(currency: 'HAMMER').pricedInHammers, isTrue);
    expect(_row(type: 'FREE', cost: 0, days: 0, owned: true).free, isTrue);
    // A server that sends no type or hours reads as a free, day-rented row.
    final bare = TablePicture.fromJson({
      'id': 1,
      'name': 'Classic Baize',
      'dayUrl': 'a',
      'nightUrl': 'b',
      'owned': true,
    });
    expect(bare.free, isTrue);
    expect(bare.durationHours, 0);
    expect(bare.assetFormat, 'IMAGE');
  });

  test('the account carries the laid pair, or null for the table as it comes', () {
    final bare = User.fromJson(_user());
    expect(bare.tablePicture, isNull);
    expect(bare.activeTablePictureId, isNull);

    final laid = User.fromJson(
      _user(
        tablePicture: {
          'id': 3,
          'dayUrl': '/tables/royal-sapphire-day.svg',
          'nightUrl': '/tables/royal-sapphire-night.svg',
          'assetFormat': 'SVG',
        },
      ),
    );
    expect(laid.activeTablePictureId, 3);
    expect(laid.tablePicture!.forBrightness(Brightness.dark), endsWith('night.svg'));
    // The pair survives the wallet copies a Force Sideshow and a missile make.
    expect(laid.withHammer(19).tablePicture?.id, 3);
    expect(laid.withMissile(0).tablePicture?.id, 3);
    // An older server sends no tablePicture at all.
    final older = _user()..remove('tablePicture');
    expect(User.fromJson(older).tablePicture, isNull);
  });

  test('the felt draws the table\'s picture, day file by day, night by night', () {
    final state = _gameState();
    expect(state.tablePictureUrl(Brightness.dark), isNull);
    // The viewer's own choice on its own draws nothing: the table decides.
    state.user = User.fromJson(
      _user(
        tablePicture: {
          'id': 3,
          'dayUrl': '/tables/mine-day.svg',
          'nightUrl': '/tables/mine-night.svg',
        },
      ),
    );
    expect(state.laidTablePicture?.id, 3);
    expect(state.shownTablePicture, isNull);
    expect(state.tablePictureUrl(Brightness.light), isNull);

    // What the table shows — here another player's, which outranked mine —
    // is what is drawn, tagged with who laid it.
    state.room = RoomState.fromJson({
      'roomId': 'r1',
      'code': 'ABCD2345',
      'category': 'blind',
      'state': 'waiting',
      'seats': [],
      'tablePicture': {
        'id': 9,
        'dayUrl': '/tables/theirs-day.svg',
        'nightUrl': 'https://cdn.example/theirs-night.png',
        'assetFormat': 'LOTTIE',
        'currency': 'DIAMOND',
        'cost': 5,
        'userId': 'u2',
      },
    });
    expect(state.shownTablePicture?.id, 9);
    expect(state.shownTablePicture?.userId, 'u2');
    expect(state.shownTablePicture?.assetFormat, 'LOTTIE');
    expect(
      state.tablePictureUrl(Brightness.light),
      'http://example.test/tables/theirs-day.svg',
    );
    expect(
      state.tablePictureUrl(Brightness.dark),
      'https://cdn.example/theirs-night.png',
    );
    // A table where nobody has laid one sends null, and the chips are back.
    state.room = RoomState.fromJson({
      'roomId': 'r1',
      'code': 'ABCD2345',
      'category': 'blind',
      'state': 'waiting',
      'seats': [],
      'tablePicture': null,
    });
    expect(state.shownTablePicture, isNull);
    state.dispose();
  });

  testWidgets(
    'a tile\'s two grounds fill its height, the pale one left and the dark one right',
    (tester) async {
      // A childless DecoratedBox has no height of its own: without the row
      // stretching its halves both grounds laid out at zero height and painted
      // nothing, and the day half of every tile sat on the store's dark
      // backdrop (the emulator, 23 Sep 2026).
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 200,
              height: 112,
              child: TablePicturePreview(
                dayUrl: 'http://example.test/tables/d.svg',
                nightUrl: 'http://example.test/tables/n.svg',
                format: 'SVG',
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final grounds = find.descendant(
        of: find.byType(TablePicturePreview),
        matching: find.byType(DecoratedBox),
      );
      expect(grounds, findsNWidgets(2));
      final boxes = grounds.evaluate().map((e) => e.renderObject! as RenderBox).toList();
      for (final box in boxes) {
        expect(box.size.height, 112);
        expect(box.size.width, 100);
      }
      final left = boxes[0].localToGlobal(Offset.zero).dx;
      final right = boxes[1].localToGlobal(Offset.zero).dx;
      expect(right - left, 100, reason: 'the pale ground is the left half, the dark one the right');
      final decorations = grounds
          .evaluate()
          .map((e) => (e.widget as DecoratedBox).decoration as BoxDecoration)
          .toList();
      final pale = decorations[0];
      final dark = decorations[1];
      expect((pale.gradient! as LinearGradient).colors.first.computeLuminance(), greaterThan(0.8));
      expect((dark.gradient! as LinearGradient).colors.first.computeLuminance(), lessThan(0.01));
      // Let the cache's directory lookup and the fetch it starts run out
      // (they fail here: no plugin, no network), then unmount so the retry
      // the box arms after a failed fetch is cancelled with it.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'on the felt a banner-shaped picture is drawn above the plinth, a square one around the pot',
    (tester) async {
      // Welcome (428x123) fitted whole into the square centred on the pot was
      // a strip under the plinth (TP_Tall, 23 Sep 2026): a banner now stands
      // in the band above it, across the square's width.
      Uint8List lottie(int w, int h) => Uint8List.fromList(
        utf8.encode('{"v":"5.5.3","fr":25,"ip":0,"op":10,"w":$w,"h":$h,"nm":"x","layers":[]}'),
      );
      PictureCache.prime('http://example.test/tables/banner.json', lottie(428, 123));
      PictureCache.prime('http://example.test/tables/square.json', lottie(1500, 1500));
      for (final (url, banner) in [
        ('http://example.test/tables/banner.json', true),
        ('http://example.test/tables/square.json', false),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 300,
                height: 300,
                child: TablePictureGround(url: url, format: 'LOTTIE'),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(AspectRatio), banner ? findsOneWidget : findsNothing, reason: url);
        if (banner) {
          final strip = tester.getRect(find.byType(AspectRatio));
          expect(strip.width, 300);
          expect(strip.height, closeTo(300 * 123 / 428, 0.5));
          final pot = tester.getCenter(find.byType(TablePictureGround)).dy;
          expect(strip.center.dy, lessThan(pot - 0.25 * 150), reason: 'the banner sits above the pot');
          expect(strip.top, greaterThan(pot - 150), reason: 'and inside the square');
        }
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpWidget(const SizedBox());
      }
      PictureCache.clearMemory();
    },
  );

  test('a near-square canvas covers its box, a banner is fitted whole', () {
    expect(pictureFitFor(1.0), BoxFit.cover);
    expect(pictureFitFor(1.5), BoxFit.cover, reason: 'Background Pattern, 1500×1000');
    expect(pictureFitFor(1 / 1.5), BoxFit.cover);
    expect(pictureFitFor(428 / 123), BoxFit.contain, reason: 'Welcome, one word on a banner');
    expect(pictureFitFor(1920 / 1080), BoxFit.cover, reason: 'Circle Background Pattern, a 16:9 scene');
    expect(pictureFitFor(2.01), BoxFit.contain);
    expect(pictureFitFor(0.4), BoxFit.contain, reason: 'a column past 1:2');
    expect(pictureFitFor(0.5), BoxFit.cover, reason: 'exactly 1:2 still covers');
    expect(pictureFitFor(null), BoxFit.cover, reason: 'a canvas the head does not give');
  });

  test('the shelf runs free, then chips, hammers and diamonds, cheapest first', () {
    final ordered = tableShelfOrder([
      _row(id: 8, name: 'Royal Purple', currency: 'DIAMOND', cost: 5),
      _row(id: 7, name: 'Carbon Weave', currency: 'HAMMER', cost: 40),
      _row(id: 5, name: 'Sunset Marble', cost: 10000000),
      _row(id: 3, name: 'Royal Sapphire', cost: 50000),
      _row(id: 6, name: 'Emerald Lattice', currency: 'HAMMER', cost: 20),
      _row(id: 2, name: 'Oxblood Club', type: 'FREE', cost: 0, owned: true),
      _row(id: 4, name: 'Midnight Gold', cost: 200000),
      _row(id: 1, name: 'Classic Baize', type: 'FREE', cost: 0, owned: true),
    ]);
    expect(ordered.map((p) => p.id).toList(), [2, 1, 3, 4, 5, 6, 7, 8]);
  });

  test('the unlock question names the price in its wallet, and the term', () {
    expect(
      unlockTableBody(english, _row()),
      'Royal Sapphire costs 50,000 chips and dresses your table for 7 days. '
      'Unlock it and use it now?',
    );
    expect(
      unlockTableBody(english, _row(currency: 'DIAMOND', cost: 5, days: 100)),
      startsWith('Royal Sapphire costs 5 diamonds and dresses your table for 100 days.'),
    );
    expect(
      unlockTableBody(english, _row(currency: 'DIAMOND', cost: 1, days: 0)),
      'Royal Sapphire costs 1 diamond. Unlock it and use it now?',
    );
    expect(
      unlockTableBody(english, _row(currency: 'HAMMER', cost: 1, days: 0)),
      'Royal Sapphire costs 1 hammer. Unlock it and use it now?',
    );
    expect(
      unlockTableBody(english, _row(currency: 'HAMMER', cost: 20, days: 20)),
      startsWith('Royal Sapphire costs 20 hammers and dresses your table for 20 days.'),
    );
  });

  test('a refused table purchase is read as the picture shelf reads it', () {
    final state = _gameState();
    state.tablePictures = [
      _row(id: 6, currency: 'HAMMER', cost: 20),
      _row(id: 3),
    ];
    expect(
      state.tablePictureRefused(6, ApiException('short', code: 'picture_chips')),
      PictureBuyResult.notEnough,
    );
    expect(
      state.tablePictureRefused(3, ApiException('short', code: 'picture_chips')),
      PictureBuyResult.refused,
    );
    expect(state.notice, 'short');
    expect(
      state.tablePictureRefused(3, ApiException('x', code: 'seated')),
      PictureBuyResult.refused,
    );
    expect(state.notice, english.tableChipsLobbyOnly);
    state.dispose();
  });

  for (final lang in AppLang.values) {
    test('every table word is written in ${lang.englishName}', () {
      final t = Strings(lang);
      for (final MapEntry(key: key, value: placeholders) in _keys.entries) {
        final own = t.ownEntry(key);
        expect(own, isNotNull, reason: '${lang.code} has no "$key"');
        expect(own!.trim(), isNotEmpty, reason: '${lang.code} "$key"');
        for (final placeholder in placeholders) {
          expect(own, contains(placeholder), reason: '${lang.code} "$key"');
        }
        if (lang != AppLang.english) {
          expect(
            own,
            isNot(english.ownEntry(key)),
            reason: '${lang.code} "$key" is the English left in place',
          );
        }
      }
    });
  }
}
