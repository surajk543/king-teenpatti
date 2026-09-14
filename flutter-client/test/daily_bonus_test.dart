import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';

/// The two timed rewards (owner, 14 Sep 2026): the 4-hour bonus of 10,000
/// chips, and beside it the daily bonus of 1 lakh chips and a hammer every 24
/// hours, collected through an endpoint of its own.
void main() {
  test('the rewards carry both bonuses, and an older server no daily one', () {
    final r = Rewards.fromJson({
      'bonusReward': 10000,
      'bonusReadyAt': 0,
      'bonusAvailable': true,
      'dailyReward': 100000,
      'dailyHammers': 1,
      'dailyReadyAt': 0,
      'dailyAvailable': true,
    });
    expect(r.bonusReward, 10000);
    expect(r.bonusReady, isTrue);
    expect(r.hasDaily, isTrue);
    expect(r.dailyReward, 100000);
    expect(r.dailyHammers, 1);
    expect(r.dailyReady, isTrue);

    final older = Rewards.fromJson({
      'bonusReward': 10000,
      'bonusAvailable': true,
    });
    expect(older.hasDaily, isFalse);
    expect(older.dailyHammers, 0);

    final recharging = Rewards.fromJson({
      'dailyReward': 100000,
      'dailyReadyAt': DateTime.now()
          .add(const Duration(hours: 23))
          .millisecondsSinceEpoch,
    });
    expect(recharging.dailyReady, isFalse);
    expect(recharging.untilDaily, greaterThan(const Duration(hours: 22)));
  });

  test('every language names both bonuses and says one hammer', () {
    const english = Strings(AppLang.english);
    expect(english.fourHourBonus, '4-HOUR BONUS');
    expect(english.dailyBonus, 'DAILY BONUS');
    expect(english.rewardComeBack, 'Come again after 4 hours.');
    expect(english.rewardComeBackDaily, 'Come again after 24 hours.');
    expect(english.plusHammers(1), '+1 Hammer');
    expect(english.plusHammers(5), '+5 Hammers');

    for (final lang in AppLang.values) {
      final t = Strings(lang);
      for (final key in [
        'fourHourBonus',
        'dailyBonus',
        'rewardComeBack',
        'rewardComeBackDaily',
        'plusHammerOne',
        'bonusYouGet',
        'bonusNextIn',
        'bonusReadyNow',
        'bonusEveryFourHours',
        'bonusEveryDay',
      ]) {
        expect(
          t.ownEntry(key),
          isNotNull,
          reason: '${lang.code} has no "$key"',
        );
      }
      expect(
        t.rewardComeBackDaily,
        contains(RegExp('24|২৪')),
        reason: lang.code,
      );
      expect(
        t.rewardComeBack,
        isNot(contains(RegExp('24|২৪'))),
        reason: lang.code,
      );
      expect(t.plusHammers(1), contains('1'), reason: lang.code);
    }
  });
}
