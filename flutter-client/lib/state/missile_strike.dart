import 'package:flutter/foundation.dart';

/// A missile volley being shown to the table: one missile from the player who
/// fired to every other player still in the hand (owner, 14 Sep 2026).
///
/// Presentation only. By the time this exists the server has already compared
/// every hand and settled the pot; the volley decides nothing, it only decides
/// *when* the table is shown what already happened — the missiles land, then
/// the cards turn over and the winner is celebrated.
@immutable
class MissileStrike {
  const MissileStrike({
    required this.handNo,
    required this.fromUserId,
    required this.targetUserIds,
    required this.startedAt,
  });

  /// One volley's identity. A hand ends with the missile, so a firer cannot
  /// fire twice in one hand; the pair names it exactly.
  static String keyFor(int handNo, String fromUserId) => '$handNo:$fromUserId';

  final int handNo;

  /// Who fired, and so the pod every missile leaves from.
  final String fromUserId;

  /// Everyone else still in the hand when it was fired, in seat order. The
  /// n-th missile is launched n staggers after the first.
  final List<String> targetUserIds;

  /// When the client heard of it. The felt's animation starts a frame or two
  /// later and catches up to this, so the timers in `GameState` and the frames
  /// on screen agree on when each missile lands.
  final DateTime startedAt;

  String get key => keyFor(handNo, fromUserId);

  int get count => targetUserIds.length;

  /// Where [userId] is in the volley, or -1 when no missile is aimed at them.
  int indexOf(String? userId) =>
      userId == null ? -1 : targetUserIds.indexOf(userId);
}

/// When each part of a volley happens, measured from
/// [MissileStrike.startedAt]. One table of numbers read by both halves:
/// `GameState` holds the reveal on a timer, the felt draws the missiles on the
/// frame clock; the missiles land at [lastImpact], and the winner is told at
/// [reveal], once the explosions have played out.
abstract final class MissileTiming {
  /// Between one missile's launch and the next.
  static const stagger = Duration(milliseconds: 70);

  /// One missile's flight, launch to impact (owner, 14 Sep 2026: 1.3 s).
  static const flight = Duration(milliseconds: 1300);

  /// How long an explosion plays (owner, 14 Sep 2026: 0.44 s, and then the
  /// winner) — the drawing's own length, 11 frames at 25 fps, so the flipbook
  /// plays at its natural pace.
  static const explosion = Duration(milliseconds: 440);

  /// A breath after the reveal before the volley is gone.
  static const tail = Duration(milliseconds: 80);

  /// When the missile at [index] lands.
  static Duration impact(int index) => stagger * index + flight;

  /// When the last of [count] missiles lands and its explosion starts.
  static Duration lastImpact(int count) => impact(count <= 1 ? 0 : count - 1);

  /// When the cards turn over and the winner is announced: once the last
  /// explosion has played out (owner, 14 Sep 2026). It used to be the moment
  /// the last missile landed, over the explosions, which gave the result
  /// away before the blast had been seen.
  static Duration reveal(int count) => lastImpact(count) + explosion;

  /// The whole volley for [count] missiles, launch to a breath past the
  /// reveal — so nothing it holds back is let go before the reveal itself.
  static Duration total(int count) => reveal(count) + tail;

  /// [d] as a share of [total] for [count] missiles, for an animation that
  /// runs 0 to 1 over it.
  static double share(Duration d, int count) =>
      d.inMicroseconds / total(count).inMicroseconds;
}
