import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Thrown when the build carries no credentials for the provider tapped.
///
/// Its own type because the alternative is a player being told the server is
/// unreachable when the server is fine and the build simply shipped without an
/// app id. [provider] is already display-cased, for putting straight on screen.
class SignInUnavailable implements Exception {
  const SignInUnavailable(this.provider);

  final String provider;

  @override
  String toString() => 'SignInUnavailable($provider)';
}

/// Getting a credential out of Google or Facebook.
///
/// Only that. Neither function talks to our server, decides anything about the
/// account, or knows what a session is — they hand back one string, and
/// GameState.loginWithProvider does the rest. Keeping it this narrow is what
/// lets the two providers, and guest play, share one path afterwards.
///
/// Both return null when the player backs out of the provider's own sheet.
/// That is a decision, not a failure, and it must not surface as an error.
class SocialSignIn {
  const SocialSignIn._();

  /// The Google Cloud **Web** client id, passed at build time:
  ///
  ///   flutter build apk --dart-define=GOOGLE_SERVER_CLIENT_ID=…apps.googleusercontent.com
  ///
  /// It is the *web* one even on Android, and it is what makes Google return
  /// an `idToken` at all — without it the sign-in succeeds and hands back a
  /// credential the server cannot verify. It must also be listed in the
  /// server's GOOGLE_CLIENT_IDS, because that is what the server checks the
  /// token's audience against.
  static const serverClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
  );

  static bool get googleConfigured => serverClientId.isNotEmpty;

  /// The Facebook app id, passed the same way:
  ///
  ///   --dart-define=FACEBOOK_APP_ID=1234567890
  ///
  /// Only used to decide whether a tap can succeed. The SDK itself reads the
  /// id from android/app/src/main/res/values/strings.xml, because that is
  /// where the native side looks and there is no way to hand it one from
  /// Dart — so this flag and that file have to be set together.
  static const facebookAppId = String.fromEnvironment('FACEBOOK_APP_ID');

  static bool get facebookConfigured => facebookAppId.isNotEmpty;

  static bool _googleReady = false;

  /// Signs in with Google and returns the OpenID token for our server.
  static Future<String?> google() async {
    if (!googleConfigured) throw const SignInUnavailable('Google');
    if (!_googleReady) {
      // v7 is a singleton that must be initialised once before any call.
      await GoogleSignIn.instance.initialize(serverClientId: serverClientId);
      _googleReady = true;
    }
    try {
      final account = await GoogleSignIn.instance.authenticate();
      return account.authentication.idToken;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }
  }

  /// Signs in with Facebook and returns the access token for our server.
  static Future<String?> facebook() async {
    if (!facebookConfigured) throw const SignInUnavailable('Facebook');
    final result = await FacebookAuth.instance.login(
      // The default set. Our server only needs the identity behind the token;
      // asking for more would put a longer consent screen in front of a
      // player for data the game never reads.
      permissions: const ['public_profile'],
    );
    switch (result.status) {
      case LoginStatus.success:
        return result.accessToken?.tokenString;
      case LoginStatus.cancelled:
        return null;
      case LoginStatus.failed:
      case LoginStatus.operationInProgress:
        throw StateError(result.message ?? 'Facebook sign-in failed');
    }
  }
}
