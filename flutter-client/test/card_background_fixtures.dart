// The card backs as the server seeds them (owner, 3 Oct 2026: "Add a table
// cards_background which users can buy just like user can buy
// profile_pictures … keep the price of all cards 5 Hammers validaity 10
// days"), for every card-back test: the eight rows of `GET
// /api/card-backgrounds` with the crops measured for them, a seat, a table
// and an account wearing one — and the pictures themselves in miniature, so
// a widget test can draw a back without the bucket.
//
// Drawing a back in a widget test: decoding is real work a widget test's fake
// clock never finishes, so prime the backs first —
//
//   await primeCardBacks(tester, [seededCard('Royal Tiger')]);
//   await tester.pumpWidget(...);   // the cards show it on the first frame
//
// — and call forgetCardBacks() in tearDown. A back that is not primed draws
// the bundled Royal Fox and fetches nothing (no signer is wired in a test).
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/widgets/card_back_art.dart';

/// The bucket the art is in, path-style on the account's S3 endpoint.
const cardBucket =
    'https://a91cb23b3b93a35dd9ea50db7b855e18.r2.cloudflarestorage.com/king-teenpatti';

/// [key]'s location as the database stores it: the bucket's path with the
/// key's spaces written `%20`, the only escape.
String cardLocation(String key) => '$cardBucket/${key.replaceAll(' ', '%20')}';

/// One seeded card back: the row's id on a fresh database (the seed's
/// order), its place, name, key in the bucket and the card's crop in the
/// 1024x1024 picture.
class SeededCard {
  const SeededCard(
    this.id,
    this.sortOrder,
    this.name,
    this.key,
    this.crop,
    this.colour,
  );

  final int id;
  final int sortOrder;
  final String name;
  final String key;
  final CardCrop crop;

  /// What [cardPicturePng] paints this card's rectangle in — one colour per
  /// back, so a test can tell which back a card wears by a pixel.
  final Color colour;

  /// The location the database stores.
  String get url => cardLocation(key);

  /// The back as a seat or the account carries it.
  CardBackArt get art => CardBackArt(id: id, url: url, crop: crop);

  /// The back as a seat or the account carries a rental of it that runs out
  /// at [expiresAt] (epoch ms).
  CardBackArt artUntil(int expiresAt) =>
      CardBackArt(id: id, url: url, crop: crop, expiresAt: expiresAt);
}

/// The eight backs on sale, in the seed's order: PREMIUM, 5 hammers, 10
/// days each.
const seededCards = <SeededCard>[
  SeededCard(
    1,
    10,
    'Brutal Demon',
    'cards/Brutal Demon.jpg',
    CardCrop(x: 0.2035, y: 0.0805, w: 0.6007, h: 0.8410),
    Color(0xFFD32F2F),
  ),
  SeededCard(
    2,
    20,
    'Demon Hell',
    'cards/Demon Hell.jpg',
    CardCrop(x: 0.2203, y: 0.1167, w: 0.5594, h: 0.7831),
    Color(0xFF7B1FA2),
  ),
  SeededCard(
    3,
    30,
    'Dragon Hunter',
    'cards/Dragon Hunter.jpg',
    CardCrop(x: 0.2073, y: 0.0880, w: 0.5844, h: 0.8182),
    Color(0xFF388E3C),
  ),
  SeededCard(
    4,
    40,
    'Royal Lion',
    'cards/Royal Lion.jpg',
    CardCrop(x: 0.2065, y: 0.0948, w: 0.5851, h: 0.8192),
    Color(0xFFFBC02D),
  ),
  SeededCard(
    5,
    50,
    'Royal Majestic Fox',
    'cards/Royal Majestic Fox.jpg',
    CardCrop(x: 0.2371, y: 0.1336, w: 0.5248, h: 0.7347),
    Color(0xFFF57C00),
  ),
  SeededCard(
    6,
    60,
    'Royal Owl with Fox',
    'cards/Royal Owl with fox.jpg',
    CardCrop(x: 0.1985, y: 0.0776, w: 0.6021, h: 0.8429),
    Color(0xFF0288D1),
  ),
  SeededCard(
    7,
    70,
    'Royal Tiger',
    'cards/Royal Tiger.jpg',
    CardCrop(x: 0.2291, y: 0.1262, w: 0.5417, h: 0.7584),
    Color(0xFFE64A19),
  ),
  SeededCard(
    8,
    80,
    'Royal White Tiger',
    'cards/Royal White Tiger.jpg',
    CardCrop(x: 0.2224, y: 0.1108, w: 0.5533, h: 0.7746),
    Color(0xFF26C6DA),
  ),
];

