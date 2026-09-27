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
