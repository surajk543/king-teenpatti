// A countdown with a known window never shows more than the window's whole
// seconds (24 Sep 2026, owner's "fix all bugs"; release review B6). The
// deadlines are the SERVER's clock; on TP_Small, whose clock ran behind the
// server's, the variation picker's first frame read 11 for a 10 s window.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/variation_prompt.dart';

int _now() => DateTime.now().millisecondsSinceEpoch;

void main() {
  group('countdownSeconds', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1000000000);
    int at(int ms) => now.millisecondsSinceEpoch + ms;

    test('is clamped to the window when a phone runs behind the server', () {
      // 10.6 s left by this phone's clock of a 10 s window.
      expect(countdownSeconds(at(10600), totalMs: 10000, now: now), 10);
      // The 8 s 5-Card pick.
      expect(countdownSeconds(at(9100), totalMs: 8000, now: now), 8);
    });

    test('counts whole seconds up, as before, inside the window', () {
      expect(countdownSeconds(at(9001), totalMs: 10000, now: now), 10);
      expect(countdownSeconds(at(4200), totalMs: 10000, now: now), 5);
      expect(countdownSeconds(at(1), totalMs: 10000, now: now), 1);
    });

    test('is 0 once the deadline has passed, or with no deadline', () {
      expect(countdownSeconds(at(0), totalMs: 10000, now: now), 0);
      expect(countdownSeconds(at(-500), totalMs: 10000, now: now), 0);
      expect(countdownSeconds(0, totalMs: 10000, now: now), 0);
    });

    test('with no known window it is the deadline alone', () {
      expect(countdownSeconds(at(10600), now: now), 11);
    });
  });

  testWidgets('the picker first frame never reads past its window', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(sound: false),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              child: VariationCountdown(
                // The server's deadline, 10.8 s ahead of a phone that runs
                // behind it, for a 10 s window.
                deadlineMs: _now() + 10800,
                totalMs: 10000,
                digitsHeight: 30,
              ),
            ),
          ),
        ),
      ),
    );
    final digits = tester.widget<Text>(
      find.byKey(const ValueKey('variation-seconds')),
    );
    expect(digits.data, '10');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('a variation window and an unfunded seat say the same', () {
    final window = VariationState.fromJson({
      'selecting': true,
      'userId': 'u1',
      'deadline': _now() + 10800,
      'timeoutMs': 10000,
    });
    expect(window.secondsLeft, 10);

    final you = You.fromJson({
      'userId': 'u1',
      'seatIndex': 0,
      'unfundedDeadline': _now() + 30900,
    });
    final now = DateTime.now();
    expect(you.unfundedSecondsLeft(now, totalMs: 30000), 30);
    // With no grace length known it is the deadline alone.
    expect(you.unfundedSecondsLeft(now), 31);
  });
}
