import 'dart:io' show Platform;

import 'package:in_app_update/in_app_update.dart';

/// Whether a newer build of the game is waiting on the store.
///
/// Asked once, before the player signs in. An old client talking to a server
/// that has moved on is the case this exists for: the wire contract is not
/// versioned, so a client that predates a change can misread what it is sent,
/// and the failure looks like a broken game rather than an old one.
///
/// # What it can and cannot see
///
/// Play answers only for a build Play itself installed. A side-loaded APK, a
/// debug build, an emulator without Play Services — all report "unavailable",
/// which is not an error and must not block anyone: refusing to let a
/// developer past a check that can never pass would be its own bug. So the
/// gate fails OPEN. It is a nudge backed by Play, not a security control.
///
/// If the reason for gating is that old clients break against a newer server,
/// Play cannot be the authority — it does not know what the server changed,
/// and its answer lags a release by hours. That needs a minimum version from
/// the server, which this deliberately does not pretend to be.
///
/// # iOS
///
/// There is no equivalent: the App Store has no in-app update API, and
/// `in_app_update` is an Android-only plugin. On iOS [AppUpdate.check] answers
/// [UpdateStatus.none] without asking anything, and the only route left is the
/// listing — which is exactly what the server's minimum build already drives
/// (`GameState._forceUpdate`), so nothing is lost but the in-place install.
enum UpdateStatus {
  /// No update, or the store cannot say — carry on to sign-in.
  none,

  /// A newer build exists and Play can install it in place.
  available,

  /// A newer build exists but Play cannot run its in-app flow, so the player
  /// has to be sent to the store listing instead.
  availableManual,
}

/// The app's numeric App Store id, passed at build time:
///
///   flutter build ipa --dart-define=APPLE_APP_ID=1234567890
///
/// Apple mints it when the app record is created in App Store Connect, so it
/// cannot be written down before there is a listing. Empty until then, and
/// [storeListingUris] answers with nothing rather than opening a dead page.
const _appleAppId = String.fromEnvironment('APPLE_APP_ID');

const _androidPackage = 'com.sungamestudio.kingteenpatti';

/// Where to send a player who has to update by hand, best route first.
///
/// Two entries per platform and for the same reason on each: the first opens
/// the store app directly and only works if it is installed, the second is the
/// web listing that always resolves. The caller tries them in order.
///
/// Empty on iOS until [_appleAppId] is set — a store link needs the number
/// Apple assigns, and an invented one would open somebody else's app.
List<String> storeListingUris() {
  if (Platform.isIOS) {
    if (_appleAppId.isEmpty) return const [];
    return [
      'itms-apps://itunes.apple.com/app/id$_appleAppId',
      'https://apps.apple.com/app/id$_appleAppId',
    ];
  }
  return const [
    'market://details?id=$_androidPackage',
    'https://play.google.com/store/apps/details?id=$_androidPackage',
  ];
}

class AppUpdate {
  const AppUpdate();

  /// Asks Play whether there is a newer build.
  ///
  /// Never throws: every failure — no Play, no network, an old Play Store —
  /// comes back as [UpdateStatus.none], because a player who cannot be told
  /// about an update must still be able to play. iOS answers the same, having
  /// nothing to ask.
  Future<UpdateStatus> check() async {
    if (!Platform.isAndroid) return UpdateStatus.none;
    try {
      final info = await InAppUpdate.checkForUpdate();
      if (info.updateAvailability != UpdateAvailability.updateAvailable) {
        return UpdateStatus.none;
      }
      return info.immediateUpdateAllowed
          ? UpdateStatus.available
          : UpdateStatus.availableManual;
    } catch (_) {
      return UpdateStatus.none;
    }
  }

  /// Runs Play's immediate-update flow: Play takes over the screen, downloads
  /// and installs, and restarts the app itself.
  ///
  /// Returns false when the player backed out or it failed, so the caller can
  /// leave the prompt up rather than pretending it worked. Always false on
  /// iOS, where the caller falls through to the listing.
  Future<bool> startImmediate() async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await InAppUpdate.performImmediateUpdate();
      return result == AppUpdateResult.success;
    } catch (_) {
      return false;
    }
  }
}
