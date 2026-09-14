// The words the missile brought with it (owner, 14 Sep 2026).
//
// A missing translation does not show as a key: `Strings` falls back to the
// English. So "written in every language" is checked against each language's
// own entry, not against what the getter happens to return.
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';

/// Every new key, with the placeholders its text must keep.
const _newKeys = <String, List<String>>{
  'missile': [],
  'fireMissileTitle': [],
  'fireMissileBody': [],
  'fireMissileNote': [],
  'fire': [],
  'missileTooLate': [],
  'noMissilesTitle': [],
  'noMissilesBody': [],
  'getMissiles': [],
  'noMissiles': [],
  'tooFewPlayers': [],
  'missileFiredByYou': [],
  'missileFiredBy': ['{name}'],
  'storeTabMissiles': [],
  'storeMissilesTitle': [],
  'storeMissilesBlurb': [],
  'tradeMissilesTitle': [],
  'tradeMissilesBody': ['{diamonds}', '{missiles}'],
  'trade': [],
  'notEnoughDiamondsTitle': [],
  'notEnoughDiamondsBody': ['{diamonds}'],
  'getDiamonds': [],
  'missilesAdded': ['{n}'],
  'rewardMissilesTraded': [],
  'walletSummary': ['{diamonds}', '{hammers}', '{missiles}'],
};

void main() {
  for (final lang in AppLang.values) {
    test('every missile word is written in ${lang.englishName}', () {
      final t = Strings(lang);
      const english = Strings(AppLang.english);
      for (final MapEntry(key: key, value: placeholders) in _newKeys.entries) {
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

  test('the English says what the owner asked for', () {
    const t = Strings(AppLang.english);
    expect(t.missile, 'Missile');
    expect(
      '${t.fireMissileTitle} ${t.fireMissileBody}',
      'Fire a missile? Every player still in the hand shows their cards and '
          'the best hand takes the pot. Costs 1 missile.',
    );
    expect(t.missileFiredByYou, 'You fired a missile');
    expect(t.missileFiredBy('Meera'), 'Meera fired a missile');
    expect(t.tradeMissilesBody(5, 10), 'Trade 5 diamonds for 10 missiles?');
    expect(t.tradeMissilesBody(1, 2), 'Trade 1 diamond for 2 missiles?');
    expect(
      t.notEnoughDiamondsBody(1),
      'This trade needs 1 diamond. Get more diamonds?',
    );
    expect(t.missilesAdded(10), '10 missiles added to your wallet');
  });

  test('every placeholder is filled, in every language', () {
    for (final lang in AppLang.values) {
      final t = Strings(lang);
      for (final line in [
        t.missileFiredBy('Ravi'),
        t.tradeMissilesBody(5, 10),
        t.tradeMissilesBody(1, 2),
        t.notEnoughDiamondsBody(25),
        t.missilesAdded(50),
        t.walletSummary(2, 20, 1),
      ]) {
        expect(line, isNot(contains('{')), reason: '${lang.code}: $line');
      }
    }
  });
}
