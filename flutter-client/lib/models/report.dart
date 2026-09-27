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

/// A report's status as moderation has it (`player_reports.status`). The
/// player only reads it; moderation sets it.
abstract final class ReportStatus {
  static const pending = 'PENDING';
  static const underReview = 'UNDER_REVIEW';
  static const actionTaken = 'ACTION_TAKEN';
  static const dismissed = 'DISMISSED';
}

/// One report the signed-in player filed, as `GET /api/reports/mine` lists it
/// (owner, 27 Sep 2026: "all the players he reported in detail status,
/// description, time he reported but don't show the reported user id"): who
/// it is about by name and picture only — the wire carries no user id, and
/// neither does this — why, what they wrote, where the two met, its status,
/// and when.
class FiledReport {
  const FiledReport({
    required this.displayName,
    required this.pictureUrl,
    required this.gone,
    required this.reason,
    required this.description,
    required this.game,
    required this.category,
    required this.variant,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  final String displayName;
  final String? pictureUrl;

  /// The reported account has been deleted since: no name, no picture.
  final bool gone;

  /// The reason's wire value ([ReportReason.wire]); [reasonKind] names it.
  final String reason;
  final String description;

  /// Where the two met: the engine (`teen_patti`, `poker`), the category
  /// (`seen` …), the variant or "".
  final String game;
  final String category;
  final String variant;

  /// One of [ReportStatus].
  final String status;

  /// Filed and last changed, epoch ms (the server's clock).
  final int createdAt;
  final int updatedAt;

  /// The reason this build knows, or null for one it has never heard of.
  ReportReason? get reasonKind {
    for (final r in ReportReason.values) {
      if (r.wire == reason) return r;
    }
    return null;
  }

  /// One report off the wire; null for anything that is not one.
  static FiledReport? fromJson(Object? json) {
    if (json is! Map) return null;
    String s(Object? v) => v is String ? v : '';
    int n(Object? v) => v is num && v.isFinite ? v.toInt() : 0;
    final player = json['player'] is Map ? json['player'] as Map : const {};
    final picture = player['profilePicture'] is Map
        ? player['profilePicture'] as Map
        : const {};
    final url = picture['url'];
    return FiledReport(
      displayName: s(player['displayName']),
      pictureUrl: url is String && url.isNotEmpty ? url : null,
      gone: player['gone'] == true,
      reason: s(json['reason']),
      description: s(json['description']),
      game: s(json['game']),
      category: s(json['category']),
      variant: s(json['variant']),
      status: s(json['status']),
      createdAt: n(json['createdAt']),
      updatedAt: n(json['updatedAt']),
    );
  }

  /// [reports] newest first — by when each was filed; the order the server
  /// sends, kept stable for two filed in the same millisecond.
  static List<FiledReport> newestFirst(Iterable<FiledReport> reports) {
    final list = reports.toList();
    final order = {for (final (i, r) in list.indexed) r: i};
    list.sort((a, b) {
      final by = b.createdAt.compareTo(a.createdAt);
      return by != 0 ? by : order[a]!.compareTo(order[b]!);
    });
    return list;
  }
}
