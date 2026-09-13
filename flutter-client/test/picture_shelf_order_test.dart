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

void main() {
  test(
    'the premium animated pictures run cheapest first, in their own slots',
    () {
      final shelf = shelfOrder([
        _picture(1, type: 'FREE'),
        _picture(2, cost: 50000),
        _picture(3, format: 'LOTTIE', currency: 'DIAMOND', cost: 4),
        _picture(4, cost: 10000),
        _picture(5, format: 'LOTTIE', currency: 'DIAMOND', cost: 1),
        _picture(6, format: 'LOTTIE', currency: 'DIAMOND', cost: 3),
        _picture(7, format: 'LOTTIE', currency: 'DIAMOND', cost: 1),
      ]);
      // The stills keep the catalogue's order; the equal 1-diamond pair keeps
      // theirs too.
      expect(shelf.map((p) => p.id), [1, 2, 5, 4, 7, 6, 3]);
    },
  );

  test(
    'a chip price comes before a diamond price, and a free animation stays put',
    () {
      final shelf = shelfOrder([
        _picture(1, type: 'FREE', format: 'LOTTIE'),
        _picture(2, format: 'LOTTIE', currency: 'DIAMOND', cost: 1),
        _picture(3, format: 'RIVE', cost: 90000),
      ]);
      expect(shelf.map((p) => p.id), [1, 3, 2]);
    },
  );
}
