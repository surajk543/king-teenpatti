// The hammer wallet on the client (owner, 13 Sep 2026): the store's shelf of
// hammer packs, and the wire fields that carry hammers and Force Sideshow.
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/widgets/chip_store.dart';

Map<String, dynamic> _user({Object? hammer}) => {
  'id': 'u1',
  'provider': 'guest',
  'displayName': 'Ravi',
  'chips': 200000,
  'diamond': 1,
  'hammer': ?hammer,
  'avatarUrl': null,
  'providerAvatarUrl': null,
  'activePictureId': 7,
  'handsPlayed': 12,
  'handsWon': 5,
  'handsLost': 7,
  'handsLeftMid': 1,
  'totalWinnings': 4200,
  'biggestPot': 9000,
};

void main() {
  group('the hammer shelf', () {
    test("is the owner's four packs, cheapest first", () {
      expect(
        [for (final p in hammerPacks) (p.productId, p.hammers, p.rupees)],
        [
          ('hammers_20_300', 20, 300),
          ('hammers_50_699', 50, 699),
          ('hammers_100_1299', 100, 1299),
          ('hammers_250_2999', 250, 2999),
        ],
      );
    });

    test('marks 50 popular and 100 best value, as the diamond shelf does', () {
      expect(
        {for (final p in hammerPacks) p.hammers: p.mark},
        {
          20: ShelfMark.none,
          50: ShelfMark.popular,
          100: ShelfMark.bestValue,
          250: ShelfMark.none,
        },
      );
    });

    test('names each product by its count and price, and none twice', () {
      for (final p in hammerPacks) {
        expect(p.productId, 'hammers_${p.hammers}_${p.rupees}');
      }
      final ids = [
        ...chipPacks.map((p) => p.productId),
        ...diamondPacks.map((p) => p.productId),
        ...hammerPacks.map((p) => p.productId),
      ];
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('sits after Diamonds among the store tabs', () {
      expect(StoreTab.values, [
        StoreTab.chips,
        StoreTab.diamonds,
        StoreTab.hammers,
        StoreTab.missiles,
        StoreTab.pictures,
        StoreTab.tables,
        StoreTab.emojis,
      ]);
    });
  });

  group('the wire', () {
    test('a user carries its hammers', () {
      expect(User.fromJson(_user(hammer: 20)).hammer, 20);
      // An older server sends no hammer at all, which is none to spend.
      expect(User.fromJson(_user()).hammer, 0);
    });

    test('withHammer changes the count and nothing else', () {
      final before = User.fromJson(_user(hammer: 20));
      final after = before.withHammer(19);
      expect(after.hammer, 19);
      expect(after.id, before.id);
      expect(after.chips, before.chips);
      expect(after.diamond, before.diamond);
      expect(after.activePictureId, before.activePictureId);
      expect(after.handsPlayed, before.handsPlayed);
      expect(after.biggestPot, before.biggestPot);
      expect(before.withHammer(-3).hammer, 0);
    });

    test('the turn options say whether a Force Sideshow is allowed', () {
      TurnOptions options(Map<String, dynamic> extra) => TurnOptions.fromJson({
        'canSee': false,
        'canPack': true,
        'canSideshow': true,
        'sideshowWith': 'Meera',
        'raiseSteps': [400, 800],
        'show': null,
        'chips': 90000,
        'currentStake': 200,
        ...extra,
      });
      expect(options({'canForceSideshow': true}).canForceSideshow, isTrue);
      expect(options({'canForceSideshow': false}).canForceSideshow, isFalse);
      // A server that predates it sends nothing, and the key stays dark.
      expect(options({}).canForceSideshow, isFalse);
    });

    test('a reveal says whether it was forced', () {
      SideshowReveal reveal(String? reason) => SideshowReveal.fromJson({
        'reason': ?reason,
        'packedUserId': 'u2',
        'hands': [
          {
            'userId': 'u1',
            'displayName': 'Ravi',
            'cards': ['As', 'Ad', 'Ah'],
            'handName': 'Trail',
          },
          {
            'userId': 'u2',
            'displayName': 'Meera',
            'cards': ['2c', '7d', '9h'],
            'handName': 'High card',
          },
        ],
      });
      expect(reveal('forced').forced, isTrue);
      expect(reveal('forced').reason, SideshowReason.forced);
      expect(reveal('accepted').forced, isFalse);
      expect(reveal(null).reason, SideshowReason.accepted);
      expect(reveal('forced').hands.map((h) => h.userId), ['u1', 'u2']);
    });
  });
}
