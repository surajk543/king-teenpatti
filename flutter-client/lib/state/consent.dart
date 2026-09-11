import 'package:shared_preferences/shared_preferences.dart';

/// The one-time statement a player confirms before the game opens: that they
/// expect no money or other enrichment from playing.
///
/// Recorded per account on this device, and never asked of that account here
/// again — not after a quit, not after a relaunch. Keyed to the account rather
/// than the device so a second person signing in on the same phone confirms
/// it for themselves. Nothing is sent to the server; the game's economy has
/// no cash value and the server has no reason to know who has read that.
///
/// Kept apart from [GameState] so it can be tested without the rest of a
/// session — constructing the state starts Play billing, which no unit test
/// can reach.
class NoWinningsConsent {
  const NoWinningsConsent._();

  static String keyFor(String userId) => 'noWinningsAck:$userId';

  /// Whether [userId] still owes the confirmation. Nobody owes it while
  /// signed out.
  static Future<bool> isPending(
    String? userId, [
    SharedPreferences? prefs,
  ]) async {
    if (userId == null || userId.isEmpty) return false;
    prefs ??= await SharedPreferences.getInstance();
    return prefs.getBool(keyFor(userId)) != true;
  }

  /// Records that [userId] confirmed the statement on this device.
  static Future<void> record(String userId, [SharedPreferences? prefs]) async {
    prefs ??= await SharedPreferences.getInstance();
    await prefs.setBool(keyFor(userId), true);
  }
}
