// The daily XP missions the player has just completed (owner, 27 Sep 2026:
// "whenever xp mission completed, show top notification bar for 5 seconds
// showing this is completed and xp increased"). Pure bookkeeping: which
// sources a `player:level` shows earned that the standing before it had not,
// queued one bar each for [XpMissionHost] to show in turn.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/dtos.dart';

/// One completed mission, as the bar shows it.
///
/// The source's name, mark and XP come from the level ladder
/// (`GET /api/levels`), which may still be on its way when the award lands:
/// [source] is what was known then, and the bar asks the ladder again when it
/// is drawn ([sourceIn]).
@immutable
class XpMissionNews {
  const XpMissionNews({
    required this.id,
    required this.code,
    required this.times,
    required this.xp,
    required this.total,
    this.source,
    this.goal,
    this.levelUp,
    this.levelUpTaxBps,
  });

  /// Unique for the life of the app: what the bar is keyed on, so a second
  /// completion of the same source is a new bar.
  final int id;

  /// The source's code ("WIN_PAIR").
  final String code;

  /// How many times this award earned it (1 as seeded).
  final int times;

  /// The source as the ladder described it when the award landed; null where
  /// the ladder was not read yet.
  final LadderSource? source;

  /// The XP this mission gave, or null where neither the ladder nor the award
  /// says (an unknown source sharing an award with another).
  final int? xp;

  /// The player's XP once this mission's is counted; null where an earlier
  /// mission of the same award gave an XP nothing says (the ladder could not
  /// be read, and two sources it would have named shared the award).
  final int? total;

  /// The XP that reaches the next level from [total]; null at the top of the
  /// ladder, or where nothing says.
  final int? goal;

  /// The level this award lifted the player to — carried by the award's LAST
  /// bar only; null when it lifted them nowhere.
  final PlayerLevel? levelUp;

  /// The winning tax the player pays now, in basis points, when the level up
  /// changed it — the news the level-up toast used to carry ("… your winning
  /// tax is now 19.71%"), which the bar says instead. Null when it did not
  /// change (a badge keeps the rate lower than either level's) and on every
  /// bar but the one with [levelUp].
  final int? levelUpTaxBps;

  /// The source as [ladder] describes it now, else as it did.
  LadderSource? sourceIn(LevelLadder? ladder) {
    for (final s in ladder?.sources ?? const <LadderSource>[]) {
      if (s.code == code) return s;
    }
    return source;
  }

  /// The XP to show: this mission's, else the ladder's figure for it.
  int? xpIn(LevelLadder? ladder) {
    if (xp != null) return xp;
    final s = sourceIn(ladder);
    return s == null ? null : s.xp * times;
  }
}

/// The queue of completed missions, owned by GameState: its own notifier, so
/// the bar never rebuilds with GameState's one-second tick.
class XpMissions extends ChangeNotifier {
  final List<XpMissionNews> _queue = [];
  int _nextId = 1;

  /// The bar on screen (or arriving), or null.
  XpMissionNews? get current => _queue.isEmpty ? null : _queue.first;

  /// Everything waiting, the current bar first.
  List<XpMissionNews> get queue => List.unmodifiable(_queue);

  /// Queues the missions the award between [before] and [after] completed;
  /// returns them (empty when it completed none).
  List<XpMissionNews> award(
    PlayerLevel? before,
    PlayerLevel after,
    LevelLadder? ladder, {
    int? levelUpTaxBps,
  }) {
    final news = completions(
      before,
      after,
      ladder,
      firstId: _nextId,
      levelUpTaxBps: levelUpTaxBps,
    );
    if (news.isEmpty) return news;
    _nextId += news.length;
    _queue.addAll(news);
    notifyListeners();
    return news;
  }

  /// The bar [id] has been shown and gone: the next one may come.
  void shown(int id) {
    final before = _queue.length;
    _queue.removeWhere((n) => n.id == id);
    if (_queue.length != before) notifyListeners();
  }

  /// Sign-out, account deletion: nothing of this player's is shown to the
  /// next.
  void clear() {
    if (_queue.isEmpty) return;
    _queue.clear();
    notifyListeners();
  }

  /// Two `resetsAt` this close are one window.
  static const int sameWindowMs = 60 * 1000;

