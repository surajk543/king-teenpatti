import 'package:in_app_update/in_app_update.dart';

/// Whether a newer build of the game is waiting on Google Play.
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
enum UpdateStatus {
  /// No update, or Play cannot say — carry on to sign-in.
  none,

  /// A newer build exists and Play can install it in place.
  available,

  /// A newer build exists but Play cannot run its in-app flow, so the player
  /// has to be sent to the store listing instead.
  availableManual,
}

class AppUpdate {
  const AppUpdate();

  /// Asks Play whether there is a newer build.
  ///
  /// Never throws: every failure — no Play, no network, an old Play Store —
  /// comes back as [UpdateStatus.none], because a player who cannot be told
  /// about an update must still be able to play.
  Future<UpdateStatus> check() async {
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
  /// leave the prompt up rather than pretending it worked.
  Future<bool> startImmediate() async {
    try {
      final result = await InAppUpdate.performImmediateUpdate();
      return result == AppUpdateResult.success;
    } catch (_) {
      return false;
    }
  }
}
