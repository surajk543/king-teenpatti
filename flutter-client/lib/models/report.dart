/// Report Player (owner, 27 Sep 2026): the reasons a player may report
/// another for, as the server matches them (`POST /api/reports`,
/// go-server/internal/auth/reports.go ReportReasons) — exactly these values,
/// in this order. The words the app shows for each are the player's language
/// (`Strings.reportReason`); the value is the wire's.
enum ReportReason {
  cheating('CHEATING'),
  harassment('HARASSMENT'),
  abusiveLanguage('ABUSIVE_LANGUAGE'),
  spam('SPAM'),
  inappropriateBehavior('INAPPROPRIATE_BEHAVIOR'),
  suspiciousGameplay('SUSPICIOUS_GAMEPLAY'),
  collusion('COLLUSION'),
  exploitingBug('EXPLOITING_BUG'),
  other('OTHER');

  const ReportReason(this.wire);

  /// What the server is sent.
  final String wire;

  /// OTHER says what happened; every other reason may.
  bool get needsDescription => this == other;
}

/// The longest description the server accepts (REPORT_DESCRIPTION_MAX's
/// default), counted as the server counts it: in Unicode code points
/// ([reportDescriptionLength]).
const reportDescriptionMax = 500;

/// A description's length as the server measures it: code points, so an
/// emoji of two code points counts two, and the field can never let through
/// a description the server would refuse as too long.
int reportDescriptionLength(String text) => text.runes.length;

/// How the signed-in player stands against the report limit (owner, 27 Sep
/// 2026: "if user has reported 2 player, then reporting by him should be
/// disabled in UI, and show a cool down time in UI when can he report
/// again"): `GET /api/reports/limit`'s `limit`, and the same on a report
/// filed (201) or refused for the limit (429). The server counts; the app
/// only shows it.
class ReportLimit {
  const ReportLimit({
    required this.max,
    required this.used,
    required this.remaining,
    this.availableAt,
  });

  /// The reports allowed in the window; 0 = no limit.
  final int max;

  /// The reports this player filed within the window.
  final int used;

  /// How many more the window allows now.
  final int remaining;

  /// When the next report opens, on THIS phone's clock — the server's wait
  /// (`waitMs`) added to the moment its answer arrived, so a phone whose clock
  /// is wrong still counts to the server's moment. Null while one can be
  /// sent now.
  final DateTime? availableAt;

  /// Whether no report can be sent at [now].
  bool limitedAt(DateTime now) {
    final at = availableAt;
    return max > 0 && remaining <= 0 && at != null && now.isBefore(at);
  }

  /// How long until the next report opens at [now]; zero once it has.
  Duration waitAt(DateTime now) {
    final at = availableAt;
    if (at == null || !now.isBefore(at)) return Duration.zero;
    return at.difference(now);
  }

  /// The wire's `{max, used, remaining, windowMs, availableAt, waitMs}`,
  /// received at [receivedAt]; null for anything that is not an object.
  static ReportLimit? fromJson(Object? json, {required DateTime receivedAt}) {
    if (json is! Map) return null;
    int n(String key) {
      final v = json[key];
      return v is num && v.isFinite ? v.toInt() : 0;
    }

    final remaining = n('remaining');
    final wait = n('waitMs');
    return ReportLimit(
      max: n('max'),
      used: n('used'),
      remaining: remaining,
      availableAt: remaining <= 0 && wait > 0
          ? receivedAt.add(Duration(milliseconds: wait))
          : null,
    );
  }
}