  /// The missions an award completed — the rule, pure, so it can be tested
  /// on its own:
  ///
  ///  * only a genuine award counts: the XP rose. A standing that did not
  ///    raise it (the same figures again, a decrease, a window rolling over
  ///    with nothing earned) completes nothing;
  ///  * [after] must carry a daily window, and [before] a level: without the
  ///    one nothing was earned, without the other nothing can be compared;
  ///  * within one window (the same `resetsAt`, give or take
  ///    [sameWindowMs]), a source is completed when
  ///    its count went up. When the window changed — it rolled over, or
  ///    [before] had none yet (it opens at the player's first completed hand,
  ///    which may itself be a win) — the old counts are gone, and a source
  ///    is completed when the NEW window has earned it: the counts that were
  ///    reset are never read as completions, and a count that fell is never
  ///    one;
  ///  * one bar per source, in the ladder's order (unknown codes after, by
  ///    code). Each carries its XP — the ladder's figure, or, where exactly
  ///    ONE source is one the ladder cannot name, whatever of the award the
  ///    others do not account for; with two or more such sources nothing
  ///    says how the rest divides, and they carry none — and the running
  ///    total after it (none once a mission before it gave an XP nothing
  ///    says). The last carries the award's own total and the level it
  ///    reached, when it reached one, with [levelUpTaxBps].
  static List<XpMissionNews> completions(
    PlayerLevel? before,
    PlayerLevel after,
    LevelLadder? ladder, {
    int firstId = 1,
    int? levelUpTaxBps,
  }) {
    final daily = after.daily;
    if (before == null || daily == null) return const [];
    final gained = after.xp - before.xp;
    if (gained <= 0) return const [];
    final old = before.daily;
    // The same window within a minute: the server says when a window ends
    // as its start plus its length, the same figure every time, and a new
    // window ends a whole window later (it opens at the first hand after
    // the old one ended) — the margin only forgives a clock's rounding.
    final sameWindow =
        old != null && (old.resetsAt - daily.resetsAt).abs() < sameWindowMs;
    final baseline = sameWindow ? old.claimed : const <String, int>{};

    final earned = <String, int>{};
    for (final MapEntry(key: code, value: n) in daily.claimed.entries) {
      final up = n - (baseline[code] ?? 0);
      if (up > 0) earned[code] = up;
    }
    if (earned.isEmpty) return const [];

    final sources = ladder?.sources ?? const <LadderSource>[];
    LadderSource? sourceOf(String code) {
      for (final s in sources) {
        if (s.code == code) return s;
      }
      return null;
    }

    int rank(String code) {
      final i = sources.indexWhere((s) => s.code == code);
      return i < 0 ? sources.length : i;
    }

    final codes = earned.keys.toList()
      ..sort((a, b) {
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : a.compareTo(b);
      });

    // What the ladder accounts for, and what is left for the rest.
    var known = 0;
    final unknown = <String>[];
    for (final code in codes) {
      final s = sourceOf(code);
      if (s == null) {
        unknown.add(code);
      } else {
        known += s.xp * earned[code]!;
      }
    }
    final rest = math.max(0, gained - known);

    int? goalFor(int? xp) {
      if (xp == null) return null;
      final levels = ladder?.levels ?? const <LadderLevel>[];
      if (levels.isNotEmpty) {
        for (final l in levels) {
          if (l.minXp > xp) return l.minXp;
        }
        return null;
      }
      final next = after.next;
      return next != null && next.minXp > xp ? next.minXp : null;
    }

    final out = <XpMissionNews>[];
    int? running = before.xp;
    for (var i = 0; i < codes.length; i++) {
      final code = codes[i];
      final last = i == codes.length - 1;
      final s = sourceOf(code);
      final int? xp;
      if (s != null) {
        xp = s.xp * earned[code]!;
      } else if (unknown.length == 1 && rest > 0) {
        xp = rest;
      } else {
        xp = null;
      }
      running = last
          ? after.xp
          : running == null || xp == null
          ? null
          : math.min(after.xp, running + xp);
      final total = running;
      final levelUp = last && after.level > before.level ? after : null;
      out.add(
        XpMissionNews(
          id: firstId + i,
          code: code,
          times: earned[code]!,
          source: s,
          xp: xp,
          total: total,
          goal: goalFor(total),
          levelUp: levelUp,
          levelUpTaxBps: levelUp == null ? null : levelUpTaxBps,
        ),
      );
    }
    return out;
  }
}
