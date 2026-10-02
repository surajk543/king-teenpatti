// The level a player has just reached (owner, 2 Oct 2026: "Use this animation
// to COngrats Player once his level upgraded , show a pop in UI, and Tell in
// pop up that something like that now you will pay less tax and how much less
// tax u pay tell that in pop up"). Pure bookkeeping: what the popup says,
// worked out when a `player:level` push lifts the player a level, and held
// for [LevelUpHost] to show.
import 'package:flutter/foundation.dart';

import '../models/dtos.dart';

/// One level up, as the popup tells it.
@immutable
class LevelUpNews {
  const LevelUpNews({
    required this.id,
    required this.from,
    required this.to,
    required this.paidBefore,
    required this.paidNow,
    this.rateBadge,
  });

  /// Unique for the life of the app: what the popup is keyed on.
  final int id;

  /// The level the player stood at, and the one they have reached.
  final PlayerLevel from;
  final PlayerLevel to;

  /// The winning tax the player paid before the level up and pays now, in
  /// basis points: the lowest of the level's and their badges', as the
  /// server charges it.
  final int paidBefore;
  final int paidNow;

  /// The badge that keeps the rate they pay BELOW the new level's own — the
  /// reason a level up changes nothing they pay — or null when the level's
  /// rate is what they pay.
  final PlayerBadge? rateBadge;

  /// How much less winning tax the player pays now, in basis points; 0 when
  /// the level up did not change what they pay.
  int get savedBps => paidNow < paidBefore ? paidBefore - paidNow : 0;

  /// Whether the level up lowered the tax the player pays.
  bool get paysLess => savedBps > 0;

  /// Whether the levels' own rates differ (they do on the owner's ladder; a
  /// ladder edited to give two levels one rate has nothing to say).
  bool get levelRateFell => to.taxBps < from.taxBps;
}

/// The level up waiting to be shown, owned by GameState: its own notifier, so
/// the popup never rebuilds with GameState's one-second tick.
class LevelUps extends ChangeNotifier {
  LevelUpNews? _current;
  int _nextId = 1;

  /// The popup on screen (or about to be), or null.
  LevelUpNews? get current => _current;

  /// Raises the popup for a level up from [from] to [to]. A second level up
  /// while one is still on screen does not stack a second popup: the one
  /// showing becomes the whole climb — it keeps the level it started from and
  /// what was paid there, and takes the new level and rate.
  LevelUpNews raise({
    required PlayerLevel from,
    required PlayerLevel to,
    required int paidBefore,
    required int paidNow,
    PlayerBadge? rateBadge,
  }) {
    final showing = _current;
    final news = LevelUpNews(
      id: _nextId++,
      from: showing?.from ?? from,
      to: to,
      paidBefore: showing?.paidBefore ?? paidBefore,
      paidNow: paidNow,
      rateBadge: rateBadge,
    );
    _current = news;
    notifyListeners();
    return news;
  }

  /// The popup [id] has been put away (its key, a tap outside, Back, or its
  /// time ran out). A stale id — the popup has since become a newer one — does
  /// nothing.
  void dismiss(int id) {
    if (_current?.id != id) return;
    _current = null;
    notifyListeners();
  }

  /// Sign-out, account deletion: nothing of this player's is shown to the
  /// next.
  void clear() {
    if (_current == null) return;
    _current = null;
    notifyListeners();
  }

  /// The winning tax an account at [level] holding [badges] pays, in basis
  /// points: the lowest of the level's rate and every badge's that still runs
  /// at [now] — the server's own rule (the lowest applies), worked out here
  /// only to say what the player paid BEFORE a level up; what they pay now is
  /// always the server's figure.
  static int paidAt(PlayerLevel level, List<PlayerBadge> badges, DateTime now) {
    var lowest = level.taxBps;
    final ms = now.millisecondsSinceEpoch;
    for (final b in badges) {
      final rate = b.taxBps;
      if (rate == null) continue;
      if (b.expiresAt > 0 && b.expiresAt <= ms) continue;
      if (rate < lowest) lowest = rate;
    }
    return lowest;
  }
}
