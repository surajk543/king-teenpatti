// The words a variation table brought with it.
//
// A missing translation does not show as a key: `Strings` falls back to the
// English. So "written in every language" is checked against each language's
// own entry, not against what the getter happens to return.
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';

/// Every new key, with the placeholders its text must keep.
const _newKeys = <String, List<String>>{
  'variation': [],
  'variationTableNote': [],
  'variationChooseTitle': [],
  'variationSelectingBy': ['{name}'],
  'variationChosen': ['{variation}'],
  'variationAutoChosen': [],
  'variationLeftChosen': ['{name}'],
  'wildCard': [],
  'varMuflis': [],
  'varAk47': [],
  'varJoker': [],
  'varHukam': [],
  'varLowestJoker': [],
  'varHighestJoker': [],
  'varMuflisNote': [],
  'varAk47Note': [],
  'varJokerNote': [],
  'varHukamNote': [],
  'varLowestJokerNote': [],
  'varHighestJokerNote': [],
};

/// Written the same in every script: a rifle's model number is not a word.
const _sameEverywhere = {'varAk47'};

void main() {
  for (final lang in AppLang.values) {
    test('every variation word is written in ${lang.englishName}', () {
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
        if (lang != AppLang.english && !_sameEverywhere.contains(key)) {
          expect(
            own,
            isNot(english.ownEntry(key)),
            reason: '${lang.code} "$key" is still the English',
          );
        }
      }
    });

    test('${lang.englishName} names and explains all six variations', () {
      final t = Strings(lang);
      for (final wire in Variation.all) {
        // A name that came back as the wire value is the unknown-variation
        // fallback, which would mean the switch has lost one. AK47 is its own
        // name.
        if (wire != Variation.ak47) {
          expect(t.variationName(wire), isNot(wire), reason: wire);
        }
        expect(t.variationNote(wire), isNotEmpty, reason: wire);
      }
    });
  }

  test('the English says what the owner asked for', () {
    const t = Strings(AppLang.english);
    expect(t.variationChooseTitle, 'Choose Variation');
    expect(t.variationSelectingBy('Rahul'), 'Rahul is selecting variation…');
    expect(t.variationChosen(t.variationName('AK47')), 'Variation: AK47');
    expect(t.variationName('LOWEST_JOKER'), 'Lowest Joker');
  });

  test('a variation this build has never heard of is shown as sent', () {
    const t = Strings(AppLang.hindi);
    expect(t.variationName('ROYAL_FLIP'), 'ROYAL_FLIP');
    expect(t.variationNote('ROYAL_FLIP'), isEmpty);
  });
}
