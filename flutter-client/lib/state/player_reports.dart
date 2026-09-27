import 'dart:async';

import 'package:flutter/foundation.dart';

import '../l10n/strings.dart';
import '../models/report.dart';
import '../net/api_client.dart';

/// A report that got no answer at all: no connection, a timeout, a body that
/// was not JSON.
const reportNoAnswer = 'no_answer';

/// A report refusal, or [reportNoAnswer], in the player's language.
/// `report_limit_reached` with a known wait is said by the page itself —
/// "Report limit reached" over a countdown (`ReportCooldown`); this is its
/// words when the server did not say how long. The
/// server's codes (go-server/internal/auth/reports.go) each have words; one
/// this build does not know — and a server failing — is the plain "something
/// went wrong". None of them says anything about what moderation will do.
String reportRefusalText(Strings t, String? code) => switch (code) {
  'already_reported' => t.reportAlready,
  'report_limit_reached' || 'rate_limited' => t.reportLimited,
  'player_not_at_table' => t.reportNotAtTable,
  'player_not_found' ||
  'invalid_player_id' ||
  'self_report' => t.reportInvalidPlayer,
  'description_required' => t.reportDescriptionRequired,
  'description_too_long' => t.reportDescriptionTooLong,
  reportNoAnswer => t.reportNetworkError,
  _ => t.reportServerError,
};

/// Report Player on the phone (owner, 27 Sep 2026): the report a player is
/// writing about another from the table's player drawer — who, the reason
/// chosen, what they wrote — and sending it (`POST /api/reports`).
///
/// A notifier of its own, owned by GameState beside [FriendsState], so the
/// drawer rebuilds for the report's own changes and never for GameState's
/// one-second tick. The client sends three things — the player, the reason,
/// the description — and nothing else: the table, the hand, the time and the
/// reporter are the server's to say.
///
/// One report is sent at a time: [submit] does nothing while one is out, and
/// the key that calls it is dead meanwhile. A player reported this session —
/// or one the server says was already reported — is remembered
/// ([wasReported]), so the drawer offers them no second report.
///
/// And the player's standing against the report limit ([limit]; owner, 27
/// Sep 2026: "if user has reported 2 player, then reporting by him should be
/// disabled in UI, and show a cool down time in UI when can he report
/// again"): read as a player drawer opens ([refreshLimit]) and taken from
/// every answer that changes it. While it is used up ([limited]) no report
/// can be started or sent, and the drawer counts down to [limitOpensAt]; the
/// moment that passes it is read again and the Report line comes back.
class PlayerReports extends ChangeNotifier {
  PlayerReports({required this._api, required this._token});

  final ApiClient _api;
  final String? Function() _token;

  /// The clock the limit is counted on: DateTime.now; a test sets its own.
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  /// Now, on [clock].
  DateTime now() => clock();

  /// A drawer opened within this of the last read does not read the limit
  /// again.
  static const limitFresh = Duration(seconds: 10);

  /// How long a report may take before it is given up as unanswered.
  static const timeout = Duration(seconds: 12);

  /// The player the report is about, while the drawer shows the report page;
  /// null otherwise.
  String? get target => _target;
  String? _target;

  /// The reason chosen, or null before one is.
  ReportReason? get reason => _reason;
  ReportReason? _reason;

  /// What the player has written so far.
  String get description => _description;
  String _description = '';

  /// True while the report is on its way.
  bool get submitting => _submitting;
  bool _submitting = false;

  /// Why the last try was refused (a server code, or [reportNoAnswer]); null
  /// when it was not.
  String? get error => _error;
  String? _error;

  /// True once the server has filed the report: the page thanks the player.
  bool get sent => _sent;
  bool _sent = false;

  final Set<String> _reported = {};
  int _seq = 0;
  bool _disposed = false;

  /// The player's own reports, newest first, as `GET /api/reports/mine` last
  /// listed them (the Friends page's Reported tab); null before the first
  /// read, and from a server that predates the list.
  List<FiledReport>? get mine => _mine;
  List<FiledReport>? _mine;

