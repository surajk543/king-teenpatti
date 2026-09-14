import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';

/// Pictures rented by the hour (owner, 14 Sep 2026): the catalogue's
/// durationHours beside durationDays, and every place the app words a term —
/// the price tag, the unlock sentence and an owned rental's tag.
void main() {
  const english = Strings(AppLang.english);

  ProfilePicture picture({
    int days = 0,
    int hours = 0,
    String currency = 'COIN',
    int cost = 1000000,
  }) => ProfilePicture.fromJson({
    'id': 7,
    'name': 'Love Sheep',
    'url': 'https://example.test/love-sheep.json',
    'assetFormat': 'LOTTIE',
    'currency': currency,
    'type': 'PREMIUM',
    'cost': cost,
    'durationDays': days,
    'durationHours': hours,
    'owned': false,
    'expiresAt': 0,
  });

  test('the catalogue hours are read, and an hour is a rental', () {
    final sheep = picture(hours: 1);
    expect(sheep.durationDays, 0);
    expect(sheep.durationHours, 1);
    expect(sheep.rented, isTrue);
    expect(picture().rented, isFalse);

    // A server that sends no hours rents by the day, as it always did.
    final older = ProfilePicture.fromJson({
      'id': 1,
      'type': 'PREMIUM',
      'cost': 5,
      'durationDays': 3,
    });
    expect(older.durationHours, 0);
    expect(older.rented, isTrue);
  });

  test('a term is worded in days, hours or both', () {
    expect(english.rentalTerm(10, 0), '10 days');
    expect(english.rentalTerm(1, 0), '1 day');
    expect(english.rentalTerm(0, 1), '1 hour');
    expect(english.rentalTerm(0, 3), '3 hours');
    expect(english.rentalTerm(1, 12), '1 day 12 hours');
    // The price tag keeps its short form for days, and says hours in full.
    expect(english.rentForDays(10), '10 days');
    expect(english.rentForDays(0, hours: 3), '3 hours');
  });

  test('the unlock sentence says how long, in every wallet', () {
    expect(
      unlockPictureBody(english, picture(hours: 1)),
      contains('and is yours for 1 hour. Unlock it'),
    );
    expect(
      unlockPictureBody(english, picture(hours: 3, cost: 3000000)),
      contains('and is yours for 3 hours. Unlock it'),
    );
    expect(
      unlockPictureBody(
        english,
        picture(days: 10, currency: 'HAMMER', cost: 2),
      ),
      'Love Sheep costs 2 hammers and is yours for 10 days. Unlock it and '
      'wear it now?',
    );
    expect(
      unlockPictureBody(
        english,
        picture(days: 100, currency: 'DIAMOND', cost: 4),
      ),
      contains('costs 4 diamonds and is yours for 100 days.'),
    );
  });

  test('every language puts the hours into its own sentence', () {
    for (final lang in AppLang.values) {
      final t = Strings(lang);
      for (final body in [
        t.unlockRentBody('Love Sheep', '10', 0, hours: 3),
        t.unlockRentBodyDiamond('Love Sheep', '10', 0, hours: 3),
        t.unlockRentBodyHammers('Love Sheep', 10, 0, hours: 3),
        t.unlockRentBodyHammers('Love Sheep', 1, 0, hours: 3),
      ]) {
        expect(body, contains(t.timeHours(3)), reason: lang.code);
        expect(body, isNot(contains('{')), reason: lang.code);
      }
      for (final key in ['hoursLeft', 'minutesLeft']) {
        final own = t.ownEntry(key);
        expect(own, isNotNull, reason: '${lang.code} has no "$key"');
        expect(own, contains('{n}'), reason: '${lang.code} "$key"');
      }
    }
  });

  test("an owned rental's tag counts days, then hours, then minutes", () {
    final now = DateTime.fromMillisecondsSinceEpoch(1800000000000);
    int at(Duration d) => now.add(d).millisecondsSinceEpoch;

    expect(rentalTagLeft(english, 0, now), isNull);
    expect(
      rentalTagLeft(english, at(const Duration(days: 4, hours: 2)), now),
      '5d left',
    );
    expect(
      rentalTagLeft(english, at(const Duration(hours: 24)), now),
      '24h left',
    );
    expect(
      rentalTagLeft(english, at(const Duration(hours: 3)), now),
      '3h left',
    );
    expect(
      rentalTagLeft(english, at(const Duration(hours: 2, minutes: 1)), now),
      '3h left',
    );
    // An hour just bought reads as the hour, not as 60 minutes.
    expect(
      rentalTagLeft(english, at(const Duration(hours: 1)), now),
      '1h left',
    );
    expect(
      rentalTagLeft(english, at(const Duration(minutes: 59)), now),
      '59m left',
    );
    expect(
      rentalTagLeft(english, at(const Duration(seconds: 30)), now),
      '1m left',
    );
  });
}
