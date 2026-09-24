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
  'walletSummary': ['{diamonds}', '{hammers}', '{missiles}'],
};

/// The words pictures priced in hammers brought with them (owner, 14 Sep
/// 2026), with the placeholders each must keep. A `…One` line writes its 1
/// out, so it keeps no `{cost}`.
const _pictureKeys = <String, List<String>>{
  'unlockBodyHammers': ['{name}', '{cost}'],
  'unlockBodyHammerOne': ['{name}'],
  'unlockRentBodyHammers': ['{name}', '{cost}', '{time}'],
  'unlockRentBodyHammerOne': ['{name}', '{time}'],
  'notEnoughHammersTitle': [],
  'notEnoughHammersBody': ['{name}', '{cost}'],
  'notEnoughHammersBodyOne': ['{name}'],
  'notEnoughDiamondsPictureBody': ['{name}', '{cost}'],
  'pictureChipsLobbyOnly': [],
};

/// Every key in [keys] is this language's own, non-empty, keeps its
/// placeholders, and — outside English — is not the English left in place.
void _writtenIn(AppLang lang, Map<String, List<String>> keys) {
  final t = Strings(lang);
  const english = Strings(AppLang.english);
  for (final MapEntry(key: key, value: placeholders) in keys.entries) {
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
}

void main() {
  group('the Force Sideshow and hammer words', () {
    for (final lang in AppLang.values) {
      test('are all written in ${lang.englishName}', () {
        _writtenIn(lang, _newKeys);
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
      expect(
        english.walletSummary(3, 20, 4),
        '3 diamonds, 20 hammers, 4 missiles',
      );

      for (final lang in AppLang.values) {
        final t = Strings(lang);
        for (final line in [
          t.forceSideshowBody('Meera'),
          t.sideshowForcedByYou('Meera'),
          t.sideshowForcedOnYou('Ravi'),
          t.sideshowForcedOn('Ravi', 'Meera'),
          t.walletSummary(3, 20, 4),
        ]) {
          expect(line, isNot(contains('{')), reason: '${lang.code}: $line');
        }
      }
    });
  });

  group('the words of a picture priced in hammers', () {
    for (final lang in AppLang.values) {
      test('are all written in ${lang.englishName}', () {
        _writtenIn(lang, _pictureKeys);
      });
    }

    test('say what the owner asked for in English', () {
      const t = Strings(AppLang.english);
      expect(
        t.unlockRentBodyHammers('Toucan Flying', 30, 100),
        'Toucan Flying costs 30 hammers and is yours for 100 days. Unlock it '
        'and wear it now?',
      );
      expect(
        t.unlockBodyHammers('Cool Cat', 10),
        'Cool Cat costs 10 hammers. Unlock it and wear it now?',
      );
      expect(t.notEnoughHammersTitle, 'Not enough hammers');
      expect(
        t.notEnoughHammersBody('Jolly Queen', 100),
        'Jolly Queen costs 100 hammers. Get more hammers?',
      );
      expect(t.getHammers, 'Get hammers');
      expect(
        t.notEnoughDiamondsPictureBody('Jolly King', '1'),
        'Jolly King costs 1 diamond. Get more diamonds?',
      );
      expect(
        t.notEnoughDiamondsPictureBody('Jolly King', '4'),
        'Jolly King costs 4 diamonds. Get more diamonds?',
      );
      expect(
        t.pictureChipsLobbyOnly,
        'You can only buy a chip-priced picture in the lobby.',
      );
      // Pictures are sold for chips, hammers AND diamonds (Butterfly
      // Flapping, Waving Tiger Cub, Indian Flag, Jolly King and Jolly Queen
      // cost diamonds), and the shelves' copy says all of it (24 Sep 2026,
      // owner's "fix all bugs": it said "chips or hammers" alone).
      expect(
        t.storePicturesBlurb,
        'Unlock a picture with chips, hammers or diamonds.',
      );
      expect(
        t.storeAnimatedBlurb,
        'Unlock an animated picture with hammers or diamonds.',
      );
      expect(t.storeDiamondsBlurb, 'Diamonds trade for missiles.');
      expect(
        t.rewardDiamondsPurchased,
        'The diamonds are in your wallet. Trade them for missiles.',
      );
    });

    test('say one hammer in the singular, in every language', () {
      for (final lang in AppLang.values) {
        final t = Strings(lang);
        String own(String key) => t.ownEntry(key)!;
        expect(
          t.unlockBodyHammers('Blazing Fire', 1),
          own('unlockBodyHammerOne').replaceAll('{name}', 'Blazing Fire'),
          reason: lang.code,
        );
        expect(
          t.unlockRentBodyHammers('Blazing Fire', 1, 100),
          own('unlockRentBodyHammerOne')
              .replaceAll('{name}', 'Blazing Fire')
              .replaceAll('{time}', t.timeDays(100)),
          reason: lang.code,
        );
        expect(
          t.notEnoughHammersBody('Blazing Fire', 1),
          own('notEnoughHammersBodyOne').replaceAll('{name}', 'Blazing Fire'),
          reason: lang.code,
        );
        // And more than one keeps the plural lines.
        expect(
          t.unlockBodyHammers('Cool Cat', 10),
          own(
            'unlockBodyHammers',
          ).replaceAll('{name}', 'Cool Cat').replaceAll('{cost}', '10'),
          reason: lang.code,
        );
        expect(
          t.unlockRentBodyHammers('Cool Cat', 10, 100),
          isNot(t.unlockRentBodyHammers('Cool Cat', 1, 100)),
          reason: lang.code,
        );
      }
      // The plural nouns that must never follow a 1.
      for (final (lang, plural) in [
        (AppLang.english, '1 hammers'),
        (AppLang.hindi, '1 हथौड़े'),
        (AppLang.punjabi, '1 ਹਥੌੜੇ'),
      ]) {
        final t = Strings(lang);
        for (final line in [
          t.unlockBodyHammers('Blazing Fire', 1),
          t.unlockRentBodyHammers('Blazing Fire', 1, 100),
          t.notEnoughHammersBody('Blazing Fire', 1),
        ]) {
          expect(line, isNot(contains(plural)), reason: '${lang.code}: $line');
          expect(line, contains('1'), reason: '${lang.code}: $line');
        }
      }
    });

    test('fill in every placeholder, in every language', () {
      for (final lang in AppLang.values) {
        final t = Strings(lang);
        for (final line in [
          t.unlockBodyHammers('Cool Cat', 10),
          t.unlockBodyHammers('Blazing Fire', 1),
          t.unlockRentBodyHammers('Cool Cat', 10, 100),
          t.unlockRentBodyHammers('Blazing Fire', 1, 100),
          t.notEnoughHammersBody('Cool Cat', 10),
          t.notEnoughHammersBody('Blazing Fire', 1),
          t.notEnoughDiamondsPictureBody('Jolly King', '4'),
          t.notEnoughDiamondsPictureBody('Jolly King', '1'),
        ]) {
          expect(line, isNot(contains('{')), reason: '${lang.code}: $line');
          expect(line, contains(RegExp('Cool Cat|Blazing Fire|Jolly King')));
        }
      }
    });

    test('price the pictures shelves in every wallet they sell for, '
        'everywhere', () {
      for (final (lang, chip, hammer, diamond) in [
        (AppLang.english, 'chips', 'hammer', 'diamond'),
        (AppLang.hindi, 'चिप्स', 'हथौड़', 'हीर'),
        (AppLang.bengali, 'চিপস', 'হাতুড়ি', 'হীরে'),
        (AppLang.gujarati, 'ચિપ્સ', 'હથોડી', 'હીરા'),
        (AppLang.punjabi, 'ਚਿਪਸ', 'ਹਥੌੜ', 'ਹੀਰ'),
      ]) {
        final t = Strings(lang);
        // Hammer and diamond pictures sell in the lobby and at a table.
        for (final blurb in [t.storePicturesBlurb, t.storeAnimatedBlurb]) {
          expect(blurb, contains(hammer), reason: '${lang.code}: $blurb');
          expect(blurb, contains(diamond), reason: '${lang.code}: $blurb');
        }
        // Chip-priced ones only in the lobby, where the Pictures shelf is.
        expect(
          t.storePicturesBlurb,
          contains(chip),
          reason: '${lang.code}: ${t.storePicturesBlurb}',
        );
        expect(
          t.storeAnimatedBlurb,
          isNot(contains(chip)),
          reason: '${lang.code}: ${t.storeAnimatedBlurb}',
        );
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
