// The one-time "no expectation of winnings" confirmation shown after sign-in.
//
// It is asked once per account on a device and never again — not after a
// quit, not after a relaunch — which is why it is keyed to the player, not to
// the session.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/state/consent.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a player who has never confirmed is asked', () async {
    expect(await NoWinningsConsent.isPending('u1'), isTrue);
  });

  test('nobody is asked while signed out', () async {
    expect(await NoWinningsConsent.isPending(null), isFalse);
    expect(await NoWinningsConsent.isPending(''), isFalse);
  });

  test('confirming is remembered across a relaunch', () async {
    await NoWinningsConsent.record('u1');
    expect(await NoWinningsConsent.isPending('u1'), isFalse);

    // A relaunched app reads the same store through a fresh instance.
    final prefs = await SharedPreferences.getInstance();
    expect(await NoWinningsConsent.isPending('u1', prefs), isFalse);
  });

  test('a different account on the same device is asked', () async {
    await NoWinningsConsent.record('u1');
    expect(await NoWinningsConsent.isPending('u2'), isTrue);
  });
}
