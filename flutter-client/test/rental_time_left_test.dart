import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';

/// The wording the already-unlocked picture popup uses for a rental.
void main() {
  const en = Strings(AppLang.english);
  final now = DateTime(2026, 9, 13, 18, 30);
  int after(Duration d) => now.add(d).millisecondsSinceEpoch;

  group('rentalTimeLeft', () {
    test('a rental with a day or more to go counts days and hours', () {
      expect(
        rentalTimeLeft(
          en,
          after(const Duration(days: 99, hours: 23, minutes: 10)),
          now,
        ),
        '99 days 23 hours left',
      );
      expect(
        rentalTimeLeft(en, after(const Duration(days: 1, hours: 1)), now),
        '1 day 1 hour left',
      );
      // Exactly two days: the hours still show, so the line keeps its shape.
      expect(
        rentalTimeLeft(en, after(const Duration(days: 2)), now),
        '2 days 0 hours left',
      );
    });

    test('under a day it counts hours and minutes', () {
      expect(
        rentalTimeLeft(en, after(const Duration(hours: 5, minutes: 7)), now),
        '5 hours 7 minutes left',
      );
      expect(
        rentalTimeLeft(en, after(const Duration(hours: 1, minutes: 1)), now),
        '1 hour 1 minute left',
      );
    });

    test('under an hour it counts minutes, rounded up', () {
      expect(
        rentalTimeLeft(en, after(const Duration(minutes: 42)), now),
        '42 minutes left',
      );
      // Seconds to go is still time to go — never "0 minutes left".
      expect(
        rentalTimeLeft(en, after(const Duration(seconds: 30)), now),
        '1 minute left',
      );
      expect(
        rentalTimeLeft(en, after(const Duration(minutes: 59, seconds: 1)), now),
        '1 hour 0 minutes left',
      );
    });

    test('a rental whose end has come says it has run out', () {
      expect(
        rentalTimeLeft(en, now.millisecondsSinceEpoch, now),
        en.rentalLapsed,
      );
      expect(
        rentalTimeLeft(en, after(const Duration(minutes: -3)), now),
        en.rentalLapsed,
      );
    });

    test('a picture that never runs out is yours to keep', () {
      expect(rentalTimeLeft(en, 0, now), 'Yours to keep');
    });

    test('the other languages put their own words round the numbers', () {
      expect(
        rentalTimeLeft(
          const Strings(AppLang.hindi),
          after(const Duration(days: 2, hours: 3)),
          now,
        ),
        '2 दिन 3 घंटे बाकी',
      );
      expect(
        rentalTimeLeft(
          const Strings(AppLang.punjabi),
          after(const Duration(hours: 1, minutes: 5)),
          now,
        ),
        '1 ਘੰਟਾ 5 ਮਿੰਟ ਬਾਕੀ',
      );
    });
  });

  test('the end date is numeric, day first, on a 24-hour clock', () {
    expect(rentalEndDate(DateTime(2026, 12, 3, 9, 5)), '03/12/2026 09:05');
    expect(rentalEndDate(DateTime(2027, 1, 21, 23, 59)), '21/01/2027 23:59');
  });
}
