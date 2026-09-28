import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app version gate, the client's half (owner, 28 Sep 2026: "the backend
/// controls the minimum supported app version. Flutter checks the backend
/// configuration … The backend must ALSO enforce the minimum version").
///
/// The server decides. It keeps, per platform, the oldest version allowed to
/// play, the newest it announces, a store link and whether the game is in
/// maintenance (go-server/internal/appversion, the app_versions rows), answers
/// `GET /api/app-config` with this build's state, and refuses a build below
/// the minimum at every signed-in door — REST 426 `update_required`, the
/// socket handshake's connect_error `update_required` — and every build while
/// in maintenance (503 / connect_error `maintenance`). This file holds what
/// the client needs to take part: its own identity on the wire, the one
/// semantic-version comparison it has ([SemVer]), and the verdict the update
/// and maintenance screens show ([AppGateVerdict]). No minimum is written
/// here: it is always the server's.

/// The refusal codes, as REST's `{error}` and the handshake's connect_error
/// `message` carry them.
const updateRequiredCode = 'update_required';
const maintenanceCode = 'maintenance';

/// How the app declares itself: two headers on every REST call, and the same
/// two values in the socket handshake's auth object, beside the token.
const appPlatformHeader = 'X-App-Platform';
const appVersionHeader = 'X-App-Version';
const appPlatformAuthKey = 'appPlatform';
const appVersionAuthKey = 'appVersion';

/// The platform this build declares: `android` or `ios`, from the platform
/// the framework is running on ([defaultTargetPlatform], which a test can
/// override); null anywhere else (desktop, web), which then declares nothing.
String? appPlatformName() => switch (defaultTargetPlatform) {
  TargetPlatform.android => 'android',
  TargetPlatform.iOS => 'ios',
  _ => null,
};