  /// True while the list is being read.
  bool get mineLoading => _mineLoading;
  bool _mineLoading = false;

  /// True when the last read of the list failed (and none has since
  /// succeeded); what was listed before stays on screen.
  bool get mineFailed => _mineFailed;
  bool _mineFailed = false;

  /// True once a read has answered, a server that predates the list
  /// included.
  bool get mineRead => _mineRead;
  bool _mineRead = false;
  int _mineSeq = 0;

  /// Reads the player's own reports (the Reported tab opening, a pull, a
  /// retry). One read at a time; an answer for an account signed out since is
  /// dropped.
  Future<void> loadMine() async {
    final token = _token();
    if (token == null || _mineLoading) return;
    final seq = _mineSeq;
    _mineLoading = true;
    _notify();
    try {
      final list = await _api.myReports(token).timeout(timeout);
      if (seq != _mineSeq || _disposed) return;
      _mine = list == null ? null : FiledReport.newestFirst(list);
      _mineFailed = false;
      _mineRead = true;
    } catch (_) {
      if (seq != _mineSeq || _disposed) return;
      _mineFailed = true;
    } finally {
      if (seq == _mineSeq) {
        _mineLoading = false;
        _notify();
      }
    }
  }

  /// The player's standing against the report limit, as the server last said
  /// it; null before it has (or from a server that does not say).
  ReportLimit? get limit => _limit;
  ReportLimit? _limit;
  DateTime? _limitReadAt;
  bool _limitReading = false;
  int _limitSeq = 0;
  Timer? _limitTimer;

  /// Whether every report the limit allows is used now: nothing can be
  /// reported until [limitOpensAt].
  bool get limited => _limit?.limitedAt(now()) ?? false;

  /// When the next report opens, while [limited]; null otherwise.
  DateTime? get limitOpensAt => limited ? _limit?.availableAt : null;

  /// How long until the next report opens; zero when one can be sent now.
  Duration get limitWait => _limit?.waitAt(now()) ?? Duration.zero;

  /// Reads the limit from the server (`GET /api/reports/limit`) — as a player
  /// drawer opens, so a player who has used every report finds the Report
  /// line off before they write anything. Skipped while a read is out, and
  /// within [limitFresh] of the last one unless [force]d. A failure keeps
  /// what was known; the server decides at Submit either way.
  Future<void> refreshLimit({bool force = false}) async {
    final token = _token();
    if (token == null || _limitReading) return;
    final last = _limitReadAt;
    if (!force && last != null && now().difference(last) < limitFresh) return;
    final seq = _limitSeq;
    _limitReading = true;
    try {
      final limit = await _api.reportLimit(token).timeout(timeout);
      if (seq != _limitSeq || _disposed) return;
      _limitReadAt = now();
      _setLimit(limit);
    } catch (_) {
      // Offline, a timeout, a 500: what was known stands.
    } finally {
      if (seq == _limitSeq) _limitReading = false;
    }
  }

  /// Takes [limit] as the standing now, and arms the moment it opens.
  void _setLimit(ReportLimit? limit) {
    _limit = limit;
    _limitTimer?.cancel();
    _limitTimer = null;
    if (limit != null && limit.limitedAt(now())) {
      // A beat past the server's moment, so the read that follows finds the
      // report counted out of the window.
      _limitTimer = Timer(
        limit.waitAt(now()) + const Duration(milliseconds: 500),
        _limitOpened,
      );
    } else if (limit != null && _error == 'report_limit_reached') {
      // The server now says a report is open: its refusal no longer stands.
      // (A server that says nothing leaves the refusal where it was.)
      _error = null;
    }
    _notify();
  }

  /// The wait is over: the Report line comes back at once, and the server is
  /// asked to say so too.
  void _limitOpened() {
    _limitTimer = null;
    if (_disposed) return;
    if (_error == 'report_limit_reached') _error = null;
    _notify();
    unawaited(refreshLimit(force: true));
  }

