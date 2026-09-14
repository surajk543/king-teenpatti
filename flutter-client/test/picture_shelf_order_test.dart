import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';

ProfilePicture _picture(
  int id, {
  String type = 'PREMIUM',
  String format = 'IMAGE',
  String currency = 'COIN',
  int cost = 0,
}) => ProfilePicture(
  id: id,
  name: 'Picture $id',
  url: '/profiles/$id.json',
  assetFormat: format,
  currency: currency,
  type: type,
  cost: cost,
  durationDays: 100,
  owned: false,
  expiresAt: 0,
);

/// The shelf's order menu (owner, 14 Sep 2026): price low to high or high to
/// low, each wallet's pictures sorted among themselves.
void main() {
  final mixed = [
    _picture(1, type: 'FREE'),
    _picture(2, cost: 50000),
    _picture(3, format: 'LOTTIE', currency: 'HAMMER', cost: 40),
    _picture(4, cost: 10000),
    _picture(5, format: 'LOTTIE', currency: 'HAMMER', cost: 1),
    _picture(6, format: 'LOTTIE', currency: 'DIAMOND', cost: 5),
    _picture(7, format: 'LOTTIE', currency: 'HAMMER', cost: 1),
    _picture(8, format: 'LOTTIE', currency: 'DIAMOND', cost: 3),
    _picture(9, type: 'FREE', format: 'LOTTIE'),
    _picture(10, format: 'LOTTIE', cost: 10000000),
  ];

  test('low to high: free first, then chips, hammers and diamonds, each '
      'cheapest first', () {
    // The equal 1-hammer pair keeps the catalogue's order.
    expect(shelfOrder(mixed).map((p) => p.id), [1, 9, 4, 2, 10, 5, 7, 3, 8, 6]);
    // Low to high is the default.
    expect(
      shelfOrder(mixed, PictureSort.lowToHigh).map((p) => p.id),
      shelfOrder(mixed).map((p) => p.id),
    );
  });

  test(
    'high to low: each wallet dearest first, and the free pictures last',
    () {
      expect(shelfOrder(mixed, PictureSort.highToLow).map((p) => p.id), [
        10,
        2,
        4,
        3,
        5,
        7,
        6,
        8,
        1,
        9,
      ]);
    },
  );

  test('a shelf of one wallet is simply sorted by price, either way', () {
    final hammers = [
      _picture(1, format: 'LOTTIE', currency: 'HAMMER', cost: 30),
      _picture(2, format: 'LOTTIE', currency: 'HAMMER', cost: 10),
      _picture(3, format: 'LOTTIE', currency: 'HAMMER', cost: 100),
    ];
    expect(shelfOrder(hammers).map((p) => p.id), [2, 1, 3]);
    expect(shelfOrder(hammers, PictureSort.highToLow).map((p) => p.id), [
      3,
      1,
      2,
    ]);
  });

  test('a currency this build does not know is sorted with chips', () {
    final shelf = shelfOrder([
      _picture(1, format: 'LOTTIE', currency: 'DIAMOND', cost: 1),
      _picture(2, format: 'LOTTIE', currency: 'HAMMER', cost: 100),
      _picture(3, format: 'RIVE', cost: 90000),
      _picture(4, format: 'LOTTIE', currency: 'RUBY', cost: 5),
    ]);
    expect(shelf.map((p) => p.id), [4, 3, 2, 1]);
  });
}