/// A semantic version's core, MAJOR.MINOR.PATCH, compared as numbers — never
/// as text, which puts "1.10.0" before "1.9.0". The server's comparison
/// (appversion.Parse) reads exactly the same shape: three decimal numbers
/// without leading zeros, at most nine digits each, optionally followed by a
/// `+build` suffix that is ignored. Anything else is not a version.
@immutable
class SemVer implements Comparable<SemVer> {
  const SemVer(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static const zero = SemVer(0, 0, 0);

  static final _component = RegExp(r'^(0|[1-9][0-9]{0,8})$');
  static final _build = RegExp(r'^[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*$');

  /// [text] as a version, or null when it is not one.
  static SemVer? tryParse(String? text) {
    if (text == null) return null;
    var core = text;
    final plus = text.indexOf('+');
    if (plus >= 0) {
      final build = text.substring(plus + 1);
      if (build.length > 64 || !_build.hasMatch(build)) return null;
      core = text.substring(0, plus);
    }
    final parts = core.split('.');
    if (parts.length != 3 || !parts.every(_component.hasMatch)) return null;
    return SemVer(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }

  bool get isZero => major == 0 && minor == 0 && patch == 0;

  @override
  int compareTo(SemVer other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator <(SemVer other) => compareTo(other) < 0;
  bool operator >(SemVer other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) => other is SemVer && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// The four states (the server's words, `status` on `GET /api/app-config`).
enum AppGateStatus {
  normal('NORMAL'),
  softUpdate('SOFT_UPDATE'),
  forceUpdate('FORCE_UPDATE'),
  maintenance('MAINTENANCE');

  const AppGateStatus(this.wire);
  final String wire;

  /// Reads the server's word; null for anything else.
  static AppGateStatus? fromWire(Object? value) {
    for (final s in values) {
      if (s.wire == value) return s;
    }
    return null;
  }

  /// Whether this state keeps the player out of the game.
  bool get blocks => this == forceUpdate || this == maintenance;

  /// How strict it is: the stricter of two readings wins.
  int get _rank => index;
}

/// One platform's row as `GET /api/app-config` shows it.
@immutable
class AppPlatformInfo {
  const AppPlatformInfo({
    this.maintenance = false,
    this.minimumVersion,
    this.latestVersion,
    this.storeUrl,
    this.message,
  });

  final bool maintenance;
  final SemVer? minimumVersion;
  final SemVer? latestVersion;
  final String? storeUrl;
  final String? message;

  factory AppPlatformInfo.fromJson(Object? j) {
    if (j is! Map) return const AppPlatformInfo();
    return AppPlatformInfo(
      maintenance: j['status'] == AppGateStatus.maintenance.wire,
      minimumVersion: SemVer.tryParse(_text(j['minimumVersion'])),
      latestVersion: SemVer.tryParse(_text(j['latestVersion'])),
      storeUrl: _text(j['storeUrl']),
      message: _text(j['message']),
    );
  }
}

/// `GET /api/app-config`: this build's state as the server worked it out,
/// and both platforms' rows.
@immutable
class AppConfigInfo {
  const AppConfigInfo({
    required this.status,
    this.android = const AppPlatformInfo(),
    this.ios = const AppPlatformInfo(),
  });

  /// The server's verdict for the platform and version this build declared;
  /// null when the answer named none the client knows.
  final AppGateStatus? status;
  final AppPlatformInfo android;
  final AppPlatformInfo ios;

  factory AppConfigInfo.fromJson(Map<String, dynamic> j) => AppConfigInfo(
    status: AppGateStatus.fromWire(j['status']),
    android: AppPlatformInfo.fromJson(j['android']),
    ios: AppPlatformInfo.fromJson(j['ios']),
  );

  AppPlatformInfo? rowFor(String? platform) => switch (platform) {
    'android' => android,
    'ios' => ios,
    _ => null,
  };
}

/// What the gate decided for this build, and what the screens need to show
/// it: the state, where Update now goes, the version to reach, and the
/// operator's words when they wrote any (null: the app's own, translated).
@immutable
class AppGateVerdict {
  const AppGateVerdict(
    this.status, {
    this.storeUrl,
    this.minimumVersion,
    this.latestVersion,
    this.message,
  });

  final AppGateStatus status;
  final String? storeUrl;
  final SemVer? minimumVersion;
  final SemVer? latestVersion;
  final String? message;

  bool get blocks => status.blocks;

  /// A signed-in door's refusal — REST's `{error, message, storeUrl?,
  /// minimumVersion?}` — or null when [body] is not one of the gate's.
  static AppGateVerdict? fromRefusal(Map<String, dynamic> body) {
    final code = body['error'];
    return _fromCode(code is String ? code : null, body);
  }

  /// The handshake's refusal — connect_error `{message: code, data:
  /// {message, storeUrl?, minimumVersion?}}` — or null when it is not one of
  /// the gate's.
  static AppGateVerdict? fromConnectError(Object? error) {
    if (error is! Map) return null;
    final code = error['message'];
    final data = error['data'];
    return _fromCode(
      code is String ? code : null,
      data is Map ? Map<String, dynamic>.from(data) : const {},
    );
  }

  static AppGateVerdict? _fromCode(String? code, Map<String, dynamic> j) {
    final status = switch (code) {
      updateRequiredCode => AppGateStatus.forceUpdate,
      maintenanceCode => AppGateStatus.maintenance,
      _ => null,
    };
    if (status == null) return null;
    return AppGateVerdict(
      status,
      storeUrl: _text(j['storeUrl']),
      minimumVersion: SemVer.tryParse(_text(j['minimumVersion'])),
      message: _serverWords(_text(j['message']), status),
    );
  }
}

/// The server's default sentences, which the app shows in the player's own
/// language instead: only an operator's own message is shown as it came.
const _serverDefaults = {
  AppGateStatus.forceUpdate:
      'A new version of King Teen Patti is required to continue playing.',
  AppGateStatus.maintenance:
      'King Teen Patti is temporarily unavailable. Please try again later.',
};

String? _serverWords(String? message, AppGateStatus status) =>
    message == null || message == _serverDefaults[status] ? null : message;

String? _text(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

/// This build's state from `GET /api/app-config`: the server's own verdict,
/// checked against the platform's row with this build's [SemVer] — and the
/// stricter of the two wins, so an answer that disagreed with its own rows
/// (or a server that sent no verdict) could never let an unsupported build
/// through. [platform] and [version] are what this build declares; with no
/// platform nothing but the server's verdict can be judged.
AppGateVerdict evaluateAppConfig(
  AppConfigInfo config, {
  required String? platform,
  required String? version,
}) {
  final row = config.rowFor(platform);
  var status = config.status ?? AppGateStatus.normal;
  if (row != null) {
    final local = _judge(row, SemVer.tryParse(version));
    if (local._rank > status._rank) status = local;
  }
  // A build that declares no platform is judged by the server against
  // android's row (every install that predates the gate is an Android one).
  final shown = row ?? config.android;
  return AppGateVerdict(
    status,
    storeUrl: shown.storeUrl,
    minimumVersion: shown.minimumVersion,
    latestVersion: shown.latestVersion,
    message: status.blocks ? _serverWords(shown.message, status) : null,
  );
}

/// The rule, as the server's appversion.Evaluate states it for an app build:
/// maintenance first; below a set minimum — or no readable version with one
/// set — a force update; below the announced latest a soft one.
AppGateStatus _judge(AppPlatformInfo row, SemVer? version) {
  if (row.maintenance) return AppGateStatus.maintenance;
  final minimum = row.minimumVersion ?? SemVer.zero;
  if (!minimum.isZero && (version == null || version < minimum)) {
    return AppGateStatus.forceUpdate;
  }
  final latest = row.latestVersion ?? SemVer.zero;
  if (version != null && version < latest) return AppGateStatus.softUpdate;
  return AppGateStatus.normal;
}

/// "Later" on the optional update, remembered on the phone (owner's brief:
/// "Do not repeatedly show the prompt"): the player is asked once per
/// announced version — a newer one announced later asks again — never at
/// every launch. The key is the announcement's own (the server's latest
/// version, or Play's nudge for this installed build).
class SoftUpdateMemory {
  static const prefsKey = 'softUpdateLater';

  /// Whether the prompt for [announcement] has not been answered Later.
  static bool shouldOffer(SharedPreferences prefs, String announcement) =>
      prefs.getString(prefsKey) != announcement;

  static Future<void> later(SharedPreferences prefs, String announcement) =>
      prefs.setString(prefsKey, announcement);
}