/// The seeded back called [name].
SeededCard seededCard(String name) =>
    seededCards.firstWhere((c) => c.name == name);

/// The bundled default's original in the bucket — not a row; the app ships
/// it cut to the card (`PlayingCard.backAsset`).
const royalFoxKey = 'cards/Royal Fox.jpg';
const royalFoxCrop = CardCrop(x: 0.1927, y: 0.0729, w: 0.6136, h: 0.8590);

/// What [cardPicturePng] paints round the card: the product shots' dark
/// ground.
const cardGround = Color(0xFF101010);

Map<String, dynamic> cardCropJson(CardCrop crop) => {
  'x': crop.x,
  'y': crop.y,
  'w': crop.w,
  'h': crop.h,
};

/// One catalogue row as `GET /api/card-backgrounds` sends it.
Map<String, dynamic> cardBackgroundJson(
  SeededCard card, {
  bool owned = false,
  int expiresAt = 0,
  String currency = 'HAMMER',
  String type = 'PREMIUM',
  int cost = 5,
  int durationDays = 10,
  int durationHours = 0,
}) => {
  'id': card.id,
  'name': card.name,
  'url': card.url,
  'assetFormat': 'IMAGE',
  'crop': cardCropJson(card.crop),
  'currency': currency,
  'type': type,
  'cost': cost,
  'durationDays': durationDays,
  'durationHours': durationHours,
  'sortOrder': card.sortOrder,
  'owned': owned,
  'expiresAt': expiresAt,
};

/// `GET /api/card-backgrounds`' answer: all eight, those in [owned] (id →
/// epoch ms the rental runs out) owned by this viewer.
Map<String, dynamic> cardCatalogueJson({Map<int, int> owned = const {}}) => {
  'cardBackgrounds': [
    for (final card in seededCards)
      cardBackgroundJson(
        card,
        owned: owned.containsKey(card.id),
        expiresAt: owned[card.id] ?? 0,
      ),
  ],
};

/// The eight as the app reads them.
List<CardBackground> seededCatalogue({Map<int, int> owned = const {}}) => [
  for (final row in cardCatalogueJson(owned: owned)['cardBackgrounds'] as List)
    CardBackground.fromJson(row as Map<String, dynamic>),
];

/// What a seat (`room:state.seats[].cardBackground`) or the account
/// (`user.cardBackground`) carries for a back that is worn — with, for a
/// rental, the moment it runs out ([expiresAt], epoch ms; the server leaves
/// the key out of one that never does, as 0 here).
Map<String, dynamic> cardBackJson(SeededCard card, {int expiresAt = 0}) => {
  'id': card.id,
  'url': card.url,
  'assetFormat': 'IMAGE',
  'crop': cardCropJson(card.crop),
  if (expiresAt > 0) 'expiresAt': expiresAt,
};

/// A copy of [seat] (a seat's JSON) wearing [card] — or, for null, none: the
/// key absent, as the server leaves it out of a seat that wears none — a
/// rental of it running out at [expiresAt] when that is set.
Map<String, dynamic> withCardBack(
  Map<String, dynamic> seat,
  SeededCard? card, {
  int expiresAt = 0,
}) => {
  for (final entry in seat.entries)
    if (entry.key != 'cardBackground') entry.key: entry.value,
  if (card != null) 'cardBackground': cardBackJson(card, expiresAt: expiresAt),
};