  /// Whether [userId] has been reported by this player this session (or the
  /// server said they had been already).
  bool wasReported(String? userId) =>
      userId != null && _reported.contains(userId);

  /// The description as it will be sent: trimmed.
  String get _clean => _description.trim();

  /// Whether the report can be sent now: a reason, a description where the
  /// reason needs one, none too long, and nothing already on its way.
  bool get canSubmit {
    final r = _reason;
    if (r == null || _submitting || _sent || limited) return false;
    if (r.needsDescription && _clean.isEmpty) return false;
    return reportDescriptionLength(_clean) <= reportDescriptionMax;
  }

  /// The drawer turns to the report page for [userId]: a fresh report.
  void open(String userId) {
    _seq++;
    _target = userId;
    _reason = null;
    _description = '';
    _submitting = false;
    _error = null;
    _sent = false;
    _notify();
  }

  /// The report page has gone — Cancel, Done, the drawer shut, another seat
  /// opened. A report still on its way is not taken back; its answer is only
  /// no longer shown. Quiet when [notify] is false (the drawer calls it as it
  /// is taken down).
  void close({bool notify = true}) {
    _seq++;
    _target = null;
    _reason = null;
    _description = '';
    _submitting = false;
    _error = null;
    _sent = false;
    if (notify) _notify();
  }

  void choose(ReportReason r) {
    if (_submitting || _sent) return;
    _reason = r;
    if (_error == 'description_required' && !r.needsDescription) _error = null;
    _notify();
  }

  void describe(String text) {
    if (_description == text) return;
    _description = text;
    if (_error == 'description_required' || _error == 'description_too_long') {
      _error = null;
    }
    _notify();
  }

  /// Sends the report. True once the server has filed it. Does nothing (and
  /// answers false) while a report is already on its way or when it cannot be
  /// sent yet.
  Future<bool> submit() async {
    final target = _target;
    final reason = _reason;
    if (target == null || reason == null || !canSubmit) return false;
    final token = _token();
    final seq = ++_seq;
    if (token == null) {
      _error = reportNoAnswer;
      _notify();
      return false;
    }
    _submitting = true;
    _error = null;
    _notify();
    String? error;
    ReportLimit? limit;
    var limitKnown = false;
    try {
      limit = await _api
          .reportPlayer(
            token,
            reportedUserId: target,
            reason: reason.wire,
            description: _clean,
          )
          .timeout(timeout);
      limitKnown = limit != null;
      _reported.add(target);
    } on ReportLimitRefusal catch (e) {
      error = e.code;
      limit = e.limit;
      limitKnown = limit != null;
    } on ApiException catch (e) {
      error = e.code ?? 'internal_error';
      if (error == 'already_reported') _reported.add(target);
    } catch (_) {
      error = reportNoAnswer;
    }
    // The standing the answer brought is the player's whatever page is up.
    if (limitKnown && !_disposed) {
      _limitReadAt = now();
      _limitSeq++;
      _limitReading = false;
      _setLimit(limit);
    } else if (error == null || error == 'report_limit_reached') {
      unawaited(refreshLimit(force: true));
    }
    if (seq != _seq) return error == null;
    _submitting = false;
    _error = error;
    _sent = error == null;
    _notify();
    return _sent;
  }

  /// Everything of the account that was signed in, forgotten — its limit
  /// too: the next account's is its own.
  void reset() {
    _reported.clear();
    _limitSeq++;
    _limitReading = false;
    _limit = null;
    _limitReadAt = null;
    _limitTimer?.cancel();
    _limitTimer = null;
    _mineSeq++;
    _mine = null;
    _mineLoading = false;
    _mineFailed = false;
    _mineRead = false;
    close();
  }

  @override
  void dispose() {
    _disposed = true;
    _limitTimer?.cancel();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
