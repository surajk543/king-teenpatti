// A `canceled` from Google sign-in is the player's decision only when it says
// so (24 Sep 2026). The descriptions below are the ones Android reported on a
// Play Store emulator: backing out with the back key and with a tap outside
// the picker, and a release build signed with a certificate the Cloud project
// has no Android client for (status=UNREGISTERED_ON_API_CONSOLE).
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/net/social_sign_in.dart';

void main() {
  test('backing out of the account picker is the player\'s decision', () {
    expect(SocialSignIn.playerCancelled('[16] Cancelled by user.'), isTrue);
    // Credential Manager's own wording, when the picker is closed under it.
    expect(
      SocialSignIn.playerCancelled('activity is cancelled by the user.'),
      isTrue,
    );
    // No description at all: read as the player's, as before.
    expect(SocialSignIn.playerCancelled(null), isTrue);
    expect(SocialSignIn.playerCancelled(''), isTrue);
  });

  test('an unregistered signing certificate is not a cancel', () {
    // Reported as canceled after the account was picked; returning null there
    // left the player on the login screen with nothing said.
    expect(
      SocialSignIn.playerCancelled('[16] Account reauth failed.'),
      isFalse,
    );
  });
}
