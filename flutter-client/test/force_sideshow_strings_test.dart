// The words Force Sideshow and the hammer wallet brought with them (owner,
// 13 Sep 2026), and the line a forced sideshow leaves at the table.
//
// A missing translation does not show as a key: `Strings` falls back to the
// English. So "non-empty in every language" is checked against each
// language's own entry, not against what the getter happens to return.
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/state/game_state.dart';

/// Every new key, with the placeholders its text must keep.
const _newKeys = <String, List<String>>{
  'force': [],
  'forceSideshow': [],
  'forceSideshowTitle': [],
  'forceSideshowBody': ['{name}'],
  'forceSideshowNote': [],
  'noHammersTitle': [],
  'noHammersBody': [],
  'getHammers': [],
  'noHammers': [],
  'sideshowForcedByYou': ['{name}'],
  'sideshowForcedOnYou': ['{name}'],
  'sideshowForcedOn': ['{from}', '{to}'],
  'storeTabHammers': [],
  'storeHammersTitle': [],
  'storeHammersBlurb': [],
  'rewardHammersPurchased': [],
  'walletSummary': ['{diamonds}', '{hammers}'],
};

void main() {
  group('the Force Sideshow and hammer words', () {
    for (final lang in AppLang.values) {
      test('are all written in ${lang.englishName}', () {
        final t = Strings(lang);
        const english = Strings(AppLang.english);
        for (final MapEntry(key: key, value: placeholders)
            in _newKeys.entries) {
          final own = t.ownEntry(key);
          expect(own, isNotNull, reason: '${lang.code} has no "$key"');
          expect(own!.trim(), isNotEmpty, reason: '${lang.code} "$key"');
          for (final placeholder in placeholders) {
            expect(
              own,
              contains(placeholder),
              reason: '${lang.code} "$key" lost $placeholder',
            );
          }
          if (lang != AppLang.english) {
            expect(
              own,
              isNot(english.ownEntry(key)),
              reason: '${lang.code} "$key" is still the English',
            );
          }
        }
      });
    }

    test('fill in every placeholder, in every language', () {
      const english = Strings(AppLang.english);
      expect(
        english.forceSideshowBody('Meera'),
        'Spend 1 hammer to force a sideshow with Meera?',
      );
      expect(
        english.sideshowForcedOn('Ravi', 'Meera'),
        'Ravi forced a sideshow on Meera',
      );
      expect(english.walletSummary(3, 20), '3 diamonds, 20 hammers');

      for (final lang in AppLang.values) {
        final t = Strings(lang);
        for (final line in [
          t.forceSideshowBody('Meera'),
          t.sideshowForcedByYou('Meera'),
          t.sideshowForcedOnYou('Ravi'),
          t.sideshowForcedOn('Ravi', 'Meera'),
          t.walletSummary(3, 20),
        ]) {
          expect(line, isNot(contains('{')), reason: '${lang.code}: $line');
        }
      }
    });
  });

  group('the line a forced sideshow leaves at the table', () {
    Seat seat(int index, String id, String name) => Seat.fromJson({
      'seatIndex': index,
      'userId': id,
      'displayName': name,
      'status': 'active',
      'cardCount': 3,
    });
    final seats = [
      seat(0, 'u1', 'Ravi'),
      seat(1, 'u2', 'Meera'),
      seat(2, 'u3', 'Arjun'),
    ];
    const t = Strings(AppLang.english);

    test('tells the player who forced it whom they forced', () {
      expect(
        forcedSideshowLine(
          t,
          viewerId: 'u1',
          fromUserId: 'u1',
          toUserId: 'u2',
          seats: seats,
        ),
        'You forced a sideshow with Meera',
      );
    });

    test('tells the player it was forced on who forced it', () {
      expect(
        forcedSideshowLine(
          t,
          viewerId: 'u2',
          fromUserId: 'u1',
          toUserId: 'u2',
          seats: seats,
        ),
        'Ravi forced a sideshow with you',
      );
    });

    test('tells everyone else who forced it on whom', () {
      for (final viewer in ['u3', null]) {
        expect(
          forcedSideshowLine(
            t,
            viewerId: viewer,
            fromUserId: 'u1',
            toUserId: 'u2',
            seats: seats,
          ),
          'Ravi forced a sideshow on Meera',
        );
      }
    });

    test('says nothing rather than name nobody', () {
      final noMeera = [seats[0], seats[2]];
      for (final viewer in ['u1', 'u3']) {
        expect(
          forcedSideshowLine(
            t,
            viewerId: viewer,
            fromUserId: 'u1',
            toUserId: 'u2',
            seats: noMeera,
          ),
          isNull,
        );
      }
    });
  });
}
