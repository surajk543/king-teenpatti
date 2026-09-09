import 'package:flutter/foundation.dart';
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

/// Getting a credential out of Google.
///
/// Only that. It does not talk to our server, decide anything about the
/// account, or know what a session is — it hands back one string, and
/// GameState.loginWithProvider does the rest. Keeping it this narrow is what
/// lets a provider and guest play share one path afterwards, and is why adding
/// Facebook back later is a second function here and nothing else.
///
/// Returns null when the player backs out of Google's own sheet. That is a
/// decision, not a failure, and it must not surface as an error.
///
/// Facebook lived here until 10 Sep 2026. It was removed for the first
/// production release, not because it did not work, but because the
/// flutter_facebook_auth plugin pulls in com.facebook.android:facebook-core,
/// whose manifest injects AD_ID, four ACCESS_ADSERVICES_* permissions and the
/// install-referrer binding. Those force a "yes" on Play's Advertising ID
/// declaration for a game that carries no advertising at all — a contradiction
/// a reviewer is entitled to question. docs/social-login-setup.md has what to
/// restore.
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
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        // Sign-in succeeded and produced a credential our server cannot check.
        // The cause is always the same one: serverClientId is absent or is not
        // the WEB client, so Google had no audience to mint an ID token for.
        debugPrint(
          'Google sign-in: no idToken — serverClientId is not a Web client',
        );
        throw const SignInUnavailable('Google');
      }
      return idToken;
    } on GoogleSignInException catch (e) {
      // Log every one before deciding. Android's Credential Manager reports
      // several configuration errors as "canceled" *after* an account has been
      // picked (the plugin's own README says so), which is indistinguishable
      // from the player backing out. Without this line a wrong SHA-1 fingerprint
      // looks exactly like a change of mind and leaves nothing to debug.
      debugPrint('Google sign-in: ${e.code.name}: ${e.description ?? ''}');
      switch (e.code) {
        case GoogleSignInExceptionCode.canceled:
          return null;
        case GoogleSignInExceptionCode.clientConfigurationError:
        case GoogleSignInExceptionCode.providerConfigurationError:
          throw const SignInUnavailable('Google');
        default:
          rethrow;
      }
    }
  }
}