/// A Teen Patti seat as `room:state` carries it, wearing [card] (none when
/// null) — a rental running out at [expiresAt] when that is set.
Map<String, dynamic> cardSeatJson({
  required int seatIndex,
  String? userId,
  String? displayName,
  SeededCard? card,
  int expiresAt = 0,
  String status = 'active',
  bool isBlind = true,
  int cardCount = 3,
  int? chips,
}) => withCardBack(
  {
    'seatIndex': seatIndex,
    'userId': userId ?? 'u$seatIndex',
    'displayName': displayName ?? 'Player $seatIndex',
    'avatarUrl': null,
    'chips': chips,
    'status': status,
    'isBlind': isBlind,
    'lastBet': 200,
    'lastAction': 'chaal',
    'contributed': 400,
    'connected': true,
    'cardCount': cardCount,
  },
  card,
  expiresAt: expiresAt,
);

/// A `room:state` at a Teen Patti table mid-hand, the viewer at [youSeat]
/// of [seats].
Map<String, dynamic> cardRoomJson({
  required List<Map<String, dynamic>> seats,
  int youSeat = 0,
  String category = 'blind',
  int handNo = 3,
  String game = '',
}) => {
  'roomId': 'r1',
  'code': 'ABCD2345',
  'category': category,
  'chipsHidden': category != 'seen',
  'state': 'betting',
  'handNo': handNo,
  'dealerSeat': 0,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'startsAt': 0,
  'pot': 1200,
  'maxPot': 0,
  'stake': 200,
  'turn': null,
  'sideshow': null,
  'game': game,
  'you': {
    'seatIndex': youSeat,
    'chips': 100000,
    'status': 'active',
    'isBlind': true,
    'blindMovesLeft': 4,
    'contributed': 400,
    'missedTurns': 0,
    'maxMissedTurns': 3,
    'cards': <String>[],
    'options': null,
  },
  'seats': seats,
};

/// An account as `/api/auth/me` and the card-back routes answer it, with
/// [card] chosen (none when null) — a rental running out at [expiresAt] when
/// that is set.
Map<String, dynamic> cardAccountJson({
  SeededCard? card,
  int expiresAt = 0,
  String id = 'me',
  int chips = 500000,
  int diamond = 9,
  int hammer = 20,
}) => {
  'id': id,
  'provider': 'guest',
  'displayName': 'You',
  'avatarUrl': null,
  'providerAvatarUrl': null,
  'activePictureId': null,
  'tablePicture': null,
  'cardBackground': card == null
      ? null
      : cardBackJson(card, expiresAt: expiresAt),
  'chips': chips,
  'diamond': diamond,
  'hammer': hammer,
  'missile': 1,
  'handsPlayed': 0,
  'handsWon': 0,
  'handsLost': 0,
  'handsLeftMid': 0,
  'totalWinnings': 0,
  'biggestPot': 0,
};

/// A card back's picture in miniature, as a PNG: [ground] all over a
/// [size]-pixel square and [card] filling the card's [crop] (the whole
/// square when null) — an R2 product shot at a size a test decodes in a
/// moment. Needs real async: call it inside `tester.runAsync`, or from a
/// plain `test`.
Future<Uint8List> cardPicturePng(
  CardCrop? crop, {
  required Color card,
  Color ground = cardGround,
  int size = 128,
}) async {
  final side = size.toDouble();
  final whole = Rect.fromLTWH(0, 0, side, side);
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
    ..drawRect(whole, Paint()..color = ground)
    ..drawRect(crop?.rectIn(side, side) ?? whole, Paint()..color = card);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  picture.dispose();
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List();
}

/// Makes [cards] drawable at once in a widget test: each one's miniature
/// ([cardPicturePng], in its own colour) put in the picture cache under its
/// location and decoded, so every [CardBackImage] built after this shows it
/// on its first frame.
Future<void> primeCardBacks(
  WidgetTester tester,
  Iterable<SeededCard> cards, {
  int size = 128,
}) async {
  await tester.runAsync(() async {
    for (final card in cards) {
      PictureCache.prime(
        card.url,
        await cardPicturePng(card.crop, card: card.colour, size: size),
      );
      await CardBackImages.load(card.art);
    }
  });
}

/// A card-back test's teardown: the decoded backs and the cached bytes
/// forgotten.
void forgetCardBacks() {
  CardBackImages.debugClear();
  PictureCache.clearMemory();
}
