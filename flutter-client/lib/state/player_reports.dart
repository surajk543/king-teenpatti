import 'package:flutter/foundation.dart';

import '../l10n/strings.dart';
import '../models/report.dart';
import '../net/api_client.dart';

/// A report that got no answer at all: no connection, a timeout, a body that
/// was not JSON.
const reportNoAnswer = 'no_answer';

/// A report refusal, or [reportNoAnswer], in the player's language. The
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
class PlayerReports extends ChangeNotifier {
  PlayerReports({required this._api, required this._token});

  final ApiClient _api;
  final String? Function() _token;

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
    if (r == null || _submitting || _sent) return false;
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
    try {
      await _api
          .reportPlayer(
            token,
            reportedUserId: target,
            reason: reason.wire,
            description: _clean,
          )
          .timeout(timeout);
      _reported.add(target);
    } on ApiException catch (e) {
      error = e.code ?? 'internal_error';
      if (error == 'already_reported') _reported.add(target);
    } catch (_) {
      error = reportNoAnswer;
    }
    if (seq != _seq) return error == null;
    _submitting = false;
    _error = error;
    _sent = error == null;
    _notify();
    return _sent;
  }

  /// Everything of the account that was signed in, forgotten.
  void reset() {
    _reported.clear();
    close();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
