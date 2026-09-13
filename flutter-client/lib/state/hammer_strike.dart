import 'package:flutter/foundation.dart';

/// A Force Sideshow being shown to the table: the hammer thrown from the
/// player who paid for it to the player it was forced on (owner, 14 Sep 2026).
///
/// Presentation only. The server has already compared the hands and packed
/// the loser by the time this exists; the strike decides nothing, it only
/// decides *when* the table is shown what already happened — the hammer lands,
/// then the cards turn over, then the loser folds.
@immutable
class HammerStrike {
  const HammerStrike({
    required this.handNo,
    required this.fromUserId,
    required this.toUserId,
    required this.packedUserId,
    required this.startedAt,
  });

  /// One sideshow's identity, whichever of its two events announced it.
  ///
  /// A player gets `game:sideshowReveal` and then `game:sideshowResolved` for
  /// the same sideshow; everyone else gets only the second. Both carry the two
  /// players, and a pair cannot meet twice in one hand — one of them has
  /// packed — so the hand and the pair name it exactly.
  static String keyFor(int handNo, String fromUserId, String toUserId) =>
      '$handNo:$fromUserId:$toUserId';

  final int handNo;

  /// Who forced it, and so where the hammer is thrown from.
  final String fromUserId;

  /// Who it was forced on, and so the pod it lands on.
  final String toUserId;

  /// Who lost and packed, when the server said. Their fold is held back until
  /// [HammerTiming.result].
  final String? packedUserId;

  /// When the client heard of it. The table's animation starts a frame or two
  /// later and catches up to this, so the timers in `GameState` and the frames
  /// on screen agree on when the hammer lands.
  final DateTime startedAt;

  String get key => keyFor(handNo, fromUserId, toUserId);
}

/// When each part of a strike happens, measured from [HammerStrike.startedAt].
///
/// One table of numbers read by both halves: `GameState` holds the reveal and
/// the fold back on timers, the felt draws the hammer on the frame clock, and
/// the two meet at [impact].
abstract final class HammerTiming {
  /// The whole strike, launch to the last spark.
  static const total = Duration(milliseconds: 1500);

  /// The hammer leaves the asker's pod and arrives over the target's, winding
  /// up as it goes.
  static const flight = Duration(milliseconds: 760);

  /// The swing comes down and lands. The cards turn over here, and the pod
  /// that was hit shakes.
  static const impact = Duration(milliseconds: 900);

  /// How long the hit pod shakes for.
  static const shake = Duration(milliseconds: 380);

  /// The hammer has gone. After the flip (420 ms from [impact]) the loser
  /// folds and the table is told what happened.
  static const result = Duration(milliseconds: 1320);

  /// [d] as a share of [total], for an animation that runs 0 to 1 over it.
  static double share(Duration d) => d.inMicroseconds / total.inMicroseconds;
}
