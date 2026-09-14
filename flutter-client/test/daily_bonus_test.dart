import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';

/// The daily bonus (owner, 14 Sep 2026): 1 lakh chips and a hammer every 24
/// hours, where the timed bonus had been 10,000 chips every four.
void main() {
  test('the rewards carry the bonus hammers, and an older server none', () {
    final r = Rewards.fromJson({
      'bonusReward': 100000,
      'bonusHammers': 1,
      'bonusReadyAt': 0,
      'bonusAvailable': true,
    });
    expect(r.bonusReward, 100000);
    expect(r.bonusHammers, 1);
    expect(r.bonusReady, isTrue);
    expect(Rewards.fromJson({'bonusReward': 10000}).bonusHammers, 0);
  });

  test('every language names the daily bonus and says one hammer', () {
    const english = Strings(AppLang.english);
    expect(english.dailyBonus, 'DAILY BONUS');
    expect(english.rewardComeBack, 'Come again after 24 hours.');
    expect(english.plusHammers(1), '+1 Hammer');
    expect(english.plusHammers(5), '+5 Hammers');

    for (final lang in AppLang.values) {
      final t = Strings(lang);
      for (final key in ['dailyBonus', 'rewardComeBack', 'plusHammerOne']) {
        expect(
          t.ownEntry(key),
          isNotNull,
          reason: '${lang.code} has no "$key"',
        );
      }
      expect(t.ownEntry('fourHourBonus'), isNull, reason: lang.code);
      expect(t.rewardComeBack, contains(RegExp('24|২৪')), reason: lang.code);
      expect(t.plusHammers(1), contains('1'), reason: lang.code);
    }
  });
}
