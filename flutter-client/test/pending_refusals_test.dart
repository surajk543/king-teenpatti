// Two refusals the server gives a Teen Patti move while something else is
// still being decided (24 Sep 2026, owner's "fix all bugs"), said in the
// player's language rather than in the server's English:
//   sideshow_pending — the player's own sideshow request is still waiting for
//                      its answer;
//   pick_pending     — a Sideshow, Force Sideshow, Missile or Show while a
//                      player is still choosing their three cards under
//                      5-Card Teen Patti.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/state/game_state.dart';

GameState _newState() {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state;
}

void main() {
  const english = Strings(AppLang.english);

  test('sideshow_pending and pick_pending are said in every language', () {
    final state = _newState();
    for (final lang in AppLang.values) {
      state.lang = lang;
      final t = Strings(lang);
      for (final (code, key, words) in [
        (
          'sideshow_pending',
          'sideshowPendingRefusal',
          t.sideshowPendingRefusal,
        ),
        ('pick_pending', 'pickPendingRefusal', t.pickPendingRefusal),
      ]) {
        // The server's English is never what the player reads.
        final said = state.refusalText(code, 'server english for $code');
        expect(said, words, reason: '${lang.code} $code');
        // Each language has words of its own, not the English fallback.
        final own = t.ownEntry(key);
        expect(own, isNotNull, reason: '${lang.code} has no "$key"');
        expect(own!.trim(), isNotEmpty, reason: '${lang.code} "$key"');
        if (lang != AppLang.english) {
          expect(
            own,
            isNot(english.ownEntry(key)),
            reason: '${lang.code} "$key" is the English',
          );
        }
      }
    }
    state.dispose();
  });

  test('the English says what to wait for', () {
    expect(english.sideshowPendingRefusal, contains('sideshow'));
    expect(english.pickPendingRefusal, contains('three cards'));
  });
}
