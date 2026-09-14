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
  'tradeMissileBodyOne': ['{diamonds}'],
  'trade': [],
  'notEnoughDiamondsTitle': [],
  'notEnoughDiamondsBody': ['{diamonds}'],
  'getDiamonds': [],
  'missilesAdded': ['{n}'],
  'missileAddedOne': [],
  'rewardMissilesTraded': [],
  'rewardMissileTradedOne': [],
  'walletSummary': ['{diamonds}', '{hammers}', '{missiles}'],
  'walletSummaryOneMissile': ['{diamonds}', '{hammers}'],
  // The Premium Packages (owner, 14 Sep 2026), which bring missiles too.
  'premiumPackages': [],
  'posPremiumPackage': [],
  'plusMissileOne': [],
  'plusMissiles': ['{n}'],
  'plusHammers': ['{n}'],
  'rewardPremiumPurchased': [],
  'premiumAdded': ['{chips}', '{missiles}', '{hammers}'],
  'premiumAddedOneMissile': ['{chips}', '{hammers}'],
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
    expect(t.storeMissilesBlurb, 'Trade diamonds: 10 diamonds = 1 missile.');
    expect(t.tradeMissilesBody(25, 5), 'Trade 25 diamonds for 5 missiles?');
    expect(t.tradeMissilesBody(5, 1), 'Trade 5 diamonds for 1 missile?');
    // {s} still follows the diamonds.
    expect(t.tradeMissilesBody(1, 2), 'Trade 1 diamond for 2 missiles?');
    expect(t.tradeMissilesBody(1, 1), 'Trade 1 diamond for 1 missile?');
    expect(
      t.notEnoughDiamondsBody(1),
      'This trade needs 1 diamond. Get more diamonds?',
    );
    expect(t.missilesAdded(10), '10 missiles added to your wallet');
    expect(t.missilesAdded(1), '1 missile added to your wallet');
    expect(
      t.rewardMissilesTraded(10),
      'The missiles are in your wallet. Fire one at the table.',
    );
    expect(
      t.rewardMissilesTraded(1),
      'The missile is in your wallet. Fire it at the table.',
    );
    expect(t.walletSummary(2, 20, 4), '2 diamonds, 20 hammers, 4 missiles');
    expect(t.walletSummary(2, 20, 1), '2 diamonds, 20 hammers, 1 missile');
    expect(t.premiumPackages, 'Premium Packages');
    expect(t.posPremiumPackage, 'PREMIUM PACKAGE');
    expect(t.plusMissiles(1), '+1 Missile');
    expect(t.plusMissiles(11), '+11 Missiles');
    expect(t.plusHammers(10), '+10 Hammers');
    expect(
      t.premiumAdded('650 Crore', 1, 10),
      'Premium Package added: 650 Crore chips, 1 missile and 10 hammers',
    );
    expect(
      t.premiumAdded('4,750 Crore', 11, 45),
      'Premium Package added: 4,750 Crore chips, 11 missiles and 45 hammers',
    );
  });

  test('a single missile is said in the singular, in every language', () {
    for (final lang in AppLang.values) {
      final t = Strings(lang);
      String own(String key) => t.ownEntry(key)!;
      expect(
        t.tradeMissilesBody(5, 1),
        own(
          'tradeMissileBodyOne',
        ).replaceAll('{diamonds}', '5').replaceAll('{s}', 's'),
        reason: lang.code,
      );
      expect(t.missilesAdded(1), own('missileAddedOne'), reason: lang.code);
      expect(
        t.rewardMissilesTraded(1),
        own('rewardMissileTradedOne'),
        reason: lang.code,
      );
      expect(
        t.walletSummary(2, 20, 1),
        own(
          'walletSummaryOneMissile',
        ).replaceAll('{diamonds}', '2').replaceAll('{hammers}', '20'),
        reason: lang.code,
      );
      // And more than one keeps the plural lines.
      expect(t.missilesAdded(5), isNot(t.missilesAdded(1)), reason: lang.code);
      // A Premium Package's one missile, on its card and in the notice.
      expect(t.plusMissiles(1), own('plusMissileOne'), reason: lang.code);
      expect(
        t.premiumAdded('650 Crore', 1, 10),
        own(
          'premiumAddedOneMissile',
        ).replaceAll('{chips}', '650 Crore').replaceAll('{hammers}', '10'),
        reason: lang.code,
      );
    }
    // The plural nouns that must never follow a 1.
    for (final (lang, plural) in [
      (AppLang.english, '1 missiles'),
      (AppLang.hindi, 'मिसाइलें'),
      (AppLang.punjabi, 'ਮਿਜ਼ਾਈਲਾਂ'),
    ]) {
      final t = Strings(lang);
      for (final line in [
        t.tradeMissilesBody(5, 1),
        t.missilesAdded(1),
        t.rewardMissilesTraded(1),
        t.walletSummary(2, 20, 1),
        t.plusMissiles(1),
        t.premiumAdded('650 Crore', 1, 10),
      ]) {
        expect(line, isNot(contains(plural)), reason: '${lang.code}: $line');
      }
    }
    // "+1 Missiles", with its capital.
    for (final line in [
      const Strings(AppLang.english).plusMissiles(1),
      const Strings(AppLang.english).premiumAdded('650 Crore', 1, 10),
    ]) {
      expect(line.toLowerCase(), isNot(contains('1 missiles')), reason: line);
    }
  });

  test('every placeholder is filled, in every language', () {
    for (final lang in AppLang.values) {
      final t = Strings(lang);
      for (final line in [
        t.missileFiredBy('Ravi'),
        t.tradeMissilesBody(25, 5),
        t.tradeMissilesBody(5, 1),
        t.tradeMissilesBody(1, 2),
        t.notEnoughDiamondsBody(25),
        t.missilesAdded(20),
        t.missilesAdded(1),
        t.rewardMissilesTraded(1),
        t.rewardMissilesTraded(20),
        t.walletSummary(2, 20, 1),
        t.walletSummary(2, 20, 4),
        t.plusMissiles(1),
        t.plusMissiles(50),
        t.plusHammers(100),
        t.premiumAdded('650 Crore', 1, 10),
        t.premiumAdded('10,500 Crore', 50, 100),
      ]) {
        expect(line, isNot(contains('{')), reason: '${lang.code}: $line');
      }
    }
  });
}
